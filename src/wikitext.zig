const std = @import("std");
const xml_decode = @import("xml_decode.zig");

const max_gloss_bytes = 2048;
const max_example_bytes = 1024;
const max_section_bytes = 3072;

pub const TempSense = struct {
    group: []const u8,
    pos: []const u8,
    gloss: []const u8,
    examples: []const u8,
    depth: u16,
};

pub const TempSection = struct {
    group: []const u8,
    title: []const u8,
    body: []const u8,
};

pub const ParsedEntry = struct {
    word: []const u8,
    alt_forms: std.ArrayListUnmanaged([]const u8) = .empty,
    canonical_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    sections: std.ArrayListUnmanaged(TempSection) = .empty,
    senses: std.ArrayListUnmanaged(TempSense) = .empty,
    alias_only: bool = false,
    has_real_sense: bool = false,

    pub fn deinit(self: *ParsedEntry, allocator: std.mem.Allocator) void {
        self.alt_forms.deinit(allocator);
        self.canonical_targets.deinit(allocator);
        self.sections.deinit(allocator);
        self.senses.deinit(allocator);
    }
};

const Heading = struct {
    level: u8,
    title: []const u8,
};

const PosCapture = struct {
    group: []const u8,
    pos: []const u8,
    level: u8,
};

const SectionBuffer = struct {
    allocator: std.mem.Allocator,
    group: []const u8,
    title: []const u8,
    level: u8,
    body: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator, group: []const u8, title: []const u8, level: u8) SectionBuffer {
        return .{
            .allocator = allocator,
            .group = group,
            .title = title,
            .level = level,
        };
    }

    fn deinit(self: *SectionBuffer) void {
        self.body.deinit(self.allocator);
    }

    fn appendRawLine(self: *SectionBuffer, raw_line: []const u8) !void {
        const cleaned = try renderWikitextToOwned(self.allocator, trimListPrefix(raw_line), max_section_bytes);
        if (cleaned.len == 0) return;

        if (self.body.items.len != 0) try self.body.append(self.allocator, '\n');

        const room = max_section_bytes -| self.body.items.len;
        if (room == 0) return;
        try self.body.appendSlice(self.allocator, cleaned[0..@min(room, cleaned.len)]);
    }
};

const LogicalBalance = struct {
    templates: usize = 0,
    links: usize = 0,
    comments: usize = 0,

    fn update(self: *LogicalBalance, line: []const u8) void {
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
                continue;
            }
        }
    }

    fn isOpen(self: LogicalBalance) bool {
        return self.templates != 0 or self.links != 0 or self.comments != 0;
    }
};

const ParsedDefinitionLine = struct {
    const Kind = enum { sense, example };

    depth: u16,
    kind: Kind,
    content: []const u8,
};

