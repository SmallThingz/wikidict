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
fn copyBufferedValues(buffer: []Value, values: []const Value) void {
    const count = @min(buffer.len, values.len);
    if (count == 0) return;
    if (@intFromPtr(buffer.ptr) > @intFromPtr(values.ptr))
        std.mem.copyBackwards(Value, buffer[0..count], values[0..count])
    else
        std.mem.copyForwards(Value, buffer[0..count], values[0..count]);
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
fn setNativeBuffered(runtime: *rt.Context, t: *rt.Table, name: []const u8, comptime call: anytype) !void {
    try t.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNativeBuffered(null, call));
}
fn setGlobalNative(runtime: *rt.Context, comptime name: []const u8, comptime call: anytype) !void {
    try runtime.setGlobal(global_abi.id(name), try runtime.newNative(null, call));
}
fn setGlobalNativeBuffered(runtime: *rt.Context, comptime name: []const u8, comptime call: anytype) !void {
    try runtime.setGlobal(global_abi.id(name), try runtime.newNativeBuffered(null, call));
}

fn strictGlobalName(ctx: *rt.Context, value: Value) ![]const u8 {
    return switch (value) {
        .string => |name| name,
        .number => |number| try rt.numberToString(ctx.allocator, number),
        else => valueTypeName(value),
    };
}

fn strictNewIndex(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 3 or args[0] != .table) return error.TableExpected;
    if (args[1] == .string and std.mem.eql(u8, args[1].string, "arg")) {
        try args[0].table.rawSet(ctx.allocator, args[1], args[2]);
        return &.{};
    }
    ctx.last_error = .{ .string = try std.fmt.allocPrint(
        ctx.allocator,
        "assign to undeclared variable '{s}'",
        .{try strictGlobalName(ctx, args[1])},
    ) };
    return error.LuaRaised;
}

fn strictIndex(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    if (args[1] == .string and std.mem.eql(u8, args[1].string, "arg"))
        return bufferedOne(result_buffer, args[0].table.rawGet(args[1]) orelse .nil);
    ctx.last_error = .{ .string = try std.fmt.allocPrint(
        ctx.allocator,
        "variable '{s}' is not declared",
        .{try strictGlobalName(ctx, args[1])},
    ) };
    return error.LuaRaised;
}

fn installStrict(ctx: *rt.Context) !Value {
    const global = ctx.global_table orelse return error.GlobalTableNotBound;
    const mt = global.metatable orelse try ctx.newTable();
    try mt.rawSet(ctx.allocator, .{ .string = "__newindex" }, try ctx.newNative(null, strictNewIndex));
    try mt.rawSet(ctx.allocator, .{ .string = "__index" }, try ctx.newNativeBuffered(null, strictIndex));
    global.metatable = mt;
    const result = Value{ .boolean = true };
    const loaded = ctx.package_loaded orelse return error.MissingPackageLoaded;
    try loaded.rawSet(ctx.allocator, .{ .string = "strict" }, result);
    return result;
}

fn baseRequire(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    if (std.mem.eql(u8, args[0].string, "strict")) {
        if (ctx.package_loaded) |loaded| if (loaded.rawGet(.{ .string = "strict" })) |value|
            return bufferedOne(result_buffer, value);
        return bufferedOne(result_buffer, try installStrict(ctx));
    }
    return bufferedOne(result_buffer, try ctx.requireByName(args[0].string));
}

const ModuleLoaderCtx = struct { module_id: u32 };
const MainModuleLoaderCtx = struct { cache: *rt.Table };

fn moduleLoader(raw: ?*anyopaque, ctx: *rt.Context, _: []const Value, result_buffer: ?[]Value) ![]const Value {
    const loader: *ModuleLoaderCtx = @ptrCast(@alignCast(raw orelse return error.MissingModuleLoader));
    return bufferedOne(result_buffer, try ctx.loadModule(loader.module_id, null));
}

fn mainModuleLoader(raw: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const state: *MainModuleLoaderCtx = @ptrCast(@alignCast(raw orelse return error.MissingModuleLoader));
    const module_id = ctx.resolveModule(args[0].string) catch return bufferedOne(result_buffer, .nil);
    const key: Value = .{ .number = @floatFromInt(module_id) };
    if (state.cache.rawGet(key)) |loader| return bufferedOne(result_buffer, loader);
    const loader_ctx = try ctx.allocator.create(ModuleLoaderCtx);
    loader_ctx.* = .{ .module_id = module_id };
    const loader = try ctx.newNativeBuffered(loader_ctx, moduleLoader);
    try state.cache.rawSet(ctx.allocator, key, loader);
    return bufferedOne(result_buffer, loader);
}

fn valueTypeName(value: Value) []const u8 {
    return switch (value) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .table => "table",
        .callable => "function",
    };
}

fn baseType(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    return bufferedOne(result_buffer, .{ .string = if (args.len == 0) "nil" else valueTypeName(args[0]) });
}
fn baseAssert(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len != 0 and args[0].truthy()) {
        const out = try rt.returnBuffer(result_buffer, args.len);
        copyBufferedValues(out, args);
        return out;
    }
    const runtime = ctx;
    runtime.setLuaError(if (args.len > 1) args[1] else .{ .string = "assertion failed!" });
    return error.LuaRaised;
}
fn baseError(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    const runtime = ctx;
    runtime.setLuaError(if (args.len != 0) args[0] else .nil);
    return error.LuaRaised;
}
fn baseRawEqual(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    return bufferedOne(result_buffer, .{ .boolean = args.len >= 2 and rt.rawEqual(args[0], args[1]) });
}
fn baseRawGet(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    return bufferedOne(result_buffer, args[0].table.rawGet(args[1]) orelse .nil);
}
fn baseRawSet(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 3 or args[0] != .table) return error.TableExpected;
    try args[0].table.rawSet(ctx.allocator, args[1], args[2]);
    return bufferedOne(result_buffer, args[0]);
}
fn baseGetMetatable(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0) return bufferedOne(result_buffer, .nil);
    const runtime = ctx;
    const mt: ?*rt.Table = switch (args[0]) {
        .table => |t| t.metatable,
        .string => runtime.string_metatable,
        else => null,
    };
    const actual = mt orelse return bufferedOne(result_buffer, .nil);
    if (actual.rawGet(.{ .string = "__metatable" })) |v| return bufferedOne(result_buffer, v);
    return bufferedOne(result_buffer, .{ .table = actual });
}
fn baseSetMetatable(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    if (args[0].table.metatable) |old| if (old.rawGet(.{ .string = "__metatable" }) != null) return error.ProtectedMetatable;
    args[0].table.metatable = switch (args[1]) {
        .nil => null,
        .table => |t| t,
        else => return error.TableExpected,
    };
    return bufferedOne(result_buffer, args[0]);
}

fn baseToString(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const runtime = ctx;
    const v = if (args.len == 0) Value.nil else args[0];
    // Default object strings expose an allocation address or function
    // identity. A metamethod may do so too, so conservatively reject either
    // object type from cross-page loadData snapshots.
    if (v == .table or v == .callable) rt.markLoadDataEffect();
    if (runtime.metamethod(v, "__tostring")) |mm| {
        const out = try runtime.callValue(mm, &.{v});
        defer rt.freeResults(out);
        if (out.len == 0 or out[0] != .string) return error.StringExpected;
        return bufferedOne(result_buffer, out[0]);
    }
    const s: []const u8 = switch (v) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try rt.numberToString(a, n),
        .string => |x| x,
        .table => |p| try std.fmt.allocPrint(a, "table: 0x{x}", .{@intFromPtr(p)}),
        .callable => |f| try std.fmt.allocPrint(a, "function: 0x{x}", .{f.identity}),
    };
    return bufferedOne(result_buffer, .{ .string = s });
}
fn explicitBaseDigit(c: u8) ?u8 {
    return if (c >= '0' and c <= '9')
        c - '0'
    else if (c >= 'a' and c <= 'z')
        c - 'a' + 10
    else if (c >= 'A' and c <= 'Z')
        c - 'A' + 10
    else
        null;
}

fn parseExplicitBase(a: std.mem.Allocator, value: Value, base: i64) !?f64 {
    if (base == 10) return rt.toNumber(value);
    const raw: []const u8 = switch (value) {
        .string => |text| text,
        .number => |number| try rt.numberToString(a, number),
        else => return error.StringExpected,
    };
    const text = std.mem.trim(u8, raw, rt.lua_number_whitespace);
    if (text.len == 0) return null;

    var i: usize = 0;
    const negative = text[0] == '-';
    if (text[0] == '+' or text[0] == '-') i += 1;
    if (base == 16 and i + 2 <= text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) i += 2;
    if (i == text.len) return null;

    const base_u: u64 = @intCast(base);
    var number: u64 = 0;
    var overflow = false;
    while (i < text.len) : (i += 1) {
        const digit = explicitBaseDigit(text[i]) orelse return null;
        if (digit >= base) return null;
        if (!overflow) {
            const digit_u: u64 = digit;
            if (number > (std.math.maxInt(u64) - digit_u) / base_u) {
                number = std.math.maxInt(u64);
                overflow = true;
            } else {
                number = number * base_u + digit_u;
            }
        }
    }
    if (negative and !overflow) number = 0 -% number;
    return @floatFromInt(number);
}

