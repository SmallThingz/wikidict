const std = @import("std");
const config = @import("config");
const xml_decode = @import("shared_xml_decode");

const max_gloss_bytes = 2048;
const max_example_bytes = 1024;
const max_section_bytes = 3072;

pub const TempSense = struct {
    // Etymology bucket such as "Etymology 2", or empty for the default group.
    group: []const u8,
    pos: []const u8,
    gloss: []const u8,
    examples: []const u8,
    // Number of leading definition markers (`#`, `##`, ...).
    depth: u16,

    fn deinit(self: *const TempSense, allocator: std.mem.Allocator) void {
        allocator.free(self.group);
        allocator.free(self.pos);
        allocator.free(self.gloss);
        if (self.examples.len != 0) allocator.free(self.examples);
    }
};

pub const TempSection = struct {
    group: []const u8,
    title: []const u8,
    body: []const u8,

    fn deinit(self: *const TempSection, allocator: std.mem.Allocator) void {
        allocator.free(self.group);
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

pub const ParsedEntry = struct {
    word: []const u8,
    alt_forms: std.ArrayListUnmanaged([]const u8) = .empty,
    canonical_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    sections: std.ArrayListUnmanaged(TempSection) = .empty,
    senses: std.ArrayListUnmanaged(TempSense) = .empty,
    // Human-readable alias hint such as "Plural Form Of" for single-sense alias-style entries.
    alias_hint_label: []const u8 = "",
    alias_only: bool = false,
    has_real_sense: bool = false,
    alias_like_sense_count: usize = 0,

    pub fn deinit(self: *ParsedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
        for (self.alt_forms.items) |value| allocator.free(value);
        self.alt_forms.deinit(allocator);
        for (self.canonical_targets.items) |value| allocator.free(value);
        self.canonical_targets.deinit(allocator);
        if (self.alias_hint_label.len != 0) allocator.free(self.alias_hint_label);
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
        for (self.senses.items) |*sense| sense.deinit(allocator);
        self.senses.deinit(allocator);
    }
};

pub const EntryMetadata = struct {
    alt_forms: std.ArrayListUnmanaged([]const u8) = .empty,
    canonical_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    // Only set when the entry is a single-sense alias/form-of entry.
    alias_hint_label: []const u8 = "",
    alias_only: bool = false,

    pub fn deinit(self: *EntryMetadata, allocator: std.mem.Allocator) void {
        for (self.alt_forms.items) |value| allocator.free(value);
        self.alt_forms.deinit(allocator);
        for (self.canonical_targets.items) |value| allocator.free(value);
        self.canonical_targets.deinit(allocator);
        if (self.alias_hint_label.len != 0) allocator.free(self.alias_hint_label);
    }
};

pub const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

pub const ExclusionPolicy = struct {
    exclude_anagrams: bool = false,
    exclude_citations: bool = false,
    exclude_meta: bool = false,
    exclude_statistics: bool = false,
    exclude_further_reading: bool = false,
    exclude_translations: bool = false,

    pub fn defaultCompact() ExclusionPolicy {
        return parseExclusionPolicy(config.skip_headings_csv) catch @panic("invalid -Dskip-headings value");
    }
};

pub fn parseExclusionPolicy(value: []const u8) !ExclusionPolicy {
    var policy: ExclusionPolicy = .{};
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(part, "anagrams") or headingMatches(part, "Anagrams")) {
            policy.exclude_anagrams = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "statistics") or headingMatches(part, "Statistics")) {
            policy.exclude_statistics = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "further_reading") or
            std.ascii.eqlIgnoreCase(part, "further-reading") or
            headingMatches(part, "Further reading"))
        {
            policy.exclude_further_reading = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "translations") or headingMatches(part, "Translations") or headingMatches(part, "Translate")) {
            policy.exclude_translations = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "citations")) {
            policy.exclude_citations = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "meta")) {
            policy.exclude_meta = true;
            continue;
        }

        if (sectionParserSpecForTitle(part, 3)) |parser| {
            switch (parser.kind) {
                .citations => policy.exclude_citations = true,
                .meta => policy.exclude_meta = true,
                .translations => policy.exclude_translations = true,
                else => return error.InvalidArgument,
            }
            continue;
        }
        if (sectionParserSpecForTitle(part, 4)) |parser| {
            switch (parser.kind) {
                .citations => policy.exclude_citations = true,
                .meta => policy.exclude_meta = true,
                .translations => policy.exclude_translations = true,
                else => return error.InvalidArgument,
            }
            continue;
        }

        return error.InvalidArgument;
    }
    return policy;
}

pub const SectionParserKind = enum {
    language_root,
    alternative_forms,
    etymology,
    part_of_speech,
    pronunciation,
    relations,
    translations,
    citations,
    notes,
    navigation,
    descendants,
    inflection,
    meta,
};

pub const SectionParserSpec = struct {
    kind: SectionParserKind,
    parser_name: []const u8,
    canonical_title: []const u8,
};

const PosCapture = struct {
    group: []const u8,
    pos: []const u8,
    level: u8,
};

const parser_name_capture = "SectionBuffer.appendRawLine";
const parser_name_alt_forms = "extractTermsFromLine";
const parser_name_pos = "consumePosLine";

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
        var prefix_end: usize = 0;
        while (prefix_end < raw_line.len and (raw_line[prefix_end] == '*' or raw_line[prefix_end] == ':' or raw_line[prefix_end] == ';' or raw_line[prefix_end] == '#')) : (prefix_end += 1) {}
        const cleaned = try renderWikitextToOwned(
            self.allocator,
            std.mem.trimStart(u8, raw_line[prefix_end..], " \t"),
            max_section_bytes,
        );
        defer self.allocator.free(cleaned);
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

const CanonicalTargetMatch = struct {
    found: bool = false,
    hint_label: ?[]u8 = null,

    fn deinit(self: *CanonicalTargetMatch, allocator: std.mem.Allocator) void {
        if (self.hint_label) |value| allocator.free(value);
    }
};

pub fn parseEnglishEntry(allocator: std.mem.Allocator, title: []const u8, text: []const u8) !?ParsedEntry {
    var entry: ParsedEntry = .{
        .word = try allocator.dupe(u8, title),
    };
    errdefer entry.deinit(allocator);

    var in_english = false;
    var current_group: []const u8 = "";
    var active_parser_kind: ?SectionParserKind = null;
    var pos_capture: ?PosCapture = null;
    var section_capture: ?SectionBuffer = null;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var balance: LogicalBalance = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");

        if (pending.items.len == 0) {
            if (parseHeadingLine(raw_line)) |heading| {
                if (section_capture) |*capture| {
                    try flushSectionCapture(allocator, &entry, capture);
                    capture.deinit();
                }
                section_capture = null;
                pos_capture = null;
                active_parser_kind = null;

                if (heading.level == 2) {
                    if (in_english and !headingMatches(heading.title, "English")) break;
                    in_english = headingMatches(heading.title, "English");
                    current_group = "";
                    if (in_english) {
                        section_capture = SectionBuffer.init(allocator, "", heading.title, heading.level);
                        active_parser_kind = .language_root;
                    }
                    continue;
                }
                if (!in_english) continue;

                const parser = sectionParserSpecForHeading(heading) orelse continue;

                if (heading.level == 3) {
                    current_group = if (parser.kind == .etymology and isNumberedEtymology(heading.title))
                        heading.title
                    else
                        "";
                }

                active_parser_kind = parser.kind;
                switch (parser.kind) {
                    .language_root => {
                        section_capture = SectionBuffer.init(allocator, "", heading.title, heading.level);
                    },
                    .alternative_forms => {},
                    .part_of_speech => {
                        pos_capture = .{
                            .group = current_group,
                            .pos = heading.title,
                            .level = heading.level,
                        };
                    },
                    else => {
                        section_capture = SectionBuffer.init(allocator, current_group, heading.title, heading.level);
                    },
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
                active_parser_kind,
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
            active_parser_kind,
            pos_capture,
            if (section_capture) |*capture| capture else null,
        );
    }

    if (pending.items.len != 0 and in_english) {
        try processLogicalLine(
            allocator,
            &entry,
            pending.items,
            active_parser_kind,
            pos_capture,
            if (section_capture) |*capture| capture else null,
        );
    }
    if (section_capture) |*capture| {
        try flushSectionCapture(allocator, &entry, capture);
        capture.deinit();
    }

    entry.alias_only = entry.canonical_targets.items.len != 0 and !entry.has_real_sense;
    if (!(entry.alias_only and entry.senses.items.len == 1 and entry.alias_like_sense_count == 1 and entry.canonical_targets.items.len == 1)) {
        if (entry.alias_hint_label.len != 0) {
            allocator.free(entry.alias_hint_label);
            entry.alias_hint_label = "";
        }
    }
    if (entry.alt_forms.items.len == 0 and entry.canonical_targets.items.len == 0 and entry.sections.items.len == 0 and entry.senses.items.len == 0) {
        entry.deinit(allocator);
        return null;
    }

    return entry;
}

pub fn extractEnglishSection(text: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var english_start: ?usize = null;

    while (line_start <= text.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const raw_line = std.mem.trimEnd(u8, text[line_start..next_newline], "\r");

        if (parseHeadingLine(raw_line)) |heading| {
            if (heading.level == 2) {
                if (std.mem.eql(u8, heading.title, "English")) {
                    english_start = line_start;
                } else if (english_start) |start| {
                    return text[start..line_start];
                }
            }
        }

        if (next_newline == text.len) break;
        line_start = next_newline + 1;
    }

    if (english_start) |start| return text[start..text.len];
    return null;
}

pub fn extractConfiguredLanguageSectionsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    exclusions: ExclusionPolicy,
) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var line_start: usize = 0;
    var active_start: ?usize = null;

    while (line_start <= text.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const raw_line = std.mem.trimEnd(u8, text[line_start..next_newline], "\r");

        if (parseHeadingLine(raw_line)) |heading| {
            if (heading.level == 2) {
                if (active_start) |start| {
                    try appendFilteredLanguageSection(allocator, &out, text[start..line_start], exclusions);
                }
                active_start = if (shouldStoreLanguage(heading.title)) line_start else null;
            }
        }

        if (next_newline == text.len) break;
        line_start = next_newline + 1;
    }

    if (active_start) |start| {
        try appendFilteredLanguageSection(allocator, &out, text[start..text.len], exclusions);
    }

    if (out.items.len == 0) return null;
    const owned = try out.toOwnedSlice(allocator);
    return owned;
}

fn appendFilteredLanguageSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    language_section: []const u8,
    exclusions: ExclusionPolicy,
) !void {
    const filtered = try filterLanguageSectionAlloc(allocator, language_section, exclusions);
    defer allocator.free(filtered);
    if (filtered.len == 0) return;
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, filtered);
}

fn shouldStoreLanguage(title: []const u8) bool {
    return languageMatchesFilterCsv(title, config.filter_languages_csv);
}

fn languageMatchesFilterCsv(title: []const u8, filter_csv: []const u8) bool {
    if (std.mem.trim(u8, filter_csv, " \t").len == 0) return true;
    var parts = std.mem.splitScalar(u8, filter_csv, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), title)) return true;
    }
    return false;
}