pub fn parseEnglishEntry(allocator: std.mem.Allocator, title: []const u8, text: []const u8) !?ParsedEntry {
    var entry: ParsedEntry = .{
        .word = try allocator.dupe(u8, title),
    };
    errdefer entry.deinit(allocator);

    var in_english = false;
    var current_group: []const u8 = "";
    var alt_level: ?u8 = null;
    var pos_capture: ?PosCapture = null;
    var section_capture: ?SectionBuffer = null;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var balance: LogicalBalance = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");

        if (pending.items.len == 0) {
            if (parseHeading(raw_line)) |heading| {
                if (section_capture) |*capture| {
                    try flushSectionCapture(allocator, &entry, capture);
                    capture.deinit();
                }
                section_capture = null;
                pos_capture = null;
                alt_level = null;

                if (heading.level == 2) {
                    if (in_english and !std.mem.eql(u8, heading.title, "English")) break;
                    in_english = std.mem.eql(u8, heading.title, "English");
                    current_group = "";
                    continue;
                }
                if (!in_english) continue;

                if (heading.level == 3) {
                    current_group = if (isNumberedEtymology(heading.title)) heading.title else "";
                }

                if (std.mem.eql(u8, heading.title, "Alternative forms")) {
                    alt_level = heading.level;
                    continue;
                }
                if (isEtymologyTitle(heading.title)) {
                    section_capture = SectionBuffer.init(
                        allocator,
                        if (isNumberedEtymology(heading.title)) heading.title else "",
                        "Etymology",
                        heading.level,
                    );
                    continue;
                }
                if (isPartOfSpeech(heading.title)) {
                    pos_capture = .{
                        .group = current_group,
                        .pos = heading.title,
                        .level = heading.level,
                    };
                    continue;
                }
                if (isInterestingInfoSection(heading.title)) {
                    section_capture = SectionBuffer.init(allocator, current_group, heading.title, heading.level);
                    continue;
                }
                continue;
            }
        }

        if (!in_english) continue;

        if (pending.items.len != 0) {
            if (pending.items.len != 0) try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, raw_line);
            balance.update(raw_line);
            if (balance.isOpen()) continue;

            try processLogicalLine(
                allocator,
                &entry,
                pending.items,
                alt_level != null,
                pos_capture,
                if (section_capture) |*capture| capture else null,
            );
            pending.items.len = 0;
            balance = .{};
            continue;
        }

        var line_balance: LogicalBalance = .{};
        line_balance.update(raw_line);
        if (line_balance.isOpen()) {
            try pending.appendSlice(allocator, raw_line);
            balance = line_balance;
            continue;
        }

        try processLogicalLine(
            allocator,
            &entry,
            raw_line,
            alt_level != null,
            pos_capture,
            if (section_capture) |*capture| capture else null,
        );
    }

    if (pending.items.len != 0 and in_english) {
        try processLogicalLine(
            allocator,
            &entry,
            pending.items,
            alt_level != null,
            pos_capture,
            if (section_capture) |*capture| capture else null,
        );
    }
    if (section_capture) |*capture| {
        try flushSectionCapture(allocator, &entry, capture);
        capture.deinit();
    }

    entry.alias_only = entry.canonical_targets.items.len != 0 and !entry.has_real_sense;
    if (entry.alt_forms.items.len == 0 and entry.canonical_targets.items.len == 0 and entry.sections.items.len == 0 and entry.senses.items.len == 0) {
        entry.deinit(allocator);
        return null;
    }

    return entry;
}

fn processLogicalLine(
    allocator: std.mem.Allocator,
    entry: *ParsedEntry,
    raw_line: []const u8,
    in_alt_section: bool,
    pos_capture: ?PosCapture,
    section_capture: ?*SectionBuffer,
) !void {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (trimmed.len == 0) return;

    if (in_alt_section) {
        try extractTermsFromLine(allocator, &entry.alt_forms, trimmed);
        return;
    }
    if (pos_capture) |capture| {
        try consumePosLine(allocator, entry, capture, trimmed);
        return;
    }
    if (section_capture) |capture| {
        try capture.appendRawLine(trimmed);
    }
}

fn flushSectionCapture(allocator: std.mem.Allocator, entry: *ParsedEntry, capture: *SectionBuffer) !void {
    const body = std.mem.trim(u8, capture.body.items, " \n\t");
    if (body.len == 0) return;
    try entry.sections.append(allocator, .{
        .group = try allocator.dupe(u8, capture.group),
        .title = try allocator.dupe(u8, capture.title),
        .body = try allocator.dupe(u8, body),
    });
}

