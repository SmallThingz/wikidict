const std = @import("std");
const format = @import("blob_format.zig");

pub const schema = "dict.presentation.v3";
pub const Role = enum { normal, label, pronunciation, headword, example, quotation, citation, reference };
pub const InlineKind = enum { text, link, external_link, line_break };
pub const FontScaleBasis = enum { context, normal_body };
pub const InlineImage = struct {
    file: []const u8,
    width_px: ?u32 = null,
    height_px: ?u32 = null,
    alt: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,

    pub fn jsonStringify(self: InlineImage, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(self.file);
        inline for (.{ "width_px", "height_px", "alt", "tooltip" }) |name| {
            if (@field(self, name)) |value| {
                try jw.objectField(name);
                try jw.write(value);
            }
        }
        try jw.endObject();
    }
};
pub const Span = struct {
    kind: InlineKind = .text,
    text: []const u8 = "",
    target: []const u8 = "",
    trail: []const u8 = "",
    language: []const u8 = "",
    classes: []const u8 = "",
    direction: []const u8 = "",
    explanation: []const u8 = "",
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    /// Numeric size relative to the selected unscaled typography basis.
    font_scale: ?f32 = null,
    font_scale_basis: FontScaleBasis = .context,
    image: ?InlineImage = null,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    small: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    strike: bool = false,
    underline: bool = false,
    role: Role = .normal,

    // Keep the established JSON shape when no new paint is present.
    pub fn jsonStringify(self: Span, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Span).@"struct".field_names) |field_name| {
            const background_field = comptime std.mem.eql(u8, field_name, "background");
            const scale_field = comptime std.mem.eql(u8, field_name, "font_scale");
            const basis_field = comptime std.mem.eql(u8, field_name, "font_scale_basis");
            const image_field = comptime std.mem.eql(u8, field_name, "image");
            if ((!image_field or self.image != null) and (!background_field or self.background != null) and
                (!scale_field or (self.font_scale != null and (self.font_scale.? != 1 or self.font_scale_basis == .normal_body))) and
                (!basis_field or self.font_scale_basis != .context))
            {
                try jw.objectField(field_name);
                try jw.write(@field(self, field_name));
            }
        }
        try jw.endObject();
    }
};
pub const Feature = struct {
    kind: []const u8,
    language: []const u8 = "",
    data: []const u8 = "",
    tail_kind: []const u8 = "none",
    tail: []const u8 = "",
};
pub const BlockKind = enum { paragraph, blank, definition, example, quotation, list_item, list_detail, indent, term, heading, preformatted, rule, table };
pub const max_table_depth: usize = 16;
pub const TableWidthUnit = enum { px, percent };
pub const TableWidth = struct { unit: TableWidthUnit, value: u32 };
pub const TableGeometry = struct {
    border: ?u16 = null,
    cell_spacing: ?u16 = null,
    cell_padding: ?u16 = null,
    width: ?TableWidth = null,
};
pub const StyleLengthUnit = enum { px, em };
pub const StyleLength = struct {
    unit: StyleLengthUnit,
    value: f32,

    pub fn jsonStringify(self: StyleLength, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("unit");
        try jw.write(self.unit);
        try jw.objectField("value");
        try jw.write(@as(f64, self.value));
        try jw.endObject();
    }
};
pub const StyleEdges = struct {
    top: StyleLength,
    right: StyleLength,
    bottom: StyleLength,
    left: StyleLength,

    pub fn all(value: StyleLength) StyleEdges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};
