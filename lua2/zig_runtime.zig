const std = @import("std");
const aot_data = @import("zig_aot_data.zig");
const static_fields = @import("vm_static_field_abi.zig");
const static_keys = @import("vm_static_key_abi.zig");

pub const Cell = struct { value: Value };
pub const Env = struct { captures: []const *Cell };
pub const ModuleEnv = struct { cells: []?*Cell };

pub const FunctionEnv = struct {
    raw: usize = 0,
    const module_tag: usize = 1;

    pub fn closure(env: *Env) FunctionEnv {
        comptime std.debug.assert(@alignOf(Env) >= 2);
        const raw = @intFromPtr(env);
        std.debug.assert(raw & module_tag == 0);
        return .{ .raw = raw };
    }

    pub fn module(env: *ModuleEnv) FunctionEnv {
        comptime std.debug.assert(@alignOf(ModuleEnv) >= 2);
        const raw = @intFromPtr(env);
        std.debug.assert(raw & module_tag == 0);
        return .{ .raw = raw | module_tag };
    }

    pub fn closurePtr(self: FunctionEnv) ?*Env {
        if (self.raw == 0 or self.raw & module_tag != 0) return null;
        return @ptrFromInt(self.raw);
    }

    pub fn modulePtr(self: FunctionEnv) ?*ModuleEnv {
        if (self.raw & module_tag == 0) return null;
        return @ptrFromInt(self.raw & ~module_tag);
    }
};

pub const Captures = union(enum) {
    direct: []const *Cell,
    module: *ModuleEnv,

    pub fn cell(self: Captures, ordinal: u32, module_slot: u32) !*Cell {
        return switch (self) {
            .direct => |cells| if (ordinal < cells.len) cells[ordinal] else error.BadUpvalue,
            .module => |env| blk: {
                if (module_slot >= env.cells.len) return error.BadModuleCapture;
                break :blk env.cells[module_slot] orelse return error.BadModuleCapture;
            },
        };
    }
};

pub const FunctionValue = struct {
    id: u32,
    env: FunctionEnv = .{},
    identity: u64,
    entry: FunctionFn,

    pub fn captures(self: FunctionValue) Captures {
        if (self.env.modulePtr()) |env| return .{ .module = env };
        if (self.env.closurePtr()) |env| return .{ .direct = env.captures };
        return .{ .direct = &.{} };
    }
};
pub const DirectFunctionFn = *const fn (*Context, Captures, []const Value) anyerror![]const Value;
pub const FunctionResult = extern struct {
    values_ptr: ?[*]const Value,
    values_len: usize,
    status: u32,
    reserved: u32,
};
pub const FunctionFn = *const fn (*Context, *const Captures, [*]const Value, usize) callconv(.c) FunctionResult;
pub const NativeFn = *const fn (?*anyopaque, *Context, []const Value) anyerror![]const Value;
pub const StableNativeFn = *const fn (?*anyopaque, *Context, [*]const Value, usize) callconv(.c) FunctionResult;
pub const ModuleLookupFn = *const fn (?*const anyopaque, []const u8) ?u32;
pub const ModuleNameFn = *const fn (?*const anyopaque, u32) ?[]const u8;
pub const NativeFunction = struct {
    ctx: ?*anyopaque = null,
    call: NativeFn,
    stable_call: StableNativeFn,
};

pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *Table,
    function: FunctionValue,
    native: *NativeFunction,

    pub fn truthy(value: Value) bool {
        return switch (value) {
            .nil => false,
            .boolean => |v| v,
            else => true,
        };
    }
};
pub const NativeFieldGuard = struct {
    namespace: static_fields.Namespace,
    slot: u32,
    root: Value,
    child_slot: ?u32 = null,
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
        fn call(ctx: *Context, captures: *const Captures, args_ptr: [*]const Value, args_len: usize) callconv(.c) FunctionResult {
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

pub fn stabilizeNative(comptime function: anytype) StableNativeFn {
    return struct {
        fn call(host: ?*anyopaque, ctx: *Context, args_ptr: [*]const Value, args_len: usize) callconv(.c) FunctionResult {
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

pub const no_shape = std.math.maxInt(u32);
pub const TableConstant = struct { first: u32, count: u32, shape: u32 = no_shape };
pub const Constant = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: TableConstant,
};
pub const implicit_list_key = std.math.maxInt(u32);
pub const ConstantEntry = u64;
pub fn packConstantEntry(key: u32, value: u32) ConstantEntry {
    return (@as(u64, key) << 32) | value;
}
fn constantEntryKey(entry: ConstantEntry) u32 {
    return @intCast(entry >> 32);
}
fn constantEntryValue(entry: ConstantEntry) u32 {
    return @truncate(entry);
}
pub const ConstantBlock = struct { first: u32, values: []const Constant };
pub const ConstantEntryBlock = struct { first: u32, values: []const ConstantEntry };
pub const FunctionBlock = struct { first: u32, values: []const FunctionFn };
pub const ProgramData = aot_data.View;
pub const module_root_function = std.math.maxInt(u32);
pub const module_root_empty = module_root_function - 1;
pub fn descriptorModuleRootStub(_: *Context, _: Captures, _: []const Value) anyerror![]const Value {
    return error.DescriptorModuleRootInvoked;
}

pub const Shape = struct {
    field_keys: []const Value = &.{},
    field_count: u32 = 0,
    choice_count: u32 = 0,
    open: bool = false,
};

pub const ChoiceCell = struct {
    key: Value = .nil,
    value: Value = .nil,
};

const ValueContext = struct {
    pub fn hash(_: ValueContext, value: Value) u64 {
        var h = std.hash.Wyhash.init(0);
        const tag: u8 = @intFromEnum(std.meta.activeTag(value));
        h.update(&.{tag});
        switch (value) {
            .nil => {},
            .boolean => |v| h.update(&.{@intFromBool(v)}),
            .number => |v| {
                const normalized: f64 = if (v == 0) 0 else v;
                const bits: u64 = @bitCast(normalized);
                h.update(std.mem.asBytes(&bits));
            },
            .string => |v| h.update(v),
            .table => |v| {
                const ptr: usize = @intFromPtr(v);
                h.update(std.mem.asBytes(&ptr));
            },
            .function => |v| h.update(std.mem.asBytes(&v.identity)),
            .native => |v| {
                const ptr: usize = @intFromPtr(v);
                h.update(std.mem.asBytes(&ptr));
            },
        }
        return h.final();
    }
    pub fn eql(_: ValueContext, a: Value, b: Value) bool {
        return rawEqual(a, b);
    }
};

const Map = std.HashMapUnmanaged(Value, Value, ValueContext, 80);

pub const Table = struct {
    shape: ?*const Shape = null,
    native_namespace: ?static_fields.Namespace = null,
    slots: []Value = &.{},
    owns_slots: bool = true,
    choices: []ChoiceCell = &.{},
    map: Map = .empty,
    metatable: ?*Table = null,
    append_index: u32 = 1,
    read_only: bool = false,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        if (self.owns_slots and self.slots.len != 0) allocator.free(self.slots);
        if (self.choices.len != 0) allocator.free(self.choices);
    }

    fn slotForKey(self: *const Table, key: Value) ?u32 {
        if (key == .string) if (self.native_namespace) |namespace|
            return static_fields.slotForName(namespace, key.string);
        const shape = self.shape orelse return null;
        if (shape.field_keys.len != shape.field_count) return null;
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

    pub fn rawGetSlot(self: *const Table, slot: u32) ?Value {
        if (slot >= self.slots.len) return null;
        return if (self.slots[slot] == .nil) null else self.slots[slot];
    }

    pub fn rawSetSlot(self: *Table, slot: u32, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        if (slot >= self.slots.len) return error.BadShapeSlot;
        self.slots[slot] = value;
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
        if (value == .nil) {
            if (rawEqual(self.choices[choice].key, key)) self.choices[choice] = .{};
            return;
        }
        self.choices[choice] = .{ .key = key, .value = value };
    }
    pub fn rawGet(self: *const Table, key: Value) ?Value {
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| {
            if (cell.value != .nil and rawEqual(cell.key, key)) return cell.value;
        }
        return self.map.getContext(key, .{});
    }

    pub fn rawSet(self: *Table, allocator: std.mem.Allocator, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        try validateTableKey(key);
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
        pub fn next(self: *Iterator) ?Entry {
            while (self.slot < self.table.slots.len) {
                const index = self.slot;
                self.slot += 1;
                if (self.table.slots[index] == .nil) continue;
                self.key = self.table.fieldKey(index) orelse continue;
                return .{ .key_ptr = &self.key, .value_ptr = &self.table.slots[index] };
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
        return .{ .table = self, .hash = self.map.iterator() };
    }

    fn hasArrayIndex(self: *const Table, index: usize) bool {
        return self.rawGet(.{ .number = @floatFromInt(index) }) != null;
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
        .function => |v| v.identity == b.function.identity,
        .native => |v| v == b.native,
    };
}

pub fn toNumber(value: Value) ?f64 {
    return switch (value) {
        .number => |v| v,
        .string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

pub fn numberToString(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    if (std.math.isNan(number)) return "nan";
    if (std.math.isInf(number)) return if (number < 0) "-inf" else "inf";
    if (@floor(number) == number and number >= @as(f64, @floatFromInt(std.math.minInt(i64))) and number <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        return std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(number))});
    return std.fmt.allocPrint(allocator, "{d}", .{number});
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
pub const Frame = struct {
    regs: []Value,
    cells: []?*Cell,
    module_env: ?*ModuleEnv = null,
    varargs: []const Value = &.{},
    multi: []const Value = &.{},
    multi_base: u32 = std.math.maxInt(u32),
    multi_owned: bool = false,

    pub fn init(regs: []Value, cells: []?*Cell, args: []const Value, param_count: u32, is_vararg: bool) !Frame {
        if (param_count > regs.len or cells.len != regs.len) return error.BadFrame;
        @memset(regs, .nil);
        @memset(cells, null);
        const n = @min(@as(usize, param_count), args.len);
        @memcpy(regs[0..n], args[0..n]);
        const tail = if (is_vararg and args.len > param_count) args[param_count..] else &.{};
        return .{ .regs = regs, .cells = cells, .varargs = tail };
    }

    /// Generated AOT IR defines every non-parameter register before its first read.
    /// Only parameters need Lua's implicit nil initialization at function entry.
    pub fn initAot(regs: []Value, cells: []?*Cell, args: []const Value, param_count: u32, is_vararg: bool) !Frame {
        if (param_count > regs.len or cells.len != regs.len) return error.BadFrame;
        const params_len: usize = @intCast(param_count);
        @memset(regs[0..params_len], .nil);
        @memset(cells, null);
        const n = @min(params_len, args.len);
        @memcpy(regs[0..n], args[0..n]);
        const tail = if (is_vararg and args.len > param_count) args[param_count..] else &.{};
        return .{ .regs = regs, .cells = cells, .varargs = tail };
    }

    pub fn initAotNoCells(regs: []Value, args: []const Value, param_count: u32, is_vararg: bool) !Frame {
        if (param_count > regs.len) return error.BadFrame;
        const params_len: usize = @intCast(param_count);
        @memset(regs[0..params_len], .nil);
        const n = @min(params_len, args.len);
        @memcpy(regs[0..n], args[0..n]);
        const tail = if (is_vararg and args.len > param_count) args[param_count..] else &.{};
        return .{ .regs = regs, .cells = &.{}, .varargs = tail };
    }

    pub fn deinit(self: *Frame) void {
        if (self.multi_owned) freeResults(self.multi);
    }

    pub fn get(self: *const Frame, reg: u32) Value {
        if (reg < self.cells.len) if (self.cells[reg]) |cell| return cell.value;
        return self.regs[reg];
    }

    pub fn set(self: *Frame, reg: u32, value: Value) void {
        if (reg < self.cells.len) if (self.cells[reg]) |cell| {
            cell.value = value;
            return;
        };
        self.regs[reg] = value;
    }
    pub fn ensureCell(self: *Frame, ctx: *Context, reg: u32) !*Cell {
        if (reg >= self.cells.len) return error.BadFrame;
        if (self.cells[reg]) |cell| return cell;
        const cell = try ctx.allocator.create(Cell);
        cell.* = .{ .value = self.regs[reg] };
        self.cells[reg] = cell;
        return cell;
    }

    pub fn ensureModuleEnv(self: *Frame, ctx: *Context) !*ModuleEnv {
        if (self.module_env) |env| return env;
        const env = try ctx.allocator.create(ModuleEnv);
        errdefer ctx.allocator.destroy(env);
        const cells = try ctx.allocator.alloc(?*Cell, self.cells.len);
        @memcpy(cells, self.cells);
        env.* = .{ .cells = cells };
        self.cells = cells;
        self.module_env = env;
        return env;
    }

    pub fn detachCell(self: *Frame, reg: u32) void {
        if (reg >= self.cells.len) return;
        if (self.cells[reg]) |cell| {
            self.regs[reg] = cell.value;
            self.cells[reg] = null;
        }
    }

    pub fn multiAt(self: *const Frame, base: u32) []const Value {
        return if (self.multi_base == base) self.multi else &.{};
    }

    pub fn storeResults(self: *Frame, base: u32, count: u32, values: []const Value, owned: bool) void {
        if (count == 0) {
            if (owned) freeResults(values);
            return;
        }
        if (count == std.math.maxInt(u32)) {
            if (self.multi_owned) freeResults(self.multi);
            self.multi = values;
            self.multi_base = base;
            self.multi_owned = owned;
            self.set(base, if (values.len == 0) .nil else values[0]);
            return;
        }
        for (0..count) |i| self.set(base + @as(u32, @intCast(i)), if (i < values.len) values[i] else .nil);
        if (owned) freeResults(values);
    }
};
pub const Context = struct {
    allocator: std.mem.Allocator,
    globals: []Value,
    shapes: []const Shape = &.{},
    function_blocks: []const FunctionBlock = &.{},
    constant_blocks: []const ConstantBlock = &.{},
    constant_entry_blocks: []const ConstantEntryBlock = &.{},
    program_data: ?ProgramData = null,
    module_roots: []const u32 = &.{},
    module_root_values: []const u32 = &.{},
    string_metatable: ?*Table = null,
    string_intern: std.StringHashMapUnmanaged([]const u8) = .empty,
    last_error: Value = .nil,
    aot_error_name: StableErrorName = .{},
    depth: usize = 0,
    max_depth: usize = 1000,
    next_identity: u64 = 1,
    module_state: []u8 = &.{},
    module_envs: []?*ModuleEnv = &.{},
    module_value_slots: []u32 = &.{},
    module_values: std.ArrayList(Value) = .empty,
    module_lookup_ctx: ?*const anyopaque = null,
    module_lookup: ?ModuleLookupFn = null,
    module_name: ?ModuleNameFn = null,
    host: ?*anyopaque = null,
    current_frame: ?*Table = null,
    package_loaded: ?*Table = null,
    global_table: ?*Table = null,

    pub fn init(allocator: std.mem.Allocator, global_count: usize) !Context {
        return initProgram(allocator, global_count, 0);
    }

    pub fn initProgram(allocator: std.mem.Allocator, global_count: usize, module_count: usize) !Context {
        const globals = try allocator.alloc(Value, global_count);
        errdefer allocator.free(globals);
        @memset(globals, .nil);
        const module_state = try allocator.alloc(u8, module_count);
        errdefer allocator.free(module_state);
        @memset(module_state, 0);
        const module_envs = try allocator.alloc(?*ModuleEnv, module_count);
        errdefer allocator.free(module_envs);
        @memset(module_envs, null);
        const module_value_slots = try allocator.alloc(u32, module_count);
        errdefer allocator.free(module_value_slots);
        @memset(module_value_slots, std.math.maxInt(u32));
        return .{ .allocator = allocator, .globals = globals, .module_state = module_state, .module_envs = module_envs, .module_value_slots = module_value_slots };
    }

    pub fn forkProgram(self: *const Context, allocator: std.mem.Allocator) !Context {
        var child = try initProgram(allocator, self.globals.len, self.module_roots.len);
        child.shapes = self.shapes;
        child.function_blocks = self.function_blocks;
        child.constant_blocks = self.constant_blocks;
        child.constant_entry_blocks = self.constant_entry_blocks;
        child.program_data = self.program_data;
        child.module_roots = self.module_roots;
        child.module_root_values = self.module_root_values;
        child.module_lookup_ctx = self.module_lookup_ctx;
        child.module_lookup = self.module_lookup;
        child.module_name = self.module_name;
        child.max_depth = self.max_depth;
        child.host = self.host;
        return child;
    }

    pub fn deinit(self: *Context) void {
        var it = self.string_intern.keyIterator();
        while (it.next()) |text| self.allocator.free(text.*);
        self.string_intern.deinit(self.allocator);
        self.module_values.deinit(self.allocator);
        if (self.module_value_slots.len != 0) self.allocator.free(self.module_value_slots);
        if (self.global_table) |table| {
            table.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.allocator.free(self.globals);
        if (self.module_state.len != 0) self.allocator.free(self.module_state);
        if (self.module_envs.len != 0) self.allocator.free(self.module_envs);
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

    pub fn adoptFailure(self: *Context, child: *const Context) void {
        if (child.aotErrorName()) |name| self.setAotErrorName(name) else self.clearAotErrorName();
    }

    pub fn getGlobal(self: *const Context, slot: u32) Value {
        return if (slot < self.globals.len) self.globals[slot] else .nil;
    }

    pub fn setGlobal(self: *Context, slot: u32, value: Value) !void {
        if (slot >= self.globals.len) return error.BadGlobalSlot;
        self.globals[slot] = value;
    }
    pub fn makeFunction(self: *Context, id: u32, captures: []const *Cell) !Value {
        const entry = self.functionById(id) orelse return error.BadFunctionId;
        const identity = self.next_identity;
        self.next_identity +%= 1;
        const env: FunctionEnv = if (captures.len == 0) .{} else blk: {
            const owned = try self.allocator.dupe(*Cell, captures);
            const value = try self.allocator.create(Env);
            value.* = .{ .captures = owned };
            break :blk FunctionEnv.closure(value);
        };
        return .{ .function = .{ .id = id, .env = env, .identity = identity, .entry = entry } };
    }

    pub fn makeModuleFunction(self: *Context, id: u32, env: *ModuleEnv) !Value {
        const entry = self.functionById(id) orelse return error.BadFunctionId;
        const identity = self.next_identity;
        self.next_identity +%= 1;
        return .{ .function = .{ .id = id, .env = FunctionEnv.module(env), .identity = identity, .entry = entry } };
    }

    fn functionById(self: *const Context, id: u32) ?FunctionFn {
        var low: usize = 0;
        var high = self.function_blocks.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const block = self.function_blocks[mid];
            if (id < block.first) {
                high = mid;
            } else {
                const offset = @as(usize, id - block.first);
                if (offset < block.values.len) return block.values[offset];
                low = mid + 1;
            }
        }
        return null;
    }

    fn invokeEntry(self: *Context, entry: FunctionFn, captures: Captures, args: []const Value) anyerror![]const Value {
        const result = entry(self, &captures, args.ptr, args.len);
        if (result.reserved != 0 or result.status > 1) return error.BadAotFunctionResult;
        if (result.status == 1) {
            if (self.aotErrorName() == null) self.setAotErrorName("AotCallFailed");
            return error.AotCallFailed;
        }
        if (result.values_len == 0) return &.{};
        const values_ptr = result.values_ptr orelse return error.BadAotFunctionResult;
        return values_ptr[0..result.values_len];
    }

    pub fn invokeKnown(self: *Context, id: u32, captures: Captures, args: []const Value) anyerror![]const Value {
        return self.invokeEntry(self.functionById(id) orelse return error.BadFunctionId, captures, args);
    }

    fn callNative(self: *Context, native: *NativeFunction, args: []const Value) anyerror![]const Value {
        const result = native.stable_call(native.ctx, self, args.ptr, args.len);
        if (result.reserved != 0 or result.status > 1) return error.BadAotFunctionResult;
        if (result.status == 1) {
            if (self.aotErrorName() == null) self.setAotErrorName("AotCallFailed");
            return error.AotCallFailed;
        }
        if (result.values_len == 0) return &.{};
        const values_ptr = result.values_ptr orelse return error.BadAotFunctionResult;
        return values_ptr[0..result.values_len];
    }

    pub fn callFunction(self: *Context, value: FunctionValue, args: []const Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        return self.invokeEntry(value.entry, value.captures(), args);
    }

    pub inline fn callDirectFunction(self: *Context, value: FunctionValue, direct: DirectFunctionFn, args: []const Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        return direct(self, value.captures(), args);
    }

    pub fn bindModuleEnv(self: *Context, module_id: u32, env: *ModuleEnv) !void {
        if (module_id >= self.module_envs.len) return error.BadModuleId;
        if (self.module_envs[module_id]) |existing| {
            if (existing != env) return error.ModuleEnvironmentMismatch;
        } else {
            self.module_envs[module_id] = env;
        }
    }

    pub fn moduleCaptures(self: *const Context, module_id: u32) !Captures {
        if (module_id >= self.module_envs.len) return error.BadModuleId;
        return .{ .module = self.module_envs[module_id] orelse return error.UnregisteredModuleEnvironment };
    }

    pub fn configureModules(self: *Context, host: ?*const anyopaque, lookup: ModuleLookupFn, name: ModuleNameFn) void {
        self.module_lookup_ctx = host;
        self.module_lookup = lookup;
        self.module_name = name;
    }

    fn canonicalModuleName(self: *const Context, module_id: u32, requested: ?[]const u8) ?[]const u8 {
        if (self.module_name) |name| if (name(self.module_lookup_ctx, module_id)) |text| return text;
        return requested;
    }

    pub fn loadModule(self: *Context, module_id: u32, requested: ?[]const u8) anyerror!Value {
        if (module_id >= self.module_roots.len or module_id >= self.module_state.len) return error.BadModuleId;
        if (self.module_state[module_id] == 2) {
            const slot = self.module_value_slots[module_id];
            if (slot >= self.module_values.items.len) return error.MissingModuleValue;
            return self.module_values.items[slot];
        }
        if (self.module_state[module_id] == 1) return error.ModuleLoadLoop;
        self.module_state[module_id] = 1;
        errdefer {
            if (self.module_state[module_id] != 2) self.module_state[module_id] = 0;
        }

        const canonical = self.canonicalModuleName(module_id, requested);
        const root_value = if (module_id < self.module_root_values.len) self.module_root_values[module_id] else module_root_function;
        var value: Value = if (root_value == module_root_function) blk: {
            const argv: []const Value = if (canonical) |text| &.{.{ .string = text }} else &.{};
            const values = try self.invokeKnown(self.module_roots[module_id], .{ .direct = &.{} }, argv);
            defer freeResults(values);
            break :blk if (values.len == 0) .nil else values[0];
        } else if (root_value == module_root_empty)
            .nil
        else
            try self.materializeConstant(root_value);
        if (value == .nil) {
            if (canonical) |text| if (self.package_loaded) |loaded| {
                if (loaded.rawGet(.{ .string = text })) |existing| value = existing;
            };
            if (value == .nil) value = .{ .boolean = true };
        }
        const value_slot = std.math.cast(u32, self.module_values.items.len) orelse return error.TooManyLoadedModules;
        try self.module_values.ensureUnusedCapacity(self.allocator, 1);
        if (canonical) |text| if (self.package_loaded) |loaded|
            try loaded.rawSet(self.allocator, .{ .string = text }, value);
        self.module_values.appendAssumeCapacity(value);
        self.module_value_slots[module_id] = value_slot;
        self.module_state[module_id] = 2;
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

    pub fn requireByName(self: *Context, raw_name: []const u8) anyerror!Value {
        if (self.package_loaded) |loaded| if (loaded.rawGet(.{ .string = raw_name })) |value| return value;
        const module_id = try self.resolveModule(raw_name);
        const value = try self.loadModule(module_id, raw_name);
        if (self.package_loaded) |loaded| try loaded.rawSet(self.allocator, .{ .string = raw_name }, value);
        return value;
    }

    pub inline fn callKnownDirect(self: *Context, callable: Value, expected: u32, direct: DirectFunctionFn, args: []const Value) anyerror![]const Value {
        if (callable == .function and callable.function.id == expected)
            return self.callDirectFunction(callable.function, direct, args);
        return self.callValue(callable, args);
    }

    pub inline fn callKnown(self: *Context, callable: Value, expected: u32, args: []const Value) anyerror![]const Value {
        if (callable == .function and callable.function.id == expected)
            return self.callFunction(callable.function, args);
        return self.callValue(callable, args);
    }

    pub inline fn callKnownNative(self: *Context, callable: Value, expected: Value, args: []const Value) anyerror![]const Value {
        if (callable == .native and expected == .native and callable.native.call == expected.native.call) {
            return self.callNative(callable.native, args);
        }
        return self.callValue(callable, args);
    }

    fn expectedNativeField(_: *Context, guard: NativeFieldGuard) ?Value {
        if (guard.root != .table) return null;
        var table = guard.root.table;
        if (guard.child_slot) |child_index| {
            if (table.native_namespace != .mw or child_index >= table.slots.len) return null;
            const child = table.slots[child_index];
            if (child != .table or child.table.native_namespace != guard.namespace) return null;
            table = child.table;
        } else if (table.native_namespace != guard.namespace) {
            return null;
        }
        if (guard.slot >= table.slots.len) return null;
        return table.slots[guard.slot];
    }

    pub inline fn callKnownNativeField(self: *Context, callable: Value, namespace: static_fields.Namespace, slot: u32, root: Value, child_slot: ?u32, args: []const Value) anyerror![]const Value {
        const expected = self.expectedNativeField(.{ .namespace = namespace, .slot = slot, .root = root, .child_slot = child_slot }) orelse return self.callValue(callable, args);
        return self.callKnownNative(callable, expected, args);
    }

    pub inline fn callKnownNativeFieldCandidates(self: *Context, callable: Value, guards: []const NativeFieldGuard, args: []const Value) anyerror![]const Value {
        if (callable == .native) {
            for (guards) |guard| {
                const expected = self.expectedNativeField(guard) orelse continue;
                if (expected == .native and callable.native.call == expected.native.call)
                    return self.callNative(callable.native, args);
            }
        }
        return self.callValue(callable, args);
    }

    pub fn callValue(self: *Context, callable: Value, args: []const Value) anyerror![]const Value {
        return switch (callable) {
            .function => |value| self.callFunction(value, args),
            .native => |value| self.callNative(value, args),
            .table => blk: {
                const method = self.metamethod(callable, "__call") orelse return error.NotCallable;
                const all = try std.heap.smp_allocator.alloc(Value, args.len + 1);
                defer rawFreeSlice(Value, std.heap.smp_allocator, all);
                all[0] = callable;
                @memcpy(all[1..], args);
                break :blk try self.callValue(method, all);
            },
            else => error.NotCallable,
        };
    }
    pub fn newNative(self: *Context, host: ?*anyopaque, comptime call: anytype) !Value {
        const native = try self.allocator.create(NativeFunction);
        native.* = .{ .ctx = host, .call = call, .stable_call = stabilizeNative(call) };
        return .{ .native = native };
    }

    pub fn newTable(self: *Context) !*Table {
        const table = try self.allocator.create(Table);
        table.* = .{};
        return table;
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

    pub fn newShape(self: *Context, shape_id: u32) !*Table {
        if (shape_id >= self.shapes.len) return error.BadShape;
        const desc = &self.shapes[shape_id];
        const table = try self.allocator.create(Table);
        errdefer self.allocator.destroy(table);
        table.* = .{ .shape = desc };
        if (desc.field_count != 0) {
            table.slots = try self.allocator.alloc(Value, desc.field_count);
            @memset(table.slots, .nil);
        }
        if (desc.choice_count != 0) {
            table.choices = try self.allocator.alloc(ChoiceCell, desc.choice_count);
            @memset(table.choices, .{});
        }
        return table;
    }

    fn constantById(self: *const Context, id: u32) anyerror!Constant {
        if (self.program_data) |view| {
            return switch (try view.constant(id)) {
                .nil => .nil,
                .boolean => |value| .{ .boolean = value },
                .number_bits => |bits| .{ .number = @bitCast(bits) },
                .string => |value| .{ .string = value },
                .table => |table| .{ .table = .{ .first = table.first, .count = table.count, .shape = table.shape } },
            };
        }
        var low: usize = 0;
        var high = self.constant_blocks.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const block = self.constant_blocks[mid];
            if (id < block.first) {
                high = mid;
            } else {
                const offset = @as(usize, id - block.first);
                if (offset < block.values.len) return block.values[offset];
                low = mid + 1;
            }
        }
        return error.BadConstantReference;
    }

    fn constantEntryAt(self: *const Context, id: u32) anyerror!ConstantEntry {
        if (self.program_data) |view| return view.entry(id);
        var low: usize = 0;
        var high = self.constant_entry_blocks.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const block = self.constant_entry_blocks[mid];
            if (id < block.first) {
                high = mid;
            } else {
                const offset = @as(usize, id - block.first);
                if (offset < block.values.len) return block.values[offset];
                low = mid + 1;
            }
        }
        return error.BadConstantEntryRange;
    }

    pub fn materializeConstant(self: *Context, id: u32) anyerror!Value {
        return switch (try self.constantById(id)) {
            .nil => .nil,
            .boolean => |value| .{ .boolean = value },
            .number => |value| .{ .number = value },
            .string => |value| .{ .string = value },
            .table => |table| blk: {
                if (table.count > std.math.maxInt(u32) - table.first) return error.BadConstantEntryRange;
                const object = if (table.shape == no_shape) try self.newTable() else try self.newShape(table.shape);
                var list_index: u32 = 1;
                for (0..table.count) |offset| {
                    const entry_id = table.first + @as(u32, @intCast(offset));
                    const entry = try self.constantEntryAt(entry_id);
                    const key_id = constantEntryKey(entry);
                    const value_id = constantEntryValue(entry);
                    const key: Value = if (key_id == implicit_list_key) list: {
                        const value: Value = .{ .number = @floatFromInt(list_index) };
                        list_index += 1;
                        break :list value;
                    } else try self.materializeConstant(key_id);
                    const value = try self.materializeConstant(value_id);
                    try object.rawSet(self.allocator, key, value);
                }
                object.append_index = list_index;
                break :blk .{ .table = object };
            },
        };
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

    fn getLocalSlot(self: *Context, object: Value, slot: u32) anyerror!Value {
        if (object != .table) return error.IndexType;
        if (object.table.rawGetSlot(slot)) |value| return value;
        if (object.table.metatable == null) return .nil;
        const key = object.table.fieldKey(slot) orelse return error.BadAnonymousShapeMetatable;
        return self.getIndex(object, key);
    }

    pub fn getSlot(self: *Context, object: Value, slot: u32) anyerror!Value {
        if (static_keys.integerForRef(slot)) |integer| {
            const key: Value = .{ .number = @floatFromInt(integer) };
            if (object == .table) if (object.table.slotForKey(key)) |local| return self.getLocalSlot(object, local);
            return self.getIndex(object, key);
        }
        if (static_fields.nameForRef(slot)) |name| {
            if (object == .table) if (object.table.native_namespace) |namespace| {
                if (static_fields.slotForRef(namespace, slot)) |local| return self.getLocalSlot(object, local);
            };
            return self.getIndex(object, .{ .string = name });
        }
        return self.getLocalSlot(object, slot);
    }

    fn setLocalSlot(self: *Context, object: Value, slot: u32, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        if (object.table.rawGetSlot(slot) != null or object.table.metatable == null)
            return object.table.rawSetSlot(slot, value);
        const key = object.table.fieldKey(slot) orelse return error.BadAnonymousShapeMetatable;
        return self.setIndex(object, key, value);
    }

    pub fn setSlot(self: *Context, object: Value, slot: u32, value: Value) anyerror!void {
        if (static_keys.integerForRef(slot)) |integer| {
            const key: Value = .{ .number = @floatFromInt(integer) };
            if (object == .table) if (object.table.slotForKey(key)) |local| return self.setLocalSlot(object, local, value);
            return self.setIndex(object, key, value);
        }
        if (static_fields.nameForRef(slot)) |name| {
            if (object == .table) if (object.table.native_namespace) |namespace| {
                if (static_fields.slotForRef(namespace, slot)) |local| return self.setLocalSlot(object, local, value);
            };
            return self.setIndex(object, .{ .string = name }, value);
        }
        return self.setLocalSlot(object, slot, value);
    }
    pub fn getChoice(self: *Context, object: Value, choice: u32, key: Value) anyerror!Value {
        if (object != .table) return error.IndexType;
        if (object.table.rawGetChoice(choice, key)) |value| return value;
        if (object.table.metatable == null) return .nil;
        return self.getIndex(object, key);
    }

    pub fn setChoice(self: *Context, object: Value, choice: u32, key: Value, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        if (object.table.rawGetChoice(choice, key) != null or object.table.metatable == null)
            return object.table.rawSetChoice(choice, key, value);
        return self.setIndex(object, key, value);
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
        const name = if (op == .lt or op == .gt) "__lt" else "__le";
        const left = if (op == .gt or op == .ge) b else a;
        const right = if (op == .gt or op == .ge) a else b;
        if (self.metamethod(left, name) orelse self.metamethod(right, name)) |method| {
            const out = try self.callValue(method, &.{ left, right });
            defer freeResults(out);
            return out.len != 0 and out[0].truthy();
        }
        return error.CompareType;
    }
    fn internString(self: *Context, text: []const u8) ![]const u8 {
        if (self.string_intern.get(text)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, text);
        try self.string_intern.put(self.allocator, owned, owned);
        return owned;
    }

    pub fn concatValues(self: *Context, values: []const Value) anyerror!Value {
        var scratch = std.heap.stackFallback(1024, std.heap.smp_allocator);
        const allocator = scratch.get();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (values) |value| switch (value) {
            .string => |text| try out.appendSlice(allocator, text),
            .number => |number| {
                var buf: [128]u8 = undefined;
                const text = if (@floor(number) == number)
                    try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(number))})
                else
                    try std.fmt.bufPrint(&buf, "{d}", .{number});
                try out.appendSlice(allocator, text);
            },
            else => return error.ConcatType,
        };
        return .{ .string = try self.internString(out.items) };
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

test "AOT module resolver caches numeric identities and exposes package.loaded aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 3);
    defer ctx.deinit();
    const functions = [_]FunctionFn{ stabilize(ModuleRuntimeProbe.named), stabilize(ModuleRuntimeProbe.packageOverride), stabilize(ModuleRuntimeProbe.loop) };
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    const roots = [_]u32{ 0, 1, 2 };
    ctx.function_blocks = &blocks;
    ctx.module_roots = &roots;
    ctx.configureModules(null, ModuleRuntimeProbe.lookup, ModuleRuntimeProbe.name);
    ctx.package_loaded = try ctx.newTable();
    try ctx.ensureModule(0);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Module:A" }).?.string);

    const alias = try ctx.requireByName("Alias:A");
    try std.testing.expectEqualStrings("Module:A", alias.string);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    const canonical = try ctx.requireByName("Module:A");
    try std.testing.expectEqualStrings("Module:A", canonical.string);
    try std.testing.expectEqual(@as(f64, 1), ctx.getGlobal(0).number);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Alias:A" }).?.string);
    try std.testing.expectEqualStrings("Module:A", ctx.package_loaded.?.rawGet(.{ .string = "Module:A" }).?.string);

    const overridden = try ctx.requireByName("Module:B");
    try std.testing.expectEqualStrings("override", overridden.string);
    try std.testing.expectError(error.AotCallFailed, ctx.requireByName("Module:Loop"));
    try std.testing.expectEqualStrings("ModuleLoadLoop", ctx.aotErrorName().?);
    ctx.clearAotErrorName();
    ctx.last_error = .nil;
    try std.testing.expectEqual(@as(u8, 0), ctx.module_state[2]);
    try std.testing.expectEqual(std.math.maxInt(u32), ctx.module_value_slots[2]);
    try std.testing.expectError(error.ModuleNotFound, ctx.requireByName("Module:Missing"));
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
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    const roots = [_]u32{ 0, 1 };
    ctx.function_blocks = &blocks;
    ctx.module_roots = &roots;

    const outer = try ctx.loadModule(0, null);
    const loaded_inner = try ctx.loadModule(1, null);
    const cached_outer = try ctx.loadModule(0, null);
    try std.testing.expectEqualStrings("outer", outer.string);
    try std.testing.expectEqualStrings("inner", loaded_inner.string);
    try std.testing.expectEqualStrings("outer", cached_outer.string);
    try std.testing.expect(ctx.module_value_slots[0] != ctx.module_value_slots[1]);
}

test "descriptor module roots materialize constants without generated functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const functions = [_]FunctionFn{stabilize(descriptorModuleRootStub)};
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    const roots = [_]u32{ 0, 0 };
    const root_values = [_]u32{ 0, module_root_empty };
    const constants = [_]Constant{.{ .table = .{ .first = 0, .count = 0 } }};
    const constant_blocks = [_]ConstantBlock{.{ .first = 0, .values = &constants }};
    ctx.function_blocks = &blocks;
    ctx.constant_blocks = &constant_blocks;
    ctx.module_roots = &roots;
    ctx.module_root_values = &root_values;

    const first = try ctx.loadModule(0, null);
    const second = try ctx.loadModule(0, null);
    try std.testing.expect(first == .table and second == .table and first.table == second.table);
    var child = try ctx.forkProgram(arena.allocator());
    defer child.deinit();
    const fresh = try child.loadModule(0, null);
    try std.testing.expect(fresh == .table and fresh.table != first.table);
    const empty = try ctx.loadModule(1, null);
    try std.testing.expect(empty == .boolean and empty.boolean);
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

test "guarded native call matches callback identity and uses actual context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 4 });
    var expected_host = NativeHostProbe{ .value = 90 };
    var actual_host = NativeHostProbe{ .value = 7 };
    const expected = try ctx.newNative(&expected_host, NativeHostProbe.call);
    const actual = try ctx.newNative(&actual_host, NativeHostProbe.call);
    const out = try ctx.callKnownNative(actual, expected, &.{ .nil, .nil });
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 13), out[0].number);
}

test "guarded native call falls back on callback mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    var expected_host = NativeHostProbe{ .value = 1 };
    var actual_host = OtherNativeHostProbe{ .value = 9 };
    const expected = try ctx.newNative(&expected_host, NativeHostProbe.call);
    const actual = try ctx.newNative(&actual_host, OtherNativeHostProbe.call);
    const out = try ctx.callKnownNative(actual, expected, &.{});
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 109), out[0].number);
}

test "guarded native field resolves root namespace callback identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 4 });
    const table = try ctx.newNativeNamespace(.table);
    var expected_host = NativeHostProbe{ .value = 90 };
    var actual_host = NativeHostProbe{ .value = 7 };
    try table.rawSet(ctx.allocator, .{ .string = "insert" }, try ctx.newNative(&expected_host, NativeHostProbe.call));
    const actual = try ctx.newNative(&actual_host, NativeHostProbe.call);
    const insert_slot = static_fields.slotForName(.table, "insert") orelse return error.MissingStaticField;
    const out = try ctx.callKnownNativeField(actual, .table, insert_slot, .{ .table = table }, null, &.{ .nil, .nil });
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 13), out[0].number);
}

