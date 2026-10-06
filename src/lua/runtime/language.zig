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
    const month: std.time.epoch.Month = @fromBackingInt(@intCast(civil.month));
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
    var text = raw;
    while (text.len != 0 and text[text.len - 1] == '.') text = text[0 .. text.len - 1];
    if (text.len == 0) return null;
    for (month_names, 1..) |name, i| {
        if (std.ascii.eqlIgnoreCase(text, name) or
            (text.len >= 3 and text.len <= 4 and std.ascii.eqlIgnoreCase(text[0..3], name[0..3]) and
                (text.len == 3 or std.ascii.eqlIgnoreCase(text, "Sept"))))
            return @intCast(i);
    }
    return null;
}

fn parseDateYear(raw: []const u8) ?i64 {
    const year = std.fmt.parseInt(i64, raw, 10) catch return null;
    if (year < 0) return null;
    if (raw.len <= 2) return if (year <= 69) 2000 + year else 1900 + year;
    return year;
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
    const third = parseDateYear(fields[2]) orelse return null;
    if (first >= 1000) {
        const month = monthNumber(fields[1]) orelse return null;
        const day = std.fmt.parseInt(u8, fields[2], 10) catch return null;
        return .{ .year = first, .month = month, .day = day };
    }
    const day = std.math.cast(u8, first) orelse return null;
    const month = monthNumber(fields[1]) orelse return null;
    return .{ .year = third, .month = month, .day = day };
}

fn parseSlashDate(raw: []const u8) ?Civil {
    var fields: [3][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, raw, '/');
    var n: usize = 0;
    while (it.next()) |field| {
        if (field.len == 0 or n == fields.len) return null;
        fields[n] = field;
        n += 1;
    }
    if (n != 3) return null;
    if (fields[0].len == 4) {
        return .{
            .year = std.fmt.parseInt(i64, fields[0], 10) catch return null,
            .month = std.fmt.parseInt(u8, fields[1], 10) catch return null,
            .day = std.fmt.parseInt(u8, fields[2], 10) catch return null,
        };
    }
    return .{
        .year = parseDateYear(fields[2]) orelse return null,
        .month = std.fmt.parseInt(u8, fields[0], 10) catch return null,
        .day = std.fmt.parseInt(u8, fields[1], 10) catch return null,
    };
}

fn parseDottedDate(raw: []const u8) ?Civil {
    var fields: [3][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, raw, '.');
    var n: usize = 0;
    while (it.next()) |field| {
        if (field.len == 0 or n == fields.len) return null;
        fields[n] = field;
        n += 1;
    }
    if (n != 3 or fields[2].len != 4) return null;
    return .{
        .year = std.fmt.parseInt(i64, fields[2], 10) catch return null,
        .month = std.fmt.parseInt(u8, fields[1], 10) catch return null,
        .day = std.fmt.parseInt(u8, fields[0], 10) catch return null,
    };
}

// This is the bounded English monthtext + separator* + year4 form used by
// PHP's datenoday grammar. Keep numeric dotted dates in their existing parser.
fn parseNamedMonthYear(raw: []const u8) ?Civil {
    var month_end: usize = 0;
    while (month_end < raw.len and std.ascii.isAlphabetic(raw[month_end])) : (month_end += 1) {}
    if (month_end == 0) return null;
    const month = monthNumber(raw[0..month_end]) orelse return null;
    const year_raw = std.mem.trimStart(u8, raw[month_end..], " .\t-");
    if (year_raw.len != 4) return null;
    for (year_raw) |byte| if (!std.ascii.isDigit(byte)) return null;
    const year = std.fmt.parseInt(i64, year_raw, 10) catch return null;
    return .{ .year = year, .month = month, .day = 1 };
}

fn parseOrdinalDay(raw: []const u8) ?u8 {
    if (raw.len < 3 or raw.len > 4) return null;
    const digits = raw[0 .. raw.len - 2];
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const suffix = raw[raw.len - 2 ..];
    if (!std.mem.eql(u8, suffix, "st") and !std.mem.eql(u8, suffix, "nd") and
        !std.mem.eql(u8, suffix, "rd") and !std.mem.eql(u8, suffix, "th")) return null;
    const day = std.fmt.parseInt(u8, digits, 10) catch return null;
    // PHP's suffix is independent of the numeric day: do not enforce 1st/2nd/etc.
    return if (day >= 1 and day <= 31) day else null;
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
    const year = parseDateYear(fields[2]) orelse return null;
    if (std.fmt.parseInt(u8, fields[0], 10)) |day| {
        const month = monthNumber(fields[1]) orelse return null;
        return .{ .year = year, .month = month, .day = day };
    } else |_| {}
    if (parseOrdinalDay(fields[0])) |day| {
        // monthNumber also accepts numbers; this addition is named-month only.
        if (!std.ascii.isAlphabetic(fields[1][0])) return null;
        const month = monthNumber(fields[1]) orelse return null;
        return .{ .year = year, .month = month, .day = day };
    }
    const month = monthNumber(fields[0]) orelse return null;
    const day = std.fmt.parseInt(u8, fields[1], 10) catch return null;
    return .{ .year = year, .month = month, .day = day };
}

fn parseDelimitedDate(raw: []const u8) ?Civil {
    return if (std.mem.indexOfScalar(u8, raw, '-') != null)
        parseHyphenDate(raw)
    else if (std.mem.indexOfScalar(u8, raw, '/') != null)
        parseSlashDate(raw)
    else
        parseDottedDate(raw) orelse parseSpaceDate(raw);
}

fn parseIsoDateTime(raw: []const u8) ?Civil {
    const body = if (raw.len == 20 and raw[19] == 'Z') raw[0..19] else raw;
    if (body.len != 19 or
        body[4] != '-' or body[7] != '-' or
        (body[10] != 'T' and body[10] != ' ') or
        body[13] != ':' or body[16] != ':')
        return null;
    return .{
        .year = std.fmt.parseInt(i64, body[0..4], 10) catch return null,
        .month = std.fmt.parseInt(u8, body[5..7], 10) catch return null,
        .day = std.fmt.parseInt(u8, body[8..10], 10) catch return null,
        .hour = std.fmt.parseInt(u8, body[11..13], 10) catch return null,
        .minute = std.fmt.parseInt(u8, body[14..16], 10) catch return null,
        .second = std.fmt.parseInt(u8, body[17..19], 10) catch return null,
    };
}

fn parseCivil(raw: []const u8) ?Civil {
    return parseIsoDateTime(raw) orelse parseDelimitedDate(raw) orelse parseNamedMonthYear(raw);
}

fn parseClockDateTime(raw: []const u8) ?Civil {
    var body = std.mem.trim(u8, raw, " \t\r\n");
    if (body.len == 0) return null;

    var meridiem: ?bool = null; // false = AM, true = PM
    if (body.len >= 3 and body[body.len - 3] == ' ') {
        const suffix = body[body.len - 2 ..];
        if (std.ascii.eqlIgnoreCase(suffix, "AM")) {
            meridiem = false;
            body = std.mem.trimEnd(u8, body[0 .. body.len - 3], " \t\r\n");
        } else if (std.ascii.eqlIgnoreCase(suffix, "PM")) {
            meridiem = true;
            body = std.mem.trimEnd(u8, body[0 .. body.len - 3], " \t\r\n");
        }
    }

    const split = std.mem.lastIndexOfScalar(u8, body, ' ') orelse return null;
    const date_raw = std.mem.trim(u8, body[0..split], " \t\r\n");
    const time_raw = std.mem.trim(u8, body[split + 1 ..], " \t\r\n");
    if (date_raw.len == 0 or time_raw.len == 0) return null;
    if (meridiem == null and std.mem.indexOfScalar(u8, time_raw, ':') == null) return null;

    var parts = std.mem.splitScalar(u8, time_raw, ':');
    const hour_raw = parts.next() orelse return null;
    if (hour_raw.len == 0) return null;
    var hour = std.fmt.parseInt(u8, hour_raw, 10) catch return null;
    var minute: u8 = 0;
    var second: u8 = 0;
    if (parts.next()) |raw_minute| {
        if (raw_minute.len == 0) return null;
        minute = std.fmt.parseInt(u8, raw_minute, 10) catch return null;
        if (parts.next()) |raw_second| {
            if (raw_second.len == 0) return null;
            second = std.fmt.parseInt(u8, raw_second, 10) catch return null;
        }
    }
    if (parts.next() != null or minute > 59 or second > 59) return null;

    if (meridiem) |pm| {
        if (hour < 1 or hour > 12) return null;
        if (hour == 12) hour = 0;
        if (pm) hour += 12;
    } else if (hour > 23) return null;

    var civil = parseCivil(date_raw) orelse return null;
    civil.hour = hour;
    civil.minute = minute;
    civil.second = second;
    return civil;
}

fn parseLeadingClockDateTime(raw: []const u8) ?Civil {
    var body = std.mem.trim(u8, raw, " \t\r\n");
    if (body.len == 0) return null;

    const zones = [_][]const u8{ "(UTC)", "(GMT)", "UTC", "GMT" };
    for (zones) |zone| {
        if (body.len <= zone.len) continue;
        const start = body.len - zone.len;
        if (!std.ascii.isWhitespace(body[start - 1]) or !std.ascii.eqlIgnoreCase(body[start..], zone)) continue;
        body = std.mem.trimEnd(u8, body[0 .. start - 1], " \t\r\n");
        break;
    }

    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return null;
    const time_raw = std.mem.trim(u8, body[0..comma], " \t\r\n");
    const date_raw = std.mem.trim(u8, body[comma + 1 ..], " \t\r\n");
    if (time_raw.len == 0 or date_raw.len == 0) return null;

    var parts = std.mem.splitScalar(u8, time_raw, ':');
    const hour_raw = parts.next() orelse return null;
    const minute_raw = parts.next() orelse return null;
    if (hour_raw.len == 0 or minute_raw.len == 0) return null;
    const hour = std.fmt.parseInt(u8, hour_raw, 10) catch return null;
    const minute = std.fmt.parseInt(u8, minute_raw, 10) catch return null;
    var second: u8 = 0;
    if (parts.next()) |second_raw| {
        if (second_raw.len == 0) return null;
        second = std.fmt.parseInt(u8, second_raw, 10) catch return null;
    }
    if (parts.next() != null or hour > 23 or minute > 59 or second > 59) return null;

    var civil = parseCivil(date_raw) orelse return null;
    civil.hour = hour;
    civil.minute = minute;
    civil.second = second;
    return civil;
}

