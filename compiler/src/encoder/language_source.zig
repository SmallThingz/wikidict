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
    root_wiki_heading: bool = false,
    adjacent_root_rule: ?usize = null,
};

/// A language declaration remains a boundary even when its label is unknown.
/// Keep this separate from name resolution and from ordinary grammar headings.
pub fn explicitLanguageDeclaration(raw: []const u8, content_language: []const u8) ?[]const u8 {
    // JA L p318906/r1367401 invokes the section-name-by-code formatter.
    // Its unresolved code still declares a boundary; it does not create an alias.
    const declaration = if (std.mem.eql(u8, content_language, "ar")) "اللغة" else if (std.mem.eql(u8, content_language, "az")) "Dil" else if (std.mem.eql(u8, content_language, "ja")) "L" else return null;
    const heading = std.mem.trim(u8, raw, " \t");
    if (std.mem.eql(u8, content_language, "ar")) {
        for ([_][]const u8{ "لغة", "اللغة" }) |prefix| {
            if (!std.mem.startsWith(u8, heading, prefix) or heading.len <= prefix.len or
                (heading[prefix.len] != ' ' and heading[prefix.len] != '\t')) continue;
            const label = std.mem.trim(u8, heading[prefix.len..], " \t");
            if (label.len == 0 or std.mem.indexOfAny(u8, label, "{}[]<>|=\r\n") != null) return null;
            return label;
        }
    }
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
    var protection: ProtectionScan = .{};
    while (search < raw.len) {
        if (protection.protectedEnd(raw, search)) |end| {
            search = end;
            continue;
        }
        if (raw[search] == '<') if (protection.tagAt(raw, search)) |tag| {
            search = tag.end;
            continue;
        };
        if (!std.mem.startsWith(u8, raw[search..], "{{")) {
            search += 1;
            continue;
        }
        const open = search;
        const pair = syntax.balancedWithOpaqueScan(raw, open, &protection.opaque_scan) orelse break;
        const body = raw[open + 2 .. pair.inner_end];
        const pipe = syntax.delimiter(body, "|", 0) orelse {
            search = pair.end;
            continue;
        };
        const name = std.mem.trim(u8, body[0..pipe], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Sprache")) {
            const tail = body[pipe + 1 ..];
            const next_pipe = syntax.delimiter(tail, "|", 0) orelse tail.len;
            const language = std.mem.trim(u8, tail[0..next_pipe], " \t");
            if (language.len != 0 and std.mem.indexOfAny(u8, language, "{}[]<>") == null) return language;
        }
        search = pair.end;
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
    var protection: ProtectionScan = .{};
    while (cursor < source.len) {
        const rest = source[cursor..];
        if (protection.protectedEnd(source, cursor)) |end| {
            cursor = end;
            continue;
        }
        if (rest[0] == '<') if (protection.tagAt(source, cursor)) |tag| {
            cursor = tag.end;
            continue;
        };
        if (std.mem.startsWith(u8, rest, "{{") or std.mem.startsWith(u8, rest, "[[")) {
            const pair = syntax.balancedWithOpaqueScan(source, cursor, &protection.opaque_scan) orelse return false;
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

// A full-source renderer observation proves which balanced links expose
// page headings. Category sort keys and file captions keep their local scope.
pub const LinkHeadingScopes = struct {
    source: []const u8,
    openings: []const usize,

    pub fn admits(self: LinkHeadingScopes, source: []const u8, opening: usize) bool {
        if (source.ptr != self.source.ptr or source.len != self.source.len) return false;
        var low: usize = 0;
        var high = self.openings.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.openings[middle] < opening) low = middle + 1 else high = middle;
        }
        return low < self.openings.len and self.openings[low] == opening;
    }
};

/// Only the renderer's original page-body observation may supply these offsets.
/// The parser below describes syntax; this scope carries its admitted domain.
pub const HtmlHeadingScopes = struct {
    source: []const u8,
    openings: []const usize,
    namespace_catalog: ?*const @import("namespace_registry").Registry = null,
    linked_h1_filter: ?Iterator.MarkerFilter = null,
    category_h1_filter: ?Iterator.MarkerFilter = null,

    fn heading(self: HtmlHeadingScopes, source: []const u8, start: usize, line: []const u8) ?ParsedHeading {
        const scope: LinkHeadingScopes = .{ .source = self.source, .openings = self.openings };
        if (!scope.admits(source, start)) return null;
        if (plainLineHtmlH2(line)) |label| return .{ .level = 2, .title = label };
        if (categoryLinkedLineHtmlH1(line, self.namespace_catalog)) |label| {
            const source_filter = self.category_h1_filter orelse return null;
            if (!source_filter.accepts(source_filter.ctx, line)) return null;
            const owner_filter = self.linked_h1_filter orelse return null;
            if (!owner_filter.accepts(owner_filter.ctx, label)) return null;
            return .{ .level = 1, .title = label };
        }
        const linked = plainLineHtmlH1(line) orelse literalBracketLineHtmlH1(line) orelse
            linkedLineHtmlH1(line, self.namespace_catalog) orelse return null;
        const filter = self.linked_h1_filter orelse return null;
        if (!filter.accepts(filter.ctx, linked)) return null;
        return .{ .level = 1, .title = linked };
    }
};

/// Borrow the label of one complete plain HTML h2 line. This does not establish
/// a language owner or authorize headings in a nested/protected source domain.
pub fn plainLineHtmlH2(line: []const u8) ?[]const u8 {
    return plainLineHtmlHeading(line, "h2");
}

/// Syntax only; an H1 owner still requires the observed root and trusted filter.
pub fn plainLineHtmlH1(line: []const u8) ?[]const u8 {
    return plainLineHtmlHeading(line, "h1");
}

// The interrupted-heading preparation preserves the opening brackets as
// literal entities. They remain body content, not part of the H1 label. This
// syntax helper supplies no authority without an observed original root H1.
pub const literal_h1_prefix = "&#91;&#91;";
pub fn literalBracketLineHtmlH1(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, literal_h1_prefix)) return null;
    return plainLineHtmlH1(line[literal_h1_prefix.len..]);
}

fn plainLineHtmlHeading(line: []const u8, name: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '<' or std.mem.indexOfAny(u8, line, "\r\n") != null) return null;
    const tag = syntax.tagAt(line, 0) orelse return null;
    if (!tag.is(name) or tag.closing or tag.self_closing) return null;
    const pair = syntax.matchingTag(line, tag) orelse return null;
    if (pair.end != line.len) return null;
    const label = std.mem.trim(u8, line[tag.end..pair.inner_end], " \t");
    if (label.len == 0 or std.mem.indexOfAny(u8, label, "{}[]<>&|=\r\n") != null) return null;
    return label;
}

/// Conservative scheduling hint only. The renderer still proves page scope.
/// Match its physical-line CR trimming so CRLF cannot hide a possible heading.
pub fn mayHavePlainLineHtmlH2(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (plainLineHtmlH2(std.mem.trimEnd(u8, line, "\r")) != null) return true;
    }
    return false;
}

/// A borrowed linked H1 label with only nonvisible category controls after it.
/// Syntax and namespaces do not supply an owner: the caller also needs the
/// original renderer scope and its normal trusted language-heading resolver.
pub fn linkedLineHtmlH1(line: []const u8, namespaces: ?*const @import("namespace_registry").Registry) ?[]const u8 {
    const catalog = namespaces orelse return null;
    if (line.len == 0 or line[0] != '<' or std.mem.indexOfAny(u8, line, "\r\n") != null) return null;
    const tag = syntax.tagAt(line, 0) orelse return null;
    if (!tag.is("h1") or tag.closing or tag.self_closing) return null;
    const pair = syntax.matchingTag(line, tag) orelse return null;
    const heading = std.mem.trim(u8, line[tag.end..pair.inner_end], " \t");
    if (!std.mem.startsWith(u8, heading, "[[")) return null;
    const link = syntax.balanced(heading, 0) orelse return null;
    if (link.end != heading.len) return null;
    const body = heading[2..link.inner_end];
    if (std.mem.indexOfAny(u8, body, "[]{}<>&\r\n") != null) return null;
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    const target = std.mem.trim(u8, body[0..pipe], " \t");
    if (target.len == 0 or std.mem.indexOfAny(u8, target, ":#") != null or catalog.ofTitle(target).id != 0) return null;
    if (pipe != body.len) {
        const label = std.mem.trim(u8, body[pipe + 1 ..], " \t");
        if (label.len == 0 or std.mem.indexOfScalar(u8, label, '|') != null) return null;
    }
    var tail = std.mem.trim(u8, line[pair.end..], " \t");
    while (tail.len != 0) {
        if (!std.mem.startsWith(u8, tail, "[[")) return null;
        const category = syntax.balanced(tail, 0) orelse return null;
        const fields = tail[2..category.inner_end];
        if (std.mem.indexOfAny(u8, fields, "[]{}<>&\r\n") != null) return null;
        const delimiter = std.mem.indexOfScalar(u8, fields, '|') orelse fields.len;
        const title = std.mem.trim(u8, fields[0..delimiter], " \t");
        if (title.len == 0 or title[0] == ':' or std.mem.indexOfScalar(u8, title, '#') != null) return null;
        const resolved = catalog.ofTitle(title);
        if (resolved.id != 14 or std.mem.trim(u8, resolved.text, " \t").len == 0) return null;
        if (delimiter != fields.len and std.mem.indexOfScalar(u8, fields[delimiter + 1 ..], '|') != null) return null;
        tail = std.mem.trim(u8, tail[category.end..], " \t");
    }
    return heading;
}

