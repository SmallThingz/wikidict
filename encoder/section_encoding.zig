const std = @import("std");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");
const generated = @import("generated_structure_tables");

const trailing_newline_flag: u8 = 1 << 0;
const extended_ref_marker: u8 = 0xFF;
const max_inline_ref_code: u16 = 0xFE;

const SectionKind = generated.SectionKind;

const heading_generic: u16 = 0;
const heading_preamble: u16 = 1;

const HeadingDef = generated.HeadingSpec;
const heading_defs = generated.heading_specs;

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
const record_column_block_base: u8 = 1;

const trans_raw_line: u8 = 0;
const trans_top_empty: u8 = 1;
const trans_top: u8 = 2;
const trans_check_top_empty: u8 = 3;
const trans_check_top: u8 = 4;
const trans_mid: u8 = 5;
const trans_bottom: u8 = 6;
const trans_multitrans_open: u8 = 7;
const trans_multitrans_close: u8 = 8;
const trans_mapping_plain_base: u8 = 32;
const trans_mapping_inline_base: u8 = 64;

const translation_raw_token: u8 = 0;
const translation_template_token: u8 = 1;

const template_name_raw: u16 = 0;

const TranslationTemplate = generated.TranslationTemplate;
const translation_templates = generated.translation_templates;

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
    prefix_code: u8,
    has_inline_value: bool,
};

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
        try out.append(allocator, section.level);

        const heading_code = headingCodeForTitle(section.title, section.level);
        try appendTieredRef(&out, allocator, heading_code);
        const kind = kindForHeadingCode(heading_code) orelse kindForTitle(section.title) orelse .lines;
        if (heading_code == heading_generic) {
            try appendCompactSlice(&out, allocator, section.title);
            try out.append(allocator, @intFromEnum(kindForTitle(section.title) orelse .lines));
        }

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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "==English==");

    while (cursor < encoded.len) {
        if (cursor >= encoded.len) return error.InvalidEncoding;
        const level = encoded[cursor];
        cursor += 1;
        const heading_code = readTieredRef(encoded, &cursor, encoded.len) catch return error.InvalidEncoding;

        const title, const kind = if (heading_code == heading_generic) blk: {
            const generic_title = try readCompactSliceAlloc(allocator, encoded, &cursor, encoded.len);
            if (cursor >= encoded.len) return error.InvalidEncoding;
            const kind_int = encoded[cursor];
            cursor += 1;
            break :blk .{
                generic_title,
                sectionKindFromInt(kind_int) orelse return error.InvalidEncoding,
            };
        } else if (heading_code == heading_preamble) blk: {
            break :blk .{
                try allocator.dupe(u8, ""),
                SectionKind.lines,
            };
        } else blk: {
            const def = headingDefForCode(heading_code) orelse return error.InvalidEncoding;
            break :blk .{
                try allocator.dupe(u8, def.title),
                def.kind,
            };
        };
        defer allocator.free(title);

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

fn decodeJoinedBodyAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    return compact.decodeAlloc(allocator, payload) catch return error.InvalidEncoding;
}

