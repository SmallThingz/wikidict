const std = @import("std");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");

const trailing_newline_flag: u8 = 1 << 0;

const SectionKind = enum(u8) {
    lines = 0,
    pos_lines = 1,
    term_list = 2,
    translations = 3,
};

const heading_generic: u8 = 0;
const heading_preamble: u8 = 1;

const HeadingDef = struct {
    code: u8,
    title: []const u8,
    kind: SectionKind,
};

const heading_defs = [_]HeadingDef{
    .{ .code = 2, .title = "Alternative forms", .kind = .term_list },
    .{ .code = 3, .title = "Etymology", .kind = .lines },
    .{ .code = 4, .title = "Pronunciation", .kind = .lines },
    .{ .code = 5, .title = "Noun", .kind = .pos_lines },
    .{ .code = 6, .title = "Proper noun", .kind = .pos_lines },
    .{ .code = 7, .title = "Proper Noun", .kind = .pos_lines },
    .{ .code = 8, .title = "Verb", .kind = .pos_lines },
    .{ .code = 9, .title = "Adjective", .kind = .pos_lines },
    .{ .code = 10, .title = "Adverb", .kind = .pos_lines },
    .{ .code = 11, .title = "Pronoun", .kind = .pos_lines },
    .{ .code = 12, .title = "Preposition", .kind = .pos_lines },
    .{ .code = 13, .title = "Conjunction", .kind = .pos_lines },
    .{ .code = 14, .title = "Interjection", .kind = .pos_lines },
    .{ .code = 15, .title = "Determiner", .kind = .pos_lines },
    .{ .code = 16, .title = "Numeral", .kind = .pos_lines },
    .{ .code = 17, .title = "Phrase", .kind = .pos_lines },
    .{ .code = 18, .title = "Article", .kind = .pos_lines },
    .{ .code = 19, .title = "Abbreviation", .kind = .pos_lines },
    .{ .code = 20, .title = "Initialism", .kind = .pos_lines },
    .{ .code = 21, .title = "Symbol", .kind = .pos_lines },
    .{ .code = 22, .title = "Letter", .kind = .pos_lines },
    .{ .code = 23, .title = "Contraction", .kind = .pos_lines },
    .{ .code = 24, .title = "Participle", .kind = .pos_lines },
    .{ .code = 25, .title = "Particle", .kind = .pos_lines },
    .{ .code = 26, .title = "Affix", .kind = .pos_lines },
    .{ .code = 27, .title = "Prefix", .kind = .pos_lines },
    .{ .code = 28, .title = "Suffix", .kind = .pos_lines },
    .{ .code = 29, .title = "Infix", .kind = .pos_lines },
    .{ .code = 30, .title = "Circumfix", .kind = .pos_lines },
    .{ .code = 31, .title = "Proverb", .kind = .pos_lines },
    .{ .code = 32, .title = "Idiom", .kind = .pos_lines },
    .{ .code = 33, .title = "Usage notes", .kind = .lines },
    .{ .code = 34, .title = "Synonyms", .kind = .term_list },
    .{ .code = 35, .title = "Antonyms", .kind = .term_list },
    .{ .code = 36, .title = "Related terms", .kind = .term_list },
    .{ .code = 37, .title = "Coordinate terms", .kind = .term_list },
    .{ .code = 38, .title = "Hypernyms", .kind = .term_list },
    .{ .code = 39, .title = "Hyponyms", .kind = .term_list },
    .{ .code = 40, .title = "Translations", .kind = .translations },
    .{ .code = 41, .title = "Derived terms", .kind = .term_list },
    .{ .code = 42, .title = "See also", .kind = .term_list },
    .{ .code = 43, .title = "Anagrams", .kind = .term_list },
    .{ .code = 44, .title = "Further reading", .kind = .lines },
    .{ .code = 45, .title = "Descendants", .kind = .lines },
    .{ .code = 46, .title = "Conjugation", .kind = .lines },
    .{ .code = 47, .title = "Declension", .kind = .lines },
    .{ .code = 48, .title = "Inflection", .kind = .lines },
    .{ .code = 49, .title = "Quotations", .kind = .lines },
    .{ .code = 50, .title = "Compounds", .kind = .term_list },
    .{ .code = 51, .title = "References", .kind = .lines },
};

const line_blank: u8 = 254;
const line_raw: u8 = 255;

const LinePrefix = struct {
    code: u8,
    prefix: []const u8,
};

const line_prefixes = [_]LinePrefix{
    .{ .code = 1, .prefix = "### " },
    .{ .code = 2, .prefix = "##* " },
    .{ .code = 3, .prefix = "##: " },
    .{ .code = 4, .prefix = "## " },
    .{ .code = 5, .prefix = "#:* " },
    .{ .code = 6, .prefix = "#: " },
    .{ .code = 7, .prefix = "#* " },
    .{ .code = 8, .prefix = "# " },
    .{ .code = 9, .prefix = "*** " },
    .{ .code = 10, .prefix = "**: " },
    .{ .code = 11, .prefix = "** " },
    .{ .code = 12, .prefix = "*: " },
    .{ .code = 13, .prefix = "* " },
    .{ .code = 14, .prefix = ":: " },
    .{ .code = 15, .prefix = ": " },
    .{ .code = 16, .prefix = "; " },
};