// Syntax only. The root observation and selected raw template-role callback
// remain mandatory; a category name or this wrapper alone supplies no owner.
pub fn categoryLinkedLineHtmlH1(line: []const u8, namespaces: ?*const @import("namespace_registry").Registry) ?[]const u8 {
    const ns = namespaces orelse return null;
    if (line.len == 0 or line[0] != '<' or std.mem.indexOfAny(u8, line, "\r\n") != null) return null;
    const outer = syntax.tagAt(line, 0) orelse return null;
    if (!outer.is("h1") or outer.closing or outer.self_closing) return null;
    const whole = syntax.matchingTag(line, outer) orelse return null;
    const tail = line[whole.end..];
    if (tail.len != 0 and !std.mem.eql(u8, tail, "__NOEDITSECTION__")) return null;
    const inner = line[outer.end..whole.inner_end];
    if (!std.mem.startsWith(u8, inner, "[[")) return null;
    const hidden = syntax.balanced(inner, 0) orelse return null;
    const target = inner[2..hidden.inner_end];
    if (target.len == 0 or target[0] == ':' or std.mem.indexOfAny(u8, target, "[]{}<>&|#\r\n") != null) return null;
    const category = ns.ofTitle(target);
    if (category.id != 14 or category.text.len == 0) return null;
    const rest = inner[hidden.end..];
    const span = syntax.tagAt(rest, 0) orelse return null;
    if (!span.is("span") or span.closing or span.self_closing or
        !std.mem.eql(u8, std.mem.trim(u8, span.attrs, " \t"), "class=\"bluetogreen\"")) return null;
    const wrapped = syntax.matchingTag(rest, span) orelse return null;
    if (wrapped.end != rest.len) return null;
    const visible = rest[span.end..wrapped.inner_end];
    if (!std.mem.startsWith(u8, visible, "[[:")) return null;
    const link = syntax.balanced(visible, 0) orelse return null;
    if (link.end != visible.len) return null;
    const fields = visible[3..link.inner_end];
    const pipe = std.mem.indexOfScalar(u8, fields, '|') orelse return null;
    const label = fields[pipe + 1 ..];
    if (!std.mem.eql(u8, fields[0..pipe], target) or !std.mem.eql(u8, label, category.text) or
        std.mem.indexOfAny(u8, label, "[]{}<>&|#=\"'\r\n\t") != null) return null;
    return label;
}

