const std = @import("std");
const format = @import("blob_format.zig");

pub const schema = "dict.presentation.v3";
// DPRE extends the private catalog capacity; earlier image records retain128.
pub const legacy_inline_image_assets: usize = 128;
pub const legacy_extended_image_assets: usize = 256;
// The wire aggregate budget is unchanged; G removes only the image-specific ceiling.
pub const max_presentation_items: usize = 1 << 20;
pub const Role = enum { normal, label, pronunciation, headword, example, quotation, citation, reference };
pub const InlineKind = enum { text, link, external_link, line_break };
pub const FontScaleBasis = enum { context, normal_body };
pub const max_image_map_string_bytes: usize = 32 * 1024 * 1024;
pub const MapActionKind = enum { internal, external };
pub const MapAction = struct {
    kind: MapActionKind,
    target: []const u8,
    target_fragment: ?[]const u8 = null,
    label: []const u8,
};
pub const MapShape = enum { rectangle, circle, polygon };
pub const MapRegion = struct { shape: MapShape, coordinates: []const f64, action: MapAction };
pub const MapDescription = enum { none, top_right, bottom_right, bottom_left, top_left };
pub const ImageMap = struct {
    regions: []const MapRegion = &.{},
    default_action: ?MapAction = null,
    description: MapDescription = .bottom_right,
};
pub const InlineImage = struct {
    file: []const u8,
    width_px: ?u32 = null,
    height_px: ?u32 = null,
    alt: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    /// MediaWiki border decoration; one logical pixel outside content dimensions.
    border: bool = false,
    map: ?ImageMap = null,

    pub fn jsonStringify(self: InlineImage, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(self.file);
        inline for (.{ "width_px", "height_px", "alt", "tooltip", "map" }) |name| {
            if (@field(self, name)) |value| {
                try jw.objectField(name);
                try jw.write(value);
            }
        }
        if (self.border) {
            try jw.objectField("border");
            try jw.write(true);
        }
        try jw.endObject();
    }
};
pub const Span = struct {
    kind: InlineKind = .text,
    text: []const u8 = "",
    target: []const u8 = "",
    // null retains legacy combined title#fragment; non-null separates components.
    target_fragment: ?[]const u8 = null,
    trail: []const u8 = "",
    language: []const u8 = "",
    classes: []const u8 = "",
    direction: []const u8 = "",
    explanation: []const u8 = "",
    /// Effective advisory title: null is absent, empty explicitly suppresses advice.
    /// Separate from abbreviation expansion and from InlineImage.tooltip.
    tooltip: ?[]const u8 = null,
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
            const fragment_field = comptime std.mem.eql(u8, field_name, "target_fragment");
            const background_field = comptime std.mem.eql(u8, field_name, "background");
            const scale_field = comptime std.mem.eql(u8, field_name, "font_scale");
            const basis_field = comptime std.mem.eql(u8, field_name, "font_scale_basis");
            const image_field = comptime std.mem.eql(u8, field_name, "image");
            if ((!fragment_field or self.target_fragment != null) and (!image_field or self.image != null) and (!background_field or self.background != null) and
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
pub const max_content_depth: usize = 16;
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
pub const StyleWidthUnit = enum { px, em, percent };
/// Resolved CSS width request; em uses the normal-body typography basis.
pub const StyleWidth = struct {
    unit: StyleWidthUnit,
    value: f32,
    pub fn jsonStringify(self: StyleWidth, jw: anytype) !void {
        try jw.beginObject(); try jw.objectField("unit"); try jw.write(self.unit);
        try jw.objectField("value"); try jw.write(@as(f64, self.value)); try jw.endObject();
    }
};
pub fn validStyleWidth(value: StyleWidth) bool { return std.math.isFinite(value.value) and value.value >= 0; }
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
pub const TableFloatSide = enum { left, right };
pub const TableStyle = struct {
    background: ?[]const u8 = null,
    border: ?StyleBorder = null,
    collapse: ?BorderCollapse = null,
    margins: ?StyleEdges = null,
    float_side: ?TableFloatSide = null,
    width: ?StyleWidth = null,
    padding: ?StyleEdges = null,
    clear: ?FigureClear = null,

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
    /// Non-null is authoritative; flat caption must be empty.
    caption_blocks: ?[]const Block = null,
    rows: []const Row = &.{},
    geometry: ?TableGeometry = null,
    style: ?TableStyle = null,

    pub fn jsonStringify(self: Table, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("caption");
        try jw.write(self.caption);
        if (self.caption_blocks) |blocks| { try jw.objectField("caption_blocks"); try jw.write(blocks); }
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
/// Non-inherited geometry for an ordinary, unfeatured depth-zero paragraph.
pub const BlockStyle = struct {
    margins: ?StyleEdges = null,
    padding: ?StyleEdges = null,

    pub fn jsonStringify(self: BlockStyle, jw: anytype) !void {
        try writeOptionalStyleFields(self, jw);
    }
};
pub const FigureFormat = enum { thumbnail, framed };
pub const FigureSizingPolicy = enum { intrinsic, original_width_with_height_bound, requested_fit, requested_fit_cap_original_width };
pub const FigurePlacement = enum { none, center, float_left, float_right };
pub const FigureClear = enum { none, left, right, both };
pub const FigureColorKind = enum { native_theme, transparent, rgb };
pub const FigureColor = struct {
    kind: FigureColorKind,
    value: ?[]const u8 = null,
    pub fn jsonStringify(self: FigureColor, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("kind"); try jw.write(self.kind);
        if (self.value) |value| { try jw.objectField("value"); try jw.write(value); }
        try jw.endObject();
    }
};
pub const FigureBorderKind = enum { none, solid };
pub const FigureBorder = struct {
    kind: FigureBorderKind,
    width: ?StyleLength = null,
    color: ?FigureColor = null,
    pub fn jsonStringify(self: FigureBorder, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("kind"); try jw.write(self.kind);
        if (self.width) |width| { try jw.objectField("width"); try jw.write(width); }
        if (self.color) |color| { try jw.objectField("color"); try jw.write(color); }
        try jw.endObject();
    }
};
pub const Figure = struct {
    image_span: Span,
    caption: []const Span = &.{},
    caption_text_align: ?CellTextAlign = null,
    /// Non-null is authoritative, including an explicitly empty caption.
    caption_blocks: ?[]const Block = null,
    format: FigureFormat,
    /// Required resolved policy; no reader MIME inference or implicit default.
    sizing: FigureSizingPolicy,
    /// Physical content-box CSS floor, separate from media axes and margins.
    frame_min_width: ?StyleLength = null,
    placement: FigurePlacement,
    clear: FigureClear,
    margins: StyleEdges,
    image_insets: StyleEdges,
    caption_padding: StyleEdges,
    caption_font_scale: f32,
    caption_line_height: StyleLength,
    frame_background: FigureColor,
    frame_border: FigureBorder,
    image_background: FigureColor,
    image_border: FigureBorder,
    caption_foreground: FigureColor,
    caption_background: FigureColor,
    pub fn jsonStringify(self: Figure, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Figure).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "frame_min_width")) {
                if (self.frame_min_width) |minimum| { try jw.objectField(name); try jw.write(minimum); }
            } else if (comptime std.mem.eql(u8, name, "caption_font_scale")) {
                try jw.objectField(name); try jw.write(@as(f64, self.caption_font_scale));
            } else if (comptime std.mem.eql(u8, name, "caption_text_align")) {
                if (self.caption_text_align) |alignment| { try jw.objectField(name); try jw.write(alignment); }
            } else if (comptime std.mem.eql(u8, name, "caption_blocks")) {
                if (self.caption_blocks) |blocks| { try jw.objectField(name); try jw.write(blocks); }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }
};
pub const BidiMode = enum { isolate, isolate_override };
pub const BidiDirectionInput = enum { ltr, rtl, auto };
pub const BidiResolvedDirection = enum { ltr, rtl };
/// Authored semantic input and compiled result stay distinct. All fields,
/// including nullable metadata, are named in JSON; consumers never rerun auto.
pub const BidiScope = struct {
    mode: BidiMode,
    authored_direction: ?BidiDirectionInput = null,
    resolved_direction: BidiResolvedDirection,
    language: ?[]const u8 = null,
    parts: []const FlowPart,
};
pub const FlowPartKind = enum { @"inline", figure, scope };
pub const FlowPart = struct {
    kind: FlowPartKind,
    spans: []const Span = &.{},
    figure: ?Figure = null,
    scope: ?BidiScope = null,
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
    text_align: ?CellTextAlign = null,
    style: ?BlockStyle = null,
    figure: ?Figure = null,
    /// Anonymous ordered content; parent block owns role, list, geometry and spacing.
    flow: ?[]const FlowPart = null,

    pub fn jsonStringify(self: Block, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Block).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "text_align") or std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "figure") or std.mem.eql(u8, name, "flow")) {
                if (@field(self, name)) |present| {
                    try jw.objectField(name);
                    try jw.write(present);
                }
            } else {
                try jw.objectField(name);
                try jw.write(@field(self, name));
            }
        }
        try jw.endObject();
    }
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