pub const StyleBorder = union(enum) {
    none,
    solid: struct { width: StyleLength, color: []const u8 },
};
pub const BorderCollapse = enum { separate, collapse };
pub const CellTextAlign = enum { left, center, right };
pub const TableStyle = struct {
    background: ?[]const u8 = null,
    border: ?StyleBorder = null,
    collapse: ?BorderCollapse = null,
    margins: ?StyleEdges = null,

    pub fn jsonStringify(self: TableStyle, jw: anytype) !void {
        try writeOptionalStyleFields(self, jw);
    }
};
pub const CellStyle = struct {
    border: ?StyleBorder = null,
    padding: ?StyleEdges = null,
    text_align: ?CellTextAlign = null,

    pub fn jsonStringify(self: CellStyle, jw: anytype) !void {
        try writeOptionalStyleFields(self, jw);
    }
};
fn writeOptionalStyleFields(value: anytype, jw: anytype) !void {
    try jw.beginObject();
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        if (@field(value, name)) |present| {
            try jw.objectField(name);
            try jw.write(present);
        }
    }
    try jw.endObject();
}
pub const Cell = struct {
    spans: []const Span = &.{},
    header: bool = false,
    colspan: u16 = 1,
    rowspan: u16 = 1,
    background: ?[]const u8 = null,
    nested_table: ?Table = null,
    /// Non-null is authoritative, including an explicitly empty block list.
    blocks: ?[]const Block = null,
    style: ?CellStyle = null,

    pub fn jsonStringify(self: Cell, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Cell).@"struct".field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "style")) {
                if (self.style) |style| {
                    try jw.objectField(field_name);
                    try jw.write(style);
                }
            } else if (comptime std.mem.eql(u8, field_name, "blocks")) {
                if (self.blocks) |blocks| {
                    try jw.objectField(field_name);
                    try jw.write(blocks);
                }
            } else if (comptime !std.mem.eql(u8, field_name, "nested_table")) {
                try jw.objectField(field_name);
                try jw.write(@field(self, field_name));
            } else if (self.nested_table != null) {
                try jw.objectField(field_name);
                try jw.write(self.nested_table);
            }
        }
        try jw.endObject();
    }
};
pub const Row = struct { cells: []const Cell = &.{} };
pub const Table = struct {
    caption: []const Span = &.{},
    rows: []const Row = &.{},
    geometry: ?TableGeometry = null,
    style: ?TableStyle = null,

    pub fn jsonStringify(self: Table, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("caption");
        try jw.write(self.caption);
        try jw.objectField("rows");
        try jw.write(self.rows);
        if (self.geometry) |geometry| {
            try jw.objectField("geometry");
            try jw.write(geometry);
        }
        if (self.style) |style| {
            try jw.objectField("style");
            try jw.write(style);
        }
        try jw.endObject();
    }
};
pub const Block = struct {
    kind: BlockKind,
    depth: u8 = 0,
    spans: []const Span = &.{},
    feature: ?Feature = null,
    list_path: []const u8 = "",
    number: []const u8 = "",
    level: u8 = 0,
    anchor: []const u8 = "",
    anchor_fallback: []const u8 = "",
    table: ?Table = null,
};
pub const Section = struct {
    level: u8,
    title: []const u8,
    anchor: []const u8 = "",
    anchor_fallback: []const u8 = "",
    blocks: []const Block = &.{},
};
pub const Form = struct { relation: []const u8, target: []const u8, language: []const u8 };
pub const Sense = struct {
    block: usize,
    parent: ?usize = null,
    examples: []const usize = &.{},
    quotations: []const usize = &.{},
    notes: []const usize = &.{},
    form: ?Form = null,
};
pub const Lexeme = struct {
    language: []const u8 = "",
    kind: []const u8,
    section: usize,
    etymology: ?usize = null,
    definitions: []const Sense = &.{},
    introduction: []const usize = &.{},
    other_blocks: []const usize = &.{},
    related_sections: []const usize = &.{},
};
pub const Layout = struct { lexemes: []const Lexeme = &.{}, other_sections: []const usize = &.{} };
pub const ReferenceKind = enum { note, fragment };
pub const Reference = struct {
    kind: ReferenceKind = .note,
    // Stable item identity, independent of the footer array position.
    number: usize,
    group_number: ?u32,
    name: []const u8 = "",
    group: []const u8 = "",
    spans: []const Span = &.{},
    /// Non-null is authoritative, including an explicitly empty block list.
    /// Legacy span-only references keep null and their established wire bytes.
    blocks: ?[]const Block = null,

    pub fn jsonStringify(self: Reference, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Reference).@"struct".field_names) |field_name| {
            // Keep legacy note JSON unchanged; absence of kind means note.
            const kind_field = comptime std.mem.eql(u8, field_name, "kind");
            const blocks_field = comptime std.mem.eql(u8, field_name, "blocks");
            if ((!kind_field or self.kind != .note) and (!blocks_field or self.blocks != null)) {
                try jw.objectField(field_name);
                try jw.write(@field(self, field_name));
            }
        }
        try jw.endObject();
    }
};
pub const MediaKind = enum { image, audio };
pub const Media = struct { file: []const u8, kind: MediaKind, caption: []const u8 };
/// Reader routing metadata. Ordinary DPR2 payloads do not encode this field.
pub const Redirect = struct {
    source_title: []const u8,
    target_title: []const u8,
    fragment: []const u8,
    followed: bool,
};
/// Direct destination of the displayed redirect page, independent of the
/// incoming redirect which selected it. DAL1 supplies this metadata.
pub const AliasTarget = struct {
    xml_target: []const u8,
    target_title: []const u8,
    fragment: []const u8,
};
pub const Entry = struct {
    organization: Layout = .{},
    title: []const u8,
    display_title: []const Span = &.{},
    kind: format.BlobKind,
    language: ?[]const u8 = null,
    language_code: []const u8 = "",
    sections: []const Section = &.{},
    preamble_spans: []const Span = &.{},
    references: []const Reference = &.{},
    media: []const Media = &.{},
    redirect: ?Redirect = null,
    alias: ?AliasTarget = null,
};
pub const Stored = struct { schema: []const u8 = schema, entry: Entry };

