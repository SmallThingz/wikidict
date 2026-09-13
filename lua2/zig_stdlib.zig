const std = @import("std");
const rt = @import("zig_runtime");
const pattern = @import("lua_pattern.zig");
const lua_format = @import("zig_format.zig");
const global_abi = @import("vm_global_abi.zig");
const Value = rt.Value;

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
fn bufferedOne(buffer: ?[]Value, v: Value) ![]const Value {
    const out = try rt.returnBuffer(buffer, 1);
    rt.storeReturn(out, 0, v);
    return out;
}
fn bufferedTwo(buffer: ?[]Value, x: Value, y: Value) ![]const Value {
    const out = try rt.returnBuffer(buffer, 2);
    rt.storeReturn(out, 0, x);
    rt.storeReturn(out, 1, y);
    return out;
}
fn num(v: Value) !f64 {
    return rt.toNumber(v) orelse error.NumberExpected;
}
fn integer(v: Value) !i64 {
    const n = switch (v) {
        .number => |value| value,
        else => try num(v),
    };
    return @intFromFloat(@trunc(n));
}
fn str(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        else => error.StringExpected,
    };
}

fn setNative(vm: *rt.Context, t: *rt.Table, name: []const u8, comptime call: anytype) !void {
    try t.rawSet(vm.allocator, .{ .string = name }, try vm.newNative(null, call));
}
fn setGlobalNative(vm: *rt.Context, comptime name: []const u8, comptime call: anytype) !void {
    try vm.setGlobal(global_abi.id(name), try vm.newNative(null, call));
}

fn baseRequire(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(ctx.allocator, try ctx.requireByName(args[0].string));
}

const ModuleLoaderCtx = struct { module_id: u32 };
const MainModuleLoaderCtx = struct { cache: *rt.Table };

fn moduleLoader(raw: ?*anyopaque, ctx: *rt.Context, _: []const Value) ![]const Value {
    const loader: *ModuleLoaderCtx = @ptrCast(@alignCast(raw orelse return error.MissingModuleLoader));
    return one(ctx.allocator, try ctx.loadModule(loader.module_id, null));
}

fn mainModuleLoader(raw: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const state: *MainModuleLoaderCtx = @ptrCast(@alignCast(raw orelse return error.MissingModuleLoader));
    const module_id = ctx.resolveModule(args[0].string) catch return one(ctx.allocator, .nil);
    const key: Value = .{ .number = @floatFromInt(module_id) };
    if (state.cache.rawGet(key)) |loader| return one(ctx.allocator, loader);
    const loader_ctx = try ctx.allocator.create(ModuleLoaderCtx);
    loader_ctx.* = .{ .module_id = module_id };
    const loader = try ctx.newNative(loader_ctx, moduleLoader);
    try state.cache.rawSet(ctx.allocator, key, loader);
    return one(ctx.allocator, loader);
}

fn baseType(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const name = if (args.len == 0) "nil" else switch (args[0]) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .table => "table",
        .callable => "function",
    };
    return one(a, .{ .string = name });
}
fn baseAssert(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len != 0 and args[0].truthy()) {
        const out = try std.heap.smp_allocator.alloc(Value, args.len);
        @memcpy(out, args);
        return out;
    }
    const vm = ctx;
    vm.last_error = if (args.len > 1) args[1] else .{ .string = "assertion failed!" };
    return error.LuaRaised;
}
fn baseError(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const vm = ctx;
    vm.last_error = if (args.len != 0) args[0] else .nil;
    return error.LuaRaised;
}
fn baseRawEqual(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    return one(a, .{ .boolean = args.len >= 2 and rt.rawEqual(args[0], args[1]) });
}
fn baseRawGet(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    return one(a, args[0].table.rawGet(args[1]) orelse .nil);
}
fn baseRawSet(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 3 or args[0] != .table) return error.TableExpected;
    try args[0].table.rawSet(ctx.allocator, args[1], args[2]);
    return one(a, args[0]);
}
fn baseGetMetatable(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len == 0) return one(a, .nil);
    const vm = ctx;
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => vm.string_metatable,
        else => null,
    };
    const actual = mt orelse return one(a, .nil);
    if (actual.rawGet(.{ .string = "__metatable" })) |v| return one(a, v);
    return one(a, .{ .table = actual });
}
fn baseSetMetatable(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    if (args[0].table.metatable) |old| if (old.rawGet(.{ .string = "__metatable" }) != null) return error.ProtectedMetatable;
    args[0].table.metatable = switch (args[1]) {
        .nil => null,
        .table => |t| t,
        else => return error.TableExpected,
    };
    return one(a, args[0]);
}

