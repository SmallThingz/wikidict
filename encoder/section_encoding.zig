const std = @import("std");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");
const generated = @import("generated_structure_tables");

const trailing_newline_flag: u8 = 1 << 0;
const extended_ref_marker: u8 = 0xFF;
const max_inline_ref_code: u16 = 0xFE;

pub const document_ir = @import("document_ir.zig");
pub const SectionKind = document_ir.SectionKind;
pub const BlockKind = document_ir.BlockKind;
pub const InlineKind = document_ir.InlineKind;
pub const InlineSpan = document_ir.InlineSpan;
pub const TermRecordKind = document_ir.TermRecordKind;
pub const TermRecord = document_ir.TermRecord;
pub const TranslationRecordKind = document_ir.TranslationRecordKind;
pub const TranslationSeparator = document_ir.TranslationSeparator;
pub const TranslationRecord = document_ir.TranslationRecord;
pub const DecodedBlock = document_ir.DecodedBlock;
pub const InlineIterator = document_ir.InlineIterator;
pub const BlockIterator = document_ir.BlockIterator;
pub const DecodedSection = document_ir.DecodedSection;
pub const DecodedDocument = document_ir.DecodedDocument;

const heading_level_generic: u16 = 0;
const heading_level_preamble: u16 = 1;

const HeadingDef = generated.HeadingSpec;
const heading_defs = generated.heading_specs;
const HeadingLevelDef = generated.HeadingLevelSpec;
const heading_level_defs = generated.heading_level_specs;

const line_blank: u8 = 254;
const line_raw: u8 = 255;
const line_template_full: u8 = 29;
const line_template_prefixed: u8 = 30;
const line_template_full_en: u8 = 31;
const line_template_prefixed_en: u8 = 32;
const line_template_list_prefixed: u8 = 33;
const line_template_list_prefixed_en: u8 = 34;
const line_template_full_en_onearg: u8 = 35;
const line_template_prefixed_en_onearg: u8 = 36;
const line_template_list_prefixed_en_onearg: u8 = 37;

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

const JoinedBody = struct {
    // Keeps the exact blank-line shape of line-oriented sections even when the decoded text is empty.
    text: []const u8,
    line_count: usize,
};

const special_line_prefixes = [_]LinePrefix{
    .{ .code = 17, .prefix = "{{en-noun" },
    .{ .code = 18, .prefix = "{{en-verb" },
    .{ .code = 19, .prefix = "{{en-adj" },
    .{ .code = 20, .prefix = "{{en-proper noun" },
    .{ .code = 21, .prefix = "{{head|en|" },
    .{ .code = 22, .prefix = "{{plural of|" },
    .{ .code = 23, .prefix = "{{infl of|" },
    .{ .code = 24, .prefix = "{{lb|en|" },
    .{ .code = 25, .prefix = "{{IPA|en|" },
    .{ .code = 26, .prefix = "{{audio|en|" },
    .{ .code = 27, .prefix = "{{rhymes|en|" },
    .{ .code = 28, .prefix = "<references/>" },
};

const record_column_escape: u8 = 0;
const record_column_inline_base: u8 = 1;
const record_column_block_base: u8 = record_column_inline_base + (column_col5 - column_col + 1);

const trans_raw_line: u8 = 0;
const trans_top_empty: u8 = 1;
const trans_top_empty_pipe: u8 = 2;
const trans_top: u8 = 3;
const trans_check_top_empty: u8 = 4;
const trans_check_top_empty_pipe: u8 = 5;
const trans_check_top: u8 = 6;
const trans_mid: u8 = 7;
const trans_bottom: u8 = 8;
const trans_multitrans_open: u8 = 9;
const trans_multitrans_close: u8 = 10;
const trans_mapping_plain_base: u8 = 32;
const trans_mapping_inline_base: u8 = 64;
const trans_mapping_simple_base: u8 = 96;
const trans_mapping_simple_list_base: u8 = 208;

const translation_raw_token: u8 = 0;
const translation_template_token: u8 = 1;
const translation_template_langref_token: u8 = 2;
const translation_template_langref_simple_token: u8 = 3;

const template_name_raw: u16 = 0;

const TranslationTemplate = generated.TranslationTemplate;
const translation_templates = generated.translation_templates;

const LineTemplate = generated.LineTemplate;
const line_templates = generated.line_templates;

const TargetLanguage = generated.TargetLanguage;
const target_languages = generated.target_languages;

const label_raw: u16 = 0;

const LanguageLabel = generated.LanguageLabel;
const language_labels = generated.language_labels;

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
    first_line_item_count: usize,
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

const TranslationMappingSpec = struct {
    kind: enum {
        plain,
        inline_value,
        simple,
        simple_list,
    },
    prefix_code: u8,
    has_inline_value: bool,
    simple_template_variant: u8 = 0,
    separator_kind: u8 = 0,
};

const TemplateArgLine = struct {
    has_explicit_arg: bool,
    arg: []const u8,
};

const SimpleTranslationTemplate = struct {
    variant: u8,
    lang_code: u16,
    term: []const u8,
};

const SimpleTranslationTemplateList = struct {
    variant: u8,
    lang_code: u16,
    separator_kind: u8,
    terms: []const []const u8,
};

const ParsedTemplateLine = struct {
    prefix_code: ?u8 = null,
    template_code: u16,
    args: []const []const u8,
};

const TemplateLineListItem = struct {
    args: []const []const u8,
};

const ParsedTemplateLineList = struct {
    prefix_code: u8,
    template_code: u16,
    separator_kind: u8,
    include_english_arg: bool,
    items: []const TemplateLineListItem,
};

const simple_list_separator_comma: u8 = 1;
const simple_list_separator_semicolon: u8 = 2;
const simple_list_prefix_codes = [_]u8{ 13, 12 };

pub fn encodeEnglishAlloc(allocator: std.mem.Allocator, english_section: []const u8) ![]u8 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_allocator = temp_arena.allocator();

    const trailing_newline = english_section.len != 0 and english_section[english_section.len - 1] == '\n';
    const sections = splitEnglishSections(temp_allocator, english_section) catch |err| switch (err) {
        error.InvalidEnglishSection => try splitEnglishSectionsFallback(temp_allocator, english_section),
        else => return err,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, if (trailing_newline) trailing_newline_flag else 0);

    for (sections) |section| {
        const heading_level_code = headingLevelCodeForTitle(section.title, section.level);
        try appendTieredRef(&out, allocator, heading_level_code);
        const kind = kindForHeadingLevelCode(heading_level_code) orelse kindForTitle(section.title) orelse .lines;
        if (heading_level_code == heading_level_generic) {
            try out.append(allocator, section.level);
            try appendCompactSlice(&out, allocator, section.title);
            try out.append(allocator, @intFromEnum(kindForTitle(section.title) orelse .lines));
        }

        const payload = switch (kind) {
            .lines => try encodeJoinedBodyAlloc(temp_allocator, section.lines.items),
            .pos_lines => try encodeLineStreamAlloc(temp_allocator, section.lines.items),
            .term_list => try encodeTermSectionAlloc(temp_allocator, section.lines.items),
            .translations => try encodeTranslationSectionAlloc(temp_allocator, section.lines.items),
        };
        try appendBytesSlice(&out, allocator, payload);
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeDocumentAlloc(allocator: std.mem.Allocator, encoded: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})!DecodedDocument {
    if (encoded.len == 0) return error.InvalidEncoding;

    var cursor: usize = 1;
    var sections: std.ArrayList(DecodedSection) = .empty;
    errdefer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    while (cursor < encoded.len) {
        const heading_level_code = readTieredRef(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;

        const level, const title, const kind = if (heading_level_code == heading_level_generic) blk: {
            if (cursor >= encoded.len) return error.InvalidEncoding;
            const generic_level = encoded[cursor];
            cursor += 1;
            const generic_title = try readCompactSliceAlloc(allocator, encoded, &cursor, encoded.len);
            errdefer allocator.free(generic_title);
            if (cursor >= encoded.len) return error.InvalidEncoding;
            const kind_int = encoded[cursor];
            cursor += 1;
            break :blk .{
                generic_level,
                generic_title,
                sectionKindFromInt(kind_int) orelse return error.InvalidEncoding,
            };
        } else if (heading_level_code == heading_level_preamble) blk: {
            break :blk .{
                @as(u8, 0),
                try allocator.dupe(u8, ""),
                SectionKind.lines,
            };
        } else blk: {
            const def = headingLevelDefForCode(heading_level_code) orelse return error.InvalidEncoding;
            break :blk .{
                def.level,
                try allocator.dupe(u8, def.title),
                documentSectionKind(def.kind),
            };
        };
        errdefer allocator.free(title);

        const payload = readLengthPrefixedSlice(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;
        const term_records: ?[]TermRecord = if (kind == .term_list)
            try decodeTermRecordsAlloc(allocator, payload)
        else
            null;
        errdefer if (term_records) |records| deinitTermRecords(allocator, records);
        const translation_records: ?[]TranslationRecord = if (kind == .translations)
            try decodeTranslationRecordsAlloc(allocator, payload)
        else
            null;
        errdefer if (translation_records) |records| deinitTranslationRecords(allocator, records);

        var body: []const u8 = undefined;
        var line_count: usize = 0;
        if (kind == .lines) {
            const joined = try decodeJoinedBodyAlloc(allocator, payload);
            body = joined.text;
            line_count = joined.line_count;
        } else {
            body = switch (kind) {
                .pos_lines => try decodeLineStreamAlloc(allocator, payload),
                .term_list => try renderTermRecordsAlloc(allocator, term_records.?),
                .translations => try renderTranslationRecordsAlloc(allocator, translation_records.?),
                .lines => unreachable,
            };
            if (body.len != 0) {
                line_count = 1;
                for (body) |byte| if (byte == '\n') {
                    line_count += 1;
                };
            }
        }
        errdefer allocator.free(body);

        try sections.append(allocator, .{
            .level = level,
            .title = title,
            .kind = kind,
            .body = body,
            .line_count = line_count,
            .term_records = term_records,
            .translation_records = translation_records,
        });
    }

    return .{
        .trailing_newline = (encoded[0] & trailing_newline_flag) != 0,
        .sections = try sections.toOwnedSlice(allocator),
    };
}

pub fn decodeEnglishAlloc(allocator: std.mem.Allocator, encoded: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    if (encoded.len == 0) return error.InvalidEncoding;

    var cursor: usize = 0;
    const flags = encoded[cursor];
    cursor += 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "==English==");

    while (cursor < encoded.len) {
        const heading_level_code = readTieredRef(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;

        const level, const title, const kind = if (heading_level_code == heading_level_generic) blk: {
            if (cursor >= encoded.len) return error.InvalidEncoding;
            const generic_level = encoded[cursor];
            cursor += 1;
            const generic_title = try readCompactSliceAlloc(allocator, encoded, &cursor, encoded.len);
            if (cursor >= encoded.len) return error.InvalidEncoding;
            const kind_int = encoded[cursor];
            cursor += 1;
            break :blk .{
                generic_level,
                generic_title,
                sectionKindFromInt(kind_int) orelse return error.InvalidEncoding,
            };
        } else if (heading_level_code == heading_level_preamble) blk: {
            break :blk .{
                @as(u8, 0),
                try allocator.dupe(u8, ""),
                SectionKind.lines,
            };
        } else blk: {
            const def = headingLevelDefForCode(heading_level_code) orelse return error.InvalidEncoding;
            break :blk .{
                def.level,
                try allocator.dupe(u8, def.title),
                documentSectionKind(def.kind),
            };
        };
        defer allocator.free(title);

        const payload = readLengthPrefixedSlice(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;
        if (kind == .lines) {
            const body = try decodeJoinedBodyAlloc(allocator, payload);
            defer allocator.free(body.text);

            if (level != 0 and heading_level_code != heading_level_preamble) {
                try out.append(allocator, '\n');
                try appendHeadingLine(&out, allocator, level, title);
            }
            if (body.line_count != 0) {
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, body.text);
            }
            continue;
        }

        const body = switch (kind) {
            .pos_lines => try decodeLineStreamAlloc(allocator, payload),
            .term_list => try decodeTermSectionAlloc(allocator, payload),
            .translations => try decodeTranslationSectionAlloc(allocator, payload),
            .lines => unreachable,
        };
        defer allocator.free(body);

        if (level == 0 or heading_level_code == heading_level_preamble) {
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

fn encodeJoinedBodyAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    if (lines.len == 0) return allocator.alloc(u8, 0);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    for (lines, 0..) |line, idx| {
        if (idx != 0) try joined.append(allocator, '\n');
        try joined.appendSlice(allocator, line);
    }

    if (joined.items.len == 0) {
        return allocator.dupe(u8, &[_]u8{0});
    }

    return compact.encodeAlloc(allocator, joined.items);
}

fn encodeLineStreamAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (lines) |line| try appendEncodedLine(&out, allocator, line);
    return out.toOwnedSlice(allocator);
}

fn decodeLineStreamAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var cursor: usize = 0;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var first = true;
    while (cursor < payload.len) {
        if (!first) try out.append(allocator, '\n');
        const line = try decodeEncodedLineAlloc(allocator, payload, &cursor, payload.len);
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        first = false;
    }

    return out.toOwnedSlice(allocator);
}

fn decodeJoinedBodyAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})!JoinedBody {
    if (payload.len == 0) {
        return .{
            .text = try allocator.alloc(u8, 0),
            .line_count = 0,
        };
    }
    if (payload.len == 1 and payload[0] == 0) {
        return .{
            .text = try allocator.alloc(u8, 0),
            .line_count = 1,
        };
    }

    const text = compact.decodeAlloc(allocator, payload) catch return error.InvalidEncoding;
    errdefer allocator.free(text);
    if (text.len == 0) return error.InvalidEncoding;

    var line_count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') line_count += 1;
    }

    return .{
        .text = text,
        .line_count = line_count,
    };
}