fn currentUnix(runtime: *const rt.Context) !i64 {
    const host = host_api.getForStablePageRead(runtime) orelse return error.MissingScribuntoHost;
    return host.now_unix orelse error.MissingCurrentTime;
}

fn addDays(timestamp: i64, count: i64) !i64 {
    const seconds = std.math.mul(i64, count, std.time.s_per_day) catch return error.InvalidDate;
    return std.math.add(i64, timestamp, seconds) catch error.InvalidDate;
}

fn parseMonthRelative(runtime: *const rt.Context, raw: []const u8) !?i64 {
    const anchors = [_]struct { text: []const u8, shift: i64, last: bool }{
        .{ .text = "first day of this month", .shift = 0, .last = false },
        .{ .text = "first day of last month", .shift = -1, .last = false },
        .{ .text = "first day of next month", .shift = 1, .last = false },
        .{ .text = "last day of this month", .shift = 0, .last = true },
        .{ .text = "last day of last month", .shift = -1, .last = true },
        .{ .text = "last day of next month", .shift = 1, .last = true },
    };
    for (anchors) |anchor| {
        if (!std.ascii.startsWithIgnoreCase(raw, anchor.text)) continue;
        if (raw.len > anchor.text.len and !std.ascii.isWhitespace(raw[anchor.text.len])) continue;

        var shift = anchor.shift;
        const suffix = std.mem.trim(u8, raw[anchor.text.len..], " \t\r\n");
        if (suffix.len != 0) {
            if (suffix[0] != '+' and suffix[0] != '-') return error.InvalidDate;
            const body = std.mem.trim(u8, suffix[1..], " \t\r\n");
            const space = std.mem.indexOfScalar(u8, body, ' ') orelse return error.InvalidDate;
            const count = std.fmt.parseInt(i64, body[0..space], 10) catch return error.InvalidDate;
            const unit = std.mem.trim(u8, body[space + 1 ..], " \t\r\n");
            if (!std.ascii.eqlIgnoreCase(unit, "month") and !std.ascii.eqlIgnoreCase(unit, "months"))
                return error.InvalidDate;
            const signed = std.math.mul(i64, if (suffix[0] == '+') @as(i64, 1) else -1, count) catch return error.InvalidDate;
            shift = std.math.add(i64, shift, signed) catch return error.InvalidDate;
        }

        const current = civilFromUnix(try currentUnix(runtime));
        const year_month = std.math.add(
            i64,
            std.math.mul(i64, current.year, 12) catch return error.InvalidDate,
            @as(i64, current.month) - 1,
        ) catch return error.InvalidDate;
        const shifted = std.math.add(i64, year_month, shift) catch return error.InvalidDate;
        const year = floorDiv(shifted, 12);
        const month: u8 = @intCast(@mod(shifted, 12) + 1);
        if (year < 1 or year > std.math.maxInt(std.time.epoch.Year)) return error.InvalidDate;
        const day: u8 = if (anchor.last)
            std.time.epoch.getDaysInMonth(@intCast(year), @fromBackingInt(@intCast(month)))
        else
            1;
        return try unixFromCivil(.{ .year = year, .month = month, .day = day });
    }
    return null;
}

pub fn parseTimestampText(runtime: *const rt.Context, raw_value: ?[]const u8) !i64 {
    const raw = if (raw_value) |value| std.mem.trim(u8, value, " \t\r\n") else return currentUnix(runtime);
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "now")) return currentUnix(runtime);
    if (raw[0] == '@') return std.fmt.parseInt(i64, raw[1..], 10) catch error.InvalidDate;
    if (std.ascii.eqlIgnoreCase(raw, "today"))
        return floorDiv(try currentUnix(runtime), std.time.s_per_day) * std.time.s_per_day;
    if (try parseMonthRelative(runtime, raw)) |timestamp| return timestamp;
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
    inline for (.{ .{ '+', @as(i64, 1) }, .{ '-', @as(i64, -1) } }) |entry| {
        if (std.mem.lastIndexOfScalar(u8, raw, entry[0])) |at| {
            if (at != 0) {
                const suffix = std.mem.trim(u8, raw[at + 1 ..], " \t\r\n");
                if (std.mem.indexOfScalar(u8, suffix, ' ')) |space| {
                    if (std.fmt.parseInt(i64, suffix[0..space], 10)) |count| {
                        const unit = std.mem.trim(u8, suffix[space + 1 ..], " \t\r\n");
                        if (std.ascii.eqlIgnoreCase(unit, "day") or std.ascii.eqlIgnoreCase(unit, "days")) {
                            const base_raw = std.mem.trim(u8, raw[0..at], " \t\r\n");
                            if (parseCivil(base_raw)) |civil| {
                                const signed = std.math.mul(i64, entry[1], count) catch return error.InvalidDate;
                                return addDays(try unixFromCivil(civil), signed);
                            }
                        }
                    } else |_| {}
                }
            }
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
                const civil = parseCivil(base_raw) orelse return error.InvalidDate;
                const signed = std.math.mul(i64, entry[1], count) catch return error.InvalidDate;
                return addDays(try unixFromCivil(civil), signed);
            }
        }
    }
    const civil = parseCivil(raw) orelse parseClockDateTime(raw) orelse parseLeadingClockDateTime(raw) orelse return error.InvalidDate;
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
        out += std.time.epoch.getDaysInMonth(@intCast(c.year), @fromBackingInt(@intCast(month)));
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

fn languageGetCode(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const ctx: *LanguageCtx = @ptrCast(@alignCast(ctx_raw.?));
    return one(a, .{ .string = ctx.code });
}

const date_month_keys = [_][]const u8{ "january", "february", "march", "april", "may_long", "june", "july", "august", "september", "october", "november", "december" };
const date_month_genitive_keys = [_][]const u8{ "january-gen", "february-gen", "march-gen", "april-gen", "may-gen", "june-gen", "july-gen", "august-gen", "september-gen", "october-gen", "november-gen", "december-gen" };
const date_month_short_keys = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const date_weekday_keys = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
const date_weekday_short_keys = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

fn dateNumbering(runtime: *rt.Context, code: []const u8) !host_api.DateNumbering {
    const host = host_api.getForStablePageRead(runtime) orelse {
        rt.work_stats.logLine("date numbering missing: language={s}\n", .{code[0..@min(code.len, 128)]});
        return error.DateNumberingSnapshotMissing;
    };
    const get = host.date_numbering orelse {
        rt.work_stats.logLine("date numbering missing: language={s}\n", .{code[0..@min(code.len, 128)]});
        return error.DateNumberingSnapshotMissing;
    };
    return get(host.ctx, code) catch |err| {
        if (err == error.DateNumberingSnapshotMissing)
            rt.work_stats.logLine("date numbering missing: language={s}\n", .{code[0..@min(code.len, 128)]});
        if (err == error.DateNumberingUnsupported)
            rt.work_stats.logLine("date numbering unsupported: language={s}\n", .{code[0..@min(code.len, 128)]});
        return err;
    };
}

fn appendDateMessage(out: *std.ArrayList(u8), runtime: *rt.Context, code: []const u8, key: []const u8) !void {
    const host = host_api.getForStablePageRead(runtime) orelse return error.InterfaceMessageSnapshotMissing;
    const get = host.interface_message orelse return error.InterfaceMessageSnapshotMissing;
    const entry = (try get(host.ctx, runtime.allocator, code, key)) orelse return error.InterfaceMessageSnapshotMissing;
    const source = entry.source orelse return error.UnsupportedDateMessage;
    // MediaWiki uses Message::text(). Plain captured labels are exact; a message
    // needing template/parameter expansion needs its own evaluated capture.
    if (std.mem.indexOf(u8, source, "{{") != null or std.mem.indexOf(u8, source, "}}") != null or
        std.mem.indexOfScalar(u8, source, '$') != null)
        return error.UnsupportedDateMessage;
    try out.appendSlice(runtime.allocator, source);
}

fn appendDateNumber(out: *std.ArrayList(u8), a: std.mem.Allocator, profile: host_api.DateNumbering, number: i64, width: usize, raw: bool) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{number});
    const padding = width -| text.len;
    for (0..padding) |_| try out.appendSlice(a, if (raw or number < 0) "0" else profile.digits[0]);
    // sprintfDate translates only /^[\d.]+$/. In particular negative Unix
    // timestamps retain the ASCII minus and ASCII digits, not a Unicode minus.
    if (raw or number < 0) return out.appendSlice(a, text);
    for (text) |digit| try out.appendSlice(a, profile.digits[digit - '0']);
}