pub fn mayHaveLanguageHtmlHeading(source: []const u8, namespaces: ?*const @import("namespace_registry").Registry) bool {
    if (mayHavePlainLineHtmlH2(source)) return true;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const physical = std.mem.trimEnd(u8, line, "\r");
        if (plainLineHtmlH1(physical) != null or literalBracketLineHtmlH1(physical) != null or
            linkedLineHtmlH1(physical, namespaces) != null or categoryLinkedLineHtmlH1(physical, namespaces) != null) return true;
    }
    return false;
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
    // Caller must independently corroborate an authored language boundary.
    table_boundary_filter: ?MarkerFilter = null,
    mixed_levels: bool = false,
    all_heading_levels: bool = false,
    link_headings: ?LinkHeadingScopes = null,
    html_headings: ?HtmlHeadingScopes = null,
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

    fn enclosingTableCloses(self: *const Iterator, start: usize) bool {
        var balance = self.balance;
        const depth = balance.tables;
        var cursor = start;
        while (cursor < self.source.len) {
            const end = std.mem.indexOfScalarPos(u8, self.source, cursor, '\n') orelse self.source.len;
            balance.update(self.source, cursor, end);
            if (balance.tables < depth) return true;
            cursor = if (end == self.source.len) end else end + 1;
        }
        return false;
    }

    pub fn next(self: *Iterator) ?Section {
        if (self.done) return null;
        self.balance.link_headings = self.link_headings;
        while (self.cursor < self.source.len) {
            const line_start = self.cursor;
            const newline = std.mem.indexOfScalarPos(u8, self.source, line_start, '\n') orelse self.source.len;
            var content_end = newline;
            if (content_end != line_start and self.source[content_end - 1] == '\r') content_end -= 1;
            const line = self.source[line_start..content_end];
            self.cursor = if (newline == self.source.len) self.source.len else newline + 1;

            if (self.balance.comments == 0 and self.balance.tables != 0 and line_start >= self.balance.protected_until) {
                if (self.table_boundary_filter) |filter| if (parseHeadingControlled(line, self.control_matcher)) |heading| {
                    // Corroboration recovers an unterminated table; a matched
                    // table keeps its cell-local headings inside that table.
                    if (heading.level == 2 and filter.accepts(filter.ctx, heading.title) and
                        !self.enclosingTableCloses(line_start)) self.balance.tables = 0;
                };
            }
            if (!self.balance.isOpen() and line_start >= self.balance.protected_until) {
                const heading = parseHeadingControlled(line, self.control_matcher) orelse
                    if (self.html_headings) |scopes| scopes.heading(self.source, line_start, line) else null;
                const marker = if (heading == null) self.languageMarker(line) else null;
                const hyphen_marker = if (marker != null) blk: {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
                    break :blk body[0] == '-';
                } else false;
                const title = if (heading) |value| value.title else marker orelse "";
                // A declared language can start a page at a deeper authored
                // level. Never promote a nested heading or meaningful prefix.
                const leading_position = heading != null and self.active_level == null and
                    std.mem.trim(u8, self.source[0..line_start], " \t\r\n").len == 0;
                // Once a declared deep language established the active depth,
                // its declared peers must split too; deeper children still do not.
                const same_deep_level = if (heading) |value| value.level > 2 and
                    self.active_level != null and value.level == self.active_level.? else false;
                const eligible = if (heading) |value| self.all_heading_levels or
                    value.level == 1 or value.level == 2 or leading_position or same_deep_level else marker != null;
                const declared = eligible and if (self.heading_filter) |filter| filter.accepts(filter.ctx, title) else false;
                const candidate_level: ?u8 = if (heading) |value|
                    if (self.all_heading_levels or value.level == 1 or value.level == 2 or ((leading_position or same_deep_level) and declared)) value.level else null
                else if (marker != null) 2 else null;
                if (candidate_level) |level| {
                    if (self.active_level == null) self.active_level = level;
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
    const outer = parseHeadingControlled(section.source[0..newline], matcher) orelse return .{};
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
            if (parseHeadingControlled(line, matcher)) |heading| {
                if (heading.level <= 2) return .{};
                if (heading.level == 3) {
                    const label = std.mem.trim(u8, heading.title, " \t\r");
                    // Beeb rev1430527 uses this ordinary proper-noun POS, not a language adjective.
                    const proper_noun = std.mem.eql(u8, label, "اسم عَلَم") or std.mem.eql(u8, label, "اسم علم");
                    if (!proper_noun and std.mem.startsWith(u8, label, "اسم ")) {
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

const ProtectionScan = struct {
    opaque_scan: syntax.OpaqueScan = .{},
    no_more_nowiki_close: bool = false,

    fn protectedEnd(self: *ProtectionScan, source: []const u8, start: usize) ?usize {
        return self.opaque_scan.protectedEnd(source, start, &self.no_more_nowiki_close);
    }

    fn tagAt(self: *ProtectionScan, source: []const u8, start: usize) ?syntax.Tag {
        return self.opaque_scan.tagAt(source, start, &self.no_more_nowiki_close);
    }
};

const Balance = struct {
    link_headings: ?LinkHeadingScopes = null,
    comments: usize = 0,
    tables: usize = 0,
    protected_until: usize = 0,
    protection: ProtectionScan = .{},

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
                const token_end: ?usize = self.protection.protectedEnd(source, absolute) orelse
                    if (self.protection.tagAt(source, absolute)) |tag| tag.end else null;
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
            if (std.mem.startsWith(u8, line[i..], "{{") or std.mem.startsWith(u8, line[i..], "[[")) {
                // Failed roots stay literal, allowing complete inner roots to
                // recover. Complete template/parameter roots protect headings;
                // only an observed ordinary link exposes its page-level label.
                // In particular category sort keys and file captions do not
                // manufacture owners from their locally parsed headings.
                if (syntax.balancedWithOpaqueScan(source, line_start + i, &self.protection.opaque_scan)) |pair| {
                    const exposed = std.mem.startsWith(u8, line[i..], "[[") and
                        if (self.link_headings) |scopes| scopes.admits(source, line_start + i) else false;
                    if (!exposed) {
                        self.protected_until = pair.end;
                        if (pair.end >= line_end) return;
                        i = pair.end - line_start - 1;
                    }
                }
            }
        }
    }

    fn isOpen(self: Balance) bool {
        return self.comments != 0 or self.tables != 0;
    }
};

/// An exact equals-style standalone declaration remains a boundary even
/// when its language code has not been captured in the registry.
pub fn equalsLanguageDeclaration(source: []const u8) ?[]const u8 {
    const first = std.mem.trim(u8, source[0..(std.mem.indexOfScalar(u8, source, '\n') orelse source.len)], " \t\r");
    if (!std.mem.startsWith(u8, first, "{{")) return null;
    const body = std.mem.trimStart(u8, first[2..], " \t");
    if (body.len == 0 or body[0] != '=') return null;
    return parseStandaloneLanguageMarker(first);
}

fn parseStandaloneLanguageMarker(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 7 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return null;
    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
    // Equals-language templates may take sort/display arguments. Only the
    // first field declares the language; arguments never supply an owner.
    const name = std.mem.trim(u8, body[0..(std.mem.indexOfScalar(u8, body, '|') orelse body.len)], " \t");
    if (name.len >= 3 and name[0] == '=' and name[name.len - 1] == '=') {
        const pair = syntax.balanced(trimmed, 0) orelse return null;
        if (pair.end != trimmed.len) return null;
        const code = std.mem.trim(u8, name[1 .. name.len - 1], " \t");
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
    return parseHeadingControlled(raw, null);
}

fn parseHeadingControlled(raw: []const u8, matcher: ?syntax.ControlMatcher) ?ParsedHeading {
    const heading = syntax.controlHeading(raw, matcher) orelse return null;
    return .{ .level = heading.level, .title = heading.title };
}

/// Literal page category links, excluding comments, template arguments and
/// protected source. Namespace and language validation belong to the caller.
pub const CategoryIterator = struct {
    source: []const u8,
    cursor: usize = 0,
    templates: usize = 0,
    protection: ProtectionScan = .{},

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
                if (self.protection.protectedEnd(self.source, start)) |end| {
                    self.cursor = end;
                    continue;
                }
                const html_pre = if (self.protection.tagAt(self.source, start)) |tag| tag.html_pre else false;
                if (!html_pre) for ([_][]const u8{ "pre", "source", "syntaxhighlight", "math", "includeonly" }) |name| {
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
                };
                if (self.cursor != start) continue;
                if (self.templates == 0) {
                    if (self.protection.tagAt(self.source, start)) |tag| {
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
    try std.testing.expectEqualStrings("الإنجليزية", explicitLanguageDeclaration("اللغة الإنجليزية", "ar").?);
    try std.testing.expectEqualStrings("الانجليزية", explicitLanguageDeclaration("اللغة الانجليزية", "ar").?);
    try std.testing.expectEqualStrings("مجهولة", explicitLanguageDeclaration("اللغة مجهولة", "ar").?);
    inline for (.{ "اللغة", "اللغةالإنجليزية", "اللغة [[إنجليزية]]", "اللغة إنجليزية|فرنسية", "اللغة إنجليزية\nفرنسية" }) |heading|
        try std.testing.expect(explicitLanguageDeclaration(heading, "ar") == null);
    try std.testing.expect(explicitLanguageDeclaration("اللغة الإنجليزية", "en") == null);
    try std.testing.expect(explicitLanguageDeclaration("لغة ألمانية", "ar") != null);
    try std.testing.expectEqualStrings("ألمانية", explicitLanguageDeclaration("لغة ألمانية", "ar").?);
    try std.testing.expectEqualStrings("مجهولة", explicitLanguageDeclaration("لغة مجهولة", "ar").?);
    try std.testing.expect(explicitLanguageDeclaration("لغة ألمانية", "en") == null);
    try std.testing.expect(explicitLanguageDeclaration("لغة [[ألمانية|الإنجليزية]]", "ar") == null);
    try std.testing.expect(explicitLanguageDeclaration("اسم عَلَم", "ar") == null);

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
        try std.testing.expectEqualStrings("French", it.next().?.heading);
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

test "language iterator recognizes active prefix controls without inventing protected headings" {
    var iterator = Iterator.init("__NOEDITSECTION__==English==\n__NOEDITSECTION__# sense\n<nowiki>__NOEDITSECTION__==French==</nowiki>\n__NOTOC__==French==\n# autre");
    try std.testing.expectEqualStrings("English", iterator.next().?.heading);
    try std.testing.expectEqualStrings("French", iterator.next().?.heading);
    try std.testing.expect(iterator.next() == null);
}

test "Sprache heading evidence ignores protected comments and tag attributes" {
    inline for (.{ "Lemma <nowiki>{{Sprache|Deutsch}}</nowiki>", "Lemma <pre>{{Sprache|Deutsch}}</pre>", "Lemma <!--{{Sprache|Deutsch}}-->", "Lemma <span title=\"{{Sprache|Deutsch}}\">literal</span>" }) |heading|
        try std.testing.expectEqualStrings(heading, classificationHeading(heading));
    try std.testing.expectEqualStrings("Deutsch", classificationHeading("Lemma ({{Sprache|Deutsch}})"));
    try std.testing.expectEqualStrings("Deutsch", classificationHeading("Lemma <nowiki>{{Sprache|French}}</nowiki> <!--{{Sprache|French}}--> ({{Sprache|Deutsch}})"));
}

test "Sprache argument boundaries cannot shorten protected or nested language text" {
    inline for (.{ "Lemma ({{Sprache|Deutsch<nowiki>|French</nowiki>}})", "Lemma ({{Sprache|Deutsch<!--}}|French-->suffix}})", "Lemma ({{Sprache|{{Sprache|Deutsch}}}})" }) |heading|
        try std.testing.expectEqualStrings(heading, classificationHeading(heading));
    inline for (.{ "Lemma ({{Sprache|<span>Deutsch</span>}})", "Lemma ({{Sprache|Deutsch<pre>|French</pre>}})", "Lemma ({{Sprache|Deutsch<code>|French</code>}})" }) |heading|
        try std.testing.expectEqualStrings(heading, classificationHeading(heading));
    try std.testing.expectEqualStrings("Deutsch", classificationHeading("Lemma ({{Sprache|Deutsch<nowiki>|French</nowiki>}}) ({{Sprache|Deutsch}})"));
    try std.testing.expectEqualStrings("K'iche'", classificationHeading("Lemma ({{Sprache|K'iche'}})"));
    try std.testing.expectEqualStrings("Egyptian (Ancient)", classificationHeading("Lemma ({{Sprache|Egyptian (Ancient)}})"));
    try std.testing.expectEqualStrings("Old English", classificationHeading("Lemma ({{Sprache|Old English|ignored}})"));
    try std.testing.expectEqualStrings("العربية", classificationHeading("Lemma ({{Sprache|العربية}})"));
    try std.testing.expectEqualStrings("Deutsch", classificationHeading("Lemma ({{Sprache|{{unknown}}}}) ({{Sprache|Deutsch}})"));
}

test "unclosed nowiki leaves category and language boundaries active" {
    var unclosed: CategoryIterator = .{ .source = "<nowiki>[[Category:German]]" };
    try std.testing.expectEqualStrings("Category:German", unclosed.next().?);
    try std.testing.expect(unclosed.next() == null);
    var closed: CategoryIterator = .{ .source = "<nowiki>[[Category:German]]</nowiki extra>[[Category:Spanish]]</nowiki>[[Category:English]]" };
    try std.testing.expectEqualStrings("Category:English", closed.next().?);
    try std.testing.expect(closed.next() == null);
    var active = Iterator.init("==English==\n<nowiki>ordinary\n==French==\n# chat\n");
    try std.testing.expectEqualStrings("English", active.next().?.heading);
    try std.testing.expectEqualStrings("French", active.next().?.heading);
    try std.testing.expect(active.next() == null);
}

test "unmatched extension openers leave later owner headings active" {
    const tags = [_][]const u8{ "nowiki", "pre", "gallery", "indicator", "ref", "references", "templatestyles", "math", "ce", "chem", "score", "syntaxhighlight", "source", "timeline", "hiero", "poem", "categorytree", "charinsert", "graph", "mapframe", "maplink", "section", "inputbox", "imagemap", "dynamicpagelist" };
    for (tags) |tag| {
        const protected_body = if (std.mem.eql(u8, tag, "nowiki")) "" else "<nowiki>\n==German==\n</nowiki>\n";
        const source = try std.fmt.allocPrint(std.testing.allocator, "==English==\n<{s} title=\"==German==\">unclosed\n<{s}>again\n{s}==French==\n# chat\n", .{ tag, tag, protected_body });
        defer std.testing.allocator.free(source);
        var active = Iterator.init(source);
        try std.testing.expectEqualStrings("English", active.next().?.heading);
        try std.testing.expectEqualStrings("French", active.next().?.heading);
        try std.testing.expect(active.next() == null);
        const closed_source = try std.fmt.allocPrint(std.testing.allocator, "==English==\n<{s}>\n==German==\n</{s}>\n==French==\n# chat\n", .{ tag, tag });
        defer std.testing.allocator.free(closed_source);
        var closed = Iterator.init(closed_source);
        try std.testing.expectEqualStrings("English", closed.next().?.heading);
        try std.testing.expectEqualStrings("French", closed.next().?.heading);
        try std.testing.expect(closed.next() == null);
    }
    var comment = Iterator.init("==English==\n<!-- unclosed\n==French==\n# chat\n");
    try std.testing.expectEqualStrings("English", comment.next().?.heading);
    try std.testing.expect(comment.next() == null);
}

test "unmatched extension openers retain active language classification evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags = [_][]const u8{ "nowiki", "pre", "gallery", "indicator", "ref", "references", "templatestyles", "math", "ce", "chem", "score", "syntaxhighlight", "source", "timeline", "hiero", "poem", "categorytree", "charinsert", "graph", "mapframe", "maplink", "section", "inputbox", "imagemap", "dynamicpagelist" };
    for (tags) |tag| {
        const opening = try std.mem.concat(a, u8, &.{ "<", tag, ">" });
        const closing = try std.mem.concat(a, u8, &.{ "</", tag, ">" });
        const category = try std.mem.concat(a, u8, &.{ opening, "[[קטגוריה:שפה ספרדית]]" });
        try std.testing.expectEqualStrings("ספרדית", classificationSection(.{ .heading = "lemma", .source = category }));
        const closed_category = try std.mem.concat(a, u8, &.{ category, closing });
        try std.testing.expectEqualStrings("lemma", classificationSection(.{ .heading = "lemma", .source = closed_category }));
        const grammar = try std.mem.concat(a, u8, &.{ opening, "{{ניתוח דקדוקי|x}}" });
        try std.testing.expectEqualStrings("עברית", classificationSection(.{ .heading = "lemma", .source = grammar }));
        const closed_grammar = try std.mem.concat(a, u8, &.{ grammar, closing });
        try std.testing.expectEqualStrings("lemma", classificationSection(.{ .heading = "lemma", .source = closed_grammar }));
        const heading = try std.mem.concat(a, u8, &.{ "Lemma ", opening, "({{Sprache|Deutsch}})" });
        try std.testing.expectEqualStrings("Deutsch", classificationHeading(heading));
        const closed_heading = try std.mem.concat(a, u8, &.{ heading, closing });
        try std.testing.expectEqualStrings(closed_heading, classificationHeading(closed_heading));
    }
}

test "pre HTML fallback leaves active language owners while strip hooks protect paired bodies" {
    const cases = [_]struct { opener: []const u8, body_active: bool }{
        .{ .opener = "<pre/ >", .body_active = true },
        .{ .opener = "<PRE/ >", .body_active = true },
        .{ .opener = "<pre/>", .body_active = true },
        .{ .opener = "<pre />", .body_active = true },
        .{ .opener = "<pre>", .body_active = false },
        .{ .opener = "<pre / >", .body_active = false },
        .{ .opener = "<pre title='literal' / >", .body_active = false },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "==English==\n{s}\n<nowiki>\n==Latin==\n</nowiki>\n==French==\n# chat\n</pre>\n==German==\n# Hund\n", .{case.opener});
        defer std.testing.allocator.free(source);
        var owners = Iterator.init(source);
        try std.testing.expectEqualStrings("English", owners.next().?.heading);
        if (case.body_active) try std.testing.expectEqualStrings("French", owners.next().?.heading);
        try std.testing.expectEqualStrings("German", owners.next().?.heading);
        try std.testing.expect(owners.next() == null);
    }
}

test "pre HTML fallback exposes categories while genuine core pairs remain protected" {
    var active: CategoryIterator = .{ .source = "<pre/ foo>[[Category:English nouns]]</pre>" };
    try std.testing.expectEqualStrings("Category:English nouns", active.next().?);
    try std.testing.expect(active.next() == null);
    var short: CategoryIterator = .{ .source = "<pre/>[[Category:English nouns]]" };
    try std.testing.expectEqualStrings("Category:English nouns", short.next().?);
    try std.testing.expect(short.next() == null);
    for ([_][]const u8{ "<pre>[[Category:English nouns]]</pre>", "<pre / >[[Category:English nouns]]</pre>", "<nowiki><pre/ foo>[[Category:English nouns]]</pre></nowiki>", "<!-- <pre/ foo>[[Category:English nouns]]</pre> -->" }) |source| {
        var hidden: CategoryIterator = .{ .source = source };
        try std.testing.expect(hidden.next() == null);
    }
}

test "unmatched template and link roots resume real language headings" {
    const prefix = "==English==\n# first\n";
    const suffix = "==French==\n# second\n";
    for ([_][]const u8{
        "{{open|\n",                                   "[[open\n",
        "{{open|\n{{inner|\n==German==\nhidden\n}}\n", "[[open\n{{inner|\n==German==\nhidden\n}}\n",
        "{{open|\n<nowiki>}}</nowiki>\n",              "[[open\n<!-- ]] -->\n",
    }) |middle| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, middle, suffix });
        defer std.testing.allocator.free(source);
        var it = Iterator.init(source);
        try std.testing.expectEqualStrings("English", it.next().?.heading);
        try std.testing.expectEqualStrings("French", it.next().?.heading);
        try std.testing.expect(it.next() == null);
    }
    // Matched template/parameter bodies retain their physical headings.
    for ([_][]const u8{
        "{{closed|\n==French==\nhidden\n}}\n",
        "{{{value|\n==French==\nhidden\n}}}\n",
    }) |middle| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, middle, "# after\n" });
        defer std.testing.allocator.free(source);
        var it = Iterator.init(source);
        try std.testing.expectEqualStrings("English", it.next().?.heading);
        try std.testing.expect(it.next() == null);
    }
    const malformed = "{{open|\n==French==\n";
    try std.testing.expectEqual(@as(usize, 7), syntax.logicalEnd(malformed, 0));
}

test "unmatched owner root recovery keeps bounded overflow and complete inner scopes" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "==English==\n");
    for (0..1024) |_| try source.appendSlice(std.testing.allocator, "{{open|\n{{closed|\n==German==\nhidden\n}}\n==French==\n# second\n");
    var it = Iterator.init(source.items);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    for (0..1024) |_| try std.testing.expectEqualStrings("French", it.next().?.heading);
    try std.testing.expect(it.next() == null);
    var closed = Iterator.init("==English==\n{{closed|\n==French==\nhidden\n}}\n");
    try std.testing.expectEqualStrings("English", closed.next().?.heading);
    try std.testing.expect(closed.next() == null);
}