fn baseToNumber(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len == 0) return bufferedOne(result_buffer, .nil);
    if (args.len < 2 or args[1] == .nil) {
        return bufferedOne(result_buffer, if (rt.toNumber(args[0])) |n| .{ .number = n } else .nil);
    }
    const base = try integer(args[1]);
    if (base < 2 or base > 36) return error.BadBase;
    return bufferedOne(result_buffer, if (try parseExplicitBase(a, args[0], base)) |n| .{ .number = n } else .nil);
}
fn baseSelect(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    if (args[0] == .string and std.mem.eql(u8, args[0].string, "#")) return bufferedOne(result_buffer, .{ .number = @floatFromInt(args.len - 1) });
    var idx = try integer(args[0]);
    const n: @TypeOf(idx) = @intCast(args.len - 1);
    if (idx == 0 or idx < -n) {
        ctx.last_error = .{ .string = "bad argument #1 to 'select' (index out of range)" };
        return error.LuaRaised;
    }
    if (idx < 0) idx = n + idx + 1;
    if (idx > n) return &.{};
    const out = try rt.returnBuffer(result_buffer, @intCast(n - idx + 1));
    copyBufferedValues(out, args[@intCast(idx)..]);
    return out;
}
fn baseUnpack(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const i: i64 = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1;
    const j: i64 = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else @intCast(t.rawLen());
    if (j < i) return &.{};
    const out = try rt.returnBuffer(result_buffer, @intCast(j - i + 1));
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
fn iteratorTripleFromCall(runtime: *rt.Context, callable: Value, object: Value, result_buffer: ?[]Value) ![]const Value {
    const values = try runtime.callValue(callable, &.{object});
    defer rt.freeResults(values);
    const out = try rt.returnBuffer(result_buffer, 3);
    for (out, 0..) |*slot, i| slot.* = if (i < values.len) values[i] else .nil;
    return out;
}

fn iterationMetamethod(object: Value, name: []const u8) ?Value {
    if (object != .table) return null;
    const metatable = object.table.metatable orelse return null;
    return metatable.rawGet(.{ .string = name });
}

fn basePairs(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const object = args[0];
    if (iterationMetamethod(object, "__pairs")) |method|
        return iteratorTripleFromCall(ctx, method, object, result_buffer);
    if (ctx.builtin_next != .callable) return error.MissingBuiltinNext;
    const out = try rt.returnBuffer(result_buffer, 3);
    rt.storeReturn(out, 0, ctx.builtin_next);
    rt.storeReturn(out, 1, object);
    rt.storeReturn(out, 2, .nil);
    return out;
}
fn ipairsIter(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len < 2 or args[0] != .table) return error.TableExpected;
    const i = (try integer(args[1])) + 1;
    const v = args[0].table.rawGetNumber(@floatFromInt(i)) orelse return bufferedOne(result_buffer, .nil);
    return bufferedTwo(result_buffer, .{ .number = @floatFromInt(i) }, v);
}
fn baseIpairs(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const object = args[0];
    if (iterationMetamethod(object, "__ipairs")) |method|
        return iteratorTripleFromCall(ctx, method, object, result_buffer);
    const iter = try ctx.newNativeBuffered(null, ipairsIter);
    const out = try rt.returnBuffer(result_buffer, 3);
    rt.storeReturn(out, 0, iter);
    rt.storeReturn(out, 1, object);
    rt.storeReturn(out, 2, .{ .number = 0 });
    return out;
}
fn protectedPairsProbe(_: ?*anyopaque, ctx: *rt.Context, _: []const Value) ![]const Value {
    const state = try ctx.newTable();
    try state.rawSet(ctx.allocator, .{ .string = "y" }, .{ .number = 2 });
    const out = try std.heap.smp_allocator.alloc(Value, 3);
    out[0] = ctx.getGlobal(global_abi.id("next"));
    out[1] = .{ .table = state };
    out[2] = .nil;
    return out;
}

fn protectedErrorValue(ctx: *rt.Context, err: anyerror) !Value {
    if (ctx.last_error_present or ctx.last_error != .nil) return ctx.last_error;
    if (ctx.aotErrorName()) |name| return .{ .string = try ctx.allocator.dupe(u8, name) };
    return .{ .string = @errorName(err) };
}

fn basePcall(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    // A later evaluation could catch allocation failure even if this one did
    // not. Protected calls therefore exclude dynamic cross-page admission.
    rt.markLoadDataEffect();
    if (args.len == 0) return error.MissingArgument;
    const saved_error = ctx.last_error;
    const saved_error_present = ctx.last_error_present;
    const saved_aot_error_name = ctx.aot_error_name;
    defer {
        ctx.last_error = saved_error;
        ctx.last_error_present = saved_error_present;
        ctx.aot_error_name = saved_aot_error_name;
    }
    ctx.clearLuaError();
    ctx.clearAotErrorName();
    const result = ctx.callValue(args[0], args[1..]) catch |err| {
        // A protected error can expose allocator pressure (including OOM) as
        // Lua data. Such a result cannot be shared between page evaluations.
        rt.markLoadDataEffect();
        const out = try rt.returnBuffer(result_buffer, 2);
        const error_value = try protectedErrorValue(ctx, err);
        rt.storeReturn(out, 0, .{ .boolean = false });
        rt.storeReturn(out, 1, error_value);
        return out;
    };
    defer rt.freeResults(result);
    const out = try rt.returnBuffer(result_buffer, result.len + 1);
    rt.storeReturn(out, 0, .{ .boolean = true });
    rt.copyReturnTail(out, 1, result);
    return out;
}

fn baseXpcall(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    rt.markLoadDataEffect();
    if (args.len < 2) return error.MissingArgument;
    const saved_error = ctx.last_error;
    const saved_error_present = ctx.last_error_present;
    const saved_aot_error_name = ctx.aot_error_name;
    defer {
        ctx.last_error = saved_error;
        ctx.last_error_present = saved_error_present;
        ctx.aot_error_name = saved_aot_error_name;
    }
    ctx.clearLuaError();
    ctx.clearAotErrorName();
    const result = ctx.callValue(args[0], &.{}) catch |err| {
        rt.markLoadDataEffect();
        const original_error = try protectedErrorValue(ctx, err);
        ctx.clearLuaError();
        ctx.clearAotErrorName();
        const handled = ctx.callValue(args[1], &.{original_error}) catch {
            rt.markLoadDataEffect();
            const out = try bufferedTwo(result_buffer, .{ .boolean = false }, .{ .string = "error in error handling" });
            return out;
        };
        defer rt.freeResults(handled);
        const out = try bufferedTwo(result_buffer, .{ .boolean = false }, if (handled.len == 0) .nil else handled[0]);
        return out;
    };
    defer rt.freeResults(result);
    const out = try rt.returnBuffer(result_buffer, result.len + 1);
    rt.storeReturn(out, 0, .{ .boolean = true });
    rt.copyReturnTail(out, 1, result);
    return out;
}

fn installDynamicBase(runtime: *rt.Context) !void {
    const global = runtime.global_table orelse return;
    try global.rawSet(runtime.allocator, .{ .string = "xpcall" }, try runtime.newNativeBuffered(null, baseXpcall));
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
fn tableRemove(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const t = args[0].table;
    const n: i64 = @intCast(t.rawLen());
    if (n == 0) return bufferedOne(result_buffer, .nil);
    const pos = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else n;
    if (pos < 1 or pos > n) return bufferedOne(result_buffer, .nil);
    const removed = t.rawGet(.{ .number = @floatFromInt(pos) }) orelse .nil;
    var i = pos;
    while (i < n) : (i += 1) try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(i) }, t.rawGet(.{ .number = @floatFromInt(i + 1) }) orelse .nil);
    try t.rawSet(ctx.allocator, .{ .number = @floatFromInt(n) }, .nil);
    return bufferedOne(result_buffer, removed);
}
fn tableConcat(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
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
    return bufferedOne(result_buffer, .{ .string = out });
}
fn tableMaxn(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    var max: f64 = 0;
    var it = args[0].table.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* == .number and e.key_ptr.number > max) max = e.key_ptr.number;
    }
    return bufferedOne(result_buffer, .{ .number = max });
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

