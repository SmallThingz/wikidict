const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const ustring_lib = @import("ustring.zig");

const Value = rt.Value;

pub const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
};

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn floorDiv(a: i64, b: i64) i64 {
    return @divFloor(a, b);
}
pub fn daysFromCivil(year_raw: i64, month: u8, day: u8) i64 {
    var year = year_raw;
    year -= if (month <= 2) 1 else 0;
    const era = floorDiv(year, 400);
    const yoe = year - era * 400;
    const m: i64 = month;
    const mp: i64 = m + (if (month > 2) @as(i64, -3) else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days_raw: i64) Civil {
    const z = days_raw + 719468;
    const era = floorDiv(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month_i: i64 = mp + (if (mp < 10) @as(i64, 3) else -9);
    const month: u8 = @intCast(month_i);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = month, .day = day };
}
pub fn civilFromUnix(timestamp: i64) Civil {
    const days = floorDiv(timestamp, std.time.s_per_day);
    const seconds = timestamp - days * std.time.s_per_day;
    var out = civilFromDays(days);
    out.hour = @intCast(@divFloor(seconds, std.time.s_per_hour));
    out.minute = @intCast(@divFloor(@mod(seconds, std.time.s_per_hour), std.time.s_per_min));
    out.second = @intCast(@mod(seconds, std.time.s_per_min));
    return out;
}

fn unixFromCivil(civil: Civil) !i64 {
    if (civil.month < 1 or civil.month > 12 or civil.day < 1) return error.InvalidDate;
    const month: std.time.epoch.Month = @enumFromInt(civil.month);
    if (civil.year < 1 or civil.year > std.math.maxInt(std.time.epoch.Year)) return error.InvalidDate;
    const days_in_month = std.time.epoch.getDaysInMonth(@intCast(civil.year), month);
    if (civil.day > days_in_month or civil.hour > 23 or civil.minute > 59 or civil.second > 59)
        return error.InvalidDate;
    return daysFromCivil(civil.year, civil.month, civil.day) * std.time.s_per_day +
        @as(i64, civil.hour) * std.time.s_per_hour +
        @as(i64, civil.minute) * std.time.s_per_min + civil.second;
}

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
fn monthNumber(raw: []const u8) ?u8 {
    if (std.fmt.parseInt(u8, raw, 10)) |n| {
        if (n >= 1 and n <= 12) return n;
    } else |_| {}
    for (month_names, 1..) |name, i| {
        if (std.ascii.eqlIgnoreCase(raw, name) or
            (raw.len == 3 and std.ascii.eqlIgnoreCase(raw, name[0..3])))
            return @intCast(i);
    }
    return null;
}

fn parseHyphenDate(raw: []const u8) ?Civil {
    var fields: [3][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, raw, '-');
    var n: usize = 0;
    while (it.next()) |field| {
        if (field.len == 0 or n == fields.len) return null;
        fields[n] = field;
        n += 1;
    }
    if (n == 2) {
        const year = std.fmt.parseInt(i64, fields[0], 10) catch return null;
        if (year < 1000) return null;
        const month = monthNumber(fields[1]) orelse return null;
        return .{ .year = year, .month = month, .day = 1 };
    }
    if (n != 3) return null;
    const first = std.fmt.parseInt(i64, fields[0], 10) catch return null;
    const third = std.fmt.parseInt(i64, fields[2], 10) catch return null;
    if (first >= 1000) {
        const month = monthNumber(fields[1]) orelse return null;
        const day = std.fmt.parseInt(u8, fields[2], 10) catch return null;
        return .{ .year = first, .month = month, .day = day };
    }
    const day = std.math.cast(u8, first) orelse return null;
    const month = monthNumber(fields[1]) orelse return null;
    return .{ .year = third, .month = month, .day = day };
}

fn parseSpaceDate(raw: []const u8) ?Civil {
    var fields: [3][]const u8 = undefined;
    var it = std.mem.tokenizeAny(u8, raw, " \t,");
    var n: usize = 0;
    while (it.next()) |field| {
        if (n == fields.len) return null;
        fields[n] = field;
        n += 1;
    }
    if (n == 2) {
        if (std.fmt.parseInt(i64, fields[0], 10)) |year| {
            if (year >= 1000) {
                const month = monthNumber(fields[1]) orelse return null;
                return .{ .year = year, .month = month, .day = 1 };
            }
        } else |_| {}
        const year = std.fmt.parseInt(i64, fields[1], 10) catch return null;
        if (year < 1000) return null;
        const month = monthNumber(fields[0]) orelse return null;
        return .{ .year = year, .month = month, .day = 1 };
    }
    if (n != 3) return null;
    const year = std.fmt.parseInt(i64, fields[2], 10) catch return null;
    if (year < 1000) return null;
    if (std.fmt.parseInt(u8, fields[0], 10)) |day| {
        const month = monthNumber(fields[1]) orelse return null;
        return .{ .year = year, .month = month, .day = day };
    } else |_| {}
    const month = monthNumber(fields[0]) orelse return null;
    const day = std.fmt.parseInt(u8, fields[1], 10) catch return null;
    return .{ .year = year, .month = month, .day = day };
}

fn parseDelimitedDate(raw: []const u8) ?Civil {
    return if (std.mem.indexOfScalar(u8, raw, '-') != null)
        parseHyphenDate(raw)
    else
        parseSpaceDate(raw);
}

fn currentUnix(runtime: *const rt.Context) !i64 {
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    return host.now_unix orelse error.MissingCurrentTime;
}

fn addDays(timestamp: i64, count: i64) !i64 {
    const seconds = std.math.mul(i64, count, std.time.s_per_day) catch return error.InvalidDate;
    return std.math.add(i64, timestamp, seconds) catch error.InvalidDate;
}

pub fn parseTimestampText(runtime: *const rt.Context, raw_value: ?[]const u8) !i64 {
    const raw = if (raw_value) |value| std.mem.trim(u8, value, " \t\r\n") else return currentUnix(runtime);
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "now")) return currentUnix(runtime);
    if (raw[0] == '@') return std.fmt.parseInt(i64, raw[1..], 10) catch error.InvalidDate;
    if (std.ascii.eqlIgnoreCase(raw, "today"))
        return floorDiv(try currentUnix(runtime), std.time.s_per_day) * std.time.s_per_day;
    inline for (.{ .{ "now +", @as(i64, 1) }, .{ "now -", @as(i64, -1) } }) |entry| {
        if (std.ascii.startsWithIgnoreCase(raw, entry[0])) {
            const suffix = std.mem.trim(u8, raw[entry[0].len..], " \t\r\n");
            const space = std.mem.indexOfScalar(u8, suffix, ' ') orelse return error.InvalidDate;
            const count = std.fmt.parseInt(i64, suffix[0..space], 10) catch return error.InvalidDate;
            const unit = std.mem.trim(u8, suffix[space + 1 ..], " \t\r\n");
            if (!std.ascii.eqlIgnoreCase(unit, "day") and !std.ascii.eqlIgnoreCase(unit, "days"))
                return error.InvalidDate;
            const signed = std.math.mul(i64, entry[1], count) catch return error.InvalidDate;
            return addDays(try currentUnix(runtime), signed);
        }
    }
    inline for (.{ .{ " +", @as(i64, 1) }, .{ " -", @as(i64, -1) } }) |entry| {
        if (std.mem.lastIndexOf(u8, raw, entry[0])) |at| {
            const base_raw = std.mem.trim(u8, raw[0..at], " \t\r\n");
            const suffix = std.mem.trim(u8, raw[at + entry[0].len ..], " \t\r\n");
            if (base_raw.len != 0) {
                const space = std.mem.indexOfScalar(u8, suffix, ' ') orelse return error.InvalidDate;
                const count = std.fmt.parseInt(i64, suffix[0..space], 10) catch return error.InvalidDate;
                const unit = std.mem.trim(u8, suffix[space + 1 ..], " \t\r\n");
                if (!std.ascii.eqlIgnoreCase(unit, "day") and !std.ascii.eqlIgnoreCase(unit, "days"))
                    return error.InvalidDate;
                const civil = parseDelimitedDate(base_raw) orelse return error.InvalidDate;
                const signed = std.math.mul(i64, entry[1], count) catch return error.InvalidDate;
                return addDays(try unixFromCivil(civil), signed);
            }
        }
    }
    const civil = parseDelimitedDate(raw) orelse return error.InvalidDate;
    return unixFromCivil(civil);
}