pub fn filterEnglishSectionAlloc(allocator: std.mem.Allocator, english_section: []const u8, exclusions: ExclusionPolicy) ![]u8 {
    return filterLanguageSectionAlloc(allocator, english_section, exclusions);
}

pub fn filterLanguageSectionAlloc(allocator: std.mem.Allocator, language_section: []const u8, exclusions: ExclusionPolicy) ![]u8 {
    if (!exclusions.exclude_anagrams and
        !exclusions.exclude_citations and
        !exclusions.exclude_meta and
        !exclusions.exclude_statistics and
        !exclusions.exclude_further_reading and
        !exclusions.exclude_translations)
    {
        return allocator.dupe(u8, language_section);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var skip_level: ?u8 = null;
    var line_start: usize = 0;
    while (line_start <= language_section.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, language_section, line_start, '\n') orelse language_section.len;
        const line = language_section[line_start..next_newline];
        const raw_line = std.mem.trimEnd(u8, line, "\r");
        const trimmed = std.mem.trim(u8, raw_line, " \t");

        if (parseHeadingLine(raw_line)) |heading| {
            if (skip_level) |level| {
                if (heading.level <= level) {
                    skip_level = null;
                }
            }
            if (skip_level == null and isExcludedHeading(heading.title, heading.level, exclusions)) {
                skip_level = heading.level;
            }
        }

        if (skip_level == null) {
            if (shouldExcludeInlineLine(trimmed, exclusions)) {
                if (next_newline == language_section.len) break;
                line_start = next_newline + 1;
                continue;
            }
            if (out.items.len != 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, line);
        }

        if (next_newline == language_section.len) break;
        line_start = next_newline + 1;
    }

    return out.toOwnedSlice(allocator);
}

fn shouldExcludeInlineLine(line: []const u8, exclusions: ExclusionPolicy) bool {
    if (!exclusions.exclude_citations) return false;
    const parsed = parseDefinitionLine(line) orelse return false;
    if (parsed.kind != .example) return false;
    return isQuotationOnlyContent(parsed.content);
}

fn isQuotationOnlyContent(content: []const u8) bool {
    const body = singleTemplateBody(content) orelse return false;
    const pipe_index = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    const name = std.mem.trim(u8, body[0..pipe_index], " \t");
    return asciiStartsWithIgnoreCase(name, "quote-") or std.mem.startsWith(u8, name, "RQ:");
}

fn singleTemplateBody(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (!std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return null;
    const end = findBalanced(trimmed, 0, "{{", "}}") orelse return null;
    if (end + 2 != trimmed.len) return null;
    return trimmed[2..end];
}

pub fn extractEntryMetadata(allocator: std.mem.Allocator, title: []const u8, english_section: []const u8) !EntryMetadata {
    var metadata: EntryMetadata = .{};
    errdefer metadata.deinit(allocator);

    var parsed = (try parseEnglishEntry(allocator, title, english_section)) orelse return metadata;
    defer parsed.deinit(allocator);

    metadata.alt_forms = parsed.alt_forms;
    parsed.alt_forms = .empty;

    metadata.canonical_targets = parsed.canonical_targets;
    parsed.canonical_targets = .empty;

    metadata.alias_hint_label = parsed.alias_hint_label;
    parsed.alias_hint_label = "";

    metadata.alias_only = parsed.alias_only;
    return metadata;
}

pub fn extractSummaryAlloc(allocator: std.mem.Allocator, english_section: []const u8, max_len: usize) ![]const u8 {
    var current_pos: []const u8 = "";
    var current_head_label: ?[]const u8 = null;
    defer if (current_head_label) |label| allocator.free(label);

    var lines = std.mem.splitScalar(u8, english_section, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trim(u8, std.mem.trimEnd(u8, raw_input, "\r"), " \t");
        if (raw_line.len == 0) continue;

        if (parseHeadingLine(raw_line)) |heading| {
            if (heading.level >= 3 and isRecognizedPartOfSpeech(heading.title)) {
                current_pos = heading.title;
                if (current_head_label) |label| allocator.free(label);
                current_head_label = null;
            } else if (heading.level <= 3) {
                current_pos = "";
                if (current_head_label) |label| allocator.free(label);
                current_head_label = null;
            }
            continue;
        }

        if (current_pos.len != 0 and current_head_label == null and looksLikeHeadSummaryLine(raw_line)) {
            const rendered = try renderWikitextToOwned(allocator, raw_line, 96);
            if (rendered.len == 0) {
                allocator.free(rendered);
            } else {
                current_head_label = rendered;
            }
            continue;
        }

        const parsed = parseDefinitionLine(raw_line) orelse continue;
        if (parsed.kind != .sense) continue;

        const prefix = current_head_label orelse current_pos;
        if (prefix.len == 0) return renderWikitextToOwned(allocator, parsed.content, max_len);
        return renderSummaryWithPrefixAlloc(allocator, prefix, parsed.content, max_len);
    }

    return allocator.dupe(u8, "");
}

fn looksLikeHeadSummaryLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return asciiStartsWithIgnoreCase(trimmed, "{{head|");
}

fn renderSummaryWithPrefixAlloc(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    content: []const u8,
    max_len: usize,
) ![]const u8 {
    const normalized_prefix = try lowerAsciiAlloc(allocator, std.mem.trim(u8, prefix, " \t"));
    defer allocator.free(normalized_prefix);
    if (normalized_prefix.len == 0) return renderWikitextToOwned(allocator, content, max_len);

    const gloss_limit = max_len -| normalized_prefix.len -| 2;
    const rendered = try renderWikitextToOwned(allocator, content, gloss_limit);
    if (rendered.len == 0) return rendered;
    if (asciiStartsWithIgnoreCase(rendered, normalized_prefix)) return rendered;
    defer allocator.free(rendered);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ normalized_prefix, rendered });
}

fn lowerAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*char| char.* = std.ascii.toLower(char.*);
    return out;
}

