const std = @import("std");
const types = @import("blob_encoder").presentation_types;

pub const Scope = u64;
/// Null means unknown; an empty ID proves parsed attribute absence. This context
/// is build-only and never inherited as the identity of another element.
pub const ElementContext = struct {
    ancestor_classes: ?[]const u8 = null,
    own_id: ?[]const u8 = null,
};
pub const TableResolution = struct { style: ?types.TableStyle, scope: Scope, unresolved: bool, margin_basis_unresolved: bool = false, background_specified: bool = false, descendant_style_unresolved: bool = false, width_specified: bool = false };
pub const CellResolution = struct { style: ?types.CellStyle, background: ?[]const u8, background_specified: bool, unresolved: bool, padding_basis_unresolved: bool = false, alignment_specified: bool = false };
const max_css_bytes = 1024 * 1024;
const max_rules = 4096;
const Target = enum { element, table, cell, th, td, other };
const Property = enum { background, border, collapse, margins, margin_top, margin_right, margin_bottom, margin_left, padding, text_align, float_side, width, clear, box_sizing, layout_reset, other };
const Value = union(enum) {
    color: []const u8,
    border: types.StyleBorder,
    collapse: types.BorderCollapse,
    edges: types.StyleEdges,
    align_value: types.CellTextAlign,
    float_value: types.TableFloatSide,
    no_float,
    width_value: types.StyleWidth,
    auto_width,
    border_box,
    clear_value: types.FigureClear,
    length_value: types.StyleLength,
    unsupported,
};
const Declaration = struct { property: Property, value: Value, important: bool, order: u32, affects_font_basis: bool = false };
const Selector = struct {
    target: Target,
    mask: Scope,
    ancestor_mask: Scope = 0,
    ancestor_class: ?[]const u8 = null,
    own_classes: []const []const u8 = &.{},
    own_ids: []const []const u8 = &.{},
    necessary_classes: []const []const u8 = &.{},
    specificity: u64,
    unsupported: bool,
};
const Rule = struct { selector: Selector, declarations: []const Declaration, number: u32 };
const Priority = struct {
    important: bool = false,
    specificity: u64 = 0,
    order: u32 = 0,
    inline_style: bool = false,
    fn wins(self: Priority, prior: Priority) bool {
        if (self.important != prior.important) return self.important;
        if (self.inline_style != prior.inline_style) return self.inline_style;
        if (self.specificity != prior.specificity) return self.specificity > prior.specificity;
        return self.order >= prior.order;
    }
};
const Winner = struct { value: Value, priority: Priority };
const Winners = struct {
    slots: [@typeInfo(Property).@"enum".field_names.len]?Winner = @splat(null),
    selector_unresolved: bool = false,
    font_basis_unresolved: bool = false,
    fn add(self: *Winners, declaration: Declaration, specificity: u64, conditional: bool, inline_style: bool) void {
        if (declaration.affects_font_basis) self.font_basis_unresolved = true;
        const index = @backingInt(declaration.property);
        const next: Priority = .{ .important = declaration.important, .specificity = specificity, .order = declaration.order, .inline_style = inline_style };
        if (self.slots[index]) |prior| if (!next.wins(prior.priority)) return;
        self.slots[index] = .{ .value = if (conditional) .unsupported else declaration.value, .priority = next };
    }
    fn value(self: Winners, property: Property) ?Value {
        var selected = self.slots[@backingInt(property)];
        if (property == .float_side or property == .text_align or property == .width or property == .clear or property == .padding or property == .box_sizing) if (self.slots[@backingInt(Property.layout_reset)]) |reset| {
            if (selected == null or reset.priority.wins(selected.?.priority)) selected = reset;
        };
        return if (selected) |winner| winner.value else null;
    }
    fn unresolved(self: Winners) bool {
        if (self.selector_unresolved) return true;
        for (self.slots, 0..) |slot, index| {
            const property: Property = @enumFromInt(index);
            if (property == .margins or marginEdge(property) != null) continue;
            if (slot) |winner| if (winner.value == .unsupported) return true;
        }
        return resolvedMargins(self).unresolved;
    }
};


fn marginEdge(property: Property) ?usize {
    return switch (property) { .margin_top => 0, .margin_right => 1, .margin_bottom => 2, .margin_left => 3, else => null };
}
const MarginResolution = struct { value: ?types.StyleEdges = null, unresolved: bool = false };
fn resolvedMargins(winners: Winners) MarginResolution {
    var values: [4]types.StyleLength = @splat(.{ .unit = .px, .value = 0 });
    var seen = false;
    inline for (.{ Property.margin_top, Property.margin_right, Property.margin_bottom, Property.margin_left }, 0..) |property, index| {
        var selected = winners.slots[@backingInt(Property.margins)];
        if (winners.slots[@backingInt(property)]) |edge| {
            if (selected == null or edge.priority.wins(selected.?.priority)) selected = edge;
        }
        if (winners.slots[@backingInt(Property.layout_reset)]) |reset| {
            if (selected == null or reset.priority.wins(selected.?.priority)) selected = reset;
        }
        if (selected) |winner| {
            seen = true;
            switch (winner.value) {
                .length_value => |value| values[index] = value,
                .edges => |edges_value| values[index] = switch (index) { 0 => edges_value.top, 1 => edges_value.right, 2 => edges_value.bottom, 3 => edges_value.left, else => unreachable },
                else => return .{ .unresolved = true },
            }
        }
    }
    return .{ .value = if (seen) .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] } else null };
}

pub const AlignmentResolution = struct { value: ?types.CellTextAlign = null, specified: bool = false, unresolved: bool = false };
const AlignmentCascade = struct {
    resolution: AlignmentResolution = .{},
    priority: Priority = .{},
    inline_style: bool = false,
    fn consider(self: *AlignmentCascade, declaration: Declaration, specificity: u32, conditional: bool, inline_style: bool) void {
        const next: Priority = .{ .important = declaration.important, .specificity = specificity, .order = declaration.order };
        if (self.resolution.specified) {
            if (next.important == self.priority.important and inline_style != self.inline_style) {
                if (!inline_style) return;
            } else if (!next.wins(self.priority)) return;
        }
        const known = !conditional and declaration.value == .align_value;
        self.* = .{ .resolution = .{ .value = if (known) declaration.value.align_value else null, .specified = true, .unresolved = !known }, .priority = next, .inline_style = inline_style };
    }
    fn declarations(self: *AlignmentCascade, a: std.mem.Allocator, css: []const u8, specificity: u32, order: u32, conditional: bool, inline_style: bool) !void {
        var pos: usize = 0;
        var next_order = order;
        while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
            defer a.free(raw);
            next_order += 1;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
            const name = trim(raw[0..colon]);
            if (std.ascii.eqlIgnoreCase(name, "all") or std.mem.indexOfScalar(u8, name, '\\') != null) {
                if (try declarationAlloc(a, raw, next_order)) |declaration| self.consider(declaration, specificity, true, inline_style);
            } else if (try declarationAlloc(a, raw, next_order)) |declaration| {
                if (declaration.property == .text_align) self.consider(declaration, specificity, conditional, inline_style);
            }
        }
    }
};

pub fn presentationalTextAlign(raw: ?[]const u8) ?types.CellTextAlign {
    const value = trim(raw orelse return null);
    inline for (.{ "left", "center", "right" }, .{ types.CellTextAlign.left, .center, .right }) |name, alignment| if (std.ascii.eqlIgnoreCase(value, name)) return alignment;
    return null;
}
fn emptyProfile(a: std.mem.Allocator) Profile {
    return .{ .arena = std.heap.ArenaAllocator.init(a), .rules = &.{}, .classes = &.{}, .admitted_rule_numbers = &.{}, .has_unsupported_rules = false };
}
pub fn resolveInlineTableAlloc(a: std.mem.Allocator, css: []const u8) !TableResolution {
    if (css.len > max_css_bytes) return .{ .style = null, .scope = 0, .unresolved = true, .margin_basis_unresolved = true };
    const profile = emptyProfile(a);
    const winners = try profile.cascade(a, .table, 0, 0, "", .{ .ancestor_classes = "", .own_id = "" }, null, null, css);
    const margins = resolvedMargins(winners);
    var style: types.TableStyle = .{ .margins = margins.value };
    var unresolved = margins.unresolved;
    if (winners.value(.float_side)) |value| {
        if (value == .float_value) style.float_side = value.float_value;
        unresolved = unresolved or value == .unsupported;
    }
    projectTableBox(&style, winners);
    inline for (.{ Property.width, .padding, .clear, .box_sizing, .collapse }) |property| if (winners.value(property)) |value| {
        unresolved = unresolved or value == .unsupported;
    };
    return .{ .style = if (types.validTableStyle(style)) style else null, .scope = 0, .unresolved = unresolved, .margin_basis_unresolved = winners.font_basis_unresolved, .width_specified = winners.value(.width) != null or unresolvedTableWidthBox(winners) };
}
pub fn resolveInlineCellAlloc(a: std.mem.Allocator, legacy_align: ?[]const u8, css: []const u8) !CellResolution {
    const profile = emptyProfile(a);
    const alignment = try profile.resolveAlignment(a, "", "", "", legacy_align, css);
    return .{ .style = if (alignment.value) |value| .{ .text_align = value } else null, .background = null, .background_specified = false, .unresolved = alignment.unresolved, .alignment_specified = alignment.specified };
}
pub fn resolveInlineAlignmentAlloc(a: std.mem.Allocator, legacy_align: ?[]const u8, css: []const u8) !AlignmentResolution {
    const profile = emptyProfile(a);
    return profile.resolveAlignment(a, "", "", "", legacy_align, css);
}

pub const FontSizeValue = union(enum) {
    inherit,
    absolute: f32,
    relative: f32,
    step: @import("font_scale.zig").RelativeKeyword,
    unknown,
};

fn fontSizeValue(property: []const u8, raw: []const u8) ?FontSizeValue {
    const value = trim(raw);
    if (std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset")) return .inherit;
    if (std.ascii.eqlIgnoreCase(value, "initial")) return .{ .absolute = 1 };
    if (!std.ascii.eqlIgnoreCase(property, "font-size")) return if (value.len != 0) .unknown else null;
    const font = @import("font_scale.zig");
    if (font.absoluteKeyword(value)) |size| return .{ .absolute = size };
    if (font.relativeKeyword(value)) |step| return .{ .step = step };
    if (font.parseRelative(value)) |factor| return .{ .relative = factor };
    if (std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer") or
        std.mem.indexOfScalar(u8, value, '(') != null or std.mem.indexOfScalar(u8, value, '\\') != null) return .unknown;
    // Valid but unsupported lengths must invalidate parent authority. Invalid
    // identifiers/negative lengths do not replace a valid earlier declaration.
    for ([_][]const u8{ "px", "pt", "pc", "in", "cm", "mm", "q", "rem", "ex", "ch", "cap", "ic", "lh", "rlh", "vw", "vh", "vi", "vb", "vmin", "vmax", "svw", "svh", "lvw", "lvh", "dvw", "dvh" }) |unit| {
        if (value.len > unit.len and std.ascii.eqlIgnoreCase(value[value.len - unit.len ..], unit)) {
            const number = value[0 .. value.len - unit.len];
            const size = std.fmt.parseFloat(f64, number) catch continue;
            if (std.math.isFinite(size) and size >= 0) return .unknown;
        }
    }
    return null;
}

const FontCascade = struct {
    value: ?FontSizeValue = null,
    priority: Priority = .{},
    fn declarations(self: *FontCascade, a: std.mem.Allocator, css: []const u8, specificity: u64, order: u32, uncertain: bool, inline_style: bool) !void {
        var pos: usize = 0;
        var next_order = order;
        while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
            defer a.free(raw);
            next_order += 1;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
            const property = trim(raw[0..colon]);
            const escaped = std.mem.indexOfScalar(u8, property, '\\') != null;
            if (!escaped and !std.ascii.eqlIgnoreCase(property, "font-size") and !std.ascii.eqlIgnoreCase(property, "font") and !std.ascii.eqlIgnoreCase(property, "all")) continue;
            const parsed_priority = customPriority(raw[colon + 1 ..]);
            const selected = if (escaped or parsed_priority.unknown) FontSizeValue.unknown else fontSizeValue(property, parsed_priority.value) orelse continue;
            const next: Priority = .{ .important = parsed_priority.important, .specificity = specificity, .order = next_order, .inline_style = inline_style };
            if (self.value != null and !next.wins(self.priority)) continue;
            self.value = if (uncertain) .unknown else selected;
            self.priority = next;
        }
    }
};

pub fn resolveInlineFontSizeAlloc(a: std.mem.Allocator, css: []const u8) !?FontSizeValue {
    if (css.len > max_css_bytes) return .unknown;
    var cascade_value: FontCascade = .{};
    try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
    return cascade_value.value;
}

// Visibility is resolved only during production; no CSS enters a reader record.
// Its own-class namespace is separate from the table ancestor paint namespace.
// Producer-only text paint. Keep real element ancestry separate from inherited
// span classes: a descendant selector must never match a flattened class union.
pub const TextElement = struct {
    tag: []const u8,
    // Null is an unobserved attribute domain. Empty proves typeof is absent.
    // Figure matching admits only proved Thumb/Frame format membership,
    // not an exclusive inventory of other generated RDFa tokens.
    typeof_tokens: ?[]const u8 = null,
    // Null inherits; an explicit empty or unsupported language is a barrier.
    language: ?[]const u8 = null,
    classes: []const u8 = "",
    id: []const u8 = "",
    parent: ?*const TextElement = null,
    source_key: usize = 0,
    // Build-only end of a selected complete content tree; fragments default unknown.
    ancestry_complete: bool = false,
};
const TextCompound = struct {
    tag: ?[]const u8 = null,
    typeof_token: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    ids: []const []const u8 = &.{},
    fn matches(self: TextCompound, element: *const TextElement) bool {
        if (self.tag) |tag| if (!std.ascii.eqlIgnoreCase(tag, element.tag)) return false;
        for (self.classes) |name| if (!Profile.hasClass(element.classes, name)) return false;
        for (self.ids) |name| if (!std.mem.eql(u8, name, element.id)) return false;
        if (self.typeof_token) |token| if (element.typeof_tokens) |values| {
            if (!Profile.hasClass(values, token)) return false;
        };
        return true;
    }
};
// A deliberately narrow, refusal-only subset of CSS language ranges.
fn simpleLanguage(value: []const u8) bool {
    if (value.len == 0) return false;
    var segment = false;
    for (value) |byte| {
        if (byte == '-') { if (!segment) return false; segment = false; }
        else if (std.ascii.isAlphabetic(byte)) { segment = true; }
        else return false;
    }
    return segment;
}
fn bareLanguageRange(raw: []const u8) ?[]const u8 {
    const text = trim(raw);
    if (text.len < 8 or !std.ascii.eqlIgnoreCase(text[0..6], ":lang(") or text[text.len - 1] != ')') return null;
    const value = text[6 .. text.len - 1];
    return if (simpleLanguage(value)) value else null;
}
fn languageRefutes(range: []const u8, element: ?*const TextElement, root_language: ?[]const u8) bool {
    var cursor = element;
    while (cursor) |node| : (cursor = node.parent) {
        if (node.language) |value| return languageValueRefutes(range, value);
    }
    return if (root_language) |value| languageValueRefutes(range, value) else false;
}
fn languageValueRefutes(range: []const u8, value: []const u8) bool {
    if (!simpleLanguage(value)) return false;
    return !(value.len >= range.len and std.ascii.eqlIgnoreCase(value[0..range.len], range) and
        (value.len == range.len or value[range.len] == '-'));
}
const TextSelector = struct {
    // A known nonmatch can refuse this candidate; a match remains uncertain.
    language_range: ?[]const u8 = null,
    // A complete original chain requires an element before its subject. This
    // refutes only the isolated, certified content-root node, never a fragment.
    root_subject_excluded: bool = false,
    root_predicate_unresolved: bool = false,
    // Necessary own classes outside one simple :lang() predicate. This is
    // refusal-only evidence, never a language or selector-match certificate.
    caption_class_guard: []const []const u8 = &.{},
    // Necessary terminal type from a separately bounded complete chain.
    caption_subject_tag: ?[]const u8 = null,
    chain: []const TextCompound,
    specificity: u64,
    uncertain: bool,
    required_own_attribute: ?[]const u8 = null,
    direct_children: bool = false,
    fn matches(self: TextSelector, element: *const TextElement) bool {
        if (self.language_range) |range| if (languageRefutes(range, element, null)) return false;
        if (self.root_subject_excluded and element.ancestry_complete and element.parent == null and
            element.source_key == 0 and std.ascii.eqlIgnoreCase(element.tag, "div") and Profile.hasClass(element.classes, "mw-parser-output")) return false;
        if (self.chain.len == 0) return true;
        if (!self.chain[self.chain.len - 1].matches(element)) return false;
        var parent = element.parent;
        var index = self.chain.len - 1;
        while (index != 0) {
            index -= 1;
            if (self.direct_children) {
                const ancestor = parent orelse return false;
                parent = ancestor.parent;
                if (!self.chain[index].matches(ancestor)) return false;
            } else {
                while (parent) |ancestor| {
                    parent = ancestor.parent;
                    if (self.chain[index].matches(ancestor)) break;
                } else return false;
            }
        }
        return true;
    }
};
const TextRule = struct {
    selector: TextSelector,
    css: []const u8,
    order: u32,
    // Only finite direct text-align values; no custom/malformed/mixed effect.
    figure_root_alignment_only: bool = false,
    figure_language_baseline_only: bool = false,
};
// A figure's recorded ancestry contains authored elements, not an invented
// skin/content/list wrapper. A selector still satisfiable in those outer
// domains cannot be called false merely because no generated wrapper was
// recorded. The ordinary complete-content producer can instead supply its
// exact ParserOutput wrapper and an explicit end of that content domain.
// Unbound fragments retain the unknown outer domain. Generated wrappers cannot
// introduce another image or figure.
// Follow the same necessary-compound path as matches(). An unobserved
// attribute can retain a possible match, but cannot become a known CSS winner.
fn figureTypeofUnknown(selector: TextSelector, element: *const TextElement) bool {
    var has_attribute = false;
    for (selector.chain) |compound| has_attribute = has_attribute or compound.typeof_token != null;
    if (!has_attribute or selector.chain.len == 0) return false;
    var index = selector.chain.len - 1;
    if (selector.chain[index].typeof_token != null and element.typeof_tokens == null) return true;
    var parent = element.parent;
    while (index != 0) {
        index -= 1;
        if (selector.direct_children) {
            const ancestor = parent orelse return true;
            if (selector.chain[index].typeof_token != null and ancestor.typeof_tokens == null) return true;
            parent = ancestor.parent;
        } else {
            while (parent) |ancestor| {
                parent = ancestor.parent;
                if (selector.chain[index].matches(ancestor)) {
                    if (selector.chain[index].typeof_token != null and ancestor.typeof_tokens == null) return true;
                    break;
                }
            } else return true;
        }
    }
    return false;
}

fn figureOuterSelectorUnknown(selector: TextSelector, element: *const TextElement) bool {
    if (selector.chain.len < 2 or !selector.chain[selector.chain.len - 1].matches(element)) return false;
    var parent = element.parent;
    var complete = element.ancestry_complete;
    var index = selector.chain.len - 1;
    while (index != 0) {
        index -= 1;
        if (selector.direct_children) {
            if (parent) |ancestor| {
                parent = ancestor.parent;
                complete = complete or ancestor.ancestry_complete;
                if (!selector.chain[index].matches(ancestor)) return false;
                continue;
            }
        } else {
            while (parent) |ancestor| {
                parent = ancestor.parent;
                complete = complete or ancestor.ancestry_complete;
                if (selector.chain[index].matches(ancestor)) break;
            } else {
                if (complete) return false;
                for (selector.chain[0 .. index + 1]) |compound| if (compound.tag) |tag| {
                    if (!std.ascii.eqlIgnoreCase(tag, "div") and !std.ascii.eqlIgnoreCase(tag, "body") and
                        !std.ascii.eqlIgnoreCase(tag, "html") and !std.ascii.eqlIgnoreCase(tag, "li") and
                        !std.ascii.eqlIgnoreCase(tag, "ul") and !std.ascii.eqlIgnoreCase(tag, "ol")) return false;
                };
                return true;
            }
            continue;
        }
        if (complete) return false;
        for (selector.chain[0 .. index + 1]) |compound| if (compound.tag) |tag| {
            if (!std.ascii.eqlIgnoreCase(tag, "div") and !std.ascii.eqlIgnoreCase(tag, "body") and
                !std.ascii.eqlIgnoreCase(tag, "html") and !std.ascii.eqlIgnoreCase(tag, "li") and
                !std.ascii.eqlIgnoreCase(tag, "ul") and !std.ascii.eqlIgnoreCase(tag, "ol")) return false;
        };
        return true;
    }
    return false;
}
// Refusal-only inventory already used for uncertain root predicates. A missing
// necessary class cannot match caption nodes, generated nodes or real ancestors.
fn figureCaptionClassPresent(authored: ?*const TextElement, caption_classes: []const u8, required: []const u8) bool {
    var present = Profile.hasClass(caption_classes, required) or Profile.hasClass(
        "mw-content-ltr mw-content-rtl mw-parser-output mw-default-size mw-halign-none mw-halign-center mw-halign-left mw-halign-right mw-file-element mw-selflink selflink internal mw-magiclink-isbn", required);
    var ancestor = authored;
    while (ancestor) |element| : (ancestor = element.parent) present = present or Profile.hasClass(element.classes, required);
    return present;
}

pub const TextColor = union(enum) { inherit, initial, value: []const u8, unknown };
pub const TextWeight = union(enum) { inherit, value: bool, unknown };
pub const TextFontStyle = union(enum) { inherit, value: bool, unknown };
pub const TextPaint = struct { color: ?TextColor = null, weight: ?TextWeight = null, color_inline: bool = false, weight_inline: bool = false, font_style: ?TextFontStyle = null, font_style_inline: bool = false };
fn textColorEqual(a: TextColor, b: TextColor) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return if (a == .value) std.mem.eql(u8, a.value, b.value) else true;
}
fn textWeightEqual(a: TextWeight, b: TextWeight) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return if (a == .value) a.value == b.value else true;
}
fn textFontStyleEqual(a: TextFontStyle, b: TextFontStyle) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return if (a == .value) a.value == b.value else true;
}
pub const BlockGeometryResolution = struct {
    style: ?types.BlockStyle = null,
    unresolved: bool = false,
};
const BlockEdgeCandidate = struct { value: ?types.StyleLength, priority: Priority };
const BlockGeometryCascade = struct {
    slots: [8]?BlockEdgeCandidate = @splat(null),
    possible: std.ArrayList(struct { index: usize, candidate: BlockEdgeCandidate }) = .empty,
    unsafe: bool = false,
    seen: bool = false,

    fn add(self: *@This(), a: std.mem.Allocator, index: usize, value: ?types.StyleLength, priority: Priority, uncertain: bool) !void {
        self.seen = true;
        const candidate: BlockEdgeCandidate = .{ .value = value, .priority = priority };
        if (uncertain) {
            try self.possible.append(a, .{ .index = index, .candidate = candidate });
        } else if (self.slots[index] == null or priority.wins(self.slots[index].?.priority)) {
            self.slots[index] = candidate;
        }
    }
    fn declarations(self: *@This(), a: std.mem.Allocator, css: []const u8, specificity: u64, order: u32, uncertain: bool, inline_style: bool) !void {
        var pos: usize = 0;
        var next_order = order;
        while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
            defer a.free(raw);
            next_order += 1;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
            const name = trim(raw[0..colon]);
            const parsed = customPriority(raw[colon + 1 ..]);
            const value = trim(parsed.value);
            const priority: Priority = .{ .important = parsed.important, .specificity = specificity, .order = next_order, .inline_style = inline_style };
            const escaped = std.mem.indexOfScalar(u8, name, '\\') != null;
            const reset = std.ascii.eqlIgnoreCase(name, "all") or escaped;
            const margin = std.ascii.eqlIgnoreCase(name, "margin");
            const padding = std.ascii.eqlIgnoreCase(name, "padding");
            if (reset or margin or padding) {
                const quartet = if (!reset and !parsed.unknown) edges(value) else null;
                const values: [4]?types.StyleLength = if (quartet) |q| .{ q.top, q.right, q.bottom, q.left } else @splat(null);
                for (0..8) |index| {
                    if (!reset and ((margin and index >= 4) or (padding and index < 4))) continue;
                    try self.add(a, index, values[index % 4], priority, uncertain);
                }
                if (reset) self.unsafe = true;
                continue;
            }
            var edge_index: ?usize = null;
            inline for (.{ "margin-top", "margin-right", "margin-bottom", "margin-left", "padding-top", "padding-right", "padding-bottom", "padding-left" }, 0..) |property, index| {
                if (std.ascii.eqlIgnoreCase(name, property)) edge_index = index;
            }
            if (edge_index) |index| {
                try self.add(a, index, if (parsed.unknown) null else length(value), priority, uncertain);
                continue;
            }
            // Logical edges, decorations, sizing and flow cannot be represented
            // by this initial transparent single-paragraph box contract.
            if (std.ascii.startsWithIgnoreCase(name, "margin-") or std.ascii.startsWithIgnoreCase(name, "padding-") or
                std.ascii.startsWithIgnoreCase(name, "border") or std.ascii.startsWithIgnoreCase(name, "background") or
                std.ascii.startsWithIgnoreCase(name, "overflow") or std.ascii.startsWithIgnoreCase(name, "column") or
                std.ascii.startsWithIgnoreCase(name, "grid") or std.ascii.startsWithIgnoreCase(name, "flex")) self.unsafe = true;
            inline for (.{ "display", "position", "float", "clear", "width", "height", "min-width", "max-width", "min-height", "max-height", "box-sizing", "box-shadow", "transform", "visibility", "opacity", "contain", "writing-mode", "line-height", "text-indent", "white-space", "vertical-align", "top", "right", "bottom", "left", "inset", "zoom", "clip", "filter" }) |property| {
                if (std.ascii.eqlIgnoreCase(name, property)) self.unsafe = true;
            }
        }
    }
    fn result(self: *const @This(), zero_default: bool) BlockGeometryResolution {
        if (!self.seen) return .{};
        if (self.unsafe) return .{ .unresolved = true };
        var selected: [8]?types.StyleLength = @splat(null);
        for (self.slots, 0..) |slot, index| {
            if (slot) |winner| {
                selected[index] = winner.value orelse return .{ .unresolved = true };
            } else if (zero_default) selected[index] = .{ .unit = .px, .value = 0 };
        }
        for (self.possible.items) |possible| {
            const certain = self.slots[possible.index];
            if (certain != null and !possible.candidate.priority.wins(certain.?.priority)) continue;
            const value = possible.candidate.value orelse return .{ .unresolved = true };
            const current = selected[possible.index] orelse return .{ .unresolved = true };
            if (value.unit != current.unit or value.value != current.value) return .{ .unresolved = true };
        }
        var style: types.BlockStyle = .{};
        inline for (0..2) |group| {
            var seen = false;
            for (self.slots[group * 4 ..][0..4]) |slot| seen = seen or slot != null;
            var possible_group = false;
            for (self.possible.items) |possible| if (possible.index / 4 == group) { possible_group = true; };
            // A merely possible property cannot replace the viewer default
            // outside gap even when its numeric edge equals CSS initial zero.
            if (!seen and possible_group) return .{ .unresolved = true };
            if (seen) {
                const at = group * 4;
                const quartet: types.StyleEdges = .{
                    .top = selected[at] orelse return .{ .unresolved = true },
                    .right = selected[at + 1] orelse return .{ .unresolved = true },
                    .bottom = selected[at + 2] orelse return .{ .unresolved = true },
                    .left = selected[at + 3] orelse return .{ .unresolved = true },
                };
                if (group == 0) style.margins = quartet else style.padding = quartet;
            }
        }
        return .{ .style = if (types.validBlockStyle(style)) style else null };
    }
};

const TextCascade = struct {
    paint: TextPaint = .{},
    color_priority: Priority = .{},
    weight_priority: Priority = .{},
    font_style_priority: Priority = .{},
    possible_colors: std.ArrayList(struct { value: TextColor, priority: Priority }) = .empty,
    possible_weights: std.ArrayList(struct { value: TextWeight, priority: Priority }) = .empty,
    possible_font_styles: std.ArrayList(struct { value: TextFontStyle, priority: Priority }) = .empty,
    fn result(self: *const TextCascade) TextPaint {
        var paint = self.paint;
        for (self.possible_colors.items) |possible| if (paint.color == null or (possible.priority.wins(self.color_priority) and !textColorEqual(paint.color.?, possible.value))) {
            paint.color = .unknown; paint.color_inline = false;
        };
        for (self.possible_weights.items) |possible| if (paint.weight == null or (possible.priority.wins(self.weight_priority) and !textWeightEqual(paint.weight.?, possible.value))) {
            paint.weight = .unknown; paint.weight_inline = false;
        };
        for (self.possible_font_styles.items) |possible| if (paint.font_style == null or (possible.priority.wins(self.font_style_priority) and !textFontStyleEqual(paint.font_style.?, possible.value))) {
            paint.font_style = .unknown; paint.font_style_inline = false;
        };
        return paint;
    }
    fn declarations(self: *TextCascade, a: std.mem.Allocator, css: []const u8, specificity: u64, order: u32, uncertain: bool, inline_style: bool) !void {
        var pos: usize = 0;
        var next_order = order;
        while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
            defer a.free(raw);
            next_order += 1;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
            const property = trim(raw[0..colon]);
            const escaped = std.mem.indexOfScalar(u8, property, '\\') != null;
            const all = std.ascii.eqlIgnoreCase(property, "all");
            const color = all or escaped or std.ascii.eqlIgnoreCase(property, "color");
            const weight = all or escaped or std.ascii.eqlIgnoreCase(property, "font-weight") or std.ascii.eqlIgnoreCase(property, "font");
            const font_style = all or escaped or std.ascii.eqlIgnoreCase(property, "font-style") or std.ascii.eqlIgnoreCase(property, "font");
            if (!color and !weight and !font_style) continue;
            const parsed = customPriority(raw[colon + 1 ..]);
            const value = trim(parsed.value);
            const inherit = std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset");
            const initial = std.ascii.eqlIgnoreCase(value, "initial");
            const next: Priority = .{ .important = parsed.important, .specificity = specificity, .order = next_order, .inline_style = inline_style };
            if (color) {
                var selected: TextColor = .unknown;
                if (!escaped and !parsed.unknown) {
                    if (inherit or std.ascii.eqlIgnoreCase(value, "currentcolor")) selected = .inherit else if (initial) selected = .initial else if (!all) {
                        if (try canonicalColorAlloc(a, value)) |canonical| selected = .{ .value = canonical };
                    }
                }
                if (uncertain) {
                    try self.possible_colors.append(a, .{ .value = selected, .priority = next });
                } else if (self.paint.color == null or next.wins(self.color_priority)) {
                    self.paint.color = selected;
                    self.color_priority = next;
                    self.paint.color_inline = inline_style;
                }
            }
            if (weight) {
                var selected: TextWeight = .unknown;
                if (!escaped and !parsed.unknown) {
                    if (inherit) selected = .inherit else if (initial) selected = .{ .value = false } else if (std.ascii.eqlIgnoreCase(property, "font-weight")) {
                        if (std.ascii.eqlIgnoreCase(value, "normal")) selected = .{ .value = false } else if (std.ascii.eqlIgnoreCase(value, "bold")) selected = .{ .value = true };
                    }
                }
                if (uncertain) {
                    try self.possible_weights.append(a, .{ .value = selected, .priority = next });
                } else if (self.paint.weight == null or next.wins(self.weight_priority)) {
                    self.paint.weight = selected;
                    self.weight_priority = next;
                    self.paint.weight_inline = inline_style;
                }
            }
            if (font_style) {
                var selected: TextFontStyle = .unknown;
                if (!escaped and !parsed.unknown) {
                    if (inherit) selected = .inherit else if (initial) selected = .{ .value = false } else if (std.ascii.eqlIgnoreCase(property, "font-style")) {
                        if (std.ascii.eqlIgnoreCase(value, "normal")) selected = .{ .value = false } else if (std.ascii.eqlIgnoreCase(value, "italic")) selected = .{ .value = true };
                    }
                }
                if (uncertain) {
                    try self.possible_font_styles.append(a, .{ .value = selected, .priority = next });
                } else if (self.paint.font_style == null or next.wins(self.font_style_priority)) {
                    self.paint.font_style = selected;
                    self.font_style_priority = next;
                    self.paint.font_style_inline = inline_style;
                }
            }
        }
    }
};

pub const AttributePresence = enum { unknown, present, absent };
pub const AttributePresenceSource = struct {
    ctx: ?*const anyopaque,
    get: *const fn (?*const anyopaque, []const u8) AttributePresence,
};

// Only a positive, complete final-compound attribute can require authored
// presence. Its value is never used to grant a selector match.
fn requiredOwnAttribute(tail: []const u8) ?[]const u8 {
    const raw = trim(tail);
    if (raw.len < 3 or raw[0] != '[' or raw[raw.len - 1] != ']') return null;
    const inner = trim(raw[1 .. raw.len - 1]);
    if (inner.len == 0 or !(std.ascii.isAlphabetic(inner[0]) or inner[0] == '_')) return null;
    var end: usize = 1;
    while (end < inner.len and (std.ascii.isAlphanumeric(inner[end]) or inner[end] == '_' or inner[end] == '-')) : (end += 1) {}
    const name = inner[0..end];
    const rest = trim(inner[end..]);
    if (rest.len == 0) return name;
    if (rest[0] != '=') return null;
    const value = trim(rest[1..]);
    if (value.len < 2 or (value[0] != '\'' and value[0] != '"') or value[value.len - 1] != value[0]) return null;
    for (value[1 .. value.len - 1]) |byte| if (byte == value[0] or byte == '\\' or byte == '[' or byte == ']' or byte < 32 or byte == 127) return null;
    return name;
}

const DisplaySelector = struct {
    required_own_attribute: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const u32 = &.{},
    specificity: u32 = 0,
    uncertain: bool = false,
};
const DisplayRule = struct { selector: DisplaySelector, css: []const u8, order: u32 };
pub const DisplayMatch = struct { css: []const u8, specificity: u32, order: u32, uncertain: bool };
pub const DisplayIterator = struct {
    attribute_presence: ?AttributePresenceSource = null,
    profile: *const Profile,
    tag: []const u8,
    id: []const u8,
    classes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *DisplayIterator) ?DisplayMatch {
        rules: while (self.cursor < self.profile.display_rules.len) {
            const rule = self.profile.display_rules[self.cursor];
            self.cursor += 1;
            const selector = rule.selector;
            if (selector.required_own_attribute) |name| if (self.attribute_presence) |attributes| {
                if (attributes.get(attributes.ctx, name) == .absent) continue;
            };
            if (selector.tag) |tag| if (!std.ascii.eqlIgnoreCase(tag, self.tag)) continue;
            if (selector.id) |id| if (!std.mem.eql(u8, id, self.id)) continue;
            for (selector.classes) |required| {
                if (!Profile.hasClass(self.classes, self.profile.display_classes[required])) continue :rules;
            }
            return .{ .css = rule.css, .specificity = selector.specificity, .order = rule.order, .uncertain = selector.uncertain };
        }
        return null;
    }
};

pub const DisplayCascade = struct {
    hidden: ?bool = false,
    seen: bool = false,
    priority: Priority = .{},
    inline_style: bool = false,

    pub fn consider(self: *DisplayCascade, hidden: ?bool, important: bool, specificity: u32, order: u32, inline_style: bool) void {
        const next: Priority = .{ .important = important, .specificity = specificity, .order = order };
        if (self.seen) {
            if (important == self.priority.important and inline_style != self.inline_style) {
                if (!inline_style) return;
            } else if (!next.wins(self.priority)) return;
        }
        self.* = .{ .hidden = hidden, .seen = true, .priority = next, .inline_style = inline_style };
    }
};