fn parseTimestamp(runtime: *const rt.Context, raw_value: ?Value) !i64 {
    if (raw_value == null or raw_value.? == .nil) return parseTimestampText(runtime, null);
    if (raw_value.? != .string) return error.StringExpected;
    return parseTimestampText(runtime, raw_value.?.string);
}

fn writeTwo(out: *std.ArrayList(u8), a: std.mem.Allocator, n: u8) !void {
    try out.append(a, '0' + n / 10);
    try out.append(a, '0' + n % 10);
}

fn appendInt(out: *std.ArrayList(u8), a: std.mem.Allocator, value: anytype) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(a, text);
}
fn appendPadded(out: *std.ArrayList(u8), a: std.mem.Allocator, value: i64, width: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    var pad = if (text.len < width) width - text.len else 0;
    while (pad > 0) : (pad -= 1) try out.append(a, '0');
    try out.appendSlice(a, text);
}

const weekday_names = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};

pub fn weekdaySunday0(timestamp: i64) u8 {
    const days = floorDiv(timestamp, std.time.s_per_day);
    return @intCast(@mod(days + 4, 7));
}

fn dayOfYear(c: Civil) u16 {
    var out: u16 = c.day;
    var month: u8 = 1;
    while (month < c.month) : (month += 1)
        out += std.time.epoch.getDaysInMonth(@intCast(c.year), @enumFromInt(month));
    return out;
}

