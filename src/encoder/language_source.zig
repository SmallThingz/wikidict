const std = @import("std");
const syntax = @import("blob_encoder").wikitext_syntax;

const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

pub const Section = struct {
    heading: []const u8,
    source: []const u8,
    hyphen_marker: bool = false,
};

/// A language declaration remains a boundary even when its label is unknown.
/// Keep this separate from name resolution and from ordinary grammar headings.
pub fn explicitLanguageDeclaration(raw: []const u8, content_language: []const u8) ?[]const u8 {
    const declaration = if (std.mem.eql(u8, content_language, "ar")) "اللغة" else if (std.mem.eql(u8, content_language, "az")) "Dil" else return null;
    const heading = std.mem.trim(u8, raw, " \t");
    if (!std.mem.startsWith(u8, heading, "{{") or !std.mem.endsWith(u8, heading, "}}")) return null;
    const body = heading[2 .. heading.len - 2];
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, body[0..pipe], " \t"), declaration)) return null;
    const label = std.mem.trim(u8, body[pipe + 1 ..], " \t");
    if (label.len == 0 or std.mem.indexOfAny(u8, label, "{}[]<>|=\r\n") != null) return null;
    return label;
}

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
    var categories: CategoryIterator = .{ .source = source };
    while (categories.next()) |target| {
        inline for (&.{ "קטגוריה:שפה ", "קטגוריה: שפה " }) |marker| {
            if (std.mem.startsWith(u8, target, marker)) {
                const language = std.mem.trim(u8, target[marker.len..], " \t\r\n");
                if (language.len != 0 and std.mem.indexOfAny(u8, language, "{}[]") == null) return language;
            }
        }
    }
    return null;
}

fn hebrewGrammarTemplate(source: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const rest = source[cursor..];
        if (syntax.protectedEnd(source, cursor)) |end| {
            cursor = end;
            continue;
        }
        if (rest[0] == '<') if (syntax.tagAt(source, cursor)) |tag| {
            cursor = tag.end;
            continue;
        };
        if (std.mem.startsWith(u8, rest, "{{") or std.mem.startsWith(u8, rest, "[[")) {
            const pair = syntax.balanced(source, cursor) orelse return false;
            if (std.mem.startsWith(u8, rest, "{{") and !std.mem.startsWith(u8, rest, "{{{")) {
                const body = source[cursor + 2 .. pair.inner_end];
                const end = syntax.delimiter(body, "|", 0) orelse body.len;
                if (std.mem.eql(u8, std.mem.trim(u8, body[0..end], " \t\r\n"), "ניתוח דקדוקי")) return true;
            }
            cursor = pair.end;
            continue;
        }
        cursor += 1;
    }
    return false;
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
    if (hebrewGrammarTemplate(section.source)) return "עברית";
    return section.heading;
}

pub const Iterator = struct {
    source: []const u8,
    cursor: usize = 0,
    active_start: ?usize = null,
    active_heading: []const u8 = "",
    active_hyphen_marker: bool = false,
    active_level: ?u8 = null,
    balance: Balance = .{},
    done: bool = false,
    marker_filter: ?MarkerFilter = null,
    heading_filter: ?MarkerFilter = null,
    mixed_levels: bool = false,
    control_matcher: ?syntax.ControlMatcher = null,

    pub const MarkerFilter = struct {
        ctx: ?*const anyopaque,
        accepts: *const fn (?*const anyopaque, []const u8) bool,
        accepts_equals: ?*const fn (?*const anyopaque, []const u8) bool = null,
    };

    pub fn init(source: []const u8) Iterator {
        return .{ .source = source };
    }

    pub fn initWithMarkerFilter(source: []const u8, filter: MarkerFilter) Iterator {
        return .{ .source = source, .marker_filter = filter };
    }

    fn languageMarker(self: *const Iterator, line: []const u8) ?[]const u8 {
        const code = parseStandaloneLanguageMarker(line) orelse return null;
        if (self.marker_filter) |filter| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
            const accepts = if (body[0] == '=') filter.accepts_equals orelse filter.accepts else filter.accepts;
            if (!accepts(filter.ctx, code)) return null;
        }
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

            if (!self.balance.isOpen() and line_start >= self.balance.protected_until) {
                const heading = parseHeading(syntax.headingControlPrefix(line, self.control_matcher));
                const marker = if (heading == null) self.languageMarker(line) else null;
                const hyphen_marker = if (marker != null) blk: {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
                    break :blk body[0] == '-';
                } else false;
                const candidate_level: ?u8 = if (heading) |value|
                    if (value.level == 1 or value.level == 2) value.level else null
                else if (marker != null) 2 else null;
                if (candidate_level) |level| {
                    if (self.active_level == null) self.active_level = level;
                    const title = if (heading) |value| value.title else marker.?;
                    const declared = if (self.heading_filter) |filter| filter.accepts(filter.ctx, title) else false;
                    if (level == self.active_level.? or declared) {
                        if (level != self.active_level.?) self.mixed_levels = true;
                        self.active_level = level;
                        if (self.active_start) |start| {
                            const result: Section = .{
                                .heading = self.active_heading,
                                .source = self.source[start..line_start],
                                .hyphen_marker = self.active_hyphen_marker,
                            };
                            self.active_start = line_start;
                            self.active_heading = title;
                            self.active_hyphen_marker = hyphen_marker;
                            return result;
                        }
                        self.active_start = line_start;
                        self.active_heading = title;
                        self.active_hyphen_marker = hyphen_marker;
                        continue;
                    }
                }
            }
            self.balance.update(self.source, line_start, content_end);
        }

        self.done = true;
        if (self.active_start) |start| {
            self.active_start = null;
            return .{ .heading = self.active_heading, .source = self.source[start..], .hyphen_marker = self.active_hyphen_marker };
        }
        return null;
    }
};