/// Producer-only static table styles. No selector or declaration text enters a reader.
pub const Profile = struct {
    custom_properties: ?*const CustomProfile = null,
    arena: std.heap.ArenaAllocator,
    sources: []const SourceRange = &.{},
    rules: []const Rule,
    classes: []const []const u8,
    ancestor_classes: []const []const u8 = &.{},
    admitted_rule_numbers: []const u32,
    has_unsupported_rules: bool,
    globally_unresolved: bool = false,
    text_rules: []const TextRule = &.{},
    block_rules: []const TextRule = &.{},
    figure_rules: []const TextRule = &.{},
    display_rules: []const DisplayRule = &.{},
    display_classes: []const []const u8 = &.{},

    pub fn displayRules(self: *const Profile, tag: []const u8, classes: []const u8, id: []const u8) DisplayIterator {
        return .{ .profile = self, .tag = tag, .id = id, .classes = classes };
    }

    pub fn resolveAlignment(self: *const Profile, a: std.mem.Allocator, tag: []const u8, classes: []const u8, id: []const u8, legacy_align: ?[]const u8, css: []const u8) std.mem.Allocator.Error!AlignmentResolution {
        if (self.globally_unresolved or css.len > max_css_bytes) return .{ .specified = true, .unresolved = true };
        var cascade_value: AlignmentCascade = .{};
        if (presentationalTextAlign(legacy_align)) |alignment| cascade_value.consider(.{ .property = .text_align, .value = .{ .align_value = alignment }, .important = false, .order = 0 }, 0, false, false);
        var matches = self.displayRules(tag, classes, id);
        while (matches.next()) |matched| try cascade_value.declarations(a, matched.css, matched.specificity, matched.order, matched.uncertain, false);
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return cascade_value.resolution;
    }

    pub fn resolveFontSize(self: *const Profile, a: std.mem.Allocator, tag: []const u8, classes: []const u8, id: []const u8, css: []const u8) std.mem.Allocator.Error!?FontSizeValue {
        return self.resolveFontSizeWithAttributes(a, tag, classes, id, css, null);
    }

    pub fn resolveFontSizeWithAttributes(self: *const Profile, a: std.mem.Allocator, tag: []const u8, classes: []const u8, id: []const u8, css: []const u8, attributes: ?AttributePresenceSource) std.mem.Allocator.Error!?FontSizeValue {
        if (self.globally_unresolved or css.len > max_css_bytes) return .unknown;
        var cascade_value: FontCascade = .{};
        var matches = self.displayRules(tag, classes, id);
        matches.attribute_presence = attributes;
        while (matches.next()) |matched| try cascade_value.declarations(a, matched.css, matched.specificity, matched.order, matched.uncertain, false);
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return cascade_value.value;
    }

    /// Uses the same typed ancestor selector proof as text paint. Necessary
    /// own-attribute absence may refute an unsupported candidate, never admit it.
    pub fn resolveFontSizeIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8, attributes: ?AttributePresenceSource) std.mem.Allocator.Error!?FontSizeValue {
        if (self.globally_unresolved or css.len > max_css_bytes) return .unknown;
        var cascade_value: FontCascade = .{};
        for (self.text_rules) |rule| {
            if (!rule.selector.matches(element)) continue;
            if (rule.selector.required_own_attribute) |name| if (attributes) |known| {
                if (known.get(known.ctx, name) == .absent) continue;
            };
            try cascade_value.declarations(a, rule.css, rule.selector.specificity, rule.order, rule.selector.uncertain, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return cascade_value.value;
    }

    pub fn resolveBlockGeometryIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!BlockGeometryResolution {
        if (self.globally_unresolved or css.len > max_css_bytes) return .{ .unresolved = true };
        var cascade_value: BlockGeometryCascade = .{};
        defer cascade_value.possible.deinit(a);
        for (self.block_rules) |rule| {
            if (!rule.selector.matches(element)) continue;
            try cascade_value.declarations(a, rule.css, rule.selector.specificity, rule.order, rule.selector.uncertain, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        // DIV has zero initial edges; paragraph UA margins are viewer-owned,
        // so a P quartet needs independently explicit values on every side.
        return cascade_value.result(std.ascii.eqlIgnoreCase(element.tag, "div"));
    }

    pub fn hasTextContext(self: *const Profile) bool { return self.hasTextPaint() or self.block_rules.len != 0; }

    pub fn hasTextPaint(self: *const Profile) bool { return self.globally_unresolved or self.text_rules.len != 0; }

    pub fn resolveTextPaint(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!TextPaint {
        if (self.globally_unresolved or css.len > max_css_bytes) return .{ .color = .unknown, .weight = .unknown, .font_style = .unknown };
        var cascade_value: TextCascade = .{};
        defer cascade_value.possible_colors.deinit(a);
        defer cascade_value.possible_weights.deinit(a);
        defer cascade_value.possible_font_styles.deinit(a);
        for (self.text_rules) |rule| {
            if (rule.selector.matches(element)) try cascade_value.declarations(a, rule.css, rule.selector.specificity, rule.order, rule.selector.uncertain, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return cascade_value.result();
    }

    pub fn resolveFigure(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, font_scale: f32, rtl: bool) std.mem.Allocator.Error!FigureStyle {
        return resolveFigureStyle(self, a, element, font_scale, rtl);
    }

    pub const FigureRootDirectionUse = enum { independent, generated_only, unresolved };

    // A source site default does not attest ParserOutput's page direction.
    // Rules that can depend on that unknown root and later caption children
    // need more context than the pure generated-Figure preparation supplies.
    pub fn figureRootDirectionUse(self: *const Profile, authored: ?*const TextElement) FigureRootDirectionUse {
        return self.figureRootDirectionUseWithCaptionClasses(authored, null);
    }

    pub fn figureRootDirectionUseWithCaptionClasses(self: *const Profile, authored: ?*const TextElement, caption_classes: ?[]const u8) FigureRootDirectionUse {
        return self.figureRootDirectionUseWithCaptionDomain(authored, caption_classes, null);
    }

    pub fn figureRootDirectionUseWithCaptionDomain(self: *const Profile, authored: ?*const TextElement, caption_classes: ?[]const u8, caption_tags: ?[]const []const u8) FigureRootDirectionUse {
        return self.figureRootDirectionUseWithLanguage(authored, caption_classes, caption_tags, null, false, null);
    }
    pub fn figureRootDirectionUseWithLanguage(self: *const Profile, authored: ?*const TextElement, caption_classes: ?[]const u8, caption_tags: ?[]const []const u8, root_language: ?[]const u8, caption_no_language_override: bool, outer_languages: ?[]const []const u8) FigureRootDirectionUse {
        const ltr: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
        const rtl: TextElement = .{ .tag = "div", .classes = "mw-content-rtl mw-parser-output" };
        var result: FigureRootDirectionUse = .independent;
        direction_rule: for (self.figure_rules) |rule| {
            // Only complete supported selectors supply necessary terminal classes.
            // Unknown functional/pseudo projections retain their existing guards.
            if (caption_classes) |inherited_classes| if (!rule.selector.uncertain and rule.selector.chain.len != 0) {
                for (rule.selector.chain[rule.selector.chain.len - 1].classes) |required|
                    if (!figureCaptionClassPresent(authored, inherited_classes, required)) continue :direction_rule;
            };
            if (caption_no_language_override) if (rule.selector.language_range) |range| {
                // A bare rule can affect an ancestor and then inherit into the
                // caption even when an inner language overrides that ancestor.
                var outer_absent = rule.figure_language_baseline_only;
                if (outer_languages) |languages| {
                    outer_absent = languages.len != 0;
                    for (languages) |language| outer_absent = outer_absent and languageValueRefutes(range, language);
                }
                var absent = outer_absent and languageRefutes(range, null, root_language);
                var cursor = authored;
                while (cursor) |node| : (cursor = node.parent) absent = absent and languageRefutes(range, node, root_language);
                if (absent) continue;
            };
            // A fully inventoried caption cannot acquire a subject tag absent
            // from both its native nodes and the actual inherited ancestry.
            // This refutes an effect; it never matches a language predicate.
            if (caption_tags) |tags| if (rule.selector.caption_subject_tag) |required| {
                // Only list containers have a complete absence certificate.
                // Other authored/generated wrapper domains remain unchanged.
                const list_container = std.ascii.eqlIgnoreCase(required, "ol") or
                    std.ascii.eqlIgnoreCase(required, "ul") or std.ascii.eqlIgnoreCase(required, "dl");
                var present = !list_container;
                for ([_][]const u8{ "html", "body", "div", "figure", "figcaption", "a", "img" }) |tag|
                    present = present or std.ascii.eqlIgnoreCase(tag, required);
                for (tags) |tag| present = present or std.ascii.eqlIgnoreCase(tag, required);
                var ancestor = authored;
                while (ancestor) |element| : (ancestor = element.parent)
                    present = present or std.ascii.eqlIgnoreCase(element.tag, required);
                if (!present) continue;
            };
            // Matched primary Thumb/Frame CSS explicitly sets center on the
            // frame and start on its caption. A root-only inherited alignment
            // cannot cross either barrier; descendant rules remain evaluated.
            if (rule.figure_root_alignment_only and !rule.selector.uncertain and rule.selector.chain.len == 1 and
                (rule.selector.matches(&ltr) or rule.selector.matches(&rtl))) continue;
            if (rule.selector.root_predicate_unresolved) {
                if (caption_classes) |inherited_classes| {
                    var absent = false;
                    for (rule.selector.caption_class_guard) |name| {
                        absent = absent or !figureCaptionClassPresent(authored, inherited_classes, name);
                    }
                    if (absent) continue;
                }
                return .unresolved;
            }
            for (rule.selector.chain, 0..) |compound, index| {
                if (compound.matches(&ltr) == compound.matches(&rtl)) continue;
                // A first descendant compound is independent only if the next
                // compound cannot be an existing ancestor or the root. Its
                // future match is then below this actual authored ancestor.
                var independently_matched = false;
                if (index == 0 and !rule.selector.direct_children and rule.selector.chain.len > 1 and
                    !rule.selector.chain[1].matches(&ltr) and !rule.selector.chain[1].matches(&rtl))
                {
                    var preceding_match = false;
                    var parent = authored;
                    while (parent) |element| : (parent = element.parent) {
                        if (element.ancestry_complete) break;
                        if (rule.selector.chain[1].matches(element)) preceding_match = true;
                        if (element.source_key != 0 and compound.matches(element)) independently_matched = true;
                    }
                    independently_matched = independently_matched and !preceding_match;
                }
                if (independently_matched) continue;
                // These two generated nodes are completely evaluated before
                // caption effects. Other terminal/ancestor domains stay strict.
                if (index != 0 or rule.selector.chain.len != 2 or rule.selector.uncertain) return .unresolved;
                const terminal = rule.selector.chain[1];
                const tag = terminal.tag orelse return .unresolved;
                if ((!std.ascii.eqlIgnoreCase(tag, "figure") and !std.ascii.eqlIgnoreCase(tag, "figcaption")) or
                    terminal.classes.len != 0 or terminal.ids.len != 0) return .unresolved;
                result = .generated_only;
            }
        }
        // Custom definitions are separate from direct Figure rules. A root
        // direction-dependent environment must not leak into the later parse.
        if (self.custom_properties) |custom| for (custom.rules) |rule| {
            if (rule.root_only) continue; // CSS :root is not this content DIV.
            if (rule.root_predicate_unresolved) return .unresolved;
            if (rule.selector.tag) |tag| if (!std.ascii.eqlIgnoreCase(tag, "div")) continue;
            if (rule.selector.id) |id| if (id.len != 0) continue;
            var match_ltr = true;
            var match_rtl = true;
            for (rule.selector.classes) |required| {
                const name = custom.classes[required];
                match_ltr = match_ltr and Profile.hasClass(ltr.classes, name);
                match_rtl = match_rtl and Profile.hasClass(rtl.classes, name);
            }
            if (match_ltr != match_rtl) return .unresolved;
        };
        return result;
    }

    // Closing content ancestry must not introduce an uncomputed inherited
    // cascade. Direct generated-Figure rules are resolved separately below.
    pub fn contentParentEffectsUnchanged(self: *const Profile, original: ?*const TextElement, projected: *const TextElement) bool {
        if (self.globally_unresolved) return false;
        for (self.figure_rules) |rule| {
            if (rule.figure_root_alignment_only and !rule.selector.uncertain and rule.selector.chain.len == 1 and
                projected.ancestry_complete and projected.source_key == 0 and projected.parent == null and
                std.ascii.eqlIgnoreCase(projected.tag, "div") and Profile.hasClass(projected.classes, "mw-parser-output")) continue;
            if (rule.selector.matches(projected) and (original == null or !rule.selector.matches(original.?))) return false;
        }
        return true;
    }

    pub fn sourceBidiScopeUnchanged(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!bool {
        if (self.globally_unresolved or css.len > max_css_bytes) return false;
        for (self.figure_rules) |rule| {
            if ((rule.selector.matches(element) or figureOuterSelectorUnknown(rule.selector, element)) and
                try hasBidiDeclaration(a, rule.css)) return false;
        }
        return !(try hasBidiDeclaration(a, css));
    }

    pub fn deinit(self: *Profile) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn classScope(self: *const Profile, names: []const u8) Scope {
        var result: Scope = 0;
        var tokens = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
        while (tokens.next()) |token| {
            for (self.classes, 0..) |name, i| if (std.mem.eql(u8, token, name)) {
                result |= @as(Scope, 1) << @intCast(i);
            };
        }
        return result;
    }

    fn hasClass(names: []const u8, required: []const u8) bool {
        var tokens = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
        while (tokens.next()) |name| if (std.mem.eql(u8, name, required)) return true;
        return false;
    }

    pub fn ancestorScope(self: *const Profile, names: []const u8) Scope {
        var result: Scope = 0;
        var tokens = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
        while (tokens.next()) |token| {
            for (self.ancestor_classes, 0..) |name, i| if (std.mem.eql(u8, token, name)) {
                result |= @as(Scope, 1) << @intCast(i);
            };
        }
        return result;
    }

    fn cascade(self: *const Profile, a: std.mem.Allocator, target: Target, scope: Scope, ancestor_scope: Scope, own_names: []const u8, context: ElementContext, legacy_bg: ?[]const u8, legacy_align: ?[]const u8, inline_css: []const u8) !Winners {
        const ancestor_names = context.ancestor_classes;
        var winners: Winners = .{};
        if (legacy_bg) |raw| if (try canonicalColorAlloc(a, raw)) |color| {
            winners.add(.{ .property = .background, .value = .{ .color = color }, .important = false, .order = 0 }, 0, false, false);
        };
        if (presentationalTextAlign(legacy_align)) |alignment| winners.add(.{ .property = .text_align, .value = .{ .align_value = alignment }, .important = false, .order = 0 }, 0, false, false);
        rules: for (self.rules) |rule| {
            const selector_value = rule.selector;
            if (selector_value.target != .element and selector_value.target != target and !(selector_value.target == .cell and (target == .th or target == .td))) continue;
            if (selector_value.mask != 0 and selector_value.mask & scope == 0) continue;
            for (selector_value.own_classes) |name| if (!hasClass(own_names, name)) continue :rules;
            var uncertain = selector_value.unsupported;
            if (context.own_id) |id| {
                for (selector_value.own_ids) |required| if (!std.mem.eql(u8, id, required)) continue :rules;
            } else if (selector_value.own_ids.len != 0) uncertain = true;
            if (selector_value.ancestor_class) |name| {
                if (ancestor_names) |names| {
                    if (!hasClass(names, name)) continue;
                } else if (selector_value.ancestor_mask != 0) {
                    if (selector_value.ancestor_mask & ancestor_scope == 0) continue;
                } else uncertain = true;
            }
            if (ancestor_names) |names| for (selector_value.necessary_classes) |name| {
                if (!hasClass(own_names, name) and !hasClass(names, name)) continue :rules;
            };
            if (uncertain) winners.selector_unresolved = true;
            for (rule.declarations) |declaration| winners.add(declaration, selector_value.specificity, uncertain or !representedProperty(target, declaration.property), false);
        }
        var order: u32 = max_rules * 1024;
        var pos: usize = 0;
        while (try nextDeclarationAlloc(a, inline_css, &pos)) |raw| {
            defer a.free(raw);
            order += 1;
            if (try declarationAlloc(a, raw, order)) |declaration| winners.add(declaration, 0, !representedProperty(target, declaration.property), true);
        }
        return winners;
    }

    pub fn resolveTable(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        return self.resolveTableWithAncestors(a, inherited_scope, classes, null, legacy_bg, inline_css);
    }

    pub fn resolveTableWithAncestors(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, ancestor_names: ?[]const u8, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        return self.resolveTableWithContext(a, inherited_scope, classes, .{ .ancestor_classes = ancestor_names }, legacy_bg, inline_css);
    }

    pub fn resolveTableWithContext(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, context: ElementContext, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        const ancestor_names = context.ancestor_classes;
        if (self.globally_unresolved or inline_css.len > max_css_bytes) return .{ .style = null, .scope = inherited_scope | self.classScope(classes), .unresolved = true, .background_specified = true, .margin_basis_unresolved = true, .descendant_style_unresolved = true };
        const own_scope = self.classScope(classes);
        // Every local selector is represented as a proved match/nonmatch or an
        // uncertain property override. An extra element class absent from that
        // complete sheet cannot erase independent known paint.
        const winners = try self.cascade(a, .table, own_scope, if (ancestor_names) |names| self.ancestorScope(names) else 0, classes, context, legacy_bg, null, inline_css);
        var style: types.TableStyle = .{};
        if (winners.value(.background)) |value| if (value == .color) {
            style.background = value.color;
        };
        if (winners.value(.border)) |value| if (value == .border) {
            style.border = value.border;
        };
        style.margins = resolvedMargins(winners).value;
        projectTableBox(&style, winners);
        if (winners.value(.float_side)) |value| if (value == .float_value) {
            style.float_side = value.float_value;
        };
        return .{ .style = if (types.validTableStyle(style)) style else null, .scope = inherited_scope | own_scope, .unresolved = winners.unresolved(), .margin_basis_unresolved = winners.font_basis_unresolved or self.inheritedFontBasisUnresolved(inherited_scope, ancestor_names), .background_specified = winners.value(.background) != null, .width_specified = winners.value(.width) != null or unresolvedTableWidthBox(winners) };
    }

    fn inheritedFontBasisUnresolved(self: *const Profile, scope: Scope, ancestor_names: ?[]const u8) bool {
        rules: for (self.rules) |rule| {
            const selected = rule.selector;
            if (selected.mask != 0 and selected.mask & scope == 0) continue;
            // Only actual ancestor class absence can refute inherited font
            // declarations. Merged names do not prove tag/order/compound identity.
            if (ancestor_names) |names| {
                for (selected.own_classes) |name| if (!hasClass(names, name)) continue :rules;
                for (selected.necessary_classes) |name| if (!hasClass(names, name)) continue :rules;
                if (selected.ancestor_class) |name| if (!hasClass(names, name)) continue :rules;
            }
            for (rule.declarations) |declaration| if (declaration.affects_font_basis) return true;
        }
        return false;
    }

    pub fn resolveCell(self: *const Profile, a: std.mem.Allocator, scope: Scope, header: bool, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        return self.resolveCellWithAncestors(a, scope, 0, header, legacy_bg, inline_css);
    }

    pub fn resolveCellWithAncestors(self: *const Profile, a: std.mem.Allocator, scope: Scope, ancestor_scope: Scope, header: bool, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        return self.resolveCellWithClasses(a, scope, ancestor_scope, "", null, header, legacy_bg, inline_css);
    }

    pub fn resolveCellWithClasses(self: *const Profile, a: std.mem.Allocator, scope: Scope, ancestor_scope: Scope, own_names: []const u8, ancestor_names: ?[]const u8, header: bool, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        return self.resolveCellWithContext(a, scope, ancestor_scope, own_names, .{ .ancestor_classes = ancestor_names }, header, legacy_bg, inline_css);
    }

    pub fn resolveCellWithContext(self: *const Profile, a: std.mem.Allocator, scope: Scope, ancestor_scope: Scope, own_names: []const u8, context: ElementContext, header: bool, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        return self.resolveCellWithContextAndHints(a, scope, ancestor_scope, own_names, context, header, legacy_bg, null, inline_css);
    }

    pub fn resolveCellWithHints(self: *const Profile, a: std.mem.Allocator, scope: Scope, ancestor_scope: Scope, header: bool, legacy_bg: ?[]const u8, legacy_align: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        return self.resolveCellWithContextAndHints(a, scope, ancestor_scope, "", .{}, header, legacy_bg, legacy_align, inline_css);
    }

    pub fn resolveCellWithContextAndHints(self: *const Profile, a: std.mem.Allocator, scope: Scope, ancestor_scope: Scope, own_names: []const u8, context: ElementContext, header: bool, legacy_bg: ?[]const u8, legacy_align: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        const ancestor_names = context.ancestor_classes;
        if (self.globally_unresolved or inline_css.len > max_css_bytes) return .{ .style = null, .background = null, .background_specified = true, .unresolved = true, .padding_basis_unresolved = true, .alignment_specified = true };
        const winners = try self.cascade(a, if (header) .th else .td, scope, ancestor_scope, own_names, context, legacy_bg, legacy_align, inline_css);
        var style: types.CellStyle = .{};
        if (winners.value(.border)) |value| if (value == .border) {
            style.border = value.border;
        };
        if (winners.value(.padding)) |value| if (value == .edges) {
            style.padding = value.edges;
        };
        if (winners.value(.text_align)) |value| if (value == .align_value) {
            style.text_align = value.align_value;
        };
        const background = winners.value(.background);
        return .{ .style = if (types.validCellStyle(style)) style else null, .background = if (background) |value| (if (value == .color) value.color else null) else null, .background_specified = background != null, .unresolved = winners.unresolved(), .padding_basis_unresolved = winners.font_basis_unresolved or self.inheritedFontBasisUnresolved(scope, ancestor_names), .alignment_specified = winners.value(.text_align) != null };
    }
};

fn hasBidiDeclaration(a: std.mem.Allocator, css: []const u8) std.mem.Allocator.Error!bool {
    var pos: usize = 0;
    while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
        defer a.free(raw);
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return true;
        const name = trim(raw[0..colon]);
        if (std.mem.indexOfScalar(u8, name, '\\') != null or std.ascii.eqlIgnoreCase(name, "unicode-bidi") or std.ascii.eqlIgnoreCase(name, "direction")) return true;
    }
    return false;
}

const Builder = struct {
    a: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,
    classes: std.ArrayList([]const u8) = .empty,
    ancestor_classes: std.ArrayList([]const u8) = .empty,
    numbers: std.ArrayList(u32) = .empty,
    number: u32 = 0,
    declaration_order: u32 = 0,
    unsupported: bool = false,
    globally_unresolved: bool = false,
    text_rules: std.ArrayList(TextRule) = .empty,
    block_rules: std.ArrayList(TextRule) = .empty,
    figure_rules: std.ArrayList(TextRule) = .empty,
    display_rules: std.ArrayList(DisplayRule) = .empty,
    display_classes: std.ArrayList([]const u8) = .empty,

    fn uncertainTextSelector(self: *Builder, raw: []const u8) !TextSelector {
        // Reuse the existing quote/bracket-aware terminal scanner. Unsupported
        // ancestry cannot introduce paint, but its necessary own compound must
        // not invalidate unrelated elements throughout the page.
        const terminal = try self.displaySelector(raw, true);
        var classes: std.ArrayList([]const u8) = .empty;
        for (terminal.classes) |id| try classes.append(self.a, self.display_classes.items[id]);
        const ids: []const []const u8 = if (terminal.id) |id| try self.a.dupe([]const u8, &.{id}) else &.{};
        const compounds = try self.a.alloc(TextCompound, 1);
        compounds[0] = .{ .tag = terminal.tag, .classes = classes.items, .ids = ids };
        return .{ .chain = compounds, .specificity = std.math.maxInt(u64), .uncertain = true, .required_own_attribute = terminal.required_own_attribute };
    }
    fn textSelector(self: *Builder, raw: []const u8, conditional: bool) !TextSelector {
        if (bareLanguageRange(raw)) |range| {
            var language_selector = try self.uncertainTextSelector(raw);
            language_selector.language_range = try self.a.dupe(u8, range);
            return language_selector;
        }
        var chain: std.ArrayList(TextCompound) = .empty;
        var uncertain = conditional;
        var specificity: u64 = 0;
        const unsafe_relation = std.mem.indexOfAny(u8, raw, "+~|\\/") != null;
        if (unsafe_relation or std.mem.indexOfAny(u8, raw, "[(") != null) return self.uncertainTextSelector(raw);
        const text = trim(raw);
        var pos: usize = 0;
        var child = false;
        var has_child = false;
        var has_descendant = false;
        while (pos < text.len) {
            if (text[pos] == '>') return self.uncertainTextSelector(raw);
            const start = pos;
            while (pos < text.len and text[pos] != '>' and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) == null) : (pos += 1) {}
            const part = text[start..pos];
            const exact = try self.paintCompound(part, true);
            const compound = exact orelse try self.paintCompound(part, false) orelse return self.uncertainTextSelector(raw);
            if (exact == null) uncertain = true;
            if (chain.items.len != 0) {
                has_child = has_child or child;
                has_descendant = has_descendant or !child;
                // Mixing descendant search with immediate-parent constraints
                // requires another matching proof. Do not use greedy ancestry
                // to guess those selectors; preserve their uncertain candidate.
                if (has_child and has_descendant) return self.uncertainTextSelector(raw);
            }
            try chain.append(self.a, .{ .tag = compound.tag, .classes = compound.classes, .ids = compound.ids });
            specificity += (@as(u64, @intCast(compound.ids.len)) << 42) + (@as(u64, @intCast(compound.classes.len)) << 21) + @intFromBool(compound.tag != null);
            while (pos < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) != null) : (pos += 1) {}
            if (pos == text.len) break;
            child = text[pos] == '>';
            if (child) {
                pos += 1;
                while (pos < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) != null) : (pos += 1) {}
                if (pos == text.len) return self.uncertainTextSelector(raw);
            }
        }
        return .{ .chain = chain.items, .specificity = if (uncertain) std.math.maxInt(u64) else specificity, .uncertain = uncertain or chain.items.len == 0, .direct_children = has_child };
    }
    fn appendTextRules(self: *Builder, prelude: []const u8, css: []const u8, conditional: bool, order: u32) !void {
        try self.appendTypedRules(&self.text_rules, prelude, css, conditional, order);
    }
    fn appendTypedRules(self: *Builder, destination: *std.ArrayList(TextRule), prelude: []const u8, css: []const u8, conditional: bool, order: u32) !void {
        var parts: SelectorList = .{ .source = prelude };
        var selectors: std.ArrayList(TextSelector) = .empty;
        var uncertain_list = false;
        while (try parts.nextAlloc(self.a)) |part| {
            const selector_value = try self.textSelector(part, conditional);
            uncertain_list = uncertain_list or selector_value.uncertain;
            try selectors.append(self.a, selector_value);
        }
        for (selectors.items) |selector_value| {
            var selected = selector_value;
            if (uncertain_list) { selected.uncertain = true; selected.specificity = std.math.maxInt(u64); }
            if (destination.items.len == max_rules) return error.StyleProfileLimit;
            try destination.append(self.a, .{ .selector = selected, .css = css, .order = order });
        }
    }

    // Keep supported necessary ancestor compounds even when one compound has
    // an unrepresented attribute/pseudo predicate. Whitespace and combinators
    // inside quoted attributes/functions cannot manufacture ancestors.
    fn figureCompoundEnd(text: []const u8, start: usize, dependency_scan: bool) ?usize {
        var at = start;
        var groups: [16]u8 = undefined;
        var count: usize = 0;
        var quote: u8 = 0;
        while (at < text.len) : (at += 1) {
            const c = text[at];
            if (c == '\\') return null;
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '\'' or c == '"') {
                if (count == 0) return null;
                quote = c;
                continue;
            }
            if (c == '[' or c == '(') {
                if (count == groups.len) return null;
                groups[count] = c; count += 1;
                continue;
            }
            if (c == ']' or c == ')') {
                if (count == 0 or groups[count - 1] != (if (c == ']') @as(u8, '[') else '(')) return null;
                count -= 1;
                continue;
            }
            if (count == 0) {
                if (c == '>' or std.mem.indexOfScalar(u8, " \t\r\n\x0c", c) != null) return at;
                if (dependency_scan and (c == '+' or c == '~')) return at;
                if (c == '*' and at == start) continue;
                if (std.mem.indexOfScalar(u8, "+~|/*", c) != null) return null;
            }
        }
        return if (count == 0 and quote == 0) at else null;
    }

    // This is only a necessary subject-position proof. It never grants a
    // match for the unsupported relation/predicate retained by the fallback.
    fn contentRootSubjectExcluded(self: *Builder, raw: []const u8) std.mem.Allocator.Error!bool {
        const text = trim(raw);
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < text.len) {
            const end = figureCompoundEnd(text, pos, true) orelse return false;
            if (end == pos or try self.paintCompound(text[pos..end], false) == null) return false;
            count += 1;
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
            if (next == text.len) return count > 1;
            if (std.mem.indexOfScalar(u8, ">+~", text[next]) != null) {
                next += 1;
                while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
                if (next == text.len) return false;
            } else if (next == end) return false;
            pos = next;
        }
        return false;
    }

    fn inheritedRootPredicate(part: []const u8) bool {
        var attribute_depth: usize = 0;
        var quote: u8 = 0;
        for (part, 0..) |byte, at| {
            if (quote != 0) {
                if (byte == quote) quote = 0;
                continue;
            }
            if (byte == '\'' or byte == '"') { quote = byte; continue; }
            if (byte == '[') { attribute_depth += 1; continue; }
            if (byte == ']') { attribute_depth -|= 1; continue; }
            if (attribute_depth != 0 or byte != ':') continue;
            // These computed predicates can inherit from the unknown root even
            // when their necessary own tag excludes the content DIV.
            const tail = part[at..];
            if ((tail.len >= 5 and std.ascii.eqlIgnoreCase(tail[0..5], ":dir(")) or
                (tail.len >= 6 and std.ascii.eqlIgnoreCase(tail[0..6], ":lang("))) return true;
        }
        return false;
    }

    fn numericNthArgument(raw: []const u8) bool {
        const value = trim(raw);
        if (std.ascii.eqlIgnoreCase(value, "odd") or std.ascii.eqlIgnoreCase(value, "even")) return true;
        var at: usize = if (value.len != 0 and (value[0] == '+' or value[0] == '-')) 1 else 0;
        if (at == value.len) return false;
        while (at < value.len) : (at += 1) if (!std.ascii.isDigit(value[at])) return false;
        return true;
    }

    fn functionalRootPredicateUnresolved(self: *Builder, part: []const u8, subject_may_be_root: bool, depth: usize) std.mem.Allocator.Error!bool {
        if (depth == 16) return true;
        var at: usize = 0;
        var attribute_depth: usize = 0;
        var quote: u8 = 0;
        while (at < part.len) : (at += 1) {
            const byte = part[at];
            if (quote != 0) { if (byte == quote) quote = 0; continue; }
            if (byte == '\'' or byte == '"') { quote = byte; continue; }
            if (byte == '[') { attribute_depth += 1; continue; }
            if (byte == ']') { attribute_depth -|= 1; continue; }
            if (attribute_depth != 0 or byte != ':') continue;
            const name_start = at + 1;
            const name_end = identifierEnd(part, name_start);
            if (name_end == name_start or name_end == part.len or part[name_end] != '(') continue;
            const name = part[name_start..name_end];
            var end = name_end + 1;
            var nesting: usize = 1;
            var argument_quote: u8 = 0;
            while (end < part.len) : (end += 1) {
                const c = part[end];
                if (argument_quote != 0) { if (c == argument_quote) argument_quote = 0; continue; }
                if (c == '\'' or c == '"') { argument_quote = c; continue; }
                if (c == '(') { nesting += 1; if (nesting > 16) return true; }
                if (c == ')') { nesting -= 1; if (nesting == 0) break; }
            }
            if (end == part.len) return true;
            const arguments = part[name_end + 1 .. end];
            const selector_arguments = std.ascii.eqlIgnoreCase(name, "is") or std.ascii.eqlIgnoreCase(name, "where") or
                std.ascii.eqlIgnoreCase(name, "not") or std.ascii.eqlIgnoreCase(name, "has");
            const nth_arguments = std.ascii.eqlIgnoreCase(name, "nth-child") or std.ascii.eqlIgnoreCase(name, "nth-last-child") or
                std.ascii.eqlIgnoreCase(name, "nth-of-type") or std.ascii.eqlIgnoreCase(name, "nth-last-of-type");
            if (nth_arguments) {
                if (!numericNthArgument(arguments)) return true;
                at = end; continue;
            }
            if (!selector_arguments) return true;
            // Is/where/not retain the enclosing subject constraint. Relative
            // has() arguments keep the conservative unknown subject instead.
            // Earlier compounds can still refer to the unknown root.
            // This is only a dependency proof, never functional matching support.
            if (try self.contentRootPredicateAt(arguments, true, subject_may_be_root or std.ascii.eqlIgnoreCase(name, "has"), depth + 1)) return true;
            at = end;
        }
        return false;
    }

    // Inspect original compounds before a fallback keeps only the terminal.
    // This records uncertainty only; it never supplies selector match authority.
    fn contentRootPredicateUnresolved(self: *Builder, raw: []const u8, reduced_ancestry: bool) std.mem.Allocator.Error!bool {
        return self.contentRootPredicateAt(raw, reduced_ancestry, true, 0);
    }

    fn contentRootPredicateAt(self: *Builder, raw: []const u8, reduced_ancestry: bool, subject_may_be_root: bool, depth: usize) std.mem.Allocator.Error!bool {
        if (depth == 16) return true;
        const ltr: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
        const rtl: TextElement = .{ .tag = "div", .classes = "mw-content-rtl mw-parser-output" };
        const text = trim(raw);
        if (text.len == 0) return true;
        const root_first_only = depth == 0 and try self.contentRootSubjectExcluded(text);
        var pos: usize = 0;
        while (pos < text.len) {
            const end = figureCompoundEnd(text, pos, true) orelse return true;
            if (end == pos) return true;
            const part = text[pos..end];
            if (inheritedRootPredicate(part)) return true;
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c>+~", text[next]) != null) : (next += 1) {}
            // Only a validated complete top-level chain proves the selected
            // content root must be first. Functional arguments retain separate
            // conservative subject/ancestor rules; inherited predicates above
            // are never discharged by this position constraint.
            const may_be_root = (!root_first_only or pos == 0) and (next != text.len or subject_may_be_root);
            const exact = try self.paintCompound(part, true);
            const necessary = exact orelse try self.paintCompound(part, false) orelse {
                if (may_be_root or try self.functionalRootPredicateUnresolved(part, false, depth)) return true;
                pos = next; continue;
            };
            const compound: TextCompound = .{ .tag = necessary.tag, .classes = necessary.classes, .ids = necessary.ids };
            const match_ltr = may_be_root and compound.matches(&ltr);
            const match_rtl = may_be_root and compound.matches(&rtl);
            if (exact == null and (match_ltr or match_rtl)) return true;
            if (reduced_ancestry and match_ltr != match_rtl) return true;
            if (try self.functionalRootPredicateUnresolved(part, match_ltr or match_rtl, depth)) return true;
            pos = next;
        }
        return false;
    }

    fn uncertainFigureSelector(self: *Builder, raw: []const u8) !TextSelector {
        var result = try self.uncertainTextSelector(raw);
        result.root_predicate_unresolved = try self.contentRootPredicateUnresolved(raw, true);
        result.root_subject_excluded = try self.contentRootSubjectExcluded(raw);
        result.caption_subject_tag = try self.figureSubjectTag(raw);
        return result;
    }

    // This positive token predicate is needed by Linker's generated figure
    // type. Other operators, escapes, modifiers and extra predicates stay on
    // the existing uncertain path; no attributes are inferred for source HTML.
    fn figureTypeofCompound(self: *Builder, raw: []const u8) !?TextCompound {
        const opening = std.mem.indexOfScalar(u8, raw, '[') orelse return null;
        if (opening == 0 or raw[raw.len - 1] != ']') return null;
        const base = try self.paintCompound(raw[0..opening], true) orelse return null;
        var predicate = trim(raw[opening + 1 .. raw.len - 1]);
        const name_end = identifierEnd(predicate, 0);
        if (!std.ascii.eqlIgnoreCase(predicate[0..name_end], "typeof")) return null;
        predicate = trim(predicate[name_end..]);
        if (!std.mem.startsWith(u8, predicate, "~=")) return null;
        predicate = trim(predicate[2..]);
        if (predicate.len < 2 or (predicate[0] != '\'' and predicate[0] != '"') or predicate[predicate.len - 1] != predicate[0]) return null;
        const token = predicate[1 .. predicate.len - 1];
        if (!std.mem.eql(u8, token, "mw:File/Thumb") and !std.mem.eql(u8, token, "mw:File/Frame")) return null;
        if (token.len == 0 or !std.unicode.utf8ValidateSlice(token)) return null;
        for (token) |byte| if (std.mem.indexOfScalar(u8, " \t\r\n\x0c\\\"'", byte) != null or byte == 0) return null;
        return .{ .tag = base.tag, .classes = base.classes, .ids = base.ids, .typeof_token = try self.a.dupe(u8, token) };
    }

    // Attribute predicates remain unsupported. Retain only positive literal
    // class/ID constraints in this same compound, never text inside a value.
    fn figureNecessaryCompound(self: *Builder, text: []const u8) !?PaintCompound {
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, '\\') != null or std.mem.indexOf(u8, text, "/*") != null) return null;
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.a);
        var pos: usize = 0;
        var attributes: usize = 0;
        while (pos < text.len) {
            if (text[pos] != '[') {
                if (text[pos] == ':' or text[pos] == ']' or std.ascii.isWhitespace(text[pos])) return null;
                try clean.append(self.a, text[pos]); pos += 1; continue;
            }
            var end = pos + 1;
            var quote: u8 = 0;
            while (end < text.len) : (end += 1) {
                const byte = text[end];
                if (byte < 0x20 or byte == 0x7f) return null;
                if (quote != 0) { if (byte == quote) quote = 0; continue; }
                if (byte == '\'' or byte == '"') { quote = byte; continue; }
                if (byte == ']') break;
                if (byte == '[' or byte == '(' or byte == ')') return null;
            }
            if (end == text.len or quote != 0) return null;
            var value = trim(text[pos + 1 .. end]);
            if (value.len == 0 or !paintIdentifierStart(value, 0)) return null;
            const name_end = paintIdentifierEnd(value, 0);
            value = trim(value[name_end..]);
            if (value.len != 0) {
                if (value[0] == '=') value = trim(value[1..]) else {
                    if (value.len < 2 or std.mem.indexOfScalar(u8, "~|^$*", value[0]) == null or value[1] != '=') return null;
                    value = trim(value[2..]);
                }
                if (value.len == 0) return null;
                var value_end: usize = 0;
                if (value[0] == '\'' or value[0] == '"') {
                    value_end = 1;
                    while (value_end < value.len and value[value_end] != value[0]) : (value_end += 1) {}
                    if (value_end == value.len) return null;
                    value_end += 1;
                } else {
                    if (!paintIdentifierStart(value, 0)) return null;
                    value_end = paintIdentifierEnd(value, 0);
                }
                const modifier = trim(value[value_end..]);
                if (modifier.len != 0 and !std.ascii.eqlIgnoreCase(modifier, "i") and !std.ascii.eqlIgnoreCase(modifier, "s")) return null;
            }
            attributes += 1; pos = end + 1;
            // A second type token after an attribute is not a class suffix.
            if (pos < text.len and text[pos] != '[' and text[pos] != '.' and text[pos] != '#') return null;
        }
        if (clean.items.len == 0) return if (attributes != 0) PaintCompound{} else null;
        return self.paintCompound(clean.items, true);
    }

    // The finite dependency grammar accepts simple lang() and a simple not()
    // argument only to bound the chain. Its argument never supplies positives.
    fn figureSubjectCompound(self: *Builder, text: []const u8) !?PaintCompound {
        if (try self.figureNecessaryCompound(text)) |value| return value;
        const opening = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const name_end = paintIdentifierEnd(text, opening + 1);
        if (name_end == opening + 1 or name_end == text.len or text[name_end] != '(' or text[text.len - 1] != ')') return null;
        const name = text[opening + 1 .. name_end];
        const argument = text[name_end + 1 .. text.len - 1];
        if (std.ascii.eqlIgnoreCase(name, "lang")) {
            if (argument.len == 0 or !std.ascii.isAlphabetic(argument[0]) or !std.ascii.isAlphabetic(argument[argument.len - 1])) return null;
            for (argument) |byte| if (!std.ascii.isAlphabetic(byte) and byte != '-') return null;
        } else if (std.ascii.eqlIgnoreCase(name, "not")) {
            if (try self.paintCompound(argument, true) == null) return null;
        } else return null;
        if (opening == 0) return PaintCompound{};
        return self.figureNecessaryCompound(text[0..opening]);
    }

    fn figureSubjectTag(self: *Builder, raw: []const u8) !?[]const u8 {
        const text = trim(raw);
        var pos: usize = 0;
        while (pos < text.len) {
            const end = figureCompoundEnd(text, pos, true) orelse return null;
            if (end == pos) return null;
            const compound = try self.figureSubjectCompound(text[pos..end]) orelse return null;
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
            if (next == text.len) return compound.tag;
            if (std.mem.indexOfScalar(u8, ">+~", text[next]) != null) {
                next += 1;
                while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
                if (next == text.len) return null;
            } else if (next == end) return null;
            pos = next;
        }
        return null;
    }

    fn languageClassCompound(self: *Builder, raw: []const u8) !?PaintCompound {
        const opening = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
        if (raw.len - opening < 8 or !std.ascii.eqlIgnoreCase(raw[opening .. opening + 6], ":lang(")) return null;
        const closing = std.mem.indexOfScalarPos(u8, raw, opening + 6, ')') orelse return null;
        const language = raw[opening + 6 .. closing];
        if (language.len == 0 or !std.ascii.isAlphabetic(language[0]) or !std.ascii.isAlphabetic(language[language.len - 1])) return null;
        for (language) |byte| if (!std.ascii.isAlphabetic(byte) and byte != '-') return null;
        const prefix = raw[0..opening];
        const suffix = raw[closing + 1 ..];
        if (prefix.len != 0 and try self.paintCompound(prefix, true) == null) return null;
        if (suffix.len != 0 and suffix[0] != '.' and suffix[0] != '#') return null;
        const compound = try self.paintCompound(try std.mem.concat(self.a, u8, &.{ prefix, suffix }), true) orelse return null;
        return if (compound.classes.len != 0) compound else null;
    }

    fn figureSelector(self: *Builder, raw: []const u8, conditional: bool) !TextSelector {
        if (bareLanguageRange(raw)) |range| {
            var language_selector = try self.uncertainFigureSelector(raw);
            language_selector.language_range = try self.a.dupe(u8, range);
            return language_selector;
        }
        var chain: std.ArrayList(TextCompound) = .empty;
        var uncertain = conditional;
        var specificity: u64 = 0;
        const text = trim(raw);
        var pos: usize = 0;
        var child = false;
        var has_child = false;
        var has_descendant = false;
        while (pos < text.len) {
            const end = figureCompoundEnd(text, pos, false) orelse return self.uncertainFigureSelector(raw);
            if (end == pos) return self.uncertainFigureSelector(raw);
            const part = text[pos..end];
            const typed = try self.figureTypeofCompound(part);
            const exact = if (typed == null) try self.paintCompound(part, true) else null;
            const language_compound = if (typed == null and exact == null) try self.languageClassCompound(part) else null;
            const necessary = if (typed == null and exact == null) language_compound orelse try self.figureNecessaryCompound(part) orelse try self.paintCompound(part, false) else null;
            const compound: TextCompound = typed orelse if (exact orelse necessary) |value|
                .{ .tag = value.tag, .classes = value.classes, .ids = value.ids }
            else return self.uncertainFigureSelector(raw);
            if (typed == null and exact == null) uncertain = true;
            if (chain.items.len != 0) {
                has_child = has_child or child;
                has_descendant = has_descendant or !child;
                if (has_child and has_descendant) return self.uncertainFigureSelector(raw);
            }
            try chain.append(self.a, compound);
            specificity += (@as(u64, @intCast(compound.ids.len)) << 42) + (@as(u64, @intCast(compound.classes.len + @as(usize, @intFromBool(compound.typeof_token != null)))) << 21) + @intFromBool(compound.tag != null);
            pos = end;
            while (pos < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) != null) : (pos += 1) {}
            if (pos == text.len) break;
            child = text[pos] == '>';
            if (child) {
                pos += 1;
                while (pos < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) != null) : (pos += 1) {}
                if (pos == text.len) return self.uncertainFigureSelector(raw);
            }
        }
        const language_guard = if (chain.items.len == 1) try self.languageClassCompound(text) else null;
        return .{ .chain = chain.items, .specificity = if (uncertain) std.math.maxInt(u64) else specificity, .uncertain = uncertain or chain.items.len == 0, .direct_children = has_child, .root_predicate_unresolved = try self.contentRootPredicateUnresolved(raw, false), .root_subject_excluded = chain.items.len > 1,
            .caption_class_guard = if (language_guard) |value| value.classes else &.{}, .caption_subject_tag = try self.figureSubjectTag(raw) };
    }

    fn figureRootAlignmentOnly(self: *Builder, css: []const u8) !bool {
        var pos: usize = 0;
        var seen = false;
        while (try nextDeclarationAlloc(self.a, css, &pos)) |raw| {
            if (trim(raw).len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
            if (!std.ascii.eqlIgnoreCase(trim(raw[0..colon]), "text-align")) return false;
            const parsed = customPriority(raw[colon + 1 ..]);
            if (parsed.unknown) return false;
            const value = trim(parsed.value);
            var known = false;
            for ([_][]const u8{ "left", "right", "center", "justify", "start", "end" }) |name|
                known = known or std.ascii.eqlIgnoreCase(value, name);
            if (!known) return false;
            seen = true;
        }
        return seen;
    }

    // The complete content root supplies the normal-body font basis. The
    // matched primary Figure/figcaption rules reset inherited line-height.
    // Other outer effects (notably color and font-family) remain uncomputed.
    fn figureLanguageBaselineOnly(self: *Builder, css: []const u8) !bool {
        var pos: usize = 0;
        var seen = false;
        while (try nextDeclarationAlloc(self.a, css, &pos)) |raw| {
            if (trim(raw).len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
            const name = trim(raw[0..colon]);
            const parsed = customPriority(raw[colon + 1 ..]);
            if (parsed.unknown) return false;
            const value = trim(parsed.value);
            if (std.ascii.eqlIgnoreCase(name, "font-size")) {
                const size = fontSizeValue(name, value) orelse return false;
                if (size != .relative) return false;
            } else if (std.ascii.eqlIgnoreCase(name, "line-height")) {
                if (!widthNumberSyntax(value) or (value.len != 0 and value[0] == '-')) return false;
                const number = std.fmt.parseFloat(f64, value) catch return false;
                if (!std.math.isFinite(number) or number < 0) return false;
            } else return false;
            seen = true;
        }
        return seen;
    }
    fn appendFigureRules(self: *Builder, prelude: []const u8, css: []const u8, conditional: bool, order: u32) !void {
        // Custom definitions contribute through var() consumers, not as direct
        // Figure declarations. Preserve those consumers and their uncertainty.
        var declaration_pos: usize = 0;
        var relevant = false;
        while (try nextDeclarationAlloc(self.a, css, &declaration_pos)) |raw| {
            if (trim(raw).len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse { relevant = true; break; };
            if (!customName(trim(raw[0..colon]))) { relevant = true; break; }
        }
        if (!relevant) return;
        const root_alignment_only = try self.figureRootAlignmentOnly(css);
        const language_baseline_only = try self.figureLanguageBaselineOnly(css);
        // Uncertain text selectors use the display terminal scanner, but this
        // separate inventory must not grow the legacy display-class catalogue.
        const display_count = self.display_classes.items.len;
        defer self.display_classes.items.len = display_count;
        var parts: SelectorList = .{ .source = prelude };
        var selectors: std.ArrayList(TextSelector) = .empty;
        var uncertain_list = false;
        while (try parts.nextAlloc(self.a)) |part| {
            const selector_value = try self.figureSelector(part, conditional);
            uncertain_list = uncertain_list or selector_value.uncertain;
            try selectors.append(self.a, selector_value);
        }
        for (selectors.items) |selector_value| {
            var selected = selector_value;
            if (uncertain_list) { selected.uncertain = true; selected.specificity = std.math.maxInt(u64); }
            if (self.figure_rules.items.len == max_rules) return error.StyleProfileLimit;
            try self.figure_rules.append(self.a, .{ .selector = selected, .css = css, .order = order, .figure_root_alignment_only = root_alignment_only, .figure_language_baseline_only = language_baseline_only });
        }
    }

    fn displayClassId(self: *Builder, name: []const u8) !u32 {
        for (self.display_classes.items, 0..) |prior, i| if (std.mem.eql(u8, prior, name)) return @intCast(i);
        // IDs and selector occurrences are bounded by the aggregate CSS byte limit.
        // Sparse membership does not consume the independent table-paint scope.
        try self.display_classes.append(self.a, try self.a.dupe(u8, name));
        return @intCast(self.display_classes.items.len - 1);
    }

    fn displayIdentifierStart(text: []const u8, pos: usize) bool {
        if (pos == text.len) return false;
        if (std.ascii.isAlphabetic(text[pos]) or text[pos] == '_') return true;
        if (text[pos] != '-' or pos + 1 == text.len) return false;
        return std.ascii.isAlphabetic(text[pos + 1]) or text[pos + 1] == '_' or text[pos + 1] == '-';
    }

    fn displaySelector(self: *Builder, raw: []const u8, conditional: bool) !DisplaySelector {
        const text = trim(raw);
        // A comment inside a selector can alter token boundaries. The existing
        // parser preserves it; do not infer a tag from its comment contents.
        if (std.mem.indexOf(u8, text, "/*") != null)
            return .{ .uncertain = true, .specificity = std.math.maxInt(u32) };
        // Simple type/class/ID selectors are exact. For combinators or unknown
        // syntax, retain only necessary conditions from the final compound.
        // A possible override stays unknown and can never authorize hiding.
        var start: usize = 0;
        var depth: usize = 0;
        var quote: u8 = 0;
        var pos: usize = 0;
        while (pos < text.len) : (pos += 1) {
            const byte = text[pos];
            if (byte == '\\') {
                pos += 1;
                continue;
            }
            if (quote != 0) {
                if (byte == quote) quote = 0;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
            } else if (byte == '(' or byte == '[') {
                depth += 1;
            } else if (byte == ')' or byte == ']') {
                depth -|= 1;
            } else if (depth == 0 and (std.ascii.isWhitespace(byte) or byte == '>' or byte == '+' or byte == '~')) {
                start = pos + 1;
            }
        }
        const tail = trim(text[start..]);
        var result: DisplaySelector = .{ .uncertain = conditional or start != 0 };
        var classes: std.ArrayList(u32) = .empty;
        defer classes.deinit(self.a);
        var class_count: u32 = 0;
        pos = 0;
        if (tail.len != 0 and (std.ascii.isAlphabetic(tail[0]) or tail[0] == '_')) {
            const end = identifierEnd(tail, 0);
            if (end == tail.len or std.mem.indexOfScalar(u8, ".#:[", tail[end]) != null) {
                result.tag = try self.a.dupe(u8, tail[0..end]);
                result.specificity += 1;
                pos = end;
            }
        } else if (tail.len != 0 and tail[0] == '*') pos = 1;
        while (pos < tail.len and (tail[pos] == '.' or tail[pos] == '#')) {
            const kind = tail[pos];
            pos += 1;
            if (!displayIdentifierStart(tail, pos)) {
                result.uncertain = true;
                break;
            }
            const end = identifierEnd(tail, pos);
            // Only a proved token boundary makes this ASCII prefix a necessary
            // condition; escapes, non-ASCII and replaced NUL can extend it.
            if (end < tail.len and std.mem.indexOfScalar(u8, ".#:[", tail[end]) == null) break;
            if (kind == '.') {
                try classes.append(self.a, try self.displayClassId(tail[pos..end]));
                // Pack the exact lexicographic ID/class/type tuple. Only one
                // ID and one type are admitted; larger class counts stay
                // uncertain instead of carrying into the ID component.
                class_count += 1;
                if (class_count <= 65535) result.specificity += 1 << 8 else result.uncertain = true;
            } else {
                if (result.id != null) break;
                result.id = try self.a.dupe(u8, tail[pos..end]);
                result.specificity += 1 << 24;
            }
            pos = end;
        }
        // Only the current compound's positive attribute can supply this
        // necessary condition. Functions, escaped syntax and sibling/nesting
        // relations retain the old uncertainty without an absence shortcut.
        if (pos < tail.len and tail[pos] == '[' and std.mem.indexOfAny(u8, text, "\\()+~|&\x00") == null) {
            if (requiredOwnAttribute(tail[pos..])) |name| {
                result.required_own_attribute = try self.a.dupe(u8, name);
            }
        }
        if (pos != tail.len or tail.len == 0) result.uncertain = true;
        if (result.uncertain) result.specificity = std.math.maxInt(u32);
        result.classes = try classes.toOwnedSlice(self.a);
        return result;
    }

    fn appendDisplayRules(self: *Builder, prelude: []const u8, css: []const u8, conditional: bool, order: u32) !void {
        var selectors: std.ArrayList(DisplaySelector) = .empty;
        var parts: SelectorList = .{ .source = prelude };
        var uncertain = false;
        while (try parts.nextAlloc(self.a)) |raw| {
            if (self.display_rules.items.len + selectors.items.len == max_rules) return error.StyleProfileLimit;
            const selector_value = try self.displaySelector(raw, conditional);
            uncertain = uncertain or selector_value.uncertain;
            try selectors.append(self.a, selector_value);
        }
        // A non-forgiving selector list is invalid if any branch is invalid.
        // Until every branch is proved, even an exact matching branch cannot
        // authorize hiding. Keep necessary conditions for potential overrides.
        if (uncertain) self.unsupported = true;
        for (selectors.items) |original| {
            var selector_value = original;
            if (uncertain) {
                selector_value.uncertain = true;
                selector_value.specificity = std.math.maxInt(u32);
            }
            try self.display_rules.append(self.a, .{ .selector = selector_value, .css = css, .order = order });
        }
    }

    fn classBit(self: *Builder, name: []const u8) !Scope {
        for (self.classes.items, 0..) |prior, i| if (std.mem.eql(u8, prior, name)) return @as(Scope, 1) << @intCast(i);
        if (self.classes.items.len + self.ancestor_classes.items.len == 64) return error.StyleProfileLimit;
        try self.classes.append(self.a, try self.a.dupe(u8, name));
        return @as(Scope, 1) << @intCast(self.classes.items.len - 1);
    }

    fn ancestorClassBit(self: *Builder, name: []const u8) !Scope {
        for (self.ancestor_classes.items, 0..) |prior, i| if (std.mem.eql(u8, prior, name)) return @as(Scope, 1) << @intCast(i);
        if (self.classes.items.len + self.ancestor_classes.items.len == 64) return error.StyleProfileLimit;
        try self.ancestor_classes.append(self.a, try self.a.dupe(u8, name));
        return @as(Scope, 1) << @intCast(self.ancestor_classes.items.len - 1);
    }

    const PaintCompound = struct { tag: ?[]const u8 = null, classes: []const []const u8 = &.{}, ids: []const []const u8 = &.{} };

    fn paintIdentifierStart(text: []const u8, pos: usize) bool {
        if (pos == text.len) return false;
        if (std.ascii.isAlphabetic(text[pos]) or text[pos] == '_' or text[pos] >= 0x80) return true;
        if (text[pos] != '-' or pos + 1 == text.len) return false;
        return std.ascii.isAlphabetic(text[pos + 1]) or text[pos + 1] == '_' or text[pos + 1] == '-' or text[pos + 1] >= 0x80;
    }

    fn paintIdentifierEnd(text: []const u8, start: usize) usize {
        var pos = start;
        while (pos < text.len and (std.ascii.isAlphanumeric(text[pos]) or text[pos] == '_' or text[pos] == '-' or text[pos] >= 0x80)) : (pos += 1) {}
        return pos;
    }

    fn paintCompound(self: *Builder, text: []const u8, exact: bool) !?PaintCompound {
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
        var pos: usize = 0;
        var result: PaintCompound = .{};
        var names: std.ArrayList([]const u8) = .empty;
        var ids: std.ArrayList([]const u8) = .empty;
        if (text[0] == '*') {
            pos = 1;
        } else if (paintIdentifierStart(text, 0)) {
            const end = paintIdentifierEnd(text, 0);
            result.tag = try self.a.dupe(u8, text[0..end]);
            pos = end;
        }
        // A leading nonfunctional pseudo leaves this compound uncertain, but
        // does not erase positive ancestor compounds or a following class/ID.
        // Never inspect function arguments, escaped names, or pseudo-elements
        // as positive evidence. Exact mode continues to reject every pseudo.
        if (!exact and pos == 0) {
            while (pos < text.len and text[pos] == ':') {
                if (!paintIdentifierStart(text, pos + 1)) return null;
                const end = paintIdentifierEnd(text, pos + 1);
                if (end < text.len and text[end] != '.' and text[end] != '#' and text[end] != ':') return null;
                pos = end;
            }
        }
        while (pos < text.len and (text[pos] == '.' or text[pos] == '#')) {
            const is_id = text[pos] == '#';
            if (!paintIdentifierStart(text, pos + 1)) {
                if (exact) return null;
                result.classes = try names.toOwnedSlice(self.a);
                result.ids = try ids.toOwnedSlice(self.a);
                return result;
            }
            const end = paintIdentifierEnd(text, pos + 1);
            // Unproved escapes/namespace continuations cannot grant a necessary
            // identifier prefix. Pseudos/attributes keep only a proved prefix.
            if (end < text.len and text[end] != '.' and text[end] != '#' and text[end] != ':' and text[end] != '[') return null;
            const name = try self.a.dupe(u8, text[pos + 1 .. end]);
            if (is_id) try ids.append(self.a, name) else try names.append(self.a, name);
            pos = end;
        }
        if (pos == 0 or (exact and pos != text.len)) return null;
        if (pos < text.len and text[pos] != '#' and text[pos] != ':' and text[pos] != '[' and text[pos] != '.') return null;
        result.classes = try names.toOwnedSlice(self.a);
        result.ids = try ids.toOwnedSlice(self.a);
        return result;
    }

    fn paintTarget(tag: ?[]const u8) Target {
        const name = tag orelse return .element;
        if (std.ascii.eqlIgnoreCase(name, "table")) return .table;
        if (std.ascii.eqlIgnoreCase(name, "th")) return .th;
        if (std.ascii.eqlIgnoreCase(name, "td")) return .td;
        return .other;
    }

    fn uncertainPaintSelector(self: *Builder, text: []const u8) !?Selector {
        // Unknown syntax remains a possible override. Keep only necessary
        // prefixes, never use them to claim that an unsupported selector matches.
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOf(u8, text, "/*") != null or std.mem.indexOfScalar(u8, text, '\\') != null or std.mem.indexOfScalar(u8, text, 0) != null)
            return .{ .target = .element, .mask = 0, .specificity = std.math.maxInt(u64), .unsupported = true };
        var ancestors: std.ArrayList([]const u8) = .empty;
        defer ancestors.deinit(self.a);
        var safe_ancestors = true;
        var start: usize = 0;
        var depth: usize = 0;
        var quote: u8 = 0;
        for (text, 0..) |byte, pos| {
            if (quote != 0) {
                if (byte == quote) quote = 0;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                if (depth == 0) safe_ancestors = false;
                quote = byte;
            } else if (byte == '(' or byte == '[') depth += 1 else if (byte == ')' or byte == ']') {
                if (depth == 0) safe_ancestors = false;
                depth -|= 1;
            } else if (depth == 0 and (std.ascii.isWhitespace(byte) or byte == '>' or byte == '+' or byte == '~')) {
                if (pos > start) if (try self.paintCompound(trim(text[start..pos]), false)) |prefix| {
                    try ancestors.appendSlice(self.a, prefix.classes);
                };
                // A class on a sibling is not necessarily on this element or
                // its ancestors. Retain the old uncertainty for that whole chain.
                if (byte == '+' or byte == '~') safe_ancestors = false;
                start = pos + 1;
            } else if (depth == 0 and (byte == '|' or byte == '&')) safe_ancestors = false;
        }
        const necessary: []const []const u8 = if (safe_ancestors and depth == 0 and quote == 0) try ancestors.toOwnedSlice(self.a) else &.{};
        if (try self.paintCompound(trim(text[start..]), false)) |last| {
            return .{ .target = paintTarget(last.tag), .mask = 0, .own_classes = last.classes, .own_ids = last.ids, .necessary_classes = necessary, .specificity = std.math.maxInt(u64), .unsupported = true };
        }
        return .{ .target = .element, .mask = 0, .necessary_classes = necessary, .specificity = std.math.maxInt(u64), .unsupported = true };
    }

    fn selector(self: *Builder, raw: []const u8, conditional: bool) !?Selector {
        const text = trim(raw);
        if (text.len == 0) return null;
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOf(u8, text, "/*") != null or std.mem.indexOfScalar(u8, text, '\\') != null or std.mem.indexOfScalar(u8, text, 0) != null)
            return self.uncertainPaintSelector(text);
        var chain: std.ArrayList(PaintCompound) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var specificity: u64 = 0;
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
        while (tokens.next()) |token| {
            const part = (try self.paintCompound(token, true)) orelse return self.uncertainPaintSelector(text);
            try chain.append(self.a, part);
            try names.appendSlice(self.a, part.classes);
            // Lexicographic ID/class/type counts, each bounded below 2^21 by
            // the one-MiB source limit. Repetition increases specificity; no
            // number of classes can outweigh one ID. Inline priority is separate.
            specificity += (@as(u64, @intCast(part.ids.len)) << 42) +
                (@as(u64, @intCast(part.classes.len)) << 21) + @as(u64, if (part.tag != null) 1 else 0);
        }
        const last = chain.items[chain.items.len - 1];
        var result: Selector = .{
            .target = paintTarget(last.tag),
            .mask = 0,
            .own_classes = last.classes,
            .own_ids = last.ids,
            .necessary_classes = try names.toOwnedSlice(self.a),
            .specificity = specificity,
            .unsupported = conditional,
        };
        if (chain.items.len == 1) {
            // Preserve the existing table-qualified ancestor mask for nested
            // cells and callers that supply scopes without textual ancestry.
            if (result.target == .table and last.classes.len == 1)
                result.mask = try self.classBit(last.classes[0]);
            return result;
        }
        if (chain.items.len == 2) {
            const first = chain.items[0];
            if (first.tag == null and first.ids.len == 0 and first.classes.len == 1) {
                result.ancestor_class = first.classes[0];
                // Preserve the established compact namespace for existing API
                // callers that supply the generic ancestor mask rather than text.
                if ((result.target == .th or result.target == .td) and last.classes.len == 0)
                    result.ancestor_mask = try self.ancestorClassBit(first.classes[0]);
                return result;
            }
            if (first.tag) |tag| if (std.ascii.eqlIgnoreCase(tag, "table") and first.ids.len == 0 and first.classes.len <= 1 and (result.target == .th or result.target == .td)) {
                if (first.classes.len == 1) result.mask = try self.classBit(first.classes[0]);
                return result;
            };
        }
        // A merged ancestor-class set cannot prove which tag/compound owns a
        // class or the chain order. Its complete absence can still disprove a
        // match; otherwise each affected property remains unknown.
        result.unsupported = true;
        result.specificity = std.math.maxInt(u64);
        return result;
    }

    fn seedSelector(self: *Builder, raw: []const u8) !void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, raw, pos, "table.")) |start| {
            const end = identifierEnd(raw, start + 6);
            if ((start == 0 or !std.ascii.isAlphanumeric(raw[start - 1])) and end > start + 6) _ = try self.classBit(raw[start + 6 .. end]);
            pos = @max(end, start + 6);
        }
    }

    fn parse(self: *Builder, css: []const u8, conditional: bool, depth: usize, seed: bool) anyerror!void {
        if (depth > 16) return error.StyleProfileLimit;
        var pos: usize = 0;
        while (true) {
            try skipSpaceComments(css, &pos);
            if (pos >= css.len) break;
            const start = pos;
            const boundary = try findBoundary(css, &pos);
            const prelude = trim(css[start .. pos - 1]);
            if (boundary == ';') {
                if (prelude.len == 0 or prelude[0] != '@') return error.InvalidStyleProfile;
                // Input is already decoded. CSS Syntax drops parsed charset
                // rules; they cannot change this sheet's element cascade.
                if (atRuleNamed(prelude, "charset")) continue;
                self.unsupported = true;
                self.globally_unresolved = true;
                continue;
            }
            if (boundary != '{') return error.InvalidStyleProfile;
            const body_start = pos;
            const end = try closingBrace(css, &pos);
            if (prelude.len != 0 and prelude[0] == '@') {
                self.unsupported = true;
                // Counter descriptors define marker strings, not element
                // declarations. Keep their unsupported status without erasing
                // unrelated table paint or interpreting the body as selectors.
                if (atRuleNamed(prelude, "counter-style")) continue;
                // Conditional groups may contain matching overrides; mark every
                // projected declaration unknown instead of guessing the condition.
                if (isConditionalGroup(prelude)) {
                    try self.parse(css[body_start..end], true, depth + 1, seed);
                } else self.globally_unresolved = true;
                continue;
            }
            if (seed) {
                try self.seedSelector(prelude);
                continue;
            }
            self.number += 1;
            if (self.number > max_rules) return error.StyleProfileLimit;
            var declarations: std.ArrayList(Declaration) = .empty;
            var declaration_pos: usize = 0;
            const display_order = self.declaration_order;
            var has_display = false;
            var has_alignment = false;
            var has_font = false;
            var has_text_paint = false;
            while (try nextDeclarationAlloc(self.a, css[body_start..end], &declaration_pos)) |raw| {
                if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
                    const property = trim(raw[0..colon]);
                    has_text_paint = has_text_paint or std.ascii.eqlIgnoreCase(property, "font-style") or std.ascii.eqlIgnoreCase(property, "color") or std.ascii.eqlIgnoreCase(property, "font-weight") or std.ascii.eqlIgnoreCase(property, "font") or std.ascii.eqlIgnoreCase(property, "all") or std.mem.indexOfScalar(u8, property, '\\') != null;
                    has_font = has_font or std.ascii.eqlIgnoreCase(property, "font-size") or std.ascii.eqlIgnoreCase(property, "font") or std.ascii.eqlIgnoreCase(property, "all") or std.mem.indexOfScalar(u8, property, '\\') != null;
                    has_alignment = has_alignment or std.ascii.eqlIgnoreCase(property, "text-align") or std.ascii.eqlIgnoreCase(property, "all") or std.mem.indexOfScalar(u8, property, '\\') != null;
                    has_display = has_display or std.ascii.eqlIgnoreCase(property, "display") or std.ascii.eqlIgnoreCase(property, "all") or std.mem.indexOfScalar(u8, property, '\\') != null;
                }
                self.declaration_order += 1;
                if (self.declaration_order >= max_rules * 1024) return error.StyleProfileLimit;
                if (try declarationAlloc(self.a, raw, self.declaration_order)) |declaration| try declarations.append(self.a, declaration);
            }
            if (has_display or has_alignment or has_font) try self.appendDisplayRules(prelude, try self.a.dupe(u8, css[body_start..end]), conditional, display_order);
            if (has_text_paint or has_font) try self.appendTextRules(prelude, try self.a.dupe(u8, css[body_start..end]), conditional, display_order);
            try self.appendTypedRules(&self.block_rules, prelude, try self.a.dupe(u8, css[body_start..end]), conditional, display_order);
            try self.appendFigureRules(prelude, try self.a.dupe(u8, css[body_start..end]), conditional, display_order);
            var selectors: SelectorList = .{ .source = prelude };
            var projected: std.ArrayList(Selector) = .empty;
            var list_uncertain = false;
            while (try selectors.nextAlloc(self.a)) |raw| {
                if (try self.selector(raw, conditional)) |selector_value| {
                    list_uncertain = list_uncertain or selector_value.unsupported;
                    try projected.append(self.a, selector_value);
                } else list_uncertain = true;
            }
            var admitted = has_display or has_alignment;
            for (projected.items) |parsed_selector| {
                var selector_value = parsed_selector;
                // One unproved selector branch can invalidate the whole list.
                // It may suppress a prior property, but cannot introduce paint.
                if (list_uncertain) {
                    selector_value.unsupported = true;
                    selector_value.specificity = std.math.maxInt(u64);
                }
                if (self.rules.items.len == max_rules) return error.StyleProfileLimit;
                if (selector_value.unsupported) self.unsupported = true;
                for (declarations.items) |declaration| if (declaration.value == .unsupported) { self.unsupported = true; };
                try self.rules.append(self.a, .{ .selector = selector_value, .declarations = declarations.items, .number = self.number });
                admitted = true;
            }
            if (admitted) try self.numbers.append(self.a, self.number);
        }
    }
};

