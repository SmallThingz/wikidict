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
    const names = .{ "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large" };
    const factors = [_]f32{ 3.0 / 5.0, 3.0 / 4.0, 8.0 / 9.0, 1, 6.0 / 5.0, 3.0 / 2.0, 2, 3 };
    inline for (names, factors) |name, factor| if (std.ascii.eqlIgnoreCase(value, name)) return factor;
    return null;
}

// HTML FONT's normalized absolute size is a presentational hint.
pub fn htmlAbsoluteSizeKeyword(digit: u8) ?[]const u8 {
    const keywords = [_][]const u8{ "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large" };
    if (digit < '1' or digit > '7') return null;
    return keywords[digit - '1'];
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
    return parseAbsoluteFontLength(raw, false);
}

pub fn parseCssPixelOrPointFontSize(raw: []const u8) ?f32 {
    return parseAbsoluteFontLength(raw, true);
}

fn parseAbsoluteFontLength(raw: []const u8, allow_points: bool) ?f32 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (value.len <= 2) return null;
    const unit = value[value.len - 2 ..];
    const number = value[0 .. value.len - 2];
    const pixels_per_unit: f64 = if (std.ascii.eqlIgnoreCase(unit, "px")) 1
        else if (allow_points and std.ascii.eqlIgnoreCase(unit, "pt")) 96.0 / 72.0 else return null;
    if (!cssNumber(number)) return null;
    const parsed = std.fmt.parseFloat(f64, number) catch return null;
    const pixels = parsed * pixels_per_unit;
    if (!std.math.isFinite(pixels) or pixels < 0 or pixels > std.math.floatMax(f32) or
        (pixels == 0 and nonzeroMantissa(number))) return null;
    const result: f32 = @floatCast(pixels);
    if (pixels > 0 and result == 0) return null;
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


pub fn FontMetric(comptime Basis: type) type {
    return struct {
        const Self = @This();
        value: ?f32 = null,
        basis: Basis = .context,

        pub fn isValid(self: Self) bool {
            if (self.value) |value| if (!valid(value)) return false;
            return self.basis == .context or self.value != null;
        }
        pub fn from(value: ?f32, basis: Basis) error{InvalidFontScale}!Self {
            const result: Self = .{ .value = if (basis == .context and value == 1) null else value, .basis = basis };
            if (!result.isValid()) return error.InvalidFontScale;
            return result;
        }
        pub fn cssPixels(value: f32) error{InvalidFontScale}!Self {
            return from(value, .css_px);
        }
        pub fn normalBody(value: f32) error{InvalidFontScale}!Self {
            return from(value, .normal_body);
        }
        pub fn relative(self: Self, factor: f32) error{InvalidFontScale}!Self {
            if (!self.isValid()) return error.InvalidFontScale;
            const product = (try resolve(self.value, factor)) orelse 1;
            return from(product, self.basis);
        }
        pub fn keyword(self: Self, direction: RelativeKeyword) error{InvalidFontScale, UnresolvedFontOrigin}!Self {
            if (!self.isValid()) return error.InvalidFontScale;
            // The maintained UA keyword table is in body-medium units. A
            // pixel/context magnitude cannot become that unit without proof.
            if (self.basis != .normal_body) return error.UnresolvedFontOrigin;
            return normalBody(try resolveKeyword(self.value.?, direction));
        }
        pub fn emLength(self: Self, comptime Length: type, value: f32) error{InvalidFontScale, UnresolvedFontOrigin}!Length {
            if (self.basis == .context) return error.UnresolvedFontOrigin;
            const computed = try self.relative(value);
            return .{ .unit = if (self.basis == .css_px) .px else .em, .value = computed.value.? };
        }
    };
}