const record_raw_line: u8 = 0;
const record_column_block: u8 = 1;

const trans_raw_line: u8 = 0;
const trans_top: u8 = 1;
const trans_check_top: u8 = 2;
const trans_mid: u8 = 3;
const trans_bottom: u8 = 4;
const trans_multitrans_open: u8 = 5;
const trans_multitrans_close: u8 = 6;
const trans_mapping_line: u8 = 7;

const translation_raw_token: u8 = 0;
const translation_template_token: u8 = 1;

const template_name_raw: u8 = 0;

const TranslationTemplate = struct {
    code: u8,
    name: []const u8,
};

const translation_templates = [_]TranslationTemplate{
    .{ .code = 1, .name = "tt+" },
    .{ .code = 2, .name = "tt" },
    .{ .code = 3, .name = "t+check" },
    .{ .code = 4, .name = "t-check" },
    .{ .code = 5, .name = "t+" },
    .{ .code = 6, .name = "t" },
};

const label_raw: u8 = 0;

const LanguageLabel = struct {
    code: u8,
    label: []const u8,
};

const language_labels = [_]LanguageLabel{
    .{ .code = 1, .label = "French" },
    .{ .code = 2, .label = "German" },
    .{ .code = 3, .label = "Spanish" },
    .{ .code = 4, .label = "Portuguese" },
    .{ .code = 5, .label = "Russian" },
    .{ .code = 6, .label = "Japanese" },
    .{ .code = 7, .label = "Italian" },
    .{ .code = 8, .label = "Dutch" },
    .{ .code = 9, .label = "Swedish" },
    .{ .code = 10, .label = "Danish" },
    .{ .code = 11, .label = "Polish" },
    .{ .code = 12, .label = "Finnish" },
    .{ .code = 13, .label = "Hungarian" },
    .{ .code = 14, .label = "Greek" },
    .{ .code = 15, .label = "Hebrew" },
    .{ .code = 16, .label = "Arabic" },
    .{ .code = 17, .label = "Turkish" },
    .{ .code = 18, .label = "Korean" },
    .{ .code = 19, .label = "Czech" },
    .{ .code = 20, .label = "Bulgarian" },
    .{ .code = 21, .label = "Ukrainian" },
    .{ .code = 22, .label = "Romanian" },
    .{ .code = 23, .label = "Chinese" },
    .{ .code = 24, .label = "Mandarin" },
    .{ .code = 25, .label = "Cantonese" },
    .{ .code = 26, .label = "Norwegian" },
    .{ .code = 27, .label = "Bokmal" },
    .{ .code = 28, .label = "Bokmal Norwegian" },
    .{ .code = 29, .label = "Bokmål" },
    .{ .code = 30, .label = "Nynorsk" },
    .{ .code = 31, .label = "Armenian" },
    .{ .code = 32, .label = "Catalan" },
    .{ .code = 33, .label = "Esperanto" },
    .{ .code = 34, .label = "Icelandic" },
    .{ .code = 35, .label = "Irish" },
    .{ .code = 36, .label = "Latin" },
    .{ .code = 37, .label = "Malay" },
    .{ .code = 38, .label = "Persian" },
    .{ .code = 39, .label = "Vietnamese" },
    .{ .code = 40, .label = "Volapuk" },
    .{ .code = 41, .label = "Volapük" },
    .{ .code = 42, .label = "Albanian" },
    .{ .code = 43, .label = "Belarusian" },
    .{ .code = 44, .label = "Breton" },
    .{ .code = 45, .label = "Galician" },
    .{ .code = 46, .label = "Interlingua" },
    .{ .code = 47, .label = "Kurdish" },
    .{ .code = 48, .label = "Northern Kurdish" },
    .{ .code = 49, .label = "Central Kurdish" },
    .{ .code = 50, .label = "Serbo-Croatian" },
    .{ .code = 51, .label = "Slovene" },
    .{ .code = 52, .label = "Slovak" },
    .{ .code = 53, .label = "Croatian" },
    .{ .code = 54, .label = "Serbian" },
    .{ .code = 55, .label = "Lithuanian" },
    .{ .code = 56, .label = "Latvian" },
    .{ .code = 57, .label = "Georgian" },
    .{ .code = 58, .label = "Hindi" },
    .{ .code = 59, .label = "Urdu" },
    .{ .code = 60, .label = "Pashto" },
    .{ .code = 61, .label = "Old English" },
    .{ .code = 62, .label = "Ottoman Turkish" },
    .{ .code = 63, .label = "Malayalam" },
    .{ .code = 64, .label = "Indonesian" },
};