// Split only CSS top-level list commas. Boundary comments may be omitted
// without changing tokens; embedded compound comments stay unsupported raw text.
const SelectorList = struct {
    source: []const u8,
    cursor: usize = 0,

    fn nextAlloc(self: *SelectorList, a: std.mem.Allocator) !?[]const u8 {
        if (self.cursor > self.source.len) return null;
        const start = self.cursor;
        var at = start;
        var copied_from = start;
        var changed = false;
        var leading = true;
        var quote: u8 = 0;
        var groups: [16]u8 = undefined;
        var depth: usize = 0;
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(a);
        while (at < self.source.len) {
            const byte = self.source[at];
            if (byte == '\\') {
                if (at + 1 == self.source.len) return error.InvalidStyleProfile;
                leading = false;
                at += 2;
                continue;
            }
            if (quote != 0) {
                if (byte == quote) quote = 0;
                at += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte; leading = false; at += 1; continue;
            }
            if (byte == '/' and at + 1 < self.source.len and self.source[at + 1] == '*') {
                const close = std.mem.indexOfPos(u8, self.source, at + 2, "*/") orelse return error.InvalidStyleProfile;
                const after = close + 2;
                const boundary = leading or after == self.source.len or
                    (depth == 0 and self.source[after] == ',') or
                    (at != start and std.ascii.isWhitespace(self.source[at - 1])) or
                    (after < self.source.len and std.ascii.isWhitespace(self.source[after]));
                if (boundary) {
                    try normalized.appendSlice(a, self.source[copied_from..at]);
                    copied_from = after;
                    changed = true;
                }
                at = after;
                continue;
            }
            if (depth == 0 and byte == ',') break;
            if (byte == '(' or byte == '[') {
                if (depth == groups.len) return error.StyleProfileLimit;
                groups[depth] = byte; depth += 1;
            } else if (byte == ')' or byte == ']') {
                if (depth == 0 or groups[depth - 1] != (if (byte == ')') @as(u8, '(') else '[')) return error.InvalidStyleProfile;
                depth -= 1;
            }
            if (!std.ascii.isWhitespace(byte)) leading = false;
            at += 1;
        }
        if (quote != 0 or depth != 0) return error.InvalidStyleProfile;
        self.cursor = at + 1; // Also preserve a final empty list branch once.
        if (!changed) return self.source[start..at];
        try normalized.appendSlice(a, self.source[copied_from..at]);
        return try normalized.toOwnedSlice(a);
    }
};

pub const Source = struct { css: []const u8, base_url: []const u8, byte_start: usize = 0 };
pub const SourceRange = struct {
    base_url: []const u8, byte_start: usize, bytes: usize, css_sha256: [64]u8,
    rule_begin: usize, rule_end: usize,
    pub fn jsonStringify(self: SourceRange, jw: anytype) !void {
        try jw.write(.{ .base_url = self.base_url, .byte_start = self.byte_start, .bytes = self.bytes,
            .css_sha256 = self.css_sha256[0..], .rule_begin = self.rule_begin, .rule_end = self.rule_end });
    }
};
pub fn parseAlloc(a: std.mem.Allocator, css: []const u8) !Profile {
    return parseSourcesAlloc(a, &.{.{ .css = css, .base_url = "" }});
}

// Parse every sheet/segment independently while preserving global declaration
// order and every repeated occurrence. Relative URL bases remain attached to
// their source; this profile admits no URL-valued presentation property.
pub fn parseSourcesAlloc(a: std.mem.Allocator, sources: []const Source) !Profile {
    var total: usize = 0;
    for (sources) |source| {
        total = std.math.add(usize, total, source.css.len) catch return error.StyleProfileLimit;
        if (total > max_css_bytes or source.base_url.len > 4096) return error.StyleProfileLimit;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var builder: Builder = .{ .a = arena.allocator() };
    for (sources) |source| try builder.parse(source.css, false, 0, true);
    var ranges: std.ArrayList(SourceRange) = .empty;
    for (sources) |source| {
        const first = builder.number + 1;
        try builder.parse(source.css, false, 0, false);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source.css, &digest, .{});
        try ranges.append(builder.a, .{ .base_url = try builder.a.dupe(u8, source.base_url),
            .byte_start = source.byte_start, .bytes = source.css.len, .css_sha256 = std.fmt.bytesToHex(digest, .lower),
            .rule_begin = first, .rule_end = builder.number + 1 });
    }
    return .{ .arena = arena, .sources = ranges.items, .rules = builder.rules.items, .classes = builder.classes.items, .ancestor_classes = builder.ancestor_classes.items, .admitted_rule_numbers = builder.numbers.items, .has_unsupported_rules = builder.unsupported, .globally_unresolved = builder.globally_unresolved, .text_rules = builder.text_rules.items, .block_rules = builder.block_rules.items, .figure_rules = builder.figure_rules.items, .display_rules = builder.display_rules.items, .display_classes = builder.display_classes.items };
}

fn atRuleNamed(prelude: []const u8, name: []const u8) bool {
    if (prelude.len == 0 or prelude[0] != '@') return false;
    const end = identifierEnd(prelude, 1);
    // Escaped identifiers need tokenization; decline them conservatively.
    if (end < prelude.len and (prelude[end] == '\\' or prelude[end] >= 0x80)) return false;
    return std.ascii.eqlIgnoreCase(prelude[1..end], name);
}

fn isConditionalGroup(prelude: []const u8) bool {
    const end = identifierEnd(prelude, 1);
    if (end < prelude.len and !std.ascii.isWhitespace(prelude[end]) and prelude[end] != '(') return false;
    const name = prelude[1..end];
    inline for (.{ "media", "supports", "layer", "container" }) |known| if (std.ascii.eqlIgnoreCase(name, known)) return true;
    return false;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n\x0c");
}
fn identifierEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == '_')) : (i += 1) {}
    return i;
}
fn skipSpaceComments(css: []const u8, pos: *usize) !void {
    while (pos.* < css.len) {
        if (std.ascii.isWhitespace(css[pos.*])) {
            pos.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, css[pos.*..], "/*")) {
            const close = std.mem.indexOfPos(u8, css, pos.* + 2, "*/") orelse return error.InvalidStyleProfile;
            pos.* = close + 2;
        } else return;
    }
}
fn findBoundary(css: []const u8, pos: *usize) !u8 {
    var quote: u8 = 0;
    var depth: usize = 0;
    while (pos.* < css.len) {
        const byte = css[pos.*];
        pos.* += 1;
        if (byte == '\\' and pos.* < css.len) {
            pos.* += 1;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '/' and pos.* < css.len and css[pos.*] == '*') {
            const close = std.mem.indexOfPos(u8, css, pos.* + 1, "*/") orelse return error.InvalidStyleProfile;
            pos.* = close + 2;
            continue;
        }
        if (byte == '(' or byte == '[') depth += 1;
        if (byte == ')' or byte == ']') {
            if (depth == 0) return error.InvalidStyleProfile;
            depth -= 1;
        }
        if (depth == 0 and (byte == '{' or byte == ';')) return byte;
    }
    return error.InvalidStyleProfile;
}
fn closingBrace(css: []const u8, pos: *usize) !usize {
    var depth: usize = 1;
    var quote: u8 = 0;
    while (pos.* < css.len) {
        const at = pos.*;
        const byte = css[at];
        pos.* += 1;
        if (byte == '\\' and pos.* < css.len) {
            pos.* += 1;
            continue;
        }
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '/' and pos.* < css.len and css[pos.*] == '*') {
            const close = std.mem.indexOfPos(u8, css, pos.* + 1, "*/") orelse return error.InvalidStyleProfile;
            pos.* = close + 2;
            continue;
        }
        if (byte == '{') depth += 1;
        if (byte == '}') {
            depth -= 1;
            if (depth == 0) return at;
        }
    }
    return error.InvalidStyleProfile;
}

