const std = @import("std");

pub fn parse(raw: []const u8) !f64 {
    var s = raw;
    var sign: f64 = 1;
    if (s.len != 0 and s[0] == '-') {
        sign = -1;
        s = s[1..];
    }
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s = s[2..];
        var mantissa = s;
        var exp2: i32 = 0;
        if (std.mem.indexOfAny(u8, s, "pP")) |p| {
            mantissa = s[0..p];
            exp2 = try std.fmt.parseInt(i32, s[p + 1 ..], 10);
        }
        var value: f64 = 0;
        var fraction: f64 = 1;
        var after_dot = false;
        for (mantissa) |c| {
            if (c == '.') {
                after_dot = true;
                continue;
            }
            const digit: u8 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.InvalidNumber;
            if (!after_dot) {
                value = value * 16 + @as(f64, @floatFromInt(digit));
            } else {
                fraction /= 16;
                value += @as(f64, @floatFromInt(digit)) * fraction;
            }
        }
        return sign * value * std.math.pow(f64, 2, @floatFromInt(exp2));
    }
    return sign * (std.fmt.parseFloat(f64, s) catch return error.InvalidNumber);
}

test "Lua numeric literals parse" {
    try std.testing.expectEqual(@as(f64, 12.5), try parse("12.5"));
    try std.testing.expectEqual(@as(f64, -16), try parse("-0x10"));
    try std.testing.expectEqual(@as(f64, 6), try parse("0x1.8p2"));
}