fn processLogicalLine(
    allocator: std.mem.Allocator,
    entry: *ParsedEntry,
    raw_line: []const u8,
    active_parser_kind: ?SectionParserKind,
    pos_capture: ?PosCapture,
    section_capture: ?*SectionBuffer,
) !void {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (trimmed.len == 0) return;

    const parser_kind = active_parser_kind orelse return;
    switch (parser_kind) {
        .alternative_forms => try extractTermsFromLine(allocator, &entry.alt_forms, trimmed),
        .part_of_speech => {
            const capture = pos_capture orelse return;
            try consumePosLine(allocator, entry, capture, trimmed);
        },
        .language_root => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .etymology => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .pronunciation => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .relations => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .translations => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .citations => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .notes => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .navigation => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .descendants => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .inflection => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
        .meta => {
            const capture = section_capture orelse return;
            try capture.appendRawLine(trimmed);
        },
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
        var alias_match = try extractCanonicalTargetsFromDefinition(allocator, &entry.canonical_targets, parsed.content);
        defer alias_match.deinit(allocator);
        if (alias_match.found) {
            entry.alias_like_sense_count += 1;
            if (entry.alias_hint_label.len == 0) {
                if (alias_match.hint_label) |label| {
                    entry.alias_hint_label = label;
                    alias_match.hint_label = null;
                }
            }
        } else {
            entry.has_real_sense = true;
        }

        try entry.senses.append(allocator, .{
            .group = try allocator.dupe(u8, capture.group),
            .pos = try allocator.dupe(u8, capture.pos),
            .gloss = cleaned,
            .examples = "",
            .depth = parsed.depth,
        });
        return;
    }

    if (entry.senses.items.len == 0) {
        allocator.free(cleaned);
        return;
    }
    const sense = &entry.senses.items[entry.senses.items.len - 1];
    const previous_examples = sense.examples;
    sense.examples = try appendOwnedLine(allocator, previous_examples, cleaned, max_example_bytes);
    if (previous_examples.len != 0) allocator.free(previous_examples);
    allocator.free(cleaned);
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

pub fn parseHeadingLine(line: []const u8) ?ParsedHeading {
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

pub fn sectionParserSpecForHeading(heading: ParsedHeading) ?SectionParserSpec {
    return sectionParserSpecForTitle(heading.title, heading.level);
}

pub fn sectionParserSpecForTitle(title: []const u8, level: u8) ?SectionParserSpec {
    const trimmed = std.mem.trim(u8, title, " \t");
    if (level == 2 and trimmed.len != 0) {
        return .{
            .kind = .language_root,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (isAlternativeFormsHeading(title)) {
        return .{
            .kind = .alternative_forms,
            .parser_name = parser_name_alt_forms,
            .canonical_title = "Alternative forms",
        };
    }
    if (isEtymologyHeading(title)) {
        return .{
            .kind = .etymology,
            .parser_name = parser_name_capture,
            .canonical_title = "Etymology",
        };
    }
    if (isTranslationHeading(title)) {
        return .{
            .kind = .translations,
            .parser_name = parser_name_capture,
            .canonical_title = "Translations",
        };
    }
    if (isDescendantHeading(title)) {
        return .{
            .kind = .descendants,
            .parser_name = parser_name_capture,
            .canonical_title = "Descendants",
        };
    }
    if (isInflectionHeading(title)) {
        return .{
            .kind = .inflection,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (isRelationHeading(title)) {
        return .{
            .kind = .relations,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (isCitationHeading(title)) {
        return .{
            .kind = .citations,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (isNotesHeading(title)) {
        return .{
            .kind = .notes,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (isPronunciationHeading(title)) {
        return .{
            .kind = .pronunciation,
            .parser_name = parser_name_capture,
            .canonical_title = "Pronunciation",
        };
    }
    if (isNavigationHeading(title)) {
        return .{
            .kind = .navigation,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (isPartOfSpeechHeading(title)) {
        return .{
            .kind = .part_of_speech,
            .parser_name = parser_name_pos,
            .canonical_title = title,
        };
    }
    if (isMetaHeading(title)) {
        return .{
            .kind = .meta,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    if (level >= 3 and trimmed.len != 0) {
        return .{
            .kind = .notes,
            .parser_name = parser_name_capture,
            .canonical_title = title,
        };
    }
    return null;
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

pub fn isRecognizedEtymologyTitle(title: []const u8) bool {
    return isEtymologyHeading(title);
}

fn isNumberedEtymology(title: []const u8) bool {
    return headingStartsWith(title, "Etymology ");
}

pub fn isRecognizedInfoSection(title: []const u8) bool {
    const parser = sectionParserSpecForTitle(title, 3) orelse return false;
    return switch (parser.kind) {
        .pronunciation,
        .relations,
        .citations,
        .notes,
        .navigation,
        .descendants,
        .translations,
        .inflection,
        .meta,
        => true,
        else => false,
    };
}

pub fn isExcludedHeading(title: []const u8, level: u8, exclusions: ExclusionPolicy) bool {
    if (exclusions.exclude_anagrams and headingMatches(title, "Anagrams")) return true;
    if (exclusions.exclude_statistics and headingMatches(title, "Statistics")) return true;
    if (exclusions.exclude_further_reading and headingMatches(title, "Further reading")) return true;

    const parser = sectionParserSpecForTitle(title, level) orelse return false;
    return switch (parser.kind) {
        .citations => exclusions.exclude_citations,
        .meta => exclusions.exclude_meta,
        .translations => exclusions.exclude_translations,
        else => false,
    };
}

pub fn isRecognizedPartOfSpeech(title: []const u8) bool {
    const parser = sectionParserSpecForTitle(title, 3) orelse return false;
    return parser.kind == .part_of_speech;
}

fn headingMatches(title: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, title, " \t"), expected);
}

fn headingStartsWith(title: []const u8, prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, title, " \t");
    return asciiStartsWithIgnoreCase(trimmed, prefix);
}

fn isAlternativeFormsHeading(title: []const u8) bool {
    return headingMatches(title, "Alternative forms") or
        headingMatches(title, "Alternate forms") or
        headingMatches(title, "Alternative spelling") or
        headingMatches(title, "Alternative spellings");
}

fn isEtymologyHeading(title: []const u8) bool {
    return headingMatches(title, "Etymology") or
        isNumberedEtymology(title) or
        headingStartsWith(title, "Etymolog");
}

fn isPronunciationHeading(title: []const u8) bool {
    return headingMatches(title, "Pronunciation") or
        headingStartsWith(title, "Pronunciation ") or
        headingMatches(title, "Homophones");
}

fn isTranslationHeading(title: []const u8) bool {
    return headingMatches(title, "Translations") or
        headingMatches(title, "Translate");
}

fn isDescendantHeading(title: []const u8) bool {
    return headingMatches(title, "Descendants");
}

fn isInflectionHeading(title: []const u8) bool {
    return headingMatches(title, "Conjugation") or
        headingMatches(title, "Declension") or
        headingMatches(title, "Inflection") or
        headingMatches(title, "Mutation");
}

fn isRelationHeading(title: []const u8) bool {
    return headingMatches(title, "Derived terms") or
        headingMatches(title, "Derivations") or
        headingMatches(title, "Related terms") or
        headingMatches(title, "Related forms") or
        headingMatches(title, "Related vocabulary") or
        headingMatches(title, "Synonyms") or
        headingMatches(title, "Near-synonyms") or
        headingMatches(title, "Parasynonyms") or
        headingMatches(title, "Synonyms and related terms") or
        headingMatches(title, "Antonyms") or
        headingMatches(title, "Hypernyms") or
        headingMatches(title, "Hyponyms") or
        headingMatches(title, "Meronyms") or
        headingMatches(title, "Comeronyms") or
        headingMatches(title, "Holonyms") or
        headingMatches(title, "Troponyms") or
        headingMatches(title, "Paronyms") or
        headingMatches(title, "Coordinate terms") or
        headingMatches(title, "Collocations");
}

fn isCitationHeading(title: []const u8) bool {
    return headingMatches(title, "References") or
        headingMatches(title, "Citations") or
        headingMatches(title, "Sources") or
        headingMatches(title, "Source") or
        headingMatches(title, "Further reading") or
        headingMatches(title, "Further information") or
        headingMatches(title, "External links") or
        headingMatches(title, "Links") or
        headingMatches(title, "Quotations");
}

fn isNotesHeading(title: []const u8) bool {
    return headingMatches(title, "Notes") or
        headingMatches(title, "Note") or
        headingMatches(title, "Additional notes") or
        headingMatches(title, "Historical notes") or
        headingMatches(title, "Usage notes") or
        headingMatches(title, "Usage") or
        headingMatches(title, "Pronunciation notes");
}

fn isNavigationHeading(title: []const u8) bool {
    return headingMatches(title, "See also") or
        headingMatches(title, "Anagrams") or
        headingMatches(title, "Statistics") or
        headingMatches(title, "Gallery") or
        headingMatches(title, "Sense overview") or
        headingMatches(title, "Description") or
        headingMatches(title, "Examples") or
        headingMatches(title, "Trivia");
}

fn isPartOfSpeechHeading(title: []const u8) bool {
    return isCorePartOfSpeechHeading(title) or
        headingMatches(title, "Prepositional phrase") or
        headingMatches(title, "Verb phrase") or
        headingMatches(title, "Proper adjective") or
        headingMatches(title, "Proper nouns") or
        headingStartsWith(title, "Proper noun ") or
        headingMatches(title, "Multiple parts of speech") or
        headingMatches(title, "Abbreviations") or
        headingMatches(title, "Number") or
        headingMatches(title, "Punctuation mark") or
        headingMatches(title, "Diacritical mark") or
        headingMatches(title, "Symbols") or
        headingMatches(title, "Combining form") or
        headingMatches(title, "Verb form") or
        headingMatches(title, "Adverbial phrase") or
        headingMatches(title, "Common nouns") or
        headingMatches(title, "Initialisms") or
        headingMatches(title, "Adjectives") or
        headingMatches(title, "Proper");
}

fn isCorePartOfSpeechHeading(title: []const u8) bool {
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
        if (headingMatches(title, candidate)) return true;
    }
    return false;
}

fn isMetaHeading(title: []const u8) bool {
    return headingMatches(title, "Interfix") or
        headingMatches(title, "Attestation") or
        headingMatches(title, "Dialects") or
        headingMatches(title, "Other names") or
        headingMatches(title, "Etymyology");
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
    var emphasis_state: EmphasisState = .{};
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
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            i += 2;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            const end = findBalanced(input, i, "[[", "]]") orelse break;
            var trail_end = end + 2;
            while (trail_end < input.len and isWikiLinkTrailByte(input[trail_end])) : (trail_end += 1) {}
            try renderLink(out, allocator, input[i + 2 .. end], input[end + 2 .. trail_end]);
            i = trail_end;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "]]")) {
            i += 2;
            continue;
        }
        if (input[i] == '[') {
            if (asciiStartsWithIgnoreCase(input[i + 1 ..], "http")) {
                if (findExternalLinkClose(input, i)) |end| {
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
            if (!looksLikeInlineTagStart(input[i..])) {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            }
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
            if (std.mem.indexOfScalarPos(u8, input, i, '>')) |end| {
                i = end + 1;
                continue;
            }
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }
        if (input[i] == '\'' and i + 1 < input.len and input[i + 1] == '\'') {
            const run_start = i;
            while (i < input.len and input[i] == '\'') : (i += 1) {}
            if (emphasis_state.consumeApostropheRun(input, run_start, i - run_start)) {
                try out.append(allocator, '\'');
            }
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
}

const EmphasisState = struct {
    italic_open: bool = false,
    bold_open: bool = false,

    fn consumeApostropheRun(self: *EmphasisState, input: []const u8, run_start: usize, run_len: usize) bool {
        switch (run_len) {
            2 => {
                self.italic_open = !self.italic_open;
                return false;
            },
            3 => {
                if (self.italic_open and !self.bold_open and shouldKeepLiteralApostrophe(input, run_start, run_len)) {
                    self.italic_open = false;
                    return true;
                }
                self.bold_open = !self.bold_open;
                return false;
            },
            5 => {
                self.bold_open = !self.bold_open;
                self.italic_open = !self.italic_open;
                return false;
            },
            else => return shouldKeepLiteralApostrophe(input, run_start, run_len),
        }
    }
};

fn renderLink(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    trail: []const u8,
) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const display = if (parts.items.len >= 2)
        std.mem.trim(u8, parts.items[parts.items.len - 1], " \t")
    else
        "";
    const base_selected = if (display.len != 0)
        display
    else
        normalizedLinkTarget(parts.items[0]);
    const selected = if (trail.len == 0)
        base_selected
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_selected, trail });
    defer if (trail.len != 0) allocator.free(selected);
    if (selected.len == 0) return;
    try renderInline(out, allocator, selected);
}

fn shouldKeepLiteralApostrophe(input: []const u8, run_start: usize, run_len: usize) bool {
    if ((run_len & 1) == 0) return false;
    if (run_start == 0 or run_start + run_len >= input.len) return false;
    return isLiteralApostropheNeighbor(input[run_start - 1]) and isLiteralApostropheNeighbor(input[run_start + run_len]);
}

fn isLiteralApostropheNeighbor(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte);
}

fn isWikiLinkTrailByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte);
}

fn renderTemplate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const name = std.mem.trim(u8, parts.items[0], " \t");

    if (templateMatches(name, "also") or templateMatches(name, "wikipedia") or templateMatches(name, "slim-wikipedia") or templateMatches(name, "minitoc") or templateMatches(name, "wikidata lexeme") or templateMatches(name, "trans-see") or templateMatches(name, "senseid") or templateMatches(name, "etymid") or templateMatches(name, "picdic") or templateMatches(name, "elements") or templateMatches(name, "ref") or templateMatches(name, "see also") or templateMatches(name, "catlangname") or templateMatches(name, "ctRenderF") or templateMatches(name, "construed with") or templateMatches(name, "in appendix") or templateMatches(name, "pseudo-loan") or templateMatches(name, "Webster 1913")) {
        return;
    }

    if (templateMatches(name, "season name spelling")) {
        try appendWithSpace(out, allocator, "Note that season names are not capitalized in modern English except where any noun would be capitalized, e.g. at the beginning of a sentence or as part of a name (Old Man Winter, the Winter War, Summer Glau). This is in contrast to the days of the week and months of the year, which are always capitalized (Thursday or September).");
        return;
    }

    if (templateMatches(name, "lb") or templateMatches(name, "lbl") or templateMatches(name, "label")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "qualifier") or templateMatches(name, "q") or templateMatches(name, "q-lite")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "i")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "small")) {
        try appendPositional(out, allocator, &parts, 0, "", "", " ");
        return;
    }
    if (templateMatches(name, "nbsp")) {
        try appendWithSpace(out, allocator, " ");
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
    if (asciiStartsWithIgnoreCase(name, "quote-") or std.mem.startsWith(u8, name, "RQ:")) {
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
            defer allocator.free(rendered);
            if (rendered.len != 0) {
                try appendWithSpace(out, allocator, " (");
                try appendWithSpace(out, allocator, rendered);
                try appendWithSpace(out, allocator, ")");
            }
        }
        return;
    }
    if (templateMatches(name, "lang")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "place")) {
        try appendPlaceTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "given name")) {
        try appendNominalTemplate(out, allocator, &parts, "given name");
        return;
    }
    if (templateMatches(name, "surname")) {
        try appendNominalTemplate(out, allocator, &parts, "surname");
        return;
    }
    if (templateMatches(name, "learned borrowing") or
        templateMatches(name, "bor") or
        templateMatches(name, "bor+") or
        templateMatches(name, "ubor") or
        templateMatches(name, "inh") or
        templateMatches(name, "inh+") or
        templateMatches(name, "der") or
        templateMatches(name, "der+"))
    {
        try renderEtymologyLexemeTemplate(out, allocator, name, &parts);
        return;
    }
    if (templateMatches(name, "&lit")) {
        try appendWithSpace(out, allocator, "Used other than figuratively or idiomatically: see ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "clip of")) {
        try renderUnaryTemplate(out, allocator, &parts, "clipping of");
        return;
    }
    if (isSemanticOfTemplate(name)) {
        try renderSemanticOfTemplate(out, allocator, name, &parts);
        return;
    }
    if (templateMatches(name, "head")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| {
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
    if (templateMatches(name, "compound+")) {
        try appendWithSpace(out, allocator, "Compound of ");
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "prefix") or
        templateMatches(name, "pre") or
        templateMatches(name, "suffix") or
        templateMatches(name, "suf") or
        templateMatches(name, "af") or
        templateMatches(name, "com") or
        templateMatches(name, "affix") or
        templateMatches(name, "confix"))
    {
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "blend")) {
        try renderBlendTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "clipping") or templateMatches(name, "clip of")) {
        try renderUnaryTemplate(out, allocator, &parts, "clipping of");
        return;
    }
    if (templateMatches(name, "back-form")) {
        try renderUnaryTemplate(out, allocator, &parts, "back-formation from");
        return;
    }
    if (templateMatches(name, "B.C.E.") or templateMatches(name, "C.E.")) {
        try appendWithSpace(out, allocator, name);
        return;
    }
    if (templateMatches(name, "U") or asciiStartsWithIgnoreCase(name, "U:")) {
        if (usageTemplateDisplayValue(name, &parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "only used in")) {
        try appendWithSpace(out, allocator, "Only used in ");
        try appendPositional(out, allocator, &parts, semanticTemplateTargetIndex(&parts), "", "", ", ");
        try appendWithSpace(out, allocator, ".");
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
    if (templateMatches(name, "alt form")) {
        try appendWithSpace(out, allocator, "alternative form of ");
        if (templateAliasTarget(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "dated form")) {
        try renderUnaryTemplate(out, allocator, &parts, "dated form of");
        return;
    }
    if (templateMatches(name, "alt case form")) {
        try renderUnaryTemplate(out, allocator, &parts, "alternative case form of");
        return;
    }
    if (templateMatches(name, "aphetic form")) {
        try renderUnaryTemplate(out, allocator, &parts, "aphetic form of");
        return;
    }
    if (templateMatches(name, "partial calque")) {
        try renderUnaryTemplate(out, allocator, &parts, "partial calque of");
        return;
    }
    if (templateMatches(name, "near-synonyms")) {
        try appendWithSpace(out, allocator, "Near synonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "onom") or templateMatches(name, "onomatopoeic")) {
        try appendWithSpace(out, allocator, "Onomatopoeic");
        return;
    }
    if (templateMatches(name, "initialism")) {
        try renderUnaryTemplate(out, allocator, &parts, "initialism of");
        return;
    }
    if (templateMatches(name, "hol")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |arg| try renderInline(out, allocator, stripTraversalSegments(arg));
        return;
    }
    if (templateMatches(name, "ng")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "circa2")) {
        if (templatePositional(&parts, 0)) |year| {
            try appendWithSpace(out, allocator, "c. ");
            try renderInline(out, allocator, year);
        }
        return;
    }
    if (templatePositional(&parts, positionalCount(&parts) -| 1)) |fallback| {
        try renderInline(out, allocator, fallback);
    }
}

fn looksLikeInlineTagStart(input: []const u8) bool {
    if (input.len < 2 or input[0] != '<') return false;
    const next = input[1];
    return next == '!' or next == '/' or std.ascii.isAlphabetic(next);
}

fn templateLexeme(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, if (positionalCount(parts) >= 2) 1 else 0);
}

fn usageTemplateTarget(name: []const u8, parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const trimmed_name = std.mem.trim(u8, name, " \t");
    if (asciiStartsWithIgnoreCase(trimmed_name, "U:")) {
        var target = trimmed_name["U:".len..];
        if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
            const prefix = std.mem.trim(u8, target[0..colon], " \t");
            if (looksLikeLanguageCode(prefix)) {
                target = target[colon + 1 ..];
            }
        }
        const trimmed_target = std.mem.trim(u8, target, " \t");
        return if (trimmed_target.len == 0) null else trimmed_target;
    }

    if (templatePositional(parts, 0)) |first| {
        const trimmed_first = std.mem.trim(u8, first, " \t");
        if (trimmed_first.len != 0 and !looksLikeLanguageCode(trimmed_first)) return trimmed_first;
    }
    if (templatePositional(parts, 1)) |second| {
        const trimmed_second = std.mem.trim(u8, second, " \t");
        if (trimmed_second.len != 0) return trimmed_second;
    }
    if (templatePositional(parts, 0)) |first| {
        const trimmed_first = std.mem.trim(u8, first, " \t");
        if (trimmed_first.len != 0) return trimmed_first;
    }
    return null;
}

fn usageTemplateDisplayValue(name: []const u8, parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const target = usageTemplateTarget(name, parts) orelse return null;
    return knownUsageTemplateExpansion(target) orelse target;
}

fn knownUsageTemplateExpansion(target: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, target, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed, "I-P")) {
        return "The use of Israel to refer to the region between the Jordan River and the Mediterranean Sea in a non-historical sense is (since the latter half of the 20th century) politically charged; indeed, this is true of all terms for this region.";
    }
    return null;
}

fn templateEtymologyTerm(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, 2) orelse
        templatePositional(parts, 1) orelse
        templatePositional(parts, 0);
}