fn baseToString(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const vm = ctx;
    const v = if (args.len == 0) Value.nil else args[0];
    if (vm.metamethod(v, "__tostring")) |mm| {
        const out = try vm.callValue(mm, &.{v});
        defer rt.freeResults(out);
        if (out.len == 0 or out[0] != .string) return error.StringExpected;
        return one(a, out[0]);
    }
    const s: []const u8 = switch (v) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try rt.numberToString(a, n),
        .string => |x| x,
        .table => |p| try std.fmt.allocPrint(a, "table: 0x{x}", .{@intFromPtr(p)}),
        .callable => |f| try std.fmt.allocPrint(a, "function: 0x{x}", .{f.identity}),
    };
    return one(a, .{ .string = s });
}
fn baseToNumber(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
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
fn baseSelect(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
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
fn baseUnpack(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const i: i64 = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1;
    const j: i64 = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else @intCast(t.rawLen());
    if (j < i) return &.{};
    const out = try std.heap.smp_allocator.alloc(Value, @intCast(j - i + 1));
    for (out, 0..) |*v, k| v.* = t.rawGet(.{ .number = @floatFromInt(i + @as(i64, @intCast(k))) }) orelse .nil;
    return out;
}

fn baseNext(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const key = if (args.len > 1) args[1] else Value.nil;
    var it = t.iterator();
    var found = key == .nil;
    if (!found) {
        if (ctx.next_iteration_hint) |hint| {
            if (hint.table == t and rt.rawEqual(hint.key, key) and it.restorePosition(hint.position)) found = true;
        }
        if (!found) {
            while (it.next()) |entry| {
                if (rt.rawEqual(entry.key_ptr.*, key)) {
                    found = true;
                    break;
                }
            }
        }
    }
    if (!found) {
        ctx.next_iteration_hint = null;
        return error.InvalidNextKey;
    }
    const entry = it.next() orelse {
        ctx.next_iteration_hint = null;
        return bufferedOne(result_buffer, .nil);
    };
    const next_key = entry.key_ptr.*;
    ctx.next_iteration_hint = .{ .table = t, .key = next_key, .position = it.position() };
    return bufferedTwo(result_buffer, next_key, entry.value_ptr.*);
}
fn iteratorTripleFromCall(vm: *rt.Context, callable: Value, object: Value) ![]const Value {
    const values = try vm.callValue(callable, &.{object});
    defer rt.freeResults(values);
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    for (out, 0..) |*slot, i| slot.* = if (i < values.len) values[i] else .nil;
    return out;
}

fn exposedMetamethod(vm: *rt.Context, object: Value, name: []const u8) !?Value {
    if (object != .table) return null;
    const actual = object.table.metatable orelse return null;
    const exposed = actual.rawGet(.{ .string = "__metatable" }) orelse Value{ .table = actual };
    if (!exposed.truthy()) return null;
    const method = try vm.getIndex(exposed, .{ .string = name });
    return if (method.truthy()) method else null;
}

fn basePairs(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const vm = ctx;
    if (try exposedMetamethod(vm, args[0], "__pairs")) |method|
        return iteratorTripleFromCall(vm, method, args[0]);
    const nxt = vm.getGlobal(global_abi.id("next"));
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = nxt;
    out[1] = args[0];
    out[2] = .nil;
    return out;
}
fn ipairsIter(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    const i = (try integer(args[1])) + 1;
    const v = args[0].table.rawGet(.{ .number = @floatFromInt(i) }) orelse return bufferedOne(result_buffer, .nil);
    return bufferedTwo(result_buffer, .{ .number = @floatFromInt(i) }, v);
}
fn baseIpairs(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const vm = ctx;
    if (try exposedMetamethod(vm, args[0], "__ipairs")) |method|
        return iteratorTripleFromCall(vm, method, args[0]);
    const iter = try vm.newNativeBuffered(null, ipairsIter);
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = iter;
    out[1] = args[0];
    out[2] = .{ .number = 0 };
    return out;
}
fn basePcall(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    const saved_error = ctx.last_error;
    const saved_aot_error_name = ctx.aot_error_name;
    ctx.last_error = .nil;
    ctx.clearAotErrorName();
    const result = ctx.callValue(args[0], args[1..]) catch |err| {
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .boolean = false };
        out[1] = if (ctx.last_error != .nil)
            ctx.last_error
        else if (ctx.aotErrorName()) |name|
            .{ .string = try ctx.allocator.dupe(u8, name) }
        else
            .{ .string = @errorName(err) };
        ctx.last_error = saved_error;
        ctx.aot_error_name = saved_aot_error_name;
        return out;
    };
    ctx.last_error = saved_error;
    ctx.aot_error_name = saved_aot_error_name;
    defer rt.freeResults(result);
    const out = try std.heap.smp_allocator.alloc(Value, result.len + 1);
    out[0] = .{ .boolean = true };
    @memcpy(out[1..], result);
    return out;
}

fn tableInsert(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n = t.rawLen();
    if (args.len == 2) {
        try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(n + 1) }, args[1]);
        return &.{};
    }
    const pos = try integer(args[1]);
    if (pos < 1 or pos > @as(i64, @intCast(n)) + 1) return error.PositionOutOfBounds;
    var i: i64 = @intCast(n + 1);
    while (i > pos) : (i -= 1) try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, t.rawGet(.{ .number = @floatFromInt(i - 1) }) orelse .nil);
    try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(pos) }, args[2]);
    return &.{};
}
fn tableRemove(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n: i64 = @intCast(t.rawLen());
    if (n == 0) return one(a, .nil);
    const pos = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else n;
    if (pos < 1 or pos > n) return one(a, .nil);
    const removed = t.rawGet(.{ .number = @floatFromInt(pos) }) orelse .nil;
    var i = pos;
    while (i < n) : (i += 1) try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, t.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse .nil);
    try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(n) }, .nil);
    return one(a, removed);
}
fn tableConcat(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
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
fn tableMaxn(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    var max: f64 = 0;
    var it = args[0].table.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* == .number and e.key_ptr.number > max) max = e.key_ptr.number;
    }
    return one(a, .{ .number = max });
}
fn tableSortLess(vm: *rt.Context, cmp: Value, a: Value, b: Value) !bool {
    if (cmp == .nil) return vm.comparison(.lt, a, b);
    const out = try vm.callValue(cmp, &.{ a, b });
    defer rt.freeResults(out);
    return out.len != 0 and out[0].truthy();
}

