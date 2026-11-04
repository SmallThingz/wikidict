const std = @import("std");

// Build-time relative CSS values only. No source/CSS reaches readers.
// Zero is retained here; the Qt zero-layout contract still needs measurement.
pub fn parseRelative(raw: []const u8) ?f32 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    var number = value;
    var divisor: f64 = 1;
    if (std.mem.endsWith(u8, value, "%")) {
        number = value[0 .. value.len - 1];
        divisor = 100;
    } else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "em")) {
        number = value[0 .. value.len - 2];
    } else {
        // CSS permits unitless zero, not arbitrary unitless font sizes.
        if (!cssNumber(number)) return null;
        const zero = std.fmt.parseFloat(f64, number) catch return null;
        if (zero == 0 and nonzeroMantissa(number)) return null;
        return if (zero == 0) 0 else null;
    }
    if (!cssNumber(number)) return null;
    const parsed = std.fmt.parseFloat(f64, number) catch return null;
    if (parsed == 0 and nonzeroMantissa(number)) return null;
    const ratio = parsed / divisor;
    if (parsed > 0 and ratio == 0) return null;
    if (!std.math.isFinite(ratio) or ratio < 0 or ratio > std.math.floatMax(f32)) return null;
    const result: f32 = @floatCast(ratio);
    if (ratio > 0 and result == 0) return null;
    return result;
}

fn nonzeroMantissa(value: []const u8) bool {
    for (value) |c| {
        if (c == 'e' or c == 'E') break;
        if (c >= '1' and c <= '9') return true;
    }
    return false;
}

fn cssNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    if (value[i] == '+' or value[i] == '-') i += 1;
    var digits: usize = 0;
    while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) digits += 1;
    if (i < value.len and value[i] == '.') {
        i += 1;
        if (i == value.len or !std.ascii.isDigit(value[i])) return false;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        const start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        if (i == start) return false;
    }
    return i == value.len;
}

pub fn valid(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

// Parent and child describe numeric CSS only. Existing small/sub/super flags
// remain separate so readers apply their established reduction exactly once.
pub fn resolve(parent: ?f32, child: f32) error{InvalidFontScale}! ?f32 {
    const inherited = parent orelse 1;
    if (!valid(inherited) or !valid(child)) return error.InvalidFontScale;
    const product = @as(f64, inherited) * @as(f64, child);
    if (!std.math.isFinite(product) or product > std.math.floatMax(f32)) return error.InvalidFontScale;
    const result: f32 = @floatCast(product);
    if (product > 0 and result == 0) return error.InvalidFontScale;
    return if (result == 1) null else result;
}

test "actual ARchar125 percent is a relative multiplier" {
    try std.testing.expectEqual(@as(?f32, 1.25), parseRelative("125%"));
    try std.testing.expectEqual(@as(?f32, 1.25), parseRelative("1.25em"));
    try std.testing.expectEqual(@as(?f32, 1.25), parseRelative(" +1.25EM "));
    try std.testing.expectEqual(@as(?f32, 0.5), parseRelative(".5em"));
    try std.testing.expectEqual(@as(?f32, 1), parseRelative("1e2%"));
    try std.testing.expectEqual(@as(?f32, 1.25), try resolve(null, parseRelative("125%") orelse unreachable));
}

test "numeric inheritance composes and identity does not force a new payload" {
    const parent = try resolve(null, 1.25);
    try std.testing.expectEqual(@as(?f32, 1.25), try resolve(parent, 1));
    try std.testing.expectEqual(@as(?f32, null), try resolve(parent, 0.8));
    try std.testing.expectEqual(@as(?f32, 1.5625), try resolve(parent, 1.25));
    try std.testing.expectEqual(@as(?f32, null), try resolve(null, 1));
}

test "CSS zero stays explicit without choosing a renderer workaround" {
    for ([_][]const u8{ "0", "+0", "-0", "0%", "0em", "0e-999", "-0e-999", "0.0e2%" }) |source|
        try std.testing.expectEqual(@as(?f32, 0), parseRelative(source));
    try std.testing.expectEqual(@as(?f32, 0), try resolve(1.25, 0));
    try std.testing.expectEqual(@as(?f32, 0), try resolve(0, 1.25));
}

test "invalid unsupported and nonfinite values never become a scale" {
    for ([_][]const u8{ "", "-1%", "NaN%", "Infinityem", "1e999%", "1e-999%", "1e-999", "-1e-999", "125.%", "1.em", "1e%", ".%", "1 25%", "125 %", "12px", "12pt", "calc(100% + 1px)", "inherit", "1.25", "125%!important" }) |source|
        try std.testing.expectEqual(@as(?f32, null), parseRelative(source));
    try std.testing.expect(!valid(std.math.nan(f32)));
    try std.testing.expect(!valid(std.math.inf(f32)));
    try std.testing.expectError(error.InvalidFontScale, resolve(std.math.floatMax(f32), 2));
    try std.testing.expectError(error.InvalidFontScale, resolve(1, std.math.inf(f32)));
}
