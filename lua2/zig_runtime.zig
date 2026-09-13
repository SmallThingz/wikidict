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

    pub fn native(host: ?*anyopaque) FunctionEnv {
        return .{ .raw = if (host) |ptr| @intFromPtr(ptr) else 0 };
    }

    pub fn nativePtr(self: FunctionEnv) ?*anyopaque {
        return if (self.raw == 0) null else @ptrFromInt(self.raw);
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
    native: ?*anyopaque,

    pub fn cell(self: Captures, ordinal: u32, module_slot: u32) !*Cell {
        return switch (self) {
            .direct => |cells| if (ordinal < cells.len) cells[ordinal] else error.BadUpvalue,
            .module => |env| blk: {
                if (module_slot >= env.cells.len) return error.BadModuleCapture;
                break :blk env.cells[module_slot] orelse return error.BadModuleCapture;
            },
            .native => error.BadUpvalue,
        };
    }
};

pub const native_function_id = std.math.maxInt(u32);
pub const FunctionValue = struct {
    id: u32,
    env: FunctionEnv = .{},
    identity: u64,
    entry: FunctionFn,

    pub fn captures(self: FunctionValue) Captures {
        if (self.id == native_function_id) return .{ .native = self.env.nativePtr() };
        if (self.env.modulePtr()) |env| return .{ .module = env };
        if (self.env.closurePtr()) |env| return .{ .direct = env.captures };
        return .{ .direct = &.{} };
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

fn numberValueHash(number: f64) u64 {
    const normalized: f64 = if (number == 0) 0 else number;
    const bits: u64 = @bitCast(normalized);
    var bytes: [9]u8 = undefined;
    bytes[0] = @intFromEnum(std.meta.Tag(Value).number);
    @memcpy(bytes[1..], std.mem.asBytes(&bits));
    return std.hash.Wyhash.hash(0, &bytes);
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
        const tag: u8 = @intFromEnum(std.meta.activeTag(value));
        var h = std.hash.Wyhash.init(0);
        h.update(&.{tag});
        switch (value) {
            .nil => {},
            .boolean => |v| h.update(&.{@intFromBool(v)}),
            .number => unreachable,
            .string => |v| h.update(v),
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

    pub fn rawGetNumber(self: *const Table, number: f64) ?Value {
        if (self.shape == null and self.choices.len == 0)
            return self.map.getAdapted(number, NumberLookupContext{});
        const key = Value{ .number = number };
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| {
            if (cell.value != .nil and cell.key == .number and cell.key.number == number) return cell.value;
        }
        return self.map.getAdapted(number, NumberLookupContext{});
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
        pub const Position = struct { slot: u32, choice: u32, hash_index: u32 };

        pub fn position(self: *const Iterator) Position {
            return .{ .slot = self.slot, .choice = self.choice, .hash_index = self.hash.index };
        }

        pub fn restorePosition(self: *Iterator, position_value: Position) bool {
            if (position_value.slot > self.table.slots.len or position_value.choice > self.table.choices.len or position_value.hash_index > self.table.map.capacity()) return false;
            self.slot = position_value.slot;
            self.choice = position_value.choice;
            self.hash.index = position_value.hash_index;
            return true;
        }

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
        if (param_count > regs.len or cells.len > regs.len) return error.BadFrame;
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

pub const NextIterationHint = struct {
    table: *Table,
    key: Value,
    position: Table.Iterator.Position,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    globals: []Value,
    shapes: []const Shape = &.{},
    constant_blocks: []const ConstantBlock = &.{},
    constant_entry_blocks: []const ConstantEntryBlock = &.{},
    program_data: ?ProgramData = null,
    module_roots: []const u32 = &.{},
    module_root_entries: []const *const FunctionFn = &.{},
    module_root_values: []const u32 = &.{},
    string_metatable: ?*Table = null,
    string_intern: std.StringHashMapUnmanaged([]const u8) = .empty,
    last_error: Value = .nil,
    aot_error_name: StableErrorName = .{},
    depth: usize = 0,
    max_depth: usize = 1000,
    next_identity: u64 = 1,
    module_count: usize = 0,
    module_loading: std.AutoHashMapUnmanaged(u32, void) = .empty,
    module_envs: std.AutoHashMapUnmanaged(u32, *ModuleEnv) = .empty,
    module_values: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    module_lookup_ctx: ?*const anyopaque = null,
    module_lookup: ?ModuleLookupFn = null,
    module_name: ?ModuleNameFn = null,
    host: ?*anyopaque = null,
    current_frame: ?*Table = null,
    package_loaded: ?*Table = null,
    global_table: ?*Table = null,
    next_iteration_hint: ?NextIterationHint = null,

    pub fn init(allocator: std.mem.Allocator, global_count: usize) !Context {
        return initProgram(allocator, global_count, 0);
    }

    pub fn initProgram(allocator: std.mem.Allocator, global_count: usize, module_count: usize) !Context {
        const globals = try allocator.alloc(Value, global_count);
        errdefer allocator.free(globals);
        @memset(globals, .nil);
        return .{ .allocator = allocator, .globals = globals, .module_count = module_count };
    }

    pub fn forkProgram(self: *const Context, allocator: std.mem.Allocator) !Context {
        var child = try initProgram(allocator, self.globals.len, self.module_count);
        child.shapes = self.shapes;
        child.constant_blocks = self.constant_blocks;
        child.constant_entry_blocks = self.constant_entry_blocks;
        child.program_data = self.program_data;
        child.module_roots = self.module_roots;
        child.module_root_entries = self.module_root_entries;
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
        self.module_loading.deinit(self.allocator);
        self.module_envs.deinit(self.allocator);
        self.module_values.deinit(self.allocator);
        if (self.global_table) |table| {
            table.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.allocator.free(self.globals);
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
    pub fn makeFunction(self: *Context, id: u32, entry: FunctionFn, captures: []const *Cell) !Value {
        const identity = self.next_identity;
        self.next_identity +%= 1;
        const env: FunctionEnv = if (captures.len == 0) .{} else blk: {
            const owned = try self.allocator.dupe(*Cell, captures);
            const value = try self.allocator.create(Env);
            value.* = .{ .captures = owned };
            break :blk FunctionEnv.closure(value);
        };
        return .{ .callable = .{ .id = id, .env = env, .identity = identity, .entry = entry } };
    }

    pub fn makeFunctionKnown(self: *Context, id: u32, comptime entry: DirectFunctionFn, captures: []const *Cell) !Value {
        return self.makeFunction(id, stabilize(entry), captures);
    }

    pub fn makeModuleFunction(self: *Context, id: u32, entry: FunctionFn, env: *ModuleEnv) Value {
        const identity = self.next_identity;
        self.next_identity +%= 1;
        return .{ .callable = .{ .id = id, .env = FunctionEnv.module(env), .identity = identity, .entry = entry } };
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
        return self.callEntryBuffered(value.entry, value.captures(), args, result_buffer);
    }

    pub fn callFunction(self: *Context, value: FunctionValue, args: []const Value) anyerror![]const Value {
        return self.callFunctionBuffered(value, args, null);
    }

    pub inline fn callDirectFunction(self: *Context, value: FunctionValue, direct: DirectFunctionFn, args: []const Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        return direct(self, value.captures(), args);
    }

    pub inline fn callBufferedDirectFunction(self: *Context, value: FunctionValue, direct: BufferedDirectFunctionFn, args: []const Value, result_buffer: ?[]Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        return direct(self, value.captures(), args, result_buffer);
    }

    pub fn bindModuleEnv(self: *Context, module_id: u32, env: *ModuleEnv) !void {
        if (module_id >= self.module_count) return error.BadModuleId;
        if (self.module_envs.get(module_id)) |existing| {
            if (existing != env) return error.ModuleEnvironmentMismatch;
        } else {
            try self.module_envs.put(self.allocator, module_id, env);
        }
    }

    pub fn moduleCaptures(self: *const Context, module_id: u32) !Captures {
        if (module_id >= self.module_count) return error.BadModuleId;
        return .{ .module = self.module_envs.get(module_id) orelse return error.UnregisteredModuleEnvironment };
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
        if (module_id >= self.module_count or module_id >= self.module_roots.len) return error.BadModuleId;
        if (self.module_values.get(module_id)) |value| return value;
        if (self.module_loading.contains(module_id)) return error.ModuleLoadLoop;
        try self.module_loading.put(self.allocator, module_id, {});
        errdefer _ = self.module_loading.remove(module_id);

        const canonical = self.canonicalModuleName(module_id, requested);
        const root_value = if (module_id < self.module_root_values.len) self.module_root_values[module_id] else module_root_function;
        var value: Value = if (root_value == module_root_function) blk: {
            if (module_id >= self.module_root_entries.len) return error.BadModuleId;
            const argv: []const Value = if (canonical) |text| &.{.{ .string = text }} else &.{};
            const values = try self.callEntry(self.module_root_entries[module_id].*, .{ .direct = &.{} }, argv);
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
        try self.module_values.ensureUnusedCapacity(self.allocator, 1);
        if (canonical) |text| if (self.package_loaded) |loaded|
            try loaded.rawSet(self.allocator, .{ .string = text }, value);
        self.module_values.putAssumeCapacity(module_id, value);
        _ = self.module_loading.remove(module_id);
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

    pub inline fn callValueStoreFixed(self: *Context, frame: *Frame, base: u32, count: u32, callable: Value, args: []const Value) anyerror!void {
        if (count <= 8 and callable == .callable) {
            const function = callable.callable;
            if (function.id == native_function_id) {
                const values = try self.callEntry(function.entry, function.captures(), args);
                frame.storeResults(base, count, values, true);
                return;
            }
            var storage: [8]Value = undefined;
            const len: usize = @intCast(count);
            const values = try self.callFunctionBuffered(function, args, storage[0..len]);
            const owned = values.len != 0 and values.ptr != storage[0..].ptr;
            frame.storeResults(base, count, values, owned);
            return;
        }
        const values = try self.callValue(callable, args);
        frame.storeResults(base, count, values, true);
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
        const identity = self.next_identity;
        self.next_identity +%= 1;
        return .{ .callable = .{
            .id = native_function_id,
            .env = FunctionEnv.native(host),
            .identity = identity,
            .entry = stabilizeNative(call),
        } };
    }

    pub fn newNativeBuffered(self: *Context, host: ?*anyopaque, comptime call: anytype) !Value {
        const identity = self.next_identity;
        self.next_identity +%= 1;
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

test "AOT module resolver caches numeric identities and exposes package.loaded aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 1, 3);
    defer ctx.deinit();
    const functions = [_]FunctionFn{ stabilize(ModuleRuntimeProbe.named), stabilize(ModuleRuntimeProbe.packageOverride), stabilize(ModuleRuntimeProbe.loop) };
    const roots = [_]u32{ 0, 1, 2 };
    ctx.module_roots = &roots;
    ctx.module_root_entries = &.{ &functions[0], &functions[1], &functions[2] };
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
    try std.testing.expect(!ctx.module_loading.contains(2));
    try std.testing.expect(ctx.module_values.get(2) == null);
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
    const roots = [_]u32{ 0, 1 };
    ctx.module_roots = &roots;
    ctx.module_root_entries = &.{ &functions[0], &functions[1] };

    const outer = try ctx.loadModule(0, null);
    const loaded_inner = try ctx.loadModule(1, null);
    const cached_outer = try ctx.loadModule(0, null);
    try std.testing.expectEqualStrings("outer", outer.string);
    try std.testing.expectEqualStrings("inner", loaded_inner.string);
    try std.testing.expectEqualStrings("outer", cached_outer.string);
    try std.testing.expect(ctx.module_values.get(0) != null and ctx.module_values.get(1) != null);
}

test "descriptor module roots materialize constants without generated functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    const functions = [_]FunctionFn{stabilize(descriptorModuleRootStub)};
    const roots = [_]u32{ 0, 0 };
    const root_values = [_]u32{ 0, module_root_empty };
    const constants = [_]Constant{.{ .table = .{ .first = 0, .count = 0 } }};
    const constant_blocks = [_]ConstantBlock{.{ .first = 0, .values = &constants }};
    ctx.constant_blocks = &constant_blocks;
    ctx.module_roots = &roots;
    ctx.module_root_entries = &.{ &functions[0], &functions[0] };
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

test "AOT frames permit a captured-cell register prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    var regs: [5]Value = undefined;
    var cells: [2]?*Cell = undefined;
    var frame = try Frame.initAot(&regs, &cells, &.{.{ .number = 4 }}, 1, false);
    try std.testing.expectEqual(@as(usize, 2), frame.cells.len);
    frame.set(4, .{ .string = "plain" });
    try std.testing.expectEqualStrings("plain", frame.get(4).string);
    frame.set(1, .{ .number = 7 });
    const cell = try frame.ensureCell(&ctx, 1);
    frame.set(1, .{ .number = 8 });
    try std.testing.expectEqual(@as(f64, 8), cell.value.number);
    frame.detachCell(1);
    try std.testing.expect(frame.cells[1] == null);
    try std.testing.expectEqual(@as(f64, 8), frame.get(1).number);
    const reattached = try frame.ensureCell(&ctx, 1);
    try std.testing.expect(reattached != cell);
    try std.testing.expectEqual(@as(f64, 8), reattached.value.number);
    try std.testing.expectError(error.BadFrame, frame.ensureCell(&ctx, 2));
    const env = try frame.ensureModuleEnv(&ctx);
    try std.testing.expectEqual(@as(usize, 2), env.cells.len);
    try std.testing.expect(env.cells[1] == reattached);
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
    var regs: [3]Value = undefined;
    var cells: [3]?*Cell = undefined;
    var frame = try Frame.init(&regs, &cells, &.{}, 0, false);
    frame.set(1, .{ .number = 7 });
    _ = try frame.ensureCell(&ctx, 1);
    const env = try frame.ensureModuleEnv(&ctx);
    try std.testing.expect(env == try frame.ensureModuleEnv(&ctx));
    const first = ctx.makeModuleFunction(4, functions[4], env);
    const second = ctx.makeModuleFunction(5, functions[5], env);
    try std.testing.expect(first.callable.env.modulePtr() == second.callable.env.modulePtr());
    try std.testing.expect(first.callable.env.closurePtr() == null);
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
        .native => 0,
    };
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

test "dynamic fixed result storage buffers Lua functions and preserves native fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    var regs: [3]Value = undefined;
    var frame = try Frame.initAotNoCells(&regs, &.{}, 0, false);
    defer frame.deinit();

    const buffered = Value{ .callable = .{ .id = 0, .identity = 1, .entry = stabilizeBuffered(bufferedResultProbe) } };
    try ctx.callValueStoreFixed(&frame, 0, 1, buffered, &.{.{ .number = 3 }});
    try std.testing.expectEqual(@as(f64, 3), frame.get(0).number);

    const unbuffered = Value{ .callable = .{ .id = 1, .identity = 2, .entry = stabilize(guardTestExpected) } };
    try ctx.callValueStoreFixed(&frame, 1, 1, unbuffered, &.{.{ .number = 4 }});
    try std.testing.expectEqual(@as(f64, 4), frame.get(1).number);

    const native = try ctx.newNative(null, nativeBufferedOwnershipProbe);
    try ctx.callValueStoreFixed(&frame, 2, 1, native, &.{.{ .number = 5 }});
    try std.testing.expectEqual(@as(f64, 5), frame.get(2).number);
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
    try std.testing.expectEqual(@as(usize, 0), ctx.module_loading.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.module_envs.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.module_values.count());
}

test "forked AOT context shares program metadata but resets runtime state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parent = try Context.initProgram(arena.allocator(), 2, 1);
    defer parent.deinit();
    const functions = [_]FunctionFn{stabilize(ModuleRuntimeProbe.named)};
    const roots = [_]u32{0};
    const root_values = [_]u32{module_root_function};
    parent.module_roots = &roots;
    parent.module_root_entries = &.{&functions[0]};
    parent.module_root_values = &root_values;
    parent.configureModules(null, ModuleRuntimeProbe.lookup, ModuleRuntimeProbe.name);
    var host_marker: u8 = 0;
    parent.setHost(&host_marker);
    parent.current_frame = try parent.newTable();
    try parent.setGlobal(1, .{ .number = 9 });
    try parent.module_values.put(parent.allocator, 0, .{ .number = 1 });

    var child = try parent.forkProgram(arena.allocator());
    defer child.deinit();
    try std.testing.expect(child.module_roots.ptr == parent.module_roots.ptr);
    try std.testing.expect(child.module_root_values.ptr == parent.module_root_values.ptr);
    try std.testing.expect(child.getGlobal(1) == .nil);
    try std.testing.expectEqual(@as(usize, 0), child.module_values.count());
    try std.testing.expectEqual(@as(usize, 1), parent.module_values.count());
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
    try std.testing.expectEqual(@as(f64, 4), table.rawGetNumber(1).?.number);
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
