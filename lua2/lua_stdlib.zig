const std = @import("std");
const rt = @import("vm_runtime.zig");
const exec = @import("vm_exec.zig");
const ir = @import("vm_ir.zig");
const pattern = @import("lua_pattern.zig");
const lua_format = @import("lua_format.zig");
const Value = rt.Value;

fn vmCast(p: *anyopaque) *exec.Vm {
    return @ptrCast(@alignCast(p));
}
fn one(_: std.mem.Allocator, v: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = v;
    return out;
}
fn two(_: std.mem.Allocator, x: Value, y: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 2);
    out[0] = x;
    out[1] = y;
    return out;
}
fn num(v: Value) !f64 {
    return rt.toNumber(v) orelse error.NumberExpected;
}
fn integer(v: Value) !i64 {
    const n = try num(v);
    return @intFromFloat(@trunc(n));
}
fn str(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        else => error.StringExpected,
    };
}

fn setNative(vm: *exec.Vm, t: *rt.Table, name: []const u8, call: rt.NativeCall) !void {
    try t.rawSet(vm.allocator, .{ .string = name }, try rt.newNative(vm.allocator, null, call));
}
fn setGlobalNative(vm: *exec.Vm, comptime name: []const u8, call: rt.NativeCall) !void {
    try vm.setGlobal(name, try rt.newNative(vm.allocator, null, call));
}

fn baseType(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const name = if (args.len == 0) "nil" else switch (args[0]) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .table => "table",
        .closure, .native => "function",
    };
    return one(a, .{ .string = name });
}
fn baseAssert(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len != 0 and args[0].truthy()) {
        const out = try std.heap.smp_allocator.alloc(Value, args.len);
        @memcpy(out, args);
        return out;
    }
    const vm = vmCast(raw);
    vm.last_error = if (args.len > 1) args[1] else .{ .string = "assertion failed!" };
    return error.LuaRaised;
}
fn baseError(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    const vm = vmCast(raw);
    vm.last_error = if (args.len != 0) args[0] else .nil;
    return error.LuaRaised;
}
fn baseRawEqual(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .boolean = args.len >= 2 and rt.rawEqual(args[0], args[1]) });
}
fn baseRawGet(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    return one(a, args[0].table.rawGet(args[1]) orelse .nil);
}
fn baseRawSet(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 3 or args[0] != .table) return error.TableExpected;
    try args[0].table.rawSet(vmCast(raw).allocator, args[1], args[2]);
    return one(a, args[0]);
}
fn baseGetMetatable(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return one(a, .nil);
    const vm = vmCast(raw);
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => vm.string_metatable,
        else => null,
    };
    const actual = mt orelse return one(a, .nil);
    if (actual.rawGet(.{ .string = "__metatable" })) |v| return one(a, v);
    return one(a, .{ .table = actual });
}
fn baseSetMetatable(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    if (args[0].table.metatable) |old| if (old.rawGet(.{ .string = "__metatable" }) != null) return error.ProtectedMetatable;
    args[0].table.metatable = switch (args[1]) {
        .nil => null,
        .table => |t| t,
        else => return error.TableExpected,
    };
    return one(a, args[0]);
}