fn encodeTermSectionAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) {
        if (parseInlineColumnTemplate(allocator, lines[i])) |column_inline| {
            try out.append(allocator, record_column_escape);
            try out.append(allocator, columnInlineRecordCode(column_inline.template_code) orelse return error.InvalidEncoding);
            try appendVarUInt(&out, allocator, column_inline.items.len);
            for (column_inline.items) |item| try appendCompactTerminated(&out, allocator, item);
            i += 1;
            continue;
        }

        if (parseColumnBlock(allocator, lines[i..])) |block| {
            try out.append(allocator, record_column_escape);
            try out.append(allocator, columnBlockRecordCode(block.template_code) orelse return error.InvalidEncoding);
            try appendVarUInt(&out, allocator, block.first_line_item_count);
            try appendVarUInt(&out, allocator, block.item_count);
            for (block.items[0..block.item_count]) |item| try appendCompactTerminated(&out, allocator, item);
            i += block.consumed;
            continue;
        }

        try appendEncodedLine(&out, allocator, lines[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn decodeTermRecordsAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]TermRecord {
    var cursor: usize = 0;
    var records: std.ArrayList(TermRecord) = .empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    while (cursor < payload.len) {
        if (payload[cursor] != record_column_escape) {
            const line = try decodeEncodedLineAlloc(allocator, payload, &cursor, payload.len);
            errdefer allocator.free(line);
            try records.append(allocator, .{ .kind = .line, .text = line });
            continue;
        }

        cursor += 1;
        if (cursor >= payload.len) return error.InvalidEncoding;
        const record_code = payload[cursor];
        const inline_template_code = columnTemplateCodeForInlineRecord(record_code);
        const block_template_code = columnTemplateCodeForBlockRecord(record_code);
        const template_code = inline_template_code orelse block_template_code orelse return error.InvalidEncoding;
        const block_layout = block_template_code != null;
        cursor += 1;
        const first_line_item_count = if (block_layout)
            format.readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding
        else
            0;
        const item_count_u64 = format.readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
        const item_count = std.math.cast(usize, item_count_u64) orelse return error.InvalidEncoding;
        const items = try allocator.alloc([]const u8, item_count);
        var decoded_items: usize = 0;
        errdefer {
            for (items[0..decoded_items]) |item| allocator.free(item);
            allocator.free(items);
        }
        while (decoded_items < item_count) : (decoded_items += 1) {
            items[decoded_items] = try readCompactTerminatedAlloc(allocator, payload, &cursor, payload.len);
        }
        try records.append(allocator, .{
            .kind = .column,
            .columns = if (template_code == column_col) null else template_code,
            .block_layout = block_layout,
            .first_line_item_count = first_line_item_count,
            .items = items,
        });
    }

    return records.toOwnedSlice(allocator);
}

fn deinitTermRecords(allocator: std.mem.Allocator, records: []TermRecord) void {
    for (records) |*record| record.deinit(allocator);
    allocator.free(records);
}

fn renderTermRecordsAlloc(allocator: std.mem.Allocator, records: []const TermRecord) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (records, 0..) |record, record_index| {
        if (record_index != 0) try out.append(allocator, '\n');
        switch (record.kind) {
            .line => try out.appendSlice(allocator, record.text),
            .column => {
                const template_code = record.columns orelse column_col;
                try out.appendSlice(allocator, columnTemplateStart(template_code) orelse return error.InvalidEncoding);
                for (record.items, 0..) |item, item_index| {
                    if (!record.block_layout or item_index < record.first_line_item_count) {
                        try out.append(allocator, '|');
                    } else {
                        try out.appendSlice(allocator, "\n|");
                    }
                    try out.appendSlice(allocator, item);
                }
                if (record.block_layout) {
                    try out.appendSlice(allocator, "\n}}");
                } else {
                    try out.appendSlice(allocator, "}}");
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn decodeTermSectionAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const records = try decodeTermRecordsAlloc(allocator, payload);
    defer deinitTermRecords(allocator, records);
    return renderTermRecordsAlloc(allocator, records);
}

fn encodeTranslationSectionAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (lines) |line| {
        if (matchTemplateArgLine(line, "trans-top")) |template_arg| {
            if (template_arg.arg.len == 0) {
                try out.append(allocator, if (template_arg.has_explicit_arg) trans_top_empty_pipe else trans_top_empty);
            } else {
                try out.append(allocator, trans_top);
                try appendCompactTerminated(&out, allocator, template_arg.arg);
            }
            continue;
        }
        if (matchTemplateArgLine(line, "checktrans-top")) |template_arg| {
            if (template_arg.arg.len == 0) {
                try out.append(allocator, if (template_arg.has_explicit_arg) trans_check_top_empty_pipe else trans_check_top_empty);
            } else {
                try out.append(allocator, trans_check_top);
                try appendCompactTerminated(&out, allocator, template_arg.arg);
            }
            continue;
        }
        if (lineEqualsTrimmed(line, "{{trans-mid}}")) {
            try out.append(allocator, trans_mid);
            continue;
        }
        if (lineEqualsTrimmed(line, "{{trans-bottom}}")) {
            try out.append(allocator, trans_bottom);
            continue;
        }
        if (lineEqualsTrimmed(line, "{{multitrans|data=")) {
            try out.append(allocator, trans_multitrans_open);
            continue;
        }
        if (lineEqualsTrimmed(line, "}}<!-- close {{multitrans}} -->")) {
            try out.append(allocator, trans_multitrans_close);
            continue;
        }
        if (parseMappingLine(line)) |mapping| {
            if (mapping.has_inline_value) {
                if (parseSimpleTranslationTemplateList(allocator, mapping.value)) |list| {
                    if (simpleTranslationListRecordCode(mapping.prefix_code, list.variant, list.separator_kind)) |record_code| {
                        try out.append(allocator, record_code);
                        try appendLabelRef(&out, allocator, mapping.label);
                        try appendTieredRef(&out, allocator, list.lang_code);
                        try appendVarUInt(&out, allocator, list.terms.len);
                        for (list.terms) |term| try appendCompactTerminated(&out, allocator, term);
                        continue;
                    }
                }
                if (parseSimpleTranslationTemplate(allocator, mapping.value)) |simple| {
                    try out.append(allocator, simpleTranslationMappingRecordCode(mapping.prefix_code, simple.variant) orelse return error.InvalidEncoding);
                    try appendLabelRef(&out, allocator, mapping.label);
                    try appendTieredRef(&out, allocator, simple.lang_code);
                    try appendCompactTerminated(&out, allocator, simple.term);
                    continue;
                }
            }
            try out.append(allocator, translationMappingRecordCode(mapping.prefix_code, mapping.has_inline_value) orelse return error.InvalidEncoding);
            try appendLabelRef(&out, allocator, mapping.label);
            if (mapping.has_inline_value) try appendTranslationValue(&out, allocator, mapping.value);
            continue;
        }

        try out.append(allocator, trans_raw_line);
        try appendEncodedLine(&out, allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

fn decodeTranslationRecordsAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]TranslationRecord {
    var cursor: usize = 0;
    var records: std.ArrayList(TranslationRecord) = .empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    while (cursor < payload.len) {
        var record = try decodeTranslationRecordAlloc(allocator, payload, &cursor);
        records.append(allocator, record) catch |err| {
            record.deinit(allocator);
            return err;
        };
    }
    return records.toOwnedSlice(allocator);
}

fn decodeTranslationRecordAlloc(allocator: std.mem.Allocator, payload: []const u8, cursor: *usize) (std.mem.Allocator.Error || error{InvalidEncoding})!TranslationRecord {
    if (cursor.* >= payload.len) return error.InvalidEncoding;
    const record_code = payload[cursor.*];
    cursor.* += 1;

    switch (record_code) {
        trans_raw_line => return .{
            .kind = .raw_line,
            .text = try decodeEncodedLineAlloc(allocator, payload, cursor, payload.len),
        },
        trans_top, trans_check_top => return .{
            .kind = .group_start,
            .text = try readCompactTerminatedAlloc(allocator, payload, cursor, payload.len),
            .check = record_code == trans_check_top,
        },
        trans_top_empty, trans_top_empty_pipe, trans_check_top_empty, trans_check_top_empty_pipe => return .{
            .kind = .group_start,
            .check = record_code == trans_check_top_empty or record_code == trans_check_top_empty_pipe,
            .explicit_empty = record_code == trans_top_empty_pipe or record_code == trans_check_top_empty_pipe,
        },
        trans_mid => return .{ .kind = .group_mid },
        trans_bottom => return .{ .kind = .group_end },
        trans_multitrans_open => return .{ .kind = .multitrans_start },
        trans_multitrans_close => return .{ .kind = .multitrans_end },
        else => {},
    }

    const mapping_spec = translationMappingSpec(record_code) orelse return error.InvalidEncoding;
    const label = try readLabelRefAlloc(allocator, payload, cursor, payload.len);
    errdefer allocator.free(label);
    const source_prefix = prefixForCode(mapping_spec.prefix_code) orelse return error.InvalidEncoding;
    const block = document_ir.classifyLine(source_prefix);

    if (mapping_spec.kind == .simple) {
        const lang_code = readTieredRef(payload, cursor, payload.len) catch return error.InvalidEncoding;
        const language = targetLanguageValueForCode(lang_code) orelse return error.InvalidEncoding;
        const term = try readCompactTerminatedAlloc(allocator, payload, cursor, payload.len);
        errdefer allocator.free(term);
        const terms = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(terms);
        terms[0] = term;
        return .{
            .kind = .mapping,
            .block_kind = block.kind,
            .depth = block.depth,
            .source_prefix = source_prefix,
            .label = label,
            .language = language,
            .template_name = simpleTranslationTemplateName(mapping_spec.simple_template_variant) orelse return error.InvalidEncoding,
            .terms = terms,
        };
    }

    if (mapping_spec.kind == .simple_list) {
        const lang_code = readTieredRef(payload, cursor, payload.len) catch return error.InvalidEncoding;
        const language = targetLanguageValueForCode(lang_code) orelse return error.InvalidEncoding;
        const term_count_u64 = format.readVarUInt(payload, cursor, payload.len) catch return error.InvalidEncoding;
        const term_count = std.math.cast(usize, term_count_u64) orelse return error.InvalidEncoding;
        const terms = try allocator.alloc([]const u8, term_count);
        var decoded_terms: usize = 0;
        errdefer {
            for (terms[0..decoded_terms]) |term| allocator.free(term);
            allocator.free(terms);
        }
        while (decoded_terms < term_count) : (decoded_terms += 1) {
            terms[decoded_terms] = try readCompactTerminatedAlloc(allocator, payload, cursor, payload.len);
        }
        return .{
            .kind = .mapping,
            .block_kind = block.kind,
            .depth = block.depth,
            .source_prefix = source_prefix,
            .label = label,
            .language = language,
            .template_name = simpleTranslationTemplateName(mapping_spec.simple_template_variant) orelse return error.InvalidEncoding,
            .terms = terms,
            .separator = translationSeparatorFromKind(mapping_spec.separator_kind) orelse return error.InvalidEncoding,
        };
    }

    if (mapping_spec.has_inline_value) {
        const value = try readTranslationValueAlloc(allocator, payload, cursor, payload.len);
        errdefer allocator.free(value);
        return .{
            .kind = .mapping,
            .block_kind = block.kind,
            .depth = block.depth,
            .source_prefix = source_prefix,
            .text = value,
            .label = label,
        };
    }

    return .{
        .kind = .mapping,
        .block_kind = block.kind,
        .depth = block.depth,
        .source_prefix = source_prefix,
        .label = label,
    };
}

fn translationSeparatorFromKind(kind: u8) ?TranslationSeparator {
    return switch (kind) {
        simple_list_separator_comma => .comma,
        simple_list_separator_semicolon => .semicolon,
        else => null,
    };
}

fn translationSeparatorText(separator: TranslationSeparator) ?[]const u8 {
    return switch (separator) {
        .comma => ", ",
        .semicolon => "; ",
        .none => null,
    };
}

fn renderTranslationRecordsAlloc(allocator: std.mem.Allocator, records: []const TranslationRecord) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (records, 0..) |record, record_index| {
        if (record_index != 0) try out.append(allocator, '\n');
        switch (record.kind) {
            .raw_line => try out.appendSlice(allocator, record.text orelse return error.InvalidEncoding),
            .group_start => {
                try out.appendSlice(allocator, if (record.check) "{{checktrans-top" else "{{trans-top");
                if (record.text) |gloss| {
                    try out.append(allocator, '|');
                    try out.appendSlice(allocator, gloss);
                } else if (record.explicit_empty) {
                    try out.append(allocator, '|');
                }
                try out.appendSlice(allocator, "}}");
            },
            .group_mid => try out.appendSlice(allocator, "{{trans-mid}}"),
            .group_end => try out.appendSlice(allocator, "{{trans-bottom}}"),
            .multitrans_start => try out.appendSlice(allocator, "{{multitrans|data="),
            .multitrans_end => try out.appendSlice(allocator, "}}<!-- close {{multitrans}} -->"),
            .mapping => {
                try out.appendSlice(allocator, record.source_prefix);
                try out.appendSlice(allocator, record.label orelse return error.InvalidEncoding);
                if (record.language) |language| {
                    const template_name = record.template_name orelse return error.InvalidEncoding;
                    try out.appendSlice(allocator, ": ");
                    for (record.terms, 0..) |term, term_index| {
                        if (term_index != 0) {
                            try out.appendSlice(allocator, translationSeparatorText(record.separator) orelse return error.InvalidEncoding);
                        }
                        try out.appendSlice(allocator, "{{");
                        try out.appendSlice(allocator, template_name);
                        try out.append(allocator, '|');
                        try out.appendSlice(allocator, language);
                        try out.append(allocator, '|');
                        try out.appendSlice(allocator, term);
                        try out.appendSlice(allocator, "}}");
                    }
                } else if (record.text) |value| {
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, value);
                } else {
                    try out.append(allocator, ':');
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn deinitTranslationRecords(allocator: std.mem.Allocator, records: []TranslationRecord) void {
    for (records) |*record| record.deinit(allocator);
    allocator.free(records);
}

fn decodeTranslationSectionAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const records = try decodeTranslationRecordsAlloc(allocator, payload);
    defer deinitTranslationRecords(allocator, records);
    return renderTranslationRecordsAlloc(allocator, records);
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
            if (heading.level >= 3 and isCanonicalHeadingLine(line, heading)) {
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

fn splitEnglishSectionsFallback(allocator: std.mem.Allocator, english_section: []const u8) ![]SectionSource {
    var sections: std.ArrayList(SectionSource) = .empty;
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit(allocator);
    }

    try sections.append(allocator, .{
        .level = 0,
        .title = try allocator.dupe(u8, ""),
    });

    const body_start = bodyStartAfterEnglishHeading(english_section) orelse 0;
    var current: *SectionSource = &sections.items[0];
    var line_start: usize = body_start;
    while (line_start < english_section.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, english_section, line_start, '\n') orelse english_section.len;
        const line = std.mem.trimEnd(u8, english_section[line_start..next_newline], "\r");
        try current.lines.append(allocator, line);
        line_start = if (next_newline == english_section.len) english_section.len else next_newline + 1;
    }

    return sections.toOwnedSlice(allocator);
}

fn bodyStartAfterEnglishHeading(english_section: []const u8) ?usize {
    const first_line_end = std.mem.indexOfScalar(u8, english_section, '\n') orelse english_section.len;
    const first_line = std.mem.trimEnd(u8, english_section[0..first_line_end], "\r");
    const heading = parseHeading(first_line) orelse return null;
    if (heading.level != 2 or !std.mem.eql(u8, heading.title, "English")) return null;
    return if (first_line_end == english_section.len) english_section.len else first_line_end + 1;
}

fn appendEncodedLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    if (line.len == 0) {
        try out.append(allocator, line_blank);
        return;
    }

    if (parseExactTemplateLineList(allocator, line)) |parsed| {
        const use_english_onearg = parsed.include_english_arg and blk: {
            for (parsed.items) |item| {
                if (item.args.len != 2) break :blk false;
            }
            break :blk true;
        };
        try out.append(allocator, if (use_english_onearg) line_template_list_prefixed_en_onearg else if (parsed.include_english_arg) line_template_list_prefixed_en else line_template_list_prefixed);
        try out.append(allocator, parsed.prefix_code);
        try appendTieredRef(out, allocator, parsed.template_code);
        try out.append(allocator, parsed.separator_kind);
        try appendVarUInt(out, allocator, parsed.items.len);
        for (parsed.items) |item| {
            const stored_args = if (parsed.include_english_arg) item.args[1..] else item.args;
            if (use_english_onearg) {
                try appendCompactTerminated(out, allocator, stored_args[0]);
            } else {
                try appendVarUInt(out, allocator, stored_args.len);
                for (stored_args) |arg| try appendCompactTerminated(out, allocator, arg);
            }
        }
        return;
    }

    if (parseExactTemplateLine(allocator, line)) |parsed| {
        const use_english_arg = parsed.args.len != 0 and std.mem.eql(u8, parsed.args[0], "en");
        const use_english_onearg = use_english_arg and parsed.args.len == 2;
        try out.append(allocator, switch (parsed.prefix_code == null) {
            true => if (use_english_onearg) line_template_full_en_onearg else if (use_english_arg) line_template_full_en else line_template_full,
            false => if (use_english_onearg) line_template_prefixed_en_onearg else if (use_english_arg) line_template_prefixed_en else line_template_prefixed,
        });
        if (parsed.prefix_code) |prefix_code| try out.append(allocator, prefix_code);
        try appendTieredRef(out, allocator, parsed.template_code);
        const stored_args = if (use_english_arg) parsed.args[1..] else parsed.args;
        if (use_english_onearg) {
            try appendCompactTerminated(out, allocator, stored_args[0]);
        } else {
            try appendVarUInt(out, allocator, stored_args.len);
            for (stored_args) |arg| try appendCompactTerminated(out, allocator, arg);
        }
        return;
    }

    if (matchSpecialLinePrefix(line)) |matched| {
        try out.append(allocator, matched.code);
        try appendCompactTerminated(out, allocator, matched.rest);
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
    if (code == line_template_list_prefixed or code == line_template_list_prefixed_en or code == line_template_list_prefixed_en_onearg) {
        if (cursor.* >= limit) return error.InvalidEncoding;
        const prefix_code = bytes[cursor.*];
        cursor.* += 1;
        const prefix = prefixForCode(prefix_code) orelse return error.InvalidEncoding;
        const template_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;
        const template_name = lineTemplateName(template_code) orelse return error.InvalidEncoding;
        if (cursor.* >= limit) return error.InvalidEncoding;
        const separator_kind = bytes[cursor.*];
        cursor.* += 1;
        const separator = simpleListSeparatorText(separator_kind) orelse return error.InvalidEncoding;
        const item_count = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
        const include_english_arg = code == line_template_list_prefixed_en or code == line_template_list_prefixed_en_onearg;
        const include_english_onearg = code == line_template_list_prefixed_en_onearg;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, prefix);

        var item_index: usize = 0;
        while (item_index < item_count) : (item_index += 1) {
            if (item_index != 0) try out.appendSlice(allocator, separator);
            try out.appendSlice(allocator, "{{");
            try out.appendSlice(allocator, template_name);
            if (include_english_arg) try out.appendSlice(allocator, "|en");

            if (include_english_onearg) {
                const arg = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
                defer allocator.free(arg);
                try out.append(allocator, '|');
                try out.appendSlice(allocator, arg);
            } else {
                const arg_count = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
                var arg_index: usize = 0;
                while (arg_index < arg_count) : (arg_index += 1) {
                    const arg = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
                    defer allocator.free(arg);
                    try out.append(allocator, '|');
                    try out.appendSlice(allocator, arg);
                }
            }
            try out.appendSlice(allocator, "}}");
        }

        return out.toOwnedSlice(allocator);
    }

    if (code == line_template_full or code == line_template_prefixed or code == line_template_full_en or code == line_template_prefixed_en or code == line_template_full_en_onearg or code == line_template_prefixed_en_onearg) {
        const prefix = if (code == line_template_prefixed or code == line_template_prefixed_en or code == line_template_prefixed_en_onearg) blk: {
            if (cursor.* >= limit) return error.InvalidEncoding;
            const prefix_code = bytes[cursor.*];
            cursor.* += 1;
            break :blk prefixForCode(prefix_code) orelse return error.InvalidEncoding;
        } else "";

        const template_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;
        const template_name = lineTemplateName(template_code) orelse return error.InvalidEncoding;
        const include_english_arg = code == line_template_full_en or code == line_template_prefixed_en or code == line_template_full_en_onearg or code == line_template_prefixed_en_onearg;
        const include_english_onearg = code == line_template_full_en_onearg or code == line_template_prefixed_en_onearg;
        const arg_count = if (include_english_onearg)
            @as(u64, 1)
        else
            format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, "{{");
        try out.appendSlice(allocator, template_name);

        if (include_english_arg) try out.appendSlice(allocator, "|en");

        var arg_index: usize = 0;
        while (arg_index < arg_count) : (arg_index += 1) {
            const arg = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
            defer allocator.free(arg);
            try out.append(allocator, '|');
            try out.appendSlice(allocator, arg);
        }

        try out.appendSlice(allocator, "}}");
        return out.toOwnedSlice(allocator);
    }

    const prefix = specialLinePrefixForCode(code) orelse prefixForCode(code) orelse return error.InvalidEncoding;
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

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendTieredRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, code: u16) !void {
    if (code <= max_inline_ref_code) {
        try out.append(allocator, @intCast(code));
        return;
    }
    try out.append(allocator, extended_ref_marker);
    try appendU16(out, allocator, code);
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

fn readU16(bytes: []const u8, cursor: *usize, limit: usize) error{InvalidEncoding}!u16 {
    if (cursor.* > limit or 2 > limit - cursor.*) return error.InvalidEncoding;
    const value = std.mem.readInt(u16, bytes[cursor.* .. cursor.* + 2][0..2], .little);
    cursor.* += 2;
    return value;
}

fn readTieredRef(bytes: []const u8, cursor: *usize, limit: usize) error{InvalidEncoding}!u16 {
    if (cursor.* >= limit) return error.InvalidEncoding;
    const first = bytes[cursor.*];
    cursor.* += 1;
    if (first != extended_ref_marker) return first;
    return readU16(bytes, cursor, limit);
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

fn headingLevelCodeForTitle(title: []const u8, level: u8) u16 {
    if (level == 0 and title.len == 0) return heading_level_preamble;
    for (heading_level_defs) |def| {
        if (def.level == level and std.mem.eql(u8, def.title, title)) return def.code;
    }
    return heading_level_generic;
}

fn headingLevelDefForCode(code: u16) ?HeadingLevelDef {
    for (heading_level_defs) |def| {
        if (def.code == code) return def;
    }
    return null;
}

fn kindForHeadingLevelCode(code: u16) ?SectionKind {
    if (code == heading_level_preamble) return .lines;
    const def = headingLevelDefForCode(code) orelse return null;
    return documentSectionKind(def.kind);
}

fn kindForTitle(title: []const u8) ?SectionKind {
    for (heading_defs) |def| {
        if (std.mem.eql(u8, def.title, title)) return documentSectionKind(def.kind);
    }
    return null;
}

fn documentSectionKind(kind: generated.SectionKind) SectionKind {
    return @enumFromInt(@intFromEnum(kind));
}

comptime {
    if (@intFromEnum(generated.SectionKind.lines) != @intFromEnum(SectionKind.lines) or
        @intFromEnum(generated.SectionKind.pos_lines) != @intFromEnum(SectionKind.pos_lines) or
        @intFromEnum(generated.SectionKind.term_list) != @intFromEnum(SectionKind.term_list) or
        @intFromEnum(generated.SectionKind.translations) != @intFromEnum(SectionKind.translations))
    {
        @compileError("generated and renderer section kinds must stay byte-compatible");
    }
}

fn sectionKindFromInt(value: u8) ?SectionKind {
    return switch (value) {
        @intFromEnum(SectionKind.lines) => .lines,
        @intFromEnum(SectionKind.pos_lines) => .pos_lines,
        @intFromEnum(SectionKind.term_list) => .term_list,
        @intFromEnum(SectionKind.translations) => .translations,
        else => null,
    };
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

fn matchSpecialLinePrefix(line: []const u8) ?MatchedPrefix {
    var best: ?MatchedPrefix = null;
    var best_len: usize = 0;
    for (special_line_prefixes) |prefix| {
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

fn specialLinePrefixForCode(code: u8) ?[]const u8 {
    for (special_line_prefixes) |prefix| {
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

fn parseExactTemplateLine(allocator: std.mem.Allocator, line: []const u8) ?ParsedTemplateLine {
    if (matchLinePrefix(line)) |matched| {
        const parsed = parseExactTemplateBody(allocator, matched.rest) orelse return null;
        return .{
            .prefix_code = matched.code,
            .template_code = parsed.template_code,
            .args = parsed.args,
        };
    }

    return parseExactTemplateBody(allocator, line);
}

fn parseExactTemplateLineList(allocator: std.mem.Allocator, line: []const u8) ?ParsedTemplateLineList {
    const matched = matchLinePrefix(line) orelse return null;

    const Separator = struct {
        kind: u8,
        text: []const u8,
    };
    const separator: Separator = blk: {
        if (std.mem.indexOf(u8, matched.rest, ", ") != null) break :blk .{ .kind = simple_list_separator_comma, .text = ", " };
        if (std.mem.indexOf(u8, matched.rest, "; ") != null) break :blk .{ .kind = simple_list_separator_semicolon, .text = "; " };
        return null;
    };

    const parts = splitTopLevelString(allocator, matched.rest, separator.text) catch return null;
    if (parts.items.len < 2) return null;

    const items = allocator.alloc(TemplateLineListItem, parts.items.len) catch return null;

    var first_template_code: ?u16 = null;
    var include_english_arg = true;
    for (parts.items, 0..) |part, idx| {
        const parsed = parseExactTemplateBody(allocator, part) orelse return null;
        if (first_template_code == null) {
            first_template_code = parsed.template_code;
        } else if (first_template_code.? != parsed.template_code) {
            return null;
        }

        if (parsed.args.len == 0 or !std.mem.eql(u8, parsed.args[0], "en")) include_english_arg = false;
        items[idx] = .{ .args = parsed.args };
    }

    return .{
        .prefix_code = matched.code,
        .template_code = first_template_code.?,
        .separator_kind = separator.kind,
        .include_english_arg = include_english_arg,
        .items = items,
    };
}

fn parseExactTemplateBody(allocator: std.mem.Allocator, line: []const u8) ?ParsedTemplateLine {
    if (!std.mem.eql(u8, line, std.mem.trim(u8, line, " \t"))) return null;
    if (line.len < 4 or !std.mem.startsWith(u8, line, "{{") or !std.mem.endsWith(u8, line, "}}")) return null;

    const body = line[2 .. line.len - 2];
    const parts = splitTopLevelRaw(allocator, body, '|') catch return null;
    if (parts.items.len == 0) return null;

    return .{
        .template_code = lineTemplateCode(parts.items[0]) orelse return null,
        .args = parts.items[1..],
    };
}

fn parseColumnBlock(allocator: std.mem.Allocator, lines: []const []const u8) ?ColumnBlock {
    if (lines.len == 0) return null;

    const first_trimmed = std.mem.trim(u8, lines[0], " \t");
    if (!std.mem.startsWith(u8, first_trimmed, "{{")) return null;

    const first_body = first_trimmed[2..];
    const first_parts = splitTopLevelRaw(allocator, first_body, '|') catch return null;
    if (first_parts.items.len < 2) return null;

    const template_code = inlineColumnTemplateCode(first_parts.items[0]) orelse return null;
    if (!std.mem.eql(u8, first_parts.items[1], "en")) return null;

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
        items[write_index] = item;
        write_index += 1;
    }
    for (extra_items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        items[write_index] = trimmed[1..];
        write_index += 1;
    }

    return .{
        .template_code = template_code,
        .first_line_item_count = initial_items.len,
        .item_count = item_count,
        .consumed = end_index + 1,
        .items = items,
    };
}

fn parseInlineColumnTemplate(allocator: std.mem.Allocator, line: []const u8) ?ColumnInline {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return null;

    const body = trimmed[2 .. trimmed.len - 2];
    const parts = splitTopLevelRaw(allocator, body, '|') catch return null;
    if (parts.items.len < 2) return null;

    const template_code = inlineColumnTemplateCode(parts.items[0]) orelse return null;
    if (!std.mem.eql(u8, parts.items[1], "en")) return null;

    return .{
        .template_code = template_code,
        .items = parts.items[2..],
    };
}

fn inlineColumnTemplateCode(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "col")) return column_col;
    if (std.mem.eql(u8, name, "col2")) return column_col2;
    if (std.mem.eql(u8, name, "col3")) return column_col3;
    if (std.mem.eql(u8, name, "col4")) return column_col4;
    if (std.mem.eql(u8, name, "col5")) return column_col5;
    return null;
}

fn columnInlineRecordCode(template_code: u8) ?u8 {
    if (template_code < column_col or template_code > column_col5) return null;
    return record_column_inline_base + (template_code - column_col);
}

fn columnBlockRecordCode(template_code: u8) ?u8 {
    if (template_code < column_col or template_code > column_col5) return null;
    return record_column_block_base + (template_code - column_col);
}

fn columnTemplateCodeForInlineRecord(record_code: u8) ?u8 {
    if (record_code < record_column_inline_base or record_code > record_column_inline_base + (column_col5 - column_col)) return null;
    return column_col + (record_code - record_column_inline_base);
}

fn columnTemplateCodeForBlockRecord(record_code: u8) ?u8 {
    if (record_code < record_column_block_base or record_code > record_column_block_base + (column_col5 - column_col)) return null;
    return column_col + (record_code - record_column_block_base);
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

fn matchTemplateArgLine(line: []const u8, name: []const u8) ?TemplateArgLine {
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
    if (std.mem.eql(u8, trimmed, plain)) {
        return .{
            .has_explicit_arg = false,
            .arg = "",
        };
    }
    if (!std.mem.startsWith(u8, trimmed, open) or !std.mem.endsWith(u8, trimmed, "}}")) return null;
    return .{
        .has_explicit_arg = true,
        .arg = trimmed[open.len .. trimmed.len - 2],
    };
}

fn parseMappingLine(line: []const u8) ?MappingLine {
    const matched = matchLinePrefix(line) orelse return null;
    const rest = matched.rest;
    if (rest.len == 0) return null;

    if (std.mem.indexOf(u8, rest, ": ")) |colon| {
        const label = rest[0..colon];
        if (!std.mem.eql(u8, label, std.mem.trim(u8, label, " \t"))) return null;
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
        const label = rest[0 .. rest.len - 1];
        if (!std.mem.eql(u8, label, std.mem.trim(u8, label, " \t"))) return null;
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

fn translationMappingRecordCode(prefix_code: u8, has_inline_value: bool) ?u8 {
    if (prefixForCode(prefix_code) == null) return null;
    return (if (has_inline_value) trans_mapping_inline_base else trans_mapping_plain_base) + prefix_code;
}

fn translationMappingSpec(record_code: u8) ?TranslationMappingSpec {
    if (record_code > trans_mapping_plain_base and record_code <= trans_mapping_plain_base + line_prefixes.len) {
        return .{
            .kind = .plain,
            .prefix_code = record_code - trans_mapping_plain_base,
            .has_inline_value = false,
        };
    }
    if (record_code > trans_mapping_inline_base and record_code <= trans_mapping_inline_base + line_prefixes.len) {
        return .{
            .kind = .inline_value,
            .prefix_code = record_code - trans_mapping_inline_base,
            .has_inline_value = true,
        };
    }
    if (record_code >= trans_mapping_simple_base and record_code < trans_mapping_simple_base + (simple_translation_template_variant_count * line_prefixes.len)) {
        const delta: u8 = record_code - trans_mapping_simple_base;
        return .{
            .kind = .simple,
            .prefix_code = @intCast((delta % line_prefixes.len) + 1),
            .has_inline_value = true,
            .simple_template_variant = @intCast((delta / line_prefixes.len) + 1),
        };
    }
    if (record_code >= trans_mapping_simple_list_base and record_code < trans_mapping_simple_list_base + (simple_translation_template_variant_count * simple_list_prefix_codes.len * 2)) {
        const delta: u8 = record_code - trans_mapping_simple_list_base;
        const prefix_slot = delta % simple_list_prefix_codes.len;
        const tmp = delta / simple_list_prefix_codes.len;
        return .{
            .kind = .simple_list,
            .prefix_code = simple_list_prefix_codes[prefix_slot],
            .has_inline_value = true,
            .simple_template_variant = @intCast((tmp / 2) + 1),
            .separator_kind = @intCast((tmp % 2) + 1),
        };
    }
    return null;
}

fn simpleTranslationMappingRecordCode(prefix_code: u8, variant: u8) ?u8 {
    if (prefixForCode(prefix_code) == null) return null;
    if (variant == 0 or variant > simple_translation_template_variant_count) return null;
    const offset = (variant - 1) * @as(u8, line_prefixes.len) + (prefix_code - 1);
    return trans_mapping_simple_base + offset;
}

fn simpleTranslationListRecordCode(prefix_code: u8, variant: u8, separator_kind: u8) ?u8 {
    const prefix_index = simpleListPrefixIndex(prefix_code) orelse return null;
    if (variant == 0 or variant > simple_translation_template_variant_count) return null;
    if (separator_kind != simple_list_separator_comma and separator_kind != simple_list_separator_semicolon) return null;
    const offset = ((variant - 1) * 2 + (separator_kind - 1)) * @as(u8, simple_list_prefix_codes.len) + prefix_index;
    return trans_mapping_simple_list_base + offset;
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
                if (parsed.target_language_code) |lang_code| {
                    if (parsed.args.len == 2) {
                        try token_bytes.append(allocator, translation_template_langref_simple_token);
                        try appendTieredRef(&token_bytes, allocator, parsed.name_code);
                        if (parsed.name_code == template_name_raw) try appendCompactTerminated(&token_bytes, allocator, parsed.raw_name.?);
                        try appendTieredRef(&token_bytes, allocator, lang_code);
                        try appendCompactTerminated(&token_bytes, allocator, parsed.args[1]);
                    } else {
                        try token_bytes.append(allocator, translation_template_langref_token);
                        try appendTieredRef(&token_bytes, allocator, parsed.name_code);
                        if (parsed.name_code == template_name_raw) try appendCompactTerminated(&token_bytes, allocator, parsed.raw_name.?);
                        try appendTieredRef(&token_bytes, allocator, lang_code);
                        try appendVarUInt(&token_bytes, allocator, parsed.args.len - 1);
                        for (parsed.args[1..]) |arg| try appendCompactTerminated(&token_bytes, allocator, arg);
                    }
                } else {
                    try token_bytes.append(allocator, translation_template_token);
                    try appendTieredRef(&token_bytes, allocator, parsed.name_code);
                    if (parsed.name_code == template_name_raw) try appendCompactTerminated(&token_bytes, allocator, parsed.raw_name.?);
                    try appendVarUInt(&token_bytes, allocator, parsed.args.len);
                    for (parsed.args) |arg| try appendCompactTerminated(&token_bytes, allocator, arg);
                }
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
                const name_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;

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
            translation_template_langref_token => {
                const name_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;

                const name = if (name_code == template_name_raw)
                    try readCompactTerminatedAlloc(allocator, bytes, cursor, limit)
                else
                    try allocator.dupe(u8, translationTemplateName(name_code) orelse return error.InvalidEncoding);
                defer allocator.free(name);

                const lang_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;
                const lang = try allocator.dupe(u8, targetLanguageValueForCode(lang_code) orelse return error.InvalidEncoding);
                defer allocator.free(lang);

                const remaining_arg_count = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
                try out.appendSlice(allocator, "{{");
                try out.appendSlice(allocator, name);
                try out.append(allocator, '|');
                try out.appendSlice(allocator, lang);
                var arg_index: usize = 0;
                while (arg_index < remaining_arg_count) : (arg_index += 1) {
                    const arg = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
                    defer allocator.free(arg);
                    try out.append(allocator, '|');
                    try out.appendSlice(allocator, arg);
                }
                try out.appendSlice(allocator, "}}");
            },
            translation_template_langref_simple_token => {
                const name_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;

                const name = if (name_code == template_name_raw)
                    try readCompactTerminatedAlloc(allocator, bytes, cursor, limit)
                else
                    try allocator.dupe(u8, translationTemplateName(name_code) orelse return error.InvalidEncoding);
                defer allocator.free(name);

                const lang_code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;
                const lang = try allocator.dupe(u8, targetLanguageValueForCode(lang_code) orelse return error.InvalidEncoding);
                defer allocator.free(lang);
                const term = try readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
                defer allocator.free(term);

                try out.appendSlice(allocator, "{{");
                try out.appendSlice(allocator, name);
                try out.append(allocator, '|');
                try out.appendSlice(allocator, lang);
                try out.append(allocator, '|');
                try out.appendSlice(allocator, term);
                try out.appendSlice(allocator, "}}");
            },
            else => return error.InvalidEncoding,
        }
    }

    return out.toOwnedSlice(allocator);
}

const ParsedTranslationTemplate = struct {
    name_code: u16,
    raw_name: ?[]const u8 = null,
    args: []const []const u8,
    target_language_code: ?u16 = null,
};

fn parseTranslationTemplate(allocator: std.mem.Allocator, body: []const u8) ?ParsedTranslationTemplate {
    var parts = splitTopLevelRaw(allocator, body, '|') catch return null;
    if (parts.items.len == 0) return null;

    const raw_name = parts.items[0];
    const name_code = translationTemplateCode(raw_name) orelse return null;
    const target_language_code = if (argsCanUseTargetLanguageCode(name_code, parts.items[1..]))
        targetLanguageCodeForValue(parts.items[1])
    else
        null;

    return .{
        .name_code = name_code,
        .args = parts.items[1..],
        .target_language_code = target_language_code,
    };
}

const simple_translation_template_variant_count: u8 = 7;

fn parseSimpleTranslationTemplate(allocator: std.mem.Allocator, value: []const u8) ?SimpleTranslationTemplate {
    if (value.len < 4 or !std.mem.startsWith(u8, value, "{{") or !std.mem.endsWith(u8, value, "}}")) return null;
    const parsed = parseTranslationTemplate(allocator, value[2 .. value.len - 2]) orelse return null;
    const lang_code = parsed.target_language_code orelse return null;
    if (parsed.args.len != 2) return null;
    return .{
        .variant = simpleTranslationTemplateVariant(parsed.name_code) orelse return null,
        .lang_code = lang_code,
        .term = parsed.args[1],
    };
}

fn parseSimpleTranslationTemplateList(allocator: std.mem.Allocator, value: []const u8) ?SimpleTranslationTemplateList {
    const Separator = struct {
        kind: u8,
        text: []const u8,
    };
    const separator: Separator = blk: {
        if (std.mem.indexOf(u8, value, ", ") != null) break :blk .{ .kind = simple_list_separator_comma, .text = ", " };
        if (std.mem.indexOf(u8, value, "; ") != null) break :blk .{ .kind = simple_list_separator_semicolon, .text = "; " };
        return null;
    };

    const parts = splitTopLevelString(allocator, value, separator.text) catch return null;
    if (parts.items.len < 2) return null;

    var terms: std.ArrayList([]const u8) = .empty;
    errdefer terms.deinit(allocator);

    var first_variant: ?u8 = null;
    var first_lang_code: ?u16 = null;
    for (parts.items) |part| {
        const parsed = parseSimpleTranslationTemplate(allocator, part) orelse return null;
        if (first_variant == null) {
            first_variant = parsed.variant;
            first_lang_code = parsed.lang_code;
        } else if (first_variant.? != parsed.variant or first_lang_code.? != parsed.lang_code) {
            return null;
        }
        terms.append(allocator, parsed.term) catch return null;
    }

    return .{
        .variant = first_variant.?,
        .lang_code = first_lang_code.?,
        .separator_kind = separator.kind,
        .terms = terms.toOwnedSlice(allocator) catch return null,
    };
}

fn simpleTranslationTemplateVariant(name_code: u16) ?u8 {
    const name = translationTemplateName(name_code) orelse return null;
    if (std.mem.eql(u8, name, "t")) return 1;
    if (std.mem.eql(u8, name, "t+")) return 2;
    if (std.mem.eql(u8, name, "tt")) return 3;
    if (std.mem.eql(u8, name, "tt+")) return 4;
    if (std.mem.eql(u8, name, "t-needed")) return 5;
    if (std.mem.eql(u8, name, "t-check")) return 6;
    if (std.mem.eql(u8, name, "t+check")) return 7;
    return null;
}

fn simpleTranslationTemplateName(variant: u8) ?[]const u8 {
    return switch (variant) {
        1 => "t",
        2 => "t+",
        3 => "tt",
        4 => "tt+",
        5 => "t-needed",
        6 => "t-check",
        7 => "t+check",
        else => null,
    };
}

fn simpleListPrefixIndex(prefix_code: u8) ?u8 {
    for (simple_list_prefix_codes, 0..) |value, idx| {
        if (value == prefix_code) return @intCast(idx);
    }
    return null;
}

fn simpleListSeparatorText(kind: u8) ?[]const u8 {
    return switch (kind) {
        simple_list_separator_comma => ", ",
        simple_list_separator_semicolon => "; ",
        else => null,
    };
}

fn splitTopLevelString(allocator: std.mem.Allocator, input: []const u8, sep: []const u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
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
        if (templates == 0 and links == 0 and i + sep.len <= input.len and std.mem.eql(u8, input[i .. i + sep.len], sep)) {
            try out.append(allocator, input[start..i]);
            start = i + sep.len;
            i += sep.len - 1;
        }
    }
    try out.append(allocator, input[start..]);
    return out;
}

fn translationTemplateCode(name: []const u8) ?u16 {
    for (translation_templates) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.code;
    }
    return null;
}

fn lineTemplateCode(name: []const u8) ?u16 {
    for (line_templates) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.code;
    }
    return null;
}

fn lineTemplateName(code: u16) ?[]const u8 {
    for (line_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
}

fn translationTemplateName(code: u16) ?[]const u8 {
    for (translation_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
}

fn argsCanUseTargetLanguageCode(name_code: u16, args: []const []const u8) bool {
    if (args.len == 0) return false;
    const name = translationTemplateName(name_code) orelse return false;
    return std.mem.eql(u8, name, "t") or
        std.mem.eql(u8, name, "t+") or
        std.mem.eql(u8, name, "tt") or
        std.mem.eql(u8, name, "tt+") or
        std.mem.eql(u8, name, "t-needed") or
        std.mem.eql(u8, name, "t-check") or
        std.mem.eql(u8, name, "t+check");
}

fn splitTopLevelRaw(allocator: std.mem.Allocator, input: []const u8, sep: u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
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
            try out.append(allocator, input[start..i]);
            start = i + 1;
        }
    }
    try out.append(allocator, input[start..]);
    return out;
}

fn isCanonicalHeadingLine(line: []const u8, heading: ParsedHeading) bool {
    const marker_len = heading.level;
    const total_len = marker_len * 2 + heading.title.len;
    if (line.len != total_len) return false;

    var i: usize = 0;
    while (i < marker_len) : (i += 1) {
        if (line[i] != '=') return false;
    }
    if (!std.mem.eql(u8, line[marker_len .. marker_len + heading.title.len], heading.title)) return false;
    i = marker_len + heading.title.len;
    while (i < line.len) : (i += 1) {
        if (line[i] != '=') return false;
    }
    return true;
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
        try appendTieredRef(out, allocator, code);
        return;
    }

    try appendTieredRef(out, allocator, label_raw);
    try appendCompactTerminated(out, allocator, label);
}

fn readLabelRefAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, limit: usize) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const code = readTieredRef(bytes, cursor, limit) catch return error.InvalidEncoding;

    if (code == label_raw) return readCompactTerminatedAlloc(allocator, bytes, cursor, limit);
    return allocator.dupe(u8, languageLabelForCode(code) orelse return error.InvalidEncoding);
}

fn languageCodeForLabel(label: []const u8) ?u16 {
    for (language_labels) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry.code;
    }
    return null;
}

fn languageLabelForCode(code: u16) ?[]const u8 {
    for (language_labels) |entry| {
        if (entry.code == code) return entry.label;
    }
    return null;
}

fn targetLanguageCodeForValue(value: []const u8) ?u16 {
    for (target_languages) |entry| {
        if (std.mem.eql(u8, entry.value, value)) return entry.code;
    }
    return null;
}

fn targetLanguageValueForCode(code: u16) ?[]const u8 {
    for (target_languages) |entry| {
        if (entry.code == code) return entry.value;
    }
    return null;
}

fn expectEnglishSectionRoundTripExact(sample: []const u8) !void {
    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeEnglishAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
}

fn lineTemplateSampleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Noun===
        \\{{{{{s}|en|alpha|beta}}}}
        \\
    , .{name});
}

fn translationTemplateSampleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Noun===
        \\# thing
        \\====Translations====
        \\{{{{trans-top|test}}}}
        \\* French: {{{{{s}|fr|alpha}}}}
        \\{{{{trans-bottom}}}}
        \\
    , .{name});
}