fn consumePosLine(allocator: std.mem.Allocator, entry: *ParsedEntry, capture: PosCapture, raw_line: []const u8) !void {
    const parsed = parseDefinitionLine(raw_line) orelse return;
    const cleaned = try renderWikitextToOwned(
        allocator,
        parsed.content,
        if (parsed.kind == .sense) max_gloss_bytes else max_example_bytes,
    );
    if (cleaned.len == 0) return;

    if (parsed.kind == .sense) {
        const is_alias = try extractCanonicalTargetsFromDefinition(allocator, &entry.canonical_targets, parsed.content);
        if (!is_alias) entry.has_real_sense = true;

        try entry.senses.append(allocator, .{
            .group = try allocator.dupe(u8, capture.group),
            .pos = try allocator.dupe(u8, capture.pos),
            .gloss = cleaned,
            .examples = "",
            .depth = parsed.depth,
        });
        return;
    }

    if (entry.senses.items.len == 0) return;
    const sense = &entry.senses.items[entry.senses.items.len - 1];
    sense.examples = try appendOwnedLine(allocator, sense.examples, cleaned, max_example_bytes);
}

fn appendOwnedLine(allocator: std.mem.Allocator, existing: []const u8, addition: []const u8, limit: usize) ![]const u8 {
    if (addition.len == 0) return existing;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    if (existing.len != 0) try out.appendSlice(allocator, existing[0..@min(existing.len, limit)]);
    if (existing.len != 0 and out.items.len < limit) try out.append(allocator, '\n');
    if (out.items.len < limit) {
        const room = limit - out.items.len;
        try out.appendSlice(allocator, addition[0..@min(room, addition.len)]);
    }
    return out.toOwnedSlice(allocator);
}

fn parseHeading(line: []const u8) ?Heading {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 4 or trimmed[0] != '=') return null;

    var left: usize = 0;
    while (left < trimmed.len and trimmed[left] == '=') : (left += 1) {}
    if (left < 2 or left > 6) return null;

    var right = trimmed.len;
    while (right > 0 and trimmed[right - 1] == '=') : (right -= 1) {}
    if (trimmed.len - right != left or right <= left) return null;

    const title = std.mem.trim(u8, trimmed[left..right], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(left), .title = title };
}

fn parseDefinitionLine(line: []const u8) ?ParsedDefinitionLine {
    var i: usize = 0;
    var depth: u16 = 0;
    while (i < line.len and line[i] == '#') : (i += 1) depth += 1;
    if (depth == 0) return null;

    var kind: ParsedDefinitionLine.Kind = .sense;
    while (i < line.len and (line[i] == ':' or line[i] == '*')) : (i += 1) {
        kind = .example;
    }

    const content = std.mem.trimStart(u8, line[i..], " \t");
    if (content.len == 0) return null;
    return .{
        .depth = depth,
        .kind = kind,
        .content = content,
    };
}

fn trimListPrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == '*' or line[i] == ':' or line[i] == ';' or line[i] == '#')) : (i += 1) {}
    return std.mem.trimStart(u8, line[i..], " \t");
}

fn isEtymologyTitle(title: []const u8) bool {
    return std.mem.eql(u8, title, "Etymology") or isNumberedEtymology(title);
}

fn isNumberedEtymology(title: []const u8) bool {
    return std.mem.startsWith(u8, title, "Etymology ");
}

fn isInterestingInfoSection(title: []const u8) bool {
    return std.mem.eql(u8, title, "Pronunciation") or
        std.mem.eql(u8, title, "Usage notes") or
        std.mem.eql(u8, title, "Synonyms") or
        std.mem.eql(u8, title, "Antonyms") or
        std.mem.eql(u8, title, "Related terms") or
        std.mem.eql(u8, title, "Coordinate terms") or
        std.mem.eql(u8, title, "Hypernyms") or
        std.mem.eql(u8, title, "Hyponyms") or
        std.mem.eql(u8, title, "See also");
}