fn baseToString(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const vm = vmCast(raw);
    const v = if (args.len == 0) Value.nil else args[0];
    if (vm.metamethod(v, "__tostring")) |mm| {
        const out = try vm.callValue(mm, &.{v});
        defer exec.Vm.freeResults(out);
        if (out.len == 0 or out[0] != .string) return error.StringExpected;
        return one(a, out[0]);
    }
    const s: []const u8 = switch (v) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try rt.numberToString(a, n),
        .string => |x| x,
        .table => |p| try std.fmt.allocPrint(a, "table: 0x{x}", .{@intFromPtr(p)}),
        .closure => |p| try std.fmt.allocPrint(a, "function: 0x{x}", .{@intFromPtr(p)}),
        .native => |p| try std.fmt.allocPrint(a, "function: 0x{x}", .{@intFromPtr(p)}),
    };
    return one(a, .{ .string = s });
}
fn baseToNumber(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return one(a, .nil);
    if (args.len < 2 or args[1] == .nil) {
        return one(a, if (rt.toNumber(args[0])) |n| .{ .number = n } else .nil);
    }
    if (args[0] != .string) return one(a, .nil);
    const base = try integer(args[1]);
    if (base < 2 or base > 36) return error.BadBase;
    const s = std.mem.trim(u8, args[0].string, " \t\r\n\x0b\x0c");
    var sign: f64 = 1;
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        if (s[i] == '-') sign = -1;
        i += 1;
    }
    if (i == s.len) return one(a, .nil);
    var n: f64 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const d: i64 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'z') c - 'a' + 10 else if (c >= 'A' and c <= 'Z') c - 'A' + 10 else return one(a, .nil);
        if (d >= base) return one(a, .nil);
        n = n * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(d));
    }
    return one(a, .{ .number = sign * n });
}
fn baseSelect(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    if (args[0] == .string and std.mem.eql(u8, args[0].string, "#")) return one(a, .{ .number = @floatFromInt(args.len - 1) });
    var idx = try integer(args[0]);
    const n: @TypeOf(idx) = @intCast(args.len - 1);
    if (idx < 0) idx = n + idx + 1;
    if (idx < 1) idx = 1;
    if (idx > n) return &.{};
    const out = try std.heap.smp_allocator.alloc(Value, @intCast(n - idx + 1));
    @memcpy(out, args[@intCast(idx)..]);
    return out;
}
fn baseUnpack(_: ?*anyopaque, _: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const i: i64 = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1;
    const j: i64 = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else @intCast(t.rawLen());
    if (j < i) return &.{};
    const out = try std.heap.smp_allocator.alloc(Value, @intCast(j - i + 1));
    for (out, 0..) |*v, k| v.* = t.rawGet(.{ .number = @floatFromInt(i + @as(i64, @intCast(k))) }) orelse .nil;
    return out;
}

fn baseNext(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const key = if (args.len > 1) args[1] else Value.nil;
    var it = t.iterator();
    var found = key == .nil;
    while (it.next()) |e| {
        if (found) return two(a, e.key_ptr.*, e.value_ptr.*);
        if (rt.rawEqual(e.key_ptr.*, key)) found = true;
    }
    if (key != .nil and !found) return error.InvalidNextKey;
    return one(a, .nil);
}
fn iteratorTripleFromCall(vm: *exec.Vm, callable: Value, object: Value) ![]const Value {
    const values = try vm.callValue(callable, &.{object});
    defer exec.Vm.freeResults(values);
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    for (out, 0..) |*slot, i| slot.* = if (i < values.len) values[i] else .nil;
    return out;
}

fn exposedMetamethod(vm: *exec.Vm, object: Value, name: []const u8) !?Value {
    if (object != .table) return null;
    const actual = object.table.metatable orelse return null;
    const exposed = actual.rawGet(.{ .string = "__metatable" }) orelse Value{ .table = actual };
    if (!exposed.truthy()) return null;
    const method = try vm.getIndex(exposed, .{ .string = name });
    return if (method.truthy()) method else null;
}

fn basePairs(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const vm = vmCast(raw);
    if (try exposedMetamethod(vm, args[0], "__pairs")) |method|
        return iteratorTripleFromCall(vm, method, args[0]);
    const nxt = vm.getGlobal("next") orelse return error.MissingBuiltin;
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = nxt;
    out[1] = args[0];
    out[2] = .nil;
    return out;
}
fn ipairsIter(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    const i = (try integer(args[1])) + 1;
    const v = args[0].table.rawGet(.{ .number = @floatFromInt(i) }) orelse return one(a, .nil);
    return two(a, .{ .number = @floatFromInt(i) }, v);
}
fn baseIpairs(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const vm = vmCast(raw);
    if (try exposedMetamethod(vm, args[0], "__ipairs")) |method|
        return iteratorTripleFromCall(vm, method, args[0]);
    const iter = try rt.newNative(vm.allocator, null, ipairsIter);
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = iter;
    out[1] = args[0];
    out[2] = .{ .number = 0 };
    return out;
}
fn basePcall(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    const vm = vmCast(raw);
    const saved_failure = vm.failure;
    vm.failure = null;
    const result = vm.callValue(args[0], args[1..]) catch |err| {
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .boolean = false };
        out[1] = if (vm.last_error != .nil) vm.last_error else .{ .string = @errorName(err) };
        vm.last_error = .nil;
        vm.failure = saved_failure;
        return out;
    };
    vm.failure = saved_failure;
    defer exec.Vm.freeResults(result);
    const out = try std.heap.smp_allocator.alloc(Value, result.len + 1);
    out[0] = .{ .boolean = true };
    @memcpy(out[1..], result);
    return out;
}

