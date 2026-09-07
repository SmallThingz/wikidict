const std = @import("std");

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

    pub fn captures(self: FunctionValue) Captures {
        if (self.env.modulePtr()) |env| return .{ .module = env };
        if (self.env.closurePtr()) |env| return .{ .direct = env.captures };
        return .{ .direct = &.{} };
    }
};
pub const FunctionFn = *const fn (*Context, Captures, []const Value) anyerror![]const Value;
pub const NativeFn = *const fn (*Context, []const Value) anyerror![]const Value;
pub const NativeFunction = struct { call: NativeFn };

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
pub const TableConstant = struct { first: u32, count: u32 };
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

pub const Shape = struct {
    field_keys: []const []const u8 = &.{},
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
        if (key != .string) return null;
        const shape = self.shape orelse return null;
        if (shape.field_keys.len != shape.field_count) return null;
        for (shape.field_keys, 0..) |name, slot| {
            if (std.mem.eql(u8, name, key.string)) return @intCast(slot);
        }
        return null;
    }
    pub fn fieldKey(self: *const Table, slot: u32) ?Value {
        const shape = self.shape orelse return null;
        if (shape.field_keys.len != shape.field_count or slot >= shape.field_count) return null;
        return .{ .string = shape.field_keys[slot] };
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

    pub fn rawLen(self: *const Table) usize {
        var n: usize = 0;
        while (self.rawGet(.{ .number = @floatFromInt(n + 1) }) != null) n += 1;
        return n;
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

    pub fn deinit(self: *Frame) void {
        if (self.multi_owned) freeResults(self.multi);
    }

    pub fn get(self: *const Frame, reg: u32) Value {
        if (self.cells[reg]) |cell| return cell.value;
        return self.regs[reg];
    }

    pub fn set(self: *Frame, reg: u32, value: Value) void {
        if (self.cells[reg]) |cell| cell.value = value else self.regs[reg] = value;
    }
    pub fn ensureCell(self: *Frame, ctx: *Context, reg: u32) !*Cell {
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
    module_roots: []const u32 = &.{},
    string_metatable: ?*Table = null,
    string_intern: std.StringHashMapUnmanaged([]const u8) = .empty,
    depth: usize = 0,
    max_depth: usize = 1000,
    next_identity: u64 = 1,
    module_state: []u8 = &.{},
    module_envs: []?*ModuleEnv = &.{},
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
        return .{ .allocator = allocator, .globals = globals, .module_state = module_state, .module_envs = module_envs };
    }

    pub fn deinit(self: *Context) void {
        var it = self.string_intern.keyIterator();
        while (it.next()) |text| self.allocator.free(text.*);
        self.string_intern.deinit(self.allocator);
        if (self.global_table) |table| {
            table.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.allocator.free(self.globals);
        if (self.module_state.len != 0) self.allocator.free(self.module_state);
        if (self.module_envs.len != 0) self.allocator.free(self.module_envs);
    }

    pub fn getGlobal(self: *const Context, slot: u32) Value {
        return if (slot < self.globals.len) self.globals[slot] else .nil;
    }

    pub fn setGlobal(self: *Context, slot: u32, value: Value) !void {
        if (slot >= self.globals.len) return error.BadGlobalSlot;
        self.globals[slot] = value;
    }
    pub fn makeFunction(self: *Context, id: u32, captures: []const *Cell) !Value {
        const identity = self.next_identity;
        self.next_identity +%= 1;
        const env: FunctionEnv = if (captures.len == 0) .{} else blk: {
            const owned = try self.allocator.dupe(*Cell, captures);
            const value = try self.allocator.create(Env);
            value.* = .{ .captures = owned };
            break :blk FunctionEnv.closure(value);
        };
        return .{ .function = .{ .id = id, .env = env, .identity = identity } };
    }

    pub fn makeModuleFunction(self: *Context, id: u32, env: *ModuleEnv) Value {
        const identity = self.next_identity;
        self.next_identity +%= 1;
        return .{ .function = .{ .id = id, .env = FunctionEnv.module(env), .identity = identity } };
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

    pub fn invokeKnown(self: *Context, id: u32, captures: Captures, args: []const Value) anyerror![]const Value {
        const function = self.functionById(id) orelse return error.BadFunctionId;
        return function(self, captures, args);
    }

    pub fn callFunction(self: *Context, value: FunctionValue, args: []const Value) anyerror![]const Value {
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        return self.invokeKnown(value.id, value.captures(), args);
    }

    pub fn registerModuleFunction(self: *Context, module_id: u32, value: Value) !void {
        if (module_id >= self.module_envs.len) return error.BadModuleId;
        if (value != .function) return error.FunctionExpected;
        const env = value.function.env.modulePtr() orelse return;
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

    pub fn ensureModule(self: *Context, module_id: u32) anyerror!void {
        if (module_id >= self.module_roots.len or module_id >= self.module_state.len) return error.BadModuleId;
        if (self.module_state[module_id] == 2) return;
        if (self.module_state[module_id] == 1) return error.ModuleLoadLoop;
        self.module_state[module_id] = 1;
        errdefer self.module_state[module_id] = 0;
        const values = try self.invokeKnown(self.module_roots[module_id], .{ .direct = &.{} }, &.{});
        freeResults(values);
        self.module_state[module_id] = 2;
    }

    pub fn callValue(self: *Context, callable: Value, args: []const Value) anyerror![]const Value {
        return switch (callable) {
            .function => |value| self.callFunction(value, args),
            .native => |value| value.call(self, args),
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
    pub fn newTable(self: *Context) !*Table {
        const table = try self.allocator.create(Table);
        table.* = .{};
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

    fn constantById(self: *const Context, id: u32) ?Constant {
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
        return null;
    }

    fn constantEntryAt(self: *const Context, id: u32) ?ConstantEntry {
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
        return null;
    }

    pub fn materializeConstant(self: *Context, id: u32) anyerror!Value {
        return switch (self.constantById(id) orelse return error.BadConstantReference) {
            .nil => .nil,
            .boolean => |value| .{ .boolean = value },
            .number => |value| .{ .number = value },
            .string => |value| .{ .string = value },
            .table => |table| blk: {
                if (table.count > std.math.maxInt(u32) - table.first) return error.BadConstantEntryRange;
                const object = try self.newTable();
                var list_index: u32 = 1;
                for (0..table.count) |offset| {
                    const entry_id = table.first + @as(u32, @intCast(offset));
                    const entry = self.constantEntryAt(entry_id) orelse return error.BadConstantEntryRange;
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

    pub fn getSlot(self: *Context, object: Value, slot: u32) anyerror!Value {
        if (object != .table) return error.IndexType;
        if (object.table.rawGetSlot(slot)) |value| return value;
        if (object.table.metatable == null) return .nil;
        const key = object.table.fieldKey(slot) orelse return error.BadAnonymousShapeMetatable;
        return self.getIndex(object, key);
    }

    pub fn setSlot(self: *Context, object: Value, slot: u32, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        if (object.table.rawGetSlot(slot) != null or object.table.metatable == null)
            return object.table.rawSetSlot(slot, value);
        const key = object.table.fieldKey(slot) orelse return error.BadAnonymousShapeMetatable;
        return self.setIndex(object, key, value);
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
    const constants_a = [_]Constant{ .{ .number = 4 }, .{ .string = "x" } };
    const constants_b = [_]Constant{
        .{ .table = .{ .first = 0, .count = 2 } },
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
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expectEqual(@as(f64, 4), left.table.rawGet(.{ .number = 1 }).?.number);
    const outer_left = try ctx.materializeConstant(3);
    const outer_right = try ctx.materializeConstant(3);
    const nested_left = outer_left.table.rawGet(.{ .string = "x" }).?;
    const nested_right = outer_right.table.rawGet(.{ .string = "x" }).?;
    try std.testing.expect(nested_left == .table and nested_right == .table and nested_left.table != nested_right.table);
}

test "AOT module functions share one activation environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try Context.initProgram(arena.allocator(), 0, 2);
    defer ctx.deinit();
    var regs: [3]Value = undefined;
    var cells: [3]?*Cell = undefined;
    var frame = try Frame.init(&regs, &cells, &.{}, 0, false);
    frame.set(1, .{ .number = 7 });
    _ = try frame.ensureCell(&ctx, 1);
    const env = try frame.ensureModuleEnv(&ctx);
    try std.testing.expect(env == try frame.ensureModuleEnv(&ctx));
    const first = ctx.makeModuleFunction(4, env);
    const second = ctx.makeModuleFunction(5, env);
    try std.testing.expect(first.function.env.modulePtr() == second.function.env.modulePtr());
    try std.testing.expect(first.function.env.closurePtr() == null);
    try std.testing.expect(!rawEqual(first, second));
    try ctx.registerModuleFunction(1, first);
    try ctx.registerModuleFunction(1, second);
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
    const other = ctx.makeModuleFunction(6, other_env);
    try std.testing.expectError(error.ModuleEnvironmentMismatch, ctx.registerModuleFunction(1, other));
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 24), @sizeOf(FunctionValue));
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