fn isPartOfSpeech(title: []const u8) bool {
    inline for ([_][]const u8{
        "Noun",
        "Proper noun",
        "Verb",
        "Adjective",
        "Adverb",
        "Pronoun",
        "Preposition",
        "Conjunction",
        "Interjection",
        "Determiner",
        "Numeral",
        "Phrase",
        "Article",
        "Abbreviation",
        "Initialism",
        "Symbol",
        "Letter",
        "Contraction",
        "Participle",
        "Particle",
        "Affix",
        "Prefix",
        "Suffix",
        "Infix",
        "Circumfix",
        "Proverb",
        "Idiom",
        "Proper Noun",
    }) |candidate| {
        if (std.mem.eql(u8, title, candidate)) return true;
    }
    return false;
}

fn renderWikitextToOwned(allocator: std.mem.Allocator, input: []const u8, max_len: usize) std.mem.Allocator.Error![]const u8 {
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    try renderInline(&rendered, allocator, input);

    const decoded = try xml_decode.decodeAlloc(allocator, rendered.items);
    defer allocator.free(decoded);

    var collapsed: std.ArrayList(u8) = .empty;
    defer collapsed.deinit(allocator);
    try collapseWhitespace(&collapsed, allocator, decoded, max_len);
    return collapsed.toOwnedSlice(allocator);
}

fn renderInline(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < input.len) {
        if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "<!--")) {
            const end = std.mem.indexOfPos(u8, input, i + 4, "-->") orelse input.len;
            i = @min(end + 3, input.len);
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            const end = findBalanced(input, i, "{{", "}}") orelse break;
            try renderTemplate(out, allocator, input[i + 2 .. end]);
            i = end + 2;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            const end = findBalanced(input, i, "[[", "]]") orelse break;
            try renderLink(out, allocator, input[i + 2 .. end]);
            i = end + 2;
            continue;
        }
        if (input[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, input, i + 1, ']')) |end| {
                if (std.mem.startsWith(u8, input[i + 1 ..], "http")) {
                    const body = input[i + 1 .. end];
                    if (std.mem.indexOfScalar(u8, body, ' ')) |space| {
                        try renderInline(out, allocator, body[space + 1 ..]);
                    }
                    i = end + 1;
                    continue;
                }
            }
        }
        if (input[i] == '<') {
            if (asciiStartsWithIgnoreCase(input[i..], "<br") or asciiStartsWithIgnoreCase(input[i..], "<hr")) {
                try appendWithSpace(out, allocator, " ");
                i = (std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len) + 1;
                continue;
            }
            if (asciiStartsWithIgnoreCase(input[i..], "<ref")) {
                if (std.mem.indexOfPos(u8, input, i, "</ref>")) |end| {
                    i = end + "</ref>".len;
                    continue;
                }
            }
            i = (std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len) + 1;
            continue;
        }
        if (input[i] == '\'' and i + 1 < input.len and input[i + 1] == '\'') {
            while (i < input.len and input[i] == '\'') : (i += 1) {}
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
}

fn renderLink(out: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const selected = if (parts.items.len >= 2)
        parts.items[parts.items.len - 1]
    else blk: {
        var target = parts.items[0];
        if (std.mem.indexOfScalar(u8, target, '#')) |hash_index| target = target[0..hash_index];
        if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon_index| {
            if (colon_index + 1 < target.len) target = target[colon_index + 1 ..];
        }
        break :blk target;
    };
    try renderInline(out, allocator, selected);
}

