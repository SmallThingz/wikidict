const std = @import("std");
const rt = @import("zig_runtime");
const Value = rt.Value;

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn hashValueCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.StringExpected;
    if (!std.mem.eql(u8, args[0].string, "md5")) return error.UnsupportedHashAlgorithm;
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(args[1].string, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return one(.{ .string = try runtime.allocator.dupe(u8, &hex) });
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    const hash = try runtime.newNativeNamespace(.hash);
    try hash.rawSetNativeField(.hash, "hashValue", try runtime.newNative(null, hashValueCall));
    try mw.rawSetNativeField(.mw, "hash", .{ .table = hash });
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT mw hash exposes corpus-used MD5" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const hash = try runtime.getIndex(.{ .table = mw }, .{ .string = "hash" });
    const md5 = try callField(&runtime, hash, "hashValue", &.{ .{ .string = "md5" }, .{ .string = "abc" } });
    defer rt.freeResults(md5);
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", md5[0].string);
    const hash_value = try runtime.getIndex(hash, .{ .string = "hashValue" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(hash_value, &.{ .{ .string = "sha512" }, .{ .string = "abc" } }));
    try std.testing.expectEqualStrings("UnsupportedHashAlgorithm", runtime.aotErrorName().?);
}
