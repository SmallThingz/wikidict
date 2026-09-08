const std = @import("std");
const rt = @import("vm_runtime.zig");

const Value = rt.Value;

const Context = struct {
    io: std.Io,
};

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
fn daysFromCivil(year_raw: i64, month: u8, day: u8) i64 {
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

pub const ParsedExplicitDate = struct {
    civil: Civil,
    timestamp: i64,
    has_day: bool,
};

pub fn parseExplicitDate(raw_value: []const u8) !ParsedExplicitDate {
    const raw = std.mem.trim(u8, raw_value, " \t\r\n");
    const civil = parseDelimitedDate(raw) orelse return error.InvalidDate;
    var fields: usize = 0;
    if (std.mem.indexOfScalar(u8, raw, '-') != null) {
        var it = std.mem.splitScalar(u8, raw, '-');
        while (it.next()) |_| fields += 1;
    } else {
        var it = std.mem.tokenizeAny(u8, raw, " \t,");
        while (it.next()) |_| fields += 1;
    }
    return .{ .civil = civil, .timestamp = try unixFromCivil(civil), .has_day = fields == 3 };
}

fn currentUnix(ctx: *const Context) i64 {
    return std.Io.Clock.real.now(ctx.io).toSeconds();
}

fn parseTimestamp(ctx: *const Context, raw_value: ?Value) !i64 {
    if (raw_value == null or raw_value.? == .nil) return currentUnix(ctx);
    if (raw_value.? != .string) return error.StringExpected;
    const raw = std.mem.trim(u8, raw_value.?.string, " \t\r\n");
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "now")) return currentUnix(ctx);
    if (raw[0] == '@') return std.fmt.parseInt(i64, raw[1..], 10) catch error.InvalidDate;
    if (std.ascii.eqlIgnoreCase(raw, "today"))
        return floorDiv(currentUnix(ctx), std.time.s_per_day) * std.time.s_per_day;
    inline for (.{ .{ "now +", @as(i64, 1) }, .{ "now -", @as(i64, -1) } }) |entry| {
        if (std.ascii.startsWithIgnoreCase(raw, entry[0])) {
            const suffix = std.mem.trim(u8, raw[entry[0].len..], " \t\r\n");
            const space = std.mem.indexOfScalar(u8, suffix, ' ') orelse return error.InvalidDate;
            const count = std.fmt.parseInt(i64, suffix[0..space], 10) catch return error.InvalidDate;
            const unit = std.mem.trim(u8, suffix[space + 1 ..], " \t\r\n");
            if (!std.ascii.eqlIgnoreCase(unit, "day") and !std.ascii.eqlIgnoreCase(unit, "days"))
                return error.InvalidDate;
            return currentUnix(ctx) + entry[1] * count * std.time.s_per_day;
        }
    }
    const civil = parseDelimitedDate(raw) orelse return error.InvalidDate;
    return unixFromCivil(civil);
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

fn formatDateAlloc(a: std.mem.Allocator, timestamp: i64, format: []const u8) ![]const u8 {
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

fn setNative(a: std.mem.Allocator, table: *rt.Table, name: []const u8, ctx: ?*anyopaque, call: rt.NativeCall) !void {
    try table.rawSet(a, .{ .string = name }, try rt.newNative(a, ctx, call));
}
const LanguageCtx = struct {
    host: *Context,
    code: []const u8,
};

fn languageGetCode(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *LanguageCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .string = ctx.code });
}

fn languageFormatDate(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *LanguageCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const timestamp = try parseTimestamp(ctx.host, if (args.len > 2) args[2] else null);
    return one(a, .{ .string = try formatDateAlloc(a, timestamp, args[1].string) });
}

fn sourceMethodArg(args: []const Value) ![]const u8 {
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    return args[1].string;
}

fn asciiCaseAlloc(a: std.mem.Allocator, source: []const u8, upper: bool, first_only: bool) ![]const u8 {
    const out = try a.dupe(u8, source);
    if (first_only) {
        if (out.len != 0 and out[0] < 0x80) out[0] = if (upper) std.ascii.toUpper(out[0]) else std.ascii.toLower(out[0]);
        return out;
    }
    for (out) |*c| if (c.* < 0x80) {
        c.* = if (upper) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    };
    return out;
}

fn languageUc(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .string = try asciiCaseAlloc(a, try sourceMethodArg(args), true, false) });
}

fn languageLc(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .string = try asciiCaseAlloc(a, try sourceMethodArg(args), false, false) });
}

fn languageUcfirst(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .string = try asciiCaseAlloc(a, try sourceMethodArg(args), true, true) });
}

fn languageLcfirst(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .string = try asciiCaseAlloc(a, try sourceMethodArg(args), false, true) });
}

fn languageGetDir(_: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    return one(a, .{ .string = "ltr" });
}
fn languageGetFallbacks(_: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const table = try rt.newTable(a);
    try table.append(a, .{ .string = "en" });
    return one(a, .{ .table = table });
}

fn languageGetArrow(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const which = try sourceMethodArg(args);
    if (std.ascii.eqlIgnoreCase(which, "forwards")) return one(a, .{ .string = "→" });
    if (std.ascii.eqlIgnoreCase(which, "backwards")) return one(a, .{ .string = "←" });
    return error.InvalidArrowDirection;
}