fn renderTemplate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const name = std.mem.trim(u8, parts.items[0], " \t");

    if (templateMatches(name, "also") or templateMatches(name, "wikipedia") or templateMatches(name, "slim-wikipedia") or templateMatches(name, "minitoc") or templateMatches(name, "wikidata lexeme") or templateMatches(name, "trans-see") or templateMatches(name, "senseid") or templateMatches(name, "etymid") or templateMatches(name, "picdic") or templateMatches(name, "elements")) {
        return;
    }

    if (templateMatches(name, "lb") or templateMatches(name, "lbl") or templateMatches(name, "label")) {
        try appendLabeledList(out, allocator, &parts, "(", ")");
        return;
    }
    if (templateMatches(name, "qualifier") or templateMatches(name, "q")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "gloss")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "ux") or templateMatches(name, "uxi") or templateMatches(name, "usex")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (std.mem.startsWith(u8, asciiLowerAlloc(allocator, name) catch name, "quote-") or std.mem.startsWith(u8, name, "RQ:")) {
        if (templateNamed(&parts, "passage") orelse templateNamed(&parts, "text")) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "syn")) {
        try appendWithSpace(out, allocator, "Synonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ant")) {
        try appendWithSpace(out, allocator, "Antonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "alt") or templateMatches(name, "alter")) {
        if (templatePositional(&parts, 1)) |arg| try renderInline(out, allocator, arg);
        if (templatePositional(&parts, 2)) |qualifier| {
            const rendered = try renderWikitextToOwned(allocator, qualifier, 128);
            if (rendered.len != 0) {
                try appendWithSpace(out, allocator, " (");
                try appendWithSpace(out, allocator, rendered);
                try appendWithSpace(out, allocator, ")");
            }
        }
        return;
    }
    if (templateMatches(name, "standard spelling of") or templateMatches(name, "standard form of") or templateMatches(name, "alternative spelling of") or templateMatches(name, "alternative form of") or templateMatches(name, "alt form") or templateMatches(name, "alt spelling of") or templateMatches(name, "dated spelling of") or templateMatches(name, "obsolete spelling of") or templateMatches(name, "nonstandard spelling of") or templateMatches(name, "misspelling of") or templateMatches(name, "pronunciation spelling of") or templateMatches(name, "pronunciation variant of")) {
        try appendWithSpace(out, allocator, templateDisplayName(name));
        if (templateAliasTarget(&parts)) |arg| {
            try appendWithSpace(out, allocator, " ");
            try renderInline(out, allocator, arg);
        }
        return;
    }
    if (templateMatches(name, "enpr")) {
        try appendPositional(out, allocator, &parts, 0, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ipa")) {
        try appendWithSpace(out, allocator, "IPA ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "audio")) {
        try appendWithSpace(out, allocator, "audio");
        if (templateNamed(&parts, "a")) |accent| {
            try appendWithSpace(out, allocator, " (");
            try renderInline(out, allocator, accent);
            try appendWithSpace(out, allocator, ")");
        }
        return;
    }
    if (templateMatches(name, "homophones")) {
        try appendWithSpace(out, allocator, "Homophones: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "hyph")) {
        try appendWithSpace(out, allocator, "Hyphenation: ");
        try appendPositional(out, allocator, &parts, 1, "", "", "-");
        return;
    }
    if (templateMatches(name, "rhymes") or templateMatches(name, "rhyme")) {
        try appendWithSpace(out, allocator, "Rhymes: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (isLexicalTemplate(name)) {
        if (templateLexeme(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (isColumnTemplate(name)) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateNamed(&parts, "passage") orelse templateNamed(&parts, "text")) |arg| {
        try renderInline(out, allocator, arg);
        return;
    }
    if (templatePositional(&parts, positionalCount(&parts) -| 1)) |fallback| {
        try renderInline(out, allocator, fallback);
    }
}

fn templateLexeme(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, if (positionalCount(parts) >= 2) 1 else 0);
}

fn extractCanonicalTargetsFromDefinition(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    definition: []const u8,
) !bool {
    var i: usize = 0;
    var found = false;
    while (i + 2 <= definition.len) {
        if (!std.mem.eql(u8, definition[i .. i + 2], "{{")) {
            i += 1;
            continue;
        }
        const end = findBalanced(definition, i, "{{", "}}") orelse break;
        const body = definition[i + 2 .. end];
        var parts = try splitTopLevel(allocator, body, '|');
        defer parts.deinit(allocator);
        if (parts.items.len != 0 and isAliasTemplate(parts.items[0])) {
            if (templateAliasTarget(&parts)) |target_raw| {
                const target = try renderWikitextToOwned(allocator, target_raw, 256);
                try addUniqueTerm(out, allocator, target);
                found = true;
            }
        }
        i = end + 2;
    }
    return found;
}

fn extractTermsFromLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    line: []const u8,
) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "{{")) {
            const end = findBalanced(line, i, "{{", "}}") orelse break;
            const body = line[i + 2 .. end];
            var parts = try splitTopLevel(allocator, body, '|');
            defer parts.deinit(allocator);
            if (parts.items.len != 0) {
                const name = parts.items[0];
                if (templateMatches(name, "alt") or templateMatches(name, "alter") or templateMatches(name, "l") or templateMatches(name, "m") or templateMatches(name, "m+") or templateMatches(name, "link")) {
                    if (templateLexeme(&parts)) |raw| {
                        const rendered = try renderWikitextToOwned(allocator, raw, 256);
                        try pushRenderedTerms(out, allocator, rendered);
                    }
                } else if (isColumnTemplate(name)) {
                    const count = positionalCount(&parts);
                    var pos_index: usize = 1;
                    while (pos_index < count) : (pos_index += 1) {
                        if (templatePositional(&parts, pos_index)) |raw| {
                            const rendered = try renderWikitextToOwned(allocator, raw, 256);
                            try pushRenderedTerms(out, allocator, rendered);
                        }
                    }
                }
            }
            i = end + 2;
            continue;
        }
        if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "[[")) {
            const end = findBalanced(line, i, "[[", "]]") orelse break;
            const body = line[i + 2 .. end];
            if (body.len != 0 and body[0] == '#') {
                i = end + 2;
                continue;
            }
            const rendered = try renderWikitextToOwned(allocator, body, 256);
            try pushRenderedTerms(out, allocator, rendered);
            i = end + 2;
            continue;
        }
        i += 1;
    }
}