// Numeric width is a requested HTML table border-box width, not a forced
// used width. Padding remains table-box padding, distinct from cell padding.
fn unresolvedTableWidthBox(winners: Winners) bool {
    return if (winners.value(.box_sizing)) |value| value != .border_box else false;
}
fn projectTableBox(style: *types.TableStyle, winners: Winners) void {
    if (!unresolvedTableWidthBox(winners)) if (winners.value(.width)) |value| if (value == .width_value) { style.width = value.width_value; };
    const collapse = winners.value(.collapse);
    if (collapse) |value| if (value == .collapse) { style.collapse = value.collapse; };
    // Without a proved border model, applying table padding would invent an
    // outer gap: collapsed tables do not apply table-box padding.
    if (collapse == null or collapse.? == .collapse)
        if (winners.value(.padding)) |value| if (value == .edges) { style.padding = value.edges; };
    if (winners.value(.clear)) |value| if (value == .clear_value) { style.clear = value.clear_value; };
}

fn representedProperty(target: Target, property: Property) bool {
    return switch (property) {
        .background, .border, .other, .layout_reset => true,
        .collapse, .margins, .margin_top, .margin_right, .margin_bottom, .margin_left, .float_side, .width, .clear, .box_sizing => target == .table,
        .padding => true,
        .text_align => target != .table,
    };
}

fn propertyFor(name: []const u8) ?Property {
    if (std.ascii.eqlIgnoreCase(name, "background") or std.ascii.eqlIgnoreCase(name, "background-color") or std.ascii.eqlIgnoreCase(name, "background-image")) return .background;
    if (std.ascii.eqlIgnoreCase(name, "border-collapse")) return .collapse;
    if (std.ascii.eqlIgnoreCase(name, "border") or std.ascii.startsWithIgnoreCase(name, "border-")) return .border;
    if (std.ascii.eqlIgnoreCase(name, "margin")) return .margins;
    inline for (.{ "margin-top", "margin-right", "margin-bottom", "margin-left" }, .{ Property.margin_top, .margin_right, .margin_bottom, .margin_left }) |edge, property| if (std.ascii.eqlIgnoreCase(name, edge)) return property;
    if (std.ascii.startsWithIgnoreCase(name, "margin-")) return .margins;
    if (std.ascii.eqlIgnoreCase(name, "float")) return .float_side;
    if (std.ascii.eqlIgnoreCase(name, "width")) return .width;
    if (std.ascii.eqlIgnoreCase(name, "clear")) return .clear;
    if (std.ascii.eqlIgnoreCase(name, "box-sizing")) return .box_sizing;
    if (std.ascii.eqlIgnoreCase(name, "all")) return .layout_reset;
    if (std.ascii.eqlIgnoreCase(name, "padding") or std.ascii.startsWithIgnoreCase(name, "padding-")) return .padding;
    if (std.ascii.eqlIgnoreCase(name, "text-align")) return .text_align;
    // These affect table/cell presentation but have no projection in this ABI.
    inline for (.{ "height", "min-width", "max-width", "min-height", "max-height", "display", "visibility", "position", "color", "font", "font-size", "font-family", "font-weight", "vertical-align", "table-layout", "border-spacing", "opacity", "transform", "all" }) |relevant| if (std.ascii.eqlIgnoreCase(name, relevant)) return .other;
    if (name.len == 0 or std.mem.startsWith(u8, name, "--")) return null;
    return .other;
}
fn dynamicValue(value: []const u8) bool {
    if (std.mem.indexOfAny(u8, value, "(%/") != null) return true;
    inline for (.{ "inherit", "initial", "unset", "revert", "revert-layer", "currentcolor", "transparent", "auto", "thin", "medium", "thick", "solid", "dotted", "dashed", "double", "groove", "ridge", "inset", "outset", "hidden" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    return false;
}
fn unrepresentedColorValue(value: []const u8) bool {
    if (dynamicValue(value) or std.ascii.eqlIgnoreCase(value, "none")) return true;
    if ((value.len == 5 or value.len == 9) and value[0] == '#') {
        for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return false;
        return true;
    }
    inline for (.{ "accentcolor", "accentcolortext", "activetext", "buttonborder", "buttonface", "buttontext", "canvas", "canvastext", "field", "fieldtext", "graytext", "highlight", "highlighttext", "linktext", "mark", "marktext", "selecteditem", "selecteditemtext", "visitedtext" }) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}

fn length(raw: []const u8) ?types.StyleLength {
    const value = trim(raw);
    if (std.mem.eql(u8, value, "0")) return .{ .unit = .px, .value = 0 };
    if (value.len <= 2) return null;
    const unit: types.StyleLengthUnit = if (std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) .px else if (std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "em")) .em else return null;
    const number = std.fmt.parseFloat(f32, value[0 .. value.len - 2]) catch return null;
    const result: types.StyleLength = .{ .unit = unit, .value = number };
    return if (types.validStyleLength(result)) result else null;
}
// CSS number grammar, independent of parseFloat extensions such as hex or
// digit separators. Unitless signed/fractional/exponent zero is valid width.
fn widthNumberSyntax(value: []const u8) bool {
    var at: usize = 0;
    if (at < value.len and (value[at] == '+' or value[at] == '-')) at += 1;
    const integer = at;
    while (at < value.len and std.ascii.isDigit(value[at])) : (at += 1) {}
    const has_integer = at != integer;
    var has_fraction = false;
    if (at < value.len and value[at] == '.') {
        at += 1;
        const fraction = at;
        while (at < value.len and std.ascii.isDigit(value[at])) : (at += 1) {}
        has_fraction = at != fraction;
        if (!has_fraction) return false;
    }
    if (!has_integer and !has_fraction) return false;
    if (at < value.len and (value[at] == 'e' or value[at] == 'E')) {
        at += 1;
        if (at < value.len and (value[at] == '+' or value[at] == '-')) at += 1;
        const exponent = at;
        while (at < value.len and std.ascii.isDigit(value[at])) : (at += 1) {}
        if (at == exponent) return false;
    }
    return at == value.len;
}
fn widthNumberIsZero(value: []const u8) bool {
    for (value) |byte| {
        if (byte == 'e' or byte == 'E') break;
        if (byte >= '1' and byte <= '9') return false;
    }
    return true;
}
fn styleWidth(raw: []const u8) ?types.StyleWidth {
    const value = trim(raw);
    var numeric = value;
    var unit: types.StyleWidthUnit = .px;
    var unitless = true;
    if (std.ascii.endsWithIgnoreCase(value, "px") or std.ascii.endsWithIgnoreCase(value, "em")) {
        numeric = value[0 .. value.len - 2];
        unit = if (std.ascii.endsWithIgnoreCase(value, "em")) .em else .px;
        unitless = false;
    } else if (std.mem.endsWith(u8, value, "%")) {
        numeric = value[0 .. value.len - 1];
        unit = .percent;
        unitless = false;
    }
    if (!widthNumberSyntax(numeric)) return null;
    const zero = widthNumberIsZero(numeric);
    if (unitless) return if (zero) .{ .unit = .px, .value = 0 } else null;
    if (numeric[0] == '-' and !zero) return null;
    const number = std.fmt.parseFloat(f32, numeric) catch return null;
    const parsed: types.StyleWidth = .{ .unit = unit, .value = number };
    return if (types.validStyleWidth(parsed)) parsed else null;
}
fn unsupportedWidth(value: []const u8) bool {
    inline for (.{ "min-content", "max-content", "fit-content", "stretch" }) |keyword|
        if (std.ascii.eqlIgnoreCase(value, keyword)) return true;
    if (std.mem.indexOfScalar(u8, value, '(') != null) return true;
    // Other valid numeric units, and finite-source values beyond f32, remain
    // winning unknowns. Negative dimensions and malformed numbers are invalid.
    inline for (.{ "px", "em", "rem", "ex", "ch", "vw", "vh", "vmin", "vmax", "cm", "mm", "in", "pt", "pc", "q", "%" }) |unit| {
        if (value.len > unit.len and std.ascii.endsWithIgnoreCase(value, unit)) {
            const numeric = value[0 .. value.len - unit.len];
            if (widthNumberSyntax(numeric)) {
                if (numeric[0] == '-' and !widthNumberIsZero(numeric)) return false;
                const number = std.fmt.parseFloat(f64, numeric) catch return false;
                return number >= 0;
            }
        }
    }
    return std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer");
}
fn edges(value: []const u8) ?types.StyleEdges {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var values: [4]types.StyleLength = undefined;
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count == 4) return null;
        values[count] = length(token) orelse return null;
        count += 1;
    }
    return switch (count) {
        1 => types.StyleEdges.all(values[0]),
        2 => .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] },
        3 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] },
        4 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
        else => null,
    };
}
fn unsupportedEdges(value: []const u8, negative_allowed: bool) bool {
    // Whole-value auto is valid only for margins, including the dynamic shortcut.
    if (std.ascii.eqlIgnoreCase(value, "auto")) return negative_allowed;
    if (dynamicValue(value)) return true;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var count: usize = 0;
    while (tokens.next()) |token| {
        count += 1;
        if (count > 4) return false;
        // Auto is valid in a margin shorthand but has no numeric edge
        // projection. Retain it as unresolved instead of dropping the rule.
        var recognized = negative_allowed and std.ascii.eqlIgnoreCase(token, "auto");
        const units = [_][]const u8{ "px", "em", "rem", "ex", "ch", "vw", "vh", "vmin", "vmax", "cm", "mm", "in", "pt", "pc", "q", "%" };
        for (units) |unit| {
            if (token.len > unit.len and std.ascii.endsWithIgnoreCase(token, unit)) {
                const number = std.fmt.parseFloat(f32, token[0 .. token.len - unit.len]) catch continue;
                if (std.math.isFinite(number) and (negative_allowed or number >= 0)) recognized = true;
            }
        }
        if (!recognized and !std.mem.eql(u8, token, "0")) return false;
    }
    return count != 0;
}

fn borderAlloc(a: std.mem.Allocator, value: []const u8) !?types.StyleBorder {
    if (std.ascii.eqlIgnoreCase(value, "none") or std.mem.eql(u8, value, "0")) return .none;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var width: ?types.StyleLength = null;
    var color: ?[]const u8 = null;
    var solid = false;
    var count: usize = 0;
    while (tokens.next()) |token| {
        count += 1;
        if (std.ascii.eqlIgnoreCase(token, "solid") and !solid) {
            solid = true;
        } else if (length(token)) |next| {
            if (width != null) return null;
            width = next;
        } else if (try canonicalColorAlloc(a, token)) |next| {
            if (color != null) return null;
            color = next;
        } else return null;
    }
    if (count != 3 or width == null or color == null or !solid) return null;
    return .{ .solid = .{ .width = width.?, .color = color.? } };
}
fn declarationAlloc(a: std.mem.Allocator, raw: []const u8, order: u32) !?Declaration {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
    const name = trim(raw[0..colon]);
    const property = propertyFor(name) orelse return null;
    var value = trim(raw[colon + 1 ..]);
    if (value.len == 0) return null;
    var important = false;
    if (std.mem.lastIndexOfScalar(u8, value, '!')) |bang| {
        if (std.ascii.eqlIgnoreCase(trim(value[bang + 1 ..]), "important")) {
            important = true;
            value = trim(value[0..bang]);
        } else if (!dynamicValue(value)) return null;
    }
    var projection: Value = .unsupported;
    switch (property) {
        .background => {
            if (!std.ascii.eqlIgnoreCase(name, "background-image")) {
                if (try canonicalColorAlloc(a, value)) |color| {
                    projection = .{ .color = color };
                } else if (!unrepresentedColorValue(value) and std.mem.indexOfAny(u8, value, " \t") == null) return null;
            }
        },
        .border => {
            if (std.ascii.eqlIgnoreCase(name, "border")) {
                if (try borderAlloc(a, value)) |next| {
                    projection = .{ .border = next };
                } else if (!dynamicValue(value) and std.mem.indexOfAny(u8, value, " \t") == null and length(value) == null and (try canonicalColorAlloc(a, value)) == null) return null;
            }
        },
        .collapse => {
            if (std.ascii.eqlIgnoreCase(value, "collapse")) {
                projection = .{ .collapse = .collapse };
            } else if (std.ascii.eqlIgnoreCase(value, "separate")) {
                projection = .{ .collapse = .separate };
            } else if (!dynamicValue(value)) return null;
        },
        .margins, .padding => {
            const shorthand = std.ascii.eqlIgnoreCase(name, if (property == .margins) "margin" else "padding");
            if (shorthand) {
                if (edges(value)) |next| {
                    projection = .{ .edges = next };
                } else if (!unsupportedEdges(value, property == .margins)) return null;
            }
        },
        .margin_top, .margin_right, .margin_bottom, .margin_left => {
            if (length(value)) |next| {
                projection = .{ .length_value = next };
            } else {
                var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
                _ = tokens.next();
                if (!dynamicValue(value) and (tokens.next() != null or !unsupportedEdges(value, true))) return null;
            }
        },
        .box_sizing => {
            if (std.ascii.eqlIgnoreCase(value, "border-box")) projection = .border_box
            else if (!(std.ascii.eqlIgnoreCase(value, "content-box") or dynamicValue(value))) return null;
        },
        .width => {
            if (styleWidth(value)) |next| {
                projection = .{ .width_value = next };
            } else if (std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) {
                projection = .auto_width;
            } else if (!unsupportedWidth(value)) return null;
        },
        .clear => {
            if (std.ascii.eqlIgnoreCase(value, "none") or std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) projection = .{ .clear_value = .none }
            else if (std.ascii.eqlIgnoreCase(value, "left")) projection = .{ .clear_value = .left }
            else if (std.ascii.eqlIgnoreCase(value, "right")) projection = .{ .clear_value = .right }
            else if (std.ascii.eqlIgnoreCase(value, "both")) projection = .{ .clear_value = .both };
            if (projection == .unsupported and !dynamicValue(value) and
                !std.ascii.eqlIgnoreCase(value, "inline-start") and !std.ascii.eqlIgnoreCase(value, "inline-end")) return null;
        },
        .float_side => {
            if (std.ascii.eqlIgnoreCase(value, "left")) projection = .{ .float_value = .left } else if (std.ascii.eqlIgnoreCase(value, "right")) projection = .{ .float_value = .right } else if (std.ascii.eqlIgnoreCase(value, "none")) projection = .no_float else if (std.ascii.eqlIgnoreCase(value, "inline-start") or std.ascii.eqlIgnoreCase(value, "inline-end") or dynamicValue(value)) {} else return null;
        },
        .text_align => {
            if (std.ascii.eqlIgnoreCase(value, "left")) {
                projection = .{ .align_value = .left };
            } else if (std.ascii.eqlIgnoreCase(value, "center")) {
                projection = .{ .align_value = .center };
            } else if (std.ascii.eqlIgnoreCase(value, "right")) {
                projection = .{ .align_value = .right };
            } else if (std.ascii.eqlIgnoreCase(value, "justify") or std.ascii.eqlIgnoreCase(value, "start") or std.ascii.eqlIgnoreCase(value, "end") or dynamicValue(value)) {} else return null;
        },
        .layout_reset => {
            if (!(std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset") or std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer") or std.ascii.startsWithIgnoreCase(value, "var(") or std.ascii.startsWithIgnoreCase(value, "env("))) return null;
        },
        .other => {},
    }
    return .{ .property = property, .value = projection, .important = important, .order = order, .affects_font_basis = std.ascii.eqlIgnoreCase(name, "font") or std.ascii.eqlIgnoreCase(name, "font-size") or std.ascii.eqlIgnoreCase(name, "all") };
}

// CSS Color 3 comma RGB: either three integer channels or three percentages.
// Project opaque sRGB to the existing 8-bit wire color; alpha/dynamic forms
// stay unsupported instead of discarding their opacity or dependencies.
fn legacyRgb(value: []const u8) ?[3]u8 {
    if (value.len < 5 or !std.ascii.startsWithIgnoreCase(value, "rgb(") or value[value.len - 1] != ')') return null;
    var channels = std.mem.splitScalar(u8, value[4 .. value.len - 1], ',');
    var percent: ?bool = null;
    var result: [3]u8 = undefined;
    for (&result) |*channel| {
        const raw = trim(channels.next() orelse return null);
        const is_percent = std.mem.endsWith(u8, raw, "%");
        if (percent) |prior| {
            if (prior != is_percent) return null;
        } else percent = is_percent;
        const number = if (is_percent) raw[0 .. raw.len - 1] else raw;
        if (number.len == 0 or number.len > 128) return null;
        var pos: usize = 0;
        if (number[pos] == '+' or number[pos] == '-') pos += 1;
        var digits: usize = 0;
        while (pos < number.len and std.ascii.isDigit(number[pos])) : (pos += 1) digits += 1;
        if (is_percent and pos < number.len and number[pos] == '.') {
            pos += 1;
            const fractional_start = pos;
            while (pos < number.len and std.ascii.isDigit(number[pos])) : (pos += 1) digits += 1;
            if (fractional_start == pos) return null;
        }
        if (digits == 0 or pos != number.len) return null;
        const parsed = std.fmt.parseFloat(f64, number) catch return null;
        if (!std.math.isFinite(parsed)) return null;
        const limit: f64 = if (is_percent) 100 else 255;
        const clipped = @max(0, @min(limit, parsed));
        const scaled = if (is_percent) clipped * 255 / 100 else clipped;
        channel.* = @intFromFloat(@floor(scaled + 0.5));
    }
    if (channels.next() != null) return null;
    return result;
}

pub fn canonicalColorAlloc(a: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const value = trim(raw);
    if (legacyRgb(value)) |channels| {
        const digits = std.fmt.bytesToHex(channels, .lower);
        const rgb_text = try a.alloc(u8, 7);
        rgb_text[0] = '#';
        @memcpy(rgb_text[1..], &digits);
        return rgb_text;
    }
    const names = .{ "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black", "blanchedalmond", "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse", "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue", "darkcyan", "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki", "darkmagenta", "darkolivegreen", "darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen", "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise", "darkviolet", "deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick", "floralwhite", "forestgreen", "fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod", "gray", "green", "greenyellow", "grey", "honeydew", "hotpink", "indianred", "indigo", "ivory", "khaki", "lavender", "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan", "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink", "lightsalmon", "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey", "lightsteelblue", "lightyellow", "lime", "limegreen", "linen", "magenta", "maroon", "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple", "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise", "mediumvioletred", "midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite", "navy", "oldlace", "olive", "olivedrab", "orange", "orangered", "orchid", "palegoldenrod", "palegreen", "paleturquoise", "palevioletred", "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple", "rebeccapurple", "red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown", "seagreen", "seashell", "sienna", "silver", "skyblue", "slateblue", "slategray", "slategrey", "snow", "springgreen", "steelblue", "tan", "teal", "thistle", "tomato", "turquoise", "violet", "wheat", "white", "whitesmoke", "yellow", "yellowgreen" };
    const colors = .{ "#f0f8ff", "#faebd7", "#00ffff", "#7fffd4", "#f0ffff", "#f5f5dc", "#ffe4c4", "#000000", "#ffebcd", "#0000ff", "#8a2be2", "#a52a2a", "#deb887", "#5f9ea0", "#7fff00", "#d2691e", "#ff7f50", "#6495ed", "#fff8dc", "#dc143c", "#00ffff", "#00008b", "#008b8b", "#b8860b", "#a9a9a9", "#006400", "#a9a9a9", "#bdb76b", "#8b008b", "#556b2f", "#ff8c00", "#9932cc", "#8b0000", "#e9967a", "#8fbc8f", "#483d8b", "#2f4f4f", "#2f4f4f", "#00ced1", "#9400d3", "#ff1493", "#00bfff", "#696969", "#696969", "#1e90ff", "#b22222", "#fffaf0", "#228b22", "#ff00ff", "#dcdcdc", "#f8f8ff", "#ffd700", "#daa520", "#808080", "#008000", "#adff2f", "#808080", "#f0fff0", "#ff69b4", "#cd5c5c", "#4b0082", "#fffff0", "#f0e68c", "#e6e6fa", "#fff0f5", "#7cfc00", "#fffacd", "#add8e6", "#f08080", "#e0ffff", "#fafad2", "#d3d3d3", "#90ee90", "#d3d3d3", "#ffb6c1", "#ffa07a", "#20b2aa", "#87cefa", "#778899", "#778899", "#b0c4de", "#ffffe0", "#00ff00", "#32cd32", "#faf0e6", "#ff00ff", "#800000", "#66cdaa", "#0000cd", "#ba55d3", "#9370db", "#3cb371", "#7b68ee", "#00fa9a", "#48d1cc", "#c71585", "#191970", "#f5fffa", "#ffe4e1", "#ffe4b5", "#ffdead", "#000080", "#fdf5e6", "#808000", "#6b8e23", "#ffa500", "#ff4500", "#da70d6", "#eee8aa", "#98fb98", "#afeeee", "#db7093", "#ffefd5", "#ffdab9", "#cd853f", "#ffc0cb", "#dda0dd", "#b0e0e6", "#800080", "#663399", "#ff0000", "#bc8f8f", "#4169e1", "#8b4513", "#fa8072", "#f4a460", "#2e8b57", "#fff5ee", "#a0522d", "#c0c0c0", "#87ceeb", "#6a5acd", "#708090", "#708090", "#fffafa", "#00ff7f", "#4682b4", "#d2b48c", "#008080", "#d8bfd8", "#ff6347", "#40e0d0", "#ee82ee", "#f5deb3", "#ffffff", "#f5f5f5", "#ffff00", "#9acd32" };
    inline for (names, colors) |name, color| if (std.ascii.eqlIgnoreCase(value, name)) return color;
    if ((value.len != 4 and value.len != 7) or value[0] != '#') return null;
    for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return null;
    const color = try a.alloc(u8, 7);
    color[0] = '#';
    for (0..6) |i| color[i + 1] = std.ascii.toLower(value[if (value.len == 4) 1 + i / 2 else i + 1]);
    return color;
}

// Split declarations at top-level semicolons only. Quoted font names,
// escaped bytes and function bodies cannot create a color declaration.
pub fn nextDeclarationAlloc(a: std.mem.Allocator, css: []const u8, pos: *usize) std.mem.Allocator.Error!?[]const u8 {
    if (pos.* >= css.len) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var quote: u8 = 0;
    var depth: usize = 0;
    while (pos.* < css.len) {
        const byte = css[pos.*];
        pos.* += 1;
        if (byte == '\\' and pos.* < css.len) {
            try out.append(a, byte);
            try out.append(a, css[pos.*]);
            pos.* += 1;
            continue;
        }
        if (quote != 0) {
            try out.append(a, byte);
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            try out.append(a, byte);
            continue;
        }
        if (byte == '/' and pos.* < css.len and css[pos.*] == '*') {
            const close = std.mem.indexOfPos(u8, css, pos.* + 1, "*/") orelse {
                pos.* = css.len;
                break;
            };
            pos.* = close + 2;
            try out.append(a, ' ');
            continue;
        }
        if (byte == '(' or byte == '[' or byte == '{') depth += 1;
        if ((byte == ')' or byte == ']' or byte == '}') and depth != 0) depth -= 1;
        if (byte == ';' and depth == 0) break;
        try out.append(a, byte);
    }
    return try out.toOwnedSlice(a);
}

// Exact retained HR namespace-8 Common.css fixture (8437 bytes at source authority).
const actual_common_css =
    "/* See also [[Special:Mypage/monobook.css]], [[MediaWiki:Monobook.css]] */\n" ++
    "\n" ++
    "/* <pre> */\n" ++
    "\n" ++
    "/* Class for links with loudspeaker icon next to them */\n" ++
    "\n" ++
    ".audiolink a {\n" ++
    "    background: url(\"//upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Loudspeaker.svg/16px-Loudspeaker.svg.png\") center left no-repeat !important;\n" ++
    "    padding-left: 20px !important;\n" ++
    "    padding-right: 0 !important;\n" ++
    "}\n" ++
    "\n" ++
    "\n" ++
    "/* Support for script templates. The inherit declaration resets the font for all browsers except MSIE6.  The empty comment must remain. */\n" ++
    ".IPA {\n" ++
    "        font-family: DejaVu Sans, Segoe UI, Lucida Grande, Lucida Sans Unicode, Charis SIL, Doulos SIL, Code2000, Gentium, Gentium Alternative, TITUS Cyberbit Basic, Arial Unicode MS;\n" ++
    "        font-family /**/:inherit;\n" ++
    "}\n" ++
    ".Unicode {\n" ++
    "        font-family: TITUS Cyberbit Basic, Code2000, Doulos SIL, Chrysanthi Unicode, Bitstream Cyberbit, Bitstream CyberBase, Bitstream Vera, Thryomanes, Gentium, GentiumAlt, Visual Geez Unicode, Lucida Grande, Tahoma, Arial Unicode MS, Microsoft Sans Serif, Lucida Sans Unicode;\n" ++
    "        font-family /**/:inherit;\n" ++
    "}\n" ++
    "/* Arabic */\n" ++
    ".AR {\n" ++
    "        font-family: Tahoma, Arial Unicode MS, Code2000, Traditional Arabic; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "/* Bengali */\n" ++
    ".BN {\n" ++
    "        font-family: UniBangla, Arial Unicode MS, Code2000, Likhan, UT Bengali Dhaka, Vrinda; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 130%;\n" ++
    "}\n" ++
    "/* Persian */\n" ++
    ".FA {\n" ++
    "        font-family: Tahoma; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "/* Kashmiri */\n" ++
    ".KS {\n" ++
    "        font-family: Tahoma; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "/* Kurdish */\n" ++
    ".KU {\n" ++
    "        font-family: Tahoma; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "/* Latin Extended-B */\n" ++
    ".latinx {\n" ++
    "        font-family: TITUS Cyberbit Basic, Code2000, Microsoft Sans Serif;\n" ++
    "        font-family /**/:inherit;\n" ++
    "}\n" ++
    "/* Polytonic Greek */\n" ++
    ".polytonic {\n" ++
    "        font-family: Athena, Gentium, Palatino Linotype, Arial Unicode MS, Lucida Sans Unicode, Lucida Grande, Code2000; \n" ++
    "        font-family /**/:inherit;\n" ++
    "}\n" ++
    "/* Russian and other Cyrillic */\n" ++
    ".RU {\n" ++
    "        font-family: Arial Unicode MS, Gentium, Code2000, Lucida Sans Unicode; \n" ++
    "        font-family /**/:inherit;\n" ++
    "}\n" ++
    "/* Sindhi */\n" ++
    ".SD {\n" ++
    "        font-family: MB Sindhi, MBSarang Sattar, MB Bhitai Sattar, MB Lateefi, Ayaz Gul, Tahoma; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "/* Thai */\n" ++
    ".TH {\n" ++
    "        font-family: Arial Unicode MS, Code2000; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "/* Urdu */\n" ++
    ".UR {\n" ++
    "        font-family: Tahoma; \n" ++
    "        font-family /**/:inherit;\n" ++
    "        font-size: 125%;\n" ++
    "}\n" ++
    "\n" ++
    "\n" ++
    "\n" ++
    "/* wikitable/prettytable class for skinning normal tables */\n" ++
    "\n" ++
    "table.wikitable,\n" ++
    "table.prettytable {\n" ++
    "  margin: 1em 1em 1em 0;\n" ++
    "  background: #f9f9f9;\n" ++
    "  border: 1px #aaaaaa solid;\n" ++
    "  border-collapse: collapse;\n" ++
    "}\n" ++
    "\n" ++
    "table.wikitable th, table.wikitable td,\n" ++
    "table.prettytable th, table.prettytable td {\n" ++
    "  border: 1px #aaaaaa solid;\n" ++
    "  padding: 0.2em;\n" ++
    "}\n" ++
    "\n" ++
    "table.wikitable th,\n" ++
    "table.prettytable th {\n" ++
    "  background: #f2f2f2;\n" ++
    "  text-align: center;\n" ++
    "}\n" ++
    "\n" ++
    "table.wikitable caption,\n" ++
    "table.prettytable caption {\n" ++
    "  margin-left: inherit;\n" ++
    "  margin-right: inherit;\n" ++
    "}\n" ++
    "\n" ++
    "/* main page-style boxes */\n" ++
    "table.bluebox {\n" ++
    "   background:#f9f9ff;\n" ++
    "   border:1px solid #aaaaaa;\n" ++
    "   margin-bottom:0.5em;\n" ++
    "   width:100%;\n" ++
    "}\n" ++
    "table.bluebox td {\n" ++
    "   padding:0.5em;\n" ++
    "}\n" ++
    "table.bluebox th {\n" ++
    "   background-color:#006699;\n" ++
    "   color:#ffffff;\n" ++
    "   padding:0.5em;\n" ++
    "}\n" ++
    "\n" ++
    "\n" ++
    "\n" ++
    "\n" ++
    "\n" ++
    "/* default setting for {{temp|italbrac}} and {{temp|italbrac-colon}} */\n" ++
    ".ib-brac, .ib-comma, .ib-colon { font-style: normal }\n" ++
    ".ib-content { font-style: italic }\n" ++
    "\n" ++
    "/* default setting for [[:Category:Inflection templates]] */\n" ++
    ".infl-inline { display: inline }\n" ++
    ".infl-table { display: none }\n" ++
    "\n" ++
    "/* default setting for Template:seeCites */\n" ++
    ".see-cites { font-style: italic }\n" ++
    "\n" ++
    "/* default style for indented \"see also\" */\n" ++
    ".disambig-see-also, .disambig-see-also-2 { text-indent: 2em }\n" ++
    "\n" ++
    "/* temporary default style for mentions outside of \"form of\" definitions */\n" ++
    ".mention { font-style: italic; }\n" ++
    ".mention-Latn { font-style: italic; }\n" ++
    ".en-mention { font-weight: bold; }\n" ++
    ".en-mention-double-quote { display: none; }\n" ++
    ".en-mention-single-quote { display: none; }\n" ++
    ".mention-gloss-double-quote { display: inline; }\n" ++
    ".mention-gloss-single-quote { display: none; }\n" ++
    "\n" ++
    "/* default style for \"form of\" definitions */\n" ++
    ".use-with-mention .mention { font-style: normal; font-weight: bold; }\n" ++
    "\n" ++
    "\n" ++
    "\n" ++
    "  /************************/\n" ++
    "  /* CommonsTicker styles */\n" ++
    "  /************************/\n" ++
    " \n" ++
    "  /* links */\n" ++
    "  .tickerDiffLink { } /* diff links in ticker */\n" ++
    "  .tickerMiscLink { } /* misc links in ticker */\n" ++
    " \n" ++
    "  /* remove list bullets */\n" ++
    "  .tickerList ul,    .tickerList ul li    { list-style: none; text-indent:-2em; margin-left:2em;   text-align:left; }\n" ++
    "  .tickerList ul ul, .tickerList ul ul li { list-style: none; text-indent:0;    margin-left:1.5em; text-align:left; }\n" ++
    "\n" ++
    "  /* per-type styles */\n" ++
    "  .tickerEntry_deleted     { }  /* entry for image deletion */\n" ++
    "  .tickerEntry_replaced    { }  /* entry for image replacement */\n" ++
    "  .tickerEntry_tagged      { }  /* entry for adding/removing problem tags */\n" ++
    "  .tickerEntry_redir       { }  /* entry for critical redirection (fot tag redirects) */\n" ++
    "  .tickerEntry_recat       { }  /* entry for critical re-categorization (for tag categories) */\n" ++
    "  .tickerEntry_notify      { }  /* entry for global notifications */\n" ++
    "  .tickerEntry_changed     { }  /* entry for generic change */\n" ++
    "\n" ++
    "  /* per-action styles */\n" ++
    "  .tickerAction_deleted:before     { content:\" GONE \"; color: #FF0000; font-family:monospace; font-weight:bold; font-size:100%; }  \n" ++
    "  .tickerAction_replaced:before    { content:\" REPL \"; color: #CC88FF; font-family:monospace; font-weight:bold; font-size:100%; }  \n" ++
    "  .tickerAction_addedBad:before    { content:\" +VfD \"; color: #FF8800; font-family:monospace; font-weight:bold; font-size:100%; }  \n" ++
    "  .tickerAction_removedBad:before  { content:\" -VfD \"; color: #00BB00; font-family:monospace; font-weight:bold; font-size:100%; }  \n" ++
    "  .tickerAction_addedGood:before   { content:\" +OK  \"; color: #00BB00; font-family:monospace; font-weight:bold; font-size:100%; }  \n" ++
    "  .tickerAction_removedGood:before { content:\" -OK  \"; color: #FF8800; font-family:monospace; font-weight:bold; font-size:100%; }\n" ++
    "\n" ++
    "  /* ticker usage list */\n" ++
    "  .tickerUsage  { font-size:80%; }  \n" ++
    "\n" ++
    "  /* entry applies to a template used by multiple images */\n" ++
    "  .tickerTemplateEntry    { font-weight: bold; } \n" ++
    "\n" ++
    "  /* entry applies to sub-entries, i.e. images that use a specific template */\n" ++
    "  .tickerSubEntry         { }                       \n" ++
    "\n" ++
    "  /* minor entry styles */ \n" ++
    "  .tickerMinorEntry  { color:#666; }     /* minor entry */\n" ++
    "  .tickerMinorEntry a,\n" ++
    "  .tickerMinorEntry a:link,\n" ++
    "  .tickerMinorEntry a:visited { color:#669; }\n" ++
    "  #bodyContent .tickerMinorEntry a.extiw,\n" ++
    "  #bodyContent .tickerMinorEntry a.extiw:link,\n" ++
    "  #bodyContent .tickerMinorEntry a.extiw:visited { color:#669; }\n" ++
    "\n" ++
    "/*InterProject */\n" ++
    "\n" ++
    ".interProject {\n" ++
    "   display:none; \n" ++
    "   clear: both; \n" ++
    "   border-top: 2px dotted #AAAAAA; \n" ++
    "   margin-top: 2em;\n" ++
    "}\n" ++
    "/* temp - testing */\n" ++
    "body.page-User_Dvortygirl_Articles_needing_photos { background: url(//upload.wikimedia.org/wiktionary/en/6/6b/Bounce_7.0_annoy_level_99.gif) top left repeat; }\n" ++
    "\n" ++
    "/* CSS moved from various templates */\n" ++
    "\n" ++
    ".rfc-trans { background-color: #f0fff0 }\n" ++
    ".ttbc { background-color: #f0fff0 }\n" ++
    ".trreq { background-color: #f0fff0 }\n" ++
    "\n" ++
    "/* t- template */\n" ++
    "\n" ++
    "#bodyContent a.extiw .new ,\n" ++
    "#bodyContent a.extiw:active .new {\n" ++
    "       /* color: #BA3333; */       /* based on the colour in the monobook skin    */\n" ++
    "       color: #CC5038;             /* based on the colour hard-coded in mediawiki */\n" ++
    "}\n" ++
    "\n" ++
    " \n" ++
    "/** live ajax link checking support **/\n" ++
    " \n" ++
    "/* #002bb8 for (unvisited) blue, #ba0000 for red; so #5d155c for unknown */\n" ++
    "a.dunno, #p-personal a.dunno {\n" ++
    "        color: #5d155c;\n" ++
    "}\n" ++
    " \n" ++
    "/* #5a3696 for (visited) blue, #a55858 for red; so #744777 for unknown */\n" ++
    "a.dunno:visited, #p-personal a.dunno:visited {\n" ++
    "        color: #744777;\n" ++
    "}\n" ++
    " \n" ++
    "/* for pages which exist but lack the section we're looking for */\n" ++
    "a.partlynew, #p-personal a.partlynew {\n" ++
    "        color: #B88D00;\n" ++
    "}\n" ++
    " \n" ++
    "/* for pages which exist but lack the section we're looking for */\n" ++
    "a.partlynew:visited, #p-personal a.partlynew:visited {\n" ++
    "        color: #826F34;\n" ++
    "}\n" ++
    "\n" ++
    "\n" ++
    "/* </pre> */\n" ++
    "\n" ++
    "/*\n" ++
    "<pre>\n" ++
    "*/\n" ++
    "\n" ++
    "#p-logo a { background: url(//upload.wikimedia.org/wiktionary/hr/b/bc/Wiki.png) 35% 50% no-repeat !important; }\n" ++
    "\n" ++
    "/* Standard Navigationsleisten, aka box hiding thingy from .de. */";

test "actual retained HR profile projects exact wikitable and header authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 8437), actual_common_css.len);
    var profile = try parseAlloc(a, actual_common_css);
    defer profile.deinit();
    try std.testing.expect(!profile.globally_unresolved);
    try std.testing.expect(profile.admitted_rule_numbers.len >= 3);
    const table = try profile.resolveTable(a, 0, "wikitable", null, "margin:10px");
    try std.testing.expect(!table.unresolved);
    try std.testing.expectEqualStrings("#f9f9f9", table.style.?.background.?);
    try std.testing.expectEqual(types.BorderCollapse.collapse, table.style.?.collapse.?);
    try std.testing.expectEqual(@as(f32, 10), table.style.?.margins.?.left.value);
    try std.testing.expectEqual(types.StyleLengthUnit.px, table.style.?.margins.?.left.unit);
    try std.testing.expectEqualStrings("#aaaaaa", table.style.?.border.?.solid.color);
    const th = try profile.resolveCellWithClasses(a, table.scope, 0, "", "wikitable", true, null, "");
    const td = try profile.resolveCellWithClasses(a, table.scope, 0, "", "wikitable", false, null, "");
    try std.testing.expect(!th.unresolved and !td.unresolved);
    try std.testing.expectEqualStrings("#f2f2f2", th.background.?);
    try std.testing.expect(td.background == null and !td.background_specified);
    try std.testing.expectEqual(types.CellTextAlign.center, th.style.?.text_align.?);
    try std.testing.expect(td.style.?.text_align == null);
    try std.testing.expectEqual(@as(f32, 0.2), th.style.?.padding.?.left.value);
    try std.testing.expectEqual(types.StyleLengthUnit.em, th.style.?.padding.?.left.unit);
    try std.testing.expect(!th.padding_basis_unresolved);
    const classes_case = try profile.resolveTable(a, 0, "Wikitable", null, "");
    try std.testing.expect(classes_case.style == null and classes_case.scope == 0 and !classes_case.unresolved);
    const pretty = try profile.resolveTable(a, 0, "prettytable", null, "");
    try std.testing.expectEqual(@as(f32, 0), pretty.style.?.margins.?.left.value);
    try std.testing.expectEqual(types.StyleLengthUnit.px, pretty.style.?.margins.?.left.unit);
    try std.testing.expectEqual(types.StyleLengthUnit.em, pretty.style.?.margins.?.top.unit);
}

