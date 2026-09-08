const std = @import("std");

pub const integer_marker: u32 = @as(u32, 1) << 31;
const payload_mask = integer_marker - 1;
const min_integer: i64 = -(@as(i64, 1) << 30);
const max_integer: i64 = (@as(i64, 1) << 30) - 1;

pub fn string(string_id: u32) !u32 {
    if (string_id & integer_marker != 0) return error.ShapeKeyOverflow;
    return string_id;
}

pub fn stringId(key: u32) ?u32 {
    return if (key & integer_marker == 0) key else null;
}

pub fn integer(value: i64) ?u32 {
    if (value < min_integer or value > max_integer) return null;
    const signed: i32 = @intCast(value);
    const bits: u32 = @bitCast(signed);
    const zigzag = (bits << 1) ^ @as(u32, @bitCast(signed >> 31));
    return integer_marker | (zigzag & payload_mask);
}

pub fn number(value: f64) ?u32 {
    if (!std.math.isFinite(value) or @floor(value) != value) return null;
    if (value < @as(f64, @floatFromInt(min_integer)) or value > @as(f64, @floatFromInt(max_integer))) return null;
    return integer(@intFromFloat(value));
}

pub fn integerValue(key: u32) ?i32 {
    if (key & integer_marker == 0) return null;
    const payload = key & payload_mask;
    const decoded = (payload >> 1) ^ (0 -% (payload & 1));
    return @bitCast(decoded);
}

pub fn valid(key: u32, string_count: usize) bool {
    if (stringId(key)) |id| return id < string_count;
    return integerValue(key) != null;
}

test "shape keys preserve string ids and signed integer keys" {
    try std.testing.expectEqual(@as(u32, 17), try string(17));
    try std.testing.expectEqual(@as(?u32, 17), stringId(17));
    for ([_]i64{ min_integer, -7, -1, 0, 1, 99, max_integer }) |value| {
        const key = integer(value) orelse return error.MissingShapeKey;
        try std.testing.expectEqual(@as(i32, @intCast(value)), integerValue(key).?);
        try std.testing.expect(stringId(key) == null);
    }
    try std.testing.expectEqual(@as(?u32, null), integer(min_integer - 1));
    try std.testing.expectEqual(@as(?u32, null), integer(max_integer + 1));
    try std.testing.expectEqual(integer(0), number(-0.0));
    try std.testing.expectEqual(integer(12), number(12.0));
    try std.testing.expect(number(1.5) == null);
}
