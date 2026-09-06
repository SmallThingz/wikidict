const global_abi = @import("vm_global_abi.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");

pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *Table,
    closure: *Closure,
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

const Map = std.HashMapUnmanaged(Value, Value, ValueContext, 80);
pub const Table = struct {
    map: Map = .empty,
    global_values: ?*[global_abi.count]Value = null,
    metatable: ?*Table = null,
    append_index: u32 = 1,
    read_only: bool = false,

    pub fn deinit(self: *Table, a: std.mem.Allocator) void {
        self.map.deinit(a);
        if (self.global_values) |values| a.destroy(values);
    }

    pub fn globalGet(self: *const Table, id: u32) ?Value {
        const slots = self.global_values orelse return null;
        if (id >= global_abi.count) return null;
        return if (slots[id] == .nil) null else slots[id];
    }
    pub fn globalSet(self: *Table, id: u32, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        const slots = self.global_values orelse return error.NotGlobalEnvironment;
        if (id >= global_abi.count) return error.BadGlobalSlot;
        slots[id] = value;
    }
    pub const Iterator = struct {
        table: *Table,
        hash: Map.Iterator,
        slot: u32 = 0,
        key: Value = .nil,
        pub const Entry = struct { key_ptr: *const Value, value_ptr: *Value };
        pub fn next(self: *Iterator) ?Entry {
            if (self.table.global_values) |values| while (self.slot < global_abi.count) {
                const i = self.slot;
                self.slot += 1;
                if (values[i] == .nil) continue;
                self.key = .{ .string = global_abi.names[i] };
                return .{ .key_ptr = &self.key, .value_ptr = &values[i] };
            };
            if (self.hash.next()) |entry| return .{ .key_ptr = entry.key_ptr, .value_ptr = entry.value_ptr };
            return null;
        }
    };
    pub fn iterator(self: *Table) Iterator {
        return .{ .table = self, .hash = self.map.iterator() };
    }

    pub fn rawGet(self: *const Table, key: Value) ?Value {
        if (self.global_values != null and key == .string) {
            if (global_abi.find(key.string)) |id| return self.globalGet(id);
        }
        return self.map.getContext(key, .{});
    }
    pub fn rawSet(self: *Table, a: std.mem.Allocator, key: Value, value: Value) !void {
        if (self.read_only) return error.ReadOnlyTable;
        if (key == .nil) return error.NilTableKey;
        if (key == .number and std.math.isNan(key.number)) return error.NaNTableKey;
        if (self.global_values != null and key == .string) {
            if (global_abi.find(key.string)) |id| return self.globalSet(id, value);
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
