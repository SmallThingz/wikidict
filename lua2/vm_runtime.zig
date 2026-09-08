const global_abi = @import("vm_global_abi.zig");
const static_fields = @import("vm_static_field_abi.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");

pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *Table,
    closure: *Closure,
    function: FunctionValue,
    native: *NativeClosure,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }
};

pub const Cell = struct { value: Value };
pub const Closure = struct {
    program: *const ir.Program,
    function_id: u32,
    upvalues: []const *Cell,
};
pub const ModuleEnv = struct { program: *const ir.Program, module_id: u32, cells: []?*Cell };
pub const FunctionValue = struct { env: *ModuleEnv, function_id: u32 };

pub const NativeCall = *const fn (ctx: ?*anyopaque, vm: *anyopaque, args: []const Value, allocator: std.mem.Allocator) anyerror![]const Value;
pub const NativeClosure = struct { ctx: ?*anyopaque = null, call: NativeCall };

const ValueContext = struct {
    pub fn hash(_: ValueContext, v: Value) u64 {
        var h = std.hash.Wyhash.init(0);
        const tag: u8 = @intFromEnum(std.meta.activeTag(v));
        h.update(&.{tag});
        switch (v) {
            .nil => {},
            .boolean => |b| h.update(&.{@intFromBool(b)}),
            .number => |n| {
                const normalized: f64 = if (n == 0) 0 else n;
                const bits: u64 = @bitCast(normalized);
                h.update(std.mem.asBytes(&bits));
            },
            .string => |s| h.update(s),
            .table => |p| {
                const x: usize = @intFromPtr(p);
                h.update(std.mem.asBytes(&x));
            },
            .closure => |p| {
                const x: usize = @intFromPtr(p);
                h.update(std.mem.asBytes(&x));
            },
            .function => |f| {
                const p: usize = @intFromPtr(f.env);
                h.update(std.mem.asBytes(&p));
                h.update(std.mem.asBytes(&f.function_id));
            },
            .native => |p| {
                const x: usize = @intFromPtr(p);
                h.update(std.mem.asBytes(&x));
            },
        }
        return h.final();
    }
    pub fn eql(_: ValueContext, a: Value, b: Value) bool {
        return rawEqual(a, b);
    }
};

pub const ChoiceCell = struct { key: Value = .nil, value: Value = .nil };

const Map = std.HashMapUnmanaged(Value, Value, ValueContext, 80);

pub const Table = struct {
    map: Map = .empty,
    metatable: ?*Table = null,
    append_index: u32 = 1,
    read_only: bool = false,
    native_namespace: ?static_fields.Namespace = null,
    shape_program: ?*const ir.Program = null,
    shape_id: u32 = std.math.maxInt(u32),
    slots: []Value = &.{},
    choices: []ChoiceCell = &.{},

    pub fn deinit(self: *Table, a: std.mem.Allocator) void {
        self.map.deinit(a);
        if (self.slots.len != 0) a.free(self.slots);
        if (self.choices.len != 0) a.free(self.choices);
    }

    fn shape(self: *const Table) ?*const ir.Shape {
        const p = self.shape_program orelse return null;
        if (self.shape_id >= p.shapes.items.len) return null;
        return &p.shapes.items[self.shape_id];
    }

    fn slotForKey(self: *const Table, key: Value) ?u32 {
        if (key != .string) return null;
        if (self.native_namespace) |namespace| return static_fields.slotForName(namespace, key.string);
        if (self.shape_program == null and self.shape_id == global_abi.native_shape) return global_abi.find(key.string);
        const desc = self.shape() orelse return null;
        if (desc.field_keys.items.len != desc.field_count) return null;
        const p = self.shape_program.?;
        for (desc.field_keys.items, 0..) |sid, slot| {
            if (sid >= p.strings.items.len) continue;
            if (std.mem.eql(u8, p.strings.items[sid], key.string)) return @intCast(slot);
        }
        return null;
    }

    pub fn fieldKey(self: *const Table, slot: u32) ?Value {
        if (self.native_namespace) |namespace| {
            return .{ .string = static_fields.nameAt(namespace, slot) orelse return null };
        }
        if (self.shape_program == null and self.shape_id == global_abi.native_shape and slot < global_abi.count)
            return .{ .string = global_abi.names[slot] };
        const desc = self.shape() orelse return null;
        if (desc.field_keys.items.len != desc.field_count or slot >= desc.field_count) return null;
        const sid = desc.field_keys.items[slot];
        const p = self.shape_program.?;
        if (sid >= p.strings.items.len) return null;
        return .{ .string = p.strings.items[sid] };
    }

    pub fn rawGetSlot(self: *const Table, slot: u32) ?Value {
        if (slot >= self.slots.len) return null;
        const value = self.slots[slot];
        return if (value == .nil) null else value;
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
        if (key == .nil) return error.NilTableKey;
        if (key == .number and std.math.isNan(key.number)) return error.NaNTableKey;
        if (value == .nil) {
            if (rawEqual(self.choices[choice].key, key)) self.choices[choice] = .{};
            return;
        }
        self.choices[choice] = .{ .key = key, .value = value };
    }

    pub fn rawGet(self: *const Table, key: Value) ?Value {
        if (self.slotForKey(key)) |slot| if (self.rawGetSlot(slot)) |value| return value;
        for (self.choices) |cell| if (cell.value != .nil and rawEqual(cell.key, key)) return cell.value;
        return self.map.getContext(key, .{});
    }
    pub fn rawSet(self: *Table, a: std.mem.Allocator, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        if (key == .nil) return error.NilTableKey;
        if (key == .number and std.math.isNan(key.number)) return error.NaNTableKey;
        if (self.slotForKey(key)) |slot| return self.rawSetSlot(slot, value);
        for (self.choices, 0..) |cell, choice| {
            if (cell.value != .nil and rawEqual(cell.key, key)) return self.rawSetChoice(@intCast(choice), key, value);
        }
        if (value == .nil) {
            _ = self.map.removeContext(key, .{});
            return;
        }
        try self.map.putContext(a, key, value, .{});
    }

    pub fn append(self: *Table, a: std.mem.Allocator, value: Value) !void {
        try self.rawSet(a, .{ .number = @floatFromInt(self.append_index) }, value);
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

    pub fn rawLen(self: *const Table) usize {
        var n: usize = 0;
        while (true) {
            const key: Value = .{ .number = @floatFromInt(n + 1) };
            if (self.rawGet(key) == null) return n;
            n += 1;
        }
    }
};
pub fn newTable(a: std.mem.Allocator) !*Table {
    const t = try a.create(Table);
    t.* = .{};
    return t;
}

pub fn newNativeNamespace(a: std.mem.Allocator, namespace: static_fields.Namespace) !*Table {
    const t = try a.create(Table);
    errdefer a.destroy(t);
    t.* = .{ .native_namespace = namespace };
    const count = static_fields.fieldCount(namespace);
    if (count != 0) {
        t.slots = try a.alloc(Value, count);
        @memset(t.slots, .nil);
    }
    return t;
}

pub fn newShapedTable(a: std.mem.Allocator, p: *const ir.Program, shape_id: u32) !*Table {
    if (shape_id >= p.shapes.items.len) return error.BadShape;
    const shape = p.shapes.items[shape_id];
    const t = try a.create(Table);
    errdefer a.destroy(t);
    t.* = .{ .shape_program = p, .shape_id = shape_id };
    errdefer t.deinit(a);
    if (shape.field_count != 0) {
        t.slots = try a.alloc(Value, shape.field_count);
        @memset(t.slots, .nil);
    }
    if (shape.choice_count != 0) {
        t.choices = try a.alloc(ChoiceCell, shape.choice_count);
        @memset(t.choices, .{});
    }
    return t;
}
pub fn newNative(a: std.mem.Allocator, ctx: ?*anyopaque, call: NativeCall) !Value {
    const f = try a.create(NativeClosure);
    f.* = .{ .ctx = ctx, .call = call };
    return .{ .native = f };
}

pub fn rawEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nil => true,
        .boolean => |x| x == b.boolean,
        .number => |x| x == b.number,
        .string => |x| std.mem.eql(u8, x, b.string),
        .table => |x| x == b.table,
        .closure => |x| x == b.closure,
        .function => |x| x.env == b.function.env and x.function_id == b.function.function_id,
        .native => |x| x == b.native,
    };
}