const column_col: u8 = 1;
const column_col2: u8 = 2;
const column_col3: u8 = 3;
const column_col4: u8 = 4;
const column_col5: u8 = 5;

const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

const SectionSource = struct {
    level: u8,
    title: []const u8,
    lines: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *SectionSource, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
    }
};

const MatchedPrefix = struct {
    code: u8,
    rest: []const u8,
};

const ColumnBlock = struct {
    template_code: u8,
    item_count: usize,
    consumed: usize,
    items: []const []const u8,
};

const ColumnInline = struct {
    template_code: u8,
    items: []const []const u8,
};

const MappingLine = struct {
    prefix_code: u8,
    label: []const u8,
    value: []const u8,
    has_inline_value: bool,
};

pub fn encodeEnglishAlloc(allocator: std.mem.Allocator, english_section: []const u8) ![]u8 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_allocator = temp_arena.allocator();

    const trailing_newline = english_section.len != 0 and english_section[english_section.len - 1] == '\n';
    const sections = try splitEnglishSections(temp_allocator, english_section);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, if (trailing_newline) trailing_newline_flag else 0);
    try appendVarUInt(&out, allocator, sections.len);

    for (sections) |section| {
        try out.append(allocator, section.level);

        const heading_code = headingCodeForTitle(section.title, section.level);
        try out.append(allocator, heading_code);
        if (heading_code == heading_generic) try appendCompactSlice(&out, allocator, section.title);

        const kind = kindForHeading(section.title, heading_code);
        try out.append(allocator, @intFromEnum(kind));

        const payload = try encodeSectionPayloadAlloc(temp_allocator, section.lines.items, kind);
        try appendBytesSlice(&out, allocator, payload);
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeEnglishAlloc(allocator: std.mem.Allocator, encoded: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    if (encoded.len == 0) return error.InvalidEncoding;

    var cursor: usize = 0;
    const flags = encoded[cursor];
    cursor += 1;
    const section_count = format.readVarUInt(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "==English==");

    var section_index: usize = 0;
    while (section_index < section_count) : (section_index += 1) {
        if (cursor >= encoded.len) return error.InvalidEncoding;
        const level = encoded[cursor];
        cursor += 1;
        if (cursor >= encoded.len) return error.InvalidEncoding;
        const heading_code = encoded[cursor];
        cursor += 1;

        const title = if (heading_code == heading_generic)
            try readCompactSliceAlloc(allocator, encoded, &cursor, encoded.len)
        else
            try allocator.dupe(u8, headingTitleForCode(heading_code) orelse return error.InvalidEncoding);
        defer allocator.free(title);

        if (cursor >= encoded.len) return error.InvalidEncoding;
        const kind_int = encoded[cursor];
        const kind = switch (kind_int) {
            @intFromEnum(SectionKind.lines) => SectionKind.lines,
            @intFromEnum(SectionKind.pos_lines) => SectionKind.pos_lines,
            @intFromEnum(SectionKind.term_list) => SectionKind.term_list,
            @intFromEnum(SectionKind.translations) => SectionKind.translations,
            else => return error.InvalidEncoding,
        };
        cursor += 1;

        const payload = readLengthPrefixedSlice(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;
        const body = switch (kind) {
            .lines => try decodeJoinedBodyAlloc(allocator, payload),
            .pos_lines => try decodeLineStreamAlloc(allocator, payload),
            .term_list => try decodeTermSectionAlloc(allocator, payload),
            .translations => try decodeTranslationSectionAlloc(allocator, payload),
        };
        defer allocator.free(body);

        if (level == 0 or heading_code == heading_preamble) {
            if (body.len != 0) {
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, body);
            }
            continue;
        }

        try out.append(allocator, '\n');
        try appendHeadingLine(&out, allocator, level, title);
        if (body.len != 0) {
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, body);
        }
    }

    if ((flags & trailing_newline_flag) != 0) try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn encodeSectionPayloadAlloc(allocator: std.mem.Allocator, lines: []const []const u8, kind: SectionKind) ![]u8 {
    return switch (kind) {
        .lines => encodeJoinedBodyAlloc(allocator, lines),
        .pos_lines => encodeLineStreamAlloc(allocator, lines),
        .term_list => encodeTermSectionAlloc(allocator, lines),
        .translations => encodeTranslationSectionAlloc(allocator, lines),
    };
}

fn encodeJoinedBodyAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    for (lines, 0..) |line, idx| {
        if (idx != 0) try joined.append(allocator, '\n');
        try joined.appendSlice(allocator, line);
    }

    return compact.encodeAlloc(allocator, joined.items);
}

fn encodeLineStreamAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try appendVarUInt(&out, allocator, lines.len);
    for (lines) |line| try appendEncodedLine(&out, allocator, line);
    return out.toOwnedSlice(allocator);
}