fn renderEtymologyLexemeTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    if (templateMatches(name, "bor") or templateMatches(name, "bor+")) {
        try appendWithSpace(out, allocator, "borrowed from ");
    } else if (templateMatches(name, "ubor")) {
        try appendWithSpace(out, allocator, "Unadapted borrowing from ");
    } else if (templateMatches(name, "learned borrowing")) {
        try appendWithSpace(out, allocator, "learned borrowing from ");
    } else if (templateMatches(name, "inh") or templateMatches(name, "inh+")) {
        try appendWithSpace(out, allocator, "inherited from ");
    } else if (templateMatches(name, "der") or templateMatches(name, "der+")) {
        try appendWithSpace(out, allocator, "derived from ");
    }

    if (templatePositional(parts, 1)) |code| {
        if (languageDisplay(code)) |display| {
            try appendWithSpace(out, allocator, display);
            if (templateEtymologyTerm(parts)) |term| {
                if (!looksLikeLanguageCode(std.mem.trim(u8, term, " \t"))) try appendWithSpace(out, allocator, " ");
            }
        }
    }

    if (templateEtymologyTerm(parts)) |arg| {
        try renderInline(out, allocator, arg);
        if (templateNamed(parts, "t") orelse templateNamed(parts, "gloss")) |gloss| {
            try appendWithSpace(out, allocator, " (");
            try renderInline(out, allocator, gloss);
            try appendWithSpace(out, allocator, ")");
        }
        if (templateNamed(parts, "lit")) |literal| {
            try appendWithSpace(out, allocator, " (literally \"");
            try renderInline(out, allocator, literal);
            try appendWithSpace(out, allocator, "\")");
        }
    }
}

fn renderSemanticOfTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    if (templateMatches(name, "infl of") or templateMatches(name, "inflection of")) {
        if (try renderInflectionTemplate(out, allocator, parts)) return;
    }

    try appendWithSpace(out, allocator, std.mem.trim(u8, name, " \t"));

    const target_index = semanticTemplateTargetIndex(parts);
    if (templatePositional(parts, target_index)) |arg| {
        try appendWithSpace(out, allocator, " ");
        try renderInline(out, allocator, arg);
    }

    const positional_total = positionalCount(parts);
    var extra_index = target_index + 1;
    var wrote_extra = false;
    while (extra_index < positional_total) : (extra_index += 1) {
        const extra = templatePositional(parts, extra_index) orelse continue;
        const trimmed = std.mem.trim(u8, extra, " \t");
        if (trimmed.len == 0 or looksLikeLanguageCode(trimmed)) continue;

        if (!wrote_extra) {
            try appendWithSpace(out, allocator, " (");
            wrote_extra = true;
        } else {
            try appendWithSpace(out, allocator, ", ");
        }
        try renderInline(out, allocator, trimmed);
    }
    if (wrote_extra) try appendWithSpace(out, allocator, ")");
    if (templatePositional(parts, target_index)) |arg| {
        const gloss = templateNamed(parts, "t") orelse templateNamed(parts, "gloss") orelse templateTrailingGloss(parts, arg);
        if (gloss) |value| {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len != 0 and !std.mem.eql(u8, trimmed, std.mem.trim(u8, arg, " \t"))) {
                try appendWithSpace(out, allocator, " (");
                try renderInline(out, allocator, trimmed);
                try appendWithSpace(out, allocator, ")");
            }
        }
    }
}

fn renderInflectionTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!bool {
    const target_index = semanticTemplateTargetIndex(parts);
    const target = templatePositional(parts, target_index) orelse return false;

    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);

    var extra_index = target_index + 1;
    while (extra_index < positionalCount(parts)) : (extra_index += 1) {
        const extra = templatePositional(parts, extra_index) orelse continue;
        const trimmed = std.mem.trim(u8, extra, " \t");
        if (trimmed.len == 0 or (looksLikeLanguageCode(trimmed) and !isRecognizedInflectionTag(trimmed))) continue;
        try tags.append(allocator, trimmed);
    }

    const phrase = formatInflectionTags(tags.items) orelse return false;
    try appendWithSpace(out, allocator, phrase);
    try appendWithSpace(out, allocator, " of ");
    try renderInline(out, allocator, target);
    return true;
}

fn formatInflectionTags(tags: []const []const u8) ?[]const u8 {
    if (sameTagSet(tags, &.{ "1", "s", "simple", "pres" })) return "first-person singular simple present";
    if (sameTagSet(tags, &.{ "1", "p", "simple", "pres" })) return "first-person plural simple present";
    if (sameTagSet(tags, &.{ "2", "s", "simple", "pres" })) return "second-person singular simple present";
    if (sameTagSet(tags, &.{ "2", "p", "simple", "pres" })) return "second-person plural simple present";
    if (sameTagSet(tags, &.{ "3", "s", "simple", "pres" })) return "third-person singular simple present";
    if (sameTagSet(tags, &.{ "3", "p", "simple", "pres" })) return "third-person plural simple present";
    if (tags.len == 1) {
        if (std.ascii.eqlIgnoreCase(tags[0], "pres")) return "present tense";
        if (std.ascii.eqlIgnoreCase(tags[0], "s-verb-form")) return "third-person singular simple present indicative";
        if (std.ascii.eqlIgnoreCase(tags[0], "spast")) return "simple past";
        if (std.ascii.eqlIgnoreCase(tags[0], "ed-form")) return "simple past and past participle";
        if (std.ascii.eqlIgnoreCase(tags[0], "ing-form")) return "present participle and gerund";
    }
    return null;
}

fn isRecognizedInflectionTag(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "s-verb-form") or
        std.ascii.eqlIgnoreCase(tag, "1") or
        std.ascii.eqlIgnoreCase(tag, "2") or
        std.ascii.eqlIgnoreCase(tag, "3") or
        std.ascii.eqlIgnoreCase(tag, "p") or
        std.ascii.eqlIgnoreCase(tag, "pres") or
        std.ascii.eqlIgnoreCase(tag, "s") or
        std.ascii.eqlIgnoreCase(tag, "simple") or
        std.ascii.eqlIgnoreCase(tag, "spast") or
        std.ascii.eqlIgnoreCase(tag, "ed-form") or
        std.ascii.eqlIgnoreCase(tag, "ing-form");
}

