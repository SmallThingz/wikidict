const std = @import("std");
const rt = @import("vm_runtime.zig");
const Value = rt.Value;

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alternate: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    code: u8,
};

fn stringValue(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number => |n| try rt.numberToString(a, n),
        else => error.StringExpected,
    };
}

fn numberValue(v: Value) !f64 {
    return rt.toNumber(v) orelse error.NumberExpected;
}

fn integerValue(v: Value) !i64 {
    return @intFromFloat(@trunc(try numberValue(v)));
}
fn appendPadding(out: *std.ArrayList(u8), a: std.mem.Allocator, count: usize, byte: u8) !void {
    try out.ensureUnusedCapacity(a, count);
    for (0..count) |_| out.appendAssumeCapacity(byte);
}

fn appendPadded(out: *std.ArrayList(u8), a: std.mem.Allocator, raw: []const u8, spec: Spec, numeric: bool) !void {
    if (raw.len >= spec.width) return out.appendSlice(a, raw);
    const pad = spec.width - raw.len;
    if (spec.left) {
        try out.appendSlice(a, raw);
        return appendPadding(out, a, pad, ' ');
    }
    if (numeric and spec.zero) {
        var prefix_len: usize = 0;
        if (raw.len != 0 and (raw[0] == '-' or raw[0] == '+' or raw[0] == ' ')) prefix_len = 1;
        if (raw.len >= prefix_len + 2 and raw[prefix_len] == '0' and
            (raw[prefix_len + 1] == 'x' or raw[prefix_len + 1] == 'X')) prefix_len += 2;
        try out.appendSlice(a, raw[0..prefix_len]);
        try appendPadding(out, a, pad, '0');
        return out.appendSlice(a, raw[prefix_len..]);
    }
    try appendPadding(out, a, pad, ' ');
    try out.appendSlice(a, raw);
}

fn digit(c: u8) ?usize {
    return if (c >= '0' and c <= '9') c - '0' else null;
}
fn parseSpec(fmt: []const u8, index: *usize) !Spec {
    var spec: Spec = undefined;
    spec = .{ .code = 0 };
    while (index.* < fmt.len) {
        switch (fmt[index.*]) {
            '-' => spec.left = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alternate = true,
            '0' => spec.zero = true,
            else => break,
        }
        index.* += 1;
    }
    while (index.* < fmt.len) {
        const d = digit(fmt[index.*]) orelse break;
        spec.width = try std.math.add(usize, try std.math.mul(usize, spec.width, 10), d);
        index.* += 1;
    }
    if (index.* < fmt.len and fmt[index.*] == '.') {
        index.* += 1;
        var precision: usize = 0;
        while (index.* < fmt.len) {
            const d = digit(fmt[index.*]) orelse break;
            precision = try std.math.add(usize, try std.math.mul(usize, precision, 10), d);
            index.* += 1;
        }
        spec.precision = precision;
    }
    if (index.* >= fmt.len) return error.InvalidFormat;
    spec.code = fmt[index.*];
    index.* += 1;
    return spec;
}
fn unsignedDigits(buf: []u8, value: u64, base: u8, upper: bool) []const u8 {
    const alphabet = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var n = value;
    var pos = buf.len;
    while (true) {
        pos -= 1;
        buf[pos] = alphabet[@intCast(n % base)];
        n /= base;
        if (n == 0) break;
    }
    return buf[pos..];
}