fn decodeLineStreamAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var cursor: usize = 0;
    const line_count = format.readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        if (i != 0) try out.append(allocator, '\n');
        const line = try decodeEncodedLineAlloc(allocator, payload, &cursor, payload.len);
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    if (cursor != payload.len) return error.InvalidEncoding;
    return out.toOwnedSlice(allocator);
}

fn decodeJoinedBodyAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    return compact.decodeAlloc(allocator, payload) catch return error.InvalidEncoding;
}

fn encodeTermSectionAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var records: std.ArrayList(u8) = .empty;
    defer records.deinit(allocator);

    var record_count: usize = 0;
    var i: usize = 0;
    while (i < lines.len) {
        if (parseInlineColumnTemplate(allocator, lines[i])) |column_inline| {
            record_count += 1;
            try records.append(allocator, record_column_block);
            try records.append(allocator, column_inline.template_code);
            try appendVarUInt(&records, allocator, column_inline.items.len);
            for (column_inline.items) |item| try appendCompactTerminated(&records, allocator, item);
            i += 1;
            continue;
        }

        if (parseColumnBlock(allocator, lines[i..])) |block| {
            record_count += 1;
            try records.append(allocator, record_column_block);
            try records.append(allocator, block.template_code);
            try appendVarUInt(&records, allocator, block.item_count);
            for (block.items[0..block.item_count]) |item| try appendCompactTerminated(&records, allocator, item);
            i += block.consumed;
            continue;
        }

        record_count += 1;
        try records.append(allocator, record_raw_line);
        try appendEncodedLine(&records, allocator, lines[i]);
        i += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendVarUInt(&out, allocator, record_count);
    try out.appendSlice(allocator, records.items);
    return out.toOwnedSlice(allocator);
}

fn decodeTermSectionAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var cursor: usize = 0;
    const record_count = format.readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        if (record_index != 0) try out.append(allocator, '\n');
        if (cursor >= payload.len) return error.InvalidEncoding;

        switch (payload[cursor]) {
            record_raw_line => {
                cursor += 1;
                const line = try decodeEncodedLineAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            },
            record_column_block => {
                cursor += 1;
                if (cursor >= payload.len) return error.InvalidEncoding;
                const template_code = payload[cursor];
                cursor += 1;
                const item_count = format.readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;

                try out.appendSlice(allocator, columnTemplateStart(template_code) orelse return error.InvalidEncoding);
                var item_index: usize = 0;
                while (item_index < item_count) : (item_index += 1) {
                    const item = try readCompactTerminatedAlloc(allocator, payload, &cursor, payload.len);
                    defer allocator.free(item);
                    try out.appendSlice(allocator, "\n|");
                    try out.appendSlice(allocator, item);
                }
                try out.appendSlice(allocator, "\n}}");
            },
            else => return error.InvalidEncoding,
        }
    }

    if (cursor != payload.len) return error.InvalidEncoding;
    return out.toOwnedSlice(allocator);
}

fn encodeTranslationSectionAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var records: std.ArrayList(u8) = .empty;
    defer records.deinit(allocator);

    var record_count: usize = 0;
    for (lines) |line| {
        if (matchTemplateArgLine(line, "trans-top")) |gloss| {
            record_count += 1;
            try records.append(allocator, trans_top);
            try appendCompactTerminated(&records, allocator, gloss);
            continue;
        }
        if (matchTemplateArgLine(line, "checktrans-top")) |gloss| {
            record_count += 1;
            try records.append(allocator, trans_check_top);
            try appendCompactTerminated(&records, allocator, gloss);
            continue;
        }
        if (lineEqualsTrimmed(line, "{{trans-mid}}")) {
            record_count += 1;
            try records.append(allocator, trans_mid);
            continue;
        }
        if (lineEqualsTrimmed(line, "{{trans-bottom}}")) {
            record_count += 1;
            try records.append(allocator, trans_bottom);
            continue;
        }
        if (lineEqualsTrimmed(line, "{{multitrans|data=")) {
            record_count += 1;
            try records.append(allocator, trans_multitrans_open);
            continue;
        }
        if (lineEqualsTrimmed(line, "}}<!-- close {{multitrans}} -->")) {
            record_count += 1;
            try records.append(allocator, trans_multitrans_close);
            continue;
        }
        if (parseMappingLine(line)) |mapping| {
            record_count += 1;
            try records.append(allocator, trans_mapping_line);
            try records.append(allocator, mapping.prefix_code);
            try appendLabelRef(&records, allocator, mapping.label);
            try records.append(allocator, if (mapping.has_inline_value) 1 else 0);
            try appendTranslationValue(&records, allocator, mapping.value);
            continue;
        }

        record_count += 1;
        try records.append(allocator, trans_raw_line);
        try appendEncodedLine(&records, allocator, line);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendVarUInt(&out, allocator, record_count);
    try out.appendSlice(allocator, records.items);
    return out.toOwnedSlice(allocator);
}

