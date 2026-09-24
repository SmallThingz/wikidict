const std = @import("std");

const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

pub const Section = struct {
    heading: []const u8,
    source: []const u8,
};

/// Some Wiktionaries put the lemma and a language template in the level-2
/// heading instead of using the language name as the whole heading. Keep this
/// classification build-only and derived from the unexpanded source so template
/// expansion cannot erase the language argument.
pub fn classificationHeading(raw: []const u8) []const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, raw, search, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, raw, open + 2, "}}") orelse break;
        const body = raw[open + 2 .. close];
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse {
            search = close + 2;
            continue;
        };
        const name = std.mem.trim(u8, body[0..pipe], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Sprache")) {
            const tail = body[pipe + 1 ..];
            const next_pipe = std.mem.indexOfScalar(u8, tail, '|') orelse tail.len;
            const language = std.mem.trim(u8, tail[0..next_pipe], " \t");
            if (language.len != 0 and std.mem.indexOfAny(u8, language, "{}[]") == null) return language;
        }
        search = close + 2;
    }
    return raw;
}

fn hebrewLanguageCategory(source: []const u8) ?[]const u8 {
    inline for (&.{ "[[קטגוריה:שפה ", "[[קטגוריה: שפה " }) |marker| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, source, search, marker)) |at| {
            const start = at + marker.len;
            const close = std.mem.indexOfPos(u8, source, start, "]]") orelse return null;
            const pipe = std.mem.indexOfScalarPos(u8, source, start, '|');
            const end = if (pipe != null and pipe.? < close) pipe.? else close;
            const language = std.mem.trim(u8, source[start..end], " \t\r\n");
            if (language.len != 0 and std.mem.indexOfAny(u8, language, "{}[]") == null) return language;
            search = close + 2;
        }
    }
    return null;
}

pub fn classificationSection(section: Section) []const u8 {
    const heading = classificationHeading(section.heading);
    if (!std.mem.eql(u8, heading, section.heading)) return heading;
    if (hebrewLanguageCategory(section.source)) |language| return language;
    if (std.mem.indexOf(u8, section.source, "{{ניתוח דקדוקי") != null) return "עברית";
    return section.heading;
}

pub const Iterator = struct {
    source: []const u8,
    cursor: usize = 0,
    active_start: ?usize = null,
    active_heading: []const u8 = "",
    active_level: ?u8 = null,
    balance: Balance = .{},
    done: bool = false,

    pub fn init(source: []const u8) Iterator {
        return .{ .source = source };
    }

    pub fn next(self: *Iterator) ?Section {
        if (self.done) return null;
        while (self.cursor < self.source.len) {
            const line_start = self.cursor;
            const newline = std.mem.indexOfScalarPos(u8, self.source, line_start, '\n') orelse self.source.len;
            var content_end = newline;
            if (content_end != line_start and self.source[content_end - 1] == '\r') content_end -= 1;
            const line = self.source[line_start..content_end];
            self.cursor = if (newline == self.source.len) self.source.len else newline + 1;

            if (!self.balance.isOpen()) {
                const heading = parseHeading(line);
                const marker = if (heading == null) parseStandaloneLanguageMarker(line) else null;
                const candidate_level: ?u8 = if (heading) |value|
                    if (value.level == 1 or value.level == 2) value.level else null
                else if (marker != null) 2 else null;
                if (candidate_level) |level| {
                    if (self.active_level == null) self.active_level = level;
                    if (level == self.active_level.?) {
                        const title = if (heading) |value| value.title else marker.?;
                        if (self.active_start) |start| {
                            const result: Section = .{
                                .heading = self.active_heading,
                                .source = self.source[start..line_start],
                            };
                            self.active_start = line_start;
                            self.active_heading = title;
                            return result;
                        }
                        self.active_start = line_start;
                        self.active_heading = title;
                        continue;
                    }
                }
            }
            self.balance.update(line);
        }

        self.done = true;
        if (self.active_start) |start| {
            self.active_start = null;
            return .{ .heading = self.active_heading, .source = self.source[start..] };
        }
        return null;
    }
};

const Balance = struct {
    templates: usize = 0,
    links: usize = 0,
    comments: usize = 0,
    tables: usize = 0,

    fn update(self: *Balance, line: []const u8) void {
        const content = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, content, "{|")) self.tables += 1;
        if (std.mem.startsWith(u8, content, "|}") and self.tables != 0) self.tables -= 1;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (i + 4 <= line.len and std.mem.eql(u8, line[i .. i + 4], "<!--")) {
                self.comments += 1;
                i += 3;
                continue;
            }
            if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "-->")) {
                if (self.comments != 0) self.comments -= 1;
                i += 2;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "{{")) {
                self.templates += 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "}}")) {
                if (self.templates != 0) self.templates -= 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "[[")) {
                self.links += 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "]]")) {
                if (self.links != 0) self.links -= 1;
                i += 1;
            }
        }
    }

    fn isOpen(self: Balance) bool {
        return self.templates != 0 or self.links != 0 or self.comments != 0 or self.tables != 0;
    }
};