test "guarded native field resolves canonical nested namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 4 });
    const mw = try ctx.newNativeNamespace(.mw);
    const ustring = try ctx.newNativeNamespace(.ustring);
    try mw.rawSet(ctx.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    var expected_host = NativeHostProbe{ .value = 90 };
    var actual_host = NativeHostProbe{ .value = 7 };
    try ustring.rawSet(ctx.allocator, .{ .string = "gsub" }, try ctx.newNative(&expected_host, NativeHostProbe.call));
    const actual = try ctx.newNative(&actual_host, NativeHostProbe.call);
    const child_slot = static_fields.slotForName(.mw, "ustring") orelse return error.MissingStaticField;
    const gsub_slot = static_fields.slotForName(.ustring, "gsub") orelse return error.MissingStaticField;
    const out = try ctx.callKnownNativeField(actual, .ustring, gsub_slot, .{ .table = mw }, child_slot, &.{ .nil, .nil });
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 13), out[0].number);
}

test "candidate native field guard matches shared canonical callbacks and uses actual context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 4 });
    const string = try ctx.newNativeNamespace(.string);
    const mw = try ctx.newNativeNamespace(.mw);
    const ustring = try ctx.newNativeNamespace(.ustring);
    try mw.rawSet(ctx.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    var string_host = OtherNativeHostProbe{ .value = 1 };
    var ustring_host = NativeHostProbe{ .value = 90 };
    var actual_string_host = OtherNativeHostProbe{ .value = 9 };
    var actual_ustring_host = NativeHostProbe{ .value = 7 };
    const string_slot = static_fields.slotForName(.string, "gsub") orelse return error.MissingStaticField;
    const ustring_slot = static_fields.slotForName(.ustring, "gsub") orelse return error.MissingStaticField;
    const child_slot = static_fields.slotForName(.mw, "ustring") orelse return error.MissingStaticField;
    try string.rawSet(ctx.allocator, .{ .string = "gsub" }, try ctx.newNative(&string_host, OtherNativeHostProbe.call));
    try ustring.rawSet(ctx.allocator, .{ .string = "gsub" }, try ctx.newNative(&ustring_host, NativeHostProbe.call));
    const guards = [_]NativeFieldGuard{
        .{ .namespace = .string, .slot = string_slot, .root = .{ .table = string } },
        .{ .namespace = .ustring, .slot = ustring_slot, .root = .{ .table = mw }, .child_slot = child_slot },
    };

    const actual_string = try ctx.newNative(&actual_string_host, OtherNativeHostProbe.call);
    const string_out = try ctx.callKnownNativeFieldCandidates(actual_string, &guards, &.{});
    defer freeResults(string_out);
    try std.testing.expectEqual(@as(f64, 109), string_out[0].number);

    const actual_ustring = try ctx.newNative(&actual_ustring_host, NativeHostProbe.call);
    const ustring_out = try ctx.callKnownNativeFieldCandidates(actual_ustring, &guards, &.{ .nil, .nil });
    defer freeResults(ustring_out);
    try std.testing.expectEqual(@as(f64, 13), ustring_out[0].number);
}