// Consumer-facing authored background values are canonical opaque RGB only.
pub fn isCanonicalRgb(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

pub const ValidationError = error{InvalidPresentation};

const max_inline_image_string_bytes = 32 * 1024 * 1024;
fn validInlineImageString(value: []const u8) bool {
    return value.len <= max_inline_image_string_bytes and std.unicode.utf8ValidateSlice(value);
}
pub fn validInlineImageFile(value: []const u8) bool {
    if (value.len == 0 or !validInlineImageString(value)) return false;
    if (value[0] == ' ' or value[value.len - 1] == ' ') return false;
    // Canonical media identity is trimmed and has underscores normalized to
    // spaces. Reject impossible title characters, without path/namespace rules.
    for (value) |byte| if (byte < 32 or byte == 127 or
        std.mem.indexOfScalar(u8, "[]{}<>|#_", byte) != null) return false;
    var view = std.unicode.Utf8View.initUnchecked(value);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (cp >= 0x80 and cp <= 0x9f) return false;
    return true;
}
pub fn validInlineImage(value: InlineImage) bool {
    if (!validInlineImageFile(value.file)) return false;
    if (value.width_px) |width| if (width == 0) return false;
    if (value.height_px) |height| if (height == 0) return false;
    if (value.alt) |alt| if (!validInlineImageString(alt)) return false;
    if (value.tooltip) |tooltip| if (!validInlineImageString(tooltip)) return false;
    return true;
}
pub fn validInlineImageAction(kind: InlineKind, target: []const u8) bool {
    return switch (kind) {
        .text => target.len == 0,
        .link, .external_link => target.len != 0,
        .line_break => false,
    };
}
fn validateInlineImageMedia(value: InlineImage, media: []const Media) ValidationError!void {
    // The existing compiler caps the shared asset inventory at 128. Apply that
    // bound only to new image occurrences; legacy records keep their old rules.
    if (media.len > 128) return error.InvalidPresentation;
    var matches: usize = 0;
    for (media) |item| if (std.mem.eql(u8, item.file, value.file)) {
        if (item.kind != .image) return error.InvalidPresentation;
        matches += 1;
        if (matches > 1) return error.InvalidPresentation;
    };
    if (matches != 1) return error.InvalidPresentation;
}
fn validateSpanColors(spans: []const Span, media: []const Media) ValidationError!void {
    for (spans) |span| {
        if (span.image) |image| {
            if (span.text.len != 0 or span.trail.len != 0 or !validInlineImage(image) or
                !validInlineImageAction(span.kind, span.target)) return error.InvalidPresentation;
            try validateInlineImageMedia(image, media);
        }
        if (span.font_scale) |scale| if (!std.math.isFinite(scale) or scale < 0) return error.InvalidPresentation;
        if (span.font_scale_basis == .normal_body and span.font_scale == null) return error.InvalidPresentation;
        if (span.foreground) |color| if (!isCanonicalRgb(color)) return error.InvalidPresentation;
        if (span.background) |color| if (!isCanonicalRgb(color)) return error.InvalidPresentation;
    }
}

pub fn validStyleLength(value: StyleLength) bool {
    return std.math.isFinite(value.value) and value.value >= 0;
}
pub fn validStyleEdges(value: StyleEdges) bool {
    return validStyleLength(value.top) and validStyleLength(value.right) and
        validStyleLength(value.bottom) and validStyleLength(value.left);
}
pub fn validBorder(value: StyleBorder) bool {
    return switch (value) {
        .none => true,
        .solid => |solid| validStyleLength(solid.width) and isCanonicalRgb(solid.color),
    };
}
pub fn validTableStyle(value: TableStyle) bool {
    if (value.background == null and value.border == null and value.collapse == null and value.margins == null) return false;
    if (value.background) |color| if (!isCanonicalRgb(color)) return false;
    if (value.border) |border| if (!validBorder(border)) return false;
    if (value.margins) |margins| if (!validStyleEdges(margins)) return false;
    return true;
}
pub fn validCellStyle(value: CellStyle) bool {
    if (value.border == null and value.padding == null and value.text_align == null) return false;
    if (value.border) |border| if (!validBorder(border)) return false;
    if (value.padding) |padding| if (!validStyleEdges(padding)) return false;
    return true;
}
pub fn validTableGeometry(value: TableGeometry) bool {
    if (value.border == null and value.cell_spacing == null and value.cell_padding == null and value.width == null) return false;
    if (value.width) |width| if (width.unit == .percent and width.value > 100) return false;
    return true;
}

fn validateTable(table: Table, depth: usize, media: []const Media) ValidationError!void {
    if (depth > max_table_depth) return error.InvalidPresentation;
    if (table.geometry) |geometry| if (!validTableGeometry(geometry)) return error.InvalidPresentation;
    if (table.style) |style| if (!validTableStyle(style)) return error.InvalidPresentation;
    try validateSpanColors(table.caption, media);
    for (table.rows) |row| for (row.cells) |cell| {
        try validateSpanColors(cell.spans, media);
        if (cell.background) |background| if (!isCanonicalRgb(background)) return error.InvalidPresentation;
        if (cell.style) |style| if (!validCellStyle(style)) return error.InvalidPresentation;
        if (cell.blocks) |blocks| {
            if (cell.spans.len != 0 or cell.nested_table != null) return error.InvalidPresentation;
            for (blocks) |block| try validateBlock(block, depth, media);
        }
        if (cell.nested_table) |child| {
            if (cell.spans.len != 0) return error.InvalidPresentation;
            try validateTable(child, depth + 1, media);
        }
    };
}

fn validateBlock(block: Block, table_depth: usize, media: []const Media) ValidationError!void {
    if ((block.anchor.len != 0 or block.anchor_fallback.len != 0) and block.kind != .heading) return error.InvalidPresentation;
    try validateSpanColors(block.spans, media);
    if (block.table) |table| try validateTable(table, table_depth + 1, media);
}

fn blockIndexValid(indices: []const usize, block_count: usize) bool {
    for (indices) |index| if (index >= block_count) return false;
    return true;
}

pub fn validateStored(
    stored: Stored,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
) ValidationError!void {
    if (!std.mem.eql(u8, stored.schema, schema)) return error.InvalidPresentation;
    const entry = stored.entry;
    if (!std.mem.eql(u8, entry.title, expected_title) or entry.kind != expected_kind) return error.InvalidPresentation;

    if (expected_kind == .language) {
        const metadata = language_metadata orelse return error.InvalidPresentation;
        const language = entry.language orelse return error.InvalidPresentation;
        if (!std.mem.eql(u8, language, metadata.heading)) return error.InvalidPresentation;
        if (entry.language_code.len != 0 and !std.mem.eql(u8, entry.language_code, metadata.code))
            return error.InvalidPresentation;
    } else if (language_metadata != null) return error.InvalidPresentation;

    for (entry.organization.other_sections) |section| if (section >= entry.sections.len)
        return error.InvalidPresentation;

    for (entry.organization.lexemes) |lexeme| {
        if (lexeme.section >= entry.sections.len) return error.InvalidPresentation;
        if (lexeme.etymology) |section| if (section >= entry.sections.len) return error.InvalidPresentation;
        for (lexeme.related_sections) |section| if (section >= entry.sections.len)
            return error.InvalidPresentation;

        const block_count = entry.sections[lexeme.section].blocks.len;
        if (!blockIndexValid(lexeme.introduction, block_count) or !blockIndexValid(lexeme.other_blocks, block_count))
            return error.InvalidPresentation;
        for (lexeme.definitions, 0..) |sense, sense_index| {
            if (sense.block >= block_count) return error.InvalidPresentation;
            if (sense.parent) |parent| if (parent >= sense_index) return error.InvalidPresentation;
            if (!blockIndexValid(sense.examples, block_count) or
                !blockIndexValid(sense.quotations, block_count) or
                !blockIndexValid(sense.notes, block_count)) return error.InvalidPresentation;
        }
    }

    try validateSpanColors(entry.display_title, entry.media);
    try validateSpanColors(entry.preamble_spans, entry.media);
    for (entry.references) |reference| {
        if (reference.blocks) |blocks| {
            if (reference.spans.len != 0) return error.InvalidPresentation;
            for (blocks) |block| try validateBlock(block, 0, entry.media);
        } else try validateSpanColors(reference.spans, entry.media);
    }
    for (entry.sections) |section| for (section.blocks) |block| try validateBlock(block, 0, entry.media);

    for (entry.references) |reference| {
        if (reference.number == 0 or reference.number >= std.math.maxInt(u32)) return error.InvalidPresentation;
        switch (reference.kind) {
            .note => if (reference.group_number == null or reference.group_number.? == 0 or reference.group_number.? == std.math.maxInt(u32)) return error.InvalidPresentation,
            .fragment => if (reference.group_number != null or reference.name.len != 0) return error.InvalidPresentation,
        }
    }
}

test "compiled presentation validation rejects unsafe semantic indices" {
    const sections = [_]Section{.{ .level = 2, .title = "English" }};
    const bad_lexemes = [_]Lexeme{.{ .kind = "Noun", .section = 1 }};
    const stored: Stored = .{ .entry = .{
        .organization = .{ .lexemes = &bad_lexemes },
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
        .sections = &sections,
    } };
    try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "cat", .language, .{ .code = "en", .heading = "English" }));
}