fn decodeTranslationSectionAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var cursor: usize = 0;
    const record_count = format.readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        if (record_index != 0) try out.append(allocator, '\n');
        if (cursor >= payload.len) return error.InvalidEncoding;

        switch (payload[cursor]) {
            trans_raw_line => {
                cursor += 1;
                const line = try decodeEncodedLineAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            },
            trans_top => {
                cursor += 1;
                const gloss = try readCompactTerminatedAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(gloss);
                if (gloss.len == 0) {
                    try out.appendSlice(allocator, "{{trans-top}}");
                } else {
                    try out.appendSlice(allocator, "{{trans-top|");
                    try out.appendSlice(allocator, gloss);
                    try out.appendSlice(allocator, "}}");
                }
            },
            trans_check_top => {
                cursor += 1;
                const gloss = try readCompactTerminatedAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(gloss);
                if (gloss.len == 0) {
                    try out.appendSlice(allocator, "{{checktrans-top}}");
                } else {
                    try out.appendSlice(allocator, "{{checktrans-top|");
                    try out.appendSlice(allocator, gloss);
                    try out.appendSlice(allocator, "}}");
                }
            },
            trans_mid => {
                cursor += 1;
                try out.appendSlice(allocator, "{{trans-mid}}");
            },
            trans_bottom => {
                cursor += 1;
                try out.appendSlice(allocator, "{{trans-bottom}}");
            },
            trans_multitrans_open => {
                cursor += 1;
                try out.appendSlice(allocator, "{{multitrans|data=");
            },
            trans_multitrans_close => {
                cursor += 1;
                try out.appendSlice(allocator, "}}<!-- close {{multitrans}} -->");
            },
            trans_mapping_line => {
                cursor += 1;
                if (cursor >= payload.len) return error.InvalidEncoding;
                const prefix_code = payload[cursor];
                cursor += 1;
                const label = try readLabelRefAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(label);
                if (cursor >= payload.len) return error.InvalidEncoding;
                const has_inline_value = payload[cursor] != 0;
                cursor += 1;
                const value = try readTranslationValueAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(value);

                const prefix = prefixForCode(prefix_code) orelse return error.InvalidEncoding;
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, label);
                if (has_inline_value) {
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, value);
                } else {
                    try out.append(allocator, ':');
                }
            },
            else => return error.InvalidEncoding,
        }
    }

    if (cursor != payload.len) return error.InvalidEncoding;
    return out.toOwnedSlice(allocator);
}

fn splitEnglishSections(allocator: std.mem.Allocator, english_section: []const u8) ![]SectionSource {
    const first_line_end = std.mem.indexOfScalar(u8, english_section, '\n') orelse english_section.len;
    const first_line = std.mem.trimEnd(u8, english_section[0..first_line_end], "\r");
    const first_heading = parseHeading(first_line) orelse return error.InvalidEnglishSection;
    if (first_heading.level != 2 or !std.mem.eql(u8, first_heading.title, "English")) return error.InvalidEnglishSection;

    var sections: std.ArrayList(SectionSource) = .empty;
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    try sections.append(allocator, .{ .level = 0, .title = "" });

    var current: *SectionSource = &sections.items[0];
    var line_start: usize = if (first_line_end == english_section.len) english_section.len else first_line_end + 1;
    while (line_start < english_section.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, english_section, line_start, '\n') orelse english_section.len;
        const line = std.mem.trimEnd(u8, english_section[line_start..next_newline], "\r");

        if (parseHeading(line)) |heading| {
            if (heading.level >= 3) {
                try sections.append(allocator, .{
                    .level = heading.level,
                    .title = heading.title,
                });
                current = &sections.items[sections.items.len - 1];
            } else {
                try current.lines.append(allocator, line);
            }
        } else {
            try current.lines.append(allocator, line);
        }
        line_start = if (next_newline == english_section.len) english_section.len else next_newline + 1;
    }

    if (sections.items.len > 1 and sections.items[0].lines.items.len == 0) {
        sections.items[0].deinit(allocator);
        _ = sections.orderedRemove(0);
    }

    for (sections.items) |*section| {
        section.title = try allocator.dupe(u8, section.title);
    }

    return sections.toOwnedSlice(allocator);
}

fn appendEncodedLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    if (line.len == 0) {
        try out.append(allocator, line_blank);
        return;
    }

    if (matchLinePrefix(line)) |matched| {
        try out.append(allocator, matched.code);
        try appendCompactTerminated(out, allocator, matched.rest);
        return;
    }

    try out.append(allocator, line_raw);
    try appendCompactTerminated(out, allocator, line);
}