fn stringLen(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    return bufferedOne(result_buffer, .{ .number = @floatFromInt((try str(a, args[0])).len) });
}
fn normIndex(i: i64, n: i64) i64 {
    return if (i < 0) n + i + 1 else i;
}
fn stringSub(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const n: i64 = @intCast(s.len);
    var i = normIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, n);
    var j = normIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else -1, n);
    i = @max(@as(i64, 1), i);
    j = @min(n, j);
    if (i > j or i > n) return bufferedOne(result_buffer, .{ .string = "" });
    return bufferedOne(result_buffer, .{ .string = s[@intCast(i - 1)..@intCast(j)] });
}
fn stringLower(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return bufferedOne(result_buffer, .{ .string = out });
}
fn stringUpper(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return bufferedOne(result_buffer, .{ .string = out });
}
fn stringReverse(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[s.len - 1 - i] = c;
    return bufferedOne(result_buffer, .{ .string = out });
}
fn stringRep(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const n = try integer(args[1]);
    if (n <= 0) return bufferedOne(result_buffer, .{ .string = "" });
    const total = try std.math.mul(usize, s.len, @intCast(n));
    const out = try a.alloc(u8, total);
    var p: usize = 0;
    for (0..@intCast(n)) |_| {
        @memcpy(out[p .. p + s.len], s);
        p += s.len;
    }
    return bufferedOne(result_buffer, .{ .string = out });
}
fn stringChar(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const out = try a.alloc(u8, args.len);
    for (args, 0..) |v, i| {
        const x = try integer(v);
        if (x < 0 or x > 255) return error.ByteOutOfRange;
        out[i] = @intCast(x);
    }
    return bufferedOne(result_buffer, .{ .string = out });
}
fn stringByte(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    const s = try str(a, args[0]);
    const n: i64 = @intCast(s.len);
    var i = normIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, n);
    var j = normIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else i, n);
    i = @max(@as(i64, 1), i);
    j = @min(n, j);
    if (i > j) return &.{};
    const out = try rt.returnBuffer(result_buffer, @intCast(j - i + 1));
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

fn captureResultsBuffered(source: []const u8, m: pattern.Match, result_buffer: ?[]Value) ![]const Value {
    if (m.capture_count == 0) return bufferedOne(result_buffer, .{ .string = source[m.start..m.end] });
    const out = try rt.returnBuffer(result_buffer, m.capture_count);
    for (out, 0..) |*value, i| value.* = try captureValue(source, m.captures[i]);
    return out;
}

fn findStart(len: usize, raw: i64) ?usize {
    const n: i64 = @intCast(len);
    var i = if (raw < 0) n + raw + 1 else raw;
    if (i < 1) i = 1;
    if (i > n + 1) return null;
    return @intCast(i - 1);
}

fn stringFind(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2) return error.MissingArgument;
    const source = try str(a, args[0]);
    const needle = try str(a, args[1]);
    const init = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const start = findStart(source.len, init) orelse return bufferedOne(result_buffer, .nil);
    if (args.len > 3 and args[3].truthy()) {
        const rel = std.mem.indexOf(u8, source[start..], needle) orelse return bufferedOne(result_buffer, .nil);
        const first = start + rel;
        return bufferedTwo(result_buffer, .{ .number = @floatFromInt(first + 1) }, .{ .number = @floatFromInt(first + needle.len) });
    }
    var m: pattern.Match = undefined;
    if (!(try pattern.findIntoStart(source, needle, init, &m))) return bufferedOne(result_buffer, .nil);
    const out = try rt.returnBuffer(result_buffer, 2 + m.capture_count);
    rt.storeReturn(out, 0, .{ .number = @floatFromInt(m.start + 1) });
    rt.storeReturn(out, 1, .{ .number = @floatFromInt(m.end) });
    for (out[@min(out.len, 2)..], 0..) |*value, i| value.* = try captureValue(source, m.captures[i]);
    return out;
}

fn stringMatch(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2) return error.MissingArgument;
    const source = try str(a, args[0]);
    const pat = try str(a, args[1]);
    const init = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    var m: pattern.Match = undefined;
    if (!(try pattern.findIntoStart(source, pat, init, &m))) return bufferedOne(result_buffer, .nil);
    return captureResultsBuffered(source, m, result_buffer);
}
const GmatchCtx = struct { iterator: pattern.Iterator };
fn gmatchNext(ctx_raw: ?*anyopaque, _: *rt.Context, _: []const Value, result_buffer: ?[]Value) ![]const Value {
    const state: *GmatchCtx = @ptrCast(@alignCast(ctx_raw.?));
    const m = try state.iterator.next() orelse return &.{};
    return captureResultsBuffered(state.iterator.source, m, result_buffer);
}

fn stringGmatch(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 2) return error.MissingArgument;
    const state = try ctx.allocator.create(GmatchCtx);
    state.* = .{ .iterator = .{ .source = try str(a, args[0]), .pattern = try str(a, args[1]) } };
    return bufferedOne(result_buffer, try ctx.newNativeBuffered(state, gmatchNext));
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

fn appendReplacement(out: *std.ArrayList(u8), a: std.mem.Allocator, repl: []const u8, source: []const u8, m: pattern.Match) !void {
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
}

fn replacementArgs(a: std.mem.Allocator, source: []const u8, m: pattern.Match) ![]const Value {
    return captureResults(a, source, m);
}

fn replacementValue(runtime: *rt.Context, replacement: Value, source: []const u8, m: pattern.Match, a: std.mem.Allocator) !?[]const u8 {
    const original = source[m.start..m.end];
    const value: Value = switch (replacement) {
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

fn stringFormat(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    return bufferedOne(result_buffer, .{ .string = try lua_format.format(a, args) });
}

fn stringGsub(_: ?*anyopaque, ctx: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const a = ctx.allocator;
    if (args.len < 3) return error.MissingArgument;
    const runtime = ctx;
    const source = try str(a, args[0]);
    const pat = try str(a, args[1]);
    var replacement = args[2];
    if (replacement == .number) {
        const number = replacement.number;
        replacement = .{ .string = try rt.numberToString(a, number) };
    }
    if (replacement != .string and replacement != .table and replacement != .callable)
        return error.InvalidReplacement;
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
        var m: pattern.Match = undefined;
        if (!(try pattern.findIntoStart(source, pat, @intCast(search + 1), &m))) break;
        if (m.start < cursor) return error.BadPatternProgress;
        try out.appendSlice(a, source[cursor..m.start]);
        if (replacement == .string) {
            try appendReplacement(&out, a, replacement.string, source, m);
        } else {
            const replacement_text = try replacementValue(runtime, replacement, source, m, a);
            if (replacement_text) |text|
                try out.appendSlice(a, text)
            else
                try out.appendSlice(a, source[m.start..m.end]);
        }
        count += 1;
        cursor = m.end;
        if (anchored) break;
        if (m.end > m.start) search = m.end else if (m.end < source.len) search = m.end + 1 else search = source.len + 1;
    }
    // Lua strings are immutable and the source bytes outlive this result.
    // A miss (or a zero replacement limit) can reuse the original value.
    if (count == 0) return bufferedTwo(result_buffer, .{ .string = source }, .{ .number = 0 });
    try out.appendSlice(a, source[cursor..]);
    const rendered = try out.toOwnedSlice(a);
    return bufferedTwo(result_buffer, .{ .string = rendered }, .{ .number = @floatFromInt(count) });
}

const MathOp = enum { abs, ceil, floor, sqrt, exp, log, log10, sin, cos, tan, asin, acos, atan, deg, rad };
fn mathUnary(raw: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
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
    return bufferedOne(result_buffer, .{ .number = y });
}
fn mathMin(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    var x = try num(args[0]);
    for (args[1..]) |v| x = @min(x, try num(v));
    return bufferedOne(result_buffer, .{ .number = x });
}
fn mathMax(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    if (args.len == 0) return error.MissingArgument;
    var x = try num(args[0]);
    for (args[1..]) |v| x = @max(x, try num(v));
    return bufferedOne(result_buffer, .{ .number = x });
}
fn mathPow(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    return bufferedOne(result_buffer, .{ .number = std.math.pow(f64, try num(args[0]), try num(args[1])) });
}
fn mathFmod(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const x = try num(args[0]);
    const y = try num(args[1]);
    return bufferedOne(result_buffer, .{ .number = @rem(x, y) });
}
fn mathModf(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    const x = try num(args[0]);
    const ip = @trunc(x);
    var fp: f64 = if (std.math.isInf(x)) 0.0 else x - ip;
    if (fp == 0 and std.math.signbit(x)) fp = -0.0;
    return bufferedTwo(result_buffer, .{ .number = ip }, .{ .number = fp });
}

fn debugTraceback(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    return bufferedOne(result_buffer, if (args.len != 0 and args[0] == .string) args[0] else .{ .string = "" });
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
fn mathRandomCall(raw: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
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
    return bufferedOne(result_buffer, .{ .number = result });
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
    try math.rawSetNativeField(.math, "random", try runtime.newNativeBuffered(state, mathRandomCall));
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
    try t.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNativeBuffered(ctx, mathUnary));
}

fn bit32Value(value: Value) !u32 {
    const number = try num(value);
    if (!std.math.isFinite(number)) return error.NumberExpected;
    const modulus: f64 = 4294967296.0;
    const floored = @floor(number);
    const wrapped = floored - @floor(floored / modulus) * modulus;
    return @intFromFloat(wrapped);
}

fn bit32Band(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    var result: u32 = std.math.maxInt(u32);
    for (args) |arg| result &= try bit32Value(arg);
    return bufferedOne(result_buffer, .{ .number = @floatFromInt(result) });
}

fn bit32Bor(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
    var result: u32 = 0;
    for (args) |arg| result |= try bit32Value(arg);
    return bufferedOne(result_buffer, .{ .number = @floatFromInt(result) });
}

fn makeBit32(runtime: *rt.Context) !*rt.Table {
    const bit32 = try runtime.newTable();
    try setNativeBuffered(runtime, bit32, "band", bit32Band);
    try setNativeBuffered(runtime, bit32, "bor", bit32Bor);
    return bit32;
}

fn raiseLibraryUtilTypeError(ctx: *rt.Context, name: []const u8, arg_index: i64, expected: []const u8, actual: []const u8) ![]const Value {
    ctx.last_error = .{ .string = try std.fmt.allocPrint(
        ctx.allocator,
        "bad argument #{d} to '{s}' ({s} expected, got {s})",
        .{ arg_index, name, expected, actual },
    ) };
    return error.LuaRaised;
}

fn libraryUtilCheckType(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 4) return error.MissingArgument;
    const name = try str(ctx.allocator, args[0]);
    const arg_index = try integer(args[1]);
    const expected = try str(ctx.allocator, args[3]);
    if (args[2] == .nil and args.len > 4 and args[4].truthy()) return &.{};
    const actual = valueTypeName(args[2]);
    if (std.mem.eql(u8, actual, expected)) return &.{};
    return raiseLibraryUtilTypeError(ctx, name, arg_index, expected, actual);
}