test "reference block authority preserves null JSON and rejects mixed or invalid deep style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const words = [_]Span{.{ .text = "legacy" }};
    const legacy: Reference = .{ .number = 1, .group_number = 1, .spans = &words };
    const legacy_json = try std.json.Stringify.valueAlloc(a, legacy, .{});
    try std.testing.expect(std.mem.indexOf(u8, legacy_json, "\"blocks\"") == null);
    const empty: Reference = .{ .number = 1, .group_number = 1, .blocks = &.{} };
    const empty_json = try std.json.Stringify.valueAlloc(a, empty, .{});
    try std.testing.expect(std.mem.indexOf(u8, empty_json, "\"blocks\":[]") != null);
    var references = [_]Reference{empty};
    const stored: Stored = .{ .entry = .{ .title = "entry", .kind = .language, .language = "English", .language_code = "en", .references = &references } };
    try validateStored(stored, "entry", .language, .{ .code = "en", .heading = "English" });
    references[0].spans = &words;
    try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "entry", .language, .{ .code = "en", .heading = "English" }));
    const invalid_style = [_]Span{.{ .text = "cell", .foreground = "red" }};
    const cells = [_]Cell{.{ .spans = &invalid_style, .header = true }};
    const rows = [_]Row{.{ .cells = &cells }};
    const blocks = [_]Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    references[0] = .{ .number = 1, .group_number = 1, .blocks = &blocks };
    try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "entry", .language, .{ .code = "en", .heading = "English" }));
}