fn specialLinePrefixSampleAlloc(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const line = if (std.mem.eql(u8, prefix, "{{en-noun"))
        "{{en-noun|s}}"
    else if (std.mem.eql(u8, prefix, "{{en-verb"))
        "{{en-verb}}"
    else if (std.mem.eql(u8, prefix, "{{en-adj"))
        "{{en-adj|er}}"
    else if (std.mem.eql(u8, prefix, "{{en-proper noun"))
        "{{en-proper noun}}"
    else if (std.mem.eql(u8, prefix, "{{head|en|"))
        "{{head|en|noun}}"
    else if (std.mem.eql(u8, prefix, "{{plural of|"))
        "{{plural of|en|cat}}"
    else if (std.mem.eql(u8, prefix, "{{infl of|"))
        "{{infl of|en|cat||s-verb-form}}"
    else if (std.mem.eql(u8, prefix, "{{lb|en|"))
        "{{lb|en|countable}}"
    else if (std.mem.eql(u8, prefix, "{{IPA|en|"))
        "{{IPA|en|/kat/}}"
    else if (std.mem.eql(u8, prefix, "{{audio|en|"))
        "{{audio|en|cat.ogg|a=UK}}"
    else if (std.mem.eql(u8, prefix, "{{rhymes|en|"))
        "{{rhymes|en|at}}"
    else if (std.mem.eql(u8, prefix, "<references/>"))
        "<references/>"
    else
        return error.InvalidArgument;

    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Noun===
        \\# thing
        \\{s}
        \\
    , .{line});
}

fn inlineColumnTemplateSampleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Derived terms===
        \\{{{{{s}|en|alpha|beta|gamma}}}}
        \\
    , .{name});
}

fn blockColumnTemplateSampleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Derived terms===
        \\{{{{{s}|en|alpha
        \\|beta
        \\|gamma
        \\}}}}
        \\
    , .{name});
}

test "tiered refs round trip inline and extended values" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try appendTieredRef(&bytes, std.testing.allocator, 0);
    try appendTieredRef(&bytes, std.testing.allocator, 1);
    try appendTieredRef(&bytes, std.testing.allocator, 42);
    try appendTieredRef(&bytes, std.testing.allocator, max_inline_ref_code);
    try appendTieredRef(&bytes, std.testing.allocator, max_inline_ref_code + 1);
    try appendTieredRef(&bytes, std.testing.allocator, 4096);

    var cursor: usize = 0;
    try std.testing.expectEqual(@as(u16, 0), try readTieredRef(bytes.items, &cursor, bytes.items.len));
    try std.testing.expectEqual(@as(u16, 1), try readTieredRef(bytes.items, &cursor, bytes.items.len));
    try std.testing.expectEqual(@as(u16, 42), try readTieredRef(bytes.items, &cursor, bytes.items.len));
    try std.testing.expectEqual(max_inline_ref_code, try readTieredRef(bytes.items, &cursor, bytes.items.len));
    try std.testing.expectEqual(max_inline_ref_code + 1, try readTieredRef(bytes.items, &cursor, bytes.items.len));
    try std.testing.expectEqual(@as(u16, 4096), try readTieredRef(bytes.items, &cursor, bytes.items.len));
    try std.testing.expectEqual(bytes.items.len, cursor);
}