fn languageGender(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 3 or args[2] != .table) return error.TableExpected;
    const forms = args[2].table;
    const first = forms.rawGet(.{ .number = 1 }) orelse Value.nil;
    return one(a, first);
}

fn valueString(a: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .number => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        else => error.NumberExpected,
    };
}
fn languageFormatNum(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len < 2) return error.NumberExpected;
    const raw = try valueString(a, args[1]);
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse raw.len;
    const sign_len: usize = if (raw.len != 0 and (raw[0] == '-' or raw[0] == '+')) 1 else 0;
    const digits = dot - sign_len;
    if (digits <= 3) return one(a, .{ .string = raw });
    const commas = (digits - 1) / 3;
    const out = try a.alloc(u8, raw.len + commas);
    var src: usize = 0;
    var dst: usize = 0;
    if (sign_len != 0) {
        out[0] = raw[0];
        src = 1;
        dst = 1;
    }
    while (src < dot) : (src += 1) {
        if (src > sign_len and (dot - src) % 3 == 0) {
            out[dst] = ',';
            dst += 1;
        }
        out[dst] = raw[src];
        dst += 1;
    }
    @memcpy(out[dst..], raw[dot..]);
    return one(a, .{ .string = out });
}
fn languageParseFormattedNumber(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const raw = try sourceMethodArg(args);
    var clean: std.ArrayList(u8) = .empty;
    for (raw) |c| if (c != ',') try clean.append(a, c);
    return one(a, .{ .string = try clean.toOwnedSlice(a) });
}

fn makeLanguage(a: std.mem.Allocator, host: *Context, code: []const u8) !*rt.Table {
    const table = try rt.newNativeNamespace(a, .language_value);
    const ctx = try a.create(LanguageCtx);
    ctx.* = .{ .host = host, .code = code };
    try table.rawSet(a, .{ .string = "code" }, .{ .string = code });
    try setNative(a, table, "getCode", ctx, languageGetCode);
    try setNative(a, table, "formatDate", ctx, languageFormatDate);
    try setNative(a, table, "uc", ctx, languageUc);
    try setNative(a, table, "lc", ctx, languageLc);
    try setNative(a, table, "ucfirst", ctx, languageUcfirst);
    try setNative(a, table, "lcfirst", ctx, languageLcfirst);
    try setNative(a, table, "getDir", ctx, languageGetDir);
    try setNative(a, table, "getFallbackLanguages", ctx, languageGetFallbacks);
    try setNative(a, table, "getArrow", ctx, languageGetArrow);
    try setNative(a, table, "gender", ctx, languageGender);
    try setNative(a, table, "formatNum", ctx, languageFormatNum);
    try setNative(a, table, "parseFormattedNumber", ctx, languageParseFormattedNumber);
    return table;
}
fn languageNew(ctx_raw: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *Context = @ptrCast(@alignCast(ctx_raw.?));
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(a, .{ .table = try makeLanguage(a, ctx, args[0].string) });
}

fn getContentLanguage(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const ctx: *Context = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .table = try makeLanguage(a, ctx, "en") });
}

fn isKnownLanguageTag(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return one(a, .{ .boolean = false });
    const code = args[0].string;
    if (code.len == 0) return one(a, .{ .boolean = false });
    for (code) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-'))
        return one(a, .{ .boolean = false });
    return one(a, .{ .boolean = true });
}

fn fetchLanguageName(_: ?*anyopaque, _: *anyopaque, args: []const Value, a: std.mem.Allocator) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    if (std.mem.eql(u8, args[0].string, "en")) return one(a, .{ .string = "English" });
    return one(a, .{ .string = args[0].string });
}
fn getFallbacksFor(_: ?*anyopaque, _: *anyopaque, _: []const Value, a: std.mem.Allocator) ![]const Value {
    const table = try rt.newTable(a);
    try table.append(a, .{ .string = "en" });
    return one(a, .{ .table = table });
}

pub fn install(a: std.mem.Allocator, io: std.Io, mw: *rt.Table) !void {
    const ctx = try a.create(Context);
    ctx.* = .{ .io = io };
    const language = try rt.newNativeNamespace(a, .language);
    try setNative(a, language, "new", ctx, languageNew);
    try setNative(a, language, "getContentLanguage", ctx, getContentLanguage);
    try setNative(a, language, "getFallbacksFor", ctx, getFallbacksFor);
    try setNative(a, language, "isKnownLanguageTag", ctx, isKnownLanguageTag);
    try setNative(a, language, "fetchLanguageName", ctx, fetchLanguageName);
    try mw.rawSet(a, .{ .string = "language" }, .{ .table = language });
    try setNative(a, mw, "getContentLanguage", ctx, getContentLanguage);
    try setNative(a, mw, "getLanguage", ctx, getContentLanguage);
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
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const ctx = Context{ .io = threaded.io() };
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
}

test "parse date forms used by Wiktionary modules" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const ctx = Context{ .io = threaded.io() };
    const a = std.testing.allocator;
    const a_ts = try parseTimestamp(&ctx, Value{ .string = "12-December-2022" });
    const b_ts = try parseTimestamp(&ctx, Value{ .string = "2022-12-12" });
    try std.testing.expectEqual(a_ts, b_ts);
    const out = try formatDateAlloc(a, a_ts, "YmdHis");
    defer a.free(out);
    try std.testing.expectEqualStrings("20221212000000", out);
}