// Additive model controls; append to the selected private model for an authorized
// future qualification. Source/parser checks alone do not execute these tests.

test "style length JSON widens the stored f32 exactly for all style sinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const JsonLength = struct { unit: StyleLengthUnit, value: f64 };
    for ([_]f32{ 0.2, 0, std.math.floatMax(f32) }, [_]f64{ 0.20000000298023224, 0, 3.4028234663852886e38 }) |value, expected| {
        const length: StyleLength = .{ .unit = .em, .value = value };
        const encoded = try std.json.Stringify.valueAlloc(a, length, .{});
        const parsed = try std.json.parseFromSlice(JsonLength, a, encoded, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(StyleLengthUnit.em, parsed.value.unit);
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(parsed.value.value)));
        const expected_json = try std.json.Stringify.valueAlloc(a, JsonLength{ .unit = .em, .value = @as(f64, value) }, .{});
        try std.testing.expectEqualStrings(expected_json, encoded);
        const edges = StyleEdges.all(length);
        const border: StyleBorder = .{ .solid = .{ .width = length, .color = "#aaaaaa" } };
        const nested = TableStyle{ .margins = edges, .border = border };
        const nested_json = try std.json.Stringify.valueAlloc(a, nested, .{});
        const JsonEdges = struct { top: JsonLength, right: JsonLength, bottom: JsonLength, left: JsonLength };
        const JsonBorder = union(enum) { none, solid: struct { width: JsonLength, color: []const u8 } };
        const JsonTableStyle = struct { margins: JsonEdges, border: JsonBorder };
        const nested_parsed = try std.json.parseFromSlice(JsonTableStyle, a, nested_json, .{});
        defer nested_parsed.deinit();
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(nested_parsed.value.margins.left.value)));
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(nested_parsed.value.border.solid.width.value)));
    }
}

