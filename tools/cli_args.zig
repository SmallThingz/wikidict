const std = @import("std");

pub fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

pub fn parseOptionalIntFlag(comptime T: type, args: []const []const u8, name: []const u8) !?T {
    const value = flagValue(args, name) orelse return null;
    return try std.fmt.parseInt(T, value, 10);
}

test "flagValue returns the next argument for a matching flag" {
    const args = [_][]const u8{ "--input", "sample.xml", "--output", "sample.bin" };
    try std.testing.expectEqualStrings("sample.xml", flagValue(&args, "--input").?);
    try std.testing.expectEqualStrings("sample.bin", flagValue(&args, "--output").?);
    try std.testing.expect(flagValue(&args, "--missing") == null);
}

test "parseOptionalIntFlag parses present values and ignores absent ones" {
    const args = [_][]const u8{ "--limit", "42" };
    try std.testing.expectEqual(@as(?usize, 42), try parseOptionalIntFlag(usize, &args, "--limit"));
    try std.testing.expectEqual(@as(?usize, null), try parseOptionalIntFlag(usize, &args, "--missing"));
}