fn tableInsert(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n = t.rawLen();
    if (args.len == 2) {
        try t.rawSet(vmCast(raw).allocator, .{ .number = @floatFromInt(n + 1) }, args[1]);
        return &.{};
    }
    const pos = try integer(args[1]);
    if (pos < 1 or pos > @as(i64, @intCast(n)) + 1) return error.PositionOutOfBounds;
    var i: i64 = @intCast(n + 1);
    while (i > pos) : (i -= 1) try t.rawSet(vmCast(raw).allocator, .{ .number = @floatFromInt(i) }, t.rawGet(.{ .number = @floatFromInt(i - 1) }) orelse .nil);
    try t.rawSet(vmCast(raw).allocator, .{ .number = @floatFromInt(pos) }, args[2]);
    return &.{};
}
fn tableRemove(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n: i64 = @intCast(t.rawLen());
    if (n == 0) return one(a, .nil);
    const pos = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else n;
    if (pos < 1 or pos > n) return one(a, .nil);
    const removed = t.rawGet(.{ .number = @floatFromInt(pos) }) orelse .nil;
    var i = pos;
    while (i < n) : (i += 1) try t.rawSet(vmCast(raw).allocator, .{ .number = @floatFromInt(i) }, t.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse .nil);
    try t.rawSet(vmCast(raw).allocator, .{ .number = @floatFromInt(n) }, .nil);
    return one(a, removed);
}
fn tableConcat(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const sep = if (args.len > 1 and args[1] != .nil) try str(a, args[1]) else "";
    const i = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const j = if (args.len > 3 and args[3] != .nil) try integer(args[3]) else @as(i64, @intCast(t.rawLen()));
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(a);
    var total: usize = 0;
    var k = i;
    while (k <= j) : (k += 1) {
        const s = try rt.toConcatString(a, t.rawGet(.{ .number = @floatFromInt(k) }) orelse return error.InvalidValue);
        try pieces.append(a, s);
        total += s.len;
        if (k < j) total += sep.len;
    }
    const out = try a.alloc(u8, total);
    var p: usize = 0;
    for (pieces.items, 0..) |s, n| {
        @memcpy(out[p .. p + s.len], s);
        p += s.len;
        if (n + 1 < pieces.items.len) {
            @memcpy(out[p .. p + sep.len], sep);
            p += sep.len;
        }
    }
    return one(a, .{ .string = out });
}
fn tableMaxn(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    var max: f64 = 0;
    var it = args[0].table.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* == .number and e.key_ptr.number > max) max = e.key_ptr.number;
    }
    return one(a, .{ .number = max });
}
fn tableSortLess(vm: *exec.Vm, cmp: Value, a: Value, b: Value) !bool {
    if (cmp == .nil) return vm.comparison(.lt, a, b);
    const out = try vm.callValue(cmp, &.{ a, b });
    defer exec.Vm.freeResults(out);
    return out.len != 0 and out[0].truthy();
}

fn tableSortSiftDown(vm: *exec.Vm, cmp: Value, values: []Value, root_in: usize, end: usize) !void {
    var root = root_in;
    while (root * 2 + 1 < end) {
        var child = root * 2 + 1;
        if (child + 1 < end and try tableSortLess(vm, cmp, values[child], values[child + 1])) child += 1;
        if (!try tableSortLess(vm, cmp, values[root], values[child])) return;
        std.mem.swap(Value, &values[root], &values[child]);
        root = child;
    }
}