test "section encoding round trips headings, translations, and column terms" {
    const sample =
        \\==English==
        \\{{wikipedia|color}}
        \\===Alternative forms===
        \\* {{alt|en|colour||Commonwealth}}
        \\====Derived terms====
        \\{{col4|en| anticolor
        \\|bicolor
        \\}}
        \\===Noun===
        \\{{en-noun|s}}
        \\# {{plural of|en|colors}}
        \\# {{lb|en|countable}} [[light]]
        \\#: {{ux|en|Humans see color.}}
        \\===Anagrams===
        \\{{anagrams|en|crool|color}}
        \\===See also===
        \\* {{l|en|hue}}, {{l|en|tint}}
        \\====Translations====
        \\{{trans-top|visible spectrum}}
        \\{{checktrans-top|}}
        \\{{multitrans|data=
        \\* French: {{tt+|fr|couleur}}
        \\* Chinese:
        \\*: Mandarin: {{tt|cmn|颜色|tr=yánsè}}
        \\* Sindhi : {{t+|sd|اَڱارو}}, {{t|sd|مَنگلُ}}
        \\* Maori: {{t|mi|wewete}} {{qualifier|from a spell or ritual }}
        \\* Ukrainian: {{t|uk|коштувати цілий статок}}{{qualifier |lit. cost an entire estate}}
        \\* Chinese: {{t|cmn|[[士科德]][[州]]|tr=Shìkēdé Zhōu}} {{ qual|Taiwan}}
        \\}}<!-- close {{multitrans}} -->
        \\{{trans-bottom}}
        \\=== References===
        \\<references/>
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeEnglishAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
}