test "profile retains no borrowed stylesheet bytes" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    var profile = try parseAlloc(std.testing.allocator, try scratch.allocator().dupe(u8, "table.Case {background:#abc;border:1px solid red} table.Case td {padding:.2em}"));
    scratch.deinit();
    defer profile.deinit();
    var output = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output.deinit();
    const table = try profile.resolveTable(output.allocator(), 0, "Case", null, "");
    const cell = try profile.resolveCell(output.allocator(), table.scope, false, null, "");
    try std.testing.expectEqualStrings("#aabbcc", table.style.?.background.?);
    try std.testing.expectEqualStrings("#ff0000", table.style.?.border.?.solid.color);
    try std.testing.expectEqual(@as(f32, 0.2), cell.style.?.padding.?.top.value);
}

test "important specificity source order and inline background hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.a {background:red!important;margin:1em} table.a {background:blue;margin:2em} table.a th {background:#123!important} table.a th {background:yellow}");
    defer profile.deinit();
    const table = try profile.resolveTable(a, 0, "a", "white", "background:black;margin:0");
    try std.testing.expectEqualStrings("#ff0000", table.style.?.background.?);
    try std.testing.expectEqual(@as(f32, 0), table.style.?.margins.?.top.value);
    const th = try profile.resolveCell(a, table.scope, true, "white", "background:#abc !important;background:cyan");
    try std.testing.expectEqualStrings("#aabbcc", th.background.?);
    const inline_important = try profile.resolveTable(a, 0, "a", null, "background:green!important");
    try std.testing.expectEqualStrings("#008000", inline_important.style.?.background.?);
    const plain = try profile.resolveTable(a, 0, "", "#abc", "");
    try std.testing.expectEqualStrings("#aabbcc", plain.style.?.background.?);
}

test "protected declarations do not invent style from comments quotes or functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.a{margin:1em;background:red}");
    defer profile.deinit();
    const table = try profile.resolveTable(a, 0, "a", null, "/* background:blue; */font-family:'x;background:yellow;';background: url('x;background:green;');margin:0; background:#abc/**/!important");
    try std.testing.expectEqualStrings("#aabbcc", table.style.?.background.?);
    try std.testing.expectEqual(@as(f32, 0), table.style.?.margins.?.top.value);
    try std.testing.expect(table.unresolved);
    const reset = try profile.resolveTable(a, 0, "a", null, "background:var(--other)");
    try std.testing.expect(reset.unresolved and reset.style.?.background == null);
}

test "invalid values have no priority but unsupported values suppress old winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.a{margin:1em;background:red} table.a td{padding:.2em;text-align:center;border:1px solid red}");
    defer profile.deinit();
    const invalid = try profile.resolveTable(a, 0, "a", null, "margin:nonsense!important;background:notacolor!important");
    try std.testing.expect(!invalid.unresolved);
    try std.testing.expectEqualStrings("#ff0000", invalid.style.?.background.?);
    try std.testing.expectEqual(@as(f32, 1), invalid.style.?.margins.?.top.value);
    const negative = try profile.resolveTable(a, 0, "a", null, "margin:-10px");
    try std.testing.expect(negative.unresolved and negative.style.?.margins == null);
    const relative = try profile.resolveTable(a, 0, "a", null, "margin:2rem");
    try std.testing.expect(relative.unresolved and relative.style.?.margins == null);
    const cell = try profile.resolveCell(a, invalid.scope, false, null, "padding:0;text-align:left;border:none");
    try std.testing.expectEqual(@as(f32, 0), cell.style.?.padding.?.left.value);
    try std.testing.expectEqual(types.CellTextAlign.left, cell.style.?.text_align.?);
    try std.testing.expect(cell.style.?.border.? == .none);
    const unknown_class = try profile.resolveTable(a, 0, "a unknown-class", "white", "");
    try std.testing.expect(!unknown_class.unresolved and !unknown_class.descendant_style_unresolved);
    try std.testing.expectEqualStrings("#ff0000", unknown_class.style.?.background.?);
    try std.testing.expectEqual(@as(f32, 1), unknown_class.style.?.margins.?.top.value);
    const invalid_padding = try profile.resolveCell(a, invalid.scope, false, null, "padding:-1px");
    try std.testing.expectEqual(@as(f32, 0.2), invalid_padding.style.?.padding.?.left.value);
}

test "conditional and unknown matched selectors report partial with no stale winner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.a{background:red;margin:1em} @media screen { table.a {background:blue} } table.a:hover{margin:2em} table.b{background:yellow} table.a caption{margin:inherit}");
    defer profile.deinit();
    try std.testing.expect(profile.has_unsupported_rules);
    const table = try profile.resolveTable(a, 0, "a", null, "");
    try std.testing.expect(table.unresolved and table.style == null);
    const other = try profile.resolveTable(a, 0, "b", null, "");
    try std.testing.expect(!other.unresolved);
    try std.testing.expectEqualStrings("#ffff00", other.style.?.background.?);
}

test "descendant scopes preserve nested classes and flag unsupported em font bases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.a{font-size:20px;margin:1em} table.a td{padding:.2em} table.b th{text-align:right}");
    defer profile.deinit();
    const outer = try profile.resolveTable(a, 0, "a", null, "");
    try std.testing.expect(outer.unresolved and outer.margin_basis_unresolved);
    const inner = try profile.resolveTable(a, outer.scope, "b", null, "");
    try std.testing.expect(!inner.unresolved);
    const td = try profile.resolveCell(a, inner.scope, false, null, "");
    try std.testing.expect(td.padding_basis_unresolved);
    const th = try profile.resolveCell(a, inner.scope, true, null, "font-size:10px");
    try std.testing.expect(th.padding_basis_unresolved and th.unresolved);
    try std.testing.expectEqual(types.CellTextAlign.right, th.style.?.text_align.?);
}

test "balanced unknown at-rules remain partial without fetching or stale projections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unknown_rules = [_][]const u8{
        "@import 'unavailable.css';",
        "@IMPORT url('unavailable.css') layer(external);",
        "@charset-extra \"UTF-8\";",
        "@namespace svg url('urn:unavailable');",
        "@unknown { table.a { background:blue!important } }",
        "@font-face { font-family:Other; src:url('unavailable.woff') }",
        "@mediafoo { future:syntax; }",
        "@media screen { @unknown { future:syntax; } }",
    };
    for (unknown_rules) |unknown| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}table.a{{background:red;margin:1em}} table.a th{{background:blue;border:1px solid red;padding:.2em}}", .{unknown}));
        defer profile.deinit();
        try std.testing.expect(profile.globally_unresolved and profile.has_unsupported_rules);
        try std.testing.expect(profile.admitted_rule_numbers.len == 2);
        const table = try profile.resolveTable(a, 0, "a", "white", "background:yellow!important");
        try std.testing.expect(table.style == null and table.unresolved and table.background_specified and table.margin_basis_unresolved and table.descendant_style_unresolved);
        const plain = try profile.resolveTable(a, 0, "", "white", "background:yellow!important");
        try std.testing.expect(plain.style == null and plain.unresolved and plain.background_specified);
        const cell = try profile.resolveCell(a, table.scope, true, "white", "background:yellow!important;padding:0");
        try std.testing.expect(cell.style == null and cell.background == null and cell.background_specified and cell.unresolved and cell.padding_basis_unresolved);
    }
    var known_group = try parseAlloc(a, "table.a{background:red} table.b{background:yellow} @MEDIA screen { table.a{background:blue} }");
    defer known_group.deinit();
    try std.testing.expect(!known_group.globally_unresolved and known_group.has_unsupported_rules);
    const unaffected = try known_group.resolveTable(a, 0, "b", null, "");
    try std.testing.expect(!unaffected.unresolved);
    try std.testing.expectEqualStrings("#ffff00", unaffected.style.?.background.?);
}

test "finite profile limits and incomplete stylesheets fail honestly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const oversized = try a.alloc(u8, max_css_bytes + 1);
    @memset(oversized, ' ');
    try std.testing.expectError(error.StyleProfileLimit, parseAlloc(a, oversized));
    var css: std.ArrayList(u8) = .empty;
    for (0..64) |i| try css.appendSlice(a, try std.fmt.allocPrint(a, "table.c{d}{{margin:0}}", .{i}));
    var full_scope = try parseAlloc(a, css.items);
    defer full_scope.deinit();
    const final_class = try full_scope.resolveTable(a, 0, "c63", null, "");
    try std.testing.expect(!final_class.unresolved and final_class.scope == (@as(Scope, 1) << 63));
    try std.testing.expectEqual(@as(f32, 0), final_class.style.?.margins.?.top.value);
    try css.appendSlice(a, "table.c64{margin:0}");
    try std.testing.expectError(error.StyleProfileLimit, parseAlloc(a, css.items));
    try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, "table.a{margin:0"));
    try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, "/* unfinished"));
    try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, "@import 'unfinished"));
    try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, "@unknown { unclosed"));
    css.clearRetainingCapacity();
    for (0..max_rules + 1) |_| try css.appendSlice(a, "table.a{margin:0}");
    try std.testing.expectError(error.StyleProfileLimit, parseAlloc(a, css.items));
}


test "class descendant CSS requires its separate ancestor scope and preserves cascade uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".Talk-Notice td { background: inherit; }");
    defer profile.deinit();
    const unrelated = try profile.resolveCellWithAncestors(a, 0, profile.ancestorScope("Talk-Notices Other"), false, "#FFFFE0", "");
    try std.testing.expectEqualStrings("#ffffe0", unrelated.background.?);
    try std.testing.expect(!unrelated.unresolved);
    const matching = try profile.resolveCellWithAncestors(a, 0, profile.ancestorScope("Other Talk-Notice"), false, "#FFFFE0", "");
    try std.testing.expect(matching.unresolved and matching.background_specified and matching.background == null);
    const header = try profile.resolveCellWithAncestors(a, 0, profile.ancestorScope("Talk-Notice"), true, "#FFFFE0", "");
    try std.testing.expectEqualStrings("#ffffe0", header.background.?);
    const override = try profile.resolveCellWithAncestors(a, 0, profile.ancestorScope("Talk-Notice"), false, "#FFFFE0", "background-color:#123456 !important");
    try std.testing.expectEqualStrings("#123456", override.background.?);
    // This selector is now exact. The independent inline winner makes the
    // unsupported inherited value irrelevant; no inheritance is evaluated.
    try std.testing.expect(!override.unresolved);
    var conditional = try parseAlloc(a, "@media screen { .X th { background:#123456; } }");
    defer conditional.deinit();
    const conditional_match = try conditional.resolveCellWithAncestors(a, 0, conditional.ancestorScope("X"), true, "#ffffe0", "");
    try std.testing.expect(conditional_match.unresolved and conditional_match.background == null);
}

test "generic CSS ancestry cannot satisfy a table qualified selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.X td { background:#123456; } .X th { background:inherit; }");
    defer profile.deinit();
    const bare = try profile.resolveTable(a, 0, "", null, "");
    const div_x_cell = try profile.resolveCellWithAncestors(a, bare.scope, profile.ancestorScope("X"), false, "#ffffe0", "");
    try std.testing.expectEqualStrings("#ffffe0", div_x_cell.background.?);
    const table_x = try profile.resolveTable(a, 0, "X", null, "");
    const table_x_cell = try profile.resolveCellWithAncestors(a, table_x.scope, profile.ancestorScope("X"), false, "#ffffe0", "");
    try std.testing.expectEqualStrings("#123456", table_x_cell.background.?);
    const div_x_header = try profile.resolveCellWithAncestors(a, bare.scope, profile.ancestorScope("X"), true, "#ffffe0", "");
    try std.testing.expect(div_x_header.background == null and div_x_header.unresolved);
    // The combined class capacity stays 64. Do not silently make an unindexed
    // scoped selector unconditional when the finite profile is exhausted.
    var css: std.ArrayList(u8) = .empty;
    for (0..65) |i| try css.appendSlice(a, try std.fmt.allocPrint(a, ".class{d} td {{ background:inherit; }}\n", .{i}));
    try std.testing.expectError(error.StyleProfileLimit, parseAlloc(a, css.items));
}

test "display profile uses bounded own classes independently of table paint scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var css: std.ArrayList(u8) = .empty;
    for (0..64) |i| try css.appendSlice(a, try std.fmt.allocPrint(a, "table.p{d} {{ background:#fff; }}\n", .{i}));
    try css.appendSlice(a, ".omit { display:none; } tr.omit.extra { display:table-row; } #chosen { display:block; }");
    var profile = try parseAlloc(a, css.items);
    defer profile.deinit();
    try std.testing.expectEqual(@as(usize, 64), profile.classes.len);
    try std.testing.expectEqual(@as(usize, 2), profile.display_classes.len);
    var exact = profile.displayRules("tr", "omit extra", "");
    try std.testing.expectEqual(@as(u32, 1 << 8), exact.next().?.specificity);
    try std.testing.expectEqual(@as(u32, (2 << 8) + 1), exact.next().?.specificity);
    try std.testing.expect(exact.next() == null);
    var wrong_tag = profile.displayRules("td", "omit extra", "");
    try std.testing.expectEqual(@as(u32, 1 << 8), wrong_tag.next().?.specificity);
    try std.testing.expect(wrong_tag.next() == null);
    var absent = profile.displayRules("tr", "", "");
    try std.testing.expect(absent.next() == null);
    var own_id = profile.displayRules("tr", "", "chosen");
    try std.testing.expectEqual(@as(u32, 1 << 24), own_id.next().?.specificity);
    try std.testing.expect(own_id.next() == null);
    var many: std.ArrayList(u8) = .empty;
    for (0..256) |i| try many.appendSlice(a, try std.fmt.allocPrint(a, ".v{d} {{ display:none; }}\n", .{i}));
    var many_profile = try parseAlloc(a, many.items);
    defer many_profile.deinit();
    try std.testing.expectEqual(@as(usize, 256), many_profile.display_classes.len);
    for (0..256) |i| {
        const name = try std.fmt.allocPrint(a, "v{d}", .{i});
        var matched = many_profile.displayRules("div", name, "");
        try std.testing.expectEqual(@as(u32, 1 << 8), matched.next().?.specificity);
        try std.testing.expect(matched.next() == null);
    }
    for ([_][]const u8{ "V255", "v255extra", "v256", "" }) |name| {
        var unmatched = many_profile.displayRules("div", name, "");
        try std.testing.expect(unmatched.next() == null);
    }
    var overflow: std.ArrayList(u8) = .empty;
    for (0..65536) |_| try overflow.appendSlice(a, ".a");
    try overflow.appendSlice(a, "{display:none}");
    var overflow_profile = try parseAlloc(a, overflow.items);
    defer overflow_profile.deinit();
    var overflow_rules = overflow_profile.displayRules("tr", "a", "");
    try std.testing.expect(overflow_rules.next().?.uncertain);
}

test "sparse display classes preserve compound specificity source repeats and allocation unwind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var css: std.ArrayList(u8) = .empty;
    for (0..256) |i| try css.appendSlice(a, try std.fmt.allocPrint(a, ".c{d}{{display:none}}\n", .{i}));
    const compound = ".c255.c255.gate{text-align:center}.Case{display:block}";
    const Case = struct {
        fn run(allocator: std.mem.Allocator, first: []const u8, second: []const u8) !void {
            var profile = try parseSourcesAlloc(allocator, &.{
                .{ .css = first, .base_url = "https://example.test/first.css" },
                .{ .css = second, .base_url = "https://example.test/second.css" },
                .{ .css = first, .base_url = "https://example.test/first.css" },
            });
            defer profile.deinit();
            try std.testing.expectEqual(@as(usize, 258), profile.display_classes.len);
            try std.testing.expectEqual(@as(usize, 3), profile.sources.len);
            try std.testing.expectEqual(@as(usize, 1), profile.sources[0].rule_begin);
            try std.testing.expectEqual(profile.sources[0].rule_end, profile.sources[1].rule_begin);
            try std.testing.expectEqual(profile.sources[1].rule_end, profile.sources[2].rule_begin);
            try std.testing.expectEqualStrings(profile.sources[0].base_url, profile.sources[2].base_url);
            try std.testing.expectEqualDeep(profile.sources[0].css_sha256, profile.sources[2].css_sha256);
            var matches = profile.displayRules("div", "c255\tgate", "");
            const first_match = matches.next().?;
            const compound_match = matches.next().?;
            const repeated_match = matches.next().?;
            try std.testing.expectEqual(@as(u32, 1 << 8), first_match.specificity);
            try std.testing.expectEqual(@as(u32, 3 << 8), compound_match.specificity);
            try std.testing.expectEqual(@as(u32, 1 << 8), repeated_match.specificity);
            try std.testing.expect(!first_match.uncertain and !compound_match.uncertain and !repeated_match.uncertain);
            try std.testing.expect(first_match.order < compound_match.order and compound_match.order < repeated_match.order);
            try std.testing.expectEqualStrings(first_match.css, repeated_match.css);
            try std.testing.expect(matches.next() == null);
            var missing_compound_class = profile.displayRules("div", "c255", "");
            try std.testing.expectEqual(@as(u32, 1 << 8), missing_compound_class.next().?.specificity);
            try std.testing.expectEqual(@as(u32, 1 << 8), missing_compound_class.next().?.specificity);
            try std.testing.expect(missing_compound_class.next() == null);
            for ([_][]const u8{ "gate", "C255 gate", "c255extra gate", "case", "" }) |names| {
                var absent = profile.displayRules("div", names, "");
                try std.testing.expect(absent.next() == null);
            }
            var case_sensitive = profile.displayRules("div", "Case", "");
            try std.testing.expectEqualStrings("display:block", case_sensitive.next().?.css);
            try std.testing.expect(case_sensitive.next() == null);
            const alignment = try profile.resolveAlignment(allocator, "div", "c255 gate", "", null, "");
            try std.testing.expectEqual(@as(?types.CellTextAlign, .center), alignment.value);
            try std.testing.expect(alignment.specified and !alignment.unresolved);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{ css.items, compound });
}

test "display cascade keeps important and inline priority distinct from selector specificity" {
    var cascade: DisplayCascade = .{};
    cascade.consider(true, false, 10, 1, false);
    cascade.consider(false, false, 0, 1, true);
    try std.testing.expectEqual(@as(?bool, false), cascade.hidden);
    cascade.consider(true, true, 10, 2, false);
    try std.testing.expectEqual(@as(?bool, true), cascade.hidden);
    cascade.consider(null, true, std.math.maxInt(u32), 3, false);
    try std.testing.expect(cascade.hidden == null);
    cascade.consider(false, true, 0, 1, true);
    try std.testing.expectEqual(@as(?bool, false), cascade.hidden);
    cascade.consider(null, true, std.math.maxInt(u32), std.math.maxInt(u32), false);
    try std.testing.expectEqual(@as(?bool, false), cascade.hidden);
}

test "stylesheet source segments preserve import position repeats and independent syntax scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const imported: Source = .{ .css = "table.X {background:#111111;}", .base_url = "https://www.mediawiki.org/import.css" };
    const local: Source = .{ .css = "table.X {background:#222222;}", .base_url = "https://pt.wiktionary.org/local.css" };
    var profile = try parseSourcesAlloc(a, &.{ imported, local });
    defer profile.deinit();
    const result = try profile.resolveTable(a, 0, "X", null, "");
    try std.testing.expectEqualStrings("#222222", result.style.?.background.?);
    var repeated = try parseSourcesAlloc(a, &.{ imported, local, imported });
    defer repeated.deinit();
    const repeated_result = try repeated.resolveTable(a, 0, "X", null, "");
    try std.testing.expectEqualStrings("#111111", repeated_result.style.?.background.?);
    try std.testing.expectEqual(@as(usize, 3), repeated.admitted_rule_numbers.len);
    try std.testing.expectError(error.InvalidStyleProfile, parseSourcesAlloc(a, &.{
        .{ .css = "table.X {", .base_url = "https://one.example/a.css" },
        .{ .css = "background:#111111;}", .base_url = "https://two.example/b.css" },
    }));
}

test "stylesheet segments retain conditional unknowns and important cascade" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseSourcesAlloc(a, &.{
        .{ .css = "table.X {background:#111111!important;}", .base_url = "https://one.example/a.css" },
        .{ .css = "table.X {background:#222222;}", .base_url = "https://two.example/b.css" },
    });
    defer profile.deinit();
    const result = try profile.resolveTable(a, 0, "X", null, "background:#333333");
    try std.testing.expectEqualStrings("#111111", result.style.?.background.?);
    var unknown = try parseSourcesAlloc(a, &.{
        .{ .css = "@import 'missing.css'; table.X{background:#111111;}", .base_url = "https://one.example/a.css" },
        .{ .css = "table.X{background:#222222;}", .base_url = "https://two.example/b.css" },
    });
    defer unknown.deinit();
    try std.testing.expect(unknown.globally_unresolved);
}

test "complete local paint selectors distinguish own ancestor and absent classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a,
        ".base {background:red;border:1px solid black;}" ++
        ".base th,.base td {background:white;} .base th {background:blue;}" ++
        ".base th.main {padding:3px;}" ++
        ".base td.note table th {background:green!important;}" ++
        ".foreign .base {background:yellow!important;}" ++
        ".ö-content {background:yellow;} .unrelated {font-size:200%;}");
    defer profile.deinit();
    const table = try profile.resolveTableWithAncestors(a, 0, "base unused-template-class", "", null, "");
    try std.testing.expectEqualStrings("#ff0000", table.style.?.background.?);
    try std.testing.expect(!table.unresolved and !table.margin_basis_unresolved and !table.descendant_style_unresolved);
    const header = try profile.resolveCellWithClasses(a, table.scope, 0, "main unused", "base", true, null, "");
    try std.testing.expectEqualStrings("#0000ff", header.background.?);
    try std.testing.expectEqual(@as(f32, 3), header.style.?.padding.?.top.value);
    try std.testing.expect(!header.unresolved and !header.padding_basis_unresolved);
    const body = try profile.resolveCellWithClasses(a, table.scope, 0, "unused", "base", false, null, "");
    try std.testing.expectEqualStrings("#ffffff", body.background.?);
    const self_only = try profile.resolveCellWithClasses(a, 0, 0, "base", "", false, null, "");
    try std.testing.expectEqualStrings("#ff0000", self_only.background.?);
    const absent = try profile.resolveTableWithAncestors(a, 0, "Base", "", null, "");
    try std.testing.expect(absent.style == null and !absent.unresolved);
    const unicode = try profile.resolveTableWithAncestors(a, 0, "ö-content", "", null, "");
    try std.testing.expectEqualStrings("#ffff00", unicode.style.?.background.?);
    const inherited = try profile.resolveTableWithAncestors(a, 0, "base", "foreign", null, "");
    try std.testing.expectEqualStrings("#ffff00", inherited.style.?.background.?);
    const possibly_nested = try profile.resolveCellWithClasses(a, table.scope, 0, "main", "base note", true, null, "");
    try std.testing.expect(possibly_nested.background == null and possibly_nested.unresolved);
    const font_ancestor = try profile.resolveCellWithClasses(a, table.scope, 0, "", "base unrelated", false, null, "");
    try std.testing.expect(font_ancestor.padding_basis_unresolved);
    const own_font_only = try profile.resolveCellWithClasses(a, table.scope, 0, "unrelated", "base", false, null, "");
    try std.testing.expect(own_font_only.padding_basis_unresolved);
}

test "uncertain paint selectors preserve property and inline cascade boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uncertain = [_][]const u8{
        ".base:hover{background:blue}",
        "[class~='base']{background:blue}",
        ".b\\61se{background:blue}",
        ".base/* comment */.other{background:blue}",
        ".base,.other:unknown{background:blue}",
        ".base,.other.{background:blue}",
        ".base,.{background:blue}",
        ".base,div:unknown{background:blue}",
        ".base\x00suffix{background:blue}",
        "@media screen {.base{background:blue}}",
    };
    for (uncertain) |tail| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, ".base{{background:red;border:1px solid black}}{s}", .{tail}));
        defer profile.deinit();
        const table = try profile.resolveTableWithAncestors(a, 0, "base", "", null, "");
        try std.testing.expect(table.unresolved and table.background_specified);
        try std.testing.expect(table.style.?.background == null and table.style.?.border != null);
        const inline_win = try profile.resolveTableWithAncestors(a, 0, "base", "", null, "background:green");
        try std.testing.expectEqualStrings("#008000", inline_win.style.?.background.?);
    }
    // A complete trailing comment has no selector token. Embedded compound
    // comments above remain outside the bounded selector projection.
    var boundary_comment = try parseAlloc(a, ".base{background:red;border:1px solid black}.base/* comment */{background:blue}");
    defer boundary_comment.deinit();
    const comment_result = try boundary_comment.resolveTableWithAncestors(a, 0, "base", "", null, "");
    try std.testing.expect(!comment_result.unresolved and comment_result.background_specified);
    try std.testing.expectEqualStrings("#0000ff", comment_result.style.?.background.?);
    try std.testing.expect(comment_result.style.?.border != null);
    const comment_inline = try boundary_comment.resolveTableWithAncestors(a, 0, "base", "", null, "background:green");
    try std.testing.expectEqualStrings("#008000", comment_inline.style.?.background.?);
    var width_only = try parseAlloc(a, ".base{background:red} .base:hover{width:70px}");
    defer width_only.deinit();
    const separate = try width_only.resolveTableWithAncestors(a, 0, "base", "", null, "");
    try std.testing.expectEqualStrings("#ff0000", separate.style.?.background.?);
    try std.testing.expect(separate.unresolved);
    var unrelated = try parseAlloc(a, ".base{background:red} .missing:hover{background:blue} li:before{background:yellow}");
    defer unrelated.deinit();
    const untouched = try unrelated.resolveTableWithAncestors(a, 0, "base", "", null, "");
    try std.testing.expectEqualStrings("#ff0000", untouched.style.?.background.?);
    try std.testing.expect(!untouched.unresolved);
    var important = try parseAlloc(a, ".base{background:red}.base:hover{background:blue!important}");
    defer important.deinit();
    const unknown_win = try important.resolveTableWithAncestors(a, 0, "base", "", null, "background:green");
    try std.testing.expect(unknown_win.style == null and unknown_win.unresolved);
    const inline_important = try important.resolveTableWithAncestors(a, 0, "base", "", null, "background:green!important");
    try std.testing.expectEqualStrings("#008000", inline_important.style.?.background.?);
    var repeated = try parseAlloc(a, ".base.base.base.base.base.base.base.base.base.base.base{background:red!important}");
    defer repeated.deinit();
    const repeated_inline = try repeated.resolveTableWithAncestors(a, 0, "base", "", null, "background:green!important");
    try std.testing.expectEqualStrings("#008000", repeated_inline.style.?.background.?);
    var imported = try parseAlloc(a, "@import 'unavailable.css';.base{background:red}");
    defer imported.deinit();
    const unresolved_import = try imported.resolveTableWithAncestors(a, 0, "base", "", null, "background:green!important");
    try std.testing.expect(unresolved_import.style == null and unresolved_import.descendant_style_unresolved);
}

test "paint own ID context preserves unknown absence exact compounds and CSS priority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a,
        "table.box{background:#111111;border-collapse:collapse}" ++
        "#chosen{background:#222222}table#chosen.box{background:#333333}");
    defer profile.deinit();
    const unknown = try profile.resolveTable(a, 0, "box", null, "");
    try std.testing.expect(unknown.unresolved);
    try std.testing.expect(unknown.style.?.background == null);
    const absent = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    try std.testing.expectEqualStrings("#111111", absent.style.?.background.?);
    const matching = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "chosen" }, null, "");
    try std.testing.expectEqualStrings("#333333", matching.style.?.background.?);
    const case_distinct = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "Chosen" }, null, "");
    try std.testing.expectEqualStrings("#111111", case_distinct.style.?.background.?);
    const spaced = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = " chosen " }, null, "");
    try std.testing.expectEqualStrings("#111111", spaced.style.?.background.?);
    const inline_style = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "chosen" }, null, "background:#abcdef");
    try std.testing.expectEqualStrings("#abcdef", inline_style.style.?.background.?);
    var important = try parseAlloc(a, "table.box{background:#111111}#chosen{background:#222222!important}");
    defer important.deinit();
    const author_wins = try important.resolveTableWithContext(a, 0, "box", .{ .own_id = "chosen" }, null, "background:#abcdef");
    try std.testing.expectEqualStrings("#222222", author_wins.style.?.background.?);
    const inline_wins = try important.resolveTableWithContext(a, 0, "box", .{ .own_id = "chosen" }, null, "background:#abcdef!important");
    try std.testing.expectEqualStrings("#abcdef", inline_wins.style.?.background.?);
    var repeated = try parseAlloc(a, "#same{background:#444444}#same#same{background:#555555}#same#other{background:#666666}");
    defer repeated.deinit();
    const duplicate = try repeated.resolveTableWithContext(a, 0, "", .{ .own_id = "same" }, null, "");
    try std.testing.expectEqualStrings("#555555", duplicate.style.?.background.?);
    var heavy: std.ArrayList(u8) = .empty;
    try heavy.appendSlice(a, "#chosen{background:#333333}");
    for (0..300) |_| try heavy.appendSlice(a, ".box");
    try heavy.appendSlice(a, "{background:#999999}");
    var many_classes = try parseAlloc(a, heavy.items);
    defer many_classes.deinit();
    const id_wins = try many_classes.resolveTableWithContext(a, 0, "box", .{ .own_id = "chosen" }, null, "");
    try std.testing.expectEqualStrings("#333333", id_wins.style.?.background.?);
}

test "paint ID context keeps ancestor escaped attribute and dynamic selector uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "div#parent table.box{background:#222222}",
        "table.box[id=other]{background:#222222}",
        "#\\6f ther{background:#222222}",
    }) |uncertain_css| {
        const css = try std.fmt.allocPrint(a, "table.box{{background:#111111}}{s}", .{uncertain_css});
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        const result = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "" }, null, "");
        try std.testing.expect(result.unresolved);
        try std.testing.expect(result.style == null or result.style.?.background == null);
    }
    var pseudo = try parseAlloc(a, "table.box{background:#111111}#other:hover{background:#222222}");
    defer pseudo.deinit();
    const absent = try pseudo.resolveTableWithContext(a, 0, "box", .{ .own_id = "" }, null, "");
    try std.testing.expectEqualStrings("#111111", absent.style.?.background.?);
    const matching = try pseudo.resolveTableWithContext(a, 0, "box", .{ .own_id = "other" }, null, "");
    try std.testing.expect(matching.unresolved);
    try std.testing.expect(matching.style == null or matching.style.?.background == null);
    var ancestor = try parseAlloc(a, "table.box{background:#111111}.foreign#parent table.box{background:#222222}");
    defer ancestor.deinit();
    const missing_class = try ancestor.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    try std.testing.expectEqualStrings("#111111", missing_class.style.?.background.?);
    var selector_list = try parseAlloc(a, "#chosen{background:#111111}table.box,:unproved{background:#222222}");
    defer selector_list.deinit();
    const uncertain_list = try selector_list.resolveTableWithContext(a, 0, "box", .{ .own_id = "chosen" }, null, "");
    try std.testing.expect(uncertain_list.unresolved);
    try std.testing.expect(uncertain_list.style == null or uncertain_list.style.?.background == null);
}

test "cell paint own ID distinguishes source absence match and legacy unknown context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".box td{background:#111111}td#chosen{background:#222222}");
    defer profile.deinit();
    const scope = profile.ancestorScope("box");
    const absent = try profile.resolveCellWithContext(a, 0, scope, "", .{ .ancestor_classes = "box", .own_id = "" }, false, null, "");
    try std.testing.expectEqualStrings("#111111", absent.background.?);
    const matching = try profile.resolveCellWithContext(a, 0, scope, "", .{ .ancestor_classes = "box", .own_id = "chosen" }, false, null, "");
    try std.testing.expectEqualStrings("#222222", matching.background.?);
    const unknown = try profile.resolveCellWithClasses(a, 0, scope, "", "box", false, null, "");
    try std.testing.expect(unknown.unresolved and unknown.background == null);
}

test "layout profile keeps presentational alignment below stylesheet and inline winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "td{text-align:left} th{text-align:center!important}");
    defer profile.deinit();
    const td = try profile.resolveCellWithHints(a, 0, 0, false, null, "RIGHT", "");
    try std.testing.expectEqual(types.CellTextAlign.left, td.style.?.text_align.?);
    try std.testing.expect(td.alignment_specified and !td.unresolved);
    const th = try profile.resolveCellWithHints(a, 0, 0, true, null, "right", "text-align:left");
    try std.testing.expectEqual(types.CellTextAlign.center, th.style.?.text_align.?);
    const inline_important = try profile.resolveCellWithHints(a, 0, 0, true, null, "right", "text-align:left!important");
    try std.testing.expectEqual(types.CellTextAlign.left, inline_important.style.?.text_align.?);
    const hint = try resolveInlineCellAlloc(a, " right ", "font-size:95%;color:red;text-align:banana");
    try std.testing.expectEqual(types.CellTextAlign.right, hint.style.?.text_align.?);
    try std.testing.expect(!hint.unresolved);
    const unknown = try resolveInlineCellAlloc(a, "right", "text-align:var(--alignment)");
    try std.testing.expect(unknown.style == null and unknown.alignment_specified and unknown.unresolved);
    const reset = try profile.resolveCellWithHints(a, 0, 0, false, null, "right", "all:initial");
    try std.testing.expect(reset.style == null and reset.alignment_specified and reset.unresolved);
    const invalid_hint = try resolveInlineCellAlloc(a, "middle", "");
    try std.testing.expect(invalid_hint.style == null and !invalid_hint.alignment_specified and !invalid_hint.unresolved);
}

test "layout profile cascades physical float none and each margin edge independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "table.box{float:left;margin:1px 2px 3px 4px}");
    defer profile.deinit();
    const selected = try profile.resolveTable(a, 0, "box", null, "float:right;margin-left:20px");
    try std.testing.expectEqual(types.TableFloatSide.right, selected.style.?.float_side.?);
    const edges_value = selected.style.?.margins.?;
    try std.testing.expectEqualDeep(types.StyleEdges{
        .top = .{ .unit = .px, .value = 1 },
        .right = .{ .unit = .px, .value = 2 },
        .bottom = .{ .unit = .px, .value = 3 },
        .left = .{ .unit = .px, .value = 20 },
    }, edges_value);
    try std.testing.expect(!selected.unresolved);
    const none = try profile.resolveTable(a, 0, "box", null, "float:none");
    try std.testing.expect(none.style.?.float_side == null and !none.unresolved);
    const first_important = try profile.resolveTable(a, 0, "box", null, "float:right!important;float:none;margin-left:20px!important;margin:0");
    try std.testing.expectEqual(types.TableFloatSide.right, first_important.style.?.float_side.?);
    try std.testing.expectEqual(@as(f32, 20), first_important.style.?.margins.?.left.value);
    try std.testing.expectEqual(@as(f32, 0), first_important.style.?.margins.?.right.value);
    const shorthand_wins = try profile.resolveTable(a, 0, "box", null, "margin-left:auto;margin:0");
    try std.testing.expectEqualDeep(types.StyleEdges.all(.{ .unit = .px, .value = 0 }), shorthand_wins.style.?.margins.?);
    try std.testing.expect(!shorthand_wins.unresolved);
    const invalid = try profile.resolveTable(a, 0, "box", null, "float:banana;margin-left:1px 2px");
    try std.testing.expectEqual(types.TableFloatSide.left, invalid.style.?.float_side.?);
    try std.testing.expectEqual(@as(f32, 4), invalid.style.?.margins.?.left.value);
    try std.testing.expect(!invalid.unresolved);
    const negative = try profile.resolveTable(a, 0, "box", null, "margin-left:-1px;float:inline-start");
    try std.testing.expect(negative.style == null and negative.unresolved);
    const reset = try profile.resolveTable(a, 0, "box", null, "all:unset");
    try std.testing.expect(reset.style == null and reset.unresolved);
    const plain = try resolveInlineTableAlloc(a, "font-size:95%;background:red;float:right;margin-left:20px");
    try std.testing.expectEqual(types.TableFloatSide.right, plain.style.?.float_side.?);
    try std.testing.expectEqual(@as(f32, 20), plain.style.?.margins.?.left.value);
    try std.testing.expectEqual(@as(f32, 0), plain.style.?.margins.?.top.value);
    try std.testing.expect(plain.style.?.background == null and plain.style.?.border == null and !plain.unresolved);
}

test "layout profile resolves generic controlled class alignment without name heuristics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // This is a controlled stylesheet fixture, not normal EU default authority.
    var profile = try parseAlloc(a, ".center{width:100%;text-align:center}.other{text-align:right}#probe{text-align:left!important}");
    defer profile.deinit();
    const centered = try profile.resolveAlignment(a, "div", "center", "", null, "");
    try std.testing.expect(centered.specified and centered.value.? == .center and !centered.unresolved);
    const inline_value = try profile.resolveAlignment(a, "div", "center", "", null, "text-align:right");
    try std.testing.expectEqual(types.CellTextAlign.right, inline_value.value.?);
    const important = try profile.resolveAlignment(a, "div", "center", "probe", null, "text-align:right");
    try std.testing.expectEqual(types.CellTextAlign.left, important.value.?);
    const inline_important = try profile.resolveAlignment(a, "div", "center", "probe", null, "text-align:right!important");
    try std.testing.expectEqual(types.CellTextAlign.right, inline_important.value.?);
    const unbound = try resolveInlineAlignmentAlloc(a, null, "");
    try std.testing.expect(!unbound.specified and unbound.value == null and !unbound.unresolved);
    const case_sensitive = try profile.resolveAlignment(a, "div", "Center", "", null, "");
    try std.testing.expect(!case_sensitive.specified);
    var conditional = try parseAlloc(a, ".center{text-align:center}@media print{.center{text-align:right}}");
    defer conditional.deinit();
    const uncertain = try conditional.resolveAlignment(a, "div", "center", "", null, "");
    try std.testing.expect(uncertain.specified and uncertain.value == null and uncertain.unresolved);
    const invalid = try profile.resolveAlignment(a, "div", "center", "", null, "text-align:banana!important");
    try std.testing.expectEqual(types.CellTextAlign.center, invalid.value.?);
    const dynamic = try profile.resolveAlignment(a, "div", "center", "", null, "text-align:var(--alignment)");
    try std.testing.expect(dynamic.specified and dynamic.value == null and dynamic.unresolved);
}

