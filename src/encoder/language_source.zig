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
    // The Amharic entry form labels a field "language" and puts the actual
    // language name on its first body line. Preserve the whole value: a list
    // of languages or a topic must not become an arbitrary first match.
    if (std.mem.eql(u8, std.mem.trim(u8, heading, " \t"), "ቋንቋ")) {
        if (std.mem.indexOfScalar(u8, section.source, '\n')) |newline| {
            var lines = std.mem.splitScalar(u8, section.source[newline + 1 ..], '\n');
            while (lines.next()) |line| {
                var value = std.mem.trim(u8, line, " \t\r");
                if (value.len == 0) continue;
                if (value[0] == '*') value = std.mem.trim(u8, value[1..], " \t");
                if (std.mem.startsWith(u8, value, "[[") and std.mem.endsWith(u8, value, "]]"))
                    value = value[2 .. value.len - 2];
                if (value.len != 0 and std.mem.indexOfAny(u8, value, "{}[]<>|=") == null) return value;
                break;
            }
        }
    }
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
    marker_filter: ?MarkerFilter = null,

    pub const MarkerFilter = struct {
        ctx: ?*const anyopaque,
        accepts: *const fn (?*const anyopaque, []const u8) bool,
    };

    pub fn init(source: []const u8) Iterator {
        return .{ .source = source };
    }

    pub fn initWithMarkerFilter(source: []const u8, filter: MarkerFilter) Iterator {
        return .{ .source = source, .marker_filter = filter };
    }

    fn languageMarker(self: *const Iterator, line: []const u8) ?[]const u8 {
        const code = parseStandaloneLanguageMarker(line) orelse return null;
        if (self.marker_filter) |filter| if (!filter.accepts(filter.ctx, code)) return null;
        return code;
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
                const marker = if (heading == null) self.languageMarker(line) else null;
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
        if (self.comments == 0) {
            if (std.mem.startsWith(u8, content, "{|")) self.tables += 1;
            if (std.mem.startsWith(u8, content, "|}") and self.tables != 0) self.tables -= 1;
        }
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (self.comments != 0) {
                if (std.mem.startsWith(u8, line[i..], "-->")) {
                    self.comments = 0;
                    i += 2;
                }
                continue;
            }
            if (i + 4 <= line.len and std.mem.eql(u8, line[i .. i + 4], "<!--")) {
                self.comments = 1;
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

fn parseHeading(raw: []const u8) ?ParsedHeading {
    const line = std.mem.trimEnd(u8, raw, " \t");
    if (line.len < 3 or line[0] != '=') return null;
    var left: usize = 0;
    while (left < line.len and line[left] == '=') : (left += 1) {}
    var right = line.len;
    while (right != 0 and line[right - 1] == '=') : (right -= 1) {}
    const right_width = line.len - right;
    if (right_width == 0) return null;
    const level: usize = @min(6, @min(left, right_width));
    if (line.len < level * 2) return null;
    const title = std.mem.trim(u8, line[level .. line.len - level], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(level), .title = title };
}

/// Literal page category links, excluding comments, template arguments and
/// protected source. Namespace and language validation belong to the caller.
pub const CategoryIterator = struct {
    source: []const u8,
    cursor: usize = 0,
    templates: usize = 0,

    pub fn next(self: *CategoryIterator) ?[]const u8 {
        while (self.cursor < self.source.len) {
            const start = self.cursor;
            const rest = self.source[start..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const close = std.mem.indexOfPos(u8, self.source, start + 4, "-->") orelse {
                    self.cursor = self.source.len;
                    return null;
                };
                self.cursor = close + 3;
                continue;
            }
            if (rest[0] == '<') {
                for ([_][]const u8{ "nowiki", "pre", "source", "syntaxhighlight", "math", "includeonly" }) |name| {
                    if (tagMatches(rest, name, false)) {
                        const opening_end = std.mem.indexOfScalar(u8, rest, '>') orelse {
                            self.cursor = self.source.len;
                            return null;
                        };
                        self.cursor = start + opening_end + 1;
                        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, rest[0..opening_end], " \t\r\n"), "/")) break;
                        while (std.mem.indexOfScalarPos(u8, self.source, self.cursor, '<')) |close| {
                            self.cursor = close + 1;
                            if (!tagMatches(self.source[close..], name, true)) continue;
                            const end = std.mem.indexOfScalarPos(u8, self.source, close, '>') orelse self.source.len - 1;
                            self.cursor = end + 1;
                            break;
                        } else self.cursor = self.source.len;
                        break;
                    }
                }
                if (self.cursor != start) continue;
            }
            if (std.mem.startsWith(u8, rest, "{{")) {
                self.templates += 1;
                self.cursor += 2;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "}}")) {
                self.templates -|= 1;
                self.cursor += 2;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "[[")) {
                const close = std.mem.indexOfPos(u8, self.source, start + 2, "]]") orelse {
                    self.cursor = self.source.len;
                    return null;
                };
                self.cursor = close + 2;
                const body = self.source[start + 2 .. close];
                if (self.templates != 0 or std.mem.indexOfAny(u8, body, "[]{}<>") != null) continue;
                const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
                const target = std.mem.trim(u8, body[0..pipe], " \t\r\n");
                if (target.len != 0 and target[0] != ':') return target;
                continue;
            }
            self.cursor += 1;
        }
        return null;
    }

    fn tagMatches(source: []const u8, name: []const u8, closing: bool) bool {
        const offset: usize = if (closing) 2 else 1;
        if (source.len <= offset + name.len or source[0] != '<') return false;
        if (closing and source[1] != '/') return false;
        if (!std.ascii.eqlIgnoreCase(source[offset..][0..name.len], name)) return false;
        const boundary = source[offset + name.len];
        return boundary == '>' or boundary == '/' or std.ascii.isWhitespace(boundary);
    }
};

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