fn libraryUtilCheckTypeMulti(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 4) return error.MissingArgument;
    if (args[3] != .table) return error.TableExpected;
    const name = try str(ctx.allocator, args[0]);
    const arg_index = try integer(args[1]);
    const actual = valueTypeName(args[2]);
    const expected_types = args[3].table;

    var type_list: std.ArrayList(u8) = .empty;
    defer type_list.deinit(ctx.allocator);
    var expected_count: usize = 0;
    var index: usize = 1;
    while (expected_types.rawGetNumber(@floatFromInt(index))) |value| : (index += 1) {
        if (value == .nil) break;
        const expected = try str(ctx.allocator, value);
        if (std.mem.eql(u8, actual, expected)) return &.{};
        if (expected_count != 0) try type_list.appendSlice(ctx.allocator, ", ");
        try type_list.appendSlice(ctx.allocator, expected);
        expected_count += 1;
    }
    if (expected_count == 0) return error.MissingExpectedType;

    if (expected_count > 1) {
        var split = std.mem.lastIndexOf(u8, type_list.items, ", ").?;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(ctx.allocator);
        try joined.appendSlice(ctx.allocator, type_list.items[0..split]);
        try joined.appendSlice(ctx.allocator, " or ");
        split += 2;
        try joined.appendSlice(ctx.allocator, type_list.items[split..]);
        return raiseLibraryUtilTypeError(ctx, name, arg_index, joined.items, actual);
    }
    return raiseLibraryUtilTypeError(ctx, name, arg_index, type_list.items, actual);
}

fn makeLibraryUtil(runtime: *rt.Context) !*rt.Table {
    const library_util = try runtime.newTable();
    try setNative(runtime, library_util, "checkType", libraryUtilCheckType);
    try setNative(runtime, library_util, "checkTypeMulti", libraryUtilCheckTypeMulti);
    return library_util;
}

fn registerLoadedGlobal(runtime: *rt.Context, loaded: *rt.Table, comptime name: []const u8) !void {
    const value = runtime.getGlobal(global_abi.id(name));
    if (value != .nil) try loaded.rawSet(runtime.allocator, .{ .string = name }, value);
}

fn registerStandardPackageLoaded(runtime: *rt.Context) !void {
    const loaded = runtime.package_loaded orelse return error.MissingPackageLoaded;
    inline for (.{ "_G", "table", "string", "math", "debug" }) |name|
        try registerLoadedGlobal(runtime, loaded, name);
}

fn installPackage(runtime: *rt.Context) !void {
    const package = try runtime.newTable();
    const loaded = try runtime.newTable();
    const loaders = try runtime.newTable();
    try package.rawSet(runtime.allocator, .{ .string = "loaded" }, .{ .table = loaded });
    try package.rawSet(runtime.allocator, .{ .string = "loaders" }, .{ .table = loaders });
    try loaded.rawSet(runtime.allocator, .{ .string = "bit32" }, .{ .table = try makeBit32(runtime) });
    try loaded.rawSet(runtime.allocator, .{ .string = "libraryUtil" }, .{ .table = try makeLibraryUtil(runtime) });
    const loader_state = try runtime.allocator.create(MainModuleLoaderCtx);
    loader_state.* = .{ .cache = try runtime.newTable() };
    try loaders.rawSet(runtime.allocator, .{ .number = 2 }, try runtime.newNativeBuffered(loader_state, mainModuleLoader));
    runtime.package_loaded = loaded;
    try runtime.setGlobal(global_abi.id("package"), .{ .table = package });
    try loaded.rawSet(runtime.allocator, .{ .string = "package" }, .{ .table = package });
    try registerStandardPackageLoaded(runtime);
}