fn isoWeeksInYear(year: i64) u8 {
    const jan1 = weekdaySunday0(daysFromCivil(year, 1, 1) * std.time.s_per_day);
    const mon1: u8 = if (jan1 == 0) 7 else jan1;
    return if (mon1 == 4 or (mon1 == 3 and std.time.epoch.isLeapYear(@intCast(year)))) 53 else 52;
}
pub fn isoWeek(timestamp: i64, c: Civil) u8 {
    const sunday0 = weekdaySunday0(timestamp);
    const monday1: i64 = if (sunday0 == 0) 7 else sunday0;
    const raw = @divFloor(@as(i64, dayOfYear(c)) - monday1 + 10, 7);
    if (raw < 1) return isoWeeksInYear(c.year - 1);
    const max = isoWeeksInYear(c.year);
    if (raw > max) return 1;
    return @intCast(raw);
}

pub fn formatDateAlloc(a: std.mem.Allocator, timestamp: i64, format: []const u8) ![]const u8 {
    const c = civilFromUnix(timestamp);
    const weekday = weekdaySunday0(timestamp);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        const token = format[i];
        if (token == '\\' and i + 1 < format.len) {
            i += 1;
            try out.append(a, format[i]);
            continue;
        }
        if (token == 'x' and i + 1 < format.len and format[i + 1] == 'g') {
            try out.appendSlice(a, month_names[c.month - 1]);
            i += 1;
            continue;
        }
        switch (token) {
            'U' => try appendInt(&out, a, timestamp),
            'F' => try out.appendSlice(a, month_names[c.month - 1]),
            'M' => try out.appendSlice(a, month_names[c.month - 1][0..3]),
            'j' => try appendInt(&out, a, c.day),
            'd' => try writeTwo(&out, a, c.day),
            'Y' => try appendPadded(&out, a, c.year, 4),
            'm' => try writeTwo(&out, a, c.month),
            'n' => try appendInt(&out, a, c.month),
            'H' => try writeTwo(&out, a, c.hour),
            'i' => try writeTwo(&out, a, c.minute),
            's' => try writeTwo(&out, a, c.second),
            'l' => try out.appendSlice(a, weekday_names[weekday]),
            'w' => try appendInt(&out, a, weekday),
            'W' => try writeTwo(&out, a, isoWeek(timestamp, c)),
            else => try out.append(a, token),
        }
    }
    return out.toOwnedSlice(a);
}

