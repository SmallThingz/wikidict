const std = @import("std");
const format = @import("blob_format.zig");
const types = @import("presentation_types.zig");
const A = std.mem.Allocator;

pub const magic = "DPR2";
pub const explained_magic = "DPR3";
pub const color_magic = "DPR4";
pub const anchor_magic = "DPR5";
pub const background_magic = "DPR6";
pub const nested_magic = "DPR7";
pub const cell_blocks_magic = "DPR8";
pub const reference_items_magic = "DPR9";
pub const font_scale_magic = "DPRA";
pub const font_scale_basis_magic = "DPRB";
pub const reference_blocks_magic = "DPRC";
pub const image_border_magic = "DPRD";
pub const block_layout_magic = "DPRE";
pub const explicit_targets_magic = "DPRF";
pub const dynamic_catalog_magic = "DPRG";
pub const tooltips_magic = "DPRH";
pub const block_geometry_magic = "DPRI";
pub const image_maps_magic = "DPRJ";
pub const inline_table_styles_magic = "DPRK";
pub const block_containers_magic = "DPRL";
pub const container_fonts_magic = "DPRM";
/// Explicit reader capability: M base layout plus nullable authored Rule style.
pub const rule_styles_magic = "DPRN";
pub const inline_styles_magic = "DPRO";
pub const body_adjoining_magic = "DPRP";
pub const table_corners_magic = "DPRQ";
pub const intrinsic_table_magic = "DPRR";
const container_owner_font_flag: u32 = 0x10000;
const container_height_flag: u32 = 0x20000;
const container_columns_flag: u32 = 0x40000;
const container_positioning_flag: u32 = 0x80000;
const container_min_height_flag: u32 = 0x100000;
const cell_line_height_flag: u8 = 0x08;
const cell_width_flag: u8 = 0x20;
const container_margin_values_flag: u32 = 0x200000;
const cell_min_width_flag: u8 = 0x40;
const cell_vertical_align_flag: u8 = 0x80;
const container_font_family_flag: u32 = 0x400000;
const container_style_known_flags: u32 = 0x7fffff;
const Version = enum { plain, explained, colored, anchored, span_background, nested_tables, cell_blocks, reference_items, font_scale, font_scale_basis, reference_blocks, image_border, block_layout, explicit_targets, dynamic_catalog, tooltips, block_geometry, image_maps, inline_table_styles, block_containers, container_fonts };
fn hasLFields(version: Version) bool { return version == .block_containers or version == .container_fonts; }
fn hasKFields(version: Version) bool { return version == .inline_table_styles or hasLFields(version); }
fn hasRgb(version: Version) bool {
    return version == .colored or version == .anchored or version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasAnchorFields(version: Version) bool {
    return version == .anchored or version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasSpanBackgroundFields(version: Version) bool {
    return version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasNestedFields(version: Version) bool {
    return version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasCellBlockFields(version: Version) bool {
    return version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasReferenceFields(version: Version) bool {
    return version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasFontScaleFields(version: Version) bool {
    return version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasFontScaleBasisFields(version: Version) bool {
    return version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
fn hasReferenceBlockFields(version: Version) bool {
    return version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or (version == .image_maps or hasKFields(version)))))));
}
const max_items: usize = types.max_presentation_items;
const max_string_bytes: usize = 32 * 1024 * 1024;
const no_index: u32 = std.math.maxInt(u32);

const Encoder = struct {
    a: A,
    version: Version = .plain,
    rule_styles: bool = false,
    inline_styles: bool = false,
    capability_p: bool = false,
    capability_q: bool = false,
    capability_r: bool = false,
    out: std.ArrayList(u8) = .empty,
    table_depth: usize = 0,
    content_depth: usize = 0,
    in_reference: bool = false,
    inline_media_catalog: ?*const types.ImageCatalogIndex = null,
    link_paint: ?types.FigureLinkPaint = null,
    remaining_items: usize = max_items,
    remaining_map_string_bytes: usize = types.max_image_map_string_bytes,

    fn deinit(self: *Encoder) void {
        self.out.deinit(self.a);
    }
    fn byte(self: *Encoder, value: u8) !void {
        try self.out.append(self.a, value);
    }
    fn writeU16(self: *Encoder, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.out.appendSlice(self.a, &buf);
    }
    fn writeU32(self: *Encoder, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.out.appendSlice(self.a, &buf);
    }
    fn writeU64(self: *Encoder, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.out.appendSlice(self.a, &buf);
    }
    fn count(self: *Encoder, value: usize) !void {
        if (value > max_items) return error.PresentationTooLarge;
        if (hasNestedFields(self.version)) {
            if (value > self.remaining_items) return error.PresentationTooLarge;
            self.remaining_items -= value;
        }
        try self.writeU32(@intCast(value));
    }
    fn index(self: *Encoder, value: usize) !void {
        const n = std.math.cast(u32, value) orelse return error.PresentationTooLarge;
        if (n == no_index) return error.PresentationTooLarge;
        try self.writeU32(n);
    }
    fn optionalIndex(self: *Encoder, value: ?usize) !void {
        if (value) |n| return self.index(n);
        try self.writeU32(no_index);
    }
    fn string(self: *Encoder, value: []const u8) !void {
        if (value.len > max_string_bytes) return error.PresentationTooLarge;
        try self.writeU32(std.math.cast(u32, value.len) orelse return error.PresentationTooLarge);
        try self.out.appendSlice(self.a, value);
    }
    fn indices(self: *Encoder, values: []const usize) !void {
        try self.count(values.len);
        for (values) |value| try self.index(value);
    }
    inline fn enumByteValue(comptime E: type, value: anytype) !u8 {
        const Source = @TypeOf(value);
        const fields = @typeInfo(Source).@"enum";
        const invalid = std.math.maxInt(u8);
        const map = comptime blk: {
            var result: [fields.field_names.len]u8 = undefined;
            for (fields.field_names, fields.field_values, 0..) |name, source_value, i| {
                if (source_value != i) @compileError("enumByte source must use dense zero-based values");
                result[i] = if (@hasField(E, name)) @intCast(@backingInt(@field(E, name))) else invalid;
            }
            break :blk result;
        };
        const mapped = map[@backingInt(value)];
        if (mapped == invalid) return error.UncompiledTemplate;
        return mapped;
    }
    fn enumByte(self: *Encoder, comptime E: type, value: anytype) !void {
        try self.byte(try enumByteValue(E, value));
    }
    fn inlineComputedLength(self: *Encoder, value: types.ComputedLineHeight) !void {
        try self.writeU32(@bitCast(value.value));
        try self.enumByte(types.FontScaleBasis, value.font_scale_basis);
    }
    fn inlineFontSnapshot(self: *Encoder, value: types.InlineFontSnapshot) !void {
        if (!types.validInlineFontSnapshot(value) or (value.font_family != null and !self.capability_p)) return error.InvalidPresentation;
        const scale = spanScale(value);
        const flags: u8 = @as(u8, @intFromBool(scale != null)) |
            (@as(u8, @intFromBool(value.small)) << 1) | (@as(u8, @intFromBool(value.superscript)) << 2) |
            (@as(u8, @intFromBool(value.subscript)) << 3) | (@as(u8, @intFromBool(value.font_normalized)) << 4);
        try self.byte(flags);
        if (scale) |known| {
            try self.writeU32(@bitCast(known));
            try self.enumByte(types.FontScaleBasis, value.font_scale_basis);
        }
        try self.byte(@as(u8, @intFromBool(value.bold)) | (@as(u8, @intFromBool(value.italic)) << 1) |
            (@as(u8, @intFromBool(value.code)) << 2) | (@as(u8, @intFromBool(value.font_features != null)) << 3) |
            (@as(u8, @intFromBool(value.font_family != null)) << 4));
        try self.string(value.language); try self.string(value.classes);
        try self.enumByte(types.Role, value.role);
        if (value.font_features) |features| try self.enumByte(types.FontFeaturePolicy, features);
        if (value.font_family) |family| try self.containerFontFamily(family);
    }
    fn inlineTextStyle(self: *Encoder, value: types.InlineTextStyle) !void {
        if (!self.inline_styles or self.version != .container_fonts or !types.validInlineTextStyle(value)) return error.InvalidPresentation;
        const flags: u8 = @as(u8, @intFromBool(value.decoration != null)) |
            (@as(u8, @intFromBool(value.line_height != null)) << 1) |
            (@as(u8, @intFromBool(value.baseline_shift != null)) << 2) |
            (@as(u8, @intFromBool(value.font_normalized)) << 3) |
            (@as(u8, @intFromBool(value.cursor != null)) << 4);
        try self.byte(flags);
        if (value.decoration) |line| {
            try self.enumByte(types.InlineUnderlineStyle, line.style);
            try self.byte(@intFromBool(line.color != null));
            if (line.color) |color| try self.string(color);
            try self.byte(@intFromBool(line.thickness != null));
            if (line.thickness) |length| try self.styleLength(length);
        }
        if (value.line_height) |height| switch (height) {
            .computed => |length| { try self.byte(0); try self.inlineComputedLength(length); },
            .font_relative => |relative| {
                try self.byte(1); try self.writeU32(@bitCast(relative.factor));
                try self.inlineFontSnapshot(relative.font);
            },
        };
        if (value.baseline_shift) |shift| try self.inlineComputedLength(shift);
        if (value.cursor) |cursor| try self.enumByte(types.InlineCursor, cursor);
    }

    fn span(self: *Encoder, value: anytype) !void {
        if (!types.validSpanInlineStyle(value) or !types.validSpanLinkPaint(value)) return error.InvalidPresentation;
        if (self.link_paint) |paint| if (!types.validFigureLinkPaintSpan(paint, value)) return error.InvalidPresentation;
        if (comptime @hasField(@TypeOf(value), "pending_container"))
            if (value.pending_container != null) return error.InvalidPresentation;
        const kind = try enumByteValue(types.InlineKind, value.kind);
        const trail: []const u8 = if (comptime @hasField(@TypeOf(value), "trail")) value.trail else "";
        if (spanImage(value)) |image| {
            if (!hasReferenceBlockFields(self.version) or value.text.len != 0 or trail.len != 0 or !types.validInlineImage(image) or
                !types.validInlineImageAction(@enumFromInt(kind), value.target)) return error.InvalidPresentation;
        }
        const role = try enumByteValue(types.Role, value.role);
        const flags: u8 = if (comptime @hasField(@TypeOf(value), "flags"))
            @bitCast(value.flags)
        else blk: {
            var result: u8 = 0;
            if (value.bold) result |= 1 << 0;
            if (value.italic) result |= 1 << 1;
            if (value.code) result |= 1 << 2;
            if (value.small) result |= 1 << 3;
            if (value.superscript) result |= 1 << 4;
            if (value.subscript) result |= 1 << 5;
            if (value.strike) result |= 1 << 6;
            if (value.underline) result |= 1 << 7;
            break :blk result;
        };
        const explanation: []const u8 = if (comptime @hasField(@TypeOf(value), "explanation")) value.explanation else "";
        const fields = [_][]const u8{ value.text, value.target, trail, value.language, value.classes, value.direction, explanation };
        const strings = fields[0..if (self.version != .plain) @as(usize, 7) else 6];
        var encoded_len: usize = 3 + strings.len * @sizeOf(u32);
        for (strings) |string_value| {
            if (string_value.len > max_string_bytes) return error.PresentationTooLarge;
            encoded_len += string_value.len;
        }
        try self.out.ensureUnusedCapacity(self.a, encoded_len);
        const encoded = self.out.addManyAsSliceAssumeCapacity(encoded_len);
        encoded[0] = kind;
        encoded[1] = role;
        encoded[2] = flags;
        var pos: usize = 3;
        for (strings) |string_value| {
            std.mem.writeInt(u32, encoded[pos..][0..4], @intCast(string_value.len), .little);
            pos += 4;
            @memcpy(encoded[pos..][0..string_value.len], string_value);
            pos += string_value.len;
        }
        std.debug.assert(pos == encoded.len);
        if (hasRgb(self.version)) {
            const foreground: ?[]const u8 = if (comptime @hasField(@TypeOf(value), "foreground")) value.foreground else null;
            try self.byte(@intFromBool(foreground != null));
            if (foreground) |color| {
                if (!types.isCanonicalRgb(color)) return error.InvalidPresentation;
                try self.string(color);
            }
        }
        if (hasSpanBackgroundFields(self.version)) {
            const background: ?[]const u8 = if (comptime @hasField(@TypeOf(value), "background")) value.background else null;
            try self.byte(@intFromBool(background != null));
            if (background) |color| {
                if (!types.isCanonicalRgb(color)) return error.InvalidPresentation;
                try self.string(color);
            }
        }
        const scale = spanScale(value);
        const basis = spanScaleBasis(value);
        const features = spanFontFeatures(value);
        const link_paint = spanLinkPaint(value);
        const inline_style = spanInlineStyle(value);
        const family = spanFontFamily(value);
        if (family != null and (!self.capability_p or self.version != .container_fonts)) return error.InvalidPresentation;
        if (inline_style != null and (!self.inline_styles or self.version != .container_fonts)) return error.InvalidPresentation;
        if ((features != null or link_paint != null) and self.version != .container_fonts) return error.InvalidPresentation;
        if (!types.validSpanFontScale(scale, basis) or (basis != .context and !hasFontScaleBasisFields(self.version))) return error.InvalidPresentation;
        if (basis == .css_px and self.version != .container_fonts) return error.InvalidPresentation;
        if (hasFontScaleFields(self.version)) {
            const font_fields: u8 = @as(u8, @intFromBool(scale != null)) |
                (if (features != null) @as(u8, 2) else 0) | (if (link_paint != null) @as(u8, 4) else 0) |
                (if (inline_style != null) @as(u8, 8) else 0) | (if (family != null) @as(u8, 16) else 0);
            try self.byte(font_fields);
            if (scale) |n| {
                try self.writeU32(@bitCast(n));
                if (hasFontScaleBasisFields(self.version)) try self.byte(@intFromEnum(basis));
            }
            if (features) |policy| try self.enumByte(types.FontFeaturePolicy, policy);
            if (link_paint) |paint| try self.linkPaint(paint);
            if (inline_style) |style| try self.inlineTextStyle(style);
            if (family) |policy| try self.containerFontFamily(policy);
        }
        if (hasReferenceBlockFields(self.version)) try self.inlineImage(spanImage(value));
        const fragment = spanTargetFragment(value);
        if (fragment) |text| if (!types.validTargetFragment(text)) return error.InvalidPresentation;
        if (fragment != null and (kind != @intFromEnum(types.InlineKind.link) or (self.version != .explicit_targets and (self.version != .dynamic_catalog and (self.version != .tooltips and (self.version != .block_geometry and (self.version != .image_maps and !hasKFields(self.version)))))))) return error.InvalidPresentation;
        if ((self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version))))))) {
            try self.byte(@intFromBool(fragment != null));
            if (fragment) |text| try self.string(text);
        }
        const tooltip = spanTooltip(value);
        if (tooltip != null and (self.version != .tooltips and (self.version != .block_geometry and (self.version != .image_maps and !hasKFields(self.version))))) return error.InvalidPresentation;
        if ((self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version))))) {
            try self.byte(@intFromBool(tooltip != null));
            if (tooltip) |advice| {
                if (!std.unicode.utf8ValidateSlice(advice)) return error.InvalidPresentation;
                try self.string(advice);
            }
        }
    }
    fn mapString(self: *Encoder, value: []const u8) !void {
        if (value.len > max_string_bytes or value.len > self.remaining_map_string_bytes) return error.PresentationTooLarge;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidPresentation;
        self.remaining_map_string_bytes -= value.len;
        try self.string(value);
    }
    fn mapAction(self: *Encoder, value: types.MapAction) !void {
        if (!types.validMapAction(value)) return error.InvalidPresentation;
        try self.enumByte(types.MapActionKind, value.kind);
        try self.mapString(value.target);
        try self.byte(@intFromBool(value.target_fragment != null));
        if (value.target_fragment) |fragment| try self.mapString(fragment);
        try self.mapString(value.label);
    }
    fn chargeMapDefault(self: *Encoder) !void {
        if (self.remaining_items == 0) return error.PresentationTooLarge;
        self.remaining_items -= 1;
    }
    fn imageMap(self: *Encoder, value: types.ImageMap) !void {
        if (!types.validImageMap(value)) return error.InvalidPresentation;
        try self.enumByte(types.MapDescription, value.description);
        try self.count(value.regions.len);
        for (value.regions) |region| {
            try self.enumByte(types.MapShape, region.shape);
            try self.count(region.coordinates.len);
            for (region.coordinates) |coordinate| try self.writeU64(@bitCast(coordinate));
            try self.mapAction(region.action);
        }
        try self.byte(@intFromBool(value.default_action != null));
        if (value.default_action) |fallback| {
            try self.chargeMapDefault();
            try self.mapAction(fallback);
        }
    }
    fn inlineImage(self: *Encoder, optional: ?types.InlineImage) !void {
        const value = optional orelse {
            try self.byte(0);
            return;
        };
        if (value.static_poster != null and self.version != .container_fonts) return error.InvalidPresentation;
        if (value.vertical_align != null and (self.version != .container_fonts or !self.capability_q)) return error.InvalidPresentation;
        if (value.svg_language != null and !hasKFields(self.version)) return error.InvalidPresentation;
        if (value.dark_mode_filter != null and !hasKFields(self.version)) return error.InvalidPresentation;
        if (value.map != null and (self.version != .image_maps and !hasKFields(self.version))) return error.InvalidPresentation;
        if (!types.validInlineImage(value) or (value.border and self.version != .image_border and self.version != .block_layout and (self.version != .explicit_targets and (self.version != .dynamic_catalog and (self.version != .tooltips and (self.version != .block_geometry and (self.version != .image_maps and !hasKFields(self.version)))))))) return error.InvalidPresentation;
        try self.byte(if (value.vertical_align != null) 3 else if (value.static_poster != null) 2 else 1);
        try self.string(value.file);
        const flags: u8 = @as(u8, @intFromBool(value.width_px != null)) |
            (@as(u8, @intFromBool(value.height_px != null)) << 1) |
            (@as(u8, @intFromBool(value.alt != null)) << 2) |
            (@as(u8, @intFromBool(value.tooltip != null)) << 3) |
            (@as(u8, @intFromBool(value.border)) << 4) |
            (@as(u8, @intFromBool(value.map != null)) << 5) |
            (@as(u8, @intFromBool(value.dark_mode_filter != null)) << 6) |
            (@as(u8, @intFromBool(value.svg_language != null)) << 7);
        try self.byte(flags);
        if (value.width_px) |width| try self.writeU32(width);
        if (value.height_px) |height| try self.writeU32(height);
        if (value.alt) |alt| try self.string(alt);
        if (value.tooltip) |tooltip| try self.string(tooltip);
        if (value.map) |map| try self.imageMap(map);
        if (value.dark_mode_filter) |filter| try self.enumByte(types.ImageDarkModeFilter, filter);
        if (value.svg_language) |language| try self.string(language);
        if (value.static_poster) |poster| {
            try self.enumByte(types.StaticPosterPolicy, poster.policy);
            try self.string(poster.label);
            try self.string(poster.file_sha1);
            try self.string(poster.file_timestamp);
        }
        if (value.vertical_align) |alignment| try self.enumByte(types.InlineImageVerticalAlign, alignment);
    }
    fn spans(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |value| try self.span(value);
    }
    fn feature(self: *Encoder, value: anytype) !void {
        if (value) |feature_value| {
            try self.byte(1);
            try self.string(feature_value.kind);
            try self.string(feature_value.language);
            try self.string(feature_value.data);
            try self.string(feature_value.tail_kind);
            try self.string(feature_value.tail);
        } else try self.byte(0);
    }
    fn styleLength(self: *Encoder, value: types.StyleLength) !void {
        if (!types.validStyleLength(value)) return error.InvalidPresentation;
        try self.enumByte(types.StyleLengthUnit, value.unit);
        try self.writeU32(@bitCast(value.value));
    }
    fn styleEdges(self: *Encoder, value: types.StyleEdges) !void {
        try self.styleLength(value.top);
        try self.styleLength(value.right);
        try self.styleLength(value.bottom);
        try self.styleLength(value.left);
    }
    fn styleBorderEdge(self: *Encoder, value: types.StyleBorderEdge) !void {
        if (self.version != .container_fonts or !types.validBorderEdge(value)) return error.InvalidPresentation;
        switch (value) {
            .none => try self.byte(0),
            .hidden => try self.byte(1),
            .solid, .dotted => |line| {
                try self.byte(if (value == .solid) 2 else 3);
                try self.styleLength(line.width); try self.string(line.color);
            },
        }
    }
    fn styleBorder(self: *Encoder, value: types.StyleBorder) !void {
        if (!types.validBorder(value)) return error.InvalidPresentation;
        switch (value) {
            .none => try self.byte(0),
            .solid => |solid| {
                try self.byte(1);
                try self.styleLength(solid.width);
                try self.string(solid.color);
            },
            .edges => |edges| {
                if (self.version != .container_fonts) return error.InvalidPresentation;
                try self.byte(2);
                inline for (.{ "top", "right", "bottom", "left" }) |side| try self.styleBorderEdge(@field(edges, side));
            },
        }
    }
    fn figureColor(self: *Encoder, value: types.FigureColor) !void {
        if (!types.validFigureColor(value)) return error.InvalidPresentation;
        try self.enumByte(types.FigureColorKind, value.kind);
        if (value.kind == .rgb) try self.string(value.value.?);
    }
    fn figureBorder(self: *Encoder, value: types.FigureBorder) !void {
        if (!types.validFigureBorder(value)) return error.InvalidPresentation;
        try self.enumByte(types.FigureBorderKind, value.kind);
        if (value.kind == .solid) { try self.styleLength(value.width.?); try self.figureColor(value.color.?); }
    }
    fn figureBorderEdge(self: *Encoder, value: types.FigureBorderEdge) !void {
        if (!types.validFigureBorderEdge(value)) return error.InvalidPresentation;
        switch (value) {
            .none => try self.byte(0), .hidden => try self.byte(1),
            .solid, .dotted => |line| {
                try self.byte(if (value == .solid) 2 else 3);
                try self.styleLength(line.width); try self.figureColor(line.color);
            },
        }
    }
    fn figureCaptionBefore(self: *Encoder, value: ?types.ContainerStyle) !void {
        try self.byte(@intFromBool(value != null));
        if (value) |style| {
            if (!types.validFigureCaptionBefore(style)) return error.InvalidPresentation;
            try self.containerStyle(style);
        }
    }
    fn figureFocusOutline(self: *Encoder, optional: ?types.FigureFocusOutline) !void {
        try self.byte(@intFromBool(optional != null));
        if (optional) |outline| {
            if (!types.validFigureFocusOutline(outline)) return error.InvalidPresentation;
            try self.styleLength(outline.width); try self.figureColor(outline.color);
            try self.styleLength(outline.radius); try self.containerMarginLength(outline.offset);
        }
    }
    fn figureLinkPaint(self: *Encoder, optional: ?types.FigureLinkPaint) !void {
        try self.byte(@intFromBool(optional != null));
        const paint = optional orelse return;
        if (self.version != .container_fonts or !types.validFigureLinkPaint(paint)) return error.InvalidPresentation;
        var flags: u8 = @as(u8, @intFromBool(paint.underline_on_focus)) << 6;
        inline for (.{ "normal", "hover", "active", "visited", "visited_hover", "visited_active" }, 0..) |name, state_index| {
            const state = @field(paint, name);
            try self.string(state.foreground);
            flags |= @as(u8, @intFromBool(state.underline)) << state_index;
        }
        try self.byte(flags); try self.figureFocusOutline(paint.focus_outline);
    }
    fn linkPaint(self: *Encoder, paint: types.LinkPaint) !void {
        if (!types.validLinkPaint(paint)) return error.InvalidPresentation;
        try self.figureLinkPaint(paint.sixStatePrefix());
        try self.string(paint.hover_active.foreground); try self.string(paint.visited_hover_active.foreground);
        try self.byte(@as(u8, @intFromBool(paint.hover_active.underline)) | (@as(u8, @intFromBool(paint.visited_hover_active.underline)) << 1));
    }
    fn figureMediaLayout(self: *Encoder, value: types.FigureMediaLayout) !void {
        if (self.version != .container_fonts or !types.validFigureMediaLayout(value)) return error.InvalidPresentation;
        try self.writeU32(@bitCast(value.strut.font_scale));
        try self.byte(@as(u8, @intFromBool(value.strut.bold)) |
            (@as(u8, @intFromBool(value.strut.italic)) << 1) | (@as(u8, @intFromBool(value.strut.code)) << 2) |
            (if (value.strut.font_features != null) @as(u8, 0x08) else 0));
        try self.string(value.strut.language); try self.enumByte(types.BidiResolvedDirection, value.strut.direction);
        if (value.strut.font_features) |policy| try self.enumByte(types.FontFeaturePolicy, policy);
        try self.enumByte(types.InlineBoxVerticalAlign, value.vertical_align);
        try self.byte(@intFromBool(value.max_width != null));
        if (value.max_width) |limit| {
            try self.writeU32(@bitCast(limit.percent)); try self.styleLength(limit.subtract);
        }
        try self.byte(@intFromBool(value.positioning != null));
        if (value.positioning) |position| try self.enumByte(types.ContainerPositioning, position);
        try self.byte(@intFromBool(value.after != null));
        if (value.after) |after| {
            try self.styleLength(after.width); try self.styleLength(after.height);
            try self.enumByte(types.TableFloatSide, after.side); try self.styleLength(after.inset);
            try self.containerMarginLength(after.bottom);
            try self.byte(@intFromBool(after.paint != null));
            if (after.paint) |paint| {
                try self.enumByte(types.FigureMediaGraphic, paint.graphic); try self.byte(@intFromBool(paint.invert));
            }
        }
        try self.figureFocusOutline(value.focus_outline);
    }
    fn tableCaptionLayout(self: *Encoder, value: types.TableCaptionLayout) !void {
        if (self.version != .container_fonts or !types.validTableCaptionLayout(value)) return error.InvalidPresentation;
        try self.enumByte(types.BorderCollapse, value.collapse);
        try self.containerStyle(value.wrapper);
        inline for (.{ "table_border", "caption_border" }) |box|
            inline for (.{ "top", "right", "bottom", "left" }) |side|
                try self.figureBorderEdge(@field(@field(value, box), side));
        try self.figureMediaLayout(value.media);
        try self.figureCaptionBefore(value.caption_before);
        try self.count(value.viewport_states.len);
        for (value.viewport_states) |state| {
            try self.writeU32(state.max_width_px); try self.containerStyle(state.wrapper);
            try self.figureMediaLayout(state.media); try self.figureCaptionBefore(state.caption_before);
        }
        try self.figureLinkPaint(value.missing_link_paint); try self.figureLinkPaint(value.caption_link_paint);
    }
    fn figureBlockMediaLayout(self: *Encoder, value: types.FigureBlockMediaLayout) !void {
        if (self.version != .container_fonts or !types.validFigureBlockMediaLayout(value)) return error.InvalidPresentation;
        try self.containerStyle(value.wrapper); try self.figureMediaLayout(value.media);
        try self.writeU32(value.preferred_width_px); try self.writeU32(value.natural_width); try self.writeU32(value.natural_height);
        try self.string(value.rendition_1x.url); try self.string(value.rendition_1x.sha256);
        try self.string(value.rendition_2x.url); try self.string(value.rendition_2x.sha256);
        try self.count(value.viewport_states.len);
        for (value.viewport_states) |state| {
            try self.writeU32(state.max_width_px); try self.containerStyle(state.wrapper); try self.figureMediaLayout(state.media);
        }
    }
    fn chargeFigureContent(self: *Encoder) !void {
        if (self.remaining_items == 0) return error.PresentationTooLarge;
        self.remaining_items -= 1;
    }
    fn figure(self: *Encoder, optional: anytype) error{OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate}!void {
        const value = optional orelse { try self.byte(0); return; };
        if (self.version != .image_maps and !hasKFields(self.version)) return error.InvalidPresentation;
        if (value.frame_min_width) |minimum| if (!types.validFigureFrameMinWidth(minimum)) return error.InvalidPresentation;
        if (!types.validFigureGeometry(value)) return error.InvalidPresentation;
        const caption_layout: ?types.TableCaptionLayout = if (comptime @hasField(@TypeOf(value), "table_caption_layout")) value.table_caption_layout else null;
        const block_layout: ?types.FigureBlockMediaLayout = if (comptime @hasField(@TypeOf(value), "block_media_layout")) value.block_media_layout else null;
        if ((caption_layout != null or block_layout != null) and self.version != .container_fonts) return error.InvalidPresentation;
        const missing = value.content == .missing;
        const previous_paint = self.link_paint;
        defer self.link_paint = previous_paint;
        self.link_paint = if (caption_layout) |present_layout| present_layout.missing_link_paint else null;
        switch (value.content) {
            .image => |content| {
                const image = spanImage(content.span) orelse return error.InvalidPresentation;
                if (caption_layout != null and image.static_poster != null) return error.InvalidPresentation;
                if (!types.validFigureSizingContext(value.format, content.sizing, image.width_px, image.height_px)) return error.InvalidPresentation;
                const trail: []const u8 = if (comptime @hasField(@TypeOf(content.span), "trail")) content.span.trail else "";
                if (content.span.text.len != 0 or trail.len != 0) return error.InvalidPresentation;
            },
            .missing => |content| {
                if (!hasKFields(self.version) or !types.validMissingFigureContent(content)) return error.InvalidPresentation;
            },
        }
        try self.byte(if (block_layout != null) @as(u8, 7) else if (caption_layout != null) (if (missing) @as(u8, 6) else 5) else (if (missing) @as(u8, 2) else 1));
        try self.enumByte(types.FigureFormat, value.format);
        try self.enumByte(types.FigurePlacement, value.placement);
        try self.enumByte(types.FigureClear, value.clear);
        try self.styleEdges(value.margins); try self.styleEdges(value.image_insets); try self.styleEdges(value.caption_padding);
        try self.writeU32(@bitCast(value.caption_font_scale)); try self.styleLength(value.caption_line_height);
        try self.figureColor(value.frame_background); try self.figureBorder(value.frame_border);
        try self.figureColor(value.image_background); try self.figureBorder(value.image_border);
        try self.figureColor(value.caption_foreground); try self.figureColor(value.caption_background);
        try self.chargeFigureContent();
        // Preserve the actual compiler Span, including packed flags/provenance.
        try self.span(value.content.span());
        if (missing) {
            try self.styleLength(value.content.missing.width);
            try self.styleLength(value.content.missing.line_height);
            try self.byte(@intFromBool(value.content.missing.link_paint != null));
            if (value.content.missing.link_paint) |paint| try self.enumByte(types.MissingLinkPaint, paint);
        }
        const caption = if (comptime @hasField(@TypeOf(value), "caption")) value.caption else @as([]const types.Span, &.{});
        if (comptime @hasField(@TypeOf(value), "caption_blocks")) {
            if (value.caption_blocks != null and caption.len != 0) return error.InvalidPresentation;
        }
        self.link_paint = if (caption_layout) |present_layout| present_layout.caption_link_paint else null;
        try self.spans(caption);
        if (comptime @hasField(@TypeOf(value), "caption_blocks")) try self.captionBlocks(value.caption_blocks) else try self.byte(0);
        const alignment: ?types.CellTextAlign = if (comptime @hasField(@TypeOf(value), "caption_text_align")) value.caption_text_align else null;
        try self.byte(@intFromBool(alignment != null)); if (alignment) |present| try self.enumByte(types.CellTextAlign, present);
        if (!missing) try self.enumByte(types.FigureSizingPolicy, value.content.image.sizing);
        try self.byte(@intFromBool(value.frame_min_width != null));
        if (value.frame_min_width) |minimum| try self.styleLength(minimum);
        if (caption_layout) |present| try self.tableCaptionLayout(present);
        if (block_layout) |present| try self.figureBlockMediaLayout(present);
    }
    fn captionBlocks(self: *Encoder, optional: anytype) error{OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate}!void {
        const blocks_value = optional orelse { try self.byte(0); return; };
        if (self.content_depth >= types.max_content_depth) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        try self.byte(1); try self.blocks(blocks_value);
    }
    fn bidiScope(self: *Encoder, value: anytype) error{OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate}!void {
        if (self.content_depth >= types.max_content_depth or !types.validBidiScopeHeader(value)) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        try self.enumByte(types.BidiMode, value.mode);
        const authored: u8 = if (value.authored_direction) |direction| 1 + try enumByteValue(types.BidiDirectionInput, direction) else 0;
        try self.byte(authored); try self.enumByte(types.BidiResolvedDirection, value.resolved_direction);
        try self.byte(@intFromBool(value.language != null)); if (value.language) |language| try self.string(language);
        try self.flowParts(value.parts);
    }
    fn flowParts(self: *Encoder, parts: anytype) error{OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate}!void {
        try self.count(parts.len);
        for (parts) |part| {
            const kind: types.FlowPartKind = @enumFromInt(try enumByteValue(types.FlowPartKind, part.kind));
            try self.enumByte(types.FlowPartKind, kind);
            switch (kind) {
                .@"inline" => {
                    if (part.figure != null) return error.InvalidPresentation;
                    if (comptime @hasField(@TypeOf(part), "scope")) if (part.scope != null) return error.InvalidPresentation;
                    try self.spans(part.spans);
                },
                .figure => {
                    if (part.figure == null or part.spans.len != 0) return error.InvalidPresentation;
                    if (comptime @hasField(@TypeOf(part), "scope")) if (part.scope != null) return error.InvalidPresentation;
                    try self.figure(part.figure);
                },
                .scope => {
                    if (part.spans.len != 0 or part.figure != null) return error.InvalidPresentation;
                    if (comptime @hasField(@TypeOf(part), "scope")) {
                        const scope = part.scope orelse return error.InvalidPresentation;
                        try self.bidiScope(scope);
                    } else return error.InvalidPresentation;
                },
            }
        }
    }
    fn flow(self: *Encoder, optional: anytype) error{OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate}!void {
        const parts = optional orelse { try self.byte(0); return; };
        if (self.content_depth >= types.max_content_depth) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        try self.byte(1); try self.flowParts(parts);
    }
    fn blockStyle(self: *Encoder, optional: ?types.BlockStyle) !void {
        const value = optional orelse {
            try self.byte(0);
            return;
        };
        if (!types.validBlockStyle(value)) return error.InvalidPresentation;
        try self.byte(1);
        const flags: u8 = @as(u8, @intFromBool(value.margins != null)) |
            (@as(u8, @intFromBool(value.padding != null)) << 1);
        try self.byte(flags);
        if (value.margins) |edges| try self.styleEdges(edges);
        if (value.padding) |edges| try self.styleEdges(edges);
    }
    fn cellLineHeight(self: *Encoder, value: types.CellLineHeight) !void {
        if (self.version != .container_fonts or !types.validCellLineHeight(value)) return error.InvalidPresentation;
        const marker: u8 = if (value.strut) |strut| (if (strut.owner_font != null) @as(u8, 2) else 1) else 0;
        if (marker == 2 and !self.capability_p) return error.InvalidPresentation;
        try self.byte(marker);
        if (value.strut) |strut| {
            try self.writeU32(@bitCast(strut.font_scale));
            try self.enumByte(types.FontScaleBasis, strut.font_scale_basis);
            if (strut.owner_font) |font| {
                // The strut is the single wire size authority.
                var snapshot = font; snapshot.font_scale = null; snapshot.font_scale_basis = .context;
                try self.inlineFontSnapshot(snapshot);
            }
        }
        switch (value.height) {
            .normal => try self.byte(0),
            .multiplier => |factor| { try self.byte(1); try self.writeU32(@bitCast(factor)); },
            .length => |length| {
                try self.byte(2); try self.writeU32(@bitCast(length.value));
                try self.enumByte(types.FontScaleBasis, length.font_scale_basis);
            },
        }
    }
    fn cellStyle(self: *Encoder, optional: ?types.CellStyle) !void {
        const value = optional orelse {
            try self.byte(0);
            return;
        };
        if (!types.validCellStyle(value) or ((value.width != null or value.min_width != null or value.vertical_align != null or value.line_height != null) and self.version != .container_fonts)) return error.InvalidPresentation;
        try self.byte(1);
        const flags: u8 = @as(u8, @intFromBool(value.border != null)) |
            (@as(u8, @intFromBool(value.padding != null)) << 1) |
            (@as(u8, @intFromBool(value.text_align != null)) << 2) |
            (if (value.width != null) cell_width_flag else @as(u8, 0)) |
            (if (value.min_width != null) cell_min_width_flag else @as(u8, 0)) |
            (if (value.vertical_align != null) cell_vertical_align_flag else @as(u8, 0)) |
            (if (value.line_height != null) cell_line_height_flag else @as(u8, 0));
        try self.byte(flags);
        if (value.border) |border| try self.styleBorder(border);
        if (value.padding) |padding| try self.styleEdges(padding);
        if (value.text_align) |alignment| try self.enumByte(types.CellTextAlign, alignment);
        if (value.width) |width| try self.styleWidth(width);
        if (value.min_width) |width| try self.styleLength(width);
        if (value.vertical_align) |alignment| try self.enumByte(types.CellVerticalAlign, alignment);
        if (value.line_height) |height| try self.cellLineHeight(height);
    }
    fn styleWidth(self: *Encoder, value: types.StyleWidth) !void {
        if (!types.validStyleWidth(value)) return error.InvalidPresentation;
        try self.enumByte(types.StyleWidthUnit, value.unit); try self.writeU32(@bitCast(value.value));
    }
    fn tableStyle(self: *Encoder, optional: ?types.TableStyle) !void {
        const value = optional orelse {
            try self.byte(0);
            return;
        };
        if (value.corner_radii != null and !self.capability_q) return error.InvalidPresentation;
        if (tableStyleHasInlineFields(value) and !hasKFields(self.version)) return error.InvalidPresentation;
        if (value.margin_values != null and self.version != .container_fonts) return error.InvalidPresentation;
        if (value.vertical_align) |alignment| if (alignment == .top and self.version != .container_fonts) return error.InvalidPresentation;
        if (tableStyleHasBoxFields(value) and (self.version != .image_maps and !hasKFields(self.version))) return error.InvalidPresentation;
        if (!types.validTableStyle(value) or (value.float_side != null and self.version != .block_layout and (self.version != .explicit_targets and (self.version != .dynamic_catalog and (self.version != .tooltips and (self.version != .block_geometry and (self.version != .image_maps and !hasKFields(self.version)))))))) return error.InvalidPresentation;
        try self.byte(1);
        const flags: u8 = @as(u8, @intFromBool(value.background != null)) |
            (@as(u8, @intFromBool(value.border != null)) << 1) |
            (@as(u8, @intFromBool(value.collapse != null)) << 2) |
            (@as(u8, @intFromBool(value.margins != null)) << 3) |
            (@as(u8, @intFromBool(value.float_side != null)) << 4) |
            (@as(u8, @intFromBool(value.width != null)) << 5) |
            (@as(u8, @intFromBool(value.padding != null)) << 6) |
            (@as(u8, @intFromBool(value.clear != null)) << 7);
        try self.byte(flags);
        if (hasKFields(self.version)) {
            try self.byte(@as(u8, @intFromBool(value.display != null)) |
                (@as(u8, @intFromBool(value.vertical_align != null)) << 1) |
                (@as(u8, @intFromBool(value.line_height != null)) << 2) |
                (@as(u8, @intFromBool(value.margin_values != null)) << 3) |
                (@as(u8, @intFromBool(value.containing_direction != null)) << 4) |
                (@as(u8, @intFromBool(value.corner_radii != null)) << 5));
        }
        if (value.background) |color| try self.string(color);
        if (value.border) |border| try self.styleBorder(border);
        if (value.collapse) |collapse| try self.enumByte(types.BorderCollapse, collapse);
        if (value.margins) |margins| try self.styleEdges(margins);
        if (value.float_side) |side| try self.enumByte(types.TableFloatSide, side);
        if (value.width) |width| try self.styleWidth(width);
        if (value.padding) |padding| try self.styleEdges(padding);
        if (value.clear) |clear| try self.enumByte(types.FigureClear, clear);
        if (value.display) |display| try self.enumByte(types.TableDisplay, display);
        if (value.vertical_align) |alignment| try self.enumByte(types.InlineBoxVerticalAlign, alignment);
        if (value.line_height) |height| {
            try self.writeU32(@bitCast(height.value));
            try self.enumByte(types.FontScaleBasis, height.font_scale_basis);
        }
        if (value.margin_values) |margins| try self.containerMargins(margins);
        if (value.containing_direction) |direction| try self.enumByte(types.TableContainingDirection, direction);
        if (value.corner_radii) |corners| inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }) |name|
            try self.styleLength(@field(corners, name));
    }
    fn cell(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        try self.byte(@intFromBool(value.header));
        try self.writeU16(value.colspan);
        try self.writeU16(value.rowspan);
        if (hasRgb(self.version)) {
            const background: ?[]const u8 = if (comptime @hasField(@TypeOf(value), "background")) value.background else null;
            try self.byte(@intFromBool(background != null));
            if (background) |color| {
                if (!types.isCanonicalRgb(color)) return error.InvalidPresentation;
                try self.string(color);
            }
        }
        try self.spans(value.spans);
        if (hasNestedFields(self.version)) {
            if (comptime @hasField(@TypeOf(value), "nested_table")) {
                if (value.nested_table != null and value.spans.len != 0) return error.InvalidPresentation;
                try self.table(value.nested_table);
            } else try self.byte(0);
        }
        if (hasCellBlockFields(self.version)) {
            if (comptime @hasField(@TypeOf(value), "blocks")) {
                try self.byte(@intFromBool(value.blocks != null));
                if (value.blocks) |reference_blocks| {
                    if (value.spans.len != 0) return error.InvalidPresentation;
                    if (comptime @hasField(@TypeOf(value), "nested_table")) if (value.nested_table != null) return error.InvalidPresentation;
                    try self.blocks(reference_blocks);
                }
            } else try self.byte(0);
        }
        if (hasReferenceBlockFields(self.version)) {
            const style: ?types.CellStyle = if (comptime @hasField(@TypeOf(value), "style")) value.style else null;
            try self.cellStyle(style);
        }
    }
    fn row(self: *Encoder, value: anytype) !void {
        try self.count(value.cells.len);
        for (value.cells) |cell_value| try self.cell(cell_value);
    }
    fn tableGeometry(self: *Encoder, geometry: ?types.TableGeometry) !void {
        const value = geometry orelse {
            try self.byte(0);
            return;
        };
        if (!types.validTableGeometry(value)) return error.InvalidPresentation;
        const flags: u8 = @as(u8, @intFromBool(value.border != null)) |
            (@as(u8, @intFromBool(value.cell_spacing != null)) << 1) |
            (@as(u8, @intFromBool(value.cell_padding != null)) << 2) |
            (@as(u8, @intFromBool(value.width != null)) << 3);
        try self.byte(flags);
        if (value.border) |n| try self.writeU16(n);
        if (value.cell_spacing) |n| try self.writeU16(n);
        if (value.cell_padding) |n| try self.writeU16(n);
        if (value.width) |width| {
            try self.enumByte(types.TableWidthUnit, width.unit);
            try self.writeU32(width.value);
        }
    }
    fn tableBlockViewport(self: *Encoder, value: types.TableBlockViewport) !void {
        return self.tableBlockViewportIn(value, false);
    }
    fn tableBlockViewportIn(self: *Encoder, value: types.TableBlockViewport, paired: bool) !void {
        if (value.intrinsic_containing_direction != null and !self.capability_r) return error.InvalidPresentation;
        if (self.version != .container_fonts or (paired and !self.capability_p) or
            !(if (paired) types.validTableScrollViewport(value) else types.validTableBlockViewport(value) or (self.capability_q and types.validTableCornerBlockViewport(value)) or (self.capability_r and types.validTableIntrinsicViewport(value)))) return error.InvalidPresentation;
        try self.writeU32(value.max_viewport_width_px);
        try self.tableStyle(value.box_style);
        try self.enumByte(types.ContainerBoxSizing, value.box_sizing);
        try self.styleWidth(value.max_width);
        try self.tableStyle(value.grid_style);
        try self.enumByte(types.TableContainingDirection, value.grid_direction);
        try self.string(value.language);
        if (value.intrinsic_containing_direction) |direction| try self.enumByte(types.TableContainingDirection, direction);
        if (value.intrinsic_containing_direction != null or paired or (self.capability_q and types.tableCornerBlockViewportShape(value))) {
            const focus = value.focus_paint orelse return error.InvalidPresentation;
            try self.enumByte(types.TableScrollFocusMode, focus.mode);
            try self.byte(if (focus.color != null) 1 else 0);
            if (focus.color) |color| try self.figureColor(color);
        }
    }
    fn table(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        if (value) |table_value| {
            if (self.table_depth >= types.max_table_depth) return error.InvalidPresentation;
            self.table_depth += 1;
            defer self.table_depth -= 1;
            const viewport: ?*const types.TableBlockViewport = if (comptime @hasField(@TypeOf(table_value), "block_viewport")) table_value.block_viewport else null;
            const viewport_geometry: ?types.TableGeometry = if (comptime @hasField(@TypeOf(table_value), "geometry")) table_value.geometry else null;
            const viewport_style: ?types.TableStyle = if (comptime @hasField(@TypeOf(table_value), "style")) table_value.style else null;
            const float_viewport: ?types.TableFloatViewport = if (comptime @hasField(@TypeOf(table_value), "float_viewport")) table_value.float_viewport else null;
            const paired = viewport != null and float_viewport != null;
            const intrinsic = if (viewport) |policy| policy.intrinsic_containing_direction != null else false;
            if (intrinsic and !self.capability_r) return error.InvalidPresentation;
            if (((viewport != null or float_viewport != null) and self.version != .container_fonts) or
                (paired and !self.capability_p) or
                !types.validTableViewportHeaders(viewport_geometry, viewport_style, viewport, float_viewport)) return error.InvalidPresentation;
            const extended_clear = if (float_viewport) |policy| policy.narrow_clear != null else false;
            if (extended_clear and !self.capability_p) return error.InvalidPresentation;
            try self.byte(1 | (@as(u8, @intFromBool(viewport != null)) << 1) | (@as(u8, @intFromBool(float_viewport != null)) << 2) |
                (@as(u8, @intFromBool(extended_clear)) << 3) | (@as(u8, @intFromBool(intrinsic)) << 4));
            if (hasNestedFields(self.version)) {
                const geometry: ?types.TableGeometry = if (comptime @hasField(@TypeOf(table_value), "geometry")) table_value.geometry else null;
                try self.tableGeometry(geometry);
            }
            const inline_style: ?types.TableStyle = if (comptime @hasField(@TypeOf(table_value), "style")) table_value.style else null;
            const has_caption_blocks = if (comptime @hasField(@TypeOf(table_value), "caption_blocks")) table_value.caption_blocks != null else false;
            var has_cells = false;
            for (table_value.rows) |row_value| if (row_value.cells.len != 0) { has_cells = true; break; };
            if (!types.validTableFloatViewportContent(float_viewport, table_value.caption.len, has_caption_blocks, has_cells)) return error.InvalidPresentation;
            if (!types.validInlineTableContent(inline_style, table_value.caption.len, has_caption_blocks, has_cells)) return error.InvalidPresentation;
            if (types.tableStyleIsInline(inline_style)) {
                if (self.table_depth != 1 or self.content_depth != 0 or self.in_reference or
                    !(if (self.version == .container_fonts) types.inlineTableShapeSupportedM(table_value) else types.inlineTableShapeSupported(table_value))) return error.InvalidPresentation;
                for (table_value.rows) |row_value| for (row_value.cells) |cell_value| for (cell_value.spans) |inline_value| {
                    if (inline_value.image == null and !types.inlineTableEmbeddedMedia(inline_value)) continue;
                    const catalog = self.inline_media_catalog orelse return error.InvalidPresentation;
                    if (!(if (self.version == .container_fonts) catalog.supportsInlineTableMedia(inline_value) else catalog.supportsInlineTableAudio(inline_value))) return error.InvalidPresentation;
                };
            }
            try self.spans(table_value.caption);
            try self.count(table_value.rows.len);
            for (table_value.rows) |row_value| try self.row(row_value);
            if (hasReferenceBlockFields(self.version)) {
                const style: ?types.TableStyle = if (comptime @hasField(@TypeOf(table_value), "style")) table_value.style else null;
                try self.tableStyle(style);
            }
            if (comptime @hasField(@TypeOf(table_value), "caption_blocks")) {
                if (table_value.caption_blocks != null and ((self.version != .image_maps and !hasKFields(self.version)) or table_value.caption.len != 0)) return error.InvalidPresentation;
            }
            if ((self.version == .image_maps or hasKFields(self.version))) {
                if (comptime @hasField(@TypeOf(table_value), "caption_blocks")) try self.captionBlocks(table_value.caption_blocks) else try self.byte(0);
            }
            if (viewport) |policy| try self.tableBlockViewportIn(policy.*, paired);
            if (float_viewport) |policy| {
                try self.writeU32(policy.max_viewport_width_px);
                try self.enumByte(types.TableContainingDirection, policy.containing_direction);
                try self.enumByte(types.TableContainingDirection, policy.grid_direction);
                try self.string(policy.language);
                if (policy.narrow_clear) |clear| try self.enumByte(types.FigureClear, clear);
            }
        } else try self.byte(0);
    }
    fn containerWidth(self: *Encoder, value: types.ContainerWidth) !void {
        if (!types.validContainerWidth(value)) return error.InvalidPresentation;
        switch (value) {
            .auto => try self.byte(0),
            .length => |length| { try self.byte(1); try self.styleWidth(length); },
            .fit_content => try self.byte(2),
        }
    }
    fn containerMaxWidth(self: *Encoder, value: types.ContainerMaxWidth) !void {
        if (!types.validContainerMaxWidth(value)) return error.InvalidPresentation;
        switch (value) { .none => try self.byte(0), .length => |length| { try self.byte(1); try self.styleWidth(length); } }
    }
    fn containerColor(self: *Encoder, value: types.ContainerColor) !void {
        if (!types.validContainerColor(value)) return error.InvalidPresentation;
        switch (value) {
            .transparent => try self.byte(0),
            .rgb => |color| { try self.byte(1); try self.string(color); },
            .light_dark => |colors| { try self.byte(2); try self.string(colors.light); try self.string(colors.dark); },
        }
    }
    fn containerBorderEdge(self: *Encoder, value: types.ContainerBorderEdge) !void {
        if (self.version != .container_fonts or !types.validContainerBorderEdge(value)) return error.InvalidPresentation;
        switch (value) {
            .none => try self.byte(0),
            .hidden => try self.byte(1),
            .solid, .dotted => |line| {
                try self.byte(if (value == .solid) 2 else 3);
                try self.styleLength(line.width); try self.containerColor(line.color);
            },
        }
    }
    fn containerBorder(self: *Encoder, value: types.ContainerBorder) !void {
        if (!types.validContainerBorder(value)) return error.InvalidPresentation;
        switch (value) { .none => try self.byte(0), .solid => |border| { try self.byte(1); try self.styleLength(border.width); try self.containerColor(border.color); }, .edges => |edges| {
            if (self.version != .container_fonts) return error.InvalidPresentation;
            try self.byte(2); inline for (.{ "top", "right", "bottom", "left" }) |side| try self.containerBorderEdge(@field(edges, side));
        } }
    }
    fn containerLineHeight(self: *Encoder, value: types.ContainerLineHeight) !void {
        if (!types.validContainerLineHeight(value)) return error.InvalidPresentation;
        switch (value) {
            .normal => try self.byte(0),
            .multiplier => |factor| { try self.byte(1); try self.writeU32(@bitCast(factor)); },
            .length => |length| { try self.byte(2); try self.styleLength(length); },
        }
    }
    fn containerMarginLength(self: *Encoder, value: types.StyleLength) !void {
        if (self.version != .container_fonts) return self.styleLength(value);
        if (!types.validContainerMarginLength(value)) return error.InvalidPresentation;
        try self.enumByte(types.StyleLengthUnit, value.unit);
        try self.writeU32(@bitCast(value.value));
    }
    fn containerMarginEdges(self: *Encoder, value: types.StyleEdges) !void {
        inline for (.{ "top", "right", "bottom", "left" }) |side| try self.containerMarginLength(@field(value, side));
    }
    fn containerMargin(self: *Encoder, value: types.ContainerMargin) !void {
        if (!hasLFields(self.version) or !types.validContainerMargin(value)) return error.InvalidPresentation;
        switch (value) { .auto => try self.byte(0), .length => |length| { try self.byte(1); try self.containerMarginLength(length); } }
    }
    fn containerMargins(self: *Encoder, value: types.ContainerMargins) !void {
        inline for (.{ "top", "right", "bottom", "left" }) |name| try self.containerMargin(@field(value, name));
    }
    fn containerScreenPrefix(self: *Encoder, value: types.ContainerScreenMaxWidth, following: bool) !void {
        if (!hasLFields(self.version) or !types.validContainerScreenMaxWidth(value)) return error.InvalidPresentation;
        try self.writeU32(value.max_width_px);
        const flags: u8 = @as(u8, @intFromBool(value.width != null)) | (@as(u8, @intFromBool(value.max_width != null)) << 1) | (@as(u8, @intFromBool(value.box_sizing != null)) << 2) | (@as(u8, @intFromBool(value.line_height != null)) << 3) | (@as(u8, @intFromBool(value.float_side != null)) << 4) | (@as(u8, @intFromBool(value.margins != null)) << 5) | (@as(u8, @intFromBool(value.clear != null)) << 6) | (@as(u8, @intFromBool(following)) << 7);
        try self.byte(flags);
        if (value.width) |width| try self.containerWidth(width);
        if (value.max_width) |width| try self.containerMaxWidth(width);
        if (value.box_sizing) |sizing| try self.enumByte(types.ContainerBoxSizing, sizing);
        if (value.line_height) |height| try self.containerLineHeight(height);
        if (value.float_side) |side| try self.enumByte(types.ContainerFloatOverride, side);
        if (value.margins) |margins| try self.containerMargins(margins);
        if (value.clear) |clear| try self.enumByte(types.FigureClear, clear);
    }
    fn containerScreen(self: *Encoder, value: types.ContainerScreenMaxWidth) !void {
        if (!hasLFields(self.version) or !types.validContainerScreenMaxWidth(value)) return error.InvalidPresentation;
        try self.containerScreenPrefix(value, value.following_rules.len != 0);
        if (value.following_rules.len != 0) {
            try self.count(value.following_rules.len);
            for (value.following_rules) |rule| try self.containerScreenPrefix(rule, false);
        }
    }
    fn containerFontFamily(self: *Encoder, value: types.ContainerFontFamily) !void {
        if (!types.validContainerFontFamily(value)) return error.InvalidPresentation;
        switch (value) {
            .sans_serif => try self.byte(0),
            .stack => |stack| {
                if (!self.capability_p) return error.InvalidPresentation;
                try self.byte(1); try self.count(stack.names.len);
                for (stack.names) |name| try self.string(name);
                try self.enumByte(types.GenericFontFamily, stack.fallback);
            },
        }
    }
    fn sectionHeadingStyles(self: *Encoder, values: anytype) !void {
        var styled_count: usize = 0;
        for (values) |section| if (sectionHeadingStyle(section) != null) { styled_count += 1; };
        if (styled_count == 0 or !self.capability_p) return error.InvalidPresentation;
        try self.count(styled_count);
        for (values, 0..) |section, index_value| if (sectionHeadingStyle(section)) |style| {
            if (!types.validSectionHeadingStyle(style) or !types.validSectionHeadingCompanion(section)) return error.InvalidPresentation;
            try self.index(index_value); try self.containerStyle(style.box);
            try self.inlineFontSnapshot(style.font); try self.enumByte(types.BidiResolvedDirection, style.direction);
        };
    }
    fn containerStyle(self: *Encoder, value: types.ContainerStyle) !void {
        if (!hasLFields(self.version) or !types.validContainerStyle(value)) return error.InvalidPresentation;
        if ((value.owner_font_scale != null or value.height != null or value.columns != null or value.positioning != null or value.min_height != null or value.margin_values != null or value.font_family != null) and self.version != .container_fonts) return error.InvalidPresentation;
        var flags: u32 = 0;
        inline for (@typeInfo(types.ContainerStyle).@"struct".field_names, 0..) |name, bit| if (@field(value, name) != null) { flags |= @as(u32, 1) << bit; };
        if (self.version == .container_fonts) try self.writeU32(flags) else try self.writeU16(@intCast(flags));
        if (value.margins) |edges| try self.containerMarginEdges(edges);
        if (value.padding) |edges| try self.styleEdges(edges);
        if (value.width) |width| try self.containerWidth(width);
        if (value.float_side) |side| try self.enumByte(types.TableFloatSide, side);
        if (value.clear) |clear| try self.enumByte(types.FigureClear, clear);
        if (value.max_width) |width| try self.containerMaxWidth(width);
        if (value.box_sizing) |sizing| try self.enumByte(types.ContainerBoxSizing, sizing);
        if (value.layout) |layout_value| try self.enumByte(types.ContainerLayout, layout_value);
        if (value.align_items) |alignment| try self.enumByte(types.ContainerAlignItems, alignment);
        if (value.flex_item) |item| try self.enumByte(types.ContainerFlexItem, item);
        if (value.background) |color| try self.containerColor(color);
        if (value.border) |border| try self.containerBorder(border);
        if (value.line_height) |height| try self.containerLineHeight(height);
        if (value.text_align) |alignment| try self.enumByte(types.CellTextAlign, alignment);
        if (value.screen_max_width) |screen| try self.containerScreen(screen);
        if (value.overflow) |overflow| try self.enumByte(types.ContainerOverflow, overflow);
        if (value.owner_font_scale) |scale| try self.writeU32(@bitCast(scale));
        if (value.height) |height| try self.styleLength(height);
        if (value.columns) |columns| { try self.writeU16(columns.count); try self.styleLength(columns.gap); }
        if (value.positioning) |positioning| try self.enumByte(types.ContainerPositioning, positioning);
        if (value.min_height) |height| try self.styleLength(height);
        if (value.margin_values) |margins| try self.containerMargins(margins);
        if (value.font_family) |family| try self.containerFontFamily(family);
    }
    fn container(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        if (!hasLFields(self.version) or !types.validContainerHeader(value) or self.content_depth >= types.max_content_depth) return error.InvalidPresentation;
        if (self.version != .container_fonts and !types.legacyContainerMarginsSupported(value)) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        try self.containerStyle(value.style);
        try self.blocks(value.blocks);
    }
    fn childPath(self: *Encoder, path: []const usize) !void {
        if (path.len > types.max_content_depth) return error.InvalidPresentation;
        try self.indices(path);
    }
    fn childPaths(self: *Encoder, roots: []const usize, paths: []const []const usize) !void {
        if (paths.len != 0) {
            if (paths.len != roots.len) return error.InvalidPresentation;
            var nested = false; for (paths) |path| { nested = nested or path.len != 0; }
            if (!nested) return error.InvalidPresentation;
        }
        try self.count(paths.len);
        for (paths) |path| try self.childPath(path);
    }
    fn ruleStyle(self: *Encoder, value: types.RuleStyle) !void {
        if (!self.rule_styles or self.version != .container_fonts or !types.validRuleStyle(value) or
            (value.clear != null and !self.capability_r)) return error.InvalidPresentation;
        try self.styleLength(value.height);
        try self.containerColor(value.fill);
        try self.styleEdges(value.margins);
        if (value.clear) |clear| try self.enumByte(types.FigureClear, clear);
    }
    fn block(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        const rule_style = blockRuleStyle(value);
        if (self.rule_styles and self.version != .container_fonts) return error.InvalidPresentation;
        if (rule_style) |style| if (!self.rule_styles or !types.validRuleStyle(style) or !types.validRuleStyleContext(value)) return error.InvalidPresentation;
        const block_kind = try enumByteValue(types.BlockKind, value.kind);
        if (block_kind == @backingInt(types.BlockKind.container)) {
            if (!hasLFields(self.version) or !types.validContainerContext(value)) return error.InvalidPresentation;
        } else if (comptime @hasField(@TypeOf(value), "container")) if (value.container != null) return error.InvalidPresentation;
        if (comptime @hasField(@TypeOf(value), "figure")) if (value.figure != null) {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            if (value.spans.len != 0 or (self.version != .image_maps and !hasKFields(self.version)) or !types.validFigureContext(kind, value.depth, value.table != null, value.feature != null, blockGeometry(value) != null, value.list_path)) return error.InvalidPresentation;
        };
        if (comptime @hasField(@TypeOf(value), "flow")) if (value.flow != null) {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            const has_figure = if (comptime @hasField(@TypeOf(value), "figure")) value.figure != null else false;
            if ((self.version != .image_maps and !hasKFields(self.version)) or value.spans.len != 0 or !types.validFlowContext(kind, value.depth, value.table != null, value.feature != null, has_figure, value.list_path)) return error.InvalidPresentation;
        };
        const geometry = blockGeometry(value);
        if (geometry) |style| {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            if ((self.version != .block_geometry and (self.version != .image_maps and !hasKFields(self.version))) or !types.validBlockStyle(style) or
                !types.validBlockStyleContext(kind, value.depth, value.table != null, value.feature != null, value.list_path)) return error.InvalidPresentation;
        }
        if (value.table) |table_value| if (types.tableStyleIsInline(table_value.style)) {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            if (!types.validInlineTableOwner(kind, value.spans.len, value.feature != null)) return error.InvalidPresentation;
        };
        if ((anchorValue(value).len != 0 or fallbackValue(value).len != 0) and (try enumByteValue(types.BlockKind, value.kind)) != @backingInt(types.BlockKind.heading)) return error.InvalidPresentation;
        try self.enumByte(types.BlockKind, value.kind);
        try self.byte(value.depth);
        try self.byte(value.level);
        try self.spans(value.spans);
        try self.feature(value.feature);
        try self.string(value.list_path);
        try self.string(value.number);
        try self.table(value.table);
        if (hasAnchorFields(self.version)) {
            try self.string(anchorValue(value));
            try self.string(fallbackValue(value));
        }
        const alignment = blockTextAlign(value);
        if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))))))) {
            try self.byte(@intFromBool(alignment != null));
            if (alignment) |present| try self.enumByte(types.CellTextAlign, present);
        } else if (alignment != null) return error.InvalidPresentation;
        if ((self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))) try self.blockStyle(geometry);
        if ((self.version == .image_maps or hasKFields(self.version))) {
            if (comptime @hasField(@TypeOf(value), "figure")) try self.figure(value.figure) else try self.byte(0);
            if (comptime @hasField(@TypeOf(value), "flow")) try self.flow(value.flow) else try self.byte(0);
        }
        if (block_kind == @backingInt(types.BlockKind.container)) {
            if (comptime @hasField(@TypeOf(value), "container")) try self.container(value.container.?) else return error.InvalidPresentation;
        }
        if (self.rule_styles and block_kind == @backingInt(types.BlockKind.rule)) {
            try self.byte(if (rule_style) |style| if (style.clear != null) @as(u8, 2) else 1 else 0);
            if (rule_style) |style| try self.ruleStyle(style);
        }
    }
    fn blocks(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |value| try self.block(value);
    }
    fn sections(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |section| {
            try self.byte(section.level);
            try self.string(section.title);
            if (hasAnchorFields(self.version)) {
                try self.string(anchorValue(section));
                try self.string(fallbackValue(section));
            }
            try self.count(section.blocks.len);
            for (section.blocks) |block_value| try self.block(block_value);
        }
    }
    fn form(self: *Encoder, value: anytype) !void {
        if (value) |form_value| {
            try self.byte(1);
            try self.string(form_value.relation);
            try self.string(form_value.target);
            try self.string(form_value.language);
        } else try self.byte(0);
    }
    fn sense(self: *Encoder, value: anytype) !void {
        try self.index(value.block);
        try self.optionalIndex(value.parent);
        try self.indices(value.examples);
        try self.indices(value.quotations);
        try self.indices(value.notes);
        try self.form(value.form);
        if (hasLFields(self.version)) {
            try self.childPath(sensePath(value));
            try self.childPaths(value.examples, lexicalPaths(value, "example_paths"));
            try self.childPaths(value.quotations, lexicalPaths(value, "quotation_paths"));
            try self.childPaths(value.notes, lexicalPaths(value, "note_paths"));
        } else if (senseHasPaths(value)) return error.InvalidPresentation;
    }
    fn layout(self: *Encoder, value: anytype) !void {
        try self.count(value.lexemes.len);
        for (value.lexemes) |lexeme| {
            try self.string(lexeme.language);
            try self.string(lexeme.kind);
            try self.index(lexeme.section);
            try self.optionalIndex(lexeme.etymology);
            try self.count(lexeme.definitions.len);
            for (lexeme.definitions) |sense_value| try self.sense(sense_value);
            try self.indices(lexeme.introduction);
            try self.indices(lexeme.other_blocks);
            try self.indices(lexeme.related_sections);
            if (hasLFields(self.version)) {
                try self.childPaths(lexeme.introduction, lexicalPaths(lexeme, "introduction_paths"));
                try self.childPaths(lexeme.other_blocks, lexicalPaths(lexeme, "other_block_paths"));
            } else if (lexicalPaths(lexeme, "introduction_paths").len != 0 or lexicalPaths(lexeme, "other_block_paths").len != 0) return error.InvalidPresentation;
        }
        try self.indices(value.other_sections);
    }
    fn references(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |reference| {
            const kind = try enumByteValue(types.ReferenceKind, reference.kind);
            if (reference.number == 0) return error.InvalidPresentation;
            if (kind == @backingInt(types.ReferenceKind.note)) {
                const ordinal = reference.group_number orelse return error.InvalidPresentation;
                if (ordinal == 0) return error.InvalidPresentation;
                if (hasReferenceFields(self.version)) try self.byte(kind);
                try self.index(reference.number);
                try self.index(ordinal);
                try self.string(reference.name);
            } else {
                if (!hasReferenceFields(self.version) or reference.group_number != null or reference.name.len != 0)
                    return error.InvalidPresentation;
                try self.byte(kind);
                try self.index(reference.number);
            }
            try self.string(reference.group);
            try self.spans(reference.spans);
            if (hasReferenceBlockFields(self.version)) {
                if (comptime @hasField(@TypeOf(reference), "blocks")) {
                    try self.byte(@intFromBool(reference.blocks != null));
                    if (reference.blocks) |blocks_value| {
                        if (reference.spans.len != 0) return error.InvalidPresentation;
                        const previous_reference = self.in_reference;
                        self.in_reference = true;
                        defer self.in_reference = previous_reference;
                        try self.blocks(blocks_value);
                    }
                } else try self.byte(0);
            }
        }
    }
    fn media(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |item| {
            try self.string(item.file);
            try self.enumByte(types.MediaKind, item.kind);
            try self.string(item.caption);
        }
    }
};

/// Observed while the existing decoder consumes one successful DPR2 payload.
/// These are measurements, not a reader compatibility verdict or new limits.
pub const TableGridMetrics = struct {
    exact_compact_columns: ?usize = 0,
    columns_lower_bound: usize = 0,
    column_limit_exceeded: bool = false,
    spans_supported: bool = true,
    occupied_rows: usize = 0,
    max_colspan: u16 = 0,
    max_rowspan: u16 = 0,
};

// Observation only. This mirrors the selected Android sparse placement without
// allocating a dense grid or retaining more than 513 global boundaries.
const GridObserver = struct {
    const Interval = struct { start: u64, end: u64, until_row: usize };
    active: [512]Interval = undefined,
    active_len: usize = 0,
    boundaries: [513]u64 = undefined,
    boundary_len: usize = 1,

    fn init() GridObserver {
        var self: GridObserver = .{};
        self.boundaries[0] = 0;
        return self;
    }
    fn expire(self: *GridObserver, row: usize) void {
        var kept: usize = 0;
        for (self.active[0..self.active_len]) |interval| {
            if (interval.until_row > row) {
                self.active[kept] = interval;
                kept += 1;
            }
        }
        self.active_len = kept;
    }
    fn lowerActive(self: *const GridObserver, column: u64) usize {
        var lo: usize = 0;
        var hi = self.active_len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.active[mid].start < column) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
    fn boundary(self: *GridObserver, value: u64) bool {
        var lo: usize = 0;
        var hi = self.boundary_len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.boundaries[mid] < value) lo = mid + 1 else hi = mid;
        }
        if (lo < self.boundary_len and self.boundaries[lo] == value) return true;
        // A new 514th boundary proves at least 513 compact columns. Do not
        // insert it or pretend the saturated count is the final exact width.
        if (self.boundary_len == self.boundaries.len) return false;
        var i = self.boundary_len;
        while (i > lo) : (i -= 1) self.boundaries[i] = self.boundaries[i - 1];
        self.boundaries[lo] = value;
        self.boundary_len += 1;
        return true;
    }
    fn place(self: *GridObserver, column: *u64, cell: types.Cell, row: usize) bool {
        var end: u64 = undefined;
        var index: usize = undefined;
        while (true) {
            end = column.* + cell.colspan;
            index = self.lowerActive(column.*);
            if (index > 0 and self.active[index - 1].end > column.*) {
                column.* = self.active[index - 1].end;
            } else if (index < self.active_len and self.active[index].start < end) {
                column.* = self.active[index].end;
            } else break;
        }
        if (!self.boundary(column.*) or !self.boundary(end)) return false;
        // Nonoverlapping positive intervals need at most boundaries-1 slots.
        std.debug.assert(self.active_len < self.active.len);
        var i = self.active_len;
        while (i > index) : (i -= 1) self.active[i] = self.active[i - 1];
        self.active[index] = .{ .start = column.*, .end = end, .until_row = row + cell.rowspan };
        self.active_len += 1;
        column.* = end;
        return true;
    }
};

pub fn measureTableGrid(table: types.Table) TableGridMetrics {
    var result: TableGridMetrics = .{ .occupied_rows = table.rows.len };
    var observer = GridObserver.init();
    var observe_columns = true;
    for (table.rows, 0..) |row, row_index| {
        if (observe_columns) observer.expire(row_index);
        var column: u64 = 0;
        for (row.cells) |cell| {
            result.occupied_rows = @max(result.occupied_rows, row_index + @as(usize, cell.rowspan));
            result.max_colspan = @max(result.max_colspan, cell.colspan);
            result.max_rowspan = @max(result.max_rowspan, cell.rowspan);
            if (cell.colspan == 0 or cell.colspan > 100 or cell.rowspan == 0 or cell.rowspan > 100) {
                result.spans_supported = false;
                result.exact_compact_columns = null;
                observe_columns = false;
            }
            if (observe_columns and !observer.place(&column, cell, row_index)) {
                result.column_limit_exceeded = true;
                result.exact_compact_columns = null;
                result.columns_lower_bound = 513;
                observe_columns = false;
            }
        }
    }
    if (result.exact_compact_columns != null) {
        result.exact_compact_columns = observer.boundary_len - 1;
        result.columns_lower_bound = observer.boundary_len - 1;
    }
    return result;
}

pub const DecodeMetrics = struct {
    total_items: u64 = 0,
    largest_string_bytes: usize = 0,
    tables: usize = 0,
    table_columns_exact: ?usize = 0,
    table_columns_lower_bound: usize = 0,
    table_column_limit_exceeded: bool = false,
    table_spans_supported: bool = true,
    max_table_rows: usize = 0,
    max_table_colspan: u16 = 0,
    max_table_rowspan: u16 = 0,
    widest_table: ?usize = null,
    tallest_table: ?usize = null,
    span_table: ?usize = null,

    fn tableTree(self: *DecodeMetrics, value: types.Table) void {
        self.contentTableTree(value, 1, 0);
    }
    // Root-table ownership and preorder ordinals are unchanged. Tables decoded
    // while inside a rich caption have table_depth > 1 and belong to this walk.
    fn contentTableTree(self: *DecodeMetrics, value: types.Table, table_depth: usize, content_depth: usize) void {
        if (table_depth > types.max_table_depth or content_depth > types.max_content_depth) return;
        self.table(value);
        if (value.caption_blocks) |blocks| self.contentBlockTables(blocks, table_depth, content_depth + 1);
        for (value.rows) |row| for (row.cells) |cell| {
            if (cell.nested_table) |child| self.contentTableTree(child, table_depth + 1, content_depth);
            if (cell.blocks) |blocks| self.contentBlockTables(blocks, table_depth, content_depth);
        };
    }
    fn figureTables(self: *DecodeMetrics, figure: types.Figure, table_depth: usize, content_depth: usize) void {
        if (figure.caption_blocks) |blocks| self.contentBlockTables(blocks, table_depth, content_depth + 1);
    }
    fn contentPartTables(self: *DecodeMetrics, parts: []const types.FlowPart, table_depth: usize, content_depth: usize) void {
        if (content_depth > types.max_content_depth) return;
        for (parts) |part| {
            if (part.figure) |figure| self.figureTables(figure, table_depth, content_depth);
            if (part.scope) |scope| self.contentPartTables(scope.parts, table_depth, content_depth + 1);
        }
    }
    fn contentBlockTables(self: *DecodeMetrics, blocks: []const types.Block, table_depth: usize, content_depth: usize) void {
        if (content_depth > types.max_content_depth) return;
        for (blocks) |block| {
            if (block.container) |box| self.contentBlockTables(box.blocks, table_depth, content_depth + 1);
            if (block.table) |table_value| self.contentTableTree(table_value, table_depth + 1, content_depth);
            if (block.figure) |figure| self.figureTables(figure, table_depth, content_depth);
            if (block.flow) |parts| {
                if (content_depth >= types.max_content_depth) continue;
                self.contentPartTables(parts, table_depth, content_depth + 1);
            }
        }
    }

    fn table(self: *DecodeMetrics, value: types.Table) void {
        const observed = measureTableGrid(value);
        const ordinal = self.tables;
        self.tables += 1;
        if (self.widest_table == null or observed.columns_lower_bound > self.table_columns_lower_bound or
            (observed.column_limit_exceeded and !self.table_column_limit_exceeded)) self.widest_table = ordinal;
        if (self.tallest_table == null or observed.occupied_rows > self.max_table_rows) self.tallest_table = ordinal;
        if (self.span_table == null or observed.max_colspan > self.max_table_colspan or
            observed.max_rowspan > self.max_table_rowspan or (!observed.spans_supported and self.table_spans_supported)) self.span_table = ordinal;
        self.table_columns_lower_bound = @max(self.table_columns_lower_bound, observed.columns_lower_bound);
        if (self.table_columns_exact) |previous| {
            self.table_columns_exact = if (observed.exact_compact_columns) |columns| @max(previous, columns) else null;
        }
        self.table_column_limit_exceeded = self.table_column_limit_exceeded or observed.column_limit_exceeded;
        self.table_spans_supported = self.table_spans_supported and observed.spans_supported;
        self.max_table_rows = @max(self.max_table_rows, observed.occupied_rows);
        self.max_table_colspan = @max(self.max_table_colspan, observed.max_colspan);
        self.max_table_rowspan = @max(self.max_table_rowspan, observed.max_rowspan);
    }
};

const Reader = struct {
    a: A,
    version: Version = .plain,
    rule_styles: bool = false,
    inline_styles: bool = false,
    capability_p: bool = false,
    capability_q: bool = false,
    capability_r: bool = false,
    bytes: []const u8,
    pos: usize = 0,
    metrics: ?*DecodeMetrics = null,
    table_depth: usize = 0,
    content_depth: usize = 0,
    in_reference: bool = false,
    remaining_items: usize = max_items,
    remaining_map_string_bytes: usize = types.max_image_map_string_bytes,

    fn remaining(self: Reader) usize {
        return self.bytes.len -| self.pos;
    }
    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.InvalidPresentation;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn readU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn readU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    fn count(self: *Reader, min_bytes: usize) !usize {
        const value: usize = try self.readU32();
        if (value > max_items) return error.InvalidPresentation;
        if (hasNestedFields(self.version)) {
            if (value > self.remaining_items) return error.InvalidPresentation;
            self.remaining_items -= value;
        }
        if (min_bytes != 0 and value > self.remaining() / min_bytes) return error.InvalidPresentation;
        if (self.metrics) |metrics| {
            metrics.total_items = std.math.add(u64, metrics.total_items, @as(u64, value)) catch return error.InvalidPresentation;
        }
        return value;
    }
    fn index(self: *Reader) !usize {
        const value = try self.readU32();
        if (value == no_index) return error.InvalidPresentation;
        return value;
    }
    fn optionalIndex(self: *Reader) !?usize {
        const value = try self.readU32();
        return if (value == no_index) null else @as(usize, value);
    }
    fn string(self: *Reader) ![]const u8 {
        const len: usize = try self.readU32();
        if (len > max_string_bytes) return error.InvalidPresentation;
        const value = try self.take(len);
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidPresentation;
        if (self.metrics) |metrics| metrics.largest_string_bytes = @max(metrics.largest_string_bytes, len);
        return value;
    }
    fn enumValue(self: *Reader, comptime E: type) !E {
        return std.enums.fromInt(E, try self.byte()) orelse return error.InvalidPresentation;
    }
    fn presence(self: *Reader) !bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidPresentation,
        };
    }
    fn indices(self: *Reader) ![]const usize {
        const len = try self.count(4);
        const out = try self.a.alloc(usize, len);
        for (out) |*value| value.* = try self.index();
        return out;
    }
    fn inlineComputedLength(self: *Reader) !types.ComputedLineHeight {
        return .{ .value = @bitCast(try self.readU32()), .font_scale_basis = try self.enumValue(types.FontScaleBasis) };
    }
    fn inlineFontSnapshot(self: *Reader) !types.InlineFontSnapshot {
        const flags = try self.byte();
        if (flags & 0xe0 != 0) return error.InvalidPresentation;
        var value: types.InlineFontSnapshot = .{
            .small = flags & 2 != 0, .superscript = flags & 4 != 0,
            .subscript = flags & 8 != 0, .font_normalized = flags & 16 != 0,
        };
        if (flags & 1 != 0) {
            value.font_scale = @bitCast(try self.readU32());
            value.font_scale_basis = try self.enumValue(types.FontScaleBasis);
            // Use the same identity representation as Reader.span, so the
            // explicit-shift owner/run tuple survives canonical decoding.
            if (value.font_scale == 1 and value.font_scale_basis == .context) value.font_scale = null;
        }
        const face = try self.byte();
        if (face & (if (self.capability_p) @as(u8, 0xe0) else 0xf0) != 0) return error.InvalidPresentation;
        value.bold = face & 1 != 0; value.italic = face & 2 != 0; value.code = face & 4 != 0;
        value.language = try self.string(); value.classes = try self.string();
        value.role = try self.enumValue(types.Role);
        if (face & 8 != 0) value.font_features = try self.enumValue(types.FontFeaturePolicy);
        if (face & 16 != 0) value.font_family = try self.containerFontFamily();
        if (!types.validInlineFontSnapshot(value)) return error.InvalidPresentation;
        return value;
    }
    fn inlineTextStyle(self: *Reader) !types.InlineTextStyle {
        if (!self.inline_styles or self.version != .container_fonts) return error.InvalidPresentation;
        const flags = try self.byte();
        if (flags == 0 or flags & 0xe0 != 0) return error.InvalidPresentation;
        var value: types.InlineTextStyle = .{ .font_normalized = flags & 8 != 0 };
        if (flags & 1 != 0) {
            value.decoration = .{
                .style = try self.enumValue(types.InlineUnderlineStyle),
                .color = if (try self.presence()) try self.string() else null,
                .thickness = if (try self.presence()) try self.styleLength() else null,
            };
        }
        if (flags & 2 != 0) value.line_height = switch (try self.byte()) {
            0 => .{ .computed = try self.inlineComputedLength() },
            1 => .{ .font_relative = .{ .factor = @bitCast(try self.readU32()), .font = try self.inlineFontSnapshot() } },
            else => return error.InvalidPresentation,
        };
        if (flags & 4 != 0) value.baseline_shift = try self.inlineComputedLength();
        if (flags & 16 != 0) value.cursor = try self.enumValue(types.InlineCursor);
        if (!types.validInlineTextStyle(value)) return error.InvalidPresentation;
        return value;
    }

    fn span(self: *Reader) !types.Span {
        const kind = try self.enumValue(types.InlineKind);
        const role = try self.enumValue(types.Role);
        const flags = try self.byte();
        var result: types.Span = .{
            .kind = kind,
            .role = role,
            .bold = flags & (1 << 0) != 0,
            .italic = flags & (1 << 1) != 0,
            .code = flags & (1 << 2) != 0,
            .small = flags & (1 << 3) != 0,
            .superscript = flags & (1 << 4) != 0,
            .subscript = flags & (1 << 5) != 0,
            .strike = flags & (1 << 6) != 0,
            .underline = flags & (1 << 7) != 0,
            .text = try self.string(),
            .target = try self.string(),
            .trail = try self.string(),
            .language = try self.string(),
            .classes = try self.string(),
            .direction = try self.string(),
            .explanation = if (self.version != .plain) try self.string() else "",
            .foreground = if (hasRgb(self.version) and try self.presence()) foreground: {
                const value = try self.string();
                if (!types.isCanonicalRgb(value)) return error.InvalidPresentation;
                break :foreground value;
            } else null,
            .background = if (hasSpanBackgroundFields(self.version) and try self.presence()) background: {
                const value = try self.string();
                if (!types.isCanonicalRgb(value)) return error.InvalidPresentation;
                break :background value;
            } else null,
        };
        if (hasFontScaleFields(self.version)) {
            const font_fields = try self.byte();
            const unknown_mask: u8 = if (self.capability_p) 0xe0 else if (self.version == .container_fonts) (if (self.inline_styles) @as(u8, 0xf0) else 0xf8) else 0xfe;
            if (font_fields & unknown_mask != 0) return error.InvalidPresentation;
            if (font_fields & 1 != 0) {
                const n: f32 = @bitCast(try self.readU32());
                if (!std.math.isFinite(n) or n < 0) return error.InvalidPresentation;
                if (hasFontScaleBasisFields(self.version)) result.font_scale_basis = try self.enumValue(types.FontScaleBasis);
                if (result.font_scale_basis == .css_px and self.version != .container_fonts) return error.InvalidPresentation;
                result.font_scale = if (n == 1 and result.font_scale_basis == .context) null else n;
            }
            if (font_fields & 2 != 0) result.font_features = try self.enumValue(types.FontFeaturePolicy);
            if (font_fields & 4 != 0) result.link_paint = try self.linkPaint();
            if (font_fields & 8 != 0) result.inline_style = try self.inlineTextStyle();
            if (font_fields & 16 != 0) result.font_family = try self.containerFontFamily();
        }
        if (hasReferenceBlockFields(self.version)) result.image = try self.inlineImage();
        if ((self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))))) and try self.presence()) {
            if (result.kind != .link) return error.InvalidPresentation;
            result.target_fragment = try self.string();
        }
        if ((self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))) and try self.presence()) result.tooltip = try self.string();
        if (result.image != null and (result.text.len != 0 or result.trail.len != 0 or
            !types.validInlineImageAction(result.kind, result.target))) return error.InvalidPresentation;
        if (!types.validSpanInlineStyle(result) or !types.validSpanLinkPaint(result)) return error.InvalidPresentation;
        return result;
    }
    fn mapString(self: *Reader) ![]const u8 {
        const len: usize = try self.readU32();
        if (len > max_string_bytes or len > self.remaining_map_string_bytes) return error.InvalidPresentation;
        const value = try self.take(len);
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidPresentation;
        self.remaining_map_string_bytes -= len;
        if (self.metrics) |metrics| metrics.largest_string_bytes = @max(metrics.largest_string_bytes, len);
        return value;
    }
    fn mapAction(self: *Reader) !types.MapAction {
        if (self.remaining() < 10) return error.InvalidPresentation;
        const value: types.MapAction = .{
            .kind = try self.enumValue(types.MapActionKind),
            .target = try self.mapString(),
            .target_fragment = if (try self.presence()) try self.mapString() else null,
            .label = try self.mapString(),
        };
        if (!types.validMapAction(value)) return error.InvalidPresentation;
        return value;
    }
    fn chargeMapDefault(self: *Reader) !void {
        if (self.remaining_items == 0) return error.InvalidPresentation;
        self.remaining_items -= 1;
        if (self.metrics) |metrics| metrics.total_items = std.math.add(u64, metrics.total_items, 1) catch return error.InvalidPresentation;
    }
    fn mapCoordinateCount(self: *Reader, shape: types.MapShape) !usize {
        const len = try self.count(8);
        if (!types.validMapCoordinateCount(shape, len)) return error.InvalidPresentation;
        const bytes = std.math.mul(usize, len, 8) catch return error.InvalidPresentation;
        const minimum = std.math.add(usize, bytes, 10) catch return error.InvalidPresentation;
        if (minimum > self.remaining()) return error.InvalidPresentation;
        return len;
    }
    // Allocation-free first pass validates the whole occurrence against the
    // entry's copied item/string budgets before either map array can allocate.
    // The real reader later charges once; probe metrics never mutate observers.
    fn scanImageMap(self: *Reader) !void {
        if (self.remaining() < 6) return error.InvalidPresentation;
        _ = try self.enumValue(types.MapDescription);
        const len = try self.count(39);
        for (0..len) |_| {
            const shape = try self.enumValue(types.MapShape);
            const coordinates = try self.mapCoordinateCount(shape);
            for (0..coordinates) |_| {
                const value: f64 = @bitCast(try self.readU64());
                if (!std.math.isFinite(value)) return error.InvalidPresentation;
            }
            _ = try self.mapAction();
        }
        if (try self.presence()) {
            try self.chargeMapDefault();
            _ = try self.mapAction();
        }
    }
    fn imageMap(self: *Reader) !types.ImageMap {
        var probe = self.*;
        probe.metrics = null;
        try probe.scanImageMap();
        const description = try self.enumValue(types.MapDescription);
        const len = try self.count(39);
        const regions = try self.a.alloc(types.MapRegion, len);
        for (regions) |*region| {
            const shape = try self.enumValue(types.MapShape);
            const coordinate_count = try self.mapCoordinateCount(shape);
            const coordinates = try self.a.alloc(f64, coordinate_count);
            for (coordinates) |*coordinate| {
                coordinate.* = @bitCast(try self.readU64());
                if (!std.math.isFinite(coordinate.*)) return error.InvalidPresentation;
            }
            region.* = .{ .shape = shape, .coordinates = coordinates, .action = try self.mapAction() };
        }
        const fallback: ?types.MapAction = if (try self.presence()) fallback: {
            try self.chargeMapDefault();
            break :fallback try self.mapAction();
        } else null;
        return .{ .description = description, .regions = regions, .default_action = fallback };
    }
    fn inlineImage(self: *Reader) !?types.InlineImage {
        const tag = try self.byte();
        if (tag == 0) return null;
        if (tag != 1 and !(tag == 2 and self.version == .container_fonts) and
            !(tag == 3 and self.version == .container_fonts and self.capability_q)) return error.InvalidPresentation;
        const file = try self.string();
        const flags = try self.byte();
        const reserved_mask: u8 = if (hasKFields(self.version)) 0x00 else if (self.version == .image_maps) 0xc0 else if (self.version == .image_border or (self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))))))) 0xe0 else 0xf0;
        if (flags & reserved_mask != 0) return error.InvalidPresentation;
        const value: types.InlineImage = .{
            .file = file,
            .width_px = if (flags & 1 != 0) try self.readU32() else null,
            .height_px = if (flags & 2 != 0) try self.readU32() else null,
            .alt = if (flags & 4 != 0) try self.string() else null,
            .tooltip = if (flags & 8 != 0) try self.string() else null,
            .border = flags & 16 != 0,
            .map = if (flags & 32 != 0) try self.imageMap() else null,
            .dark_mode_filter = if (flags & 64 != 0) try self.enumValue(types.ImageDarkModeFilter) else null,
            .svg_language = if (flags & 128 != 0) try self.string() else null,
            .static_poster = if (tag == 2) .{
                .policy = try self.enumValue(types.StaticPosterPolicy),
                .label = try self.string(),
                .file_sha1 = try self.string(),
                .file_timestamp = try self.string(),
            } else null,
            .vertical_align = if (tag == 3) try self.enumValue(types.InlineImageVerticalAlign) else null,
        };
        if (!types.validInlineImage(value)) return error.InvalidPresentation;
        return value;
    }
    fn spans(self: *Reader) ![]const types.Span {
        const len = try self.count(if ((self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version))))) 37 else if ((self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version))))))) 36 else if (hasReferenceBlockFields(self.version)) 35 else if (hasFontScaleFields(self.version)) 34 else if (hasSpanBackgroundFields(self.version)) 33 else if (hasRgb(self.version)) 32 else if (self.version == .explained) 31 else 27);
        const out = try self.a.alloc(types.Span, len);
        for (out) |*value| value.* = try self.span();
        return out;
    }
    fn feature(self: *Reader) !?types.Feature {
        if (!try self.presence()) return null;
        return .{
            .kind = try self.string(),
            .language = try self.string(),
            .data = try self.string(),
            .tail_kind = try self.string(),
            .tail = try self.string(),
        };
    }
    fn styleLength(self: *Reader) !types.StyleLength {
        const value: types.StyleLength = .{ .unit = try self.enumValue(types.StyleLengthUnit), .value = @bitCast(try self.readU32()) };
        if (!types.validStyleLength(value)) return error.InvalidPresentation;
        return value;
    }
    fn styleEdges(self: *Reader) !types.StyleEdges {
        return .{ .top = try self.styleLength(), .right = try self.styleLength(), .bottom = try self.styleLength(), .left = try self.styleLength() };
    }
    fn styleBorderEdge(self: *Reader) !types.StyleBorderEdge {
        if (self.version != .container_fonts) return error.InvalidPresentation;
        const value: types.StyleBorderEdge = switch (try self.byte()) {
            0 => .none, 1 => .hidden,
            2 => .{ .solid = .{ .width = try self.styleLength(), .color = try self.string() } },
            3 => .{ .dotted = .{ .width = try self.styleLength(), .color = try self.string() } },
            else => return error.InvalidPresentation,
        };
        if (!types.validBorderEdge(value)) return error.InvalidPresentation;
        return value;
    }
    fn styleBorder(self: *Reader) !types.StyleBorder {
        return switch (try self.byte()) {
            0 => .none,
            1 => solid: {
                const value: types.StyleBorder = .{ .solid = .{ .width = try self.styleLength(), .color = try self.string() } };
                if (!types.validBorder(value)) return error.InvalidPresentation;
                break :solid value;
            },
            2 => edges: {
                if (self.version != .container_fonts) return error.InvalidPresentation;
                break :edges .{ .edges = .{ .top = try self.styleBorderEdge(), .right = try self.styleBorderEdge(), .bottom = try self.styleBorderEdge(), .left = try self.styleBorderEdge() } };
            },
            else => error.InvalidPresentation,
        };
    }
    fn figureColor(self: *Reader) !types.FigureColor {
        const kind = try self.enumValue(types.FigureColorKind);
        const value: types.FigureColor = .{ .kind = kind, .value = if (kind == .rgb) try self.string() else null };
        if (!types.validFigureColor(value)) return error.InvalidPresentation;
        return value;
    }
    fn figureBorder(self: *Reader) !types.FigureBorder {
        const kind = try self.enumValue(types.FigureBorderKind);
        const value: types.FigureBorder = .{ .kind = kind, .width = if (kind == .solid) try self.styleLength() else null,
            .color = if (kind == .solid) try self.figureColor() else null };
        if (!types.validFigureBorder(value)) return error.InvalidPresentation;
        return value;
    }
    fn figureBorderEdge(self: *Reader) !types.FigureBorderEdge {
        const tag = try self.byte();
        return switch (tag) {
            0 => .none, 1 => .hidden,
            2, 3 => line: {
                const width = try self.styleLength(); const color = try self.figureColor();
                const value: types.FigureBorderEdge = if (tag == 2) .{ .solid = .{ .width = width, .color = color } }
                    else .{ .dotted = .{ .width = width, .color = color } };
                if (!types.validFigureBorderEdge(value)) return error.InvalidPresentation;
                break :line value;
            },
            else => error.InvalidPresentation,
        };
    }
    fn figureCaptionBefore(self: *Reader) !?types.ContainerStyle {
        if (!try self.presence()) return null;
        const value = try self.containerStyle();
        if (!types.validFigureCaptionBefore(value)) return error.InvalidPresentation;
        return value;
    }
    fn figureFocusOutline(self: *Reader) !?types.FigureFocusOutline {
        if (!try self.presence()) return null;
        const outline: types.FigureFocusOutline = .{ .width = try self.styleLength(), .color = try self.figureColor(),
            .radius = try self.styleLength(), .offset = try self.containerMarginLength() };
        if (!types.validFigureFocusOutline(outline)) return error.InvalidPresentation;
        return outline;
    }
    fn figureLinkPaint(self: *Reader) !?types.FigureLinkPaint {
        if (!try self.presence()) return null;
        if (self.version != .container_fonts or self.remaining() < 68) return error.InvalidPresentation;
        var paint: types.FigureLinkPaint = undefined;
        inline for (.{ "normal", "hover", "active", "visited", "visited_hover", "visited_active" }) |name|
            @field(paint, name) = .{ .foreground = try self.string(), .underline = false };
        const flags = try self.byte();
        if (flags & 0x80 != 0) return error.InvalidPresentation;
        inline for (.{ "normal", "hover", "active", "visited", "visited_hover", "visited_active" }, 0..) |name, state_index|
            @field(paint, name).underline = flags & (@as(u8, 1) << state_index) != 0;
        paint.underline_on_focus = flags & 0x40 != 0;
        paint.focus_outline = try self.figureFocusOutline();
        if (!types.validFigureLinkPaint(paint)) return error.InvalidPresentation;
        return paint;
    }
    fn linkPaint(self: *Reader) !types.LinkPaint {
        const prefix = (try self.figureLinkPaint()) orelse return error.InvalidPresentation;
        const hover_active = try self.string(); const visited_hover_active = try self.string();
        const flags = try self.byte(); if (flags & 0xfc != 0) return error.InvalidPresentation;
        const paint = types.LinkPaint.fromSixStatePrefix(prefix,
            .{ .foreground = hover_active, .underline = flags & 1 != 0 },
            .{ .foreground = visited_hover_active, .underline = flags & 2 != 0 });
        if (!types.validLinkPaint(paint)) return error.InvalidPresentation;
        return paint;
    }
    fn figureMediaLayout(self: *Reader) !types.FigureMediaLayout {
        if (self.version != .container_fonts) return error.InvalidPresentation;
        const font_scale: f32 = @bitCast(try self.readU32());
        const flags = try self.byte();
        if (flags & 0xf0 != 0) return error.InvalidPresentation;
        const strut: types.FigureMediaStrut = .{ .font_scale = font_scale,
            .bold = flags & 1 != 0, .italic = flags & 2 != 0, .code = flags & 4 != 0,
            .language = try self.string(), .direction = try self.enumValue(types.BidiResolvedDirection),
            .font_features = if (flags & 0x08 != 0) try self.enumValue(types.FontFeaturePolicy) else null };
        const align_value = try self.enumValue(types.InlineBoxVerticalAlign);
        const max_width: ?types.AvailableWidthLimit = if (try self.presence())
            .{ .percent = @as(f32, @bitCast(try self.readU32())), .subtract = try self.styleLength() } else null;
        const positioning: ?types.ContainerPositioning = if (try self.presence()) try self.enumValue(types.ContainerPositioning) else null;
        const after: ?types.FigureMediaAfter = if (try self.presence()) .{
            .width = try self.styleLength(), .height = try self.styleLength(),
            .side = try self.enumValue(types.TableFloatSide), .inset = try self.styleLength(),
            .bottom = try self.containerMarginLength(),
            .paint = if (try self.presence()) .{ .graphic = try self.enumValue(types.FigureMediaGraphic), .invert = try self.presence() } else null,
        } else null;
        const focus_outline = try self.figureFocusOutline();
        const value: types.FigureMediaLayout = .{ .strut = strut, .vertical_align = align_value,
            .max_width = max_width, .positioning = positioning, .after = after, .focus_outline = focus_outline };
        if (!types.validFigureMediaLayout(value)) return error.InvalidPresentation;
        return value;
    }
    fn tableCaptionLayout(self: *Reader) !types.TableCaptionLayout {
        if (self.version != .container_fonts) return error.InvalidPresentation;
        const collapse = try self.enumValue(types.BorderCollapse);
        var value: types.TableCaptionLayout = .{ .collapse = collapse, .wrapper = try self.containerStyle(),
            .table_border = .{ .top = try self.figureBorderEdge(), .right = try self.figureBorderEdge(), .bottom = try self.figureBorderEdge(), .left = try self.figureBorderEdge() },
            .caption_border = .{ .top = try self.figureBorderEdge(), .right = try self.figureBorderEdge(), .bottom = try self.figureBorderEdge(), .left = try self.figureBorderEdge() },
            .media = try self.figureMediaLayout(), .caption_before = try self.figureCaptionBefore() };
        const len = try self.count(24);
        if (len > types.max_figure_viewport_states) return error.InvalidPresentation;
        const states = try self.a.alloc(types.FigureViewportState, len);
        for (states) |*state| state.* = .{ .max_width_px = try self.readU32(), .wrapper = try self.containerStyle(),
            .media = try self.figureMediaLayout(), .caption_before = try self.figureCaptionBefore() };
        value.viewport_states = states;
        value.missing_link_paint = try self.figureLinkPaint(); value.caption_link_paint = try self.figureLinkPaint();
        if (!types.validTableCaptionLayout(value)) return error.InvalidPresentation;
        return value;
    }
    fn figureBlockMediaLayout(self: *Reader) !types.FigureBlockMediaLayout {
        if (self.version != .container_fonts) return error.InvalidPresentation;
        var value: types.FigureBlockMediaLayout = .{ .wrapper = try self.containerStyle(), .media = try self.figureMediaLayout(),
            .preferred_width_px = try self.readU32(), .natural_width = try self.readU32(), .natural_height = try self.readU32(),
            .rendition_1x = .{ .url = try self.string(), .sha256 = try self.string() },
            .rendition_2x = .{ .url = try self.string(), .sha256 = try self.string() } };
        const state_count = try self.count(24);
        if (state_count > types.max_figure_viewport_states) return error.InvalidPresentation;
        const states = try self.a.alloc(types.FigureBlockMediaState, state_count);
        for (states) |*state| state.* = .{ .max_width_px = try self.readU32(), .wrapper = try self.containerStyle(), .media = try self.figureMediaLayout() };
        value.viewport_states = states;
        if (!types.validFigureBlockMediaLayout(value)) return error.InvalidPresentation;
        return value;
    }
    fn chargeFigureContent(self: *Reader) !void {
        if (self.remaining_items == 0) return error.InvalidPresentation;
        self.remaining_items -= 1;
        if (self.metrics) |metrics| metrics.total_items = std.math.add(u64, metrics.total_items, 1) catch return error.InvalidPresentation;
    }
    fn figure(self: *Reader) error{OutOfMemory, InvalidPresentation}!?types.Figure {
        const tag = try self.byte();
        if (tag == 0) return null;
        const table_caption = tag == 5 or tag == 6;
        const block_media = tag == 7;
        if (tag != 1 and !(tag == 2 and hasKFields(self.version)) and
            !((table_caption or block_media) and self.version == .container_fonts)) return error.InvalidPresentation;
        const is_missing = tag == 2 or tag == 6;
        // The legacy image minimum remains unchanged. Missing has no image
        // payload/policy; individual bounded readers check its variable tail.
        if (self.remaining() < (if (!is_missing) @as(usize, 123) else 78)) return error.InvalidPresentation;
        const geometry = .{
            .format = try self.enumValue(types.FigureFormat), .placement = try self.enumValue(types.FigurePlacement), .clear = try self.enumValue(types.FigureClear),
            .margins = try self.styleEdges(), .image_insets = try self.styleEdges(), .caption_padding = try self.styleEdges(),
            .caption_font_scale = @as(f32, @bitCast(try self.readU32())), .caption_line_height = try self.styleLength(),
            .frame_background = try self.figureColor(), .frame_border = try self.figureBorder(),
            .image_background = try self.figureColor(), .image_border = try self.figureBorder(),
            .caption_foreground = try self.figureColor(), .caption_background = try self.figureColor(),
        };
        if (!types.validFigureGeometry(geometry)) return error.InvalidPresentation;
        try self.chargeFigureContent();
        const content_span = try self.span();
        const missing: ?types.FigureContent.Missing = if (is_missing) .{
            .label = content_span, .width = try self.styleLength(), .line_height = try self.styleLength(),
            .link_paint = if (try self.presence()) try self.enumValue(types.MissingLinkPaint) else null,
        } else null;
        const caption = try self.spans();
        const caption_blocks = try self.captionBlocks(caption.len);
        const caption_text_align: ?types.CellTextAlign = if (try self.presence()) try self.enumValue(types.CellTextAlign) else null;
        const content: types.FigureContent = if (missing) |present| .{ .missing = present }
            else .{ .image = .{ .span = content_span, .sizing = try self.enumValue(types.FigureSizingPolicy) } };
        const value: types.Figure = .{
            .content = content, .caption = caption, .caption_blocks = caption_blocks, .caption_text_align = caption_text_align,
            .frame_min_width = if (try self.presence()) try self.styleLength() else null,
            .table_caption_layout = if (table_caption) try self.tableCaptionLayout() else null,
            .block_media_layout = if (block_media) try self.figureBlockMediaLayout() else null,
            .format = geometry.format, .placement = geometry.placement, .clear = geometry.clear,
            .margins = geometry.margins, .image_insets = geometry.image_insets, .caption_padding = geometry.caption_padding,
            .caption_font_scale = geometry.caption_font_scale, .caption_line_height = geometry.caption_line_height,
            .frame_background = geometry.frame_background, .frame_border = geometry.frame_border,
            .image_background = geometry.image_background, .image_border = geometry.image_border,
            .caption_foreground = geometry.caption_foreground, .caption_background = geometry.caption_background,
        };
        if (!types.validFigure(value)) return error.InvalidPresentation;
        return value;
    }
    fn captionBlocks(self: *Reader, flat_len: usize) error{OutOfMemory, InvalidPresentation}!?[]const types.Block {
        if (!try self.presence()) return null;
        if (flat_len != 0 or self.content_depth >= types.max_content_depth) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        return try self.blocks();
    }
    fn bidiScope(self: *Reader) error{OutOfMemory, InvalidPresentation}!types.BidiScope {
        if (self.content_depth >= types.max_content_depth or self.remaining() < 8) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        const mode = try self.enumValue(types.BidiMode);
        const authored: ?types.BidiDirectionInput = switch (try self.byte()) { 0 => null, 1 => .ltr, 2 => .rtl, 3 => .auto, else => return error.InvalidPresentation };
        const resolved = try self.enumValue(types.BidiResolvedDirection);
        const language: ?[]const u8 = if (try self.presence()) try self.string() else null;
        const header = .{ .mode = mode, .authored_direction = authored, .resolved_direction = resolved, .language = language };
        if (!types.validBidiScopeHeader(header)) return error.InvalidPresentation;
        return .{ .mode = mode, .authored_direction = authored, .resolved_direction = resolved, .language = language, .parts = try self.flowParts() };
    }
    fn flowParts(self: *Reader) error{OutOfMemory, InvalidPresentation}![]const types.FlowPart {
        const len = try self.count(5);
        const out = try self.a.alloc(types.FlowPart, len);
        for (out) |*part| {
            const kind = try self.enumValue(types.FlowPartKind);
            part.* = switch (kind) {
                .@"inline" => .{ .kind = kind, .spans = try self.spans() },
                .figure => .{ .kind = kind, .figure = (try self.figure()) orelse return error.InvalidPresentation },
                .scope => .{ .kind = kind, .scope = try self.bidiScope() },
            };
        }
        return out;
    }
    fn flow(self: *Reader) error{OutOfMemory, InvalidPresentation}!?[]const types.FlowPart {
        if (!try self.presence()) return null;
        if (self.content_depth >= types.max_content_depth) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        return try self.flowParts();
    }
    fn blockStyle(self: *Reader) !?types.BlockStyle {
        if (!try self.presence()) return null;
        const flags = try self.byte();
        if (flags == 0 or flags & 0xfc != 0) return error.InvalidPresentation;
        const value: types.BlockStyle = .{
            .margins = if (flags & 1 != 0) try self.styleEdges() else null,
            .padding = if (flags & 2 != 0) try self.styleEdges() else null,
        };
        if (!types.validBlockStyle(value)) return error.InvalidPresentation;
        return value;
    }
    fn cellLineHeight(self: *Reader) !types.CellLineHeight {
        if (self.version != .container_fonts) return error.InvalidPresentation;
        const marker = try self.byte();
        if (marker > 2 or (marker == 2 and !self.capability_p)) return error.InvalidPresentation;
        var strut: ?types.CellTextStrut = if (marker != 0) .{
            .font_scale = @bitCast(try self.readU32()), .font_scale_basis = try self.enumValue(types.FontScaleBasis), .owner_font = null,
        } else null;
        if (marker == 2) {
            // Reject even a contextual identity size before the shared decoder
            // canonicalizes it: there must be exactly one encoded size.
            if (self.pos >= self.bytes.len or self.bytes[self.pos] & 1 != 0) return error.InvalidPresentation;
            var font = try self.inlineFontSnapshot();
            if (font.font_scale != null or font.font_scale_basis != .context) return error.InvalidPresentation;
            font.font_scale = strut.?.font_scale; font.font_scale_basis = strut.?.font_scale_basis;
            strut.?.owner_font = font;
        }
        const height: types.CellLineHeightValue = switch (try self.byte()) {
            0 => .normal,
            1 => .{ .multiplier = @bitCast(try self.readU32()) },
            2 => .{ .length = .{ .value = @bitCast(try self.readU32()), .font_scale_basis = try self.enumValue(types.FontScaleBasis) } },
            else => return error.InvalidPresentation,
        };
        const value: types.CellLineHeight = .{ .strut = strut, .height = height };
        if (!types.validCellLineHeight(value)) return error.InvalidPresentation;
        return value;
    }
    fn cellStyle(self: *Reader) !?types.CellStyle {
        if (!try self.presence()) return null;
        const flags = try self.byte();
        const allowed: u8 = if (self.version == .container_fonts) 0xef else 0x07;
        if (flags == 0 or flags & ~allowed != 0) return error.InvalidPresentation;
        const value: types.CellStyle = .{
            .border = if (flags & 1 != 0) try self.styleBorder() else null,
            .padding = if (flags & 2 != 0) try self.styleEdges() else null,
            .text_align = if (flags & 4 != 0) try self.enumValue(types.CellTextAlign) else null,
            .width = if (flags & cell_width_flag != 0) try self.styleWidth() else null,
            .min_width = if (flags & cell_min_width_flag != 0) try self.styleLength() else null,
            .vertical_align = if (flags & cell_vertical_align_flag != 0) try self.enumValue(types.CellVerticalAlign) else null,
            .line_height = if (flags & cell_line_height_flag != 0) try self.cellLineHeight() else null,
        };
        if (!types.validCellStyle(value)) return error.InvalidPresentation;
        return value;
    }
    fn styleWidth(self: *Reader) !types.StyleWidth {
        const value: types.StyleWidth = .{ .unit = try self.enumValue(types.StyleWidthUnit), .value = @bitCast(try self.readU32()) };
        if (!types.validStyleWidth(value)) return error.InvalidPresentation; return value;
    }
    fn tableStyle(self: *Reader) !?types.TableStyle {
        if (!try self.presence()) return null;
        const flags = try self.byte();
        const inline_flags = if (hasKFields(self.version)) try self.byte() else 0;
        if (inline_flags & (if (self.capability_q) @as(u8, 0xc0) else if (self.version == .container_fonts) @as(u8, 0xe0) else @as(u8, 0xf8)) != 0) return error.InvalidPresentation;
        if ((inline_flags & 8 != 0) != (inline_flags & 16 != 0) and
            !(self.capability_q and inline_flags & 0x38 == 0x30)) return error.InvalidPresentation;
        const reserved_mask: u8 = if ((self.version == .image_maps or hasKFields(self.version))) 0 else if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))))))) 0xe0 else 0xf0;
        if ((flags == 0 and inline_flags == 0) or flags & reserved_mask != 0) return error.InvalidPresentation;
        const value: types.TableStyle = .{
            .background = if (flags & 1 != 0) try self.string() else null,
            .border = if (flags & 2 != 0) try self.styleBorder() else null,
            .collapse = if (flags & 4 != 0) try self.enumValue(types.BorderCollapse) else null,
            .margins = if (flags & 8 != 0) try self.styleEdges() else null,
            .float_side = if (flags & 16 != 0) try self.enumValue(types.TableFloatSide) else null,
            .width = if (flags & 32 != 0) try self.styleWidth() else null,
            .padding = if (flags & 64 != 0) try self.styleEdges() else null,
            .clear = if (flags & 128 != 0) try self.enumValue(types.FigureClear) else null,
            .display = if (inline_flags & 1 != 0) try self.enumValue(types.TableDisplay) else null,
            .vertical_align = if (inline_flags & 2 != 0) try self.enumValue(types.InlineBoxVerticalAlign) else null,
            .line_height = if (inline_flags & 4 != 0) .{
                .value = @bitCast(try self.readU32()),
                .font_scale_basis = try self.enumValue(types.FontScaleBasis),
            } else null,
            .margin_values = if (inline_flags & 8 != 0) try self.containerMargins() else null,
            .containing_direction = if (inline_flags & 16 != 0) try self.enumValue(types.TableContainingDirection) else null,
            .corner_radii = if (inline_flags & 32 != 0) .{
                .top_left = try self.styleLength(), .top_right = try self.styleLength(),
                .bottom_right = try self.styleLength(), .bottom_left = try self.styleLength(),
            } else null,
        };
        if (value.vertical_align) |alignment| if (alignment == .top and self.version != .container_fonts) return error.InvalidPresentation;
        if (!types.validTableStyle(value)) return error.InvalidPresentation;
        return value;
    }
    fn cell(self: *Reader) error{ OutOfMemory, InvalidPresentation }!types.Cell {
        var value: types.Cell = .{
            .header = try self.presence(),
            .colspan = try self.readU16(),
            .rowspan = try self.readU16(),
            .background = if (hasRgb(self.version) and try self.presence()) background: {
                const value = try self.string();
                if (!types.isCanonicalRgb(value)) return error.InvalidPresentation;
                break :background value;
            } else null,
            .spans = try self.spans(),
        };
        if (hasNestedFields(self.version)) value.nested_table = try self.table();
        if (value.nested_table != null and value.spans.len != 0) return error.InvalidPresentation;
        if (hasCellBlockFields(self.version) and try self.presence()) {
            if (value.spans.len != 0 or value.nested_table != null) return error.InvalidPresentation;
            value.blocks = try self.blocks();
        }
        if (hasReferenceBlockFields(self.version)) value.style = try self.cellStyle();
        return value;
    }
    fn row(self: *Reader) !types.Row {
        const len = try self.count(if (hasReferenceBlockFields(self.version)) 13 else if (hasCellBlockFields(self.version)) 12 else if (hasNestedFields(self.version)) 11 else if (hasRgb(self.version)) 10 else 9);
        const out = try self.a.alloc(types.Cell, len);
        for (out) |*cell_value| cell_value.* = try self.cell();
        return .{ .cells = out };
    }
    fn tableGeometry(self: *Reader) !?types.TableGeometry {
        const flags = try self.byte();
        if (flags & 0xf0 != 0) return error.InvalidPresentation;
        if (flags == 0) return null;
        const value: types.TableGeometry = .{
            .border = if (flags & 1 != 0) try self.readU16() else null,
            .cell_spacing = if (flags & 2 != 0) try self.readU16() else null,
            .cell_padding = if (flags & 4 != 0) try self.readU16() else null,
            .width = if (flags & 8 != 0) .{ .unit = try self.enumValue(types.TableWidthUnit), .value = try self.readU32() } else null,
        };
        if (!types.validTableGeometry(value)) return error.InvalidPresentation;
        return value;
    }
    fn tableBlockViewport(self: *Reader) error{ OutOfMemory, InvalidPresentation }!*const types.TableBlockViewport {
        return self.tableBlockViewportIn(false);
    }
    fn tableBlockViewportIn(self: *Reader, paired: bool) error{ OutOfMemory, InvalidPresentation }!*const types.TableBlockViewport {
        return self.tableBlockViewportMode(paired, false);
    }
    fn tableBlockViewportMode(self: *Reader, paired: bool, intrinsic: bool) error{ OutOfMemory, InvalidPresentation }!*const types.TableBlockViewport {
        if (intrinsic and (!self.capability_r or paired)) return error.InvalidPresentation;
        if (self.version != .container_fonts or (paired and !self.capability_p)) return error.InvalidPresentation;
        const value = try self.a.create(types.TableBlockViewport);
        value.* = .{ .max_viewport_width_px = try self.readU32(),
            .box_style = (try self.tableStyle()) orelse return error.InvalidPresentation,
            .box_sizing = try self.enumValue(types.ContainerBoxSizing), .max_width = try self.styleWidth(),
            .grid_style = (try self.tableStyle()) orelse return error.InvalidPresentation,
            .grid_direction = try self.enumValue(types.TableContainingDirection), .language = try self.string() };
        if (intrinsic) value.intrinsic_containing_direction = try self.enumValue(types.TableContainingDirection);
        if (intrinsic or paired or (self.capability_q and types.tableCornerBlockViewportShape(value.*))) {
            const mode = try self.enumValue(types.TableScrollFocusMode);
            const present = try self.byte(); if (present > 1) return error.InvalidPresentation;
            value.focus_paint = .{ .mode = mode, .color = if (present == 1) try self.figureColor() else null };
        }
        if (!(if (paired) types.validTableScrollViewport(value.*) else types.validTableBlockViewport(value.*) or (self.capability_q and types.validTableCornerBlockViewport(value.*)) or (self.capability_r and types.validTableIntrinsicViewport(value.*)))) return error.InvalidPresentation;
        return value;
    }
    fn table(self: *Reader) error{ OutOfMemory, InvalidPresentation }!?types.Table {
        const flags = try self.byte();
        if (flags == 0) return null;
        if (flags != 1 and !(self.version == .container_fonts and (flags == 3 or flags == 5 or (self.capability_p and (flags == 7 or flags == 13)) or (self.capability_r and flags == 19)))) return error.InvalidPresentation;
        if (self.table_depth >= types.max_table_depth) return error.InvalidPresentation;
        self.table_depth += 1;
        defer self.table_depth -= 1;
        const geometry = if (hasNestedFields(self.version)) try self.tableGeometry() else null;
        const caption = try self.spans();
        const len = try self.count(4);
        const rows = try self.a.alloc(types.Row, len);
        for (rows) |*row_value| row_value.* = try self.row();
        const value: types.Table = .{ .caption = caption, .rows = rows, .geometry = geometry, .style = if (hasReferenceBlockFields(self.version)) try self.tableStyle() else null, .caption_blocks = if ((self.version == .image_maps or hasKFields(self.version))) try self.captionBlocks(caption.len) else null,
            .block_viewport = if (flags == 3 or flags == 7 or flags == 19) try self.tableBlockViewportMode(flags == 7, flags == 19) else null,
            .float_viewport = if (flags == 5 or flags == 7 or flags == 13) .{ .max_viewport_width_px = try self.readU32(),
            .containing_direction = try self.enumValue(types.TableContainingDirection),
            .grid_direction = try self.enumValue(types.TableContainingDirection), .language = try self.string(),
            .narrow_clear = if (flags == 13) try self.enumValue(types.FigureClear) else null } else null };
        if (!types.validTableViewportHeaders(value.geometry, value.style, value.block_viewport, value.float_viewport)) return error.InvalidPresentation;
        if (value.caption_blocks != null and value.caption.len != 0) return error.InvalidPresentation;
        var has_cells = false;
        for (value.rows) |row_value| if (row_value.cells.len != 0) { has_cells = true; break; };
        if (!types.validTableFloatViewportContent(value.float_viewport, value.caption.len, value.caption_blocks != null, has_cells)) return error.InvalidPresentation;
        if (!types.validInlineTableContent(value.style, value.caption.len, value.caption_blocks != null, has_cells)) return error.InvalidPresentation;
        if (types.tableStyleIsInline(value.style) and (self.table_depth != 1 or self.content_depth != 0 or
            self.in_reference or !(if (self.version == .container_fonts) types.inlineTableShapeSupportedM(value) else types.inlineTableShapeSupported(value)))) return error.InvalidPresentation;
        if (self.table_depth == 1) if (self.metrics) |metrics| metrics.contentTableTree(value, 1, self.content_depth);
        return value;
    }
    fn containerWidth(self: *Reader) !types.ContainerWidth {
        return switch (try self.byte()) { 0 => .auto, 1 => .{ .length = try self.styleWidth() }, 2 => .fit_content, else => error.InvalidPresentation };
    }
    fn containerMaxWidth(self: *Reader) !types.ContainerMaxWidth {
        return switch (try self.byte()) { 0 => .none, 1 => .{ .length = try self.styleWidth() }, else => error.InvalidPresentation };
    }
    fn containerColor(self: *Reader) !types.ContainerColor {
        const value: types.ContainerColor = switch (try self.byte()) {
            0 => .transparent,
            1 => .{ .rgb = try self.string() },
            2 => .{ .light_dark = .{ .light = try self.string(), .dark = try self.string() } },
            else => return error.InvalidPresentation,
        };
        if (!types.validContainerColor(value)) return error.InvalidPresentation;
        return value;
    }
    fn containerBorderEdge(self: *Reader) !types.ContainerBorderEdge {
        if (self.version != .container_fonts) return error.InvalidPresentation;
        const value: types.ContainerBorderEdge = switch (try self.byte()) {
            0 => .none, 1 => .hidden,
            2 => .{ .solid = .{ .width = try self.styleLength(), .color = try self.containerColor() } },
            3 => .{ .dotted = .{ .width = try self.styleLength(), .color = try self.containerColor() } },
            else => return error.InvalidPresentation,
        };
        if (!types.validContainerBorderEdge(value)) return error.InvalidPresentation;
        return value;
    }
    fn containerBorder(self: *Reader) !types.ContainerBorder {
        return switch (try self.byte()) { 0 => .none, 1 => .{ .solid = .{ .width = try self.styleLength(), .color = try self.containerColor() } }, 2 => edges: {
            if (self.version != .container_fonts) return error.InvalidPresentation;
            break :edges .{ .edges = .{ .top = try self.containerBorderEdge(), .right = try self.containerBorderEdge(), .bottom = try self.containerBorderEdge(), .left = try self.containerBorderEdge() } };
        }, else => error.InvalidPresentation };
    }
    fn containerLineHeight(self: *Reader) !types.ContainerLineHeight {
        const value: types.ContainerLineHeight = switch (try self.byte()) {
            0 => .normal,
            1 => .{ .multiplier = @bitCast(try self.readU32()) },
            2 => .{ .length = try self.styleLength() },
            else => return error.InvalidPresentation,
        };
        if (!types.validContainerLineHeight(value)) return error.InvalidPresentation;
        return value;
    }
    fn containerMarginLength(self: *Reader) !types.StyleLength {
        if (self.version != .container_fonts) return self.styleLength();
        const value: types.StyleLength = .{ .unit = try self.enumValue(types.StyleLengthUnit), .value = @bitCast(try self.readU32()) };
        if (!types.validContainerMarginLength(value)) return error.InvalidPresentation;
        return value;
    }
    fn containerMarginEdges(self: *Reader) !types.StyleEdges {
        return .{ .top = try self.containerMarginLength(), .right = try self.containerMarginLength(),
            .bottom = try self.containerMarginLength(), .left = try self.containerMarginLength() };
    }
    fn containerMargin(self: *Reader) !types.ContainerMargin {
        if (!hasLFields(self.version)) return error.InvalidPresentation;
        return switch (try self.byte()) { 0 => .auto, 1 => .{ .length = try self.containerMarginLength() }, else => error.InvalidPresentation };
    }
    fn containerMargins(self: *Reader) !types.ContainerMargins {
        return .{ .top = try self.containerMargin(), .right = try self.containerMargin(), .bottom = try self.containerMargin(), .left = try self.containerMargin() };
    }
    fn containerScreenPrefix(self: *Reader, allow_following: bool) !struct { value: types.ContainerScreenMaxWidth, following: bool } {
        if (!hasLFields(self.version)) return error.InvalidPresentation;
        const limit = try self.readU32(); const flags = try self.byte();
        if (flags == 0 or (!allow_following and flags & 0x80 != 0)) return error.InvalidPresentation;
        const value: types.ContainerScreenMaxWidth = .{ .max_width_px = limit,
            .width = if (flags & 1 != 0) try self.containerWidth() else null,
            .max_width = if (flags & 2 != 0) try self.containerMaxWidth() else null,
            .box_sizing = if (flags & 4 != 0) try self.enumValue(types.ContainerBoxSizing) else null,
            .line_height = if (flags & 8 != 0) try self.containerLineHeight() else null,
            .float_side = if (flags & 16 != 0) try self.enumValue(types.ContainerFloatOverride) else null,
            .margins = if (flags & 32 != 0) try self.containerMargins() else null,
            .clear = if (flags & 64 != 0) try self.enumValue(types.FigureClear) else null };
        if (!types.validContainerScreenMaxWidth(value)) return error.InvalidPresentation;
        return .{ .value = value, .following = flags & 0x80 != 0 };
    }
    fn containerScreen(self: *Reader) !types.ContainerScreenMaxWidth {
        const prefix = try self.containerScreenPrefix(true);
        var value = prefix.value;
        if (prefix.following) {
            const len = try self.count(5);
            if (len == 0 or len >= types.max_container_screen_rules) return error.InvalidPresentation;
            const rules = try self.a.alloc(types.ContainerScreenMaxWidth, len);
            for (rules) |*rule| rule.* = (try self.containerScreenPrefix(false)).value;
            value.following_rules = rules;
        }
        if (!types.validContainerScreenMaxWidth(value)) return error.InvalidPresentation;
        return value;
    }
    fn containerFontFamily(self: *Reader) !types.ContainerFontFamily {
        const family: types.ContainerFontFamily = switch (try self.byte()) {
            0 => .sans_serif,
            1 => blk: {
                if (!self.capability_p) return error.InvalidPresentation;
                const name_count = try self.count(4);
                if (name_count > 16) return error.InvalidPresentation;
                const names = try self.a.alloc([]const u8, name_count);
                for (names) |*name| name.* = try self.string();
                break :blk .{ .stack = .{ .names = names, .fallback = try self.enumValue(types.GenericFontFamily) } };
            },
            else => return error.InvalidPresentation,
        };
        if (!types.validContainerFontFamily(family)) return error.InvalidPresentation;
        return family;
    }
    fn sectionHeadingStyles(self: *Reader, sections_value: []const types.Section) !void {
        if (!self.capability_p) return error.InvalidPresentation;
        const styled_count = try self.count(4);
        if (styled_count == 0 or styled_count > sections_value.len) return error.InvalidPresentation;
        var previous: ?usize = null;
        for (0..styled_count) |_| {
            const index_value = try self.index();
            if (index_value >= sections_value.len or (previous != null and index_value <= previous.?)) return error.InvalidPresentation;
            previous = index_value;
            const style: types.SectionHeadingStyle = .{ .box = try self.containerStyle(), .font = try self.inlineFontSnapshot(),
                .direction = try self.enumValue(types.BidiResolvedDirection) };
            if (!types.validSectionHeadingStyle(style) or !types.validSectionHeadingCompanion(sections_value[index_value])) return error.InvalidPresentation;
            @constCast(sections_value)[index_value].heading_style = style;
        }
    }
    fn containerStyle(self: *Reader) !types.ContainerStyle {
        if (!hasLFields(self.version)) return error.InvalidPresentation;
        const flags: u32 = if (self.version == .container_fonts) try self.readU32() else try self.readU16();
        if (flags & ~container_style_known_flags != 0) return error.InvalidPresentation;
        const value: types.ContainerStyle = .{
            .margins = if (flags & 1 != 0) try self.containerMarginEdges() else null,
            .padding = if (flags & 2 != 0) try self.styleEdges() else null,
            .width = if (flags & 4 != 0) try self.containerWidth() else null,
            .float_side = if (flags & 8 != 0) try self.enumValue(types.TableFloatSide) else null,
            .clear = if (flags & 16 != 0) try self.enumValue(types.FigureClear) else null,
            .max_width = if (flags & 32 != 0) try self.containerMaxWidth() else null,
            .box_sizing = if (flags & 64 != 0) try self.enumValue(types.ContainerBoxSizing) else null,
            .layout = if (flags & 128 != 0) try self.enumValue(types.ContainerLayout) else null,
            .align_items = if (flags & 256 != 0) try self.enumValue(types.ContainerAlignItems) else null,
            .flex_item = if (flags & 512 != 0) try self.enumValue(types.ContainerFlexItem) else null,
            .background = if (flags & 1024 != 0) try self.containerColor() else null,
            .border = if (flags & 2048 != 0) try self.containerBorder() else null,
            .line_height = if (flags & 4096 != 0) try self.containerLineHeight() else null,
            .text_align = if (flags & 8192 != 0) try self.enumValue(types.CellTextAlign) else null,
            .screen_max_width = if (flags & 16384 != 0) try self.containerScreen() else null,
            .overflow = if (flags & 32768 != 0) try self.enumValue(types.ContainerOverflow) else null,
            .owner_font_scale = if (flags & container_owner_font_flag != 0) @as(f32, @bitCast(try self.readU32())) else null,
            .height = if (flags & container_height_flag != 0) try self.styleLength() else null,
            .columns = if (flags & container_columns_flag != 0) .{ .count = try self.readU16(), .gap = try self.styleLength() } else null,
            .positioning = if (flags & container_positioning_flag != 0) try self.enumValue(types.ContainerPositioning) else null,
            .min_height = if (flags & container_min_height_flag != 0) try self.styleLength() else null,
            .margin_values = if (flags & container_margin_values_flag != 0) try self.containerMargins() else null,
            .font_family = if (flags & container_font_family_flag != 0) try self.containerFontFamily() else null,
        };
        if (!types.validContainerStyle(value)) return error.InvalidPresentation;
        return value;
    }
    fn container(self: *Reader) error{ OutOfMemory, InvalidPresentation }!types.Container {
        if (!hasLFields(self.version) or self.content_depth >= types.max_content_depth) return error.InvalidPresentation;
        self.content_depth += 1; defer self.content_depth -= 1;
        const value: types.Container = .{ .style = try self.containerStyle(), .blocks = try self.blocks() };
        if (!types.validContainerHeader(value)) return error.InvalidPresentation;
        if (self.version != .container_fonts and !types.legacyContainerMarginsSupported(value)) return error.InvalidPresentation;
        return value;
    }
    fn childPath(self: *Reader) ![]const usize {
        const len = try self.count(4);
        if (len > types.max_content_depth) return error.InvalidPresentation;
        const out = try self.a.alloc(usize, len); for (out) |*index_value| { index_value.* = try self.index(); }
        return out;
    }
    fn childPaths(self: *Reader, roots: []const usize) ![]const []const usize {
        const len = try self.count(4);
        if (len != 0 and len != roots.len) return error.InvalidPresentation;
        const out = try self.a.alloc([]const usize, len);
        var nested = false;
        for (out) |*path| { path.* = try self.childPath(); nested = nested or path.len != 0; }
        if (len != 0 and !nested) return error.InvalidPresentation;
        return out;
    }
    fn ruleStyle(self: *Reader) !types.RuleStyle { return self.ruleStyleIn(false); }
    fn ruleStyleIn(self: *Reader, clear: bool) !types.RuleStyle {
        if (!self.rule_styles or self.version != .container_fonts or (clear and !self.capability_r)) return error.InvalidPresentation;
        const value: types.RuleStyle = .{ .height = try self.styleLength(), .fill = try self.containerColor(),
            .margins = try self.styleEdges(), .clear = if (clear) try self.enumValue(types.FigureClear) else null };
        if (!types.validRuleStyle(value)) return error.InvalidPresentation;
        return value;
    }
    fn block(self: *Reader) error{ OutOfMemory, InvalidPresentation }!types.Block {
        if (self.rule_styles and self.version != .container_fonts) return error.InvalidPresentation;
        const kind = try self.enumValue(types.BlockKind);
        if (kind == .container and !hasLFields(self.version)) return error.InvalidPresentation;
        var value: types.Block = .{
            .kind = kind,
            .depth = try self.byte(),
            .level = try self.byte(),
            .spans = try self.spans(),
            .feature = try self.feature(),
            .list_path = try self.string(),
            .number = try self.string(),
            .table = try self.table(),
            .anchor = if (hasAnchorFields(self.version)) try self.string() else "",
            .anchor_fallback = if (hasAnchorFields(self.version)) try self.string() else "",
            .text_align = if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version))))))) and try self.presence()) try self.enumValue(types.CellTextAlign) else null,
            .style = if ((self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))) try self.blockStyle() else null,
            .figure = if ((self.version == .image_maps or hasKFields(self.version))) try self.figure() else null,
            .flow = if ((self.version == .image_maps or hasKFields(self.version))) try self.flow() else null,
        };
        if (kind == .container) {
            value.container = try self.container();
            if (!types.validContainerContext(value)) return error.InvalidPresentation;
        }
        if (self.rule_styles and kind == .rule) {
            const marker = try self.byte();
            if (marker > 1 and !(marker == 2 and self.capability_r)) return error.InvalidPresentation;
            if (marker != 0) {
                value.rule_style = try self.ruleStyleIn(marker == 2);
                if (!types.validRuleStyleContext(value)) return error.InvalidPresentation;
            }
        }
        if (value.table) |table_value| if (types.tableStyleIsInline(table_value.style) and
            !types.validInlineTableOwner(value.kind, value.spans.len, value.feature != null)) return error.InvalidPresentation;
        if (value.style != null and !types.validBlockStyleContext(value.kind, value.depth, value.table != null, value.feature != null, value.list_path)) return error.InvalidPresentation;
        if (value.figure != null and (value.spans.len != 0 or !types.validFigureContext(value.kind, value.depth, value.table != null, value.feature != null, value.style != null, value.list_path))) return error.InvalidPresentation;
        if (value.flow != null and (value.spans.len != 0 or !types.validFlowContext(value.kind, value.depth, value.table != null, value.feature != null, value.figure != null, value.list_path))) return error.InvalidPresentation;
        return value;
    }
    fn blocks(self: *Reader) ![]const types.Block {
        const len = try self.count(if ((self.version == .image_maps or hasKFields(self.version))) 29 else if ((self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))) 27 else if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))))))) 26 else 25);
        const out = try self.a.alloc(types.Block, len);
        for (out) |*value| value.* = try self.block();
        return out;
    }
    fn sections(self: *Reader) ![]const types.Section {
        const len = try self.count(if (hasAnchorFields(self.version)) 17 else 9);
        const out = try self.a.alloc(types.Section, len);
        for (out) |*section| {
            section.heading_style = null;
            section.level = try self.byte();
            section.title = try self.string();
            section.anchor = if (hasAnchorFields(self.version)) try self.string() else "";
            section.anchor_fallback = if (hasAnchorFields(self.version)) try self.string() else "";
            const block_len = try self.count(if ((self.version == .image_maps or hasKFields(self.version))) 29 else if ((self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))) 27 else if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or (self.version == .image_maps or hasKFields(self.version)))))))) 26 else if (hasAnchorFields(self.version)) 25 else 17);
            const block_values = try self.a.alloc(types.Block, block_len);
            for (block_values) |*block_value| block_value.* = try self.block();
            section.blocks = block_values;
        }
        return out;
    }
    fn form(self: *Reader) !?types.Form {
        if (!try self.presence()) return null;
        return .{ .relation = try self.string(), .target = try self.string(), .language = try self.string() };
    }
    fn sense(self: *Reader) !types.Sense {
        var value: types.Sense = .{
            .block = try self.index(),
            .parent = try self.optionalIndex(),
            .examples = try self.indices(),
            .quotations = try self.indices(),
            .notes = try self.indices(),
            .form = try self.form(),
        };
        if (hasLFields(self.version)) {
            value.block_path = try self.childPath();
            value.example_paths = try self.childPaths(value.examples);
            value.quotation_paths = try self.childPaths(value.quotations);
            value.note_paths = try self.childPaths(value.notes);
        }
        return value;
    }
    fn layout(self: *Reader) !types.Layout {
        const len = try self.count(if (hasLFields(self.version)) 37 else 29);
        const lexemes = try self.a.alloc(types.Lexeme, len);
        for (lexemes) |*lexeme| {
            lexeme.language = try self.string();
            lexeme.kind = try self.string();
            lexeme.section = try self.index();
            lexeme.etymology = try self.optionalIndex();
            const senses_len = try self.count(if (hasLFields(self.version)) 34 else 18);
            const senses = try self.a.alloc(types.Sense, senses_len);
            for (senses) |*sense_value| sense_value.* = try self.sense();
            lexeme.definitions = senses;
            lexeme.introduction = try self.indices();
            lexeme.other_blocks = try self.indices();
            lexeme.related_sections = try self.indices();
            // Allocated Lexeme memory has no implicit field defaults.
            lexeme.introduction_paths = if (hasLFields(self.version)) try self.childPaths(lexeme.introduction) else &.{};
            lexeme.other_block_paths = if (hasLFields(self.version)) try self.childPaths(lexeme.other_blocks) else &.{};
        }
        return .{ .lexemes = lexemes, .other_sections = try self.indices() };
    }
    fn references(self: *Reader) ![]const types.Reference {
        const len = try self.count(if (hasReferenceBlockFields(self.version)) 14 else if (hasReferenceFields(self.version)) 13 else 20);
        const out = try self.a.alloc(types.Reference, len);
        for (out) |*reference| {
            const kind = if (hasReferenceFields(self.version)) try self.enumValue(types.ReferenceKind) else types.ReferenceKind.note;
            reference.* = .{
                .kind = kind,
                .number = try self.index(),
                .group_number = if (kind == .note) @as(u32, @intCast(try self.index())) else null,
                .name = if (kind == .note) try self.string() else "",
                .group = try self.string(),
                .spans = try self.spans(),
            };
            if (hasReferenceBlockFields(self.version) and try self.presence()) {
                if (reference.spans.len != 0) return error.InvalidPresentation;
                const previous_reference = self.in_reference;
                self.in_reference = true;
                defer self.in_reference = previous_reference;
                reference.blocks = try self.blocks();
            }
        }
        return out;
    }
    fn media(self: *Reader) ![]const types.Media {
        const len = try self.count(9);
        const out = try self.a.alloc(types.Media, len);
        for (out) |*item| item.* = .{
            .file = try self.string(),
            .kind = try self.enumValue(types.MediaKind),
            .caption = try self.string(),
        };
        return out;
    }
};

fn spanImage(value: anytype) ?types.InlineImage {
    return if (comptime @hasField(@TypeOf(value), "image")) value.image else null;
}
fn spansHaveImageMaps(values: anytype) bool {
    for (values) |value| if (spanImage(value)) |image| if (image.map != null) { return true; };
    return false;
}
fn hasImageMaps(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveImageMaps(display) or spansHaveImageMaps(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .image_maps, 0)) return true;
    for (references) |reference| if (spansHaveImageMaps(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .image_maps);
}
fn spansHaveSvgLanguages(values: anytype) bool {
    for (values) |value| if (spanImage(value)) |image| if (image.svg_language != null) { return true; };
    return false;
}
fn hasSvgLanguages(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveSvgLanguages(display) or spansHaveSvgLanguages(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .svg_languages, 0)) return true;
    for (references) |reference| if (spansHaveSvgLanguages(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .svg_languages);
}
fn spansHaveImageDarkModeFilters(values: anytype) bool {
    for (values) |value| if (spanImage(value)) |image| if (image.dark_mode_filter != null) { return true; };
    return false;
}
fn hasImageDarkModeFilters(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveImageDarkModeFilters(display) or spansHaveImageDarkModeFilters(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .image_dark_mode_filters, 0)) return true;
    for (references) |reference| if (spansHaveImageDarkModeFilters(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .image_dark_mode_filters);
}
fn spansHaveImageAlignments(values: anytype) bool {
    for (values) |value| if (spanImage(value)) |image| if (image.vertical_align != null) return true;
    return false;
}
fn hasImageAlignments(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveImageAlignments(display) or spansHaveImageAlignments(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .image_alignments, 0)) return true;
    for (references) |reference| if (spansHaveImageAlignments(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .image_alignments);
}
fn spansHaveStaticPosters(values: anytype) bool {
    for (values) |value| if (spanImage(value)) |image| if (image.static_poster != null) { return true; };
    return false;
}
fn hasStaticPosters(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveStaticPosters(display) or spansHaveStaticPosters(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .static_posters, 0)) return true;
    for (references) |reference| if (spansHaveStaticPosters(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .static_posters);
}
fn spansHaveImages(values: anytype) bool {
    for (values) |value| if (spanImage(value) != null) return true;
    return false;
}
fn spanFontFeatures(value: anytype) ?types.FontFeaturePolicy {
    if (comptime @hasField(@TypeOf(value), "font_features")) return value.font_features;
    return null;
}
fn spanInlineStyle(value: anytype) ?types.InlineTextStyle {
    if (comptime @hasField(@TypeOf(value), "inline_style")) return value.inline_style;
    return null;
}
fn spansHaveInlineStyles(values: anytype) bool {
    for (values) |value| if (spanInlineStyle(value) != null) return true;
    return false;
}
fn hasInlineStyles(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveInlineStyles(display) or spansHaveInlineStyles(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .inline_styles, 0)) return true;
    for (references) |reference| if (spansHaveInlineStyles(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .inline_styles);
}

fn spanLinkPaint(value: anytype) ?types.LinkPaint {
    if (comptime @hasField(@TypeOf(value), "link_paint")) return value.link_paint;
    return null;
}
fn spansRequireMFontFields(values: anytype) bool {
    for (values) |value| if (spanScaleBasis(value) == .css_px or spanFontFeatures(value) != null or spanLinkPaint(value) != null) return true;
    return false;
}
fn hasMSpanFonts(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansRequireMFontFields(display) or spansRequireMFontFields(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .m_span_fonts, 0)) return true;
    for (references) |reference| if (spansRequireMFontFields(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .m_span_fonts);
}
fn spanScaleBasis(value: anytype) types.FontScaleBasis {
    if (comptime @hasField(@TypeOf(value), "font_scale_basis")) return value.font_scale_basis;
    return .context;
}
fn spanScale(value: anytype) ?f32 {
    if (comptime @hasField(@TypeOf(value), "font_scale")) {
        if (value.font_scale) |n| return if (n == 1 and spanScaleBasis(value) == .context) null else n;
    }
    return null;
}
fn spansHaveScale(values: anytype) bool {
    for (values) |value| if (spanScale(value) != null) return true;
    return false;
}
fn tableHasScale(table: anytype, depth: usize) bool {
    // The encoder independently rejects excess depth; selection stays bounded.
    if (depth > types.max_table_depth) return false;
    if (spansHaveScale(table.caption)) return true;
    for (table.rows) |row| for (row.cells) |cell| {
        if (spansHaveScale(cell.spans)) return true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| {
            if (tableHasScale(child, depth + 1)) return true;
        };
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks) |blocks| {
            for (blocks) |block| {
                if (spansHaveScale(block.spans)) return true;
                if (block.table) |child| if (tableHasScale(child, depth + 1)) return true;
            }
        };
    };
    return false;
}
fn hasFontScale(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (hasFigureSpanFeature(sections, references, .scale)) return true;
    if (spansHaveScale(display) or spansHaveScale(preamble)) return true;
    for (sections) |section| for (section.blocks) |block| {
        if (spansHaveScale(block.spans)) return true;
        if (block.table) |table| if (tableHasScale(table, 1)) return true;
    };
    for (references) |reference| if (spansHaveScale(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .scale);
}

fn spansHaveCssPixelFonts(values: anytype) bool {
    for (values) |value| if (spanScaleBasis(value) == .css_px) return true;
    return false;
}
fn hasCssPixelFonts(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveCssPixelFonts(display) or spansHaveCssPixelFonts(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .css_pixel_fonts, 0)) return true;
    for (references) |reference| if (spansHaveCssPixelFonts(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .css_pixel_fonts);
}

fn spansHaveBodyScale(values: anytype) bool {
    for (values) |value| if (spanScaleBasis(value) == .normal_body) return true;
    return false;
}
fn tableHasBodyScale(table: anytype, depth: usize) bool {
    // The encoder independently rejects excess depth; selection stays bounded.
    if (depth > types.max_table_depth) return false;
    if (spansHaveBodyScale(table.caption)) return true;
    for (table.rows) |row| for (row.cells) |cell| {
        if (spansHaveBodyScale(cell.spans)) return true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| {
            if (tableHasBodyScale(child, depth + 1)) return true;
        };
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks) |blocks| {
            for (blocks) |block| {
                if (spansHaveBodyScale(block.spans)) return true;
                if (block.table) |child| if (tableHasBodyScale(child, depth + 1)) return true;
            }
        };
    };
    return false;
}
fn hasBodyFontScale(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (hasFigureSpanFeature(sections, references, .body_scale)) return true;
    if (spansHaveBodyScale(display) or spansHaveBodyScale(preamble)) return true;
    for (sections) |section| for (section.blocks) |block| {
        if (spansHaveBodyScale(block.spans)) return true;
        if (block.table) |table| if (tableHasBodyScale(table, 1)) return true;
    };
    for (references) |reference| if (spansHaveBodyScale(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .body_scale);
}

fn spansHaveExplanation(values: anytype) bool {
    for (values) |span_value| {
        if (comptime @hasField(@TypeOf(span_value), "explanation"))
            if (span_value.explanation.len != 0) return true;
    }
    return false;
}

// Visit every span that Encoder serializes. Layout contains only indices and
// scalar fields; media descriptions are plain text, not another span tree.
fn hasExplanation(display: anytype, sections_value: anytype, preamble: anytype, references_value: anytype) bool {
    if (hasFigureSpanFeature(sections_value, references_value, .explanation)) return true;
    if (spansHaveExplanation(display) or spansHaveExplanation(preamble)) return true;
    for (sections_value) |section| for (section.blocks) |block_value| {
        if (spansHaveExplanation(block_value.spans)) return true;
        if (block_value.table) |table_value| {
            if (spansHaveExplanation(table_value.caption)) return true;
            for (table_value.rows) |row_value| for (row_value.cells) |cell_value|
                if (spansHaveExplanation(cell_value.spans)) return true;
        }
    };
    for (references_value) |reference| if (spansHaveExplanation(reference.spans)) return true;
    return referenceBlocksHaveFeature(references_value, .explanation);
}

fn spansHaveForeground(values: anytype) bool {
    for (values) |span_value| if (comptime @hasField(@TypeOf(span_value), "foreground")) {
        if (span_value.foreground != null) return true;
    };
    return false;
}

fn hasColor(display: anytype, sections_value: anytype, preamble: anytype, references_value: anytype) bool {
    if (hasFigureSpanFeature(sections_value, references_value, .color)) return true;
    if (spansHaveForeground(display) or spansHaveForeground(preamble)) return true;
    for (sections_value) |section| for (section.blocks) |block_value| {
        if (spansHaveForeground(block_value.spans)) return true;
        if (block_value.table) |table_value| {
            if (spansHaveForeground(table_value.caption)) return true;
            for (table_value.rows) |row_value| for (row_value.cells) |cell_value| {
                if (comptime @hasField(@TypeOf(cell_value), "background")) {
                    if (cell_value.background != null) return true;
                }
                if (spansHaveForeground(cell_value.spans)) return true;
            };
        }
    };
    for (references_value) |reference| if (spansHaveForeground(reference.spans)) return true;
    return referenceBlocksHaveFeature(references_value, .color);
}

fn spansHaveBackground(values: anytype) bool {
    for (values) |span| if (comptime @hasField(@TypeOf(span), "background")) {
        if (span.background != null) return true;
    };
    return false;
}

fn hasSpanBackground(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (hasFigureSpanFeature(sections, references, .background)) return true;
    if (spansHaveBackground(display) or spansHaveBackground(preamble)) return true;
    for (sections) |section| for (section.blocks) |block| {
        if (spansHaveBackground(block.spans)) return true;
        if (block.table) |table| {
            if (spansHaveBackground(table.caption)) return true;
            for (table.rows) |row| for (row.cells) |cell|
                if (spansHaveBackground(cell.spans)) return true;
        }
    };
    for (references) |reference| if (spansHaveBackground(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .background);
}

fn hasNestedTables(sections: anytype, references: anytype) bool {
    for (sections) |section| for (section.blocks) |block| if (block.table) |table| {
        if (comptime @hasField(@TypeOf(table), "geometry")) if (table.geometry != null) return true;
        for (table.rows) |row| for (row.cells) |cell| {
            if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table != null) return true;
        };
    };
    return referenceBlocksHaveFeature(references, .nested_tables);
}

fn tableHasCellBlocks(table: anytype, depth: usize) bool {
    // Encoding rejects excess depth; version detection must also remain bounded.
    if (depth > types.max_table_depth) return false;
    for (table.rows) |row| for (row.cells) |cell| {
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks != null) return true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| {
            if (tableHasCellBlocks(child, depth + 1)) return true;
        };
    };
    return false;
}

fn hasCellBlocks(sections: anytype, references: anytype) bool {
    for (sections) |section| for (section.blocks) |block_value| if (block_value.table) |table| {
        if (tableHasCellBlocks(table, 1)) return true;
    };
    return referenceBlocksHaveFeature(references, .cell_blocks);
}

fn anchorValue(value: anytype) []const u8 {
    return if (comptime @hasField(@TypeOf(value), "anchor")) value.anchor else "";
}

fn fallbackValue(value: anytype) []const u8 {
    return if (comptime @hasField(@TypeOf(value), "anchor_fallback")) value.anchor_fallback else "";
}

fn hasAnchors(sections: anytype, references: anytype) bool {
    for (sections) |section| {
        if (anchorValue(section).len != 0 or fallbackValue(section).len != 0) return true;
        for (section.blocks) |block_value| if (anchorValue(block_value).len != 0 or fallbackValue(block_value).len != 0) return true;
    }
    return referenceBlocksHaveFeature(references, .anchors);
}

const TreeFeature = enum { rule_clear, intrinsic_tables, cell_owner_fonts, image_alignments, table_corners, responsive_table_scroll, responsive_table_clear, extended_font_families, inline_styles, rule_styles, m_span_fonts, css_pixel_fonts, static_posters, cell_min_width, container_fonts, containers, svg_languages, missing_figures, image_dark_mode_filters, inline_table_media, inline_table_style, table_box_style, rich_content, figures, image_maps, block_geometry, tooltips, explicit_targets, explanation, color, background, scale, body_scale, anchors, nested_tables, cell_blocks, styles, images, image_borders, block_layout };

fn treeSpansHaveFeature(values: anytype, comptime feature: TreeFeature) bool {
    return switch (feature) {
        .image_alignments => spansHaveImageAlignments(values),
        .extended_font_families => spansHaveExplicitFontFamily(values),
        .static_posters => spansHaveStaticPosters(values),
        .svg_languages => spansHaveSvgLanguages(values),
        .image_maps => spansHaveImageMaps(values),
        .image_dark_mode_filters => spansHaveImageDarkModeFilters(values),
        .tooltips => spansHaveTooltips(values),
        .explicit_targets => spansHaveExplicitTargets(values),
        .explanation => spansHaveExplanation(values),
        .color => spansHaveForeground(values),
        .background => spansHaveBackground(values),
        .scale => spansHaveScale(values),
        .body_scale => spansHaveBodyScale(values),
        .css_pixel_fonts => spansHaveCssPixelFonts(values),
        .m_span_fonts => spansRequireMFontFields(values),
        .inline_styles => spansHaveInlineStyles(values),
        .images => spansHaveImages(values),
        .image_borders => spansHaveImageBorders(values),
        else => false,
    };
}

fn blocksHaveFeature(values: anytype, comptime feature: TreeFeature, table_depth: usize) bool { return contentBlocksHaveFeature(values, feature, table_depth, 0); }
fn treeTableHasFeature(value: anytype, comptime feature: TreeFeature, table_depth: usize) bool { return contentTableHasFeature(value, feature, table_depth, 0); }
fn figureHasFeature(figure: anytype, comptime feature: TreeFeature, table_depth: usize, content_depth: usize) bool {
    if (feature == .container_fonts) if (comptime @hasField(@TypeOf(figure), "table_caption_layout"))
        if (figure.table_caption_layout != null) return true;
    if (feature == .container_fonts) if (comptime @hasField(@TypeOf(figure), "block_media_layout"))
        if (figure.block_media_layout != null) return true;
    if (feature == .figures) return true;
    if (feature == .missing_figures and figure.content == .missing) return true;
    const subject = [_]@TypeOf(figure.content.span()){figure.content.span()};
    if (treeSpansHaveFeature(&subject, feature)) return true;
    if (comptime @hasField(@TypeOf(figure), "caption_blocks")) if (figure.caption_blocks) |blocks| {
        if (feature == .rich_content) return true;
        if (contentBlocksHaveFeature(blocks, feature, table_depth, content_depth + 1)) return true;
    };
    if (comptime @hasField(@TypeOf(figure), "caption")) if (treeSpansHaveFeature(figure.caption, feature)) return true;
    return false;
}
fn contentPartsHaveFeature(parts: anytype, comptime feature: TreeFeature, table_depth: usize, content_depth: usize) bool {
    if (content_depth > types.max_content_depth) return false;
    for (parts) |part| {
        if (treeSpansHaveFeature(part.spans, feature)) return true;
        if (part.figure) |figure| if (figureHasFeature(figure, feature, table_depth, content_depth)) return true;
        if (comptime @hasField(@TypeOf(part), "scope")) if (part.scope) |scope| {
            if (content_depth < types.max_content_depth and contentPartsHaveFeature(scope.parts, feature, table_depth, content_depth + 1)) return true;
        };
    }
    return false;
}
fn contentBlocksHaveFeature(values: anytype, comptime feature: TreeFeature, table_depth: usize, content_depth: usize) bool {
    if (content_depth > types.max_content_depth) return false;
    for (values) |value| {
        if (feature == .rule_styles and blockRuleStyle(value) != null) return true;
        if (feature == .rule_clear) if (blockRuleStyle(value)) |style| if (style.clear != null) return true;
        if (comptime @hasField(@TypeOf(value), "container")) if (value.container) |box| {
            if (feature == .containers) return true;
            if (feature == .extended_font_families and stackFontFamily(box.style)) return true;
            if (feature == .container_fonts and (box.style.font_family != null or box.style.owner_font_scale != null or box.style.height != null or box.style.columns != null or box.style.positioning != null or box.style.min_height != null or (box.style.border != null and box.style.border.? == .edges) or types.containerRequiresMForMargins(box))) return true;
            if (content_depth < types.max_content_depth and contentBlocksHaveFeature(box.blocks, feature, table_depth, content_depth + 1)) return true;
        };
        if (comptime @hasField(@TypeOf(value), "flow")) if (value.flow) |parts| {
            if (feature == .rich_content) return true;
            if (content_depth < types.max_content_depth and contentPartsHaveFeature(parts, feature, table_depth, content_depth + 1)) return true;
        };
        if (comptime @hasField(@TypeOf(value), "figure")) if (value.figure) |figure| {
            if (feature == .figures) return true;
            if (figureHasFeature(figure, feature, table_depth, content_depth)) return true;
        };
        if (feature == .block_geometry and blockGeometry(value) != null) return true;
        if (feature == .block_layout and blockTextAlign(value) != null) return true;
        if (treeSpansHaveFeature(value.spans, feature)) return true;
        if (feature == .anchors and (anchorValue(value).len != 0 or fallbackValue(value).len != 0)) return true;
        if (value.table) |table_value| if (contentTableHasFeature(table_value, feature, table_depth + 1, content_depth)) return true;
    }
    return false;
}

fn contentTableHasFeature(value: anytype, comptime feature: TreeFeature, table_depth: usize, content_depth: usize) bool {
    if (content_depth > types.max_content_depth) return false;
    if (table_depth > types.max_table_depth) return false;
    if (feature == .intrinsic_tables) {
        if (comptime @hasField(@TypeOf(value), "block_viewport")) if (value.block_viewport) |viewport|
            if (viewport.intrinsic_containing_direction != null) return true;
    }
    if (feature == .table_corners) {
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style) |style| if (style.corner_radii != null) return true;
        if (comptime @hasField(@TypeOf(value), "block_viewport")) if (value.block_viewport) |viewport| {
            if (viewport.box_style.corner_radii != null or viewport.grid_style.corner_radii != null) return true;
        };
    }
    if (feature == .responsive_table_scroll) {
        if (comptime @hasField(@TypeOf(value), "float_viewport") and @hasField(@TypeOf(value), "block_viewport"))
            if (value.float_viewport != null and value.block_viewport != null) return true;
    }
    if (feature == .responsive_table_clear) {
        if (comptime @hasField(@TypeOf(value), "float_viewport")) if (value.float_viewport) |policy|
            if (policy.narrow_clear != null) return true;
    }
    if (feature == .container_fonts) {
        if (comptime @hasField(@TypeOf(value), "block_viewport")) if (value.block_viewport != null) return true;
        if (comptime @hasField(@TypeOf(value), "float_viewport")) if (value.float_viewport != null) return true;
        if (types.inlineTableRequiresM(value)) return true;
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style) |style| if (style.margin_values != null) return true;
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style) |style| if (style.border) |border| if (border == .edges) return true;
    }
    if (feature == .inline_table_media) {
        if (comptime @hasField(@TypeOf(value), "style")) if (types.tableStyleIsInline(value.style)) {
            for (value.rows) |row_value| for (row_value.cells) |cell_value| for (cell_value.spans) |span|
                if (span.image != null or types.inlineTableEmbeddedMedia(span)) return true;
        };
    }
    if (feature == .inline_table_style) {
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style) |style| if (tableStyleHasInlineFields(style)) return true;
    }
    if (feature == .table_box_style) {
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style) |style| if (tableStyleHasBoxFields(style)) return true;
    }
    if (feature == .block_layout) {
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style) |style| {
            if (style.float_side != null) return true;
        };
    }
    if (feature == .styles) {
        if (comptime @hasField(@TypeOf(value), "style")) if (value.style != null) return true;
    }
    if (feature == .nested_tables) {
        if (comptime @hasField(@TypeOf(value), "geometry")) if (value.geometry != null) return true;
    }
    if (comptime @hasField(@TypeOf(value), "caption_blocks")) if (value.caption_blocks) |blocks| {
        if (feature == .rich_content) return true;
        if (contentBlocksHaveFeature(blocks, feature, table_depth, content_depth + 1)) return true;
    };
    if (treeSpansHaveFeature(value.caption, feature)) return true;
    for (value.rows) |row_value| for (row_value.cells) |cell_value| {
        if (feature == .styles) {
            if (comptime @hasField(@TypeOf(cell_value), "style")) if (cell_value.style != null) return true;
        }
        if (feature == .container_fonts) {
            if (comptime @hasField(@TypeOf(cell_value), "style")) if (cell_value.style) |style| if (style.border) |border| if (border == .edges) return true;
        }
        if (feature == .cell_min_width) {
            if (comptime @hasField(@TypeOf(cell_value), "style")) if (cell_value.style) |style| if (style.width != null or style.min_width != null or style.vertical_align != null or style.line_height != null) return true;
        }
        if (feature == .cell_owner_fonts or feature == .extended_font_families) {
            if (comptime @hasField(@TypeOf(cell_value), "style")) if (cell_value.style) |style| if (style.line_height) |height| if (height.strut) |strut| if (strut.owner_font) |font| {
                if (feature == .cell_owner_fonts or font.font_family != null) return true;
            };
        }
        if (feature == .color) {
            if (comptime @hasField(@TypeOf(cell_value), "background")) if (cell_value.background != null) return true;
        }
        if (treeSpansHaveFeature(cell_value.spans, feature)) return true;
        if (comptime @hasField(@TypeOf(cell_value), "nested_table")) if (cell_value.nested_table) |child| {
            if (feature == .nested_tables or contentTableHasFeature(child, feature, table_depth + 1, content_depth)) return true;
        };
        if (comptime @hasField(@TypeOf(cell_value), "blocks")) if (cell_value.blocks) |blocks_value| {
            if (feature == .cell_blocks or contentBlocksHaveFeature(blocks_value, feature, table_depth, content_depth)) return true;
        };
    };
    return false;
}

fn referenceBlocksHaveFeature(values: anytype, comptime feature: TreeFeature) bool {
    for (values) |value| {
        if (comptime @hasField(@TypeOf(value), "blocks")) if (value.blocks) |blocks_value| {
            if (blocksHaveFeature(blocks_value, feature, 0)) return true;
        };
    }
    return false;
}

fn tableStyleHasInlineFields(style: types.TableStyle) bool {
    return style.display != null or style.vertical_align != null or style.line_height != null;
}
fn hasInlineTableMedia(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .inline_table_media, 0)) return true;
    return referenceBlocksHaveFeature(references, .inline_table_media);
}
fn hasMissingFigures(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .missing_figures, 0)) return true;
    return referenceBlocksHaveFeature(references, .missing_figures);
}
fn hasInlineTableStyle(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .inline_table_style, 0)) return true;
    return referenceBlocksHaveFeature(references, .inline_table_style);
}
fn tableStyleHasBoxFields(style: types.TableStyle) bool { return style.width != null or style.padding != null or style.clear != null; }
fn hasTableBoxStyle(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .table_box_style, 0)) return true;
    return referenceBlocksHaveFeature(references, .table_box_style);
}
fn hasRichContent(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .rich_content, 0)) return true;
    return referenceBlocksHaveFeature(references, .rich_content);
}
fn hasFigures(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .figures, 0)) return true;
    return referenceBlocksHaveFeature(references, .figures);
}
// Earlier capability predicates have direct legacy traversals. Include only
// figure-image sinks here so their no-figure behavior remains byte-identical.
fn figureSpansHaveFeature(values: anytype, comptime feature: TreeFeature, depth: usize) bool {
    return contentBlocksHaveFeature(values, feature, depth, 0);
}

fn hasFigureSpanFeature(sections: anytype, references: anytype, comptime feature: TreeFeature) bool {
    for (sections) |section| if (figureSpansHaveFeature(section.blocks, feature, 0)) return true;
    for (references) |reference| if (comptime @hasField(@TypeOf(reference), "blocks")) if (reference.blocks) |blocks| if (figureSpansHaveFeature(blocks, feature, 0)) return true;
    return false;
}
fn blockGeometry(value: anytype) ?types.BlockStyle {
    return if (comptime @hasField(@TypeOf(value), "style")) value.style else null;
}
fn hasBlockGeometry(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .block_geometry, 0)) return true;
    return referenceBlocksHaveFeature(references, .block_geometry);
}
fn blockTextAlign(value: anytype) ?types.CellTextAlign {
    return if (comptime @hasField(@TypeOf(value), "text_align")) value.text_align else null;
}
fn hasBlockLayout(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .block_layout, 0)) return true;
    return referenceBlocksHaveFeature(references, .block_layout);
}
fn hasStyles(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .styles, 0)) return true;
    return referenceBlocksHaveFeature(references, .styles);
}

fn spansHaveImageBorders(values: anytype) bool {
    for (values) |value| if (spanImage(value)) |image| if (image.border) { return true; };
    return false;
}
fn spanTooltip(value: anytype) ?[]const u8 {
    return if (comptime @hasField(@TypeOf(value), "tooltip")) value.tooltip else null;
}
fn spansHaveTooltips(values: anytype) bool {
    // Empty titles are present metadata: never collapse them into absent.
    for (values) |value| if (spanTooltip(value) != null) return true;
    return false;
}
fn hasTooltips(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveTooltips(display) or spansHaveTooltips(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .tooltips, 0)) return true;
    for (references) |reference| if (spansHaveTooltips(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .tooltips);
}
fn spanTargetFragment(value: anytype) ?[]const u8 {
    return if (comptime @hasField(@TypeOf(value), "target_fragment")) value.target_fragment else null;
}
fn spansHaveExplicitTargets(values: anytype) bool {
    for (values) |value| if (spanTargetFragment(value) != null) return true;
    return false;
}
fn hasExplicitTargets(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveExplicitTargets(display) or spansHaveExplicitTargets(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .explicit_targets, 0)) return true;
    for (references) |reference| if (spansHaveExplicitTargets(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .explicit_targets);
}
fn hasImageBorders(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveImageBorders(display) or spansHaveImageBorders(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .image_borders, 0)) return true;
    for (references) |reference| if (spansHaveImageBorders(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .image_borders);
}
fn hasInlineImages(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveImages(display) or spansHaveImages(preamble)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .images, 0)) return true;
    for (references) |reference| if (spansHaveImages(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .images);
}
fn validateImageSpans(values: anytype, media: *const types.ImageCatalogIndex) error{InvalidPresentation}!void {
    for (values) |value| if (spanImage(value)) |image| {
        try media.validate(image.file);
    };
}
fn validateImageFigure(figure: anytype, media: *const types.ImageCatalogIndex, table_depth: usize, content_depth: usize) error{InvalidPresentation}!void {
    const subject = [_]@TypeOf(figure.content.span()){figure.content.span()}; try validateImageSpans(&subject, media);
    if (comptime @hasField(@TypeOf(figure), "caption")) try validateImageSpans(figure.caption, media);
    if (comptime @hasField(@TypeOf(figure), "caption_blocks")) if (figure.caption_blocks) |blocks| try validateContentImages(blocks, media, table_depth, content_depth + 1);
}
fn validateContentPartImages(parts: anytype, media: *const types.ImageCatalogIndex, table_depth: usize, content_depth: usize) error{InvalidPresentation}!void {
    if (content_depth > types.max_content_depth) return error.InvalidPresentation;
    for (parts) |part| {
        try validateImageSpans(part.spans, media);
        if (part.figure) |figure| try validateImageFigure(figure, media, table_depth, content_depth);
        if (comptime @hasField(@TypeOf(part), "scope")) if (part.scope) |scope| try validateContentPartImages(scope.parts, media, table_depth, content_depth + 1);
    }
}
fn validateContentImages(values: anytype, media: *const types.ImageCatalogIndex, table_depth: usize, content_depth: usize) error{InvalidPresentation}!void {
    if (content_depth > types.max_content_depth) return error.InvalidPresentation;
    for (values) |value| {
        if (comptime @hasField(@TypeOf(value), "container")) if (value.container) |box| {
            if (content_depth >= types.max_content_depth) return error.InvalidPresentation;
            try validateContentImages(box.blocks, media, table_depth, content_depth + 1);
        };
        if (comptime @hasField(@TypeOf(value), "figure")) if (value.figure) |figure| try validateImageFigure(figure, media, table_depth, content_depth);
        if (comptime @hasField(@TypeOf(value), "flow")) if (value.flow) |parts| {
            if (content_depth >= types.max_content_depth) return error.InvalidPresentation;
            try validateContentPartImages(parts, media, table_depth, content_depth + 1);
        };
        try validateImageSpans(value.spans, media);
        if (value.table) |table| try validateContentImageTable(table, media, table_depth + 1, content_depth);
    }
}
fn validateImageBlocks(values: anytype, media: *const types.ImageCatalogIndex, table_depth: usize) error{InvalidPresentation}!void { return validateContentImages(values, media, table_depth, 0); }
fn validateContentImageTable(value: anytype, media: *const types.ImageCatalogIndex, table_depth: usize, content_depth: usize) error{InvalidPresentation}!void {
    if (table_depth > types.max_table_depth or content_depth > types.max_content_depth) return error.InvalidPresentation;
    try validateImageSpans(value.caption, media);
    if (comptime @hasField(@TypeOf(value), "caption_blocks")) if (value.caption_blocks) |blocks| try validateContentImages(blocks, media, table_depth, content_depth + 1);
    for (value.rows) |row| for (row.cells) |cell| {
        try validateImageSpans(cell.spans, media);
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| try validateContentImageTable(child, media, table_depth + 1, content_depth);
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks) |blocks| try validateContentImages(blocks, media, table_depth, content_depth);
    };
}
fn validateImageTable(value: anytype, media: *const types.ImageCatalogIndex, table_depth: usize) error{InvalidPresentation}!void { return validateContentImageTable(value, media, table_depth, 0); }
fn validateImages(a: A, display: anytype, sections: anytype, preamble: anytype, references: anytype, values: anytype) !void {
    var index = try types.ImageCatalogIndex.init(a, values);
    defer index.deinit(a);
    const media: *const types.ImageCatalogIndex = &index;
    try validateImageSpans(display, media);
    try validateImageSpans(preamble, media);
    for (sections) |section| try validateImageBlocks(section.blocks, media, 0);
    for (references) |reference| {
        try validateImageSpans(reference.spans, media);
        if (comptime @hasField(@TypeOf(reference), "blocks")) if (reference.blocks) |blocks| {
            try validateImageBlocks(blocks, media, 0);
        };
    }
}

fn hasReferenceBlocks(values: anytype) bool {
    for (values) |value| {
        if (comptime @hasField(@TypeOf(value), "blocks")) if (value.blocks != null) return true;
    }
    return false;
}

fn hasReferenceFragments(references: anytype) bool {
    for (references) |reference| if (reference.kind == .fragment) return true;
    return false;
}

fn sensePath(value: anytype) []const usize {
    return if (comptime @hasField(@TypeOf(value), "block_path")) value.block_path else &.{};
}
fn lexicalPaths(value: anytype, comptime name: []const u8) []const []const usize {
    return if (comptime @hasField(@TypeOf(value), name)) @field(value, name) else &.{};
}
fn senseHasPaths(value: anytype) bool {
    return sensePath(value).len != 0 or lexicalPaths(value, "example_paths").len != 0 or lexicalPaths(value, "quotation_paths").len != 0 or lexicalPaths(value, "note_paths").len != 0;
}
fn layoutHasPaths(value: anytype) bool {
    for (value.lexemes) |lexeme| {
        if (lexicalPaths(lexeme, "introduction_paths").len != 0 or lexicalPaths(lexeme, "other_block_paths").len != 0) return true;
        for (lexeme.definitions) |sense_value| if (senseHasPaths(sense_value)) return true;
    }
    return false;
}
fn blockRuleStyle(value: anytype) ?types.RuleStyle {
    return if (comptime @hasField(@TypeOf(value), "rule_style")) value.rule_style else null;
}
fn hasRuleStyles(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .rule_styles, 0)) return true;
    return referenceBlocksHaveFeature(references, .rule_styles);
}
fn hasMFields(sections: anytype, references: anytype) bool {
    if (hasContainerFonts(sections, references)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .cell_min_width, 0)) return true;
    return referenceBlocksHaveFeature(references, .cell_min_width);
}
fn hasContainerFonts(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .container_fonts, 0)) return true;
    return referenceBlocksHaveFeature(references, .container_fonts);
}
fn hasContainers(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .containers, 0)) return true;
    return referenceBlocksHaveFeature(references, .containers);
}
fn buildBlockPathExists(blocks: anytype, root: usize, suffix: []const usize) bool {
    if (root >= blocks.len or suffix.len > types.max_content_depth) return false;
    var current: *const @TypeOf(blocks[0]) = &blocks[root];
    for (suffix) |index_value| {
        if (comptime @hasField(@TypeOf(current.*), "container")) {
            if (!types.validContainerContext(current.*)) return false;
            const box = current.container.?;
            if (index_value >= box.blocks.len) return false;
            current = &box.blocks[index_value];
        } else return false;
    }
    return true;
}
fn buildParallelPathsValid(blocks: anytype, roots: []const usize, paths: []const []const usize) bool {
    if (paths.len == 0) { for (roots) |root| if (!buildBlockPathExists(blocks, root, &.{})) return false; return true; }
    if (paths.len != roots.len) return false;
    var nested = false;
    for (roots, paths) |root, suffix| {
        if (!buildBlockPathExists(blocks, root, suffix)) return false;
        nested = nested or suffix.len != 0;
    }
    return nested;
}
fn buildLayoutPathsValid(layout_value: anytype, sections: anytype) bool {
    for (layout_value.lexemes) |lexeme| {
        if (lexeme.section >= sections.len) return false;
        const blocks = sections[lexeme.section].blocks;
        if (!buildParallelPathsValid(blocks, lexeme.introduction, lexicalPaths(lexeme, "introduction_paths")) or
            !buildParallelPathsValid(blocks, lexeme.other_blocks, lexicalPaths(lexeme, "other_block_paths"))) return false;
        for (lexeme.definitions) |sense_value| {
            if (!buildBlockPathExists(blocks, sense_value.block, sensePath(sense_value)) or
                !buildParallelPathsValid(blocks, sense_value.examples, lexicalPaths(sense_value, "example_paths")) or
                !buildParallelPathsValid(blocks, sense_value.quotations, lexicalPaths(sense_value, "quotation_paths")) or
                !buildParallelPathsValid(blocks, sense_value.notes, lexicalPaths(sense_value, "note_paths"))) return false;
        }
    }
    return true;
}

fn spanFontFamily(value: anytype) ?types.ContainerFontFamily {
    if (comptime @hasField(@TypeOf(value), "font_family")) return value.font_family;
    return null;
}
fn spansHaveExplicitFontFamily(values: anytype) bool {
    for (values) |value| {
        if (spanFontFamily(value) != null) return true;
        if (spanInlineStyle(value)) |style| if (style.line_height) |height| if (height == .font_relative and height.font_relative.font.font_family != null) return true;
    }
    return false;
}
fn sectionHeadingStyle(section: anytype) ?types.SectionHeadingStyle {
    if (comptime @hasField(@TypeOf(section), "heading_style")) return section.heading_style;
    return null;
}
fn hasSectionHeadingStyles(sections: anytype) bool {
    for (sections) |section| if (sectionHeadingStyle(section) != null) return true;
    return false;
}
fn stackFontFamily(style: types.ContainerStyle) bool {
    return if (style.font_family) |family| family == .stack else false;
}
pub fn hasExtendedFontFamilies(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveExplicitFontFamily(display) or spansHaveExplicitFontFamily(preamble)) return true;
    for (sections) |section| {
        if (sectionHeadingStyle(section)) |heading| if (stackFontFamily(heading.box) or heading.font.font_family != null) return true;
        if (blocksHaveFeature(section.blocks, .extended_font_families, 0)) return true;
    }
    for (references) |reference| if (spansHaveExplicitFontFamily(reference.spans)) return true;
    return referenceBlocksHaveFeature(references, .extended_font_families);
}
fn hasResponsiveTableClear(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .responsive_table_clear, 0)) return true;
    return referenceBlocksHaveFeature(references, .responsive_table_clear);
}
fn hasResponsiveTableScroll(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .responsive_table_scroll, 0)) return true;
    return referenceBlocksHaveFeature(references, .responsive_table_scroll);
}
fn hasCellOwnerFonts(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .cell_owner_fonts, 0)) return true;
    return referenceBlocksHaveFeature(references, .cell_owner_fonts);
}
fn hasRuleClearStyles(sections: anytype, references: anytype) bool {
    for (sections) |section| if (blocksHaveFeature(section.blocks, .rule_clear, 0)) return true;
    return referenceBlocksHaveFeature(references, .rule_clear);
}

fn hasIntrinsicTables(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (treeSpansHaveFeature(display, .intrinsic_tables) or treeSpansHaveFeature(preamble, .intrinsic_tables)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .intrinsic_tables, 0)) return true;
    for (references) |reference| if (treeSpansHaveFeature(reference.spans, .intrinsic_tables)) return true;
    return referenceBlocksHaveFeature(references, .intrinsic_tables);
}

fn hasTableCorners(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (treeSpansHaveFeature(display, .table_corners) or treeSpansHaveFeature(preamble, .table_corners)) return true;
    for (sections) |section| if (blocksHaveFeature(section.blocks, .table_corners, 0)) return true;
    for (references) |reference| if (treeSpansHaveFeature(reference.spans, .table_corners)) return true;
    return referenceBlocksHaveFeature(references, .table_corners);
}
fn pendingBodyFeatures(display: anytype, sections: anytype, preamble: anytype, references: anytype, body: ?types.BodyAdjoiningPolicy) u8 {
    return (if (body != null) @as(u8, 1) else 0) |
        (if (hasSectionHeadingStyles(sections)) @as(u8, 2) else 0) |
        (if (hasExtendedFontFamilies(display, sections, preamble, references)) @as(u8, 4) else 0) |
        (if (hasResponsiveTableClear(sections, references)) @as(u8, 8) else 0) |
        (if (hasResponsiveTableScroll(sections, references)) @as(u8, 32) else 0) |
        (if (hasCellOwnerFonts(sections, references)) @as(u8, 128) else 0);
}

fn versionMagic(version: Version) []const u8 {
    return switch (version) {
        .plain => magic,
        .explained => explained_magic,
        .colored => color_magic,
        .anchored => anchor_magic,
        .span_background => background_magic,
        .nested_tables => nested_magic,
        .cell_blocks => cell_blocks_magic,
        .reference_items => reference_items_magic,
        .font_scale => font_scale_magic,
        .font_scale_basis => font_scale_basis_magic,
        .reference_blocks => reference_blocks_magic,
        .image_border => image_border_magic,
        .block_layout => block_layout_magic,
        .explicit_targets => explicit_targets_magic,
        .dynamic_catalog => dynamic_catalog_magic,
        .tooltips => tooltips_magic,
        .block_geometry => block_geometry_magic,
        .image_maps => image_maps_magic,
        .inline_table_styles => inline_table_styles_magic,
        .block_containers => block_containers_magic,
        .container_fonts => container_fonts_magic,
    };
}

pub fn encodeAlloc(a: A, stored: types.Stored) ![]u8 {
    if (!std.mem.eql(u8, stored.schema, types.schema)) return error.InvalidPresentation;
    if (layoutHasPaths(stored.entry.organization) and !buildLayoutPathsValid(stored.entry.organization, stored.entry.sections)) return error.InvalidPresentation;
    const images = hasInlineImages(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references);
    if (images) try validateImages(a, stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references, stored.entry.media);
    const r_required = hasIntrinsicTables(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references) or
        hasRuleClearStyles(stored.entry.sections, stored.entry.references);
    const q_required = hasTableCorners(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references) or hasImageAlignments(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references);
    const pending_features = pendingBodyFeatures(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references, stored.entry.body_adjoining);
    const inline_styles = r_required or q_required or pending_features != 0 or hasInlineStyles(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references);
    const rule_styles = inline_styles or hasRuleStyles(stored.entry.sections, stored.entry.references);
    const version: Version = if (rule_styles or hasMSpanFonts(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references) or hasMFields(stored.entry.sections, stored.entry.references) or hasStaticPosters(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .container_fonts else if (hasContainers(stored.entry.sections, stored.entry.references) or layoutHasPaths(stored.entry.organization)) .block_containers else if (hasSvgLanguages(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references) or hasMissingFigures(stored.entry.sections, stored.entry.references) or hasInlineTableStyle(stored.entry.sections, stored.entry.references) or hasImageDarkModeFilters(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .inline_table_styles else if (hasTableBoxStyle(stored.entry.sections, stored.entry.references) or hasRichContent(stored.entry.sections, stored.entry.references) or hasFigures(stored.entry.sections, stored.entry.references) or hasImageMaps(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .image_maps else if (hasBlockGeometry(stored.entry.sections, stored.entry.references)) .block_geometry else if (hasTooltips(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .tooltips else if (images and stored.entry.media.len > types.legacy_extended_image_assets) .dynamic_catalog else if (hasExplicitTargets(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .explicit_targets else if (stored.entry.media.len > types.legacy_inline_image_assets or hasBlockLayout(stored.entry.sections, stored.entry.references)) .block_layout else if (hasImageBorders(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .image_border else if (images or hasReferenceBlocks(stored.entry.references) or hasStyles(stored.entry.sections, stored.entry.references)) .reference_blocks else if (hasBodyFontScale(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .font_scale_basis else if (hasFontScale(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .font_scale else if (hasReferenceFragments(stored.entry.references)) .reference_items else if (hasCellBlocks(stored.entry.sections, stored.entry.references)) .cell_blocks else if (hasNestedTables(stored.entry.sections, stored.entry.references)) .nested_tables else if (hasSpanBackground(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .span_background else if (hasAnchors(stored.entry.sections, stored.entry.references)) .anchored else if (hasColor(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .colored else if (hasExplanation(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .explained else .plain;
    var inline_catalog: ?types.ImageCatalogIndex = null;
    defer if (inline_catalog) |*catalog| catalog.deinit(a);
    if (hasInlineTableMedia(stored.entry.sections, stored.entry.references)) inline_catalog = try types.ImageCatalogIndex.init(a, stored.entry.media);
    var encoder: Encoder = .{ .a = a, .version = version, .rule_styles = rule_styles, .inline_styles = inline_styles, .capability_p = r_required or q_required or pending_features != 0, .capability_q = r_required or q_required, .capability_r = r_required, .inline_media_catalog = if (inline_catalog) |*catalog| catalog else null };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, if (r_required) intrinsic_table_magic else if (q_required) table_corners_magic else if (pending_features != 0) body_adjoining_magic else if (inline_styles) inline_styles_magic else if (rule_styles) rule_styles_magic else versionMagic(version));
    try encoder.spans(stored.entry.display_title);
    try encoder.sections(stored.entry.sections);
    try encoder.spans(stored.entry.preamble_spans);
    try encoder.layout(stored.entry.organization);
    try encoder.references(stored.entry.references);
    try encoder.media(stored.entry.media);
    if (r_required or q_required or pending_features != 0) {
        try encoder.byte(pending_features);
        if (pending_features & 2 != 0) try encoder.sectionHeadingStyles(stored.entry.sections);
    }
    return encoder.out.toOwnedSlice(a);
}

/// Build-time fast path: serialize compiler/layout structures directly instead of
/// allocating a second presentation tree with the same fields.
pub fn encodeBuildAlloc(
    a: A,
    display_title: anytype,
    sections: anytype,
    layout_value: anytype,
    references_value: anytype,
    media_value: anytype,
) ![]u8 {
    return encodeBuildWithBodyAdjoiningAlloc(a, display_title, sections, layout_value, references_value, media_value, null);
}
pub fn encodeBuildWithBodyAdjoiningAlloc(
    a: A,
    display_title: anytype,
    sections: anytype,
    layout_value: anytype,
    references_value: anytype,
    media_value: anytype,
    body_adjoining: ?types.BodyAdjoiningPolicy,
) ![]u8 {
    if (layoutHasPaths(layout_value) and !buildLayoutPathsValid(layout_value, sections)) return error.InvalidPresentation;
    const images = hasInlineImages(display_title, sections, @as([]const types.Span, &.{}), references_value);
    if (images) try validateImages(a, display_title, sections, @as([]const types.Span, &.{}), references_value, media_value);
    const r_required = hasIntrinsicTables(display_title, sections, @as([]const types.Span, &.{}), references_value) or
        hasRuleClearStyles(sections, references_value);
    const q_required = hasTableCorners(display_title, sections, @as([]const types.Span, &.{}), references_value) or hasImageAlignments(display_title, sections, @as([]const types.Span, &.{}), references_value);
    const pending_features = pendingBodyFeatures(display_title, sections, @as([]const types.Span, &.{}), references_value, body_adjoining);
    const inline_styles = r_required or q_required or pending_features != 0 or hasInlineStyles(display_title, sections, @as([]const types.Span, &.{}), references_value);
    const rule_styles = inline_styles or hasRuleStyles(sections, references_value);
    const version: Version = if (rule_styles or hasMSpanFonts(display_title, sections, @as([]const types.Span, &.{}), references_value) or hasMFields(sections, references_value) or hasStaticPosters(display_title, sections, @as([]const types.Span, &.{}), references_value)) .container_fonts else if (hasContainers(sections, references_value) or layoutHasPaths(layout_value)) .block_containers else if (hasSvgLanguages(display_title, sections, @as([]const types.Span, &.{}), references_value) or hasMissingFigures(sections, references_value) or hasInlineTableStyle(sections, references_value) or hasImageDarkModeFilters(display_title, sections, @as([]const types.Span, &.{}), references_value)) .inline_table_styles else if (hasTableBoxStyle(sections, references_value) or hasRichContent(sections, references_value) or hasFigures(sections, references_value) or hasImageMaps(display_title, sections, @as([]const types.Span, &.{}), references_value)) .image_maps else if (hasBlockGeometry(sections, references_value)) .block_geometry else if (hasTooltips(display_title, sections, @as([]const types.Span, &.{}), references_value)) .tooltips else if (images and media_value.len > types.legacy_extended_image_assets) .dynamic_catalog else if (hasExplicitTargets(display_title, sections, @as([]const types.Span, &.{}), references_value)) .explicit_targets else if (media_value.len > types.legacy_inline_image_assets or hasBlockLayout(sections, references_value)) .block_layout else if (hasImageBorders(display_title, sections, @as([]const types.Span, &.{}), references_value)) .image_border else if (images or hasReferenceBlocks(references_value) or hasStyles(sections, references_value)) .reference_blocks else if (hasBodyFontScale(display_title, sections, @as([]const types.Span, &.{}), references_value)) .font_scale_basis else if (hasFontScale(display_title, sections, @as([]const types.Span, &.{}), references_value)) .font_scale else if (hasReferenceFragments(references_value)) .reference_items else if (hasCellBlocks(sections, references_value)) .cell_blocks else if (hasNestedTables(sections, references_value)) .nested_tables else if (hasSpanBackground(display_title, sections, @as([]const types.Span, &.{}), references_value)) .span_background else if (hasAnchors(sections, references_value)) .anchored else if (hasColor(display_title, sections, @as([]const types.Span, &.{}), references_value)) .colored else if (hasExplanation(display_title, sections, @as([]const types.Span, &.{}), references_value)) .explained else .plain;
    var inline_catalog: ?types.ImageCatalogIndex = null;
    defer if (inline_catalog) |*catalog| catalog.deinit(a);
    if (hasInlineTableMedia(sections, references_value)) inline_catalog = try types.ImageCatalogIndex.init(a, media_value);
    var encoder: Encoder = .{ .a = a, .version = version, .rule_styles = rule_styles, .inline_styles = inline_styles, .capability_p = r_required or q_required or pending_features != 0, .capability_q = r_required or q_required, .capability_r = r_required, .inline_media_catalog = if (inline_catalog) |*catalog| catalog else null };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, if (r_required) intrinsic_table_magic else if (q_required) table_corners_magic else if (pending_features != 0) body_adjoining_magic else if (inline_styles) inline_styles_magic else if (rule_styles) rule_styles_magic else versionMagic(version));
    try encoder.spans(display_title);
    try encoder.sections(sections);
    try encoder.count(0); // no preamble is emitted by the bundle compiler
    try encoder.layout(layout_value);
    try encoder.references(references_value);
    try encoder.media(media_value);
    if (r_required or q_required or pending_features != 0) {
        try encoder.byte(pending_features);
        if (pending_features & 2 != 0) try encoder.sectionHeadingStyles(sections);
    }
    return encoder.out.toOwnedSlice(a);
}

/// Structural slices are allocated from `a`; all decoded strings borrow `payload`,
/// `expected_title`, or `language_metadata`. Those backing bytes must outlive the result.
pub fn decodeAlloc(
    a: A,
    payload: []const u8,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
) !types.Stored {
    return decodeImpl(a, payload, expected_title, expected_kind, language_metadata, null);
}

/// Commit measurements only after ordinary framing and semantic validation pass.
pub fn decodeWithMetricsAlloc(
    a: A,
    payload: []const u8,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
    metrics: *DecodeMetrics,
) !types.Stored {
    var observed: DecodeMetrics = .{};
    const stored = try decodeImpl(a, payload, expected_title, expected_kind, language_metadata, &observed);
    metrics.* = observed;
    return stored;
}

fn decodeImpl(
    a: A,
    payload: []const u8,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
    metrics: ?*DecodeMetrics,
) !types.Stored {
    if (payload.len < magic.len) return error.InvalidPresentation;
    const intrinsic_header = std.mem.eql(u8, payload[0..magic.len], intrinsic_table_magic);
    const table_corners_header = std.mem.eql(u8, payload[0..magic.len], table_corners_magic);
    const body_adjoining_header = intrinsic_header or table_corners_header or std.mem.eql(u8, payload[0..magic.len], body_adjoining_magic);
    const inline_styles = body_adjoining_header or std.mem.eql(u8, payload[0..magic.len], inline_styles_magic);
    const rule_styles = inline_styles or std.mem.eql(u8, payload[0..magic.len], rule_styles_magic);
    const version: Version = if (rule_styles) .container_fonts else if (std.mem.eql(u8, payload[0..magic.len], magic)) .plain else if (std.mem.eql(u8, payload[0..explained_magic.len], explained_magic)) .explained else if (std.mem.eql(u8, payload[0..color_magic.len], color_magic)) .colored else if (std.mem.eql(u8, payload[0..anchor_magic.len], anchor_magic)) .anchored else if (std.mem.eql(u8, payload[0..background_magic.len], background_magic)) .span_background else if (std.mem.eql(u8, payload[0..nested_magic.len], nested_magic)) .nested_tables else if (std.mem.eql(u8, payload[0..cell_blocks_magic.len], cell_blocks_magic)) .cell_blocks else if (std.mem.eql(u8, payload[0..reference_items_magic.len], reference_items_magic)) .reference_items else if (std.mem.eql(u8, payload[0..font_scale_magic.len], font_scale_magic)) .font_scale else if (std.mem.eql(u8, payload[0..font_scale_basis_magic.len], font_scale_basis_magic)) .font_scale_basis else if (std.mem.eql(u8, payload[0..reference_blocks_magic.len], reference_blocks_magic)) .reference_blocks else if (std.mem.eql(u8, payload[0..image_border_magic.len], image_border_magic)) .image_border else if (std.mem.eql(u8, payload[0..block_layout_magic.len], block_layout_magic)) .block_layout else if (std.mem.eql(u8, payload[0..explicit_targets_magic.len], explicit_targets_magic)) .explicit_targets else if (std.mem.eql(u8, payload[0..dynamic_catalog_magic.len], dynamic_catalog_magic)) .dynamic_catalog else if (std.mem.eql(u8, payload[0..tooltips_magic.len], tooltips_magic)) .tooltips else if (std.mem.eql(u8, payload[0..block_geometry_magic.len], block_geometry_magic)) .block_geometry else if (std.mem.eql(u8, payload[0..image_maps_magic.len], image_maps_magic)) .image_maps else if (std.mem.eql(u8, payload[0..inline_table_styles_magic.len], inline_table_styles_magic)) .inline_table_styles else if (std.mem.eql(u8, payload[0..block_containers_magic.len], block_containers_magic)) .block_containers else if (std.mem.eql(u8, payload[0..container_fonts_magic.len], container_fonts_magic)) .container_fonts else {
        // A complete DPR header advertises a reader capability. Do not call an
        // unknown capability malformed; known versions still validate normally.
        if (std.mem.eql(u8, payload[0..3], "DPR")) return error.UnsupportedPresentationVersion;
        return error.InvalidPresentation;
    };
    var reader: Reader = .{ .a = a, .version = version, .rule_styles = rule_styles, .inline_styles = inline_styles, .capability_p = body_adjoining_header, .capability_q = intrinsic_header or table_corners_header, .capability_r = intrinsic_header, .bytes = payload, .pos = magic.len, .metrics = metrics };
    const display_title = try reader.spans();
    const sections = try reader.sections();
    const preamble = try reader.spans();
    const layout = try reader.layout();
    const references = try reader.references();
    const media = try reader.media();
    const pending_features: u8 = if (body_adjoining_header) try reader.byte() else 0;
    if (body_adjoining_header and ((!intrinsic_header and !table_corners_header and pending_features == 0) or pending_features & ~@as(u8, 175) != 0)) return error.InvalidPresentation;
    if (pending_features & 2 != 0) try reader.sectionHeadingStyles(sections);
    const body_adjoining: ?types.BodyAdjoiningPolicy = if (pending_features & 1 != 0) .ordinary else null;
    if (body_adjoining_header and pending_features != pendingBodyFeatures(display_title, sections, preamble, references, body_adjoining)) return error.InvalidPresentation;
    if (!intrinsic_header and table_corners_header != (hasTableCorners(display_title, sections, preamble, references) or
        hasImageAlignments(display_title, sections, preamble, references))) return error.InvalidPresentation;
    if (intrinsic_header != (hasIntrinsicTables(display_title, sections, preamble, references) or
        hasRuleClearStyles(sections, references))) return error.InvalidPresentation;
    if (reader.pos != payload.len) return error.InvalidPresentation;

    const title = expected_title;
    const language = if (expected_kind == .language)
        (language_metadata orelse return error.InvalidPresentation).heading
    else
        null;
    const language_code = if (expected_kind == .language) language_metadata.?.code else "";
    const stored: types.Stored = .{ .entry = .{
        .organization = layout,
        .title = title,
        .display_title = display_title,
        .kind = expected_kind,
        .language = language,
        .language_code = language_code,
        .sections = sections,
        .preamble_spans = preamble,
        .body_adjoining = body_adjoining,
        .references = references,
        .media = media,
    } };
    // E is the first wire version admitting more than128 inline-image assets.
    // Do not retroactively restrict media-only legacy records.
    if (version != .block_layout and (version != .explicit_targets and (version != .dynamic_catalog and (version != .tooltips and (version != .block_geometry and (version != .image_maps and !hasKFields(version)))))) and media.len > types.legacy_inline_image_assets and
        hasInlineImages(display_title, sections, preamble, references)) return error.InvalidPresentation;
    if ((version != .dynamic_catalog and (version != .tooltips and (version != .block_geometry and (version != .image_maps and !hasKFields(version))))) and media.len > types.legacy_extended_image_assets and
        hasInlineImages(display_title, sections, preamble, references)) return error.InvalidPresentation;
    try types.validateStored(a, stored, expected_title, expected_kind, language_metadata);
    return stored;
}

test "enum encoding maps build-only tags without runtime name lookup" {
    const BuildInlineKind = enum { text, template, link, external_link, line_break };
    var encoder: Encoder = .{ .a = std.testing.allocator };
    defer encoder.deinit();

    try encoder.enumByte(types.InlineKind, BuildInlineKind.link);
    try std.testing.expectEqualSlices(u8, &.{@backingInt(types.InlineKind.link)}, encoder.out.items);
    try std.testing.expectError(error.UncompiledTemplate, encoder.enumByte(types.InlineKind, BuildInlineKind.template));
}

test "binary presentation codec round trips semantic structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{ .kind = .link, .text = "cat", .target = "cat", .bold = true, .role = .headword }};
    const display_title = [_]types.Span{.{ .text = "cat", .italic = true, .classes = "Latn", .language = "en", .direction = "ltr", .role = .headword }};
    const blocks = [_]types.Block{.{ .kind = .definition, .spans = &spans }};
    const sections = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &blocks }};
    const senses = [_]types.Sense{.{ .block = 0 }};
    const lexemes = [_]types.Lexeme{.{ .language = "English", .kind = "Noun", .section = 0, .definitions = &senses }};
    const stored: types.Stored = .{ .entry = .{
        .organization = .{ .lexemes = &lexemes },
        .title = "cat",
        .display_title = &display_title,
        .kind = .language,
        .language = "English",
        .language_code = "en",
        .sections = &sections,
    } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("cat", decoded.entry.title);
    try std.testing.expectEqualStrings("English", decoded.entry.language.?);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.display_title.len);
    try std.testing.expect(decoded.entry.display_title[0].italic);
    try std.testing.expectEqualStrings("cat", decoded.entry.display_title[0].text);
    try std.testing.expectEqualStrings("Latn", decoded.entry.display_title[0].classes);
    try std.testing.expectEqualStrings("en", decoded.entry.display_title[0].language);
    try std.testing.expectEqualStrings("ltr", decoded.entry.display_title[0].direction);
    try std.testing.expectEqual(types.BlockKind.definition, decoded.entry.sections[0].blocks[0].kind);
    try std.testing.expect(decoded.entry.sections[0].blocks[0].spans[0].bold);
    try std.testing.expectEqualStrings("cat", decoded.entry.sections[0].blocks[0].spans[0].target);
}

test "binary presentation codec borrows decoded strings" {
    const a = std.testing.allocator;
    const spans = [_]types.Span{.{ .text = "borrow-me" }};
    const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans }};
    const sections = [_]types.Section{.{ .level = 1, .title = "body", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "cat", .kind = .citations, .sections = &sections } };
    const bytes = try encodeAlloc(a, stored);
    defer a.free(bytes);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const expected_title = "cat";
    const decoded = try decodeAlloc(arena.allocator(), bytes, expected_title, .citations, null);
    const text = decoded.entry.sections[0].blocks[0].spans[0].text;
    const payload_start = @intFromPtr(bytes.ptr);
    const payload_end = payload_start + bytes.len;
    const text_ptr = @intFromPtr(text.ptr);
    try std.testing.expect(text_ptr >= payload_start and text_ptr + text.len <= payload_end);
    try std.testing.expectEqual(@intFromPtr(expected_title.ptr), @intFromPtr(decoded.entry.title.ptr));
}

test "binary presentation codec preserves composite semantic fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{
        .kind = .external_link,
        .role = .quotation,
        .text = "quoted",
        .target = "https://example.invalid",
        .trail = "!",
        .language = "en",
        .bold = true,
        .italic = true,
        .code = true,
        .small = true,
        .superscript = true,
        .subscript = true,
        .strike = true,
        .underline = true,
    }};
    const cells = [_]types.Cell{.{ .header = true, .colspan = 2, .rowspan = 3, .spans = &spans }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{
        .{
            .kind = .definition,
            .depth = 2,
            .level = 3,
            .spans = &spans,
            .feature = .{ .kind = "audio", .language = "en", .data = "Cat.ogg", .tail_kind = "label", .tail = "RP" },
            .list_path = "##",
            .number = "2",
            .table = .{ .caption = &spans, .rows = &rows },
        },
        .{ .kind = .example, .spans = &spans },
        .{ .kind = .table, .depth = 2, .list_path = "::", .table = .{ .caption = &spans } },
    };
    const sections = [_]types.Section{
        .{ .level = 3, .title = "Etymology" },
        .{ .level = 3, .title = "Noun", .blocks = &blocks },
    };
    const examples = [_]usize{1};
    const senses = [_]types.Sense{.{
        .block = 0,
        .examples = &examples,
        .form = .{ .relation = "plural", .target = "cats", .language = "en" },
    }};
    const intro = [_]usize{1};
    const related = [_]usize{0};
    const lexemes = [_]types.Lexeme{.{
        .language = "English",
        .kind = "Noun",
        .section = 1,
        .etymology = 0,
        .definitions = &senses,
        .introduction = &intro,
        .related_sections = &related,
    }};
    const other_sections = [_]usize{0};
    const references = [_]types.Reference{.{ .number = 1, .group_number = 2, .name = "ref", .group = "notes", .spans = &spans }};
    const media = [_]types.Media{
        .{ .file = "Cat.svg", .kind = .image, .caption = "A cat" },
        .{ .file = "Cat.ogg", .kind = .audio, .caption = "Pronunciation" },
    };
    const stored: types.Stored = .{ .entry = .{
        .organization = .{ .lexemes = &lexemes, .other_sections = &other_sections },
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
        .sections = &sections,
        .preamble_spans = &spans,
        .references = &references,
        .media = &media,
    } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    var metrics: DecodeMetrics = .{};
    const measured = try decodeWithMetricsAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" }, &metrics);
    // Nested table rows/cells/spans, lexical indices, references and media all
    // contribute to Android's per-record aggregate count budget.
    try std.testing.expectEqual(@as(u64, 23), metrics.total_items);
    try std.testing.expectEqual("https://example.invalid".len, metrics.largest_string_bytes);
    const measured_json = try std.json.Stringify.valueAlloc(a, measured, .{});
    const ordinary_json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expectEqualStrings(ordinary_json, measured_json);
    const span = decoded.entry.sections[1].blocks[0].spans[0];
    try std.testing.expect(span.bold and span.italic and span.code and span.small and span.superscript and span.subscript and span.strike and span.underline);
    try std.testing.expectEqual(types.Role.quotation, span.role);
    try std.testing.expectEqualStrings("https://example.invalid", span.target);
    try std.testing.expectEqualStrings("audio", decoded.entry.sections[1].blocks[0].feature.?.kind);
    try std.testing.expectEqual(@as(u16, 2), decoded.entry.sections[1].blocks[0].table.?.rows[0].cells[0].colspan);
    try std.testing.expectEqualStrings("cats", decoded.entry.organization.lexemes[0].definitions[0].form.?.target);
    try std.testing.expectEqual(@as(?u32, 2), decoded.entry.references[0].group_number);
    try std.testing.expectEqual(types.MediaKind.audio, decoded.entry.media[1].kind);
    const caption_only = decoded.entry.sections[1].blocks[2];
    try std.testing.expectEqual(types.BlockKind.table, caption_only.kind);
    try std.testing.expectEqual(@as(u8, 2), caption_only.depth);
    try std.testing.expectEqualStrings("::", caption_only.list_path);
    try std.testing.expectEqual(@as(usize, 0), caption_only.table.?.rows.len);
    try std.testing.expectEqual(@as(usize, 1), caption_only.table.?.caption.len);
    const caption_span = caption_only.table.?.caption[0];
    try std.testing.expectEqual(types.InlineKind.external_link, caption_span.kind);
    try std.testing.expectEqualStrings("quoted", caption_span.text);
    try std.testing.expectEqualStrings("https://example.invalid", caption_span.target);
    try std.testing.expectEqualStrings("en", caption_span.language);
    try std.testing.expect(caption_span.bold and caption_span.italic);

    const expected_json = try std.json.Stringify.valueAlloc(a, stored, .{});
    const decoded_json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expectEqualStrings(expected_json, decoded_json);
}

test "binary presentation codec rejects encoder collection overflow" {
    var encoder: Encoder = .{ .a = std.testing.allocator };
    defer encoder.deinit();
    try std.testing.expectError(error.PresentationTooLarge, encoder.count(max_items + 1));
}

test "binary presentation codec keeps string and collection limits independent" {
    const a = std.testing.allocator;
    const value = try a.alloc(u8, max_items + 1);
    defer a.free(value);
    @memset(value, 'x');
    var encoder: Encoder = .{ .a = a };
    defer encoder.deinit();
    try encoder.string(value);
    try std.testing.expectEqual(@as(usize, 4 + value.len), encoder.out.items.len);
}

test "binary presentation codec rejects invalid UTF-8 strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored: types.Stored = .{ .entry = .{
        .title = "cat",
        .kind = .citations,
        .sections = &.{.{ .level = 1, .title = "x" }},
    } };
    const bytes = try encodeAlloc(a, stored);
    const damaged = try a.dupe(u8, bytes);
    const title_at = magic.len + 4 + 1 + 4;
    damaged[title_at] = 0xff;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, damaged, "cat", .citations, null));
}

test "binary presentation codec rejects invalid framing and trailing bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, "{}", "cat", .citations, null));
    const stored: types.Stored = .{ .entry = .{ .title = "cat", .kind = .citations } };
    const bytes = try encodeAlloc(a, stored);
    const damaged = try std.mem.concat(a, u8, &.{ bytes, "x" });
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, damaged, "cat", .citations, null));
}

test "failed presentation decoding never commits successful metrics" {
    var metrics: DecodeMetrics = .{ .total_items = 99, .largest_string_bytes = 77 };
    try std.testing.expectError(error.InvalidPresentation, decodeWithMetricsAlloc(std.testing.allocator, "DPR2", "x", .supplemental, null, &metrics));
    try std.testing.expectEqual(@as(u64, 99), metrics.total_items);
    try std.testing.expectEqual(@as(usize, 77), metrics.largest_string_bytes);
}

test "sparse table observations preserve global boundaries and rowspan placement" {
    const a = std.testing.allocator;
    var broad: [6]types.Cell = undefined;
    @memset(&broad, .{ .colspan = 100 });
    const broad_rows = [_]types.Row{.{ .cells = &broad }};
    const wide = measureTableGrid(.{ .rows = &broad_rows });
    try std.testing.expectEqual(@as(?usize, 6), wide.exact_compact_columns);
    try std.testing.expectEqual(@as(usize, 1), wide.occupied_rows);
    const first = [_]types.Cell{ .{ .colspan = 100, .rowspan = 2 }, .{ .colspan = 100 } };
    const second = [_]types.Cell{ .{ .colspan = 50 }, .{ .colspan = 50 } };
    const split_rows = [_]types.Row{ .{ .cells = &first }, .{ .cells = &second } };
    const split = measureTableGrid(.{ .rows = &split_rows });
    try std.testing.expectEqual(@as(?usize, 3), split.exact_compact_columns);
    try std.testing.expectEqual(@as(usize, 2), split.occupied_rows);
    const old_a = [_]types.Cell{ .{ .rowspan = 2 }, .{ .colspan = 2 } };
    const old_b = [_]types.Cell{ .{}, .{} };
    const old_c = [_]types.Cell{ .{}, .{}, .{} };
    const old_rows = [_]types.Row{ .{ .cells = &old_a }, .{ .cells = &old_b }, .{ .cells = &old_c } };
    try std.testing.expectEqual(@as(?usize, 3), measureTableGrid(.{ .rows = &old_rows }).exact_compact_columns);
    try std.testing.expectEqual(@as(?usize, 0), measureTableGrid(.{}).exact_compact_columns);
    const empty_rows = [_]types.Row{ .{}, .{} };
    try std.testing.expectEqual(@as(usize, 2), measureTableGrid(.{ .rows = &empty_rows }).occupied_rows);
    const trailing = [_]types.Cell{.{ .rowspan = 100 }};
    const trailing_rows = [_]types.Row{.{ .cells = &trailing }};
    try std.testing.expectEqual(@as(usize, 100), measureTableGrid(.{ .rows = &trailing_rows }).occupied_rows);
    const cells = try a.alloc(types.Cell, 513);
    defer a.free(cells);
    @memset(cells, .{ .colspan = 100 });
    const exact_rows = [_]types.Row{.{ .cells = cells[0..512] }};
    try std.testing.expectEqual(@as(?usize, 512), measureTableGrid(.{ .rows = &exact_rows }).exact_compact_columns);
    cells[512].rowspan = 100;
    const saturated_rows = [_]types.Row{ .{ .cells = cells }, .{}, .{} };
    const saturated = measureTableGrid(.{ .rows = &saturated_rows });
    try std.testing.expect(saturated.column_limit_exceeded);
    try std.testing.expect(saturated.exact_compact_columns == null);
    try std.testing.expectEqual(@as(usize, 513), saturated.columns_lower_bound);
    try std.testing.expectEqual(@as(usize, 100), saturated.occupied_rows);
}

test "unsupported spans remain ordinary decode values while observation is explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]types.Cell{ .{ .colspan = 0 }, .{ .colspan = 101 }, .{ .rowspan = 0 }, .{ .rowspan = 101 } }) |cell| {
        const cells = [_]types.Cell{cell};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
        const sections = [_]types.Section{.{ .level = 2, .title = "Table", .blocks = &blocks }};
        const stored: types.Stored = .{ .entry = .{ .title = "table", .kind = .supplemental, .sections = &sections } };
        const payload = try encodeAlloc(a, stored);
        const ordinary = try decodeAlloc(a, payload, "table", .supplemental, null);
        var metrics: DecodeMetrics = .{};
        const measured = try decodeWithMetricsAlloc(a, payload, "table", .supplemental, null, &metrics);
        try std.testing.expectEqual(ordinary.entry.sections[0].blocks[0].table.?.rows[0].cells[0].colspan, measured.entry.sections[0].blocks[0].table.?.rows[0].cells[0].colspan);
        try std.testing.expect(!metrics.table_spans_supported);
        try std.testing.expect(metrics.table_columns_exact == null);
        try std.testing.expect(!metrics.table_column_limit_exceeded);
        try std.testing.expectEqual(@as(usize, 1), metrics.tables);
    }
}

test "table observations preserve round trips and do not commit failed decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [6]types.Cell = undefined;
    @memset(&cells, .{ .colspan = 100 });
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Table", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "wide", .kind = .supplemental, .sections = &sections } };
    const payload = try encodeAlloc(a, stored);
    const ordinary = try decodeAlloc(a, payload, "wide", .supplemental, null);
    var metrics: DecodeMetrics = .{};
    const measured = try decodeWithMetricsAlloc(a, payload, "wide", .supplemental, null, &metrics);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, ordinary, .{}), try std.json.Stringify.valueAlloc(a, measured, .{}));
    try std.testing.expectEqual(@as(?usize, 6), metrics.table_columns_exact);
    try std.testing.expectEqual(@as(usize, 1), metrics.max_table_rows);
    try std.testing.expectEqual(@as(u16, 100), metrics.max_table_colspan);
    const corrupt = try a.alloc(u8, payload.len + 1);
    @memcpy(corrupt[0..payload.len], payload);
    corrupt[payload.len] = 0;
    metrics.table_columns_exact = 77;
    metrics.tables = 99;
    try std.testing.expectError(error.InvalidPresentation, decodeWithMetricsAlloc(a, corrupt, "wide", .supplemental, null, &metrics));
    try std.testing.expectEqual(@as(?usize, 77), metrics.table_columns_exact);
    try std.testing.expectEqual(@as(usize, 99), metrics.tables);
}

test "legacy DPR2 compact spans remain readable and byte identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Independently framed pre-extension DPR2: eight minimal empty spans and
    // six empty following lists. This also distinguishes the 27/31 minimum.
    const legacy = "\x44\x50\x52\x32\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const parsed = try decodeAlloc(a, legacy, "entry", .supplemental, null);
    try std.testing.expectEqualStrings("dict.presentation.v3", parsed.schema);
    try std.testing.expectEqual(@as(usize, 8), parsed.entry.display_title.len);
    for (parsed.entry.display_title) |span_value| try std.testing.expectEqualStrings("", span_value.explanation);
    try std.testing.expectEqualStrings(legacy, try encodeAlloc(a, parsed));
    try std.testing.expectEqualStrings(legacy, try encodeBuildAlloc(a, parsed.entry.display_title, parsed.entry.sections, parsed.entry.organization, parsed.entry.references, parsed.entry.media));
}

test "DPR3 explanations traverse every stored span container and reject corrupt fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const note = "feminine gender explanation";
    const annotated = [_]types.Span{.{ .kind = .link, .text = "f", .target = "glossary", .explanation = note, .italic = true }};
    const blank: []const types.Span = &.{};
    for (0..6) |location| {
        const cells = [_]types.Cell{.{ .spans = if (location == 3) &annotated else blank }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const table_value: types.Table = .{ .caption = if (location == 2) &annotated else blank, .rows = &rows };
        const blocks = [_]types.Block{.{ .kind = .table, .spans = if (location == 1) &annotated else blank, .table = table_value }};
        const sections_value = [_]types.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 4) &annotated else blank }};
        const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .display_title = if (location == 0) &annotated else blank, .sections = &sections_value, .preamble_spans = if (location == 5) &annotated else blank, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(explained_magic, bytes[0..4]);
        var metrics: DecodeMetrics = .{};
        const parsed = try decodeWithMetricsAlloc(a, bytes, "entry", .supplemental, null, &metrics);
        const actual = switch (location) {
            0 => parsed.entry.display_title[0],
            1 => parsed.entry.sections[0].blocks[0].spans[0],
            2 => parsed.entry.sections[0].blocks[0].table.?.caption[0],
            3 => parsed.entry.sections[0].blocks[0].table.?.rows[0].cells[0].spans[0],
            4 => parsed.entry.references[0].spans[0],
            else => parsed.entry.preamble_spans[0],
        };
        try std.testing.expectEqualStrings(note, actual.explanation);
        try std.testing.expectEqualStrings("f", actual.text);
        try std.testing.expectEqualStrings("glossary", actual.target);
        try std.testing.expect(actual.italic and actual.kind == .link);
        try std.testing.expectEqual(note.len, metrics.largest_string_bytes);
        const built = try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media);
        if (location != 5) try std.testing.expectEqualStrings(bytes, built) else try std.testing.expectEqualStrings(magic, built[0..4]);
        const at = std.mem.indexOf(u8, bytes, note).?;
        const invalid = try a.dupe(u8, bytes);
        invalid[at] = 0xff;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invalid, "entry", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. at + note.len - 1], "entry", .supplemental, null));
        const oversized = try a.dupe(u8, bytes);
        std.mem.writeInt(u32, oversized[at - 4 ..][0..4], max_string_bytes + 1, .little);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, oversized, "entry", .supplemental, null));
        const unknown = try a.dupe(u8, bytes);
        unknown[3] = '9';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "entry", .supplemental, null));
    }
}

test "DPR4 RGB fields roundtrip every span container and preserve legacy table bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = "\x44\x50\x52\x32\x00\x00\x00\x00\x01\x00\x00\x00\x02\x06\x00\x00\x00\x63\x6f\x6c\x6f\x72\x73\x01\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x01\x00\x01\x00\x01\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\xc2\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const old = try decodeAlloc(a, legacy, "colors", .supplemental, null);
    const old_cell = old.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
    try std.testing.expect(old_cell.background == null and old_cell.spans[0].foreground == null);
    try std.testing.expectEqualStrings(" ", old_cell.spans[0].text);
    try std.testing.expectEqualStrings(legacy, try encodeAlloc(a, old));
    try std.testing.expectEqualStrings(legacy, try encodeBuildAlloc(a, old.entry.display_title, old.entry.sections, old.entry.organization, old.entry.references, old.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"background\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"foreground\":null") != null);
    const note = "authored dialect explanation";
    const annotated = [_]types.Span{.{ .kind = .link, .text = "dialect", .target = "A", .foreground = "#1c39bb", .explanation = note, .italic = true }};
    const ordinary = [_]types.Span{.{ .text = "plain" }};
    for (0..7) |location| {
        const cells = [_]types.Cell{ .{ .spans = if (location == 3) &annotated else &ordinary, .background = if (location == 6) "#eeeeee" else null }, .{ .spans = &ordinary } };
        const rows = [_]types.Row{.{ .cells = &cells }};
        const table: types.Table = .{ .caption = if (location == 2) &annotated else &ordinary, .rows = &rows };
        const blocks = [_]types.Block{.{ .kind = .table, .spans = if (location == 1) &annotated else &ordinary, .table = table }};
        const sections = [_]types.Section{.{ .level = 2, .title = "colors", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 4) &annotated else &ordinary }};
        const stored: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = if (location == 0) &annotated else &ordinary, .sections = &sections, .preamble_spans = if (location == 5) &annotated else &ordinary, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(color_magic, bytes[0..4]);
        // The archived reader recognizes only DPR2/DPR3, so this new record
        // cannot silently enter its old cell/span decoder.
        try std.testing.expect(!std.mem.eql(u8, bytes[0..4], magic) and !std.mem.eql(u8, bytes[0..4], explained_magic));
        var metrics: DecodeMetrics = .{};
        const parsed = try decodeWithMetricsAlloc(a, bytes, "colors", .supplemental, null, &metrics);
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, parsed, .{}));
        try std.testing.expect(parsed.entry.sections[0].blocks[0].table.?.rows[0].cells[1].background == null);
        try std.testing.expect(parsed.entry.sections[0].blocks[0].table.?.rows[0].cells[1].spans[0].foreground == null);
        try std.testing.expectEqualStrings(bytes, try encodeAlloc(a, parsed));
        const built = try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media);
        const built_parsed = try decodeAlloc(a, built, "colors", .supplemental, null);
        var built_expected = stored;
        built_expected.entry.preamble_spans = &.{};
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, built_expected, .{}), try std.json.Stringify.valueAlloc(a, built_parsed, .{}));
        try std.testing.expectEqualStrings(if (location == 5) magic else color_magic, built[0..4]);

        const selected = if (location == 6) "#eeeeee" else "#1c39bb";
        const at = std.mem.indexOf(u8, bytes, selected).?;
        const corrupt = try a.dupe(u8, bytes);
        corrupt[at + 1] = 'G';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, corrupt, "colors", .supplemental, null));
        const bad_presence = try a.dupe(u8, bytes);
        bad_presence[at - 5] = 2;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad_presence, "colors", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. bytes.len - 1], "colors", .supplemental, null));
        const unknown = try a.dupe(u8, bytes);
        unknown[3] = '9';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "colors", .supplemental, null));
    }
    const invalid = [_]types.Span{.{ .text = "invalid", .foreground = "red" }};
    const invalid_stored: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = &invalid } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, invalid_stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, invalid_stored, "colors", .supplemental, null));
}

test "DPR5 preserves section and standalone heading anchors with rich fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = [_]types.Block{
        .{ .kind = .heading, .level = 3, .anchor = "Usage_notes_2", .anchor_fallback = "Usage.20notes_2", .spans = &.{.{ .text = "Usage notes", .explanation = "note", .foreground = "#123abc" }} },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "body" }} },
        .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .background = "#abcdef", .spans = &.{.{ .text = "cell", .foreground = "#123abc" }} }} }} } },
    };
    const sections = [_]types.Section{.{ .level = 2, .title = "English", .anchor = "English_2", .anchor_fallback = "English.202", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "test", .kind = .supplemental, .sections = &sections } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(anchor_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("English_2", decoded.entry.sections[0].anchor);
    const heading = decoded.entry.sections[0].blocks[0];
    try std.testing.expectEqualStrings("Usage_notes_2", heading.anchor);
    try std.testing.expectEqualStrings("Usage.20notes_2", heading.anchor_fallback);
    try std.testing.expectEqualStrings("English.202", decoded.entry.sections[0].anchor_fallback);
    try std.testing.expectEqualStrings("note", heading.spans[0].explanation);
    try std.testing.expectEqualStrings("#123abc", heading.spans[0].foreground.?);
    try std.testing.expectEqualStrings("", decoded.entry.sections[0].blocks[1].anchor);
    const cell = decoded.entry.sections[0].blocks[2].table.?.rows[0].cells[0];
    try std.testing.expectEqualStrings("#abcdef", cell.background.?);
    try std.testing.expectEqualStrings("#123abc", cell.spans[0].foreground.?);
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor\":\"English_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor\":\"Usage_notes_2\"") != null);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const built = try encodeBuildAlloc(a, stored.entry.display_title, &sections, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualSlices(u8, bytes, built);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor_fallback\":\"English.202\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor_fallback\":\"Usage.20notes_2\"") != null);
    const malformed_fallback = try a.dupe(u8, bytes);
    malformed_fallback[std.mem.indexOf(u8, malformed_fallback, "Usage.20notes_2").?] = 0xff;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, malformed_fallback, "test", .supplemental, null));
    const FallbackSection = struct { level: u8, title: []const u8, anchor_fallback: []const u8, blocks: []const types.Block = &.{} };
    const fallback_sections = [_]FallbackSection{.{ .level = 2, .title = "English", .anchor_fallback = "English.202" }};
    const fallback_bytes = try encodeBuildAlloc(a, stored.entry.display_title, &fallback_sections, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualStrings(anchor_magic, fallback_bytes[0..4]);
    const fallback_decoded = try decodeAlloc(a, fallback_bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("", fallback_decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("English.202", fallback_decoded.entry.sections[0].anchor_fallback);
    const malformed = try a.dupe(u8, bytes);
    const anchor_offset = std.mem.indexOf(u8, malformed, "English_2").?;
    malformed[anchor_offset] = 0xff;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, malformed, "test", .supplemental, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. bytes.len - 1], "test", .supplemental, null));
    const standalone = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &blocks }};
    const standalone_bytes = try encodeBuildAlloc(a, stored.entry.display_title, &standalone, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualStrings(anchor_magic, standalone_bytes[0..4]);
    const fallback_blocks = [_]types.Block{.{ .kind = .heading, .anchor_fallback = "Usage.20notes" }};
    const fallback_block_sections = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &fallback_blocks }};
    const fallback_block_bytes = try encodeBuildAlloc(a, stored.entry.display_title, &fallback_block_sections, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualStrings(anchor_magic, fallback_block_bytes[0..4]);
    const fallback_block_decoded = try decodeAlloc(a, fallback_block_bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("Usage.20notes", fallback_block_decoded.entry.sections[0].blocks[0].anchor_fallback);
    const invalid_blocks = [_]types.Block{.{ .kind = .paragraph, .anchor_fallback = "invalid" }};
    const invalid_sections = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &invalid_blocks }};
    try std.testing.expectError(error.InvalidPresentation, encodeBuildAlloc(a, stored.entry.display_title, &invalid_sections, stored.entry.organization, stored.entry.references, stored.entry.media));
}

test "legacy generic sections without anchors retain DPR2 and decode empty anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const LegacySection = struct { level: u8, title: []const u8, blocks: []const types.Block = &.{} };
    const sections = [_]LegacySection{.{ .level = 2, .title = "English" }};
    const bytes = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, @as(types.Layout, .{}), @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualStrings(magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
}

test "DPR6 span backgrounds roundtrip every container with anchors and legacy fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const painted = [_]types.Span{.{ .kind = .link, .text = "painted", .target = "Target", .trail = "s", .background = "#123456", .foreground = "#654321", .explanation = "note", .italic = true }};
    const ordinary = [_]types.Span{.{ .text = "plain" }};
    for (0..6) |location| {
        const cells = [_]types.Cell{
            .{ .spans = if (location == 3) &painted else &ordinary, .background = "#eeeeee" },
            .{ .spans = &ordinary },
        };
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{
            .{ .kind = .heading, .level = 3, .anchor = "Heading_2", .anchor_fallback = "Heading.202", .spans = if (location == 1) &painted else &ordinary },
            .{ .kind = .table, .table = .{ .caption = if (location == 2) &painted else &ordinary, .rows = &rows } },
        };
        const sections = [_]types.Section{.{ .level = 2, .title = "colors", .anchor = "colors", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 4) &painted else &ordinary }};
        const stored: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = if (location == 0) &painted else &ordinary, .sections = &sections, .preamble_spans = if (location == 5) &painted else &ordinary, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(background_magic, bytes[0..4]);
        const parsed = try decodeAlloc(a, bytes, "colors", .supplemental, null);
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, parsed, .{}));
        try std.testing.expectEqualStrings("colors", parsed.entry.sections[0].anchor);
        try std.testing.expectEqualStrings("Heading_2", parsed.entry.sections[0].blocks[0].anchor);
        try std.testing.expectEqualStrings("Heading.202", parsed.entry.sections[0].blocks[0].anchor_fallback);
        try std.testing.expectEqualStrings("#eeeeee", parsed.entry.sections[0].blocks[1].table.?.rows[0].cells[0].background.?);
        try std.testing.expect(parsed.entry.sections[0].blocks[1].table.?.rows[0].cells[1].spans[0].background == null);
        try std.testing.expectEqualStrings(bytes, try encodeAlloc(a, parsed));
        const built = try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media);
        try std.testing.expectEqualStrings(if (location == 5) anchor_magic else background_magic, built[0..4]);
        const built_parsed = try decodeAlloc(a, built, "colors", .supplemental, null);
        var expected = stored;
        expected.entry.preamble_spans = &.{};
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, expected, .{}), try std.json.Stringify.valueAlloc(a, built_parsed, .{}));
        const at = std.mem.indexOf(u8, bytes, "#123456").?;
        const corrupt = try a.dupe(u8, bytes);
        corrupt[at + 1] = 'G';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, corrupt, "colors", .supplemental, null));
        const presence = try a.dupe(u8, bytes);
        presence[at - 5] = 2;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, presence, "colors", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. at + 3], "colors", .supplemental, null));
    }
    const invalid = [_]types.Span{.{ .text = "invalid", .background = "red" }};
    const bad: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = &invalid } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, bad));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, bad, "colors", .supplemental, null));
    // Independently framed eight minimal DPR6 spans are exactly 33 bytes each.
    var minimal: [4 + 4 + 8 * 33 + 6 * 4]u8 = @splat(0);
    @memcpy(minimal[0..4], background_magic);
    minimal[4] = 8;
    const compact = try decodeAlloc(a, &minimal, "colors", .supplemental, null);
    try std.testing.expectEqual(@as(usize, 8), compact.entry.display_title.len);
    for (compact.entry.display_title) |span| try std.testing.expect(span.background == null);
}

test "absent span backgrounds preserve established JSON and legacy selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const span: types.Span = .{ .text = "plain" };
    // H adds tooltip:null to JSON even when legacy wire selection remains unchanged.
    const legacy_json = "{\"kind\":\"text\",\"text\":\"plain\",\"target\":\"\",\"trail\":\"\",\"language\":\"\",\"classes\":\"\",\"direction\":\"\",\"explanation\":\"\",\"tooltip\":null,\"foreground\":null,\"bold\":false,\"italic\":false,\"code\":false,\"small\":false,\"superscript\":false,\"subscript\":false,\"strike\":false,\"underline\":false,\"role\":\"normal\"}";
    try std.testing.expectEqualStrings(legacy_json, try std.json.Stringify.valueAlloc(a, span, .{}));
    var annotated = span;
    annotated.background = "#abcdef";
    const json = try std.json.Stringify.valueAlloc(a, annotated, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"background\":\"#abcdef\"") != null);
    const values = [_]types.Span{span};
    const plain: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = &values } };
    const bytes = try encodeAlloc(a, plain);
    try std.testing.expectEqualStrings(magic, bytes[0..4]);
    const parsed = try decodeAlloc(a, bytes, "colors", .supplemental, null);
    try std.testing.expect(parsed.entry.display_title[0].background == null);
    try std.testing.expectEqualStrings(bytes, try encodeAlloc(a, parsed));
}

// Offsource nested-grid controls. These have not been executed during preparation.
test "DPR7 nested empty painted header and authored zero geometry round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child_cells = [_]types.Cell{
        .{ .header = true, .background = "#efafef" },
        .{ .spans = &.{.{ .kind = .link, .text = "form", .target = "acan", .explanation = "source action", .background = "#efefef" }} },
    };
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const outer_cells = [_]types.Cell{.{ .nested_table = .{
        .rows = &child_rows,
        .geometry = .{ .border = 1, .cell_padding = 2, .width = .{ .unit = .percent, .value = 100 } },
    } }};
    const outer_rows = [_]types.Row{.{ .cells = &outer_cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{
        .rows = &outer_rows,
        .geometry = .{ .border = 0, .cell_spacing = 15 },
    } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Unclassified", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "nested", .kind = .language, .language = "Unclassified", .sections = &sections } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(nested_magic, encoded[0..4]);
    var metrics: DecodeMetrics = .{};
    const decoded = try decodeWithMetricsAlloc(a, encoded, "nested", .language, .{ .code = "", .heading = "Unclassified" }, &metrics);
    const outer = decoded.entry.sections[0].blocks[0].table.?;
    try std.testing.expectEqual(@as(?u16, 0), outer.geometry.?.border);
    try std.testing.expectEqual(@as(?u16, 15), outer.geometry.?.cell_spacing);
    try std.testing.expect(outer.geometry.?.cell_padding == null);
    try std.testing.expectEqual(@as(usize, 0), outer.rows[0].cells[0].spans.len);
    const child = outer.rows[0].cells[0].nested_table.?;
    try std.testing.expectEqual(@as(?u16, 1), child.geometry.?.border);
    try std.testing.expectEqual(@as(?u16, 2), child.geometry.?.cell_padding);
    try std.testing.expectEqual(types.TableWidthUnit.percent, child.geometry.?.width.?.unit);
    try std.testing.expectEqual(@as(u32, 100), child.geometry.?.width.?.value);
    try std.testing.expect(child.rows[0].cells[0].header);
    try std.testing.expectEqual(@as(usize, 0), child.rows[0].cells[0].spans.len);
    try std.testing.expectEqualStrings("#efafef", child.rows[0].cells[0].background.?);
    try std.testing.expectEqualStrings("acan", child.rows[0].cells[1].spans[0].target);
    try std.testing.expectEqualStrings("source action", child.rows[0].cells[1].spans[0].explanation);
    try std.testing.expectEqualStrings("#efefef", child.rows[0].cells[1].spans[0].background.?);
    try std.testing.expectEqual(@as(usize, 2), metrics.tables);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
}

test "legacy flat cell and table JSON omit all extension fields" {
    const a = std.testing.allocator;
    const cell_json = try std.json.Stringify.valueAlloc(a, types.Cell{}, .{});
    defer a.free(cell_json);
    try std.testing.expectEqualStrings("{\"spans\":[],\"header\":false,\"colspan\":1,\"rowspan\":1,\"background\":null}", cell_json);
    const table_json = try std.json.Stringify.valueAlloc(a, types.Table{}, .{});
    defer a.free(table_json);
    try std.testing.expectEqualStrings("{\"caption\":[],\"rows\":[]}", table_json);
}

test "DPR7 rejects mixed nested spans invalid geometry and excess table depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [17][1]types.Cell = undefined;
    var rows: [17][1]types.Row = undefined;
    var tables: [17]types.Table = undefined;
    var i: usize = 17;
    while (i != 0) {
        i -= 1;
        cells[i] = .{.{ .nested_table = if (i + 1 < tables.len) tables[i + 1] else null }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .rows = &rows[i] };
    }
    var blocks = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const sections = [_]types.Section{.{ .level = 2, .title = "U", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .language, .language = "U", .sections = &sections } };
    const sixteen = try encodeAlloc(a, stored);
    _ = try decodeAlloc(a, sixteen, "depth", .language, .{ .code = "", .heading = "U" });
    blocks[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    blocks[0].table = .{ .geometry = .{ .width = .{ .unit = .percent, .value = 101 } } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    const mixed_cells = [_]types.Cell{.{ .spans = &.{.{ .text = "must not disappear" }}, .nested_table = .{} }};
    const mixed_rows = [_]types.Row{.{ .cells = &mixed_cells }};
    blocks[0].table = .{ .rows = &mixed_rows };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
}

test "DPR7 collection counts share one item budget" {
    var encoder: Encoder = .{ .a = std.testing.allocator, .version = .nested_tables, .remaining_items = 1 };
    defer encoder.deinit();
    try encoder.count(1);
    try std.testing.expectError(error.PresentationTooLarge, encoder.count(1));
    var reader: Reader = .{ .a = std.testing.allocator, .version = .nested_tables, .bytes = &.{ 1, 0, 0, 0, 1, 0, 0, 0 }, .remaining_items = 1 };
    try std.testing.expectEqual(@as(usize, 1), try reader.count(0));
    try std.testing.expectError(error.InvalidPresentation, reader.count(0));
}

test "DPR8 ordered cell blocks retain headings actions paint and nested metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child_cells = [_]types.Cell{.{ .spans = &.{.{ .kind = .link, .text = "inner", .target = "Inner", .trail = "s", .background = "#ffffe0" }} }};
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const contents = [_]types.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "before" }} },
        .{ .kind = .heading, .level = 3, .anchor = "翻訳_2", .anchor_fallback = ".E7.BF.BB.E8.A8.B3_2", .spans = &.{.{ .text = "翻訳", .bold = true }} },
        .{ .kind = .list_item, .depth = 2, .list_path = "*#", .number = "2", .spans = &.{.{ .kind = .link, .text = "item", .target = "Item", .explanation = "retained action" }} },
        .{ .kind = .rule },
        .{ .kind = .table, .table = .{ .rows = &child_rows, .geometry = .{ .width = .{ .unit = .percent, .value = 50 } } } },
        .{ .kind = .paragraph, .feature = .{ .kind = "tail", .data = "compiled" }, .spans = &.{.{ .text = "after", .foreground = "#123456" }} },
    };
    const cells = [_]types.Cell{
        .{ .header = true, .background = "#fffdd0", .blocks = &contents },
        .{ .blocks = &.{} },
        .{ .spans = &.{.{ .text = "legacy neighbor" }} },
    };
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "English", .anchor = "English", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "ordered", .kind = .supplemental, .sections = &sections } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(cell_blocks_magic, encoded[0..4]);
    var metrics: DecodeMetrics = .{};
    const decoded = try decodeWithMetricsAlloc(a, encoded, "ordered", .supplemental, null, &metrics);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqual(@as(usize, 2), metrics.tables);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
    const decoded_cells = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells;
    try std.testing.expectEqual(@as(usize, 6), decoded_cells[0].blocks.?.len);
    try std.testing.expectEqual(@as(u8, 3), decoded_cells[0].blocks.?[1].level);
    try std.testing.expectEqualStrings("翻訳_2", decoded_cells[0].blocks.?[1].anchor);
    try std.testing.expectEqual(@as(usize, 0), decoded_cells[1].blocks.?.len);
    try std.testing.expect(decoded_cells[2].blocks == null);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, encoded, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, stored.entry.organization, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{})));
    const json = try std.json.Stringify.valueAlloc(a, types.Cell{ .blocks = &.{} }, .{});
    try std.testing.expectEqualStrings("{\"spans\":[],\"header\":false,\"colspan\":1,\"rowspan\":1,\"background\":null,\"blocks\":[]}", json);
}

test "DPR8 presence and empty content preserve legacy cell framing" {
    const a = std.testing.allocator;
    const legacy = [_]u8{ 0, 1, 0, 1, 0, 0, 0, 0, 0 };
    for ([_]Version{ .plain, .explained, .colored, .anchored, .span_background, .nested_tables }) |version| {
        var encoder: Encoder = .{ .a = a, .version = version };
        defer encoder.deinit();
        try encoder.cell(types.Cell{});
        try std.testing.expectEqual(@as(usize, if (version == .nested_tables) 11 else if (hasRgb(version)) 10 else 9), encoder.out.items.len);
        try std.testing.expectEqualSlices(u8, &legacy, encoder.out.items[0..9]);
        for (encoder.out.items[9..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
    var encoder: Encoder = .{ .a = a, .version = .cell_blocks };
    defer encoder.deinit();
    try encoder.cell(types.Cell{ .blocks = &.{} });
    const present_empty = [_]u8{ 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &present_empty, encoder.out.items);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader: Reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = &present_empty };
    try std.testing.expectEqual(@as(usize, 0), (try reader.cell()).blocks.?.len);
    var invalid = present_empty;
    invalid[11] = 2;
    reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = &invalid };
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
    reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = present_empty[0..15] };
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
    // A present block vector cannot claim a 25-byte block from an empty tail.
    invalid = present_empty;
    invalid[12] = 1;
    reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = &invalid };
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
}

test "DPR8 rejects mixed cell modes and validates nested semantic colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells = [_]types.Cell{.{ .blocks = &.{}, .spans = &.{.{ .text = "preserve me" }} }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "U", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "modes", .kind = .supplemental, .sections = &sections } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "modes", .supplemental, null));
    cells[0] = .{ .blocks = &.{}, .nested_table = .{} };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "modes", .supplemental, null));
    cells[0] = .{ .blocks = &.{.{ .kind = .heading, .level = 3, .anchor = "Color", .spans = &.{.{ .text = "color", .background = "red" }} }} };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "modes", .supplemental, null));
    cells[0] = .{ .blocks = &.{.{ .kind = .paragraph, .anchor = "not a heading" }} };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "modes", .supplemental, null));
}

test "DPR8 cell block tables retain depth and shared collection limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [17][1]types.Cell = undefined;
    var rows: [17][1]types.Row = undefined;
    var tables: [17]types.Table = undefined;
    var contents: [17][1]types.Block = undefined;
    var i: usize = 17;
    while (i != 0) {
        i -= 1;
        contents[i] = .{.{ .kind = .table, .table = if (i + 1 < tables.len) tables[i + 1] else null }};
        cells[i] = .{.{ .blocks = &contents[i] }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .rows = &rows[i] };
    }
    var blocks = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const sections = [_]types.Section{.{ .level = 2, .title = "U", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .supplemental, .sections = &sections } };
    const sixteen = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(cell_blocks_magic, sixteen[0..4]);
    var metrics: DecodeMetrics = .{};
    _ = try decodeWithMetricsAlloc(a, sixteen, "depth", .supplemental, null, &metrics);
    try std.testing.expectEqual(@as(usize, 16), metrics.tables);
    // Starting inside an enclosing table must not reset depth at a cell Block.table.
    var nested_encoder: Encoder = .{ .a = a, .version = .cell_blocks };
    defer nested_encoder.deinit();
    try nested_encoder.table(@as(?types.Table, tables[15]));
    var nested_reader: Reader = .{ .a = a, .version = .cell_blocks, .bytes = nested_encoder.out.items, .table_depth = 14 };
    _ = try nested_reader.table();
    nested_reader = .{ .a = a, .version = .cell_blocks, .bytes = nested_encoder.out.items, .table_depth = 15 };
    try std.testing.expectError(error.InvalidPresentation, nested_reader.table());
    blocks[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "depth", .supplemental, null));
    var encoder: Encoder = .{ .a = a, .version = .cell_blocks, .remaining_items = 1 };
    defer encoder.deinit();
    try encoder.cell(types.Cell{ .blocks = &.{.{ .kind = .paragraph }} });
    const first = try a.dupe(u8, encoder.out.items);
    try std.testing.expectError(error.PresentationTooLarge, encoder.cell(types.Cell{ .blocks = &.{.{ .kind = .paragraph }} }));
    const two_cells = try std.mem.concat(a, u8, &.{ first, first });
    var reader: Reader = .{ .a = a, .version = .cell_blocks, .bytes = two_cells, .remaining_items = 1 };
    _ = try reader.cell();
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
    // The old per-string bound is unchanged in the new version.
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, max_string_bytes + 1, .little);
    reader = .{ .a = a, .version = .cell_blocks, .bytes = &length };
    try std.testing.expectError(error.InvalidPresentation, reader.string());
}

test "DPR9 reference fragments preserve footer order identities groups and rich bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rich = [_]types.Span{.{ .kind = .external_link, .text = "orphan", .target = "https://example.test/fragment", .bold = true, .explanation = "source note", .foreground = "#123456", .background = "#abcdef" }};
    const refs = [_]types.Reference{
        .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &rich },
        .{ .number = 2, .group_number = 1, .name = "parent", .group = "notes", .spans = &.{.{ .text = "numbered" }} },
    };
    const child = [_]types.Block{.{ .kind = .heading, .level = 3, .anchor = "child", .spans = &.{.{ .text = "Child" }} }};
    const cells = [_]types.Cell{.{ .blocks = &child }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Body", .anchor = "body", .blocks = &blocks }};
    const media = [_]types.Media{.{ .file = "Example.svg", .kind = .image, .caption = "caption" }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .sections = &sections, .references = &refs, .media = &media } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPR9", bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "entry", .supplemental, null);
    try std.testing.expectEqual(types.ReferenceKind.fragment, decoded.entry.references[0].kind);
    try std.testing.expectEqual(@as(usize, 8), decoded.entry.references[0].number);
    try std.testing.expectEqual(@as(?u32, null), decoded.entry.references[0].group_number);
    try std.testing.expectEqualStrings("", decoded.entry.references[0].name);
    try std.testing.expectEqualStrings("notes", decoded.entry.references[0].group);
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.references[1].number);
    try std.testing.expectEqual(@as(?u32, 1), decoded.entry.references[1].group_number);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    // The compiler path uses a distinct enum type with the same semantic names.
    const BuildKind = enum { note, fragment };
    const BuildReference = struct { kind: BuildKind = .note, number: usize, group_number: ?u32, name: []const u8 = "", group: []const u8 = "", spans: []const types.Span = &.{} };
    const build_refs = [_]BuildReference{.{ .kind = .fragment, .number = 7, .group_number = null, .spans = &rich }};
    const built = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &build_refs, @as([]const types.Media, &.{}));
    const build_decoded = try decodeAlloc(a, built, "entry", .supplemental, null);
    try std.testing.expectEqual(@as(usize, 7), build_decoded.entry.references[0].number);
    try std.testing.expectEqualStrings("https://example.test/fragment", build_decoded.entry.references[0].spans[0].target);
}

test "legacy note reference bytes and JSON stay unchanged without fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = [_]types.Reference{.{ .number = 9, .group_number = 2 }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .references = &refs } };
    // Independent legacy framing: five empty collections, one note, empty media.
    const legacy = "DPR2" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x01\x00\x00\x00\x09\x00\x00\x00\x02\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectEqualSlices(u8, legacy, try encodeAlloc(a, stored));
    const decoded = try decodeAlloc(a, legacy, "entry", .supplemental, null);
    try std.testing.expectEqual(types.ReferenceKind.note, decoded.entry.references[0].kind);
    try std.testing.expectEqualStrings("{\"number\":9,\"group_number\":2,\"name\":\"\",\"group\":\"\",\"spans\":[]}", try std.json.Stringify.valueAlloc(a, decoded.entry.references[0], .{}));
    try std.testing.expectEqualSlices(u8, legacy, try encodeAlloc(a, decoded));
}

test "DPR9 reference tags and semantic invariants reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = [_]types.Reference{.{ .kind = .fragment, .number = 1, .group_number = null }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .references = &refs } };
    const valid = try encodeAlloc(a, stored);
    // The first item follows magic, five empty collection counts and ref count.
    const tag_at = 28;
    try std.testing.expectEqual(@as(u8, 1), valid[tag_at]);
    const unknown = try a.dupe(u8, valid);
    unknown[tag_at] = 2;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "entry", .supplemental, null));
    const zero_id = try a.dupe(u8, valid);
    @memset(zero_id[tag_at + 1 .. tag_at + 5], 0);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, zero_id, "entry", .supplemental, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, valid[0 .. valid.len - 1], "entry", .supplemental, null));
    const invalid = [_]types.Reference{
        .{ .number = 1, .group_number = null },
        .{ .number = 1, .group_number = 0 },
        .{ .kind = .fragment, .number = 0, .group_number = null },
        .{ .kind = .fragment, .number = 1, .group_number = 1 },
        .{ .kind = .fragment, .number = 1, .group_number = null, .name = "named" },
    };
    for (invalid) |reference| {
        var bad = stored;
        bad.entry.references = &.{reference};
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, bad, "entry", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, bad));
    }
    // Encoder selection is canonical, but a valid note-only DPR9 remains readable.
    var encoder: Encoder = .{ .a = a, .version = .reference_items };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, reference_items_magic);
    for (0..5) |_| try encoder.count(0);
    try encoder.references(&[_]types.Reference{.{ .number = 4, .group_number = 2 }});
    try encoder.media(@as([]const types.Media, &.{}));
    const notes = try decodeAlloc(a, encoder.out.items, "entry", .supplemental, null);
    try std.testing.expectEqual(types.ReferenceKind.note, notes.entry.references[0].kind);
    try std.testing.expectEqual(@as(usize, 4), notes.entry.references[0].number);
}

test "DPRA preserves ARchar scale and all DPR9 reference and ordered cell fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rich = [_]types.Span{.{ .kind = .link, .text = "سبتمبر", .target = "سبتمبر", .classes = "AR", .font_scale = 1.25, .small = true, .superscript = true, .subscript = true, .background = "#abcdef" }};
    const refs = [_]types.Reference{
        .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &rich },
        .{ .number = 2, .group_number = 1, .name = "parent", .group = "notes", .spans = &rich },
    };
    const child = [_]types.Block{.{ .kind = .heading, .level = 3, .anchor = "child", .spans = &rich }};
    const cells = [_]types.Cell{.{ .blocks = &child }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .caption = &rich, .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Body", .anchor = "body", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .display_title = &rich, .preamble_spans = &rich, .sections = &sections, .references = &refs } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPRA", bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "entry", .supplemental, null);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const built = try encodeBuildAlloc(a, &rich, &sections, types.Layout{}, &refs, @as([]const types.Media, &.{}));
    const build_decoded = try decodeAlloc(a, built, "entry", .supplemental, null);
    try std.testing.expectEqual(@as(?f32, 1.25), build_decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].blocks.?[0].spans[0].font_scale);
}

test "font scale selection recurses into nested tables and canonical identity retains legacy bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spans = [_]types.Span{.{ .text = "sized", .font_scale = 1 }};
    const child_cells = [_]types.Cell{.{ .spans = &spans }};
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const cells = [_]types.Cell{.{ .nested_table = .{ .rows = &child_rows } }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Body", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .sections = &sections } };
    const identity = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPR7", identity[0..4]);
    spans[0].font_scale = null;
    try std.testing.expectEqualSlices(u8, identity, try encodeAlloc(a, stored));
    spans[0].font_scale = 0;
    const zero = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPRA", zero[0..4]);
    const decoded = try decodeAlloc(a, zero, "entry", .supplemental, null);
    try std.testing.expectEqual(@as(?f32, 0), decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].nested_table.?.rows[0].cells[0].spans[0].font_scale);
    const built = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualStrings("DPRA", built[0..4]);
}

test "font scale codec rejects malformed numeric fields without rejecting valid zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        var encoder: Encoder = .{ .a = a, .version = .font_scale };
        defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.span(types.Span{ .font_scale = invalid }));
    }
    var encoder: Encoder = .{ .a = a, .version = .font_scale };
    defer encoder.deinit();
    try encoder.span(types.Span{ .font_scale = 1.25 });
    const encoded = encoder.out.items;
    var truncated: Reader = .{ .a = a, .version = .font_scale, .bytes = encoded[0 .. encoded.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, truncated.span());
    const bad = try a.dupe(u8, encoded);
    std.mem.writeInt(u32, bad[bad.len - 4 ..][0..4], @bitCast(std.math.inf(f32)), .little);
    var nonfinite: Reader = .{ .a = a, .version = .font_scale, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, nonfinite.span());
}

test "DPRB body identity and zero retain references ordered cells and nested selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f32{ 1, 0, 1.25 }) |number| {
        const rich = [_]types.Span{.{ .kind = .link, .text = "body", .target = "Target", .font_scale = number, .font_scale_basis = .normal_body, .small = true, .superscript = true, .subscript = true, .background = "#abcdef" }};
        const refs = [_]types.Reference{
            .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &rich },
            .{ .number = 2, .group_number = 1, .name = "parent", .group = "notes", .spans = &rich },
        };
        const nested_cells = [_]types.Cell{.{ .spans = &rich }};
        const nested_rows = [_]types.Row{.{ .cells = &nested_cells }};
        const child = [_]types.Block{.{ .kind = .heading, .level = 3, .anchor = "child", .spans = &rich }};
        const cells = [_]types.Cell{ .{ .blocks = &child }, .{ .nested_table = .{ .rows = &nested_rows } } };
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .caption = &rich, .rows = &rows } }};
        const sections = [_]types.Section{.{ .level = 2, .title = "Body", .anchor = "body", .blocks = &blocks }};
        const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .display_title = &rich, .preamble_spans = &rich, .sections = &sections, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings("DPRB", bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "entry", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        const built = try encodeBuildAlloc(a, &rich, &sections, types.Layout{}, &refs, @as([]const types.Media, &.{}));
        try std.testing.expectEqualStrings("DPRB", built[0..4]);
        const build_decoded = try decodeAlloc(a, built, "entry", .supplemental, null);
        try std.testing.expectEqualDeep(sections[0], build_decoded.entry.sections[0]);
        const nested_only = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
        try std.testing.expectEqualStrings("DPRB", nested_only[0..4]);
        const json = try std.json.Stringify.valueAlloc(a, rich[0], .{});
        try std.testing.expect(std.mem.indexOf(u8, json, "\"font_scale_basis\":\"normal_body\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"font_scale\":") != null);
    }
}

test "context-only scale keeps exact DPRA span bytes and legacy identity JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder: Encoder = .{ .a = a, .version = .font_scale };
    defer encoder.deinit();
    try encoder.span(types.Span{ .font_scale = 1.25 });
    // Old DPRA empty span: 3 flags, 7 empty strings, two absent paints,
    // scale presence, then little-endian 1.25f. No basis byte is added.
    const absent_fields: [33]u8 = @splat(0);
    const old_bytes = absent_fields ++ [_]u8{ 1, 0, 0, 0xa0, 0x3f };
    try std.testing.expectEqualSlices(u8, &old_bytes, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .font_scale, .bytes = &old_bytes };
    const decoded = try reader.span();
    try std.testing.expectEqual(@as(?f32, 1.25), decoded.font_scale);
    try std.testing.expectEqual(types.FontScaleBasis.context, decoded.font_scale_basis);
    const plain_json = try std.json.Stringify.valueAlloc(a, types.Span{}, .{});
    const identity_json = try std.json.Stringify.valueAlloc(a, types.Span{ .font_scale = 1 }, .{});
    try std.testing.expectEqualStrings(plain_json, identity_json);
    try std.testing.expect(std.mem.indexOf(u8, plain_json, "font_scale") == null);
    const scaled_json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expect(std.mem.indexOf(u8, scaled_json, "font_scale_basis") == null);
}

test "DPRB count floor admits absent scales and rejects invalid basis pairs and bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var values: [64]types.Span = @splat(.{});
    values[63] = .{ .font_scale = 1, .font_scale_basis = .normal_body };
    var encoder: Encoder = .{ .a = a, .version = .font_scale_basis };
    defer encoder.deinit();
    try encoder.spans(&values);
    var reader: Reader = .{ .a = a, .version = .font_scale_basis, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(@as([]const types.Span, &values), try reader.spans());
    var invalid: Encoder = .{ .a = a, .version = .font_scale_basis };
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid.span(types.Span{ .font_scale_basis = .normal_body }));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        try std.testing.expectError(error.InvalidPresentation, invalid.span(types.Span{ .font_scale = number, .font_scale_basis = .normal_body }));
    }
    var single: Encoder = .{ .a = a, .version = .font_scale_basis };
    defer single.deinit();
    try single.span(types.Span{ .font_scale = 1, .font_scale_basis = .normal_body });
    const bad = try a.dupe(u8, single.out.items);
    bad[bad.len - 1] = 2;
    var unknown: Reader = .{ .a = a, .version = .font_scale_basis, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, unknown.span());
    var truncated: Reader = .{ .a = a, .version = .font_scale_basis, .bytes = single.out.items[0 .. single.out.items.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, truncated.span());
    var old: Encoder = .{ .a = a, .version = .font_scale };
    defer old.deinit();
    try std.testing.expectError(error.InvalidPresentation, old.span(types.Span{ .font_scale = 1, .font_scale_basis = .normal_body }));
}

// Additive controls: append to presentation_codec.zig after codec.patch in a
// future authorized qualification. Parser checked only; no semantic run claimed.

test "DPRC inherits earlier fields and keeps legacy reference bytes" {
    const a = std.testing.allocator;
    try std.testing.expect(hasRgb(.reference_blocks));
    try std.testing.expect(hasAnchorFields(.reference_blocks));
    try std.testing.expect(hasSpanBackgroundFields(.reference_blocks));
    try std.testing.expect(hasNestedFields(.reference_blocks));
    try std.testing.expect(hasCellBlockFields(.reference_blocks));
    try std.testing.expect(hasReferenceFields(.reference_blocks));
    try std.testing.expect(hasFontScaleFields(.reference_blocks));
    try std.testing.expect(hasFontScaleBasisFields(.reference_blocks));
    const LegacyReference = struct {
        kind: types.ReferenceKind = .note,
        number: usize,
        group_number: ?u32,
        name: []const u8 = "",
        group: []const u8 = "",
        spans: []const types.Span = &.{},
    };
    const legacy = [_]LegacyReference{.{ .number = 9, .group_number = 2 }};
    const current = [_]types.Reference{.{ .number = 9, .group_number = 2 }};
    // Frozen DPR2 reference list: one item; 9/2 identity; three empty strings/vectors.
    const plain = [_]u8{ 1, 0, 0, 0, 9, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    for ([_]Version{ .plain, .explained, .colored, .anchored, .span_background, .nested_tables, .cell_blocks, .reference_items, .font_scale, .font_scale_basis }) |version| {
        var before: Encoder = .{ .a = a, .version = version };
        defer before.deinit();
        var after: Encoder = .{ .a = a, .version = version };
        defer after.deinit();
        try before.references(&legacy);
        try after.references(&current);
        try std.testing.expectEqualSlices(u8, before.out.items, after.out.items);
        if (!hasReferenceFields(version)) {
            try std.testing.expectEqualSlices(u8, &plain, after.out.items);
        } else {
            try std.testing.expectEqual(@as(usize, plain.len + 1), after.out.items.len);
            try std.testing.expectEqualSlices(u8, plain[0..4], after.out.items[0..4]);
            try std.testing.expectEqual(@as(u8, 0), after.out.items[4]);
            try std.testing.expectEqualSlices(u8, plain[4..], after.out.items[5..]);
        }
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_]types.Span{
        .{ .text = "plain" },
        .{ .text = "explanation", .explanation = "retained" },
        .{ .text = "color", .foreground = "#123456" },
        .{ .text = "paint", .background = "#abcdef" },
        .{ .text = "scale", .font_scale = 1.25 },
        .{ .text = "basis", .font_scale = 1, .font_scale_basis = .normal_body },
    }) |span_value| {
        const spans_value = [_]types.Span{span_value};
        const old_refs = [_]LegacyReference{.{ .number = 9, .group_number = 2, .spans = &spans_value }};
        const refs = [_]types.Reference{.{ .number = 9, .group_number = 2, .spans = &spans_value }};
        const stored: types.Stored = .{ .entry = .{ .title = "legacy", .kind = .supplemental, .references = &refs } };
        const encoded = try encodeAlloc(alloc, stored);
        const built = try encodeBuildAlloc(alloc, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &old_refs, @as([]const types.Media, &.{}));
        try std.testing.expect(!std.mem.eql(u8, reference_blocks_magic, encoded[0..4]));
        try std.testing.expectEqualSlices(u8, built, encoded);
        const decoded = try decodeAlloc(alloc, encoded, "legacy", .supplemental, null);
        try std.testing.expect(decoded.entry.references[0].blocks == null);
        try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(alloc, decoded));
    }
}

test "DPRC keeps null explicit empty and mixed footer identities distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = [_]types.Reference{
        .{ .kind = .fragment, .number = 8, .group_number = null, .group = "citations", .blocks = &.{} },
        .{ .number = 2, .group_number = 1, .name = "named", .group = "notes", .spans = &.{.{ .text = "legacy" }} },
        .{ .number = 4, .group_number = 2, .blocks = &.{} },
    };
    const stored: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental, .references = &refs } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(reference_blocks_magic, encoded[0..4]);
    const decoded = try decodeAlloc(a, encoded, "empty", .supplemental, null);
    try std.testing.expectEqualDeep(@as([]const types.Reference, &refs), decoded.entry.references);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.references[0].blocks.?.len);
    try std.testing.expect(decoded.entry.references[1].blocks == null);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.references[2].blocks.?.len);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, encoded, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &refs, @as([]const types.Media, &.{})));
}

test "DPRC reference table tree preserves styles anchors actions and metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rich = [_]types.Span{.{ .kind = .link, .text = "deep", .target = "Deep", .trail = "s", .explanation = "source", .foreground = "#123456", .background = "#abcdef", .font_scale = 1.25, .font_scale_basis = .normal_body, .bold = true, .small = true }};
    const child_cells = [_]types.Cell{.{ .spans = &rich }};
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const ordered = [_]types.Block{
        .{ .kind = .heading, .level = 3, .anchor = "Deep_anchor", .anchor_fallback = "Deep_fallback", .spans = &.{.{ .text = "heading" }} },
        .{ .kind = .list_item, .depth = 2, .list_path = "*#", .number = "2", .feature = .{ .kind = "audio", .language = "en", .data = "Deep.ogg" } },
        .{ .kind = .table, .table = .{ .rows = &child_rows, .geometry = .{ .width = .{ .unit = .percent, .value = 50 } } } },
    };
    const first_cells = [_]types.Cell{
        .{ .header = true, .blocks = &ordered, .background = "#ffffe0" },
        .{ .spans = &.{.{ .text = "r1c2" }} },
        .{ .spans = &.{.{ .text = "r1c3" }} },
        .{ .spans = &.{.{ .text = "r1c4" }} },
        .{ .spans = &.{.{ .text = "r1c5" }} },
    };
    const second_cells = [_]types.Cell{
        .{ .spans = &.{.{ .text = "r2c1" }} },
        .{ .spans = &.{.{ .text = "r2c2" }} },
        .{ .spans = &.{.{ .text = "r2c3" }} },
        .{ .spans = &.{.{ .text = "r2c4" }} },
        .{ .spans = &.{.{ .text = "r2c5" }} },
    };
    const rows = [_]types.Row{ .{ .cells = &first_cells }, .{ .cells = &second_cells } };
    const contents = [_]types.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "before" }} },
        .{ .kind = .table, .table = .{ .caption = &.{.{ .text = "caption" }}, .rows = &rows } },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "after" }} },
    };
    const refs = [_]types.Reference{.{ .number = 7, .group_number = 3, .name = "rich", .group = "notes", .blocks = &contents }};
    try std.testing.expect(rich[0].font_features == null);
    // Every present feature occurs only inside this footer tree; several are two tables deep.
    // This image-free tree must retain DPRC rather than require the DPRD border feature.
    inline for (comptime std.meta.tags(TreeFeature)) |feature| {
        if (comptime feature == .containers or feature == .container_fonts or feature == .cell_min_width) continue;
        const expected = switch (feature) {
            .explanation, .color, .background, .scale, .body_scale,
            .anchors, .nested_tables, .cell_blocks => true,
            else => false,
        };
        errdefer std.debug.print("DPRC_REFERENCE_FEATURE member={s} expected={}\n", .{ @tagName(feature), expected });
        try std.testing.expectEqual(expected, referenceBlocksHaveFeature(&refs, feature));
    }
    const stored: types.Stored = .{ .entry = .{ .title = "rich", .kind = .supplemental, .references = &refs } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(reference_blocks_magic, encoded[0..4]);
    var metrics: DecodeMetrics = .{};
    const decoded = try decodeWithMetricsAlloc(a, encoded, "rich", .supplemental, null, &metrics);
    try std.testing.expectEqualDeep(@as([]const types.Reference, &refs), decoded.entry.references);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 2), metrics.tables);
    try std.testing.expectEqual(@as(?usize, 5), metrics.table_columns_exact);
    const table_value = decoded.entry.references[0].blocks.?[1].table.?;
    try std.testing.expectEqual(@as(usize, 2), table_value.rows.len);
    try std.testing.expectEqual(@as(usize, 5), table_value.rows[0].cells.len);
    const inner = table_value.rows[0].cells[0].blocks.?;
    try std.testing.expectEqualStrings("Deep_anchor", inner[0].anchor);
    try std.testing.expectEqualDeep(rich[0], inner[2].table.?.rows[0].cells[0].spans[0]);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    const BuildKind = enum { note, fragment };
    const BuildReference = struct { kind: BuildKind = .note, number: usize, group_number: ?u32, name: []const u8 = "", group: []const u8 = "", spans: []const types.Span = &.{}, blocks: ?[]const types.Block = null };
    const build_refs = [_]BuildReference{.{ .number = 7, .group_number = 3, .name = "rich", .group = "notes", .blocks = &contents }};
    try std.testing.expectEqualSlices(u8, encoded, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &build_refs, @as([]const types.Media, &.{})));
    // An explicit font-feature policy at the same deepest reference-table span
    // needs M; normal-body scale alone above must keep the legacy DPRC bytes.
    var font_spans = rich; font_spans[0].font_features = .seven_on;
    var font_child_cells = child_cells; font_child_cells[0].spans = &font_spans;
    var font_child_rows = child_rows; font_child_rows[0].cells = &font_child_cells;
    var font_ordered = ordered; font_ordered[2].table.?.rows = &font_child_rows;
    var font_first_cells = first_cells; font_first_cells[0].blocks = &font_ordered;
    var font_rows = rows; font_rows[0].cells = &font_first_cells;
    var font_contents = contents; font_contents[1].table.?.rows = &font_rows;
    var font_refs = refs; font_refs[0].blocks = &font_contents;
    try std.testing.expect(referenceBlocksHaveFeature(&font_refs, .m_span_fonts));
    const font_stored: types.Stored = .{ .entry = .{ .title = "rich", .kind = .supplemental, .references = &font_refs } };
    const font_encoded = try encodeAlloc(a, font_stored);
    try std.testing.expectEqualStrings(container_fonts_magic, font_encoded[0..4]);
    const font_decoded = try decodeAlloc(a, font_encoded, "rich", .supplemental, null);
    try std.testing.expectEqualDeep(@as([]const types.Reference, &font_refs), font_decoded.entry.references);
    try std.testing.expectEqualSlices(u8, font_encoded, try encodeAlloc(a, font_decoded));
    try std.testing.expectEqualSlices(u8, font_encoded, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &font_refs, @as([]const types.Media, &.{})));

}

test "DPRC rejects mixed reference bodies and malformed presence or counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mixed = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = &.{.{ .text = "keep" }}, .blocks = &.{} }};
    const stored: types.Stored = .{ .entry = .{ .title = "mixed", .kind = .supplemental, .references = &mixed } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &mixed, @as([]const types.Media, &.{})));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "mixed", .supplemental, null));
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer encoder.deinit();
    try encoder.references(&[_]types.Reference{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{} }});
    const presence_at = encoder.out.items.len - 5;
    // Exact minimum item: 13 legacy fragment bytes + one presence; empty blocks add four.
    try std.testing.expectEqual(@as(usize, 4 + 14 + 4), encoder.out.items.len);
    const invalid_presence = try a.dupe(u8, encoder.out.items);
    invalid_presence[presence_at] = 2;
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = invalid_presence };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items[0 .. encoder.out.items.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    const invalid_count = try a.dupe(u8, encoder.out.items);
    invalid_count[presence_at + 1] = 1;
    reader = .{ .a = a, .version = .reference_blocks, .bytes = invalid_count };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    var legacy_body: Encoder = .{ .a = a, .version = .reference_blocks };
    defer legacy_body.deinit();
    try legacy_body.references(&[_]types.Reference{.{ .number = 1, .group_number = 1, .spans = &.{.{ .text = "keep" }} }});
    legacy_body.out.items[legacy_body.out.items.len - 1] = 1;
    try legacy_body.writeU32(0);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = legacy_body.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    var span_encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer span_encoder.deinit();
    try span_encoder.spans(&[_]types.Span{.{}});
    try std.testing.expectEqual(@as(usize, 4 + 35), span_encoder.out.items.len);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = span_encoder.out.items };
    try std.testing.expectEqual(@as(usize, 1), (try reader.spans()).len);
}

test "DPRC rejects invalid styles and anchors in the reference block tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]types.Span{
        .{ .text = "bad foreground", .foreground = "red" },
        .{ .text = "bad background", .background = "#ABCD12" },
        .{ .text = "missing body scale", .font_scale_basis = .normal_body },
        .{ .text = "negative scale", .font_scale = -1 },
    }) |span_value| {
        const spans_value = [_]types.Span{span_value};
        const cells = [_]types.Cell{.{ .blocks = &.{.{ .kind = .paragraph, .spans = &spans_value }} }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .table, .table = .{ .rows = &rows } }} }};
        const stored: types.Stored = .{ .entry = .{ .title = "invalid", .kind = .supplemental, .references = &refs } };
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "invalid", .supplemental, null));
    }
    const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .paragraph, .anchor = "invalid" }} }};
    const stored: types.Stored = .{ .entry = .{ .title = "invalid", .kind = .supplemental, .references = &refs } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "invalid", .supplemental, null));
}

test "DPRC shares table depth and aggregate item budget across reference blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [types.max_table_depth + 1][1]types.Cell = undefined;
    var rows: [types.max_table_depth + 1][1]types.Row = undefined;
    var tables: [types.max_table_depth + 1]types.Table = undefined;
    var i: usize = tables.len;
    while (i != 0) {
        i -= 1;
        cells[i] = .{.{ .nested_table = if (i + 1 < tables.len) tables[i + 1] else null }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .rows = &rows[i] };
    }
    var contents = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .blocks = &contents }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .supplemental, .references = &refs } };
    const valid = try encodeAlloc(a, stored);
    var metrics: DecodeMetrics = .{};
    _ = try decodeWithMetricsAlloc(a, valid, "depth", .supplemental, null, &metrics);
    try std.testing.expectEqual(types.max_table_depth, metrics.tables);
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer encoder.deinit();
    try encoder.references(&refs);
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items, .table_depth = 1 };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    contents[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "depth", .supplemental, null));
    const small = [_]types.Reference{.{ .number = 2, .group_number = 1, .blocks = &.{.{ .kind = .paragraph }} }};
    var small_encoder: Encoder = .{ .a = a, .version = .reference_blocks, .remaining_items = 2 };
    defer small_encoder.deinit();
    try small_encoder.references(&small);
    try std.testing.expectEqual(@as(usize, 0), small_encoder.remaining_items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = small_encoder.out.items, .remaining_items = 2 };
    _ = try reader.references();
    try std.testing.expectEqual(@as(usize, 0), reader.remaining_items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = small_encoder.out.items, .remaining_items = 1 };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    var limited_encoder: Encoder = .{ .a = a, .version = .reference_blocks, .remaining_items = 1 };
    defer limited_encoder.deinit();
    try std.testing.expectError(error.PresentationTooLarge, limited_encoder.references(&small));
}

// Additive codec controls for the completed private DPRC contract. These are
// synthetic typed controls, not a claim that the compiler consumed retained HR CSS.

test "DPRC styles preserve actual palette em padding pixel margins and header alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const border: types.StyleBorder = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } };
    const padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.2 });
    const margins = types.StyleEdges.all(.{ .unit = .px, .value = 10 });
    const header_cells = [_]types.Cell{
        .{ .header = true, .background = "#f2f2f2", .style = .{ .border = border, .padding = padding, .text_align = .center }, .spans = &.{.{ .text = "Latin" }} },
        .{ .header = true, .background = "#f2f2f2", .style = .{ .border = border, .padding = padding, .text_align = .center }, .spans = &.{.{ .text = "Italian" }} },
        .{ .header = true, .background = "#f2f2f2", .style = .{ .border = border, .padding = padding, .text_align = .center }, .spans = &.{.{ .text = "German" }} },
        .{ .header = true, .background = "#f2f2f2", .style = .{ .border = border, .padding = padding, .text_align = .center }, .spans = &.{.{ .text = "Croatian" }} },
        .{ .header = true, .background = "#f2f2f2", .style = .{ .border = border, .padding = padding, .text_align = .center }, .spans = &.{.{ .text = "Hungarian" }} },
    };
    const body_cells = [_]types.Cell{
        .{ .style = .{ .border = border, .padding = padding }, .spans = &.{.{ .text = "one" }} },
        .{ .style = .{ .border = border, .padding = padding }, .spans = &.{.{ .text = "two" }} },
        .{ .style = .{ .border = border, .padding = padding }, .spans = &.{.{ .text = "three" }} },
        .{ .style = .{ .border = border, .padding = padding }, .spans = &.{.{ .text = "four" }} },
        .{ .style = .{ .border = border, .padding = padding }, .spans = &.{.{ .text = "five" }} },
    };
    const rows = [_]types.Row{ .{ .cells = &header_cells }, .{ .cells = &body_cells } };
    const contents = [_]types.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "before", .foreground = "#123456", .font_scale = 1.25, .font_scale_basis = .normal_body }} },
        .{ .kind = .table, .table = .{ .rows = &rows, .style = .{ .background = "#f9f9f9", .border = border, .collapse = .collapse, .margins = margins } } },
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "after", .target = "After" }} },
    };
    const refs = [_]types.Reference{.{ .number = 7, .group_number = 3, .name = "rich", .blocks = &contents }};
    const stored: types.Stored = .{ .entry = .{ .title = "style", .kind = .supplemental, .references = &refs } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(reference_blocks_magic, bytes[0..4]);
    var metrics: DecodeMetrics = .{};
    const decoded = try decodeWithMetricsAlloc(a, bytes, "style", .supplemental, null, &metrics);
    try std.testing.expectEqualDeep(@as([]const types.Reference, &refs), decoded.entry.references);
    try std.testing.expectEqual(@as(usize, 1), metrics.tables);
    try std.testing.expectEqual(@as(?usize, 5), metrics.table_columns_exact);
    const table = decoded.entry.references[0].blocks.?[1].table.?;
    try std.testing.expectEqual(types.StyleLengthUnit.em, table.rows[0].cells[0].style.?.padding.?.left.unit);
    try std.testing.expectEqual(@as(f32, 0.2), table.rows[0].cells[0].style.?.padding.?.left.value);
    try std.testing.expectEqual(types.StyleLengthUnit.px, table.style.?.margins.?.left.unit);
    try std.testing.expectEqual(@as(f32, 10), table.style.?.margins.?.left.value);
    try std.testing.expect(table.rows[1].cells[0].background == null);
    try std.testing.expect(table.rows[1].cells[0].style.?.text_align == null);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &refs, @as([]const types.Media, &.{})));
}

test "DPRC styles alone select C while all legacy two through B selectors retain bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Version{ .plain, .explained, .colored, .anchored, .span_background, .nested_tables, .cell_blocks, .reference_items, .font_scale, .font_scale_basis }) |version| {
        var legacy_cell: Encoder = .{ .a = a, .version = version };
        defer legacy_cell.deinit();
        try legacy_cell.cell(types.Cell{});
        // Frozen pre-style empty cell bytes for every legacy version.
        const frozen = [_]u8{ 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
        const frozen_len: usize = if (hasCellBlockFields(version)) 12 else if (hasNestedFields(version)) 11 else if (hasRgb(version)) 10 else 9;
        try std.testing.expectEqualSlices(u8, frozen[0..frozen_len], legacy_cell.out.items);
        var spans_value = [_]types.Span{.{ .text = "word" }};
        var cells = [_]types.Cell{.{}};
        const rows = [_]types.Row{.{ .cells = &cells }};
        var block = [_]types.Block{.{ .kind = .paragraph, .spans = &spans_value }};
        var sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = &block }};
        var refs = [_]types.Reference{.{ .number = 1, .group_number = 1 }};
        switch (version) {
            .plain => {},
            .explained => spans_value[0].explanation = "source",
            .colored => spans_value[0].foreground = "#123456",
            .anchored => sections[0].anchor = "Body",
            .span_background => spans_value[0].background = "#abcdef",
            .nested_tables => block[0] = .{ .kind = .table, .table = .{ .geometry = .{ .border = 0 } } },
            .cell_blocks => {
                cells[0].blocks = &.{};
                block[0] = .{ .kind = .table, .table = .{ .rows = &rows } };
            },
            .reference_items => refs[0] = .{ .kind = .fragment, .number = 8, .group_number = null },
            .font_scale => spans_value[0].font_scale = 1.25,
            .font_scale_basis => {
                spans_value[0].font_scale = 1;
                spans_value[0].font_scale_basis = .normal_body;
            },
            .reference_blocks, .image_border, .block_layout, .explicit_targets, .dynamic_catalog, .tooltips, .block_geometry, .image_maps, .inline_table_styles, .block_containers, .container_fonts => unreachable,
        }
        const stored: types.Stored = .{ .entry = .{ .title = "legacy", .kind = .supplemental, .sections = &sections, .references = &refs } };
        try std.testing.expect(!hasStyles(&sections, &refs));
        const encoded = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(versionMagic(version), encoded[0..4]);
        const decoded = try decodeAlloc(a, encoded, "legacy", .supplemental, null);
        try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    }
    // Style discovery must recurse through both nested-table representations.
    for (0..5) |location| {
        const styled: types.Table = .{ .style = .{ .background = "#f9f9f9" } };
        const child_blocks = [_]types.Block{.{ .kind = .table, .table = styled }};
        const cells = [_]types.Cell{.{ .style = if (location == 1) .{ .text_align = .left } else null, .nested_table = if (location == 2) styled else null, .blocks = if (location == 3) &child_blocks else null }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows, .style = if (location == 0) .{ .collapse = .separate } else null } }};
        const sections = [_]types.Section{.{ .level = 2, .title = "style", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .blocks = &child_blocks }};
        const selected_sections: []const types.Section = if (location == 4) &.{} else &sections;
        const selected_refs: []const types.Reference = if (location == 4) &refs else &.{};
        try std.testing.expect(hasStyles(selected_sections, selected_refs));
        const stored: types.Stored = .{ .entry = .{ .title = "nested", .kind = .supplemental, .sections = selected_sections, .references = selected_refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(reference_blocks_magic, bytes[0..4]);
        _ = try decodeAlloc(a, bytes, "nested", .supplemental, null);
    }
}

test "DPRC generic build structs serialize optional typed style fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const BuildCell = struct { spans: []const types.Span = &.{}, header: bool = false, colspan: u16 = 1, rowspan: u16 = 1, background: ?[]const u8 = null, style: ?types.CellStyle = null };
    const BuildRow = struct { cells: []const BuildCell };
    const BuildTable = struct { caption: []const types.Span = &.{}, rows: []const BuildRow, style: ?types.TableStyle = null };
    const BuildBlock = struct { kind: enum { table } = .table, depth: u8 = 0, level: u8 = 0, spans: []const types.Span = &.{}, feature: ?types.Feature = null, list_path: []const u8 = "", number: []const u8 = "", table: ?BuildTable = null };
    const BuildSection = struct { level: u8 = 2, title: []const u8 = "generic", blocks: []const BuildBlock };
    const cells = [_]BuildCell{.{ .header = true, .background = "#f2f2f2", .style = .{ .padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.2 }), .text_align = .center } }};
    const rows = [_]BuildRow{.{ .cells = &cells }};
    const blocks = [_]BuildBlock{.{ .table = .{ .rows = &rows, .style = .{ .background = "#f9f9f9", .margins = types.StyleEdges.all(.{ .unit = .px, .value = 10 }) } } }};
    const sections = [_]BuildSection{.{ .blocks = &blocks }};
    const bytes = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualStrings(reference_blocks_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "generic", .supplemental, null);
    const table = decoded.entry.sections[0].blocks[0].table.?;
    try std.testing.expectEqualDeep(blocks[0].table.?.style, table.style);
    try std.testing.expectEqualDeep(cells[0].style, table.rows[0].cells[0].style);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
}

test "DPRC style wire retains null zero none and strict minimum framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks, .remaining_items = 0 };
    defer encoder.deinit();
    try encoder.cell(types.Cell{});
    try std.testing.expectEqual(@as(usize, 13), encoder.out.items.len);
    try std.testing.expectEqual(@as(u8, 0), encoder.out.items[12]);
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items, .remaining_items = 0 };
    try std.testing.expect((try reader.cell()).style == null);
    encoder.out.clearRetainingCapacity();
    try encoder.tableStyle(.{ .border = .none });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 0 }, encoder.out.items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
    try std.testing.expect((try reader.tableStyle()).?.border.? == .none);
    encoder.out.clearRetainingCapacity();
    try encoder.cellStyle(.{ .text_align = .left });
    try std.testing.expectEqualSlices(u8, &.{ 1, 4, 0 }, encoder.out.items);
    encoder.out.clearRetainingCapacity();
    for ([_]f32{ 0, -0.0, 0.2, std.math.floatMax(f32) }) |number| {
        for ([_]types.StyleLengthUnit{ .px, .em }) |unit| {
            encoder.out.clearRetainingCapacity();
            try encoder.styleLength(.{ .unit = unit, .value = number });
            try std.testing.expectEqual(@as(usize, 5), encoder.out.items.len);
            reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
            const decoded = try reader.styleLength();
            try std.testing.expectEqual(unit, decoded.unit);
            try std.testing.expectEqual(@as(u32, @bitCast(number)), @as(u32, @bitCast(decoded.value)));
        }
    }
    encoder.out.clearRetainingCapacity();
    const asymmetric: types.StyleEdges = .{
        .top = .{ .unit = .px, .value = 1 },
        .right = .{ .unit = .em, .value = 0.2 },
        .bottom = .{ .unit = .px, .value = 0 },
        .left = .{ .unit = .em, .value = 3 },
    };
    try encoder.cellStyle(.{ .padding = asymmetric });
    const edges_wire = [_]u8{ 1, 2, 0, 0, 0, 128, 63, 1, 205, 204, 76, 62, 0, 0, 0, 0, 0, 1, 0, 0, 64, 64 };
    try std.testing.expectEqualSlices(u8, &edges_wire, encoder.out.items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(asymmetric, (try reader.cellStyle()).?.padding.?);
    encoder.out.clearRetainingCapacity();
    try encoder.writeU32(1);
    try encoder.cell(types.Cell{});
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
    try std.testing.expectEqual(@as(usize, 1), (try reader.row()).cells.len);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items[0 .. encoder.out.items.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, reader.row());
    const cells = [_]types.Cell{.{ .style = .{ .padding = types.StyleEdges.all(.{ .unit = .em, .value = std.math.floatMax(f32) }), .border = .none } }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows, .style = .{ .margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "limits", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "limits", .kind = .supplemental, .sections = &sections } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "limits", .supplemental, null);
    try std.testing.expectEqualDeep(stored.entry.sections, decoded.entry.sections);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
}

test "DPRC styles reject malformed flags units borders enums colors and empty records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ &.{2}, &.{ 1, 0 }, &.{ 1, 8 }, &.{ 1, 1, 2 }, &.{ 1, 4, 3 }, &.{ 1, 2, 2, 0, 0, 0, 0 } }) |bytes| {
        var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.cellStyle());
    }
    for ([_][]const u8{ &.{2}, &.{ 1, 0 }, &.{ 1, 16 }, &.{ 1, 2, 2 }, &.{ 1, 4, 2 }, &.{ 1, 8, 2, 0, 0, 0, 0 } }) |bytes| {
        var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |number| {
        var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
        defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.styleLength(.{ .unit = .em, .value = number }));
        try encoder.byte(1);
        try encoder.writeU32(@bitCast(number));
        var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.styleLength());
    }
    for ([_][]const u8{ "red", "#aaa", "#AAAAAA", "#12345g" }) |color| {
        var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
        defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.tableStyle(.{ .background = color }));
        try encoder.byte(1);
        try encoder.byte(1);
        try encoder.string(color);
        var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer encoder.deinit();
    try std.testing.expectError(error.InvalidPresentation, encoder.tableStyle(.{}));
    try std.testing.expectError(error.InvalidPresentation, encoder.cellStyle(.{}));
    const cells = [_]types.Cell{.{ .style = .{} }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "empty", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental, .sections = &sections } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
}

test "DPRC styled reference tables preserve shared depth and aggregate budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [types.max_table_depth + 1][1]types.Cell = undefined;
    var rows: [types.max_table_depth + 1][1]types.Row = undefined;
    var tables: [types.max_table_depth + 1]types.Table = undefined;
    var i: usize = tables.len;
    while (i != 0) {
        i -= 1;
        cells[i] = .{.{ .style = .{ .padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.2 }) }, .nested_table = if (i + 1 < tables.len) tables[i + 1] else null }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .rows = &rows[i], .style = .{ .background = "#f9f9f9" } };
    }
    var contents = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .blocks = &contents }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .supplemental, .references = &refs } };
    const valid = try encodeAlloc(a, stored);
    var metrics: DecodeMetrics = .{};
    _ = try decodeWithMetricsAlloc(a, valid, "depth", .supplemental, null, &metrics);
    try std.testing.expectEqual(types.max_table_depth, metrics.tables);
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer encoder.deinit();
    try encoder.references(&refs);
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items, .table_depth = 1 };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    contents[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "depth", .supplemental, null));
    contents[0].table = tables[tables.len - 1];
    var exact: Encoder = .{ .a = a, .version = .reference_blocks, .remaining_items = 4 };
    defer exact.deinit();
    try exact.references(&refs);
    try std.testing.expectEqual(@as(usize, 0), exact.remaining_items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = exact.out.items, .remaining_items = 4 };
    _ = try reader.references();
    try std.testing.expectEqual(@as(usize, 0), reader.remaining_items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = exact.out.items, .remaining_items = 3 };
    try std.testing.expectError(error.InvalidPresentation, reader.references());
    var insufficient: Encoder = .{ .a = a, .version = .reference_blocks, .remaining_items = 3 };
    defer insufficient.deinit();
    try std.testing.expectError(error.PresentationTooLarge, insufficient.references(&refs));
}

// Additive source-only controls for the selected private C image successor.

test "DPRC image wire keeps exact dimensions nullable text and minimum span35" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer encoder.deinit();
    try encoder.inlineImage(.{ .file = "Icon.svg", .width_px = 15 });
    const golden = [_]u8{ 1, 8, 0, 0, 0, 'I', 'c', 'o', 'n', '.', 's', 'v', 'g', 1, 15, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &golden, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = &golden };
    const image = (try reader.inlineImage()).?;
    try std.testing.expectEqual(@as(?u32, 15), image.width_px);
    try std.testing.expect(image.height_px == null and image.alt == null and image.tooltip == null);
    const variants = [_]types.InlineImage{
        .{ .file = "Icon.svg" },
        .{ .file = "Icon.svg", .alt = "", .tooltip = "" },
        .{ .file = "Icon.svg", .width_px = std.math.maxInt(u32), .height_px = std.math.maxInt(u32), .alt = "alt", .tooltip = "tooltip" },
    };
    for (variants) |value| {
        encoder.out.clearRetainingCapacity();
        try encoder.inlineImage(value);
        reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
        try std.testing.expectEqualDeep(value, (try reader.inlineImage()).?);
    }
    encoder.out.clearRetainingCapacity();
    try encoder.spans(&[_]types.Span{.{}});
    try std.testing.expectEqual(@as(usize, 4 + 35), encoder.out.items.len);
    try std.testing.expectEqual(@as(u8, 0), encoder.out.items[encoder.out.items.len - 1]);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
    try std.testing.expect((try reader.spans())[0].image == null);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items[0 .. encoder.out.items.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, reader.spans());
}

test "DPRC image discovery and roundtrip cover all nested semantic span sinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image = [_]types.Span{.{ .kind = .link, .target = "File:Vraagteken-2.svg", .image = .{ .file = "Vraagteken-2.svg", .width_px = 15 }, .foreground = "#123456", .background = "#abcdef", .font_scale = 1.25, .font_scale_basis = .normal_body }};
    const blank: []const types.Span = &.{};
    const media = [_]types.Media{.{ .file = "Vraagteken-2.svg", .kind = .image, .caption = "metadata" }};
    for (0..12) |location| {
        const child_cells = [_]types.Cell{.{ .spans = if (location == 6) &image else blank }};
        const child_rows = [_]types.Row{.{ .cells = &child_cells }};
        const child: types.Table = .{ .caption = if (location == 5 or location == 8) &image else blank, .rows = &child_rows };
        const cell_blocks = [_]types.Block{
            .{ .kind = .paragraph, .spans = if (location == 7) &image else blank },
            .{ .kind = .table, .table = if (location == 8) child else null },
        };
        const cells = [_]types.Cell{.{ .spans = if (location == 4) &image else blank, .nested_table = if (location == 5 or location == 6) child else null, .blocks = if (location == 7 or location == 8) &cell_blocks else null }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{
            .{ .kind = .heading, .level = 3, .anchor = "Stable_anchor", .spans = if (location == 2) &image else blank },
            .{ .kind = .table, .table = .{ .caption = if (location == 3) &image else blank, .rows = &rows } },
        };
        const sections = [_]types.Section{.{ .level = 2, .title = "Stable title", .anchor = "Stable_section", .blocks = &blocks }};
        const reference_blocks = [_]types.Block{
            .{ .kind = .paragraph, .spans = if (location == 10) &image else blank },
            .{ .kind = .table, .table = if (location == 11) .{ .caption = &image } else null },
        };
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 9) &image else blank, .blocks = if (location >= 10) &reference_blocks else null }};
        const stored: types.Stored = .{ .entry = .{ .title = "sinks", .kind = .supplemental, .display_title = if (location == 0) &image else blank, .preamble_spans = if (location == 1) &image else blank, .sections = &sections, .references = &refs, .media = &media } };
        try std.testing.expect(hasInlineImages(stored.entry.display_title, &sections, stored.entry.preamble_spans, &refs));
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(reference_blocks_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "sinks", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualStrings("Stable title", decoded.entry.sections[0].title);
        try std.testing.expectEqualStrings("Stable_anchor", decoded.entry.sections[0].blocks[0].anchor);
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    }
}

test "DPRC images preserve per occurrence actions and generic compiler build fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const BuildSpan = struct { kind: enum { text, link, external_link } = .text, role: types.Role = .normal, text: []const u8 = "", target: []const u8 = "", language: []const u8 = "", classes: []const u8 = "", direction: []const u8 = "", flags: packed struct(u8) { bold: bool = false, rest: u7 = 0 } = .{}, image: ?types.InlineImage = null };
    const spans = [_]BuildSpan{
        .{ .text = "before" },
        .{ .kind = .link, .target = "File:Icon.svg", .image = .{ .file = "Icon.svg", .width_px = 15 } },
        .{ .image = .{ .file = "Icon.svg", .height_px = 20, .alt = "", .tooltip = "" } },
        .{ .kind = .link, .target = "Target", .image = .{ .file = "Icon.svg", .alt = "alternate" } },
        .{ .kind = .external_link, .target = "https://example.invalid/image", .image = .{ .file = "Icon.svg", .tooltip = "tooltip" } },
        .{ .text = "after" },
    };
    const media = [_]types.Media{.{ .file = "Icon.svg", .kind = .image, .caption = "shared metadata" }};
    const bytes = try encodeBuildAlloc(a, &spans, @as([]const types.Section, &.{}), types.Layout{}, @as([]const types.Reference, &.{}), &media);
    try std.testing.expectEqualStrings(reference_blocks_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "actions", .supplemental, null);
    try std.testing.expectEqual(@as(usize, 6), decoded.entry.display_title.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
    try std.testing.expectEqualStrings("before", decoded.entry.display_title[0].text);
    try std.testing.expectEqualStrings("after", decoded.entry.display_title[5].text);
    for (decoded.entry.display_title[1..5]) |span| {
        try std.testing.expectEqual(@as(usize, 0), span.text.len);
        try std.testing.expectEqualStrings("Icon.svg", span.image.?.file);
    }
    try std.testing.expectEqual(types.InlineKind.text, decoded.entry.display_title[2].kind);
    try std.testing.expectEqualStrings("", decoded.entry.display_title[2].image.?.alt.?);
    try std.testing.expectEqualStrings("Target", decoded.entry.display_title[3].target);
    try std.testing.expectEqual(types.InlineKind.external_link, decoded.entry.display_title[4].kind);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const bad_media = [_]types.Media{.{ .file = "Icon.svg", .kind = .audio, .caption = "wrong" }};
    try std.testing.expectError(error.InvalidPresentation, encodeBuildAlloc(a, &spans, @as([]const types.Section, &.{}), types.Layout{}, @as([]const types.Reference, &.{}), &bad_media));
}

test "image absent spans retain all legacy bytes and plain selector" {
    const a = std.testing.allocator;
    const LegacySpan = struct { kind: types.InlineKind = .text, role: types.Role = .normal, text: []const u8 = "", target: []const u8 = "", language: []const u8 = "", classes: []const u8 = "", direction: []const u8 = "", flags: packed struct(u8) { bits: u8 = 0 } = .{} };
    for ([_]Version{ .plain, .explained, .colored, .anchored, .span_background, .nested_tables, .cell_blocks, .reference_items, .font_scale, .font_scale_basis }) |version| {
        var old: Encoder = .{ .a = a, .version = version };
        defer old.deinit();
        var current: Encoder = .{ .a = a, .version = version };
        defer current.deinit();
        try old.span(LegacySpan{});
        try current.span(types.Span{});
        const len: usize = if (hasFontScaleFields(version)) 34 else if (hasSpanBackgroundFields(version)) 33 else if (hasRgb(version)) 32 else if (version == .explained) 31 else 27;
        const frozen: [34]u8 = @splat(0);
        try std.testing.expectEqualSlices(u8, frozen[0..len], current.out.items);
        try std.testing.expectEqualSlices(u8, old.out.items, current.out.items);
    }
    const stored: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental } };
    const bytes = try encodeAlloc(a, stored);
    defer a.free(bytes);
    var frozen: [32]u8 = @splat(0);
    @memcpy(frozen[0..4], "DPR2");
    try std.testing.expectEqualSlices(u8, &frozen, bytes);
}

test "DPRC images reject malformed suffixes actions and full entry assets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ &.{2}, &.{ 1, 0, 0, 0, 0, 0 }, &.{ 1, 1, 0, 0, 0, 'I', 16 }, &.{ 1, 1, 0, 0, 0, 'I', 1, 0, 0, 0, 0 }, &.{ 1, 1, 0, 0, 0, 'I', 2, 0, 0, 0, 0 }, &.{ 1, 1, 0, 0, 0, 255, 0 } }) |bytes| {
        var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks };
    defer encoder.deinit();
    for ([_][]const u8{ "[Icon].svg", "{Icon}.svg", "<Icon>.svg", "Icon|bad.svg", "Icon#bad.svg", "Icon_name.svg", "Icon\n.svg", "Icon\u{0085}.svg" }) |file| {
        encoder.out.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidPresentation, encoder.inlineImage(.{ .file = file }));
        try encoder.byte(1);
        try encoder.string(file);
        try encoder.byte(0);
        var malformed_reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
        try std.testing.expectError(error.InvalidPresentation, malformed_reader.inlineImage());
    }
    encoder.out.clearRetainingCapacity();
    try encoder.span(types.Span{ .image = .{ .file = "Icon.svg" } });
    const truncated = encoder.out.items[0 .. encoder.out.items.len - 1];
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = truncated };
    try std.testing.expectError(error.InvalidPresentation, reader.span());
    for ([_]u8{ 1, 2, 3, 255 }) |tag| {
        const invalid = try a.dupe(u8, encoder.out.items);
        invalid[0] = tag;
        reader = .{ .a = a, .version = .reference_blocks, .bytes = invalid };
        try std.testing.expectError(error.InvalidPresentation, reader.span());
    }
    for ([_]types.Span{
        .{ .text = "kept", .image = .{ .file = "Icon.svg" } },
        .{ .trail = "kept", .image = .{ .file = "Icon.svg" } },
    }) |invalid_span| {
        encoder.out.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidPresentation, encoder.span(invalid_span));
        var ordinary = invalid_span;
        ordinary.image = null;
        try encoder.span(ordinary);
        encoder.out.items.len -= 1;
        try encoder.inlineImage(invalid_span.image);
        reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.span());
    }
    encoder.out.clearRetainingCapacity();
    try encoder.byte(1);
    try encoder.writeU32(max_string_bytes + 1);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    const images = [_]types.Span{.{ .image = .{ .file = "Icon.svg" } }};
    const good = [_]types.Media{.{ .file = "Icon.svg", .kind = .image, .caption = "" }};
    const wrong = [_]types.Media{.{ .file = "Icon.svg", .kind = .audio, .caption = "" }};
    const duplicate = [_]types.Media{ good[0], good[0] };
    for ([_][]const types.Media{ &.{}, &wrong, &duplicate }) |media| {
        const stored: types.Stored = .{ .entry = .{ .title = "bad", .kind = .supplemental, .display_title = &images, .media = media } };
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        // Construct an otherwise ordinary C record directly so decode's full
        // Entry validation is independently tested after the asset vector exists.
        encoder.out.clearRetainingCapacity();
        try encoder.out.appendSlice(a, reference_blocks_magic);
        try encoder.spans(&images);
        try encoder.sections(@as([]const types.Section, &.{}));
        try encoder.spans(@as([]const types.Span, &.{}));
        try encoder.layout(types.Layout{});
        try encoder.references(@as([]const types.Reference, &.{}));
        try encoder.media(media);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, encoder.out.items, "bad", .supplemental, null));
    }
}

test "DPRC zero text image occurrences spend shared items and table depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{ .image = .{ .file = "Icon.svg", .width_px = 15 } }};
    var encoder: Encoder = .{ .a = a, .version = .reference_blocks, .remaining_items = 1 };
    defer encoder.deinit();
    try encoder.spans(&spans);
    try std.testing.expectEqual(@as(usize, 0), encoder.remaining_items);
    var reader: Reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items, .remaining_items = 1 };
    try std.testing.expectEqual(@as(usize, 1), (try reader.spans()).len);
    try std.testing.expectEqual(@as(usize, 0), reader.remaining_items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = encoder.out.items, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, reader.spans());
    try std.testing.expectError(error.PresentationTooLarge, encoder.spans(&spans));
    var cells: [types.max_table_depth + 1][1]types.Cell = undefined;
    var rows: [types.max_table_depth + 1][1]types.Row = undefined;
    var tables: [types.max_table_depth + 1]types.Table = undefined;
    var i: usize = tables.len;
    while (i != 0) {
        i -= 1;
        cells[i] = .{.{ .nested_table = if (i + 1 < tables.len) tables[i + 1] else null }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .caption = if (i + 1 == tables.len) &spans else &.{}, .rows = &rows[i] };
    }
    var blocks = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .blocks = &blocks }};
    const media = [_]types.Media{.{ .file = "Icon.svg", .kind = .image, .caption = "" }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .supplemental, .references = &refs, .media = &media } };
    const valid = try encodeAlloc(a, stored);
    var metrics: DecodeMetrics = .{};
    _ = try decodeWithMetricsAlloc(a, valid, "depth", .supplemental, null, &metrics);
    try std.testing.expectEqual(types.max_table_depth, metrics.tables);
    blocks[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "depth", .supplemental, null));
}

test "DPRD border flag preserves C bytes and rejects old version and reserved flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image: types.InlineImage = .{ .file = "Flag.svg", .width_px = 40, .border = true };
    var d: Encoder = .{ .a = a, .version = .image_border };
    defer d.deinit();
    try d.inlineImage(image);
    const golden = [_]u8{ 1, 8, 0, 0, 0, 'F', 'l', 'a', 'g', '.', 's', 'v', 'g', 17, 40, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &golden, d.out.items);
    var reader: Reader = .{ .a = a, .version = .image_border, .bytes = &golden };
    try std.testing.expectEqualDeep(image, (try reader.inlineImage()).?);
    var c: Encoder = .{ .a = a, .version = .reference_blocks };
    defer c.deinit();
    try std.testing.expectError(error.InvalidPresentation, c.inlineImage(image));
    reader = .{ .a = a, .version = .reference_blocks, .bytes = &golden };
    try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    for ([_]u8{ 0x20, 0x40, 0x80 }) |reserved| {
        var invalid = golden;
        invalid[13] |= reserved;
        reader = .{ .a = a, .version = .image_border, .bytes = &invalid };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    for (0..golden.len) |len| {
        reader = .{ .a = a, .version = .image_border, .bytes = golden[0..len] };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    var plain = image;
    plain.border = false;
    try c.inlineImage(plain);
    d.out.clearRetainingCapacity();
    try d.inlineImage(plain);
    try std.testing.expectEqualSlices(u8, c.out.items, d.out.items);
    reader = .{ .a = a, .version = .reference_blocks, .bytes = c.out.items };
    try std.testing.expect(!(try reader.inlineImage()).?.border);
    d.out.clearRetainingCapacity();
    try d.spans(&[_]types.Span{.{}});
    try std.testing.expectEqual(@as(usize, 39), d.out.items.len);
    try std.testing.expectEqual(@as(u8, 0), d.out.items[38]);
    try std.testing.expectError(error.InvalidPresentation, d.span(types.Span{ .text = "raw", .image = image }));
    try std.testing.expectError(error.InvalidPresentation, d.span(types.Span{ .kind = .line_break, .image = image }));
}

test "border false keeps C selection while D generic build preserves actions and full validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const media = [_]types.Media{.{ .file = "Flag.svg", .kind = .image, .caption = "" }};
    var spans = [_]types.Span{.{ .kind = .link, .target = "File:Flag.svg", .image = .{ .file = "Flag.svg", .width_px = 40 } }};
    const stored: types.Stored = .{ .entry = .{ .title = "image-border-contract", .kind = .supplemental, .display_title = &spans, .media = &media } };
    const legacy = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPRC", legacy[0..4]);
    spans[0].image.?.border = true;
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPRD", bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "image-border-contract", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, &spans, @as([]const types.Section, &.{}), types.Layout{}, @as([]const types.Reference, &.{}), &media));
    const invalid = try a.dupe(u8, bytes);
    @memcpy(invalid[0..4], "DPRC");
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invalid, "image-border-contract", .supplemental, null));
    var missing = stored;
    missing.entry.media = &.{};
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, missing));
    spans[0].image.?.border = false;
    try std.testing.expectEqualSlices(u8, legacy, try encodeAlloc(a, stored));
}

test "DPRD border discovery covers every nested image sink without changing body fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image = [_]types.Span{.{ .kind = .link, .target = "File:Vraagteken-2.svg", .image = .{ .file = "Vraagteken-2.svg", .width_px = 15, .border = true }, .foreground = "#123456", .background = "#abcdef", .font_scale = 1.25, .font_scale_basis = .normal_body }};
    const blank: []const types.Span = &.{};
    const media = [_]types.Media{.{ .file = "Vraagteken-2.svg", .kind = .image, .caption = "metadata" }};
    for (0..12) |location| {
        const child_cells = [_]types.Cell{.{ .spans = if (location == 6) &image else blank }};
        const child_rows = [_]types.Row{.{ .cells = &child_cells }};
        const child: types.Table = .{ .caption = if (location == 5 or location == 8) &image else blank, .rows = &child_rows };
        const cell_blocks = [_]types.Block{
            .{ .kind = .paragraph, .spans = if (location == 7) &image else blank },
            .{ .kind = .table, .table = if (location == 8) child else null },
        };
        const cells = [_]types.Cell{.{ .spans = if (location == 4) &image else blank, .nested_table = if (location == 5 or location == 6) child else null, .blocks = if (location == 7 or location == 8) &cell_blocks else null }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{
            .{ .kind = .heading, .level = 3, .anchor = "Stable_anchor", .spans = if (location == 2) &image else blank },
            .{ .kind = .table, .table = .{ .caption = if (location == 3) &image else blank, .rows = &rows } },
        };
        const sections = [_]types.Section{.{ .level = 2, .title = "Stable title", .anchor = "Stable_section", .blocks = &blocks }};
        const reference_blocks = [_]types.Block{
            .{ .kind = .paragraph, .spans = if (location == 10) &image else blank },
            .{ .kind = .table, .table = if (location == 11) .{ .caption = &image } else null },
        };
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 9) &image else blank, .blocks = if (location >= 10) &reference_blocks else null }};
        const stored: types.Stored = .{ .entry = .{ .title = "sinks", .kind = .supplemental, .display_title = if (location == 0) &image else blank, .preamble_spans = if (location == 1) &image else blank, .sections = &sections, .references = &refs, .media = &media } };
        try std.testing.expect(hasInlineImages(stored.entry.display_title, &sections, stored.entry.preamble_spans, &refs));
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(image_border_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "sinks", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualStrings("Stable title", decoded.entry.sections[0].title);
        try std.testing.expectEqualStrings("Stable_anchor", decoded.entry.sections[0].blocks[0].anchor);
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    }
}

test "DPRE block suffix follows old payload for every block kind and preserves legacy bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (comptime std.meta.tags(types.BlockKind)) |kind| {
        if (comptime kind == .container) continue;
        var old: Encoder = .{ .a = a, .version = .image_border };
        defer old.deinit();
        var next: Encoder = .{ .a = a, .version = .block_layout };
        defer next.deinit();
        const empty: types.Block = .{ .kind = kind };
        try old.block(empty);
        try std.testing.expectEqual(@as(usize, 25), old.out.items.len);
        try next.block(empty);
        try std.testing.expectEqualSlices(u8, old.out.items, next.out.items[0..25]);
        try std.testing.expectEqual(@as(u8, 0), next.out.items[25]);
        for ([_]types.CellTextAlign{ .left, .center, .right }, 0..) |alignment, tag| {
            next.out.clearRetainingCapacity();
            var aligned = empty;
            aligned.text_align = alignment;
            try next.block(aligned);
            try std.testing.expectEqualSlices(u8, old.out.items, next.out.items[0..25]);
            try std.testing.expectEqualSlices(u8, &.{ 1, @intCast(tag) }, next.out.items[25..]);
            var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = next.out.items };
            try std.testing.expectEqualDeep(aligned, try reader.block());
            try std.testing.expectEqual(next.out.items.len, reader.pos);
        }
    }
    // A frozen empty paragraph is 25 bytes through D; E adds only its suffix.
    const golden = [_]u8{ @intFromEnum(types.BlockKind.paragraph), 0, 0 } ++ @as([22]u8, @splat(0));
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime hasLFields(version)) continue;
        if (comptime version != .block_layout and (version != .explicit_targets and (version != .dynamic_catalog and (version != .tooltips and (version != .block_geometry and (version != .image_maps and version != .inline_table_styles)))))) {
            var encoder: Encoder = .{ .a = a, .version = version };
            defer encoder.deinit();
            try encoder.block(types.Block{ .kind = .paragraph, .text_align = null });
            try std.testing.expectEqualSlices(u8, golden[0..if (comptime hasAnchorFields(version)) @as(usize, 25) else 17], encoder.out.items);
        }
    }
    // K carries the same legacy prefix plus E alignment, I geometry and the
    // two J Figure/Flow presence bytes. It is not an old-through-D frame.
    var current: Encoder = .{ .a = a, .version = .inline_table_styles };
    defer current.deinit();
    const empty: types.Block = .{ .kind = .paragraph };
    try current.block(empty);
    try std.testing.expectEqualSlices(u8, &golden, current.out.items[0..25]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, current.out.items[25..]);
    var current_reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = current.out.items };
    try std.testing.expectEqualDeep(empty, try current_reader.block());
    try std.testing.expectEqual(current.out.items.len, current_reader.pos);
}

test "DPRE table float flags follow existing style fields and reject C D reinterpretation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder: Encoder = .{ .a = a, .version = .block_layout };
    defer encoder.deinit();
    for ([_]types.TableFloatSide{ .left, .right }, 0..) |side, tag| {
        encoder.out.clearRetainingCapacity();
        try encoder.tableStyle(.{ .float_side = side });
        try std.testing.expectEqualSlices(u8, &.{ 1, 16, @intCast(tag) }, encoder.out.items);
        var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = encoder.out.items };
        try std.testing.expectEqual(@as(?types.TableFloatSide, side), (try reader.tableStyle()).?.float_side);
        for ([_]Version{ .reference_blocks, .image_border }) |version| {
            reader = .{ .a = a, .version = version, .bytes = encoder.out.items };
            try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
            var old: Encoder = .{ .a = a, .version = version };
            defer old.deinit();
            try std.testing.expectError(error.InvalidPresentation, old.tableStyle(.{ .float_side = side }));
        }
    }
    var style: types.TableStyle = .{ .background = "#123456", .border = .none, .collapse = .collapse, .margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) };
    var old: Encoder = .{ .a = a, .version = .image_border };
    defer old.deinit();
    try old.tableStyle(style);
    encoder.out.clearRetainingCapacity();
    try encoder.tableStyle(style);
    try std.testing.expectEqualSlices(u8, old.out.items, encoder.out.items);
    style.float_side = .right;
    encoder.out.clearRetainingCapacity();
    try encoder.tableStyle(style);
    try std.testing.expectEqual(@as(u8, 31), encoder.out.items[1]);
    try std.testing.expectEqualSlices(u8, old.out.items[2..], encoder.out.items[2 .. encoder.out.items.len - 1]);
    try std.testing.expectEqual(@as(u8, 1), encoder.out.items[encoder.out.items.len - 1]);
}

test "DPRE rejects invalid presence enum reserved flags truncation and impossible block counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder: Encoder = .{ .a = a, .version = .block_layout };
    defer encoder.deinit();
    try encoder.block(types.Block{ .kind = .paragraph, .text_align = .right });
    const block_bytes = try a.dupe(u8, encoder.out.items);
    for (0..block_bytes.len) |len| {
        var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = block_bytes[0..len] };
        try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    for ([_]struct { offset: usize, byte: u8 }{ .{ .offset = 25, .byte = 2 }, .{ .offset = 26, .byte = 3 }, .{ .offset = 26, .byte = 255 } }) |bad| {
        const invalid = try a.dupe(u8, block_bytes);
        invalid[bad.offset] = bad.byte;
        var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = invalid };
        try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    for ([_][]const u8{ &.{ 1, 16 }, &.{ 1, 16, 2 }, &.{ 1, 32, 0 }, &.{ 1, 64, 0 }, &.{ 1, 128, 0 }, &.{ 1, 0 }, &.{2} }) |invalid| {
        var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = invalid };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    encoder.out.clearRetainingCapacity();
    try encoder.writeU32(1);
    try encoder.out.appendSlice(a, block_bytes[0..25]);
    var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = encoder.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.blocks());
    reader = .{ .a = a, .version = .block_layout, .bytes = &.{ 255, 255, 255, 255 } };
    try std.testing.expectError(error.InvalidPresentation, reader.blocks());
}

test "DPRE discovery traverses section reference nested table and ordered cell block sinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rich = [_]types.Span{.{ .kind = .link, .text = "middle", .target = "Destination#part", .trail = "s", .foreground = "#123456", .background = "#abcdef", .font_scale = 1.25, .font_scale_basis = .normal_body, .italic = true }};
    const icon = [_]types.Span{.{ .kind = .link, .target = "File:Flag.svg", .image = .{ .file = "Flag.svg", .border = true } }};
    const media = [_]types.Media{.{ .file = "Flag.svg", .kind = .image, .caption = "authored metadata" }};
    for (0..8) |location| {
        const inner_blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &rich, .text_align = if (location == 2 or location == 6) .center else null }};
        const inner_cells = [_]types.Cell{.{ .blocks = &inner_blocks, .style = .{ .text_align = .right } }};
        const inner_rows = [_]types.Row{.{ .cells = &inner_cells }};
        const inner: types.Table = .{ .rows = &inner_rows, .style = if (location == 3 or location == 7) .{ .float_side = .right, .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0 }) } else null };
        const cells = [_]types.Cell{.{ .nested_table = inner, .colspan = 2, .background = "#b4cdcd" }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const table: types.Table = .{ .rows = &rows, .caption = &rich, .style = if (location == 1 or location == 5) .{ .float_side = .left } else null };
        const blocks = [_]types.Block{
            .{ .kind = .heading, .level = 3, .anchor = "Stable", .anchor_fallback = "stable", .spans = &rich },
            .{ .kind = .paragraph, .spans = &rich, .text_align = if (location == 0 or location == 4) .left else null },
            .{ .kind = .table, .table = table },
        };
        const sections = [_]types.Section{.{ .level = 2, .title = "Owner", .blocks = if (location < 4) &blocks else &.{} }};
        const refs = [_]types.Reference{.{ .number = 9, .group_number = 2, .group = "g", .name = "n", .blocks = if (location >= 4) &blocks else null }};
        const stored: types.Stored = .{ .entry = .{ .title = "layout", .kind = .supplemental, .display_title = &icon, .sections = &sections, .references = &refs, .media = &media } };
        const encoded = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings("DPRE", encoded[0..4]);
        const decoded = try decodeAlloc(a, encoded, "layout", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
        try std.testing.expectEqualSlices(u8, encoded, try encodeBuildAlloc(a, &icon, &sections, types.Layout{}, &refs, &media));
        try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    }
}

test "DPRE selection is conditional and generic old blocks preserve exact prior versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const OldBlock = struct { kind: types.BlockKind = .paragraph, depth: u8 = 0, level: u8 = 0, spans: []const types.Span = &.{}, feature: ?types.Feature = null, list_path: []const u8 = "", number: []const u8 = "", table: ?types.Table = null, anchor: []const u8 = "", anchor_fallback: []const u8 = "" };
    const old_sections = [_]struct { level: u8 = 2, title: []const u8 = "Owner", anchor: []const u8 = "", anchor_fallback: []const u8 = "", blocks: []const OldBlock }{.{ .blocks = &.{.{}} }};
    var blocks = [_]types.Block{.{ .kind = .paragraph }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Owner", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "conditional", .kind = .supplemental, .sections = &sections } };
    const legacy = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPR2", legacy[0..4]);
    try std.testing.expectEqualSlices(u8, legacy, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &old_sections, types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{})));
    for ([_]types.CellTextAlign{ .left, .center, .right }) |alignment| {
        blocks[0].text_align = alignment;
        const encoded = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings("DPRE", encoded[0..4]);
        try std.testing.expectEqualDeep(stored, try decodeAlloc(a, encoded, "conditional", .supplemental, null));
        const downgraded = try a.dupe(u8, encoded);
        @memcpy(downgraded[0..4], "DPRD");
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, downgraded, "conditional", .supplemental, null));
    }
    blocks[0].text_align = null;
    try std.testing.expectEqualSlices(u8, legacy, try encodeAlloc(a, stored));
}

test "DPRE retains shared item depth limits and propagates allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = [_]types.Block{.{ .kind = .paragraph, .text_align = .center }};
    var limited: Encoder = .{ .a = a, .version = .block_layout, .remaining_items = 0 };
    defer limited.deinit();
    try std.testing.expectError(error.PresentationTooLarge, limited.blocks(&blocks));
    var full: Encoder = .{ .a = a, .version = .block_layout };
    defer full.deinit();
    try full.blocks(&blocks);
    var reader: Reader = .{ .a = a, .version = .block_layout, .bytes = full.out.items, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, reader.blocks());
    const cells = [_]types.Cell{.{ .blocks = &blocks }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const table: types.Table = .{ .rows = &rows, .style = .{ .float_side = .right } };
    var depth: Encoder = .{ .a = a, .version = .block_layout, .table_depth = types.max_table_depth };
    defer depth.deinit();
    try std.testing.expectError(error.InvalidPresentation, depth.table(@as(?types.Table, table)));
    full.out.clearRetainingCapacity();
    try full.table(@as(?types.Table, table));
    reader = .{ .a = a, .version = .block_layout, .bytes = full.out.items, .table_depth = types.max_table_depth };
    try std.testing.expectError(error.InvalidPresentation, reader.table());
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var oom: Encoder = .{ .a = failing.allocator(), .version = .block_layout };
    defer oom.deinit();
    try std.testing.expectError(error.OutOfMemory, oom.blocks(&blocks));
    failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    reader = .{ .a = failing.allocator(), .version = .block_layout, .bytes = &([_]u8{ 1, 0, 0, 0 } ++ @as([26]u8, @splat(0))) };
    try std.testing.expectError(error.OutOfMemory, reader.blocks());
}

test "DPRE catalog capacity preserves legacy image bounds and exact small payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const media = try a.alloc(types.Media, types.legacy_extended_image_assets + 1);
    const spans = try a.alloc(types.Span, media.len);
    for (media, spans, 0..) |*asset, *span, index| {
        const file = try std.fmt.allocPrint(a, "Flag-{d}.svg", .{index});
        asset.* = .{ .file = file, .kind = .image, .caption = file };
        span.* = .{ .kind = .link, .target = try std.fmt.allocPrint(a, "File:{s}", .{file}),
            .image = .{ .file = file, .width_px = 30 } };
    }
    for ([_]usize{ 128, 129, 193, 256 }) |count| {
        const stored: types.Stored = .{ .entry = .{ .title = "catalog", .kind = .supplemental,
            .display_title = spans[0..count], .media = media[0..count] } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(if (count > 128) block_layout_magic else reference_blocks_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "catalog", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title,
            stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        // No block/alignment fields occur in this fixture, so the C/D/E wire
        // after the magic is identical. This isolates catalog-version admission.
        for ([_][]const u8{ reference_blocks_magic, image_border_magic, block_layout_magic }) |version_magic| {
            const forced = try a.dupe(u8, bytes);
            @memcpy(forced[0..4], version_magic);
            if (count > 128 and !std.mem.eql(u8, version_magic, block_layout_magic)) {
                try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, forced, "catalog", .supplemental, null));
            } else {
                try std.testing.expectEqualDeep(stored, try decodeAlloc(a, forced, "catalog", .supplemental, null));
            }
        }
        if (count == 128) {
            var old: Encoder = .{ .a = a, .version = .reference_blocks };
            defer old.deinit();
            try old.out.appendSlice(a, reference_blocks_magic);
            try old.spans(stored.entry.display_title);
            try old.sections(stored.entry.sections);
            try old.spans(stored.entry.preamble_spans);
            try old.layout(stored.entry.organization);
            try old.references(stored.entry.references);
            try old.media(stored.entry.media);
            try std.testing.expectEqualSlices(u8, old.out.items, bytes);
        }
    }
    const overflow: types.Stored = .{ .entry = .{ .title = "catalog", .kind = .supplemental,
        .display_title = spans, .media = media } };
    const extended = try encodeAlloc(a, overflow);
    try std.testing.expectEqualStrings(dynamic_catalog_magic, extended[0..4]);
    try std.testing.expectEqualDeep(overflow, try decodeAlloc(a, extended, overflow.entry.title, .supplemental, null));
    try types.validateStored(std.testing.allocator, overflow, "catalog", .supplemental, null);
    // Construct the oversized E wire directly so decoder rejection is tested
    // independently of the encoder's admission check.
    var bad: Encoder = .{ .a = a, .version = .block_layout };
    defer bad.deinit();
    try bad.out.appendSlice(a, block_layout_magic);
    try bad.spans(spans);
    try bad.sections(overflow.entry.sections);
    try bad.spans(overflow.entry.preamble_spans);
    try bad.layout(overflow.entry.organization);
    try bad.references(overflow.entry.references);
    try bad.media(media);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad.out.items, "catalog", .supplemental, null));
    // Historical media-only records had no128 bound. Preserve their admission.
    var historical: Encoder = .{ .a = a, .version = .plain };
    defer historical.deinit();
    try historical.out.appendSlice(a, magic);
    try historical.spans(@as([]const types.Span, &.{}));
    try historical.sections(overflow.entry.sections);
    try historical.spans(overflow.entry.preamble_spans);
    try historical.layout(overflow.entry.organization);
    try historical.references(overflow.entry.references);
    try historical.media(media);
    const old_media_only = try decodeAlloc(a, historical.out.items, "catalog", .supplemental, null);
    try std.testing.expectEqualDeep(@as([]const types.Media, media), old_media_only.entry.media);
    try std.testing.expectEqual(@as(usize, 0), old_media_only.entry.display_title.len);
}

test "DPRE extended catalog retains image joins layout and corruption guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const assets = try a.alloc(types.Media, 193);
    for (assets, 0..) |*asset, index| asset.* = .{
        .file = try std.fmt.allocPrint(a, "Asset-{d}.svg", .{index}), .kind = .image, .caption = "" };
    const image: types.Span = .{ .kind = .link, .target = "File:Asset-192.svg", .bold = true,
        .image = .{ .file = assets[192].file, .width_px = 30, .border = true, .alt = "flag", .tooltip = "country" } };
    const cells = [_]types.Cell{.{ .spans = &.{image} }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .text_align = .center,
        .table = .{ .rows = &rows, .style = .{ .float_side = .left } } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Flags", .blocks = &blocks }};
    var stored: types.Stored = .{ .entry = .{ .title = "layout", .kind = .supplemental,
        .sections = &sections, .media = assets } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_layout_magic, bytes[0..4]);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, "layout", .supplemental, null));
    const last = assets[192];
    assets[192].kind = .audio;
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    assets[192] = last;
    assets[0] = last;
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    stored.entry.media = assets[0..0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    for ([_][]const u8{ bytes[0 .. bytes.len - 1], try std.mem.concat(a, u8, &.{bytes, &.{0}}) }) |corrupt|
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, corrupt, "layout", .supplemental, null));
}

test "explicit internal target components roundtrip literal hash and preserve legacy payload bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{ .kind = .link, .text = "ISBN 9781234567890#tail", .target = "Special:Booksources/9781234567890#tail", .target_fragment = "", .bold = true }};
    const sections = [_]types.Section{.{ .title = "English", .level = 2, .blocks = &.{.{ .kind = .paragraph, .spans = &spans }} }};
    const expected: types.Stored = .{ .entry = .{ .title = "ISBN", .kind = .language, .language = "English", .language_code = "en", .sections = &sections } };
    const bytes = try encodeAlloc(a, expected);
    try std.testing.expectEqualStrings(explicit_targets_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "ISBN", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualStrings("", decoded.entry.sections[0].blocks[0].spans[0].target_fragment.?);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const legacy_spans = [_]types.Span{.{ .kind = .link, .text = "ordinary", .target = "page#section" }};
    const legacy_sections = [_]types.Section{.{ .title = "English", .level = 2, .blocks = &.{.{ .kind = .paragraph, .spans = &legacy_spans }} }};
    const legacy: types.Stored = .{ .entry = .{ .title = "legacy", .kind = .language, .language = "English", .language_code = "en", .sections = &legacy_sections } };
    const old_bytes = try encodeAlloc(a, legacy);
    try std.testing.expectEqualStrings(magic, old_bytes[0..4]);
    const old_decoded = try decodeAlloc(a, old_bytes, "legacy", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expect(old_decoded.entry.sections[0].blocks[0].spans[0].target_fragment == null);
    try std.testing.expectEqualSlices(u8, old_bytes, try encodeAlloc(a, old_decoded));
    const bad_spans = [_]types.Span{.{ .text = "not an action", .target_fragment = "" }};
    const bad_sections = [_]types.Section{.{ .title = "English", .level = 2, .blocks = &.{.{ .kind = .paragraph, .spans = &bad_spans }} }};
    const invalid: types.Stored = .{ .entry = .{ .title = "invalid", .kind = .language, .language = "English", .language_code = "en", .sections = &bad_sections } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, invalid));
}
test "DPRF validates component kinds and inherits193 and256 inline media capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const media = try a.alloc(types.Media, types.legacy_extended_image_assets + 1);
    const spans = try a.alloc(types.Span, media.len + 1);
    spans[0] = .{ .kind = .link, .text = "ISBN 9781234567890#tail", .target = "Special:Booksources/9781234567890#tail", .target_fragment = "" };
    for (media, spans[1..], 0..) |*asset, *span, index| {
        const file = try std.fmt.allocPrint(a, "Flag-{d}.svg", .{index});
        asset.* = .{ .file = file, .kind = .image, .caption = file };
        span.* = .{ .kind = .link, .target = try std.fmt.allocPrint(a, "File:{s}", .{file}), .image = .{ .file = file, .width_px = 30 } };
    }
    for ([_]usize{ 193, 256 }) |count| {
        const stored: types.Stored = .{ .entry = .{ .title = "explicit catalog", .kind = .supplemental, .display_title = spans[0 .. count + 1], .media = media[0..count] } };
        try types.validateStored(std.testing.allocator, stored, "explicit catalog", .supplemental, null);
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(explicit_targets_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "explicit catalog", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    }
    const overflow: types.Stored = .{ .entry = .{ .title = "explicit catalog", .kind = .supplemental, .display_title = spans, .media = media } };
    try types.validateStored(std.testing.allocator, overflow, "explicit catalog", .supplemental, null);
    const extended = try encodeAlloc(a, overflow);
    try std.testing.expectEqualStrings(dynamic_catalog_magic, extended[0..4]);
    try std.testing.expectEqualDeep(overflow, try decodeAlloc(a, extended, overflow.entry.title, .supplemental, null));
    var raw: Encoder = .{ .a = a, .version = .explicit_targets };
    defer raw.deinit();
    try raw.out.appendSlice(a, explicit_targets_magic);
    try raw.spans(spans);
    try raw.sections(overflow.entry.sections);
    try raw.spans(overflow.entry.preamble_spans);
    try raw.layout(overflow.entry.organization);
    try raw.references(overflow.entry.references);
    try raw.media(overflow.entry.media);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, raw.out.items, "explicit catalog", .supplemental, null));
    for ([_]types.InlineKind{ .text, .external_link, .line_break }) |kind| {
        var bad = [_]types.Span{.{ .kind = kind, .text = "data", .target = "title", .target_fragment = "" }};
        const invalid: types.Stored = .{ .entry = .{ .title = "invalid", .kind = .supplemental, .display_title = &bad } };
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, invalid, "invalid", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, invalid));
        // Decoder's independent raw-byte kind gate must match model validation.
        var encoded: Encoder = .{ .a = a, .version = .explicit_targets };
        defer encoded.deinit();
        bad[0].kind = .link;
        try encoded.span(bad[0]);
        encoded.out.items[0] = @intFromEnum(kind);
        var reader: Reader = .{ .a = a, .version = .explicit_targets, .bytes = encoded.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.span());
    }
    const local_spans = [_]types.Span{.{ .kind = .link, .text = "local", .target_fragment = "reference-1" }};
    const local: types.Stored = .{ .entry = .{ .title = "local", .kind = .supplemental, .display_title = &local_spans } };
    const local_bytes = try encodeAlloc(a, local);
    try std.testing.expectEqualDeep(local, try decodeAlloc(a, local_bytes, "local", .supplemental, null));
    var minimum: Encoder = .{ .a = a, .version = .explicit_targets };
    defer minimum.deinit();
    try minimum.span(types.Span{});
    try std.testing.expectEqual(@as(usize, 36), minimum.out.items.len);
    var minimum_reader: Reader = .{ .a = a, .version = .explicit_targets, .bytes = minimum.out.items };
    try std.testing.expectEqualDeep(types.Span{}, try minimum_reader.span());
    var empty_block: Encoder = .{ .a = a, .version = .explicit_targets };
    defer empty_block.deinit();
    try empty_block.block(types.Block{ .kind = .paragraph });
    try std.testing.expectEqual(@as(usize, 26), empty_block.out.items.len);
    var block_reader: Reader = .{ .a = a, .version = .explicit_targets, .bytes = empty_block.out.items };
    try std.testing.expectEqualDeep(types.Block{ .kind = .paragraph }, try block_reader.block());
}

test "explicit target component strings retain wire UTF8 and size validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const oversized = try a.alloc(u8, max_string_bytes + 1);
    for ([_][]const u8{ "\xff", oversized }) |fragment| {
        const spans = [_]types.Span{.{ .kind = .link, .text = "local", .target_fragment = fragment }};
        const stored: types.Stored = .{ .entry = .{ .title = "fragment", .kind = .supplemental, .display_title = &spans } };
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(std.testing.allocator, stored, "fragment", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    }
    // A separately constructed malformed component exercises Reader.string.
    var encoded: Encoder = .{ .a = a, .version = .explicit_targets };
    defer encoded.deinit();
    try encoded.span(types.Span{ .kind = .link, .target_fragment = "X" });
    encoded.out.items[encoded.out.items.len - 1] = 0xff;
    var reader: Reader = .{ .a = a, .version = .explicit_targets, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.span());
}


test "DPRG preserves280 catalog identities all image sinks F components and legacy rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const media = try a.alloc(types.Media, 280);
    for (media, 0..) |*item, index| item.* = .{ .file = try std.fmt.allocPrint(a, "Flag-{d}.svg", .{index}), .kind = .image, .caption = "catalog" };
    const image: types.Span = .{ .kind = .link, .target = "File:Flag-279.svg", .target_fragment = "", .bold = true,
        .foreground = "#123456", .font_scale = 1.2, .font_scale_basis = .normal_body,
        .image = .{ .file = media[279].file, .width_px = 21, .border = true, .alt = "flag" } };
    const images = [_]types.Span{image};
    const paragraph = [_]types.Block{.{ .kind = .paragraph, .spans = &images, .text_align = .center }};
    const simple: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &images, .background = "#abcdef" }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = simple }} }} };
    const children: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &paragraph }} }} };
    const caption: types.Table = .{ .caption = &images, .rows = &.{}, .style = .{ .float_side = .right } };
    const cases = [_]types.Entry{
        .{ .title = "sinks", .kind = .supplemental, .display_title = &images },
        .{ .title = "sinks", .kind = .supplemental, .preamble_spans = &images },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &paragraph }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "caption", .blocks = &.{.{ .kind = .table, .table = caption }} }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = simple }} }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "children", .blocks = &.{.{ .kind = .table, .table = children }} }} },
        .{ .title = "sinks", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .spans = &images }} },
        .{ .title = "sinks", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &paragraph }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = media;
        try types.validateStored(a, stored, "sinks", .supplemental, null);
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(dynamic_catalog_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "sinks", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        // G inherits F's complete layout; changing only its marker must fail
        // the older typed catalog boundary, not accidentally admit the payload.
        const old = try a.dupe(u8, bytes);
        @memcpy(old[0..4], explicit_targets_magic);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, "sinks", .supplemental, null));
        const last = media[279];
        media[279].kind = .audio;
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "sinks", .supplemental, null));
        media[279] = last;
        const first = media[0];
        media[0] = last;
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "sinks", .supplemental, null));
        media[0] = first;
        stored.entry.media = media[0..279];
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "sinks", .supplemental, null));
    }
}

test "DPRG catalog allocation obeys existing aggregate byte and allocator guards" {
    const a = std.testing.allocator;
    var excessive: [4]u8 = undefined;
    std.mem.writeInt(u32, &excessive, max_items + 1, .little);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var reader: Reader = .{ .a = failing.allocator(), .version = .dynamic_catalog, .bytes = &excessive };
    try std.testing.expectError(error.InvalidPresentation, reader.media());
    var truncated: [4]u8 = undefined;
    std.mem.writeInt(u32, &truncated, 280, .little);
    reader = .{ .a = failing.allocator(), .version = .dynamic_catalog, .bytes = &truncated };
    try std.testing.expectError(error.InvalidPresentation, reader.media());
    var framed: [4 + 9 * 280]u8 = @splat(0);
    std.mem.writeInt(u32, framed[0..4], 280, .little);
    reader = .{ .a = failing.allocator(), .version = .dynamic_catalog, .bytes = &framed, .remaining_items = 279 };
    try std.testing.expectError(error.InvalidPresentation, reader.media());
    reader = .{ .a = failing.allocator(), .version = .dynamic_catalog, .bytes = &framed };
    try std.testing.expectError(error.OutOfMemory, reader.media());
}

test "indexed Stored validation cleans allocation failures and preserves unreferenced duplicate media" {
    const Case = struct {
        fn run(a: A) !void {
            var media: [280]types.Media = @splat(.{ .file = "unused.svg", .kind = .audio, .caption = "unchanged" });
            media[279] = .{ .file = "visible.svg", .kind = .image, .caption = "visible" };
            const span = [_]types.Span{.{ .kind = .link, .target = "File:visible.svg", .image = .{ .file = "visible.svg", .width_px = 21 } }};
            const stored: types.Stored = .{ .entry = .{ .title = "indexed", .kind = .supplemental, .display_title = &span, .media = &media } };
            try types.validateStored(a, stored, "indexed", .supplemental, null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "DPRH preserves nullable advice in every recursive span sink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "literal \"quoted\" & <advice>\nsecond line" }) |advice| {
        const rich = [_]types.Span{.{ .kind = .link, .text = "visible", .target = "Target", .target_fragment = "", .trail = "s", .explanation = "abbreviation expansion", .tooltip = advice, .classes = "API", .language = "sg", .direction = "ltr", .italic = true, .foreground = "#123456", .background = "#ccffff", .font_scale = 0, .font_scale_basis = .normal_body }};
        const paragraph = [_]types.Block{.{ .kind = .paragraph, .spans = &rich, .text_align = .center }};
        const simple: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &rich }} }} };
        const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = simple }} }} };
        const children: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &paragraph }} }} };
        const caption: types.Table = .{ .caption = &rich, .rows = &.{}, .style = .{ .float_side = .right } };
        const cases = [_]types.Entry{
            .{ .title = "advice", .kind = .supplemental, .display_title = &rich },
            .{ .title = "advice", .kind = .supplemental, .preamble_spans = &rich },
            .{ .title = "advice", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &paragraph }} },
            .{ .title = "advice", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "caption", .blocks = &.{.{ .kind = .table, .table = caption }} }} },
            .{ .title = "advice", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = simple }} }} },
            .{ .title = "advice", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
            .{ .title = "advice", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "children", .blocks = &.{.{ .kind = .table, .table = children }} }} },
            .{ .title = "advice", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .spans = &rich }} },
            .{ .title = "advice", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &paragraph }} },
        };
        for (cases) |entry| {
            const stored: types.Stored = .{ .entry = entry };
            const bytes = try encodeAlloc(a, stored);
            try std.testing.expectEqualStrings(tooltips_magic, bytes[0..4]);
            const decoded = try decodeAlloc(a, bytes, "advice", .supplemental, null);
            try std.testing.expectEqualDeep(stored, decoded);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
            const original_json = try std.json.Stringify.valueAlloc(a, stored, .{});
            try std.testing.expectEqualStrings(original_json, try std.json.Stringify.valueAlloc(a, decoded, .{}));
            if (entry.preamble_spans.len == 0) try std.testing.expectEqualSlices(u8, bytes,
                try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        }
    }
}

test "nullable advice leaves every older raw span framing byte unchanged" {
    const versions = [_]Version{ .plain, .explained, .colored, .anchored, .span_background, .nested_tables, .cell_blocks, .reference_items, .font_scale, .font_scale_basis, .reference_blocks, .image_border, .block_layout, .explicit_targets, .dynamic_catalog, .tooltips };
    const minimum = [_]usize{ 27, 31, 32, 32, 33, 33, 33, 33, 34, 34, 35, 35, 35, 36, 36, 37 };
    for (versions, minimum) |version, size| {
        var encoded: Encoder = .{ .a = std.testing.allocator, .version = version };
        defer encoded.deinit();
        try encoded.span(types.Span{});
        try std.testing.expectEqual(size, encoded.out.items.len);
        try std.testing.expect(std.mem.allEqual(u8, encoded.out.items, 0));
        var reader: Reader = .{ .a = std.testing.allocator, .version = version, .bytes = encoded.out.items };
        const decoded = try reader.span();
        try std.testing.expect(decoded.tooltip == null);
        try std.testing.expectEqual(encoded.out.items.len, reader.pos);
        if ((version != .tooltips and (version != .block_geometry and version != .image_maps))) try std.testing.expectError(error.InvalidPresentation, encoded.span(types.Span{ .tooltip = "" }));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: types.Stored = .{ .entry = .{ .title = "legacy", .kind = .supplemental } };
    const bytes = try encodeAlloc(a, empty);
    const legacy_tail: [28]u8 = @splat(0);
    const legacy_oracle: [32]u8 = [_]u8{ 'D', 'P', 'R', '2' } ++ legacy_tail;
    try std.testing.expectEqualSlices(u8, &legacy_oracle, bytes);
    const old = try decodeAlloc(a, bytes, "legacy", .supplemental, null);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, old));
    // An abbr's own title remains its established explanation. It must not
    // promote an otherwise unchanged explanation-only record to H.
    const abbreviation: types.Stored = .{ .entry = .{ .title = "abbr", .kind = .supplemental,
        .display_title = &.{.{ .text = "abbr", .explanation = "expanded abbreviation", .tooltip = null }} } };
    const explained = try encodeAlloc(a, abbreviation);
    try std.testing.expectEqualStrings(explained_magic, explained[0..4]);
    const expansion = try decodeAlloc(a, explained, "abbr", .supplemental, null);
    try std.testing.expect(expansion.entry.display_title[0].tooltip == null);
    try std.testing.expectEqualStrings("expanded abbreviation", expansion.entry.display_title[0].explanation);
    try std.testing.expectEqualSlices(u8, explained, try encodeAlloc(a, expansion));
    // Effective field pairs after producer inheritance: own abbr advice B,
    // own empty abbr, and generic empty/C overrides inside abbr B.
    for ([_]types.Span{
        .{ .text = "label", .tooltip = null, .explanation = "B" },
        .{ .text = "label", .tooltip = null, .explanation = "" },
        .{ .text = "label", .tooltip = "", .explanation = "B" },
        .{ .text = "label", .tooltip = "C", .explanation = "B" },
    }) |span| {
        const values = [_]types.Span{span};
        const effective: types.Stored = .{ .entry = .{ .title = "effective", .kind = .supplemental, .display_title = &values } };
        const payload = try encodeAlloc(a, effective);
        const expected_magic = if (span.tooltip != null) tooltips_magic else if (span.explanation.len != 0) explained_magic else magic;
        try std.testing.expectEqualStrings(expected_magic, payload[0..4]);
        const result = try decodeAlloc(a, payload, "effective", .supplemental, null);
        try std.testing.expectEqualDeep(span, result.entry.display_title[0]);
    }
}

test "DPRH strict title presence string framing and aggregate guards" {
    const a = std.testing.allocator;
    var encoded: Encoder = .{ .a = a, .version = .tooltips };
    defer encoded.deinit();
    try encoded.span(types.Span{ .tooltip = "" });
    try std.testing.expectEqual(@as(usize, 41), encoded.out.items.len);
    const presence_at = encoded.out.items.len - 5;
    var reader: Reader = .{ .a = a, .version = .tooltips, .bytes = encoded.out.items };
    try std.testing.expectEqualStrings("", (try reader.span()).tooltip.?);
    encoded.out.items[presence_at] = 2;
    reader.pos = 0;
    try std.testing.expectError(error.InvalidPresentation, reader.span());
    encoded.out.items[presence_at] = 1;
    for (presence_at .. encoded.out.items.len) |end| {
        reader = .{ .a = a, .version = .tooltips, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.span());
    }
    std.mem.writeInt(u32, encoded.out.items[presence_at + 1 ..][0..4], max_string_bytes + 1, .little);
    reader = .{ .a = a, .version = .tooltips, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.span());
    encoded.out.clearRetainingCapacity();
    try encoded.span(types.Span{ .tooltip = "x" });
    encoded.out.items[encoded.out.items.len - 1] = 0xff;
    reader = .{ .a = a, .version = .tooltips, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.span());
    try std.testing.expectError(error.InvalidPresentation, encoded.span(types.Span{ .tooltip = "\xff" }));
    encoded.out.clearRetainingCapacity();
    try encoded.spans(&[_]types.Span{.{}});
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    reader = .{ .a = failing.allocator(), .version = .tooltips, .bytes = encoded.out.items, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, reader.spans());
    std.mem.writeInt(u32, encoded.out.items[0..4], 2, .little);
    reader = .{ .a = failing.allocator(), .version = .tooltips, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.spans());
}

test "DPRH retains G dynamic image catalogs and independent image advice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const media = try a.alloc(types.Media, 280);
    for (media, 0..) |*item, index| item.* = .{ .kind = .image, .file = try std.fmt.allocPrint(a, "Advice-{d}.svg", .{index}), .caption = "" };
    const spans = [_]types.Span{.{ .kind = .link, .target = "ImagePage", .target_fragment = "", .tooltip = "outer advice", .font_scale = 0, .font_scale_basis = .normal_body,
        .image = .{ .file = media[279].file, .width_px = 40, .height_px = 20, .border = true, .alt = "visible alt", .tooltip = "" } }};
    const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans, .text_align = .center }};
    const stored: types.Stored = .{ .entry = .{ .title = "images", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .media = media } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(tooltips_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "images", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const unknown = try a.dupe(u8, bytes); @memcpy(unknown[0..4], "DPRK");
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "images", .supplemental, null));
    const last = media[279]; media[279].kind = .audio;
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    media[279] = last;
}

test "DPRH allocation failures preserve null empty and advisory storage" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const spans = [_]types.Span{ .{ .text = "old" }, .{ .text = "suppress", .tooltip = "" }, .{ .kind = .link, .text = "advice", .target = "Target", .tooltip = "literal <advice>\nnext" } };
            const stored: types.Stored = .{ .entry = .{ .title = "allocation", .kind = .supplemental, .display_title = &spans } };
            const bytes = try encodeAlloc(a, stored);
            const decoded = try decodeAlloc(a, bytes, "allocation", .supplemental, null);
            try std.testing.expectEqualDeep(stored, decoded);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "DPRI selects only present paragraph geometry in recursive block sinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const margins: types.StyleEdges = .{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .em, .value = 0.5 }, .bottom = .{ .unit = .px, .value = 3 }, .left = .{ .unit = .em, .value = 1.25 } };
    const padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.25 });
    const rich = [_]types.Span{.{ .kind = .link, .text = "linked", .target = "Target", .target_fragment = "", .trail = "s", .tooltip = "advice", .explanation = "abbreviation", .background = "#ccffff", .font_scale = 0, .font_scale_basis = .normal_body }};
    const styled = [_]types.Block{.{ .kind = .paragraph, .level = 4, .number = "retained", .spans = &rich, .text_align = .center, .style = .{ .margins = margins, .padding = padding } }};
    const inner: types.Table = .{ .caption = &.{.{ .text = "caption" }}, .rows = &.{.{ .cells = &.{.{ .blocks = &styled }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = inner }} }} };
    const cases = [_]types.Entry{
        .{ .title = "geometry", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "ordinary", .blocks = &styled }} },
        .{ .title = "geometry", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = inner }} }} },
        .{ .title = "geometry", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "geometry", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &styled }} },
        .{ .title = "geometry", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{.{ .kind = .table, .table = nested }} }} },
    };
    for (cases) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(block_geometry_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "geometry", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    }
    const without_geometry = [_]types.Block{.{ .kind = .paragraph, .spans = &rich, .text_align = .center, .style = null }};
    const old: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &without_geometry }} } };
    const old_bytes = try encodeAlloc(a, old);
    try std.testing.expectEqualStrings(tooltips_magic, old_bytes[0..4]);
    const old_read = try decodeAlloc(a, old_bytes, "old", .supplemental, null);
    try std.testing.expect(old_read.entry.sections[0].blocks[0].style == null);
    try std.testing.expectEqualSlices(u8, old_bytes, try encodeAlloc(a, old_read));
}

test "DPRI geometry eligibility is enforced by model encoder and decoder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const style: types.BlockStyle = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) };
    const invalid = [_]types.Block{
        .{ .kind = .heading }, .{ .kind = .definition }, .{ .kind = .table },
        .{ .kind = .paragraph, .depth = 1 }, .{ .kind = .paragraph, .list_path = "*" },
        .{ .kind = .paragraph, .table = .{ .rows = &.{} } },
        .{ .kind = .paragraph, .feature = .{ .kind = "audio" } },
    };
    for (invalid) |old| {
        var bad = old; bad.style = style;
        const blocks = [_]types.Block{bad};
        const stored: types.Stored = .{ .entry = .{ .title = "bad", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }} } };
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "bad", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        // Construct the preceding H block unchanged, then append only I's
        // geometry suffix to exercise the decoder's owner validation directly.
        var encoded: Encoder = .{ .a = a, .version = .tooltips };
        defer encoded.deinit();
        try encoded.block(old);
        try encoded.blockStyle(style);
        var reader: Reader = .{ .a = a, .version = .block_geometry, .bytes = encoded.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    const empty = [_]types.Block{.{ .kind = .paragraph, .style = .{} }};
    const empty_stored: types.Stored = .{ .entry = .{ .title = "bad", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &empty }} } };
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, empty_stored, "bad", .supplemental, null));
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, empty_stored));
    var older: Encoder = .{ .a = a, .version = .tooltips };
    defer older.deinit();
    try std.testing.expectError(error.InvalidPresentation, older.block(types.Block{ .kind = .paragraph, .style = style }));
}

test "DPRI geometry framing rejects bad presence mask unit size and truncated edges" {
    const a = std.testing.allocator;
    const style: types.BlockStyle = .{ .margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }), .padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.5 }) };
    var encoded: Encoder = .{ .a = a, .version = .block_geometry };
    defer encoded.deinit();
    try encoded.blockStyle(style);
    try std.testing.expectEqual(@as(usize, 42), encoded.out.items.len);
    for ([_]u8{ 0, 4, 255 }) |mask| {
        encoded.out.items[1] = mask;
        var reader: Reader = .{ .a = a, .version = .block_geometry, .bytes = encoded.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.blockStyle());
    }
    encoded.out.items[1] = 3;
    encoded.out.items[0] = 2;
    var reader: Reader = .{ .a = a, .version = .block_geometry, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.blockStyle());
    encoded.out.items[0] = 1;
    encoded.out.items[2] = 2;
    reader.pos = 0;
    try std.testing.expectError(error.InvalidPresentation, reader.blockStyle());
    encoded.out.items[2] = 0;
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |value| {
        std.mem.writeInt(u32, encoded.out.items[3..7], @bitCast(value), .little);
        reader.pos = 0;
        try std.testing.expectError(error.InvalidPresentation, reader.blockStyle());
        try std.testing.expectError(error.InvalidPresentation, encoded.blockStyle(.{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = value }) }));
    }
    encoded.out.clearRetainingCapacity();
    try encoded.blockStyle(style);
    for (0..encoded.out.items.len) |end| {
        reader = .{ .a = a, .version = .block_geometry, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.blockStyle());
    }
    encoded.out.clearRetainingCapacity();
    try encoded.block(types.Block{ .kind = .paragraph });
    try std.testing.expectEqual(@as(usize, 27), encoded.out.items.len);
    encoded.out.clearRetainingCapacity();
    encoded.version = .tooltips;
    try encoded.block(types.Block{ .kind = .paragraph });
    try std.testing.expectEqual(@as(usize, 26), encoded.out.items.len);
    encoded.out.clearRetainingCapacity();
    encoded.version = .block_geometry;
    try encoded.span(types.Span{});
    try std.testing.expectEqual(@as(usize, 37), encoded.out.items.len);
    encoded.out.clearRetainingCapacity();
    try encoded.blocks(&[_]types.Block{.{ .kind = .paragraph }});
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    reader = .{ .a = failing.allocator(), .version = .block_geometry, .bytes = encoded.out.items, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, reader.blocks());
    std.mem.writeInt(u32, encoded.out.items[0..4], 2, .little);
    reader = .{ .a = failing.allocator(), .version = .block_geometry, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.blocks());
}

test "DPRI geometry allocation rollback retains H advice and G image capacity" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const media = try a.alloc(types.Media, 280);
            for (media, 0..) |*item, index| item.* = .{ .kind = .image, .file = try std.fmt.allocPrint(a, "Geometry-{d}.svg", .{index}), .caption = "" };
            const spans = [_]types.Span{.{ .kind = .link, .target = "ImagePage", .target_fragment = "", .tooltip = "advice", .font_scale = 0, .font_scale_basis = .normal_body,
                .image = .{ .file = media[279].file, .border = true, .alt = "alt", .tooltip = "" } }};
            const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans, .text_align = .center,
                .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } }};
            const stored: types.Stored = .{ .entry = .{ .title = "rollback", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .media = media } };
            const bytes = try encodeAlloc(a, stored);
            try std.testing.expectEqualStrings(block_geometry_magic, bytes[0..4]);
            const decoded = try decodeAlloc(a, bytes, "rollback", .supplemental, null);
            try std.testing.expectEqualDeep(stored, decoded);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "DPRJ occurrence maps round trip every image sink without merging same file maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const negative_zero: f64 = @bitCast(@as(u64, 0x8000000000000000));
    const regions = [_]types.MapRegion{
        .{ .shape = .rectangle, .coordinates = &.{ 20.5, negative_zero, -4.25, -16 }, .action = .{ .kind = .internal, .target = "Same", .target_fragment = null, .label = "first" } },
        .{ .shape = .circle, .coordinates = &.{ 1.7976931348623157e308, -1.7976931348623157e308, -0.5 }, .action = .{ .kind = .internal, .target = "Same", .target_fragment = "", .label = "second" } },
        .{ .shape = .polygon, .coordinates = &.{ -8.5, 0, 4.25, 9.5, negative_zero, -2.75 }, .action = .{ .kind = .external, .target = "https://example.invalid/#part", .label = "literal <third> & line\nnext" } },
    };
    const map: types.ImageMap = .{ .regions = &regions, .default_action = .{ .kind = .internal, .target = "", .target_fragment = "", .label = "" }, .description = .top_left };
    const rich = [_]types.Span{.{ .kind = .link, .target = "File:Shared.svg", .target_fragment = "", .tooltip = "outer advice", .font_scale = 0, .font_scale_basis = .normal_body,
        .image = .{ .file = "Shared.svg", .width_px = 40, .height_px = 20, .border = true, .alt = "alt", .tooltip = "", .map = map } }};
    const paragraph = [_]types.Block{.{ .kind = .paragraph, .spans = &rich, .text_align = .center, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } }};
    const simple: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &rich }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = simple }} }} };
    const children: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &paragraph }} }} };
    const caption: types.Table = .{ .caption = &rich, .rows = &.{}, .style = .{ .float_side = .right } };
    const cases = [_]types.Entry{
        .{ .title = "map", .kind = .supplemental, .display_title = &rich },
        .{ .title = "map", .kind = .supplemental, .preamble_spans = &rich },
        .{ .title = "map", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &paragraph }} },
        .{ .title = "map", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "caption", .blocks = &.{.{ .kind = .table, .table = caption }} }} },
        .{ .title = "map", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = simple }} }} },
        .{ .title = "map", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "map", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "children", .blocks = &.{.{ .kind = .table, .table = children }} }} },
        .{ .title = "map", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .spans = &rich }} },
        .{ .title = "map", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &paragraph }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .kind = .image, .file = "Shared.svg", .caption = "" }};
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "map", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
        if (entry.preamble_spans.len == 0) try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
    }
    var other = rich[0]; other.image.?.map = .{ .description = .none };
    const occurrences = [_]types.Span{ rich[0], other };
    const stored: types.Stored = .{ .entry = .{ .title = "same file", .kind = .supplemental, .display_title = &occurrences, .media = &.{.{ .kind = .image, .file = "Shared.svg", .caption = "" }} } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "same file", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqual(@as(usize, 3), decoded.entry.display_title[0].image.?.map.?.regions.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.display_title[1].image.?.map.?.regions.len);
    try std.testing.expectEqual(types.MapDescription.none, decoded.entry.display_title[1].image.?.map.?.description);
}

test "DPRJ keeps empty maps distinct and no map bytes identical to preceding image frames" {
    var old: Encoder = .{ .a = std.testing.allocator, .version = .block_geometry };
    defer old.deinit();
    var next: Encoder = .{ .a = std.testing.allocator, .version = .image_maps };
    defer next.deinit();
    const image: types.InlineImage = .{ .file = "Shared.svg", .width_px = 40, .alt = "", .tooltip = "", .border = true };
    try old.inlineImage(image); try next.inlineImage(image);
    try std.testing.expectEqualSlices(u8, old.out.items, next.out.items);
    try std.testing.expectError(error.InvalidPresentation, old.inlineImage(.{ .file = "Shared.svg", .map = .{} }));
    next.out.clearRetainingCapacity(); try next.imageMap(.{});
    const empty_map: [6]u8 = .{ 2, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &empty_map, next.out.items);
    inline for (comptime std.meta.tags(types.MapDescription)) |description| {
        next.out.clearRetainingCapacity(); try next.imageMap(.{ .description = description });
        try std.testing.expectEqual(@as(u8, @intFromEnum(description)), next.out.items[0]);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var reader: Reader = .{ .a = arena.allocator(), .version = .image_maps, .bytes = next.out.items };
        try std.testing.expectEqual(description, (try reader.imageMap()).description);
    }
    next.out.clearRetainingCapacity(); try next.span(types.Span{});
    try std.testing.expectEqual(@as(usize, 37), next.out.items.len);
    next.out.clearRetainingCapacity(); try next.block(types.Block{ .kind = .paragraph });
    try std.testing.expectEqual(@as(usize, 29), next.out.items.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{ .image = image }};
    const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } }};
    const stored: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .media = &.{.{ .kind = .image, .file = "Shared.svg", .caption = "" }} } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_geometry_magic, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, try decodeAlloc(a, bytes, "old", .supplemental, null)));
}

test "DPRJ preflight preserves signed zero and charges global budgets metrics only once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const negative_zero: f64 = @bitCast(@as(u64, 0x8000000000000000));
    const regions = [_]types.MapRegion{.{ .shape = .circle, .coordinates = &.{ negative_zero, -1.25, -0.5 }, .action = .{ .kind = .internal, .target = "", .target_fragment = "", .label = "" } }};
    const map: types.ImageMap = .{ .regions = &regions, .default_action = .{ .kind = .internal, .target = "D", .label = "" } };
    var encoded: Encoder = .{ .a = a, .version = .image_maps }; defer encoded.deinit();
    try encoded.imageMap(map);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), std.mem.readInt(u64, encoded.out.items[10..18], .little));
    var metrics: DecodeMetrics = .{};
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = encoded.out.items, .metrics = &metrics };
    const decoded = try reader.imageMap();
    try std.testing.expectEqualDeep(map, decoded);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(decoded.regions[0].coordinates[0])));
    try std.testing.expectEqual(@as(u64, 5), metrics.total_items);
    try std.testing.expectEqual(max_items - 5, reader.remaining_items);
    try std.testing.expectEqual(types.max_image_map_string_bytes - 1, reader.remaining_map_string_bytes);
    try std.testing.expectEqual(max_items - 5, encoded.remaining_items);
    encoded.out.clearRetainingCapacity();
    encoded.remaining_map_string_bytes = types.max_image_map_string_bytes;
    const repeated: types.ImageMap = .{ .default_action = .{ .kind = .internal, .target = "T", .label = "L" } };
    try encoded.imageMap(repeated); try encoded.imageMap(repeated);
    reader = .{ .a = a, .version = .image_maps, .bytes = encoded.out.items, .remaining_map_string_bytes = 3 };
    _ = try reader.imageMap(); const second = reader.pos;
    try std.testing.expectError(error.InvalidPresentation, reader.imageMap());
    try std.testing.expectEqual(second, reader.pos);
    try std.testing.expectEqual(@as(usize, 1), reader.remaining_map_string_bytes);
    reader = .{ .a = a, .version = .image_maps, .bytes = encoded.out.items, .remaining_items = 1 };
    _ = try reader.imageMap();
    try std.testing.expectError(error.InvalidPresentation, reader.imageMap());
    var small: Encoder = .{ .a = a, .version = .image_maps, .remaining_map_string_bytes = 3 }; defer small.deinit();
    try small.imageMap(repeated);
    try std.testing.expectError(error.PresentationTooLarge, small.imageMap(repeated));
    var items: Encoder = .{ .a = a, .version = .image_maps, .remaining_items = 4 }; defer items.deinit();
    try std.testing.expectError(error.PresentationTooLarge, items.imageMap(map));
}

test "DPRJ rejects malformed map data before allocating regions or coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const regions = [_]types.MapRegion{.{ .shape = .circle, .coordinates = &.{ 1, 2, -3 }, .action = .{ .kind = .internal, .target = "T", .target_fragment = "", .label = "L" } }};
    const map: types.ImageMap = .{ .regions = &regions };
    var encoded: Encoder = .{ .a = a, .version = .image_maps }; defer encoded.deinit();
    try encoded.imageMap(map);
    const good = try a.dupe(u8, encoded.out.items);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..good.len) |end| {
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = good[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.imageMap());
    }
    const byte_cases = [_]struct { offset: usize, value: u8 }{
        .{ .offset = 0, .value = 5 }, .{ .offset = 5, .value = 3 },
        .{ .offset = 34, .value = 2 }, .{ .offset = 34, .value = 1 },
        .{ .offset = 40, .value = 2 }, .{ .offset = good.len - 1, .value = 2 },
        .{ .offset = 49, .value = 0xff },
    };
    for (byte_cases) |change| {
        const bad = try a.dupe(u8, good); bad[change.offset] = change.value;
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.imageMap());
    }
    for ([_]struct { offset: usize, value: u32 }{
        .{ .offset = 1, .value = max_items + 1 }, .{ .offset = 1, .value = 2 },
        .{ .offset = 6, .value = 4 }, .{ .offset = 6, .value = max_items + 1 },
        .{ .offset = 35, .value = max_string_bytes + 1 },
    }) |change| {
        const bad = try a.dupe(u8, good); std.mem.writeInt(u32, bad[change.offset..][0..4], change.value, .little);
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.imageMap());
    }
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |number| {
        const bad = try a.dupe(u8, good); std.mem.writeInt(u64, bad[10..18], @bitCast(number), .little);
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.imageMap());
    }
    var valid: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = good };
    try std.testing.expectError(error.OutOfMemory, valid.imageMap());
    var exhausted: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = good, .remaining_items = 3 };
    try std.testing.expectError(error.InvalidPresentation, exhausted.imageMap());
    exhausted = .{ .a = failing.allocator(), .version = .image_maps, .bytes = good, .remaining_map_string_bytes = 1 };
    try std.testing.expectError(error.InvalidPresentation, exhausted.imageMap());
    encoded.out.clearRetainingCapacity(); try encoded.inlineImage(.{ .file = "Map.svg", .map = map });
    const image = try a.dupe(u8, encoded.out.items); const flags_at = 5 + "Map.svg".len;
    for ([_]u8{ 0x40, 0x80 }) |bit| {
        const bad = try a.dupe(u8, image); bad[flags_at] |= bit;
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    var old: Reader = .{ .a = failing.allocator(), .version = .block_geometry, .bytes = image };
    try std.testing.expectError(error.InvalidPresentation, old.inlineImage());
}

test "DPRJ allocation rollback retains complete maps alongside I H and large G catalogs" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit();
            const a = arena.allocator();
            const media = try a.alloc(types.Media, 280);
            for (media, 0..) |*item, index| item.* = .{ .kind = .image, .file = try std.fmt.allocPrint(a, "Map-{d}.svg", .{index}), .caption = "" };
            const regions = [_]types.MapRegion{.{ .shape = .polygon, .coordinates = &.{ -0.5, 1.25, 20, -4, 7.5, 16 }, .action = .{ .kind = .internal, .target = "Target", .target_fragment = "", .label = "label" } }};
            const spans = [_]types.Span{.{ .kind = .link, .target = "FilePage", .target_fragment = "", .tooltip = "outer", .font_scale = 0, .font_scale_basis = .normal_body,
                .image = .{ .file = media[279].file, .border = true, .alt = "alt", .tooltip = "", .map = .{ .regions = &regions, .default_action = .{ .kind = .external, .target = "https://example.invalid/", .label = "" } } } }};
            const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans, .text_align = .center, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } }};
            const stored: types.Stored = .{ .entry = .{ .title = "rollback", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .media = media } };
            const bytes = try encodeAlloc(a, stored);
            try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
            const decoded = try decodeAlloc(a, bytes, "rollback", .supplemental, null);
            try std.testing.expectEqualDeep(stored, decoded);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

const FigureCodecFixture = struct {
    fn make(span: types.Span) types.Figure {
        // Synthetic fixtures explicitly choose an admissible policy/format
        // without changing their existing occurrence bounds. This is not a
        // production source-policy inference or a Figure field default.
        const image = span.image.?;
        return .{ .content = .{ .image = .{ .span = span, .sizing = if (image.width_px != null) .requested_fit else if (image.height_px != null) .original_width_with_height_bound else .intrinsic } }, .format = if (image.width_px != null) .thumbnail else .framed,
             .placement = .float_right, .clear = .right,
            .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0.5 }), .image_insets = types.StyleEdges.all(.{ .unit = .px, .value = 3 }),
            .caption_padding = types.StyleEdges.all(.{ .unit = .px, .value = 2 }), .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
            .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none }, .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
            .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    }
};

test "revised J figure image and caption round trip recursive sinks and capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const regions = [_]types.MapRegion{.{ .shape = .rectangle, .coordinates = &.{ 1.5, -2, 30, 40 }, .action = .{ .kind = .internal, .target = "Region", .target_fragment = "", .label = "region" } }};
    const image: types.Span = .{ .kind = .link, .target = "File:Figure.svg", .target_fragment = "", .tooltip = "image advice", .explanation = "image expansion", .foreground = "#123456", .background = "#abcdef", .font_scale = 0, .font_scale_basis = .normal_body, .bold = true,
        .image = .{ .file = "Figure.svg", .width_px = 400, .border = true, .alt = "alt", .tooltip = "", .map = .{ .regions = &regions } } };
    var figure = FigureCodecFixture.make(image);
    figure.frame_border = .{ .kind = .solid, .width = .{ .unit = .px, .value = 1 }, .color = .{ .kind = .native_theme } };
    figure.image_background = .{ .kind = .transparent };
    figure.image_border = .{ .kind = .solid, .width = .{ .unit = .px, .value = 2 }, .color = .{ .kind = .rgb, .value = "#112233" } };
    figure.caption_foreground = .{ .kind = .rgb, .value = "#445566" };
    const caption = [_]types.Span{.{ .kind = .link, .text = "caption", .target = "CaptionTarget", .trail = "s", .tooltip = "caption advice", .italic = true, .foreground = "#778899" }};
    figure.caption = &caption;
    const paragraph = [_]types.Block{.{ .kind = .paragraph, .level = 4, .number = "retained", .spans = &.{}, .text_align = .center, .figure = figure }};
    const listed = [_]types.Block{.{ .kind = .list_item, .depth = 2, .list_path = "*#", .number = "2", .spans = &.{}, .text_align = .right, .figure = figure }};
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &listed }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    const cases = [_]types.Entry{
        .{ .title = "figure", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &paragraph }} },
        .{ .title = "figure", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "list", .blocks = &listed }} },
        .{ .title = "figure", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "figure", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "figure", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &paragraph }} },
        .{ .title = "figure", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{.{ .kind = .table, .table = nested }} }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry }; stored.entry.media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "summary" }};
        try std.testing.expect(hasFigures(entry.sections, entry.references));
        try std.testing.expect(hasInlineImages(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasImageMaps(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasTooltips(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasExplicitTargets(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasFontScale(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasBodyFontScale(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasExplanation(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasColor(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasSpanBackground(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "figure", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const reparsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        try std.testing.expectEqualDeep(stored, reparsed.value);
        stored.entry.media = &.{};
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "figure", .supplemental, null));
    }
}

test "generic build figure keeps compiler span flags without a Stored cast" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Flags = packed struct(u8) { bold: bool = false, italic: bool = false, code: bool = false, small: bool = false, superscript: bool = false, subscript: bool = false, strike: bool = false, underline: bool = false };
    const BuildSpan = struct {
        kind: types.InlineKind = .link, role: types.Role = .normal, text: []const u8 = "", target: []const u8 = "File:Figure.svg",
        language: []const u8 = "en", classes: []const u8 = "image", direction: []const u8 = "ltr", explanation: []const u8 = "",
        target_fragment: ?[]const u8 = "", tooltip: ?[]const u8 = "advice", image: ?types.InlineImage = .{ .file = "Figure.svg", .width_px = 400 },
        flags: Flags = .{ .bold = true, .italic = true, .small = true, .superscript = true, .strike = true, .underline = true }, provenance: u8 = 77,
    };
    const base = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    const build = .{ .content = types.FigureContentFor(BuildSpan){ .image = .{ .span = BuildSpan{}, .sizing = base.content.image.sizing } }, .format = base.format,  .frame_min_width = @as(?types.StyleLength, .{ .unit = .px, .value = 100 }), .placement = base.placement, .clear = base.clear,
        .margins = base.margins, .image_insets = base.image_insets, .caption_padding = base.caption_padding, .caption_font_scale = base.caption_font_scale, .caption_line_height = base.caption_line_height,
        .frame_background = base.frame_background, .frame_border = base.frame_border, .image_background = base.image_background, .image_border = base.image_border,
        .caption_foreground = base.caption_foreground, .caption_background = base.caption_background };
    try std.testing.expect(types.validFigureGeometry(build));
    const block = .{ .kind = types.BlockKind.paragraph, .depth = @as(u8, 0), .level = @as(u8, 0), .spans = @as([]const BuildSpan, &.{}), .feature = @as(?types.Feature, null), .table = @as(?types.Table, null),
        .list_path = @as([]const u8, ""), .number = @as([]const u8, ""), .figure = @as(?@TypeOf(build), build) };
    const blocks = [_]@TypeOf(block){block};
    const section = .{ .level = @as(u8, 2), .title = @as([]const u8, "body"), .blocks = &blocks };
    const sections = [_]@TypeOf(section){section};
    const media = [_]types.Media{.{ .file = "Figure.svg", .kind = .image, .caption = "" }};
    const bytes = try encodeBuildAlloc(a, @as([]const BuildSpan, &.{}), &sections, types.Layout{}, @as([]const types.Reference, &.{}), &media);
    const decoded = try decodeAlloc(a, bytes, "build", .supplemental, null);
    try std.testing.expectEqual(@as(f32, 100), decoded.entry.sections[0].blocks[0].figure.?.frame_min_width.?.value);
    const span = decoded.entry.sections[0].blocks[0].figure.?.content.image.span;
    try std.testing.expect(span.bold and span.italic and span.small and span.superscript and span.strike and span.underline);
    try std.testing.expectEqualStrings("advice", span.tooltip.?);
    try std.testing.expectEqualStrings("", span.target_fragment.?);
    try std.testing.expectEqual(@as(u8, 77), build.content.image.span.provenance);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
}

test "figure contexts are enforced on encode decode and Stored validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    const invalid = [_]types.Block{ .{ .kind = .heading }, .{ .kind = .preformatted }, .{ .kind = .table }, .{ .kind = .paragraph, .depth = 1 }, .{ .kind = .paragraph, .list_path = "*" },
        .{ .kind = .paragraph, .table = .{ .rows = &.{} } }, .{ .kind = .paragraph, .feature = .{ .kind = "audio" } }, .{ .kind = .paragraph, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } } };
    for (invalid) |old| {
        var bad = old; bad.figure = figure;
        const blocks = [_]types.Block{bad}; const stored: types.Stored = .{ .entry = .{ .title = "bad", .kind = .supplemental,
            .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "bad", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
        var raw: Encoder = .{ .a = a, .version = .block_geometry }; defer raw.deinit();
        try raw.block(old); raw.version = .image_maps; try raw.figure(@as(?types.Figure, figure)); try raw.byte(0);
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    var old: Encoder = .{ .a = a, .version = .block_geometry }; defer old.deinit();
    try std.testing.expectError(error.InvalidPresentation, old.block(types.Block{ .kind = .paragraph, .figure = figure }));
}

test "figure paint geometry framing and image item budgets reject malformed data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    var encoded: Encoder = .{ .a = a, .version = .image_maps }; defer encoded.deinit();
    try encoded.figure(@as(?types.Figure, figure)); const good = try a.dupe(u8, encoded.out.items);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..good.len) |end| {
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = good[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    for ([_]struct { offset: usize, value: u8 }{ .{ .offset = 0, .value = 2 }, .{ .offset = 1, .value = 2 }, .{ .offset = 2, .value = 4 }, .{ .offset = 3, .value = 4 },
        .{ .offset = 4, .value = 2 }, .{ .offset = 68, .value = 2 }, .{ .offset = 73, .value = 3 }, .{ .offset = 74, .value = 2 } }) |change| {
        const bad = try a.dupe(u8, good); bad[change.offset] = change.value;
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    for ([_]usize{ 5, 64, 69 }) |offset| for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |value| {
        const bad = try a.dupe(u8, good); std.mem.writeInt(u32, bad[offset..][0..4], @bitCast(value), .little);
        var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.figure());
    };
    var reader: Reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = good, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, reader.figure());
    var exhausted: Encoder = .{ .a = a, .version = .image_maps, .remaining_items = 0 }; defer exhausted.deinit();
    try std.testing.expectError(error.PresentationTooLarge, exhausted.figure(@as(?types.Figure, figure)));
    encoded.out.clearRetainingCapacity(); try encoded.block(types.Block{ .kind = .paragraph });
    try std.testing.expectEqual(@as(usize, 29), encoded.out.items.len);
    encoded.out.clearRetainingCapacity(); try encoded.blocks(&[_]types.Block{.{ .kind = .paragraph }});
    std.mem.writeInt(u32, encoded.out.items[0..4], 2, .little);
    reader = .{ .a = failing.allocator(), .version = .image_maps, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.blocks());
}

test "figure manual image count and map counters are charged once and rollback allocations" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit(); const a = arena.allocator();
            const media = try a.alloc(types.Media, 280);
            for (media, 0..) |*value, n| value.* = .{ .file = try std.fmt.allocPrint(a, "Figure-{d}.svg", .{n}), .kind = .image, .caption = "" };
            const regions = [_]types.MapRegion{.{ .shape = .circle, .coordinates = &.{ -0.0, 2, -3 }, .action = .{ .kind = .internal, .target = "T", .label = "L" } }};
            const figure = FigureCodecFixture.make(.{ .image = .{ .file = media[279].file, .border = true, .map = .{ .regions = &regions, .default_action = .{ .kind = .internal, .target = "", .target_fragment = "", .label = "" } } } });
            var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit();
            try raw.figure(@as(?types.Figure, figure));
            var metrics: DecodeMetrics = .{};
            var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .metrics = &metrics };
            try std.testing.expectEqualDeep(figure, (try reader.figure()).?);
            try std.testing.expectEqual(@as(u64, 6), metrics.total_items);
            try std.testing.expectEqual(max_items - 6, reader.remaining_items);
            try std.testing.expectEqual(types.max_image_map_string_bytes - 2, reader.remaining_map_string_bytes);
            const stored: types.Stored = .{ .entry = .{ .title = "rollback", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }}, .media = media } };
            const bytes = try encodeAlloc(a, stored);
            const decoded = try decodeAlloc(a, bytes, "rollback", .supplemental, null);
            try std.testing.expectEqualDeep(stored, decoded);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "anonymous mixed flow and authoritative captions preserve source order all recursive sinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const caption = [_]types.Block{.{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{.{ .kind = .link, .text = "caption", .target = "Caption", .target_fragment = "part", .tooltip = "caption advice", .background = "#112233" }} }};
    var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .border = true } }); figure.caption_blocks = &caption; figure.caption_text_align = .left;
    var second_figure = figure; second_figure.caption_text_align = .right;
    const parts = [_]types.FlowPart{ .{ .kind = .@"inline", .spans = &.{.{ .text = "before " }} }, .{ .kind = .figure, .figure = figure },
        .{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = " after", .target = "After", .trail = "s", .font_scale = 0.8, .font_scale_basis = .normal_body }} }, .{ .kind = .figure, .figure = second_figure } };
    const flow = [_]types.Block{.{ .kind = .list_item, .depth = 2, .list_path = "*#", .number = "2", .flow = &parts, .text_align = .center }};
    const table: types.Table = .{ .caption_blocks = &flow, .rows = &.{.{ .cells = &.{.{ .blocks = &flow }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    const cases = [_]types.Entry{
        .{ .title = "mixed", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &flow }} },
        .{ .title = "mixed", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "caption", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "mixed", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "mixed", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &flow }} },
        .{ .title = "mixed", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{.{ .kind = .table, .table = nested }} }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry }; stored.entry.media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }};
        try std.testing.expect(hasRichContent(entry.sections, entry.references));
        try std.testing.expect(hasInlineImages(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasTooltips(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasExplicitTargets(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasBodyFontScale(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasSpanBackground(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try types.validateStored(a, stored, "mixed", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "mixed", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, stored, .{}); const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); try std.testing.expectEqualDeep(stored, parsed.value);
        stored.entry.media = &.{}; try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    }
    // Style belongs to the containing anonymous flow exactly once; fragments carry no fabricated paragraph style.
    const styled: types.Block = .{ .kind = .paragraph, .flow = &parts, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } };
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.block(styled);
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items }; try std.testing.expectEqualDeep(styled, try reader.block());
}

test "flow discriminants authority framing and shared item counters are strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    const invalid = [_]types.FlowPart{ .{ .kind = .figure }, .{ .kind = .@"inline", .figure = figure }, .{ .kind = .figure, .figure = figure, .spans = &.{.{ .text = "dup" }} } };
    for (invalid) |part| { var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try std.testing.expectError(error.InvalidPresentation, raw.flow(@as(?[]const types.FlowPart, &.{part}))); }
    for ([_][]const u8{ &.{2}, &.{ 1, 1, 0, 0, 0, 2, 0, 0, 0, 0 }, &.{ 1, 1, 0, 0, 0, 1, 0, 0, 0, 0 }, &.{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 } }) |bytes| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var reader: Reader = .{ .a = if (bytes.len == 1 or bytes[1] == 2) failing.allocator() else a, .version = .image_maps, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.flow());
    }
    const parts = [_]types.FlowPart{ .{ .kind = .@"inline", .spans = &.{.{ .text = " " }} }, .{ .kind = .figure, .figure = figure } };
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.flow(@as(?[]const types.FlowPart, &parts));
    var metrics: DecodeMetrics = .{}; var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .metrics = &metrics };
    try std.testing.expectEqualDeep(@as(?[]const types.FlowPart, &parts), try reader.flow());
    try std.testing.expectEqual(@as(u64, 4), metrics.total_items); // two parts + one inline span + one figure image
    try std.testing.expectEqual(max_items - 4, reader.remaining_items);
    reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .remaining_items = 1 }; try std.testing.expectError(error.InvalidPresentation, reader.flow());
    for ([_]types.Block{ .{ .kind = .heading, .flow = &parts }, .{ .kind = .paragraph, .flow = &parts, .spans = &.{.{ .text = "dup" }} },
        .{ .kind = .paragraph, .flow = &parts, .figure = figure }, .{ .kind = .paragraph, .flow = &parts, .table = .{} }, .{ .kind = .paragraph, .flow = &parts, .feature = .{ .kind = "audio" } },
        .{ .kind = .paragraph, .figure = figure, .spans = &.{.{ .text = "old caption location" }} } }) |bad| {
        raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try std.testing.expectError(error.InvalidPresentation, raw.block(bad));
        const stored: types.Stored = .{ .entry = .{ .title = "bad", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{bad} }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, stored, "bad", .supplemental, null));
    }
    var no_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var authority: Reader = .{ .a = no_alloc.allocator(), .version = .image_maps, .bytes = &.{ 1, 1, 0, 0, 0 } };
    try std.testing.expectError(error.InvalidPresentation, authority.captionBlocks(1));
    authority = .{ .a = no_alloc.allocator(), .version = .image_maps, .bytes = &.{ 1, 1, 0, 0, 0 }, .content_depth = types.max_content_depth };
    try std.testing.expectError(error.InvalidPresentation, authority.captionBlocks(0));
    raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try raw.flow(@as(?[]const types.FlowPart, &parts));
    for (0..raw.out.items.len) |end| {
        var truncated: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, truncated.flow());
    }
    var duplicate = figure; duplicate.caption = &.{.{ .text = "dup" }}; duplicate.caption_blocks = &.{};
    raw.out.clearRetainingCapacity(); try std.testing.expectError(error.InvalidPresentation, raw.figure(@as(?types.Figure, duplicate)));
    const table: types.Table = .{ .caption = &.{.{ .text = "dup" }}, .caption_blocks = &.{} };
    raw.out.clearRetainingCapacity(); try std.testing.expectError(error.InvalidPresentation, raw.table(@as(?types.Table, table)));
    raw.out.clearRetainingCapacity(); try raw.block(types.Block{ .kind = .paragraph }); try std.testing.expectEqual(@as(usize, 29), raw.out.items.len);
}

test "new content depth survives table cell reference transitions and boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var blocks: []const types.Block = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "leaf" }} }};
    for (0..types.max_content_depth) |_| {
        var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } }); figure.caption_blocks = blocks;
        const outer = try a.alloc(types.Block, 1); outer[0] = .{ .kind = .paragraph, .figure = figure }; blocks = outer;
    }
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = blocks }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
    try types.validateStored(a, stored, "depth", .supplemental, null);
    const bytes = try encodeAlloc(a, stored); const decoded = try decodeAlloc(a, bytes, "depth", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
    var outer_figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } }); outer_figure.caption_blocks = blocks;
    const outer = [_]types.Block{.{ .kind = .paragraph, .figure = outer_figure }};
    var too_deep = stored; too_deep.entry.references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &outer }};
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, too_deep, "depth", .supplemental, null));
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, too_deep));
    var depth_raw: Encoder = .{ .a = a, .version = .image_maps }; defer depth_raw.deinit(); try depth_raw.blocks(blocks);
    var depth_reader: Reader = .{ .a = a, .version = .image_maps, .bytes = depth_raw.out.items, .content_depth = 1 };
    try std.testing.expectError(error.InvalidPresentation, depth_reader.blocks());
    // Reader does not reset content depth when entering an existing table/cell path.
    const leaf = [_]types.Block{.{ .kind = .paragraph, .flow = &.{} }};
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &leaf }} }} };
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.table(@as(?types.Table, table));
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .content_depth = types.max_content_depth };
    try std.testing.expectError(error.InvalidPresentation, reader.table());
    raw.out.clearRetainingCapacity(); raw.content_depth = types.max_content_depth; try std.testing.expectError(error.InvalidPresentation, raw.table(@as(?types.Table, table)));
}

test "null new content retains old byte selection and OOM rollback" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit(); const a = arena.allocator();
            const empty = [_]types.Block{.{ .kind = .paragraph, .flow = &.{} }};
            const stored: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &empty }} } };
            const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
            const decoded = try decodeAlloc(a, bytes, "empty", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
            var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
            figure.caption_blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = "caption", .target = "Target", .tooltip = "advice" }} }} }};
            const rich: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "rich", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .figure, .figure = figure }} }} }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
            const rbytes = try encodeAlloc(a, rich); const rround = try decodeAlloc(a, rbytes, "empty", .supplemental, null); try std.testing.expectEqualDeep(rich, rround);
            try std.testing.expectEqualSlices(u8, rbytes, try encodeAlloc(a, rround));
            const ordinary: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "ordinary" }} }} }} } };
            const old = try encodeAlloc(a, ordinary); try std.testing.expectEqualStrings(magic, old[0..4]);
            const round = try decodeAlloc(a, old, "empty", .supplemental, null); try std.testing.expectEqualDeep(ordinary, round);
            const styled: types.Stored = .{ .entry = .{ .title = "empty", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } }} }} } };
            const ibytes = try encodeAlloc(a, styled); try std.testing.expectEqualStrings(block_geometry_magic, ibytes[0..4]);
            const iround = try decodeAlloc(a, ibytes, "empty", .supplemental, null); try std.testing.expectEqualDeep(styled, iround);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "table diagnostics include direct rich captions and flow figure captions exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const two: types.Table = .{ .rows = &.{.{ .cells = &.{ .{}, .{} } }} };
    const three: types.Table = .{ .rows = &.{.{ .cells = &.{ .{}, .{}, .{} } }} };
    const four: types.Table = .{ .rows = &.{.{ .cells = &.{ .{}, .{}, .{}, .{} } }} };
    var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    figure.caption_blocks = &.{.{ .kind = .table, .table = three }};
    const root: types.Table = .{ .caption_blocks = &.{ .{ .kind = .table, .table = two },
        .{ .kind = .paragraph, .flow = &.{ .{ .kind = .@"inline", .spans = &.{.{ .text = "before" }} }, .{ .kind = .figure, .figure = figure } } } },
        .rows = &.{.{ .cells = &.{.{ .nested_table = four }} }} };
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.table(@as(?types.Table, root));
    var actual: DecodeMetrics = .{}; var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .metrics = &actual };
    try std.testing.expectEqualDeep(root, (try reader.table()).?);
    try std.testing.expectEqual(@as(usize, 4), actual.tables);
    try std.testing.expectEqual(@as(?usize, 3), actual.widest_table);
    try std.testing.expectEqual(@as(?usize, 0), actual.tallest_table);
    try std.testing.expectEqual(@as(?usize, 4), actual.table_columns_exact);
    try std.testing.expectEqual(@as(usize, 4), actual.table_columns_lower_bound);
    var expected: DecodeMetrics = .{}; expected.table(root); expected.table(two); expected.table(three); expected.table(four);
    expected.total_items = actual.total_items; expected.largest_string_bytes = actual.largest_string_bytes;
    try std.testing.expectEqualDeep(expected, actual);
    // Without an outer table, caption tables are their own depth-one metric roots.
    raw.out.clearRetainingCapacity(); raw.remaining_items = max_items;
    try raw.block(types.Block{ .kind = .paragraph, .figure = figure });
    actual = .{}; reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .metrics = &actual };
    _ = try reader.block(); try std.testing.expectEqual(@as(usize, 1), actual.tables);
    try std.testing.expectEqual(@as(?usize, 0), actual.widest_table);
    try std.testing.expectEqual(@as(usize, 3), actual.table_columns_lower_bound);
}

test "Figure native JSON preserves promoted binary f32 caption scale exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]f32{ 0.884, 0.8, 1.2376, 1 }) |scale| {
        var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } }); figure.caption_font_scale = scale;
        figure.frame_border = .{ .kind = .solid, .width = .{ .unit = .px, .value = scale }, .color = .{ .kind = .native_theme } };
        const stored: types.Stored = .{ .entry = .{ .title = "numeric", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        const bytes = try encodeAlloc(a, stored); const decoded = try decodeAlloc(a, bytes, "numeric", .supplemental, null);
        const binary_figure = decoded.entry.sections[0].blocks[0].figure.?;
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const dynamic = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        const json_figure = dynamic.value.object.get("entry").?.object.get("sections").?.array.items[0].object.get("blocks").?.array.items[0].object.get("figure").?;
        const numeric = switch (json_figure.object.get("caption_font_scale").?) { .float => |number| number, .integer => |number| @as(f64, @floatFromInt(number)), else => return error.UnexpectedJsonNumber };
        try std.testing.expectEqual(@as(f64, binary_figure.caption_font_scale), numeric);
        // Existing StyleLength widening covers every other new Figure float:
        // edges, caption line height, and both border widths use that writer.
        const border_numeric = switch (json_figure.object.get("frame_border").?.object.get("width").?.object.get("value").?) { .float => |number| number, .integer => |number| @as(f64, @floatFromInt(number)), else => return error.UnexpectedJsonNumber };
        try std.testing.expectEqual(@as(f64, binary_figure.frame_border.width.?.value), border_numeric);
        if (scale == @as(f32, 0.884)) try std.testing.expect(numeric != @as(f64, 0.884));
        const reparsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        try std.testing.expectEqualDeep(decoded, reparsed.value);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, reparsed.value));
    }
}

test "existing seven typed list roles own figures and anonymous flow without coercion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const cases = [_]struct { kind: types.BlockKind, path: []const u8, depth: u8, number: []const u8 }{
        .{ .kind = .list_item, .path = "*#", .depth = 2, .number = "17" },
        .{ .kind = .definition, .path = "##", .depth = 2, .number = "23" },
        .{ .kind = .example, .path = "#:", .depth = 2, .number = "" },
        .{ .kind = .quotation, .path = "#*", .depth = 2, .number = "" },
        .{ .kind = .term, .path = ";", .depth = 1, .number = "" },
        .{ .kind = .list_detail, .path = "*#:", .depth = 3, .number = "" },
        .{ .kind = .indent, .path = "::", .depth = 2, .number = "" },
    };
    var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } }); figure.caption = &.{.{ .text = "caption" }};
    for (cases) |row| {
        try std.testing.expect(types.validFigureContext(row.kind, row.depth, false, false, false, row.path));
        try std.testing.expect(types.validFlowContext(row.kind, row.depth, false, false, false, row.path));
        const blocks = [_]types.Block{
            .{ .kind = row.kind, .depth = row.depth, .list_path = row.path, .number = row.number, .figure = figure },
            .{ .kind = row.kind, .depth = row.depth, .list_path = row.path, .number = row.number, .flow = &.{
                .{ .kind = .@"inline", .spans = &.{.{ .text = "before " }} }, .{ .kind = .figure, .figure = figure }, .{ .kind = .@"inline", .spans = &.{.{ .text = " after" }} } } },
        };
        const stored: types.Stored = .{ .entry = .{ .title = "roles", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try types.validateStored(a, stored, "roles", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); const decoded = try decodeAlloc(a, bytes, "roles", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        for (decoded.entry.sections[0].blocks) |block| {
            try std.testing.expectEqual(row.kind, block.kind); try std.testing.expectEqual(row.depth, block.depth);
            try std.testing.expectEqualStrings(row.path, block.list_path); try std.testing.expectEqualStrings(row.number, block.number);
        }
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        // Existing exclusions remain independent of the expanded owner-role set.
        try std.testing.expect(!types.validFigureContext(row.kind, row.depth, true, false, false, row.path));
        try std.testing.expect(!types.validFigureContext(row.kind, row.depth, false, true, false, row.path));
        try std.testing.expect(!types.validFigureContext(row.kind, row.depth, false, false, true, row.path));
        try std.testing.expect(!types.validFlowContext(row.kind, row.depth, true, false, false, row.path));
        try std.testing.expect(!types.validFlowContext(row.kind, row.depth, false, true, false, row.path));
        try std.testing.expect(!types.validFlowContext(row.kind, row.depth, false, false, true, row.path));
    }
    for ([_]types.BlockKind{ .blank, .heading, .preformatted, .rule, .table }) |kind| {
        try std.testing.expect(!types.validFigureContext(kind, 0, false, false, false, ""));
        try std.testing.expect(!types.validFlowContext(kind, 0, false, false, false, ""));
    }
    try std.testing.expect(types.validFigureContext(.paragraph, 0, false, false, false, ""));
    try std.testing.expect(!types.validFigureContext(.paragraph, 1, false, false, false, ""));
    try std.testing.expect(!types.validFigureContext(.paragraph, 0, false, false, false, "*"));
    try std.testing.expect(!types.validFlowContext(.paragraph, 1, false, false, false, ""));
    try std.testing.expect(!types.validFlowContext(.paragraph, 0, false, false, false, "*"));
    // Preserve old list-item admission: this repair adds no invented path,
    // number, terminal-marker or depth-equality validator to compiled metadata.
    try std.testing.expect(types.validFigureContext(.list_item, 0, false, false, false, ""));
    try std.testing.expect(types.validFlowContext(.list_item, 0, false, false, false, ""));
}

test "nested bidi scope metadata and all existing content survive recursive owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const action: types.MapAction = .{ .kind = .internal, .target = "Mapped", .target_fragment = "", .label = "region" };
    const regions = [_]types.MapRegion{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 10.5, 20 }, .action = action }};
    const caption_table: types.Table = .{ .rows = &.{.{ .cells = &.{ .{}, .{} } }} };
    var figure = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Figure.svg", .tooltip = "image advice", .image = .{ .file = "Figure.svg", .map = .{ .regions = &regions } } });
    figure.caption_text_align = .right; figure.caption_blocks = &.{.{ .kind = .table, .table = caption_table }};
    const child: types.BidiScope = .{ .mode = .isolate_override, .authored_direction = .rtl, .resolved_direction = .rtl, .language = "",
        .parts = &.{ .{ .kind = .figure, .figure = figure }, .{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = "אב", .target = "Target", .target_fragment = "", .tooltip = "", .font_scale = 0.8, .font_scale_basis = .normal_body, .background = "#123456" }} } } };
    const parent: types.BidiScope = .{ .mode = .isolate, .authored_direction = .auto, .resolved_direction = .ltr, .language = null,
        .parts = &.{ .{ .kind = .@"inline", .spans = &.{.{ .text = "Latin " }} }, .{ .kind = .scope, .scope = child }, .{ .kind = .@"inline", .spans = &.{.{ .text = " after\xe2\x81\xa7authored\xe2\x81\xa9" }} } } };
    const blocks = [_]types.Block{.{ .kind = .definition, .depth = 1, .list_path = "#", .number = "17", .flow = &.{.{ .kind = .scope, .scope = parent }} }};
    const table: types.Table = .{ .caption_blocks = &blocks, .rows = &.{.{ .cells = &.{.{ .blocks = &blocks }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    const cases = [_]types.Entry{
        .{ .title = "scope", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }} },
        .{ .title = "scope", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "scope", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "scope", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &blocks }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry }; stored.entry.media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }};
        try std.testing.expect(hasRichContent(entry.sections, entry.references));
        try std.testing.expect(hasInlineImages(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasImageMaps(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasTooltips(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasExplicitTargets(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasBodyFontScale(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try std.testing.expect(hasSpanBackground(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try types.validateStored(a, stored, "scope", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); const decoded = try decodeAlloc(a, bytes, "scope", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{}); const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); try std.testing.expectEqualDeep(decoded, parsed.value);
        stored.entry.media = &.{}; try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    }
    // A table in a nested scope's Figure caption is included by the existing
    // root-table diagnostic owner exactly once (both caption and cell copies).
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.table(@as(?types.Table, table));
    var metrics: DecodeMetrics = .{}; var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .metrics = &metrics };
    _ = try reader.table(); try std.testing.expectEqual(@as(usize, 3), metrics.tables);
    try std.testing.expectEqual(@as(usize, 2), metrics.table_columns_lower_bound);
}

test "bidi scope framing enums nullable metadata and counts are strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const empty: types.BidiScope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{} };
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.bidiScope(empty);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, raw.out.items);
    var no_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (0..raw.out.items.len) |end| {
        var reader: Reader = .{ .a = no_alloc.allocator(), .version = .image_maps, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.bidiScope());
    }
    for ([_]struct { offset: usize, value: u8 }{ .{ .offset = 0, .value = 2 }, .{ .offset = 1, .value = 4 }, .{ .offset = 2, .value = 2 }, .{ .offset = 3, .value = 2 },
        .{ .offset = 0, .value = 1 }, .{ .offset = 1, .value = 2 } }) |change| {
        const bytes = try a.dupe(u8, raw.out.items); bytes[change.offset] = change.value;
        var reader: Reader = .{ .a = no_alloc.allocator(), .version = .image_maps, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.bidiScope());
    }
    for ([_][]const u8{ &.{ 1, 3, 0, 0, 0, 0, 0, 0 }, &.{ 0, 0, 0, 1, 1, 0, 0, 0, 255, 0, 0, 0, 0 }, &.{ 0, 0, 0, 0, 1, 0, 0, 0 }, &.{ 0, 0, 0, 0, 255, 255, 255, 255 } }) |bytes| {
        var reader: Reader = .{ .a = no_alloc.allocator(), .version = .image_maps, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.bidiScope());
    }
    // Scope tag2 has a direct body, not an additional optional presence byte.
    raw.out.clearRetainingCapacity(); try raw.flowParts(&[_]types.FlowPart{.{ .kind = .scope, .scope = empty }});
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0 }, raw.out.items);
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, reader.flowParts());
    reader = .{ .a = a, .version = .image_maps, .bytes = &.{ 1, 0, 0, 0, 3, 0, 0, 0, 0 } }; try std.testing.expectError(error.InvalidPresentation, reader.flowParts());
    for ([_]?[]const u8{ null, "", "he" }) |language| for ([_]?types.BidiDirectionInput{ null, .auto, .ltr, .rtl }) |authored| {
        var value = empty; value.language = language; value.authored_direction = authored; value.resolved_direction = if (authored == .rtl) .rtl else .ltr;
        raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try raw.bidiScope(value);
        reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items }; try std.testing.expectEqualDeep(value, try reader.bidiScope());
    };
    const figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    for ([_]types.FlowPart{ .{ .kind = .scope }, .{ .kind = .scope, .scope = empty, .figure = figure }, .{ .kind = .scope, .scope = empty, .spans = &.{.{ .text = "duplicate" }} },
        .{ .kind = .@"inline", .scope = empty }, .{ .kind = .figure, .figure = figure, .scope = empty } }) |part| {
        raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try std.testing.expectError(error.InvalidPresentation, raw.flowParts(&[_]types.FlowPart{part}));
        try std.testing.expect(!types.validFlowPart(part));
    }
}

test "scope depth item accounting old variants and allocation rollback stay bounded" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit(); const a = arena.allocator();
            var parts: []const types.FlowPart = &.{.{ .kind = .@"inline", .spans = &.{.{ .text = "leaf" }} }};
            // Block.flow consumes one edge, leaving fifteen scope-container edges.
            for (0..types.max_content_depth - 1) |_| {
                const outer = try a.alloc(types.FlowPart, 1); outer[0] = .{ .kind = .scope, .scope = .{ .mode = .isolate, .authored_direction = .auto, .resolved_direction = .rtl, .language = "", .parts = parts } }; parts = outer;
            }
            const blocks = [_]types.Block{.{ .kind = .paragraph, .flow = parts }};
            const stored: types.Stored = .{ .entry = .{ .title = "scope", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }} } };
            try types.validateStored(a, stored, "scope", .supplemental, null);
            const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
            const decoded = try decodeAlloc(a, bytes, "scope", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
            const outer = [_]types.FlowPart{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = parts } }};
            var too_deep = stored; too_deep.entry.sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .flow = &outer }} }};
            try std.testing.expectError(error.InvalidPresentation, types.validateStored(a, too_deep, "scope", .supplemental, null));
            try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, too_deep));
            var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.flow(@as(?[]const types.FlowPart, parts));
            var metrics: DecodeMetrics = .{}; var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .metrics = &metrics };
            _ = try reader.flow(); try std.testing.expectEqual(@as(u64, types.max_content_depth + 1), metrics.total_items); // 15 scopes + inline part + span
            reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items, .content_depth = 1 }; try std.testing.expectError(error.InvalidPresentation, reader.flow());
            // A legacy inline variant retains its exact bytes; old typed records
            // without new content still choose their established H/I markers.
            raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try raw.flowParts(&[_]types.FlowPart{.{ .kind = .@"inline" }});
            try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0 }, raw.out.items);
            const old: types.Stored = .{ .entry = .{ .title = "scope", .kind = .supplemental } };
            const oldbytes = try encodeAlloc(a, old); try std.testing.expectEqualStrings(magic, oldbytes[0..4]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "generic bidi scope preserves compiler span flags and provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const Flags = packed struct(u8) { bold: bool = true, italic: bool = true, code: bool = false, small: bool = true, superscript: bool = false, subscript: bool = false, strike: bool = false, underline: bool = true };
    const BuildSpan = struct { kind: types.InlineKind = .text, role: types.Role = .normal, text: []const u8 = "compiled", target: []const u8 = "", language: []const u8 = "he", classes: []const u8 = "", direction: []const u8 = "", explanation: []const u8 = "", flags: Flags = .{}, provenance: u8 = 77 };
    const spans = [_]BuildSpan{.{}};
    const child = .{ .kind = types.FlowPartKind.@"inline", .spans = @as([]const BuildSpan, &spans), .figure = @as(?types.Figure, null), .scope = @as(?types.BidiScope, null) };
    const children = [_]@TypeOf(child){child};
    const scope = .{ .mode = types.BidiMode.isolate, .authored_direction = @as(?types.BidiDirectionInput, .auto), .resolved_direction = types.BidiResolvedDirection.rtl, .language = @as(?[]const u8, ""), .parts = &children };
    try std.testing.expect(types.validBidiScopeHeader(scope));
    const parent = .{ .kind = types.FlowPartKind.scope, .spans = @as([]const BuildSpan, &.{}), .figure = @as(?types.Figure, null), .scope = @as(?@TypeOf(scope), scope) };
    const parents = [_]@TypeOf(parent){parent};
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.flowParts(&parents);
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items };
    const decoded = try reader.flowParts(); const result = decoded[0].scope.?;
    try std.testing.expectEqual(types.BidiResolvedDirection.rtl, result.resolved_direction);
    try std.testing.expectEqualStrings("", result.language.?);
    const span = result.parts[0].spans[0]; try std.testing.expect(span.bold and span.italic and span.small and span.underline);
    try std.testing.expectEqualStrings("compiled", span.text); try std.testing.expectEqual(@as(u8, 77), spans[0].provenance);
    var reencoded: Encoder = .{ .a = a, .version = .image_maps }; defer reencoded.deinit(); try reencoded.flowParts(decoded);
    try std.testing.expectEqualSlices(u8, raw.out.items, reencoded.out.items);
}

test "all four required sizing policies preserve occurrence axes across every rich owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const cases = [_]struct { format: types.FigureFormat, policy: types.FigureSizingPolicy, width: ?u32, height: ?u32 }{
        .{ .format = .framed, .policy = .intrinsic, .width = 400, .height = 100 },
        .{ .format = .framed, .policy = .intrinsic, .width = null, .height = null },
        .{ .format = .framed, .policy = .original_width_with_height_bound, .width = null, .height = 100 },
        .{ .format = .thumbnail, .policy = .requested_fit, .width = 400, .height = null },
        .{ .format = .thumbnail, .policy = .requested_fit_cap_original_width, .width = 400, .height = 100 },
    };
    for (cases) |row| {
        var inner = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 256 } }); inner.content.image.sizing = .requested_fit_cap_original_width; inner.caption = &.{.{ .text = "inner caption" }};
        const inner_blocks = [_]types.Block{.{ .kind = .paragraph, .figure = inner }};
        const caption_table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &inner_blocks }} }} };
        const regions = [_]types.MapRegion{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 50, 40 }, .action = .{ .kind = .internal, .target = "Mapped", .target_fragment = "", .label = "region" } }};
        var figure = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Figure.svg", .tooltip = "image advice", .image = .{ .file = "Figure.svg", .width_px = row.width, .height_px = row.height, .map = .{ .regions = &regions } } });
        figure.format = row.format; figure.content.image.sizing = row.policy; figure.caption_text_align = .right; figure.caption_blocks = &.{.{ .kind = .table, .table = caption_table }};
        const scope: types.BidiScope = .{ .mode = .isolate, .authored_direction = .auto, .resolved_direction = .rtl, .language = "", .parts = &.{ .{ .kind = .@"inline", .spans = &.{.{ .text = "before " }} }, .{ .kind = .figure, .figure = figure }, .{ .kind = .@"inline", .spans = &.{.{ .text = " after" }} } } };
        const owners = [_]types.Block{ .{ .kind = .paragraph, .figure = figure }, .{ .kind = .list_detail, .depth = 2, .list_path = "*:", .flow = &.{.{ .kind = .scope, .scope = scope }} } };
        const table: types.Table = .{ .caption_blocks = &owners, .rows = &.{.{ .cells = &.{.{ .blocks = &owners }} }} };
        const stored: types.Stored = .{ .entry = .{ .title = "sizing", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{ .{ .kind = .paragraph, .figure = figure }, .{ .kind = .table, .table = table } } }},
            .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &owners }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try types.validateStored(a, stored, "sizing", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "sizing", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        const actual = decoded.entry.sections[0].blocks[0].figure.?; try std.testing.expectEqual(row.policy, actual.content.image.sizing);
        try std.testing.expectEqual(row.width, actual.content.image.span.image.?.width_px); try std.testing.expectEqual(row.height, actual.content.image.span.image.?.height_px);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const needle = try std.fmt.allocPrint(a, "\"sizing\":\"{s}\"", .{@tagName(row.policy)}); try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
        var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.figure(@as(?types.Figure, figure));
        try std.testing.expectEqual(@as(u8, @intFromEnum(row.policy)), raw.out.items[raw.out.items.len - 2]);
    }
}

test "required sizing byte rejects bad tags missing bytes and contradictory bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var good = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 0x0f123456, .height_px = 0x0f234567 } }); good.content.image.sizing = .requested_fit;
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.figure(@as(?types.Figure, good));
    const bytes = try a.dupe(u8, raw.out.items);
    for (0..bytes.len) |end| {
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = bytes[0..end] }; try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    for ([_]u8{ 4, 255, 0, 1 }) |tag| {
        const bad = try a.dupe(u8, bytes); bad[bad.len - 2] = tag; // tags0/1 contradict thumbnail format
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = bad }; try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    for ([_][4]u8{ .{ 0x56, 0x34, 0x12, 0x0f }, .{ 0x67, 0x45, 0x23, 0x0f } }) |marker| {
        const bad = try a.dupe(u8, bytes); const offset = std.mem.indexOf(u8, bad, &marker).?;
        try std.testing.expect(std.mem.indexOf(u8, bad[offset + 4 ..], &marker) == null); @memset(bad[offset..][0..4], 0);
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = bad }; try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    const cases = [_]struct { format: types.FigureFormat, policy: types.FigureSizingPolicy, width: ?u32, height: ?u32 }{
        .{ .format = .thumbnail, .policy = .intrinsic, .width = 400, .height = null },
        .{ .format = .thumbnail, .policy = .original_width_with_height_bound, .width = 400, .height = 100 },
        .{ .format = .framed, .policy = .original_width_with_height_bound, .width = 400, .height = null },
        .{ .format = .framed, .policy = .requested_fit, .width = 400, .height = null },
        .{ .format = .thumbnail, .policy = .requested_fit, .width = null, .height = 100 },
        .{ .format = .thumbnail, .policy = .requested_fit_cap_original_width, .width = null, .height = null },
        .{ .format = .thumbnail, .policy = .requested_fit, .width = 0, .height = 100 },
        .{ .format = .thumbnail, .policy = .requested_fit, .width = 400, .height = 0 },
    };
    for (cases) |row| {
        var figure = good; figure.format = row.format; figure.content.image.sizing = row.policy; figure.content.image.span.image.?.width_px = row.width; figure.content.image.span.image.?.height_px = row.height;
        try std.testing.expect(!types.validFigure(figure)); raw.out.clearRetainingCapacity(); raw.remaining_items = max_items;
        try std.testing.expectError(error.InvalidPresentation, raw.figure(@as(?types.Figure, figure)));
    }
    // A missing required height remains invalid even when its final policy byte
    // is a known enum; no old-private-J or MIME-based fallback can reinterpret it.
    var framed = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } }); framed.format = .framed; framed.content.image.sizing = .intrinsic;
    raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try raw.figure(@as(?types.Figure, framed)); raw.out.items[raw.out.items.len - 2] = 1;
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items }; try std.testing.expectError(error.InvalidPresentation, reader.figure());
}

test "sizing is absent from old ordinary H I payloads and keeps least versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const empty: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental } };
    const old = try encodeAlloc(a, empty); const zeros: [28]u8 = @splat(0); const prefix = [_]u8{ 'D', 'P', 'R', '2' }; const golden = prefix ++ zeros;
    try std.testing.expectEqualSlices(u8, &golden, old);
    const h: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental, .display_title = &.{.{ .text = "old", .tooltip = "" }} } };
    const hb = try encodeAlloc(a, h); try std.testing.expectEqualStrings(tooltips_magic, hb[0..4]);
    const hr = try decodeAlloc(a, hb, "old", .supplemental, null); try std.testing.expectEqualDeep(h, hr); try std.testing.expectEqualSlices(u8, hb, try encodeAlloc(a, hr));
    const i: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) } }} }} } };
    const ib = try encodeAlloc(a, i); try std.testing.expectEqualStrings(block_geometry_magic, ib[0..4]);
    const ir = try decodeAlloc(a, ib, "old", .supplemental, null); try std.testing.expectEqualDeep(i, ir); try std.testing.expectEqualSlices(u8, ib, try encodeAlloc(a, ir));
}

test "J table box fields survive all owners with legacy geometry kept separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]types.StyleWidthUnit{ .px, .em, .percent }) |unit| {
        const style: types.TableStyle = .{ .width = .{ .unit = unit, .value = if (unit == .percent) 150 else 16 }, .padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.16 }), .clear = .left,
            .float_side = .left, .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0.4 }), .background = "#f9f9f9" };
        const table: types.Table = .{ .style = style, .geometry = .{ .width = .{ .unit = .percent, .value = 50 }, .cell_padding = 3 }, .rows = &.{.{ .cells = &.{.{ .style = .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 7 }) }, .spans = &.{.{ .kind = .link, .text = "cell", .target = "Target" }} }} }} };
        const child = [_]types.Block{.{ .kind = .table, .table = table }};
        var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 400 } }); figure.caption_blocks = &child;
        const scoped: types.BidiScope = .{ .mode = .isolate, .resolved_direction = .rtl, .parts = &.{.{ .kind = .figure, .figure = figure }} };
        const owners = [_]types.Block{ .{ .kind = .table, .table = table }, .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = scoped }} } };
        const enclosing: types.Table = .{ .caption_blocks = &child, .rows = &.{.{ .cells = &.{ .{ .blocks = &owners }, .{ .nested_table = table } } }} };
        const stored: types.Stored = .{ .entry = .{ .title = "table", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = enclosing }} }},
            .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &owners }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try std.testing.expect(hasTableBoxStyle(stored.entry.sections, stored.entry.references));
        try types.validateStored(a, stored, "table", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "table", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{}); const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); try std.testing.expectEqualDeep(decoded, parsed.value);
    }
    // A style-only ordinary table, without another J feature, still selects J.
    for ([_]types.TableStyle{ .{ .width = .{ .unit = .em, .value = 0 } }, .{ .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) }, .{ .clear = .none } }) |style| {
        const stored: types.Stored = .{ .entry = .{ .title = "table", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = .{ .style = style } }} }} } };
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, "table", .supplemental, null));
    }
}

test "J table style framing is strict and old versions retain their masks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const styles = [_]types.TableStyle{ .{ .width = .{ .unit = .em, .value = 16 } }, .{ .padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.16 }) }, .{ .clear = .none } };
    const lengths = [_]usize{ 7, 22, 3 };
    for (styles, lengths) |style, expected_len| {
        var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.tableStyle(style); try std.testing.expectEqual(expected_len, raw.out.items.len);
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items }; try std.testing.expectEqualDeep(@as(?types.TableStyle, style), try reader.tableStyle());
        for (0..raw.out.items.len) |end| { reader = .{ .a = a, .version = .image_maps, .bytes = raw.out.items[0..end] }; try std.testing.expectError(error.InvalidPresentation, reader.tableStyle()); }
        for ([_]Version{ .reference_blocks, .block_layout, .tooltips, .block_geometry }) |version| {
            reader = .{ .a = a, .version = version, .bytes = raw.out.items }; try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
            var old: Encoder = .{ .a = a, .version = version }; defer old.deinit(); try std.testing.expectError(error.InvalidPresentation, old.tableStyle(style));
        }
    }
    for ([_][]const u8{ &.{ 2 }, &.{ 1, 0 }, &.{ 1, 32, 3, 0, 0, 0, 0 }, &.{ 1, 128, 4 }, &.{ 1, 64, 2 } }) |bytes| {
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = bytes }; try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        var bytes = [_]u8{ 1, 32, 2, 0, 0, 0, 0 }; std.mem.writeInt(u32, bytes[3..7], @bitCast(number), .little);
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = &bytes }; try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    const old_style: types.TableStyle = .{ .background = "#abcdef", .float_side = .left };
    var old: Encoder = .{ .a = a, .version = .block_geometry }; defer old.deinit(); try old.tableStyle(old_style);
    var next: Encoder = .{ .a = a, .version = .image_maps }; defer next.deinit(); try next.tableStyle(old_style); try std.testing.expectEqualSlices(u8, old.out.items, next.out.items);
    var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = &.{0} }; try std.testing.expect((try reader.tableStyle()) == null);
    try std.testing.expect(!tableStyleHasBoxFields(old_style));
    next.out.clearRetainingCapacity(); try std.testing.expectError(error.InvalidPresentation, next.tableStyle(.{}));
}

test "Figure physical content-box minimum preserves null zero and px100 independently of media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]?types.StyleLength{ null, .{ .unit = .px, .value = 0 }, .{ .unit = .px, .value = 100 } }) |minimum| {
        var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 50 } }); figure.frame_min_width = minimum;
        figure.caption = &.{.{ .kind = .link, .text = "caption", .target = "Target" }};
        const scope: types.BidiScope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} };
        const blocks = [_]types.Block{ .{ .kind = .paragraph, .figure = figure }, .{ .kind = .list_item, .depth = 1, .list_path = "*", .flow = &.{.{ .kind = .scope, .scope = scope }} } };
        const stored: types.Stored = .{ .entry = .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }}, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &blocks }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try types.validateStored(a, stored, "minimum", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); const decoded = try decodeAlloc(a, bytes, "minimum", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        try std.testing.expectEqual(@as(?u32, 50), decoded.entry.sections[0].blocks[0].figure.?.content.image.span.image.?.width_px);
        const json = try std.json.Stringify.valueAlloc(a, figure, .{});
        try std.testing.expectEqual(minimum != null, std.mem.indexOf(u8, json, "\"frame_min_width\"") != null);
        if (minimum) |value| {
            const dynamic = try std.json.parseFromSlice(std.json.Value, a, json, .{});
            const field = dynamic.value.object.get("frame_min_width").?;
            try std.testing.expectEqualStrings("px", field.object.get("unit").?.string);
            const number = switch (field.object.get("value").?) { .integer => |v| @as(f64, @floatFromInt(v)), .float => |v| v, else => return error.UnexpectedJsonNumber };
            try std.testing.expectEqual(@as(f64, value.value), number);
        }
    }
}

test "Figure minimum strict presence unit finite validation and older encoder gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 50 } }); figure.frame_min_width = .{ .unit = .px, .value = 100 };
    var raw: Encoder = .{ .a = a, .version = .image_maps }; defer raw.deinit(); try raw.figure(@as(?types.Figure, figure));
    const good = try a.dupe(u8, raw.out.items);
    try std.testing.expectEqual(@as(u8, 1), good[good.len - 6]); try std.testing.expectEqual(@as(u8, 0), good[good.len - 5]);
    for (0..good.len) |end| { var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = good[0..end] }; try std.testing.expectError(error.InvalidPresentation, reader.figure()); }
    for ([_]struct { offset: usize, value: u8 }{ .{ .offset = good.len - 6, .value = 2 }, .{ .offset = good.len - 5, .value = 1 }, .{ .offset = good.len - 5, .value = 2 } }) |change| {
        const bad = try a.dupe(u8, good); bad[change.offset] = change.value;
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = bad }; try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        const bad = try a.dupe(u8, good); std.mem.writeInt(u32, bad[bad.len - 4 ..][0..4], @bitCast(number), .little);
        var reader: Reader = .{ .a = a, .version = .image_maps, .bytes = bad }; try std.testing.expectError(error.InvalidPresentation, reader.figure());
        figure.frame_min_width = .{ .unit = .px, .value = number }; try std.testing.expect(!types.validFigure(figure));
        raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try std.testing.expectError(error.InvalidPresentation, raw.figure(@as(?types.Figure, figure)));
    }
    figure.frame_min_width = .{ .unit = .em, .value = 100 }; try std.testing.expect(!types.validFigure(figure));
    figure.frame_min_width = .{ .unit = .px, .value = 100 };
    for ([_]Version{ .dynamic_catalog, .tooltips, .block_geometry }) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit(); try std.testing.expectError(error.InvalidPresentation, old.figure(@as(?types.Figure, figure)));
    }
    figure.frame_min_width = null; raw.out.clearRetainingCapacity(); raw.remaining_items = max_items; try raw.figure(@as(?types.Figure, figure));
    try std.testing.expectEqual(@as(u8, 0), raw.out.items[raw.out.items.len - 1]);
}


test "K inline table style preserves computed inheritance and recursive codec content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const style: types.TableStyle = .{ .display = .inline_block, .vertical_align = .middle,
        .line_height = .{ .value = 1, .font_scale_basis = .normal_body }, .collapse = .collapse };
    const cell: types.Cell = .{ .spans = &.{.{ .kind = .link, .text = "file", .target = "File:audio.ogg", .font_scale = 0.8, .font_scale_basis = .normal_body }} };
    const table: types.Table = .{ .style = style, .rows = &.{.{ .cells = &.{cell} }} };
    const blocks = [_]types.Block{.{ .kind = .list_item, .list_path = "*", .table = table }};
    var recursive_table = table;
    recursive_table.style.?.display = null;
    recursive_table.style.?.vertical_align = null;
    const recursive_blocks = [_]types.Block{.{ .kind = .table, .table = recursive_table }};
    const enclosing: types.Table = .{ .caption_blocks = &recursive_blocks, .rows = &.{.{ .cells = &.{.{ .nested_table = recursive_table }, .{ .blocks = &recursive_blocks }} }} };
    const stored: types.Stored = .{ .entry = .{ .title = "audio", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = enclosing }, blocks[0]} }},
        .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &recursive_blocks }} } };
    try types.validateStored(a, stored, "audio", .supplemental, null);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "audio", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); try std.testing.expectEqualDeep(decoded, parsed.value);
    var raw: Encoder = .{ .a = a, .version = .inline_table_styles }; defer raw.deinit(); try raw.tableStyle(style);
    for (0..raw.out.items.len) |end| {
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    var old: Encoder = .{ .a = a, .version = .image_maps }; defer old.deinit();
    try std.testing.expectError(error.InvalidPresentation, old.tableStyle(style));
    for ([_]u8{ 8, 128, 255 }) |unknown| {
        const invalid = [_]u8{ 1, 0, unknown };
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = &invalid };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    for ([_]types.TableStyle{ .{ .line_height = .{ .value = 0 } }, .{ .line_height = .{ .value = std.math.nan(f32) } } }) |bad|
        try std.testing.expectError(error.InvalidPresentation, raw.tableStyle(bad));
    const invalid_enum = [_]u8{ 1, 0, 1, 255 };
    var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = &invalid_enum };
    try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
}


test "K fractional line height matches exact JSON number and old absent fields stay on J" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const style: types.TableStyle = .{ .display = .inline_table, .vertical_align = .middle,
        .line_height = .{ .value = 1.2, .font_scale_basis = .normal_body } };
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .style = style,
        .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "fraction" }} }} }} } }};
    const stored: types.Stored = .{ .entry = .{ .title = "fraction", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }} } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "fraction", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "1.2000000476837158") != null);
    var legacy = stored;
    var old_blocks = blocks;
    old_blocks[0].table.?.style = .{ .clear = .none };
    const sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = &old_blocks }};
    legacy.entry.sections = &sections;
    const old = try encodeAlloc(a, legacy);
    try std.testing.expectEqualStrings(image_maps_magic, old[0..4]);
    // The selected old frame is exactly the unchanged explicit J encoder path.
    var encoder: Encoder = .{ .a = a, .version = .image_maps }; defer encoder.deinit();
    try encoder.out.appendSlice(a, image_maps_magic);
    try encoder.spans(legacy.entry.display_title); try encoder.sections(legacy.entry.sections);
    try encoder.spans(legacy.entry.preamble_spans); try encoder.layout(legacy.entry.organization);
    try encoder.references(legacy.entry.references); try encoder.media(legacy.entry.media);
    try std.testing.expectEqualSlices(u8, encoder.out.items, old);
    var invalid = blocks[0].table.?;
    invalid.caption = &.{.{ .text = "caption stays authored" }};
    var raw: Encoder = .{ .a = a, .version = .inline_table_styles }; defer raw.deinit();
    try std.testing.expectError(error.InvalidPresentation, raw.table(@as(?types.Table, invalid)));
}


test "K style carries J figure scope maps tooltip explicit target and reference content together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const regions = [_]types.MapRegion{.{ .shape = .circle, .coordinates = &.{ -0.0, 2, 3 },
        .action = .{ .kind = .internal, .target = "Region", .target_fragment = "fragment", .label = "region" } }};
    const image: types.Span = .{ .kind = .link, .target = "File:Figure.svg", .target_fragment = "", .tooltip = "image advice",
        .image = .{ .file = "Figure.svg", .width_px = 190, .border = true, .map = .{ .regions = &regions } } };
    const inline_table: types.Table = .{ .style = .{ .display = .inline_block, .vertical_align = .middle,
        .line_height = .{ .value = 1.2, .font_scale_basis = .normal_body } },
        .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "file", .target = "File:audio.ogg", .tooltip = "detail", .font_scale = 0.8, .font_scale_basis = .normal_body }} }} }} };
    var block_table = inline_table;
    block_table.style.?.display = null;
    block_table.style.?.vertical_align = null;
    const caption_blocks = [_]types.Block{.{ .kind = .table, .table = block_table }};
    var figure = FigureCodecFixture.make(image); figure.caption_blocks = &caption_blocks;
    const scope: types.BidiScope = .{ .mode = .isolate, .resolved_direction = .rtl,
        .parts = &.{.{ .kind = .figure, .figure = figure }} };
    const blocks = [_]types.Block{ .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = scope }} },
        .{ .kind = .table, .table = inline_table } };
    const stored: types.Stored = .{ .entry = .{ .title = "mixed K", .kind = .supplemental,
        .display_title = &.{image}, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }},
        .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &caption_blocks }},
        .media = &.{.{ .kind = .image, .file = "Figure.svg", .caption = "" }} } };
    try types.validateStored(a, stored, "mixed K", .supplemental, null);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "mixed K", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections,
        stored.entry.organization, stored.entry.references, stored.entry.media));
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    // Deep styles alone must select K alongside the old J map and Scope.
    var deep_only = stored;
    const deep_sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = blocks[0..1] }};
    deep_only.entry.sections = &deep_sections;
    const deep_bytes = try encodeAlloc(a, deep_only);
    try std.testing.expectEqualStrings(inline_table_styles_magic, deep_bytes[0..4]);
    try std.testing.expectEqualDeep(deep_only, try decodeAlloc(a, deep_bytes, "mixed K", .supplemental, null));
}


test "K inline capability validates shared cell media and owner contexts without losing legacy body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const style: types.TableStyle = .{ .display = .inline_block, .vertical_align = .middle, .line_height = .{ .value = 1 } };
    const audio: types.Span = .{ .text = "voice", .classes = "wikidict-media wikidict-media-file-546f6e652e6f6767" };
    const table: types.Table = .{ .style = style, .rows = &.{.{ .cells = &.{.{ .spans = &.{audio} }} }} };
    var blocks = [_]types.Block{.{ .kind = .list_item, .list_path = "*", .table = table }};
    const sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = &blocks }};
    var stored: types.Stored = .{ .entry = .{ .title = "audio domain", .kind = .supplemental, .sections = &sections,
        .media = &.{.{ .kind = .audio, .file = "Tone.ogg", .caption = "" }} } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null));
    const changed = try a.dupe(u8, bytes);
    const audio_name = std.mem.lastIndexOf(u8, changed, "Tone.ogg").?;
    changed[audio_name + "Tone.ogg".len] = @intFromEnum(types.MediaKind.image);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, changed, stored.entry.title, .supplemental, null));
    const duplicate_audio = [_]types.Media{ stored.entry.media[0], stored.entry.media[0] };
    stored.entry.media = &duplicate_audio;
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    stored.entry.media = &.{}; try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    stored.entry.media = &.{.{ .kind = .image, .file = "Tone.ogg", .caption = "" }};
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    stored.entry.media = &.{.{ .kind = .audio, .file = "Tone.ogg", .caption = "" }};
    blocks[0].spans = &.{.{ .text = "not discarded" }}; try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    blocks[0].spans = &.{};
    blocks[0].feature = .{ .kind = "color_swatch", .data = "#abcdef" }; try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    blocks[0].feature = null;
    stored.entry.sections = &.{};
    stored.entry.references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &blocks }};
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
}

test "K image dark filter preserves recursive presentation and remains conditional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.Span = .{ .kind = .link, .target = "File:Figure.svg", .image = .{ .file = "Figure.svg", .width_px = 470, .height_px = 390, .alt = "map", .tooltip = "map", .dark_mode_filter = .invert_hue_rotate_180,
        .map = .{ .description = .none, .regions = &.{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 1, 1 }, .action = .{ .kind = .internal, .target = "theme", .label = "Here" } }} } } };
    const paragraph = [_]types.Block{.{ .kind = .paragraph, .spans = &.{image} }};
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &paragraph }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    const figure = FigureCodecFixture.make(image);
    const cases = [_]types.Entry{
        .{ .title = "theme", .kind = .supplemental, .display_title = &.{image} },
        .{ .title = "theme", .kind = .supplemental, .preamble_spans = &.{image} },
        .{ .title = "theme", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &paragraph }} },
        .{ .title = "theme", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "theme", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "theme", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .@"inline", .spans = &.{image} }} } }} }} }} },
        .{ .title = "theme", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .spans = &.{image} }} },
        .{ .title = "theme", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{.{ .kind = .table, .table = nested }} }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "map" }};
        try std.testing.expect(hasImageDarkModeFilters(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "theme", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        try std.testing.expect(std.mem.indexOf(u8, json, "\"dark_mode_filter\":\"invert_hue_rotate_180\"") != null);
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        try std.testing.expectEqualDeep(decoded, parsed.value);
    }
    // Both new domains share K; neither is a new unconditional wire version.
    const mixed: types.Stored = .{ .entry = .{ .title = "theme", .kind = .supplemental,
        .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "map" }},
        .sections = &.{.{ .level = 2, .title = "mixed", .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{image} },
            .{ .kind = .table, .table = .{ .style = .{ .display = .inline_block }, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "inline table" }} }} }} } },
        } }} } };
    const bytes = try encodeAlloc(a, mixed);
    try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
    try std.testing.expectEqualDeep(mixed, try decodeAlloc(a, bytes, "theme", .supplemental, null));
}

test "K image dark filter rejects old versions unknown flags enum and truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.InlineImage = .{ .file = "X.svg", .width_px = 30, .dark_mode_filter = .invert_hue_rotate_180 };
    var current: Encoder = .{ .a = a, .version = .inline_table_styles }; defer current.deinit();
    try current.inlineImage(image);
    const good = try a.dupe(u8, current.out.items);
    const flags_at = 5 + image.file.len;
    try std.testing.expectEqual(@as(u8, 0x41), good[flags_at]);
    try std.testing.expectEqual(@as(u8, 0), good[good.len - 1]);
    var valid: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = good };
    try std.testing.expectEqualDeep(image, (try valid.inlineImage()).?);
    for (0..good.len) |end| {
        var short: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = good[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.inlineImage());
    }
    for ([_]u8{ 1, 255 }) |tag| {
        const bad = try a.dupe(u8, good); bad[bad.len - 1] = tag;
        var unknown: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, unknown.inlineImage());
    }
    const reserved = try a.dupe(u8, good); reserved[flags_at] |= 0x80;
    var unknown: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = reserved };
    try std.testing.expectError(error.InvalidPresentation, unknown.inlineImage());
    for ([_]Version{ .reference_blocks, .image_border, .block_layout, .explicit_targets, .dynamic_catalog, .tooltips, .block_geometry, .image_maps }) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.inlineImage(image));
        var reader: Reader = .{ .a = a, .version = version, .bytes = good };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    var plain = image; plain.dark_mode_filter = null;
    var old: Encoder = .{ .a = a, .version = .image_maps }; defer old.deinit();
    var next: Encoder = .{ .a = a, .version = .inline_table_styles }; defer next.deinit();
    try old.inlineImage(plain); try next.inlineImage(plain);
    try std.testing.expectEqualSlices(u8, old.out.items, next.out.items);
    const json = try std.json.Stringify.valueAlloc(a, plain, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "dark_mode_filter") == null);
}


const MissingFigureCodecTest = struct {
    fn make() types.Figure {
        const zero = types.StyleEdges.all(.{ .unit = .px, .value = 0 });
        return .{ .content = .{ .missing = .{
            .label = .{ .kind = .external_link, .text = "File:Missing.png", .target = "//example.invalid/upload?file=Missing.png", .tooltip = "File:Missing.png", .font_scale = 0.94 },
            .width = .{ .unit = .px, .value = 180 }, .line_height = .{ .unit = .em, .value = 1.504 },
        } }, .format = .thumbnail, .placement = .float_right, .clear = .none,
            .margins = zero, .image_insets = types.StyleEdges.all(.{ .unit = .px, .value = 3 }), .caption_padding = zero,
            .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
            .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none },
            .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
            .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    }
};

test "K missing Figure recursively retains real label action caption style and no image catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var missing = MissingFigureCodecTest.make();
    missing.caption = &.{.{ .kind = .link, .text = "Caption", .target = "Caption target", .tooltip = "Caption advice", .italic = true }};
    const body = [_]types.Block{.{ .kind = .paragraph, .figure = missing }};
    const scope: types.BidiScope = .{ .mode = .isolate, .authored_direction = .rtl, .resolved_direction = .rtl,
        .language = "he", .parts = &.{.{ .kind = .figure, .figure = missing }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &body }} }} };
    const cases = [_]types.Entry{
        .{ .title = "missing", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &body }} },
        .{ .title = "missing", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = scope }} }} }} },
        .{ .title = "missing", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Cell", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "missing", .kind = .supplemental, .references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .blocks = &body }} },
    };
    for (cases) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, "missing", .supplemental, null);
        try std.testing.expect(hasMissingFigures(entry.sections, entry.references));
        try std.testing.expect(!hasInlineImages(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "missing", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqual(@as(usize, 0), decoded.entry.media.len);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const reparsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        try std.testing.expectEqualDeep(stored, reparsed.value);
    }
    // A missing descendant selects K while the sibling image still carries all
    // established J image-map/tooltip/action and K dark-filter fields.
    const regions = [_]types.MapRegion{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 10, 10 },
        .action = .{ .kind = .internal, .target = "Map target", .target_fragment = "", .label = "Map label" } }};
    var outer = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Picture.svg", .tooltip = "Image advice",
        .image = .{ .file = "Picture.svg", .width_px = 100, .dark_mode_filter = .invert_hue_rotate_180,
            .map = .{ .regions = &regions } } });
    outer.caption_blocks = &body;
    const mixed: types.Stored = .{ .entry = .{ .title = "mixed", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Rich", .blocks = &.{.{ .kind = .paragraph, .figure = outer }} }},
        .media = &.{.{ .file = "Picture.svg", .kind = .image, .caption = "Picture" }} } };
    const mixed_bytes = try encodeAlloc(a, mixed);
    try std.testing.expectEqualStrings(inline_table_styles_magic, mixed_bytes[0..4]);
    const mixed_decoded = try decodeAlloc(a, mixed_bytes, "mixed", .supplemental, null);
    try std.testing.expectEqualDeep(mixed, mixed_decoded);
    try std.testing.expectEqualSlices(u8, mixed_bytes, try encodeAlloc(a, mixed_decoded));
}

test "K missing Figure tag and positive dimensions reject legacy malformed truncated or fake content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const figure = MissingFigureCodecTest.make();
    var raw: Encoder = .{ .a = a, .version = .inline_table_styles }; defer raw.deinit();
    try raw.figure(@as(?types.Figure, figure));
    const bytes = try a.dupe(u8, raw.out.items);
    try std.testing.expectEqual(@as(u8, 2), bytes[0]);
    var valid: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bytes };
    try std.testing.expectEqualDeep(figure, (try valid.figure()).?);
    try std.testing.expectEqual(bytes.len, valid.pos);
    for (0..bytes.len) |end| {
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bytes[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    for ([_]u8{ 3, 255 }) |tag| {
        const bad = try a.dupe(u8, bytes); bad[0] = tag;
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    var old: Reader = .{ .a = a, .version = .image_maps, .bytes = bytes };
    try std.testing.expectError(error.InvalidPresentation, old.figure());
    var old_encoder: Encoder = .{ .a = a, .version = .image_maps }; defer old_encoder.deinit();
    try std.testing.expectError(error.InvalidPresentation, old_encoder.figure(@as(?types.Figure, figure)));
    for ([_]f32{ figure.content.missing.width.value, figure.content.missing.line_height.value }) |number| {
        var marker: [4]u8 = undefined; std.mem.writeInt(u32, &marker, @bitCast(number), .little);
        const offset = std.mem.indexOf(u8, bytes, &marker).?;
        try std.testing.expect(std.mem.indexOf(u8, bytes[offset + 4 ..], &marker) == null);
        for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32) }) |bad_value| {
            const bad = try a.dupe(u8, bytes); std.mem.writeInt(u32, bad[offset..][0..4], @bitCast(bad_value), .little);
            var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bad };
            try std.testing.expectError(error.InvalidPresentation, reader.figure());
        }
        const bad_unit = try a.dupe(u8, bytes); bad_unit[offset - 1] = 2;
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bad_unit };
        try std.testing.expectError(error.InvalidPresentation, reader.figure());
    }
    var fake = figure; fake.content.missing.label.image = .{ .file = "Fake.png" };
    try std.testing.expectError(error.InvalidPresentation, raw.figure(@as(?types.Figure, fake)));
    var exhausted: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bytes, .remaining_items = 0 };
    try std.testing.expectError(error.InvalidPresentation, exhausted.figure());
    var absent: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = &.{0} };
    try std.testing.expect(try absent.figure() == null);
    // Existing J image content remains presence1 with its old tail policy.
    const image = FigureCodecFixture.make(.{ .image = .{ .file = "Picture.svg", .width_px = 100 } });
    var image_raw: Encoder = .{ .a = a, .version = .image_maps }; defer image_raw.deinit();
    try image_raw.figure(@as(?types.Figure, image));
    try std.testing.expectEqual(@as(u8, 1), image_raw.out.items[0]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(image.content.image.sizing)), image_raw.out.items[image_raw.out.items.len - 2]);
    var image_reader: Reader = .{ .a = a, .version = .image_maps, .bytes = image_raw.out.items };
    try std.testing.expectEqualDeep(image, (try image_reader.figure()).?);
}

test "missing Figure build Span flags remain native and allocation failures release owned trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const Flags = packed struct(u8) { bold: bool = true, italic: bool = true, code: bool = false, small: bool = false,
        superscript: bool = false, subscript: bool = false, strike: bool = false, underline: bool = false };
    const RawKind = enum { text, link, external_link, build_only };
    const RawSpan = struct { kind: RawKind = .external_link, role: types.Role = .normal,
        text: []const u8 = "Missing raw", target: []const u8 = "https://example.invalid/upload",
        language: []const u8 = "en", classes: []const u8 = "new", direction: []const u8 = "ltr", explanation: []const u8 = "",
        flags: Flags = .{}, provenance: u8 = 77 };
    const base = MissingFigureCodecTest.make();
    const content: types.FigureContentFor(RawSpan) = .{ .missing = .{ .label = .{},
        .width = base.content.missing.width, .line_height = base.content.missing.line_height } };
    const build = .{ .content = content, .format = base.format, .frame_min_width = base.frame_min_width,
        .placement = base.placement, .clear = base.clear, .margins = base.margins, .image_insets = base.image_insets,
        .caption_padding = base.caption_padding, .caption_font_scale = base.caption_font_scale, .caption_line_height = base.caption_line_height,
        .frame_background = base.frame_background, .frame_border = base.frame_border, .image_background = base.image_background,
        .image_border = base.image_border, .caption_foreground = base.caption_foreground, .caption_background = base.caption_background };
    try std.testing.expect(types.validMissingFigureContent(build.content.missing));
    var unsupported = build; unsupported.content.missing.label.kind = .build_only;
    try std.testing.expect(!types.validMissingFigureContent(unsupported.content.missing));
    var raw: Encoder = .{ .a = a, .version = .inline_table_styles }; defer raw.deinit();
    try std.testing.expectError(error.InvalidPresentation, raw.figure(@as(?@TypeOf(build), unsupported)));
    try raw.figure(@as(?@TypeOf(build), build));
    var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = raw.out.items };
    const decoded = (try reader.figure()).?;
    try std.testing.expect(decoded.content.missing.label.bold and decoded.content.missing.label.italic);
    try std.testing.expectEqualStrings("Missing raw", decoded.content.missing.label.text);
    try std.testing.expectEqual(@as(u8, 77), build.content.missing.label.provenance);
    const Case = struct {
        fn run(allocator: A) !void {
            var owned = std.heap.ArenaAllocator.init(allocator); defer owned.deinit(); const alloc = owned.allocator();
            const value: types.Stored = .{ .entry = .{ .title = "missing", .kind = .supplemental,
                .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .paragraph, .figure = MissingFigureCodecTest.make() }} }} } };
            const bytes = try encodeAlloc(alloc, value);
            const result = try decodeAlloc(alloc, bytes, "missing", .supplemental, null);
            try std.testing.expectEqualDeep(value, result);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(alloc, result));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}


test "K SVG languages preserve distinct occurrences and recursive identity with maps and theme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const ru: types.Span = .{ .kind = .link, .target = "File:Picture.svg", .language = "ja", .tooltip = "Advice",
        .image = .{ .file = "Picture.svg", .width_px = 200, .svg_language = "ru" } };
    var ko = ru; ko.image.?.svg_language = "ko";
    const pair = [_]types.Span{ ru, ko };
    const table: types.Table = .{ .caption = &.{ru}, .rows = &.{.{ .cells = &.{.{ .spans = &.{ko} }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    var figure = FigureCodecFixture.make(ru); figure.caption = &.{ko};
    const cases = [_]types.Entry{
        .{ .title = "variant", .kind = .supplemental, .display_title = &pair },
        .{ .title = "variant", .kind = .supplemental, .preamble_spans = &pair },
        .{ .title = "variant", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Spans", .blocks = &.{.{ .kind = .paragraph, .spans = &pair }} }} },
        .{ .title = "variant", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "variant", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "variant", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph,
            .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr,
                .parts = &.{.{ .kind = .@"inline", .spans = &pair }} } }} }} }} },
        .{ .title = "variant", .kind = .supplemental, .references = &.{.{ .kind = .note, .number = 1, .group_number = 1,
            .blocks = &.{.{ .kind = .table, .table = nested }} }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .file = "Picture.svg", .kind = .image, .caption = "Picture" }};
        try std.testing.expect(hasSvgLanguages(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "variant", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        if (entry.preamble_spans.len == 0) try std.testing.expectEqualSlices(u8, bytes,
            try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
    var combined = ru.image.?;
    combined.dark_mode_filter = .invert_hue_rotate_180;
    combined.map = .{ .regions = &.{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 10, 10 },
        .action = .{ .kind = .internal, .target = "Map target", .target_fragment = "", .label = "Map" } }} };
    var raw: Encoder = .{ .a = a, .version = .inline_table_styles }; defer raw.deinit(); try raw.inlineImage(combined);
    const flags_at = 5 + combined.file.len;
    try std.testing.expectEqual(@as(u8, 0xe1), raw.out.items[flags_at]);
    var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(combined, (try reader.inlineImage()).?);
    try std.testing.expectEqual(raw.out.items.len, reader.pos);
}

test "SVG language flag is K only strict and absent fields retain old bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.InlineImage = .{ .file = "Picture.svg", .width_px = 200, .svg_language = "ru" };
    var current: Encoder = .{ .a = a, .version = .inline_table_styles }; defer current.deinit(); try current.inlineImage(image);
    const bytes = try a.dupe(u8, current.out.items);
    const flags_at = 5 + image.file.len;
    try std.testing.expectEqual(@as(u8, 0x81), bytes[flags_at]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 'r', 'u' }, bytes[bytes.len - 6 ..]);
    for (0..bytes.len) |end| {
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bytes[0..end] };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    for ([_]Version{ .reference_blocks, .image_border, .block_layout, .explicit_targets, .dynamic_catalog, .tooltips, .block_geometry, .image_maps }) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.inlineImage(image));
        var reader: Reader = .{ .a = a, .version = version, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    // Corrupt only the canonical language bytes, retaining the authenticated
    // payload framing so rejection is due to identity syntax, not truncation.
    for ([_][2]u8{ .{ 'R', 'U' }, .{ '-', 'u' }, .{ 'r', '-' }, .{ 'r', 0 } }) |language| {
        const bad = try a.dupe(u8, bytes); @memcpy(bad[bad.len - 2 ..], &language);
        var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineImage());
    }
    var plain = image; plain.svg_language = null;
    var old: Encoder = .{ .a = a, .version = .image_maps }; defer old.deinit();
    var next: Encoder = .{ .a = a, .version = .inline_table_styles }; defer next.deinit();
    try old.inlineImage(plain); try next.inlineImage(plain);
    try std.testing.expectEqualSlices(u8, old.out.items, next.out.items);
    const json = try std.json.Stringify.valueAlloc(a, plain, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "svg_language") == null);
    const stored: types.Stored = .{ .entry = .{ .title = "plain", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .image = plain }} }} }},
        .media = &.{.{ .file = "Picture.svg", .kind = .image, .caption = "Picture" }} } };
    const old_frame = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(reference_blocks_magic, old_frame[0..4]);
}


test "K missing link paint has exact optional framing and strict closed enum with rich SVG sibling parity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = MissingFigureCodecTest.make();
    var absent: Encoder = .{ .a = a, .version = .inline_table_styles }; defer absent.deinit();
    try absent.figure(@as(?types.Figure, figure));
    figure.content.missing.link_paint = .vector_new_link_v1;
    var present: Encoder = .{ .a = a, .version = .inline_table_styles }; defer present.deinit();
    try present.figure(@as(?types.Figure, figure));
    var marker: [4]u8 = undefined;
    std.mem.writeInt(u32, &marker, @bitCast(figure.content.missing.line_height.value), .little);
    const marker_at = std.mem.indexOf(u8, present.out.items, &marker).?;
    try std.testing.expect(std.mem.indexOf(u8, present.out.items[marker_at + 4 ..], &marker) == null);
    const paint_at = marker_at + 4;
    try std.testing.expectEqual(@as(u8, 0), absent.out.items[paint_at]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, present.out.items[paint_at..][0..2]);
    try std.testing.expectEqualSlices(u8, absent.out.items[0..paint_at], present.out.items[0..paint_at]);
    try std.testing.expectEqualSlices(u8, absent.out.items[paint_at + 1 ..], present.out.items[paint_at + 2 ..]);
    var reader: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = present.out.items };
    try std.testing.expectEqualDeep(figure, (try reader.figure()).?);
    try std.testing.expectEqual(present.out.items.len, reader.pos);
    for ([_]usize{ paint_at, paint_at + 1 }) |offset| {
        const bad = try a.dupe(u8, present.out.items); bad[offset] = 255;
        var malformed: Reader = .{ .a = a, .version = .inline_table_styles, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, malformed.figure());
    }
    var invalid = figure; invalid.content.missing.label.foreground = "#bf3c2c";
    try std.testing.expectError(error.InvalidPresentation, present.figure(@as(?types.Figure, invalid)));
    const variant: types.Span = .{ .kind = .link, .target = "File:Picture.svg", .tooltip = "real variant",
        .image = .{ .file = "Picture.svg", .width_px = 200, .svg_language = "ko", .dark_mode_filter = .invert_hue_rotate_180,
            .map = .{ .regions = &.{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 1, 1 },
                .action = .{ .kind = .internal, .target = "Map target", .target_fragment = "", .label = "Map" } }} } } };
    figure.caption_blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .@"inline", .spans = &.{variant} }} }};
    const stored: types.Stored = .{ .entry = .{ .title = "paint", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Complete", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }},
        .media = &.{.{ .file = "Picture.svg", .kind = .image, .caption = "Picture" }} } };
    const payload = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(inline_table_styles_magic, payload[0..4]);
    const decoded = try decodeAlloc(a, payload, "paint", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, payload, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, payload, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections,
        stored.entry.organization, stored.entry.references, stored.entry.media));
}


test "L recursive real containers retain full layout suffixes styles actions and inherited K media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.Span = .{ .kind = .link, .target = "File:Picture.svg", .tooltip = "picture", .image = .{
        .file = "Picture.svg", .width_px = 200, .svg_language = "ru", .dark_mode_filter = .invert_hue_rotate_180,
        .map = .{ .description = .none, .regions = &.{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 10, 10 }, .action = .{ .kind = .internal, .target = "Region", .label = "region" } }} },
    } };
    var missing = MissingFigureCodecTest.make(); missing.content.missing.link_paint = .vector_new_link_v1;
    const inner = [_]types.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "intro", .font_scale = 0.9, .font_scale_basis = .normal_body }} },
        .{ .kind = .definition, .list_path = "#", .spans = &.{.{ .text = "meaning", .bold = true }} },
        .{ .kind = .example, .spans = &.{.{ .kind = .link, .text = "example", .target = "Target", .target_fragment = "", .tooltip = "advice" }} },
        .{ .kind = .quotation, .spans = &.{.{ .text = "quote", .italic = true }} },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "note", .background = "#abcdef" }} },
        .{ .kind = .paragraph, .spans = &.{image} },
        .{ .kind = .paragraph, .figure = missing },
    };
    const owner = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &inner, .style = .{
        .width = .{ .length = .{ .unit = .px, .value = 250 } }, .layout = .flex_row, .align_items = .center,
        .padding = types.StyleEdges.all(.{ .unit = .px, .value = 4 }), .background = .{ .rgb = "#f9f9f9" },
        .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .light_dark = .{ .light = "#a2a9b1", .dark = "#72777d" } } } },
        .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } }, .max_width = .{ .length = .{ .unit = .percent, .value = 100 } }, .box_sizing = .border_box, .line_height = .{ .multiplier = 1.5 } },
    } } }, .{ .kind = .paragraph, .spans = &.{.{ .text = "outside" }} }};
    var senses = [_]types.Sense{.{ .block = 0, .block_path = &.{1}, .examples = &.{0}, .example_paths = &.{&.{2}}, .quotations = &.{0}, .quotation_paths = &.{&.{3}}, .notes = &.{0}, .note_paths = &.{&.{4}} }};
    const lexemes = [_]types.Lexeme{.{ .kind = "Noun", .section = 0, .definitions = &senses, .introduction = &.{ 0, 1 }, .introduction_paths = &.{ &.{0}, &.{} }, .other_blocks = &.{0}, .other_block_paths = &.{&.{5}} }};
    const stored: types.Stored = .{ .entry = .{ .title = "container", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Body", .blocks = &owner }}, .organization = .{ .lexemes = &lexemes },
        .media = &.{.{ .file = "Picture.svg", .kind = .image, .caption = "picture" }},
    } };
    try types.validateStored(a, stored, "container", .supplemental, null);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "container", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit(); try std.testing.expectEqualDeep(stored, parsed.value);
    senses[0].example_paths = &.{&.{99}};
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
}

test "L selection visits containers in table cell caption Figure Flow and reference owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const boxed = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Target", .text = "kept" }} }} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxed;
    const table: types.Table = .{ .caption_blocks = &boxed, .rows = &.{.{ .cells = &.{.{ .blocks = &boxed }} }} };
    const cases = [_]types.Entry{
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxed }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested table", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } }} }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "sinks", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "sinks", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxed }} },
        .{ .title = "sinks", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .table, .table = table }} }} },
    };
    for (cases) |entry| {
        const stored: types.Stored = .{ .entry = entry }; const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
        try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, "sinks", .supplemental, null));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
    }
}

test "L container framing rejects old versions bad style grammar truncation depth and budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const box: types.Block = .{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "word" }} }}, .style = .{ .layout = .flex_row, .align_items = .center, .width = .fit_content, .line_height = .{ .multiplier = 1.5 } } } };
    var raw: Encoder = .{ .a = a, .version = .block_containers }; defer raw.deinit(); try raw.block(box);
    var read: Reader = .{ .a = a, .version = .block_containers, .bytes = raw.out.items }; try std.testing.expectEqualDeep(box, try read.block());
    try std.testing.expectEqual(raw.out.items.len, read.pos);
    for (0..raw.out.items.len) |end| { var short: Reader = .{ .a = a, .version = .block_containers, .bytes = raw.out.items[0..end] }; try std.testing.expectError(error.InvalidPresentation, short.block()); }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime hasLFields(version)) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit(); try std.testing.expectError(error.InvalidPresentation, old.block(box));
        var reader: Reader = .{ .a = a, .version = version, .bytes = raw.out.items }; try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    var exhausted: Reader = .{ .a = a, .version = .block_containers, .bytes = raw.out.items, .remaining_items = 0 }; try std.testing.expectError(error.InvalidPresentation, exhausted.block());
    var too_deep: Reader = .{ .a = a, .version = .block_containers, .bytes = raw.out.items, .content_depth = types.max_content_depth }; try std.testing.expectError(error.InvalidPresentation, too_deep.block());
    for ([_][]const u8{ &.{ 0, 128 }, &.{ 4, 0, 3 }, &.{ 0, 1, 255 }, &.{ 0, 64, 207, 2, 0, 0, 0 }, &.{ 0, 64, 207, 2, 0, 0, 16 } }) |bad| {
        var reader: Reader = .{ .a = a, .version = .block_containers, .bytes = bad }; try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
    var style: Encoder = .{ .a = a, .version = .block_containers }; defer style.deinit();
    const all: types.ContainerStyle = .{ .margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }), .padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.2 }), .width = .auto,
        .float_side = .left, .clear = .both, .max_width = .none, .box_sizing = .content_box, .layout = .flex_row, .align_items = .end, .flex_item = .none,
        .background = .transparent, .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .rgb = "#123456" } } }, .line_height = .normal, .text_align = .right,
        .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } }, .max_width = .none, .box_sizing = .border_box, .line_height = .{ .length = .{ .unit = .em, .value = 1.35 } } }, };
    try style.containerStyle(all);
    var reader: Reader = .{ .a = a, .version = .block_containers, .bytes = style.out.items }; try std.testing.expectEqualDeep(all, try reader.containerStyle());
    for (0..style.out.items.len) |end| { var short: Reader = .{ .a = a, .version = .block_containers, .bytes = style.out.items[0..end] }; try std.testing.expectError(error.InvalidPresentation, short.containerStyle()); }
}

test "L absence preserves every old block prefix and legacy organization defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const empty: types.Block = .{ .kind = .paragraph };
    var old: Encoder = .{ .a = a, .version = .inline_table_styles }; defer old.deinit(); try old.block(empty);
    var next: Encoder = .{ .a = a, .version = .block_containers }; defer next.deinit(); try next.block(empty);
    try std.testing.expectEqualSlices(u8, old.out.items, next.out.items);
    try std.testing.expectEqual(@as(usize, 29), next.out.items.len);
    const stored: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .definition, .spans = &.{.{ .text = "old" }} }} }}, .organization = .{ .lexemes = &.{.{ .kind = "Noun", .section = 0, .definitions = &.{.{ .block = 0 }}, .introduction = &.{0}, .other_blocks = &.{0} }} } } };
    const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(magic, bytes[0..4]);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, "old", .supplemental, null));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    const plain_json = try std.json.Stringify.valueAlloc(a, stored, .{});
    try std.testing.expect(std.mem.indexOf(u8, plain_json, "\"container\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_json, "_paths\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_json, "block_path") == null);
    var old_layout: Encoder = .{ .a = a, .version = .inline_table_styles }; defer old_layout.deinit();
    var changed = stored.entry.organization.lexemes[0]; var sense = changed.definitions[0]; sense.block_path = &.{0}; changed.definitions = &.{sense};
    try std.testing.expectError(error.InvalidPresentation, old_layout.layout(types.Layout{ .lexemes = &.{changed} }));
}

test "L recursive decode encode allocations preserve owned trees on failure" {
    const Case = struct {
        fn run(allocator: A) !void {
            var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit(); const a = arena.allocator();
            const stored: types.Stored = .{ .entry = .{ .title = "box", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .definition, .spans = &.{.{ .kind = .link, .target = "Target", .text = "meaning" }} }} } }} }}, .organization = .{ .lexemes = &.{.{ .kind = "Noun", .section = 0, .definitions = &.{.{ .block = 0, .block_path = &.{0} }} }} } } };
            const bytes = try encodeAlloc(a, stored); const result = try decodeAlloc(a, bytes, "box", .supplemental, null);
            try std.testing.expectEqualDeep(stored, result); try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, result));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}


test "L generic build container preserves distinct enum tags and recursive suffix transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const RawKind = enum { paragraph, build_only, definition, container };
    const RawBlock = struct {
        kind: RawKind, depth: u8 = 0, spans: []const types.Span = &.{}, feature: ?types.Feature = null,
        list_path: []const u8 = "", number: []const u8 = "", level: u8 = 0, anchor: []const u8 = "", anchor_fallback: []const u8 = "",
        table: ?types.Table = null, text_align: ?types.CellTextAlign = null, style: ?types.BlockStyle = null,
        figure: ?types.Figure = null, flow: ?[]const types.FlowPart = null,
        container: ?types.ContainerFor(@This()) = null,
    };
    const RawSection = struct { level: u8, title: []const u8, blocks: []const RawBlock, anchor: []const u8 = "", anchor_fallback: []const u8 = "" };
    const children = [_]RawBlock{.{ .kind = .definition, .list_path = "#", .spans = &.{.{ .kind = .link, .text = "meaning", .target = "Target" }} }};
    const root = [_]RawBlock{.{ .kind = .container, .container = .{ .blocks = &children, .style = .{ .width = .fit_content } } }};
    const sections = [_]RawSection{.{ .level = 2, .title = "Body", .blocks = &root }};
    const layout_value: types.Layout = .{ .lexemes = &.{.{ .kind = "Noun", .section = 0, .definitions = &.{.{ .block = 0, .block_path = &.{0} }} }} };
    const bytes = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, layout_value, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "raw", .supplemental, null);
    try std.testing.expectEqualDeep(layout_value, decoded.entry.organization);
    const leaf = types.resolveBlockPath(decoded.entry.sections[0].blocks, 0, &.{0}).?;
    try std.testing.expectEqualStrings("Target", leaf.spans[0].target);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    var bad = root[0]; bad.kind = .build_only; try std.testing.expect(!types.validContainerContext(bad));
    var raw: Encoder = .{ .a = a, .version = .block_containers }; defer raw.deinit();
    try std.testing.expectError(error.UncompiledTemplate, raw.block(bad));
}


test "L responsive float margins append after exact old screen bytes and reject reserved grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const old: types.ContainerScreenMaxWidth = .{ .max_width_px = 719, .width = .auto, .max_width = .none,
        .box_sizing = .content_box, .line_height = .{ .multiplier = 1.5 } };
    var old_encoder: Encoder = .{ .a = a, .version = .block_containers }; defer old_encoder.deinit();
    try old_encoder.containerScreen(old);
    const old_golden = [_]u8{ 0xcf, 2, 0, 0, 0x0f, 0, 0, 0, 1, 0, 0, 0xc0, 0x3f };
    try std.testing.expectEqualSlices(u8, &old_golden, old_encoder.out.items);
    var extended = old;
    extended.float_side = .none;
    extended.margins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto };
    var encoder: Encoder = .{ .a = a, .version = .block_containers }; defer encoder.deinit();
    try encoder.containerScreen(extended);
    try std.testing.expectEqual(@as(u8, 0x3f), encoder.out.items[4]);
    try std.testing.expectEqualSlices(u8, old_golden[0..4], encoder.out.items[0..4]);
    try std.testing.expectEqualSlices(u8, old_golden[5..], encoder.out.items[5..old_golden.len]);
    var reader: Reader = .{ .a = a, .version = .block_containers, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(extended, try reader.containerScreen());
    try std.testing.expectEqual(encoder.out.items.len, reader.pos);
    for (0..encoder.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .block_containers, .bytes = encoder.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerScreen());
    }
    for ([_][]const u8{
        &.{ 0x7f, 2, 0, 0, 0 },
        &.{ 0x7f, 2, 0, 0, 0x40 },
        &.{ 0x7f, 2, 0, 0, 0x80 },
        &.{ 0x7f, 2, 0, 0, 0x10, 3 },
        &.{ 0x7f, 2, 0, 0, 0x20, 2 },
    }) |bytes| {
        var bad: Reader = .{ .a = a, .version = .block_containers, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad.containerScreen());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime hasLFields(version)) continue;
        var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.containerScreen(extended));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = encoder.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.containerScreen());
    }
}

test "L responsive existing map container preserves full graph auto margins and refusal in both variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const image: types.Span = .{ .image = .{ .file = "Map.svg", .width_px = 1600, .height_px = 800, .tooltip = "mini", .map = .{
        .regions = &.{.{ .shape = .circle, .coordinates = &.{ 100, 200, 50 }, .action = .{ .kind = .internal, .target = "Region", .target_fragment = "part", .label = "region" } }},
        .default_action = .{ .kind = .external, .target = "https://example.org/default", .label = "default" },
        .description = .bottom_right,
    } } };
    var style: types.ContainerStyle = .{ .float_side = .left, .clear = .left,
        .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0.5 }),
        .screen_max_width = .{ .max_width_px = 639, .float_side = .none,
            .margins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto } },
    };
    const children = [_]types.Block{.{ .kind = .paragraph, .spans = &.{image} }};
    var blocks = [_]types.Block{
        .{ .kind = .container, .container = .{ .blocks = &children, .style = style } },
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "After", .text = "following body", .italic = true }} },
    };
    const stored: types.Stored = .{ .entry = .{ .title = "responsive-map", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Body", .blocks = &blocks }},
        .media = &.{.{ .kind = .image, .file = "Map.svg", .caption = "catalog" }},
    } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "responsive-map", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(stored, parsed.value);
    try std.testing.expect(decoded.entry.sections[0].blocks[0].container.?.style.width == null);
    style.screen_max_width.?.margins = null;
    blocks[0].container.?.style = style;
    const adjoining = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(container_fonts_magic, adjoining[0..4]);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, adjoining, "responsive-map", .supplemental, null));
    try std.testing.expectEqualSlices(u8, adjoining, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    try types.validateStored(a, stored, "responsive-map", .supplemental, null);
    var legacy: Encoder = .{ .a = a, .version = .block_containers }; defer legacy.deinit();
    try std.testing.expectError(error.InvalidPresentation, legacy.container(blocks[0].container.?));
    // Neither legacy refusal nor viewport reset deletes logical dimensions,
    // spatial/default/description actions, the strut-owning child, or later body.
    try std.testing.expectEqualDeep(image, blocks[0].container.?.blocks[0].spans[0]);
    try std.testing.expectEqualStrings("After", blocks[1].spans[0].target);
}


test "L overflow auto appends only its field and keeps old absence bytes and version refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit();
    try old.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, old.out.items);
    for ([_]types.ContainerOverflow{ .visible, .auto }, 0..) |overflow, value| {
        var encoder: Encoder = .{ .a = a, .version = .block_containers }; defer encoder.deinit();
        try encoder.containerStyle(.{ .overflow = overflow });
        const expected = [_]u8{ 0, 128, @intCast(value) };
        try std.testing.expectEqualSlices(u8, &expected, encoder.out.items);
        var reader: Reader = .{ .a = a, .version = .block_containers, .bytes = encoder.out.items };
        try std.testing.expectEqualDeep(types.ContainerStyle{ .overflow = overflow }, try reader.containerStyle());
        try std.testing.expectEqual(encoder.out.items.len, reader.pos);
        for (0..encoder.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .block_containers, .bytes = encoder.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
        }
        inline for (comptime std.meta.tags(Version)) |version| {
            if (comptime hasLFields(version)) continue;
            var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
            try std.testing.expectError(error.InvalidPresentation, refused.containerStyle(.{ .overflow = overflow }));
            var old_reader: Reader = .{ .a = a, .version = version, .bytes = encoder.out.items };
            try std.testing.expectError(error.InvalidPresentation, old_reader.containerStyle());
        }
    }
    for ([_][]const u8{ &.{ 0, 128 }, &.{ 0, 128, 2 }, &.{ 0, 128, 255 } }) |bytes| {
        var refused: Reader = .{ .a = a, .version = .block_containers, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, refused.containerStyle());
    }
}

test "L scrolling plain map wrapper retains full image source geometry strut actions and recursive codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
    const image: types.Span = .{ .image = .{ .file = "Map.svg", .width_px = 600, .height_px = 513, .tooltip = "source map", .map = .{
        .regions = &.{.{ .shape = .polygon, .coordinates = &.{ 0, 0, 1401, 0, 700, 1198 }, .action = .{ .kind = .internal, .target = "Region", .target_fragment = "part", .label = "polygon" } }},
        .default_action = .{ .kind = .external, .target = "https://example.org/default", .label = "default" }, .description = .bottom_right,
    } } };
    const inner = [_]types.Block{.{ .kind = .paragraph, .spans = &.{image} }};
    const wrapper: types.Block = .{ .kind = .container, .container = .{ .blocks = &inner, .style = .{
        .float_side = .right, .clear = .right,
        .margins = .{ .top = zero, .right = zero, .bottom = .{ .unit = .em, .value = 0.5 }, .left = .{ .unit = .em, .value = 0.5 } },
        .max_width = .{ .length = .{ .unit = .percent, .value = 100 } }, .overflow = .auto,
        .line_height = .{ .multiplier = 1.625 },
        .screen_max_width = .{ .max_width_px = 639, .float_side = .none,
            .margins = .{ .top = .{ .length = zero }, .right = .auto, .bottom = .{ .length = zero }, .left = .auto } },
    } } };
    const stored: types.Stored = .{ .entry = .{ .title = "scroll-map", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Before", .text = "before" }} },
            wrapper,
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "After", .text = "after", .italic = true }} },
        } }}, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{wrapper} }},
        .media = &.{.{ .kind = .image, .file = "Map.svg", .caption = "independent catalog" }},
    } };
    try types.validateStored(a, stored, "scroll-map", .supplemental, null);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "scroll-map", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(stored, parsed.value);
    const actual = decoded.entry.sections[0].blocks[1].container.?;
    try std.testing.expect(actual.style.width == null and actual.style.overflow.? == .auto);
    try std.testing.expectEqualDeep(image, actual.blocks[0].spans[0]);
    try std.testing.expectEqual(@as(usize, 1), actual.blocks.len);
}


test "L ordered screen rules preserve old prefix append clear and flat bounds with strict grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: types.ContainerScreenMaxWidth = .{ .max_width_px = 719, .width = .auto, .max_width = .none,
        .box_sizing = .content_box, .line_height = .{ .multiplier = 1.5 } };
    const golden = [_]u8{ 0xcf, 2, 0, 0, 0x0f, 0, 0, 0, 1, 0, 0, 0xc0, 0x3f };
    var old_encoder: Encoder = .{ .a = a, .version = .block_containers }; defer old_encoder.deinit();
    try old_encoder.containerScreen(old);
    try std.testing.expectEqualSlices(u8, &golden, old_encoder.out.items);
    var extended = old; extended.clear = .right;
    extended.following_rules = &.{
        .{ .max_width_px = 639, .float_side = .none, .clear = .both },
        .{ .max_width_px = 319, .clear = .none, .width = .{ .length = .{ .unit = .px, .value = 0 } } },
    };
    var encoded: Encoder = .{ .a = a, .version = .block_containers }; defer encoded.deinit();
    try encoded.containerScreen(extended);
    try std.testing.expectEqual(@as(u8, 0xcf), encoded.out.items[4]);
    try std.testing.expectEqualSlices(u8, golden[0..4], encoded.out.items[0..4]);
    try std.testing.expectEqualSlices(u8, golden[5..], encoded.out.items[5..golden.len]);
    try std.testing.expectEqual(@as(u8, 2), encoded.out.items[golden.len]); // existing FigureClear.right
    var reader: Reader = .{ .a = a, .version = .block_containers, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(extended, try reader.containerScreen());
    try std.testing.expectEqual(encoded.out.items.len, reader.pos);
    for (0..encoded.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .block_containers, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerScreen());
    }
    // Old private readers reject the newly assigned c0 bits. Old negatives
    // without their now-required payload remain meaningful truncation refusals.
    for ([_][]const u8{
        &.{ 0xcf, 2, 0, 0, 0x40, 0xff }, // closed clear enum
        &.{ 0xcf, 2, 0, 0, 0x81, 0, 0, 0, 0, 0 }, // explicit empty following count
        &.{ 0xcf, 2, 0, 0, 0x81, 0, 16, 0, 0, 0 }, // count exceeds cap before allocation
        &.{ 0xcf, 2, 0, 0, 0x81, 0, 1, 0, 0, 0, 0xcf, 2, 0, 0, 0x40, 3 }, // duplicate bound
        &.{ 0xcf, 2, 0, 0, 0x81, 0, 1, 0, 0, 0, 0xd0, 2, 0, 0, 0x40, 3 }, // increasing bound
        &.{ 0xcf, 2, 0, 0, 0x81, 0, 1, 0, 0, 0, 0x7f, 2, 0, 0, 0xc0, 3 }, // nested following-list bit
    }) |bytes| {
        var invalid: Reader = .{ .a = a, .version = .block_containers, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, invalid.containerScreen());
    }
    var duplicate = extended; duplicate.following_rules = &.{.{ .max_width_px = 719, .clear = .both }};
    var invalid_encoder: Encoder = .{ .a = a, .version = .block_containers }; defer invalid_encoder.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid_encoder.containerScreen(duplicate));
    // Complete payload, so the bounded count refusal is not a truncated-data
    // premise. Every child has an otherwise valid descending bound and field.
    var over_budget: Encoder = .{ .a = a, .version = .block_containers }; defer over_budget.deinit();
    try over_budget.containerScreenPrefix(old, true);
    try over_budget.count(types.max_container_screen_rules);
    for (0..types.max_container_screen_rules) |index| try over_budget.containerScreenPrefix(.{
        .max_width_px = @intCast(700 - index), .clear = .none,
    }, false);
    var over_reader: Reader = .{ .a = a, .version = .block_containers, .bytes = over_budget.out.items };
    try std.testing.expectError(error.InvalidPresentation, over_reader.containerScreen());
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime hasLFields(version)) continue;
        var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.containerScreen(extended));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = encoded.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.containerScreen());
    }
}

test "L ordered viewport map owners retain complete Stored build JSON lexical paths media and every band" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
    const image: types.Span = .{ .image = .{ .file = "Map.svg", .width_px = 600, .height_px = 513, .map = .{
        .regions = &.{.{ .shape = .polygon, .coordinates = &.{ 0, 0, 1401, 0, 700, 1198 }, .action = .{ .kind = .internal, .target = "Region", .target_fragment = "part", .label = "polygon" } }},
        .default_action = .{ .kind = .external, .target = "https://example.org/default", .label = "default" }, .description = .bottom_right,
    } } };
    const style: types.ContainerStyle = .{ .float_side = .right, .clear = .right, .layout = .flex_row, .align_items = .center,
        .width = .{ .length = .{ .unit = .px, .value = 250 } }, .padding = types.StyleEdges.all(.{ .unit = .px, .value = 4 }),
        .background = .{ .rgb = "#f8f9fa" }, .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .rgb = "#a2a9b1" } } },
        .line_height = .{ .multiplier = 1.625 }, .overflow = .auto,
        .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } },
            .max_width = .{ .length = .{ .unit = .percent, .value = 100 } }, .box_sizing = .border_box, .line_height = .{ .multiplier = 1.5 },
            .following_rules = &.{.{ .max_width_px = 639, .float_side = .none, .clear = .both,
                .margins = .{ .top = .{ .length = zero }, .right = .auto, .bottom = .{ .length = zero }, .left = .auto } }} },
    };
    const inner: types.Block = .{ .kind = .container, .container = .{ .style = .{ .width = .fit_content }, .blocks = &.{
        .{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &.{.{ .kind = .link, .target = "Meaning", .text = "whole sense", .bold = true }} },
        .{ .kind = .paragraph, .spans = &.{image} },
    } } };
    const wrapper: types.Block = .{ .kind = .container, .container = .{ .style = style, .blocks = &.{inner} } };
    const stored: types.Stored = .{ .entry = .{ .title = "ordered-responsive", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "before", .target = "Before" }} }, wrapper,
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "after", .target = "After", .italic = true }} },
        } }}, .organization = .{ .lexemes = &.{.{ .kind = "Noun", .section = 0, .definitions = &.{.{ .block = 1, .block_path = &.{ 0, 0 } }} }} },
        .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{wrapper} }},
        .media = &.{.{ .kind = .image, .file = "Map.svg", .caption = "independent catalog" }},
    } };
    try types.validateStored(a, stored, "ordered-responsive", .supplemental, null);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "ordered-responsive", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(stored, parsed.value);
    const actual = decoded.entry.sections[0].blocks[1].container.?;
    try std.testing.expectEqualDeep(style, actual.style);
    const leaf = types.resolveBlockPath(decoded.entry.sections[0].blocks, 1, &.{ 0, 0 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Meaning", leaf.spans[0].target);
    try std.testing.expectEqualDeep(image, actual.blocks[0].container.?.blocks[1].spans[0]);
    for ([_]f64{ 720, 719, 640, 639.5, 639, 360 }) |viewport| {
        try std.testing.expectEqualDeep(try types.resolveContainerScreen(style, viewport), try types.resolveContainerScreen(actual.style, viewport));
    }
    // This controlled zero-vertical-margin source does not waive the actual
    // VI adjoining-margin case when its real .5em bottom edge is retained.
    var refused = wrapper; refused.container.?.style.margins = types.StyleEdges.all(.{ .unit = .em, .value = 0.5 });
    refused.container.?.style.screen_max_width.?.following_rules = &.{.{ .max_width_px = 639, .float_side = .none, .clear = .both }};
    var invalid: Encoder = .{ .a = a, .version = .block_containers }; defer invalid.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid.block(refused));
}


test "M owner font style has explicit width mask strict scalar grammar and old version refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit();
    try old.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, old.out.items);
    for ([_]f32{ 0, 0.9, 1, 2 }) |scale| {
        const style: types.ContainerStyle = .{ .owner_font_scale = scale, .line_height = .{ .multiplier = 1.5 } };
        var next: Encoder = .{ .a = a, .version = .container_fonts }; defer next.deinit();
        try next.containerStyle(style);
        try std.testing.expectEqual(@as(u32, 0x11000), std.mem.readInt(u32, next.out.items[0..4], .little));
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = next.out.items };
        try std.testing.expectEqualDeep(style, try reader.containerStyle());
        try std.testing.expectEqual(next.out.items.len, reader.pos);
        for (0..next.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = next.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
        }
        inline for (comptime std.meta.tags(Version)) |version| {
            if (comptime version == .container_fonts) continue;
            var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
            try std.testing.expectError(error.InvalidPresentation, refused.containerStyle(style));
        }
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        var refused: Encoder = .{ .a = a, .version = .container_fonts }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.containerStyle(.{ .owner_font_scale = bad }));
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], container_owner_font_flag, .little);
        std.mem.writeInt(u32, bytes[4..8], @bitCast(bad), .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
    for ([_]u32{ 0x800000, 0x80000000 }) |flags| {
        var bytes: [4]u8 = undefined; std.mem.writeInt(u32, &bytes, flags, .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
}

test "M conditional selection walks every real owner sink and retains full Stored build JSON and actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const child: types.Block = .{ .kind = .paragraph, .spans = &.{
        .{ .kind = .link, .target = "Target", .target_fragment = "part", .text = "large", .font_scale = 1.8, .font_scale_basis = .normal_body, .bold = true },
        .{ .text = " small", .font_scale = 0.45, .font_scale_basis = .normal_body },
    } };
    const boxed = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .owner_font_scale = 0.9, .line_height = .{ .multiplier = 1.5 } }, .blocks = &.{child} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxed;
    const table: types.Table = .{ .caption_blocks = &boxed, .rows = &.{.{ .cells = &.{.{ .blocks = &boxed }} }} };
    const entries = [_]types.Entry{
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxed }} },
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "empty", .blocks = &.{.{ .kind = .container, .container = .{ .style = .{ .owner_font_scale = 0 }, .blocks = &.{} } }} }} },
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested table", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } }} }} },
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "owner-font", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxed }} },
        .{ .title = "owner-font", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &boxed } }} }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        // N is a supported capability; keep unknown versions distinct from malformed framing.
        const unknown = try a.dupe(u8, bytes); unknown[3] = 0;
        try std.testing.expectError(error.UnsupportedPresentationVersion, decodeAlloc(a, unknown, entry.title, .supplemental, null));
        const malformed = try a.dupe(u8, bytes); malformed[0] = 0;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, malformed, entry.title, .supplemental, null));
    }
}

test "M absent owner font preserves L framing and prior low style payload byte identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const style: types.ContainerStyle = .{ .width = .{ .length = .{ .unit = .px, .value = 65 } },
        .line_height = .{ .multiplier = 1.5 }, .overflow = .visible,
        .screen_max_width = .{ .max_width_px = 719, .width = .auto, .following_rules = &.{.{ .max_width_px = 639, .clear = .none }} } };
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.containerStyle(style);
    var wide: Encoder = .{ .a = a, .version = .container_fonts }; defer wide.deinit(); try wide.containerStyle(style);
    try std.testing.expectEqualSlices(u8, old.out.items[0..2], wide.out.items[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, wide.out.items[2..4]);
    try std.testing.expectEqualSlices(u8, old.out.items[2..], wide.out.items[4..]);
    const stored: types.Stored = .{ .entry = .{ .title = "legacy-container", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .container, .container = .{ .style = style, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Kept", .text = "kept" }} }} } }} }} } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(block_containers_magic, bytes[0..4]);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
}


test "M cell minimum appends after legacy style and rejects old versions reserved units and truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const legacy: types.CellStyle = .{ .text_align = .left, .padding = types.StyleEdges.all(.{ .unit = .px, .value = 2 }) };
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.cellStyle(legacy);
    var same: Encoder = .{ .a = a, .version = .container_fonts }; defer same.deinit(); try same.cellStyle(legacy);
    try std.testing.expectEqualSlices(u8, old.out.items, same.out.items);
    for ([_]types.StyleLength{ .{ .unit = .px, .value = 0 }, .{ .unit = .em, .value = 30 }, .{ .unit = .px, .value = 65 } }) |minimum| {
        var style = legacy; style.min_width = minimum;
        var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit(); try encoded.cellStyle(style);
        try std.testing.expectEqual(@as(u8, 0x46), encoded.out.items[1]);
        try std.testing.expectEqualSlices(u8, old.out.items[2..], encoded.out.items[2..old.out.items.len]);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
        try std.testing.expectEqualDeep(@as(?types.CellStyle, style), try reader.cellStyle());
        try std.testing.expectEqual(encoded.out.items.len, reader.pos);
        for (0..encoded.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.cellStyle());
        }
        inline for (comptime std.meta.tags(Version)) |version| {
            if (comptime version == .container_fonts) continue;
            var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
            try std.testing.expectError(error.InvalidPresentation, refused.cellStyle(style));
            var reader_old: Reader = .{ .a = a, .version = version, .bytes = encoded.out.items };
            try std.testing.expectError(error.InvalidPresentation, reader_old.cellStyle());
        }
    }
    for ([_][]const u8{ &.{ 1, 0x80 }, &.{ 1, 0x08 }, &.{ 1, 0x40, 255, 0, 0, 0, 0 } }) |bytes| {
        var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad.cellStyle());
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.cellStyle(.{ .min_width = .{ .unit = .px, .value = bad } }));
        var bytes: [7]u8 = .{ 1, 0x40, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, bytes[3..7], @bitCast(bad), .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.cellStyle());
    }
}

test "M cell minimum selects recursively without owner font and retains grids actions Figure JSON and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const grid: types.Table = .{ .caption = &.{.{ .text = "kept caption" }}, .rows = &.{
        .{ .cells = &.{.{ .header = true, .colspan = 3, .style = .{ .text_align = .left, .min_width = .{ .unit = .em, .value = 30 } },
            .spans = &.{.{ .kind = .link, .target = "Header", .text = "whole header" }} }} },
        .{ .cells = &.{ .{ .spans = &.{.{ .kind = .link, .target = "A", .text = "a" }} }, .{ .spans = &.{.{ .kind = .link, .target = "B", .text = "b" }} }, .{ .spans = &.{.{ .kind = .link, .target = "C", .text = "c" }} } } },
    } };
    const boxed = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .table, .table = grid }} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxed;
    const entries = [_]types.Entry{
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &.{.{ .kind = .table, .table = grid }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = grid }} }} } }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxed }} }} } }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "minimum", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxed }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
}

test "M static poster tag2 keeps ordinary image framing and rejects old versions and malformed tails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.InlineImage = .{ .file = "X.stl", .width_px = 4, .height_px = 3,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "3D", .file_sha1 = "832cafd6c58519ddd441e8f7fc7d78eb14165a2e", .file_timestamp = "2020-07-25T07:26:20Z" } };
    var current: Encoder = .{ .a = a, .version = .container_fonts }; defer current.deinit();
    try current.inlineImage(image);
    const bytes = current.out.items;
    try std.testing.expectEqualSlices(u8, &.{ 2, 5, 0, 0, 0, 'X', '.', 's', 't', 'l', 3,
        4, 0, 0, 0, 3, 0, 0, 0, 0, 2, 0, 0, 0, '3', 'D' }, bytes[0..26]);
    try std.testing.expectEqualSlices(u8, "\x28\x00\x00\x00" ++ "832cafd6c58519ddd441e8f7fc7d78eb14165a2e" ++ "\x14\x00\x00\x00" ++ "2020-07-25T07:26:20Z", bytes[26..]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
    try std.testing.expectEqualDeep(image, (try reader.inlineImage()).?);
    try std.testing.expectEqual(bytes.len, reader.pos);
    for (0..bytes.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.inlineImage());
    }
    for ([_]Version{ .plain, .image_maps, .inline_table_styles, .block_containers }) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.inlineImage(image));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, old_reader.inlineImage());
        try std.testing.expectEqual(@as(usize, 1), old_reader.pos);
    }
    var old_m_presence: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
    try std.testing.expectError(error.InvalidPresentation, old_m_presence.presence());
    const bad = try a.dupe(u8, bytes);
    bad[19] = 1;
    var unknown_policy: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, unknown_policy.inlineImage());
    bad[19] = 0; bad[0] = 3;
    var unknown_tag: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, unknown_tag.inlineImage());
    bad[0] = 2; bad[30] = 'g';
    var invalid_identity: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, invalid_identity.inlineImage());
    bad[30] = bytes[30]; bad[15] = 4;
    var wrong_ratio: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, wrong_ratio.inlineImage());
}

test "M static poster absence leaves J K L M image tag0 tag1 bytes exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const plain: types.InlineImage = .{ .file = "X.stl", .width_px = 4, .height_px = 3 };
    const expected = [_]u8{ 0, 1, 5, 0, 0, 0, 'X', '.', 's', 't', 'l', 3, 4, 0, 0, 0, 3, 0, 0, 0 };
    for ([_]Version{ .image_maps, .inline_table_styles, .block_containers, .container_fonts }) |version| {
        var encoder: Encoder = .{ .a = a, .version = version }; defer encoder.deinit();
        try encoder.inlineImage(null); try encoder.inlineImage(plain);
        try std.testing.expectEqualSlices(u8, &expected, encoder.out.items);
        var reader: Reader = .{ .a = a, .version = version, .bytes = encoder.out.items };
        try std.testing.expect((try reader.inlineImage()) == null);
        try std.testing.expectEqualDeep(plain, (try reader.inlineImage()).?);
        try std.testing.expectEqual(expected.len, reader.pos);
    }
}

test "M static poster recursive sinks preserve full Stored build codec JSON owners actions and captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const poster: types.Span = .{ .kind = .link, .target = "File:Model.stl", .target_fragment = "", .tooltip = "action advice",
        .image = .{ .file = "Model.stl", .width_px = 250, .height_px = 188, .alt = "model alternative", .tooltip = "image advice", .border = true,
            .static_poster = .{ .policy = .three_d_stl_v1, .label = "Mod\xc3\xa8le 3D", .file_sha1 = "832cafd6c58519ddd441e8f7fc7d78eb14165a2e", .file_timestamp = "2020-07-25T07:26:20Z" } } };
    var ordinary = poster; ordinary.image.?.static_poster = null;
    const body = [_]types.Block{.{ .kind = .paragraph, .spans = &.{poster} }};
    var figure = FigureCodecFixture.make(poster);
    figure.caption = &.{.{ .kind = .link, .text = "authored caption", .target = "CaptionTarget", .italic = true }};
    var caption_figure = FigureCodecFixture.make(ordinary); caption_figure.caption = &.{poster};
    var block_caption_figure = FigureCodecFixture.make(ordinary); block_caption_figure.caption_blocks = &body;
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{poster} }} }} };
    const table_caption: types.Table = .{ .caption = &.{poster}, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "cell" }} }} }} };
    const table_block_caption: types.Table = .{ .caption_blocks = &body, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "cell" }} }} }} };
    const table_blocks: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &body }} }} };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    const cases = [_]types.Entry{
        .{ .title = "poster", .kind = .supplemental, .display_title = &.{poster} },
        .{ .title = "poster", .kind = .supplemental, .preamble_spans = &.{poster} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Spans", .blocks = &body }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Caption", .blocks = &.{.{ .kind = .paragraph, .figure = caption_figure }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Caption blocks", .blocks = &.{.{ .kind = .paragraph, .figure = block_caption_figure }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Table caption", .blocks = &.{.{ .kind = .table, .table = table_caption }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Table caption blocks", .blocks = &.{.{ .kind = .table, .table = table_block_caption }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Table cell blocks", .blocks = &.{.{ .kind = .table, .table = table_blocks }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Container", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &body, .style = .{} } }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .@"inline", .spans = &.{poster} }} }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Scope", .blocks = &.{.{ .kind = .paragraph,
            .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .@"inline", .spans = &.{poster} }} } }} }} }} },
        .{ .title = "poster", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow figure", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .figure, .figure = figure }} }} }} },
        .{ .title = "poster", .kind = .supplemental, .references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .spans = &.{poster} }} },
        .{ .title = "poster", .kind = .supplemental, .references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .blocks = &body }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .file = "Model.stl", .kind = .image, .caption = "model" }};
        try std.testing.expect(hasStaticPosters(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        try types.validateStored(a, stored, "poster", .supplemental, null);
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "poster", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        if (entry.preamble_spans.len == 0) try std.testing.expectEqualSlices(u8, bytes,
            try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
}


test "M fixed height mask payload scalar truncation and reserved bits remain strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]types.StyleLength{ .{ .unit = .px, .value = 0 }, .{ .unit = .px, .value = 24 }, .{ .unit = .em, .value = 1.44 } }) |height| {
        const style: types.ContainerStyle = .{ .height = height };
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.containerStyle(style);
        try std.testing.expectEqual(@as(u32, 0x20000), std.mem.readInt(u32, encoder.out.items[0..4], .little));
        try std.testing.expectEqual(@as(usize, 9), encoder.out.items.len);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
        try std.testing.expectEqualDeep(style, try reader.containerStyle());
        try std.testing.expectEqual(encoder.out.items.len, reader.pos);
        for (0..encoder.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
        }
        const unit = try a.dupe(u8, encoder.out.items); unit[4] = 255;
        var bad_unit: Reader = .{ .a = a, .version = .container_fonts, .bytes = unit };
        try std.testing.expectError(error.InvalidPresentation, bad_unit.containerStyle());
        inline for (comptime std.meta.tags(Version)) |version| {
            if (comptime version == .container_fonts) continue;
            var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
            try std.testing.expectError(error.InvalidPresentation, old.containerStyle(style));
        }
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.containerStyle(.{ .height = .{ .unit = .em, .value = bad } }));
        var bytes: [9]u8 = undefined; std.mem.writeInt(u32, bytes[0..4], container_height_flag, .little); bytes[4] = 0;
        std.mem.writeInt(u32, bytes[5..9], @bitCast(bad), .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
    for ([_]u32{ 0x800000, 0x80000000 }) |flags| {
        var bytes: [4]u8 = undefined; std.mem.writeInt(u32, &bytes, flags, .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
    const absent: types.ContainerStyle = .{ .owner_font_scale = 0.9, .line_height = .{ .multiplier = 1.5 } };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.containerStyle(absent);
    try std.testing.expectEqual(@as(u32, 0x11000), std.mem.readInt(u32, encoder.out.items[0..4], .little));
    // This original M payload is unchanged when height is absent.
    try std.testing.expectEqual(@as(usize, 13), encoder.out.items.len);
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, old.out.items);
}

test "M fixed height conditional recursive Stored build JSON retains complete body actions and media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const child: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Overflow", .target_fragment = "kept", .text = "visible beyond fixed box", .font_scale = 2, .font_scale_basis = .normal_body, .bold = true }} };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .height = .{ .unit = .px, .value = 0 } }, .blocks = &.{child} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const table: types.Table = .{ .caption_blocks = &boxes, .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} };
    const entries = [_]types.Entry{
        .{ .title = "fixed-height", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxes }} },
        .{ .title = "fixed-height", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "fixed-height", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "fixed-height", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "fixed-height", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxes }} },
        .{ .title = "fixed-height", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &boxes } }} }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry }; const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        const old = try a.dupe(u8, bytes); old[3] = 'L';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
    }
}


test "M count columns payload versions absent bytes and strict scalar framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]u16{ 1, 2, 65535 }) |count| for ([_]types.StyleLength{ .{ .unit = .px, .value = 0 }, .{ .unit = .em, .value = 0.95 } }) |gap| {
        const style: types.ContainerStyle = .{ .columns = .{ .count = count, .gap = gap } };
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.containerStyle(style);
        try std.testing.expectEqual(container_columns_flag, std.mem.readInt(u32, encoder.out.items[0..4], .little));
        try std.testing.expectEqual(@as(usize, 11), encoder.out.items.len);
        try std.testing.expectEqual(count, std.mem.readInt(u16, encoder.out.items[4..6], .little));
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
        try std.testing.expectEqualDeep(style, try reader.containerStyle()); try std.testing.expectEqual(encoder.out.items.len, reader.pos);
        for (0..encoder.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
        }
        const zero = try a.dupe(u8, encoder.out.items); @memset(zero[4..6], 0);
        var zero_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = zero };
        try std.testing.expectError(error.InvalidPresentation, zero_reader.containerStyle());
        const unit = try a.dupe(u8, encoder.out.items); unit[6] = 255;
        var bad_unit: Reader = .{ .a = a, .version = .container_fonts, .bytes = unit };
        try std.testing.expectError(error.InvalidPresentation, bad_unit.containerStyle());
        inline for (comptime std.meta.tags(Version)) |version| {
            if (comptime version == .container_fonts) continue;
            var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
            try std.testing.expectError(error.InvalidPresentation, old.containerStyle(style));
        }
    };
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.containerStyle(.{ .columns = .{ .count = 2, .gap = .{ .unit = .em, .value = bad } } }));
        var bytes: [11]u8 = undefined; std.mem.writeInt(u32, bytes[0..4], container_columns_flag, .little); std.mem.writeInt(u16, bytes[4..6], 2, .little); bytes[6] = 0;
        std.mem.writeInt(u32, bytes[7..11], @bitCast(bad), .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
    for ([_]u32{ 0x800000, 0x80000000 }) |flags| {
        var bytes: [4]u8 = undefined; std.mem.writeInt(u32, &bytes, flags, .little);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.containerStyle());
    }
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, old.out.items);
    var absent: Encoder = .{ .a = a, .version = .container_fonts }; defer absent.deinit(); try absent.containerStyle(.{ .height = .{ .unit = .px, .value = 0 } });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 2, 0, 0, 0, 0, 0, 0 }, absent.out.items);
}

test "M count columns recursive Stored build and JSON preserve full ordered graph actions and body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const child: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Complete", .target_fragment = "kept", .text = "full ordered text", .font_scale = 1.9, .font_scale_basis = .normal_body, .bold = true }} };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .columns = .{ .count = 2, .gap = .{ .unit = .em, .value = 0.95 } }, .owner_font_scale = 0.95 }, .blocks = &.{child} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const table: types.Table = .{ .caption_blocks = &boxes, .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} };
    const entries = [_]types.Entry{
        .{ .title = "columns", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxes }} },
        .{ .title = "columns", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "columns", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "columns", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "columns", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxes }} },
        .{ .title = "columns", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &boxes } }} }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry }; const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        const old = try a.dupe(u8, bytes); old[3] = 'L';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
    }
}


test "M relative auto tail enum truncation absent bytes and older versions remain strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const style: types.ContainerStyle = .{ .positioning = .relative_auto };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.containerStyle(style);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 8, 0, 0 }, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(style, try reader.containerStyle()); try std.testing.expectEqual(encoder.out.items.len, reader.pos);
    for (0..encoder.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
    }
    for ([_]u8{ 1, 255 }) |tag| {
        const bad = try a.dupe(u8, encoder.out.items); bad[4] = tag;
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, invalid.containerStyle());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.containerStyle(style));
    }
    for ([_]u32{ 0x800000, 0x80000000 }) |flag| {
        var bytes: [4]u8 = undefined; std.mem.writeInt(u32, &bytes, flag, .little);
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, invalid.containerStyle());
    }
    var absent: Encoder = .{ .a = a, .version = .container_fonts }; defer absent.deinit();
    try absent.containerStyle(.{ .height = .{ .unit = .px, .value = 0 } });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 2, 0, 0, 0, 0, 0, 0 }, absent.out.items);
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, old.out.items);
    var full: Encoder = .{ .a = a, .version = .container_fonts }; defer full.deinit();
    try full.containerStyle(.{ .height = .{ .unit = .px, .value = 0 }, .positioning = .relative_auto });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 10, 0, 0, 0, 0, 0, 0, 0 }, full.out.items);
}

test "M relative auto recursive Stored build and JSON retain original geometry body actions and media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const child: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Kept", .target_fragment = "part", .text = "header body", .font_scale = 0.95, .font_scale_basis = .normal_body, .bold = true }} };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .height = .{ .unit = .em, .value = 1.52 }, .owner_font_scale = 0.95, .positioning = .relative_auto }, .blocks = &.{child} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const table: types.Table = .{ .caption_blocks = &boxes, .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} };
    const entries = [_]types.Entry{
        .{ .title = "relative", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxes }} },
        .{ .title = "relative", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "relative", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "relative", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "relative", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxes }} },
        .{ .title = "relative", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &boxes } }} }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry }; const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded); try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit(); try std.testing.expectEqualDeep(stored, parsed.value);
        const old = try a.dupe(u8, bytes); old[3] = 'L';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
    }
}


test "M minimum height keeps explicit zero tail strict scalars and old absent container bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const style: types.ContainerStyle = .{ .min_height = .{ .unit = .px, .value = 0 } };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.containerStyle(style);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 16, 0, 0, 0, 0, 0, 0 }, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(style, try reader.containerStyle()); try std.testing.expectEqual(encoder.out.items.len, reader.pos);
    for (0..encoder.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
    }
    const bad_unit = try a.dupe(u8, encoder.out.items); bad_unit[4] = 255;
    var bad_unit_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad_unit };
    try std.testing.expectError(error.InvalidPresentation, bad_unit_reader.containerStyle());
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        var invalid: Encoder = .{ .a = a, .version = .container_fonts }; defer invalid.deinit();
        try std.testing.expectError(error.InvalidPresentation, invalid.containerStyle(.{ .min_height = .{ .unit = .px, .value = bad } }));
        const bytes = try a.dupe(u8, encoder.out.items); std.mem.writeInt(u32, bytes[5..9], @bitCast(bad), .little);
        var invalid_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, invalid_reader.containerStyle());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.containerStyle(style));
    }
    var absent: Encoder = .{ .a = a, .version = .container_fonts }; defer absent.deinit(); try absent.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, absent.out.items);
    var legacy: Encoder = .{ .a = a, .version = .block_containers }; defer legacy.deinit(); try legacy.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, legacy.out.items);
    for ([_]u32{ 0x800000, 0x80000000 }) |flag| {
        var bytes: [4]u8 = undefined; std.mem.writeInt(u32, &bytes, flag, .little);
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, invalid.containerStyle());
    }
}

test "M physical border edge framing preserves legacy none solid bytes and strictly refuses unsupported tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const value: types.StyleBorder = .{ .edges = types.StyleBorderEdges.all(.none) };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.styleBorder(value);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0 }, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(value, try reader.styleBorder()); try std.testing.expectEqual(encoder.out.items.len, reader.pos);
    for (0..encoder.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.styleBorder());
    }
    for ([_]u8{ 4, 255 }) |tag| {
        const bytes = try a.dupe(u8, encoder.out.items); bytes[1] = tag;
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, invalid.styleBorder());
    }
    var bad_outer: Reader = .{ .a = a, .version = .container_fonts, .bytes = &.{3} };
    try std.testing.expectError(error.InvalidPresentation, bad_outer.styleBorder());
    for ([_]Version{ .image_maps, .inline_table_styles, .block_containers }) |version| {
        for ([_]types.StyleBorder{ .none, .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } } }) |old_value| {
            var old: Encoder = .{ .a = a, .version = version }; defer old.deinit(); try old.styleBorder(old_value);
            var current: Encoder = .{ .a = a, .version = .container_fonts }; defer current.deinit(); try current.styleBorder(old_value);
            try std.testing.expectEqualSlices(u8, old.out.items, current.out.items);
        }
    }
    for ([_]types.ContainerBorder{ .none, .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .rgb = "#aaaaaa" } } } }) |old_value| {
        var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.containerBorder(old_value);
        var current: Encoder = .{ .a = a, .version = .container_fonts }; defer current.deinit(); try current.containerBorder(old_value);
        try std.testing.expectEqualSlices(u8, old.out.items, current.out.items);
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.styleBorder(value));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = encoder.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.styleBorder());
        var old_container: Encoder = .{ .a = a, .version = version }; defer old_container.deinit();
        try std.testing.expectError(error.InvalidPresentation, old_container.containerBorder(.{ .edges = types.ContainerBorderEdges.all(.hidden) }));
    }
    var hidden: Encoder = .{ .a = a, .version = .container_fonts }; defer hidden.deinit();
    try hidden.containerBorder(.{ .edges = types.ContainerBorderEdges.all(.hidden) });
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 1, 1, 1 }, hidden.out.items);
    var hidden_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = hidden.out.items };
    try std.testing.expectEqualDeep(types.ContainerBorder{ .edges = types.ContainerBorderEdges.all(.hidden) }, try hidden_reader.containerBorder());
    for (0..hidden.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = hidden.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerBorder());
    }
    var bad_color: Encoder = .{ .a = a, .version = .container_fonts }; defer bad_color.deinit();
    try bad_color.byte(2); try bad_color.byte(3); try bad_color.styleLength(.{ .unit = .px, .value = 1 }); try bad_color.string("red"); try bad_color.out.appendSlice(a, &.{ 0, 0, 0 });
    var invalid_color: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad_color.out.items };
    try std.testing.expectError(error.InvalidPresentation, invalid_color.styleBorder());
}

test "M minimum and dotted edge borders retain complete recursive Stored build JSON body and actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const edge: types.StyleBorderEdge = .{ .dotted = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } };
    const edges: types.StyleBorderEdges = .{ .top = edge, .right = .none, .bottom = edge, .left = .hidden };
    const container_edges: types.ContainerBorderEdges = .{ .top = .{ .dotted = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .rgb = "#aaaaaa" } } }, .right = .none, .bottom = .{ .dotted = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .rgb = "#aaaaaa" } } }, .left = .hidden };
    const child: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Complete#kept", .text = "complete body", .font_scale = 2, .font_scale_basis = .normal_body, .bold = true }} };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .min_height = .{ .unit = .em, .value = 1.52 }, .owner_font_scale = 0.95, .border = .{ .edges = container_edges } }, .blocks = &.{child} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const cell_edge_table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .style = .{ .border = .{ .edges = edges } }, .spans = child.spans }} }} };
    const table_edge_table: types.Table = .{ .style = .{ .border = .{ .edges = edges }, .collapse = .collapse }, .rows = &.{.{ .cells = &.{.{ .spans = child.spans }} }} };
    const entries = [_]types.Entry{
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxes }} },
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table border", .blocks = &.{.{ .kind = .table, .table = table_edge_table }} }} },
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell border", .blocks = &.{.{ .kind = .table, .table = cell_edge_table }} }} },
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table caption", .blocks = &.{.{ .kind = .table, .table = .{ .caption_blocks = &boxes, .rows = &.{.{ .cells = &.{.{ .spans = child.spans }} }} } }} }} },
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell blocks", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} },
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "minimum edges", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "minimum edges", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxes }} },
        .{ .title = "minimum edges", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table_edge_table }} }} } }} }} },
    };
    for (entries, 0..) |entry, index| {
        errdefer std.debug.print("MINIMUM_EDGE_RECURSION member={d}\n", .{index});
        const stored: types.Stored = .{ .entry = entry }; const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{}); const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        for ([_]u8{ 'J', 'K', 'L' }) |old_header| {
            const old = try a.dupe(u8, bytes); old[3] = old_header;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
        }
    }
    const absent: types.Stored = .{ .entry = .{ .title = "old absent", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &.{child} } }} }} } };
    const old_bytes = try encodeAlloc(a, absent); try std.testing.expectEqualStrings(block_containers_magic, old_bytes[0..4]);
    try std.testing.expectEqualDeep(absent, try decodeAlloc(a, old_bytes, absent.entry.title, .supplemental, null));
}

test "M signed Container margin scalars preserve old bytes and strict nonmargin and legacy admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const negative: types.StyleLength = .{ .unit = .em, .value = -0.5 };
    var raw: Encoder = .{ .a = a, .version = .container_fonts }; defer raw.deinit();
    try raw.containerMarginLength(negative);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0xbf }, raw.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(negative, try reader.containerMarginLength());
    try std.testing.expectEqual(raw.out.items.len, reader.pos);
    for (0..raw.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerMarginLength());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.containerMarginLength(negative));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = raw.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.containerMarginLength());
    }
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        var invalid: Encoder = .{ .a = a, .version = .container_fonts }; defer invalid.deinit();
        try std.testing.expectError(error.InvalidPresentation, invalid.containerMarginLength(.{ .unit = .px, .value = bad }));
        var bytes: [5]u8 = .{ 0, 0, 0, 0, 0 }; std.mem.writeInt(u32, bytes[1..5], @bitCast(bad), .little);
        var bad_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, bad_reader.containerMarginLength());
    }
    var invalid_unit: Reader = .{ .a = a, .version = .container_fonts, .bytes = &.{ 255, 0, 0, 0, 0 } };
    try std.testing.expectError(error.InvalidPresentation, invalid_unit.containerMarginLength());
    var nonmargin: Encoder = .{ .a = a, .version = .container_fonts }; defer nonmargin.deinit();
    try std.testing.expectError(error.InvalidPresentation, nonmargin.styleLength(negative));
    try std.testing.expectError(error.InvalidPresentation, nonmargin.containerStyle(.{ .padding = types.StyleEdges.all(negative) }));
    const positive: types.ContainerStyle = .{ .margins = types.StyleEdges.all(.{ .unit = .px, .value = 2 }), .float_side = .left };
    var l: Encoder = .{ .a = a, .version = .block_containers }; defer l.deinit(); try l.containerStyle(positive);
    var m: Encoder = .{ .a = a, .version = .container_fonts }; defer m.deinit(); try m.containerStyle(positive);
    try std.testing.expectEqualSlices(u8, l.out.items[0..2], m.out.items[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, m.out.items[2..4]);
    try std.testing.expectEqualSlices(u8, l.out.items[2..], m.out.items[4..]);
    const box: types.Container = .{ .style = .{ .margins = types.StyleEdges.all(.{ .unit = .px, .value = 2 }) },
        .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "full body" }} }} };
    var old_full: Encoder = .{ .a = a, .version = .block_containers }; defer old_full.deinit();
    try std.testing.expectError(error.InvalidPresentation, old_full.container(box));
    try std.testing.expectEqual(@as(usize, 0), old_full.out.items.len);
    // Construct the unsupported old-wire shape explicitly to exercise the
    // decoder's compatibility gate, without weakening the full encoder guard.
    var invalid_l: Encoder = .{ .a = a, .version = .block_containers }; defer invalid_l.deinit();
    try invalid_l.containerStyle(box.style); try invalid_l.blocks(box.blocks);
    var read_l: Reader = .{ .a = a, .version = .block_containers, .bytes = invalid_l.out.items };
    try std.testing.expectError(error.InvalidPresentation, read_l.container());
    var current: Encoder = .{ .a = a, .version = .container_fonts }; defer current.deinit(); try current.container(box);
    var read_m: Reader = .{ .a = a, .version = .container_fonts, .bytes = current.out.items };
    try std.testing.expectEqualDeep(box, try read_m.container());
}

test "M signed and adjoining margin selection visits recursive complete Stored build and JSON owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const body: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "Complete#kept", .text = "complete body", .font_scale = 1.8, .font_scale_basis = .normal_body, .bold = true }} };
    var margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }); margins.bottom = .{ .unit = .em, .value = -0.5 };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .margins = margins }, .blocks = &.{body} } }};
    var positive_child = body; positive_child.style = .{ .margins = types.StyleEdges.all(.{ .unit = .px, .value = 2 }) };
    const positive_boxes = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{positive_child} } }};
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const screen_boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = .{ .screen_max_width = .{ .max_width_px = 719, .width = .auto,
        .following_rules = &.{.{ .max_width_px = 639, .margins = .{ .top = zero, .right = zero, .bottom = .{ .length = .{ .unit = .em, .value = -0.5 } }, .left = .auto } }} } }, .blocks = &.{body} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const entries = [_]types.Entry{
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &boxes }} },
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "positive child", .blocks = &positive_boxes }} },
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "ordered screen", .blocks = &screen_boxes }} },
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table caption", .blocks = &.{.{ .kind = .table, .table = .{ .caption_blocks = &boxes, .rows = &.{.{ .cells = &.{.{ .spans = body.spans }} }} } }} }} },
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell blocks", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} },
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "signed margin", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "signed margin", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxes }} },
        .{ .title = "signed margin", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} } }} }} },
    };
    for (entries, 0..) |entry, index| {
        errdefer std.debug.print("SIGNED_MARGIN_RECURSION member={d}\n", .{index});
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        for ([_]u8{ 'J', 'K', 'L' }) |header| {
            const old = try a.dupe(u8, bytes); old[3] = header;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
        }
    }
}


test "M cell top alignment appends strict distinct solver policy and preserves absent old bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prior: types.CellStyle = .{ .text_align = .left, .padding = types.StyleEdges.all(.{ .unit = .em, .value = 1.2 }) };
    var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit(); try old.cellStyle(prior);
    var same: Encoder = .{ .a = a, .version = .container_fonts }; defer same.deinit(); try same.cellStyle(prior);
    try std.testing.expectEqualSlices(u8, old.out.items, same.out.items);
    var value = prior; value.vertical_align = .top;
    var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit(); try encoded.cellStyle(value);
    try std.testing.expectEqual(@as(u8, 0x86), encoded.out.items[1]);
    try std.testing.expectEqualSlices(u8, same.out.items[2..], encoded.out.items[2..same.out.items.len]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, value), try reader.cellStyle());
    for (0..encoded.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.cellStyle());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.cellStyle(value));
        var before: Reader = .{ .a = a, .version = version, .bytes = encoded.out.items };
        try std.testing.expectError(error.InvalidPresentation, before.cellStyle());
    }
    for ([_][]const u8{ &.{1, 0x80}, &.{1, 0x80, 2}, &.{1, 0x80, 255}, &.{1, 0x10, 0} }) |bytes| {
        var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad.cellStyle());
    }
}

test "M cell top selects recursively without owner font and retains grids actions Figure JSON and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const grid: types.Table = .{ .caption = &.{.{ .text = "kept caption" }}, .rows = &.{
        .{ .cells = &.{.{ .header = true, .colspan = 3, .style = .{ .text_align = .left, .vertical_align = .top },
            .spans = &.{.{ .kind = .link, .target = "Header", .text = "whole header" }} }} },
        .{ .cells = &.{ .{ .spans = &.{.{ .kind = .link, .target = "A", .text = "a" }} }, .{ .spans = &.{.{ .kind = .link, .target = "B", .text = "b" }} }, .{ .spans = &.{.{ .kind = .link, .target = "C", .text = "c" }} } } },
    } };
    const boxed = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .table, .table = grid }} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxed;
    const entries = [_]types.Entry{
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &.{.{ .kind = .table, .table = grid }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = grid }} }} } }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxed }} }} } }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "minimum", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "minimum", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxed }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
}

test "M list inline image and top preserve full body media actions and reject old wire capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.Span = .{ .classes = "wikidict-media wikidict-media-file-4c6f7564737065616b65722e737667", .image = .{ .file = "Loudspeaker.svg", .width_px = 32, .alt = "speaker" } };
    const audio: types.Span = .{ .kind = .link, .text = "voice", .target = "File:Voice.ogg", .classes = "wikidict-media wikidict-media-file-566f6963652e6f6767" };
    const table: types.Table = .{ .style = .{ .display = .inline_block, .vertical_align = .top, .line_height = .{ .value = 1 } }, .rows = &.{.{ .cells = &.{ .{ .spans = &.{image, .{ .text = " Hoa Kỳ" }} }, .{ .spans = &.{audio} } } }} };
    const blocks = [_]types.Block{.{ .kind = .list_item, .list_path = "*", .depth = 1, .table = table }};
    const stored: types.Stored = .{ .entry = .{ .title = "speaker", .kind = .supplemental, .media = &.{ .{ .kind = .image, .file = "Loudspeaker.svg", .caption = "speaker" }, .{ .kind = .audio, .file = "Voice.ogg", .caption = "voice" } }, .sections = &.{.{ .level = 2, .title = "body", .blocks = &blocks }} } };
    try types.validateStored(a, stored, stored.entry.title, .supplemental, null);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
    try std.testing.expectEqualDeep(stored, parsed.value);
    for ([_]Version{ .tooltips, .image_maps, .inline_table_styles, .block_containers }) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.table(@as(?types.Table, table)));
        old.out.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidPresentation, old.tableStyle(table.style));
        const changed = try a.dupe(u8, bytes); @memcpy(changed[0..4], versionMagic(version));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, changed, stored.entry.title, .supplemental, null));
    }
    // Images independently require M even when external alignment stays legacy.
    var image_only = table; image_only.style.?.vertical_align = .middle;
    var m: Encoder = .{ .a = a, .version = .container_fonts }; defer m.deinit();
    var catalog = try types.ImageCatalogIndex.init(a, stored.entry.media); defer catalog.deinit(a); m.inline_media_catalog = &catalog;
    try m.table(@as(?types.Table, image_only));
    const image_sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = image_only }} }};
    var image_stored = stored; image_stored.entry.sections = &image_sections;
    try std.testing.expectEqualStrings(container_fonts_magic, (try encodeAlloc(a, image_stored))[0..4]);
    // Top independently requires M on an otherwise old text-only table.
    const text_table: types.Table = .{ .style = .{ .display = .inline_table, .vertical_align = .top }, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "body", .target = "Target" }} }} }} };
    const text_sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = text_table }} }};
    const text_stored: types.Stored = .{ .entry = .{ .title = "top", .kind = .supplemental, .sections = &text_sections } };
    const top_bytes = try encodeAlloc(a, text_stored);
    try std.testing.expectEqualStrings(container_fonts_magic, top_bytes[0..4]);
    try std.testing.expectEqualDeep(text_stored, try decodeAlloc(a, top_bytes, "top", .supplemental, null));
    for (0..bytes.len) |end| try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0..end], stored.entry.title, .supplemental, null));
    var bad = stored; bad.entry.media = stored.entry.media[1..];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, bad));
    bad.entry.media = &.{stored.entry.media[0], stored.entry.media[0], stored.entry.media[1]};
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, bad));
}

test "M inline top enum is strict while legacy middle table bytes remain K" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const top: types.TableStyle = .{ .display = .inline_block, .vertical_align = .top };
    var m: Encoder = .{ .a = a, .version = .container_fonts }; defer m.deinit(); try m.tableStyle(top);
    try std.testing.expectEqual(@as(u8, 2), m.out.items[m.out.items.len - 1]);
    for ([_]u8{3, 255}) |unknown| {
        const changed = try a.dupe(u8, m.out.items); changed[changed.len - 1] = unknown;
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = changed };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    for ([_]Version{.inline_table_styles, .block_containers}) |version| {
        var reader: Reader = .{ .a = a, .version = version, .bytes = m.out.items };
        try std.testing.expectError(error.InvalidPresentation, reader.tableStyle());
    }
    const table: types.Table = .{ .style = .{ .display = .inline_block, .vertical_align = .middle }, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "unchanged" }} }} }} };
    const stored: types.Stored = .{ .entry = .{ .title = "legacy", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = table }} }} } };
    const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(inline_table_styles_magic, bytes[0..4]);
    var k: Encoder = .{ .a = a, .version = .inline_table_styles }; defer k.deinit();
    try k.out.appendSlice(a, inline_table_styles_magic); try k.spans(stored.entry.display_title); try k.sections(stored.entry.sections);
    try k.spans(stored.entry.preamble_spans); try k.layout(stored.entry.organization); try k.references(stored.entry.references); try k.media(stored.entry.media);
    try std.testing.expectEqualSlices(u8, k.out.items, bytes);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null));
}

test "M preferred cell width reuses strict width tail and preserves every absent legacy byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prior: types.CellStyle = .{ .min_width = .{ .unit = .px, .value = 3 }, .vertical_align = .top };
    var absent: Encoder = .{ .a = a, .version = .container_fonts }; defer absent.deinit(); try absent.cellStyle(prior);
    const old_m = [_]u8{1, 0xc0, 0, 0, 0, 64, 64, 0};
    try std.testing.expectEqualSlices(u8, &old_m, absent.out.items);
    var style = prior; style.width = .{ .unit = .percent, .value = 48 };
    var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit(); try encoded.cellStyle(style);
    // Existing width0x20 payload precedes minimum0x40 and top0x80.
    const width_min_top = [_]u8{1, 0xe0, 2, 0, 0, 64, 66, 0, 0, 0, 64, 64, 0};
    try std.testing.expectEqualSlices(u8, &width_min_top, encoded.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, style), try reader.cellStyle());
    try std.testing.expectEqual(encoded.out.items.len, reader.pos);
    for (0..encoded.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.cellStyle());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.cellStyle(.{ .width = .{ .unit = .percent, .value = 48 } }));
        var before: Reader = .{ .a = a, .version = version, .bytes = &width_min_top };
        try std.testing.expectError(error.InvalidPresentation, before.cellStyle());
    }
    for ([_]Version{.reference_blocks, .image_maps, .inline_table_styles, .block_containers, .container_fonts}) |version| {
        var unchanged: Encoder = .{ .a = a, .version = version }; defer unchanged.deinit(); try unchanged.cellStyle(.{ .text_align = .left });
        try std.testing.expectEqualSlices(u8, &[_]u8{1, 4, 0}, unchanged.out.items);
    }
    for ([_][]const u8{ &.{1, 0}, &.{1, 0x20}, &.{1, 0x20, 3, 0, 0, 0, 0}, &.{1, 0x28, 2, 0, 0, 64, 66}, &.{1, 0x30, 2, 0, 0, 64, 66} }) |bytes| {
        var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad.cellStyle());
    }
    for ([_]f32{-1, std.math.nan(f32), std.math.inf(f32)}) |number| {
        var bad_encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer bad_encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, bad_encoder.cellStyle(.{ .width = .{ .unit = .percent, .value = number } }));
        var bytes = [_]u8{1, 0x20, 2, 0, 0, 0, 0}; std.mem.writeInt(u32, bytes[3..7], @bitCast(number), .little);
        var bad_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, bad_reader.cellStyle());
    }
    for ([_]types.StyleWidth{ .{ .unit = .px, .value = 0 }, .{ .unit = .em, .value = 1.35 }, .{ .unit = .percent, .value = 0 }, .{ .unit = .percent, .value = 150 } }) |width| {
        var raw: Encoder = .{ .a = a, .version = .container_fonts }; defer raw.deinit(); try raw.cellStyle(.{ .width = width });
        var parsed: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items };
        try std.testing.expectEqualDeep(@as(?types.CellStyle, .{ .width = width }), try parsed.cellStyle());
    }
}

test "M preferred cell widths select every recursive owner and retain complete grids actions min top and JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const grid: types.Table = .{ .style = .{ .width = .{ .unit = .percent, .value = 100 } }, .caption = &.{.{ .text = "complete caption" }}, .rows = &.{
        .{ .cells = &.{.{ .header = true, .colspan = 2, .style = .{ .width = .{ .unit = .percent, .value = 48 }, .min_width = .{ .unit = .px, .value = 60 }, .vertical_align = .top }, .spans = &.{.{ .kind = .link, .target = "Header", .text = "whole header" }} }} },
        .{ .cells = &.{ .{ .style = .{ .width = .{ .unit = .percent, .value = 20 } }, .spans = &.{.{ .kind = .link, .target = "A", .target_fragment = "kept", .text = "left" }} }, .{ .style = .{ .width = .{ .unit = .em, .value = 1.35 } }, .spans = &.{.{ .kind = .external_link, .target = "https://example.test/full", .text = "right" }} } } },
    } };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .table, .table = grid }} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const entries = [_]types.Entry{
        .{ .title = "cell widths", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &.{.{ .kind = .table, .table = grid }} }} },
        .{ .title = "cell widths", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = grid }} }} } }} }} },
        .{ .title = "cell widths", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} },
        .{ .title = "cell widths", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Container", .blocks = &boxes }} },
        .{ .title = "cell widths", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "cell widths", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .rtl, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "cell widths", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &boxes }} },
    };
    for (entries, 0..) |entry, index| {
        errdefer std.debug.print("CELL_WIDTH_RECURSION member={d}\n", .{index});
        const stored: types.Stored = .{ .entry = entry }; try types.validateStored(a, stored, entry.title, .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{}); const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        for ([_]u8{'H', 'J', 'K', 'L'}) |header| {
            const old = try a.dupe(u8, bytes); old[3] = header;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
        }
    }
    // Width alone, including zero, must select M without minimum/top/Container.
    for ([_]f32{0, 48, 150}) |amount| {
        const only: types.Stored = .{ .entry = .{ .title = "only width", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .style = .{ .width = .{ .unit = .percent, .value = amount } }, .spans = &.{.{ .text = "kept" }} }} }} } }} }} } };
        const bytes = try encodeAlloc(a, only); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        try std.testing.expectEqualDeep(only, try decodeAlloc(a, bytes, only.entry.title, .supplemental, null));
    }
}

test "local automatic scrollports preserve old L bytes absence and full M child ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const styles = [_]types.ContainerStyle{ .{}, .{ .overflow = .visible }, .{ .overflow = .auto } };
    const golden = [_][]const u8{ &.{0, 0}, &.{0, 128, 0}, &.{0, 128, 1} };
    for (styles, golden) |style, expected| {
        var old: Encoder = .{ .a = a, .version = .block_containers }; defer old.deinit();
        try old.containerStyle(style); try std.testing.expectEqualSlices(u8, expected, old.out.items);
        var reader: Reader = .{ .a = a, .version = .block_containers, .bytes = old.out.items };
        try std.testing.expectEqualDeep(style, try reader.containerStyle());
        var modern: Encoder = .{ .a = a, .version = .container_fonts }; defer modern.deinit();
        try modern.containerStyle(style);
        const expected_m: []const u8 = if (style.overflow) |overflow| if (overflow == .auto) &.{0, 128, 0, 0, 1} else &.{0, 128, 0, 0, 0} else &.{0, 0, 0, 0};
        try std.testing.expectEqualSlices(u8, expected_m, modern.out.items);
        const stored: types.Stored = .{ .entry = .{ .title = "old scroll owner", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .container, .container = .{ .style = style, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "complete old body", .target = "Kept" }} }} } }} }} } };
        const bytes = try encodeAlloc(a, stored);
        // Existing auto alone still uses L. This capability adds no M-only bit.
        try std.testing.expectEqual(@as(u8, 'L'), bytes[3]);
        try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null));
    }
    const grid: types.Table = .{ .style = .{ .width = .{ .unit = .percent, .value = 100 } }, .rows = &.{.{ .cells = &.{
        .{ .style = .{ .width = .{ .unit = .percent, .value = 48 } }, .spans = &.{.{ .kind = .link, .text = "whole left", .target = "Left", .target_fragment = "kept" }} },
        .{ .style = .{ .width = .{ .unit = .percent, .value = 1 } } },
        .{ .style = .{ .width = .{ .unit = .percent, .value = 48 } }, .spans = &.{.{ .kind = .external_link, .text = "whole right", .target = "https://example.test/full" }} },
    } }} };
    const box: types.Block = .{ .kind = .container, .container = .{ .style = .{ .overflow = .auto, .width = .auto, .margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) }, .blocks = &.{.{ .kind = .table, .table = grid }} } };
    const stored: types.Stored = .{ .entry = .{ .title = "scroll and preferred grid", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{ box, .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "following", .target = "After" }} } } }},
        .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{box} }} } };
    try types.validateStored(a, stored, stored.entry.title, .supplemental, null);
    const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{}); const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(stored, parsed.value);
    for ([_]u8{'H', 'J', 'K', 'L'}) |header| {
        const old = try a.dupe(u8, bytes); old[3] = header;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, stored.entry.title, .supplemental, null));
    }
}

test "M base auto margin tail is exclusive strict and leaves old absent bytes unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const style: types.ContainerStyle = .{ .margin_values = .{ .top = zero, .right = .auto, .bottom = .{ .length = .{ .unit = .em, .value = -0.5 } }, .left = .auto } };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.containerStyle(style);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 32, 0 }, encoder.out.items[0..4]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(style, try reader.containerStyle()); try std.testing.expectEqual(encoder.out.items.len, reader.pos);
    for (0..encoder.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.containerStyle());
    }
    const bad = try a.dupe(u8, encoder.out.items); bad[4] = 2;
    var bad_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, bad_reader.containerStyle());
    var both = style; both.margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 });
    var invalid: Encoder = .{ .a = a, .version = .container_fonts }; defer invalid.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid.containerStyle(both));
    // Independently construct two valid payloads behind an invalid combined
    // flag word, so decode exclusivity is exercised beyond encoder rejection.
    var numeric: Encoder = .{ .a = a, .version = .container_fonts }; defer numeric.deinit();
    try numeric.containerStyle(.{ .margins = both.margins });
    var collision: std.ArrayList(u8) = .empty; defer collision.deinit(a);
    try collision.appendSlice(a, &.{ 1, 0, 32, 0 });
    try collision.appendSlice(a, numeric.out.items[4..]); try collision.appendSlice(a, encoder.out.items[4..]);
    var collision_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = collision.items };
    try std.testing.expectError(error.InvalidPresentation, collision_reader.containerStyle());
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.containerStyle(style));
    }
    var absent: Encoder = .{ .a = a, .version = .container_fonts }; defer absent.deinit(); try absent.containerStyle(.{});
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, absent.out.items);
    var legacy: Encoder = .{ .a = a, .version = .block_containers }; defer legacy.deinit(); try legacy.containerStyle(.{ .margins = both.margins });
    try std.testing.expectEqualSlices(u8, legacy.out.items[0..2], numeric.out.items[0..2]);
    try std.testing.expectEqualSlices(u8, legacy.out.items[2..], numeric.out.items[4..]);
    var unknown: Reader = .{ .a = a, .version = .container_fonts, .bytes = &.{ 0, 0, 64, 0 } };
    try std.testing.expectError(error.InvalidPresentation, unknown.containerStyle());
}

test "base auto margins select M through full recursive Stored build and JSON paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const style: types.ContainerStyle = .{ .margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto }, .background = .{ .rgb = "#dcdcdc" } };
    const child: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .target = "kept#anchor", .text = "complete", .font_scale = 1.2, .font_scale_basis = .normal_body }} };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .style = style, .blocks = &.{child} } }};
    const entries = [_]types.Entry{
        .{ .title = "auto", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "ordinary", .blocks = &boxes }} },
        .{ .title = "auto", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} },
        .{ .title = "auto", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &boxes }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        for ([_]u8{ 'J', 'K', 'L' }) |header| {
            const old = try a.dupe(u8, bytes); old[3] = header;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
        }
    }
}


const TableCaptionCodecTest = struct {
    fn media() types.FigureMediaLayout {
        return .{ .strut = .{ .font_scale = 1, .direction = .ltr }, .vertical_align = .middle };
    }
    fn richMedia() types.FigureMediaLayout {
        return .{ .strut = .{ .font_scale = 1.25, .bold = true, .italic = true, .code = true, .language = "de", .direction = .rtl },
            .vertical_align = .middle, .max_width = .{ .percent = 100, .subtract = .{ .unit = .px, .value = 8 } },
            .positioning = .relative_auto,
            .after = .{ .width = .{ .unit = .px, .value = 15 }, .height = .{ .unit = .px, .value = 11 },
                .side = .left, .inset = .{ .unit = .px, .value = 6 }, .bottom = .{ .unit = .px, .value = -11 },
                .paint = .{ .graphic = .magnify_clip_rtl_v1, .invert = true } },
            .focus_outline = .{ .width = .{ .unit = .px, .value = 2 }, .color = .{ .kind = .rgb, .value = "#3366cc" },
                .radius = .{ .unit = .px, .value = 2 }, .offset = .{ .unit = .px, .value = 0 } } };
    }
    fn minimal() types.TableCaptionLayout {
        return .{ .collapse = .collapse, .wrapper = .{}, .table_border = types.FigureBorderEdges.all(.none), .caption_border = types.FigureBorderEdges.all(.none), .media = media() };
    }
    fn rich() types.TableCaptionLayout {
        const line: types.FigureBorderEdge = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .kind = .rgb, .value = "#a2a9b1" } } };
        var table = types.FigureBorderEdges.all(line); table.bottom = .none;
        var caption = types.FigureBorderEdges.all(line); caption.top = .none;
        var margin = types.StyleEdges.all(.{ .unit = .px, .value = 0 }); margin.left.value = 3;
        return .{ .collapse = .collapse, .wrapper = .{ .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0.5 }), .float_side = .right, .clear = .right }, .table_border = table, .caption_border = caption,
            .media = richMedia(),
            .caption_before = .{ .width = .{ .length = .{ .unit = .px, .value = 15 } }, .height = .{ .unit = .px, .value = 11 },
                .float_side = .right, .margins = margin, .border = .none, .background = .transparent } };
    }
};

test "M Figure table caption tags retain legacy image Missing bytes and close old capability tails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 190 } });
    var missing = MissingFigureCodecTest.make(); missing.frame_border = .{ .kind = .none };
    for ([_]types.Figure{image, missing}) |base| {
        var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
        try old.figure(@as(?types.Figure, base));
        try std.testing.expectEqual(if (base.content == .missing) @as(u8, 2) else 1, old.out.items[0]);
        var figure = base; figure.table_caption_layout = TableCaptionCodecTest.minimal();
        if (figure.content == .missing) figure.table_caption_layout.?.media.vertical_align = .baseline;
        var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit();
        try encoded.figure(@as(?types.Figure, figure));
        try std.testing.expectEqual(if (base.content == .missing) @as(u8, 6) else 5, encoded.out.items[0]);
        try std.testing.expectEqualSlices(u8, old.out.items[1..], encoded.out.items[1..old.out.items.len]);
        var golden = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 63, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        if (base.content == .missing) golden[23] = 0;
        try std.testing.expectEqualSlices(u8, &golden, encoded.out.items[old.out.items.len..]);
        var decoded: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
        try std.testing.expectEqualDeep(figure, (try decoded.figure()).?);
        try std.testing.expectEqual(encoded.out.items.len, decoded.pos);
        for ([_]Version{ .image_maps, .inline_table_styles, .block_containers }) |version| {
            var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
            try std.testing.expectError(error.InvalidPresentation, refused.figure(@as(?types.Figure, figure)));
            var reader: Reader = .{ .a = a, .version = version, .bytes = encoded.out.items };
            try std.testing.expectError(error.InvalidPresentation, reader.figure());
        }
        for (0..encoded.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.figure());
        }
        for ([_]u8{ 3, 4, 7, 127, 255 }) |tag| {
            const bad = try a.dupe(u8, encoded.out.items); bad[0] = tag;
            var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
            try std.testing.expectError(error.InvalidPresentation, reader.figure());
        }
        const separate = try a.dupe(u8, encoded.out.items); separate[old.out.items.len] = 0;
        var separate_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = separate };
        try std.testing.expectError(error.InvalidPresentation, separate_reader.figure());
        const unknown_edge = try a.dupe(u8, encoded.out.items); unknown_edge[old.out.items.len + 5] = 4;
        var edge_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = unknown_edge };
        try std.testing.expectError(error.InvalidPresentation, edge_reader.figure());
    }
    var capped_missing = missing; capped_missing.table_caption_layout = TableCaptionCodecTest.minimal();
    capped_missing.table_caption_layout.?.media.vertical_align = .baseline;
    capped_missing.table_caption_layout.?.media.max_width = .{ .percent = 100, .subtract = .{ .unit = .px, .value = 8 } };
    try std.testing.expect(!types.validFigure(capped_missing));
    var invalid: Encoder = .{ .a = a, .version = .container_fonts }; defer invalid.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid.figure(@as(?types.Figure, capped_missing)));
}

test "M Figure table caption layout independently selects full recursive Stored build JSON body media actions and states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Figure.svg", .image = .{ .file = "Figure.svg", .width_px = 190, .height_px = 248, .alt = "source image" } });
    figure.table_caption_layout = TableCaptionCodecTest.rich();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    var narrow = figure.table_caption_layout.?.media; narrow.after.?.paint = null;
    const states = [_]types.FigureViewportState{.{ .max_width_px = 639, .media = narrow,
        .wrapper = .{ .margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto }, .clear = .none }, .caption_before = null }};
    figure.table_caption_layout.?.viewport_states = &states;
    const caption = [_]types.Block{.{ .kind = .paragraph, .spans = &.{ .{ .text = "[1] Elmar " }, .{ .kind = .link, .text = "Mai", .target = "Mai", .italic = true }, .{ .text = ", Biologe" } } }};
    figure.caption_blocks = &caption;
    const direct = [_]types.Block{.{ .kind = .paragraph, .figure = figure }};
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &direct }} }} };
    const outer: types.Table = .{ .caption_blocks = &direct, .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    var parent = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 100 } });
    parent.caption_blocks = &direct;
    const cases = [_]types.Entry{
        .{ .title = "caption", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "direct", .blocks = &direct }} },
        .{ .title = "caption", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = outer }} }} },
        .{ .title = "caption", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "caption", .blocks = &.{.{ .kind = .paragraph, .figure = parent }} }} },
        .{ .title = "caption", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &direct }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "source media" }};
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, stored, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        for ([_]Version{ .image_maps, .inline_table_styles, .block_containers }) |version| {
            const old = try a.dupe(u8, bytes); @memcpy(old[0..4], versionMagic(version));
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
        }
    }
    // Layout presence independently selects M without before boxes, viewport
    // state, caption Containers, SVG language or any other new M feature.
    figure.table_caption_layout = TableCaptionCodecTest.minimal();
    figure.caption_blocks = null; figure.caption = &.{.{ .text = "kept" }};
    const minimal_sections = [_]types.Section{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }};
    const minimal: types.Stored = .{ .entry = .{ .title = "minimal", .kind = .supplemental, .sections = &minimal_sections,
        .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "source media" }} } };
    try std.testing.expectEqualStrings(container_fonts_magic, (try encodeAlloc(a, minimal))[0..4]);
}

test "M Figure table caption bounded state edge and scalar tails reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var value = TableCaptionCodecTest.rich();
    value.caption_border.left = .hidden;
    value.caption_border.right = .{ .dotted = .{ .width = .{ .unit = .em, .value = 0.125 }, .color = .{ .kind = .transparent } } };
    var raw: Encoder = .{ .a = a, .version = .container_fonts }; defer raw.deinit();
    try raw.tableCaptionLayout(value);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(value, try reader.tableCaptionLayout());
    try std.testing.expectEqual(raw.out.items.len, reader.pos);
    for (0..raw.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.tableCaptionLayout());
    }
    for ([_][]const u8{ &.{4}, &.{ 2, 0, 0, 0, 0x80, 0x7f, 0 }, &.{ 2, 0, 0, 0, 0x80, 0x3f, 3 } }) |bytes| {
        var bad_edge: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad_edge.figureBorderEdge());
    }
    var invalid = value; invalid.media.max_width.?.percent = std.math.nan(f32);
    try std.testing.expectError(error.InvalidPresentation, raw.tableCaptionLayout(invalid));
    invalid = value; invalid.caption_before.?.height.?.value = -1;
    try std.testing.expectError(error.InvalidPresentation, raw.tableCaptionLayout(invalid));
    const duplicate = [_]types.FigureViewportState{ .{ .max_width_px = 639, .wrapper = .{}, .media = TableCaptionCodecTest.media() }, .{ .max_width_px = 639, .wrapper = .{}, .media = TableCaptionCodecTest.media() } };
    invalid = value; invalid.viewport_states = &duplicate;
    try std.testing.expectError(error.InvalidPresentation, raw.tableCaptionLayout(invalid));
    var too_many: [types.max_figure_viewport_states + 1]types.FigureViewportState = undefined;
    for (&too_many, 0..) |*state, index| state.* = .{ .max_width_px = @intCast(1000 - index), .wrapper = .{}, .media = TableCaptionCodecTest.media() };
    invalid = value; invalid.viewport_states = &too_many;
    try std.testing.expectError(error.InvalidPresentation, raw.tableCaptionLayout(invalid));
}


test "M Figure complete media exact strut relative graphic focus wire rejects every unrepresented tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const media = TableCaptionCodecTest.richMedia();
    var raw: Encoder = .{ .a = a, .version = .container_fonts }; defer raw.deinit();
    try raw.figureMediaLayout(media);
    const golden = [_]u8{ 0, 0, 160, 63, 7, 2, 0, 0, 0, 100, 101, 1, 1, 1, 0, 0, 200, 66, 0, 0, 0, 0, 65, 1, 0, 1, 0, 0, 0, 112, 65, 0, 0, 0, 48, 65, 0, 0, 0, 0, 192, 64, 0, 0, 0, 48, 193, 1, 1, 1, 1, 0, 0, 0, 0, 64, 2, 7, 0, 0, 0, 35, 51, 51, 54, 54, 99, 99, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &golden, raw.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(media, try reader.figureMediaLayout());
    try std.testing.expectEqual(raw.out.items.len, reader.pos);
    for (0..raw.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.figureMediaLayout());
    }
    // Independent minimum encoding: scale1, empty language, ltr/middle, no optionals.
    var minimal: Encoder = .{ .a = a, .version = .container_fonts }; defer minimal.deinit();
    try minimal.figureMediaLayout(TableCaptionCodecTest.media());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 63, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, minimal.out.items);
    const Mutation = struct { index: usize, byte: u8 };
    for ([_]Mutation{ .{ .index = 4, .byte = 8 }, .{ .index = 9, .byte = 2 }, .{ .index = 10, .byte = 2 },
        .{ .index = 11, .byte = 2 }, .{ .index = 12, .byte = 2 }, .{ .index = 13, .byte = 2 }, .{ .index = 14, .byte = 2 } }) |mutation| {
        const bad = try a.dupe(u8, minimal.out.items); bad[mutation.index] = mutation.byte;
        var refused: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, refused.figureMediaLayout());
    }
    const bad_scale = try a.dupe(u8, minimal.out.items); @memcpy(bad_scale[0..4], &[_]u8{ 0, 0, 128, 127 });
    var scale_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad_scale };
    try std.testing.expectError(error.InvalidPresentation, scale_reader.figureMediaLayout());
    const bad_utf8 = try a.dupe(u8, raw.out.items); bad_utf8[9] = 255;
    var utf8_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad_utf8 };
    try std.testing.expectError(error.InvalidPresentation, utf8_reader.figureMediaLayout());
    // Known rich field offsets are independently fixed by the literal above.
    for ([_]Mutation{ .{ .index = 24, .byte = 1 }, .{ .index = 36, .byte = 2 },
        .{ .index = 48, .byte = 2 }, .{ .index = 49, .byte = 2 }, .{ .index = 50, .byte = 2 } }) |mutation| {
        const bad = try a.dupe(u8, raw.out.items); bad[mutation.index] = mutation.byte;
        var refused: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, refused.figureMediaLayout());
    }
}


test "M Figure positioned File action excludes map ownership without changing legacy valid maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Figure.svg", .image = .{ .file = "Figure.svg", .width_px = 190 } });
    const layout = TableCaptionCodecTest.rich();
    figure.table_caption_layout = layout;
    var good: Encoder = .{ .a = a, .version = .container_fonts }; defer good.deinit();
    try good.figure(@as(?types.Figure, figure));
    for ([_]bool{ false, true }) |map_case| {
        var bad = figure;
        if (map_case) bad.content.image.span.image.?.map = .{ .regions = &.{} }
        else { bad.content.image.span.kind = .text; bad.content.image.span.target = ""; }
        try std.testing.expect(!types.validFigure(bad));
        var refused: Encoder = .{ .a = a, .version = .container_fonts }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.figure(@as(?types.Figure, bad)));
        bad.table_caption_layout = null;
        try std.testing.expect(types.validFigure(bad));
        var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
        try old.figure(@as(?types.Figure, bad));
        var legacy: Reader = .{ .a = a, .version = .container_fonts, .bytes = old.out.items };
        try std.testing.expectEqualDeep(bad, (try legacy.figure()).?);
        // A forged current tag/tail still goes through content-aware validation.
        old.out.items[0] = 5;
        try old.tableCaptionLayout(layout);
        var forged: Reader = .{ .a = a, .version = .container_fonts, .bytes = old.out.items };
        try std.testing.expectError(error.InvalidPresentation, forged.figure());
    }
}


const FigureLinkPaintCodecTest = struct {
    fn paint() types.FigureLinkPaint {
        return .{ .normal = .{ .foreground = "#000001", .underline = true }, .hover = .{ .foreground = "#000002", .underline = false },
            .active = .{ .foreground = "#000003", .underline = true }, .visited = .{ .foreground = "#000004", .underline = false },
            .visited_hover = .{ .foreground = "#000005", .underline = true }, .visited_active = .{ .foreground = "#000006", .underline = false },
            .underline_on_focus = true };
    }
    fn missing() types.Figure {
        var figure = MissingFigureCodecTest.make(); figure.frame_border = .{ .kind = .none };
        figure.content.missing.link_paint = null; figure.content.missing.label.foreground = "#000001";
        figure.table_caption_layout = TableCaptionCodecTest.minimal(); figure.table_caption_layout.?.media.vertical_align = .baseline;
        figure.table_caption_layout.?.missing_link_paint = paint(); figure.table_caption_layout.?.caption_link_paint = paint();
        return figure;
    }
};

test "M Figure fixed source link paint literal six state mask and strict nullable tails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const paint = FigureLinkPaintCodecTest.paint();
    var raw: Encoder = .{ .a = a, .version = .container_fonts }; defer raw.deinit(); try raw.figureLinkPaint(paint);
    const golden = [_]u8{ 1, 7, 0, 0, 0, 35, 48, 48, 48, 48, 48, 49, 7, 0, 0, 0, 35, 48, 48, 48, 48, 48, 50, 7, 0, 0, 0, 35, 48, 48, 48, 48, 48, 51, 7, 0, 0, 0, 35, 48, 48, 48, 48, 48, 52, 7, 0, 0, 0, 35, 48, 48, 48, 48, 48, 53, 7, 0, 0, 0, 35, 48, 48, 48, 48, 48, 54, 85, 0 };
    try std.testing.expectEqualSlices(u8, &golden, raw.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(paint, (try reader.figureLinkPaint()).?); try std.testing.expectEqual(raw.out.items.len, reader.pos);
    for (0..raw.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.figureLinkPaint());
    }
    const Mutation = struct { index: usize, value: u8 };
    for ([_]Mutation{ .{ .index = 0, .value = 2 }, .{ .index = 6, .value = 'G' }, .{ .index = 67, .value = 128 }, .{ .index = 68, .value = 2 } }) |mutation| {
        const bad = try a.dupe(u8, raw.out.items); bad[mutation.index] = mutation.value;
        var refused: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, refused.figureLinkPaint());
    }
    for ([_]Version{ .image_maps, .inline_table_styles, .block_containers }) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.figureLinkPaint(paint));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = raw.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.figureLinkPaint());
    }
    var native_color = paint; native_color.focus_outline = .{ .width = .{ .unit = .px, .value = 2 }, .color = .{ .kind = .native_theme },
        .radius = .{ .unit = .px, .value = 2 }, .offset = .{ .unit = .px, .value = 0 } };
    try std.testing.expectError(error.InvalidPresentation, raw.figureLinkPaint(native_color));
    var focus: Encoder = .{ .a = a, .version = .container_fonts }; defer focus.deinit();
    try focus.figureFocusOutline(native_color.focus_outline);
    const forged = try a.alloc(u8, golden.len - 1 + focus.out.items.len);
    @memcpy(forged[0..golden.len - 1], golden[0..golden.len - 1]); @memcpy(forged[golden.len - 1..], focus.out.items);
    var rejected_focus: Reader = .{ .a = a, .version = .container_fonts, .bytes = forged };
    try std.testing.expectError(error.InvalidPresentation, rejected_focus.figureLinkPaint());
}

test "M Figure fixed label caption policy keeps full recursive Stored build JSON and independent legacy absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = FigureLinkPaintCodecTest.missing();
    var paint = FigureLinkPaintCodecTest.paint(); paint.focus_outline = .{ .width = .{ .unit = .px, .value = 2 },
        .color = .{ .kind = .rgb, .value = "#3366cc" }, .radius = .{ .unit = .px, .value = 2 }, .offset = .{ .unit = .px, .value = -3 } };
    figure.table_caption_layout.?.caption_link_paint = paint;
    const caption = [_]types.Block{.{ .kind = .paragraph, .spans = &.{.{ .kind = .external_link, .text = "one", .target = "https://example.invalid/one", .foreground = "#000001", .italic = true },
        .{ .text = " / " }, .{ .kind = .link, .text = "two", .target = "Two", .target_fragment = "Section", .underline = true, .language = "th" }} }};
    figure.caption = &.{}; figure.caption_blocks = &caption;
    const direct = [_]types.Block{.{ .kind = .paragraph, .figure = figure }};
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &direct }} }} };
    var image = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Figure.svg", .image = .{ .file = "Figure.svg", .width_px = 190 } });
    image.table_caption_layout = TableCaptionCodecTest.minimal(); image.table_caption_layout.?.caption_link_paint = paint;
    image.caption_blocks = &caption;
    const cases = [_]types.Entry{
        .{ .title = "state", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "direct", .blocks = &direct }} },
        .{ .title = "state", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "state", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &direct }} },
        .{ .title = "state", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "image", .blocks = &.{.{ .kind = .paragraph, .figure = image }} }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry }; stored.entry.media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "resource" }};
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, stored, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
    var conflicting = figure; conflicting.content.missing.link_paint = .vector_new_link_v1;
    var rejected: Encoder = .{ .a = a, .version = .container_fonts }; defer rejected.deinit();
    try std.testing.expectError(error.InvalidPresentation, rejected.figure(@as(?types.Figure, conflicting)));
    conflicting = figure; conflicting.content.missing.label.foreground = "#ffffff";
    try std.testing.expectError(error.InvalidPresentation, rejected.figure(@as(?types.Figure, conflicting)));
    conflicting = figure; conflicting.caption_blocks = null; conflicting.caption = &.{.{ .kind = .link, .text = "mismatch", .target = "Target", .foreground = "#ffffff" }};
    try std.testing.expectError(error.InvalidPresentation, rejected.figure(@as(?types.Figure, conflicting)));
    conflicting = figure; conflicting.content.missing.label.kind = .text;
    conflicting.content.missing.label.target = ""; conflicting.content.missing.label.target_fragment = null;
    try std.testing.expect(!types.validFigure(conflicting));
    try std.testing.expectError(error.InvalidPresentation, rejected.figure(@as(?types.Figure, conflicting)));
    conflicting.table_caption_layout.?.missing_link_paint = null;
    try std.testing.expect(types.validFigure(conflicting));
    var no_link: Encoder = .{ .a = a, .version = .container_fonts }; defer no_link.deinit();
    try no_link.figure(@as(?types.Figure, conflicting));
    var no_link_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = no_link.out.items };
    try std.testing.expectEqualDeep(conflicting, (try no_link_reader.figure()).?);
    var legacy = FigureLinkPaintCodecTest.missing(); legacy.table_caption_layout = null;
    legacy.content.missing.link_paint = .vector_new_link_v1; legacy.content.missing.label.foreground = null;
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit(); try old.figure(@as(?types.Figure, legacy));
    try std.testing.expectEqual(@as(u8, 2), old.out.items[0]);
    var old_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = old.out.items };
    try std.testing.expectEqualDeep(legacy, (try old_reader.figure()).?);
}


test "M CSS pixel spans preserve exact numeric origins and refuse every earlier span header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]f32{ 0, 1, 12, 9.6 }) |size| {
        const span: types.Span = .{ .kind = .link, .text = "full", .target = "Target", .target_fragment = "kept", .bold = true,
            .font_scale = size, .font_scale_basis = .css_px };
        var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit();
        try encoded.span(span);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
        try std.testing.expectEqualDeep(span, try reader.span());
        try std.testing.expectEqual(encoded.out.items.len, reader.pos);
        inline for (comptime std.meta.tags(Version)) |version| {
            if (version == .container_fonts) continue;
            var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
            try std.testing.expectError(error.InvalidPresentation, old.span(span));
        }
    }
    // Use a field-minimal span: the earlier-header read must fail on the new
    // basis, not on an unrelated image/target/tooltip feature or short input.
    const plain: types.Span = .{ .text = "kept", .font_scale = 12, .font_scale_basis = .css_px };
    var bytes: Encoder = .{ .a = a, .version = .container_fonts }; defer bytes.deinit();
    try bytes.span(plain);
    inline for (comptime std.meta.tags(Version)) |version| {
        if (hasFontScaleBasisFields(version) and version != .container_fonts) {
            var earlier: Reader = .{ .a = a, .version = version, .bytes = bytes.out.items };
            try std.testing.expectError(error.InvalidPresentation, earlier.span());
        }
    }
    for ([_]types.FontScaleBasis{ .context, .normal_body }) |basis| {
        const legacy: types.Span = .{ .text = "retained", .font_scale = 0.8, .font_scale_basis = basis };
        var old: Encoder = .{ .a = a, .version = .inline_table_styles }; defer old.deinit();
        var current: Encoder = .{ .a = a, .version = .container_fonts }; defer current.deinit();
        try old.span(legacy); try current.span(legacy);
        try std.testing.expectEqualSlices(u8, old.out.items, current.out.items);
    }
}

test "CSS pixel origin selects M independently at every recursive serialized span owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const pixels = [_]types.Span{.{ .kind = .link, .text = "complete owner", .trail = "s", .target = "Target", .target_fragment = "kept",
        .tooltip = "full advice", .foreground = "#123456", .background = "#abcdef", .bold = true, .italic = true, .code = true,
        .font_scale = 12, .font_scale_basis = .css_px }};
    const leaf = [_]types.Block{.{ .kind = .paragraph, .spans = &pixels }};
    const cell_table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &pixels }} }} };
    const empty_table: types.Table = .{ .rows = &.{.{ .cells = &.{.{}} }} };
    const image: types.Span = .{ .kind = .link, .target = "File:Figure.svg", .image = .{ .file = "Figure.svg", .width_px = 20, .alt = "source alternative" } };
    const media = [_]types.Media{.{ .kind = .image, .file = "Figure.svg", .caption = "source catalogue" }};
    for (0..19) |owner| {
        errdefer std.debug.print("CSS_PX_RECURSIVE_OWNER={d}\n", .{owner});
        var entry: types.Entry = .{ .title = "font", .kind = .supplemental };
        var block: types.Block = .{ .kind = .paragraph };
        switch (owner) {
            0 => entry.display_title = &pixels,
            1 => entry.preamble_spans = &pixels,
            2 => entry.references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .spans = &pixels }},
            3 => block = leaf[0],
            4 => block = .{ .kind = .table, .table = cell_table },
            5 => { var table = empty_table; table.caption = &pixels; block = .{ .kind = .table, .table = table }; },
            6 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = cell_table }} }} } },
            7 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &leaf }} }} } },
            8 => { var table = empty_table; table.caption_blocks = &leaf; block = .{ .kind = .table, .table = table }; },
            9 => block = .{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } },
            10 => block = .{ .kind = .paragraph, .flow = &.{.{ .kind = .@"inline", .spans = &pixels }} },
            11 => block = .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .authored_direction = .ltr, .resolved_direction = .ltr,
                .parts = &.{.{ .kind = .@"inline", .spans = &pixels }} } }} },
            12, 13, 14, 17, 18 => {
                var figure = FigureCodecFixture.make(image);
                if (owner == 12) { figure.content.image.span.font_scale = 12; figure.content.image.span.font_scale_basis = .css_px; }
                else if (owner == 14) figure.caption_blocks = &leaf
                else figure.caption = &pixels;
                entry.media = &media;
                block = if (owner == 17) .{ .kind = .paragraph, .flow = &.{.{ .kind = .figure, .figure = figure }} }
                    else if (owner == 18) .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .authored_direction = .ltr, .resolved_direction = .ltr,
                        .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }
                    else .{ .kind = .paragraph, .figure = figure };
            },
            15 => entry.references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{.{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } }} }},
            16 => {
                var figure = MissingFigureCodecTest.make();
                figure.content.missing.label.font_scale = 12;
                figure.content.missing.label.font_scale_basis = .css_px;
                block = .{ .kind = .paragraph, .figure = figure };
            },
            else => unreachable,
        }
        if (owner >= 3 and owner != 15) entry.sections = &.{.{ .level = 2, .title = "body", .blocks = &.{block} }};
        try std.testing.expect(hasCssPixelFonts(entry.display_title, entry.sections, entry.preamble_spans, entry.references));
        const stored: types.Stored = .{ .entry = entry };
        if (owner == 2) {
            try std.testing.expectEqual(types.ReferenceKind.note, entry.references[0].kind);
            try std.testing.expectEqual(@as(?u32, 1), entry.references[0].group_number);
        }
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const encoded = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, encoded[0..4]);
        const decoded = try decodeAlloc(a, encoded, "font", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
        if (entry.preamble_spans.len == 0) {
            const built = try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media);
            try std.testing.expectEqualSlices(u8, encoded, built);
        }
    }
}

test "CSS pixel span payload keeps zero one strict unknown basis truncation and table separation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    // The empty string fields occupy 7 length words after kind/role/flags;
    // foreground/background presences follow, then scale presence/value/basis.
    var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit();
    try encoded.span(types.Span{ .font_scale = 1, .font_scale_basis = .css_px });
    const basis_at: usize = 3 + 7 * 4 + 2 + 1 + 4;
    try std.testing.expectEqual(@as(u8, 2), encoded.out.items[basis_at]);
    const bad = try a.dupe(u8, encoded.out.items); bad[basis_at] = 3;
    var unknown: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, unknown.span());
    for (0..encoded.out.items.len) |end| {
        var truncated: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, truncated.span());
    }
    var invalid: Encoder = .{ .a = a, .version = .container_fonts }; defer invalid.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid.span(types.Span{ .font_scale_basis = .css_px }));
    try std.testing.expectError(error.InvalidPresentation, invalid.tableStyle(types.TableStyle{ .line_height = .{ .value = 12, .font_scale_basis = .css_px } }));
}


test "CSS pixel full payload remains rejected under every earlier header and old fonts keep old selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const spans = [_]types.Span{.{ .text = "source size", .font_scale = 12, .font_scale_basis = .css_px }};
    const stored: types.Stored = .{ .entry = .{ .title = "font", .kind = .supplemental, .display_title = &spans } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(container_fonts_magic, encoded[0..4]);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, encoded, "font", .supplemental, null));
    inline for (comptime std.meta.tags(Version)) |version| {
        if (version == .container_fonts) continue;
        const earlier = try a.dupe(u8, encoded);
        @memcpy(earlier[0..4], versionMagic(version));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, earlier, "font", .supplemental, null));
    }
    for ([_]types.FontScaleBasis{ .context, .normal_body }) |basis| {
        const old = [_]types.Span{.{ .text = "unchanged", .font_scale = 0.8, .font_scale_basis = basis }};
        const old_stored: types.Stored = .{ .entry = .{ .title = "old", .kind = .supplemental, .display_title = &old } };
        const old_bytes = try encodeAlloc(a, old_stored);
        try std.testing.expectEqualStrings(if (basis == .context) font_scale_magic else font_scale_basis_magic, old_bytes[0..4]);
        try std.testing.expectEqualDeep(old_stored, try decodeAlloc(a, old_bytes, "old", .supplemental, null));
    }
}

test "M Figure base wrapper uses required existing ContainerStyle wire and rejects absent or foreign fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    var layout = TableCaptionCodecTest.minimal();
    layout.wrapper = .{ .margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto }, .clear = .right };
    const states = [_]types.FigureViewportState{.{ .max_width_px = 639, .wrapper = .{}, .media = layout.media }};
    layout.viewport_states = &states;
    var wire: Encoder = .{ .a = a, .version = .container_fonts }; defer wire.deinit();
    try wire.tableCaptionLayout(layout);
    var wrapper: Encoder = .{ .a = a, .version = .container_fonts }; defer wrapper.deinit();
    try wrapper.containerStyle(layout.wrapper);
    try std.testing.expectEqual(@as(u8, @intFromEnum(types.BorderCollapse.collapse)), wire.out.items[0]);
    try std.testing.expectEqualSlices(u8, wrapper.out.items, wire.out.items[1..][0..wrapper.out.items.len]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items };
    const decoded = try reader.tableCaptionLayout();
    try std.testing.expectEqualDeep(layout, decoded);
    try std.testing.expectEqual(wire.out.items.len, reader.pos);
    try std.testing.expectEqualDeep(layout.wrapper, if (try types.resolveFigureViewportState(decoded, 900)) |state| state.wrapper else decoded.wrapper);
    try std.testing.expectEqualDeep(@as(types.ContainerStyle, .{}), (try types.resolveFigureViewportState(decoded, 639)).?.wrapper);
    var reencoded: Encoder = .{ .a = a, .version = .container_fonts }; defer reencoded.deinit();
    try reencoded.tableCaptionLayout(decoded);
    try std.testing.expectEqualSlices(u8, wire.out.items, reencoded.out.items);
    for (0..wire.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.tableCaptionLayout());
    }
    const unknown = try a.dupe(u8, wire.out.items); unknown[4] |= 0x80;
    var unknown_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = unknown };
    try std.testing.expectError(error.InvalidPresentation, unknown_reader.tableCaptionLayout());

    var minimal: Encoder = .{ .a = a, .version = .container_fonts }; defer minimal.deinit();
    try minimal.tableCaptionLayout(TableCaptionCodecTest.minimal());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, minimal.out.items[1..5]);
    var positive: Reader = .{ .a = a, .version = .container_fonts, .bytes = minimal.out.items };
    try std.testing.expectEqualDeep(TableCaptionCodecTest.minimal(), try positive.tableCaptionLayout());
    // The unshipped former tail omitted this required record; it is not an
    // alternate interpretation of the current tags.
    const omitted = try std.mem.concat(a, u8, &.{ minimal.out.items[0..1], minimal.out.items[5..] });
    var omitted_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = omitted };
    try std.testing.expectError(error.InvalidPresentation, omitted_reader.tableCaptionLayout());
    var foreign: Encoder = .{ .a = a, .version = .container_fonts }; defer foreign.deinit();
    try foreign.byte(minimal.out.items[0]);
    try foreign.containerStyle(.{ .width = .auto });
    try foreign.out.appendSlice(a, minimal.out.items[5..]);
    var foreign_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = foreign.out.items };
    try std.testing.expectError(error.InvalidPresentation, foreign_reader.tableCaptionLayout());
    var invalid = layout; invalid.wrapper.width = .auto;
    try std.testing.expectError(error.InvalidPresentation, wire.tableCaptionLayout(invalid));
}

test "M cell line height appends its strict optional metric tail and preserves all old style bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const normal: types.CellStyle = .{ .line_height = .{ .height = .normal } };
    var minimal: Encoder = .{ .a = a, .version = .container_fonts }; defer minimal.deinit(); try minimal.cellStyle(normal);
    try std.testing.expectEqualSlices(u8, &.{ 1, 8, 0, 0 }, minimal.out.items);
    var positive: Reader = .{ .a = a, .version = .container_fonts, .bytes = minimal.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, normal), try positive.cellStyle());
    const zero: types.CellStyle = .{ .line_height = .{ .strut = .{ .font_scale = 0, .font_scale_basis = .normal_body }, .height = .{ .length = .{ .value = 0, .font_scale_basis = .normal_body } } } };
    var wire: Encoder = .{ .a = a, .version = .container_fonts }; defer wire.deinit(); try wire.cellStyle(zero);
    const golden = [_]u8{ 1, 8, 1, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 1 };
    try std.testing.expectEqualSlices(u8, &golden, wire.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, zero), try reader.cellStyle());
    try std.testing.expectEqual(wire.out.items.len, reader.pos);
    // Frozen pre-feature M mask rejects the new08 bit, rather than assigning
    // an old field or a second interpretation to this same payload.
    try std.testing.expect(wire.out.items[1] & ~@as(u8, 0xe7) != 0);
    const prior: types.CellStyle = .{ .text_align = .left, .width = .{ .unit = .percent, .value = 48 }, .min_width = .{ .unit = .px, .value = 3 }, .vertical_align = .top };
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit(); try old.cellStyle(prior);
    var combined = prior; combined.line_height = zero.line_height;
    var appended: Encoder = .{ .a = a, .version = .container_fonts }; defer appended.deinit(); try appended.cellStyle(combined);
    try std.testing.expectEqual(old.out.items[1] | @as(u8, 8), appended.out.items[1]);
    try std.testing.expectEqualSlices(u8, old.out.items[2..], appended.out.items[2..old.out.items.len]);
    try std.testing.expectEqualSlices(u8, golden[2..], appended.out.items[old.out.items.len..]);
    var complete: Reader = .{ .a = a, .version = .container_fonts, .bytes = appended.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, combined), try complete.cellStyle());
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var refused: Encoder = .{ .a = a, .version = version }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.cellStyle(normal));
        var legacy: Reader = .{ .a = a, .version = version, .bytes = wire.out.items };
        try std.testing.expectError(error.InvalidPresentation, legacy.cellStyle());
    }
    for (0..wire.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.cellStyle());
    }
    const mutations = [_]struct { at: usize, value: u8 }{
        .{ .at = 1, .value = 0x18 }, .{ .at = 2, .value = 2 },
        .{ .at = 7, .value = 0 }, .{ .at = 7, .value = 3 },
        .{ .at = 8, .value = 3 }, .{ .at = 8, .value = 255 },
        .{ .at = 13, .value = 0 }, .{ .at = 13, .value = 3 },
    };
    for (mutations) |mutation| {
        const bytes = try a.dupe(u8, &golden); bytes[mutation.at] = mutation.value;
        var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad.cellStyle());
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |number| {
        for ([_]usize{ 3, 9 }) |at| {
            const bytes = try a.dupe(u8, &golden); std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(number), .little);
            var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
            try std.testing.expectError(error.InvalidPresentation, bad.cellStyle());
        }
        var invalid: Encoder = .{ .a = a, .version = .container_fonts }; defer invalid.deinit();
        try std.testing.expectError(error.InvalidPresentation, invalid.cellStyle(.{ .line_height = .{ .height = .{ .multiplier = number } } }));
        var bytes = [_]u8{ 1, 8, 0, 1, 0, 0, 0, 0 };
        std.mem.writeInt(u32, bytes[4..8], @bitCast(number), .little);
        var bad_number: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bytes };
        try std.testing.expectError(error.InvalidPresentation, bad_number.cellStyle());
    }
}

test "genuine EL footer and empty cell retain whole neighbor graph fonts actions and exact codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const fixtures = [_]struct { bytes: []const u8, row: usize, column: usize, policy: types.CellLineHeight, spans: usize }{
        .{ .bytes = @embedFile("testdata/el-cell-line-height/modern.table.json"), .row = 5, .column = 0, .spans = 5,
            .policy = .{ .strut = .{ .font_scale = 0.7, .font_scale_basis = .normal_body }, .height = .{ .length = .{ .value = 0.7, .font_scale_basis = .normal_body } } } },
        .{ .bytes = @embedFile("testdata/el-cell-line-height/ancient.table.json"), .row = 1, .column = 0, .spans = 0,
            .policy = .{ .height = .{ .length = .{ .value = 1, .font_scale_basis = .normal_body } } } },
    };
    for (fixtures) |fixture| {
        const parsed = try std.json.parseFromSlice(types.Table, a, fixture.bytes, .{}); defer parsed.deinit();
        const original = parsed.value;
        var table = original;
        const rows = try a.dupe(types.Row, original.rows);
        const cells = try a.dupe(types.Cell, original.rows[fixture.row].cells);
        rows[fixture.row].cells = cells; table.rows = rows;
        const old_cell = cells[fixture.column];
        try std.testing.expectEqual(fixture.spans, old_cell.spans.len);
        try std.testing.expect(old_cell.blocks == null and old_cell.nested_table == null);
        var style = old_cell.style orelse types.CellStyle{};
        try std.testing.expect(style.line_height == null);
        style.line_height = fixture.policy; cells[fixture.column].style = style;
        try std.testing.expectEqualDeep(fixture.policy, cells[fixture.column].style.?.line_height.?);
        // Compare the complete typed graph after restoring ONLY the explicitly
        // added policy. All original cells, fonts, actions and geometry remain.
        const restored_rows = try a.dupe(types.Row, rows);
        const restored_cells = try a.dupe(types.Cell, cells);
        restored_cells[fixture.column] = old_cell;
        restored_rows[fixture.row].cells = restored_cells;
        var restored = table; restored.rows = restored_rows;
        try std.testing.expectEqualDeep(original, restored);
        if (fixture.spans != 0) {
            for (old_cell.spans) |span| {
                try std.testing.expectEqual(@as(?f32, 0.7), span.font_scale);
                try std.testing.expectEqual(types.FontScaleBasis.normal_body, span.font_scale_basis);
            }
            try std.testing.expectEqual(@as(u16, 5), old_cell.colspan);
            try std.testing.expectEqualStrings("Κατηγορία", old_cell.spans[0].text);
            try std.testing.expectEqualStrings("Κατηγορία:Ουσιαστικά που κλίνονται όπως το 'νίκη' (νέα ελληνικά)", old_cell.spans[0].target);
        } else try std.testing.expectEqualStrings("#e3e5e8", old_cell.background.?);
        const stored: types.Stored = .{ .entry = .{ .title = "cell whole source", .kind = .supplemental,
            .sections = &.{.{ .level = 2, .title = "whole table", .blocks = &.{.{ .kind = .table, .table = table }} }} } };
        try types.validateStored(a, stored, stored.entry.title, .supplemental, null);
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const reparsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer reparsed.deinit();
        try std.testing.expectEqualDeep(stored, reparsed.value);
    }
}

test "cell line height independently selects M through every existing recursive table owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const grid: types.Table = .{ .rows = &.{.{ .cells = &.{
        .{ .style = .{ .line_height = .{ .height = .{ .multiplier = 1.25 } } }, .spans = &.{.{ .kind = .link, .text = "whole cell", .target = "Kept", .target_fragment = "section" }} },
        .{ .spans = &.{.{ .text = "\u{a0}" }}, .style = .{ .line_height = .{ .strut = .{ .font_scale = 0, .font_scale_basis = .css_px }, .height = .normal } } },
        .{ .style = .{ .line_height = .{ .height = .{ .length = .{ .value = 0, .font_scale_basis = .normal_body } } } } },
    } }} };
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .table, .table = grid }} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const entries = [_]types.Entry{
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &.{.{ .kind = .table, .table = grid }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = grid }} }} } }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{
            .level = 2, .title = "caption body", .blocks = &.{.{ .kind = .table, .table = .{ .caption_blocks = &boxes } }},
        }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Container", .blocks = &boxes }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .rtl, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &boxes }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        for ([_]u8{ 'H', 'J', 'K', 'L' }) |header| {
            const old = try a.dupe(u8, bytes); old[3] = header;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, .supplemental, null));
        }
    }
    const legacy: types.Stored = .{ .entry = .{ .title = "old cell", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "old" }} }} }} } }} }} } };
    const old = try encodeAlloc(a, legacy);
    try std.testing.expect(!std.mem.eql(u8, container_fonts_magic, old[0..4]));
    try std.testing.expectEqualDeep(legacy, try decodeAlloc(a, old, legacy.entry.title, .supplemental, null));
}


test "M font feature policy keeps absent bytes and rejects unknown flags policies and truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const presence_at: usize = 3 + 7 * 4 + 2;
    for ([_]types.FontFeaturePolicy{ .normal, .seven_on }) |policy| {
        const span: types.Span = .{ .font_features = policy };
        var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit();
        try encoded.span(span);
        try std.testing.expectEqual(@as(u8, 2), encoded.out.items[presence_at]);
        try std.testing.expectEqual(@intFromEnum(policy), encoded.out.items[presence_at + 1]);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
        try std.testing.expectEqualDeep(span, try reader.span());
        try std.testing.expectEqual(encoded.out.items.len, reader.pos);
        for ([_]u8{ 2, 255 }) |invalid| {
            const bytes = try a.dupe(u8, encoded.out.items); bytes[presence_at + 1] = invalid;
            var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
            try std.testing.expectError(error.InvalidPresentation, bad.span());
        }
        const flags = try a.dupe(u8, encoded.out.items); flags[presence_at] |= 8;
        var bad_flags: Reader = .{ .a = a, .version = .container_fonts, .bytes = flags };
        try std.testing.expectError(error.InvalidPresentation, bad_flags.span());
        for (0..encoded.out.items.len) |end| {
            var truncated: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, truncated.span());
        }
        inline for (comptime std.meta.tags(Version)) |version| {
            if (version == .container_fonts) continue;
            var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
            try std.testing.expectError(error.InvalidPresentation, old.span(span));
        }
        var combined: Encoder = .{ .a = a, .version = .container_fonts }; defer combined.deinit();
        const scaled: types.Span = .{ .font_scale = 0.8, .font_scale_basis = .normal_body, .font_features = policy };
        try combined.span(scaled);
        try std.testing.expectEqual(@as(u8, 3), combined.out.items[presence_at]);
        try std.testing.expectEqual(@intFromEnum(types.FontScaleBasis.normal_body), combined.out.items[presence_at + 5]);
        try std.testing.expectEqual(@intFromEnum(policy), combined.out.items[presence_at + 6]);
        var combined_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = combined.out.items };
        try std.testing.expectEqualDeep(scaled, try combined_reader.span());
        inline for (comptime std.meta.tags(Version)) |version| {
            if (hasFontScaleFields(version) and version != .container_fonts) {
                var earlier: Reader = .{ .a = a, .version = version, .bytes = combined.out.items };
                try std.testing.expectError(error.InvalidPresentation, earlier.span());
            }
        }
        var media = TableCaptionCodecTest.minimal().media; media.strut.font_features = policy;
        var media_bytes: Encoder = .{ .a = a, .version = .container_fonts }; defer media_bytes.deinit();
        try media_bytes.figureMediaLayout(media);
        var media_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = media_bytes.out.items };
        try std.testing.expectEqualDeep(media, try media_reader.figureMediaLayout());
        const invalid_media = try a.dupe(u8, media_bytes.out.items);
        // scale4, flags1, empty language length4, direction1, policy1.
        try std.testing.expectEqual(@as(u8, 8), invalid_media[4] & 8);
        invalid_media[10] = 2;
        var bad_media: Reader = .{ .a = a, .version = .container_fonts, .bytes = invalid_media };
        try std.testing.expectError(error.InvalidPresentation, bad_media.figureMediaLayout());
    }
    var old: Encoder = .{ .a = a, .version = .inline_table_styles }; defer old.deinit();
    var current: Encoder = .{ .a = a, .version = .container_fonts }; defer current.deinit();
    const legacy: types.Span = .{ .text = "unchanged", .font_scale = 0.8, .font_scale_basis = .normal_body };
    try old.span(legacy); try current.span(legacy);
    try std.testing.expectEqualSlices(u8, old.out.items, current.out.items);
    const explicit = [_]types.Span{.{ .text = "complete replacement", .font_features = .normal }};
    const sections = [_]types.Section{.{ .level = 2, .title = "kept", .blocks = &.{.{ .kind = .paragraph, .spans = &explicit }} }};
    try std.testing.expect(hasMSpanFonts(@as([]const types.Span, &.{}), &sections, @as([]const types.Span, &.{}), @as([]const types.Reference, &.{})));
}


test "M automatic table margin tail has exact framing and strict old masks malformed bytes and truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const style: types.TableStyle = .{ .containing_direction = .ltr, .margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto } };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit(); try encoder.tableStyle(style);
    const expected = [_]u8{ 1, 0, 24, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &expected, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &expected };
    try std.testing.expectEqualDeep(@as(?types.TableStyle, style), try reader.tableStyle());
    try std.testing.expectEqual(expected.len, reader.pos);
    for ([_]Version{ .inline_table_styles, .block_containers, .image_maps }) |version| {
        var old_encoder: Encoder = .{ .a = a, .version = version }; defer old_encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, old_encoder.tableStyle(style));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = &expected };
        try std.testing.expectError(error.InvalidPresentation, old_reader.tableStyle());
    }
    for (0..expected.len) |end| {
        var truncated: Reader = .{ .a = a, .version = .container_fonts, .bytes = expected[0..end] };
        try std.testing.expectError(error.InvalidPresentation, truncated.tableStyle());
    }
    for ([_]usize{ 3, 4, 9, 2 }) |index| {
        var bad = expected; bad[index] = 255;
        var rejected: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bad };
        try std.testing.expectError(error.InvalidPresentation, rejected.tableStyle());
    }
    var infinity = expected; @memcpy(infinity[5..9], &[_]u8{ 0, 0, 128, 127 });
    var invalid: Reader = .{ .a = a, .version = .container_fonts, .bytes = &infinity };
    try std.testing.expectError(error.InvalidPresentation, invalid.tableStyle());
    var legacy: Encoder = .{ .a = a, .version = .container_fonts }; defer legacy.deinit(); try legacy.tableStyle(.{ .clear = .none });
    const old_bytes = [_]u8{ 1, 128, 0, 0 };
    try std.testing.expectEqualSlices(u8, &old_bytes, legacy.out.items);
}

test "automatic table margins select M through nested caption container and reference owners with full graph bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const fixed: types.ContainerMargin = .{ .length = .{ .unit = .em, .value = 0.2 } };
    const table: types.Table = .{ .style = .{ .width = .{ .unit = .percent, .value = 70 }, .collapse = .collapse, .clear = .none, .containing_direction = .rtl,
        .margin_values = .{ .top = fixed, .right = .auto, .bottom = fixed, .left = .auto } },
        .caption = &.{.{ .text = "complete caption" }}, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .target = "Target#part", .text = "complete body", .bold = true }} }} }} };
    const leaf = [_]types.Block{.{ .kind = .table, .table = table }};
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{ .{ .nested_table = table }, .{ .blocks = &leaf } } }} };
    const caption: types.Table = .{ .caption_blocks = &leaf, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "cell" }} }} }} };
    const box: types.Block = .{ .kind = .container, .container = .{ .style = .{ .clear = .both }, .blocks = &leaf } };
    const entries = [_]types.Entry{
        .{ .title = "automatic margins", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &leaf }} },
        .{ .title = "automatic margins", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "automatic margins", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = caption }} }} },
        .{ .title = "automatic margins", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{box} }} },
        .{ .title = "automatic margins", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &leaf }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
    }
}

test "M table containing direction pairs capability flags and rejects missing malformed and truncated parent proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const margins: types.ContainerMargins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto };
    for ([_]types.TableContainingDirection{ .ltr, .rtl }) |direction| {
        const style: types.TableStyle = .{ .margin_values = margins, .containing_direction = direction };
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
        try encoder.tableStyle(style);
        try std.testing.expectEqual(@as(u8, 24), encoder.out.items[2]);
        try std.testing.expectEqual(@intFromEnum(direction), encoder.out.items[encoder.out.items.len - 1]);
        // The prior private margin reader's f0 mask refuses new bit4.
        try std.testing.expect(encoder.out.items[2] & 0xf0 != 0);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items };
        try std.testing.expectEqualDeep(@as(?types.TableStyle, style), try reader.tableStyle());
        for ([_]u8{ 8, 16, 32, 255 }) |flags| {
            const bad = try a.dupe(u8, encoder.out.items); bad[2] = flags;
            var rejected: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
            try std.testing.expectError(error.InvalidPresentation, rejected.tableStyle());
        }
        const bad = try a.dupe(u8, encoder.out.items); bad[bad.len - 1] = 2;
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, invalid.tableStyle());
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoder.out.items[0 .. encoder.out.items.len - 1] };
        try std.testing.expectError(error.InvalidPresentation, short.tableStyle());
    }
    var missing: Encoder = .{ .a = a, .version = .container_fonts }; defer missing.deinit();
    try std.testing.expectError(error.InvalidPresentation, missing.tableStyle(.{ .margin_values = margins }));
    try std.testing.expectError(error.InvalidPresentation, missing.tableStyle(.{ .clear = .none, .containing_direction = .ltr }));
}


const TableBlockViewportCodecTest = struct {
    fn policy() types.TableBlockViewport {
        const edge: types.ContainerMargin = .{ .length = .{ .unit = .em, .value = 0.2 } };
        return .{ .max_viewport_width_px = 639,
            .box_style = .{ .width = .{ .unit = .percent, .value = 70 }, .clear = .none,
                .margin_values = .{ .top = edge, .right = .auto, .bottom = edge, .left = .auto }, .containing_direction = .ltr },
            .box_sizing = .content_box, .max_width = .{ .unit = .percent, .value = 100 },
            .grid_style = .{ .collapse = .collapse }, .grid_direction = .rtl, .language = "ru" };
    }
    fn table() types.Table {
        return .{ .caption = &.{.{ .text = "CAPTION" }}, .style = .{ .width = .{ .unit = .percent, .value = 70 } },
            .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "KEPT", .trail = "s", .target = "Target", .target_fragment = "part", .tooltip = "full advice", .bold = true, .foreground = "#123456" }} }} }} };
    }
};
test "M Table block viewport appends strict tail after unchanged legacy record bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = TableBlockViewportCodecTest.policy();
    const prior = TableBlockViewportCodecTest.table();
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
    try old.table(@as(?types.Table, prior));
    var old_k: Encoder = .{ .a = a, .version = .inline_table_styles }; defer old_k.deinit();
    try old_k.table(@as(?types.Table, prior));
    try std.testing.expectEqualSlices(u8, old_k.out.items, old.out.items);
    var value = prior; value.block_viewport = &policy;
    var wire: Encoder = .{ .a = a, .version = .container_fonts }; defer wire.deinit();
    try wire.table(@as(?types.Table, value));
    try std.testing.expectEqual(@as(u8, 1), old.out.items[0]);
    try std.testing.expectEqual(@as(u8, 3), wire.out.items[0]);
    try std.testing.expectEqualSlices(u8, old.out.items[1..], wire.out.items[1..old.out.items.len]);
    var tail: Encoder = .{ .a = a, .version = .container_fonts }; defer tail.deinit(); try tail.tableBlockViewport(policy);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 127, 2, 0, 0 }, tail.out.items[0..4]);
    try std.testing.expectEqualSlices(u8, tail.out.items, wire.out.items[old.out.items.len..]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, value), try reader.table());
    try std.testing.expectEqual(wire.out.items.len, reader.pos);
    var before: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items };
    try std.testing.expectError(error.InvalidPresentation, before.presence());
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var forbidden: Encoder = .{ .a = a, .version = version }; defer forbidden.deinit();
        try std.testing.expectError(error.InvalidPresentation, forbidden.table(@as(?types.Table, value)));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = wire.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.table());
    }
    var reencoded: Encoder = .{ .a = a, .version = .container_fonts }; defer reencoded.deinit();
    var round_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items };
    try reencoded.table(try round_reader.table());
    try std.testing.expectEqualSlices(u8, wire.out.items, reencoded.out.items);
}
test "M Table block viewport rejects truncation unknown flags enums nonfinite cap and legacy geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = TableBlockViewportCodecTest.policy();
    var value = TableBlockViewportCodecTest.table(); value.block_viewport = &policy;
    var wire: Encoder = .{ .a = a, .version = .container_fonts }; defer wire.deinit(); try wire.table(@as(?types.Table, value));
    for (0..wire.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = wire.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.table());
    }
    for ([_]u8{ 2, 4, 0x81, 0xff }) |flag| {
        const bad = try a.dupe(u8, wire.out.items); bad[0] = flag;
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.table());
    }
    var base = value; base.block_viewport = null;
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit(); try old.table(@as(?types.Table, base));
    var box: Encoder = .{ .a = a, .version = .container_fonts }; defer box.deinit(); try box.tableStyle(policy.box_style);
    const sizing_at = old.out.items.len + 4 + box.out.items.len;
    const direction_at = wire.out.items.len - (4 + policy.language.len) - 1;
    for ([_]usize{ sizing_at, direction_at }) |at| {
        const bad = try a.dupe(u8, wire.out.items); bad[at] = 2;
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.table());
    }
    const nonfinite = try a.dupe(u8, wire.out.items);
    @memcpy(nonfinite[sizing_at + 2 ..][0..4], &[_]u8{ 0, 0, 128, 127 });
    var invalid_cap: Reader = .{ .a = a, .version = .container_fonts, .bytes = nonfinite };
    try std.testing.expectError(error.InvalidPresentation, invalid_cap.table());
    value.geometry = .{ .cell_padding = 5, .border = 1, .width = .{ .unit = .percent, .value = 70 } };
    try std.testing.expectError(error.InvalidPresentation, wire.table(@as(?types.Table, value)));
}
test "Table block viewport selects M through every recursive Table owner preserving full Stored and build bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = TableBlockViewportCodecTest.policy();
    var table = TableBlockViewportCodecTest.table(); table.block_viewport = &policy;
    const leaf = [_]types.Block{.{ .kind = .table, .table = table }};
    const image: types.Span = .{ .kind = .link, .target = "File:Figure.svg", .image = .{ .file = "Figure.svg", .width_px = 20, .alt = "source alternative" } };
    const media = [_]types.Media{.{ .kind = .image, .file = "Figure.svg", .caption = "source catalogue" }};
    for (0..12) |owner| {
        errdefer std.debug.print("TABLE_BLOCK_VIEWPORT_OWNER={d}\n", .{owner});
        var entry: types.Entry = .{ .title = "viewport", .kind = .supplemental };
        var block = leaf[0];
        switch (owner) {
            0 => {},
            1 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } },
            2 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &leaf }} }} } },
            3 => block = .{ .kind = .table, .table = .{ .caption_blocks = &leaf, .rows = &.{.{ .cells = &.{.{}} }} } },
            4 => block = .{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } },
            5 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &.{.{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } }} }} }} } },
            6 => block = .{ .kind = .table, .table = .{ .caption_blocks = &.{.{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } }}, .rows = &.{.{ .cells = &.{.{}} }} } },
            7, 8, 9 => {
                var figure = FigureCodecFixture.make(image); figure.caption_blocks = &leaf; entry.media = &media;
                block = if (owner == 7) .{ .kind = .paragraph, .figure = figure }
                    else if (owner == 8) .{ .kind = .paragraph, .flow = &.{.{ .kind = .figure, .figure = figure }} }
                    else .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .authored_direction = .ltr, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} };
            },
            10 => entry.references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .blocks = &leaf }},
            11 => entry.references = &.{.{ .kind = .fragment, .number = 1, .group_number = null,
                .blocks = &.{.{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } }} }},
            else => unreachable,
        }
        if (owner < 10) entry.sections = &.{.{ .level = 2, .title = "body", .blocks = &.{block} }};
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const before = try std.json.Stringify.valueAlloc(a, stored, .{});
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(a, decoded, .{}));
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
    }
}


test "M Cell middle uses existing alignment slot without changing null top order or old version refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var absent: Encoder = .{ .a = a, .version = .container_fonts }; defer absent.deinit(); try absent.cellStyle(null);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, absent.out.items);
    var top: Encoder = .{ .a = a, .version = .container_fonts }; defer top.deinit(); try top.cellStyle(.{ .vertical_align = .top });
    try std.testing.expectEqualSlices(u8, &[_]u8{1, 0x80, 0}, top.out.items);
    var middle: Encoder = .{ .a = a, .version = .container_fonts }; defer middle.deinit(); try middle.cellStyle(.{ .vertical_align = .middle });
    try std.testing.expectEqualSlices(u8, &[_]u8{1, 0x80, 1}, middle.out.items);
    var decoded: Reader = .{ .a = a, .version = .container_fonts, .bytes = middle.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, .{ .vertical_align = .middle }), try decoded.cellStyle());
    try std.testing.expectEqual(middle.out.items.len, decoded.pos);
    // All optional payloads retain their pre-existing order, independent of enum expansion.
    const combined: types.CellStyle = .{ .width = .{ .unit = .percent, .value = 25 },
        .min_width = .{ .unit = .px, .value = 7 }, .vertical_align = .middle,
        .line_height = .{ .height = .{ .multiplier = 1.25 } } };
    var mixed: Encoder = .{ .a = a, .version = .container_fonts }; defer mixed.deinit(); try mixed.cellStyle(combined);
    var expected: Encoder = .{ .a = a, .version = .container_fonts }; defer expected.deinit();
    try expected.byte(1); try expected.byte(0xe8); try expected.styleWidth(combined.width.?);
    try expected.styleLength(combined.min_width.?); try expected.byte(1); try expected.cellLineHeight(combined.line_height.?);
    try std.testing.expectEqualSlices(u8, expected.out.items, mixed.out.items);
    var mixed_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = mixed.out.items };
    try std.testing.expectEqualDeep(@as(?types.CellStyle, combined), try mixed_reader.cellStyle());
    for (0..middle.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = middle.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.cellStyle());
    }
    for ([_]u8{ 2, 3, 255 }) |tag| {
        const bad = [_]u8{ 1, 0x80, tag };
        var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = &bad };
        try std.testing.expectError(error.InvalidPresentation, reader.cellStyle());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (comptime version == .container_fonts) continue;
        var forbidden: Encoder = .{ .a = a, .version = version }; defer forbidden.deinit();
        try std.testing.expectError(error.InvalidPresentation, forbidden.cellStyle(.{ .vertical_align = .middle }));
        var old_reader: Reader = .{ .a = a, .version = version, .bytes = middle.out.items };
        try std.testing.expectError(error.InvalidPresentation, old_reader.cellStyle());
    }
}
test "Cell middle recursively retains complete table body actions neighbors and Stored build codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var table = TableBlockViewportCodecTest.table();
    const rows = try a.dupe(types.Row, table.rows);
    const cells = try a.alloc(types.Cell, 3);
    cells[0] = rows[0].cells[0]; cells[0].style = .{ .vertical_align = .middle };
    cells[1] = .{ .style = .{ .vertical_align = .top }, .spans = &.{.{ .text = "TOP NEIGHBOR" }} };
    cells[2] = .{ .spans = &.{.{ .text = "NULL NEIGHBOR" }} };
    rows[0].cells = cells; table.rows = rows;
    const leaf = [_]types.Block{.{ .kind = .table, .table = table }};
    for (0..6) |owner| {
        errdefer std.debug.print("CELL_MIDDLE_OWNER={d}\n", .{owner});
        var entry: types.Entry = .{ .title = "middle", .kind = .supplemental };
        var block = leaf[0];
        switch (owner) {
            0 => {},
            1 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } },
            2 => block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &leaf }} }} } },
            3 => block = .{ .kind = .container, .container = .{ .style = .{}, .blocks = &leaf } },
            4 => block = .{ .kind = .table, .table = .{ .caption_blocks = &leaf, .rows = &.{.{ .cells = &.{.{}} }} } },
            5 => entry.references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .blocks = &leaf }},
            else => unreachable,
        }
        if (owner != 5) entry.sections = &.{.{ .level = 2, .title = "body", .blocks = &.{block} }};
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const json = try std.json.Stringify.valueAlloc(a, stored, .{});
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualStrings(json, try std.json.Stringify.valueAlloc(a, decoded, .{}));
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
    }
}


test "M Table viewport appends required source language and preserves independent entry run body and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = TableBlockViewportCodecTest.policy();
    try std.testing.expectEqualStrings("ru", policy.language);
    var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit(); try encoded.tableBlockViewport(policy);
    const language_at = encoded.out.items.len - 6;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 0, 0, 0, 'r', 'u' }, encoded.out.items[language_at..]);
    try std.testing.expectEqual(@as(u8, @intCast(@intFromEnum(policy.grid_direction))), encoded.out.items[language_at - 1]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(policy, (try reader.tableBlockViewport()).*);
    try std.testing.expectEqual(encoded.out.items.len, reader.pos);
    for (language_at..encoded.out.items.len) |end| {
        var truncated: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, truncated.tableBlockViewport());
    }
    const empty = try a.dupe(u8, encoded.out.items[0 .. language_at + 4]);
    @memset(empty[language_at..], 0);
    var empty_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = empty };
    try std.testing.expectError(error.InvalidPresentation, empty_reader.tableBlockViewport());
    const malformed = try a.dupe(u8, encoded.out.items); malformed[language_at + 4] = 255;
    var malformed_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = malformed };
    try std.testing.expectError(error.InvalidPresentation, malformed_reader.tableBlockViewport());
    var bad = policy; bad.language = "";
    try std.testing.expectError(error.InvalidPresentation, encoded.tableBlockViewport(bad));
    var table = TableBlockViewportCodecTest.table(); table.block_viewport = &policy;
    const rows = try a.dupe(types.Row, table.rows);
    const cells = try a.dupe(types.Cell, rows[0].cells);
    const spans = try a.dupe(types.Span, cells[0].spans);
    spans[0].language = "uk"; cells[0].spans = spans; cells[0].style = .{ .vertical_align = .middle };
    rows[0].cells = cells; table.rows = rows;
    const entry: types.Entry = .{ .title = "source ru and entry ja", .kind = .language, .language = "Japanese", .language_code = "ja",
        .sections = &.{.{ .level = 2, .title = "Japanese", .blocks = &.{.{ .kind = .table, .table = table }} }} };
    const stored: types.Stored = .{ .entry = entry };
    try types.validateStored(a, stored, entry.title, .language, .{ .heading = "Japanese", .code = "ja" });
    const before = try std.json.Stringify.valueAlloc(a, stored, .{});
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, entry.title, .language, .{ .heading = "Japanese", .code = "ja" });
    try std.testing.expectEqualDeep(stored, decoded);
    try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqualStrings("ru", decoded.entry.sections[0].blocks[0].table.?.block_viewport.?.language);
    try std.testing.expectEqualStrings("Japanese", decoded.entry.language.?);
    try std.testing.expectEqualStrings("uk", decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].spans[0].language);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
}


const FloatViewportCodecTest = struct {
    fn table() types.Table {
        return .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "KEPT", .kind = .link, .target = "Target#part", .bold = true }} }} }},
            .style = .{ .float_side = .right, .clear = .right, .collapse = .collapse, .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0.4 }) },
            .float_viewport = .{ .max_viewport_width_px = 639, .containing_direction = .rtl, .grid_direction = .ltr, .language = "de" } };
    }
};
test "M Table float viewport has strict disjoint tail old null bytes and corruptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const value = FloatViewportCodecTest.table(); var raw: Encoder = .{ .a = a, .version = .container_fonts }; defer raw.deinit();
    try raw.table(@as(?types.Table, value)); try std.testing.expectEqual(@as(u8, 5), raw.out.items[0]);
    const tail = raw.out.items.len - 12;
    try std.testing.expectEqual(@as(u32, 639), std.mem.readInt(u32, raw.out.items[tail..][0..4], .little));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0 }, raw.out.items[tail + 4..tail + 6]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, value), try reader.table());
    for (0..raw.out.items.len) |end| { reader = .{ .a = a, .version = .container_fonts, .bytes = raw.out.items[0..end] }; try std.testing.expectError(error.InvalidPresentation, reader.table()); }
    for ([_]Version{ .plain, .image_maps, .inline_table_styles, .block_containers }) |version| {
        reader = .{ .a = a, .version = version, .bytes = raw.out.items }; try std.testing.expectError(error.InvalidPresentation, reader.table());
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit(); try std.testing.expectError(error.InvalidPresentation, old.table(@as(?types.Table, value)));
    }
    for ([_]u8{ 2, 4, 7, 255 }) |tag| { const bytes = try a.dupe(u8, raw.out.items); bytes[0] = tag;
        reader = .{ .a = a, .version = .container_fonts, .bytes = bytes }; try std.testing.expectError(error.InvalidPresentation, reader.table()); }
    for ([_]usize{ tail + 4, tail + 5 }) |offset| { const bytes = try a.dupe(u8, raw.out.items); bytes[offset] = 2;
        reader = .{ .a = a, .version = .container_fonts, .bytes = bytes }; try std.testing.expectError(error.InvalidPresentation, reader.table()); }
    const zero = try a.dupe(u8, raw.out.items); @memset(zero[tail..tail + 4], 0);
    reader = .{ .a = a, .version = .container_fonts, .bytes = zero }; try std.testing.expectError(error.InvalidPresentation, reader.table());
    var legacy = value; legacy.float_viewport = null; var first: Encoder = .{ .a = a, .version = .container_fonts }; defer first.deinit(); try first.table(@as(?types.Table, legacy));
    var second: Encoder = .{ .a = a, .version = .block_containers }; defer second.deinit(); try second.table(@as(?types.Table, legacy));
    try std.testing.expectEqual(@as(u8, 1), first.out.items[0]); try std.testing.expectEqualSlices(u8, first.out.items, second.out.items);
}

test "Table float viewport selects M recursively and retains full Stored body style actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const child = FloatViewportCodecTest.table();
    const outer: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = child }} }} };
    for ([_]types.Table{ child, outer }) |table| {
        const stored: types.Stored = .{ .entry = .{ .title = "compiled placement", .kind = .supplemental,
            .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .table, .table = table }} }} } };
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded); try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    }
}

const OrdinaryLinkPaintCodecTesting = struct {
    fn paint() types.LinkPaint {
        return types.LinkPaint.fromSixStatePrefix(FigureLinkPaintCodecTest.paint(),
            .{ .foreground = "#000007", .underline = false }, .{ .foreground = "#000008", .underline = true });
    }
    fn span() types.Span {
        return .{ .kind = .link, .text = "kept", .target = "Target", .target_fragment = "Part", .trail = "s", .tooltip = "advice",
            .foreground = "#000001", .underline = true, .link_paint = paint() };
    }
};

test "M ordinary source link paint exact existing payload framing flags and strict failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const span = OrdinaryLinkPaintCodecTesting.span();
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
    var absent = span; absent.link_paint = null; try old.span(absent);
    var encoded: Encoder = .{ .a = a, .version = .container_fonts }; defer encoded.deinit(); try encoded.span(span);
    const at: usize = 3 + 7 * 4 + span.text.len + span.target.len + span.trail.len + 1 + 4 + 7 + 1;
    try std.testing.expectEqual(@as(u8, 0), old.out.items[at]); try std.testing.expectEqual(@as(u8, 4), encoded.out.items[at]);
    var payload: Encoder = .{ .a = a, .version = .container_fonts }; defer payload.deinit(); try payload.linkPaint(span.link_paint.?);
    try std.testing.expectEqual(@as(u8, 1), encoded.out.items[at + 1]);
    const combined_tail = [_]u8{ 7, 0, 0, 0, '#', '0', '0', '0', '0', '0', '7', 7, 0, 0, 0, '#', '0', '0', '0', '0', '0', '8', 2 };
    try std.testing.expectEqualSlices(u8, &combined_tail, payload.out.items[payload.out.items.len - combined_tail.len ..]);
    const bad_combined = try a.dupe(u8, encoded.out.items); bad_combined[at + payload.out.items.len] |= 4;
    var combined_flags: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad_combined };
    try std.testing.expectError(error.InvalidPresentation, combined_flags.span());
    try std.testing.expectEqualSlices(u8, payload.out.items, encoded.out.items[at + 1 .. at + 1 + payload.out.items.len]);
    try std.testing.expectEqualSlices(u8, old.out.items[0..at], encoded.out.items[0..at]);
    try std.testing.expectEqualSlices(u8, old.out.items[at + 1 ..], encoded.out.items[at + 1 + payload.out.items.len ..]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(span, try reader.span()); try std.testing.expectEqual(encoded.out.items.len, reader.pos);
    for ([_]u8{ 0, 2, 255 }) |bad_presence| {
        const bytes = try a.dupe(u8, encoded.out.items); bytes[at + 1] = bad_presence;
        var bad: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, bad.span());
    }
    const unknown = try a.dupe(u8, encoded.out.items); unknown[at] |= 8;
    var bad_flags: Reader = .{ .a = a, .version = .container_fonts, .bytes = unknown };
    try std.testing.expectError(error.InvalidPresentation, bad_flags.span());
    for (0..2) |case| {
        const bytes = try a.dupe(u8, encoded.out.items);
        if (case == 0) bytes[0] = @intFromEnum(types.InlineKind.text) else bytes[2] &= 0x7f;
        var wrong_owner: Reader = .{ .a = a, .version = .container_fonts, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, wrong_owner.span());
    }
    for (0..encoded.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .bytes = encoded.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.span());
    }
    inline for (comptime std.meta.tags(Version)) |version| {
        if (version == .container_fonts) continue;
        var unsupported: Encoder = .{ .a = a, .version = version }; defer unsupported.deinit();
        try std.testing.expectError(error.InvalidPresentation, unsupported.span(span));
    }
    var combined_span = span; combined_span.font_scale = 0.8; combined_span.font_scale_basis = .normal_body; combined_span.font_features = .seven_on;
    var combined: Encoder = .{ .a = a, .version = .container_fonts }; defer combined.deinit(); try combined.span(combined_span);
    try std.testing.expectEqual(@as(u8, 7), combined.out.items[at]);
    try std.testing.expectEqual(@intFromEnum(types.FontScaleBasis.normal_body), combined.out.items[at + 5]);
    try std.testing.expectEqual(@intFromEnum(types.FontFeaturePolicy.seven_on), combined.out.items[at + 6]);
    var combined_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = combined.out.items };
    try std.testing.expectEqualDeep(combined_span, try combined_reader.span());
}

test "ordinary source link paint recursive M selection build stored and byte roundtrip retain all owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const spans = [_]types.Span{OrdinaryLinkPaintCodecTesting.span()};
    const body = [_]types.Block{.{ .kind = .paragraph, .spans = &spans }};
    const table: types.Table = .{ .caption = &spans, .rows = &.{.{ .cells = &.{.{ .spans = &spans }, .{ .blocks = &body }} }} };
    var figure = FigureLinkPaintCodecTest.missing(); figure.table_caption_layout = null; figure.content.missing.link_paint = null;
    figure.content.missing.label.link_paint = null; figure.caption = &spans;
    const entries = [_]types.Entry{
        .{ .title = "source links", .kind = .supplemental, .display_title = &spans },
        .{ .title = "source links", .kind = .supplemental, .preamble_spans = &spans },
        .{ .title = "source links", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &body }} },
        .{ .title = "source links", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "source links", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested table", .blocks = &.{.{ .kind = .table, .table = .{ .caption_blocks = &body, .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } }} }} },
        .{ .title = "source links", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "container", .blocks = &.{.{ .kind = .container, .container = .{ .style = .{}, .blocks = &body } }} }} },
        .{ .title = "source links", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "source links", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .rtl, .parts = &.{.{ .kind = .@"inline", .spans = &spans }} } }} }} }} },
        .{ .title = "source links", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .spans = &spans }} },
        .{ .title = "source links", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &body }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, entry.title, .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        // The existing build API has no preamble input. Compare its complete
        // output to the independently constructed corresponding Stored shape;
        // the original preamble-bearing record above still roundtrips exactly.
        var build_entry = entry; build_entry.preamble_spans = &.{};
        const build_bytes = try encodeAlloc(a, .{ .entry = build_entry });
        try std.testing.expectEqualSlices(u8, build_bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
    }
}

test "ordinary source link paint rejects invalid owners and overlapping Figure paint without losing legacy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const good = OrdinaryLinkPaintCodecTesting.span();
    for (0..4) |case| {
        var bad = good;
        switch (case) { 0 => bad.kind = .text, 1 => bad.target = "", 2 => bad.foreground = "#ffffff", 3 => bad.underline = false, else => unreachable }
        var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.span(bad));
    }
    var figure = FigureLinkPaintCodecTest.missing(); figure.caption = &.{good};
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
    try std.testing.expectError(error.InvalidPresentation, encoder.figure(@as(?types.Figure, figure)));
    figure.table_caption_layout.?.caption_link_paint = null;
    var independent: Encoder = .{ .a = a, .version = .container_fonts }; defer independent.deinit();
    try independent.figure(@as(?types.Figure, figure));
    figure.caption = &.{}; figure.content.missing.label.underline = true;
    figure.content.missing.label.link_paint = OrdinaryLinkPaintCodecTesting.paint();
    try std.testing.expect(types.validSpanLinkPaint(figure.content.missing.label));
    try std.testing.expectError(error.InvalidPresentation, encoder.figure(@as(?types.Figure, figure)));
    figure.table_caption_layout = null; figure.content.missing.link_paint = .vector_new_link_v1;
    figure.content.missing.label.foreground = null; figure.content.missing.label.link_paint = null;
    var legacy_figure: Encoder = .{ .a = a, .version = .container_fonts }; defer legacy_figure.deinit();
    try legacy_figure.figure(@as(?types.Figure, figure));
    figure.content.missing.label.link_paint = OrdinaryLinkPaintCodecTesting.paint();
    try std.testing.expect(types.validSpanLinkPaint(figure.content.missing.label));
    try std.testing.expectError(error.InvalidPresentation, encoder.figure(@as(?types.Figure, figure)));
    var plain: Encoder = .{ .a = a, .version = .container_fonts }; defer plain.deinit();
    const legacy: types.Span = .{ .kind = .link, .text = "legacy", .target = "Target" }; try plain.span(legacy);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = plain.out.items };
    try std.testing.expectEqualDeep(legacy, try reader.span());
}

test "M ordinary combined link states are mandatory and preserve the six state Figure prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const paint = OrdinaryLinkPaintCodecTesting.paint();
    var ordinary: Encoder = .{ .a = a, .version = .container_fonts }; defer ordinary.deinit(); try ordinary.linkPaint(paint);
    var figure: Encoder = .{ .a = a, .version = .container_fonts }; defer figure.deinit(); try figure.figureLinkPaint(paint.sixStatePrefix());
    try std.testing.expectEqualSlices(u8, figure.out.items, ordinary.out.items[0..figure.out.items.len]);
    var absent_combined: Reader = .{ .a = a, .version = .container_fonts, .bytes = figure.out.items };
    try std.testing.expectError(error.InvalidPresentation, absent_combined.linkPaint());
    var prefix_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = figure.out.items };
    try std.testing.expectEqualDeep(paint.sixStatePrefix(), (try prefix_reader.figureLinkPaint()).?);
    try std.testing.expectEqual(figure.out.items.len, prefix_reader.pos);
    const bad_color = try a.dupe(u8, ordinary.out.items); bad_color[figure.out.items.len + 5] = 'A';
    var color_reader: Reader = .{ .a = a, .version = .container_fonts, .bytes = bad_color };
    try std.testing.expectError(error.InvalidPresentation, color_reader.linkPaint());
}


const RuleCodecTest = struct {
    fn style() types.RuleStyle {
        const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
        return .{ .height = .{ .unit = .px, .value = 1 }, .fill = .{ .rgb = "#a2a9b1" },
            .margins = .{ .top = .{ .unit = .em, .value = 0.2 }, .right = zero, .bottom = .{ .unit = .em, .value = 0.2 }, .left = zero } };
    }
    fn block() types.Block { return .{ .kind = .rule, .rule_style = style() }; }
};

test "DPRN authored Rule advertises new capability and preserves every legacy null byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
    try old.block(types.Block{ .kind = .rule });
    const golden = [_]u8{ 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &golden, old.out.items);
    var n: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer n.deinit();
    try n.block(types.Block{ .kind = .rule });
    try std.testing.expectEqualSlices(u8, &golden, n.out.items[0..golden.len]);
    try std.testing.expectEqualSlices(u8, &.{0}, n.out.items[golden.len..]);
    var old_read: Reader = .{ .a = a, .version = .container_fonts, .bytes = &golden };
    try std.testing.expectEqualDeep(types.Block{ .kind = .rule }, try old_read.block());
    try std.testing.expectEqual(golden.len, old_read.pos);
    inline for (comptime std.meta.tags(Version)) |version| {
        var legacy: Encoder = .{ .a = a, .version = version }; defer legacy.deinit();
        try std.testing.expectError(error.InvalidPresentation, legacy.block(RuleCodecTest.block()));
    }
    const styled: types.Stored = .{ .entry = .{ .title = "rule", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{RuleCodecTest.block()} }} } };
    const bytes = try encodeAlloc(a, styled);
    try std.testing.expectEqualStrings(rule_styles_magic, bytes[0..4]);
    // The pre-extension closed-header reader recognizes only Version's old
    // magic set. N is not falsely advertised as any old reader capability.
    inline for (comptime std.meta.tags(Version)) |version| {
        try std.testing.expect(!std.mem.eql(u8, versionMagic(version), bytes[0..4]));
        const downgraded = try a.dupe(u8, bytes); @memcpy(downgraded[0..4], versionMagic(version));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, downgraded, "rule", .supplemental, null));
    }
    const null_stored: types.Stored = .{ .entry = .{ .title = "rule", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .rule }} }} } };
    const legacy_bytes = try encodeAlloc(a, null_stored);
    try std.testing.expectEqualStrings(magic, legacy_bytes[0..4]);
    const legacy_golden = [_]u8{
        68, 80, 82, 50, 0, 0, 0, 0, 1, 0, 0, 0, 2, 4, 0, 0,
        0, 98, 111, 100, 121, 1, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    try std.testing.expectEqualSlices(u8, &legacy_golden, legacy_bytes);
    try std.testing.expectEqualDeep(null_stored, try decodeAlloc(a, legacy_bytes, "rule", .supplemental, null));
    try std.testing.expectEqualSlices(u8, legacy_bytes, try encodeBuildAlloc(a, null_stored.entry.display_title,
        null_stored.entry.sections, null_stored.entry.organization, null_stored.entry.references, null_stored.entry.media));
}

test "DPRN Rule payload preserves zero theme colors and refuses truncation invalid data and mixed owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]types.ContainerColor{ .transparent, .{ .rgb = "#a2a9b1" }, .{ .light_dark = .{ .light = "#a2a9b1", .dark = "#54595d" } } }) |color| {
        var block = RuleCodecTest.block(); block.rule_style.?.fill = color;
        block.rule_style.?.height.value = 0;
        var writer: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer writer.deinit();
        try writer.block(block);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .bytes = writer.out.items };
        try std.testing.expectEqualDeep(block, try reader.block());
        try std.testing.expectEqual(writer.out.items.len, reader.pos);
        for (0..writer.out.items.len) |end| {
            var short: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .bytes = writer.out.items[0..end] };
            try std.testing.expectError(error.InvalidPresentation, short.block());
        }
    }
    var writer: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer writer.deinit();
    try writer.block(RuleCodecTest.block());
    // Independent M empty-rule prefix is29 bytes; N presence follows it,
    // then height unit/f32 and the ContainerColor tag.
    for ([_]struct { at: usize, value: u8 }{
        .{ .at = 29, .value = 2 }, .{ .at = 30, .value = 255 }, .{ .at = 35, .value = 255 },
        .{ .at = 34, .value = 0xbf }, // negative1 height
        .{ .at = 1, .value = 1 }, .{ .at = 2, .value = 1 },
        .{ .at = 40, .value = 'G' }, .{ .at = 47, .value = 255 }, .{ .at = 51, .value = 0xbe },
    }) |mutation| {
        const bad = try a.dupe(u8, writer.out.items); bad[mutation.at] = mutation.value;
        var reader: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    for ([_][4]u8{ .{ 0, 0, 128, 127 }, .{ 0, 0, 192, 127 } }) |nonfinite| {
        const bad = try a.dupe(u8, writer.out.items); @memcpy(bad[31..35], &nonfinite);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.block());
    }
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        var bad = RuleCodecTest.block(); bad.rule_style.?.margins.left.value = invalid;
        var rejected: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer rejected.deinit();
        try std.testing.expectError(error.InvalidPresentation, rejected.block(bad));
    }
    var bad = RuleCodecTest.block(); bad.kind = .paragraph;
    var rejected: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer rejected.deinit();
    try std.testing.expectError(error.InvalidPresentation, rejected.block(bad));
    bad = RuleCodecTest.block(); bad.figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } });
    try std.testing.expect(!types.validRuleStyleContext(bad));
    try std.testing.expectError(error.InvalidPresentation, rejected.block(bad));
    bad = RuleCodecTest.block(); bad.rule_style.?.fill = .{ .rgb = "#ABCDEF" };
    try std.testing.expectError(error.InvalidPresentation, rejected.block(bad));
}

test "DPRN Rule capability recursively follows existing body caption reference and flow sinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const rule = [_]types.Block{RuleCodecTest.block()};
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &rule }} }} };
    const table_caption: types.Table = .{ .caption_blocks = &rule };
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    var figure = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 20 } });
    figure.caption_blocks = &rule;
    const parts = [_]types.FlowPart{.{ .kind = .figure, .figure = figure }};
    const cases = [_]types.Entry{
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &rule }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "container", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &rule } }} }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = nested }} }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "table caption", .blocks = &.{.{ .kind = .table, .table = table_caption }} }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "figure caption", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "flow", .blocks = &.{.{ .kind = .paragraph, .flow = &parts }} }} },
        .{ .title = "rule", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "scope", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope,
            .scope = .{ .mode = .isolate, .authored_direction = .auto, .resolved_direction = .ltr, .parts = &parts } }} }} }} },
        .{ .title = "rule", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &rule }} },
    };
    for (cases) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .kind = .image, .file = "Figure.svg", .caption = "unchanged catalogue" }};
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(rule_styles_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "rule", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try types.validateStored(a, decoded, "rule", .supplemental, null);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections,
            entry.organization, entry.references, stored.entry.media));
    }
}

test "complete unknown DPR capability differs from malformed known and truncated framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "DPRQ", "DPRZ", "DPR0", "DPRQpayload" }) |bytes| {
        var metrics: DecodeMetrics = .{ .total_items = 99, .largest_string_bytes = 77 };
        try std.testing.expectError(error.UnsupportedPresentationVersion, decodeWithMetricsAlloc(a, bytes, "x", .supplemental, null, &metrics));
        try std.testing.expectEqual(@as(u64, 99), metrics.total_items);
        try std.testing.expectEqual(@as(usize, 77), metrics.largest_string_bytes);
    }
    for ([_][]const u8{ "", "D", "DP", "DPR", "XPRN", "DPNN", "{}" }) |bytes|
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes, "x", .supplemental, null));
    for ([_][]const u8{ magic, explained_magic, color_magic, anchor_magic, background_magic, nested_magic,
        cell_blocks_magic, reference_items_magic, font_scale_magic, font_scale_basis_magic, reference_blocks_magic,
        image_border_magic, block_layout_magic, explicit_targets_magic, dynamic_catalog_magic, tooltips_magic,
        block_geometry_magic, image_maps_magic, inline_table_styles_magic, block_containers_magic, container_fonts_magic, rule_styles_magic, inline_styles_magic }) |header|
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, header, "x", .supplemental, null));
    const bytes = try encodeAlloc(a, types.Stored{ .entry = .{ .title = "x", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{RuleCodecTest.block()} }} } });
    defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRN", bytes[0..4]);
    for (0..bytes.len) |end| try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0..end], "x", .supplemental, null));
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "x" }); defer a.free(trailing);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, trailing, "x", .supplemental, null));
}


const InlineStyleCodecTest = struct {
    fn span() types.Span {
        return .{ .kind = .external_link, .text = "Joyo", .target = "https://example.invalid/Joyo",
            .tooltip = "source title", .explanation = "source title", .underline = true,
            .inline_style = .{ .decoration = .{ .style = .dotted },
                .line_height = .{ .font_relative = .{ .factor = 1, .font = .{ .superscript = true,
                    .bold = true, .language = "ja", .classes = "Jpan", .role = .headword, .font_features = .seven_on } } } } };
    }
    fn stored(a: std.mem.Allocator, spans: []const types.Span) !types.Stored {
        // The returned fixture owns these runtime arrays beyond this call.
        const blocks = try a.dupe(types.Block, &.{.{ .kind = .paragraph, .spans = spans }, RuleCodecTest.block()});
        const sections = try a.dupe(types.Section, &.{.{ .level = 2, .title = "body", .blocks = blocks }});
        return .{ .entry = .{ .title = "inline", .kind = .supplemental, .sections = sections } };
    }
};

test "DPRO inline effects coexist with DPRN Rule and preserve null policy bytes and all source actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const span = InlineStyleCodecTest.span();
    const spans = [_]types.Span{span, .{ .superscript = true, .inline_style = .{
        .line_height = .{ .font_relative = .{ .factor = 1, .font = .{ .superscript = true } } } } }};
    const stored = try InlineStyleCodecTest.stored(a, &spans);
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(inline_styles_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "inline", .supplemental, null);
    try std.testing.expectEqualDeep(stored, decoded);
    try types.validateStored(a, decoded, "inline", .supplemental, null);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title,
        stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
    var old_span = span; old_span.inline_style = null;
    const null_bytes = try encodeAlloc(a, try InlineStyleCodecTest.stored(a, &.{old_span}));
    try std.testing.expectEqualStrings(rule_styles_magic, null_bytes[0..4]);
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
    var enabled: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true }; defer enabled.deinit();
    try old.span(old_span); try enabled.span(old_span);
    try std.testing.expectEqualSlices(u8, old.out.items, enabled.out.items);
    var refused: Encoder = .{ .a = a, .version = .container_fonts }; defer refused.deinit();
    try std.testing.expectError(error.InvalidPresentation, refused.span(span));
    for ([_][]const u8{ container_fonts_magic, rule_styles_magic }) |header| {
        const bad = try a.dupe(u8, bytes); @memcpy(bad[0..4], header);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, "inline", .supplemental, null));
    }
}

test "DPRO typed payload rejects unknown flags tags truncations and malformed span contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var writer: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer writer.deinit();
    const value = InlineStyleCodecTest.span().inline_style.?;
    try writer.inlineTextStyle(value);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = writer.out.items };
    try std.testing.expectEqualDeep(value, try reader.inlineTextStyle());
    try std.testing.expectEqual(writer.out.items.len, reader.pos);
    for (0..writer.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = writer.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.inlineTextStyle());
    }
    // flags, decoration enum, color presence, thickness presence, height tag.
    for ([_]struct { at: usize, value: u8 }{ .{ .at = 0, .value = 0 }, .{ .at = 0, .value = 16 },
        .{ .at = 1, .value = 255 }, .{ .at = 2, .value = 2 }, .{ .at = 3, .value = 2 }, .{ .at = 4, .value = 2 },
        .{ .at = 9, .value = 32 }, .{ .at = 10, .value = 16 } }) |mutation| {
        const bad = try a.dupe(u8, writer.out.items); bad[mutation.at] = mutation.value;
        var rejected: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, rejected.inlineTextStyle());
    }
    var bad_span = InlineStyleCodecTest.span(); bad_span.kind = .line_break;
    try std.testing.expectError(error.InvalidPresentation, writer.span(bad_span));
    bad_span = InlineStyleCodecTest.span(); bad_span.inline_style.?.font_normalized = true;
    try std.testing.expectError(error.InvalidPresentation, writer.span(bad_span));
    const normalized: types.Span = .{ .text = "7", .superscript = true, .font_scale = 0.8, .font_scale_basis = .normal_body,
        .inline_style = .{ .font_normalized = true, .baseline_shift = .{ .value = -2, .font_scale_basis = .css_px },
            .line_height = .{ .computed = .{ .value = 1.2, .font_scale_basis = .normal_body } } } };
    var normalized_writer: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer normalized_writer.deinit();
    try normalized_writer.span(normalized);
    var normalized_reader: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = normalized_writer.out.items };
    try std.testing.expectEqualDeep(normalized, try normalized_reader.span());
}

test "DPRO capability detection follows every existing recursive span sink" {
    const spans = [_]types.Span{InlineStyleCodecTest.span()};
    try std.testing.expect(hasInlineStyles(&spans, &.{}, &.{}, &.{}));
    try std.testing.expect(hasInlineStyles(&.{}, &.{}, &spans, &.{}));
    const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans }};
    const table: types.Table = .{ .caption = &spans, .rows = &.{.{ .cells = &.{.{ .spans = &spans, .blocks = &blocks }} }} };
    const cases = [_]types.Block{
        .{ .kind = .paragraph, .spans = &spans },
        .{ .kind = .container, .container = .{ .blocks = &blocks } },
        .{ .kind = .table, .table = table },
        .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } },
        .{ .kind = .paragraph, .flow = &.{.{ .kind = .@"inline", .spans = &spans }} },
    };
    for (cases) |block| try std.testing.expect(hasInlineStyles(&.{}, &[_]types.Section{.{ .level = 2, .title = "root", .blocks = &.{block} }}, &.{}, &.{}));
    try std.testing.expect(hasInlineStyles(&.{}, &.{}, &.{}, &[_]types.Reference{.{ .kind = .fragment, .number = 1, .group_number = null, .spans = &spans }}));
    try std.testing.expect(hasInlineStyles(&.{}, &.{}, &.{}, &[_]types.Reference{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &blocks }}));
}

test "inline owner context identity scale canonicalizes with its span across explicit baseline roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]types.FontScaleBasis{ .context, .normal_body }) |basis| {
        const value: types.Span = .{ .kind = .link, .text = "kept", .target = "Kept", .font_scale = 1, .font_scale_basis = basis,
            .superscript = true, .bold = true, .language = "ja", .classes = "Jpan", .role = .headword,
            .inline_style = .{ .baseline_shift = .{ .value = 2, .font_scale_basis = .css_px },
                .line_height = .{ .font_relative = .{ .factor = 1, .font = .{ .font_scale = 1, .font_scale_basis = basis,
                    .superscript = true, .bold = true, .language = "ja", .classes = "Jpan", .role = .headword } } } } };
        try std.testing.expect(types.validSpanInlineStyle(value));
        var writer: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer writer.deinit();
        try writer.span(value);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = writer.out.items };
        const decoded = try reader.span();
        var expected = value;
        if (basis == .context) {
            expected.font_scale = null;
            expected.inline_style.?.line_height.?.font_relative.font.font_scale = null;
        }
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqual(writer.out.items.len, reader.pos);
        var repeat: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer repeat.deinit();
        try repeat.span(decoded);
        try std.testing.expectEqualSlices(u8, writer.out.items, repeat.out.items);
    }
    // Match the existing span decoder's accepted noncanonical identity input.
    // The encoder above always emits the canonical absent context scale.
    var raw: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer raw.deinit();
    try raw.byte(1); try raw.writeU32(@bitCast(@as(f32, 1))); try raw.enumByte(types.FontScaleBasis, types.FontScaleBasis.context);
    try raw.byte(0); try raw.string(""); try raw.string(""); try raw.enumByte(types.Role, types.Role.normal);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = raw.out.items };
    const snapshot = try reader.inlineFontSnapshot();
    try std.testing.expect(snapshot.font_scale == null and snapshot.font_scale_basis == .context);
    try std.testing.expectEqual(raw.out.items.len, reader.pos);
}

test "DPRO authored Help cursor roundtrips without creating actions or changing null bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]types.Span{
        .{ .text = "plain", .explanation = "meaning" },
        .{ .kind = .link, .text = "linked", .target = "Kept", .tooltip = "meaning" },
        .{ .kind = .external_link, .text = "outside", .target = "https://example.invalid/", .underline = true },
    }) |original| {
        var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit(); try old.span(original);
        var enabled: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer enabled.deinit(); try enabled.span(original);
        try std.testing.expectEqualSlices(u8, old.out.items, enabled.out.items);
        var helped = original; helped.inline_style = .{ .cursor = .help };
        var writer: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer writer.deinit(); try writer.span(helped);
        var reader: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = writer.out.items };
        try std.testing.expectEqualDeep(helped, try reader.span());
        try std.testing.expectEqual(writer.out.items.len, reader.pos);
    }
    var policy: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true }; defer policy.deinit();
    try policy.inlineTextStyle(.{ .cursor = .help });
    try std.testing.expectEqualSlices(u8, &.{16, 0}, policy.out.items);
    for ([_][]const u8{ &.{16}, &.{16, 1}, &.{32, 0}, &.{0} }) |bytes| {
        var reader: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, reader.inlineTextStyle());
    }
}

const BodyAdjoiningCodecTest = struct {
    const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
    const text = [_]types.Span{.{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part" }};
    const sections = [_]types.Section{.{ .level = 2, .title = "", .blocks = &.{
        .{ .kind = .container, .container = .{ .style = .{ .float_side = .right,
            .height = .{ .unit = .px, .value = 40 },
            .width = .{ .length = .{ .unit = .px, .value = 40 } } },
            .blocks = &.{.{ .kind = .paragraph, .spans = &text }} } },
        .{ .kind = .paragraph, .spans = &text, .style = .{ .margins = .{
            .top = .{ .unit = .px, .value = 20 }, .right = zero,
            .bottom = .{ .unit = .px, .value = 30 }, .left = zero } } },
    } }};
};
test "DPRP ordinary body policy roundtrips every existing field and requires its closed tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const preamble = [_]types.Span{.{ .text = "outside preamble" }};
    const references = [_]types.Reference{.{ .kind = .fragment, .number = 1, .group_number = null,
        .spans = &.{.{ .kind = .external_link, .text = "outside reference", .target = "https://example.invalid/" }} }};
    const entry: types.Entry = .{ .title = "body", .kind = .citations, .body_adjoining = .ordinary,
        .display_title = &.{.{ .text = "display", .inline_style = .{ .cursor = .help } }},
        .preamble_spans = &preamble, .sections = &BodyAdjoiningCodecTest.sections, .references = &references };
    const bytes = try encodeAlloc(a, .{ .entry = entry });
    try std.testing.expectEqualStrings(body_adjoining_magic, bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 1), bytes[bytes.len - 1]);
    const decoded = try decodeAlloc(a, bytes, "body", .citations, null);
    try std.testing.expectEqualDeep(entry, decoded.entry);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    for ([_]u8{ 0, 2, 255 }) |invalid| {
        const bad = try a.dupe(u8, bytes); bad[bad.len - 1] = invalid;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, "body", .citations, null));
    }
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. bytes.len - 1], "body", .citations, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, try std.mem.concat(a, u8, &.{ bytes, &.{1} }), "body", .citations, null));
    // The old build API intentionally has no preamble. Compare its explicit
    // body-aware counterpart only to an independently absent-preamble Stored.
    var build_entry = entry; build_entry.preamble_spans = &.{};
    try std.testing.expectEqualSlices(u8, try encodeAlloc(a, .{ .entry = build_entry }),
        try encodeBuildWithBodyAdjoiningAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media, .ordinary));
}
test "DPRP null keeps exact prior headers payloads and mandatory capability rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: types.Entry = .{ .title = "body", .kind = .citations, .sections = &BodyAdjoiningCodecTest.sections };
    const bytes = try encodeAlloc(a, .{ .entry = old });
    var independent: Encoder = .{ .a = a, .version = .container_fonts }; defer independent.deinit();
    try independent.out.appendSlice(a, container_fonts_magic);
    try independent.spans(old.display_title); try independent.sections(old.sections); try independent.spans(old.preamble_spans);
    try independent.layout(old.organization); try independent.references(old.references); try independent.media(old.media);
    try std.testing.expectEqualSlices(u8, independent.out.items, bytes);
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildWithBodyAdjoiningAlloc(a,
        old.display_title, old.sections, old.organization, old.references, old.media, null));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a,
        old.display_title, old.sections, old.organization, old.references, old.media));
    try std.testing.expect((try decodeAlloc(a, bytes, "body", .citations, null)).entry.body_adjoining == null);
    for ([_][]const u8{ "DPRP", "DPRPpayload" }) |bad|
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, "body", .citations, null));
    try std.testing.expectError(error.UnsupportedPresentationVersion, decodeAlloc(a, "DPRS", "body", .citations, null));
}

const StyledSectionCodecTest = struct {
    const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
    const edges: types.StyleEdges = .{ .top = zero, .right = zero, .bottom = zero, .left = zero };
    const style: types.SectionHeadingStyle = .{
        .box = .{ .margins = edges, .padding = edges, .border = .none, .owner_font_scale = 1.5,
            .line_height = .{ .multiplier = 1.375 }, .clear = .none,
            .font_family = .{ .stack = .{ .names = &.{ "Linux Libertine", "Georgia", "Times", "Source Serif 4" }, .fallback = .serif } } },
        .font = .{ .font_scale = 1.5, .font_scale_basis = .normal_body, .language = "th" }, .direction = .ltr,
    };
    const sections = [_]types.Section{
        .{ .level = 2, .title = "Language", .anchor = "Language", .anchor_fallback = "Legacy", .heading_style = style, .blocks = &.{
            .{ .kind = .heading, .level = 2, .anchor = "Language", .anchor_fallback = "Legacy", .spans = &.{ .{ .kind = .link, .text = "Lang", .target = "Kept", .target_fragment = "part" }, .{ .text = "uage" } } },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "same body" }} },
        } },
        .{ .level = 3, .title = "Next", .anchor = "Next", .heading_style = style, .blocks = &.{
            .{ .kind = .heading, .level = 3, .anchor = "Next", .spans = &.{.{ .text = "Next" }} },
        } },
    };
    const entry: types.Entry = .{ .title = "heading", .kind = .citations, .sections = &sections,
        .organization = .{ .other_sections = &.{ 0, 1 } }, .preamble_spans = &.{.{ .text = "outside preamble" }},
        .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null,
            .spans = &.{.{ .kind = .external_link, .text = "reference", .target = "https://example.invalid/" }} }} };
    fn tail(a: A, payload: []const u8) !usize {
        var reader: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true,
            .capability_p = true, .bytes = payload, .pos = 4 };
        _ = try reader.spans(); _ = try reader.sections(); _ = try reader.spans();
        _ = try reader.layout(); _ = try reader.references(); _ = try reader.media();
        return reader.pos;
    }
};
test "DPRP styled headings preserve every companion action owner and independent feature combination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var entry = StyledSectionCodecTest.entry;
    const encoded = try encodeAlloc(a, .{ .entry = entry });
    try std.testing.expectEqualStrings(body_adjoining_magic, encoded[0..4]);
    try std.testing.expectEqual(@as(u8, 6), encoded[try StyledSectionCodecTest.tail(a, encoded)]);
    const decoded = try decodeAlloc(a, encoded, entry.title, entry.kind, null);
    try std.testing.expectEqualDeep(entry, decoded.entry);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    var no_preamble = entry; no_preamble.preamble_spans = &.{};
    try std.testing.expectEqualSlices(u8, try encodeAlloc(a, .{ .entry = no_preamble }),
        try encodeBuildWithBodyAdjoiningAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media, null));
    for ([_]bool{ false, true }) |ordinary| {
        entry.body_adjoining = if (ordinary) .ordinary else null;
        const bytes = try encodeAlloc(a, .{ .entry = entry });
        try std.testing.expectEqual(@as(u8, if (ordinary) 7 else 6), bytes[try StyledSectionCodecTest.tail(a, bytes)]);
        try std.testing.expectEqualDeep(entry, (try decodeAlloc(a, bytes, entry.title, entry.kind, null)).entry);
        var sections = StyledSectionCodecTest.sections;
        for (&sections) |*section| section.heading_style.?.box.font_family = .sans_serif;
        entry.sections = &sections;
        const generic = try encodeAlloc(a, .{ .entry = entry });
        try std.testing.expectEqual(@as(u8, if (ordinary) 3 else 2), generic[try StyledSectionCodecTest.tail(a, generic)]);
        try std.testing.expectEqualDeep(entry, (try decodeAlloc(a, generic, entry.title, entry.kind, null)).entry);
        entry.sections = &StyledSectionCodecTest.sections;
    }
    const body_sections = [_]types.Section{.{ .level = 2, .title = "", .blocks = &.{.{ .kind = .container, .container = .{
        .style = .{ .font_family = StyledSectionCodecTest.style.box.font_family },
        .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "owner" }} }},
    } }} }};
    entry = .{ .title = "heading", .kind = .citations, .sections = &body_sections };
    for ([_]bool{ false, true }) |ordinary| {
        entry.body_adjoining = if (ordinary) .ordinary else null;
        const bytes = try encodeAlloc(a, .{ .entry = entry });
        try std.testing.expectEqual(@as(u8, if (ordinary) 5 else 4), bytes[try StyledSectionCodecTest.tail(a, bytes)]);
        try std.testing.expectEqualDeep(entry, (try decodeAlloc(a, bytes, entry.title, entry.kind, null)).entry);
    }
}
test "DPRP indexed heading trailer refuses orphan duplicate unordered unknown and truncated capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const entry = StyledSectionCodecTest.entry;
    const bytes = try encodeAlloc(a, .{ .entry = entry }); const tail = try StyledSectionCodecTest.tail(a, bytes);
    for ([_]u8{ 0, 2, 4, 8, 128, 255 }) |flags| {
        const bad = try a.dupe(u8, bytes); bad[tail] = flags;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, entry.title, entry.kind, null));
    }
    for (tail..bytes.len) |end| try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0..end], entry.title, entry.kind, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, try std.mem.concat(a, u8, &.{bytes, "x"}), entry.title, entry.kind, null));
    var reader: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true,
        .capability_p = true, .bytes = bytes, .pos = tail + 1 };
    try std.testing.expectEqual(@as(usize, 2), try reader.count(4));
    const first_index = reader.pos; _ = try reader.index(); _ = try reader.containerStyle(); _ = try reader.inlineFontSnapshot(); _ = try reader.enumValue(types.BidiResolvedDirection);
    const second_index = reader.pos;
    for (0..3) |mutation| {
        const bad = try a.dupe(u8, bytes);
        switch (mutation) {
            0 => std.mem.writeInt(u32, bad[second_index..][0..4], 0, .little),
            1 => { std.mem.writeInt(u32, bad[first_index..][0..4], 1, .little); std.mem.writeInt(u32, bad[second_index..][0..4], 0, .little); },
            2 => std.mem.writeInt(u32, bad[first_index..][0..4], 2, .little),
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, entry.title, entry.kind, null));
    }
    for ([_][]const u8{ container_fonts_magic, rule_styles_magic, inline_styles_magic }) |header| {
        const bad = try a.dupe(u8, bytes); @memcpy(bad[0..4], header);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, entry.title, entry.kind, null));
    }
}
test "ordered Container font payload preserves HU zero and requires the explicit P family capability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
    try old.containerStyle(.{ .font_family = .sans_serif });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x40, 0, 0 }, old.out.items);
    var legacy: Reader = .{ .a = a, .version = .container_fonts, .bytes = old.out.items };
    try std.testing.expectEqualDeep(@as(types.ContainerStyle, .{ .font_family = .sans_serif }), try legacy.containerStyle());
    var named: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer named.deinit();
    const value: types.ContainerStyle = .{ .font_family = .{ .stack = .{ .names = &.{"Georgia"}, .fallback = .serif } } };
    try named.containerStyle(value);
    var read: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = named.out.items };
    try std.testing.expectEqualDeep(value, try read.containerStyle());
    var denied: Reader = .{ .a = a, .version = .container_fonts, .bytes = named.out.items };
    try std.testing.expectError(error.InvalidPresentation, denied.containerStyle());
    for (0..4) |mutation| {
        const bad = try a.dupe(u8, named.out.items);
        switch (mutation) {
            0 => bad[4] = 255,
            1 => std.mem.writeInt(u32, bad[5..][0..4], 17, .little),
            2 => bad[13] = 0,
            3 => bad[bad.len - 1] = 255,
            else => unreachable,
        }
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, invalid.containerStyle());
    }
}

test "P generic Span and independent snapshot family each require feature four without dropping text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const variants = [_]types.Span{
        .{ .kind = .link, .text = " kept\xc2\xa0 ", .target = "Kept", .target_fragment = "part", .font_family = .sans_serif },
        .{ .text = "declared", .inline_style = .{ .line_height = .{ .font_relative = .{ .factor = 1,
            .font = .{ .font_family = .sans_serif } } } } },
    };
    for (variants) |span| {
        const entry: types.Entry = .{ .title = "families", .kind = .citations, .display_title = &.{span} };
        const bytes = try encodeAlloc(a, .{ .entry = entry });
        const tail = try StyledSectionCodecTest.tail(a, bytes);
        try std.testing.expectEqualStrings(body_adjoining_magic, bytes[0..4]);
        try std.testing.expectEqual(@as(u8, 4), bytes[tail]);
        try std.testing.expectEqualDeep(entry, (try decodeAlloc(a, bytes, entry.title, entry.kind, null)).entry);
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildWithBodyAdjoiningAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media, null));
        for ([_]u8{ 0, 1, 2, 8 }) |flags| {
            const invalid = try a.dupe(u8, bytes); invalid[tail] = flags;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invalid, entry.title, entry.kind, null));
        }
        for ([_][]const u8{ container_fonts_magic, rule_styles_magic, inline_styles_magic }) |header| {
            const invalid = try a.dupe(u8, bytes); @memcpy(invalid[0..4], header);
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invalid, entry.title, entry.kind, null));
        }
    }
    const hani: types.ContainerFontFamily = .{ .stack = .{ .names = &.{ "BabelStone Han", "PingFang TC", "Source Han Sans TC", "Source Han Sans TW", "Noto Sans CJK TC", "Microsoft Jhenghei", "MOESongUN", "PMingLiU", "PMingLiU-ExtB", "MingLiU", "MingLiU-ExtB", "Ming", "Heiti TC", "HanaMinA", "HanaMinB" }, .fallback = .sans_serif } };
    const glyph: types.Span = .{ .text = "\xe9\x96\x93", .font_scale = 1.2, .font_scale_basis = .normal_body, .font_family = hani,
        .inline_style = .{ .line_height = .{ .font_relative = .{ .factor = 1, .font = .{
            .font_scale = 1.2, .font_scale_basis = .normal_body, .language = "th", .font_family = hani } } } } };
    const sections = [_]types.Section{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .table, .table = .{
        .style = .{ .float_side = .right, .width = .{ .unit = .em, .value = 25 } },
        .caption = &.{variants[1]}, .rows = &.{.{ .cells = &.{.{ .spans = &.{glyph} }} }},
    } }} }};
    const entry: types.Entry = .{ .title = "families", .kind = .citations, .sections = &sections, .preamble_spans = &.{variants[0]} };
    const encoded = try encodeAlloc(a, .{ .entry = entry });
    const decoded = try decodeAlloc(a, encoded, entry.title, entry.kind, null);
    try std.testing.expectEqualDeep(entry, decoded.entry);
    try std.testing.expectEqual(@as(usize, 15), decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].spans[0].font_family.?.stack.names.len);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    // This is controlled transport data, not a responsive Table/source-cut grant.
}
test "P inline family masks preserve old absence and refuse unknown or incomplete Span and snapshot payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const span: types.Span = .{ .text = "x", .font_family = .sans_serif };
    var encoded: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true, .capability_p = true }; defer encoded.deinit();
    try encoded.span(span);
    const field = encoded.out.items.len - 5;
    try std.testing.expectEqualSlices(u8, &.{ 16, 0, 0, 0, 0 }, encoded.out.items[field..]);
    var accepted: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true, .capability_p = true, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(span, try accepted.span());
    var old: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true, .bytes = encoded.out.items };
    try std.testing.expectError(error.InvalidPresentation, old.span());
    for (0..2) |mutation| {
        const invalid = try a.dupe(u8, encoded.out.items); invalid[field + mutation] = if (mutation == 0) 32 else 255;
        var read: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .inline_styles = true, .capability_p = true, .bytes = invalid };
        try std.testing.expectError(error.InvalidPresentation, read.span());
    }
    const font: types.InlineFontSnapshot = .{ .font_features = .seven_on, .font_family = .sans_serif };
    var snapshot: Encoder = .{ .a = a, .version = .container_fonts, .inline_styles = true, .capability_p = true }; defer snapshot.deinit();
    try snapshot.inlineFontSnapshot(font);
    try std.testing.expectEqual(@as(u8, 24), snapshot.out.items[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, snapshot.out.items[snapshot.out.items.len - 2..]);
    var matched: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .capability_p = true, .bytes = snapshot.out.items };
    try std.testing.expectEqualDeep(font, try matched.inlineFontSnapshot());
    var denied: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .bytes = snapshot.out.items };
    try std.testing.expectError(error.InvalidPresentation, denied.inlineFontSnapshot());
    for (0..2) |mutation| {
        const invalid = try a.dupe(u8, snapshot.out.items);
        if (mutation == 0) invalid[1] |= 32 else invalid[invalid.len - 1] = 255;
        var read: Reader = .{ .a = a, .version = .container_fonts, .inline_styles = true, .capability_p = true, .bytes = invalid };
        try std.testing.expectError(error.InvalidPresentation, read.inlineFontSnapshot());
    }
}

test "P responsive Table clear keeps existing width payload and derives every feature combination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for (0..8) |features| {
        var table = FloatViewportCodecTest.table();
        table.style.?.width = .{ .unit = .em, .value = 25 };
        table.float_viewport.?.narrow_clear = .both;
        var cell_spans = [_]types.Span{.{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part" }};
        if (features & 4 != 0) cell_spans[0].font_family = .sans_serif;
        table.rows = &.{.{ .cells = &.{.{ .spans = &cell_spans }} }};
        var heading = StyledSectionCodecTest.sections[0];
        heading.heading_style.?.box.font_family = .sans_serif;
        const sections = [_]types.Section{ .{ .level = 0, .title = "", .blocks = &.{.{ .kind = .table, .table = table }} }, heading };
        const entry: types.Entry = .{ .title = "prefix", .kind = .citations,
            .sections = sections[0..(if (features & 2 != 0) @as(usize, 2) else 1)],
            .body_adjoining = if (features & 1 != 0) .ordinary else null };
        const bytes = try encodeAlloc(a, .{ .entry = entry });
        const tail = try StyledSectionCodecTest.tail(a, bytes);
        try std.testing.expectEqualStrings(body_adjoining_magic, bytes[0..4]);
        try std.testing.expectEqual(@as(u8, @intCast(features | 8)), bytes[tail]);
        const decoded = try decodeAlloc(a, bytes, entry.title, entry.kind, null);
        try std.testing.expectEqualDeep(entry, decoded.entry);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildWithBodyAdjoiningAlloc(a, entry.display_title,
            entry.sections, entry.organization, entry.references, entry.media, entry.body_adjoining));
        for ([_]f32{ 638.5, 639, 639.5, 900 }) |viewport| {
            const selected = (try types.resolveTableFloatStyle(decoded.entry.sections[0].blocks[0].table.?, viewport)).?;
            try std.testing.expectEqual(@as(f32, 25), selected.width.?.value);
            try std.testing.expectEqual(types.StyleWidthUnit.em, selected.width.?.unit);
            try std.testing.expectEqual(@as(?types.FigureClear, if (viewport <= 639) .both else .right), selected.clear);
            try std.testing.expectEqual(@as(?types.TableFloatSide, if (viewport <= 639) null else .right), selected.float_side);
        }
        const missing = try a.dupe(u8, bytes); missing[tail] &= 7;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, missing, entry.title, entry.kind, null));
        const unknown = try a.dupe(u8, bytes); unknown[tail] |= 16;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, entry.title, entry.kind, null));
    }
    var nested = FloatViewportCodecTest.table(); nested.float_viewport.?.narrow_clear = .none;
    const entry: types.Entry = .{ .title = "nested", .kind = .citations, .references = &.{.{ .kind = .fragment,
        .number = 1, .group_number = null, .blocks = &.{.{ .kind = .container, .container = .{
            .style = .{}, .blocks = &.{.{ .kind = .table, .table = nested }},
        } }} }} };
    const bytes = try encodeAlloc(a, .{ .entry = entry });
    try std.testing.expectEqual(@as(u8, 8), bytes[try StyledSectionCodecTest.tail(a, bytes)]);
    try std.testing.expectEqualDeep(entry, (try decodeAlloc(a, bytes, entry.title, entry.kind, null)).entry);
}
test "P responsive Table clear tag thirteen is strict and old tag five stays exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var value = FloatViewportCodecTest.table();
    var prior: Encoder = .{ .a = a, .version = .container_fonts }; defer prior.deinit();
    try prior.table(@as(?types.Table, value));
    try std.testing.expectEqual(@as(u8, 5), prior.out.items[0]);
    var absent: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer absent.deinit();
    try absent.table(@as(?types.Table, value));
    try std.testing.expectEqualSlices(u8, prior.out.items, absent.out.items);
    value.float_viewport.?.narrow_clear = .both;
    var current: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer current.deinit();
    try current.table(@as(?types.Table, value));
    try std.testing.expectEqual(@as(u8, 13), current.out.items[0]);
    try std.testing.expectEqualSlices(u8, prior.out.items[1..], current.out.items[1..current.out.items.len - 1]);
    try std.testing.expectEqual(@as(u8, 3), current.out.items[current.out.items.len - 1]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = current.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, value), try reader.table());
    reader = .{ .a = a, .version = .container_fonts, .bytes = current.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.table());
    reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = current.out.items[0..current.out.items.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, reader.table());
    for (0..2) |mutation| {
        const bad = try a.dupe(u8, current.out.items);
        if (mutation == 0) bad[bad.len - 1] = 4 else bad[0] = 9;
        reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, reader.table());
    }
}

test "Section decoder initializes absent heading styles with poisoned backing for legacy and mixed P records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const plain: types.Entry = .{ .title = "poison", .kind = .citations, .sections = &.{
        .{ .level = 0, .title = "", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "prefix" }} }} },
        .{ .level = 2, .title = "tail", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "tail", .target = "Kept" }} }} },
    } };
    var body_only = plain; body_only.body_adjoining = .ordinary;
    const mixed: types.Entry = .{ .title = "poison", .kind = .citations,
        .sections = &.{ plain.sections[0], StyledSectionCodecTest.sections[0], plain.sections[1] } };
    var mixed_body = mixed; mixed_body.body_adjoining = .ordinary;
    for ([_]types.Entry{ plain, body_only, mixed, mixed_body }) |entry| {
        const encoded = try encodeAlloc(a, .{ .entry = entry });
        for ([_]u8{ 0xa5, 0xff }) |poison| {
            var memory: [128 * 1024]u8 = undefined;
            @memset(&memory, poison);
            // This precondition is about raw backing only. Allocator.alloc
            // may overwrite its result with undefined; never read that as a
            // promise that a typed allocation preserves these poison bytes.
            for (memory[0 .. @sizeOf(types.Section) * entry.sections.len]) |byte|
                try std.testing.expectEqual(poison, byte);
            var fixed = std.heap.FixedBufferAllocator.init(&memory);
            const decoded = try decodeAlloc(fixed.allocator(), encoded, entry.title, entry.kind, null);
            try std.testing.expectEqualDeep(entry, decoded.entry);
            try std.testing.expect(decoded.entry.sections[0].heading_style == null);
            try std.testing.expect(decoded.entry.sections[decoded.entry.sections.len - 1].heading_style == null);
            if (entry.sections.len == 3) {
                try std.testing.expectEqualDeep(StyledSectionCodecTest.style, decoded.entry.sections[1].heading_style.?);
                try std.testing.expectEqualStrings("Kept", decoded.entry.sections[1].blocks[0].spans[0].target);
            }
            try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
        }
    }
}

const BlockMediaCodecFixture = struct {
    fn figure() types.Figure {
        var value = FigureCodecFixture.make(.{ .kind = .text, .image = .{ .file = "controlled-block.svg", .width_px = 44, .height_px = 40, .alt = "complete alt" } });
        value.placement = .none; value.clear = .none;
        value.margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }); value.image_insets = value.margins; value.caption_padding = value.margins;
        value.frame_background = .{ .kind = .transparent }; value.image_background = .{ .kind = .transparent }; value.caption_background = .{ .kind = .transparent };
        value.block_media_layout = .{ .wrapper = .{ .width = .auto, .margins = value.margins, .line_height = .{ .multiplier = 1.5 }, .text_align = .left, .owner_font_scale = 1 },
            .media = .{ .strut = .{ .font_scale = 1, .direction = .ltr }, .vertical_align = .middle,
                .max_width = .{ .percent = 100, .subtract = .{ .unit = .px, .value = 0 } } },
            .preferred_width_px = 44, .natural_width = 120, .natural_height = 110,
            .rendition_1x = .{ .url = "https://example.test/controlled-1x.png", .sha256 = "1111111111111111111111111111111111111111111111111111111111111111" },
            .rendition_2x = .{ .url = "https://example.test/controlled-2x.png", .sha256 = "2222222222222222222222222222222222222222222222222222222222222222" } };
        return value;
    }
};

test "M Figure block media tag preserves legacy bytes and rejects truncated or foreign tails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const value = BlockMediaCodecFixture.figure();
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
    try encoder.figure(@as(?types.Figure, value));
    try std.testing.expectEqual(@as(u8, 7), encoder.out.items[0]);
    var reader: Reader = .{ .a = a, .bytes = encoder.out.items, .version = .container_fonts };
    try std.testing.expectEqualDeep(value, (try reader.figure()).?);
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());
    for (0..encoder.out.items.len) |end| {
        var truncated: Reader = .{ .a = a, .bytes = encoder.out.items[0..end], .version = .container_fonts };
        try std.testing.expectError(error.InvalidPresentation, truncated.figure());
    }
    var unknown = try a.dupe(u8, encoder.out.items); unknown[0] = 8;
    var unknown_reader: Reader = .{ .a = a, .bytes = unknown, .version = .container_fonts };
    try std.testing.expectError(error.InvalidPresentation, unknown_reader.figure());
    var old_reader: Reader = .{ .a = a, .bytes = encoder.out.items, .version = .image_maps };
    try std.testing.expectError(error.InvalidPresentation, old_reader.figure());
    var legacy = value; legacy.block_media_layout = null;
    var legacy_a: Encoder = .{ .a = a, .version = .container_fonts }; defer legacy_a.deinit();
    try legacy_a.figure(@as(?types.Figure, legacy));
    try std.testing.expectEqual(@as(u8, 1), legacy_a.out.items[0]);
    // Tag7 adds a required tail after the unchanged complete M image payload.
    // Older versions have their own Span encodings and are not byte aliases.
    try std.testing.expect(encoder.out.items.len > legacy_a.out.items.len);
    try std.testing.expectEqualSlices(u8, legacy_a.out.items[1..], encoder.out.items[1..legacy_a.out.items.len]);
}

test "M block media retains complete recursive Stored build JSON body actions and viewport line context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var value = BlockMediaCodecFixture.figure();
    var narrow = value.block_media_layout.?.wrapper; narrow.line_height = .{ .length = .{ .unit = .px, .value = 24 } }; narrow.text_align = .center;
    const states = [_]types.FigureBlockMediaState{.{ .max_width_px = 639, .wrapper = narrow, .media = value.block_media_layout.?.media }};
    value.block_media_layout.?.viewport_states = &states;
    const image: types.Block = .{ .kind = .paragraph, .figure = value };
    const sibling: types.Block = .{ .kind = .paragraph, .spans = &.{.{ .kind = .external_link, .target = "https://example.test/", .text = "retained action", .foreground = "#3366cc" }} };
    const entries = [_]types.Entry{
        .{ .title = "block", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{image, sibling} }} },
        .{ .title = "block", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &.{image, sibling} }} }} } }} }} },
        .{ .title = "block", .kind = .supplemental, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{image, sibling} }} },
    };
    for (entries) |source_entry| {
        var entry = source_entry;
        entry.media = &.{.{ .file = "controlled-block.svg", .kind = .image, .caption = "complete alt" }};
        const stored: types.Stored = .{ .entry = entry };
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(container_fonts_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
}

test "M block raster hashes survive recursive ownership and reject corrupted required identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const good = BlockMediaCodecFixture.figure();
    var encoder: Encoder = .{ .a = a, .version = .container_fonts }; defer encoder.deinit();
    try encoder.figure(@as(?types.Figure, good));
    const hash = good.block_media_layout.?.rendition_2x.sha256;
    const at = std.mem.indexOf(u8, encoder.out.items, hash) orelse return error.TestUnexpectedResult;
    var damaged = try a.dupe(u8, encoder.out.items); damaged[at] = 'G';
    var reader: Reader = .{ .a = a, .bytes = damaged, .version = .container_fonts };
    try std.testing.expectError(error.InvalidPresentation, reader.figure());
    var no_identity = good; no_identity.block_media_layout.?.rendition_1x.url = "";
    var rejected: Encoder = .{ .a = a, .version = .container_fonts }; defer rejected.deinit();
    try std.testing.expectError(error.InvalidPresentation, rejected.figure(@as(?types.Figure, no_identity)));
}

const PairedTableScrollCodecTest = struct {
    fn block() types.TableBlockViewport {
        return .{ .max_viewport_width_px = 639, .box_style = .{
            .margins = types.StyleEdges.all(.{ .unit = .em, .value = 0 }), .clear = .right,
            .padding = types.StyleEdges.all(.{ .unit = .px, .value = 0 }),
        }, .box_sizing = .border_box, .max_width = .{ .unit = .percent, .value = 100 },
            .grid_style = .{ .collapse = .collapse }, .grid_direction = .ltr, .language = "de", .focus_paint = .{ .mode = .ua_auto, .color = .{ .kind = .rgb, .value = "#3366cc" } } };
    }
    fn table(narrow: *const types.TableBlockViewport) types.Table {
        var value = FloatViewportCodecTest.table(); value.block_viewport = narrow;
        value.rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part" }} }} }};
        value.float_viewport.?.grid_direction = narrow.grid_direction;
        value.float_viewport.?.language = narrow.language;
        return value;
    }
};
test "P paired Table scroll uses explicit bit thirty two and preserves complete Stored recursively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const block = PairedTableScrollCodecTest.block(); const table = PairedTableScrollCodecTest.table(&block);
    const nested: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} };
    for (0..3) |owner| {
        const table_block: types.Block = .{ .kind = .table, .table = if (owner == 1) nested else table };
        const blocks = [_]types.Block{table_block};
        const entry: types.Entry = .{ .title = "paired", .kind = .citations,
            .sections = if (owner == 2) &.{} else &.{.{ .level = 0, .title = "", .blocks = &blocks }},
            .references = if (owner == 2) &.{.{ .kind = .fragment, .number = 1, .group_number = null,
                .blocks = &.{.{ .kind = .container, .container = .{ .style = .{}, .blocks = &blocks } }} }} else &.{} };
        const bytes = try encodeAlloc(a, .{ .entry = entry });
        const tail = try StyledSectionCodecTest.tail(a, bytes);
        try std.testing.expectEqualStrings(body_adjoining_magic, bytes[0..4]);
        try std.testing.expectEqual(@as(u8, 32), bytes[tail]);
        const decoded = try decodeAlloc(a, bytes, entry.title, entry.kind, null);
        try std.testing.expectEqualDeep(entry, decoded.entry);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildWithBodyAdjoiningAlloc(a, entry.display_title,
            entry.sections, entry.organization, entry.references, entry.media, entry.body_adjoining));
        const omitted = try a.dupe(u8, bytes); omitted[tail] = 1;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, omitted, entry.title, entry.kind, null));
        const unknown = try a.dupe(u8, bytes); unknown[tail] |= 64;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, entry.title, entry.kind, null));
        const old = try a.dupe(u8, bytes); @memcpy(old[0..4], container_fonts_magic);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, entry.title, entry.kind, null));
    }
}
test "P paired Table tag seven refuses earlier header truncated pair and inconsistent thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var block = PairedTableScrollCodecTest.block(); const value = PairedTableScrollCodecTest.table(&block);
    var current: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer current.deinit();
    try current.table(@as(?types.Table, value));
    try std.testing.expectEqual(@as(u8, 7), current.out.items[0]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = current.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, value), try reader.table());
    var old: Encoder = .{ .a = a, .version = .container_fonts }; defer old.deinit();
    try std.testing.expectError(error.InvalidPresentation, old.table(@as(?types.Table, value)));
    reader = .{ .a = a, .version = .container_fonts, .bytes = current.out.items };
    try std.testing.expectError(error.InvalidPresentation, reader.table());
    for (0..current.out.items.len) |length| {
        reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = current.out.items[0..length] };
        try std.testing.expectError(error.InvalidPresentation, reader.table());
    }
    block.max_viewport_width_px = 638;
    try std.testing.expectError(error.InvalidPresentation, current.table(@as(?types.Table, value)));
    var legacy = value; legacy.block_viewport = null;
    var original: Encoder = .{ .a = a, .version = .container_fonts }; defer original.deinit();
    var absent: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer absent.deinit();
    try original.table(@as(?types.Table, legacy)); try absent.table(@as(?types.Table, legacy));
    try std.testing.expectEqualSlices(u8, original.out.items, absent.out.items);
}

test "paired scroll focus tail rejects missing invalid mode presence and color on none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var policy = PairedTableScrollCodecTest.block(); policy.focus_paint = .{ .mode = .authored_none };
    var encoded: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer encoded.deinit();
    try encoded.tableBlockViewportIn(policy, true);
    const end = encoded.out.items.len;
    try std.testing.expectEqualSlices(u8, &.{0, 0}, encoded.out.items[end - 2 ..]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = encoded.out.items };
    try std.testing.expectEqualDeep(policy, (try reader.tableBlockViewportIn(true)).*);
    for (0..4) |mutation| {
        const bytes = try a.dupe(u8, encoded.out.items);
        if (mutation == 0) bytes[end - 2] = 2 else if (mutation == 1) bytes[end - 1] = 2;
        reader = .{ .a = a, .version = .container_fonts, .capability_p = true,
            .bytes = bytes[0 .. if (mutation >= 2) end - (mutation - 1) else end] };
        try std.testing.expectError(error.InvalidPresentation, reader.tableBlockViewportIn(true));
    }
    policy.focus_paint.?.color = .{ .kind = .rgb, .value = "#3366cc" };
    try std.testing.expectError(error.InvalidPresentation, encoded.tableBlockViewportIn(policy, true));
}

const CellOwnerFontCodecTest = struct {
    const font: types.InlineFontSnapshot = .{ .font_scale = 1.1, .font_scale_basis = .normal_body,
        .bold = true, .language = "th", .font_features = .seven_on,
        .font_family = .{ .stack = .{ .names = &.{"Owner Face"}, .fallback = .sans_serif } } };
    const policy: types.CellLineHeight = .{ .strut = .{ .font_scale = 1.1, .font_scale_basis = .normal_body, .owner_font = font }, .height = .normal };
    const table: types.Table = .{ .rows = &.{.{ .cells = &.{
        .{ .style = .{ .line_height = policy }, .spans = &.{.{ .kind = .link, .text = "child", .target = "Kept", .trail = "s",
            .target_fragment = "part", .italic = true, .font_scale = 0.8, .font_scale_basis = .normal_body, .language = "en" }} },
        .{ .style = .{ .line_height = .{ .strut = .{ .font_scale = 0, .font_scale_basis = .css_px }, .height = .normal } }, .spans = &.{} },
        .{ .spans = &.{.{ .text = "neighbor" }} },
    } }} };
};

test "P cell owner font stores one size and rejects duplicate malformed and legacy payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const value = CellOwnerFontCodecTest.policy;
    var wire: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer wire.deinit();
    try wire.cellLineHeight(value);
    try std.testing.expectEqual(@as(u8, 2), wire.out.items[0]);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.1))), std.mem.readInt(u32, wire.out.items[1..5], .little));
    try std.testing.expectEqual(@as(u8, @intFromEnum(types.FontScaleBasis.normal_body)), wire.out.items[5]);
    try std.testing.expectEqual(@as(u8, 0), wire.out.items[6]);
    var expected_snapshot: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer expected_snapshot.deinit();
    var unsized = value.strut.?.owner_font.?; unsized.font_scale = null; unsized.font_scale_basis = .context;
    try expected_snapshot.inlineFontSnapshot(unsized);
    try std.testing.expectEqualSlices(u8, expected_snapshot.out.items, wire.out.items[6 .. wire.out.items.len - 1]);
    var read: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = wire.out.items };
    try std.testing.expectEqualDeep(value, try read.cellLineHeight());
    try std.testing.expectEqual(wire.out.items.len, read.pos);
    inline for (comptime std.meta.tags(Version)) |version| {
        var old: Encoder = .{ .a = a, .version = version }; defer old.deinit();
        try std.testing.expectError(error.InvalidPresentation, old.cellLineHeight(value));
        var denied: Reader = .{ .a = a, .version = version, .bytes = wire.out.items };
        try std.testing.expectError(error.InvalidPresentation, denied.cellLineHeight());
    }
    for (0..wire.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = wire.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.cellLineHeight());
    }
    for ([_]struct { at: usize, value: u8 }{
        .{ .at = 0, .value = 3 }, .{ .at = 5, .value = 255 },
        .{ .at = 6, .value = 2 }, .{ .at = 7, .value = 0xff },
    }) |mutation| {
        const bad = try a.dupe(u8, wire.out.items); bad[mutation.at] = mutation.value;
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, invalid.cellLineHeight());
    }
    // A complete redundant size encoding must fail even if it agrees, including
    // the old contextual identity that inlineFontSnapshot normally canonicalizes.
    for ([_]types.InlineFontSnapshot{ value.strut.?.owner_font.?, .{ .font_scale = 1, .font_scale_basis = .context,
        .bold = true, .language = "th", .font_features = .seven_on, .font_family = .sans_serif } }) |duplicate| {
        var bad: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer bad.deinit();
        try bad.out.appendSlice(a, wire.out.items[0..6]);
        if (duplicate.font_scale_basis == .context) {
            var raw_snapshot: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer raw_snapshot.deinit();
            var without_size = duplicate; without_size.font_scale = null;
            try raw_snapshot.inlineFontSnapshot(without_size);
            try bad.byte(raw_snapshot.out.items[0] | 1);
            try bad.writeU32(@bitCast(@as(f32, 1)));
            try bad.enumByte(types.FontScaleBasis, @as(types.FontScaleBasis, .context));
            try bad.out.appendSlice(a, raw_snapshot.out.items[1..]);
        } else try bad.inlineFontSnapshot(duplicate);
        try bad.byte(0);
        var invalid: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = bad.out.items };
        try std.testing.expectError(error.InvalidPresentation, invalid.cellLineHeight());
    }
    for (0..3) |mode| {
        var bad = value;
        switch (mode) {
            0 => bad.strut.?.owner_font.?.font_scale = 2,
            1 => bad.strut.?.owner_font.?.font_features = null,
            2 => bad.strut.?.owner_font.?.font_family = null,
            else => unreachable,
        }
        var invalid: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true }; defer invalid.deinit();
        try std.testing.expectError(error.InvalidPresentation, invalid.cellLineHeight(bad));
    }
}

test "P cell owner font preserves legacy strut bytes and initializes absent owners on poisoned backing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policies = [_]types.CellLineHeight{
        .{ .height = .normal },
        .{ .strut = .{ .font_scale = 0, .font_scale_basis = .normal_body }, .height = .normal },
        CellOwnerFontCodecTest.policy,
    };
    for (policies, 0..) |policy, index| {
        var old: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = index == 2 }; defer old.deinit();
        try old.cellLineHeight(policy);
        if (index == 0) try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, old.out.items);
        if (index == 1) try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 1, 0 }, old.out.items);
    }
    for ([_]bool{ false, true }) |owned| {
        var rows = [_]types.Row{CellOwnerFontCodecTest.table.rows[0]};
        var cells = [_]types.Cell{ rows[0].cells[0], rows[0].cells[1], rows[0].cells[2] };
        if (!owned) cells[0].style.?.line_height.?.strut.?.owner_font = null;
        rows[0].cells = &cells;
        const entry: types.Entry = .{ .title = "cell owners", .kind = .citations,
            .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &rows } }} }} };
        const bytes = try encodeAlloc(a, .{ .entry = entry });
        try std.testing.expectEqualStrings(if (owned) body_adjoining_magic else container_fonts_magic, bytes[0..4]);
        for ([_]u8{ 0xa5, 0xff }) |poison| {
            var memory: [128 * 1024]u8 = undefined; @memset(&memory, poison);
            var fixed = std.heap.FixedBufferAllocator.init(&memory);
            const decoded = try decodeAlloc(fixed.allocator(), bytes, entry.title, entry.kind, null);
            try std.testing.expectEqualDeep(entry, decoded.entry);
            const actual = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells;
            try std.testing.expect(actual[1].style.?.line_height.?.strut.?.owner_font == null);
            try std.testing.expect(actual[2].style == null);
            try std.testing.expectEqual(owned, actual[0].style.?.line_height.?.strut.?.owner_font != null);
            try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        }
    }
}

test "P cell owner font recursively binds capability and preserves every body action through Stored and build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const grid = CellOwnerFontCodecTest.table;
    const boxes = [_]types.Block{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .table, .table = grid }} } }};
    var figure = MissingFigureCodecTest.make(); figure.caption_blocks = &boxes;
    const entries = [_]types.Entry{
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "root", .blocks = &.{.{ .kind = .table, .table = grid }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "nested", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = grid }} }} } }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "cell body", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &boxes }} }} } }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{
            .level = 2, .title = "caption body", .blocks = &.{.{ .kind = .table, .table = .{ .caption_blocks = &boxes } }},
        }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Container", .blocks = &boxes }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Figure", .blocks = &.{.{ .kind = .paragraph, .figure = figure }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .rtl, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} }} },
        .{ .title = "cell heights", .kind = .supplemental, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &boxes }} },
    };
    for (entries) |entry| {
        const stored: types.Stored = .{ .entry = entry };
        try types.validateStored(a, stored, entry.title, entry.kind, null);
        const bytes = try encodeAlloc(a, stored);
        const tail = try StyledSectionCodecTest.tail(a, bytes);
        try std.testing.expectEqualStrings(body_adjoining_magic, bytes[0..4]);
        try std.testing.expectEqual(@as(u8, 132), bytes[tail]);
        const decoded = try decodeAlloc(a, bytes, entry.title, entry.kind, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const reparsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer reparsed.deinit();
        try std.testing.expectEqualDeep(stored, reparsed.value);
        // Bit one carries the body policy itself, so adding it is a valid
        // semantic change. The independently computed Cell features stay exact.
        var adjoining = stored;
        adjoining.entry.body_adjoining = .ordinary;
        const adjoining_bytes = try a.dupe(u8, bytes);
        adjoining_bytes[tail] |= 1;
        try std.testing.expectEqual(@as(u8, 133), adjoining_bytes[tail]);
        try std.testing.expectEqualDeep(adjoining, try decodeAlloc(a, adjoining_bytes, entry.title, entry.kind, null));
        try std.testing.expectEqualSlices(u8, adjoining_bytes, try encodeAlloc(a, adjoining));
        try std.testing.expectEqualSlices(u8, adjoining_bytes, try encodeBuildWithBodyAdjoiningAlloc(a,
            entry.display_title, entry.sections, entry.organization, entry.references, entry.media, .ordinary));
        for ([_]u8{ 0, 4, 128, 140, 148, 164, 196, 255 }) |features| {
            const bad = try a.dupe(u8, bytes); bad[tail] = features;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, entry.title, entry.kind, null));
        }
        for ([_][]const u8{ container_fonts_magic, rule_styles_magic, inline_styles_magic }) |header| {
            const bad = try a.dupe(u8, bytes); @memcpy(bad[0..4], header);
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, entry.title, entry.kind, null));
        }
    }
}

test "P cell metric owner combines with responsive Table and heading capabilities without borrowing their fonts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const narrow = PairedTableScrollCodecTest.block();
    var table = PairedTableScrollCodecTest.table(&narrow); table.rows = CellOwnerFontCodecTest.table.rows;
    const sections = [_]types.Section{ .{ .level = 0, .title = "", .blocks = &.{.{ .kind = .table, .table = table }} }, StyledSectionCodecTest.sections[0] };
    const entry: types.Entry = .{ .title = "combined", .kind = .citations, .sections = &sections, .body_adjoining = .ordinary };
    const bytes = try encodeAlloc(a, .{ .entry = entry });
    try std.testing.expectEqual(@as(u8, 167), bytes[try StyledSectionCodecTest.tail(a, bytes)]);
    try std.testing.expectEqualDeep(entry, (try decodeAlloc(a, bytes, entry.title, entry.kind, null)).entry);
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildWithBodyAdjoiningAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, entry.media, entry.body_adjoining));
}


const TableCornersCodecTest = struct {
    const corners: types.TableCornerRadii = .{
        .top_left = .{ .unit = .px, .value = 8 }, .top_right = .{ .unit = .px, .value = 8 },
        .bottom_right = .{ .unit = .px, .value = 8 }, .bottom_left = .{ .unit = .px, .value = 0 },
    };
    const style: types.TableStyle = .{ .background = "#f5f4aa", .border = .{ .solid = .{
        .width = .{ .unit = .px, .value = 1 }, .color = "#bca674" } },
        .collapse = .separate, .width = .{ .unit = .percent, .value = 100 }, .corner_radii = corners };
    const table: types.Table = .{ .style = style, .rows = &.{.{ .cells = &.{.{ .spans = &.{
        .{ .kind = .link, .text = "variant", .target = "-ac", .bold = true, .tooltip = "kept" },
    } }} }} };
    const blocks = [_]types.Block{.{ .kind = .table, .table = table }};
    const stored: types.Stored = .{ .entry = .{ .title = "corners", .kind = .citations,
        .sections = &.{.{ .level = 0, .title = "", .blocks = &blocks }} } };
};

test "DPRQ Table corners roundtrip complete owner body actions and build payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = TableCornersCodecTest;
    const bytes = try encodeAlloc(a, F.stored);
    try std.testing.expectEqualStrings(table_corners_magic, bytes[0..4]);
    // Q has corners but no P features: zero is an explicit required tail here.
    try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
    const decoded = try decodeAlloc(a, bytes, "corners", .citations, null);
    try std.testing.expectEqualDeep(F.stored, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const build = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), F.stored.entry.sections,
        types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualSlices(u8, bytes, build);
    var with_body = F.stored; with_body.entry.body_adjoining = .ordinary;
    const combined = try encodeAlloc(a, with_body);
    try std.testing.expectEqual(@as(u8, 1), combined[combined.len - 1]);
    try std.testing.expectEqualDeep(with_body, try decodeAlloc(a, combined, "corners", .citations, null));
}

test "DPRQ corner census follows nested cells and reference blocks without changing P8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = TableCornersCodecTest;
    const outer: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .blocks = &F.blocks }} }} };
    const nested_blocks = [_]types.Block{.{ .kind = .table, .table = outer }};
    var nested = F.stored; nested.entry.sections = &.{.{ .level = 0, .title = "", .blocks = &nested_blocks }};
    const nested_bytes = try encodeAlloc(a, nested);
    try std.testing.expectEqualStrings(table_corners_magic, nested_bytes[0..4]);
    try std.testing.expectEqualDeep(nested, try decodeAlloc(a, nested_bytes, "corners", .citations, null));
    var referenced = F.stored; referenced.entry.sections = &.{};
    referenced.entry.references = &.{.{ .number = 1, .group_number = 1, .blocks = &F.blocks }};
    var missing_ordinal = referenced;
    missing_ordinal.entry.references = &.{.{ .number = 1, .group_number = null, .blocks = &F.blocks }};
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, missing_ordinal));
    const ref_bytes = try encodeAlloc(a, referenced);
    try std.testing.expectEqualStrings(table_corners_magic, ref_bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 0), ref_bytes[ref_bytes.len - 1]);
    try std.testing.expectEqualDeep(referenced, try decodeAlloc(a, ref_bytes, "corners", .citations, null));
    const wrong_feature = try a.dupe(u8, ref_bytes); wrong_feature[wrong_feature.len - 1] = 8;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, wrong_feature, "corners", .citations, null));
}

test "DPRQ rejects old header corner flags missing owner census and truncated payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = TableCornersCodecTest;
    const bytes = try encodeAlloc(a, F.stored);
    for ([_][]const u8{ container_fonts_magic, rule_styles_magic, inline_styles_magic, body_adjoining_magic }) |header| {
        const old = try a.dupe(u8, bytes); @memcpy(old[0..4], header);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, "corners", .citations, null));
    }
    var old_body = F.stored; old_body.entry.body_adjoining = .ordinary;
    var no_corner_table = F.table; no_corner_table.style.?.corner_radii = null;
    const no_corner_blocks = [_]types.Block{.{ .kind = .table, .table = no_corner_table }};
    old_body.entry.sections = &.{.{ .level = 0, .title = "", .blocks = &no_corner_blocks }};
    const previous = try encodeAlloc(a, old_body);
    try std.testing.expectEqualStrings(body_adjoining_magic, previous[0..4]);
    const absent = try a.dupe(u8, previous); @memcpy(absent[0..4], table_corners_magic);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, absent, "corners", .citations, null));
    for (0..bytes.len) |end| try std.testing.expectError(error.InvalidPresentation,
        decodeAlloc(a, bytes[0..end], "corners", .citations, null));
    try std.testing.expectError(error.UnsupportedPresentationVersion, decodeAlloc(a, "DPRS", "corners", .citations, null));
}

test "Table corner tail has strict old reader masks units flags and exact legacy null bytes" {
    const a = std.testing.allocator;
    var legacy: Encoder = .{ .a = a, .version = .container_fonts }; defer legacy.deinit();
    try legacy.tableStyle(.{ .border = .none, .collapse = .separate });
    try std.testing.expectEqualSlices(u8, &.{ 1, 6, 0, 0, 0 }, legacy.out.items);
    var raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer raw.deinit();
    const style: types.TableStyle = .{ .border = .none, .collapse = .separate, .corner_radii = TableCornersCodecTest.corners };
    try raw.tableStyle(style);
    var next: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(@as(?types.TableStyle, style), try next.tableStyle());
    // This is the exact pre-Q M/P style mask, not a claim that ABI10 implies Q.
    for ([_]bool{ false, true }) |old_p| {
        var old: Reader = .{ .a = a, .version = .container_fonts, .capability_p = old_p, .bytes = raw.out.items };
        try std.testing.expectError(error.InvalidPresentation, old.tableStyle());
    }
    for (0..raw.out.items.len) |end| {
        next = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, next.tableStyle());
    }
    const unknown = try a.dupe(u8, raw.out.items); defer a.free(unknown); unknown[2] |= 0x40;
    next = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = unknown };
    try std.testing.expectError(error.InvalidPresentation, next.tableStyle());
    var invalid = style; invalid.corner_radii.?.top_left.unit = .em;
    try std.testing.expectError(error.InvalidPresentation, raw.tableStyle(invalid));
}


test "DPRQ responsive corner box preserves paired P32 owner flags seven actions and anonymous grid refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var box = PairedTableScrollCodecTest.block();
    box.box_style.border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#bca674" } };
    box.box_style.background = "#f5f4aa";
    box.box_style.corner_radii = TableCornersCodecTest.corners;
    const table = PairedTableScrollCodecTest.table(&box);
    try std.testing.expect(types.validTableScrollViewport(box));
    const table_blocks = [_]types.Block{.{ .kind = .table, .table = table }};
    const blocks = [_]types.Block{.{ .kind = .container,
        .container = .{ .style = .{}, .blocks = &table_blocks } }};
    const source: types.Stored = .{ .entry = .{ .title = "responsive corners", .kind = .citations,
        .sections = &.{.{ .level = 0, .title = "", .blocks = &blocks }} } };
    // Corners live only on the narrow responsive box. The wide table and
    // anonymous grid retain their independent original styles and paint.
    try std.testing.expect(table.style.?.corner_radii == null and box.grid_style.corner_radii == null);
    const bytes = try encodeAlloc(a, source);
    try std.testing.expectEqualStrings(table_corners_magic, bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 32), bytes[bytes.len - 1]);
    const decoded = try decodeAlloc(a, bytes, source.entry.title, source.entry.kind, null);
    try std.testing.expectEqualDeep(source, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, source.entry.display_title,
        source.entry.sections, source.entry.organization, source.entry.references, source.entry.media));
    const old_header = try a.dupe(u8, bytes); @memcpy(old_header[0..4], body_adjoining_magic);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old_header, source.entry.title, source.entry.kind, null));
    const absent_pair_feature = try a.dupe(u8, bytes); absent_pair_feature[absent_pair_feature.len - 1] = 0;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, absent_pair_feature, source.entry.title, source.entry.kind, null));
    var raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer raw.deinit();
    try raw.table(@as(?types.Table, table));
    try std.testing.expectEqual(@as(u8, 7), raw.out.items[0]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, table), try reader.table());
    try std.testing.expectEqual(raw.out.items.len, reader.pos);
    var bad_box = box;
    bad_box.grid_style = .{ .border = .none, .collapse = .separate, .corner_radii = TableCornersCodecTest.corners };
    try std.testing.expect(types.validTableStyle(bad_box.grid_style));
    try std.testing.expect(!types.validTableScrollViewport(bad_box));
    var invalid = table; invalid.block_viewport = &bad_box;
    try std.testing.expectError(error.InvalidPresentation, raw.table(@as(?types.Table, invalid)));
}


test "DPRQ separate responsive banner keeps numeric margins grid geometry body actions and strict old policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.StyleLength = .{ .unit = .em, .value = 0 };
    var box_style = TableCornersCodecTest.style;
    box_style.collapse = null;
    box_style.containing_direction = .ltr;
    box_style.margins = .{ .top = zero, .right = zero, .bottom = .{ .unit = .em, .value = 0.5 }, .left = zero };
    box_style.padding = types.StyleEdges.all(.{ .unit = .em, .value = 0.1 });
    var box: types.TableBlockViewport = .{ .max_viewport_width_px = 639,
        .box_style = box_style, .box_sizing = .content_box,
        .max_width = .{ .unit = .percent, .value = 100 }, .grid_style = .{ .collapse = .separate },
        .grid_direction = .ltr, .language = "mg", .focus_paint = .{ .mode = .authored_none } };
    var table = TableCornersCodecTest.table;
    table.style.?.margins = box.box_style.margins;
    table.style.?.containing_direction = .ltr;
    table.geometry = .{ .cell_spacing = 2, .cell_padding = 1 };
    table.block_viewport = &box;
    try std.testing.expect(!types.validTableBlockViewport(box));
    try std.testing.expect(!types.validTableScrollViewport(box));
    try std.testing.expect(types.validTableCornerBlockViewport(box));
    try std.testing.expect(types.validTableViewportHeaders(table.geometry, table.style, &box, null));
    var source = TableCornersCodecTest.stored;
    source.entry.sections = &.{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .table, .table = table }} }};
    const encoded = try encodeAlloc(a, source);
    try std.testing.expectEqualStrings(table_corners_magic, encoded[0..4]);
    try std.testing.expectEqual(@as(u8, 0), encoded[encoded.len - 1]);
    const decoded = try decodeAlloc(a, encoded, source.entry.title, source.entry.kind, null);
    try std.testing.expectEqualDeep(source, decoded);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, encoded, try encodeBuildAlloc(a, source.entry.display_title,
        source.entry.sections, source.entry.organization, source.entry.references, source.entry.media));
    for ([_]f32{ 638.75, 639, 639.25, 640 }) |width| {
        const active = try types.resolveTableBlockViewport(table, width);
        try std.testing.expect((active != null) == (width <= 639));
    }
    const json = try std.json.Stringify.valueAlloc(a, decoded.entry, .{});
    const parsed = try std.json.parseFromSlice(types.Entry, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(decoded.entry, parsed.value);
    const old = try a.dupe(u8, encoded); @memcpy(old[0..4], body_adjoining_magic);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, source.entry.title, source.entry.kind, null));
    for (0..15) |mode| {
        var bad = table; var changed = box; bad.block_viewport = &changed;
        switch (mode) {
            0 => bad.geometry = null,
            1 => bad.geometry.?.cell_spacing = null,
            2 => bad.geometry.?.cell_padding = null,
            3 => bad.geometry.?.border = 0,
            4 => bad.geometry.?.width = .{ .unit = .percent, .value = 100 },
            5 => changed.grid_style.background = "#f5f4aa",
            6 => changed.grid_style.collapse = .collapse,
            7 => changed.box_style.corner_radii = null,
            8 => changed.box_style.containing_direction = null,
            9 => changed.focus_paint = null,
            10 => changed.focus_paint = .{ .mode = .authored_none, .color = .{ .kind = .rgb, .value = "#123456" } },
            11 => bad.style.?.containing_direction = null,
            12 => bad.style.?.margins = null,
            13 => bad.style.?.width.?.value = 99,
            14 => bad.style.?.margin_values = .{ .top = .{ .length = zero }, .right = .auto, .bottom = .{ .length = zero }, .left = .auto },
            else => unreachable,
        }
        try std.testing.expect(!types.validTableViewportHeaders(bad.geometry, bad.style, bad.block_viewport, null));
        var raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer raw.deinit();
        try std.testing.expectError(error.InvalidPresentation, raw.table(@as(?types.Table, bad)));
    }
    var style_raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer style_raw.deinit();
    try style_raw.tableStyle(box.box_style);
    try std.testing.expectEqual(@as(u8, 0x30), style_raw.out.items[2] & 0x38);
    var style_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = style_raw.out.items };
    try std.testing.expectEqualDeep(@as(?types.TableStyle, box.box_style), try style_reader.tableStyle());
    try std.testing.expectEqual(style_raw.out.items.len, style_reader.pos);
    var old_style_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .bytes = style_raw.out.items };
    try std.testing.expectError(error.InvalidPresentation, old_style_reader.tableStyle());
    const missing_corner_flag = try a.dupe(u8, style_raw.out.items); missing_corner_flag[2] &= ~@as(u8, 0x20);
    var missing_corner_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = missing_corner_flag };
    try std.testing.expectError(error.InvalidPresentation, missing_corner_reader.tableStyle());
    for ([_]bool{ false, true }) |q| {
        var lone_direction: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = q, .bytes = &.{ 1, 0, 16, 0 } };
        try std.testing.expectError(error.InvalidPresentation, lone_direction.tableStyle());
    }
    // The new Q owner carries its own required focus result, without P32.
    var policy_raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer policy_raw.deinit();
    try policy_raw.tableBlockViewport(box);
    try std.testing.expectEqualSlices(u8, &.{ @intFromEnum(types.TableScrollFocusMode.authored_none), 0 }, policy_raw.out.items[policy_raw.out.items.len - 2 ..]);
    var policy_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = policy_raw.out.items };
    try std.testing.expectEqualDeep(box, (try policy_reader.tableBlockViewport()).*);
    try std.testing.expectEqual(policy_raw.out.items.len, policy_reader.pos);
    for (0..3) |mode| {
        const malformed = try a.dupe(u8, policy_raw.out.items);
        if (mode == 0) malformed[malformed.len - 2] = 255;
        if (mode == 1) malformed[malformed.len - 1] = 2;
        var refused: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true,
            .bytes = if (mode == 2) malformed[0 .. malformed.len - 1] else malformed };
        try std.testing.expectError(error.InvalidPresentation, refused.tableBlockViewport());
    }
    var outlined = box; outlined.focus_paint = .{ .mode = .ua_auto, .color = .{ .kind = .rgb, .value = "#3366cc" } };
    var outline_raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer outline_raw.deinit();
    try outline_raw.tableBlockViewport(outlined);
    var outline_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = outline_raw.out.items };
    try std.testing.expectEqualDeep(outlined, (try outline_reader.tableBlockViewport()).*);
    try std.testing.expectEqual(outline_raw.out.items.len, outline_reader.pos);
    var rtl = box; rtl.box_style.containing_direction = .rtl;
    var rtl_table = table; rtl_table.block_viewport = &rtl;
    try std.testing.expect(types.validTableViewportHeaders(rtl_table.geometry, rtl_table.style, &rtl, null));
    var rtl_raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true }; defer rtl_raw.deinit();
    try rtl_raw.table(@as(?types.Table, rtl_table));
    var rtl_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .bytes = rtl_raw.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, rtl_table), try rtl_reader.table());
    try std.testing.expectEqual(rtl_raw.out.items.len, rtl_reader.pos);
    // Geometry zero is real, independently represented, not a native default.
    var zero_grid = table; zero_grid.geometry = .{ .cell_spacing = 0, .cell_padding = 0 };
    try std.testing.expect(types.validTableViewportHeaders(zero_grid.geometry, zero_grid.style, &box, null));
    try std.testing.expect(!types.validTableViewportHeaders(table.geometry, table.style, &box,
        .{ .max_viewport_width_px = 639, .containing_direction = .ltr, .grid_direction = .ltr, .language = "mg" }));
}

test "Q explicit inline image middle tag3 tail is strict and old null image bytes stay exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: types.InlineImage = .{ .file = "M.svg", .width_px = 600, .vertical_align = .middle };
    var encoder: Encoder = .{ .a = a, .version = .container_fonts, .capability_q = true }; defer encoder.deinit();
    try encoder.inlineImage(image);
    const bytes = encoder.out.items;
    try std.testing.expectEqualSlices(u8, &.{3,5,0,0,0,'M','.','s','v','g',1,88,2,0,0,0}, bytes);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .capability_q = true, .bytes = bytes };
    try std.testing.expectEqualDeep(image, (try reader.inlineImage()).?);
    try std.testing.expectEqual(bytes.len, reader.pos);
    for (0..bytes.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .capability_q = true, .bytes = bytes[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.inlineImage());
    }
    const bad = try a.dupe(u8, bytes); bad[bad.len - 1] = 2;
    var unknown: Reader = .{ .a = a, .version = .container_fonts, .capability_q = true, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, unknown.inlineImage());
    const baseline = try a.dupe(u8, bytes); baseline[baseline.len - 1] = 1;
    var baseline_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_q = true, .bytes = baseline };
    var baseline_image = image; baseline_image.vertical_align = .baseline;
    try std.testing.expectEqualDeep(baseline_image, (try baseline_reader.inlineImage()).?);
    try std.testing.expectEqual(baseline.len, baseline_reader.pos);
    var baseline_encoder: Encoder = .{ .a = a, .version = .container_fonts, .capability_q = true }; defer baseline_encoder.deinit();
    try baseline_encoder.inlineImage(baseline_image);
    try std.testing.expectEqualSlices(u8, baseline, baseline_encoder.out.items);
    const unknown_tag_bytes = try a.dupe(u8, bytes); unknown_tag_bytes[0] = 4;
    var unknown_tag_reader: Reader = .{ .a = a, .version = .container_fonts, .capability_q = true, .bytes = unknown_tag_bytes };
    try std.testing.expectError(error.InvalidPresentation, unknown_tag_reader.inlineImage());
    var old = image; old.vertical_align = null;
    const golden = [_]u8{1,5,0,0,0,'M','.','s','v','g',1,88,2,0,0};
    for ([_]Version{ .image_maps, .inline_table_styles, .block_containers, .container_fonts }) |version| {
        var prior: Encoder = .{ .a = a, .version = version }; defer prior.deinit();
        try prior.inlineImage(old); try std.testing.expectEqualSlices(u8, &golden, prior.out.items);
        try std.testing.expectError(error.InvalidPresentation, prior.inlineImage(image));
        var legacy: Reader = .{ .a = a, .version = version, .bytes = bytes };
        try std.testing.expectError(error.InvalidPresentation, legacy.inlineImage());
    }
}
test "explicit image middle recursively selects Q in Stored build and mapped owner paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const span: types.Span = .{ .kind = .link, .target = "File:M.svg", .image = .{ .file = "M.svg", .width_px = 600,
        .vertical_align = .middle, .map = .{ .description = .bottom_right, .regions = &.{.{ .shape = .rectangle,
            .coordinates = &.{0,0,100,100}, .action = .{ .kind = .internal, .target = "Region", .label = "region" } }} } } };
    const body = [_]types.Block{.{ .kind = .paragraph, .spans = &.{span} }};
    const table: types.Table = .{ .caption = &.{span}, .rows = &.{.{ .cells = &.{.{ .blocks = &body }} }} };
    const entries = [_]types.Entry{
        .{ .title = "middle", .kind = .supplemental, .display_title = &.{span} },
        .{ .title = "middle", .kind = .supplemental, .preamble_spans = &.{span} },
        .{ .title = "middle", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Container", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &body } }} }} },
        .{ .title = "middle", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Table", .blocks = &.{.{ .kind = .table, .table = table }} }} },
        .{ .title = "middle", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Flow", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .@"inline", .spans = &.{span} }} }} }} },
        .{ .title = "middle", .kind = .supplemental, .references = &.{.{ .kind = .note, .number = 1, .group_number = 1, .blocks = &body }} },
    };
    for (entries) |entry| {
        var stored: types.Stored = .{ .entry = entry };
        stored.entry.media = &.{.{ .file = "M.svg", .kind = .image, .caption = "" }};
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(table_corners_magic, bytes[0..4]);
        try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, "middle", .supplemental, null));
        if (entry.preamble_spans.len == 0) try std.testing.expectEqualSlices(u8, bytes,
            try encodeBuildAlloc(a, entry.display_title, entry.sections, entry.organization, entry.references, stored.entry.media));
    }
}



test "baseline-only Q image survives recursive build data and refuses old headers without corners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const span: types.Span = .{ .kind = .link, .target = "File:Arrow.png", .image = .{
        .file = "Arrow.png", .width_px = 30, .vertical_align = .baseline } };
    const source: types.Stored = .{ .entry = .{ .title = "baseline", .kind = .citations,
        .sections = &.{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .paragraph, .spans = &.{span} }} }},
        .media = &.{.{ .file = "Arrow.png", .kind = .image, .caption = "" }} } };
    try std.testing.expect(!hasTableCorners(source.entry.display_title, source.entry.sections, source.entry.preamble_spans, source.entry.references));
    const bytes = try encodeAlloc(a, source);
    try std.testing.expectEqualStrings(table_corners_magic, bytes[0..4]);
    try std.testing.expectEqualDeep(source, try decodeAlloc(a, bytes, source.entry.title, source.entry.kind, null));
    try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, source.entry.display_title,
        source.entry.sections, source.entry.organization, source.entry.references, source.entry.media));
    for ([_][]const u8{ container_fonts_magic, inline_styles_magic, body_adjoining_magic }) |header| {
        const old = try a.dupe(u8, bytes); @memcpy(old[0..4], header);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, old, source.entry.title, source.entry.kind, null));
    }
}

test "Q corners and image alignment compose with independent Cell owner P128 and responsive P32 census" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..4) |mode| {
        const corners = mode & 1 != 0;
        const aligned = mode & 2 != 0;
        var box = PairedTableScrollCodecTest.block();
        if (corners) {
            box.box_style.border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#bca674" } };
            box.box_style.corner_radii = TableCornersCodecTest.corners;
        }
        var table = PairedTableScrollCodecTest.table(&box);
        table.rows = CellOwnerFontCodecTest.table.rows;
        const image: types.Span = .{ .kind = .link, .target = "File:Owner.png", .image = .{
            .file = "Owner.png", .width_px = 30, .vertical_align = if (aligned) .middle else null } };
        const source: types.Stored = .{ .entry = .{ .title = "combined owners", .kind = .citations,
            .sections = &.{.{ .level = 0, .title = "", .blocks = &.{
                .{ .kind = .table, .table = table }, .{ .kind = .paragraph, .spans = &.{image} } } }},
            .media = &.{.{ .file = "Owner.png", .kind = .image, .caption = "" }} } };
        // The paired float owner remains captionless. Retain the original
        // invalid caption premise as a negative; keep its image/action in the
        // valid complete body as a neighboring paragraph for recursive census.
        var captioned_table = table; captioned_table.caption = &.{image};
        var invalid_caption = source;
        invalid_caption.entry.sections = &.{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .table, .table = captioned_table }} }};
        try std.testing.expectError(error.InvalidPresentation,
            types.validateStored(a, invalid_caption, source.entry.title, source.entry.kind, null));
        try types.validateStored(a, source, source.entry.title, source.entry.kind, null);
        const bytes = try encodeAlloc(a, source);
        try std.testing.expectEqualStrings(if (corners or aligned) table_corners_magic else body_adjoining_magic, bytes[0..4]);
        // Owner family, paired responsive Table, and Cell owner have independent bits.
        try std.testing.expectEqual(@as(u8, 164), bytes[bytes.len - 1]);
        const decoded = try decodeAlloc(a, bytes, source.entry.title, source.entry.kind, null);
        try std.testing.expectEqualDeep(source, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, source.entry.display_title,
            source.entry.sections, source.entry.organization, source.entry.references, source.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(source, parsed.value);
        const cell = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
        try std.testing.expectEqualDeep(CellOwnerFontCodecTest.policy, cell.style.?.line_height.?);
        try std.testing.expect(cell.style.?.line_height.?.strut.?.owner_font.?.bold);
        try std.testing.expect(!cell.spans[0].bold and cell.spans[0].italic);
        try std.testing.expectEqualStrings("Kept", cell.spans[0].target);
        try std.testing.expectEqualStrings("part", cell.spans[0].target_fragment.?);
        for ([_]u8{ 0, 4, 32, 128, 132, 160, 172, 180, 228, 255 }) |mask| {
            const bad = try a.dupe(u8, bytes);
            bad[bad.len - 1] = mask;
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad, source.entry.title, source.entry.kind, null));
        }
        const wrong_header = try a.dupe(u8, bytes);
        @memcpy(wrong_header[0..4], if (corners or aligned) body_adjoining_magic else table_corners_magic);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, wrong_header, source.entry.title, source.entry.kind, null));
        // Body policy remains independently expressible without changing the owner census.
        var ordinary = source;
        ordinary.entry.body_adjoining = .ordinary;
        const ordinary_bytes = try a.dupe(u8, bytes);
        ordinary_bytes[ordinary_bytes.len - 1] |= 1;
        try std.testing.expectEqualDeep(ordinary, try decodeAlloc(a, ordinary_bytes, source.entry.title, source.entry.kind, null));
        try std.testing.expectEqualSlices(u8, ordinary_bytes, try encodeAlloc(a, ordinary));
    }
}

const IntrinsicTableCodecTest = struct {
    fn policy() types.TableBlockViewport {
        return .{ .max_viewport_width_px = 639,
            .box_style = .{ .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } },
                .margins = types.StyleEdges.all(.{ .unit = .px, .value = 0 }) },
            .box_sizing = .border_box, .max_width = .{ .unit = .percent, .value = 100 },
            .grid_style = .{ .collapse = .collapse }, .grid_direction = .ltr, .language = "ku",
            .focus_paint = .{ .mode = .ua_auto, .color = .{ .kind = .rgb, .value = "#3366cc" } },
            .intrinsic_containing_direction = .rtl };
    }
    fn table(policy_value: *const types.TableBlockViewport) types.Table {
        var wide = policy_value.box_style; wide.collapse = .collapse;
        return .{ .geometry = .{ .border = 1, .cell_padding = 4, .cell_spacing = 0 }, .style = wide,
            .block_viewport = policy_value, .caption = &.{.{ .text = "complete caption" }},
            .rows = &.{.{ .cells = &.{
                .{ .header = true, .background = "#add8e6", .spans = &.{.{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part", .bold = true }} },
                .{ .colspan = 2, .spans = &.{.{ .kind = .external_link, .text = "source", .target = "https://example.test/" }} },
            } }} };
    }
};

test "DPRR intrinsic Table recursive Stored build and JSON retain complete cell actions and legacy hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = IntrinsicTableCodecTest.policy(); const table = IntrinsicTableCodecTest.table(&policy);
    for (0..4) |owner| {
        const leaf: types.Block = .{ .kind = .table, .table = table };
        const nested: types.Block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = table }} }} } };
        const container: types.Block = .{ .kind = .container, .container = .{ .style = .{}, .blocks = &.{leaf} } };
        const blocks = [_]types.Block{if (owner == 1) nested else if (owner == 2) container else leaf};
        const stored: types.Stored = .{ .entry = .{ .title = "intrinsic", .kind = .supplemental,
            .sections = if (owner == 3) &.{} else &.{.{ .level = 0, .title = "", .blocks = &blocks }},
            .references = if (owner == 3) &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &blocks }} else &.{} } };
        if (owner == 3) {
            var invalid_note = stored.entry.references[0]; invalid_note.kind = .note;
            var invalid = stored; invalid.entry.references = &.{invalid_note};
            try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, invalid));
        }
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(intrinsic_table_magic, bytes[0..4]);
        try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
        const decoded = try decodeAlloc(a, bytes, stored.entry.title, .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title,
            stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        const parsed = try std.json.parseFromSlice(types.Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
    }
}

test "DPRR local tag nineteen rejects old headers malformed direction missing focus and invented census" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = IntrinsicTableCodecTest.policy(); const table = IntrinsicTableCodecTest.table(&policy);
    var raw: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true }; defer raw.deinit();
    try raw.table(@as(?types.Table, table));
    try std.testing.expectEqual(@as(u8, 19), raw.out.items[0]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = raw.out.items };
    try std.testing.expectEqualDeep(@as(?types.Table, table), try reader.table());
    var tail: Encoder = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true }; defer tail.deinit();
    try tail.tableBlockViewportIn(policy, false);
    var probe: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = tail.out.items };
    _ = try probe.readU32(); _ = try probe.tableStyle(); _ = try probe.enumValue(types.ContainerBoxSizing);
    _ = try probe.styleWidth(); _ = try probe.tableStyle(); _ = try probe.enumValue(types.TableContainingDirection); _ = try probe.string();
    const direction_at = probe.pos;
    for (0..3) |field| {
        const bad = try a.dupe(u8, tail.out.items); bad[direction_at + field] = 255;
        var wrong: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, wrong.tableBlockViewportMode(false, true));
    }
    for ([_]bool{ false, true }) |q| {
        var old: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = q, .bytes = raw.out.items };
        try std.testing.expectError(error.InvalidPresentation, old.table());
    }
    for (0..raw.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = raw.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.table());
    }
    for ([_]u8{ 3, 7, 23, 27, 35 }) |tag| {
        const bad = try a.dupe(u8, raw.out.items); bad[0] = tag;
        var wrong: Reader = .{ .a = a, .version = .container_fonts, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = bad };
        // Tag3 can consume only the legacy shape, which lacks required fixed-width/auto-margins.
        try std.testing.expectError(error.InvalidPresentation, wrong.table());
    }
    const stored: types.Stored = .{ .entry = .{ .title = "intrinsic", .kind = .supplemental,
        .sections = &.{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .table, .table = table }} }} } };
    const bytes = try encodeAlloc(a, stored);
    for ([_][]const u8{ body_adjoining_magic, table_corners_magic, container_fonts_magic }) |header| {
        const wrong = try a.dupe(u8, bytes); @memcpy(wrong[0..4], header);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, wrong, stored.entry.title, .supplemental, null));
    }
    const old_q = try encodeAlloc(a, TableCornersCodecTest.stored);
    const invented = try a.dupe(u8, old_q); @memcpy(invented[0..4], intrinsic_table_magic);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invented, "corners", .citations, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, intrinsic_table_magic, "intrinsic", .supplemental, null));
    try std.testing.expectError(error.UnsupportedPresentationVersion, decodeAlloc(a, "DPRS", "intrinsic", .supplemental, null));
}

test "DPRR combines Q and P cell owner families without adding a P feature or weakening Q census" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = IntrinsicTableCodecTest.policy(); var table = IntrinsicTableCodecTest.table(&policy);
    table.rows = CellOwnerFontCodecTest.table.rows;
    const blocks = [_]types.Block{.{ .kind = .table, .table = table }, TableCornersCodecTest.blocks[0]};
    const stored: types.Stored = .{ .entry = .{ .title = "mixed", .kind = .citations,
        .sections = &.{.{ .level = 0, .title = "", .blocks = &blocks }} } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(intrinsic_table_magic, bytes[0..4]);
    try std.testing.expectEqualDeep(stored, try decodeAlloc(a, bytes, "mixed", .citations, null));
    // Full-font owner carries its existing family4 + Cell128 independently.
    try std.testing.expectEqual(@as(u8, 132), bytes[bytes.len - 1]);
    const invalid = try a.dupe(u8, bytes); invalid[invalid.len - 1] |= 16;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invalid, "mixed", .citations, null));
}

test "DPRR Rule clear preserves recursive Stored build JSON actions and intrinsic Table coexistence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    inline for (comptime std.meta.tags(types.FigureClear)) |clear| for (0..5) |owner| {
        var rule = RuleCodecTest.block(); rule.rule_style.?.clear = clear;
        const body = [_]types.Block{
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "before", .target = "Before", .target_fragment = "kept" }} },
            rule,
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .external_link, .text = "after", .target = "https://example.test/after" }} },
        };
        const cell: types.Block = .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &body }} }} } };
        const container: types.Block = .{ .kind = .container, .container = .{ .blocks = &body } };
        const policy = IntrinsicTableCodecTest.policy();
        const intrinsic: types.Block = .{ .kind = .table, .table = IntrinsicTableCodecTest.table(&policy) };
        const paired = [_]types.Block{ intrinsic, body[0], rule, body[2] };
        const nested = [_]types.Block{if (owner == 1) cell else container};
        const blocks: []const types.Block = if (owner == 0 or owner == 3) &body else if (owner == 4) &paired else &nested;
        const stored: types.Stored = .{ .entry = .{ .title = "clear", .kind = .supplemental,
            .sections = if (owner == 3) &.{} else &.{.{ .level = 0, .title = "", .blocks = blocks }},
            .references = if (owner == 3) &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = blocks }} else &.{} } };
        if (owner == 3) {
            // A fragment has no ordinal. Preserve the original note/null
            // fixture as an explicit refusal rather than granting it R.
            var invalid_reference = stored.entry.references[0];
            invalid_reference.kind = .note;
            var invalid = stored;
            invalid.entry.references = &.{invalid_reference};
            try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, invalid));
            try std.testing.expectError(error.InvalidPresentation, encodeBuildAlloc(a, invalid.entry.display_title,
                invalid.entry.sections, invalid.entry.organization, invalid.entry.references, invalid.entry.media));
        }
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(intrinsic_table_magic, bytes[0..4]);
        try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
        const decoded = try decodeAlloc(a, bytes, "clear", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        try std.testing.expectEqualSlices(u8, bytes, try encodeBuildAlloc(a, stored.entry.display_title,
            stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media));
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        try std.testing.expectEqualDeep(stored, try std.json.parseFromSliceLeaky(types.Stored, a, json, .{}));
        for ([_][]const u8{ rule_styles_magic, inline_styles_magic, body_adjoining_magic, table_corners_magic }) |header| {
            const downgraded = try a.dupe(u8, bytes); @memcpy(downgraded[0..4], header);
            try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, downgraded, "clear", .supplemental, null));
        }
    };
}

test "DPRR Rule marker two requires an explicit clear tail and retains every null legacy byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var old: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer old.deinit();
    try old.block(RuleCodecTest.block());
    var same: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = true, .capability_r = true }; defer same.deinit();
    try same.block(RuleCodecTest.block());
    try std.testing.expectEqualSlices(u8, old.out.items, same.out.items);
    var prefix: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true }; defer prefix.deinit();
    try prefix.block(types.Block{ .kind = .rule });
    const marker = prefix.out.items.len - 1;
    var rule = RuleCodecTest.block(); rule.rule_style.?.clear = .right;
    var writer: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = true, .capability_r = true }; defer writer.deinit();
    try writer.block(rule);
    try std.testing.expectEqual(@as(u8, 2), writer.out.items[marker]);
    try std.testing.expectEqual(@as(u8, 2), writer.out.items[writer.out.items.len - 1]);
    try std.testing.expectEqual(old.out.items.len + 1, writer.out.items.len);
    try std.testing.expectEqualSlices(u8, old.out.items[0..marker], writer.out.items[0..marker]);
    try std.testing.expectEqualSlices(u8, old.out.items[marker + 1..], writer.out.items[marker + 1..writer.out.items.len - 1]);
    var reader: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = writer.out.items };
    try std.testing.expectEqualDeep(rule, try reader.block());
    try std.testing.expectEqual(writer.out.items.len, reader.pos);
    for (0..writer.out.items.len) |end| {
        var short: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = writer.out.items[0..end] };
        try std.testing.expectError(error.InvalidPresentation, short.block());
    }
    for ([_]usize{ marker, writer.out.items.len - 1 }) |at| {
        const bad = try a.dupe(u8, writer.out.items); bad[at] = 255;
        var wrong: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = true, .capability_r = true, .bytes = bad };
        try std.testing.expectError(error.InvalidPresentation, wrong.block());
    }
    for ([_]bool{ false, true }) |q| {
        var legacy: Reader = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = q, .bytes = writer.out.items };
        try std.testing.expectError(error.InvalidPresentation, legacy.block());
        var refused: Encoder = .{ .a = a, .version = .container_fonts, .rule_styles = true, .capability_p = true, .capability_q = q }; defer refused.deinit();
        try std.testing.expectError(error.InvalidPresentation, refused.block(rule));
    }
    const legacy_stored: types.Stored = .{ .entry = .{ .title = "clear", .kind = .supplemental,
        .sections = &.{.{ .level = 0, .title = "", .blocks = &.{RuleCodecTest.block()} }} } };
    const old_bytes = try encodeAlloc(a, legacy_stored);
    try std.testing.expectEqualStrings(rule_styles_magic, old_bytes[0..4]);
    var invented: std.ArrayList(u8) = .empty;
    try invented.appendSlice(a, old_bytes); @memcpy(invented.items[0..4], intrinsic_table_magic);
    try invented.append(a, 0);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invented.items, "clear", .supplemental, null));
}
