const std = @import("std");
const rt = @import("zig_runtime");
const pattern = @import("pattern.zig");
const lua_format = @import("format.zig");
const global_abi = @import("lua_globals");
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

fn setNative(runtime: *rt.Context, t: *rt.Table, name: []const u8, comptime call: anytype) !void {
    try t.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(null, call));
}
fn setGlobalNative(runtime: *rt.Context, comptime name: []const u8, comptime call: anytype) !void {
    try runtime.setGlobal(global_abi.id(name), try runtime.newNative(null, call));
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
    const runtime = ctx;
    runtime.last_error = if (args.len > 1) args[1] else .{ .string = "assertion failed!" };
    return error.LuaRaised;
}
fn baseError(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const runtime = ctx;
    runtime.last_error = if (args.len != 0) args[0] else .nil;
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
    const runtime = ctx;
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => runtime.string_metatable,
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
    const runtime = ctx;
    const v = if (args.len == 0) Value.nil else args[0];
    if (runtime.metamethod(v, "__tostring")) |mm| {
        const out = try runtime.callValue(mm, &.{v});
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
fn iteratorTripleFromCall(runtime: *rt.Context, callable: Value, object: Value) ![]const Value {
    const values = try runtime.callValue(callable, &.{object});
    defer rt.freeResults(values);
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    for (out, 0..) |*slot, i| slot.* = if (i < values.len) values[i] else .nil;
    return out;
}

fn exposedMetamethod(runtime: *rt.Context, object: Value, name: []const u8) !?Value {
    if (object != .table) return null;
    const actual = object.table.metatable orelse return null;
    const exposed = actual.rawGet(.{ .string = "__metatable" }) orelse Value{ .table = actual };
    if (!exposed.truthy()) return null;
    const method = try runtime.getIndex(exposed, .{ .string = name });
    return if (method.truthy()) method else null;
}

fn basePairs(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const runtime = ctx;
    if (try exposedMetamethod(runtime, args[0], "__pairs")) |method|
        return iteratorTripleFromCall(runtime, method, args[0]);
    const nxt = runtime.getGlobal(global_abi.id("next"));
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = nxt;
    out[1] = args[0];
    out[2] = .nil;
    return out;
}
fn ipairsIter(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    const i = (try integer(args[1])) + 1;
    const v = args[0].table.rawGetNumber(@floatFromInt(i)) orelse return bufferedOne(result_buffer, .nil);
    return bufferedTwo(result_buffer, .{ .number = @floatFromInt(i) }, v);
}
fn baseIpairs(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const runtime = ctx;
    if (try exposedMetamethod(runtime, args[0], "__ipairs")) |method|
        return iteratorTripleFromCall(runtime, method, args[0]);
    const iter = try runtime.newNativeBuffered(null, ipairsIter);
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = iter;
    out[1] = args[0];
    out[2] = .{ .number = 0 };
    return out;
}
fn protectedErrorValue(ctx: *rt.Context, err: anyerror) !Value {
    if (ctx.last_error != .nil) return ctx.last_error;
    if (ctx.aotErrorName()) |name| return .{ .string = try ctx.allocator.dupe(u8, name) };
    return .{ .string = @errorName(err) };
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
        out[1] = try protectedErrorValue(ctx, err);
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

fn baseXpcall(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    const saved_error = ctx.last_error;
    const saved_aot_error_name = ctx.aot_error_name;
    ctx.last_error = .nil;
    ctx.clearAotErrorName();
    const result = ctx.callValue(args[0], &.{}) catch |err| {
        const original_error = try protectedErrorValue(ctx, err);
        ctx.last_error = .nil;
        ctx.clearAotErrorName();
        const handled = ctx.callValue(args[1], &.{original_error}) catch {
            const out = try std.heap.smp_allocator.alloc(Value, 2);
            out[0] = .{ .boolean = false };
            out[1] = .{ .string = "error in error handling" };
            ctx.last_error = saved_error;
            ctx.aot_error_name = saved_aot_error_name;
            return out;
        };
        defer rt.freeResults(handled);
        const out = try std.heap.smp_allocator.alloc(Value, 2);
        out[0] = .{ .boolean = false };
        out[1] = if (handled.len == 0) .nil else handled[0];
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

fn installDynamicBase(runtime: *rt.Context) !void {
    const global = runtime.global_table orelse return;
    try global.rawSet(runtime.allocator, .{ .string = "xpcall" }, try runtime.newNative(null, baseXpcall));
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
fn tableSortLess(runtime: *rt.Context, cmp: Value, a: Value, b: Value) !bool {
    if (cmp == .nil) return runtime.comparison(.lt, a, b);
    const out = try runtime.callValue(cmp, &.{ a, b });
    defer rt.freeResults(out);
    return out.len != 0 and out[0].truthy();
}

fn tableSortSiftDown(runtime: *rt.Context, cmp: Value, values: []Value, root_in: usize, end: usize) !void {
    var root = root_in;
    while (root * 2 + 1 < end) {
        var child = root * 2 + 1;
        if (child + 1 < end and try tableSortLess(runtime, cmp, values[child], values[child + 1])) child += 1;
        if (!try tableSortLess(runtime, cmp, values[root], values[child])) return;
        std.mem.swap(Value, &values[root], &values[child]);
        root = child;
    }
}

fn tableSort(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const runtime = ctx;
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
        try tableSortSiftDown(runtime, cmp, values, start, n);
    }
    var end = n;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Value, &values[0], &values[end]);
        try tableSortSiftDown(runtime, cmp, values, 0, end);
    }

    for (values, 0..) |value, i|
        try t.rawSet(runtime.allocator, .{ .number = @floatFromInt(i + 1) }, value);
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

fn replacementValue(runtime: *rt.Context, replacement: Value, source: []const u8, m: pattern.Match, a: std.mem.Allocator) !?[]const u8 {
    const original = source[m.start..m.end];
    const value: Value = switch (replacement) {
        .string => return try expandReplacement(a, replacement.string, source, m),
        .table => |table| blk: {
            const captures = try replacementArgs(a, source, m);
            defer rt.freeResults(captures);
            const key = if (captures.len == 0) Value{ .string = original } else captures[0];
            break :blk try runtime.getIndex(.{ .table = table }, key);
        },
        .callable => blk: {
            const captures = try replacementArgs(a, source, m);
            defer rt.freeResults(captures);
            const result = try runtime.callValue(replacement, captures);
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
    const runtime = ctx;
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
        if (try replacementValue(runtime, replacement, source, m, a)) |text|
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
    const runtime = ctx;
    if (args.len == 0) return one(a, .nil);
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => runtime.string_metatable,
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

const MathRandomState = struct {
    state: [31]u32 = [_]u32{0} ** 31,
    front: u8 = 3,
    rear: u8 = 0,

    fn seed(self: *MathRandomState, raw_seed: u32) void {
        const seed_value: u32 = if (raw_seed == 0) 1 else raw_seed;
        self.state[0] = seed_value;
        var word: i64 = @as(i32, @bitCast(seed_value));
        var i: usize = 1;
        while (i < self.state.len) : (i += 1) {
            const hi = @divTrunc(word, 127773);
            const lo = @rem(word, 127773);
            word = 16807 * lo - 2836 * hi;
            if (word < 0) word += 2147483647;
            self.state[i] = @intCast(word);
        }
        self.front = 3;
        self.rear = 0;
        var warm: usize = 0;
        while (warm < self.state.len * 10) : (warm += 1) _ = self.next();
    }

    fn next(self: *MathRandomState) u32 {
        const front: usize = self.front;
        const rear: usize = self.rear;
        self.state[front] +%= self.state[rear];
        const result = self.state[front] >> 1;
        self.front = @intCast((front + 1) % self.state.len);
        self.rear = @intCast((rear + 1) % self.state.len);
        return result;
    }
};

fn randomSeedValue(value: Value) !u32 {
    const n = try integer(value);
    return @truncate(@as(u64, @bitCast(n)));
}
fn randomBound(value: Value) !i32 {
    const n = try integer(value);
    if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return error.RandomBoundOutOfRange;
    return @intCast(n);
}
fn mathRandomCall(raw: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const state: *MathRandomState = @ptrCast(@alignCast(raw orelse return error.MissingRandomState));
    const rand_max: u32 = 2147483647;
    const sample = state.next() % rand_max;
    const r = @as(f64, @floatFromInt(sample)) / @as(f64, @floatFromInt(rand_max));
    const result: f64 = switch (args.len) {
        0 => r,
        1 => blk: {
            const upper = try randomBound(args[0]);
            if (upper < 1) return error.RandomIntervalEmpty;
            break :blk @floor(r * @as(f64, @floatFromInt(upper))) + 1;
        },
        2 => blk: {
            const lower = try randomBound(args[0]);
            const upper = try randomBound(args[1]);
            if (lower > upper) return error.RandomIntervalEmpty;
            const width = @as(i64, upper) - @as(i64, lower) + 1;
            break :blk @floor(r * @as(f64, @floatFromInt(width))) + @as(f64, @floatFromInt(lower));
        },
        else => return error.WrongArgumentCount,
    };
    return one(ctx.allocator, .{ .number = result });
}
fn mathRandomSeedCall(raw: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    const state: *MathRandomState = @ptrCast(@alignCast(raw orelse return error.MissingRandomState));
    state.seed(try randomSeedValue(args[0]));
    return &.{};
}
fn installMathRandom(runtime: *rt.Context, math: *rt.Table) !void {
    const state = try runtime.allocator.create(MathRandomState);
    state.* = .{};
    state.seed(1);
    try math.rawSetNativeField(.math, "random", try runtime.newNative(state, mathRandomCall));
    try math.rawSetNativeField(.math, "randomseed", try runtime.newNative(state, mathRandomSeedCall));
}

pub fn resetMathRandom(runtime: *rt.Context) !void {
    const math = runtime.getGlobal(global_abi.id("math"));
    if (math != .table) return error.MissingMathLibrary;
    const seed_fn = math.table.rawGet(.{ .string = "randomseed" }) orelse return error.MissingRandomSeed;
    const result = try runtime.callValue(seed_fn, &.{.{ .number = 1 }});
    defer rt.freeResults(result);
}

fn addMath(runtime: *rt.Context, t: *rt.Table, name: []const u8, op: MathOp) !void {
    const ctx = try runtime.allocator.create(MathOp);
    ctx.* = op;
    try t.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(ctx, mathUnary));
}

fn bit32Value(value: Value) !u32 {
    const number = try num(value);
    if (!std.math.isFinite(number)) return error.NumberExpected;
    const modulus: f64 = 4294967296.0;
    const floored = @floor(number);
    const wrapped = floored - @floor(floored / modulus) * modulus;
    return @intFromFloat(wrapped);
}

fn bit32Band(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    var result: u32 = std.math.maxInt(u32);
    for (args) |arg| result &= try bit32Value(arg);
    return one(ctx.allocator, .{ .number = @floatFromInt(result) });
}

fn bit32Bor(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    var result: u32 = 0;
    for (args) |arg| result |= try bit32Value(arg);
    return one(ctx.allocator, .{ .number = @floatFromInt(result) });
}

fn makeBit32(runtime: *rt.Context) !*rt.Table {
    const bit32 = try runtime.newTable();
    try setNative(runtime, bit32, "band", bit32Band);
    try setNative(runtime, bit32, "bor", bit32Bor);
    return bit32;
}

fn installPackage(runtime: *rt.Context) !void {
    const package = try runtime.newTable();
    const loaded = try runtime.newTable();
    const loaders = try runtime.newTable();
    try package.rawSet(runtime.allocator, .{ .string = "loaded" }, .{ .table = loaded });
    try package.rawSet(runtime.allocator, .{ .string = "loaders" }, .{ .table = loaders });
    try loaded.rawSet(runtime.allocator, .{ .string = "bit32" }, .{ .table = try makeBit32(runtime) });
    const loader_state = try runtime.allocator.create(MainModuleLoaderCtx);
    loader_state.* = .{ .cache = try runtime.newTable() };
    try loaders.rawSet(runtime.allocator, .{ .number = 2 }, try runtime.newNative(loader_state, mainModuleLoader));
    runtime.package_loaded = loaded;
    try runtime.setGlobal(global_abi.id("package"), .{ .table = package });
}

pub fn install(runtime: *rt.Context) !void {
    try setGlobalNative(runtime, "type", baseType);
    try setGlobalNative(runtime, "assert", baseAssert);
    try setGlobalNative(runtime, "error", baseError);
    try setGlobalNative(runtime, "rawequal", baseRawEqual);
    try setGlobalNative(runtime, "rawget", baseRawGet);
    try setGlobalNative(runtime, "rawset", baseRawSet);
    try setGlobalNative(runtime, "getmetatable", baseGetMetatable);
    try setGlobalNative(runtime, "setmetatable", baseSetMetatable);
    try setGlobalNative(runtime, "tostring", baseToString);
    try setGlobalNative(runtime, "tonumber", baseToNumber);
    try setGlobalNative(runtime, "select", baseSelect);
    try setGlobalNative(runtime, "unpack", baseUnpack);
    try runtime.setGlobal(global_abi.id("next"), try runtime.newNativeBuffered(null, baseNext));
    try setGlobalNative(runtime, "pairs", basePairs);
    try setGlobalNative(runtime, "ipairs", baseIpairs);
    try setGlobalNative(runtime, "pcall", basePcall);
    try installDynamicBase(runtime);

    try installPackage(runtime);
    try setGlobalNative(runtime, "require", baseRequire);

    const table = try runtime.newNativeNamespace(.table);
    try setNative(runtime, table, "insert", tableInsert);
    try setNative(runtime, table, "remove", tableRemove);
    try setNative(runtime, table, "concat", tableConcat);
    try setNative(runtime, table, "sort", tableSort);
    try setNative(runtime, table, "maxn", tableMaxn);
    try setNative(runtime, table, "getn", struct {
        fn f(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
            const a = ctx.allocator;
            if (args.len == 0 or args[0] != .table) return error.TableExpected;
            return one(a, .{ .number = @floatFromInt(args[0].table.rawLen()) });
        }
    }.f);
    try runtime.setGlobal(global_abi.id("table"), .{ .table = table });
    const string = try runtime.newNativeNamespace(.string);
    try setNative(runtime, string, "len", stringLen);
    try setNative(runtime, string, "sub", stringSub);
    try setNative(runtime, string, "lower", stringLower);
    try setNative(runtime, string, "upper", stringUpper);
    try setNative(runtime, string, "reverse", stringReverse);
    try setNative(runtime, string, "rep", stringRep);
    try setNative(runtime, string, "char", stringChar);
    try setNative(runtime, string, "byte", stringByte);
    try setNative(runtime, string, "find", stringFind);
    try setNative(runtime, string, "match", stringMatch);
    try setNative(runtime, string, "gmatch", stringGmatch);
    try setNative(runtime, string, "gsub", stringGsub);
    try setNative(runtime, string, "format", stringFormat);
    try runtime.setGlobal(global_abi.id("string"), .{ .table = string });
    const smt = try runtime.newTable();
    try smt.rawSet(runtime.allocator, .{ .string = "__index" }, .{ .table = string });
    runtime.string_metatable = smt;
    const math = try runtime.newNativeNamespace(.math);
    inline for (.{ .{ "abs", MathOp.abs }, .{ "ceil", .ceil }, .{ "floor", .floor }, .{ "sqrt", .sqrt }, .{ "exp", .exp }, .{ "log", .log }, .{ "log10", .log10 }, .{ "sin", .sin }, .{ "cos", .cos }, .{ "tan", .tan }, .{ "asin", .asin }, .{ "acos", .acos }, .{ "atan", .atan }, .{ "deg", .deg }, .{ "rad", .rad } }) |x| try addMath(runtime, math, x[0], x[1]);
    try setNative(runtime, math, "min", mathMin);
    try setNative(runtime, math, "max", mathMax);
    try setNative(runtime, math, "pow", mathPow);
    try setNative(runtime, math, "fmod", mathFmod);
    try setNative(runtime, math, "mod", mathFmod);
    try setNative(runtime, math, "modf", mathModf);
    try math.rawSet(runtime.allocator, .{ .string = "pi" }, .{ .number = std.math.pi });
    try math.rawSet(runtime.allocator, .{ .string = "huge" }, .{ .number = std.math.inf(f64) });
    try installMathRandom(runtime, math);
    try runtime.setGlobal(global_abi.id("math"), .{ .table = math });
    const debug = try runtime.newNativeNamespace(.debug);
    try setNative(runtime, debug, "getmetatable", debugGetMetatable);
    try setNative(runtime, debug, "traceback", debugTraceback);
    try setNative(runtime, debug, "getinfo", debugGetInfo);
    try runtime.setGlobal(global_abi.id("debug"), .{ .table = debug });
}

fn cloneTemplateNamespace(runtime: *rt.Context, source: *rt.Table) !*rt.Table {
    const namespace = source.native_namespace orelse return error.TemplateNamespaceExpected;
    if (source.choices.len != 0 or source.map.count() != 0 or source.metatable != null)
        return error.UnsupportedTemplateNamespace;
    const out = try runtime.newNativeNamespace(namespace);
    if (out.slots.len != source.slots.len) return error.TemplateNamespaceLayoutMismatch;
    @memcpy(out.slots, source.slots);
    out.append_index = source.append_index;
    return out;
}

pub const Template = struct {
    arena: *std.heap.ArenaAllocator,
    base: rt.Context,

    pub fn init() !Template {
        const arena = try std.heap.smp_allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        errdefer {
            arena.deinit();
            std.heap.smp_allocator.destroy(arena);
        }
        var base = try rt.Context.init(arena.allocator(), global_abi.count);
        try rt.bindGlobalTable(&base, null, global_abi.id("_G"));
        try install(&base);
        return .{ .arena = arena, .base = base };
    }

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
        std.heap.smp_allocator.destroy(self.arena);
        self.* = undefined;
    }

    fn namespace(self: *const Template, comptime name: []const u8) !*rt.Table {
        const value = self.base.getGlobal(global_abi.id(name));
        return if (value == .table) value.table else error.TemplateNamespaceExpected;
    }

    pub fn bootstrapOpaque(raw: ?*const anyopaque, runtime: *rt.Context) !void {
        const self: *const Template = @ptrCast(@alignCast(raw orelse return error.MissingStdlibTemplate));
        try self.instantiate(runtime);
    }

    pub fn instantiate(self: *const Template, runtime: *rt.Context) !void {
        if (runtime.global_table == null) return error.GlobalTableNotBound;
        if (runtime.globals.len < self.base.globals.len) return error.TemplateGlobalLayoutMismatch;
        const page_global = runtime.global_table.?;
        @memcpy(runtime.globals[0..self.base.globals.len], self.base.globals);
        runtime.next_identity = self.base.next_identity;
        try runtime.setGlobal(global_abi.id("_G"), .{ .table = page_global });

        const table = try cloneTemplateNamespace(runtime, try self.namespace("table"));
        const string = try cloneTemplateNamespace(runtime, try self.namespace("string"));
        const math = try cloneTemplateNamespace(runtime, try self.namespace("math"));
        try installMathRandom(runtime, math);
        const debug = try cloneTemplateNamespace(runtime, try self.namespace("debug"));
        try runtime.setGlobal(global_abi.id("table"), .{ .table = table });
        try runtime.setGlobal(global_abi.id("string"), .{ .table = string });
        try runtime.setGlobal(global_abi.id("math"), .{ .table = math });
        try runtime.setGlobal(global_abi.id("debug"), .{ .table = debug });

        const string_mt = try runtime.newTable();
        try string_mt.rawSet(runtime.allocator, .{ .string = "__index" }, .{ .table = string });
        runtime.string_metatable = string_mt;
        try installPackage(runtime);
        try installDynamicBase(runtime);
    }
};

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
    ctx.module_root_entries = &functions;
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
    const bit32_result = try ctx.callValue(require, &.{.{ .string = "bit32" }});
    defer rt.freeResults(bit32_result);
    try std.testing.expect(bit32_result.len == 1 and bit32_result[0] == .table);
    const band = try callField(&ctx, bit32_result[0], "band", &.{ .{ .number = 0xF0 }, .{ .number = 0x3C } });
    defer rt.freeResults(band);
    try std.testing.expectEqual(@as(f64, 0x30), band[0].number);
    const bor = try callField(&ctx, bit32_result[0], "bor", &.{ .{ .number = 0x10 }, .{ .number = 0x03 }, .{ .number = 0x40 } });
    defer rt.freeResults(bor);
    try std.testing.expectEqual(@as(f64, 0x53), bor[0].number);
    const wrapped = try callField(&ctx, bit32_result[0], "band", &.{ .{ .number = -1 }, .{ .number = 0xFF } });
    defer rt.freeResults(wrapped);
    try std.testing.expectEqual(@as(f64, 0xFF), wrapped[0].number);
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

test "Lua 5.1 math random matches glibc sequence and reseeding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try rt.bindGlobalTable(&ctx, null, global_abi.id("_G"));
    try install(&ctx);
    const math = ctx.getGlobal(global_abi.id("math"));
    const random = try ctx.getIndex(math, .{ .string = "random" });
    const seed = try ctx.getIndex(math, .{ .string = "randomseed" });
    inline for ([_]f64{ 9, 4, 8 }) |expected| {
        const got = try ctx.callValue(random, &.{.{ .number = 10 }});
        defer rt.freeResults(got);
        try std.testing.expectEqual(expected, got[0].number);
    }
    const seeded = try ctx.callValue(seed, &.{.{ .number = 1 }});
    defer rt.freeResults(seeded);
    const range = try ctx.callValue(random, &.{ .{ .number = -300 }, .{ .number = 300 } });
    defer rt.freeResults(range);
    try std.testing.expectEqual(@as(f64, 204), range[0].number);
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

fn xpcallFail(ctx: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
    ctx.last_error = .{ .string = "boom" };
    return error.LuaError;
}
fn xpcallReturnPair(_: *rt.Context, _: rt.Captures, _: []const Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 2);
    out[0] = .{ .string = "left" };
    out[1] = .{ .number = 7 };
    return out;
}
fn xpcallHandle(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(ctx.allocator, .{ .string = try std.fmt.allocPrint(ctx.allocator, "handled:{s}", .{args[0].string}) });
}

test "AOT xpcall transforms failures and preserves success results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try rt.bindGlobalTable(&ctx, null, global_abi.id("_G"));
    try install(&ctx);
    const xpcall = ctx.global_table.?.rawGet(.{ .string = "xpcall" }).?;
    const fail_fn = try ctx.makeFunctionKnown(0, xpcallFail, &.{});
    const handler = try ctx.newNative(null, xpcallHandle);
    const failed = try ctx.callValue(xpcall, &.{ fail_fn, handler, .{ .string = "ignored" } });
    defer rt.freeResults(failed);
    try std.testing.expect(!failed[0].boolean);
    try std.testing.expectEqualStrings("handled:boom", failed[1].string);

    const success_fn = try ctx.makeFunctionKnown(0, xpcallReturnPair, &.{});
    const success = try ctx.callValue(xpcall, &.{ success_fn, handler });
    defer rt.freeResults(success);
    try std.testing.expect(success[0].boolean);
    try std.testing.expectEqualStrings("left", success[1].string);
    try std.testing.expectEqual(@as(f64, 7), success[2].number);
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

test "stdlib template keeps page mutation isolated" {
    var template = try Template.init();
    defer template.deinit();
    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();

    var first = try rt.Context.init(first_arena.allocator(), global_abi.count + 2);
    defer first.deinit();
    try rt.bindGlobalTable(&first, null, global_abi.id("_G"));
    try template.instantiate(&first);
    var second = try rt.Context.init(second_arena.allocator(), global_abi.count + 2);
    defer second.deinit();
    try rt.bindGlobalTable(&second, null, global_abi.id("_G"));
    try template.instantiate(&second);

    const first_table = first.getGlobal(global_abi.id("table")).table;
    const second_table = second.getGlobal(global_abi.id("table")).table;
    try std.testing.expect(first_table != second_table);
    try first_table.rawSet(first.allocator, .{ .string = "insert" }, .{ .number = 9 });
    try std.testing.expect(second_table.rawGet(.{ .string = "insert" }).? == .callable);
    try std.testing.expect(first.getGlobal(global_abi.id("package")).table != second.getGlobal(global_abi.id("package")).table);
    try std.testing.expect(first.getGlobal(global_abi.count) == .nil);
}