test "pixel font inheritance and relative composition do not normalize through a guessed body" {
    const Basis = enum { context, normal_body, css_px };
    const Metric = FontMetric(Basis);
    const parent = try Metric.cssPixels(12);
    const inherited = parent;
    try std.testing.expectEqualDeep(parent, inherited);
    const child = try parent.relative(0.75);
    try std.testing.expectEqual(@as(?f32, 9), child.value);
    try std.testing.expectEqual(Basis.css_px, child.basis);
    try std.testing.expectEqualDeep(parent, try parent.relative(1));
    const nested = try child.relative(2);
    try std.testing.expectEqual(@as(?f32, 18), nested.value);
    try std.testing.expectEqual(Basis.css_px, nested.basis);
    const one = try Metric.cssPixels(1);
    try std.testing.expectEqual(@as(?f32, 1), one.value);
    try std.testing.expectEqual(@as(?f32, null), (try Metric.from(1, .context)).value);
    try std.testing.expectEqual(@as(?f32, 1), (try Metric.normalBody(1)).value);
}

test "explicit pixel and keyword resets escape inherited zero without changing legacy flags" {
    const Basis = enum { context, normal_body, css_px };
    const Metric = FontMetric(Basis);
    const zero = try Metric.normalBody(0);
    const pixels = try Metric.cssPixels(12);
    try std.testing.expectEqual(@as(?f32, 0), zero.value);
    try std.testing.expectEqual(@as(?f32, 12), pixels.value);
    const zero_child = try pixels.relative(0);
    try std.testing.expectEqual(@as(?f32, 0), zero_child.value);
    try std.testing.expectEqual(Basis.css_px, zero_child.basis);
    const reset = try Metric.normalBody(1);
    try std.testing.expectEqual(Basis.normal_body, reset.basis);
    try std.testing.expectError(error.UnresolvedFontOrigin, pixels.keyword(.smaller));
    try std.testing.expectError(error.UnresolvedFontOrigin, (Metric{}).keyword(.larger));
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), (try reset.keyword(.larger)).value.?, 0.000001);
}

test "font origin normalizes em geometry into the actual symbolic length unit" {
    const Basis = enum { context, normal_body, css_px };
    const Metric = FontMetric(Basis);
    const Length = struct { unit: enum { px, em }, value: f32 };
    const pixels = try (try Metric.cssPixels(12)).emLength(Length, 0.5);
    try std.testing.expectEqualDeep(Length{ .unit = .px, .value = 6 }, pixels);
    const relative = try (try Metric.normalBody(0.9)).emLength(Length, 0.5);
    try std.testing.expectEqualDeep(Length{ .unit = .em, .value = 0.45 }, relative);
    try std.testing.expectError(error.UnresolvedFontOrigin, (Metric{}).emLength(Length, 1));
}

