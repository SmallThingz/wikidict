const std = @import("std");
pub const work_stats = @import("work_stats.zig");
const static_fields = @import("lua_static_fields");

extern fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;

pub const Cell = struct { value: Value };
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

    pub fn captures(self: FunctionValue) Captures {
        if (self.id == native_function_id) return .{ .native = self.env.nativePtr() };
        if (self.env.closurePtr()) |env| return env.capture_view;
        return .{ .direct = &.{} };
    }

    pub fn capturesPtr(self: FunctionValue) ?*const Captures {
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
    callable: FunctionValue,

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
    bytes: [stable_error_name_capacity]u8 = [_]u8{0} ** stable_error_name_capacity,
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
    field_keys: []const Value = &.{},
    sorted_string_slots: []const u32 = &.{},
    field_count: u32 = 0,
    choice_count: u32 = 0,
    open: bool = false,
};

fn shapeStringSlot(shape: *const Shape, name: []const u8) ?u32 {
    if (shape.field_keys.len != shape.field_count or shape.sorted_string_slots.len != shape.field_keys.len) return null;
    var low: usize = 0;
    var high = shape.sorted_string_slots.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const slot = shape.sorted_string_slots[mid];
        if (slot >= shape.field_keys.len or shape.field_keys[slot] != .string) return null;
        switch (std.mem.order(u8, name, shape.field_keys[slot].string)) {
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
    bytes[0] = @intFromEnum(std.meta.Tag(Value).number);
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

fn stringValueHash(text: []const u8) u64 {
    const tag: u8 = @intFromEnum(std.meta.Tag(Value).string);
    if (text.len <= 63) {
        var bytes: [64]u8 = undefined;
        bytes[0] = tag;
        @memcpy(bytes[1..][0..text.len], text);
        return std.hash.Wyhash.hash(0, bytes[0 .. text.len + 1]);
    }
    var h = std.hash.Wyhash.init(0);
    h.update(&.{tag});
    h.update(text);
    return h.final();
}

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
        const tag: u8 = @intFromEnum(std.meta.activeTag(value));
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

    fn snapshot(allocator: std.mem.Allocator, values: []const Value) !*GlobalTail {
        const self = try allocator.create(GlobalTail);
        errdefer allocator.destroy(self);
        const pages = try allocator.alloc(?*GlobalPage, values.len / global_page_len + @intFromBool(values.len % global_page_len != 0));
        @memset(pages, null);
        self.* = .{ .allocator = allocator, .len = values.len, .pages = pages };
        errdefer self.deinit();
        for (pages, 0..) |*page, page_index| {
            const start = page_index * global_page_len;
            const source = values[start..@min(start + global_page_len, values.len)];
            for (source) |value| {
                if (value != .nil) {
                    const owned = try allocator.create(GlobalPage);
                    owned.* = [_]Value{.nil} ** global_page_len;
                    @memcpy(owned[0..source.len], source);
                    page.* = owned;
                    break;
                }
            }
        }
        return self;
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
            page.* = [_]Value{.nil} ** global_page_len;
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
    choices: []ChoiceCell = &.{},
    map: Map = .empty,
    metatable: ?*Table = null,
    append_index: u32 = 1,
    read_only: bool = false,
    mutation_sentinel: ?*bool = null,
    // Monotonic: only tables that have ever hashed a numeric key need numeric map probes.
    has_hashed_number: bool = false,
    // Identity-key iteration may depend on arena addresses or function allocation order.
    has_identity_key: bool = false,

    fn markMutated(self: *Table) void {
        if (self.mutation_sentinel) |sentinel| sentinel.* = false;
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
        if (self.owns_slots and self.slots.len != 0) allocator.free(self.slots);
        if (self.choices.len != 0) allocator.free(self.choices);
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

    fn slotForKey(self: *const Table, key: Value) ?u32 {
        if (key == .string) if (self.native_namespace) |namespace|
            return static_fields.slotForName(namespace, key.string);
        const shape = self.shape orelse return null;
        if (shape.field_keys.len != shape.field_count) return null;
        if (key == .string and shape.sorted_string_slots.len == shape.field_keys.len)
            return shapeStringSlot(shape, key.string);
        for (shape.field_keys, 0..) |field_key, slot| {
            if (rawEqual(field_key, key)) return @intCast(slot);
        }
        return null;
    }
    pub fn fieldKey(self: *const Table, slot: u32) ?Value {
        if (self.native_namespace) |namespace| {
            return .{ .string = static_fields.nameAt(namespace, slot) orelse return null };
        }
        const shape = self.shape orelse return null;
        if (shape.field_keys.len != shape.field_count or slot >= shape.field_count) return null;
        return shape.field_keys[slot];
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
        const grown = if (old_len == 0) try allocator.alloc(Value, new_len) else try allocator.realloc(self.slots, new_len);
        @memset(grown[old_len..], .nil);
        self.slots = grown;
        return slot;
    }

    fn rawGetArraySlot(self: *const Table, slot: u32) ?Value {
        if (self.shape != null or self.native_namespace != null or slot >= self.slots.len) return null;
        return if (self.slots[slot] == .nil) null else self.slots[slot];
    }

    fn rawSetArraySlot(self: *Table, slot: u32, value: Value) void {
        std.debug.assert(self.shape == null and self.native_namespace == null and slot < self.slots.len);
        self.markMutated();
        self.slots[slot] = value;
    }

    pub fn rawGetSlot(self: *const Table, slot: u32) ?Value {
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
        if (self.fieldKey(slot)) |key| self.markIdentityKeyWrite(key, value);
        if (slot >= self.slots.len) {
            try self.global_tail.?.set(slot - self.slots.len, value);
            self.markMutated();
            return;
        }
        self.markMutated();
        self.slots[slot] = value;
    }

    pub fn rawSetNativeField(self: *Table, comptime namespace: static_fields.Namespace, comptime name: []const u8, value: Value) !void {
        if (self.native_namespace != namespace) return error.BadNativeNamespace;
        const slot = comptime static_fields.slotForName(namespace, name) orelse @compileError("unknown native namespace field: " ++ name);
        try self.rawSetSlot(slot, value);
    }

    pub fn rawGetChoice(self: *const Table, choice: u32, key: Value) ?Value {
        if (choice >= self.choices.len) return null;
        const cell = self.choices[choice];
        if (cell.value == .nil or !rawEqual(cell.key, key)) return null;
        return cell.value;
    }

    pub fn rawSetChoice(self: *Table, choice: u32, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        if (choice >= self.choices.len) return error.BadChoiceSlot;
        try validateTableKey(key);
        self.markIdentityKeyWrite(key, value);
        self.markMutated();
        if (value == .nil) {
            if (rawEqual(self.choices[choice].key, key)) self.choices[choice] = .{};
            return;
        }
        self.choices[choice] = .{ .key = key, .value = value };
    }
    pub fn rawGet(self: *const Table, key: Value) ?Value {
        if (key == .number) return self.rawGetNumber(key.number);
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| {
            if (cell.value != .nil and rawEqual(cell.key, key)) return cell.value;
        }
        return self.map.getContext(key, .{});
    }

    pub fn rawGetNumber(self: *const Table, number: f64) ?Value {
        if (self.arraySlotForNumber(number)) |slot| if (self.rawGetArraySlot(slot)) |value| return value;
        if (self.shape == null and self.choices.len == 0)
            return if (self.has_hashed_number) self.map.getAdapted(number, NumberLookupContext{}) else null;
        const key = Value{ .number = number };
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| {
            if (cell.value != .nil and cell.key == .number and cell.key.number == number) return cell.value;
        }
        return if (self.has_hashed_number) self.map.getAdapted(number, NumberLookupContext{}) else null;
    }

    pub fn rawSet(self: *Table, allocator: std.mem.Allocator, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        try validateTableKey(key);
        self.markIdentityKeyWrite(key, value);
        self.markMutated();
        if (key == .number) if (self.genericArrayIndex(key.number)) |index| {
            if (self.arraySlotForNumber(key.number)) |slot| {
                _ = self.map.removeContext(key, .{});
                self.rawSetArraySlot(slot, value);
                return;
            }
            if (value != .nil) if (try self.ensureGenericArraySlot(allocator, index)) |slot| {
                _ = self.map.removeContext(key, .{});
                self.rawSetArraySlot(slot, value);
                return;
            };
        };
        if (self.slotForKey(key)) |slot| return self.rawSetSlot(slot, value);
        for (self.choices, 0..) |cell, choice| {
            if (cell.value != .nil and rawEqual(cell.key, key))
                return self.rawSetChoice(@intCast(choice), key, value);
        }
        if (value == .nil) {
            _ = self.map.removeContext(key, .{});
            return;
        }
        try self.map.putContext(allocator, key, value, .{});
        if (key == .number) self.has_hashed_number = true;
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

        pub fn next(self: *Iterator) ?Entry {
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
            if (self.hash.next()) |entry| return .{ .key_ptr = entry.key_ptr, .value_ptr = entry.value_ptr };
            return null;
        }
    };

    pub fn iterator(self: *Table) Iterator {
        if (self.has_identity_key) markLoadDataEffect();
        return .{ .table = self, .hash = self.map.iterator() };
    }

    fn hasArrayIndex(self: *const Table, index: usize) bool {
        return self.rawGetNumber(@floatFromInt(index)) != null;
    }

    pub fn rawLen(self: *const Table) usize {
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
};

threadlocal var load_data_effect_probe: ?*bool = null;

pub fn beginLoadDataEffectProbe(flag: *bool) ?*bool {
    const previous = load_data_effect_probe;
    load_data_effect_probe = flag;
    return previous;
}

pub fn endLoadDataEffectProbe(previous: ?*bool) void {
    load_data_effect_probe = previous;
}

pub fn markLoadDataEffect() void {
    if (load_data_effect_probe) |flag| flag.* = true;
}

const module_state_page_shift = 8;
const module_state_page_len = 1 << module_state_page_shift;
const module_state_page_mask = module_state_page_len - 1;
const ModuleState = struct {
    loading: bool = false,
    value: ?Value = null,
    preinitialized: ?Value = null,
    load_data_snapshot: ?Value = null,
    deferred_require_visibility: bool = false,
    export_pristine: bool = false,
    globals: ?[]Value = null,
    global_tail: ?*GlobalTail = null,
    global_table: ?*Table = null,
};
const ModuleStatePage = struct {
    initialized: [module_state_page_len / 64]u64 = [_]u64{0} ** (module_state_page_len / 64),
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
const GlobalScope = struct {
    globals: []Value,
    global_table: ?*Table,
    global_tail: ?*GlobalTail,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    // Lua strings compare/hash by bytes; runtime concat results need ownership, not hash dedup.
    string_arena: std.heap.ArenaAllocator,
    globals: []Value,
    root_globals: []Value,
    global_tail: ?*GlobalTail = null,
    program_shapes: []const Shape = &.{},
    module_export_shape_ids: []const u32 = &.{},
    module_root_entries: []const FunctionFn = &.{},
    function_module_ids: []const u32 = &.{},
    string_metatable: ?*Table = null,
    last_error: Value = .nil,
    aot_error_name: StableErrorName = .{},
    depth: usize = 0,
    max_depth: usize = 1000,
    next_identity: u32 = 1,
    module_count: usize = 0,
    module_state_pages: []?*ModuleStatePage = &.{},
    module_lookup_ctx: ?*const anyopaque = null,
    module_lookup: ?ModuleLookupFn = null,
    module_name: ?ModuleNameFn = null,
    module_requirements_ctx: ?*const anyopaque = null,
    module_requirements: ?ModuleRequirementsFn = null,
    static_module_ctx: ?*const anyopaque = null,
    static_module: ?StaticModuleFn = null,
    eager_bootstrap: bool = false,
    package_observable: bool = false,
    program_bootstrap_ctx: ?*const anyopaque = null,
    program_bootstrap: ?ProgramBootstrapFn = null,
    host: ?*anyopaque = null,
    current_frame: ?*Table = null,
    package_loaded: ?*Table = null,
    // Lua's base pairs() closes over the builtin next iterator. Rebinding the
    // global name `next` must not change the iterator returned by pairs().
    builtin_next: Value = .nil,
    global_table: ?*Table = null,
    root_global_table: ?*Table = null,
    global_env_slot: ?u32 = null,
    static_global_scopes: std.ArrayList(GlobalScope) = .empty,
    next_iteration_hint: ?NextIterationHint = null,

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
            .string_arena = .init(allocator),
            .globals = globals,
            .root_globals = globals,
            .module_count = module_count,
            .module_state_pages = module_state_pages,
        };
    }

    pub fn forkProgram(self: *const Context, allocator: std.mem.Allocator) !Context {
        var child = try initProgram(allocator, self.root_globals.len, self.module_count);
        child.program_shapes = self.program_shapes;
        child.module_export_shape_ids = self.module_export_shape_ids;
        child.module_root_entries = self.module_root_entries;
        child.function_module_ids = self.function_module_ids;
        child.module_lookup_ctx = self.module_lookup_ctx;
        child.module_lookup = self.module_lookup;
        child.module_name = self.module_name;
        child.module_requirements_ctx = self.module_requirements_ctx;
        child.module_requirements = self.module_requirements;
        child.static_module_ctx = self.static_module_ctx;
        child.static_module = self.static_module;
        child.program_bootstrap_ctx = self.program_bootstrap_ctx;
        child.program_bootstrap = self.program_bootstrap;
        child.max_depth = self.max_depth;
        child.host = self.host;
        return child;
    }

    pub fn deinit(self: *Context) void {
        self.string_arena.deinit();
        self.static_global_scopes.deinit(self.allocator);
        for (self.module_state_pages) |page| if (page) |owned| {
            for (owned.initialized, 0..) |word, word_index| {
                var remaining = word;
                while (remaining != 0) {
                    const slot = word_index * 64 + @as(usize, @intCast(@ctz(remaining)));
                    remaining &= remaining - 1;
                    const state = &owned.states[slot];
                    if (state.global_table) |table| {
                        table.deinit(self.allocator);
                        self.allocator.destroy(table);
                    }
                    if (state.globals) |globals| self.allocator.free(globals);
                    if (state.global_tail) |tail| {
                        tail.deinit();
                        self.allocator.destroy(tail);
                    }
                }
            }
            self.allocator.destroy(owned);
        };
        self.allocator.free(self.module_state_pages);
        if (self.root_global_table) |table| {
            table.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.allocator.free(self.root_globals);
    }

    pub fn setHost(self: *Context, host: ?*anyopaque) void {
        self.host = host;
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
        } else {
            self.last_error = .nil;
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
        if (slot < self.globals.len) {
            self.globals[slot] = value;
            return;
        }
        const tail = self.global_tail orelse return error.BadGlobalSlot;
        try tail.set(slot - self.globals.len, value);
    }
    fn takeFunctionIdentity(self: *Context) !u32 {
        const identity = self.next_identity;
        if (identity == 0) return error.FunctionIdentityExhausted;
        self.next_identity +%= 1;
        return identity;
    }
    pub fn makeFunction(self: *Context, id: u32, entry: FunctionFn, captures: []const *Cell) !Value {
        const identity = try self.takeFunctionIdentity();
        const env: FunctionEnv = if (captures.len == 0) .{} else blk: {
            const owned = try self.allocator.dupe(*Cell, captures);
            const value = try self.allocator.create(Env);
            value.* = .{
                .captures = owned,
                .capture_view = .{ .direct = owned },
            };
            break :blk FunctionEnv.closure(value);
        };
        return .{ .callable = .{ .id = id, .env = env, .identity = identity, .entry = entry } };
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

    pub fn callFunctionBuffered(self: *Context, value: FunctionValue, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (value.id == native_function_id) return self.callEntryBuffered(value.entry, value.captures(), args, result_buffer);
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        const previous = try self.enterFunctionModule(value.id);
        defer if (previous) |scope| self.restoreGlobals(scope);
        return self.callEntryBuffered(value.entry, value.captures(), args, result_buffer);
    }

    pub fn callFunction(self: *Context, value: FunctionValue, args: []const Value) anyerror![]const Value {
        return self.callFunctionBuffered(value, args, null);
    }

    pub fn callStaticFunctionBuffered(self: *Context, module_id: u32, entry: FunctionFn, captures: []const *Cell, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        if (module_id == std.math.maxInt(u32))
            return self.callEntryBuffered(entry, .{ .direct = captures }, args, result_buffer);
        const previous = try self.enterModule(module_id);
        defer self.restoreGlobals(previous);
        return self.callEntryBuffered(entry, .{ .direct = captures }, args, result_buffer);
    }

    pub inline fn callDirectFunction(self: *Context, value: FunctionValue, direct: DirectFunctionFn, args: []const Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        const previous = try self.enterFunctionModule(value.id);
        defer if (previous) |scope| self.restoreGlobals(scope);
        return direct(self, value.captures(), args);
    }

    pub inline fn callBufferedDirectFunction(self: *Context, value: FunctionValue, direct: BufferedDirectFunctionFn, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        const previous = try self.enterFunctionModule(value.id);
        defer if (previous) |scope| self.restoreGlobals(scope);
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
                    try loaded.rawSet(self.allocator, .{ .string = name }, value);
                    state.deferred_require_visibility = false;
                }
            }
        };
        self.package_observable = true;
    }

    pub fn deferStaticRequireRef(self: *Context, module_id: u32, out: *Value) ?*const bool {
        if (self.package_observable) return null;
        const state = self.moduleState(module_id) orelse return null;
        const value = state.value orelse state.preinitialized orelse return null;
        const canonical = self.canonicalModuleName(module_id, null) orelse return null;
        if (self.package_loaded) |loaded| if (loaded.rawGet(.{ .string = canonical })) |visible|
            if (!rawEqual(visible, value)) return null;
        if (!self.eager_bootstrap) state.deferred_require_visibility = true;
        out.* = value;
        return &state.export_pristine;
    }

    pub fn moduleValueSentinel(self: *const Context, module_id: u32, value: Value) ?*const bool {
        const state = self.moduleStateConst(module_id) orelse return null;
        const expected = state.value orelse state.preinitialized orelse return null;
        if (!rawEqual(value, expected) or value != .table) return null;
        return &state.export_pristine;
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
            page.initialized = [_]u64{0} ** (module_state_page_len / 64);
            self.module_state_pages[page_index] = page;
        }
        return self.module_state_pages[page_index].?.ensure(@as(usize, module_id) & module_state_page_mask);
    }

    fn moduleGlobalsAreDense(self: *const Context) bool {
        // A shapeless bound environment exposes numeric array slots directly.
        if (self.root_global_table) |table| if (table.shape == null) return true;
        if (self.root_globals.len <= module_global_prefix_len) return true;
        const values = self.root_globals[module_global_prefix_len..];
        const page_count = values.len / global_page_len + @intFromBool(values.len % global_page_len != 0);
        var occupied: usize = 0;
        var start: usize = 0;
        while (start < values.len) : (start += global_page_len) {
            for (values[start..@min(start + global_page_len, values.len)]) |value| {
                if (value != .nil) {
                    occupied += 1;
                    if (occupied > page_count / 2) return true;
                    break;
                }
            }
        }
        return false;
    }

    fn ensureModuleGlobals(self: *Context, module_id: u32) !GlobalScope {
        const state = try self.ensureModuleState(module_id);
        if (state.globals == null) {
            const dense = self.moduleGlobalsAreDense();
            const prefix_len = if (dense) self.root_globals.len else @min(self.root_globals.len, module_global_prefix_len);
            const globals = try self.allocator.dupe(Value, self.root_globals[0..prefix_len]);
            errdefer self.allocator.free(globals);
            const tail = if (prefix_len < self.root_globals.len)
                try GlobalTail.snapshot(self.allocator, self.root_globals[prefix_len..])
            else
                null;
            errdefer if (tail) |owned| {
                owned.deinit();
                self.allocator.destroy(owned);
            };
            var table: ?*Table = null;
            if (self.root_global_table) |root_table| {
                const owned = try self.allocator.create(Table);
                errdefer self.allocator.destroy(owned);
                owned.* = .{
                    .shape = root_table.shape,
                    .slots = globals,
                    .global_tail = tail,
                    .owns_slots = false,
                };
                if (self.global_env_slot) |slot| {
                    if (slot < globals.len) {
                        globals[slot] = .{ .table = owned };
                    } else if (tail) |extra| {
                        try extra.set(slot - globals.len, .{ .table = owned });
                    } else return error.BadGlobalSlot;
                }
                table = owned;
            }
            state.globals = globals;
            state.global_tail = tail;
            state.global_table = table;
        }
        return .{
            .globals = state.globals.?,
            .global_table = state.global_table,
            .global_tail = state.global_tail,
        };
    }

    fn moduleForFunction(self: *const Context, function_id: u32) ?u32 {
        if (function_id >= self.function_module_ids.len) return null;
        const module_id = self.function_module_ids[function_id];
        return if (module_id < self.module_count) module_id else null;
    }

    fn enterModule(self: *Context, module_id: u32) !GlobalScope {
        const previous = GlobalScope{
            .globals = self.globals,
            .global_table = self.global_table,
            .global_tail = self.global_tail,
        };
        const target = try self.ensureModuleGlobals(module_id);
        self.globals = target.globals;
        self.global_table = target.global_table;
        self.global_tail = target.global_tail;
        return previous;
    }

    fn enterFunctionModule(self: *Context, function_id: u32) !?GlobalScope {
        const module_id = self.moduleForFunction(function_id) orelse return null;
        return try self.enterModule(module_id);
    }

    fn restoreGlobals(self: *Context, previous: GlobalScope) void {
        self.globals = previous.globals;
        self.global_table = previous.global_table;
        self.global_tail = previous.global_tail;
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
        try self.static_global_scopes.append(self.allocator, previous);
    }

    pub fn leaveStaticFunction(self: *Context) void {
        if (self.static_global_scopes.pop()) |previous| self.restoreGlobals(previous);
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
        copy.* = .{};
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

    pub fn preinitializeModule(self: *Context, module_id: u32, value: Value, snapshot_load_data: bool) !void {
        const state = try self.ensureModuleState(module_id);
        if (state.value == null and state.preinitialized == null) {
            state.preinitialized = value;
            if (value == .table) {
                state.export_pristine = true;
                value.table.mutation_sentinel = &state.export_pristine;
            }
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
        for (self.requirementsFor(module_id)) |requirement| {
            const expected = self.preparedModuleValue(requirement.module_id) orelse {
                valid = false;
                break;
            };
            const actual = try self.requireModuleId(requirement.module_id, requirement.requested);
            if (!rawEqual(actual, expected)) {
                valid = false;
                break;
            }
        }

        if (!valid) {
            state.export_pristine = false;
            state.loading = false;
            return null;
        }

        const canonical = self.canonicalModuleName(module_id, requested);
        if (canonical) |text| if (self.package_loaded) |loaded|
            try loaded.rawSet(self.allocator, .{ .string = text }, value);
        state.value = value;
        state.loading = false;
        return value;
    }

    pub fn loadModule(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!Value {
        if (module_id >= self.module_count or module_id >= self.module_root_entries.len) return error.BadModuleId;
        if (self.moduleState(module_id)) |existing| {
            if (existing.value) |value| return value;
            if (existing.preinitialized) |value|
                if (try self.adoptPreinitialized(module_id, requested, existing, value)) |adopted|
                    return adopted;
            if (existing.loading) return error.ModuleLoadLoop;
        }
        const state = try self.ensureModuleState(module_id);
        state.export_pristine = false;
        state.loading = true;
        errdefer state.loading = false;

        const canonical = self.canonicalModuleName(module_id, requested);
        var owned_values: ?[]const Value = null;
        defer if (owned_values) |values| freeResults(values);
        var value: Value = if (self.static_module) |load|
            if (try load(self.static_module_ctx, self, module_id)) |static_value|
                static_value
            else blk: {
                const argv: []const Value = if (canonical) |text| &.{.{ .string = text }} else &.{};
                const previous_globals = try self.enterModule(module_id);
                defer self.restoreGlobals(previous_globals);
                if (work_stats.current()) |work| work.module_roots +|= 1;
                var root_frame: work_stats.RootFrame = .{};
                work_stats.beginRoot(&root_frame, module_id);
                defer work_stats.endRoot(&root_frame);
                const values = try self.callEntry(self.module_root_entries[module_id], .{ .direct = &.{} }, argv);
                owned_values = values;
                break :blk if (values.len == 0) .nil else values[0];
            }
        else blk: {
            const argv: []const Value = if (canonical) |text| &.{.{ .string = text }} else &.{};
            const previous_globals = try self.enterModule(module_id);
            defer self.restoreGlobals(previous_globals);
            if (work_stats.current()) |work| work.module_roots +|= 1;
            var root_frame: work_stats.RootFrame = .{};
            work_stats.beginRoot(&root_frame, module_id);
            defer work_stats.endRoot(&root_frame);
            const values = try self.callEntry(self.module_root_entries[module_id], .{ .direct = &.{} }, argv);
            owned_values = values;
            break :blk if (values.len == 0) .nil else values[0];
        };
        if (value == .nil) {
            if (canonical) |text| if (self.package_loaded) |loaded| {
                if (loaded.rawGet(.{ .string = text })) |existing| value = existing;
            };
            if (value == .nil) value = .{ .boolean = true };
        }
        if (canonical) |text| if (self.package_loaded) |loaded|
            try loaded.rawSet(self.allocator, .{ .string = text }, value);
        state.value = value;
        state.loading = false;
        return value;
    }

    pub fn ensureModule(self: *Context, module_id: u32) anyerror!void {
        _ = try self.loadModule(module_id, null);
    }

    pub fn resolveModule(self: *const Context, raw_name: []const u8) !u32 {
        const lookup = self.module_lookup orelse return error.ModuleNotFound;
        if (lookup(self.module_lookup_ctx, raw_name)) |id| return id;
        const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
        if (std.mem.indexOfScalar(u8, trimmed, '_') == null)
            return lookup(self.module_lookup_ctx, trimmed) orelse error.ModuleNotFound;
        const normalized = try self.allocator.dupe(u8, trimmed);
        defer self.allocator.free(normalized);
        std.mem.replaceScalar(u8, normalized, '_', ' ');
        return lookup(self.module_lookup_ctx, normalized) orelse error.ModuleNotFound;
    }

    pub fn requireModuleId(self: *Context, module_id: u32, raw_name: []const u8) anyerror!Value {
        if (self.eager_bootstrap)
            return self.preparedModuleValue(module_id) orelse error.EagerDependencyNotInitialized;
        if (self.package_loaded) |loaded| if (loaded.rawGet(.{ .string = raw_name })) |value| return value;
        const value = try self.loadModule(module_id, raw_name);
        if (self.package_loaded) |loaded| try loaded.rawSet(self.allocator, .{ .string = raw_name }, value);
        if (self.moduleState(module_id)) |state| state.deferred_require_visibility = false;
        return value;
    }

    pub fn requireByName(self: *Context, raw_name: []const u8) anyerror!Value {
        if (std.mem.eql(u8, raw_name, "package")) try self.observePackage();
        if (self.package_loaded) |loaded| if (loaded.rawGet(.{ .string = raw_name })) |value| return value;
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
    pub fn newNative(self: *Context, host: ?*anyopaque, comptime call: anytype) !Value {
        const identity = try self.takeFunctionIdentity();
        return .{ .callable = .{
            .id = native_function_id,
            .env = FunctionEnv.native(host),
            .identity = identity,
            .entry = stabilizeNative(call),
        } };
    }

    pub fn newNativeBuffered(self: *Context, host: ?*anyopaque, comptime call: anytype) !Value {
        const identity = try self.takeFunctionIdentity();
        return .{ .callable = .{
            .id = native_function_id,
            .env = FunctionEnv.native(host),
            .identity = identity,
            .entry = stabilizeNativeBuffered(call),
        } };
    }

    pub fn newTable(self: *Context) !*Table {
        const table = try self.allocator.create(Table);
        table.* = .{};
        return table;
    }

    pub fn newArrayTable(self: *Context, capacity: u32) !*Table {
        const table = try self.newTable();
        errdefer self.allocator.destroy(table);
        if (capacity != 0) {
            table.slots = try self.allocator.alloc(Value, capacity);
            @memset(table.slots, .nil);
        }
        return table;
    }

    pub fn newShapedTable(self: *Context, shape: *const Shape) !*Table {
        if (shape.field_keys.len != shape.field_count or
            (shape.sorted_string_slots.len != 0 and shape.sorted_string_slots.len != shape.field_keys.len))
            return error.BadShape;
        const table = try self.allocator.create(Table);
        errdefer self.allocator.destroy(table);
        table.* = .{ .shape = shape };
        if (shape.field_count != 0) {
            table.slots = try self.allocator.alloc(Value, shape.field_count);
            @memset(table.slots, .nil);
        }
        if (shape.choice_count != 0) {
            table.choices = try self.allocator.alloc(ChoiceCell, shape.choice_count);
            @memset(table.choices, .{});
        }
        return table;
    }

    pub fn newProgramShape(self: *Context, shape_id: u32) !*Table {
        if (shape_id >= self.program_shapes.len) return error.BadShape;
        return self.newShapedTable(&self.program_shapes[shape_id]);
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

    pub fn newNativeNamespace(self: *Context, namespace: static_fields.Namespace) !*Table {
        const table = try self.allocator.create(Table);
        errdefer self.allocator.destroy(table);
        table.* = .{ .native_namespace = namespace };
        const count = static_fields.fieldCount(namespace);
        if (count != 0) {
            table.slots = try self.allocator.alloc(Value, count);
            @memset(table.slots, .nil);
        }
        return table;
    }

    pub fn metamethod(_: *Context, value: Value, name: []const u8) ?Value {
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
                        else => blk: {
                            const out = try self.callValue(indexer, &.{ object, key });
                            defer freeResults(out);
                            break :blk if (out.len == 0) .nil else out[0];
                        },
                    };
                };
                return .nil;
            },
            .string => {
                if (self.string_metatable) |mt| if (mt.rawGet(.{ .string = "__index" })) |indexer| {
                    if (indexer == .table) return indexer.table.rawGet(key) orelse .nil;
                    const out = try self.callValue(indexer, &.{ object, key });
                    defer freeResults(out);
                    return if (out.len == 0) .nil else out[0];
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
                const out = try self.callValue(handler, &.{ object, key, value });
                defer freeResults(out);
                return;
            },
        };
        try table.rawSet(self.allocator, key, value);
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
        const out = try self.callValue(method, &.{ a, b });
        defer freeResults(out);
        return if (out.len == 0) .nil else out[0];
    }
    fn sharedComparisonMetamethod(self: *Context, a: Value, b: Value, name: []const u8) ?Value {
        const left = self.metamethod(a, name) orelse return null;
        const right = self.metamethod(b, name) orelse return null;
        return if (rawEqual(left, right)) left else null;
    }
    fn callComparisonMetamethod(self: *Context, method: Value, a: Value, b: Value) anyerror!bool {
        const out = try self.callValue(method, &.{ a, b });
        defer freeResults(out);
        return out.len != 0 and out[0].truthy();
    }
    pub fn comparison(self: *Context, op: CompareOp, a: Value, b: Value) anyerror!bool {
        if (op == .eq or op == .ne) {
            if (rawEqual(a, b)) return op == .eq;
            if (a == .table and b == .table) {
                const left = self.metamethod(a, "__eq");
                const right = self.metamethod(b, "__eq");
                if (left != null and right != null and rawEqual(left.?, right.?)) {
                    const out = try self.callValue(left.?, &.{ a, b });
                    defer freeResults(out);
                    const equal = out.len != 0 and out[0].truthy();
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
    fn ownString(self: *Context, text: []const u8) ![]const u8 {
        return self.string_arena.allocator().dupe(u8, text);
    }

    pub fn concatValues(self: *Context, values: []const Value) anyerror!Value {
        var scratch = std.heap.stackFallback(1024, std.heap.smp_allocator);
        const allocator = scratch.get();
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

test "numeric value hashing preserves prior iteration order" {
    const samples = [_]f64{ 0, -0.0, 1, -1, 64, 1.5 };
    const context = ValueContext{};
    for (samples) |sample| {
        const value = Value{ .number = sample };
        const normalized: f64 = if (sample == 0) 0 else sample;
        const bits: u64 = @bitCast(normalized);
        const tag: u8 = @intFromEnum(std.meta.activeTag(value));
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
        const tag: u8 = @intFromEnum(std.meta.activeTag(value));
        var previous = std.hash.Wyhash.init(0);
        previous.update(&.{tag});
        previous.update(text);
        try std.testing.expectEqual(previous.final(), context.hash(value));
    }
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
    try std.testing.expect(ctx.getGlobal(0) == .nil);
    try std.testing.expectEqual(@as(f64, 1), ctx.moduleState(0).?.globals.?[0].number);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Module:A" }).?.string);

    const alias = try ctx.requireByName("Alias:A");
    try std.testing.expectEqualStrings("Module:A", alias.string);
    try std.testing.expectEqual(@as(f64, 1), ctx.moduleState(0).?.globals.?[0].number);
    const canonical = try ctx.requireByName("Module:A");
    try std.testing.expectEqualStrings("Module:A", canonical.string);
    try std.testing.expectEqual(@as(f64, 1), ctx.moduleState(0).?.globals.?[0].number);
    try std.testing.expect(ctx.getGlobal(0) == .nil);
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

test "module globals are isolated for dynamic and static calls" {
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
    try std.testing.expectEqualStrings("root", ctx.getGlobal(0).string);

    const a_result = try ctx.callValue(a, &.{});
    defer freeResults(a_result);
    try std.testing.expectEqualStrings("A", a_result[0].string);
    const b_result = try ctx.callValue(b, &.{});
    defer freeResults(b_result);
    try std.testing.expectEqualStrings("B", b_result[0].string);
    try std.testing.expectEqualStrings("root", ctx.getGlobal(0).string);

    const static_a = try ctx.callStaticFunctionBuffered(
        0,
        stabilize(ModuleGlobalIsolationProbe.read),
        &.{},
        &.{},
        null,
    );
    defer freeResults(static_a);
    try std.testing.expectEqualStrings("A", static_a[0].string);
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
    table.* = .{ .shape = shape, .slots = ctx.globals, .owns_slots = false };
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

    const buffered = Value{ .callable = .{ .id = 0, .identity = 1, .entry = stabilizeBuffered(bufferedTripleProbe) } };
    var storage: [2]Value = undefined;
    const borrowed = try ctx.callValueFixed(buffered, &.{}, &storage);
    defer borrowed.deinit();
    try std.testing.expect(!borrowed.owned);
    try std.testing.expectEqual(@as(usize, 2), borrowed.values.len);
    try std.testing.expectEqual(@as(f64, 1), borrowed.values[0].number);
    try std.testing.expectEqual(@as(f64, 2), borrowed.values[1].number);

    const empty_callable = Value{ .callable = .{ .id = 2, .identity = 3, .entry = stabilizeBuffered(bufferedEmptyProbe) } };
    const empty = try ctx.callValueFixed(empty_callable, &.{}, &storage);
    defer empty.deinit();
    try std.testing.expect(!empty.owned);
    try std.testing.expectEqual(@as(usize, 0), empty.values.len);

    const unbuffered = Value{ .callable = .{ .id = 1, .identity = 2, .entry = stabilize(guardTestExpected) } };
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
    const lua_method = Value{ .callable = .{ .id = 3, .identity = 4, .entry = stabilizeBuffered(bufferedCallableTableProbe) } };
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

test "sparse module globals preserve root snapshots aliases and iteration" {
    const count = 193;
    var keys: [count]Value = undefined;
    for (&keys, 0..) |*key, slot| key.* = .{ .number = @floatFromInt(slot + 1) };
    keys[0] = .{ .string = "_G" };
    keys[1] = .{ .string = "native" };
    keys[64] = .{ .string = "early" };
    keys[128] = .{ .string = "late" };
    const shape: Shape = .{ .field_keys = &keys, .field_count = count, .open = true };
    var ctx = try Context.initProgram(std.testing.allocator, count, 2);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, &shape, 0);
    const root = ctx.global_table.?;
    try ctx.setGlobal(1, .{ .number = 1 });
    try ctx.setGlobal(128, .{ .number = 8 });

    const root_scope = try ctx.enterModule(0);
    const first = ctx.global_table.?;
    try std.testing.expect(ctx.global_tail != null);
    try std.testing.expectEqual(@as(usize, module_global_prefix_len), ctx.globals.len);
    try std.testing.expect(ctx.getGlobal(0).table == first);
    const native_ptr = &ctx.globals[1];
    const late_ptr = first.slotPtr(128).?;
    try ctx.setGlobal(1, .{ .number = 2 });
    try first.rawSet(ctx.allocator, keys[128], .{ .number = 9 });
    try ctx.setGlobal(64, .{ .boolean = false });
    try std.testing.expectEqual(@as(f64, 2), native_ptr.number);
    try std.testing.expectEqual(@as(f64, 9), late_ptr.number);
    try std.testing.expect(!first.rawGet(keys[64]).?.boolean);
    var it = first.iterator();
    for ([_]usize{ 0, 1, 64, 128 }) |slot| {
        const entry = it.next().?;
        try std.testing.expect(rawEqual(keys[slot], entry.key_ptr.*));
    }
    try std.testing.expect(it.next() == null);
    ctx.restoreGlobals(root_scope);

    try ctx.setGlobal(128, .nil);
    const second_scope = try ctx.enterModule(1);
    try std.testing.expect(ctx.global_table.? != first);
    try std.testing.expect(ctx.getGlobal(64) == .nil);
    try std.testing.expect(ctx.getGlobal(128) == .nil);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(1).number);
    try std.testing.expect(ctx.getGlobal(0).table == ctx.global_table.?);
    try std.testing.expectError(error.BadGlobalSlot, ctx.setGlobal(count, .nil));
    ctx.restoreGlobals(second_scope);
    try std.testing.expect(ctx.global_table.? == root and ctx.global_tail == null);
    try std.testing.expect(ctx.getGlobal(128) == .nil);
}

fn moduleGlobalAllocationCase(allocator: std.mem.Allocator, dense: bool) !void {
    var keys = [_]Value{.nil} ** 257;
    keys[256] = .{ .string = "_G" };
    const shape: Shape = .{ .field_keys = &keys, .field_count = keys.len, .open = true };
    var ctx = try Context.initProgram(allocator, keys.len, 1);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, &shape, 256);
    try ctx.setGlobal(64, .{ .number = 1 });
    if (dense) try ctx.setGlobal(128, .{ .boolean = false });
    const previous = try ctx.enterModule(0);
    defer ctx.restoreGlobals(previous);
    try std.testing.expectEqual(dense, ctx.global_tail == null);
    try std.testing.expect(ctx.getGlobal(256).table == ctx.global_table.?);
    try ctx.setGlobal(128, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), ctx.getGlobal(128).number);
}

test "sparse and dense module globals clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, moduleGlobalAllocationCase, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, moduleGlobalAllocationCase, .{true});
}

test "module global density counts false and partial tail pages" {
    var ctx = try Context.init(std.testing.allocator, 257);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 1 });
    try std.testing.expect(!ctx.moduleGlobalsAreDense());
    try ctx.setGlobal(64, .{ .number = 1 });
    try ctx.setGlobal(192, .{ .number = 1 });
    try std.testing.expect(!ctx.moduleGlobalsAreDense());
    try ctx.setGlobal(256, .{ .boolean = false });
    try std.testing.expect(ctx.moduleGlobalsAreDense());
    try ctx.setGlobal(256, .nil);
    try std.testing.expect(!ctx.moduleGlobalsAreDense());
}

test "shapeless module globals keep numeric array aliases" {
    var ctx = try Context.initProgram(std.testing.allocator, 193, 1);
    defer ctx.deinit();
    try bindGlobalTable(&ctx, null, 0);
    try ctx.setGlobal(64, .{ .number = 11 });
    const previous = try ctx.enterModule(0);
    const table = ctx.global_table.?;
    try std.testing.expect(ctx.global_tail == null);
    try std.testing.expectEqual(@as(f64, 11), table.rawGetNumber(65).?.number);
    try table.rawSet(ctx.allocator, .{ .number = 65 }, .{ .number = 22 });
    try std.testing.expectEqual(@as(f64, 22), ctx.getGlobal(64).number);
    var iterator = table.iterator();
    try std.testing.expectEqual(@as(f64, 1), iterator.next().?.key_ptr.number);
    const high = iterator.next().?;
    try std.testing.expectEqual(@as(f64, 65), high.key_ptr.number);
    try std.testing.expectEqual(@as(f64, 22), high.value_ptr.number);
    try std.testing.expect(iterator.next() == null);
    ctx.restoreGlobals(previous);
    try std.testing.expectEqual(@as(f64, 11), ctx.getGlobal(64).number);
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
        .field_keys = &keys,
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
        .field_keys = &keys,
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

test "runtime Value stays compact and function identities never wrap" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Value));
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