test "candidate native field guard falls back to Lua and mismatched native callables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const functions = [_]FunctionFn{stabilize(candidateLuaFallback)};
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    ctx.function_blocks = &blocks;
    const table = try ctx.newNativeNamespace(.table);
    var expected_host = NativeHostProbe{ .value = 1 };
    var mismatch_host = OtherNativeHostProbe{ .value = 9 };
    const insert_slot = static_fields.slotForName(.table, "insert") orelse return error.MissingStaticField;
    try table.rawSet(ctx.allocator, .{ .string = "insert" }, try ctx.newNative(&expected_host, NativeHostProbe.call));
    const guards = [_]NativeFieldGuard{.{ .namespace = .table, .slot = insert_slot, .root = .{ .table = table } }};

    const lua_callable = try ctx.makeFunction(0, &.{});
    const lua_out = try ctx.callKnownNativeFieldCandidates(lua_callable, &guards, &.{});
    defer freeResults(lua_out);
    try std.testing.expectEqual(@as(f64, 7), lua_out[0].number);

    const mismatch = try ctx.newNative(&mismatch_host, OtherNativeHostProbe.call);
    const mismatch_out = try ctx.callKnownNativeFieldCandidates(mismatch, &guards, &.{});
    defer freeResults(mismatch_out);
    try std.testing.expectEqual(@as(f64, 109), mismatch_out[0].number);
}