// Producer-only CSS custom properties. Unknown source/context is distinct from
// CSS's guaranteed-invalid value: only the latter may select a var fallback.
pub const CustomValue = union(enum) { known: []const u8, invalid, unknown };
pub const CustomBinding = struct { name: []const u8, value: CustomValue };
pub const CustomEnvironment = struct {
    values: []const CustomBinding = &.{},
    complete: bool = false,
    pub fn get(self: CustomEnvironment, name: []const u8) CustomValue {
        for (self.values) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return if (self.complete) .invalid else .unknown;
    }
};
pub const CustomElement = struct { tag: []const u8, classes: []const u8 = "", id: []const u8 = "", root: bool = false, inline_css: []const u8 = "" };
pub const CustomContext = struct { dark: ?bool = null, ancestors: []const CustomElement };
const CustomRule = struct { selector: DisplaySelector, root_only: bool, root_predicate_unresolved: bool = false, css: []const u8, order: u32 };
const CustomWinner = struct { name: []const u8, raw: []const u8, unknown: bool, priority: Priority, state: enum { fresh, visiting, done } = .fresh, cyclic: bool = false, value: CustomValue = .unknown };
pub const CustomProfile = struct {
    // Observed page-specific stylesheet/ancestor context is not an edition
    // default. Other titles retain unknown authority until separately bound.
    page_title: ?[]const u8 = null,
    rules: []const CustomRule,
    classes: []const []const u8,
    is_opaque: bool,
    root_environment: CustomEnvironment = .{},
    pub fn appliesTo(self: *const CustomProfile, title: []const u8) bool {
        return if (self.page_title) |expected| std.mem.eql(u8, expected, title) else true;
    }

    pub fn element(self: *const CustomProfile, a: std.mem.Allocator, parent: CustomEnvironment, element_value: CustomElement, inline_css: []const u8) !CustomEnvironment {
        var winners: std.ArrayList(CustomWinner) = .empty;
        defer winners.deinit(a);
        var complete = parent.complete and !self.is_opaque;
        rules: for (self.rules) |rule| {
            if (rule.root_only and !element_value.root) continue;
            if (rule.selector.tag) |tag| if (!std.ascii.eqlIgnoreCase(tag, element_value.tag)) continue;
            if (rule.selector.id) |id| if (!std.mem.eql(u8, id, element_value.id)) continue;
            for (rule.selector.classes) |required| if (!Profile.hasClass(element_value.classes, self.classes[required])) continue :rules;
            try customDeclarations(a, &winners, rule.css, rule.selector.uncertain, .{ .specificity = rule.selector.specificity, .order = rule.order }, &complete);
        }
        try customDeclarations(a, &winners, inline_css, false, .{ .inline_style = true, .order = max_rules * 1024 }, &complete);
        // Most elements do not redefine variables. Share immutable computed
        // parent data instead of cloning the complete site token table per span.
        if (winners.items.len == 0 and complete == parent.complete and !self.is_opaque) return parent;
        var out: std.ArrayList(CustomBinding) = .empty;
        for (parent.values) |entry| try out.append(a, .{ .name = entry.name, .value = if (self.is_opaque) .unknown else entry.value });
        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(a);
        for (winners.items, 0..) |_, index| {
            const value = try customComputed(a, winners.items, index, .{ .values = parent.values, .complete = complete }, &stack);
            const binding: CustomBinding = .{ .name = try a.dupe(u8, winners.items[index].name), .value = value };
            var replaced = false;
            for (out.items) |*entry| if (std.mem.eql(u8, entry.name, binding.name)) { entry.* = binding; replaced = true; break; };
            if (!replaced) try out.append(a, binding);
        }
        // An unparsed escaped name can affect an inherited binding as well as a
        // missing name. Never turn parser uncertainty into CSS absence.
        if (!complete) for (out.items) |*entry| { entry.value = .unknown; };
        return .{ .values = try out.toOwnedSlice(a), .complete = complete };
    }
};
fn customName(raw: []const u8) bool {
    if (raw.len <= 2 or !std.mem.startsWith(u8, raw, "--")) return false;
    for (raw[2..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
const CustomPriorityValue = struct { value: []const u8, important: bool = false, unknown: bool = false };
pub fn customPriority(raw: []const u8) CustomPriorityValue {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    var bang: ?usize = null;
    for (raw, 0..) |c, i| {
        if (escaped) { escaped = false; continue; }
        if (c == '\\') { escaped = true; continue; }
        if (quote != 0) { if (c == quote) quote = 0; continue; }
        if (c == '\'' or c == '"') { quote = c; continue; }
        if (c == '(' or c == '[' or c == '{') depth += 1;
        if (c == ')' or c == ']' or c == '}') { if (depth == 0) return .{ .value = raw, .unknown = true }; depth -= 1; }
        if (c == '!' and depth == 0) { if (bang != null) return .{ .value = raw, .unknown = true }; bang = i; }
    }
    if (quote != 0 or escaped or depth != 0) return .{ .value = raw, .unknown = true };
    if (bang) |at| {
        if (!std.ascii.eqlIgnoreCase(trim(raw[at + 1 ..]), "important")) return .{ .value = raw, .unknown = true };
        return .{ .value = trim(raw[0..at]), .important = true };
    }
    return .{ .value = raw };
}
fn customDeclarations(a: std.mem.Allocator, out: *std.ArrayList(CustomWinner), css: []const u8, uncertain: bool, priority: Priority, complete: *bool) !void {
    if (css.len > max_css_bytes) { complete.* = false; return; }
    var at: usize = 0;
    var order = priority.order;
    while (try nextDeclarationAlloc(a, css, &at)) |raw| {
        order +|= 1;
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = trim(raw[0..colon]);
        if (std.mem.indexOfScalar(u8, name, '\\') != null) { complete.* = false; continue; }
        if (!std.mem.startsWith(u8, name, "--")) continue;
        if (!customName(name)) { complete.* = false; continue; }
        const selected = customPriority(trim(raw[colon + 1 ..]));
        const value = selected.value;
        var p = priority;
        p.order = order;
        p.important = selected.important;
        var found = false;
        for (out.items) |*prior| if (std.mem.eql(u8, prior.name, name)) {
            found = true;
            if (p.wins(prior.priority)) prior.* = .{ .name = name, .raw = value, .unknown = uncertain or selected.unknown, .priority = p };
            break;
        };
        if (!found) {
            if (out.items.len >= 4096) { complete.* = false; return; }
            try out.append(a, .{ .name = name, .raw = value, .unknown = uncertain or selected.unknown, .priority = p });
        }
    }
}
const CustomCall = struct { name: []const u8, fallback: ?[]const u8 };
fn customCall(raw: []const u8) ?CustomCall {
    const value = trim(raw);
    if (!std.mem.startsWith(u8, value, "var(") or value.len < 6 or value[value.len - 1] != ')') return null;
    var depth: usize = 0;
    var comma: ?usize = null;
    var quote: u8 = 0;
    var escaped = false;
    for (value[4 .. value.len - 1], 4..) |c, i| {
        if (escaped) { escaped = false; continue; }
        if (quote != 0) {
            if (c == '\n' or c == '\r' or c == 12) return null;
            if (c == '\\') escaped = true else if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') { quote = c; continue; }
        if (c == '\\' or c == '/' or c == ';' or c == '{' or c == '}') return null;
        if (c == '(') depth += 1;
        if (c == ')') { if (depth == 0) return null; depth -= 1; }
        if (c == ',' and depth == 0 and comma == null) comma = i;
    }
    if (depth != 0 or quote != 0 or escaped) return null;
    const end = comma orelse value.len - 1;
    const name = trim(value[4..end]);
    if (!customName(name)) return null;
    return .{ .name = name, .fallback = if (comma) |i| trim(value[i + 1 .. value.len - 1]) else null };
}
fn customContainsFunction(value: []const u8) bool {
    // Strings are literal tokens, including text resembling a dependency.
    // Outside strings, unsupported escapes/functions cannot become literals.
    var quote: u8 = 0;
    var escaped = false;
    for (value, 0..) |c, i| {
        if (escaped) { escaped = false; continue; }
        if (quote != 0) {
            if (c == '\n' or c == '\r' or c == 12) return true;
            if (c == '\\') escaped = true else if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') { quote = c; continue; }
        if (c == '\\' or std.mem.startsWith(u8, value[i..], "var(")) return true;
    }
    return quote != 0 or escaped;
}
fn customLookup(a: std.mem.Allocator, entries: []CustomWinner, name: []const u8, parent: CustomEnvironment, stack: *std.ArrayList(usize)) std.mem.Allocator.Error!CustomValue {
    for (entries, 0..) |entry, i| if (std.mem.eql(u8, entry.name, name)) return customComputed(a, entries, i, parent, stack);
    return parent.get(name);
}
fn customExpression(a: std.mem.Allocator, entries: []CustomWinner, raw: []const u8, parent: CustomEnvironment, stack: *std.ArrayList(usize), depth: usize) std.mem.Allocator.Error!CustomValue {
    if (depth > 32 or raw.len > 65536) return .unknown;
    const value = trim(raw);
    if (customCall(value)) |call| {
        // The dependency graph includes fallback references even when the main
        // value exists. Walking both branches preserves cycle invalidation.
        const fallback: CustomValue = if (call.fallback) |f| try customExpression(a, entries, f, parent, stack, depth + 1) else .invalid;
        const selected = try customLookup(a, entries, call.name, parent, stack);
        return switch (selected) { .invalid => fallback, else => selected };
    }
    if (customContainsFunction(value)) return .unknown;
    return .{ .known = try a.dupe(u8, value) };
}
fn customComputed(a: std.mem.Allocator, entries: []CustomWinner, index: usize, parent: CustomEnvironment, stack: *std.ArrayList(usize)) std.mem.Allocator.Error!CustomValue {
    if (entries[index].state == .done) return entries[index].value;
    if (entries[index].state == .visiting) {
        var cycle = false;
        for (stack.items) |i| { cycle = cycle or i == index; if (cycle) entries[i].cyclic = true; }
        return .invalid;
    }
    if (stack.items.len >= 32) return .unknown;
    entries[index].state = .visiting;
    try stack.append(a, index);
    defer _ = stack.pop();
    const raw = entries[index].raw;
    const value: CustomValue = if (entries[index].unknown) .unknown else if (std.ascii.eqlIgnoreCase(raw, "initial")) .invalid else if (std.ascii.eqlIgnoreCase(raw, "inherit") or std.ascii.eqlIgnoreCase(raw, "unset")) parent.get(entries[index].name) else if (std.ascii.eqlIgnoreCase(raw, "revert") or std.ascii.eqlIgnoreCase(raw, "revert-layer")) .unknown else try customExpression(a, entries, raw, parent, stack, 0);
    entries[index].value = if (entries[index].cyclic) .invalid else value;
    entries[index].state = .done;
    return entries[index].value;
}
pub fn customColorValue(a: std.mem.Allocator, environment: CustomEnvironment, raw: []const u8) !CustomValue {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(a);
    return customExpression(a, &.{}, raw, environment, &stack, 0);
}

const CustomBuilder = struct {
    selector_builder: Builder,
    rules: std.ArrayList(CustomRule) = .empty,
    is_opaque: bool = false,
    order: u32 = 0,
    dark: ?bool,
    fn parse(self: *CustomBuilder, css: []const u8, conditional: bool, depth: usize) anyerror!void {
        if (depth > 16) return error.StyleProfileLimit;
        const a = self.selector_builder.a;
        var pos: usize = 0;
        while (true) {
            try skipSpaceComments(css, &pos);
            if (pos == css.len) break;
            const start = pos;
            const boundary = try findBoundary(css, &pos);
            const prelude = trim(css[start .. pos - 1]);
            if (boundary == ';') {
                // Imports/namespace/layer order are not implicit dependencies.
                self.is_opaque = true;
                continue;
            }
            if (boundary != '{') return error.InvalidStyleProfile;
            const begin = pos;
            const end = try closingBrace(css, &pos);
            const body = css[begin..end];
            if (std.mem.startsWith(u8, prelude, "@media")) {
                const query = trim(prelude[6..]);
                const applies: ?bool = if (std.mem.eql(u8, query, "screen") or std.mem.eql(u8, query, "all")) true else if (std.mem.eql(u8, query, "print")) false else if (std.mem.eql(u8, query, "screen and (prefers-color-scheme:dark)") or std.mem.eql(u8, query, "screen and (prefers-color-scheme: dark)")) self.dark else null;
                if (applies == false) continue;
                try self.parse(body, conditional or applies == null, depth + 1);
                continue;
            }
            if (prelude.len != 0 and prelude[0] == '@') {
                if (isConditionalGroup(prelude)) {
                    try self.parse(body, true, depth + 1);
                } else if (std.mem.indexOf(u8, body, "--") != null or std.mem.startsWith(u8, prelude, "@property")) self.is_opaque = true;
                continue;
            }
            var declarations: std.ArrayList(CustomWinner) = .empty;
            defer declarations.deinit(a);
            var complete = true;
            try customDeclarations(a, &declarations, body, false, .{}, &complete);
            if (!complete) self.is_opaque = true;
            if (declarations.items.len == 0) continue;
            if (self.rules.items.len >= max_rules) return error.StyleProfileLimit;
            const order = self.order;
            var declaration_at: usize = 0;
            while (try nextDeclarationAlloc(a, body, &declaration_at)) |_| {
                self.order += 1;
                if (self.order >= max_rules * 1024) return error.StyleProfileLimit;
            }
            const copied = try a.dupe(u8, body);
            var parts: SelectorList = .{ .source = prelude };
            const first = self.rules.items.len;
            var uncertain = conditional;
            while (try parts.nextAlloc(a)) |part| {
                if (self.rules.items.len >= max_rules) return error.StyleProfileLimit;
                const root_only = std.mem.eql(u8, trim(part), ":root");
                var selector = try self.selector_builder.displaySelector(if (root_only) "html" else part, conditional);
                if (root_only) selector.specificity = 1 << 8;
                uncertain = uncertain or selector.uncertain;
                try self.rules.append(a, .{ .selector = selector, .root_only = root_only, .root_predicate_unresolved = !root_only and try self.selector_builder.contentRootPredicateUnresolved(part, true), .css = copied, .order = order });
            }
            if (uncertain) for (self.rules.items[first..]) |*rule| { rule.selector.uncertain = true; rule.selector.specificity = std.math.maxInt(u32); };
        }
    }
};
/// Attach only to a selected, source-bound profile. Parse all supplied sheets,
/// retaining name-specific unknown rules rather than choosing var fallbacks.
pub fn attachCustomProperties(profile: *Profile, sources: []const Source, context: CustomContext) !void {
    const a = profile.arena.allocator();
    if (context.ancestors.len == 0 or context.ancestors.len > 32 or !context.ancestors[0].root or !std.mem.eql(u8, context.ancestors[0].tag, "html")) return error.InvalidStyleProfile;
    var builder: CustomBuilder = .{ .selector_builder = .{ .a = a }, .dark = context.dark };
    var total: usize = 0;
    for (sources) |source| {
        total = std.math.add(usize, total, source.css.len) catch return error.StyleProfileLimit;
        if (total > max_css_bytes) return error.StyleProfileLimit;
        try builder.parse(source.css, false, 0);
    }
    const result = try a.create(CustomProfile);
    result.* = .{ .rules = builder.rules.items, .classes = builder.selector_builder.display_classes.items, .is_opaque = builder.is_opaque };
    var environment: CustomEnvironment = .{ .complete = !builder.is_opaque };
    for (context.ancestors, 0..) |element_value, i| {
        if (i != 0 and element_value.root) return error.InvalidStyleProfile;
        environment = try result.element(a, environment, element_value, element_value.inline_css);
    }
    result.root_environment = environment;
    profile.custom_properties = result;
}

const CustomPropertyFixture = struct {
    fn profile(a: std.mem.Allocator, css: []const u8) !Profile {
        var result = try parseAlloc(a, "");
        errdefer result.deinit();
        try attachCustomProperties(&result, &.{.{ .css = css, .base_url = "https://example.invalid/observed.css" }}, .{
            .dark = false, .ancestors = &.{ .{ .tag = "html", .classes = "skin-theme-clientpref-day", .root = true }, .{ .tag = "body" } },
        });
        return result;
    }
    fn known(environment: CustomEnvironment, name: []const u8, expected: []const u8) !void {
        const value = environment.get(name);
        try std.testing.expect(value == .known);
        try std.testing.expectEqualStrings(expected, value.known);
    }
};
test "selected custom properties preserve computed inheritance local priority and sibling scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try CustomPropertyFixture.profile(a,
        ":root{--ink:#123456;--copy:var(--ink);--Mixed:#abcdef} .local{--ink:#654321} .important{--ink:#445566!important}"
    ); defer profile.deinit();
    const custom = profile.custom_properties.?;
    const parent = custom.root_environment;
    try CustomPropertyFixture.known(parent, "--ink", "#123456");
    const child = try custom.element(a, parent, .{ .tag = "span", .classes = "local" }, "--ink:#fedcba;--ink:#234567!important;--ink:#ffffff");
    try CustomPropertyFixture.known(child, "--ink", "#234567");
    try CustomPropertyFixture.known(child, "--copy", "#123456");
    const peer = try custom.element(a, parent, .{ .tag = "span" }, "");
    try CustomPropertyFixture.known(peer, "--ink", "#123456");
    const important = try custom.element(a, parent, .{ .tag = "span", .classes = "important" }, "--ink:#ffffff");
    try CustomPropertyFixture.known(important, "--ink", "#445566");
    const inline_important = try custom.element(a, parent, .{ .tag = "span", .classes = "important" }, "--ink:#ffffff!important");
    try CustomPropertyFixture.known(inline_important, "--ink", "#ffffff");
    try std.testing.expect(parent.get("--mixed") == .invalid);
    const order = try custom.element(a, parent, .{ .tag = "span" }, "--a:var(--b);--b:#102030");
    try CustomPropertyFixture.known(order, "--a", "#102030");
}
test "custom variable cycles invalid values and unknown authority cannot manufacture fallback paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try CustomPropertyFixture.profile(a, ":root{--ink:#123456}"); defer profile.deinit();
    const custom = profile.custom_properties.?;
    const value = try custom.element(a, custom.root_environment, .{ .tag = "span" },
        "--a:var(--b,red);--b:var(--a,blue);--c:var(--a,#abcdef);--d:var(--ink,var(--d));--empty:initial;--text:12px;--quoted:\"not !important\";--nested:fn(!important);--strong:\"not !important\" !important;--strong:red");
    try std.testing.expect(value.get("--a") == .invalid and value.get("--b") == .invalid and value.get("--d") == .invalid);
    try CustomPropertyFixture.known(value, "--c", "#abcdef");
    try CustomPropertyFixture.known(value, "--quoted", "\"not !important\"");
    try CustomPropertyFixture.known(value, "--nested", "fn(!important)");
    try CustomPropertyFixture.known(value, "--strong", "\"not !important\"");
    const missing = try customColorValue(a, value, "var(--absent,#abcdef)");
    try std.testing.expectEqualStrings("#abcdef", missing.known);
    const invalid = try customColorValue(a, value, "var(--empty,#abcdef)");
    try std.testing.expectEqualStrings("#abcdef", invalid.known);
    const defined_noncolor = try customColorValue(a, value, "var(--text,#abcdef)");
    try std.testing.expectEqualStrings("12px", defined_noncolor.known);
    const quoted = try customColorValue(a, value, "var(--quoted,#abcdef)");
    try std.testing.expectEqualStrings("\"not !important\"", quoted.known);
    const unused_quoted = try customColorValue(a, value, "var(--ink,'not !important')");
    try std.testing.expectEqualStrings("#123456", unused_quoted.known);
    const quoted_fallback = try customColorValue(a, value, "var(--absent,'var(--a), !important)')");
    try std.testing.expectEqualStrings("'var(--a), !important)'", quoted_fallback.known);
    const quoted_self = try custom.element(a, value, .{ .tag = "span" }, "--s:'var(--s)'");
    try CustomPropertyFixture.known(quoted_self, "--s", "'var(--s)'");
    try std.testing.expect((try customColorValue(a, value, "var(--absent,'unterminated)")) == .unknown);
    try std.testing.expect((try customColorValue(a, .{}, "var(--absent,#abcdef)")) == .unknown);
    var unknown = try CustomPropertyFixture.profile(a, ":root{--ink:#123456}@supports(display:grid){span{--ink:#abcdef}}"); defer unknown.deinit();
    const uncertain = try unknown.custom_properties.?.element(a, unknown.custom_properties.?.root_environment, .{ .tag = "span" }, "");
    try std.testing.expect((try customColorValue(a, uncertain, "var(--ink,#fedcba)")) == .unknown);
}
test "custom property source order spans long declaration blocks and selected theme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var css: std.ArrayList(u8) = .empty;
    try css.appendSlice(a, ":root{--ink:#123456}@media screen{.x{");
    for (0..1100) |_| try css.appendSlice(a, "--ink:#ff0000;");
    try css.appendSlice(a, "}.x{--ink:#00ff00}}html.skin-theme-clientpref-night{--ink:#010203}");
    var profile = try CustomPropertyFixture.profile(a, css.items); defer profile.deinit();
    const custom = profile.custom_properties.?;
    const result = try custom.element(a, custom.root_environment, .{ .tag = "span", .classes = "x" }, "");
    try CustomPropertyFixture.known(result, "--ink", "#00ff00");
    var night = try parseAlloc(a, ""); defer night.deinit();
    try attachCustomProperties(&night, &.{.{ .css = css.items, .base_url = "https://example.invalid/observed.css" }}, .{
        .dark = true, .ancestors = &.{ .{ .tag = "html", .classes = "skin-theme-clientpref-night", .root = true }, .{ .tag = "body" } },
    });
    try CustomPropertyFixture.known(night.custom_properties.?.root_environment, "--ink", "#010203");
}


test "opaque comma RGB colors preserve integer percent clipping and reject alpha or mixed tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, color: []const u8 }{
        .{ .source = "rgb(80%,80%,100%)", .color = "#ccccff" },
        .{ .source = "rgb(95%,95%,100%)", .color = "#f2f2ff" },
        .{ .source = "RGB( 255, 0, +128 )", .color = "#ff0080" },
        .{ .source = "rgb(110%,-5%,50%)", .color = "#ff0080" },
        .{ .source = "rgb(300,-10,0)", .color = "#ff0000" },
        .{ .source = "rgb(.5%,+0%,100.0%)", .color = "#0100ff" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.color, (try canonicalColorAlloc(a, case.source)) orelse return error.TestUnexpectedResult);
    for ([_][]const u8{
        "rgb(1,2)", "rgb(1,2,3,4)", "rgb(1%,2,3%)", "rgb(1.5,2,3)",
        "rgb(1.,2,3)", "rgb(1.%,2%,3%)", "rgb(1 % ,2%,3%)", "rgb(+%,2%,3%)",
        "rgb(1e2%,0%,0%)", "rgb(NaN%,0%,0%)", "rgb(1 2 3)", "rgb(1,2,3)tail",
        "rgba(1,2,3,0.5)", "rgba(1,2,3,1)", "rgb(var(--r),2,3)", "rgb(calc(1),2,3)",
    }) |source| try std.testing.expect((try canonicalColorAlloc(a, source)) == null);
}


test "font-only stylesheet cascade selects exact winners and retains unknown computed-parent authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a,
        ".exact{font-size:110%}.strong{font-size:150%!important}" ++
        "@media print{.maybe{font-size:90%}} .ancestor .desc{font-size:80%}");
    defer profile.deinit();
    const exact = (try profile.resolveFontSize(a, "span", "exact", "", "")).?;
    try std.testing.expect(exact == .relative);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), exact.relative, 0.000001);
    const important = (try profile.resolveFontSize(a, "span", "strong", "", "font-size:small")).?;
    try std.testing.expect(important == .relative);
    try std.testing.expectEqual(@as(f32, 1.5), important.relative);
    const override = (try profile.resolveFontSize(a, "span", "strong", "", "font-size:small!important")).?;
    try std.testing.expect(override == .absolute);
    try std.testing.expectEqual(@as(f32, 8.0 / 9.0), override.absolute);
    for ([_][]const u8{ "maybe", "desc" }) |class| {
        try std.testing.expect((try profile.resolveFontSize(a, "span", class, "", "")).? == .unknown);
    }
    try std.testing.expect((try profile.resolveFontSize(a, "span", "maybe", "", "font-size:medium!important")).? == .absolute);
    for ([_][]const u8{ "font-size:20px", "font-size:calc(1em + 1px)", "font:caption", "all:revert", "font-size:var(--size)", "font-size:125%;font-size:20px!important;font-size:medium" }) |css| {
        try std.testing.expect((try resolveInlineFontSizeAlloc(a, css)).? == .unknown);
    }
    const reset = (try resolveInlineFontSizeAlloc(a, "font-size:20px;font-size:medium")).?;
    try std.testing.expect(reset == .absolute and reset.absolute == 1);
    const invalid = (try resolveInlineFontSizeAlloc(a, "font-size:125%;font-size:nonsense;font-size:-20px")).?;
    try std.testing.expect(invalid == .relative and invalid.relative == 1.25);
    try std.testing.expect((try resolveInlineFontSizeAlloc(a, "font-size:inherit")).? == .inherit);
    try std.testing.expect((try resolveInlineFontSizeAlloc(a, "all:unset")).? == .inherit);
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(a, ".same{");
    for (0..1100) |_| try many.appendSlice(a, "font-size:110%;");
    try many.appendSlice(a, "}.same{font-size:125%}");
    var ordered = try parseAlloc(a, many.items);
    defer ordered.deinit();
    const last = (try ordered.resolveFontSize(a, "span", "same", "", "")).?;
    try std.testing.expect(last == .relative and last.relative == 1.25);
}

test "unsupported paint selectors retain necessary ancestor classes only as nonmatch proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    // Relevant background declarations from retained SR Common.css58c27434. The unknown
    // :target/rgba state must not suppress an unrelated infobox's known paint.
    const css = ".infobox {background-color:#f8f9fa}" ++
        "body.action-info .mw-body-content :target, .citation:target {background-color:#def;background-color:rgba(0,127,255,0.133)}" ++
        "table.inflection tr:nth-child(odd):not(.rowgroup) th {background:#f6f6f6}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    const table = try profile.resolveTableWithContext(a, 0, "infobox vcard", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    const style = table.style orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("#f8f9fa", style.background orelse return error.TestUnexpectedResult);
    try std.testing.expect(!table.unresolved);
    for ([_]bool{ true, false }) |header| {
        const expected = if (header) "#ffffe0" else "#f4f4f4";
        const cell = try profile.resolveCellWithContextAndHints(a, table.scope, 0, "", .{ .ancestor_classes = "infobox vcard", .own_id = "" }, header, expected, null, "");
        try std.testing.expectEqualStrings(expected, cell.background orelse return error.TestUnexpectedResult);
        try std.testing.expect(!cell.unresolved);
    }
    // Presence is not a match proof: unsupported pseudo/ancestor order and
    // viewport/state still withhold the property. Null ancestry is unknown.
    for ([_]?[]const u8{ "action-info mw-body-content", null }) |ancestors| {
        const possible = try profile.resolveCellWithContextAndHints(a, table.scope, 0, "", .{ .ancestor_classes = ancestors, .own_id = "" }, true, "#f4f4f4", null, "");
        try std.testing.expect(possible.unresolved and possible.background == null);
    }
    const inflection = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = "inflection", .own_id = "" }, true, "#f4f4f4", null, "");
    try std.testing.expect(inflection.unresolved and inflection.background == null);
    const inline_winner = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = "action-info mw-body-content", .own_id = "" }, true, "#f4f4f4", null, "background:yellow!important");
    try std.testing.expectEqualStrings("#ffff00", inline_winner.background orelse return error.TestUnexpectedResult);
}

test "uncertain ancestor prefixes preserve child descendant sibling function escape and unknown context domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ ".missing td:hover", ".missing > td:hover", ".missing[data-note=\"a b\"] td:hover", ".missing/*comment*/ td:hover" }) |selector| {
        errdefer std.debug.print("SR necessary-ancestor selector={s}\n", .{selector});
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{background:blue}}", .{selector})); defer profile.deinit();
        const absent = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "" }, false, "#f4f4f4", null, "");
        try std.testing.expectEqualStrings("#f4f4f4", absent.background orelse return error.TestUnexpectedResult);
        try std.testing.expect(!absent.unresolved);
        for ([_]?[]const u8{ "missing", null }) |ancestors| {
            const possible = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = ancestors, .own_id = "" }, false, "#f4f4f4", null, "");
            try std.testing.expect(possible.unresolved and possible.background == null);
        }
    }
    for ([_][]const u8{
        ".missing + td:hover", ".missing ~ td:hover", ".missing > .other + td:hover",
        ":not(.missing) td:hover", ":has(.missing + .other) td:hover", ":is(.missing,.other) td:hover",
        ".missing\\:escaped td:hover", ".missing/*comment*/.other td:hover", ".missing & td:hover",
    }) |selector| {
        errdefer std.debug.print("SR conservative-ancestor selector={s}\n", .{selector});
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{background:blue}}", .{selector})); defer profile.deinit();
        const possible = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "" }, false, "#f4f4f4", null, "");
        try std.testing.expect(possible.unresolved and possible.background == null);
    }
    // The .container prefix is necessary; functional arguments are not ancestor
    // classes. Their absence cannot prove :not/:has false or clear uncertainty.
    for ([_][]const u8{ ".container:not(.missing) td:hover", ".container:has(.missing) td:hover" }) |selector| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{background:blue}}", .{selector})); defer profile.deinit();
        const possible = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = "container", .own_id = "" }, false, "#f4f4f4", null, "");
        try std.testing.expect(possible.unresolved and possible.background == null);
        const absent = try profile.resolveCellWithContextAndHints(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "" }, false, "#f4f4f4", null, "");
        try std.testing.expectEqualStrings("#f4f4f4", absent.background orelse return error.TestUnexpectedResult);
    }
}

test "typed text paint proves ancestor tags classes order and cascade without flattened aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const css = "div.NavFrame div.NavHead{font-weight:bold} .tunk a{color:#3366BB!important} .tunk a:active{color:#3366BB!important}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    const frame: TextElement = .{ .tag = "div", .classes = "NavFrame" };
    const head: TextElement = .{ .tag = "div", .classes = "NavHead", .parent = &frame };
    try std.testing.expect((try profile.resolveTextPaint(a, &head, "")).weight.?.value);
    const wrong_tag: TextElement = .{ .tag = "span", .classes = "NavFrame" };
    const wrong_parent: TextElement = .{ .tag = "div", .classes = "NavHead", .parent = &wrong_tag };
    try std.testing.expect((try profile.resolveTextPaint(a, &wrong_parent, "")).weight == null);
    const flattened: TextElement = .{ .tag = "div", .classes = "NavFrame NavHead" };
    try std.testing.expect((try profile.resolveTextPaint(a, &flattened, "")).weight == null);
    const sibling: TextElement = .{ .tag = "div", .classes = "NavHead" };
    try std.testing.expect((try profile.resolveTextPaint(a, &sibling, "")).weight == null);
    const hint: TextElement = .{ .tag = "span", .classes = "tunk" };
    const link: TextElement = .{ .tag = "a", .parent = &hint };
    try std.testing.expectEqualStrings("#3366bb", (try profile.resolveTextPaint(a, &link, "color:red")).color.?.value);
    try std.testing.expectEqualStrings("#ff0000", (try profile.resolveTextPaint(a, &link, "color:red!important")).color.?.value);
    try std.testing.expect(!(try profile.resolveTextPaint(a, &head, "font-weight:normal")).weight.?.value);
    try std.testing.expect((try profile.resolveTextPaint(a, &head, "font-weight:inherit")).weight.? == .inherit);
    const outside: TextElement = .{ .tag = "a" };
    try std.testing.expect((try profile.resolveTextPaint(a, &outside, "")).color == null);
    var uncertain = try parseAlloc(a, ".tunk a{color:blue} @media screen {.tunk a{color:red}} "); defer uncertain.deinit();
    try std.testing.expect((try uncertain.resolveTextPaint(a, &link, "")).color.? == .unknown);
    // An optional equal-valued state rule cannot override a later different
    // certain rule while being incorrectly treated as certainly selected.
    var state = try parseAlloc(a, ".tunk a{color:blue}.tunk a:active{color:blue} a{color:red!important}"); defer state.deinit();
    try std.testing.expectEqualStrings("#ff0000", (try state.resolveTextPaint(a, &link, "")).color.?.value);
    var id_profile = try parseAlloc(a, "div#frame.NavFrame div.NavHead{font-weight:bold}"); defer id_profile.deinit();
    try std.testing.expect((try id_profile.resolveTextPaint(a, &head, "")).weight == null);
    const id_frame: TextElement = .{ .tag = "div", .classes = "NavFrame", .id = "frame" };
    const id_head: TextElement = .{ .tag = "div", .classes = "NavHead", .parent = &id_frame };
    try std.testing.expect((try id_profile.resolveTextPaint(a, &id_head, "")).weight.?.value);
    var namespace = try parseAlloc(a, ".tunk a{color:blue}svg|a{color:red}"); defer namespace.deinit();
    try std.testing.expect((try namespace.resolveTextPaint(a, &link, "")).color.? == .unknown);
    var ordered = try parseAlloc(a, ".outer .middle a{font-weight:bold}"); defer ordered.deinit();
    const outer: TextElement = .{ .tag = "div", .classes = "outer" };
    const middle: TextElement = .{ .tag = "span", .classes = "middle", .parent = &outer };
    const ordered_link: TextElement = .{ .tag = "a", .parent = &middle };
    try std.testing.expect((try ordered.resolveTextPaint(a, &ordered_link, "")).weight.?.value);
    const reversed_outer: TextElement = .{ .tag = "div", .classes = "middle" };
    const reversed_middle: TextElement = .{ .tag = "span", .classes = "outer", .parent = &reversed_outer };
    const reversed_link: TextElement = .{ .tag = "a", .parent = &reversed_middle };
    try std.testing.expect((try ordered.resolveTextPaint(a, &reversed_link, "")).weight == null);
}

test "text font style cascade preserves inherited normal italic and unresolved selector bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".ib-content{font-style:italic}.ib-content i,.ib-content em{font-style:normal}body[class*=\"page-Template_table\"] .CategoryTreeLabel{font-style:inherit}"); defer profile.deinit();
    const label: TextElement = .{ .tag = "span", .classes = "ib-content label-content" };
    try std.testing.expect((try profile.resolveTextPaint(a, &label, "")).font_style.?.value);
    const child_i: TextElement = .{ .tag = "i", .parent = &label };
    const child_em: TextElement = .{ .tag = "em", .parent = &label };
    try std.testing.expect(!(try profile.resolveTextPaint(a, &child_i, "")).font_style.?.value);
    try std.testing.expect(!(try profile.resolveTextPaint(a, &child_em, "")).font_style.?.value);
    const outside_i: TextElement = .{ .tag = "i" };
    try std.testing.expect((try profile.resolveTextPaint(a, &outside_i, "")).font_style == null);
    try std.testing.expect(!(try profile.resolveTextPaint(a, &label, "font-style:normal")).font_style.?.value);
    try std.testing.expect((try profile.resolveTextPaint(a, &child_i, "font-style:italic")).font_style.?.value);
    try std.testing.expect((try profile.resolveTextPaint(a, &label, "font-style:inherit")).font_style.? == .inherit);
    const category: TextElement = .{ .tag = "span", .classes = "CategoryTreeLabel" };
    // The unsupported body predicate remains uncertain where the necessary
    // terminal class matches, but cannot erase unrelated ib-content paint.
    try std.testing.expect((try profile.resolveTextPaint(a, &category, "")).font_style.? == .unknown);
    var important = try parseAlloc(a, ".ib-content{font-style:normal!important}"); defer important.deinit();
    try std.testing.expect(!(try important.resolveTextPaint(a, &label, "font-style:italic")).font_style.?.value);
    try std.testing.expect((try important.resolveTextPaint(a, &label, "font-style:italic!important")).font_style.?.value);
    var conditional = try parseAlloc(a, ".ib-content{font-style:italic}@media screen{.ib-content{font-style:normal}}"); defer conditional.deinit();
    try std.testing.expect((try conditional.resolveTextPaint(a, &label, "")).font_style.? == .unknown);
    var equal_state = try parseAlloc(a, ".ib-content{font-style:italic}.ib-content:active{font-style:italic}"); defer equal_state.deinit();
    try std.testing.expect((try equal_state.resolveTextPaint(a, &label, "")).font_style.?.value);
    try std.testing.expect((try profile.resolveTextPaint(a, &label, "font-style:italic!important;font:initial")).font_style.?.value);
    try std.testing.expect(!(try profile.resolveTextPaint(a, &label, "font-style:italic;font:initial!important")).font_style.?.value);
    try std.testing.expect((try profile.resolveTextPaint(a, &label, "font-style:oblique 10deg")).font_style.? == .unknown);
}