fn decodeEncodedLineAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, limit: usize) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    if (cursor.* >= limit) return error.InvalidEncoding;
    const code = bytes[cursor.*];
    cursor.* += 1;

    if (code == line_blank) return allocator.dupe(u8, "");
    if (code == line_raw) return readCompactTerminatedAlloc(allocator, bytes, cursor, limit);

    const prefix = prefixForCode(code) orelse return error.InvalidEncoding;
    const rest = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
    defer allocator.free(rest);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn appendHeadingLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, level: u8, title: []const u8) !void {
    var i: u8 = 0;
    while (i < level) : (i += 1) try out.append(allocator, '=');
    try out.appendSlice(allocator, title);
    i = 0;
    while (i < level) : (i += 1) try out.append(allocator, '=');
}

fn appendVarUInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var len_buf: [10]u8 = undefined;
    try out.appendSlice(allocator, format.encodeVarUInt(&len_buf, value));
}

fn appendBytesSlice(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendVarUInt(out, allocator, bytes.len);
    try out.appendSlice(allocator, bytes);
}

fn readLengthPrefixedSlice(bytes: []const u8, cursor: *usize, limit: usize) error{InvalidEncoding}![]const u8 {
    const len_u64 = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
    const len = std.math.cast(usize, len_u64) orelse return error.InvalidEncoding;
    if (cursor.* > limit or len > limit - cursor.*) return error.InvalidEncoding;
    const start = cursor.*;
    cursor.* += len;
    return bytes[start .. start + len];
}

fn appendCompactSlice(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const encoded = try compact.encodeAlloc(allocator, text);
    defer allocator.free(encoded);
    try appendBytesSlice(out, allocator, encoded);
}

fn readCompactSliceAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, limit: usize) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const encoded = readLengthPrefixedSlice(bytes, cursor, limit) catch return error.InvalidEncoding;
    return compact.decodeAlloc(allocator, encoded) catch return error.InvalidEncoding;
}

fn appendCompactTerminated(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const encoded = try compact.encodeAlloc(allocator, text);
    defer allocator.free(encoded);
    if (std.mem.indexOfScalar(u8, encoded, 0) != null) return error.InvalidEncoding;
    try out.appendSlice(allocator, encoded);
    try out.append(allocator, 0);
}

fn readCompactTerminatedAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, limit: usize) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes[0..limit], cursor.*, 0) orelse return error.InvalidEncoding;
    const encoded = bytes[cursor.*..end];
    cursor.* = end + 1;
    return compact.decodeAlloc(allocator, encoded) catch return error.InvalidEncoding;
}

fn headingCodeForTitle(title: []const u8, level: u8) u8 {
    if (level == 0 and title.len == 0) return heading_preamble;
    for (heading_defs) |def| {
        if (std.mem.eql(u8, def.title, title)) return def.code;
    }
    return heading_generic;
}

fn headingTitleForCode(code: u8) ?[]const u8 {
    if (code == heading_preamble) return "";
    for (heading_defs) |def| {
        if (def.code == code) return def.title;
    }
    return null;
}

fn kindForHeading(title: []const u8, code: u8) SectionKind {
    if (code == heading_preamble) return .lines;
    for (heading_defs) |def| {
        if (def.code == code) return def.kind;
    }
    _ = title;
    return .lines;
}

fn matchLinePrefix(line: []const u8) ?MatchedPrefix {
    var best: ?MatchedPrefix = null;
    var best_len: usize = 0;
    for (line_prefixes) |prefix| {
        if (prefix.prefix.len > best_len and std.mem.startsWith(u8, line, prefix.prefix)) {
            best = .{
                .code = prefix.code,
                .rest = line[prefix.prefix.len..],
            };
            best_len = prefix.prefix.len;
        }
    }
    return best;
}

fn prefixForCode(code: u8) ?[]const u8 {
    for (line_prefixes) |prefix| {
        if (prefix.code == code) return prefix.prefix;
    }
    return null;
}

fn parseHeading(line: []const u8) ?ParsedHeading {
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

fn parseColumnBlock(allocator: std.mem.Allocator, lines: []const []const u8) ?ColumnBlock {
    if (lines.len == 0) return null;

    const first_trimmed = std.mem.trim(u8, lines[0], " \t");
    if (!std.mem.startsWith(u8, first_trimmed, "{{")) return null;

    const first_body = first_trimmed[2..];
    var first_parts = splitTopLevel(allocator, first_body, '|') catch return null;
    if (first_parts.items.len < 2) return null;

    const template_code = inlineColumnTemplateCode(first_parts.items[0]) orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first_parts.items[1], " \t"), "en")) return null;

    var end_index: usize = 1;
    while (end_index < lines.len) : (end_index += 1) {
        const trimmed = std.mem.trim(u8, lines[end_index], " \t");
        if (std.mem.eql(u8, trimmed, "}}")) break;
        if (!std.mem.startsWith(u8, trimmed, "|")) return null;
    }
    if (end_index >= lines.len) return null;

    const extra_items = lines[1..end_index];
    for (extra_items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "|")) return null;
    }

    const initial_items = first_parts.items[2..];
    const item_count = initial_items.len + extra_items.len;
    const items = allocator.alloc([]const u8, item_count) catch return null;

    var write_index: usize = 0;
    for (initial_items) |item| {
        items[write_index] = std.mem.trim(u8, item, " \t");
        write_index += 1;
    }
    for (extra_items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        items[write_index] = std.mem.trim(u8, trimmed[1..], " \t");
        write_index += 1;
    }

    return .{
        .template_code = template_code,
        .item_count = item_count,
        .consumed = end_index + 1,
        .items = items,
    };
}