test "candidate native field guard observes namespace and field rebinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 2);
    defer ctx.deinit();
    try ctx.setGlobal(1, .{ .number = 4 });
    const string = try ctx.newNativeNamespace(.string);
    var original_host = NativeHostProbe{ .value = 90 };
    var rebound_host = OtherNativeHostProbe{ .value = 1 };
    var actual_host = NativeHostProbe{ .value = 7 };
    const gsub_slot = static_fields.slotForName(.string, "gsub") orelse return error.MissingStaticField;
    try string.rawSet(ctx.allocator, .{ .string = "gsub" }, try ctx.newNative(&original_host, NativeHostProbe.call));
    const actual = try ctx.newNative(&actual_host, NativeHostProbe.call);

    try string.rawSet(ctx.allocator, .{ .string = "gsub" }, try ctx.newNative(&rebound_host, OtherNativeHostProbe.call));
    const field_rebound = [_]NativeFieldGuard{.{ .namespace = .string, .slot = gsub_slot, .root = .{ .table = string } }};
    const field_out = try ctx.callKnownNativeFieldCandidates(actual, &field_rebound, &.{ .nil, .nil });
    defer freeResults(field_out);
    try std.testing.expectEqual(@as(f64, 13), field_out[0].number);

    const replacement = try ctx.newTable();
    const namespace_rebound = [_]NativeFieldGuard{.{ .namespace = .string, .slot = gsub_slot, .root = .{ .table = replacement } }};
    const namespace_out = try ctx.callKnownNativeFieldCandidates(actual, &namespace_rebound, &.{ .nil, .nil });
    defer freeResults(namespace_out);
    try std.testing.expectEqual(@as(f64, 13), namespace_out[0].number);
}