/// MediaWiki Gregorian format codes use captured messages and effective site
/// numeral policy. The old formatDateAlloc remains the existing parser-function
/// implementation; this path implements mw.language:formatDate.
fn localizedDateAlloc(runtime: *rt.Context, code: []const u8, profile: host_api.DateNumbering, timestamp: i64, format: []const u8) ![]const u8 {
    // Matches Scribunto's 0..9999 DateTime year envelope before civil arithmetic.
    if (timestamp < -62167219200 or timestamp > 253402300799) return error.InvalidDate;
    const a = runtime.allocator;
    const c = civilFromUnix(timestamp);
    const weekday = weekdaySunday0(timestamp);
    const week = isoWeek(timestamp, c);
    const iso_year = c.year + (if (c.month == 1 and week >= 52) @as(i64, -1) else if (c.month == 12 and week == 1) @as(i64, 1) else 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var raw_next = false;
    var raw_all = false;
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        const token = format[i];
        if (token == '\\') {
            if (i + 1 < format.len) i += 1;
            try out.append(a, format[i]);
            continue;
        }
        if (token == '"') {
            if (std.mem.indexOfScalarPos(u8, format, i + 1, '"')) |end| {
                try out.appendSlice(a, format[i + 1 .. end]);
                i = end;
            } else try out.append(a, '"');
            continue;
        }
        if (token == 'x' and i + 1 < format.len) {
            i += 1;
            switch (format[i]) {
                'x' => try out.append(a, 'x'),
                'n' => raw_next = true,
                'N' => raw_all = !raw_all,
                'g' => try appendDateMessage(&out, runtime, code, date_month_genitive_keys[c.month - 1]),
                'r', 'h' => return error.UnsupportedDateNumeralMode,
                'i', 'j', 'k', 'm', 'o', 't' => {
                    if (i + 1 < format.len) {
                        i += 1;
                        const extension = format[i - 2 .. i + 1];
                        inline for (.{ "xij", "xiF", "xin", "xiy", "xiY", "xit", "xiz", "xjj", "xjF", "xjt", "xjx", "xjn", "xjY", "xmj", "xmF", "xmn", "xmY", "xkY", "xoY", "xtY" }) |calendar| {
                            if (std.mem.eql(u8, extension, calendar)) return error.UnsupportedDateCalendar;
                        }
                    }
                    try out.append(a, format[i]);
                },
                // MediaWiki consumes x and emits only the unknown second byte.
                else => try out.append(a, format[i]),
            }
            continue;
        }
        var number: ?i64 = null;
        var width: usize = 0;
        switch (token) {
            'F' => try appendDateMessage(&out, runtime, code, date_month_keys[c.month - 1]),
            'M' => try appendDateMessage(&out, runtime, code, date_month_short_keys[c.month - 1]),
            'l' => try appendDateMessage(&out, runtime, code, date_weekday_keys[weekday]),
            'D' => try appendDateMessage(&out, runtime, code, date_weekday_short_keys[weekday]),
            'U' => number = timestamp,
            'j' => number = c.day,
            'd' => {
                number = c.day;
                width = 2;
            },
            'Y' => {
                number = c.year;
                width = 4;
            },
            'y' => {
                number = @mod(c.year, 100);
                width = 2;
            },
            'm' => {
                number = c.month;
                width = 2;
            },
            'n' => number = c.month,
            'H' => {
                number = c.hour;
                width = 2;
            },
            'G' => number = c.hour,
            'g', 'h' => {
                number = if (c.hour % 12 == 0) 12 else c.hour % 12;
                width = if (token == 'h') 2 else 0;
            },
            'i' => {
                number = c.minute;
                width = 2;
            },
            's' => {
                number = c.second;
                width = 2;
            },
            'a' => try out.appendSlice(a, if (c.hour < 12) "am" else "pm"),
            'A' => try out.appendSlice(a, if (c.hour < 12) "AM" else "PM"),
            'w' => number = weekday,
            'N' => number = if (weekday == 0) 7 else weekday,
            'z' => number = daysFromCivil(c.year, c.month, c.day) - daysFromCivil(c.year, 1, 1),
            'W' => {
                number = week;
                width = 2;
            },
            'o' => number = iso_year,
            't' => number = std.time.epoch.getDaysInMonth(@intCast(c.year), @fromBackingInt(@intCast(c.month))),
            'L' => number = if (@mod(c.year, 4) == 0 and (@mod(c.year, 100) != 0 or @mod(c.year, 400) == 0)) 1 else 0,
            'I', 'Z' => number = 0,
            'e', 'T' => try out.appendSlice(a, "UTC"),
            'O' => try out.appendSlice(a, "+0000"),
            'P' => try out.appendSlice(a, "+00:00"),
            // These two PHP DateTime composite formats are deliberately ASCII,
            // including English abbreviations in r, for every output language.
            'c' => {
                try appendPadded(&out, a, c.year, 4);
                try out.append(a, '-');
                try writeTwo(&out, a, c.month);
                try out.append(a, '-');
                try writeTwo(&out, a, c.day);
                try out.append(a, 'T');
                try writeTwo(&out, a, c.hour);
                try out.append(a, ':');
                try writeTwo(&out, a, c.minute);
                try out.append(a, ':');
                try writeTwo(&out, a, c.second);
                try out.appendSlice(a, "+00:00");
            },
            'r' => {
                try out.appendSlice(a, weekday_names[weekday][0..3]);
                try out.appendSlice(a, ", ");
                try writeTwo(&out, a, c.day);
                try out.append(a, ' ');
                try out.appendSlice(a, month_names[c.month - 1][0..3]);
                try out.append(a, ' ');
                try appendPadded(&out, a, c.year, 4);
                try out.append(a, ' ');
                try writeTwo(&out, a, c.hour);
                try out.append(a, ':');
                try writeTwo(&out, a, c.minute);
                try out.append(a, ':');
                try writeTwo(&out, a, c.second);
                try out.appendSlice(a, " +0000");
            },
            else => try out.append(a, token),
        }
        if (number) |value| {
            try appendDateNumber(&out, a, profile, value, width, raw_next or raw_all);
            raw_next = false;
        }
    }
    return out.toOwnedSlice(a);
}

fn languageFormatDate(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    if (args.len > 2 and args[2] != .nil and args[2] != .string) return error.StringExpected;
    const local = if (args.len <= 3 or args[3] == .nil) false else if (args[3] == .boolean) args[3].boolean else return error.BooleanExpected;
    const timestamp = try parseTimestamp(runtime, if (args.len > 2) args[2] else null);
    if (timestamp < -62167219200 or timestamp > 253402300799) return error.InvalidDate;
    const profile = try dateNumbering(runtime, ctx.code);
    if (local and !std.mem.eql(u8, profile.timezone, "UTC")) return error.UnsupportedDateTimezone;
    return one(runtime.allocator, .{ .string = try localizedDateAlloc(runtime, ctx.code, profile, timestamp, args[1].string) });
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
    if (!std.unicode.utf8ValidateSlice(source)) {
        const out = try a.dupe(u8, source);
        if (out[0] < 0x80)
            out[0] = if (upper) std.ascii.toUpper(out[0]) else std.ascii.toLower(out[0]);
        return out;
    }
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

const FirstCaseClass = enum { base, az, tr, kaa };

fn firstCaseClass(code: []const u8) FirstCaseClass {
    // MediaWiki 1.47.0-wmf.22 LanguageFactory chooses the direct class, then
    // the first existing class in its language fallback chain. These are the
    // only classes overriding ucfirst/lcfirst; their full uc/lc stay base.
    // https://gerrit.wikimedia.org/r/plugins/gitiles/mediawiki/core/+/534a011895bffbb001eef512fc313b8ad4bc939c/includes/Languages/
    if (std.mem.eql(u8, code, "az")) return .az;
    if (std.mem.eql(u8, code, "kaa")) return .kaa;
    inline for (.{ "tr", "crh", "crh-cyrl", "crh-latn", "gag", "kiu", "lzz" }) |inherited|
        if (std.mem.eql(u8, code, inherited)) return .tr;
    return .base;
}

fn languageFirstCaseAlloc(ctx: *LanguageCtx, a: std.mem.Allocator, source: []const u8, upper: bool) ![]const u8 {
    const class = firstCaseClass(ctx.code);
    const replacement: ?struct { from: []const u8, to: []const u8 } = switch (class) {
        .base => null,
        .az => if (upper and std.mem.startsWith(u8, source, "i")) .{ .from = "i", .to = "İ" } else null,
        .tr => if (upper)
            (if (std.mem.startsWith(u8, source, "i")) .{ .from = "i", .to = "İ" } else if (std.mem.startsWith(u8, source, "ı")) .{ .from = "ı", .to = "I" } else null)
        else
            (if (std.mem.startsWith(u8, source, "I")) .{ .from = "I", .to = "ı" } else if (std.mem.startsWith(u8, source, "İ")) .{ .from = "İ", .to = "i" } else null),
        .kaa => if (upper)
            (if (std.mem.startsWith(u8, source, "ı")) .{ .from = "ı", .to = "Í" } else null)
        else
            (if (std.mem.startsWith(u8, source, "Í")) .{ .from = "Í", .to = "ı" } else null),
    };
    if (replacement) |pair| return try std.mem.concat(a, u8, &.{ pair.to, source[pair.from.len..] });
    return firstCaseAlloc(ctx.case_mapper, a, source, upper);
}

fn mediaWikiCaseAlloc(
    case_mapper: *ustring_lib.Normalizer,
    a: std.mem.Allocator,
    source: []const u8,
    upper: bool,
) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(source))
        return ustring_lib.caseAlloc(case_mapper, a, source, if (upper) .upper else .lower);

    // MediaWiki Language::uc/lc falls back to byte strtoupper/strtolower
    // when mb_strlen does not classify the input as multibyte. This matters
    // for Lua code which slices a multibyte character with string.sub() and
    // then passes an individual byte through mw.ustring.upper/lower, because
    // Scribunto aliases those functions to the content language.
    const out = try a.dupe(u8, source);
    for (out) |*byte| {
        if (byte.* < 0x80)
            byte.* = if (upper) std.ascii.toUpper(byte.*) else std.ascii.toLower(byte.*);
    }
    return out;
}

fn languageUc(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try mediaWikiCaseAlloc(ctx.case_mapper, a, try sourceMethodArg(args), true) });
}

fn languageLc(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try mediaWikiCaseAlloc(ctx.case_mapper, a, try sourceMethodArg(args), false) });
}

fn contentLanguageUpper(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx: *LanguageFactoryCtx = @ptrCast(@alignCast(ctx_raw orelse return error.MissingLanguageFactory));
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(runtime.allocator, .{
        .string = try mediaWikiCaseAlloc(ctx.case_mapper, runtime.allocator, args[0].string, true),
    });
}

fn contentLanguageLower(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx: *LanguageFactoryCtx = @ptrCast(@alignCast(ctx_raw orelse return error.MissingLanguageFactory));
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return one(runtime.allocator, .{
        .string = try mediaWikiCaseAlloc(ctx.case_mapper, runtime.allocator, args[0].string, false),
    });
}

fn languageUcfirst(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try languageFirstCaseAlloc(ctx, a, try sourceMethodArg(args), true) });
}

fn languageLcfirst(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    const a = runtime.allocator;
    return one(a, .{ .string = try languageFirstCaseAlloc(ctx, a, try sourceMethodArg(args), false) });
}