/// Exact noun declarations within one L2 lemma. English is an explicit alias
/// in frozen names.lua en.codes; German is a source-specific known declaration
/// from Aal rev1429569, not a generic imported alias or morphology algorithm.
pub const ArabicNounSubtree = struct { present: bool = false, code: ?[]const u8 = null };

pub fn arabicNounSubtree(section: Section, matcher: ?syntax.ControlMatcher) ArabicNounSubtree {
    const newline = std.mem.indexOfScalar(u8, section.source, '\n') orelse return .{};
    const outer = parseHeading(syntax.headingControlPrefix(section.source[0..newline], matcher)) orelse return .{};
    if (outer.level != 2 or !std.mem.eql(u8, outer.title, section.heading)) return .{};
    var balance: Balance = .{};
    var cursor = newline + 1;
    var declarations: usize = 0;
    var code: ?[]const u8 = null;
    var saw_heading = false;
    var invalid = false;
    while (cursor < section.source.len) {
        const end = std.mem.indexOfScalarPos(u8, section.source, cursor, '\n') orelse section.source.len;
        const line = section.source[cursor..end];
        if (!balance.isOpen() and cursor >= balance.protected_until) {
            if (parseHeading(syntax.headingControlPrefix(line, matcher))) |heading| {
                if (heading.level <= 2) return .{};
                if (heading.level == 3) {
                    const label = std.mem.trim(u8, heading.title, " \t\r");
                    if (std.mem.startsWith(u8, label, "اسم ")) {
                        declarations += 1;
                        if (saw_heading or declarations != 1) invalid = true;
                        const adjective = std.mem.trim(u8, label["اسم ".len..], " \t");
                        code = if (std.mem.eql(u8, adjective, "إنجليزي")) "en" else if (std.mem.eql(u8, adjective, "ألماني")) "de" else null;
                        if (code == null) invalid = true;
                    }
                    saw_heading = true;
                }
            }
        }
        balance.update(section.source, cursor, end);
        cursor = if (end == section.source.len) end else end + 1;
    }
    return .{ .present = declarations != 0, .code = if (declarations == 1 and !invalid) code else null };
}