fn parseInlineColumnTemplate(allocator: std.mem.Allocator, line: []const u8) ?ColumnInline {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return null;

    const body = trimmed[2 .. trimmed.len - 2];
    var parts = splitTopLevel(allocator, body, '|') catch return null;
    if (parts.items.len < 2) return null;

    const template_code = inlineColumnTemplateCode(parts.items[0]) orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, parts.items[1], " \t"), "en")) return null;

    return .{
        .template_code = template_code,
        .items = parts.items[2..],
    };
}

fn columnTemplateCode(line: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.eql(u8, trimmed, "{{col|en")) return column_col;
    if (std.mem.eql(u8, trimmed, "{{col2|en")) return column_col2;
    if (std.mem.eql(u8, trimmed, "{{col3|en")) return column_col3;
    if (std.mem.eql(u8, trimmed, "{{col4|en")) return column_col4;
    if (std.mem.eql(u8, trimmed, "{{col5|en")) return column_col5;
    return null;
}

fn inlineColumnTemplateCode(name: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (std.mem.eql(u8, trimmed, "col")) return column_col;
    if (std.mem.eql(u8, trimmed, "col2")) return column_col2;
    if (std.mem.eql(u8, trimmed, "col3")) return column_col3;
    if (std.mem.eql(u8, trimmed, "col4")) return column_col4;
    if (std.mem.eql(u8, trimmed, "col5")) return column_col5;
    return null;
}

fn columnTemplateStart(code: u8) ?[]const u8 {
    return switch (code) {
        column_col => "{{col|en",
        column_col2 => "{{col2|en",
        column_col3 => "{{col3|en",
        column_col4 => "{{col4|en",
        column_col5 => "{{col5|en",
        else => null,
    };
}

fn lineEqualsTrimmed(line: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t"), expected);
}

fn matchTemplateArgLine(line: []const u8, name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    const open = blk: {
        var out: [64]u8 = undefined;
        const written = std.fmt.bufPrint(&out, "{{{{{s}|", .{name}) catch return null;
        break :blk written;
    };
    const plain = blk: {
        var out: [64]u8 = undefined;
        const written = std.fmt.bufPrint(&out, "{{{{{s}}}}}", .{name}) catch return null;
        break :blk written;
    };
    if (std.mem.eql(u8, trimmed, plain)) return "";
    if (!std.mem.startsWith(u8, trimmed, open) or !std.mem.endsWith(u8, trimmed, "}}")) return null;
    return trimmed[open.len .. trimmed.len - 2];
}

fn parseMappingLine(line: []const u8) ?MappingLine {
    const matched = matchLinePrefix(line) orelse return null;
    const rest = matched.rest;
    if (rest.len == 0) return null;

    if (std.mem.indexOf(u8, rest, ": ")) |colon| {
        const label = std.mem.trim(u8, rest[0..colon], " \t");
        const value = rest[colon + 2 ..];
        if (label.len == 0) return null;
        return .{
            .prefix_code = matched.code,
            .label = label,
            .value = value,
            .has_inline_value = true,
        };
    }
    if (rest[rest.len - 1] == ':') {
        const label = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
        if (label.len == 0) return null;
        return .{
            .prefix_code = matched.code,
            .label = label,
            .value = "",
            .has_inline_value = false,
        };
    }
    return null;
}