fn setNative(runtime: *rt.Context, table: *rt.Table, name: []const u8, ctx: ?*anyopaque, comptime call: anytype) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(ctx, call));
}
const LanguageCtx = struct { code: []const u8, case_mapper: *ustring_lib.Normalizer };
const LanguageFactoryCtx = struct { case_mapper: *ustring_lib.Normalizer };

fn languageContext(raw: ?*anyopaque) !*LanguageCtx {
    return @ptrCast(@alignCast(raw orelse return error.MissingLanguageContext));
}

fn requireEnglishLocale(raw: ?*anyopaque) !*LanguageCtx {
    const ctx = try languageContext(raw);
    if (!std.mem.eql(u8, ctx.code, "en")) return error.NotImplemented;
    return ctx;
}

fn requireBaseCaseLocale(raw: ?*anyopaque) !*LanguageCtx {
    const ctx = try languageContext(raw);
    if (!std.mem.eql(u8, ctx.code, "en") and !std.mem.eql(u8, ctx.code, "it")) return error.NotImplemented;
    return ctx;
}

fn languageGetCode(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const ctx: *LanguageCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .string = ctx.code });
}

fn languageFormatDate(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const timestamp = try parseTimestamp(runtime, if (args.len > 2) args[2] else null);
    return one(a, .{ .string = try formatDateAlloc(a, timestamp, args[1].string) });
}

fn sourceMethodArg(args: []const Value) ![]const u8 {
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    return args[1].string;
}

fn wmfUcfirstOverride(cp: u21) bool {
    return switch (cp) {
        0xDF, 0x19B, 0x264, 0x1C8A, 0xA7CD, 0xA7CF, 0xA7D3, 0xA7D5, 0xA7DB => true,
        else => (cp >= 0x10D70 and cp <= 0x10D85) or (cp >= 0x16EBB and cp <= 0x16ED3),
    };
}

pub fn firstCaseAlloc(case_mapper: *ustring_lib.Normalizer, a: std.mem.Allocator, source: []const u8, upper: bool) ![]const u8 {
    if (source.len == 0) return source;
    if (source[0] < 0x80) {
        const out = try a.dupe(u8, source);
        out[0] = if (upper) std.ascii.toUpper(out[0]) else std.ascii.toLower(out[0]);
        return out;
    }
    const first_len = try std.unicode.utf8ByteSequenceLength(source[0]);
    if (first_len > source.len) return error.InvalidUtf8;
    const first = source[0..first_len];
    const cp = try std.unicode.utf8Decode(first);
    if (upper and wmfUcfirstOverride(cp)) return source;
    const mapped = try ustring_lib.caseAlloc(case_mapper, a, first, if (upper) .title else .lower);
    if (std.mem.eql(u8, first, mapped)) return source;
    const out = try a.alloc(u8, mapped.len + source.len - first.len);
    @memcpy(out[0..mapped.len], mapped);
    @memcpy(out[mapped.len..], source[first.len..]);
    return out;
}

fn languageUc(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try requireBaseCaseLocale(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try ustring_lib.caseAlloc(ctx.case_mapper, a, try sourceMethodArg(args), .upper) });
}