pub const ValidationError = error{ InvalidPresentation, OutOfMemory };

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
pub fn validMapAction(value: MapAction) bool {
    if (!validInlineImageString(value.target) or !validInlineImageString(value.label)) return false;
    if (value.target_fragment) |fragment| if (!validTargetFragment(fragment)) return false;
    return switch (value.kind) {
        .internal => value.target.len != 0 or value.target_fragment != null,
        .external => value.target.len != 0 and value.target_fragment == null,
    };
}
pub fn validMapCoordinateCount(shape: MapShape, count: usize) bool {
    return switch (shape) { .rectangle => count == 4, .circle => count == 3, .polygon => count >= 6 and count % 2 == 0 };
}
pub fn validMapRegion(value: MapRegion) bool {
    if (!validMapCoordinateCount(value.shape, value.coordinates.len)) return false;
    for (value.coordinates) |coordinate| if (!std.math.isFinite(coordinate)) return false;
    return validMapAction(value.action);
}
const MapValidationBudget = struct {
    remaining_items: usize = max_presentation_items,
    remaining_string_bytes: usize = max_image_map_string_bytes,
    fn items(self: *MapValidationBudget, count: usize) bool {
        if (count > self.remaining_items) return false;
        self.remaining_items -= count;
        return true;
    }
    fn string(self: *MapValidationBudget, text: []const u8) bool {
        if (text.len > self.remaining_string_bytes) return false;
        self.remaining_string_bytes -= text.len;
        return true;
    }
    fn action(self: *MapValidationBudget, value: MapAction) bool {
        if (!validMapAction(value) or !self.string(value.target) or !self.string(value.label)) return false;
        if (value.target_fragment) |fragment| if (!self.string(fragment)) return false;
        return true;
    }
    fn map(self: *MapValidationBudget, value: ImageMap) bool {
        if (!self.items(value.regions.len)) return false;
        for (value.regions) |region| {
            if (!self.items(region.coordinates.len) or !validMapRegion(region) or !self.action(region.action)) return false;
        }
        if (value.default_action) |fallback| if (!self.items(1) or !self.action(fallback)) return false;
        return true;
    }
};
pub fn validImageMap(value: ImageMap) bool {
    var budget: MapValidationBudget = .{};
    return budget.map(value);
}
pub fn validInlineImage(value: InlineImage) bool {
    if (!validInlineImageFile(value.file)) return false;
    if (value.width_px) |width| if (width == 0) return false;
    if (value.height_px) |height| if (height == 0) return false;
    if (value.alt) |alt| if (!validInlineImageString(alt)) return false;
    if (value.tooltip) |tooltip| if (!validInlineImageString(tooltip)) return false;
    if (value.map) |map| if (!validImageMap(map)) return false;
    return true;
}
// This new optional component has the same string ceiling/UTF8 contract as wire strings.
pub fn validTargetFragment(value: []const u8) bool {
    return value.len <= 32 * 1024 * 1024 and std.unicode.utf8ValidateSlice(value);
}
pub fn validInlineImageAction(kind: InlineKind, target: []const u8) bool {
    return switch (kind) {
        .text => target.len == 0,
        .link, .external_link => target.len != 0,
        .line_break => false,
    };
}
/// Borrowed filenames, owned index storage; immutable after construction.
/// Only referenced identities must be unique images, as in the older validator.
pub const ImageCatalogIndex = struct {
    const Value = struct { image: bool, duplicate: bool = false };
    values: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn init(a: std.mem.Allocator, media: anytype) ValidationError!ImageCatalogIndex {
        if (media.len > max_presentation_items) return error.InvalidPresentation;
        var result: ImageCatalogIndex = .{};
        errdefer result.deinit(a);
        try result.values.ensureTotalCapacity(a, @intCast(media.len));
        for (media) |item| {
            const slot = result.values.getOrPutAssumeCapacity(item.file);
            if (slot.found_existing) slot.value_ptr.duplicate = true
            else slot.value_ptr.* = .{ .image = item.kind == .image };
        }
        return result;
    }
    pub fn deinit(self: *ImageCatalogIndex, a: std.mem.Allocator) void {
        self.values.deinit(a);
        self.* = .{};
    }
    pub fn validate(self: *const ImageCatalogIndex, file: []const u8) error{InvalidPresentation}!void {
        const value = self.values.get(file) orelse return error.InvalidPresentation;
        if (!value.image or value.duplicate) return error.InvalidPresentation;
    }
};