test "AOT runtime globals are numeric slots without hash storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 8);
    try ctx.setGlobal(3, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), ctx.getGlobal(3).number);
}
test "AOT constant templates preserve fresh table identity across blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const shape_keys = [_]Value{.{ .string = "x" }};
    const shapes = [_]Shape{.{ .field_keys = &shape_keys, .field_count = 1, .open = true }};
    ctx.shapes = &shapes;
    const constants_a = [_]Constant{ .{ .number = 4 }, .{ .string = "x" } };
    const constants_b = [_]Constant{
        .{ .table = .{ .first = 0, .count = 2, .shape = 0 } },
        .{ .table = .{ .first = 2, .count = 1 } },
    };
    const entries_a = [_]ConstantEntry{
        packConstantEntry(1, 0),
        packConstantEntry(implicit_list_key, 0),
    };
    const entries_b = [_]ConstantEntry{packConstantEntry(1, 2)};
    const constant_blocks = [_]ConstantBlock{
        .{ .first = 0, .values = &constants_a },
        .{ .first = 2, .values = &constants_b },
    };
    const entry_blocks = [_]ConstantEntryBlock{
        .{ .first = 0, .values = &entries_a },
        .{ .first = 2, .values = &entries_b },
    };
    ctx.constant_blocks = &constant_blocks;
    ctx.constant_entry_blocks = &entry_blocks;
    const left = try ctx.materializeConstant(2);
    const right = try ctx.materializeConstant(2);
    try std.testing.expect(left == .table and right == .table and left.table != right.table);
    try std.testing.expect(left.table.shape == &shapes[0] and left.table.slots.len == 1);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .number = 1 }).?.number);
    const outer_left = try ctx.materializeConstant(3);
    const outer_right = try ctx.materializeConstant(3);
    const nested_left = outer_left.table.rawGet(.{ .string = "x" }).?;
    const nested_right = outer_right.table.rawGet(.{ .string = "x" }).?;
    try std.testing.expect(nested_left == .table and nested_right == .table and nested_left.table != nested_right.table);
}