fn languageLc(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try requireBaseCaseLocale(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try ustring_lib.caseAlloc(ctx.case_mapper, a, try sourceMethodArg(args), .lower) });
}

fn languageUcfirst(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try requireBaseCaseLocale(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try firstCaseAlloc(ctx.case_mapper, a, try sourceMethodArg(args), true) });
}

fn languageLcfirst(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try requireBaseCaseLocale(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try firstCaseAlloc(ctx.case_mapper, a, try sourceMethodArg(args), false) });
}

fn languageGetDir(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = "ltr" });
}
fn languageGetFallbacks(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .table = try runtime.newTable() });
}

fn languageGetArrow(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    const which = try sourceMethodArg(args);
    if (std.ascii.eqlIgnoreCase(which, "forwards")) return one(a, .{ .string = "→" });
    if (std.ascii.eqlIgnoreCase(which, "backwards")) return one(a, .{ .string = "←" });
    return error.InvalidArrowDirection;
}

fn languageGender(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    if (args.len < 3 or args[2] != .table) return error.TableExpected;
    const forms = args[2].table;
    const count = forms.rawLen();
    if (count == 0) return one(a, .{ .string = "" });
    if (count == 1) return one(a, forms.rawGet(.{ .number = 1 }) orelse .nil);
    return error.NotImplemented;
}

fn valueString(a: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .number => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        else => error.NumberExpected,
    };
}
fn formatNumberImpl(a: std.mem.Allocator, raw: []const u8, commafy: bool) ![]const u8 {
    if (raw.len == 0) return raw;
    const minus = "−";
    const sign_len: usize = if (raw[0] == '-' or raw[0] == '+') 1 else if (std.mem.startsWith(u8, raw, minus)) minus.len else 0;
    const negative = raw[0] == '-' or std.mem.startsWith(u8, raw, minus);
    const body = raw[sign_len..];
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    if (std.mem.indexOfScalarPos(u8, body, dot + @intFromBool(dot < body.len), '.') != null) return raw;
    if (dot == 0) return raw;
    for (body[0..dot]) |c| if (!std.ascii.isDigit(c)) return raw;
    if (dot < body.len) for (body[dot + 1 ..]) |c| if (!std.ascii.isDigit(c)) return raw;

    const commas = if (commafy and dot > 3) (dot - 1) / 3 else 0;
    const sign_out_len: usize = if (negative) minus.len else 0;
    if (commas == 0 and sign_out_len == sign_len and (sign_len == 0 or negative and std.mem.startsWith(u8, raw, minus))) return raw;
    const out = try a.alloc(u8, sign_out_len + body.len + commas);
    var dst: usize = 0;
    if (negative) {
        @memcpy(out[0..minus.len], minus);
        dst = minus.len;
    }
    for (body[0..dot], 0..) |c, i| {
        if (commafy and i != 0 and (dot - i) % 3 == 0) {
            out[dst] = ',';
            dst += 1;
        }
        out[dst] = c;
        dst += 1;
    }
    @memcpy(out[dst..], body[dot..]);
    return out;
}

pub fn formatNumberAlloc(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return formatNumberImpl(a, raw, true);
}

pub fn formatNumberNoSeparatorsAlloc(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return formatNumberImpl(a, raw, false);
}

pub fn parseFormattedNumberAlloc(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const minus = "−";
    const has_comma = std.mem.indexOfScalar(u8, raw, ',') != null;
    const localized_minus = std.mem.startsWith(u8, raw, minus);
    if (!has_comma and !localized_minus) return raw;
    var clean: std.ArrayList(u8) = .empty;
    if (localized_minus) {
        try clean.append(a, '-');
        for (raw[minus.len..]) |c| if (c != ',') try clean.append(a, c);
    } else {
        for (raw) |c| if (c != ',') try clean.append(a, c);
    }
    return clean.toOwnedSlice(a);
}