fn appendTranslationValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    var token_bytes: std.ArrayList(u8) = .empty;
    defer token_bytes.deinit(allocator);

    var token_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < value.len) {
        if (cursor + 2 <= value.len and std.mem.eql(u8, value[cursor .. cursor + 2], "{{")) {
            const end = findBalanced(value, cursor, "{{", "}}") orelse {
                try token_bytes.append(allocator, translation_raw_token);
                try appendCompactTerminated(&token_bytes, allocator, value[cursor..]);
                token_count += 1;
                break;
            };

            const template_slice = value[cursor .. end + 2];
            const body = value[cursor + 2 .. end];
            if (parseTranslationTemplate(allocator, body)) |parsed| {
                try token_bytes.append(allocator, translation_template_token);
                try token_bytes.append(allocator, parsed.name_code);
                if (parsed.name_code == template_name_raw) try appendCompactTerminated(&token_bytes, allocator, parsed.raw_name.?);
                try appendVarUInt(&token_bytes, allocator, parsed.args.len);
                for (parsed.args) |arg| try appendCompactTerminated(&token_bytes, allocator, arg);
                token_count += 1;
            } else {
                try token_bytes.append(allocator, translation_raw_token);
                try appendCompactTerminated(&token_bytes, allocator, template_slice);
                token_count += 1;
            }

            cursor = end + 2;
            continue;
        }

        const next_template = std.mem.indexOfPos(u8, value, cursor, "{{") orelse value.len;
        if (next_template > cursor) {
            try token_bytes.append(allocator, translation_raw_token);
            try appendCompactTerminated(&token_bytes, allocator, value[cursor..next_template]);
            token_count += 1;
        }
        cursor = next_template;
    }

    try appendVarUInt(out, allocator, token_count);
    try out.appendSlice(allocator, token_bytes.items);
}

fn readTranslationValueAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, limit: usize) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const token_count = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var token_index: usize = 0;
    while (token_index < token_count) : (token_index += 1) {
        if (cursor.* >= limit) return error.InvalidEncoding;
        const kind = bytes[cursor.*];
        cursor.* += 1;

        switch (kind) {
            translation_raw_token => {
                const text = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
                defer allocator.free(text);
                try out.appendSlice(allocator, text);
            },
            translation_template_token => {
                if (cursor.* >= limit) return error.InvalidEncoding;
                const name_code = bytes[cursor.*];
                cursor.* += 1;

                const name = if (name_code == template_name_raw)
                    try readCompactTerminatedAlloc(allocator, bytes, cursor, limit)
                else
                    try allocator.dupe(u8, translationTemplateName(name_code) orelse return error.InvalidEncoding);
                defer allocator.free(name);

                const arg_count = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
                try out.appendSlice(allocator, "{{");
                try out.appendSlice(allocator, name);
                var arg_index: usize = 0;
                while (arg_index < arg_count) : (arg_index += 1) {
                    const arg = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
                    defer allocator.free(arg);
                    try out.append(allocator, '|');
                    try out.appendSlice(allocator, arg);
                }
                try out.appendSlice(allocator, "}}");
            },
            else => return error.InvalidEncoding,
        }
    }

    return out.toOwnedSlice(allocator);
}

const ParsedTranslationTemplate = struct {
    name_code: u8,
    raw_name: ?[]const u8 = null,
    args: []const []const u8,
};

fn parseTranslationTemplate(allocator: std.mem.Allocator, body: []const u8) ?ParsedTranslationTemplate {
    var parts = splitTopLevel(allocator, body, '|') catch return null;
    if (parts.items.len == 0) return null;

    const raw_name = std.mem.trim(u8, parts.items[0], " \t");
    const name_code = translationTemplateCode(raw_name) orelse return null;

    return .{
        .name_code = name_code,
        .args = parts.items[1..],
    };
}

fn translationTemplateCode(name: []const u8) ?u8 {
    for (translation_templates) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.code;
    }
    return null;
}

fn translationTemplateName(code: u8) ?[]const u8 {
    for (translation_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
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

fn appendLabelRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8) !void {
    if (languageCodeForLabel(label)) |code| {
        try out.append(allocator, code);
        return;
    }

    try out.append(allocator, label_raw);
    try appendCompactTerminated(out, allocator, label);
}

fn readLabelRefAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, limit: usize) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    if (cursor.* >= limit) return error.InvalidEncoding;
    const code = bytes[cursor.*];
    cursor.* += 1;

    if (code == label_raw) return readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
    return allocator.dupe(u8, languageLabelForCode(code) orelse return error.InvalidEncoding);
}

fn languageCodeForLabel(label: []const u8) ?u8 {
    for (language_labels) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry.code;
    }
    return null;
}

fn languageLabelForCode(code: u8) ?[]const u8 {
    for (language_labels) |entry| {
        if (entry.code == code) return entry.label;
    }
    return null;
}

test "section encoding round trips headings, translations, and column terms" {
    const sample =
        \\==English==
        \\{{wikipedia|color}}
        \\===Alternative forms===
        \\* {{alt|en|colour||Commonwealth}}
        \\====Derived terms====
        \\{{col4|en
        \\|anticolor
        \\|bicolor
        \\}}
        \\===Noun===
        \\{{en-noun|s}}
        \\# {{lb|en|countable}} [[light]]
        \\#: {{ux|en|Humans see color.}}
        \\====Translations====
        \\{{trans-top|visible spectrum}}
        \\{{multitrans|data=
        \\* French: {{tt+|fr|couleur}}
        \\* Chinese:
        \\*: Mandarin: {{tt|cmn|颜色|tr=yánsè}}
        \\}}<!-- close {{multitrans}} -->
        \\{{trans-bottom}}
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeEnglishAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
}