fn pushRenderedTerms(out: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator, rendered: []const u8) !void {
    if (rendered.len == 0) return;

    var parts = std.mem.splitAny(u8, rendered, ",;");
    while (parts.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len == 0) continue;
        try addUniqueTerm(out, allocator, trimmed);
    }
}

fn addUniqueTerm(out: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (out.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, value)) return;
    }
    try out.append(allocator, try allocator.dupe(u8, value));
}

fn collapseWhitespace(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8, max_len: usize) std.mem.Allocator.Error!void {
    out.items.len = 0;
    var pending_space = false;

    for (input) |c| {
        if (out.items.len >= max_len) break;
        switch (c) {
            ' ', '\n', '\r', '\t' => pending_space = true,
            else => {
                if (pending_space and out.items.len != 0) {
                    try out.append(allocator, ' ');
                    if (out.items.len >= max_len) break;
                }
                pending_space = false;
                try out.append(allocator, c);
            },
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
    }
}

fn splitTopLevel(allocator: std.mem.Allocator, input: []const u8, sep: u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (input[i] == sep and templates == 0 and links == 0) {
            try out.append(allocator, std.mem.trim(u8, input[start..i], " \t"));
            start = i + 1;
        }
    }
    try out.append(allocator, std.mem.trim(u8, input[start..], " \t"));
    return out;
}

fn findBalanced(input: []const u8, start: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (i + open.len <= input.len and std.mem.eql(u8, input[i .. i + open.len], open)) {
            depth += 1;
            i += open.len - 1;
            continue;
        }
        if (i + close.len <= input.len and std.mem.eql(u8, input[i .. i + close.len], close)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
            i += close.len - 1;
        }
    }
    return null;
}

fn appendWithSpace(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, text);
}

fn appendPositional(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    first_positional: usize,
    prefix: []const u8,
    suffix: []const u8,
    separator: []const u8,
) std.mem.Allocator.Error!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    if (prefix.len != 0) try out.appendSlice(allocator, prefix);
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < first_positional) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, separator);
        try renderInline(out, allocator, segment);
        wrote_any = true;
        positional_index += 1;
    }
    if (suffix.len != 0 and wrote_any) try out.appendSlice(allocator, suffix);
}