fn languageGetDir(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    const code = try std.ascii.allocLowerString(runtime.allocator, ctx.code);
    if (std.mem.eql(u8, code, "en")) return one(runtime.allocator, .{ .string = "ltr" });
    const host = host_api.getForStablePageRead(runtime);
    const get = if (host) |value| value.language_direction else null;
    const direction = if (get) |callback| callback(host.?.ctx, code) catch |err| {
        if (err == error.LanguageDirectionSnapshotMissing)
            rt.work_stats.logLine("warning: language direction snapshot missing: language={s}\n", .{code[0..@min(code.len, 128)]});
        return err;
    } else {
        rt.work_stats.logLine("warning: language direction snapshot unavailable: language={s}\n", .{code[0..@min(code.len, 128)]});
        return error.LanguageDirectionSnapshotMissing;
    };
    return one(runtime.allocator, .{ .string = @tagName(direction) });
}
fn languageIsRtl(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    _ = try requireEnglishLocale(ctx_raw);
    return one(runtime.allocator, .{ .boolean = false });
}
fn languageGetFallbacks(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const ctx = try languageContext(ctx_raw);
    return fallbackLanguages(runtime, ctx.code, if (args.len > 1) args[1] else .nil);
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
    const ctx = try languageContext(ctx_raw);
    const arabic = std.ascii.eqlIgnoreCase(ctx.code, "ar");
    if (!arabic and !std.ascii.eqlIgnoreCase(ctx.code, "en")) return error.NotImplemented;
    const a = runtime.allocator;
    if (args.len < 2) return error.StringExpected;
    // Scribunto accepts numeric values and returns nil for other nonstrings.
    // An absent argument is distinct from an explicitly supplied nil.
    const raw = switch (args[1]) {
        .string => |value| value,
        .number => |value| try rt.numberToString(a, value),
        else => return one(a, .nil),
    };
    defer if (args[1] == .number) a.free(raw);
    // Arabic support requires the exact captured database message. Keep the
    // existing English path independent of an interface-message snapshot.
    if (arabic and try isFormattedNumberNan(runtime, raw))
        return one(a, .{ .number = std.math.nan(f64) });
    const normalized = try normalizeFormattedNumberAlloc(a, raw, arabic);
    defer a.free(normalized);
    // mw.language.lua applies tonumber to the PHP-normalized string. This is
    // essential for Quran's nonnumeric surah-name lookup to receive nil.
    return one(a, if (rt.toNumber(.{ .string = normalized })) |number| .{ .number = number } else .nil);
}

fn isFormattedNumberNan(runtime: *rt.Context, raw: []const u8) !bool {
    const host = host_api.getForStablePageRead(runtime) orelse {
        rt.work_stats.logLine("interface message unavailable: language=ar key=formatnum-nan\n", .{});
        return error.InterfaceMessageSnapshotMissing;
    };
    const get = host.interface_message orelse {
        rt.work_stats.logLine("interface message unavailable: language=ar key=formatnum-nan\n", .{});
        return error.InterfaceMessageSnapshotMissing;
    };
    const captured = (get(host.ctx, runtime.allocator, "ar", "formatnum-nan") catch |err| {
        if (err == error.InterfaceMessageSnapshotMissing)
            rt.work_stats.logLine("interface message missing: language=ar key=formatnum-nan\n", .{});
        return err;
    }) orelse {
        rt.work_stats.logLine("interface message missing: language=ar key=formatnum-nan\n", .{});
        return error.InterfaceMessageSnapshotMissing;
    };
    const source = captured.source orelse return error.UnsupportedFormattedNumberNanMessage;
    // Core uses Message::text(), which evaluates template syntax. The pinned
    // plain-message callback cannot represent an unevaluated template result.
    if (std.mem.indexOf(u8, source, "{{") != null) return error.UnsupportedFormattedNumberNanMessage;
    return std.mem.eql(u8, raw, source);
}

fn normalizeFormattedNumberAlloc(a: std.mem.Allocator, raw: []const u8, arabic: bool) ![]u8 {
    // MediaWiki 1.47.0-wmf.22 Language::parseFormattedNumber and MessagesAr.php
    // inverse transforms: U+0660..0669 digits, U+066B decimal, U+066C grouping.
    // Infinity recognition is exact, before whitespace trimming by tonumber.
    if (std.mem.eql(u8, raw, "∞")) return try a.dupe(u8, "INF");
    if (std.mem.eql(u8, raw, "-∞") or std.mem.eql(u8, raw, "−∞")) return try a.dupe(u8, "-INF");
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(a);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "−")) {
            try normalized.append(a, '-');
            i += "−".len;
        } else if (arabic and raw[i] == 0xD9 and i + 1 < raw.len and raw[i + 1] >= 0xA0 and raw[i + 1] <= 0xA9) {
            try normalized.append(a, '0' + raw[i + 1] - 0xA0);
            i += 2;
        } else if (arabic and std.mem.startsWith(u8, raw[i..], "٫")) {
            try normalized.append(a, '.');
            i += "٫".len;
        } else if (arabic and std.mem.startsWith(u8, raw[i..], "٬")) {
            i += "٬".len;
        } else {
            if (raw[i] != ',') try normalized.append(a, raw[i]);
            i += 1;
        }
    }
    return try normalized.toOwnedSlice(a);
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
    try setNative(runtime, table, "isRTL", ctx, languageIsRtl);
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
    const catalog = runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
    return one(a, .{ .table = try makeLanguage(runtime, factory.case_mapper, catalog.content_language) });
}

fn isKnownLanguageTag(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return one(a, .{ .boolean = false });
    if (std.mem.eql(u8, args[0].string, "en")) return one(a, .{ .boolean = true });
    const host = host_api.getForStablePageRead(runtime) orelse return error.NotImplemented;
    const get = host.language_known_tag orelse return error.NotImplemented;
    return one(a, .{ .boolean = try get(host.ctx, args[0].string) });
}

fn displayLanguage(runtime: *rt.Context, args: []const Value, index: usize) !?[]const u8 {
    if (index >= args.len or args[index] == .nil) return null;
    if (args[index] != .string) return error.StringExpected;
    return try std.ascii.allocLowerString(runtime.allocator, args[index].string);
}
fn languageNameMissing(code: []const u8, display: ?[]const u8, scope: []const u8) void {
    const shown = display orelse "<autonym>";
    rt.work_stats.logLine("warning: language name snapshot missing: language={s} display={s} scope={s}\n", .{
        code[0..@min(code.len, 128)], shown[0..@min(shown.len, 128)], scope,
    });
}
fn fetchLanguageName(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const code = try std.ascii.allocLowerString(runtime.allocator, args[0].string);
    const display = try displayLanguage(runtime, args, 1);
    // Retain the previously supported English autonym without substituting it
    // for a name requested in another display language.
    if (display == null and std.mem.eql(u8, code, "en")) return one(runtime.allocator, .{ .string = "English" });
    const host = host_api.getForStablePageRead(runtime);
    const get = if (host) |value| value.language_name else null;
    const name = if (get) |callback| callback(host.?.ctx, code, display) catch |err| {
        if (err == error.LanguageNameSnapshotMissing) languageNameMissing(code, display, "single");
        return err;
    } else {
        languageNameMissing(code, display, "single");
        return error.LanguageNameSnapshotMissing;
    };
    return one(runtime.allocator, .{ .string = name });
}
fn fetchLanguageNames(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const display = try displayLanguage(runtime, args, 0);
    const scope: host_api.LanguageNameScope = if (args.len < 2 or args[1] == .nil)
        .mw
    else if (args[1] != .string)
        return error.StringExpected
    else if (std.mem.eql(u8, args[1].string, "all"))
        .all
    else if (std.mem.eql(u8, args[1].string, "mwfile"))
        .mwfile
    else
        .mw;
    const host = host_api.getForStablePageRead(runtime);
    const get = if (host) |value| value.language_names else null;
    const rows = if (get) |callback| callback(host.?.ctx, display, scope) catch |err| {
        if (err == error.LanguageNameSnapshotMissing) languageNameMissing("*", display, @tagName(scope));
        return err;
    } else {
        languageNameMissing("*", display, @tagName(scope));
        return error.LanguageNameSnapshotMissing;
    };
    const result = try runtime.newTable();
    for (rows) |row| try result.rawSet(runtime.allocator, .{ .string = row.code }, .{ .string = row.name });
    return one(runtime.allocator, .{ .table = result });
}

fn fallbackLanguages(runtime: *rt.Context, code: []const u8, mode: Value) ![]const Value {
    const a = runtime.allocator;
    const strict = if (mode == .nil) false else blk: {
        if (mode != .string) return error.InvalidLanguageFallbackMode;
        if (std.mem.eql(u8, mode.string, "FALLBACK_MESSAGES")) break :blk false;
        if (std.mem.eql(u8, mode.string, "FALLBACK_STRICT")) break :blk true;
        return error.InvalidLanguageFallbackMode;
    };
    const table = try runtime.newTable();
    // MediaWiki returns an empty chain for English and invalid built-in codes.
    if (std.mem.eql(u8, code, "en") or code.len < 2) return one(a, .{ .table = table });
    for (code) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-')
        return one(a, .{ .table = table });
    const host = host_api.getForStablePageRead(runtime) orelse {
        rt.work_stats.logLine("warning: language fallback snapshot unavailable: language={s}\n", .{code[0..@min(code.len, 128)]});
        return error.LanguageFallbackSnapshotMissing;
    };
    const get = host.language_fallbacks orelse {
        rt.work_stats.logLine("warning: language fallback snapshot unavailable: language={s}\n", .{code[0..@min(code.len, 128)]});
        return error.LanguageFallbackSnapshotMissing;
    };
    const captured = try get(host.ctx, code);
    // The API records STRICT. MediaWiki's MESSAGES mode adds a terminal English
    // fallback, without sorting, recursively expanding, or deduplicating the list.
    for (captured, 1..) |fallback, index|
        try table.rawSet(a, .{ .number = @floatFromInt(index) }, .{ .string = fallback });
    if (!strict and (captured.len == 0 or !std.mem.eql(u8, captured[captured.len - 1], "en")))
        try table.rawSet(a, .{ .number = @floatFromInt(captured.len + 1) }, .{ .string = "en" });
    return one(a, .{ .table = table });
}

