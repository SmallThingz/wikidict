const std = @import("std");
const static_fields = @import("vm_static_field_abi.zig");

// Bit 31 belongs to static string-field refs; bit 30 distinguishes immediate numeric keys from local shape slots.
pub const marker: u32 = @as(u32, 1) << 30;
const payload_mask = marker - 1;
pub const min_integer: i64 = -536_870_912;
pub const max_integer: i64 = 536_870_911;

pub fn refForInteger(value: i64) ?u32 {
    if (value < min_integer or value > max_integer) return null;
    const payload: u32 = if (value >= 0)
        @intCast(@as(u64, @intCast(value)) * 2)
    else
        @intCast(@as(u64, @intCast(-value)) * 2 - 1);
    return marker | payload;
}

pub fn refForNumber(value: f64) ?u32 {
    if (!std.math.isFinite(value) or @floor(value) != value) return null;
    if (value < @as(f64, @floatFromInt(min_integer)) or value > @as(f64, @floatFromInt(max_integer))) return null;
    return refForInteger(@intFromFloat(value));
}

pub fn integerForRef(value: u32) ?i64 {
    if (value & static_fields.marker != 0 or value & marker == 0) return null;
    const payload = value & payload_mask;
    if (payload & 1 == 0) return @intCast(payload / 2);
    return -@as(i64, @intCast(payload / 2)) - 1;
}

test "static integer refs roundtrip without colliding with field refs" {
    inline for ([_]i64{ min_integer, -17, -1, 0, 1, 17, max_integer }) |value| {
        const ref = refForInteger(value) orelse return error.MissingStaticKey;
        try std.testing.expectEqual(value, integerForRef(ref).?);
        try std.testing.expect(ref & static_fields.marker == 0);
    }
    try std.testing.expectEqual(@as(?u32, null), refForInteger(min_integer - 1));
    try std.testing.expectEqual(@as(?u32, null), refForInteger(max_integer + 1));
    try std.testing.expectEqual(@as(?u32, null), refForNumber(1.5));
    try std.testing.expectEqual(refForInteger(0), refForNumber(-0.0));
    try std.testing.expectEqual(@as(?i64, null), integerForRef(7));
    const field = @import("vm_static_field_abi.zig").refForName("insert") orelse return error.MissingField;
    try std.testing.expectEqual(@as(?i64, null), integerForRef(field));
}