test "decoded document exposes renderer-facing section structure" {
    const sample =
        \\==English==
        \\{{wikipedia|color}}
        \\===Noun===
        \\# [[light]]
        \\====Translations====
        \\{{trans-top|visible spectrum}}
        \\* French: {{t|fr|couleur}}
        \\{{trans-bottom}}
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);
    var document = try decodeDocumentAlloc(std.testing.allocator, encoded);
    defer document.deinit(std.testing.allocator);

    try std.testing.expect(document.trailing_newline);
    try std.testing.expectEqual(@as(usize, 3), document.sections.len);
    try std.testing.expectEqual(@as(u8, 0), document.sections[0].level);
    try std.testing.expectEqualStrings("", document.sections[0].title);
    try std.testing.expectEqualStrings("{{wikipedia|color}}", document.sections[0].body);
    try std.testing.expectEqual(@as(u8, 3), document.sections[1].level);
    try std.testing.expectEqualStrings("Noun", document.sections[1].title);
    try std.testing.expectEqual(SectionKind.pos_lines, document.sections[1].kind);
    try std.testing.expectEqualStrings("# [[light]]", document.sections[1].body);
    var block_iterator = document.sections[1].blockIterator();
    const definition = block_iterator.next().?;
    try std.testing.expectEqual(BlockKind.definition, definition.kind);
    try std.testing.expectEqual(@as(u8, 1), definition.depth);
    try std.testing.expectEqualStrings("[[light]]", definition.text);
    try std.testing.expect(block_iterator.next() == null);
    try std.testing.expectEqual(@as(u8, 4), document.sections[2].level);
    try std.testing.expectEqualStrings("Translations", document.sections[2].title);
    try std.testing.expectEqual(SectionKind.translations, document.sections[2].kind);
    const translations = document.sections[2].translation_records orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), translations.len);
    try std.testing.expectEqual(TranslationRecordKind.group_start, translations[0].kind);
    try std.testing.expectEqualStrings("visible spectrum", translations[0].text.?);
    try std.testing.expect(!translations[0].check);
    try std.testing.expectEqual(TranslationRecordKind.mapping, translations[1].kind);
    try std.testing.expectEqual(BlockKind.list_item, translations[1].block_kind);
    try std.testing.expectEqual(@as(u8, 1), translations[1].depth);
    try std.testing.expectEqualStrings("French", translations[1].label.?);
    try std.testing.expect(translations[1].language == null);
    try std.testing.expect(translations[1].template_name == null);
    try std.testing.expectEqual(@as(usize, 0), translations[1].terms.len);
    try std.testing.expectEqualStrings("{{t|fr|couleur}}", translations[1].text.?);
    try std.testing.expectEqual(TranslationRecordKind.group_end, translations[2].kind);
}