fn getFallbacksFor(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return fallbackLanguages(runtime, args[0].string, if (args.len > 1) args[1] else .nil);
}

pub fn install(runtime: *rt.Context, mw: *rt.Table, case_mapper: *ustring_lib.Normalizer) !void {
    const factory = try runtime.allocator.create(LanguageFactoryCtx);
    factory.* = .{ .case_mapper = case_mapper };
    const language = try runtime.newNativeNamespace(.language);
    try setNative(runtime, language, "new", factory, languageNew);
    try setNative(runtime, language, "getContentLanguage", factory, getContentLanguage);
    try setNative(runtime, language, "getFallbacksFor", null, getFallbacksFor);
    try language.rawSet(runtime.allocator, .{ .string = "FALLBACK_MESSAGES" }, .{ .string = "FALLBACK_MESSAGES" });
    try language.rawSet(runtime.allocator, .{ .string = "FALLBACK_STRICT" }, .{ .string = "FALLBACK_STRICT" });
    try setNative(runtime, language, "isKnownLanguageTag", null, isKnownLanguageTag);
    try setNative(runtime, language, "fetchLanguageName", null, fetchLanguageName);
    try setNative(runtime, language, "fetchLanguageNames", null, fetchLanguageNames);
    try mw.rawSet(runtime.allocator, .{ .string = "language" }, .{ .table = language });
    try setNative(runtime, mw, "getContentLanguage", factory, getContentLanguage);
    try setNative(runtime, mw, "getLanguage", factory, languageNew);

    // Scribunto replaces mw.ustring.upper/lower with content-language uc/lc.
    // Every MediaWiki language class inherits the same full-string methods;
    // only ucfirst/lcfirst have language-specific overrides.
    if (mw.rawGet(.{ .string = "ustring" })) |ustring_value| if (ustring_value == .table) {
        try ustring_value.table.rawSetNativeField(
            .ustring,
            "upper",
            try runtime.newNative(factory, contentLanguageUpper),
        );
        try ustring_value.table.rawSetNativeField(
            .ustring,
            "lower",
            try runtime.newNative(factory, contentLanguageLower),
        );
    };
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
        .{ .raw = "4 February 9", .expected = "2009-02-04" },
        .{ .raw = "4 Feb 69", .expected = "2069-02-04" },
        .{ .raw = "4 Feb 70", .expected = "1970-02-04" },
        .{ .raw = "Feb 4 84", .expected = "1984-02-04" },
        .{ .raw = "4-Feb-99", .expected = "1999-02-04" },
        .{ .raw = "4 Feb 684", .expected = "0684-02-04" },
        .{ .raw = "17.10.1836", .expected = "1836-10-17" },
        .{ .raw = "1.2.0003", .expected = "0003-02-01" },
        .{ .raw = "07/18/14", .expected = "2014-07-18" },
        .{ .raw = "12/31/99", .expected = "1999-12-31" },
        .{ .raw = "01/02/03", .expected = "2003-01-02" },
        .{ .raw = "07/18/684", .expected = "0684-07-18" },
        .{ .raw = "2014/07/18", .expected = "2014-07-18" },
        .{ .raw = "0684/07/18", .expected = "0684-07-18" },
        .{ .raw = "0003/07/18", .expected = "0003-07-18" },
        .{ .raw = "Nov. 2 1999", .expected = "1999-11-02" },
        .{ .raw = "2 Nov.. 1999", .expected = "1999-11-02" },
        .{ .raw = "Sept. 2 1999", .expected = "1999-09-02" },
        .{ .raw = "November. 2 1999", .expected = "1999-11-02" },
        // Observed BN quote inputs, then the exact added grammar boundaries.
        .{ .raw = "30th June 1982", .expected = "1982-06-30" },
        .{ .raw = "Dec.1921", .expected = "1921-12-01" },
        .{ .raw = "1st June 1982", .expected = "1982-06-01" },
        .{ .raw = "2nd June 1982", .expected = "1982-06-02" },
        .{ .raw = "3rd June 1982", .expected = "1982-06-03" },
        .{ .raw = "1th June 1982", .expected = "1982-06-01" },
        .{ .raw = "01st June 1982", .expected = "1982-06-01" },
        .{ .raw = "30th jUnE 1982", .expected = "1982-06-30" },
        .{ .raw = "dec.1921", .expected = "1921-12-01" },
        .{ .raw = "December1921", .expected = "1921-12-01" },
        .{ .raw = "Dec.- \t1921", .expected = "1921-12-01" },
        .{ .raw = "Dec.0684", .expected = "0684-12-01" },
    };
    for (cases) |case| {
        const ts = try parseTimestamp(&ctx, .{ .string = case.raw });
        const got = try formatDateAlloc(std.testing.allocator, ts, "Y-m-d");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
    // These remain outside this bounded addition; not all are upstream-invalid.
    for ([_][]const u8{
        "30thx June 1982",    "30thth June 1982", "+30th June 1982", "030th June 1982",
        "30TH June 1982",     "30th 06 1982",     "0th June 1982",   "32nd June 1982",
        "31st February 1982", "12.1921",          "Dec.84",          "Dec.+921",
        "Dec.1921junk",       "Dec.0000",
        "৩০th June 1982",
        "১৩ এপ্রিল ২০১৫",
        "০১-০১-২০২২",
        "14 মার্চ 1927",
    }) |raw| {
        try std.testing.expectError(error.InvalidDate, parseTimestampText(&ctx, raw));
    }
    try std.testing.expectError(error.InvalidDate, parseTimestamp(&ctx, .{ .string = "2022 July 1" }));
    try std.testing.expectError(error.InvalidDate, parseTimestamp(&ctx, .{ .string = "Feb 84" }));
    try std.testing.expect(parseDottedDate("17.10.09") == null);
    try std.testing.expectError(error.InvalidDate, parseTimestamp(&ctx, .{ .string = "18/07/14" }));
    try std.testing.expectError(error.InvalidDate, parseTimestamp(&ctx, .{ .string = "684/07/18" }));
    try std.testing.expectError(error.InvalidDate, parseTimestamp(&ctx, .{ .string = "2 11. 1999" }));
    const shifted = try parseTimestampText(&ctx, "2013-3-31 +8 days");
    const shifted_text = try formatDateAlloc(std.testing.allocator, shifted, "Y M d");
    defer std.testing.allocator.free(shifted_text);
    try std.testing.expectEqualStrings("2013 Apr 08", shifted_text);
    const julian_shift = try parseTimestampText(&ctx, "22 February 1735+11 day");
    const julian_shift_text = try formatDateAlloc(std.testing.allocator, julian_shift, "j F Y");
    defer std.testing.allocator.free(julian_shift_text);
    try std.testing.expectEqualStrings("5 March 1735", julian_shift_text);
    const attached_negative = try parseTimestampText(&ctx, "2013-04-08-8 days");
    const attached_negative_text = try formatDateAlloc(std.testing.allocator, attached_negative, "Y M d");
    defer std.testing.allocator.free(attached_negative_text);
    try std.testing.expectEqualStrings("2013 Mar 31", attached_negative_text);
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
    const iso = try parseTimestampText(&ctx, "2002-12-18T04:19:52");
    const iso_out = try formatDateAlloc(a, iso, "Y-m-d H:i:s");
    defer a.free(iso_out);
    try std.testing.expectEqualStrings("2002-12-18 04:19:52", iso_out);
    const iso_z = try parseTimestampText(&ctx, "2002-12-18T04:19:52Z");
    try std.testing.expectEqual(iso, iso_z);
    const clock_cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "Jul 18 2003 12:38:20 PM", .expected = "2003-07-18 12:38:20" },
        .{ .raw = "Jul 18 2003 12:38:20 AM", .expected = "2003-07-18 00:38:20" },
        .{ .raw = "Jul 18 2003 1:02 PM", .expected = "2003-07-18 13:02:00" },
        .{ .raw = "Jul 18 2003 1 PM", .expected = "2003-07-18 13:00:00" },
        .{ .raw = "18 Jul 2003 11:59:59 PM", .expected = "2003-07-18 23:59:59" },
        .{ .raw = "Jul 18 2003 23:38:20", .expected = "2003-07-18 23:38:20" },
        .{ .raw = "19:27, 21 March 2023", .expected = "2023-03-21 19:27:00" },
        .{ .raw = "19:27:30, 21 March 2023 (UTC)", .expected = "2023-03-21 19:27:30" },
        .{ .raw = "19:27, 21 March 2023 GMT", .expected = "2023-03-21 19:27:00" },
    };
    for (clock_cases) |case| {
        const timestamp = try parseTimestampText(&ctx, case.raw);
        const actual = try formatDateAlloc(a, timestamp, "Y-m-d H:i:s");
        defer a.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
    try std.testing.expectError(error.InvalidDate, parseTimestampText(&ctx, "7:27 PM, 21 March 2023 (UTC)"));
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT language objects expose MediaWiki helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const registry = try rt.namespace_registry.englishTestRegistry();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    runtime.namespace_catalog = registry;
    var host = host_api.Host{ .now_unix = 1_670_803_200, .date_numbering = DateFormattingProbe.numbering };
    host_api.set(&runtime, &host);
    const month_cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "first day of this month", .expected = "2022-12-01" },
        .{ .raw = "first day of this month - 1 month", .expected = "2022-11-01" },
        .{ .raw = "first day of this month + 1 month", .expected = "2023-01-01" },
        .{ .raw = "first day of last month", .expected = "2022-11-01" },
        .{ .raw = "first day of next month", .expected = "2023-01-01" },
        .{ .raw = "last day of this month", .expected = "2022-12-31" },
    };
    for (month_cases) |case| {
        const timestamp = try parseTimestampText(&runtime, case.raw);
        const actual = try formatDateAlloc(std.testing.allocator, timestamp, "Y-m-d");
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
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
    try std.testing.expectEqual(@as(usize, 0), language.table.map.count());
    const is_rtl = try callField(&runtime, language, "isRTL", &.{language});
    defer rt.freeResults(is_rtl);
    try std.testing.expect(!is_rtl[0].boolean);
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
    try std.testing.expectEqual(@as(f64, -12345.67), parsed[0].number);
    const upper = try callField(&runtime, language, "uc", &.{ language, .{ .string = "straße ﬃ" } });
    defer rt.freeResults(upper);
    try std.testing.expectEqualStrings("STRASSE FFI", upper[0].string);
    const broken = [_]u8{0xc9};
    const broken_upper = try callField(&runtime, language, "uc", &.{ language, .{ .string = &broken } });
    defer rt.freeResults(broken_upper);
    try std.testing.expectEqualSlices(u8, &broken, broken_upper[0].string);
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
    try std.testing.expect(italian[0].table.rawGet(.{ .string = "isRTL" }).? == .callable);
    const italian_is_rtl = try runtime.getIndex(italian[0], .{ .string = "isRTL" });
    try std.testing.expectError(error.AotCallFailed, runtime.callValue(italian_is_rtl, &.{italian[0]}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
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
    const french_upper = try runtime.callValue(upper_fn, &.{ french[0], .{ .string = "abc" } });
    defer rt.freeResults(french_upper);
    try std.testing.expectEqualStrings("ABC", french_upper[0].string);
}

test "AOT edition case uses base full strings and MediaWiki first character classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try rt.namespace_registry.Registry.init(std.testing.allocator, rt.namespace_registry.english_test_fixture);
    defer registry.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    runtime.namespace_catalog = &registry;
    const mw = try runtime.newTable();
    const ustring = try runtime.newNativeNamespace(.ustring);
    const case_mapper = try ustring_lib.install(&runtime, ustring);
    try mw.rawSet(runtime.allocator, .{ .string = "ustring" }, .{ .table = ustring });
    try install(&runtime, mw, case_mapper);

    // Both real regression paths select the edition language, including
    // parser ucfirst/lcfirst, which call these same language object methods.
    const cases = [_]struct { code: []const u8, method: []const u8, source: []const u8, expected: []const u8 }{
        .{ .code = "af", .method = "ucfirst", .source = "koppelvlak", .expected = "Koppelvlak" },
        .{ .code = "af", .method = "lcfirst", .source = "Selfstandig", .expected = "selfstandig" },
        .{ .code = "af", .method = "ucfirst", .source = "selfstandige naamwoorde", .expected = "Selfstandige naamwoorde" },
        .{ .code = "ang", .method = "ucfirst", .source = "wǽre", .expected = "Wǽre" },
        .{ .code = "ang", .method = "lcfirst", .source = "DA", .expected = "dA" },
        .{ .code = "ar", .method = "ucfirst", .source = "عربي", .expected = "عربي" },
        .{ .code = "fr", .method = "ucfirst", .source = "éClair", .expected = "ÉClair" },
        .{ .code = "af", .method = "ucfirst", .source = "ßETA", .expected = "ßETA" },
        .{ .code = "ang", .method = "ucfirst", .source = "ǰfoo", .expected = "J̌foo" },
        .{ .code = "az", .method = "ucfirst", .source = "istanbul", .expected = "İstanbul" },
        .{ .code = "az", .method = "lcfirst", .source = "Istanbul", .expected = "istanbul" },
        .{ .code = "tr", .method = "ucfirst", .source = "istanbul", .expected = "İstanbul" },
        .{ .code = "tr", .method = "ucfirst", .source = "ıSTANBUL", .expected = "ISTANBUL" },
        .{ .code = "tr", .method = "lcfirst", .source = "ISTANBUL", .expected = "ıSTANBUL" },
        .{ .code = "tr", .method = "lcfirst", .source = "İstanbul", .expected = "istanbul" },
        .{ .code = "kaa", .method = "ucfirst", .source = "ırmak", .expected = "Írmak" },
        .{ .code = "kaa", .method = "lcfirst", .source = "Írmak", .expected = "ırmak" },
        // Unknown codes fall back to base; do not infer classes by prefix.
        .{ .code = "az-latn", .method = "ucfirst", .source = "istanbul", .expected = "Istanbul" },
        .{ .code = "tr-unknown", .method = "lcfirst", .source = "Istanbul", .expected = "istanbul" },
    };
    for (cases) |case| {
        registry.content_language = case.code;
        const content = try callField(&runtime, .{ .table = mw }, "getContentLanguage", &.{});
        defer rt.freeResults(content);
        const code = try callField(&runtime, content[0], "getCode", &.{content[0]});
        defer rt.freeResults(code);
        try std.testing.expectEqualStrings(case.code, code[0].string);
        const result = try callField(&runtime, content[0], case.method, &.{ content[0], .{ .string = case.source } });
        defer rt.freeResults(result);
        try std.testing.expectEqualStrings(case.expected, result[0].string);
    }

    for ([_][]const u8{ "af", "ang", "ar", "az", "kaa", "tr", "crh", "crh-cyrl", "crh-latn", "gag", "kiu", "lzz" }) |code| {
        const language = try callField(&runtime, .{ .table = mw }, "getLanguage", &.{.{ .string = code }});
        defer rt.freeResults(language);
        // Full-string case is not Turkish locale case, even in LanguageTr.
        const upper = try callField(&runtime, language[0], "uc", &.{ language[0], .{ .string = "iı straße" } });
        defer rt.freeResults(upper);
        try std.testing.expectEqualStrings("II STRASSE", upper[0].string);
        const lower = try callField(&runtime, language[0], "lc", &.{ language[0], .{ .string = "Iİ ÉCLAIR" } });
        defer rt.freeResults(lower);
        try std.testing.expectEqualStrings("ii̇ éclair", lower[0].string);
    }
    for ([_][]const u8{ "tr", "crh", "crh-cyrl", "crh-latn", "gag", "kiu", "lzz" }) |code| {
        const language = try callField(&runtime, .{ .table = mw }, "getLanguage", &.{.{ .string = code }});
        defer rt.freeResults(language);
        const first = try callField(&runtime, language[0], "ucfirst", &.{ language[0], .{ .string = "istanbul" } });
        defer rt.freeResults(first);
        try std.testing.expectEqualStrings("İstanbul", first[0].string);
        const lower_first = try callField(&runtime, language[0], "lcfirst", &.{ language[0], .{ .string = "Istanbul" } });
        defer rt.freeResults(lower_first);
        try std.testing.expectEqualStrings("ıstanbul", lower_first[0].string);
    }
    // Ustring aliases share full-string base semantics, without a fabricated
    // language context or a different first-character policy leaking into uc.
    const upper = try callField(&runtime, .{ .table = ustring }, "upper", &.{.{ .string = "iı straße" }});
    defer rt.freeResults(upper);
    try std.testing.expectEqualStrings("II STRASSE", upper[0].string);
    const lower = try callField(&runtime, .{ .table = ustring }, "lower", &.{.{ .string = "Iİ ÉCLAIR" }});
    defer rt.freeResults(lower);
    try std.testing.expectEqualStrings("ii̇ éclair", lower[0].string);
    const broken = [_]u8{ 'a', 0xc9, 'B' };
    const broken_upper = try callField(&runtime, .{ .table = ustring }, "upper", &.{.{ .string = &broken }});
    defer rt.freeResults(broken_upper);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0xc9, 'B' }, broken_upper[0].string);
}