fn tableSort(_: ?*anyopaque, raw: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const vm = vmCast(raw);
    const t = args[0].table;
    const n = t.rawLen();
    if (n < 2) return &.{};
    const cmp = if (args.len > 1) args[1] else Value.nil;

    const values = try std.heap.smp_allocator.alloc(Value, n);
    defer std.heap.smp_allocator.free(values);
    for (values, 0..) |*value, i|
        value.* = t.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse .nil;

    var start = n / 2;
    while (start != 0) {
        start -= 1;
        try tableSortSiftDown(vm, cmp, values, start, n);
    }
    var end = n;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Value, &values[0], &values[end]);
        try tableSortSiftDown(vm, cmp, values, 0, end);
    }

    for (values, 0..) |value, i|
        try t.rawSet(vm.allocator, .{ .number = @floatFromInt(i + 1) }, value);
    return &.{};
}

fn stringLen(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .number = @floatFromInt((try str(a, args[0])).len) });
}
fn normIndex(i: i64, n: i64) i64 {
    return if (i < 0) n + i + 1 else i;
}
fn stringSub(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const s = try str(a, args[0]);
    const n: i64 = @intCast(s.len);
    var i = normIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, n);
    var j = normIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else -1, n);
    i = @max(@as(i64, 1), i);
    j = @min(n, j);
    if (i > j or i > n) return one(a, .{ .string = "" });
    return one(a, .{ .string = s[@intCast(i - 1)..@intCast(j)] });
}
fn stringLower(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const s = try str(a, args[0]);
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return one(a, .{ .string = out });
}
fn stringUpper(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const s = try str(a, args[0]);
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return one(a, .{ .string = out });
}
fn stringReverse(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const s = try str(a, args[0]);
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[s.len - 1 - i] = c;
    return one(a, .{ .string = out });
}
fn stringRep(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const s = try str(a, args[0]);
    const n = try integer(args[1]);
    if (n <= 0) return one(a, .{ .string = "" });
    const total = try std.math.mul(usize, s.len, @intCast(n));
    const out = try a.alloc(u8, total);
    var p: usize = 0;
    for (0..@intCast(n)) |_| {
        @memcpy(out[p .. p + s.len], s);
        p += s.len;
    }
    return one(a, .{ .string = out });
}
fn stringChar(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const out = try a.alloc(u8, args.len);
    for (args, 0..) |v, i| {
        const x = try integer(v);
        if (x < 0 or x > 255) return error.ByteOutOfRange;
        out[i] = @intCast(x);
    }
    return one(a, .{ .string = out });
}
fn stringByte(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const s = try str(a, args[0]);
    const n: i64 = @intCast(s.len);
    var i = normIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, n);
    var j = normIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else i, n);
    i = @max(@as(i64, 1), i);
    j = @min(n, j);
    if (i > j) return &.{};
    const out = try std.heap.smp_allocator.alloc(Value, @intCast(j - i + 1));
    for (out, 0..) |*v, k| v.* = .{ .number = @floatFromInt(s[@intCast(i + @as(i64, @intCast(k)) - 1)]) };
    return out;
}

fn captureValue(source: []const u8, capture: pattern.Capture) !Value {
    return switch (capture) {
        .slice => |s| .{ .string = source[s.start..s.end] },
        .position => |p| .{ .number = @floatFromInt(p + 1) },
        .unfinished => error.UnfinishedCapture,
    };
}

fn captureResults(a: std.mem.Allocator, source: []const u8, m: pattern.Match) ![]const Value {
    if (m.capture_count == 0) return one(a, .{ .string = source[m.start..m.end] });
    const out = try std.heap.smp_allocator.alloc(Value, m.capture_count);
    for (out, 0..) |*v, i| v.* = try captureValue(source, m.captures[i]);
    return out;
}

fn findStart(len: usize, raw: i64) ?usize {
    const n: i64 = @intCast(len);
    var i = if (raw < 0) n + raw + 1 else raw;
    if (i < 1) i = 1;
    if (i > n + 1) return null;
    return @intCast(i - 1);
}