test "observed ordinary links expose headings while nested complete templates remain protected" {
    for ([_][]const u8{
        "==English==\n[[Target|\n==French==\nhidden\n]]\n",
        "==English==\n[[Target|\n{{closed|\n==German==\nhidden\n}}\n==French==\nbody\n]]\n",
        "==English==\n[[Target|\n{{{value|\n==German==\nhidden\n}}}\n==French==\nbody\n]]\n",
    }) |source| {
        var it = Iterator.init(source);
        const openings = [_]usize{std.mem.indexOf(u8, source, "[[Target|").?};
        it.link_headings = .{ .source = source, .openings = &openings };
        const english = it.next().?;
        const french = it.next().?;
        try std.testing.expectEqualStrings("English", english.heading);
        try std.testing.expectEqualStrings("French", french.heading);
        try std.testing.expect(std.mem.startsWith(u8, french.source, "==French==\n"));
        try std.testing.expect(std.mem.endsWith(u8, french.source, "]]\n"));
        try std.testing.expect(it.next() == null);
    }
}

test "balanced link heading admission is source-bound and conservative" {
    const source = "==English==\n[[Target|\n==French==\nbody\n]]\n";
    var without = Iterator.init(source);
    try std.testing.expectEqualStrings("English", without.next().?.heading);
    try std.testing.expect(without.next() == null);
    const offsets = [_]usize{std.mem.indexOf(u8, source, "[[").?};
    const copy = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(copy);
    var mismatched = Iterator.init(source);
    mismatched.link_headings = .{ .source = copy, .openings = &offsets };
    try std.testing.expectEqualStrings("English", mismatched.next().?.heading);
    try std.testing.expect(mismatched.next() == null);
    for ([_][]const u8{
        "==English==\n[[Category:English nouns|\n==French==\nhidden\n]]\nOutside\n",
        "==English==\n[[File:Example.jpg|thumb|\n==French==\ncaption\n]]\nOutside\n",
    }) |local| {
        var it = Iterator.init(local);
        try std.testing.expectEqualStrings("English", it.next().?.heading);
        try std.testing.expect(it.next() == null);
    }
}

test "equals declarations preserve unknown boundaries without accepting hyphen or partial forms" {
    try std.testing.expectEqualStrings("qmg", equalsLanguageDeclaration("{{=qmg=}}\n# body").?);
    try std.testing.expectEqualStrings("nb", equalsLanguageDeclaration("  {{ = nb = }}\n# body").?);
    for ([_][]const u8{ "{{-qmg-}}\n# body", "{{=qmg=}} trailing", "<nowiki>{{=qmg=}}</nowiki>", "{{=qmg|x=}}", "{{=x=}}", "==qmg==" }) |source|
        try std.testing.expect(equalsLanguageDeclaration(source) == null);
}

test "equals language arguments never supply or change the declared code" {
    try std.testing.expectEqualStrings("ett", equalsLanguageDeclaration("{{=ett=|𐌅𐌄𐌋𐌈𐌉𐌕𐌄}}\nbody").?);
    try std.testing.expectEqualStrings("ett", equalsLanguageDeclaration("{{=ett=|{{sort|en}}|display=[[English]]}}\nbody").?);
    try std.testing.expectEqualStrings("unknown", equalsLanguageDeclaration("{{=unknown=|ett}}\nbody").?);
    for ([_][]const u8{ "{{=ett=|x}} trailing", "{{=ett=|{{broken}}", "{{=ett=|x}}{{=en=}}", "<nowiki>{{=ett=|en}}</nowiki>", "{{-ett-|en}}" }) |source|
        try std.testing.expect(equalsLanguageDeclaration(source) == null);
}