fn sameTagSet(tags: []const []const u8, expected: []const []const u8) bool {
    if (tags.len != expected.len) return false;
    for (expected) |candidate| {
        var found = false;
        for (tags) |tag| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tag, " \t"), candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn renderUnaryTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    prefix: []const u8,
) std.mem.Allocator.Error!void {
    const target_index = semanticTemplateTargetIndex(parts);
    const target = templatePositional(parts, target_index);
    if (target == null or (positionalCount(parts) <= 1 and looksLikeLanguageCode(std.mem.trim(u8, target.?, " \t")))) {
        try appendWithSpace(out, allocator, if (std.ascii.eqlIgnoreCase(prefix, "clipping of")) "clipping" else prefix);
        return;
    }
    try appendWithSpace(out, allocator, prefix);
    if (target) |arg| {
        try appendWithSpace(out, allocator, " ");
        try renderInline(out, allocator, arg);
    }
    const positional_total = positionalCount(parts);
    var extra_index = target_index + 1;
    var wrote_extra = false;
    while (extra_index < positional_total) : (extra_index += 1) {
        const extra = templatePositional(parts, extra_index) orelse continue;
        const trimmed_extra = std.mem.trim(u8, extra, " \t");
        if (trimmed_extra.len == 0 or looksLikeLanguageCode(trimmed_extra)) continue;

        if (!wrote_extra) {
            try appendWithSpace(out, allocator, " (");
            wrote_extra = true;
        } else {
            try appendWithSpace(out, allocator, ", ");
        }
        try renderInline(out, allocator, trimmed_extra);
    }
    if (wrote_extra) try appendWithSpace(out, allocator, ")");
    if (target) |arg| {
        const gloss = templateNamed(parts, "t") orelse templateNamed(parts, "gloss") orelse templateTrailingGloss(parts, arg);
        if (gloss) |value| {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len != 0 and !std.mem.eql(u8, trimmed, std.mem.trim(u8, arg, " \t"))) {
                try appendWithSpace(out, allocator, " (");
                try renderInline(out, allocator, trimmed);
                try appendWithSpace(out, allocator, ")");
            }
        }
    }
}

fn renderBlendTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, "blend of ");
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, " and ");
        try renderInline(out, allocator, segment);
        wrote_any = true;
        positional_index += 1;
    }
}

fn appendPlaceTerms(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const type_index = placeTypeIndex(parts);
    const raw_type = templatePositional(parts, type_index) orelse return;
    const abbreviation_target = placeAbbreviationTarget(raw_type);
    const actual_type_index = if (abbreviation_target != null and templatePositional(parts, type_index + 1) != null) type_index + 1 else type_index;
    const actual_raw_type = templatePositional(parts, actual_type_index) orelse raw_type;
    const rendered_type = try renderPlaceTypeTextAlloc(allocator, actual_raw_type);
    defer allocator.free(rendered_type);
    if (rendered_type.len == 0) return;

    if (abbreviation_target) |target| {
        try out.appendSlice(allocator, "Abbreviation of ");
        try renderInline(out, allocator, target);
        try out.appendSlice(allocator, ": ");
        if (placeTypeNeedsArticle(rendered_type)) {
            try out.appendSlice(allocator, chooseIndefiniteArticle(rendered_type, false));
            try out.appendSlice(allocator, " ");
        }
    } else if (placeTypeNeedsArticle(rendered_type)) {
        try out.appendSlice(allocator, chooseIndefiniteArticle(rendered_type, true));
        try out.appendSlice(allocator, " ");
    }
    try out.appendSlice(allocator, rendered_type);

    var wrote_location = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index <= actual_type_index) {
            positional_index += 1;
            continue;
        }
        const piece = std.mem.trim(u8, stripTraversalSegments(segment), " \t");
        if (piece.len == 0) {
            positional_index += 1;
            continue;
        }
        if (!wrote_location) {
            try out.appendSlice(allocator, if (abbreviation_target != null) " of " else if (asciiEndsWithIgnoreCase(rendered_type, " seat")) " of " else if (placeTypeNeedsIn(rendered_type)) " in " else " ");
            wrote_location = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try appendPlaceLocationFragment(out, allocator, piece);
        positional_index += 1;
    }

    for ([_][]const u8{ "official", "capital", "located", "located in", "caplc" }) |key| {
        if (templateNamed(parts, key)) |value| {
            const piece = normalizePlaceFragment(value);
            if (piece.len == 0) continue;
            if (wrote_location) {
                try out.appendSlice(allocator, "; ");
            } else {
                try out.appendSlice(allocator, " ");
            }
            try renderInline(out, allocator, piece);
            wrote_location = true;
        }
    }
}

fn placeAbbreviationTarget(raw_type: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stripTraversalSegments(raw_type), " \t");
    if (!asciiStartsWithIgnoreCase(trimmed, "@abbrev of:")) return null;
    return std.mem.trim(u8, trimmed["@abbrev of:".len..], " \t");
}

fn appendNominalTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    noun: []const u8,
) std.mem.Allocator.Error!void {
    var phrase: std.ArrayList(u8) = .empty;
    defer phrase.deinit(allocator);

    const qualifier = blk: {
        if (templatePositional(parts, 0)) |first| {
            if (looksLikeLanguageCode(std.mem.trim(u8, first, " \t"))) {
                break :blk templatePositional(parts, 1);
            }
            break :blk first;
        }
        break :blk templatePositional(parts, 1);
    };
    if (qualifier) |value| {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len != 0) {
            try renderInline(&phrase, allocator, trimmed);
            if (phrase.items.len != 0) try phrase.append(allocator, ' ');
        }
    }
    try phrase.appendSlice(allocator, noun);

    try out.appendSlice(allocator, chooseIndefiniteArticle(phrase.items, true));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, phrase.items);
    if (templateNamed(parts, "addl")) |value| {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, ", ");
            try renderInline(out, allocator, trimmed);
        }
    }
}

fn semanticTemplateTargetIndex(parts: *const std.ArrayList([]const u8)) usize {
    const count = positionalCount(parts);
    if (count <= 1) return 0;
    const first = templatePositional(parts, 0) orelse return 0;
    return if (looksLikeLanguageCode(first)) 1 else 0;
}

fn isSemanticOfTemplate(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    return trimmed.len != 0 and asciiEndsWithIgnoreCase(trimmed, " of");
}

fn looksLikeLanguageCode(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed.len > 12) return false;

    var has_letter = false;
    for (trimmed) |char| {
        if (std.ascii.isAlphabetic(char)) {
            has_letter = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '-' or char == '_') continue;
        return false;
    }
    return has_letter;
}

fn normalizePlaceFragment(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, stripTraversalSegments(input), " \t");
    if (trimmed.len == 0) return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        const prefix = std.mem.trim(u8, trimmed[0..slash], " \t");
        if (prefix.len <= 8 and std.mem.indexOfScalar(u8, prefix, ' ') == null) {
            return std.mem.trim(u8, trimmed[slash + 1 ..], " \t");
        }
    }
    return trimmed;
}

fn appendPlaceLocationFragment(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!void {
    if (std.mem.indexOfScalar(u8, input, '/')) |slash| {
        const prefix = std.mem.trim(u8, input[0..slash], " \t");
        const value = std.mem.trim(u8, input[slash + 1 ..], " \t");
        if (value.len == 0) return;
        const resolved_value = placeLocationDisplayValue(prefix, value);
        const display = placeHolonymDisplay(prefix);
        switch (display.kind) {
            .plain => try renderInline(out, allocator, resolved_value),
            .prefix => {
                try appendPlaceHolonymPrefix(out, allocator, display.label);
                try renderInline(out, allocator, resolved_value);
            },
            .suffix => {
                try renderInline(out, allocator, resolved_value);
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, display.label);
            },
        }
        return;
    }
    try renderInline(out, allocator, input);
}

fn renderPlaceTypeTextAlloc(
    allocator: std.mem.Allocator,
    raw_type: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const trimmed = std.mem.trim(u8, stripTraversalSegments(raw_type), " \t");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, trimmed, '/') == null) {
        return renderWikitextToOwned(allocator, trimmed, std.math.maxInt(usize));
    }

    var parts = try splitTopLevel(allocator, trimmed, '/');
    defer parts.deinit(allocator);

    if (parts.items.len == 2) {
        const first = std.mem.trim(u8, parts.items[0], " \t");
        const second = std.mem.trim(u8, parts.items[1], " \t");
        const canonical_second = canonicalPlaceHolonymType(second) orelse second;
        if (std.ascii.eqlIgnoreCase(canonical_second, "capital city") or std.ascii.eqlIgnoreCase(canonical_second, "county seat")) {
            const rendered_first = try renderWikitextToOwned(allocator, canonicalPlaceHolonymType(first) orelse first, std.math.maxInt(usize));
            defer allocator.free(rendered_first);
            const rendered_second = try renderWikitextToOwned(allocator, canonical_second, std.math.maxInt(usize));
            defer allocator.free(rendered_second);
            if (rendered_first.len != 0 and rendered_second.len != 0) {
                return std.fmt.allocPrint(allocator, "{s}, the {s}", .{ rendered_first, rendered_second });
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var prev_was_connector = false;
    var wrote_any = false;
    for (parts.items) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) continue;

        const token = canonicalPlaceHolonymType(segment) orelse segment;
        const rendered = try renderWikitextToOwned(allocator, token, std.math.maxInt(usize));
        defer allocator.free(rendered);
        if (rendered.len == 0) continue;

        const is_connector = isPlaceTypeConnector(rendered);
        if (wrote_any) {
            try out.appendSlice(allocator, if (prev_was_connector or is_connector) " " else " and ");
        }
        try out.appendSlice(allocator, rendered);
        wrote_any = true;
        prev_was_connector = is_connector;
    }
    return out.toOwnedSlice(allocator);
}

const PlaceHolonymDisplayKind = enum {
    plain,
    prefix,
    suffix,
};

const PlaceHolonymDisplay = struct {
    kind: PlaceHolonymDisplayKind = .plain,
    label: []const u8 = "",
};

fn placeHolonymDisplay(prefix: []const u8) PlaceHolonymDisplay {
    const canonical = canonicalPlaceHolonymType(prefix) orelse return .{};

    if (std.ascii.eqlIgnoreCase(canonical, "metropolitan borough") or
        std.ascii.eqlIgnoreCase(canonical, "London borough") or
        std.ascii.eqlIgnoreCase(canonical, "royal borough") or
        std.ascii.eqlIgnoreCase(canonical, "metropolitan city"))
    {
        return .{ .kind = .prefix, .label = canonical };
    }

    if (std.ascii.eqlIgnoreCase(canonical, "borough") or
        std.ascii.eqlIgnoreCase(canonical, "county borough") or
        std.ascii.eqlIgnoreCase(canonical, "parish") or
        std.ascii.eqlIgnoreCase(canonical, "civil parish") or
        std.mem.endsWith(u8, canonical, " district") or
        std.ascii.eqlIgnoreCase(canonical, "district"))
    {
        return .{ .kind = .suffix, .label = canonical };
    }

    return .{};
}

