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

// Native reader UA absolute-size table, following CSS Fonts 3 section 3.5.
// The existing normal-body reading size is our medium. These values reset the
// ancestor scale; they are not a claim about a captured browser's pixel sizes.
pub fn absoluteKeyword(raw: []const u8) ?f32 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    const names = .{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large" };
    const factors = [_]f32{ 3.0 / 5.0, 3.0 / 4.0, 8.0 / 9.0, 1, 6.0 / 5.0, 3.0 / 2.0, 2 };
    inline for (names, factors) |name, factor| if (std.ascii.eqlIgnoreCase(value, name)) return factor;
    return null;
}

pub const RelativeKeyword = enum { smaller, larger };
pub fn relativeKeyword(raw: []const u8) ?RelativeKeyword {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(value, "smaller")) return .smaller;
    if (std.ascii.eqlIgnoreCase(value, "larger")) return .larger;
    return null;
}

// Native UA policy: interpolate the adjacent-keyword mapping linearly between
// known body-medium sizes; extrapolate with the nearest endpoint ratio. This
// is a computed size, not a percentage to multiply against the parent again.
pub fn resolveKeyword(parent: f32, direction: RelativeKeyword) error{InvalidFontScale}!f32 {
    if (!valid(parent)) return error.InvalidFontScale;
    const table = [_]f32{ 3.0 / 5.0, 3.0 / 4.0, 8.0 / 9.0, 1, 6.0 / 5.0, 3.0 / 2.0, 2 };
    const x: f64 = parent;
    var result: f64 = undefined;
    if (x <= table[0]) {
        result = x * (if (direction == .smaller) @as(f64, table[0]) / table[1] else @as(f64, table[1]) / table[0]);
    } else if (x >= table[table.len - 1]) {
        result = x * (if (direction == .smaller) @as(f64, table[table.len - 2]) / table[table.len - 1] else @as(f64, table[table.len - 1]) / table[table.len - 2]);
    } else {
        var i: usize = 0;
        while (x > table[i + 1]) : (i += 1) {}
        const lower: f64 = table[i];
        const upper: f64 = table[i + 1];
        const from: f64 = if (direction == .smaller)
            (if (i == 0) lower * lower / upper else table[i - 1])
        else upper;
        const to: f64 = if (direction == .smaller) lower else
            (if (i + 2 == table.len) upper * upper / lower else table[i + 2]);
        result = from + (x - lower) / (upper - lower) * (to - from);
    }
    if (!std.math.isFinite(result) or result > std.math.floatMax(f32)) return error.InvalidFontScale;
    const projected: f32 = @floatCast(result);
    if (result > 0 and projected == 0) return error.InvalidFontScale;
    return projected;
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


test "relative keyword native UA table interpolates computed sizes without repeated parent multiplication" {
    const table = [_]f32{ 3.0 / 5.0, 3.0 / 4.0, 8.0 / 9.0, 1, 6.0 / 5.0, 3.0 / 2.0, 2 };
    for (table, 0..) |size, i| {
        if (i > 0) try std.testing.expectApproxEqAbs(table[i - 1], try resolveKeyword(size, .smaller), 0.000001);
        if (i + 1 < table.len) try std.testing.expectApproxEqAbs(table[i + 1], try resolveKeyword(size, .larger), 0.000001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.838888888888889), try resolveKeyword(0.96, .smaller), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.128), try resolveKeyword(0.96, .larger), 0.000001);
    try std.testing.expectEqual(@as(f32, 0), try resolveKeyword(0, .smaller));
    try std.testing.expectEqual(@as(f32, 0), try resolveKeyword(0, .larger));
    try std.testing.expectApproxEqAbs(@as(f32, 0.24), try resolveKeyword(0.3, .smaller), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 4), try resolveKeyword(3, .larger), 0.000001);
    try std.testing.expectError(error.InvalidFontScale, resolveKeyword(std.math.floatMax(f32), .larger));
    try std.testing.expectError(error.InvalidFontScale, resolveKeyword(-1, .smaller));
    try std.testing.expectError(error.InvalidFontScale, resolveKeyword(std.math.nan(f32), .smaller));
    try std.testing.expect(relativeKeyword(" SMALLER ") == .smaller);
    try std.testing.expect(relativeKeyword("1.2") == null);
}


pub fn parseCssPixels(raw: []const u8) ?f32 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (value.len <= 2 or !std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) return null;
    const number = value[0 .. value.len - 2];
    if (!cssNumber(number)) return null;
    const parsed = std.fmt.parseFloat(f64, number) catch return null;
    if (!std.math.isFinite(parsed) or parsed < 0 or parsed > std.math.floatMax(f32) or
        (parsed == 0 and nonzeroMantissa(number))) return null;
    const result: f32 = @floatCast(parsed);
    if (parsed > 0 and result == 0) return null;
    return result;
}

test "authored pixel font parser preserves absolute units and strict CSS number tokens" {
    try std.testing.expectEqual(@as(?f32, 12), parseCssPixels("12px"));
    try std.testing.expectEqual(@as(?f32, 12), parseCssPixels(" +1.2e1PX "));
    try std.testing.expectEqual(@as(?f32, 0.5), parseCssPixels(".5px"));
    for ([_][]const u8{ "0px", "-0px", "+0.0e9px" }) |value|
        try std.testing.expectEqual(@as(?f32, 0), parseCssPixels(value));
    for ([_][]const u8{ "12", "12 px", "12pxsolid", "12.pt", "12pt", "-1px", "NaNpx", "Infpx", "1e999px", "1e-999px", "12.px", "calc(12px)", "var(--size)", "12\\px", "12px!important" }) |value|
        try std.testing.expect(parseCssPixels(value) == null);
}