fn tableSortSiftDown(vm: *rt.Context, cmp: Value, values: []Value, root_in: usize, end: usize) !void {
    var root = root_in;
    while (root * 2 + 1 < end) {
        var child = root * 2 + 1;
        if (child + 1 < end and try tableSortLess(vm, cmp, values[child], values[child + 1])) child += 1;
        if (!try tableSortLess(vm, cmp, values[root], values[child])) return;
        std.mem.swap(Value, &values[root], &values[child]);
        root = child;
    }
}

fn tableSort(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const vm = ctx;
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

fn stringLen(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    return one(a, .{ .number = @floatFromInt((try str(a, args[0])).len) });
}
fn normIndex(i: i64, n: i64) i64 {
    return if (i < 0) n + i + 1 else i;
}
fn stringSub(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const n: i64 = @intCast(s.len);
    var i = normIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, n);
    var j = normIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else -1, n);
    i = @max(@as(i64, 1), i);
    j = @min(n, j);
    if (i > j or i > n) return one(a, .{ .string = "" });
    return one(a, .{ .string = s[@intCast(i - 1)..@intCast(j)] });
}
fn stringLower(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return one(a, .{ .string = out });
}
fn stringUpper(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return one(a, .{ .string = out });
}
fn stringReverse(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[s.len - 1 - i] = c;
    return one(a, .{ .string = out });
}
fn stringRep(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
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
fn stringChar(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const out = try a.alloc(u8, args.len);
    for (args, 0..) |v, i| {
        const x = try integer(v);
        if (x < 0 or x > 255) return error.ByteOutOfRange;
        out[i] = @intCast(x);
    }
    return one(a, .{ .string = out });
}
fn stringByte(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
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

fn stringFind(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
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

fn stringMatch(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2) return error.MissingArgument;
    const source = try str(a, args[0]);
    const pat = try str(a, args[1]);
    const init = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const m = try pattern.find(source, pat, init) orelse return one(a, .nil);
    return captureResults(a, source, m);
}
const GmatchCtx = struct { iterator: pattern.Iterator };
fn gmatchNext(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const state: *GmatchCtx = @ptrCast(@alignCast(ctx_raw.?));
    const m = try state.iterator.next() orelse return &.{};
    return captureResults(a, state.iterator.source, m);
}

fn stringGmatch(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2) return error.MissingArgument;
    const state = try ctx.allocator.create(GmatchCtx);
    state.* = .{ .iterator = .{ .source = try str(a, args[0]), .pattern = try str(a, args[1]) } };
    return one(a, try ctx.newNative(state, gmatchNext));
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

fn replacementValue(vm: *rt.Context, replacement: Value, source: []const u8, m: pattern.Match, a: std.mem.Allocator) !?[]const u8 {
    const original = source[m.start..m.end];
    const value: Value = switch (replacement) {
        .string => return try expandReplacement(a, replacement.string, source, m),
        .table => |table| blk: {
            const captures = try replacementArgs(a, source, m);
            defer rt.freeResults(captures);
            const key = if (captures.len == 0) Value{ .string = original } else captures[0];
            break :blk try vm.getIndex(.{ .table = table }, key);
        },
        .callable => blk: {
            const captures = try replacementArgs(a, source, m);
            defer rt.freeResults(captures);
            const result = try vm.callValue(replacement, captures);
            defer rt.freeResults(result);
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

fn stringFormat(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    return one(a, .{ .string = try lua_format.format(a, args) });
}

fn stringGsub(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 3) return error.MissingArgument;
    const vm = ctx;
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
fn mathUnary(raw: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const op: *MathOp = @ptrCast(@alignCast(raw.?));
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
fn mathMin(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len == 0) return error.MissingArgument;
    var x = try num(args[0]);
    for (args[1..]) |v| x = @min(x, try num(v));
    return one(a, .{ .number = x });
}
fn mathMax(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len == 0) return error.MissingArgument;
    var x = try num(args[0]);
    for (args[1..]) |v| x = @max(x, try num(v));
    return one(a, .{ .number = x });
}
fn mathPow(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    return one(a, .{ .number = std.math.pow(f64, try num(args[0]), try num(args[1])) });
}
fn mathFmod(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const x = try num(args[0]);
    const y = try num(args[1]);
    return one(a, .{ .number = @rem(x, y) });
}
fn mathModf(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const x = try num(args[0]);
    const ip = @trunc(x);
    return two(a, .{ .number = ip }, .{ .number = x - ip });
}

fn debugGetMetatable(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    const vm = ctx;
    if (args.len == 0) return one(a, .nil);
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => vm.string_metatable,
        else => null,
    };
    return one(a, if (mt) |t| .{ .table = t } else .nil);
}
fn debugTraceback(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const a = ctx.allocator;
    return one(a, if (args.len != 0 and args[0] == .string) args[0] else .{ .string = "" });
}
fn debugGetInfo(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return error.NotImplemented;
}

fn addMath(vm: *rt.Context, t: *rt.Table, name: []const u8, op: MathOp) !void {
    const ctx = try vm.allocator.create(MathOp);
    ctx.* = op;
    try t.rawSet(vm.allocator, .{ .string = name }, try vm.newNative(ctx, mathUnary));
}

pub fn install(vm: *rt.Context) !void {
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
    try vm.setGlobal(global_abi.id("next"), try vm.newNativeBuffered(null, baseNext));
    try setGlobalNative(vm, "pairs", basePairs);
    try setGlobalNative(vm, "ipairs", baseIpairs);
    try setGlobalNative(vm, "pcall", basePcall);

    const package = try vm.newTable();
    const loaded = try vm.newTable();
    const loaders = try vm.newTable();
    try package.rawSet(vm.allocator, .{ .string = "loaded" }, .{ .table = loaded });
    try package.rawSet(vm.allocator, .{ .string = "loaders" }, .{ .table = loaders });
    const loader_state = try vm.allocator.create(MainModuleLoaderCtx);
    loader_state.* = .{ .cache = try vm.newTable() };
    try loaders.rawSet(vm.allocator, .{ .number = 2 }, try vm.newNative(loader_state, mainModuleLoader));
    vm.package_loaded = loaded;
    try vm.setGlobal(global_abi.id("package"), .{ .table = package });
    try setGlobalNative(vm, "require", baseRequire);

    const table = try vm.newNativeNamespace(.table);
    try setNative(vm, table, "insert", tableInsert);
    try setNative(vm, table, "remove", tableRemove);
    try setNative(vm, table, "concat", tableConcat);
    try setNative(vm, table, "sort", tableSort);
    try setNative(vm, table, "maxn", tableMaxn);
    try setNative(vm, table, "getn", struct {
        fn f(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
            const a = ctx.allocator;
            if (args.len == 0 or args[0] != .table) return error.TableExpected;
            return one(a, .{ .number = @floatFromInt(args[0].table.rawLen()) });
        }
    }.f);
    try vm.setGlobal(global_abi.id("table"), .{ .table = table });
    const string = try vm.newNativeNamespace(.string);
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
    try vm.setGlobal(global_abi.id("string"), .{ .table = string });
    const smt = try vm.newTable();
    try smt.rawSet(vm.allocator, .{ .string = "__index" }, .{ .table = string });
    vm.string_metatable = smt;
    const math = try vm.newNativeNamespace(.math);
    inline for (.{ .{ "abs", MathOp.abs }, .{ "ceil", .ceil }, .{ "floor", .floor }, .{ "sqrt", .sqrt }, .{ "exp", .exp }, .{ "log", .log }, .{ "log10", .log10 }, .{ "sin", .sin }, .{ "cos", .cos }, .{ "tan", .tan }, .{ "asin", .asin }, .{ "acos", .acos }, .{ "atan", .atan }, .{ "deg", .deg }, .{ "rad", .rad } }) |x| try addMath(vm, math, x[0], x[1]);
    try setNative(vm, math, "min", mathMin);
    try setNative(vm, math, "max", mathMax);
    try setNative(vm, math, "pow", mathPow);
    try setNative(vm, math, "fmod", mathFmod);
    try setNative(vm, math, "mod", mathFmod);
    try setNative(vm, math, "modf", mathModf);
    try math.rawSet(vm.allocator, .{ .string = "pi" }, .{ .number = std.math.pi });
    try math.rawSet(vm.allocator, .{ .string = "huge" }, .{ .number = std.math.inf(f64) });
    try vm.setGlobal(global_abi.id("math"), .{ .table = math });
    const debug = try vm.newNativeNamespace(.debug);
    try setNative(vm, debug, "getmetatable", debugGetMetatable);
    try setNative(vm, debug, "traceback", debugTraceback);
    try setNative(vm, debug, "getinfo", debugGetInfo);
    try vm.setGlobal(global_abi.id("debug"), .{ .table = debug });
}

fn callField(ctx: *rt.Context, table: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try ctx.getIndex(table, .{ .string = name });
    return ctx.callValue(callable, args);
}

const ModuleLoaderProbe = struct {
    fn lookup(_: ?*const anyopaque, raw_name: []const u8) ?u32 {
        return if (std.mem.eql(u8, raw_name, "Module:A") or std.mem.eql(u8, raw_name, "Alias:A")) 0 else null;
    }
    fn name(_: ?*const anyopaque, id: u32) ?[]const u8 {
        return if (id == 0) "Module:A" else null;
    }
    fn root(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
        return one(ctx.allocator, .{ .string = "loaded" });
    }
};

test "AOT package main loader resolves and caches numeric module loaders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.initProgram(arena.allocator(), global_abi.count, 1);
    defer ctx.deinit();
    const functions = [_]rt.FunctionFn{rt.stabilize(ModuleLoaderProbe.root)};
    const roots = [_]u32{0};
    ctx.module_roots = &roots;
    ctx.module_root_entries = &.{&functions[0]};
    ctx.configureModules(null, ModuleLoaderProbe.lookup, ModuleLoaderProbe.name);
    try rt.bindGlobalTable(&ctx, null, global_abi.id("_G"));
    try install(&ctx);

    const package = ctx.getGlobal(global_abi.id("package"));
    const loaders = try ctx.getIndex(package, .{ .string = "loaders" });
    const main_loader = try ctx.getIndex(loaders, .{ .number = 2 });
    const first = try ctx.callValue(main_loader, &.{.{ .string = "Module:A" }});
    defer rt.freeResults(first);
    const alias = try ctx.callValue(main_loader, &.{.{ .string = "Alias:A" }});
    defer rt.freeResults(alias);
    try std.testing.expect(first.len == 1 and first[0] == .callable);
    try std.testing.expect(alias.len == 1 and rt.rawEqual(first[0], alias[0]));
    const missing = try ctx.callValue(main_loader, &.{.{ .string = "Module:Missing" }});
    defer rt.freeResults(missing);
    try std.testing.expect(missing.len == 1 and missing[0] == .nil);
    const loaded = try ctx.callValue(first[0], &.{});
    defer rt.freeResults(loaded);
    try std.testing.expectEqualStrings("loaded", loaded[0].string);
    try std.testing.expectEqualStrings("loaded", ctx.package_loaded.?.rawGet(.{ .string = "Module:A" }).?.string);
}

test "AOT standard library installs numeric globals and executes core helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try rt.bindGlobalTable(&ctx, null, global_abi.id("_G"));
    try install(&ctx);

    const package = ctx.getGlobal(global_abi.id("package"));
    try std.testing.expect(package == .table);
    const loaded = try ctx.getIndex(package, .{ .string = "loaded" });
    try std.testing.expect(loaded == .table and ctx.package_loaded == loaded.table);
    const require = ctx.getGlobal(global_abi.id("require"));
    try std.testing.expect(require == .callable);
    try std.testing.expectError(error.AotCallFailed, ctx.callValue(require, &.{.{ .string = "Module:Missing" }}));
    try std.testing.expectEqualStrings("ModuleNotFound", ctx.aotErrorName().?);
    ctx.clearAotErrorName();

    const string = ctx.getGlobal(global_abi.id("string"));
    const sub = try callField(&ctx, string, "sub", &.{ .{ .string = "abcdef" }, .{ .number = 2 }, .{ .number = -2 } });
    defer rt.freeResults(sub);
    try std.testing.expectEqualStrings("bcde", sub[0].string);

    const match = try callField(&ctx, string, "match", &.{ .{ .string = "abc123" }, .{ .string = "(%a+)(%d+)" } });
    defer rt.freeResults(match);
    try std.testing.expectEqualStrings("abc", match[0].string);
    try std.testing.expectEqualStrings("123", match[1].string);

    const formatted = try callField(&ctx, string, "format", &.{ .{ .string = "%s:%02d" }, .{ .string = "n" }, .{ .number = 7 } });
    defer rt.freeResults(formatted);
    try std.testing.expectEqualStrings("n:07", formatted[0].string);

    const table = ctx.getGlobal(global_abi.id("table"));
    const values = try ctx.newTable();
    const inserted = try callField(&ctx, table, "insert", &.{ .{ .table = values }, .{ .string = "x" } });
    defer rt.freeResults(inserted);
    try std.testing.expectEqualStrings("x", values.rawGet(.{ .number = 1 }).?.string);

    const math = ctx.getGlobal(global_abi.id("math"));
    const max = try callField(&ctx, math, "max", &.{ .{ .number = 3 }, .{ .number = 8 }, .{ .number = 5 } });
    defer rt.freeResults(max);
    try std.testing.expectEqual(@as(f64, 8), max[0].number);
}

test "AOT sparse array borders survive table remove and insert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);

    const lib = ctx.getGlobal(global_abi.id("table"));
    const values = try ctx.newTable();
    for (1..21) |index| try values.append(ctx.allocator, if (index == 1 or index == 11) .nil else .{ .number = @floatFromInt(index) });
    try std.testing.expectEqual(@as(usize, 20), values.rawLen());

    const remove11 = try callField(&ctx, lib, "remove", &.{ .{ .table = values }, .{ .number = 11 } });
    defer rt.freeResults(remove11);
    try std.testing.expectEqual(@as(usize, 19), values.rawLen());
    const remove1 = try callField(&ctx, lib, "remove", &.{ .{ .table = values }, .{ .number = 1 } });
    defer rt.freeResults(remove1);
    try std.testing.expectEqual(@as(usize, 18), values.rawLen());
    const insert1 = try callField(&ctx, lib, "insert", &.{ .{ .table = values }, .{ .number = 1 }, .nil });
    defer rt.freeResults(insert1);
    try std.testing.expectEqual(@as(usize, 19), values.rawLen());
    const insert11 = try callField(&ctx, lib, "insert", &.{ .{ .table = values }, .{ .number = 11 }, .nil });
    defer rt.freeResults(insert11);
    try std.testing.expectEqual(@as(usize, 20), values.rawLen());
}