pub fn install(runtime: *rt.Context) !void {
    try setGlobalNativeBuffered(runtime, "type", baseType);
    try setGlobalNativeBuffered(runtime, "assert", baseAssert);
    try setGlobalNative(runtime, "error", baseError);
    try setGlobalNativeBuffered(runtime, "rawequal", baseRawEqual);
    try setGlobalNativeBuffered(runtime, "rawget", baseRawGet);
    try setGlobalNativeBuffered(runtime, "rawset", baseRawSet);
    try setGlobalNativeBuffered(runtime, "getmetatable", baseGetMetatable);
    try setGlobalNativeBuffered(runtime, "setmetatable", baseSetMetatable);
    try setGlobalNativeBuffered(runtime, "tostring", baseToString);
    try setGlobalNativeBuffered(runtime, "tonumber", baseToNumber);
    try setGlobalNativeBuffered(runtime, "select", baseSelect);
    try setGlobalNativeBuffered(runtime, "unpack", baseUnpack);
    runtime.builtin_next = try runtime.newNativeBuffered(null, baseNext);
    try runtime.setGlobal(global_abi.id("next"), runtime.builtin_next);
    try setGlobalNativeBuffered(runtime, "pairs", basePairs);
    try setGlobalNativeBuffered(runtime, "ipairs", baseIpairs);
    try setGlobalNativeBuffered(runtime, "pcall", basePcall);
    try installDynamicBase(runtime);

    try installPackage(runtime);
    try setGlobalNativeBuffered(runtime, "require", baseRequire);

    const table = try runtime.newNativeNamespace(.table);
    try setNative(runtime, table, "insert", tableInsert);
    try setNativeBuffered(runtime, table, "remove", tableRemove);
    try setNativeBuffered(runtime, table, "concat", tableConcat);
    try setNative(runtime, table, "sort", tableSort);
    try setNativeBuffered(runtime, table, "maxn", tableMaxn);
    try setNativeBuffered(runtime, table, "getn", struct {
        fn f(_: ?*anyopaque, _: *rt.Context, args: []const Value, result_buffer: ?[]Value) ![]const Value {
            if (args.len == 0 or args[0] != .table) return error.TableExpected;
            return bufferedOne(result_buffer, .{ .number = @floatFromInt(args[0].table.rawLen()) });
        }
    }.f);
    try runtime.setGlobal(global_abi.id("table"), .{ .table = table });
    const string = try runtime.newNativeNamespace(.string);
    try setNativeBuffered(runtime, string, "len", stringLen);
    try setNativeBuffered(runtime, string, "sub", stringSub);
    try setNativeBuffered(runtime, string, "lower", stringLower);
    try setNativeBuffered(runtime, string, "upper", stringUpper);
    try setNativeBuffered(runtime, string, "reverse", stringReverse);
    try setNativeBuffered(runtime, string, "rep", stringRep);
    try setNativeBuffered(runtime, string, "char", stringChar);
    try setNativeBuffered(runtime, string, "byte", stringByte);
    try setNativeBuffered(runtime, string, "find", stringFind);
    try setNativeBuffered(runtime, string, "match", stringMatch);
    try setNativeBuffered(runtime, string, "gmatch", stringGmatch);
    try setNativeBuffered(runtime, string, "gsub", stringGsub);
    try setNativeBuffered(runtime, string, "format", stringFormat);
    try runtime.setGlobal(global_abi.id("string"), .{ .table = string });
    const smt = try runtime.newTable();
    try smt.rawSet(runtime.allocator, .{ .string = "__index" }, .{ .table = string });
    runtime.string_metatable = smt;
    const math = try runtime.newNativeNamespace(.math);
    inline for (.{ .{ "abs", MathOp.abs }, .{ "ceil", .ceil }, .{ "floor", .floor }, .{ "sqrt", .sqrt }, .{ "exp", .exp }, .{ "log", .log }, .{ "log10", .log10 }, .{ "sin", .sin }, .{ "cos", .cos }, .{ "tan", .tan }, .{ "asin", .asin }, .{ "acos", .acos }, .{ "atan", .atan }, .{ "deg", .deg }, .{ "rad", .rad } }) |x| try addMath(runtime, math, x[0], x[1]);
    try setNativeBuffered(runtime, math, "min", mathMin);
    try setNativeBuffered(runtime, math, "max", mathMax);
    try setNativeBuffered(runtime, math, "pow", mathPow);
    try setNativeBuffered(runtime, math, "fmod", mathFmod);
    try setNativeBuffered(runtime, math, "mod", mathFmod);
    try setNativeBuffered(runtime, math, "modf", mathModf);
    try math.rawSet(runtime.allocator, .{ .string = "pi" }, .{ .number = std.math.pi });
    try math.rawSet(runtime.allocator, .{ .string = "huge" }, .{ .number = std.math.inf(f64) });
    try installMathRandom(runtime, math);
    try runtime.setGlobal(global_abi.id("math"), .{ .table = math });
    const debug = try runtime.newNativeNamespace(.debug);
    try setNativeBuffered(runtime, debug, "traceback", debugTraceback);
    try runtime.setGlobal(global_abi.id("debug"), .{ .table = debug });
    try registerStandardPackageLoaded(runtime);
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
        // Instantiation writes the slot array directly, outside Context.setGlobal.
        if (runtime.globals.ptr == runtime.root_globals.ptr) runtime.root_tail_cache_valid.* = false;
        @memcpy(runtime.globals[0..self.base.globals.len], self.base.globals);
        runtime.next_identity = self.base.next_identity;
        runtime.builtin_next = self.base.builtin_next;
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

    const debug = ctx.getGlobal(global_abi.id("debug"));
    try std.testing.expect(debug == .table);
    try std.testing.expect((try ctx.getIndex(debug, .{ .string = "getmetatable" })) == .nil);
    try std.testing.expect((try ctx.getIndex(debug, .{ .string = "getinfo" })) == .nil);
    try std.testing.expect((try ctx.getIndex(debug, .{ .string = "traceback" })) == .callable);
    try std.testing.expectEqual(@as(usize, 0), debug.table.map.count());

    const package = ctx.getGlobal(global_abi.id("package"));
    try std.testing.expect(package == .table);
    const loaded = try ctx.getIndex(package, .{ .string = "loaded" });
    try std.testing.expect(loaded == .table and ctx.package_loaded == loaded.table);
    const require = ctx.getGlobal(global_abi.id("require"));
    try std.testing.expect(require == .callable);
    inline for (.{ "table", "string", "math", "debug", "package", "_G" }) |name| {
        const required = try ctx.callValue(require, &.{.{ .string = name }});
        defer rt.freeResults(required);
        try std.testing.expect(required.len == 1 and required[0] == .table);
    }
    const strict = try ctx.callValue(require, &.{.{ .string = "strict" }});
    defer rt.freeResults(strict);
    try std.testing.expect(strict.len == 1 and strict[0] == .boolean and strict[0].boolean);
    try std.testing.expect(ctx.global_table.?.metatable != null);
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
    const library_util_result = try ctx.callValue(require, &.{.{ .string = "libraryUtil" }});
    defer rt.freeResults(library_util_result);
    try std.testing.expect(library_util_result.len == 1 and library_util_result[0] == .table);
    const check_type = try ctx.getIndex(library_util_result[0], .{ .string = "checkType" });
    const check_type_ok = try ctx.callValue(check_type, &.{ .{ .string = "demo" }, .{ .number = 1 }, .{ .string = "ok" }, .{ .string = "string" } });
    defer rt.freeResults(check_type_ok);
    try std.testing.expectEqual(@as(usize, 0), check_type_ok.len);
    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const check_type_bad = try ctx.callValue(pcall, &.{ check_type, .{ .string = "demo" }, .{ .number = 2 }, .{ .number = 7 }, .{ .string = "string" } });
    defer rt.freeResults(check_type_bad);
    try std.testing.expect(!check_type_bad[0].boolean);
    try std.testing.expectEqualStrings("bad argument #2 to 'demo' (string expected, got number)", check_type_bad[1].string);
    const check_nil = try ctx.callValue(check_type, &.{ .{ .string = "demo" }, .{ .number = 3 }, .nil, .{ .string = "table" }, .{ .boolean = true } });
    defer rt.freeResults(check_nil);
    try std.testing.expectEqual(@as(usize, 0), check_nil.len);

    const expected_types = try ctx.newTable();
    try expected_types.rawSet(ctx.allocator, .{ .number = 1 }, .{ .string = "table" });
    try expected_types.rawSet(ctx.allocator, .{ .number = 2 }, .{ .string = "number" });
    try expected_types.rawSet(ctx.allocator, .{ .number = 3 }, .{ .string = "string" });
    const check_type_multi = try ctx.getIndex(library_util_result[0], .{ .string = "checkTypeMulti" });
    const multi_ok = try ctx.callValue(check_type_multi, &.{ .{ .string = "demo" }, .{ .number = 1 }, .{ .number = 7 }, .{ .table = expected_types } });
    defer rt.freeResults(multi_ok);
    try std.testing.expectEqual(@as(usize, 0), multi_ok.len);
    const multi_bad = try ctx.callValue(pcall, &.{ check_type_multi, .{ .string = "demo" }, .{ .number = 1 }, .{ .boolean = true }, .{ .table = expected_types } });
    defer rt.freeResults(multi_bad);
    try std.testing.expect(!multi_bad[0].boolean);
    try std.testing.expectEqualStrings("bad argument #1 to 'demo' (table, number or string expected, got boolean)", multi_bad[1].string);
    try std.testing.expectError(error.AotCallFailed, ctx.callValue(require, &.{.{ .string = "Module:Missing" }}));
    try std.testing.expectEqualStrings("ModuleNotFound", ctx.aotErrorName().?);
    ctx.clearAotErrorName();

    const tonumber_fn = ctx.getGlobal(global_abi.id("tonumber"));
    const spaced_number = try ctx.callValue(tonumber_fn, &.{.{ .string = " \t1\r\n" }});
    defer rt.freeResults(spaced_number);
    try std.testing.expectEqual(@as(f64, 1), spaced_number[0].number);
    const default_hex = try ctx.callValue(tonumber_fn, &.{.{ .string = "0x10" }});
    defer rt.freeResults(default_hex);
    try std.testing.expectEqual(@as(f64, 16), default_hex[0].number);
    const decimal_hex = try ctx.callValue(tonumber_fn, &.{ .{ .string = "0x10" }, .{ .number = 10 } });
    defer rt.freeResults(decimal_hex);
    try std.testing.expectEqual(@as(f64, 16), decimal_hex[0].number);
    const explicit_hex = try ctx.callValue(tonumber_fn, &.{ .{ .string = "+0xFF" }, .{ .number = 16 } });
    defer rt.freeResults(explicit_hex);
    try std.testing.expectEqual(@as(f64, 255), explicit_hex[0].number);
    const numeric_hex = try ctx.callValue(tonumber_fn, &.{ .{ .number = 10 }, .{ .number = 16 } });
    defer rt.freeResults(numeric_hex);
    try std.testing.expectEqual(@as(f64, 16), numeric_hex[0].number);
    const wrapped_hex = try ctx.callValue(tonumber_fn, &.{ .{ .string = "-FFFFFFFFFFFFFFFF" }, .{ .number = 16 } });
    defer rt.freeResults(wrapped_hex);
    try std.testing.expectEqual(@as(f64, 1), wrapped_hex[0].number);
    const saturated_hex = try ctx.callValue(tonumber_fn, &.{ .{ .string = "10000000000000000" }, .{ .number = 16 } });
    defer rt.freeResults(saturated_hex);
    try std.testing.expectEqual(@as(f64, @floatFromInt(std.math.maxInt(u64))), saturated_hex[0].number);
    const base34 = try ctx.callValue(tonumber_fn, &.{ .{ .string = "0xFF" }, .{ .number = 34 } });
    defer rt.freeResults(base34);
    try std.testing.expectEqual(@as(f64, 38673), base34[0].number);
    const invalid_hex = try ctx.callValue(tonumber_fn, &.{ .{ .string = "F.F" }, .{ .number = 16 } });
    defer rt.freeResults(invalid_hex);
    try std.testing.expect(invalid_hex[0] == .nil);
    try std.testing.expectError(error.AotCallFailed, ctx.callValue(tonumber_fn, &.{ .{ .boolean = true }, .{ .number = 16 } }));
    try std.testing.expectEqualStrings("StringExpected", ctx.aotErrorName().?);
    ctx.clearAotErrorName();

    const string = ctx.getGlobal(global_abi.id("string"));
    const sub = try callField(&ctx, string, "sub", &.{ .{ .string = "abcdef" }, .{ .number = 2 }, .{ .number = -2 } });
    defer rt.freeResults(sub);
    try std.testing.expectEqualStrings("bcde", sub[0].string);
    const numeric_gsub = try callField(&ctx, string, "gsub", &.{
        .{ .string = "a\x01b" },
        .{ .string = "\x01" },
        .{ .number = 123 },
    });
    defer rt.freeResults(numeric_gsub);
    try std.testing.expectEqualStrings("a123b", numeric_gsub[0].string);
    try std.testing.expectEqual(@as(f64, 1), numeric_gsub[1].number);

    const select_fn = ctx.getGlobal(global_abi.id("select"));
    const tail = try ctx.callValue(select_fn, &.{ .{ .number = -2 }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } });
    defer rt.freeResults(tail);
    try std.testing.expectEqual(@as(usize, 2), tail.len);
    try std.testing.expectEqualStrings("b", tail[0].string);
    try std.testing.expectEqualStrings("c", tail[1].string);
    const after_end = try ctx.callValue(select_fn, &.{ .{ .number = 4 }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } });
    defer rt.freeResults(after_end);
    try std.testing.expectEqual(@as(usize, 0), after_end.len);
    inline for ([_]f64{ 0, -4 }) |index| {
        const bad_select = try ctx.callValue(pcall, &.{ select_fn, .{ .number = index }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } });
        defer rt.freeResults(bad_select);
        try std.testing.expect(!bad_select[0].boolean);
        try std.testing.expectEqualStrings("bad argument #1 to 'select' (index out of range)", bad_select[1].string);
    }

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

    const negative_integer = try callField(&ctx, math, "modf", &.{.{ .number = -2 }});
    defer rt.freeResults(negative_integer);
    try std.testing.expectEqual(@as(f64, -2), negative_integer[0].number);
    try std.testing.expect(negative_integer[1].number == 0 and std.math.signbit(negative_integer[1].number));
    const positive_infinity = try callField(&ctx, math, "modf", &.{.{ .number = std.math.inf(f64) }});
    defer rt.freeResults(positive_infinity);
    try std.testing.expect(std.math.isPositiveInf(positive_infinity[0].number));
    try std.testing.expect(positive_infinity[1].number == 0 and !std.math.signbit(positive_infinity[1].number));
    const negative_infinity = try callField(&ctx, math, "modf", &.{.{ .number = -std.math.inf(f64) }});
    defer rt.freeResults(negative_infinity);
    try std.testing.expect(std.math.isNegativeInf(negative_infinity[0].number));
    try std.testing.expect(negative_infinity[1].number == 0 and std.math.signbit(negative_infinity[1].number));
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