const ImageValidation = struct {
    a: std.mem.Allocator,
    media: []const Media,
    index: ?ImageCatalogIndex = null,
    maps: MapValidationBudget = .{},
    content_depth: usize = 0,

    fn deinit(self: *ImageValidation) void {
        if (self.index) |*index| index.deinit(self.a);
    }
    fn validate(self: *ImageValidation, image: InlineImage) ValidationError!void {
        if (image.map) |map| if (!self.maps.map(map)) return error.InvalidPresentation;
        // Media-only records retain their historical admission and allocate no index.
        if (self.index == null) self.index = try ImageCatalogIndex.init(self.a, self.media);
        const index: *const ImageCatalogIndex = &self.index.?;
        try index.validate(image.file);
    }
};
fn validateSpanColors(spans: []const Span, media: *ImageValidation) ValidationError!void {
    for (spans) |span| {
        if (span.tooltip) |advice| if (!std.unicode.utf8ValidateSlice(advice)) return error.InvalidPresentation;
        if (span.target_fragment) |fragment| if (span.kind != .link or !validTargetFragment(fragment)) return error.InvalidPresentation;
        if (span.image) |image| {
            if (span.text.len != 0 or span.trail.len != 0 or !validInlineImage(image) or
                !validInlineImageAction(span.kind, span.target)) return error.InvalidPresentation;
            try media.validate(image);
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
    if (value.background == null and value.border == null and value.collapse == null and value.margins == null and value.float_side == null and value.width == null and value.padding == null and value.clear == null) return false;
    if (value.background) |color| if (!isCanonicalRgb(color)) return false;
    if (value.border) |border| if (!validBorder(border)) return false;
    if (value.margins) |margins| if (!validStyleEdges(margins)) return false;
    if (value.width) |width| if (!validStyleWidth(width)) return false;
    if (value.padding) |padding| if (!validStyleEdges(padding)) return false;
    return true;
}
pub fn validCellStyle(value: CellStyle) bool {
    if (value.border == null and value.padding == null and value.text_align == null) return false;
    if (value.border) |border| if (!validBorder(border)) return false;
    if (value.padding) |padding| if (!validStyleEdges(padding)) return false;
    return true;
}
pub fn validFigureColor(value: FigureColor) bool {
    return switch (value.kind) {
        .native_theme, .transparent => value.value == null,
        .rgb => if (value.value) |color| isCanonicalRgb(color) else false,
    };
}
pub fn validFigureBorder(value: FigureBorder) bool {
    return switch (value.kind) {
        .none => value.width == null and value.color == null,
        .solid => value.width != null and value.color != null and validStyleLength(value.width.?) and validFigureColor(value.color.?),
    };
}
// BuildFigure mirrors these fields but keeps a compiler Span. Do not cast that
// span to Stored or discard its packed flags/provenance to validate geometry.
pub fn validFigureGeometry(value: anytype) bool {
    return validStyleEdges(value.margins) and validStyleEdges(value.image_insets) and validStyleEdges(value.caption_padding) and
        std.math.isFinite(value.caption_font_scale) and value.caption_font_scale >= 0 and validStyleLength(value.caption_line_height) and
        validFigureColor(value.frame_background) and validFigureBorder(value.frame_border) and
        validFigureColor(value.image_background) and validFigureBorder(value.image_border) and
        validFigureColor(value.caption_foreground) and validFigureColor(value.caption_background);
}
/// Pure context/axis checks only. Handler, revision, rotation and site-profile
/// evidence select policy in the producer and are never guessed by decoders.
pub fn validFigureSizingContext(figure_format: FigureFormat, policy: FigureSizingPolicy, width_px: ?u32, height_px: ?u32) bool {
    if (width_px) |width| if (width == 0) return false;
    if (height_px) |height| if (height == 0) return false;
    return switch (policy) {
        .intrinsic => figure_format == .framed,
        .original_width_with_height_bound => figure_format == .framed and height_px != null,
        .requested_fit, .requested_fit_cap_original_width => figure_format == .thumbnail and width_px != null,
    };
}
pub fn validFigureFrameMinWidth(value: StyleLength) bool {
    return value.unit == .px and validStyleLength(value);
}
pub fn validFigure(value: Figure) bool {
    if (value.frame_min_width) |minimum| if (!validFigureFrameMinWidth(minimum)) return false;
    if (!validFigureGeometry(value) or (value.caption_blocks != null and value.caption.len != 0)) return false;
    const span = value.image_span;
    const image = span.image orelse return false;
    if (!validFigureSizingContext(value.format, value.sizing, image.width_px, image.height_px)) return false;
    if (span.text.len != 0 or span.trail.len != 0 or !validInlineImage(image) or !validInlineImageAction(span.kind, span.target)) return false;
    if (span.target_fragment) |fragment| if (span.kind != .link or !validTargetFragment(fragment)) return false;
    if (span.tooltip) |tooltip| if (!std.unicode.utf8ValidateSlice(tooltip)) return false;
    if (span.font_scale) |scale| if (!std.math.isFinite(scale) or scale < 0) return false;
    if (span.font_scale_basis == .normal_body and span.font_scale == null) return false;
    if (span.foreground) |color| if (!isCanonicalRgb(color)) return false;
    if (span.background) |color| if (!isCanonicalRgb(color)) return false;
    return true;
}
/// Header-only: recursive children must pass the shared bounded traversal.
/// Generic BuildScope retains compiler FlowParts/Spans and their provenance.
pub fn validBidiScopeHeader(value: anytype) bool {
    if (value.language) |language| if (language.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(language)) return false;
    if (value.authored_direction) |direction| switch (direction) {
        .ltr => if (value.resolved_direction != .ltr) return false,
        .rtl => if (value.resolved_direction != .rtl) return false,
        .auto => if (value.mode == .isolate_override) return false,
    } else if (value.mode == .isolate_override) return false;
    return true;
}
pub fn validFlowPart(value: FlowPart) bool {
    return switch (value.kind) {
        .@"inline" => value.figure == null and value.scope == null,
        .figure => value.spans.len == 0 and value.scope == null and value.figure != null and validFigure(value.figure.?),
        .scope => value.spans.len == 0 and value.figure == null and value.scope != null and validBidiScopeHeader(value.scope.?),
    };
}
// The compiler already preserves these seven typed list roles, paths, depths
// and numbers. Content ownership must not coerce them into list_item or add
// new marker/path rules that ordinary compiled list blocks do not require.
fn isListContentKind(kind: BlockKind) bool {
    return switch (kind) {
        .list_item, .definition, .example, .quotation, .term, .list_detail, .indent => true,
        else => false,
    };
}
pub fn validFlowContext(kind: BlockKind, depth: u8, has_table: bool, has_feature: bool, has_figure: bool, list_path: []const u8) bool {
    if (has_table or has_feature or has_figure) return false;
    return isListContentKind(kind) or (kind == .paragraph and depth == 0 and list_path.len == 0);
}
pub fn validFigureContext(kind: BlockKind, depth: u8, has_table: bool, has_feature: bool, has_block_style: bool, list_path: []const u8) bool {
    if (has_table or has_feature or has_block_style) return false;
    return isListContentKind(kind) or (kind == .paragraph and depth == 0 and list_path.len == 0);
}
pub fn validBlockStyle(value: BlockStyle) bool {
    if (value.margins == null and value.padding == null) return false;
    if (value.margins) |margins| if (!validStyleEdges(margins)) return false;
    if (value.padding) |padding| if (!validStyleEdges(padding)) return false;
    return true;
}
pub fn validBlockStyleContext(kind: BlockKind, depth: u8, has_table: bool, has_feature: bool, list_path: []const u8) bool {
    return kind == .paragraph and depth == 0 and !has_table and !has_feature and list_path.len == 0;
}
pub fn validTableGeometry(value: TableGeometry) bool {
    if (value.border == null and value.cell_spacing == null and value.cell_padding == null and value.width == null) return false;
    if (value.width) |width| if (width.unit == .percent and width.value > 100) return false;
    return true;
}

fn validateTable(table: Table, depth: usize, media: *ImageValidation) ValidationError!void {
    if (depth > max_table_depth) return error.InvalidPresentation;
    if (table.geometry) |geometry| if (!validTableGeometry(geometry)) return error.InvalidPresentation;
    if (table.style) |style| if (!validTableStyle(style)) return error.InvalidPresentation;
    if (table.caption_blocks) |blocks| {
        if (table.caption.len != 0) return error.InvalidPresentation;
        try validateCaptionBlocks(blocks, depth, media);
    } else try validateSpanColors(table.caption, media);
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

fn validateCaptionBlocks(blocks: []const Block, table_depth: usize, media: *ImageValidation) ValidationError!void {
    if (media.content_depth >= max_content_depth) return error.InvalidPresentation;
    media.content_depth += 1; defer media.content_depth -= 1;
    for (blocks) |block| try validateBlock(block, table_depth, media);
}
fn validateFigureContent(figure: Figure, table_depth: usize, media: *ImageValidation) ValidationError!void {
    if (!validFigure(figure)) return error.InvalidPresentation;
    try validateSpanColors(&.{figure.image_span}, media);
    if (figure.caption_blocks) |blocks| try validateCaptionBlocks(blocks, table_depth, media) else try validateSpanColors(figure.caption, media);
}
fn validateFlowParts(parts: []const FlowPart, table_depth: usize, media: *ImageValidation) ValidationError!void {
    for (parts) |part| {
        if (!validFlowPart(part)) return error.InvalidPresentation;
        switch (part.kind) {
            .@"inline" => try validateSpanColors(part.spans, media),
            .figure => try validateFigureContent(part.figure.?, table_depth, media),
            .scope => {
                if (media.content_depth >= max_content_depth) return error.InvalidPresentation;
                media.content_depth += 1; defer media.content_depth -= 1;
                try validateFlowParts(part.scope.?.parts, table_depth, media);
            },
        }
    }
}
fn validateBlock(block: Block, table_depth: usize, media: *ImageValidation) ValidationError!void {
    if (block.flow) |flow| {
        if (block.spans.len != 0 or !validFlowContext(block.kind, block.depth, block.table != null, block.feature != null, block.figure != null, block.list_path) or media.content_depth >= max_content_depth) return error.InvalidPresentation;
        media.content_depth += 1; defer media.content_depth -= 1;
        try validateFlowParts(flow, table_depth, media);
    }
    if (block.figure) |figure| {
        if (block.spans.len != 0 or !validFigureContext(block.kind, block.depth, block.table != null, block.feature != null, block.style != null, block.list_path)) return error.InvalidPresentation;
        try validateFigureContent(figure, table_depth, media);
    }
    if (block.style) |style| {
        if (!validBlockStyle(style) or !validBlockStyleContext(block.kind, block.depth, block.table != null, block.feature != null, block.list_path)) return error.InvalidPresentation;
    }
    if ((block.anchor.len != 0 or block.anchor_fallback.len != 0) and block.kind != .heading) return error.InvalidPresentation;
    try validateSpanColors(block.spans, media);
    if (block.table) |table| try validateTable(table, table_depth + 1, media);
}

fn blockIndexValid(indices: []const usize, block_count: usize) bool {
    for (indices) |index| if (index >= block_count) return false;
    return true;
}

pub fn validateStored(
    a: std.mem.Allocator,
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

    var media: ImageValidation = .{ .a = a, .media = entry.media };
    defer media.deinit();
    try validateSpanColors(entry.display_title, &media);
    try validateSpanColors(entry.preamble_spans, &media);
    for (entry.references) |reference| {
        if (reference.blocks) |blocks| {
            if (reference.spans.len != 0) return error.InvalidPresentation;
            for (blocks) |block| try validateBlock(block, 0, &media);
        } else try validateSpanColors(reference.spans, &media);
    }
    for (entry.sections) |section| for (section.blocks) |block| try validateBlock(block, 0, &media);

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
    try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "cat", .language, .{ .code = "en", .heading = "English" }));
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
    try validateStored(std.testing.allocator, stored, "entry", .language, .{ .code = "en", .heading = "English" });
    references[0].spans = &words;
    try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "entry", .language, .{ .code = "en", .heading = "English" }));
    const invalid_style = [_]Span{.{ .text = "cell", .foreground = "red" }};
    const cells = [_]Cell{.{ .spans = &invalid_style, .header = true }};
    const rows = [_]Row{.{ .cells = &cells }};
    const blocks = [_]Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    references[0] = .{ .number = 1, .group_number = 1, .blocks = &blocks };
    try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "entry", .language, .{ .code = "en", .heading = "English" }));
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
    try validateStored(std.testing.allocator, stored, "style", .supplemental, null);
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
        try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "invalid", .supplemental, null));
    }
    const blocks = [_]Block{.{ .kind = .table, .table = .{ .style = .{} } }};
    const sections = [_]Section{.{ .level = 2, .title = "invalid", .blocks = &blocks }};
    const stored: Stored = .{ .entry = .{ .title = "invalid", .kind = .supplemental, .sections = &sections } };
    try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "invalid", .supplemental, null));
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
        try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, malformed, "bad file", .supplemental, null));
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
    try validateStored(std.testing.allocator, stored, "image", .supplemental, null);
    for ([_][]const Media{ &.{}, &wrong, &duplicate, &ambiguous }) |media| {
        stored.entry.media = media;
        try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "image", .supplemental, null));
    }
    var too_many: [legacy_extended_image_assets + 1]Media = undefined;
    @memset(&too_many, good[0]);
    stored.entry.media = &too_many;
    try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "image", .supplemental, null));
    // Duplicate unreferenced catalog entries remain valid in media-only records.
    stored.entry.display_title = &.{};
    try validateStored(std.testing.allocator, stored, "image", .supplemental, null);
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
        try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "image", .supplemental, null));
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
    try validateStored(std.testing.allocator, stored, "nested", .supplemental, null);
    stored.entry.media = &.{};
    try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "nested", .supplemental, null));
}