test "font origin arithmetic keeps finite magnitude and explicit basis admission" {
    const Basis = enum { context, normal_body, css_px };
    const Metric = FontMetric(Basis);
    try std.testing.expectError(error.InvalidFontScale, Metric.from(null, .css_px));
    try std.testing.expectError(error.InvalidFontScale, Metric.from(null, .normal_body));
    try std.testing.expectError(error.InvalidFontScale, Metric.cssPixels(-1));
    try std.testing.expectError(error.InvalidFontScale, Metric.cssPixels(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidFontScale, (try Metric.cssPixels(std.math.floatMax(f32))).relative(2));
    try std.testing.expectError(error.InvalidFontScale, (try Metric.cssPixels(1)).relative(std.math.inf(f32)));
}


// Specified values retain their origin until the original cell/root fonts are known.
pub const CellLineHeightSpecified = union(enum) {
    normal,
    inherit,
    multiplier: f32,
    owner_relative: f32,
    root_relative: f32,
    css_px: f32,
};
pub const CellLineHeightParse = union(enum) { known: CellLineHeightSpecified, invalid, unknown };

pub fn parseCellLineHeight(raw: []const u8) CellLineHeightParse {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(value, "normal") or std.ascii.eqlIgnoreCase(value, "initial")) return .{ .known = .normal };
    if (std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset")) return .{ .known = .inherit };
    if (std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer") or
        std.mem.indexOfAny(u8, value, "()\\/!") != null) return .unknown;
    const Unit = enum { number, px, em, percent, rem };
    var unit: Unit = .number;
    var number = value;
    if (value.len >= 3 and std.ascii.eqlIgnoreCase(value[value.len - 3 ..], "rem")) {
        unit = .rem; number = value[0 .. value.len - 3];
    } else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "em")) {
        unit = .em; number = value[0 .. value.len - 2];
    } else if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) {
        unit = .px; number = value[0 .. value.len - 2];
    } else if (std.mem.endsWith(u8, value, "%")) {
        unit = .percent; number = value[0 .. value.len - 1];
    }
    if (!cssNumber(number)) {
        // Preserve unrepresented length units rather than treating a possible
        // valid future unit as an ignorable declaration.
        if (value.len != 0 and (std.ascii.isDigit(value[0]) or value[0] == '+' or value[0] == '-' or value[0] == '.')) return .unknown;
        return .invalid;
    }
    if (number[0] == '-' and nonzeroMantissa(number)) return .invalid;
    const parsed = std.fmt.parseFloat(f64, number) catch return .unknown;
    if (!std.math.isFinite(parsed) or (parsed == 0 and nonzeroMantissa(number))) return .unknown;
    const scalar = parsed / (if (unit == .percent) @as(f64, 100) else 1);
    if (scalar < 0) return .invalid;
    if (scalar > std.math.floatMax(f32) or (parsed > 0 and scalar == 0)) return .unknown;
    const result: f32 = @floatCast(scalar);
    if (scalar > 0 and result == 0) return .unknown;
    return .{ .known = switch (unit) {
        .number => .{ .multiplier = result },
        .px => .{ .css_px = result },
        .em, .percent => .{ .owner_relative = result },
        .rem => .{ .root_relative = result },
    } };
}

fn cellFontMetricKnown(comptime Basis: type, metric: FontMetric(Basis)) bool {
    return metric.isValid() and metric.value != null and (metric.basis == .normal_body or metric.basis == .css_px);
}
fn cellHeightValueValid(comptime Model: type, height: Model.CellLineHeightValue) bool {
    return switch (height) {
        .normal => true,
        .multiplier => |factor| valid(factor),
        .length => |length| valid(length.value) and
            (length.font_scale_basis == .normal_body or length.font_scale_basis == .css_px),
    };
}

/// The caller proves non-size owner context equality independently. No emitted
/// child run, native default, title or numeric equality grants that authority.
pub fn resolveCellLineHeight(comptime Model: type, specified: CellLineHeightSpecified,
    owner: FontMetric(Model.FontScaleBasis), native_owner: ?FontMetric(Model.FontScaleBasis),
    root: ?FontMetric(Model.FontScaleBasis), inherited: ?Model.CellLineHeightValue,
    owner_context_matches: bool) error{InvalidFontScale, UnresolvedFontOrigin, UnresolvedCellContext, UnresolvedLineHeight}!Model.CellLineHeight
{
    if (!owner_context_matches) return error.UnresolvedCellContext;
    if (!owner.isValid()) return error.InvalidFontScale;
    if (!cellFontMetricKnown(Model.FontScaleBasis, owner)) return error.UnresolvedFontOrigin;
    const height: Model.CellLineHeightValue = switch (specified) {
        .normal => .normal,
        .inherit => inherited orelse return error.UnresolvedLineHeight,
        .multiplier => |factor| .{ .multiplier = factor },
        .css_px => |pixels| .{ .length = .{ .value = pixels, .font_scale_basis = .css_px } },
        .owner_relative => |factor| fixed: {
            const metric = try owner.relative(factor);
            break :fixed .{ .length = .{ .value = metric.value.?, .font_scale_basis = metric.basis } };
        },
        .root_relative => |factor| fixed: {
            const origin = root orelse return error.UnresolvedFontOrigin;
            if (!origin.isValid()) return error.InvalidFontScale;
            if (!cellFontMetricKnown(Model.FontScaleBasis, origin)) return error.UnresolvedFontOrigin;
            const metric = try origin.relative(factor);
            break :fixed .{ .length = .{ .value = metric.value.?, .font_scale_basis = metric.basis } };
        },
    };
    if (!cellHeightValueValid(Model, height)) return error.UnresolvedLineHeight;
    var strut: ?Model.CellTextStrut = .{ .font_scale = owner.value.?, .font_scale_basis = owner.basis };
    if (native_owner) |native| {
        if (!native.isValid()) return error.InvalidFontScale;
        if (cellFontMetricKnown(Model.FontScaleBasis, native) and native.basis == owner.basis and native.value.? == owner.value.?) strut = null;
    }
    return .{ .strut = strut, .height = height };
}