const KnownLanguageTagProbe = struct {
    fn get(_: ?*anyopaque, code: []const u8) !bool {
        return std.mem.eql(u8, code, "fr") or std.mem.eql(u8, code, "es");
    }
};

test "AOT language known tags use pinned host registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .language_known_tag = KnownLanguageTagProbe.get };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    const ustring = try runtime.newNativeNamespace(.ustring);
    const case_mapper = try ustring_lib.install(&runtime, ustring);
    try install(&runtime, mw, case_mapper);
    const language_api = mw.rawGet(.{ .string = "language" }).?.table;

    const french = try callField(&runtime, .{ .table = language_api }, "isKnownLanguageTag", &.{.{ .string = "fr" }});
    defer rt.freeResults(french);
    try std.testing.expect(french[0].boolean);
    const unknown = try callField(&runtime, .{ .table = language_api }, "isKnownLanguageTag", &.{.{ .string = "zz-invalid" }});
    defer rt.freeResults(unknown);
    try std.testing.expect(!unknown[0].boolean);
}

const LanguageMetadataProbe = struct {
    const all_rows = [_]host_api.LanguageNameRow{
        .{ .code = "ar", .name = "العربية" },
        .{ .code = "als", .name = "Alemannic" },
    };
    fn names(_: ?*anyopaque, display: ?[]const u8, scope: host_api.LanguageNameScope) ![]const host_api.LanguageNameRow {
        if (display == null or !std.mem.eql(u8, display.?, "ar") or scope == .mwfile) return error.LanguageNameSnapshotMissing;
        return if (scope == .all) &all_rows else all_rows[0..1];
    }
    fn name(_: ?*anyopaque, code: []const u8, display: ?[]const u8) ![]const u8 {
        if (display == null or !std.mem.eql(u8, display.?, "ar")) return error.LanguageNameSnapshotMissing;
        if (std.mem.eql(u8, code, "ar")) return "العربية";
        if (std.mem.eql(u8, code, "als")) return "الألمانية السويسرية";
        return "";
    }
    fn direction(_: ?*anyopaque, code: []const u8) !host_api.LanguageDirection {
        if (std.mem.eql(u8, code, "ar")) return .rtl;
        return error.LanguageDirectionSnapshotMissing;
    }
    fn denied(_: ?*anyopaque, _: []const u8, _: ?[]const u8) ![]const u8 {
        return error.AccessDenied;
    }
    fn oom(_: ?*anyopaque, _: []const u8, _: ?[]const u8) ![]const u8 {
        return error.OutOfMemory;
    }
};