test "image border JSON defaults preserve legacy shape and reject nonboolean input" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.json.Stringify.value(InlineImage{ .file = "Flag.svg", .width_px = 40 }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"file\":\"Flag.svg\",\"width_px\":40}", out.written());
    out.clearRetainingCapacity();
    try std.json.Stringify.value(InlineImage{ .file = "Flag.svg", .width_px = 40, .border = true }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"file\":\"Flag.svg\",\"width_px\":40,\"border\":true}", out.written());
    const parsed = try std.json.parseFromSlice(InlineImage, a, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.border and parsed.value.width_px.? == 40);
    for ([_][]const u8{ "{\"file\":\"Flag.svg\",\"border\":1}", "{\"file\":\"Flag.svg\",\"border\":\"true\"}", "{\"file\":\"Flag.svg\",\"border\":null}" }) |source| {
        const invalid = std.json.parseFromSlice(InlineImage, a, source, .{});
        if (invalid) |value| { value.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
}

test "block alignment and table float JSON distinguish null from explicit physical sides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = struct {
        kind: BlockKind = .paragraph,
        depth: u8 = 0,
        spans: []const Span = &.{},
        feature: ?Feature = null,
        list_path: []const u8 = "",
        number: []const u8 = "",
        level: u8 = 0,
        anchor: []const u8 = "",
        anchor_fallback: []const u8 = "",
        table: ?Table = null,
    }{};
    const legacy = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expectEqualStrings(legacy, try std.json.Stringify.valueAlloc(a, Block{ .kind = .paragraph }, .{}));
    try std.testing.expectEqualStrings(legacy, try std.json.Stringify.valueAlloc(a, Block{ .kind = .paragraph, .text_align = null }, .{}));
    for ([_]CellTextAlign{ .left, .center, .right }) |alignment| {
        const json = try std.json.Stringify.valueAlloc(a, Block{ .kind = .paragraph, .text_align = alignment }, .{});
        const suffix = try std.fmt.allocPrint(a, ",\"text_align\":\"{s}\"}}", .{@tagName(alignment)});
        try std.testing.expect(std.mem.endsWith(u8, json, suffix));
    }
    try std.testing.expect(!validTableStyle(.{}));
    for ([_]TableFloatSide{ .left, .right }) |side| {
        const style: TableStyle = .{ .float_side = side };
        try std.testing.expect(validTableStyle(style));
        const expected = try std.fmt.allocPrint(a, "{{\"float_side\":\"{s}\"}}", .{@tagName(side)});
        try std.testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(a, style, .{}));
    }
    try std.testing.expectEqualStrings("{\"collapse\":\"separate\"}", try std.json.Stringify.valueAlloc(a, TableStyle{ .collapse = .separate, .float_side = null }, .{}));
    try std.testing.expect(!validTableStyle(.{ .float_side = .right, .margins = StyleEdges.all(.{ .unit = .em, .value = -1 }) }));
}