test "AOT pairs and ipairs use hidden real metamethods including false call errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);

    const protected = try ctx.newTable();
    const protected_mt = try ctx.newTable();
    try protected_mt.rawSet(ctx.allocator, .{ .string = "__metatable" }, .{ .string = "hidden" });
    try protected_mt.rawSet(ctx.allocator, .{ .string = "__pairs" }, try ctx.newNative(null, protectedPairsProbe));
    protected.metatable = protected_mt;
    const triple = try basePairs(null, &ctx, &.{.{ .table = protected }}, null);
    defer rt.freeResults(triple);
    const first = try ctx.callValue(triple[0], triple[1..3]);
    defer rt.freeResults(first);
    try std.testing.expectEqualStrings("y", first[0].string);
    try std.testing.expectEqual(@as(f64, 2), first[1].number);
    const exposed = try baseGetMetatable(null, &ctx, &.{.{ .table = protected }}, null);
    defer rt.freeResults(exposed);
    try std.testing.expectEqualStrings("hidden", exposed[0].string);

    const bad_pairs = try ctx.newTable();
    const bad_pairs_mt = try ctx.newTable();
    try bad_pairs_mt.rawSet(ctx.allocator, .{ .string = "__pairs" }, .{ .boolean = false });
    bad_pairs.metatable = bad_pairs_mt;
    try std.testing.expectError(error.NotCallable, basePairs(null, &ctx, &.{.{ .table = bad_pairs }}, null));

    const bad_ipairs = try ctx.newTable();
    const bad_ipairs_mt = try ctx.newTable();
    try bad_ipairs_mt.rawSet(ctx.allocator, .{ .string = "__ipairs" }, .{ .boolean = false });
    bad_ipairs.metatable = bad_ipairs_mt;
    try std.testing.expectError(error.NotCallable, baseIpairs(null, &ctx, &.{.{ .table = bad_ipairs }}, null));
}

test "AOT pairs keeps builtin next after global next is overwritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);

    const builtin_next = ctx.builtin_next;
    try std.testing.expect(builtin_next == .callable);
    try ctx.setGlobal(global_abi.id("next"), .{ .string = "poison" });

    const values = try ctx.newTable();
    try values.rawSet(ctx.allocator, .{ .string = "x" }, .{ .number = 1 });
    const triple = try basePairs(null, &ctx, &.{.{ .table = values }}, null);
    defer rt.freeResults(triple);
    try std.testing.expect(rt.rawEqual(builtin_next, triple[0]));

    const first = try ctx.callValue(triple[0], triple[1..3]);
    defer rt.freeResults(first);
    try std.testing.expectEqualStrings("x", first[0].string);
    try std.testing.expectEqual(@as(f64, 1), first[1].number);
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

test "stdlib template callable owners outlive children and random hosts stay isolated" {
    var template = try Template.init();
    defer template.deinit();
    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second = try rt.Context.init(second_arena.allocator(), global_abi.count);
    defer second.deinit();
    try rt.bindGlobalTable(&second, null, global_abi.id("_G"));
    try template.instantiate(&second);
    const second_math = second.getGlobal(global_abi.id("math")).table;
    const second_random = second_math.rawGet(.{ .string = "random" }).?;
    var saved_sqrt: Value = .nil;
    var expected_second_sample: f64 = undefined;
    const Probe = struct {
        fn seed(ctx: *rt.Context, math: *rt.Table) !void {
            const result = try callField(ctx, .{ .table = math }, "randomseed", &.{.{ .number = 123 }});
            defer rt.freeResults(result);
            try std.testing.expectEqual(@as(usize, 0), result.len);
        }
        fn next(ctx: *rt.Context, math: *rt.Table) !f64 {
            const result = try callField(ctx, .{ .table = math }, "random", &.{});
            defer rt.freeResults(result);
            try std.testing.expectEqual(@as(usize, 1), result.len);
            return result[0].number;
        }
    };
    {
        var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer first_arena.deinit();
        var first = try rt.Context.init(first_arena.allocator(), global_abi.count);
        defer first.deinit();
        try rt.bindGlobalTable(&first, null, global_abi.id("_G"));
        try template.instantiate(&first);
        const first_math = first.getGlobal(global_abi.id("math")).table;
        const first_random = first_math.rawGet(.{ .string = "random" }).?;
        try std.testing.expect(first_random.callable.env.raw != second_random.callable.env.raw);
        const base_math = try template.namespace("math");
        saved_sqrt = first_math.rawGet(.{ .string = "sqrt" }).?;
        try std.testing.expect(rt.rawEqual(saved_sqrt, base_math.rawGet(.{ .string = "sqrt" }).?));
        try std.testing.expect(rt.rawEqual(saved_sqrt, second_math.rawGet(.{ .string = "sqrt" }).?));
        try first_math.rawSet(first.allocator, .{ .string = "sqrt" }, .{ .number = 9 });
        try Probe.seed(&first, first_math);
        try Probe.seed(&second, second_math);
        const first_sample = try Probe.next(&first, first_math);
        expected_second_sample = try Probe.next(&first, first_math);
        try std.testing.expectEqual(first_sample, try Probe.next(&second, second_math));
    }
    // The saved standard-library callable belongs to the Template, not the
    // first child's released namespace or arena. The second host also survives.
    const result = try second.callValue(saved_sqrt, &.{.{ .number = 81 }});
    defer rt.freeResults(result);
    try std.testing.expectEqual(@as(f64, 9), result[0].number);
    try std.testing.expectEqual(expected_second_sample, try Probe.next(&second, second_math));
}

test "string.gsub appends string replacements and preserves callback captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);
    const gsub = ctx.getGlobal(global_abi.id("string")).table.rawGet(.{ .string = "gsub" }).?;

    const captures = try ctx.callValue(gsub, &.{
        .{ .string = "ab cd" }, .{ .string = "(%a+)" }, .{ .string = "<%0|%1>" },
    });
    defer rt.freeResults(captures);
    try std.testing.expectEqualStrings("<ab|ab> <cd|cd>", captures[0].string);
    try std.testing.expectEqual(@as(f64, 2), captures[1].number);

    const trailing_percent = try ctx.callValue(gsub, &.{
        .{ .string = "aa" }, .{ .string = "a" }, .{ .string = "x%" },
    });
    defer rt.freeResults(trailing_percent);
    try std.testing.expectEqualSlices(u8, &.{ 'x', 0, 'x', 0 }, trailing_percent[0].string);
    try std.testing.expectEqual(@as(f64, 2), trailing_percent[1].number);

    var callback_count: usize = 0;
    const callback = try ctx.newNative(&callback_count, struct {
        fn call(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
            return one(runtime.allocator, args[0]);
        }
    }.call);
    const via_callback = try ctx.callValue(gsub, &.{
        .{ .string = "ab cd" }, .{ .string = "(%a+)" }, callback,
    });
    defer rt.freeResults(via_callback);
    try std.testing.expectEqualStrings("ab cd", via_callback[0].string);
    try std.testing.expectEqual(@as(f64, 2), via_callback[1].number);
    try std.testing.expectEqual(@as(usize, 2), callback_count);

    const original = "no match here";
    const missed = try ctx.callValue(gsub, &.{
        .{ .string = original }, .{ .string = "[%d]+" }, .{ .string = "replacement" },
    });
    defer rt.freeResults(missed);
    try std.testing.expectEqualStrings(original, missed[0].string);
    try std.testing.expectEqual(@as(f64, 0), missed[1].number);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(missed[0].string.ptr));

    const limited = try ctx.callValue(gsub, &.{
        .{ .string = original }, .{ .string = "%a" }, .{ .string = "replacement" }, .{ .number = 0 },
    });
    defer rt.freeResults(limited);
    try std.testing.expectEqualStrings(original, limited[0].string);
    try std.testing.expectEqual(@as(f64, 0), limited[1].number);
}