test "typed table styles preserve units palette zeros and null JSON omission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const padding = StyleEdges.all(.{ .unit = .em, .value = 0.2 });
    const margins = StyleEdges.all(.{ .unit = .px, .value = 10 });
    const border: StyleBorder = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } };
    const table_style: TableStyle = .{ .background = "#f9f9f9", .border = border, .collapse = .collapse, .margins = margins };
    const cell_style: CellStyle = .{ .border = border, .padding = padding, .text_align = .center };
    try std.testing.expect(validTableStyle(table_style));
    try std.testing.expect(validCellStyle(cell_style));
    try std.testing.expect(!@hasField(TableStyle, "alignment"));
    try std.testing.expectEqualStrings("{\"none\":{}}", try std.json.Stringify.valueAlloc(a, @as(StyleBorder, .none), .{}));
    const border_json = try std.json.Stringify.valueAlloc(a, border, .{});
    try std.testing.expect(std.mem.startsWith(u8, border_json, "{\"solid\":{\"width\":{\"unit\":\"px\",\"value\":"));
    const parsed_border = try std.json.parseFromSlice(StyleBorder, a, border_json, .{});
    defer parsed_border.deinit();
    try std.testing.expectEqualDeep(border, parsed_border.value);
    try std.testing.expectEqualStrings("{\"caption\":[],\"rows\":[]}", try std.json.Stringify.valueAlloc(a, Table{}, .{}));
    try std.testing.expectEqualStrings("{\"spans\":[],\"header\":false,\"colspan\":1,\"rowspan\":1,\"background\":null}", try std.json.Stringify.valueAlloc(a, Cell{}, .{}));
    try std.testing.expectEqualStrings("{\"text_align\":\"left\"}", try std.json.Stringify.valueAlloc(a, CellStyle{ .text_align = .left }, .{}));
    try std.testing.expectEqualStrings("{\"collapse\":\"separate\"}", try std.json.Stringify.valueAlloc(a, TableStyle{ .collapse = .separate }, .{}));
    const zero = StyleEdges.all(.{ .unit = .em, .value = 0 });
    const json = try std.json.Stringify.valueAlloc(a, Cell{ .style = .{ .padding = zero } }, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"style\":{\"padding\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unit\":\"em\",\"value\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text_align\"") == null);
    const header = Cell{ .header = true, .background = "#f2f2f2", .style = cell_style };
    const cells = [_]Cell{ header, .{ .style = .{ .border = border, .padding = padding } } };
    const rows = [_]Row{.{ .cells = &cells }};
    const blocks = [_]Block{.{ .kind = .table, .table = .{ .rows = &rows, .style = table_style } }};
    const refs = [_]Reference{.{ .number = 1, .group_number = 1, .blocks = &blocks }};
    const stored: Stored = .{ .entry = .{ .title = "style", .kind = .supplemental, .references = &refs } };
    try validateStored(stored, "style", .supplemental, null);
    try std.testing.expect(cells[1].background == null);
    try std.testing.expect(cells[1].style.?.text_align == null);
}