const CellHeightMathTest = struct {
    const FontScaleBasis = enum { context, normal_body, css_px };
    const ComputedLineHeight = struct { value: f32, font_scale_basis: FontScaleBasis };
    const CellTextStrut = struct { font_scale: f32, font_scale_basis: FontScaleBasis };
    const CellLineHeightValue = union(enum) { normal, multiplier: f32, length: ComputedLineHeight };
    const CellLineHeight = struct { strut: ?CellTextStrut = null, height: CellLineHeightValue };
    const Metric = FontMetric(FontScaleBasis);
};

test "cell line height parser preserves number percent em rem and pixel origins" {
    const cases = [_]struct { source: []const u8, expected: CellLineHeightSpecified }{
        .{ .source = "normal", .expected = .normal }, .{ .source = "INITIAL", .expected = .normal },
        .{ .source = "inherit", .expected = .inherit }, .{ .source = "unset", .expected = .inherit },
        .{ .source = "1.25", .expected = .{ .multiplier = 1.25 } },
        .{ .source = " 100% ", .expected = .{ .owner_relative = 1 } },
        .{ .source = "150%", .expected = .{ .owner_relative = 1.5 } },
        .{ .source = "+.5EM", .expected = .{ .owner_relative = 0.5 } },
        .{ .source = "1.5rem", .expected = .{ .root_relative = 1.5 } },
        .{ .source = "+1.2e1PX", .expected = .{ .css_px = 12 } },
        .{ .source = "0", .expected = .{ .multiplier = 0 } },
        .{ .source = "-0%", .expected = .{ .owner_relative = 0 } },
        .{ .source = "0rem", .expected = .{ .root_relative = 0 } },
    };
    for (cases) |case| {
        const got = parseCellLineHeight(case.source);
        try std.testing.expect(got == .known);
        try std.testing.expectEqualDeep(case.expected, got.known);
    }
    for ([_][]const u8{ "-1", "-1%", "-1px", "-1rem", "none", "NaN" }) |source|
        try std.testing.expect(parseCellLineHeight(source) == .invalid);
    for ([_][]const u8{ "var(--h)", "calc(100% + 2px)", "1/**/px", "1 px", "1e-999em", "1e999px", "1pt", "1lh", "revert", "revert-layer", "100%!important" }) |source|
        try std.testing.expect(parseCellLineHeight(source) == .unknown);
}

test "cell footer percentage fixes height before nested child fonts and unitless remains inherited" {
    const M = CellHeightMathTest; const Metric = M.Metric;
    const owner = try Metric.normalBody(0.7); const native = try Metric.normalBody(1);
    const height = try resolveCellLineHeight(M, parseCellLineHeight("100%").known, owner, native, null, null, true);
    try std.testing.expectEqualDeep(@as(?M.CellTextStrut, .{ .font_scale = 0.7, .font_scale_basis = .normal_body }), height.strut);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .length = .{ .value = 0.7, .font_scale_basis = .normal_body } }, height.height);
    const child = try owner.relative(2);
    const inherited_fixed = try resolveCellLineHeight(M, .inherit, child, native, null, height.height, true);
    try std.testing.expectEqualDeep(height.height, inherited_fixed.height);
    const number = try resolveCellLineHeight(M, .{ .multiplier = 1 }, owner, native, null, null, true);
    const inherited_number = try resolveCellLineHeight(M, .inherit, child, native, null, number.height, true);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .multiplier = 1 }, inherited_number.height);
    try std.testing.expectEqual(@as(?f32, 1.4), child.value);
    const reset = try resolveCellLineHeight(M, .normal, child, native, null, height.height, true);
    try std.testing.expect(reset.height == .normal);
}