test "buffered stdlib returns clip fixed calls and preserve full dynamic results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);
    const string = ctx.getGlobal(global_abi.id("string")).table;
    const find = string.rawGet(.{ .string = "find" }).?;
    const match = string.rawGet(.{ .string = "match" }).?;
    const byte = string.rawGet(.{ .string = "byte" }).?;
    const gsub = string.rawGet(.{ .string = "gsub" }).?;
    var slots = [_]Value{ .{ .string = "stale" }, .{ .string = "stale" } };

    const find_args = [_]Value{ .{ .string = "abc123" }, .{ .string = "(%a+)(%d+)" } };
    const clipped_find = try ctx.callValueFixed(find, &find_args, &slots);
    defer clipped_find.deinit();
    try std.testing.expectEqual(@as(usize, 2), clipped_find.values.len);
    try std.testing.expect(clipped_find.values.ptr == slots[0..].ptr);
    try std.testing.expectEqual(@as(f64, 1), slots[0].number);
    try std.testing.expectEqual(@as(f64, 6), slots[1].number);
    const full_find = try ctx.callValue(find, &find_args);
    defer rt.freeResults(full_find);
    try std.testing.expectEqual(@as(usize, 4), full_find.len);
    try std.testing.expectEqualStrings("abc", full_find[2].string);
    try std.testing.expectEqualStrings("123", full_find[3].string);

    const match_args = [_]Value{ .{ .string = "abc123" }, .{ .string = "(%a+)(%d+)" } };
    const clipped_match = try ctx.callValueFixed(match, &match_args, slots[0..1]);
    defer clipped_match.deinit();
    try std.testing.expectEqual(@as(usize, 1), clipped_match.values.len);
    try std.testing.expectEqualStrings("abc", slots[0].string);
    const full_match = try ctx.callValue(match, &match_args);
    defer rt.freeResults(full_match);
    try std.testing.expectEqual(@as(usize, 2), full_match.len);
    try std.testing.expectEqualStrings("123", full_match[1].string);

    const byte_args = [_]Value{ .{ .string = "ABC" }, .{ .number = 1 }, .{ .number = 3 } };
    const clipped_byte = try ctx.callValueFixed(byte, &byte_args, &slots);
    defer clipped_byte.deinit();
    try std.testing.expectEqual(@as(usize, 2), clipped_byte.values.len);
    try std.testing.expectEqual(@as(f64, 65), slots[0].number);
    try std.testing.expectEqual(@as(f64, 66), slots[1].number);
    const full_byte = try ctx.callValue(byte, &byte_args);
    defer rt.freeResults(full_byte);
    try std.testing.expectEqual(@as(usize, 3), full_byte.len);
    try std.testing.expectEqual(@as(f64, 67), full_byte[2].number);

    const gsub_args = [_]Value{ .{ .string = "aba" }, .{ .string = "a" }, .{ .string = "x" } };
    const clipped_gsub = try ctx.callValueFixed(gsub, &gsub_args, &slots);
    defer clipped_gsub.deinit();
    try std.testing.expectEqual(@as(usize, 2), clipped_gsub.values.len);
    try std.testing.expectEqualStrings("xbx", slots[0].string);
    try std.testing.expectEqual(@as(f64, 2), slots[1].number);
    const full_gsub = try ctx.callValue(gsub, &gsub_args);
    defer rt.freeResults(full_gsub);
    try std.testing.expectEqual(@as(usize, 2), full_gsub.len);

    const missing = try ctx.callValueFixed(find, &.{ .{ .string = "abc" }, .{ .string = "z" } }, &slots);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), missing.values.len);
    try std.testing.expect(slots[0] == .nil);

    const require = ctx.getGlobal(global_abi.id("require"));
    try ctx.package_loaded.?.rawSet(ctx.allocator, .{ .string = "strict" }, .{ .boolean = true });
    const cached = try ctx.callValueFixed(require, &.{.{ .string = "strict" }}, slots[0..1]);
    defer cached.deinit();
    try std.testing.expectEqual(@as(usize, 1), cached.values.len);
    try std.testing.expect(slots[0].boolean);
    try std.testing.expectError(error.AotCallFailed, ctx.callValueFixed(require, &.{.{ .number = 1 }}, &slots));
}