test "typed style model rejects empty malformed paint and nonfinite lengths recursively" {
    try std.testing.expect(!validTableStyle(.{}));
    try std.testing.expect(!validCellStyle(.{}));
    try std.testing.expect(validTableStyle(.{ .border = .none }));
    try std.testing.expect(validCellStyle(.{ .border = .none }));
    try std.testing.expect(validStyleLength(.{ .unit = .px, .value = 0 }));
    try std.testing.expect(validStyleLength(.{ .unit = .em, .value = std.math.floatMax(f32) }));
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |number| {
        const length: StyleLength = .{ .unit = .em, .value = number };
        try std.testing.expect(!validStyleLength(length));
        try std.testing.expect(!validStyleEdges(StyleEdges.all(length)));
        try std.testing.expect(!validBorder(.{ .solid = .{ .width = length, .color = "#aaaaaa" } }));
        try std.testing.expect(!validCellStyle(.{ .padding = StyleEdges.all(length) }));
        try std.testing.expect(!validTableStyle(.{ .margins = StyleEdges.all(length) }));
    }
    for ([_][]const u8{ "red", "#aaa", "#AAAAAA", "#12345g", "transparent" }) |color| {
        try std.testing.expect(!validBorder(.{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = color } }));
        try std.testing.expect(!validTableStyle(.{ .background = color }));
    }
    const invalid_cells = [_]Cell{ .{ .style = .{} }, .{ .style = .{ .padding = StyleEdges.all(.{ .unit = .em, .value = -1 }) } } };
    for (invalid_cells) |cell| {
        const cells = [_]Cell{cell};
        const rows = [_]Row{.{ .cells = &cells }};
        const blocks = [_]Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
        const refs = [_]Reference{.{ .number = 1, .group_number = 1, .blocks = &blocks }};
        const stored: Stored = .{ .entry = .{ .title = "invalid", .kind = .supplemental, .references = &refs } };
        try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "invalid", .supplemental, null));
    }
    const blocks = [_]Block{.{ .kind = .table, .table = .{ .style = .{} } }};
    const sections = [_]Section{.{ .level = 2, .title = "invalid", .blocks = &blocks }};
    const stored: Stored = .{ .entry = .{ .title = "invalid", .kind = .supplemental, .sections = &sections } };
    try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "invalid", .supplemental, null));
}

// Append-only controls for the private inline-image successor model.

test "inline image JSON omits null preserves empty and keeps existing actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const icon: InlineImage = .{ .file = "Vraagteken-2.svg", .width_px = 15 };
    try std.testing.expectEqualStrings("{\"file\":\"Vraagteken-2.svg\",\"width_px\":15}", try std.json.Stringify.valueAlloc(a, icon, .{}));
    const empty: InlineImage = .{ .file = "Icon.svg", .alt = "", .tooltip = "" };
    try std.testing.expectEqualStrings("{\"file\":\"Icon.svg\",\"alt\":\"\",\"tooltip\":\"\"}", try std.json.Stringify.valueAlloc(a, empty, .{}));
    const span: Span = .{ .kind = .link, .target = "File:Vraagteken-2.svg", .image = icon };
    const json = try std.json.Stringify.valueAlloc(a, span, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"image\":{\"file\":\"Vraagteken-2.svg\",\"width_px\":15}") != null);
    try std.testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(a, Span{}, .{}), "\"image\"") == null);
    try std.testing.expect(validInlineImage(icon));
    try std.testing.expect(validInlineImage(.{ .file = "Icon.svg", .width_px = std.math.maxInt(u32), .height_px = std.math.maxInt(u32) }));
    try std.testing.expect(validInlineImageAction(.text, ""));
    try std.testing.expect(validInlineImageAction(.link, "Target"));
    try std.testing.expect(validInlineImageAction(.external_link, "https://example.invalid/"));
    try std.testing.expect(!validInlineImageAction(.line_break, ""));
    try std.testing.expect(!validInlineImageAction(.text, "Target"));
    try std.testing.expect(!validInlineImageAction(.link, ""));
    try std.testing.expect(!validInlineImageAction(.external_link, ""));
}

