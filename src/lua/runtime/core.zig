pub const RequestPool = @import("request_pool.zig").RequestPool;
const std = @import("std");
pub const namespace_registry = @import("namespace_registry");
pub const RequestAllocator = @import("request_allocator.zig").RequestAllocator;
pub const LocalBumpArena = @import("local_bump_arena.zig").LocalBumpArena;
pub const work_stats = @import("work_stats.zig");
pub const execution_budget = @import("execution_budget.zig");
const static_fields = @import("lua_static_fields");
pub const NativeNamespace = static_fields.Namespace;
const native_namespace_count = @typeInfo(static_fields.Namespace).@"enum".field_names.len;
comptime { if (native_namespace_count > 64) @compileError("library dependency mask is too small"); }

// Promotion still mutates process-lived graphs incrementally. A failed
// allocation can be caught by Lua pcall or an optional upward-promotion caller;
// that must never permit the build worker to accept output or reuse the engine.
// Keep this out of Context's generated-code ABI and sticky until process exit.
threadlocal var module_template_allocation_failed = false;

pub fn moduleTemplateAllocationFailed() bool {
    return module_template_allocation_failed;
}

fn templateSingletonNamespace(namespace: static_fields.Namespace) bool {
    return switch (namespace) {
        .table,
        .string,
        .math,
        .debug,
        .mw,
        .ustring,
        .title,
        .text,
        .uri,
        .html,
        .language,
        .hash,
        .site,
        .site_stats,
        .ext,
        .ext_data,
        .wikibase,
        .message,
        .os,
        .package,
        .package_loaded,
        .bit32,
        .library_util,
        => true,
        .frame,
        .title_value,
        .language_value,
        .html_node,
        .message_value,
        .uri_value,
        .title_batch,
        .namespace_value,
        .namespace_map,
        => false,
    };
}

comptime {
    if (@backingInt(std.meta.Tag(Value).string) != static_fields.string_value_tag)
        @compileError("prehashed field ABI requires the runtime string Value tag");
}

extern fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;

pub const Cell = struct { value: Value };
const ExportGuardRoot = struct { table: ?*Table };
pub const Env = struct {
    captures: []const *Cell,
    capture_view: Captures,
};
pub const FunctionEnv = struct {
    raw: usize = 0,

    pub fn closure(env: *Env) FunctionEnv {
        return .{ .raw = @intFromPtr(env) };
    }

    pub fn native(host: ?*anyopaque) FunctionEnv {
        return .{ .raw = if (host) |ptr| @intFromPtr(ptr) else 0 };
    }

    pub fn nativePtr(self: FunctionEnv) ?*anyopaque {
        return if (self.raw == 0) null else @ptrFromInt(self.raw);
    }

    pub fn closurePtr(self: FunctionEnv) ?*Env {
        return if (self.raw == 0) null else @ptrFromInt(self.raw);
    }
};

pub const Captures = union(enum) {
    direct: []const *Cell,
    native: ?*anyopaque,

    pub fn cell(self: Captures, ordinal: u32) !*Cell {
        return switch (self) {
            .direct => |cells| if (ordinal < cells.len) cells[ordinal] else error.BadUpvalue,
            .native => error.BadUpvalue,
        };
    }
};

pub const native_function_id = std.math.maxInt(u32);
pub const FunctionValue = struct {
    env: FunctionEnv = .{},
    entry: FunctionFn,
    id: u32,
    identity: u32,

    pub fn captures(self: *const FunctionValue) Captures {
        if (self.id == native_function_id) return .{ .native = self.env.nativePtr() };
        if (self.env.closurePtr()) |env| return env.capture_view;
        return .{ .direct = &.{} };
    }

    pub fn capturesPtr(self: *const FunctionValue) ?*const Captures {
        if (self.id == native_function_id) return null;
        if (self.env.closurePtr()) |env| return &env.capture_view;
        return null;
    }
};
pub const DirectFunctionFn = *const fn (*Context, Captures, []const Value) anyerror![]const Value;
pub const BufferedDirectFunctionFn = *const fn (*Context, Captures, []const Value, ?[]Value) anyerror![]const Value;
pub const FunctionResult = extern struct {
    values_ptr: ?[*]const Value,
    values_len: usize,
    status: u32,
    reserved: u32,
};
pub const FunctionFn = *const fn (*Context, *const Captures, [*]const Value, usize, ?[*]Value, usize) callconv(.c) FunctionResult;
pub const ModuleLookupFn = *const fn (?*const anyopaque, []const u8) ?u32;
pub const ModuleNameFn = *const fn (?*const anyopaque, u32) ?[]const u8;
pub const ModuleLoadErrorFn = ModuleNameFn;
pub const ModuleRequirement = struct {
    module_id: u32,
    requested: []const u8,
};
pub const ModuleRequirementsFn = *const fn (?*const anyopaque, u32) []const ModuleRequirement;
pub const StaticModuleFn = *const fn (?*const anyopaque, *Context, u32) anyerror!?Value;
pub const ProgramBootstrapFn = *const fn (?*const anyopaque, *Context) anyerror!void;
pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *Table,
    // Descriptors are immutable and remain valid for their owning Context.
    // Copies keep closure identity and the live capture cells by pointer.
    callable: *const FunctionValue,

    pub fn truthy(value: Value) bool {
        return switch (value) {
            .nil => false,
            .boolean => |v| v,
            else => true,
        };
    }
};
pub const stable_error_name_capacity = 128;
pub const StableErrorName = struct {
    bytes: [stable_error_name_capacity]u8 = @as([stable_error_name_capacity]u8, @splat(0)),
    len: u16 = 0,

    pub fn clear(self: *StableErrorName) void {
        self.len = 0;
    }

    pub fn set(self: *StableErrorName, name: []const u8) void {
        const source = if (name.len <= self.bytes.len) name else "AotErrorNameTooLong";
        @memcpy(self.bytes[0..source.len], source);
        self.len = @intCast(source.len);
    }

    pub fn get(self: *const StableErrorName) ?[]const u8 {
        return if (self.len == 0) null else self.bytes[0..self.len];
    }
};

pub fn checkExecutionBudget(ctx: *Context) !void {
    execution_budget.check() catch |err| {
        ctx.clearLuaError();
        ctx.setAotErrorName(@errorName(err));
        return err;
    };
}

pub fn stabilize(comptime function: DirectFunctionFn) FunctionFn {
    return struct {
        fn call(ctx: *Context, captures: *const Captures, args_ptr: [*]const Value, args_len: usize, result_ptr: ?[*]Value, result_len: usize) callconv(.c) FunctionResult {
            _ = result_ptr;
            _ = result_len;
            const values = function(ctx, captures.*, args_ptr[0..args_len]) catch |err| {
                if (ctx.aotErrorName() == null) ctx.setAotErrorName(@errorName(err));
                return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
            };
            return .{
                .values_ptr = if (values.len == 0) null else values.ptr,
                .values_len = values.len,
                .status = 0,
                .reserved = 0,
            };
        }
    }.call;
}

pub fn stabilizeBuffered(comptime function: BufferedDirectFunctionFn) FunctionFn {
    return struct {
        fn call(ctx: *Context, captures: *const Captures, args_ptr: [*]const Value, args_len: usize, result_ptr: ?[*]Value, result_len: usize) callconv(.c) FunctionResult {
            const result_buffer: ?[]Value = if (result_ptr) |ptr| ptr[0..result_len] else null;
            const values = function(ctx, captures.*, args_ptr[0..args_len], result_buffer) catch |err| {
                if (ctx.aotErrorName() == null) ctx.setAotErrorName(@errorName(err));
                return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
            };
            return .{
                .values_ptr = if (values.len == 0) null else values.ptr,
                .values_len = values.len,
                .status = 0,
                .reserved = 0,
            };
        }
    }.call;
}

pub fn stabilizeNative(comptime function: anytype) FunctionFn {
    return struct {
        fn call(ctx: *Context, captures: *const Captures, args_ptr: [*]const Value, args_len: usize, result_ptr: ?[*]Value, result_len: usize) callconv(.c) FunctionResult {
            checkExecutionBudget(ctx) catch return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
            _ = result_ptr;
            _ = result_len;
            const host = switch (captures.*) {
                .native => |value| value,
                else => {
                    if (ctx.aotErrorName() == null) ctx.setAotErrorName("NativeCaptureExpected");
                    return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
                },
            };
            const values = @call(.always_inline, function, .{ host, ctx, args_ptr[0..args_len] }) catch |err| {
                if (ctx.aotErrorName() == null) ctx.setAotErrorName(@errorName(err));
                return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
            };
            return .{
                .values_ptr = if (values.len == 0) null else values.ptr,
                .values_len = values.len,
                .status = 0,
                .reserved = 0,
            };
        }
    }.call;
}

pub fn stabilizeNativeBuffered(comptime function: anytype) FunctionFn {
    return struct {
        fn call(ctx: *Context, captures: *const Captures, args_ptr: [*]const Value, args_len: usize, result_ptr: ?[*]Value, result_len: usize) callconv(.c) FunctionResult {
            checkExecutionBudget(ctx) catch return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
            const result_buffer: ?[]Value = if (result_ptr) |ptr| ptr[0..result_len] else null;
            const host = switch (captures.*) {
                .native => |value| value,
                else => {
                    if (ctx.aotErrorName() == null) ctx.setAotErrorName("NativeCaptureExpected");
                    return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
                },
            };
            const values = @call(.always_inline, function, .{ host, ctx, args_ptr[0..args_len], result_buffer }) catch |err| {
                if (ctx.aotErrorName() == null) ctx.setAotErrorName(@errorName(err));
                return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
            };
            return .{
                .values_ptr = if (values.len == 0) null else values.ptr,
                .values_len = values.len,
                .status = 0,
                .reserved = 0,
            };
        }
    }.call;
}

pub const Shape = struct {
    pub const Keys = union(enum) {
        boxed: []const Value,
        strings: []const []const u8,
        dense_array,
    };
    keys: Keys = .{ .boxed = &.{} },
    sorted_string_slots: []const u32 = &.{},
    // Immutable program layout: zero means absent, otherwise slot + 1.
    // Unlike a Lua table map, this never owns Values or changes on mutation.
    string_lookup_slots: []const u32 = &.{},
    field_count: u32 = 0,
    choice_count: u32 = 0,
    open: bool = false,
    // Set only by producers that construct a complete all-string key index.
    all_string_keys: bool = false,

    pub fn validStorage(self: *const Shape) bool {
        return switch (self.keys) {
            .boxed => |keys| keys.len == self.field_count,
            .strings => |keys| keys.len == self.field_count,
            .dense_array => true,
        };
    }

    pub fn keyAt(self: *const Shape, slot: usize) ?Value {
        if (slot >= self.field_count) return null;
        return switch (self.keys) {
            .boxed => |keys| if (slot < keys.len) keys[slot] else null,
            .strings => |keys| if (slot < keys.len) .{ .string = keys[slot] } else null,
            .dense_array => .{ .number = @floatFromInt(slot + 1) },
        };
    }

    pub fn stringKeyAt(self: *const Shape, slot: usize) ?[]const u8 {
        if (slot >= self.field_count) return null;
        return switch (self.keys) {
            .strings => |keys| if (slot < keys.len) keys[slot] else null,
            .boxed => |keys| if (slot < keys.len and keys[slot] == .string) keys[slot].string else null,
            .dense_array => null,
        };
    }
};

fn shapeStringIndexCapacity(shape: *const Shape) !usize {
    if (!shape.validStorage()) return error.BadShape;
    var count: usize = 0;
    if (shape.keys == .dense_array) return 0;
    if (shape.keys == .strings) {
        count = shape.field_count;
    } else for (shape.keys.boxed) |key| {
        count += @intFromBool(key == .string);
    }
    const needed = std.math.mul(usize, count, 2) catch return error.OutOfMemory;
    var capacity: usize = 1;
    while (capacity < needed)
        capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
    return capacity;
}

/// Construct all string-to-slot layouts once in a single program-owned block.
/// Field order remains authoritative, including partial indices and duplicate
/// keys. Allocation failure leaves every input shape unchanged.
pub fn buildShapeStringIndices(a: std.mem.Allocator, shapes: []Shape) ![]u32 {
    var total: usize = 0;
    for (shapes) |*shape| {
        if (shape.string_lookup_slots.len != 0) return error.BadShape;
        total = std.math.add(usize, total, try shapeStringIndexCapacity(shape)) catch return error.OutOfMemory;
    }
    const storage = try a.alloc(u32, total);
    @memset(storage, 0);
    var at: usize = 0;
    for (shapes) |*shape| {
        const capacity = shapeStringIndexCapacity(shape) catch unreachable;
        const slots = storage[at..][0..capacity];
        if (capacity == 0) continue;
        const mask = capacity - 1;
        for (0..shape.field_count) |slot| {
            const name = shape.stringKeyAt(slot) orelse continue;
            var bucket: usize = @as(usize, @truncate(stringValueHash(name))) & mask;
            while (slots[bucket] != 0) : (bucket = (bucket + 1) & mask) {
                const previous = shape.stringKeyAt(slots[bucket] - 1).?;
                if (std.mem.eql(u8, previous, name)) break;
            }
            if (slots[bucket] == 0) slots[bucket] = @as(u32, @intCast(slot)) + 1;
        }
        shape.string_lookup_slots = slots;
        at += capacity;
    }
    return storage;
}

fn indexedShapeStringSlot(shape: *const Shape, name: []const u8, key_hash: u64) ?u32 {
    const slots = shape.string_lookup_slots;
    if (slots.len == 0) return null;
    const mask = slots.len - 1;
    var bucket: usize = @as(usize, @truncate(key_hash)) & mask;
    var remaining = slots.len;
    while (remaining != 0) : (remaining -= 1) {
        const encoded = slots[bucket];
        if (encoded == 0) return null;
        const slot = encoded - 1;
        const candidate = shape.stringKeyAt(slot) orelse return null;
        if (std.mem.eql(u8, candidate, name)) return slot;
        bucket = (bucket + 1) & mask;
    }
    return null;
}

pub fn shapeStringSlot(shape: *const Shape, name: []const u8) ?u32 {
    if (!shape.validStorage()) return null;
    var low: usize = 0;
    var high = shape.sorted_string_slots.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const slot = shape.sorted_string_slots[mid];
        const key = shape.stringKeyAt(slot) orelse return null;
        switch (std.mem.order(u8, name, key)) {
            .lt => high = mid,
            .gt => low = mid + 1,
            .eq => return slot,
        }
    }
    return null;
}

pub const ChoiceCell = struct {
    key: Value = .nil,
    value: Value = .nil,
};

inline fn wyhashMix64(a: u64, b: u64) u64 {
    const product = @as(u128, a) *% b;
    return @as(u64, @truncate(product)) ^ @as(u64, @truncate(product >> 64));
}

fn numberValueHash(number: f64) u64 {
    const secret0: u64 = 0xa0761d6478bd642f;
    const secret1: u64 = 0xe7037ed1a0b428db;
    const normalized: f64 = if (number == 0) 0 else number;
    const bits: u64 = @bitCast(normalized);
    var bytes: [9]u8 = undefined;
    bytes[0] = @backingInt(std.meta.Tag(Value).number);
    @memcpy(bytes[1..], std.mem.asBytes(&bits));
    const a0 = (@as(u64, std.mem.readInt(u32, bytes[0..4], .little)) << 32) |
        std.mem.readInt(u32, bytes[4..8], .little);
    const b0 = (@as(u64, std.mem.readInt(u32, bytes[5..9], .little)) << 32) |
        std.mem.readInt(u32, bytes[1..5], .little);
    const state0 = wyhashMix64(secret0, secret1);
    const a = a0 ^ secret1;
    const b = b0 ^ state0;
    const product = @as(u128, a) *% b;
    const low = @as(u64, @truncate(product));
    const high = @as(u64, @truncate(product >> 64));
    return wyhashMix64(low ^ secret0 ^ 9, high ^ secret1);
}

pub fn stringValueHash(text: []const u8) u64 {
    return static_fields.hashStringKey(text);
}

const StringLookupContext = struct {
    key_hash: u64,

    pub fn hash(self: StringLookupContext, _: []const u8) u64 {
        return self.key_hash;
    }
    pub fn eql(_: StringLookupContext, text: []const u8, value: Value) bool {
        return value == .string and std.mem.eql(u8, text, value.string);
    }
};

const NumberLookupContext = struct {
    pub fn hash(_: NumberLookupContext, number: f64) u64 {
        return numberValueHash(number);
    }
    pub fn eql(_: NumberLookupContext, number: f64, value: Value) bool {
        return value == .number and number == value.number;
    }
};

const ValueContext = struct {
    pub fn hash(_: ValueContext, value: Value) u64 {
        if (value == .number) return numberValueHash(value.number);
        if (value == .string) return stringValueHash(value.string);
        const tag: u8 = @backingInt(std.meta.activeTag(value));
        var h = std.hash.Wyhash.init(0);
        h.update(&.{tag});
        switch (value) {
            .nil => {},
            .boolean => |v| h.update(&.{@intFromBool(v)}),
            .number => unreachable,
            .string => unreachable,
            .table => |v| {
                const ptr: usize = @intFromPtr(v);
                h.update(std.mem.asBytes(&ptr));
            },
            .callable => |v| h.update(std.mem.asBytes(&v.identity)),
        }
        return h.final();
    }
    pub fn eql(_: ValueContext, a: Value, b: Value) bool {
        return rawEqual(a, b);
    }
};

const Map = std.HashMapUnmanaged(Value, Value, ValueContext, 80);

// Native global pointers refer only to this fixed prefix; tail pages never move it.
pub const module_global_prefix_len = static_fields.global_dense_prefix_len;
const global_page_len = 64;
const GlobalPage = [global_page_len]Value;
const GlobalTail = struct {
    allocator: std.mem.Allocator,
    len: usize,
    pages: []?*GlobalPage,

    fn initEmpty(allocator: std.mem.Allocator, len: usize) !*GlobalTail {
        const self = try allocator.create(GlobalTail);
        errdefer allocator.destroy(self);
        const page_count = len / global_page_len + @intFromBool(len % global_page_len != 0);
        const pages = try allocator.alloc(?*GlobalPage, page_count);
        @memset(pages, null);
        self.* = .{ .allocator = allocator, .len = len, .pages = pages };
        return self;
    }

    fn snapshot(allocator: std.mem.Allocator, values: []const Value, occupied_pages: ?[]const u64) !*GlobalTail {
        const self = try allocator.create(GlobalTail);
        errdefer allocator.destroy(self);
        const pages = try allocator.alloc(?*GlobalPage, values.len / global_page_len + @intFromBool(values.len % global_page_len != 0));
        @memset(pages, null);
        self.* = .{ .allocator = allocator, .len = values.len, .pages = pages };
        errdefer self.deinit();
        for (pages, 0..) |*page, page_index| {
            const start = page_index * global_page_len;
            const source = values[start..@min(start + global_page_len, values.len)];
            const occupied = if (occupied_pages) |bits|
                bits[page_index / 64] & (@as(u64, 1) << @intCast(page_index % 64)) != 0
            else blk: {
                for (source) |value| if (value != .nil) break :blk true;
                break :blk false;
            };
            if (!occupied) continue;
            const owned = try allocator.create(GlobalPage);
            owned.* = @as([global_page_len]Value, @splat(.nil));
            @memcpy(owned[0..source.len], source);
            page.* = owned;
        }
        return self;
    }

    fn cloneState(self: *const GlobalTail, allocator: std.mem.Allocator) !GlobalTail {
        const pages = try allocator.alloc(?*GlobalPage, self.pages.len);
        @memset(pages, null);
        var out = GlobalTail{ .allocator = allocator, .len = self.len, .pages = pages };
        errdefer out.deinit();
        for (self.pages, pages) |source, *target| if (source) |page| {
            const copy = try allocator.create(GlobalPage);
            copy.* = page.*;
            target.* = copy;
        };
        return out;
    }

    fn deinit(self: *GlobalTail) void {
        for (self.pages) |page| if (page) |owned| self.allocator.destroy(owned);
        self.allocator.free(self.pages);
    }

    fn ptr(self: *const GlobalTail, slot: usize) ?*Value {
        if (slot >= self.len) return null;
        const page = self.pages[slot / global_page_len] orelse return null;
        return &page[slot % global_page_len];
    }

    fn set(self: *GlobalTail, slot: usize, value: Value) !void {
        if (slot >= self.len) return error.BadGlobalSlot;
        const page_index = slot / global_page_len;
        if (self.pages[page_index] == null) {
            if (value == .nil) return;
            const page = try self.allocator.create(GlobalPage);
            page.* = @as([global_page_len]Value, @splat(.nil));
            self.pages[page_index] = page;
        }
        self.pages[page_index].?[slot % global_page_len] = value;
    }
};

pub const Table = struct {
    shape: ?*const Shape = null,
    native_namespace: ?static_fields.Namespace = null,
    slots: []Value = &.{},
    global_tail: ?*GlobalTail = null,
    owns_slots: bool = true,
    // The real environment owner, independent of the ordinary variable _G.
    invocation_environment: bool = false,
    choices: []ChoiceCell = &.{},
    map: Map = .empty,
    // Lua next() accepts a previously present key after its value is cleared.
    // Declared shape slots are not necessarily initialized: keep that distinction.
    slot_history: u64 = 0,
    slot_history_tail: []u64 = &.{},
    map_deletions_since_prune: u32 = 0,
    metatable: ?*Table = null,
    append_index: u32 = 1,
    read_only: bool = false,
    // Every module alias of this table observes the same stable guard. Keep
    // it in the table, not in one arbitrarily chosen module-state allocation.
    has_export_guard: bool = false,
    export_pristine: bool = false,
    export_guard_graph_ready: bool = false,
    // Every exported root that reaches this table shares its mutation guard.
    // These context-owned lists are installed once, never copied across forks.
    export_guard_root: ?*ExportGuardRoot = null,
    export_guard_parents: []const *ExportGuardRoot = &.{},
    export_capture_baselines: []const InvokeCellBaseline = &.{},
    // Monotonic: only tables that have ever hashed a numeric key need numeric map probes.
    has_hashed_number: bool = false,
    field_cache_owner_nonce: u64 = 0,
    field_cache_nonce: u64 = 0,
    field_cache_epoch: u64 = 1,
    // A small numeric read mirror for string-shaped tables. The map remains
    // authoritative for insertion, deletion, and iteration order.
    numeric_mirror: []Value = &.{},
    numeric_mirror_disabled: bool = false,
    dense_prefix_len: usize = 0,
    dense_prefix_valid: bool = true,
    // Identity-key iteration may depend on arena addresses or function allocation order.
    has_identity_key: bool = false,
    // Marks the remapped package.loaded singleton. Runtime module-cache
    // bookkeeping is reconstructed; explicit user contents remain page state.
    module_template_reconstructable: bool = false,
    // Worker-lifetime immutable data graphs may be shared directly by
    // page/invoke contexts and by the worker-global module-template graph.
    // Only the shared mw.loadData cache sets this bit.
    cross_page_stable: bool = false,
    native_metatable_namespace: ?NativeNamespace = null,
    // Points at the owning module state's mutation epoch for export graphs.
    // Nested table mutations can then be snapshotted as root-private module
    // overrides instead of being mistaken for page-state effects.
    module_template_mutation_probe: ?*u64 = null,
    // Non-zero only for tables created while a dynamic module-root promotion
    // probe is active. Mutating a table owned by another probe (or no probe)
    // is an externally visible effect and makes the root non-reusable.
    module_template_probe_id: u64 = 0,
    // Certified only at the end of library installation, before Lua executes.
    template_native_baseline_pristine: ?bool = null,
    invoke_rollback_owner_nonce: u64 = 0,
    invoke_rollback_allocation_id: u64 = 0,
    invoke_rollback_snapshot_id: u64 = 0,

    fn markMapStructuralMutation(self: *Table) void {
        if (self.field_cache_epoch == std.math.maxInt(u64))
            self.field_cache_nonce = 0
        else
            self.field_cache_epoch += 1;
    }

    pub fn notePackageStateAccess(self: *const Table) void {
        if (module_template_effect_probe != null) {
            if (self.invocation_environment) observeInvocationGlobalAccess();
            if (self.native_namespace) |namespace| {
                if (templateSingletonNamespace(namespace)) self.observeTemplateLibrary(namespace);
            }
            if (self.native_metatable_namespace) |namespace| self.observeTemplateLibrary(namespace);
        }
        if (module_template_effect_probe != null and self.module_template_reconstructable) {
            // The package singleton is remapped, not snapshotted. Its user-visible
            // contents (including misses, false, iteration, length and writes) are page state.
            noteModuleTemplateEffectReason(1 << 1);
            markModuleTemplateEffect();
        }
    }

    fn observeTemplateLibrary(self: *const Table, namespace: NativeNamespace) void {
        module_template_library_dependencies |= @as(u64, 1) << @as(u6, @intCast(@backingInt(namespace)));
        // Uncertified lazy libraries are unproved dependencies, just as a
        // previously modified installed library is. Execution stays unchanged.
        if (self.template_native_baseline_pristine != @as(?bool, true))
            observeInvocationGlobalAccess();
    }

    fn markMutated(self: *Table) !void {
        self.notePackageStateAccess();
        try noteInvokeTableMutation(self);
        for (self.export_guard_parents) |guard| if (guard.table) |root| {
            if (!root.export_pristine) continue;
            try noteInvokeTableMutation(root);
            root.export_pristine = false;
        };
        if (self.template_native_baseline_pristine != null)
            self.template_native_baseline_pristine = false;
        if (module_template_effect_probe != null and self.native_metatable_namespace != null) {
            // A builtin type is shared by every object of that type. Returning
            // its metatable from a module does not make it module-private.
            noteModuleTemplateEffectReason(1 << 1);
            markModuleTemplateEffect();
        }
        if (module_template_effect_probe != null) {
            if (self.module_template_mutation_probe) |probe| {
                probe.* = module_template_probe_id;
            }
        }
        if (module_template_effect_probe != null and
            self.module_template_probe_id != module_template_probe_owner_id and
            self.module_template_mutation_probe == null and
            !self.has_export_guard)
        {
            noteModuleTemplateEffectReason(1 << 1);
            markModuleTemplateEffect();
        }
        self.export_pristine = false;
    }

    pub fn setMetatable(self: *Table, metatable: ?*Table) !void {
        try self.markMutated();
        self.metatable = metatable;
    }

    fn prepareExportGuard(self: *Table) void {
        // A later alias must never make an already-mutated export pristine.
        if (self.has_export_guard) return;
        self.has_export_guard = true;
        self.export_pristine = true;
    }

    fn exportGraphPristine(self: *const Table) bool {
        if (!self.export_guard_graph_ready or !self.export_pristine) return false;
        // Generated stores write capture cells directly. Descendant table
        // writes use the guards above; rebinding a cell is checked separately.
        for (self.export_capture_baselines) |baseline|
            if (!rawEqual(baseline.cell.value, baseline.value)) return false;
        return true;
    }

    fn invalidateExportGuard(self: *Table) !void {
        try noteInvokeTableMutation(self);
        for (self.export_guard_parents) |guard| if (guard.table) |root| {
            if (!root.export_pristine) continue;
            try noteInvokeTableMutation(root);
            root.export_pristine = false;
        };
        self.export_pristine = false;
    }

    fn identityKey(key: Value) bool {
        return key == .table or key == .callable;
    }

    fn markIdentityKeyWrite(self: *Table, key: Value, value: Value) void {
        if (!identityKey(key)) return;
        markLoadDataEffect();
        if (value != .nil) self.has_identity_key = true;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        if (self.slot_history_tail.len != 0) allocator.free(self.slot_history_tail);
        if (self.numeric_mirror.len != 0) allocator.free(self.numeric_mirror);
        if (self.owns_slots and self.slots.len != 0) allocator.free(self.slots);
        if (self.choices.len != 0) allocator.free(self.choices);
    }

    fn initSlotHistory(self: *Table, allocator: std.mem.Allocator) !void {
        if (self.shape == null and self.native_namespace == null) return;
        const count = self.slotCount();
        if (count > 64) {
            self.slot_history_tail = try allocator.alloc(u64, (count - 1) / 64);
            @memset(self.slot_history_tail, 0);
        }
    }

    fn noteSlotPresence(self: *Table, slot: u32) void {
        if (self.shape == null and self.native_namespace == null) return;
        const mask = @as(u64, 1) << @as(u6, @intCast(slot % 64));
        if (slot < 64) self.slot_history |= mask else self.slot_history_tail[slot / 64 - 1] |= mask;
    }

    fn slotWasPresent(self: *const Table, slot: u32) bool {
        const word = if (slot < 64) self.slot_history else self.slot_history_tail[slot / 64 - 1];
        return word & (@as(u64, 1) << @as(u6, @intCast(slot % 64))) != 0;
    }

    fn liveValue(value: ?Value) ?Value {
        return if (value) |v| if (v == .nil) null else v else null;
    }

    fn pruneDeletedMapKeys(self: *Table) void {
        // HashMap's next insertion grows when available is zero. Amortize a
        // full scan across enough prior deletions; one remove/replace on a
        // nearly full large map must not cause an O(capacity) scan each time.
        if (self.map.available != 0 or
            self.map_deletions_since_prune < @max(1, self.map.capacity() / 8)) return;
        var entries = self.map.iterator();
        while (entries.next()) |entry| if (entry.value_ptr.* == .nil) {
            const key = entry.key_ptr.*;
            _ = self.map.removeContext(key, .{});
        };
        self.map_deletions_since_prune = 0;
        self.markMapStructuralMutation();
    }

    fn genericArrayIndex(self: *const Table, number: f64) ?u32 {
        if (self.shape != null or self.native_namespace != null) return null;
        if (!std.math.isFinite(number) or number < 1 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
        if (@floor(number) != number) return null;
        return @intFromFloat(number);
    }

    fn arraySlotForNumber(self: *const Table, number: f64) ?u32 {
        const index = self.genericArrayIndex(number) orelse return null;
        const slot = index - 1;
        return if (slot < self.slots.len) slot else null;
    }

    const numeric_mirror_len: usize = 16;

    fn allStringShape(self: *const Table) bool {
        const shape = self.shape orelse return false;
        return shape.all_string_keys and self.native_namespace == null and self.choices.len == 0 and
            shape.sorted_string_slots.len == shape.field_count;
    }

    fn positiveInteger(number: f64) ?usize {
        if (!std.math.isFinite(number) or number < 1 or
            number >= @as(f64, @floatFromInt(std.math.maxInt(usize))) or
            @floor(number) != number) return null;
        return @intFromFloat(number);
    }

    // Build only after the authoritative map write has succeeded. The mirror
    // is an optional cache: its allocation must never cause a Lua write to fail.
    fn maybeBuildNumericMirror(self: *Table, allocator: std.mem.Allocator, key: Value, value: Value) void {
        if (!self.allStringShape() or key != .number or value == .nil or
            self.numeric_mirror.len != 0 or self.numeric_mirror_disabled) return;
        const index = positiveInteger(key.number) orelse return;
        if (index > numeric_mirror_len) return;
        if (self.map.count() > 128) {
            self.numeric_mirror_disabled = true;
            return;
        }
        const mirror = allocator.alloc(Value, numeric_mirror_len) catch {
            self.numeric_mirror_disabled = true;
            return;
        };
        @memset(mirror, .nil);
        var entries = self.map.iterator();
        while (entries.next()) |entry| {
            if (entry.key_ptr.* != .number) continue;
            const number_index = positiveInteger(entry.key_ptr.number) orelse continue;
            if (number_index <= mirror.len) mirror[number_index - 1] = entry.value_ptr.*;
        }
        self.numeric_mirror = mirror;
    }

    // Called only after a successful map mutation. A known dense prefix has no
    // missing positive integer and no positive key beyond its border.
    fn noteNumericMapWrite(self: *Table, key: Value, value: Value) void {
        if (!self.allStringShape() or key != .number) return;
        const index = positiveInteger(key.number) orelse {
            if (std.math.isFinite(key.number) and key.number >= 1 and
                @floor(key.number) == key.number and value != .nil)
                self.dense_prefix_valid = false;
            return;
        };
        if (index <= self.numeric_mirror.len) self.numeric_mirror[index - 1] = value;
        if (!self.dense_prefix_valid) return;
        if (value == .nil) {
            if (index <= self.dense_prefix_len) self.dense_prefix_valid = false;
        } else if (self.dense_prefix_len < std.math.maxInt(usize) and index == self.dense_prefix_len + 1) {
            self.dense_prefix_len = index;
        } else if (index > self.dense_prefix_len) {
            self.dense_prefix_valid = false;
        }
    }

    fn slotForString(self: *const Table, name: []const u8, known_hash: ?u64) ?u32 {
        if (self.native_namespace) |namespace| {
            // Namespace-map names are virtual aliases backed by numeric entries;
            // they must never become physical slots because that would change
            // iteration and string-key override semantics.
            if (namespace == .namespace_map) return null;
            return static_fields.slotForName(namespace, name);
        }
        const shape = self.shape orelse return null;
        if (!shape.validStorage()) return null;
        if (shape.string_lookup_slots.len != 0)
            return indexedShapeStringSlot(shape, name, known_hash orelse stringValueHash(name));
        if (shape.sorted_string_slots.len == shape.field_count)
            return shapeStringSlot(shape, name);
        if (shape.keys == .dense_array) return null;
        for (0..shape.field_count) |slot| {
            const candidate = shape.stringKeyAt(slot) orelse continue;
            if (std.mem.eql(u8, candidate, name)) return @intCast(slot);
        }
        return null;
    }

    fn slotForKey(self: *const Table, key: Value) ?u32 {
        if (key == .string) return self.slotForString(key.string, null);
        const shape = self.shape orelse return null;
        if (!shape.validStorage()) return null;
        if (shape.all_string_keys or shape.keys == .strings) return null;
        if (shape.keys == .dense_array) {
            if (key != .number or !std.math.isFinite(key.number) or key.number < 1 or
                key.number > @as(f64, @floatFromInt(shape.field_count)) or @floor(key.number) != key.number) return null;
            return @as(u32, @intFromFloat(key.number)) - 1;
        }
        for (0..shape.field_count) |slot| {
            const field_key = shape.keyAt(slot) orelse return null;
            if (rawEqual(field_key, key)) return @intCast(slot);
        }
        return null;
    }
    pub fn fieldKey(self: *const Table, slot: u32) ?Value {
        if (self.native_namespace) |namespace| {
            return .{ .string = static_fields.nameAt(namespace, slot) orelse return null };
        }
        const shape = self.shape orelse return null;
        if (!shape.validStorage()) return null;
        return shape.keyAt(slot);
    }

    fn ensureGenericArraySlot(self: *Table, allocator: std.mem.Allocator, index: u32) !?u32 {
        if (self.shape != null or self.native_namespace != null or !self.owns_slots or index == 0) return null;
        const slot = index - 1;
        if (slot < self.slots.len) return slot;
        const needed: usize = index;
        const old_len = self.slots.len;
        const growth_limit = if (old_len == 0) @as(usize, 8) else old_len +| old_len;
        if (needed > growth_limit or needed > std.math.maxInt(u32)) return null;
        var new_len: usize = if (old_len == 0) 8 else old_len;
        while (new_len < needed) {
            const doubled = new_len +| new_len;
            new_len = @min(@as(usize, std.math.maxInt(u32)), doubled);
        }
        // Generic arrays are an optimization, not part of Lua table
        // semantics. Do not let gradually increasing sparse integer keys keep
        // doubling a mostly-empty dense allocation (for example 100k, 200k,
        // ... 2m). Require the grown array to remain at least half occupied;
        // sparse keys stay in the exact hash-table fallback instead.
        if (old_len != 0) {
            var occupied: usize = 0;
            for (self.slots) |value| occupied += @intFromBool(value != .nil);
            if ((occupied + 1) * 2 < new_len) return null;
        }
        const grown = if (old_len == 0) try allocator.alloc(Value, new_len) else try allocator.realloc(self.slots, new_len);
        @memset(grown[old_len..], .nil);
        self.slots = grown;
        return slot;
    }

    fn rawGetArraySlot(self: *const Table, slot: u32) ?Value {
        if (self.shape != null or self.native_namespace != null or slot >= self.slots.len) return null;
        return if (self.slots[slot] == .nil) null else self.slots[slot];
    }

    fn rawSetArraySlot(self: *Table, slot: u32, value: Value) !void {
        std.debug.assert(self.shape == null and self.native_namespace == null and slot < self.slots.len);
        try self.markMutated();
        self.slots[slot] = value;
    }

    pub fn rawGetSlot(self: *const Table, slot: u32) ?Value {
        self.notePackageStateAccess();
        if (self.shape == null and self.native_namespace == null) return null;
        const value = self.slotPtr(slot) orelse return null;
        return if (value.* == .nil) null else value.*;
    }

    fn slotCount(self: *const Table) usize {
        return self.slots.len + if (self.global_tail) |tail| tail.len else @as(usize, 0);
    }

    fn slotPtr(self: *const Table, slot: u32) ?*Value {
        if (slot < self.slots.len) return &self.slots[slot];
        const tail = self.global_tail orelse return null;
        return tail.ptr(slot - self.slots.len);
    }

    pub fn rawSetSlot(self: *Table, slot: u32, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        if (self.shape == null and self.native_namespace == null) return error.BadShapeSlot;
        if (slot >= self.slotCount()) return error.BadShapeSlot;
        try self.markMutated();
        if (self.shape == null or self.shape.?.keys == .boxed)
            if (self.fieldKey(slot)) |key| self.markIdentityKeyWrite(key, value);
        // Native construction can fill slots directly before exposing the
        // table. Remember an existing value before clearing that slot too.
        if (value == .nil) if (self.slotPtr(slot)) |previous| if (previous.* != .nil) self.noteSlotPresence(slot);
        if (slot >= self.slots.len) {
            try self.global_tail.?.set(slot - self.slots.len, value);
            if (value != .nil) self.noteSlotPresence(slot);
            return;
        }
        self.slots[slot] = value;
        if (value != .nil) self.noteSlotPresence(slot);
    }

    pub fn rawSetNativeField(self: *Table, comptime namespace: static_fields.Namespace, comptime name: []const u8, value: Value) !void {
        if (self.native_namespace != namespace) return error.BadNativeNamespace;
        const slot = comptime static_fields.slotForName(namespace, name) orelse @compileError("unknown native namespace field: " ++ name);
        try self.rawSetSlot(slot, value);
    }

    pub fn rawGetChoice(self: *const Table, choice: u32, key: Value) ?Value {
        self.notePackageStateAccess();
        if (choice >= self.choices.len) return null;
        const cell = self.choices[choice];
        if (cell.value == .nil or !rawEqual(cell.key, key)) return null;
        return cell.value;
    }

    pub fn rawSetChoice(self: *Table, choice: u32, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        if (choice >= self.choices.len) return error.BadChoiceSlot;
        try validateTableKey(key);
        try self.markMutated();
        self.markIdentityKeyWrite(key, value);
        if (value == .nil) {
            if (rawEqual(self.choices[choice].key, key)) self.choices[choice].value = .nil;
            return;
        }
        if (!rawEqual(self.choices[choice].key, key)) self.markMapStructuralMutation();
        self.choices[choice] = .{ .key = key, .value = value };
    }
    pub fn rawGet(self: *const Table, key: Value) ?Value {
        self.notePackageStateAccess();
        if (key == .number) return self.rawGetNumber(key.number);
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        return self.rawGetAfterSlot(key);
    }

    // The caller has already resolved the structural slot. A nil slot does
    // not erase live choice/map overrides, including iterator-written nils.
    fn rawGetAfterSlot(self: *const Table, key: Value) ?Value {
        self.notePackageStateAccess();
        for (self.choices) |cell| {
            if (cell.value != .nil and rawEqual(cell.key, key)) return cell.value;
        }
        return liveValue(self.map.getContext(key, .{}));
    }

    pub fn rawGetHashedString(self: *const Table, name: []const u8, key_hash: u64) ?Value {
        self.notePackageStateAccess();
        const key = Value{ .string = name };
        if (self.slotForString(name, key_hash)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| {
            if (cell.value != .nil and rawEqual(cell.key, key)) return cell.value;
        }
        return liveValue(self.map.getAdapted(name, StringLookupContext{ .key_hash = key_hash }));
    }

    // A positive own field can be cached, but the live Value is always read.
    // A traced miss records only the nil locations already visited by this
    // lookup, so an inherited-cache fill never repeats the receiver search.
    const OwnMissWitness = struct {
        slot: ?*Value = null,
        map_value: ?*Value = null,
    };
    fn ownHashedStringValuePtr(self: *Table, name: []const u8, key_hash: u64, witness: ?*OwnMissWitness) ?*Value {
        if (self.native_namespace != null or !self.owns_slots or
            self.global_tail != null or self.choices.len != 0) return null;
        const slot = if (self.shape != null) self.slotForString(name, key_hash) else null;
        return self.ownHashedStringValuePtrAtSlot(name, key_hash, slot, witness);
    }

    // The caller proves the immutable shape lookup result. A missing/nil slot
    // still probes the live map and records witnesses for inherited lookups.
    fn ownHashedStringValuePtrAtSlot(self: *Table, name: []const u8, key_hash: u64, slot: ?u32, witness: ?*OwnMissWitness) ?*Value {
        self.notePackageStateAccess();
        if (slot) |known| {
            const value = self.slotPtr(known) orelse return null;
            if (witness) |miss| miss.slot = value;
            if (value.* != .nil) return value;
        }
        const value = self.map.getPtrAdapted(name, StringLookupContext{ .key_hash = key_hash });
        if (witness) |miss| miss.map_value = value;
        if (value) |ptr| if (ptr.* != .nil) return ptr;
        return null;
    }

    pub fn rawGetNumber(self: *const Table, number: f64) ?Value {
        self.notePackageStateAccess();
        if (self.arraySlotForNumber(number)) |slot| if (self.rawGetArraySlot(slot)) |value| return value;
        if (!self.numeric_mirror_disabled and self.numeric_mirror.len != 0) if (positiveInteger(number)) |index| if (index <= self.numeric_mirror.len) {
            const value = self.numeric_mirror[index - 1];
            return if (value == .nil) null else value;
        };
        if (self.shape == null and self.choices.len == 0)
            return if (self.has_hashed_number) liveValue(self.map.getAdapted(number, NumberLookupContext{})) else null;
        const key = Value{ .number = number };
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| {
            if (cell.value != .nil and cell.key == .number and cell.key.number == number) return cell.value;
        }
        return if (self.has_hashed_number) liveValue(self.map.getAdapted(number, NumberLookupContext{})) else null;
    }

    pub fn rawSet(self: *Table, allocator: std.mem.Allocator, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        try validateTableKey(key);
        try self.markMutated();
        self.markIdentityKeyWrite(key, value);
        if (key == .number) if (self.genericArrayIndex(key.number)) |index| {
            if (self.arraySlotForNumber(key.number)) |slot| {
                if (self.map.removeContext(key, .{})) self.markMapStructuralMutation();
                try self.rawSetArraySlot(slot, value);
                return;
            }
            if (value != .nil) if (try self.ensureGenericArraySlot(allocator, index)) |slot| {
                if (self.map.removeContext(key, .{})) self.markMapStructuralMutation();
                try self.rawSetArraySlot(slot, value);
                return;
            };
        };
        if (self.slotForKey(key)) |slot| return self.rawSetSlot(slot, value);
        for (self.choices, 0..) |cell, choice| {
            if (cell.value != .nil and rawEqual(cell.key, key))
                return self.rawSetChoice(@intCast(choice), key, value);
        }
        if (value == .nil) {
            if (self.map.getPtrContext(key, .{})) |present| {
                if (present.* != .nil) {
                    self.map_deletions_since_prune +|= 1;
                    self.markMapStructuralMutation();
                }
                present.* = .nil;
            }
            self.noteNumericMapWrite(key, value);
            return;
        }
        if (self.map.getPtrContext(key, .{})) |present| {
            if (present.* == .nil) self.markMapStructuralMutation();
            present.* = value;
            self.maybeBuildNumericMirror(allocator, key, value);
            self.noteNumericMapWrite(key, value);
            if (key == .number) self.has_hashed_number = true;
            return;
        }
        // Insertion of a new field during next traversal is unspecified by Lua.
        // Reclaim dead identities here, bounding retention to the current map.
        self.pruneDeletedMapKeys();
        const old_count = self.map.count();
        const old_capacity = self.map.capacity();
        try self.map.putContext(allocator, key, value, .{});
        if (self.map.count() != old_count or self.map.capacity() != old_capacity)
            self.markMapStructuralMutation();
        self.maybeBuildNumericMirror(allocator, key, value);
        self.noteNumericMapWrite(key, value);
        if (key == .number) self.has_hashed_number = true;
    }

    // Constant string writes use the caller's compiled hash. This follows the
    // same shape, choice, and map order as rawSet. Existing map writes never
    // rehash: changing a present value during traversal is permitted by Lua.
    pub fn rawSetHashedString(self: *Table, allocator: std.mem.Allocator, name: []const u8, key_hash: u64, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        const key = Value{ .string = name };
        try self.markMutated();
        if (self.slotForString(name, key_hash)) |slot| return self.rawSetSlot(slot, value);
        for (self.choices, 0..) |cell, choice| {
            if (cell.value != .nil and rawEqual(cell.key, key))
                return self.rawSetChoice(@intCast(choice), key, value);
        }
        const lookup = StringLookupContext{ .key_hash = key_hash };
        if (value == .nil) {
            if (self.map.getPtrAdapted(name, lookup)) |present| {
                if (present.* != .nil) {
                    self.map_deletions_since_prune +|= 1;
                    self.markMapStructuralMutation();
                }
                present.* = .nil;
            }
            return;
        }
        if (self.map.getPtrAdapted(name, lookup)) |present| {
            if (present.* == .nil) self.markMapStructuralMutation();
            present.* = value;
            return;
        }
        self.pruneDeletedMapKeys();
        const old_count = self.map.count();
        const old_capacity = self.map.capacity();
        const result = try self.map.getOrPutContextAdapted(allocator, name, lookup, ValueContext{});
        if (!result.found_existing) result.key_ptr.* = key;
        result.value_ptr.* = value;
        if (self.map.count() != old_count or self.map.capacity() != old_capacity)
            self.markMapStructuralMutation();
    }

    pub fn append(self: *Table, allocator: std.mem.Allocator, value: Value) !void {
        try self.rawSet(allocator, .{ .number = @floatFromInt(self.append_index) }, value);
        self.append_index +%= 1;
    }

    pub const Iterator = struct {
        table: *Table,
        hash: Map.Iterator,
        slot: u32 = 0,
        choice: u32 = 0,
        key: Value = .nil,
        pub const Entry = struct { key_ptr: *const Value, value_ptr: *Value };
        pub const Position = struct { slot: u32, choice: u32, hash_index: u32 };

        pub fn position(self: *const Iterator) Position {
            return .{ .slot = self.slot, .choice = self.choice, .hash_index = self.hash.index };
        }

        pub fn restorePosition(self: *Iterator, position_value: Position) bool {
            if (position_value.slot > self.table.slotCount() or position_value.choice > self.table.choices.len or position_value.hash_index > self.table.map.capacity()) return false;
            self.slot = position_value.slot;
            self.choice = position_value.choice;
            self.hash.index = position_value.hash_index;
            return true;
        }

        pub fn seekAfter(self: *Iterator, key: Value) bool {
            // Prefer a live override to an older shape/choice tombstone.
            while (self.next()) |entry| if (rawEqual(entry.key_ptr.*, key)) return true;
            self.* = self.table.iterator();
            const table = self.table;
            const slot = if (key == .number and table.shape == null and table.native_namespace == null)
                table.arraySlotForNumber(key.number)
            else
                table.slotForKey(key);
            if (slot) |index| {
                const array = (table.shape == null and table.native_namespace == null) or
                    (table.shape != null and table.shape.?.keys == .dense_array);
                if (index < table.slotCount() and (array or table.slotWasPresent(index))) {
                    self.slot = index + 1;
                    return true;
                }
            }
            self.slot = @intCast(table.slotCount());
            for (table.choices, 0..) |cell, index| if (cell.key != .nil and rawEqual(cell.key, key)) {
                self.choice = @intCast(index + 1);
                return true;
            };
            self.choice = @intCast(table.choices.len);
            while (self.hash.next()) |entry| if (rawEqual(entry.key_ptr.*, key)) return true;
            return false;
        }

        pub fn next(self: *Iterator) ?Entry {
            self.table.notePackageStateAccess();
            while (self.slot < self.table.slotCount()) {
                const index = self.slot;
                self.slot += 1;
                const value = self.table.slotPtr(index) orelse continue;
                if (value.* == .nil) continue;
                self.key = if (self.table.shape == null and self.table.native_namespace == null)
                    .{ .number = @floatFromInt(index + 1) }
                else
                    self.table.fieldKey(index) orelse continue;
                return .{ .key_ptr = &self.key, .value_ptr = value };
            }
            while (self.choice < self.table.choices.len) {
                const index = self.choice;
                self.choice += 1;
                const cell = &self.table.choices[index];
                if (cell.value == .nil) continue;
                return .{ .key_ptr = &cell.key, .value_ptr = &cell.value };
            }
            while (self.hash.next()) |entry| {
                if (entry.value_ptr.* != .nil) return .{ .key_ptr = entry.key_ptr, .value_ptr = entry.value_ptr };
            }
            return null;
        }
    };

    pub fn iterator(self: *Table) Iterator {
        self.notePackageStateAccess();
        // Iterator.Entry exposes mutable value pointers. Existing callers only
        // read them, but invalidate the auxiliary mirror before exposing one.
        if (self.allStringShape() and self.has_hashed_number) {
            self.numeric_mirror_disabled = true;
            self.dense_prefix_valid = false;
        }
        if (self.has_identity_key) markLoadDataEffect();
        return .{ .table = self, .hash = self.map.iterator() };
    }

    fn hasArrayIndex(self: *const Table, index: usize) bool {
        return self.rawGetNumber(@floatFromInt(index)) != null;
    }

    pub fn rawLen(self: *const Table) usize {
        self.notePackageStateAccess();
        if (self.allStringShape() and self.dense_prefix_valid) return self.dense_prefix_len;
        var low: usize = if (self.append_index == 0) 0 else self.append_index - 1;
        if (low != 0 and !self.hasArrayIndex(low)) {
            var high = low;
            low = 0;
            while (high - low > 1) {
                const mid = low + (high - low) / 2;
                if (self.hasArrayIndex(mid)) low = mid else high = mid;
            }
            return low;
        }
        var high = low + 1;
        while (self.hasArrayIndex(high)) {
            low = high;
            high *= 2;
        }
        while (high - low > 1) {
            const mid = low + (high - low) / 2;
            if (self.hasArrayIndex(mid)) low = mid else high = mid;
        }
        return low;
    }
};
pub fn validateTableKey(key: Value) !void {
    if (key == .nil) return error.NilTableKey;
    if (key == .number and std.math.isNan(key.number)) return error.NaNTableKey;
}

pub fn rawEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nil => true,
        .boolean => |v| v == b.boolean,
        .number => |v| v == b.number,
        .string => |v| std.mem.eql(u8, v, b.string),
        .table => |v| v == b.table,
        .callable => |v| v.identity == b.callable.identity,
    };
}

pub const lua_number_whitespace = " \t\r\n\x0b\x0c";

pub fn toNumber(value: Value) ?f64 {
    return switch (value) {
        .number => |v| v,
        .string => |v| blk: {
            const text = std.mem.trim(u8, v, lua_number_whitespace);
            if (text.len == 0) break :blk null;
            break :blk std.fmt.parseFloat(f64, text) catch null;
        },
        else => null,
    };
}

fn numberToBuffer(buffer: []u8, number: f64) ![]const u8 {
    const written = snprintf(buffer.ptr, buffer.len, "%.14g", number);
    if (written < 0) return error.NumberFormatFailed;
    const len: usize = @intCast(written);
    if (len >= buffer.len) return error.NumberFormatTooLong;
    return buffer[0..len];
}

pub fn numberToString(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    var buffer: [64]u8 = undefined;
    return allocator.dupe(u8, try numberToBuffer(&buffer, number));
}

pub fn toConcatString(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| numberToString(allocator, number),
        else => error.ConcatType,
    };
}

fn rawFreeSlice(comptime T: type, allocator: std.mem.Allocator, values: []T) void {
    if (values.len == 0) return;
    allocator.rawFree(std.mem.sliceAsBytes(values), .of(T), @returnAddress());
}

pub fn freeResults(values: []const Value) void {
    rawFreeSlice(Value, std.heap.smp_allocator, @constCast(values));
}

pub const FixedCallResult = struct {
    values: []const Value,
    owned: bool,

    pub inline fn deinit(self: FixedCallResult) void {
        if (self.owned) freeResults(self.values);
    }
};

pub inline fn returnBuffer(buffer: ?[]Value, len: usize) ![]Value {
    return if (buffer) |values| values[0..@min(values.len, len)] else std.heap.smp_allocator.alloc(Value, len);
}

pub inline fn storeReturn(result: []Value, index: usize, value: Value) void {
    if (index < result.len) result[index] = value;
}

pub inline fn copyReturnTail(result: []Value, offset: usize, tail: []const Value) void {
    if (offset >= result.len) return;
    const n = @min(result.len - offset, tail.len);
    @memcpy(result[offset..][0..n], tail[0..n]);
}
pub const NextIterationHint = struct {
    table: *Table,
    key: Value,
    position: Table.Iterator.Position,
    structural_epoch: u64,
};

threadlocal var load_data_effect_probe: ?*bool = null;
threadlocal var load_data_pending_probe: ?*bool = null;
threadlocal var module_template_effect_probe: ?*bool = null;
threadlocal var module_template_probe_id: u64 = 0;
threadlocal var module_template_probe_owner_id: u64 = 0;
threadlocal var module_template_probe_next_id: u64 = 1;
threadlocal var module_template_effect_reasons: u32 = 0;
threadlocal var module_template_probe_page_scope: bool = false;
threadlocal var module_template_library_dependencies: u64 = 0;
threadlocal var module_template_allocation_mutation_probe: ?*u64 = null;
threadlocal var module_template_dependency_probe: ?*ModuleTemplateDependencyProbe = null;
threadlocal var invoke_rollback: ?*InvokeRollbackJournal = null;
threadlocal var invoke_rollback_next_id: u64 = 1;

const InvokeTableSnapshot = struct {
    table: *Table,
    saved: Table,
    borrowed_slots: []Value = &.{},
    tail_ptr: ?*GlobalTail = null,
    tail: ?GlobalTail = null,
};

const InvokeCellBaseline = struct { cell: *Cell, value: Value };

pub const InvokeRollbackJournal = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    id: u64,
    owner_nonce: u64,
    tables: std.ArrayList(InvokeTableSnapshot) = .empty,
    previous: ?*InvokeRollbackJournal = null,

    pub fn init(allocator: std.mem.Allocator, ctx: *Context) InvokeRollbackJournal {
        const id = invoke_rollback_next_id;
        invoke_rollback_next_id +%= 1;
        if (invoke_rollback_next_id == 0) invoke_rollback_next_id = 1;
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .id = id,
            .owner_nonce = ctx.field_cache_nonce,
        };
    }

    pub fn begin(self: *InvokeRollbackJournal) void {
        self.previous = invoke_rollback;
        invoke_rollback = self;
    }

    pub fn end(self: *InvokeRollbackJournal) void {
        std.debug.assert(invoke_rollback == self);
        invoke_rollback = self.previous;
    }

    fn snapshotTable(self: *InvokeRollbackJournal, table: *Table) !void {
        if (table.invoke_rollback_owner_nonce != self.owner_nonce) return;
        if (table.invoke_rollback_allocation_id == self.id or
            table.invoke_rollback_snapshot_id == self.id)
            return;

        var saved = table.*;
        saved.map = try table.map.clone(self.allocator);
        errdefer saved.map.deinit(self.allocator);
        saved.slot_history_tail = try self.allocator.dupe(u64, table.slot_history_tail);
        errdefer self.allocator.free(saved.slot_history_tail);
        if (table.owns_slots and table.slots.len != 0)
            saved.slots = try self.allocator.dupe(Value, table.slots);
        errdefer if (table.owns_slots and saved.slots.len != 0) self.allocator.free(saved.slots);
        if (table.choices.len != 0) saved.choices = try self.allocator.dupe(ChoiceCell, table.choices);
        errdefer if (saved.choices.len != 0) self.allocator.free(saved.choices);
        if (table.numeric_mirror.len != 0)
            saved.numeric_mirror = try self.allocator.dupe(Value, table.numeric_mirror);
        errdefer if (saved.numeric_mirror.len != 0) self.allocator.free(saved.numeric_mirror);
        const borrowed_slots: []Value = if (!table.owns_slots and table.slots.len != 0)
            try self.allocator.dupe(Value, table.slots)
        else
            &.{};
        errdefer if (borrowed_slots.len != 0) self.allocator.free(borrowed_slots);
        var tail = if (table.global_tail) |value| try value.cloneState(self.allocator) else null;
        errdefer if (tail) |*value| value.deinit();
        try self.tables.append(self.allocator, .{
            .table = table,
            .saved = saved,
            .borrowed_slots = borrowed_slots,
            .tail_ptr = table.global_tail,
            .tail = tail,
        });
        table.invoke_rollback_snapshot_id = self.id;
    }

    pub fn rollback(self: *InvokeRollbackJournal, ctx: *Context) void {
        self.end();
        var table_index = self.tables.items.len;
        while (table_index != 0) {
            table_index -= 1;
            var snapshot = &self.tables.items[table_index];
            const table = snapshot.table;
            table.deinit(self.allocator);
            table.* = snapshot.saved;
            if (!table.owns_slots and snapshot.borrowed_slots.len != 0)
                @memcpy(table.slots, snapshot.borrowed_slots);
            if (snapshot.tail) |saved_tail| {
                const tail = snapshot.tail_ptr orelse unreachable;
                tail.deinit();
                tail.* = saved_tail;
                table.global_tail = tail;
                snapshot.tail = null;
            }
            ctx.assignFieldCacheIdentity(table);
            snapshot.saved.map = .empty;
            snapshot.saved.slot_history_tail = &.{};
            snapshot.saved.numeric_mirror = &.{};
            if (snapshot.saved.owns_slots) snapshot.saved.slots = &.{};
            snapshot.saved.choices = &.{};
            if (snapshot.borrowed_slots.len != 0) self.allocator.free(snapshot.borrowed_slots);
            snapshot.borrowed_slots = &.{};
        }
        self.tables.deinit(self.allocator);
        self.tables = .empty;

        // Only cloned cells survive the invoke's module-state reset. Restore
        // that owned graph, including writes inlined into compiled Lua. A
        // thread-local write hook also sees temporary loader contexts whose
        // cells can already be dead here.
        ctx.resetTemplateCloneCells();
        ctx.resetInvokeModuleState();
        // Cached closures survive this transaction. Rewinding their identity
        // allocator would make a later distinct closure compare/hash equal.
    }
};

pub fn currentInvokeRollbackId() u64 {
    return if (invoke_rollback) |journal| journal.id else 0;
}

test "invoke rollback restores identity flags before the first keyed mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    const key = Value{ .table = try ctx.newTable() };
    const fields = [_]Value{key};
    const shape = Shape{ .keys = .{ .boxed = &fields }, .field_count = 1, .open = true };
    for (0..3) |mode| {
        const table = try ctx.newTable();
        if (mode == 1) {
            table.choices = try a.alloc(ChoiceCell, 1);
            @memset(table.choices, .{});
        } else if (mode == 2) {
            table.shape = &shape;
            table.slots = try a.alloc(Value, 1);
            @memset(table.slots, .nil);
        }
        var journal = InvokeRollbackJournal.init(a, &ctx);
        journal.begin();
        switch (mode) {
            0 => try table.rawSet(a, key, .{ .number = 9 }),
            1 => try table.rawSetChoice(0, key, .{ .number = 9 }),
            else => try table.rawSetSlot(0, .{ .number = 9 }),
        }
        try std.testing.expect(table.has_identity_key);
        journal.rollback(&ctx);
        try std.testing.expect(!table.has_identity_key);
        try std.testing.expect(table.rawGet(key) == null);
    }
}

test "invoke rollback retains cell baselines after clone cache rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var child = try Context.init(a, 0);
    defer child.deinit();
    child.retain_invoke_cell_baselines = true;
    var original = Cell{ .value = .{ .number = 42 } };
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &child };
    defer clone.deinit();
    const cell = try clone.cloneCell(&original);
    child.module_template_clone_source = &source;
    child.module_template_clone_cells = clone.cells;
    clone.cells = .empty;
    var journal = InvokeRollbackJournal.init(a, &child);
    journal.begin();
    cell.value = .nil;
    // UnsupportedModuleTemplate drops memoization, not already-owned cells.
    child.module_template_clone_cells.clearRetainingCapacity();
    child.module_template_clone_tables.clearRetainingCapacity();
    child.module_template_clone_callables.clearRetainingCapacity();
    journal.rollback(&child);
    try std.testing.expect(cell.value == .number);
    try std.testing.expectEqual(@as(f64, 42), cell.value.number);
}

test "cloning another closure preserves a shared capture deliberately set to nil" {
    const Probe = struct {
        fn call(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return &.{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var child = try Context.init(a, 0);
    defer child.deinit();
    var original = Cell{ .value = .{ .number = 42 } };
    const first_source = try source.makeFunctionKnown(17, Probe.call, &.{&original});
    const second_source = try source.makeFunctionKnown(18, Probe.call, &.{&original});
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &child };
    defer clone.deinit();
    const first = try clone.cloneValue(first_source);
    const shared = try first.callable.captures().cell(0);
    shared.value = .nil;
    const second = try clone.cloneValue(second_source);
    try std.testing.expect(shared == try second.callable.captures().cell(0));
    try std.testing.expect(shared.value == .nil);
}

test "invoke rollback restores owned cloned cells after inlined writes and foreign teardown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var child = try Context.init(a, 0);
    defer child.deinit();
    child.retain_invoke_cell_baselines = true;
    const source_table = try source.newTable();
    try source_table.rawSet(a, .{ .string = "state" }, .{ .number = 7 });
    var source_cells = [_]Cell{
        .{ .value = .{ .table = source_table } },
        .{ .value = .{ .number = 42 } },
        .{ .value = .{ .string = "initial" } },
        .{ .value = .nil },
    };
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &child };
    defer clone.deinit();
    var cells: [source_cells.len]*Cell = undefined;
    for (&source_cells, &cells) |*source_cell, *cell| cell.* = try clone.cloneCell(source_cell);
    const cloned_table = cells[0].value.table;
    child.module_template_clone_source = &source;
    child.module_template_clone_tables = clone.tables;
    child.module_template_clone_cells = clone.cells;
    child.module_template_clone_callables = clone.callables;
    clone.tables = .empty;
    clone.cells = .empty;
    clone.callables = .empty;

    for (0..3) |_| {
        var journal = InvokeRollbackJournal.init(a, &child);
        journal.begin();
        // The LLVM leaf can compile these stores without calling any hook.
        for (cells) |cell| cell.value = .{ .boolean = true };
        try cloned_table.rawSet(a, .{ .string = "state" }, .{ .number = 99 });
        {
            var temporary = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer temporary.deinit();
            var foreign = try Context.init(temporary.allocator(), 0);
            defer foreign.deinit();
            const foreign_cell = try foreign.allocator.create(Cell);
            foreign_cell.* = .{ .value = .{ .number = 1 } };
            foreign_cell.value = .{ .number = 2 };
            const foreign_table = try foreign.newTable();
            try foreign_table.rawSet(foreign.allocator, .{ .string = "state" }, .{ .number = 2 });
        }
        journal.rollback(&child);
        try std.testing.expect(cells[0].value.table == cloned_table);
        try std.testing.expect(cloned_table != source_table);
        try std.testing.expectEqual(@as(f64, 7), cloned_table.rawGet(.{ .string = "state" }).?.number);
        try std.testing.expectEqual(@as(f64, 42), cells[1].value.number);
        try std.testing.expectEqualStrings("initial", cells[2].value.string);
        try std.testing.expect(cells[3].value == .nil);
        try std.testing.expectEqual(@as(f64, 7), source_table.rawGet(.{ .string = "state" }).?.number);
    }
}

pub fn noteInvokeTableMutation(table: *Table) !void {
    if (invoke_rollback) |journal| try journal.snapshotTable(table);
}

test "invoke rollback never recycles identities of retained cloned closures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var target = try Context.init(a, 0);
    defer target.deinit();
    const entry = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
    }.call;
    const original = try source.newNative(null, entry);
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target };
    defer clone.deinit();
    var journal = InvokeRollbackJournal.init(a, &target);
    journal.begin();
    const retained = try clone.cloneValue(original);
    journal.rollback(&target);
    const fresh = try target.newNative(null, entry);
    try std.testing.expect(!rawEqual(retained, fresh));
    const keys = try target.newTable();
    try keys.rawSet(a, retained, .{ .number = 1 });
    try keys.rawSet(a, fresh, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 1), keys.rawGet(retained).?.number);
    try std.testing.expectEqual(@as(f64, 2), keys.rawGet(fresh).?.number);
}

test "template tagging does not retain context markers in deeply immutable shared data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    const root = try ctx.newTable();
    const shared = try ctx.newTable();
    const nested = try ctx.newTable();
    try shared.rawSet(a, .{ .string = "nested" }, .{ .table = nested });
    shared.read_only = true;
    shared.cross_page_stable = true;
    nested.read_only = true;
    nested.cross_page_stable = true;
    try root.rawSet(a, .{ .string = "data" }, .{ .table = shared });
    var marker: u64 = 0;
    try ctx.tagModuleTemplateValue(.{ .table = root }, &marker);
    try std.testing.expect(root.module_template_mutation_probe == &marker);
    try std.testing.expect(shared.module_template_mutation_probe == null);
    try std.testing.expect(nested.module_template_mutation_probe == null);
}

test "shared invocation globals preserve large slots false and nil across module owners" {
    for ([_]usize{ 100, 129 }) |pages| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const count = module_global_prefix_len + pages * global_page_len + 3;
        const early: u32 = module_global_prefix_len + 2 * global_page_len + 7;
        const late: u32 = @intCast(count - 1);
        var ctx = try Context.initProgram(a, count, 2);
        defer ctx.deinit();
        try bindGlobalTable(&ctx, null, 0);
        const environment = ctx.global_table.?;
        try ctx.setGlobal(early, .{ .number = 42 });
        const first = try ctx.enterModule(0);
        try ctx.setGlobal(early, .nil);
        try ctx.setGlobal(late, .{ .boolean = false });
        ctx.restoreModule(first);
        const second = try ctx.enterModule(1);
        try std.testing.expect(ctx.global_table.? == environment);
        try std.testing.expect(ctx.getGlobal(0).table == environment);
        try std.testing.expect(ctx.getGlobal(early) == .nil);
        try std.testing.expect(ctx.getGlobal(late) == .boolean and !ctx.getGlobal(late).boolean);
        const late_key = @as(f64, @floatFromInt(late + 1));
        try std.testing.expect(!environment.rawGetNumber(late_key).?.boolean);
        try environment.rawSet(a, .{ .number = late_key }, .{ .number = 123 });
        try std.testing.expectEqual(@as(f64, 123), ctx.getGlobal(late).number);
        var iterator = environment.iterator();
        try std.testing.expectEqual(@as(f64, 1), iterator.next().?.key_ptr.number);
        const high = iterator.next().?;
        try std.testing.expectEqual(late_key, high.key_ptr.number);
        try std.testing.expectEqual(@as(f64, 123), high.value_ptr.number);
        try std.testing.expect(iterator.next() == null);
        ctx.restoreModule(second);
        try std.testing.expectEqual(@as(f64, 123), ctx.getGlobal(late).number);
        var independent = try ctx.forkProgram(a);
        defer independent.deinit();
        try bindGlobalTable(&independent, null, 0);
        try std.testing.expect(independent.global_table.? != environment);
        try std.testing.expect(independent.getGlobal(late) == .nil);
        try std.testing.expect(independent.getGlobal(0).table == independent.global_table.?);
    }
}

pub fn suspendInvokeRollback() ?*InvokeRollbackJournal {
    const previous = invoke_rollback;
    invoke_rollback = null;
    return previous;
}

pub fn resumeInvokeRollback(previous: ?*InvokeRollbackJournal) void {
    std.debug.assert(invoke_rollback == null);
    invoke_rollback = previous;
}

const ModuleTemplateProbeState = struct {
    previous: ?*bool,
    previous_id: u64,
    previous_owner_id: u64,
    previous_reasons: u32,
    previous_page_scope: bool,
    previous_library_dependencies: u64,
};

pub fn beginLoadDataEffectProbe(flag: *bool) ?*bool {
    const previous = load_data_effect_probe;
    load_data_effect_probe = flag;
    return previous;
}

pub fn endLoadDataEffectProbe(previous: ?*bool) void {
    load_data_effect_probe = previous;
}

pub fn markLoadDataOnlyEffect() void {
    if (load_data_effect_probe) |flag| flag.* = true;
}

pub fn markLoadDataEffect() void {
    markLoadDataOnlyEffect();
    if (module_template_effect_probe) |flag| {
        module_template_effect_reasons |= 1 << 0;
        flag.* = true;
    }
}

/// Marks state that is stable for one page but not necessarily across
/// independent invokes on that page. Page-local data caches may retain it, but
/// module-root templates must reject it unless an invoke-stability proof exists.
pub fn markPageTemplateEffect() void {
    markLoadDataOnlyEffect();
    if (module_template_effect_probe) |flag| {
        module_template_effect_reasons |= 1 << 5;
        if (!module_template_probe_page_scope) flag.* = true;
    }
}

/// Marks state that can differ between independent invokes on the same page.
/// Unlike page-stable host data, this must reject both worker-global and
/// page-scoped module-root templates.
pub fn markInvokeTemplateEffect() void {
    markLoadDataOnlyEffect();
    if (module_template_effect_probe) |flag| {
        module_template_effect_reasons |= 1 << 6;
        flag.* = true;
    }
}

fn beginModuleTemplateEffectProbe(flag: *bool, page_scope: bool) ModuleTemplateProbeState {
    const previous = module_template_effect_probe;
    const previous_id = module_template_probe_id;
    const previous_owner_id = module_template_probe_owner_id;
    const previous_reasons = module_template_effect_reasons;
    const previous_page_scope = module_template_probe_page_scope;
    const previous_library_dependencies = module_template_library_dependencies;
    const id = module_template_probe_next_id;
    module_template_probe_next_id +%= 1;
    if (module_template_probe_next_id == 0) module_template_probe_next_id = 1;
    module_template_effect_probe = flag;
    module_template_probe_id = id;
    module_template_probe_owner_id = if (previous != null) previous_owner_id else id;
    module_template_effect_reasons = 0;
    module_template_probe_page_scope = page_scope;
    module_template_library_dependencies = 0;
    return .{
        .previous = previous,
        .previous_id = previous_id,
        .previous_owner_id = previous_owner_id,
        .previous_reasons = previous_reasons,
        .previous_page_scope = previous_page_scope,
        .previous_library_dependencies = previous_library_dependencies,
    };
}

fn endModuleTemplateEffectProbe(state: ModuleTemplateProbeState, observed: bool) void {
    const observed_reasons = module_template_effect_reasons;
    module_template_effect_probe = state.previous;
    module_template_probe_id = state.previous_id;
    module_template_probe_owner_id = state.previous_owner_id;
    module_template_effect_reasons = state.previous_reasons | observed_reasons;
    module_template_probe_page_scope = state.previous_page_scope;
    module_template_library_dependencies = state.previous_library_dependencies | module_template_library_dependencies;
    if (observed) {
        if (state.previous) |flag| flag.* = true;
    }
}

inline fn noteModuleTemplateEffectReason(bit: u32) void {
    if (module_template_effect_probe != null) module_template_effect_reasons |= bit;
}

pub const ModuleTemplateProbeSuspend = struct {
    current: ?*bool,
    current_id: u64,
    current_owner_id: u64,
    current_page_scope: bool,
    current_library_dependencies: u64,
    current_reasons: u32,
};

pub fn suspendModuleTemplateEffectProbe() ModuleTemplateProbeSuspend {
    const state = ModuleTemplateProbeSuspend{
        .current = module_template_effect_probe,
        .current_id = module_template_probe_id,
        .current_owner_id = module_template_probe_owner_id,
        .current_page_scope = module_template_probe_page_scope,
        .current_library_dependencies = module_template_library_dependencies,
        .current_reasons = module_template_effect_reasons,
    };
    module_template_effect_probe = null;
    module_template_probe_id = 0;
    module_template_probe_owner_id = 0;
    module_template_probe_page_scope = false;
    module_template_library_dependencies = 0;
    module_template_effect_reasons = 0;
    return state;
}

pub fn resumeModuleTemplateEffectProbe(state: ModuleTemplateProbeSuspend) void {
    module_template_effect_probe = state.current;
    module_template_probe_id = state.current_id;
    module_template_probe_owner_id = state.current_owner_id;
    module_template_probe_page_scope = state.current_page_scope;
    module_template_library_dependencies = state.current_library_dependencies;
    module_template_effect_reasons = state.current_reasons;
}

/// Executed unknown/mutable global bindings are invocation dependencies of a
/// module initializer. This does not classify private loadData state as a host effect.
pub fn observeInvocationGlobalAccess() void {
    noteModuleTemplateEffectReason(1 << 6);
    markModuleTemplateEffect();
}

fn markModuleTemplateEffect() void {
    if (module_template_effect_probe) |flag| flag.* = true;
}

// A nested read-only dependency has not reached the worker cache yet. Do not
// promote this execution, but allow a later page to retry once it has.
pub fn beginLoadDataPendingProbe(flag: *bool) ?*bool {
    const previous = load_data_pending_probe;
    load_data_pending_probe = flag;
    return previous;
}

pub fn endLoadDataPendingProbe(previous: ?*bool) void {
    load_data_pending_probe = previous;
}

pub fn markLoadDataPending() void {
    if (load_data_pending_probe) |flag| flag.* = true;
}

const module_state_page_shift = 8;
const module_state_page_len = 1 << module_state_page_shift;
const module_state_page_mask = module_state_page_len - 1;
const ModuleTemplateOverride = struct {
    module_id: u32,
    value: Value,
};
const non_table_export_pristine = false;
const ModuleValueGuard = struct {
    valid: bool = true,
    root: ?*Table = null,
    capture_tables: []const *Table = &.{},
    capture_cells: []const InvokeCellBaseline = &.{},

    fn pristine(self: ModuleValueGuard) bool {
        if (!self.valid) return false;
        if (self.root) |root| if (!root.exportGraphPristine()) return false;
        for (self.capture_tables) |table| if (!table.exportGraphPristine()) return false;
        for (self.capture_cells) |cell| if (!rawEqual(cell.cell.value, cell.value)) return false;
        return true;
    }
};

const ModuleTemplateDependencyProbe = struct {
    ctx: *Context,
    requirements: std.ArrayList(ModuleRequirement) = .empty,

    fn record(self: *ModuleTemplateDependencyProbe, ctx: *const Context, module_id: u32, requested: []const u8) !void {
        if (self.ctx != ctx) return;
        for (self.requirements.items) |item|
            if (item.module_id == module_id and std.mem.eql(u8, item.requested, requested)) return;
        const name = try self.ctx.stringAllocator().dupe(u8, requested);
        try self.requirements.append(std.heap.smp_allocator, .{ .module_id = module_id, .requested = name });
    }
};

const ModuleState = struct {
    loading: bool = false,
    value: ?Value = null,
    preinitialized: ?Value = null,
    load_data_snapshot: ?Value = null,
    deferred_require_visibility: bool = false,
    template_package_observed: bool = false,
    template_page_scoped_only: bool = false,
    template_library_dependencies: u64 = 0,
    template_invocation_dependent: bool = false,
    template_value_guard: ModuleValueGuard = .{},
    template_origin_context: ?*const Context = null,
    template_observed_requirements: []const ModuleRequirement = &.{},
    template_init_probe_id: u64 = 0,
    template_mutation_probe_id: u64 = 0,
    template_overrides: []const ModuleTemplateOverride = &.{},
};
const ModuleStatePage = struct {
    initialized: [module_state_page_len / 64]u64 = @as([(module_state_page_len / 64)]u64, @splat(0)),
    states: [module_state_page_len]ModuleState = undefined,

    fn get(self: *ModuleStatePage, index: usize) ?*ModuleState {
        if (self.initialized[index / 64] & (@as(u64, 1) << @intCast(index % 64)) == 0) return null;
        return &self.states[index];
    }

    fn ensure(self: *ModuleStatePage, index: usize) *ModuleState {
        const mask = @as(u64, 1) << @intCast(index % 64);
        const word = &self.initialized[index / 64];
        if (word.* & mask == 0) {
            self.states[index] = .{};
            word.* |= mask;
        }
        return &self.states[index];
    }
};
const ModuleScope = struct { module_id: ?u32 };

// Nonces prevent a stale site pointer from surviving page-arena address reuse.
var next_field_cache_context_nonce: std.atomic.Value(u64) = .init(1);
fn takeFieldCacheContextNonce() u64 {
    while (true) {
        const current = next_field_cache_context_nonce.load(.monotonic);
        if (current == std.math.maxInt(u64)) return 0;
        if (next_field_cache_context_nonce.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null)
            return current;
    }
}

pub const FieldCache = extern struct {
    site_id: u64 = 0,
    context_nonce: u64 = 0,
    owner_context_nonce: u64 = 0,
    table_nonce: u64 = 0,
    table_epoch: u64 = 0,
    table: ?*Table = null,
    value: ?*Value = null,
};
pub const field_cache_entries = 4096;
// Spread nearby function IDs and field ordinals across the direct-mapped cache.
pub fn fieldCacheIndex(site_id: u64) usize {
    comptime std.debug.assert(field_cache_entries == 4096);
    return @intCast((site_id *% 0x9e3779b97f4a7c15) >> 52);
}
// A positive named slot is stable across fresh instances of one program shape.
// This cache holds only metadata, never a Value pointer from another table.
pub const ShapeSiteCache = extern struct {
    site_id: u64 = 0,
    program_generation: u64 = 0,
    shape_id: u32 = 0,
    slot: u32 = 0,
};
// The build-only bitcode imports storage supplied by the native worker. Other
// roots, including standalone core tests, own one initialized TLS provider.
// Direct declarations avoid taking a thread-local address at comptime.
const FieldCacheStorage = if (@hasDecl(@import("root"), "build_value_leaf") and
    @import("root").build_value_leaf) struct {
    extern threadlocal var dict_lua_field_cache: [field_cache_entries]FieldCache;
    extern threadlocal var dict_lua_shape_site_cache: [field_cache_entries]ShapeSiteCache;
} else struct {
    export threadlocal var dict_lua_field_cache: [field_cache_entries]FieldCache =
        @as([field_cache_entries]FieldCache, @splat(.{}));
    export threadlocal var dict_lua_shape_site_cache: [field_cache_entries]ShapeSiteCache =
        @as([field_cache_entries]ShapeSiteCache, @splat(.{}));
};

// Metadata-only cache: it holds no table or Value pointer. A matching immutable
// program shape maps this exact site to a slot; load that slot from the CURRENT
// table. Context/table identity nonces guard mutable map pointers, not this path.
pub inline fn positiveProgramShapeHit(
    ctx: *const Context,
    object: *const Value,
    site_id: u64,
    shapes: *const [field_cache_entries]ShapeSiteCache,
) ?*const Value {
    if (object.* != .table) return null;
    const table = object.table;
    if (table.native_namespace != null or !table.owns_slots or
        table.global_tail != null or table.choices.len != 0) return null;
    const shape_entry = &shapes[fieldCacheIndex(site_id)];
    if (table.shape != null and ctx.program_shape_generation != 0 and
        shape_entry.site_id == site_id and
        shape_entry.program_generation == ctx.program_shape_generation and
        shape_entry.shape_id < ctx.program_shapes.len and
        table.shape == &ctx.program_shapes[shape_entry.shape_id])
    {
        if (shape_entry.slot < table.slots.len) {
            const value = &table.slots[shape_entry.slot];
            if (value.* != .nil) return value;
        }
    }
    return null;
}

// Runtime fallback retains the full mutable-map cache and all identity guards.
// The imported read-only leaf above deliberately inlines only the shape tier.
pub inline fn positiveFieldCacheHit(
    ctx: *const Context,
    object: *const Value,
    site_id: u64,
    fields: *const [field_cache_entries]FieldCache,
    shapes: *const [field_cache_entries]ShapeSiteCache,
) ?*const Value {
    if (positiveProgramShapeHit(ctx, object, site_id, shapes)) |value| return value;
    if (object.* != .table or ctx.field_cache_nonce == 0) return null;
    const table = object.table;
    if (table.field_cache_nonce == 0 or table.native_namespace != null or
        !table.owns_slots or table.global_tail != null or table.choices.len != 0) return null;
    const entry = &fields[fieldCacheIndex(site_id)];
    if (entry.site_id != site_id or entry.context_nonce != ctx.field_cache_nonce or
        entry.owner_context_nonce != table.field_cache_owner_nonce or
        entry.table_nonce != table.field_cache_nonce or entry.table_epoch != table.field_cache_epoch or
        entry.table != table) return null;
    const value = entry.value orelse return null;
    return if (value.* == .nil) null else value;
}

// A bounded path of table-valued __index links. The path holds live locations,
// never a copied Value, and is useful across reads of one mutable receiver.
const inherited_link_limit = 3;
const inherited_site_entries = 1024;
const InheritedHop = struct {
    table: *Table,
    owner_nonce: u64,
    nonce: u64,
    epoch: u64,
    shape: ?*const Shape,
    own_slot: ?*Value,
    own_map_value: ?*Value,
    metatable: *Table,
    mt_owner_nonce: u64,
    mt_nonce: u64,
    mt_epoch: u64,
    mt_shape: ?*const Shape,
    index_value: *Value,
    parent: *Table,
};
const InheritedTerminal = struct {
    table: ?*Table = null,
    owner_nonce: u64 = 0,
    nonce: u64 = 0,
    epoch: u64 = 0,
    shape: ?*const Shape = null,
    value: ?*Value = null,
};
const InheritedSiteCache = struct {
    site_id: u64 = 0,
    context_nonce: u64 = 0,
    count: u8 = 0,
    hops: [inherited_link_limit]InheritedHop = undefined,
    terminal: InheritedTerminal = .{},
};
fn inheritedSiteIndex(site_id: u64) usize {
    return @intCast((site_id *% 0x9e3779b97f4a7c15) >> 54);
}
threadlocal var inherited_site_cache: [inherited_site_entries]InheritedSiteCache =
    @as([inherited_site_entries]InheritedSiteCache, @splat(.{}));

pub const Context = struct {
    namespace_catalog: ?*const namespace_registry.Registry = null,
    allocator: std.mem.Allocator,
    field_cache_nonce: u64 = 0,
    next_field_cache_table_nonce: u64 = 1,
    // Lua strings compare/hash by bytes; runtime concat results need ownership, not hash dedup.
    // Context-lifetime strings and immutable callable descriptors.
    string_arena: std.heap.ArenaAllocator,
    strings_use_context_allocator: bool = false,
    // Reused page-local invoke contexts can outlive the nested invoke arena
    // that owns strings reachable from a module-template graph. Those targets
    // opt in to copying cloned strings into their page-lifetime allocator.
    own_cloned_strings: bool = false,
    globals: []Value,
    root_globals: []Value,
    // Stable heap address because Context is returned and forked by value.
    global_tail: ?*GlobalTail = null,
    program_shapes: []const Shape = &.{},
    program_shapes_validated: bool = false,
    program_shape_generation: u64 = 0,
    frame_args_shape_id: ?u32 = null,
    package_loaded_shape_id: ?u32 = null,
    package_loaded_module_slots: []const u32 = &.{},
    // Immutable inverse of the compiler's canonical package slots. Dynamic
    // require can reuse its actual package lookup instead of resolving the
    // same canonical name again through the program's module-name index.
    package_loaded_slot_modules: []const u32 = &.{},
    json_object_shape_id: ?u32 = null,
    uri_query_shape_id: ?u32 = null,
    module_export_shape_ids: []const u32 = &.{},
    module_root_entries: []const FunctionFn = &.{},
    function_module_ids: []const u32 = &.{},
    string_metatable: ?*Table = null,
    last_error: Value = .nil,
    last_error_present: bool = false,
    aot_error_name: StableErrorName = .{},
    depth: usize = 0,
    max_depth: usize = 1000,
    next_identity: u32 = 1,
    module_count: usize = 0,
    module_state_pages: []?*ModuleStatePage = &.{},
    module_lookup_ctx: ?*const anyopaque = null,
    module_lookup: ?ModuleLookupFn = null,
    module_name: ?ModuleNameFn = null,
    module_load_error: ?ModuleLoadErrorFn = null,
    module_requirements_ctx: ?*const anyopaque = null,
    module_requirements: ?ModuleRequirementsFn = null,
    static_module_ctx: ?*const anyopaque = null,
    static_module: ?StaticModuleFn = null,
    module_template_context: ?*Context = null,
    module_template_eligible: []bool = &.{},
    module_template_rejected: []bool = &.{},
    // Reuse one source→child graph mapping for the lifetime of a fresh Context.
    // A #invoke can load many modules from the same template graph; rebuilding
    // these maps for every require both reallocates and reclones shared
    // dependency objects.
    module_template_clone_source: ?*Context = null,
    module_template_clone_tables: std.AutoHashMapUnmanaged(*Table, *Table) = .empty,
    module_template_clone_cells: std.AutoHashMapUnmanaged(*Cell, *Cell) = .empty,
    module_template_clone_callables: std.AutoHashMapUnmanaged(*const FunctionValue, *const FunctionValue) = .empty,
    // Transaction-owned capture baselines are not clone lookup-cache entries.
    // Cache rejection may discard mappings while earlier closures stay live.
    // Store the cloned target value, never a pointer into the source context.
    retain_invoke_cell_baselines: bool = false,
    invoke_cell_baselines: std.ArrayList(InvokeCellBaseline) = .empty,
    template_native_namespaces: [native_namespace_count]?*Table = @splat(null),
    // Type metatables are context singletons too. Lua may capture private
    // methods such as a title's __lt, which has no public namespace alias.
    template_native_metatables: [native_namespace_count]?*Table = @splat(null),
    module_template_page_scope: bool = false,
    page_stable_host_effects: bool = false,
    eager_bootstrap: bool = false,
    template_library_installation_closed: bool = false,
    package_observable: bool = false,
    program_bootstrap_ctx: ?*const anyopaque = null,
    program_bootstrap: ?ProgramBootstrapFn = null,
    host: ?*anyopaque = null,
    current_frame: ?*Table = null,
    package_loaded: ?*Table = null,
    package_loaded_tail: ?*GlobalTail = null,
    // Lua's base pairs() closes over the builtin next iterator. Rebinding the
    // global name `next` must not change the iterator returned by pairs().
    builtin_next: Value = .nil,
    global_table: ?*Table = null,
    root_global_table: ?*Table = null,
    global_env_slot: ?u32 = null,
    active_module_id: ?u32 = null,
    static_module_scopes: std.ArrayList(ModuleScope) = .empty,
    next_iteration_hint: ?NextIterationHint = null,
    // Borrowed program-owned immutable Unicode pattern metadata cache.
    ustring_pattern_cache: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, global_count: usize) !Context {
        return initProgram(allocator, global_count, 0);
    }

    pub fn initProgram(allocator: std.mem.Allocator, global_count: usize, module_count: usize) !Context {
        const globals = try allocator.alloc(Value, global_count);
        errdefer allocator.free(globals);
        @memset(globals, .nil);
        const page_count = (module_count + module_state_page_len - 1) / module_state_page_len;
        const module_state_pages = try allocator.alloc(?*ModuleStatePage, page_count);
        errdefer allocator.free(module_state_pages);
        @memset(module_state_pages, null);
        return .{
            .allocator = allocator,
            .namespace_catalog = if (@import("builtin").is_test) try namespace_registry.englishTestRegistry() else null,
            .field_cache_nonce = takeFieldCacheContextNonce(),
            .string_arena = .init(allocator),
            .globals = globals,
            .root_globals = globals,
            .module_count = module_count,
            .module_state_pages = module_state_pages,
        };
    }

    pub fn forkProgram(self: *const Context, allocator: std.mem.Allocator) !Context {
        var child = try initProgram(allocator, self.root_globals.len, self.module_count);
        child.namespace_catalog = self.namespace_catalog;
        child.ustring_pattern_cache = self.ustring_pattern_cache;
        child.program_shapes = self.program_shapes;
        child.program_shapes_validated = self.program_shapes_validated;
        child.program_shape_generation = self.program_shape_generation;
        child.frame_args_shape_id = self.frame_args_shape_id;
        child.package_loaded_shape_id = self.package_loaded_shape_id;
        child.package_loaded_module_slots = self.package_loaded_module_slots;
        child.package_loaded_slot_modules = self.package_loaded_slot_modules;
        child.json_object_shape_id = self.json_object_shape_id;
        child.uri_query_shape_id = self.uri_query_shape_id;
        child.module_export_shape_ids = self.module_export_shape_ids;
        child.module_root_entries = self.module_root_entries;
        child.function_module_ids = self.function_module_ids;
        child.module_lookup_ctx = self.module_lookup_ctx;
        child.module_lookup = self.module_lookup;
        child.module_name = self.module_name;
        child.module_load_error = self.module_load_error;
        child.module_requirements_ctx = self.module_requirements_ctx;
        child.module_requirements = self.module_requirements;
        child.static_module_ctx = self.static_module_ctx;
        child.static_module = self.static_module;
        child.module_template_context = self.module_template_context;
        child.module_template_eligible = self.module_template_eligible;
        child.module_template_rejected = self.module_template_rejected;
        child.module_template_page_scope = self.module_template_page_scope;
        child.page_stable_host_effects = self.page_stable_host_effects;
        child.program_bootstrap_ctx = self.program_bootstrap_ctx;
        child.program_bootstrap = self.program_bootstrap;
        child.max_depth = self.max_depth;
        child.host = self.host;
        return child;
    }

    // Opt in only when the caller bulk-reclaims allocator after this Context.
    // Strings and callable descriptors remain live until that owner exits.
    pub fn useContextAllocatorForStrings(self: *Context) void {
        self.strings_use_context_allocator = true;
    }

    pub fn ownClonedStrings(self: *Context) void {
        self.own_cloned_strings = true;
    }

    fn stringAllocator(self: *Context) std.mem.Allocator {
        return if (self.strings_use_context_allocator) self.allocator else self.string_arena.allocator();
    }

    /// Installation-only: finish every library field and alias before exposing
    /// this Context to Lua. Never use this to reseal user-modified libraries.
    pub fn finishLibraryInstallation(self: *Context) void {
        if (self.template_library_installation_closed) return;
        for (self.template_native_namespaces) |table| {
            if (table) |library| library.template_native_baseline_pristine = true;
        }
        for (self.template_native_metatables) |table| {
            if (table) |metatable| metatable.template_native_baseline_pristine = true;
        }
    }

    pub fn registerNativeMetatable(self: *Context, namespace: NativeNamespace, table: *Table) void {
        self.template_native_metatables[@backingInt(namespace)] = table;
        table.native_metatable_namespace = namespace;
        table.module_template_mutation_probe = null;
        table.module_template_probe_id = 0;
    }

    fn nativeMetatableIndex(self: *const Context, table: *const Table) ?usize {
        const namespace = table.native_metatable_namespace orelse return null;
        const index = @backingInt(namespace);
        return if (self.template_native_metatables[index] == table) index else null;
    }

    fn findTemplateNativeNamespace(
        self: *const Context,
        namespace: static_fields.Namespace,
    ) ?*Table {
        if (!templateSingletonNamespace(namespace)) return null;
        if (self.template_native_namespaces[@backingInt(namespace)]) |table| return table;
        var pending: [96]*Table = undefined;
        var pending_len: usize = 0;
        var seen: [96]*Table = undefined;
        var seen_len: usize = 0;

        for (self.root_globals) |value| {
            if (value != .table or value.table.native_namespace == null) continue;
            if (pending_len == pending.len) return null;
            pending[pending_len] = value.table;
            pending_len += 1;
        }

        while (pending_len != 0) {
            pending_len -= 1;
            const table = pending[pending_len];
            var duplicate = false;
            for (seen[0..seen_len]) |existing| {
                if (existing == table) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            if (seen_len == seen.len) return null;
            seen[seen_len] = table;
            seen_len += 1;

            if (table.native_namespace == namespace) return table;
            if (table.native_namespace == null) continue;
            for (table.slots) |value| {
                if (value != .table or value.table.native_namespace == null) continue;
                if (pending_len == pending.len) return null;
                pending[pending_len] = value.table;
                pending_len += 1;
            }
        }
        return null;
    }

    // The four mw.site namespace maps share one native layout, but each has
    // a different identity and membership. Rebind captures by their site field,
    // never by the last table installed for the namespace_map layout.
    fn findTemplateNamespaceMap(self: *const Context, source: *const Context, source_table: *const Table) ?*Table {
        const source_site = source.findTemplateNativeNamespace(.site) orelse return null;
        const target_site = self.findTemplateNativeNamespace(.site) orelse return null;
        for ([_][]const u8{ "namespaces", "subjectNamespaces", "talkNamespaces", "contentNamespaces" }) |name| {
            const source_value = source_site.rawGet(.{ .string = name }) orelse continue;
            if (source_value != .table or source_value.table != source_table) continue;
            const target_value = target_site.rawGet(.{ .string = name }) orelse return null;
            if (target_value != .table or target_value.table.native_namespace != .namespace_map) return null;
            return target_value.table;
        }
        return null;
    }

    fn seedModuleTemplateNativeAliases(
        self: *Context,
        source: *Context,
    ) !void {
        // package.loaded is a context singleton but, when the program supplies
        // a structural shape for it, it is intentionally not a native-
        // namespace table. Module roots commonly capture `package.loaded` in a
        // local. Remap that capture to the fresh Context instead of attempting
        // to clone the source package table and its context-bound callables.
        if (source.package_loaded) |source_loaded| if (self.package_loaded) |target_loaded|
            try self.module_template_clone_tables.put(
                self.allocator,
                source_loaded,
                target_loaded,
            );

        if (source.root_globals.len == self.root_globals.len) {
            for (source.root_globals, self.root_globals) |source_value, target_value| {
                if (source_value == .table and target_value == .table and
                    source_value.table.native_namespace == target_value.table.native_namespace)
                {
                    try self.module_template_clone_tables.put(
                        self.allocator,
                        source_value.table,
                        target_value.table,
                    );
                } else if (source_value == .callable and target_value == .callable and
                    source_value.callable.id == target_value.callable.id and
                    source_value.callable.entry == target_value.callable.entry)
                {
                    try self.module_template_clone_callables.put(
                        self.allocator,
                        source_value.callable,
                        target_value.callable,
                    );
                }
            }
        }

        inline for (std.enums.values(static_fields.Namespace)) |namespace| {
            if (comptime templateSingletonNamespace(namespace)) {
                if (source.findTemplateNativeNamespace(namespace)) |source_table| {
                    if (self.findTemplateNativeNamespace(namespace)) |target_table| {
                        if (source_table.slots.len == target_table.slots.len) {
                            try self.module_template_clone_tables.put(
                                self.allocator,
                                source_table,
                                target_table,
                            );
                            for (source_table.slots, target_table.slots) |source_value, target_value| {
                                if (source_value != .callable or target_value != .callable or
                                    source_value.callable.id != native_function_id or
                                    target_value.callable.id != native_function_id or
                                    source_value.callable.entry != target_value.callable.entry)
                                    continue;
                                try self.module_template_clone_callables.put(
                                    self.allocator,
                                    source_value.callable,
                                    target_value.callable,
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn deinit(self: *Context) void {
        self.invoke_cell_baselines.deinit(self.allocator);
        self.module_template_clone_tables.deinit(self.allocator);
        self.module_template_clone_cells.deinit(self.allocator);
        self.module_template_clone_callables.deinit(self.allocator);
        self.static_module_scopes.deinit(self.allocator);
        for (self.module_state_pages) |page| if (page) |owned|
            self.allocator.destroy(owned);
        self.allocator.free(self.module_state_pages);
        if (self.package_loaded_tail) |tail| {
            tail.deinit();
            self.allocator.destroy(tail);
        }
        if (self.root_global_table) |table| {
            table.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.allocator.free(self.root_globals);
        self.string_arena.deinit();
    }

    pub fn setHost(self: *Context, host: ?*anyopaque) void {
        self.host = host;
    }

    pub fn setLuaError(self: *Context, value: Value) void {
        self.last_error = value;
        self.last_error_present = true;
    }

    pub fn clearLuaError(self: *Context) void {
        self.last_error = .nil;
        self.last_error_present = false;
    }

    pub fn setAotErrorName(self: *Context, name: []const u8) void {
        self.aot_error_name.set(name);
    }

    pub fn clearAotErrorName(self: *Context) void {
        self.aot_error_name.clear();
    }

    pub fn aotErrorName(self: *const Context) ?[]const u8 {
        return self.aot_error_name.get();
    }

    pub fn adoptFailure(self: *Context, child: *const Context) !void {
        if (child.last_error == .string) {
            self.last_error = .{ .string = try self.allocator.dupe(u8, child.last_error.string) };
            self.last_error_present = child.last_error_present;
        } else {
            // A nil payload has no ownership boundary. Other non-string
            // values may refer to the child's arena and remain unadopted.
            self.last_error = .nil;
            self.last_error_present = child.last_error_present and child.last_error == .nil;
        }
        if (child.aotErrorName()) |name| {
            self.setAotErrorName(name);
        } else {
            self.clearAotErrorName();
        }
    }

    pub fn getGlobal(self: *const Context, slot: u32) Value {
        if (slot < self.globals.len) return self.globals[slot];
        const tail = self.global_tail orelse return .nil;
        const value = tail.ptr(slot - self.globals.len) orelse return .nil;
        return value.*;
    }

    pub fn setGlobal(self: *Context, slot: u32, value: Value) !void {
        if (self.global_table) |table| try noteInvokeTableMutation(table);
        if (value == .nil and self.getGlobal(slot) != .nil) if (self.global_table) |table| table.noteSlotPresence(slot);
        if (slot < self.globals.len) {
            self.globals[slot] = value;
            if (value != .nil) if (self.global_table) |table| table.noteSlotPresence(slot);
            return;
        }
        const tail = self.global_tail orelse return error.BadGlobalSlot;
        try tail.set(slot - self.globals.len, value);
        if (value != .nil) if (self.global_table) |table| table.noteSlotPresence(slot);
    }

    fn retainInvokeCellBaseline(self: *Context, cell: *Cell) !void {
        if (self.retain_invoke_cell_baselines)
            try self.invoke_cell_baselines.append(self.allocator, .{ .cell = cell, .value = cell.value });
    }

    fn resetTemplateCloneCells(self: *Context) void {
        for (self.invoke_cell_baselines.items) |baseline|
            baseline.cell.value = baseline.value;
    }

    fn resetInvokeModuleState(self: *Context) void {
        for (self.module_state_pages) |page| if (page) |states| {
            for (states.initialized, 0..) |word, word_index| {
                var remaining = word;
                while (remaining != 0) {
                    const slot = word_index * 64 + @as(usize, @intCast(@ctz(remaining)));
                    remaining &= remaining - 1;
                    const state = &states.states[slot];
                    state.* = .{};
                }
            }
        };
        self.globals = self.root_globals;
        self.global_table = self.root_global_table;
        self.global_tail = if (self.root_global_table) |table| table.global_tail else null;
        self.package_observable = false;
        self.current_frame = null;
        self.depth = 0;
        self.active_module_id = null;
        self.static_module_scopes.clearRetainingCapacity();
        self.next_iteration_hint = null;
        self.clearLuaError();
        self.clearAotErrorName();
    }
    fn takeFunctionIdentity(self: *Context) !u32 {
        const identity = self.next_identity;
        if (identity == 0) return error.FunctionIdentityExhausted;
        self.next_identity +%= 1;
        return identity;
    }
    fn storeFunction(self: *Context, function: FunctionValue) !Value {
        const descriptor = try self.stringAllocator().create(FunctionValue);
        descriptor.* = function;
        return .{ .callable = descriptor };
    }

    pub fn makeFunction(self: *Context, id: u32, entry: FunctionFn, captures: []const *Cell) !Value {
        const identity = try self.takeFunctionIdentity();
        if (captures.len == 0)
            return self.storeFunction(.{ .id = id, .identity = identity, .entry = entry });
        // Keep the descriptor, environment, and copied capture pointers in
        // one stable allocation. The cells themselves stay shared and mutable.
        const CapturedFunction = struct { function: FunctionValue, env: Env };
        const capture_bytes = std.math.mul(usize, captures.len, @sizeOf(*Cell)) catch return error.OutOfMemory;
        const total_bytes = std.math.add(usize, @sizeOf(CapturedFunction), capture_bytes) catch return error.OutOfMemory;
        const bytes = try self.stringAllocator().alignedAlloc(u8, .of(CapturedFunction), total_bytes);
        const record: *CapturedFunction = @ptrCast(bytes.ptr);
        const capture_ptr: [*]*Cell = @ptrCast(@alignCast(bytes.ptr + @sizeOf(CapturedFunction)));
        const owned = capture_ptr[0..captures.len];
        @memcpy(owned, captures);
        record.env = .{
            .captures = owned,
            .capture_view = .{ .direct = owned },
        };
        record.function = .{
            .id = id,
            .env = FunctionEnv.closure(&record.env),
            .identity = identity,
            .entry = entry,
        };
        return .{ .callable = &record.function };
    }

    pub fn makeFunctionKnown(self: *Context, id: u32, comptime entry: DirectFunctionFn, captures: []const *Cell) !Value {
        return self.makeFunction(id, stabilize(entry), captures);
    }

    pub fn callEntryBuffered(self: *Context, entry: FunctionFn, captures: Captures, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        const result = entry(
            self,
            &captures,
            args.ptr,
            args.len,
            if (result_buffer) |values| values.ptr else null,
            if (result_buffer) |values| values.len else 0,
        );
        if (result.reserved != 0 or result.status > 1) return error.BadAotFunctionResult;
        if (result.status == 1) {
            switch (captures) {
                .native => work_stats.noteNativeFailure(@intFromPtr(entry), self.aotErrorName() orelse "AotCallFailed"),
                .direct => {},
            }
            if (self.aotErrorName() == null) self.setAotErrorName("AotCallFailed");
            return error.AotCallFailed;
        }
        if (result.values_len == 0) return &.{};
        const values_ptr = result.values_ptr orelse return error.BadAotFunctionResult;
        return values_ptr[0..result.values_len];
    }

    pub fn callEntry(self: *Context, entry: FunctionFn, captures: Captures, args: []const Value) anyerror![]const Value {
        return self.callEntryBuffered(entry, captures, args, null);
    }

    pub fn callFunctionBuffered(self: *Context, value: *const FunctionValue, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (value.id == native_function_id) return self.callEntryBuffered(value.entry, value.captures(), args, result_buffer);
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        const previous = try self.enterFunctionModule(value.id);
        defer if (previous) |scope| self.restoreModule(scope);
        return self.callEntryBuffered(value.entry, value.captures(), args, result_buffer);
    }

    pub fn callFunction(self: *Context, value: *const FunctionValue, args: []const Value) anyerror![]const Value {
        return self.callFunctionBuffered(value, args, null);
    }

    pub fn callStaticFunctionBuffered(self: *Context, module_id: u32, entry: FunctionFn, captures: []const *Cell, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        if (module_id == std.math.maxInt(u32))
            return self.callEntryBuffered(entry, .{ .direct = captures }, args, result_buffer);
        const previous = try self.enterModule(module_id);
        defer self.restoreModule(previous);
        return self.callEntryBuffered(entry, .{ .direct = captures }, args, result_buffer);
    }

    pub inline fn callDirectFunction(self: *Context, value: FunctionValue, direct: DirectFunctionFn, args: []const Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        const previous = try self.enterFunctionModule(value.id);
        defer if (previous) |scope| self.restoreModule(scope);
        return direct(self, value.captures(), args);
    }

    pub inline fn callBufferedDirectFunction(self: *Context, value: FunctionValue, direct: BufferedDirectFunctionFn, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        const previous = try self.enterFunctionModule(value.id);
        defer if (previous) |scope| self.restoreModule(scope);
        return direct(self, value.captures(), args, result_buffer);
    }

    pub fn configureProgramBootstrap(self: *Context, raw: ?*const anyopaque, bootstrap: ProgramBootstrapFn) void {
        self.program_bootstrap_ctx = raw;
        self.program_bootstrap = bootstrap;
    }

    pub fn bootstrapProgram(self: *Context) !bool {
        const bootstrap = self.program_bootstrap orelse return false;
        try bootstrap(self.program_bootstrap_ctx, self);
        return true;
    }

    pub fn configureModules(self: *Context, host: ?*const anyopaque, lookup: ModuleLookupFn, name: ModuleNameFn) void {
        self.module_lookup_ctx = host;
        self.module_lookup = lookup;
        self.module_name = name;
        self.module_load_error = null;
    }

    pub fn configureModuleLoadErrors(self: *Context, load_error: ModuleLoadErrorFn) void {
        self.module_load_error = load_error;
    }

    pub fn checkModuleLoadError(self: *Context, module_id: u32) !void {
        const lookup = self.module_load_error orelse return;
        const diagnostic = lookup(self.module_lookup_ctx, module_id) orelse return;
        try checkExecutionBudget(self);
        self.setLuaError(.{ .string = diagnostic });
        return error.LuaRaised;
    }

    pub fn configureModuleRequirements(
        self: *Context,
        host: ?*const anyopaque,
        requirements: ModuleRequirementsFn,
    ) void {
        self.module_requirements_ctx = host;
        self.module_requirements = requirements;
    }

    pub fn configureFunctionModules(self: *Context, module_ids: []const u32) void {
        self.function_module_ids = module_ids;
    }

    pub fn configureStaticModules(self: *Context, host: ?*const anyopaque, loader: StaticModuleFn) void {
        self.static_module_ctx = host;
        self.static_module = loader;
    }

    pub fn preinitializeSpecialModule(self: *Context, module_id: u32, snapshot_load_data: bool) !void {
        const load = self.static_module orelse return error.MissingStaticModuleLoader;
        var value = (try load(self.static_module_ctx, self, module_id)) orelse
            return error.ModuleNotSpecial;
        if (value == .nil) value = .{ .boolean = true };
        try self.preinitializeModule(module_id, value, snapshot_load_data);
    }

    pub fn beginEagerBootstrap(self: *Context) void {
        self.eager_bootstrap = true;
    }

    pub fn endEagerBootstrap(self: *Context) void {
        self.eager_bootstrap = false;
    }

    pub fn observePackage(self: *Context) !void {
        noteModuleTemplateEffectReason(1 << 3);
        if (self.package_observable) return;
        for (self.module_state_pages, 0..) |page, page_index| if (page) |states| {
            for (states.initialized, 0..) |word, word_index| {
                var remaining = word;
                while (remaining != 0) {
                    const slot = word_index * 64 + @as(usize, @intCast(@ctz(remaining)));
                    remaining &= remaining - 1;
                    const state = &states.states[slot];
                    if (!state.deferred_require_visibility) continue;
                    const module_id_usize = (page_index << module_state_page_shift) | slot;
                    if (module_id_usize >= self.module_count) continue;
                    const loaded = self.package_loaded orelse continue;
                    const module_id: u32 = @intCast(module_id_usize);
                    const value = state.value orelse state.preinitialized orelse continue;
                    const name = self.canonicalModuleName(module_id, null) orelse continue;
                    try self.rawSetRuntimeBookkeeping(loaded, .{ .string = name }, value);
                    state.deferred_require_visibility = false;
                }
            }
        };
        self.package_observable = true;
    }

    /// Runtime-only cache writes must not make an otherwise reusable module
    /// root look effectful. User-visible writes still flow through ordinary
    /// table mutation paths and are observed by the active promotion probe.
    pub fn rawSetRuntimeBookkeeping(
        self: *Context,
        table: *Table,
        key: Value,
        value: Value,
    ) !void {
        const suspended = suspendModuleTemplateEffectProbe();
        defer resumeModuleTemplateEffectProbe(suspended);
        try table.rawSet(self.allocator, key, value);
    }

    // These scopes cover only runtime cache observations, never module roots
    // or user code. Explicit Lua reads retain the ordinary table read probe.
    pub fn rawGetRuntimeBookkeeping(table: *const Table, key: Value) ?Value {
        const suspended = suspendModuleTemplateEffectProbe();
        defer resumeModuleTemplateEffectProbe(suspended);
        return table.rawGet(key);
    }

    fn rawGetSlotRuntimeBookkeeping(table: *const Table, slot: u32) ?Value {
        const suspended = suspendModuleTemplateEffectProbe();
        defer resumeModuleTemplateEffectProbe(suspended);
        return table.rawGetSlot(slot);
    }

    fn rawGetAfterSlotRuntimeBookkeeping(table: *const Table, key: Value) ?Value {
        const suspended = suspendModuleTemplateEffectProbe();
        defer resumeModuleTemplateEffectProbe(suspended);
        return table.rawGetAfterSlot(key);
    }

    fn packageLoadedModuleGet(self: *const Context, module_id: u32, requested: ?[]const u8) ?Value {
        const suspended = suspendModuleTemplateEffectProbe();
        defer resumeModuleTemplateEffectProbe(suspended);
        const loaded = self.package_loaded orelse return null;
        if (module_id < self.package_loaded_module_slots.len and self.program_shapes_validated) {
            if (self.package_loaded_shape_id) |shape_id| if (shape_id < self.program_shapes.len and
                loaded.shape == &self.program_shapes[shape_id])
            {
                const slot = self.package_loaded_module_slots[module_id];
                if (slot != std.math.maxInt(u32)) {
                    if (loaded.rawGetSlot(slot)) |value| return value;
                    const canonical = self.canonicalModuleName(module_id, requested) orelse return null;
                    return loaded.rawGetAfterSlot(.{ .string = canonical });
                }
            };
        }
        const canonical = self.canonicalModuleName(module_id, requested) orelse return null;
        return loaded.rawGet(.{ .string = canonical });
    }

    fn packageLoadedModuleSet(self: *Context, module_id: u32, requested: ?[]const u8, value: Value) !void {
        const loaded = self.package_loaded orelse return;
        if (module_id < self.package_loaded_module_slots.len and self.program_shapes_validated) {
            if (self.package_loaded_shape_id) |shape_id| if (shape_id < self.program_shapes.len and
                loaded.shape == &self.program_shapes[shape_id])
            {
                const slot = self.package_loaded_module_slots[module_id];
                if (slot != std.math.maxInt(u32)) {
                    const suspended = suspendModuleTemplateEffectProbe();
                    defer resumeModuleTemplateEffectProbe(suspended);
                    try loaded.rawSetSlot(slot, value);
                    return;
                }
            };
        }
        if (self.module_name) |name| if (name(self.module_lookup_ctx, module_id)) |canonical| {
            try self.rawSetRuntimeBookkeeping(loaded, .{ .string = canonical }, value);
            return;
        };
        try self.packageLoadedRequestedSet(requested orelse return, value);
    }

    fn packageLoadedRequestedSet(self: *Context, requested: []const u8, value: Value) !void {
        const loaded = self.package_loaded orelse return;
        // Match rawSet's destination: slots retain no key, choices replace
        // their key, and existing map entries retain theirs (including nil).
        const suspended = suspendModuleTemplateEffectProbe();
        defer resumeModuleTemplateEffectProbe(suspended);
        const key = Value{ .string = requested };
        const retained: Value = blk: {
            if (value == .nil or loaded.slotForKey(key) != null) break :blk key;
            for (loaded.choices) |cell| {
                if (cell.value != .nil and rawEqual(cell.key, key)) break :blk cell.key;
            }
            if (loaded.map.getPtrContext(key, .{}) != null) break :blk key;
            // The request may belong to a shorter-lived loadData child/caller.
            break :blk .{ .string = try self.ownString(requested) };
        };
        try self.rawSetRuntimeBookkeeping(loaded, retained, value);
    }

    pub fn deferStaticRequireRef(self: *Context, module_id: u32, out: *Value) ?*const bool {
        // The existing fallthrough records the exact require in the root probe.
        // This pointer-only ABI cannot report allocation failure for that record.
        if (module_template_dependency_probe != null) return null;
        if (self.package_observable) return null;
        const state = self.moduleState(module_id) orelse return null;
        const value = state.value orelse state.preinitialized orelse return null;
        if (!value.truthy()) return null;
        if (self.packageLoadedModuleGet(module_id, null)) |visible|
            if (!rawEqual(visible, value)) return null;
        if (!self.eager_bootstrap) state.deferred_require_visibility = true;
        out.* = value;
        if (value == .table and value.table.export_pristine and !state.template_value_guard.pristine())
            return &non_table_export_pristine;
        return if (value == .table) &value.table.export_pristine else &non_table_export_pristine;
    }

    pub fn moduleValueSentinel(self: *const Context, module_id: u32, value: Value) ?*const bool {
        const state = self.moduleStateConst(module_id) orelse return null;
        const expected = state.value orelse state.preinitialized orelse return null;
        if (!rawEqual(value, expected) or value != .table) return null;
        if (value.table.export_pristine and !state.template_value_guard.pristine()) return &non_table_export_pristine;
        return &value.table.export_pristine;
    }

    pub fn deferStaticRequire(self: *Context, module_id: u32) ?Value {
        var value: Value = undefined;
        _ = self.deferStaticRequireRef(module_id, &value) orelse return null;
        return value;
    }

    fn canonicalModuleName(self: *const Context, module_id: u32, requested: ?[]const u8) ?[]const u8 {
        if (self.module_name) |name| if (name(self.module_lookup_ctx, module_id)) |text| return text;
        return requested;
    }

    fn moduleState(self: *Context, module_id: u32) ?*ModuleState {
        if (module_id >= self.module_count) return null;
        const page_index: usize = @as(usize, module_id) >> module_state_page_shift;
        const page = self.module_state_pages[page_index] orelse return null;
        return page.get(@as(usize, module_id) & module_state_page_mask);
    }

    fn moduleStateConst(self: *const Context, module_id: u32) ?*const ModuleState {
        if (module_id >= self.module_count) return null;
        const page_index: usize = @as(usize, module_id) >> module_state_page_shift;
        const page = self.module_state_pages[page_index] orelse return null;
        return page.get(@as(usize, module_id) & module_state_page_mask);
    }

    fn ensureModuleState(self: *Context, module_id: u32) !*ModuleState {
        if (module_id >= self.module_count) return error.BadModuleId;
        const page_index: usize = @as(usize, module_id) >> module_state_page_shift;
        if (self.module_state_pages[page_index] == null) {
            const page = try self.allocator.create(ModuleStatePage);
            page.initialized = @as([(module_state_page_len / 64)]u64, @splat(0));
            self.module_state_pages[page_index] = page;
        }
        return self.module_state_pages[page_index].?.ensure(@as(usize, module_id) & module_state_page_mask);
    }

    fn moduleForFunction(self: *const Context, function_id: u32) ?u32 {
        if (function_id >= self.function_module_ids.len) return null;
        const module_id = self.function_module_ids[function_id];
        return if (module_id < self.module_count) module_id else null;
    }

    fn enterModule(self: *Context, module_id: u32) !ModuleScope {
        if (module_id >= self.module_count) return error.BadModuleId;
        self.template_library_installation_closed = true;
        const previous = ModuleScope{ .module_id = self.active_module_id };
        // Required modules share the active invocation's globals. Defining
        // module identity remains call metadata, not environment ownership.
        self.active_module_id = module_id;
        return previous;
    }

    fn enterFunctionModule(self: *Context, function_id: u32) !?ModuleScope {
        const module_id = self.moduleForFunction(function_id) orelse return null;
        return try self.enterModule(module_id);
    }

    fn restoreModule(self: *Context, previous: ModuleScope) void {
        self.active_module_id = previous.module_id;
    }

    pub fn enterLocalStaticFunction(self: *Context) !void {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
    }

    pub fn leaveLocalStaticFunction(self: *Context) void {
        if (self.depth != 0) self.depth -= 1;
    }

    pub fn enterStaticModule(self: *Context, module_id: u32) !void {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        errdefer self.depth -= 1;
        const previous = try self.enterModule(module_id);
        errdefer self.restoreModule(previous);
        try self.static_module_scopes.append(self.allocator, previous);
    }

    pub fn leaveStaticFunction(self: *Context) void {
        if (self.static_module_scopes.pop()) |previous| self.restoreModule(previous);
        if (self.depth != 0) self.depth -= 1;
    }

    fn cloneSnapshotValue(
        self: *Context,
        value: Value,
        seen: *std.AutoHashMapUnmanaged(*Table, *Table),
    ) anyerror!Value {
        if (value != .table) return value;
        if (seen.get(value.table)) |existing| return .{ .table = existing };
        const copy = try self.allocator.create(Table);
        copy.* = .{ .module_template_probe_id = module_template_probe_owner_id };
        try seen.put(self.allocator, value.table, copy);
        var it = value.table.iterator();
        while (it.next()) |entry| {
            const key = try self.cloneSnapshotValue(entry.key_ptr.*, seen);
            const item = try self.cloneSnapshotValue(entry.value_ptr.*, seen);
            try copy.rawSet(self.allocator, key, item);
        }
        copy.append_index = value.table.append_index;
        if (value.table.metatable) |metatable|
            copy.metatable = (try self.cloneSnapshotValue(.{ .table = metatable }, seen)).table;
        copy.read_only = value.table.read_only;
        return .{ .table = copy };
    }

    const ExportGraphGuard = struct {
        owner: *Context,
        root: *Table,
        tables: std.AutoHashMapUnmanaged(*Table, void) = .empty,
        cells: std.AutoHashMapUnmanaged(*Cell, void) = .empty,
        callables: std.AutoHashMapUnmanaged(*const FunctionValue, void) = .empty,
        baselines: std.ArrayList(InvokeCellBaseline) = .empty,
        pending: std.ArrayList(Value) = .empty,

        fn deinit(self: *ExportGraphGuard) void {
            self.tables.deinit(std.heap.smp_allocator);
            self.cells.deinit(std.heap.smp_allocator);
            self.callables.deinit(std.heap.smp_allocator);
            self.baselines.deinit(std.heap.smp_allocator);
            self.pending.deinit(std.heap.smp_allocator);
        }

        fn table(self: *ExportGraphGuard, item: *Table) anyerror!void {
            if (item.cross_page_stable and item.read_only) return;
            if (item.invoke_rollback_owner_nonce != self.owner.field_cache_nonce) {
                self.root.export_pristine = false;
                return;
            }
            if (item.invocation_environment or !item.owns_slots or item.global_tail != null) {
                self.root.export_pristine = false;
                return;
            }
            if (item.native_metatable_namespace != null) return;
            if (item.native_namespace) |namespace|
                if (templateSingletonNamespace(namespace) or namespace == .namespace_map or namespace == .title_value) return;
            const entry = try self.tables.getOrPut(std.heap.smp_allocator, item);
            if (entry.found_existing) return;
            if (item != self.root) {
                if (item.has_export_guard and !item.exportGraphPristine())
                    self.root.export_pristine = false;
                var present = false;
                for (item.export_guard_parents) |parent| {
                    if (parent.table) |ancestor| {
                        if (ancestor != self.root and !ancestor.exportGraphPristine()) self.root.export_pristine = false;
                        present = present or ancestor == self.root;
                    }
                }
                if (!present) {
                    try noteInvokeTableMutation(item);
                    const parents = try self.owner.stringAllocator().alloc(*ExportGuardRoot, item.export_guard_parents.len + 1);
                    @memcpy(parents[0..item.export_guard_parents.len], item.export_guard_parents);
                    parents[item.export_guard_parents.len] = self.root.export_guard_root.?;
                    item.export_guard_parents = parents;
                }
            }
            for (item.slots) |slot_value| try self.pending.append(std.heap.smp_allocator, slot_value);
            for (item.choices) |choice| {
                try self.pending.append(std.heap.smp_allocator, choice.key);
                try self.pending.append(std.heap.smp_allocator, choice.value);
            }
            var entries = item.map.iterator();
            while (entries.next()) |row| {
                try self.pending.append(std.heap.smp_allocator, row.key_ptr.*);
                try self.pending.append(std.heap.smp_allocator, row.value_ptr.*);
            }
            if (item.metatable) |metatable| try self.pending.append(std.heap.smp_allocator, .{ .table = metatable });
        }

        fn value(self: *ExportGraphGuard, item: Value) anyerror!void {
            switch (item) {
                .table => |table_value| try self.table(table_value),
                .callable => |callable| {
                    if (callable.id == native_function_id) return;
                    const entry = try self.callables.getOrPut(std.heap.smp_allocator, callable);
                    if (entry.found_existing) return;
                    switch (callable.captures()) {
                        .direct => |captures| for (captures) |cell| {
                            const seen = try self.cells.getOrPut(std.heap.smp_allocator, cell);
                            if (seen.found_existing) continue;
                            try self.baselines.append(std.heap.smp_allocator, .{ .cell = cell, .value = cell.value });
                            try self.pending.append(std.heap.smp_allocator, cell.value);
                        },
                        .native => unreachable,
                    }
                },
                else => {},
            }
        }
    };

    fn prepareModuleExportGuard(self: *Context, value: Value) !void {
        if (value != .table or value.table.export_guard_graph_ready) return;
        const root = value.table;
        try noteInvokeTableMutation(root);
        if (root.export_guard_root == null) {
            const record = try self.stringAllocator().create(ExportGuardRoot);
            record.* = .{ .table = root };
            root.export_guard_root = record;
        }
        root.prepareExportGuard();
        errdefer root.export_pristine = false;
        var guard = ExportGraphGuard{ .owner = self, .root = root };
        defer guard.deinit();
        // Heap graph depth is independent of Lua call depth.
        try guard.pending.append(std.heap.smp_allocator, value);
        while (guard.pending.pop()) |item| try guard.value(item);
        root.export_capture_baselines = try self.stringAllocator().dupe(InvokeCellBaseline, guard.baselines.items);
        root.export_guard_graph_ready = true;
    }

    fn prepareModuleValueGuard(self: *Context, value: Value) !ModuleValueGuard {
        if (value == .table) {
            if (value.table.cross_page_stable and value.table.read_only) return .{};
            if (value.table.invoke_rollback_owner_nonce != self.field_cache_nonce) return .{ .valid = false };
            try self.prepareModuleExportGuard(value);
            return .{ .root = value.table };
        }
        if (value != .callable) return .{};
        const Walk = struct {
            ctx: *Context,
            valid: bool = true,
            seen: std.AutoHashMapUnmanaged(*const FunctionValue, void) = .empty,
            cells: std.AutoHashMapUnmanaged(*Cell, void) = .empty,
            tables: std.ArrayList(*Table) = .empty,
            baselines: std.ArrayList(InvokeCellBaseline) = .empty,
            pending: std.ArrayList(Value) = .empty,

            fn visit(walk: *@This(), item: Value) anyerror!void {
                if (item == .table) {
                    if (item.table.cross_page_stable and item.table.read_only) return;
                    if (item.table.invoke_rollback_owner_nonce != walk.ctx.field_cache_nonce) {
                        walk.valid = false;
                        return;
                    }
                    for (walk.tables.items) |table| if (table == item.table) return;
                    try walk.ctx.prepareModuleExportGuard(item);
                    try walk.tables.append(std.heap.smp_allocator, item.table);
                } else if (item == .callable and item.callable.id != native_function_id) {
                    const entry = try walk.seen.getOrPut(std.heap.smp_allocator, item.callable);
                    if (entry.found_existing) return;
                    switch (item.callable.captures()) {
                        .direct => |captures| for (captures) |cell| {
                            const found = try walk.cells.getOrPut(std.heap.smp_allocator, cell);
                            if (found.found_existing) continue;
                            try walk.baselines.append(std.heap.smp_allocator, .{ .cell = cell, .value = cell.value });
                            try walk.pending.append(std.heap.smp_allocator, cell.value);
                        },
                        .native => unreachable,
                    }
                }
            }
        };
        var walk = Walk{ .ctx = self };
        defer walk.seen.deinit(std.heap.smp_allocator);
        defer walk.cells.deinit(std.heap.smp_allocator);
        defer walk.tables.deinit(std.heap.smp_allocator);
        defer walk.baselines.deinit(std.heap.smp_allocator);
        defer walk.pending.deinit(std.heap.smp_allocator);
        try walk.pending.append(std.heap.smp_allocator, value);
        while (walk.pending.pop()) |item| try walk.visit(item);
        return .{
            .valid = walk.valid,
            .capture_tables = try self.stringAllocator().dupe(*Table, walk.tables.items),
            .capture_cells = try self.stringAllocator().dupe(InvokeCellBaseline, walk.baselines.items),
        };
    }

    fn retainModuleRequirements(self: *Context, values: []const ModuleRequirement) ![]const ModuleRequirement {
        const result = try self.stringAllocator().alloc(ModuleRequirement, values.len);
        for (values, result) |item, *out| out.* = .{
            .module_id = item.module_id,
            .requested = try self.stringAllocator().dupe(u8, item.requested),
        };
        return result;
    }

    const ModuleTemplateTagger = struct {
        allocator: std.mem.Allocator,
        marker: *u64,
        tables: std.AutoHashMapUnmanaged(*Table, void) = .empty,
        cells: std.AutoHashMapUnmanaged(*Cell, void) = .empty,
        callables: std.AutoHashMapUnmanaged(*const FunctionValue, void) = .empty,

        fn deinit(self: *ModuleTemplateTagger) void {
            self.tables.deinit(self.allocator);
            self.cells.deinit(self.allocator);
            self.callables.deinit(self.allocator);
        }

        fn tagCell(self: *ModuleTemplateTagger, cell: *Cell) anyerror!void {
            const gop = try self.cells.getOrPut(self.allocator, cell);
            if (gop.found_existing) return;
            try self.tagValue(cell.value);
        }

        fn tagCallable(
            self: *ModuleTemplateTagger,
            callable: *const FunctionValue,
        ) anyerror!void {
            if (callable.id == native_function_id) return;
            const gop = try self.callables.getOrPut(self.allocator, callable);
            if (gop.found_existing) return;
            switch (callable.captures()) {
                .direct => |captures| for (captures) |cell| try self.tagCell(cell),
                .native => unreachable,
            }
        }

        fn tagTable(self: *ModuleTemplateTagger, table: *Table) anyerror!void {
            if (table.native_metatable_namespace != null) return;
            // Worker-owned loadData graphs cannot retain pointers into a
            // shorter-lived module state. Their descendants are immutable too.
            if (table.cross_page_stable and table.read_only) return;
            const gop = try self.tables.getOrPut(self.allocator, table);
            if (gop.found_existing) return;
            // A later export may alias a dependency. Its traversal must not
            // transfer that dependency's mutation ownership to the exporter.
            if (table.module_template_mutation_probe == null)
                table.module_template_mutation_probe = self.marker;
            for (table.slots) |item| try self.tagValue(item);
            for (table.choices) |choice| {
                try self.tagValue(choice.key);
                try self.tagValue(choice.value);
            }
            var entries = table.map.iterator();
            while (entries.next()) |entry| {
                try self.tagValue(entry.key_ptr.*);
                try self.tagValue(entry.value_ptr.*);
            }
            if (table.metatable) |metatable| try self.tagTable(metatable);
        }

        fn tagValue(self: *ModuleTemplateTagger, value: Value) anyerror!void {
            switch (value) {
                .table => |table| try self.tagTable(table),
                .callable => |callable| try self.tagCallable(callable),
                else => {},
            }
        }
    };

    fn tagModuleTemplateValue(
        self: *Context,
        value: Value,
        marker: *u64,
    ) !void {
        _ = self;
        // Traversal sets die with this walk, not with the persistent graph.
        var tagger = ModuleTemplateTagger{
            .allocator = std.heap.smp_allocator,
            .marker = marker,
        };
        defer tagger.deinit();
        try tagger.tagValue(value);
    }

    const ModuleTemplateClone = struct {
        source: *Context,
        target: *Context,
        promotion: bool = false,
        source_mutation_marker: ?*const u64 = null,
        mutation_marker: ?*u64 = null,
        mutation_owners: std.AutoHashMapUnmanaged(*u64, *u64) = .empty,
        skip_modules: []const u32 = &.{},
        tables: std.AutoHashMapUnmanaged(*Table, *Table) = .empty,
        cells: std.AutoHashMapUnmanaged(*Cell, *Cell) = .empty,
        callables: std.AutoHashMapUnmanaged(*const FunctionValue, *const FunctionValue) = .empty,

        fn mapAllocator(self: *const ModuleTemplateClone) std.mem.Allocator {
            // Promotion publishes values, never these temporary identity maps.
            return if (self.promotion) std.heap.smp_allocator else self.target.allocator;
        }

        fn deinit(self: *ModuleTemplateClone) void {
            self.mutation_owners.deinit(std.heap.smp_allocator);
            self.tables.deinit(self.mapAllocator());
            self.cells.deinit(self.mapAllocator());
            self.callables.deinit(self.mapAllocator());
        }

        fn cloneMutationMarker(self: *ModuleTemplateClone, table: *const Table) !?*u64 {
            const marker = table.module_template_mutation_probe orelse return self.mutation_marker;
            if (marker == self.source_mutation_marker) return self.mutation_marker;
            if (self.mutation_owners.get(marker)) |mapped| return mapped;
            // Overrides can be reached through another module before their
            // package entry is installed. Remap their original owner, not the
            // module that happened to visit the graph first.
            const address = @intFromPtr(marker);
            for (self.source.module_state_pages, 0..) |page, page_index| if (page) |states| {
                const first = @intFromPtr(&states.states[0].template_mutation_probe_id);
                if (address < first) continue;
                const delta = address - first;
                if (delta % @sizeOf(ModuleState) != 0) continue;
                const slot = delta / @sizeOf(ModuleState);
                if (slot >= module_state_page_len or states.get(slot) == null) continue;
                const id = (page_index << module_state_page_shift) | slot;
                if (id >= self.source.module_count or id >= self.target.module_count) continue;
                const target_state = try self.target.ensureModuleState(@intCast(id));
                const mapped = &target_state.template_mutation_probe_id;
                try self.mutation_owners.put(std.heap.smp_allocator, marker, mapped);
                return mapped;
            };
            return self.mutation_marker;
        }

        fn skipsModule(self: *const ModuleTemplateClone, module_id: u32) bool {
            for (self.skip_modules) |candidate|
                if (candidate == module_id) return true;
            return false;
        }

        fn bindExisting(self: *ModuleTemplateClone, from: Value, to: Value) !void {
            if (from == .table and to == .table) {
                try self.tables.put(self.mapAllocator(), from.table, to.table);
            } else if (from == .callable and to == .callable) {
                try self.callables.put(self.mapAllocator(), from.callable, to.callable);
            }
        }

        fn cloneCell(self: *ModuleTemplateClone, source_cell: *Cell) anyerror!*Cell {
            if (self.cells.get(source_cell)) |existing| return existing;
            const cell = try self.target.stringAllocator().create(Cell);
            cell.* = .{ .value = .nil };
            try self.cells.put(self.mapAllocator(), source_cell, cell);
            cell.value = try self.cloneValue(source_cell.value);
            try self.target.retainInvokeCellBaseline(cell);
            return cell;
        }

        fn remapNativeCallable(
            self: *ModuleTemplateClone,
            source_function: *const FunctionValue,
        ) error{UnsupportedModuleTemplate}!?Value {
            for (self.source.root_globals, self.target.root_globals) |source_value, target_value| {
                if (source_value != .callable or source_value.callable != source_function)
                    continue;
                if (target_value != .callable or target_value.callable.id != native_function_id or
                    target_value.callable.entry != source_function.entry)
                    return error.UnsupportedModuleTemplate;
                return target_value;
            }

            inline for (std.enums.values(static_fields.Namespace)) |namespace| {
                if (comptime templateSingletonNamespace(namespace)) {
                    if (self.source.findTemplateNativeNamespace(namespace)) |source_table| {
                        for (source_table.slots, 0..) |source_value, slot| {
                            if (source_value != .callable or source_value.callable != source_function)
                                continue;
                            const target_table = self.target.findTemplateNativeNamespace(namespace) orelse
                                return error.UnsupportedModuleTemplate;
                            if (source_table.slots.len != target_table.slots.len)
                                return error.UnsupportedModuleTemplate;
                            const target_value = target_table.slots[slot];
                            if (target_value != .callable or target_value.callable.id != native_function_id or
                                target_value.callable.entry != source_function.entry)
                                return error.UnsupportedModuleTemplate;
                            return target_value;
                        }
                    }
                }
            }
            for (self.source.template_native_metatables, 0..) |source_opt, index| {
                const source_table = source_opt orelse continue;
                const key = nativeCallableKey(source_table, source_function) orelse continue;
                const target_table = self.target.template_native_metatables[index] orelse
                    return error.UnsupportedModuleTemplate;
                const target_value = target_table.rawGet(key) orelse
                    return error.UnsupportedModuleTemplate;
                if (target_value != .callable or target_value.callable.id != native_function_id or
                    target_value.callable.entry != source_function.entry)
                    return error.UnsupportedModuleTemplate;
                return target_value;
            }
            return null;
        }

        fn nativeCallableKey(table: *const Table, function: *const FunctionValue) ?Value {
            for (table.slots, 0..) |value, slot| {
                if (value == .callable and value.callable == function)
                    return table.fieldKey(@intCast(slot)) orelse .{ .number = @floatFromInt(slot + 1) };
            }
            for (table.choices) |choice|
                if (choice.value == .callable and choice.value.callable == function) return choice.key;
            var entries = table.map.iterator();
            while (entries.next()) |entry|
                if (entry.value_ptr.* == .callable and entry.value_ptr.callable == function) return entry.key_ptr.*;
            return null;
        }

        fn cloneCallable(self: *ModuleTemplateClone, source_function: *const FunctionValue) anyerror!Value {
            if (self.callables.get(source_function)) |existing|
                return .{ .callable = existing };
            if (source_function.id == native_function_id) {
                // Canonical identity is observable independently of captures:
                // title metatables compare __eq to mw.title.equals. Private
                // same-entry functions must still receive distinct identities.
                if (try self.remapNativeCallable(source_function)) |value| {
                    try self.callables.put(self.mapAllocator(), source_function, value.callable);
                    return value;
                }
                // The entrypoint is process code, but the descriptor itself is
                // allocated in the owning Context arena. Never retain that
                // pointer across page/template lifetimes. Context-bound native
                // environments remain uncloneable until they have an explicit
                // remapping contract.
                if (source_function.env.nativePtr() != null) {
                    if (work_stats.current()) |work| if (work.sampled)
                        work_stats.logLine("module template clone unsupported: kind=native_callable entry=0x{x}\n", .{@intFromPtr(source_function.entry)});
                    return error.UnsupportedModuleTemplate;
                }
                const value = try self.target.storeFunction(.{
                    .id = native_function_id,
                    .identity = try self.target.takeFunctionIdentity(),
                    .entry = source_function.entry,
                });
                try self.callables.put(
                    self.mapAllocator(),
                    source_function,
                    value.callable,
                );
                return value;
            }

            const captures = source_function.captures();
            const source_cells = switch (captures) {
                .direct => |cells| cells,
                .native => unreachable,
            };
            if (source_cells.len == 0) {
                const value = try self.target.makeFunction(source_function.id, source_function.entry, &.{});
                try self.callables.put(self.mapAllocator(), source_function, value.callable);
                return value;
            }

            const target_cells = try self.mapAllocator().alloc(*Cell, source_cells.len);
            defer self.mapAllocator().free(target_cells);
            var stack_created: [32]bool = undefined;
            const created = if (source_cells.len <= stack_created.len)
                stack_created[0..source_cells.len]
            else
                try self.mapAllocator().alloc(bool, source_cells.len);
            defer if (source_cells.len > stack_created.len) self.mapAllocator().free(created);
            for (source_cells, 0..) |source_cell, index| {
                if (self.cells.get(source_cell)) |existing| {
                    target_cells[index] = existing;
                    created[index] = false;
                } else {
                    const cell = try self.target.stringAllocator().create(Cell);
                    cell.* = .{ .value = .nil };
                    try self.cells.put(self.mapAllocator(), source_cell, cell);
                    target_cells[index] = cell;
                    created[index] = true;
                }
            }
            const value = try self.target.makeFunction(
                source_function.id,
                source_function.entry,
                target_cells,
            );
            try self.callables.put(self.mapAllocator(), source_function, value.callable);
            for (source_cells, target_cells, created) |source_cell, target_cell, is_new| {
                // nil is a valid live capture, not an uninitialized marker.
                // The creator of a recursive placeholder completes it once.
                if (is_new) {
                    target_cell.value = try self.cloneValue(source_cell.value);
                    try self.target.retainInvokeCellBaseline(target_cell);
                }
            }
            return value;
        }

        fn cloneTable(self: *ModuleTemplateClone, source_table: *Table) anyerror!Value {
            if (self.tables.get(source_table)) |existing|
                return .{ .table = existing };
            if (self.source.nativeMetatableIndex(source_table)) |index| {
                const table = self.target.template_native_metatables[index] orelse
                    return error.UnsupportedModuleTemplate;
                try self.tables.put(self.mapAllocator(), source_table, table);
                return .{ .table = table };
            }
            // Title values retain native per-page identity outside their Lua fields.
            // Removing their methods cannot make that state portable to a new Context.
            if (source_table.native_namespace == .title_value) return error.UnsupportedModuleTemplate;
            if (source_table.cross_page_stable and source_table.read_only) {
                try self.tables.put(self.mapAllocator(), source_table, source_table);
                return .{ .table = source_table };
            }
            if (source_table.native_namespace) |namespace| {
                if (namespace == .namespace_map) {
                    const table = self.target.findTemplateNamespaceMap(self.source, source_table) orelse
                        return error.UnsupportedModuleTemplate;
                    try self.tables.put(self.mapAllocator(), source_table, table);
                    return .{ .table = table };
                }
                if (templateSingletonNamespace(namespace)) {
                    const table = self.target.findTemplateNativeNamespace(namespace) orelse {
                        if (work_stats.current()) |work| if (work.sampled)
                            work_stats.logLine("module template clone unsupported: kind=native_namespace namespace={s}\n", .{@tagName(namespace)});
                        return error.UnsupportedModuleTemplate;
                    };
                    try self.tables.put(self.mapAllocator(), source_table, table);
                    return .{ .table = table };
                }
            }
            if (!source_table.owns_slots or source_table.global_tail != null or
                source_table.has_identity_key)
            {
                if (work_stats.current()) |work| if (work.sampled)
                    work_stats.logLine("module template clone unsupported: kind=table_flags owns_slots={} global_tail={} identity={} namespace={s}\n", .{
                        source_table.owns_slots,
                        source_table.global_tail != null,
                        source_table.has_identity_key,
                        if (source_table.native_namespace) |ns| @tagName(ns) else "none",
                    });
                return error.UnsupportedModuleTemplate;
            }

            const marker = try self.cloneMutationMarker(source_table);
            const table = try self.target.stringAllocator().create(Table);
            table.* = .{
                .shape = source_table.shape,
                .native_namespace = source_table.native_namespace,
                .append_index = source_table.append_index,
                .read_only = source_table.read_only,
                .has_hashed_number = source_table.has_hashed_number,
                .numeric_mirror_disabled = source_table.numeric_mirror_disabled,
                .dense_prefix_len = source_table.dense_prefix_len,
                .dense_prefix_valid = source_table.dense_prefix_valid,
                .module_template_probe_id = module_template_probe_owner_id,
                .module_template_reconstructable = source_table.module_template_reconstructable,
                .invoke_rollback_owner_nonce = self.target.field_cache_nonce,
                .module_template_mutation_probe = marker,
            };
            table.slot_history = source_table.slot_history;
            table.slot_history_tail = try self.target.allocator.dupe(u64, source_table.slot_history_tail);
            table.map_deletions_since_prune = source_table.map_deletions_since_prune;
            self.target.assignFieldCacheIdentity(table);
            try self.tables.put(self.mapAllocator(), source_table, table);

            if (source_table.slots.len != 0) {
                table.slots = try self.target.allocator.alloc(Value, source_table.slots.len);
                for (source_table.slots, 0..) |item, index|
                    table.slots[index] = try self.cloneValue(item);
            }
            if (source_table.choices.len != 0) {
                table.choices = try self.target.allocator.alloc(ChoiceCell, source_table.choices.len);
                for (source_table.choices, 0..) |choice, index| {
                    if (Table.identityKey(choice.key)) {
                        if (work_stats.current()) |work| if (work.sampled)
                            work_stats.logLine("module template clone unsupported: kind=choice_identity\n", .{});
                        return error.UnsupportedModuleTemplate;
                    }
                    table.choices[index] = .{
                        .key = try self.cloneValue(choice.key),
                        .value = try self.cloneValue(choice.value),
                    };
                }
            }
            var entries = source_table.map.iterator();
            while (entries.next()) |entry| {
                if (Table.identityKey(entry.key_ptr.*)) {
                    if (work_stats.current()) |work| if (work.sampled)
                        work_stats.logLine("module template clone unsupported: kind=map_identity\n", .{});
                    return error.UnsupportedModuleTemplate;
                }
                try table.map.putContext(
                    self.target.allocator,
                    try self.cloneValue(entry.key_ptr.*),
                    try self.cloneValue(entry.value_ptr.*),
                    .{},
                );
            }
            if (source_table.metatable) |metatable|
                table.metatable = (try self.cloneTable(metatable)).table;
            return .{ .table = table };
        }

        fn cloneValue(self: *ModuleTemplateClone, value: Value) anyerror!Value {
            return switch (value) {
                .string => |text| if (self.promotion or self.target.own_cloned_strings)
                    .{ .string = try self.target.ownString(text) }
                else
                    value,
                .table => |table| self.cloneTable(table),
                .callable => |callable| self.cloneCallable(callable),
                else => value,
            };
        }

        fn cloneModule(
            self: *ModuleTemplateClone,
            module_id: u32,
            requested: ?[]const u8,
        ) anyerror!Value {
            if (module_id >= self.target.module_template_eligible.len or
                !self.target.module_template_eligible[module_id])
                return error.UnsupportedModuleTemplate;

            const source_value = try self.target.loadTemplateSource(self.source, module_id, requested);
            const source_state = self.source.moduleStateConst(module_id) orelse
                return error.UnsupportedModuleTemplate;
            if (self.target.moduleState(module_id)) |existing| {
                if (existing.value) |value| {
                    try self.bindExisting(source_value, value);
                    try self.publishRequestedAlias(module_id, requested, value);
                    return value;
                }
                if (existing.loading) return error.ModuleLoadLoop;
            }

            const state = try self.target.ensureModuleState(module_id);
            if (module_template_effect_probe != null and state.template_init_probe_id == 0)
                state.template_init_probe_id = module_template_probe_id;
            state.loading = true;
            errdefer state.loading = false;
            var requirements = self.source.templateRequirementsFor(module_id);
            while (requirements.next()) |requirement| {
                if (self.skipsModule(requirement.module_id)) continue;
                _ = try self.cloneModule(requirement.module_id, requirement.requested);
            }

            const previous_source_marker = self.source_mutation_marker;
            const previous_marker = self.mutation_marker;
            self.source_mutation_marker = &source_state.template_mutation_probe_id;
            self.mutation_marker = &state.template_mutation_probe_id;
            defer {
                self.source_mutation_marker = previous_source_marker;
                self.mutation_marker = previous_marker;
            }
            const value = try self.cloneValue(source_value);
            const observed_requirements = try self.target.retainModuleRequirements(source_state.template_observed_requirements);
            const value_guard = try self.target.prepareModuleValueGuard(value);
            state.value = value;
            state.preinitialized = null;
            state.template_package_observed = source_state.template_package_observed;
            state.template_page_scoped_only = source_state.template_page_scoped_only;
            state.template_library_dependencies = source_state.template_library_dependencies;
            state.template_invocation_dependent = source_state.template_invocation_dependent;
            state.template_observed_requirements = observed_requirements;
            state.template_value_guard = value_guard;
            state.template_origin_context = if (self.promotion) null else self.source;
            state.loading = false;
            try self.target.packageLoadedModuleSet(module_id, requested, value);
            try self.publishRequestedAlias(module_id, requested, value);
            if (!self.promotion and source_state.template_package_observed)
                try self.target.observePackage();
            return value;
        }

        fn publishRequestedAlias(self: *ModuleTemplateClone, module_id: u32, requested: ?[]const u8, value: Value) !void {
            const raw_name = requested orelse return;
            const loaded = self.target.package_loaded orelse return;
            if (self.target.canonicalModuleName(module_id, null)) |canonical|
                if (std.mem.eql(u8, canonical, raw_name)) return;
            if (rawGetRuntimeBookkeeping(loaded, .{ .string = raw_name })) |existing|
                if (rawEqual(existing, value)) return;
            try self.target.packageLoadedRequestedSet(raw_name, value);
        }

        fn applyTemplateOverrides(
            self: *ModuleTemplateClone,
            overrides: []const ModuleTemplateOverride,
            creator: *const ModuleState,
        ) anyerror!void {
            const previous_source_marker = self.source_mutation_marker;
            const previous_marker = self.mutation_marker;
            defer {
                self.source_mutation_marker = previous_source_marker;
                self.mutation_marker = previous_marker;
            }
            for (overrides) |override| {
                const state = try self.target.ensureModuleState(override.module_id);
                const source_state = self.source.moduleState(override.module_id);
                self.source_mutation_marker = if (source_state) |owner| &owner.template_mutation_probe_id else null;
                self.mutation_marker = &state.template_mutation_probe_id;
                const value = try self.cloneValue(override.value);
                const value_guard = try self.target.prepareModuleValueGuard(value);
                const original = if (source_state) |owner| owner.template_observed_requirements else &.{};
                const combined = try self.target.allocator.alloc(ModuleRequirement, original.len + creator.template_observed_requirements.len);
                defer self.target.allocator.free(combined);
                @memcpy(combined[0..original.len], original);
                @memcpy(combined[original.len..], creator.template_observed_requirements);
                const observed_requirements = try self.target.retainModuleRequirements(combined);
                state.value = value;
                state.preinitialized = null;
                state.template_value_guard = value_guard;
                state.template_origin_context = null;
                state.template_library_dependencies = creator.template_library_dependencies |
                    (if (source_state) |owner| owner.template_library_dependencies else 0);
                state.template_invocation_dependent = creator.template_invocation_dependent or
                    (if (source_state) |owner| owner.template_invocation_dependent else false);
                state.template_observed_requirements = observed_requirements;
                state.loading = false;
                try self.target.packageLoadedModuleSet(override.module_id, null, value);
            }
        }
    };

    // A failed upward clone must not fill the worker-lifetime arena with
    // discarded nodes. Check already-materialized source graphs before any
    // target allocation. Missing source modules remain the ordinary loader's
    // responsibility; this walk never executes a root or changes package state.
    const PromotionPreflight = struct {
        clone: ModuleTemplateClone,
        seen: std.AutoHashMapUnmanaged(usize, void) = .empty,
        modules: std.AutoHashMapUnmanaged(u32, void) = .empty,

        fn deinit(self: *PromotionPreflight) void {
            self.seen.deinit(std.heap.smp_allocator);
            self.modules.deinit(std.heap.smp_allocator);
        }

        fn first(self: *PromotionPreflight, pointer: anytype) !bool {
            const entry = try self.seen.getOrPut(std.heap.smp_allocator, @intFromPtr(pointer));
            return !entry.found_existing;
        }

        fn bind(self: *PromotionPreflight, from: Value, to: Value) !void {
            if (from == .table and to == .table) {
                _ = try self.first(from.table);
            } else if (from == .callable and to == .callable) {
                _ = try self.first(from.callable);
            }
        }

        fn module(self: *PromotionPreflight, id: u32) anyerror!bool {
            const visited = try self.modules.getOrPut(std.heap.smp_allocator, id);
            if (visited.found_existing) return true;
            const source = self.clone.source.moduleStateConst(id) orelse return true;
            const exported = source.value orelse source.preinitialized orelse return true;
            if (self.clone.target.moduleStateConst(id)) |target| if (target.value) |existing| {
                try self.bind(exported, existing);
                return true;
            };
            var requirements = self.clone.source.templateRequirementsFor(id);
            while (requirements.next()) |dependency| {
                if (self.clone.skipsModule(dependency.module_id)) continue;
                if (!try self.module(dependency.module_id)) return false;
            }
            return self.value(exported);
        }

        fn value(self: *PromotionPreflight, input: Value) anyerror!bool {
            switch (input) {
                .table => |table| {
                    if (!try self.first(table)) return true;
                    if (self.clone.source.nativeMetatableIndex(table)) |index|
                        return self.clone.target.template_native_metatables[index] != null;
                    if (table.native_namespace == .title_value) return false;
                    if (table.cross_page_stable and table.read_only) return true;
                    if (table.native_namespace == .namespace_map)
                        return self.clone.target.findTemplateNamespaceMap(self.clone.source, table) != null;
                    if (table.native_namespace) |namespace| if (templateSingletonNamespace(namespace))
                        return self.clone.target.findTemplateNativeNamespace(namespace) != null;
                    if (!table.owns_slots or table.global_tail != null or table.has_identity_key)
                        return false;
                    for (table.slots) |item| if (!try self.value(item)) return false;
                    for (table.choices) |choice| {
                        if (Table.identityKey(choice.key)) return false;
                        if (!try self.value(choice.key) or !try self.value(choice.value)) return false;
                    }
                    var entries = table.map.iterator();
                    while (entries.next()) |entry| {
                        if (Table.identityKey(entry.key_ptr.*)) return false;
                        if (!try self.value(entry.key_ptr.*) or !try self.value(entry.value_ptr.*)) return false;
                    }
                    if (table.metatable) |metatable|
                        if (!try self.value(.{ .table = metatable })) return false;
                },
                .callable => |callable| {
                    if (!try self.first(callable)) return true;
                    if (callable.id == native_function_id) {
                        const mapped = self.clone.remapNativeCallable(callable) catch return false;
                        return mapped != null or callable.env.nativePtr() == null;
                    }
                    switch (callable.captures()) {
                        .direct => |captures| for (captures) |cell| {
                            if (try self.first(cell)) if (!try self.value(cell.value)) return false;
                        },
                        .native => unreachable,
                    }
                },
                else => {},
            }
            return true;
        }
    };

    fn loadTemplateSource(self: *Context, source: *Context, module_id: u32, requested: ?[]const u8) anyerror!Value {
        if (module_id < source.module_count and module_id < source.module_root_entries.len)
            if (source.moduleStateConst(module_id)) |state|
                if (state.value) |value| return value;
        if (source == self) return source.loadModule(module_id, requested);
        // A missing dependency is not a reusable graph. Evaluating it in the
        // worker template would observe no page host or invocation frame.
        // Reject that cache candidate; the ordinary loader retries in self.
        if (self.host != null and source.host == null)
            return error.UnsupportedModuleTemplate;

        const saved_error = source.last_error;
        const saved_error_present = source.last_error_present;
        const saved_name = source.aot_error_name;
        source.clearLuaError();
        source.clearAotErrorName();
        defer {
            source.last_error = saved_error;
            source.last_error_present = saved_error_present;
            source.aot_error_name = saved_name;
        }
        return source.loadModule(module_id, requested) catch |err| {
            // AotCallFailed is the compiled-call envelope. Adopt its diagnostic
            // before restoring the source scope, including an explicit nil.
            if (err == error.AotCallFailed) try self.adoptFailure(source);
            return err;
        };
    }

    fn templateLibrariesPristine(self: *const Context, dependencies: u64) bool {
        var remaining = dependencies;
        while (remaining != 0) {
            const index: usize = @intCast(@ctz(remaining));
            remaining &= remaining - 1;
            if (index >= native_namespace_count) return false;
            var present = false;
            if (self.template_native_namespaces[index]) |library| {
                present = true;
                if (library.template_native_baseline_pristine != @as(?bool, true)) return false;
            }
            if (self.template_native_metatables[index]) |metatable| {
                present = true;
                if (metatable.template_native_baseline_pristine != @as(?bool, true)) return false;
            }
            if (!present) return false;
        }
        return true;
    }

    fn instantiateModuleTemplate(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!?Value {
        const source = self.module_template_context orelse return null;
        if (module_id >= self.module_template_eligible.len or
            !self.module_template_eligible[module_id])
            return null;
        const source_materialized = if (source.moduleStateConst(module_id)) |state|
            state.value != null
        else
            false;
        if (!source_materialized and self.host != null and source.host == null) {
            // Cold cache admission must execute in the live page context.
            // Keep rejection clear so the existing effect/graph checks can
            // still promote a pure result after ordinary root evaluation.
            self.module_template_eligible[module_id] = false;
            return null;
        }
        if (source.moduleStateConst(module_id) == null) {
            _ = self.loadTemplateSource(source, module_id, requested) catch |err| switch (err) {
                error.UnsupportedModuleTemplate => {
                    self.module_template_eligible[module_id] = false;
                    if (module_id < self.module_template_rejected.len)
                        self.module_template_rejected[module_id] = true;
                    return null;
                },
                else => return err,
            };
        }
        const source_state = source.moduleStateConst(module_id) orelse {
            self.module_template_eligible[module_id] = false;
            if (module_id < self.module_template_rejected.len)
                self.module_template_rejected[module_id] = true;
            return null;
        };
        const source_value = source_state.value orelse source_state.preinitialized orelse return null;
        if (!source_value.truthy()) return null;
        if (source_state.template_invocation_dependent or
            !self.templateLibrariesPristine(source_state.template_library_dependencies)) return null;
        if (!try self.templateDependenciesPristine(module_id)) return null;
        for (source_state.template_overrides) |override| {
            if (self.moduleStateConst(override.module_id)) |existing|
                if (existing.value != null or existing.preinitialized != null)
                    return null;
        }
        const override_ids = try self.allocator.alloc(u32, source_state.template_overrides.len);
        defer self.allocator.free(override_ids);
        for (source_state.template_overrides, override_ids) |override, *id|
            id.* = override.module_id;
        if (self.module_template_clone_source != source) {
            self.module_template_clone_tables.deinit(self.allocator);
            self.module_template_clone_cells.deinit(self.allocator);
            self.module_template_clone_callables.deinit(self.allocator);
            self.module_template_clone_tables = .empty;
            self.module_template_clone_cells = .empty;
            self.module_template_clone_callables = .empty;
            self.module_template_clone_source = source;
            try self.seedModuleTemplateNativeAliases(source);
        }
        var clone = ModuleTemplateClone{
            .source = source,
            .target = self,
            .skip_modules = override_ids,
            .tables = self.module_template_clone_tables,
            .cells = self.module_template_clone_cells,
            .callables = self.module_template_clone_callables,
        };
        self.module_template_clone_tables = .empty;
        self.module_template_clone_cells = .empty;
        self.module_template_clone_callables = .empty;
        defer {
            self.module_template_clone_tables = clone.tables;
            self.module_template_clone_cells = clone.cells;
            self.module_template_clone_callables = clone.callables;
            clone.tables = .empty;
            clone.cells = .empty;
            clone.callables = .empty;
            clone.deinit();
        }
        const value = clone.cloneModule(module_id, requested) catch |err| switch (err) {
            error.UnsupportedModuleTemplate => blk: {
                try self.clearTemplateInstalledModule(module_id, requested);
                clone.tables.clearRetainingCapacity();
                clone.cells.clearRetainingCapacity();
                clone.callables.clearRetainingCapacity();
                self.module_template_eligible[module_id] = false;
                if (module_id < self.module_template_rejected.len)
                    self.module_template_rejected[module_id] = true;
                break :blk null;
            },
            else => return err,
        };
        if (value == null) return null;
        clone.applyTemplateOverrides(source_state.template_overrides, source_state) catch |err| switch (err) {
            error.UnsupportedModuleTemplate => {
                try self.clearTemplateInstalledModule(module_id, requested);
                for (source_state.template_overrides) |override|
                    try self.clearTemplateInstalledModule(override.module_id, null);
                clone.tables.clearRetainingCapacity();
                clone.cells.clearRetainingCapacity();
                clone.callables.clearRetainingCapacity();
                self.module_template_eligible[module_id] = false;
                if (module_id < self.module_template_rejected.len)
                    self.module_template_rejected[module_id] = true;
                return null;
            },
            else => return err,
        };
        return value;
    }

    fn clearTemplateInstalledModule(
        self: *Context,
        module_id: u32,
        requested: ?[]const u8,
    ) !void {
        if (self.moduleState(module_id)) |state| state.* = .{};
        try self.packageLoadedModuleSet(module_id, requested, .nil);
    }

    fn dynamicModuleTemplateCandidate(self: *const Context, module_id: u32) bool {
        return self.module_template_context != null and
            module_id < self.module_template_eligible.len and
            module_id < self.module_template_rejected.len and
            !self.module_template_eligible[module_id] and
            !self.module_template_rejected[module_id];
    }

    fn moduleTemplateProbeModules(
        self: *const Context,
        allocator: std.mem.Allocator,
        probe_id: u64,
        exclude_module_id: u32,
    ) ![]u32 {
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(allocator);
        for (self.module_state_pages, 0..) |page, page_index| if (page) |states| {
            for (states.initialized, 0..) |word, word_index| {
                var remaining = word;
                while (remaining != 0) {
                    const slot = word_index * 64 + @as(usize, @intCast(@ctz(remaining)));
                    remaining &= remaining - 1;
                    const module_id_usize = (page_index << module_state_page_shift) | slot;
                    if (module_id_usize >= self.module_count) continue;
                    const module_id: u32 = @intCast(module_id_usize);
                    if (module_id == exclude_module_id) continue;
                    const state = &states.states[slot];
                    if (state.template_init_probe_id != probe_id and
                        state.template_mutation_probe_id != probe_id)
                        continue;
                    try ids.append(allocator, module_id);
                }
            }
        };
        return ids.toOwnedSlice(allocator);
    }

    fn promoteModuleTemplate(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!bool {
        return self.promoteModuleTemplateImpl(module_id, requested) catch |err| {
            if (err == error.OutOfMemory) module_template_allocation_failed = true;
            return err;
        };
    }

    fn promoteModuleTemplateImpl(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!bool {
        const target = self.module_template_context orelse return false;
        if (module_id >= self.module_template_eligible.len or
            module_id >= self.module_template_rejected.len or
            self.module_template_rejected[module_id])
            return false;
        if (self.module_template_eligible[module_id]) return true;

        const probe_id = module_template_probe_id;
        const override_ids = try self.moduleTemplateProbeModules(
            self.allocator,
            probe_id,
            module_id,
        );
        defer self.allocator.free(override_ids);
        var preflight = PromotionPreflight{ .clone = .{
            .source = self,
            .target = target,
            .promotion = true,
            .skip_modules = override_ids,
        } };
        defer preflight.deinit();
        const portable = blk: {
            if (!try preflight.module(module_id)) break :blk false;
            for (override_ids) |id| {
                const state = self.moduleStateConst(id) orelse break :blk false;
                const value = state.value orelse state.preinitialized orelse break :blk false;
                if (!try preflight.value(value)) break :blk false;
            }
            break :blk true;
        };
        if (!portable) {
            self.module_template_rejected[module_id] = true;
            noteModuleTemplateEffectReason(1 << 4);
            markModuleTemplateEffect();
            return false;
        }
        // Bundle workers execute requests serially. Temporarily expose the root
        // to the clone walker, and retain the bit only after a complete clone.
        self.module_template_eligible[module_id] = true;
        errdefer {
            self.module_template_eligible[module_id] = false;
            self.module_template_rejected[module_id] = true;
            target.clearTemplateInstalledModule(module_id, requested) catch {};
        }
        var clone = ModuleTemplateClone{
            .source = self,
            .target = target,
            .promotion = true,
            .skip_modules = override_ids,
        };
        defer clone.deinit();
        _ = clone.cloneModule(module_id, requested) catch |err| switch (err) {
            error.UnsupportedModuleTemplate => {
                self.module_template_eligible[module_id] = false;
                self.module_template_rejected[module_id] = true;
                if (target.moduleState(module_id)) |state| state.* = .{};
                noteModuleTemplateEffectReason(1 << 4);
                markModuleTemplateEffect();
                return false;
            },
            else => {
                self.module_template_eligible[module_id] = false;
                if (target.moduleState(module_id)) |state| state.* = .{};
                return err;
            },
        };
        if (override_ids.len != 0) {
            const overrides = try target.allocator.alloc(ModuleTemplateOverride, override_ids.len);
            errdefer target.allocator.free(overrides);
            for (override_ids, overrides) |dependency_id, *override| {
                const source_state = self.moduleStateConst(dependency_id) orelse
                    return error.UnsupportedModuleTemplate;
                const source_value = source_state.value orelse source_state.preinitialized orelse
                    return error.UnsupportedModuleTemplate;
                override.* = .{
                    .module_id = dependency_id,
                    .value = try clone.cloneValue(source_value),
                };
            }
            const target_state = target.moduleState(module_id) orelse
                return error.UnsupportedModuleTemplate;
            target_state.template_overrides = overrides;
        }
        if (self.moduleState(module_id)) |state| state.template_origin_context = target;
        return true;
    }

    fn promoteModuleTemplateUpstreamRecursive(
        self: *Context,
        module_id: u32,
        requested: ?[]const u8,
        visiting: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror!bool {
        return self.promoteModuleTemplateUpstreamImpl(module_id, requested, visiting) catch |err| {
            if (err == error.OutOfMemory) module_template_allocation_failed = true;
            return err;
        };
    }

    fn promoteModuleTemplateUpstreamImpl(
        self: *Context,
        module_id: u32,
        requested: ?[]const u8,
        visiting: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror!bool {
        const target = self.module_template_context orelse return false;
        if (module_id >= target.module_template_eligible.len or
            module_id >= target.module_template_rejected.len or
            target.module_template_rejected[module_id])
            return false;
        if (target.module_template_eligible[module_id]) return true;
        const source_state = self.moduleStateConst(module_id) orelse return false;
        if (source_state.template_page_scoped_only) return false;

        const visit = try visiting.getOrPut(self.allocator, module_id);
        if (visit.found_existing) return false;
        defer _ = visiting.remove(module_id);

        var requirements = self.templateRequirementsFor(module_id);
        while (requirements.next()) |requirement| {
            if (requirement.module_id >= target.module_template_eligible.len)
                return false;
            if (!target.module_template_eligible[requirement.module_id]) {
                if (!try self.promoteModuleTemplateUpstreamRecursive(
                    requirement.module_id,
                    requirement.requested,
                    visiting,
                )) return false;
            }
        }

        const override_ids = try self.allocator.alloc(u32, source_state.template_overrides.len);
        defer self.allocator.free(override_ids);
        for (source_state.template_overrides, override_ids) |override, *id|
            id.* = override.module_id;

        var preflight = PromotionPreflight{ .clone = .{
            .source = self,
            .target = target,
            .promotion = true,
            .skip_modules = override_ids,
        } };
        defer preflight.deinit();
        if (!try preflight.module(module_id)) return false;
        for (source_state.template_overrides) |override|
            if (!try preflight.value(override.value)) return false;

        target.module_template_eligible[module_id] = true;
        errdefer {
            target.module_template_eligible[module_id] = false;
            target.module_template_rejected[module_id] = true;
            target.clearTemplateInstalledModule(module_id, requested) catch {};
        }
        var clone = ModuleTemplateClone{
            .source = self,
            .target = target,
            .promotion = true,
            .skip_modules = override_ids,
        };
        defer clone.deinit();
        _ = clone.cloneModule(module_id, requested) catch |err| switch (err) {
            error.UnsupportedModuleTemplate, error.ModuleLoadLoop => {
                target.module_template_eligible[module_id] = false;
                try target.clearTemplateInstalledModule(module_id, requested);
                return false;
            },
            else => return err,
        };
        if (source_state.template_overrides.len != 0) {
            // Upward promotion stores creator-local effects on that prototype.
            // Only a later live instantiation may install them as module state.
            const overrides = try target.allocator.alloc(ModuleTemplateOverride, source_state.template_overrides.len);
            errdefer target.allocator.free(overrides);
            for (source_state.template_overrides, overrides) |original, *override| override.* = .{
                .module_id = original.module_id,
                .value = try clone.cloneValue(original.value),
            };
            const target_state = target.moduleState(module_id) orelse return error.UnsupportedModuleTemplate;
            target_state.template_overrides = overrides;
        }
        if (self.moduleState(module_id)) |state| state.template_origin_context = target;
        return true;
    }

    fn promoteModuleTemplateUpstream(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!bool {
        var visiting: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visiting.deinit(self.allocator);
        return self.promoteModuleTemplateUpstreamRecursive(module_id, requested, &visiting);
    }

    pub fn preinitializeModule(self: *Context, module_id: u32, value: Value, snapshot_load_data: bool) !void {
        const state = try self.ensureModuleState(module_id);
        if (state.value == null and state.preinitialized == null) {
            try self.tagModuleTemplateValue(
                value,
                &state.template_mutation_probe_id,
            );
            state.template_value_guard = try self.prepareModuleValueGuard(value);
            state.preinitialized = value;
        }
        if (snapshot_load_data and state.load_data_snapshot == null) {
            var seen: std.AutoHashMapUnmanaged(*Table, *Table) = .empty;
            defer seen.deinit(self.allocator);
            state.load_data_snapshot = try self.cloneSnapshotValue(value, &seen);
        }
    }

    pub fn loadDataSnapshot(self: *const Context, module_id: u32) ?Value {
        const state = self.moduleStateConst(module_id) orelse return null;
        return state.load_data_snapshot;
    }

    fn preparedModuleValue(self: *const Context, module_id: u32) ?Value {
        const state = self.moduleStateConst(module_id) orelse return null;
        return state.value orelse state.preinitialized;
    }

    fn requirementsFor(self: *const Context, module_id: u32) []const ModuleRequirement {
        const get = self.module_requirements orelse return &.{};
        return get(self.module_requirements_ctx, module_id);
    }

    const RequirementIterator = struct {
        declared: []const ModuleRequirement,
        observed: []const ModuleRequirement,
        index: usize = 0,

        fn next(self: *RequirementIterator) ?ModuleRequirement {
            const i = self.index;
            self.index += 1;
            if (i < self.declared.len) return self.declared[i];
            const j = i - self.declared.len;
            return if (j < self.observed.len) self.observed[j] else null;
        }
    };

    fn templateRequirementsFor(self: *const Context, module_id: u32) RequirementIterator {
        const state = self.moduleStateConst(module_id);
        return .{
            .declared = self.requirementsFor(module_id),
            .observed = if (state) |value| value.template_observed_requirements else &.{},
        };
    }

    fn templateDependencyPristine(
        self: *const Context,
        source: *const Context,
        module_id: u32,
        seen: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror!bool {
        const visited = try seen.getOrPut(std.heap.smp_allocator, module_id);
        if (visited.found_existing) return true;
        const prototype = source.moduleStateConst(module_id) orelse return false;
        if (prototype.value == null and prototype.preinitialized == null) return false;
        if (prototype.template_invocation_dependent or
            !self.templateLibrariesPristine(prototype.template_library_dependencies)) return false;
        if (self.moduleStateConst(module_id)) |state| {
            if (state.value != null or state.preinitialized != null) {
                if (state.template_origin_context != source or state.template_invocation_dependent or !state.template_value_guard.pristine() or
                    (module_id < self.module_template_rejected.len and self.module_template_rejected[module_id])) return false;
            }
        }
        var requirements = source.templateRequirementsFor(module_id);
        while (requirements.next()) |requirement|
            if (!try self.templateRequirementPristine(source, requirement, seen)) return false;
        return true;
    }

    fn templateRequirementPristine(
        self: *const Context,
        source: *const Context,
        requirement: ModuleRequirement,
        seen: *std.AutoHashMapUnmanaged(u32, void),
    ) !bool {
        const expected = self.preparedModuleValue(requirement.module_id);
        const requested = if (self.package_loaded) |loaded|
            rawGetRuntimeBookkeeping(loaded, .{ .string = requirement.requested }) else null;
        const canonical = self.packageLoadedModuleGet(requirement.module_id, requirement.requested);
        if (requested orelse canonical) |visible| {
            if (expected == null or !visible.truthy() or !rawEqual(visible, expected.?)) return false;
        }
        if (self.requireMissMustReload(requirement.module_id, requested, canonical)) return false;
        return self.templateDependencyPristine(source, requirement.module_id, seen);
    }

    fn templateDependenciesPristine(self: *const Context, module_id: u32) !bool {
        const source = self.module_template_context orelse return true;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(std.heap.smp_allocator);
        var requirements = source.templateRequirementsFor(module_id);
        while (requirements.next()) |requirement|
            if (!try self.templateRequirementPristine(source, requirement, &seen)) return false;
        // A cold root has not published observed requirements yet. Its declared
        // imports still guard compiled static-require paths before evaluation.
        for (self.requirementsFor(module_id)) |requirement|
            if (!try self.templateRequirementPristine(source, requirement, &seen)) return false;
        return true;
    }

    fn adoptPreinitialized(
        self: *Context,
        module_id: u32,
        requested: ?[]const u8,
        state: *ModuleState,
        value: Value,
    ) anyerror!?Value {
        state.preinitialized = null;
        state.loading = true;
        errdefer {
            state.loading = false;
            if (state.value == null and state.preinitialized == null)
                state.preinitialized = value;
        }

        var valid = true;
        var requirements = self.templateRequirementsFor(module_id);
        while (requirements.next()) |requirement| {
            const expected = self.preparedModuleValue(requirement.module_id) orelse {
                valid = false;
                break;
            };
            const actual = try self.requireModuleId(requirement.module_id, requirement.requested);
            const dependency = self.moduleStateConst(requirement.module_id);
            if (!rawEqual(actual, expected) or dependency == null or !dependency.?.template_value_guard.pristine()) {
                valid = false;
                break;
            }
        }

        if (!valid) {
            if (value == .table) try value.table.invalidateExportGuard();
            state.loading = false;
            return null;
        }

        try self.packageLoadedModuleSet(module_id, requested, value);
        state.value = value;
        state.loading = false;
        return value;
    }

    pub fn loadModule(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!Value {
        return self.loadModuleMode(module_id, requested, false);
    }

    fn loadModuleMode(self: *Context, module_id: u32, requested: ?[]const u8, reload: bool) anyerror!Value {
        if (module_id >= self.module_count or module_id >= self.module_root_entries.len) return error.BadModuleId;
        if (self.moduleState(module_id)) |existing| {
            if (!reload) if (existing.value) |value| if (value.truthy()) return value;
            if (!reload) if (existing.preinitialized) |value| if (value.truthy())
                if (try self.adoptPreinitialized(module_id, requested, existing, value)) |adopted|
                    return adopted;
            if (existing.loading) return error.ModuleLoadLoop;
            if (reload) {
                existing.value = null;
                existing.preinitialized = null;
            }
        }
        if (reload) {
            // A public cache invalidation must not resurrect an old template
            // after this reload fails and leaves no installed state value.
            if (module_id < self.module_template_eligible.len)
                self.module_template_eligible[module_id] = false;
            if (module_id < self.module_template_rejected.len)
                self.module_template_rejected[module_id] = true;
        }
        const had_template = !reload and self.module_template_context != null and
            module_id < self.module_template_eligible.len and self.module_template_eligible[module_id];
        if (!reload) if (try self.instantiateModuleTemplate(module_id, requested)) |templated|
            return templated;
        const guarded_template_miss = had_template and self.module_template_eligible[module_id] and
            (module_id >= self.module_template_rejected.len or !self.module_template_rejected[module_id]);
        const dynamic_template_probe = guarded_template_miss or self.dynamicModuleTemplateCandidate(module_id);
        var observed_template_effect = false;
        const previous_template_probe = if (dynamic_template_probe)
            beginModuleTemplateEffectProbe(
                &observed_template_effect,
                self.module_template_page_scope,
            )
        else
            null;
        defer if (dynamic_template_probe)
            endModuleTemplateEffectProbe(previous_template_probe.?, observed_template_effect);
        var dependency_probe = ModuleTemplateDependencyProbe{ .ctx = self };
        const previous_dependency_probe = module_template_dependency_probe;
        if (dynamic_template_probe) module_template_dependency_probe = &dependency_probe;
        defer {
            module_template_dependency_probe = previous_dependency_probe;
            dependency_probe.requirements.deinit(std.heap.smp_allocator);
        }
        errdefer if (dynamic_template_probe) {
            observed_template_effect = true;
            if (!guarded_template_miss) self.module_template_rejected[module_id] = true;
        };
        const state = try self.ensureModuleState(module_id);
        if (dynamic_template_probe and state.template_init_probe_id == 0)
            state.template_init_probe_id = module_template_probe_id;
        self.template_library_installation_closed = true;
        state.loading = true;
        errdefer state.loading = false;
        if (dynamic_template_probe) for (self.requirementsFor(module_id)) |requirement| {
            if (self.moduleStateConst(requirement.module_id)) |dependency|
                if (dependency.value != null or dependency.preinitialized != null) {
                    if (!dependency.template_value_guard.pristine() or dependency.template_invocation_dependent)
                        observeInvocationGlobalAccess();
                };
        };

        const canonical = self.canonicalModuleName(module_id, requested);
        var owned_values: ?[]const Value = null;
        defer if (owned_values) |values| freeResults(values);
        var root_executed = false;
        var value: Value = value_blk: {
            const previous_allocation_probe = module_template_allocation_mutation_probe;
            module_template_allocation_mutation_probe = &state.template_mutation_probe_id;
            defer module_template_allocation_mutation_probe = previous_allocation_probe;
            break :value_blk if (self.static_module) |load|
                if (try load(self.static_module_ctx, self, module_id)) |static_value|
                    static_value
                else blk: {
                    root_executed = true;
                    const argv: []const Value = if (canonical) |text| &.{.{ .string = text }} else &.{};
                    const previous_globals = try self.enterModule(module_id);
                    defer self.restoreModule(previous_globals);
                    if (work_stats.current()) |work| work.module_roots +|= 1;
                    var root_frame: work_stats.RootFrame = .{};
                    work_stats.beginRoot(&root_frame, module_id);
                    defer work_stats.endRoot(&root_frame);
                    const values = try self.callEntry(self.module_root_entries[module_id], .{ .direct = &.{} }, argv);
                    owned_values = values;
                    break :blk if (values.len == 0) .nil else values[0];
                }
            else blk: {
                root_executed = true;
                const argv: []const Value = if (canonical) |text| &.{.{ .string = text }} else &.{};
                const previous_globals = try self.enterModule(module_id);
                defer self.restoreModule(previous_globals);
                if (work_stats.current()) |work| work.module_roots +|= 1;
                var root_frame: work_stats.RootFrame = .{};
                work_stats.beginRoot(&root_frame, module_id);
                defer work_stats.endRoot(&root_frame);
                const values = try self.callEntry(self.module_root_entries[module_id], .{ .direct = &.{} }, argv);
                owned_values = values;
                break :blk if (values.len == 0) .nil else values[0];
            };
        };
        if (value == .nil) {
            // A forced public reload uses the requested key, including false;
            // an old canonical alias entry must not hide that value.
            if (reload and requested != null) {
                if (self.package_loaded) |loaded| {
                    if (rawGetRuntimeBookkeeping(loaded, .{ .string = requested.? })) |existing| value = existing;
                }
            } else if (self.packageLoadedModuleGet(module_id, requested)) |existing| value = existing;
            if (value == .nil) value = .{ .boolean = true };
        }
        // These ordinary root executions already lack a reusable template proof.
        // Do not traverse their values or invalidate a returned dependency's guard.
        const skip_value_guard = root_executed and (guarded_template_miss or
            (dynamic_template_probe and observed_template_effect) or
            (module_id < self.module_template_rejected.len and self.module_template_rejected[module_id]));
        const value_guard = if (skip_value_guard)
            ModuleValueGuard{ .valid = false }
        else
            try self.prepareModuleValueGuard(value);
        const observed_requirements = if (dynamic_template_probe)
            try self.retainModuleRequirements(dependency_probe.requirements.items) else &.{};
        try self.packageLoadedModuleSet(module_id, requested, value);
        state.value = value;
        state.template_origin_context = null;
        if (dynamic_template_probe) {
            state.template_library_dependencies = module_template_library_dependencies;
            state.template_invocation_dependent = guarded_template_miss or observed_template_effect;
            state.template_observed_requirements = observed_requirements;
        }
        if (dynamic_template_probe and module_template_effect_reasons & (1 << 3) != 0)
            state.template_package_observed = true;
        if (dynamic_template_probe and module_template_effect_reasons & (1 << 5) != 0)
            state.template_page_scoped_only = true;
        if (!root_executed) try self.tagModuleTemplateValue(
            value,
            &state.template_mutation_probe_id,
        );
        state.template_value_guard = value_guard;
        state.loading = false;
        if (dynamic_template_probe and !guarded_template_miss) {
            if (observed_template_effect) {
                if (work_stats.current()) |work| if (work.sampled)
                    work_stats.logLine("module template reject: id={d} page_scope={} reasons=0x{x} name={s}\n", .{
                        module_id,
                        self.module_template_page_scope,
                        module_template_effect_reasons,
                        canonical orelse "",
                    });
                self.module_template_rejected[module_id] = true;
            } else {
                const promoted = self.promoteModuleTemplate(module_id, requested) catch |err| switch (err) {
                    error.UnsupportedModuleTemplate => blk: {
                        self.module_template_eligible[module_id] = false;
                        self.module_template_rejected[module_id] = true;
                        if (self.module_template_context) |target| {
                            if (target.moduleState(module_id)) |template_state|
                                template_state.* = .{};
                        }
                        break :blk false;
                    },
                    else => return err,
                };
                if (promoted and self.module_template_page_scope and
                    !state.template_page_scoped_only)
                {
                    if (self.module_template_context) |page_template|
                        _ = page_template.promoteModuleTemplateUpstream(module_id, requested) catch false;
                }
                if (!promoted) if (work_stats.current()) |work| if (work.sampled)
                    work_stats.logLine("module template reject: id={d} page_scope={} reasons=0x{x} name={s}\n", .{
                        module_id,
                        self.module_template_page_scope,
                        module_template_effect_reasons,
                        canonical orelse "",
                    });
            }
        }
        return value;
    }

    pub fn ensureModule(self: *Context, module_id: u32) anyerror!void {
        _ = try self.loadModule(module_id, null);
    }

    fn missingModule(raw_name: []const u8) error{ModuleNotFound} {
        work_stats.logLine("module lookup missing: name={s}\n", .{raw_name});
        return error.ModuleNotFound;
    }

    pub fn resolveModule(self: *const Context, raw_name: []const u8) !u32 {
        const lookup = self.module_lookup orelse return missingModule(raw_name);
        if (lookup(self.module_lookup_ctx, raw_name)) |id| return id;
        if (self.namespace_catalog) |registry| {
            const name = (try registry.normalizeModuleLoader(self.allocator, raw_name)) orelse return missingModule(raw_name);
            defer self.allocator.free(name);
            return lookup(self.module_lookup_ctx, name) orelse missingModule(raw_name);
        }
        const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
        if (std.mem.indexOfScalar(u8, trimmed, '_') == null)
            return lookup(self.module_lookup_ctx, trimmed) orelse missingModule(raw_name);
        const normalized = try self.allocator.dupe(u8, trimmed);
        defer self.allocator.free(normalized);
        std.mem.replaceScalar(u8, normalized, '_', ' ');
        return lookup(self.module_lookup_ctx, normalized) orelse missingModule(raw_name);
    }

    fn requireMissMustReload(self: *const Context, module_id: u32, requested_cache: ?Value, canonical_cache: ?Value) bool {
        if (requested_cache) |value| return !value.truthy();
        if (canonical_cache) |value| return !value.truthy();
        const state = self.moduleStateConst(module_id) orelse return false;
        if (state.value) |value| {
            if (!value.truthy()) return true;
            return self.package_loaded != null and !state.deferred_require_visibility;
        }
        if (state.preinitialized) |value| return !value.truthy();
        return false;
    }

    fn observeRequiredTemplateValue(self: *const Context, module_id: ?u32, raw_name: []const u8, value: Value) !void {
        if (module_template_effect_probe == null) return;
        if (module_id) |id| {
            if (self.moduleStateConst(id)) |state| if (state.value orelse state.preinitialized) |expected| {
                if (rawEqual(value, expected)) {
                    if (module_template_dependency_probe) |probe| try probe.record(self, id, raw_name);
                    module_template_library_dependencies |= state.template_library_dependencies;
                    if (state.template_invocation_dependent or
                        !state.template_value_guard.pristine() or
                        (self.module_template_context != null and state.template_origin_context != self.module_template_context) or
                        (id < self.module_template_rejected.len and self.module_template_rejected[id]) or
                        !self.templateLibrariesPristine(state.template_library_dependencies))
                        observeInvocationGlobalAccess();
                    return;
                }
            };
            // A public package.loaded override is invocation data, not the
            // prototype selected by this module ID.
            observeInvocationGlobalAccess();
            return;
        }
        if (value == .table) if (value.table.native_namespace) |namespace| {
            const name: []const u8 = switch (namespace) {
                .table => "table", .string => "string", .math => "math", .debug => "debug",
                .os => "os", .package => "package", .bit32 => "bit32", .library_util => "libraryUtil", .mw => "mw",
                else => "",
            };
            if (name.len != 0 and std.mem.eql(u8, name, raw_name) and
                self.template_native_namespaces[@backingInt(namespace)] == value.table) return;
        };
        observeInvocationGlobalAccess();
    }

    fn cachedRequiredValue(self: *const Context, raw_name: []const u8, value: Value) !Value {
        if (module_template_effect_probe == null) return value;
        const id = if (self.module_lookup) |lookup| lookup(self.module_lookup_ctx, raw_name) else null;
        try self.observeRequiredTemplateValue(id, raw_name, value);
        return value;
    }

    pub fn requireModuleId(self: *Context, module_id: u32, raw_name: []const u8) anyerror!Value {
        const canonical = self.canonicalModuleName(module_id, null);
        const canonical_request = if (canonical) |name| std.mem.eql(u8, name, raw_name) else false;
        const canonical_cache = self.packageLoadedModuleGet(module_id, raw_name);
        const requested_cache = if (canonical_request) canonical_cache else if (self.package_loaded) |loaded|
            rawGetRuntimeBookkeeping(loaded, .{ .string = raw_name }) else null;
        if (requested_cache) |value| if (value.truthy()) {
            try self.observeRequiredTemplateValue(module_id, raw_name, value);
            return value;
        };
        if (self.eager_bootstrap)
            return self.preparedModuleValue(module_id) orelse error.EagerDependencyNotInitialized;
        // Loader-search syntax failures precede mutation of package.loaded.
        // This getter is supplied by the separate syntax-error-root change.
        try self.checkModuleLoadError(module_id);
        // Clear an old false only after a valid loader has been found. A nil
        // result then defaults to true, while a false written by the loader
        // remains distinguishable by the post-root raw cache read.
        if (requested_cache) |cached| if (!cached.truthy()) {
            if (self.package_loaded) |loaded|
                try self.rawSetRuntimeBookkeeping(loaded, .{ .string = raw_name }, .nil);
        };
        const value = try self.loadModuleMode(module_id, raw_name, self.requireMissMustReload(module_id, requested_cache, canonical_cache));
        if (!canonical_request)
            try self.packageLoadedRequestedSet(raw_name, value);
        if (self.moduleState(module_id)) |state| state.deferred_require_visibility = false;
        try self.observeRequiredTemplateValue(module_id, raw_name, value);
        return value;
    }

    pub fn requireByName(self: *Context, raw_name: []const u8) anyerror!Value {
        if (std.mem.eql(u8, raw_name, "package")) try self.observePackage();
        if (self.package_loaded) |loaded| {
            if (self.program_shapes_validated and loaded.native_namespace == null and
                self.package_loaded_shape_id != null and
                self.package_loaded_shape_id.? < self.program_shapes.len and
                loaded.shape == &self.program_shapes[self.package_loaded_shape_id.?] and
                self.package_loaded_slot_modules.len != 0)
            {
                const key = Value{ .string = raw_name };
                const slot = loaded.slotForKey(key);
                if (slot) |known| if (rawGetSlotRuntimeBookkeeping(loaded, known)) |value| if (value.truthy()) return self.cachedRequiredValue(raw_name, value);
                if (rawGetAfterSlotRuntimeBookkeeping(loaded, key)) |value| if (value.truthy()) return self.cachedRequiredValue(raw_name, value);
                if (slot) |known| if (known < self.package_loaded_slot_modules.len) {
                    const module_id = self.package_loaded_slot_modules[known];
                    if (module_id < self.module_count) if (self.canonicalModuleName(module_id, null)) |canonical| {
                        if (std.mem.eql(u8, canonical, raw_name)) {
                            return self.requireModuleId(module_id, raw_name);
                        }
                    };
                };
            } else if (rawGetRuntimeBookkeeping(loaded, .{ .string = raw_name })) |value| if (value.truthy()) return self.cachedRequiredValue(raw_name, value);
        }
        return self.requireModuleId(try self.resolveModule(raw_name), raw_name);
    }

    pub fn callValueFixed(self: *Context, callable: Value, args: []const Value, result_buffer: []Value) anyerror!FixedCallResult {
        return switch (callable) {
            .callable => |function| if (function.id == native_function_id) blk: {
                const values = try self.callEntryBuffered(function.entry, function.captures(), args, result_buffer);
                break :blk .{ .values = values, .owned = values.len != 0 and values.ptr != result_buffer.ptr };
            } else blk: {
                const values = try self.callFunctionBuffered(function, args, result_buffer);
                break :blk .{ .values = values, .owned = values.len != 0 and values.ptr != result_buffer.ptr };
            },
            .table => blk: {
                const method = self.metamethod(callable, "__call") orelse return error.NotCallable;
                var storage: [8]Value = undefined;
                const all = try mergeSmallValues(&storage, &.{callable}, args);
                defer freeSmallValues(all, &storage);
                break :blk try self.callValueFixed(method, all, result_buffer);
            },
            else => error.NotCallable,
        };
    }

    pub fn callValue(self: *Context, callable: Value, args: []const Value) anyerror![]const Value {
        return switch (callable) {
            .callable => |value| self.callFunction(value, args),
            .table => blk: {
                const method = self.metamethod(callable, "__call") orelse return error.NotCallable;
                var storage: [8]Value = undefined;
                const all = try mergeSmallValues(&storage, &.{callable}, args);
                defer freeSmallValues(all, &storage);
                break :blk switch (method) {
                    .callable => |value| try self.callFunction(value, all),
                    else => try self.callValue(method, all),
                };
            },
            else => error.NotCallable,
        };
    }

    // Lua indexing, arithmetic and comparison consume exactly the first
    // result. Pass that demand through the native ABI instead of allocating a
    // variable result array only to throw away its tail. The callee still
    // evaluates every return expression and performs all side effects.
    pub fn callValueFirst(self: *Context, callable: Value, args: []const Value) anyerror!Value {
        var buffer: [1]Value = undefined;
        const result = try self.callValueFixed(callable, args, &buffer);
        defer result.deinit();
        return if (result.values.len == 0) .nil else result.values[0];
    }
    pub fn newNative(self: *Context, host: ?*anyopaque, comptime call: anytype) !Value {
        const identity = try self.takeFunctionIdentity();
        return self.storeFunction(.{
            .id = native_function_id,
            .env = FunctionEnv.native(host),
            .identity = identity,
            .entry = stabilizeNative(call),
        });
    }

    pub fn newNativeBuffered(self: *Context, host: ?*anyopaque, comptime call: anytype) !Value {
        const identity = try self.takeFunctionIdentity();
        return self.storeFunction(.{
            .id = native_function_id,
            .env = FunctionEnv.native(host),
            .identity = identity,
            .entry = stabilizeNativeBuffered(call),
        });
    }

    fn assignFieldCacheIdentity(self: *Context, table: *Table) void {
        if (self.field_cache_nonce != 0 and self.next_field_cache_table_nonce != 0) {
            table.field_cache_owner_nonce = self.field_cache_nonce;
            table.field_cache_nonce = self.next_field_cache_table_nonce;
            self.next_field_cache_table_nonce = if (self.next_field_cache_table_nonce == std.math.maxInt(u64))
                0
            else
                self.next_field_cache_table_nonce + 1;
        }
    }

    pub fn newTable(self: *Context) !*Table {
        // Lua object headers have a context lifetime. Pool them with closure
        // descriptors and cells; resizable table storage still uses the
        // ordinary allocator so rollback and explicit frees reclaim it.
        const table = try self.stringAllocator().create(Table);
        table.* = .{
            .module_template_mutation_probe = module_template_allocation_mutation_probe,
            .module_template_probe_id = module_template_probe_owner_id,
            .invoke_rollback_owner_nonce = self.field_cache_nonce,
            .invoke_rollback_allocation_id = currentInvokeRollbackId(),
        };
        self.assignFieldCacheIdentity(table);
        return table;
    }

    pub fn newCell(self: *Context, initial: Value) !*Cell {
        const cell = try self.stringAllocator().create(Cell);
        cell.* = .{ .value = initial };
        return cell;
    }

    /// Release a table returned by a Context constructor. Its header belongs
    /// to the context arena; its mutable buffers have independent allocations.
    pub fn destroyTable(self: *Context, table: *Table) void {
        if (table.export_guard_root) |guard| guard.table = null;
        table.deinit(self.allocator);
        self.stringAllocator().destroy(table);
    }

    pub fn newArrayTable(self: *Context, capacity: u32) !*Table {
        const table = try self.newTable();
        errdefer self.destroyTable(table);
        if (capacity != 0) {
            table.slots = try self.allocator.alloc(Value, capacity);
            @memset(table.slots, .nil);
        }
        return table;
    }

    fn allocShapedTable(self: *Context, shape: *const Shape) !*Table {
        const table = try self.stringAllocator().create(Table);
        table.* = .{
            .shape = shape,
            .module_template_mutation_probe = module_template_allocation_mutation_probe,
            .module_template_probe_id = module_template_probe_owner_id,
            .invoke_rollback_owner_nonce = self.field_cache_nonce,
            .invoke_rollback_allocation_id = currentInvokeRollbackId(),
        };
        errdefer self.destroyTable(table);
        self.assignFieldCacheIdentity(table);
        if (shape.field_count != 0) {
            table.slots = try self.allocator.alloc(Value, shape.field_count);
            @memset(table.slots, .nil);
        }
        if (shape.choice_count != 0) {
            table.choices = try self.allocator.alloc(ChoiceCell, shape.choice_count);
            @memset(table.choices, .{});
        }
        try table.initSlotHistory(self.allocator);
        return table;
    }

    pub fn newShapedTable(self: *Context, shape: *const Shape) !*Table {
        if (!shape.validStorage() or
            shape.sorted_string_slots.len > shape.field_count)
            return error.BadShape;
        var previous_string: ?[]const u8 = null;
        for (shape.sorted_string_slots) |slot| {
            const current = shape.stringKeyAt(slot) orelse return error.BadShape;
            if (previous_string) |previous|
                if (std.mem.order(u8, previous, current) != .lt)
                    return error.BadShape;
            previous_string = current;
        }
        if (shape.string_lookup_slots.len != 0) {
            const slots = shape.string_lookup_slots;
            if (slots.len & (slots.len - 1) != 0) return error.BadShape;
            var occupied: usize = 0;
            for (slots) |encoded| {
                if (encoded == 0) continue;
                if (shape.stringKeyAt(encoded - 1) == null) return error.BadShape;
                occupied += 1;
            }
            if (occupied == slots.len) return error.BadShape;
            for (0..shape.field_count) |index| {
                const key = shape.keyAt(index) orelse return error.BadShape;
                if (key != .string) continue;
                const resolved = indexedShapeStringSlot(shape, key.string, stringValueHash(key.string)) orelse
                    return error.BadShape;
                // In field order, a duplicate can only resolve backward.
                // A first occurrence must resolve exactly to its own slot.
                if (resolved > index) return error.BadShape;
            }
        }
        return self.allocShapedTable(shape);
    }

    pub fn newProgramShape(self: *Context, shape_id: u32) !*Table {
        if (shape_id >= self.program_shapes.len) return error.BadShape;
        const shape = &self.program_shapes[shape_id];
        return if (self.program_shapes_validated)
            self.allocShapedTable(shape)
        else
            self.newShapedTable(shape);
    }

    pub fn newFrameArgsTable(self: *Context) !*Table {
        return if (self.frame_args_shape_id) |shape_id|
            self.newProgramShape(shape_id)
        else
            self.newTable();
    }

    pub fn newPackageLoadedTable(self: *Context) !*Table {
        const table = if (self.package_loaded_shape_id) |shape_id| blk: {
            if (shape_id >= self.program_shapes.len) return error.BadShape;
            if (self.package_loaded_tail != null) return error.PackageLoadedAlreadyInitialized;
            const shape = &self.program_shapes[shape_id];
            const owned = try self.stringAllocator().create(Table);
            errdefer self.stringAllocator().destroy(owned);
            const tail = try GlobalTail.initEmpty(self.allocator, shape.field_count);
            errdefer {
                tail.deinit();
                self.allocator.destroy(tail);
            }
            owned.* = .{
                .shape = shape,
                .global_tail = tail,
                .module_template_mutation_probe = module_template_allocation_mutation_probe,
                .module_template_probe_id = module_template_probe_owner_id,
                .invoke_rollback_owner_nonce = self.field_cache_nonce,
                .invoke_rollback_allocation_id = currentInvokeRollbackId(),
            };
            try owned.initSlotHistory(self.allocator);
            self.assignFieldCacheIdentity(owned);
            self.package_loaded_tail = tail;
            break :blk owned;
        } else try self.newTable();
        table.module_template_reconstructable = true;
        return table;
    }

    pub fn newJsonObjectTable(self: *Context) !*Table {
        return if (self.json_object_shape_id) |shape_id|
            self.newProgramShape(shape_id)
        else
            self.newTable();
    }

    pub fn newUriQueryTable(self: *Context) !*Table {
        return if (self.uri_query_shape_id) |shape_id|
            self.newProgramShape(shape_id)
        else
            self.newTable();
    }

    pub const ProgramFieldSlot = struct { shape_id: u32, slot: u32 };

    pub fn moduleExportSlot(self: *const Context, module_id: u32, name: []const u8) ?ProgramFieldSlot {
        if (module_id >= self.module_export_shape_ids.len) return null;
        const shape_id = self.module_export_shape_ids[module_id];
        if (shape_id == std.math.maxInt(u32) or shape_id >= self.program_shapes.len) return null;
        const slot = shapeStringSlot(&self.program_shapes[shape_id], name) orelse return null;
        return .{ .shape_id = shape_id, .slot = slot };
    }

    pub fn getProgramShapeField(self: *Context, object: Value, shape_id: u32, slot: u32, name: []const u8) !Value {
        if (object == .table and shape_id < self.program_shapes.len and object.table.shape == &self.program_shapes[shape_id]) {
            if (object.table.rawGetSlot(slot)) |value| return value;
            if (object.table.metatable == null) return .nil;
        }
        return self.getIndex(object, .{ .string = name });
    }

    pub fn getProgramShapeIndex(self: *Context, object: Value, shape_id: u32, slot: u32, key: Value) !Value {
        if (object == .table and shape_id < self.program_shapes.len and object.table.shape == &self.program_shapes[shape_id]) {
            if (object.table.fieldKey(slot)) |expected| if (rawEqual(expected, key)) {
                if (object.table.rawGetSlot(slot)) |value| return value;
                if (object.table.metatable == null) return .nil;
            };
        }
        return self.getIndex(object, key);
    }

    pub fn getProgramShapeDynamic(self: *Context, object: Value, shape_id: u32, key: Value) !Value {
        if (object == .table and shape_id < self.program_shapes.len and object.table.shape == &self.program_shapes[shape_id]) {
            if (object.table.slotForKey(key)) |slot| {
                if (object.table.rawGetSlot(slot)) |value| return value;
                if (object.table.metatable == null) return .nil;
            }
        }
        return self.getIndex(object, key);
    }

    /// Dynamic-key access with structural priority. Any shaped/native table uses
    /// its slot layout first; truly open/shapeless tables and misses retain
    /// ordinary Lua indexing and metamethod behavior.
    pub fn getStructuralIndex(self: *Context, object: Value, key: Value) !Value {
        if (object == .table) {
            const table = object.table;
            if (table.shape != null or table.native_namespace != null) {
                if (table.slotForKey(key)) |slot| {
                    if (table.rawGetSlot(slot)) |value| return value;
                    if (table.metatable == null) return .nil;
                }
            }
        }
        return self.getIndex(object, key);
    }

    pub fn getTypedArrayIndex(self: *Context, object: Value, key: Value) !Value {
        if (object == .table and key == .number) {
            if (object.table.rawGetNumber(key.number)) |value| return value;
            if (object.table.metatable == null) return .nil;
        }
        return self.getIndex(object, key);
    }

    pub fn getKnownNativeField(
        self: *Context,
        object: Value,
        namespace: static_fields.Namespace,
        slot: u32,
        name: []const u8,
    ) !Value {
        if (object == .table and object.table.native_namespace == namespace) {
            if (namespace == .namespace_map) {
                if (object.table.rawGet(.{ .string = name })) |override| return override;
                // Namespace identities are edition metadata, not ABI constants.
                return self.getIndex(object, .{ .string = name });
            }
            if (object.table.fieldKey(slot)) |expected|
                if (rawEqual(expected, .{ .string = name })) {
                    if (object.table.rawGetSlot(slot)) |value| return value;
                    if (object.table.metatable == null) return .nil;
                };
        }
        return self.getIndex(object, .{ .string = name });
    }

    pub fn setKnownNativeField(
        self: *Context,
        object: Value,
        namespace: static_fields.Namespace,
        slot: u32,
        name: []const u8,
        value: Value,
    ) !void {
        if (object == .table and object.table.native_namespace == namespace) {
            if (object.table.fieldKey(slot)) |expected|
                if (rawEqual(expected, .{ .string = name })) {
                    if (object.table.rawGetSlot(slot) != null or object.table.metatable == null) {
                        try object.table.rawSetSlot(slot, value);
                        return;
                    }
                };
        }
        try self.setIndex(object, .{ .string = name }, value);
    }

    pub fn setProgramShapeIndex(self: *Context, object: Value, shape_id: u32, slot: u32, key: Value, value: Value) !void {
        if (object == .table and shape_id < self.program_shapes.len and object.table.shape == &self.program_shapes[shape_id]) {
            if (object.table.fieldKey(slot)) |expected| if (rawEqual(expected, key)) {
                if (object.table.rawGetSlot(slot) != null or object.table.metatable == null) {
                    try object.table.rawSetSlot(slot, value);
                    return;
                }
            };
        }
        try self.setIndex(object, key, value);
    }

    pub fn setProgramShapeDynamic(self: *Context, object: Value, shape_id: u32, key: Value, value: Value) !void {
        if (object == .table and shape_id < self.program_shapes.len and object.table.shape == &self.program_shapes[shape_id]) {
            if (object.table.slotForKey(key)) |slot| {
                if (object.table.rawGetSlot(slot) != null or object.table.metatable == null) {
                    try object.table.rawSetSlot(slot, value);
                    return;
                }
            }
        }
        try self.setIndex(object, key, value);
    }

    /// Dynamic-key write with structural priority. Open structural tables still
    /// fall through for keys outside their declared slot set.
    pub fn setStructuralIndex(self: *Context, object: Value, key: Value, value: Value) !void {
        if (object == .table) {
            const table = object.table;
            if (table.shape != null or table.native_namespace != null) {
                if (table.slotForKey(key)) |slot| {
                    if (table.rawGetSlot(slot) != null or table.metatable == null) {
                        try table.rawSetSlot(slot, value);
                        return;
                    }
                }
            }
        }
        try self.setIndex(object, key, value);
    }

    pub fn newNativeNamespace(self: *Context, namespace: static_fields.Namespace) !*Table {
        const table = try self.stringAllocator().create(Table);
        table.* = .{
            .native_namespace = namespace,
            .module_template_mutation_probe = module_template_allocation_mutation_probe,
            .module_template_probe_id = module_template_probe_owner_id,
            .invoke_rollback_owner_nonce = self.field_cache_nonce,
            .invoke_rollback_allocation_id = currentInvokeRollbackId(),
        };
        errdefer self.destroyTable(table);
        const count = static_fields.fieldCount(namespace);
        if (count != 0) {
            table.slots = try self.allocator.alloc(Value, count);
            @memset(table.slots, .nil);
        }
        try table.initSlotHistory(self.allocator);
        if (templateSingletonNamespace(namespace))
            self.template_native_namespaces[@backingInt(namespace)] = table;
        return table;
    }

    pub fn metamethod(_: *Context, value: Value, name: []const u8) ?Value {
        if (value == .table) value.table.notePackageStateAccess();
        const mt = switch (value) {
            .table => |table| table.metatable,
            else => null,
        } orelse return null;
        return mt.rawGet(.{ .string = name });
    }
    pub fn getIndex(self: *Context, object: Value, key: Value) anyerror!Value {
        switch (object) {
            .table => |table| {
                if (table.rawGet(key)) |value| return value;
                if (table.metatable) |mt| if (mt.rawGet(.{ .string = "__index" })) |indexer| {
                    return switch (indexer) {
                        .table => |other| self.getIndex(.{ .table = other }, key),
                        else => self.callValueFirst(indexer, &.{ object, key }),
                    };
                };
                return .nil;
            },
            .string => {
                if (self.string_metatable) |mt| if (mt.rawGet(.{ .string = "__index" })) |indexer| {
                    if (indexer == .table) return indexer.table.rawGet(key) orelse .nil;
                    return self.callValueFirst(indexer, &.{ object, key });
                };
                return error.IndexType;
            },
            else => return error.IndexType,
        }
    }
    // The key hash is compiled from the exact immutable field-name bytes. Only
    // lookup work is reused: Values and each __index handler remain live reads.
    fn getHashedFieldAfterOwnMiss(self: *Context, object: Value, table: *Table, name: []const u8, key_hash: u64) anyerror!Value {
        const index_hash = comptime static_fields.hashStringKey("__index");
        if (table.metatable) |mt| if (mt.rawGetHashedString("__index", index_hash)) |indexer| {
            return switch (indexer) {
                .table => |other| self.getHashedField(.{ .table = other }, name, key_hash),
                else => self.callValueFirst(indexer, &.{ object, .{ .string = name } }),
            };
        };
        return .nil;
    }

    fn programShapeId(self: *const Context, shape: *const Shape) ?u32 {
        if (self.program_shape_generation == 0 or self.program_shapes.len == 0) return null;
        const first = @intFromPtr(self.program_shapes.ptr);
        const address = @intFromPtr(shape);
        if (address < first) return null;
        const delta = address - first;
        if (delta % @sizeOf(Shape) != 0) return null;
        const index = delta / @sizeOf(Shape);
        if (index >= self.program_shapes.len or index > std.math.maxInt(u32)) return null;
        return @intCast(index);
    }

    fn inheritedCacheable(table: *const Table) bool {
        return table.field_cache_nonce != 0 and table.native_namespace == null and
            table.owns_slots and table.global_tail == null and table.choices.len == 0;
    }

    fn inheritedCacheHit(self: *Context, receiver: *Table, site_id: u64) ?Value {
        const cached = &inherited_site_cache[inheritedSiteIndex(site_id)];
        if (cached.site_id != site_id or cached.context_nonce != self.field_cache_nonce or
            cached.count == 0 or cached.count > inherited_link_limit) return null;
        var current = receiver;
        for (cached.hops[0..cached.count]) |hop| {
            if (hop.table != current or current.field_cache_owner_nonce != hop.owner_nonce or
                current.field_cache_nonce != hop.nonce or current.field_cache_epoch != hop.epoch or
                current.shape != hop.shape or !inheritedCacheable(current) or
                (hop.own_slot != null and hop.own_slot.?.* != .nil) or
                (hop.own_map_value != null and hop.own_map_value.?.* != .nil)) return null;
            const mt = current.metatable orelse return null;
            if (mt != hop.metatable or mt.field_cache_owner_nonce != hop.mt_owner_nonce or
                mt.field_cache_nonce != hop.mt_nonce or mt.field_cache_epoch != hop.mt_epoch or
                mt.shape != hop.mt_shape or !inheritedCacheable(mt)) return null;
            const indexer = hop.index_value.*;
            if (indexer != .table or indexer.table != hop.parent) return null;
            current = hop.parent;
        }
        const terminal = cached.terminal;
        if (terminal.table != current or current.field_cache_owner_nonce != terminal.owner_nonce or
            current.field_cache_nonce != terminal.nonce or current.field_cache_epoch != terminal.epoch or
            current.shape != terminal.shape or !inheritedCacheable(current)) return null;
        const value = terminal.value orelse return null;
        return if (value.* == .nil) null else value.*;
    }

    // Called after the receiver's own search. Every subsequent own lookup is
    // performed once, and its nil locations become guards for a future hit.
    fn inheritedCacheFill(self: *Context, receiver: *Table, first_miss: Table.OwnMissWitness, name: []const u8, key_hash: u64, site_id: u64) anyerror!Value {
        var candidate = InheritedSiteCache{ .site_id = site_id, .context_nonce = self.field_cache_nonce };
        var current = receiver;
        var witness = first_miss;
        const index_hash = comptime static_fields.hashStringKey("__index");
        while (true) {
            if (candidate.count == inherited_link_limit or !inheritedCacheable(current))
                return self.getHashedFieldAfterOwnMiss(.{ .table = current }, current, name, key_hash);
            const mt = current.metatable orelse return .nil;
            if (!inheritedCacheable(mt))
                return self.getHashedFieldAfterOwnMiss(.{ .table = current }, current, name, key_hash);
            var index_miss: Table.OwnMissWitness = .{};
            const index_value = mt.ownHashedStringValuePtr("__index", index_hash, &index_miss) orelse return .nil;
            if (index_value.* != .table)
                return self.getHashedFieldAfterOwnMiss(.{ .table = current }, current, name, key_hash);
            const parent = index_value.table;
            if (!inheritedCacheable(parent))
                return self.getHashedField(.{ .table = parent }, name, key_hash);
            candidate.hops[candidate.count] = .{
                .table = current,
                .owner_nonce = current.field_cache_owner_nonce,
                .nonce = current.field_cache_nonce,
                .epoch = current.field_cache_epoch,
                .shape = current.shape,
                .own_slot = witness.slot,
                .own_map_value = witness.map_value,
                .metatable = mt,
                .mt_owner_nonce = mt.field_cache_owner_nonce,
                .mt_nonce = mt.field_cache_nonce,
                .mt_epoch = mt.field_cache_epoch,
                .mt_shape = mt.shape,
                .index_value = index_value,
                .parent = parent,
            };
            candidate.count += 1;
            var parent_miss: Table.OwnMissWitness = .{};
            if (parent.ownHashedStringValuePtr(name, key_hash, &parent_miss)) |value| {
                candidate.terminal = .{
                    .table = parent,
                    .owner_nonce = parent.field_cache_owner_nonce,
                    .nonce = parent.field_cache_nonce,
                    .epoch = parent.field_cache_epoch,
                    .shape = parent.shape,
                    .value = value,
                };
                inherited_site_cache[inheritedSiteIndex(site_id)] = candidate;
                return value.*;
            }
            // A retained nil cell is absent. Keep its address as a witness so
            // later revival invalidates this inherited path even without an
            // epoch change, and continue through the parent's metatable.
            current = parent;
            witness = parent_miss;
        }
    }

    pub fn getFieldAtSite(self: *Context, object: Value, name: []const u8, key_hash: u64, site_id: u64) anyerror!Value {
        if (object == .table) object.table.notePackageStateAccess();
        if (object != .table or self.field_cache_nonce == 0 or object.table.field_cache_nonce == 0 or
            object.table.native_namespace != null or !object.table.owns_slots or object.table.global_tail != null or object.table.choices.len != 0)
            return self.getHashedField(object, name, key_hash);
        const table = object.table;
        const cache_index: usize = fieldCacheIndex(site_id);
        const shape_entry = &FieldCacheStorage.dict_lua_shape_site_cache[cache_index];
        const entry = &FieldCacheStorage.dict_lua_field_cache[cache_index];
        if (positiveFieldCacheHit(self, &object, site_id, &FieldCacheStorage.dict_lua_field_cache, &FieldCacheStorage.dict_lua_shape_site_cache)) |value|
            return value.*;
        if (table.metatable != null) if (self.inheritedCacheHit(table, site_id)) |value| return value;
        var own_witness: Table.OwnMissWitness = .{};
        const known_shape = if (table.shape) |shape| self.programShapeId(shape) else null;
        const own_value = if (known_shape) |shape_id| blk: {
            const slot: ?u32 = if (shape_entry.site_id == site_id and
                shape_entry.program_generation == self.program_shape_generation and
                shape_entry.shape_id == shape_id)
                (if (shape_entry.slot == std.math.maxInt(u32)) null else shape_entry.slot)
            else resolve: {
                const resolved = table.slotForString(name, key_hash);
                shape_entry.* = .{
                    .site_id = site_id,
                    .program_generation = self.program_shape_generation,
                    .shape_id = shape_id,
                    .slot = resolved orelse std.math.maxInt(u32),
                };
                break :resolve resolved;
            };
            break :blk table.ownHashedStringValuePtrAtSlot(name, key_hash, slot, &own_witness);
        } else table.ownHashedStringValuePtr(name, key_hash, &own_witness);
        if (own_value) |value| {
            entry.* = .{ .site_id = site_id, .context_nonce = self.field_cache_nonce, .owner_context_nonce = table.field_cache_owner_nonce, .table_nonce = table.field_cache_nonce, .table_epoch = table.field_cache_epoch, .table = table, .value = value };
            return value.*;
        }
        return self.inheritedCacheFill(table, own_witness, name, key_hash, site_id);
    }

    /// Static field access on a value whose exact table shape is not known by
    /// the compiler. Prefer the live table's structural slot immediately, then
    /// retain the ordinary site-cache / hash / metamethod path as the semantic
    /// fallback for truly dynamic or overflow fields.
    pub fn getStructuralFieldAtSite(
        self: *Context,
        object: Value,
        name: []const u8,
        key_hash: u64,
        site_id: ?u64,
    ) anyerror!Value {
        if (object == .table) {
            const table = object.table;
            if (table.shape != null or table.native_namespace != null) {
                if (table.slotForString(name, key_hash)) |slot| {
                    if (table.rawGetSlot(slot)) |value| return value;
                    if (table.metatable == null) return .nil;
                }
            }
        }
        return if (site_id) |site|
            self.getFieldAtSite(object, name, key_hash, site)
        else
            self.getHashedField(object, name, key_hash);
    }

    pub fn getHashedField(self: *Context, object: Value, name: []const u8, key_hash: u64) anyerror!Value {
        const index_hash = comptime static_fields.hashStringKey("__index");
        switch (object) {
            .table => |table| {
                if (table.rawGetHashedString(name, key_hash)) |value| return value;
                return self.getHashedFieldAfterOwnMiss(object, table, name, key_hash);
            },
            .string => {
                if (self.string_metatable) |mt| if (mt.rawGetHashedString("__index", index_hash)) |indexer| {
                    if (indexer == .table) return indexer.table.rawGetHashedString(name, key_hash) orelse .nil;
                    return self.callValueFirst(indexer, &.{ object, .{ .string = name } });
                };
                return error.IndexType;
            },
            else => return error.IndexType,
        }
    }

    pub fn setIndex(self: *Context, object: Value, key: Value, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        const table = object.table;
        if (table.rawGet(key) != null or table.metatable == null)
            return table.rawSet(self.allocator, key, value);
        if (table.metatable.?.rawGet(.{ .string = "__newindex" })) |handler| switch (handler) {
            .table => |other| return self.setIndex(.{ .table = other }, key, value),
            else => {
                var buffer: [0]Value = .{};
                const out = try self.callValueFixed(handler, &.{ object, key, value }, &buffer);
                defer out.deinit();
                return;
            },
        };
        try table.rawSet(self.allocator, key, value);
    }

    // Compiled field names carry their hash. With no metatable, a write can
    // enter rawSetHashedString immediately. For a metatable, an existing own
    // field still wins over __newindex; a map overwrite uses its first probe
    // without rehashing present keys or changing their traversal position.
    pub fn setHashedField(self: *Context, object: Value, name: []const u8, key_hash: u64, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        const table = object.table;
        if (table.metatable == null)
            return table.rawSetHashedString(self.allocator, name, key_hash, value);
        const key = Value{ .string = name };
        const shaped_slot = table.slotForString(name, key_hash);
        if (shaped_slot) |slot| if (table.rawGetSlot(slot) != null) {
            // A global tail write can allocate; retain rawSet's failure effects.
            if (slot >= table.slots.len) return table.rawSetHashedString(self.allocator, name, key_hash, value);
            return table.rawSetSlot(slot, value);
        };
        for (table.choices, 0..) |cell, choice| {
            if (cell.value != .nil and rawEqual(cell.key, key)) {
                // rawSet writes a matching shape slot first even when that
                // slot is nil and a choice exposes the own value.
                if (shaped_slot != null) return table.rawSetHashedString(self.allocator, name, key_hash, value);
                return table.rawSetChoice(@intCast(choice), key, value);
            }
        }
        const existing = table.map.getPtrAdapted(name, StringLookupContext{ .key_hash = key_hash });
        if (existing != null and existing.?.* != .nil) {
            if (shaped_slot != null) return table.rawSetHashedString(self.allocator, name, key_hash, value);
            if (value != .nil) {
                if (table.read_only) return error.ReadOnlyTable;
                try table.markMutated();
                existing.?.* = value;
                return;
            }
            return table.rawSetHashedString(self.allocator, name, key_hash, value);
        }
        if (table.metatable.?.rawGet(.{ .string = "__newindex" })) |handler| switch (handler) {
            .table => |other| return self.setHashedField(.{ .table = other }, name, key_hash, value),
            else => {
                var buffer: [0]Value = .{};
                const out = try self.callValueFixed(handler, &.{ object, key, value }, &buffer);
                defer out.deinit();
                return;
            },
        };
        try table.rawSetHashedString(self.allocator, name, key_hash, value);
    }

    pub fn binaryArith(self: *Context, op: ArithOp, a: Value, b: Value) anyerror!Value {
        if (toNumber(a)) |x| if (toNumber(b)) |y| {
            return .{ .number = switch (op) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
                .div => x / y,
                .mod => x - @floor(x / y) * y,
                .pow => std.math.pow(f64, x, y),
            } };
        };
        const name = switch (op) {
            .add => "__add",
            .sub => "__sub",
            .mul => "__mul",
            .div => "__div",
            .mod => "__mod",
            .pow => "__pow",
        };
        const method = self.metamethod(a, name) orelse self.metamethod(b, name) orelse return error.ArithmeticType;
        return self.callValueFirst(method, &.{ a, b });
    }
    fn sharedComparisonMetamethod(self: *Context, a: Value, b: Value, name: []const u8) ?Value {
        const left = self.metamethod(a, name) orelse return null;
        const right = self.metamethod(b, name) orelse return null;
        return if (rawEqual(left, right)) left else null;
    }
    fn callComparisonMetamethod(self: *Context, method: Value, a: Value, b: Value) anyerror!bool {
        return (try self.callValueFirst(method, &.{ a, b })).truthy();
    }
    pub fn comparison(self: *Context, op: CompareOp, a: Value, b: Value) anyerror!bool {
        if (op == .eq or op == .ne) {
            if (rawEqual(a, b)) return op == .eq;
            if (a == .table and b == .table) {
                const left = self.metamethod(a, "__eq");
                const right = self.metamethod(b, "__eq");
                if (left != null and right != null and rawEqual(left.?, right.?)) {
                    const equal = try self.callComparisonMetamethod(left.?, a, b);
                    return if (op == .eq) equal else !equal;
                }
            }
            return op == .ne;
        }
        if (a == .number and b == .number) return numericCompare(op, a.number, b.number);
        if (a == .string and b == .string) return stringCompare(op, a.string, b.string);
        const left = if (op == .gt or op == .ge) b else a;
        const right = if (op == .gt or op == .ge) a else b;
        if (op == .lt or op == .gt) {
            const method = self.sharedComparisonMetamethod(left, right, "__lt") orelse return error.CompareType;
            return self.callComparisonMetamethod(method, left, right);
        }
        if (self.sharedComparisonMetamethod(left, right, "__le")) |method|
            return self.callComparisonMetamethod(method, left, right);
        if (self.sharedComparisonMetamethod(right, left, "__lt")) |method|
            return !(try self.callComparisonMetamethod(method, right, left));
        return error.CompareType;
    }
    pub fn ownString(self: *Context, text: []const u8) ![]const u8 {
        return self.stringAllocator().dupe(u8, text);
    }

    pub fn concatValues(self: *Context, values: []const Value) anyerror!Value {
        var scratch_buffer: [1024]u8 = undefined;
        var scratch: std.heap.BufferFirstAllocator = .init(&scratch_buffer, std.heap.smp_allocator);
        const allocator = scratch.allocator();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (values) |value| switch (value) {
            .string => |text| try out.appendSlice(allocator, text),
            .number => |number| {
                var buffer: [64]u8 = undefined;
                try out.appendSlice(allocator, try numberToBuffer(&buffer, number));
            },
            else => return error.ConcatType,
        };
        return .{ .string = try self.ownString(out.items) };
    }
};

pub const ArithOp = enum { add, sub, mul, div, mod, pow };
pub const CompareOp = enum { eq, ne, lt, le, gt, ge };
pub fn numericCompare(op: CompareOp, a: f64, b: f64) bool {
    return switch (op) {
        .eq => a == b,
        .ne => a != b,
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
    };
}

pub fn stringCompare(op: CompareOp, a: []const u8, b: []const u8) bool {
    const order = std.mem.order(u8, a, b);
    return switch (op) {
        .eq => order == .eq,
        .ne => order != .eq,
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
    };
}

const ModuleRuntimeProbe = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:A") or std.mem.eql(u8, raw_name, "Alias:A")) return 0;
        if (std.mem.eql(u8, raw_name, "Module:B")) return 1;
        if (std.mem.eql(u8, raw_name, "Module:Loop")) return 2;
        return null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:A",
            1 => "Module:B",
            2 => "Module:Loop",
            else => null,
        };
    }
    fn named(ctx: *Context, _: Captures, args: []const Value) ![]const Value {
        const count = switch (ctx.getGlobal(0)) {
            .number => |n| n,
            else => 0,
        };
        try ctx.setGlobal(0, .{ .number = count + 1 });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = if (args.len == 0) .nil else args[0];
        return out;
    }
    fn packageOverride(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        const loaded = ctx.package_loaded orelse return error.MissingPackageLoaded;
        try loaded.rawSet(ctx.allocator, .{ .string = "Module:B" }, .{ .string = "override" });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .nil;
        return out;
    }
    fn loop(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = try ctx.requireByName("Module:Loop");
        return &.{};
    }
};

test "deleted table keys remain absent and bounded while next can recover identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const table = try ctx.newTable();
    const object_key: Value = .{ .table = try ctx.newTable() };
    const keys = [_]Value{ .{ .string = "gone" }, .{ .number = -7 }, object_key };
    for (keys) |key| try table.rawSet(ctx.allocator, key, .{ .boolean = true });
    for (keys) |key| try table.rawSet(ctx.allocator, key, .nil);
    for (keys) |key| {
        try std.testing.expect(table.rawGet(key) == null);
        var it = table.iterator();
        try std.testing.expect(it.seekAfter(key));
        try std.testing.expect(it.next() == null);
    }
    try std.testing.expect(table.rawGetHashedString("gone", stringValueHash("gone")) == null);
    try std.testing.expect(table.rawGetNumber(-7) == null);
    var empty = table.iterator();
    try std.testing.expect(empty.next() == null);
    try std.testing.expectEqual(@as(usize, 0), table.rawLen());
    // New insertions can invalidate traversal identities, but do not retain an
    // unbounded history of all keys ever inserted during a long-lived page.
    for (0..256) |i| {
        const key: Value = .{ .number = -100 - @as(f64, @floatFromInt(i)) };
        try table.rawSet(ctx.allocator, key, .{ .number = 1 });
        try table.rawSet(ctx.allocator, key, .nil);
        try std.testing.expect(table.map.count() <= 6 and table.map.capacity() <= 8);
    }
    var invalid = table.iterator();
    try std.testing.expect(!invalid.seekAfter(.{ .string = "never inserted" }));
}

test "shape deletion history survives template clone and rollback without inventing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var target = try Context.init(a, 0);
    defer target.deinit();
    var keys: [70][]const u8 = undefined;
    for (&keys, 0..) |*key, i| key.* = try std.fmt.allocPrint(a, "field-{d}", .{i});
    const shape = Shape{ .keys = .{ .strings = &keys }, .field_count = keys.len, .choice_count = 1 };
    const table = try source.newShapedTable(&shape);
    // Native namespace construction can initialize storage directly.
    table.slots[65] = .{ .number = 1 };
    try table.rawSetSlot(65, .nil);
    try table.rawSetChoice(0, .{ .string = "choice" }, .{ .number = 2 });
    try table.rawSetChoice(0, .{ .string = "choice" }, .nil);
    try table.rawSet(a, .{ .string = "map" }, .{ .number = 3 });
    try table.rawSet(a, .{ .string = "map" }, .nil);
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target };
    defer clone.deinit();
    const copied = (try clone.cloneValue(.{ .table = table })).table;
    try std.testing.expect(copied.slot_history_tail.ptr != table.slot_history_tail.ptr);
    for ([_]*Table{ table, copied }) |object| {
        for ([_][]const u8{ keys[65], "choice", "map" }) |name| {
            var it = object.iterator();
            try std.testing.expect(it.seekAfter(.{ .string = name }));
            try std.testing.expect(it.next() == null);
            try std.testing.expect(object.rawGet(.{ .string = name }) == null);
        }
        var never = object.iterator();
        try std.testing.expect(!never.seekAfter(.{ .string = keys[66] }));
    }
    var journal = InvokeRollbackJournal.init(a, &target);
    journal.begin();
    try copied.rawSetSlot(66, .{ .number = 4 });
    try copied.rawSetSlot(66, .nil);
    journal.rollback(&target);
    var restored = copied.iterator();
    try std.testing.expect(!restored.seekAfter(.{ .string = keys[66] }));
    try std.testing.expect(restored.seekAfter(.{ .string = keys[65] }));

    // A live map override takes precedence over an older dead structural slot.
    try copied.map.putContext(a, .{ .string = keys[65] }, .{ .number = 9 }, .{});
    var actual = copied.iterator();
    while (actual.next()) |entry| if (rawEqual(entry.key_ptr.*, .{ .string = keys[65] })) break;
    var seek = copied.iterator();
    try std.testing.expect(seek.seekAfter(.{ .string = keys[65] }));
    try std.testing.expectEqualDeep(actual.position(), seek.position());
}

test "shape iteration history allocation failure releases table buffers" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var ctx = try Context.init(a, 0);
            defer ctx.deinit();
            const keys: [70]Value = @splat(.{ .number = -1 });
            const shape = Shape{ .keys = .{ .boxed = &keys }, .field_count = keys.len };
            const table = try ctx.newShapedTable(&shape);
            defer ctx.destroyTable(table);
            try table.rawSetSlot(65, .{ .number = 7 });
            try table.rawSetSlot(65, .nil);
            try std.testing.expect(table.slotWasPresent(65));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "numeric value hashing preserves prior iteration order" {
    const samples = [_]f64{ 0, -0.0, 1, -1, 64, 1.5 };
    const context = ValueContext{};
    for (samples) |sample| {
        const value = Value{ .number = sample };
        const normalized: f64 = if (sample == 0) 0 else sample;
        const bits: u64 = @bitCast(normalized);
        const tag: u8 = @backingInt(std.meta.activeTag(value));
        var previous = std.hash.Wyhash.init(0);
        previous.update(&.{tag});
        previous.update(std.mem.asBytes(&bits));
        try std.testing.expectEqual(previous.final(), context.hash(value));
    }
    try std.testing.expectEqual(context.hash(.{ .number = 0.0 }), context.hash(.{ .number = -0.0 }));
}

test "Lua numeric coercion trims whitespace and accepts hexadecimal strings" {
    try std.testing.expectEqual(@as(f64, 1), toNumber(.{ .string = " \t1\r\n" }).?);
    try std.testing.expectEqual(@as(f64, 16), toNumber(.{ .string = "0x10" }).?);
    try std.testing.expectEqual(@as(f64, -16), toNumber(.{ .string = " -0x10 " }).?);
    try std.testing.expect(toNumber(.{ .string = "   " }) == null);
    try std.testing.expect(std.math.isNan(toNumber(.{ .string = "nan" }).?));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const spaced = try ctx.binaryArith(.add, .{ .number = 1 }, .{ .string = " 2 " });
    try std.testing.expectEqual(@as(f64, 3), spaced.number);
    const hex = try ctx.binaryArith(.add, .{ .number = 1 }, .{ .string = "0x10" });
    try std.testing.expectEqual(@as(f64, 17), hex.number);
}

test "Lua 5.1 number stringification uses fourteen significant digits" {
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = 1.0 / 3.0, .expected = "0.33333333333333" },
        .{ .value = 1.234567890123456, .expected = "1.2345678901235" },
        .{ .value = 1e13, .expected = "10000000000000" },
        .{ .value = 1e14, .expected = "1e+14" },
        .{ .value = 1e-6, .expected = "1e-06" },
        .{ .value = 1e-7, .expected = "1e-07" },
        .{ .value = -0.0, .expected = "-0" },
    };
    for (cases) |case| {
        const actual = try numberToString(std.testing.allocator, case.value);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const concat = try ctx.concatValues(&.{ .{ .number = -0.0 }, .{ .string = "/" }, .{ .number = 1e14 } });
    try std.testing.expectEqualStrings("-0/1e+14", concat.string);
}

test "string value hashing preserves prior iteration order" {
    var bytes: [80]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast((index * 37 + 11) % 251);
    const lengths = [_]usize{ 0, 1, 3, 4, 7, 8, 15, 16, 17, 31, 32, 47, 48, 49, 63, 64, 79 };
    const context = ValueContext{};
    for (lengths) |len| {
        const text = bytes[0..len];
        const value = Value{ .string = text };
        const tag: u8 = @backingInt(std.meta.activeTag(value));
        var previous = std.hash.Wyhash.init(0);
        previous.update(&.{tag});
        previous.update(text);
        try std.testing.expectEqual(previous.final(), context.hash(value));
    }
}
test "prehashed string lookup preserves mutable map shape choice and native slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const table = try ctx.newTable();
    var bytes: [80]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast((index * 37 + 11) % 251);
    const lengths = [_]usize{ 0, 1, 3, 4, 7, 8, 15, 16, 17, 31, 32, 47, 48, 49, 63, 64, 79 };
    for (lengths) |len| try table.rawSet(ctx.allocator, .{ .string = bytes[0..len] }, .{ .number = @floatFromInt(len) });
    for (lengths) |len| {
        const name = bytes[0..len];
        try std.testing.expect(rawEqual(table.rawGet(.{ .string = name }).?, table.rawGetHashedString(name, static_fields.hashStringKey(name)).?));
    }
    const hash = comptime static_fields.hashStringKey("field");
    try table.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 1 });
    for (0..256) |index| {
        const name = try std.fmt.allocPrint(ctx.allocator, "grow_{d}", .{index});
        try table.rawSet(ctx.allocator, .{ .string = name }, .{ .number = @floatFromInt(index) });
    }
    try std.testing.expectEqual(@as(f64, 1), table.rawGetHashedString("field", hash).?.number);
    var it = table.iterator();
    while (it.next()) |entry| if (rawEqual(entry.key_ptr.*, .{ .string = "field" })) {
        entry.value_ptr.* = .{ .number = 2 };
    };
    try std.testing.expectEqual(@as(f64, 2), table.rawGetHashedString("field", hash).?.number);
    try std.testing.expect(table.rawGetHashedString("not-field", hash) == null);
    try table.rawSet(ctx.allocator, .{ .string = "field" }, .nil);
    try std.testing.expect(table.rawGetHashedString("field", hash) == null);
    try table.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), table.rawGetHashedString("field", hash).?.number);

    const keys = [_]Value{.{ .string = "slot" }};
    const shape = Shape{ .keys = .{ .boxed = &keys }, .field_count = 1, .choice_count = 1 };
    const shaped = try ctx.newShapedTable(&shape);
    try shaped.rawSetSlot(0, .{ .number = 4 });
    try shaped.rawSetChoice(0, .{ .string = "choice" }, .{ .number = 5 });
    try shaped.rawSet(ctx.allocator, .{ .string = "overflow" }, .{ .number = 6 });
    for ([_][]const u8{ "slot", "choice", "overflow" }) |name|
        try std.testing.expect(rawEqual(shaped.rawGet(.{ .string = name }).?, shaped.rawGetHashedString(name, static_fields.hashStringKey(name)).?));
    const native = try ctx.newNativeNamespace(.string);
    try native.rawSetNativeField(.string, "find", .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), native.rawGetHashedString("find", comptime static_fields.hashStringKey("find")).?.number);
}

test "prehashed field lookup keeps metatable callbacks and string semantics live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const object = try ctx.newTable();
    const mt = try ctx.newTable();
    object.metatable = mt;
    const parent = try ctx.newTable();
    const parent_mt = try ctx.newTable();
    const grandparent = try ctx.newTable();
    parent.metatable = parent_mt;
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = parent });
    try parent_mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = grandparent });
    try grandparent.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 11 });
    const hash = comptime static_fields.hashStringKey("field");
    try std.testing.expectEqual(@as(f64, 11), (try ctx.getHashedField(.{ .table = object }, "field", hash)).number);
    try grandparent.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 12 });
    try std.testing.expectEqual(@as(f64, 12), (try ctx.getHashedField(.{ .table = object }, "field", hash)).number);
    try object.rawSet(ctx.allocator, .{ .string = "field" }, .{ .boolean = false });
    try std.testing.expectEqual(false, (try ctx.getHashedField(.{ .table = object }, "field", hash)).boolean);
    try object.rawSet(ctx.allocator, .{ .string = "field" }, .nil);
    var count: usize = 0;
    const Probe = struct {
        fn call(raw: ?*anyopaque, runtime: *Context, args: []const Value) ![]const Value {
            const calls: *usize = @ptrCast(@alignCast(raw.?));
            calls.* += 1;
            try std.testing.expectEqualStrings("field", args[1].string);
            try args[0].table.rawSet(runtime.allocator, args[1], .{ .number = 14 });
            return &.{};
        }
        fn fail(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return error.IndexProbeFailure;
        }
    };
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, try ctx.newNative(&count, Probe.call));
    try std.testing.expect((try ctx.getHashedField(.{ .table = object }, "field", hash)) == .nil);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(f64, 14), (try ctx.getHashedField(.{ .table = object }, "field", hash)).number);
    try std.testing.expectEqual(@as(usize, 1), count);
    try object.rawSet(ctx.allocator, .{ .string = "field" }, .nil);
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, try ctx.newNative(null, Probe.fail));
    ctx.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, ctx.getHashedField(.{ .table = object }, "field", hash));
    try std.testing.expectEqualStrings("IndexProbeFailure", ctx.aotErrorName().?);
    ctx.clearAotErrorName();

    const string_mt = try ctx.newTable();
    ctx.string_metatable = string_mt;
    try string_mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = parent });
    try parent.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 15 });
    try std.testing.expectEqual(@as(f64, 15), (try ctx.getHashedField(.{ .string = "abc" }, "field", hash)).number);
    try parent.rawSet(ctx.allocator, .{ .string = "field" }, .nil);
    // The existing string-table branch performs a raw read, unlike the table
    // __index chain. The specialized reader must preserve that distinction.
    try std.testing.expect((try ctx.getHashedField(.{ .string = "abc" }, "field", hash)) == .nil);
    try std.testing.expectError(error.IndexType, ctx.getHashedField(.nil, "field", hash));
}

test "AOT module resolver caches numeric identities and exposes package.loaded aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 3);
    defer ctx.deinit();
    const functions = [_]FunctionFn{ stabilize(ModuleRuntimeProbe.named), stabilize(ModuleRuntimeProbe.packageOverride), stabilize(ModuleRuntimeProbe.loop) };
    ctx.module_root_entries = &functions;
    ctx.configureModules(null, ModuleRuntimeProbe.lookup, ModuleRuntimeProbe.name);
    ctx.package_loaded = try ctx.newTable();
    try ctx.package_loaded.?.rawSet(ctx.allocator, .{ .string = "builtin" }, .{ .string = "preloaded" });
    try std.testing.expectEqualStrings("preloaded", (try ctx.requireByName("builtin")).string);
    try ctx.ensureModule(0);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Module:A" }).?.string);

    const alias = try ctx.requireByName("Alias:A");
    try std.testing.expectEqualStrings("Module:A", alias.string);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    const canonical = try ctx.requireByName("Module:A");
    try std.testing.expectEqualStrings("Module:A", canonical.string);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Alias:A" }).?.string);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Module:A" }).?.string);

    const overridden = try ctx.requireByName("Module:B");
    try std.testing.expectEqualStrings("override", overridden.string);
    try std.testing.expectError(error.AotCallFailed, ctx.requireByName("Module:Loop"));
    try std.testing.expectEqualStrings("ModuleLoadLoop", ctx.aotErrorName().?);
    ctx.clearAotErrorName();
    ctx.last_error = .nil;
    const loop_state = ctx.moduleState(2) orelse return error.MissingModuleState;
    try std.testing.expect(!loop_state.loading);
    try std.testing.expect(loop_state.value == null);
    try std.testing.expectError(error.ModuleNotFound, ctx.requireByName("Module:Missing"));
}

test "package loaded structural slots allocate sparse pages lazily" {
    const a = std.testing.allocator;
    var ctx = try Context.initProgram(a, 0, 1);
    defer ctx.deinit();

    var keys: [130]Value = undefined;
    for (&keys) |*key| key.* = .{ .string = "module" };
    const shape = Shape{
        .keys = .{ .boxed = &keys },
        .sorted_string_slots = &.{},
        .field_count = keys.len,
        .open = true,
        .all_string_keys = true,
    };
    ctx.program_shapes = &.{shape};
    ctx.program_shapes_validated = true;
    ctx.package_loaded_shape_id = 0;
    ctx.package_loaded_module_slots = &.{129};

    const table = try ctx.newPackageLoadedTable();
    defer ctx.destroyTable(table);
    ctx.package_loaded = table;

    try std.testing.expectEqual(@as(usize, 0), table.slots.len);
    try std.testing.expectEqual(@as(usize, 130), table.slotCount());
    const tail = ctx.package_loaded_tail orelse return error.MissingPackageLoadedTail;
    try std.testing.expect(table.global_tail == tail);
    try std.testing.expectEqual(@as(usize, 3), tail.pages.len);
    try std.testing.expect(tail.pages[0] == null);
    try std.testing.expect(tail.pages[1] == null);
    try std.testing.expect(tail.pages[2] == null);
    try std.testing.expect(ctx.packageLoadedModuleGet(0, null) == null);

    try table.rawSetSlot(129, .{ .number = 42 });
    try std.testing.expect(tail.pages[0] == null);
    try std.testing.expect(tail.pages[1] == null);
    try std.testing.expect(tail.pages[2] != null);
    try std.testing.expectEqual(@as(f64, 42), table.rawGetSlot(129).?.number);
    try std.testing.expectEqual(@as(f64, 42), ctx.packageLoadedModuleGet(0, null).?.number);
    try std.testing.expect(table.rawGetSlot(64) == null);

    try table.rawSetSlot(0, .{ .boolean = true });
    try std.testing.expect(tail.pages[0] != null);
    try std.testing.expect(table.rawGetSlot(0).?.boolean);
}

const ModuleTemplateProbe = struct {
    var root_calls = std.atomic.Value(u32).init(0);
    var effect_root_calls = std.atomic.Value(u32).init(0);
    var page_effect_root_calls = std.atomic.Value(u32).init(0);
    var invoke_effect_root_calls = std.atomic.Value(u32).init(0);
    var existing_mutation_calls = std.atomic.Value(u32).init(0);
    var load_data_only_calls = std.atomic.Value(u32).init(0);

    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:TemplateProbe")) 0 else null;
    }

    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:TemplateProbe" else null;
    }

    fn run(ctx: *Context, captures: Captures, _: []const Value) ![]const Value {
        const cell = try captures.cell(0);
        const current = if (cell.value == .number) cell.value.number else 0;
        cell.value = .{ .number = current + 1 };
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = cell.value;
        _ = ctx;
        return out;
    }

    fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        const cell = try ctx.allocator.create(Cell);
        cell.* = .{ .value = .{ .number = 0 } };
        const table = try ctx.newTable();
        try table.rawSet(
            ctx.allocator,
            .{ .string = "run" },
            try ctx.makeFunctionKnown(1, run, &.{cell}),
        );
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = table };
        return out;
    }

    fn effectRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = effect_root_calls.fetchAdd(1, .monotonic);
        markLoadDataEffect();
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = try ctx.newTable() };
        return out;
    }

    fn pageEffectRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = page_effect_root_calls.fetchAdd(1, .monotonic);
        markPageTemplateEffect();
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = try ctx.newTable() };
        return out;
    }

    fn invokeEffectRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = invoke_effect_root_calls.fetchAdd(1, .monotonic);
        markInvokeTemplateEffect();
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = try ctx.newTable() };
        return out;
    }

    fn mutateExistingRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = existing_mutation_calls.fetchAdd(1, .monotonic);
        const existing = ctx.getGlobal(0);
        if (existing != .table) return error.TableExpected;
        try existing.table.rawSet(
            ctx.allocator,
            .{ .string = "root_mutation" },
            .{ .boolean = true },
        );
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .boolean = true };
        return out;
    }

    fn loadDataOnlyRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = load_data_only_calls.fetchAdd(1, .monotonic);
        markLoadDataOnlyEffect();
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = try ctx.newTable() };
        return out;
    }
};

test "retained clone cells and strings pool storage without borrowing the source lifetime" {
    const Probe = struct {
        fn call(_: *Context, captures: Captures, _: []const Value) ![]const Value {
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = (try captures.cell(0)).value;
            return out;
        }
    };
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    var target = try Context.init(request.allocator(), 0);
    defer target.deinit();
    target.ownClonedStrings();
    target.retain_invoke_cell_baselines = true;
    const values = try std.testing.allocator.alloc(Value, 1024);
    defer std.testing.allocator.free(values);
    {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        var source = try Context.init(source_arena.allocator(), 0);
        defer source.deinit();
        var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target };
        defer clone.deinit();
        for (values) |*value| {
            const cell = try source.allocator.create(Cell);
            cell.* = .{ .value = .{ .string = try source.allocator.dupe(u8, "persistent capture") } };
            const original = try source.makeFunctionKnown(1, Probe.call, &.{cell});
            value.* = try clone.cloneValue(original);
            try std.testing.expect(value.callable != original.callable);
        }
        // Cells, strings, and descriptors are bulk-lived objects; map growth
        // and transient buffers still use the ordinary freeing allocator.
        try std.testing.expect(request.live_count < 64);
    }
    try std.testing.expectEqual(values.len, target.invoke_cell_baselines.items.len);
    for (values) |value| {
        const cell = try value.callable.captures().cell(0);
        try std.testing.expectEqualStrings("persistent capture", cell.value.string);
        cell.value = .nil;
    }
    var journal = InvokeRollbackJournal.init(target.allocator, &target);
    journal.begin();
    journal.rollback(&target);
    var buffer: [1]Value = undefined;
    for ([_]usize{ 0, values.len - 1 }) |index| {
        const result = try target.callValueFixed(values[index], &.{}, &buffer);
        defer result.deinit();
        try std.testing.expectEqualStrings("persistent capture", result.values[0].string);
    }
}

test "template tagging cannot attach short lived state to shared immutable data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const root = try ctx.newTable();
    const shared = try ctx.newTable();
    const nested = try ctx.newTable();
    try shared.rawSet(ctx.allocator, .{ .string = "nested" }, .{ .table = nested });
    shared.read_only = true;
    shared.cross_page_stable = true;
    nested.read_only = true;
    nested.cross_page_stable = true;
    try root.rawSet(ctx.allocator, .{ .string = "data" }, .{ .table = shared });
    var marker: u64 = 0;
    try ctx.tagModuleTemplateValue(.{ .table = root }, &marker);
    try std.testing.expect(root.module_template_mutation_probe == &marker);
    try std.testing.expect(shared.module_template_mutation_probe == null);
    try std.testing.expect(nested.module_template_mutation_probe == null);
}

test "template graph tagging does not retain traversal storage in its owner" {
    const Probe = struct {
        fn call(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return &.{};
        }
    };
    var storage: [512 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    const root = try ctx.newTable();
    for (0..100) |i| {
        const table = try ctx.newTable();
        const cell = try a.create(Cell);
        cell.* = .{ .value = .{ .table = table } };
        const callable = try ctx.makeFunctionKnown(@intCast(i), Probe.call, &.{cell});
        try table.rawSet(a, .{ .string = "cycle" }, callable);
        try root.rawSet(a, .{ .number = @floatFromInt(i + 1) }, callable);
    }
    const before = fixed.end_index;
    var marker: u64 = 0;
    for (0..4) |_| try ctx.tagModuleTemplateValue(.{ .table = root }, &marker);
    try std.testing.expectEqual(before, fixed.end_index);
    try std.testing.expect(root.module_template_mutation_probe == &marker);
}

test "upstream promotion rejects nonportable graphs before allocating persistent nodes" {
    const Native = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
    };
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var storage: [512 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var target = try Context.initProgram(fixed.allocator(), 0, 1);
    defer target.deinit();
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};
    target.module_template_eligible = &eligible;
    target.module_template_rejected = &rejected;
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
    target.module_root_entries = &roots;
    var source = try target.forkProgram(source_arena.allocator());
    defer source.deinit();
    source.module_template_context = &target;
    var host: u64 = 123;
    const exports = try source.newTable();
    try exports.rawSet(source.allocator, .{ .string = "bound" }, try source.newNative(&host, Native.call));
    try source.preinitializeModule(0, .{ .table = exports }, false);
    const before = fixed.end_index;
    for (0..64) |_| try std.testing.expect(!(try source.promoteModuleTemplateUpstream(0, null)));
    try std.testing.expectEqual(before, fixed.end_index);
    try std.testing.expect(!eligible[0]);
    try std.testing.expect(!rejected[0]);
}

test "pure module templates ignore unrelated invocation globals without importing foreign values" {
    const Native = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value { return &.{}; }
    };
    const count = module_global_prefix_len + 2 * global_page_len + 3;
    for ([_]u32{ 1, count - 1 }) |slot| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var storage: [512 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var target = try Context.initProgram(fixed.allocator(), count, 1);
        defer target.deinit();
        var eligible = [_]bool{false};
        var rejected = [_]bool{false};
        target.module_template_eligible = &eligible;
        target.module_template_rejected = &rejected;
        const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
        target.module_root_entries = &roots;
        var source = try target.forkProgram(arena.allocator());
        defer source.deinit();
        source.module_template_context = &target;
        var host: u64 = 123;
        const unrelated = try source.newTable();
        try unrelated.rawSet(source.allocator, .{ .string = "bound" }, try source.newNative(&host, Native.call));
        try unrelated.rawSet(source.allocator, .{ .string = "cycle" }, .{ .table = unrelated });
        try source.setGlobal(slot, .{ .table = unrelated });
        // This export neither reads nor captures that unrelated environment value.
        try source.preinitializeModule(0, .{ .number = 42 }, false);
        try std.testing.expect(try source.promoteModuleTemplate(0, null));
        try std.testing.expect(target.getGlobal(slot) == .nil);
        try std.testing.expectEqual(@as(f64, 42), target.moduleStateConst(0).?.value.?.number);
        const after = fixed.end_index;
        for (0..64) |_| try std.testing.expect(try source.promoteModuleTemplate(0, null));
        try std.testing.expectEqual(after, fixed.end_index);
        try std.testing.expect(eligible[0] and !rejected[0]);
    }
}

test "module template preflight rejects an exported invocation environment alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var target = try Context.initProgram(a, 3, 1);
    defer target.deinit();
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};
    target.module_template_eligible = &eligible;
    target.module_template_rejected = &rejected;
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
    target.module_root_entries = &roots;
    try bindGlobalTable(&target, null, 0);
    try target.setGlobal(1, .{ .number = 7 });
    var source = try target.forkProgram(a);
    defer source.deinit();
    source.module_template_context = &target;
    try bindGlobalTable(&source, null, 0);
    const exported = try source.newTable();
    try exported.rawSet(a, .{ .string = "environment" }, source.getGlobal(0));
    try source.preinitializeModule(0, .{ .table = exported }, false);
    try std.testing.expect(!try source.promoteModuleTemplateUpstream(0, null));
    try std.testing.expect(!eligible[0]);
    try std.testing.expect(target.moduleStateConst(0) == null);
    try std.testing.expectEqual(@as(f64, 7), target.getGlobal(1).number);
    try std.testing.expect(target.getGlobal(0).table == target.global_table.?);
}

test "caught promotion allocation failures retain the worker fatal signal" {
    const saved = module_template_allocation_failed;
    defer module_template_allocation_failed = saved;
    for ([_]bool{ false, true }) |ordinary| {
        module_template_allocation_failed = false;
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        var storage: [4096]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var target = try Context.initProgram(fixed.allocator(), 0, 1);
        defer target.deinit();
        var eligible = [_]bool{false};
        var rejected = [_]bool{false};
        target.module_template_eligible = &eligible;
        target.module_template_rejected = &rejected;
        const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
        target.module_root_entries = &roots;
        var source = try target.forkProgram(source_arena.allocator());
        defer source.deinit();
        source.module_template_context = &target;
        try source.preinitializeModule(0, .{ .number = 42 }, false);
        fixed.end_index = storage.len;
        const promoted = if (ordinary)
            source.promoteModuleTemplate(0, null) catch false
        else
            source.promoteModuleTemplateUpstream(0, null) catch false;
        try std.testing.expect(!promoted);
        try std.testing.expect(moduleTemplateAllocationFailed());
    }
}

test "module templates run roots once while fresh contexts clone mutable closure state" {
    ModuleTemplateProbe.root_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
    var eligible = [_]bool{true};

    var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer template_arena.deinit();
    var template = try Context.initProgram(template_arena.allocator(), 0, 1);
    defer template.deinit();
    template.module_root_entries = &roots;
    template.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try template.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &template;
    first.module_template_eligible = &eligible;

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try template.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &template;
    second.module_template_eligible = &eligible;

    const first_module = try first.requireByName("Module:TemplateProbe");
    const second_module = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(@as(u32, 1), ModuleTemplateProbe.root_calls.load(.monotonic));
    try std.testing.expect(first_module == .table and second_module == .table);
    try std.testing.expect(first_module.table != second_module.table);

    const first_run = first_module.table.rawGet(.{ .string = "run" }) orelse return error.MissingTemplateCallable;
    const second_run = second_module.table.rawGet(.{ .string = "run" }) orelse return error.MissingTemplateCallable;
    try std.testing.expect(first_run == .callable and second_run == .callable);
    try std.testing.expect(first_run.callable != second_run.callable);

    const first_once = try first.callValue(first_run, &.{});
    defer freeResults(first_once);
    try std.testing.expectEqual(@as(f64, 1), first_once[0].number);
    const first_twice = try first.callValue(first_run, &.{});
    defer freeResults(first_twice);
    try std.testing.expectEqual(@as(f64, 2), first_twice[0].number);
    const second_once = try second.callValue(second_run, &.{});
    defer freeResults(second_once);
    try std.testing.expectEqual(@as(f64, 1), second_once[0].number);
}

test "module template cloning recreates null-environment native descriptors" {
    const NativeProbe = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .boolean = true };
            return out;
        }
    };

    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var target = try Context.init(target_arena.allocator(), 0);
    defer target.deinit();

    const copied = blk: {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        var source = try Context.init(source_arena.allocator(), 0);
        defer source.deinit();
        const original = try source.newNative(null, NativeProbe.call);
        var clone = Context.ModuleTemplateClone{
            .source = &source,
            .target = &target,
        };
        defer clone.deinit();
        const value = try clone.cloneValue(original);
        try std.testing.expect(value == .callable);
        try std.testing.expect(value.callable != original.callable);
        try std.testing.expectEqual(original.callable.entry, value.callable.entry);
        break :blk value;
    };

    const out = try target.callValue(copied, &.{});
    defer freeResults(out);
    try std.testing.expectEqual(true, out[0].boolean);
}

test "module template cloning can own strings for reused target contexts" {
    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var target = try Context.init(target_arena.allocator(), 0);
    defer target.deinit();
    target.ownClonedStrings();

    const copied = blk: {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        var source = try Context.init(source_arena.allocator(), 0);
        defer source.deinit();
        const source_text = try source.allocator.dupe(u8, "nested-invoke-string");

        var clone = Context.ModuleTemplateClone{
            .source = &source,
            .target = &target,
        };
        defer clone.deinit();
        const value = try clone.cloneValue(.{ .string = source_text });
        try std.testing.expect(value == .string);
        try std.testing.expect(@intFromPtr(value.string.ptr) != @intFromPtr(source_text.ptr));
        break :blk value;
    };

    try std.testing.expectEqualStrings("nested-invoke-string", copied.string);
}

test "module template cloning remaps context-bound native namespace callables" {
    const NativeProbe = struct {
        fn call(raw: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            const host: *const u32 = @ptrCast(@alignCast(raw orelse
                return error.MissingHost));
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .number = @floatFromInt(host.*) };
            return out;
        }
    };

    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var source = try Context.init(source_arena.allocator(), 1);
    defer source.deinit();
    var source_host: u32 = 11;
    const source_title = try source.newNativeNamespace(.title);
    const source_callable = try source.newNative(&source_host, NativeProbe.call);
    try source_title.rawSetNativeField(.title, "new", source_callable);
    try source.setGlobal(0, .{ .table = source_title });
    const source_export = try source.newTable();
    try source_export.rawSet(
        source.allocator,
        .{ .string = "call" },
        source_callable,
    );

    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var target = try Context.init(target_arena.allocator(), 1);
    defer target.deinit();
    var target_host: u32 = 29;
    const target_title = try target.newNativeNamespace(.title);
    const target_callable = try target.newNative(&target_host, NativeProbe.call);
    try target_title.rawSetNativeField(.title, "new", target_callable);
    try target.setGlobal(0, .{ .table = target_title });

    var clone = Context.ModuleTemplateClone{
        .source = &source,
        .target = &target,
    };
    defer clone.deinit();
    const copied = try clone.cloneValue(.{ .table = source_export });
    const callable = copied.table.rawGet(.{ .string = "call" }) orelse
        return error.MissingTemplateCallable;
    try std.testing.expect(callable == .callable);
    try std.testing.expect(callable.callable == target_callable.callable);
    try std.testing.expect(callable.callable != source_callable.callable);

    const out = try target.callValue(callable, &.{});
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 29), out[0].number);
}

test "module template namespace map captures keep full and filtered identities" {
    const Fixture = struct {
        fn install(ctx: *Context, reverse: bool) !*Table {
            const site = try ctx.newNativeNamespace(.site);
            const names = [_][]const u8{ "namespaces", "subjectNamespaces", "talkNamespaces", "contentNamespaces" };
            for (0..names.len) |step| {
                const index = if (reverse) names.len - 1 - step else step;
                const map = try ctx.newNativeNamespace(.namespace_map);
                if (index == 0 or index == 1)
                    try map.rawSet(ctx.allocator, .{ .number = 10 }, .{ .string = "Template" });
                if (index == 0 or index == 2)
                    try map.rawSet(ctx.allocator, .{ .number = 11 }, .{ .string = "Template talk" });
                try site.rawSet(ctx.allocator, .{ .string = names[index] }, .{ .table = map });
            }
            return site;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Context.init(arena.allocator(), 0);
    defer source.deinit();
    var target = try Context.init(arena.allocator(), 0);
    defer target.deinit();
    const source_site = try Fixture.install(&source, false);
    const target_site = try Fixture.install(&target, true);
    for ([_]bool{ false, true }) |promotion| {
        try target.seedModuleTemplateNativeAliases(&source);
        var clone = Context.ModuleTemplateClone{
            .source = &source,
            .target = &target,
            .promotion = promotion,
        };
        defer clone.deinit();
        var preflight = Context.PromotionPreflight{ .clone = .{ .source = &source, .target = &target, .promotion = true } };
        defer preflight.deinit();
        inline for (.{ "namespaces", "subjectNamespaces", "talkNamespaces", "contentNamespaces" }) |name| {
            const input = source_site.rawGet(.{ .string = name }).?;
            const expected = target_site.rawGet(.{ .string = name }).?;
            try std.testing.expect(try preflight.value(input));
            const copied = try clone.cloneValue(input);
            try std.testing.expect(copied == .table and copied.table == expected.table);
            try std.testing.expect(copied.table != input.table);
            try std.testing.expectEqual(input.table.rawGet(.{ .number = 10 }) != null, copied.table.rawGet(.{ .number = 10 }) != null);
            try std.testing.expectEqual(input.table.rawGet(.{ .number = 11 }) != null, copied.table.rawGet(.{ .number = 11 }) != null);
        }
        const unregistered = Value{ .table = try source.newNativeNamespace(.namespace_map) };
        try std.testing.expect(!try preflight.value(unregistered));
        try std.testing.expectError(error.UnsupportedModuleTemplate, clone.cloneValue(unregistered));
    }
}

test "module template cloning remaps structural package loaded singleton" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var source = try Context.init(source_arena.allocator(), 0);
    defer source.deinit();
    const source_loaded = try source.newTable();
    source.package_loaded = source_loaded;

    var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer target_arena.deinit();
    var target = try Context.init(target_arena.allocator(), 0);
    defer target.deinit();
    const target_loaded = try target.newTable();
    target.package_loaded = target_loaded;

    try target.seedModuleTemplateNativeAliases(&source);
    var clone = Context.ModuleTemplateClone{
        .source = &source,
        .target = &target,
        .tables = target.module_template_clone_tables,
    };
    target.module_template_clone_tables = .empty;
    defer clone.deinit();
    const copied = try clone.cloneValue(.{ .table = source_loaded });
    try std.testing.expect(copied == .table and copied.table == target_loaded);
}

test "effect-free roots promote after first execution and never rerun on fresh contexts" {
    ModuleTemplateProbe.root_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};

    var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer template_arena.deinit();
    var template = try Context.initProgram(template_arena.allocator(), 0, 1);
    defer template.deinit();
    template.module_root_entries = &roots;
    template.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    template.module_template_eligible = &eligible;
    template.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try template.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &template;
    first.package_loaded = try first.newTable();
    const first_module = try first.requireByName("Module:TemplateProbe");
    try std.testing.expect(eligible[0]);
    try std.testing.expect(!rejected[0]);
    try std.testing.expectEqual(@as(u32, 1), ModuleTemplateProbe.root_calls.load(.monotonic));

    const first_run = first_module.table.rawGet(.{ .string = "run" }) orelse
        return error.MissingTemplateCallable;
    const first_once = try first.callValue(first_run, &.{});
    defer freeResults(first_once);
    try std.testing.expectEqual(@as(f64, 1), first_once[0].number);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try template.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &template;
    second.package_loaded = try second.newTable();
    const second_module = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(@as(u32, 1), ModuleTemplateProbe.root_calls.load(.monotonic));
    try std.testing.expect(second_module.table != first_module.table);
    const second_run = second_module.table.rawGet(.{ .string = "run" }) orelse
        return error.MissingTemplateCallable;
    const second_once = try second.callValue(second_run, &.{});
    defer freeResults(second_once);
    try std.testing.expectEqual(@as(f64, 1), second_once[0].number);
}

test "effectful roots are rejected from dynamic module templates" {
    ModuleTemplateProbe.effect_root_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.effectRoot)};
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};

    var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer template_arena.deinit();
    var template = try Context.initProgram(template_arena.allocator(), 0, 1);
    defer template.deinit();
    template.module_root_entries = &roots;
    template.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    template.module_template_eligible = &eligible;
    template.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try template.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &template;
    _ = try first.requireByName("Module:TemplateProbe");
    try std.testing.expect(!eligible[0]);
    try std.testing.expect(rejected[0]);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try template.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &template;
    _ = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(
        @as(u32, 2),
        ModuleTemplateProbe.effect_root_calls.load(.monotonic),
    );
}

test "page-stable effects promote only within one page" {
    ModuleTemplateProbe.page_effect_root_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.pageEffectRoot)};

    {
        var eligible = [_]bool{false};
        var rejected = [_]bool{false};
        var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer template_arena.deinit();
        var template = try Context.initProgram(template_arena.allocator(), 0, 1);
        defer template.deinit();
        template.module_root_entries = &roots;
        template.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
        template.module_template_eligible = &eligible;
        template.module_template_rejected = &rejected;

        var child_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer child_arena.deinit();
        var child = try template.forkProgram(child_arena.allocator());
        defer child.deinit();
        child.module_template_context = &template;
        _ = try child.requireByName("Module:TemplateProbe");
        try std.testing.expect(!eligible[0]);
        try std.testing.expect(rejected[0]);
    }

    ModuleTemplateProbe.page_effect_root_calls.store(0, .monotonic);
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};
    var base_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer base_arena.deinit();
    var base = try Context.initProgram(base_arena.allocator(), 0, 1);
    defer base.deinit();
    base.module_root_entries = &roots;
    base.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);

    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page_arena.deinit();
    var page = try base.forkProgram(page_arena.allocator());
    defer page.deinit();
    page.module_template_eligible = &eligible;
    page.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try page.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &page;
    first.module_template_eligible = &eligible;
    first.module_template_rejected = &rejected;
    first.module_template_page_scope = true;
    _ = try first.requireByName("Module:TemplateProbe");
    try std.testing.expect(eligible[0]);
    try std.testing.expect(!rejected[0]);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try page.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &page;
    second.module_template_eligible = &eligible;
    second.module_template_rejected = &rejected;
    second.module_template_page_scope = true;
    _ = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(
        @as(u32, 1),
        ModuleTemplateProbe.page_effect_root_calls.load(.monotonic),
    );

    // A new page owns a new page-template bitset and must execute the root once
    // for its own page-stable state before that state can be reused there.
    var next_eligible = [_]bool{false};
    var next_rejected = [_]bool{false};
    var next_page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer next_page_arena.deinit();
    var next_page = try base.forkProgram(next_page_arena.allocator());
    defer next_page.deinit();
    next_page.module_template_eligible = &next_eligible;
    next_page.module_template_rejected = &next_rejected;

    var third_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer third_arena.deinit();
    var third = try next_page.forkProgram(third_arena.allocator());
    defer third.deinit();
    third.module_template_context = &next_page;
    third.module_template_eligible = &next_eligible;
    third.module_template_rejected = &next_rejected;
    third.module_template_page_scope = true;
    _ = try third.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(
        @as(u32, 2),
        ModuleTemplateProbe.page_effect_root_calls.load(.monotonic),
    );
}

test "invoke-specific effects still reject page-scoped module templates" {
    ModuleTemplateProbe.invoke_effect_root_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.invokeEffectRoot)};
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};

    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page_arena.deinit();
    var page = try Context.initProgram(page_arena.allocator(), 0, 1);
    defer page.deinit();
    page.module_root_entries = &roots;
    page.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    page.module_template_eligible = &eligible;
    page.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try page.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &page;
    first.module_template_eligible = &eligible;
    first.module_template_rejected = &rejected;
    first.module_template_page_scope = true;
    _ = try first.requireByName("Module:TemplateProbe");
    try std.testing.expect(!eligible[0]);
    try std.testing.expect(rejected[0]);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try page.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &page;
    second.module_template_eligible = &eligible;
    second.module_template_rejected = &rejected;
    second.module_template_page_scope = true;
    _ = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(
        @as(u32, 2),
        ModuleTemplateProbe.invoke_effect_root_calls.load(.monotonic),
    );
}

test "mutating a pre-existing table rejects dynamic module templates" {
    ModuleTemplateProbe.existing_mutation_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.mutateExistingRoot)};
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};

    var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer template_arena.deinit();
    var template = try Context.initProgram(template_arena.allocator(), 1, 1);
    defer template.deinit();
    template.module_root_entries = &roots;
    template.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    template.module_template_eligible = &eligible;
    template.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try template.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &template;
    const first_existing = try first.newTable();
    try first.setGlobal(0, .{ .table = first_existing });
    _ = try first.requireByName("Module:TemplateProbe");
    try std.testing.expect(!eligible[0]);
    try std.testing.expect(rejected[0]);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try template.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &template;
    const second_existing = try second.newTable();
    try second.setGlobal(0, .{ .table = second_existing });
    _ = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(
        @as(u32, 2),
        ModuleTemplateProbe.existing_mutation_calls.load(.monotonic),
    );
}

test "loadData-only effects do not block module-root promotion" {
    ModuleTemplateProbe.load_data_only_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.loadDataOnlyRoot)};
    var eligible = [_]bool{false};
    var rejected = [_]bool{false};

    var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer template_arena.deinit();
    var template = try Context.initProgram(template_arena.allocator(), 0, 1);
    defer template.deinit();
    template.module_root_entries = &roots;
    template.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    template.module_template_eligible = &eligible;
    template.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try template.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &template;
    _ = try first.requireByName("Module:TemplateProbe");
    try std.testing.expect(eligible[0]);
    try std.testing.expect(!rejected[0]);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try template.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &template;
    _ = try second.requireByName("Module:TemplateProbe");
    try std.testing.expectEqual(
        @as(u32, 1),
        ModuleTemplateProbe.load_data_only_calls.load(.monotonic),
    );
}

const ModuleTemplateOverrideProbe = struct {
    var root_calls = std.atomic.Value(u32).init(0);
    var dependency_calls = std.atomic.Value(u32).init(0);

    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:Root")) return 0;
        if (std.mem.eql(u8, raw_name, "Module:Dep")) return 1;
        return null;
    }

    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:Root",
            1 => "Module:Dep",
            else => null,
        };
    }

    fn dependencyRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = dependency_calls.fetchAdd(1, .monotonic);
        const nested = try ctx.newTable();
        try nested.rawSet(
            ctx.allocator,
            .{ .string = "value" },
            .{ .number = 1 },
        );
        const exported = try ctx.newTable();
        try exported.rawSet(
            ctx.allocator,
            .{ .string = "nested" },
            .{ .table = nested },
        );
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exported };
        return out;
    }

    fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = root_calls.fetchAdd(1, .monotonic);
        const dependency = try ctx.loadModule(1, "Module:Dep");
        if (dependency != .table) return error.TableExpected;
        const nested = dependency.table.rawGet(.{ .string = "nested" }) orelse
            return error.MissingTemplateDependency;
        if (nested != .table) return error.TableExpected;
        try nested.table.rawSet(
            ctx.allocator,
            .{ .string = "value" },
            .{ .number = 2 },
        );
        const exported = try ctx.newTable();
        try exported.rawSet(
            ctx.allocator,
            .{ .string = "dependency" },
            dependency,
        );
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .table = exported };
        return out;
    }
};

test "promoted roots replay nested dependency overrides without rerunning roots" {
    ModuleTemplateOverrideProbe.root_calls.store(0, .monotonic);
    ModuleTemplateOverrideProbe.dependency_calls.store(0, .monotonic);
    const roots = [_]FunctionFn{
        stabilize(ModuleTemplateOverrideProbe.root),
        stabilize(ModuleTemplateOverrideProbe.dependencyRoot),
    };
    var eligible = [_]bool{ false, false };
    var rejected = [_]bool{ false, false };

    var template_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer template_arena.deinit();
    var template = try Context.initProgram(template_arena.allocator(), 0, 2);
    defer template.deinit();
    template.module_root_entries = &roots;
    template.configureModules(
        null,
        ModuleTemplateOverrideProbe.lookup,
        ModuleTemplateOverrideProbe.name,
    );
    template.module_template_eligible = &eligible;
    template.module_template_rejected = &rejected;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first = try template.forkProgram(first_arena.allocator());
    defer first.deinit();
    first.module_template_context = &template;
    first.package_loaded = try first.newTable();
    const first_root = try first.requireByName("Module:Root");
    try std.testing.expect(first_root == .table);
    try std.testing.expect(eligible[0]);
    try std.testing.expect(!rejected[0]);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try template.forkProgram(second_arena.allocator());
    defer second.deinit();
    second.module_template_context = &template;
    second.package_loaded = try second.newTable();
    const second_root = try second.requireByName("Module:Root");
    const second_dep = try second.requireByName("Module:Dep");
    try std.testing.expectEqual(
        @as(u32, 1),
        ModuleTemplateOverrideProbe.root_calls.load(.monotonic),
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        ModuleTemplateOverrideProbe.dependency_calls.load(.monotonic),
    );
    const root_dep = second_root.table.rawGet(.{ .string = "dependency" }) orelse
        return error.MissingTemplateDependency;
    try std.testing.expect(root_dep == .table and second_dep == .table);
    try std.testing.expect(root_dep.table == second_dep.table);
    const nested = second_dep.table.rawGet(.{ .string = "nested" }) orelse
        return error.MissingTemplateDependency;
    try std.testing.expect(nested == .table);
    const value = nested.table.rawGet(.{ .string = "value" }) orelse
        return error.MissingTemplateDependency;
    try std.testing.expectEqual(@as(f64, 2), value.number);
}

const DeferredRequireProbe = struct {
    fn lookup(_: ?*const anyopaque, module_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, module_name, "Module:Prepared")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:Prepared" else null;
    }
};

test "eager module export mutation invalidates pristine direct-call state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 1);
    defer ctx.deinit();
    ctx.package_loaded = try ctx.newTable();
    ctx.configureModules(null, DeferredRequireProbe.lookup, DeferredRequireProbe.name);

    const exported = try ctx.newTable();
    try exported.rawSet(ctx.allocator, .{ .string = "run" }, .{ .number = 1 });
    try ctx.preinitializeModule(0, .{ .table = exported }, false);
    var loaded: Value = undefined;
    const sentinel = ctx.deferStaticRequireRef(0, &loaded) orelse return error.MissingPreparedModule;
    try std.testing.expect(loaded == .table and loaded.table == exported);
    try std.testing.expect(sentinel.*);

    try exported.rawSet(ctx.allocator, .{ .string = "other" }, .{ .number = 2 });
    try std.testing.expect(!sentinel.*);
}

test "prepared export sentinel invalidates on package observation and respects loaded override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 1);
    defer ctx.deinit();
    ctx.package_loaded = try ctx.newTable();
    ctx.configureModules(null, DeferredRequireProbe.lookup, DeferredRequireProbe.name);

    const exported = try ctx.newTable();
    try ctx.preinitializeModule(0, .{ .table = exported }, false);
    var loaded: Value = undefined;
    const sentinel = ctx.deferStaticRequireRef(0, &loaded) orelse return error.MissingPreparedModule;
    try std.testing.expect(sentinel.*);
    try ctx.observePackage();
    try std.testing.expect(sentinel.*);
    var ignored_after_observe: Value = undefined;
    try std.testing.expect(ctx.deferStaticRequireRef(0, &ignored_after_observe) == null);
    try std.testing.expect(ctx.moduleValueSentinel(0, loaded) == sentinel);

    var second = try Context.initProgram(arena.allocator(), 0, 1);
    defer second.deinit();
    second.package_loaded = try second.newTable();
    second.configureModules(null, DeferredRequireProbe.lookup, DeferredRequireProbe.name);
    const second_export = try second.newTable();
    try second.preinitializeModule(0, .{ .table = second_export }, false);
    try second.package_loaded.?.rawSet(
        second.allocator,
        .{ .string = "Module:Prepared" },
        .{ .string = "override" },
    );
    var ignored: Value = undefined;
    try std.testing.expect(second.deferStaticRequireRef(0, &ignored) == null);
}

test "prepared static require stays hidden until package becomes observable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 1);
    defer ctx.deinit();
    ctx.package_loaded = try ctx.newTable();
    ctx.configureModules(null, DeferredRequireProbe.lookup, DeferredRequireProbe.name);
    try ctx.preinitializeModule(0, .{ .string = "prepared" }, false);

    const fast = ctx.deferStaticRequire(0) orelse return error.MissingPreparedModule;
    try std.testing.expectEqualStrings("prepared", fast.string);
    try std.testing.expect(ctx.package_loaded.?.rawGet(.{ .string = "Module:Prepared" }) == null);

    try ctx.observePackage();
    try std.testing.expect(ctx.package_observable);
    try std.testing.expectEqualStrings(
        "prepared",
        ctx.package_loaded.?.rawGet(.{ .string = "Module:Prepared" }).?.string,
    );
    try std.testing.expect(ctx.deferStaticRequire(0) == null);
}

test "eager bootstrap static require does not create deferred package visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 1);
    defer ctx.deinit();
    ctx.package_loaded = try ctx.newTable();
    ctx.configureModules(null, DeferredRequireProbe.lookup, DeferredRequireProbe.name);
    try ctx.preinitializeModule(0, .{ .string = "prepared" }, false);

    ctx.beginEagerBootstrap();
    _ = ctx.deferStaticRequire(0) orelse return error.MissingPreparedModule;
    ctx.endEagerBootstrap();
    try ctx.observePackage();
    try std.testing.expect(ctx.package_loaded.?.rawGet(.{ .string = "Module:Prepared" }) == null);
}

const EagerRequirementProbe = struct {
    const requirements = [_]ModuleRequirement{
        .{ .module_id = 1, .requested = "Module:Dep" },
    };

    fn requirementsFor(_: ?*const anyopaque, module_id: u32) []const ModuleRequirement {
        return if (module_id == 0) &requirements else &.{};
    }

    fn parent(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        const dependency = try ctx.requireModuleId(1, "Module:Dep");
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = dependency;
        return out;
    }

    fn dep(_: *Context, _: Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "lazy-dep" };
        return out;
    }
};

test "eager module dependencies stay private and fall back on package.loaded override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const functions = [_]FunctionFn{
        stabilize(EagerRequirementProbe.parent),
        stabilize(EagerRequirementProbe.dep),
    };
    ctx.module_root_entries = &functions;
    ctx.package_loaded = try ctx.newTable();
    ctx.configureModuleRequirements(null, EagerRequirementProbe.requirementsFor);

    try ctx.preinitializeModule(1, .{ .string = "eager-dep" }, false);
    try ctx.preinitializeModule(0, .{ .string = "eager-dep" }, false);

    ctx.beginEagerBootstrap();
    try std.testing.expectEqualStrings(
        "eager-dep",
        (try ctx.requireModuleId(1, "Module:Dep")).string,
    );
    ctx.endEagerBootstrap();
    try std.testing.expect(ctx.package_loaded.?.rawGet(.{ .string = "Module:Dep" }) == null);

    try ctx.package_loaded.?.rawSet(
        ctx.allocator,
        .{ .string = "Module:Dep" },
        .{ .string = "override" },
    );
    const parent = try ctx.loadModule(0, "Module:Parent");
    try std.testing.expectEqualStrings("override", parent.string);
    try std.testing.expectEqualStrings(
        "override",
        ctx.package_loaded.?.rawGet(.{ .string = "Module:Dep" }).?.string,
    );
}

const RecursiveModuleCacheProbe = struct {
    fn outer(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        const loaded_inner = try ctx.loadModule(1, null);
        if (loaded_inner != .string or !std.mem.eql(u8, loaded_inner.string, "inner")) return error.BadInnerModule;
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "outer" };
        return out;
    }
    fn inner(_: *Context, _: Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = "inner" };
        return out;
    }
};

test "recursive module loads keep distinct cache slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const functions = [_]FunctionFn{ stabilize(RecursiveModuleCacheProbe.outer), stabilize(RecursiveModuleCacheProbe.inner) };
    ctx.module_root_entries = &functions;

    const outer = try ctx.loadModule(0, null);
    const loaded_inner = try ctx.loadModule(1, null);
    const cached_outer = try ctx.loadModule(0, null);
    try std.testing.expectEqualStrings("outer", outer.string);
    try std.testing.expectEqualStrings("inner", loaded_inner.string);
    try std.testing.expectEqualStrings("outer", cached_outer.string);
    try std.testing.expect(ctx.moduleState(0).?.value != null);
    try std.testing.expect(ctx.moduleState(1).?.value != null);
}

const ModuleGlobalIsolationProbe = struct {
    fn rootA(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try ctx.setGlobal(0, .{ .string = "A" });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = try ctx.makeFunctionKnown(1, read, &.{});
        return out;
    }
    fn rootB(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try ctx.setGlobal(0, .{ .string = "B" });
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = try ctx.makeFunctionKnown(3, read, &.{});
        return out;
    }
    fn read(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = ctx.getGlobal(0);
        return out;
    }
};

test "module globals are shared for dynamic and static calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 2, 2);
    defer ctx.deinit();
    const roots = [_]FunctionFn{
        stabilize(ModuleGlobalIsolationProbe.rootA),
        stabilize(ModuleGlobalIsolationProbe.rootB),
    };
    const function_modules = [_]u32{ 0, 0, 1, 1 };
    ctx.module_root_entries = &roots;
    ctx.configureFunctionModules(&function_modules);
    try bindGlobalTable(&ctx, null, 1);
    try ctx.setGlobal(0, .{ .string = "root" });

    const a = try ctx.loadModule(0, null);
    const b = try ctx.loadModule(1, null);
    try std.testing.expectEqualStrings("B", ctx.getGlobal(0).string);

    const a_result = try ctx.callValue(a, &.{});
    defer freeResults(a_result);
    try std.testing.expectEqualStrings("B", a_result[0].string);
    const b_result = try ctx.callValue(b, &.{});
    defer freeResults(b_result);
    try std.testing.expectEqualStrings("B", b_result[0].string);
    try std.testing.expectEqualStrings("B", ctx.getGlobal(0).string);

    const static_a = try ctx.callStaticFunctionBuffered(
        0,
        stabilize(ModuleGlobalIsolationProbe.read),
        &.{},
        &.{},
        null,
    );
    defer freeResults(static_a);
    try std.testing.expectEqualStrings("B", static_a[0].string);
    try ctx.setGlobal(0, .{ .string = "current" });
    const same_module = try ctx.callStaticFunctionBuffered(
        std.math.maxInt(u32),
        stabilize(ModuleGlobalIsolationProbe.read),
        &.{},
        &.{},
        null,
    );
    defer freeResults(same_module);
    try std.testing.expectEqualStrings("current", same_module[0].string);
    try std.testing.expectEqualStrings("current", ctx.getGlobal(0).string);
}

const NativeHostProbe = struct {
    value: f64,
    fn call(raw: ?*anyopaque, ctx: *Context, args: []const Value) ![]const Value {
        const host: *NativeHostProbe = @ptrCast(@alignCast(raw orelse return error.MissingHost));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .number = host.value + @as(f64, @floatFromInt(args.len)) + ctx.getGlobal(1).number };
        return out;
    }
};

const OtherNativeHostProbe = struct {
    value: f64,
    fn call(raw: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
        const host: *OtherNativeHostProbe = @ptrCast(@alignCast(raw.?));
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .number = 100 + host.value };
        return out;
    }
};

fn candidateLuaFallback(_: *Context, _: Captures, _: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = .{ .number = 7 };
    return out;
}

test "AOT native calls carry independent host context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 4 });
    var host = NativeHostProbe{ .value = 7 };
    const callable = try ctx.newNative(&host, NativeHostProbe.call);
    const out = try ctx.callValue(callable, &.{ .nil, .nil });
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 13), out[0].number);
}

test "AOT runtime globals are numeric slots without hash storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 8);
    try ctx.setGlobal(3, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), ctx.getGlobal(3).number);
}
pub fn mergeValues(prefix: []const Value, tail: []const Value) ![]Value {
    const out = try std.heap.smp_allocator.alloc(Value, prefix.len + tail.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], tail);
    return out;
}

pub inline fn mergeBoundedValues(storage: []Value, prefix: []const Value, tail: []const Value) []const Value {
    const prefix_len = @min(storage.len, prefix.len);
    @memcpy(storage[0..prefix_len], prefix[0..prefix_len]);
    const tail_len = @min(storage.len - prefix_len, tail.len);
    @memcpy(storage[prefix_len..][0..tail_len], tail[0..tail_len]);
    return storage[0 .. prefix_len + tail_len];
}

pub inline fn mergeSmallValues(storage: []Value, prefix: []const Value, tail: []const Value) ![]Value {
    const total = prefix.len + tail.len;
    if (total > storage.len) return mergeValues(prefix, tail);
    @memcpy(storage[0..prefix.len], prefix);
    @memcpy(storage[prefix.len..total], tail);
    return storage[0..total];
}

pub inline fn freeSmallValues(values: []Value, storage: []Value) void {
    if (values.ptr != storage.ptr) freeValues(values);
}

pub fn freeValues(values: []Value) void {
    rawFreeSlice(Value, std.heap.smp_allocator, values);
}
pub inline fn touch(value: anytype) void {
    _ = value;
}
pub fn bindGlobalTable(ctx: *Context, shape: ?*const Shape, env_slot: u32) !void {
    if (ctx.root_global_table != null) return error.GlobalTableAlreadyBound;
    const table = try ctx.allocator.create(Table);
    table.* = .{
        .shape = shape,
        .slots = ctx.globals,
        .owns_slots = false,
        .invocation_environment = true,
        .invoke_rollback_owner_nonce = ctx.field_cache_nonce,
    };
    table.initSlotHistory(ctx.allocator) catch |err| {
        ctx.allocator.destroy(table);
        return err;
    };
    // Unlike fresh shaped/package tables, borrowed globals can already hold
    // values. The separate initialization avoids scanning every empty sparse
    // package slot merely to discover that it is nil.
    for (ctx.globals, 0..) |value, slot| if (value != .nil) table.noteSlotPresence(@intCast(slot));
    ctx.global_table = table;
    ctx.root_global_table = table;
    ctx.root_globals = ctx.globals;
    ctx.global_env_slot = env_slot;
    try ctx.setGlobal(env_slot, .{ .table = table });
}

fn comparisonField(args: []const Value, index: usize) !f64 {
    if (index >= args.len or args[index] != .table) return error.TableExpected;
    const value = args[index].table.rawGet(.{ .string = "n" }) orelse return error.NumberExpected;
    if (value != .number) return error.NumberExpected;
    return value.number;
}

fn comparisonLessProbe(_: ?*anyopaque, _: *Context, args: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = .{ .boolean = try comparisonField(args, 0) < try comparisonField(args, 1) };
    return out;
}

fn comparisonFalseProbe(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = .{ .boolean = false };
    return out;
}

fn guardCapture(captures: Captures) f64 {
    return switch (captures) {
        .direct => |cells| if (cells.len == 0) 0 else cells[0].value.number,
        .native => 0,
    };
}

test "Lua 5.1 ordering metamethods require shared functions and fall back from le to reversed lt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();

    const a = try ctx.newTable();
    const b = try ctx.newTable();
    try a.rawSet(ctx.allocator, .{ .string = "n" }, .{ .number = 1 });
    try b.rawSet(ctx.allocator, .{ .string = "n" }, .{ .number = 2 });
    const shared_mt = try ctx.newTable();
    const shared_lt = try ctx.newNative(null, comparisonLessProbe);
    try shared_mt.rawSet(ctx.allocator, .{ .string = "__lt" }, shared_lt);
    a.metatable = shared_mt;
    b.metatable = shared_mt;

    try std.testing.expect(try ctx.comparison(.lt, .{ .table = a }, .{ .table = b }));
    try std.testing.expect(try ctx.comparison(.le, .{ .table = a }, .{ .table = b }));
    try std.testing.expect(!(try ctx.comparison(.le, .{ .table = b }, .{ .table = a })));
    try std.testing.expect(try ctx.comparison(.ge, .{ .table = b }, .{ .table = a }));

    const shared_le = try ctx.newNative(null, comparisonFalseProbe);
    try shared_mt.rawSet(ctx.allocator, .{ .string = "__le" }, shared_le);
    try std.testing.expect(!(try ctx.comparison(.le, .{ .table = a }, .{ .table = b })));

    const c = try ctx.newTable();
    const d = try ctx.newTable();
    const c_mt = try ctx.newTable();
    const d_mt = try ctx.newTable();
    try c_mt.rawSet(ctx.allocator, .{ .string = "__lt" }, try ctx.newNative(null, comparisonLessProbe));
    try d_mt.rawSet(ctx.allocator, .{ .string = "__lt" }, try ctx.newNative(null, comparisonLessProbe));
    c.metatable = c_mt;
    d.metatable = d_mt;
    try std.testing.expectError(error.CompareType, ctx.comparison(.lt, .{ .table = c }, .{ .table = d }));
}

fn bufferedResultProbe(_: *Context, captures: Captures, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const value = guardCapture(captures) + if (args.len == 0) 0 else args[0].number;
    if (result_buffer) |result| {
        if (result.len != 0) result[0] = .{ .number = value };
        return result[0..@min(result.len, 1)];
    }
    const result = try std.heap.smp_allocator.alloc(Value, 1);
    result[0] = .{ .number = value };
    return result;
}

fn bufferedEmptyProbe(_: *Context, _: Captures, _: []const Value, result_buffer: ?[]Value) ![]const Value {
    return try returnBuffer(result_buffer, 0);
}

fn bufferedTripleProbe(_: *Context, _: Captures, _: []const Value, result_buffer: ?[]Value) ![]const Value {
    const result = try returnBuffer(result_buffer, 3);
    storeReturn(result, 0, .{ .number = 1 });
    storeReturn(result, 1, .{ .number = 2 });
    storeReturn(result, 2, .{ .number = 3 });
    return result;
}

test "bounded argument merge truncates excess tail without heap storage" {
    var storage: [2]Value = undefined;
    const values = mergeBoundedValues(&storage, &.{.{ .number = 7 }}, &.{ .{ .number = 8 }, .{ .number = 9 } });
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(f64, 7), values[0].number);
    try std.testing.expectEqual(@as(f64, 8), values[1].number);
    var larger: [3]Value = undefined;
    const short = mergeBoundedValues(&larger, &.{.{ .number = 4 }}, &.{});
    try std.testing.expectEqual(@as(usize, 1), short.len);
    try std.testing.expectEqual(@as(f64, 4), short[0].number);
    var one: [1]Value = undefined;
    const truncated_prefix = mergeBoundedValues(&one, &.{ .{ .number = 5 }, .{ .number = 6 } }, &.{.{ .number = 7 }});
    try std.testing.expectEqual(@as(usize, 1), truncated_prefix.len);
    try std.testing.expectEqual(@as(f64, 5), truncated_prefix[0].number);
}

test "small argument merge borrows stack storage and falls back without truncation" {
    var storage: [3]Value = undefined;
    const small = try mergeSmallValues(&storage, &.{.{ .number = 1 }}, &.{ .{ .number = 2 }, .{ .number = 3 } });
    defer freeSmallValues(small, &storage);
    try std.testing.expect(small.ptr == storage[0..].ptr);
    try std.testing.expectEqual(@as(usize, 3), small.len);
    try std.testing.expectEqual(@as(f64, 3), small[2].number);

    const large = try mergeSmallValues(&storage, &.{ .{ .number = 4 }, .{ .number = 5 } }, &.{ .{ .number = 6 }, .{ .number = 7 } });
    defer freeSmallValues(large, &storage);
    try std.testing.expect(large.ptr != storage[0..].ptr);
    try std.testing.expectEqual(@as(usize, 4), large.len);
    try std.testing.expectEqual(@as(f64, 7), large[3].number);
}

fn callableTableProbe(raw: ?*anyopaque, _: *Context, args: []const Value) ![]const Value {
    const expected: *Table = @ptrCast(@alignCast(raw orelse return error.MissingHost));
    if (args.len == 0 or args[0] != .table or args[0].table != expected) return error.BadCallableSelf;
    const out = try std.heap.smp_allocator.alloc(Value, 2);
    out[0] = .{ .number = @floatFromInt(args.len) };
    out[1] = args[args.len - 1];
    return out;
}

test "callable tables use full small arguments and heap fallback without changing self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const target = try ctx.newTable();
    const mt = try ctx.newTable();
    target.metatable = mt;
    try mt.rawSet(ctx.allocator, .{ .string = "__call" }, try ctx.newNative(target, callableTableProbe));

    const small = try ctx.callValue(.{ .table = target }, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    defer freeResults(small);
    try std.testing.expectEqual(@as(f64, 4), small[0].number);
    try std.testing.expectEqual(@as(f64, 3), small[1].number);

    const large = try ctx.callValue(.{ .table = target }, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 }, .{ .number = 4 }, .{ .number = 5 }, .{ .number = 6 }, .{ .number = 7 }, .{ .number = 8 }, .{ .number = 9 } });
    defer freeResults(large);
    try std.testing.expectEqual(@as(f64, 10), large[0].number);
    try std.testing.expectEqual(@as(f64, 9), large[1].number);
}

test "callable table metamethod tables retain recursive call semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const outer = try ctx.newTable();
    const outer_mt = try ctx.newTable();
    outer.metatable = outer_mt;
    const inner = try ctx.newTable();
    const inner_mt = try ctx.newTable();
    inner.metatable = inner_mt;
    try outer_mt.rawSet(ctx.allocator, .{ .string = "__call" }, .{ .table = inner });
    try inner_mt.rawSet(ctx.allocator, .{ .string = "__call" }, try ctx.newNative(inner, callableTableProbe));
    const out = try ctx.callValue(.{ .table = outer }, &.{.{ .number = 9 }});
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 3), out[0].number);
    try std.testing.expectEqual(@as(f64, 9), out[1].number);
}

fn bufferedCallableTableProbe(_: *Context, _: Captures, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table or args[1] != .number) return error.BadCallableSelf;
    const result = try returnBuffer(result_buffer, 1);
    storeReturn(result, 0, args[1]);
    return result;
}

fn nativeBufferedOwnershipProbe(_: ?*anyopaque, _: *Context, args: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = if (args.len == 0) .nil else args[0];
    return out;
}

fn nativeFixedBufferedProbe(_: ?*anyopaque, _: *Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const out = try returnBuffer(result_buffer, 2);
    storeReturn(out, 0, if (args.len == 0) .nil else args[0]);
    storeReturn(out, 1, .{ .number = 42 });
    return out;
}

test "fixed dynamic calls borrow and truncate caller result storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();

    const buffered = Value{ .callable = &.{ .id = 0, .identity = 1, .entry = stabilizeBuffered(bufferedTripleProbe) } };
    var storage: [2]Value = undefined;
    const borrowed = try ctx.callValueFixed(buffered, &.{}, &storage);
    defer borrowed.deinit();
    try std.testing.expect(!borrowed.owned);
    try std.testing.expectEqual(@as(usize, 2), borrowed.values.len);
    try std.testing.expectEqual(@as(f64, 1), borrowed.values[0].number);
    try std.testing.expectEqual(@as(f64, 2), borrowed.values[1].number);

    const empty_callable = Value{ .callable = &.{ .id = 2, .identity = 3, .entry = stabilizeBuffered(bufferedEmptyProbe) } };
    const empty = try ctx.callValueFixed(empty_callable, &.{}, &storage);
    defer empty.deinit();
    try std.testing.expect(!empty.owned);
    try std.testing.expectEqual(@as(usize, 0), empty.values.len);

    const unbuffered = Value{ .callable = &.{ .id = 1, .identity = 2, .entry = stabilize(guardTestExpected) } };
    const copied = try ctx.callValueFixed(unbuffered, &.{.{ .number = 7 }}, &storage);
    defer copied.deinit();
    try std.testing.expect(copied.owned);
    try std.testing.expectEqual(@as(f64, 7), copied.values[0].number);

    const native = try ctx.newNative(null, nativeBufferedOwnershipProbe);
    const native_result = try ctx.callValueFixed(native, &.{.{ .number = 9 }}, &storage);
    defer native_result.deinit();
    try std.testing.expect(native_result.owned);
    try std.testing.expectEqual(@as(f64, 9), native_result.values[0].number);

    const buffered_native = try ctx.newNativeBuffered(null, nativeFixedBufferedProbe);
    const native_borrowed = try ctx.callValueFixed(buffered_native, &.{.{ .number = 10 }}, &storage);
    defer native_borrowed.deinit();
    try std.testing.expect(!native_borrowed.owned);
    try std.testing.expectEqual(@as(usize, 2), native_borrowed.values.len);
    try std.testing.expectEqual(@as(f64, 10), native_borrowed.values[0].number);
    try std.testing.expectEqual(@as(f64, 42), native_borrowed.values[1].number);

    const native_owned = try ctx.callValue(buffered_native, &.{.{ .number = 13 }});
    defer freeResults(native_owned);
    try std.testing.expectEqual(@as(usize, 2), native_owned.len);
    try std.testing.expectEqual(@as(f64, 13), native_owned[0].number);
    try std.testing.expectEqual(@as(f64, 42), native_owned[1].number);

    const target = try ctx.newTable();
    const mt = try ctx.newTable();
    target.metatable = mt;
    try mt.rawSet(ctx.allocator, .{ .string = "__call" }, try ctx.newNative(target, callableTableProbe));
    const table_result = try ctx.callValueFixed(.{ .table = target }, &.{.{ .number = 11 }}, &storage);
    defer table_result.deinit();
    try std.testing.expect(table_result.owned);
    try std.testing.expectEqual(@as(usize, 2), table_result.values.len);
    try std.testing.expectEqual(@as(f64, 2), table_result.values[0].number);
    try std.testing.expectEqual(@as(f64, 11), table_result.values[1].number);

    const lua_table = try ctx.newTable();
    const lua_mt = try ctx.newTable();
    lua_table.metatable = lua_mt;
    const lua_method = Value{ .callable = &.{ .id = 3, .identity = 4, .entry = stabilizeBuffered(bufferedCallableTableProbe) } };
    try lua_mt.rawSet(ctx.allocator, .{ .string = "__call" }, lua_method);
    const table_borrowed = try ctx.callValueFixed(.{ .table = lua_table }, &.{.{ .number = 12 }}, &storage);
    defer table_borrowed.deinit();
    try std.testing.expect(!table_borrowed.owned);
    try std.testing.expectEqual(@as(usize, 1), table_borrowed.values.len);
    try std.testing.expectEqual(@as(f64, 12), table_borrowed.values[0].number);
}

test "buffered results borrow caller storage across direct and stable calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const callable = FunctionValue{ .id = 0, .identity = 1, .entry = stabilizeBuffered(bufferedResultProbe) };
    var storage: [1]Value = undefined;
    const borrowed = try ctx.callBufferedDirectFunction(callable, bufferedResultProbe, &.{.{ .number = 3 }}, &storage);
    try std.testing.expectEqual(@as(usize, 1), borrowed.len);
    try std.testing.expectEqual(@as(f64, 3), borrowed[0].number);
    try std.testing.expect(borrowed.ptr == storage[0..].ptr);
    var stable_storage: [1]Value = undefined;
    const stable_borrowed = try ctx.callEntryBuffered(callable.entry, .{ .direct = &.{} }, &.{.{ .number = 6 }}, &stable_storage);
    try std.testing.expectEqual(@as(usize, 1), stable_borrowed.len);
    try std.testing.expectEqual(@as(f64, 6), stable_borrowed[0].number);
    try std.testing.expect(stable_borrowed.ptr == stable_storage[0..].ptr);
    var none: [0]Value = .{};
    const discarded = try ctx.callBufferedDirectFunction(callable, bufferedResultProbe, &.{.{ .number = 4 }}, &none);
    try std.testing.expectEqual(@as(usize, 0), discarded.len);
    const stable = try ctx.callEntry(callable.entry, .{ .direct = &.{} }, &.{.{ .number = 5 }});
    defer freeResults(stable);
    try std.testing.expectEqual(@as(usize, 1), stable.len);
    try std.testing.expectEqual(@as(f64, 5), stable[0].number);
}

fn guardTestExpected(_: *Context, captures: Captures, args: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    const arg = if (args.len == 0) 0 else args[0].number;
    out[0] = .{ .number = guardCapture(captures) + arg };
    return out;
}

fn guardTestOther(_: *Context, captures: Captures, args: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    const arg = if (args.len == 0) 0 else args[0].number;
    out[0] = .{ .number = 100 + guardCapture(captures) + arg };
    return out;
}

test "Lua closures retain their compiled entrypoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const functions = [_]FunctionFn{stabilize(guardTestOther)};
    var cell = Cell{ .value = .{ .number = 7 } };
    const callable = try ctx.makeFunction(0, functions[0], &.{&cell});
    const out = try ctx.callValue(callable, &.{.{ .number = 3 }});
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 110), out[0].number);
}

fn nativeDispatchFailureProbe(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
    return error.NativeDispatchProbe;
}

test "native calls invoke the callable entrypoint directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const callable = try ctx.newNative(null, nativeDispatchFailureProbe);
    try std.testing.expect(callable == .callable);
    try std.testing.expectEqual(native_function_id, callable.callable.id);
    try std.testing.expectError(error.AotCallFailed, ctx.callValue(callable, &.{}));
    try std.testing.expectEqualStrings("NativeDispatchProbe", ctx.aotErrorName().?);
}

fn nativeNotImplementedProbe(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
    return error.NotImplemented;
}

test "native failure diagnostics cover ordinary and fixed calls without changing errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const callable = try ctx.newNative(null, nativeNotImplementedProbe);
    var failures: work_stats.NativeFailures = .{};
    var page: work_stats.Page = .{ .native_failures = &failures };
    const previous = work_stats.begin(&page);
    defer work_stats.end(previous);

    try std.testing.expectError(error.AotCallFailed, ctx.callValue(callable, &.{}));
    try std.testing.expectEqualStrings("NotImplemented", ctx.aotErrorName().?);
    ctx.clearAotErrorName();
    var result_buffer: [1]Value = undefined;
    try std.testing.expectError(error.AotCallFailed, ctx.callValueFixed(callable, &.{}, &result_buffer));
    try std.testing.expectEqualStrings("NotImplemented", ctx.aotErrorName().?);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(@as(u64, 2), failures.entries[0].count);
    try std.testing.expectEqual(@intFromPtr(callable.callable.entry), failures.entries[0].address);
}

test "AOT context startup stays independent of corpus module count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 2, 1_000_000);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 2), ctx.globals.len);
    try std.testing.expectEqual(@as(usize, 1_000_000), ctx.module_count);
    try std.testing.expect(ctx.module_state_pages.len > 0);
    for (ctx.module_state_pages) |page| try std.testing.expect(page == null);
}

test "module state pages initialize only touched modules and preserve pointers" {
    var ctx = try Context.initProgram(std.testing.allocator, 0, 600);
    defer ctx.deinit();
    try std.testing.expect(ctx.moduleState(0) == null);
    const first = try ctx.ensureModuleState(0);
    first.value = .{ .number = 12 };
    try std.testing.expect(ctx.moduleState(255) == null);
    try std.testing.expect(ctx.moduleState(256) == null);
    const last = try ctx.ensureModuleState(255);
    last.deferred_require_visibility = true;
    try std.testing.expect(ctx.moduleState(0).? == first);
    try std.testing.expectEqual(@as(f64, 12), ctx.moduleStateConst(0).?.value.?.number);
    try std.testing.expect(ctx.moduleStateConst(254) == null);
    try std.testing.expect(ctx.moduleState(255).? == last);
    _ = try ctx.ensureModuleState(256);
    try std.testing.expect(ctx.moduleState(257) == null);
    try ctx.observePackage();
    try std.testing.expectError(error.BadModuleId, ctx.ensureModuleState(600));
}

test "package observation visits initialized module states across bitmap words and pages" {
    const Names = struct {
        fn lookup(_: ?*const anyopaque, _: []const u8) ?u32 {
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) {
                0 => "Module:Zero",
                63 => "Module:SixtyThree",
                64 => "Module:SixtyFour",
                255 => "Module:TwoFiftyFive",
                256 => "Module:TwoFiftySix",
                else => null,
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 257);
    defer ctx.deinit();
    ctx.package_loaded = try ctx.newTable();
    ctx.configureModules(null, Names.lookup, Names.name);
    for ([_]u32{ 256, 0, 64, 255, 63 }) |id| {
        const state = try ctx.ensureModuleState(id);
        state.value = .{ .number = @floatFromInt(id) };
        state.deferred_require_visibility = true;
    }
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0001), ctx.module_state_pages[0].?.initialized[0]);
    try std.testing.expectEqual(@as(u64, 1), ctx.module_state_pages[0].?.initialized[1]);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), ctx.module_state_pages[0].?.initialized[3]);
    try std.testing.expectEqual(@as(u64, 1), ctx.module_state_pages[1].?.initialized[0]);
    try ctx.observePackage();
    for ([_]u32{ 0, 63, 64, 255, 256 }) |id| {
        const name = Names.name(null, id).?;
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(id)),
            ctx.package_loaded.?.rawGet(.{ .string = name }).?.number,
        );
        try std.testing.expect(!ctx.moduleState(id).?.deferred_require_visibility);
    }
    try std.testing.expect(ctx.moduleState(62) == null);
    try std.testing.expect(ctx.moduleState(257) == null);
}

test "module calls share global aliases presence iteration and metadata independently" {
    const count = 193;
    var keys: [count]Value = undefined;
    for (&keys, 0..) |*key, slot| key.* = .{ .number = @floatFromInt(slot + 1) };
    keys[0] = .{ .string = "_G" };
    keys[1] = .{ .string = "native" };
    keys[64] = .{ .string = "early" };
    keys[128] = .{ .string = "late" };
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .field_count = count, .open = true };
    var ctx = try Context.initProgram(std.testing.allocator, count, 2);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, &shape, 0);
    const environment = ctx.global_table.?;
    const globals = ctx.globals.ptr;
    try ctx.setGlobal(1, .{ .number = 1 });
    try ctx.setGlobal(128, .{ .number = 8 });
    const first = try ctx.enterModule(0);
    try std.testing.expectEqual(@as(?u32, 0), ctx.active_module_id);
    try ctx.setGlobal(1, .{ .number = 2 });
    try environment.rawSet(ctx.allocator, keys[128], .{ .number = 9 });
    try ctx.setGlobal(64, .{ .boolean = false });
    ctx.restoreModule(first);
    const second = try ctx.enterModule(1);
    try std.testing.expectEqual(@as(?u32, 1), ctx.active_module_id);
    try std.testing.expect(ctx.globals.ptr == globals and ctx.global_table.? == environment);
    try std.testing.expect(ctx.getGlobal(0).table == environment);
    try std.testing.expectEqual(@as(f64, 2), ctx.getGlobal(1).number);
    try std.testing.expectEqual(@as(f64, 9), ctx.getGlobal(128).number);
    try std.testing.expect(!ctx.getGlobal(64).boolean);
    var iterator = environment.iterator();
    for ([_]usize{ 0, 1, 64, 128 }) |slot|
        try std.testing.expect(rawEqual(keys[slot], iterator.next().?.key_ptr.*));
    try std.testing.expect(iterator.next() == null);
    try ctx.setGlobal(128, .nil);
    try std.testing.expect(environment.rawGet(keys[128]) == null);
    try std.testing.expectError(error.BadGlobalSlot, ctx.setGlobal(count, .nil));
    ctx.restoreModule(second);
    try std.testing.expect(ctx.active_module_id == null);
    try std.testing.expect(ctx.getGlobal(128) == .nil);
    try std.testing.expect(!ctx.getGlobal(64).boolean);
}

fn invocationGlobalAllocationCase(allocator: std.mem.Allocator, env_slot: u32) !void {
    var keys = @as([257]Value, @splat(.nil));
    keys[env_slot] = .{ .string = "_G" };
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .field_count = keys.len, .open = true };
    var ctx = try Context.initProgram(allocator, keys.len, 2);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, &shape, env_slot);
    const environment = ctx.global_table.?;
    const previous = try ctx.enterModule(0);
    try ctx.setGlobal(64, .{ .number = 1 });
    ctx.restoreModule(previous);
    const second = try ctx.enterModule(1);
    defer ctx.restoreModule(second);
    try std.testing.expect(ctx.getGlobal(env_slot).table == environment);
    try std.testing.expect(ctx.global_table.? == environment);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(64).number);
    try ctx.setGlobal(128, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), ctx.getGlobal(128).number);
}

test "shared invocation globals clean up allocation failures including a late environment slot" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, invocationGlobalAllocationCase, .{@as(u32, 0)});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, invocationGlobalAllocationCase, .{@as(u32, 256)});
}

test "reassigning the G variable preserves actual shared environment and saved aliases" {
    const keys = [_]Value{ .{ .string = "_G" }, .{ .string = "x" }, .{ .string = "late" } };
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .field_count = keys.len, .open = true };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), keys.len, 2);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, &shape, 0);
    const saved = ctx.global_table.?;
    for ([_]Value{ .nil, .{ .table = try ctx.newTable() } }) |replacement| {
        const first = try ctx.enterModule(0);
        try ctx.setGlobal(0, replacement);
        try ctx.setGlobal(1, .{ .boolean = false });
        ctx.restoreModule(first);
        const second = try ctx.enterModule(1);
        try std.testing.expect(ctx.global_table.? == saved);
        try std.testing.expect(rawEqual(replacement, ctx.getGlobal(0)));
        try std.testing.expect(!saved.rawGet(keys[1]).?.boolean);
        try saved.rawSet(ctx.allocator, keys[2], .{ .number = 19 });
        try std.testing.expectEqual(@as(f64, 19), ctx.getGlobal(2).number);
        ctx.restoreModule(second);
    }
}

test "forked AOT context shares native module entries but resets runtime state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parent = try Context.initProgram(arena.allocator(), 2, 1);
    defer parent.deinit();
    const functions = [_]FunctionFn{stabilize(ModuleRuntimeProbe.named)};
    parent.module_root_entries = &functions;
    parent.configureModules(null, ModuleRuntimeProbe.lookup, ModuleRuntimeProbe.name);
    var host_marker: u8 = 0;
    parent.setHost(&host_marker);
    parent.current_frame = try parent.newTable();
    try parent.setGlobal(1, .{ .number = 9 });
    try parent.preinitializeModule(0, .{ .number = 1 }, false);

    var child = try parent.forkProgram(arena.allocator());
    defer child.deinit();
    try std.testing.expect(child.module_root_entries.ptr == parent.module_root_entries.ptr);
    try std.testing.expect(child.getGlobal(1) == .nil);
    try std.testing.expect(child.moduleState(0) == null);
    try std.testing.expectEqual(@as(f64, 1), parent.preparedModuleValue(0).?.number);
    try std.testing.expect(child.host == parent.host);
    try std.testing.expect(child.current_frame == null);
    try std.testing.expectEqual(@as(u32, 0), try child.resolveModule("Module:A"));
}

test "native namespace fields use fixed slots with generic fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();

    const native = try ctx.newNativeNamespace(.table);
    try native.rawSetNativeField(.table, "insert", .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), native.rawGet(.{ .string = "insert" }).?.number);
    try std.testing.expectEqual(@as(usize, static_fields.fieldCount(.table)), native.slots.len);
    try std.testing.expectEqual(@as(usize, 0), native.map.count());
    try std.testing.expectError(error.BadNativeNamespace, native.rawSetNativeField(.string, "len", .{ .number = 1 }));

    const generic = try ctx.newTable();
    try generic.rawSet(ctx.allocator, .{ .string = "insert" }, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), generic.rawGet(.{ .string = "insert" }).?.number);
    try std.testing.expectEqual(@as(usize, 1), generic.map.count());
}

test "indexed global shape preserves slot aliases iteration and context isolation" {
    const keys = [_]Value{
        .{ .string = "_G" }, .{ .string = "zebra" }, .{ .string = "alpha" }, .{ .string = "middle" },
    };
    const sorted_slots = [_]u32{ 0, 2, 3, 1 };
    const shape: Shape = .{
        .keys = .{ .boxed = &keys },
        .sorted_string_slots = &sorted_slots,
        .field_count = keys.len,
        .open = true,
    };
    var first = try Context.init(std.testing.allocator, keys.len);
    defer first.deinit();
    var second = try Context.init(std.testing.allocator, keys.len);
    defer second.deinit();
    try bindGlobalTable(&first, &shape, 0);
    try bindGlobalTable(&second, &shape, 0);
    const table = first.global_table.?;
    for (keys[1..], 1..) |key, slot| {
        try first.setGlobal(@intCast(slot), .{ .number = @floatFromInt(slot) });
        try std.testing.expectEqual(@as(f64, @floatFromInt(slot)), table.rawGet(key).?.number);
        try std.testing.expect(second.global_table.?.rawGet(key) == null);
    }
    const saved_slot_pointer = &first.globals[1];
    try table.rawSet(first.allocator, keys[1], .{ .number = 19 });
    try std.testing.expectEqual(@as(f64, 19), first.getGlobal(1).number);
    try std.testing.expectEqual(@as(f64, 19), saved_slot_pointer.number);
    try std.testing.expect(second.getGlobal(1) == .nil);
    try std.testing.expect(table.rawGet(.{ .string = "unknown" }) == null);
    try table.rawSet(first.allocator, .{ .string = "unknown" }, .{ .number = 23 });
    try std.testing.expectEqual(@as(f64, 23), table.rawGet(.{ .string = "unknown" }).?.number);
    var it = table.iterator();
    for (keys) |key| {
        const entry = it.next().?;
        try std.testing.expect(rawEqual(key, entry.key_ptr.*));
    }
    const extra = it.next().?;
    try std.testing.expectEqualStrings("unknown", extra.key_ptr.string);
    try std.testing.expect(it.next() == null);
}

test "generic tables use dense numeric slots and keep sparse keys hashed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const table = try ctx.newTable();

    const nine = Value{ .number = 9 };
    try table.rawSet(ctx.allocator, nine, .{ .number = 900 });
    try std.testing.expectEqual(@as(usize, 0), table.slots.len);
    try std.testing.expectEqual(@as(f64, 900), table.map.getContext(nine, .{}).?.number);

    for (1..10) |i| try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, .{ .number = @floatFromInt(i * 10) });
    try std.testing.expect(table.slots.len >= 9);
    try std.testing.expect(table.rawGetSlot(0) == null);
    try std.testing.expectError(error.BadShapeSlot, table.rawSetSlot(0, .{ .number = 999 }));
    try std.testing.expect(table.map.getContext(nine, .{}) == null);
    for (1..10) |i| try std.testing.expectEqual(@as(f64, @floatFromInt(i * 10)), table.rawGetNumber(@floatFromInt(i)).?.number);
    try std.testing.expectEqual(@as(usize, 9), table.rawLen());

    const array_capacity = table.slots.len;
    const sparse = Value{ .number = 1000 };
    try table.rawSet(ctx.allocator, sparse, .{ .number = 5 });
    try std.testing.expectEqual(array_capacity, table.slots.len);
    try std.testing.expectEqual(@as(f64, 5), table.rawGetNumber(1000).?.number);
    try std.testing.expectEqual(@as(f64, 5), table.map.getContext(sparse, .{}).?.number);

    var iterator = table.iterator();
    var count: usize = 0;
    var nine_count: usize = 0;
    while (iterator.next()) |entry| {
        count += 1;
        if (entry.key_ptr.* == .number and entry.key_ptr.number == 9) nine_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), count);
    try std.testing.expectEqual(@as(usize, 1), nine_count);

    try table.rawSet(ctx.allocator, nine, .nil);
    try std.testing.expect(table.rawGetNumber(9) == null);
    try std.testing.expect(table.map.getContext(nine, .{}) == null);
    try std.testing.expectEqual(@as(usize, 8), table.rawLen());
}

test "numeric lookups skip string-only maps and retain sparse numeric fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const table = try ctx.newTable();

    try table.rawSet(ctx.allocator, .{ .string = "named" }, .{ .number = 10 });
    try table.rawSet(ctx.allocator, .{ .number = 1 }, .{ .string = "first" });
    try std.testing.expect(!table.has_hashed_number);
    try std.testing.expect(table.rawGetNumber(2) == null);
    try std.testing.expect(table.rawGet(.{ .number = 2 }) == null);
    try std.testing.expectEqualStrings("first", table.rawGetNumber(1).?.string);
    try std.testing.expectEqualStrings("first", table.rawGet(.{ .number = 1 }).?.string);
    try std.testing.expectEqual(@as(usize, 1), table.rawLen());

    try table.rawSet(ctx.allocator, .{ .number = 1000 }, .{ .string = "sparse" });
    try std.testing.expect(table.has_hashed_number);
    try std.testing.expectEqualStrings("sparse", table.rawGetNumber(1000).?.string);
    try std.testing.expectEqualStrings("sparse", table.rawGet(.{ .number = 1000 }).?.string);
    try table.rawSet(ctx.allocator, .{ .number = 1000 }, .nil);
    try std.testing.expect(table.has_hashed_number);
    try std.testing.expect(table.rawGetNumber(1000) == null);
    try std.testing.expect(table.rawGet(.{ .number = 1000 }) == null);

    try table.rawSet(ctx.allocator, .{ .number = -0.0 }, .{ .string = "zero" });
    try std.testing.expectEqualStrings("zero", table.rawGetNumber(0.0).?.string);
    try std.testing.expect(table.rawGetNumber(std.math.nan(f64)) == null);
}

test "program string shapes use sorted slots with open fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();

    const keys = [_]Value{ .{ .string = "zeta" }, .{ .string = "alpha" }, .{ .string = "middle" } };
    const sorted = [_]u32{ 1, 2, 0 };
    const shapes = [_]Shape{.{
        .keys = .{ .boxed = &keys },
        .sorted_string_slots = &sorted,
        .field_count = keys.len,
        .open = true,
    }};
    ctx.program_shapes = &shapes;
    const export_shapes = [_]u32{0};
    ctx.module_export_shape_ids = &export_shapes;
    const known = ctx.moduleExportSlot(0, "alpha") orelse return error.MissingShapeSlot;
    try std.testing.expectEqual(@as(u32, 0), known.shape_id);
    try std.testing.expectEqual(@as(u32, 1), known.slot);
    try std.testing.expect(ctx.moduleExportSlot(0, "unknown") == null);
    const table = try ctx.newProgramShape(0);
    try table.rawSet(ctx.allocator, .{ .string = "zeta" }, .{ .number = 1 });
    try table.rawSet(ctx.allocator, .{ .string = "alpha" }, .{ .number = 2 });
    try table.rawSet(ctx.allocator, .{ .string = "other" }, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 1), table.rawGet(.{ .string = "zeta" }).?.number);
    try std.testing.expectEqual(@as(f64, 2), table.rawGet(.{ .string = "alpha" }).?.number);
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getProgramShapeField(.{ .table = table }, known.shape_id, known.slot, "alpha")).number);
    try std.testing.expectEqual(@as(f64, 3), table.rawGet(.{ .string = "other" }).?.number);
    try std.testing.expectEqual(@as(usize, 1), table.map.count());
}

test "compact callable descriptors preserve copies identities and live captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    var first_cell = Cell{ .value = .{ .number = 11 } };
    var second_cell = Cell{ .value = .{ .number = 22 } };
    const first = try ctx.makeFunction(7, stabilizeBuffered(bufferedResultProbe), &.{&first_cell});
    const second = try ctx.makeFunction(7, stabilizeBuffered(bufferedResultProbe), &.{&second_cell});
    const copy = first;
    const first_captures = first.callable.capturesPtr().?;
    try std.testing.expect(first.callable != second.callable);
    try std.testing.expect(copy.callable == first.callable);
    try std.testing.expect(rawEqual(copy, first));
    try std.testing.expect(!rawEqual(first, second));

    const keys = try ctx.newTable();
    try keys.rawSet(ctx.allocator, first, .{ .number = 101 });
    try keys.rawSet(ctx.allocator, second, .{ .number = 202 });
    try std.testing.expectEqual(@as(f64, 101), keys.rawGet(copy).?.number);
    try std.testing.expectEqual(@as(f64, 202), keys.rawGet(second).?.number);

    const plain = try ctx.makeFunction(7, stabilizeBuffered(bufferedResultProbe), &.{});
    const another_plain = try ctx.makeFunction(7, stabilizeBuffered(bufferedResultProbe), &.{});
    try std.testing.expect(plain.callable.capturesPtr() == null);
    try std.testing.expect(!rawEqual(plain, another_plain));
    // Growing the arena must not move either an earlier descriptor or its
    // adjacent environment. No closure is interned merely by its source ID.
    for (0..256) |_| _ = try ctx.makeFunction(7, stabilizeBuffered(bufferedResultProbe), &.{});
    try std.testing.expect(first.callable.capturesPtr().? == first_captures);
    first_cell.value = .{ .number = 40 };
    var storage: [1]Value = undefined;
    const first_result = try ctx.callValueFixed(copy, &.{.{ .number = 2 }}, &storage);
    defer first_result.deinit();
    try std.testing.expect(!first_result.owned);
    try std.testing.expectEqual(@as(f64, 42), first_result.values[0].number);
    const second_result = try ctx.callValueFixed(second, &.{.{ .number = 3 }}, &storage);
    defer second_result.deinit();
    try std.testing.expectEqual(@as(f64, 25), second_result.values[0].number);
}

test "captured function stores copied pointer tails in its owning context" {
    var first = try Context.init(std.testing.allocator, 0);
    defer first.deinit();
    var second = try Context.init(std.testing.allocator, 0);
    defer second.deinit();
    var cells: [17]Cell = undefined;
    var pointers: [17]*Cell = undefined;
    for (&cells, &pointers, 0..) |*cell, *ptr, index| {
        cell.* = .{ .value = .{ .number = @floatFromInt(index) } };
        ptr.* = cell;
    }
    const entry = stabilizeBuffered(bufferedResultProbe);
    const one = try first.makeFunction(7, entry, &.{pointers[0]});
    const many = try first.makeFunction(7, entry, &pointers);
    const other = try second.makeFunction(7, entry, &pointers);
    const captured = many.callable.capturesPtr().?.direct;
    try std.testing.expectEqual(@as(usize, pointers.len), captured.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(captured.ptr) % @alignOf(*Cell));
    try std.testing.expect(@intFromPtr(captured.ptr) >= @intFromPtr(many.callable));
    try std.testing.expect(@intFromPtr(captured.ptr) - @intFromPtr(many.callable) < @sizeOf(FunctionValue) + @sizeOf(Env) + @alignOf(*Cell));
    pointers[0] = &cells[1];
    try std.testing.expect(one.callable.capturesPtr().?.direct[0] == &cells[0]);
    try std.testing.expect(captured[0] == &cells[0]);
    try std.testing.expect(other.callable.capturesPtr().?.direct[0] == &cells[0]);
    try std.testing.expect(other.callable.capturesPtr().?.direct.ptr != captured.ptr);
    for (captured, 0..) |cell, index| try std.testing.expect(cell == &cells[index]);
    for (0..512) |_| _ = try first.makeFunction(7, entry, &pointers);
    try std.testing.expect(many.callable.capturesPtr().?.direct.ptr == captured.ptr);
    cells[0].value = .{ .number = 40 };
    var storage: [1]Value = undefined;
    const result = try first.callValueFixed(many, &.{.{ .number = 2 }}, &storage);
    defer result.deinit();
    try std.testing.expectEqual(@as(f64, 42), result.values[0].number);
}

test "prehashed field writes retain growth nil and newindex behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const original = try ctx.newTable();
    const hashed = try ctx.newTable();
    const Compare = struct {
        fn tables(a: *Table, b: *Table) !void {
            try std.testing.expectEqual(a.map.count(), b.map.count());
            try std.testing.expectEqual(a.map.capacity(), b.map.capacity());
            try std.testing.expectEqual(a.field_cache_epoch, b.field_cache_epoch);
            var left = a.iterator();
            var right = b.iterator();
            while (left.next()) |entry| {
                const other = right.next() orelse return error.MissingField;
                try std.testing.expect(rawEqual(entry.key_ptr.*, other.key_ptr.*));
                try std.testing.expect(rawEqual(entry.value_ptr.*, other.value_ptr.*));
            }
            try std.testing.expect(right.next() == null);
        }
    };
    var long_name: [257]u8 = @as([257]u8, @splat('x'));
    long_name[256] = 'a';
    try ctx.setIndex(.{ .table = original }, .{ .string = &long_name }, .{ .number = 1 });
    try ctx.setHashedField(.{ .table = hashed }, &long_name, stringValueHash(&long_name), .{ .number = 1 });
    var keys: [64][]const u8 = undefined;
    var count: usize = 0;
    while (original.map.available != 0 and count < keys.len) : (count += 1) {
        keys[count] = try std.fmt.allocPrint(ctx.allocator, "field-{d}", .{count});
        try ctx.setIndex(.{ .table = original }, .{ .string = keys[count] }, .{ .number = @floatFromInt(count) });
        try ctx.setHashedField(.{ .table = hashed }, keys[count], stringValueHash(keys[count]), .{ .number = @floatFromInt(count) });
    }
    try std.testing.expect(count != keys.len);
    try Compare.tables(original, hashed);
    // An overwrite at the map load limit retains storage and iteration order.
    const capacity_before_overwrite = original.map.capacity();
    try ctx.setIndex(.{ .table = original }, .{ .string = &long_name }, .{ .number = 7 });
    try ctx.setHashedField(.{ .table = hashed }, &long_name, stringValueHash(&long_name), .{ .number = 7 });
    try std.testing.expectEqual(capacity_before_overwrite, original.map.capacity());
    try std.testing.expectEqual(capacity_before_overwrite, hashed.map.capacity());
    try Compare.tables(original, hashed);
    try ctx.setIndex(.{ .table = original }, .{ .string = &long_name }, .nil);
    try ctx.setHashedField(.{ .table = hashed }, &long_name, stringValueHash(&long_name), .nil);
    try Compare.tables(original, hashed);
    try ctx.setIndex(.{ .table = original }, .{ .string = &long_name }, .{ .number = 9 });
    try ctx.setHashedField(.{ .table = hashed }, &long_name, stringValueHash(&long_name), .{ .number = 9 });
    try Compare.tables(original, hashed);

    // Nil-valued retained map cells are absent to lookup and __newindex,
    // even though next() can still resume from their key identity.
    var left = original.iterator();
    while (left.next()) |entry| if (entry.key_ptr.* == .string and std.mem.eql(u8, entry.key_ptr.string, long_name[0..])) {
        entry.value_ptr.* = .nil;
        break;
    };
    var right = hashed.iterator();
    while (right.next()) |entry| if (entry.key_ptr.* == .string and std.mem.eql(u8, entry.key_ptr.string, long_name[0..])) {
        entry.value_ptr.* = .nil;
        break;
    };
    const Handler = struct {
        fn call(_: ?*anyopaque, runtime: *Context, args: []const Value) ![]const Value {
            if (args.len != 3 or args[0] != .table) return error.BadNewIndexArgs;
            args[0].table.metatable = null;
            try runtime.setIndex(args[0], args[1], args[2]);
            return &.{};
        }
    };
    const mt = try ctx.newTable();
    try mt.rawSet(ctx.allocator, .{ .string = "__newindex" }, try ctx.newNative(null, Handler.call));
    original.metatable = mt;
    hashed.metatable = mt;
    try ctx.setIndex(.{ .table = original }, .{ .string = &long_name }, .{ .number = 13 });
    try ctx.setHashedField(.{ .table = hashed }, &long_name, stringValueHash(&long_name), .{ .number = 13 });
    try std.testing.expect(original.metatable == null and hashed.metatable == null);
    try Compare.tables(original, hashed);
    original.metatable = mt;
    hashed.metatable = mt;
    const absent = "another-very-long-absent-field-name";
    try ctx.setIndex(.{ .table = original }, .{ .string = absent }, .{ .number = 20 });
    try ctx.setHashedField(.{ .table = hashed }, absent, stringValueHash(absent), .{ .number = 20 });
    try std.testing.expect(original.metatable == null and hashed.metatable == null);
    try Compare.tables(original, hashed);
}

test "prehashed field writes preserve shaped choices redirects and readonly errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "slot" }};
    const shape = Shape{ .keys = .{ .boxed = &keys }, .field_count = 1, .choice_count = 1 };
    const original = try ctx.newShapedTable(&shape);
    const hashed = try ctx.newShapedTable(&shape);
    for ([_]*Table{ original, hashed }) |table| {
        try table.rawSetSlot(0, .{ .number = 1 });
        try table.rawSetChoice(0, .{ .string = "choice" }, .{ .number = 2 });
        try table.rawSet(ctx.allocator, .{ .string = "overflow" }, .{ .number = 3 });
    }
    for ([_][]const u8{ "slot", "choice", "overflow" }) |name| {
        try ctx.setIndex(.{ .table = original }, .{ .string = name }, .{ .number = 4 });
        try ctx.setHashedField(.{ .table = hashed }, name, stringValueHash(name), .{ .number = 4 });
        try std.testing.expectEqual(@as(f64, 4), hashed.rawGet(.{ .string = name }).?.number);
        try std.testing.expectEqual(original.field_cache_epoch, hashed.field_cache_epoch);
    }
    // A matching shape slot takes the write even if the visible own value
    // currently comes from a choice with the same key.
    const overlap_original = try ctx.newShapedTable(&shape);
    const overlap_hashed = try ctx.newShapedTable(&shape);
    const overlap_mt = try ctx.newTable();
    for ([_]*Table{ overlap_original, overlap_hashed }) |table| {
        try table.rawSetChoice(0, .{ .string = "slot" }, .{ .number = 12 });
        table.metatable = overlap_mt;
    }
    try ctx.setIndex(.{ .table = overlap_original }, .{ .string = "slot" }, .{ .number = 15 });
    try ctx.setHashedField(.{ .table = overlap_hashed }, "slot", stringValueHash("slot"), .{ .number = 15 });
    try std.testing.expectEqual(@as(f64, 15), overlap_hashed.rawGetSlot(0).?.number);
    try std.testing.expectEqual(@as(f64, 12), overlap_hashed.choices[0].value.number);
    try std.testing.expectEqual(overlap_original.field_cache_epoch, overlap_hashed.field_cache_epoch);
    const target_original = try ctx.newTable();
    const target_hashed = try ctx.newTable();
    const mt_original = try ctx.newTable();
    const mt_hashed = try ctx.newTable();
    try mt_original.rawSet(ctx.allocator, .{ .string = "__newindex" }, .{ .table = target_original });
    try mt_hashed.rawSet(ctx.allocator, .{ .string = "__newindex" }, .{ .table = target_hashed });
    original.metatable = mt_original;
    hashed.metatable = mt_hashed;
    const absent = "redirected-field";
    try ctx.setIndex(.{ .table = original }, .{ .string = absent }, .{ .number = 9 });
    try ctx.setHashedField(.{ .table = hashed }, absent, stringValueHash(absent), .{ .number = 9 });
    try std.testing.expect(original.rawGet(.{ .string = absent }) == null);
    try std.testing.expect(hashed.rawGet(.{ .string = absent }) == null);
    try std.testing.expectEqual(@as(f64, 9), target_original.rawGet(.{ .string = absent }).?.number);
    try std.testing.expectEqual(@as(f64, 9), target_hashed.rawGet(.{ .string = absent }).?.number);
    original.read_only = true;
    hashed.read_only = true;
    try std.testing.expectError(error.ReadOnlyTable, ctx.setIndex(.{ .table = original }, .{ .string = "slot" }, .{ .number = 5 }));
    try std.testing.expectError(error.ReadOnlyTable, ctx.setHashedField(.{ .table = hashed }, "slot", stringValueHash("slot"), .{ .number = 5 }));
}

test "compact native descriptors preserve host pointers through arena growth" {
    var ctx = try Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    var host = Cell{ .value = .{ .number = 5 } };
    const HostProbe = struct {
        fn call(raw: ?*anyopaque, _: *Context, _: []const Value, buffer: ?[]Value) ![]const Value {
            const cell: *Cell = @ptrCast(@alignCast(raw orelse return error.MissingHost));
            const out = try returnBuffer(buffer, 1);
            storeReturn(out, 0, cell.value);
            return out;
        }
    };
    const native = try ctx.newNativeBuffered(&host, HostProbe.call);
    const copy = native;
    for (0..256) |_| _ = try ctx.newNativeBuffered(null, HostProbe.call);
    try std.testing.expect(native.callable.capturesPtr() == null);
    try std.testing.expect(native.callable.captures().native == @as(?*anyopaque, @ptrCast(&host)));
    try std.testing.expect(rawEqual(native, copy));
    host.value = .{ .number = 19 };
    var storage: [1]Value = undefined;
    const result = try ctx.callValueFixed(copy, &.{}, &storage);
    defer result.deinit();
    try std.testing.expect(!result.owned);
    try std.testing.expectEqual(@as(f64, 19), result.values[0].number);
}

test "runtime Value stays compact and function identities never wrap" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Value));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(FunctionValue));
    var ctx = try Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    ctx.next_identity = std.math.maxInt(u32);
    const last = try ctx.newNative(null, struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
    }.call);
    try std.testing.expectEqual(std.math.maxInt(u32), last.callable.identity);
    try std.testing.expectError(error.FunctionIdentityExhausted, ctx.newNative(null, struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
    }.call));
}

test "concat strings use owned arena without interning" {
    var runtime = try Context.init(std.testing.allocator, 0);
    defer runtime.deinit();
    const first = try runtime.concatValues(&.{ .{ .string = "ab" }, .{ .string = "cd" } });
    const second = try runtime.concatValues(&.{ .{ .string = "ab" }, .{ .string = "cd" } });
    try std.testing.expect(first == .string and second == .string);
    try std.testing.expectEqualStrings("abcd", first.string);
    try std.testing.expect(rawEqual(first, second));
    try std.testing.expectEqual((ValueContext{}).hash(first), (ValueContext{}).hash(second));
    try std.testing.expect(first.string.ptr != second.string.ptr);
}

test "all-string shaped tables mirror numeric reads without changing iteration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "_parse_data" }};
    const sorted = [_]u32{0};
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true };
    const table = try ctx.newShapedTable(&shape);
    try table.rawSet(ctx.allocator, keys[0], .{ .string = "metadata" });
    try std.testing.expectEqual(@as(usize, 0), table.rawLen());
    for (1..17) |i| {
        try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, .{ .number = @floatFromInt(i * 10) });
        try std.testing.expectEqual(i, table.rawLen());
        try std.testing.expectEqual(@as(f64, @floatFromInt(i * 10)), table.rawGetNumber(@floatFromInt(i)).?.number);
    }
    try std.testing.expectEqual(@as(usize, 16), table.numeric_mirror.len);
    try std.testing.expectEqual(@as(usize, 16), table.map.count()); // metadata lives in its shape slot.
    try table.rawSet(ctx.allocator, .{ .number = 8 }, .nil);
    try std.testing.expect(table.rawGetNumber(8) == null);
    try std.testing.expect(!table.dense_prefix_valid);
    try std.testing.expectEqual(table.map.getContext(.{ .number = 16 }, .{}).?.number, table.rawGetNumber(16).?.number);
    var seen: usize = 0;
    var it = table.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* == .number) {
            seen += 1;
            try std.testing.expectEqual(table.map.getContext(entry.key_ptr.*, .{}).?.number, entry.value_ptr.number);
        }
    }
    try std.testing.expectEqual(@as(usize, 15), seen);
}

test "numeric mirror does not hide metatable fallback or out-of-range keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "name" }};
    const sorted = [_]u32{0};
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true };
    const table = try ctx.newShapedTable(&shape);
    const mt = try ctx.newTable();
    const fallback = try ctx.newTable();
    try fallback.rawSet(ctx.allocator, .{ .number = 2 }, .{ .string = "fallback" });
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = fallback });
    table.metatable = mt;
    try table.rawSet(ctx.allocator, .{ .number = 1 }, .{ .string = "first" });
    try std.testing.expectEqualStrings("fallback", (try ctx.getIndex(.{ .table = table }, .{ .number = 2 })).string);
    try table.rawSet(ctx.allocator, .{ .number = 40 }, .{ .number = 40 });
    try std.testing.expectEqual(@as(f64, 40), table.rawGetNumber(40).?.number);
    try table.rawSet(ctx.allocator, .{ .number = 1.5 }, .{ .string = "fraction" });
    try std.testing.expectEqualStrings("fraction", table.rawGetNumber(1.5).?.string);
    try table.rawSet(ctx.allocator, .{ .number = -1 }, .{ .string = "negative" });
    try std.testing.expectEqualStrings("negative", table.rawGetNumber(-1).?.string);
}

test "numeric mirror and dense prefix match baseline after sparse mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "label" }};
    const sorted = [_]u32{0};
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true };
    const unoptimized_shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true };
    const fast = try ctx.newShapedTable(&shape);
    const old = try ctx.newShapedTable(&unoptimized_shape);
    const writes = [_]struct { key: f64, value: Value }{
        .{ .key = 1, .value = .{ .number = 10 } },
        .{ .key = 2, .value = .{ .number = 20 } },
        .{ .key = 3, .value = .{ .number = 30 } },
        .{ .key = 2, .value = .{ .number = 21 } },
        .{ .key = 40, .value = .{ .number = 40 } },
        .{ .key = 1, .value = .nil },
        .{ .key = 1, .value = .{ .number = 11 } },
        .{ .key = 0, .value = .{ .number = 0 } },
        .{ .key = 1.5, .value = .{ .number = 15 } },
        .{ .key = 40, .value = .nil },
    };
    for (writes) |write| {
        try fast.rawSet(ctx.allocator, .{ .number = write.key }, write.value);
        try old.rawSet(ctx.allocator, .{ .number = write.key }, write.value);
        try std.testing.expectEqual(old.rawLen(), fast.rawLen());
        for ([_]f64{ 0, 1, 1.5, 2, 3, 4, 16, 40 }) |n| {
            const before = old.rawGetNumber(n) orelse .nil;
            const after = fast.rawGetNumber(n) orelse .nil;
            try std.testing.expect(rawEqual(before, after));
        }
    }
    var oi = old.iterator();
    var fi = fast.iterator();
    while (oi.next()) |entry| {
        const counterpart = fi.next() orelse return error.IterationOrderChanged;
        try std.testing.expect(rawEqual(entry.key_ptr.*, counterpart.key_ptr.*));
        try std.testing.expect(rawEqual(entry.value_ptr.*, counterpart.value_ptr.*));
    }
    try std.testing.expect(fi.next() == null);
}

test "numeric mirror allocation is optional and map failures leave it coherent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "field" }};
    const sorted = [_]u32{0};
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true };
    const first = try ctx.newShapedTable(&shape);
    try first.map.ensureTotalCapacity(ctx.allocator, 8);
    var fail_mirror = std.testing.FailingAllocator.init(ctx.allocator, .{ .fail_index = 0 });
    try first.rawSet(fail_mirror.allocator(), .{ .number = 1 }, .{ .number = 11 });
    try std.testing.expect(fail_mirror.has_induced_failure);
    try std.testing.expect(first.numeric_mirror_disabled);
    try std.testing.expectEqual(@as(f64, 11), first.rawGetNumber(1).?.number);

    const second = try ctx.newShapedTable(&shape);
    try second.rawSet(ctx.allocator, .{ .number = 1 }, .{ .number = 21 });
    try std.testing.expect(second.numeric_mirror.len != 0);
    var failed_at: ?usize = null;
    for (2..100) |i| {
        var fail_map = std.testing.FailingAllocator.init(ctx.allocator, .{ .fail_index = 0 });
        second.rawSet(fail_map.allocator(), .{ .number = @floatFromInt(i) }, .{ .number = @floatFromInt(i * 10) }) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
            failed_at = i;
            break;
        };
    }
    const missing = failed_at orelse return error.ExpectedMapGrowthFailure;
    try std.testing.expectEqual(@as(f64, 21), second.rawGetNumber(1).?.number);
    try std.testing.expect(second.rawGetNumber(@floatFromInt(missing)) == null);
    try second.rawSet(ctx.allocator, .{ .number = @floatFromInt(missing) }, .{ .number = 99 });
    try std.testing.expectEqual(@as(f64, 99), second.rawGetNumber(@floatFromInt(missing)).?.number);
}

test "numeric mirror rejects out-of-range integer conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "field" }};
    const sorted = [_]u32{0};
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true };
    const table = try ctx.newShapedTable(&shape);
    const huge: f64 = 0x1p64;
    try table.rawSet(ctx.allocator, .{ .number = huge }, .{ .string = "huge" });
    try std.testing.expectEqualStrings("huge", table.rawGetNumber(huge).?.string);
    try std.testing.expect(!table.dense_prefix_valid);
    try std.testing.expect(table.numeric_mirror.len == 0);
}

test "iterator mutable value pointer invalidates shaped numeric mirror" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "field" }};
    const sorted = [_]u32{0};
    const shape: Shape = .{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true };
    const table = try ctx.newShapedTable(&shape);
    try table.rawSet(ctx.allocator, .{ .number = 1 }, .{ .number = 1 });
    try std.testing.expectEqual(@as(usize, 1), table.rawLen());
    var it = table.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* == .number and entry.key_ptr.number == 1) entry.value_ptr.* = .{ .number = 42 };
    }
    try std.testing.expect(table.numeric_mirror_disabled);
    try std.testing.expectEqual(@as(f64, 42), table.rawGetNumber(1).?.number);
}

test "adoptFailure distinguishes explicit nil and owns string payload" {
    var parent_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parent_arena.deinit();
    var child_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer child_arena.deinit();
    var parent = try Context.init(parent_arena.allocator(), 0);
    defer parent.deinit();
    var child = try Context.init(child_arena.allocator(), 0);
    defer child.deinit();

    child.setLuaError(.nil);
    try parent.adoptFailure(&child);
    try std.testing.expect(parent.last_error_present and parent.last_error == .nil);

    const child_text = try child.allocator.dupe(u8, "child error");
    child.setLuaError(.{ .string = child_text });
    try parent.adoptFailure(&child);
    try std.testing.expect(parent.last_error_present);
    try std.testing.expectEqualStrings("child error", parent.last_error.string);
    try std.testing.expect(parent.last_error.string.ptr != child_text.ptr);

    const child_table = try child.newTable();
    child.setLuaError(.{ .table = child_table });
    try parent.adoptFailure(&child);
    try std.testing.expect(!parent.last_error_present and parent.last_error == .nil);
}

test "prehashed field-site cache follows alias writes and callback mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const hash = comptime static_fields.hashStringKey("key");
    const site: u64 = (@as(u64, 12345) << 32) | 17;
    const table = try ctx.newTable();
    const alias = table;
    const mt = try ctx.newTable();
    table.metatable = mt;
    try table.rawSet(ctx.allocator, .{ .string = "key" }, .{ .number = 1 });
    const object = Value{ .table = table };
    try std.testing.expectEqual(@as(f64, 1), (try ctx.getFieldAtSite(object, "key", hash, site)).number);
    try alias.rawSet(ctx.allocator, .{ .string = "key" }, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "key", hash, site)).number);
    var iterator = alias.iterator();
    const item = iterator.next() orelse return error.MissingIteratorValue;
    item.value_ptr.* = .{ .number = 3 };
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getFieldAtSite(object, "key", hash, site)).number);
    try alias.rawSet(ctx.allocator, .{ .string = "key" }, .nil);
    var calls: usize = 0;
    const Probe = struct {
        fn call(raw: ?*anyopaque, runtime: *Context, args: []const Value) ![]const Value {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
            try args[0].table.rawSet(runtime.allocator, args[1], .{ .number = 4 });
            return &.{};
        }
    };
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, try ctx.newNative(&calls, Probe.call));
    try std.testing.expect((try ctx.getFieldAtSite(object, "key", hash, site)) == .nil);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(f64, 4), (try ctx.getFieldAtSite(object, "key", hash, site)).number);
    try std.testing.expectEqual(@as(usize, 1), calls);
    const other = try ctx.newTable();
    try other.rawSet(ctx.allocator, .{ .string = "key" }, .{ .number = 5 });
    try std.testing.expectEqual(@as(f64, 5), (try ctx.getFieldAtSite(.{ .table = other }, "key", hash, site)).number);
    try std.testing.expectEqual(@as(f64, 4), (try ctx.getFieldAtSite(object, "key", hash, site)).number);
}

test "prehashed field-site cache preserves shaped slot and overflow field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "slot" }};
    const shape = Shape{ .keys = .{ .boxed = &keys }, .field_count = 1 };
    const table = try ctx.newShapedTable(&shape);
    const hash = comptime static_fields.hashStringKey("slot");
    const object = Value{ .table = table };
    try table.rawSetSlot(0, .{ .number = 1 });
    try std.testing.expectEqual(@as(f64, 1), (try ctx.getFieldAtSite(object, "slot", hash, 41)).number);
    try table.rawSetSlot(0, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "slot", hash, 41)).number);
    try table.rawSetSlot(0, .nil);
    try std.testing.expect((try ctx.getFieldAtSite(object, "slot", hash, 41)) == .nil);
    const overflow_hash = comptime static_fields.hashStringKey("overflow");
    try table.rawSet(ctx.allocator, .{ .string = "overflow" }, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getFieldAtSite(object, "overflow", overflow_hash, 42)).number);
    const old_epoch = table.field_cache_epoch;
    try table.rawSet(ctx.allocator, .{ .string = "overflow" }, .nil);
    try std.testing.expect(table.field_cache_epoch != old_epoch);
    try std.testing.expect((try ctx.getFieldAtSite(object, "overflow", overflow_hash, 42)) == .nil);
    const deleted_epoch = table.field_cache_epoch;
    try table.rawSet(ctx.allocator, .{ .string = "overflow" }, .{ .number = 4 });
    try std.testing.expect(table.field_cache_epoch != deleted_epoch);
    try std.testing.expectEqual(@as(f64, 4), (try ctx.getFieldAtSite(object, "overflow", overflow_hash, 42)).number);
    const live_epoch = table.field_cache_epoch;
    try table.rawSetHashedString(ctx.allocator, "overflow", overflow_hash, .{ .number = 5 });
    try std.testing.expectEqual(live_epoch, table.field_cache_epoch);
    try table.rawSetHashedString(ctx.allocator, "overflow", overflow_hash, .nil);
    try std.testing.expect(table.field_cache_epoch != live_epoch);
    try std.testing.expect((try ctx.getFieldAtSite(object, "overflow", overflow_hash, 42)) == .nil);
    const hashed_deleted_epoch = table.field_cache_epoch;
    try table.rawSetHashedString(ctx.allocator, "overflow", overflow_hash, .{ .number = 6 });
    try std.testing.expect(table.field_cache_epoch != hashed_deleted_epoch);
    try std.testing.expectEqual(@as(f64, 6), (try ctx.getFieldAtSite(object, "overflow", overflow_hash, 42)).number);
}

test "field site shares a positive program shape slot across fresh tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();

    const x_keys = [_]Value{.{ .string = "x" }};
    const y_keys = [_]Value{.{ .string = "y" }};
    const sorted = [_]u32{0};
    var shapes = [_]Shape{
        .{ .keys = .{ .boxed = &x_keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true },
        .{ .keys = .{ .boxed = &y_keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true },
    };
    ctx.program_shapes = &shapes;
    ctx.program_shape_generation = 83;
    const site_id: u64 = (@as(u64, 110111) << 32) | 71;
    const key_hash = static_fields.hashStringKey("x");
    const first = try ctx.newProgramShape(0);
    const second = try ctx.newProgramShape(0);
    try first.rawSetSlot(0, .{ .number = 1 });
    try second.rawSetSlot(0, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 1), (try ctx.getFieldAtSite(.{ .table = first }, "x", key_hash, site_id)).number);
    const cache_index: usize = fieldCacheIndex(site_id);
    try std.testing.expectEqual(site_id, FieldCacheStorage.dict_lua_shape_site_cache[cache_index].site_id);
    try std.testing.expectEqual(@as(u32, 0), FieldCacheStorage.dict_lua_shape_site_cache[cache_index].shape_id);
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(.{ .table = second }, "x", key_hash, site_id)).number);
    try second.rawSetSlot(0, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getFieldAtSite(.{ .table = second }, "x", key_hash, site_id)).number);

    const metatable = try ctx.newTable();
    const inherited = try ctx.newTable();
    try inherited.rawSet(ctx.allocator, .{ .string = "x" }, .{ .number = 9 });
    try metatable.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = inherited });
    second.metatable = metatable;
    try second.rawSetSlot(0, .nil);
    try std.testing.expectEqual(@as(f64, 9), (try ctx.getFieldAtSite(.{ .table = second }, "x", key_hash, site_id)).number);
    try second.rawSetSlot(0, .{ .number = 5 });
    try std.testing.expectEqual(@as(f64, 5), (try ctx.getFieldAtSite(.{ .table = second }, "x", key_hash, site_id)).number);

    var iterator = first.iterator();
    const one = iterator.next() orelse return error.MissingShapeField;
    try std.testing.expectEqualStrings("x", one.key_ptr.string);
    try std.testing.expect(iterator.next() == null);

    const other = try ctx.newProgramShape(1);
    try other.rawSetSlot(0, .{ .number = 10 });
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = other }, "x", key_hash, site_id)) == .nil);
    try std.testing.expectError(error.IndexType, ctx.getFieldAtSite(.{ .number = 1 }, "x", key_hash, site_id));

    // Simulate a new metadata load reusing the same shape allocation.
    ctx.program_shape_generation = 84;
    shapes[0] = shapes[1];
    const later = try ctx.newProgramShape(0);
    try later.rawSetSlot(0, .{ .number = 11 });
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = later }, "x", key_hash, site_id)) == .nil);
}

test "bounded inherited site cache reads live three-link field and invalidates mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const hash = comptime static_fields.hashStringKey("method");
    const site: u64 = (@as(u64, 110068) << 32) | 0;
    const keys = [_]Value{.{ .string = "method" }};
    const shape = Shape{ .keys = .{ .boxed = &keys }, .field_count = 1 };
    const receiver = try ctx.newShapedTable(&shape);
    const mt0 = try ctx.newTable();
    const mt1 = try ctx.newTable();
    const mt2 = try ctx.newTable();
    const class1 = try ctx.newTable();
    const class2 = try ctx.newShapedTable(&shape);
    const class3 = try ctx.newTable();
    receiver.metatable = mt0;
    class1.metatable = mt1;
    class2.metatable = mt2;
    try mt0.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = class1 });
    try mt1.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = class2 });
    try mt2.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = class3 });
    try class3.rawSet(ctx.allocator, .{ .string = "method" }, .{ .number = 1 });
    const object = Value{ .table = receiver };
    try std.testing.expectEqual(@as(f64, 1), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    const cached = &inherited_site_cache[inheritedSiteIndex(site)];
    try std.testing.expectEqual(site, cached.site_id);
    try std.testing.expectEqual(@as(u8, 3), cached.count);
    try std.testing.expectEqual(@as(f64, 1), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    // Existing-key replacement does not bump the map epoch; cached Values stay live.
    try class3.rawSet(ctx.allocator, .{ .string = "method" }, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    try receiver.rawSetSlot(0, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    try receiver.rawSetSlot(0, .nil);
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    try class2.rawSetSlot(0, .{ .number = 8 });
    try std.testing.expectEqual(@as(f64, 8), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    try class2.rawSetSlot(0, .nil);
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    var deep_calls: usize = 0;
    const DeepProbe = struct {
        fn call(raw: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
            return &.{};
        }
    };
    try mt2.rawSet(ctx.allocator, .{ .string = "__index" }, try ctx.newNative(&deep_calls, DeepProbe.call));
    try std.testing.expect((try ctx.getFieldAtSite(object, "method", hash, site)) == .nil);
    try std.testing.expect((try ctx.getFieldAtSite(object, "method", hash, site)) == .nil);
    try std.testing.expectEqual(@as(usize, 2), deep_calls);
    try mt2.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = class3 });
    // An already retained mutable location can change without an epoch bump.
    // A nil cell must expose the inherited value, then revival must shadow it.
    try class1.rawSet(ctx.allocator, .{ .string = "method" }, .{ .number = 4 });
    const mutable_method = class1.map.getPtrContext(.{ .string = "method" }, .{}).?;
    const mutable_epoch = class1.field_cache_epoch;
    mutable_method.* = .nil;
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    mutable_method.* = .{ .number = 5 };
    try std.testing.expectEqual(mutable_epoch, class1.field_cache_epoch);
    try std.testing.expectEqual(@as(f64, 5), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    // Restoring absence allows the same path to fill again.
    try class1.rawSet(ctx.allocator, .{ .string = "method" }, .nil);
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    const replacement = try ctx.newTable();
    try replacement.rawSet(ctx.allocator, .{ .string = "method" }, .{ .number = 6 });
    try mt1.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = replacement });
    try std.testing.expectEqual(@as(f64, 6), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    class1.metatable = mt2;
    try std.testing.expectEqual(@as(f64, 2), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    const other_mt = try ctx.newTable();
    try other_mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = replacement });
    receiver.metatable = other_mt;
    try std.testing.expectEqual(@as(f64, 6), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
    try class3.rawSet(ctx.allocator, .{ .string = "method" }, .nil);
    const fourth = try ctx.newTable();
    try fourth.rawSet(ctx.allocator, .{ .string = "method" }, .{ .number = 7 });
    const mt3 = try ctx.newTable();
    try mt3.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = fourth });
    class3.metatable = mt3;
    // A cycle exists beyond the terminal field; bounded tracing must use the
    // ordinary lookup after three links and stop at the positive field.
    const cycle_mt = try ctx.newTable();
    fourth.metatable = cycle_mt;
    try cycle_mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = class1 });
    receiver.metatable = mt0;
    class1.metatable = mt1;
    try mt1.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = class2 });
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getFieldAtSite(object, "method", hash, site)).number);
}

test "bounded inherited site cache keeps callable indexers live and context-local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first = try Context.init(arena.allocator(), 0);
    defer first.deinit();
    const site: u64 = (@as(u64, 21434) << 32) | 0;
    const hash = comptime static_fields.hashStringKey("method");
    const receiver = try first.newTable();
    const mt = try first.newTable();
    const parent = try first.newTable();
    receiver.metatable = mt;
    try mt.rawSet(first.allocator, .{ .string = "__index" }, .{ .table = parent });
    try parent.rawSet(first.allocator, .{ .string = "method" }, .{ .number = 10 });
    try std.testing.expectEqual(@as(f64, 10), (try first.getFieldAtSite(.{ .table = receiver }, "method", hash, site)).number);
    try std.testing.expectEqual(@as(u8, 1), inherited_site_cache[inheritedSiteIndex(site)].count);
    var calls: usize = 0;
    const Probe = struct {
        fn call(raw: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
            return &.{};
        }
    };
    try mt.rawSet(first.allocator, .{ .string = "__index" }, try first.newNative(&calls, Probe.call));
    try std.testing.expect((try first.getFieldAtSite(.{ .table = receiver }, "method", hash, site)) == .nil);
    try std.testing.expect((try first.getFieldAtSite(.{ .table = receiver }, "method", hash, site)) == .nil);
    try std.testing.expectEqual(@as(usize, 2), calls);
    var second = try Context.init(arena.allocator(), 0);
    defer second.deinit();
    const other = try second.newTable();
    const other_mt = try second.newTable();
    const other_parent = try second.newTable();
    other.metatable = other_mt;
    try other_mt.rawSet(second.allocator, .{ .string = "__index" }, .{ .table = other_parent });
    try other_parent.rawSet(second.allocator, .{ .string = "method" }, .{ .number = 11 });
    try std.testing.expect(first.field_cache_nonce != second.field_cache_nonce);
    try std.testing.expectEqual(@as(f64, 11), (try second.getFieldAtSite(.{ .table = other }, "method", hash, site)).number);
}

test "invoke-local strings and captured callables release with the invoke arena" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    {
        var invoke_arena = LocalBumpArena.init(request.allocator());
        defer invoke_arena.deinit();
        var child = try Context.init(invoke_arena.allocator(), 0);
        defer child.deinit();
        child.useContextAllocatorForStrings();

        var cell = Cell{ .value = .{ .number = 3 } };
        const captured = try child.makeFunction(7, stabilizeBuffered(bufferedResultProbe), &.{&cell});
        try std.testing.expect(captured.callable.capturesPtr().?.direct[0] == &cell);
        const plain = try child.makeFunction(8, stabilizeBuffered(bufferedResultProbe), &.{});
        try std.testing.expect(plain.callable.capturesPtr() == null);
        const joined = try child.concatValues(&.{ .{ .string = "left" }, .{ .string = "right" } });
        try std.testing.expectEqualStrings("leftright", joined.string);
        try std.testing.expect(request.live_count > 0);
    }
    try std.testing.expectEqual(@as(usize, 0), request.live_count);
}

test "invoke-local owned strings and errors survive explicit parent copies" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    var parent = try Context.init(request.allocator(), 0);
    defer parent.deinit();
    const before = request.live_count;
    var output: []const u8 = undefined;
    {
        var invoke_arena = LocalBumpArena.init(request.allocator());
        defer invoke_arena.deinit();
        var child = try parent.forkProgram(invoke_arena.allocator());
        defer child.deinit();
        child.useContextAllocatorForStrings();
        const result = try child.concatValues(&.{ .{ .string = "owned-" }, .{ .string = "output" } });
        output = try request.allocator().dupe(u8, result.string);
        child.last_error = try child.concatValues(&.{ .{ .string = "owned-" }, .{ .string = "failure" } });
        child.last_error_present = true;
        child.setAotErrorName("LuaRaised");
        try parent.adoptFailure(&child);
    }
    // Only the two explicit parent copies remain after child bulk reclamation.
    try std.testing.expectEqual(before + 2, request.live_count);
    const churn = try request.allocator().alloc(u8, 64 * 1024);
    @memset(churn, 0xaa);
    try std.testing.expectEqualStrings("owned-output", output);
    try std.testing.expectEqualStrings("owned-failure", parent.last_error.string);
    try std.testing.expect(parent.last_error_present);
    try std.testing.expectEqualStrings("LuaRaised", parent.aotErrorName().?);
}

test "program shape leaf ignores identity exhaustion but preserves semantic guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "x" }};
    const sorted = [_]u32{0};
    const shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .all_string_keys = true }};
    ctx.program_shapes = &shapes;
    ctx.program_shape_generation = 991;
    const cache = try arena.allocator().create([field_cache_entries]ShapeSiteCache);
    cache.* = @as([field_cache_entries]ShapeSiteCache, @splat(.{}));
    const site: u64 = 0x81234567;
    const entry = &cache[fieldCacheIndex(site)];
    entry.* = .{ .site_id = site, .program_generation = 991, .shape_id = 0, .slot = 0 };
    const table = try ctx.newProgramShape(0);
    try table.rawSetSlot(0, .{ .number = 7 });
    const object = Value{ .table = table };
    const saved_entry = entry.*;
    const original_slots = table.slots;
    ctx.field_cache_nonce = 0;
    table.field_cache_nonce = 0;
    table.field_cache_owner_nonce = 0;
    table.field_cache_epoch = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(f64, 7), (positiveProgramShapeHit(&ctx, &object, site, cache) orelse return error.MissingNonceFreeShapeHit).number);
    // Always read the current allocation; no stale cached Value pointer exists.
    table.slots = try ctx.allocator.alloc(Value, 1);
    table.slots[0] = .{ .number = 8 };
    try std.testing.expectEqual(@as(f64, 8), (positiveProgramShapeHit(&ctx, &object, site, cache) orelse return error.MissingRelocatedSlotHit).number);
    table.slots = original_slots;
    var child = try ctx.forkProgram(arena.allocator());
    defer child.deinit();
    const other = try child.newProgramShape(0);
    try other.rawSetSlot(0, .{ .number = 9 });
    try std.testing.expectEqual(@as(f64, 9), (positiveProgramShapeHit(&child, &.{ .table = other }, site, cache) orelse return error.MissingChildShapeHit).number);

    entry.site_id +%= 1;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    entry.* = saved_entry;
    entry.program_generation += 1;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    entry.* = saved_entry;
    entry.shape_id = 1;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    entry.* = saved_entry;
    entry.slot = 1;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    entry.* = saved_entry;
    ctx.program_shape_generation = 0;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    ctx.program_shape_generation = 991;

    table.native_namespace = @fromBackingInt(@intCast(0));
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    table.native_namespace = null;
    table.owns_slots = false;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    table.owns_slots = true;
    var tail: GlobalTail = undefined; // Guard must reject without dereferencing it.
    table.global_tail = &tail;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    table.global_tail = null;
    var choice = [_]ChoiceCell{.{}};
    table.choices = &choice;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    table.choices = &.{};
    table.slots[0] = .nil;
    try std.testing.expect(positiveProgramShapeHit(&ctx, &object, site, cache) == null);
    try std.testing.expect(positiveProgramShapeHit(&ctx, &.{ .number = 1 }, site, cache) == null);
}

test "shape site caches nil and absent slots but reads live map and inherited values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{.{ .string = "optional" }};
    const sorted = [_]u32{0};
    const shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = 1, .open = true, .all_string_keys = true }};
    ctx.program_shapes = &shapes;
    ctx.program_shape_generation = 1707;
    const first = try ctx.newProgramShape(0);
    const second = try ctx.newProgramShape(0);
    const slot_site: u64 = (@as(u64, 1707) << 32) | 44;
    const absent_site: u64 = (@as(u64, 1707) << 32) | 45;
    const optional_hash = stringValueHash("optional");
    const absent_hash = stringValueHash("extra");
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = first }, "optional", optional_hash, slot_site)) == .nil);
    try std.testing.expectEqual(@as(u32, 0), FieldCacheStorage.dict_lua_shape_site_cache[fieldCacheIndex(slot_site)].slot);
    try second.rawSetSlot(0, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getFieldAtSite(.{ .table = second }, "optional", optional_hash, slot_site)).number);
    try std.testing.expectEqual(@as(f64, 7), (positiveProgramShapeHit(&ctx, &.{ .table = second }, slot_site, &FieldCacheStorage.dict_lua_shape_site_cache) orelse return error.MissingComposedShapeHit).number);
    try second.rawSetSlot(0, .nil);
    const inherited = try ctx.newTable();
    try inherited.rawSet(ctx.allocator, .{ .string = "optional" }, .{ .number = 9 });
    const mt = try ctx.newTable();
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = inherited });
    second.metatable = mt;
    try std.testing.expectEqual(@as(f64, 9), (try ctx.getFieldAtSite(.{ .table = second }, "optional", optional_hash, slot_site)).number);
    try inherited.rawSet(ctx.allocator, .{ .string = "optional" }, .{ .number = 11 });
    try std.testing.expectEqual(@as(f64, 11), (try ctx.getFieldAtSite(.{ .table = second }, "optional", optional_hash, slot_site)).number);
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = first }, "extra", absent_hash, absent_site)) == .nil);
    try std.testing.expectEqual(std.math.maxInt(u32), FieldCacheStorage.dict_lua_shape_site_cache[fieldCacheIndex(absent_site)].slot);
    try std.testing.expect(positiveProgramShapeHit(&ctx, &.{ .table = first }, absent_site, &FieldCacheStorage.dict_lua_shape_site_cache) == null);
    try second.rawSet(ctx.allocator, .{ .string = "extra" }, .{ .boolean = false });
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = second }, "extra", absent_hash, absent_site)) == .boolean);
    try std.testing.expect(!(try ctx.getFieldAtSite(.{ .table = second }, "extra", absent_hash, absent_site)).boolean);
    try second.rawSet(ctx.allocator, .{ .string = "extra" }, .nil);
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = second }, "extra", absent_hash, absent_site)) == .nil);
    try inherited.rawSet(ctx.allocator, .{ .string = "extra" }, .{ .number = 99 });
    try second.rawSet(ctx.allocator, .{ .string = "extra" }, .{ .number = 5 });
    try std.testing.expectEqual(@as(f64, 5), (try ctx.getFieldAtSite(.{ .table = second }, "extra", absent_hash, absent_site)).number);
    second.metatable = null;
    var iterator = second.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.* == .string and std.mem.eql(u8, entry.key_ptr.string, "extra")) {
            entry.value_ptr.* = .nil;
            break;
        }
    }
    // Preserve live nil-map observation without changing inherited dispatch.
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = second }, "extra", absent_hash, absent_site)) == .nil);
    ctx.program_shape_generation += 1;
    try std.testing.expect((try ctx.getFieldAtSite(.{ .table = first }, "optional", optional_hash, slot_site)) == .nil);
    try std.testing.expectEqual(ctx.program_shape_generation, FieldCacheStorage.dict_lua_shape_site_cache[fieldCacheIndex(slot_site)].program_generation);
}

test "immutable string slot indices preserve mixed duplicate and missing field semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    const keys = [_]Value{ .{ .string = "z" }, .{ .number = 2 }, .{ .string = "" }, .{ .boolean = false }, .{ .string = "a" }, .{ .string = "z" }, .{ .string = "é" }, .{ .number = 1 } };
    const sorted = [_]u32{ 4, 0 };
    var shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .sorted_string_slots = &sorted, .field_count = keys.len, .open = true }};
    const index = try buildShapeStringIndices(std.testing.allocator, &shapes);
    defer std.testing.allocator.free(index);
    const table = try ctx.newShapedTable(&shapes[0]);
    for (keys, 0..) |key, i| {
        const expected: u32 = blk: {
            for (keys, 0..) |candidate, slot| if (rawEqual(candidate, key)) break :blk @intCast(slot);
            unreachable;
        };
        try std.testing.expectEqual(expected, table.slotForKey(key).?);
        try table.rawSet(a, key, .{ .number = @floatFromInt(i + 10) });
    }
    try std.testing.expectEqual(@as(f64, 15), table.rawGetHashedString("z", stringValueHash("z")).?.number);
    try std.testing.expect(table.slots[5] == .nil);
    for ([_][]const u8{ "missing", "other", "\xff", "1" }) |missing| {
        try std.testing.expect(table.slotForKey(.{ .string = missing }) == null);
        try std.testing.expect(table.rawGetHashedString(missing, stringValueHash(missing)) == null);
    }
    try table.rawSetHashedString(a, "extra", stringValueHash("extra"), .{ .number = 37 });
    const inherited = try ctx.newTable();
    try inherited.rawSet(a, .{ .string = "a" }, .{ .number = 72 });
    const mt = try ctx.newTable();
    try mt.rawSet(a, .{ .string = "__index" }, .{ .table = inherited });
    table.metatable = mt;
    var rollback = InvokeRollbackJournal.init(a, &ctx);
    rollback.begin();
    try table.rawSetHashedString(a, "a", stringValueHash("a"), .nil);
    try std.testing.expectEqual(@as(f64, 72), (try ctx.getStructuralFieldAtSite(.{ .table = table }, "a", stringValueHash("a"), 123)).number);
    try table.rawSetHashedString(a, "extra", stringValueHash("extra"), .{ .number = 91 });
    rollback.rollback(&ctx);
    try std.testing.expectEqual(@as(f64, 14), table.rawGetHashedString("a", stringValueHash("a")).?.number);
    try std.testing.expectEqual(@as(f64, 37), table.rawGetHashedString("extra", stringValueHash("extra")).?.number);
}

test "immutable string indices match the first-slot oracle through collisions and empty layouts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    for (0..130) |size| {
        const keys = try a.alloc(Value, size);
        for (keys, 0..) |*key, i| key.* = if (i % 5 == 0)
            .{ .number = @floatFromInt(i) }
        else
            .{ .string = try std.fmt.allocPrint(a, "field-{d}", .{i % 29}) };
        var shapes = [_]Shape{.{ .keys = .{ .boxed = keys }, .field_count = @intCast(size), .open = true }};
        const index = try buildShapeStringIndices(a, &shapes);
        defer a.free(index);
        const table = try ctx.newShapedTable(&shapes[0]);
        for (0..40) |number| {
            const text = try std.fmt.allocPrint(a, "field-{d}", .{number});
            const query = Value{ .string = text };
            const expected: ?u32 = blk: {
                for (keys, 0..) |key, slot| if (rawEqual(query, key)) break :blk @intCast(slot);
                break :blk null;
            };
            try std.testing.expectEqual(expected, table.slotForKey(query));
            try std.testing.expectEqual(expected, table.slotForString(text, stringValueHash(text)));
        }
    }
}

test "immutable string index validation rejects missing full and invalid layouts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{ .{ .string = "item" }, .{ .number = 1 }, .{ .string = "item" } };
    var shape = Shape{ .keys = .{ .boxed = &keys }, .field_count = keys.len };
    for ([_][]const u32{ &.{ 0, 0 }, &.{ 1, 1 }, &.{ 99, 0 }, &.{ 2, 0 }, &.{ 1, 0, 0 }, &.{ 3, 0 } }) |index| {
        shape.string_lookup_slots = index;
        try std.testing.expectError(error.BadShape, ctx.newShapedTable(&shape));
    }
}

test "immutable string index construction is allocation-failure atomic" {
    const Probe = struct {
        fn run(a: std.mem.Allocator) !void {
            const keys = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
            var shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .field_count = keys.len }};
            const index = buildShapeStringIndices(a, &shapes) catch |err| {
                try std.testing.expectEqual(@as(usize, 0), shapes[0].string_lookup_slots.len);
                return err;
            };
            defer a.free(index);
            try std.testing.expectEqual(@as(u32, 0), indexedShapeStringSlot(&shapes[0], "a", stringValueHash("a")).?);
            try std.testing.expectError(error.BadShape, buildShapeStringIndices(a, &shapes));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "failed static module metadata entry preserves shared globals and depth before recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.initProgram(a, 2, 1);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, null, 0);
    try ctx.setGlobal(1, .{ .number = 17 });
    const caller = try ctx.enterModule(0);
    try ctx.setGlobal(1, .{ .number = 43 });
    ctx.restoreModule(caller);
    ctx.depth = 7;
    var failed = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    ctx.allocator = failed.allocator();
    const entered = ctx.enterStaticModule(0);
    ctx.allocator = a;
    try std.testing.expectError(error.OutOfMemory, entered);
    try std.testing.expectEqual(@as(usize, 7), ctx.depth);
    try std.testing.expectEqual(@as(usize, 0), ctx.static_module_scopes.items.len);
    try std.testing.expectEqual(caller.module_id, ctx.active_module_id);
    try std.testing.expect(ctx.globals.ptr == ctx.root_globals.ptr);
    try std.testing.expect(ctx.global_table == ctx.root_global_table);
    try std.testing.expectEqual(@as(f64, 43), ctx.getGlobal(1).number);
    try ctx.enterStaticModule(0);
    try std.testing.expectEqual(@as(f64, 43), ctx.getGlobal(1).number);
    ctx.leaveStaticFunction();
    try std.testing.expectEqual(caller.module_id, ctx.active_module_id);
    try std.testing.expectEqual(@as(f64, 43), ctx.getGlobal(1).number);
    try std.testing.expectEqual(@as(usize, 7), ctx.depth);
}

test "generic arrays reject progressive sparse numeric densification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const table = try ctx.newTable();

    for (1..102) |i|
        try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, .{ .number = @floatFromInt(i) });
    try std.testing.expectEqual(@as(usize, 128), table.slots.len);

    var value: usize = 200;
    while (value <= 900) : (value += 100)
        try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(value) }, .{ .number = @floatFromInt(value) });
    value = 1000;
    while (value <= 9000) : (value += 1000)
        try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(value) }, .{ .number = @floatFromInt(value) });
    value = 10_000;
    while (value <= 90_000) : (value += 10_000)
        try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(value) }, .{ .number = @floatFromInt(value) });
    value = 100_000;
    while (value <= 900_000) : (value += 100_000)
        try table.rawSet(ctx.allocator, .{ .number = @floatFromInt(value) }, .{ .number = @floatFromInt(value) });
    try table.rawSet(ctx.allocator, .{ .number = 1_000_000 }, .{ .number = 1_000_000 });
    try table.rawSet(ctx.allocator, .{ .number = 2_000_000 }, .{ .number = 2_000_000 });

    try std.testing.expectEqual(@as(usize, 128), table.slots.len);
    try std.testing.expectEqual(@as(f64, 2_000_000), table.rawGetNumber(2_000_000).?.number);
    try std.testing.expectEqual(@as(f64, 900_000), table.rawGet(.{ .number = 900_000 }).?.number);
    try std.testing.expect(table.map.getContext(.{ .number = 2_000_000 }, .{}) != null);
}

test "template root errors cross cold and warm context boundaries without stale diagnostics" {
    const Probe = struct {
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.NotImplemented;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Context.initProgram(arena.allocator(), 0, 1);
    defer source.deinit();
    const roots = [_]FunctionFn{stabilize(Probe.root)};
    source.module_root_entries = &roots;
    source.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    source.setAotErrorName("prior source diagnostic");
    source.setLuaError(.{ .string = "prior source payload" });
    var eligible = [_]bool{true};
    for (0..3) |_| {
        var child = try source.forkProgram(arena.allocator());
        defer child.deinit();
        child.module_template_context = &source;
        child.module_template_eligible = &eligible;
        try std.testing.expectError(error.AotCallFailed, child.requireByName("Module:TemplateProbe"));
        try std.testing.expectEqualStrings("NotImplemented", child.aotErrorName() orelse "missing");
        try std.testing.expect(!child.last_error_present and child.last_error == .nil);
        try std.testing.expectEqualStrings("prior source diagnostic", source.aotErrorName().?);
        try std.testing.expectEqualStrings("prior source payload", source.last_error.string);
        try std.testing.expect(source.last_error_present);
    }
}

test "template root error nil remains present across a context boundary" {
    const Probe = struct {
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            ctx.setLuaError(.nil);
            return error.RaisedError;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Context.initProgram(arena.allocator(), 0, 1);
    defer source.deinit();
    const roots = [_]FunctionFn{stabilize(Probe.root)};
    source.module_root_entries = &roots;
    source.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    var eligible = [_]bool{true};
    for (0..2) |_| {
        var child = try source.forkProgram(arena.allocator());
        defer child.deinit();
        child.module_template_context = &source;
        child.module_template_eligible = &eligible;
        try std.testing.expectError(error.AotCallFailed, child.requireByName("Module:TemplateProbe"));
        try std.testing.expect(child.last_error_present and child.last_error == .nil);
        try std.testing.expectEqualStrings("RaisedError", child.aotErrorName() orelse "missing");
        try std.testing.expect(!source.last_error_present and source.aotErrorName() == null);
    }
}

test "promotion preserves canonical native callable aliases without merging private functions" {
    const Native = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Context.init(arena.allocator(), 1);
    defer source.deinit();
    var target = try Context.init(arena.allocator(), 1);
    defer target.deinit();
    const source_title = try source.newNativeNamespace(.title);
    const target_title = try target.newNativeNamespace(.title);
    const source_eq = try source.newNative(null, Native.call);
    const target_eq = try target.newNative(null, Native.call);
    try source_title.rawSetNativeField(.title, "equals", source_eq);
    try target_title.rawSetNativeField(.title, "equals", target_eq);
    try source.setGlobal(0, .{ .table = source_title });
    try target.setGlobal(0, .{ .table = target_title });
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target, .promotion = true };
    defer clone.deinit();
    const canonical = try clone.cloneValue(source_eq);
    try std.testing.expect(canonical.callable == target_eq.callable);
    try std.testing.expect(rawEqual(canonical, target_eq));
    const private = try source.newNative(null, Native.call);
    const owned = try clone.cloneValue(private);
    try std.testing.expect(owned.callable != private.callable);
    try std.testing.expect(!rawEqual(owned, target_eq));
    try std.testing.expect(rawEqual(owned, try clone.cloneValue(private)));
    var missing = try Context.init(arena.allocator(), 1);
    defer missing.deinit();
    var no_namespace = Context.ModuleTemplateClone{ .source = &source, .target = &missing, .promotion = true };
    defer no_namespace.deinit();
    try std.testing.expectError(error.UnsupportedModuleTemplate, no_namespace.cloneValue(source_eq));
}

test "cloned native type metatables retain private method identity in the target context" {
    const Native = struct {
        fn less(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
        fn replacement(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return error.NotImplemented;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var target = try Context.init(a, 0);
    defer target.deinit();
    const source_mt = try source.newTable();
    const target_mt = try target.newTable();
    const source_lt = try source.newNative(null, Native.less);
    _ = try target.newNative(null, Native.less);
    const target_lt = try target.newNative(null, Native.less);
    try source_mt.rawSet(a, .{ .string = "__lt" }, source_lt);
    try target_mt.rawSet(a, .{ .string = "__lt" }, target_lt);
    source.registerNativeMetatable(.title_value, source_mt);
    target.registerNativeMetatable(.title_value, target_mt);

    for ([_]bool{ false, true }) |promotion| {
        var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target, .promotion = promotion };
        defer clone.deinit();
        const lt = try clone.cloneValue(source_lt);
        try std.testing.expect(lt.callable == target_lt.callable);
        try std.testing.expect(rawEqual(lt, target_mt.rawGet(.{ .string = "__lt" }).?));
        const mt = try clone.cloneValue(.{ .table = source_mt });
        try std.testing.expect(mt.table == target_mt);
        const private = try source.newNative(null, Native.less);
        const copied = try clone.cloneValue(private);
        try std.testing.expect(copied.callable != target_lt.callable);
        try std.testing.expect(!rawEqual(copied, target_lt));
        try std.testing.expect(rawEqual(copied, try clone.cloneValue(private)));
    }

    var missing = try Context.init(a, 0);
    defer missing.deinit();
    var absent = Context.ModuleTemplateClone{ .source = &source, .target = &missing, .promotion = true };
    defer absent.deinit();
    try std.testing.expectError(error.UnsupportedModuleTemplate, absent.cloneValue(source_lt));
    try std.testing.expectError(error.UnsupportedModuleTemplate, absent.cloneValue(.{ .table = source_mt }));
    try target_mt.rawSet(a, .{ .string = "__lt" }, try target.newNative(null, Native.replacement));
    var changed = Context.ModuleTemplateClone{ .source = &source, .target = &target, .promotion = true };
    defer changed.deinit();
    try std.testing.expectError(error.UnsupportedModuleTemplate, changed.cloneValue(source_lt));
}

test "registered native metatables cannot become private module mutation state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    // A nested context can bootstrap while an outer module's allocation
    // probe is active. Registration must cut this foreign lifetime edge.
    var foreign_marker: u64 = 0;
    const old_allocation_probe = module_template_allocation_mutation_probe;
    module_template_allocation_mutation_probe = &foreign_marker;
    const mt = ctx.newTable() catch |err| {
        module_template_allocation_mutation_probe = old_allocation_probe;
        return err;
    };
    module_template_allocation_mutation_probe = old_allocation_probe;
    try std.testing.expect(mt.module_template_mutation_probe == &foreign_marker);
    ctx.registerNativeMetatable(.title_value, mt);
    try std.testing.expect(mt.module_template_mutation_probe == null);
    const wrapper = try ctx.newTable();
    try wrapper.rawSet(a, .{ .string = "type" }, .{ .table = mt });
    var marker: u64 = 0;
    try ctx.tagModuleTemplateValue(.{ .table = wrapper }, &marker);
    try std.testing.expect(wrapper.module_template_mutation_probe == &marker);
    try std.testing.expect(mt.module_template_mutation_probe == null);
    // Exporting the canonical object can install an export sentinel. That
    // sentinel must not turn later global type mutations into private effects.
    mt.prepareExportGuard();
    var effect = false;
    const previous = beginModuleTemplateEffectProbe(&effect, true);
    defer endModuleTemplateEffectProbe(previous, effect);
    try mt.rawSet(a, .{ .string = "__custom" }, .{ .boolean = true });
    try std.testing.expect(effect);
    try std.testing.expect(!mt.export_pristine);
}

test "invoke rollback restores identity key metadata before the first insertion" {
    const Native = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return &.{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    const table = try ctx.newTable();
    try table.rawSet(a, .{ .string = "kept" }, .{ .number = 7 });
    const keys = [_]Value{ .{ .table = try ctx.newTable() }, try ctx.newNative(null, Native.call) };
    for (keys) |key| {
        try std.testing.expect(!table.has_identity_key);
        var journal = InvokeRollbackJournal.init(a, &ctx);
        journal.begin();
        try table.rawSet(a, key, .{ .number = 42 });
        try std.testing.expect(table.has_identity_key);
        journal.rollback(&ctx);
        try std.testing.expect(!table.has_identity_key);
        try std.testing.expect(table.rawGet(key) == null);
        try std.testing.expectEqual(@as(f64, 7), table.rawGet(.{ .string = "kept" }).?.number);
    }
}

test "cloned dependency graphs keep their original mutation owner through aliases" {
    const Probe = struct {
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.TestUnexpectedResult;
        }
        fn requirements(_: ?*const anyopaque, id: u32) []const ModuleRequirement {
            return if (id == 1) &.{.{ .module_id = 0, .requested = "Module:Dep" }} else &.{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.initProgram(a, 0, 2);
    defer source.deinit();
    const roots: [2]FunctionFn = @splat(stabilize(Probe.root));
    source.module_root_entries = &roots;
    source.configureModuleRequirements(null, Probe.requirements);
    const nested = try source.newTable();
    try nested.rawSet(a, .{ .string = "value" }, .{ .number = 1 });
    const dependency = try source.newTable();
    try dependency.rawSet(a, .{ .string = "nested" }, .{ .table = nested });
    const alias = try source.newTable();
    try alias.rawSet(a, .{ .string = "dependency" }, .{ .table = dependency });
    try source.preinitializeModule(0, .{ .table = dependency }, false);
    try source.preinitializeModule(1, .{ .table = alias }, false);
    var child = try source.forkProgram(a);
    defer child.deinit();
    var eligible = [_]bool{ true, true };
    child.module_template_context = &source;
    child.module_template_eligible = &eligible;
    const first = try child.loadModule(0, "Module:Dep");
    const second = try child.loadModule(1, "Module:Alias");
    try std.testing.expect(rawEqual(first, second.table.rawGet(.{ .string = "dependency" }).?));
    const cloned_nested = first.table.rawGet(.{ .string = "nested" }).?.table;
    const owner = &child.moduleState(0).?.template_mutation_probe_id;
    try std.testing.expect(cloned_nested.module_template_mutation_probe == owner);
    var observed = false;
    const probe = beginModuleTemplateEffectProbe(&observed, true);
    defer endModuleTemplateEffectProbe(probe, observed);
    try cloned_nested.rawSet(a, .{ .string = "value" }, .{ .number = 2 });
    const mutations = try child.moduleTemplateProbeModules(a, module_template_probe_id, 1);
    defer a.free(mutations);
    try std.testing.expectEqualSlices(u32, &.{0}, mutations);
    try std.testing.expectEqual(@as(f64, 1), nested.rawGet(.{ .string = "value" }).?.number);
}

test "template override cycles retain each source module mutation owner" {
    const Probe = struct {
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.TestUnexpectedResult;
        }
        fn requirements(_: ?*const anyopaque, id: u32) []const ModuleRequirement {
            return if (id == 1) &.{.{ .module_id = 0, .requested = "Module:Dep" }} else &.{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.initProgram(a, 0, 2);
    defer source.deinit();
    const roots: [2]FunctionFn = @splat(stabilize(Probe.root));
    source.module_root_entries = &roots;
    source.configureModuleRequirements(null, Probe.requirements);
    const dependency = try source.newTable();
    const dependency_owner = try source.ensureModuleState(0);
    try source.tagModuleTemplateValue(.{ .table = dependency }, &dependency_owner.template_mutation_probe_id);
    const alias = try source.newTable();
    try alias.rawSet(a, .{ .string = "dependency" }, .{ .table = dependency });
    const alias_owner = try source.ensureModuleState(1);
    try source.tagModuleTemplateValue(.{ .table = alias }, &alias_owner.template_mutation_probe_id);
    try dependency.rawSet(a, .{ .string = "back" }, .{ .table = alias });
    // Production promotion clones the complete graph before sealing exports.
    try source.preinitializeModule(0, .{ .table = dependency }, false);
    try source.preinitializeModule(1, .{ .table = alias }, false);
    const overrides = [_]ModuleTemplateOverride{.{ .module_id = 0, .value = .{ .table = dependency } }};
    source.moduleState(1).?.template_overrides = &overrides;
    try std.testing.expect(dependency.module_template_mutation_probe == &source.moduleState(0).?.template_mutation_probe_id);
    try std.testing.expect(alias.module_template_mutation_probe == &source.moduleState(1).?.template_mutation_probe_id);

    var child = try source.forkProgram(a);
    defer child.deinit();
    var eligible = [_]bool{ true, true };
    child.module_template_context = &source;
    child.module_template_eligible = &eligible;
    const copied_alias = (try child.loadModule(1, "Module:Alias")).table;
    const copied_dep = copied_alias.rawGet(.{ .string = "dependency" }).?.table;
    try std.testing.expect(copied_dep == (try child.loadModule(0, "Module:Dep")).table);
    try std.testing.expect(copied_alias == copied_dep.rawGet(.{ .string = "back" }).?.table);
    try std.testing.expect(copied_dep.module_template_mutation_probe == &child.moduleState(0).?.template_mutation_probe_id);
    try std.testing.expect(copied_alias.module_template_mutation_probe == &child.moduleState(1).?.template_mutation_probe_id);
    var observed = false;
    const probe = beginModuleTemplateEffectProbe(&observed, true);
    defer endModuleTemplateEffectProbe(probe, observed);
    try copied_dep.rawSet(a, .{ .string = "changed" }, .{ .boolean = true });
    const mutations = try child.moduleTemplateProbeModules(a, module_template_probe_id, 1);
    defer a.free(mutations);
    try std.testing.expectEqualSlices(u32, &.{0}, mutations);
    try std.testing.expect(dependency.rawGet(.{ .string = "changed" }) == null);
}

test "metamethods propagate one or zero result demand without losing effects or errors" {
    const Probe = struct {
        calls: usize = 0,
        demand: usize = 99,
        fail: bool = false,
        empty: bool = false,
        fn call(raw: ?*anyopaque, _: *Context, _: []const Value, buffer: ?[]Value) ![]const Value {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.demand = if (buffer) |values| values.len else 99;
            if (self.fail) return error.MetamethodProbeFailure;
            if (self.empty) return &.{};
            const out = try returnBuffer(buffer, 3);
            storeReturn(out, 0, .{ .number = 7 });
            storeReturn(out, 1, .{ .boolean = false });
            storeReturn(out, 2, .{ .string = "unused tail" });
            return out;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    var probe: Probe = .{};
    const callable = try ctx.newNativeBuffered(&probe, Probe.call);
    const table = try ctx.newTable();
    const other = try ctx.newTable();
    const mt = try ctx.newTable();
    table.metatable = mt;
    other.metatable = mt;
    for ([_][]const u8{ "__index", "__newindex", "__add", "__eq", "__lt" }) |name|
        try mt.rawSet(ctx.allocator, .{ .string = name }, callable);
    const object = Value{ .table = table };
    const rhs = Value{ .table = other };
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getIndex(object, .{ .string = "missing" })).number);
    try std.testing.expectEqual(@as(usize, 1), probe.demand);
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getHashedField(object, "missing", stringValueHash("missing"))).number);
    try std.testing.expectEqual(@as(usize, 1), probe.demand);
    ctx.string_metatable = mt;
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getIndex(.{ .string = "text" }, .{ .string = "missing" })).number);
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getHashedField(.{ .string = "text" }, "missing", stringValueHash("missing"))).number);
    try std.testing.expectEqual(@as(f64, 7), (try ctx.binaryArith(.add, object, rhs)).number);
    try std.testing.expect(try ctx.comparison(.eq, object, rhs));
    try std.testing.expect(try ctx.comparison(.lt, object, rhs));
    try std.testing.expectEqual(@as(usize, 1), probe.demand);
    try ctx.setIndex(object, .{ .string = "new" }, .{ .number = 8 });
    try std.testing.expectEqual(@as(usize, 0), probe.demand);
    try ctx.setHashedField(object, "new", stringValueHash("new"), .{ .number = 8 });
    try std.testing.expectEqual(@as(usize, 0), probe.demand);
    try std.testing.expectEqual(@as(usize, 9), probe.calls);
    probe.empty = true;
    try std.testing.expect((try ctx.getIndex(object, .{ .string = "missing" })) == .nil);
    try std.testing.expect(!(try ctx.comparison(.eq, object, rhs)));
    probe.fail = true;
    try std.testing.expectError(error.AotCallFailed, ctx.getIndex(object, .{ .string = "missing" }));
    try std.testing.expectEqualStrings("MetamethodProbeFailure", ctx.aotErrorName().?);
    ctx.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, ctx.setIndex(object, .{ .string = "new" }, .nil));
    try std.testing.expectEqual(@as(usize, 0), probe.demand);
    try std.testing.expectEqualStrings("MetamethodProbeFailure", ctx.aotErrorName().?);
}

test "context pools table headers and cells while large table buffers remain reclaimable" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    for (0..4) |_| {
        {
            var ctx = try Context.init(request.allocator(), 0);
            defer ctx.deinit();
            const initial = request.live_count;
            var tables: [512]*Table = undefined;
            var cells: [512]*Cell = undefined;
            for (&tables, &cells, 0..) |*table, *cell, i| {
                table.* = try ctx.newTable();
                cell.* = try ctx.newCell(.{ .number = @floatFromInt(i) });
            }
            // These are 1024 separately addressable objects, not 1024 backing
            // allocator calls. Their addresses and values survive arena growth.
            try std.testing.expect(request.live_count < initial + 32);
            for (tables, cells, 0..) |table, cell, i| {
                try std.testing.expect(table.slots.len == 0 and table.map.count() == 0);
                try std.testing.expectEqual(@as(f64, @floatFromInt(i)), cell.value.number);
            }
            const large = try ctx.newArrayTable(32768);
            try large.rawSet(ctx.allocator, .{ .number = 32768 }, .{ .number = 19 });
            const with_large = request.live_count;
            ctx.destroyTable(large);
            try std.testing.expect(request.live_count < with_large);
            for (tables) |table| ctx.destroyTable(table);
        }
        try std.testing.expectEqual(@as(usize, 0), request.live_count);
    }
}

fn pooledTableAllocationCase(a: std.mem.Allocator) !void {
    var ctx = try Context.init(a, 0);
    defer ctx.deinit();
    const table = try ctx.newTable();
    defer ctx.destroyTable(table);
    try table.rawSet(a, .{ .string = "value" }, .{ .number = 7 });
    const array = try ctx.newArrayTable(17);
    defer ctx.destroyTable(array);
    const fields = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const shape = Shape{ .keys = .{ .boxed = &fields }, .field_count = 2, .choice_count = 3, .open = true };
    const shaped = try ctx.newShapedTable(&shape);
    defer ctx.destroyTable(shaped);
    const native = try ctx.newNativeNamespace(.frame);
    defer ctx.destroyTable(native);
    const cell = try ctx.newCell(.{ .table = table });
    try std.testing.expect(cell.value.table == table);
}

test "pooled table construction releases partial buffers on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pooledTableAllocationCase, .{});
}

test "canonical package slots preserve eager bootstrap dependency admission" {
    const Probe = struct {
        var roots: usize = 0;
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            return if (std.mem.eql(u8, raw_name, "Module:Eager")) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) "Module:Eager" else null;
        }
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            roots += 1;
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .number = 99 };
            return out;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 1);
    defer ctx.deinit();
    const roots = [_]FunctionFn{stabilize(Probe.root)};
    const keys = [_]Value{.{ .string = "Module:Eager" }};
    const sorted = [_]u32{0};
    const shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .field_count = 1, .sorted_string_slots = &sorted, .all_string_keys = true, .open = true }};
    ctx.module_root_entries = &roots;
    ctx.configureModules(null, Probe.lookup, Probe.name);
    ctx.program_shapes = &shapes;
    ctx.program_shapes_validated = true;
    ctx.package_loaded_shape_id = 0;
    ctx.package_loaded_module_slots = &.{0};
    ctx.package_loaded_slot_modules = &.{0};
    ctx.package_loaded = try ctx.newProgramShape(0);
    Probe.roots = 0;
    ctx.beginEagerBootstrap();
    try std.testing.expectError(error.EagerDependencyNotInitialized, ctx.requireByName("Module:Eager"));
    try std.testing.expectEqual(@as(usize, 0), Probe.roots);
    try ctx.preinitializeModule(0, .{ .number = 42 }, false);
    try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName("Module:Eager")).number);
    try std.testing.expect(ctx.moduleState(0).?.preinitialized != null);
    try std.testing.expect(!ctx.moduleState(0).?.deferred_require_visibility);
    // A live package entry wins before module admission, just as on the
    // ordinary name path. Eager mode must not erase that observation.
    try ctx.package_loaded.?.rawSetSlot(0, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), (try ctx.requireByName("Module:Eager")).number);
    try ctx.package_loaded.?.rawSetSlot(0, .nil);
    ctx.endEagerBootstrap();
    try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName("Module:Eager")).number);
    try std.testing.expectEqual(@as(usize, 0), Probe.roots);
}

test "canonical requires reuse resolved package slots without repeating name lookup" {
    const Probe = struct {
        var lookups: u32 = 0;
        var roots: u32 = 0;
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            lookups += 1;
            return if (std.mem.eql(u8, raw_name, "Module:slot-probe") or
                std.mem.eql(u8, raw_name, "Module:slot-probe-alias")) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) {
                0 => "Module:slot-probe",
                1 => "Module:other",
                else => null,
            };
        }
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            roots += 1;
            const result = try std.heap.smp_allocator.alloc(Value, 1);
            result[0] = .{ .number = 42 };
            return result;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]Value{.{ .string = "Module:slot-probe" }};
    const sorted = [_]u32{0};
    const shapes: [2]Shape = @splat(.{ .keys = .{ .boxed = &fields }, .field_count = 1, .sorted_string_slots = &sorted, .all_string_keys = true, .open = true });
    const roots: [2]FunctionFn = @splat(stabilize(Probe.root));
    const slots = [_]u32{ 0, std.math.maxInt(u32) };
    for (0..4) |mode| {
        Probe.lookups = 0;
        Probe.roots = 0;
        var ctx = try Context.initProgram(a, 0, 2);
        defer ctx.deinit();
        ctx.module_root_entries = &roots;
        ctx.configureModules(null, Probe.lookup, Probe.name);
        ctx.program_shapes = &shapes;
        ctx.program_shapes_validated = true;
        ctx.package_loaded_shape_id = 0;
        ctx.package_loaded_module_slots = &slots;
        const inverse = [_]u32{if (mode == 2) std.math.maxInt(u32) else if (mode == 3) 1 else 0};
        ctx.package_loaded_slot_modules = &inverse;
        const loaded = try ctx.newProgramShape(if (mode == 1) 1 else 0);
        ctx.package_loaded = loaded;
        const first = try ctx.requireByName("Module:slot-probe");
        try std.testing.expectEqual(@as(f64, 42), first.number);
        try std.testing.expectEqual(@as(u32, if (mode == 0) 0 else 1), Probe.lookups);
        try std.testing.expectEqual(@as(u32, 1), Probe.roots);
        const second = try ctx.requireByName("Module:slot-probe");
        try std.testing.expect(rawEqual(first, second));
        try std.testing.expectEqual(@as(u32, 1), Probe.roots);

        // Canonical nil slots must still observe exact overflow/choice values.
        try loaded.rawSetSlot(0, .nil);
        try loaded.map.putContext(a, fields[0], .{ .number = 73 }, .{});
        try std.testing.expectEqual(@as(f64, 73), (try ctx.requireByName("Module:slot-probe")).number);
        try std.testing.expectEqual(@as(f64, 73), (try ctx.requireModuleId(0, "Module:slot-probe")).number);
        loaded.choices = try a.alloc(ChoiceCell, 1);
        loaded.choices[0] = .{ .key = fields[0], .value = .{ .number = 81 } };
        try std.testing.expectEqual(@as(f64, 81), (try ctx.requireByName("Module:slot-probe")).number);
        try std.testing.expectEqual(@as(f64, 81), (try ctx.requireModuleId(0, "Module:slot-probe")).number);
        loaded.choices[0].value = .nil;
        try loaded.map.putContext(a, fields[0], .nil, .{});
        // Clearing the public cache reloads once; the restored truthy entry
        // then supplies the direct-ID require without another root call.
        try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName("Module:slot-probe")).number);
        try std.testing.expectEqual(@as(f64, 42), (try ctx.requireModuleId(0, "Module:slot-probe")).number);
        try std.testing.expectEqual(@as(u32, 2), Probe.roots);
        _ = loaded.map.removeContext(fields[0], .{});
        try loaded.rawSet(a, .{ .string = "arbitrary-loaded-key" }, .{ .boolean = false });
        const before_missing = Probe.lookups;
        try std.testing.expectError(error.ModuleNotFound, ctx.requireByName("arbitrary-loaded-key"));
        // The test namespace registry rejects this unqualified name before
        // a normalized lookup; only the initial exact-name lookup occurs.
        try std.testing.expectEqual(before_missing + 1, Probe.lookups);
        try std.testing.expect(!loaded.rawGet(.{ .string = "arbitrary-loaded-key" }).?.boolean);
        try std.testing.expectEqual(@as(u32, 2), Probe.roots);
        const before = Probe.lookups;

        // Redirect spelling keeps its separate package entry and ordinary ID
        // resolution; the inverse covers canonical names only.
        try loaded.rawSetSlot(0, .{ .number = 42 });
        try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName("Module:slot-probe-alias")).number);
        try std.testing.expectEqual(before + 1, Probe.lookups);
        try loaded.rawSet(a, .{ .string = "Module:slot-probe-alias" }, .{ .number = 91 });
        try std.testing.expectEqual(@as(f64, 91), (try ctx.requireByName("Module:slot-probe-alias")).number);
        try std.testing.expectEqual(before + 1, Probe.lookups);
        var child = try ctx.forkProgram(a);
        defer child.deinit();
        try std.testing.expectEqualSlices(u32, &inverse, child.package_loaded_slot_modules);
    }
}

test "invoke rollback restores the shared guard of aliased table exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.initProgram(a, 0, 2);
    defer ctx.deinit();
    const table = try ctx.newTable();
    try table.rawSet(a, .{ .string = "field" }, .{ .number = 7 });
    try ctx.preinitializeModule(0, .{ .table = table }, false);
    try ctx.preinitializeModule(1, .{ .table = table }, false);
    const first = ctx.moduleValueSentinel(0, .{ .table = table }).?;
    const second = ctx.moduleValueSentinel(1, .{ .table = table }).?;
    try std.testing.expect(first == second);
    var journal = InvokeRollbackJournal.init(a, &ctx);
    journal.begin();
    try table.rawSet(a, .{ .string = "field" }, .{ .number = 99 });
    try std.testing.expect(!first.* and !second.*);
    journal.rollback(&ctx);
    try std.testing.expect(first.* and second.*);
    try std.testing.expectEqual(@as(f64, 7), table.rawGet(.{ .string = "field" }).?.number);
}

test "aliased module exports invalidate every retained pristine guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 3);
    defer ctx.deinit();
    const table = try ctx.newTable();
    try table.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 1 });
    try ctx.preinitializeModule(0, .{ .table = table }, false);
    const first = ctx.moduleValueSentinel(0, .{ .table = table }).?;
    try ctx.preinitializeModule(1, .{ .table = table }, false);
    const second = ctx.moduleValueSentinel(1, .{ .table = table }).?;
    try ctx.preinitializeModule(2, .{ .table = table }, false);
    const third = ctx.moduleValueSentinel(2, .{ .table = table }).?;
    try table.rawSet(ctx.allocator, .{ .string = "field" }, .{ .number = 2 });
    try std.testing.expect(!first.*);
    try std.testing.expect(!second.*);
    try std.testing.expect(!third.*);
}

test "publishing another alias never revives a mutated export guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const table = try ctx.newTable();
    try ctx.preinitializeModule(0, .{ .table = table }, false);
    const first = ctx.moduleValueSentinel(0, .{ .table = table }).?;
    try table.rawSet(ctx.allocator, .{ .string = "changed" }, .{ .boolean = true });
    try std.testing.expect(!first.*);
    try ctx.preinitializeModule(1, .{ .table = table }, false);
    try std.testing.expect(!ctx.moduleValueSentinel(1, .{ .table = table }).?.*);
    try std.testing.expect(!first.*);
}

test "module reinitialization cannot revive a previous export guard" {
    const Probe = struct {
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            const result = try std.heap.smp_allocator.alloc(Value, 1);
            errdefer std.heap.smp_allocator.free(result);
            result[0] = try ctx.requireModuleId(1, "Module:Dep");
            return result;
        }
        fn dependency(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.TestUnexpectedResult;
        }
        fn requirements(_: ?*const anyopaque, id: u32) []const ModuleRequirement {
            return if (id == 0) &.{.{ .module_id = 1, .requested = "Module:Dep" }} else &.{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const roots = [_]FunctionFn{ stabilize(Probe.root), stabilize(Probe.dependency) };
    ctx.module_root_entries = &roots;
    ctx.configureModuleRequirements(null, Probe.requirements);
    ctx.package_loaded = try ctx.newTable();
    const previous = try ctx.newTable();
    try ctx.preinitializeModule(1, .{ .table = previous }, false);
    try ctx.preinitializeModule(0, .{ .table = previous }, false);
    const old_guard = ctx.moduleValueSentinel(0, .{ .table = previous }).?;
    const replacement = try ctx.newTable();
    try ctx.package_loaded.?.rawSet(ctx.allocator, .{ .string = "Module:Dep" }, .{ .table = replacement });
    const current = try ctx.loadModule(0, "Module:Parent");
    try std.testing.expect(current.table == replacement);
    try std.testing.expect(!old_guard.*);
    try std.testing.expect(ctx.moduleValueSentinel(0, current).?.*);
}

test "program pattern cache pointer survives descendant forks and invoke reset" {
    const a = std.testing.allocator;
    var parent = try Context.init(a, 0);
    defer parent.deinit();
    var sentinel: usize = 42;
    parent.ustring_pattern_cache = &sentinel;
    var child = try parent.forkProgram(a);
    defer child.deinit();
    var grandchild = try child.forkProgram(a);
    defer grandchild.deinit();
    try std.testing.expectEqual(parent.ustring_pattern_cache, child.ustring_pattern_cache);
    try std.testing.expectEqual(parent.ustring_pattern_cache, grandchild.ustring_pattern_cache);
    grandchild.resetInvokeModuleState();
    try std.testing.expectEqual(parent.ustring_pattern_cache, grandchild.ustring_pattern_cache);
}

test "independent template backing owns promoted graphs without growing asset storage" {
    const Probe = struct {
        fn call(_: *Context, captures: Captures, _: []const Value) ![]const Value {
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = (try captures.cell(0)).value;
            return out;
        }
    };
    var outer_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var template_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var outer = std.heap.ArenaAllocator.init(outer_backing.allocator());
        defer outer.deinit();
        const sentinel = try outer.allocator().dupe(u8, "asset bytes");
        const outer_capacity = outer.queryCapacity();
        var arena = std.heap.ArenaAllocator.init(template_backing.allocator());
        defer arena.deinit();
        var target = try Context.initProgram(arena.allocator(), 0, 0);
        defer target.deinit();
        target.useContextAllocatorForStrings();
        var promoted: Value = undefined;
        {
            var page = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer page.deinit();
            var source = try Context.initProgram(page.allocator(), 0, 0);
            defer source.deinit();
            const root = try source.newTable();
            const payload = try source.allocator.alloc(u8, 512 * 1024);
            @memset(payload, 'q');
            try root.rawSet(source.allocator, .{ .string = "payload" }, .{ .string = payload });
            try root.rawSet(source.allocator, .{ .string = "self" }, .{ .table = root });
            const cell = try source.allocator.create(Cell);
            cell.* = .{ .value = .{ .table = root } };
            try root.rawSet(source.allocator, .{ .string = "get" }, try source.makeFunctionKnown(17, Probe.call, &.{cell}));
            var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target, .promotion = true };
            defer clone.deinit();
            promoted = try clone.cloneValue(.{ .table = root });
        }
        try std.testing.expectEqual(outer_capacity, outer.queryCapacity());
        try std.testing.expectEqualStrings("asset bytes", sentinel);
        try std.testing.expect(arena.queryCapacity() > 512 * 1024);
        try std.testing.expectEqual(@as(usize, 0), target.string_arena.queryCapacity());
        try std.testing.expect(promoted.table.rawGet(.{ .string = "self" }).?.table == promoted.table);
        const payload = promoted.table.rawGet(.{ .string = "payload" }).?.string;
        try std.testing.expectEqual(@as(usize, 512 * 1024), payload.len);
        for (payload) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
        for (0..3) |_| {
            var page = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer page.deinit();
            var child = try target.forkProgram(page.allocator());
            defer child.deinit();
            try std.testing.expect(!child.strings_use_context_allocator);
            var clone = Context.ModuleTemplateClone{ .source = &target, .target = &child };
            defer clone.deinit();
            const copied = try clone.cloneValue(promoted);
            try copied.table.rawSet(child.allocator, .{ .string = "payload" }, .nil);
            try std.testing.expect(promoted.table.rawGet(.{ .string = "payload" }).? == .string);
            const result = try child.callValue(copied.table.rawGet(.{ .string = "get" }).?, &.{});
            defer freeResults(result);
            try std.testing.expect(result[0].table == copied.table);
        }
    }
    try std.testing.expectEqual(outer_backing.allocated_bytes, outer_backing.freed_bytes);
    try std.testing.expectEqual(template_backing.allocated_bytes, template_backing.freed_bytes);
}

test "worker pool participates in runtime ownership qualification" {
    var pool = RequestPool.init(std.testing.allocator, 1024 * 1024);
    defer pool.deinit();
    var page = RequestAllocator.init(pool.allocator());
    _ = try page.allocator().alloc(u8, 100);
    page.deinit();
    pool.resetAndTrim();
    try std.testing.expect(pool.mapped_bytes <= pool.retained_limit);
}

test "cold template sources evaluate with the live host and retain only their invocation frame" {
    const Probe = struct {
        fn run(ctx: *Context, captures: Captures, _: []const Value) ![]const Value {
            const host: *const u32 = @ptrCast(@alignCast(ctx.host orelse return error.MissingScribuntoHost));
            const saved = (try captures.cell(0)).value;
            const out = try std.heap.smp_allocator.alloc(Value, 2);
            out[0] = saved;
            out[1] = .{ .number = @floatFromInt(host.*) };
            return out;
        }
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            if (ctx.host == null) return error.MissingScribuntoHost;
            const frame = ctx.current_frame orelse return error.MissingFrameContext;
            // Same admission contract as mw.getCurrentFrame(): the retained
            // frame is valid here, but may not become a cross-invoke template.
            markInvokeTemplateEffect();
            const saved = try ctx.newCell(.{ .table = frame });
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = try ctx.makeFunctionKnown(1, run, &.{saved});
            return out;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var worker = try Context.initProgram(arena.allocator(), 0, 1);
    defer worker.deinit();
    const roots = [_]FunctionFn{stabilize(Probe.root)};
    worker.module_root_entries = &roots;
    worker.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    // Also exercise a warm state record with no materialized export.
    _ = try worker.ensureModuleState(0);
    for ([_]u32{ 17, 29 }) |page_number| {
        var marker = page_number;
        var eligible = [_]bool{true};
        var rejected = [_]bool{false};
        for (0..2) |_| {
            var invocation = try worker.forkProgram(arena.allocator());
            defer invocation.deinit();
            invocation.module_template_context = &worker;
            invocation.module_template_eligible = &eligible;
            invocation.module_template_rejected = &rejected;
            invocation.setHost(&marker);
            const frame = try invocation.newTable();
            invocation.current_frame = frame;
            const retained = try invocation.requireByName("Module:TemplateProbe");
            try std.testing.expect(retained == .callable);
            // A saved frame remains itself even while another frame is current.
            invocation.current_frame = try invocation.newTable();
            for (0..2) |_| {
                const result = try invocation.callValue(retained, &.{});
                defer freeResults(result);
                try std.testing.expect(result.len == 2 and result[0] == .table);
                try std.testing.expect(result[0].table == frame);
                try std.testing.expectEqual(@as(f64, @floatFromInt(page_number)), result[1].number);
            }
            try std.testing.expect(!eligible[0] and rejected[0]);
            try std.testing.expect(worker.host == null and worker.current_frame == null);
            try std.testing.expect(worker.moduleStateConst(0).?.value == null);
        }
    }
}

test "cold live-host admission still promotes pure roots and preserves loader failures" {
    ModuleTemplateProbe.root_calls.store(0, .monotonic);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var worker = try Context.initProgram(arena.allocator(), 0, 1);
    defer worker.deinit();
    const roots = [_]FunctionFn{stabilize(ModuleTemplateProbe.root)};
    worker.module_root_entries = &roots;
    worker.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    var eligible = [_]bool{true};
    var rejected = [_]bool{false};
    worker.module_template_eligible = &eligible;
    worker.module_template_rejected = &rejected;
    var marker: u32 = 1;
    for (0..2) |_| {
        var child = try worker.forkProgram(arena.allocator());
        defer child.deinit();
        child.module_template_context = &worker;
        child.setHost(&marker);
        const module = try child.requireByName("Module:TemplateProbe");
        const result = try child.callValue(module.table.rawGet(.{ .string = "run" }).?, &.{});
        defer freeResults(result);
        try std.testing.expectEqual(@as(f64, 1), result[0].number);
        try std.testing.expect(eligible[0] and !rejected[0]);
    }
    try std.testing.expectEqual(@as(u32, 1), ModuleTemplateProbe.root_calls.load(.monotonic));
    const Failure = struct {
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.NotImplemented;
        }
    };
    var failing_source = try Context.initProgram(arena.allocator(), 0, 1);
    defer failing_source.deinit();
    const failing_roots = [_]FunctionFn{stabilize(Failure.root)};
    failing_source.module_root_entries = &failing_roots;
    failing_source.configureModules(null, ModuleTemplateProbe.lookup, ModuleTemplateProbe.name);
    var failing_eligible = [_]bool{true};
    var failing_rejected = [_]bool{false};
    var failing_child = try failing_source.forkProgram(arena.allocator());
    defer failing_child.deinit();
    failing_child.module_template_context = &failing_source;
    failing_child.module_template_eligible = &failing_eligible;
    failing_child.module_template_rejected = &failing_rejected;
    failing_child.setHost(&marker);
    try std.testing.expectError(error.AotCallFailed, failing_child.requireByName("Module:TemplateProbe"));
    try std.testing.expectEqualStrings("NotImplemented", failing_child.aotErrorName() orelse "missing");
    try std.testing.expect(failing_source.aotErrorName() == null);
}


test "title values refuse module template portability before stable sharing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Context.init(a, 0);
    defer source.deinit();
    var target = try Context.init(a, 0);
    defer target.deinit();
    const source_meta = try source.newTable();
    const target_meta = try target.newTable();
    source.registerNativeMetatable(.title_value, source_meta);
    target.registerNativeMetatable(.title_value, target_meta);
    var clone = Context.ModuleTemplateClone{ .source = &source, .target = &target };
    defer clone.deinit();
    const mapped_meta = try clone.cloneValue(.{ .table = source_meta });
    try std.testing.expect(mapped_meta.table == target_meta);
    const title = try source.newNativeNamespace(.title_value);
    try title.rawSetNativeField(.title_value, "namespace", .{ .number = 0 });
    try title.rawSetNativeField(.title_value, "text", .{ .string = "Event:Stored page" });
    try title.rawSetNativeField(.title_value, "prefixedText", .{ .string = "Event:Stored page" });
    title.metatable = source_meta;
    // This deliberately has no native methods; their removal cannot erase identity.
    title.cross_page_stable = true;
    title.read_only = true;
    try std.testing.expectError(error.UnsupportedModuleTemplate, clone.cloneValue(.{ .table = title }));
    var preflight = Context.PromotionPreflight{ .clone = .{ .source = &source, .target = &target } };
    defer preflight.deinit();
    try std.testing.expect(!try preflight.value(.{ .table = title }));
    try std.testing.expect(try preflight.value(.{ .table = source_meta }));
    const ordinary = try source.newTable();
    try ordinary.rawSet(a, .{ .string = "value" }, .{ .number = 7 });
    const copied = try clone.cloneValue(.{ .table = ordinary });
    try std.testing.expectEqual(@as(f64, 7), copied.table.rawGet(.{ .string = "value" }).?.number);
}

test "module syntax diagnostics use immutable metadata without loading a root" {
    const Probe = struct {
        const diagnostic = "error loading module 'Module:Broken': UnexpectedToken";
        fn lookup(_: ?*const anyopaque, module_name: []const u8) ?u32 {
            return if (std.mem.eql(u8, module_name, "Module:Broken")) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) "Module:Broken" else null;
        }
        fn diagnosticFor(raw: ?*const anyopaque, id: u32) ?[]const u8 {
            const host: *const u8 = @ptrCast(@alignCast(raw.?));
            std.debug.assert(host.* == 17);
            return if (id == 0) diagnostic else null;
        }
    };
    var ctx = try Context.initProgram(std.testing.allocator, 0, 1);
    defer ctx.deinit();
    const host: u8 = 17;
    ctx.configureModules(&host, Probe.lookup, Probe.name);
    ctx.configureModuleLoadErrors(Probe.diagnosticFor);
    try std.testing.expect(ctx.moduleState(0) == null);
    for (0..2) |_| {
        try std.testing.expectError(error.LuaRaised, ctx.checkModuleLoadError(0));
        try std.testing.expectEqualStrings(Probe.diagnostic, ctx.last_error.string);
        try std.testing.expect(ctx.moduleState(0) == null);
        ctx.clearLuaError();
    }
    try ctx.checkModuleLoadError(1);
    try std.testing.expect(!ctx.last_error_present);
    ctx.configureModules(null, Probe.lookup, Probe.name);
    try ctx.checkModuleLoadError(0);
    try std.testing.expect(!ctx.last_error_present);
}

test "module loader syntax diagnostics do not replace a fatal execution budget" {
    const Probe = struct {
        var now: u64 = 0;
        fn clock() error{LuaCpuClockUnavailable}!u64 { return now; }
        fn lookup(_: ?*const anyopaque, _: []const u8) ?u32 { return 0; }
        fn name(_: ?*const anyopaque, _: u32) ?[]const u8 { return "Module:Broken"; }
        fn diagnostic(_: ?*const anyopaque, _: u32) ?[]const u8 { return "UnexpectedToken"; }
    };
    var ctx = try Context.initProgram(std.testing.allocator, 0, 1);
    defer ctx.deinit();
    ctx.configureModules(null, Probe.lookup, Probe.name);
    ctx.configureModuleLoadErrors(Probe.diagnostic);
    Probe.now = 0;
    var budget: execution_budget.Budget = .{ .limit_ns = 10, .clock = Probe.clock };
    var scope = try budget.enter();
    Probe.now = 20;
    var exhausted = false;
    for (0..execution_budget.sample_period) |_| {
        execution_budget.check() catch |err| {
            try std.testing.expect(err == error.LuaCpuLimit);
            exhausted = true;
            break;
        };
    }
    try std.testing.expect(exhausted);
    try std.testing.expectError(error.LuaCpuLimit, ctx.checkModuleLoadError(0));
    try std.testing.expectEqualStrings("LuaCpuLimit", ctx.aotErrorName().?);
    try std.testing.expect(!ctx.last_error_present);
    try std.testing.expectError(error.LuaCpuLimit, scope.finish());
}

// Append to core.zig only in the private combined candidate. UNEXECUTED.
// Requires cache-truthiness.peer.patch, its clear-false followup, and the
// separately owned checkModuleLoadError getter. No Lua sentinel is introduced.
const RequireNilFalseControl = struct {
    fn lookup(_: ?*const anyopaque, name_value: []const u8) ?u32 {
        if (std.mem.eql(u8, name_value, "Module:NilResult")) return 0;
        if (std.mem.eql(u8, name_value, "Module:WritesFalse")) return 1;
        return null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return switch (id) {
            0 => "Module:NilResult",
            1 => "Module:WritesFalse",
            else => null,
        };
    }
    fn countRoot(ctx: *Context) !void {
        const before: f64 = switch (ctx.getGlobal(0)) {
            .number => |number| number,
            else => 0,
        };
        try ctx.setGlobal(0, .{ .number = before + 1 });
    }
    fn nilResult(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try countRoot(ctx);
        return &.{};
    }
    fn writesFalse(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try countRoot(ctx);
        const loaded = ctx.package_loaded orelse return error.MissingPackageLoaded;
        try loaded.rawSet(ctx.allocator, .{ .string = "Module:WritesFalse" }, .{ .boolean = false });
        return &.{};
    }
};

test "require caller seeded false followed by nil loader becomes cached true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 2);
    defer ctx.deinit();
    const roots = [_]FunctionFn{
        stabilize(RequireNilFalseControl.nilResult),
        stabilize(RequireNilFalseControl.writesFalse),
    };
    ctx.module_root_entries = &roots;
    ctx.configureModules(null, RequireNilFalseControl.lookup, RequireNilFalseControl.name);
    ctx.package_loaded = try ctx.newTable();
    const key: Value = .{ .string = "Module:NilResult" };
    try ctx.package_loaded.?.rawSet(ctx.allocator, key, .{ .boolean = false });
    try std.testing.expect((try ctx.requireByName(key.string)).boolean);
    try std.testing.expect(ctx.package_loaded.?.rawGet(key).?.boolean);
    try std.testing.expect((try ctx.requireByName(key.string)).boolean);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    // The ID entry point must also distinguish old false from a root write.
    try ctx.package_loaded.?.rawSet(ctx.allocator, key, .{ .boolean = false });
    try std.testing.expect((try ctx.requireModuleId(0, key.string)).boolean);
    try std.testing.expect(ctx.package_loaded.?.rawGet(key).?.boolean);
    try std.testing.expectEqual(@as(f64, 2), ctx.getGlobal(0).number);
}

test "require loader writing false then returning nil remains false and reruns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 2);
    defer ctx.deinit();
    const roots = [_]FunctionFn{
        stabilize(RequireNilFalseControl.nilResult),
        stabilize(RequireNilFalseControl.writesFalse),
    };
    ctx.module_root_entries = &roots;
    ctx.configureModules(null, RequireNilFalseControl.lookup, RequireNilFalseControl.name);
    ctx.package_loaded = try ctx.newTable();
    const key: Value = .{ .string = "Module:WritesFalse" };
    try ctx.package_loaded.?.rawSet(ctx.allocator, key, .{ .boolean = false });
    try std.testing.expect(!(try ctx.requireByName(key.string)).boolean);
    try std.testing.expect(!ctx.package_loaded.?.rawGet(key).?.boolean);
    try std.testing.expect(!(try ctx.requireModuleId(1, key.string)).boolean);
    try std.testing.expect(!ctx.package_loaded.?.rawGet(key).?.boolean);
    try std.testing.expectEqual(@as(f64, 2), ctx.getGlobal(0).number);
}

// Private core.zig append; UNEXECUTED. Requires both cache peer patches and
// main's loader-boundary patch, including forkProgram callback inheritance.
const RequireCacheControl = struct {
    const canonical = "Module:CacheControl";
    const alias = "Alias:CacheControl";
    const single_keys = [_]Value{.{ .string = canonical }};
    const dual_keys = [_]Value{ .{ .string = alias }, .{ .string = canonical } };
    const shapes = [_]Shape{
        .{ .keys = .{ .boxed = &single_keys }, .sorted_string_slots = &.{0}, .field_count = 1, .open = true, .all_string_keys = true },
        .{ .keys = .{ .boxed = &dual_keys }, .sorted_string_slots = &.{ 0, 1 }, .field_count = 2, .open = true, .all_string_keys = true },
    };
    fn lookup(_: ?*const anyopaque, text: []const u8) ?u32 {
        return if (std.mem.eql(u8, text, canonical) or std.mem.eql(u8, text, alias)) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) canonical else null;
    }
    // Ordinary map, canonical slot plus dynamic alias, then two known slots.
    fn loaded(ctx: *Context, mode: usize) !void {
        if (mode != 0) {
            ctx.program_shapes = &shapes;
            ctx.program_shapes_validated = true;
            ctx.package_loaded_shape_id = @intCast(mode - 1);
            ctx.package_loaded_module_slots = if (mode == 1) &.{0} else &.{1};
            ctx.package_loaded_slot_modules = if (mode == 1) &.{0} else &.{ std.math.maxInt(u32), 0 };
        }
        ctx.package_loaded = try ctx.newPackageLoadedTable();
    }
    fn increment(ctx: *Context) !f64 {
        const count: f64 = switch (ctx.getGlobal(0)) { .number => |n| n, else => 0 };
        try ctx.setGlobal(0, .{ .number = count + 1 });
        return count + 1;
    }
    fn returnFalse(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        _ = try increment(ctx);
        const result = try std.heap.smp_allocator.alloc(Value, 1);
        result[0] = .{ .boolean = false };
        return result;
    }
    fn returnCount(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        const count = try increment(ctx);
        const result = try std.heap.smp_allocator.alloc(Value, 1);
        result[0] = .{ .number = count };
        return result;
    }
    fn calls(ctx: *Context) f64 {
        return switch (ctx.getGlobal(0)) { .number => |n| n, else => 0 };
    }
};

test "require false-returning roots rerun through canonical alias and structural caches" {
    const F = RequireCacheControl;
    for (0..3) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ctx = try Context.initProgram(arena.allocator(), 1, 1);
        defer ctx.deinit();
        const roots = [_]FunctionFn{stabilize(F.returnFalse)};
        ctx.module_root_entries = &roots;
        ctx.configureModules(null, F.lookup, F.name);
        try F.loaded(&ctx, mode);
        try std.testing.expect(!(try ctx.requireByName(F.canonical)).boolean);
        try std.testing.expect(!(try ctx.requireModuleId(0, F.canonical)).boolean);
        try std.testing.expect(!(try ctx.requireByName(F.alias)).boolean);
        try std.testing.expect(!(try ctx.requireByName(F.alias)).boolean);
        try std.testing.expectEqual(@as(f64, 4), F.calls(&ctx));
        try std.testing.expect(!ctx.package_loaded.?.rawGet(.{ .string = F.canonical }).?.boolean);
        try std.testing.expect(!ctx.package_loaded.?.rawGet(.{ .string = F.alias }).?.boolean);
    }
}

test "require cleared nil and false reload prior truthy state while initial aliases share identity" {
    const F = RequireCacheControl;
    for (0..3) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ctx = try Context.initProgram(arena.allocator(), 1, 1);
        defer ctx.deinit();
        const roots = [_]FunctionFn{stabilize(F.returnCount)};
        ctx.module_root_entries = &roots;
        ctx.configureModules(null, F.lookup, F.name);
        try F.loaded(&ctx, mode);
        const key: Value = .{ .string = F.canonical };
        const alias_key: Value = .{ .string = F.alias };
        try std.testing.expectEqual(@as(f64, 1), (try ctx.requireByName(F.canonical)).number);
        try std.testing.expectEqual(@as(f64, 1), (try ctx.requireByName(F.alias)).number);
        try std.testing.expectEqual(@as(f64, 1), F.calls(&ctx));
        try ctx.package_loaded.?.rawSet(ctx.allocator, key, .nil);
        try std.testing.expectEqual(@as(f64, 2), (try ctx.requireByName(F.canonical)).number);
        try ctx.package_loaded.?.rawSet(ctx.allocator, key, .{ .boolean = false });
        try std.testing.expectEqual(@as(f64, 3), (try ctx.requireModuleId(0, F.canonical)).number);
        try ctx.package_loaded.?.rawSet(ctx.allocator, alias_key, .{ .boolean = false });
        try std.testing.expectEqual(@as(f64, 4), (try ctx.requireByName(F.alias)).number);
        try std.testing.expectEqual(@as(f64, 4), F.calls(&ctx));
        // Retain the repository's numeric-module alias identity contract.
        try ctx.package_loaded.?.rawSet(ctx.allocator, alias_key, .nil);
        try std.testing.expectEqual(@as(f64, 4), (try ctx.requireByName(F.alias)).number);
        try std.testing.expectEqual(@as(f64, 4), F.calls(&ctx));
    }
}

test "require zero and empty string are truthy hits without any module state" {
    const F = RequireCacheControl;
    for (0..3) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ctx = try Context.initProgram(arena.allocator(), 1, 1);
        defer ctx.deinit();
        const roots = [_]FunctionFn{stabilize(F.returnFalse)};
        ctx.module_root_entries = &roots;
        ctx.configureModules(null, F.lookup, F.name);
        try F.loaded(&ctx, mode);
        for ([_]Value{ .{ .number = 0 }, .{ .string = "" } }) |value| {
            try ctx.package_loaded.?.rawSet(ctx.allocator, .{ .string = F.canonical }, value);
            try ctx.package_loaded.?.rawSet(ctx.allocator, .{ .string = F.alias }, value);
            try std.testing.expect(rawEqual(value, try ctx.requireByName(F.canonical)));
            try std.testing.expect(rawEqual(value, try ctx.requireByName(F.alias)));
            try std.testing.expect(rawEqual(value, try ctx.requireModuleId(0, F.canonical)));
            try std.testing.expect(ctx.moduleState(0) == null);
        }
    }
}

test "require false preinitialization declines deferred cache and preserves eager admission" {
    const F = RequireCacheControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 1);
    defer ctx.deinit();
    const roots = [_]FunctionFn{stabilize(F.returnCount)};
    ctx.module_root_entries = &roots;
    ctx.configureModules(null, F.lookup, F.name);
    try F.loaded(&ctx, 0);
    try ctx.preinitializeModule(0, .{ .boolean = false }, false);
    var ignored: Value = undefined;
    try std.testing.expect(ctx.deferStaticRequireRef(0, &ignored) == null);
    ctx.beginEagerBootstrap();
    const eager = ctx.requireModuleId(0, F.canonical) catch |err| {
        ctx.endEagerBootstrap();
        return err;
    };
    ctx.endEagerBootstrap();
    try std.testing.expect(!eager.boolean);
    try std.testing.expectEqual(@as(f64, 0), F.calls(&ctx));
    try std.testing.expectEqual(@as(f64, 1), (try ctx.requireByName(F.canonical)).number);
    try std.testing.expectEqual(@as(f64, 1), F.calls(&ctx));
}

test "require false template exports execute live roots instead of cloning cached false" {
    const F = RequireCacheControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Context.initProgram(arena.allocator(), 1, 1);
    defer source.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 1);
    defer ctx.deinit();
    const roots = [_]FunctionFn{stabilize(F.returnFalse)};
    source.module_root_entries = &roots;
    ctx.module_root_entries = &roots;
    source.configureModules(null, F.lookup, F.name);
    ctx.configureModules(null, F.lookup, F.name);
    try F.loaded(&source, 0);
    try F.loaded(&ctx, 0);
    try std.testing.expect(!(try source.loadModule(0, null)).boolean);
    var eligible = [_]bool{true};
    var rejected = [_]bool{false};
    ctx.module_template_context = &source;
    ctx.module_template_eligible = &eligible;
    ctx.module_template_rejected = &rejected;
    try std.testing.expect(!(try ctx.requireByName(F.canonical)).boolean);
    try std.testing.expectEqual(@as(f64, 1), F.calls(&ctx));
    try std.testing.expect(!(try ctx.requireByName(F.canonical)).boolean);
    try std.testing.expectEqual(@as(f64, 2), F.calls(&ctx));
    try std.testing.expectEqual(@as(f64, 1), F.calls(&source));
}

test "forked contexts inherit immutable module load diagnostics and lookup host" {
    const Probe = struct {
        const message = "error loading module 'Module:BrokenFork': UnexpectedToken";
        fn lookup(_: ?*const anyopaque, _: []const u8) ?u32 { return 0; }
        fn name(_: ?*const anyopaque, _: u32) ?[]const u8 { return "Module:BrokenFork"; }
        fn diagnostic(raw: ?*const anyopaque, id: u32) ?[]const u8 {
            const host: *const u8 = @ptrCast(@alignCast(raw.?));
            std.debug.assert(host.* == 23);
            return if (id == 0) message else null;
        }
    };
    const host: u8 = 23;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Context.initProgram(arena.allocator(), 0, 1);
    defer source.deinit();
    source.configureModules(&host, Probe.lookup, Probe.name);
    source.configureModuleLoadErrors(Probe.diagnostic);
    var child = try source.forkProgram(arena.allocator());
    defer child.deinit();
    try std.testing.expect(child.module_lookup_ctx == source.module_lookup_ctx);
    try std.testing.expectError(error.LuaRaised, child.checkModuleLoadError(0));
    try std.testing.expectEqualStrings(Probe.message, child.last_error.string);
    try std.testing.expect(child.moduleState(0) == null);
    try std.testing.expect(!source.last_error_present);
    child.clearLuaError();
    try std.testing.expectError(error.LuaRaised, source.checkModuleLoadError(0));
    try std.testing.expectEqualStrings(Probe.message, source.last_error.string);
}


test "package loaded nil roots preserve page effects while pure roots remain reusable" {
    const Probe = struct {
        var pure_runs: u32 = 0;
        fn lookup(_: ?*const anyopaque, text: []const u8) ?u32 {
            if (std.mem.eql(u8, text, "Module:NilCounter")) return 0;
            if (std.mem.eql(u8, text, "Module:PureCounter")) return 1;
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) { 0 => "Module:NilCounter", 1 => "Module:PureCounter", else => null };
        }
        fn nilRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            const loaded = ctx.package_loaded.?;
            const key: Value = .{ .string = "__counter" };
            const before: Value = loaded.rawGet(key) orelse .{ .number = 0 };
            try loaded.rawSet(ctx.allocator, key, .{ .number = before.number + 1 });
            return &.{};
        }
        fn pureRoot(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            pure_runs += 1;
            try ctx.observePackage();
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .string = "pure" };
            return out;
        }
    };
    const keys = [_]Value{ .{ .string = "Module:NilCounter" }, .{ .string = "Module:PureCounter" } };
    const shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .field_count = 2, .sorted_string_slots = &.{ 0, 1 }, .all_string_keys = true, .open = true }};
    const roots = [_]FunctionFn{ stabilize(Probe.nilRoot), stabilize(Probe.pureRoot) };
    for ([_]bool{ false, true }) |structural| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var source = try Context.initProgram(a, 0, 2);
        defer source.deinit();
        source.module_root_entries = &roots;
        source.configureModules(null, Probe.lookup, Probe.name);
        if (structural) {
            source.program_shapes = &shapes;
            source.program_shapes_validated = true;
            source.package_loaded_shape_id = 0;
            source.package_loaded_module_slots = &.{ 0, 1 };
            source.package_loaded_slot_modules = &.{ 0, 1 };
        }
        var eligible = [_]bool{ false, false };
        var rejected = [_]bool{ false, false };
        source.module_template_eligible = &eligible;
        source.module_template_rejected = &rejected;
        Probe.pure_runs = 0;
        for (0..3) |page_number| {
            var page = try source.forkProgram(a);
            defer page.deinit();
            page.module_template_context = &source;
            page.module_template_eligible = &eligible;
            page.module_template_rejected = &rejected;
            var marker = page_number;
            page.setHost(&marker);
            page.package_loaded = try page.newPackageLoadedTable();
            try page.package_loaded.?.rawSet(a, .{ .string = "__counter" }, .{ .number = 0 });
            try std.testing.expect((try page.requireByName("Module:NilCounter")).boolean);
            try std.testing.expect((try page.requireByName("Module:NilCounter")).boolean);
            try std.testing.expectEqual(@as(f64, 1), page.package_loaded.?.rawGet(.{ .string = "__counter" }).?.number);
            // Test false reload only after all three cold/warm page checks;
            // otherwise the shared rejection flag would mask the pre-fix bug.
            if (page_number == 2) {
                try page.package_loaded.?.rawSet(a, .{ .string = "Module:NilCounter" }, .{ .boolean = false });
                try std.testing.expect((try page.requireByName("Module:NilCounter")).boolean);
                try std.testing.expect((try page.requireByName("Module:NilCounter")).boolean);
                try std.testing.expectEqual(@as(f64, 2), page.package_loaded.?.rawGet(.{ .string = "__counter" }).?.number);
            }
            try std.testing.expectEqualStrings("pure", (try page.requireByName("Module:PureCounter")).string);
            try std.testing.expectEqualStrings("pure", (try page.requireByName("Module:PureCounter")).string);
        }
        try std.testing.expectEqual(@as(u32, 1), Probe.pure_runs);
    }
}

test "package loaded explicit reads observe current page values including misses false and semantic access" {
    const Probe = struct {
        var mode: usize = 0;
        fn lookup(_: ?*const anyopaque, text: []const u8) ?u32 {
            if (std.mem.eql(u8, text, "Module:Reader")) return 0;
            if (std.mem.eql(u8, text, "Module:Observed")) return 1;
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) { 0 => "Module:Reader", 1 => "Module:Observed", else => null };
        }
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            const loaded = ctx.package_loaded.?;
            const key: Value = .{ .string = if (mode == 3) "Module:Observed" else "__custom" };
            const seen: Value = switch (mode) {
                0, 3 => loaded.rawGet(key) orelse .nil,
                1 => loaded.rawGetHashedString(key.string, stringValueHash(key.string)) orelse .nil,
                2 => blk: {
                    const first = try ctx.getFieldAtSite(.{ .table = loaded }, key.string, stringValueHash(key.string), 41);
                    const second = try ctx.getFieldAtSite(.{ .table = loaded }, key.string, stringValueHash(key.string), 41);
                    try std.testing.expect(rawEqual(first, second));
                    break :blk second;
                },
                4 => loaded.rawGetNumber(1) orelse .nil,
                5 => .{ .number = @floatFromInt(loaded.rawLen()) },
                6 => blk: {
                    var it = loaded.iterator();
                    while (it.next()) |entry| if (rawEqual(entry.key_ptr.*, key)) break :blk entry.value_ptr.*;
                    break :blk .nil;
                },
                7 => ctx.metamethod(.{ .table = loaded }, "__call") orelse .nil,
                else => unreachable,
            };
            const result = try ctx.newTable();
            try result.rawSet(ctx.allocator, .{ .string = "seen" }, seen);
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .table = result };
            return out;
        }
    };
    const keys = [_]Value{ .{ .string = "Module:Observed" }, .{ .string = "Module:Reader" } };
    const shapes = [_]Shape{.{ .keys = .{ .boxed = &keys }, .field_count = 2, .sorted_string_slots = &.{ 0, 1 }, .all_string_keys = true, .open = true }};
    const roots = [_]FunctionFn{ stabilize(Probe.root), stabilize(Probe.root) };
    for ([_]bool{ false, true }) |structural| for (0..8) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var source = try Context.initProgram(a, 0, 2);
        defer source.deinit();
        source.module_root_entries = &roots;
        source.configureModules(null, Probe.lookup, Probe.name);
        if (structural) {
            source.program_shapes = &shapes;
            source.program_shapes_validated = true;
            source.package_loaded_shape_id = 0;
            source.package_loaded_module_slots = &.{ 1, 0 };
            source.package_loaded_slot_modules = &.{ 1, 0 };
        }
        var eligible = [_]bool{ false, false };
        var rejected = [_]bool{ false, false };
        source.module_template_eligible = &eligible;
        source.module_template_rejected = &rejected;
        Probe.mode = mode;
        for (0..3) |page_number| {
            var page = try source.forkProgram(a);
            defer page.deinit();
            page.module_template_context = &source;
            page.module_template_eligible = &eligible;
            page.module_template_rejected = &rejected;
            var marker = page_number;
            page.setHost(&marker);
            page.package_loaded = try page.newPackageLoadedTable();
            const input: Value = switch (page_number) { 0 => .nil, 1 => .{ .boolean = false }, else => .{ .number = 17 } };
            const key: Value = .{ .string = if (mode == 3) "Module:Observed" else "__custom" };
            try page.package_loaded.?.rawSet(a, key, input);
            try page.package_loaded.?.rawSet(a, .{ .number = 1 }, input);
            if (page_number == 2) try page.package_loaded.?.rawSet(a, .{ .number = 2 }, .{ .boolean = true });
            if (mode == 7 and page_number != 0) {
                const mt = try page.newTable();
                try mt.rawSet(a, .{ .string = "__call" }, input);
                page.package_loaded.?.metatable = mt;
            }
            const result = try page.requireByName("Module:Reader");
            const seen = result.table.rawGet(.{ .string = "seen" }) orelse .nil;
            const expected: Value = if (mode == 5) .{ .number = @floatFromInt(page_number) } else input;
            try std.testing.expect(rawEqual(expected, seen));
        }
    };
}


test "package loaded writes remain page effects despite export guards or probe allocation" {
    const Probe = struct {
        var allocate_inside: bool = false;
        fn lookup(_: ?*const anyopaque, text: []const u8) ?u32 {
            return if (std.mem.eql(u8, text, "Module:Writer")) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) "Module:Writer" else null;
        }
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            if (allocate_inside) ctx.package_loaded = try ctx.newPackageLoadedTable();
            try ctx.package_loaded.?.rawSet(ctx.allocator, .{ .string = "__written" }, .{ .number = 17 });
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .string = "written" };
            return out;
        }
    };
    for ([_]bool{ false, true }) |allocate_inside| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var source = try Context.initProgram(a, 0, 1);
        defer source.deinit();
        const roots = [_]FunctionFn{stabilize(Probe.root)};
        source.module_root_entries = &roots;
        source.configureModules(null, Probe.lookup, Probe.name);
        var eligible = [_]bool{false};
        var rejected = [_]bool{false};
        source.module_template_eligible = &eligible;
        source.module_template_rejected = &rejected;
        Probe.allocate_inside = allocate_inside;
        for (0..3) |page_number| {
            var page = try source.forkProgram(a);
            defer page.deinit();
            page.module_template_context = &source;
            page.module_template_eligible = &eligible;
            page.module_template_rejected = &rejected;
            var marker = page_number;
            page.setHost(&marker);
            page.package_loaded = try page.newPackageLoadedTable();
            page.package_loaded.?.prepareExportGuard();
            try std.testing.expectEqualStrings("written", (try page.requireByName("Module:Writer")).string);
            try std.testing.expectEqual(@as(f64, 17), page.package_loaded.?.rawGet(.{ .string = "__written" }).?.number);
        }
    }
}

const InvocationEnvironmentTest = struct {
    const names = [_][]const u8{ "Module:InvocationWriter", "Module:InvocationReader", "Module:InvocationBroken" };
    fn lookup(_: ?*const anyopaque, requested: []const u8) ?u32 {
        for (names, 0..) |item, id| if (std.mem.eql(u8, item, requested)) return @intCast(id);
        return null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id < names.len) names[id] else null;
    }
    fn one(value: Value) ![]const Value {
        const result = try std.heap.smp_allocator.alloc(Value, 1);
        result[0] = value;
        return result;
    }
    fn read(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try std.testing.expectEqual(@as(?u32, 1), ctx.active_module_id);
        return one(ctx.getGlobal(1));
    }
    fn readBuffered(ctx: *Context, captures: Captures, args: []const Value, buffer: ?[]Value) ![]const Value {
        try std.testing.expectEqual(@as(?u32, 1), ctx.active_module_id);
        if (buffer) |out| if (out.len != 0) {
            out[0] = ctx.getGlobal(1);
            return out[0..1];
        };
        return read(ctx, captures, args);
    }
    fn reader(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        const exported = try ctx.newTable();
        try exported.rawSet(ctx.allocator, .{ .string = "read" }, try ctx.makeFunction(3, stabilize(read), &.{}));
        return one(.{ .table = exported });
    }
    fn writer(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try ctx.setGlobal(1, .{ .number = 7 });
        const exported = try ctx.requireByName(names[1]);
        const callable = exported.table.rawGet(.{ .string = "read" }).?;
        const first = try ctx.callValueFirst(callable, &.{});
        try ctx.setGlobal(1, .{ .number = 19 });
        const second = try ctx.callValueFirst(callable, &.{});
        try std.testing.expect(rawEqual(exported, try ctx.requireByName(names[1])));
        const result = try ctx.newTable();
        try result.rawSet(ctx.allocator, .{ .string = "before" }, first);
        try result.rawSet(ctx.allocator, .{ .string = "after" }, second);
        return one(.{ .table = result });
    }
    fn broken(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try ctx.setGlobal(1, .{ .number = 43 });
        return error.NotImplemented;
    }
};

test "required modules and returned functions observe same invocation globals and late writes" {
    const F = InvocationEnvironmentTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 2, F.names.len);
    defer ctx.deinit();
    const roots = [_]FunctionFn{ stabilize(F.writer), stabilize(F.reader), stabilize(F.broken) };
    const owners = [_]u32{ 0, 1, 2, 1 };
    ctx.module_root_entries = &roots;
    ctx.function_module_ids = &owners;
    ctx.configureModules(null, F.lookup, F.name);
    const actual = try ctx.requireByName(F.names[0]);
    try std.testing.expectEqual(@as(f64, 7), actual.table.rawGet(.{ .string = "before" }).?.number);
    try std.testing.expectEqual(@as(f64, 19), actual.table.rawGet(.{ .string = "after" }).?.number);
    try std.testing.expectEqual(@as(f64, 19), ctx.getGlobal(1).number);
    try std.testing.expect(ctx.active_module_id == null and ctx.depth == 0);
    const cached = try ctx.requireByName(F.names[1]);
    const callable = cached.table.rawGet(.{ .string = "read" }).?;
    try ctx.setGlobal(1, .{ .boolean = false });
    try std.testing.expect(!(try ctx.callValueFirst(callable, &.{})).boolean);
    try std.testing.expect(rawEqual(cached, try ctx.requireByName(F.names[1])));
    try std.testing.expect(ctx.active_module_id == null and ctx.depth == 0);
}

test "static direct buffered and dynamic calls retain environment while restoring defining module metadata" {
    const F = InvocationEnvironmentTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 2, 2);
    defer ctx.deinit();
    const owners = [_]u32{ 0, 1 };
    ctx.function_module_ids = &owners;
    const callable = try ctx.makeFunction(1, stabilize(F.read), &.{});
    try ctx.setGlobal(1, .{ .number = 29 });
    const outer = try ctx.enterModule(0);
    defer ctx.restoreModule(outer);
    var buffer: [1]Value = undefined;
    const dynamic = try ctx.callFunctionBuffered(callable.callable, &.{}, &buffer);
    defer freeResults(dynamic);
    try std.testing.expectEqual(@as(f64, 29), dynamic[0].number);
    try std.testing.expectEqual(@as(?u32, 0), ctx.active_module_id);
    const direct = try ctx.callDirectFunction(callable.callable.*, F.read, &.{});
    defer freeResults(direct);
    try std.testing.expectEqual(@as(f64, 29), direct[0].number);
    try std.testing.expectEqual(@as(?u32, 0), ctx.active_module_id);
    const buffered = try ctx.callBufferedDirectFunction(callable.callable.*, F.readBuffered, &.{}, &buffer);
    try std.testing.expect(buffered.ptr == buffer[0..].ptr);
    try std.testing.expectEqual(@as(f64, 29), buffered[0].number);
    try std.testing.expectEqual(@as(?u32, 0), ctx.active_module_id);
    const fixed = try ctx.callStaticFunctionBuffered(1, stabilize(F.read), &.{}, &.{}, &buffer);
    defer freeResults(fixed);
    try std.testing.expectEqual(@as(f64, 29), fixed[0].number);
    try std.testing.expectEqual(@as(?u32, 0), ctx.active_module_id);
    try ctx.enterStaticModule(1);
    try std.testing.expectEqual(@as(?u32, 1), ctx.active_module_id);
    try ctx.setGlobal(1, .{ .number = 31 });
    ctx.leaveStaticFunction();
    try std.testing.expectEqual(@as(f64, 31), ctx.getGlobal(1).number);
    try std.testing.expectEqual(@as(?u32, 0), ctx.active_module_id);
    try std.testing.expectEqual(@as(usize, 0), ctx.depth);
}

test "caught module initialization errors preserve prior global writes and unwind loading owner and depth" {
    const F = InvocationEnvironmentTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 2, F.names.len);
    defer ctx.deinit();
    const roots = [_]FunctionFn{ stabilize(F.writer), stabilize(F.reader), stabilize(F.broken) };
    const owners = [_]u32{ 0, 1, 2, 1 };
    ctx.module_root_entries = &roots;
    ctx.function_module_ids = &owners;
    ctx.configureModules(null, F.lookup, F.name);
    const exported = try ctx.requireByName(F.names[1]);
    for (0..2) |_| {
        try std.testing.expectError(error.AotCallFailed, ctx.requireByName(F.names[2]));
        try std.testing.expectEqualStrings("NotImplemented", ctx.aotErrorName().?);
        try std.testing.expect(!ctx.moduleStateConst(2).?.loading);
        try std.testing.expect(ctx.active_module_id == null and ctx.depth == 0);
        try std.testing.expectEqual(@as(f64, 43), ctx.getGlobal(1).number);
        ctx.clearAotErrorName();
        try std.testing.expectEqual(@as(f64, 43), (try ctx.callValueFirst(exported.table.rawGet(.{ .string = "read" }).?, &.{})).number);
    }
}

test "modified installed library field and metatable reads refuse root promotion and rollback restores baseline" {
    for ([_]bool{ false, true }) |page_scope| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ctx = try Context.initProgram(a, 3, 1);
        defer ctx.deinit();
        try bindGlobalTable(&ctx, null, 0);
        const environment = ctx.global_table.?;
        const math = try ctx.newNativeNamespace(.math);
        try math.rawSetNativeField(.math, "abs", .{ .number = 7 });
        const absolute_slot = math.slotForString("abs", null) orelse return error.MissingNativeFixtureField;
        try ctx.setGlobal(1, .{ .table = math });
        try ctx.setGlobal(2, .{ .number = 11 });
        ctx.finishLibraryInstallation();
        const initial_scope = try ctx.enterModule(0);
        ctx.restoreModule(initial_scope);
        var pristine_effect = false;
        const pristine_probe = beginModuleTemplateEffectProbe(&pristine_effect, page_scope);
        const pristine = ctx.getKnownNativeField(ctx.getGlobal(1), .math, absolute_slot, "abs") catch |err| {
            endModuleTemplateEffectProbe(pristine_probe, pristine_effect);
            return err;
        };
        endModuleTemplateEffectProbe(pristine_probe, pristine_effect);
        try std.testing.expectEqual(@as(f64, 7), pristine.number);
        try std.testing.expect(!pristine_effect);

        var journal = InvokeRollbackJournal.init(a, &ctx);
        journal.begin();
        var journal_active = true;
        defer if (journal_active) journal.rollback(&ctx);
        try math.rawSetNativeField(.math, "abs", .{ .number = 19 });
        ctx.finishLibraryInstallation();
        try std.testing.expectEqual(@as(?bool, false), math.template_native_baseline_pristine);
        const changed_mt = try ctx.newTable();
        try changed_mt.rawSet(a, .{ .string = "__index" }, .{ .number = 23 });
        try math.setMetatable(changed_mt);
        try ctx.setGlobal(2, .{ .boolean = false });
        try ctx.setGlobal(0, .nil);
        try std.testing.expect(ctx.global_table.? == environment and ctx.getGlobal(0) == .nil);

        var field_effect = false;
        const field_probe = beginModuleTemplateEffectProbe(&field_effect, page_scope);
        const changed = ctx.getKnownNativeField(ctx.getGlobal(1), .math, absolute_slot, "abs") catch |err| {
            endModuleTemplateEffectProbe(field_probe, field_effect);
            return err;
        };
        endModuleTemplateEffectProbe(field_probe, field_effect);
        try std.testing.expectEqual(@as(f64, 19), changed.number);
        try std.testing.expect(field_effect);

        var metatable_effect = false;
        const metatable_probe = beginModuleTemplateEffectProbe(&metatable_effect, page_scope);
        const inherited = ctx.metamethod(.{ .table = math }, "__index");
        endModuleTemplateEffectProbe(metatable_probe, metatable_effect);
        try std.testing.expectEqual(@as(f64, 23), (inherited orelse return error.MissingNativeFixtureMetamethod).number);
        try std.testing.expect(metatable_effect);

        ctx.setAotErrorName("controlled invocation failure");
        journal.rollback(&ctx);
        journal_active = false;
        try std.testing.expect(ctx.global_table.? == environment and ctx.getGlobal(0).table == environment);
        try std.testing.expectEqual(@as(f64, 11), ctx.getGlobal(2).number);
        try std.testing.expect(math.metatable == null);
        try std.testing.expect(ctx.aotErrorName() == null and ctx.depth == 0 and ctx.active_module_id == null);
        var restored_effect = false;
        const restored_probe = beginModuleTemplateEffectProbe(&restored_effect, page_scope);
        const restored = ctx.getKnownNativeField(ctx.getGlobal(1), .math, absolute_slot, "abs") catch |err| {
            endModuleTemplateEffectProbe(restored_probe, restored_effect);
            return err;
        };
        endModuleTemplateEffectProbe(restored_probe, restored_effect);
        try std.testing.expectEqual(@as(f64, 7), restored.number);
        try std.testing.expect(!restored_effect);
    }
}

test "pristine library template reuse guards current invocation and retains later pristine reuse" {
    const Probe = struct {
        var calls: usize = 0;
        const names = [_][]const u8{ "Module:LibraryCapture", "Module:LibraryConsumer" };
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            for (names, 0..) |candidate, id| if (std.mem.eql(u8, candidate, raw_name)) return @intCast(id);
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id < names.len) names[id] else null;
        }
        fn result(ctx: *Context, value: Value) ![]const Value {
            const table = try ctx.newTable();
            try table.rawSet(ctx.allocator, .{ .string = "value" }, value);
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .table = table };
            return out;
        }
        fn capture(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            calls += 1;
            const math = ctx.getGlobal(0);
            const slot = math.table.slotForString("abs", null) orelse return error.MissingNativeFixtureField;
            return result(ctx, try ctx.getKnownNativeField(math, .math, slot, "abs"));
        }
        fn consumer(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            const captured = try ctx.requireByName(names[0]);
            return result(ctx, captured.table.rawGet(.{ .string = "value" }).?);
        }
        fn install(ctx: *Context) !*Table {
            const math = try ctx.newNativeNamespace(.math);
            try math.rawSetNativeField(.math, "abs", .{ .number = 7 });
            try ctx.setGlobal(0, .{ .table = math });
            ctx.finishLibraryInstallation();
            return math;
        }
    };
    for ([_]bool{ false, true }) |page_scope| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var template = try Context.initProgram(a, 1, 2);
        defer template.deinit();
        const roots = [_]FunctionFn{ stabilize(Probe.capture), stabilize(Probe.consumer) };
        template.module_root_entries = &roots;
        template.configureModules(null, Probe.lookup, Probe.name);
        var eligible = [_]bool{ false, false };
        var rejected = [_]bool{ false, false };
        template.module_template_eligible = &eligible;
        template.module_template_rejected = &rejected;
        template.module_template_page_scope = page_scope;
        _ = try Probe.install(&template);
        Probe.calls = 0;
        for ([_]f64{ 7, 19, 7 }, 0..) |expected, invocation_index| {
            var invocation = try template.forkProgram(a);
            defer invocation.deinit();
            invocation.module_template_context = &template;
            invocation.module_template_page_scope = page_scope;
            invocation.package_loaded = try invocation.newTable();
            const math = try Probe.install(&invocation);
            if (expected != 7) try math.rawSetNativeField(.math, "abs", .{ .number = expected });
            const value = try invocation.requireByName(Probe.names[0]);
            try std.testing.expectEqual(expected, value.table.rawGet(.{ .string = "value" }).?.number);
            try std.testing.expect(eligible[0] and !rejected[0]);
            try std.testing.expect(template.moduleStateConst(0).?.template_library_dependencies != 0);
            try std.testing.expectEqual(invocation_index == 1, invocation.moduleStateConst(0).?.template_invocation_dependent);
            if (invocation_index == 1) {
                const consumer = try invocation.requireByName(Probe.names[1]);
                try std.testing.expectEqual(expected, consumer.table.rawGet(.{ .string = "value" }).?.number);
                try std.testing.expect(!eligible[1] and rejected[1]);
                try math.rawSetNativeField(.math, "abs", .{ .number = 7 });
                const cached = try invocation.requireByName(Probe.names[0]);
                try std.testing.expect(cached.table == value.table);
                try std.testing.expectEqual(expected, cached.table.rawGet(.{ .string = "value" }).?.number);
            }
        }
        try std.testing.expectEqual(@as(usize, 2), Probe.calls);
    }
}

const BetweenProbeDependencyFixture = struct {
    calls: [2]usize = .{ 0, 0 },
    fail: bool = false,
    const names = [_][]const u8{ "Module:GuardA", "Module:GuardB", "Module:GuardHelper" };
    const roots = [_]FunctionFn{ stabilize(rootA), stabilize(rootB), stabilize(helperRoot) };

    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        if (std.mem.eql(u8, raw_name, "Module:GuardAlias")) return 0;
        for (names, 0..) |item, id| if (std.mem.eql(u8, item, raw_name)) return @intCast(id);
        return null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id < names.len) names[id] else null;
    }
    fn fixture(ctx: *Context) *@This() {
        return @ptrCast(@alignCast(@constCast(ctx.module_lookup_ctx.?)));
    }
    fn result(value: Value) ![]const Value {
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = value;
        return out;
    }
    fn rootA(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        fixture(ctx).calls[0] += 1;
        const nested_child = try ctx.newTable();
        try nested_child.rawSet(ctx.allocator, .{ .string = "x" }, .{ .number = 7 });
        const out = try ctx.newTable();
        try out.rawSet(ctx.allocator, .{ .string = "child" }, .{ .table = nested_child });
        return result(.{ .table = out });
    }
    fn helperRoot(_: *Context, _: Captures, _: []const Value) ![]const Value {
        return error.TestUnexpectedResult;
    }
    fn helper(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        try std.testing.expectEqual(@as(?u32, 2), ctx.active_module_id);
        var deferred: Value = undefined;
        if (module_template_dependency_probe != null)
            try std.testing.expect(ctx.deferStaticRequireRef(0, &deferred) == null);
        const dependency = try ctx.requireByName("Module:GuardAlias");
        const nested_child = dependency.table.rawGet(.{ .string = "child" }).?.table;
        return result(nested_child.rawGet(.{ .string = "x" }) orelse .nil);
    }
    fn rootB(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
        fixture(ctx).calls[1] += 1;
        const values = try ctx.callStaticFunctionBuffered(2, stabilize(helper), &.{}, &.{}, null);
        defer freeResults(values);
        if (fixture(ctx).fail) return error.DependencyGuardProbeFailure;
        const out = try ctx.newTable();
        try out.rawSet(ctx.allocator, .{ .string = "saved" }, values[0]);
        return result(.{ .table = out });
    }
    fn init(self: *@This(), a: std.mem.Allocator, eligible: []bool, rejected: []bool) !Context {
        var ctx = try Context.initProgram(a, 0, roots.len);
        ctx.module_root_entries = &roots;
        ctx.configureModules(self, lookup, name);
        ctx.module_template_eligible = eligible;
        ctx.module_template_rejected = rejected;
        return ctx;
    }
    fn fork(template: *Context, a: std.mem.Allocator) !Context {
        var ctx = try template.forkProgram(a);
        ctx.module_template_context = template;
        ctx.package_loaded = try ctx.newTable();
        return ctx;
    }
    fn child(value: Value) *Table {
        return value.table.rawGet(.{ .string = "child" }).?.table;
    }
    fn saved(value: Value) Value {
        return value.table.rawGet(.{ .string = "saved" }) orelse .nil;
    }
};

test "warm template dependency guard rejects between probe descendants and retains unchanged specialization" {
    const F = BetweenProbeDependencyFixture;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var probe: F = .{};
    var eligible = [_]bool{ false, false, false };
    var rejected = [_]bool{ false, false, false };
    var template = try probe.init(a, &eligible, &rejected);
    defer template.deinit();
    for ([_]f64{ 7, 19, 7 }, 0..) |expected, index| {
        var live = try F.fork(&template, a);
        defer live.deinit();
        const dependency = try live.requireByName(F.names[0]);
        const sentinel = live.moduleValueSentinel(0, dependency).?;
        var direct: Value = undefined;
        try std.testing.expect(live.deferStaticRequireRef(0, &direct) != null);
        try std.testing.expect(rawEqual(direct, dependency));
        if (index == 1) {
            try std.testing.expect(module_template_effect_probe == null);
            try F.child(dependency).rawSet(a, .{ .string = "x" }, .{ .number = expected });
            try std.testing.expect(!sentinel.*);
        }
        const value = try live.requireByName(F.names[1]);
        try std.testing.expectEqual(expected, F.saved(value).number);
        try std.testing.expect(rawEqual(dependency, live.package_loaded.?.rawGet(.{ .string = "Module:GuardAlias" }).?));
        try std.testing.expect(eligible[0] and eligible[1]);
        try std.testing.expect(!rejected[0] and !rejected[1]);
        try std.testing.expectEqual(index == 1, live.moduleStateConst(1).?.template_invocation_dependent);
        const cached = try live.requireByName(F.names[1]);
        try std.testing.expect(rawEqual(value, cached));
        const requirements = template.moduleStateConst(1).?.template_observed_requirements;
        try std.testing.expectEqual(@as(usize, 1), requirements.len);
        try std.testing.expectEqual(@as(u32, 0), requirements[0].module_id);
        try std.testing.expectEqualStrings("Module:GuardAlias", requirements[0].requested);
        try std.testing.expectEqual(@as(f64, 7), F.saved(template.moduleStateConst(1).?.value.?).number);
    }
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, &probe.calls);
}

test "cold template dependency guard observes mutation before initializer and preserves nil false and errors" {
    const F = BetweenProbeDependencyFixture;
    for ([_]Value{ .{ .number = 19 }, .{ .boolean = false }, .nil }) |expected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var probe: F = .{};
        var eligible = [_]bool{ false, false, false };
        var rejected = [_]bool{ false, false, false };
        var template = try probe.init(a, &eligible, &rejected);
        defer template.deinit();
        var first = try F.fork(&template, a);
        defer first.deinit();
        const dependency = try first.requireByName(F.names[0]);
        try F.child(dependency).rawSet(a, .{ .string = "x" }, expected);
        const actual = try first.requireByName(F.names[1]);
        try std.testing.expect(rawEqual(expected, F.saved(actual)));
        try std.testing.expect(eligible[0] and !rejected[0] and !eligible[1] and rejected[1]);
        try std.testing.expect(template.moduleStateConst(1) == null);
        var second = try F.fork(&template, a);
        defer second.deinit();
        const later = try second.requireByName(F.names[0]);
        try F.child(later).rawSet(a, .{ .string = "x" }, .{ .number = 27 });
        try std.testing.expectEqual(@as(f64, 27), F.saved(try second.requireByName(F.names[1])).number);
        var failed = try F.fork(&template, a);
        defer failed.deinit();
        probe.fail = true;
        try std.testing.expectError(error.AotCallFailed, failed.requireByName(F.names[1]));
        try std.testing.expectEqualStrings("DependencyGuardProbeFailure", failed.aotErrorName().?);
        try std.testing.expect(failed.moduleStateConst(1).?.value == null);
        try std.testing.expectEqualSlices(usize, &.{ 1, 3 }, &probe.calls);
    }
}

test "template dependency guard rejects requested alias overrides without changing the worker prototype" {
    const F = BetweenProbeDependencyFixture;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var probe: F = .{};
    var eligible = [_]bool{ false, false, false };
    var rejected = [_]bool{ false, false, false };
    var template = try probe.init(a, &eligible, &rejected);
    defer template.deinit();
    var seed = try F.fork(&template, a);
    defer seed.deinit();
    _ = try seed.requireByName(F.names[0]);
    _ = try seed.requireByName(F.names[1]);
    var live = try F.fork(&template, a);
    defer live.deinit();
    const original = try live.requireByName(F.names[0]);
    const replacement = try live.newTable();
    const child = try live.newTable();
    try child.rawSet(a, .{ .string = "x" }, .{ .number = 31 });
    try replacement.rawSet(a, .{ .string = "child" }, .{ .table = child });
    try live.package_loaded.?.rawSet(a, .{ .string = "Module:GuardAlias" }, .{ .table = replacement });
    try std.testing.expectEqual(@as(f64, 31), F.saved(try live.requireByName(F.names[1])).number);
    try std.testing.expect(rawEqual(original, try live.requireByName(F.names[0])));
    try std.testing.expectEqual(@as(f64, 7), F.saved(template.moduleStateConst(1).?.value.?).number);
    try std.testing.expect(eligible[1] and !rejected[1]);
}

test "descendant export guards cover shared cycles slot writes and rollback without invoking metatables" {
    const Poison = struct {
        fn call(_: ?*anyopaque, _: *Context, _: []const Value) ![]const Value {
            return error.TestUnexpectedResult;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.initProgram(a, 0, 2);
    defer ctx.deinit();
    const keys = [_][]const u8{"x"};
    const shape = Shape{ .keys = .{ .strings = &keys }, .field_count = 1 };
    const child = try ctx.newShapedTable(&shape);
    try child.rawSetSlot(0, .{ .number = 7 });
    const left = try ctx.newTable();
    const right = try ctx.newTable();
    try left.rawSet(a, .{ .string = "child" }, .{ .table = child });
    try right.rawSet(a, .{ .string = "child" }, .{ .table = child });
    try child.rawSet(a, .{ .string = "left" }, .{ .table = left });
    try child.rawSet(a, .{ .string = "right" }, .{ .table = right });
    const meta = try ctx.newTable();
    try meta.rawSet(a, .{ .string = "__index" }, try ctx.newNative(null, Poison.call));
    child.metatable = meta;
    try ctx.preinitializeModule(0, .{ .table = left }, false);
    try ctx.preinitializeModule(1, .{ .table = right }, false);
    const left_guard = ctx.moduleValueSentinel(0, .{ .table = left }).?;
    var delayed: Value = undefined;
    const right_guard = ctx.deferStaticRequireRef(1, &delayed).?;
    try std.testing.expect(left_guard.* and right_guard.*);
    try std.testing.expectEqual(@as(usize, 2), child.export_guard_parents.len);
    const parents = child.export_guard_parents.ptr;
    for (0..16) |_| {
        try std.testing.expect(ctx.moduleStateConst(0).?.template_value_guard.pristine());
        try std.testing.expect(ctx.moduleStateConst(1).?.template_value_guard.pristine());
        try std.testing.expect(child.export_guard_parents.ptr == parents);
    }
    var journal = InvokeRollbackJournal.init(a, &ctx);
    journal.begin();
    try child.rawSetSlot(0, .{ .boolean = false });
    try std.testing.expect(!left_guard.* and !right_guard.*);
    try std.testing.expect(child.rawGetSlot(0).?.boolean == false);
    try child.rawSetSlot(0, .nil);
    try std.testing.expect(child.rawGetSlot(0) == null);
    journal.rollback(&ctx);
    try std.testing.expect(left_guard.* and right_guard.*);
    try std.testing.expectEqual(@as(f64, 7), child.rawGetSlot(0).?.number);
    try std.testing.expect(child.rawGet(.{ .string = "left" }).?.table == left);
    try std.testing.expect(child.rawGet(.{ .string = "right" }).?.table == right);
    try meta.rawSet(a, .{ .string = "changed" }, .{ .number = 1 });
    try std.testing.expect(!left_guard.* and !right_guard.*);
}

test "export graph guards inspect captured cells without disabling pure closure templates" {
    const F = struct {
        fn call(_: *Context, captures: Captures, _: []const Value) ![]const Value {
            return BetweenProbeDependencyFixture.result((try captures.cell(0)).value);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.initProgram(a, 0, 1);
    defer ctx.deinit();
    const cell = try ctx.newCell(.{ .number = 7 });
    const callable = try ctx.makeFunctionKnown(0, F.call, &.{cell});
    try ctx.preinitializeModule(0, callable, false);
    const guard = ctx.moduleStateConst(0).?.template_value_guard;
    try std.testing.expect(guard.pristine());
    cell.value = .{ .boolean = false };
    try std.testing.expect(!guard.pristine());
    const actual = try ctx.callValue(callable, &.{});
    defer freeResults(actual);
    try std.testing.expectEqualDeep(Value{ .boolean = false }, actual[0]);
    cell.value = .nil;
    try std.testing.expect(!guard.pristine());
    cell.value = .{ .number = 7 };
    try std.testing.expect(guard.pristine());
}

test "descendant guard records survive destroyed roots and reject foreign mutable ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.initProgram(a, 0, 2);
    defer ctx.deinit();
    const child = try ctx.newTable();
    try child.rawSet(a, .{ .string = "x" }, .{ .number = 7 });
    const root = try ctx.newTable();
    try root.rawSet(a, .{ .string = "child" }, .{ .table = child });
    _ = try ctx.prepareModuleValueGuard(.{ .table = root });
    const retired = root.export_guard_root.?;
    try std.testing.expect(child.export_guard_parents[0] == retired);
    ctx.destroyTable(root);
    try std.testing.expect(retired.table == null);
    try child.rawSet(a, .{ .string = "x" }, .{ .number = 19 });
    try std.testing.expectEqual(@as(f64, 19), child.rawGet(.{ .string = "x" }).?.number);
    const survivor = try ctx.newTable();
    try survivor.rawSet(a, .{ .string = "child" }, .{ .table = child });
    const surviving_guard = try ctx.prepareModuleValueGuard(.{ .table = survivor });
    try std.testing.expect(surviving_guard.pristine());
    try child.rawSet(a, .{ .string = "x" }, .nil);
    try std.testing.expect(!surviving_guard.pristine());
    var foreign = try Context.init(a, 0);
    defer foreign.deinit();
    const borrowed = try foreign.newTable();
    const owner = try ctx.newTable();
    try owner.rawSet(a, .{ .string = "borrowed" }, .{ .table = borrowed });
    const unproved = try ctx.prepareModuleValueGuard(.{ .table = owner });
    try std.testing.expect(!unproved.pristine());
    try std.testing.expectEqual(@as(usize, 0), borrowed.export_guard_parents.len);
    try std.testing.expect(!(try ctx.prepareModuleValueGuard(.{ .table = borrowed })).pristine());
}

const UpstreamOverrideGuardFixture = struct {
    fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
        return error.TestUnexpectedResult;
    }
    fn requirements(_: ?*const anyopaque, id: u32) []const ModuleRequirement {
        return if (id == 1) &.{.{ .module_id = 0, .requested = "Module:Dependency" }} else &.{};
    }
    fn table(ctx: *Context, number: f64) !Value {
        const out = try ctx.newTable();
        try out.rawSet(ctx.allocator, .{ .string = "x" }, .{ .number = number });
        return .{ .table = out };
    }
    fn run(backing: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const a = arena.allocator();
        const roots: [2]FunctionFn = @splat(stabilize(root));
        var worker = try Context.initProgram(a, 0, 2);
        defer worker.deinit();
        var worker_eligible = [_]bool{ true, false };
        var worker_rejected = [_]bool{ false, false };
        worker.module_root_entries = &roots;
        worker.module_template_eligible = &worker_eligible;
        worker.module_template_rejected = &worker_rejected;
        worker.configureModuleRequirements(null, requirements);
        const baseline = try table(&worker, 7);
        try worker.preinitializeModule(0, baseline, false);
        var page = try worker.forkProgram(a);
        defer page.deinit();
        var page_eligible = [_]bool{ true, true };
        var page_rejected = [_]bool{ false, false };
        page.module_template_context = &worker;
        page.module_template_eligible = &page_eligible;
        page.module_template_rejected = &page_rejected;
        try page.preinitializeModule(0, try table(&page, 7), false);
        const overridden = try table(&page, 19);
        const exported = try page.newTable();
        try exported.rawSet(a, .{ .string = "dependency" }, overridden);
        try page.preinitializeModule(1, .{ .table = exported }, false);
        const effects = [_]ModuleTemplateOverride{.{ .module_id = 0, .value = overridden }};
        page.moduleState(1).?.template_overrides = &effects;
        const promoted = page.promoteModuleTemplateUpstream(1, null) catch |err| {
            if (err == error.OutOfMemory) {
                try std.testing.expect(!worker_eligible[1]);
                if (worker.moduleStateConst(1)) |state| try std.testing.expect(state.value == null);
            }
            return err;
        };
        try std.testing.expect(promoted and worker_eligible[1]);
        try std.testing.expect(rawEqual(baseline, worker.preparedModuleValue(0).?));
        try std.testing.expectEqual(@as(f64, 7), baseline.table.rawGet(.{ .string = "x" }).?.number);
        const prototype = worker.moduleStateConst(1).?;
        try std.testing.expectEqual(@as(usize, 1), prototype.template_overrides.len);
        const retained = prototype.template_overrides[0].value;
        try std.testing.expect(rawEqual(retained, prototype.value.?.table.rawGet(.{ .string = "dependency" }).?));
        try std.testing.expectEqual(@as(f64, 19), retained.table.rawGet(.{ .string = "x" }).?.number);
        var live = try worker.forkProgram(a);
        defer live.deinit();
        live.module_template_context = &worker;
        const creator = try live.loadModule(1, null);
        const dependency = try live.loadModule(0, null);
        try std.testing.expect(rawEqual(dependency, creator.table.rawGet(.{ .string = "dependency" }).?));
        try std.testing.expectEqual(@as(f64, 19), dependency.table.rawGet(.{ .string = "x" }).?.number);
        try std.testing.expect(live.moduleStateConst(0).?.template_origin_context == null);
        var independent = try worker.forkProgram(a);
        defer independent.deinit();
        independent.module_template_context = &worker;
        try std.testing.expectEqual(@as(f64, 7), (try independent.loadModule(0, null)).table.rawGet(.{ .string = "x" }).?.number);
        // Applying an override carries its creator's observations in addition
        // to the original dependency owner's observations.
        worker.moduleState(0).?.template_library_dependencies = 2;
        worker.moduleState(1).?.template_library_dependencies = 4;
        var checked = try worker.forkProgram(a);
        defer checked.deinit();
        var clone = Context.ModuleTemplateClone{ .source = &worker, .target = &checked };
        defer clone.deinit();
        try clone.applyTemplateOverrides(prototype.template_overrides, prototype);
        try std.testing.expectEqual(@as(u64, 6), checked.moduleStateConst(0).?.template_library_dependencies);
        try std.testing.expect(checked.moduleStateConst(0).?.template_origin_context == null);
    }
};

test "upstream promotion retains creator overrides without replacing dependency prototypes" {
    try UpstreamOverrideGuardFixture.run(std.testing.allocator);
}

test "dependency guard allocation failures preserve failed promotion and release owned state" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), UpstreamOverrideGuardFixture.run, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "export guard registration uses heap worklists for deep table and closure chains" {
    const F = struct {
        fn call(_: *Context, captures: Captures, _: []const Value) ![]const Value {
            return BetweenProbeDependencyFixture.result((try captures.cell(0)).value);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try Context.initProgram(a, 0, 1);
    defer ctx.deinit();
    const root = try ctx.newTable();
    var tail = root;
    for (0..16384) |_| {
        const next = try ctx.newTable();
        try tail.rawSet(a, .{ .string = "child" }, .{ .table = next });
        tail = next;
    }
    const terminal_cell = try ctx.newCell(.{ .number = 7 });
    var callable = try ctx.makeFunctionKnown(0, F.call, &.{terminal_cell});
    for (0..16384) |_| {
        const cell = try ctx.newCell(callable);
        callable = try ctx.makeFunctionKnown(0, F.call, &.{cell});
    }
    try tail.rawSet(a, .{ .string = "closure" }, callable);
    const graph_guard = try ctx.prepareModuleValueGuard(.{ .table = root });
    const callable_guard = try ctx.prepareModuleValueGuard(callable);
    try std.testing.expect(graph_guard.pristine() and callable_guard.pristine());
    try std.testing.expectEqual(@as(usize, 16385), root.export_capture_baselines.len);
    try std.testing.expectEqual(@as(usize, 16385), callable_guard.capture_cells.len);
    try std.testing.expectEqual(@as(usize, 1), tail.export_guard_parents.len);
    try std.testing.expect(tail.export_guard_parents[0].table == root);
    terminal_cell.value = .{ .boolean = false };
    try std.testing.expect(!graph_guard.pristine() and !callable_guard.pristine());
    terminal_cell.value = .{ .number = 7 };
    try std.testing.expect(graph_guard.pristine() and callable_guard.pristine());
    try tail.rawSet(a, .{ .string = "x" }, .{ .number = 19 });
    try std.testing.expect(!graph_guard.pristine() and callable_guard.pristine());
}

test "rejected and effectful ordinary roots keep deep values without registering cache guards" {
    const F = struct {
        const module_name = "Module:DeepOrdinary";
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            return if (std.mem.eql(u8, raw_name, module_name)) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) module_name else null;
        }
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            const value = try ctx.newTable();
            var tail = value;
            for (0..16384) |_| {
                const next = try ctx.newTable();
                try tail.rawSet(ctx.allocator, .{ .string = "child" }, .{ .table = next });
                tail = next;
            }
            try tail.rawSet(ctx.allocator, .{ .string = "x" }, .{ .number = 19 });
            // A real invocation-global write makes the active initializer uncacheable.
            try ctx.global_table.?.rawSet(ctx.allocator, .{ .string = "changed" }, .{ .boolean = true });
            return BetweenProbeDependencyFixture.result(.{ .table = value });
        }
    };
    for ([_]bool{ false, true }) |previously_rejected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var template = try Context.initProgram(a, 1, 1);
        defer template.deinit();
        const roots = [_]FunctionFn{stabilize(F.root)};
        template.module_root_entries = &roots;
        template.configureModules(null, F.lookup, F.name);
        var eligible = [_]bool{false};
        var rejected = [_]bool{previously_rejected};
        template.module_template_eligible = &eligible;
        template.module_template_rejected = &rejected;
        var live = try template.forkProgram(a);
        defer live.deinit();
        live.module_template_context = &template;
        live.package_loaded = try live.newTable();
        try bindGlobalTable(&live, null, 0);
        const value = try live.requireByName(F.module_name);
        try std.testing.expect(rejected[0] and !eligible[0]);
        try std.testing.expect(!live.moduleStateConst(0).?.template_value_guard.pristine());
        try std.testing.expect(template.moduleStateConst(0) == null);
        try std.testing.expect(live.global_table.?.rawGet(.{ .string = "changed" }).?.boolean);
        var tail = value.table;
        var depth: usize = 0;
        while (true) {
            try std.testing.expect(!tail.export_guard_graph_ready and tail.export_guard_root == null);
            try std.testing.expectEqual(@as(usize, 0), tail.export_guard_parents.len);
            const next = tail.rawGet(.{ .string = "child" }) orelse break;
            tail = next.table;
            depth += 1;
        }
        try std.testing.expectEqual(@as(usize, 16384), depth);
        try std.testing.expectEqual(@as(f64, 19), tail.rawGet(.{ .string = "x" }).?.number);
        try std.testing.expect(rawEqual(value, try live.requireByName(F.module_name)));
    }
}

test "cached require avoids unused lookup but preserves active dependency and mutation observation" {
    const F = struct {
        calls: usize = 0,
        fn lookup(raw: ?*const anyopaque, raw_name: []const u8) ?u32 {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw.?)));
            self.calls += 1;
            return if (std.mem.eql(u8, raw_name, "Module:CachedAlias")) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) "Module:Cached" else null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var probe: F = .{};
    var ctx = try Context.initProgram(a, 0, 1);
    defer ctx.deinit();
    ctx.configureModules(&probe, F.lookup, F.name);
    const value = try ctx.newTable();
    try value.rawSet(a, .{ .string = "field" }, .{ .number = 7 });
    try ctx.preinitializeModule(0, .{ .table = value }, false);
    ctx.package_loaded = try ctx.newTable();
    try ctx.package_loaded.?.rawSet(a, .{ .string = "Module:CachedAlias" }, .{ .table = value });
    try ctx.package_loaded.?.rawSet(a, .{ .string = "arbitrary" }, .{ .number = 0 });
    try std.testing.expect((try ctx.requireByName("Module:CachedAlias")).table == value);
    try std.testing.expectEqual(@as(f64, 0), (try ctx.requireByName("arbitrary")).number);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    var observed = false;
    const previous = beginModuleTemplateEffectProbe(&observed, false);
    defer endModuleTemplateEffectProbe(previous, observed);
    var dependencies = ModuleTemplateDependencyProbe{ .ctx = &ctx };
    defer dependencies.requirements.deinit(std.heap.smp_allocator);
    const saved_dependency_probe = module_template_dependency_probe;
    module_template_dependency_probe = &dependencies;
    defer module_template_dependency_probe = saved_dependency_probe;
    try std.testing.expect((try ctx.requireByName("Module:CachedAlias")).table == value);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(!observed);
    try std.testing.expectEqual(@as(usize, 1), dependencies.requirements.items.len);
    try std.testing.expectEqual(@as(u32, 0), dependencies.requirements.items[0].module_id);
    try std.testing.expectEqualStrings("Module:CachedAlias", dependencies.requirements.items[0].requested);
    try value.rawSet(a, .{ .string = "field" }, .{ .boolean = false });
    observed = false;
    try std.testing.expect((try ctx.requireByName("Module:CachedAlias")).table == value);
    try std.testing.expect(observed);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), dependencies.requirements.items.len);
    observed = false;
    try std.testing.expectEqual(@as(f64, 0), (try ctx.requireByName("arbitrary")).number);
    try std.testing.expect(observed);
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

test "captured override identity does not excuse post capture descendant mutation" {
    const F = BetweenProbeDependencyFixture;
    for ([_]bool{ false, true }) |mutate_after_capture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var probe: F = .{};
        var eligible = [_]bool{ true, true, false };
        var rejected = [_]bool{ false, false, false };
        var source = try probe.init(a, &eligible, &rejected);
        defer source.deinit();
        const nested = try source.newTable();
        try nested.rawSet(a, .{ .string = "x" }, .{ .number = 19 });
        const dependency = try source.newTable();
        try dependency.rawSet(a, .{ .string = "child" }, .{ .table = nested });
        try source.preinitializeModule(0, .{ .table = dependency }, false);
        const consumer = try source.newTable();
        try consumer.rawSet(a, .{ .string = "saved" }, .{ .number = 19 });
        try source.preinitializeModule(1, .{ .table = consumer }, false);
        const requirements = [_]ModuleRequirement{.{ .module_id = 0, .requested = "Module:GuardAlias" }};
        source.moduleState(1).?.template_observed_requirements = &requirements;
        const overrides = [_]ModuleTemplateOverride{.{ .module_id = 0, .value = .{ .table = dependency } }};
        source.moduleState(1).?.template_overrides = &overrides;
        try std.testing.expect(source.moduleStateConst(0).?.template_value_guard.pristine());
        if (mutate_after_capture) try nested.rawSet(a, .{ .string = "x" }, .{ .number = 31 });
        try std.testing.expectEqual(!mutate_after_capture, source.moduleStateConst(0).?.template_value_guard.pristine());
        try std.testing.expect(rawEqual(overrides[0].value, source.preparedModuleValue(0).?));
        try std.testing.expectEqual(@as(f64, 19), consumer.rawGet(.{ .string = "saved" }).?.number);
        var live = try F.fork(&source, a);
        defer live.deinit();
        const expected: f64 = if (mutate_after_capture) 31 else 19;
        const actual = try live.requireByName(F.names[1]);
        const actual_dependency = try live.requireByName(F.names[0]);
        try std.testing.expectEqual(expected, F.saved(actual).number);
        try std.testing.expectEqual(expected, F.child(actual_dependency).rawGet(.{ .string = "x" }).?.number);
        try std.testing.expectEqualSlices(usize, &.{ 0, if (mutate_after_capture) 1 else 0 }, &probe.calls);
        try std.testing.expectEqual(@as(f64, 19), consumer.rawGet(.{ .string = "saved" }).?.number);
        try std.testing.expect(actual.table != consumer and actual_dependency.table != dependency);
        try std.testing.expect(!source.moduleStateConst(1).?.loading);
    }
}

test "ordinary promotion captures dependency cycles before sealing and retains distinct mutation owners" {
    const F = struct {
        calls: [2]usize = .{ 0, 0 },
        fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
            if (std.mem.eql(u8, raw_name, "Module:CycleRoot")) return 0;
            if (std.mem.eql(u8, raw_name, "Module:CycleDep")) return 1;
            return null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return switch (id) { 0 => "Module:CycleRoot", 1 => "Module:CycleDep", else => null };
        }
        fn requirements(_: ?*const anyopaque, id: u32) []const ModuleRequirement {
            return if (id == 0) &.{.{ .module_id = 1, .requested = "Module:CycleDep" }} else &.{};
        }
        fn fixture(ctx: *Context) *@This() {
            return @ptrCast(@alignCast(@constCast(ctx.module_lookup_ctx.?)));
        }
        fn dependency(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            fixture(ctx).calls[1] += 1;
            const table = try ctx.newTable();
            try table.rawSet(ctx.allocator, .{ .string = "value" }, .{ .number = 1 });
            return BetweenProbeDependencyFixture.result(.{ .table = table });
        }
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            fixture(ctx).calls[0] += 1;
            const dep = try ctx.loadModule(1, "Module:CycleDep");
            try dep.table.rawSet(ctx.allocator, .{ .string = "value" }, .{ .number = 2 });
            const table = try ctx.newTable();
            try table.rawSet(ctx.allocator, .{ .string = "dependency" }, dep);
            try dep.table.rawSet(ctx.allocator, .{ .string = "back" }, .{ .table = table });
            return BetweenProbeDependencyFixture.result(.{ .table = table });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var probe: F = .{};
    var template = try Context.initProgram(a, 0, 2);
    defer template.deinit();
    const roots = [_]FunctionFn{ stabilize(F.root), stabilize(F.dependency) };
    template.module_root_entries = &roots;
    template.configureModules(&probe, F.lookup, F.name);
    template.configureModuleRequirements(null, F.requirements);
    var eligible = [_]bool{ false, false };
    var rejected = [_]bool{ false, false };
    template.module_template_eligible = &eligible;
    template.module_template_rejected = &rejected;
    for (0..2) |iteration| {
        var live = try template.forkProgram(a);
        defer live.deinit();
        live.module_template_context = &template;
        live.package_loaded = try live.newTable();
        const creator = try live.requireByName("Module:CycleRoot");
        const dep = try live.requireByName("Module:CycleDep");
        try std.testing.expect(creator.table.rawGet(.{ .string = "dependency" }).?.table == dep.table);
        try std.testing.expect(dep.table.rawGet(.{ .string = "back" }).?.table == creator.table);
        try std.testing.expectEqual(@as(f64, 2), dep.table.rawGet(.{ .string = "value" }).?.number);
        try std.testing.expect(creator.table.module_template_mutation_probe == &live.moduleState(0).?.template_mutation_probe_id);
        try std.testing.expect(dep.table.module_template_mutation_probe == &live.moduleState(1).?.template_mutation_probe_id);
        try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &probe.calls);
        try std.testing.expect(eligible[0] and eligible[1] and !rejected[0] and !rejected[1]);
        const prototype = template.moduleStateConst(0).?;
        try std.testing.expectEqual(@as(usize, 1), prototype.template_overrides.len);
        const captured = prototype.template_overrides[0];
        try std.testing.expectEqual(@as(u32, 1), captured.module_id);
        try std.testing.expect(captured.value.table.rawGet(.{ .string = "back" }).?.table == prototype.value.?.table);
        try std.testing.expectEqual(@as(f64, 2), captured.value.table.rawGet(.{ .string = "value" }).?.number);
        const baseline = template.preparedModuleValue(1).?.table;
        try std.testing.expectEqual(@as(f64, 1), baseline.rawGet(.{ .string = "value" }).?.number);
        try std.testing.expect(baseline.rawGet(.{ .string = "back" }) == null);
        if (iteration == 1) {
            var observed = false;
            const previous = beginModuleTemplateEffectProbe(&observed, true);
            defer endModuleTemplateEffectProbe(previous, observed);
            try dep.table.rawSet(a, .{ .string = "value" }, .{ .number = 3 });
            const mutations = try live.moduleTemplateProbeModules(a, module_template_probe_id, 0);
            defer a.free(mutations);
            try std.testing.expectEqualSlices(u32, &.{1}, mutations);
            try std.testing.expectEqual(@as(f64, 2), captured.value.table.rawGet(.{ .string = "value" }).?.number);
        }
    }
}

test "module template alias keys outlive requested scratch in promotion and instantiation" {
    const F = struct {
        const canonical: []const u8 = "Module:AliasLifetime";
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) canonical else null;
        }
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.TestUnexpectedResult;
        }
    };
    for ([_]bool{ false, true }) |promotion| {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer target_arena.deinit();
        var source = try Context.initProgram(source_arena.allocator(), 0, 1);
        defer source.deinit();
        var target = try Context.initProgram(target_arena.allocator(), 0, 1);
        defer target.deinit();
        const roots = [_]FunctionFn{stabilize(F.root)};
        source.module_root_entries = &roots;
        target.module_root_entries = &roots;
        source.module_name = F.name;
        target.module_name = F.name;
        var eligible = [_]bool{true};
        target.module_template_eligible = &eligible;
        (try source.ensureModuleState(0)).value = .{ .number = 42 };
        const shape = Shape{ .keys = .{ .strings = &.{} }, .field_count = 0, .choice_count = 1 };
        target.package_loaded = try target.newShapedTable(&shape);
        const choice_key = try target.ownString("Alias:ChoiceLifetime");
        try target.package_loaded.?.rawSetChoice(0, .{ .string = choice_key }, .{ .number = 41 });
        var clone = Context.ModuleTemplateClone{
            .source = &source,
            .target = &target,
            .promotion = promotion,
        };
        defer clone.deinit();
        {
            var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer scratch.deinit();
            const first = try scratch.allocator().dupe(u8, "Alias:FirstLifetime");
            const second = try scratch.allocator().dupe(u8, "Alias:SecondLifetime");
            const choice_alias = try scratch.allocator().dupe(u8, "Alias:ChoiceLifetime");
            const initial = try clone.cloneModule(0, first);
            const reused = try clone.cloneModule(0, second);
            const changed_choice = try clone.cloneModule(0, choice_alias);
            try std.testing.expect(rawEqual(initial, reused));
            try std.testing.expect(rawEqual(initial, changed_choice));
            try std.testing.expect(target.package_loaded.?.choices[0].key.string.ptr == choice_key.ptr);
            try std.testing.expect(target.package_loaded.?.choices[0].key.string.ptr != choice_alias.ptr);
            var iterator = target.package_loaded.?.iterator();
            var alias_count: usize = 0;
            while (iterator.next()) |entry| {
                if (entry.key_ptr.* != .string) continue;
                const key = entry.key_ptr.string;
                if (std.mem.startsWith(u8, key, "Alias:")) {
                    try std.testing.expect(key.ptr != first.ptr and key.ptr != second.ptr and key.ptr != choice_alias.ptr);
                    alias_count += 1;
                } else if (std.mem.eql(u8, key, F.canonical)) {
                    try std.testing.expect(key.ptr == F.canonical.ptr);
                }
            }
            try std.testing.expectEqual(@as(usize, 3), alias_count);
            @memset(first, '!');
            @memset(second, '?');
            @memset(choice_alias, '%');
            try std.testing.expect(rawEqual(initial, target.package_loaded.?.rawGet(.{ .string = "Alias:ChoiceLifetime" }).?));
            try std.testing.expect(rawEqual(initial, target.package_loaded.?.rawGet(.{ .string = "Alias:FirstLifetime" }).?));
            try std.testing.expect(rawEqual(initial, target.package_loaded.?.rawGet(.{ .string = "Alias:SecondLifetime" }).?));
        }
        const capacity_before = target.package_loaded.?.map.capacity();
        for (0..128) |index| {
            var buffer: [64]u8 = undefined;
            const alias = try std.fmt.bufPrint(&buffer, "Alias:Grow-{d}", .{index});
            _ = try clone.cloneModule(0, alias);
            @memset(alias, '#');
        }
        try std.testing.expect(target.package_loaded.?.map.capacity() > capacity_before);
        for ([_][]const u8{ F.canonical, "Alias:FirstLifetime", "Alias:SecondLifetime", "Alias:ChoiceLifetime", "Alias:Grow-0", "Alias:Grow-127" }) |name| {
            try std.testing.expectEqual(@as(f64, 42), target.package_loaded.?.rawGet(.{ .string = name }).?.number);
            try std.testing.expect(rawEqual(target.moduleStateConst(0).?.value.?, target.package_loaded.?.rawGet(.{ .string = name }).?));
        }
    }
}

test "ordinary require owns aliases and requested canonical fallback without changing cache identity" {
    const F = struct {
        const canonical: []const u8 = "Module:OwnedAlias";
        const alias: []const u8 = "Alias:OwnedAlias";
        fn lookup(_: ?*const anyopaque, requested_name: []const u8) ?u32 {
            return if (std.mem.eql(u8, requested_name, canonical) or std.mem.eql(u8, requested_name, alias)) 0 else null;
        }
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) canonical else null;
        }
        fn root(ctx: *Context, _: Captures, _: []const Value) ![]const Value {
            const calls: f64 = if (ctx.getGlobal(0) == .number) ctx.getGlobal(0).number else 0;
            try ctx.setGlobal(0, .{ .number = calls + 1 });
            const result = try std.heap.smp_allocator.alloc(Value, 1);
            result[0] = .{ .number = 42 };
            return result;
        }
    };
    for ([_]bool{ false, true }) |has_canonical_name| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ctx = try Context.initProgram(arena.allocator(), 1, 1);
        defer ctx.deinit();
        const roots = [_]FunctionFn{stabilize(F.root)};
        ctx.module_root_entries = &roots;
        ctx.module_lookup = F.lookup;
        ctx.module_name = if (has_canonical_name) F.name else null;
        ctx.package_loaded = try ctx.newTable();
        {
            var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer scratch.deinit();
            const requested = try scratch.allocator().dupe(u8, F.alias);
            try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName(requested)).number);
            var iterator = ctx.package_loaded.?.iterator();
            var found_alias = false;
            while (iterator.next()) |entry| {
                if (entry.key_ptr.* == .string and std.mem.eql(u8, entry.key_ptr.string, F.alias)) {
                    try std.testing.expect(entry.key_ptr.string.ptr != requested.ptr);
                    found_alias = true;
                }
            }
            try std.testing.expect(found_alias);
            @memset(requested, '!');
            try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName(F.alias)).number);
        }
        const capacity_before = ctx.package_loaded.?.map.capacity();
        for (0..128) |index| {
            var buffer: [64]u8 = undefined;
            const key = try std.fmt.bufPrint(&buffer, "unrelated-{d}", .{index});
            try ctx.packageLoadedRequestedSet(key, .{ .number = @floatFromInt(index) });
            @memset(key, '#');
        }
        try std.testing.expect(ctx.package_loaded.?.map.capacity() > capacity_before);
        try std.testing.expectEqual(@as(f64, 42), (try ctx.requireByName(F.alias)).number);
        if (has_canonical_name) {
            try std.testing.expect(rawEqual(try ctx.requireByName(F.canonical), try ctx.requireByName(F.alias)));
        }
        try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
        try std.testing.expectEqual(@as(f64, 42), ctx.moduleStateConst(0).?.value.?.number);
    }
}

test "alias ownership allocation failure preserves promotion rollback and existing cache keys" {
    const F = struct {
        const canonical: []const u8 = "Module:AliasAllocation";
        fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
            return if (id == 0) canonical else null;
        }
        fn root(_: *Context, _: Captures, _: []const Value) ![]const Value {
            return error.TestUnexpectedResult;
        }
    };
    const saved_failure = module_template_allocation_failed;
    defer module_template_allocation_failed = saved_failure;
    for ([_]bool{ false, true }) |upstream| {
        module_template_allocation_failed = false;
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        var target_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer target_arena.deinit();
        const target_allocator = target_arena.allocator();
        var target = try Context.initProgram(target_allocator, 0, 1);
        defer target.deinit();
        target.useContextAllocatorForStrings();
        var source = try Context.initProgram(source_arena.allocator(), 0, 1);
        defer source.deinit();
        const roots = [_]FunctionFn{stabilize(F.root)};
        target.module_root_entries = &roots;
        source.module_root_entries = &roots;
        target.module_name = F.name;
        source.module_name = F.name;
        var eligible = [_]bool{false};
        var rejected = [_]bool{false};
        target.module_template_eligible = &eligible;
        target.module_template_rejected = &rejected;
        source.module_template_eligible = &eligible;
        source.module_template_rejected = &rejected;
        source.module_template_context = &target;
        (try source.ensureModuleState(0)).value = .{ .number = 42 };
        (try target.ensureModuleState(0)).value = .{ .number = 42 };
        const keys = [_][]const u8{ F.canonical, "Alias:StaticNil" };
        const shape = Shape{ .keys = .{ .strings = &keys }, .field_count = keys.len, .choice_count = 1 };
        target.package_loaded = try target.newShapedTable(&shape);
        try target.packageLoadedModuleSet(0, null, .{ .number = 42 });
        try target.packageLoadedRequestedSet("Alias:Existing", .{ .number = 7 });
        const choice_key = try target.ownString("Alias:ChoiceExisting");
        try target.package_loaded.?.rawSetChoice(0, .{ .string = choice_key }, .{ .number = 10 });
        try target.packageLoadedRequestedSet("Alias:Tombstone", .{ .number = 11 });
        try target.packageLoadedRequestedSet("Alias:Tombstone", .nil);
        try std.testing.expect(target.package_loaded.?.map.getPtrContext(.{ .string = "Alias:Tombstone" }, .{}) != null);
        var failing = std.testing.FailingAllocator.init(target_allocator, .{ .fail_index = 0 });
        target.allocator = failing.allocator();
        defer target.allocator = target_allocator;
        try target.packageLoadedModuleSet(0, null, .{ .number = 42 });
        try target.packageLoadedRequestedSet("Alias:Existing", .{ .number = 8 });
        try target.packageLoadedRequestedSet("Alias:StaticNil", .{ .number = 12 });
        try target.packageLoadedRequestedSet("Alias:Tombstone", .{ .number = 13 });
        var choice_request = "Alias:ChoiceExisting".*;
        try target.packageLoadedRequestedSet(&choice_request, .{ .number = 14 });
        @memset(&choice_request, '!');
        try std.testing.expect(target.package_loaded.?.choices[0].key.string.ptr == choice_key.ptr);
        try std.testing.expectEqual(@as(f64, 12), target.package_loaded.?.rawGet(.{ .string = "Alias:StaticNil" }).?.number);
        try std.testing.expectEqual(@as(f64, 13), target.package_loaded.?.rawGet(.{ .string = "Alias:Tombstone" }).?.number);
        try std.testing.expectEqual(@as(f64, 14), target.package_loaded.?.rawGet(.{ .string = "Alias:ChoiceExisting" }).?.number);
        try target.packageLoadedRequestedSet("Alias:Absent", .nil);
        try std.testing.expectEqual(@as(f64, 8), target.package_loaded.?.rawGet(.{ .string = "Alias:Existing" }).?.number);
        const count_before = target.package_loaded.?.map.count();
        try std.testing.expectError(error.OutOfMemory, target.packageLoadedRequestedSet("Alias:Fresh", .{ .number = 9 }));
        try std.testing.expectEqual(count_before, target.package_loaded.?.map.count());
        try std.testing.expect(target.package_loaded.?.rawGet(.{ .string = "Alias:Fresh" }) == null);
        try std.testing.expect(!moduleTemplateAllocationFailed());
        if (upstream) {
            try std.testing.expectError(error.OutOfMemory, source.promoteModuleTemplateUpstream(0, "Alias:Fresh"));
        } else {
            try std.testing.expectError(error.OutOfMemory, source.promoteModuleTemplate(0, "Alias:Fresh"));
        }
        try std.testing.expect(moduleTemplateAllocationFailed());
        try std.testing.expect(!eligible[0] and rejected[0]);
        try std.testing.expect(target.moduleStateConst(0).?.value == null);
        try std.testing.expect(target.package_loaded.?.rawGet(.{ .string = F.canonical }) == null);
        try std.testing.expect(target.package_loaded.?.rawGet(.{ .string = "Alias:Fresh" }) == null);
        try std.testing.expectEqual(@as(f64, 8), target.package_loaded.?.rawGet(.{ .string = "Alias:Existing" }).?.number);
        try std.testing.expectEqual(@as(f64, 42), source.moduleStateConst(0).?.value.?.number);
    }
}