test "generic span tooltip JSON distinguishes null empty and explanation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]?[]const u8{ null, "", "literal \"quote\" & <advice>\nsecond line" }) |advice| {
        const value: Span = .{ .kind = .link, .text = "visible", .target = "Target", .explanation = "abbreviation expansion", .tooltip = advice };
        const json = try std.json.Stringify.valueAlloc(a, value, .{});
        const decoded = try std.json.parseFromSlice(Span, a, json, .{});
        try std.testing.expectEqualDeep(value, decoded.value);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"tooltip\":") != null);
        if (advice == null) try std.testing.expect(std.mem.indexOf(u8, json, "\"tooltip\":null") != null);
        if (advice) |text| try std.testing.expectEqualStrings(text, decoded.value.tooltip.?);
        try std.testing.expectEqualStrings("abbreviation expansion", decoded.value.explanation);
    }
    const old = try std.json.parseFromSlice(Span, a, "{\"text\":\"old\",\"explanation\":\"existing expansion\"}", .{});
    try std.testing.expect(old.value.tooltip == null);
    const image_span: Span = .{ .tooltip = "outer advice", .image = .{ .file = "Flag.svg", .tooltip = "" } };
    const json = try std.json.Stringify.valueAlloc(a, image_span, .{});
    const decoded = try std.json.parseFromSlice(Span, a, json, .{});
    try std.testing.expectEqualStrings("outer advice", decoded.value.tooltip.?);
    try std.testing.expectEqualStrings("", decoded.value.image.?.tooltip.?);
    const bad: Stored = .{ .entry = .{ .title = "bad", .kind = .supplemental, .display_title = &.{.{ .text = "visible", .tooltip = "\xff" }} } };
    try std.testing.expectError(error.InvalidPresentation, validateStored(a, bad, "bad", .supplemental, null));
}