/// Conservative uniqueness check for a caller-corroborated table boundary.
/// This never changes source, classifies an owner, or executes the callback on
/// a heading inside a comment or opaque literal body.
pub fn countUnprotectedL2Headings(source: []const u8, matcher: ?syntax.ControlMatcher, filter: Iterator.MarkerFilter) usize {
    var balance: Balance = .{};
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        if (balance.comments == 0 and cursor >= balance.protected_until) {
            if (parseHeadingControlled(source[cursor..end], matcher)) |heading|
                if (heading.level == 2 and filter.accepts(filter.ctx, heading.title) and outsideNestedOrOpaque(source, cursor)) {
                    count += 1;
                };
        }
        balance.update(source, cursor, end);
        cursor = if (end < source.len) end + 1 else end;
    }
    return count;
}

pub fn outsideNestedOrOpaque(source: []const u8, offset: usize) bool {
    var cursor: usize = 0;
    while (cursor < offset) {
        if (syntax.protectedEnd(source, cursor)) |end| {
            if (end > offset) return false;
            cursor = end;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<!--")) {
            const close = std.mem.indexOfPos(u8, source, cursor + 4, "-->") orelse return false;
            if (close + 3 > offset) return false;
            cursor = close + 3;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "{{") or std.mem.startsWith(u8, source[cursor..], "[[")) {
            const pair = syntax.balanced(source, cursor) orelse return false;
            if (pair.end > offset) return false;
            cursor = pair.end;
            continue;
        }
        if (source[cursor] == '<') if (syntax.tagAt(source, cursor)) |tag| {
            if (tag.end > offset) return false;
            cursor = tag.end;
            continue;
        };
        cursor += 1;
    }
    return true;
}

test "corroborated recovery leaves matched table headings in their cell domain" {
    const Accept = struct {
        fn accepts(_: ?*const anyopaque, _: []const u8) bool {
            return true;
        }
    };
    const cases = [_]struct { source: []const u8, recovered: bool }{
        .{ .source = "==English==\n{|\n|\n==French==\n[[chat]]\n|}</div>\n==German==\n[[Katze]]\n", .recovered = false },
        .{ .source = "==English==\n{|\n|\n{|\n|\n==French==\n[[chat]]\n|}\n|}\n==German==\n[[Katze]]\n", .recovered = false },
        .{ .source = "==English==\n{|\n|\n==French==\n[[chat]]\n<nowiki>\n|}\n</nowiki>\n<!--\n|}\n-->\n==German==\n[[Katze]]\n", .recovered = true },
        .{ .source = "==English==\n{|\n|\n==French==\n[[chat]]\n{|\n| nested\n|}\n==German==\n[[Katze]]\n", .recovered = true },
    };
    for (cases) |case| {
        var iterator = Iterator.init(case.source);
        iterator.table_boundary_filter = .{ .ctx = null, .accepts = Accept.accepts };
        try std.testing.expectEqualStrings("English", iterator.next().?.heading);
        if (case.recovered) try std.testing.expectEqualStrings("French", iterator.next().?.heading);
        try std.testing.expectEqualStrings("German", iterator.next().?.heading);
        try std.testing.expect(iterator.next() == null);
    }
}

// This proves an authored lexical subtree, never a language or an owner.
// Caller must independently establish raw/rendered identity, leading position,
// a later resolved peer L2, and exclusion of known support/POS outer headings.
pub fn literalL2Section(section: Section, matcher: ?syntax.ControlMatcher) bool {
    if (section.hyphen_marker) return false;
    const first_end = std.mem.indexOfScalar(u8, section.source, '\n') orelse return false;
    const first_line = std.mem.trimEnd(u8, section.source[0..first_end], "\r");
    const outer = literalSubtreeHeading(first_line, matcher) orelse return false;
    return outer.level == 2 and std.mem.eql(u8, outer.title, section.heading) and
        std.mem.indexOfAny(u8, outer.title, "<>{}[]|=\r\n") == null;
}

// Exact unpiped local-link heading. This supplies source shape only, never
// a language alias. Root scope and independent target resolution are callers' proofs.
pub fn linkedL2Section(section: Section, matcher: ?syntax.ControlMatcher) ?[]const u8 {
    if (section.hyphen_marker) return null;
    const end = std.mem.indexOfScalar(u8, section.source, '\n') orelse return null;
    const outer = literalSubtreeHeading(std.mem.trimEnd(u8, section.source[0..end], "\r"), matcher) orelse return null;
    if (outer.level != 2 or !std.mem.eql(u8, outer.title, section.heading) or
        !std.mem.startsWith(u8, outer.title, "[[")) return null;
    const link = syntax.balanced(outer.title, 0) orelse return null;
    if (link.end != outer.title.len) return null;
    const target = outer.title[2..link.inner_end];
    if (target.len == 0 or !std.mem.eql(u8, target, std.mem.trim(u8, target, " \t")) or
        std.mem.indexOfAny(u8, target, ":#%&{}[]<>|=\r\n") != null) return null;
    return target;
}

pub fn authoredLinkedL2LexicalSubtree(section: Section, matcher: ?syntax.ControlMatcher) bool {
    if (linkedL2Section(section, matcher) == null) return false;
    return authoredL2LexicalBody(section, matcher, false);
}

pub fn authoredL2LexicalSubtree(section: Section, matcher: ?syntax.ControlMatcher) bool {
    return authoredL2LexicalSubtreePolicy(section, matcher, false);
}

// A complete leading qualifier template contributes no lexical or language
// evidence. This separate policy requires a following complete ordinary link
// with a plain nonempty target/display; the old leading policy is unchanged.
pub fn authoredL2LexicalSubtreeWithLiteralTail(section: Section, matcher: ?syntax.ControlMatcher) bool {
    return authoredL2LexicalSubtreePolicy(section, matcher, true);
}

fn authoredL2LexicalSubtreePolicy(section: Section, matcher: ?syntax.ControlMatcher, literal_tail: bool) bool {
    if (!literalL2Section(section, matcher)) return false;
    return authoredL2LexicalBody(section, matcher, literal_tail);
}

// Caller separately proves the physical outer heading and its root scope.
// This body-only predicate confers lexical shape, never language ownership.
pub fn authoredL2LexicalBody(section: Section, matcher: ?syntax.ControlMatcher, literal_tail: bool) bool {
    const first_end = std.mem.indexOfScalar(u8, section.source, '\n') orelse return false;

    var balance: Balance = .{};
    var cursor = first_end + 1;
    var under_subheading = false;
    var found_definition = false;
    while (cursor < section.source.len) {
        const end = std.mem.indexOfScalarPos(u8, section.source, cursor, '\n') orelse section.source.len;
        const line = std.mem.trimEnd(u8, section.source[cursor..end], "\r");
        const active = !balance.isOpen() and cursor >= balance.protected_until;
        if (active and line.len != 0 and line[0] == '=') {
            const heading = literalSubtreeHeading(line, matcher) orelse return false;
            if (heading.level <= 2) return false;
            under_subheading = true;
        } else if (active and under_subheading and line.len != 0 and line[0] == '#') {
            var body_start: usize = 0;
            while (body_start < line.len and line[body_start] == '#') body_start += 1;
            // Only a top-level numbered meaning is evidence; examples and
            // nested list markers cannot supply the missing lexical subtree.
            if (body_start == 1 and body_start < line.len and line[body_start] != ':' and line[body_start] != '*') {
                if (nonemptyAuthoredDefinitionPolicy(line[body_start..], literal_tail)) found_definition = true;
            }
        }
        balance.update(section.source, cursor, end);
        cursor = if (end == section.source.len) end else end + 1;
    }
    // One whole-source provenance check rejects failed template/link roots
    // without rescanning every heading/meaning prefix. Balance above prevents
    // opaque/table bodies from supplying evidence. A later unmatched opaque
    // tail does not erase earlier evidence; its normal compile diagnostic stays.
    return found_definition and !balance.isOpen() and
        outsideNestedOrOpaque(section.source, section.source.len);
}

fn literalSubtreeHeading(line: []const u8, matcher: ?syntax.ControlMatcher) ?ParsedHeading {
    // Reject mismatched or excessive equals depth, even if the ordinary parser
    // can recover it. No leading indentation is allowed in this authored proof.
    if (line.len == 0 or line[0] != '=') return null;
    var opening: usize = 0;
    while (opening < line.len and line[opening] == '=') opening += 1;
    const stripped = std.mem.trimEnd(u8, line, " \t");
    var closing: usize = 0;
    while (closing < stripped.len and stripped[stripped.len - closing - 1] == '=') closing += 1;
    if (opening < 2 or opening > 6 or closing != opening or opening * 2 >= stripped.len) return null;
    const heading = parseHeadingControlled(line, matcher) orelse return null;
    if (heading.level != opening) return null;
    const authored_title = std.mem.trim(u8, stripped[opening .. stripped.len - closing], " \t");
    if (!std.mem.eql(u8, authored_title, heading.title)) return null;
    return heading;
}