fn canonicalPlaceHolonymType(prefix: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, prefix, " \t");
    inline for ([_]struct { alias: []const u8, canonical: []const u8 }{
        .{ .alias = "bor", .canonical = "borough" },
        .{ .alias = "borough", .canonical = "borough" },
        .{ .alias = "cobor", .canonical = "county borough" },
        .{ .alias = "county borough", .canonical = "county borough" },
        .{ .alias = "cpar", .canonical = "civil parish" },
        .{ .alias = "civil parish", .canonical = "civil parish" },
        .{ .alias = "dist", .canonical = "district" },
        .{ .alias = "district", .canonical = "district" },
        .{ .alias = "lgd", .canonical = "local government district" },
        .{ .alias = "lgdist", .canonical = "local government district" },
        .{ .alias = "local government district", .canonical = "local government district" },
        .{ .alias = "lbor", .canonical = "London borough" },
        .{ .alias = "London borough", .canonical = "London borough" },
        .{ .alias = "metbor", .canonical = "metropolitan borough" },
        .{ .alias = "metropolitan borough", .canonical = "metropolitan borough" },
        .{ .alias = "metcity", .canonical = "metropolitan city" },
        .{ .alias = "metropolitan city", .canonical = "metropolitan city" },
        .{ .alias = "par", .canonical = "parish" },
        .{ .alias = "parish", .canonical = "parish" },
        .{ .alias = "rdist", .canonical = "regional district" },
        .{ .alias = "regional district", .canonical = "regional district" },
        .{ .alias = "robor", .canonical = "royal borough" },
        .{ .alias = "royal borough", .canonical = "royal borough" },
        .{ .alias = "subdistrict", .canonical = "subdistrict" },
        .{ .alias = "udist", .canonical = "unitary district" },
        .{ .alias = "unitary district", .canonical = "unitary district" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.alias)) return entry.canonical;
    }
    return null;
}

fn isPlaceTypeConnector(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    inline for ([_][]const u8{
        "and",
        "or",
        "of",
        "for",
        "in",
        "on",
        "near",
        "with",
        "without",
        "from",
        "to",
        "the",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

fn appendPlaceHolonymPrefix(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
) std.mem.Allocator.Error!void {
    const titled = try titleCaseAsciiAlloc(allocator, label);
    defer allocator.free(titled);
    try out.appendSlice(allocator, "the ");
    try out.appendSlice(allocator, titled);
    try out.appendSlice(allocator, " of ");
}

fn placeLocationDisplayValue(prefix: []const u8, value: []const u8) []const u8 {
    const trimmed_prefix = std.mem.trim(u8, prefix, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed_prefix, "c") or std.ascii.eqlIgnoreCase(trimmed_prefix, "cc")) {
        if (std.ascii.eqlIgnoreCase(value, "US") or std.ascii.eqlIgnoreCase(value, "U.S.") or std.ascii.eqlIgnoreCase(value, "USA") or std.ascii.eqlIgnoreCase(value, "U.S.A.")) return "United States";
        if (std.ascii.eqlIgnoreCase(value, "UK") or std.ascii.eqlIgnoreCase(value, "U.K.")) return "United Kingdom";
    }
    return value;
}

fn placeTypeIndex(parts: *const std.ArrayList([]const u8)) usize {
    if (positionalCount(parts) <= 1) return 0;
    const first = templatePositional(parts, 0) orelse return 0;
    return if (looksLikeLanguageCode(first)) 1 else 0;
}

fn placeTypeNeedsIn(rendered_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, rendered_type, " \t");
    return !asciiEndsWithIgnoreCase(trimmed, " in") and
        !asciiEndsWithIgnoreCase(trimmed, " of") and
        !asciiEndsWithIgnoreCase(trimmed, " on") and
        !asciiEndsWithIgnoreCase(trimmed, " at");
}

fn placeTypeNeedsArticle(rendered_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, rendered_type, " \t");
    if (trimmed.len == 0) return false;
    inline for ([_][]const u8{
        "a ",
        "an ",
        "the ",
        "this ",
        "that ",
        "these ",
        "those ",
        "one ",
    }) |prefix| {
        if (asciiStartsWithIgnoreCase(trimmed, prefix)) return false;
    }
    return true;
}

fn chooseIndefiniteArticle(text: []const u8, capitalize: bool) []const u8 {
    const article = if (startsWithVowelSound(text)) "an" else "a";
    if (!capitalize) return article;
    return if (article[0] == 'a' and article.len == 2) "An" else "A";
}

fn startsWithVowelSound(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return false;

    var index: usize = 0;
    while (index < trimmed.len and !std.ascii.isAlphabetic(trimmed[index])) : (index += 1) {}
    if (index >= trimmed.len) return false;

    return switch (std.ascii.toLower(trimmed[index])) {
        'a', 'e', 'i', 'o', 'u' => true,
        else => false,
    };
}

fn normalizedLinkTarget(raw_target: []const u8) []const u8 {
    var target = std.mem.trim(u8, raw_target, " \t");
    if (target.len != 0 and target[0] == ':') target = std.mem.trim(u8, target[1..], " \t");

    if (std.mem.indexOfScalar(u8, target, '#')) |hash_index| {
        target = if (hash_index == 0)
            target[1..]
        else
            target[0..hash_index];
    }

    if (isHiddenNamespaceTarget(target)) return "";
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon_index| {
        if (colon_index + 1 < target.len) target = target[colon_index + 1 ..];
    }
    return std.mem.trim(u8, target, " \t");
}

fn isHiddenNamespaceTarget(target: []const u8) bool {
    const colon_index = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    const namespace = std.mem.trim(u8, target[0..colon_index], " \t");
    return std.ascii.eqlIgnoreCase(namespace, "File") or
        std.ascii.eqlIgnoreCase(namespace, "Image");
}

fn stripTraversalSegments(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '>')) |marker| {
        if (marker + 1 < trimmed.len) return std.mem.trim(u8, trimmed[marker + 1 ..], " \t");
    }
    return trimmed;
}

fn isCanonicalTargetTemplate(name: []const u8) bool {
    if (isAliasTemplate(name)) return true;

    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return false;

    if (templateMatches(trimmed, "inflection of") or templateMatches(trimmed, "infl of")) return true;
    if (asciiEndsWithIgnoreCase(trimmed, " form of") or
        asciiEndsWithIgnoreCase(trimmed, " spelling of") or
        asciiEndsWithIgnoreCase(trimmed, " variant of") or
        asciiEndsWithIgnoreCase(trimmed, " romanization of") or
        asciiEndsWithIgnoreCase(trimmed, " typography of") or
        asciiEndsWithIgnoreCase(trimmed, " orthography of"))
    {
        return true;
    }
    if (!asciiEndsWithIgnoreCase(trimmed, " of")) return false;

    const stem = std.mem.trim(u8, trimmed[0 .. trimmed.len - " of".len], " \t");
    return canonicalStemNeedsFormSuffix(stem) or canonicalStemIsDirectVariant(stem);
}

fn extractCanonicalTargetsFromDefinition(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    definition: []const u8,
) !CanonicalTargetMatch {
    var i: usize = 0;
    var match: CanonicalTargetMatch = .{};
    errdefer match.deinit(allocator);
    while (i + 2 <= definition.len) {
        if (!std.mem.eql(u8, definition[i .. i + 2], "{{")) {
            i += 1;
            continue;
        }
        const end = findBalanced(definition, i, "{{", "}}") orelse break;
        const body = definition[i + 2 .. end];
        var parts = try splitTopLevel(allocator, body, '|');
        defer parts.deinit(allocator);
        if (parts.items.len != 0 and isCanonicalTargetTemplate(parts.items[0])) {
            if (templateAliasTarget(&parts)) |target_raw| {
                const target = try renderWikitextToOwned(allocator, target_raw, 256);
                defer allocator.free(target);
                try addUniqueTerm(out, allocator, target);
                match.found = true;
                if (match.hint_label == null) {
                    match.hint_label = try canonicalHintLabelAlloc(allocator, parts.items[0]);
                }
            }
        }
        i = end + 2;
    }
    return match;
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
                        defer allocator.free(rendered);
                        try pushRenderedTerms(out, allocator, rendered);
                    }
                } else if (isColumnTemplate(name)) {
                    const count = positionalCount(&parts);
                    var pos_index: usize = 1;
                    while (pos_index < count) : (pos_index += 1) {
                        if (templatePositional(&parts, pos_index)) |raw| {
                            const rendered = try renderWikitextToOwned(allocator, raw, 256);
                            defer allocator.free(rendered);
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
            defer allocator.free(rendered);
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

fn appendAffixTerms(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, " + ");
        try renderInline(out, allocator, segment);
        wrote_any = true;
        positional_index += 1;
    }
}

fn templateMatches(name: []const u8, expected: []const u8) bool {
    const actual = std.mem.trim(u8, name, " \t");
    const target = std.mem.trim(u8, expected, " \t");

    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
        while (j < target.len and isTemplateNameSpaceByte(target[j])) : (j += 1) {}
        if (i == actual.len or j == target.len) break;
        if (std.ascii.toLower(actual[i]) != std.ascii.toLower(target[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
    while (j < target.len and isTemplateNameSpaceByte(target[j])) : (j += 1) {}
    return i == actual.len and j == target.len;
}

fn isTemplateNameSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_';
}

fn findExternalLinkClose(input: []const u8, start: usize) ?usize {
    if (start >= input.len or input[start] != '[' or start + 1 >= input.len) return null;
    if (!asciiStartsWithIgnoreCase(input[start + 1 ..], "http")) return null;

    var templates: usize = 0;
    var links: usize = 0;
    var i = start + 1;
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
        if (input[i] == ']' and templates == 0 and links == 0) return i;
    }
    return null;
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

fn templateTrailingGloss(parts: *const std.ArrayList([]const u8), term: []const u8) ?[]const u8 {
    const count = positionalCount(parts);
    if (count <= 2) return null;
    const candidate = templatePositional(parts, count - 1) orelse return null;
    const trimmed = std.mem.trim(u8, candidate, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, std.mem.trim(u8, term, " \t")) or looksLikeLanguageCode(trimmed)) return null;
    return trimmed;
}

fn positionalCount(parts: *const std.ArrayList([]const u8)) usize {
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        if (!templateArgHasName(segment) or templateArgNumericIndex(segment) != null) count += 1;
    }
    return count;
}

fn templatePositional(parts: *const std.ArrayList([]const u8), target: usize) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) {
            if (templateArgNumericIndex(segment)) |numeric_index| {
                if (numeric_index == target) return templateArgNamedValue(segment);
            }
            continue;
        }
        if (positional_index == target) return std.mem.trim(u8, segment, " \t");
        positional_index += 1;
    }
    return null;
}

fn templateArgNumericIndex(segment: []const u8) ?usize {
    const equals = topLevelEquals(segment) orelse return null;
    const key = std.mem.trim(u8, segment[0..equals], " \t");
    if (key.len == 0) return null;
    for (key) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const one_based = std.fmt.parseInt(usize, key, 10) catch return null;
    return if (one_based == 0) null else one_based - 1;
}

fn templateArgNamedValue(segment: []const u8) ?[]const u8 {
    const equals = topLevelEquals(segment) orelse return null;
    return std.mem.trim(u8, segment[equals + 1 ..], " \t");
}

fn isLexicalTemplate(name: []const u8) bool {
    return templateMatches(name, "l") or templateMatches(name, "m") or templateMatches(name, "m+") or templateMatches(name, "link") or templateMatches(name, "cog") or templateMatches(name, "cognate") or templateMatches(name, "noncog") or templateMatches(name, "inh") or templateMatches(name, "der") or templateMatches(name, "bor") or templateMatches(name, "af") or templateMatches(name, "doublet");
}