test "block paragraph geometry JSON preserves zero and rejects unsupported owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
    const em = StyleEdges.all(.{ .unit = .em, .value = 1.25 });
    try std.testing.expect(!validBlockStyle(.{}));
    try std.testing.expect(validBlockStyle(.{ .margins = zero }));
    try std.testing.expect(validBlockStyle(.{ .padding = zero }));
    try std.testing.expect(validBlockStyle(.{ .margins = em, .padding = zero }));
    const plain: Block = .{ .kind = .paragraph, .number = "retained", .level = 4 };
    const old_json = try std.json.Stringify.valueAlloc(a, plain, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "\"style\"") == null);
    const zero_block: Block = .{ .kind = .paragraph, .number = "retained", .level = 4, .style = .{ .padding = zero } };
    const zero_json = try std.json.Stringify.valueAlloc(a, zero_block, .{});
    try std.testing.expect(std.mem.indexOf(u8, zero_json, "\"style\":{\"padding\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, zero_json, "\"unit\":\"px\",\"value\":0") != null);
    const parsed = try std.json.parseFromSlice(Block, a, zero_json, .{});
    try std.testing.expectEqualDeep(zero_block, parsed.value);
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |value| {
        const bad = StyleEdges.all(.{ .unit = .em, .value = value });
        try std.testing.expect(!validBlockStyle(.{ .margins = bad }));
        try std.testing.expect(!validBlockStyle(.{ .padding = bad }));
    }
    try std.testing.expect(validBlockStyleContext(.paragraph, 0, false, false, ""));
    try std.testing.expect(!validBlockStyleContext(.paragraph, 1, false, false, ""));
    try std.testing.expect(!validBlockStyleContext(.paragraph, 0, true, false, ""));
    try std.testing.expect(!validBlockStyleContext(.paragraph, 0, false, true, ""));
    try std.testing.expect(!validBlockStyleContext(.paragraph, 0, false, false, "*"));
    inline for (comptime std.meta.tags(BlockKind)) |kind| {
        try std.testing.expectEqual(kind == .paragraph, validBlockStyleContext(kind, 0, false, false, ""));
    }
    const valid: Stored = .{ .entry = .{ .title = "geometry", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{zero_block} }} } };
    try validateStored(a, valid, "geometry", .supplemental, null);
}

test "occurrence maps preserve action fragments nullable JSON and finite coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const negative_zero: f64 = @bitCast(@as(u64, 0x8000000000000000));
    const action: MapAction = .{ .kind = .internal, .target = "", .target_fragment = "", .label = "literal <label> & line\nnext" };
    try std.testing.expect(validMapAction(action));
    try std.testing.expect(validMapAction(.{ .kind = .internal, .target = "Target", .target_fragment = "section", .label = "" }));
    try std.testing.expect(validMapAction(.{ .kind = .external, .target = "https://example.invalid/#part", .label = "external" }));
    try std.testing.expect(!validMapAction(.{ .kind = .internal, .target = "", .label = "" }));
    try std.testing.expect(!validMapAction(.{ .kind = .external, .target = "", .label = "" }));
    try std.testing.expect(!validMapAction(.{ .kind = .external, .target = "https://example.invalid/", .target_fragment = "", .label = "" }));
    try std.testing.expect(!validMapAction(.{ .kind = .internal, .target = "Target", .label = "\xff" }));
    const regions = [_]MapRegion{
        .{ .shape = .rectangle, .coordinates = &.{ 20.5, negative_zero, -4.25, -16 }, .action = action },
        .{ .shape = .circle, .coordinates = &.{ 1.7976931348623157e308, -1.7976931348623157e308, -1e-300 }, .action = .{ .kind = .internal, .target = "Radius", .label = "negative radius retained" } },
        .{ .shape = .polygon, .coordinates = &.{ -8.5, 0, 4.25, 9.5, negative_zero, -2.75 }, .action = .{ .kind = .external, .target = "https://example.invalid/", .label = "polygon" } },
    };
    const map: ImageMap = .{ .regions = &regions, .default_action = action, .description = .top_left };
    try std.testing.expect(validImageMap(map));
    const image: InlineImage = .{ .file = "Shared.svg", .map = map };
    try std.testing.expect(validInlineImage(image));
    const json = try std.json.Stringify.valueAlloc(a, image, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"map\":") != null);
    const decoded = try std.json.parseFromSlice(InlineImage, a, json, .{});
    try std.testing.expectEqualDeep(image, decoded.value);
    try std.testing.expectEqual(@as(u64, @bitCast(negative_zero)), @as(u64, @bitCast(decoded.value.map.?.regions[0].coordinates[1])));
    const ordinary_json = try std.json.Stringify.valueAlloc(a, InlineImage{ .file = "Shared.svg" }, .{});
    try std.testing.expect(std.mem.indexOf(u8, ordinary_json, "\"map\"") == null);
    const empty_json = try std.json.Stringify.valueAlloc(a, InlineImage{ .file = "Shared.svg", .map = .{} }, .{});
    try std.testing.expect(std.mem.indexOf(u8, empty_json, "\"regions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_json, "\"default_action\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_json, "\"description\":\"bottom_right\"") != null);
    const action_json = try std.json.Stringify.valueAlloc(a, MapAction{ .kind = .internal, .target = "Target", .label = "" }, .{});
    try std.testing.expect(std.mem.indexOf(u8, action_json, "\"target_fragment\":null") != null);
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |number| {
        try std.testing.expect(!validMapRegion(.{ .shape = .circle, .coordinates = &.{ 1, 2, number }, .action = action }));
    }
    try std.testing.expect(!validMapRegion(.{ .shape = .rectangle, .coordinates = &.{ 1, 2, 3 }, .action = action }));
    try std.testing.expect(!validMapRegion(.{ .shape = .circle, .coordinates = &.{ 1, 2, 3, 4 }, .action = action }));
    try std.testing.expect(!validMapRegion(.{ .shape = .polygon, .coordinates = &.{ 1, 2, 3, 4, 5, 6, 7 }, .action = action }));
    var strings: MapValidationBudget = .{ .remaining_string_bytes = 3 };
    const repeated: ImageMap = .{ .default_action = .{ .kind = .internal, .target = "T", .label = "L" } };
    try std.testing.expect(strings.map(repeated));
    try std.testing.expect(!strings.map(repeated));
    var items: MapValidationBudget = .{ .remaining_items = 1 };
    try std.testing.expect(items.map(repeated));
    try std.testing.expect(!items.map(repeated));
}

test "figure tagged paint JSON is strict and round trips named variant fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const colors = [_]FigureColor{ .{ .kind = .native_theme }, .{ .kind = .transparent }, .{ .kind = .rgb, .value = "#abcdef" } };
    const jsons = [_][]const u8{ "{\"kind\":\"native_theme\"}", "{\"kind\":\"transparent\"}", "{\"kind\":\"rgb\",\"value\":\"#abcdef\"}" };
    for (colors, jsons) |color, expected| {
        try std.testing.expect(validFigureColor(color));
        const json = try std.json.Stringify.valueAlloc(a, color, .{});
        try std.testing.expectEqualStrings(expected, json);
        const parsed = try std.json.parseFromSlice(FigureColor, a, json, .{});
        try std.testing.expectEqualDeep(color, parsed.value);
    }
    for ([_]FigureColor{ .{ .kind = .rgb }, .{ .kind = .native_theme, .value = "#abcdef" }, .{ .kind = .transparent, .value = "#abcdef" }, .{ .kind = .rgb, .value = "#ABCDEF" }, .{ .kind = .rgb, .value = "#ffffffff" } }) |color| try std.testing.expect(!validFigureColor(color));
    const border: FigureBorder = .{ .kind = .solid, .width = .{ .unit = .px, .value = 1 }, .color = .{ .kind = .transparent } };
    try std.testing.expect(validFigureBorder(border));
    const json = try std.json.Stringify.valueAlloc(a, border, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"solid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"solid\":") == null);
    const parsed = try std.json.parseFromSlice(FigureBorder, a, json, .{});
    try std.testing.expectEqualDeep(border, parsed.value);
    try std.testing.expectEqualStrings("{\"kind\":\"none\"}", try std.json.Stringify.valueAlloc(a, FigureBorder{ .kind = .none }, .{}));
    for ([_]FigureBorder{ .{ .kind = .none, .width = .{ .unit = .px, .value = 0 } }, .{ .kind = .solid }, .{ .kind = .solid, .width = .{ .unit = .px, .value = -1 }, .color = .{ .kind = .native_theme } } }) |bad| try std.testing.expect(!validFigureBorder(bad));
}