test "AOT pcall preserves Lua error values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);
    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const raise = ctx.getGlobal(global_abi.id("error"));
    const out = try ctx.callValue(pcall, &.{ raise, .{ .string = "boom" } });
    defer rt.freeResults(out);
    try std.testing.expect(!out[0].boolean);
    try std.testing.expectEqualStrings("boom", out[1].string);
}

fn stablePcallFailure(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
    return error.NotCallable;
}

test "AOT pcall preserves stable generated-function error names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);
    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const callable = try ctx.makeFunctionKnown(0, stablePcallFailure, &.{});
    const out = try ctx.callValue(pcall, &.{callable});
    defer rt.freeResults(out);
    try std.testing.expect(!out[0].boolean);
    try std.testing.expectEqualStrings("NotCallable", out[1].string);
    try std.testing.expect(ctx.aotErrorName() == null);
}

test "AOT native next and ipairs iterators borrow fixed result storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);

    const values = try ctx.newTable();
    try values.rawSet(ctx.allocator, .{ .number = 1 }, .{ .string = "x" });
    const table_value = Value{ .table = values };
    var storage: [2]Value = undefined;

    const next = ctx.getGlobal(global_abi.id("next"));
    const first = try ctx.callValueFixed(next, &.{ table_value, .nil }, &storage);
    defer first.deinit();
    try std.testing.expect(!first.owned);
    try std.testing.expectEqual(@as(usize, 2), first.values.len);
    try std.testing.expectEqual(@as(f64, 1), first.values[0].number);
    try std.testing.expectEqualStrings("x", first.values[1].string);
    const first_key = first.values[0];

    const done = try ctx.callValueFixed(next, &.{ table_value, first_key }, &storage);
    defer done.deinit();
    try std.testing.expect(!done.owned);
    try std.testing.expectEqual(@as(usize, 1), done.values.len);
    try std.testing.expect(done.values[0] == .nil);

    const ipairs = ctx.getGlobal(global_abi.id("ipairs"));
    const triple = try ctx.callValue(ipairs, &.{table_value});
    defer rt.freeResults(triple);
    try std.testing.expectEqual(@as(usize, 3), triple.len);
    const item = try ctx.callValueFixed(triple[0], triple[1..3], &storage);
    defer item.deinit();
    try std.testing.expect(!item.owned);
    try std.testing.expectEqual(@as(usize, 2), item.values.len);
    try std.testing.expectEqual(@as(f64, 1), item.values[0].number);
    try std.testing.expectEqualStrings("x", item.values[1].string);
    const item_key = item.values[0];

    const numeric_string = try ctx.callValueFixed(triple[0], &.{ table_value, .{ .string = "0" } }, &storage);
    defer numeric_string.deinit();
    try std.testing.expectEqual(@as(usize, 2), numeric_string.values.len);
    try std.testing.expectEqual(@as(f64, 1), numeric_string.values[0].number);

    const ipairs_done = try ctx.callValueFixed(triple[0], &.{ table_value, item_key }, &storage);
    defer ipairs_done.deinit();
    try std.testing.expect(!ipairs_done.owned);
    try std.testing.expectEqual(@as(usize, 1), ipairs_done.values.len);
    try std.testing.expect(ipairs_done.values[0] == .nil);
}