test "buffered base and namespace calls borrow fixed slots and keep dynamic arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try install(&ctx);

    const rawset = ctx.getGlobal(global_abi.id("rawset"));
    const rawget = ctx.getGlobal(global_abi.id("rawget"));
    var tostring_callable = ctx.getGlobal(global_abi.id("tostring"));
    const table_value = Value{ .table = try ctx.newTable() };
    var slot = [_]Value{.{ .string = "old" }};
    const set = try ctx.callValueFixed(rawset, &.{ table_value, .{ .string = "a" }, .{ .number = 7 } }, &slot);
    defer set.deinit();
    try std.testing.expect(!set.owned);
    try std.testing.expect(set.values.ptr == slot[0..].ptr);
    try std.testing.expect(slot[0].table == table_value.table);
    const get = try ctx.callValueFixed(rawget, &.{ table_value, .{ .string = "a" } }, &slot);
    defer get.deinit();
    try std.testing.expect(!get.owned);
    try std.testing.expectEqual(@as(f64, 7), slot[0].number);

    const assert_fn = ctx.getGlobal(global_abi.id("assert"));
    const assert_args = [_]Value{ .{ .boolean = true }, .{ .string = "first" }, .{ .string = "second" } };
    const assert_fixed = try ctx.callValueFixed(assert_fn, &assert_args, &slot);
    defer assert_fixed.deinit();
    try std.testing.expect(!assert_fixed.owned);
    try std.testing.expect(slot[0].boolean);
    const assert_dynamic = try ctx.callValue(assert_fn, &assert_args);
    defer rt.freeResults(assert_dynamic);
    try std.testing.expectEqual(@as(usize, 3), assert_dynamic.len);
    try std.testing.expectEqualStrings("second", assert_dynamic[2].string);

    const pairs = ctx.getGlobal(global_abi.id("pairs"));
    var pair_storage = [_]Value{ table_value, .nil, .nil };
    const pair_result = try ctx.callValueFixed(pairs, pair_storage[0..1], &pair_storage);
    defer pair_result.deinit();
    try std.testing.expect(!pair_result.owned);
    try std.testing.expectEqual(@as(usize, 3), pair_result.values.len);
    try std.testing.expect(pair_storage[0] == .callable);
    try std.testing.expect(pair_storage[1].table == table_value.table);
    try std.testing.expect(pair_storage[2] == .nil);
    const ipairs = ctx.getGlobal(global_abi.id("ipairs"));
    var ipairs_storage = [_]Value{ table_value, .nil, .nil };
    const ipairs_result = try ctx.callValueFixed(ipairs, ipairs_storage[0..1], &ipairs_storage);
    defer ipairs_result.deinit();
    try std.testing.expect(!ipairs_result.owned);
    try std.testing.expectEqual(@as(usize, 3), ipairs_result.values.len);
    try std.testing.expect(ipairs_storage[0] == .callable);
    try std.testing.expect(ipairs_storage[1].table == table_value.table);
    try std.testing.expectEqual(@as(f64, 0), ipairs_storage[2].number);

    const select = ctx.getGlobal(global_abi.id("select"));
    const selected_args = [_]Value{ .{ .number = 2 }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } };
    const clipped = try ctx.callValueFixed(select, &selected_args, &slot);
    defer clipped.deinit();
    try std.testing.expect(!clipped.owned);
    try std.testing.expectEqual(@as(usize, 1), clipped.values.len);
    try std.testing.expectEqualStrings("b", slot[0].string);
    const dynamic = try ctx.callValue(select, &selected_args);
    defer rt.freeResults(dynamic);
    try std.testing.expectEqual(@as(usize, 2), dynamic.len);
    try std.testing.expectEqualStrings("c", dynamic[1].string);
    var overlapping_args = [_]Value{ .{ .number = 2 }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } };
    const overlapping = try baseSelect(null, &ctx, &overlapping_args, overlapping_args[1..3]);
    try std.testing.expectEqual(@as(usize, 2), overlapping.len);
    try std.testing.expectEqualStrings("b", overlapping[0].string);
    try std.testing.expectEqualStrings("c", overlapping[1].string);
    var reverse_overlap_args = [_]Value{ .{ .number = 1 }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } };
    const reverse_overlap = try baseSelect(null, &ctx, &reverse_overlap_args, reverse_overlap_args[2..4]);
    try std.testing.expectEqual(@as(usize, 2), reverse_overlap.len);
    try std.testing.expectEqualStrings("a", reverse_overlap[0].string);
    try std.testing.expectEqualStrings("b", reverse_overlap[1].string);

    const unpack = ctx.getGlobal(global_abi.id("unpack"));
    try table_value.table.rawSet(ctx.allocator, .{ .number = 1 }, .{ .number = 11 });
    try table_value.table.rawSet(ctx.allocator, .{ .number = 2 }, .{ .number = 22 });
    const unpacked = try ctx.callValueFixed(unpack, &.{ table_value, .{ .number = 1 }, .{ .number = 3 } }, &slot);
    defer unpacked.deinit();
    try std.testing.expect(!unpacked.owned);
    try std.testing.expectEqual(@as(f64, 11), slot[0].number);
    const all = try ctx.callValue(unpack, &.{ table_value, .{ .number = 1 }, .{ .number = 3 } });
    defer rt.freeResults(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expect(all[2] == .nil);

    const math = ctx.getGlobal(global_abi.id("math")).table;
    const modf = math.rawGet(.{ .string = "modf" }).?;
    const fraction = try ctx.callValueFixed(modf, &.{.{ .number = 2.5 }}, &slot);
    defer fraction.deinit();
    try std.testing.expect(!fraction.owned);
    try std.testing.expectEqual(@as(f64, 2), slot[0].number);
    const full_fraction = try ctx.callValue(modf, &.{.{ .number = 2.5 }});
    defer rt.freeResults(full_fraction);
    try std.testing.expectEqual(@as(usize, 2), full_fraction.len);
    try std.testing.expectEqual(@as(f64, 0.5), full_fraction[1].number);

    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const protected_args = [_]Value{ rawget, table_value, .{ .string = "a" } };
    const protected_fixed = try ctx.callValueFixed(pcall, &protected_args, &slot);
    defer protected_fixed.deinit();
    try std.testing.expect(!protected_fixed.owned);
    try std.testing.expect(slot[0].boolean);
    const protected_dynamic = try ctx.callValue(pcall, &protected_args);
    defer rt.freeResults(protected_dynamic);
    try std.testing.expectEqual(@as(usize, 2), protected_dynamic.len);
    try std.testing.expectEqual(@as(f64, 7), protected_dynamic[1].number);

    const string = ctx.getGlobal(global_abi.id("string")).table;
    const concat = ctx.getGlobal(global_abi.id("table")).table.rawGet(.{ .string = "concat" }).?;
    const joined = try ctx.callValueFixed(concat, &.{ table_value, .{ .string = ":" }, .{ .number = 1 }, .{ .number = 2 } }, &slot);
    defer joined.deinit();
    try std.testing.expect(!joined.owned);
    try std.testing.expectEqualStrings("11:22", slot[0].string);
    const sub = string.rawGet(.{ .string = "sub" }).?;
    const sliced = try ctx.callValueFixed(sub, &.{ .{ .string = "abcdef" }, .{ .number = 2 }, .{ .number = 4 } }, &slot);
    defer sliced.deinit();
    try std.testing.expect(!sliced.owned);
    try std.testing.expectEqualStrings("bcd", slot[0].string);

    const mt = try ctx.newTable();
    const nested_tostring = try ctx.newNative(&tostring_callable, struct {
        fn call(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
            const inner_callable: *const Value = @ptrCast(@alignCast(raw.?));
            const inner = try runtime.callValue(inner_callable.*, &.{.{ .number = 42 }});
            defer rt.freeResults(inner);
            return one(runtime.allocator, inner[0]);
        }
    }.call);
    try mt.rawSet(ctx.allocator, .{ .string = "__tostring" }, nested_tostring);
    table_value.table.metatable = mt;
    const outer = try ctx.callValueFixed(tostring_callable, &.{table_value}, &slot);
    defer outer.deinit();
    try std.testing.expect(!outer.owned);
    try std.testing.expectEqualStrings("42", slot[0].string);

    var no_slots: [0]Value = .{};
    const discarded = try ctx.callValueFixed(rawset, &.{ table_value, .{ .string = "b" }, .{ .number = 9 } }, &no_slots);
    defer discarded.deinit();
    try std.testing.expectEqual(@as(usize, 0), discarded.values.len);
    try std.testing.expect(!discarded.owned);
    try std.testing.expectEqual(@as(f64, 9), table_value.table.rawGet(.{ .string = "b" }).?.number);
    const missing = try ctx.callValueFixed(rawget, &.{ table_value, .{ .string = "missing" } }, &slot);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), missing.values.len);
    try std.testing.expect(slot[0] == .nil);
}

fn nilPayloadHandler(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len != 1 or args[0] != .nil) return error.BadNilPayload;
    return one(ctx.allocator, .nil);
}

fn nestedNilThenGeneric(_: ?*anyopaque, ctx: *rt.Context, _: []const Value) ![]const Value {
    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const raise = ctx.getGlobal(global_abi.id("error"));
    const inner = try ctx.callValue(pcall, &.{ raise, .nil });
    defer rt.freeResults(inner);
    if (inner.len != 2 or inner[0] != .boolean or inner[0].boolean or inner[1] != .nil)
        return error.BadNestedPcall;
    return error.GenericAfterNestedPcall;
}

fn nilIndexPayload(_: ?*anyopaque, ctx: *rt.Context, _: []const Value) ![]const Value {
    ctx.setLuaError(.nil);
    return error.LuaRaised;
}

fn readMissingField(_: ?*anyopaque, ctx: *rt.Context, args: []const Value) ![]const Value {
    if (args.len != 1) return error.MissingArgument;
    return one(ctx.allocator, try ctx.getIndex(args[0], .{ .string = "missing" }));
}

test "protected calls retain explicit nil errors and clear nested payload state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try rt.bindGlobalTable(&ctx, null, global_abi.id("_G"));
    try install(&ctx);
    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const raise = ctx.getGlobal(global_abi.id("error"));
    const assertion = ctx.getGlobal(global_abi.id("assert"));

    const explicit_nil = try ctx.callValue(pcall, &.{ raise, .nil });
    defer rt.freeResults(explicit_nil);
    try std.testing.expectEqual(@as(usize, 2), explicit_nil.len);
    try std.testing.expect(explicit_nil[0] == .boolean and !explicit_nil[0].boolean and explicit_nil[1] == .nil);
    try std.testing.expect(!ctx.last_error_present);

    const absent_arg = try ctx.callValue(pcall, &.{raise});
    defer rt.freeResults(absent_arg);
    try std.testing.expectEqual(@as(usize, 2), absent_arg.len);
    try std.testing.expect(absent_arg[0] == .boolean and !absent_arg[0].boolean and absent_arg[1] == .nil);

    const assertion_nil = try ctx.callValue(pcall, &.{ assertion, .{ .boolean = false }, .nil });
    defer rt.freeResults(assertion_nil);
    try std.testing.expectEqual(@as(usize, 2), assertion_nil.len);
    try std.testing.expect(assertion_nil[0] == .boolean and !assertion_nil[0].boolean and assertion_nil[1] == .nil);

    const nested = try ctx.newNative(null, nestedNilThenGeneric);
    const generic = try ctx.callValue(pcall, &.{nested});
    defer rt.freeResults(generic);
    try std.testing.expectEqual(@as(usize, 2), generic.len);
    try std.testing.expect(generic[0] == .boolean and !generic[0].boolean);
    try std.testing.expectEqualStrings("GenericAfterNestedPcall", generic[1].string);
    try std.testing.expect(!ctx.last_error_present);
}

test "metamethod nil payload and xpcall nil handler result survive protected calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), global_abi.count);
    defer ctx.deinit();
    try rt.bindGlobalTable(&ctx, null, global_abi.id("_G"));
    try install(&ctx);
    const pcall = ctx.getGlobal(global_abi.id("pcall"));
    const xpcall = ctx.global_table.?.rawGet(.{ .string = "xpcall" }).?;
    const raise = ctx.getGlobal(global_abi.id("error"));

    const object = try ctx.newTable();
    const metatable = try ctx.newTable();
    try metatable.rawSet(ctx.allocator, .{ .string = "__index" }, try ctx.newNative(null, nilIndexPayload));
    object.metatable = metatable;
    const reader = try ctx.newNative(null, readMissingField);
    const metamethod = try ctx.callValue(pcall, &.{ reader, .{ .table = object } });
    defer rt.freeResults(metamethod);
    try std.testing.expectEqual(@as(usize, 2), metamethod.len);
    try std.testing.expect(metamethod[0] == .boolean and !metamethod[0].boolean and metamethod[1] == .nil);

    const handler = try ctx.newNative(null, nilPayloadHandler);
    const handled = try ctx.callValue(xpcall, &.{ raise, handler });
    defer rt.freeResults(handled);
    try std.testing.expectEqual(@as(usize, 2), handled.len);
    try std.testing.expect(handled[0] == .boolean and !handled[0].boolean and handled[1] == .nil);
    try std.testing.expect(!ctx.last_error_present);
}