fn languageFormatNum(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    if (args.len < 2) return error.NumberExpected;
    const raw = try valueString(a, args[1]);
    return one(a, .{ .string = try formatNumberAlloc(a, raw) });
}
fn languageParseFormattedNumber(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    const a = runtime.allocator;
    const raw = try sourceMethodArg(args);
    return one(a, .{ .string = try parseFormattedNumberAlloc(a, raw) });
}

fn makeLanguage(runtime: *rt.Context, case_mapper: *ustring_lib.Normalizer, code: []const u8) !*rt.Table {
    const a = runtime.allocator;
    const table = try runtime.newNativeNamespace(.language_value);
    const ctx = try a.create(LanguageCtx);
    ctx.* = .{ .code = code, .case_mapper = case_mapper };
    try table.rawSet(a, .{ .string = "code" }, .{ .string = code });
    try setNative(runtime, table, "getCode", ctx, languageGetCode);
    try setNative(runtime, table, "formatDate", ctx, languageFormatDate);
    try setNative(runtime, table, "uc", ctx, languageUc);
    try setNative(runtime, table, "lc", ctx, languageLc);
    try setNative(runtime, table, "ucfirst", ctx, languageUcfirst);
    try setNative(runtime, table, "lcfirst", ctx, languageLcfirst);
    try setNative(runtime, table, "getDir", ctx, languageGetDir);
    try setNative(runtime, table, "getFallbackLanguages", ctx, languageGetFallbacks);
    try setNative(runtime, table, "getArrow", ctx, languageGetArrow);
    try setNative(runtime, table, "gender", ctx, languageGender);
    try setNative(runtime, table, "formatNum", ctx, languageFormatNum);
    try setNative(runtime, table, "parseFormattedNumber", ctx, languageParseFormattedNumber);
    return table;
}
fn languageNew(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const factory: *LanguageFactoryCtx = @ptrCast(@alignCast(raw orelse return error.MissingLanguageFactory));
    return one(a, .{ .table = try makeLanguage(runtime, factory.case_mapper, args[0].string) });
}

fn getContentLanguage(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const factory: *LanguageFactoryCtx = @ptrCast(@alignCast(raw orelse return error.MissingLanguageFactory));
    return one(a, .{ .table = try makeLanguage(runtime, factory.case_mapper, "en") });
}

fn isKnownLanguageTag(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return one(a, .{ .boolean = false });
    if (std.mem.eql(u8, args[0].string, "en")) return one(a, .{ .boolean = true });
    return error.NotImplemented;
}

fn fetchLanguageName(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    if (std.mem.eql(u8, args[0].string, "en")) return one(a, .{ .string = "English" });
    return error.NotImplemented;
}
fn getFallbacksFor(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    if (!std.mem.eql(u8, args[0].string, "en")) return error.NotImplemented;
    return one(a, .{ .table = try runtime.newTable() });
}

pub fn install(runtime: *rt.Context, mw: *rt.Table, case_mapper: *ustring_lib.Normalizer) !void {
    const factory = try runtime.allocator.create(LanguageFactoryCtx);
    factory.* = .{ .case_mapper = case_mapper };
    const language = try runtime.newNativeNamespace(.language);
    try setNative(runtime, language, "new", factory, languageNew);
    try setNative(runtime, language, "getContentLanguage", factory, getContentLanguage);
    try setNative(runtime, language, "getFallbacksFor", null, getFallbacksFor);
    try setNative(runtime, language, "isKnownLanguageTag", null, isKnownLanguageTag);
    try setNative(runtime, language, "fetchLanguageName", null, fetchLanguageName);
    try mw.rawSet(runtime.allocator, .{ .string = "language" }, .{ .table = language });
    try setNative(runtime, mw, "getContentLanguage", factory, getContentLanguage);
    try setNative(runtime, mw, "getLanguage", factory, languageNew);
}