test "external AOT data materializes fresh shaped tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const shape_keys = [_]Value{.{ .string = "x" }};
    const shapes = [_]Shape{.{ .field_keys = &shape_keys, .field_count = 1, .open = true }};
    ctx.shapes = &shapes;

    const l = try aot_data.layout(4, 3, 1);
    const bytes = try arena.allocator().alloc(u8, l.total);
    @memset(bytes, 0);
    try aot_data.writeHeader(bytes, l);
    try aot_data.writeRecord(bytes, l, 0, .number, @bitCast(@as(f64, 4)), 0);
    try aot_data.writeRecord(bytes, l, 1, .string, 0, 1);
    try aot_data.writeRecord(bytes, l, 2, .table, (@as(u64, 2) << 32), 0);
    try aot_data.writeRecord(bytes, l, 3, .table, (@as(u64, 1) << 32) | 2, no_shape);
    try aot_data.writeEntry(bytes, l, 0, packConstantEntry(1, 0));
    try aot_data.writeEntry(bytes, l, 1, packConstantEntry(implicit_list_key, 0));
    try aot_data.writeEntry(bytes, l, 2, packConstantEntry(1, 2));
    bytes[l.strings_offset] = 'x';
    ctx.program_data = try ProgramData.parse(bytes);

    const left = try ctx.materializeConstant(2);
    const right = try ctx.materializeConstant(2);
    try std.testing.expect(left == .table and right == .table and left.table != right.table);
    try std.testing.expect(left.table.shape == &shapes[0]);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .number = 1 }).?.number);
    const outer_left = try ctx.materializeConstant(3);
    const outer_right = try ctx.materializeConstant(3);
    try std.testing.expect(outer_left.table.rawGet(.{ .string = "x" }).?.table != outer_right.table.rawGet(.{ .string = "x" }).?.table);
}

test "AOT external program data preserves fresh table materialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const shape_keys = [_]Value{.{ .string = "x" }};
    const shapes = [_]Shape{.{ .field_keys = &shape_keys, .field_count = 1, .open = true }};
    ctx.shapes = &shapes;

    const l = try aot_data.layout(3, 2, 1);
    const bytes = try arena.allocator().alloc(u8, l.total);
    @memset(bytes, 0);
    try aot_data.writeHeader(bytes, l);
    try aot_data.writeRecord(bytes, l, 0, .number, @bitCast(@as(f64, 4)), 0);
    try aot_data.writeRecord(bytes, l, 1, .string, 0, 1);
    try aot_data.writeRecord(bytes, l, 2, .table, (@as(u64, 2) << 32), 0);
    try aot_data.writeEntry(bytes, l, 0, packConstantEntry(1, 0));
    try aot_data.writeEntry(bytes, l, 1, packConstantEntry(implicit_list_key, 0));
    bytes[l.strings_offset] = 'x';
    ctx.program_data = try aot_data.View.parse(bytes);

    const left = try ctx.materializeConstant(2);
    const right = try ctx.materializeConstant(2);
    try std.testing.expect(left == .table and right == .table and left.table != right.table);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .number = 1 }).?.number);
}

test "AOT frames without captures allocate no cell plane" {
    var regs: [3]Value = undefined;
    var frame = try Frame.initAotNoCells(&regs, &.{.{ .number = 7 }}, 2, false);
    try std.testing.expectEqual(@as(usize, 0), frame.cells.len);
    try std.testing.expectEqual(@as(f64, 7), frame.get(0).number);
    try std.testing.expect(frame.get(1) == .nil);
    frame.set(2, .{ .string = "ok" });
    try std.testing.expectEqualStrings("ok", frame.get(2).string);
    var ctx = try Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    try std.testing.expectError(error.BadFrame, frame.ensureCell(&ctx, 2));
}

test "AOT module functions share one activation environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const functions = [_]FunctionFn{
        stabilize(descriptorModuleRootStub), stabilize(descriptorModuleRootStub), stabilize(descriptorModuleRootStub),
        stabilize(descriptorModuleRootStub), stabilize(descriptorModuleRootStub), stabilize(descriptorModuleRootStub),
    };
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    ctx.function_blocks = &blocks;
    var regs: [3]Value = undefined;
    var cells: [3]?*Cell = undefined;
    var frame = try Frame.init(&regs, &cells, &.{}, 0, false);
    frame.set(1, .{ .number = 7 });
    _ = try frame.ensureCell(&ctx, 1);
    const env = try frame.ensureModuleEnv(&ctx);
    try std.testing.expect(env == try frame.ensureModuleEnv(&ctx));
    const first = try ctx.makeModuleFunction(4, env);
    const second = try ctx.makeModuleFunction(5, env);
    try std.testing.expect(first.function.env.modulePtr() == second.function.env.modulePtr());
    try std.testing.expect(first.function.env.closurePtr() == null);
    try std.testing.expect(!rawEqual(first, second));
    try ctx.bindModuleEnv(1, env);
    try ctx.bindModuleEnv(1, env);
    const registered = try ctx.moduleCaptures(1);
    try std.testing.expect(registered.module == env);
    const capture = try registered.cell(0, 1);
    try std.testing.expectEqual(@as(f64, 7), capture.value.number);
    frame.set(1, .{ .number = 9 });
    try std.testing.expectEqual(@as(f64, 9), capture.value.number);
    var other_regs: [1]Value = undefined;
    var other_cells: [1]?*Cell = undefined;
    var other_frame = try Frame.init(&other_regs, &other_cells, &.{}, 0, false);
    const other_env = try other_frame.ensureModuleEnv(&ctx);
    try std.testing.expectError(error.ModuleEnvironmentMismatch, ctx.bindModuleEnv(1, other_env));
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 32), @sizeOf(FunctionValue));
}