test "cell fixed lengths retain independent css pixel root and body metrics without division" {
    const M = CellHeightMathTest; const Metric = M.Metric;
    const owner = try Metric.cssPixels(12); const root = try Metric.normalBody(1.25);
    const own = try resolveCellLineHeight(M, .{ .owner_relative = 1.5 }, owner, null, root, null, true);
    const rem = try resolveCellLineHeight(M, .{ .root_relative = 1.5 }, owner, null, root, null, true);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .length = .{ .value = 18, .font_scale_basis = .css_px } }, own.height);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .length = .{ .value = 1.875, .font_scale_basis = .normal_body } }, rem.height);
    const pixels = try resolveCellLineHeight(M, .{ .css_px = 12.5 }, try owner.relative(2), null, root, null, true);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .length = .{ .value = 12.5, .font_scale_basis = .css_px } }, pixels.height);
    const zero = try Metric.cssPixels(0);
    const zero_rem = try resolveCellLineHeight(M, .{ .root_relative = 9 }, owner, null, zero, null, true);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .length = .{ .value = 0, .font_scale_basis = .css_px } }, zero_rem.height);
}

test "cell owner context root and inherited uncertainty do not acquire numeric authority" {
    const M = CellHeightMathTest; const Metric = M.Metric; const owner = try Metric.normalBody(1);
    try std.testing.expectError(error.UnresolvedCellContext, resolveCellLineHeight(M, .normal, owner, owner, null, null, false));
    try std.testing.expectError(error.UnresolvedFontOrigin, resolveCellLineHeight(M, .normal, .{}, owner, null, null, true));
    try std.testing.expectError(error.UnresolvedFontOrigin, resolveCellLineHeight(M, .{ .root_relative = 1 }, owner, owner, null, null, true));
    try std.testing.expectError(error.UnresolvedFontOrigin, resolveCellLineHeight(M, .{ .root_relative = 1 }, owner, owner, Metric{}, null, true));
    try std.testing.expectError(error.UnresolvedLineHeight, resolveCellLineHeight(M, .inherit, owner, owner, null, null, true));
    try std.testing.expectError(error.UnresolvedLineHeight, resolveCellLineHeight(M, .inherit, owner, owner, null,
        .{ .length = .{ .value = 1, .font_scale_basis = .context } }, true));
    try std.testing.expectError(error.UnresolvedLineHeight, resolveCellLineHeight(M, .{ .multiplier = -1 }, owner, owner, null, null, true));
    try std.testing.expectError(error.InvalidFontScale, resolveCellLineHeight(M, .{ .owner_relative = 2 }, try Metric.normalBody(std.math.floatMax(f32)), owner, null, null, true));
}

test "cell strut null zero fractional and origins remain distinguishable" {
    const M = CellHeightMathTest; const Metric = M.Metric;
    const zero = try Metric.normalBody(0); const native = try Metric.normalBody(1);
    const explicit_zero = try resolveCellLineHeight(M, .normal, zero, native, null, null, true);
    try std.testing.expectEqualDeep(@as(?M.CellTextStrut, .{ .font_scale = 0, .font_scale_basis = .normal_body }), explicit_zero.strut);
    const existing_zero = try resolveCellLineHeight(M, .normal, zero, zero, null, null, true);
    try std.testing.expect(existing_zero.strut == null);
    const different_origin_zero = try resolveCellLineHeight(M, .normal, try Metric.cssPixels(0), zero, null, null, true);
    try std.testing.expect(different_origin_zero.strut != null);
    const same = try resolveCellLineHeight(M, .{ .multiplier = 0 }, native, native, null, null, true);
    try std.testing.expect(same.strut == null);
    try std.testing.expectEqualDeep(M.CellLineHeightValue{ .multiplier = 0 }, same.height);
}