fn stringFind(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    const source = try str(a, args[0]);
    const needle = try str(a, args[1]);
    const init = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const start = findStart(source.len, init) orelse return one(a, .nil);
    if (args.len > 3 and args[3].truthy()) {
        const rel = std.mem.indexOf(u8, source[start..], needle) orelse return one(a, .nil);
        const first = start + rel;
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .number = @floatFromInt(first + 1) };
        out[1] = .{ .number = @floatFromInt(first + needle.len) };
        return out;
    }
    const m = try pattern.find(source, needle, init) orelse return one(a, .nil);
    const out = try std.heap.smp_allocator.alloc(Value, 2 + m.capture_count);
    out[0] = .{ .number = @floatFromInt(m.start + 1) };
    out[1] = .{ .number = @floatFromInt(m.end) };
    for (0..m.capture_count) |i| out[2 + i] = try captureValue(source, m.captures[i]);
    return out;
}

fn stringMatch(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    const source = try str(a, args[0]);
    const pat = try str(a, args[1]);
    const init = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const m = try pattern.find(source, pat, init) orelse return one(a, .nil);
    return captureResults(a, source, m);
}
const GmatchCtx = struct { iterator: pattern.Iterator };
fn gmatchNext(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *GmatchCtx = @ptrCast(@alignCast(ctx_raw.?));
    const m = try ctx.iterator.next() orelse return &.{};
    return captureResults(a, ctx.iterator.source, m);
}

fn stringGmatch(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    const vm = vmCast(raw);
    const ctx = try vm.allocator.create(GmatchCtx);
    ctx.* = .{ .iterator = .{ .source = try str(a, args[0]), .pattern = try str(a, args[1]) } };
    return one(a, try rt.newNative(vm.allocator, ctx, gmatchNext));
}

fn captureReplacementText(a: std.mem.Allocator, source: []const u8, m: pattern.Match, digit: u8) ![]const u8 {
    if (digit == '0') return source[m.start..m.end];
    const index: usize = digit - '1';
    if (m.capture_count == 0 and digit == '1') return source[m.start..m.end];
    if (index >= m.capture_count) return error.InvalidCapture;
    return switch (m.captures[index]) {
        .slice => |s| source[s.start..s.end],
        .position => |p| try rt.numberToString(a, @floatFromInt(p + 1)),
        .unfinished => error.UnfinishedCapture,
    };
}

fn expandReplacement(a: std.mem.Allocator, repl: []const u8, source: []const u8, m: pattern.Match) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < repl.len) {
        if (repl[i] != '%') {
            try out.append(a, repl[i]);
            i += 1;
            continue;
        }
        // Lua 5.1 treats `%x` as literal `x` for every non-digit x.
        // PUC 5.1's lstrlib.c also emits the terminating NUL for a trailing `%`.
        if (i + 1 >= repl.len) {
            try out.append(a, 0);
            i += 1;
            continue;
        }
        const code = repl[i + 1];
        if (code >= '0' and code <= '9')
            try out.appendSlice(a, try captureReplacementText(a, source, m, code))
        else
            try out.append(a, code);
        i += 2;
    }
    return out.toOwnedSlice(a);
}

fn replacementArgs(a: std.mem.Allocator, source: []const u8, m: pattern.Match) ![]const Value {
    return captureResults(a, source, m);
}

fn replacementValue(vm: *exec.Vm, replacement: Value, source: []const u8, m: pattern.Match, a: std.mem.Allocator) !?[]const u8 {
    const original = source[m.start..m.end];
    const value: Value = switch (replacement) {
        .string => return try expandReplacement(a, replacement.string, source, m),
        .table => |table| blk: {
            const captures = try replacementArgs(a, source, m);
            defer exec.Vm.freeResults(captures);
            const key = if (captures.len == 0) Value{ .string = original } else captures[0];
            break :blk try vm.getIndex(.{ .table = table }, key);
        },
        .closure, .native => blk: {
            const captures = try replacementArgs(a, source, m);
            defer exec.Vm.freeResults(captures);
            const result = try vm.callValue(replacement, captures);
            defer exec.Vm.freeResults(result);
            break :blk if (result.len == 0) Value.nil else result[0];
        },
        else => return error.InvalidReplacement,
    };
    return switch (value) {
        .nil => null,
        .boolean => |b| if (!b) null else error.InvalidReplacement,
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        else => error.InvalidReplacement,
    };
}