test "complete authenticated BN stylesheet supplies ib content italic and descendant normal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    // Shared genuine fixture supplied by the existing BN full-page packet.
    const css = @embedFile("testdata/bn-longingly/common.css");
    var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(css, &digest, .{});
    try std.testing.expectEqualStrings("90d205550d9a15d001e25af98d9933e2ac7fed8337d902bb0b294d9c63ff2ec8", &std.fmt.bytesToHex(digest, .lower));
    var profile = try parseAlloc(a, css); defer profile.deinit();
    const accent: TextElement = .{ .tag = "span", .classes = "usage-label-accent" };
    const label: TextElement = .{ .tag = "span", .classes = "ib-content label-content", .parent = &accent };
    try std.testing.expect((try profile.resolveTextPaint(a, &label, "")).font_style.?.value);
    const child_i: TextElement = .{ .tag = "i", .parent = &label };
    const child_em: TextElement = .{ .tag = "em", .parent = &label };
    try std.testing.expect(!(try profile.resolveTextPaint(a, &child_i, "")).font_style.?.value);
    try std.testing.expect(!(try profile.resolveTextPaint(a, &child_em, "")).font_style.?.value);
    const outside_i: TextElement = .{ .tag = "i" };
    try std.testing.expect((try profile.resolveTextPaint(a, &outside_i, "")).font_style == null);
}

test "text paint literal values trim CSS whitespace and preserve unknown declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "span", .classes = "paint" };
    var spaced = try parseAlloc(a, ".paint{font-weight: \n bold \t; font-style: \t italic \n; color: #3366BB ;}"); defer spaced.deinit();
    const actual = try spaced.resolveTextPaint(a, &element, "");
    try std.testing.expect(actual.weight.?.value and actual.font_style.?.value);
    try std.testing.expectEqualStrings("#3366bb", actual.color.?.value);
    var compact = try parseAlloc(a, ".paint{font-weight:bold;font-style:italic;color:#3366BB}"); defer compact.deinit();
    try std.testing.expectEqualDeep(try compact.resolveTextPaint(a, &element, ""), actual);
    const normal = try spaced.resolveTextPaint(a, &element, " font-weight: normal ; font-style: normal ; ");
    try std.testing.expect(!normal.weight.?.value and !normal.font_style.?.value);
    const inherited = try spaced.resolveTextPaint(a, &element, "font-weight: inherit ; font-style: unset ;");
    try std.testing.expect(inherited.weight.? == .inherit and inherited.font_style.? == .inherit);
    const initial = try spaced.resolveTextPaint(a, &element, "font-weight: initial ;font-style: initial ;");
    try std.testing.expect(!initial.weight.?.value and !initial.font_style.?.value);
    const unresolved = try spaced.resolveTextPaint(a, &element, "font-weight: b old ;font-style: it alic ;");
    try std.testing.expect(unresolved.weight.? == .unknown and unresolved.font_style.? == .unknown);
    const variable = try spaced.resolveTextPaint(a, &element, "font-weight: var(--weight) ;font-style: var(--style) ;");
    try std.testing.expect(variable.weight.? == .unknown and variable.font_style.? == .unknown);
    var important = try parseAlloc(a, ".paint{font-weight: bold !important;font-style: italic !important}"); defer important.deinit();
    const protected = try important.resolveTextPaint(a, &element, "font-weight: normal ;font-style: normal ;");
    try std.testing.expect(protected.weight.?.value and protected.font_style.?.value);
    const inline_important = try important.resolveTextPaint(a, &element, "font-weight: normal !important ;font-style: normal !important ;");
    try std.testing.expect(!inline_important.weight.?.value and !inline_important.font_style.?.value);
}

test "font selector uses certified own attribute absence only and retains unknown legacy context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Proof = struct {
        state: AttributePresence,
        fn get(raw: ?*const anyopaque, key: []const u8) AttributePresence {
            const value: *const @This() = @ptrCast(@alignCast(raw orelse return .unknown));
            return if (std.ascii.eqlIgnoreCase(key, "dir")) value.state else .unknown;
        }
    };
    const absent: Proof = .{ .state = .absent };
    const present: Proof = .{ .state = .present };
    const unknown: Proof = .{ .state = .unknown };
    for ([_][]const u8{ "span[dir=\"rtl\"]", "span[DIR='rtl']", "span[dir]", "span[dir='']", ".lang-ms span[dir=\"rtl\"]", "div > span[dir='rtl']" }) |selector_text| {
        const css = try std.fmt.allocPrint(a, ".API{{font-size:110%}} {s}{{font-size:133%}}", .{selector_text});
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expect((try profile.resolveFontSize(a, "span", "API", "", "")).? == .unknown);
        const resolved = (try profile.resolveFontSizeWithAttributes(a, "span", "API", "", "", .{ .ctx = &absent, .get = Proof.get })).?;
        try std.testing.expect(resolved == .relative);
        try std.testing.expectApproxEqAbs(@as(f32, 1.1), resolved.relative, 0.000001);
        try std.testing.expect((try profile.resolveFontSizeWithAttributes(a, "span", "API", "", "", .{ .ctx = &present, .get = Proof.get })).? == .unknown);
        try std.testing.expect((try profile.resolveFontSizeWithAttributes(a, "span", "API", "", "", .{ .ctx = &unknown, .get = Proof.get })).? == .unknown);
    }
}

test "font attribute absence cannot escape functions relations or unproved selector syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Proof = struct {
        fn get(_: ?*const anyopaque, _: []const u8) AttributePresence { return .absent; }
    };
    for ([_][]const u8{
        "span:not([dir='rtl'])", "span:is([dir='rtl'])", "span:has([dir='rtl'])",
        "[dir='rtl'] span", "[dir='rtl'] > span", "[dir='rtl'] + span", "[dir='rtl'] ~ span",
        ".other + span[dir='rtl']", ".other ~ span[dir='rtl']", "sp\\61n[dir='rtl']",
        "span/*comment*/[dir='rtl']", "span[dir^='r']", "span[dir='rtl' i]",
        "span[dir='rtl'][other]", "span[dir='rtl']:hover", "span[dir='rtl']&",
    }) |selector_text| {
        const css = try std.fmt.allocPrint(a, ".API{{font-size:110%}} {s}{{font-size:133%}}", .{selector_text});
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expect((try profile.resolveFontSizeWithAttributes(a, "span", "API", "", "", .{ .ctx = null, .get = Proof.get })).? == .unknown);
    }
    // Escaping only the opening bracket leaves an unmatched closing bracket.
    // Keep malformed-sheet rejection distinct from valid escaped-selector uncertainty.
    try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, ".API{font-size:110%} span\\[dir='rtl']{font-size:133%}"));
}

test "decoded charset and counter descriptors preserve independent table cascade" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const declarations = "table.a{background:red;border:1px solid #ccc;border-collapse:collapse;float:left} table.a td{padding:2px}";
    var reference = try parseAlloc(a, declarations);
    defer reference.deinit();
    const expected = try reference.resolveTable(a, 0, "a", null, "");
    const expected_cell = try reference.resolveCell(a, expected.scope, false, null, "");
    const prefixes = [_][]const u8{
        "@charset \"utf-8\";",
        "/* already decoded */ @CHARSET\"utf-8\";",
        "@charset 'not-an-encoding-declaration';",
        "@counter-style lower-vietnamese { system:alphabetic; symbols:\"a\" \"b\"; }",
        "@media screen { @counter-style example { system:cyclic; symbols:\"x\"; } }",
        // Descriptor bodies are never element rules, even if invalid.
        "@counter-style example { table.a { background:blue!important } }",
    };
    for (prefixes, 0..) |prefix, index| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, declarations }));
        defer profile.deinit();
        try std.testing.expect(!profile.globally_unresolved);
        try std.testing.expectEqual(index >= 3, profile.has_unsupported_rules);
        try std.testing.expectEqualSlices(u32, reference.admitted_rule_numbers, profile.admitted_rule_numbers);
        const actual = try profile.resolveTable(a, 0, "a", null, "");
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqualDeep(expected_cell, try profile.resolveCell(a, actual.scope, false, null, ""));
        try std.testing.expectEqual(prefix.len + declarations.len, profile.sources[0].bytes);
    }
    for ([_][]const u8{
        "@charset-extra \"utf-8\";", "@charset\\78 \"utf-8\";",
        "@counter-style-extra name { system:cyclic; }", "@counter-style\\78 name { system:cyclic; }",
        "@import 'other.css';", "@namespace x url('urn:x');", "@font-face { font-family:x; src:url(x); }",
    }) |prefix| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, declarations }));
        defer profile.deinit();
        try std.testing.expect(profile.globally_unresolved and profile.has_unsupported_rules);
        try std.testing.expect((try profile.resolveTable(a, 0, "a", null, "border:1px solid red!important")).style == null);
    }
    for ([_][]const u8{
        "@charset \"unfinished;", "@charset \"utf-8\"", "@charset /* unfinished",
        "@counter-style x { symbols:\"unfinished; }", "@counter-style x { system:cyclic;",
    }) |invalid| try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, invalid));
}

test "retained VI full stylesheet preserves inline table paint with counter markers unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const css = @embedFile("testdata/vi-dau100/common.css");
    var profile = try parseAlloc(a, css);
    defer profile.deinit();
    var reference = try parseAlloc(a, "");
    defer reference.deinit();
    try std.testing.expect(!profile.globally_unresolved and profile.has_unsupported_rules);
    try std.testing.expectEqualStrings("35aa66753ce277ec32a63c12a6d85b9346ca0bf793dc7037e4f99cadc3dfb39a", &profile.sources[0].css_sha256);
    try std.testing.expectEqual(css.len, profile.sources[0].bytes);
    // Actual source grid declarations. No source sheet is stripped or replaced.
    const inline_css = "border:1px solid #ccc; border-collapse:collapse; float:left;";
    const actual = try profile.resolveTable(a, 0, "", null, inline_css);
    const expected = try reference.resolveTable(a, 0, "", null, inline_css);
    try std.testing.expect(actual.style != null and !actual.descendant_style_unresolved);
    try std.testing.expectEqualDeep(expected.style, actual.style);
    // The real sheet has ID/ancestor selectors; this legacy API supplies no
    // own-ID or ancestry certificate. Their uncertainty is independent of the
    // fully known inline paint and must not equal the empty sheet's status.
    try std.testing.expect(!expected.unresolved and actual.unresolved);
    var id_rule = try parseAlloc(a, "#interwiki-completelist { font-weight: bold; }");
    defer id_rule.deinit();
    const unknown_id = try id_rule.resolveTable(a, 0, "", null, inline_css);
    const absent_id = try id_rule.resolveTableWithContext(a, 0, "", .{ .own_id = "", .ancestor_classes = "" }, null, inline_css);
    try std.testing.expect(unknown_id.unresolved and !absent_id.unresolved);
    try std.testing.expectEqualDeep(expected.style, unknown_id.style);
    try std.testing.expectEqualDeep(expected.style, absent_id.style);
    // The named list-counter algorithm remains unsupported, not projected as
    // table declarations or claimed as faithful list-marker rendering.
    try std.testing.expect(profile.has_unsupported_rules);
}


test "typed font cascade proves ordered ancestors and keeps uncertain overrides unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "div.Frame{font-size:95%} div.Frame div.Content{font-size:100%} div#actual.Content{font-size:125%}");
    defer profile.deinit();
    const frame: TextElement = .{ .tag = "div", .classes = "Frame" };
    const content: TextElement = .{ .tag = "div", .classes = "Content", .parent = &frame };
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 0.95 }, (try profile.resolveFontSizeIn(a, &frame, "", null)).?);
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 1 }, (try profile.resolveFontSizeIn(a, &content, "", null)).?);
    const wrong_frame: TextElement = .{ .tag = "span", .classes = "Frame" };
    const wrong: TextElement = .{ .tag = "div", .classes = "Content", .parent = &wrong_frame };
    const flattened: TextElement = .{ .tag = "div", .classes = "Frame Content" };
    const unparented: TextElement = .{ .tag = "div", .classes = "Content" };
    try std.testing.expect(try profile.resolveFontSizeIn(a, &wrong, "", null) == null);
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 0.95 }, (try profile.resolveFontSizeIn(a, &flattened, "", null)).?);
    try std.testing.expect(try profile.resolveFontSizeIn(a, &unparented, "", null) == null);
    const identified: TextElement = .{ .tag = "div", .classes = "Content", .id = "actual", .parent = &frame };
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 1.25 }, (try profile.resolveFontSizeIn(a, &identified, "", null)).?);
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 0 }, (try profile.resolveFontSizeIn(a, &identified, "font-size:0!important", null)).?);
    try std.testing.expectEqualDeep(@as(FontSizeValue, .inherit), (try profile.resolveFontSizeIn(a, &identified, "font-size:inherit", null)).?);
    try std.testing.expectEqualDeep(FontSizeValue{ .absolute = 1 }, (try profile.resolveFontSizeIn(a, &identified, "all:initial", null)).?);
    for ([_][]const u8{
        "div.Content:hover{font-size:200%}",
        "@media screen{div.Frame div.Content{font-size:200%}}",
        "div.Frame + div.Content{font-size:200%}",
        "div.Content{font:12px unknown}",
        "div.Content{font-size:var(--unknown)}",
        "svg|div.Content{font-size:200%}",
    }) |css| {
        var uncertain = try parseAlloc(a, css); defer uncertain.deinit();
        try std.testing.expect((try uncertain.resolveFontSizeIn(a, &content, "", null)).? == .unknown);
        try std.testing.expectEqualDeep(FontSizeValue{ .relative = 1 }, (try uncertain.resolveFontSizeIn(a, &content, "font-size:100%!important", null)).?);
    }
    var important = try parseAlloc(a, "div.Frame div.Content{font-size:125%!important}"); defer important.deinit();
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 1.25 }, (try important.resolveFontSizeIn(a, &content, "font-size:80%", null)).?);
    // The composed child matcher now supplies exact font ancestry too.
    var direct = try parseAlloc(a, "div.Frame>div.Content{font-size:125%}"); defer direct.deinit();
    try std.testing.expectEqualDeep(FontSizeValue{ .relative = 1.25 }, (try direct.resolveFontSizeIn(a, &content, "", null)).?);
    try std.testing.expect(try direct.resolveFontSizeIn(a, &wrong, "", null) == null);
    const between: TextElement = .{ .tag = "span", .parent = &frame };
    const nested_content: TextElement = .{ .tag = "div", .classes = "Content", .parent = &between };
    try std.testing.expect(try direct.resolveFontSizeIn(a, &nested_content, "", null) == null);
    var attribute = try parseAlloc(a, "div.Content[title]{font-size:200%}"); defer attribute.deinit();
    const Absent = struct { fn get(_: ?*const anyopaque, _: []const u8) AttributePresence { return .absent; } };
    try std.testing.expect(try attribute.resolveFontSizeIn(a, &content, "", .{ .ctx = null, .get = Absent.get }) == null);
    try std.testing.expect((try attribute.resolveFontSizeIn(a, &content, "", null)).? == .unknown);
}


test "typed direct-child font rules require the immediate authored parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent: TextElement = .{ .tag = "div", .classes = "translations" };
    const child: TextElement = .{ .tag = "dfn", .parent = &parent };
    for ([_][]const u8{ "div.translations > dfn", "div.translations>dfn", "div.translations >dfn", "div.translations> dfn" }) |selector| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{font-weight:bold;font-style:normal}}", .{selector}));
        defer profile.deinit();
        const actual = try profile.resolveTextPaint(a, &child, "");
        try std.testing.expectEqualDeep(TextWeight{ .value = true }, actual.weight.?);
        try std.testing.expectEqualDeep(TextFontStyle{ .value = false }, actual.font_style.?);
        const wrong_tag: TextElement = .{ .tag = "span", .classes = "translations" };
        const wrong_class: TextElement = .{ .tag = "div", .classes = "other" };
        const intermediate: TextElement = .{ .tag = "span", .parent = &parent };
        const sibling: TextElement = .{ .tag = "div" };
        const nested: TextElement = .{ .tag = "dfn", .parent = &intermediate };
        const flattened: TextElement = .{ .tag = "dfn", .classes = "translations" };
        for ([_]TextElement{ .{ .tag = "dfn", .parent = &wrong_tag }, .{ .tag = "dfn", .parent = &wrong_class }, nested, flattened, .{ .tag = "dfn", .parent = &sibling }, .{ .tag = "dfn" } }) |wrong| {
            const result = try profile.resolveTextPaint(a, &wrong, "");
            try std.testing.expect(result.weight == null and result.font_style == null);
        }
        const inline_override = try profile.resolveTextPaint(a, &child, "font-weight:normal!important;font-style:italic!important");
        try std.testing.expectEqualDeep(TextWeight{ .value = false }, inline_override.weight.?);
        try std.testing.expectEqualDeep(TextFontStyle{ .value = true }, inline_override.font_style.?);
    }
    const outer: TextElement = .{ .tag = "section" };
    const middle: TextElement = .{ .tag = "div", .classes = "translations", .parent = &outer };
    const leaf: TextElement = .{ .tag = "dfn", .parent = &middle };
    var chain = try parseAlloc(a, "section>div.translations>dfn{font-weight:bold;font-style:normal}"); defer chain.deinit();
    try std.testing.expectEqualDeep(TextWeight{ .value = true }, (try chain.resolveTextPaint(a, &leaf, "")).weight.?);
    var descendant = try parseAlloc(a, "div.translations dfn{font-weight:bold}"); defer descendant.deinit();
    const inside: TextElement = .{ .tag = "span", .parent = &parent };
    const deep: TextElement = .{ .tag = "dfn", .parent = &inside };
    try std.testing.expectEqualDeep(TextWeight{ .value = true }, (try descendant.resolveTextPaint(a, &deep, "")).weight.?);
    for ([_][]const u8{
        "@media screen{div.translations>dfn{font-weight:bold;font-style:normal}}",
        "div.translations>dfn:hover{font-weight:bold;font-style:normal}",
        "section div.translations>dfn{font-weight:bold;font-style:normal}",
        "section>div.translations dfn{font-weight:bold;font-style:normal}",
        "div.translations+dfn{font-weight:bold;font-style:normal}",
        "svg|div.translations>dfn{font-weight:bold;font-style:normal}",
        "div.translations>>dfn{font-weight:bold;font-style:normal}",
    }) |css| {
        var unknown = try parseAlloc(a, css); defer unknown.deinit();
        const result = try unknown.resolveTextPaint(a, &leaf, "");
        try std.testing.expect(result.weight.? == .unknown and result.font_style.? == .unknown);
    }
}


test "text paint preserves positive descendant compounds around unknown pseudo states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outer: TextElement = .{ .tag = "div", .classes = "partlynew", .id = "p-personal" };
    const middle: TextElement = .{ .tag = "span", .parent = &outer };
    const unrelated: TextElement = .{ .tag = "span", .classes = "example-block" };
    const outside: TextElement = .{ .tag = "b", .parent = &unrelated };
    const inside: TextElement = .{ .tag = "a", .parent = &middle };
    for ([_][]const u8{ ".partlynew :link", ".partlynew :visited", "#p-personal :link" }) |selector| {
        errdefer std.debug.print("text-paint pseudo selector={s}\n", .{selector});
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{color:red}}", .{selector}));
        defer profile.deinit();
        try std.testing.expect((try profile.resolveTextPaint(a, &outside, "")).color == null);
        try std.testing.expect((try profile.resolveTextPaint(a, &inside, "")).color.? == .unknown);
        const own_only: TextElement = .{ .tag = "a", .classes = "partlynew", .id = "p-personal" };
        try std.testing.expect((try profile.resolveTextPaint(a, &own_only, "")).color == null);
        try std.testing.expectEqualStrings("#006400", (try profile.resolveTextPaint(a, &inside, "color:darkgreen")).color.?.value);
    }
    var suffix = try parseAlloc(a, "#p-personal :link.partlynew{color:red}");
    defer suffix.deinit();
    const own_match: TextElement = .{ .tag = "a", .classes = "partlynew", .parent = &middle };
    try std.testing.expect((try suffix.resolveTextPaint(a, &own_match, "")).color.? == .unknown);
    // A class on an ancestor does not satisfy the compound's own class.
    try std.testing.expect((try suffix.resolveTextPaint(a, &inside, "")).color == null);
    const no_id: TextElement = .{ .tag = "a", .classes = "partlynew", .parent = &unrelated };
    try std.testing.expect((try suffix.resolveTextPaint(a, &no_id, "")).color == null);
    var ordered = try parseAlloc(a, ".outer :hover .leaf{color:red}");
    defer ordered.deinit();
    const ordered_root: TextElement = .{ .tag = "div", .classes = "outer" };
    const unknown_middle: TextElement = .{ .tag = "span", .parent = &ordered_root };
    const leaf: TextElement = .{ .tag = "b", .classes = "leaf", .parent = &unknown_middle };
    try std.testing.expect((try ordered.resolveTextPaint(a, &leaf, "")).color.? == .unknown);
    const missing_middle: TextElement = .{ .tag = "b", .classes = "leaf", .parent = &ordered_root };
    try std.testing.expect((try ordered.resolveTextPaint(a, &missing_middle, "")).color == null);
    const copied: TextElement = .{ .tag = "b", .classes = "outer leaf" };
    try std.testing.expect((try ordered.resolveTextPaint(a, &copied, "")).color == null);
    // Unsafe grammar never borrows classes from a function/escape/sibling.
    for ([_][]const u8{ ":not(.absent)", ":is(.absent,:link)", ".absent + :link", ".absent\\:escaped :link", ":link\\31.absent", "::before", ":" }) |selector| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{color:red}}", .{selector}));
        defer profile.deinit();
        try std.testing.expect((try profile.resolveTextPaint(a, &outside, "")).color.? == .unknown);
    }
}

test "table box stylesheet width padding and clear obey ordinary cascade and CSS resets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".box{width:20em;padding:.2em;clear:left} .box{width:75%!important}");
    defer profile.deinit();
    const actual = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "" }, null, "width:10px;padding:1px 2px 3px 4px;clear:both");
    try std.testing.expect(actual.width_specified and !actual.unresolved);
    const style = actual.style orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .percent, .value = 75 }, style.width.?);
    try std.testing.expectEqual(types.FigureClear.both, style.clear.?);
    try std.testing.expectEqualDeep(types.StyleEdges{ .top = .{ .unit = .px, .value = 1 }, .right = .{ .unit = .px, .value = 2 }, .bottom = .{ .unit = .px, .value = 3 }, .left = .{ .unit = .px, .value = 4 } }, style.padding.?);
    const automatic = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "" }, null, "width:auto!important;clear:none");
    try std.testing.expect(automatic.width_specified and automatic.style.?.width == null and !automatic.unresolved);
    try std.testing.expectEqual(types.FigureClear.none, automatic.style.?.clear.?);
    const zero = try resolveInlineTableAlloc(a, "width:0;padding:0;clear:none");
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 0 }, zero.style.?.width.?);
    try std.testing.expectEqualDeep(types.StyleEdges.all(.{ .unit = .px, .value = 0 }), zero.style.?.padding.?);
    const absent = try resolveInlineTableAlloc(a, "");
    try std.testing.expect(!absent.width_specified and absent.style == null);
}

test "table box invalid declarations do not win and unsupported winners cannot revive numeric width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "-1px", "-2%", "nanpx", "infem", "banana", "5px 6px", "5% 6%", "0x0p0", "1_0px", "1.px", "1e-1000", "-1e-1000px" }) |invalid| {
        const css = try std.fmt.allocPrint(a, "width:23px;width:{s}", .{invalid});
        const resolved = try resolveInlineTableAlloc(a, css);
        try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 23 }, resolved.style.?.width.?);
        try std.testing.expect(resolved.width_specified and !resolved.unresolved);
    }
    for ([_][]const u8{ "calc(100% - 1px)", "var(--width)", "inherit", "10rem", "min-content", "max-content", "fit-content", "stretch", "1e100px" }) |unknown| {
        const css = try std.fmt.allocPrint(a, "width:23px;width:{s};padding:2px", .{unknown});
        const resolved = try resolveInlineTableAlloc(a, css);
        try std.testing.expect(resolved.width_specified and resolved.unresolved and resolved.style.?.width == null);
        try std.testing.expectEqual(@as(f32, 2), resolved.style.?.padding.?.top.value);
    }
    var profile = try parseAlloc(a, ".box{width:20em;padding:.2em;clear:left}.box:hover{width:50%}");
    defer profile.deinit();
    const uncertain = try profile.resolveTableWithContext(a, 0, "box", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    try std.testing.expect(uncertain.width_specified and uncertain.unresolved and uncertain.style.?.width == null);
    try std.testing.expectEqual(types.FigureClear.left, uncertain.style.?.clear.?);
    try std.testing.expectEqual(@as(f32, 0.2), uncertain.style.?.padding.?.top.value);
}

test "table width CSS zero and box sizing cannot revive overridden width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "0.0", "+0", "-0", ".0", "0e1", "-0.0e-1" }) |zero| {
        const css = try std.fmt.allocPrint(a, "width:23px;width:{s}", .{zero});
        const actual = try resolveInlineTableAlloc(a, css);
        try std.testing.expect(actual.width_specified and !actual.unresolved);
        try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 0 }, actual.style.?.width.?);
    }
    for ([_][]const u8{ "content-box", "initial", "inherit", "var(--box)" }) |box| {
        const css = try std.fmt.allocPrint(a, "width:23px;box-sizing:{s};padding:2px", .{box});
        const actual = try resolveInlineTableAlloc(a, css);
        try std.testing.expect(actual.width_specified and actual.unresolved and actual.style.?.width == null);
        try std.testing.expectEqual(@as(f32, 2), actual.style.?.padding.?.left.value);
    }
    const border_box = try resolveInlineTableAlloc(a, "width:23px;box-sizing:border-box;box-sizing:banana");
    try std.testing.expect(!border_box.unresolved);
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 23 }, border_box.style.?.width.?);
}

test "inline table box padding retains the proved border model and refuses an unknown one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const collapsed = try resolveInlineTableAlloc(a, "width:20em;padding:.2em;border-collapse:collapse");
    try std.testing.expect(!collapsed.unresolved);
    try std.testing.expectEqual(types.BorderCollapse.collapse, collapsed.style.?.collapse.?);
    try std.testing.expectEqual(@as(f32, 0.2), collapsed.style.?.padding.?.top.value);
    const separate = try resolveInlineTableAlloc(a, "padding:3px;border-collapse:separate");
    try std.testing.expectEqual(types.BorderCollapse.separate, separate.style.?.collapse.?);
    try std.testing.expectEqual(@as(f32, 3), separate.style.?.padding.?.top.value);
    const unknown = try resolveInlineTableAlloc(a, "width:23px;padding:3px;border-collapse:var(--model)");
    try std.testing.expect(unknown.unresolved and unknown.style.?.padding == null and unknown.style.?.collapse == null);
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 23 }, unknown.style.?.width.?);
}

pub fn resolveInlineBlockGeometryAlloc(a: std.mem.Allocator, tag: []const u8, css: []const u8) std.mem.Allocator.Error!BlockGeometryResolution {
    if (css.len > max_css_bytes) return .{ .unresolved = true };
    var cascade_value: BlockGeometryCascade = .{};
    defer cascade_value.possible.deinit(a);
    try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
    return cascade_value.result(std.ascii.eqlIgnoreCase(tag, "div"));
}

test "transparent paragraph geometry uses typed ancestry physical edges cascade and possible winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a,
        "div.outer > div.note {padding-left:1.6em;margin-bottom:.5em}" ++
        "div.note {margin-top:2px} div.note {margin-top:3px!important}" ++
        "@media print {div.note {padding-right:4px}}" ++
        "div.note {padding-right:0!important}");
    defer profile.deinit();
    const outer: TextElement = .{ .tag = "div", .classes = "outer" };
    const inner: TextElement = .{ .tag = "div", .classes = "note", .parent = &outer };
    const got = try profile.resolveBlockGeometryIn(a, &inner, "margin-top:9px");
    try std.testing.expect(!got.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, got.style.?.padding.?.left);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 0 }, got.style.?.padding.?.right);
    try std.testing.expectEqual(@as(f32, 3), got.style.?.margins.?.top.value);
    try std.testing.expectEqual(@as(f32, 0.5), got.style.?.margins.?.bottom.value);
    const wrong: TextElement = .{ .tag = "span", .classes = "outer" };
    const wrong_child: TextElement = .{ .tag = "div", .classes = "note", .parent = &wrong };
    const wrong_result = try profile.resolveBlockGeometryIn(a, &wrong_child, "");
    try std.testing.expect(wrong_result.style.?.padding.?.left.value == 0);
    const middle: TextElement = .{ .tag = "span", .parent = &outer };
    const nested: TextElement = .{ .tag = "div", .classes = "note", .parent = &middle };
    try std.testing.expect((try profile.resolveBlockGeometryIn(a, &nested, "")).style.?.padding.?.left.value == 0);
    const overridden = try profile.resolveBlockGeometryIn(a, &inner, "margin-top:9px!important");
    try std.testing.expectEqual(@as(f32, 9), overridden.style.?.margins.?.top.value);
    var state = try parseAlloc(a, "div.note:hover{padding-left:0}"); defer state.deinit();
    // Conditional zero must not falsely erase the absent-property reader gap.
    try std.testing.expect((try state.resolveBlockGeometryIn(a, &inner, "")).unresolved);
    var possible = try parseAlloc(a, "div.note{padding:1px}div.note:hover{padding-left:2px}"); defer possible.deinit();
    try std.testing.expect((try possible.resolveBlockGeometryIn(a, &inner, "")).unresolved);
    try std.testing.expect(!(try possible.resolveBlockGeometryIn(a, &inner, "padding:3px!important")).unresolved);
    for ([_][]const u8{ "padding:1px;float:left", "padding:1px;background:red", "padding:1px;width:50%", "padding:1px;line-height:2", "padding:1px;margin-inline:2px", "padding:var(--x)", "padding:-1px", "all:initial;padding:1px" }) |css|
        try std.testing.expect((try resolveInlineBlockGeometryAlloc(a, "div", css)).unresolved);
    try std.testing.expect((try resolveInlineBlockGeometryAlloc(a, "p", "margin-bottom:1px")).unresolved);
    const p = try resolveInlineBlockGeometryAlloc(a, "p", "margin:0;padding:1px 2px 3px 4px");
    try std.testing.expect(!p.unresolved and p.style.?.margins.?.bottom.value == 0 and p.style.?.padding.?.left.value == 4);
    try std.testing.expect((try resolveInlineBlockGeometryAlloc(a, "div", "font-style:italic")).style == null);
}

// Figure declarations use the same bounded selector/declaration parser, but a
// separate inventory: unrelated table/font projections keep their old counts.
pub const FigureStyle = struct {
    min_width: ?types.StyleLength = null,
    margins: ?types.StyleEdges = null,
    padding: ?types.StyleEdges = null,
    background: ?types.FigureColor = null,
    color: ?types.FigureColor = null,
    border: ?types.FigureBorder = null,
    placement: ?types.FigurePlacement = null,
    clear: ?types.FigureClear = null,
    text_align: ?types.CellTextAlign = null,
    line_height: ?types.StyleLength = null,
    margin_mask: u8 = 0,
    padding_mask: u8 = 0,
    unresolved: bool = false,
};
const FigureProperty = enum {
    margin_top, margin_right, margin_bottom, margin_left,
    padding_top, padding_right, padding_bottom, padding_left,
    background, color, border, float_side, clear, text_align, line_height, min_width,
};
const FigureWinner = struct { raw: []const u8, priority: Priority };
const FigureWinners = struct {
    values: [@typeInfo(FigureProperty).@"enum".field_names.len]?FigureWinner = @splat(null),
    unresolved: bool = false,
    fn put(self: *FigureWinners, property: FigureProperty, raw: []const u8, priority: Priority) void {
        const slot = &self.values[@intFromEnum(property)];
        if (slot.* == null or priority.wins(slot.*.?.priority)) slot.* = .{ .raw = raw, .priority = priority };
    }
    fn declarations(self: *FigureWinners, a: std.mem.Allocator, rule: TextRule) !void {
        var pos: usize = 0;
        var order = rule.order;
        while (try nextDeclarationAlloc(a, rule.css, &pos)) |raw| {
            order += 1;
            if (trim(raw).len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse { self.unresolved = true; continue; };
            const name = trim(raw[0..colon]);
            // Text weight/style have independent cascades. Their selector
            // uncertainty must not become box uncertainty. Font-size keeps
            // the earlier guard because it can alter descendant em geometry.
            if (std.ascii.eqlIgnoreCase(name, "font-weight") or std.ascii.eqlIgnoreCase(name, "font-style")) continue;
            const parsed = customPriority(raw[colon + 1 ..]);
            if (parsed.unknown or rule.selector.uncertain) { self.unresolved = true; continue; }
            const priority: Priority = .{ .specificity = rule.selector.specificity, .order = order, .important = parsed.important };
            const value = trim(parsed.value);
            if (std.ascii.eqlIgnoreCase(name, "margin") or std.ascii.eqlIgnoreCase(name, "padding")) {
                // Expand before cascading, so later longhands and importance
                // retain their independent side priorities.
                var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
                var parts: [4][]const u8 = undefined;
                var count: usize = 0;
                while (words.next()) |part| {
                    if (count == 4) { self.unresolved = true; break; }
                    parts[count] = part; count += 1;
                }
                if (count == 0 or words.next() != null) { self.unresolved = true; continue; }
                const four: [4][]const u8 = switch (count) {
                    1 => @splat(parts[0]),
                    2 => .{ parts[0], parts[1], parts[0], parts[1] },
                    3 => .{ parts[0], parts[1], parts[2], parts[1] },
                    else => parts,
                };
                const first: usize = if (std.ascii.eqlIgnoreCase(name, "margin")) 0 else 4;
                for (four, 0..) |part, index| self.put(@enumFromInt(first + index), part, priority);
                continue;
            }
            const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left", "padding-top", "padding-right", "padding-bottom", "padding-left", "background", "color", "border", "float", "clear", "text-align", "line-height", "min-width" };
            var found = false;
            for (names, 0..) |known, index| if (std.ascii.eqlIgnoreCase(name, known) or (index == 8 and std.ascii.eqlIgnoreCase(name, "background-color"))) {
                self.put(@enumFromInt(index), value, priority); found = true; break;
            };
            if (found) continue;
            if (std.ascii.eqlIgnoreCase(name, "font-size")) continue;
            // Other possible geometry/paint effects remain explicitly unknown.
            self.unresolved = true;
        }
    }
};
fn figureLength(raw: []const u8, font_scale: f32) ?types.StyleLength {
    var result = length(raw) orelse return null;
    if (result.unit == .em) result.value *= font_scale;
    return if (types.validStyleLength(result)) result else null;
}
fn figureColor(a: std.mem.Allocator, raw: []const u8) !?types.FigureColor {
    if (std.ascii.eqlIgnoreCase(raw, "transparent")) return .{ .kind = .transparent };
    const rgb = try canonicalColorAlloc(a, raw) orelse return null;
    return .{ .kind = .rgb, .value = rgb };
}
fn figureBorder(a: std.mem.Allocator, raw: []const u8, font_scale: f32) !?types.FigureBorder {
    if (std.ascii.eqlIgnoreCase(raw, "none") or std.mem.eql(u8, raw, "0")) return .{ .kind = .none };
    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    var width: ?types.StyleLength = null;
    var color: ?types.FigureColor = null;
    var solid = false;
    var count: usize = 0;
    while (tokens.next()) |token| {
        count += 1;
        if (std.ascii.eqlIgnoreCase(token, "solid") and !solid) solid = true else if (figureLength(token, font_scale)) |v| {
            if (width != null) return null; width = v;
        } else if (try figureColor(a, token)) |v| {
            if (color != null) return null; color = v;
        } else return null;
    }
    if (count != 3 or !solid or width == null or color == null) return null;
    return .{ .kind = .solid, .width = width, .color = color };
}
fn resolveFigureStyle(profile: *const Profile, a: std.mem.Allocator, element: *const TextElement, font_scale: f32, rtl: bool) !FigureStyle {
    var winners: FigureWinners = .{};
    for (profile.figure_rules) |rule| {
        if (rule.selector.matches(element)) {
            if (figureTypeofUnknown(rule.selector, element)) return .{ .unresolved = true };
            try winners.declarations(a, rule);
        } else if (figureOuterSelectorUnknown(rule.selector, element)) {
            return .{ .unresolved = true };
        }
    }
    var result: FigureStyle = .{ .unresolved = profile.globally_unresolved or winners.unresolved };
    if (!std.math.isFinite(font_scale) or font_scale < 0) { result.unresolved = true; return result; }
    var margin = types.StyleEdges.all(.{ .unit = .px, .value = 0 });
    var padding = margin;
    var margin_bits: u8 = 0;
    var padding_bits: u8 = 0;
    for (winners.values, 0..) |slot, index| if (slot) |win| {
        if (index < 8) {
            const v = figureLength(win.raw, font_scale) orelse { result.unresolved = true; continue; };
            const output = if (index < 4) &margin else &padding;
            switch (index % 4) { 0 => output.top = v, 1 => output.right = v, 2 => output.bottom = v, 3 => output.left = v, else => unreachable }
            if (index < 4) margin_bits |= @as(u8, 1) << @intCast(index) else padding_bits |= @as(u8, 1) << @intCast(index - 4);
            continue;
        }
        const raw = win.raw;
        switch (@as(FigureProperty, @enumFromInt(index))) {
            .min_width => {
                const value = styleWidth(raw) orelse { result.unresolved = true; continue; };
                if (value.unit != .px) { result.unresolved = true; continue; }
                result.min_width = .{ .unit = .px, .value = value.value };
            },
            .background => { result.background = try figureColor(a, raw); result.unresolved = result.unresolved or result.background == null; },
            .color => { result.color = try figureColor(a, raw); result.unresolved = result.unresolved or result.color == null; },
            .border => { result.border = try figureBorder(a, raw, font_scale); result.unresolved = result.unresolved or result.border == null; },
            .float_side => {
                result.placement = if (std.ascii.eqlIgnoreCase(raw, "none")) .none else if (std.ascii.eqlIgnoreCase(raw, "left")) .float_left else if (std.ascii.eqlIgnoreCase(raw, "right")) .float_right else null;
                result.unresolved = result.unresolved or result.placement == null;
            },
            .clear => { result.clear = std.meta.stringToEnum(types.FigureClear, raw); result.unresolved = result.unresolved or result.clear == null; },
            .text_align => {
                result.text_align = if (std.ascii.eqlIgnoreCase(raw, "start")) (if (rtl) .right else .left) else if (std.ascii.eqlIgnoreCase(raw, "end")) (if (rtl) .left else .right) else std.meta.stringToEnum(types.CellTextAlign, raw);
                result.unresolved = result.unresolved or result.text_align == null;
            },
            .line_height => {
                if (figureLength(raw, font_scale)) |v| result.line_height = v else if (std.fmt.parseFloat(f32, raw)) |number| {
                    const v: types.StyleLength = .{ .unit = .em, .value = number * font_scale };
                    if (types.validStyleLength(v)) result.line_height = v;
                } else |_| {}
                result.unresolved = result.unresolved or result.line_height == null;
            },
            else => unreachable,
        }
    };
    // Partial side overrides need default-aware merging at the caller.
    result.margin_mask = margin_bits;
    result.padding_mask = padding_bits;
    if (margin_bits != 0) result.margins = margin;
    if (padding_bits != 0) result.padding = padding;
    return result;
}

test "figure custom definitions do not poison direct geometry and remain available to variable consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const css = ":root{--ink:#123456;--spacing:4px}figure{margin:2px;background:#abcdef}";
    var actual = try parseAlloc(a, css); defer actual.deinit();
    var reference = try parseAlloc(a, "figure{margin:2px;background:#abcdef}"); defer reference.deinit();
    const figure: TextElement = .{ .tag = "figure" };
    const actual_style = try actual.resolveFigure(a, &figure, 1, false);
    try std.testing.expect(!actual_style.unresolved);
    try std.testing.expectEqualDeep(try reference.resolveFigure(a, &figure, 1, false), actual_style);
    try std.testing.expect(actual_style.background != null);
    try std.testing.expectEqual(types.FigureColorKind.rgb, actual_style.background.?.kind);
    try std.testing.expect(actual_style.background.?.value != null);
    try std.testing.expectEqualStrings("#abcdef", actual_style.background.?.value.?);
    try std.testing.expectEqual(@as(f32, 2), actual_style.margins.?.left.value);
    try attachCustomProperties(&actual, &.{.{ .css = css, .base_url = "" }}, .{
        .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
    });
    try CustomPropertyFixture.known(actual.custom_properties.?.root_environment, "--ink", "#123456");
    for ([_][]const u8{
        ":root{--ink:#123456}figure{color:var(--ink)}",
        ":root{--ink:#123456}figure{color:var(--ink,#abcdef)}",
        ":root{--ink:#123456;background:#abcdef}",
        "@media (min-width:700px){figure{margin:2px}}",
    }) |source| {
        var profile = try parseAlloc(a, source); defer profile.deinit();
        try std.testing.expect((try profile.resolveFigure(a, &figure, 1, false)).unresolved);
    }
}

test "complete figure content ancestry retains authored and uncertain selector constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    const anchor: TextElement = .{ .tag = "a", .parent = &frame };
    const fragment_frame: TextElement = .{ .tag = "figure" };
    const fragment_anchor: TextElement = .{ .tag = "a", .parent = &fragment_frame };
    for ([_][]const u8{
        "#p-cactions li#ca-stable a{background:red}",
        ".audiolink a{padding-left:20px}",
        "#mw-content-text a[href*=\"//de.wiktionary.org\"]{padding:0}",
        "#outside a[title=\"an embedded > .audiolink word\"]{color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect(!(try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
        try std.testing.expect((try profile.resolveFigure(a, &fragment_anchor, 1, false)).unresolved);
    }
    const audio: TextElement = .{ .tag = "div", .classes = "audiolink", .parent = &root };
    const authored_frame: TextElement = .{ .tag = "figure", .parent = &audio };
    const authored_anchor: TextElement = .{ .tag = "a", .parent = &authored_frame };
    var matching = try parseAlloc(a, ".audiolink a{padding-left:20px}"); defer matching.deinit();
    const matched = try matching.resolveFigure(a, &authored_anchor, 1, false);
    try std.testing.expect(!matched.unresolved);
    try std.testing.expectEqual(@as(f32, 20), matched.padding.?.left.value);
    for ([_][]const u8{
        ".mw-parser-output a[href*=\"/wiki/\"]{padding:0}",
        ".audiolink a:hover{color:red}",
        "@supports(display:grid){.audiolink a{padding-left:20px}}",
        ".audiolink a{color:var(--ink)}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveFigure(a, &authored_anchor, 1, false)).unresolved);
    }
}

test "unknown content root direction separates generated resolution from later caption dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var generated = try parseAlloc(a, ".mw-content-rtl figure{margin-top:9px}"); defer generated.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.generated_only, generated.figureRootDirectionUse(null));
    var child = try parseAlloc(a, ".mw-content-rtl figcaption a{font-weight:bold}"); defer child.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, child.figureRootDirectionUse(null));
    const authored: TextElement = .{ .tag = "div", .classes = "mw-content-rtl", .source_key = 1 };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, child.figureRootDirectionUse(&authored));
    const detached: TextElement = .{ .tag = "div", .classes = "mw-content-rtl" };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, child.figureRootDirectionUse(&detached));
    const outer: TextElement = .{ .tag = "div", .classes = "other", .source_key = 2 };
    const inner: TextElement = .{ .tag = "div", .classes = "mw-content-rtl", .source_key = 3, .parent = &outer };
    var ordered = try parseAlloc(a, ".mw-content-rtl .other a{font-weight:bold}"); defer ordered.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, ordered.figureRootDirectionUse(&inner));
    var necessary = try parseAlloc(a, ".other.mw-content-rtl figcaption a{font-weight:bold}"); defer necessary.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, necessary.figureRootDirectionUse(null));
    const custom_css = ".mw-content-rtl{--ink:#123456}";
    var custom = try parseAlloc(a, custom_css); defer custom.deinit();
    try attachCustomProperties(&custom, &.{.{ .css = custom_css, .base_url = "" }}, .{
        .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
    });
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, custom.figureRootDirectionUse(null));
}