test "civil conversion round trips unix epoch and leap dates" {
    try std.testing.expectEqual(@as(i64, 0), try unixFromCivil(.{ .year = 1970, .month = 1, .day = 1 }));
    try std.testing.expectEqual(Civil{ .year = 2024, .month = 2, .day = 29 }, civilFromUnix(try unixFromCivil(.{ .year = 2024, .month = 2, .day = 29 })));
}
test "MediaWiki date formats used by was-wotd" {
    const ts = try unixFromCivil(.{ .year = 2022, .month = 12, .day = 12 });
    try std.testing.expectEqual(@as(i64, 1_670_803_200), ts);
    const f = try formatDateAlloc(std.testing.allocator, ts, "F j Y U");
    defer std.testing.allocator.free(f);
    try std.testing.expectEqualStrings("December 12 2022 1670803200", f);
}

test "MediaWiki partial and word date grammar" {
    var ctx = try rt.Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "1864-9", .expected = "1864-09-01" },
        .{ .raw = "1864-Sep", .expected = "1864-09-01" },
        .{ .raw = "September 1864", .expected = "1864-09-01" },
        .{ .raw = "1864 September", .expected = "1864-09-01" },
        .{ .raw = "July 1 2022", .expected = "2022-07-01" },
        .{ .raw = "1 July 2022", .expected = "2022-07-01" },
    };
    for (cases) |case| {
        const ts = try parseTimestamp(&ctx, .{ .string = case.raw });
        const got = try formatDateAlloc(std.testing.allocator, ts, "Y-m-d");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
    try std.testing.expectError(error.InvalidDate, parseTimestamp(&ctx, .{ .string = "2022 July 1" }));
    const shifted = try parseTimestampText(&ctx, "2013-3-31 +8 days");
    const shifted_text = try formatDateAlloc(std.testing.allocator, shifted, "Y M d");
    defer std.testing.allocator.free(shifted_text);
    try std.testing.expectEqualStrings("2013 Apr 08", shifted_text);
}