fn stringFormat(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .string = try lua_format.format(a, args) });
}

fn stringGsub(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 3) return error.MissingArgument;
    const vm = vmCast(raw);
    const source = try str(a, args[0]);
    const pat = try str(a, args[1]);
    const replacement = args[2];
    const max_count: usize = if (args.len > 3 and args[3] != .nil)
        @intCast(@max(@as(i64, 0), try integer(args[3])))
    else
        source.len + 1;
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    var search: usize = 0;
    var count: usize = 0;
    const anchored = pat.len != 0 and pat[0] == '^';
    while (count < max_count and search <= source.len) {
        const m = try pattern.find(source, pat, @intCast(search + 1)) orelse break;
        if (m.start < cursor) return error.BadPatternProgress;
        try out.appendSlice(a, source[cursor..m.start]);
        if (try replacementValue(vm, replacement, source, m, a)) |text|
            try out.appendSlice(a, text)
        else
            try out.appendSlice(a, source[m.start..m.end]);
        count += 1;
        cursor = m.end;
        if (anchored) break;
        if (m.end > m.start) search = m.end else if (m.end < source.len) search = m.end + 1 else search = source.len + 1;
    }
    try out.appendSlice(a, source[cursor..]);
    const result = try std.heap.smp_allocator.alloc(Value, 2);
    result[0] = .{ .string = try out.toOwnedSlice(a) };
    result[1] = .{ .number = @floatFromInt(count) };
    return result;
}

const MathOp = enum { abs, ceil, floor, sqrt, exp, log, log10, sin, cos, tan, asin, acos, atan, deg, rad };
fn mathUnary(ctx: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const op: *MathOp = @ptrCast(@alignCast(ctx.?));
    const x = try num(args[0]);
    const y = switch (op.*) {
        .abs => @abs(x),
        .ceil => @ceil(x),
        .floor => @floor(x),
        .sqrt => @sqrt(x),
        .exp => @exp(x),
        .log => @log(x),
        .log10 => @log10(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .tan => @tan(x),
        .asin => std.math.asin(x),
        .acos => std.math.acos(x),
        .atan => std.math.atan(x),
        .deg => x * 180 / std.math.pi,
        .rad => x * std.math.pi / 180,
    };
    return one(a, .{ .number = y });
}
fn mathMin(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    var x = try num(args[0]);
    for (args[1..]) |v| x = @min(x, try num(v));
    return one(a, .{ .number = x });
}
fn mathMax(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    var x = try num(args[0]);
    for (args[1..]) |v| x = @max(x, try num(v));
    return one(a, .{ .number = x });
}
fn mathPow(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .number = std.math.pow(f64, try num(args[0]), try num(args[1])) });
}
fn mathFmod(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const x = try num(args[0]);
    const y = try num(args[1]);
    return one(a, .{ .number = @rem(x, y) });
}
fn mathModf(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const x = try num(args[0]);
    const ip = @trunc(x);
    return two(a, .{ .number = ip }, .{ .number = x - ip });
}

fn debugGetMetatable(_: ?*anyopaque, raw: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const vm = vmCast(raw);
    if (args.len == 0) return one(a, .nil);
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => vm.string_metatable,
        else => null,
    };
    return one(a, if (mt) |t| .{ .table = t } else .nil);
}
fn debugTraceback(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, if (args.len != 0 and args[0] == .string) args[0] else .{ .string = "" });
}
fn debugGetInfo(_: ?*anyopaque, _: *anyopaque, _: []const Value, _: std.mem.Allocator) ![]const Value {
    return error.NotImplemented;
}

fn addMath(vm: *exec.Vm, t: *rt.Table, name: []const u8, op: MathOp) !void {
    const ctx = try vm.allocator.create(MathOp);
    ctx.* = op;
    try t.rawSet(vm.allocator, .{ .string = name }, try rt.newNative(vm.allocator, ctx, mathUnary));
}