fn formatInteger(a: std.mem.Allocator, value: i64, spec: Spec) ![]const u8 {
    const signed = spec.code == 'd' or spec.code == 'i';
    const base: u8 = switch (spec.code) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    const negative = signed and value < 0;
    const magnitude: u64 = if (negative) @as(u64, @intCast(-(value + 1))) + 1 else @bitCast(value);
    var digits_buf: [64]u8 = undefined;
    const digits = unsignedDigits(&digits_buf, magnitude, base, spec.code == 'X');
    const precision = spec.precision orelse 0;
    const zero_count = if (precision > digits.len) precision - digits.len else 0;
    const prefix = if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
    const alt = if (!spec.alternate) "" else switch (spec.code) {
        'x' => if (magnitude != 0) "0x" else "",
        'X' => if (magnitude != 0) "0X" else "",
        'o' => if (digits[0] != '0') "0" else "",
        else => "",
    };
    const out = try a.alloc(u8, prefix.len + alt.len + zero_count + digits.len);
    var pos: usize = 0;
    @memcpy(out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out[pos..][0..alt.len], alt);
    pos += alt.len;
    @memset(out[pos..][0..zero_count], '0');
    pos += zero_count;
    @memcpy(out[pos..][0..digits.len], digits);
    return out;
}
fn normalizeExponent(a: std.mem.Allocator, raw: []const u8, upper: bool) ![]const u8 {
    const epos = std.mem.indexOfAny(u8, raw, "eE") orelse return a.dupe(u8, raw);
    const mantissa = raw[0..epos];
    const exp_raw = raw[epos + 1 ..];
    var negative = false;
    var pos: usize = 0;
    if (pos < exp_raw.len and (exp_raw[pos] == '-' or exp_raw[pos] == '+')) {
        negative = exp_raw[pos] == '-';
        pos += 1;
    }
    while (pos + 1 < exp_raw.len and exp_raw[pos] == '0') pos += 1;
    const digits = exp_raw[pos..];
    const pad = if (digits.len < 2) 2 - digits.len else 0;
    const out = try a.alloc(u8, mantissa.len + 2 + pad + digits.len);
    @memcpy(out[0..mantissa.len], mantissa);
    out[mantissa.len] = if (upper) 'E' else 'e';
    out[mantissa.len + 1] = if (negative) '-' else '+';
    @memset(out[mantissa.len + 2 ..][0..pad], '0');
    @memcpy(out[mantissa.len + 2 + pad ..], digits);
    return out;
}