fn parseStandaloneLanguageMarker(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 7 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return null;
    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
    if (body.len >= 3 and body[0] == '=' and body[body.len - 1] == '=') {
        const code = std.mem.trim(u8, body[1 .. body.len - 1], " \t");
        if (validMarkerCode(code)) return code;
    }
    if (body.len >= 3 and body[0] == '-' and body[body.len - 1] == '-') {
        const code = std.mem.trim(u8, body[1 .. body.len - 1], " \t");
        if (validMarkerCode(code)) return code;
    }
    return null;
}

fn validMarkerCode(code: []const u8) bool {
    if (code.len < 2 or code.len > 16) return false;
    for (code) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-')) return false;
    return true;
}

fn parseHeading(line: []const u8) ?ParsedHeading {
    if (line.len < 3 or line[0] != '=') return null;
    var left: usize = 0;
    while (left < line.len and line[left] == '=') : (left += 1) {}
    if (left < 1 or left > 6) return null;
    var right = line.len;
    while (right != 0 and line[right - 1] == '=') : (right -= 1) {}
    if (line.len - right != left or right <= left) return null;
    const title = std.mem.trim(u8, line[left..right], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(left), .title = title };
}

test "language sections ignore preamble and nested fake headings" {
    const source = "{{also|cat}}\n==English==\n{{foo|\n==not French==\n}}\n===Noun===\n# cat\n==French==\r\n===Nom===\n# chat\n";
    var it = Iterator.init(source);
    const english = it.next().?;
    try std.testing.expectEqualStrings("English", english.heading);
    try std.testing.expect(std.mem.startsWith(u8, english.source, "==English=="));
    try std.testing.expect(std.mem.indexOf(u8, english.source, "==not French==") != null);
    const french = it.next().?;
    try std.testing.expectEqualStrings("French", french.heading);
    try std.testing.expect(std.mem.startsWith(u8, french.source, "==French=="));
    try std.testing.expect(it.next() == null);
}

test "repeated language sections remain separate" {
    const source = "==English==\n# first\n==French==\n# milieu\n==English==\n# second\n";
    var it = Iterator.init(source);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expectEqualStrings("French", it.next().?.heading);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expect(it.next() == null);
}

test "language iterator accepts level-one boundaries and standalone code markers" {
    var level_one = Iterator.init("= {{-be-}} =\n===Noun===\n# one\n= {{-bg-}} =\n===Noun===\n# two\n");
    try std.testing.expectEqualStrings("{{-be-}}", level_one.next().?.heading);
    try std.testing.expectEqualStrings("{{-bg-}}", level_one.next().?.heading);
    try std.testing.expect(level_one.next() == null);

    var markers = Iterator.init("{{=nld=}}\n{{-noun-|nld}}\n# huis\n{{=enm=}}\n{{-noun-|enm}}\n# hous\n");
    try std.testing.expectEqualStrings("nld", markers.next().?.heading);
    try std.testing.expectEqualStrings("enm", markers.next().?.heading);
    try std.testing.expect(markers.next() == null);
}

test "table subheadings do not become language sections" {
    const source = "{| class=wikitable\n== AC ==\n|-\n| entry\n|}\n==English==\n===Noun===\n# meaning\n";
    var it = Iterator.init(source);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expect(it.next() == null);
}

test "raw section conventions classify German and Hebrew languages" {
    try std.testing.expectEqualStrings("Deutsch", classificationHeading("Hallo ({{Sprache|Deutsch}})"));
    try std.testing.expectEqualStrings("Latein", classificationHeading("ordo ({{ Sprache | Latein }})"));
    try std.testing.expectEqualStrings("English", classificationHeading("English"));
    try std.testing.expectEqualStrings("x ({{Sprache|{{bad}}}})", classificationHeading("x ({{Sprache|{{bad}}}})"));
    try std.testing.expectEqualStrings("ספרדית", classificationSection(.{
        .heading = "HOTEL",
        .source = "==HOTEL==\n{{ניתוח דקדוקי מקוצר|}}[[קטגוריה:שפה ספרדית]]\n",
    }));
    try std.testing.expectEqualStrings("עברית", classificationSection(.{
        .heading = "מָלוֹן",
        .source = "==מָלוֹן==\n{{ניתוח דקדוקי|חלק דיבר=שם־עצם}}\n",
    }));
}