fn nonemptyAuthoredDefinitionPolicy(body: []const u8, literal_tail: bool) bool {
    var rest = std.mem.trim(u8, body, " \t\r");
    while (std.mem.startsWith(u8, rest, "<!--")) {
        const close = std.mem.indexOf(u8, rest[4..], "-->") orelse return false;
        rest = std.mem.trim(u8, rest[4 + close + 3 ..], " \t\r");
    }
    var skipped_template = false;
    if (literal_tail) while (std.mem.startsWith(u8, rest, "{{")) {
        skipped_template = true;
        const pair = syntax.balanced(rest, 0) orelse return false;
        rest = std.mem.trim(u8, rest[pair.end..], " \t\r");
        while (std.mem.startsWith(u8, rest, "<!--")) {
            const close = std.mem.indexOf(u8, rest[4..], "-->") orelse return false;
            rest = std.mem.trim(u8, rest[4 + close + 3 ..], " \t\r");
        }
    };
    if (skipped_template) return authoredPlainDefinitionLink(rest);
    // A template-only meaning needs expansion authority, not this raw proof.
    return rest.len != 0 and !std.mem.startsWith(u8, rest, "{{");
}

// This is deliberately not an HTML/formatting visibility evaluator. Metadata
// category/file links, empty labels, quote-only formatting and rich/template
// labels cannot supply the new qualifier-tail certificate.
fn authoredPlainDefinitionLink(source: []const u8) bool {
    if (!std.mem.startsWith(u8, source, "[[")) return false;
    const pair = syntax.balanced(source, 0) orelse return false;
    const body = source[2..pair.inner_end];
    const pipe = std.mem.indexOfScalar(u8, body, '|');
    const target = std.mem.trim(u8, body[0..(pipe orelse body.len)], " \t\r");
    if (std.mem.trim(u8, target, " \t\r'_").len == 0 or
        std.mem.indexOfAny(u8, target, ":<>{}[]|&\r\n") != null or !std.unicode.utf8ValidateSlice(target)) return false;
    if (pipe) |at| {
        const label = std.mem.trim(u8, body[at + 1 ..], " \t\r'");
        if (label.len == 0 or std.mem.indexOfAny(u8, label, "<>{}[]|&\r\n") != null or !std.unicode.utf8ValidateSlice(label)) return false;
    }
    return true;
}

// A lexical spelling is only a preflight. The final boundary additionally
// requires the renderer to have observed BOTH the heading and this exact rule
// in its original root domain. Earlier malformed source may recover normally;
// a separate prefix parser cannot replace that actual observation.
pub fn adjacentPhysicalRule(source: []const u8, section: Section) ?struct { start: usize, end: usize } {
    const heading_start = std.math.sub(usize, @intFromPtr(section.source.ptr), @intFromPtr(source.ptr)) catch return null;
    if (heading_start > source.len or section.source.len > source.len - heading_start) return null;
    const before = std.mem.trimEnd(u8, source[0..heading_start], " \t\r\n");
    if (before.len == 0) return null;
    const rule_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |at| at + 1 else 0;
    if (!std.mem.eql(u8, before[rule_start..], "----")) return null;
    return .{ .start = rule_start, .end = heading_start };
}

pub fn adjacentRootRule(source: []const u8, section: Section) ?struct { start: usize, end: usize } {
    if (!section.root_wiki_heading) return null;
    const rule = adjacentPhysicalRule(source, section) orelse return null;
    if ((section.adjacent_root_rule orelse return null) != rule.start) return null;
    return .{ .start = rule.start, .end = rule.end };
}

test "authored literal L2 lexical subtrees require active deeper numbered meaning" {
    // Exact lexical prefix of KW montagne; the caller separately proves the
    // later Italek peer and raw/rendered identity before isolating this region.
    const positive = "== Frynkek ==\n=== Leveryans ===\n* IPA: /mɔ̃.taɲ/\n\n=== Hanow ===\n'''montagne''' ''benow'' (''liesplek'': '''[[montagnes]]''')\n# [[menydh]]\n";
    const region: Section = .{ .heading = "Frynkek", .source = positive };
    try std.testing.expect(literalL2Section(region, null));
    try std.testing.expect(authoredL2LexicalSubtree(region, null));
    // An unclosed nowiki opening is literal; its remainder remains active.
    // A matched nowiki pair cannot supply the heading or numbered meaning.
    try std.testing.expect(authoredL2LexicalSubtree(.{ .heading = "Frynkek", .source = positive ++ "<nowiki>\n=== Fake ===\n# active tail" }, null));
    try std.testing.expect(authoredL2LexicalSubtree(.{ .heading = "Frynkek", .source = "== Frynkek ==\n<nowiki>\n=== Hanow ===\n# active remainder" }, null));
    try std.testing.expect(!authoredL2LexicalSubtree(.{ .heading = "Frynkek", .source = "== Frynkek ==\n<nowiki>\n=== Hanow ===\n# protected remainder\n</nowiki>" }, null));
    try std.testing.expect(authoredL2LexicalSubtree(.{ .heading = "Frynkek", .source = "== Frynkek ==\r\n=== Hanow ===\r\n# [[menydh]]" }, null));
    try std.testing.expect(!literalL2Section(.{ .heading = "Italek", .source = positive }, null));
    try std.testing.expect(!literalL2Section(.{ .heading = "Frynkek", .source = positive, .hyphen_marker = true }, null));
    const negatives = [_][]const u8{
        "== Frynkek ==\n# [[menydh]]\n", // Direct L2 meaning is insufficient.
        "== Frynkek ==\n=== Hanow ===\n#\n",
        "== Frynkek ==\n=== Hanow ===\n# <!-- empty -->\n",
        "== Frynkek ==\n=== Hanow ===\n## [[menydh]]\n",
        "== Frynkek ==\n=== Hanow ===\n#: [[menydh]]\n",
        "== Frynkek ==\n=== Hanow ===\n#* [[menydh]]\n",
        "== Frynkek ==\n<nowiki>\n=== Hanow ===\n# [[menydh]]\n</nowiki>\n",
        "== Frynkek ==\n<pre>\n=== Hanow ===\n# [[menydh]]\n</pre>\n",
        "== Frynkek ==\n<!--\n=== Hanow ===\n# [[menydh]]\n-->\n",
        "== Frynkek ==\n{|\n|\n=== Hanow ===\n# [[menydh]]\n|}\n",
        "== Frynkek ==\n{{example|\n=== Hanow ===\n# [[menydh]]\n}}\n",
        "== Frynkek ==\n{{{example|\n=== Hanow ===\n# [[menydh]]\n}}}\n",
        "== Frynkek ==\n{{unclosed|\n=== Hanow ===\n# [[menydh]]\n",
        "== Frynkek ==\n=== Hanow ===\n# {{meaning}}\n",
        "== Frynkek ==\n=== Hanow ==\n# [[menydh]]\n",
        "== Frynkek ===\n=== Hanow ===\n# [[menydh]]\n",
        "=== Frynkek ===\n==== Hanow ====\n# [[menydh]]\n",
        "== Frynkek ==\n=== Hanow ===\n# [[menydh]]\n== Italek ==\n# other\n",
        "== Frynkek ==\n=== Hanow ===\n# [[menydh]]\n= Other =\n# other\n",
        // An active deeper heading cannot borrow its sole definition from an opaque domain.
        "== Frynkek ==\n=== Hanow ===\n<nowiki>\n# [[menydh]]\n</nowiki>\n",
        "== Frynkek ==\n=== Hanow ===\n<!--\n# [[menydh]]\n-->\n",
        "== Frynkek ==\n=== Hanow ===\n{|\n|\n# [[menydh]]\n|}\n",
        "== Frynkek ==\n=== Hanow ===\n{{example|\n# [[menydh]]\n}}\n",
    };
    for (negatives) |source| {
        try std.testing.expect(!authoredL2LexicalSubtree(.{ .heading = "Frynkek", .source = source }, null));
    }
}

// A same-page language cross-reference can corroborate an unresolved peer
// boundary. It never supplies that peer's owner. Scan each adjacent region
// once; callers must independently bind raw/rendered headings and page title.
pub fn peerLanguageReferenceCode(source: []const u8, label: []const u8, title: []const u8, filter: Iterator.MarkerFilter) ?[]const u8 {
    if (label.len == 0 or title.len == 0 or std.mem.indexOfAny(u8, title, "[]|:#<>\r\n") != null) return null;
    // Block containers can turn an otherwise active-looking row into quoted
    // or embedded content. Conservatively leave those pages to existing rules.
    var protection: ProtectionScan = .{};
    var token: usize = 0;
    while (token < source.len) {
        if (protection.protectedEnd(source, token)) |end| { token = end; continue; }
        if (source[token] == '<') if (protection.tagAt(source, token)) |tag| {
            inline for (.{ "blockquote", "q", "div", "table", "ul", "ol", "dl", "li", "dd", "dt", "p", "poem", "pre" }) |name|
                if (tag.is(name)) return null;
            token = tag.end;
            continue;
        };
        token += 1;
    }
    var balance: Balance = .{};
    var cursor: usize = 0;
    var found: ?[]const u8 = null;
    while (cursor < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        if (!balance.isOpen() and cursor >= balance.protected_until) {
            if (peerLanguageRowCode(std.mem.trimEnd(u8, source[cursor..end], "\r"), label, title)) |code| {
                if (filter.accepts(filter.ctx, code)) {
                    if (found) |prior| if (!std.mem.eql(u8, prior, code)) return null;
                    found = code;
                }
            }
        }
        balance.update(source, cursor, end);
        cursor = if (end < source.len) end + 1 else end;
    }
    if (balance.isOpen() or !outsideNestedOrOpaque(source, source.len)) return null;
    return found;
}