fn languageDisplay(code: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, code, " \t");
    inline for ([_]struct { code: []const u8, display: []const u8 }{
        .{ .code = "am", .display = "Amharic" },
        .{ .code = "ang", .display = "Old English" },
        .{ .code = "cmn", .display = "Mandarin" },
        .{ .code = "de", .display = "German" },
        .{ .code = "en", .display = "English" },
        .{ .code = "enm", .display = "Middle English" },
        .{ .code = "fa-cls", .display = "Classical Persian" },
        .{ .code = "fr", .display = "French" },
        .{ .code = "fy", .display = "West Frisian" },
        .{ .code = "gem-pro", .display = "Proto-Germanic" },
        .{ .code = "gmq", .display = "North Germanic" },
        .{ .code = "gmw-pro", .display = "Proto-West Germanic" },
        .{ .code = "ine-pro", .display = "Proto-Indo-European" },
        .{ .code = "ko", .display = "Korean" },
        .{ .code = "la", .display = "Latin" },
        .{ .code = "nan-hbl", .display = "Hokkien" },
        .{ .code = "nl", .display = "Dutch" },
        .{ .code = "no", .display = "Norwegian" },
        .{ .code = "ota", .display = "Ottoman Turkish" },
        .{ .code = "sga", .display = "Old Irish" },
        .{ .code = "sv", .display = "Swedish" },
        .{ .code = "tr", .display = "Turkish" },
        .{ .code = "yue", .display = "Cantonese" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.code)) return entry.display;
    }
    return null;
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

fn canonicalHintLabelAlloc(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0 or !isCanonicalTargetTemplate(trimmed)) return null;

    inline for ([_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "alt form", .label = "alternative form of" },
        .{ .name = "alt form of", .label = "alternative form of" },
        .{ .name = "altform", .label = "alternative form of" },
        .{ .name = "alternative form of", .label = "alternative form of" },
        .{ .name = "alt sp", .label = "alternative spelling of" },
        .{ .name = "alt sp of", .label = "alternative spelling of" },
        .{ .name = "alt spell", .label = "alternative spelling of" },
        .{ .name = "alt spelling of", .label = "alternative spelling of" },
        .{ .name = "alternative spelling of", .label = "alternative spelling of" },
        .{ .name = "alt case", .label = "alternative case form of" },
        .{ .name = "alternative case form of", .label = "alternative case form of" },
        .{ .name = "abbr", .label = "abbreviation of" },
        .{ .name = "abbr of", .label = "abbreviation of" },
        .{ .name = "abbrev", .label = "abbreviation of" },
        .{ .name = "abbrev of", .label = "abbreviation of" },
        .{ .name = "abbreviation of", .label = "abbreviation of" },
        .{ .name = "acronym of", .label = "acronym of" },
        .{ .name = "init of", .label = "initialism of" },
        .{ .name = "clipping", .label = "clipping of" },
        .{ .name = "clip", .label = "clipping of" },
        .{ .name = "clip of", .label = "clipping of" },
        .{ .name = "clipping of", .label = "clipping of" },
        .{ .name = "contraction of", .label = "contraction of" },
        .{ .name = "back-form", .label = "back-formation of" },
        .{ .name = "back-formation", .label = "back-formation of" },
        .{ .name = "inflection of", .label = "inflection of" },
        .{ .name = "infl of", .label = "inflection of" },
    }) |candidate| {
        if (templateMatches(trimmed, candidate.name)) return try sentenceCaseAsciiAlloc(allocator, candidate.label);
    }

    if (!asciiEndsWithIgnoreCase(trimmed, " of")) return null;
    const stem = std.mem.trim(u8, trimmed[0 .. trimmed.len - " of".len], " \t");
    const phrase = if (canonicalStemNeedsFormSuffix(stem))
        try std.fmt.allocPrint(allocator, "{s} form of", .{stem})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(phrase);
    return try sentenceCaseAsciiAlloc(allocator, phrase);
}

fn canonicalStemNeedsFormSuffix(stem: []const u8) bool {
    inline for ([_][]const u8{
        "plural",
        "singular",
        "participle",
        "gerund",
        "comparative",
        "superlative",
        "feminine",
        "masculine",
        "neuter",
        "verb",
        "noun",
        "adj",
        "adjective",
        "adverb",
        "past",
        "present",
        "future",
        "imperative",
        "indicative",
        "subjunctive",
        "infinitive",
        "possessive",
        "attributive",
    }) |needle| {
        if (asciiContainsIgnoreCase(stem, needle)) return true;
    }
    return false;
}

fn canonicalStemIsDirectVariant(stem: []const u8) bool {
    inline for ([_][]const u8{
        "form",
        "spelling",
        "variant",
        "romanization",
        "pronunciation",
        "typography",
        "orthography",
        "mutation",
        "lenition",
        "eclipsis",
        "prothesis",
        "abbreviation",
        "acronym",
        "initialism",
        "contraction",
        "clipping",
        "ellipsis",
        "aphetic",
        "apheretic",
        "apocopic",
        "procopic",
        "syncopic",
        "combining form",
        "combining stem",
    }) |needle| {
        if (asciiContainsIgnoreCase(stem, needle)) return true;
    }
    return false;
}

fn templateAliasTargetIndex(parts: *const std.ArrayList([]const u8)) ?usize {
    const count = positionalCount(parts);
    if (count == 0) return null;

    var index = semanticTemplateTargetIndex(parts);
    while (index < count) : (index += 1) {
        const candidate = templatePositional(parts, index) orelse continue;
        const trimmed = std.mem.trim(u8, candidate, " \t");
        if (trimmed.len == 0) continue;
        if (index == 0 and looksLikeLanguageCode(trimmed) and count == 1) continue;
        return index;
    }
    return null;
}

fn templateAliasTarget(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const index = templateAliasTargetIndex(parts) orelse return null;
    return templatePositional(parts, index);
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
}

fn titleCaseAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    var upper_next = true;
    for (out) |*char| {
        if (std.ascii.isAlphabetic(char.*)) {
            char.* = if (upper_next) std.ascii.toUpper(char.*) else std.ascii.toLower(char.*);
            upper_next = false;
            continue;
        }
        upper_next = char.* == ' ' or char.* == '-' or char.* == '/' or char.* == '(';
    }
    return out;
}

fn sentenceCaseAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    var saw_alpha = false;
    for (out) |*char| {
        if (!std.ascii.isAlphabetic(char.*)) continue;
        char.* = if (saw_alpha) std.ascii.toLower(char.*) else std.ascii.toUpper(char.*);
        saw_alpha = true;
    }
    return out;
}

fn asciiEndsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return asciiStartsWithIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (asciiStartsWithIgnoreCase(haystack[start..], needle)) return true;
    }
    return false;
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

test "parse noun form gloss preserves semantic template labels" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\
        \\# {{plural of|en|Fresnel reflection}}
    ;

    var parsed = (try parseEnglishEntry(std.testing.allocator, "Fresnel reflections", source)).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.alias_only);
    try std.testing.expectEqual(@as(usize, 1), parsed.senses.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.canonical_targets.items.len);
    try std.testing.expectEqualStrings("Fresnel reflection", parsed.canonical_targets.items[0]);
    try std.testing.expectEqualStrings("Plural form of", parsed.alias_hint_label);
    try std.testing.expectEqualStrings("plural of Fresnel reflection", parsed.senses.items[0].gloss);
}

test "parse singular form entries also emit canonical alias hints" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\
        \\# {{singular of|en|scissors}}
    ;

    var parsed = (try parseEnglishEntry(std.testing.allocator, "scissor", source)).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.alias_only);
    try std.testing.expectEqual(@as(usize, 1), parsed.canonical_targets.items.len);
    try std.testing.expectEqualStrings("scissors", parsed.canonical_targets.items[0]);
    try std.testing.expectEqualStrings("Singular form of", parsed.alias_hint_label);
}

test "extractSummaryAlloc uses dictionary-style head label when present" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\
        \\# {{plural of|en|Fresnel reflection}}
    ;

    const summary = try extractSummaryAlloc(std.testing.allocator, source, 240);
    defer std.testing.allocator.free(summary);

    try std.testing.expectEqualStrings("noun form: plural of Fresnel reflection", summary);
}

test "renderWikitextToOwned expands common inflection tags" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{infl of|en|pie||s-verb-form}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("third-person singular simple present indicative of pie", rendered);
}

test "renderWikitextToOwned expands ed-form and ing-form inflection tags" {
    const ed = try renderWikitextToOwned(std.testing.allocator, "{{infl of|en|abandon||ed-form}}", 256);
    defer std.testing.allocator.free(ed);
    try std.testing.expectEqualStrings("simple past and past participle of abandon", ed);

    const ing = try renderWikitextToOwned(std.testing.allocator, "{{infl of|en|abear||ing-form}}", 256);
    defer std.testing.allocator.free(ing);
    try std.testing.expectEqualStrings("present participle and gerund of abear", ing);
}

test "extractSummaryAlloc falls back to part-of-speech heading label" {
    const source =
        \\==English==
        \\
        \\===Verb===
        \\# [[to]] [[move]] quickly
    ;

    const summary = try extractSummaryAlloc(std.testing.allocator, source, 240);
    defer std.testing.allocator.free(summary);

    try std.testing.expectEqualStrings("verb: to move quickly", summary);
}

test "renderWikitextToOwned formats place and surname templates as sentence fragments" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|hamlet|par/Ipplepen|dist/Teignbridge|co/Devon|cc/England}} {{q|[[OS]] grid ref SX8566}}. {{surname|en}}.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A hamlet in Ipplepen parish, Teignbridge district, Devon, England (OS grid ref SX8566). A surname.",
        rendered,
    );
}

test "renderWikitextToOwned expands metropolitan borough place fragments" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|town|metbor/Knowsley|co/Merseyside|cc/England}} {{q|[[OS]] grid ref SJ4491}}.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A town in the Metropolitan Borough of Knowsley, Merseyside, England (OS grid ref SJ4491).",
        rendered,
    );
}

test "renderWikitextToOwned expands learned borrowing templates semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{learned borrowing|en|la|[[absque]] [[hoc]]|lit=without this}}.",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "learned borrowing from Latin absque hoc (literally \"without this\").",
        rendered,
    );
}

test "renderWikitextToOwned expands season name spelling usage note" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{season name spelling}}", 512);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "Note that season names are not capitalized in modern English except where any noun would be capitalized, e.g. at the beginning of a sentence or as part of a name (Old Man Winter, the Winter War, Summer Glau). This is in contrast to the days of the week and months of the year, which are always capitalized (Thursday or September).",
        rendered,
    );
}

test "renderWikitextToOwned supports cognate alias template" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{cognate|ang|earfoþe}} and {{cognate|de|Arbeit}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("earfoþe and Arbeit", rendered);
}

test "renderWikitextToOwned preserves nominal addl text and expands &lit semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{given name|en|male|addl=or more often nickname, for a boy who is junior to someone else}}. {{&lit|en|false|friend}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A male given name, or more often nickname, for a boy who is junior to someone else. Used other than figuratively or idiomatically: see false, friend",
        rendered,
    );
}

test "renderWikitextToOwned expands present inflection tags and abbreviation place templates" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|@abbrev of:Alabama|state|c/US}} {{inflection of|en|be||1|p|simple|pres}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Abbreviation of Alabama: a state of United States") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "first-person plural simple present of be") != null);
}

test "renderWikitextToOwned expands unadapted borrowing templates semantically" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{ubor|en|la|ōs|t=the mouth}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Unadapted borrowing from Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "the mouth") != null);
}