test "decoded translation mappings preserve generic inline values without generated tables" {
    const sample =
        \\==English==
        \\===Noun===
        \\# cat
        \\====Translations====
        \\{{trans-top|domestic cat}}
        \\* French: {{t|fr|chat}}, {{t|fr|minou}}
        \\{{trans-bottom}}
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);
    var document = try decodeDocumentAlloc(std.testing.allocator, encoded);
    defer document.deinit(std.testing.allocator);

    var records: ?[]TranslationRecord = null;
    for (document.sections) |section| {
        if (section.translation_records) |translation_records| {
            records = translation_records;
            break;
        }
    }
    const translations = records orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), translations.len);
    const mapping = translations[1];
    try std.testing.expectEqual(TranslationRecordKind.mapping, mapping.kind);
    try std.testing.expectEqual(BlockKind.list_item, mapping.block_kind);
    try std.testing.expectEqual(@as(u8, 1), mapping.depth);
    try std.testing.expectEqual(TranslationSeparator.none, mapping.separator);
    try std.testing.expectEqualStrings("French", mapping.label.?);
    try std.testing.expect(mapping.language == null);
    try std.testing.expect(mapping.template_name == null);
    try std.testing.expectEqual(@as(usize, 0), mapping.terms.len);
    try std.testing.expectEqualStrings("{{t|fr|chat}}, {{t|fr|minou}}", mapping.text.?);
}

test "render blocks classify wiktionary line structure" {
    const body =
        "# definition\n" ++
        "## nested\n" ++
        "#: example\n" ++
        "#* quotation\n" ++
        "* item\n" ++
        "**: detail\n" ++
        ": indent\n" ++
        "; term\n" ++
        "paragraph\n";
    const section = DecodedSection{
        .level = 3,
        .title = "Noun",
        .kind = .pos_lines,
        .body = body,
        .line_count = 10,
    };
    const expected = [_]BlockKind{
        .definition,
        .definition,
        .example,
        .quotation,
        .list_item,
        .list_detail,
        .indent,
        .term,
        .paragraph,
        .blank,
    };

    var iterator = section.blockIterator();
    for (expected, 0..) |kind, index| {
        const block = iterator.next().?;
        try std.testing.expectEqual(kind, block.kind);
        if (index == 0) {
            try std.testing.expectEqual(@as(u8, 1), block.depth);
            try std.testing.expectEqualStrings("definition", block.text);
        } else if (index == 1) {
            try std.testing.expectEqual(@as(u8, 2), block.depth);
        }
    }
    try std.testing.expect(iterator.next() == null);

    const blocks = try section.blocksAlloc(std.testing.allocator);
    defer std.testing.allocator.free(blocks);
    try std.testing.expectEqual(expected.len, blocks.len);
    try std.testing.expectEqual(BlockKind.blank, blocks[blocks.len - 1].kind);
}