test "inline image model rejects invalid dimensions strings actions and asset joins" {
    for ([_][]const u8{ "Parent:Child/Icon.svg", "plain file.svg", "\u{05d0}.svg" }) |file|
        try std.testing.expect(validInlineImageFile(file));
    for ([_][]const u8{ "[Icon].svg", "{Icon}.svg", "<Icon>.svg", "Icon|bad.svg", "Icon#bad.svg", " Icon.svg", "Icon.svg ", "Icon_name.svg", "Icon\x00.svg", "Icon\r.svg", "Icon\n.svg", "Icon\x7f.svg", "Icon\u{0085}.svg" }) |file| {
        try std.testing.expect(!validInlineImageFile(file));
        const spans = [_]Span{.{ .image = .{ .file = file } }};
        const media = [_]Media{.{ .file = file, .kind = .image, .caption = "" }};
        const malformed: Stored = .{ .entry = .{ .title = "bad file", .kind = .supplemental, .display_title = &spans, .media = &media } };
        try std.testing.expectError(error.InvalidPresentation, validateStored(malformed, "bad file", .supplemental, null));
    }
    // Protected plain alternative text is data, not another title/source grammar.
    try std.testing.expect(validInlineImage(.{ .file = "Icon.svg", .alt = "[[literal]] {{text}} <value>", .tooltip = "{{plain}}" }));
    for ([_]InlineImage{
        .{ .file = "" },
        .{ .file = "Icon.svg", .width_px = 0 },
        .{ .file = "Icon.svg", .height_px = 0 },
        .{ .file = "\xff" },
        .{ .file = "Icon.svg", .alt = "\xff" },
        .{ .file = "Icon.svg", .tooltip = "\xff" },
    }) |image| try std.testing.expect(!validInlineImage(image));
    const span = [_]Span{.{ .kind = .link, .target = "File:Icon.svg", .image = .{ .file = "Icon.svg" } }};
    const good = [_]Media{.{ .file = "Icon.svg", .kind = .image, .caption = "" }};
    const wrong = [_]Media{.{ .file = "Icon.svg", .kind = .audio, .caption = "" }};
    const duplicate = [_]Media{ good[0], good[0] };
    const ambiguous = [_]Media{ good[0], wrong[0] };
    var stored: Stored = .{ .entry = .{ .title = "image", .kind = .supplemental, .display_title = &span, .media = &good } };
    try validateStored(stored, "image", .supplemental, null);
    for ([_][]const Media{ &.{}, &wrong, &duplicate, &ambiguous }) |media| {
        stored.entry.media = media;
        try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "image", .supplemental, null));
    }
    var too_many: [129]Media = undefined;
    @memset(&too_many, good[0]);
    stored.entry.media = &too_many;
    try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "image", .supplemental, null));
    // The new asset bound does not change validation for records with no images.
    stored.entry.display_title = &.{};
    try validateStored(stored, "image", .supplemental, null);
    stored.entry.media = &good;
    for ([_]Span{
        .{ .text = "kept", .image = .{ .file = "Icon.svg" } },
        .{ .trail = "kept", .image = .{ .file = "Icon.svg" } },
        .{ .kind = .line_break, .image = .{ .file = "Icon.svg" } },
        .{ .kind = .text, .target = "Target", .image = .{ .file = "Icon.svg" } },
        .{ .kind = .link, .image = .{ .file = "Icon.svg" } },
        .{ .kind = .external_link, .image = .{ .file = "Icon.svg" } },
    }) |invalid| {
        const values = [_]Span{invalid};
        stored.entry.display_title = &values;
        try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "image", .supplemental, null));
    }
}

test "inline image model validates joins inside nested cells and reference blocks" {
    const images = [_]Span{.{ .image = .{ .file = "Icon.svg", .width_px = 15, .alt = "", .tooltip = "" } }};
    const child_cells = [_]Cell{.{ .spans = &images }};
    const child_rows = [_]Row{.{ .cells = &child_cells }};
    const child_blocks = [_]Block{.{ .kind = .table, .table = .{ .caption = &images, .rows = &child_rows } }};
    const parent_cells = [_]Cell{.{ .blocks = &child_blocks }};
    const parent_rows = [_]Row{.{ .cells = &parent_cells }};
    const blocks = [_]Block{.{ .kind = .table, .table = .{ .rows = &parent_rows } }};
    const refs = [_]Reference{.{ .number = 1, .group_number = 1, .blocks = &blocks }};
    const media = [_]Media{.{ .file = "Icon.svg", .kind = .image, .caption = "metadata" }};
    var stored: Stored = .{ .entry = .{ .title = "nested", .kind = .supplemental, .references = &refs, .media = &media } };
    try validateStored(stored, "nested", .supplemental, null);
    stored.entry.media = &.{};
    try std.testing.expectError(error.InvalidPresentation, validateStored(stored, "nested", .supplemental, null));
}