test "renderWikitextToOwned renders usage and only-used-in templates semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{U:en:be dead}} {{only used in|en|man enough}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "be dead") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Only used in man enough.") != null);
}

test "extractSummaryAlloc formats place templates semantically for previews" {
    const source =
        \\==English==
        \\{{wp}}
        \\
        \\===Proper noun===
        \\{{en-proper noun}}
        \\
        \\# {{place|en|hamlet|par/Ipplepen|dist/Teignbridge|co/Devon|cc/England}} {{q|[[OS]] grid ref SX8566}}.
        \\# {{surname|en}}.
    ;

    const summary = try extractSummaryAlloc(std.testing.allocator, source, 512);
    defer std.testing.allocator.free(summary);

    try std.testing.expectEqualStrings(
        "proper noun: A hamlet in Ipplepen parish, Teignbridge district, Devon, England (OS grid ref SX8566).",
        summary,
    );
}

test "extractSummaryAlloc does not prepend indefinite articles to determiner-led place text" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|The largest and most populous <<constituent country>> of the <<c/United Kingdom>>}}
    ;

    const summary = try extractSummaryAlloc(std.testing.allocator, source, 512);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "proper noun: The largest and") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "proper noun: A The largest") == null);
}

test "renderWikitextToOwned prefixes compound-plus etymologies" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{compound+|en|trade|t1=course, path (of running)|pos1=from 14th c.|wind}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Compound of trade") != null);
}

test "renderWikitextToOwned keeps standalone clipping templates targetless" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "Bookmaker sense by {{clipping|en|nocap=1}}.", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "clipping.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "clipping of") == null);
}

test "renderWikitextToOwned reads numeric named args as positional template args" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{non-gloss|1=Used as a prefix to verbs in the sense of remaining in the same condition.}} {{clip of|en|abdominal muscle}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Used as a prefix to verbs in the sense of remaining in the same condition.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "clipping of abdominal muscle") != null);
}

test "renderWikitextToOwned preserves possessive apostrophes around italic markup" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "''Britannica'''s ''[[w:Macropædia|Macropædia]]''",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Britannica's Macropædia", rendered);
}

test "renderWikitextToOwned preserves literal less-than text" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "month names < English", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("month names < English", rendered);
}

test "renderWikitextToOwned preserves unary template targets that resemble language codes" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{alternative spelling of|en|cro|t=marijuana}} {{ellipsis of|en|pie-dog|t=an [[Indian]] [[breed]]}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "alternative spelling of cro (marijuana) ellipsis of pie-dog (an Indian breed)",
        rendered,
    );
}

test "extract english section preserves raw bytes" {
    const source =
        \\==Translingual==
        \\foo
        \\==English==
        \\===Noun===
        \\# [[light]]
        \\==French==
        \\bar
    ;

    const english = extractEnglishSection(source).?;
    try std.testing.expectEqualStrings(
        \\==English==
        \\===Noun===
        \\# [[light]]
        \\
    , english);
}

test "extractConfiguredLanguageSectionsAlloc keeps all language sections by default" {
    const source =
        \\{{also|foo}}
        \\==English==
        \\===Noun===
        \\# [[light]]
        \\
        \\==Hindi==
        \\===Noun===
        \\# [[cunt]]
    ;

    const sections = (try extractConfiguredLanguageSectionsAlloc(std.testing.allocator, source, .{})).?;
    defer std.testing.allocator.free(sections);

    try std.testing.expect(std.mem.indexOf(u8, sections, "==English==") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "==Hindi==") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "{{also|foo}}") == null);
}

test "languageMatchesFilterCsv matches trimmed names" {
    try std.testing.expect(languageMatchesFilterCsv("English", "English, Chinese"));
    try std.testing.expect(languageMatchesFilterCsv("Chinese", "English, Chinese"));
    try std.testing.expect(!languageMatchesFilterCsv("Hindi", "English, Chinese"));
    try std.testing.expect(languageMatchesFilterCsv("Hindi", ""));
}

test "section parser specs advertise live shared parser implementations" {
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("English", 2).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_alt_forms, sectionParserSpecForTitle("Alternative forms", 3).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Etymology", 3).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Pronunciation", 3).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_pos, sectionParserSpecForTitle("Noun", 3).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Derived terms", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Translations", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("References", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Usage notes", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("See also", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Descendants", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Conjugation", 4).?.parser_name);
    try std.testing.expectEqualStrings(parser_name_capture, sectionParserSpecForTitle("Attestation", 4).?.parser_name);
}

test "parse english entry dispatches section families through dedicated parsers" {
    const source =
        \\==English==
        \\[[File:Color wheel.svg|thumb|A color wheel.]]
        \\General overview.
        \\
        \\===Alternative spelling===
        \\* [[colour]]
        \\
        \\===Pronunciation===
        \\* {{IPA|en|/kʌlə(ɹ)/}}
        \\
        \\===Etymology===
        \\From [[Latin]].
        \\
        \\===Noun===
        \\# [[light]]
        \\
        \\===Translations===
        \\* Finnish: {{t|fi|vari}}
        \\
        \\===Derived terms===
        \\* {{l|en|colorize}}
        \\
        \\===Descendants===
        \\* {{desc|fr|couleur}}
        \\
        \\===Conjugation===
        \\* third-person singular: colors
        \\
        \\===References===
        \\* Reference note.
        \\
        \\===Usage Notes===
        \\* chiefly US
        \\
        \\===See Also===
        \\* [[shade]]
        \\
        \\===Dialects===
        \\* regional variants
    ;

    var parsed = (try parseEnglishEntry(std.testing.allocator, "color", source)).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.alt_forms.items.len);
    try std.testing.expectEqualStrings("colour", parsed.alt_forms.items[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.senses.items.len);
    try std.testing.expectEqualStrings("light", parsed.senses.items[0].gloss);

    var saw_root = false;
    var saw_pronunciation = false;
    var saw_etymology = false;
    var saw_translations = false;
    var saw_relations = false;
    var saw_descendants = false;
    var saw_inflection = false;
    var saw_citations = false;
    var saw_notes = false;
    var saw_navigation = false;
    var saw_meta = false;

    for (parsed.sections.items) |section| {
        if (headingMatches(section.title, "English")) saw_root = true;
        if (headingMatches(section.title, "Pronunciation")) saw_pronunciation = true;
        if (headingMatches(section.title, "Etymology")) saw_etymology = true;
        if (headingMatches(section.title, "Translations")) saw_translations = true;
        if (headingMatches(section.title, "Derived terms")) saw_relations = true;
        if (headingMatches(section.title, "Descendants")) saw_descendants = true;
        if (headingMatches(section.title, "Conjugation")) saw_inflection = true;
        if (headingMatches(section.title, "References")) saw_citations = true;
        if (headingMatches(section.title, "Usage Notes")) saw_notes = true;
        if (headingMatches(section.title, "See Also")) saw_navigation = true;
        if (headingMatches(section.title, "Dialects")) saw_meta = true;
    }

    try std.testing.expect(saw_root);
    try std.testing.expect(saw_pronunciation);
    try std.testing.expect(saw_etymology);
    try std.testing.expect(saw_translations);
    try std.testing.expect(saw_relations);
    try std.testing.expect(saw_descendants);
    try std.testing.expect(saw_inflection);
    try std.testing.expect(saw_citations);
    try std.testing.expect(saw_notes);
    try std.testing.expect(saw_navigation);
    try std.testing.expect(saw_meta);
}

test "filter english section honors compact exclusion policy" {
    const english =
        \\==English==
        \\===Pronunciation===
        \\* {{IPA|en|/tɛst/}}
        \\===Translations===
        \\* Finnish: testi
        \\===Further reading===
        \\* {{R:OneLook}}
        \\===References===
        \\* {{R:OneLook}}
        \\===Anagrams===
        \\* sett
        \\===Statistics===
        \\* stub
        \\===Dialects===
        \\* rare
        \\===Noun===
        \\# [[test]]
        \\
    ;

    const filtered = try filterEnglishSectionAlloc(std.testing.allocator, english, .defaultCompact());
    defer std.testing.allocator.free(filtered);

    try std.testing.expect(std.mem.indexOf(u8, filtered, "===Pronunciation===") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "===Noun===") != null);
    if (!ExclusionPolicy.defaultCompact().exclude_translations) {
        try std.testing.expect(std.mem.indexOf(u8, filtered, "===Translations===") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, filtered, "===Translations===") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, filtered, "===Further reading===") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "===References===") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "===Anagrams===") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "===Statistics===") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "===Dialects===") == null);
}

test "parseExclusionPolicy accepts heading titles and policy names" {
    const exclusions = try parseExclusionPolicy("Anagrams,Further reading,translations,References,meta");
    try std.testing.expect(exclusions.exclude_anagrams);
    try std.testing.expect(exclusions.exclude_further_reading);
    try std.testing.expect(exclusions.exclude_translations);
    try std.testing.expect(exclusions.exclude_citations);
    try std.testing.expect(exclusions.exclude_meta);
}

test "filter english section strips inline quotation examples in compact mode" {
    const english =
        \\==English==
        \\===Noun===
        \\# A travelling case.
        \\#: {{RQ:Dickens Haunted House|chapter=The Mortals in the House|page=7|column=2|passage=...}}
        \\#* {{quote-book|en|year=1859|author=Charles Dickens|title=A Tale of Two Cities|passage=...}}
        \\#: {{ux|en|A portmanteau lay open on the bed.}}
        \\
    ;

    const filtered = try filterEnglishSectionAlloc(std.testing.allocator, english, .defaultCompact());
    defer std.testing.allocator.free(filtered);

    try std.testing.expect(std.mem.indexOf(u8, filtered, "{{RQ:Dickens Haunted House|") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "{{quote-book|en|") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "{{ux|en|A portmanteau lay open on the bed.}}") != null);
}

test "renderWikitextToOwned tolerates stray closing wiki markup" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "kept sense}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("kept sense", rendered);
}

test "renderWikitextToOwned normalizes template names and external link labels" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{dated_form|en|bra||item of underwear}} {{q-lite|Arabic numeral}} {{Webster_1913}} [https://example.test [[Wikipedia:The Art of Cookery made Plain and Easy|The Art of Cookery made Plain and Easy]]]",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "dated form of bra") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(item of underwear)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(Arabic numeral)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "The Art of Cookery made Plain and Easy") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://example.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Webster") == null);
}

test "renderWikitextToOwned expands standalone initialism etymologies" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "From {{initialism|en|[[resistant|'''R'''esistant]] [[to]] [[oil]] [[particles]] [[with]] [[ninety-five|'''95''']][[%]] [[filtration]] [[efficiency]]}} in {{w|lang=en|NIOSH air filtration rating}}s.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("From initialism of Resistant to oil particles with 95% filtration efficiency in NIOSH air filtration ratings.", rendered);
}

test "renderWikitextToOwned expands usage helpers and county-seat place templates" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{U:en:I-P}} {{place|en|city/county seat|co/Clay County|s/Indiana|c/USA}} {{onom|en}} {{aphetic form|en|escarp}}",
        1024,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "The use of Israel to refer to the region") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "A city, the county seat of Clay County, Indiana, United States") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Onomatopoeic") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aphetic form of escarp") != null);
}
