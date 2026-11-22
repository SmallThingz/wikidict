const std = @import("std");

const Source = enum { mdy, dmy, ymd, iso, ydm, dm, md };
const Preference = enum { none, mdy, dmy, ymd, iso };
const Year = struct {
    raw: []const u8,
    digits: []const u8,
    bc: bool,
};
const Pair = struct {
    day: []const u8,
    month: u8,
};
const Match = struct {
    source: Source,
    day: []const u8,
    month: ?u8 = null,
    iso_month: ?[]const u8 = null,
    year: ?Year = null,
    iso_year: ?[]const u8 = null,
};

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
fn asciiDigits(raw: []const u8, min: usize, max: usize) bool {
    if (raw.len < min or raw.len > max) return false;
    for (raw) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn monthNumber(raw: []const u8) ?u8 {
    for (month_names, 1..) |name, i| {
        if (std.ascii.eqlIgnoreCase(raw, name) or
            (raw.len == 3 and std.ascii.eqlIgnoreCase(raw, name[0..3]))) return @intCast(i);
    }
    return null;
}

fn parsePair(raw: []const u8, day_first: bool) ?Pair {
    for (raw, 0..) |c, i| {
        if (c != ' ' and c != '_') continue;
        const lhs = raw[0..i];
        const rhs = raw[i + 1 ..];
        if (lhs.len == 0 or rhs.len == 0) continue;
        const day = if (day_first) lhs else rhs;
        const month_raw = if (day_first) rhs else lhs;
        if (!asciiDigits(day, 1, 2)) continue;
        const month = monthNumber(month_raw) orelse continue;
        return .{ .day = day, .month = month };
    }
    return null;
}
fn parseYear(raw: []const u8) ?Year {
    var digits = raw;
    var bc = false;
    if (raw.len > 3 and (std.ascii.eqlIgnoreCase(raw[raw.len - 3 ..], " BC") or
        std.ascii.eqlIgnoreCase(raw[raw.len - 3 ..], "_BC")))
    {
        const suffix = raw[raw.len - 3 ..];
        digits = raw[0 .. raw.len - 3];
        bc = std.mem.eql(u8, suffix, " BC") or std.mem.eql(u8, suffix, "_BC");
    }
    if (!asciiDigits(digits, 1, 4)) return null;
    return .{ .raw = raw, .digits = digits, .bc = bc };
}
fn makeNamed(source: Source, pair_raw: []const u8, year_raw: []const u8, day_first: bool) ?Match {
    const pair = parsePair(pair_raw, day_first) orelse return null;
    const year = parseYear(year_raw) orelse return null;
    return .{
        .source = source,
        .day = pair.day,
        .month = pair.month,
        .year = year,
    };
}

fn parsePairYear(raw: []const u8, source: Source, day_first: bool, pair_first: bool) ?Match {
    for (raw, 0..) |c, i| if (c == ',') {
        const lhs = std.mem.trimEnd(u8, raw[0..i], " ");
        const rhs = std.mem.trimStart(u8, raw[i + 1 ..], " ");
        if (makeNamed(source, if (pair_first) lhs else rhs, if (pair_first) rhs else lhs, day_first)) |value|
            return value;
    };
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != ' ') {
            i += 1;
            continue;
        }
        const start = i;
        while (i < raw.len and raw[i] == ' ') i += 1;
        if (start == 0 or i == raw.len) continue;
        const lhs = raw[0..start];
        const rhs = raw[i..];
        if (makeNamed(source, if (pair_first) lhs else rhs, if (pair_first) rhs else lhs, day_first)) |value|
            return value;
    }
    return null;
}

fn parseIso(raw: []const u8) ?Match {
    const offset: usize = if (raw.len != 0 and raw[0] == '-') 1 else 0;
    if (raw.len != offset + 10 or raw[offset + 4] != '-' or raw[offset + 7] != '-') return null;
    if (!asciiDigits(raw[offset .. offset + 4], 4, 4) or
        !asciiDigits(raw[offset + 5 .. offset + 7], 2, 2) or
        !asciiDigits(raw[offset + 8 .. offset + 10], 2, 2)) return null;
    return .{
        .source = .iso,
        .day = raw[offset + 8 .. offset + 10],
        .iso_month = raw[offset + 5 .. offset + 7],
        .iso_year = raw[0 .. offset + 4],
    };
}

fn parseDate(raw: []const u8) ?Match {
    if (parsePairYear(raw, .mdy, false, true)) |value| return value;
    if (parsePairYear(raw, .dmy, true, true)) |value| return value;
    if (parsePairYear(raw, .ymd, false, false)) |value| return value;
    if (parseIso(raw)) |value| return value;
    if (parsePairYear(raw, .ydm, true, false)) |value| return value;
    if (parsePair(raw, true)) |pair| return .{ .source = .dm, .day = pair.day, .month = pair.month };
    if (parsePair(raw, false)) |pair| return .{ .source = .md, .day = pair.day, .month = pair.month };
    return null;
}

fn preference(raw: ?[]const u8) Preference {
    const value = if (raw) |text| std.mem.trim(u8, text, " \t\r\n") else return .none;
    if (std.mem.eql(u8, value, "mdy")) return .mdy;
    if (std.mem.eql(u8, value, "dmy")) return .dmy;
    if (std.mem.eql(u8, value, "ymd")) return .ymd;
    if (std.mem.eql(u8, value, "ISO 8601")) return .iso;
    return .none;
}
fn target(source: Source, pref: Preference) Source {
    return switch (pref) {
        .none => source,
        .mdy => if (source == .dm or source == .md) .md else .mdy,
        .dmy => if (source == .dm or source == .md) .dm else .dmy,
        .ymd => if (source == .dm or source == .md) source else .ymd,
        .iso => if (source == .dm or source == .md) source else .iso,
    };
}