pub fn install(vm: *exec.Vm) !void {
    try setGlobalNative(vm, "type", baseType);
    try setGlobalNative(vm, "assert", baseAssert);
    try setGlobalNative(vm, "error", baseError);
    try setGlobalNative(vm, "rawequal", baseRawEqual);
    try setGlobalNative(vm, "rawget", baseRawGet);
    try setGlobalNative(vm, "rawset", baseRawSet);
    try setGlobalNative(vm, "getmetatable", baseGetMetatable);
    try setGlobalNative(vm, "setmetatable", baseSetMetatable);
    try setGlobalNative(vm, "tostring", baseToString);
    try setGlobalNative(vm, "tonumber", baseToNumber);
    try setGlobalNative(vm, "select", baseSelect);
    try setGlobalNative(vm, "unpack", baseUnpack);
    try setGlobalNative(vm, "next", baseNext);
    try setGlobalNative(vm, "pairs", basePairs);
    try setGlobalNative(vm, "ipairs", baseIpairs);
    try setGlobalNative(vm, "pcall", basePcall);
    const table = try rt.newTable(vm.allocator);
    try setNative(vm, table, "insert", tableInsert);
    try setNative(vm, table, "remove", tableRemove);
    try setNative(vm, table, "concat", tableConcat);
    try setNative(vm, table, "sort", tableSort);
    try setNative(vm, table, "maxn", tableMaxn);
    try setNative(vm, table, "getn", struct {
        fn f(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
            if (args.len == 0 or args[0] != .table) return error.TableExpected;
            return one(a, .{ .number = @floatFromInt(args[0].table.rawLen()) });
        }
    }.f);
    try vm.setGlobal("table", .{ .table = table });
    const string = try rt.newTable(vm.allocator);
    try setNative(vm, string, "len", stringLen);
    try setNative(vm, string, "sub", stringSub);
    try setNative(vm, string, "lower", stringLower);
    try setNative(vm, string, "upper", stringUpper);
    try setNative(vm, string, "reverse", stringReverse);
    try setNative(vm, string, "rep", stringRep);
    try setNative(vm, string, "char", stringChar);
    try setNative(vm, string, "byte", stringByte);
    try setNative(vm, string, "find", stringFind);
    try setNative(vm, string, "match", stringMatch);
    try setNative(vm, string, "gmatch", stringGmatch);
    try setNative(vm, string, "gsub", stringGsub);
    try setNative(vm, string, "format", stringFormat);
    try vm.setGlobal("string", .{ .table = string });
    const smt = try rt.newTable(vm.allocator);
    try smt.rawSet(vm.allocator, .{ .string = "__index" }, .{ .table = string });
    vm.string_metatable = smt;
    const math = try rt.newTable(vm.allocator);
    inline for (.{ .{ "abs", MathOp.abs }, .{ "ceil", .ceil }, .{ "floor", .floor }, .{ "sqrt", .sqrt }, .{ "exp", .exp }, .{ "log", .log }, .{ "log10", .log10 }, .{ "sin", .sin }, .{ "cos", .cos }, .{ "tan", .tan }, .{ "asin", .asin }, .{ "acos", .acos }, .{ "atan", .atan }, .{ "deg", .deg }, .{ "rad", .rad } }) |x| try addMath(vm, math, x[0], x[1]);
    try setNative(vm, math, "min", mathMin);
    try setNative(vm, math, "max", mathMax);
    try setNative(vm, math, "pow", mathPow);
    try setNative(vm, math, "fmod", mathFmod);
    try setNative(vm, math, "mod", mathFmod);
    try setNative(vm, math, "modf", mathModf);
    try math.rawSet(vm.allocator, .{ .string = "pi" }, .{ .number = std.math.pi });
    try math.rawSet(vm.allocator, .{ .string = "huge" }, .{ .number = std.math.inf(f64) });
    try vm.setGlobal("math", .{ .table = math });
    const debug = try rt.newTable(vm.allocator);
    try setNative(vm, debug, "getmetatable", debugGetMetatable);
    try setNative(vm, debug, "traceback", debugTraceback);
    try setNative(vm, debug, "getinfo", debugGetInfo);
    try vm.setGlobal("debug", .{ .table = debug });
}

test "base and byte string library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try install(&vm);
    const sub = try vm.getIndex(vm.getGlobal("string").?, .{ .string = "sub" });
    const out = try vm.callValue(sub, &.{ .{ .string = "abcdef" }, .{ .number = 2 }, .{ .number = -2 } });
    try std.testing.expectEqualStrings("bcde", out[0].string);
}