fn peerLanguageRowCode(line: []const u8, label: []const u8, title: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "* ")) return null;
    var rest = line[2..];
    if (!std.mem.startsWith(u8, rest, label)) return null;
    rest = rest[label.len..];
    if (!std.mem.startsWith(u8, rest, ": [[")) return null;
    rest = rest[4..];
    if (!std.mem.startsWith(u8, rest, title)) return null;
    rest = rest[title.len..];
    if (!std.mem.startsWith(u8, rest, "]] ([[:")) return null;
    rest = rest[7..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const code = rest[0..colon];
    if (code.len == 0) return null;
    for (code) |byte| if (!(byte >= 'a' and byte <= 'z') and byte != '-') return null;
    rest = rest[colon + 1..];
    if (!std.mem.startsWith(u8, rest, title)) return null;
    rest = rest[title.len..];
    if (!std.mem.startsWith(u8, rest, "|")) return null;
    rest = rest[1..];
    if (!std.mem.endsWith(u8, rest, "]])") or !std.mem.eql(u8, rest[0 .. rest.len - 3], code)) return null;
    return code;
}

test "peer language references reject protected mismatched and long ordinary input" {
    const Accept = struct {
        fn accepts(_: ?*const anyopaque, code: []const u8) bool { return std.mem.eql(u8, code, "ss"); }
    };
    const filter: Iterator.MarkerFilter = .{ .ctx = null, .accepts = Accept.accepts };
    const row = "* IsiSwazi: [[sawubona]] ([[:ss:sawubona|ss]])\n";
    try std.testing.expectEqualStrings("ss", peerLanguageReferenceCode("==IsiZulu==\n" ++ row, "IsiSwazi", "sawubona", filter).?);
    inline for (.{
        "* IsiSwazi: [[other]] ([[:ss:sawubona|ss]])\n",
        "* IsiSwazi: [[sawubona]] ([[:ss:other|ss]])\n",
        "* IsiSwazi: [[sawubona]] ([[:commons:sawubona|commons]])\n",
        "* IsiSwazi: [[sawubona]] ([[:ss:sawubona|Swati]])\n",
        "* IsiSwazi extra: [[sawubona]] ([[:ss:sawubona|ss]])\n",
        "* XIsiSwazi: [[sawubona]] ([[:ss:sawubona|ss]])\n",
        "* [[sawubona]] ([[:ss:sawubona|ss]])\n",
        "* IsiSwazi: [[sawubona]] ([[:ss:sawubona|ss]]) prose\n",
        " " ++ row, ":" ++ row, "*" ++ row,
        "<!--\n" ++ row ++ "-->\n",
        "<nowiki>\n" ++ row ++ "</nowiki>\n",
        "<pre>\n" ++ row ++ "</pre>\n",
        "<blockquote>\n" ++ row ++ "</blockquote>\n",
        "<div class=quote>\n" ++ row ++ "</div>\n",
        "{|\n|\n" ++ row ++ "|}\n",
        "{{quote|\n" ++ row ++ "}}\n",
        "{{unclosed|\n" ++ row,
        "[[unclosed|\n" ++ row,
    }) |source| try std.testing.expect(peerLanguageReferenceCode(source, "IsiSwazi", "sawubona", filter) == null);
    var ordinary: std.ArrayList(u8) = .empty;
    defer ordinary.deinit(std.testing.allocator);
    for (0..4096) |_| try ordinary.appendSlice(std.testing.allocator, "ordinary prose with [[links]] and * non-row text\n");
    try std.testing.expect(peerLanguageReferenceCode(ordinary.items, "IsiSwazi", "sawubona", filter) == null);
}


test "HTML heading precheck includes renderer physical line normalization" {
    for ([_][]const u8{
        "<h2>Béarla</h2>",
        "<H2 title='English'>Béarla</H2>\r\n# meaning",
        "prefix\n<h2>Béarla</h2>\r\r\n# meaning",
        "<nowiki>\n<h2>Béarla</h2>\n</nowiki>",
    }) |source| try std.testing.expect(mayHavePlainLineHtmlH2(source));
    for ([_][]const u8{
        "==Béarla==\n# meaning",
        "<h3>Béarla</h3>",
        "prefix<h2>Béarla</h2>",
        "<h2>Béarla</h2>suffix",
        "<h2>Béarla",
    }) |source| try std.testing.expect(!mayHavePlainLineHtmlH2(source));
}


test "linked HTML H1 language syntax requires ordinary links and nonvisible namespace categories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategoria\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const line = "<h1 style='clear:both'>[[english|English]]</h1>[[Categoria:English]]";
    try std.testing.expectEqualStrings("[[english|English]]", linkedLineHtmlH1(line, &namespaces).?);
    try std.testing.expectEqualStrings("[[English]]", linkedLineHtmlH1("<H1>[[English]]</H1> [[Category:English|entry]] [[Categoria:Words]]", &namespaces).?);
    try std.testing.expect(mayHaveLanguageHtmlHeading(line ++ "\r\n# body", &namespaces));
    try std.testing.expect(linkedLineHtmlH1(line, null) == null);
    for ([_][]const u8{
        "<h1>[[File:English|English]]</h1>", "<h1>[[Media:English|English]]</h1>",
        "<h1>[[:Category:English|English]]</h1>", "<h1>[[en:English|English]]</h1>",
        "<h1>[[English#part|English]]</h1>", "<h1>[[English|English|caption]]</h1>",
        "<h1>[[English|<span>English</span>]]</h1>", "<h1>[[English]] prose</h1>",
        "<h1>[[English]]</h1>[[File:Icon.svg|caption]]", "<h1>[[English]]</h1>[[:Category:English]]",
        "<h1>[[English]]</h1>[[Category:]]", "<h1>[[English]]</h1>[[Category:English|{{sort}}]]",
        "<h1>[[English]]</h1>[[Category:English|a|b]]", "<h1>[[English]]</h1> trailing prose",
        "<h1>[[English]]", " <h1>[[English]]</h1>", "<h2>[[English]]</h2>",
    }) |invalid| try std.testing.expect(linkedLineHtmlH1(invalid, &namespaces) == null);
    // Syntax alone cannot confer a language owner, and copied source offsets
    // cannot borrow the original renderer observation.
    const source = line ++ "\n# body";
    const offsets = [_]usize{0};
    const Filter = struct {
        fn accepts(_: ?*const anyopaque, value: []const u8) bool { return std.mem.eql(u8, value, "[[english|English]]"); }
    };
    var scopes: HtmlHeadingScopes = .{ .source = source, .openings = &offsets, .namespace_catalog = &namespaces };
    try std.testing.expect(scopes.heading(source, 0, line) == null);
    scopes.linked_h1_filter = .{ .ctx = null, .accepts = Filter.accepts };
    try std.testing.expectEqual(@as(u8, 1), scopes.heading(source, 0, line).?.level);
    const copy = try a.dupe(u8, source);
    try std.testing.expect(scopes.heading(copy, 0, line) == null);
    try std.testing.expect(scopes.heading(source, 1, line) == null);
    try std.testing.expectEqualStrings("English", plainLineHtmlH2("<h2>English</h2>").?);
    try std.testing.expect(plainLineHtmlH2("<h2>[[English]]</h2>") == null);
}

const LeadingDeclaredLanguageTest = struct {
    fn accepts(_: ?*const anyopaque, label: []const u8) bool {
        return std.mem.eql(u8, label, "سنڌي") or std.mem.eql(u8, label, "انگريزي");
    }
    fn iterator(source: []const u8) Iterator {
        var result = Iterator.init(source);
        result.heading_filter = .{ .ctx = null, .accepts = accepts };
        return result;
    }
};

test "leading declared deeper language retains exact source before shallower peer" {
    const first = "=== سنڌي ===\n# ڏيکاءُ\n# مَڪر\n\n";
    const second = "== انگريزي ==\n# English sense\n";
    var it = LeadingDeclaredLanguageTest.iterator(" \n\t\n" ++ first ++ second);
    try std.testing.expectEqualStrings("سنڌي", it.next().?.heading);
    // The original fixture indented the delimiter itself. Keep that exact
    // spelling as a negative: blank prefix lines are not indented headings.
    var indented = LeadingDeclaredLanguageTest.iterator(" \n\t" ++ first ++ second);
    try std.testing.expectEqualStrings(second, indented.next().?.source);
    try std.testing.expect(indented.next() == null);
    // Leading whitespace is intentionally outside the first section, as for L2.
    var exact = LeadingDeclaredLanguageTest.iterator(first ++ second);
    try std.testing.expectEqualStrings(first, exact.next().?.source);
    try std.testing.expectEqualStrings(second, exact.next().?.source);
    try std.testing.expect(exact.next() == null and exact.mixed_levels);
    var unproved = Iterator.init(first ++ second);
    try std.testing.expectEqualStrings(second, unproved.next().?.source);
    try std.testing.expect(unproved.next() == null);
    var deeper = LeadingDeclaredLanguageTest.iterator("==== سنڌي ====\n# sense\n" ++ second);
    try std.testing.expectEqualStrings("سنڌي", deeper.next().?.heading);
    try std.testing.expectEqualStrings("انگريزي", deeper.next().?.heading);
    try std.testing.expect(deeper.next() == null);
}