test "inline iterator exposes links and emphasis without allocations" {
    const block = DecodedBlock{
        .kind = .definition,
        .depth = 1,
        .text = "plain ''italic'' '''bold''' '''''both''''' [[light]] and '''[[cat|cats]]''' end",
    };
    var iterator = block.inlineIterator();

    const plain = iterator.next().?;
    try std.testing.expectEqual(InlineKind.text, plain.kind);
    try std.testing.expectEqualStrings("plain ", plain.text);
    try std.testing.expect(!plain.bold and !plain.italic);

    const italic = iterator.next().?;
    try std.testing.expectEqualStrings("italic", italic.text);
    try std.testing.expect(!italic.bold and italic.italic);
    const spacer1 = iterator.next().?;
    try std.testing.expectEqualStrings(" ", spacer1.text);

    const bold = iterator.next().?;
    try std.testing.expectEqualStrings("bold", bold.text);
    try std.testing.expect(bold.bold and !bold.italic);
    _ = iterator.next().?;

    const both = iterator.next().?;
    try std.testing.expectEqualStrings("both", both.text);
    try std.testing.expect(both.bold and both.italic);
    _ = iterator.next().?;

    const light = iterator.next().?;
    try std.testing.expectEqual(InlineKind.link, light.kind);
    try std.testing.expectEqualStrings("light", light.target);
    try std.testing.expectEqualStrings("light", light.text);
    _ = iterator.next().?;

    const cats = iterator.next().?;
    try std.testing.expectEqual(InlineKind.link, cats.kind);
    try std.testing.expectEqualStrings("cat", cats.target);
    try std.testing.expectEqualStrings("cats", cats.text);
    try std.testing.expect(cats.bold and !cats.italic);

    const tail = iterator.next().?;
    try std.testing.expectEqualStrings(" end", tail.text);
    try std.testing.expect(iterator.next() == null);
}

test "inline iterator exposes balanced templates for runtime expansion" {
    const block = DecodedBlock{
        .kind = .definition,
        .depth = 1,
        .text = "'''{{lb|en|countable}}''' {{outer|{{inner|x}}|{{{p|d}}}}} {{{param}}} {{broken",
    };
    var iterator = block.inlineIterator();

    const label = iterator.next().?;
    try std.testing.expectEqual(InlineKind.template, label.kind);
    try std.testing.expectEqualStrings("lb", label.target);
    try std.testing.expectEqualStrings("lb|en|countable", label.text);
    try std.testing.expect(label.bold and !label.italic);

    const space = iterator.next().?;
    try std.testing.expectEqualStrings(" ", space.text);

    const nested = iterator.next().?;
    try std.testing.expectEqual(InlineKind.template, nested.kind);
    try std.testing.expectEqualStrings("outer", nested.target);
    try std.testing.expectEqualStrings("outer|{{inner|x}}|{{{p|d}}}", nested.text);

    const tail = iterator.next().?;
    try std.testing.expectEqual(InlineKind.text, tail.kind);
    try std.testing.expectEqualStrings(" {{{param}}} {{broken", tail.text);
    try std.testing.expect(iterator.next() == null);
}

test "inline iterator exposes link trails external links and line breaks" {
    const block = DecodedBlock{
        .kind = .paragraph,
        .depth = 0,
        .text = "[[cat]]s [https://example.com docs]<BR />tail",
    };
    var iterator = block.inlineIterator();

    const internal = iterator.next().?;
    try std.testing.expectEqual(InlineKind.link, internal.kind);
    try std.testing.expectEqualStrings("cat", internal.target);
    try std.testing.expectEqualStrings("cat", internal.text);
    try std.testing.expectEqualStrings("s", internal.trail);

    const space = iterator.next().?;
    try std.testing.expectEqualStrings(" ", space.text);

    const external = iterator.next().?;
    try std.testing.expectEqual(InlineKind.external_link, external.kind);
    try std.testing.expectEqualStrings("https://example.com", external.target);
    try std.testing.expectEqualStrings("docs", external.text);

    const line_break = iterator.next().?;
    try std.testing.expectEqual(InlineKind.line_break, line_break.kind);
    try std.testing.expectEqualStrings("", line_break.text);

    const tail = iterator.next().?;
    try std.testing.expectEqual(InlineKind.text, tail.kind);
    try std.testing.expectEqualStrings("tail", tail.text);
    try std.testing.expect(iterator.next() == null);
}

test "inline iterator preserves malformed markup as text" {
    const block = DecodedBlock{
        .kind = .paragraph,
        .depth = 0,
        .text = "broken ''italic and [[open",
    };
    var iterator = block.inlineIterator();
    const span = iterator.next().?;
    try std.testing.expectEqual(InlineKind.text, span.kind);
    try std.testing.expectEqualStrings(block.text, span.text);
    try std.testing.expect(iterator.next() == null);
}

test "decoded term lists expose renderer-native column records" {
    const sample =
        \\==English==
        \\===Noun===
        \\# thing
        \\====Derived terms====
        \\{{col3|en|daylight|moonlight|sunlight}}
        \\* [[torchlight]]
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);
    var document = try decodeDocumentAlloc(std.testing.allocator, encoded);
    defer document.deinit(std.testing.allocator);

    var terms: ?*const DecodedSection = null;
    for (document.sections) |*section| {
        if (section.kind == .term_list) {
            terms = section;
            break;
        }
    }
    const section = terms orelse return error.TestExpectedEqual;
    const term_records = section.term_records orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), term_records.len);

    const column = term_records[0];
    try std.testing.expectEqual(TermRecordKind.column, column.kind);
    try std.testing.expectEqual(@as(?u8, 3), column.columns);
    try std.testing.expect(!column.block_layout);
    try std.testing.expectEqual(@as(usize, 3), column.items.len);
    try std.testing.expectEqualStrings("daylight", column.items[0]);
    try std.testing.expectEqualStrings("moonlight", column.items[1]);
    try std.testing.expectEqualStrings("sunlight", column.items[2]);

    const line = term_records[1];
    try std.testing.expectEqual(TermRecordKind.line, line.kind);
    try std.testing.expectEqualStrings("* [[torchlight]]", line.text);
}

test "section document encoding is smaller on a representative entry" {
    const sample =
        \\==English==
        \\===Noun===
        \\{{en-noun|s}}
        \\# {{lb|en|countable}} [[light]]
        \\#: {{ux|en|Humans see light.}}
        \\====Derived terms====
        \\{{col3|en|daylight|moonlight|sunlight|starlight|torchlight|twilight}}
        \\====Translations====
        \\{{trans-top|visible light}}
        \\* French: {{t+|fr|lumière}}
        \\* German: {{t+|de|Licht|n}}
        \\* Spanish: {{t+|es|luz|f}}
        \\{{trans-bottom}}
        \\
    ;

    const structured = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(structured);
    const raw = try compact.encodeAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(structured.len < raw.len);
}

test "section encoding falls back when simple translation lists use unsupported prefixes" {
    const sample =
        \\==English==
        \\===Noun===
        \\# thing
        \\====Translations====
        \\{{trans-top|test}}
        \\** French: {{t|fr|chat}}, {{t|fr|minou}}
        \\{{trans-bottom}}
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeEnglishAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
}

test "section encoding preserves blank-only spacer bodies between headings" {
    const sample =
        \\==English==
        \\
        \\===Pronunciation===
        \\* test
        \\
    ;

    const encoded = try encodeEnglishAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeEnglishAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
}

test "section encoding round trips every generated line template from the bottom of the table" {
    if (line_templates.len == 0) return;
    var idx = line_templates.len;
    while (idx > 0) {
        idx -= 1;
        const sample = try lineTemplateSampleAlloc(std.testing.allocator, line_templates[idx].name);
        defer std.testing.allocator.free(sample);
        try expectEnglishSectionRoundTripExact(sample);
    }
}

test "section encoding round trips every generated translation template from the bottom of the table" {
    if (translation_templates.len == 0) return;
    var idx = translation_templates.len;
    while (idx > 0) {
        idx -= 1;
        const sample = try translationTemplateSampleAlloc(std.testing.allocator, translation_templates[idx].name);
        defer std.testing.allocator.free(sample);
        try expectEnglishSectionRoundTripExact(sample);
    }
}

test "section encoding round trips every static special line template from the bottom of the table" {
    var idx = special_line_prefixes.len;
    while (idx > 0) {
        idx -= 1;
        const prefix = special_line_prefixes[idx].prefix;
        if (!std.mem.startsWith(u8, prefix, "{{") and !std.mem.eql(u8, prefix, "<references/>")) continue;
        const sample = try specialLinePrefixSampleAlloc(std.testing.allocator, prefix);
        defer std.testing.allocator.free(sample);
        try expectEnglishSectionRoundTripExact(sample);
    }
}

test "section encoding round trips every inline column template from the bottom of the table" {
    const column_names = [_][]const u8{ "col", "col2", "col3", "col4", "col5" };
    var idx = column_names.len;
    while (idx > 0) {
        idx -= 1;
        const sample = try inlineColumnTemplateSampleAlloc(std.testing.allocator, column_names[idx]);
        defer std.testing.allocator.free(sample);
        try expectEnglishSectionRoundTripExact(sample);
    }
}

test "section encoding round trips every block column template from the bottom of the table" {
    const column_names = [_][]const u8{ "col", "col2", "col3", "col4", "col5" };
    var idx = column_names.len;
    while (idx > 0) {
        idx -= 1;
        const sample = try blockColumnTemplateSampleAlloc(std.testing.allocator, column_names[idx]);
        defer std.testing.allocator.free(sample);
        try expectEnglishSectionRoundTripExact(sample);
    }
}
