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
pub const FontScaleBasis = enum { context, normal_body, css_px };
/// Complete explicit OpenType feature-list policy, never an additive patch.
/// null at the owner preserves legacy behavior. normal clears the explicit
/// list; seven_on replaces it with liga/clig/kern/ccmp/dist/mark/mkmk = 1.
/// Kerning, variants, tracking, direction and shaping bypasses are separate.
pub const FontFeaturePolicy = enum(u8) {
    normal = 0,
    seven_on = 1,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const name = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), name) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse error.InvalidEnumTag;
    }
};
/// A span's numeric magnitude retains its computed font origin. Pixel magnitudes
/// are independent of the configured body font; readers apply their text policy.
pub fn validSpanFontScale(value: ?f32, basis: FontScaleBasis) bool {
    if (value) |number| if (!std.math.isFinite(number) or number < 0) return false;
    return basis == .context or value != null;
}
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
/// Closed image-pixel policy in effective dark mode; light mode is unchanged.
pub const ImageDarkModeFilter = enum {
    /// Render the image with a light color scheme, then apply CSS invert(1)
    /// followed by hue-rotate(180deg), without standard dark-mode dimming.
    invert_hue_rotate_180,
};
/// Closed static-poster rendering policy; producer authority is checked before storage.
pub const StaticPosterPolicy = enum(u8) { three_d_stl_v1 = 0 };
pub const StaticPoster = struct {
    policy: StaticPosterPolicy,
    /// Already resolved content-language text; readers never translate or parse it.
    label: []const u8,
    /// Exact source identity to verify before accepting a runtime PNG thumbnail.
    file_sha1: []const u8,
    file_timestamp: []const u8,
};
/// Positive PHP round(width / (640 / 480)), using exact bounded integer arithmetic.
pub fn staticPosterHeight(width: u32) u32 {
    return @intCast((@as(u64, width) * 3 + 2) / 4);
}
pub const InlineImageVerticalAlign = enum(u8) {
    middle = 0,
    baseline = 1,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const raw = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), raw) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse error.InvalidEnumTag;
    }
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
    /// Source-defined image color-scheme and filter policy; captions are unaffected.
    dark_mode_filter: ?ImageDarkModeFilter = null,
    /// Compiled SVG raster language identity, separate from text language.
    svg_language: ?[]const u8 = null,
    /// Source-proven static PNG poster and localized visual/accessibility badge.
    static_poster: ?StaticPoster = null,
    // Explicit source-computed image alignment, distinct from legacy null.
    vertical_align: ?InlineImageVerticalAlign = null,

    pub fn jsonStringify(self: InlineImage, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(self.file);
        inline for (.{ "width_px", "height_px", "alt", "tooltip", "map", "dark_mode_filter", "svg_language", "static_poster", "vertical_align" }) |name| {
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
pub const TextWrap = enum(u8) {
    normal,
    break_word,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const name = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), name) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse error.InvalidEnumTag;
    }
};
pub const HeadingAnchorReveal = struct {
    primary_top: StyleLength,
    fallback_top: ?StyleLength = null,
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("primary_top"); try jw.write(self.primary_top);
        if (self.fallback_top) |value| { try jw.objectField("fallback_top"); try jw.write(value); }
        try jw.endObject();
    }
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        const value = try std.json.innerParse(std.json.Value, a, source, options);
        return jsonParseFromValue(a, value, options);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, value: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (value != .object or value.object.count() < 1 or value.object.count() > 2) return error.UnexpectedToken;
        for (value.object.keys()) |name| if (!std.mem.eql(u8, name, "primary_top") and !std.mem.eql(u8, name, "fallback_top")) return error.UnexpectedToken;
        for ([_][]const u8{ "primary_top", "fallback_top" }) |name| if (value.object.get(name)) |length| {
            if (length == .null and std.mem.eql(u8, name, "fallback_top")) continue;
            if (length != .object or length.object.count() != 2) return error.UnexpectedToken;
            const unit = length.object.get("unit") orelse return error.UnexpectedToken;
            const number = length.object.get("value") orelse return error.UnexpectedToken;
            if (unit != .string or !std.mem.eql(u8, unit.string, "px") or
                (number != .integer and number != .float and number != .number_string)) return error.UnexpectedToken;
        };
        const Raw = struct { primary_top: StyleLength, fallback_top: ?StyleLength = null };
        const raw = try std.json.innerParseFromValue(Raw, a, value, options);
        const result: @This() = .{ .primary_top = raw.primary_top, .fallback_top = raw.fallback_top };
        if (!validHeadingAnchorReveal(result)) return error.UnexpectedToken;
        return result;
    }
};
pub fn validHeadingAnchorReveal(value: HeadingAnchorReveal) bool {
    if (value.primary_top.unit != .px or !validStyleLength(value.primary_top)) return false;
    if (value.fallback_top) |length| if (length.unit != .px or !validStyleLength(length)) return false;
    return true;
}

pub const InlineCursor = enum(u8) {
    help,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const name = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), name) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse error.InvalidEnumTag;
    }
};
pub const InlineUnderlineStyle = enum(u8) { solid, dotted };
/// An additional source decoration; it does not replace a link-state underline.
pub const InlineUnderline = struct {
    style: InlineUnderlineStyle,
    color: ?[]const u8 = null,
    thickness: ?StyleLength = null,
};
/// The declaring owner's existing semantic font, retained before child changes.
/// This is not a numeric browser script-font or baseline assumption.
pub const InlineFontSnapshot = struct {
    font_scale: ?f32 = null,
    font_scale_basis: FontScaleBasis = .context,
    small: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    font_normalized: bool = false,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    language: []const u8 = "",
    classes: []const u8 = "",
    role: Role = .normal,
    font_features: ?FontFeaturePolicy = null,
    font_family: ?ContainerFontFamily = null,
    pub fn jsonStringify(self: InlineFontSnapshot, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(InlineFontSnapshot).@"struct".field_names) |name| {
            const scale_field = comptime std.mem.eql(u8, name, "font_scale");
            const basis_field = comptime std.mem.eql(u8, name, "font_scale_basis");
            const family_field = comptime std.mem.eql(u8, name, "font_family");
            // Match Span's contextual identity at the direct JSON boundary.
            if ((!scale_field or (self.font_scale != null and (self.font_scale.? != 1 or self.font_scale_basis != .context))) and
                (!basis_field or self.font_scale_basis != .context) and (!family_field or self.font_family != null))
            {
                try jw.objectField(name);
                try jw.write(@field(self, name));
            }
        }
        try jw.endObject();
    }
};
pub const InlineLineHeight = union(enum) {
    computed: ComputedLineHeight,
    font_relative: struct { factor: f32, font: InlineFontSnapshot },
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .computed => |value| { try jw.objectField("computed"); try jw.write(value); },
            .font_relative => |value| { try jw.objectField("font_relative"); try jw.write(value); },
        }
        try jw.endObject();
    }
};
pub const InlineTextStyle = struct {
    decoration: ?InlineUnderline = null,
    line_height: ?InlineLineHeight = null,
    baseline_shift: ?ComputedLineHeight = null,
    font_normalized: bool = false,
    cursor: ?InlineCursor = null,
    wrap: ?TextWrap = null,
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(@This()).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "wrap")) {
                if (self.wrap) |value| { try jw.objectField(name); try jw.write(value); }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }
};

pub fn validInlineFontSnapshot(value: InlineFontSnapshot) bool {
    if (value.font_family) |family| if (!validContainerFontFamily(family)) return false;
    return validSpanFontScale(value.font_scale, value.font_scale_basis) and
        std.unicode.utf8ValidateSlice(value.language) and std.unicode.utf8ValidateSlice(value.classes) and
        std.mem.indexOfScalar(u8, value.language, 0) == null and std.mem.indexOfScalar(u8, value.classes, 0) == null and
        (!value.font_normalized or (value.font_scale != null and value.font_scale_basis != .context));
}
fn validInlineComputedLength(value: ComputedLineHeight, signed: bool) bool {
    return value.font_scale_basis != .context and std.math.isFinite(value.value) and
        (signed or value.value >= 0);
}
pub fn validInlineTextStyle(value: InlineTextStyle) bool {
    if (value.decoration == null and value.line_height == null and value.baseline_shift == null and !value.font_normalized and value.cursor == null and value.wrap == null) return false;
    if (value.decoration) |line| {
        if (line.color) |color| if (!isCanonicalRgb(color)) return false;
        if (line.thickness) |length| if (!validStyleLength(length)) return false;
    }
    if (value.line_height) |height| switch (height) {
        .computed => |length| if (!validInlineComputedLength(length, false)) return false,
        .font_relative => |relative| if (!std.math.isFinite(relative.factor) or relative.factor < 0 or
            !validInlineFontSnapshot(relative.font)) return false,
    };
    if (value.baseline_shift) |shift| if (!validInlineComputedLength(shift, true)) return false;
    return true;
}
pub fn validSpanInlineStyle(span: anytype) bool {
    if (comptime !@hasField(@TypeOf(span), "inline_style")) return true;
    const value = span.inline_style orelse return true;
    if (!validInlineTextStyle(value)) return false;
    const kind = @tagName(span.kind);
    if (!std.mem.eql(u8, kind, "text") and !std.mem.eql(u8, kind, "link") and !std.mem.eql(u8, kind, "external_link")) return false;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image != null) return false;
    if (std.mem.eql(u8, kind, "text")) {
        if (span.target.len != 0) return false;
        if (span.text.len == 0 and !spanHasRuby(span) and !spanHasInlinePaddingGroup(span) and (value.line_height == null or value.cursor != null or value.wrap != null)) return false;
    } else if (span.target.len == 0 or (span.text.len == 0 and !spanHasInlinePaddingGroup(span) and !spanHasInlineActionGroup(span))) return false;
    const scale: ?f32 = if (comptime @hasField(@TypeOf(span), "font_scale")) span.font_scale else null;
    const basis: FontScaleBasis = if (comptime @hasField(@TypeOf(span), "font_scale_basis")) span.font_scale_basis else .context;
    if (value.baseline_shift != null) if (value.line_height) |height| if (height == .font_relative) {
        const font = height.font_relative.font;
        if (font.font_scale != scale or font.font_scale_basis != basis or font.font_normalized != value.font_normalized) return false;
        inline for (.{ "small", "superscript", "subscript", "bold", "italic", "code" }) |name| {
            const flag = if (comptime @hasField(@TypeOf(span), name)) @field(span, name)
                else if (comptime @hasField(@TypeOf(span), "flags")) @field(span.flags, name) else false;
            if (@field(font, name) != flag) return false;
        }
        inline for (.{ "language", "classes" }) |name| {
            const text: []const u8 = if (comptime @hasField(@TypeOf(span), name)) @field(span, name) else "";
            if (!std.mem.eql(u8, @field(font, name), text)) return false;
        }
        const role = if (comptime @hasField(@TypeOf(span), "role")) @tagName(span.role) else "normal";
        const features: ?FontFeaturePolicy = if (comptime @hasField(@TypeOf(span), "font_features")) span.font_features else null;
        const family: ?ContainerFontFamily = if (comptime @hasField(@TypeOf(span), "font_family")) span.font_family else null;
        if (!std.mem.eql(u8, @tagName(font.role), role) or font.font_features != features or !sameFontFamilyRequest(font.font_family, family)) return false;
    };
    return !value.font_normalized or (scale != null and basis != .context and validSpanFontScale(scale, basis));
}

/// Declaring group metrics, including empty and completely overridden groups.
/// This data-only context never substitutes an empty Span or emits characters.
pub const RubyOwner = struct {
    font: InlineFontSnapshot,
    direction: []const u8 = "",
    inline_style: ?InlineTextStyle = null,
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
};
fn rubyFontSnapshotEqual(a: InlineFontSnapshot, b: InlineFontSnapshot) bool {
    const a_scale = if (a.font_scale == 1 and a.font_scale_basis == .context) null else a.font_scale;
    const b_scale = if (b.font_scale == 1 and b.font_scale_basis == .context) null else b.font_scale;
    if (a_scale != b_scale or a.font_scale_basis != b.font_scale_basis or !sameFontFamilyRequest(a.font_family, b.font_family)) return false;
    inline for (.{ "small", "superscript", "subscript", "font_normalized", "bold", "italic", "code", "role", "font_features" }) |name|
        if (@field(a, name) != @field(b, name)) return false;
    return std.mem.eql(u8, a.language, b.language) and std.mem.eql(u8, a.classes, b.classes);
}
pub fn validRubyOwnerContext(value: RubyOwner) bool {
    if (!validInlineFontSnapshot(value.font) or !(value.direction.len == 0 or std.mem.eql(u8, value.direction, "ltr") or
        std.mem.eql(u8, value.direction, "rtl") or std.mem.eql(u8, value.direction, "auto"))) return false;
    if (value.foreground) |ink| if (!isCanonicalRgb(ink)) return false;
    if (value.background) |ink| if (!isCanonicalRgb(ink)) return false;
    if (value.inline_style) |style| {
        if (!validInlineTextStyle(style) or (style.font_normalized and !value.font.font_normalized)) return false;
        if (style.line_height) |height| if (height == .font_relative) {
            if (!rubyFontSnapshotEqual(value.font, height.font_relative.font)) return false;
            if (style.baseline_shift != null and style.font_normalized != value.font.font_normalized) return false;
        };
    }
    return true;
}

/// Data-only inline ruby. Child Span types are shared by Stored and the compiler.
pub fn Ruby(comptime Child: type) type {
    return struct { segments: []const RubySegment(Child) };
}
pub fn RubySegment(comptime Child: type) type {
    return struct {
        gap_before: []const Child = &.{},
        bases: []const RubyBase(Child),
        annotations: []const RubyAnnotation(Child) = &.{},
    };
}
pub fn RubyBase(comptime Child: type) type {
    return struct { owner: RubyOwner, gap_before: []const Child = &.{}, spans: []const Child = &.{} };
}
pub fn RubyAnnotation(comptime Child: type) type {
    return struct {
        base_start: u32,
        base_count: u32,
        level: u32,
        owner: RubyOwner,
        gap_before: []const Child = &.{},
        spans: []const Child = &.{},
        fallback_before: []const Child = &.{},
        fallback_after: []const Child = &.{},
        explicit_fallback: bool = false,
    };
}
pub const max_ruby_depth: usize = 16;
pub fn spanHasRuby(span: anytype) bool {
    return if (comptime @hasField(@TypeOf(span), "ruby")) span.ruby != null else false;
}
pub fn validRubyOwner(span: anytype) bool {
    if (!validRubyChild(span) or spanHasInlinePaddingGroup(span) or spanHasInlineActionGroup(span)) return false;
    if (!std.mem.eql(u8, @tagName(span.kind), "text") or span.text.len != 0 or span.target.len != 0) return false;
    if (comptime @hasField(@TypeOf(span), "trail")) if (span.trail.len != 0) return false;
    if (comptime @hasField(@TypeOf(span), "target_fragment")) if (span.target_fragment != null) return false;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image != null) return false;
    return true;
}
/// This first subset contains rich text and nested ruby, never media or forced breaks.
pub fn validRubyChild(span: anytype) bool {
    const kind = @tagName(span.kind);
    if (!std.mem.eql(u8, kind, "text") and !std.mem.eql(u8, kind, "link") and !std.mem.eql(u8, kind, "external_link")) return false;
    if ((std.mem.eql(u8, kind, "text") and span.target.len != 0) or (!std.mem.eql(u8, kind, "text") and span.target.len == 0)) return false;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image != null) return false;
    if (!validSpanInlineStyle(span) or !validSpanLinkPaint(span)) return false;
    const scale: ?f32 = if (comptime @hasField(@TypeOf(span), "font_scale")) span.font_scale else null;
    const basis: FontScaleBasis = if (comptime @hasField(@TypeOf(span), "font_scale_basis")) span.font_scale_basis else .context;
    if (!validSpanFontScale(scale, basis)) return false;
    inline for (.{ "foreground", "background" }) |name| {
        if (comptime @hasField(@TypeOf(span), name)) if (@field(span, name)) |ink| if (!isCanonicalRgb(ink)) return false;
    }
    if (comptime @hasField(@TypeOf(span), "font_family")) if (span.font_family) |family| if (!validContainerFontFamily(family)) return false;
    if (comptime @hasField(@TypeOf(span), "tooltip")) if (span.tooltip) |text| if (!std.unicode.utf8ValidateSlice(text)) return false;
    if (comptime @hasField(@TypeOf(span), "target_fragment")) if (span.target_fragment) |fragment| {
        if (!std.mem.eql(u8, kind, "link") or !validTargetFragment(fragment)) return false;
    };
    if (comptime @hasField(@TypeOf(span), "classes")) {
        var tokens = std.mem.tokenizeAny(u8, span.classes, " \t\r\n\x0c");
        while (tokens.next()) |token| if (std.mem.eql(u8, token, "wikidict-media") or std.mem.startsWith(u8, token, "wikidict-media-file-")) return false;
    }
    inline for (.{ "text", "target", "trail", "language", "classes", "direction", "explanation" }) |name| {
        if (comptime @hasField(@TypeOf(span), name)) if (!std.unicode.utf8ValidateSlice(@field(span, name))) return false;
    }
    return true;
}
/// Producer-resolved child text in the initial single-line ruby subset.
/// Gap arrays have their own CSS whitespace domain and do not use this predicate.
pub fn validRubyBodyChild(span: anytype) bool {
    if (!validRubyChild(span)) return false;
    inline for (.{ "text", "trail" }) |name| {
        if (comptime @hasField(@TypeOf(span), name)) for (@field(span, name)) |byte|
            if (byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c) return false;
    }
    return true;
}
pub fn validRubyGap(spans: anytype) bool {
    if (spans.len > max_presentation_items) return false;
    for (spans) |span| {
        if (!validRubyChild(span) or !std.mem.eql(u8, @tagName(span.kind), "text") or span.target.len != 0 or spanHasRuby(span) or spanHasInlinePaddingGroup(span) or spanHasInlineActionGroup(span)) return false;
        if (comptime @hasField(@TypeOf(span), "target_fragment")) if (span.target_fragment != null) return false;
        if (comptime @hasField(@TypeOf(span), "trail")) if (span.trail.len != 0) return false;
        for (span.text) |byte| if (byte != ' ' and byte != '\t' and byte != '\n' and byte != '\r' and byte != 0x0c) return false;
    }
    return true;
}
/// Local association validation; callers separately charge arrays and recurse.
pub fn validRuby(value: anytype) bool {
    if (value.segments.len == 0 or value.segments.len > max_presentation_items) return false;
    for (value.segments, 0..) |segment, segment_index| {
        if ((segment_index == 0 and segment.gap_before.len != 0) or !validRubyGap(segment.gap_before) or
            segment.bases.len == 0 or segment.bases.len > max_presentation_items or segment.annotations.len > max_presentation_items) return false;
        for (segment.bases, 0..) |base, base_index| {
            if (!validRubyOwnerContext(base.owner) or (base_index == 0 and base.gap_before.len != 0) or !validRubyGap(base.gap_before)) return false;
        }
        var level: u32 = 0;
        var end: u64 = 0;
        for (segment.annotations, 0..) |annotation, index| {
            if (!validRubyOwnerContext(annotation.owner) or annotation.base_count == 0 or @as(u64, annotation.base_start) + annotation.base_count > segment.bases.len) return false;
            if (index == 0) {
                if (annotation.level != 0 or annotation.gap_before.len != 0) return false;
            } else if (annotation.level != level) {
                if (annotation.level != @as(u64, level) + 1 or annotation.gap_before.len != 0) return false;
                end = 0;
            }
            if (annotation.base_start < end or !validRubyGap(annotation.gap_before) or
                (!annotation.explicit_fallback and (annotation.fallback_before.len != 0 or annotation.fallback_after.len != 0))) return false;
            level = annotation.level;
            end = @as(u64, annotation.base_start) + annotation.base_count;
        }
    }
    return true;
}

const RubyFallbackDecoration = struct {
    underline: bool = false,
    strike: bool = false,
    fn including(self: @This(), span: anytype) @This() {
        const flags = if (comptime @hasField(@TypeOf(span), "flags")) span.flags else span;
        return .{ .underline = self.underline or flags.underline, .strike = self.strike or flags.strike };
    }
    fn project(self: @This(), span: anytype) @TypeOf(span) {
        var result = span;
        if (comptime @hasField(@TypeOf(span), "flags")) {
            result.flags.underline = result.flags.underline or self.underline;
            result.flags.strike = result.flags.strike or self.strike;
        } else {
            result.underline = result.underline or self.underline;
            result.strike = result.strike or self.strike;
        }
        if (self.underline) if (comptime @hasField(@TypeOf(span), "link_paint")) if (result.link_paint) |paint| {
            var projected = paint;
            inline for (.{ "normal", "hover", "active", "hover_active", "visited", "visited_hover", "visited_active", "visited_hover_active" }) |name|
                @field(projected, name).underline = true;
            result.link_paint = projected;
        };
        return result;
    }
    fn clear(span: anytype) @TypeOf(span) {
        var result = span;
        if (comptime @hasField(@TypeOf(span), "flags")) {
            result.flags.underline = false;
            result.flags.strike = false;
        } else {
            result.underline = false;
            result.strike = false;
        }
        return result;
    }
};

const RubyFallbackBudget = struct {
    remaining: usize = max_presentation_items,
    action_group_depth: usize = 0,
    fn items(self: *RubyFallbackBudget, count: usize) error{InvalidPresentation}!void {
        if (count > self.remaining) return error.InvalidPresentation;
        self.remaining -= count;
    }
};
/// Readable semantic fallback only. Graphical readers use the ruby associations.
/// Callbacks receive real rich children; generated parentheses carry no action.
pub fn visitRubyFallback(spans: anytype, context: anytype, comptime emit: anytype) anyerror!void {
    return visitRubyFallbackAt(spans, context, emit, 0);
}
pub fn visitRubyFallbackAt(spans: anytype, context: anytype, comptime emit: anytype, content_depth: usize) anyerror!void {
    var budget: RubyFallbackBudget = .{};
    try visitRubyFallbackInner(spans, context, emit, content_depth, 0, false, .{}, null, false, &budget);
}
fn visitRubyFallbackInner(spans: anytype, context: anytype, comptime emit: anytype, content_depth: usize, ruby_depth: usize, gap: bool, decoration: RubyFallbackDecoration, inherited_action: ?InlinePaddingGroupAction, inside_group: bool, budget: *RubyFallbackBudget) anyerror!void {
    try budget.items(spans.len);
    for (spans) |span| {
        // U-only traversal keeps its existing contract. A new action owner also
        // checks each nested declaring Span before entering Ruby or padding.
        if (budget.action_group_depth != 0) if (inherited_action) |action| try action.check(span);
        if (inherited_action != null and (!std.mem.eql(u8, @tagName(span.kind), "text") or span.target.len != 0)) return error.InvalidPresentation;
        if (comptime @hasField(@TypeOf(span), "inline_action_group")) if (span.inline_action_group) |group| {
            if (gap or content_depth >= max_content_depth or !validInlineActionGroupOwner(span)) return error.InvalidPresentation;
            const action = InlinePaddingGroupAction.from(span) orelse return error.InvalidPresentation;
            budget.action_group_depth += 1;
            defer budget.action_group_depth -= 1;
            try visitRubyFallbackInner(group.spans, context, emit, content_depth + 1, ruby_depth, false,
                decoration.including(span), action, true, budget);
            continue;
        };
        if (comptime @hasField(@TypeOf(span), "inline_padding_group")) if (span.inline_padding_group) |group| {
            if (gap or content_depth >= max_content_depth or !validInlinePaddingGroupOwner(span)) return error.InvalidPresentation;
            const action = InlinePaddingGroupAction.from(span) orelse inherited_action;
            try visitRubyFallbackInner(group.spans, context, emit, content_depth + 1, ruby_depth, false,
                decoration.including(span), action, true, budget);
            continue;
        };
        if (comptime @hasField(@TypeOf(span), "ruby")) if (span.ruby) |ruby| {
            if (content_depth >= max_content_depth or ruby_depth >= max_ruby_depth or !validRubyOwner(span) or !validRuby(ruby.*)) return error.InvalidPresentation;
            const base_decoration = decoration.including(span);
            try budget.items(ruby.segments.len);
            for (ruby.segments) |segment| {
                try visitRubyFallbackInner(segment.gap_before, context, emit, content_depth + 1, ruby_depth + 1, true, base_decoration, inherited_action, inside_group, budget);
                try budget.items(segment.bases.len);
                for (segment.bases) |base| {
                    if (inherited_action) |action| try action.checkRubyOwner(base.owner);
                    try budget.items(1);
                    try visitRubyFallbackInner(base.gap_before, context, emit, content_depth + 1, ruby_depth + 1, true, base_decoration, inherited_action, inside_group, budget);
                    try visitRubyFallbackInner(base.spans, context, emit, content_depth + 1, ruby_depth + 1, false, base_decoration, inherited_action, inside_group, budget);
                }
                try budget.items(segment.annotations.len);
                for (segment.annotations) |annotation| {
                    if (inherited_action) |action| try action.checkRubyOwner(annotation.owner);
                    try budget.items(1);
                    try visitRubyFallbackInner(annotation.gap_before, context, emit, content_depth + 1, ruby_depth + 1, true, .{}, inherited_action, inside_group, budget);
                    if (annotation.explicit_fallback) {
                        try visitRubyFallbackInner(annotation.fallback_before, context, emit, content_depth + 1, ruby_depth + 1, false, .{}, inherited_action, inside_group, budget);
                        try visitRubyFallbackInner(annotation.spans, context, emit, content_depth + 1, ruby_depth + 1, false, .{}, inherited_action, inside_group, budget);
                        try visitRubyFallbackInner(annotation.fallback_after, context, emit, content_depth + 1, ruby_depth + 1, false, .{}, inherited_action, inside_group, budget);
                    } else {
                        var probe_budget = budget.*;
                        const nonempty = try rubyFallbackHasText(annotation.spans, content_depth + 1, ruby_depth + 1, &probe_budget);
                        var delimiter = RubyFallbackDecoration.clear(span);
                        delimiter.ruby = null;
                        delimiter.text = "\xef\xbc\x88";
                        if (nonempty) try emit(context, delimiter);
                        try visitRubyFallbackInner(annotation.spans, context, emit, content_depth + 1, ruby_depth + 1, false, .{}, inherited_action, inside_group, budget);
                        delimiter.text = "\xef\xbc\x89";
                        if (nonempty) try emit(context, delimiter);
                    }
                }
            }
            continue;
        };
        if ((ruby_depth != 0 or inside_group) and !(if (gap) validRubyChild(span) else validRubyBodyChild(span))) return error.InvalidPresentation;
        const effective = if (inherited_action) |action| try action.project(span) else span;
        try emit(context, decoration.project(effective));
    }
}

fn rubyFallbackHasText(spans: anytype, content_depth: usize, ruby_depth: usize, budget: *RubyFallbackBudget) error{InvalidPresentation}!bool {
    try budget.items(spans.len);
    for (spans) |span| {
        if (comptime @hasField(@TypeOf(span), "inline_action_group")) if (span.inline_action_group) |group| {
            if (content_depth >= max_content_depth or !validInlineActionGroupOwner(span)) return error.InvalidPresentation;
            if (try rubyFallbackHasText(group.spans, content_depth + 1, ruby_depth, budget)) return true;
            continue;
        };
        if (comptime @hasField(@TypeOf(span), "inline_padding_group")) if (span.inline_padding_group) |group| {
            if (content_depth >= max_content_depth or !validInlinePaddingGroupOwner(span)) return error.InvalidPresentation;
            if (try rubyFallbackHasText(group.spans, content_depth + 1, ruby_depth, budget)) return true;
            continue;
        };
        if (comptime @hasField(@TypeOf(span), "ruby")) if (span.ruby) |ruby| {
            if (content_depth >= max_content_depth or ruby_depth >= max_ruby_depth or !validRubyOwner(span) or !validRuby(ruby.*)) return error.InvalidPresentation;
            try budget.items(ruby.segments.len);
            for (ruby.segments) |segment| {
                if (try rubyFallbackHasText(segment.gap_before, content_depth + 1, ruby_depth + 1, budget)) return true;
                try budget.items(segment.bases.len);
                for (segment.bases) |base| {
                    try budget.items(1);
                    if (try rubyFallbackHasText(base.gap_before, content_depth + 1, ruby_depth + 1, budget) or
                        try rubyFallbackHasText(base.spans, content_depth + 1, ruby_depth + 1, budget)) return true;
                }
                try budget.items(segment.annotations.len);
                for (segment.annotations) |annotation| {
                    try budget.items(1);
                    inline for (.{ "gap_before", "fallback_before", "spans", "fallback_after" }) |field| {
                        if (try rubyFallbackHasText(@field(annotation, field), content_depth + 1, ruby_depth + 1, budget)) return true;
                    }
                }
            }
            continue;
        };
        if (!validRubyChild(span)) return error.InvalidPresentation;
        if (span.text.len != 0) return true;
        if (comptime @hasField(@TypeOf(span), "trail")) if (span.trail.len != 0) return true;
    }
    return false;
}

/// One ordinary inline boundary with zero vertical padding. The containing
/// Span retains the declaring font, paint and action; children add no shim text.
pub fn InlinePaddingGroup(comptime Child: type) type {
    return struct {
        left: StyleLength,
        right: StyleLength,
        spans: []const Child,
    };
}
pub fn spanHasInlinePaddingGroup(span: anytype) bool {
    return if (comptime @hasField(@TypeOf(span), "inline_padding_group")) span.inline_padding_group != null else false;
}
pub fn validInlinePaddingGroup(value: anytype) bool {
    return validStyleLength(value.left) and validStyleLength(value.right) and
        (value.left.value != 0 or value.right.value != 0) and
        value.spans.len != 0 and value.spans.len <= max_presentation_items;
}
pub fn validInlinePaddingGroupOwner(span: anytype) bool {
    if (!spanHasInlinePaddingGroup(span) or !validRubyBodyChild(span) or
        span.text.len != 0 or spanHasRuby(span) or spanHasInlineActionGroup(span)) return false;
    if (comptime @hasField(@TypeOf(span), "trail")) if (span.trail.len != 0) return false;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image != null) return false;
    if (comptime @hasField(@TypeOf(span), "inline_padding_group"))
        return validInlinePaddingGroup(span.inline_padding_group.?.*);
    return false;
}

/// Shared subtree validation for structural consumers. Their containing walk
/// still owns the aggregate entry budget; this proves the group's rich/action
/// semantics without emitting characters or allocating a second representation.
pub fn validateInlinePaddingGroupTree(owner: anytype, content_depth: usize, ruby_depth: usize) error{InvalidPresentation}!void {
    if (!validInlinePaddingGroupOwner(owner)) return error.InvalidPresentation;
    const Noop = struct {
        fn emit(_: void, _: @TypeOf(owner)) error{}!void {}
    };
    var budget: RubyFallbackBudget = .{};
    visitRubyFallbackInner(&[_]@TypeOf(owner){owner}, {}, Noop.emit, content_depth, ruby_depth,
        false, .{}, null, false, &budget) catch return error.InvalidPresentation;
}

/// One authored action occurrence, independently of its rich child runs.
/// The owner carries destination and declaring metrics; children carry all text.
pub fn InlineActionGroup(comptime Child: type) type {
    return struct { spans: []const Child };
}
pub fn spanHasInlineActionGroup(span: anytype) bool {
    return if (comptime @hasField(@TypeOf(span), "inline_action_group")) span.inline_action_group != null else false;
}
pub fn validInlineActionGroup(value: anytype) bool {
    return value.spans.len != 0 and value.spans.len <= max_presentation_items;
}
pub fn validInlineActionGroupOwner(span: anytype) bool {
    if (!spanHasInlineActionGroup(span) or !validRubyBodyChild(span) or
        span.text.len != 0 or span.target.len == 0 or spanHasRuby(span) or spanHasInlinePaddingGroup(span)) return false;
    const kind = @tagName(span.kind);
    if (!std.mem.eql(u8, kind, "link") and !std.mem.eql(u8, kind, "external_link")) return false;
    if (comptime @hasField(@TypeOf(span), "trail")) if (span.trail.len != 0) return false;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image != null) return false;
    if (comptime @hasField(@TypeOf(span), "self_link")) if (span.self_link) return false;
    if (comptime @hasField(@TypeOf(span), "inline_action_group"))
        return validInlineActionGroup(span.inline_action_group.?.*);
    return false;
}
/// Structural consumers retain their containing entry budget. This local
/// traversal checks rich children and the single stored action owner without
/// copying visible text or installing actions on stored descendants.
pub fn validateInlineActionGroupTree(owner: anytype, content_depth: usize, ruby_depth: usize) error{InvalidPresentation}!void {
    if (!validInlineActionGroupOwner(owner)) return error.InvalidPresentation;
    const Noop = struct {
        fn emit(_: void, _: @TypeOf(owner)) error{}!void {}
    };
    var budget: RubyFallbackBudget = .{};
    visitRubyFallbackInner(&[_]@TypeOf(owner){owner}, {}, Noop.emit, content_depth, ruby_depth,
        false, .{}, null, false, &budget) catch return error.InvalidPresentation;
}

pub const InlinePaddingGroupAction = struct {
    kind: InlineKind,
    target: []const u8,
    target_fragment: ?[]const u8,
    tooltip: ?[]const u8,
    explanation: []const u8,
    link_paint: ?LinkPaint,
    foreground: ?[]const u8,
    underline: bool,

    pub fn from(span: anytype) ?@This() {
        const kind = std.meta.stringToEnum(InlineKind, @tagName(span.kind)) orelse return null;
        if (kind != .link and kind != .external_link) return null;
        const flags = if (comptime @hasField(@TypeOf(span), "flags")) span.flags else span;
        const paint: ?LinkPaint = if (comptime @hasField(@TypeOf(span), "link_paint")) span.link_paint else null;
        const ink: ?[]const u8 = if (comptime @hasField(@TypeOf(span), "foreground")) span.foreground else null;
        return .{
            .kind = kind, .target = span.target,
            .target_fragment = if (comptime @hasField(@TypeOf(span), "target_fragment")) span.target_fragment else null,
            .tooltip = if (comptime @hasField(@TypeOf(span), "tooltip")) span.tooltip else null,
            .explanation = if (comptime @hasField(@TypeOf(span), "explanation")) span.explanation else "",
            .link_paint = paint,
            .foreground = ink orelse if (paint) |policy| policy.normal.foreground else null,
            .underline = flags.underline,
        };
    }
    pub fn check(self: @This(), span: anytype) error{InvalidPresentation}!void {
        if (!std.mem.eql(u8, @tagName(span.kind), "text") or span.target.len != 0) return error.InvalidPresentation;
        if (self.link_paint != null) if (comptime @hasField(@TypeOf(span), "foreground")) if (span.foreground) |ink| {
            const owner_ink = self.foreground orelse return error.InvalidPresentation;
            if (!std.mem.eql(u8, ink, owner_ink)) return error.InvalidPresentation;
        };
    }
    pub fn checkRubyOwner(self: @This(), owner: RubyOwner) error{InvalidPresentation}!void {
        if (self.link_paint != null) if (owner.foreground) |ink| {
            const owner_ink = self.foreground orelse return error.InvalidPresentation;
            if (!std.mem.eql(u8, ink, owner_ink)) return error.InvalidPresentation;
        };
    }
    pub fn project(self: @This(), span: anytype) error{InvalidPresentation}!@TypeOf(span) {
        try self.check(span);
        const trail: []const u8 = if (comptime @hasField(@TypeOf(span), "trail")) span.trail else "";
        // An empty metric owner has no semantic action interval.
        if (span.text.len == 0 and trail.len == 0) return span;
        var result = span;
        if (comptime @hasField(@TypeOf(span), "trail")) if (result.text.len == 0) {
            result.text = result.trail;
            result.trail = "";
        };
        result.kind = std.meta.stringToEnum(@TypeOf(result.kind), @tagName(self.kind)) orelse return error.InvalidPresentation;
        result.target = self.target;
        if (comptime @hasField(@TypeOf(span), "target_fragment")) result.target_fragment = self.target_fragment;
        if (comptime @hasField(@TypeOf(span), "tooltip")) if (result.tooltip == null) { result.tooltip = self.tooltip; };
        if (comptime @hasField(@TypeOf(span), "explanation")) if (result.explanation.len == 0) { result.explanation = self.explanation; };
        // Source admission owns any descendant paint override. This initial
        // inherited-action projection requires the same computed foreground.
        if (self.link_paint) |paint| {
            if (comptime @hasField(@TypeOf(span), "foreground")) {
                result.foreground = self.foreground;
            }
            if (comptime @hasField(@TypeOf(span), "link_paint")) result.link_paint = paint;
        } else if (comptime @hasField(@TypeOf(span), "foreground")) {
            result.foreground = result.foreground orelse self.foreground;
        }
        if (comptime @hasField(@TypeOf(span), "flags")) {
            result.flags.underline = result.flags.underline or self.underline;
        } else result.underline = result.underline or self.underline;
        const flags = if (comptime @hasField(@TypeOf(span), "flags")) result.flags else result;
        return (RubyFallbackDecoration{ .underline = flags.underline }).project(result);
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
    font_features: ?FontFeaturePolicy = null,
    font_family: ?ContainerFontFamily = null,
    link_paint: ?LinkPaint = null,
    inline_style: ?InlineTextStyle = null,
    image: ?InlineImage = null,
    ruby: ?*const Ruby(@This()) = null,
    inline_padding_group: ?*const InlinePaddingGroup(@This()) = null,
    inline_action_group: ?*const InlineActionGroup(@This()) = null,
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
            const ruby_field = comptime std.mem.eql(u8, field_name, "ruby");
            const padding_group_field = comptime std.mem.eql(u8, field_name, "inline_padding_group");
            const action_group_field = comptime std.mem.eql(u8, field_name, "inline_action_group");
            const features_field = comptime std.mem.eql(u8, field_name, "font_features");
            const family_field = comptime std.mem.eql(u8, field_name, "font_family");
            const link_paint_field = comptime std.mem.eql(u8, field_name, "link_paint");
            const inline_style_field = comptime std.mem.eql(u8, field_name, "inline_style");
            if ((!action_group_field or self.inline_action_group != null) and (!padding_group_field or self.inline_padding_group != null) and (!ruby_field or self.ruby != null) and (!fragment_field or self.target_fragment != null) and (!image_field or self.image != null) and (!background_field or self.background != null) and
                (!scale_field or (self.font_scale != null and (self.font_scale.? != 1 or self.font_scale_basis != .context))) and
                (!basis_field or self.font_scale_basis != .context) and (!features_field or self.font_features != null) and
                (!link_paint_field or self.link_paint != null) and (!inline_style_field or self.inline_style != null) and (!family_field or self.font_family != null))
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
pub const BlockKind = enum { paragraph, blank, definition, example, quotation, list_item, list_detail, indent, term, heading, preformatted, rule, table, container };
// DPR2-S retain their historical wire limit. DPRT advertises deeper Tables.
pub const legacy_table_depth: usize = 16;
pub const max_table_depth: usize = 32;
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
pub fn BorderEdgeFor(comptime Color: type) type {
    const Line = struct { width: StyleLength, color: Color };
    return union(enum) {
        none,
        hidden,
        solid: Line,
        dotted: Line,
    };
}
pub fn BorderEdgesFor(comptime Edge: type) type {
    return struct {
        top: Edge, right: Edge, bottom: Edge, left: Edge,
        pub fn all(value: Edge) @This() { return .{ .top = value, .right = value, .bottom = value, .left = value }; }
    };
}
pub const StyleBorderEdge = BorderEdgeFor([]const u8);
pub const StyleBorderEdges = BorderEdgesFor(StyleBorderEdge);
pub const StyleBorder = union(enum) {
    none,
    solid: struct { width: StyleLength, color: []const u8 },
    edges: StyleBorderEdges,
};
pub const BorderCollapse = enum { separate, collapse };
pub const CellTextAlign = enum { left, center, right };
pub const TableFloatSide = enum { left, right };
pub const TableDisplay = enum { table, inline_block, inline_table };
pub const InlineBoxVerticalAlign = enum { baseline, middle, top };
/// A computed length in the TABLE origin's selected font basis. Inherited cell
/// font changes do not multiply this length again.
pub const ComputedLineHeight = struct {
    value: f32,
    font_scale_basis: FontScaleBasis = .context,
    pub fn jsonStringify(self: ComputedLineHeight, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("value"); try jw.write(@as(f64, self.value));
        try jw.objectField("font_scale_basis"); try jw.write(self.font_scale_basis);
        try jw.endObject();
    }
};
pub const TableContainingDirection = enum(u8) {
    ltr = 0,
    rtl = 1,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const name = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), name) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse error.InvalidEnumTag;
    }
};
/// Circular physical corners, in clockwise order. Only fixed CSS px are
/// admitted by the initial table paint contract; decoding never clamps them.
pub const TableCornerRadii = struct {
    top_left: StyleLength,
    top_right: StyleLength,
    bottom_right: StyleLength,
    bottom_left: StyleLength,
};
pub const TableStyle = struct {
    background: ?[]const u8 = null,
    border: ?StyleBorder = null,
    collapse: ?BorderCollapse = null,
    margins: ?StyleEdges = null,
    /// Computed table-wrapper horizontal autos, exclusive with numeric margins.
    margin_values: ?ContainerMargins = null,
    containing_direction: ?TableContainingDirection = null,
    float_side: ?TableFloatSide = null,
    width: ?StyleWidth = null,
    padding: ?StyleEdges = null,
    clear: ?FigureClear = null,
    display: ?TableDisplay = null,
    vertical_align: ?InlineBoxVerticalAlign = null,
    line_height: ?ComputedLineHeight = null,
    corner_radii: ?TableCornerRadii = null,

    pub fn jsonStringify(self: TableStyle, jw: anytype) !void {
        try writeOptionalStyleFields(self, jw);
    }
};
// Cell alignment is a row/cell solver policy, never inline x-height alignment.
pub const CellVerticalAlign = enum(u8) {
    top = 0,
    middle = 1,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const name = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), name) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse error.InvalidEnumTag;
    }
};
/// Cell metric owner; painted descendants retain their own font tuples.
pub const CellTextStrut = struct {
    font_scale: f32,
    font_scale_basis: FontScaleBasis,
    owner_font: ?InlineFontSnapshot = null,

    pub fn jsonStringify(self: CellTextStrut, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("font_scale"); try jw.write(self.font_scale);
        try jw.objectField("font_scale_basis"); try jw.write(self.font_scale_basis);
        if (self.owner_font) |font| {
            try jw.objectField("owner_font"); try jw.write(font);
        }
        try jw.endObject();
    }
};
pub const CellLineHeightValue = union(enum) {
    normal,
    multiplier: f32,
    length: ComputedLineHeight,
    pub fn jsonStringify(self: CellLineHeightValue, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .normal => { try jw.objectField("normal"); try jw.beginObject(); try jw.endObject(); },
            .multiplier => |value| { try jw.objectField("multiplier"); try jw.write(@as(f64, value)); },
            .length => |value| { try jw.objectField("length"); try jw.write(value); },
        }
        try jw.endObject();
    }
};
pub const CellLineHeight = struct {
    strut: ?CellTextStrut = null,
    height: CellLineHeightValue,
};

pub const CellStyle = struct {
    border: ?StyleBorder = null,
    padding: ?StyleEdges = null,
    text_align: ?CellTextAlign = null,
    // Content-box intrinsic minimum. Em is computed at this cell's own font
    // into normal-body units; it is not a fixed/preferred width or inherited.
    min_width: ?StyleLength = null,
    vertical_align: ?CellVerticalAlign = null,
    /// Resolved preferred CSS cell width, distinct from the intrinsic minimum.
    /// Em uses normal-body units; percentages remain table sizing constraints.
    width: ?StyleWidth = null,
    line_height: ?CellLineHeight = null,

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
/// One compiled display:block viewport around the same anonymous table grid.
/// The immutable pointer in Table avoids adding two inline styles to old Tables.
/// The source scroll TABLE's focus-visible paint, independent of child A states.
/// Native auto uses the platform outline without adding layout metrics.
pub const TableScrollFocusMode = enum { authored_none, ua_auto };
pub const TableScrollFocusPaint = struct {
    mode: TableScrollFocusMode,
    color: ?FigureColor = null,
    const JsonFields = struct { mode: std.json.Value, color: ?FigureColor = null };
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParse(JsonFields, a, source, strict));
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParseFromValue(JsonFields, a, source, strict));
    }
    fn fromJson(value: JsonFields) error{ UnexpectedToken, InvalidEnumTag }!@This() {
        if (value.mode != .string) return error.UnexpectedToken;
        const result: @This() = .{ .mode = std.meta.stringToEnum(TableScrollFocusMode, value.mode.string) orelse return error.InvalidEnumTag, .color = value.color };
        if (!validTableScrollFocusPaint(result)) return error.UnexpectedToken;
        return result;
    }
};
pub fn validTableScrollFocusPaint(value: TableScrollFocusPaint) bool {
    if (value.color) |color| return value.mode == .ua_auto and validFigureColor(color);
    return true;
}
pub const TableBlockViewport = struct {
    max_viewport_width_px: u32,
    box_style: TableStyle,
    box_sizing: ContainerBoxSizing,
    max_width: StyleWidth,
    grid_style: TableStyle,
    grid_direction: TableContainingDirection,
    language: []const u8,
    focus_paint: ?TableScrollFocusPaint = null,
    intrinsic_containing_direction: ?TableContainingDirection = null,
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(@This()).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "intrinsic_containing_direction")) {
                if (self.intrinsic_containing_direction) |value| { try jw.objectField(name); try jw.write(value); }
            } else if (comptime std.mem.eql(u8, name, "focus_paint")) {
                if (self.focus_paint) |value| { try jw.objectField(name); try jw.write(value); }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }

    const JsonFields = struct {
        max_viewport_width_px: u32, box_style: TableStyle, box_sizing: std.json.Value,
        max_width: StyleWidth, grid_style: TableStyle, grid_direction: TableContainingDirection, language: []const u8,
        focus_paint: ?TableScrollFocusPaint = null,
        intrinsic_containing_direction: ?TableContainingDirection = null,
    };
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParse(JsonFields, a, source, strict));
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParseFromValue(JsonFields, a, source, strict));
    }
    fn fromJson(value: JsonFields) error{ UnexpectedToken, InvalidEnumTag }!@This() {
        if (value.box_sizing != .string) return error.UnexpectedToken;
        if (value.language.len == 0 or value.language.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(value.language)) return error.UnexpectedToken;
        return .{ .max_viewport_width_px = value.max_viewport_width_px, .box_style = value.box_style,
            .box_sizing = std.meta.stringToEnum(ContainerBoxSizing, value.box_sizing.string) orelse return error.InvalidEnumTag,
            .max_width = value.max_width, .grid_style = value.grid_style,
            .grid_direction = value.grid_direction, .language = value.language, .focus_paint = value.focus_paint,
            .intrinsic_containing_direction = value.intrinsic_containing_direction };
    }
};
/// One ordinary Table body: physical right float above the root threshold,
/// normal flow below. No scrollport or anonymous-grid semantics are implied.
pub const TableFloatViewport = struct {
    max_viewport_width_px: u32,
    containing_direction: TableContainingDirection,
    grid_direction: TableContainingDirection,
    language: []const u8,
    narrow_clear: ?FigureClear = null,
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(@This()).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "narrow_clear")) {
                if (self.narrow_clear) |value| { try jw.objectField(name); try jw.write(value); }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }
    const JsonFields = struct { max_viewport_width_px: u32, containing_direction: TableContainingDirection,
        grid_direction: TableContainingDirection, language: []const u8, narrow_clear: std.json.Value = .null };
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParse(JsonFields, a, source, strict));
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParseFromValue(JsonFields, a, source, strict));
    }
    fn fromJson(value: JsonFields) error{ UnexpectedToken, InvalidEnumTag }!@This() {
        if (value.max_viewport_width_px == 0 or value.language.len == 0 or value.language.len > 32 * 1024 * 1024 or
            !std.unicode.utf8ValidateSlice(value.language)) return error.UnexpectedToken;
        const narrow_clear: ?FigureClear = switch (value.narrow_clear) {
            .null => null,
            .string => |name| std.meta.stringToEnum(FigureClear, name) orelse return error.InvalidEnumTag,
            else => return error.UnexpectedToken,
        };
        return .{ .max_viewport_width_px = value.max_viewport_width_px, .containing_direction = value.containing_direction,
            .grid_direction = value.grid_direction, .language = value.language, .narrow_clear = narrow_clear };
    }
};
pub const Table = struct {
    caption: []const Span = &.{},
    /// Non-null is authoritative; flat caption must be empty.
    caption_blocks: ?[]const Block = null,
    rows: []const Row = &.{},
    geometry: ?TableGeometry = null,
    style: ?TableStyle = null,
    block_viewport: ?*const TableBlockViewport = null,
    float_viewport: ?TableFloatViewport = null,

    pub fn jsonStringify(self: Table, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("caption");
        try jw.write(self.caption);
        if (self.float_viewport) |policy| { try jw.objectField("float_viewport"); try jw.write(policy); }
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
        if (self.block_viewport) |viewport| { try jw.objectField("block_viewport"); try jw.write(viewport.*); }
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
/// Closed compiled paint semantics from the authenticated Vector screen module.
/// The six-state light/dark palette, active-over-hover priority, underline and
/// focus-visible rules are fixed by vector_new_link_v1, never reader link defaults.
pub const MissingLinkPaint = enum(u8) { vector_new_link_v1 = 0 };

/// The compiler and Stored model share the same semantic variants while keeping
/// their own Span metadata. Missing content is real text/action, never an image.
pub fn FigureContentFor(comptime SpanType: type) type {
    return union(enum) {
        image: Image,
        missing: Missing,
        pub const Image = struct { span: SpanType, sizing: FigureSizingPolicy };
        /// Label inline-block content width. Em lengths are producer-resolved
        /// normal-body lengths, like caption_line_height; label scale is not reapplied.
        /// Missing content wraps at word boundaries, then at emergency grapheme
        /// boundaries for an unbreakable token. Producers admit only that policy;
        /// consumers must implement it, not borrow their ordinary word-wrap default.
        pub const Missing = struct {
            label: SpanType, width: StyleLength, line_height: StyleLength,
            link_paint: ?MissingLinkPaint = null,
            pub fn jsonStringify(self: @This(), jw: anytype) !void {
                try jw.beginObject();
                try jw.objectField("label"); try jw.write(self.label);
                try jw.objectField("width"); try jw.write(self.width);
                try jw.objectField("line_height"); try jw.write(self.line_height);
                if (self.link_paint) |paint| { try jw.objectField("link_paint"); try jw.write(paint); }
                try jw.endObject();
            }
        };
        pub fn span(self: @This()) SpanType {
            return switch (self) { .image => |value| value.span, .missing => |value| value.label };
        }
        pub fn spanPtr(self: *@This()) *SpanType {
            return switch (self.*) { .image => |*value| &value.span, .missing => |*value| &value.label };
        }
    };
}
pub const FigureContent = FigureContentFor(Span);

// Preserve field presence separately from null for the strict legacy/missing XOR.
fn FigureJsonField(comptime T: type) type {
    return struct {
        present: bool = false,
        value: ?T = null,
        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
            return .{ .present = true, .value = try std.json.innerParse(?T, a, source, options) };
        }
        pub fn jsonParseFromValue(a: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
            return .{ .present = true, .value = try std.json.innerParseFromValue(?T, a, source, options) };
        }
    };
}

pub const FigureBorderEdge = BorderEdgeFor(FigureColor);
pub const FigureBorderEdges = BorderEdgesFor(FigureBorderEdge);
/// One anonymous media grid and its external bottom caption share a semantic
/// Figure owner. These physical edges use the existing table border algebra.
pub const AvailableWidthLimit = struct { percent: f32, subtract: StyleLength };
/// Explicit parent font for the zero-line-height media anchor, never alt/caption style.
pub const FigureMediaStrut = struct {
    font_scale: f32,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    language: []const u8 = "",
    direction: BidiResolvedDirection,
    font_features: ?FontFeaturePolicy = null,

    pub fn jsonStringify(self: FigureMediaStrut, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(FigureMediaStrut).@"struct".field_names) |field_name| {
            const features_field = comptime std.mem.eql(u8, field_name, "font_features");
            if (!features_field or self.font_features != null) {
                try jw.objectField(field_name);
                try jw.write(@field(self, field_name));
            }
        }
        try jw.endObject();
    }
};
pub const FigureMediaGraphic = enum(u8) { magnify_clip_ltr_v1 = 0, magnify_clip_rtl_v1 = 1 };
pub const FigureGraphicPaint = struct { graphic: FigureMediaGraphic, invert: bool = false };
pub const FigureMediaAfter = struct {
    width: StyleLength, height: StyleLength,
    side: TableFloatSide, inset: StyleLength, bottom: StyleLength,
    paint: ?FigureGraphicPaint = null,
};
pub const FigureFocusOutline = struct {
    width: StyleLength, color: FigureColor, radius: StyleLength, offset: StyleLength,
};
pub const FigureLinkState = struct { foreground: []const u8, underline: bool };
/// Fixed source-computed state colors, independent of the reader theme.
pub const FigureLinkPaint = struct {
    normal: FigureLinkState, hover: FigureLinkState, active: FigureLinkState,
    visited: FigureLinkState, visited_hover: FigureLinkState, visited_active: FigureLinkState,
    underline_on_focus: bool,
    focus_outline: ?FigureFocusOutline = null,
};
pub const LinkState = FigureLinkState;
/// Ordinary links retain independent hover+active combinations. Existing Figure
/// state fields and their six-state wire encoding remain unchanged.
pub const LinkPaint = struct {
    normal: LinkState, hover: LinkState, active: LinkState, hover_active: LinkState,
    visited: LinkState, visited_hover: LinkState, visited_active: LinkState, visited_hover_active: LinkState,
    underline_on_focus: bool,
    focus_outline: ?FigureFocusOutline = null,
    // A data/wire prefix only; never a source proof that combined states equal active.
    pub fn sixStatePrefix(self: LinkPaint) FigureLinkPaint {
        return .{ .normal = self.normal, .hover = self.hover, .active = self.active, .visited = self.visited,
            .visited_hover = self.visited_hover, .visited_active = self.visited_active,
            .underline_on_focus = self.underline_on_focus, .focus_outline = self.focus_outline };
    }
    pub fn fromSixStatePrefix(prefix: FigureLinkPaint, hover_active: LinkState, visited_hover_active: LinkState) LinkPaint {
        return .{ .normal = prefix.normal, .hover = prefix.hover, .active = prefix.active, .hover_active = hover_active,
            .visited = prefix.visited, .visited_hover = prefix.visited_hover, .visited_active = prefix.visited_active,
            .visited_hover_active = visited_hover_active, .underline_on_focus = prefix.underline_on_focus, .focus_outline = prefix.focus_outline };
    }
};
pub fn linkPaintState(paint: LinkPaint, visited: bool, hover: bool, active: bool, focused: bool) LinkState {
    var state = if (visited) (if (active) (if (hover) paint.visited_hover_active else paint.visited_active) else if (hover) paint.visited_hover else paint.visited)
        else (if (active) (if (hover) paint.hover_active else paint.active) else if (hover) paint.hover else paint.normal);
    if (focused and paint.underline_on_focus) state.underline = true;
    return state;
}
pub fn validLinkPaint(paint: LinkPaint) bool {
    return validFigureLinkPaint(paint.sixStatePrefix()) and isCanonicalRgb(paint.hover_active.foreground) and isCanonicalRgb(paint.visited_hover_active.foreground);
}
pub const FigureMediaLayout = struct {
    strut: FigureMediaStrut,
    vertical_align: InlineBoxVerticalAlign,
    max_width: ?AvailableWidthLimit = null,
    positioning: ?ContainerPositioning = null,
    after: ?FigureMediaAfter = null,
    focus_outline: ?FigureFocusOutline = null,
};
pub const FigureViewportState = struct {
    max_width_px: u32,
    wrapper: ContainerStyle,
    media: FigureMediaLayout,
    caption_before: ?ContainerStyle = null,
};
pub const max_figure_viewport_states = 16;
pub const TableCaptionLayout = struct {
    collapse: BorderCollapse,
    wrapper: ContainerStyle,
    table_border: FigureBorderEdges,
    caption_border: FigureBorderEdges,
    media: FigureMediaLayout,
    caption_before: ?ContainerStyle = null,
    viewport_states: []const FigureViewportState = &.{},
    missing_link_paint: ?FigureLinkPaint = null,
    caption_link_paint: ?FigureLinkPaint = null,
    pub fn jsonStringify(self: TableCaptionLayout, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(TableCaptionLayout).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "missing_link_paint") or std.mem.eql(u8, name, "caption_link_paint")) {
                if (@field(self, name)) |paint| { try jw.objectField(name); try jw.write(paint); }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }
};

/// A block media owner uses ordinary block width and one explicit inline line.
/// It is distinct from the anonymous table used by table-caption Figures.
pub const FigureBlockMediaRendition = struct { url: []const u8, sha256: []const u8 };
pub fn validFigureBlockMediaRendition(value: FigureBlockMediaRendition) bool {
    if (value.url.len > 8192 or !std.mem.startsWith(u8, value.url, "https://") or value.sha256.len != 64) return false;
    for (value.sha256) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    const path = std.mem.indexOfScalarPos(u8, value.url, 8, '/') orelse return false;
    if (path == 8 or path + 1 == value.url.len) return false;
    const host = value.url[8..path];
    if (host[0] == '.' or host[host.len - 1] == '.' or std.mem.indexOfScalar(u8, host, '.') == null) return false;
    for (host) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return false;
    for (value.url) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '\\' or byte == '#') return false;
    return true;
}
pub const FigureBlockMediaState = struct {
    max_width_px: u32,
    wrapper: ContainerStyle,
    media: FigureMediaLayout,
};
pub const FigureBlockMediaLayout = struct {
    wrapper: ContainerStyle,
    media: FigureMediaLayout,
    preferred_width_px: u32,
    natural_width: u32,
    natural_height: u32,
    rendition_1x: FigureBlockMediaRendition,
    rendition_2x: FigureBlockMediaRendition,
    viewport_states: []const FigureBlockMediaState = &.{},
};

fn validFigureBlockMediaState(wrapper: ContainerStyle, media: FigureMediaLayout) bool {
    if (!validContainerStyle(wrapper) or !validFigureMediaLayout(media) or
        wrapper.width == null or wrapper.width.? != .auto or wrapper.line_height == null or
        wrapper.text_align == null or wrapper.owner_font_scale == null or
        wrapper.owner_font_scale.? != media.strut.font_scale or
        (wrapper.margins == null and wrapper.margin_values == null) or
        media.vertical_align != .middle or media.positioning != null or
        media.after != null or media.focus_outline != null) return false;
    // The first source domain is a bare inline SPAN in an ordinary auto-width
    // block. Other box/formatting effects need their own explicit representation.
    inline for (@typeInfo(ContainerStyle).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "line_height") or
            std.mem.eql(u8, name, "text_align") or std.mem.eql(u8, name, "owner_font_scale") or
            std.mem.eql(u8, name, "margins") or std.mem.eql(u8, name, "margin_values")) continue;
        if (@field(wrapper, name) != null) return false;
    }
    if (media.max_width) |limit| if (limit.percent != 100 or limit.subtract.value != 0) return false;
    return true;
}
pub fn validFigureBlockMediaLayout(value: FigureBlockMediaLayout) bool {
    if (value.preferred_width_px == 0 or value.natural_width == 0 or value.natural_height == 0 or
        value.natural_width > std.math.maxInt(u32) / 2 or value.natural_height > std.math.maxInt(u32) / 2 or
        !validFigureBlockMediaRendition(value.rendition_1x) or !validFigureBlockMediaRendition(value.rendition_2x) or
        std.mem.eql(u8, value.rendition_1x.url, value.rendition_2x.url) or
        std.mem.eql(u8, value.rendition_1x.sha256, value.rendition_2x.sha256) or
        !validFigureBlockMediaState(value.wrapper, value.media) or
        value.viewport_states.len > max_figure_viewport_states) return false;
    var previous: ?u32 = null;
    for (value.viewport_states) |state| {
        if (previous) |bound| if (state.max_width_px >= bound) return false;
        previous = state.max_width_px;
        if (!validFigureBlockMediaState(state.wrapper, state.media)) return false;
    }
    return true;
}
pub fn resolveFigureBlockMediaState(value: FigureBlockMediaLayout, viewport_css_px: f64) error{InvalidPresentation}!?FigureBlockMediaState {
    if (!validFigureBlockMediaLayout(value) or !std.math.isFinite(viewport_css_px) or viewport_css_px < 0) return error.InvalidPresentation;
    var selected: ?FigureBlockMediaState = null;
    for (value.viewport_states) |state| {
        if (viewport_css_px > @as(f64, @floatFromInt(state.max_width_px))) break;
        selected = state;
    }
    return selected;
}
fn validFigureBlockMediaContent(value: anytype, layout: FigureBlockMediaLayout) bool {
    if (!validFigureBlockMediaLayout(layout) or value.content != .image or
        value.placement != .none or value.clear != .none or value.frame_min_width != null or
        value.frame_border.kind != .none or value.image_border.kind != .none or
        value.frame_background.kind != .transparent or value.image_background.kind != .transparent or
        value.caption_background.kind != .transparent) return false;
    if (comptime @hasField(@TypeOf(value), "table_caption_layout")) if (value.table_caption_layout != null) return false;
    if (comptime @hasField(@TypeOf(value), "caption")) if (value.caption.len != 0) return false;
    if (comptime @hasField(@TypeOf(value), "caption_blocks")) if (value.caption_blocks) |blocks| if (blocks.len != 0) return false;
    if (comptime @hasField(@TypeOf(value), "caption_text_align")) if (value.caption_text_align != null) return false;
    inline for (.{ "margins", "image_insets", "caption_padding" }) |name|
        inline for (.{ "top", "right", "bottom", "left" }) |side|
            if (@field(@field(value, name), side).value != 0) return false;
    const span = value.content.image.span;
    if (!std.mem.eql(u8, @tagName(span.kind), "text") or span.target.len != 0) return false;
    const image = span.image orelse return false;
    if (image.map != null or image.static_poster != null) return false;
    return true;
}

pub const Figure = struct {
    content: FigureContent,
    caption: []const Span = &.{},
    caption_text_align: ?CellTextAlign = null,
    /// Non-null is authoritative, including an explicitly empty caption.
    caption_blocks: ?[]const Block = null,
    format: FigureFormat,
    /// Physical content-box CSS floor, separate from media axes and margins.
    frame_min_width: ?StyleLength = null,
    table_caption_layout: ?TableCaptionLayout = null,
    block_media_layout: ?FigureBlockMediaLayout = null,
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
        // Legacy image names and order stay byte-exact in Reader JSON.
        switch (self.content) {
            .image => |image| { try jw.objectField("image_span"); try jw.write(image.span); },
            .missing => |missing| { try jw.objectField("missing_content"); try jw.write(missing); },
        }
        inline for (@typeInfo(Figure).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "content")) continue;
            if (comptime std.mem.eql(u8, name, "frame_min_width")) {
                if (self.content == .image) {
                    try jw.objectField("sizing"); try jw.write(self.content.image.sizing);
                }
                if (self.frame_min_width) |minimum| { try jw.objectField(name); try jw.write(minimum); }
            } else if (comptime std.mem.eql(u8, name, "table_caption_layout")) {
                if (self.table_caption_layout) |layout| { try jw.objectField(name); try jw.write(layout); }
            } else if (comptime std.mem.eql(u8, name, "block_media_layout")) {
                if (self.block_media_layout) |layout| { try jw.objectField(name); try jw.write(layout); }
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
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Figure {
        var strict = options;
        strict.ignore_unknown_fields = false;
        strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParse(FigureJson, a, source, strict));
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Figure {
        var strict = options;
        strict.ignore_unknown_fields = false;
        strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParseFromValue(FigureJson, a, source, strict));
    }
    fn fromJson(value: FigureJson) error{UnexpectedToken}!Figure {
        if (value.image_span.present == value.missing_content.present or
            value.image_span.present != value.sizing.present) return error.UnexpectedToken;
        const content: FigureContent = if (value.image_span.present)
            .{ .image = .{ .span = value.image_span.value orelse return error.UnexpectedToken,
                .sizing = value.sizing.value orelse return error.UnexpectedToken } }
        else .{ .missing = value.missing_content.value orelse return error.UnexpectedToken };
        var result: Figure = undefined;
        inline for (@typeInfo(Figure).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "content")) result.content = content
            else @field(result, name) = @field(value, name);
        }
        if (!validFigure(result)) return error.UnexpectedToken;
        return result;
    }
};
const FigureJson = struct {
    image_span: FigureJsonField(Span) = .{},
    missing_content: FigureJsonField(FigureContent.Missing) = .{},
    caption: []const Span = &.{},
    caption_text_align: ?CellTextAlign = null,
    /// Non-null is authoritative, including an explicitly empty caption.
    caption_blocks: ?[]const Block = null,
    format: FigureFormat,
    /// Required resolved policy; no reader MIME inference or implicit default.
    sizing: FigureJsonField(FigureSizingPolicy) = .{},
    /// Physical content-box CSS floor, separate from media axes and margins.
    frame_min_width: ?StyleLength = null,
    table_caption_layout: ?TableCaptionLayout = null,
    block_media_layout: ?FigureBlockMediaLayout = null,
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
// Private shared declaration candidate. Generic semantic data, not CSS source.
pub const ContainerWidth = union(enum) { auto, length: StyleWidth, fit_content };
pub const ContainerMaxWidth = union(enum) { none, length: StyleWidth };
pub const ContainerBoxSizing = enum { content_box, border_box };
pub const ContainerLayout = enum { flow, flex_row };
pub const ContainerAlignItems = enum { stretch, start, center, end };
// Null keeps the CSS initial flex value 0 1 auto; none is 0 0 auto.
pub const ContainerFlexItem = enum { none };
pub const ContainerColor = union(enum) {
    transparent,
    rgb: []const u8,
    light_dark: struct { light: []const u8, dark: []const u8 },
};
pub const ContainerBorderEdge = BorderEdgeFor(ContainerColor);
pub const ContainerBorderEdges = BorderEdgesFor(ContainerBorderEdge);
pub const ContainerBorder = union(enum) {
    none,
    solid: struct { width: StyleLength, color: ContainerColor },
    edges: ContainerBorderEdges,
};
pub const ContainerLineHeight = union(enum) {
    normal,
    // Inherited unitless values recompute at each descendant's actual font.
    multiplier: f32,
    // A computed absolute length; em has already resolved to normal-body units.
    length: StyleLength,
    pub fn jsonStringify(self: ContainerLineHeight, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .normal => { try jw.objectField("normal"); try jw.write(.{}); },
            .multiplier => |value| { try jw.objectField("multiplier"); try jw.write(@as(f64, value)); },
            .length => |value| { try jw.objectField("length"); try jw.write(value); },
        }
        try jw.endObject();
    }
};
pub const ContainerFloatOverride = enum { none, left, right };
pub const ContainerMargin = union(enum) { auto, length: StyleLength };
pub const ContainerMargins = struct {
    top: ContainerMargin, right: ContainerMargin,
    bottom: ContainerMargin, left: ContainerMargin,
};
pub const ContainerScreenMaxWidth = struct {
    // Compare against the one logical rendering viewport in CSS px, not this
    // box's containing block. Terminal projection explicitly uses 8px/column.
    max_width_px: u32,
    // Null inherits the base field. Explicit auto/none can reset width limits.
    width: ?ContainerWidth = null,
    max_width: ?ContainerMaxWidth = null,
    box_sizing: ?ContainerBoxSizing = null,
    line_height: ?ContainerLineHeight = null,
    float_side: ?ContainerFloatOverride = null,
    margins: ?ContainerMargins = null,
    // Null inherits; explicit none clears the preceding/base clearance.
    clear: ?FigureClear = null,
    // Semantic viewport bands, greatest bound first. The producer has already
    // resolved CSS importance/order in every band. Children cannot nest lists.
    following_rules: []const ContainerScreenMaxWidth = &.{},
    pub fn jsonStringify(self: ContainerScreenMaxWidth, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("max_width_px"); try jw.write(self.max_width_px);
        inline for (.{ "width", "max_width", "box_sizing", "line_height", "float_side", "margins", "clear" }) |name| {
            if (@field(self, name)) |present| { try jw.objectField(name); try jw.write(present); }
        }
        if (self.following_rules.len != 0) { try jw.objectField("following_rules"); try jw.write(self.following_rules); }
        try jw.endObject();
    }
};
pub const max_container_screen_rules = 16;
/// Computed pair: visible/visible or auto/auto. Auto is a scroll BFC.
/// Auto is a local padding-box scrollport and BFC, not document scrolling.
/// Native offsets/clips belong to its real owner; Stored contains no UI state.
pub const ContainerOverflow = enum { visible, auto };
/// Auto-height balanced fragmentation of one ordered child flow. Gap em is
/// computed once at this owner into normal-body units, never from a child span.
pub const ContainerColumns = struct { count: u16, gap: StyleLength };
pub const ContainerPositioning = enum(u8) { relative_auto = 0 };
pub const GenericFontFamily = enum(u8) { sans_serif = 0, serif = 1 };
pub const FontFamilyStack = struct {
    names: []const []const u8,
    fallback: GenericFontFamily,
};
pub const ContainerFontFamily = union(enum) {
    sans_serif,
    stack: FontFamilyStack,

    pub fn jsonStringify(self: ContainerFontFamily, jw: anytype) !void {
        switch (self) {
            .sans_serif => try jw.write("sans_serif"),
            .stack => |value| {
                try jw.beginObject(); try jw.objectField("stack"); try jw.write(value); try jw.endObject();
            },
        }
    }
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!ContainerFontFamily {
        const value = try std.json.innerParse(std.json.Value, a, source, options);
        return jsonParseFromValue(a, value, options);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!ContainerFontFamily {
        if (value == .string) return if (std.mem.eql(u8, value.string, "sans_serif")) .sans_serif else error.InvalidEnumTag;
        if (value != .object or value.object.count() != 1) return error.UnexpectedToken;
        const stack = value.object.get("stack") orelse return error.UnknownField;
        if (stack != .object or stack.object.count() != 2) return error.UnexpectedToken;
        const raw_names = stack.object.get("names") orelse return error.MissingField;
        const raw_fallback = stack.object.get("fallback") orelse return error.MissingField;
        if (raw_names != .array or raw_names.array.items.len > 16 or raw_fallback != .string) return error.UnexpectedToken;
        const fallback = std.meta.stringToEnum(GenericFontFamily, raw_fallback.string) orelse return error.InvalidEnumTag;
        const names = try a.alloc([]const u8, raw_names.array.items.len);
        for (raw_names.array.items, names) |raw, *name| {
            if (raw != .string or !validFontFamilyName(raw.string)) return error.UnexpectedToken;
            name.* = try a.dupe(u8, raw.string);
        }
        return .{ .stack = .{ .names = names, .fallback = fallback } };
    }
};
pub fn validFontFamilyName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name) or
        !std.mem.eql(u8, name, std.mem.trim(u8, name, " \t\r\n\x0c"))) return false;
    var folded: [128]u8 = undefined;
    var length: usize = 0;
    for (name) |byte| {
        if (byte < 0x20 or byte >= 0x7f or byte == '[' or byte == ']') return false;
        if (byte == ' ' and length != 0 and folded[length - 1] == ' ') continue;
        folded[length] = std.ascii.toLower(byte); length += 1;
    }
    // A quoted generic-looking source name is not the generic fallback. The
    // selected native APIs alias these spellings, so withhold this named case.
    for ([_][]const u8{ "serif", "sans-serif", "sans serif", "sans", "monospace", "cursive", "fantasy",
        "system", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded", "emoji", "math", "fangsong" }) |alias|
        if (std.mem.eql(u8, folded[0..length], alias)) return false;
    return true;
}
pub fn sameFontFamilyRequest(left: ?ContainerFontFamily, right: ?ContainerFontFamily) bool {
    const a = left orelse return right == null;
    const b = right orelse return false;
    switch (a) {
        .sans_serif => return b == .sans_serif,
        .stack => |stack| {
            if (b != .stack or stack.fallback != b.stack.fallback or stack.names.len != b.stack.names.len) return false;
            for (stack.names, b.stack.names) |x, y| if (!std.mem.eql(u8, x, y)) return false;
            return true;
        },
    }
}
pub fn validContainerFontFamily(value: ContainerFontFamily) bool {
    switch (value) {
        .sans_serif => return true,
        .stack => |stack| {
            if (stack.names.len > 16) return false;
            for (stack.names) |name| if (!validFontFamilyName(name)) return false;
            return true;
        },
    }
}

pub const SectionHeadingStyle = struct {
    box: ContainerStyle,
    font: InlineFontSnapshot,
    direction: BidiResolvedDirection,
    title_wrap: ?TextWrap = null,
    anchor_reveal: ?HeadingAnchorReveal = null,
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("box"); try jw.write(self.box);
        try jw.objectField("font"); try jw.write(self.font);
        try jw.objectField("direction"); try jw.write(self.direction);
        if (self.title_wrap) |value| { try jw.objectField("title_wrap"); try jw.write(value); }
        if (self.anchor_reveal) |value| { try jw.objectField("anchor_reveal"); try jw.write(value); }
        try jw.endObject();
    }
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!SectionHeadingStyle {
        const value = try std.json.innerParse(std.json.Value, a, source, options);
        return jsonParseFromValue(a, value, options);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, value: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!SectionHeadingStyle {
        if (value != .object or value.object.count() < 3 or value.object.count() > 5) return error.UnexpectedToken;
        for (value.object.keys()) |name| if (!std.mem.eql(u8, name, "box") and !std.mem.eql(u8, name, "font") and
            !std.mem.eql(u8, name, "direction") and !std.mem.eql(u8, name, "title_wrap") and
            !std.mem.eql(u8, name, "anchor_reveal")) return error.UnexpectedToken;
        const direction = value.object.get("direction") orelse return error.MissingField;
        if (direction != .string or (!std.mem.eql(u8, direction.string, "ltr") and !std.mem.eql(u8, direction.string, "rtl"))) return error.InvalidEnumTag;
        const Raw = struct { box: ContainerStyle, font: InlineFontSnapshot, direction: BidiResolvedDirection,
            title_wrap: ?TextWrap = null, anchor_reveal: ?HeadingAnchorReveal = null };
        const raw = try std.json.innerParseFromValue(Raw, a, value, options);
        const result: SectionHeadingStyle = .{ .box = raw.box, .font = raw.font, .direction = raw.direction,
            .title_wrap = raw.title_wrap, .anchor_reveal = raw.anchor_reveal };
        if (!validSectionHeadingStyle(result)) return error.UnexpectedToken;
        return result;
    }
};
pub fn validSectionHeadingStyle(value: SectionHeadingStyle) bool {
    if (value.anchor_reveal) |reveal| if (!validHeadingAnchorReveal(reveal)) return false;
    const box = value.box;
    if (!validContainerStyle(box) or box.margins == null or box.padding == null or box.border == null or
        box.owner_font_scale == null or box.line_height == null or box.clear == null or box.font_family == null) return false;
    const font = value.font;
    if (font.font_family != null and !sameFontFamilyRequest(font.font_family, box.font_family)) return false;
    if (!validInlineFontSnapshot(font) or font.font_scale == null or font.font_scale_basis != .normal_body or font.font_scale.? != box.owner_font_scale.? or
        font.small or font.superscript or font.subscript or font.font_normalized or font.code or font.classes.len != 0 or font.role != .normal or
        font.language.len == 0 or font.language.len > 1024 or !std.unicode.utf8ValidateSlice(font.language) or
        std.mem.indexOfScalar(u8, font.language, 0) != null) return false;
    return (box.width == null or box.width.? == .auto) and (box.max_width == null or box.max_width.? == .none) and
        (box.layout == null or box.layout.? == .flow) and (box.overflow == null or box.overflow.? == .visible) and
        box.float_side == null and box.flex_item == null and box.align_items == null and box.columns == null and
        box.positioning == null and box.screen_max_width == null and box.height == null and box.min_height == null and box.margin_values == null;
}
pub fn validSectionHeadingCompanion(section: anytype) bool {
    // Legacy build Sections have no authored heading capability. Decline at
    // compile time before touching the new identity or companion fields.
    inline for (.{ "heading_style", "level", "title", "blocks" }) |field|
        if (comptime !@hasField(@TypeOf(section), field)) return false;
    if (section.level < 1 or section.level > 6 or section.title.len == 0 or section.blocks.len == 0) return false;
    const heading = section.blocks[0];
    inline for (.{ "kind", "depth", "level", "list_path", "number", "feature", "table", "spans" }) |field|
        if (comptime !@hasField(@TypeOf(heading), field)) return false;
    const section_anchor: []const u8 = if (comptime @hasField(@TypeOf(section), "anchor")) section.anchor else "";
    const section_fallback: []const u8 = if (comptime @hasField(@TypeOf(section), "anchor_fallback")) section.anchor_fallback else "";
    if (section.heading_style) |style| if (style.anchor_reveal) |reveal| {
        if (section_anchor.len == 0 or (reveal.fallback_top != null) != (section_fallback.len != 0)) return false;
        if (section_fallback.len != 0 and std.mem.eql(u8, section_anchor, section_fallback)) return false;
    };
    const heading_anchor: []const u8 = if (comptime @hasField(@TypeOf(heading), "anchor")) heading.anchor else "";
    const heading_fallback: []const u8 = if (comptime @hasField(@TypeOf(heading), "anchor_fallback")) heading.anchor_fallback else "";
    if (!std.mem.eql(u8, @tagName(heading.kind), "heading") or heading.depth != 0 or heading.level != section.level or
        !std.mem.eql(u8, heading_anchor, section_anchor) or !std.mem.eql(u8, heading_fallback, section_fallback) or
        heading.list_path.len != 0 or heading.number.len != 0 or heading.feature != null or heading.table != null) return false;
    inline for (.{ "flow", "container", "figure", "style", "rule_style", "text_align" }) |field|
        if (comptime @hasField(@TypeOf(heading), field)) { if (@field(heading, field) != null) return false; };
    var offset: usize = 0;
    for (heading.spans) |span| {
        // Generic build spans without ruby must not instantiate its stricter
        // child/decoration contract, even when this runtime arm is unreachable.
        if (comptime @hasField(@TypeOf(span), "ruby") or @hasField(@TypeOf(span), "inline_padding_group") or @hasField(@TypeOf(span), "inline_action_group")) if (spanHasRuby(span) or spanHasInlinePaddingGroup(span) or spanHasInlineActionGroup(span)) {
            const Match = struct {
                title: []const u8, offset: usize,
                fn emit(self: *@This(), child: @TypeOf(span)) error{InvalidPresentation}!void {
                    const trail: []const u8 = if (comptime @hasField(@TypeOf(child), "trail")) child.trail else "";
                    for ([_][]const u8{ child.text, trail }) |text| {
                        if (text.len > self.title.len - self.offset or !std.mem.eql(u8, text, self.title[self.offset..][0..text.len])) return error.InvalidPresentation;
                        self.offset += text.len;
                    }
                }
            };
            var match: Match = .{ .title = section.title, .offset = offset };
            visitRubyFallback(&[_]@TypeOf(span){span}, &match, Match.emit) catch return false;
            offset = match.offset;
            continue;
        };
        // The existing build encoder defaults these optional source fields to
        // no image and empty trail/direction, including Compiler.Span.
        if (comptime @hasField(@TypeOf(span), "image")) { if (span.image != null) return false; }
        const trail: []const u8 = if (comptime @hasField(@TypeOf(span), "trail")) span.trail else "";
        const direction: []const u8 = if (comptime @hasField(@TypeOf(span), "direction")) span.direction else "";
        const kind = @tagName(span.kind);
        if (span.text.len == 0 or trail.len != 0 or direction.len != 0 or
            (!std.mem.eql(u8, kind, "text") and !std.mem.eql(u8, kind, "link") and !std.mem.eql(u8, kind, "external_link"))) return false;
        if (span.text.len > section.title.len - offset or !std.mem.eql(u8, span.text, section.title[offset..][0..span.text.len])) return false;
        offset += span.text.len;
    }
    return offset == section.title.len;
}

pub const ContainerStyle = struct {
    // Box em lengths are computed once at this box's font origin into
    // normal-body units. Width percentages use its containing block content box.
    margins: ?StyleEdges = null,
    padding: ?StyleEdges = null,
    width: ?ContainerWidth = null,
    float_side: ?TableFloatSide = null,
    clear: ?FigureClear = null,
    max_width: ?ContainerMaxWidth = null,
    box_sizing: ?ContainerBoxSizing = null,
    layout: ?ContainerLayout = null,
    align_items: ?ContainerAlignItems = null,
    flex_item: ?ContainerFlexItem = null,
    background: ?ContainerColor = null,
    border: ?ContainerBorder = null,
    line_height: ?ContainerLineHeight = null,
    text_align: ?CellTextAlign = null,
    screen_max_width: ?ContainerScreenMaxWidth = null,
    overflow: ?ContainerOverflow = null,
    // Computed owner font relative to normal body, independent of descendant
    // span overrides. Null inherits the enclosing owner/body font; zero is real.
    owner_font_scale: ?f32 = null,
    // Fixed used CSS height, not a minimum or line-height. Em is computed
    // once at this owner into normal-body units; null auto, zero explicit.
    height: ?StyleLength = null,
    columns: ?ContainerColumns = null,
    // No flow displacement. Paint in the nearest content stacking context
    // zero-positioned phase with ancestor clips and reverse hit priority.
    positioning: ?ContainerPositioning = null,
    // Minimum used-height floor; retains computed height auto and is not a BFC.
    // Preserve the computed value before any border-box content-floor adjustment.
    min_height: ?StyleLength = null,
    // Computed base margins retaining auto for the consumer's actual width and
    // formatting context. Exclusive with numeric margins; null preserves old bytes.
    margin_values: ?ContainerMargins = null,
    font_family: ?ContainerFontFamily = null,
    pub fn jsonStringify(self: ContainerStyle, jw: anytype) !void {
        try writeOptionalStyleFields(self, jw);
    }
};
pub fn ContainerFor(comptime BlockType: type) type {
    return struct { blocks: []const BlockType, style: ContainerStyle = .{} };
}
pub const Container = ContainerFor(Block);

/// Authored separator box. Relative lengths have already been normalized to
/// the normal-body font basis. Width is auto in the containing content box;
/// border/padding are zero, and margins participate in ordinary block flow.
pub const RuleStyle = struct {
    height: StyleLength,
    fill: ContainerColor,
    margins: StyleEdges,
    clear: ?FigureClear = null,
    const JsonFields = struct {
        height: StyleLength, fill: ContainerColor, margins: StyleEdges,
        clear: std.json.Value = .null,
    };
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParse(JsonFields, a, source, strict));
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        var strict = options; strict.ignore_unknown_fields = false; strict.duplicate_field_behavior = .@"error";
        return fromJson(try std.json.innerParseFromValue(JsonFields, a, source, strict));
    }
    fn fromJson(value: JsonFields) error{ UnexpectedToken, InvalidEnumTag }!@This() {
        const clear: ?FigureClear = switch (value.clear) {
            .null => null,
            .string => |name| std.meta.stringToEnum(FigureClear, name) orelse return error.InvalidEnumTag,
            else => return error.UnexpectedToken,
        };
        return .{ .height = value.height, .fill = value.fill, .margins = value.margins, .clear = clear };
    }
    pub fn jsonStringify(self: RuleStyle, jw: anytype) !void {
        try jw.beginObject();
        inline for (.{ "height", "fill", "margins" }) |name| {
            try jw.objectField(name); try jw.write(@field(self, name));
        }
        if (self.clear) |clear| { try jw.objectField("clear"); try jw.write(clear); }
        try jw.endObject();
    }
};
pub fn validRuleStyle(value: RuleStyle) bool {
    return validStyleLength(value.height) and validContainerColor(value.fill) and validStyleEdges(value.margins);
}
pub fn validRuleStyleContext(block: anytype) bool {
    if (comptime !@hasField(@TypeOf(block), "rule_style")) return false;
    if (!std.mem.eql(u8, @tagName(block.kind), "rule") or block.depth != 0 or block.level != 0 or
        block.spans.len != 0 or block.feature != null or block.table != null or
        block.list_path.len != 0 or block.number.len != 0 or block.anchor.len != 0 or block.anchor_fallback.len != 0) return false;
    inline for (.{ "figure", "flow", "container", "style", "text_align" }) |field|
        if (comptime @hasField(@TypeOf(block), field)) { if (@field(block, field) != null) return false; };
    return true;
}

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
    container: ?Container = null,
    rule_style: ?RuleStyle = null,

    pub fn jsonStringify(self: Block, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Block).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "text_align") or std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "figure") or std.mem.eql(u8, name, "flow") or std.mem.eql(u8, name, "container") or std.mem.eql(u8, name, "rule_style")) {
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
    heading_style: ?SectionHeadingStyle = null,
    pub fn jsonStringify(self: Section, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Section).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "heading_style")) {
                if (self.heading_style) |present| { try jw.objectField(name); try jw.write(present); }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }
};
pub const Form = struct { relation: []const u8, target: []const u8, language: []const u8 };
pub const Sense = struct {
    block: usize,
    parent: ?usize = null,
    examples: []const usize = &.{},
    quotations: []const usize = &.{},
    notes: []const usize = &.{},
    form: ?Form = null,
    block_path: []const usize = &.{},
    example_paths: []const []const usize = &.{},
    quotation_paths: []const []const usize = &.{},
    note_paths: []const []const usize = &.{},
    pub fn jsonStringify(self: Sense, jw: anytype) !void { try writeLexicalFields(self, jw); }
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
    introduction_paths: []const []const usize = &.{},
    other_block_paths: []const []const usize = &.{},
    pub fn jsonStringify(self: Lexeme, jw: anytype) !void { try writeLexicalFields(self, jw); }
};
fn writeLexicalFields(value: anytype, jw: anytype) !void {
    try jw.beginObject();
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "block_path") or std.mem.endsWith(u8, name, "_paths")) {
            if (@field(value, name).len != 0) { try jw.objectField(name); try jw.write(@field(value, name)); }
        } else { try jw.objectField(name); try jw.write(@field(value, name)); }
    }
    try jw.endObject();
}
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
// Source-qualified adjoining edges of the semantic Section body only.
// The app owns its assigned origin; no page-chrome numeric margins are stored.
pub const BodyAdjoiningPolicy = enum(u8) {
    ordinary = 1,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const name = try std.json.innerParse([]const u8, a, source, options);
        return std.meta.stringToEnum(@This(), name) orelse error.InvalidEnumTag;
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
        if (value != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), value.string) orelse error.InvalidEnumTag;
    }
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
    body_adjoining: ?BodyAdjoiningPolicy = null,

    pub fn jsonStringify(self: Entry, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Entry).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "body_adjoining")) {
                if (self.body_adjoining) |present| {
                    try jw.objectField(name); try jw.write(present);
                }
            } else { try jw.objectField(name); try jw.write(@field(self, name)); }
        }
        try jw.endObject();
    }
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
/// Canonical handler-key grammar. Actual handler/language validity is
/// established by the producer's exact language-qualified metadata evidence.
pub fn validSvgLanguageIdentity(value: []const u8) bool {
    if (value.len == 0 or value.len > 32 * 1024 * 1024) return false;
    var segment = false;
    for (value) |byte| {
        if (byte == '-') {
            if (!segment) return false;
            segment = false;
        } else if (byte >= 'a' and byte <= 'z') segment = true
        else return false;
    }
    return segment;
}
pub fn validStaticPosterIdentity(value: StaticPoster) bool {
    if (value.file_sha1.len != 40) return false;
    for (value.file_sha1) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    const stamp = value.file_timestamp;
    if (stamp.len != 20 or stamp[4] != '-' or stamp[7] != '-' or stamp[10] != 'T' or
        stamp[13] != ':' or stamp[16] != ':' or stamp[19] != 'Z') return false;
    for (stamp, 0..) |byte, i| if (i != 4 and i != 7 and i != 10 and i != 13 and i != 16 and i != 19)
        if (!std.ascii.isDigit(byte)) return false;
    const year = std.fmt.parseInt(u16, stamp[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, stamp[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, stamp[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, stamp[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, stamp[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, stamp[17..19], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 59) return false;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    return day <= month_days[month - 1] + @as(u8, if (month == 2 and leap) 1 else 0);
}
pub fn validInlineImage(value: InlineImage) bool {
    if (value.svg_language) |language| if (!validSvgLanguageIdentity(language)) return false;
    if (!validInlineImageFile(value.file)) return false;
    if (value.width_px) |width| if (width == 0) return false;
    if (value.height_px) |height| if (height == 0) return false;
    if (value.alt) |alt| if (!validInlineImageString(alt)) return false;
    if (value.tooltip) |tooltip| if (!validInlineImageString(tooltip)) return false;
    if (value.map) |map| if (!validImageMap(map)) return false;
    if (value.static_poster) |poster| {
        if (!std.ascii.endsWithIgnoreCase(value.file, ".stl") or !validInlineImageString(poster.label) or !validStaticPosterIdentity(poster)) return false;
        const width = value.width_px orelse return false;
        const height = value.height_px orelse return false;
        if (height != staticPosterHeight(width)) return false;
        if (value.map != null or value.svg_language != null or value.dark_mode_filter != null or value.vertical_align != null) return false;
        switch (poster.policy) { .three_d_stl_v1 => {} }
    }
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
fn inlineTableClass(classes: []const u8, name: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0b\x0c");
    while (tokens.next()) |token| if (std.mem.eql(u8, token, name)) return true;
    return false;
}
pub fn inlineTableEmbeddedMedia(span: anytype) bool {
    return inlineTableClass(span.classes, "wikidict-media");
}
/// This is the existing native text branch boundary, not a language heuristic.
pub fn inlineTableSpanSupported(span: anytype) bool {
    if (span.image != null) return false;
    const code = if (comptime @hasField(@TypeOf(span), "flags")) span.flags.code else span.code;
    if (code or (span.font_scale orelse 1) == 0 or !inlineTableClass(span.classes, "Egyp")) return true;
    const text: []const u8 = if (span.kind == .line_break) "\n" else span.text;
    var utf8 = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    while (utf8.nextCodepoint()) |scalar| if (scalar >= 0x13000 and scalar <= 0x13455) return false;
    return true;
}
pub fn inlineTableSpanSupportedM(span: anytype) bool {
    const trail: []const u8 = if (comptime @hasField(@TypeOf(span), "trail")) span.trail else "";
    if (span.image) |image| return validInlineImage(image) and image.map == null and
        image.static_poster == null and image.dark_mode_filter == null and image.vertical_align == null and
        span.text.len == 0 and trail.len == 0 and
        (if (span.kind == .text) span.target.len == 0 else if (span.kind == .link or span.kind == .external_link) span.target.len != 0 else false);
    return inlineTableSpanSupported(span);
}
pub fn inlineTableShapeSupported(table: anytype) bool { return inlineTableShapeSupportedFor(table, false); }
pub fn inlineTableShapeSupportedM(table: anytype) bool { return inlineTableShapeSupportedFor(table, true); }
fn inlineTableShapeSupportedFor(table: anytype, comptime m_images: bool) bool {
    if (table.caption.len != 0) return false;
    if (comptime @hasField(@TypeOf(table), "caption_blocks")) if (table.caption_blocks != null) return false;
    var has_cells = false;
    for (table.rows) |row| for (row.cells) |cell| {
        has_cells = true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table != null) return false;
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks != null) return false;
        for (cell.spans) |span| if (!(if (m_images) inlineTableSpanSupportedM(span) else inlineTableSpanSupported(span))) return false;
    };
    return has_cells;
}
fn inlineOwnerNibble(byte: u8) ?u8 {
    return switch (byte) { '0'...'9' => byte - '0', 'a'...'f' => byte - 'a' + 10, else => null };
}
const InlineOwnerKey = struct {
    hex: bool,
    fn decoded(self: @This(), key: []const u8, at: usize) ?u8 {
        if (!self.hex) return if (key[at] == '_') ' ' else key[at];
        const high = inlineOwnerNibble(key[at * 2]) orelse return null;
        const low = inlineOwnerNibble(key[at * 2 + 1]) orelse return null;
        return (high << 4) | low;
    }
    pub fn hash(self: @This(), key: []const u8) u64 {
        var hash_value = std.hash.Wyhash.init(0);
        const len = if (self.hex) key.len / 2 else key.len;
        for (0..len) |at| {
            const byte = self.decoded(key, at) orelse return 0;
            hash_value.update(&.{byte});
        }
        return hash_value.final();
    }
    pub fn eql(self: @This(), key: []const u8, file: []const u8) bool {
        const len = if (self.hex) key.len / 2 else key.len;
        if (len != file.len) return false;
        for (file, 0..) |byte, at| if ((self.decoded(key, at) orelse return false) != byte) return false;
        return true;
    }
};
/// Resolve only existing catalog names. The adapted lookup avoids allocating a
/// decoded filename for each span, and retains strict duplicate-owner refusal.
const InlineTableMediaOwner = struct { key: []const u8, adaptation: InlineOwnerKey };
fn inlineTableMediaOwner(span: anytype) ?InlineTableMediaOwner {
    if (!inlineTableEmbeddedMedia(span)) return null;
    const prefix = "wikidict-media-file-";
    var owner: ?[]const u8 = null;
    var tokens = std.mem.tokenizeAny(u8, span.classes, " \t\r\n\x0b\x0c");
    while (tokens.next()) |token| if (std.mem.startsWith(u8, token, prefix)) {
        if (owner != null) return null;
        owner = token[prefix.len..];
    };
    if (owner) |key| {
        if (key.len == 0 or key.len % 2 != 0) return null;
        for (key) |byte| if (inlineOwnerNibble(byte) == null) return null;
        return .{ .key = key, .adaptation = .{ .hex = true } };
    }
    if (!std.mem.startsWith(u8, span.target, "File:")) return null;
    return .{ .key = span.target[5..], .adaptation = .{ .hex = false } };
}
pub fn inlineTableMediaOwnerMatches(span: anytype, file: []const u8) bool {
    const owner = inlineTableMediaOwner(span) orelse return false;
    return owner.adaptation.eql(owner.key, file);
}
pub fn inlineTableMediaValue(index: anytype, span: anytype) @TypeOf(index.get(@as([]const u8, ""))) {
    const owner = inlineTableMediaOwner(span) orelse return null;
    return index.getAdapted(owner.key, owner.adaptation);
}
/// New image shape and external top alignment require DPRM even without a Container.
pub fn inlineTableRequiresM(table: anytype) bool {
    if (comptime !@hasField(@TypeOf(table), "style")) return false;
    if (table.style) |style| if (style.vertical_align) |alignment| if (alignment == .top) return true;
    if (!tableStyleIsInline(table.style)) return false;
    for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| if (span.image != null) return true;
    return false;
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
        const Collection = switch (@typeInfo(@TypeOf(media))) {
            .pointer => |pointer| if (pointer.size == .one) pointer.child else @TypeOf(media),
            else => @TypeOf(media),
        };
        const is_tuple = switch (@typeInfo(Collection)) {
            .@"struct" => |info| info.is_tuple,
            else => false,
        };
        if (comptime is_tuple) {
            inline for (media) |item| result.insertMedia(item);
        } else {
            for (media) |item| result.insertMedia(item);
        }
        return result;
    }
    fn insertMedia(self: *ImageCatalogIndex, item: anytype) void {
        const slot = self.values.getOrPutAssumeCapacity(item.file);
        if (slot.found_existing) slot.value_ptr.duplicate = true
        else slot.value_ptr.* = .{ .image = item.kind == .image };
    }
    pub fn deinit(self: *ImageCatalogIndex, a: std.mem.Allocator) void {
        self.values.deinit(a);
        self.* = .{};
    }
    pub fn supportsInlineTableAudio(self: *const ImageCatalogIndex, span: anytype) bool {
        if (!inlineTableEmbeddedMedia(span)) return true;
        const value = inlineTableMediaValue(self.values, span) orelse return false;
        return !value.image and !value.duplicate;
    }
    pub fn supportsInlineTableMedia(self: *const ImageCatalogIndex, span: anytype) bool {
        if (span.image) |image| {
            if (!inlineTableSpanSupportedM(span)) return false;
            const value = self.values.get(image.file) orelse return false;
            if (!value.image or value.duplicate) return false;
            return !inlineTableEmbeddedMedia(span) or inlineTableMediaOwnerMatches(span, image.file);
        }
        return self.supportsInlineTableAudio(span);
    }
    pub fn validate(self: *const ImageCatalogIndex, file: []const u8) error{InvalidPresentation}!void {
        const value = self.values.get(file) orelse return error.InvalidPresentation;
        if (!value.image or value.duplicate) return error.InvalidPresentation;
    }
};

/// Work bound for the newly supported deep-Table domain. These are the same
/// collection and Figure/Ruby-owner charges used by the nested wire encoder.
/// Codec runs this before wider capability walks; validation shares one budget
/// across first-depth17 subtrees. Historical shallow validation is unchanged.
pub const DeepTableWork = struct {
    remaining: usize = max_presentation_items,
    inline_group_found: bool = false,
    inline_action_group_found: bool = false,
    inline_group_font_family: bool = false,
    inline_group_text_flow: bool = false,
    discover_inline_group: bool = false,
    discover_inline_action_group: bool = false,
    const Error = error{ InvalidPresentation, PresentationTooLarge };
    fn take(self: *DeepTableWork, count: usize) Error!void {
        if (count > self.remaining) return error.PresentationTooLarge;
        self.remaining -= count;
    }
    fn inlineFeatures(self: *DeepTableWork, value: anytype) void {
        if (comptime @hasField(@TypeOf(value), "font_family"))
            if (value.font_family != null) { self.inline_group_font_family = true; };
        if (comptime @hasField(@TypeOf(value), "inline_style")) if (value.inline_style) |style| {
            if (style.wrap != null) self.inline_group_text_flow = true;
            if (style.line_height) |height| if (height == .font_relative and height.font_relative.font.font_family != null) {
                self.inline_group_font_family = true;
            };
        };
    }
    fn spans(self: *DeepTableWork, values: anytype, content_depth: usize, ruby_depth: usize) Error!void {
        if (content_depth > max_content_depth or ruby_depth > max_ruby_depth) return error.InvalidPresentation;
        try self.take(values.len);
        for (values) |value| {
            self.inlineFeatures(value);
            if (comptime @hasField(@TypeOf(value), "inline_action_group")) if (value.inline_action_group) |group| {
                self.inline_action_group_found = true;
                if (self.discover_inline_action_group) return error.InvalidPresentation;
                if (content_depth >= max_content_depth) return error.InvalidPresentation;
                try self.spans(group.spans, content_depth + 1, ruby_depth);
            };
            if (comptime @hasField(@TypeOf(value), "inline_padding_group")) if (value.inline_padding_group) |group| {
                self.inline_group_found = true;
                // Private discovery stops here. Its caller consumes the marker,
                // never this sentinel; ordinary preflight still checks all work.
                if (self.discover_inline_group) return error.InvalidPresentation;
                if (content_depth >= max_content_depth) return error.InvalidPresentation;
                try self.spans(group.spans, content_depth + 1, ruby_depth);
            };
            if (comptime @hasField(@TypeOf(value), "ruby")) if (value.ruby) |ruby| {
                if (content_depth >= max_content_depth or ruby_depth >= max_ruby_depth) return error.InvalidPresentation;
                try self.take(ruby.segments.len);
                for (ruby.segments) |segment| {
                    try self.spans(segment.gap_before, content_depth + 1, ruby_depth + 1);
                    try self.take(segment.bases.len);
                    for (segment.bases) |base| {
                        try self.take(1);
                        self.inlineFeatures(base.owner.font);
                        self.inlineFeatures(base.owner);
                        try self.spans(base.gap_before, content_depth + 1, ruby_depth + 1);
                        try self.spans(base.spans, content_depth + 1, ruby_depth + 1);
                    }
                    try self.take(segment.annotations.len);
                    for (segment.annotations) |annotation| {
                        try self.take(1);
                        self.inlineFeatures(annotation.owner.font);
                        self.inlineFeatures(annotation.owner);
                        inline for (.{ "gap_before", "spans", "fallback_before", "fallback_after" }) |field|
                            try self.spans(@field(annotation, field), content_depth + 1, ruby_depth + 1);
                    }
                }
            };
        }
    }
    /// Discovery never changes historical group-free validation/count semantics.
    /// A group beyond this budget cannot form a valid U entry; the legacy encoder
    /// still refuses that unsupported field if it reaches it later.
    pub fn hasInlineActionGroups(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
        var work: DeepTableWork = .{ .discover_inline_action_group = true };
        work.entry(display, sections, preamble, references) catch {};
        return work.inline_action_group_found;
    }
    pub fn hasInlinePaddingGroups(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
        var work: DeepTableWork = .{ .discover_inline_group = true };
        work.entry(display, sections, preamble, references) catch {};
        return work.inline_group_found;
    }
    fn figure(self: *DeepTableWork, value: anytype, table_depth: usize, content_depth: usize) Error!void {
        // Encoder.chargeFigureContent charges the subject Span exactly once.
        const subject = [_]@TypeOf(value.content.span()){value.content.span()};
        try self.spans(&subject, content_depth, 0);
        if (comptime @hasField(@TypeOf(value), "caption")) try self.spans(value.caption, content_depth, 0);
        if (comptime @hasField(@TypeOf(value), "caption_blocks")) if (value.caption_blocks) |children|
            try self.blocks(children, table_depth, content_depth + 1);
    }
    fn parts(self: *DeepTableWork, values: anytype, table_depth: usize, content_depth: usize) Error!void {
        if (content_depth > max_content_depth) return error.InvalidPresentation;
        try self.take(values.len);
        for (values) |value| {
            try self.spans(value.spans, content_depth, 0);
            if (value.figure) |child| try self.figure(child, table_depth, content_depth);
            if (comptime @hasField(@TypeOf(value), "scope")) if (value.scope) |scope|
                try self.parts(scope.parts, table_depth, content_depth + 1);
        }
    }
    fn blocks(self: *DeepTableWork, values: anytype, table_depth: usize, content_depth: usize) Error!void {
        if (content_depth > max_content_depth) return error.InvalidPresentation;
        try self.take(values.len);
        for (values) |value| {
            try self.spans(value.spans, content_depth, 0);
            if (comptime @hasField(@TypeOf(value), "container")) if (value.container) |box|
                try self.blocks(box.blocks, table_depth, content_depth + 1);
            if (comptime @hasField(@TypeOf(value), "flow")) if (value.flow) |flow|
                try self.parts(flow, table_depth, content_depth + 1);
            if (comptime @hasField(@TypeOf(value), "figure")) if (value.figure) |child|
                try self.figure(child, table_depth, content_depth);
            if (value.table) |child| try self.table(child, table_depth + 1, content_depth);
        }
    }
    pub fn table(self: *DeepTableWork, value: anytype, table_depth: usize, content_depth: usize) Error!void {
        if (table_depth > max_table_depth or content_depth > max_content_depth) return error.InvalidPresentation;
        if (comptime @hasField(@TypeOf(value), "caption")) try self.spans(value.caption, content_depth, 0);
        if (comptime @hasField(@TypeOf(value), "caption_blocks")) if (value.caption_blocks) |children|
            try self.blocks(children, table_depth, content_depth + 1);
        try self.take(value.rows.len);
        for (value.rows) |row| {
            try self.take(row.cells.len);
            for (row.cells) |cell| {
                try self.spans(cell.spans, content_depth, 0);
                if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks) |children|
                    try self.blocks(children, table_depth, content_depth);
                if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child|
                    try self.table(child, table_depth + 1, content_depth);
            }
        }
    }
    pub fn entry(self: *DeepTableWork, display: anytype, sections: anytype, preamble: anytype, references: anytype) Error!void {
        try self.spans(display, 0, 0);
        try self.take(sections.len);
        for (sections) |section| try self.blocks(section.blocks, 0, 0);
        try self.spans(preamble, 0, 0);
        try self.take(references.len);
        for (references) |reference| {
            try self.spans(reference.spans, 0, 0);
            if (comptime @hasField(@TypeOf(reference), "blocks")) if (reference.blocks) |children|
                try self.blocks(children, 0, 0);
        }
    }
};

const ImageValidation = struct {
    a: std.mem.Allocator,
    media: []const Media,
    index: ?ImageCatalogIndex = null,
    maps: MapValidationBudget = .{},
    deep_table_items: usize = max_presentation_items,
    content_depth: usize = 0,
    ruby_depth: usize = 0,
    in_reference: bool = false,
    inline_padding_action: ?InlinePaddingGroupAction = null,
    in_inline_padding_group: bool = false,
    in_inline_action_group: bool = false,
    link_paint: ?FigureLinkPaint = null,

    fn deinit(self: *ImageValidation) void {
        if (self.index) |*index| index.deinit(self.a);
    }
    fn validateInlineTableMedia(self: *ImageValidation, table: Table) ValidationError!void {
        for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
            if (span.image == null and !inlineTableEmbeddedMedia(span)) continue;
            if (self.index == null) self.index = try ImageCatalogIndex.init(self.a, self.media);
            if (!self.index.?.supportsInlineTableMedia(span)) return error.InvalidPresentation;
        };
    }
    fn validate(self: *ImageValidation, image: InlineImage) ValidationError!void {
        if (image.map) |map| if (!self.maps.map(map)) return error.InvalidPresentation;
        // Media-only records retain their historical admission and allocate no index.
        if (self.index == null) self.index = try ImageCatalogIndex.init(self.a, self.media);
        const index: *const ImageCatalogIndex = &self.index.?;
        try index.validate(image.file);
    }
};
fn validateRubySpans(spans: []const Span, gap: bool, media: *ImageValidation) ValidationError!void {
    if (!media.maps.items(spans.len)) return error.InvalidPresentation;
    for (spans) |span| if (!(if (gap) validRubyChild(span) else validRubyBodyChild(span))) return error.InvalidPresentation;
    try validateSpanColors(spans, media);
}
fn validateRubyContent(value: Ruby(Span), media: *ImageValidation) ValidationError!void {
    if (!validRuby(value) or media.content_depth >= max_content_depth or media.ruby_depth >= max_ruby_depth or
        !media.maps.items(value.segments.len)) return error.InvalidPresentation;
    media.content_depth += 1; defer media.content_depth -= 1;
    media.ruby_depth += 1; defer media.ruby_depth -= 1;
    for (value.segments) |segment| {
        try validateRubySpans(segment.gap_before, true, media);
        if (!media.maps.items(segment.bases.len)) return error.InvalidPresentation;
        for (segment.bases) |base| {
            if (media.inline_padding_action) |action| try action.checkRubyOwner(base.owner);
            if (!media.maps.items(1)) return error.InvalidPresentation;
            try validateRubySpans(base.gap_before, true, media);
            try validateRubySpans(base.spans, false, media);
        }
        if (!media.maps.items(segment.annotations.len)) return error.InvalidPresentation;
        for (segment.annotations) |annotation| {
            if (media.inline_padding_action) |action| try action.checkRubyOwner(annotation.owner);
            if (!media.maps.items(1)) return error.InvalidPresentation;
            inline for (.{ "gap_before", "spans", "fallback_before", "fallback_after" }) |field|
                try validateRubySpans(@field(annotation, field), comptime std.mem.eql(u8, field, "gap_before"), media);
        }
    }
}

fn validateSpanColors(spans: []const Span, media: *ImageValidation) ValidationError!void {
    for (spans) |span| {
        if ((media.in_inline_padding_group or media.in_inline_action_group) and !validRubyBodyChild(span)) return error.InvalidPresentation;
        if (media.in_inline_action_group) if (media.inline_padding_action) |action| try action.check(span);
        if (media.inline_padding_action != null and (span.kind != .text or span.target.len != 0)) return error.InvalidPresentation;
        if (span.inline_action_group) |group| {
            if (!validInlineActionGroupOwner(span) or media.content_depth >= max_content_depth or
                (!media.in_inline_padding_group and !media.in_inline_action_group and media.ruby_depth == 0 and !media.maps.items(1)) or
                !media.maps.items(group.spans.len)) return error.InvalidPresentation;
            const previous_action = media.inline_padding_action;
            const previous_group = media.in_inline_action_group;
            media.inline_padding_action = InlinePaddingGroupAction.from(span) orelse return error.InvalidPresentation;
            media.in_inline_action_group = true;
            media.content_depth += 1;
            defer media.content_depth -= 1;
            defer media.in_inline_action_group = previous_group;
            defer media.inline_padding_action = previous_action;
            try validateSpanColors(group.spans, media);
        } else if (span.inline_padding_group) |group| {
            if (!validInlinePaddingGroupOwner(span) or media.content_depth >= max_content_depth or
                (!media.in_inline_padding_group and !media.in_inline_action_group and media.ruby_depth == 0 and !media.maps.items(1)) or
                !media.maps.items(group.spans.len)) return error.InvalidPresentation;
            const previous_action = media.inline_padding_action;
            const previous_group = media.in_inline_padding_group;
            media.inline_padding_action = InlinePaddingGroupAction.from(span) orelse previous_action;
            media.in_inline_padding_group = true;
            media.content_depth += 1;
            defer media.content_depth -= 1;
            defer media.in_inline_padding_group = previous_group;
            defer media.inline_padding_action = previous_action;
            try validateSpanColors(group.spans, media);
        } else if (span.ruby == null) if (media.inline_padding_action) |action| {
            _ = try action.project(span);
        };
        if (span.ruby) |ruby| {
            if (!validRubyOwner(span) or (media.ruby_depth == 0 and !media.in_inline_action_group and !media.maps.items(1))) return error.InvalidPresentation;
            try validateRubyContent(ruby.*, media);
        }
        if (span.font_family) |family| if (!validContainerFontFamily(family)) return error.InvalidPresentation;
        if (media.link_paint) |paint| if (!validFigureLinkPaintSpan(paint, span)) return error.InvalidPresentation;
        if (span.tooltip) |advice| if (!std.unicode.utf8ValidateSlice(advice)) return error.InvalidPresentation;
        if (span.target_fragment) |fragment| if (span.kind != .link or !validTargetFragment(fragment)) return error.InvalidPresentation;
        if (span.image) |image| {
            if (span.text.len != 0 or span.trail.len != 0 or !validInlineImage(image) or
                !validInlineImageAction(span.kind, span.target)) return error.InvalidPresentation;
            try media.validate(image);
        }
        if (!validSpanInlineStyle(span) or !validSpanLinkPaint(span) or !validSpanFontScale(span.font_scale, span.font_scale_basis)) return error.InvalidPresentation;
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
pub fn validBorderEdge(value: StyleBorderEdge) bool {
    return switch (value) {
        .none, .hidden => true,
        .solid, .dotted => |line| validStyleLength(line.width) and isCanonicalRgb(line.color),
    };
}
pub fn validBorderEdges(value: StyleBorderEdges) bool {
    return validBorderEdge(value.top) and validBorderEdge(value.right) and validBorderEdge(value.bottom) and validBorderEdge(value.left);
}
pub fn validBorder(value: StyleBorder) bool {
    return switch (value) {
        .none => true,
        .solid => |solid| validStyleLength(solid.width) and isCanonicalRgb(solid.color),
        .edges => |edges| validBorderEdges(edges),
    };
}
pub fn tableStyleIsInline(style: ?TableStyle) bool {
    return if (style) |value| if (value.display) |display| display != .table else false else false;
}
pub fn validInlineTableContent(style: ?TableStyle, caption_len: usize, has_caption_blocks: bool, has_cells: bool) bool {
    return !tableStyleIsInline(style) or (caption_len == 0 and !has_caption_blocks and has_cells);
}
pub fn validComputedLineHeight(value: ComputedLineHeight) bool {
    return value.font_scale_basis != .css_px and std.math.isFinite(value.value) and value.value > 0;
}
pub fn validTableMarginValues(value: ContainerMargins) bool {
    inline for (.{ "top", "bottom" }) |name| {
        const edge = @field(value, name);
        if (edge != .length or !validStyleLength(edge.length)) return false;
    }
    inline for (.{ "right", "left" }) |name| switch (@field(value, name)) {
        .auto => {},
        .length => |length| if (!validStyleLength(length)) return false,
    };
    return value.left == .auto or value.right == .auto;
}
pub fn validTableCornerRadii(value: TableCornerRadii) bool {
    inline for (.{ "top_left", "top_right", "bottom_right", "bottom_left" }) |name| {
        const corner = @field(value, name);
        if (corner.unit != .px or !validStyleLength(corner) or corner.value > 16_777_216) return false;
    }
    return true;
}
pub fn validTableStyle(value: TableStyle) bool {
    // Q corner numeric margins need the true containing-block direction when
    // their percent content box plus physical edges is overconstrained.
    if (value.margin_values == null and value.containing_direction != null) {
        if (value.corner_radii == null or value.margins == null) return false;
    } else if ((value.margin_values != null) != (value.containing_direction != null)) return false;
    return validUnboundTableStyle(value);
}
/// Build-only parsed declaration components, before actual parent direction is
/// bound. This predicate never grants Stored/codec/native table admission.
pub fn validUnboundTableStyle(value: TableStyle) bool {
    if (value.vertical_align) |alignment| if (alignment == .top and !tableStyleIsInline(value)) return false;
    if (value.background == null and value.border == null and value.collapse == null and value.margins == null and value.margin_values == null and value.float_side == null and value.width == null and value.padding == null and value.clear == null and value.display == null and value.vertical_align == null and value.line_height == null and value.corner_radii == null) return false;
    if (value.background) |color| if (!isCanonicalRgb(color)) return false;
    if (value.border) |border| if (!validBorder(border)) return false;
    if (value.margins) |margins| if (!validStyleEdges(margins)) return false;
    if (value.margin_values) |margins| if (value.margins != null or !validTableMarginValues(margins)) return false;
    if (value.width) |width| if (!validStyleWidth(width)) return false;
    if (value.padding) |padding| if (!validStyleEdges(padding)) return false;
    if (value.line_height) |height| if (!validComputedLineHeight(height)) return false;
    if (value.display) |display| if (display != .table and value.float_side != null) return false;
    if (value.corner_radii) |corners| {
        if (!validTableCornerRadii(corners) or tableStyleIsInline(value) or value.collapse == .collapse) return false;
        const border = value.border orelse return false;
        switch (border) { .none, .solid => {}, .edges => return false }
    }
    return true;
}
pub fn validTableBlockViewport(value: TableBlockViewport) bool {
    return validTableBlockViewportIn(value, false);
}
/// In the explicitly paired responsive policy only, absent box width means
/// fit-content and fixed margins belong to the source block scroll owner.
pub fn validTableScrollViewport(value: TableBlockViewport) bool {
    return validTableBlockViewportIn(value, true);
}
fn validTableBlockViewportIn(value: TableBlockViewport, paired: bool) bool {
    if (value.intrinsic_containing_direction != null) return false;
    if (value.grid_style.corner_radii != null) return false;
    if (paired) {
        if (!validTableScrollFocusPaint(value.focus_paint orelse return false)) return false;
    } else if (value.focus_paint != null) return false;
    if (value.language.len == 0 or value.language.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(value.language)) return false;
    const box = value.box_style;
    if (!validTableStyle(box) or (if (paired)
        box.width != null or box.margins == null or box.margin_values != null or box.containing_direction != null
        else box.width == null or box.width.?.value <= 0 or box.margin_values == null or box.margins != null) or
        box.float_side != null or box.display != null or box.vertical_align != null or
        box.collapse != null or box.line_height != null or !validStyleWidth(value.max_width)) return false;
    const grid = value.grid_style;
    // Separate borders need a represented spacing carrier. The source block's
    // border/background/padding never become anonymous-grid defaults.
    return validTableStyle(grid) and grid.collapse == .collapse and grid.background == null and grid.border == null and
        grid.padding == null and grid.width == null and grid.margins == null and grid.margin_values == null and
        grid.containing_direction == null and grid.float_side == null and grid.clear == null and grid.display == null and grid.vertical_align == null;
}
/// Q-only source-owned separate responsive grid. Legacy block and P32
/// predicates above remain unchanged; a required corner field selects Q.
pub fn validTableCornerBlockViewport(value: TableBlockViewport) bool {
    return tableCornerBlockViewportShape(value) and validTableScrollFocusPaint(value.focus_paint orelse return false);
}
/// Build-only local wire-shape discriminator, before required Q focus is read.
/// The complete policy and enclosing Table geometry still require validation.
pub fn tableCornerBlockViewportShape(value: TableBlockViewport) bool {
    if (value.intrinsic_containing_direction != null) return false;
    if (value.language.len == 0 or value.language.len > 32 * 1024 * 1024 or
        !std.unicode.utf8ValidateSlice(value.language)) return false;
    const box = value.box_style;
    if (!validTableStyle(box) or box.corner_radii == null or box.width == null or
        box.width.?.unit != .percent or box.width.?.value != 100 or
        value.max_width.unit != .percent or value.max_width.value != 100 or
        box.margins == null or box.margin_values != null or box.containing_direction == null or
        box.float_side != null or box.display != null or box.vertical_align != null or
        box.collapse != null or box.line_height != null) return false;
    const grid = value.grid_style;
    return validTableStyle(grid) and grid.collapse == .separate and grid.corner_radii == null and
        grid.background == null and grid.border == null and grid.padding == null and grid.width == null and
        grid.margins == null and grid.margin_values == null and grid.containing_direction == null and
        grid.float_side == null and grid.clear == null and grid.display == null and
        grid.vertical_align == null and grid.line_height == null;
}
fn validTableCornerGridGeometry(geometry: ?TableGeometry) bool {
    const value = geometry orelse return false;
    return validTableGeometry(value) and value.border == null and value.width == null and
        value.cell_spacing != null and value.cell_padding != null;
}
/// R-only nonfloating automatic-wide / intrinsic-block-narrow source owner.
/// The direction belongs to both source allocations, not the anonymous grid.
pub fn validTableIntrinsicViewport(value: TableBlockViewport) bool {
    if (value.intrinsic_containing_direction == null or value.max_viewport_width_px == 0 or
        value.max_width.unit != .percent or value.max_width.value != 100 or
        !validTableScrollFocusPaint(value.focus_paint orelse return false)) return false;
    // Reuse the exact paired fit-content box/grid shape, but never its float.
    var shape = value;
    shape.intrinsic_containing_direction = null;
    return validTableScrollViewport(shape) and shape.box_style.corner_radii == null and
        shape.grid_style.line_height == null;
}
fn validTableIntrinsicViewportHeader(geometry: ?TableGeometry, style: ?TableStyle, value: TableBlockViewport) bool {
    if (!validTableIntrinsicViewport(value)) return false;
    const hints = geometry orelse return false;
    if (!validTableGeometry(hints) or hints.width != null or hints.border == null or
        hints.cell_spacing == null or hints.cell_padding == null) return false;
    const wide = style orelse return false;
    return validTableStyle(wide) and wide.width == null and wide.float_side == null and
        wide.display == null and wide.vertical_align == null and wide.line_height == null and
        wide.collapse == .collapse and wide.corner_radii == null and wide.margins != null and
        wide.margin_values == null and wide.containing_direction == null;
}

pub fn validTableBlockViewportHeader(geometry: ?TableGeometry, style: ?TableStyle, viewport: ?*const TableBlockViewport) bool {
    const value = viewport orelse return true;
    if (value.intrinsic_containing_direction != null)
        return validTableIntrinsicViewportHeader(geometry, style, value.*);
    if (validTableCornerBlockViewport(value.*)) {
        if (!validTableCornerGridGeometry(geometry) or tableStyleIsInline(style)) return false;
        if (style) |wide| if (!validTableStyle(wide) or wide.float_side != null or
            wide.collapse != .separate or wide.corner_radii == null or wide.width == null or
            wide.width.?.unit != .percent or wide.width.?.value != 100 or wide.margins == null or
            wide.margin_values != null or wide.containing_direction == null) return false;
        return style != null;
    }
    if (geometry != null or tableStyleIsInline(style)) return false;
    if (style) |wide| if (!validTableStyle(wide) or wide.float_side != null) return false;
    return validTableBlockViewport(value.*);
}
/// Both records describe mutually exclusive states of one source Table owner.
/// The narrow owner is a fit-content auto-scroll block; the wide owner floats.
pub fn validTableViewportHeaders(geometry: ?TableGeometry, style: ?TableStyle,
    block: ?*const TableBlockViewport, floating: ?TableFloatViewport) bool
{
    if (style) |base| if (base.corner_radii != null and base.collapse != .separate) return false;
    if (block) |narrow| if (floating) |wide| {
        return validTableFloatViewportHeader(geometry, style, wide) and
            validTableScrollViewport(narrow.*) and wide.narrow_clear == null and
            wide.max_viewport_width_px == narrow.max_viewport_width_px and
            wide.grid_direction == narrow.grid_direction and std.mem.eql(u8, wide.language, narrow.language);
    };
    return validTableBlockViewportHeader(geometry, style, block) and
        validTableFloatViewportHeader(geometry, style, floating);
}
/// Viewport is the document CSS viewport, never a cell's available width.
pub fn resolveTableBlockViewport(table: Table, viewport_css_px: f32) error{InvalidPresentation}!?*const TableBlockViewport {
    if (!validTableViewportHeaders(table.geometry, table.style, table.block_viewport, table.float_viewport) or
        !std.math.isFinite(viewport_css_px) or viewport_css_px < 0) return error.InvalidPresentation;
    const selected = table.block_viewport orelse return null;
    return if (@as(f64, viewport_css_px) <= @as(f64, @floatFromInt(selected.max_viewport_width_px))) selected else null;
}
pub fn validCellTextMetric(value: ComputedLineHeight) bool {
    return std.math.isFinite(value.value) and value.value >= 0 and
        (value.font_scale_basis == .normal_body or value.font_scale_basis == .css_px);
}
pub fn validCellTextStrut(value: CellTextStrut) bool {
    if (!validCellTextMetric(.{ .value = value.font_scale, .font_scale_basis = value.font_scale_basis })) return false;
    if (value.owner_font) |font| {
        if (!validInlineFontSnapshot(font) or font.font_scale == null or font.font_scale.? != value.font_scale or
            font.font_scale_basis != value.font_scale_basis or font.font_family == null or font.font_features == null or
            font.language.len == 0 or font.language.len > 1024 or font.small or font.superscript or font.subscript or
            font.font_normalized or font.code or font.classes.len != 0 or font.role != .normal) return false;
    }
    return true;
}
pub fn validCellLineHeight(value: CellLineHeight) bool {
    if (value.strut) |strut| if (!validCellTextStrut(strut)) return false;
    return switch (value.height) {
        .normal => true,
        .multiplier => |factor| std.math.isFinite(factor) and factor >= 0,
        .length => |length| validCellTextMetric(length),
    };
}

pub fn validCellStyle(value: CellStyle) bool {
    if (value.width) |width| if (!validStyleWidth(width)) return false;
    if (value.min_width) |width| if (!validStyleLength(width)) return false;
    if (value.border == null and value.padding == null and value.text_align == null and value.min_width == null and value.vertical_align == null and value.width == null and value.line_height == null) return false;
    if (value.border) |border| if (!validBorder(border)) return false;
    if (value.padding) |padding| if (!validStyleEdges(padding)) return false;
    if (value.line_height) |height| if (!validCellLineHeight(height)) return false;
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
pub fn validFigureBorderEdge(value: FigureBorderEdge) bool {
    return switch (value) {
        .none, .hidden => true,
        .solid, .dotted => |line| validStyleLength(line.width) and validFigureColor(line.color),
    };
}
pub fn validFigureViewportWrapper(value: ContainerStyle) bool {
    if (!validContainerStyle(value)) return false;
    const allowed: ContainerStyle = .{ .margins = value.margins, .margin_values = value.margin_values,
        .float_side = value.float_side, .clear = value.clear };
    if (!std.meta.eql(value, allowed)) return false;
    if (value.margins) |edges| if (!validStyleEdges(edges)) return false;
    if (value.margin_values) |edges| inline for (.{ "top", "right", "bottom", "left" }) |side| {
        switch (@field(edges, side)) {
            .auto => if (comptime std.mem.eql(u8, side, "top") or std.mem.eql(u8, side, "bottom")) return false,
            .length => |length_value| if (!validStyleLength(length_value)) return false,
        }
    };
    return true;
}
pub fn validFigureCaptionBefore(value: ContainerStyle) bool {
    if (!validContainerStyle(value) or value.width == null or value.height == null or value.float_side == null) return false;
    const width = value.width.?;
    if (width != .length or width.length.unit == .percent) return false;
    const allowed: ContainerStyle = .{ .width = value.width, .height = value.height, .float_side = value.float_side,
        .margins = value.margins, .layout = value.layout, .box_sizing = value.box_sizing,
        .background = value.background, .border = value.border };
    if (!std.meta.eql(value, allowed)) return false;
    if (value.margins) |edges| if (!validStyleEdges(edges)) return false;
    if (value.layout) |layout| if (layout != .flow) return false;
    if (value.box_sizing) |sizing| if (sizing != .content_box) return false;
    if (value.background) |background| if (background != .transparent) return false;
    if (value.border) |border| if (border != .none) return false;
    return true;
}
pub fn validFigureFocusOutline(value: FigureFocusOutline) bool {
    return validStyleLength(value.width) and validFigureColor(value.color) and
        validStyleLength(value.radius) and validContainerMarginLength(value.offset);
}
pub fn validFigureLinkPaint(value: FigureLinkPaint) bool {
    inline for (.{ "normal", "hover", "active", "visited", "visited_hover", "visited_active" }) |name|
        if (!isCanonicalRgb(@field(value, name).foreground)) return false;
    if (value.focus_outline) |outline| if (!validFigureFocusOutline(outline) or outline.color.kind != .rgb) return false;
    return true;
}
/// Header validity is separate; this preserves static paint agreement while the
/// existing bounded traversal visits real text-link owners exactly once.
pub fn validFigureLinkPaintSpan(paint: FigureLinkPaint, span: anytype) bool {
    if (comptime @hasField(@TypeOf(span), "link_paint")) if (span.link_paint != null) return false;
    const name = @tagName(span.kind);
    if (!std.mem.eql(u8, name, "link") and !std.mem.eql(u8, name, "external_link")) return true;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image != null) return true;
    if (comptime @hasField(@TypeOf(span), "foreground")) if (span.foreground) |color|
        if (!std.mem.eql(u8, color, paint.normal.foreground)) return false;
    return true;
}
pub fn validSpanLinkPaint(span: anytype) bool {
    const paint: LinkPaint = if (comptime @hasField(@TypeOf(span), "link_paint")) span.link_paint orelse return true else return true;
    const kind = @tagName(span.kind);
    if ((!std.mem.eql(u8, kind, "link") and !std.mem.eql(u8, kind, "external_link")) or span.target.len == 0 or !validLinkPaint(paint)) return false;
    if (comptime @hasField(@TypeOf(span), "image")) if (span.image) |image| {
        // Image-owned policy is an action focus policy. Its sampled glyph
        // ink stays data; readers never tint or underline the replaced bitmap.
        const trail: []const u8 = if (comptime @hasField(@TypeOf(span), "trail")) span.trail else "";
        if (span.text.len != 0 or trail.len != 0 or !validInlineImage(image) or
            image.map != null or image.static_poster != null or
            (if (image.alt) |alt| alt.len != 0 else false)) return false;
    };
    if (comptime @hasField(@TypeOf(span), "foreground")) if (span.foreground) |ink| if (!std.mem.eql(u8, ink, paint.normal.foreground)) return false;
    const underline = if (comptime @hasField(@TypeOf(span), "flags")) span.flags.underline else span.underline;
    return underline == paint.normal.underline;
}
pub fn validFigureMediaLayout(value: FigureMediaLayout) bool {
    if (!std.math.isFinite(value.strut.font_scale) or value.strut.font_scale < 0 or
        value.strut.language.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(value.strut.language)) return false;
    if (value.vertical_align != .baseline and value.vertical_align != .middle) return false;
    if (value.max_width) |limit| if (limit.percent != 100 or !validStyleLength(limit.subtract)) return false;
    if (value.after) |after| {
        if (value.positioning == null or value.positioning.? != .relative_auto) return false;
        // This capability paints the retained natural-size asset, not arbitrary
        // background resizing/tiling or another absolute descendant shape.
        if (after.width.unit != .px or after.width.value != 15 or
            after.height.unit != .px or after.height.value != 11 or
            after.inset.unit != .px or after.inset.value != 6 or
            after.bottom.unit != .px or after.bottom.value != -11) return false;
    }
    if (value.focus_outline) |outline| if (!validFigureFocusOutline(outline)) return false;
    return true;
}
fn validFigureMediaContent(media: FigureMediaLayout, content: anytype) bool {
    if (!validFigureMediaLayout(media)) return false;
    return switch (content) {
        .missing => media.vertical_align == .baseline and media.max_width == null and
            media.positioning == null and media.after == null and media.focus_outline == null,
        .image => |image| blk: {
            if (media.vertical_align != .middle) break :blk false;
            const file = image.span.image orelse break :blk false;
            if (file.map != null) break :blk false;
            // A present image action policy includes authored no-outline.
            // The same action cannot also own a Figure media outline.
            if (media.focus_outline != null) {
                if (comptime @hasField(@TypeOf(image.span), "link_paint"))
                    if (image.span.link_paint != null) break :blk false;
            }
            if (media.after != null or media.focus_outline != null) {
                const kind = @tagName(image.span.kind);
                if ((!std.mem.eql(u8, kind, "link") and !std.mem.eql(u8, kind, "external_link")) or
                    image.span.target.len == 0) break :blk false;
            }
            break :blk true;
        },
    };
}
pub fn validTableCaptionLayout(value: TableCaptionLayout) bool {
    // Separate grids need their real border-spacing domain, not an implicit zero.
    if (value.collapse != .collapse or !validFigureViewportWrapper(value.wrapper)) return false;
    if (!validFigureMediaLayout(value.media)) return false;
    if (value.missing_link_paint) |paint| if (!validFigureLinkPaint(paint)) return false;
    if (value.caption_link_paint) |paint| if (!validFigureLinkPaint(paint)) return false;
    if (value.caption_before) |before| if (!validFigureCaptionBefore(before)) return false;
    if (value.viewport_states.len > max_figure_viewport_states) return false;
    var previous: ?u32 = null;
    for (value.viewport_states) |state| {
        if (previous) |bound| if (state.max_width_px >= bound) return false;
        previous = state.max_width_px;
        if (!validFigureViewportWrapper(state.wrapper) or !validFigureMediaLayout(state.media)) return false;
        if (state.caption_before) |before| if (!validFigureCaptionBefore(before)) return false;
    }
    inline for (.{ "top", "right", "bottom", "left" }) |side| {
        if (!validFigureBorderEdge(@field(value.table_border, side)) or
            !validFigureBorderEdge(@field(value.caption_border, side))) return false;
    }
    return true;
}
pub fn resolveFigureViewportState(value: TableCaptionLayout, viewport_css_px: f64) error{InvalidPresentation}!?FigureViewportState {
    if (!validTableCaptionLayout(value) or !std.math.isFinite(viewport_css_px) or viewport_css_px < 0) return error.InvalidPresentation;
    var selected: ?FigureViewportState = null;
    for (value.viewport_states) |state| {
        if (viewport_css_px > @as(f64, @floatFromInt(state.max_width_px))) break;
        selected = state;
    }
    return selected;
}
// BuildFigure mirrors these fields but keeps a compiler Span. Do not cast that
// span to Stored or discard its packed flags/provenance to validate geometry.
pub fn validFigureGeometry(value: anytype) bool {
    if (comptime @hasField(@TypeOf(value), "block_media_layout")) if (value.block_media_layout) |layout|
        if (!validFigureBlockMediaContent(value, layout)) return false;
    if (comptime @hasField(@TypeOf(value), "table_caption_layout")) if (value.table_caption_layout) |layout| {
        if (!validTableCaptionLayout(layout) or value.frame_border.kind != .none or
            !validFigureMediaContent(layout.media, value.content)) return false;
        for (layout.viewport_states) |state| if (!validFigureMediaContent(state.media, value.content)) return false;
        if (layout.missing_link_paint != null) {
            if (value.content != .missing or value.content.missing.link_paint != null) return false;
            const label = value.content.missing.label;
            const kind_name = @tagName(label.kind);
            if ((!std.mem.eql(u8, kind_name, "link") and !std.mem.eql(u8, kind_name, "external_link")) or
                label.target.len == 0) return false;
        }
    };
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
pub fn validMissingFigureContent(value: anytype) bool {
    const label = value.label;
    // Compiler Span kinds are a distinct enum with additional build-only tags.
    // Accept the semantic names explicitly; never assume ordinal equivalence.
    const kind_name = switch (@typeInfo(@TypeOf(label.kind))) {
        .@"enum", .enum_literal => @tagName(label.kind),
        else => return false,
    };
    const kind: InlineKind = if (std.mem.eql(u8, kind_name, "text")) .text
        else if (std.mem.eql(u8, kind_name, "link")) .link
        else if (std.mem.eql(u8, kind_name, "external_link")) .external_link
        else return false;
    if (comptime @hasField(@TypeOf(value), "link_paint")) if (value.link_paint != null) {
        if (kind != .link and kind != .external_link) return false;
        if (comptime @hasField(@TypeOf(label), "link_paint")) if (label.link_paint != null) return false;
        // A static foreground and this stateful policy have no implicit precedence.
        if (comptime @hasField(@TypeOf(label), "foreground")) if (label.foreground != null) return false;
    };
    const trail: []const u8 = if (comptime @hasField(@TypeOf(label), "trail")) label.trail else "";
    if (!validStyleLength(value.width) or value.width.value <= 0 or
        !validStyleLength(value.line_height) or value.line_height.value <= 0 or
        label.text.len == 0 or trail.len != 0 or
        !std.unicode.utf8ValidateSlice(label.text) or !validInlineImageAction(kind, label.target)) return false;
    if (comptime @hasField(@TypeOf(label), "image")) if (label.image != null) return false;
    if (comptime @hasField(@TypeOf(label), "classes")) if (inlineTableEmbeddedMedia(label)) return false;
    if (comptime @hasField(@TypeOf(label), "target_fragment")) if (label.target_fragment) |fragment|
        if (kind != .link or !validTargetFragment(fragment)) return false;
    if (comptime @hasField(@TypeOf(label), "tooltip")) if (label.tooltip) |tooltip|
        if (!std.unicode.utf8ValidateSlice(tooltip)) return false;
    const scale: ?f32 = if (comptime @hasField(@TypeOf(label), "font_scale")) label.font_scale else null;
    const basis: FontScaleBasis = if (comptime @hasField(@TypeOf(label), "font_scale_basis")) label.font_scale_basis else .context;
    if (!validSpanLinkPaint(label) or !validSpanFontScale(scale, basis)) return false;
    if (comptime @hasField(@TypeOf(label), "foreground")) if (label.foreground) |color| if (!isCanonicalRgb(color)) return false;
    if (comptime @hasField(@TypeOf(label), "background")) if (label.background) |color| if (!isCanonicalRgb(color)) return false;
    return true;
}
pub fn validFigure(value: Figure) bool {
    if (value.table_caption_layout != null and value.content == .image) {
        const image = value.content.image.span.image orelse return false;
        if (image.static_poster != null) return false;
    }
    if (value.frame_min_width) |minimum| if (!validFigureFrameMinWidth(minimum)) return false;
    if (!validFigureGeometry(value) or (value.caption_blocks != null and value.caption.len != 0)) return false;
    switch (value.content) {
        .missing => |missing| return validMissingFigureContent(missing),
        .image => |content| {
            const image_span = content.span;
            const image = image_span.image orelse return false;
            if (image.vertical_align != null) return false; // Block Figure media has a different alignment owner.
            if (image.static_poster != null and (value.format != .thumbnail or content.sizing != .requested_fit)) return false;
            if (!validFigureSizingContext(value.format, content.sizing, image.width_px, image.height_px)) return false;
            if (image_span.text.len != 0 or image_span.trail.len != 0 or !validInlineImage(image) or !validInlineImageAction(image_span.kind, image_span.target)) return false;
            if (image_span.target_fragment) |fragment| if (image_span.kind != .link or !validTargetFragment(fragment)) return false;
            if (image_span.tooltip) |tooltip| if (!std.unicode.utf8ValidateSlice(tooltip)) return false;
            if (!validSpanFontScale(image_span.font_scale, image_span.font_scale_basis)) return false;
            if (image_span.foreground) |color| if (!isCanonicalRgb(color)) return false;
            if (image_span.background) |color| if (!isCanonicalRgb(color)) return false;
            return true;
        },
    }
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

pub fn validTableFloatViewportHeader(geometry: ?TableGeometry, style: ?TableStyle, optional: ?TableFloatViewport) bool {
    const policy = optional orelse return true;
    if (geometry != null or policy.max_viewport_width_px == 0 or policy.language.len == 0 or
        policy.language.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(policy.language)) return false;
    const base = style orelse return false;
    return validTableStyle(base) and base.float_side == .right and base.margins != null and
        base.margin_values == null and base.containing_direction == null and
        (base.width == null or base.width.?.unit != .percent) and
        base.padding == null and base.display == null and base.vertical_align == null and base.line_height == null;
}
pub fn validTableFloatViewportContent(optional: ?TableFloatViewport, caption_count: usize, caption_blocks: bool, has_cells: bool) bool {
    return optional == null or (caption_count == 0 and !caption_blocks and has_cells);
}
pub fn resolveTableFloatStyle(table: Table, viewport_css_px: f32) error{InvalidPresentation}!?TableStyle {
    const policy = table.float_viewport orelse return table.style;
    var has_cells = false; for (table.rows) |row| if (row.cells.len != 0) { has_cells = true; break; };
    if (!validTableViewportHeaders(table.geometry, table.style, table.block_viewport, policy) or
        !validTableFloatViewportContent(policy, table.caption.len, table.caption_blocks != null, has_cells) or
        !std.math.isFinite(viewport_css_px) or viewport_css_px < 0) return error.InvalidPresentation;
    var selected = table.style.?;
    if (@as(f64, viewport_css_px) <= @as(f64, @floatFromInt(policy.max_viewport_width_px))) {
        if (table.block_viewport) |narrow| return narrow.box_style;
        selected.float_side = null;
        if (policy.narrow_clear) |clear| selected.clear = clear;
    }
    return selected;
}

fn validateTable(table: Table, depth: usize, media: *ImageValidation) ValidationError!void {
    if (!validTableViewportHeaders(table.geometry, table.style, table.block_viewport, table.float_viewport)) return error.InvalidPresentation;
    if (depth > max_table_depth) return error.InvalidPresentation;
    if (depth == legacy_table_depth + 1) {
        // This boundary charge represents the parent cell/block outside the
        // subtree. Descendants are checked once, with no reset for siblings.
        var work: DeepTableWork = .{ .remaining = media.deep_table_items };
        work.take(1) catch return error.InvalidPresentation;
        work.table(table, depth, media.content_depth) catch return error.InvalidPresentation;
        media.deep_table_items = work.remaining;
    }
    if (table.geometry) |geometry| if (!validTableGeometry(geometry)) return error.InvalidPresentation;
    if (table.style) |style| if (!validTableStyle(style)) return error.InvalidPresentation;
    var has_cells = false;
    for (table.rows) |row| if (row.cells.len != 0) { has_cells = true; break; };
    if (!validTableFloatViewportContent(table.float_viewport, table.caption.len, table.caption_blocks != null, has_cells)) return error.InvalidPresentation;
    if (!validInlineTableContent(table.style, table.caption.len, table.caption_blocks != null, has_cells)) return error.InvalidPresentation;
    if (tableStyleIsInline(table.style)) {
        if (depth != 1 or media.content_depth != 0 or media.in_reference) return error.InvalidPresentation;
        if (!inlineTableShapeSupportedM(table)) return error.InvalidPresentation;
        try media.validateInlineTableMedia(table);
    }
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
    const previous = media.link_paint;
    defer media.link_paint = previous;
    // Each Figure is its own paint boundary; an outer caption policy never
    // recolors a nested Figure's media or caption implicitly.
    media.link_paint = if (figure.table_caption_layout) |layout| layout.missing_link_paint else null;
    try validateSpanColors(&.{figure.content.span()}, media);
    media.link_paint = if (figure.table_caption_layout) |layout| layout.caption_link_paint else null;
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
pub fn validInlineTableOwner(kind: BlockKind, spans_len: usize, has_feature: bool) bool {
    return (kind == .table or kind == .list_item) and spans_len == 0 and !has_feature;
}
pub fn validContainerWidth(value: ContainerWidth) bool {
    return switch (value) { .auto, .fit_content => true, .length => |length| validStyleWidth(length) };
}
pub fn validContainerMaxWidth(value: ContainerMaxWidth) bool {
    return switch (value) { .none => true, .length => |length| validStyleWidth(length) };
}
pub fn validContainerColor(value: ContainerColor) bool {
    return switch (value) {
        .transparent => true,
        .rgb => |color| isCanonicalRgb(color),
        .light_dark => |colors| isCanonicalRgb(colors.light) and isCanonicalRgb(colors.dark),
    };
}
pub fn validContainerBorderEdge(value: ContainerBorderEdge) bool {
    return switch (value) {
        .none, .hidden => true,
        .solid, .dotted => |line| validStyleLength(line.width) and validContainerColor(line.color),
    };
}
pub fn validContainerBorderEdges(value: ContainerBorderEdges) bool {
    return validContainerBorderEdge(value.top) and validContainerBorderEdge(value.right) and validContainerBorderEdge(value.bottom) and validContainerBorderEdge(value.left);
}
pub fn validContainerBorder(value: ContainerBorder) bool {
    return switch (value) { .none => true, .solid => |border| validStyleLength(border.width) and validContainerColor(border.color), .edges => |edges| validContainerBorderEdges(edges) };
}
pub fn validContainerLineHeight(value: ContainerLineHeight) bool {
    return switch (value) { .normal => true, .multiplier => |factor| std.math.isFinite(factor) and factor >= 0, .length => |length| validStyleLength(length) };
}
// Only Container margin scalars are signed. Padding, border widths and every
// other StyleLength consumer retain their original nonnegative contract.
pub fn validContainerMarginLength(value: StyleLength) bool {
    return std.math.isFinite(value.value);
}
pub fn validContainerMarginEdges(value: StyleEdges) bool {
    return validContainerMarginLength(value.top) and validContainerMarginLength(value.right) and
        validContainerMarginLength(value.bottom) and validContainerMarginLength(value.left);
}
pub fn validContainerMargin(value: ContainerMargin) bool {
    return switch (value) { .auto => true, .length => |length| validContainerMarginLength(length) };
}
pub fn validContainerMargins(value: ContainerMargins) bool {
    return validContainerMargin(value.top) and validContainerMargin(value.right) and
        validContainerMargin(value.bottom) and validContainerMargin(value.left);
}
fn validContainerScreenFields(value: ContainerScreenMaxWidth) bool {
    if (value.width == null and value.max_width == null and value.box_sizing == null and value.line_height == null and
        value.float_side == null and value.margins == null and value.clear == null) return false;
    if (value.width) |width| if (!validContainerWidth(width)) return false;
    if (value.max_width) |width| if (!validContainerMaxWidth(width)) return false;
    if (value.line_height) |height| if (!validContainerLineHeight(height)) return false;
    if (value.margins) |margins| if (!validContainerMargins(margins)) return false;
    return true;
}
pub fn validContainerScreenMaxWidth(value: ContainerScreenMaxWidth) bool {
    if (!validContainerScreenFields(value) or value.following_rules.len >= max_container_screen_rules) return false;
    var previous = value.max_width_px;
    for (value.following_rules) |rule| {
        if (rule.following_rules.len != 0 or !validContainerScreenFields(rule) or rule.max_width_px >= previous) return false;
        previous = rule.max_width_px;
    }
    return true;
}
// Merge only compiled semantic overrides at one stable root viewport. This is
// separate from applying those fields to the base and from body admission.
pub fn resolveContainerScreen(style: ContainerStyle, viewport_css_px: f64) error{InvalidPresentation}!?ContainerScreenMaxWidth {
    if (!std.math.isFinite(viewport_css_px) or viewport_css_px < 0 or !validContainerStyle(style)) return error.InvalidPresentation;
    const screen = style.screen_max_width orelse return null;
    if (viewport_css_px > @as(f64, @floatFromInt(screen.max_width_px))) return null;
    var selected = screen;
    selected.following_rules = &.{};
    for (screen.following_rules) |rule| {
        if (viewport_css_px > @as(f64, @floatFromInt(rule.max_width_px))) break;
        selected.max_width_px = rule.max_width_px;
        inline for (.{ "width", "max_width", "box_sizing", "line_height", "float_side", "margins", "clear" }) |name| {
            if (@field(rule, name)) |present| @field(selected, name) = present;
        }
    }
    return selected;
}
pub fn validContainerFontScale(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}
pub fn resolveContainerFontScale(style: ContainerStyle, inherited: f32) error{InvalidPresentation}!f32 {
    if (!validContainerStyle(style) or !validContainerFontScale(inherited)) return error.InvalidPresentation;
    return style.owner_font_scale orelse inherited;
}
pub fn validContainerStyle(value: ContainerStyle) bool {
    if (value.font_family) |family| if (!validContainerFontFamily(family)) return false;
    if (value.columns) |columns| {
        if (columns.count == 0 or !validStyleLength(columns.gap)) return false;
        // Initial semantic domain has automatic balanced block extent. Do not
        // coerce definite-height, scroll or flex fragmentation into this policy.
        if (value.height != null or value.min_height != null or value.layout == .flex_row or value.overflow == .auto or value.positioning != null) return false;
    }
    if (value.height) |height| if (!validStyleLength(height)) return false;
    if (value.min_height) |height| if (!validStyleLength(height) or value.layout == .flex_row) return false;
    if (value.owner_font_scale) |scale| if (!validContainerFontScale(scale)) return false;
    if (value.margin_values) |margins| if (value.margins != null or !validContainerMargins(margins)) return false;
    if (value.margins) |edges| if (!validContainerMarginEdges(edges)) return false;
    if (value.padding) |edges| if (!validStyleEdges(edges)) return false;
    if (value.width) |width| if (!validContainerWidth(width)) return false;
    if (value.max_width) |width| if (!validContainerMaxWidth(width)) return false;
    if (value.background) |color| if (!validContainerColor(color)) return false;
    if (value.border) |border| if (!validContainerBorder(border)) return false;
    if (value.line_height) |height| if (!validContainerLineHeight(height)) return false;
    if (value.align_items != null and value.layout != .flex_row) return false;
    if (value.screen_max_width) |screen| if (!validContainerScreenMaxWidth(screen)) return false;
    return true;
}
/// Initial native auto-height scrollport capability. General Stored validity
/// and existing L/M bytes are unchanged; unsupported layouts retain refusal.
pub fn containerAutoScrollportStyleSupported(value: ContainerStyle) bool {
    if (!validContainerStyle(value) or value.overflow != .auto) return false;
    if (value.height != null or value.min_height != null or value.columns != null or
        value.positioning != null or value.layout == .flex_row or value.flex_item != null or
        value.float_side != null or value.screen_max_width != null) return false;
    if (value.width) |width| if (width != .auto) return false;
    if (value.max_width) |width| switch (width) {
        .none => {},
        .length => |length| if (length.unit == .percent) return false,
    };
    if (value.margins) |margins| if (!validStyleEdges(margins)) return false;
    // Base auto margins are a separate newer M capability, not part of this
    // first local-scrollport contract when the components are composed.
    if (comptime @hasField(ContainerStyle, "margin_values")) if (value.margin_values != null) return false;
    return true;
}
fn nonzeroVertical(edges: StyleEdges) bool { return edges.top.value != 0 or edges.bottom.value != 0; }
fn nonzeroContainerMargin(value: ContainerMargin) bool {
    return switch (value) { .auto => false, .length => |length| length.value != 0 };
}
fn containerOwnMarginsSupported(style: ContainerStyle) bool {
    const base_vertical = if (style.margins) |edges| nonzeroVertical(edges) else false;
    if (style.float_side == null and base_vertical) return false;
    if (style.screen_max_width) |screen| {
        var floating = if (screen.float_side) |side| side != .none else style.float_side != null;
        var vertical = if (screen.margins) |edges| nonzeroContainerMargin(edges.top) or nonzeroContainerMargin(edges.bottom) else base_vertical;
        if (!floating and vertical) return false;
        for (screen.following_rules) |rule| {
            if (rule.float_side) |side| floating = side != .none;
            if (rule.margins) |edges| vertical = nonzeroContainerMargin(edges.top) or nonzeroContainerMargin(edges.bottom);
            if (!floating and vertical) return false;
        }
    }
    return true;
}
fn legacyContainerScreenMarginsSupported(screen: ContainerScreenMaxWidth) bool {
    if (screen.margins) |margins| inline for (.{ "top", "right", "bottom", "left" }) |side| {
        const margin = @field(margins, side);
        if (margin == .length and !validStyleLength(margin.length)) return false;
    };
    return true;
}
// The old full-Container wire domain remains strict even though M represents
// signed/adjoining margins. This predicate is used by version gates/selection.
pub fn legacyContainerStyleMarginsSupported(style: ContainerStyle) bool {
    if (style.margin_values != null) return false;
    if (style.margins) |margins| if (!validStyleEdges(margins)) return false;
    if (style.screen_max_width) |screen| {
        if (!legacyContainerScreenMarginsSupported(screen)) return false;
        for (screen.following_rules) |rule| if (!legacyContainerScreenMarginsSupported(rule)) return false;
    }
    return true;
}
fn containerLegacyAdjoiningMarginsSupported(value: anytype, depth: usize) bool {
    if (depth > max_content_depth or value.blocks.len > max_presentation_items) return false;
    if (!legacyContainerStyleMarginsSupported(value.style) or !containerOwnMarginsSupported(value.style)) return false;
    for (value.blocks) |block| {
        // Nested heading organization is not represented by block-child paths.
        if (std.mem.eql(u8, @tagName(block.kind), "heading")) return false;
        if (comptime @hasField(@TypeOf(block), "style")) if (block.style) |style| if (style.margins) |edges| if (nonzeroVertical(edges)) return false;
        if (comptime @hasField(@TypeOf(block), "rule_style")) if (block.rule_style) |style| if (nonzeroVertical(style.margins)) return false;
        if (comptime @hasField(@TypeOf(block), "container")) if (block.container) |child| if (!containerLegacyAdjoiningMarginsSupported(child, depth + 1)) return false;
    }
    return true;
}
pub fn legacyContainerMarginsSupported(value: anytype) bool {
    return validContainerStyle(value.style) and containerLegacyAdjoiningMarginsSupported(value, 1);
}
// The codec's existing graph walker visits descendants. Check only this own
// boundary here so feature selection does not rescan every nested subtree.
pub fn containerStyleRequiresMForMargins(style: ContainerStyle) bool {
    return !legacyContainerStyleMarginsSupported(style) or !containerOwnMarginsSupported(style);
}
pub fn containerRequiresMForMargins(value: anytype) bool {
    if (containerStyleRequiresMForMargins(value.style)) return true;
    for (value.blocks) |block| if (comptime @hasField(@TypeOf(block), "style")) if (block.style) |style|
        if (style.margins) |margins| if (nonzeroVertical(margins)) return true;
    for (value.blocks) |block| if (comptime @hasField(@TypeOf(block), "rule_style")) if (block.rule_style) |style|
        if (nonzeroVertical(style.margins)) return true;
    return false;
}
fn containerStructureSupported(value: anytype, depth: usize) bool {
    if (depth > max_content_depth or value.blocks.len > max_presentation_items or !validContainerStyle(value.style)) return false;
    for (value.blocks) |block| {
        // Margin support does not create nested organization/heading paths.
        if (std.mem.eql(u8, @tagName(block.kind), "heading")) return false;
        if (comptime @hasField(@TypeOf(block), "style")) if (block.style) |style| if (!validBlockStyle(style)) return false;
        if (comptime @hasField(@TypeOf(block), "container")) if (block.container) |child| if (!containerStructureSupported(child, depth + 1)) return false;
    }
    return true;
}
pub fn validContainerHeader(value: anytype) bool {
    return containerStructureSupported(value, 1);
}
pub fn validContainerContext(block: anytype) bool {
    if (comptime @hasField(@TypeOf(block), "rule_style")) if (block.rule_style != null) return false;
    if (comptime !@hasField(@TypeOf(block), "container")) return false;
    if (!std.mem.eql(u8, @tagName(block.kind), "container") or block.container == null or block.depth != 0 or block.spans.len != 0 or
        block.feature != null or block.table != null or block.list_path.len != 0 or block.number.len != 0 or block.level != 0 or
        block.anchor.len != 0 or block.anchor_fallback.len != 0) return false;
    if (comptime @hasField(@TypeOf(block), "figure")) if (block.figure != null) return false;
    if (comptime @hasField(@TypeOf(block), "flow")) if (block.flow != null) return false;
    if (comptime @hasField(@TypeOf(block), "style")) if (block.style != null) return false;
    if (comptime @hasField(@TypeOf(block), "text_align")) if (block.text_align != null) return false;
    return true;
}
/// Resolve a real section root plus container-child suffix; never flatten body.
pub fn resolveBlockPath(blocks: []const Block, root: usize, suffix: []const usize) ?*const Block {
    if (root >= blocks.len or suffix.len > max_content_depth) return null;
    var current = &blocks[root];
    for (suffix) |index| {
        if (!validContainerContext(current.*)) return null;
        const container = current.container.?;
        if (!validContainerHeader(container) or index >= container.blocks.len) return null;
        current = &container.blocks[index];
    }
    return current;
}
pub fn validBlockPaths(blocks: []const Block, roots: []const usize, paths: []const []const usize) bool {
    if (paths.len == 0) { for (roots) |root| if (resolveBlockPath(blocks, root, &.{}) == null) return false; return true; }
    if (paths.len != roots.len) return false;
    var any_nested = false;
    for (roots, paths) |root, path| {
        if (resolveBlockPath(blocks, root, path) == null) return false;
        any_nested = any_nested or path.len != 0;
    }
    return any_nested;
}

fn validateBlock(block: Block, table_depth: usize, media: *ImageValidation) ValidationError!void {
    if (block.rule_style) |style| if (!validRuleStyle(style) or !validRuleStyleContext(block)) return error.InvalidPresentation;
    if (block.kind == .container or block.container != null) {
        if (!validContainerContext(block) or !validContainerHeader(block.container.?) or media.content_depth >= max_content_depth) return error.InvalidPresentation;
        media.content_depth += 1; defer media.content_depth -= 1;
        for (block.container.?.blocks) |child| try validateBlock(child, table_depth, media);
        return;
    }
    if (block.table) |table| if (tableStyleIsInline(table.style) and
        !validInlineTableOwner(block.kind, block.spans.len, block.feature != null)) return error.InvalidPresentation;
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

        const blocks = entry.sections[lexeme.section].blocks;
        if (!validBlockPaths(blocks, lexeme.introduction, lexeme.introduction_paths) or !validBlockPaths(blocks, lexeme.other_blocks, lexeme.other_block_paths))
            return error.InvalidPresentation;
        for (lexeme.definitions, 0..) |sense, sense_index| {
            if (resolveBlockPath(blocks, sense.block, sense.block_path) == null) return error.InvalidPresentation;
            if (sense.parent) |parent| if (parent >= sense_index) return error.InvalidPresentation;
            if (!validBlockPaths(blocks, sense.examples, sense.example_paths) or
                !validBlockPaths(blocks, sense.quotations, sense.quotation_paths) or
                !validBlockPaths(blocks, sense.notes, sense.note_paths)) return error.InvalidPresentation;
        }
    }

    var media: ImageValidation = .{ .a = a, .media = entry.media };
    defer media.deinit();
    try validateSpanColors(entry.display_title, &media);
    try validateSpanColors(entry.preamble_spans, &media);
    media.in_reference = true;
    for (entry.references) |reference| {
        if (reference.blocks) |blocks| {
            if (reference.spans.len != 0) return error.InvalidPresentation;
            for (blocks) |block| try validateBlock(block, 0, &media);
        } else try validateSpanColors(reference.spans, &media);
    }
    media.in_reference = false;
    for (entry.sections) |section| {
        if (section.heading_style) |style| if (!validSectionHeadingStyle(style) or !validSectionHeadingCompanion(section)) return error.InvalidPresentation;
        for (section.blocks) |block| try validateBlock(block, 0, &media);
    }

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
    const value: Figure = .{ .content = .{ .image = .{ .span = .{ .kind = .link, .target = "File:Figure.svg", .target_fragment = "", .tooltip = "image advice", .background = "#123456", .image = .{ .file = "Figure.svg", .width_px = 400, .border = true } }, .sizing = .requested_fit } },
        .format = .thumbnail,  .placement = .float_right, .clear = .right,
        .margins = zero, .image_insets = zero, .caption_padding = zero, .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
        .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none }, .image_background = .{ .kind = .transparent }, .image_border = .{ .kind = .none },
        .caption_foreground = .{ .kind = .rgb, .value = "#abcdef" }, .caption_background = .{ .kind = .native_theme } };
    try std.testing.expect(validFigure(value));
    // Resolved figure paint is independent data; legacy border/background are
    // retained, not physically added a second time by a figure-aware consumer.
    try std.testing.expect(value.content.image.span.image.?.border);
    try std.testing.expectEqualStrings("#123456", value.content.image.span.background.?);
    var bad = value; bad.content.image.span.image = null; try std.testing.expect(!validFigure(bad));
    bad = value; bad.content.image.span.text = "not an image-only span"; try std.testing.expect(!validFigure(bad));
    bad = value; bad.content.image.span.trail = "trail"; try std.testing.expect(!validFigure(bad));
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
    const figure: Figure = .{ .content = .{ .image = .{ .span = .{ .image = .{ .file = "Image.svg" } }, .sizing = .intrinsic } }, .format = .framed,  .placement = .none, .clear = .none,
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
    try std.testing.expect(@hasField(FigureContent.Image, "sizing"));
    // FigureContent.Image.sizing remains required; missing has no image policy.
    // This is the typed API requirement, not an invented JSON decode service.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
    var figure: Figure = .{ .content = .{ .image = .{ .span = .{ .image = .{ .file = "Image.svg", .width_px = 400, .height_px = 100 } }, .sizing = .intrinsic } }, .format = .framed,  .placement = .none, .clear = .none,
        .margins = zero, .image_insets = zero, .caption_padding = zero, .caption_font_scale = 1, .caption_line_height = .{ .unit = .em, .value = 1 },
        .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none }, .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
        .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    try std.testing.expect(validFigure(figure));
    const json = try std.json.Stringify.valueAlloc(a, figure, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sizing\":\"intrinsic\"") != null);
    try std.testing.expectEqual(@as(?u32, 400), figure.content.image.span.image.?.width_px);
    try std.testing.expectEqual(@as(?u32, 100), figure.content.image.span.image.?.height_px);
    figure.content.image.sizing = .original_width_with_height_bound; try std.testing.expect(validFigure(figure));
    figure.content.image.span.image.?.height_px = null; try std.testing.expect(!validFigure(figure));
    figure.content.image.sizing = .intrinsic; try std.testing.expect(validFigure(figure));
    figure.format = .thumbnail; try std.testing.expect(!validFigure(figure));
    figure.content.image.sizing = .requested_fit; try std.testing.expect(validFigure(figure));
    figure.content.image.span.image.?.width_px = null; try std.testing.expect(!validFigure(figure));
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


test "computed table inline style preserves independent inherited font basis" {
    const a = std.testing.allocator;
    const style: TableStyle = .{ .display = .inline_block, .vertical_align = .middle,
        .line_height = .{ .value = 1, .font_scale_basis = .normal_body } };
    try std.testing.expect(validTableStyle(style));
    const json = try std.json.Stringify.valueAlloc(a, style, .{}); defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "inline_block") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "normal_body") != null);
    for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32) }) |bad|
        try std.testing.expect(!validTableStyle(.{ .line_height = .{ .value = bad } }));
    try std.testing.expect(validTableStyle(.{ .line_height = .{ .value = 1 } }));
    try std.testing.expect(!validTableStyle(.{ .display = .inline_block, .float_side = .left }));
    try std.testing.expect(!validInlineTableContent(style, 1, false, true));
    try std.testing.expect(!validInlineTableContent(style, 0, true, true));
    try std.testing.expect(validInlineTableContent(null, 1, true, false));
    try std.testing.expect(!validInlineTableContent(style, 0, false, false));
    const fraction = try std.json.Stringify.valueAlloc(a, ComputedLineHeight{ .value = 1.2 }, .{}); defer a.free(fraction);
    try std.testing.expect(std.mem.indexOf(u8, fraction, "1.2000000476837158") != null);
}


test "inline table intrinsic domain matches native text audio and active Egyptian branches" {
    const a = std.testing.allocator;
    const media = [_]Media{.{ .kind = .audio, .file = "Tone one.ogg", .caption = "" }};
    var index = try ImageCatalogIndex.init(a, &media); defer index.deinit(a);
    const owned: Span = .{ .classes = "wikidict-media wikidict-media-file-546f6e65206f6e652e6f6767", .text = "audio" };
    try std.testing.expect(index.supportsInlineTableAudio(owned));
    var legacy = owned; legacy.classes = "wikidict-media"; legacy.target = "File:Tone_one.ogg";
    try std.testing.expect(index.supportsInlineTableAudio(legacy));
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, media[0].file), (InlineOwnerKey{ .hex = true }).hash("546f6e65206f6e652e6f6767"));
    for ([_][]const u8{ "wikidict-media", "wikidict-media wikidict-media-file-00", "wikidict-media wikidict-media-file-546F6E65", "wikidict-media wikidict-media-file-546f6e65206f6e652e6f6767 wikidict-media-file-546f6e65206f6e652e6f6767" }) |classes| {
        var invalid = owned; invalid.classes = classes;
        try std.testing.expect(!index.supportsInlineTableAudio(invalid));
    }
    var duplicate = try ImageCatalogIndex.init(a, &.{media[0], media[0]}); defer duplicate.deinit(a);
    try std.testing.expect(!duplicate.supportsInlineTableAudio(owned));
    var image_index = try ImageCatalogIndex.init(a, &.{Media{ .kind = .image, .file = media[0].file, .caption = "" }}); defer image_index.deinit(a);
    try std.testing.expect(!image_index.supportsInlineTableAudio(owned));
    const long_media = [_]Media{.{ .kind = .audio, .file = "Very long audio filename over forty characters \u{e9}.ogg", .caption = "" }};
    var long_index = try ImageCatalogIndex.init(a, &long_media); defer long_index.deinit(a);
    const long_owner: Span = .{ .text = "long audio", .classes = "wikidict-media wikidict-media-file-56657279206c6f6e6720617564696f2066696c656e616d65206f76657220666f727479206368617261637465727320c3a92e6f6767" };
    try std.testing.expect(long_index.supportsInlineTableAudio(long_owner));
    var glyph: Span = .{ .text = "\u{13000}", .classes = "Egyp" };
    try std.testing.expect(!inlineTableSpanSupported(glyph));
    glyph.code = true; try std.testing.expect(inlineTableSpanSupported(glyph));
    glyph.code = false; glyph.font_scale = 0; try std.testing.expect(inlineTableSpanSupported(glyph));
    glyph.font_scale = null; glyph.kind = .line_break; try std.testing.expect(inlineTableSpanSupported(glyph));
    glyph.kind = .text; glyph.text = "ordinary"; glyph.trail = "\u{13000}"; try std.testing.expect(inlineTableSpanSupported(glyph));
    try std.testing.expect(!inlineTableSpanSupported(Span{ .text = "", .image = .{ .file = "Picture.svg" } }));
    const text_cell: Cell = .{ .spans = &.{owned} };
    try std.testing.expect(inlineTableShapeSupported(Table{ .rows = &.{.{ .cells = &.{text_cell} }} }));
    try std.testing.expect(!inlineTableShapeSupported(Table{ .rows = &.{.{ .cells = &.{.{ .blocks = &.{} }} }} }));
    try std.testing.expect(!inlineTableShapeSupported(Table{ .rows = &.{.{ .cells = &.{.{ .nested_table = .{} }} }} }));
}


test "inline table generic cells and tuple array slice catalogs preserve strict owner checks" {
    const LeanCell = struct { spans: []const Span = &.{} };
    const LeanRow = struct { cells: []const LeanCell };
    const LeanTable = struct { caption: []const Span = &.{}, rows: []const LeanRow };
    const owned: Span = .{ .text = "audio", .classes = "wikidict-media wikidict-media-file-546f6e65206f6e652e6f6767" };
    const cells = [_]LeanCell{.{ .spans = &.{owned} }};
    const rows = [_]LeanRow{.{ .cells = &cells }};
    try std.testing.expect(inlineTableShapeSupported(LeanTable{ .rows = &rows }));
    try std.testing.expect(!inlineTableShapeSupported(LeanTable{ .caption = &.{owned}, .rows = &rows }));
    try std.testing.expect(!inlineTableShapeSupported(LeanTable{ .rows = &.{} }));
    const image_cells = [_]LeanCell{.{ .spans = &.{.{ .text = "", .image = .{ .file = "Picture.svg" } }} }};
    const image_rows = [_]LeanRow{.{ .cells = &image_cells }};
    try std.testing.expect(!inlineTableShapeSupported(LeanTable{ .rows = &image_rows }));

    const a = std.testing.allocator;
    const audio: Media = .{ .kind = .audio, .file = "Tone one.ogg", .caption = "" };
    const image: Media = .{ .kind = .image, .file = "Picture.svg", .caption = "" };
    const media = [_]Media{ audio, image };
    var array_index = try ImageCatalogIndex.init(a, media); defer array_index.deinit(a);
    var slice_index = try ImageCatalogIndex.init(a, @as([]const Media, &media)); defer slice_index.deinit(a);
    var tuple_index = try ImageCatalogIndex.init(a, .{ audio, image }); defer tuple_index.deinit(a);
    var pointer_tuple_index = try ImageCatalogIndex.init(a, &.{ audio, image }); defer pointer_tuple_index.deinit(a);
    try std.testing.expect(array_index.supportsInlineTableAudio(owned));
    try std.testing.expect(slice_index.supportsInlineTableAudio(owned));
    try std.testing.expect(tuple_index.supportsInlineTableAudio(owned));
    try std.testing.expect(pointer_tuple_index.supportsInlineTableAudio(owned));
    try array_index.validate("Picture.svg");
    try slice_index.validate("Picture.svg");
    try tuple_index.validate("Picture.svg");
    try pointer_tuple_index.validate("Picture.svg");
    var duplicate_index = try ImageCatalogIndex.init(a, .{ audio, audio }); defer duplicate_index.deinit(a);
    try std.testing.expect(!duplicate_index.supportsInlineTableAudio(owned));
    try std.testing.expectError(error.InvalidPresentation, array_index.validate(audio.file));
}


const MissingFigureTypeTest = struct {
    fn make() Figure {
        const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
        return .{ .content = .{ .missing = .{
            .label = .{ .kind = .external_link, .text = "File:Missing.png", .target = "//example.invalid/upload?file=Missing.png", .tooltip = "File:Missing.png", .font_scale = 0.94 },
            .width = .{ .unit = .px, .value = 180 }, .line_height = .{ .unit = .em, .value = 1.504 },
        } }, .format = .thumbnail, .placement = .float_right, .clear = .none,
            .margins = zero, .image_insets = StyleEdges.all(.{ .unit = .px, .value = 3 }), .caption_padding = zero,
            .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
            .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none },
            .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
            .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    }
};

test "missing figure JSON is explicit strict XOR and preserves legacy image shape and order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var missing = MissingFigureTypeTest.make();
    missing.caption = &.{.{ .kind = .link, .text = "Caption", .target = "Caption target" }};
    try std.testing.expect(validFigure(missing));
    try std.testing.expectEqualDeep(missing.content.missing.label, missing.content.span());
    missing.content.spanPtr().bold = true;
    const json = try std.json.Stringify.valueAlloc(a, missing, .{});
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"missing_content\":"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"image_span\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sizing\"") == null);
    const parsed = try std.json.parseFromSlice(Figure, a, json, .{});
    try std.testing.expectEqualDeep(missing, parsed.value);
    const dynamic = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const from_value = try std.json.parseFromValue(Figure, a, dynamic.value, .{});
    try std.testing.expectEqualDeep(missing, from_value.value);
    for ([_][]const u8{ "\"image_span\":null", "\"sizing\":null", "\"sizing\":\"requested_fit\"", "\"unknown\":0" }) |extra| {
        const bad = try std.fmt.allocPrint(a, "{s},{s}}}", .{ json[0 .. json.len - 1], extra });
        const result = std.json.parseFromSlice(Figure, a, bad, .{ .ignore_unknown_fields = true });
        if (std.mem.startsWith(u8, extra, "\"unknown\"")) try std.testing.expectError(error.UnknownField, result)
        else try std.testing.expectError(error.UnexpectedToken, result);
    }
    var null_missing = dynamic.value;
    try null_missing.object.put(a, "missing_content", .null);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromValue(Figure, a, null_missing, .{}));
    var image = missing;
    image.content = .{ .image = .{ .span = .{ .image = .{ .file = "Picture.svg", .width_px = 180 } }, .sizing = .requested_fit } };
    const image_json = try std.json.Stringify.valueAlloc(a, image, .{});
    try std.testing.expect(std.mem.startsWith(u8, image_json, "{\"image_span\":"));
    try std.testing.expect(std.mem.indexOf(u8, image_json, "\"missing_content\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, image_json, "\"format\"").? < std.mem.indexOf(u8, image_json, "\"sizing\"").?);
    try std.testing.expect(std.mem.indexOf(u8, image_json, "\"sizing\"").? < std.mem.indexOf(u8, image_json, "\"placement\"").?);
    const old_parsed = try std.json.parseFromSlice(Figure, a, image_json, .{});
    try std.testing.expectEqualDeep(image, old_parsed.value);
    const mixed = try std.fmt.allocPrint(a, "{s},\"missing_content\":null}}", .{image_json[0 .. image_json.len - 1]});
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Figure, a, mixed, .{}));
    const duplicate = try std.fmt.allocPrint(a, "{s},\"missing_content\":null}}", .{json[0 .. json.len - 1]});
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSlice(Figure, a, duplicate, .{ .duplicate_field_behavior = .use_last }));
}

test "missing figure content rejects fake images media empty label invalid action and geometry" {
    const good = MissingFigureTypeTest.make();
    for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        var bad = good; bad.content.missing.width.value = number; try std.testing.expect(!validFigure(bad));
        bad = good; bad.content.missing.line_height.value = number; try std.testing.expect(!validFigure(bad));
    }
    for (0..9) |case| {
        var bad = good;
        switch (case) {
            0 => bad.content.missing.label.image = .{ .file = "Fake.png" },
            1 => bad.content.missing.label.text = "",
            2 => bad.content.missing.label.kind = .line_break,
            3 => bad.content.missing.label.target = "",
            4 => bad.content.missing.label.trail = "extra",
            5 => bad.content.missing.label.target_fragment = "fragment",
            6 => bad.content.missing.label.classes = "wikidict-media",
            7 => { bad.content.missing.label.font_scale = null; bad.content.missing.label.font_scale_basis = .normal_body; },
            8 => bad.content.missing.label.text = "\xff",
            else => unreachable,
        }
        try std.testing.expect(!validFigure(bad));
    }
    const MinimalSpan = struct { kind: InlineKind = .text, text: []const u8, target: []const u8 = "" };
    const generic: FigureContentFor(MinimalSpan) = .{ .missing = .{ .label = .{ .text = "Missing" },
        .width = .{ .unit = .px, .value = 1 }, .line_height = .{ .unit = .em, .value = 1 } } };
    try std.testing.expect(validMissingFigureContent(generic.missing));
    try std.testing.expectEqualStrings("Missing", generic.span().text);
    var bare = good; bare.content.missing.label.kind = .text; bare.content.missing.label.target = "";
    try std.testing.expect(validFigure(bare));
}


test "SVG raster language is nullable canonical handler identity separate from text language" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const plain: InlineImage = .{ .file = "Picture.svg", .width_px = 200 };
    const old_json = try std.json.Stringify.valueAlloc(a, plain, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "svg_language") == null);
    var ru = plain; ru.svg_language = "ru";
    var ko = plain; ko.svg_language = "ko";
    try std.testing.expect(validInlineImage(ru) and validInlineImage(ko));
    try std.testing.expect(!std.meta.eql(ru, ko));
    const span: Span = .{ .language = "ja", .image = ru };
    const json = try std.json.Stringify.valueAlloc(a, span, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"language\":\"ja\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"svg_language\":\"ru\"") != null);
    const parsed = try std.json.parseFromSlice(Span, a, json, .{});
    try std.testing.expectEqualDeep(span, parsed.value);
    for ([_][]const u8{ "ru", "ko", "zh-hant", "en", "und" }) |language| {
        // This checks handler-key syntax only; it does not grant a metadata
        // variant, infer a language, or collapse explicit default to null.
        try std.testing.expect(validSvgLanguageIdentity(language));
    }
    for ([_][]const u8{ "", "RU", "ru_foo", "ru--foo", "-ru", "ru-", "ru/ko", "ru-123", "ru\x00ko", "\xc3\xa9" }) |language| {
        var bad = plain; bad.svg_language = language;
        try std.testing.expect(!validSvgLanguageIdentity(language));
        try std.testing.expect(!validInlineImage(bad));
    }
}


test "missing link paint is explicit closed state semantics with strict JSON and unambiguous label foreground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = MissingFigureTypeTest.make();
    const absent = try std.json.Stringify.valueAlloc(a, figure, .{});
    try std.testing.expect(std.mem.indexOf(u8, absent, "link_paint") == null);
    figure.content.missing.link_paint = .vector_new_link_v1;
    try std.testing.expect(validFigure(figure));
    const json = try std.json.Stringify.valueAlloc(a, figure, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"link_paint\":\"vector_new_link_v1\"") != null);
    const parsed = try std.json.parseFromSlice(Figure, a, json, .{});
    try std.testing.expectEqualDeep(figure, parsed.value);
    const dynamic = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const from_value = try std.json.parseFromValue(Figure, a, dynamic.value, .{});
    try std.testing.expectEqualDeep(figure, from_value.value);
    const bad_enum = try std.mem.replaceOwned(u8, a, json, "vector_new_link_v1", "reader_default");
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Figure, a, bad_enum, .{}));
    var color = figure; color.content.missing.label.foreground = "#bf3c2c";
    try std.testing.expect(!validFigure(color));
    var text = figure; text.content.missing.label.kind = .text; text.content.missing.label.target = "";
    try std.testing.expect(!validFigure(text));
    text.content.missing.link_paint = null;
    try std.testing.expect(validFigure(text));
    color.content.missing.link_paint = null;
    try std.testing.expect(validFigure(color));
}


test "container style keeps compiled responsive flex paint and inherited multiplier distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const box: Container = .{ .blocks = &.{}, .style = .{
        .layout = .flex_row, .align_items = .center, .width = .{ .length = .{ .unit = .px, .value = 250 } },
        .padding = StyleEdges.all(.{ .unit = .px, .value = 4 }),
        .background = .{ .rgb = "#f9f9f9" },
        .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .light_dark = .{ .light = "#a2a9b1", .dark = "#72777d" } } } },
        .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } }, .max_width = .{ .length = .{ .unit = .percent, .value = 100 } }, .box_sizing = .border_box, .line_height = .{ .multiplier = 1.5 } },
    } };
    try std.testing.expect(validContainerHeader(box));
    const json = try std.json.Stringify.valueAlloc(a, box, .{});
    const parsed = try std.json.parseFromSlice(Container, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(box, parsed.value);
    try std.testing.expect(validContainerLineHeight(.{ .length = .{ .unit = .em, .value = 1.35 } }));
    try std.testing.expect(validContainerLineHeight(.{ .multiplier = 0 }));
    try std.testing.expect(!validContainerLineHeight(.{ .multiplier = std.math.nan(f32) }));
    try std.testing.expect(!validContainerStyle(.{ .align_items = .center }));
    try std.testing.expect(!validContainerStyle(.{ .screen_max_width = .{ .max_width_px = 719 } }));
    try std.testing.expect(!validContainerColor(.{ .light_dark = .{ .light = "red", .dark = "#000000" } }));
}

test "container shared adjoining margin boundary distinguishes floated boxes and deep zero wrappers" {
    const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
    var horizontal = zero; horizontal.left.value = 60;
    var vertical = horizontal; vertical.top.value = 10;
    const leaf = [_]Block{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "child", .target = "Target" }} }};
    try std.testing.expect(legacyContainerMarginsSupported(Container{ .blocks = &leaf, .style = .{ .margins = horizontal } }));
    try std.testing.expect(!legacyContainerMarginsSupported(Container{ .blocks = &leaf, .style = .{ .margins = vertical } }));
    try std.testing.expect(legacyContainerMarginsSupported(Container{ .blocks = &leaf, .style = .{ .margins = vertical, .float_side = .left } }));
    const own = [_]Block{.{ .kind = .paragraph, .style = .{ .margins = vertical }, .spans = &.{.{ .text = "kept" }} }};
    const wrapper = [_]Block{.{ .kind = .container, .container = .{ .blocks = &own } }};
    try std.testing.expect(!legacyContainerMarginsSupported(Container{ .blocks = &own }));
    try std.testing.expect(!legacyContainerMarginsSupported(Container{ .blocks = &wrapper }));
    try std.testing.expect(!legacyContainerMarginsSupported(Container{ .blocks = &own, .style = .{ .float_side = .left } }));
    try std.testing.expect(legacyContainerMarginsSupported(Container{ .blocks = &.{} }));
    try std.testing.expect(!legacyContainerStyleMarginsSupported(.{ .margins = StyleEdges.all(.{ .unit = .px, .value = -1 }) }));
}

test "container wrapper role XOR and real child paths remain strict" {
    const children = [_]Block{.{ .kind = .definition, .list_path = "#", .spans = &.{.{ .kind = .link, .text = "meaning", .target = "Target" }} }};
    const blocks = [_]Block{.{ .kind = .container, .container = .{ .blocks = &children } }, .{ .kind = .paragraph }};
    try std.testing.expect(validContainerContext(blocks[0]));
    var bad = blocks[0]; bad.kind = .paragraph; try std.testing.expect(!validContainerContext(bad));
    bad = blocks[0]; bad.spans = &.{.{ .text = "lost" }}; try std.testing.expect(!validContainerContext(bad));
    bad = blocks[0]; bad.flow = &.{}; try std.testing.expect(!validContainerContext(bad));
    bad = blocks[0]; bad.number = "1"; try std.testing.expect(!validContainerContext(bad));
    try std.testing.expectEqualStrings("Target", resolveBlockPath(&blocks, 0, &.{0}).?.spans[0].target);
    try std.testing.expect(resolveBlockPath(&blocks, 0, &.{1}) == null);
    try std.testing.expect(resolveBlockPath(&blocks, 1, &.{0}) == null);
    try std.testing.expect(resolveBlockPath(&blocks, 2, &.{}) == null);
    try std.testing.expect(!validBlockPaths(&blocks, &.{0}, &.{ &.{0}, &.{} }));
    try std.testing.expect(!validBlockPaths(&blocks, &.{0}, &.{&.{}}));
    try std.testing.expect(validBlockPaths(&blocks, &.{ 0, 1 }, &.{ &.{0}, &.{} }));
}

test "nested organization validates full Stored real addresses without adding legacy JSON fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const children = [_]Block{.{ .kind = .definition, .list_path = "#", .spans = &.{.{ .text = "meaning" }} }, .{ .kind = .example, .spans = &.{.{ .kind = .link, .target = "Target", .text = "example" }} }};
    const sections = [_]Section{.{ .level = 2, .title = "English", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &children } }} }};
    var senses = [_]Sense{.{ .block = 0, .block_path = &.{0}, .examples = &.{0}, .example_paths = &.{&.{1}} }};
    const lexemes = [_]Lexeme{.{ .language = "English", .kind = "Noun", .section = 0, .definitions = &senses }};
    const stored: Stored = .{ .entry = .{ .title = "entry", .kind = .language, .language = "English", .language_code = "en", .sections = &sections, .organization = .{ .lexemes = &lexemes } } };
    try validateStored(a, stored, "entry", .language, .{ .heading = "English", .code = "en" });
    const json = try std.json.Stringify.valueAlloc(a, stored, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"block_path\":[0]") != null);
    const legacy = try std.json.Stringify.valueAlloc(a, Sense{ .block = 0 }, .{});
    try std.testing.expectEqualStrings("{\"block\":0,\"parent\":null,\"examples\":[],\"quotations\":[],\"notes\":[],\"form\":null}", legacy);
    senses[0].example_paths = &.{&.{9}};
    try std.testing.expectError(error.InvalidPresentation, validateStored(a, stored, "entry", .language, .{ .heading = "English", .code = "en" }));
    senses[0].example_paths = &.{&.{1}}; senses[0].block_path = &.{9};
    try std.testing.expectError(error.InvalidPresentation, validateStored(a, stored, "entry", .language, .{ .heading = "English", .code = "en" }));
}


test "container nested headings refuse at direct and deep shared boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const heading = [_]Block{.{ .kind = .heading, .level = 3, .anchor = "Nested", .spans = &.{.{ .text = "Nested" }} }};
    const direct: Container = .{ .blocks = &heading };
    const deep: Container = .{ .blocks = &.{.{ .kind = .container, .container = direct }} };
    try std.testing.expect(!validContainerHeader(direct));
    try std.testing.expect(!validContainerHeader(deep));
    for ([_]Container{ direct, deep }) |box| {
        const stored: Stored = .{ .entry = .{ .title = "heading", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .container, .container = box }} }} } };
        try std.testing.expectError(error.InvalidPresentation, validateStored(a, stored, "heading", .supplemental, null));
    }
    const real: Container = .{ .blocks = &.{.{ .kind = .definition, .list_path = "#", .spans = &.{.{ .text = "meaning" }} }, .{ .kind = .list_item, .list_path = "*", .spans = &.{.{ .text = "item" }} }} };
    try std.testing.expect(validContainerHeader(real));
    const top: Stored = .{ .entry = .{ .title = "heading", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &heading }} } };
    try validateStored(a, top, "heading", .supplemental, null);
}


test "Container responsive float reset and auto margins preserve both viewport domains" {
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const auto_edges: ContainerMargins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto };
    const line = [_]Block{.{ .kind = .paragraph, .spans = &.{.{ .image = .{ .file = "Map.svg", .width_px = 600 } }} }};
    var box: Container = .{ .blocks = &line, .style = .{
        .float_side = .right, .clear = .right,
        .margins = .{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .px, .value = 0 }, .bottom = .{ .unit = .em, .value = 0.5 }, .left = .{ .unit = .em, .value = 0.5 } },
        .screen_max_width = .{ .max_width_px = 639, .float_side = .none, .margins = auto_edges },
    } };
    try std.testing.expect(legacyContainerMarginsSupported(box));
    // Resetting float without its nonzero vertical margin crosses the existing
    // adjoining-margin boundary; a screen override cannot waive that refusal.
    box.style.screen_max_width.?.margins = null;
    try std.testing.expect(!legacyContainerMarginsSupported(box));
    box.style.screen_max_width.?.margins = auto_edges;
    box.style.screen_max_width.?.margins.?.top = .{ .length = .{ .unit = .px, .value = 1 } };
    try std.testing.expect(!legacyContainerMarginsSupported(box));
    box.style.screen_max_width.?.float_side = .left;
    try std.testing.expect(legacyContainerMarginsSupported(box));
    box.style.screen_max_width.?.margins.?.top = .auto;
    try std.testing.expect(legacyContainerMarginsSupported(box));
    box.style.screen_max_width.?.float_side = .none;
    try std.testing.expect(legacyContainerMarginsSupported(box));
    box.style.float_side = null;
    try std.testing.expect(!legacyContainerMarginsSupported(box));
    try std.testing.expect(validContainerStyle(.{ .screen_max_width = .{ .max_width_px = 0, .float_side = .none } }));
    try std.testing.expect(!validContainerStyle(.{ .screen_max_width = .{ .max_width_px = 639 } }));
    try std.testing.expect(!validStyleLength(.{ .unit = .em, .value = -0.5 }));
    try std.testing.expect(!validContainerMargin(.{ .length = .{ .unit = .px, .value = std.math.nan(f32) } }));
}

test "Container responsive auto absent and zero remain distinct through JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const screen: ContainerScreenMaxWidth = .{ .max_width_px = 639, .float_side = .none,
        .margins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto } };
    const json = try std.json.Stringify.valueAlloc(a, screen, .{});
    const parsed = try std.json.parseFromSlice(ContainerScreenMaxWidth, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(screen, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"auto\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"float_side\":\"none\"") != null);
    const old: ContainerScreenMaxWidth = .{ .max_width_px = 719, .width = .auto };
    const old_json = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "float_side") == null);
    try std.testing.expect(std.mem.indexOf(u8, old_json, "margins") == null);
    const old_parsed = try std.json.parseFromSlice(ContainerScreenMaxWidth, a, old_json, .{}); defer old_parsed.deinit();
    try std.testing.expectEqualDeep(old, old_parsed.value);
    var changed = screen; changed.margins.?.right = zero;
    try std.testing.expect(!std.mem.eql(u8, json, try std.json.Stringify.valueAlloc(a, changed, .{})));
}


test "Container overflow auto is explicit generic data without widening adjoining margins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const box: Container = .{ .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "body" }} }}, .style = .{
        .width = .auto, .max_width = .{ .length = .{ .unit = .percent, .value = 100 } }, .overflow = .auto,
        .line_height = .{ .multiplier = 1.625 },
    } };
    try std.testing.expect(validContainerHeader(box));
    const json = try std.json.Stringify.valueAlloc(a, box, .{});
    const parsed = try std.json.parseFromSlice(Container, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(box, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"overflow\":\"auto\"") != null);
    var visible = box; visible.style.overflow = .visible;
    try std.testing.expect(validContainerHeader(visible));
    try std.testing.expect(!std.mem.eql(u8, json, try std.json.Stringify.valueAlloc(a, visible, .{})));
    visible.style.overflow = null;
    const old_json = try std.json.Stringify.valueAlloc(a, visible, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "overflow") == null);
    var refused = box; refused.style.margins = StyleEdges.all(.{ .unit = .px, .value = 1 });
    try std.testing.expect(!legacyContainerMarginsSupported(refused));
    var child = box.blocks[0]; child.style = .{ .margins = StyleEdges.all(.{ .unit = .px, .value = 1 }) };
    refused = box; refused.blocks = &.{child};
    try std.testing.expect(!legacyContainerMarginsSupported(refused));
    try std.testing.expectEqualStrings("body", refused.blocks[0].spans[0].text);
}


test "ordered container screen bands retain separate root thresholds inheritance clear and explicit resets" {
    const source: ContainerStyle = .{ .float_side = .right, .clear = .right,
        .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } },
            .max_width = .{ .length = .{ .unit = .percent, .value = 100 } }, .box_sizing = .border_box,
            .line_height = .{ .multiplier = 1.5 }, .following_rules = &.{
                .{ .max_width_px = 639, .float_side = .none, .clear = .both },
                .{ .max_width_px = 319, .clear = .none, .width = .auto, .max_width = .none },
            } }, };
    try std.testing.expect(validContainerStyle(source));
    try std.testing.expect((try resolveContainerScreen(source, 720)) == null);
    for ([_]f64{ 719, 640, 639.5 }) |viewport| {
        const selected = (try resolveContainerScreen(source, viewport)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 719), selected.max_width_px);
        try std.testing.expect(selected.float_side == null and selected.clear == null);
        try std.testing.expectEqualDeep(source.screen_max_width.?.width, selected.width);
        try std.testing.expectEqualDeep(source.screen_max_width.?.line_height, selected.line_height);
        try std.testing.expectEqual(@as(usize, 0), selected.following_rules.len);
    }
    for ([_]f64{ 639, 360, 319.5 }) |viewport| {
        const selected = (try resolveContainerScreen(source, viewport)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 639), selected.max_width_px);
        try std.testing.expect(selected.float_side == .none and selected.clear == .both);
        try std.testing.expectEqualDeep(source.screen_max_width.?.width, selected.width);
        try std.testing.expectEqualDeep(source.screen_max_width.?.line_height, selected.line_height);
        try std.testing.expect(selected.box_sizing == .border_box);
    }
    const reset = (try resolveContainerScreen(source, 319)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(reset.clear == .none and reset.float_side == .none and reset.width.? == .auto and reset.max_width.? == .none);
    try std.testing.expectEqualDeep(source.screen_max_width.?.line_height, reset.line_height);
    try std.testing.expectError(error.InvalidPresentation, resolveContainerScreen(source, -1));
    try std.testing.expectError(error.InvalidPresentation, resolveContainerScreen(source, std.math.inf(f64)));
    try std.testing.expectError(error.InvalidPresentation, resolveContainerScreen(source, std.math.nan(f64)));
}

test "ordered container rules reject ambiguous topology preserve zero and omit absent extension JSON" {
    const zero: ContainerScreenMaxWidth = .{ .max_width_px = 0, .clear = .none };
    try std.testing.expect(validContainerScreenMaxWidth(zero));
    for ([_]u32{ 719, 720 }) |limit| {
        const duplicate_or_rising: ContainerScreenMaxWidth = .{ .max_width_px = 719, .width = .auto,
            .following_rules = &.{.{ .max_width_px = limit, .clear = .both }} };
        try std.testing.expect(!validContainerScreenMaxWidth(duplicate_or_rising));
    }
    const nested: ContainerScreenMaxWidth = .{ .max_width_px = 719, .width = .auto,
        .following_rules = &.{.{ .max_width_px = 639, .clear = .both,
            .following_rules = &.{.{ .max_width_px = 319, .clear = .none }} }} };
    try std.testing.expect(!validContainerScreenMaxWidth(nested));
    try std.testing.expect(!validContainerScreenMaxWidth(.{ .max_width_px = 719,
        .following_rules = &.{.{ .max_width_px = 639, .clear = .both }} }));
    try std.testing.expect(!validContainerScreenMaxWidth(.{ .max_width_px = 719, .width = .auto,
        .following_rules = &.{.{ .max_width_px = 639 }} }));
    var excessive: [max_container_screen_rules]ContainerScreenMaxWidth = undefined;
    for (&excessive, 0..) |*rule, index| rule.* = .{ .max_width_px = @intCast(99 - index), .clear = .none };
    try std.testing.expect(validContainerScreenMaxWidth(.{ .max_width_px = 100, .width = .auto, .following_rules = excessive[0 .. max_container_screen_rules - 1] }));
    try std.testing.expect(!validContainerScreenMaxWidth(.{ .max_width_px = 100, .width = .auto, .following_rules = &excessive }));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const legacy: ContainerScreenMaxWidth = .{ .max_width_px = 719, .width = .auto };
    const bytes = try std.json.Stringify.valueAlloc(a, legacy, .{});
    try std.testing.expectEqualStrings("{\"max_width_px\":719,\"width\":{\"auto\":{}}}", bytes);
    const parsed = try std.json.parseFromSlice(ContainerScreenMaxWidth, a, bytes, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(legacy, parsed.value);
    var extended = legacy;
    extended.following_rules = &.{.{ .max_width_px = 639, .float_side = .none, .clear = .both,
        .width = .{ .length = .{ .unit = .px, .value = 0 } } }};
    const extended_json = try std.json.Stringify.valueAlloc(a, extended, .{});
    const extended_parsed = try std.json.parseFromSlice(ContainerScreenMaxWidth, a, extended_json, .{}); defer extended_parsed.deinit();
    try std.testing.expectEqualDeep(extended, extended_parsed.value);
    const resolved = (try resolveContainerScreen(.{ .screen_max_width = extended }, 639)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(ContainerWidth{ .length = .{ .unit = .px, .value = 0 } }, resolved.width.?);
}

test "ordered container bands retain adjoining margin refusal across inherited and reset states" {
    var margins = StyleEdges.all(.{ .unit = .em, .value = 0 }); margins.bottom.value = 0.45; margins.left.value = 0.45;
    var style: ContainerStyle = .{ .float_side = .right, .clear = .right, .margins = margins,
        .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } },
            .following_rules = &.{.{ .max_width_px = 639, .float_side = .none, .clear = .both }} } };
    try std.testing.expect(validContainerStyle(style));
    const body = [_]Block{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "complete body", .target = "Target" }} }};
    // These states are structurally valid M graphs. The separate legacy
    // boundary still refuses inherited adjoining margins without an M grant.
    const inherited: Container = .{ .style = style, .blocks = &body };
    try std.testing.expect(validContainerHeader(inherited));
    try std.testing.expect(!legacyContainerMarginsSupported(inherited));
    try std.testing.expect(containerRequiresMForMargins(inherited));
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    style.screen_max_width.?.following_rules = &.{.{ .max_width_px = 639, .float_side = .none, .clear = .both,
        .margins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto } }};
    const reset: Container = .{ .style = style, .blocks = &body };
    try std.testing.expect(validContainerHeader(reset));
    try std.testing.expect(legacyContainerMarginsSupported(reset));
    try std.testing.expect(!containerRequiresMForMargins(reset));
    const outer: Container = .{ .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &body,
        .style = .{ .margins = margins, .screen_max_width = .{ .max_width_px = 639, .clear = .both } } } }} };
    try std.testing.expect(validContainerHeader(outer));
    try std.testing.expect(!legacyContainerMarginsSupported(outer));
    const nested = outer.blocks[0].container orelse return error.ExpectedNestedMarginOwner;
    try std.testing.expect(containerRequiresMForMargins(nested));
}


test "container owner font is independent of child spans empty content and inherited line height" {
    const style: ContainerStyle = .{ .owner_font_scale = 0.9, .line_height = .{ .multiplier = 1.5 } };
    try std.testing.expect(validContainerHeader(Container{ .style = style, .blocks = &.{} }));
    const owner = try resolveContainerFontScale(style, 1);
    try std.testing.expectEqual(@as(f32, 0.9), owner);
    // At a20px normal-body font the owner's strut is18px with27px lineheight;
    // descendant explicit ratios2/.5 have independent60/15px lineheight.
    try std.testing.expectApproxEqAbs(@as(f32, 27), owner * 20 * style.line_height.?.multiplier, 0.00001);
    try std.testing.expectEqual(@as(f32, 60), @as(f32, 2) * 20 * style.line_height.?.multiplier);
    try std.testing.expectEqual(@as(f32, 15), @as(f32, 0.5) * 20 * style.line_height.?.multiplier);
    try std.testing.expectEqual(owner, try resolveContainerFontScale(.{}, owner));
    try std.testing.expectEqual(@as(f32, 1), try resolveContainerFontScale(.{ .owner_font_scale = 1 }, owner));
    try std.testing.expectEqual(@as(f32, 0), try resolveContainerFontScale(.{ .owner_font_scale = 0 }, owner));
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        try std.testing.expect(!validContainerStyle(.{ .owner_font_scale = bad }));
        try std.testing.expectError(error.InvalidPresentation, resolveContainerFontScale(.{}, bad));
    }
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, style, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "owner_font_scale") != null);
    const absent = try std.json.Stringify.valueAlloc(std.testing.allocator, ContainerStyle{}, .{});
    defer std.testing.allocator.free(absent);
    try std.testing.expectEqualStrings("{}", absent);
}


test "cell minimum is optional finite content lower bound distinct from inherited font and preferred width" {
    try std.testing.expect(validCellStyle(.{ .min_width = .{ .unit = .px, .value = 0 } }));
    try std.testing.expect(validCellStyle(.{ .min_width = .{ .unit = .em, .value = 30 } }));
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad|
        try std.testing.expect(!validCellStyle(.{ .min_width = .{ .unit = .em, .value = bad } }));
    const a = std.testing.allocator;
    const absent = try std.json.Stringify.valueAlloc(a, CellStyle{ .text_align = .left }, .{}); defer a.free(absent);
    try std.testing.expectEqualStrings("{\"text_align\":\"left\"}", absent);
    const zero = try std.json.Stringify.valueAlloc(a, CellStyle{ .min_width = .{ .unit = .px, .value = 0 } }, .{}); defer a.free(zero);
    try std.testing.expect(std.mem.indexOf(u8, zero, "min_width") != null);
}

test "M static STL poster validates explicit PHP rounded geometry and closed combinations" {
    const valid: InlineImage = .{ .file = "Model.STL", .width_px = 250, .height_px = 188,
        .alt = "model alternative", .tooltip = "model advice", .border = true,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "3D", .file_sha1 = "832cafd6c58519ddd441e8f7fc7d78eb14165a2e", .file_timestamp = "2020-07-25T07:26:20Z" } };
    try std.testing.expect(validInlineImage(valid));
    const widths = [_]u32{ 1, 2, 3, 4, 249, 250, 251, 252, std.math.maxInt(u32) };
    const heights = [_]u32{ 1, 2, 2, 3, 187, 188, 188, 189, 3221225471 };
    for (widths, heights) |width, height| {
        try std.testing.expectEqual(height, staticPosterHeight(width));
        var value = valid; value.width_px = width; value.height_px = height;
        try std.testing.expect(validInlineImage(value));
        value.height_px = height + 1;
        try std.testing.expect(!validInlineImage(value));
    }
    var bad = valid; bad.width_px = null; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.height_px = null; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.width_px = 0; bad.height_px = 0; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.file = "Model.png"; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.height_px = 141; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.static_poster.?.label = "\xff"; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.map = .{}; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.svg_language = "it"; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.dark_mode_filter = .invert_hue_rotate_180; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.static_poster.?.file_sha1 = "832CAFD6C58519DDD441E8F7FC7D78EB14165A2E"; try std.testing.expect(!validInlineImage(bad));
    bad = valid; bad.static_poster.?.file_sha1 = ""; try std.testing.expect(!validInlineImage(bad));
    for ([_][]const u8{ "", "2020-02-30T07:26:20Z", "2021-02-29T07:26:20Z", "2020-07-25T24:26:20Z", "2020-07-25T07:60:20Z", "2020-07-25T07:26:60Z", "2020-07-25T07:26:20+00:00", "2020-07-25T07:26:20z" }) |stamp| {
        bad = valid; bad.static_poster.?.file_timestamp = stamp; try std.testing.expect(!validInlineImage(bad));
    }
    var leap = valid; leap.static_poster.?.file_timestamp = "2020-02-29T07:26:20Z"; try std.testing.expect(validInlineImage(leap));
    var empty = valid; empty.static_poster.?.label = "";
    try std.testing.expect(validInlineImage(empty));
}

test "M static STL poster JSON preserves resolved label and absent ordinary fields" {
    const a = std.testing.allocator;
    const image: InlineImage = .{ .file = "Model.stl", .width_px = 250, .height_px = 188,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "Mod\xc3\xa8le 3D", .file_sha1 = "832cafd6c58519ddd441e8f7fc7d78eb14165a2e", .file_timestamp = "2020-07-25T07:26:20Z" } };
    const json = try std.json.Stringify.valueAlloc(a, image, .{}); defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"static_poster\":{\"policy\":\"three_d_stl_v1\",\"label\":") != null);
    const parsed = try std.json.parseFromSlice(InlineImage, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(image, parsed.value);
    var plain = image; plain.static_poster = null;
    const old = try std.json.Stringify.valueAlloc(a, plain, .{}); defer a.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "static_poster") == null);
}


test "M static poster Figure confines responsive caption policy to requested fit thumbnails" {
    const image: InlineImage = .{ .file = "BodyParts3D Tibia.stl", .width_px = 250, .height_px = 188,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "3D", .file_sha1 = "832cafd6c58519ddd441e8f7fc7d78eb14165a2e", .file_timestamp = "2020-07-25T07:26:20Z" } };
    const valid: Figure = .{ .content = .{ .image = .{ .span = .{ .image = image }, .sizing = .requested_fit } },
        .format = .thumbnail, .placement = .float_right, .clear = .right,
        .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }), .image_insets = StyleEdges.all(.{ .unit = .px, .value = 3 }),
        .caption_padding = StyleEdges.all(.{ .unit = .px, .value = 0 }), .caption_font_scale = 1,
        .caption_line_height = .{ .unit = .em, .value = 1 }, .frame_background = .{ .kind = .native_theme },
        .frame_border = .{ .kind = .none }, .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
        .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    try std.testing.expect(validFigure(valid));
    var empty = valid; empty.caption_blocks = &.{};
    try std.testing.expect(validFigure(empty));
    for ([_]FigureSizingPolicy{ .intrinsic, .original_width_with_height_bound, .requested_fit_cap_original_width }) |policy| {
        var changed = valid;
        changed.content.image.sizing = policy;
        if (policy != .requested_fit_cap_original_width) changed.format = .framed;
        try std.testing.expect(!validFigure(changed));
        try std.testing.expect(!validFlowPart(.{ .kind = .figure, .figure = changed }));
        // The corresponding ordinary image retains its existing valid domain.
        changed.content.image.span.image.?.static_poster = null;
        try std.testing.expect(validFigure(changed));
    }
}


test "M fixed Container height retains auto zero font independence and typed JSON domain" {
    const absent: ContainerStyle = .{};
    try std.testing.expect(absent.height == null);
    for ([_]StyleLength{ .{ .unit = .px, .value = 0 }, .{ .unit = .px, .value = 24 }, .{ .unit = .em, .value = 1.44 } }) |height| {
        const style: ContainerStyle = .{ .height = height, .owner_font_scale = 0.9, .box_sizing = .border_box, .line_height = .{ .multiplier = 1.5 } };
        try std.testing.expect(validContainerStyle(style));
        const json = try std.json.Stringify.valueAlloc(std.testing.allocator, style, .{}); defer std.testing.allocator.free(json);
        const parsed = try std.json.parseFromSlice(ContainerStyle, std.testing.allocator, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(style, parsed.value);
        try std.testing.expectEqual(@as(f32, 0.9), try resolveContainerFontScale(style, 2));
        try std.testing.expectEqual(@as(f32, 1.5), style.line_height.?.multiplier);
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad|
        try std.testing.expect(!validContainerStyle(.{ .height = .{ .unit = .px, .value = bad } }));
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, absent, .{}); defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{}", json);
    // M retains the fixed used height and adjoining margins independently;
    // the old full-Container margin domain continues to refuse this owner.
    const adjoining: Container = .{ .blocks = &.{}, .style = .{ .height = .{ .unit = .px, .value = 1 }, .margins = StyleEdges.all(.{ .unit = .px, .value = 2 }) } };
    try std.testing.expect(validContainerHeader(adjoining));
    try std.testing.expect(!legacyContainerMarginsSupported(adjoining));
    try std.testing.expect(containerStyleRequiresMForMargins(adjoining.style));
}


test "count columns retain one flow and strict auto-height balanced semantic domain" {
    for ([_]u16{ 1, 2, 65535 }) |count| for ([_]StyleLength{ .{ .unit = .px, .value = 0 }, .{ .unit = .em, .value = 0.95 } }) |gap| {
        const value: ContainerStyle = .{ .columns = .{ .count = count, .gap = gap } };
        try std.testing.expect(validContainerStyle(value));
        try std.testing.expect(validContainerHeader(Container{ .style = value, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "one ordered child" }} }} }));
    };
    const columns: ContainerColumns = .{ .count = 2, .gap = .{ .unit = .em, .value = 1 } };
    try std.testing.expect(!validContainerStyle(.{ .columns = .{ .count = 0, .gap = columns.gap } }));
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad|
        try std.testing.expect(!validContainerStyle(.{ .columns = .{ .count = 2, .gap = .{ .unit = .em, .value = bad } } }));
    try std.testing.expect(!validContainerStyle(.{ .columns = columns, .height = .{ .unit = .px, .value = 0 } }));
    try std.testing.expect(!validContainerStyle(.{ .columns = columns, .layout = .flex_row }));
    try std.testing.expect(!validContainerStyle(.{ .columns = columns, .overflow = .auto }));
    try std.testing.expect(validContainerStyle(.{ .columns = columns, .layout = .flow, .overflow = .visible, .owner_font_scale = 0 }));
    // The M owner retains an external adjoining margin independently of its
    // column content; this must not relax the old full-Container margin gate.
    const adjoining: Container = .{ .style = .{ .columns = columns, .margins = .{ .top = .{ .unit = .px, .value = 2 }, .right = .{ .unit = .px, .value = 0 }, .bottom = .{ .unit = .px, .value = 0 }, .left = .{ .unit = .px, .value = 0 } } }, .blocks = &.{} };
    try std.testing.expect(validContainerHeader(adjoining));
    try std.testing.expect(!legacyContainerMarginsSupported(adjoining));
    try std.testing.expect(containerStyleRequiresMForMargins(adjoining.style));
}


test "relative auto data preserves normal flow geometry and adjoining refusal" {
    const position: ContainerStyle = .{ .positioning = .relative_auto, .height = .{ .unit = .em, .value = 1.52 }, .owner_font_scale = 0.95 };
    try std.testing.expect(validContainerStyle(position));
    try std.testing.expect(position.float_side == null and position.overflow == null and position.margins == null);
    try std.testing.expectEqual(@as(f32, 1.52), position.height.?.value);
    try std.testing.expect(validContainerHeader(Container{ .style = position, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "header" }} }} }));
    try std.testing.expect(!validContainerStyle(.{ .positioning = .relative_auto, .columns = .{ .count = 2, .gap = .{ .unit = .em, .value = 1 } } }));
    const margins = StyleEdges{ .top = .{ .unit = .px, .value = 2 }, .right = .{ .unit = .px, .value = 0 }, .bottom = .{ .unit = .px, .value = 0 }, .left = .{ .unit = .px, .value = 0 } };
    const adjoining: Container = .{ .style = .{ .positioning = .relative_auto, .margins = margins }, .blocks = &.{} };
    try std.testing.expect(validContainerHeader(adjoining));
    try std.testing.expect(!legacyContainerMarginsSupported(adjoining));
    try std.testing.expect(containerStyleRequiresMForMargins(adjoining.style));
    try std.testing.expect(validContainerHeader(Container{ .style = .{ .positioning = .relative_auto, .height = .{ .unit = .px, .value = 0 } }, .blocks = &.{} }));
}


test "minimum height is independent of fixed height owner font descendants and adjoining admission" {
    for ([_]StyleLength{ .{ .unit = .px, .value = 0 }, .{ .unit = .px, .value = 24 }, .{ .unit = .em, .value = 1.52 } }) |minimum| {
        const style: ContainerStyle = .{ .min_height = minimum, .height = .{ .unit = .px, .value = 0 }, .owner_font_scale = 0.95 };
        try std.testing.expect(validContainerStyle(style));
        try std.testing.expect(validContainerHeader(Container{ .style = style, .blocks = &.{} }));
        const child: Block = .{ .kind = .paragraph, .spans = &.{.{ .text = "positive descendant", .font_scale = 2, .font_scale_basis = .normal_body }} };
        try std.testing.expect(validContainerHeader(Container{ .style = style, .blocks = &.{child} }));
        try std.testing.expectEqualDeep(minimum, style.min_height.?);
        try std.testing.expectEqual(@as(f32, 0), style.height.?.value);
        try std.testing.expectEqual(@as(f32, 0.95), try resolveContainerFontScale(style, 2));
    }
    try std.testing.expect((ContainerStyle{}).min_height == null);
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad|
        try std.testing.expect(!validContainerStyle(.{ .min_height = .{ .unit = .px, .value = bad } }));
    const zero: StyleLength = .{ .unit = .px, .value = 0 };
    try std.testing.expect(!validContainerStyle(.{ .columns = .{ .count = 2, .gap = zero }, .min_height = zero }));
    try std.testing.expect(!validContainerStyle(.{ .layout = .flex_row, .min_height = zero }));
    try std.testing.expect(!legacyContainerMarginsSupported(Container{ .style = .{ .min_height = zero, .margins = StyleEdges.all(.{ .unit = .px, .value = 2 }) }, .blocks = &.{} }));
}

test "physical border sides preserve hidden dotted asymmetric widths colors and complete typed JSON" {
    const edge: StyleBorderEdge = .{ .dotted = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } };
    const edges: StyleBorderEdges = .{ .top = edge, .right = .none, .bottom = edge, .left = .hidden };
    try std.testing.expect(validBorder(.{ .edges = edges }));
    try std.testing.expect(validTableStyle(.{ .border = .{ .edges = edges }, .collapse = .collapse }));
    try std.testing.expect(validCellStyle(.{ .border = .{ .edges = edges } }));
    const container_edges: ContainerBorderEdges = .{ .top = .{ .dotted = .{ .width = .{ .unit = .em, .value = 0.95 }, .color = .{ .rgb = "#aaaaaa" } } }, .right = .none, .bottom = .{ .solid = .{ .width = .{ .unit = .px, .value = 0 }, .color = .transparent } }, .left = .hidden };
    const style: ContainerStyle = .{ .border = .{ .edges = container_edges }, .min_height = .{ .unit = .em, .value = 1.52 }, .owner_font_scale = 0.95 };
    try std.testing.expect(validContainerStyle(style));
    const a = std.testing.allocator; const json = try std.json.Stringify.valueAlloc(a, style, .{}); defer a.free(json);
    const parsed = try std.json.parseFromSlice(ContainerStyle, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(style, parsed.value);
    try std.testing.expect(parsed.value.border.?.edges.left == .hidden and parsed.value.border.?.edges.right == .none);
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        var changed = edges; changed.top = .{ .dotted = .{ .width = .{ .unit = .px, .value = bad }, .color = "#aaaaaa" } };
        try std.testing.expect(!validBorder(.{ .edges = changed }));
        var container_changed = container_edges; container_changed.bottom = .{ .solid = .{ .width = .{ .unit = .px, .value = bad }, .color = .transparent } };
        try std.testing.expect(!validContainerBorder(.{ .edges = container_changed }));
    }
    var bad_color = edges; bad_color.bottom = .{ .dotted = .{ .width = .{ .unit = .px, .value = 1 }, .color = "red" } };
    try std.testing.expect(!validBorder(.{ .edges = bad_color }));
}

test "M Container signed margins remain separate from nonnegative box lengths and legacy adjoining admission" {
    const zero: StyleLength = .{ .unit = .px, .value = 0 };
    const negative: StyleLength = .{ .unit = .em, .value = -0.5 };
    const margins: StyleEdges = .{ .top = zero, .right = negative, .bottom = negative, .left = zero };
    try std.testing.expect(validContainerMarginEdges(margins));
    try std.testing.expect(!validStyleLength(negative) and !validStyleEdges(margins));
    try std.testing.expect(validContainerStyle(.{ .margins = margins }));
    try std.testing.expect(!validContainerStyle(.{ .padding = margins }));
    try std.testing.expect(!validBlockStyle(.{ .margins = margins }));
    try std.testing.expect(!validTableStyle(.{ .margins = margins }));
    try std.testing.expect(!validContainerStyle(.{ .height = negative }));
    try std.testing.expect(!validContainerStyle(.{ .min_height = negative }));
    const leaf = [_]Block{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "kept", .target = "Target", .target_fragment = "part", .font_scale = 1.8, .font_scale_basis = .normal_body }} }};
    const box: Container = .{ .style = .{ .margins = margins }, .blocks = &leaf };
    try std.testing.expect(validContainerHeader(box));
    try std.testing.expect(!legacyContainerMarginsSupported(box));
    var positive = box; positive.style.margins = StyleEdges.all(.{ .unit = .px, .value = 20 });
    try std.testing.expect(validContainerHeader(positive));
    try std.testing.expect(!legacyContainerMarginsSupported(positive));
    var floated = positive; floated.style.float_side = .left;
    try std.testing.expect(validContainerHeader(floated) and legacyContainerMarginsSupported(floated));
    var child = leaf[0]; child.style = .{ .margins = StyleEdges.all(.{ .unit = .px, .value = 10 }) };
    const nested: Container = .{ .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &.{child} }} } };
    try std.testing.expect(validContainerHeader(nested));
    try std.testing.expect(!legacyContainerMarginsSupported(nested));
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        var invalid = box; invalid.style.margins.?.bottom.value = bad;
        try std.testing.expect(!validContainerHeader(invalid));
        try std.testing.expect(!validContainerHeader(Container{ .blocks = &.{.{ .kind = .container, .container = invalid }} }));
    }
    const heading: Container = .{ .blocks = &.{.{ .kind = .heading, .level = 3, .spans = &.{.{ .text = "not an owned heading" }} }} };
    try std.testing.expect(!validContainerHeader(heading));
    try std.testing.expectEqualStrings("Target", box.blocks[0].spans[0].target);
    try std.testing.expectEqual(@as(f32, 1.8), box.blocks[0].spans[0].font_scale.?);
}

test "M signed Container margins survive ordered resets and full JSON without widening general lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const negative: ContainerMargin = .{ .length = .{ .unit = .em, .value = -0.5 } };
    const source: ContainerStyle = .{ .margins = StyleEdges.all(.{ .unit = .px, .value = 20 }),
        .screen_max_width = .{ .max_width_px = 719, .margins = .{ .top = zero, .right = .auto, .bottom = negative, .left = .auto },
            .following_rules = &.{.{ .max_width_px = 639, .margins = .{ .top = zero, .right = zero, .bottom = zero, .left = zero } }} } };
    try std.testing.expect(validContainerStyle(source));
    try std.testing.expect(!legacyContainerStyleMarginsSupported(source));
    const wide = try resolveContainerScreen(source, 720);
    const middle = (try resolveContainerScreen(source, 700)).?;
    const narrow = (try resolveContainerScreen(source, 639)).?;
    try std.testing.expect(wide == null);
    try std.testing.expectEqual(@as(f32, -0.5), middle.margins.?.bottom.length.value);
    try std.testing.expect(middle.margins.?.left == .auto);
    try std.testing.expectEqual(@as(f32, 0), narrow.margins.?.bottom.length.value);
    try std.testing.expect(narrow.margins.?.left == .length);
    const entry: Stored = .{ .entry = .{ .title = "signed margin", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{.{ .kind = .container, .container = .{
            .style = source, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "body", .target = "Target", .target_fragment = "part" }} }} } }} }} } };
    try validateStored(a, entry, entry.entry.title, .supplemental, null);
    const json = try std.json.Stringify.valueAlloc(a, entry, .{});
    const parsed = try std.json.parseFromSlice(Stored, a, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(entry, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, json, "-0.5") != null);
    try std.testing.expectEqualStrings("part", parsed.value.entry.sections[0].blocks[0].container.?.blocks[0].spans[0].target_fragment.?);
}

test "M inline image shape binds the exact unique image media owner without widening legacy cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const image: Span = .{ .classes = "wikidict-media wikidict-media-file-4c6f7564737065616b65722e737667", .image = .{ .file = "Loudspeaker.svg" } };
    const audio: Span = .{ .kind = .link, .text = "voice", .target = "File:Voice.ogg", .classes = "wikidict-media wikidict-media-file-566f6963652e6f6767" };
    const media = [_]Media{ .{ .kind = .image, .file = "Loudspeaker.svg", .caption = "speaker" }, .{ .kind = .audio, .file = "Voice.ogg", .caption = "voice" }, .{ .kind = .image, .file = "Other.svg", .caption = "other" } };
    var index = try ImageCatalogIndex.init(a, &media); defer index.deinit(a);
    try std.testing.expect(!inlineTableSpanSupported(image));
    try std.testing.expect(inlineTableSpanSupportedM(image));
    // The real compiler IR also has template, unlike the Stored enum. Keep
    // that uncompiled kind outside the image-action domain without assuming
    // that a generic Build Span has exactly the four Stored alternatives.
    const BuildSpan = struct {
        kind: enum { text, template, link, external_link, line_break } = .template,
        image: ?InlineImage = null, text: []const u8 = "", target: []const u8 = "",
        classes: []const u8 = "", font_scale: ?f32 = null,
        flags: packed struct(u8) { code: bool = false, rest: u7 = 0 } = .{},
    };
    var uncompiled: BuildSpan = .{ .image = image.image };
    try std.testing.expect(!inlineTableSpanSupportedM(uncompiled));
    uncompiled.kind = .text; try std.testing.expect(inlineTableSpanSupportedM(uncompiled));
    try std.testing.expect(index.supportsInlineTableMedia(image));
    try std.testing.expect(index.supportsInlineTableMedia(audio));
    try std.testing.expect(!index.supportsInlineTableAudio(image));
    var wrong = image; wrong.image.?.file = "Other.svg";
    try std.testing.expect(!index.supportsInlineTableMedia(wrong));
    var unmarked = image; unmarked.classes = "";
    try std.testing.expect(index.supportsInlineTableMedia(unmarked));
    for ([_][]const u8{ "wikidict-media", "wikidict-media wikidict-media-file-zz", "wikidict-media wikidict-media-file-4c6f7564737065616b65722e737667 wikidict-media-file-4c6f7564737065616b65722e737667" }) |classes| {
        wrong = image; wrong.classes = classes; try std.testing.expect(!index.supportsInlineTableMedia(wrong));
    }
    var duplicate = try ImageCatalogIndex.init(a, &[_]Media{media[0], media[0]}); defer duplicate.deinit(a);
    try std.testing.expect(!duplicate.supportsInlineTableMedia(image));
    var wrong_kind = try ImageCatalogIndex.init(a, &[_]Media{.{ .kind = .audio, .file = "Loudspeaker.svg", .caption = "" }}); defer wrong_kind.deinit(a);
    try std.testing.expect(!wrong_kind.supportsInlineTableMedia(image));
    const table: Table = .{ .style = .{ .display = .inline_block, .vertical_align = .top }, .rows = &.{.{ .cells = &.{ .{ .spans = &.{image, .{ .text = " Hoa Kỳ" }} }, .{ .spans = &.{audio} } } }} };
    try std.testing.expect(!inlineTableShapeSupported(table));
    try std.testing.expect(inlineTableShapeSupportedM(table));
    try std.testing.expect(inlineTableRequiresM(table));
    const stored: Stored = .{ .entry = .{ .title = "inline image", .kind = .supplemental, .media = &media, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .list_item, .list_path = "*", .depth = 1, .table = table }} }} } };
    try validateStored(a, stored, stored.entry.title, .supplemental, null);
    wrong = image; wrong.image.?.dark_mode_filter = .invert_hue_rotate_180;
    try std.testing.expect(!inlineTableSpanSupportedM(wrong));
    wrong = image; wrong.image.?.map = .{ .description = .none };
    try std.testing.expect(!inlineTableSpanSupportedM(wrong));
    wrong = image; wrong.text = "must not disappear";
    try std.testing.expect(!inlineTableSpanSupportedM(wrong));
    wrong = image; wrong.trail = "must not disappear";
    try std.testing.expect(!inlineTableSpanSupportedM(wrong));
    // External top is admitted only on the supported inline-table domain.
    for ([_]?TableDisplay{null, .table}) |display| {
        var outside = table; outside.style.?.display = display;
        try std.testing.expect(!validTableStyle(outside.style.?));
        const sections = [_]Section{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = outside }} }};
        var invalid = stored; invalid.entry.sections = &sections;
        try std.testing.expectError(error.InvalidPresentation, validateStored(a, invalid, invalid.entry.title, .supplemental, null));
    }
}

test "preferred cell width preserves null zero percent and independent minimum semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    try std.testing.expect(!validCellStyle(.{}));
    const prior: CellStyle = .{ .text_align = .left };
    try std.testing.expectEqualStrings("{\"text_align\":\"left\"}", try std.json.Stringify.valueAlloc(a, prior, .{}));
    for ([_]StyleWidth{ .{ .unit = .px, .value = 0 }, .{ .unit = .em, .value = 1.35 }, .{ .unit = .percent, .value = 48 }, .{ .unit = .percent, .value = 150 } }) |width| {
        const style: CellStyle = .{ .width = width, .min_width = .{ .unit = .px, .value = 60 }, .vertical_align = .top };
        try std.testing.expect(validCellStyle(style));
        const stored: Stored = .{ .entry = .{ .title = "cell preference", .kind = .supplemental,
            .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = .{
                .style = .{ .width = .{ .unit = .percent, .value = 100 } }, .rows = &.{.{ .cells = &.{.{ .style = style, .spans = &.{.{ .kind = .link, .target = "Kept", .text = "whole body" }} }} }} } }} }} } };
        try validateStored(a, stored, stored.entry.title, .supplemental, null);
        const json = try std.json.Stringify.valueAlloc(a, stored, .{});
        const parsed = try std.json.parseFromSlice(Stored, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(stored, parsed.value);
        const cell_style = parsed.value.entry.sections[0].blocks[0].table.?.rows[0].cells[0].style.?;
        try std.testing.expectEqualDeep(width, cell_style.width.?);
        try std.testing.expectEqual(StyleLength{ .unit = .px, .value = 60 }, cell_style.min_width.?);
    }
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |value| {
        for ([_]StyleWidthUnit{ .px, .em, .percent }) |unit| try std.testing.expect(!validCellStyle(.{ .width = .{ .unit = unit, .value = value } }));
    }
    const only_zero: CellStyle = .{ .width = .{ .unit = .percent, .value = 0 } };
    try std.testing.expect(validCellStyle(only_zero));
    const zero_json = try std.json.Stringify.valueAlloc(a, only_zero, .{});
    const zero_value = try std.json.parseFromSlice(std.json.Value, a, zero_json, .{}); defer zero_value.deinit();
    const width_value = zero_value.value.object.get("width") orelse return error.ExpectedExplicitZeroCellWidth;
    try std.testing.expectEqualStrings("percent", width_value.object.get("unit").?.string);
    const amount = switch (width_value.object.get("value").?) { .integer => |value| @as(f64, @floatFromInt(value)), .float => |value| value, else => return error.ExpectedNumericCellWidth };
    try std.testing.expectEqual(@as(f64, 0), amount);
}

test "automatic scrollport capability preserves general model validity and exact ordinary domain" {
    const known: ContainerStyle = .{ .overflow = .auto, .width = .auto, .max_width = .{ .length = .{ .unit = .px, .value = 500 } }, .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }) };
    try std.testing.expect(containerAutoScrollportStyleSupported(known));
    try std.testing.expect(containerAutoScrollportStyleSupported(.{ .overflow = .auto }));
    var max_em = known; max_em.max_width = .{ .length = .{ .unit = .em, .value = 25 } };
    try std.testing.expect(containerAutoScrollportStyleSupported(max_em));
    try std.testing.expect(!containerAutoScrollportStyleSupported(.{}));
    try std.testing.expect(!containerAutoScrollportStyleSupported(.{ .overflow = .visible }));
    const unsupported = [_]ContainerStyle{
        .{ .overflow = .auto, .height = .{ .unit = .px, .value = 0 } },
        .{ .overflow = .auto, .min_height = .{ .unit = .px, .value = 0 } },
        .{ .overflow = .auto, .layout = .flex_row },
        .{ .overflow = .auto, .flex_item = .none },
        .{ .overflow = .auto, .positioning = .relative_auto },
        .{ .overflow = .auto, .float_side = .right },
        .{ .overflow = .auto, .width = .{ .length = .{ .unit = .percent, .value = 50 } } },
        .{ .overflow = .auto, .max_width = .{ .length = .{ .unit = .percent, .value = 50 } } },
        .{ .overflow = .auto, .margins = .{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .px, .value = 0 }, .bottom = .{ .unit = .px, .value = -1 }, .left = .{ .unit = .px, .value = 0 } } },
    };
    for (unsupported, 0..) |style, index| {
        errdefer std.debug.print("SCROLLPORT_STYLE member={d}\n", .{index});
        // Existing Stored semantics remain valid; only the first native/source
        // scrollport capability is narrower. No old valid record is redefined.
        try std.testing.expect(validContainerStyle(style));
        try std.testing.expect(!containerAutoScrollportStyleSupported(style));
    }
    const columns: ContainerStyle = .{ .overflow = .auto, .columns = .{ .count = 2, .gap = .{ .unit = .em, .value = 1 } } };
    try std.testing.expect(!validContainerStyle(columns));
    try std.testing.expect(!containerAutoScrollportStyleSupported(columns));
}

test "base Container auto margins are exclusive signed typed M data independent of layout context" {
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const margins: ContainerMargins = .{ .top = zero, .right = .auto, .bottom = .{ .length = .{ .unit = .em, .value = -0.5 } }, .left = .auto };
    var style: ContainerStyle = .{ .margin_values = margins };
    try std.testing.expect(validContainerStyle(style));
    try std.testing.expect(containerStyleRequiresMForMargins(style));
    try std.testing.expect(!legacyContainerStyleMarginsSupported(style));
    // Auto is computed data, not zero: used values belong to the actual
    // ordinary/flex/float consumer and available containing width.
    for ([_]ContainerWidth{ .auto, .{ .length = .{ .unit = .px, .value = 200 } }, .fit_content }) |width| {
        style.width = width;
        try std.testing.expect(validContainerStyle(style));
        try std.testing.expect(style.margin_values.?.left == .auto);
    }
    style.max_width = .{ .length = .{ .unit = .em, .value = 20 } };
    style.flex_item = .none;
    try std.testing.expect(validContainerStyle(style));
    style.margins = StyleEdges.all(.{ .unit = .px, .value = 0 });
    try std.testing.expect(!validContainerStyle(style));
    style.margins = null;
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        var invalid = style;
        invalid.margin_values.?.bottom = .{ .length = .{ .unit = .px, .value = bad } };
        try std.testing.expect(!validContainerStyle(invalid));
    }
    try std.testing.expect(!validStyleLength(.{ .unit = .em, .value = -0.5 }));
    try std.testing.expect(validContainerStyle(.{}));
    const reset: ContainerMargins = .{ .top = zero, .right = zero, .bottom = zero, .left = zero };
    style.screen_max_width = .{ .max_width_px = 700, .width = .auto, .margins = reset,
        .following_rules = &.{.{ .max_width_px = 500, .margins = margins }} };
    try std.testing.expect((try resolveContainerScreen(style, 701)) == null);
    try std.testing.expectEqualDeep(reset, (try resolveContainerScreen(style, 600)).?.margins.?);
    try std.testing.expectEqualDeep(margins, (try resolveContainerScreen(style, 500)).?.margins.?);
    try std.testing.expectEqualDeep(margins, style.margin_values.?);
}


const TableCaptionModelFixture = struct {
    fn before() ContainerStyle {
        var margins = StyleEdges.all(.{ .unit = .px, .value = 0 }); margins.left.value = 3;
        return .{ .float_side = .right, .width = .{ .length = .{ .unit = .px, .value = 15 } },
            .height = .{ .unit = .px, .value = 11 }, .margins = margins, .background = .transparent, .border = .none };
    }
    fn media() FigureMediaLayout {
        return .{ .strut = .{ .font_scale = 1, .direction = .ltr }, .vertical_align = .middle };
    }
    fn richMedia() FigureMediaLayout {
        return .{ .strut = .{ .font_scale = 1.25, .bold = true, .italic = true, .code = true, .language = "de", .direction = .rtl },
            .vertical_align = .middle, .max_width = .{ .percent = 100, .subtract = .{ .unit = .px, .value = 8 } },
            .positioning = .relative_auto,
            .after = .{ .width = .{ .unit = .px, .value = 15 }, .height = .{ .unit = .px, .value = 11 },
                .side = .left, .inset = .{ .unit = .px, .value = 6 }, .bottom = .{ .unit = .px, .value = -11 },
                .paint = .{ .graphic = .magnify_clip_rtl_v1, .invert = true } },
            .focus_outline = .{ .width = .{ .unit = .px, .value = 2 }, .color = .{ .kind = .rgb, .value = "#3366cc" },
                .radius = .{ .unit = .px, .value = 2 }, .offset = .{ .unit = .px, .value = 0 } } };
    }
    fn layout() TableCaptionLayout {
        const edge: FigureBorderEdge = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .kind = .rgb, .value = "#a2a9b1" } } };
        var table = FigureBorderEdges.all(edge); table.bottom = .none;
        var caption = FigureBorderEdges.all(edge); caption.top = .none;
        return .{ .collapse = .collapse, .wrapper = .{}, .table_border = table, .caption_border = caption, .media = media() };
    }
    fn figure() Figure {
        const zero = StyleEdges.all(.{ .unit = .px, .value = 0 });
        return .{ .content = .{ .image = .{ .span = .{ .kind = .link, .target = "File:Mai.png", .image = .{ .file = "Mai.png", .width_px = 190 } }, .sizing = .requested_fit } },
            .format = .thumbnail, .placement = .center, .clear = .none, .table_caption_layout = layout(),
            .margins = zero, .image_insets = StyleEdges.all(.{ .unit = .px, .value = 3 }),
            .caption_padding = .{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .px, .value = 6 }, .bottom = .{ .unit = .px, .value = 6 }, .left = .{ .unit = .px, .value = 6 } },
            .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
            .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none },
            .image_background = .{ .kind = .native_theme }, .image_border = .{ .kind = .none },
            .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .native_theme } };
    }
};

test "Figure table caption keeps physical edges media constraint one caption graph and explicit responsive empty box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = TableCaptionModelFixture.figure();
    figure.table_caption_layout.?.media = TableCaptionModelFixture.richMedia();
    figure.table_caption_layout.?.caption_before = TableCaptionModelFixture.before();
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    var narrow = figure.table_caption_layout.?.media; narrow.after.?.paint = null;
    const states = [_]FigureViewportState{.{ .max_width_px = 639, .media = narrow, .wrapper = .{ .clear = .none,
        .margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto } }, .caption_before = null }};
    figure.table_caption_layout.?.viewport_states = &states;
    const caption = [_]Block{.{ .kind = .paragraph, .spans = &.{ .{ .text = "[1] Elmar " }, .{ .kind = .link, .text = "Mai", .target = "Mai", .italic = true }, .{ .text = ", Biologe" } } }};
    figure.caption_blocks = &caption;
    try std.testing.expect(validFigure(figure));
    const json = try std.json.Stringify.valueAlloc(a, figure, .{});
    const parsed = try std.json.parseFromSlice(Figure, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(figure, parsed.value);
    try std.testing.expect(parsed.value.table_caption_layout.?.table_border.bottom == .none);
    try std.testing.expect(parsed.value.table_caption_layout.?.caption_border.top == .none);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.caption_blocks.?.len);
    try std.testing.expectEqualStrings("Mai", parsed.value.caption_blocks.?[0].spans[1].target);
    try std.testing.expect(parsed.value.caption_blocks.?[0].spans[1].italic);
    try std.testing.expect((try resolveFigureViewportState(figure.table_caption_layout.?, 640)) == null);
    const selected = (try resolveFigureViewportState(figure.table_caption_layout.?, 639)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected.caption_before == null and selected.wrapper.float_side == null);
    try std.testing.expect(selected.wrapper.margin_values.?.left == .auto and selected.wrapper.margin_values.?.right == .auto);
    try std.testing.expect(figure.table_caption_layout.?.caption_before != null);
    try std.testing.expect(selected.media.after != null and selected.media.after.?.paint == null);
    try std.testing.expect(figure.table_caption_layout.?.media.after.?.paint != null);
    try std.testing.expectEqualDeep(figure.table_caption_layout.?.media.strut, selected.media.strut);
    try std.testing.expectEqual(@as(f32, 1.25), selected.media.strut.font_scale);
    try std.testing.expectEqual(@as(f32, 0.884), figure.caption_font_scale);
    try std.testing.expectEqual(@as(u32, 190), figure.content.image.span.image.?.width_px.?);
    figure.table_caption_layout = null;
    const legacy = try std.json.Stringify.valueAlloc(a, figure, .{});
    try std.testing.expect(std.mem.indexOf(u8, legacy, "table_caption_layout") == null);
}

test "Figure table caption closes invalid edge combined policy cap and viewport style domains" {
    var figure = TableCaptionModelFixture.figure();
    var invalid = figure; invalid.table_caption_layout.?.collapse = .separate;
    try std.testing.expect(!validFigure(invalid));
    invalid = figure; invalid.frame_border = .{ .kind = .solid, .width = .{ .unit = .px, .value = 0 }, .color = .{ .kind = .transparent } };
    try std.testing.expect(!validFigure(invalid));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        invalid = figure; invalid.table_caption_layout.?.table_border.left = .{ .solid = .{ .width = .{ .unit = .px, .value = number }, .color = .{ .kind = .native_theme } } };
        try std.testing.expect(!validFigure(invalid));
    }
    invalid = figure; invalid.table_caption_layout.?.caption_border.bottom = .{ .dotted = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .kind = .rgb, .value = "#ABCDEF" } } };
    try std.testing.expect(!validFigure(invalid));
    invalid = figure; invalid.table_caption_layout.?.table_border.left = .hidden;
    try std.testing.expect(validFigure(invalid));
    for ([_]f32{ -1, 0, 200, std.math.inf(f32), std.math.nan(f32) }) |percent| {
        invalid = figure; invalid.table_caption_layout.?.media.max_width = .{ .percent = percent, .subtract = .{ .unit = .px, .value = 8 } };
        try std.testing.expect(!validFigure(invalid));
    }
    var before = TableCaptionModelFixture.before(); before.width = .{ .length = .{ .unit = .percent, .value = 100 } };
    try std.testing.expect(!validFigureCaptionBefore(before));
    before = TableCaptionModelFixture.before(); before.margins.?.left.value = -1;
    try std.testing.expect(!validFigureCaptionBefore(before));
    before = TableCaptionModelFixture.before(); before.padding = StyleEdges.all(.{ .unit = .px, .value = 1 });
    try std.testing.expect(!validFigureCaptionBefore(before));
    var states = [_]FigureViewportState{ .{ .max_width_px = 639, .wrapper = .{}, .media = TableCaptionModelFixture.media() }, .{ .max_width_px = 639, .wrapper = .{}, .media = TableCaptionModelFixture.media() } };
    invalid = figure; invalid.table_caption_layout.?.viewport_states = &states;
    try std.testing.expect(!validFigure(invalid));
    states[1].max_width_px = 319; states[0].wrapper.width = .auto;
    try std.testing.expect(!validFigure(invalid));
    states[0].wrapper = .{};
    try std.testing.expect(validFigure(invalid));
    try std.testing.expectError(error.InvalidPresentation, resolveFigureViewportState(invalid.table_caption_layout.?, std.math.nan(f64)));
    try std.testing.expectError(error.InvalidPresentation, resolveFigureViewportState(invalid.table_caption_layout.?, -1));
    figure.content.image.span.image.?.file = "Model.stl";
    figure.content.image.span.image.?.height_px = staticPosterHeight(190);
    figure.content.image.span.image.?.static_poster = .{ .policy = .three_d_stl_v1, .label = "3D", .file_sha1 = "0123456789abcdef0123456789abcdef01234567", .file_timestamp = "2026-10-01T00:00:00Z" };
    figure.table_caption_layout = null; try std.testing.expect(validFigure(figure));
    figure.table_caption_layout = TableCaptionModelFixture.layout(); try std.testing.expect(!validFigure(figure));
}


test "Figure complete media strut positioned after focus and action domains refuse independently" {
    var figure = TableCaptionModelFixture.figure(); figure.table_caption_layout.?.media = TableCaptionModelFixture.richMedia();
    try std.testing.expect(validFigure(figure));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        var bad = figure; bad.table_caption_layout.?.media.strut.font_scale = number;
        try std.testing.expect(!validFigure(bad));
        bad = figure; bad.table_caption_layout.?.media.focus_outline.?.width.value = number;
        try std.testing.expect(!validFigure(bad));
        bad = figure; bad.table_caption_layout.?.media.focus_outline.?.radius.value = number;
        try std.testing.expect(!validFigure(bad));
    }
    var bad = figure; bad.table_caption_layout.?.media.strut.language = "\xff";
    try std.testing.expect(!validFigure(bad));
    bad = figure; bad.table_caption_layout.?.media.vertical_align = .baseline;
    try std.testing.expect(!validFigure(bad));
    bad = figure; bad.table_caption_layout.?.media.vertical_align = .top;
    try std.testing.expect(!validFigure(bad));
    bad = figure; bad.table_caption_layout.?.media.positioning = null;
    try std.testing.expect(!validFigure(bad));
    inline for (.{ "width", "height", "inset", "bottom" }) |field| {
        bad = figure; @field(bad.table_caption_layout.?.media.after.?, field).value += 1;
        try std.testing.expect(!validFigure(bad));
        bad = figure; @field(bad.table_caption_layout.?.media.after.?, field).unit = .em;
        try std.testing.expect(!validFigure(bad));
    }
    bad = figure; bad.table_caption_layout.?.media.focus_outline.?.offset.value = std.math.nan(f32);
    try std.testing.expect(!validFigure(bad));
    bad = figure; bad.table_caption_layout.?.media.focus_outline.?.offset.value = -2;
    try std.testing.expect(validFigure(bad));
    bad = figure; bad.table_caption_layout.?.media.strut.font_scale = 0;
    try std.testing.expect(validFigure(bad));
    bad = figure; bad.content.image.span.kind = .text; bad.content.image.span.target = "";
    try std.testing.expect(!validFigure(bad));
    bad.table_caption_layout.?.media.after = null; bad.table_caption_layout.?.media.focus_outline = null;
    try std.testing.expect(validFigure(bad));
    bad = figure; bad.content.image.span.target = "";
    try std.testing.expect(!validFigure(bad));
    bad = figure; bad.content.image.span.image.?.map = .{ .regions = &.{} };
    try std.testing.expect(validInlineImage(bad.content.image.span.image.?));
    try std.testing.expect(!validFigure(bad));
    bad.table_caption_layout = null;
    try std.testing.expect(validFigure(bad));
    var state_media = figure.table_caption_layout.?.media; state_media.strut.language = "\xff";
    const states = [_]FigureViewportState{.{ .max_width_px = 639, .wrapper = .{}, .media = state_media }};
    bad = figure; bad.table_caption_layout.?.viewport_states = &states;
    try std.testing.expect(!validFigure(bad));
}


test "Figure media strict nested JSON and complete states never borrow hidden style defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = TableCaptionModelFixture.figure(); figure.table_caption_layout.?.media = TableCaptionModelFixture.richMedia();
    const json = try std.json.Stringify.valueAlloc(a, figure, .{});
    const dynamic = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const known = try std.json.parseFromValue(Figure, a, dynamic.value, .{});
    try std.testing.expectEqualDeep(figure, known.value);
    const media = dynamic.value.object.getPtr("table_caption_layout").?.object.getPtr("media").?;
    try media.object.put(a, "unrepresented", .null);
    try std.testing.expectError(error.UnknownField, std.json.parseFromValue(Figure, a, dynamic.value, .{ .ignore_unknown_fields = true }));
    var narrow = TableCaptionModelFixture.media(); narrow.strut.font_scale = 0;
    const states = [_]FigureViewportState{.{ .max_width_px = 639, .wrapper = .{}, .media = narrow }};
    figure.table_caption_layout.?.viewport_states = &states;
    try std.testing.expect(validFigure(figure));
    const selected = (try resolveFigureViewportState(figure.table_caption_layout.?, 639)).?;
    try std.testing.expect(selected.media.after == null and selected.media.focus_outline == null);
    try std.testing.expect(selected.media.max_width == null and selected.media.positioning == null);
    try std.testing.expectEqual(@as(f32, 0), selected.media.strut.font_scale);
    try std.testing.expect(figure.table_caption_layout.?.media.after != null);
}


const FigureLinkPaintModelTest = struct {
    // Synthetic fixed data; source computation independently owns the real TH winners.
    fn normal() FigureLinkPaint {
        return .{ .normal = .{ .foreground = "#3366cc", .underline = false },
            .hover = .{ .foreground = "#3056a9", .underline = true }, .active = .{ .foreground = "#233566", .underline = true },
            .visited = .{ .foreground = "#6a60b0", .underline = false }, .visited_hover = .{ .foreground = "#534fa3", .underline = true },
            .visited_active = .{ .foreground = "#353262", .underline = true }, .underline_on_focus = true,
            .focus_outline = .{ .width = .{ .unit = .px, .value = 2 }, .color = .{ .kind = .rgb, .value = "#3366cc" },
                .radius = .{ .unit = .px, .value = 2 }, .offset = .{ .unit = .px, .value = 0 } } };
    }
    fn destructive() FigureLinkPaint {
        var value = normal();
        value.normal.foreground = "#bf3c2c"; value.hover.foreground = "#9f3526"; value.active.foreground = "#612419";
        value.visited.foreground = "#9f5555"; value.visited_hover.foreground = "#854848"; value.visited_active.foreground = "#512e2e";
        // Actual-shaped atomic label: ancestor A decoration does not propagate.
        value.normal.underline = false; value.hover.underline = false; value.active.underline = false;
        value.visited.underline = false; value.visited_hover.underline = false; value.visited_active.underline = false;
        value.underline_on_focus = false;
        return value;
    }
    fn missing() Figure {
        var figure = TableCaptionModelFixture.figure();
        figure.content = .{ .missing = .{ .label = .{ .kind = .link, .text = "Missing label", .target = "File:Missing.png", .font_scale = 0.94, .font_scale_basis = .normal_body },
            .width = .{ .unit = .px, .value = 100 }, .line_height = .{ .unit = .em, .value = 1.504 } } };
        figure.table_caption_layout.?.media = TableCaptionModelFixture.media();
        figure.table_caption_layout.?.media.vertical_align = .baseline;
        figure.table_caption_layout.?.missing_link_paint = destructive();
        figure.table_caption_layout.?.caption_link_paint = normal();
        return figure;
    }
    fn stored(a: std.mem.Allocator, figure: Figure, outside: []const Block) !Stored {
        const blocks = try a.dupe(Block, &.{.{ .kind = .paragraph, .figure = figure }});
        const sections = try a.dupe(Section, &.{.{ .level = 2, .title = "caption", .blocks = outside },
            .{ .level = 2, .title = "Figure", .blocks = blocks }});
        return .{ .entry = .{ .title = "source link states", .kind = .supplemental, .sections = sections,
            .media = &.{.{ .kind = .image, .file = "Mai.png", .caption = "media" }} } };
    }
};

test "Figure fixed source link palettes keep independent label caption colors and strict source data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var figure = FigureLinkPaintModelTest.missing();
    figure.caption = &.{.{ .kind = .external_link, .text = "Ryakuji", .target = "https://example.invalid/Ryakuji", .italic = true },
        .{ .text = " / " }, .{ .kind = .link, .text = "Door", .target = "Door", .target_fragment = "Japanese", .foreground = "#3366cc" }};
    try std.testing.expect(validFigure(figure));
    const json = try std.json.Stringify.valueAlloc(a, figure, .{});
    const parsed = try std.json.parseFromSlice(Figure, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(figure, parsed.value);
    try std.testing.expectEqualStrings("#bf3c2c", parsed.value.table_caption_layout.?.missing_link_paint.?.normal.foreground);
    try std.testing.expectEqualStrings("#3366cc", parsed.value.table_caption_layout.?.caption_link_paint.?.normal.foreground);
    try std.testing.expectEqualStrings("Japanese", parsed.value.caption[2].target_fragment.?);
    try std.testing.expect(parsed.value.caption[0].italic);
    try std.testing.expect(parsed.value.table_caption_layout.?.caption_link_paint.?.underline_on_focus);
    try std.testing.expect(!parsed.value.table_caption_layout.?.missing_link_paint.?.hover.underline);
    try std.testing.expect(!parsed.value.table_caption_layout.?.missing_link_paint.?.underline_on_focus);
    var legacy = figure; legacy.table_caption_layout = null; legacy.content.missing.link_paint = .vector_new_link_v1;
    try std.testing.expect(validFigure(legacy));
    var bad = figure; bad.content.missing.link_paint = .vector_new_link_v1;
    try std.testing.expect(!validFigure(bad));
    bad = TableCaptionModelFixture.figure(); bad.table_caption_layout.?.missing_link_paint = FigureLinkPaintModelTest.destructive();
    try std.testing.expect(!validFigure(bad));
    var inert = FigureLinkPaintModelTest.missing(); inert.content.missing.label.kind = .text;
    inert.content.missing.label.target = ""; inert.content.missing.label.target_fragment = null;
    try std.testing.expect(!validFigure(inert));
    inert.table_caption_layout.?.missing_link_paint = null;
    try std.testing.expect(validFigure(inert));
    const names = .{ "normal", "hover", "active", "visited", "visited_hover", "visited_active" };
    inline for (names) |name| {
        var paint = FigureLinkPaintModelTest.normal(); @field(paint, name).foreground = "#ABCDEF";
        try std.testing.expect(!validFigureLinkPaint(paint));
        @field(paint, name).foreground = "#36c"; try std.testing.expect(!validFigureLinkPaint(paint));
    }
    var paint = FigureLinkPaintModelTest.normal(); paint.focus_outline.?.color = .{ .kind = .native_theme };
    try std.testing.expect(!validFigureLinkPaint(paint));
    paint = FigureLinkPaintModelTest.normal(); paint.focus_outline.?.offset.value = std.math.nan(f32);
    try std.testing.expect(!validFigureLinkPaint(paint));
    var absent = TableCaptionModelFixture.figure();
    const old_json = try std.json.Stringify.valueAlloc(a, absent, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "caption_link_paint") == null);
    try std.testing.expect(std.mem.indexOf(u8, old_json, "missing_link_paint") == null);
    absent.table_caption_layout.?.caption_link_paint = FigureLinkPaintModelTest.normal();
    const dynamic = try std.json.parseFromSlice(std.json.Value, a, try std.json.Stringify.valueAlloc(a, absent, .{}), .{});
    const policy = dynamic.value.object.getPtr("table_caption_layout").?.object.getPtr("caption_link_paint").?;
    try policy.object.put(a, "borrow_native_theme", .{ .bool = true });
    // Unknown data cannot become a native default even when outer callers ask to ignore it.
    try std.testing.expectError(error.UnknownField, std.json.parseFromValue(Figure, a, dynamic.value, .{ .ignore_unknown_fields = true }));
}

test "Figure link paint follows existing bounded caption walk and resets at nested Figure boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var outer = TableCaptionModelFixture.figure(); outer.table_caption_layout.?.caption_link_paint = FigureLinkPaintModelTest.normal();
    var inner = TableCaptionModelFixture.figure(); inner.table_caption_layout = null;
    inner.caption = &.{.{ .kind = .link, .text = "inner", .target = "Inner", .foreground = "#ff0000" }};
    const links = [_]Block{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "kept", .target = "Target", .target_fragment = "Part", .foreground = "#3366cc", .bold = true }} }};
    const wrapped = [_]Block{.{ .kind = .container, .container = .{ .blocks = &links } },
        .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &links }} }} } }, .{ .kind = .paragraph, .figure = inner }};
    outer.caption_blocks = &wrapped;
    const outside = [_]Block{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "outside", .target = "Outside", .foreground = "#abcdef" }} }};
    const stored = try FigureLinkPaintModelTest.stored(a, outer, &outside);
    try validateStored(a, stored, stored.entry.title, .supplemental, null);
    var mismatch = outer; mismatch.caption_blocks = null;
    mismatch.caption = &.{.{ .kind = .link, .text = "different static", .target = "Target", .foreground = "#ff0000" }};
    const bad = try FigureLinkPaintModelTest.stored(a, mismatch, &outside);
    try std.testing.expectError(error.InvalidPresentation, validateStored(a, bad, bad.entry.title, .supplemental, null));
    var missing = FigureLinkPaintModelTest.missing(); missing.content.missing.label.foreground = "#3366cc";
    const bad_label = try FigureLinkPaintModelTest.stored(a, missing, &outside);
    try std.testing.expectError(error.InvalidPresentation, validateStored(a, bad_label, bad_label.entry.title, .supplemental, null));
}


test "CSS pixel span origin requires an explicit finite magnitude throughout Stored validation" {
    var spans = [_]Span{.{ .kind = .link, .text = "complete", .target = "Target", .target_fragment = "kept", .bold = true,
        .font_scale = 12, .font_scale_basis = .css_px }};
    const stored: Stored = .{ .entry = .{ .title = "font", .kind = .supplemental, .display_title = &spans } };
    for ([_]f32{ 0, 1, 12, 9.6 }) |value| {
        spans[0].font_scale = value;
        try validateStored(std.testing.allocator, stored, "font", .supplemental, null);
    }
    for ([_]?f32{ null, -1, std.math.nan(f32), std.math.inf(f32) }) |value| {
        spans[0].font_scale = value;
        try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, stored, "font", .supplemental, null));
    }
    try std.testing.expect(validSpanFontScale(null, .context));
    try std.testing.expect(!validSpanFontScale(null, .normal_body));
    try std.testing.expect(!validSpanFontScale(null, .css_px));
}

test "CSS pixel magnitude one survives semantic JSON independently from legacy context identity" {
    const a = std.testing.allocator;
    const span: Span = .{ .text = "full", .font_scale = 1, .font_scale_basis = .css_px };
    const bytes = try std.json.Stringify.valueAlloc(a, span, .{}); defer a.free(bytes);
    const value = try std.json.parseFromSlice(std.json.Value, a, bytes, .{}); defer value.deinit();
    try std.testing.expect(value.value.object.contains("font_scale"));
    try std.testing.expectEqualStrings("css_px", value.value.object.get("font_scale_basis").?.string);
    const restored = try std.json.parseFromSlice(Span, a, bytes, .{}); defer restored.deinit();
    try std.testing.expectEqualDeep(span, restored.value);
    const old: Span = .{ .text = "full", .font_scale = 1 };
    const old_bytes = try std.json.Stringify.valueAlloc(a, old, .{}); defer a.free(old_bytes);
    const old_value = try std.json.parseFromSlice(std.json.Value, a, old_bytes, .{}); defer old_value.deinit();
    try std.testing.expect(!old_value.value.object.contains("font_scale"));
    try std.testing.expect(!old_value.value.object.contains("font_scale_basis"));
}

test "span CSS pixel extension does not authorize table line height origins" {
    try std.testing.expect(validComputedLineHeight(.{ .value = 1, .font_scale_basis = .context }));
    try std.testing.expect(validComputedLineHeight(.{ .value = 1, .font_scale_basis = .normal_body }));
    try std.testing.expect(!validComputedLineHeight(.{ .value = 12, .font_scale_basis = .css_px }));
    try std.testing.expect(!validTableStyle(.{ .line_height = .{ .value = 12, .font_scale_basis = .css_px } }));
    try std.testing.expect(validTableStyle(.{ .line_height = .{ .value = 1, .font_scale_basis = .normal_body } }));
}

test "Figure table caption requires complete base wrapper with the same closed state domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var layout = TableCaptionModelFixture.layout();
    try std.testing.expect(validTableCaptionLayout(layout));
    const bytes = try std.json.Stringify.valueAlloc(a, layout, .{});
    const restored = try std.json.parseFromSlice(TableCaptionLayout, a, bytes, .{}); defer restored.deinit();
    try std.testing.expectEqualDeep(layout, restored.value);
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    try std.testing.expect(value.object.contains("wrapper"));
    try std.testing.expectEqual(@as(usize, 0), value.object.get("wrapper").?.object.count());
    try std.testing.expect(value.object.swapRemove("wrapper"));
    const omitted = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(TableCaptionLayout, a, omitted, .{}));
    for ([_]ContainerStyle{
        .{ .width = .auto }, .{ .height = .{ .unit = .px, .value = 0 } },
        .{ .owner_font_scale = 1 }, .{ .overflow = .auto }, .{ .positioning = .relative_auto },
        .{ .padding = StyleEdges.all(.{ .unit = .px, .value = 0 }) },
        .{ .background = .transparent }, .{ .line_height = .normal },
        .{ .screen_max_width = .{ .max_width_px = 639 } },
        .{ .margins = StyleEdges.all(.{ .unit = .px, .value = -1 }) },
    }) |wrapper| {
        layout.wrapper = wrapper;
        try std.testing.expect(!validTableCaptionLayout(layout));
    }
}

test "Figure wrapper state is a complete replacement of the explicit base record" {
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    var layout = TableCaptionModelFixture.layout();
    const base: ContainerStyle = .{ .margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto }, .clear = .right };
    const fixed: ContainerStyle = .{ .margins = StyleEdges.all(.{ .unit = .px, .value = 2 }), .float_side = .left, .clear = .left };
    layout.wrapper = base;
    const states = [_]FigureViewportState{
        .{ .max_width_px = 639, .wrapper = .{}, .media = layout.media },
        .{ .max_width_px = 420, .wrapper = fixed, .media = layout.media },
    };
    layout.viewport_states = &states;
    try std.testing.expect(validTableCaptionLayout(layout));
    for ([_]struct { width: f64, expected: ContainerStyle }{
        .{ .width = 900, .expected = base }, .{ .width = 639, .expected = .{} },
        .{ .width = 500, .expected = .{} }, .{ .width = 420, .expected = fixed }, .{ .width = 0, .expected = fixed },
    }) |case| {
        const state = try resolveFigureViewportState(layout, case.width);
        const selected = if (state) |known| known.wrapper else layout.wrapper;
        try std.testing.expectEqualDeep(case.expected, selected);
    }
    var invalid = layout;
    invalid.wrapper.margin_values.?.top = .auto;
    try std.testing.expect(!validTableCaptionLayout(invalid));
}

test "cell line height keeps nullable strut zero and explicit text origins outside old TABLE validity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const normal_json = try std.json.Stringify.valueAlloc(a, @as(CellLineHeightValue, .normal), .{});
    try std.testing.expectEqualStrings("{\"normal\":{}}", normal_json);
    const normal = try std.json.parseFromSlice(CellLineHeightValue, a, normal_json, .{}); defer normal.deinit();
    try std.testing.expectEqualDeep(@as(CellLineHeightValue, .normal), normal.value);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(CellLineHeightValue, a, "{\"normal\":[]}", .{}));
    const cases = [_]CellLineHeight{
        .{ .height = .normal },
        .{ .height = .{ .multiplier = 0 } },
        .{ .height = .{ .multiplier = 1.25 } },
        .{ .height = .{ .length = .{ .value = 0, .font_scale_basis = .normal_body } } },
        .{ .strut = .{ .font_scale = 0, .font_scale_basis = .css_px }, .height = .{ .length = .{ .value = 0, .font_scale_basis = .css_px } } },
        .{ .strut = .{ .font_scale = 0.7, .font_scale_basis = .normal_body }, .height = .{ .length = .{ .value = 0.7, .font_scale_basis = .normal_body } } },
        .{ .strut = .{ .font_scale = 12, .font_scale_basis = .css_px }, .height = .{ .length = .{ .value = 19.5, .font_scale_basis = .css_px } } },
    };
    for (cases) |height| {
        const style: CellStyle = .{ .line_height = height };
        try std.testing.expect(validCellStyle(style));
        const json = try std.json.Stringify.valueAlloc(a, style, .{});
        const parsed = try std.json.parseFromSlice(CellStyle, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(style, parsed.value);
    }
    try std.testing.expect(validComputedLineHeight(.{ .value = 1, .font_scale_basis = .context }));
    try std.testing.expect(validComputedLineHeight(.{ .value = 1, .font_scale_basis = .normal_body }));
    try std.testing.expect(!validComputedLineHeight(.{ .value = 0, .font_scale_basis = .normal_body }));
    try std.testing.expect(!validComputedLineHeight(.{ .value = 12, .font_scale_basis = .css_px }));
    try std.testing.expect(!validCellTextMetric(.{ .value = 1, .font_scale_basis = .context }));
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |number| {
        try std.testing.expect(!validCellStyle(.{ .line_height = .{ .height = .{ .multiplier = number } } }));
        try std.testing.expect(!validCellStyle(.{ .line_height = .{ .height = .{ .length = .{ .value = number, .font_scale_basis = .normal_body } } } }));
        try std.testing.expect(!validCellStyle(.{ .line_height = .{ .strut = .{ .font_scale = number, .font_scale_basis = .css_px }, .height = .normal } }));
    }
    try std.testing.expect(!validCellStyle(.{ .line_height = .{ .strut = .{ .font_scale = 1, .font_scale_basis = .context }, .height = .normal } }));
    const null_json = try std.json.Stringify.valueAlloc(a, CellLineHeight{ .height = .normal }, .{});
    const zero_json = try std.json.Stringify.valueAlloc(a, CellLineHeight{ .strut = .{ .font_scale = 0, .font_scale_basis = .normal_body }, .height = .normal }, .{});
    try std.testing.expect(!std.mem.eql(u8, null_json, zero_json));
}

test "cell line height retains genuine empty cells nonempty child fonts and complete actions in Stored" {
    const fixed: CellLineHeight = .{ .strut = .{ .font_scale = 0.7, .font_scale_basis = .normal_body }, .height = .{ .length = .{ .value = 0.7, .font_scale_basis = .normal_body } } };
    const table: Table = .{ .rows = &.{.{ .cells = &.{
        .{ .style = .{ .line_height = fixed }, .spans = &.{
            .{ .text = "whole footer ", .font_scale = 0.7, .font_scale_basis = .normal_body },
            .{ .kind = .link, .text = "larger child", .target = "Kept", .target_fragment = "section", .font_scale = 1.4, .font_scale_basis = .normal_body },
        } },
        .{ .style = .{ .line_height = .{ .height = .{ .length = .{ .value = 0, .font_scale_basis = .normal_body } } } } },
        .{ .spans = &.{.{ .text = "\u{a0}" }}, .style = .{ .line_height = .{ .height = .normal } } },
    } }} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const stored: Stored = .{ .entry = .{ .title = "cell metrics", .kind = .supplemental, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = table }} }} } };
    try validateStored(a, stored, "cell metrics", .supplemental, null);
    try std.testing.expectEqual(@as(usize, 0), table.rows[0].cells[1].spans.len);
    try std.testing.expect(table.rows[0].cells[1].blocks == null and table.rows[0].cells[1].nested_table == null);
    try std.testing.expectEqualStrings("\u{a0}", table.rows[0].cells[2].spans[0].text);
    try std.testing.expectEqual(@as(?f32, 1.4), table.rows[0].cells[0].spans[1].font_scale);
    try std.testing.expectEqualDeep(fixed, table.rows[0].cells[0].style.?.line_height.?);
    const json = try std.json.Stringify.valueAlloc(a, stored, .{});
    const parsed = try std.json.parseFromSlice(Stored, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(stored, parsed.value);
}


test "font feature JSON preserves absent legacy fields and explicit replacement reset" {
    const a = std.testing.allocator;
    const legacy = try std.json.Stringify.valueAlloc(a, Span{ .text = "unchanged" }, .{}); defer a.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "font_features") == null);
    const legacy_strut = try std.json.Stringify.valueAlloc(a, FigureMediaStrut{ .font_scale = 1, .direction = .ltr }, .{}); defer a.free(legacy_strut);
    try std.testing.expect(std.mem.indexOf(u8, legacy_strut, "font_features") == null);
    for ([_]FontFeaturePolicy{ .normal, .seven_on }) |policy| {
        const value: Span = .{ .text = "complete", .font_features = policy };
        const encoded = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(encoded);
        const decoded = try std.json.parseFromSlice(Span, a, encoded, .{}); defer decoded.deinit();
        try std.testing.expectEqualDeep(value, decoded.value);
        const strut: FigureMediaStrut = .{ .font_scale = 0.94, .direction = .rtl, .font_features = policy };
        const strut_json = try std.json.Stringify.valueAlloc(a, strut, .{}); defer a.free(strut_json);
        const strut_decoded = try std.json.parseFromSlice(FigureMediaStrut, a, strut_json, .{}); defer strut_decoded.deinit();
        try std.testing.expectEqualDeep(strut, strut_decoded.value);
    }
    for ([_][]const u8{ "{\"text\":\"kept\",\"font_features\":\"dlig\"}", "{\"text\":\"kept\",\"font_features\":2}", "{\"text\":\"kept\",\"font_features\":0}", "{\"text\":\"kept\",\"font_features\":1}", "{\"text\":\"kept\",\"font_features\":\"0\"}", "{\"text\":\"kept\",\"font_features\":\"1\"}" }) |json| {
        if (std.json.parseFromSlice(Span, a, json, .{})) |parsed| { parsed.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
}


test "table automatic margins retain old absence and strict exclusive edge domain" {
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const automatic: ContainerMargins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto };
    try std.testing.expect(validTableStyle(.{ .margin_values = automatic, .containing_direction = .ltr }));
    var one_auto = automatic; one_auto.left = .{ .length = .{ .unit = .em, .value = 0.2 } };
    try std.testing.expect(validTableStyle(.{ .margin_values = one_auto, .containing_direction = .ltr }));
    var invalid = automatic; invalid.top = .auto;
    try std.testing.expect(!validTableStyle(.{ .margin_values = invalid, .containing_direction = .ltr }));
    invalid = automatic; invalid.bottom = .{ .length = .{ .unit = .px, .value = -1 } };
    try std.testing.expect(!validTableStyle(.{ .margin_values = invalid, .containing_direction = .ltr }));
    invalid = automatic; invalid.left = .{ .length = .{ .unit = .px, .value = std.math.nan(f32) } };
    try std.testing.expect(!validTableStyle(.{ .margin_values = invalid, .containing_direction = .ltr }));
    invalid = automatic; invalid.right = zero; invalid.left = zero;
    try std.testing.expect(!validTableStyle(.{ .margin_values = invalid, .containing_direction = .ltr }));
    try std.testing.expect(!validTableStyle(.{ .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }), .margin_values = automatic, .containing_direction = .ltr }));
    const a = std.testing.allocator;
    const old = try std.json.Stringify.valueAlloc(a, TableStyle{ .clear = .none }, .{}); defer a.free(old);
    try std.testing.expectEqualStrings("{\"clear\":\"none\"}", old);
    const json = try std.json.Stringify.valueAlloc(a, TableStyle{ .margin_values = automatic, .containing_direction = .ltr }, .{}); defer a.free(json);
    const parsed = try std.json.parseFromSlice(TableStyle, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(TableStyle{ .margin_values = automatic, .containing_direction = .ltr }, parsed.value);
}

test "table containing direction is a strict paired semantic parent input independent of grid" {
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    const margins: ContainerMargins = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto };
    try std.testing.expect(validUnboundTableStyle(.{ .margin_values = margins }));
    try std.testing.expect(!validTableStyle(.{ .margin_values = margins }));
    try std.testing.expect(!validTableStyle(.{ .containing_direction = .ltr }));
    const a = std.testing.allocator;
    for ([_]TableContainingDirection{ .ltr, .rtl }) |direction| {
        const style: TableStyle = .{ .margin_values = margins, .containing_direction = direction };
        try std.testing.expect(validTableStyle(style));
        const text = try std.json.Stringify.valueAlloc(a, style, .{}); defer a.free(text);
        const parsed = try std.json.parseFromSlice(TableStyle, a, text, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(style, parsed.value);
    }
    const legacy = try std.json.Stringify.valueAlloc(a, TableStyle{ .clear = .none }, .{}); defer a.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "containing_direction") == null);
    for ([_][]const u8{ "0", "1", "2", "\"0\"", "\"auto\"", "\"RTL\"", "\"unknown\"" }) |value| {
        const text = try std.fmt.allocPrint(a, "{{\"containing_direction\":{s}}}", .{value}); defer a.free(text);
        if (std.json.parseFromSlice(TableStyle, a, text, .{})) |parsed| { parsed.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
}


const TableBlockViewportTypeTest = struct {
    fn policy() TableBlockViewport {
        const vertical: ContainerMargin = .{ .length = .{ .unit = .em, .value = 0.2 } };
        return .{ .max_viewport_width_px = 639,
            .box_style = .{ .width = .{ .unit = .percent, .value = 70 }, .clear = .none,
                .margin_values = .{ .top = vertical, .right = .auto, .bottom = vertical, .left = .auto }, .containing_direction = .ltr },
            .box_sizing = .content_box, .max_width = .{ .unit = .percent, .value = 100 },
            .grid_style = .{ .collapse = .collapse }, .grid_direction = .rtl, .language = "ru" };
    }
};
test "Table block viewport closes box grid spacing and legacy geometry domains" {
    const a = std.testing.allocator;
    const original = TableBlockViewportTypeTest.policy();
    try std.testing.expect(validTableBlockViewport(original));
    var table: Table = .{ .block_viewport = &original };
    try std.testing.expect(validTableBlockViewportHeader(table.geometry, table.style, table.block_viewport));
    // The source block and anonymous grid have independent direction/paint roles.
    try std.testing.expect(original.grid_direction != original.box_style.containing_direction.?);
    for (0..18) |mode| {
        var value = original;
        switch (mode) {
            0 => value.box_style.width = null,
            1 => value.box_style.width.?.value = 0,
            2 => value.box_style.width.?.value = -1,
            3 => value.box_style.width.?.value = std.math.inf(f32),
            4 => value.box_style.margin_values = null,
            5 => value.box_style.containing_direction = null,
            6 => value.box_style.display = .table,
            7 => value.box_style.collapse = .collapse,
            8 => value.box_style.line_height = .{ .value = 1 },
            9 => value.max_width.value = -1,
            10 => value.max_width.value = std.math.nan(f32),
            11 => value.grid_style.collapse = .separate,
            12 => value.grid_style.border = .none,
            13 => value.grid_style.background = "#abcdef",
            14 => value.grid_style.padding = StyleEdges.all(.{ .unit = .px, .value = 0 }),
            15 => value.grid_style.width = .{ .unit = .percent, .value = 100 },
            16 => value.grid_style.clear = .none,
            17 => { value.grid_style.margin_values = original.box_style.margin_values; value.grid_style.containing_direction = .ltr; },
            else => unreachable,
        }
        try std.testing.expect(!validTableBlockViewport(value));
    }
    var zero_cap = original; zero_cap.max_width.value = 0;
    try std.testing.expect(validTableBlockViewport(zero_cap));
    table.geometry = .{ .border = 1 };
    try std.testing.expect(!validTableBlockViewportHeader(table.geometry, table.style, table.block_viewport));
    table.geometry = null; table.style = .{ .display = .inline_table };
    try std.testing.expect(!validTableBlockViewportHeader(table.geometry, table.style, table.block_viewport));
    table.style = .{ .float_side = .left };
    try std.testing.expect(!validTableBlockViewportHeader(table.geometry, table.style, table.block_viewport));
    const stored: Stored = .{ .entry = .{ .title = "closed", .kind = .supplemental,
        .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{.{ .kind = .table, .table = table }} }} } };
    try std.testing.expectError(error.InvalidPresentation, validateStored(a, stored, "closed", .supplemental, null));
}
test "Table block viewport uses unrounded document CSS boundary and strict optional JSON" {
    const a = std.testing.allocator;
    const policy = TableBlockViewportTypeTest.policy();
    const table: Table = .{ .block_viewport = &policy };
    for ([_]f32{ 0, 638.75, 639 }) |viewport|
        try std.testing.expect((try resolveTableBlockViewport(table, viewport)) == &policy);
    for ([_]f32{ 639.25, 640, 800 }) |viewport|
        try std.testing.expect((try resolveTableBlockViewport(table, viewport)) == null);
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |viewport|
        try std.testing.expectError(error.InvalidPresentation, resolveTableBlockViewport(table, viewport));
    const absent: Table = .{};
    try std.testing.expect((try resolveTableBlockViewport(absent, 0)) == null);
    const old_json = try std.json.Stringify.valueAlloc(a, absent, .{}); defer a.free(old_json);
    try std.testing.expectEqualStrings("{\"caption\":[],\"rows\":[]}", old_json);
    const json = try std.json.Stringify.valueAlloc(a, table, .{}); defer a.free(json);
    var decoded = try std.json.parseFromSlice(Table, a, json, .{}); defer decoded.deinit();
    try std.testing.expectEqualDeep(table, decoded.value);
    try std.testing.expectEqual(policy.grid_direction, decoded.value.block_viewport.?.grid_direction);
    // Existing box-sizing enum is string-only in this new closed record.
    const numeric = try std.mem.replaceOwned(u8, a, json, "\"box_sizing\":\"content_box\"", "\"box_sizing\":0"); defer a.free(numeric);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Table, a, numeric, .{}));
    const unknown = try std.mem.replaceOwned(u8, a, json, "\"max_viewport_width_px\":639", "\"unknown\":true,\"max_viewport_width_px\":639"); defer a.free(unknown);
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Table, a, unknown, .{ .ignore_unknown_fields = true }));
    const invalid = try std.mem.replaceOwned(u8, a, json, "\"grid_direction\":\"rtl\"", "\"grid_direction\":2"); defer a.free(invalid);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Table, a, invalid, .{}));
}


test "Cell middle is explicit strict alignment independent of nullable legacy and text metrics" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(CellVerticalAlign.top));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(CellVerticalAlign.middle));
    const old: CellStyle = .{ .vertical_align = .top };
    const value: CellStyle = .{ .vertical_align = .middle, .padding = StyleEdges.all(.{ .unit = .px, .value = 1 }),
        .line_height = .{ .strut = .{ .font_scale = 0, .font_scale_basis = .css_px }, .height = .{ .multiplier = 1.25 } } };
    try std.testing.expect(validCellStyle(value));
    const old_json = try std.json.Stringify.valueAlloc(a, old, .{}); defer a.free(old_json);
    try std.testing.expectEqualStrings("{\"vertical_align\":\"top\"}", old_json);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(CellStyle, a, bytes, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
    try std.testing.expectEqual(CellVerticalAlign.middle, parsed.value.vertical_align.?);
    const absent: Cell = .{};
    try std.testing.expect(absent.style == null);
    for ([_][]const u8{ "{\"vertical_align\":\"baseline\"}", "{\"vertical_align\":\"bottom\"}", "{\"vertical_align\":1}", "{\"vertical_align\":\"1\"}" }) |bad| {
        if (std.json.parseFromSlice(CellStyle, a, bad, .{})) |unexpected| {
            var owned = unexpected; owned.deinit(); return error.TestUnexpectedResult;
        } else |_| {}
        var tree = try std.json.parseFromSlice(std.json.Value, a, bad, .{}); defer tree.deinit();
        if (std.json.parseFromValue(CellStyle, a, tree.value, .{})) |unexpected| {
            var owned = unexpected; owned.deinit(); return error.TestUnexpectedResult;
        } else |_| {}
    }
}


test "Table viewport requires explicit source owner language independent of entry and run language" {
    const a = std.testing.allocator;
    const policy = TableBlockViewportTypeTest.policy();
    try std.testing.expectEqualStrings("ru", policy.language);
    try std.testing.expect(validTableBlockViewport(policy));
    for ([_][]const u8{ "", "\xff", "r\xc3" }) |invalid| {
        var changed = policy; changed.language = invalid;
        try std.testing.expect(!validTableBlockViewport(changed));
    }
    const serialized = try std.json.Stringify.valueAlloc(a, policy, .{}); defer a.free(serialized);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, serialized, ",\"language\":\"ru\""));
    const missing = try std.mem.replaceOwned(u8, a, serialized, ",\"language\":\"ru\"", ""); defer a.free(missing);
    const null_value = try std.mem.replaceOwned(u8, a, serialized, "\"language\":\"ru\"", "\"language\":null"); defer a.free(null_value);
    const number = try std.mem.replaceOwned(u8, a, serialized, "\"language\":\"ru\"", "\"language\":1"); defer a.free(number);
    const empty = try std.mem.replaceOwned(u8, a, serialized, "\"language\":\"ru\"", "\"language\":\"\""); defer a.free(empty);
    for ([_][]const u8{ missing, null_value, number, empty }) |invalid| {
        if (std.json.parseFromSlice(TableBlockViewport, a, invalid, .{})) |unexpected| {
            var owned = unexpected; owned.deinit(); return error.TestUnexpectedResult;
        } else |_| {}
        var tree = try std.json.parseFromSlice(std.json.Value, a, invalid, .{}); defer tree.deinit();
        if (std.json.parseFromValue(TableBlockViewport, a, tree.value, .{})) |unexpected| {
            var owned = unexpected; owned.deinit(); return error.TestUnexpectedResult;
        } else |_| {}
    }
    const table: Table = .{ .block_viewport = &policy };
    try std.testing.expect((try resolveTableBlockViewport(table, 639)) == &policy);
    try std.testing.expect((try resolveTableBlockViewport(table, 640)) == null);
    // The owner language remains on the Table even when the narrow box is inactive.
    try std.testing.expectEqualStrings("ru", table.block_viewport.?.language);
}


test "Table float viewport preserves one body and exact fractional boundary and directions" {
    const margins = StyleEdges.all(.{ .unit = .em, .value = 0.4 });
    const policy: TableFloatViewport = .{ .max_viewport_width_px = 639, .containing_direction = .rtl, .grid_direction = .ltr, .language = "de" };
    const table: Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "KEPT" }} }} }}, .style = .{ .float_side = .right, .margins = margins, .collapse = .collapse, .clear = .right }, .float_viewport = policy };
    try std.testing.expect(validTableFloatViewportHeader(table.geometry, table.style, table.float_viewport));
    for ([_]f32{ 0, 100, 639 }) |width| {
        const selected = (try resolveTableFloatStyle(table, width)).?;
        try std.testing.expect(selected.float_side == null and selected.clear == .right);
        try std.testing.expectEqualDeep(margins, selected.margins.?);
    }
    for ([_]f32{ 639.5, 640, 1000 }) |width| try std.testing.expectEqualDeep(table.style, try resolveTableFloatStyle(table, width));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |width| try std.testing.expectError(error.InvalidPresentation, resolveTableFloatStyle(table, width));
    try std.testing.expectEqual(TableContainingDirection.rtl, table.float_viewport.?.containing_direction);
    try std.testing.expectEqual(TableContainingDirection.ltr, table.float_viewport.?.grid_direction);
    var old = table; old.float_viewport = null;
    try std.testing.expectEqualDeep(old.style, try resolveTableFloatStyle(old, std.math.nan(f32)));
}

test "Table float viewport rejects incomplete owner and conflicting legacy geometry without changing null JSON" {
    const a = std.testing.allocator;
    const policy: TableFloatViewport = .{ .max_viewport_width_px = 639, .containing_direction = .ltr, .grid_direction = .rtl, .language = "de" };
    const style: TableStyle = .{ .float_side = .right, .margins = StyleEdges.all(.{ .unit = .em, .value = 0 }) };
    var bad = policy; bad.max_viewport_width_px = 0; try std.testing.expect(!validTableFloatViewportHeader(null, style, bad));
    bad = policy; bad.language = ""; try std.testing.expect(!validTableFloatViewportHeader(null, style, bad));
    bad.language = &.{255}; try std.testing.expect(!validTableFloatViewportHeader(null, style, bad));
    try std.testing.expect(!validTableFloatViewportHeader(.{ .cell_padding = 0 }, style, policy));
    try std.testing.expect(!validTableFloatViewportHeader(null, null, policy));
    var wrong = style; wrong.float_side = .left; try std.testing.expect(!validTableFloatViewportHeader(null, wrong, policy));
    wrong = style; wrong.margins = null; try std.testing.expect(!validTableFloatViewportHeader(null, wrong, policy));
    wrong = style; wrong.width = .{ .unit = .percent, .value = 70 }; try std.testing.expect(!validTableFloatViewportHeader(null, wrong, policy));
    try std.testing.expect(!validTableFloatViewportContent(policy, 0, false, false));
    try std.testing.expect(!validTableFloatViewportContent(policy, 1, false, true));
    try std.testing.expect(!validTableFloatViewportContent(policy, 0, true, true));
    try std.testing.expect(validTableFloatViewportContent(policy, 0, false, true));
    const absent: Table = .{ .style = style }; const encoded = try std.json.Stringify.valueAlloc(a, absent, .{}); defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "float_viewport") == null);
    const present: Table = .{ .style = style, .float_viewport = policy };
    const bytes = try std.json.Stringify.valueAlloc(a, present, .{}); defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Table, a, bytes, .{}); defer parsed.deinit(); try std.testing.expectEqualDeep(present, parsed.value);
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(TableFloatViewport, a, "{\"max_viewport_width_px\":639,\"containing_direction\":\"ltr\",\"grid_direction\":\"ltr\"}", .{}));
}

const OrdinaryLinkPaintModelTesting = struct {
    fn paint() LinkPaint {
        return .{ .normal = .{ .foreground = "#3366cc", .underline = false }, .hover = .{ .foreground = "#3366cc", .underline = true },
            .active = .{ .foreground = "#233566", .underline = false }, .hover_active = .{ .foreground = "#233566", .underline = true },
            .visited = .{ .foreground = "#6a60b0", .underline = false },
            .visited_hover = .{ .foreground = "#6a60b0", .underline = true }, .visited_active = .{ .foreground = "#233566", .underline = false },
            .visited_hover_active = .{ .foreground = "#233566", .underline = true },
            .underline_on_focus = true };
    }
};

test "ordinary source link paint eight states and focus preserve independent hover active and history" {
    const paint = OrdinaryLinkPaintModelTesting.paint();
    inline for (.{ "normal", "hover", "active", "hover_active", "visited", "visited_hover", "visited_active", "visited_hover_active" }, 0..) |name, index| {
        const visited = index >= 4; const active = index % 4 >= 2; const hover = index % 2 == 1;
        try std.testing.expectEqualDeep(@field(paint, name), linkPaintState(paint, visited, hover, active, false));
        const focused = linkPaintState(paint, visited, hover, active, true);
        try std.testing.expectEqualStrings(@field(paint, name).foreground, focused.foreground);
        try std.testing.expect(focused.underline);
        try std.testing.expectEqualDeep(@field(paint, if (visited) "visited_hover_active" else "hover_active"), linkPaintState(paint, visited, true, true, false));
        try std.testing.expect(!linkPaintState(paint, visited, false, true, false).underline);
        try std.testing.expect(linkPaintState(paint, visited, true, true, false).underline);
    }
}

test "ordinary source link paint refuses inert image malformed and normal paint conflicts" {
    var span: Span = .{ .kind = .link, .text = "kept", .target = "Target", .link_paint = OrdinaryLinkPaintModelTesting.paint() };
    try std.testing.expect(validSpanLinkPaint(span));
    span.kind = .external_link; try std.testing.expect(validSpanLinkPaint(span));
    span.kind = .text; try std.testing.expect(!validSpanLinkPaint(span));
    span.kind = .line_break; try std.testing.expect(!validSpanLinkPaint(span));
    span.kind = .link; span.target = ""; try std.testing.expect(!validSpanLinkPaint(span));
    span.target = "Target"; span.image = .{ .file = "Image.svg" }; try std.testing.expect(!validSpanLinkPaint(span));
    span.image = null; span.foreground = "#3366cc"; try std.testing.expect(validSpanLinkPaint(span));
    span.foreground = "#ffffff"; try std.testing.expect(!validSpanLinkPaint(span));
    span.foreground = null; span.underline = true; try std.testing.expect(!validSpanLinkPaint(span));
    span.underline = false; span.link_paint.?.visited.foreground = "#ABCDEF"; try std.testing.expect(!validSpanLinkPaint(span));
    span.link_paint = OrdinaryLinkPaintModelTesting.paint();
    span.link_paint.?.focus_outline = .{ .width = .{ .unit = .px, .value = 1 }, .color = .{ .kind = .native_theme },
        .radius = .{ .unit = .px, .value = 0 }, .offset = .{ .unit = .px, .value = 0 } };
    try std.testing.expect(!validSpanLinkPaint(span));
}

test "ordinary source link paint absent JSON stays exact and strict structured data survives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const absent: Span = .{ .kind = .link, .text = "body", .target = "Target" };
    const old = try std.json.Stringify.valueAlloc(a, absent, .{});
    try std.testing.expect(std.mem.indexOf(u8, old, "link_paint") == null);
    const parsed_null = try std.json.parseFromSlice(Span, a, "{\"kind\":\"link\",\"text\":\"body\",\"target\":\"Target\",\"link_paint\":null}", .{}); defer parsed_null.deinit();
    try std.testing.expectEqualStrings(old, try std.json.Stringify.valueAlloc(a, parsed_null.value, .{}));
    var present = absent; present.link_paint = OrdinaryLinkPaintModelTesting.paint();
    const json_bytes = try std.json.Stringify.valueAlloc(a, present, .{});
    const parsed = try std.json.parseFromSlice(Span, a, json_bytes, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(present, parsed.value); try std.testing.expect(validSpanLinkPaint(parsed.value));
    const six_only = try std.json.Stringify.valueAlloc(a, present.link_paint.?.sixStatePrefix(), .{});
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(LinkPaint, a, six_only, .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Span, a, "{\"link_paint\":{}}", .{}));
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Span, a, "{\"link_paint\":{\"unknown\":true}}", .{}));
}

test "ordinary combined link paint rejects malformed combined colors without changing Figure palette" {
    var paint = OrdinaryLinkPaintModelTesting.paint();
    try std.testing.expect(validLinkPaint(paint));
    try std.testing.expect(validFigureLinkPaint(paint.sixStatePrefix()));
    paint.hover_active.foreground = "#ABCDEF"; try std.testing.expect(!validLinkPaint(paint));
    try std.testing.expect(validFigureLinkPaint(paint.sixStatePrefix()));
    paint = OrdinaryLinkPaintModelTesting.paint(); paint.visited_hover_active.foreground = "#36c";
    try std.testing.expect(!validLinkPaint(paint));
}


test "authored Rule style validates finite colors lengths and strict separator ownership" {
    const zero: StyleLength = .{ .unit = .px, .value = 0 };
    const style: RuleStyle = .{ .height = .{ .unit = .px, .value = 1 }, .fill = .{ .light_dark = .{ .light = "#a2a9b1", .dark = "#54595d" } },
        .margins = .{ .top = .{ .unit = .em, .value = 0.2 }, .right = zero, .bottom = .{ .unit = .em, .value = 0.2 }, .left = zero } };
    const block: Block = .{ .kind = .rule, .rule_style = style };
    const LegacyWithoutRuleFields = struct { kind: BlockKind = .rule };
    try std.testing.expect(!validRuleStyleContext(LegacyWithoutRuleFields{}));
    try std.testing.expect(validRuleStyle(style) and validRuleStyleContext(block));
    var zero_style = style; zero_style.height = zero; zero_style.fill = .transparent;
    try std.testing.expect(validRuleStyle(zero_style));
    inline for (comptime std.meta.tags(BlockKind)) |kind| {
        var changed = block; changed.kind = kind;
        try std.testing.expectEqual(kind == .rule, validRuleStyleContext(changed));
    }
    for (0..13) |mode| {
        var changed = block;
        switch (mode) {
            0 => changed.depth = 1,
            1 => changed.level = 1,
            2 => changed.list_path = ":",
            3 => changed.number = "1",
            4 => changed.anchor = "x",
            5 => changed.anchor_fallback = "x",
            6 => changed.spans = &.{.{ .kind = .link, .text = "x", .target = "x" }},
            7 => changed.feature = .{ .kind = "x" },
            8 => changed.table = .{},
            9 => changed.container = .{ .blocks = &.{} },
            10 => changed.flow = &.{},
            11 => changed.text_align = .center,
            12 => changed.style = .{},
            else => unreachable,
        }
        try std.testing.expect(!validRuleStyleContext(changed));
        const invalid: Stored = .{ .entry = .{ .title = "rule", .kind = .supplemental,
            .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{changed} }} } };
        try std.testing.expectError(error.InvalidPresentation, validateStored(std.testing.allocator, invalid, "rule", .supplemental, null));
    }
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        var changed = style; changed.height.value = invalid; try std.testing.expect(!validRuleStyle(changed));
        changed = style; changed.margins.bottom.value = invalid; try std.testing.expect(!validRuleStyle(changed));
    }
    for ([_][]const u8{ "red", "#ABCDEF", "#fff", "#a2a9b100", "" }) |invalid| {
        var changed = style; changed.fill = .{ .rgb = invalid }; try std.testing.expect(!validRuleStyle(changed));
    }
}

test "nullable Rule JSON preserves old separator fields and rejects malformed authored shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: Block = .{ .kind = .rule };
    const bytes = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rule_style") == null);
    try std.testing.expectEqualDeep(old, (try std.json.parseFromSlice(Block, a, bytes, .{})).value);
    const style: RuleStyle = .{ .height = .{ .unit = .px, .value = 0 }, .fill = .transparent,
        .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }) };
    const authored: Block = .{ .kind = .rule, .rule_style = style };
    const encoded = try std.json.Stringify.valueAlloc(a, authored, .{});
    try std.testing.expectEqualDeep(authored, (try std.json.parseFromSlice(Block, a, encoded, .{})).value);
    const valid = try std.json.Stringify.valueAlloc(a, style, .{});
    const unknown = try std.mem.concat(a, u8, &.{ valid[0 .. valid.len - 1], ",\"width\":100}" });
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(RuleStyle, a, unknown, .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(RuleStyle, a, "{}", .{}));
}


test "authored Rule vertical margins cannot acquire legacy container adjoining authority" {
    const zero: StyleLength = .{ .unit = .px, .value = 0 };
    var style: RuleStyle = .{ .height = .{ .unit = .px, .value = 1 }, .fill = .transparent,
        .margins = .{ .top = .{ .unit = .em, .value = 0.2 }, .right = zero, .bottom = zero, .left = zero } };
    const block: Block = .{ .kind = .rule, .rule_style = style };
    const box: Container = .{ .blocks = &.{block} };
    const nested: Container = .{ .blocks = &.{.{ .kind = .container, .container = box }} };
    try std.testing.expect(validContainerHeader(box) and validContainerHeader(nested));
    try std.testing.expect(!legacyContainerMarginsSupported(box));
    try std.testing.expect(!legacyContainerMarginsSupported(nested));
    try std.testing.expect(containerRequiresMForMargins(box));
    // The capability graph walker visits the child; this predicate checks
    // only the own boundary rather than repeatedly scanning all descendants.
    try std.testing.expect(!containerRequiresMForMargins(nested));
    style.margins.top = zero;
    for ([_]f32{ 0, 5 }) |horizontal| {
        style.margins.left.value = horizontal;
        const flat: Container = .{ .blocks = &.{.{ .kind = .rule, .rule_style = style }} };
        try std.testing.expect(legacyContainerMarginsSupported(flat));
        try std.testing.expect(!containerRequiresMForMargins(flat));
    }
    const old: Container = .{ .blocks = &.{.{ .kind = .rule }} };
    try std.testing.expect(legacyContainerMarginsSupported(old));
    try std.testing.expect(!containerRequiresMForMargins(old));
}


test "authored inline policies keep annotation link paint and semantic script ownership separate" {
    const strut: InlineTextStyle = .{ .line_height = .{ .font_relative = .{ .factor = 1,
        .font = .{ .superscript = true } } } };
    const empty: Span = .{ .superscript = true, .inline_style = strut };
    try std.testing.expect(validSpanInlineStyle(empty));
    var smaller = empty; smaller.text = "+"; smaller.font_scale = 1.0 / 1.2;
    try std.testing.expect(validSpanInlineStyle(smaller));
    try std.testing.expectEqual(@as(?f32, null), smaller.inline_style.?.line_height.?.font_relative.font.font_scale);
    const abbreviation: Span = .{ .kind = .external_link, .text = "Joyo", .target = "https://example.invalid/Joyo",
        .tooltip = "source title", .explanation = "source title", .underline = true,
        .inline_style = .{ .decoration = .{ .style = .dotted } } };
    try std.testing.expect(validSpanInlineStyle(abbreviation));
    var normalized = smaller; normalized.font_scale = 0.75; normalized.font_scale_basis = .normal_body;
    normalized.inline_style.?.font_normalized = true;
    normalized.inline_style.?.baseline_shift = .{ .value = -0.25, .font_scale_basis = .normal_body };
    try std.testing.expect(!validSpanInlineStyle(normalized));
    normalized.inline_style.?.line_height.?.font_relative.font = .{ .font_scale = 0.75,
        .font_scale_basis = .normal_body, .superscript = true, .font_normalized = true };
    try std.testing.expect(validSpanInlineStyle(normalized));
    try std.testing.expect(normalized.superscript);
    normalized.bold = true; normalized.italic = true; normalized.code = true;
    normalized.language = "ja"; normalized.classes = "Jpan"; normalized.role = .headword;
    normalized.font_features = .seven_on;
    try std.testing.expect(!validSpanInlineStyle(normalized));
    const owner = &normalized.inline_style.?.line_height.?.font_relative.font;
    owner.bold = true; owner.italic = true; owner.code = true;
    owner.language = "ja"; owner.classes = "Jpan"; owner.role = .headword;
    owner.font_features = .seven_on;
    try std.testing.expect(validSpanInlineStyle(normalized));
    owner.language = "en"; try std.testing.expect(!validSpanInlineStyle(normalized));
    owner.language = "ja"; owner.font_features = .normal;
    try std.testing.expect(!validSpanInlineStyle(normalized));
    const plain: Span = .{ .text = "Joyo", .explanation = "advisory only" };
    try std.testing.expect(plain.inline_style == null);
}

test "authored inline policies reject empty ownership invalid numeric data and incompatible spans" {
    const good: Span = .{ .text = "x", .inline_style = .{ .decoration = .{ .style = .dotted } } };
    try std.testing.expect(validSpanInlineStyle(good));
    var bad = good; bad.inline_style = .{}; try std.testing.expect(!validSpanInlineStyle(bad));
    bad = good; bad.text = ""; try std.testing.expect(!validSpanInlineStyle(bad));
    bad = good; bad.kind = .line_break; try std.testing.expect(!validSpanInlineStyle(bad));
    bad = good; bad.target = "foreign"; try std.testing.expect(!validSpanInlineStyle(bad));
    bad = good; bad.kind = .link; try std.testing.expect(!validSpanInlineStyle(bad));
    bad = good; bad.inline_style.?.font_normalized = true; try std.testing.expect(!validSpanInlineStyle(bad));
    bad = good; bad.inline_style.?.decoration.?.color = "#ABCDEF"; try std.testing.expect(!validSpanInlineStyle(bad));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        bad = good; bad.inline_style.?.line_height = .{ .font_relative = .{ .factor = number, .font = .{} } };
        try std.testing.expect(!validSpanInlineStyle(bad));
        bad = good; bad.inline_style.?.decoration.?.thickness = .{ .unit = .px, .value = number };
        try std.testing.expect(!validSpanInlineStyle(bad));
    }
    bad = good; bad.inline_style.?.line_height = .{ .computed = .{ .value = 1, .font_scale_basis = .context } };
    try std.testing.expect(!validSpanInlineStyle(bad));
    try std.testing.expect(!validInlineFontSnapshot(.{ .font_normalized = true }));
    try std.testing.expect(!validInlineFontSnapshot(.{ .font_scale_basis = .normal_body }));
    try std.testing.expect(!validInlineFontSnapshot(.{ .language = "a\x00b" }));
    try std.testing.expect(!validInlineFontSnapshot(.{ .classes = "\xff" }));
    try std.testing.expect(validInlineTextStyle(.{ .baseline_shift = .{ .value = -1, .font_scale_basis = .css_px } }));
}

test "inline owner JSON context identity matches ordinary Span through Stored roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]FontScaleBasis{ .context, .normal_body }) |basis| {
        const value: Span = .{ .kind = .link, .text = "kept", .target = "Kept", .font_scale = 1, .font_scale_basis = basis,
            .superscript = true, .bold = true, .language = "ja", .classes = "Jpan", .role = .headword,
            .font_features = .seven_on, .explanation = "annotation retained",
            .inline_style = .{ .baseline_shift = .{ .value = 2, .font_scale_basis = .css_px },
                .line_height = .{ .font_relative = .{ .factor = 1, .font = .{ .font_scale = 1, .font_scale_basis = basis,
                    .superscript = true, .bold = true, .language = "ja", .classes = "Jpan", .role = .headword,
                    .font_features = .seven_on } } } } };
        const spans = [_]Span{value};
        const stored: Stored = .{ .entry = .{ .title = "inline", .kind = .supplemental, .preamble_spans = &spans } };
        try validateStored(a, stored, "inline", .supplemental, null);
        const bytes = try std.json.Stringify.valueAlloc(a, stored, .{});
        const parsed = try std.json.parseFromSlice(Stored, a, bytes, .{});
        defer parsed.deinit();
        try validateStored(a, parsed.value, "inline", .supplemental, null);
        var expected = value;
        if (basis == .context) {
            expected.font_scale = null;
            expected.inline_style.?.line_height.?.font_relative.font.font_scale = null;
            try std.testing.expect(std.mem.indexOf(u8, bytes, "\"font_scale\"") == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "\"font_scale\":1") != null);
        }
        try std.testing.expectEqualDeep(expected, parsed.value.entry.preamble_spans[0]);
        try std.testing.expectEqualStrings(bytes, try std.json.Stringify.valueAlloc(a, parsed.value, .{}));
        var inconsistent = parsed.value.entry.preamble_spans[0];
        inconsistent.inline_style.?.line_height.?.font_relative.font.font_scale = 2;
        try std.testing.expect(!validSpanInlineStyle(inconsistent));
    }
    const absent: InlineFontSnapshot = .{};
    const identity: InlineFontSnapshot = .{ .font_scale = 1 };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, absent, .{}),
        try std.json.Stringify.valueAlloc(a, identity, .{}));
}

test "authored Help cursor is explicit range data independent of annotation and action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const plain: Span = .{ .text = "meaning", .explanation = "source title", .tooltip = "source title" };
    try std.testing.expect(plain.inline_style == null);
    const old = try std.json.Stringify.valueAlloc(a, plain, .{});
    try std.testing.expect(std.mem.indexOf(u8, old, "cursor") == null);
    var helped = plain; helped.inline_style = .{ .cursor = .help };
    try std.testing.expect(validSpanInlineStyle(helped));
    const bytes = try std.json.Stringify.valueAlloc(a, helped, .{});
    const parsed = try std.json.parseFromSlice(Span, a, bytes, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(helped, parsed.value);
    const parsed_json = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const from_value = try std.json.parseFromValue(Span, a, parsed_json, .{}); defer from_value.deinit();
    try std.testing.expectEqualDeep(helped, from_value.value);
    helped.kind = .link; helped.target = "Kept";
    try std.testing.expect(validSpanInlineStyle(helped));
    helped.kind = .external_link; helped.target = "https://example.invalid/";
    try std.testing.expect(validSpanInlineStyle(helped));
    helped.target = ""; try std.testing.expect(!validSpanInlineStyle(helped));
    helped = plain; helped.text = "";
    helped.inline_style = .{ .cursor = .help, .line_height = .{ .font_relative = .{ .factor = 1, .font = .{} } } };
    try std.testing.expect(!validSpanInlineStyle(helped));
    helped.inline_style.?.cursor = null; try std.testing.expect(validSpanInlineStyle(helped));
    for ([_][]const u8{ "\"pointer\"", "0", "true", "{}", "\"0\"", "[]" }) |bad| {
        const json = try std.fmt.allocPrint(a, "{{\"cursor\":{s}}}", .{bad});
        if (std.json.parseFromSlice(InlineTextStyle, a, json, .{})) |accepted| {
            accepted.deinit(); return error.TestUnexpectedResult;
        } else |_| {}
        const json_value = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        if (std.json.parseFromValue(InlineTextStyle, a, json_value, .{})) |accepted| {
            accepted.deinit(); return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "nullable body adjoining JSON preserves the old Entry shape and closed ordinary policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: Entry = .{ .title = "body", .kind = .citations };
    const plain = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.indexOf(u8, plain, "body_adjoining") == null);
    const OldEntry = struct {
        organization: Layout = .{}, title: []const u8, display_title: []const Span = &.{}, kind: format.BlobKind,
        language: ?[]const u8 = null, language_code: []const u8 = "", sections: []const Section = &.{},
        preamble_spans: []const Span = &.{}, references: []const Reference = &.{}, media: []const Media = &.{},
        redirect: ?Redirect = null, alias: ?AliasTarget = null,
    };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, OldEntry{ .title = "body", .kind = .citations }, .{}), plain);
    var owned = old; owned.body_adjoining = .ordinary;
    const json = try std.json.Stringify.valueAlloc(a, owned, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"body_adjoining\":\"ordinary\"") != null);
    const decoded = try std.json.parseFromSlice(Entry, a, json, .{}); defer decoded.deinit();
    try std.testing.expectEqualDeep(owned, decoded.value);
    const absent = try std.json.parseFromSlice(Entry, a, "{\"title\":\"body\",\"kind\":\"citations\",\"body_adjoining\":null}", .{}); defer absent.deinit();
    try std.testing.expectEqualDeep(old, absent.value);
    for ([_][]const u8{ "\"normal\"", "\"\"", "true", "0", "{}", "[]" }) |value| {
        const bad = try std.fmt.allocPrint(a, "{{\"title\":\"body\",\"kind\":\"citations\",\"body_adjoining\":{s}}}", .{value});
        if (std.json.parseFromSlice(Entry, a, bad, .{})) |parsed| { parsed.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
}

test "ordered heading font families preserve named order and strict generic distinction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const names = [_][]const u8{ "Linux Libertine", "Georgia", "Times", "Source Serif 4" };
    const policy: ContainerFontFamily = .{ .stack = .{ .names = &names, .fallback = .serif } };
    const json = try std.json.Stringify.valueAlloc(a, policy, .{});
    try std.testing.expectEqualStrings("{\"stack\":{\"names\":[\"Linux Libertine\",\"Georgia\",\"Times\",\"Source Serif 4\"],\"fallback\":\"serif\"}}", json);
    const parsed = try std.json.parseFromSlice(ContainerFontFamily, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(policy, parsed.value);
    try std.testing.expectEqualStrings("\"sans_serif\"", try std.json.Stringify.valueAlloc(a, @as(ContainerFontFamily, .sans_serif), .{}));
    for ([_][]const u8{ "serif", "Serif", "SANS-SERIF", "Sans  Serif", "monospace", "system-ui", "ui-serif", "Times [Foundry]", "Times]", "", " Georgia", "Times\x00", "\xff" }) |name| {
        try std.testing.expect(!validFontFamilyName(name));
        if (!std.unicode.utf8ValidateSlice(name)) continue;
        const bad = try std.fmt.allocPrint(a, "{{\"stack\":{{\"names\":[{s}],\"fallback\":\"serif\"}}}}", .{try std.json.Stringify.valueAlloc(a, name, .{})});
        if (std.json.parseFromSlice(ContainerFontFamily, a, bad, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
    for ([_][]const u8{ "0", "[]", "\"serif\"", "{\"stack\":{\"names\":[],\"fallback\":0}}", "{\"stack\":{\"names\":[],\"fallback\":\"fantasy\"}}", "{\"stack\":{\"names\":[],\"fallback\":\"serif\",\"extra\":0}}" }) |bad| {
        if (std.json.parseFromSlice(ContainerFontFamily, a, bad, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
}
const SectionHeadingStyleTest = struct {
    const zero: StyleLength = .{ .unit = .px, .value = 0 };
    const margins: StyleEdges = .{ .top = .{ .unit = .em, .value = 0.375 }, .right = zero, .bottom = .{ .unit = .em, .value = 0.375 }, .left = zero };
    const padding: StyleEdges = .{ .top = .{ .unit = .em, .value = 0.75 }, .right = zero, .bottom = .{ .unit = .em, .value = 0.255 }, .left = zero };
    const style: SectionHeadingStyle = .{
        .box = .{ .margins = margins, .padding = padding, .border = .none, .owner_font_scale = 1.5,
            .line_height = .{ .multiplier = 1.375 }, .clear = .none,
            .font_family = .{ .stack = .{ .names = &.{ "Linux Libertine", "Georgia", "Times", "Source Serif 4" }, .fallback = .serif } } },
        .font = .{ .font_scale = 1.5, .font_scale_basis = .normal_body, .language = "th" }, .direction = .ltr,
    };
    const section: Section = .{ .level = 2, .title = "Language", .anchor = "Language", .anchor_fallback = "Legacy",
        .heading_style = style, .blocks = &.{
            .{ .kind = .heading, .level = 2, .anchor = "Language", .anchor_fallback = "Legacy", .spans = &.{ .{ .kind = .link, .text = "Lang", .target = "Kept", .target_fragment = "part" }, .{ .text = "uage" } } },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "same body" }} },
        } };
};
test "styled Section headings require one exact companion without changing null Section JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const section = SectionHeadingStyleTest.section;
    try std.testing.expect(validSectionHeadingStyle(section.heading_style.?) and validSectionHeadingCompanion(section));
    try validateStored(a, .{ .entry = .{ .title = "heading", .kind = .citations, .sections = &.{section} } }, "heading", .citations, null);
    const json = try std.json.Stringify.valueAlloc(a, section, .{});
    const parsed = try std.json.parseFromSlice(Section, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(section, parsed.value);
    const old: Section = .{ .level = 2, .title = "legacy" };
    const OldSection = struct { level: u8, title: []const u8, anchor: []const u8 = "", anchor_fallback: []const u8 = "", blocks: []const Block = &.{} };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, OldSection{ .level = 2, .title = "legacy" }, .{}), try std.json.Stringify.valueAlloc(a, old, .{}));
    for (0..7) |mutation| {
        var bad = section; var blocks = [_]Block{section.blocks[0], section.blocks[1]}; bad.blocks = &blocks;
        switch (mutation) {
            0 => bad.level = 3,
            1 => bad.anchor = "different",
            2 => blocks[0].kind = .paragraph,
            3 => blocks[0].spans = &.{.{ .text = "different label" }},
            4 => bad.heading_style.?.font.font_scale = 1,
            5 => blocks[0].spans = &.{.{ .text = "Language", .trail = "s" }},
            6 => blocks[0].spans = &.{ .{ .text = "" }, .{ .text = "Language" } },
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidPresentation, validateStored(a, .{ .entry = .{ .title = "heading", .kind = .citations, .sections = &.{bad} } }, "heading", .citations, null));
    }
}

test "nullable inline family preserves old JSON and independent declaring family identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: Span = .{ .text = "x" };
    try std.testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(a, old, .{}), "font_family") == null);
    try std.testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(a, InlineFontSnapshot{}, .{}), "font_family") == null);
    const names = [_][]const u8{ "Georgia", "Times" };
    const first: ContainerFontFamily = .{ .stack = .{ .names = &names, .fallback = .serif } };
    const copied_names = try a.alloc([]const u8, names.len); for (names, copied_names) |name, *copy| copy.* = try a.dupe(u8, name);
    const copied: ContainerFontFamily = .{ .stack = .{ .names = copied_names, .fallback = .serif } };
    try std.testing.expect(sameFontFamilyRequest(first, copied));
    try std.testing.expect(!sameFontFamilyRequest(first, .sans_serif));
    var shifted: Span = .{ .text = "x", .font_scale = 1.5, .font_scale_basis = .normal_body, .font_family = first,
        .inline_style = .{ .baseline_shift = .{ .value = 0.2, .font_scale_basis = .normal_body },
            .line_height = .{ .font_relative = .{ .factor = 1, .font = .{ .font_scale = 1.5, .font_scale_basis = .normal_body, .font_family = copied } } } } };
    try std.testing.expect(validSpanInlineStyle(shifted));
    shifted.font_family = null; try std.testing.expect(!validSpanInlineStyle(shifted));
    shifted.inline_style.?.baseline_shift = null; // Independent unshifted declaring owner may differ from its child.
    try std.testing.expect(validSpanInlineStyle(shifted));
    const encoded = try std.json.Stringify.valueAlloc(a, shifted, .{});
    const parsed = try std.json.parseFromSlice(Span, a, encoded, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(shifted, parsed.value);
    var heading = SectionHeadingStyleTest.style;
    heading.font.font_family = .sans_serif; try std.testing.expect(!validSectionHeadingStyle(heading));
    heading.font.font_family = heading.box.font_family; try std.testing.expect(validSectionHeadingStyle(heading));
    const body_json = "{\"title\":\"x\",\"kind\":\"citations\",\"body_adjoining\":1}";
    if (std.json.parseFromSlice(Entry, a, body_json, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
    const heading_json = try std.json.Stringify.valueAlloc(a, heading, .{});
    const numeric_direction = try std.mem.replaceOwned(u8, a, heading_json, "\"direction\":\"ltr\"", "\"direction\":0");
    if (std.json.parseFromSlice(SectionHeadingStyle, a, numeric_direction, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
}

test "responsive fixed width Table preserves base geometry and exact optional narrow clear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const base: TableStyle = .{ .float_side = .right, .clear = .right, .width = .{ .unit = .em, .value = 25 },
        .margins = StyleEdges.all(.{ .unit = .em, .value = 0.5 }), .collapse = .collapse };
    var table: Table = .{ .style = base, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part" }} }} }},
        .float_viewport = .{ .max_viewport_width_px = 639, .containing_direction = .ltr, .grid_direction = .ltr, .language = "th", .narrow_clear = .both } };
    try std.testing.expect(validTableFloatViewportHeader(null, table.style, table.float_viewport));
    for ([_]f32{ 0, 638.5, 639, 639.5, 900 }) |viewport| {
        var expected = base;
        if (viewport <= 639) { expected.float_side = null; expected.clear = .both; }
        try std.testing.expectEqualDeep(@as(?TableStyle, expected), try resolveTableFloatStyle(table, viewport));
        try std.testing.expectEqual(@as(f32, 25), table.style.?.width.?.value);
        try std.testing.expectEqualStrings("Kept", table.rows[0].cells[0].spans[0].target);
    }
    const json = try std.json.Stringify.valueAlloc(a, table.float_viewport.?, .{});
    const parsed = try std.json.parseFromSlice(TableFloatViewport, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(table.float_viewport.?, parsed.value);
    table.float_viewport.?.narrow_clear = null;
    const old_json = try std.json.Stringify.valueAlloc(a, table.float_viewport.?, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "narrow_clear") == null);
    var expected = base; expected.float_side = null;
    try std.testing.expectEqualDeep(@as(?TableStyle, expected), try resolveTableFloatStyle(table, 639));
    for ([_][]const u8{ "0", "1", "\"unknown\"", "true" }) |invalid| {
        const bad = try std.fmt.allocPrint(a, "{{\"max_viewport_width_px\":639,\"containing_direction\":\"ltr\",\"grid_direction\":\"ltr\",\"language\":\"th\",\"narrow_clear\":{s}}}", .{invalid});
        if (std.json.parseFromSlice(TableFloatViewport, a, bad, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
    table.style.?.width = .{ .unit = .percent, .value = 80 };
    try std.testing.expect(!validTableFloatViewportHeader(null, table.style, table.float_viewport));
    table.style.?.width = .{ .unit = .px, .value = 400 };
    try std.testing.expect(validTableFloatViewportHeader(null, table.style, table.float_viewport));
}

test "authored heading companion supports generic build defaults without lending ownership to legacy shapes" {
    const LegacySection = struct { level: u8 = 2, title: []const u8 = "legacy", blocks: []const Block = &.{} };
    try std.testing.expect(!validSectionHeadingCompanion(LegacySection{}));
    const BuildSpan = struct { kind: enum { text, link } = .text, text: []const u8 };
    const BuildBlock = struct {
        kind: enum { paragraph, heading } = .heading, depth: u8 = 0, level: u8 = 2,
        anchor: []const u8 = "anchor", anchor_fallback: []const u8 = "fallback",
        list_path: []const u8 = "", number: []const u8 = "", feature: ?Feature = null, table: ?Table = null,
        spans: []const BuildSpan,
    };
    const BuildSection = struct {
        level: u8 = 2, title: []const u8 = "Heading", anchor: []const u8 = "anchor", anchor_fallback: []const u8 = "fallback",
        heading_style: ?SectionHeadingStyle = SectionHeadingStyleTest.style, blocks: []const BuildBlock,
    };
    const spans = [_]BuildSpan{.{ .text = "Heading" }};
    var block = [_]BuildBlock{.{ .spans = &spans }};
    var section: BuildSection = .{ .blocks = &block };
    try std.testing.expect(validSectionHeadingCompanion(section));
    section.anchor = "different"; try std.testing.expect(!validSectionHeadingCompanion(section));
    section.anchor = "anchor"; block[0].kind = .paragraph;
    try std.testing.expect(!validSectionHeadingCompanion(section));
    const TableOnly = struct { kind: enum { table } = .table, depth: u8 = 0, level: u8 = 2,
        anchor: []const u8 = "anchor", anchor_fallback: []const u8 = "fallback", list_path: []const u8 = "", number: []const u8 = "",
        feature: ?Feature = null, table: ?Table = null, spans: []const BuildSpan = &.{} };
    const OtherSection = struct { level: u8 = 2, title: []const u8 = "Heading", anchor: []const u8 = "anchor",
        anchor_fallback: []const u8 = "fallback", heading_style: ?SectionHeadingStyle = SectionHeadingStyleTest.style,
        blocks: []const TableOnly = &.{} };
    try std.testing.expect(!validSectionHeadingCompanion(OtherSection{ .blocks = &.{.{ .spans = &spans }} }));
    const NoAnchors = struct { level: u8 = 2, title: []const u8 = "Heading",
        heading_style: ?SectionHeadingStyle = SectionHeadingStyleTest.style, blocks: []const BuildBlock };
    block[0].kind = .heading; block[0].anchor = ""; block[0].anchor_fallback = "";
    try std.testing.expect(validSectionHeadingCompanion(NoAnchors{ .blocks = &block }));
    block[0].anchor = "unexpected";
    try std.testing.expect(!validSectionHeadingCompanion(NoAnchors{ .blocks = &block }));
    // Fully typed data retains the exact strict companion and trail policy.
    try std.testing.expect(validSectionHeadingCompanion(SectionHeadingStyleTest.section));
    var typed = SectionHeadingStyleTest.section;
    var typed_blocks = [_]Block{typed.blocks[0]}; typed.blocks = &typed_blocks;
    typed_blocks[0].spans = &.{.{ .text = "Language", .trail = "s" }};
    try std.testing.expect(!validSectionHeadingCompanion(typed));
}

const BlockMediaModelFixture = struct {
    fn layout() FigureBlockMediaLayout {
        return .{ .wrapper = .{ .width = .auto, .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }),
            .line_height = .{ .multiplier = 1.5 }, .text_align = .left, .owner_font_scale = 1 },
            .media = .{ .strut = .{ .font_scale = 1, .direction = .ltr }, .vertical_align = .middle,
                .max_width = .{ .percent = 100, .subtract = .{ .unit = .px, .value = 0 } } },
            .preferred_width_px = 44, .natural_width = 120, .natural_height = 110,
            .rendition_1x = .{ .url = "https://example.test/controlled-1x.png", .sha256 = "1111111111111111111111111111111111111111111111111111111111111111" },
            .rendition_2x = .{ .url = "https://example.test/controlled-2x.png", .sha256 = "2222222222222222222222222222222222222222222222222222222222222222" } };
    }
    fn figure() Figure {
        var value = TableCaptionModelFixture.figure();
        value.table_caption_layout = null; value.block_media_layout = layout();
        value.placement = .none; value.clear = .none;
        value.margins = StyleEdges.all(.{ .unit = .px, .value = 0 });
        value.image_insets = value.margins; value.caption_padding = value.margins;
        value.frame_background = .{ .kind = .transparent }; value.image_background = .{ .kind = .transparent };
        value.caption_background = .{ .kind = .transparent };
        value.content.image.span = .{ .kind = .text, .image = .{ .file = "controlled-block.svg", .width_px = 44, .height_px = 40, .alt = "controlled" } };
        return value;
    }
};

test "Figure block media retains explicit nonzero line state rendition aspect and legacy absent JSON" {
    const a = std.testing.allocator;
    var value = BlockMediaModelFixture.figure();
    var narrow = value.block_media_layout.?.wrapper;
    narrow.line_height = .{ .length = .{ .unit = .px, .value = 24 } };
    narrow.text_align = .center;
    const zero: ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    narrow.margins = null; narrow.margin_values = .{ .top = zero, .right = .auto, .bottom = zero, .left = .auto };
    const states = [_]FigureBlockMediaState{.{ .max_width_px = 639, .wrapper = narrow, .media = value.block_media_layout.?.media }};
    value.block_media_layout.?.viewport_states = &states;
    try std.testing.expect(validFigure(value));
    try std.testing.expect((try resolveFigureBlockMediaState(value.block_media_layout.?, 640)) == null);
    const selected = (try resolveFigureBlockMediaState(value.block_media_layout.?, 639)).?;
    try std.testing.expectEqualDeep(narrow, selected.wrapper);
    try std.testing.expectEqual(@as(f32, 24), selected.wrapper.line_height.?.length.value);
    const encoded = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(encoded);
    const decoded = try std.json.parseFromSlice(Figure, a, encoded, .{}); defer decoded.deinit();
    try std.testing.expectEqualDeep(value, decoded.value);
    try std.testing.expectEqual(@as(u32, 120), decoded.value.block_media_layout.?.natural_width);
    try std.testing.expectEqual(@as(u32, 110), decoded.value.block_media_layout.?.natural_height);
    value.block_media_layout = null;
    const legacy = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "block_media_layout") == null);
}

test "Figure block media refuses table mixing missing caption link and incomplete line authority" {
    const value = BlockMediaModelFixture.figure();
    try std.testing.expect(validFigure(value));
    var bad = value; bad.table_caption_layout = TableCaptionModelFixture.layout(); try std.testing.expect(!validFigure(bad));
    bad = value; bad.caption = &.{.{ .text = "not hidden" }}; try std.testing.expect(!validFigure(bad));
    bad = value; bad.caption_blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "not hidden" }} }}; try std.testing.expect(!validFigure(bad));
    bad = value; bad.content.image.span.kind = .link; bad.content.image.span.target = "File:controlled-block.svg"; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.natural_height = 0; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.preferred_width_px = 0; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.wrapper.line_height = null; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.wrapper.line_height = .{ .multiplier = std.math.nan(f32) }; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.wrapper.owner_font_scale = 1.2; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.wrapper.width = .fit_content; try std.testing.expect(!validFigure(bad));
    bad = value; bad.block_media_layout.?.wrapper.layout = .flex_row; try std.testing.expect(!validFigure(bad));
    bad = value; bad.image_insets.left.value = 1; try std.testing.expect(!validFigure(bad));
    const state: FigureBlockMediaState = .{ .max_width_px = 639, .wrapper = value.block_media_layout.?.wrapper, .media = value.block_media_layout.?.media };
    bad = value; bad.block_media_layout.?.viewport_states = &.{state, state}; try std.testing.expect(!validFigure(bad));
    try std.testing.expectError(error.InvalidPresentation, resolveFigureBlockMediaState(value.block_media_layout.?, std.math.inf(f64)));
}

test "Figure block raster identity requires two distinct HTTPS hash-bound density resources" {
    const good = BlockMediaModelFixture.figure();
    try std.testing.expect(validFigure(good));
    for ([_][]const u8{ "", "http://example.test/a.png", "https://user@example.test/a.png", "https://example.test/a.png#x", "https://example.test/a.png\n" }) |url| {
        var bad = good; bad.block_media_layout.?.rendition_1x.url = url; try std.testing.expect(!validFigure(bad));
    }
    for ([_][]const u8{ "", "00", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }) |hash| {
        var bad = good; bad.block_media_layout.?.rendition_1x.sha256 = hash; try std.testing.expect(!validFigure(bad));
    }
    var bad = good; bad.block_media_layout.?.rendition_2x = bad.block_media_layout.?.rendition_1x; try std.testing.expect(!validFigure(bad));
    bad = good; bad.block_media_layout.?.natural_width = std.math.maxInt(u32); try std.testing.expect(!validFigure(bad));
}

const PairedTableScrollTest = struct {
    fn block() TableBlockViewport {
        return .{ .max_viewport_width_px = 639, .box_style = .{
            .margins = StyleEdges.all(.{ .unit = .em, .value = 0 }), .clear = .right,
            .padding = StyleEdges.all(.{ .unit = .px, .value = 0 }),
        }, .box_sizing = .border_box, .max_width = .{ .unit = .percent, .value = 100 },
            .grid_style = .{ .collapse = .collapse }, .grid_direction = .ltr, .language = "de", .focus_paint = .{ .mode = .ua_auto, .color = .{ .kind = .rgb, .value = "#3366cc" } } };
    }
    fn table(narrow: *const TableBlockViewport) Table {
        return .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part" }} }} }},
            .style = .{ .float_side = .right, .margins = StyleEdges.all(.{ .unit = .em, .value = 0.4 }), .collapse = .collapse, .clear = .right },
            .float_viewport = .{ .max_viewport_width_px = 639, .containing_direction = .rtl, .grid_direction = .ltr, .language = "de" }, .block_viewport = narrow };
    }
};
test "paired Table float and scroll states share body actions and exact CSS breakpoint" {
    const a = std.testing.allocator;
    const block = PairedTableScrollTest.block(); const table = PairedTableScrollTest.table(&block);
    try std.testing.expect(validTableViewportHeaders(null, table.style, table.block_viewport, table.float_viewport));
    try std.testing.expect(!validTableBlockViewport(block));
    for ([_]f32{ 1000, 639, 639.5, 0, 640, 638.75, 1000 }) |width| {
        const selected = try resolveTableBlockViewport(table, width);
        const style = (try resolveTableFloatStyle(table, width)).?;
        if (width <= 639) {
            try std.testing.expect(selected == &block and style.float_side == null and style.width == null);
            try std.testing.expectEqualDeep(block.box_style, style);
        } else {
            try std.testing.expect(selected == null);
            try std.testing.expectEqualDeep(table.style.?, style);
        }
        try std.testing.expectEqualStrings("Kept", table.rows[0].cells[0].spans[0].target);
        try std.testing.expect(table.rows[0].cells[0].spans[0].target_fragment != null);
        try std.testing.expectEqualStrings("part", table.rows[0].cells[0].spans[0].target_fragment.?);
    }
    const json = try std.json.Stringify.valueAlloc(a, table, .{}); defer a.free(json);
    const decoded = try std.json.parseFromSlice(Table, a, json, .{}); defer decoded.deinit();
    try std.testing.expectEqualDeep(table, decoded.value);
}
test "paired Table viewport refuses unmatched state geometry width and margin interpretations" {
    const good = PairedTableScrollTest.block();
    for (0..15) |mutation| {
        var block = good; var table = PairedTableScrollTest.table(&block);
        switch (mutation) {
            0 => block.max_viewport_width_px = 638,
            1 => table.float_viewport.?.max_viewport_width_px = 0,
            2 => block.language = "fr",
            3 => block.grid_direction = .rtl,
            4 => table.float_viewport.?.narrow_clear = .none,
            5 => block.box_style.width = .{ .unit = .px, .value = 200 },
            6 => block.box_style.margin_values = .{ .top = .{ .length = .{ .unit = .px, .value = 0 } }, .right = .auto, .bottom = .{ .length = .{ .unit = .px, .value = 0 } }, .left = .auto },
            7 => block.box_style.margins = null,
            8 => table.geometry = .{ .border = 0 },
            9 => table.style.?.float_side = .left,
            10 => block.grid_style.background = "#ffffff",
            11 => block.max_width.value = std.math.nan(f32),
            12 => block.focus_paint = null,
            13 => block.focus_paint.?.mode = .authored_none,
            14 => block.focus_paint.?.color = .{ .kind = .rgb, .value = "invalid" },
            else => unreachable,
        }
        try std.testing.expect(!validTableViewportHeaders(table.geometry, table.style, table.block_viewport, table.float_viewport));
        try std.testing.expectError(error.InvalidPresentation, resolveTableBlockViewport(table, 639));
        try std.testing.expectError(error.InvalidPresentation, resolveTableFloatStyle(table, 640));
    }
    const table = PairedTableScrollTest.table(&good);
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |width| {
        try std.testing.expectError(error.InvalidPresentation, resolveTableBlockViewport(table, width));
        try std.testing.expectError(error.InvalidPresentation, resolveTableFloatStyle(table, width));
    }
}

test "paired scroll focus preserves authored none versus native auto and closed JSON domain" {
    const a = std.testing.allocator;
    const none: TableScrollFocusPaint = .{ .mode = .authored_none };
    try std.testing.expect(validTableScrollFocusPaint(none));
    var policy = PairedTableScrollTest.block(); policy.focus_paint = none;
    try std.testing.expect(validTableScrollViewport(policy));
    const old = TableBlockViewportTypeTest.policy();
    const old_json = try std.json.Stringify.valueAlloc(a, old, .{}); defer a.free(old_json);
    try std.testing.expect(std.mem.indexOf(u8, old_json, "focus_paint") == null);
    for ([_][]const u8{ "{\"mode\":0}", "{\"mode\":\"auto\"}", "{\"mode\":\"ua_auto\",\"width\":2}",
        "{\"mode\":\"authored_none\",\"color\":{\"kind\":\"rgb\",\"value\":\"#3366cc\"}}", "{\"mode\":\"ua_auto\",\"mode\":\"ua_auto\"}" }) |invalid| {
        if (std.json.parseFromSlice(TableScrollFocusPaint, a, invalid, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
}

test "cell metric owner requires one complete font tuple and one size authority" {
    const owner: InlineFontSnapshot = .{ .font_scale = 1.1, .font_scale_basis = .normal_body,
        .bold = true, .language = "th", .font_features = .seven_on, .font_family = .sans_serif };
    const value: CellLineHeight = .{ .strut = .{ .font_scale = 1.1, .font_scale_basis = .normal_body, .owner_font = owner }, .height = .normal };
    try std.testing.expect(validCellLineHeight(value));
    for ([_]FontScaleBasis{ .normal_body, .css_px }) |basis| for ([_]f32{ 0, 1, 1.1, 22 }) |size| {
        var next = value; next.strut.?.font_scale = size; next.strut.?.font_scale_basis = basis;
        next.strut.?.owner_font.?.font_scale = size; next.strut.?.owner_font.?.font_scale_basis = basis;
        next.height = .{ .length = .{ .value = 0, .font_scale_basis = basis } };
        try std.testing.expect(validCellLineHeight(next));
    };
    for (0..18) |mode| {
        var bad = value; const font = &bad.strut.?.owner_font.?;
        switch (mode) {
            0 => font.font_scale = null,
            1 => font.font_scale = 1.2,
            2 => font.font_scale_basis = .css_px,
            3 => font.font_family = null,
            4 => font.font_features = null,
            5 => font.language = "",
            6 => font.language = "th\x00",
            7 => font.language = "\xff",
            8 => font.small = true,
            9 => font.superscript = true,
            10 => font.subscript = true,
            11 => font.font_normalized = true,
            12 => font.code = true,
            13 => font.classes = "Hani",
            14 => font.role = .headword,
            15 => font.font_family = .{ .stack = .{ .names = &.{"bad\x00family"}, .fallback = .sans_serif } },
            16 => { bad.strut.?.font_scale = std.math.nan(f32); font.font_scale = std.math.nan(f32); },
            17 => { bad.strut.?.font_scale_basis = .context; font.font_scale_basis = .context; },
            else => unreachable,
        }
        try std.testing.expect(!validCellLineHeight(bad));
    }
    var long = value;
    var language: [1025]u8 = undefined; @memset(&language, 'a');
    long.strut.?.owner_font.?.language = &language;
    try std.testing.expect(!validCellLineHeight(long));
}

test "cell metric owner JSON preserves legacy absence and independent painted child fonts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: CellTextStrut = .{ .font_scale = 1, .font_scale_basis = .normal_body };
    const old_json = try std.json.Stringify.valueAlloc(a, old, .{});
    const old_shape = struct { font_scale: f32, font_scale_basis: FontScaleBasis }{ .font_scale = 1, .font_scale_basis = .normal_body };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, old_shape, .{}), old_json);
    const legacy = try std.json.parseFromSlice(CellTextStrut, a, old_json, .{}); defer legacy.deinit();
    try std.testing.expectEqualDeep(old, legacy.value);
    const cell: Cell = .{ .style = .{ .line_height = .{ .strut = .{ .font_scale = 1.1, .font_scale_basis = .normal_body,
        .owner_font = .{ .font_scale = 1.1, .font_scale_basis = .normal_body, .bold = true, .language = "th",
            .font_features = .seven_on, .font_family = .{ .stack = .{ .names = &.{"Owner Face"}, .fallback = .sans_serif } } } }, .height = .{ .multiplier = 1.25 } } },
        .spans = &.{.{ .kind = .link, .text = "child", .target = "Kept", .trail = "s", .font_scale = 0.8,
            .font_scale_basis = .normal_body, .italic = true, .language = "en" }} };
    const json = try std.json.Stringify.valueAlloc(a, cell, .{});
    const parsed = try std.json.parseFromSlice(Cell, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(cell, parsed.value);
    try std.testing.expect(validCellStyle(parsed.value.style.?));
    try std.testing.expect(!parsed.value.spans[0].bold and parsed.value.spans[0].font_family == null);
    try std.testing.expectEqualStrings("Kept", parsed.value.spans[0].target);
    const raw = try std.json.parseFromSlice(std.json.Value, a, json, .{}); defer raw.deinit();
    const from_value = try std.json.parseFromValue(Cell, a, raw.value, .{}); defer from_value.deinit();
    try std.testing.expectEqualDeep(cell, from_value.value);
}


test "Table corners keep physical px ownership uniform border and exact null JSON" {
    const px = StyleLength{ .unit = .px, .value = 8 };
    const corners: TableCornerRadii = .{ .top_left = px, .top_right = px,
        .bottom_right = px, .bottom_left = .{ .unit = .px, .value = 0 } };
    var style: TableStyle = .{ .collapse = .separate, .border = .none, .corner_radii = corners };
    try std.testing.expect(validTableStyle(style));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32), 16777218 }) |number| {
        var invalid = corners; invalid.top_right.value = number;
        try std.testing.expect(!validTableCornerRadii(invalid));
    }
    var wrong_unit = corners; wrong_unit.bottom_left.unit = .em;
    try std.testing.expect(!validTableCornerRadii(wrong_unit));
    var boundary = corners; boundary.top_left.value = 16777216;
    try std.testing.expect(validTableCornerRadii(boundary));
    style.collapse = .collapse; try std.testing.expect(!validTableStyle(style));
    style.collapse = .separate; style.border = null; try std.testing.expect(!validTableStyle(style));
    style.border = .{ .edges = StyleBorderEdges.all(.none) }; try std.testing.expect(!validTableStyle(style));
    style.border = .none; style.display = .inline_block; try std.testing.expect(!validTableStyle(style));
    style.display = null;
    const a = std.testing.allocator;
    const encoded = try std.json.Stringify.valueAlloc(a, style, .{}); defer a.free(encoded);
    const parsed = try std.json.parseFromSlice(TableStyle, a, encoded, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(style, parsed.value);
    const legacy = try std.json.Stringify.valueAlloc(a, TableStyle{ .border = .none }, .{}); defer a.free(legacy);
    try std.testing.expectEqualStrings("{\"border\":{\"none\":{}}}", legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "corner_radii") == null);
    const legacy_parsed = try std.json.parseFromSlice(TableStyle, a, legacy, .{}); defer legacy_parsed.deinit();
    try std.testing.expectEqualDeep(TableStyle{ .border = .none }, legacy_parsed.value);
}

test "explicit inline image middle is nullable strict data separate from static poster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const old: InlineImage = .{ .file = "Map.svg", .width_px = 600 };
    const old_json = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.indexOf(u8, old_json, "vertical_align") == null);
    var image = old; image.vertical_align = .middle;
    try std.testing.expect(validInlineImage(image));
    try std.testing.expect(inlineTableSpanSupportedM(Span{ .image = old }));
    try std.testing.expect(!inlineTableSpanSupportedM(Span{ .image = image }));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(InlineImageVerticalAlign.middle));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(InlineImageVerticalAlign.baseline));
    var baseline = image; baseline.vertical_align = .baseline;
    try std.testing.expect(validInlineImage(baseline));
    const baseline_json = try std.json.Stringify.valueAlloc(a, baseline, .{});
    const baseline_parsed = try std.json.parseFromSlice(InlineImage, a, baseline_json, .{}); defer baseline_parsed.deinit();
    try std.testing.expectEqualDeep(baseline, baseline_parsed.value);
    const json = try std.json.Stringify.valueAlloc(a, image, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"vertical_align\":\"middle\"") != null);
    const parsed = try std.json.parseFromSlice(InlineImage, a, json, .{});
    try std.testing.expectEqualDeep(image, parsed.value);
    for ([_][]const u8{ "\"top\"", "\"MIDDLE\"", "0", "{}", "[]" }) |bad| {
        const input = try std.fmt.allocPrint(a, "{{\"file\":\"Map.svg\",\"vertical_align\":{s}}}", .{bad});
        if (std.json.parseFromSlice(InlineImage, a, input, .{})) |_| return error.TestUnexpectedResult else |_| {}
        const value = try std.json.parseFromSlice(std.json.Value, a, input, .{});
        if (std.json.parseFromValue(InlineImage, a, value.value, .{})) |_| return error.TestUnexpectedResult else |_| {}
    }
    var poster: InlineImage = .{ .file = "Model.stl", .width_px = 4, .height_px = 3, .vertical_align = .middle,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "3D", .file_sha1 = "832cafd6c58519ddd441e8f7fc7d78eb14165a2e", .file_timestamp = "2020-07-25T07:26:20Z" } };
    try std.testing.expect(!validInlineImage(poster));
    poster.vertical_align = null; try std.testing.expect(validInlineImage(poster));
}

const IntrinsicTableViewportTest = struct {
    fn policy() TableBlockViewport {
        return .{ .max_viewport_width_px = 639,
            .box_style = .{ .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aaaaaa" } },
                .margins = StyleEdges.all(.{ .unit = .px, .value = 0 }) },
            .box_sizing = .border_box, .max_width = .{ .unit = .percent, .value = 100 },
            .grid_style = .{ .collapse = .collapse }, .grid_direction = .ltr, .language = "ku",
            .focus_paint = .{ .mode = .ua_auto }, .intrinsic_containing_direction = .rtl };
    }
    fn table(policy_value: *const TableBlockViewport) Table {
        var wide = policy_value.box_style; wide.collapse = .collapse;
        return .{ .geometry = .{ .border = 1, .cell_padding = 4, .cell_spacing = 0 }, .style = wide,
            .block_viewport = policy_value, .rows = &.{.{ .cells = &.{.{ .spans = &.{
                .{ .kind = .link, .text = "kept", .target = "Kept", .target_fragment = "part" },
            } }} }} };
    }
};

test "intrinsic nonfloating Table owns containing direction and exact narrow breakpoint" {
    const F = IntrinsicTableViewportTest; const policy = F.policy(); const value = F.table(&policy);
    try std.testing.expect(validTableViewportHeaders(value.geometry, value.style, value.block_viewport, value.float_viewport));
    try std.testing.expectEqual(@as(?*const TableBlockViewport, &policy), try resolveTableBlockViewport(value, 639));
    try std.testing.expectEqual(@as(?*const TableBlockViewport, null), try resolveTableBlockViewport(value, 639.5));
    try std.testing.expectEqual(@as(?TableFloatViewport, null), value.float_viewport);
    try std.testing.expectEqual(@as(?TableContainingDirection, .rtl), policy.intrinsic_containing_direction);
    try std.testing.expectEqual(TableContainingDirection.ltr, policy.grid_direction);
    try std.testing.expect(!validTableBlockViewport(policy));
    try std.testing.expect(!validTableScrollViewport(policy));
    try std.testing.expect(!validTableCornerBlockViewport(policy));
    try std.testing.expectEqual(@as(?u16, 4), value.geometry.?.cell_padding);
    try std.testing.expectEqualStrings("part", value.rows[0].cells[0].spans[0].target_fragment.?);
    try std.testing.expectError(error.InvalidPresentation, resolveTableBlockViewport(value, std.math.nan(f32)));
}

test "intrinsic Table rejects missing hints float pairing fabricated widths and missing focus" {
    const F = IntrinsicTableViewportTest;
    for (0..12) |mode| {
        var policy = F.policy(); var value = F.table(&policy);
        switch (mode) {
            0 => policy.intrinsic_containing_direction = null,
            1 => value.geometry = null,
            2 => value.geometry.?.border = null,
            3 => value.geometry.?.cell_padding = null,
            4 => value.geometry.?.cell_spacing = null,
            5 => value.geometry.?.width = .{ .unit = .percent, .value = 100 },
            6 => value.style.?.width = .{ .unit = .percent, .value = 100 },
            7 => policy.box_style.width = .{ .unit = .px, .value = 100 },
            8 => policy.focus_paint = null,
            9 => policy.max_width.value = 90,
            10 => value.float_viewport = .{ .max_viewport_width_px = 639, .containing_direction = .rtl, .grid_direction = .ltr, .language = "ku" },
            11 => policy.box_style.containing_direction = .rtl,
            else => unreachable,
        }
        try std.testing.expect(!validTableViewportHeaders(value.geometry, value.style, value.block_viewport, value.float_viewport));
    }
}

test "intrinsic viewport JSON preserves null legacy bytes and rejects discriminator confusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const policy = IntrinsicTableViewportTest.policy();
    const json = try std.json.Stringify.valueAlloc(a, policy, .{});
    const parsed = try std.json.parseFromSlice(TableBlockViewport, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(policy, parsed.value);
    var legacy = policy; legacy.intrinsic_containing_direction = null;
    const old = try std.json.Stringify.valueAlloc(a, legacy, .{});
    try std.testing.expect(std.mem.indexOf(u8, old, "intrinsic_containing_direction") == null);
    for ([_][]const u8{ "true", "123", "\"unknown\"" }) |bad| {
        const forged = try std.fmt.allocPrint(a, "{s},\"intrinsic_containing_direction\":{s}}}", .{old[0..old.len - 1], bad});
        const invalid = std.json.parseFromSlice(TableBlockViewport, a, forged, .{ .ignore_unknown_fields = true });
        if (invalid) |accepted| { accepted.deinit(); return error.TestUnexpectedResult; } else |_| {}
    }
    const duplicate = try std.fmt.allocPrint(a, "{s},\"intrinsic_containing_direction\":\"ltr\"}}", .{json[0..json.len - 1]});
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSlice(TableBlockViewport, a, duplicate, .{}));
}

test "Rule clearance preserves legacy JSON and validates the original Rule context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: StyleLength = .{ .unit = .px, .value = 0 };
    const style: RuleStyle = .{ .height = .{ .unit = .px, .value = 1 }, .fill = .{ .rgb = "#a2a9b1" },
        .margins = .{ .top = zero, .right = zero, .bottom = zero, .left = zero } };
    const legacy = try std.json.Stringify.valueAlloc(a, style, .{});
    const old_shape = .{ .height = style.height, .fill = style.fill, .margins = style.margins };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, old_shape, .{}), legacy);
    const parsed = try std.json.parseFromSliceLeaky(RuleStyle, a, legacy, .{});
    try std.testing.expectEqualDeep(style, parsed);
    const null_json = try std.fmt.allocPrint(a, "{s},\"clear\":null}}", .{legacy[0..legacy.len - 1]});
    for ([_][]const u8{ legacy, null_json }) |json| {
        try std.testing.expectEqualDeep(style, try std.json.parseFromSliceLeaky(RuleStyle, a, json, .{}));
        const tree = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        try std.testing.expectEqualDeep(style, try std.json.parseFromValueLeaky(RuleStyle, a, tree, .{}));
    }
    inline for (comptime std.meta.tags(FigureClear)) |clear| {
        var explicit = style; explicit.clear = clear;
        try std.testing.expect(validRuleStyle(explicit));
        var block: Block = .{ .kind = .rule, .rule_style = explicit };
        try std.testing.expect(validRuleStyleContext(block));
        const bytes = try std.json.Stringify.valueAlloc(a, explicit, .{});
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"clear\":") != null);
        try std.testing.expectEqualDeep(explicit, try std.json.parseFromSliceLeaky(RuleStyle, a, bytes, .{}));
        const tree = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
        try std.testing.expectEqualDeep(explicit, try std.json.parseFromValueLeaky(RuleStyle, a, tree, .{}));
        block.spans = &.{.{ .kind = .text, .text = "unowned" }};
        try std.testing.expect(!validRuleStyleContext(block));
        block.spans = &.{}; block.kind = .paragraph;
        try std.testing.expect(!validRuleStyleContext(block));
    }
    for ([_][]const u8{ "0", "1", "2", "3", "4", "true", "false", "0.0", "1.5", "{}", "[]",
        "\"inline-start\"", "\"RIGHT\"", "\"right \"", "\"0\"", "\"\"" }) |value| {
        const bytes = try std.fmt.allocPrint(a, "{s},\"clear\":{s}}}", .{ legacy[0..legacy.len - 1], value });
        const outcome = std.json.parseFromSliceLeaky(RuleStyle, a, bytes, .{});
        if (outcome) |_| return error.TestUnexpectedResult else |_| {}
        const tree = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
        const from_value = std.json.parseFromValueLeaky(RuleStyle, a, tree, .{});
        if (from_value) |_| return error.TestUnexpectedResult else |_| {}
    }
    const duplicate = try std.fmt.allocPrint(a, "{s},\"clear\":\"right\",\"clear\":\"left\"}}", .{legacy[0..legacy.len - 1]});
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSliceLeaky(RuleStyle, a, duplicate, .{}));
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSliceLeaky(RuleStyle, a, duplicate, .{ .duplicate_field_behavior = .use_last }));
    // A Value object has unique keys. Its input parser must reject duplicate
    // fields before conversion; discarded duplicate spelling cannot be recovered.
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSliceLeaky(std.json.Value, a, duplicate, .{}));
    const unknown = try std.fmt.allocPrint(a, "{s},\"unknown_clear\":\"right\"}}", .{legacy[0..legacy.len - 1]});
    try std.testing.expectError(error.UnknownField, std.json.parseFromSliceLeaky(RuleStyle, a, unknown, .{ .ignore_unknown_fields = true }));
    const unknown_tree = try std.json.parseFromSliceLeaky(std.json.Value, a, unknown, .{});
    try std.testing.expectError(error.UnknownField, std.json.parseFromValueLeaky(RuleStyle, a, unknown_tree, .{ .ignore_unknown_fields = true }));
}


test "R image action paint retains three focus modes and refuses unproved glyph owners" {
    const paint = OrdinaryLinkPaintModelTesting.paint();
    var span: Span = .{ .kind = .link, .target = "File:Arrow.png", .image = .{ .file = "Arrow.png", .width_px = 30 } };
    try std.testing.expect(validSpanLinkPaint(span));
    span.link_paint = paint;
    try std.testing.expect(validSpanLinkPaint(span));
    try std.testing.expect(span.link_paint.?.focus_outline == null);
    span.link_paint.?.focus_outline = .{ .width = .{ .unit = .px, .value = 2 },
        .color = .{ .kind = .rgb, .value = "#3366cc" }, .radius = .{ .unit = .px, .value = 0 },
        .offset = .{ .unit = .px, .value = 1 } };
    try std.testing.expect(validSpanLinkPaint(span));
    var external = span; external.kind = .external_link; external.target = "https://example.test/image";
    try std.testing.expect(validSpanLinkPaint(external));
    var empty_alt = span; empty_alt.image.?.alt = "";
    try std.testing.expect(validSpanLinkPaint(empty_alt));
    for (0..10) |mode| {
        var bad = span;
        switch (mode) {
            0 => bad.text = "visible glyph",
            1 => bad.trail = "s",
            2 => bad.image.?.alt = "authored fallback",
            3 => bad.image.?.map = .{ .description = .bottom_right, .regions = &.{.{ .shape = .rectangle, .coordinates = &.{0,0,10,10}, .action = .{ .kind = .internal, .target = "Region", .label = "region" } }} },
            4 => {
                bad.image.?.file = "Model.stl"; bad.image.?.height_px = staticPosterHeight(30);
                bad.image.?.static_poster = .{ .policy = .three_d_stl_v1, .label = "poster",
                    .file_sha1 = "0123456789012345678901234567890123456789", .file_timestamp = "2026-01-01T00:00:00Z" };
            },
            5 => bad.target = "",
            6 => bad.kind = .text,
            7 => bad.foreground = "#ffffff",
            8 => bad.underline = true,
            9 => bad.link_paint.?.focus_outline.?.color = .{ .kind = .native_theme },
            else => unreachable,
        }
        if (mode == 3 or mode == 4) try std.testing.expect(validInlineImage(bad.image.?));
        try std.testing.expect(!validSpanLinkPaint(bad));
    }
    const a = std.testing.allocator;
    for ([_]?LinkPaint{ null, paint, span.link_paint }) |policy| {
        var source = span; source.link_paint = policy;
        const json = try std.json.Stringify.valueAlloc(a, source, .{}); defer a.free(json);
        const parsed = try std.json.parseFromSlice(Span, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqualDeep(source, parsed.value);
        try std.testing.expect(validSpanLinkPaint(parsed.value));
    }
    // The legacy nonempty text-plus-image negative remains an actual refusal.
    var legacy = span; legacy.text = "kept";
    try std.testing.expect(!validSpanLinkPaint(legacy));
}


test "R Figure image paint and media outline have one authority in every viewport" {
    var paint = OrdinaryLinkPaintModelTesting.paint();
    const outline = TableCaptionModelFixture.richMedia().focus_outline.?;
    for ([_]bool{ false, true }) |outlined| {
        paint.focus_outline = if (outlined) outline else null;
        var image_owner = TableCaptionModelFixture.figure();
        image_owner.content.image.span.link_paint = paint;
        try std.testing.expect(validFigure(image_owner));
        try std.testing.expect(validSpanLinkPaint(image_owner.content.image.span));
        var base_conflict = image_owner;
        base_conflict.table_caption_layout.?.media.focus_outline = outline;
        try std.testing.expect(!validFigure(base_conflict));
        var base_only = base_conflict; base_only.content.image.span.link_paint = null;
        try std.testing.expect(validFigure(base_only));
        var media = image_owner.table_caption_layout.?.media; media.focus_outline = outline;
        var viewport_conflict = image_owner;
        viewport_conflict.table_caption_layout.?.viewport_states = &.{.{ .max_width_px = 639, .wrapper = .{}, .media = media }};
        try std.testing.expect(!validFigure(viewport_conflict));
        var viewport_only = viewport_conflict; viewport_only.content.image.span.link_paint = null;
        try std.testing.expect(validFigure(viewport_only));
        media.focus_outline = null;
        image_owner.table_caption_layout.?.viewport_states = &.{.{ .max_width_px = 639, .wrapper = .{}, .media = media }};
        try std.testing.expect(validFigure(image_owner));
        // A caption image is a distinct action owner, not the Figure's media.
        base_only.caption = &.{image_owner.content.image.span};
        try std.testing.expect(validFigure(base_only));
    }
}

test "typed text flow preserves legacy JSON and requires named wrap values through both parsers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const OldInline = struct { decoration: ?InlineUnderline = null, line_height: ?InlineLineHeight = null,
        baseline_shift: ?ComputedLineHeight = null, font_normalized: bool = false, cursor: ?InlineCursor = null };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, OldInline{ .cursor = .help }, .{}),
        try std.json.Stringify.valueAlloc(a, InlineTextStyle{ .cursor = .help }, .{}));
    const old_heading = SectionHeadingStyleTest.style;
    const OldHeading = struct { box: ContainerStyle, font: InlineFontSnapshot, direction: BidiResolvedDirection };
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, OldHeading{
        .box = old_heading.box, .font = old_heading.font, .direction = old_heading.direction }, .{}),
        try std.json.Stringify.valueAlloc(a, old_heading, .{}));
    for ([_]TextWrap{ .normal, .break_word }) |policy| {
        const json = try std.json.Stringify.valueAlloc(a, policy, .{});
        const parsed = try std.json.parseFromSlice(TextWrap, a, json, .{}); defer parsed.deinit();
        try std.testing.expectEqual(policy, parsed.value);
        const value = try std.json.parseFromSlice(std.json.Value, a, json, .{}); defer value.deinit();
        try std.testing.expectEqual(policy, try std.json.innerParseFromValue(TextWrap, a, value.value, .{}));
    }
    for ([_][]const u8{ "0", "1", "true", "null", "[]", "\"break-word\"", "\"anywhere\"", "\"Normal\"" }) |bad| {
        if (std.json.parseFromSlice(TextWrap, a, bad, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
        const value = try std.json.parseFromSlice(std.json.Value, a, bad, .{}); defer value.deinit();
        if (std.json.innerParseFromValue(TextWrap, a, value.value, .{})) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "typed inline wrap owns nonempty ranges without lending policy to empty metrics or actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]TextWrap{ .normal, .break_word }) |policy| {
        const spans = [_]Span{
            .{ .text = "unbroken", .inline_style = .{ .wrap = policy } },
            .{ .kind = .link, .text = "linked", .trail = "suffix", .direction = "rtl", .target = "Kept", .target_fragment = "part", .inline_style = .{ .wrap = policy, .cursor = .help } },
            .{ .kind = .external_link, .text = "external", .target = "https://example.invalid/", .inline_style = .{ .wrap = policy } },
        };
        for (spans) |span| {
            try std.testing.expect(validSpanInlineStyle(span));
            const json = try std.json.Stringify.valueAlloc(a, span, .{});
            const parsed = try std.json.parseFromSlice(Span, a, json, .{}); defer parsed.deinit();
            try std.testing.expectEqualDeep(span, parsed.value);
            try std.testing.expect(validSpanInlineStyle(parsed.value));
        }
        try std.testing.expect(!validSpanInlineStyle(Span{ .text = "", .inline_style = .{ .wrap = policy } }));
        try std.testing.expect(!validSpanInlineStyle(Span{ .text = "", .inline_style = .{
            .wrap = policy, .line_height = .{ .computed = .{ .value = 1, .font_scale_basis = .normal_body } } } }));
        try std.testing.expect(!validSpanInlineStyle(Span{ .text = "text", .target = "foreign", .inline_style = .{ .wrap = policy } }));
        try std.testing.expect(!validSpanInlineStyle(Span{ .kind = .link, .text = "linked", .inline_style = .{ .wrap = policy } }));
    }
    try std.testing.expect(validSpanInlineStyle(Span{ .text = "", .inline_style = .{
        .line_height = .{ .computed = .{ .value = 1, .font_scale_basis = .normal_body } } } }));
}

test "heading reveal keeps primary fallback identity and strict physical offsets independent of box margins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var section = SectionHeadingStyleTest.section;
    section.heading_style.?.title_wrap = .normal;
    section.heading_style.?.anchor_reveal = .{ .primary_top = .{ .unit = .px, .value = 75 }, .fallback_top = .{ .unit = .px, .value = 0 } };
    try std.testing.expect(validSectionHeadingCompanion(section));
    try std.testing.expectEqualDeep(SectionHeadingStyleTest.style.box, section.heading_style.?.box);
    const json = try std.json.Stringify.valueAlloc(a, section, .{});
    const parsed = try std.json.parseFromSlice(Section, a, json, .{}); defer parsed.deinit();
    try std.testing.expectEqualDeep(section, parsed.value);
    const value = try std.json.parseFromSlice(std.json.Value, a, json, .{}); defer value.deinit();
    try std.testing.expectEqualDeep(section, try std.json.innerParseFromValue(Section, a, value.value, .{}));
    try validateStored(a, .{ .entry = .{ .title = "reveal", .kind = .citations, .sections = &.{section} } }, "reveal", .citations, null);
    for (0..5) |mutation| {
        var bad = section; var blocks = [_]Block{section.blocks[0], section.blocks[1]}; bad.blocks = &blocks;
        switch (mutation) {
            0 => { bad.anchor = ""; blocks[0].anchor = ""; },
            1 => bad.heading_style.?.anchor_reveal.?.fallback_top = null,
            2 => { bad.anchor_fallback = ""; blocks[0].anchor_fallback = ""; },
            3 => { bad.anchor_fallback = bad.anchor; blocks[0].anchor_fallback = bad.anchor; },
            4 => blocks[0].anchor = "foreign",
            else => unreachable,
        }
        try std.testing.expect(!validSectionHeadingCompanion(bad));
        try std.testing.expectError(error.InvalidPresentation, validateStored(a, .{ .entry = .{
            .title = "reveal", .kind = .citations, .sections = &.{bad} } }, "reveal", .citations, null));
    }
    var legacy = section; var blocks = [_]Block{section.blocks[0], section.blocks[1]}; legacy.blocks = &blocks;
    legacy.anchor_fallback = legacy.anchor; blocks[0].anchor_fallback = legacy.anchor;
    legacy.heading_style.?.anchor_reveal = null;
    try std.testing.expect(validSectionHeadingCompanion(legacy));
    for ([_][]const u8{
        "{\"primary_top\":{\"unit\":\"em\",\"value\":1}}",
        "{\"primary_top\":{\"unit\":\"px\",\"value\":-1}}",
        "{\"primary_top\":{\"unit\":\"px\",\"value\":75},\"fallback_top\":{\"unit\":\"em\",\"value\":0}}",
        "{\"primary_top\":{\"unit\":\"px\",\"value\":75},\"extra\":0}",
        "{\"primary_top\":{\"unit\":0,\"value\":75}}",
        "{\"primary_top\":{\"unit\":\"px\",\"value\":\"75\"}}",
        "{\"primary_top\":{\"unit\":\"px\",\"value\":75,\"extra\":0}}",
        "{}",
    }) |bad| {
        if (std.json.parseFromSlice(HeadingAnchorReveal, a, bad, .{})) |unexpected| { unexpected.deinit(); return error.TestUnexpectedResult; } else |_| {}
        const invalid = try std.json.parseFromSlice(std.json.Value, a, bad, .{}); defer invalid.deinit();
        if (std.json.innerParseFromValue(HeadingAnchorReveal, a, invalid.value, .{})) |_| return error.TestUnexpectedResult else |_| {}
    }
    try std.testing.expect(!validHeadingAnchorReveal(.{ .primary_top = .{ .unit = .px, .value = std.math.inf(f32) } }));
    try std.testing.expect(!validHeadingAnchorReveal(.{ .primary_top = .{ .unit = .px, .value = 0 },
        .fallback_top = .{ .unit = .px, .value = std.math.nan(f32) } }));
}

test "Ruby associations retain empty readings gaps and levels and reject competing structure" {
    const base: RubyBase(Span) = .{ .owner = .{ .font = .{} }, .spans = &.{.{ .text = "base" }} };
    const annotation: RubyAnnotation(Span) = .{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0 };
    const value: Ruby(Span) = .{ .segments = &.{.{ .bases = &.{base}, .annotations = &.{annotation} }} };
    try std.testing.expect(validRuby(value));
    try std.testing.expect(validSpanInlineStyle(Span{ .ruby = &value, .inline_style = .{ .wrap = .normal } }));
    try std.testing.expect(!validSpanInlineStyle(Span{ .inline_style = .{ .wrap = .normal } }));
    var next = annotation; next.level = 1;
    try std.testing.expect(validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{base}, .annotations = &.{ annotation, next } }} }));
    next.level = 2;
    try std.testing.expect(!validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{base}, .annotations = &.{ annotation, next } }} }));
    next = annotation;
    try std.testing.expect(!validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{base}, .annotations = &.{ annotation, next } }} }));
    next.base_start = std.math.maxInt(u32); next.base_count = std.math.maxInt(u32);
    try std.testing.expect(!validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{base}, .annotations = &.{next} }} }));
    next = annotation; next.fallback_before = &.{.{ .text = "(" }};
    try std.testing.expect(!validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{base}, .annotations = &.{next} }} }));
    next.explicit_fallback = true;
    try std.testing.expect(validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{base}, .annotations = &.{next} }} }));
    try std.testing.expect(!validRuby(Ruby(Span){ .segments = &.{} }));
    try std.testing.expect(!validRuby(Ruby(Span){ .segments = &.{.{ .bases = &.{} }} }));
    try std.testing.expect(validRubyGap(&[_]Span{.{ .text = " \t\n\r\x0c" }}));
    inline for (.{ "a\tb", "a\nb", "a\rb", "a\x0cb" }) |text| try std.testing.expect(!validRubyBodyChild(Span{ .text = text }));
    try std.testing.expect(validRubyBodyChild(Span{ .text = "a b\xc2\xa0c" }));
    inline for (.{ "x", "\xc2\xa0", "\xff" }) |text| try std.testing.expect(!validRubyGap(&[_]Span{.{ .text = text }}));
    try std.testing.expect(!validRubyGap(&[_]Span{.{ .kind = .link, .text = " ", .target = "x" }}));
    try std.testing.expect(!validRubyGap(&[_]Span{.{ .ruby = &value }}));
    try std.testing.expect(!validRubyChild(Span{ .text = "x", .classes = "wikidict-media" }));
    try std.testing.expect(!validRubyChild(Span{ .text = "x", .classes = "plain wikidict-media-file-x" }));
    try std.testing.expect(validRubyChild(Span{ .text = "x", .classes = "wikidict-media-like" }));
    try std.testing.expect(!validRubyChild(Span{ .text = "x", .target = "not text" }));
    try std.testing.expect(!validRubyChild(Span{ .kind = .link, .text = "x" }));
    try std.testing.expect(!validRubyChild(Span{ .kind = .external_link, .text = "x" }));
    try std.testing.expect(validRubyChild(Span{ .kind = .link, .text = "x", .target = "kept" }));
}

test "Ruby heading companion uses complete recursive fallback without changing ordinary title checks" {
    const value: Ruby(Span) = .{ .segments = &.{.{ .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &.{.{ .text = "base" }} }},
        .annotations = &.{.{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0, .spans = &.{.{ .text = "reading" }} }} }} };
    const spans = [_]Span{.{ .ruby = &value }};
    var section: Section = .{ .level = 2, .title = "base\xef\xbc\x88reading\xef\xbc\x89", .anchor = "kept",
        .blocks = &.{.{ .kind = .heading, .level = 2, .anchor = "kept", .spans = &spans }} };
    try std.testing.expect(validSectionHeadingCompanion(section));
    section.title = "base"; try std.testing.expect(!validSectionHeadingCompanion(section));
    section.title = "base(reading)"; try std.testing.expect(!validSectionHeadingCompanion(section));
    section.title = "wrong"; try std.testing.expect(!validSectionHeadingCompanion(section));
    const empty: Ruby(Span) = .{ .segments = &.{.{ .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &.{.{ .text = "base" }} }},
        .annotations = &.{.{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0 }} }} };
    section.title = "base"; section.blocks = &.{.{ .kind = .heading, .level = 2, .anchor = "kept", .spans = &.{.{ .ruby = &empty }} }};
    try std.testing.expect(validSectionHeadingCompanion(section));
    section.blocks = &.{.{ .kind = .heading, .level = 2, .anchor = "kept", .spans = &.{.{ .text = "base", .trail = "x" }} }};
    try std.testing.expect(!validSectionHeadingCompanion(section));
}

test "Ruby declaring owner validates exact font context without branding an empty Span" {
    const font: InlineFontSnapshot = .{ .font_scale = 1.25, .font_scale_basis = .normal_body,
        .font_normalized = true, .bold = false, .italic = true, .language = "ja", .classes = "Jpan", .font_family = .sans_serif };
    const value: RubyOwner = .{ .font = font, .direction = "rtl", .foreground = "#112233", .background = "#ffffff",
        .inline_style = .{ .font_normalized = true, .line_height = .{ .font_relative = .{ .factor = 1.1, .font = font } },
            .baseline_shift = .{ .value = 0.1, .font_scale_basis = .normal_body }, .wrap = .break_word } };
    try std.testing.expect(validRubyOwnerContext(value));
    for ([_][]const u8{ "", "ltr", "rtl", "auto" }) |direction| {
        var changed = value; changed.direction = direction; try std.testing.expect(validRubyOwnerContext(changed));
    }
    for ([_][]const u8{ "RTL", "inherit", "rtl override", "\xff" }) |direction| {
        var changed = value; changed.direction = direction; try std.testing.expect(!validRubyOwnerContext(changed));
    }
    var changed = value; changed.foreground = "red"; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.background = "#FFFFFF"; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.font.font_scale = -1; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.inline_style.?.line_height.?.font_relative.font.bold = true; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.inline_style.?.line_height.?.font_relative.font.language = "zh"; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.inline_style.?.line_height.?.font_relative.font.classes = "other"; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.inline_style.?.line_height.?.font_relative.font.font_family = null; try std.testing.expect(!validRubyOwnerContext(changed));
    changed = value; changed.inline_style.?.font_normalized = false; try std.testing.expect(!validRubyOwnerContext(changed));
    changed.inline_style.?.baseline_shift = null; try std.testing.expect(validRubyOwnerContext(changed));
    changed = value; changed.font.font_normalized = false; changed.inline_style.?.line_height = null;
    try std.testing.expect(!validRubyOwnerContext(changed));
    const canonical: RubyOwner = .{ .font = .{}, .inline_style = .{ .line_height = .{ .font_relative = .{
        .factor = 1, .font = .{ .font_scale = 1, .font_scale_basis = .context },
    } } } };
    try std.testing.expect(validRubyOwnerContext(canonical));
    // This metadata admission is not permission to brand an ordinary empty run.
    try std.testing.expect(!validSpanInlineStyle(Span{ .inline_style = .{ .wrap = .normal } }));
}

test "Ruby fallback projects base decoration through nested owners and resets readings and RP" {
    const Collector = struct {
        values: [32]Span = undefined,
        len: usize = 0,
        fn emit(self: *@This(), value: Span) !void {
            if (self.len == self.values.len) return error.TooMany;
            self.values[self.len] = value;
            self.len += 1;
        }
    };
    const plain = Span{ .kind = .text, .text = "B", .target = "" };
    const reading = Span{ .kind = .text, .text = "reading", .target = "" };
    const explicit_rp = Span{ .kind = .text, .text = "[", .target = "", .underline = true };
    const gap = Span{ .kind = .text, .text = " \t\r\n\x0c", .target = "" };
    const nested = Ruby(Span){ .segments = &.{.{
        .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &.{plain} }},
        .annotations = &.{.{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0, .spans = &.{reading} }},
    }} };
    const nested_owner = Span{ .kind = .text, .text = "", .target = "", .ruby = &nested, .strike = true };
    const payload = Ruby(Span){ .segments = &.{
        .{ .bases = &.{
            .{ .owner = .{ .font = .{} }, .spans = &.{nested_owner} },
            .{ .owner = .{ .font = .{} }, .gap_before = &.{gap}, .spans = &.{plain} },
        }, .annotations = &.{
            .{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0, .spans = &.{reading},
                .fallback_before = &.{explicit_rp}, .fallback_after = &.{plain}, .explicit_fallback = true },
            .{ .owner = .{ .font = .{} }, .base_start = 1, .base_count = 1, .level = 0, .gap_before = &.{gap}, .spans = &.{reading} },
        } },
        .{ .gap_before = &.{gap}, .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &.{plain} }} },
    } };
    const owner = Span{ .kind = .text, .text = "", .target = "", .ruby = &payload, .underline = true };
    var out = Collector{};
    try visitRubyFallback(&[_]@TypeOf(owner){owner}, &out, Collector.emit);
    try std.testing.expectEqual(@as(usize, 15), out.len);
    // Nested base inherits outer underline and inner strike. Its reading and
    // generated delimiters receive neither inherited decoration.
    try std.testing.expect(out.values[0].underline and out.values[0].strike);
    for (out.values[1..4]) |value| try std.testing.expect(!value.underline and !value.strike);
    try std.testing.expectEqualStrings(gap.text, out.values[4].text);
    for (out.values[4..6]) |value| try std.testing.expect(value.underline and !value.strike);
    // Explicit RP keeps its authored underline; no inherited strike is added.
    try std.testing.expectEqualDeep(explicit_rp, out.values[6]);
    try std.testing.expectEqualDeep(reading, out.values[7]);
    try std.testing.expectEqualDeep(plain, out.values[8]);
    try std.testing.expectEqualDeep(gap, out.values[9]);
    for (out.values[10..13]) |value| try std.testing.expect(!value.underline and !value.strike);
    for (out.values[13..15]) |value| try std.testing.expect(value.underline and !value.strike);
    try std.testing.expect(!plain.underline and !plain.strike and !reading.underline);
    try std.testing.expectEqualDeep(nested_owner, payload.segments[0].bases[0].spans[0]);
    var ordinary = Collector{};
    try visitRubyFallback(&[_]Span{plain, explicit_rp}, &ordinary, Collector.emit);
    try std.testing.expectEqualDeep(plain, ordinary.values[0]);
    try std.testing.expectEqualDeep(explicit_rp, ordinary.values[1]);
}

test "Ruby fallback decorates all copied link states without hiding invalid original policy" {
    const Collector = struct {
        value: ?Span = null,
        fn emit(self: *@This(), value: Span) !void { self.value = value; }
    };
    const paint = LinkPaint{
        .normal = .{ .foreground = "#112233", .underline = false },
        .hover = .{ .foreground = "#223344", .underline = true },
        .active = .{ .foreground = "#334455", .underline = false },
        .hover_active = .{ .foreground = "#445566", .underline = false },
        .visited = .{ .foreground = "#556677", .underline = false },
        .visited_hover = .{ .foreground = "#667788", .underline = false },
        .visited_active = .{ .foreground = "#778899", .underline = false },
        .visited_hover_active = .{ .foreground = "#8899aa", .underline = false },
        .underline_on_focus = true,
    };
    var children = [_]Span{.{ .kind = .link, .text = "linked", .trail = "s", .target = "Exact target", .foreground = "#112233", .link_paint = paint }};
    const original = children[0];
    const payload = Ruby(Span){ .segments = &.{.{ .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &children }} }} };
    const owner = Span{ .kind = .text, .text = "", .target = "", .ruby = &payload, .underline = true, .strike = true };
    var out = Collector{};
    try visitRubyFallback(&[_]@TypeOf(owner){owner}, &out, Collector.emit);
    const projected = out.value.?;
    try std.testing.expect(validRubyBodyChild(projected));
    try std.testing.expect(projected.underline and projected.strike);
    try std.testing.expectEqualStrings(original.text, projected.text);
    try std.testing.expectEqualStrings(original.target, projected.target);
    try std.testing.expectEqualStrings(original.trail, projected.trail);
    inline for (.{ "normal", "hover", "active", "hover_active", "visited", "visited_hover", "visited_active", "visited_hover_active" }) |name| {
        try std.testing.expect(@field(projected.link_paint.?, name).underline);
        try std.testing.expectEqualStrings(@field(paint, name).foreground, @field(projected.link_paint.?, name).foreground);
    }
    try std.testing.expectEqual(paint.underline_on_focus, projected.link_paint.?.underline_on_focus);
    try std.testing.expectEqualDeep(original, children[0]);
    children[0].underline = true; // Invalid original must not be repaired by projection.
    out = .{};
    try std.testing.expectError(error.InvalidPresentation, visitRubyFallback(&[_]@TypeOf(owner){owner}, &out, Collector.emit));
    try std.testing.expect(out.value == null);
}

test "Ruby fallback projection supports compiler flags without changing source children" {
    const Child = struct {
        kind: enum { text, link, external_link } = .text,
        text: []const u8 = "",
        target: []const u8 = "",
        flags: packed struct { underline: bool = false, strike: bool = false } = .{},
        ruby: ?*const Ruby(@This()) = null,
    };
    const Collector = struct {
        values: [4]Child = undefined,
        len: usize = 0,
        fn emit(self: *@This(), value: Child) !void { self.values[self.len] = value; self.len += 1; }
    };
    const leaf = Child{ .text = "base" };
    const reading = Child{ .text = "reading" };
    const payload = Ruby(Child){ .segments = &.{.{
        .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &.{leaf} }},
        .annotations = &.{.{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0, .spans = &.{reading} }},
    }} };
    const owner = Child{ .ruby = &payload, .flags = .{ .underline = true, .strike = true } };
    var out = Collector{};
    try visitRubyFallback(&[_]@TypeOf(owner){owner}, &out, Collector.emit);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expect(out.values[0].flags.underline and out.values[0].flags.strike);
    for (out.values[1..4]) |value| try std.testing.expect(!value.flags.underline and !value.flags.strike);
    try std.testing.expectEqualDeep(leaf, payload.segments[0].bases[0].spans[0]);
    try std.testing.expectEqualDeep(reading, payload.segments[0].annotations[0].spans[0]);
}

test "DPRT validation work counts only newly supported deep tables" {
    const leaf: Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{ .{ .text = "a" }, .{ .text = "b" } } }} }} };
    const parent: Table = .{ .rows = &.{.{ .cells = &.{.{ .nested_table = leaf }} }} };
    var media: ImageValidation = .{ .a = std.testing.allocator, .media = &.{}, .deep_table_items = 0 };
    try validateTable(leaf, legacy_table_depth, &media);
    try std.testing.expectEqual(@as(usize, 0), media.deep_table_items);
    try std.testing.expectError(error.InvalidPresentation, validateTable(.{}, legacy_table_depth + 1, &media));
    // The first17 boundary, two rows, two cells and two spans consume seven.
    // The nested18 subtree was already checked and must not be charged again.
    media.deep_table_items = 7;
    try validateTable(parent, legacy_table_depth + 1, &media);
    try std.testing.expectEqual(@as(usize, 0), media.deep_table_items);
    media.deep_table_items = 6;
    try std.testing.expectError(error.InvalidPresentation, validateTable(parent, legacy_table_depth + 1, &media));
    media.deep_table_items = 10;
    try validateTable(leaf, legacy_table_depth + 1, &media);
    try std.testing.expectEqual(@as(usize, 5), media.deep_table_items);
    try validateTable(leaf, legacy_table_depth + 1, &media);
    try std.testing.expectEqual(@as(usize, 0), media.deep_table_items);
    try std.testing.expectError(error.InvalidPresentation, validateTable(leaf, legacy_table_depth + 1, &media));
    media.deep_table_items = max_presentation_items;
    try std.testing.expectError(error.InvalidPresentation, validateTable(.{}, max_table_depth + 1, &media));
    try std.testing.expectEqual(max_presentation_items, media.deep_table_items);
    try std.testing.expectEqual(@as(usize, 16), max_content_depth);
}

test "inline padding group owns its boundary and preserves child actions without textual padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const children = [_]Span{
        .{ .kind = .link, .text = "nhân", .target = "nhân", .target_fragment = "Вијетнамски", .font_scale = 0.81, .font_scale_basis = .normal_body },
        .{ .text = "!", .font_scale = 0.81, .font_scale_basis = .normal_body },
    };
    const group = InlinePaddingGroup(Span){ .left = .{ .unit = .em, .value = 0.25 },
        .right = .{ .unit = .em, .value = 0.25 }, .spans = &children };
    const owner = Span{ .inline_padding_group = &group, .font_scale = 0.81, .font_scale_basis = .normal_body };
    try std.testing.expect(validInlinePaddingGroupOwner(owner));
    try std.testing.expect(!validRubyOwner(owner) and !validRubyGap(&[_]Span{owner}));
    var validation: ImageValidation = .{ .a = a, .media = &.{} }; defer validation.deinit();
    try validateSpanColors(&[_]Span{owner}, &validation);
    const Collector = struct {
        a: std.mem.Allocator, spans: std.ArrayList(Span) = .empty,
        fn emit(self: *@This(), span: Span) !void { try self.spans.append(self.a, span); }
    };
    var result: Collector = .{ .a = a };
    try visitRubyFallback(&[_]Span{owner}, &result, Collector.emit);
    try std.testing.expectEqualDeep(@as([]const Span, &children), result.spans.items);
    try std.testing.expectEqual(@as(usize, 2), result.spans.items.len);
    try std.testing.expectEqualStrings("nhân", result.spans.items[0].text);
    try std.testing.expectEqualStrings("!", result.spans.items[1].text);
    try std.testing.expect(result.spans.items[0].kind == .link and result.spans.items[1].kind == .text);
    // The 0.81 value is a synthetic resolved-font control, not an assertion of
    // the retained page's RT default or its current computed owner font.
    try std.testing.expectEqual(@as(?f32, 0.81), result.spans.items[0].font_scale);
}

test "inline padding inherited action projects only to semantic leaves and refuses duplicate actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const children = [_]Span{ .{ .text = "thi" }, .{ .text = "ết" } };
    var group = InlinePaddingGroup(Span){ .left = .{ .unit = .em, .value = 0.25 },
        .right = .{ .unit = .em, .value = 0.25 }, .spans = &children };
    const owner = Span{ .kind = .link, .target = "fanqie", .inline_padding_group = &group, .underline = true };
    const Collector = struct {
        a: std.mem.Allocator, text: std.ArrayList(u8) = .empty, effective_actions: usize = 0,
        fn emit(self: *@This(), span: Span) !void {
            try std.testing.expect(span.inline_padding_group == null and span.ruby == null);
            try std.testing.expect(span.kind == .link and span.underline);
            try std.testing.expectEqualStrings("fanqie", span.target);
            try self.text.appendSlice(self.a, span.text);
            self.effective_actions += 1;
        }
    };
    var result: Collector = .{ .a = a };
    var validation: ImageValidation = .{ .a = a, .media = &.{} }; defer validation.deinit();
    try validateSpanColors(&[_]Span{owner}, &validation);
    try visitRubyFallback(&[_]Span{owner}, &result, Collector.emit);
    try std.testing.expectEqualStrings("thiết", result.text.items);
    try std.testing.expectEqual(@as(usize, 2), result.effective_actions);
    for (group.spans) |span| try std.testing.expect(span.kind == .text and span.target.len == 0);
    const duplicate = [_]Span{.{ .kind = .link, .text = "thiết", .target = "fanqie" }};
    group.spans = &duplicate;
    try std.testing.expectError(error.InvalidPresentation, validateSpanColors(&[_]Span{owner}, &validation));
    try std.testing.expectError(error.InvalidPresentation, visitRubyFallback(&[_]Span{owner}, &result, Collector.emit));
    const competing = [_]Span{.{ .kind = .link, .text = "thiết", .target = "Other" }};
    group.spans = &competing;
    try std.testing.expectError(error.InvalidPresentation, validateSpanColors(&[_]Span{owner}, &validation));
    group.spans = &children;
    var budget: RubyFallbackBudget = .{ .remaining = 2 };
    try std.testing.expectError(error.InvalidPresentation,
        visitRubyFallbackInner(&[_]Span{owner}, &result, Collector.emit, 0, 0, false, .{}, null, false, &budget));
    budget.remaining = max_presentation_items;
    try std.testing.expectError(error.InvalidPresentation,
        visitRubyFallbackInner(&[_]Span{owner}, &result, Collector.emit, max_content_depth, 0, false, .{}, null, false, &budget));
}

test "inline padding group shape refuses unsupported owner and edge combinations" {
    const child = [_]Span{.{ .text = "reading" }};
    const base = InlinePaddingGroup(Span){ .left = .{ .unit = .px, .value = 2 },
        .right = .{ .unit = .em, .value = 0.25 }, .spans = &child };
    for (0..7) |mode| {
        var group = base;
        var owner = Span{ .inline_padding_group = &group };
        switch (mode) {
            0 => group.left.value = -1,
            1 => group.right.value = std.math.inf(f32),
            2 => group.left.value = std.math.nan(f32),
            3 => { group.left.value = 0; group.right.value = 0; },
            4 => group.spans = &.{},
            5 => owner.text = "duplicate",
            6 => owner.trail = "duplicate",
            else => unreachable,
        }
        try std.testing.expect(!validInlinePaddingGroupOwner(owner));
    }
    var group = base;
    const owner = Span{ .inline_padding_group = &group };
    const forced_break = [_]Span{.{ .kind = .line_break, .text = "\n" }};
    group.spans = &forced_break;
    var validation: ImageValidation = .{ .a = std.testing.allocator, .media = &.{} }; defer validation.deinit();
    try std.testing.expectError(error.InvalidPresentation, validateSpanColors(&[_]Span{owner}, &validation));
    const raw_lf = [_]Span{.{ .text = "first\nsecond" }};
    group.spans = &raw_lf;
    try std.testing.expectError(error.InvalidPresentation, validateSpanColors(&[_]Span{owner}, &validation));
}

test "inline padding Ruby descendants keep synthetic punctuation actionless and reject conflicting owner ink" {
    const base = [_]Span{.{ .text = "B" }};
    const reading = [_]Span{.{ .text = "reading" }};
    var annotations = [_]RubyAnnotation(Span){.{ .owner = .{ .font = .{} },
        .base_start = 0, .base_count = 1, .level = 0, .spans = &reading }};
    const ruby = Ruby(Span){ .segments = &.{.{
        .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &base }}, .annotations = &annotations,
    }} };
    const children = [_]Span{.{ .ruby = &ruby }};
    const group = InlinePaddingGroup(Span){ .left = .{ .unit = .em, .value = 0.25 },
        .right = .{ .unit = .em, .value = 0.25 }, .spans = &children };
    const paint = OrdinaryLinkPaintModelTesting.paint();
    const owner = Span{ .kind = .link, .target = "Owner", .inline_padding_group = &group, .link_paint = paint };
    const Collector = struct {
        spans: [4]Span = undefined, count: usize = 0,
        fn emit(self: *@This(), span: Span) !void {
            if (self.count == self.spans.len) return error.TestUnexpectedResult;
            self.spans[self.count] = span; self.count += 1;
        }
    };
    var result: Collector = .{};
    try validateInlinePaddingGroupTree(owner, 0, 0);
    try visitRubyFallback(&[_]Span{owner}, &result, Collector.emit);
    try std.testing.expectEqual(@as(usize, 4), result.count);
    for ([_]usize{ 0, 2 }) |index| {
        try std.testing.expect(result.spans[index].kind == .link);
        try std.testing.expectEqualStrings("Owner", result.spans[index].target);
        try std.testing.expectEqualDeep(@as(?LinkPaint, paint), result.spans[index].link_paint);
    }
    for ([_]usize{ 1, 3 }) |index| {
        try std.testing.expect(result.spans[index].kind == .text and result.spans[index].target.len == 0);
        try std.testing.expect(result.spans[index].link_paint == null);
    }
    try std.testing.expectEqualStrings("B", result.spans[0].text);
    try std.testing.expectEqualStrings("（", result.spans[1].text);
    try std.testing.expectEqualStrings("reading", result.spans[2].text);
    try std.testing.expectEqualStrings("）", result.spans[3].text);
    annotations[0].owner.foreground = "#ff0000";
    try std.testing.expectError(error.InvalidPresentation, validateInlinePaddingGroupTree(owner, 0, 0));
    annotations[0].owner.foreground = paint.normal.foreground;
    try validateInlinePaddingGroupTree(owner, 0, 0);
    // Missing optional owner foreground is still fixed by its validated paint,
    // never by a reader theme or invented default color.
    const action = InlinePaddingGroupAction.from(owner).?;
    try action.check(Span{ .text = "reading", .foreground = paint.normal.foreground });
    try std.testing.expectError(error.InvalidPresentation, action.check(Span{ .text = "reading", .foreground = "#ff0000" }));
}

test "inline padding fallback retains empty metric owners and explicit inherited ink and child decoration" {
    const metric = Span{ .inline_style = .{ .line_height = .{ .font_relative = .{ .factor = 1, .font = .{} } } } };
    const children = [_]Span{ metric, .{ .text = "visible" } };
    const group = InlinePaddingGroup(Span){ .left = .{ .unit = .em, .value = 0.25 },
        .right = .{ .unit = .em, .value = 0.25 }, .spans = &children };
    const owner = Span{ .kind = .link, .target = "Owner", .foreground = "#ff0000", .inline_padding_group = &group };
    const action = InlinePaddingGroupAction.from(owner).?;
    try std.testing.expect(validSpanInlineStyle(metric));
    try std.testing.expectEqualDeep(metric, try action.project(metric));
    const inherited = try action.project(children[1]);
    try std.testing.expectEqualStrings("#ff0000", inherited.foreground.?);
    try std.testing.expectEqualStrings("Owner", inherited.target);
    try std.testing.expect(inherited.kind == .link and inherited.link_paint == null);
    const override = try action.project(Span{ .text = "override", .foreground = "#00ff00" });
    try std.testing.expectEqualStrings("#00ff00", override.foreground.?);
    var trailing_metric = metric;
    trailing_metric.trail = "tail";
    const trail = try action.project(trailing_metric);
    try std.testing.expect(trail.kind == .link and std.mem.eql(u8, trail.target, "Owner"));
    try std.testing.expect(validSpanInlineStyle(trail));
    try std.testing.expectEqualStrings("tail", trail.text);
    try std.testing.expectEqualStrings("", trail.trail);
    try std.testing.expectEqualDeep(metric.inline_style, trail.inline_style);
    try std.testing.expectEqualStrings("", trailing_metric.text);
    try std.testing.expectEqualStrings("tail", trailing_metric.trail);
    const Collector = struct {
        spans: [2]Span = undefined, count: usize = 0,
        fn emit(self: *@This(), span: Span) !void {
            if (self.count == self.spans.len) return error.TestUnexpectedResult;
            self.spans[self.count] = span; self.count += 1;
        }
    };
    var result: Collector = .{};
    try validateInlinePaddingGroupTree(owner, 0, 0);
    try visitRubyFallback(&[_]Span{owner}, &result, Collector.emit);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualDeep(metric, result.spans[0]);
    try std.testing.expectEqualDeep(inherited, result.spans[1]);
    const paint = OrdinaryLinkPaintModelTesting.paint();
    const painted_owner = Span{ .kind = .link, .target = "Owner", .link_paint = paint, .inline_padding_group = &group };
    const painted = try InlinePaddingGroupAction.from(painted_owner).?.project(Span{ .text = "underlined", .underline = true });
    try std.testing.expect(validSpanLinkPaint(painted));
    inline for (.{ "normal", "hover", "active", "hover_active", "visited", "visited_hover", "visited_active", "visited_hover_active" }) |name|
        try std.testing.expect(@field(painted.link_paint.?, name).underline);
    try std.testing.expect(!paint.normal.underline and !paint.active.underline);
}

test "inline action groups preserve rich runs trails and distinct equal-target owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    // Source-shaped mixed-font and trail controls. Numeric font snapshots are
    // explicit model inputs, not a claim about a captured page's computed CSS.
    const mixed = [_]Span{
        .{ .text = "der " }, .{ .text = "Mai", .italic = true }, .{ .text = " ist gekommen" },
    };
    const trail = [_]Span{ .{ .text = "d" }, .{ .text = "a" } };
    const first = InlineActionGroup(Span){ .spans = &mixed };
    const second = InlineActionGroup(Span){ .spans = &trail };
    const paint = OrdinaryLinkPaintModelTesting.paint();
    const owners = [_]Span{
        .{ .kind = .link, .target = "Same", .target_fragment = "section", .inline_action_group = &first, .link_paint = paint, .tooltip = "advice" },
        .{ .kind = .link, .target = "Same", .target_fragment = "section", .inline_action_group = &second, .link_paint = paint },
    };
    for (owners) |owner| {
        try std.testing.expect(validInlineActionGroupOwner(owner));
        try std.testing.expect(!validInlinePaddingGroupOwner(owner) and !validRubyOwner(owner));
        try validateInlineActionGroupTree(owner, 0, 0);
    }
    try std.testing.expect(owners[0].inline_action_group != owners[1].inline_action_group);
    var validation: ImageValidation = .{ .a = a, .media = &.{} }; defer validation.deinit();
    try validateSpanColors(&owners, &validation);
    const Collector = struct {
        values: [5]Span = undefined, count: usize = 0,
        fn emit(self: *@This(), span: Span) !void {
            if (self.count >= self.values.len) return error.TestUnexpectedResult;
            self.values[self.count] = span; self.count += 1;
        }
    };
    var collected: Collector = .{};
    try visitRubyFallback(&owners, &collected, Collector.emit);
    try std.testing.expectEqual(@as(usize, 5), collected.count);
    for (collected.values, 0..) |span, index| {
        try std.testing.expect(span.inline_action_group == null and span.inline_padding_group == null and span.ruby == null);
        try std.testing.expect(span.kind == .link);
        try std.testing.expectEqualStrings("Same", span.target);
        try std.testing.expectEqualStrings("section", span.target_fragment.?);
        try std.testing.expectEqualDeep(@as(?LinkPaint, paint), span.link_paint);
        try std.testing.expectEqual(index == 1, span.italic);
    }
    try std.testing.expectEqualStrings("d", collected.values[3].text);
    try std.testing.expectEqualStrings("a", collected.values[4].text);
    try std.testing.expectEqualStrings("advice", collected.values[1].tooltip.?);
    for (mixed) |span| try std.testing.expect(span.kind == .text and span.target.len == 0);
    for (trail) |span| try std.testing.expect(span.kind == .text and span.target.len == 0);
    const legacy_json = try std.json.Stringify.valueAlloc(a, mixed[0], .{});
    try std.testing.expect(std.mem.indexOf(u8, legacy_json, "inline_action_group") == null);
    const json = try std.json.Stringify.valueAlloc(a, owners[0], .{});
    const decoded = try std.json.parseFromSlice(Span, a, json, .{}); defer decoded.deinit();
    try std.testing.expectEqualDeep(owners[0], decoded.value);
    try validateInlineActionGroupTree(decoded.value, 0, 0);
}

test "inline action groups retain Ruby and padding descendants with actionless synthetic punctuation" {
    const glyphs = [_]Span{.{ .text = "B", .font_scale = 1.2, .font_scale_basis = .normal_body }};
    const reading = [_]Span{.{ .text = "reading", .superscript = true, .italic = true }};
    const padding = InlinePaddingGroup(Span){ .left = .{ .unit = .em, .value = 0.25 },
        .right = .{ .unit = .em, .value = 0.25 }, .spans = &reading };
    const padded = [_]Span{.{ .inline_padding_group = &padding }};
    const ruby = Ruby(Span){ .segments = &.{.{
        .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &glyphs }},
        .annotations = &.{.{ .owner = .{ .font = .{} }, .base_start = 0, .base_count = 1, .level = 0, .spans = &padded }},
    }} };
    const metric = Span{ .inline_style = .{ .line_height = .{ .font_relative = .{ .factor = 1, .font = .{} } } } };
    const children = [_]Span{metric, .{ .ruby = &ruby }};
    const group = InlineActionGroup(Span){ .spans = &children };
    const paint = OrdinaryLinkPaintModelTesting.paint();
    const owner = Span{ .kind = .external_link, .target = "https://example.org/", .inline_action_group = &group, .link_paint = paint };
    try validateInlineActionGroupTree(owner, 0, 0);
    const Collector = struct {
        values: [5]Span = undefined, count: usize = 0,
        fn emit(self: *@This(), span: Span) !void {
            if (self.count >= self.values.len) return error.TestUnexpectedResult;
            self.values[self.count] = span; self.count += 1;
        }
    };
    var result: Collector = .{};
    try visitRubyFallback(&[_]Span{owner}, &result, Collector.emit);
    try std.testing.expectEqual(@as(usize, 5), result.count);
    try std.testing.expectEqualDeep(metric, result.values[0]);
    // A stored action owner may have only a metric child. It remains one
    // structural owner although semantic fallback emits no action interval.
    const metric_children = [_]Span{metric};
    const metric_group = InlineActionGroup(Span){ .spans = &metric_children };
    const metric_owner = Span{ .kind = .link, .target = "Metric", .inline_action_group = &metric_group };
    try validateInlineActionGroupTree(metric_owner, 0, 0);
    var metric_result: Collector = .{};
    try visitRubyFallback(&[_]Span{metric_owner}, &metric_result, Collector.emit);
    try std.testing.expectEqual(@as(usize, 1), metric_result.count);
    try std.testing.expectEqualDeep(metric, metric_result.values[0]);
    try std.testing.expect(metric_owner.kind == .link and metric_owner.target.len != 0);
    for ([_]usize{1, 3}) |index| {
        try std.testing.expect(result.values[index].kind == .external_link);
        try std.testing.expectEqualStrings(owner.target, result.values[index].target);
        try std.testing.expectEqualDeep(@as(?LinkPaint, paint), result.values[index].link_paint);
    }
    for ([_]usize{2, 4}) |index| try std.testing.expect(result.values[index].kind == .text and result.values[index].target.len == 0 and result.values[index].link_paint == null);
    try std.testing.expectEqualStrings("reading", result.values[3].text);
    try std.testing.expect(result.values[3].superscript and result.values[3].italic);
    try std.testing.expectEqual(@as(?f32, 1.2), result.values[1].font_scale);
    try std.testing.expectEqual(FontScaleBasis.normal_body, result.values[1].font_scale_basis);
    try std.testing.expect(owner.inline_padding_group == null and owner.text.len == 0);
}

test "inline action group shape and descendants reject duplicate actions and conflicting declaring paint" {
    const plain = [_]Span{.{ .text = "child" }};
    const padding = InlinePaddingGroup(Span){ .left = .{ .unit = .px, .value = 1 },
        .right = .{ .unit = .px, .value = 0 }, .spans = &plain };
    const ruby = Ruby(Span){ .segments = &.{.{ .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &plain }} }} };
    var group = InlineActionGroup(Span){ .spans = &plain };
    const good = Span{ .kind = .link, .target = "Owner", .inline_action_group = &group };
    for (0..8) |mode| {
        var bad = good;
        switch (mode) {
            0 => bad.kind = .text,
            1 => bad.target = "",
            2 => bad.text = "duplicate",
            3 => bad.trail = "duplicate",
            4 => bad.ruby = &ruby,
            5 => bad.inline_padding_group = &padding,
            6 => bad.image = .{ .file = "Image.svg" },
            7 => bad.kind = .line_break,
            else => unreachable,
        }
        try std.testing.expect(!validInlineActionGroupOwner(bad));
    }
    group.spans = &.{};
    try std.testing.expect(!validInlineActionGroupOwner(good));
    group.spans = &plain;
    try std.testing.expect(!validRubyGap(&[_]Span{good}));
    const duplicate = [_]Span{.{ .kind = .link, .text = "child", .target = "Owner" }};
    const foreign = [_]Span{.{ .kind = .external_link, .text = "child", .target = "https://example.org/" }};
    const nested = [_]Span{good};
    const forced = [_]Span{.{ .kind = .line_break, .text = "\n" }};
    const raw_lf = [_]Span{.{ .text = "first\nsecond" }};
    const image = [_]Span{.{ .image = .{ .file = "Image.svg" } }};
    for ([_][]const Span{ &duplicate, &foreign, &nested, &forced, &raw_lf, &image }) |children| {
        group.spans = children;
        try std.testing.expectError(error.InvalidPresentation, validateInlineActionGroupTree(good, 0, 0));
    }
    const paint = OrdinaryLinkPaintModelTesting.paint();
    const painted = Span{ .kind = .link, .target = "Owner", .inline_action_group = &group, .link_paint = paint };
    const bad_leaf = [_]Span{.{ .text = "child", .foreground = "#ff0000" }};
    const bad_padding = [_]Span{.{ .inline_padding_group = &padding, .foreground = "#ff0000" }};
    const bad_ruby = [_]Span{.{ .ruby = &ruby, .foreground = "#ff0000" }};
    for ([_][]const Span{ &bad_leaf, &bad_padding, &bad_ruby }) |children| {
        group.spans = children;
        try std.testing.expectError(error.InvalidPresentation, validateInlineActionGroupTree(painted, 0, 0));
        var validation: ImageValidation = .{ .a = std.testing.allocator, .media = &.{} }; defer validation.deinit();
        try std.testing.expectError(error.InvalidPresentation, validateSpanColors(&[_]Span{painted}, &validation));
    }
    const matched = [_]Span{.{ .inline_padding_group = &padding, .foreground = paint.normal.foreground }};
    group.spans = &matched;
    try validateInlineActionGroupTree(painted, 0, 0);
    try validateInlineActionGroupTree(good, 0, 0);
}

test "inline action groups share bounded content work and reject recursive children" {
    const Noop = struct { fn emit(_: void, _: Span) error{}!void {} };
    const plain = [_]Span{ .{ .text = "first" }, .{ .text = "second" } };
    var group = InlineActionGroup(Span){ .spans = &plain };
    const owner = Span{ .kind = .link, .target = "Owner", .inline_action_group = &group };
    var budget: RubyFallbackBudget = .{ .remaining = 3 };
    try visitRubyFallbackInner(&[_]Span{owner}, {}, Noop.emit, 0, 0, false, .{}, null, false, &budget);
    try std.testing.expectEqual(@as(usize, 0), budget.remaining);
    try std.testing.expectEqual(@as(usize, 0), budget.action_group_depth);
    budget.remaining = 2;
    try std.testing.expectError(error.InvalidPresentation,
        visitRubyFallbackInner(&[_]Span{owner}, {}, Noop.emit, 0, 0, false, .{}, null, false, &budget));
    try std.testing.expectEqual(@as(usize, 0), budget.action_group_depth);
    try validateInlineActionGroupTree(owner, max_content_depth - 1, 0);
    try std.testing.expectError(error.InvalidPresentation, validateInlineActionGroupTree(owner, max_content_depth, 0));
    var paddings: [max_content_depth]InlinePaddingGroup(Span) = undefined;
    var padding_spans: [max_content_depth]Span = undefined;
    for (0..max_content_depth) |index| {
        const reversed = max_content_depth - 1 - index;
        paddings[reversed] = .{ .left = .{ .unit = .px, .value = 1 }, .right = .{ .unit = .px, .value = 0 },
            .spans = if (reversed + 1 == max_content_depth) &plain else padding_spans[reversed + 1 ..][0..1] };
        padding_spans[reversed] = .{ .inline_padding_group = &paddings[reversed] };
    }
    group.spans = padding_spans[1..2];
    try validateInlineActionGroupTree(owner, 0, 0);
    group.spans = padding_spans[0..1];
    try std.testing.expectError(error.InvalidPresentation, validateInlineActionGroupTree(owner, 0, 0));
    paddings[0].spans = padding_spans[0..1];
    try std.testing.expectError(error.InvalidPresentation, validateInlineActionGroupTree(owner, 0, 0));
    const ruby = Ruby(Span){ .segments = &.{.{ .bases = &.{.{ .owner = .{ .font = .{} }, .spans = &plain }} }} };
    const ruby_span = [_]Span{.{ .ruby = &ruby }};
    group.spans = &ruby_span;
    try std.testing.expectError(error.InvalidPresentation, validateInlineActionGroupTree(owner, 0, max_ruby_depth));
}