test "parse date forms used by Wiktionary modules" {
    var ctx = try rt.Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    const a = std.testing.allocator;
    const a_ts = try parseTimestamp(&ctx, Value{ .string = "12-December-2022" });
    const b_ts = try parseTimestamp(&ctx, Value{ .string = "2022-12-12" });
    try std.testing.expectEqual(a_ts, b_ts);
    const out = try formatDateAlloc(a, a_ts, "YmdHis");
    defer a.free(out);
    try std.testing.expectEqualStrings("20221212000000", out);
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT language objects expose MediaWiki helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .now_unix = 1_670_803_200 };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    const ustring = try runtime.newNativeNamespace(.ustring);
    const case_mapper = try ustring_lib.install(&runtime, ustring);
    try install(&runtime, mw, case_mapper);

    const content = try callField(&runtime, .{ .table = mw }, "getContentLanguage", &.{});
    defer rt.freeResults(content);
    const language = content[0];
    const code = try callField(&runtime, language, "getCode", &.{language});
    defer rt.freeResults(code);
    try std.testing.expectEqualStrings("en", code[0].string);
    const dated = try callField(&runtime, language, "formatDate", &.{ language, .{ .string = "Y-m-d" }, .{ .string = "now" } });
    defer rt.freeResults(dated);
    try std.testing.expectEqualStrings("2022-12-12", dated[0].string);
    const formatted = try callField(&runtime, language, "formatNum", &.{ language, .{ .number = 12345.67 } });
    defer rt.freeResults(formatted);
    try std.testing.expectEqualStrings("12,345.67", formatted[0].string);
    const formatted_negative = try callField(&runtime, language, "formatNum", &.{ language, .{ .string = "-1234" } });
    defer rt.freeResults(formatted_negative);
    try std.testing.expectEqualStrings("−1,234", formatted_negative[0].string);
    const parsed = try callField(&runtime, language, "parseFormattedNumber", &.{ language, .{ .string = "−12,345.67" } });
    defer rt.freeResults(parsed);
    try std.testing.expectEqualStrings("-12345.67", parsed[0].string);
    const upper = try callField(&runtime, language, "uc", &.{ language, .{ .string = "straße ﬃ" } });
    defer rt.freeResults(upper);
    try std.testing.expectEqualStrings("STRASSE FFI", upper[0].string);
    const lower = try callField(&runtime, language, "lc", &.{ language, .{ .string = "ÉCLAIR İ ΣΊΣΥΦΟΣ" } });
    defer rt.freeResults(lower);
    try std.testing.expectEqualStrings("éclair i̇ σίσυφος", lower[0].string);
    const ucfirst = try callField(&runtime, language, "ucfirst", &.{ language, .{ .string = "hello" } });
    defer rt.freeResults(ucfirst);
    try std.testing.expectEqualStrings("Hello", ucfirst[0].string);
    const ucfirst_fn = try runtime.getIndex(language, .{ .string = "ucfirst" });
    const accented = try runtime.callValue(ucfirst_fn, &.{ language, .{ .string = "éclair" } });
    defer rt.freeResults(accented);
    try std.testing.expectEqualStrings("Éclair", accented[0].string);
    const eszett = try runtime.callValue(ucfirst_fn, &.{ language, .{ .string = "ßeta" } });
    defer rt.freeResults(eszett);
    try std.testing.expectEqualStrings("ßeta", eszett[0].string);
    const composed_title = try runtime.callValue(ucfirst_fn, &.{ language, .{ .string = "ǰfoo" } });
    defer rt.freeResults(composed_title);
    try std.testing.expectEqualStrings("J̌foo", composed_title[0].string);

    const italian = try callField(&runtime, .{ .table = mw }, "getLanguage", &.{.{ .string = "it" }});
    defer rt.freeResults(italian);
    const italian_code = try callField(&runtime, italian[0], "getCode", &.{italian[0]});
    defer rt.freeResults(italian_code);
    try std.testing.expectEqualStrings("it", italian_code[0].string);
    const italian_ucfirst = try runtime.getIndex(italian[0], .{ .string = "ucfirst" });
    inline for (.{ .{ "istanza", "Istanza" }, .{ "éclair", "Éclair" }, .{ "ßeta", "ßeta" }, .{ "ǰfoo", "J̌foo" } }) |case| {
        const result = try runtime.callValue(italian_ucfirst, &.{ italian[0], .{ .string = case[0] } });
        defer rt.freeResults(result);
        try std.testing.expectEqualStrings(case[1], result[0].string);
    }

    const language_api = mw.rawGet(.{ .string = "language" }).?.table;
    const known = try callField(&runtime, .{ .table = language_api }, "isKnownLanguageTag", &.{.{ .string = "en" }});
    defer rt.freeResults(known);
    try std.testing.expect(known[0].boolean);
    const known_fn = try runtime.getIndex(.{ .table = language_api }, .{ .string = "isKnownLanguageTag" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(known_fn, &.{.{ .string = "fr" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
    const english_name = try callField(&runtime, .{ .table = language_api }, "fetchLanguageName", &.{.{ .string = "en" }});
    defer rt.freeResults(english_name);
    try std.testing.expectEqualStrings("English", english_name[0].string);
    const french = try callField(&runtime, .{ .table = language_api }, "new", &.{.{ .string = "fr" }});
    defer rt.freeResults(french);
    const french_code = try callField(&runtime, french[0], "getCode", &.{french[0]});
    defer rt.freeResults(french_code);
    try std.testing.expectEqualStrings("fr", french_code[0].string);
    const upper_fn = try runtime.getIndex(french[0], .{ .string = "uc" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(upper_fn, &.{ french[0], .{ .string = "abc" } }));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
}