test "patterns execute through compiled Lua" {
    const lua = @import("root.zig");
    const source =
        \\local a,b,c,d = string.find("abc123", "(%a+)(%d+)")
        \\local m = string.match("xx(a(b)c)yy", "%b()")
        \\local g,n = string.gsub("ab12cd34", "(%d+)", "[%1]")
        \\local xs = {}
        \\for x in string.gmatch("a1 b22 c333", "%a(%d+)") do table.insert(xs, x) end
        \\return a,b,c,d,m,g,n,table.concat(xs, ",")
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    try std.testing.expectEqual(@as(f64, 1), out[0].number);
    try std.testing.expectEqual(@as(f64, 6), out[1].number);
    try std.testing.expectEqualStrings("abc", out[2].string);
    try std.testing.expectEqualStrings("123", out[3].string);
    try std.testing.expectEqualStrings("(a(b)c)", out[4].string);
    try std.testing.expectEqualStrings("ab[12]cd[34]", out[5].string);
    try std.testing.expectEqual(@as(f64, 2), out[6].number);
    try std.testing.expectEqualStrings("1,22,333", out[7].string);
}

test "Lua 5.1 string library coerces numbers" {
    const lua = @import("root.zig");
    const source =
        \\return string.find(12345, "34", nil, true), string.sub(12345, 2, 4), string.len(12345)
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    try std.testing.expectEqual(@as(f64, 3), out[0].number);
    try std.testing.expectEqualStrings("234", out[1].string);
    try std.testing.expectEqual(@as(f64, 5), out[2].number);
}

test "Lua 5.1 gsub replacement escapes accept non-digits" {
    const captures: [pattern.max_captures]pattern.Capture = undefined;
    const m = pattern.Match{ .start = 1, .end = 2, .captures = captures, .capture_count = 0 };
    const got = try expandReplacement(std.testing.allocator, "%[%[", "x\x01y", m);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("[[", got);

    const literal = try expandReplacement(std.testing.allocator, "%q%%", "x\x01y", m);
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("q%", literal);

    const trailing = try expandReplacement(std.testing.allocator, "%", "x\x01y", m);
    defer std.testing.allocator.free(trailing);
    try std.testing.expectEqualSlices(u8, &.{0}, trailing);
}

test "Scribunto pairs and ipairs honor iterator metamethods" {
    const lua = @import("root.zig");
    const source =
        \\local parent = { g = "ɡ", ["ā"] = "aː" }
        \\local t = setmetatable({}, {
        \\  __index = parent,
        \\  __pairs = function() return next, parent, nil end,
        \\  __ipairs = function()
        \\    local vals = {"x", "y"}
        \\    return function(_, i) i = i + 1; if vals[i] then return i, vals[i] end end, nil, 0
        \\  end,
        \\})
        \\local got = {}
        \\for k, v in pairs(t) do got[k] = v end
        \\local seq = {}
        \\for i, v in ipairs(t) do seq[i] = v end
        \\return got.g, got["ā"], table.concat(seq, ",")
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqualStrings("ɡ", out[0].string);
    try std.testing.expectEqualStrings("aː", out[1].string);
    try std.testing.expectEqualStrings("x,y", out[2].string);
}

test "Lua string.find plain mode does not confuse IPA script-g with ASCII g" {
    const lua = @import("root.zig");
    const source =
        \\return string.find("ˈɡraː.tiːs", "g", nil, true), string.find("ˈɡraː.tiːs", "ɡ", nil, true)
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expect(out[0] == .nil);
    try std.testing.expectEqual(@as(f64, 3), out[1].number);
    try std.testing.expectEqual(@as(f64, 4), out[2].number);
}

test "Lua 5.1 gsub consumes UTF-8 continuation byte ranges" {
    const lua = @import("root.zig");
    const source =
        \\return string.gsub("\202\131x", "^[\1-\127\194-\244][\128-\191]*", "")
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqualStrings("x", out[0].string);
    try std.testing.expectEqual(@as(f64, 1), out[1].number);
}