test "unknown content root predicates survive attribute functional and reduced selector ancestry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "div[dir=rtl] figcaption a{color:red}",
        "div[lang=de] figcaption a{color:red}",
        ":is(div[dir=rtl]) figcaption a{color:red}",
        ":not([dir=ltr]) figcaption a{color:red}",
        ".mw-content-rtl > figure figcaption a{color:red}",
        "figcaption a:dir(rtl){color:red}",
        "figcaption a:LANG(de){color:red}",
        "figcaption a:not(:dir(ltr)){color:red}",
        "figcaption a:is(.mw-content-rtl a){color:red}",
        "figcaption a:where(.mw-content-rtl a){color:red}",
        "figcaption a:not(.mw-content-rtl a){color:red}",
        "figcaption a:has(.mw-content-rtl a){color:red}",
        "figcaption a:not(:is(.mw-content-rtl a)){color:red}",
        "figcaption a:nth-child(even of .mw-content-rtl a){color:red}",
        "figcaption a:nth-child(n){color:red}",
        "figcaption a:unknown(foo){color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
    // Unsupported predicates do not erase a necessary root-excluding compound.
    for ([_][]const u8{
        "#skin[dir=rtl] figcaption a{color:red}",
        ".other[dir=rtl] figcaption a{color:red}",
        ".uetab ~ ul{display:none}",
        "table.prettytable > * > tr > td{color:red}",
        "a[title=\":dir(rtl)\"]{color:red}",
        "table.wikitable tr:nth-child(even){color:red}",
        "table.wikitable tr:not(:first-child){color:red}",
        "html.skin-theme-clientpref-night .darkmode:not(.notheme .darkmode){color:red}",
        "figcaption a:is(.other a){color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
    }
    for ([_][]const u8{
        "div[dir=rtl]{--ink:red}",
        "div[lang=de] figcaption a{--ink:red}",
        ":is(div[dir=rtl]) figcaption a{--ink:red}",
        "figcaption a:dir(rtl){--ink:red}",
        "figcaption a:not(:lang(de)){--ink:red}",
        "figcaption a:is(.mw-content-rtl a){--ink:red}",
        "figcaption a:where(:not(.mw-content-rtl a)){--ink:red}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try attachCustomProperties(&profile, &.{.{ .css = css, .base_url = "" }}, .{
            .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
        });
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
}


test "Figure minimum width follows exact generated typeof token cascade and keeps unknown attribute domains strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .typeof_tokens = "", .classes = "mw-parser-output", .ancestry_complete = true };
    const thumb: TextElement = .{ .tag = "figure", .typeof_tokens = "mw:File/Thumb", .parent = &root };
    const framed: TextElement = .{ .tag = "figure", .typeof_tokens = "mw:File/Frame", .parent = &root };
    const absent: TextElement = .{ .tag = "figure", .typeof_tokens = "", .parent = &root };
    const unknown: TextElement = .{ .tag = "figure", .parent = &root };
    const css = "figure[typeof~='mw:File/Thumb'],figure[typeof~='mw:File/Frame'],.thumbinner{min-width:100px}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    for ([_]*const TextElement{ &thumb, &framed }) |element| {
        const value = try profile.resolveFigure(a, element, 1, false);
        try std.testing.expect(!value.unresolved);
        try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = 100 }), value.min_width);
        try std.testing.expect(value.margins == null and value.padding == null and value.border == null);
    }
    try std.testing.expect((try profile.resolveFigure(a, &absent, 1, false)).min_width == null);
    try std.testing.expect(!(try profile.resolveFigure(a, &absent, 1, false)).unresolved);
    try std.testing.expect((try profile.resolveFigure(a, &unknown, 1, false)).unresolved);
    var tokens = thumb; tokens.typeof_tokens = "other mw:File/Thumb another";
    try std.testing.expectEqual(@as(f32, 100), (try profile.resolveFigure(a, &tokens, 1, false)).min_width.?.value);
    tokens.typeof_tokens = "mw:File/Thumbnail";
    try std.testing.expect((try profile.resolveFigure(a, &tokens, 1, false)).min_width == null);
    var cascade = try parseAlloc(a, "figure{min-width:300px}figure[typeof~='mw:File/Thumb']{min-width:100px}figure{min-width:50px!important}figure{min-width:20px}"); defer cascade.deinit();
    try std.testing.expectEqual(@as(f32, 50), (try cascade.resolveFigure(a, &thumb, 1, false)).min_width.?.value);
    var zero = try parseAlloc(a, "figure[typeof~='mw:File/Thumb']{min-width:100px}figure[typeof~='mw:File/Thumb']{min-width:0}"); defer zero.deinit();
    try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = 0 }), (try zero.resolveFigure(a, &thumb, 1, false)).min_width);
    for ([_]struct { raw: []const u8, value: f32 }{
        .{ .raw = "+0", .value = 0 }, .{ .raw = "-0", .value = 0 },
        .{ .raw = ".0", .value = 0 }, .{ .raw = "0e5", .value = 0 },
        .{ .raw = "1e2px", .value = 100 }, .{ .raw = "1E+2PX", .value = 100 },
    }) |number| {
        const numeric_css = try std.fmt.allocPrint(a, "figure{{min-width:{s}}}", .{number.raw});
        var numeric_profile = try parseAlloc(a, numeric_css); defer numeric_profile.deinit();
        const selected = try numeric_profile.resolveFigure(a, &thumb, 1, false);
        try std.testing.expect(!selected.unresolved);
        try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = number.value }), selected.min_width);
    }
    for ([_][]const u8{
        "figure{min-width:0x1p2px}", "figure{min-width:1_00px}",
        "figure{min-width:-1e-999px}", "figure{min-width:-1px}",
        "figure{min-width:nanpx}", "figure{min-width:infpx}",
        "figure{min-width:1e-999}",
        "figure[typeof~='mw:File/Thumb']:hover{min-width:100px}",
        "figure[typeof~='mw:File/Thumb' i]{min-width:100px}",
        "figure[typeof='mw:File/Thumb']{min-width:100px}",
        "figure[typeof~='mw:Error']{min-width:100px}",
        "figure[typeof~='other']{min-width:100px}",
        "figure[typeof~='mw:File/Thumb'][title]{min-width:100px}",
        "figure{min-width:10em}", "figure{min-width:50%}", "figure{min-width:var(--minimum)}",
        "figure{min-width:100px;box-sizing:border-box}",
    }) |uncertain_css| {
        var uncertain_profile = try parseAlloc(a, uncertain_css); defer uncertain_profile.deinit();
        try std.testing.expect((try uncertain_profile.resolveFigure(a, &thumb, 1, false)).unresolved);
    }
    const child: TextElement = .{ .tag = "figcaption", .typeof_tokens = "", .parent = &thumb };
    var ancestor = try parseAlloc(a, "figure[typeof~='mw:File/Thumb'] figcaption{min-width:100px}"); defer ancestor.deinit();
    try std.testing.expect(!(try ancestor.resolveFigure(a, &child, 1, false)).unresolved);
    var unknown_child = child; unknown_child.parent = &unknown;
    try std.testing.expect((try ancestor.resolveFigure(a, &unknown_child, 1, false)).unresolved);
}

test "selector lists preserve comments quoted and grouped commas without joining compounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var list: SelectorList = .{ .source = " /* lead, */ .printNav .NavFrame, /* .,! boundary */ .printNav .NavContent, a[title=\",/*literal*/\"], :is(.a,.b), .a\\,b" };
    for ([_][]const u8{ ".printNav .NavFrame", ".printNav .NavContent", "a[title=\",/*literal*/\"]", ":is(.a,.b)", ".a\\,b" }) |expected| {
        try std.testing.expectEqualStrings(expected, trim((try list.nextAlloc(a)) orelse return error.TestUnexpectedResult));
    }
    try std.testing.expect(try list.nextAlloc(a) == null);
    for ([_][]const u8{ ".a/**/.b", "a/**/b" }) |source| {
        var compound: SelectorList = .{ .source = source };
        try std.testing.expectEqualStrings(source, (try compound.nextAlloc(a)) orelse return error.TestUnexpectedResult);
        try std.testing.expect(try compound.nextAlloc(a) == null);
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{color:red}}", .{source})); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
    var empty: SelectorList = .{ .source = "a,,b," };
    for ([_][]const u8{ "a", "", "b", "" }) |expected| {
        try std.testing.expectEqualStrings(expected, (try empty.nextAlloc(a)) orelse return error.TestUnexpectedResult);
    }
    try std.testing.expect(try empty.nextAlloc(a) == null);
    for ([_][]const u8{ "a/*unterminated", ":is(.a,.b", "a[title=\"unterminated]" }) |source| {
        var malformed: SelectorList = .{ .source = source };
        try std.testing.expectError(error.InvalidStyleProfile, malformed.nextAlloc(a));
    }
}

test "selector boundary comments preserve conditional and custom cascade projections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const css = "@media print{.printNav .NavFrame, /* .,! nur bis #closedNavBar = .closedNavBar: */ .printNav .NavContent{display:block!important}}";
    var actual = try parseAlloc(a, css); defer actual.deinit();
    var reference = try parseAlloc(a, "@media print{.printNav .NavFrame,.printNav .NavContent{display:block!important}}"); defer reference.deinit();
    try std.testing.expectEqual(@as(usize, 2), actual.figure_rules.len);
    try std.testing.expectEqual(@as(usize, 2), actual.display_rules.len);
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, actual.figureRootDirectionUse(null));
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const figure: TextElement = .{ .tag = "figure", .parent = &root };
    try std.testing.expectEqualDeep(try reference.resolveFigure(a, &figure, 1, false), try actual.resolveFigure(a, &figure, 1, false));
    var matches = actual.displayRules("div", "NavContent", "");
    const matched = matches.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(matched.uncertain);
    try std.testing.expect(matches.next() == null);
    const custom_css = ".left, /* comma, comment */ .right{color:#123456;font-size:90%;--ink:#abcdef}";
    var custom = try parseAlloc(a, custom_css); defer custom.deinit();
    var custom_reference = try parseAlloc(a, ".left,.right{color:#123456;font-size:90%;--ink:#abcdef}"); defer custom_reference.deinit();
    try std.testing.expectEqual(@as(usize, 2), custom.text_rules.len);
    try std.testing.expectEqual(@as(usize, 2), custom.display_rules.len);
    try std.testing.expectEqual(@as(usize, 2), custom.figure_rules.len);
    const right: TextElement = .{ .tag = "div", .classes = "right" };
    try std.testing.expectEqualDeep(try custom_reference.resolveTextPaint(a, &right, ""), try custom.resolveTextPaint(a, &right, ""));
    try attachCustomProperties(&custom, &.{.{ .css = custom_css, .base_url = "" }}, .{
        .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
    });
    const properties = custom.custom_properties orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), properties.rules.len);
    const environment = try properties.element(a, properties.root_environment, .{ .tag = "div", .classes = "right" }, "");
    try CustomPropertyFixture.known(environment, "--ink", "#abcdef");
}


test "empty Figure declaration tails retain custom-only relevance and exact known winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    for ([_][]const u8{ ":root { --ink: red;\n}", ":root{/* only */}", ":root{;; /* tail */ \n}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(@as(usize, 0), profile.figure_rules.len);
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
        try std.testing.expect(profile.contentParentEffectsUnchanged(null, &root));
    }
    const formatted = ":root { --ink: #123456;\n}\nfigure { min-width: 100px; color: #123456; ; /* tail */\n}";
    var actual = try parseAlloc(a, formatted); defer actual.deinit();
    var reference = try parseAlloc(a, ":root{--ink:#123456}figure{min-width:100px;color:#123456}"); defer reference.deinit();
    try std.testing.expectEqual(@as(usize, 1), actual.figure_rules.len);
    const selected = try actual.resolveFigure(a, &frame, 1, false);
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqualDeep(try reference.resolveFigure(a, &frame, 1, false), selected);
    try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = 100 }), selected.min_width);
    try attachCustomProperties(&actual, &.{.{ .css = formatted, .base_url = "" }}, .{
        .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
    });
    try CustomPropertyFixture.known(actual.custom_properties.?.root_environment, "--ink", "#123456");
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, actual.figureRootDirectionUse(null));
    for ([_][]const u8{ "figure{broken}", "figure{color:var(--ink);\n}", ":root{--ink:red;}figure{color:var(--ink);\n}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveFigure(a, &frame, 1, false)).unresolved);
    }
    var malformed = try parseAlloc(a, ":root{--ink:red; broken}"); defer malformed.deinit();
    try std.testing.expectEqual(@as(usize, 1), malformed.figure_rules.len);
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, malformed.figureRootDirectionUse(null));
}

test "universal Figure and text compounds preserve necessary actual ancestor chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    const anchor: TextElement = .{ .tag = "a", .parent = &frame };
    var profile = try parseAlloc(a, ".tneg a{color:#cc2200!important}.Ahom *{font-style:normal}"); defer profile.deinit();
    var empty = try parseAlloc(a, ""); defer empty.deinit();
    try std.testing.expect(profile.contentParentEffectsUnchanged(null, &root));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
    for ([_]*const TextElement{ &frame, &anchor }) |node| {
        try std.testing.expectEqualDeep(try empty.resolveFigure(a, node, 1, false), try profile.resolveFigure(a, node, 1, false));
        try std.testing.expectEqualDeep(try empty.resolveTextPaint(a, node, ""), try profile.resolveTextPaint(a, node, ""));
    }
    const ahom: TextElement = .{ .tag = "div", .classes = "Ahom", .source_key = 1, .parent = &root };
    const owned_frame: TextElement = .{ .tag = "figure", .parent = &ahom };
    const owned_anchor: TextElement = .{ .tag = "a", .parent = &owned_frame };
    try std.testing.expectEqualDeep(@as(?TextFontStyle, .{ .value = false }), (try profile.resolveTextPaint(a, &owned_anchor, "")).font_style);
    var child = try parseAlloc(a, ".Ahom > *{font-style:normal}"); defer child.deinit();
    try std.testing.expectEqualDeep(@as(?TextFontStyle, .{ .value = false }), (try child.resolveTextPaint(a, &owned_frame, "")).font_style);
    try std.testing.expect((try child.resolveTextPaint(a, &owned_anchor, "")).font_style == null);
    const fragment: TextElement = .{ .tag = "figure" };
    const fragment_anchor: TextElement = .{ .tag = "a", .parent = &fragment };
    try std.testing.expect((try profile.resolveFigure(a, &fragment_anchor, 1, false)).unresolved);
    for ([_][]const u8{ "a/**/.x{color:red}", "*|a{color:red}", "a*{color:red}" }) |css| {
        var unknown = try parseAlloc(a, css); defer unknown.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, unknown.figureRootDirectionUse(null));
    }
}

test "complete content root subject proof retains state and functional dependency uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    const anchor: TextElement = .{ .tag = "a", .parent = &frame };
    for ([_][]const u8{
        ".partlynew :link{color:#B88D00}", ".partlynew :visited{color:#826F34}",
        "#p-personal :link.partlynew{color:#B88D00}",
        "textarea#wpTextbox1 + div:last-child{tab-size:4}",
        "html:not([dummyparam]) .horizontal li:after{content:\",\"}",
        "table.prettytable > * > tr > th{color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
        try std.testing.expect(profile.contentParentEffectsUnchanged(null, &root));
        try std.testing.expect(!(try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
    }
    const partly: TextElement = .{ .tag = "div", .classes = "partlynew", .source_key = 1, .parent = &root };
    const owned_frame: TextElement = .{ .tag = "figure", .parent = &partly };
    const owned_anchor: TextElement = .{ .tag = "a", .parent = &owned_frame };
    var state = try parseAlloc(a, ".partlynew :link{color:#B88D00}"); defer state.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, state.figureRootDirectionUse(&partly));
    try std.testing.expect((try state.resolveFigure(a, &owned_anchor, 1, false)).unresolved);
    try std.testing.expect((try state.resolveTextPaint(a, &owned_anchor, "")).color.? == .unknown);
    var sibling = try parseAlloc(a, "textarea#wpTextbox1 + div:last-child{tab-size:4}"); defer sibling.deinit();
    var unknown_root = root; unknown_root.ancestry_complete = false;
    try std.testing.expect(!sibling.contentParentEffectsUnchanged(null, &unknown_root));
    var authored_root = root; authored_root.source_key = 1;
    try std.testing.expect(!sibling.contentParentEffectsUnchanged(null, &authored_root));
    var attached_root = root; attached_root.parent = &partly;
    try std.testing.expect(!sibling.contentParentEffectsUnchanged(null, &attached_root));
    var attribute = try parseAlloc(a, "a:is([href]){color:red}"); defer attribute.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, attribute.figureRootDirectionUse(null));
    try std.testing.expect((try attribute.resolveFigure(a, &anchor, 1, false)).unresolved);
    for ([_][]const u8{
        ".x || div:last-child{color:red}", ".x > > div:last-child{color:red}",
        ".x\\31 div:last-child{color:red}", ".x div:dir(rtl){color:red}",
        "div[dir=rtl] a{color:red}", "a:is(.mw-content-rtl a){color:red}",
        "a:where(:not(.mw-content-rtl a)){color:red}", "a:has([dir=rtl]){color:red}",
        "a:not(:lang(de)){color:red}", "a:unknown(foo){color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
}


test "valid auto margin shorthand remains unresolved beside represented table width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "");
    defer profile.deinit();
    for ([_][]const u8{ "margin:0 auto 0.3em auto", "margin:AUTO", "margin-left:auto" }) |margin| {
        const css = try std.fmt.allocPrint(a, "{s};width:100%;background:#fcfbff", .{margin});
        defer a.free(css);
        const value = try profile.resolveTableWithContext(a, 0, "translations", .{ .ancestor_classes = "", .own_id = "" }, null, css);
        try std.testing.expect(value.unresolved and value.width_specified);
        try std.testing.expectEqualDeep(types.TableStyle{ .background = "#fcfbff", .width = .{ .unit = .percent, .value = 100 } }, value.style.?);
    }
    // Invalid padding and invalid margin tokens do not become accepted edges.
    for ([_][]const u8{ "padding:auto", "padding:AUTO", "padding:0 auto", "padding:auto auto", "margin:0 auto nonsense auto", "margin:0 auto 0 auto 0" }) |invalid| {
        const css = try std.fmt.allocPrint(a, "{s};width:100%;background:#fcfbff", .{invalid});
        defer a.free(css);
        const value = try profile.resolveTableWithContext(a, 0, "translations", .{ .ancestor_classes = "", .own_id = "" }, null, css);
        try std.testing.expect(!value.unresolved and value.width_specified);
        try std.testing.expectEqualDeep(types.TableStyle{ .background = "#fcfbff", .width = .{ .unit = .percent, .value = 100 } }, value.style.?);
    }
    // CSS-wide and substitution values retain their existing winning uncertainty.
    for ([_][]const u8{
        "margin:inherit", "margin:initial", "margin:unset", "margin:revert", "margin:revert-layer", "margin:var(--edge)",
        "padding:inherit", "padding:initial", "padding:unset", "padding:revert", "padding:revert-layer", "padding:var(--edge)",
    }) |unknown| {
        const css = try std.fmt.allocPrint(a, "{s};width:100%;background:#fcfbff", .{unknown});
        defer a.free(css);
        const value = try profile.resolveTableWithContext(a, 0, "translations", .{ .ancestor_classes = "", .own_id = "" }, null, css);
        try std.testing.expect(value.unresolved and value.width_specified);
        try std.testing.expectEqualDeep(types.TableStyle{ .background = "#fcfbff", .width = .{ .unit = .percent, .value = 100 } }, value.style.?);
    }
    const reset = try profile.resolveTableWithContext(a, 0, "translations", .{ .ancestor_classes = "", .own_id = "" }, null, "margin:auto;margin:0;width:100%");
    try std.testing.expect(!reset.unresolved);
    try std.testing.expectEqualDeep(types.StyleEdges.all(.{ .unit = .px, .value = 0 }), reset.style.?.margins.?);
    const numeric = try profile.resolveTableWithContext(a, 0, "translations", .{ .ancestor_classes = "", .own_id = "" }, null, "margin:0 1em;width:100%");
    try std.testing.expect(!numeric.unresolved);
    try std.testing.expectEqualDeep(types.StyleEdges{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .em, .value = 1 }, .bottom = .{ .unit = .px, .value = 0 }, .left = .{ .unit = .em, .value = 1 } }, numeric.style.?.margins.?);
}

test "Figure geometry delegates uncertain font properties without waiving text or box effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    const anchor: TextElement = .{ .tag = "a", .parent = &frame };
    var profile = try parseAlloc(a, "a[rel=\"mw:referencedBy\"]::before{font-weight:bold}"); defer profile.deinit();
    try std.testing.expect(!(try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
    try std.testing.expect((try profile.resolveTextPaint(a, &anchor, "")).weight.? == .unknown);
    var mixed = try parseAlloc(a, "a[rel=\"mw:referencedBy\"]::before{font-weight:bold;background:red}"); defer mixed.deinit();
    try std.testing.expect((try mixed.resolveFigure(a, &anchor, 1, false)).unresolved);
    var size = try parseAlloc(a, "a:hover{font-size:75%}"); defer size.deinit();
    try std.testing.expect((try size.resolveFigure(a, &anchor, 1, false)).unresolved);
    try std.testing.expect((try size.resolveFontSizeIn(a, &anchor, "", null)).? == .unknown);
}

test "Figure primary alignment barriers mask only finite root alignment inheritance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "div.mw-content-ltr{text-align:justify}", "div.mw-content-rtl{text-align:right!important}", ".mw-parser-output{text-align:start}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
        for ([_][]const u8{ "mw-content-ltr mw-parser-output", "mw-content-rtl mw-parser-output" }) |classes| {
            const root: TextElement = .{ .tag = "div", .classes = classes, .ancestry_complete = true };
            try std.testing.expect(profile.contentParentEffectsUnchanged(null, &root));
            const frame: TextElement = .{ .tag = "figure", .parent = &root };
            const caption: TextElement = .{ .tag = "figcaption", .parent = &frame };
            try std.testing.expectEqualDeep(FigureStyle{}, try profile.resolveFigure(a, &frame, 1, false));
            try std.testing.expectEqualDeep(FigureStyle{}, try profile.resolveFigure(a, &caption, 1, false));
        }
    }
    for ([_][]const u8{
        "div.mw-content-ltr{text-align:justify;color:red}",
        "div.mw-content-ltr{text-align:var(--align)}",
        "div.mw-content-ltr{text-align:inherit}",
        "div.mw-content-ltr:hover{text-align:justify}",
        "div.mw-content-ltr a{text-align:justify}",
        "@media screen{div.mw-content-ltr{text-align:justify}}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
}

test "Figure caption class inventory refutes only complete positive language-class subjects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ ".Avst:lang(pal)", ":lang(vi).Hani", ".Syrc:lang(tru)", ":lang(hit).Xsux" }, [_][]const u8{ "Avst", "Hani", "Syrc", "Xsux" }) |selector, class| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{font-family:unrepresented}}", .{selector})); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUseWithCaptionClasses(null, ""));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(null, class));
        const authored: TextElement = .{ .tag = "span", .classes = class };
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(&authored, ""));
        try std.testing.expect((try profile.resolveFigure(a, &authored, 1, false)).unresolved);
    }
    for ([_][]const u8{
        ":lang(vi)", ".mw-selflink:lang(vi)", ".mw-file-element:lang(vi)",
        ".internal:lang(vi)", ".mw-magiclink-isbn:lang(vi)",
        ":is(.Hani):lang(vi)", ":not(.Hani):lang(vi)", ":has(.Hani):lang(vi)",
        ":lang('vi').Hani", ":lang(vi,hit).Hani", ":lang(vi).Hani:hover",
        ".outer :lang(vi).Hani", ".Hani\\:escaped:lang(vi)", ".Hani:lang(vi)extra",
    }) |selector| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{font-family:unrepresented}}", .{selector})); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(null, ""));
    }
}


test "Figure attribute filters retain only positive classes in their own compound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    const anchor: TextElement = .{ .tag = "a", .parent = &frame };
    const external: TextElement = .{ .tag = "a", .classes = "external", .parent = &frame };
    var empty = try parseAlloc(a, ""); defer empty.deinit();
    for ([_][]const u8{ "a[href$=\".pdf\"].external", "a[href*=\".PDF?\" i].external", "a[data-x].external", "a.external[href=\".quoted\"]" }) |subject| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, ".mw-parser-output {s}{{background:url(icon.png);padding-right:18px}}", .{subject})); defer profile.deinit();
        try std.testing.expectEqualDeep(try empty.resolveFigure(a, &anchor, 1, false), try profile.resolveFigure(a, &anchor, 1, false));
        try std.testing.expect((try profile.resolveFigure(a, &external, 1, false)).unresolved);
        try std.testing.expectEqual(@as(usize, 1), profile.figure_rules[0].selector.chain[1].classes.len);
        try std.testing.expectEqualStrings("external", profile.figure_rules[0].selector.chain[1].classes[0]);
    }
    // Quoted strings, negative/function arguments and ancestors do not grant
    // an own positive class. Potentially matching unsupported rules stay strict.
    for ([_][]const u8{
        "a[href=\".external\"]", "a:not(.external)", "a:is(.external,a)",
        "a[href=\"x.external\"]:not(.external)",
        "a[href=\"x\"].external\\suffix", "a[href=\"x\"]/* join */.external",
    }) |subject| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{padding-right:18px}}", .{subject})); defer profile.deinit();
        try std.testing.expect((try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
    }
    const marked_parent: TextElement = .{ .tag = "div", .classes = "external", .parent = &root };
    const ordinary_child: TextElement = .{ .tag = "a", .parent = &marked_parent };
    var ancestor = try parseAlloc(a, ".external a[href$='.pdf']{padding-right:18px}"); defer ancestor.deinit();
    try std.testing.expect((try ancestor.resolveFigure(a, &ordinary_child, 1, false)).unresolved);
}

test "Figure finite caption nodes refute absent subjects without language or root guesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const tags: []const []const u8 = &.{ "b", "i", "span", "a", "strong", "em" };
    for ([_][]const u8{
        "ol ol:lang(vi){list-style-type:lower-vietnamese}",
        ".infobox th:not(.noplainlist) > ul,.infobox td:not(.noplainlist) > ul,.infobox [data-wikidata-property-id] > ul{list-style-type:none;list-style-image:none;margin:0}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(null, ""));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUseWithCaptionDomain(null, "", tags));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionDomain(null, "", &.{ "ol", "ul" }));
    }
    var inherited = try parseAlloc(a, "ol ol:lang(vi){font-size:110%;line-height:1}"); defer inherited.deinit();
    const authored: TextElement = .{ .tag = "ol", .source_key = 7 };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, inherited.figureRootDirectionUseWithCaptionDomain(&authored, "", tags));
    for ([_][]const u8{
        ":lang(chu),:lang(cu),:lang(orv){font-size:110%;line-height:1}",
        "span:lang(vi){font-size:110%}", "a:lang(vi){font-size:110%}",
        "html:lang(vi){font-size:110%}", "body:lang(vi){font-size:110%}",
        ":is(ol,span):lang(vi){font-size:110%}", "div:has(ol):lang(vi){font-size:110%}",
        ".x > > ol:lang(vi){margin:1px}", "ol:lang('vi'){margin:1px}",
        "ol\\suffix:lang(vi){margin:1px}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionDomain(null, "", tags));
    }
    var builder: Builder = .{ .a = a };
    try std.testing.expect(try builder.figureNecessaryCompound("a[href=\"broken].external") == null);
    try std.testing.expect(try builder.figureSubjectTag("[data-x=\"unterminated] ol:lang(vi)") == null);
}


test "page language refutation preserves nearest overrides unknown barriers and actual font effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ":lang(chu),:lang(cu),:lang(orv){font-size:110%;line-height:1}"); defer profile.deinit();
    const root: TextElement = .{ .tag = "div", .language = "ru", .ancestry_complete = true };
    const child: TextElement = .{ .tag = "span", .parent = &root };
    const matching: TextElement = .{ .tag = "span", .language = "cu", .parent = &root };
    const inner: TextElement = .{ .tag = "span", .language = "ru", .parent = &matching };
    const empty: TextElement = .{ .tag = "span", .language = "", .parent = &root };
    try std.testing.expect(languageRefutes("cu", &child, null));
    try std.testing.expect(!languageRefutes("cu", &matching, null));
    try std.testing.expect(languageRefutes("cu", &inner, null));
    try std.testing.expect(!languageRefutes("cu", &empty, null));
    try std.testing.expect(!languageRefutes("cu", null, null));
    try std.testing.expect(!languageValueRefutes("cu", "CU-Cyrl"));
    for ([_][]const u8{ "", "ru--Latn", "ru_XX", "ru  ", "ru1" }) |value| try std.testing.expect(!languageValueRefutes("cu", value));
    for (profile.figure_rules) |rule| {
        try std.testing.expect(!rule.selector.matches(&child));
        try std.testing.expect(!rule.selector.matches(&inner));
        try std.testing.expect(rule.selector.uncertain);
    }
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUseWithLanguage(&child, "", null, "ru", true, null));
    for ([_]?*const TextElement{ &matching, &inner, &empty }) |node|
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithLanguage(node, "", null, "ru", true, null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithLanguage(&child, "", null, "ru", false, null));
    for ([_][]const u8{ ":lang('cu')", ":lang(cu,ru)", ":not(:lang(cu))", "span:lang(cu)", ":lang(cu) span", ":lang(cu--Cyrl)" }) |selector|
        try std.testing.expect(bareLanguageRange(selector) == null);
    const cu_rule = profile.figure_rules[1];
    try std.testing.expect(cu_rule.selector.matches(&matching));
    const fonts = try profile.resolveFontSizeIn(a, &matching, "", null);
    try std.testing.expect(fonts != null and fonts.? == .unknown);
    for ([_][]const u8{ "color:red", "font-family:serif", "font-style:italic", "font-size:110%;color:red", "font-size:var(--scale)", "line-height:inherit" }) |css| {
        const source = try std.fmt.allocPrint(a, ":lang(cu){{{s}}}", .{css});
        var outer = try parseAlloc(a, source); defer outer.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, outer.figureRootDirectionUseWithLanguage(&child, "", null, "ru", true, null));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, outer.figureRootDirectionUseWithLanguage(&child, "", null, "ru", true, &.{ "ru", "ru" }));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, outer.figureRootDirectionUseWithLanguage(&child, "", null, "ru", true, &.{ "cu", "ru" }));
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, outer.figureRootDirectionUseWithLanguage(&child, "", null, "ru", true, &.{ "", "ru" }));
    }
}

test "complete caption class inventory refutes only supported necessary terminal class dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const css = ".mw-content-ltr table.mw-babel-wrapper{float:right;clear:right}.mw-content-rtl table.mw-babel-wrapper{float:left;clear:left}.mw-content-ltr table.mw-babel-box{float:left;clear:left}.mw-content-rtl table.mw-babel-box{float:right;clear:right}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUseWithCaptionClasses(null, ""));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(null, null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(null, "mw-babel-box"));
    const ancestor: TextElement = .{ .tag = "table", .classes = "mw-babel-wrapper" };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionClasses(&ancestor, ""));
    var functional = try parseAlloc(a, ".mw-content-rtl table:is(.mw-babel-box,figure){float:left}"); defer functional.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, functional.figureRootDirectionUseWithCaptionClasses(null, ""));
    var generated = try parseAlloc(a, ".mw-content-rtl figure{margin-top:9px}"); defer generated.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.generated_only, generated.figureRootDirectionUseWithCaptionClasses(null, ""));
}
