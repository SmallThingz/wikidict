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
const Version = enum { plain, explained, colored, anchored, span_background, nested_tables, cell_blocks, reference_items, font_scale, font_scale_basis, reference_blocks, image_border, block_layout, explicit_targets, dynamic_catalog, tooltips, block_geometry, image_maps };
fn hasRgb(version: Version) bool {
    return version == .colored or version == .anchored or version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasAnchorFields(version: Version) bool {
    return version == .anchored or version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasSpanBackgroundFields(version: Version) bool {
    return version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasNestedFields(version: Version) bool {
    return version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasCellBlockFields(version: Version) bool {
    return version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasReferenceFields(version: Version) bool {
    return version == .reference_items or version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasFontScaleFields(version: Version) bool {
    return version == .font_scale or version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasFontScaleBasisFields(version: Version) bool {
    return version == .font_scale_basis or version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
fn hasReferenceBlockFields(version: Version) bool {
    return version == .reference_blocks or version == .image_border or (version == .block_layout or (version == .explicit_targets or (version == .dynamic_catalog or (version == .tooltips or (version == .block_geometry or version == .image_maps)))));
}
const max_items: usize = types.max_presentation_items;
const max_string_bytes: usize = 32 * 1024 * 1024;
const no_index: u32 = std.math.maxInt(u32);

const Encoder = struct {
    a: A,
    version: Version = .plain,
    out: std.ArrayList(u8) = .empty,
    table_depth: usize = 0,
    content_depth: usize = 0,
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
            const target_fields = @typeInfo(E).@"enum";
            var result: [fields.field_names.len]u8 = undefined;
            for (fields.field_names, fields.field_values, 0..) |name, source_value, i| {
                if (source_value != i) @compileError("enumByte source must use dense zero-based values");
                result[i] = invalid;
                for (target_fields.field_names, target_fields.field_values) |target_name, target_value| {
                    if (std.mem.eql(u8, name, target_name)) {
                        result[i] = @intCast(target_value);
                        break;
                    }
                }
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
    fn span(self: *Encoder, value: anytype) !void {
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
        if (scale) |n| if (!std.math.isFinite(n) or n < 0) return error.InvalidPresentation;
        if (basis == .normal_body and (scale == null or !hasFontScaleBasisFields(self.version))) return error.InvalidPresentation;
        if (hasFontScaleFields(self.version)) {
            try self.byte(@intFromBool(scale != null));
            if (scale) |n| {
                try self.writeU32(@bitCast(n));
                if (hasFontScaleBasisFields(self.version)) try self.byte(@intFromEnum(basis));
            }
        }
        if (hasReferenceBlockFields(self.version)) try self.inlineImage(spanImage(value));
        const fragment = spanTargetFragment(value);
        if (fragment) |text| if (!types.validTargetFragment(text)) return error.InvalidPresentation;
        if (fragment != null and (kind != @intFromEnum(types.InlineKind.link) or (self.version != .explicit_targets and (self.version != .dynamic_catalog and (self.version != .tooltips and (self.version != .block_geometry and self.version != .image_maps)))))) return error.InvalidPresentation;
        if ((self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps))))) {
            try self.byte(@intFromBool(fragment != null));
            if (fragment) |text| try self.string(text);
        }
        const tooltip = spanTooltip(value);
        if (tooltip != null and (self.version != .tooltips and (self.version != .block_geometry and self.version != .image_maps))) return error.InvalidPresentation;
        if ((self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps))) {
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
        if (value.map != null and self.version != .image_maps) return error.InvalidPresentation;
        if (!types.validInlineImage(value) or (value.border and self.version != .image_border and self.version != .block_layout and (self.version != .explicit_targets and (self.version != .dynamic_catalog and (self.version != .tooltips and (self.version != .block_geometry and self.version != .image_maps)))))) return error.InvalidPresentation;
        try self.byte(1);
        try self.string(value.file);
        const flags: u8 = @as(u8, @intFromBool(value.width_px != null)) |
            (@as(u8, @intFromBool(value.height_px != null)) << 1) |
            (@as(u8, @intFromBool(value.alt != null)) << 2) |
            (@as(u8, @intFromBool(value.tooltip != null)) << 3) |
            (@as(u8, @intFromBool(value.border)) << 4) |
            (@as(u8, @intFromBool(value.map != null)) << 5);
        try self.byte(flags);
        if (value.width_px) |width| try self.writeU32(width);
        if (value.height_px) |height| try self.writeU32(height);
        if (value.alt) |alt| try self.string(alt);
        if (value.tooltip) |tooltip| try self.string(tooltip);
        if (value.map) |map| try self.imageMap(map);
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
    fn styleBorder(self: *Encoder, value: types.StyleBorder) !void {
        if (!types.validBorder(value)) return error.InvalidPresentation;
        switch (value) {
            .none => try self.byte(0),
            .solid => |solid| {
                try self.byte(1);
                try self.styleLength(solid.width);
                try self.string(solid.color);
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
    fn chargeFigureImage(self: *Encoder) !void {
        if (self.remaining_items == 0) return error.PresentationTooLarge;
        self.remaining_items -= 1;
    }
    fn figure(self: *Encoder, optional: anytype) error{OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate}!void {
        const value = optional orelse { try self.byte(0); return; };
        if (self.version != .image_maps) return error.InvalidPresentation;
        if (value.frame_min_width) |minimum| if (!types.validFigureFrameMinWidth(minimum)) return error.InvalidPresentation;
        const image = spanImage(value.image_span) orelse return error.InvalidPresentation;
        if (!types.validFigureSizingContext(value.format, value.sizing, image.width_px, image.height_px)) return error.InvalidPresentation;
        const trail: []const u8 = if (comptime @hasField(@TypeOf(value.image_span), "trail")) value.image_span.trail else "";
        if (!types.validFigureGeometry(value) or value.image_span.text.len != 0 or trail.len != 0) return error.InvalidPresentation;
        try self.byte(1);
        try self.enumByte(types.FigureFormat, value.format);
        try self.enumByte(types.FigurePlacement, value.placement);
        try self.enumByte(types.FigureClear, value.clear);
        try self.styleEdges(value.margins); try self.styleEdges(value.image_insets); try self.styleEdges(value.caption_padding);
        try self.writeU32(@bitCast(value.caption_font_scale)); try self.styleLength(value.caption_line_height);
        try self.figureColor(value.frame_background); try self.figureBorder(value.frame_border);
        try self.figureColor(value.image_background); try self.figureBorder(value.image_border);
        try self.figureColor(value.caption_foreground); try self.figureColor(value.caption_background);
        try self.chargeFigureImage();
        // Preserve compiler Span packed flags and metadata through the existing
        // generic span encoder; never force a build-to-Stored conversion here.
        try self.span(value.image_span);
        const caption = if (comptime @hasField(@TypeOf(value), "caption")) value.caption else @as([]const types.Span, &.{});
        if (comptime @hasField(@TypeOf(value), "caption_blocks")) {
            if (value.caption_blocks != null and caption.len != 0) return error.InvalidPresentation;
        }
        try self.spans(caption);
        if (comptime @hasField(@TypeOf(value), "caption_blocks")) try self.captionBlocks(value.caption_blocks) else try self.byte(0);
        const alignment: ?types.CellTextAlign = if (comptime @hasField(@TypeOf(value), "caption_text_align")) value.caption_text_align else null;
        try self.byte(@intFromBool(alignment != null)); if (alignment) |present| try self.enumByte(types.CellTextAlign, present);
        try self.enumByte(types.FigureSizingPolicy, value.sizing);
        try self.byte(@intFromBool(value.frame_min_width != null));
        if (value.frame_min_width) |minimum| try self.styleLength(minimum);
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
    fn cellStyle(self: *Encoder, optional: ?types.CellStyle) !void {
        const value = optional orelse {
            try self.byte(0);
            return;
        };
        if (!types.validCellStyle(value)) return error.InvalidPresentation;
        try self.byte(1);
        const flags: u8 = @as(u8, @intFromBool(value.border != null)) |
            (@as(u8, @intFromBool(value.padding != null)) << 1) |
            (@as(u8, @intFromBool(value.text_align != null)) << 2);
        try self.byte(flags);
        if (value.border) |border| try self.styleBorder(border);
        if (value.padding) |padding| try self.styleEdges(padding);
        if (value.text_align) |alignment| try self.enumByte(types.CellTextAlign, alignment);
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
        if (tableStyleHasBoxFields(value) and self.version != .image_maps) return error.InvalidPresentation;
        if (!types.validTableStyle(value) or (value.float_side != null and self.version != .block_layout and (self.version != .explicit_targets and (self.version != .dynamic_catalog and (self.version != .tooltips and (self.version != .block_geometry and self.version != .image_maps)))))) return error.InvalidPresentation;
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
        if (value.background) |color| try self.string(color);
        if (value.border) |border| try self.styleBorder(border);
        if (value.collapse) |collapse| try self.enumByte(types.BorderCollapse, collapse);
        if (value.margins) |margins| try self.styleEdges(margins);
        if (value.float_side) |side| try self.enumByte(types.TableFloatSide, side);
        if (value.width) |width| try self.styleWidth(width);
        if (value.padding) |padding| try self.styleEdges(padding);
        if (value.clear) |clear| try self.enumByte(types.FigureClear, clear);
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
    fn table(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        if (value) |table_value| {
            if (self.table_depth >= types.max_table_depth) return error.InvalidPresentation;
            self.table_depth += 1;
            defer self.table_depth -= 1;
            try self.byte(1);
            if (hasNestedFields(self.version)) {
                const geometry: ?types.TableGeometry = if (comptime @hasField(@TypeOf(table_value), "geometry")) table_value.geometry else null;
                try self.tableGeometry(geometry);
            }
            try self.spans(table_value.caption);
            try self.count(table_value.rows.len);
            for (table_value.rows) |row_value| try self.row(row_value);
            if (hasReferenceBlockFields(self.version)) {
                const style: ?types.TableStyle = if (comptime @hasField(@TypeOf(table_value), "style")) table_value.style else null;
                try self.tableStyle(style);
            }
            if (comptime @hasField(@TypeOf(table_value), "caption_blocks")) {
                if (table_value.caption_blocks != null and (self.version != .image_maps or table_value.caption.len != 0)) return error.InvalidPresentation;
            }
            if (self.version == .image_maps) {
                if (comptime @hasField(@TypeOf(table_value), "caption_blocks")) try self.captionBlocks(table_value.caption_blocks) else try self.byte(0);
            }
        } else try self.byte(0);
    }
    fn block(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        if (comptime @hasField(@TypeOf(value), "figure")) if (value.figure != null) {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            if (value.spans.len != 0 or self.version != .image_maps or !types.validFigureContext(kind, value.depth, value.table != null, value.feature != null, blockGeometry(value) != null, value.list_path)) return error.InvalidPresentation;
        };
        if (comptime @hasField(@TypeOf(value), "flow")) if (value.flow != null) {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            const has_figure = if (comptime @hasField(@TypeOf(value), "figure")) value.figure != null else false;
            if (self.version != .image_maps or value.spans.len != 0 or !types.validFlowContext(kind, value.depth, value.table != null, value.feature != null, has_figure, value.list_path)) return error.InvalidPresentation;
        };
        const geometry = blockGeometry(value);
        if (geometry) |style| {
            const kind: types.BlockKind = @enumFromInt(try enumByteValue(types.BlockKind, value.kind));
            if ((self.version != .block_geometry and self.version != .image_maps) or !types.validBlockStyle(style) or
                !types.validBlockStyleContext(kind, value.depth, value.table != null, value.feature != null, value.list_path)) return error.InvalidPresentation;
        }
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
        if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)))))) {
            try self.byte(@intFromBool(alignment != null));
            if (alignment) |present| try self.enumByte(types.CellTextAlign, present);
        } else if (alignment != null) return error.InvalidPresentation;
        if ((self.version == .block_geometry or self.version == .image_maps)) try self.blockStyle(geometry);
        if (self.version == .image_maps) {
            if (comptime @hasField(@TypeOf(value), "figure")) try self.figure(value.figure) else try self.byte(0);
            if (comptime @hasField(@TypeOf(value), "flow")) try self.flow(value.flow) else try self.byte(0);
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
    bytes: []const u8,
    pos: usize = 0,
    metrics: ?*DecodeMetrics = null,
    table_depth: usize = 0,
    content_depth: usize = 0,
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
        if (hasFontScaleFields(self.version) and try self.presence()) {
            const n: f32 = @bitCast(try self.readU32());
            if (!std.math.isFinite(n) or n < 0) return error.InvalidPresentation;
            if (hasFontScaleBasisFields(self.version)) result.font_scale_basis = try self.enumValue(types.FontScaleBasis);
            result.font_scale = if (n == 1 and result.font_scale_basis == .context) null else n;
        }
        if (hasReferenceBlockFields(self.version)) result.image = try self.inlineImage();
        if ((self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)))) and try self.presence()) {
            if (result.kind != .link) return error.InvalidPresentation;
            result.target_fragment = try self.string();
        }
        if ((self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)) and try self.presence()) result.tooltip = try self.string();
        if (result.image != null and (result.text.len != 0 or result.trail.len != 0 or
            !types.validInlineImageAction(result.kind, result.target))) return error.InvalidPresentation;
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
        if (!try self.presence()) return null;
        const file = try self.string();
        const flags = try self.byte();
        const reserved_mask: u8 = if (self.version == .image_maps) 0xc0 else if (self.version == .image_border or (self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)))))) 0xe0 else 0xf0;
        if (flags & reserved_mask != 0) return error.InvalidPresentation;
        const value: types.InlineImage = .{
            .file = file,
            .width_px = if (flags & 1 != 0) try self.readU32() else null,
            .height_px = if (flags & 2 != 0) try self.readU32() else null,
            .alt = if (flags & 4 != 0) try self.string() else null,
            .tooltip = if (flags & 8 != 0) try self.string() else null,
            .border = flags & 16 != 0,
            .map = if (flags & 32 != 0) try self.imageMap() else null,
        };
        if (!types.validInlineImage(value)) return error.InvalidPresentation;
        return value;
    }
    fn spans(self: *Reader) ![]const types.Span {
        const len = try self.count(if ((self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps))) 37 else if ((self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps))))) 36 else if (hasReferenceBlockFields(self.version)) 35 else if (hasFontScaleFields(self.version)) 34 else if (hasSpanBackgroundFields(self.version)) 33 else if (hasRgb(self.version)) 32 else if (self.version == .explained) 31 else 27);
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
    fn styleBorder(self: *Reader) !types.StyleBorder {
        return switch (try self.byte()) {
            0 => .none,
            1 => solid: {
                const value: types.StyleBorder = .{ .solid = .{ .width = try self.styleLength(), .color = try self.string() } };
                if (!types.validBorder(value)) return error.InvalidPresentation;
                break :solid value;
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
    fn chargeFigureImage(self: *Reader) !void {
        if (self.remaining_items == 0) return error.InvalidPresentation;
        self.remaining_items -= 1;
        if (self.metrics) |metrics| metrics.total_items = std.math.add(u64, metrics.total_items, 1) catch return error.InvalidPresentation;
    }
    fn figure(self: *Reader) error{OutOfMemory, InvalidPresentation}!?types.Figure {
        if (!try self.presence()) return null;
        if (self.remaining() < 123) return error.InvalidPresentation;
        const geometry = .{
            .format = try self.enumValue(types.FigureFormat), .placement = try self.enumValue(types.FigurePlacement), .clear = try self.enumValue(types.FigureClear),
            .margins = try self.styleEdges(), .image_insets = try self.styleEdges(), .caption_padding = try self.styleEdges(),
            .caption_font_scale = @as(f32, @bitCast(try self.readU32())), .caption_line_height = try self.styleLength(),
            .frame_background = try self.figureColor(), .frame_border = try self.figureBorder(),
            .image_background = try self.figureColor(), .image_border = try self.figureBorder(),
            .caption_foreground = try self.figureColor(), .caption_background = try self.figureColor(),
        };
        if (!types.validFigureGeometry(geometry)) return error.InvalidPresentation;
        try self.chargeFigureImage();
        const image_span = try self.span();
        const caption = try self.spans();
        const value: types.Figure = .{
            .image_span = image_span, .caption = caption, .caption_blocks = try self.captionBlocks(caption.len), .caption_text_align = if (try self.presence()) try self.enumValue(types.CellTextAlign) else null, .sizing = try self.enumValue(types.FigureSizingPolicy), .frame_min_width = if (try self.presence()) try self.styleLength() else null, .format = geometry.format, .placement = geometry.placement, .clear = geometry.clear,
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
    fn cellStyle(self: *Reader) !?types.CellStyle {
        if (!try self.presence()) return null;
        const flags = try self.byte();
        if (flags == 0 or flags & 0xf8 != 0) return error.InvalidPresentation;
        const value: types.CellStyle = .{
            .border = if (flags & 1 != 0) try self.styleBorder() else null,
            .padding = if (flags & 2 != 0) try self.styleEdges() else null,
            .text_align = if (flags & 4 != 0) try self.enumValue(types.CellTextAlign) else null,
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
        const reserved_mask: u8 = if (self.version == .image_maps) 0 else if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)))))) 0xe0 else 0xf0;
        if (flags == 0 or flags & reserved_mask != 0) return error.InvalidPresentation;
        const value: types.TableStyle = .{
            .background = if (flags & 1 != 0) try self.string() else null,
            .border = if (flags & 2 != 0) try self.styleBorder() else null,
            .collapse = if (flags & 4 != 0) try self.enumValue(types.BorderCollapse) else null,
            .margins = if (flags & 8 != 0) try self.styleEdges() else null,
            .float_side = if (flags & 16 != 0) try self.enumValue(types.TableFloatSide) else null,
            .width = if (flags & 32 != 0) try self.styleWidth() else null,
            .padding = if (flags & 64 != 0) try self.styleEdges() else null,
            .clear = if (flags & 128 != 0) try self.enumValue(types.FigureClear) else null,
        };
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
    fn table(self: *Reader) error{ OutOfMemory, InvalidPresentation }!?types.Table {
        if (!try self.presence()) return null;
        if (self.table_depth >= types.max_table_depth) return error.InvalidPresentation;
        self.table_depth += 1;
        defer self.table_depth -= 1;
        const geometry = if (hasNestedFields(self.version)) try self.tableGeometry() else null;
        const caption = try self.spans();
        const len = try self.count(4);
        const rows = try self.a.alloc(types.Row, len);
        for (rows) |*row_value| row_value.* = try self.row();
        const value: types.Table = .{ .caption = caption, .rows = rows, .geometry = geometry, .style = if (hasReferenceBlockFields(self.version)) try self.tableStyle() else null, .caption_blocks = if (self.version == .image_maps) try self.captionBlocks(caption.len) else null };
        if (value.caption_blocks != null and value.caption.len != 0) return error.InvalidPresentation;
        if (self.table_depth == 1) if (self.metrics) |metrics| metrics.contentTableTree(value, 1, self.content_depth);
        return value;
    }
    fn block(self: *Reader) error{ OutOfMemory, InvalidPresentation }!types.Block {
        const value: types.Block = .{
            .kind = try self.enumValue(types.BlockKind),
            .depth = try self.byte(),
            .level = try self.byte(),
            .spans = try self.spans(),
            .feature = try self.feature(),
            .list_path = try self.string(),
            .number = try self.string(),
            .table = try self.table(),
            .anchor = if (hasAnchorFields(self.version)) try self.string() else "",
            .anchor_fallback = if (hasAnchorFields(self.version)) try self.string() else "",
            .text_align = if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps))))) and try self.presence()) try self.enumValue(types.CellTextAlign) else null,
            .style = if ((self.version == .block_geometry or self.version == .image_maps)) try self.blockStyle() else null,
            .figure = if (self.version == .image_maps) try self.figure() else null,
            .flow = if (self.version == .image_maps) try self.flow() else null,
        };
        if (value.style != null and !types.validBlockStyleContext(value.kind, value.depth, value.table != null, value.feature != null, value.list_path)) return error.InvalidPresentation;
        if (value.figure != null and (value.spans.len != 0 or !types.validFigureContext(value.kind, value.depth, value.table != null, value.feature != null, value.style != null, value.list_path))) return error.InvalidPresentation;
        if (value.flow != null and (value.spans.len != 0 or !types.validFlowContext(value.kind, value.depth, value.table != null, value.feature != null, value.figure != null, value.list_path))) return error.InvalidPresentation;
        return value;
    }
    fn blocks(self: *Reader) ![]const types.Block {
        const len = try self.count(if (self.version == .image_maps) 29 else if ((self.version == .block_geometry or self.version == .image_maps)) 27 else if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)))))) 26 else 25);
        const out = try self.a.alloc(types.Block, len);
        for (out) |*value| value.* = try self.block();
        return out;
    }
    fn sections(self: *Reader) ![]const types.Section {
        const len = try self.count(if (hasAnchorFields(self.version)) 17 else 9);
        const out = try self.a.alloc(types.Section, len);
        for (out) |*section| {
            section.level = try self.byte();
            section.title = try self.string();
            section.anchor = if (hasAnchorFields(self.version)) try self.string() else "";
            section.anchor_fallback = if (hasAnchorFields(self.version)) try self.string() else "";
            const block_len = try self.count(if (self.version == .image_maps) 29 else if ((self.version == .block_geometry or self.version == .image_maps)) 27 else if ((self.version == .block_layout or (self.version == .explicit_targets or (self.version == .dynamic_catalog or (self.version == .tooltips or (self.version == .block_geometry or self.version == .image_maps)))))) 26 else if (hasAnchorFields(self.version)) 25 else 17);
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
        return .{
            .block = try self.index(),
            .parent = try self.optionalIndex(),
            .examples = try self.indices(),
            .quotations = try self.indices(),
            .notes = try self.indices(),
            .form = try self.form(),
        };
    }
    fn layout(self: *Reader) !types.Layout {
        const len = try self.count(29);
        const lexemes = try self.a.alloc(types.Lexeme, len);
        for (lexemes) |*lexeme| {
            lexeme.language = try self.string();
            lexeme.kind = try self.string();
            lexeme.section = try self.index();
            lexeme.etymology = try self.optionalIndex();
            const senses_len = try self.count(18);
            const senses = try self.a.alloc(types.Sense, senses_len);
            for (senses) |*sense_value| sense_value.* = try self.sense();
            lexeme.definitions = senses;
            lexeme.introduction = try self.indices();
            lexeme.other_blocks = try self.indices();
            lexeme.related_sections = try self.indices();
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
fn spansHaveImages(values: anytype) bool {
    for (values) |value| if (spanImage(value) != null) return true;
    return false;
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

const TreeFeature = enum { table_box_style, rich_content, figures, image_maps, block_geometry, tooltips, explicit_targets, explanation, color, background, scale, body_scale, anchors, nested_tables, cell_blocks, styles, images, image_borders, block_layout };

fn treeSpansHaveFeature(values: anytype, comptime feature: TreeFeature) bool {
    return switch (feature) {
        .image_maps => spansHaveImageMaps(values),
        .tooltips => spansHaveTooltips(values),
        .explicit_targets => spansHaveExplicitTargets(values),
        .explanation => spansHaveExplanation(values),
        .color => spansHaveForeground(values),
        .background => spansHaveBackground(values),
        .scale => spansHaveScale(values),
        .body_scale => spansHaveBodyScale(values),
        .images => spansHaveImages(values),
        .image_borders => spansHaveImageBorders(values),
        else => false,
    };
}

fn blocksHaveFeature(values: anytype, comptime feature: TreeFeature, table_depth: usize) bool { return contentBlocksHaveFeature(values, feature, table_depth, 0); }
fn treeTableHasFeature(value: anytype, comptime feature: TreeFeature, table_depth: usize) bool { return contentTableHasFeature(value, feature, table_depth, 0); }
fn figureHasFeature(figure: anytype, comptime feature: TreeFeature, table_depth: usize, content_depth: usize) bool {
    if (feature == .figures) return true;
    const image = [_]@TypeOf(figure.image_span){figure.image_span};
    if (treeSpansHaveFeature(&image, feature)) return true;
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
    const image = [_]@TypeOf(figure.image_span){figure.image_span}; try validateImageSpans(&image, media);
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
    };
}

pub fn encodeAlloc(a: A, stored: types.Stored) ![]u8 {
    if (!std.mem.eql(u8, stored.schema, types.schema)) return error.InvalidPresentation;
    const images = hasInlineImages(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references);
    if (images) try validateImages(a, stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references, stored.entry.media);
    const version: Version = if (hasTableBoxStyle(stored.entry.sections, stored.entry.references) or hasRichContent(stored.entry.sections, stored.entry.references) or hasFigures(stored.entry.sections, stored.entry.references) or hasImageMaps(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .image_maps else if (hasBlockGeometry(stored.entry.sections, stored.entry.references)) .block_geometry else if (hasTooltips(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .tooltips else if (images and stored.entry.media.len > types.legacy_extended_image_assets) .dynamic_catalog else if (hasExplicitTargets(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .explicit_targets else if (stored.entry.media.len > types.legacy_inline_image_assets or hasBlockLayout(stored.entry.sections, stored.entry.references)) .block_layout else if (hasImageBorders(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .image_border else if (images or hasReferenceBlocks(stored.entry.references) or hasStyles(stored.entry.sections, stored.entry.references)) .reference_blocks else if (hasBodyFontScale(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .font_scale_basis else if (hasFontScale(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .font_scale else if (hasReferenceFragments(stored.entry.references)) .reference_items else if (hasCellBlocks(stored.entry.sections, stored.entry.references)) .cell_blocks else if (hasNestedTables(stored.entry.sections, stored.entry.references)) .nested_tables else if (hasSpanBackground(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .span_background else if (hasAnchors(stored.entry.sections, stored.entry.references)) .anchored else if (hasColor(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .colored else if (hasExplanation(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .explained else .plain;
    var encoder: Encoder = .{ .a = a, .version = version };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, versionMagic(version));
    try encoder.spans(stored.entry.display_title);
    try encoder.sections(stored.entry.sections);
    try encoder.spans(stored.entry.preamble_spans);
    try encoder.layout(stored.entry.organization);
    try encoder.references(stored.entry.references);
    try encoder.media(stored.entry.media);
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
    const images = hasInlineImages(display_title, sections, @as([]const types.Span, &.{}), references_value);
    if (images) try validateImages(a, display_title, sections, @as([]const types.Span, &.{}), references_value, media_value);
    const version: Version = if (hasTableBoxStyle(sections, references_value) or hasRichContent(sections, references_value) or hasFigures(sections, references_value) or hasImageMaps(display_title, sections, @as([]const types.Span, &.{}), references_value)) .image_maps else if (hasBlockGeometry(sections, references_value)) .block_geometry else if (hasTooltips(display_title, sections, @as([]const types.Span, &.{}), references_value)) .tooltips else if (images and media_value.len > types.legacy_extended_image_assets) .dynamic_catalog else if (hasExplicitTargets(display_title, sections, @as([]const types.Span, &.{}), references_value)) .explicit_targets else if (media_value.len > types.legacy_inline_image_assets or hasBlockLayout(sections, references_value)) .block_layout else if (hasImageBorders(display_title, sections, @as([]const types.Span, &.{}), references_value)) .image_border else if (images or hasReferenceBlocks(references_value) or hasStyles(sections, references_value)) .reference_blocks else if (hasBodyFontScale(display_title, sections, @as([]const types.Span, &.{}), references_value)) .font_scale_basis else if (hasFontScale(display_title, sections, @as([]const types.Span, &.{}), references_value)) .font_scale else if (hasReferenceFragments(references_value)) .reference_items else if (hasCellBlocks(sections, references_value)) .cell_blocks else if (hasNestedTables(sections, references_value)) .nested_tables else if (hasSpanBackground(display_title, sections, @as([]const types.Span, &.{}), references_value)) .span_background else if (hasAnchors(sections, references_value)) .anchored else if (hasColor(display_title, sections, @as([]const types.Span, &.{}), references_value)) .colored else if (hasExplanation(display_title, sections, @as([]const types.Span, &.{}), references_value)) .explained else .plain;
    var encoder: Encoder = .{ .a = a, .version = version };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, versionMagic(version));
    try encoder.spans(display_title);
    try encoder.sections(sections);
    try encoder.count(0); // no preamble is emitted by the bundle compiler
    try encoder.layout(layout_value);
    try encoder.references(references_value);
    try encoder.media(media_value);
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
    const version: Version = if (std.mem.eql(u8, payload[0..magic.len], magic)) .plain else if (std.mem.eql(u8, payload[0..explained_magic.len], explained_magic)) .explained else if (std.mem.eql(u8, payload[0..color_magic.len], color_magic)) .colored else if (std.mem.eql(u8, payload[0..anchor_magic.len], anchor_magic)) .anchored else if (std.mem.eql(u8, payload[0..background_magic.len], background_magic)) .span_background else if (std.mem.eql(u8, payload[0..nested_magic.len], nested_magic)) .nested_tables else if (std.mem.eql(u8, payload[0..cell_blocks_magic.len], cell_blocks_magic)) .cell_blocks else if (std.mem.eql(u8, payload[0..reference_items_magic.len], reference_items_magic)) .reference_items else if (std.mem.eql(u8, payload[0..font_scale_magic.len], font_scale_magic)) .font_scale else if (std.mem.eql(u8, payload[0..font_scale_basis_magic.len], font_scale_basis_magic)) .font_scale_basis else if (std.mem.eql(u8, payload[0..reference_blocks_magic.len], reference_blocks_magic)) .reference_blocks else if (std.mem.eql(u8, payload[0..image_border_magic.len], image_border_magic)) .image_border else if (std.mem.eql(u8, payload[0..block_layout_magic.len], block_layout_magic)) .block_layout else if (std.mem.eql(u8, payload[0..explicit_targets_magic.len], explicit_targets_magic)) .explicit_targets else if (std.mem.eql(u8, payload[0..dynamic_catalog_magic.len], dynamic_catalog_magic)) .dynamic_catalog else if (std.mem.eql(u8, payload[0..tooltips_magic.len], tooltips_magic)) .tooltips else if (std.mem.eql(u8, payload[0..block_geometry_magic.len], block_geometry_magic)) .block_geometry else if (std.mem.eql(u8, payload[0..image_maps_magic.len], image_maps_magic)) .image_maps else return error.InvalidPresentation;
    var reader: Reader = .{ .a = a, .version = version, .bytes = payload, .pos = magic.len, .metrics = metrics };
    const display_title = try reader.spans();
    const sections = try reader.sections();
    const preamble = try reader.spans();
    const layout = try reader.layout();
    const references = try reader.references();
    const media = try reader.media();
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
        .references = references,
        .media = media,
    } };
    // E is the first wire version admitting more than128 inline-image assets.
    // Do not retroactively restrict media-only legacy records.
    if (version != .block_layout and (version != .explicit_targets and (version != .dynamic_catalog and (version != .tooltips and (version != .block_geometry and version != .image_maps)))) and media.len > types.legacy_inline_image_assets and
        hasInlineImages(display_title, sections, preamble, references)) return error.InvalidPresentation;
    if ((version != .dynamic_catalog and (version != .tooltips and (version != .block_geometry and version != .image_maps))) and media.len > types.legacy_extended_image_assets and
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
    // Every present feature occurs only inside this footer tree; several are two tables deep.
    // This image-free tree must retain DPRC rather than require the DPRD border feature.
    inline for (comptime std.meta.tags(TreeFeature)) |feature| {
        const expected = feature != .table_box_style and feature != .rich_content and feature != .figures and feature != .image_maps and feature != .block_geometry and feature != .tooltips and feature != .styles and feature != .images and feature != .image_borders and feature != .block_layout and feature != .explicit_targets;
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
            .reference_blocks, .image_border, .block_layout, .explicit_targets, .dynamic_catalog, .tooltips, .block_geometry, .image_maps => unreachable,
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
        if (comptime version != .block_layout and (version != .explicit_targets and (version != .dynamic_catalog and (version != .tooltips and (version != .block_geometry and version != .image_maps))))) {
            var encoder: Encoder = .{ .a = a, .version = version };
            defer encoder.deinit();
            try encoder.block(types.Block{ .kind = .paragraph, .text_align = null });
            try std.testing.expectEqualSlices(u8, golden[0..if (comptime hasAnchorFields(version)) @as(usize, 25) else 17], encoder.out.items);
        }
    }
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
        return .{ .image_span = span, .format = if (image.width_px != null) .thumbnail else .framed,
            .sizing = if (image.width_px != null) .requested_fit else if (image.height_px != null) .original_width_with_height_bound else .intrinsic, .placement = .float_right, .clear = .right,
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
    const build = .{ .image_span = BuildSpan{}, .format = base.format, .sizing = base.sizing, .frame_min_width = @as(?types.StyleLength, .{ .unit = .px, .value = 100 }), .placement = base.placement, .clear = base.clear,
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
    const span = decoded.entry.sections[0].blocks[0].figure.?.image_span;
    try std.testing.expect(span.bold and span.italic and span.small and span.superscript and span.strike and span.underline);
    try std.testing.expectEqualStrings("advice", span.tooltip.?);
    try std.testing.expectEqualStrings("", span.target_fragment.?);
    try std.testing.expectEqual(@as(u8, 77), build.image_span.provenance);
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
        var inner = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 256 } }); inner.sizing = .requested_fit_cap_original_width; inner.caption = &.{.{ .text = "inner caption" }};
        const inner_blocks = [_]types.Block{.{ .kind = .paragraph, .figure = inner }};
        const caption_table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &inner_blocks }} }} };
        const regions = [_]types.MapRegion{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 50, 40 }, .action = .{ .kind = .internal, .target = "Mapped", .target_fragment = "", .label = "region" } }};
        var figure = FigureCodecFixture.make(.{ .kind = .link, .target = "File:Figure.svg", .tooltip = "image advice", .image = .{ .file = "Figure.svg", .width_px = row.width, .height_px = row.height, .map = .{ .regions = &regions } } });
        figure.format = row.format; figure.sizing = row.policy; figure.caption_text_align = .right; figure.caption_blocks = &.{.{ .kind = .table, .table = caption_table }};
        const scope: types.BidiScope = .{ .mode = .isolate, .authored_direction = .auto, .resolved_direction = .rtl, .language = "", .parts = &.{ .{ .kind = .@"inline", .spans = &.{.{ .text = "before " }} }, .{ .kind = .figure, .figure = figure }, .{ .kind = .@"inline", .spans = &.{.{ .text = " after" }} } } };
        const owners = [_]types.Block{ .{ .kind = .paragraph, .figure = figure }, .{ .kind = .list_detail, .depth = 2, .list_path = "*:", .flow = &.{.{ .kind = .scope, .scope = scope }} } };
        const table: types.Table = .{ .caption_blocks = &owners, .rows = &.{.{ .cells = &.{.{ .blocks = &owners }} }} };
        const stored: types.Stored = .{ .entry = .{ .title = "sizing", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{ .{ .kind = .paragraph, .figure = figure }, .{ .kind = .table, .table = table } } }},
            .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &owners }}, .media = &.{.{ .file = "Figure.svg", .kind = .image, .caption = "" }} } };
        try types.validateStored(a, stored, "sizing", .supplemental, null);
        const bytes = try encodeAlloc(a, stored); try std.testing.expectEqualStrings(image_maps_magic, bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "sizing", .supplemental, null); try std.testing.expectEqualDeep(stored, decoded);
        const actual = decoded.entry.sections[0].blocks[0].figure.?; try std.testing.expectEqual(row.policy, actual.sizing);
        try std.testing.expectEqual(row.width, actual.image_span.image.?.width_px); try std.testing.expectEqual(row.height, actual.image_span.image.?.height_px);
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
    var good = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg", .width_px = 0x0f123456, .height_px = 0x0f234567 } }); good.sizing = .requested_fit;
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
        var figure = good; figure.format = row.format; figure.sizing = row.policy; figure.image_span.image.?.width_px = row.width; figure.image_span.image.?.height_px = row.height;
        try std.testing.expect(!types.validFigure(figure)); raw.out.clearRetainingCapacity(); raw.remaining_items = max_items;
        try std.testing.expectError(error.InvalidPresentation, raw.figure(@as(?types.Figure, figure)));
    }
    // A missing required height remains invalid even when its final policy byte
    // is a known enum; no old-private-J or MIME-based fallback can reinterpret it.
    var framed = FigureCodecFixture.make(.{ .image = .{ .file = "Figure.svg" } }); framed.format = .framed; framed.sizing = .intrinsic;
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
        try std.testing.expectEqual(@as(?u32, 50), decoded.entry.sections[0].blocks[0].figure.?.image_span.image.?.width_px);
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