fn trimGeneral(raw: []u8) []u8 {
    const epos = std.mem.indexOfAny(u8, raw, "eE") orelse raw.len;
    const dot = std.mem.indexOfScalar(u8, raw[0..epos], '.') orelse return raw;
    var end = epos;
    while (end > dot + 1 and raw[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    if (epos == raw.len) return raw[0..end];
    const exp_len = raw.len - epos;
    std.mem.copyForwards(u8, raw[end .. end + exp_len], raw[epos..]);
    return raw[0 .. end + exp_len];
}
fn signedFloatAlloc(a: std.mem.Allocator, raw: []const u8, value: f64, spec: Spec) ![]const u8 {
    if (std.math.signbit(value) or (!spec.plus and !spec.space)) return a.dupe(u8, raw);
    const prefix: u8 = if (spec.plus) '+' else ' ';
    const out = try a.alloc(u8, raw.len + 1);
    out[0] = prefix;
    @memcpy(out[1..], raw);
    return out;
}

fn ensureDecimalPoint(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const epos = std.mem.indexOfAny(u8, raw, "eE") orelse raw.len;
    if (std.mem.indexOfScalar(u8, raw[0..epos], '.') != null) return a.dupe(u8, raw);
    const out = try a.alloc(u8, raw.len + 1);
    @memcpy(out[0..epos], raw[0..epos]);
    out[epos] = '.';
    @memcpy(out[epos + 1 ..], raw[epos..]);
    return out;
}

fn roundEvenInteger(x: f64) f64 {
    if (!std.math.isFinite(x)) return x;
    const lo = @floor(x);
    const frac = x - lo;
    if (frac < 0.5) return lo;
    if (frac > 0.5) return lo + 1.0;
    const half = lo / 2.0;
    return if (half == @floor(half)) lo else lo + 1.0;
}

fn roundDecimalEven(value: f64, places: i32) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    if (places > 308 or places < -308) return value;
    const scale = std.math.pow(f64, 10.0, @floatFromInt(places));
    if (!std.math.isFinite(scale) or scale == 0) return value;
    const scaled = value * scale;
    if (!std.math.isFinite(scaled)) return value;
    return roundEvenInteger(scaled) / scale;
}

fn formatFloat(a: std.mem.Allocator, value: f64, spec: Spec) ![]const u8 {
    var buf: [400]u8 = undefined;
    const precision = spec.precision orelse 6;
    const lower = spec.code == 'e' or spec.code == 'f' or spec.code == 'g';
    var rendered: []const u8 = undefined;
    var general = false;
    switch (spec.code) {
        'f' => rendered = try std.fmt.float.render(&buf, roundDecimalEven(value, @intCast(precision)), .{ .mode = .decimal, .precision = precision }),
        'e', 'E' => {
            const exp: i32 = if (value == 0 or !std.math.isFinite(value)) 0 else @intFromFloat(@floor(@log10(@abs(value))));
            rendered = try std.fmt.float.render(&buf, roundDecimalEven(value, @as(i32, @intCast(precision)) - exp), .{ .mode = .scientific, .precision = precision });
        },
        'g', 'G' => {
            general = true;
            const p = if (precision == 0) 1 else precision;
            const abs = @abs(value);
            const exponent: i32 = if (abs == 0 or !std.math.isFinite(abs)) 0 else @intFromFloat(@floor(@log10(abs)));
            if (exponent < -4 or exponent >= @as(i32, @intCast(p)))
                rendered = try std.fmt.float.render(&buf, roundDecimalEven(value, @as(i32, @intCast(p - 1)) - exponent), .{ .mode = .scientific, .precision = p - 1 })
            else {
                const frac: usize = if (exponent >= 0 and @as(usize, @intCast(exponent + 1)) >= p) 0 else @intCast(@as(i32, @intCast(p)) - exponent - 1);
                rendered = try std.fmt.float.render(&buf, roundDecimalEven(value, @intCast(frac)), .{ .mode = .decimal, .precision = frac });
            }
        },
        else => return error.InvalidFormat,
    }
    const mutable = try a.dupe(u8, rendered);
    if (!lower) {
        for (mutable) |*c| {
            if (c.* >= 'a' and c.* <= 'z') c.* = std.ascii.toUpper(c.*);
        }
    }
    var owned: []const u8 = if (general and !spec.alternate) trimGeneral(mutable) else mutable;
    if (spec.alternate) owned = try ensureDecimalPoint(a, owned);
    if (spec.code == 'e' or spec.code == 'E' or ((spec.code == 'g' or spec.code == 'G') and std.mem.indexOfAny(u8, owned, "eE") != null))
        owned = try normalizeExponent(a, owned, !lower);
    return signedFloatAlloc(a, owned, value, spec);
}
fn quoteLua(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (text) |c| switch (c) {
        '"', '\\' => {
            try out.append(a, '\\');
            try out.append(a, c);
        },
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        0 => try out.appendSlice(a, "\\000"),
        else => if (c < 32 or c == 127) {
            var buf: [4]u8 = undefined;
            const piece = try std.fmt.bufPrint(&buf, "\\{d:0>3}", .{c});
            try out.appendSlice(a, piece);
        } else try out.append(a, c),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

fn formatOne(a: std.mem.Allocator, value: Value, spec: Spec) ![]const u8 {
    const raw: []const u8 = switch (spec.code) {
        's' => blk: {
            const text = try stringValue(a, value);
            break :blk if (spec.precision) |p| text[0..@min(p, text.len)] else text;
        },
        'q' => try quoteLua(a, try stringValue(a, value)),
        'c' => blk: {
            const n = try integerValue(value);
            if (n < 0 or n > 255) return error.InvalidCharacter;
            const out = try a.alloc(u8, 1);
            out[0] = @intCast(n);
            break :blk out;
        },
        'd', 'i', 'o', 'u', 'x', 'X' => try formatInteger(a, try integerValue(value), spec),
        'e', 'E', 'f', 'g', 'G' => try formatFloat(a, try numberValue(value), spec),
        else => return error.InvalidFormat,
    };
    return appendPaddedOwned(a, raw, spec, spec.code != 's' and spec.code != 'q' and spec.code != 'c');
}

fn appendPaddedOwned(a: std.mem.Allocator, raw: []const u8, spec: Spec, numeric: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendPadded(&out, a, raw, spec, numeric and spec.precision == null);
    return out.toOwnedSlice(a);
}
pub fn format(a: std.mem.Allocator, args: []const Value) ![]const u8 {
    if (args.len == 0) return error.MissingArgument;
    const fmt = try stringValue(a, args[0]);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var arg_index: usize = 1;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try out.append(a, fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            try out.append(a, '%');
            i += 1;
            continue;
        }
        const spec = try parseSpec(fmt, &i);
        if (arg_index >= args.len) return error.MissingArgument;
        const piece = try formatOne(a, args[arg_index], spec);
        arg_index += 1;
        try out.appendSlice(a, piece);
    }
    return out.toOwnedSlice(a);
}

fn expectFormat(expected: []const u8, fmt: []const u8, args: []const Value) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all = try arena.allocator().alloc(Value, args.len + 1);
    all[0] = .{ .string = fmt };
    @memcpy(all[1..], args);
    try std.testing.expectEqualStrings(expected, try format(arena.allocator(), all));
}
test "Lua string.format core conversions" {
    try expectFormat("x 12 0x1f 00007 1.23 1.234e+03 1234 %", "%s %d %#x %05d %.2f %.3e %.4g %%", &.{
        .{ .string = "x" },   .{ .number = 12 },     .{ .number = 31 },     .{ .number = 7 },
        .{ .number = 1.234 }, .{ .number = 1234.5 }, .{ .number = 1234.5 },
    });
    try expectFormat("   +1.50", "%+8.2f", &.{.{ .number = 1.5 }});
    try expectFormat("x    !", "%-5s!", &.{.{ .string = "x" }});
}