test "registry marker filter keeps grammar templates within a language section" {
    const filter: Iterator.MarkerFilter = .{
        .ctx = null,
        .accepts = struct {
            fn accepts(_: ?*const anyopaque, code: []const u8) bool {
                return std.mem.eql(u8, code, "af") or std.mem.eql(u8, code, "nl");
            }
        }.accepts,
    };
    var it = Iterator.initWithMarkerFilter("{{=af=}}\n{{-uitspraak-}}\n{{-woordafbreking-}}\n{{-vert-}}\n# Afrikaans\n{{=nl=}}\n{{-noun-}}\n# Dutch\n", filter);
    const first = it.next().?;
    try std.testing.expectEqualStrings("af", first.heading);
    try std.testing.expect(std.mem.indexOf(u8, first.source, "{{-woordafbreking-}}") != null);
    try std.testing.expectEqualStrings("nl", it.next().?.heading);
    try std.testing.expect(it.next() == null);
}

test "language boundaries match rendered heading whitespace and comment semantics" {
    var it = Iterator.init("<!-- instructions mention <!-- and {{ without opening syntax\n{| hidden\n-->\n==English== \t\n# entry\n==French==\n# second\n");
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expectEqualStrings("French", it.next().?.heading);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqualStrings("English=", parseHeading("==English=== ").?.title);
    try std.testing.expectEqual(@as(u8, 6), parseHeading("=======deep=======").?.level);
}

test "Amharic language field keeps complete unambiguous values" {
    try std.testing.expectEqualStrings("እንግሊዝኛ", classificationSection(.{
        .heading = "ቋንቋ",
        .source = "==ቋንቋ==\n* [[እንግሊዝኛ]]\n===ስም===\n# meaning\n",
    }));
    try std.testing.expectEqualStrings("ቋንቋ", classificationSection(.{
        .heading = "ቋንቋ",
        .source = "==ቋንቋ==\n[[እንግሊዝኛ]]፣ [[ፈረንሳይኛ]]\n",
    }));
}

test "category attribution ignores hidden source and colon-prefixed links" {
    var it: CategoryIterator = .{ .source = "<!-- [[Category:French]] <!-- example -->\n" ++
        "<NOWIKI>[[Category:German]]</NOWIKI>\n" ++
        "<pre>[[Category:Spanish]]</pre>\n" ++
        "<syntaxhighlight lang=\"text\">[[Category:Italian]]</syntaxhighlight>\n" ++
        "<includeonly>[[Category:Dutch]]</includeonly>\n" ++
        "{{example|[[Category:Greek]]}}\n" ++
        "[[:Category:Portuguese]]\n" ++
        "<nowiki/>[[Category:English|sort key]]\n" };
    try std.testing.expectEqualStrings("Category:English", it.next().?);
    try std.testing.expect(it.next() == null);
}