pub fn toNumber(v: Value) ?f64 {
    return switch (v) {
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn numberToString(a: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "nan";
    if (std.math.isInf(n)) return if (n < 0) "-inf" else "inf";
    if (@floor(n) == n and n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(n))});
    return std.fmt.allocPrint(a, "{d}", .{n});
}

pub fn toConcatString(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number => |n| try numberToString(a, n),
        else => error.ConcatType,
    };
}

pub fn concat(a: std.mem.Allocator, values: []const Value) !Value {
    var strings = try a.alloc([]const u8, values.len);
    var total: usize = 0;
    for (values, 0..) |v, i| {
        strings[i] = try toConcatString(a, v);
        total = try std.math.add(usize, total, strings[i].len);
    }
    const out = try a.alloc(u8, total);
    var pos: usize = 0;
    for (strings) |s| {
        @memcpy(out[pos .. pos + s.len], s);
        pos += s.len;
    }
    return .{ .string = out };
}

pub fn unaryNeg(v: Value) !Value {
    return .{ .number = -(toNumber(v) orelse return error.ArithmeticType) };
}
pub fn len(v: Value) !Value {
    return switch (v) {
        .string => |s| .{ .number = @floatFromInt(s.len) },
        .table => |t| .{ .number = @floatFromInt(t.rawLen()) },
        else => error.LengthType,
    };
}

pub fn arithmetic(op: ir.Opcode, a: Value, b: Value) !Value {
    const x = toNumber(a) orelse return error.ArithmeticType;
    const y = toNumber(b) orelse return error.ArithmeticType;
    const z = switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .mod => x - @floor(x / y) * y,
        .pow => std.math.pow(f64, x, y),
        else => unreachable,
    };
    return .{ .number = z };
}

pub fn compare(op: ir.Opcode, a: Value, b: Value) !bool {
    if (op == .eq or op == .ne) {
        const e = rawEqual(a, b);
        return if (op == .eq) e else !e;
    }
    if (a == .number and b == .number) return switch (op) {
        .lt => a.number < b.number,
        .le => a.number <= b.number,
        .gt => a.number > b.number,
        .ge => a.number >= b.number,
        else => unreachable,
    };
    if (a == .string and b == .string) {
        const ord = std.mem.order(u8, a.string, b.string);
        return switch (op) {
            .lt => ord == .lt,
            .le => ord != .gt,
            .gt => ord == .gt,
            .ge => ord != .lt,
            else => unreachable,
        };
    }
    return error.CompareType;
}

test "table identity and scalar keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try newTable(a);
    try t.rawSet(a, .{ .string = "x" }, .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), t.rawGet(.{ .string = "x" }).?.number);
    try std.testing.expect(rawEqual(.{ .table = t }, .{ .table = t }));
}