fn encodeTermSectionAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) {
        if (parseInlineColumnTemplate(allocator, lines[i])) |column_inline| {
            try out.append(allocator, columnInlineRecordCode(column_inline.template_code) orelse return error.InvalidEncoding);
            try appendVarUInt(&out, allocator, column_inline.items.len);
            for (column_inline.items) |item| try appendCompactTerminated(&out, allocator, item);
            i += 1;
            continue;
        }

        if (parseColumnBlock(allocator, lines[i..])) |block| {
            try out.append(allocator, columnInlineRecordCode(block.template_code) orelse return error.InvalidEncoding);
            try appendVarUInt(&out, allocator, block.item_count);
            for (block.items[0..block.item_count]) |item| try appendCompactTerminated(&out, allocator, item);
            i += block.consumed;
            continue;
        }

        try out.append(allocator, record_raw_line);
        try appendEncodedLine(&out, allocator, lines[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn decodeTermSectionAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var cursor: usize = 0;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var first = true;
    while (cursor < payload.len) {
        if (!first) try out.append(allocator, '\n');
        if (cursor >= payload.len) return error.InvalidEncoding;

        const record_code = payload[cursor];
        switch (record_code) {
            record_raw_line => {
                cursor += 1;
                const line = try decodeEncodedLineAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            },
            else => {
                const template_code = columnTemplateCodeForRecord(record_code) orelse return error.InvalidEncoding;
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
        }
        first = false;
    }

    return out.toOwnedSlice(allocator);
}

fn encodeTranslationSectionAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (lines) |line| {
        if (matchTemplateArgLine(line, "trans-top")) |gloss| {
            if (gloss.len == 0) {
                try out.append(allocator, trans_top_empty);
            } else {
                try out.append(allocator, trans_top);
                try appendCompactTerminated(&out, allocator, gloss);
            }
            continue;
        }
        if (matchTemplateArgLine(line, "checktrans-top")) |gloss| {
            if (gloss.len == 0) {
                try out.append(allocator, trans_check_top_empty);
            } else {
                try out.append(allocator, trans_check_top);
                try appendCompactTerminated(&out, allocator, gloss);
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

fn decodeTranslationSectionAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var cursor: usize = 0;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var first = true;
    while (cursor < payload.len) {
        if (!first) try out.append(allocator, '\n');
        if (cursor >= payload.len) return error.InvalidEncoding;

        const record_code = payload[cursor];
        switch (record_code) {
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
                try out.appendSlice(allocator, "{{trans-top|");
                try out.appendSlice(allocator, gloss);
                try out.appendSlice(allocator, "}}");
            },
            trans_top_empty => {
                cursor += 1;
                try out.appendSlice(allocator, "{{trans-top}}");
            },
            trans_check_top => {
                cursor += 1;
                const gloss = try readCompactTerminatedAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(gloss);
                try out.appendSlice(allocator, "{{checktrans-top|");
                try out.appendSlice(allocator, gloss);
                try out.appendSlice(allocator, "}}");
            },
            trans_check_top_empty => {
                cursor += 1;
                try out.appendSlice(allocator, "{{checktrans-top}}");
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
            else => {
                const mapping_spec = translationMappingSpec(record_code) orelse return error.InvalidEncoding;
                cursor += 1;
                const label = try readLabelRefAlloc(allocator, payload, &cursor, payload.len);
                defer allocator.free(label);
                const prefix = prefixForCode(mapping_spec.prefix_code) orelse return error.InvalidEncoding;
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, label);
                if (mapping_spec.has_inline_value) {
                    const value = try readTranslationValueAlloc(allocator, payload, &cursor, payload.len);
                    defer allocator.free(value);
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, value);
                } else {
                    try out.append(allocator, ':');
                }
            },
        }
        first = false;
    }

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

fn headingCodeForTitle(title: []const u8, level: u8) u16 {
    if (level == 0 and title.len == 0) return heading_preamble;
    for (heading_defs) |def| {
        if (std.mem.eql(u8, def.title, title)) return def.code;
    }
    return heading_generic;
}

fn headingDefForCode(code: u16) ?HeadingDef {
    for (heading_defs) |def| {
        if (def.code == code) return def;
    }
    return null;
}

fn kindForHeadingCode(code: u16) ?SectionKind {
    if (code == heading_preamble) return .lines;
    const def = headingDefForCode(code) orelse return null;
    return def.kind;
}

fn kindForTitle(title: []const u8) ?SectionKind {
    for (heading_defs) |def| {
        if (std.mem.eql(u8, def.title, title)) return def.kind;
    }
    return null;
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

fn columnInlineRecordCode(template_code: u8) ?u8 {
    if (template_code < column_col or template_code > column_col5) return null;
    return record_column_block_base + (template_code - column_col);
}

fn columnTemplateCodeForRecord(record_code: u8) ?u8 {
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

fn translationMappingRecordCode(prefix_code: u8, has_inline_value: bool) ?u8 {
    if (prefixForCode(prefix_code) == null) return null;
    return (if (has_inline_value) trans_mapping_inline_base else trans_mapping_plain_base) + prefix_code;
}

fn translationMappingSpec(record_code: u8) ?TranslationMappingSpec {
    if (record_code > trans_mapping_plain_base and record_code <= trans_mapping_plain_base + line_prefixes.len) {
        return .{
            .prefix_code = record_code - trans_mapping_plain_base,
            .has_inline_value = false,
        };
    }
    if (record_code > trans_mapping_inline_base and record_code <= trans_mapping_inline_base + line_prefixes.len) {
        return .{
            .prefix_code = record_code - trans_mapping_inline_base,
            .has_inline_value = true,
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
                try appendTieredRef(&token_bytes, allocator, parsed.name_code);
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
            else => return error.InvalidEncoding,
        }
    }

    return out.toOwnedSlice(allocator);
}

const ParsedTranslationTemplate = struct {
    name_code: u16,
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

fn translationTemplateCode(name: []const u8) ?u16 {
    for (translation_templates) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.code;
    }
    return null;
}

fn translationTemplateName(code: u16) ?[]const u8 {
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