test "captured language names preserve raw table aliases single lookup and mutable result isolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{
        .language_names = LanguageMetadataProbe.names,
        .language_name = LanguageMetadataProbe.name,
        .language_direction = LanguageMetadataProbe.direction,
    };
    host_api.set(&runtime, &host);
    const first = try fetchLanguageNames(null, &runtime, &.{ .{ .string = "AR" }, .{ .string = "all" } });
    defer rt.freeResults(first);
    try std.testing.expectEqualStrings("Alemannic", first[0].table.rawGet(.{ .string = "als" }).?.string);
    try first[0].table.rawSet(runtime.allocator, .{ .string = "ar" }, .{ .string = "changed" });
    const fresh = try fetchLanguageNames(null, &runtime, &.{ .{ .string = "ar" }, .{ .string = "all" } });
    defer rt.freeResults(fresh);
    try std.testing.expectEqualStrings("العربية", fresh[0].table.rawGet(.{ .string = "ar" }).?.string);
    const singular = try fetchLanguageName(null, &runtime, &.{ .{ .string = "ALS" }, .{ .string = "ar" } });
    defer rt.freeResults(singular);
    try std.testing.expectEqualStrings("الألمانية السويسرية", singular[0].string);
    const unknown = try fetchLanguageName(null, &runtime, &.{ .{ .string = "unknown" }, .{ .string = "ar" } });
    defer rt.freeResults(unknown);
    try std.testing.expectEqualStrings("", unknown[0].string);
    const defaults = try fetchLanguageNames(null, &runtime, &.{ .{ .string = "ar" }, .{ .string = "ALL" } });
    defer rt.freeResults(defaults);
    try std.testing.expect(defaults[0].table.rawGet(.{ .string = "als" }) == null);
    try std.testing.expectError(error.LanguageNameSnapshotMissing, fetchLanguageNames(null, &runtime, &.{ .{ .string = "ar" }, .{ .string = "mwfile" } }));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, fetchLanguageNames(null, &runtime, &.{}));
    const legacy = try fetchLanguageName(null, &runtime, &.{.{ .string = "en" }});
    defer rt.freeResults(legacy);
    try std.testing.expectEqualStrings("English", legacy[0].string);
    host.language_name = LanguageMetadataProbe.denied;
    try std.testing.expectError(error.AccessDenied, fetchLanguageName(null, &runtime, &.{ .{ .string = "ar" }, .{ .string = "ar" } }));
    host.language_name = LanguageMetadataProbe.oom;
    try std.testing.expectError(error.OutOfMemory, fetchLanguageName(null, &runtime, &.{ .{ .string = "ar" }, .{ .string = "ar" } }));
}

test "language getDir uses captured direction and preserves English without inventing unknown direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .language_direction = LanguageMetadataProbe.direction };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    const ustring = try runtime.newNativeNamespace(.ustring);
    const mapper = try ustring_lib.install(&runtime, ustring);
    try install(&runtime, mw, mapper);
    const api = mw.rawGet(.{ .string = "language" }).?;
    host.language_names = LanguageMetadataProbe.names;
    const installed_names = try callField(&runtime, api, "fetchLanguageNames", &.{ .{ .string = "ar" }, .{ .string = "all" } });
    defer rt.freeResults(installed_names);
    try std.testing.expectEqualStrings("العربية", installed_names[0].table.rawGet(.{ .string = "ar" }).?.string);
    inline for (.{ .{ "ar", "rtl" }, .{ "en", "ltr" } }) |case| {
        const lang = try callField(&runtime, api, "new", &.{.{ .string = case[0] }});
        defer rt.freeResults(lang);
        const direction = try callField(&runtime, lang[0], "getDir", &.{lang[0]});
        defer rt.freeResults(direction);
        try std.testing.expectEqualStrings(case[1], direction[0].string);
    }
    const unknown = try callField(&runtime, api, "new", &.{.{ .string = "zz-unknown" }});
    defer rt.freeResults(unknown);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, unknown[0], "getDir", &.{unknown[0]}));
    try std.testing.expectEqualStrings("LanguageDirectionSnapshotMissing", runtime.aotErrorName().?);
}

const FormattedNumberMessageProbe = struct {
    source: ?[]const u8 = "synthetic NaN label",
    failure: ?anyerror = null,
    absent: bool = false,
    fn message(raw: ?*anyopaque, _: std.mem.Allocator, language: []const u8, key: []const u8) !?host_api.InterfaceMessage {
        const self: *FormattedNumberMessageProbe = @ptrCast(@alignCast(raw.?));
        if (!std.mem.eql(u8, language, "ar") or !std.mem.eql(u8, key, "formatnum-nan")) return error.UnexpectedMessageLookup;
        if (self.failure) |err| return err;
        if (self.absent) return null;
        return .{ .source = self.source };
    }
};

fn formattedNumberAllocationProbe(a: std.mem.Allocator) !void {
    const normalized = try normalizeFormattedNumberAlloc(a, "−١٢٬٣٤٥٫٦٧", true);
    defer a.free(normalized);
    try std.testing.expectEqualStrings("-12345.67", normalized);
}

test "Arabic formatted-number normalization releases failed allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, formattedNumberAllocationProbe, .{});
}

test "Arabic parseFormattedNumber returns numbers or nil for Quran surah names and exact digit separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var probe = FormattedNumberMessageProbe{};
    var host = host_api.Host{ .ctx = &probe, .interface_message = FormattedNumberMessageProbe.message };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    const ustring = try runtime.newNativeNamespace(.ustring);
    const mapper = try ustring_lib.install(&runtime, ustring);
    try install(&runtime, mw, mapper);
    const api = mw.rawGet(.{ .string = "language" }).?;
    const language = try callField(&runtime, api, "new", &.{.{ .string = "ar" }});
    defer rt.freeResults(language);
    const cases = [_]struct { input: []const u8, expected: ?f64 }{
        .{ .input = "يونس", .expected = null },
        .{ .input = "٢٤", .expected = 24 },
        .{ .input = "−١٢٬٣٤٥٫٦٧", .expected = -12345.67 },
        .{ .input = "1,٢٣٤٫5", .expected = 1234.5 },
        .{ .input = "١e−٢", .expected = 0.01 },
        .{ .input = " \t٢٤\r\n", .expected = 24 },
        .{ .input = "1,,2", .expected = 12 },
        .{ .input = "", .expected = null },
        .{ .input = "1٫2٫3", .expected = null },
        .{ .input = "۱۲", .expected = null }, // Persian digits are not the Arabic table.
        .{ .input = " +∞", .expected = null },
        .{ .input = " ∞ ", .expected = null },
        .{ .input = "∞", .expected = std.math.inf(f64) },
        .{ .input = "−∞", .expected = -std.math.inf(f64) },
    };
    for (cases) |case| {
        const parsed = try callField(&runtime, language[0], "parseFormattedNumber", &.{ language[0], .{ .string = case.input } });
        defer rt.freeResults(parsed);
        if (case.expected) |number| {
            try std.testing.expect(parsed[0] == .number);
            try std.testing.expectEqual(number, parsed[0].number);
        } else try std.testing.expect(parsed[0] == .nil);
    }
    const numeric = try callField(&runtime, language[0], "parseFormattedNumber", &.{ language[0], .{ .number = 24 } });
    defer rt.freeResults(numeric);
    try std.testing.expectEqual(@as(f64, 24), numeric[0].number);
    for ([_]Value{ .nil, .{ .boolean = false }, .{ .table = try runtime.newTable() } }) |value| {
        const parsed = try callField(&runtime, language[0], "parseFormattedNumber", &.{ language[0], value });
        defer rt.freeResults(parsed);
        try std.testing.expect(parsed[0] == .nil);
    }
    probe.source = "24"; // Exact message comparison precedes digit normalization.
    const nan = try callField(&runtime, language[0], "parseFormattedNumber", &.{ language[0], .{ .string = "24" } });
    defer rt.freeResults(nan);
    try std.testing.expect(std.math.isNan(nan[0].number));
}

test "Arabic number parsing preserves missing message and provider errors while other locales remain unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var language = LanguageCtx{ .code = "ar", .case_mapper = undefined };
    const args = [_]Value{ .nil, .{ .string = "يونس" } };
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, languageParseFormattedNumber(&language, &runtime, &args));
    var probe = FormattedNumberMessageProbe{ .absent = true };
    var host = host_api.Host{ .ctx = &probe, .interface_message = FormattedNumberMessageProbe.message };
    host_api.set(&runtime, &host);
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, languageParseFormattedNumber(&language, &runtime, &args));
    probe.absent = false;
    probe.failure = error.AccessDenied;
    try std.testing.expectError(error.AccessDenied, languageParseFormattedNumber(&language, &runtime, &args));
    probe.failure = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, languageParseFormattedNumber(&language, &runtime, &args));
    probe.failure = null;
    probe.source = null;
    try std.testing.expectError(error.UnsupportedFormattedNumberNanMessage, languageParseFormattedNumber(&language, &runtime, &args));
    probe.source = "{{dynamic message}}";
    try std.testing.expectError(error.UnsupportedFormattedNumberNanMessage, languageParseFormattedNumber(&language, &runtime, &args));
    language.code = "fa";
    try std.testing.expectError(error.NotImplemented, languageParseFormattedNumber(&language, &runtime, &args));
    language.code = "en";
    const ordinary_english = try languageParseFormattedNumber(&language, &runtime, &.{ .nil, .{ .string = "−1,234.5" } });
    defer rt.freeResults(ordinary_english);
    try std.testing.expectEqual(@as(f64, -1234.5), ordinary_english[0].number);
    try std.testing.expectError(error.StringExpected, languageParseFormattedNumber(&language, &runtime, &.{.nil}));
}