test "AOT next resumes sequential table iteration and falls back after interleaving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);

    const values = try ctx.newTable();
    for (1..4) |i| try values.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, .{ .number = @floatFromInt(i * 10) });
    const table_value = Value{ .table = values };
    const next = ctx.getGlobal(global_abi.id("next"));
    var storage: [2]Value = undefined;

    const first = try ctx.callValueFixed(next, &.{ table_value, .nil }, &storage);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.values.len);
    const first_key = first.values[0];
    try std.testing.expect(ctx.next_iteration_hint != null);
    try std.testing.expect(ctx.next_iteration_hint.?.table == values);
    try std.testing.expect(rt.rawEqual(ctx.next_iteration_hint.?.key, first_key));

    // Lua permits deleting the current key while traversing a table. The saved
    // position lets the immediately following next(t, key) continue safely.
    try values.rawSet(ctx.allocator, first_key, .nil);
    const second = try ctx.callValueFixed(next, &.{ table_value, first_key }, &storage);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.values.len);
    const second_key = second.values[0];

    // Interleaving another traversal invalidates only the optimization hint;
    // the ordinary key scan remains the semantic fallback.
    const other = try ctx.newTable();
    try other.rawSet(ctx.allocator, .{ .string = "other" }, .{ .number = 1 });
    const other_first = try ctx.callValueFixed(next, &.{ .{ .table = other }, .nil }, &storage);
    defer other_first.deinit();
    try std.testing.expectEqual(@as(usize, 2), other_first.values.len);
    const third = try ctx.callValueFixed(next, &.{ table_value, second_key }, &storage);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 2), third.values.len);

    ctx.clearAotErrorName();
    try std.testing.expectError(error.AotCallFailed, ctx.callValueFixed(next, &.{ table_value, .{ .number = 999 } }, &storage));
    try std.testing.expectEqualStrings("InvalidNextKey", ctx.aotErrorName().?);
}