test "figure geometry image and caption role validation preserve independent data" {
    const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
    const value: Figure = .{ .image_span = .{ .kind = .link, .target = "File:Figure.svg", .target_fragment = "", .tooltip = "image advice", .background = "#123456", .image = .{ .file = "Figure.svg", .width_px = 400, .border = true } },
        .format = .thumbnail, .sizing = .requested_fit, .placement = .float_right, .clear = .right,
        .margins = zero, .image_insets = zero, .caption_padding = zero, .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
        .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none }, .image_background = .{ .kind = .transparent }, .image_border = .{ .kind = .none },
        .caption_foreground = .{ .kind = .rgb, .value = "#abcdef" }, .caption_background = .{ .kind = .native_theme } };
    try std.testing.expect(validFigure(value));
    // Resolved figure paint is independent data; legacy border/background are
    // retained, not physically added a second time by a figure-aware consumer.
    try std.testing.expect(value.image_span.image.?.border);
    try std.testing.expectEqualStrings("#123456", value.image_span.background.?);
    var bad = value; bad.image_span.image = null; try std.testing.expect(!validFigure(bad));
    bad = value; bad.image_span.text = "not an image-only span"; try std.testing.expect(!validFigure(bad));
    bad = value; bad.image_span.trail = "trail"; try std.testing.expect(!validFigure(bad));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        bad = value; bad.caption_font_scale = number; try std.testing.expect(!validFigureGeometry(bad));
        bad = value; bad.caption_line_height.value = number; try std.testing.expect(!validFigureGeometry(bad));
        bad = value; bad.image_insets.left.value = number; try std.testing.expect(!validFigureGeometry(bad));
    }
    try std.testing.expect(validFigureContext(.paragraph, 0, false, false, false, ""));
    try std.testing.expect(validFigureContext(.list_item, 2, false, false, false, "*#"));
    try std.testing.expect(validFigureContext(.list_item, 0, false, false, false, ""));
    try std.testing.expect(!validFigureContext(.paragraph, 1, false, false, false, ""));
    try std.testing.expect(!validFigureContext(.paragraph, 0, false, false, false, "*"));
    try std.testing.expect(!validFigureContext(.paragraph, 0, true, false, false, ""));
    try std.testing.expect(!validFigureContext(.paragraph, 0, false, true, false, ""));
    try std.testing.expect(!validFigureContext(.paragraph, 0, false, false, true, ""));
    try std.testing.expect(!validFigureContext(.heading, 0, false, false, false, ""));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const block: Block = .{ .kind = .list_item, .depth = 2, .list_path = "*#", .number = "2", .spans = &.{.{ .kind = .link, .text = "caption", .target = "Caption", .foreground = "#112233" }}, .text_align = .center, .figure = value };
    const json = try std.json.Stringify.valueAlloc(a, block, .{});
    const decoded = try std.json.parseFromSlice(Block, a, json, .{});
    try std.testing.expectEqualDeep(block, decoded.value);
    const ordinary = try std.json.Stringify.valueAlloc(a, Block{ .kind = .paragraph }, .{});
    try std.testing.expect(std.mem.indexOf(u8, ordinary, "\"figure\"") == null);
}

test "anonymous flow and rich caption shape preserves explicit empty authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const figure: Figure = .{ .image_span = .{ .image = .{ .file = "Image.svg" } }, .format = .framed, .sizing = .intrinsic, .placement = .none, .clear = .none,
        .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }), .image_insets = StyleEdges.all(.{ .unit = .px, .value = 0 }), .caption_padding = StyleEdges.all(.{ .unit = .px, .value = 0 }),
        .caption_font_scale = 1, .caption_line_height = .{ .unit = .em, .value = 1 }, .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none },
        .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none }, .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    try std.testing.expect(validFlowPart(.{ .kind = .@"inline", .spans = &.{} }));
    try std.testing.expect(validFlowPart(.{ .kind = .figure, .figure = figure }));
    try std.testing.expect(!validFlowPart(.{ .kind = .figure }));
    try std.testing.expect(!validFlowPart(.{ .kind = .@"inline", .figure = figure }));
    try std.testing.expect(!validFlowPart(.{ .kind = .figure, .figure = figure, .spans = &.{.{ .text = "duplicate" }} }));
    try std.testing.expect(validFlowContext(.paragraph, 0, false, false, false, ""));
    try std.testing.expect(validFlowContext(.list_item, 2, false, false, false, "*#"));
    try std.testing.expect(!validFlowContext(.paragraph, 1, false, false, false, ""));
    try std.testing.expect(!validFlowContext(.paragraph, 0, true, false, false, ""));
    try std.testing.expect(!validFlowContext(.paragraph, 0, false, true, false, ""));
    try std.testing.expect(!validFlowContext(.paragraph, 0, false, false, true, ""));
    const absent = try std.json.Stringify.valueAlloc(a, figure, .{});
    try std.testing.expect(std.mem.indexOf(u8, absent, "caption_blocks") == null);
    try std.testing.expect(std.mem.indexOf(u8, absent, "caption_text_align") == null);
    var empty = figure; empty.caption_blocks = &.{}; empty.caption_text_align = .center;
    const present = try std.json.Stringify.valueAlloc(a, empty, .{});
    try std.testing.expect(std.mem.indexOf(u8, present, "\"caption_blocks\":[]") != null);
    const decoded = try std.json.parseFromSlice(Figure, a, present, .{}); try std.testing.expectEqualDeep(empty, decoded.value);
    empty.caption = &.{.{ .text = "duplicate" }}; try std.testing.expect(!validFigure(empty));
    const block: Block = .{ .kind = .paragraph, .flow = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, block, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"flow\":[]") != null);
    const table: Table = .{ .caption_blocks = &.{} };
    const table_json = try std.json.Stringify.valueAlloc(a, table, .{});
    try std.testing.expect(std.mem.indexOf(u8, table_json, "\"caption_blocks\":[]") != null);
}