fn appendLabeledList(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    prefix: []const u8,
    suffix: []const u8,
) std.mem.Allocator.Error!void {
    try appendPositional(out, allocator, parts, 1, prefix, suffix, ", ");
}

fn templateMatches(name: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), expected);
}

fn templateDisplayName(name: []const u8) []const u8 {
    return std.mem.trim(u8, name, " \t");
}

fn templateArgHasName(segment: []const u8) bool {
    return topLevelEquals(segment) != null;
}

fn topLevelEquals(segment: []const u8) ?usize {
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (segment[i] == '=' and templates == 0 and links == 0) return i;
    }
    return null;
}

fn templateNamed(parts: *const std.ArrayList([]const u8), name: []const u8) ?[]const u8 {
    for (parts.items[1..]) |segment| {
        const equals = topLevelEquals(segment) orelse continue;
        const key = std.mem.trim(u8, segment[0..equals], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) return std.mem.trim(u8, segment[equals + 1 ..], " \t");
    }
    return null;
}

fn positionalCount(parts: *const std.ArrayList([]const u8)) usize {
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        if (!templateArgHasName(segment)) count += 1;
    }
    return count;
}

fn templatePositional(parts: *const std.ArrayList([]const u8), target: usize) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == target) return std.mem.trim(u8, segment, " \t");
        positional_index += 1;
    }
    return null;
}

fn isLexicalTemplate(name: []const u8) bool {
    return templateMatches(name, "l") or templateMatches(name, "m") or templateMatches(name, "m+") or templateMatches(name, "link") or templateMatches(name, "cog") or templateMatches(name, "noncog") or templateMatches(name, "inh") or templateMatches(name, "der") or templateMatches(name, "bor") or templateMatches(name, "af") or templateMatches(name, "doublet");
}

fn isColumnTemplate(name: []const u8) bool {
    return templateMatches(name, "col") or templateMatches(name, "col2") or templateMatches(name, "col3") or templateMatches(name, "col4") or templateMatches(name, "col5");
}

fn isAliasTemplate(name: []const u8) bool {
    return templateMatches(name, "standard spelling of") or
        templateMatches(name, "standard form of") or
        templateMatches(name, "alternative spelling of") or
        templateMatches(name, "alternative form of") or
        templateMatches(name, "alt form") or
        templateMatches(name, "alt spelling of") or
        templateMatches(name, "dated spelling of") or
        templateMatches(name, "obsolete spelling of") or
        templateMatches(name, "nonstandard spelling of") or
        templateMatches(name, "misspelling of") or
        templateMatches(name, "pronunciation spelling of") or
        templateMatches(name, "pronunciation variant of");
}

fn templateAliasTarget(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const count = positionalCount(parts);
    if (count == 0) return null;
    if (count >= 2) return templatePositional(parts, count - 1);
    return templatePositional(parts, 0);
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "parse alternative spelling and noun gloss" {
    const source =
        \\==English==
        \\
        \\===Alternative forms===
        \\* {{alt|en|colour||Commonwealth}}
        \\
        \\===Noun===
        \\# {{lb|en|countable}} [[light]]
        \\
        \\===Verb===
        \\# {{standard spelling of|en|color}}.
    ;

    var parsed = (try parseEnglishEntry(std.testing.allocator, "color", source)).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.alt_forms.items.len);
    try std.testing.expectEqualStrings("colour", parsed.alt_forms.items[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.senses.items.len);
    try std.testing.expectEqualStrings("(countable) light", parsed.senses.items[0].gloss);
    try std.testing.expectEqual(@as(usize, 1), parsed.canonical_targets.items.len);
    try std.testing.expectEqualStrings("color", parsed.canonical_targets.items[0]);
}