const Balance = struct {
    templates: usize = 0,
    links: usize = 0,
    comments: usize = 0,
    tables: usize = 0,
    protected_until: usize = 0,

    fn update(self: *Balance, source: []const u8, line_start: usize, line_end: usize) void {
        const line = source[line_start..line_end];
        const content = std.mem.trimStart(u8, line, " \t");
        if (self.comments == 0 and line_start >= self.protected_until) {
            if (std.mem.startsWith(u8, content, "{|")) self.tables += 1;
            if (std.mem.startsWith(u8, content, "|}") and self.tables != 0) self.tables -= 1;
        }
        var i: usize = @min(line.len, self.protected_until -| line_start);
        while (i < line.len) : (i += 1) {
            if (self.comments != 0) {
                if (std.mem.startsWith(u8, line[i..], "-->")) {
                    self.comments = 0;
                    i += 2;
                }
                continue;
            }
            if (line[i] == '<' and !std.mem.startsWith(u8, line[i..], "<!--")) {
                const absolute = line_start + i;
                const token_end: ?usize = syntax.protectedEnd(source, absolute) orelse
                    if (self.templates == 0) (if (syntax.tagAt(source, absolute)) |tag| tag.end else null) else null;
                if (token_end) |end| {
                    self.protected_until = end;
                    if (end >= line_end) return;
                    i = end - line_start - 1;
                    continue;
                }
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
                if (syntax.protectedEnd(self.source, start)) |end| {
                    self.cursor = end;
                    continue;
                }
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
                if (self.templates == 0) {
                    if (syntax.tagAt(self.source, start)) |tag| {
                        self.cursor = tag.end;
                        continue;
                    }
                }
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

test "explicit Arabic language declarations do not depend on known labels" {
    try std.testing.expectEqualStrings("دانماركية", explicitLanguageDeclaration("{{اللغة|دانماركية}}", "ar").?);
    try std.testing.expectEqualStrings("كتالونية", explicitLanguageDeclaration(" {{ اللغة | كتالونية }} ", "ar").?);
    try std.testing.expect(explicitLanguageDeclaration("{{اللغة|دانماركية}}", "en") == null);
    inline for (.{ "دانماركية", "اسم", "{{اسم|دانماركية}}", "{{اللغة|}}", "{{اللغة|{{nested}}}}", "{{اللغة|دانماركية|extra}}", "{{اللغة|name=دانماركية}}", "prefix {{اللغة|دانماركية}}" }) |heading|
        try std.testing.expect(explicitLanguageDeclaration(heading, "ar") == null);
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

test "mixed language depths preserve ordinary nested POS" {
    const english = "=English=\n==Noun==\n# english\n";
    const french = "==French==\n===Nom===\n# french\n";
    var it = Iterator.init(english ++ french ++ "=English=\n# second\n");
    it.heading_filter = .{ .ctx = null, .accepts = struct {
        fn accepts(_: ?*const anyopaque, heading: []const u8) bool {
            return std.mem.eql(u8, heading, "English") or std.mem.eql(u8, heading, "French");
        }
    }.accepts };
    try std.testing.expectEqualStrings(english, it.next().?.source);
    try std.testing.expectEqualStrings(french, it.next().?.source);
    try std.testing.expectEqualStrings("=English=\n# second\n", it.next().?.source);
    try std.testing.expect(it.next() == null);
}

test "mixed language boundaries change active depth in both directions" {
    const english = "==English==\n===Noun===\n# english\n";
    const french = "=French=\n==Nom==\n# french\n";
    var it = Iterator.init(english ++ french ++ "==English==\n===Verb===\n# second\n");
    it.heading_filter = .{ .ctx = null, .accepts = struct {
        fn accepts(_: ?*const anyopaque, heading: []const u8) bool {
            return std.mem.eql(u8, heading, "English") or std.mem.eql(u8, heading, "French");
        }
    }.accepts };
    try std.testing.expectEqualStrings(english, it.next().?.source);
    try std.testing.expectEqualStrings(french, it.next().?.source);
    try std.testing.expectEqualStrings("==English==\n===Verb===\n# second\n", it.next().?.source);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(it.mixed_levels);
}

test "language boundaries ignore protected bodies and quoted tag delimiters" {
    const bodies = [_][]const u8{
        "# <nowiki>[[</nowiki>\n",                                "# <pre>{{</pre>\n",
        "# <span title=\"[[\">visible</span>\n",                  "<nowiki>\n==German==\n{{\n</nowiki>\n",
        "<span title=\"first\n==German==\n[[\">visible</span>\n",
    };
    for (bodies) |body| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ "==English==\n", body, "==French==\n# chat\n" });
        defer std.testing.allocator.free(source);
        var it = Iterator.init(source);
        try std.testing.expectEqualStrings("English", it.next().?.heading);
        try std.testing.expectEqualStrings("French", it.next().?.heading);
        try std.testing.expect(it.next() == null);
    }
    for ([_][]const u8{ "==English==\n[[open\n==French==\n", "==English==\n{{open|\n==French==\n" }) |source| {
        var it = Iterator.init(source);
        try std.testing.expectEqualStrings("English", it.next().?.heading);
        try std.testing.expect(it.next() == null);
    }
}

test "category attribution ignores quoted tag targets and keeps active categories" {
    for ([_][]const u8{
        "<span title=\"[[Category:German]]\">visible</span>[[Category:English]]",
        "<includeonly>[[Category:German]]</includeonly>[[Category:English]]",
        "<nowiki>[[Category:German]]</nowiki>[[Category:English]]",
    }) |source| {
        var it: CategoryIterator = .{ .source = source };
        try std.testing.expectEqualStrings("Category:English", it.next().?);
        try std.testing.expect(it.next() == null);
    }
}

test "language and category scanners preserve outer template brace handling" {
    var sections = Iterator.init("==English==\n{{x|<span title=\"}}\">text</span>\n==French==\n# chat\n");
    try std.testing.expectEqualStrings("English", sections.next().?.heading);
    try std.testing.expectEqualStrings("French", sections.next().?.heading);
    try std.testing.expect(sections.next() == null);
    var categories: CategoryIterator = .{ .source = "{{x|<span title=\"}}\">[[Category:English]]</span>" };
    try std.testing.expectEqualStrings("Category:English", categories.next().?);
    try std.testing.expect(categories.next() == null);
}

test "language headings accept active control suffix without consuming literal suffix" {
    var it = Iterator.init("=English=__NOTOC__ __NOEDITSECTION__\n# first\n=French=\n# second\n");
    const first = it.next().?;
    try std.testing.expectEqualStrings("English", first.heading);
    try std.testing.expect(std.mem.indexOf(u8, first.source, "# first") != null);
    try std.testing.expectEqualStrings("French", it.next().?.heading);
    try std.testing.expect(it.next() == null);
    var literal = Iterator.init("=English=__UNKNOWN__\n# retained\n");
    try std.testing.expect(literal.next() == null);
}


test "Hebrew raw conventions ignore protected category and grammar literals" {
    const negative = [_][]const u8{
        "==lemma==\n<nowiki>[[קטגוריה:שפה ספרדית]]</nowiki>\n",
        "==lemma==\n<pre>[[קטגוריה:שפה ספרדית]]</pre>\n",
        "==lemma==\n<!-- [[קטגוריה:שפה ספרדית]] -->\n",
        "==lemma==\n{{example|[[קטגוריה:שפה ספרדית]]}}\n",
        "==lemma==\n<span data-note=\"[[קטגוריה:שפה ספרדית]]\">text</span>\n",
        "==lemma==\n<nowiki>{{ניתוח דקדוקי|x}}</nowiki>\n",
        "==lemma==\n<pre>{{ניתוח דקדוקי|x}}</pre>\n",
        "==lemma==\n<!-- {{ניתוח דקדוקי|x}} -->\n",
        "==lemma==\n{{example|{{ניתוח דקדוקי|x}}}}\n",
        "==lemma==\n<span data-note=\"{{ניתוח דקדוקי|x}}\">text</span>\n",
        "==lemma==\n{{ניתוח דקדוקי lookalike|x}}\n",
        "==lemma==\n{{ניתוח דקדוקי|unclosed\n",
        "==lemma==\n{{ניתוח דקדוקי|{{{x}}}}\n",
        "==lemma==\n{{ניתוח דקדוקי {{x}} }}\n",
        "==lemma==\n<ref>[[קטגוריה:שפה ספרדית]]</ref>\n",
        "==lemma==\n<ref>{{ניתוח דקדוקי|x}}</ref>\n",
    };
    for (negative) |source|
        try std.testing.expectEqualStrings("lemma", classificationSection(.{ .heading = "lemma", .source = source }));
    try std.testing.expectEqualStrings("ספרדית", classificationSection(.{
        .heading = "lemma",
        .source = "==lemma==\n<nowiki>[[קטגוריה:שפה עברית]]</nowiki>\n[[קטגוריה:שפה ספרדית|sort]]\n",
    }));
    try std.testing.expectEqualStrings("עברית", classificationSection(.{
        .heading = "lemma",
        .source = "==lemma==\n<!-- {{ניתוח דקדוקי|fake}} -->\n{{ניתוח דקדוקי|real}}\n",
    }));
    try std.testing.expectEqualStrings("עברית", classificationSection(.{
        .heading = "lemma",
        .source = "==lemma==\n{{ ניתוח דקדוקי | nested={{x|value}} }}\n",
    }));
    try std.testing.expectEqualStrings("עברית", classificationSection(.{
        .heading = "lemma",
        .source = "==lemma==\n{{ניתוח דקדוקי|{{{x}}}}}\n",
    }));
}