fn isoYearAlloc(a: std.mem.Allocator, year: Year) ![]const u8 {
    const value = try std.fmt.parseInt(i64, year.digits, 10);
    if (year.bc) {
        const shifted = value - 1;
        if (shifted < 0) return std.fmt.allocPrint(a, "--{d:0>3}", .{@as(u64, @intCast(-shifted))});
        return std.fmt.allocPrint(a, "-{d:0>4}", .{@as(u64, @intCast(shifted))});
    }
    return std.fmt.allocPrint(a, "{d:0>4}", .{@as(u64, @intCast(value))});
}

fn normalYearAlloc(a: std.mem.Allocator, iso: []const u8) ![]const u8 {
    const value = try std.fmt.parseInt(i64, iso, 10);
    if (value > 0) return std.fmt.allocPrint(a, "{d}", .{value});
    const digits = if (iso.len > 1) iso[1..] else "0";
    const bc = (std.fmt.parseInt(i64, digits, 10) catch 0) + 1;
    return std.fmt.allocPrint(a, "{d} BC", .{bc});
}
pub fn format(a: std.mem.Allocator, raw_value: []const u8, preference_raw: ?[]const u8) ![]const u8 {
    const raw = std.mem.trim(u8, raw_value, " \t\r\n");
    const matched = parseDate(raw) orelse return raw;

    const iso_month = matched.iso_month orelse
        try std.fmt.allocPrint(a, "{d:0>2}", .{matched.month.?});
    const iso_day = if (matched.source == .iso)
        matched.day
    else
        try std.fmt.allocPrint(a, "{d:0>2}", .{try std.fmt.parseInt(u8, matched.day, 10)});
    const iso_year: ?[]const u8 = if (matched.iso_year) |year|
        year
    else if (matched.year) |year|
        try isoYearAlloc(a, year)
    else
        null;
    const canonical = if (iso_year) |year|
        try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ year, iso_month, iso_day })
    else
        try std.fmt.allocPrint(a, "{s}-{s}", .{ iso_month, iso_day });

    const output_format = target(matched.source, preference(preference_raw));
    if (output_format == .iso)
        return std.fmt.allocPrint(a, "<span class=\"mw-formatted-date\" title=\"{s}\">{s}</span>", .{ canonical, canonical });
    const month_number = matched.month orelse blk: {
        const value = std.fmt.parseInt(u8, iso_month, 10) catch return raw;
        if (value < 1 or value > 12) return raw;
        break :blk value;
    };
    const month = month_names[month_number - 1];
    const day = if (matched.source == .iso)
        try std.fmt.allocPrint(a, "{d}", .{try std.fmt.parseInt(u8, matched.day, 10)})
    else
        matched.day;
    const year: ?[]const u8 = if (matched.year) |value|
        value.raw
    else if (matched.iso_year) |value|
        try normalYearAlloc(a, value)
    else
        null;

    const display = switch (output_format) {
        .mdy => try std.fmt.allocPrint(a, "{s} {s}, {s}", .{ month, day, year.? }),
        .dmy => try std.fmt.allocPrint(a, "{s} {s} {s}", .{ day, month, year.? }),
        .ymd => try std.fmt.allocPrint(a, "{s} {s} {s}", .{ year.?, month, day }),
        .ydm => try std.fmt.allocPrint(a, "{s}, {s} {s}", .{ year.?, day, month }),
        .dm => try std.fmt.allocPrint(a, "{s} {s}", .{ day, month }),
        .md => try std.fmt.allocPrint(a, "{s} {s}", .{ month, day }),
        .iso => unreachable,
    };
    return std.fmt.allocPrint(a, "<span class=\"mw-formatted-date\" title=\"{s}\">{s}</span>", .{ canonical, display });
}
test "MediaWiki DateFormatter source grammar and preferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"2010-01-02\">2 January 2010</span>",
        try format(a, "2010-01-02", "dmy"),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"2010-01-02\">2 January 2010</span>",
        try format(a, "January 2, 2010", " dmy "),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"2010-01-02\">January 2, 2010</span>",
        try format(a, "2 January 2010", "mdy"),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"2010-09-02\">September 2, 2010</span>",
        try format(a, "Sep 2, 2010", null),
    );
    try std.testing.expectEqualStrings("2-Jan-2010", try format(a, "2-Jan-2010", "dmy"));
    try std.testing.expectEqualStrings("2010-01", try format(a, "2010-01", null));
}
test "MediaWiki DateFormatter partial and BC dates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"01-02\">2 January</span>",
        try format(a, "January 2", "dmy"),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"-0000-01-01\">-0000-01-01</span>",
        try format(a, "1 January 1 BC", "ISO 8601"),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"0001-01-01\">0001-01-01</span>",
        try format(a, "1 January 1 bc", "ISO 8601"),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"-0001-01-02\">2 January 2 BC</span>",
        try format(a, "-0001-01-02", "dmy"),
    );
    try std.testing.expectEqualStrings(
        "<span class=\"mw-formatted-date\" title=\"--001-01-01\">--001-01-01</span>",
        try format(a, "1 January 0 BC", "ISO 8601"),
    );
}