const DateFormattingProbe = struct {
    timezone: []const u8 = "UTC",
    profile_failure: ?anyerror = null,
    message_failure: ?anyerror = null,
    message_source: ?[]const u8 = null,
    absent_message: bool = false,
    missing_message: bool = false,
    const ascii_digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    const bengali_digits = [_][]const u8{ "০", "১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯" };
    const months = [_][]const u8{ "জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই", "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর" };
    fn numbering(raw: ?*anyopaque, code: []const u8) !host_api.DateNumbering {
        const self: ?*DateFormattingProbe = if (raw) |ptr| @ptrCast(@alignCast(ptr)) else null;
        if (self) |probe| if (probe.profile_failure) |err| return err;
        if (std.mem.eql(u8, code, "unknown")) return error.DateNumberingUnsupported;
        if (!std.mem.eql(u8, code, "bn") and !std.mem.eql(u8, code, "fr") and !std.mem.eql(u8, code, "ar") and !std.mem.eql(u8, code, "en")) return error.DateNumberingSnapshotMissing;
        return .{
            .digits = if (std.mem.eql(u8, code, "bn")) bengali_digits else ascii_digits,
            .timezone = if (self) |probe| probe.timezone else "UTC",
        };
    }
    fn message(raw: ?*anyopaque, _: std.mem.Allocator, code: []const u8, key: []const u8) !?host_api.InterfaceMessage {
        const self: *DateFormattingProbe = @ptrCast(@alignCast(raw.?));
        if (self.message_failure) |err| return err;
        if (self.absent_message) return null;
        if (self.missing_message) return .{ .source = null };
        if (self.message_source) |source| return .{ .source = source };
        for (date_month_keys, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, key)) {
                if (std.mem.eql(u8, code, "bn")) return .{ .source = months[i] };
                if (std.mem.eql(u8, code, "fr") and i == 2) return .{ .source = "mars" };
                if (std.mem.eql(u8, code, "ar") and i == 2) return .{ .source = "مارس" };
            }
        }
        if (std.mem.eql(u8, key, "march-gen")) return .{ .source = "captured-genitive" };
        if (std.mem.eql(u8, key, "mar")) return .{ .source = "captured-abbreviation" };
        if (std.mem.eql(u8, key, "wednesday")) return .{ .source = "captured-weekday" };
        if (std.mem.eql(u8, key, "wed")) return .{ .source = "captured-weekday-short" };
        return error.InterfaceMessageSnapshotMissing;
    }
};

test "localized Gregorian date formatting uses exact messages and effective site digits across locales" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var probe = DateFormattingProbe{};
    var host = host_api.Host{ .ctx = &probe, .date_numbering = DateFormattingProbe.numbering, .interface_message = DateFormattingProbe.message };
    host_api.set(&runtime, &host);
    const timestamp = try parseTimestampText(&runtime, "2024-03-27");
    const cases = [_]struct { code: []const u8, format: []const u8, expected: []const u8 }{
        .{ .code = "bn", .format = "j F '''Y'''", .expected = "২৭ মার্চ '''২০২৪'''" },
        .{ .code = "fr", .format = "j F Y", .expected = "27 mars 2024" },
        // arwiktionary disables TranslateNumerals: captured ASCII is authoritative.
        .{ .code = "ar", .format = "j F Y", .expected = "27 مارس 2024" },
        .{ .code = "bn", .format = "xnF j j xNY xNY", .expected = "মার্চ 27 ২৭ 2024 ২০২৪" },
        .{ .code = "bn", .format = "\"Y\" \\Y Y xx xq", .expected = "Y Y ২০২৪ x q" },
        .{ .code = "bn", .format = "d y m n H G g h i s w N z W t L o I Z", .expected = "২৭ ২৪ ০৩ ৩ ০০ ০ ১২ ১২ ০০ ০০ ৩ ৩ ৮৬ ১৩ ৩১ ১ ২০২৪ ০ ০" },
        .{ .code = "bn", .format = "M xg l D", .expected = "captured-abbreviation captured-genitive captured-weekday captured-weekday-short" },
        .{ .code = "bn", .format = "c r e T O P", .expected = "2024-03-27T00:00:00+00:00 Wed, 27 Mar 2024 00:00:00 +0000 UTC UTC +0000 +00:00" },
    };
    for (cases) |case| {
        const profile = try dateNumbering(&runtime, case.code);
        const actual = try localizedDateAlloc(&runtime, case.code, profile, timestamp, case.format);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
    const profile = try dateNumbering(&runtime, "bn");
    const zero_year = try localizedDateAlloc(&runtime, "bn", profile, -62167219200, "Y o");
    try std.testing.expectEqualStrings("০০০০ -1", zero_year);
    const first_year = try localizedDateAlloc(&runtime, "bn", profile, daysFromCivil(1, 1, 4) * std.time.s_per_day, "Y o");
    try std.testing.expectEqualStrings("০০০১ ১", first_year);
    inline for (.{ .{ "xiQ", "Q" }, .{ "xjQ", "Q" }, .{ "xkQ", "Q" }, .{ "xmQ", "Q" }, .{ "xoQ", "Q" }, .{ "xtQ", "Q" }, .{ "xi", "i" } }) |extension| {
        const unknown = try localizedDateAlloc(&runtime, "bn", profile, timestamp, extension[0]);
        try std.testing.expectEqualStrings(extension[1], unknown);
    }
    const negative = try localizedDateAlloc(&runtime, "bn", profile, -1, "U");
    try std.testing.expectEqualStrings("-1", negative);
    const raw = try localizedDateAlloc(&runtime, "bn", profile, 1234567890, "U xnU");
    try std.testing.expectEqualStrings("১২৩৪৫৬৭৮৯০ 1234567890", raw);
    // Numeral replacement never touches captured names or quoted literal digits.
    probe.message_source = "name3";
    const literal = try localizedDateAlloc(&runtime, "bn", profile, timestamp, "F \"123\"");
    try std.testing.expectEqualStrings("name3 123", literal);
    var variable = profile;
    variable.digits[2] = "২২";
    const multi = try localizedDateAlloc(&runtime, "bn", variable, timestamp, "j");
    try std.testing.expectEqualStrings("২২৭", multi);
}

test "localized dates preserve absent unknown malformed and provider failures without English substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var lang = LanguageCtx{ .code = "bn", .case_mapper = undefined };
    const args = [_]Value{ .nil, .{ .string = "j F Y" }, .{ .string = "2024-03-27" } };
    try std.testing.expectError(error.DateNumberingSnapshotMissing, languageFormatDate(&lang, &runtime, &args));
    try std.testing.expectError(error.StringExpected, languageFormatDate(&lang, &runtime, &.{ .nil, .{ .string = "Y" }, .{ .number = 2024 }, .{ .number = 1 } }));
    try std.testing.expectError(error.InvalidDate, languageFormatDate(&lang, &runtime, &.{ .nil, .{ .string = "Y" }, .{ .string = "invalid" } }));
    var probe = DateFormattingProbe{};
    var host = host_api.Host{ .ctx = &probe, .date_numbering = DateFormattingProbe.numbering };
    host_api.set(&runtime, &host);
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, languageFormatDate(&lang, &runtime, &args));
    host.interface_message = DateFormattingProbe.message;
    probe.profile_failure = error.AccessDenied;
    try std.testing.expectError(error.AccessDenied, languageFormatDate(&lang, &runtime, &args));
    probe.profile_failure = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, languageFormatDate(&lang, &runtime, &args));
    probe.profile_failure = null;
    lang.code = "unknown";
    try std.testing.expectError(error.DateNumberingUnsupported, languageFormatDate(&lang, &runtime, &args));
    lang.code = "missing";
    try std.testing.expectError(error.DateNumberingSnapshotMissing, languageFormatDate(&lang, &runtime, &args));
    lang.code = "bn";
    probe.absent_message = true;
    try std.testing.expectError(error.InterfaceMessageSnapshotMissing, languageFormatDate(&lang, &runtime, &args));
    probe.absent_message = false;
    probe.missing_message = true;
    try std.testing.expectError(error.UnsupportedDateMessage, languageFormatDate(&lang, &runtime, &args));
    probe.missing_message = false;
    probe.message_source = "{{dynamic}}";
    try std.testing.expectError(error.UnsupportedDateMessage, languageFormatDate(&lang, &runtime, &args));
    probe.message_source = null;
    probe.message_failure = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, languageFormatDate(&lang, &runtime, &args));
    probe.message_failure = null;
    probe.timezone = "Europe/Paris";
    const local_args = [_]Value{ .nil, .{ .string = "Y" }, .{ .string = "2024-03-27" }, .{ .boolean = true } };
    try std.testing.expectError(error.UnsupportedDateTimezone, languageFormatDate(&lang, &runtime, &local_args));
    // Default output stays UTC even for a site whose local zone is unsupported.
    const ordinary = try languageFormatDate(&lang, &runtime, &args);
    defer rt.freeResults(ordinary);
    try std.testing.expectEqualStrings("২৭ মার্চ ২০২৪", ordinary[0].string);
    probe.timezone = "UTC";
    const local_utc = try languageFormatDate(&lang, &runtime, &local_args);
    defer rt.freeResults(local_utc);
    try std.testing.expectEqualStrings("২০২৪", local_utc[0].string);
    try std.testing.expectError(error.BooleanExpected, languageFormatDate(&lang, &runtime, &.{ .nil, .{ .string = "Y" }, .nil, .{ .string = "true" } }));
    try std.testing.expectError(error.InvalidDate, languageFormatDate(&lang, &runtime, &.{ .nil, .{ .string = "Y" }, .{ .string = "not-a-date" } }));
    const profile = try dateNumbering(&runtime, "bn");
    const timestamp = try parseTimestampText(&runtime, "2024-03-27");
    for ([_][]const u8{ "xiY", "xjF", "xmj", "xtY", "xkY", "xoY" }) |format|
        try std.testing.expectError(error.UnsupportedDateCalendar, localizedDateAlloc(&runtime, "bn", profile, timestamp, format));
    for ([_][]const u8{ "xrY", "xhY" }) |format|
        try std.testing.expectError(error.UnsupportedDateNumeralMode, localizedDateAlloc(&runtime, "bn", profile, timestamp, format));
    try std.testing.expectError(error.InvalidDate, localizedDateAlloc(&runtime, "bn", profile, 253402300800, "Y"));
}

fn dateFormattingAllocationProbe(a: std.mem.Allocator) !void {
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    var probe = DateFormattingProbe{};
    var host = host_api.Host{ .ctx = &probe, .date_numbering = DateFormattingProbe.numbering, .interface_message = DateFormattingProbe.message };
    host_api.set(&runtime, &host);
    const profile = try dateNumbering(&runtime, "bn");
    const actual = try localizedDateAlloc(&runtime, "bn", profile, 1711497600, "j F Y c r");
    defer a.free(actual);
    try std.testing.expect(std.mem.startsWith(u8, actual, "২৭ মার্চ ২০২৪"));
}
test "localized date output releases partially allocated output on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dateFormattingAllocationProbe, .{});
}