pub fn mergeValues(prefix: []const Value, tail: []const Value) ![]Value {
    const out = try std.heap.smp_allocator.alloc(Value, prefix.len + tail.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], tail);
    return out;
}

pub fn freeValues(values: []Value) void {
    rawFreeSlice(Value, std.heap.smp_allocator, values);
}
pub inline fn touch(value: anytype) void {
    _ = value;
}
pub fn bindGlobalTable(ctx: *Context, shape: ?*const Shape, env_slot: u32) !void {
    if (ctx.global_table != null) return error.GlobalTableAlreadyBound;
    const table = try ctx.allocator.create(Table);
    table.* = .{ .shape = shape, .slots = ctx.globals, .owns_slots = false };
    ctx.global_table = table;
    try ctx.setGlobal(env_slot, .{ .table = table });
}

fn guardCapture(captures: Captures) f64 {
    return switch (captures) {
        .direct => |cells| if (cells.len == 0) 0 else cells[0].value.number,
        .module => |env| if (env.cells.len == 0 or env.cells[0] == null) 0 else env.cells[0].?.value.number,
    };
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

test "guarded call uses the runtime capture environment on a match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const functions = [_]FunctionFn{ stabilize(guardTestExpected), stabilize(guardTestOther) };
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    ctx.function_blocks = &blocks;
    var cell = Cell{ .value = .{ .number = 7 } };
    const callable = try ctx.makeFunction(0, &.{&cell});
    const out = try ctx.callKnownDirect(callable, 0, guardTestExpected, &.{.{ .number = 3 }});
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 10), out[0].number);
}

test "guarded call falls back to the actual function on an id mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const functions = [_]FunctionFn{ stabilize(guardTestExpected), stabilize(guardTestOther) };
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    ctx.function_blocks = &blocks;
    var cell = Cell{ .value = .{ .number = 7 } };
    const callable = try ctx.makeFunction(1, &.{&cell});
    const out = try ctx.callKnown(callable, 0, &.{.{ .number = 3 }});
    defer freeResults(out);
    try std.testing.expectEqual(@as(f64, 110), out[0].number);
}

test "Lua closures retain their compiled entrypoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const functions = [_]FunctionFn{stabilize(guardTestOther)};
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    ctx.function_blocks = &blocks;
    var cell = Cell{ .value = .{ .number = 7 } };
    const callable = try ctx.makeFunction(0, &.{&cell});
    ctx.function_blocks = &.{};
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
    try std.testing.expectError(error.AotCallFailed, ctx.callValue(callable, &.{}));
    try std.testing.expectEqualStrings("NativeDispatchProbe", ctx.aotErrorName().?);
}

test "candidate native field calls invoke the callable entrypoint directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const string = try ctx.newNativeNamespace(.string);
    const slot = static_fields.slotForName(.string, "gsub") orelse return error.MissingStaticField;
    const callable = try ctx.newNative(null, nativeDispatchFailureProbe);
    try string.rawSet(ctx.allocator, .{ .string = "gsub" }, callable);
    const guards = [_]NativeFieldGuard{.{ .namespace = .string, .slot = slot, .root = .{ .table = string } }};
    try std.testing.expectError(error.AotCallFailed, ctx.callKnownNativeFieldCandidates(callable, &guards, &.{}));
    try std.testing.expectEqualStrings("NativeDispatchProbe", ctx.aotErrorName().?);
}

test "forked AOT context shares program metadata but resets runtime state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parent = try Context.initProgram(arena.allocator(), 2, 1);
    defer parent.deinit();
    const functions = [_]FunctionFn{stabilize(ModuleRuntimeProbe.named)};
    const blocks = [_]FunctionBlock{.{ .first = 0, .values = &functions }};
    const roots = [_]u32{0};
    const root_values = [_]u32{module_root_function};
    parent.function_blocks = &blocks;
    parent.module_roots = &roots;
    parent.module_root_values = &root_values;
    parent.configureModules(null, ModuleRuntimeProbe.lookup, ModuleRuntimeProbe.name);
    var host_marker: u8 = 0;
    parent.setHost(&host_marker);
    parent.current_frame = try parent.newTable();
    try parent.setGlobal(1, .{ .number = 9 });
    parent.module_state[0] = 2;

    var child = try parent.forkProgram(arena.allocator());
    defer child.deinit();
    try std.testing.expect(child.function_blocks.ptr == parent.function_blocks.ptr);
    try std.testing.expect(child.module_roots.ptr == parent.module_roots.ptr);
    try std.testing.expect(child.module_root_values.ptr == parent.module_root_values.ptr);
    try std.testing.expect(child.getGlobal(1) == .nil);
    try std.testing.expectEqual(@as(u8, 0), child.module_state[0]);
    try std.testing.expect(child.host == parent.host);
    try std.testing.expect(child.current_frame == null);
    try std.testing.expectEqual(@as(u32, 0), try child.resolveModule("Module:A"));
}

test "static field refs use native slots and generic fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const insert_ref = static_fields.refForName("insert") orelse return error.MissingStaticField;

    const native = try ctx.newNativeNamespace(.table);
    try native.rawSet(ctx.allocator, .{ .string = "insert" }, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getSlot(.{ .table = native }, insert_ref)).number);
    try ctx.setSlot(.{ .table = native }, insert_ref, .{ .number = 4 });
    try std.testing.expectEqual(@as(f64, 4), native.rawGet(.{ .string = "insert" }).?.number);

    const generic = try ctx.newTable();
    try generic.rawSet(ctx.allocator, .{ .string = "insert" }, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getSlot(.{ .table = generic }, insert_ref)).number);
    try ctx.setSlot(.{ .table = generic }, insert_ref, .{ .number = 8 });
    try std.testing.expectEqual(@as(f64, 8), generic.rawGet(.{ .string = "insert" }).?.number);
}

test "numeric shape keys share slot raw length and iteration semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const keys = [_]Value{ .{ .number = 1 }, .{ .string = "x" } };
    const shapes = [_]Shape{.{ .field_keys = &keys, .field_count = 2, .open = true }};
    ctx.shapes = &shapes;
    const table = try ctx.newShape(0);
    try table.rawSet(ctx.allocator, .{ .number = 1 }, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getSlot(.{ .table = table }, 0)).number);
    try ctx.setSlot(.{ .table = table }, 0, .{ .number = 4 });
    try std.testing.expectEqual(@as(f64, 4), table.rawGet(.{ .number = 1 }).?.number);
    try std.testing.expectEqual(@as(usize, 1), table.rawLen());
}

test "static numeric key refs use shaped slots and generic fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const one_ref = static_keys.refForInteger(1) orelse return error.MissingStaticKey;
    const keys = [_]Value{.{ .number = 1 }};
    const shapes = [_]Shape{.{ .field_keys = &keys, .field_count = 1, .open = true }};
    ctx.shapes = &shapes;
    const shaped = try ctx.newShape(0);
    try shaped.rawSet(ctx.allocator, .{ .number = 1 }, .{ .number = 3 });
    try std.testing.expectEqual(@as(f64, 3), (try ctx.getSlot(.{ .table = shaped }, one_ref)).number);
    try ctx.setSlot(.{ .table = shaped }, one_ref, .{ .number = 4 });
    try std.testing.expectEqual(@as(f64, 4), shaped.rawGet(.{ .number = 1 }).?.number);
    const generic = try ctx.newTable();
    try generic.rawSet(ctx.allocator, .{ .number = 1 }, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), (try ctx.getSlot(.{ .table = generic }, one_ref)).number);
    try ctx.setSlot(.{ .table = generic }, one_ref, .{ .number = 8 });
    try std.testing.expectEqual(@as(f64, 8), generic.rawGet(.{ .number = 1 }).?.number);
}