test "bidi scope header keeps authored and resolved input plus nullable language distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const empty: BidiScope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{} };
    try std.testing.expect(validBidiScopeHeader(empty));
    var changed = empty; changed.resolved_direction = .rtl; try std.testing.expect(validBidiScopeHeader(changed));
    for ([_]?BidiDirectionInput{ null, .auto, .ltr, .rtl }) |authored| for ([_]BidiResolvedDirection{ .ltr, .rtl }) |resolved| {
        changed = empty; changed.authored_direction = authored; changed.resolved_direction = resolved;
        const matching = if (authored) |direction| switch (direction) { .ltr => resolved == .ltr, .rtl => resolved == .rtl, .auto => true } else true;
        try std.testing.expectEqual(matching, validBidiScopeHeader(changed));
        changed.mode = .isolate_override;
        const override_valid = if (authored) |direction| switch (direction) { .ltr => resolved == .ltr, .rtl => resolved == .rtl, .auto => false } else false;
        try std.testing.expectEqual(override_valid, validBidiScopeHeader(changed));
    };
    changed = empty; changed.language = "\xff"; try std.testing.expect(!validBidiScopeHeader(changed));
    for ([_]?[]const u8{ null, "", "he" }) |language| {
        changed = empty; changed.language = language;
        try std.testing.expect(validBidiScopeHeader(changed));
        const json = try std.json.Stringify.valueAlloc(a, changed, .{});
        try std.testing.expect(std.mem.indexOf(u8, json, "\"authored_direction\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, if (language == null) "\"language\":null" else if (language.?.len == 0) "\"language\":\"\"" else "\"language\":\"he\"") != null);
        const parsed = try std.json.parseFromSlice(BidiScope, a, json, .{}); try std.testing.expectEqualDeep(changed, parsed.value);
    }
    try std.testing.expect(validFlowPart(.{ .kind = .scope, .scope = empty }));
    try std.testing.expect(!validFlowPart(.{ .kind = .scope }));
    try std.testing.expect(!validFlowPart(.{ .kind = .scope, .scope = empty, .spans = &.{.{ .text = "wrong owner" }} }));
    try std.testing.expect(!validFlowPart(.{ .kind = .@"inline", .scope = empty }));
    try std.testing.expect(!validFlowPart(.{ .kind = .figure, .scope = empty }));
}

test "required figure sizing policy has strict source-independent format and bound contexts" {
    for ([_]FigureFormat{ .thumbnail, .framed }) |figure_format| for ([_]FigureSizingPolicy{ .intrinsic, .original_width_with_height_bound, .requested_fit, .requested_fit_cap_original_width }) |policy| {
        for ([_]?u32{ null, 0, 1, 400, std.math.maxInt(u32) }) |width| for ([_]?u32{ null, 0, 1, 100, std.math.maxInt(u32) }) |height| {
            const positive = (width == null or width.? != 0) and (height == null or height.? != 0);
            const context = switch (policy) { .intrinsic => figure_format == .framed, .original_width_with_height_bound => figure_format == .framed and height != null,
                .requested_fit, .requested_fit_cap_original_width => figure_format == .thumbnail and width != null };
            try std.testing.expectEqual(positive and context, validFigureSizingContext(figure_format, policy, width, height));
        };
    };
    try std.testing.expect(@hasField(Figure, "sizing"));
    // Figure.sizing is declared without a default: callers must supply it.
    // This is the typed API requirement, not an invented JSON decode service.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
    var figure: Figure = .{ .image_span = .{ .image = .{ .file = "Image.svg", .width_px = 400, .height_px = 100 } }, .format = .framed, .sizing = .intrinsic, .placement = .none, .clear = .none,
        .margins = zero, .image_insets = zero, .caption_padding = zero, .caption_font_scale = 1, .caption_line_height = .{ .unit = .em, .value = 1 },
        .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none }, .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
        .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    try std.testing.expect(validFigure(figure));
    const json = try std.json.Stringify.valueAlloc(a, figure, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sizing\":\"intrinsic\"") != null);
    try std.testing.expectEqual(@as(?u32, 400), figure.image_span.image.?.width_px);
    try std.testing.expectEqual(@as(?u32, 100), figure.image_span.image.?.height_px);
    figure.sizing = .original_width_with_height_bound; try std.testing.expect(validFigure(figure));
    figure.image_span.image.?.height_px = null; try std.testing.expect(!validFigure(figure));
    figure.sizing = .intrinsic; try std.testing.expect(validFigure(figure));
    figure.format = .thumbnail; try std.testing.expect(!validFigure(figure));
    figure.sizing = .requested_fit; try std.testing.expect(validFigure(figure));
    figure.image_span.image.?.width_px = null; try std.testing.expect(!validFigure(figure));
}

test "shared StyleWidth and table box fields preserve zero resets and numeric JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    try std.testing.expect(!validTableStyle(.{}));
    for ([_]StyleWidthUnit{ .px, .em, .percent }) |unit| for ([_]f32{ 0, 0.16, 16, 100, 150 }) |number| {
        const width: StyleWidth = .{ .unit = unit, .value = number }; try std.testing.expect(validStyleWidth(width));
        try std.testing.expect(validTableStyle(.{ .width = width }));
        const json = try std.json.Stringify.valueAlloc(a, width, .{}); const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        const value = switch (parsed.value.object.get("value").?) { .float => |v| v, .integer => |v| @as(f64, @floatFromInt(v)), else => return error.UnexpectedJsonNumber };
        try std.testing.expectEqual(@as(f64, number), value);
    };
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        try std.testing.expect(!validStyleWidth(.{ .unit = .percent, .value = number }));
        try std.testing.expect(!validTableStyle(.{ .width = .{ .unit = .em, .value = number } }));
        try std.testing.expect(!validTableStyle(.{ .padding = StyleEdges.all(.{ .unit = .px, .value = number }) }));
    }
    try std.testing.expect(validTableStyle(.{ .padding = StyleEdges.all(.{ .unit = .em, .value = 0 }) }));
    for ([_]FigureClear{ .none, .left, .right, .both }) |clear| try std.testing.expect(validTableStyle(.{ .clear = clear }));
    const json = try std.json.Stringify.valueAlloc(a, TableStyle{ .clear = .none, .width = .{ .unit = .em, .value = 0 } }, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"clear\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "padding") == null);
}
