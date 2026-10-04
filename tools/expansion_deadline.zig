const std = @import("std");

pub const default_ms: u32 = 60_000;
pub const max_ms: u32 = 3_600_000;

pub fn parse(raw: []const u8) error{Usage}!u32 {
    const value = std.fmt.parseInt(u32, raw, 10) catch return error.Usage;
    if (value == 0 or value > max_ms) return error.Usage;
    return value;
}

test "page expansion deadlines stay positive and bounded" {
    try std.testing.expectEqual(@as(u32, 600_000), try parse("600000"));
    try std.testing.expectEqual(max_ms, try parse("3600000"));
    for ([_][]const u8{ "", "0", "-1", "nope", "3600001", "4294967296" }) |raw|
        try std.testing.expectError(error.Usage, parse(raw));
}