test "leading deeper language refuses unknown prefix nested and protected declarations" {
    const ending = "== انگريزي ==\n# retained peer\n";
    for ([_][]const u8{
        "=== Unknown ===\n# unknown\n",
        "Meaningful prefix\n=== سنڌي ===\n# prefix sense\n",
        "=== Noun ===\n=== سنڌي ===\n# nested sense\n",
        "<nowiki>\n=== سنڌي ===\n</nowiki>\n",
        "<pre>\n=== سنڌي ===\n</pre>\n",
        "<!--\n=== سنڌي ===\n-->\n",
        "{|\n|\n=== سنڌي ===\n|}\n",
        "[[target|\n=== سنڌي ===\n]]\n",
        "{{wrapper|\n=== سنڌي ===\n}}\n",
    }) |prefix| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{prefix, ending});
        defer std.testing.allocator.free(source);
        var it = LeadingDeclaredLanguageTest.iterator(source);
        try std.testing.expectEqualStrings(ending, it.next().?.source);
        try std.testing.expect(it.next() == null);
    }
    const nested = "== انگريزي ==\n=== سنڌي ===\n# subordinate body\n";
    var it = LeadingDeclaredLanguageTest.iterator(nested);
    try std.testing.expectEqualStrings(nested, it.next().?.source);
    try std.testing.expect(it.next() == null);
}

test "declared deep language peers split at active depth without promoting children or unknown labels" {
    const first = "=== سنڌي ===\n# Sindhi\n==== انگريزي ====\n# nested child\n=== Unknown ===\n# support\n";
    const second = "=== انگريزي ===\n# English\n";
    var it = LeadingDeclaredLanguageTest.iterator(first ++ second);
    try std.testing.expectEqualStrings(first, it.next().?.source);
    try std.testing.expectEqualStrings(second, it.next().?.source);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(!it.mixed_levels);
    const deeper_first = "==== سنڌي ====\n# Sindhi\n===== انگريزي =====\n# child\n";
    const deeper_second = "==== انگريزي ====\n# English\n";
    var deeper = LeadingDeclaredLanguageTest.iterator(deeper_first ++ deeper_second);
    try std.testing.expectEqualStrings(deeper_first, deeper.next().?.source);
    try std.testing.expectEqualStrings(deeper_second, deeper.next().?.source);
    try std.testing.expect(deeper.next() == null);
    var unproved = Iterator.init(first ++ second);
    try std.testing.expect(unproved.next() == null);
    const nested = "== سنڌي ==\n" ++ second;
    var under_l2 = LeadingDeclaredLanguageTest.iterator(nested);
    try std.testing.expectEqualStrings(nested, under_l2.next().?.source);
    try std.testing.expect(under_l2.next() == null);
}

test "plain HTML H1 language boundary requires original observed source and trusted complete label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const line = "<h1>Հայերեն</h1>";
    const source = line ++ "\n# body";
    try std.testing.expectEqualStrings("Հայերեն", plainLineHtmlH1(line).?);
    try std.testing.expectEqualStrings("Հայերեն", plainLineHtmlH1("<H1 class='owner'> Հայերեն </H1>").?);
    try std.testing.expect(mayHaveLanguageHtmlHeading(source, null));
    try std.testing.expect(mayHaveLanguageHtmlHeading(line ++ "\r\n# body", null));
    const offsets = [_]usize{0};
    const Filter = struct {
        fn accepts(_: ?*const anyopaque, label: []const u8) bool { return std.mem.eql(u8, label, "Հայերեն"); }
    };
    var scope: HtmlHeadingScopes = .{ .source = source, .openings = &offsets };
    try std.testing.expect(scope.heading(source, 0, line) == null);
    scope.linked_h1_filter = .{ .ctx = null, .accepts = Filter.accepts };
    const heading = scope.heading(source, 0, line) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), heading.level);
    try std.testing.expectEqualStrings("Հայերեն", heading.title);
    try std.testing.expect(scope.heading(try a.dupe(u8, source), 0, line) == null);
    try std.testing.expect(scope.heading(source, 1, line) == null);
    const unknown = "<h1>Unknown label</h1>\n# body";
    scope.source = unknown;
    try std.testing.expect(scope.heading(unknown, 0, "<h1>Unknown label</h1>") == null);
    for ([_][]const u8{
        " <h1>Հայերեն</h1>", "<h1>Հայերեն</h1> prose", "<h1>Հայերեն</h1>[[Category:Words]]",
        "<h1>[[Հայերեն]]</h1>", "<h1><span>Հայերեն</span></h1>", "<h1>{{hy}}</h1>",
        "<h1>Հայերեն&amp;</h1>", "<h1>Հայերեն|English</h1>", "<h1>Հայերեն\nEnglish</h1>",
        "<h1></h1>", "<h1>Հայերեն", "<h1/>Հայերեն", "<h2>Հայերեն</h2>",
    }) |invalid| try std.testing.expect(plainLineHtmlH1(invalid) == null);
    try std.testing.expectEqualStrings("English", plainLineHtmlH2("<h2>English</h2>").?);
    try std.testing.expect(plainLineHtmlH2(line) == null);
}


test "qualifier lexical tail requires a complete plain visible link and leaves old policy unchanged" {
    const prefix = "==Unrecorded==\n===Pronoun===\n# ";
    inline for (.{ "{{demonstrative|lang=io}} [[ഈ]] ([[സാധനം]])", "{{cardinal|lang=no}} [[രണ്ട്]]", "{{context|demonstrative}} [[ഈ]]" }) |tail| {
        const section: Section = .{ .heading = "Unrecorded", .source = prefix ++ tail ++ "\n" };
        try std.testing.expect(!authoredL2LexicalSubtree(section, null));
        try std.testing.expect(authoredL2LexicalSubtreeWithLiteralTail(section, null));
    }
    inline for (.{ "{{qualifier|x}}<span></span>", "{{qualifier|x}}''", "{{qualifier|x}}<!--empty-->", "{{qualifier|x}}[[Category:empty]]", "{{qualifier|x}}[[target|]]", "{{qualifier|x}}[[target|''']]", "{{qualifier|x}}[[target|<span></span>]]", "{{qualifier|x}}[[target|{{empty}}]]", "{{qualifier|x}}[[broken" }) |tail| {
        const section: Section = .{ .heading = "Unrecorded", .source = prefix ++ tail ++ "\n" };
        try std.testing.expect(!authoredL2LexicalSubtreeWithLiteralTail(section, null));
    }
}

test "linked L2 lexical source proof requires an exact local unpiped heading and authored subtree" {
    const good = "==[[Unregistered]]==\n===Noun===\n'''lemma'''\n# meaning\n";
    const section: Section = .{ .heading = "[[Unregistered]]", .source = good };
    try std.testing.expectEqualStrings("Unregistered", linkedL2Section(section, null) orelse return error.TestUnexpectedResult);
    try std.testing.expect(authoredLinkedL2LexicalSubtree(section, null));
    try std.testing.expect(!literalL2Section(section, null));
    try std.testing.expect(!authoredL2LexicalSubtree(section, null));
    for ([_][]const u8{ "[[Unregistered|label]]", "[[File:Unregistered]]", "[[Unknown#fragment]]", "[[Unknown%20title]]", "[[ Unknown]]", "[[Unknown]] tail", "<nowiki>[[Unknown]]</nowiki>", "{{Unknown}}", "[[Unknown&x;]]" }) |heading| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const source = try std.fmt.allocPrint(arena.allocator(), "=={s}==\n===Noun===\n# meaning\n", .{heading});
        try std.testing.expect(linkedL2Section(.{ .heading = heading, .source = source }, null) == null);
    }
    for ([_][]const u8{
        "==[[Unregistered]]==\n# direct without lexical child\n",
        "==[[Unregistered]]==\n<nowiki>===Noun===\n# protected</nowiki>\n",
        "==[[Unregistered]]==\n{|\n|\n===Noun===\n# cell\n|}\n",
        "==[[Unregistered]]==\n===Noun===\n#: example only\n",
        "==[[Unregistered]]==\n===Noun===\n# {{unknown}}\n",
    }) |source| try std.testing.expect(!authoredLinkedL2LexicalSubtree(.{ .heading = "[[Unregistered]]", .source = source }, null));
}

test "JA L language declarations retain unknown peer boundaries without assigning aliases" {
    try std.testing.expectEqualStrings("roa-opt", explicitLanguageDeclaration("{{L|roa-opt}}", "ja").?);
    try std.testing.expectEqualStrings("fr", explicitLanguageDeclaration(" {{ L | fr }} ", "ja").?);
    try std.testing.expectEqualStrings("unknown-code", explicitLanguageDeclaration("{{L|unknown-code}}", "ja").?);
    for ([_][]const u8{ "en", "ar", "az", "fr" }) |edition|
        try std.testing.expect(explicitLanguageDeclaration("{{L|roa-opt}}", edition) == null);
    for ([_][]const u8{ "{{l|roa-opt}}", "{{L|}}", "{{L|roa-opt|extra}}", "{{L|1=roa-opt}}", "{{L|{{nested}}}}", "{{L|[[roa-opt]]}}", "prefix {{L|roa-opt}}", "{{verb}}", "動詞", "{{L|fr\npt}}" }) |heading|
        try std.testing.expect(explicitLanguageDeclaration(heading, "ja") == null);
}
