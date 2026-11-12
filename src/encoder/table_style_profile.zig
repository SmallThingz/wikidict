const std = @import("std");
const types = @import("blob_encoder").presentation_types;

pub const Scope = u64;
/// Null means unknown; an empty ID proves parsed attribute absence. This context
/// is build-only and never inherited as the identity of another element.
fn positivePageAncestorClass(root: *const TextElement, name: []const u8) bool {
    var cursor: ?*const TextElement = root;
    var remaining: usize = 64;
    while (cursor) |node| : (cursor = node.parent) {
        if (remaining == 0) return false;
        remaining -= 1;
        if (Profile.hasClass(node.classes, name)) return true;
    }
    return false;
}

pub const ElementContext = struct {
    page_style_root: ?*const TextElement = null,
    // Only the ordinary HTML font compiler may certify this projection.
    font_size_consumed: bool = false,
    custom_environment: ?CustomEnvironment = null,
    // Producer has applied this same element/profile text-color cascade.
    text_color_consumed: bool = false,
    computed_border_collapse: ?BorderCollapseState = null,
    // Own HTML presentational hint, lower priority than all author CSS.
    legacy_vertical_align: ?[]const u8 = null,
    // Own preferred cell-width HTML hint, never an intrinsic minimum.
    legacy_cell_width: ?[]const u8 = null,
    ancestor_classes: ?[]const u8 = null,
    own_id: ?[]const u8 = null,
    // Null means unknown ancestry. A nonnull list overapproximates all IDs
    // through an independently proved original content root; build-only.
    complete_font_ancestor_ids: ?[]const []const u8 = null,
    // Complete original ancestor tag inventory; null retains uncertainty.
    complete_font_ancestor_tags: ?[]const []const u8 = null,
};
pub const TableResolution = struct { style: ?types.TableStyle, scope: Scope, unresolved: bool, margin_basis_unresolved: bool = false, background_specified: bool = false, descendant_style_unresolved: bool = false, width_specified: bool = false, line_height_em: ?f32 = null };
pub const CellResolution = struct { style: ?types.CellStyle, background: ?[]const u8, background_specified: bool, unresolved: bool, padding_basis_unresolved: bool = false, alignment_specified: bool = false };
const max_css_bytes = 1024 * 1024;
const max_rules = 4096;
const Target = enum { element, table, cell, th, td, other };
const Property = enum { background, border, collapse, margins, margin_top, margin_right, margin_bottom, margin_left, padding, text_align, float_side, width, min_width, clear, box_sizing, layout_reset, display, vertical_align, line_height, list_style, font_size, text_color, other };
const Value = union(enum) {
    color: []const u8,
    no_background,
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
    display_value: types.TableDisplay,
    vertical_align_value: types.InlineBoxVerticalAlign,
    cell_vertical_align_value: types.CellVerticalAlign,
    line_height_em: f32,
    list_style_none,
    font_size_consumed,
    unsupported,
};
const Declaration = struct { border_update: ?BorderUpdate = null, border_raw: ?struct { name: []const u8, value: []const u8 } = null, property: Property, value: Value, important: bool, order: u32, affects_font_basis: bool = false, may_name_min_width: bool = false, custom_paint: ?[]const u8 = null };
const Selector = struct {
    target: Target,
    mask: Scope,
    ancestor_mask: Scope = 0,
    ancestor_class: ?[]const u8 = null,
    own_classes: []const []const u8 = &.{},
    own_ids: []const []const u8 = &.{},
    own_tag: ?[]const u8 = null,
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
    borders: BorderCascade = .{},
    slots: [@typeInfo(Property).@"enum".field_names.len]?Winner = @splat(null),
    selector_unresolved: bool = false,
    font_basis_unresolved: bool = false,
    fn add(self: *Winners, declaration: Declaration, specificity: u64, conditional: bool, inline_style: bool) void {
        if (declaration.may_name_min_width) {
            // An escaped property name may be min-width. Keep its original
            // unsupported slot too; no other property gains escape support.
            var possible = declaration;
            possible.property = .min_width;
            possible.value = .unsupported;
            possible.may_name_min_width = false;
            self.add(possible, specificity, conditional, inline_style);
        }
        if (declaration.affects_font_basis) self.font_basis_unresolved = true;
        const index = @backingInt(declaration.property);
        const next: Priority = .{ .important = declaration.important, .specificity = specificity, .order = declaration.order, .inline_style = inline_style };
        if (declaration.border_update) |update| {
            self.borders.add(update, next, conditional);
            return;
        }
        if (self.slots[index]) |prior| if (!next.wins(prior.priority)) return;
        self.slots[index] = .{ .value = if (conditional) .unsupported else declaration.value, .priority = next };
    }
    fn value(self: Winners, property: Property) ?Value {
        if (property == .border) {
            const border = self.borders.result();
            if (border.unresolved) return .unsupported;
            if (border.value) |known| return if (styleBorderFromContainer(known)) |style| .{ .border = style } else .unsupported;
        }
        var selected = self.slots[@backingInt(property)];
        if (property == .float_side or property == .text_align or property == .width or property == .min_width or property == .clear or property == .padding or property == .box_sizing or property == .display or property == .vertical_align or property == .line_height or property == .list_style or property == .font_size) if (self.slots[@backingInt(Property.layout_reset)]) |reset| {
            if (selected == null or reset.priority.wins(selected.?.priority)) selected = reset;
        };
        return if (selected) |winner| winner.value else null;
    }
    fn unresolved(self: Winners) bool { return self.unresolvedWithFont(false); }
    fn unresolvedWithFont(self: Winners, font_size_consumed: bool) bool {
        if (self.selector_unresolved) return true;
        if (self.value(.border)) |border| if (border == .unsupported) return true;
        for (self.slots, 0..) |slot, index| {
            const property: Property = @enumFromInt(index);
            if (property == .margins or marginEdge(property) != null) continue;
            if (slot) |winner| {
                if (winner.value == .unsupported) return true;
                if (property == .font_size and !font_size_consumed) return true;
            }
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

// Build-only computed inheritance. Null is unobserved, not a guessed initial
// value. Readers receive the existing concrete TableStyle.collapse enum only.
pub const BorderCollapseState = enum { separate, collapse, unknown };
const BorderCollapseCascade = struct {
    value: ?BorderCollapseState = null,
    priority: Priority = .{},
    seen: bool = false,
    parent: ?BorderCollapseState,

    fn declarations(self: *@This(), a: std.mem.Allocator, css: []const u8, specificity: u64, order: u32, uncertain: bool, inline_style: bool) !void {
        var pos: usize = 0;
        var next_order = order;
        while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
            defer a.free(raw);
            next_order += 1;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
            const name = trim(raw[0..colon]);
            const escaped = std.mem.indexOfScalar(u8, name, '\\') != null;
            const reset = std.ascii.eqlIgnoreCase(name, "all");
            if (!escaped and !reset and !std.ascii.eqlIgnoreCase(name, "border-collapse")) continue;
            const parsed = customPriority(raw[colon + 1 ..]);
            const value = trim(parsed.value);
            if (value.len == 0) continue;
            const selected: BorderCollapseState = if (escaped or parsed.unknown) .unknown
                else if (std.ascii.eqlIgnoreCase(value, "initial")) .separate
                else if (std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset")) self.parent orelse .unknown
                else if (!reset and std.ascii.eqlIgnoreCase(value, "collapse")) .collapse
                else if (!reset and std.ascii.eqlIgnoreCase(value, "separate")) .separate
                else if (dynamicValue(value)) .unknown
                else continue;
            const priority: Priority = .{ .important = parsed.important, .specificity = specificity,
                .order = next_order, .inline_style = inline_style };
            if (self.seen and !priority.wins(self.priority)) continue;
            self.seen = true;
            self.priority = priority;
            self.value = if (uncertain) .unknown else selected;
        }
    }
    fn result(self: @This()) ?BorderCollapseState { return if (self.seen) self.value else self.parent; }
};

pub fn hasBorderCollapseDeclarationsAlloc(a: std.mem.Allocator, css: []const u8) std.mem.Allocator.Error!bool {
    if (css.len > max_css_bytes) return false;
    var pos: usize = 0;
    while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
        defer a.free(raw);
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = trim(raw[0..colon]);
        if (std.ascii.eqlIgnoreCase(name, "border-collapse") or std.ascii.eqlIgnoreCase(name, "all") or std.mem.indexOfScalar(u8, name, '\\') != null) return true;
    }
    return false;
}
pub fn resolveInlineBorderCollapseAlloc(a: std.mem.Allocator, css: []const u8, parent: ?BorderCollapseState) std.mem.Allocator.Error!?BorderCollapseState {
    if (css.len > max_css_bytes) return .unknown;
    var cascade_value: BorderCollapseCascade = .{ .parent = parent };
    try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
    return cascade_value.result();
}

fn computedTableCollapse(winners: *Winners, value: ?BorderCollapseState) void {
    const selected = value orelse return;
    // The ordinary producer already cascaded this exact table and its parent
    // chain. Keep every other winner/refusal; replace only this computed slot.
    winners.slots[@intFromEnum(Property.collapse)] = .{ .priority = .{}, .value = switch (selected) {
        .separate => .{ .collapse = .separate }, .collapse => .{ .collapse = .collapse }, .unknown => .unsupported,
    } };
}

pub const AlignmentResolution = struct { value: ?types.CellTextAlign = null, specified: bool = false, unresolved: bool = false };
const AlignmentCascade = struct {
    resolution: AlignmentResolution = .{},
    priority: Priority = .{},
    inline_style: bool = false,
    fn consider(self: *AlignmentCascade, declaration: Declaration, specificity: u64, conditional: bool, inline_style: bool) void {
        const next: Priority = .{ .important = declaration.important, .specificity = specificity, .order = declaration.order };
        if (self.resolution.specified) {
            if (next.important == self.priority.important and inline_style != self.inline_style) {
                if (!inline_style) return;
            } else if (!next.wins(self.priority)) return;
        }
        const known = !conditional and declaration.value == .align_value;
        self.* = .{ .resolution = .{ .value = if (known) declaration.value.align_value else null, .specified = true, .unresolved = !known }, .priority = next, .inline_style = inline_style };
    }
    fn declarations(self: *AlignmentCascade, a: std.mem.Allocator, css: []const u8, specificity: u64, order: u32, conditional: bool, inline_style: bool) !void {
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
    return resolveInlineTableWithCollapseAlloc(a, css, null);
}
pub fn resolveInlineTableWithCollapseAlloc(a: std.mem.Allocator, css: []const u8, collapse: ?BorderCollapseState) !TableResolution {
    if (css.len > max_css_bytes) return .{ .style = null, .scope = 0, .unresolved = true, .margin_basis_unresolved = true };
    const profile = emptyProfile(a);
    var winners = try profile.cascade(a, .table, 0, 0, "", .{ .ancestor_classes = "", .own_id = "" }, null, null, css);
    computedTableCollapse(&winners, collapse);
    const margins = resolvedMargins(winners);
    var style: types.TableStyle = .{ .margins = margins.value };
    var unresolved = margins.unresolved;
    if (winners.value(.float_side)) |value| {
        if (value == .float_value) style.float_side = value.float_value;
        unresolved = unresolved or value == .unsupported;
    }
    projectTableBox(&style, winners);
    inline for (.{ Property.width, .min_width, .padding, .clear, .box_sizing, .collapse, .display, .vertical_align, .line_height, .list_style }) |property| if (winners.value(property)) |value| {
        unresolved = unresolved or value == .unsupported;
    };
    const flow_conflict = tableFlowFloatConflict(&style);
    return .{ .style = if (types.validTableStyle(style)) style else null, .scope = 0, .unresolved = unresolved or flow_conflict, .margin_basis_unresolved = winners.font_basis_unresolved, .width_specified = winners.value(.width) != null or unresolvedTableWidthBox(winners), .line_height_em = selectedLineHeight(winners) };
}
fn addCellWidthHint(winners: *Winners, raw: ?[]const u8) void {
    const value = raw orelse return;
    // Strict finite HTML integer/percentage hints. Other spellings remain
    // unsupported, never interpreted as CSS or as an attractive minimum.
    var parsed: Value = .unsupported;
    if (value.len != 0 and value.len <= 64) {
        const percent = value[value.len - 1] == '%';
        const digits = if (percent) value[0 .. value.len - 1] else value;
        var valid = digits.len != 0;
        for (digits) |byte| valid = valid and std.ascii.isDigit(byte);
        if (valid) {
            const number: ?f32 = std.fmt.parseFloat(f32, digits) catch null;
            if (number) |scalar| {
                // HTML cell dimension hints ignore zero. This does not apply
                // to a real CSS width:0 winner, which remains present data.
                if (scalar == 0) return;
                const width: types.StyleWidth = .{ .unit = if (percent) .percent else .px, .value = scalar };
                if (types.validStyleWidth(width)) parsed = .{ .width_value = width };
            }
        }
    }
    winners.add(.{ .property = .width, .value = parsed, .important = false, .order = 0 }, 0, false, false);
}
fn selectedCellWidth(winners: Winners) ?types.StyleWidth {
    if (winners.value(.box_sizing) != null) return null;
    const value = winners.value(.width) orelse return null;
    return if (value == .width_value) value.width_value else null;
}
fn cellWidthUnresolved(winners: Winners) bool {
    const value = winners.value(.width) orelse return false;
    return switch (value) { .auto_width => false, .width_value => winners.value(.box_sizing) != null, else => true };
}

fn addCellVerticalHint(winners: *Winners, raw: ?[]const u8) void {
    const value = raw orelse return;
    const alignment: Value = if (std.ascii.eqlIgnoreCase(value, "top"))
        .{ .cell_vertical_align_value = .top } else .unsupported;
    winners.add(.{ .property = .vertical_align, .value = alignment, .important = false, .order = 0 }, 0, false, false);
}

pub fn resolveInlineCellAlloc(a: std.mem.Allocator, legacy_align: ?[]const u8, css: []const u8) !CellResolution {
    return resolveInlineCellWithVerticalHintAlloc(a, legacy_align, null, css);
}
pub fn resolveInlineCellWithVerticalHintAlloc(a: std.mem.Allocator, legacy_align: ?[]const u8, legacy_vertical_align: ?[]const u8, css: []const u8) !CellResolution {
    return resolveInlineCellWithLegacyHintsAlloc(a, legacy_align, legacy_vertical_align, null, css);
}
pub fn resolveInlineCellWithLegacyHintsAlloc(a: std.mem.Allocator, legacy_align: ?[]const u8, legacy_vertical_align: ?[]const u8, legacy_width: ?[]const u8, css: []const u8) !CellResolution {
    const profile = emptyProfile(a);
    const alignment = try profile.resolveAlignment(a, "", "", "", legacy_align, css);
    if (css.len > max_css_bytes) return .{ .style = null, .background = null, .background_specified = false, .unresolved = true, .alignment_specified = alignment.specified };
    // This path historically owns alignment only, not table/cell paint. Select
    // the new minimum and its reset/box dependencies without projecting paint.
    var winners: Winners = .{};
    addCellVerticalHint(&winners, legacy_vertical_align);
    addCellWidthHint(&winners, legacy_width);
    var pos: usize = 0;
    var order: u32 = 0;
    while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
        defer a.free(raw);
        order += 1;
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = trim(raw[0..colon]);
        const property = propertyFor(name) orelse continue;
        const escaped = std.mem.indexOfScalar(u8, name, '\\') != null;
        if (property != .width and property != .min_width and property != .box_sizing and property != .layout_reset and property != .vertical_align and !escaped) continue;
        if (try declarationAlloc(a, raw, order)) |declaration| winners.add(declaration, 0, !representedDeclaration(.cell, declaration), true);
    }
    const minimum = winners.value(.min_width);
    const minimum_unknown = if (minimum) |value| value != .length_value or winners.value(.box_sizing) != null else false;
    var style: types.CellStyle = .{ .text_align = alignment.value, .min_width = selectedCellMinimumWidth(winners), .width = selectedCellWidth(winners) };
    if (winners.value(.vertical_align)) |value| if (value == .cell_vertical_align_value) { style.vertical_align = value.cell_vertical_align_value; };
    const vertical_unknown = if (winners.value(.vertical_align)) |value| value != .cell_vertical_align_value else false;
    return .{ .style = if (types.validCellStyle(style)) style else null, .background = null, .background_specified = false, .unresolved = alignment.unresolved or minimum_unknown or vertical_unknown or cellWidthUnresolved(winners), .alignment_specified = alignment.specified };
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

// Build-only identity and lifetime of a source-bound class inventory.
pub const SourceRootTableProof = struct { opening_start: usize, opening_end: usize, anchor_start: usize, anchor_end: usize, cell_ordinal: usize };
// A closed ordinary opening plus its literal bold-label operation has the
// same complete candidate census in the observed DOM. This issues no mapping,
// physical parent, ordinal, or sibling fact.
pub const SourceCustomElementProof = struct { range: SourceRootChildProof, candidate_count: u32 };

pub const BoundedTextClassScope = struct {
    source_root_tables: []const SourceRootTableProof = &.{},
    source_root_tables_source: ?[]const u8 = null,
    // Separate positive capability issued only after exact complete-page selection.
    // It proves a distant parser-root ancestor, never an edge or sibling position.
    page_styles: ?*const Profile = null,
    page_style_root: ?*const TextElement = null,
    // Independent complete path, consumed only by a source-issued root child.
    page_style_complete_root: ?*const TextElement = null,
    // Computed agreement over every observed parser-subtree element under
    // both authenticated shell states. This certifies no node identity or edge.
    page_custom_invariant: ?CustomEnvironment = null,
    source_custom_elements: []const SourceCustomElementProof = &.{},
    source_custom_elements_source: ?[]const u8 = null,
    source_root_children: []const SourceRootChildProof = &.{},
    source_root_parent_groups: []const SourceRootParentProof = &.{},
    source_root_children_source: ?[]const u8 = null,
    source_siblings: []const SourceSiblingProof = &.{},
    source_siblings_source: ?[]const u8 = null,
    root_tag: []const u8,
    root_classes: []const u8,
    subtree_classes: []const u8,
    complete_ancestor_class_superset: ?[]const u8 = null,
};

// Visibility is resolved only during production; no CSS enters a reader record.
// Its own-class namespace is separate from the table ancestor paint namespace.
// Producer-only text paint. Keep real element ancestry separate from inherited
// span classes: a descendant selector must never match a flattened class union.
pub const SourceSiblingElement = struct { tag: []const u8, classes: []const u8 = "", id: []const u8 = "" };
pub const SourceSiblingProof = struct {
    anchor_start: usize = 0, anchor_end: usize = 0,
    name_start: usize, name_len: usize, attrs_start: usize, attrs_len: usize,
    // Nonzero identity of the actual parent in the complete observed tree.
    parent_key: usize,
    previous: ?SourceSiblingElement,
};
pub const SourceRootChildProof = struct {
    anchor_start: usize, anchor_end: usize,
    name_start: usize, name_len: usize, attrs_start: usize, attrs_len: usize,
};
// Common parent facts for repeated closed anchors. No observed node identity,
// ordinal, sibling relation, or per-occurrence correspondence is issued.
pub const SourceRootParentProof = struct {
    anchor: SourceRootChildProof,
    candidate_count: u16,
};
pub const TextElement = struct {
    // Independently retained actual ancestry alternative, never a class union.
    // The alternative node has no alternative itself. Page queries preserve
    // unknown whenever the two actual states differ in selector applicability.
    alternative_ancestry: ?*const TextElement = null,
    source_root_child: ?*const SourceRootChildProof = null,
    // Null is an unobserved declaration domain; empty is an observed absence.
    observed_inline_style: ?[]const u8 = null,
    // Computed at this actual node, before descendant redefinitions. Each
    // retained API/GET path owns its own environment; null lends no variables.
    observed_custom_environment: ?CustomEnvironment = null,
    // Exact selected parser root, separate from logical parent links and class
    // supersets. Source loss clears this capability; it cannot certify adjacency.
    page_style_root: ?*const TextElement = null,
    page_style_source: ?[]const u8 = null,
    page_style_anchor: ?[]const u8 = null,
    source_sibling: ?*const SourceSiblingProof = null,
    source_sibling_scope: ?*const BoundedTextClassScope = null,
    source_sibling_source: ?[]const u8 = null,
    tag: []const u8,
    // Optional complete observed inventory for this element only. No ancestor
    // or generated-tag defaults can establish attribute absence.
    attribute_presence: ?AttributePresenceSource = null,
    // Null is an unobserved attribute domain. Empty proves typeof is absent.
    // Figure matching admits only proved Thumb/Frame format membership,
    // not an exclusive inventory of other generated RDFa tokens.
    typeof_tokens: ?[]const u8 = null,
    // Null inherits; an explicit empty or unsupported language is a barrier.
    language: ?[]const u8 = null,
    classes: []const u8 = "",
    id: []const u8 = "",
    parent: ?*const TextElement = null,
    // Explicit complete observed physical path: every parent edge is actual
    // adjacency through the document root. A logical compiler parent chain or
    // complete class inventory does not establish this build-only certificate.
    physical_ancestry_complete: bool = false,
    source_key: usize = 0,
    // Complete class-token union of all actual ancestors, including generated
    // wrappers and the selected outer domain. Null leaves that domain unknown.
    // Refusal-only: this cannot establish selector order, adjacency or matching.
    complete_ancestor_classes: ?[]const u8 = null,
    // Provenance is cache identity only; it grants no matching knowledge.
    ancestor_class_scope: ?*const BoundedTextClassScope = null,
    ancestor_class_source: ?[]const u8 = null,
    // Authoritative one-based original element-sibling position; null is unknown.
    element_index: ?u32 = null,
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
    caption_class_guard_requires_complete: bool = false,
    // Necessary terminal type from a separately bounded complete chain.
    caption_subject_tag: ?[]const u8 = null,
    chain: []const TextCompound,
    specificity: u64,
    uncertain: bool,
    required_own_attribute: ?[]const u8 = null,
    necessary_ancestor_classes: []const []const u8 = &.{},
    direct_children: bool = false,
    fn matchIn(self: TextSelector, element: *const TextElement, page_scoped: bool) ContainerSelectorMatch {
        if (page_scoped) if (element.alternative_ancestry) |alternative| {
            if (alternative.alternative_ancestry != null) return .unknown;
            var primary = element.*; primary.alternative_ancestry = null;
            const left = self.matchIn(&primary, true);
            const right = self.matchIn(alternative, true);
            return if (left == right) left else .unknown;
        };
        if (!page_scoped) return if (self.matches(element)) .known else .no;
        if (element.complete_ancestor_classes) |classes| {
            for (self.necessary_ancestor_classes) |required| if (!Profile.hasClass(classes, required)) return .no;
        }
        if (self.language_range) |range| if (languageRefutes(range, element, null)) return .no;
        if (self.required_own_attribute) |name| if (element.attribute_presence) |attributes| {
            if (attributes.get(attributes.ctx, name) == .absent) return .no;
        };
        if (self.chain.len == 0) return .unknown;
        if (!self.chain[self.chain.len - 1].matches(element)) return .no;
        const root = element.page_style_root orelse return .unknown;
        if (self.language_range != null or self.root_predicate_unresolved or self.required_own_attribute != null) return .unknown;
        // Logical compiler parents do not certify the physical child combinator.
        if (self.direct_children and !element.physical_ancestry_complete) return .unknown;
        var cursor = element.parent;
        var entered_root = false;
        var index = self.chain.len - 1;
        while (index != 0) {
            index -= 1;
            if (self.direct_children) {
                const parent = cursor orelse return if (element.physical_ancestry_complete) .no else .unknown;
                if (!self.chain[index].matches(parent)) return .no;
                cursor = parent.parent;
            } else {
                while (true) {
                    if (cursor == null and !entered_root and !element.physical_ancestry_complete) { cursor = root; entered_root = true; }
                    const parent = cursor orelse return if (element.physical_ancestry_complete) .no else .unknown;
                    cursor = parent.parent;
                    if (self.chain[index].matches(parent)) break;
                }
            }
        }
        return if (self.uncertain) .unknown else .known;
    }
    fn matches(self: TextSelector, element: *const TextElement) bool {
        if (element.complete_ancestor_classes) |classes| {
            for (self.necessary_ancestor_classes) |required| {
                if (!Profile.hasClass(classes, required)) return false;
            }
        }
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

// New functional-predicate refutations require the independent complete union.
// Also retain every represented parent/alternative: an unknown/cyclic or larger
// graph withholds the shortcut instead of trusting an inconsistent inventory.
fn figureFunctionalClassPossible(authored: ?*const TextElement, caption_classes: []const u8, complete_classes: []const u8, required: []const u8) bool {
    if (Profile.hasClass(complete_classes, required) or figureCaptionClassPresent(null, caption_classes, required)) return true;
    var pending: [128]*const TextElement = undefined;
    var seen: [128]*const TextElement = undefined;
    var count: usize = 0; var visited: usize = 0;
    if (authored) |node| { pending[0] = node; count = 1; }
    while (count != 0) {
        count -= 1; const node = pending[count];
        for (seen[0..visited]) |prior| if (prior == node) return true;
        if (visited == seen.len) return true;
        seen[visited] = node; visited += 1;
        if (Profile.hasClass(node.classes, required)) return true;
        for ([_]?*const TextElement{ node.parent, node.alternative_ancestry }) |maybe| if (maybe) |next| {
            if (count == pending.len) return true;
            pending[count] = next; count += 1;
        };
    }
    return false;
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
pub const ContainerViewportCondition = union(enum) {
    all,
    screen_max_width_px: u32,
    unknown,
};
pub const ContainerSelectorMatch = enum { no, known, unknown };
pub const ContainerRuleProvenance = struct {
    selector: []const u8,
    conditions: []const []const u8 = &.{},
    source_index: usize,
    css_byte_start: usize,
};
pub const ContainerRuleMatch = struct {
    provenance: ?ContainerRuleProvenance = null,
    css: []const u8,
    order: u32,
    specificity: u64,
    match: ContainerSelectorMatch,
    viewport: ContainerViewportCondition,
    rank_unknown: bool = false,
};
pub const MissingLinkPaintBlocker = struct {
    pub const Reason = enum { global_unresolved, malformed_declaration, unknown_priority, declaration };
    reason: Reason,
    rule: ?ContainerRuleMatch = null,
    // Borrowed Profile-owned source text, never the temporary decoded token.
    declaration: []const u8 = "",
    declaration_offset: usize = 0,
};
// A selected distant ancestor has no emitted reader box. Ordinary effects on
// that node need separate inherited/containing-box semantics; its identity alone
// must never make an otherwise unstyled child appear faithfully compiled.
pub const PageAncestorEffectBlocker = struct {
    pub const Reason = enum { missing_root, global_unresolved, depth_limit, declaration, unproved_ancestor_path };
    reason: Reason,
    ancestor_depth: usize = 0,
    rule: ?ContainerRuleMatch = null,
    declaration: []const u8 = "",
    declaration_offset: usize = 0,
};
pub const ContainerRuleMatches = struct {
    rules: []const ContainerRuleMatch = &.{},
    unresolved: bool = false,
};
const ContainerCompound = struct {
    compound: TextCompound,
    element_index: ?u32 = null,
    direct_parent: bool = false,
};
const ContainerSelector = struct {
    chain: []const ContainerCompound = &.{},
    fallback: ?TextSelector = null,
    necessary_chain: []const ContainerCompound = &.{},
    // Only two exact compounds separated by one +. Legacy matching keeps its
    // original uncertain fallback; selected pages can use an issued sibling.
    adjacent_sibling: ?struct { previous: TextCompound, subject: TextCompound, specificity: u64 } = null,
    specificity: u64,
    uncertain: bool = false,

    fn combine(left: ContainerSelectorMatch, right: ContainerSelectorMatch) ContainerSelectorMatch {
        if (left == .no or right == .no) return .no;
        return if (left == .unknown or right == .unknown) .unknown else .known;
    }

    fn matchAt(self: @This(), index: usize, element: *const TextElement, complete: bool, budget: *usize, page_root: ?*const TextElement) ContainerSelectorMatch {
        if (budget.* == 0) return .unknown;
        budget.* -= 1;
        const required = self.chain[index];
        if (!required.compound.matches(element)) return .no;
        var own: ContainerSelectorMatch = .known;
        if (required.element_index) |ordinal| {
            if (element.element_index) |actual| {
                if (actual == 0) own = .unknown else if (actual != ordinal) return .no;
            } else own = .unknown;
        }
        if (index == 0) return own;
        var closed = complete or element.ancestry_complete;
        if (required.direct_parent) {
            const parent = element.parent orelse return combine(own, if (closed) .no else .unknown);
            return combine(own, self.matchAt(index - 1, parent, closed, budget, page_root));
        }
        var parent = element.parent;
        var possible = false;
        while (parent) |ancestor| {
            const matched = self.matchAt(index - 1, ancestor, closed, budget, page_root);
            if (matched == .known) return own;
            possible = possible or matched == .unknown;
            closed = closed or ancestor.ancestry_complete;
            if (budget.* == 0) return combine(own, .unknown);
            parent = ancestor.parent;
        }
        // A selected root and its independently observed outer nodes are only
        // positive distant ancestors. Missing matches cannot close the chain.
        if (page_root) |root| {
            var outer: ?*const TextElement = root;
            while (outer) |ancestor| : (outer = ancestor.parent) {
                const matched = self.matchAt(index - 1, ancestor, false, budget, null);
                if (matched == .known) return own;
                if (budget.* == 0) break;
            }
            return combine(own, .unknown);
        }
        return combine(own, if (possible or !closed) .unknown else .no);
    }

    fn matchIn(self: @This(), element: *const TextElement, page_scoped: bool) ContainerSelectorMatch {
        if (page_scoped) if (element.alternative_ancestry) |alternative| {
            if (alternative.alternative_ancestry != null) return .unknown;
            var primary = element.*; primary.alternative_ancestry = null;
            const left = self.matchIn(&primary, true);
            const right = self.matchIn(alternative, true);
            return if (left == right) left else .unknown;
        };
        // A separate source-issued element relation remains the only positive
        // sibling authority; the parser-root proof does not add adjacency.
        if (self.adjacent_sibling != null) return self.match(element);
        if (!page_scoped) return self.match(element);
        if (self.fallback) |fallback| {
            if (self.necessary_chain.len != 0 and !self.necessary_chain[self.necessary_chain.len - 1].compound.matches(element)) return .no;
            return switch (fallback.matchIn(element, true)) { .no => .no, else => .unknown };
        }
        if (self.chain.len == 0) return .unknown;
        if (!self.chain[self.chain.len - 1].compound.matches(element)) return .no;
        const root = element.page_style_root orelse return .unknown;
        if (element.complete_ancestor_classes) |classes| {
            for (self.chain[0 .. self.chain.len - 1]) |part| for (part.compound.classes) |required| {
                if (!Profile.hasClass(classes, required)) return .no;
            };
        }
        for (self.chain) |part| if (part.direct_parent and !element.physical_ancestry_complete) return .unknown;
        var budget: usize = 4096;
        var descendant_root: ?*const TextElement = if (element.physical_ancestry_complete) null else root;
        for (self.chain) |part| if (part.direct_parent) { descendant_root = null; break; };
        const actual = self.matchAt(self.chain.len - 1, element, element.physical_ancestry_complete, &budget, descendant_root);
        if (actual == .known) return if (self.uncertain) .unknown else .known;
        // Only the independent complete physical path can close this domain.
        if (element.physical_ancestry_complete and actual == .no) return .no;
        // Incomplete parents cannot refute a potentially present intermediate.
        return .unknown;
    }
    fn match(self: @This(), element: *const TextElement) ContainerSelectorMatch {
        if (self.adjacent_sibling) |adjacent| if (element.source_sibling_scope) |scope| {
            if (!adjacent.subject.matches(element)) return .no;
            const source = element.source_sibling_source orelse return .unknown;
            const issued = scope.source_siblings_source orelse return .unknown;
            if (source.ptr != issued.ptr or source.len != issued.len) return .unknown;
            const proof = element.source_sibling orelse return .unknown;
            if (proof.parent_key == 0) return .unknown;
            const previous = proof.previous orelse return .no;
            const node: TextElement = .{ .tag = previous.tag, .classes = previous.classes, .id = previous.id };
            return if (adjacent.previous.matches(&node)) .known else .no;
        };
        if (self.fallback) |fallback| {
            if (self.necessary_chain.len != 0) {
                if (!self.necessary_chain[self.necessary_chain.len - 1].compound.matches(element)) return .no;
                if (element.physical_ancestry_complete) {
                    const necessary: ContainerSelector = .{ .chain = self.necessary_chain, .specificity = 0 };
                    var budget: usize = 4096;
                    if (necessary.matchAt(necessary.chain.len - 1, element, false, &budget, null) == .no) return .no;
                }
            }
            if (fallback.required_own_attribute) |name| if (element.attribute_presence) |attributes| {
                if (attributes.get(attributes.ctx, name) == .absent) return .no;
            };
            return if (fallback.matches(element) or figureOuterSelectorUnknown(fallback, element)) .unknown else .no;
        }
        if (self.chain.len == 0) return .unknown;
        // A selected observed element relation can refute a required ancestor
        // class absent from the complete page/outer superset. This certifies
        // no parent edge, ordinal, inherited value, or matching selector.
        if (element.source_sibling_scope) |scope| {
            if (element.source_sibling_source) |source| if (scope.source_siblings_source) |issued| {
                if (source.ptr == issued.ptr and source.len == issued.len) if (element.source_sibling) |proof| {
                    var member = false;
                    for (scope.source_siblings) |*known| member = member or known == proof;
                    if (member and proof.parent_key != 0) if (scope.complete_ancestor_class_superset) |classes| {
                        for (self.chain[0 .. self.chain.len - 1]) |ancestor| {
                            for (ancestor.compound.classes) |required| {
                                if (Profile.hasClass(classes, required)) continue;
                                // Query projections may retain the source relation while
                                // installing represented generated parents. Their classes
                                // must also be absent; an unbounded/cyclic path cannot refute.
                                var parent = element.parent;
                                var remaining: usize = 4096;
                                var present_or_unknown = false;
                                while (parent) |node| {
                                    if (remaining == 0) { present_or_unknown = true; break; }
                                    remaining -= 1;
                                    if (Profile.hasClass(node.classes, required)) { present_or_unknown = true; break; }
                                    parent = node.parent;
                                }
                                if (!present_or_unknown) return .no;
                            }
                        }
                    };
                };
            };
        }
        var budget: usize = 4096;
        const result = self.matchAt(self.chain.len - 1, element, false, &budget, null);
        return if (result == .known and self.uncertain) .unknown else result;
    }
};
const ContainerRule = struct {
    provenance: ?ContainerRuleProvenance = null,
    selector: ContainerSelector,
    css: []const u8,
    order: u32,
    viewport: ContainerViewportCondition,
    rank_unknown: bool = false,
};

fn containerViewportGroup(prelude: []const u8, parent: ContainerViewportCondition) ContainerViewportCondition {
    if (parent == .unknown or !atRuleNamed(prelude, "media")) return .unknown;
    var text = trim(prelude[identifierEnd(prelude, 1)..]);
    if (text.len < 6 or !std.ascii.eqlIgnoreCase(text[0..6], "screen")) return .unknown;
    text = text[6..];
    if (text.len == 0 or !std.ascii.isWhitespace(text[0])) return .unknown;
    text = trim(text);
    if (text.len < 3 or !std.ascii.eqlIgnoreCase(text[0..3], "and")) return .unknown;
    if (text.len == 3 or !std.ascii.isWhitespace(text[3])) return .unknown;
    text = trim(text[3..]);
    if (text.len < 3 or text[0] != '(' or text[text.len - 1] != ')') return .unknown;
    text = trim(text[1 .. text.len - 1]);
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .unknown;
    if (!std.ascii.eqlIgnoreCase(trim(text[0..colon]), "max-width")) return .unknown;
    const value = trim(text[colon + 1 ..]);
    if (value.len < 3 or !std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) return .unknown;
    const digits = value[0 .. value.len - 2];
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return .unknown;
    const limit = std.fmt.parseInt(u32, digits, 10) catch return .unknown;
    if (limit == 0) return .unknown;
    return .{ .screen_max_width_px = if (parent == .screen_max_width_px) @min(limit, parent.screen_max_width_px) else limit };
}

pub const ContainerResolution = struct {
    positioning_specified: bool = false,
    style: types.ContainerStyle = .{},
    specified: bool = false,
    unresolved: bool = false,
};

const BorderLineStyle = enum { none, hidden, solid, dotted };
const BorderAtom = union(enum) { unknown, length: types.StyleLength, line_style: BorderLineStyle, color: types.ContainerColor };
const BorderUpdate = struct { atoms: [12]?BorderAtom = @splat(null), unsafe: bool = false };
const BorderCandidate = struct { atom: BorderAtom, priority: Priority };
const BorderResolution = struct { value: ?types.ContainerBorder = null, unresolved: bool = false };
const BorderCascade = struct {
    atoms: [12]?BorderCandidate = @splat(null),
    unsafe: bool = false,
    seen: bool = false,
    fn add(self: *@This(), update: BorderUpdate, priority: Priority, uncertain: bool) void {
        self.unsafe = self.unsafe or update.unsafe;
        for (update.atoms, 0..) |maybe, index| if (maybe) |atom| {
            self.seen = true;
            if (self.atoms[index]) |current| if (!priority.wins(current.priority)) continue;
            self.atoms[index] = .{ .atom = if (uncertain) .unknown else atom, .priority = priority };
        };
    }
    fn result(self: *const @This()) BorderResolution {
        if (self.unsafe) return .{ .unresolved = true };
        if (!self.seen) return .{};
        var sides: [4]types.ContainerBorderEdge = undefined;
        for (&sides, 0..) |*side, index| {
            const start = index * 3;
            const line = if (self.atoms[start + 1]) |candidate| candidate.atom else BorderAtom{ .line_style = .none };
            if (line != .line_style) return .{ .unresolved = true };
            if (line.line_style == .none) { side.* = .none; continue; }
            if (line.line_style == .hidden) { side.* = .hidden; continue; }
            const width = if (self.atoms[start]) |candidate| candidate.atom else BorderAtom.unknown;
            const color = if (self.atoms[start + 2]) |candidate| candidate.atom else BorderAtom.unknown;
            if (width != .length or color != .color) return .{ .unresolved = true };
            side.* = switch (line.line_style) {
                .solid => .{ .solid = .{ .width = width.length, .color = color.color } },
                .dotted => .{ .dotted = .{ .width = width.length, .color = color.color } },
                .none, .hidden => unreachable,
            };
        }
        var uniform = true;
        for (sides[1..]) |side| uniform = uniform and containerBorderEdgeEqual(sides[0], side);
        if (uniform) switch (sides[0]) {
            .none => return .{ .value = .none },
            .solid => |solid| return .{ .value = .{ .solid = .{ .width = solid.width, .color = solid.color } } },
            .hidden, .dotted => {},
        };
        return .{ .value = .{ .edges = .{ .top = sides[0], .right = sides[1], .bottom = sides[2], .left = sides[3] } } };
    }
};
fn containerBorderEdgeEqual(left: types.ContainerBorderEdge, right: types.ContainerBorderEdge) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .none, .hidden => true,
        .solid => |line| std.meta.eql(line.width, right.solid.width) and containerColorEqual(line.color, right.solid.color),
        .dotted => |line| std.meta.eql(line.width, right.dotted.width) and containerColorEqual(line.color, right.dotted.color),
    };
}
fn containerBorderEdgesEqual(left: types.ContainerBorderEdges, right: types.ContainerBorderEdges) bool {
    inline for (.{ "top", "right", "bottom", "left" }) |side|
        if (!containerBorderEdgeEqual(@field(left, side), @field(right, side))) return false;
    return true;
}
fn containerEdgeFromStyle(edge: types.StyleBorderEdge) types.ContainerBorderEdge {
    return switch (edge) {
        .none => .none, .hidden => .hidden,
        .solid => |line| .{ .solid = .{ .width = line.width, .color = .{ .rgb = line.color } } },
        .dotted => |line| .{ .dotted = .{ .width = line.width, .color = .{ .rgb = line.color } } },
    };
}
fn styleEdgeFromContainer(edge: types.ContainerBorderEdge) ?types.StyleBorderEdge {
    return switch (edge) {
        .none => .none, .hidden => .hidden,
        .solid => |line| if (line.color == .rgb) .{ .solid = .{ .width = line.width, .color = line.color.rgb } } else null,
        .dotted => |line| if (line.color == .rgb) .{ .dotted = .{ .width = line.width, .color = line.color.rgb } } else null,
    };
}
fn styleBorderFromContainer(border: types.ContainerBorder) ?types.StyleBorder {
    return switch (border) {
        .none => .none,
        .solid => |line| if (line.color == .rgb) .{ .solid = .{ .width = line.width, .color = line.color.rgb } } else null,
        .edges => |sides| .{ .edges = .{ .top = styleEdgeFromContainer(sides.top) orelse return null,
            .right = styleEdgeFromContainer(sides.right) orelse return null,
            .bottom = styleEdgeFromContainer(sides.bottom) orelse return null,
            .left = styleEdgeFromContainer(sides.left) orelse return null } },
    };
}
// Token boundaries use the existing declaration's balanced CSS value. Preserve
// a whole color/var function as one atom; no evaluation or selector work here.
fn borderTokens(value: []const u8, out: *[4][]const u8) ?usize {
    var at: usize = 0; var count: usize = 0;
    while (at < value.len) {
        while (at < value.len and std.ascii.isWhitespace(value[at])) : (at += 1) {}
        if (at == value.len) break;
        if (count == out.len) return null;
        const start = at; var depth: usize = 0; var quote: u8 = 0;
        while (at < value.len) : (at += 1) {
            const byte = value[at];
            if (byte == '\\') return null;
            if (quote != 0) { if (byte == quote) quote = 0; continue; }
            if (byte == '\'' or byte == '"') { quote = byte; continue; }
            if (byte == '(') { depth += 1; if (depth > 32) return null; }
            if (byte == ')') {
                if (depth == 0) return null;
                depth -= 1;
                // A CSS function token ends here even in var(...)1px.
                if (depth == 0) { at += 1; break; }
            }
            // A hash starts its own CSS token even after an ident/dimension.
            // Keep the complete hash name: #ff0000solid is not a hex color.
            if (depth == 0 and byte == '#' and at != start) break;
            if (depth == 0 and std.ascii.isWhitespace(byte)) break;
        }
        if (depth != 0 or quote != 0) return null;
        out[count] = value[start..at]; count += 1;
    }
    return if (count == 0) null else count;
}
fn borderStyleAtom(value: []const u8) ?BorderAtom {
    inline for (.{ "none", "hidden", "solid", "dotted" }, .{ BorderLineStyle.none, .hidden, .solid, .dotted }) |name, line|
        if (std.ascii.eqlIgnoreCase(value, name)) return .{ .line_style = line };
    inline for (.{ "dashed", "double", "groove", "ridge", "inset", "outset" }) |name|
        if (std.ascii.eqlIgnoreCase(value, name)) return .unknown;
    return null;
}
fn borderWidthAtom(value: []const u8) ?BorderAtom {
    if (styleWidth(value)) |width| return if (width.unit == .percent) BorderAtom.unknown else .{ .length = .{
        .unit = if (width.unit == .px) .px else .em, .value = width.value,
    } };
    inline for (.{ "thin", "medium", "thick" }) |name| if (std.ascii.eqlIgnoreCase(value, name)) return .unknown;
    if (unsupportedWidth(value)) return .unknown;
    return null;
}
fn borderUnknownUpdate(side: ?usize, component: ?usize) BorderUpdate {
    var result: BorderUpdate = .{};
    for (0..4) |index| {
        if (side != null and side.? != index) continue;
        for (0..3) |part| if (component == null or component.? == part) { result.atoms[index * 3 + part] = .unknown; };
    }
    return result;
}
fn borderUpdateAlloc(a: std.mem.Allocator, property: []const u8, raw: []const u8, environment: ?CustomEnvironment) std.mem.Allocator.Error!BorderUpdate {
    const value = trim(raw);
    var side: ?usize = null; var component: ?usize = null; var recognized = std.ascii.eqlIgnoreCase(property, "border");
    inline for (.{ "width", "style", "color" }, 0..) |part, index|
        if (std.ascii.eqlIgnoreCase(property, "border-" ++ part)) { component = index; recognized = true; };
    inline for (.{ "top", "right", "bottom", "left" }, 0..) |edge, index| {
        if (std.ascii.eqlIgnoreCase(property, "border-" ++ edge)) { side = index; recognized = true; }
        inline for (.{ "width", "style", "color" }, 0..) |part, atom_index|
            if (std.ascii.eqlIgnoreCase(property, "border-" ++ edge ++ "-" ++ part)) { side = index; component = atom_index; recognized = true; };
    }
    if (!recognized) return .{ .unsafe = true };
    const reset = std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset");
    if (std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer")) return borderUnknownUpdate(side, component);
    var tokens: [4][]const u8 = undefined;
    const count = borderTokens(value, &tokens) orelse return borderUnknownUpdate(side, component);
    var result: BorderUpdate = .{};
    if (component) |part| {
        if (side != null and count != 1) return borderUnknownUpdate(side, component);
        var atoms: [4]BorderAtom = undefined;
        for (tokens[0..count], 0..) |token, index| atoms[index] = switch (part) {
            0 => if (reset) .unknown else borderWidthAtom(token) orelse .unknown,
            1 => if (reset) .{ .line_style = .none } else borderStyleAtom(token) orelse .unknown,
            2 => if (reset) .unknown else if (try containerColorWithCustomAlloc(a, token, environment, false)) |color| .{ .color = color } else .unknown,
            else => unreachable,
        };
        const positions: [4]usize = switch (count) { 1 => .{0,0,0,0}, 2 => .{0,1,0,1}, 3 => .{0,1,2,1}, 4 => .{0,1,2,3}, else => unreachable };
        for (positions, 0..) |at, edge| if (side == null or side.? == edge) { result.atoms[edge * 3 + part] = atoms[if (side != null) 0 else at]; };
        return result;
    }
    var width: ?BorderAtom = null; var line: ?BorderAtom = null; var color: ?BorderAtom = null;
    if (!reset) for (tokens[0..count]) |token| {
        if (borderStyleAtom(token)) |known| { if (line != null) return borderUnknownUpdate(side, null); line = known; }
        else if (try containerColorWithCustomAlloc(a, token, environment, false)) |known| { if (color != null) return borderUnknownUpdate(side, null); color = .{ .color = known }; }
        else if (std.mem.indexOfAny(u8, token, "(%") != null) return borderUnknownUpdate(side, null)
        else if (borderWidthAtom(token)) |known| { if (width != null) return borderUnknownUpdate(side, null); width = known; }
        else return borderUnknownUpdate(side, null);
    };
    for (0..4) |edge| if (side == null or side.? == edge) {
        result.atoms[edge * 3] = width orelse .unknown;
        result.atoms[edge * 3 + 1] = line orelse .{ .line_style = .none };
        result.atoms[edge * 3 + 2] = color orelse .unknown;
    };
    return result;
}

const ContainerSlot = enum {
    margin_top, margin_right, margin_bottom, margin_left,
    padding_top, padding_right, padding_bottom, padding_left,
    width, float_side, clear, max_width, box_sizing, layout, align_items,
    flex_item, background, border, line_height, text_align, height, min_height, column_count, column_gap, positioning,
};
const ContainerValue = union(enum) {
    unknown,
    margin_auto,
    edge: types.StyleLength,
    width: types.ContainerWidth,
    float_side: ?types.TableFloatSide,
    clear: types.FigureClear,
    max_width: types.ContainerMaxWidth,
    box_sizing: types.ContainerBoxSizing,
    layout: types.ContainerLayout,
    align_items: types.ContainerAlignItems,
    flex_item: types.ContainerFlexItem,
    background: types.ContainerColor,
    border: types.ContainerBorder,
    line_height: types.ContainerLineHeight,
    text_align: types.CellTextAlign,
    height: ?types.StyleLength,
    min_height: types.StyleLength,
    column_count: ?u16,
    column_gap: types.StyleLength,
    positioning: ?types.ContainerPositioning,
};
const ContainerCandidate = struct { value: ContainerValue, priority: Priority };
const ContainerContextSlot = enum { position, overflow_x, overflow_y, flex_direction, flex_wrap, background_image, background_other, column_width, column_fill, inset_top, inset_right, inset_bottom, inset_left, inset_all, z_index };
const ContainerContextCandidate = struct { ordinary: bool, priority: Priority, overflow: ?types.ContainerOverflow = null };
const ColumnAliasPolicy = enum { standard, webkit, moz, all };
const ContainerCascade = struct {
    borders: BorderCascade = .{},
    column_alias_policy: ColumnAliasPolicy = .standard,
    custom_environment: ?CustomEnvironment = null,
    border_collapse_consumed: bool = false,
    slots: [@typeInfo(ContainerSlot).@"enum".field_names.len]?ContainerCandidate = @splat(null),
    contexts: [@typeInfo(ContainerContextSlot).@"enum".field_names.len]?ContainerContextCandidate = @splat(null),
    unsafe: bool = false,
    specified: bool = false,
    responsive: bool = false,
    fragmentation_policy_present: bool = false,

    fn consider(self: *@This(), slot: ContainerSlot, value: ContainerValue, priority: Priority, uncertain: bool) void {
        const index = @intFromEnum(slot);
        if (self.slots[index]) |current| if (!priority.wins(current.priority)) return;
        const supported_conditional = switch (slot) { .width, .max_width, .box_sizing, .line_height => true, else => false };
        self.slots[index] = .{ .value = if (uncertain or (self.responsive and !supported_conditional)) .unknown else value, .priority = priority };
        self.specified = true;
    }

    fn considerContext(self: *@This(), slot: ContainerContextSlot, ordinary: bool, priority: Priority, uncertain: bool) void {
        const index = @intFromEnum(slot);
        if (self.contexts[index]) |current| if (!priority.wins(current.priority)) return;
        self.contexts[index] = .{ .ordinary = ordinary and !uncertain and !self.responsive, .priority = priority };
    }

    fn considerOverflow(self: *@This(), slot: ContainerContextSlot, value: ?types.ContainerOverflow, priority: Priority, uncertain: bool) void {
        const index = @intFromEnum(slot);
        if (self.contexts[index]) |current| if (!priority.wins(current.priority)) return;
        self.contexts[index] = .{ .ordinary = value != null and !uncertain and !self.responsive, .priority = priority, .overflow = value };
        self.specified = true;
    }

    fn declarations(self: *@This(), a: std.mem.Allocator, css: []const u8, specificity: u64, order: u32, uncertain: bool, inline_style: bool) !void {
        var pos: usize = 0;
        var next_order = order;
        while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
            defer a.free(raw);
            next_order += 1;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
            const authored_name = trim(raw[0..colon]);
            const family = columnAliasFamily(authored_name);
            if (family != .standard and self.column_alias_policy != .all and self.column_alias_policy != family) continue;
            const name = columnCanonicalProperty(authored_name);
            const parsed = customPriority(raw[colon + 1 ..]);
            const value = trim(parsed.value);
            const priority: Priority = .{ .important = parsed.important, .specificity = specificity, .order = next_order, .inline_style = inline_style };
            if (columnFragmentationProperty(name)) self.fragmentation_policy_present = true;
            const uncertain_value = uncertain or parsed.unknown;
            if (std.ascii.eqlIgnoreCase(name, "all") or std.mem.indexOfScalar(u8, name, '\\') != null) {
                // Resetting represented winners cannot discharge effects on the
                // properties that this finite container contract does not own.
                self.unsafe = true;
                inline for (@typeInfo(ContainerSlot).@"enum".field_names) |field|
                    self.consider(@field(ContainerSlot, field), .unknown, priority, true);
                continue;
            }
            if (self.border_collapse_consumed and std.ascii.eqlIgnoreCase(name, "border-collapse")) continue;
            const margin = std.ascii.eqlIgnoreCase(name, "margin");
            const padding = std.ascii.eqlIgnoreCase(name, "padding");
            if (margin or padding) {
                if (margin) {
                    const quartet = containerMarginValues(value);
                    const values: [4]?types.ContainerMargin = if (quartet) |q| .{ q.top, q.right, q.bottom, q.left } else @splat(null);
                    for (values, 0..) |edge, index| self.consider(@enumFromInt(index), if (edge) |known| switch (known) {
                        .auto => .margin_auto, .length => |v| .{ .edge = v },
                    } else .unknown, priority, uncertain_value);
                    continue;
                }
                const quartet = edges(value);
                const first: usize = if (margin) 0 else 4;
                const values: [4]?types.StyleLength = if (quartet) |q| .{ q.top, q.right, q.bottom, q.left } else @splat(null);
                for (values, 0..) |edge, index| self.consider(@enumFromInt(first + index), if (edge) |known| .{ .edge = known } else .unknown, priority, uncertain_value);
                continue;
            }
            var edge_slot: ?ContainerSlot = null;
            inline for (.{ "margin-top", "margin-right", "margin-bottom", "margin-left", "padding-top", "padding-right", "padding-bottom", "padding-left" }, 0..) |property, index| {
                if (std.ascii.eqlIgnoreCase(name, property)) edge_slot = @enumFromInt(index);
            }
            if (edge_slot) |slot| {
                if (@intFromEnum(slot) < 4 and std.ascii.eqlIgnoreCase(value, "auto")) {
                    self.consider(slot, .margin_auto, priority, uncertain_value); continue;
                }
                const edge = if (@intFromEnum(slot) < 4) containerMarginLength(value) else length(value);
                self.consider(slot, if (edge) |known| .{ .edge = known } else .unknown, priority, uncertain_value);
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "width")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "auto")) .{ .width = .auto }
                    else if (std.ascii.eqlIgnoreCase(value, "fit-content")) .{ .width = .fit_content }
                    else if (styleWidth(value)) |known| .{ .width = .{ .length = known } } else .unknown;
                self.consider(.width, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "column-count")) {
                var selected: ContainerValue = .unknown;
                if (std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) {
                    selected = .{ .column_count = null };
                } else if (containerColumnInteger(value)) {
                    // A negative/zero integer is invalid CSS; a positive count
                    // outside the finite wire domain remains unsupported.
                    if (value[0] == '-') continue;
                    const count = std.fmt.parseInt(u64, value, 10) catch std.math.maxInt(u64);
                    if (count == 0) continue;
                    if (count <= std.math.maxInt(u16)) selected = .{ .column_count = @intCast(count) };
                } else if (widthNumberSyntax(value) or styleWidth(value) != null) continue;
                self.consider(.column_count, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "column-gap")) {
                const known: ?types.StyleLength = if (std.ascii.eqlIgnoreCase(value, "normal") or
                    std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) .{ .unit = .em, .value = 1 }
                    else if (styleWidth(value)) |length_value| if (length_value.unit == .percent) null else .{
                        .unit = if (length_value.unit == .px) .px else .em, .value = length_value.value,
                    } else null;
                if (known == null and containerHeightInvalidLiteral(value)) continue;
                self.consider(.column_gap, if (known) |length_value| .{ .column_gap = length_value } else .unknown, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "column-width")) {
                // Percentages are not in column-width's grammar. Ignore the
                // authored invalid declaration without replacing an earlier
                // valid winner; never invent percentage column sizing.
                if (styleWidth(value)) |length_value| {
                    if (length_value.unit == .percent) continue;
                } else if (containerHeightInvalidLiteral(value)) continue;
                self.considerContext(.column_width, std.ascii.eqlIgnoreCase(value, "auto") or
                    std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset"), priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "column-fill")) {
                self.considerContext(.column_fill, std.ascii.eqlIgnoreCase(value, "balance") or
                    std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset"), priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "position")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "relative")) .{ .positioning = .relative_auto }
                    else if (std.ascii.eqlIgnoreCase(value, "static") or std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) .{ .positioning = null }
                    else .unknown;
                self.consider(.positioning, selected, priority, uncertain_value); continue;
            }
            var inset_property = false;
            if (std.ascii.eqlIgnoreCase(name, "inset")) {
                inline for (.{ ContainerContextSlot.inset_top, .inset_right, .inset_bottom, .inset_left }) |slot|
                    self.considerContext(slot, relativeAutoInsets(value), priority, uncertain_value);
                continue;
            }
            inline for (.{ "top", "right", "bottom", "left", "z-index" },
                .{ ContainerContextSlot.inset_top, .inset_right, .inset_bottom, .inset_left, .z_index }) |property, slot| {
                if (std.ascii.eqlIgnoreCase(name, property)) {
                    self.considerContext(slot, std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset"), priority, uncertain_value);
                    inset_property = true;
                }
            }
            if (inset_property) continue;
            if (std.ascii.eqlIgnoreCase(name, "height")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "auto") or
                    std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) .{ .height = null }
                    else if (styleWidth(value)) |known| if (known.unit == .percent) .unknown else .{ .height = .{
                        .unit = if (known.unit == .px) .px else .em, .value = known.value,
                    } }
                    else if (unsupportedWidth(value) or std.mem.indexOfScalar(u8, value, '\\') != null) .unknown
                    else if (containerHeightInvalidLiteral(value)) continue else .unknown;
                // Height is not inherited. Auto is a real winner even though
                // its computed representation has no fixed used extent.
                self.consider(.height, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "min-height")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "initial") or
                    std.ascii.eqlIgnoreCase(value, "unset")) .{ .min_height = .{ .unit = .px, .value = 0 } }
                    else if (styleWidth(value)) |known| if (known.unit == .percent) .unknown else .{ .min_height = .{
                        .unit = if (known.unit == .px) .px else .em, .value = known.value,
                    } }
                    else if (unsupportedWidth(value) or std.mem.indexOfScalar(u8, value, '\\') != null) .unknown
                    else if (containerHeightInvalidLiteral(value)) continue else .unknown;
                self.consider(.min_height, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "max-width")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "none")) .{ .max_width = .none }
                    else if (styleWidth(value)) |known| .{ .max_width = .{ .length = known } } else .unknown;
                self.consider(.max_width, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "box-sizing")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "content-box")) .{ .box_sizing = .content_box }
                    else if (std.ascii.eqlIgnoreCase(value, "border-box")) .{ .box_sizing = .border_box } else .unknown;
                self.consider(.box_sizing, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "float")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "none")) .{ .float_side = null }
                    else if (std.ascii.eqlIgnoreCase(value, "left")) .{ .float_side = .left }
                    else if (std.ascii.eqlIgnoreCase(value, "right")) .{ .float_side = .right } else .unknown;
                self.consider(.float_side, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "clear")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "none")) .{ .clear = .none }
                    else if (std.ascii.eqlIgnoreCase(value, "left")) .{ .clear = .left }
                    else if (std.ascii.eqlIgnoreCase(value, "right")) .{ .clear = .right }
                    else if (std.ascii.eqlIgnoreCase(value, "both")) .{ .clear = .both } else .unknown;
                self.consider(.clear, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "display")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "block")) .{ .layout = .flow }
                    else if (std.ascii.eqlIgnoreCase(value, "flex")) .{ .layout = .flex_row } else .unknown;
                self.consider(.layout, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "align-items")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(value, "stretch")) .{ .align_items = .stretch }
                    else if (std.ascii.eqlIgnoreCase(value, "flex-start") or std.ascii.eqlIgnoreCase(value, "start")) .{ .align_items = .start }
                    else if (std.ascii.eqlIgnoreCase(value, "flex-end") or std.ascii.eqlIgnoreCase(value, "end")) .{ .align_items = .end }
                    else if (std.ascii.eqlIgnoreCase(value, "center")) .{ .align_items = .center } else .unknown;
                self.consider(.align_items, selected, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "flex") or std.ascii.eqlIgnoreCase(name, "flex-grow") or
                std.ascii.eqlIgnoreCase(name, "flex-shrink") or std.ascii.eqlIgnoreCase(name, "flex-basis")) {
                const selected: ContainerValue = if (std.ascii.eqlIgnoreCase(name, "flex") and std.ascii.eqlIgnoreCase(value, "none")) .{ .flex_item = .none } else .unknown;
                self.consider(.flex_item, selected, priority, uncertain_value); continue;
            }
            const background = std.ascii.eqlIgnoreCase(name, "background");
            if (background or std.ascii.eqlIgnoreCase(name, "background-color")) {
                const color = try containerColorWithCustomAlloc(a, value, self.custom_environment, background);
                self.consider(.background, if (color) |known| .{ .background = known } else .unknown, priority, uncertain_value);
                // A color longhand cannot erase a prior image/layer winner.
                if (background) {
                    self.considerContext(.background_image, color != null, priority, uncertain_value);
                    self.considerContext(.background_other, color != null, priority, uncertain_value);
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "background-image")) {
                self.considerContext(.background_image, std.ascii.eqlIgnoreCase(value, "none"), priority, uncertain_value); continue;
            }
            if (std.ascii.startsWithIgnoreCase(name, "background-")) {
                self.unsafe = true; continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "border") or std.ascii.startsWithIgnoreCase(name, "border-")) {
                self.borders.add(try borderUpdateAlloc(a, name, value, self.custom_environment), priority, uncertain_value or self.responsive);
                self.specified = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "line-height") or std.ascii.eqlIgnoreCase(name, "font")) {
                const known = if (std.ascii.eqlIgnoreCase(name, "line-height")) containerLineHeight(value) else null;
                self.consider(.line_height, if (known) |height| .{ .line_height = height } else .unknown, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "text-align")) {
                self.consider(.text_align, if (presentationalTextAlign(value)) |known| .{ .text_align = known } else .unknown, priority, uncertain_value); continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "overflow")) {
                const overflow: ?types.ContainerOverflow = if (std.ascii.eqlIgnoreCase(value, "auto")) .auto
                    else if (std.ascii.eqlIgnoreCase(value, "visible")) .visible else null;
                self.considerOverflow(.overflow_x, overflow, priority, uncertain_value);
                self.considerOverflow(.overflow_y, overflow, priority, uncertain_value); continue;
            }
            var context_property = false;
            inline for (.{ "position", "overflow-x", "overflow-y", "flex-direction", "flex-wrap" },
                .{ "static", "visible", "visible", "row", "nowrap" }, 0..) |property, ordinary_value, index| {
                if (std.ascii.eqlIgnoreCase(name, property)) {
                    self.considerContext(@enumFromInt(index), std.ascii.eqlIgnoreCase(value, ordinary_value), priority, uncertain_value);
                    context_property = true;
                }
            }
            if (context_property) continue;
            if (std.ascii.startsWithIgnoreCase(name, "margin-") or std.ascii.startsWithIgnoreCase(name, "padding-") or
                std.ascii.startsWithIgnoreCase(name, "overflow") or std.ascii.startsWithIgnoreCase(name, "column") or
                std.ascii.startsWithIgnoreCase(name, "grid") or std.ascii.startsWithIgnoreCase(name, "flex")) self.unsafe = true;
            inline for (.{ "min-width", "min-height", "max-height", "box-shadow", "transform", "visibility", "opacity", "contain", "writing-mode", "text-indent", "white-space", "top", "right", "bottom", "left", "inset", "zoom", "clip", "filter", "order", "gap", "row-gap", "column-gap", "justify-content", "align-content", "align-self", "justify-self", "isolation", "mix-blend-mode", "content" }) |property| {
                if (std.ascii.eqlIgnoreCase(name, property)) self.unsafe = true;
            }
        }
    }

    fn result(self: *const @This()) ContainerResolution {
        var resolution: ContainerResolution = .{ .specified = self.specified, .unresolved = self.unsafe, .positioning_specified = self.slots[@intFromEnum(ContainerSlot.positioning)] != null };
        if (self.unsafe) return resolution;
        const borders = self.borders.result();
        if (borders.unresolved) { resolution.unresolved = true; return resolution; }
        resolution.style.border = borders.value;
        for (self.contexts) |candidate| if (candidate) |selected| if (!selected.ordinary) {
            resolution.unresolved = true; return resolution;
        };
        for (self.slots) |candidate| if (candidate) |selected| if (selected.value == .unknown) {
            resolution.unresolved = true; return resolution;
        };
        inline for (0..2) |group| {
            var values: [4]types.StyleLength = @splat(.{ .unit = .px, .value = 0 });
            var seen = false;
            var autos: [4]bool = @splat(false);
            for (self.slots[group * 4 ..][0..4], 0..) |candidate, index| if (candidate) |selected| {
                seen = true;
                if (group == 0 and selected.value == .margin_auto) autos[index] = true else values[index] = selected.value.edge;
            };
            if (seen) {
                const selected: types.StyleEdges = .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] };
                if (group == 0 and (autos[0] or autos[1] or autos[2] or autos[3])) {
                    resolution.style.margin_values = .{
                        .top = if (autos[0]) .auto else .{ .length = values[0] },
                        .right = if (autos[1]) .auto else .{ .length = values[1] },
                        .bottom = if (autos[2]) .auto else .{ .length = values[2] },
                        .left = if (autos[3]) .auto else .{ .length = values[3] },
                    };
                } else if (group == 0) resolution.style.margins = selected else resolution.style.padding = selected;
            }
        }
        inline for (.{ "width", "float_side", "clear", "max_width", "box_sizing", "layout", "align_items", "flex_item", "background", "border", "line_height", "text_align", "height", "min_height", "positioning" }) |field| {
            if (self.slots[@intFromEnum(@field(ContainerSlot, field))]) |selected| @field(resolution.style, field) = @field(selected.value, field);
        }
        if (self.slots[@intFromEnum(ContainerSlot.column_count)]) |candidate| if (candidate.value.column_count) |count| {
            const gap = if (self.slots[@intFromEnum(ContainerSlot.column_gap)]) |selected| selected.value.column_gap else types.StyleLength{ .unit = .em, .value = 1 };
            resolution.style.columns = .{ .count = count, .gap = gap };
            if (self.fragmentation_policy_present or !types.validContainerStyle(resolution.style)) resolution.unresolved = true;
        };
        const x = if (self.contexts[@intFromEnum(ContainerContextSlot.overflow_x)]) |candidate| candidate.overflow orelse .visible else .visible;
        const y = if (self.contexts[@intFromEnum(ContainerContextSlot.overflow_y)]) |candidate| candidate.overflow orelse .visible else .visible;
        // No axis-specific scroll semantics are inferred by this first domain.
        // A valid mixed-axis declaration remains unresolved, not silently lost.
        if (x != y) resolution.unresolved = true;
        if (x == .auto and y == .auto) {
            resolution.style.overflow = .auto;
            if (!types.containerAutoScrollportStyleSupported(resolution.style)) resolution.unresolved = true;
        }
        // The current minimum-height contract does not define column balance
        // or flex cross-size interaction on the same owner.
        if (resolution.style.min_height != null and (resolution.style.columns != null or
            resolution.style.layout == .flex_row)) resolution.unresolved = true;
        return resolution;
    }
};

// Legacy engine aliases in retained source use the same compiled semantic
// cascade slots. Do not drop a later valid prefixed winner or unsupported width.
fn columnAliasFamily(name: []const u8) ColumnAliasPolicy {
    if (std.ascii.startsWithIgnoreCase(name, "-webkit-column-")) return .webkit;
    if (std.ascii.startsWithIgnoreCase(name, "-moz-column-")) return .moz;
    return .standard;
}
fn hasColumnAlias(css: []const u8) bool {
    for (css, 0..) |byte, index| if (byte == '-') {
        if (std.ascii.startsWithIgnoreCase(css[index..], "-webkit-column-") or
            std.ascii.startsWithIgnoreCase(css[index..], "-moz-column-")) return true;
    };
    return false;
}
fn columnCanonicalProperty(name: []const u8) []const u8 {
    var value = name;
    if (std.ascii.startsWithIgnoreCase(value, "-webkit-column-")) value = value[8..]
    else if (std.ascii.startsWithIgnoreCase(value, "-moz-column-")) value = value[5..];
    inline for (.{ "before", "after", "inside" }) |side| {
        if (std.ascii.eqlIgnoreCase(value, "column-break-" ++ side)) return "break-" ++ side;
    }
    return value;
}
fn columnFragmentationProperty(name: []const u8) bool {
    const canonical = columnCanonicalProperty(name);
    if (std.mem.indexOfScalar(u8, canonical, '\\') != null or std.ascii.eqlIgnoreCase(canonical, "all")) return true;
    inline for (.{ "break-before", "break-after", "break-inside", "page-break-before", "page-break-after", "page-break-inside", "widows", "orphans", "column-span", "column-rule", "column-rule-color", "column-rule-style", "column-rule-width", "column-fill" }) |property|
        if (std.ascii.eqlIgnoreCase(canonical, property)) return true;
    return false;
}
/// Refusal-only source preflight. Even a reset/default declaration is outside
/// the first fragmentation policy, so no winner evaluation can invent support.
pub fn hasColumnDescendantDeclarationsAlloc(a: std.mem.Allocator, css: []const u8) std.mem.Allocator.Error!bool {
    if (css.len > max_css_bytes) return true;
    var pos: usize = 0;
    while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
        defer a.free(raw);
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = columnCanonicalProperty(trim(raw[0..colon]));
        if (std.ascii.startsWithIgnoreCase(name, "column") or columnFragmentationProperty(name)) return true;
    }
    return false;
}
pub fn hasColumnFragmentationDeclarationsAlloc(a: std.mem.Allocator, css: []const u8) std.mem.Allocator.Error!bool {
    if (css.len > max_css_bytes) return true;
    var pos: usize = 0;
    while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
        defer a.free(raw);
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        if (columnFragmentationProperty(trim(raw[0..colon]))) return true;
    }
    return false;
}

fn containerColumnInteger(value: []const u8) bool {
    if (value.len == 0) return false;
    const first: usize = if (value[0] == '+' or value[0] == '-') 1 else 0;
    if (first == value.len) return false;
    for (value[first..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn containerColorAlloc(a: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?types.ContainerColor {
    const value = trim(raw);
    if (std.ascii.eqlIgnoreCase(value, "transparent")) return .transparent;
    if (try canonicalColorAlloc(a, value)) |rgb| return .{ .rgb = rgb };
    // The model can carry an independently authenticated pair, but this query
    // has no effective color-scheme or custom-property authority.
    return null;
}
fn containerBorderAlloc(a: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?types.ContainerBorder {
    const value = trim(raw);
    if (try borderAlloc(a, value)) |border| return switch (border) {
        .none => @as(types.ContainerBorder, .none),
        .solid => |solid| .{ .solid = .{ .width = solid.width, .color = .{ .rgb = solid.color } } },
        .edges => |sides| .{ .edges = .{ .top = containerEdgeFromStyle(sides.top), .right = containerEdgeFromStyle(sides.right),
            .bottom = containerEdgeFromStyle(sides.bottom), .left = containerEdgeFromStyle(sides.left) } },
    };
    // The complete three-part shorthand also permits explicit transparent
    // paint. Its two scalar prefixes retain exact width/style roles.
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
    const first = tokens.next() orelse return null;
    const second = tokens.next() orelse return null;
    var width: ?types.StyleLength = null;
    if (std.ascii.eqlIgnoreCase(first, "solid")) width = length(second)
    else if (std.ascii.eqlIgnoreCase(second, "solid")) width = length(first)
    else return null;
    const known_width = width orelse return null;
    const color = try containerColorAlloc(a, tokens.rest()) orelse return null;
    return .{ .solid = .{ .width = known_width, .color = color } };
}

fn containerKnownCustomValue(a: std.mem.Allocator, raw: []const u8, environment: ?CustomEnvironment) std.mem.Allocator.Error!?[]const u8 {
    const selected = environment orelse return null;
    if (!selected.complete) return null;
    const call = customCall(raw) orelse return null;
    // This finite paint contract requires a known binding. The ordinary custom
    // evaluator keeps its CSS fallback behavior for its other callers.
    if (selected.get(call.name) != .known) return null;
    return switch (try customColorValue(a, selected, raw)) {
        .known => |value| value,
        .invalid, .unknown => null,
    };
}

fn containerColorWithCustomAlloc(a: std.mem.Allocator, raw: []const u8, environment: ?CustomEnvironment, background: bool) std.mem.Allocator.Error!?types.ContainerColor {
    const value = trim(raw);
    const resolved = if (std.mem.startsWith(u8, value, "var("))
        (try containerKnownCustomValue(a, value, environment)) orelse return null
    else value;
    if (background and std.ascii.eqlIgnoreCase(resolved, "none")) return .transparent;
    return containerColorAlloc(a, resolved);
}

fn containerBorderWithCustomAlloc(a: std.mem.Allocator, raw: []const u8, environment: ?CustomEnvironment) std.mem.Allocator.Error!?types.ContainerBorder {
    if (try containerBorderAlloc(a, raw)) |known| return known;
    const value = trim(raw);
    const start = std.mem.indexOf(u8, value, "var(") orelse return null;
    if (start != 0 and !std.ascii.isWhitespace(value[start - 1])) return null;
    var depth: usize = 1;
    var quote: u8 = 0;
    var escaped = false;
    var end = start + 4;
    while (end < value.len and depth != 0) : (end += 1) {
        const byte = value[end];
        if (escaped) { escaped = false; continue; }
        if (quote != 0) {
            if (byte == '\\') escaped = true else if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') { quote = byte; continue; }
        if (byte == '(') { depth += 1; if (depth > 32) return null; }
        if (byte == ')') depth -= 1;
    }
    if (depth != 0 or quote != 0 or escaped) return null;
    // Preserve the function/dimension token boundary in var(...)1px. Parsing
    // the remaining two scalar tokens avoids concatenating RGB and dimension.
    var scalars: [2][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ value[0..start], value[end..] }) |part| {
        var tokens = std.mem.tokenizeAny(u8, part, " \t\r\n\x0c");
        while (tokens.next()) |token| {
            if (count == scalars.len) return null;
            scalars[count] = token;
            count += 1;
        }
    }
    if (count != scalars.len) return null;
    const width = if (std.ascii.eqlIgnoreCase(scalars[0], "solid")) length(scalars[1])
        else if (std.ascii.eqlIgnoreCase(scalars[1], "solid")) length(scalars[0]) else null;
    const known_width = width orelse return null;
    const color = try containerColorWithCustomAlloc(a, value[start..end], environment, false) orelse return null;
    return .{ .solid = .{ .width = known_width, .color = color } };
}
// Signed lengths belong only to Container margins. Every other consumer
// continues through the original nonnegative length/width grammars.
fn containerMarginLength(raw: []const u8) ?types.StyleLength {
    const value = trim(raw);
    if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset"))
        return .{ .unit = .px, .value = 0 };
    var numeric = value;
    var unit: types.StyleLengthUnit = .px;
    var dimension = false;
    if (std.ascii.endsWithIgnoreCase(value, "px") or std.ascii.endsWithIgnoreCase(value, "em")) {
        numeric = value[0 .. value.len - 2];
        unit = if (std.ascii.endsWithIgnoreCase(value, "em")) .em else .px;
        dimension = true;
    }
    if (!widthNumberSyntax(numeric)) return null;
    if (!dimension and !widthNumberIsZero(numeric)) return null;
    const number = std.fmt.parseFloat(f32, numeric) catch return null;
    const result: types.StyleLength = .{ .unit = unit, .value = number };
    return if (types.validContainerMarginLength(result)) result else null;
}
fn containerMarginValues(value: []const u8) ?types.ContainerMargins {
    const zero: types.ContainerMargin = .{ .length = .{ .unit = .px, .value = 0 } };
    if (std.ascii.eqlIgnoreCase(trim(value), "initial") or std.ascii.eqlIgnoreCase(trim(value), "unset"))
        return .{ .top = zero, .right = zero, .bottom = zero, .left = zero };
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
    var values: [4]types.ContainerMargin = undefined;
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count == 4 or std.ascii.eqlIgnoreCase(token, "initial") or std.ascii.eqlIgnoreCase(token, "unset")) return null;
        values[count] = if (std.ascii.eqlIgnoreCase(token, "auto")) .auto else .{ .length = containerMarginLength(token) orelse return null };
        count += 1;
    }
    return switch (count) {
        1 => .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] },
        2 => .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] },
        3 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] },
        4 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
        else => null,
    };
}

fn containerHeightInvalidLiteral(value: []const u8) bool {
    // Called only after known and potentially supported width values. Do not
    // mistake an unrepresented CSS unit (lh, svh, cqh, ...) for invalid syntax.
    if (widthNumberSyntax(value)) return !widthNumberIsZero(value);
    inline for (.{ "px", "em", "%" }) |unit| {
        if (value.len > unit.len and std.ascii.endsWithIgnoreCase(value, unit)) {
            const numeric = value[0 .. value.len - unit.len];
            if (!widthNumberSyntax(numeric)) return true;
            return numeric[0] == '-' and !widthNumberIsZero(numeric);
        }
    }
    return std.ascii.eqlIgnoreCase(value, "nan") or std.ascii.eqlIgnoreCase(value, "inf") or
        std.ascii.eqlIgnoreCase(value, "none");
}
// Keep the original unsupported declaration until an exact element environment
// supplies its value. Selector uncertainty and cascade priority are unchanged.
fn declarationWithCustomPaint(a: std.mem.Allocator, original: Declaration, environment: ?CustomEnvironment) std.mem.Allocator.Error!Declaration {
    if (original.border_raw) |border| {
        if (environment == null) return original;
        var result = original;
        result.border_update = try borderUpdateAlloc(a, border.name, border.value, environment);
        return result;
    }
    const raw = original.custom_paint orelse return original;
    if (environment == null) return original;
    var result = original;
    if (original.property == .background) {
        if (try containerColorWithCustomAlloc(a, raw, environment, false)) |color| {
            if (color == .rgb) result.value = .{ .color = color.rgb };
        }
    } else if (original.property == .border) {
        if (try containerBorderWithCustomAlloc(a, raw, environment)) |border| {
            if (border == .solid and border.solid.color == .rgb)
                result.value = .{ .border = .{ .solid = .{ .width = border.solid.width, .color = border.solid.color.rgb } } };
        }
    }
    return result;
}

fn containerLineHeight(raw: []const u8) ?types.ContainerLineHeight {
    const value = trim(raw);
    if (std.ascii.eqlIgnoreCase(value, "normal")) return .normal;
    if (widthNumberSyntax(value)) {
        const factor = std.fmt.parseFloat(f32, value) catch return null;
        return if (std.math.isFinite(factor) and factor >= 0) .{ .multiplier = factor } else null;
    }
    const width = styleWidth(value) orelse return null;
    if (width.unit == .percent) return null;
    return .{ .length = .{ .unit = if (width.unit == .px) .px else .em, .value = width.value } };
}
fn containerColorEqual(left: types.ContainerColor, right: types.ContainerColor) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .transparent => true,
        .rgb => |rgb| std.mem.eql(u8, rgb, right.rgb),
        .light_dark => |pair| std.mem.eql(u8, pair.light, right.light_dark.light) and std.mem.eql(u8, pair.dark, right.light_dark.dark),
    };
}
fn containerBorderEqual(left: types.ContainerBorder, right: types.ContainerBorder) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .none => true,
        .solid => |solid| std.meta.eql(solid.width, right.solid.width) and containerColorEqual(solid.color, right.solid.color),
        .edges => |sides| containerBorderEdgesEqual(sides, right.edges),
    };
}
fn containerStyleEqual(left: types.ContainerStyle, right: types.ContainerStyle) bool {
    inline for (.{ "margins", "margin_values", "padding", "width", "float_side", "clear", "max_width", "box_sizing", "layout", "align_items", "flex_item", "line_height", "text_align", "height", "min_height", "columns", "positioning" }) |field|
        if (!std.meta.eql(@field(left, field), @field(right, field))) return false;
    if ((left.background == null) != (right.background == null) or (left.border == null) != (right.border == null)) return false;
    if (left.background) |color| if (!containerColorEqual(color, right.background.?)) return false;
    if (left.border) |border| if (!containerBorderEqual(border, right.border.?)) return false;
    return true;
}
fn containerCascadeAt(a: std.mem.Allocator, rules: []const ContainerRuleMatch, css: []const u8, screen_width: ?u32, environment: ?CustomEnvironment, border_collapse_consumed: bool) std.mem.Allocator.Error!ContainerResolution {
    var result = try containerCascadeAtAliases(a, rules, css, screen_width, .standard, environment, border_collapse_consumed);
    if (result.unresolved) return result;
    var aliases = hasColumnAlias(css);
    for (rules) |rule| aliases = aliases or hasColumnAlias(rule.css);
    if (!aliases) return result;
    // No engine family is implicit in a data-only native record. Admit only
    // an invariant result with neither, either, or both alias families active.
    inline for (.{ ColumnAliasPolicy.webkit, .moz, .all }) |policy| {
        const alternative = try containerCascadeAtAliases(a, rules, css, screen_width, policy, environment, border_collapse_consumed);
        result.specified = result.specified or alternative.specified;
        if (alternative.unresolved or !containerStyleEqual(result.style, alternative.style)) {
            result.unresolved = true;
            return result;
        }
    }
    return result;
}
fn containerCascadeAtAliases(a: std.mem.Allocator, rules: []const ContainerRuleMatch, css: []const u8, screen_width: ?u32, policy: ColumnAliasPolicy, environment: ?CustomEnvironment, border_collapse_consumed: bool) std.mem.Allocator.Error!ContainerResolution {
    var cascade_value: ContainerCascade = .{ .column_alias_policy = policy, .custom_environment = environment, .border_collapse_consumed = border_collapse_consumed };
    for (rules) |rule| {
        if (rule.rank_unknown) return .{ .unresolved = true };
        if (rule.viewport == .screen_max_width_px) {
            const width = screen_width orelse continue;
            if (width > rule.viewport.screen_max_width_px) continue;
        }
        cascade_value.responsive = rule.viewport != .all;
        try cascade_value.declarations(a, rule.css, rule.specificity, rule.order, rule.match == .unknown or rule.viewport == .unknown, false);
    }
    cascade_value.responsive = false;
    try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
    return cascade_value.result();
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
    custom_environment: ?CustomEnvironment = null,
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
                        if (try canonicalColorAlloc(a, value)) |canonical| {
                            selected = .{ .value = canonical };
                        } else if (try containerColorWithCustomAlloc(a, value, self.custom_environment, false)) |computed| {
                            if (computed == .rgb) selected = .{ .value = computed.rgb };
                        }
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
    if (value.len != 0 and (std.ascii.isAlphabetic(value[0]) or value[0] == '_')) {
        // A complete unescaped ASCII identifier is valid equality syntax. Only
        // required presence is learned; the attribute value is never matched.
        for (value[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return null;
        return name;
    }
    if (value.len < 2 or (value[0] != '\'' and value[0] != '"') or value[value.len - 1] != value[0]) return null;
    for (value[1 .. value.len - 1]) |byte| if (byte == value[0] or byte == '\\' or byte == '[' or byte == ']' or byte < 32 or byte == 127) return null;
    return name;
}

const DisplaySelector = struct {
    // Necessary direct-parent type only. This never proves a selector matches.
    required_parent_tag: ?[]const u8 = null,
    required_own_attribute: ?[]const u8 = null,
    // Necessary positive ancestor classes only; satisfying these conditions
    // never turns unsupported selector syntax into a known match.
    necessary_ancestor_classes: []const []const u8 = &.{},
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const u32 = &.{},
    specificity: u32 = 0,
    uncertain: bool = false,
};
const DisplayRule = struct { selector: DisplaySelector, css: []const u8, order: u32 };
pub const DisplayMatch = struct { css: []const u8, specificity: u32, order: u32, uncertain: bool };
pub const DisplayIterator = struct {
    // Only a source-owned physical edge may supply this. TextElement.parent
    // or a complete class union alone is not an adjacency certificate.
    physical_parent_tag: ?[]const u8 = null,
    attribute_presence: ?AttributePresenceSource = null,
    // Same complete, source-owned ancestry certificate as TextElement. Null
    // keeps missing/generated/outer ancestry unknown; own classes cannot fill it.
    complete_ancestor_classes: ?[]const u8 = null,
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
            if (selector.required_parent_tag) |required| if (self.physical_parent_tag) |actual|
                if (!std.ascii.eqlIgnoreCase(required, actual)) continue;
            if (self.complete_ancestor_classes) |classes| {
                for (selector.necessary_ancestor_classes) |required|
                    if (!Profile.hasClass(classes, required)) continue :rules;
            }
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

/// The output medium is a producer choice, independent of page or skin provenance.
pub const ReadingTarget = enum { unknown, screen, print };

/// Producer-only static table styles. No selector or declaration text enters a reader.
pub const Profile = struct {
    reading_target: ReadingTarget = .unknown,
    // Selected views borrow both this immutable page profile and their global
    // parent. No selected view owns or deinitializes either arena.
    page_style_parent: ?*const Profile = null,
    custom_properties: ?*const CustomProfile = null,
    arena: std.heap.ArenaAllocator,
    sources: []const SourceRange = &.{},
    // Exact parser inputs, owned by this profile arena. Used only when a selected
    // page adds its authored sheets; source metadata alone cannot rebuild rules.
    retained_sources: []const Source = &.{},
    rules: []const Rule,
    classes: []const []const u8,
    ancestor_classes: []const []const u8 = &.{},
    admitted_rule_numbers: []const u32,
    has_unsupported_rules: bool,
    globally_unresolved: bool = false,
    text_rules: []const TextRule = &.{},
    block_rules: []const TextRule = &.{},
    container_rules: []const ContainerRule = &.{},
    figure_rules: []const TextRule = &.{},
    missing_link_custom_rules: []const TextRule = &.{},
    display_rules: []const DisplayRule = &.{},
    display_classes: []const []const u8 = &.{},

    pub fn displayRules(self: *const Profile, tag: []const u8, classes: []const u8, id: []const u8) DisplayIterator {
        return .{ .profile = self, .tag = tag, .id = id, .classes = classes };
    }

    pub fn resolveAlignment(self: *const Profile, a: std.mem.Allocator, tag: []const u8, classes: []const u8, id: []const u8, legacy_align: ?[]const u8, css: []const u8) std.mem.Allocator.Error!AlignmentResolution {
        return self.resolveAlignmentWithAncestors(a, tag, classes, id, legacy_align, css, null);
    }
    /// Reuse only complete ancestor-class absence. A present class, parent
    /// pointer or class union never establishes selector matching or adjacency.
    pub fn resolveAlignmentIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, legacy_align: ?[]const u8, css: []const u8) std.mem.Allocator.Error!AlignmentResolution {
        if (self.page_style_parent != null) {
            if (element.page_style_root == null or css.len > max_css_bytes) return .{ .specified = true, .unresolved = true };
            const matched = try self.containerRuleMatchesIn(a, element);
            defer a.free(matched.rules);
            if (matched.unresolved) return .{ .specified = true, .unresolved = true };
            var cascade_value: AlignmentCascade = .{};
            if (presentationalTextAlign(legacy_align)) |alignment| cascade_value.consider(.{ .property = .text_align, .value = .{ .align_value = alignment }, .important = false, .order = 0 }, 0, false, false);
            for (matched.rules) |rule| try cascade_value.declarations(a, rule.css, rule.specificity, rule.order,
                rule.match == .unknown or rule.viewport != .all or rule.rank_unknown, false);
            try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
            return cascade_value.resolution;
        }
        return self.resolveAlignmentWithAncestors(a, element.tag, element.classes, element.id, legacy_align, css, element.complete_ancestor_classes);
    }
    fn resolveAlignmentWithAncestors(self: *const Profile, a: std.mem.Allocator, tag: []const u8, classes: []const u8, id: []const u8, legacy_align: ?[]const u8, css: []const u8, ancestor_classes: ?[]const u8) std.mem.Allocator.Error!AlignmentResolution {
        if (self.globally_unresolved or css.len > max_css_bytes) return .{ .specified = true, .unresolved = true };
        var cascade_value: AlignmentCascade = .{};
        if (presentationalTextAlign(legacy_align)) |alignment| cascade_value.consider(.{ .property = .text_align, .value = .{ .align_value = alignment }, .important = false, .order = 0 }, 0, false, false);
        var matches = self.displayRules(tag, classes, id);
        matches.complete_ancestor_classes = ancestor_classes;
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
        if (self.globally_unresolved or (self.page_style_parent != null and element.page_style_root == null) or css.len > max_css_bytes) return .unknown;
        var cascade_value: FontCascade = .{};
        for (self.text_rules) |rule| {
            const matched = rule.selector.matchIn(element, self.page_style_parent != null);
            if (matched == .no) continue;
            if (rule.selector.required_own_attribute) |name| if (attributes) |known| {
                if (known.get(known.ctx, name) == .absent) continue;
            };
            try cascade_value.declarations(a, rule.css, rule.selector.specificity, rule.order, rule.selector.uncertain or matched == .unknown, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return cascade_value.value;
    }

    /// The caller owns the result array; declarations remain borrowed from this
    /// build-time profile. No selector or CSS text belongs in a reader record.
    pub fn containerRuleMatchesIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement) std.mem.Allocator.Error!ContainerRuleMatches {
        if (self.globally_unresolved or (self.page_style_parent != null and element.page_style_root == null)) return .{ .unresolved = true };
        var rules: std.ArrayList(ContainerRuleMatch) = .empty;
        errdefer rules.deinit(a);
        for (self.container_rules) |rule| {
            const matched = rule.selector.matchIn(element, self.page_style_parent != null);
            if (matched == .no) continue;
            const specificity = if (element.source_sibling_scope != null and rule.selector.adjacent_sibling != null and matched == .known)
                rule.selector.adjacent_sibling.?.specificity else rule.selector.specificity;
            try rules.append(a, .{ .css = rule.css, .order = rule.order, .specificity = specificity,
                .match = matched, .viewport = rule.viewport, .rank_unknown = rule.rank_unknown, .provenance = rule.provenance });
        }
        return .{ .rules = try rules.toOwnedSlice(a) };
    }

    pub fn relativeContextPolicyPresentIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!bool {
        if (self.globally_unresolved or try hasRelativeContextDeclarationsAlloc(a, css)) return true;
        const matched = try self.containerRuleMatchesIn(a, element);
        defer a.free(matched.rules);
        if (matched.unresolved) return true;
        for (matched.rules) |rule| if (try hasRelativeContextDeclarationsAlloc(a, rule.css)) return true;
        return false;
    }

    pub fn columnFlowStylesheetPolicyAbsent(self: *const Profile, a: std.mem.Allocator) std.mem.Allocator.Error!bool {
        if (self.globally_unresolved) return false;
        for (self.container_rules) |rule| if (try hasColumnDescendantDeclarationsAlloc(a, rule.css)) return false;
        return true;
    }

    // This query covers only the closed MissingLinkPaint palette, decoration
    // and focus contract. The caller separately checks every actual ancestor;
    // it is not a font, layout, visibility or whole-page fidelity certificate.
    pub fn missingLinkAdditionalPaintUnchangedIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement) std.mem.Allocator.Error!bool {
        return (try self.missingLinkAdditionalPaintBlockerIn(a, element)) == null;
    }
    // The bool proof and its diagnostic share the exact matching and declaration
    // walk. Every returned slice belongs to this Profile until deinit().
    pub fn missingLinkAdditionalPaintBlockerIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement) std.mem.Allocator.Error!?MissingLinkPaintBlocker {
        const matches = try self.containerRuleMatchesIn(a, element);
        defer a.free(matches.rules);
        if (matches.unresolved) return .{ .reason = .global_unresolved };
        for (matches.rules) |rule| {
            var at: usize = 0;
            while (true) {
                const start = at;
                const raw = (try nextDeclarationAlloc(a, rule.css, &at)) orelse break;
                defer a.free(raw);
                if (trim(raw).len == 0) continue;
                const witness: MissingLinkPaintBlocker = .{ .reason = .declaration, .rule = rule,
                    .declaration = rule.css[start..at], .declaration_offset = start };
                const colon = std.mem.indexOfScalar(u8, raw, ':') orelse {
                    var malformed = witness; malformed.reason = .malformed_declaration; return malformed;
                };
                const name = trim(raw[0..colon]);
                const value = customPriority(raw[colon + 1 ..]);
                if (value.unknown) {
                    var unknown = witness; unknown.reason = .unknown_priority; return unknown;
                }
                if (customName(name) and !missingLinkCustomProperty(name)) continue;
                // These affect glyph shaping, which remains a separate text
                // obligation. They cannot set the closed paint fields above.
                if (std.ascii.eqlIgnoreCase(name, "font-feature-settings") or
                    std.ascii.eqlIgnoreCase(name, "-moz-font-feature-settings") or
                    std.ascii.eqlIgnoreCase(name, "-webkit-font-feature-settings")) continue;
                // Tab stops affect inherited text layout, not these closed link
                // paint fields. Keep selector uncertainty and layout refusal.
                if (std.ascii.eqlIgnoreCase(name, "tab-size") or
                    std.ascii.eqlIgnoreCase(name, "-moz-tab-size") or
                    std.ascii.eqlIgnoreCase(name, "-o-tab-size")) continue;
                return witness;
            }
        }
        return null;
    }
    // Refusal-only query over the same all-rule inventory and declaration
    // scanner as ordinary Container resolution. A match here never issues a
    // parent edge or computed inherited state. Custom values themselves have no
    // effect; their consuming declarations are still visited normally.
    pub fn pageAncestorEffectBlockerIn(self: *const Profile, a: std.mem.Allocator, root: ?*const TextElement) std.mem.Allocator.Error!?PageAncestorEffectBlocker {
        if (self.page_style_parent == null) return null;
        if (self.globally_unresolved) return .{ .reason = .global_unresolved };
        var ancestor = root orelse return .{ .reason = .missing_root };
        var depth: usize = 0;
        while (true) : (depth += 1) {
            if (depth == 64) return .{ .reason = .depth_limit, .ancestor_depth = depth };
            var query = ancestor.*;
            // This temporary marker only enables a potential-match query. Its
            // self fallback cannot authorize anything: every non-no result is
            // retained as a refusal. Do not export this node to any resolver.
            query.page_style_root = &query;
            query.complete_ancestor_classes = null;
            query.source_sibling = null;
            query.source_sibling_scope = null;
            query.source_sibling_source = null;
            query.ancestry_complete = false;
            query.physical_ancestry_complete = false;
            const matches = try self.containerRuleMatchesIn(a, &query);
            defer a.free(matches.rules);
            if (matches.unresolved) return .{ .reason = .global_unresolved, .ancestor_depth = depth };
            for (matches.rules) |rule| {
                var position: usize = 0;
                while (true) {
                    const start = position;
                    const raw = (try nextDeclarationAlloc(a, rule.css, &position)) orelse break;
                    defer a.free(raw);
                    if (trim(raw).len == 0) continue;
                    if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
                        const name = trim(raw[0..colon]);
                        const value = customPriority(raw[colon + 1 ..]);
                        if (customName(name) and !value.unknown) continue;
                    }
                    return .{ .reason = .declaration, .ancestor_depth = depth,
                        .rule = rule, .declaration = rule.css[start..position], .declaration_offset = start };
                }
            }
            ancestor = ancestor.parent orelse return null;
        }
    }

    // A distant-root capability does not describe every generated intermediate
    // node. Until an operation issues that path, any ordinary declaration may
    // affect such a node. This conservative boundary is deliberately separate
    // from own-element resolution: own fields can be compiled while the normal
    // report retains the unrepresented ancestor effect. No selector is claimed
    // to match a real node by this second witness.
    pub fn pageUnprovedInheritanceBlockerIn(self: *const Profile, a: std.mem.Allocator, root: ?*const TextElement) std.mem.Allocator.Error!?PageAncestorEffectBlocker {
        if (try self.pageAncestorEffectBlockerIn(a, root)) |failure| return failure;
        if (self.page_style_parent == null) return null;
        for (self.container_rules) |rule| {
            var position: usize = 0;
            while (true) {
                const start = position;
                const raw = (try nextDeclarationAlloc(a, rule.css, &position)) orelse break;
                defer a.free(raw);
                if (trim(raw).len == 0) continue;
                if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
                    const name = trim(raw[0..colon]);
                    const value = customPriority(raw[colon + 1 ..]);
                    if (customName(name) and !value.unknown) continue;
                }
                return .{ .reason = .unproved_ancestor_path,
                    .rule = .{ .css = rule.css, .order = rule.order, .specificity = rule.selector.specificity,
                        .match = .unknown, .viewport = rule.viewport, .rank_unknown = rule.rank_unknown, .provenance = rule.provenance },
                    .declaration = rule.css[start..position], .declaration_offset = start };
            }
        }
        return null;
    }

    pub fn resolveContainerIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!ContainerResolution {
        return self.resolveContainerInWithCustom(a, element, css, null);
    }

    pub fn resolveContainerInWithCustom(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8, environment: ?CustomEnvironment) std.mem.Allocator.Error!ContainerResolution {
        return self.resolveContainerInWithInheritance(a, element, css, environment, false);
    }

    /// The ordinary producer may consume border-collapse here only after its
    /// complete per-element inherited cascade has produced a concrete value.
    pub fn resolveContainerInWithInheritance(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8, environment: ?CustomEnvironment, border_collapse_consumed: bool) std.mem.Allocator.Error!ContainerResolution {
        if (self.globally_unresolved or css.len > max_css_bytes) return .{ .unresolved = true };
        const matched = try self.containerRuleMatchesIn(a, element);
        defer a.free(matched.rules);
        if (matched.unresolved) return .{ .unresolved = true };
        var base = try containerCascadeAt(a, matched.rules, css, null, environment, border_collapse_consumed);
        if (base.unresolved) return base;
        // This representation has one alternative. Bound proof work separately
        // from the CSS rule budget; exceeding it keeps the source unresolved.
        var thresholds: [32]u32 = undefined;
        var count: usize = 0;
        for (matched.rules) |rule| {
            if (rule.viewport != .screen_max_width_px) continue;
            const limit = rule.viewport.screen_max_width_px;
            var found = false;
            for (thresholds[0..count]) |known| found = found or known == limit;
            if (found) continue;
            if (count == thresholds.len) { base.unresolved = true; return base; }
            var index = count;
            while (index != 0 and thresholds[index - 1] < limit) : (index -= 1) thresholds[index] = thresholds[index - 1];
            thresholds[index] = limit; count += 1;
        }
        var alternative: ?types.ContainerStyle = null;
        var alternative_limit: u32 = 0;
        for (thresholds[0..count]) |limit| {
            const selected = try containerCascadeAt(a, matched.rules, css, limit, environment, border_collapse_consumed);
            base.specified = base.specified or selected.specified;
            if (selected.unresolved) { base.unresolved = true; return base; }
            if (containerStyleEqual(base.style, selected.style)) {
                // A narrower interval cannot return to the base after entering
                // an alternative: that would require a second breakpoint.
                if (alternative != null) { base.unresolved = true; return base; }
                continue;
            }
            if (alternative) |prior| {
                if (!containerStyleEqual(prior, selected.style)) { base.unresolved = true; return base; }
            } else {
                alternative = selected.style; alternative_limit = limit;
            }
        }
        if (alternative) |selected| {
            var responsive: types.ContainerScreenMaxWidth = .{ .max_width_px = alternative_limit };
            var normalized = selected;
            inline for (.{ "width", "max_width", "box_sizing", "line_height" }) |field| {
                if (!std.meta.eql(@field(base.style, field), @field(selected, field))) {
                    // Conditional declarations cannot remove an unconditional
                    // winner; explicit auto/none/normal resets stay typed.
                    @field(responsive, field) = @field(selected, field) orelse { base.unresolved = true; return base; };
                }
                @field(normalized, field) = @field(base.style, field);
            }
            if (!containerStyleEqual(base.style, normalized)) { base.unresolved = true; return base; }
            base.style.screen_max_width = responsive;
        }
        return base;
    }

    pub fn resolveBlockGeometryIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!BlockGeometryResolution {
        if (self.globally_unresolved or (self.page_style_parent != null and element.page_style_root == null) or css.len > max_css_bytes) return .{ .unresolved = true };
        var cascade_value: BlockGeometryCascade = .{};
        defer cascade_value.possible.deinit(a);
        for (self.block_rules) |rule| {
            const matched = rule.selector.matchIn(element, self.page_style_parent != null);
            if (matched == .no) continue;
            try cascade_value.declarations(a, rule.css, rule.selector.specificity, rule.order, rule.selector.uncertain or matched == .unknown, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        // DIV has zero initial edges; paragraph UA margins are viewer-owned,
        // so a P quartet needs independently explicit values on every side.
        return cascade_value.result(std.ascii.eqlIgnoreCase(element.tag, "div"));
    }

    pub fn hasTextContext(self: *const Profile) bool { return self.hasTextPaint() or self.block_rules.len != 0; }

    pub fn hasTextPaint(self: *const Profile) bool { return self.page_style_parent != null or self.globally_unresolved or self.text_rules.len != 0; }

    pub fn resolveTextPaint(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8) std.mem.Allocator.Error!TextPaint {
        return self.resolveTextPaintWithCustom(a, element, css, null);
    }

    pub fn resolveTextPaintWithCustom(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8, environment: ?CustomEnvironment) std.mem.Allocator.Error!TextPaint {
        if (self.page_style_parent != null) if (element.alternative_ancestry) |alternative| {
            if (element.observed_inline_style) |actual| {
                const other = alternative.observed_inline_style orelse return .{ .color = .unknown, .weight = .unknown, .font_style = .unknown };
                if (!std.mem.eql(u8, actual, other)) return .{ .color = .unknown, .weight = .unknown, .font_style = .unknown };
            }
        };
        if (self.globally_unresolved or (self.page_style_parent != null and element.page_style_root == null) or css.len > max_css_bytes) return .{ .color = .unknown, .weight = .unknown, .font_style = .unknown };
        var cascade_value: TextCascade = .{ .custom_environment = environment };
        defer cascade_value.possible_colors.deinit(a);
        defer cascade_value.possible_weights.deinit(a);
        defer cascade_value.possible_font_styles.deinit(a);
        for (self.text_rules) |rule| {
            const matched = rule.selector.matchIn(element, self.page_style_parent != null);
            if (matched != .no) try cascade_value.declarations(a, rule.css, rule.selector.specificity, rule.order, rule.selector.uncertain or matched == .unknown, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return cascade_value.result();
    }

    // The compiler calls this only for a complete source-issued physical path.
    // Ordinary inheritance reuses the existing cascade at each real ancestor;
    // unknown values stop that field. Other effects retain the page refusal.
    pub fn resolveTextPaintWithObservedInheritance(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8, environment: ?CustomEnvironment) std.mem.Allocator.Error!TextPaint {
        var result = try self.resolveTextPaintWithCustom(a, element, css, environment);
        if (self.page_style_parent == null or element.source_root_child == null or !element.physical_ancestry_complete) return result;
        var color_needed = result.color == null or result.color.? == .inherit;
        var weight_needed = result.weight == null or result.weight.? == .inherit;
        var italic_needed = result.font_style == null or result.font_style.? == .inherit;
        var cursor = element.parent;
        var depth: usize = 0;
        while (cursor) |ancestor| : (depth += 1) {
            if (!color_needed and !weight_needed and !italic_needed) break;
            if (depth == 64 or !ancestor.physical_ancestry_complete or ancestor.observed_inline_style == null) {
                if (color_needed) { result.color = .unknown; result.color_inline = false; }
                if (weight_needed) { result.weight = .unknown; result.weight_inline = false; }
                if (italic_needed) { result.font_style = .unknown; result.font_style_inline = false; }
                break;
            }
            // Compute an ancestor's variable consumers only from its own
            // retained environment. The descendant argument cannot lend values.
            var ancestor_environment = ancestor.observed_custom_environment;
            if (ancestor.alternative_ancestry) |alternative| {
                ancestor_environment = if (ancestor_environment) |actual|
                    if (alternative.observed_custom_environment) |other| try intersectCustomEnvironmentsAlloc(a, actual, other) else null
                else null;
            }
            const paint = try self.resolveTextPaintWithCustom(a, ancestor, ancestor.observed_inline_style.?, ancestor_environment);
            if (color_needed) if (paint.color) |value| if (value != .inherit) {
                result.color = value; result.color_inline = false; color_needed = false;
            };
            if (weight_needed) if (paint.weight) |value| if (value != .inherit) {
                result.weight = value; result.weight_inline = false; weight_needed = false;
            };
            if (italic_needed) if (paint.font_style) |value| if (value != .inherit) {
                result.font_style = value; result.font_style_inline = false; italic_needed = false;
            };
            cursor = ancestor.parent;
        }
        return result;
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
    pub const FigureRootDirectionWitness = struct {
        pub const Reason = enum { none, predicate, chain, terminal, custom_predicate, custom_classes };
        reason: Reason = .none,
        rule_index: usize = 0,
        custom_rule: bool = false,
        // Borrowed from this Profile; consumed synchronously at the refusal.
        css: []const u8 = "",
    };
    fn rootDirectionRefusal(witness: ?*FigureRootDirectionWitness, reason: FigureRootDirectionWitness.Reason, rule_index: usize, custom_rule: bool, css: []const u8) FigureRootDirectionUse {
        if (witness) |out| out.* = .{ .reason = reason, .rule_index = rule_index, .custom_rule = custom_rule, .css = css };
        return .unresolved;
    }
    pub fn figureRootDirectionUseWithLanguage(self: *const Profile, authored: ?*const TextElement, caption_classes: ?[]const u8, caption_tags: ?[]const []const u8, root_language: ?[]const u8, caption_no_language_override: bool, outer_languages: ?[]const []const u8) FigureRootDirectionUse {
        return self.figureRootDirectionUseWithWitness(authored, caption_classes, caption_tags, root_language, caption_no_language_override, outer_languages, null);
    }
    pub fn figureRootDirectionUseWithWitness(self: *const Profile, authored: ?*const TextElement, caption_classes: ?[]const u8, caption_tags: ?[]const []const u8, root_language: ?[]const u8, caption_no_language_override: bool, outer_languages: ?[]const []const u8, witness: ?*FigureRootDirectionWitness) FigureRootDirectionUse {
        return self.figureRootDirectionUseWithCompleteClasses(authored, caption_classes, caption_tags, root_language, caption_no_language_override, outer_languages, null, witness);
    }
    pub fn figureRootDirectionUseWithCompleteClasses(self: *const Profile, authored: ?*const TextElement, caption_classes: ?[]const u8, caption_tags: ?[]const []const u8, root_language: ?[]const u8, caption_no_language_override: bool, outer_languages: ?[]const []const u8, complete_classes: ?[]const u8, witness: ?*FigureRootDirectionWitness) FigureRootDirectionUse {
        if (witness) |out| out.* = .{};
        const ltr: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
        const rtl: TextElement = .{ .tag = "div", .classes = "mw-content-rtl mw-parser-output" };
        var result: FigureRootDirectionUse = .independent;
        direction_rule: for (self.figure_rules, 0..) |rule, rule_index| {
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
                    const complete: ?[]const u8 = if (rule.selector.caption_class_guard_requires_complete) complete_classes else "";
                    if (complete) |outer_classes| {
                        var absent = false;
                        for (rule.selector.caption_class_guard) |name| {
                            const present = if (rule.selector.caption_class_guard_requires_complete)
                                figureFunctionalClassPossible(authored, inherited_classes, outer_classes, name)
                            else figureCaptionClassPresent(authored, inherited_classes, name);
                            absent = absent or !present;
                        }
                        if (absent) continue;
                    }
                }
                return rootDirectionRefusal(witness, .predicate, rule_index, false, rule.css);
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
                if (index != 0 or rule.selector.chain.len != 2 or rule.selector.uncertain) return rootDirectionRefusal(witness, .chain, rule_index, false, rule.css);
                const terminal = rule.selector.chain[1];
                const tag = terminal.tag orelse return rootDirectionRefusal(witness, .terminal, rule_index, false, rule.css);
                if ((!std.ascii.eqlIgnoreCase(tag, "figure") and !std.ascii.eqlIgnoreCase(tag, "figcaption")) or
                    terminal.classes.len != 0 or terminal.ids.len != 0) return rootDirectionRefusal(witness, .terminal, rule_index, false, rule.css);
                result = .generated_only;
            }
        }
        // Custom definitions are separate from direct Figure rules. A root
        // direction-dependent environment must not leak into the later parse.
        if (self.custom_properties) |custom| for (custom.rules, 0..) |rule, rule_index| {
            if (rule.root_only) continue; // CSS :root is not this content DIV.
            if (rule.root_predicate_unresolved) return rootDirectionRefusal(witness, .custom_predicate, rule_index, true, rule.css);
            if (rule.selector.tag) |tag| if (!std.ascii.eqlIgnoreCase(tag, "div")) continue;
            if (rule.selector.id) |id| if (id.len != 0) continue;
            var match_ltr = true;
            var match_rtl = true;
            for (rule.selector.classes) |required| {
                const name = custom.classes[required];
                match_ltr = match_ltr and Profile.hasClass(ltr.classes, name);
                match_rtl = match_rtl and Profile.hasClass(rtl.classes, name);
            }
            if (match_ltr != match_rtl) return rootDirectionRefusal(witness, .custom_classes, rule_index, true, rule.css);
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

    pub fn missingLinkCustomPaintUnchanged(self: *const Profile, element: *const TextElement) bool {
        if (self.globally_unresolved) return false;
        for (self.missing_link_custom_rules) |rule| {
            var cursor: ?*const TextElement = element;
            while (cursor) |node| : (cursor = node.parent) {
                if (rule.selector.matches(node) or figureOuterSelectorUnknown(rule.selector, node)) return false;
            }
            // The supplied content DIV is not the browser HTML/BODY. A token
            // definition on those outer subjects may be inherited even when
            // the complete content subtree contains no matching element.
            if (rule.selector.chain.len != 0) {
                const terminal = rule.selector.chain[rule.selector.chain.len - 1];
                if (terminal.tag) |tag| if (std.ascii.eqlIgnoreCase(tag, "html") or std.ascii.eqlIgnoreCase(tag, "body")) return false;
            }
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

    pub fn hasClass(names: []const u8, required: []const u8) bool {
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
        if (target == .td or target == .th or target == .cell) {
            addCellVerticalHint(&winners, context.legacy_vertical_align);
            addCellWidthHint(&winners, context.legacy_cell_width);
        }
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
                const issued_root = self.page_style_parent != null and context.page_style_root != null and
                    positivePageAncestorClass(context.page_style_root.?, name);
                if (issued_root) {
                    // This one positive descendant requirement is proved.
                } else if (ancestor_names) |names| {
                    if (!hasClass(names, name)) continue;
                } else if (self.page_style_parent != null) {
                    uncertain = true;
                } else if (selector_value.ancestor_mask != 0) {
                    if (selector_value.ancestor_mask & ancestor_scope == 0) continue;
                } else uncertain = true;
            }
            if (ancestor_names) |names| for (selector_value.necessary_classes) |name| {
                if (!hasClass(own_names, name) and !hasClass(names, name) and
                    !(self.page_style_parent != null and context.page_style_root != null and positivePageAncestorClass(context.page_style_root.?, name))) continue :rules;
            };
            if (uncertain) winners.selector_unresolved = true;
            for (rule.declarations) |declaration| winners.add(try declarationWithCustomPaint(a, declaration, context.custom_environment), selector_value.specificity, uncertain or !representedDeclaration(target, declaration), false);
        }
        var order: u32 = max_rules * 1024;
        var pos: usize = 0;
        while (try nextDeclarationAlloc(a, inline_css, &pos)) |raw| {
            defer a.free(raw);
            order += 1;
            if (try declarationAlloc(a, raw, order)) |declaration| winners.add(try declarationWithCustomPaint(a, declaration, context.custom_environment), 0, !representedDeclaration(target, declaration), true);
        }
        return winners;
    }

    pub fn resolveBorderCollapseIn(self: *const Profile, a: std.mem.Allocator, element: *const TextElement, css: []const u8, parent: ?BorderCollapseState) std.mem.Allocator.Error!?BorderCollapseState {
        if (self.globally_unresolved or css.len > max_css_bytes) return .unknown;
        var cascade_value: BorderCollapseCascade = .{ .parent = parent };
        const matched = try self.containerRuleMatchesIn(a, element);
        defer a.free(matched.rules);
        if (matched.unresolved) return .unknown;
        var unknown_rank = false;
        for (matched.rules) |rule| {
            if (rule.rank_unknown) {
                var relevant: BorderCollapseCascade = .{ .parent = parent };
                try relevant.declarations(a, rule.css, 0, rule.order, true, false);
                unknown_rank = unknown_rank or relevant.seen;
            }
            try cascade_value.declarations(a, rule.css, rule.specificity, rule.order,
                rule.match == .unknown or rule.viewport != .all, false);
        }
        try cascade_value.declarations(a, css, 0, max_rules * 1024, false, true);
        return if (unknown_rank) .unknown else cascade_value.result();
    }

    pub fn resolveTable(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        return self.resolveTableWithAncestors(a, inherited_scope, classes, null, legacy_bg, inline_css);
    }

    pub fn resolveTableWithAncestors(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, ancestor_names: ?[]const u8, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        return self.resolveTableWithContext(a, inherited_scope, classes, .{ .ancestor_classes = ancestor_names }, legacy_bg, inline_css);
    }

    pub fn resolveTableWithContext(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, context: ElementContext, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        const ancestor_names = context.ancestor_classes;
        if (self.globally_unresolved or (self.page_style_parent != null and context.page_style_root == null) or inline_css.len > max_css_bytes) return .{ .style = null, .scope = inherited_scope | self.classScope(classes), .unresolved = true, .background_specified = true, .margin_basis_unresolved = true, .descendant_style_unresolved = true };
        const own_scope = self.classScope(classes);
        // Every local selector is represented as a proved match/nonmatch or an
        // uncertain property override. An extra element class absent from that
        // complete sheet cannot erase independent known paint.
        var winners = try self.cascade(a, .table, own_scope, if (ancestor_names) |names| self.ancestorScope(names) else 0, classes, context, legacy_bg, null, inline_css);
        if (context.text_color_consumed) winners.slots[@intFromEnum(Property.text_color)] = null;
        computedTableCollapse(&winners, context.computed_border_collapse);
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
        const flow_conflict = tableFlowFloatConflict(&style);
        return .{ .style = if (types.validTableStyle(style)) style else null, .scope = inherited_scope | own_scope, .unresolved = winners.unresolvedWithFont(context.font_size_consumed) or flow_conflict, .margin_basis_unresolved = winners.font_basis_unresolved or self.inheritedFontBasisUnresolved(inherited_scope, ancestor_names, context.complete_font_ancestor_ids, context.complete_font_ancestor_tags), .background_specified = winners.value(.background) != null, .width_specified = winners.value(.width) != null or unresolvedTableWidthBox(winners), .line_height_em = selectedLineHeight(winners) };
    }

    fn inheritedFontBasisUnresolved(self: *const Profile, scope: Scope, ancestor_names: ?[]const u8, complete_ids: ?[]const []const u8, complete_tags: ?[]const []const u8) bool {
        rules: for (self.rules) |rule| {
            const selected = rule.selector;
            if (selected.mask != 0 and selected.mask & scope == 0) continue;
            if (!selected.unsupported) {
                if (complete_tags) |tags| if (selected.own_tag) |required| {
                    var found = false;
                    for (tags) |tag| if (std.ascii.eqlIgnoreCase(tag, required)) { found = true; break; };
                    if (!found) continue :rules;
                };
                if (complete_ids) |ids| {
                    for (selected.own_ids) |required| {
                        var found = false;
                        for (ids) |id| if (std.mem.eql(u8, id, required)) { found = true; break; };
                        if (!found) continue :rules;
                    }
                }
            }
            // Actual class absence remains an independent necessary-condition
            // proof. Merged names never prove tag/order/compound identity.
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
        if (self.globally_unresolved or (self.page_style_parent != null and context.page_style_root == null) or inline_css.len > max_css_bytes) return .{ .style = null, .background = null, .background_specified = true, .unresolved = true, .padding_basis_unresolved = true, .alignment_specified = true };
        var winners = try self.cascade(a, if (header) .th else .td, scope, ancestor_scope | (if (self.page_style_parent != null) (if (ancestor_names) |names| self.ancestorScope(names) else 0) else 0), own_names, context, legacy_bg, legacy_align, inline_css);
        if (context.text_color_consumed) winners.slots[@intFromEnum(Property.text_color)] = null;
        // Border-collapse has no cell box effect, but its computed inherited
        // value remains on the producer's element for any nested table.
        if (context.computed_border_collapse) |value| if (value != .unknown) {
            winners.slots[@intFromEnum(Property.collapse)] = null;
        };
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
        style.min_width = selectedCellMinimumWidth(winners);
        style.width = selectedCellWidth(winners);
        if (winners.value(.vertical_align)) |value| if (value == .cell_vertical_align_value) { style.vertical_align = value.cell_vertical_align_value; };
        const background = winners.value(.background);
        return .{ .style = if (types.validCellStyle(style)) style else null, .background = if (background) |value| (if (value == .color) value.color else null) else null, .background_specified = background != null, .unresolved = winners.unresolvedWithFont(context.font_size_consumed), .padding_basis_unresolved = winners.font_basis_unresolved or self.inheritedFontBasisUnresolved(scope, ancestor_names, null, null), .alignment_specified = winners.value(.text_align) != null };
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
    reading_target: ReadingTarget = .unknown,
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
    container_rules: std.ArrayList(ContainerRule) = .empty,
    container_source: []const u8 = "",
    container_source_index: usize = 0,
    container_source_byte_start: usize = 0,
    container_conditions: []const []const u8 = &.{},
    container_viewport: ContainerViewportCondition = .all,
    container_rank_unknown: bool = false,
    figure_rules: std.ArrayList(TextRule) = .empty,
    missing_link_custom_rules: std.ArrayList(TextRule) = .empty,
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
        // The existing paint fallback extracts only positive ancestor classes
        // outside functions/attributes and refuses sibling/escaped ambiguity.
        // Keep the terminal uncertainty: a satisfied necessary condition never
        // promotes this unsupported selector into a known cascade winner.
        const necessary = (try self.uncertainPaintSelector(trim(raw))).?;
        return .{ .chain = compounds, .specificity = std.math.maxInt(u64), .uncertain = true, .required_own_attribute = terminal.required_own_attribute, .necessary_ancestor_classes = necessary.necessary_classes };
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
    fn uncertainContainerSelector(self: *Builder, raw: []const u8) !ContainerSelector {
        var fallback = try self.uncertainTextSelector(raw);
        if (try self.containerRequiredOwnAttribute(raw)) |name| fallback.required_own_attribute = name;
        var result: ContainerSelector = .{ .fallback = fallback, .necessary_chain = try self.containerNecessaryChain(raw), .specificity = std.math.maxInt(u64), .uncertain = true };
        // Parsing this extra factual shape does not alter any global caller.
        const text = trim(raw);
        if (std.mem.indexOfScalar(u8, text, '+')) |plus| {
            if (std.mem.indexOfAny(u8, text, "~>|\\[]():/*&") == null and
                std.mem.indexOfScalar(u8, text[plus + 1 ..], '+') == null) {
                const left = try self.paintCompound(trim(text[0..plus]), true);
                const right = try self.paintCompound(trim(text[plus + 1 ..]), true);
                if (left != null and right != null) {
                    const l = left.?; const r = right.?;
                    result.adjacent_sibling = .{ .previous = .{ .tag = l.tag, .classes = l.classes, .ids = l.ids },
                        .subject = .{ .tag = r.tag, .classes = r.classes, .ids = r.ids },
                        .specificity = (@as(u64, @intCast(l.ids.len + r.ids.len)) << 42) +
                            (@as(u64, @intCast(l.classes.len + r.classes.len)) << 21) +
                            @intFromBool(l.tag != null) + @intFromBool(r.tag != null) };
                }
            }
        }
        return result;
    }
    // Keep positive compound facts around an unsupported attribute value or
    // generated-content suffix. This chain can only disprove the old fallback.
    fn containerNecessaryCompound(self: *Builder, raw: []const u8, terminal: bool) !?TextCompound {
        const text = raw;
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(self.a);
        var at: usize = 0;
        while (at < text.len) {
            if (text[at] == ':') {
                if (!terminal or (!std.ascii.eqlIgnoreCase(text[at..], "::before") and !std.ascii.eqlIgnoreCase(text[at..], "::after"))) return null;
                break;
            }
            if (text[at] != '[') {
                try plain.append(self.a, text[at]);
                at += 1;
                continue;
            }
            if (plain.items.len != 0 and try self.paintCompound(plain.items, true) == null) return null;
            const start = at;
            var quote: u8 = 0;
            at += 1;
            while (at < text.len) : (at += 1) {
                const byte = text[at];
                if (byte == '\\' or byte < 32 or byte == 127) return null;
                if (quote != 0) {
                    if (byte == quote) quote = 0;
                } else if (byte == '\'' or byte == '"') {
                    quote = byte;
                } else if (byte == ']') break else if (byte == '[') return null;
            }
            if (at == text.len or quote != 0) return null;
            const attribute = text[start .. at + 1];
            if (requiredOwnAttribute(attribute) == null) {
                // Reuse the strict quoted-value grammar after removing only a
                // recognized positive comparison operator. No value is matched.
                const inner = trim(attribute[1 .. attribute.len - 1]);
                const equals = std.mem.indexOfScalar(u8, inner, '=') orelse return null;
                if (equals == 0 or std.mem.indexOfScalar(u8, "~|^$*", inner[equals - 1]) == null) return null;
                const normalized = try std.mem.concat(self.a, u8, &.{ "[", inner[0 .. equals - 1], inner[equals..], "]" });
                defer self.a.free(normalized);
                if (requiredOwnAttribute(normalized) == null) return null;
            }
            at += 1;
            if (at < text.len and std.mem.indexOfScalar(u8, ".#[:", text[at]) == null) return null;
        }
        const compound = (try self.paintCompound(plain.items, true)) orelse return null;
        if (compound.tag == null and compound.classes.len == 0 and compound.ids.len == 0) return null;
        return .{ .tag = compound.tag, .classes = compound.classes, .ids = compound.ids };
    }

    fn containerNecessaryChain(self: *Builder, raw: []const u8) ![]const ContainerCompound {
        const text = trim(raw);
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfAny(u8, text, "\\()&\x00") != null or
            std.mem.indexOf(u8, text, "/*") != null) return &.{};
        var chain: std.ArrayList(ContainerCompound) = .empty;
        defer chain.deinit(self.a);
        var at: usize = 0;
        var direct_parent = false;
        while (at < text.len) {
            const end = figureCompoundEnd(text, at, false) orelse return &.{};
            if (end == at or chain.items.len == 32) return &.{};
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
            const compound = (try self.containerNecessaryCompound(text[at..end], next == text.len)) orelse return &.{};
            try chain.append(self.a, .{ .compound = compound, .direct_parent = direct_parent });
            if (next == text.len) break;
            direct_parent = text[next] == '>';
            if (direct_parent) {
                next += 1;
                while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
                if (next == text.len or text[next] == '>') return &.{};
            } else if (next == end) return &.{};
            at = next;
        }
        return chain.toOwnedSlice(self.a);
    }

    fn containerRequiredOwnAttribute(self: *Builder, raw: []const u8) !?[]const u8 {
        const text = trim(raw);
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or
            std.mem.indexOfAny(u8, text, "\\+~|&\x00") != null) return null;
        var at: usize = 0;
        var terminal: []const u8 = "";
        while (at < text.len) {
            const end = figureCompoundEnd(text, at, false) orelse return null;
            if (end == at) return null;
            terminal = text[at..end];
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
            if (next == text.len) break;
            if (text[next] == '>') {
                next += 1;
                while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
                if (next == text.len or text[next] == '>') return null;
            } else if (next == end) return null;
            at = next;
        }
        const opening = std.mem.indexOfScalar(u8, terminal, '[') orelse return null;
        // Only a positive attribute after an exact type/class/ID prefix is
        // necessary. Attributes inside :not/:is/:has remain uncertain.
        if (opening != 0 and try self.paintCompound(terminal[0..opening], true) == null) return null;
        const closing = std.mem.indexOfScalarPos(u8, terminal, opening + 1, ']') orelse return null;
        const name = requiredOwnAttribute(terminal[opening .. closing + 1]) orelse return null;
        return try self.a.dupe(u8, name);
    }
    fn containerSelector(self: *Builder, raw: []const u8) !ContainerSelector {
        const text = trim(raw);
        var chain: std.ArrayList(ContainerCompound) = .empty;
        var pos: usize = 0;
        var direct_parent = false;
        var specificity: u64 = 0;
        while (pos < text.len) {
            const end = figureCompoundEnd(text, pos, false) orelse return self.uncertainContainerSelector(raw);
            if (end == pos or chain.items.len == 32) return self.uncertainContainerSelector(raw);
            const part = text[pos..end];
            var base = part;
            var ordinal: ?u32 = null;
            if (std.mem.indexOfScalar(u8, part, ':')) |colon| {
                const pseudo = part[colon..];
                if (std.ascii.eqlIgnoreCase(pseudo, ":first-child")) ordinal = 1 else {
                    if (pseudo.len < 13 or !std.ascii.eqlIgnoreCase(pseudo[0..11], ":nth-child(") or pseudo[pseudo.len - 1] != ')')
                        return self.uncertainContainerSelector(raw);
                    const digits = trim(pseudo[11 .. pseudo.len - 1]);
                    if (digits.len == 0) return self.uncertainContainerSelector(raw);
                    for (digits) |byte| if (!std.ascii.isDigit(byte)) return self.uncertainContainerSelector(raw);
                    const value = std.fmt.parseInt(u32, digits, 10) catch return self.uncertainContainerSelector(raw);
                    if (value == 0) return self.uncertainContainerSelector(raw);
                    ordinal = value;
                }
                base = if (colon == 0) "*" else part[0..colon];
            }
            const parsed = try self.paintCompound(base, true) orelse return self.uncertainContainerSelector(raw);
            try chain.append(self.a, .{ .compound = .{ .tag = parsed.tag, .classes = parsed.classes, .ids = parsed.ids },
                .element_index = ordinal, .direct_parent = direct_parent });
            specificity += (@as(u64, @intCast(parsed.ids.len)) << 42) +
                (@as(u64, @intCast(parsed.classes.len + @intFromBool(ordinal != null))) << 21) + @intFromBool(parsed.tag != null);
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
            if (next == text.len) break;
            direct_parent = text[next] == '>';
            if (direct_parent) {
                next += 1;
                while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
                if (next == text.len) return self.uncertainContainerSelector(raw);
            } else if (next == end) return self.uncertainContainerSelector(raw);
            pos = next;
        }
        if (chain.items.len == 0) return self.uncertainContainerSelector(raw);
        return .{ .chain = chain.items, .specificity = specificity };
    }
    fn appendContainerRules(self: *Builder, prelude: []const u8, css: []const u8, order: u32, css_byte_start: usize) !void {
        var parts: SelectorList = .{ .source = prelude };
        var selectors: std.ArrayList(ContainerSelector) = .empty;
        var selector_texts: std.ArrayList([]const u8) = .empty;
        var uncertain_list = false;
        while (try parts.nextAlloc(self.a)) |part| {
            const selected = try self.containerSelector(part);
            uncertain_list = uncertain_list or selected.uncertain;
            try selectors.append(self.a, selected);
            try selector_texts.append(self.a, try self.a.dupe(u8, part));
        }
        for (selectors.items, selector_texts.items) |item, selector_text| {
            var selected = item;
            // Keep existing list-wide uncertainty; this positive relation is
            // supported only as one exact sole selector.
            if (selectors.items.len != 1) selected.adjacent_sibling = null;
            if (uncertain_list) { selected.uncertain = true; selected.specificity = std.math.maxInt(u64); }
            if (self.container_rules.items.len == max_rules) return error.StyleProfileLimit;
            try self.container_rules.append(self.a, .{ .selector = selected, .css = css, .order = order, .viewport = self.container_viewport, .rank_unknown = self.container_rank_unknown,
                .provenance = .{ .selector = selector_text, .conditions = self.container_conditions,
                    .source_index = self.container_source_index, .css_byte_start = css_byte_start } });
        }
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

    // A relative child chain can observe the inserted ParserOutput root only
    // through a compound that can match that DIV. The attested f458 wrapper
    // has no ID (AddWrapperDivClass::transform), so exact positive :target
    // also excludes it. This proves dependency absence, never :has matching.
    // Keep lists, siblings, attributes, escapes and other pseudos uncertain.
    fn relativeChildrenExcludeContentRoot(self: *Builder, raw: []const u8) std.mem.Allocator.Error!bool {
        const text = trim(raw);
        if (text.len < 2 or text[0] != '>' or !std.unicode.utf8ValidateSlice(text) or
            std.mem.indexOfAny(u8, text, ",+~\\[]()\"'") != null) return false;
        var children = std.mem.splitScalar(u8, text[1..], '>');
        while (children.next()) |raw_child| {
            const child = trim(raw_child);
            if (child.len == 0) return false;
            const target = child.len >= 7 and std.ascii.eqlIgnoreCase(child[child.len - 7 ..], ":target");
            const prefix = if (target) child[0 .. child.len - 7] else child;
            if (std.mem.indexOfScalar(u8, prefix, ':') != null) return false;
            const compound = if (prefix.len == 0 and target) PaintCompound{} else
                (try self.paintCompound(prefix, true) orelse return false);
            const non_div = if (compound.tag) |tag| !std.ascii.eqlIgnoreCase(tag, "div") else false;
            if (!non_div and !target) return false;
        }
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
            if (std.ascii.eqlIgnoreCase(name, "has") and try self.relativeChildrenExcludeContentRoot(arguments)) {
                at = end; continue;
            }
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

    // A functional-only negation has no positive paint prefix. Prove only
    // that each exact simple argument has the same truth for both attested
    // wrapper alternatives; do not grant a match or discard outer ancestry.
    fn invariantRootNegationCompound(self: *Builder, raw: []const u8) std.mem.Allocator.Error!bool {
        const ltr: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
        const rtl: TextElement = .{ .tag = "div", .classes = "mw-content-rtl mw-parser-output" };
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < raw.len) {
            if (count == 16 or raw.len - pos < 6 or !std.ascii.eqlIgnoreCase(raw[pos .. pos + 5], ":not(")) return false;
            const end = std.mem.indexOfScalarPos(u8, raw, pos + 5, ')') orelse return false;
            const argument = try self.paintCompound(trim(raw[pos + 5 .. end]), true) orelse return false;
            const compound: TextCompound = .{ .tag = argument.tag, .classes = argument.classes, .ids = argument.ids };
            if (compound.matches(&ltr) != compound.matches(&rtl)) return false;
            count += 1;
            pos = end + 1;
        }
        return count != 0;
    }

    // The two normal content-root direction alternatives have identical
    // attribute-key presence. Only values (class/dir) vary. This closed bare
    // presence conjunction is direction-invariant; it proves neither absence
    // nor selector matching, and makes no root-position assumption.
    fn bareRootAttributePresenceInvariant(part: []const u8) bool {
        if (part.len == 0) return false;
        var pos: usize = 0;
        while (pos < part.len) {
            if (part[pos] != '[') return false;
            const end = std.mem.indexOfScalarPos(u8, part, pos + 1, ']') orelse return false;
            const name = trim(part[pos + 1 .. end]);
            if (name.len == 0 or !paintIdentifierStart(name, 0) or paintIdentifierEnd(name, 0) != name.len) return false;
            for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
            pos = end + 1;
        }
        return true;
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
                if (bareRootAttributePresenceInvariant(part)) { pos = next; continue; }
                if ((may_be_root and !try self.invariantRootNegationCompound(part)) or try self.functionalRootPredicateUnresolved(part, false, depth)) return true;
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

    fn figureBeforeRequiredOwnAttribute(self: *Builder, raw: []const u8) !?[]const u8 {
        // A positive own predicate remains necessary for its ::before box.
        // Only this exact terminal pseudo-element is stripped; the existing
        // scanner still refuses functions, escapes, siblings and extra tails.
        const text = trim(raw);
        const suffix = "::before";
        if (text.len > suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix) and
            text[text.len - suffix.len - 1] == ']') {
            const subject = try self.displaySelector(text[0 .. text.len - suffix.len], true);
            return subject.required_own_attribute;
        }
        return null;
    }

    // Refutation only: every outside-function literal class in a closed
    // descendant/child chain is necessary somewhere in the complete domain.
    // Attribute values supply no classes and remain unsupported predicates.
    fn figureNecessaryChainClasses(self: *Builder, raw: []const u8) ![]const []const u8 {
        const text = trim(raw);
        if (text.len == 0) return &.{};
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.a);
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < text.len) {
            const end = figureCompoundEnd(text, pos, false) orelse return &.{};
            if (end == pos or count == 32) return &.{};
            const compound = (try self.figureNecessaryCompound(text[pos..end])) orelse return &.{};
            for (compound.classes) |name| try names.append(self.a, name);
            count += 1;
            var next = end;
            while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
            if (next == text.len) break;
            if (text[next] == '>') {
                next += 1;
                while (next < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[next]) != null) : (next += 1) {}
                if (next == text.len) return &.{};
            } else if (next == end) return &.{};
            pos = next;
        }
        return names.toOwnedSlice(self.a);
    }

    fn uncertainFigureSelector(self: *Builder, raw: []const u8) !TextSelector {
        var result = try self.uncertainTextSelector(raw);
        // The existing terminal scanner retains only positive classes outside
        // functions. Their absence can refute an unsupported caption effect;
        // presence never grants functional selector matching or root direction.
        if (result.chain.len == 1) {
            result.caption_class_guard = result.chain[0].classes;
            result.caption_class_guard_requires_complete = result.caption_class_guard.len != 0;
        }
        const chain_classes = try self.figureNecessaryChainClasses(raw);
        if (chain_classes.len != 0) {
            result.caption_class_guard = chain_classes;
            result.caption_class_guard_requires_complete = true;
        }
        if (try self.figureBeforeRequiredOwnAttribute(raw)) |name| result.required_own_attribute = name;
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
        const chain_classes: []const []const u8 = if (chain.items.len > 1 and uncertain)
            try self.figureNecessaryChainClasses(raw) else &.{};
        return .{ .chain = chain.items, .specificity = if (uncertain) std.math.maxInt(u64) else specificity, .uncertain = uncertain or chain.items.len == 0, .direct_children = has_child, .root_predicate_unresolved = try self.contentRootPredicateUnresolved(raw, false), .root_subject_excluded = chain.items.len > 1,
            .caption_class_guard = if (language_guard) |value| value.classes else if (chain.items.len == 1 and uncertain) chain.items[0].classes else chain_classes,
            .caption_class_guard_requires_complete = language_guard == null and ((chain.items.len == 1 and uncertain and chain.items[0].classes.len != 0) or chain_classes.len != 0),
            .caption_subject_tag = try self.figureSubjectTag(raw),
            .required_own_attribute = try self.figureBeforeRequiredOwnAttribute(raw) };
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
        var missing_link_custom = false;
        while (try nextDeclarationAlloc(self.a, css, &declaration_pos)) |raw| {
            if (trim(raw).len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse { relevant = true; continue; };
            const name = trim(raw[0..colon]);
            if (missingLinkCustomProperty(name) or (std.mem.startsWith(u8, name, "--") and !customName(name))) missing_link_custom = true;
            if (!customName(name)) relevant = true;
        }
        if (!relevant and !missing_link_custom) return;
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
            const rule: TextRule = .{ .selector = selected, .css = css, .order = order, .figure_root_alignment_only = root_alignment_only, .figure_language_baseline_only = language_baseline_only };
            if (relevant) {
                if (self.figure_rules.items.len == max_rules) return error.StyleProfileLimit;
                try self.figure_rules.append(self.a, rule);
            }
            if (missing_link_custom) {
                if (self.missing_link_custom_rules.items.len == max_rules) return error.StyleProfileLimit;
                try self.missing_link_custom_rules.append(self.a, rule);
            }
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
        if (start != 0) {
            // Reuse the refusal-only parser shared by text paint. It refuses
            // sibling, escaped, negated and alternative-class assumptions.
            if (try self.uncertainPaintSelector(text)) |necessary|
                result.necessary_ancestor_classes = necessary.necessary_classes;
        }
        return result;
    }

    // Parse every compound strictly before retaining even this one necessary
    // edge. Functions, negation, attributes, sibling relations and escapes keep
    // the old uncertainty, rather than guessing a suffix through them.
    fn displayRequiredParentTag(self: *Builder, raw: []const u8) !?[]const u8 {
        const text = trim(raw);
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or
            std.mem.indexOfAny(u8, text, "+~|\\/[:()&\x00") != null) return null;
        var pos: usize = 0;
        var previous_tag: ?[]const u8 = null;
        var edge_child = false;
        var required: ?[]const u8 = null;
        var count: usize = 0;
        while (pos < text.len) {
            const start = pos;
            while (pos < text.len and text[pos] != '>' and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) == null) : (pos += 1) {}
            if (pos == start) return null;
            const compound = (try self.paintCompound(text[start..pos], true)) orelse return null;
            required = if (count != 0 and edge_child) previous_tag else null;
            previous_tag = compound.tag;
            count += 1;
            while (pos < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) != null) : (pos += 1) {}
            if (pos == text.len) break;
            edge_child = text[pos] == '>';
            if (edge_child) {
                pos += 1;
                while (pos < text.len and std.mem.indexOfScalar(u8, " \t\r\n\x0c", text[pos]) != null) : (pos += 1) {}
                if (pos == text.len) return null;
            }
        }
        return if (required) |tag| try self.a.dupe(u8, tag) else null;
    }

    fn appendDisplayRules(self: *Builder, prelude: []const u8, css: []const u8, conditional: bool, order: u32) !void {
        var selectors: std.ArrayList(DisplaySelector) = .empty;
        var parts: SelectorList = .{ .source = prelude };
        var uncertain = false;
        while (try parts.nextAlloc(self.a)) |raw| {
            if (self.display_rules.items.len + selectors.items.len == max_rules) return error.StyleProfileLimit;
            var selector_value = try self.displaySelector(raw, conditional);
            selector_value.required_parent_tag = try self.displayRequiredParentTag(raw);
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
            .own_tag = last.tag,
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
                if (readingMediaApplies(self.reading_target, prelude)) |applies| {
                    if (applies) try self.parse(css[body_start..end], conditional, depth + 1, seed);
                    continue;
                }
                self.unsupported = true;
                // Counter descriptors define marker strings, not element
                // declarations. Keep their unsupported status without erasing
                // unrelated table paint or interpreting the body as selectors.
                if (atRuleNamed(prelude, "counter-style")) continue;
                // Definitions alone have no element-selector cascade. Matching
                // animation declarations remain in the ordinary rule inventories.
                if (keyframesDefinition(prelude, css[body_start..end])) continue;
                // Conditional groups may contain matching overrides; mark every
                // projected declaration unknown instead of guessing the condition.
                if (isConditionalGroup(prelude)) {
                    const previous_viewport = self.container_viewport;
                    const previous_rank_unknown = self.container_rank_unknown;
                    const previous_conditions = self.container_conditions;
                    if (!seed) {
                        const conditions = try self.a.alloc([]const u8, previous_conditions.len + 1);
                        @memcpy(conditions[0..previous_conditions.len], previous_conditions);
                        conditions[previous_conditions.len] = try self.a.dupe(u8, prelude);
                        self.container_conditions = conditions;
                    }
                    self.container_viewport = if (self.reading_target == .print) .unknown else containerViewportGroup(prelude, previous_viewport);
                    self.container_rank_unknown = previous_rank_unknown or atRuleNamed(prelude, "layer");
                    defer {
                        self.container_viewport = previous_viewport;
                        self.container_rank_unknown = previous_rank_unknown;
                        self.container_conditions = previous_conditions;
                    }
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
            try self.appendContainerRules(prelude, try self.a.dupe(u8, css[body_start..end]), display_order,
                self.container_source_byte_start + (@intFromPtr(css.ptr) - @intFromPtr(self.container_source.ptr)) + body_start);
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
    return parseForTargetAlloc(a, css, .unknown);
}

pub fn parseForTargetAlloc(a: std.mem.Allocator, css: []const u8, target: ReadingTarget) !Profile {
    return parseSourcesForTargetAlloc(a, &.{.{ .css = css, .base_url = "" }}, target);
}

// Parse every sheet/segment independently while preserving global declaration
// order and every repeated occurrence. Relative URL bases remain attached to
// their source; this profile admits no URL-valued presentation property.
pub fn parseSourcesAlloc(a: std.mem.Allocator, sources: []const Source) !Profile {
    return parseSourcesForTargetAlloc(a, sources, .unknown);
}

pub fn parseSourcesForTargetAlloc(a: std.mem.Allocator, sources: []const Source, target: ReadingTarget) !Profile {
    var total: usize = 0;
    for (sources) |source| {
        total = std.math.add(usize, total, source.css.len) catch return error.StyleProfileLimit;
        if (total > max_css_bytes or source.base_url.len > 4096) return error.StyleProfileLimit;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const pa = arena.allocator();
    const retained_sources = try pa.alloc(Source, sources.len);
    for (sources, retained_sources) |source, *retained| retained.* = .{
        .css = try pa.dupe(u8, source.css), .base_url = try pa.dupe(u8, source.base_url), .byte_start = source.byte_start,
    };
    var builder: Builder = .{ .a = pa, .reading_target = target };
    for (sources) |source| try builder.parse(source.css, false, 0, true);
    var ranges: std.ArrayList(SourceRange) = .empty;
    for (sources, 0..) |source, source_index| {
        builder.container_source = source.css;
        builder.container_source_index = source_index;
        builder.container_source_byte_start = source.byte_start;
        const first = builder.number + 1;
        try builder.parse(source.css, false, 0, false);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source.css, &digest, .{});
        try ranges.append(builder.a, .{ .base_url = try builder.a.dupe(u8, source.base_url),
            .byte_start = source.byte_start, .bytes = source.css.len, .css_sha256 = std.fmt.bytesToHex(digest, .lower),
            .rule_begin = first, .rule_end = builder.number + 1 });
    }
    return .{ .arena = arena, .reading_target = target, .sources = ranges.items, .retained_sources = retained_sources, .rules = builder.rules.items, .classes = builder.classes.items, .ancestor_classes = builder.ancestor_classes.items, .admitted_rule_numbers = builder.numbers.items, .has_unsupported_rules = builder.unsupported, .globally_unresolved = builder.globally_unresolved, .text_rules = builder.text_rules.items, .block_rules = builder.block_rules.items, .container_rules = builder.container_rules.items, .figure_rules = builder.figure_rules.items, .missing_link_custom_rules = builder.missing_link_custom_rules.items, .display_rules = builder.display_rules.items, .display_classes = builder.display_classes.items };
}

// Reparse the original ordered inputs through the same parser so class indices,
// declaration order and every query inventory share one consistent namespace.
// The caller still has to issue the exact page/root capability separately.
pub fn joinPageSourcesAlloc(a: std.mem.Allocator, parent: *const Profile, emitted: []const Source, authored: []const Source) !Profile {
    if (parent.reading_target != .screen or parent.page_style_parent != null or
        parent.retained_sources.len != parent.sources.len) return error.InvalidStyleProfile;
    const sources = try a.alloc(Source, emitted.len + parent.retained_sources.len + authored.len);
    defer a.free(sources);
    @memcpy(sources[0..emitted.len], emitted);
    const global_end = emitted.len + parent.retained_sources.len;
    @memcpy(sources[emitted.len..global_end], parent.retained_sources);
    @memcpy(sources[global_end..], authored);
    var result = try parseSourcesForTargetAlloc(a, sources, .screen);
    result.page_style_parent = parent;
    return result;
}

// Only whole bare media types are evaluated. Features, lists, modifiers,
// escapes and comments inside the prelude retain the existing unknown path.
fn readingMediaApplies(target: ReadingTarget, prelude: []const u8) ?bool {
    if (target == .unknown or !atRuleNamed(prelude, "media")) return null;
    const end = identifierEnd(prelude, 1);
    if (end == prelude.len or !std.ascii.isWhitespace(prelude[end])) return null;
    const medium = trim(prelude[end..]);
    if (std.ascii.eqlIgnoreCase(medium, "all")) return true;
    if (std.ascii.eqlIgnoreCase(medium, "screen")) return target == .screen;
    if (std.ascii.eqlIgnoreCase(medium, "print")) return target == .print;
    return null;
}

fn atRuleNamed(prelude: []const u8, name: []const u8) bool {
    if (prelude.len == 0 or prelude[0] != '@') return false;
    const end = identifierEnd(prelude, 1);
    // Escaped identifiers need tokenization; decline them conservatively.
    if (end < prelude.len and (prelude[end] == '\\' or prelude[end] >= 0x80)) return false;
    return std.ascii.eqlIgnoreCase(prelude[1..end], name);
}

// Keyframe definitions describe animation steps, not element selector rules.
// Admit only a bounded explicit grammar; unsupported syntax keeps the existing
// global uncertainty. Applying an animation remains an ordinary declaration.
fn keyframeIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    var start: usize = 0;
    if (text[0] == '-') {
        if (text.len == 1) return false;
        start = 1;
    }
    if (!std.ascii.isAlphabetic(text[start]) and text[start] != '_' and text[start] != '-') return false;
    for (text[start + 1 ..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}
fn keyframeOffsets(text: []const u8) bool {
    var offsets = std.mem.splitScalar(u8, text, ',');
    while (offsets.next()) |raw| {
        const value = trim(raw);
        if (std.ascii.eqlIgnoreCase(value, "from") or std.ascii.eqlIgnoreCase(value, "to")) continue;
        if (value.len < 2 or value[value.len - 1] != '%') return false;
        const number = value[0 .. value.len - 1];
        if (!widthNumberSyntax(number)) return false;
        const percent = std.fmt.parseFloat(f64, number) catch return false;
        if (!std.math.isFinite(percent) or percent < 0 or percent > 100) return false;
    }
    return true;
}
fn keyframeDeclarations(css: []const u8) bool {
    var at: usize = 0;
    var start: ?usize = null;
    var colon: ?usize = null;
    var has_value = false;
    var quote: u8 = 0;
    var groups: [32]u8 = undefined;
    var depth: usize = 0;
    while (at < css.len) : (at += 1) {
        const byte = css[at];
        // Escaped identifiers/strings need a wider tokenizer than this proof.
        if (byte == '\\' or byte == 0) return false;
        if (quote != 0) {
            if (byte == '\r' or byte == '\n' or byte == 0x0c) return false;
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '/' and at + 1 < css.len and css[at + 1] == '*') {
            const end = std.mem.indexOfPos(u8, css, at + 2, "*/") orelse return false;
            at = end + 1;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) continue;
        if (byte == ';' and depth == 0) {
            if (start != null and (colon == null or !has_value)) return false;
            start = null; colon = null; has_value = false;
            continue;
        }
        if (start == null) start = at;
        // No nested rules, at-rules, or block-valued custom properties borrow
        // this declaration-only definition proof.
        if (byte == '{' or byte == '}' or byte == '@') return false;
        if (colon == null) {
            if (byte == ':') {
                if (!keyframeIdentifier(trim(css[start.?..at]))) return false;
                colon = at;
            } else if (byte == '(' or byte == ')' or byte == '[' or byte == ']' or byte == '\'' or byte == '"') return false;
            continue;
        }
        has_value = true;
        if (byte == '\'' or byte == '"') { quote = byte; continue; }
        if (byte == '(' or byte == '[') {
            if (depth == groups.len) return false;
            groups[depth] = byte; depth += 1;
        } else if (byte == ')' or byte == ']') {
            if (depth == 0 or groups[depth - 1] != (if (byte == ')') @as(u8, '(') else @as(u8, '['))) return false;
            depth -= 1;
        }
    }
    return quote == 0 and depth == 0 and (start == null or (colon != null and has_value));
}
fn keyframesDefinition(prelude: []const u8, body: []const u8) bool {
    if (!atRuleNamed(prelude, "keyframes")) return false;
    const end = identifierEnd(prelude, 1);
    if (end == prelude.len or !std.ascii.isWhitespace(prelude[end])) return false;
    const name = trim(prelude[end..]);
    if (!keyframeIdentifier(name)) return false;
    for ([_][]const u8{ "none", "initial", "inherit", "unset", "revert", "revert-layer", "default" }) |reserved|
        if (std.ascii.eqlIgnoreCase(name, reserved)) return false;
    var pos: usize = 0;
    var frames: usize = 0;
    while (true) {
        skipSpaceComments(body, &pos) catch return false;
        if (pos == body.len) return true;
        const start = pos;
        const boundary = findBoundary(body, &pos) catch return false;
        if (boundary != '{' or !keyframeOffsets(body[start .. pos - 1])) return false;
        const content = pos;
        const close = closingBrace(body, &pos) catch return false;
        if (!keyframeDeclarations(body[content..close])) return false;
        frames += 1;
        if (frames > max_rules) return false;
    }
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
fn tableFlowFloatConflict(style: *types.TableStyle) bool {
    // This first external-top capability has a real inline line-box owner.
    // An ordinary block table must not inherit a cell top projection.
    if (style.vertical_align) |alignment| if (alignment == .top and !types.tableStyleIsInline(style.*)) {
        style.vertical_align = null;
        return true;
    };
    if (style.display) |display| if (display != .table and style.float_side != null) {
        style.display = null;
        style.vertical_align = null;
        return true;
    };
    return false;
}
fn selectedLineHeight(winners: Winners) ?f32 {
    const value = winners.value(.line_height) orelse return null;
    return if (value == .line_height_em) value.line_height_em else null;
}
fn projectTableBox(style: *types.TableStyle, winners: Winners) void {
    if (winners.value(.display)) |value| if (value == .display_value) { style.display = value.display_value; };
    if (winners.value(.vertical_align)) |value| switch (value) {
        .vertical_align_value => |alignment| style.vertical_align = alignment,
        .cell_vertical_align_value => |alignment| switch (alignment) { .top => style.vertical_align = .top },
        else => {},
    };
    if (!unresolvedTableWidthBox(winners)) if (winners.value(.width)) |value| if (value == .width_value) { style.width = value.width_value; };
    const collapse = winners.value(.collapse);
    if (collapse) |value| if (value == .collapse) { style.collapse = value.collapse; };
    // Without a proved border model, applying table padding would invent an
    // outer gap: collapsed tables do not apply table-box padding.
    if (collapse == null or collapse.? == .collapse)
        if (winners.value(.padding)) |value| if (value == .edges) { style.padding = value.edges; };
    if (winners.value(.clear)) |value| if (value == .clear_value) { style.clear = value.clear_value; };
}

fn selectedCellMinimumWidth(winners: Winners) ?types.StyleLength {
    // Only the ordinary content-box cell domain is represented. An explicit
    // box-sizing candidate stays unresolved rather than changing this floor.
    if (winners.value(.box_sizing) != null) return null;
    const value = winners.value(.min_width) orelse return null;
    return if (value == .length_value) value.length_value else null;
}

fn representedDeclaration(target: Target, declaration: Declaration) bool {
    // Table transparency reveals the enclosing paint owner. Cells currently
    // flatten row paint into their own background, so do not silently grant
    // a transparent cell reset through that different fallback contract.
    if (declaration.value == .no_background and target != .table) return false;
    // A known top value for a table cell must not silently resolve an external
    // table/inline box alignment. Their layout policies are distinct.
    if (declaration.property == .vertical_align) {
        if (target == .td or target == .th or target == .cell) return declaration.value == .cell_vertical_align_value;
        if (declaration.value == .cell_vertical_align_value) return target == .table;
    }
    return representedProperty(target, declaration.property);
}
fn representedProperty(target: Target, property: Property) bool {
    return switch (property) {
        .background, .border, .text_color, .other, .layout_reset => true,
        .collapse, .margins, .margin_top, .margin_right, .margin_bottom, .margin_left, .float_side, .clear, .box_sizing => target == .table,
        .width => target == .table or target == .td or target == .th or target == .cell,
        .display, .vertical_align, .line_height, .list_style => target == .table,
        .font_size => target == .table or target == .td or target == .th or target == .cell,
        .min_width => target == .td or target == .th or target == .cell,
        .padding => true,
        // Table alignment is projected separately into inherited cell styles.
        // Dynamic values and uncertain selectors still cascade as unsupported.
        .text_align => true,
    };
}

fn propertyFor(name: []const u8) ?Property {
    // This misspelling is not a CSS property. It is never an alias for the
    // distinct supported vertical-align declaration or HTML valign hint.
    if (std.ascii.eqlIgnoreCase(name, "text-valign")) return null;
    if (std.ascii.eqlIgnoreCase(name, "color")) return .text_color;
    if (std.ascii.eqlIgnoreCase(name, "display")) return .display;
    if (std.ascii.eqlIgnoreCase(name, "vertical-align")) return .vertical_align;
    if (std.ascii.eqlIgnoreCase(name, "line-height")) return .line_height;
    if (std.ascii.eqlIgnoreCase(name, "list-style") or std.ascii.eqlIgnoreCase(name, "list-style-type")) return .list_style;
    if (std.ascii.eqlIgnoreCase(name, "font-size")) return .font_size;
    if (std.ascii.eqlIgnoreCase(name, "background") or std.ascii.eqlIgnoreCase(name, "background-color") or std.ascii.eqlIgnoreCase(name, "background-image")) return .background;
    if (std.ascii.eqlIgnoreCase(name, "border-collapse")) return .collapse;
    // Cell separation does not override any physical border component.
    // Keep its independent refusal while retaining known border winners.
    if (std.ascii.eqlIgnoreCase(name, "border-spacing")) return .other;
    if (std.ascii.eqlIgnoreCase(name, "border") or std.ascii.startsWithIgnoreCase(name, "border-")) return .border;
    if (std.ascii.eqlIgnoreCase(name, "margin")) return .margins;
    inline for (.{ "margin-top", "margin-right", "margin-bottom", "margin-left" }, .{ Property.margin_top, .margin_right, .margin_bottom, .margin_left }) |edge, property| if (std.ascii.eqlIgnoreCase(name, edge)) return property;
    if (std.ascii.startsWithIgnoreCase(name, "margin-")) return .margins;
    if (std.ascii.eqlIgnoreCase(name, "float")) return .float_side;
    if (std.ascii.eqlIgnoreCase(name, "width")) return .width;
    if (std.ascii.eqlIgnoreCase(name, "min-width")) return .min_width;
    if (std.ascii.eqlIgnoreCase(name, "clear")) return .clear;
    if (std.ascii.eqlIgnoreCase(name, "box-sizing")) return .box_sizing;
    if (std.ascii.eqlIgnoreCase(name, "all")) return .layout_reset;
    if (std.ascii.eqlIgnoreCase(name, "padding") or std.ascii.startsWithIgnoreCase(name, "padding-")) return .padding;
    if (std.ascii.eqlIgnoreCase(name, "text-align")) return .text_align;
    // These affect table/cell presentation but have no projection in this ABI.
    inline for (.{ "height", "max-width", "min-height", "max-height", "display", "visibility", "position", "color", "font", "font-size", "font-family", "font-weight", "vertical-align", "table-layout", "border-spacing", "opacity", "transform", "all" }) |relevant| if (std.ascii.eqlIgnoreCase(name, relevant)) return .other;
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
    var tokens: [4][]const u8 = undefined;
    const count = borderTokens(value, &tokens) orelse return null;
    var width: ?types.StyleLength = null;
    var color: ?[]const u8 = null;
    var solid = false;
    for (tokens[0..count]) |token| {
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
            // The complete shorthand clears both image and color. A known
            // transparent reset is distinct from omission and unsupported paint;
            // background-color:none is not this CSS shorthand.
            if (std.ascii.eqlIgnoreCase(name, "background") and std.ascii.eqlIgnoreCase(value, "none")) {
                projection = .no_background;
            } else if (!std.ascii.eqlIgnoreCase(name, "background-image")) {
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
        .min_width => {
            // Reuse the strict CSS number grammar, excluding percentage widths.
            if (styleWidth(value)) |next| {
                if (next.unit == .px or next.unit == .em) projection = .{ .length_value = .{ .unit = if (next.unit == .px) .px else .em, .value = next.value } };
            } else if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) {
                projection = .{ .length_value = .{ .unit = .px, .value = 0 } };
            } else if (!std.ascii.eqlIgnoreCase(value, "auto") and !unsupportedWidth(value)) return null;
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
        .display => {
            inline for (.{ "table", "inline-block", "inline-table" }, .{ types.TableDisplay.table, .inline_block, .inline_table }) |name_value, display| {
                if (std.ascii.eqlIgnoreCase(value, name_value)) projection = .{ .display_value = display };
            }
        },
        .vertical_align => {
            if (std.ascii.eqlIgnoreCase(value, "baseline")) projection = .{ .vertical_align_value = .baseline }
            else if (std.ascii.eqlIgnoreCase(value, "middle")) projection = .{ .vertical_align_value = .middle }
            else if (std.ascii.eqlIgnoreCase(value, "top")) projection = .{ .cell_vertical_align_value = .top };
        },
        .line_height => {
            if (length(value)) |selected| {
                if (selected.unit == .em and selected.value > 0) projection = .{ .line_height_em = selected.value };
            }
        },
        .list_style => {
            // The typed TABLE display domain cannot generate a list-item marker.
            // Unknown display/all overrides still retain their own unresolved slot.
            if (std.ascii.eqlIgnoreCase(value, "none")) projection = .list_style_none;
        },
        .font_size => {
            if (fontSizeValue(name, value)) |selected| {
                if (selected != .unknown) projection = .font_size_consumed;
            }
        },
        .text_color, .other => {},
    }
    const variable_paint = projection == .unsupported and
        ((property == .background and !std.ascii.eqlIgnoreCase(name, "background-image") and std.mem.startsWith(u8, value, "var(")) or
        (property == .border and std.ascii.eqlIgnoreCase(name, "border") and std.mem.indexOf(u8, value, "var(") != null));
    return .{ .border_update = if (property == .border) try borderUpdateAlloc(a, name, value, null) else null,
        .border_raw = if (property == .border and std.mem.indexOf(u8, value, "var(") != null) .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) } else null,
        .property = property, .value = projection, .custom_paint = if (variable_paint) try a.dupe(u8, value) else null, .important = important, .order = order, .affects_font_basis = std.ascii.eqlIgnoreCase(name, "font") or std.ascii.eqlIgnoreCase(name, "font-size") or std.ascii.eqlIgnoreCase(name, "all"), .may_name_min_width = std.mem.indexOfScalar(u8, name, '\\') != null };
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
    // Keep the ordinary allocator path and every semantic assertion exercised.
    try Case.run(std.testing.allocator, css.items, compound);
    // Arena growth may succeed in place depending on SafeAllocator bucket state.
    // The exhaustive failure checker counts allocations, not resize/remap calls;
    // consistently refuse both growth mechanisms so each run has the same count.
    var fixed_growth_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(fixed_growth_backing.allocator(), Case.run, .{ css.items, compound });
    try std.testing.expectEqual(fixed_growth_backing.allocated_bytes, fixed_growth_backing.freed_bytes);
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
pub fn missingLinkCustomProperty(name: []const u8) bool {
    for ([_][]const u8{
        "--color-destructive", "--color-destructive--hover", "--color-destructive--active",
        "--color-destructive--visited", "--color-destructive--visited--hover", "--color-destructive--visited--active",
        "--outline-color-progressive--focus",
    }) |used| if (std.mem.eql(u8, name, used)) return true;
    return false;
}
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
fn sameObservedCustomValue(left: CustomValue, right: CustomValue) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) { .known => |value| std.mem.eql(u8, value, right.known), .invalid, .unknown => true };
}
pub fn intersectCustomEnvironmentsAlloc(a: std.mem.Allocator, left: CustomEnvironment, right: CustomEnvironment) !CustomEnvironment {
    var values: std.ArrayList(CustomBinding) = .empty;
    const complete = left.complete and right.complete;
    for (left.values) |entry| try values.append(a, .{ .name = entry.name,
        .value = if (complete and sameObservedCustomValue(entry.value, right.get(entry.name))) entry.value else .unknown });
    for (right.values) |entry| {
        var found = false;
        for (left.values) |old| if (std.mem.eql(u8, old.name, entry.name)) { found = true; break; };
        if (!found) try values.append(a, .{ .name = entry.name,
            .value = if (complete and sameObservedCustomValue(entry.value, left.get(entry.name))) entry.value else .unknown });
    }
    return .{ .values = try values.toOwnedSlice(a), .complete = complete };
}
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
    // This existing observed environment is screen-bound. A print profile must
    // not borrow its independently supplied theme and ancestor observations.
    if (profile.reading_target == .print) return error.InvalidStyleProfile;
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
    if (profile.page_style_parent != null and element.page_style_root == null) return .{ .unresolved = true };
    var winners: FigureWinners = .{};
    for (profile.figure_rules) |rule| {
        if (rule.selector.required_own_attribute) |name| if (element.attribute_presence) |attributes| {
            if (attributes.get(attributes.ctx, name) == .absent) continue;
        };
        const matched = rule.selector.matchIn(element, profile.page_style_parent != null);
        if (matched == .unknown) return .{ .unresolved = true };
        if (matched == .known) {
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
    const Use = Profile.FigureRootDirectionUse;
    const cases = .{
        .{ "ol ol:lang(vi){list-style-type:lower-vietnamese}", Use.unresolved },
        // Tag-constrained negations cannot select the inserted DIV. The bare
        // attribute presence has equal truth for both direction alternatives;
        // this proves neither absence nor an actual selector match.
        .{ ".infobox th:not(.noplainlist) > ul,.infobox td:not(.noplainlist) > ul,.infobox [data-wikidata-property-id] > ul{list-style-type:none;list-style-image:none;margin:0}", Use.independent },
    };
    inline for (cases) |case| {
        const css = case[0];
        var profile = try parseAlloc(a, css); defer profile.deinit();
        std.testing.expectEqual(case[1], profile.figureRootDirectionUse(null)) catch |failure| { std.debug.print("caption domain root case: {s}\n", .{css}); return failure; };
        try std.testing.expectEqual(case[1], profile.figureRootDirectionUseWithCaptionClasses(null, ""));
        try std.testing.expectEqual(Use.independent, profile.figureRootDirectionUseWithCaptionDomain(null, "", tags));
        try std.testing.expectEqual(case[1], profile.figureRootDirectionUseWithCaptionDomain(null, "", &.{ "ol", "ul" }));
        if (case[1] == .independent) {
            const root: TextElement = .{ .tag = "div", .classes = "infobox mw-parser-output", .ancestry_complete = true };
            const cell: TextElement = .{ .tag = "td", .parent = &root, .page_style_root = &root };
            const list: TextElement = .{ .tag = "ul", .parent = &cell, .page_style_root = &root };
            var unknown_matches: usize = 0;
            for (profile.figure_rules) |rule| if (rule.selector.matchIn(&list, true) == .unknown) { unknown_matches += 1; };
            try std.testing.expect(unknown_matches != 0);
            try std.testing.expect((try profile.resolveFigure(a, &list, 1, false)).unresolved);
        }
    }
    var value_predicate = try parseAlloc(a, "body [class~=mw-content-rtl] ul{margin:0}"); defer value_predicate.deinit();
    try std.testing.expectEqual(Use.unresolved, value_predicate.figureRootDirectionUseWithCaptionDomain(null, "", &.{ "ol", "ul" }));
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
        std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUseWithCaptionDomain(null, "", tags)) catch |failure| {
            std.debug.print("caption domain strict case: {s}\n", .{css}); return failure;
        };
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

test "table alignment is represented through cell inheritance while unresolved cascades remain strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var empty = try parseAlloc(a, ""); defer empty.deinit();
    for ([_][]const u8{ "left", "center", "right" }, [_]types.CellTextAlign{ .left, .center, .right }) |value, expected| {
        const css = try std.fmt.allocPrint(a, "text-align:{s}", .{value});
        const box = try empty.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "" }, null, css);
        try std.testing.expect(!box.unresolved and box.style == null);
        const alignment = try empty.resolveAlignment(a, "table", "", "", null, css);
        try std.testing.expect(alignment.specified and !alignment.unresolved);
        try std.testing.expectEqual(@as(?types.CellTextAlign, expected), alignment.value);
    }
    var known = try parseAlloc(a, "table.center{text-align:center}"); defer known.deinit();
    try std.testing.expect(!(try known.resolveTableWithContext(a, 0, "center", .{ .ancestor_classes = "", .own_id = "" }, null, "")).unresolved);
    try std.testing.expectEqual(@as(?types.CellTextAlign, .center), (try known.resolveAlignment(a, "table", "center", "", null, "")).value);
    for ([_][]const u8{ "text-align:var(--alignment)", "text-align:inherit", "text-align:justify", "all:unset" }) |css| {
        const box = try known.resolveTableWithContext(a, 0, "center", .{ .ancestor_classes = "", .own_id = "" }, null, css);
        try std.testing.expect(box.unresolved);
        const alignment = try known.resolveAlignment(a, "table", "center", "", null, css);
        try std.testing.expect(alignment.specified and alignment.unresolved and alignment.value == null);
    }
    var conditional = try parseAlloc(a, "table.center{text-align:center}@media print{table.center{text-align:right}}"); defer conditional.deinit();
    const unknown = try conditional.resolveTableWithContext(a, 0, "center", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    try std.testing.expect(unknown.unresolved);
    const uncertain_alignment = try conditional.resolveAlignment(a, "table", "center", "", null, "");
    try std.testing.expect(uncertain_alignment.specified and uncertain_alignment.unresolved and uncertain_alignment.value == null);
}

test "relative child predicates exclude only the attested ParserOutput root and keep matching uncertain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    for ([_][]const u8{
        "li:has(> span.senseid:target){color:red}",
        "p:has(> span.etymid:target){color:red}",
        "tr:has(> :target){color:red}",
        "tr:has(> td > code:target){color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
        try std.testing.expect(profile.contentParentEffectsUnchanged(null, &root));
        try std.testing.expect(!(try profile.resolveFigure(a, &frame, 1, false)).unresolved);
        try std.testing.expectEqual(@as(usize, 1), profile.figure_rules.len);
        try std.testing.expect(profile.figure_rules[0].selector.uncertain);
        const tag = profile.figure_rules[0].selector.chain[0].tag orelse return error.TestUnexpectedResult;
        const actual_subject: TextElement = .{ .tag = tag, .parent = &root, .source_key = 1 };
        try std.testing.expect((try profile.resolveFigure(a, &actual_subject, 1, false)).unresolved);
        try std.testing.expect((try profile.resolveTextPaint(a, &actual_subject, "")).color.? == .unknown);
    }
}

test "relative child root proof retains unknown external root language and functional dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var builder: Builder = .{ .a = a };
    for ([_][]const u8{
        "", ">", ">>", ">span>", ">span + div", ">span ~ div", ">span, >div",
        ">span div", ">.mw-content-rtl", ">div", ">*", ">[id]:target",
        ">:not(:target)", ">:is(:target,.mw-parser-output)", ">:target-within",
        ">:target:target", ">span:lang(hsb)", ">span:dir(rtl)", ">span:unknown(x)",
        ">sp\\61n:target", ">span[title=':target']", ">:target >div",
    }) |argument| try std.testing.expect(!try builder.relativeChildrenExcludeContentRoot(argument));
    for ([_][]const u8{
        "body:has(> .mw-content-rtl){color:red}",
        "li:has(>span:lang(hsb)){color:red}",
        "tr:has(>:not(:target)){color:red}",
        "tr:has(>:is(:target,.mw-parser-output)){color:red}",
        "tr:has(>:target-within){color:red}",
        "tr:has(>:target:target){color:red}",
        "div:has(>:target){color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
    const css = "body:has(>.mw-content-rtl){--ink:red}";
    var custom = try parseAlloc(a, css);
    defer custom.deinit();
    try attachCustomProperties(&custom, &.{.{ .css = css, .base_url = "" }}, .{
        .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
    });
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, custom.figureRootDirectionUse(null));
}

test "functional-only simple negations preserve root direction invariance without matching authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output mw-content-ltr", .ancestry_complete = true };
    const frame: TextElement = .{ .tag = "figure", .parent = &root };
    for ([_][]const u8{
        "body.ns-0 .mw-parser-output > :not(.collapsible-block) + h2:not(:first-of-type){border-top:1px solid #a2a9b1;padding-top:1em;margin-top:0.2em}",
        "body.ns-0 .mw-parser-output > :not(.collapsible-block):not(.toc):not(.disambig-see-also):not(.character-info) + div.mw-heading2:not(:first-of-type){border-top:1px solid #a2a9b1;padding-top:1em;margin-top:0.2em}",
    }, 0..) |css, index| {
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
        try std.testing.expect(profile.contentParentEffectsUnchanged(null, &root));
        try std.testing.expect(!(try profile.resolveFigure(a, &frame, 1, false)).unresolved);
        try std.testing.expectEqual(@as(usize, 1), profile.figure_rules.len);
        try std.testing.expect(profile.figure_rules[0].selector.uncertain);
        const actual_subject: TextElement = .{ .tag = if (index == 0) "h2" else "div", .classes = if (index == 0) "" else "mw-heading2", .parent = &root, .source_key = 1 };
        try std.testing.expect((try profile.resolveFigure(a, &actual_subject, 1, false)).unresolved);
    }
}

test "functional-only negation proof retains directional inherited dynamic and custom uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var builder: Builder = .{ .a = a };
    for ([_][]const u8{ ":not(.collapsible-block)", ":not(.toc):not(.character-info)", ":not(#absent)", ":not(span)", ":NOT( .toc )" }) |part|
        try std.testing.expect(try builder.invariantRootNegationCompound(part));
    for ([_][]const u8{
        "", ":not()", ":not(.x", ":not(.x))", ":not(.x) garbage", ":not(.x) :not(.y)",
        ":not(.mw-content-rtl)", ":not(.mw-content-ltr)", ":not(.mw-content-rtl):not(.mw-content-ltr)",
        ":not(:lang(hsb))", ":not(:dir(rtl))", ":not(:unknown(x))", ":not(:is(.x,.y))",
        ":not(.x,.y)", ":not(.x > span)", ":not([dir=rtl])", ":not(.x\\31)", ":is(.x)",
    }) |part| try std.testing.expect(!try builder.invariantRootNegationCompound(part));
    for ([_][]const u8{
        "body :not(.mw-content-rtl) > h2{color:red}",
        "body :not(.mw-content-ltr) > h2{color:red}",
        "body :not(:lang(hsb)) > h2{color:red}",
        "body :not(:dir(rtl)) > h2{color:red}",
        "body :not(:unknown(x)) > h2{color:red}",
    }) |css| {
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, profile.figureRootDirectionUse(null));
    }
    const css = "body :not(.mw-content-rtl) > h2{--ink:red}";
    var custom = try parseAlloc(a, css);
    defer custom.deinit();
    try attachCustomProperties(&custom, &.{.{ .css = css, .base_url = "" }}, .{
        .dark = false, .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" } },
    });
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, custom.figureRootDirectionUse(null));
}

test "Figure before pseudo content requires observed own attribute absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Proof = struct {
        state: AttributePresence,
        fn get(raw: ?*const anyopaque, name: []const u8) AttributePresence {
            const proof: *const @This() = @ptrCast(@alignCast(raw orelse return .unknown));
            return if (std.ascii.eqlIgnoreCase(name, "rel")) proof.state else .unknown;
        }
    };
    var plain = try parseAlloc(a, ""); defer plain.deinit();
    for ([_][]const u8{ "a[ rel=\"mw:referencedBy\" ]::before", "a[REL]::before", "a[rel='other']::BEFORE", "figure > a[rel='']::before" }) |selector_text| {
        const css = try std.fmt.allocPrint(a, "{s}{{content:\" ^\"}}", .{selector_text});
        var profile = try parseAlloc(a, css); defer profile.deinit();
        const frame: TextElement = .{ .tag = "figure" };
        var anchor: TextElement = .{ .tag = "a", .parent = &frame };
        try std.testing.expect((try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
        for ([_]AttributePresence{ .unknown, .present, .absent }) |state| {
            const proof: Proof = .{ .state = state };
            anchor.attribute_presence = .{ .ctx = &proof, .get = Proof.get };
            const actual = try profile.resolveFigure(a, &anchor, 1, false);
            if (state == .absent) try std.testing.expectEqualDeep(try plain.resolveFigure(a, &anchor, 1, false), actual)
            else try std.testing.expect(actual.unresolved);
        }
        // An ancestor's complete inventory never supplies the child's proof.
        const proof: Proof = .{ .state = .absent };
        const parent: TextElement = .{ .tag = "figure", .attribute_presence = .{ .ctx = &proof, .get = Proof.get } };
        anchor = .{ .tag = "a", .parent = &parent };
        try std.testing.expect((try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
    }
}

test "Figure attribute absence does not bypass unsupported predicate grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Proof = struct {
        fn get(_: ?*const anyopaque, _: []const u8) AttributePresence { return .absent; }
    };
    const anchor: TextElement = .{ .tag = "a", .attribute_presence = .{ .ctx = null, .get = Proof.get } };
    for ([_][]const u8{
        "a:not([rel])::before", "a:is([rel])::before", "a:has([rel])::before",
        "[rel] a::before", "[rel] > a::before", "b + a[rel]::before", "b ~ a[rel]::before",
        "a[rel^='mw']::before", "a[rel='mw' i]::before", "a[rel][other]::before",
        "a[rel]:hover::before", "a[rel]::after", "a[rel] ::before", "a/*x*/[rel]::before",
        "a[rel='m\\77']::before", "a[rel]::before, a::before",
    }) |selector_text| {
        const css = try std.fmt.allocPrint(a, "{s}{{content:\" ^\"}}", .{selector_text});
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveFigure(a, &anchor, 1, false)).unresolved);
    }
}

test "complete ancestor IDs only refute necessary inherited font IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "#mw-revision-info{font-size:110%}");
    defer profile.deinit();
    const css = "margin-left:0.5em;margin-bottom:0.5em";
    const unknown = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "" }, null, css);
    try std.testing.expect(unknown.margin_basis_unresolved);
    const absent = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{} }, null, css);
    try std.testing.expect(!absent.margin_basis_unresolved);
    try std.testing.expectEqualDeep(unknown.style, absent.style);
    const unrelated = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{"authored"} }, null, css);
    try std.testing.expect(!unrelated.margin_basis_unresolved);
    const present = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{"mw-revision-info"} }, null, css);
    try std.testing.expect(present.margin_basis_unresolved);
    var ordinary = try parseAlloc(a, "div{font-size:110%}");
    defer ordinary.deinit();
    const non_id = try ordinary.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{} }, null, css);
    try std.testing.expect(non_id.margin_basis_unresolved);
    // This capability does not alter cell padding's existing conservative path.
    const cell = try profile.resolveCellWithContext(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{} }, false, null, "padding-left:0.5em");
    try std.testing.expect(cell.padding_basis_unresolved);
}

test "complete original ancestor tags refute only absent exact font subjects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const css = "margin-left:0.5em;margin-bottom:0.5em";
    var profile = try parseAlloc(a, "small{font-size:85%}#mw-revision-info{font-size:110%}");
    defer profile.deinit();
    const incomplete = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{} }, null, css);
    try std.testing.expect(incomplete.margin_basis_unresolved);
    const absent = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{}, .complete_font_ancestor_tags = &.{ "div", "table" } }, null, css);
    try std.testing.expect(!absent.margin_basis_unresolved);
    try std.testing.expectEqual(@as(f32, 0.5), absent.style.?.margins.?.left.value);
    for ([_][]const []const u8{ &.{ "div", "small", "table" }, &.{ "div", "SMALL", "table" } }) |tags| {
        const present = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{}, .complete_font_ancestor_tags = tags }, null, css);
        try std.testing.expect(present.margin_basis_unresolved);
    }
    const id_present = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{"mw-revision-info"}, .complete_font_ancestor_tags = &.{ "div", "table" } }, null, css);
    try std.testing.expect(id_present.margin_basis_unresolved);
}

test "complete ancestor tag absence retains unsupported universal and unproved cell font basis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "*{font-size:85%}", "small:hover{font-size:85%}", "@media print{small{font-size:85%}}", "div{font-size:85%}", "table{font-size:85%}" }) |css| {
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        const unresolved = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_ids = &.{}, .complete_font_ancestor_tags = &.{ "div", "table" } }, null, "margin-left:0.5em");
        try std.testing.expect(unresolved.margin_basis_unresolved);
    }
    var profile = try parseAlloc(a, "small{font-size:85%}");
    defer profile.deinit();
    const cell = try profile.resolveCellWithContext(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "", .complete_font_ancestor_tags = &.{"div"} }, false, null, "padding-left:0.5em");
    try std.testing.expect(cell.padding_basis_unresolved);
}


test "typed inline table CSS retains line height until computed font and flow consumers certify it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    const css = "vertical-align:middle;display:inline-block;list-style:none;line-height:1em;border-collapse:collapse;margin:0";
    const selected = try profile.resolveTableWithContext(a, 0, "audiotable", .{}, null, css);
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqual(types.TableDisplay.inline_block, selected.style.?.display.?);
    try std.testing.expectEqual(types.InlineBoxVerticalAlign.middle, selected.style.?.vertical_align.?);
    try std.testing.expectEqual(@as(?f32, 1), selected.line_height_em);
    try std.testing.expect(selected.style.?.line_height == null);
    const uncertified = try profile.resolveCellWithContext(a, 0, 0, "", .{}, false, null, "font-size:80%");
    try std.testing.expect(uncertified.unresolved);
    const certified = try profile.resolveCellWithContext(a, 0, 0, "", .{ .font_size_consumed = true }, false, null, "font-size:80%");
    try std.testing.expect(!certified.unresolved);
    for ([_][]const u8{ "display:list-item", "display:var(--box)", "vertical-align:top", "line-height:normal", "line-height:1px", "line-height:0em", "list-style:disc", "font-size:var(--font)", "all:inherit;display:inline-block" }) |unsupported| {
        const value = try profile.resolveTableWithContext(a, 0, "", .{ .font_size_consumed = true }, null, unsupported);
        try std.testing.expect(value.unresolved);
    }
    const floated = try profile.resolveTableWithContext(a, 0, "", .{}, null, "display:inline-block;float:left");
    try std.testing.expect(floated.unresolved);
    try std.testing.expectEqual(@as(?types.TableFloatSide, .left), floated.style.?.float_side);
    try std.testing.expect(floated.style.?.display == null);
    const cell_height = try profile.resolveCellWithContext(a, 0, 0, "", .{}, false, null, "line-height:1em");
    try std.testing.expect(cell_height.unresolved);
}

pub fn resolveInlineContainerAlloc(a: std.mem.Allocator, css: []const u8) std.mem.Allocator.Error!ContainerResolution {
    return resolveInlineContainerWithInheritanceAlloc(a, css, false);
}
pub fn resolveInlineContainerWithInheritanceAlloc(a: std.mem.Allocator, css: []const u8, border_collapse_consumed: bool) std.mem.Allocator.Error!ContainerResolution {
    if (css.len > max_css_bytes) return .{ .unresolved = true };
    return containerCascadeAt(a, &.{}, css, null, null, border_collapse_consumed);
}

test "recursive container cascade retains authored edges float and intrinsic width without inventing BFC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".box { margin-left:60px; padding:2px; width:fit-content; float:left } .box { margin-left:10px!important } .unrelated { width:var(--unknown) }");
    defer profile.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    const box: TextElement = .{ .tag = "div", .classes = "box", .parent = &root };
    const selected = try profile.resolveContainerIn(a, &box, "margin-left:80px;clear:both");
    try std.testing.expect(selected.specified and !selected.unresolved);
    try std.testing.expectEqual(types.TableFloatSide.left, selected.style.float_side.?);
    try std.testing.expectEqual(types.FigureClear.both, selected.style.clear.?);
    try std.testing.expect(selected.style.width.? == .fit_content);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 10 }, selected.style.margins.?.left);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 0 }, selected.style.margins.?.right);
    inline for (.{ "top", "right", "bottom", "left" }) |field|
        try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 2 }, @field(selected.style.padding.?, field));
    const cleared = try profile.resolveContainerIn(a, &box, "width:0;float:none;margin-left:4px!important");
    try std.testing.expect(!cleared.unresolved and cleared.style.float_side == null);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .px, .value = 0 }, cleared.style.width.?.length);
    try std.testing.expectEqual(@as(f32, 4), cleared.style.margins.?.left.value);
    const ordinary = try profile.resolveContainerIn(a, &root, "");
    try std.testing.expect(!ordinary.specified and !ordinary.unresolved);
    try std.testing.expectEqualDeep(types.ContainerStyle{}, ordinary.style);
    const fit = try resolveInlineContainerAlloc(a, "width:fit-content");
    try std.testing.expect(fit.style.width.? == .fit_content and fit.style.float_side == null);
}

test "recursive container CSS keeps matching uncertain geometry and unsupported formatting contexts unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    const box: TextElement = .{ .tag = "div", .classes = "box", .parent = &root };
    for ([_][]const u8{ ".box:hover{margin-left:1px}", "@media print{.box{width:20px}}", ".box{width:var(--box-width)}", ".box{all:inherit}", "@import 'unknown.css';" }) |css| {
        var profile = try parseAlloc(a, css);
        defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &box, "")).unresolved);
    }
    for ([_][]const u8{ "display:flex;flex-direction:column;margin-left:1px", "display:flow-root", "position:absolute", "overflow:hidden", "width:min-content", "width:calc(100% - 1px)", "padding-left:inherit", "margin-inline-start:1em", "border:1px double blue", "float:inline-start", "width:fit-content;line-height:var(--height)" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    const known = try resolveInlineContainerAlloc(a, "display:block;position:static;overflow:visible;box-sizing:content-box;width:48%;margin-left:2em");
    try std.testing.expect(!known.unresolved);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 48 }, known.style.width.?.length);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 2 }, known.style.margins.?.left);
}

test "recursive container context follows winning declarations but all reset retains unrepresented uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".box{display:flex;position:absolute;overflow:hidden;box-sizing:border-box}");
    defer profile.deinit();
    const box: TextElement = .{ .tag = "div", .classes = "box" };
    const inline_ordinary = "display:block;position:static;overflow:visible;box-sizing:content-box;width:fit-content";
    try std.testing.expect(!(try profile.resolveContainerIn(a, &box, inline_ordinary)).unresolved);
    var important = try parseAlloc(a, ".box{display:flex!important}");
    defer important.deinit();
    const important_flex = try important.resolveContainerIn(a, &box, inline_ordinary);
    try std.testing.expect(!important_flex.unresolved and important_flex.style.layout.? == .flex_row);
    try std.testing.expect(!(try important.resolveContainerIn(a, &box, "display:block!important")).unresolved);
    try std.testing.expect((try resolveInlineContainerAlloc(a, "overflow:hidden;overflow-x:visible")).unresolved);
    try std.testing.expect(!(try resolveInlineContainerAlloc(a, "overflow:hidden;overflow-x:visible;overflow-y:visible")).unresolved);
    const reset = try resolveInlineContainerAlloc(a, "all:initial;margin:0;padding:0;width:auto;float:none;clear:none;display:block;position:static;overflow:visible;box-sizing:content-box");
    try std.testing.expect(reset.unresolved);
}

test "container positional rules retain exact rendered first and second child subjects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const css = ".mw-parser-output .interproject-box{font-size:90%;width:250px;padding:4px;text-align:left;background:var(--wikt-palette-paleblue,#f9f9f9);border:var(--border-color-base,#aaa)1px solid;display:flex;flex-direction:row;align-items:center}" ++
        ".mw-parser-output .interproject-box>div:first-child{float:none!important;flex:none}" ++
        ".mw-parser-output .interproject-box>div:nth-child(2){margin-left:0.55em!important}" ++
        "body.skin-vector:not(.skin-vector-2022) .mw-parser-output .interproject-box .vector-hide{display:none}" ++
        "body.skin-vector:not(.skin-vector-2022) .mw-parser-output .interproject-box .vector-inline-block{display:inline-block;margin-left:0!important}" ++
        "@media screen and (max-width:719px){.mw-parser-output .interproject-box{box-sizing:border-box;line-height:1.5;width:100%;max-width:100%}}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const box: TextElement = .{ .tag = "div", .classes = "interproject-box", .parent = &root };
    const first: TextElement = .{ .tag = "div", .parent = &box, .element_index = 1 };
    const second: TextElement = .{ .tag = "div", .parent = &box, .element_index = 2 };
    const first_rules = try profile.containerRuleMatchesIn(a, &first);
    const second_rules = try profile.containerRuleMatchesIn(a, &second);
    try std.testing.expect(!first_rules.unresolved and !second_rules.unresolved);
    try std.testing.expectEqual(@as(usize, 1), first_rules.rules.len);
    try std.testing.expectEqual(@as(usize, 1), second_rules.rules.len);
    try std.testing.expectEqualStrings("float:none!important;flex:none", first_rules.rules[0].css);
    try std.testing.expectEqualStrings("margin-left:0.55em!important", second_rules.rules[0].css);
    try std.testing.expectEqual(ContainerSelectorMatch.known, first_rules.rules[0].match);
    try std.testing.expectEqual(ContainerSelectorMatch.known, second_rules.rules[0].match);
    try std.testing.expectEqual(@as(u64, (3 << 21) + 1), first_rules.rules[0].specificity);
    try std.testing.expectEqual(first_rules.rules[0].specificity, second_rules.rules[0].specificity);
    try std.testing.expect(first_rules.rules[0].order < second_rules.rules[0].order);
    try std.testing.expect(first_rules.rules[0].viewport == .all);
    const box_rules = try profile.containerRuleMatchesIn(a, &box);
    try std.testing.expectEqual(@as(usize, 2), box_rules.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.known, box_rules.rules[0].match);
    try std.testing.expect(box_rules.rules[0].viewport == .all);
    try std.testing.expectEqual(@as(u32, 719), box_rules.rules[1].viewport.screen_max_width_px);
    try std.testing.expectEqualStrings("box-sizing:border-box;line-height:1.5;width:100%;max-width:100%", box_rules.rules[1].css);
}

test "container child positions require actual ordinal and direct parent with complete ancestry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".root .card>div:first-child{padding:1px}.root .card>div:nth-child(2){margin:2px}"); defer profile.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "root", .ancestry_complete = true };
    const card: TextElement = .{ .tag = "div", .classes = "card", .parent = &root };
    var item: TextElement = .{ .tag = "div", .parent = &card };
    for ([_]?u32{ null, 0 }) |ordinal| {
        item.element_index = ordinal;
        const result = try profile.containerRuleMatchesIn(a, &item);
        try std.testing.expectEqual(@as(usize, 2), result.rules.len);
        for (result.rules) |rule| try std.testing.expectEqual(ContainerSelectorMatch.unknown, rule.match);
    }
    item.element_index = 3;
    try std.testing.expectEqual(@as(usize, 0), (try profile.containerRuleMatchesIn(a, &item)).rules.len);
    const wrapper: TextElement = .{ .tag = "div", .parent = &card };
    item = .{ .tag = "div", .parent = &wrapper, .element_index = 1 };
    try std.testing.expectEqual(@as(usize, 0), (try profile.containerRuleMatchesIn(a, &item)).rules.len);
    item = .{ .tag = "div", .element_index = 1 };
    const unknown = try profile.containerRuleMatchesIn(a, &item);
    try std.testing.expectEqual(@as(usize, 1), unknown.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, unknown.rules[0].match);
    item.ancestry_complete = true;
    try std.testing.expectEqual(@as(usize, 0), (try profile.containerRuleMatchesIn(a, &item)).rules.len);
}

test "container mixed child descendant matching backtracks without guessing outer ancestors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".a>.b .c{padding:3px}"); defer profile.deinit();
    var root: TextElement = .{ .tag = "div", .classes = "a", .ancestry_complete = true };
    const outer: TextElement = .{ .tag = "div", .classes = "b", .parent = &root };
    const middle: TextElement = .{ .tag = "div", .classes = "middle", .parent = &outer };
    const inner: TextElement = .{ .tag = "div", .classes = "b", .parent = &middle };
    const subject: TextElement = .{ .tag = "div", .classes = "c", .parent = &inner };
    const known = try profile.containerRuleMatchesIn(a, &subject);
    try std.testing.expectEqual(@as(usize, 1), known.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.known, known.rules[0].match);
    root.classes = "different";
    try std.testing.expectEqual(@as(usize, 0), (try profile.containerRuleMatchesIn(a, &subject)).rules.len);
    root.ancestry_complete = false;
    const unknown = try profile.containerRuleMatchesIn(a, &subject);
    try std.testing.expectEqual(@as(usize, 1), unknown.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, unknown.rules[0].match);
}

test "container complex nth syntax and selector lists retain uncertainty without widening old paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const parent: TextElement = .{ .tag = "div", .classes = "card", .ancestry_complete = true };
    var item: TextElement = .{ .tag = "div", .parent = &parent, .classes = "target", .element_index = 1 };
    for ([_][]const u8{ "odd", "even", "2n+1", "1 of .target", "-1", "0", "4294967296" }) |argument| {
        const css = try std.fmt.allocPrint(a, ".target:nth-child({s}){{padding:1px}}", .{argument});
        var profile = try parseAlloc(a, css); defer profile.deinit();
        const result = try profile.containerRuleMatchesIn(a, &item);
        try std.testing.expectEqual(@as(usize, 1), result.rules.len);
        try std.testing.expectEqual(ContainerSelectorMatch.unknown, result.rules[0].match);
        var different = item; different.classes = "other";
        try std.testing.expectEqual(@as(usize, 0), (try profile.containerRuleMatchesIn(a, &different)).rules.len);
    }
    var profile = try parseAlloc(a, ".card>div:first-child{font-style:italic;padding:1px}@media screen and (max-width:719px){.target{font-style:normal;padding:2px}}"); defer profile.deinit();
    const before = try profile.resolveTextPaint(a, &item, "");
    const priorities = try profile.containerRuleMatchesIn(a, &item);
    try std.testing.expectEqual(@as(usize, 2), priorities.rules.len);
    try std.testing.expect(priorities.rules[0].match == .known and priorities.rules[1].match == .known);
    try std.testing.expect(priorities.rules[0].specificity > priorities.rules[1].specificity);
    try std.testing.expect(priorities.rules[0].viewport == .all);
    try std.testing.expectEqual(@as(u32, 719), priorities.rules[1].viewport.screen_max_width_px);
    const old_box = try profile.resolveContainerIn(a, &item, "");
    // The stronger unconditional first-child rule wins padding in both states.
    try std.testing.expect(old_box.specified and !old_box.unresolved);
    try std.testing.expectEqual(types.StyleEdges.all(.{ .unit = .px, .value = 1 }), old_box.style.padding.?);
    try std.testing.expect(old_box.style.screen_max_width == null);
    item.element_index = null;
    try std.testing.expectEqualDeep(before, try profile.resolveTextPaint(a, &item, ""));
    try std.testing.expect((try profile.resolveContainerIn(a, &item, "")).unresolved);
    try std.testing.expect(before.font_style.? == .unknown);
    item.element_index = 1;
    var winning_conditional = try parseAlloc(a, ".card>div:first-child{font-style:italic;padding:1px}@media screen and (max-width:719px){.target{font-style:normal;padding:2px!important}}"); defer winning_conditional.deinit();
    // A genuinely winning conditional padding has no responsive field.
    try std.testing.expect((try winning_conditional.resolveContainerIn(a, &item, "")).unresolved);
    var list = try parseAlloc(a, ".card>div:first-child,div:nth-child(odd){padding:1px}"); defer list.deinit();
    item.element_index = 1;
    const rules = try list.containerRuleMatchesIn(a, &item);
    try std.testing.expectEqual(@as(usize, 2), rules.rules.len);
    for (rules.rules) |rule| try std.testing.expectEqual(ContainerSelectorMatch.unknown, rule.match);
}

test "container viewport conditions intersect nested bounds and preserve unknown groups and stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var profile = try parseAlloc(a, ".box{width:250px}@media screen and (max-width:719px){.box{width:100%}@media screen and (max-width:500px){.box{padding:2px}}.box{margin:3px}@supports(display:flex){.box{display:flex}}}.box{clear:both}"); defer profile.deinit();
    const result = try profile.containerRuleMatchesIn(a, &element);
    try std.testing.expectEqual(@as(usize, 6), result.rules.len);
    for (result.rules) |rule| try std.testing.expectEqual(ContainerSelectorMatch.known, rule.match);
    try std.testing.expect(result.rules[0].viewport == .all);
    try std.testing.expectEqual(@as(u32, 719), result.rules[1].viewport.screen_max_width_px);
    try std.testing.expectEqual(@as(u32, 500), result.rules[2].viewport.screen_max_width_px);
    try std.testing.expectEqual(@as(u32, 719), result.rules[3].viewport.screen_max_width_px);
    try std.testing.expect(result.rules[4].viewport == .unknown);
    try std.testing.expect(result.rules[5].viewport == .all);
    for (result.rules[1..], result.rules[0 .. result.rules.len - 1]) |later, earlier|
        try std.testing.expect(later.order > earlier.order);
    for ([_][]const u8{ "print", "screen", "screen and(max-width:719px)", "screen and (max-width:1em)",
        "screen and (max-width:719px),print", "screen and (max-width:719px) and (min-width:200px)",
        "screen and (max-width:4294967296px)", "screen and (max-width:0px)" }) |condition| {
        var unknown = try parseAlloc(a, try std.fmt.allocPrint(a, "@media {s}{{.box{{width:1px}}}}", .{condition})); defer unknown.deinit();
        const rules = try unknown.containerRuleMatchesIn(a, &element);
        try std.testing.expectEqual(@as(usize, 1), rules.rules.len);
        try std.testing.expect(rules.rules[0].viewport == .unknown);
    }
    var nested = try parseAlloc(a, "@supports(display:flex){@media screen and (max-width:719px){.box{width:1px}}}"); defer nested.deinit();
    try std.testing.expect((try nested.containerRuleMatchesIn(a, &element)).rules[0].viewport == .unknown);
    var global = try parseAlloc(a, "@unknown{} .box{width:1px}"); defer global.deinit();
    try std.testing.expect((try global.containerRuleMatchesIn(a, &element)).unresolved);
}

test "container bounded ancestry search cannot turn exhausted proof into nonmatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".required .target{padding:1px}"); defer profile.deinit();
    const parents = try a.alloc(TextElement, 4100);
    for (parents, 0..) |*node, index| node.* = .{ .tag = "div", .parent = if (index == 0) null else &parents[index - 1], .ancestry_complete = index == 0 };
    const subject: TextElement = .{ .tag = "div", .classes = "target", .parent = &parents[parents.len - 1] };
    const result = try profile.containerRuleMatchesIn(a, &subject);
    try std.testing.expectEqual(@as(usize, 1), result.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, result.rules[0].match);
}

test "container cascade emits finite flex paint limits alignment and line height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const actual = try resolveInlineContainerAlloc(a, "display:flex;flex-direction:row;flex-wrap:nowrap;align-items:center;flex:none;width:250px;max-width:100%;box-sizing:border-box;padding:4px;background:#F9F9F9;border:1px solid #AAA;line-height:1.5;text-align:left");
    try std.testing.expect(actual.specified and !actual.unresolved);
    try std.testing.expectEqual(types.ContainerLayout.flex_row, actual.style.layout.?);
    try std.testing.expectEqual(types.ContainerAlignItems.center, actual.style.align_items.?);
    try std.testing.expectEqual(types.ContainerFlexItem.none, actual.style.flex_item.?);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .px, .value = 250 }, actual.style.width.?.length);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, actual.style.max_width.?.length);
    try std.testing.expectEqual(types.ContainerBoxSizing.border_box, actual.style.box_sizing.?);
    try std.testing.expectEqual(types.StyleEdges.all(.{ .unit = .px, .value = 4 }), actual.style.padding.?);
    try std.testing.expectEqualStrings("#f9f9f9", actual.style.background.?.rgb);
    try std.testing.expectEqualStrings("#aaaaaa", actual.style.border.?.solid.color.rgb);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 1 }, actual.style.border.?.solid.width);
    try std.testing.expectEqual(@as(f32, 1.5), actual.style.line_height.?.multiplier);
    try std.testing.expectEqual(types.CellTextAlign.left, actual.style.text_align.?);
    const transparent = try resolveInlineContainerAlloc(a, "background:none;border:2px solid transparent");
    try std.testing.expect(!transparent.unresolved);
    try std.testing.expect(transparent.style.background.? == .transparent and transparent.style.border.?.solid.color == .transparent);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 2 }, transparent.style.border.?.solid.width);
}

test "container responsive cascade retains source order important and inline priority in both states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var profile = try parseAlloc(a, ".box{width:250px;line-height:normal}@media screen and (max-width:719px){.box{width:100%;max-width:100%;box-sizing:border-box;line-height:1.5}}.box{width:300px}"); defer profile.deinit();
    const actual = try profile.resolveContainerIn(a, &element, "");
    try std.testing.expect(!actual.unresolved);
    try std.testing.expectEqual(@as(f32, 300), actual.style.width.?.length.value);
    try std.testing.expect(actual.style.line_height.? == .normal);
    const narrow = actual.style.screen_max_width.?;
    try std.testing.expectEqual(@as(u32, 719), narrow.max_width_px);
    try std.testing.expect(narrow.width == null);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, narrow.max_width.?.length);
    try std.testing.expectEqual(types.ContainerBoxSizing.border_box, narrow.box_sizing.?);
    try std.testing.expectEqual(@as(f32, 1.5), narrow.line_height.?.multiplier);
    var important = try parseAlloc(a, ".box{width:250px}@media screen and (max-width:719px){.box{width:100%!important}}.box{width:300px}"); defer important.deinit();
    const inline_normal = try important.resolveContainerIn(a, &element, "width:400px");
    try std.testing.expect(!inline_normal.unresolved);
    try std.testing.expectEqual(@as(f32, 400), inline_normal.style.width.?.length.value);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, inline_normal.style.screen_max_width.?.width.?.length);
    const inline_important = try important.resolveContainerIn(a, &element, "width:400px!important");
    try std.testing.expect(!inline_important.unresolved and inline_important.style.screen_max_width == null);
    try std.testing.expectEqual(@as(f32, 400), inline_important.style.width.?.length.value);
}

test "container responsive alternatives retain explicit resets and reject incompatible effective thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var reset = try parseAlloc(a, ".box{width:250px;max-width:90%;box-sizing:border-box;line-height:2em}@media screen and (max-width:719px){.box{width:auto;max-width:none;box-sizing:content-box;line-height:normal}}"); defer reset.deinit();
    const actual = try reset.resolveContainerIn(a, &element, "");
    try std.testing.expect(!actual.unresolved);
    const alternative = actual.style.screen_max_width.?;
    try std.testing.expect(alternative.width.? == .auto and alternative.max_width.? == .none and alternative.line_height.? == .normal);
    try std.testing.expectEqual(types.ContainerBoxSizing.content_box, alternative.box_sizing.?);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 2 }, actual.style.line_height.?.length);
    for ([_][]const u8{ "100%", "50%", "250px" }, 0..) |last, index| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, ".box{{width:250px}}@media screen and (max-width:719px){{.box{{width:100%}}}}@media screen and (max-width:500px){{.box{{width:{s}}}}}", .{last})); defer profile.deinit();
        const result = try profile.resolveContainerIn(a, &element, "");
        if (index == 0) {
            try std.testing.expect(!result.unresolved);
            try std.testing.expectEqual(@as(u32, 719), result.style.screen_max_width.?.max_width_px);
            try std.testing.expectEqual(@as(f32, 100), result.style.screen_max_width.?.width.?.length.value);
        } else try std.testing.expect(result.unresolved);
        const overridden = try profile.resolveContainerIn(a, &element, "width:42px!important");
        try std.testing.expect(!overridden.unresolved and overridden.style.screen_max_width == null);
        try std.testing.expectEqual(@as(f32, 42), overridden.style.width.?.length.value);
    }
}

test "container unknown selector media and paint remain winning refusals until actually overridden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    for ([_][]const u8{ ".box:hover{width:var(--unknown)}", "@media print{.box{width:20px}}", ".box{width:var(--unknown)}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
        const overridden = try profile.resolveContainerIn(a, &element, "width:30px!important");
        try std.testing.expect(!overridden.unresolved and overridden.style.screen_max_width == null);
        try std.testing.expectEqual(@as(f32, 30), overridden.style.width.?.length.value);
    }
    for ([_][]const u8{ "background:var(--palette,#fff)", "border:var(--color,#aaa) 1px solid", "background:currentColor", "background:light-dark(var(--x),#fff)", "background:light-dark(#fff,#000)", "border:2px solid light-dark(#abc,#456)", "background-image:url(a);background-color:#fff", "background:var(--paint);background-color:#fff;background-image:none", "border-radius:2px;border:none" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    const background = try resolveInlineContainerAlloc(a, "background:var(--palette,#fff);background:#fff");
    try std.testing.expect(!background.unresolved);
    try std.testing.expectEqualStrings("#ffffff", background.style.background.?.rgb);
    const layers = try resolveInlineContainerAlloc(a, "background-image:url(a);background-color:#fff;background-image:none");
    try std.testing.expect(!layers.unresolved);
    const border = try resolveInlineContainerAlloc(a, "border:var(--color) 1px solid;border:1px solid red");
    try std.testing.expect(!border.unresolved);
    try std.testing.expectEqualStrings("#ff0000", border.style.border.?.solid.color.rgb);
    try std.testing.expect((try resolveInlineContainerAlloc(a, "background:var(--palette)!important;background:#fff")).unresolved);
    try std.testing.expect((try resolveInlineContainerAlloc(a, "border:1px solid red;border-color:var(--x)!important")).unresolved);
}

test "container conditional unsupported winners refuse while unconditional winners preserve ordinary behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    for ([_][]const u8{ "padding:2px", "display:flex", "background:#fff", "text-align:center", "flex:none", "align-items:center" },
        [_][]const u8{ "padding:4px!important", "display:block!important", "background:#000!important", "text-align:left!important", "flex:none!important", "align-items:stretch!important" }) |conditional, winner| {
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "@media screen and (max-width:719px){{.box{{{s}}}}}", .{conditional})); defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
        const fixed = try profile.resolveContainerIn(a, &element, winner);
        try std.testing.expect(!fixed.unresolved and fixed.style.screen_max_width == null);
    }
    for ([_][]const u8{ "display:flex;flex-direction:column", "display:flex;flex-wrap:wrap", "flex-grow:1", "display:flex;gap:1px", "align-items:baseline", "text-align:start" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    const restored = try resolveInlineContainerAlloc(a, "display:flex;flex-direction:column;flex-direction:row;flex-grow:1;flex:none");
    try std.testing.expect(!restored.unresolved and restored.style.layout.? == .flex_row and restored.style.flex_item.? == .none);
}

test "container line height retains normal multiplier and computed length distinctions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const normal = try resolveInlineContainerAlloc(a, "line-height:normal");
    const multiplier = try resolveInlineContainerAlloc(a, "line-height:0");
    const length_value = try resolveInlineContainerAlloc(a, "line-height:1.25em");
    try std.testing.expect(!normal.unresolved and normal.style.line_height.? == .normal);
    try std.testing.expect(!multiplier.unresolved and multiplier.style.line_height.?.multiplier == 0);
    try std.testing.expect(!length_value.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.25 }, length_value.style.line_height.?.length);
    for ([_][]const u8{ "120%", "-1", "nan", "inf", "var(--height)", "inherit" }) |value|
        try std.testing.expect((try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "line-height:{s}", .{value}))).unresolved);
    try std.testing.expect((try resolveInlineContainerAlloc(a, "line-height:1.5;font:12px serif")).unresolved);
    const later = try resolveInlineContainerAlloc(a, "font:12px serif;line-height:1.5");
    try std.testing.expect(!later.unresolved and later.style.line_height.?.multiplier == 1.5);
}

test "container all reset remains poisoned outside represented fields despite complete later winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const result = try resolveInlineContainerAlloc(a, "all:initial;margin:0;padding:0;width:auto;max-width:none;box-sizing:content-box;float:none;clear:none;display:flex;flex-direction:row;flex-wrap:nowrap;align-items:center;flex:none;background:transparent;border:none;line-height:normal;text-align:left;position:static;overflow:visible");
    try std.testing.expect(result.unresolved);
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var profile = try parseAlloc(a, "@media screen and (max-width:719px){.box{all:initial}}.box{width:20px!important}"); defer profile.deinit();
    try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
}

test "container positioned child cascade uses original ordinal and preserves parent box ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".mw-parser-output .card{display:flex;flex-direction:row;align-items:center;width:250px;padding:4px}.mw-parser-output .card>div:first-child{float:none!important;flex:none}.mw-parser-output .card>div:nth-child(2){margin-left:0.55em!important}"); defer profile.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const card: TextElement = .{ .tag = "div", .classes = "card", .parent = &root };
    var first: TextElement = .{ .tag = "div", .parent = &card, .element_index = 1 };
    const second: TextElement = .{ .tag = "div", .parent = &card, .element_index = 2 };
    const parent_style = try profile.resolveContainerIn(a, &card, "");
    const first_style = try profile.resolveContainerIn(a, &first, "float:left");
    const second_style = try profile.resolveContainerIn(a, &second, "");
    try std.testing.expect(!parent_style.unresolved and !first_style.unresolved and !second_style.unresolved);
    try std.testing.expect(parent_style.style.layout.? == .flex_row and parent_style.style.align_items.? == .center);
    try std.testing.expect(first_style.style.flex_item.? == .none and first_style.style.float_side == null and first_style.style.width == null);
    try std.testing.expect(second_style.style.layout == null and second_style.style.flex_item == null);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 0.55 }, second_style.style.margins.?.left);
    first.element_index = null;
    try std.testing.expect((try profile.resolveContainerIn(a, &first, "")).unresolved);
}

test "container generated content remains unknown only for potentially matching subjects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    for ([_][]const u8{ ".box::before{content:'extra'}", ".box::after{content:attr(title)}", ".box::before{content:var(--label)}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
        // An own-element declaration cannot erase a possible pseudo child.
        try std.testing.expect((try profile.resolveContainerIn(a, &element, "content:none!important;width:20px")).unresolved);
    }
    var other = try parseAlloc(a, ".other::before{content:'extra'}.box{width:23px}"); defer other.deinit();
    const actual = try other.resolveContainerIn(a, &element, "");
    try std.testing.expect(!actual.unresolved);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .px, .value = 23 }, actual.style.width.?.length);
}

test "container layer rank uncertainty cannot lose through ordinary specificity or unknown media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    for ([_][]const u8{
        ".box{width:10px!important}@layer x{div{width:20px!important}}",
        ".box{width:10px!important}@layer x{@media screen and (max-width:719px){div{width:20px!important}}}",
        "@layer x{.box:hover{width:20px!important}}.box{width:10px!important}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        const rules = try profile.containerRuleMatchesIn(a, &element);
        var unknown_rank = false;
        for (rules.rules) |rule| unknown_rank = unknown_rank or rule.rank_unknown;
        try std.testing.expect(unknown_rank);
        try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
        try std.testing.expect((try profile.resolveContainerIn(a, &element, "width:30px!important")).unresolved);
    }
    var other = try parseAlloc(a, "@layer x{@media screen and (max-width:719px){.other{width:20px!important}}}.box{width:10px!important}"); defer other.deinit();
    const matched = try other.containerRuleMatchesIn(a, &element);
    try std.testing.expectEqual(@as(usize, 1), matched.rules.len);
    try std.testing.expect(!matched.rules[0].rank_unknown and matched.rules[0].viewport == .all);
    const actual = try other.resolveContainerIn(a, &element, "");
    try std.testing.expect(!actual.unresolved and actual.style.screen_max_width == null);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .px, .value = 10 }, actual.style.width.?.length);
}


test "uncertain text paint uses complete ancestor classes only to prove nonmatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact selector/declarations retained in VI Common.css 35aa6675.
    var profile = try parseAlloc(a, ".etymology > .NavContent > ul > li:only-child > span:not(.relationship){border:3px solid #444;font-weight:bold;margin-top:0}");
    defer profile.deinit();
    for ([_][]const u8{ "", "mw-parser-output IPA", "etymology", "NavContent", "Etymology NavContent", "etymology NavContents" }) |classes| {
        errdefer std.debug.print("complete text ancestors={s}\n", .{classes});
        const subject: TextElement = .{ .tag = "span", .classes = "biota", .complete_ancestor_classes = classes };
        const paint = try profile.resolveTextPaint(a, &subject, "");
        try std.testing.expect(paint.weight == null and paint.color == null and paint.font_style == null);
    }
    const unknown: TextElement = .{ .tag = "span", .classes = "IPA" };
    try std.testing.expect((try profile.resolveTextPaint(a, &unknown, "")).weight.? == .unknown);
    // An authored parent chain or content endpoint is not an inventory of all
    // generated wrappers. Neither one silently supplies the new certificate.
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const partial: TextElement = .{ .tag = "span", .parent = &root };
    try std.testing.expect((try profile.resolveTextPaint(a, &partial, "")).weight.? == .unknown);
    const possible: TextElement = .{ .tag = "span", .classes = "relationship", .complete_ancestor_classes = "mw-parser-output etymology NavContent" };
    try std.testing.expect((try profile.resolveTextPaint(a, &possible, "")).weight.? == .unknown);
    // Pseudo-class evaluation is still unsupported, even when the supplied
    // own relationship class might let a richer matcher disprove :not().
    try std.testing.expect((try profile.resolveTextPaint(a, &possible, "font-weight:normal")).weight.?.value == false);
    const own_only: TextElement = .{ .tag = "span", .classes = "etymology NavContent", .complete_ancestor_classes = "" };
    try std.testing.expect((try profile.resolveTextPaint(a, &own_only, "")).weight == null);
}

test "text ancestor nonmatch proof never borrows negated sibling escaped or alternative classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subject: TextElement = .{ .tag = "span", .complete_ancestor_classes = "" };
    for ([_][]const u8{
        ":not(.absent) span", ":is(.absent,.other) span",
        "[data-x='.absent'] span", ".absent + span:not(.relationship)",
        ".absent ~ span:not(.relationship)", ".absent\\:escaped span:not(.relationship)",
        ".absent/* comment */.other span:not(.relationship)",
    }) |selector| {
        errdefer std.debug.print("unsupported text selector={s}\n", .{selector});
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{font-weight:bold}}", .{selector}));
        defer profile.deinit();
        const paint = try profile.resolveTextPaint(a, &subject, "");
        // An error return runs the member label above; a nullable panic does not.
        try std.testing.expect(paint.weight != null);
        try std.testing.expect(paint.weight.? == .unknown);
    }
    // This original spelling has a boundary comment (following whitespace),
    // so the established selector-list scanner preserves the ancestor token.
    // It is a proved nonmatch only when that necessary class is absent.
    const boundary_source = ".absent/* comment */ span:not(.relationship)";
    var boundary_list: SelectorList = .{ .source = boundary_source };
    try std.testing.expectEqualStrings(".absent span:not(.relationship)", trim((try boundary_list.nextAlloc(a)) orelse return error.TestUnexpectedResult));
    try std.testing.expect(try boundary_list.nextAlloc(a) == null);
    var boundary = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{font-weight:bold}}", .{boundary_source}));
    defer boundary.deinit();
    try std.testing.expect((try boundary.resolveTextPaint(a, &subject, "")).weight == null);
    const possible: TextElement = .{ .tag = "span", .complete_ancestor_classes = "absent" };
    const possible_paint = try boundary.resolveTextPaint(a, &possible, "");
    try std.testing.expect(possible_paint.weight != null);
    try std.testing.expect(possible_paint.weight.? == .unknown);
    // One disproved list arm cannot erase a different possible arm.
    var alternatives = try parseAlloc(a, ".absent > span:not(.relationship),span:not(.other){font-weight:bold}");
    defer alternatives.deinit();
    try std.testing.expect((try alternatives.resolveTextPaint(a, &subject, "")).weight.? == .unknown);
    var exact = try parseAlloc(a, "span{font-weight:bold}");
    defer exact.deinit();
    try std.testing.expect((try exact.resolveTextPaint(a, &subject, "")).weight.?.value == true);
}


test "retained VI text and display uncertainty share complete source ancestor nonmatch proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    // Both declarations are retained in Common.css35aa and in actual served
    // Cubeb site.stylesda6b. Neither ancestor is present on the observed biota path.
    const css = ".etymology li > span{display:block;position:relative;border:1px solid #aaa;background:white;margin:auto;margin-top:4em;width:10em;padding:.25em}" ++
        ".etymology > .NavContent > ul > li:only-child > span:not(.relationship){border:3px solid #444;font-weight:bold;margin-top:0}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    const unknown_subject: TextElement = .{ .tag = "span", .classes = "biota" };
    try std.testing.expect((try profile.resolveTextPaint(a, &unknown_subject, "")).weight.? == .unknown);
    var unknown_display = profile.displayRules("span", "biota", "");
    const first_unknown = unknown_display.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_unknown.uncertain);
    for ([_][]const u8{ "", "mw-parser-output mw-content-ltr vector-body mw-body", "etymology-other NavContent" }) |complete| {
        var display = profile.displayRules("span", "biota", "");
        display.complete_ancestor_classes = complete;
        try std.testing.expect(display.next() == null);
        const subject: TextElement = .{ .tag = "span", .classes = "biota", .complete_ancestor_classes = complete };
        try std.testing.expect((try profile.resolveTextPaint(a, &subject, "")).weight == null);
    }
    var partial = profile.displayRules("span", "biota", "");
    // A content endpoint and an authored parent chain do not populate the
    // separate complete-ancestor certificate. Existing uncertainty is unchanged.
    try std.testing.expect(partial.next() != null);
    var possible = profile.displayRules("span", "biota", "");
    possible.complete_ancestor_classes = "mw-parser-output etymology NavContent";
    try std.testing.expect((possible.next() orelse return error.TestUnexpectedResult).uncertain);
    const still_possible: TextElement = .{ .tag = "span", .classes = "biota", .complete_ancestor_classes = "etymology NavContent" };
    try std.testing.expect((try profile.resolveTextPaint(a, &still_possible, "")).weight.? == .unknown);
    var own_only = profile.displayRules("span", "etymology NavContent", "");
    own_only.complete_ancestor_classes = "";
    try std.testing.expect(own_only.next() == null);
}

test "display ancestor absence never borrows sibling negated escaped or alternative classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        ":not(.absent) span", ":is(.absent,.other) span", "[data-x='.absent'] span",
        ".absent + span:not(.relationship)", ".absent ~ span:not(.relationship)",
        ".absent\\:escaped span:not(.relationship)", ".absent/* comment */.other span:not(.relationship)",
    }) |selector| {
        errdefer std.debug.print("display necessary ancestor selector={s}\n", .{selector});
        var profile = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{{display:none}}", .{selector})); defer profile.deinit();
        var display = profile.displayRules("span", "biota", "");
        display.complete_ancestor_classes = "";
        try std.testing.expect((display.next() orelse return error.TestUnexpectedResult).uncertain);
    }
    var boundary = try parseAlloc(a, ".absent/* comment */ span:not(.relationship){display:none}"); defer boundary.deinit();
    var display = boundary.displayRules("span", "biota", ""); display.complete_ancestor_classes = "";
    try std.testing.expect(display.next() == null);
    var possible = boundary.displayRules("span", "biota", ""); possible.complete_ancestor_classes = "absent";
    try std.testing.expect((possible.next() orelse return error.TestUnexpectedResult).uncertain);
}

test "display selector groups retain possible arms and exact winners after ancestor filtering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".absent > span,span.other{display:none}"); defer profile.deinit();
    var display = profile.displayRules("span", "other", ""); display.complete_ancestor_classes = "";
    const remaining = display.next() orelse return error.TestUnexpectedResult;
    // One unsupported branch keeps the original non-forgiving-list boundary.
    try std.testing.expect(remaining.uncertain);
    try std.testing.expect(display.next() == null);
    var exact = try parseAlloc(a, "span.other{display:none}"); defer exact.deinit();
    var exact_display = exact.displayRules("span", "other", ""); exact_display.complete_ancestor_classes = "";
    try std.testing.expect(!(exact_display.next() orelse return error.TestUnexpectedResult).uncertain);
    try std.testing.expect(exact_display.next() == null);
}

const ContainerAttributeTesting = if (@import("builtin").is_test) struct {
    const Inventory = struct {
        names: []const []const u8 = &.{},
        known: bool = true,
        fn get(raw: ?*const anyopaque, name: []const u8) AttributePresence {
            const self: *const @This() = @ptrCast(@alignCast(raw orelse return .unknown));
            if (!self.known) return .unknown;
            for (self.names) |candidate| if (std.ascii.eqlIgnoreCase(candidate, name)) return .present;
            return .absent;
        }
        fn source(self: *const @This()) AttributePresenceSource { return .{ .ctx = self, .get = get }; }
    };
} else struct {};

test "container candidate refusal uses only proved positive terminal attribute absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const absent: ContainerAttributeTesting.Inventory = .{};
    const parent: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    for ([_][]const u8{
        "a[rel=\"mw:referencedBy\"]::before{content:' ^'}",
        ".mw-parser-output a[role=\"button\"]:focus:not(:hover){text-decoration:none}",
        "a[role][role]:active{color:red}",
        "a[role=button]{width:40px}",
        "@media print{a[role]:focus{color:red}}",
        "@layer x{a[role]:focus{color:red!important}}",
    }) |css| {
        errdefer std.debug.print("container attribute case: {s}\n", .{css});
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        const element: TextElement = .{ .tag = "a", .classes = "new", .parent = &parent, .attribute_presence = absent.source() };
        const result = try sheet.containerRuleMatchesIn(a, &element); defer a.free(result.rules);
        try std.testing.expect(!result.unresolved);
        try std.testing.expectEqual(@as(usize, 0), result.rules.len);
    }
    var sheet = try parseAlloc(a, "figure [data-mw-tmh][data-mw-tmh][data-mw-tmh]{width:100%}"); defer sheet.deinit();
    const figure: TextElement = .{ .tag = "figure", .parent = &parent };
    const span: TextElement = .{ .tag = "span", .classes = "mw-file-element mw-broken-media", .parent = &figure, .attribute_presence = absent.source() };
    const result = try sheet.containerRuleMatchesIn(a, &span); defer a.free(result.rules);
    try std.testing.expect(!result.unresolved and result.rules.len == 0);
}

test "container attribute presence or unknown inventory never promotes unsupported selector matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const present: ContainerAttributeTesting.Inventory = .{ .names = &.{"role"} };
    const unknown: ContainerAttributeTesting.Inventory = .{ .known = false };
    var sheet = try parseAlloc(a, "a[role=\"button\"]:focus:not(:hover){width:40px}"); defer sheet.deinit();
    for ([_]?AttributePresenceSource{ null, present.source(), unknown.source() }) |source| {
        const element: TextElement = .{ .tag = "a", .attribute_presence = source, .ancestry_complete = true };
        const result = try sheet.containerRuleMatchesIn(a, &element); defer a.free(result.rules);
        try std.testing.expect(!result.unresolved);
        try std.testing.expectEqual(@as(usize, 1), result.rules.len);
        try std.testing.expectEqual(ContainerSelectorMatch.unknown, result.rules[0].match);
        try std.testing.expect((try sheet.resolveContainerIn(a, &element, "")).unresolved);
    }
}

test "container attribute refusal does not borrow negated alternative ancestor or sibling predicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const absent: ContainerAttributeTesting.Inventory = .{};
    for ([_][]const u8{
        "a:not([role]){width:40px}", "a:is([role],.new){width:40px}",
        "[role] a{width:40px}", "[role]+a{width:40px}",
        "[role]~a{width:40px}", "a[r\\6fle]{width:40px}",
        "a[role~=\"button\"]{width:40px}",
    }) |css| {
        errdefer std.debug.print("container attribute case: {s}\n", .{css});
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        const element: TextElement = .{ .tag = "a", .classes = "new", .attribute_presence = absent.source(), .ancestry_complete = true };
        const result = try sheet.containerRuleMatchesIn(a, &element); defer a.free(result.rules);
        try std.testing.expect(!result.unresolved);
        try std.testing.expect(result.rules.len != 0);
        for (result.rules) |rule| try std.testing.expectEqual(ContainerSelectorMatch.unknown, rule.match);
    }
}


test "additional Missing paint query excludes only unrelated tokens and separate glyph feature properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const html: TextElement = .{ .tag = "html", .classes = "skin-theme-clientpref-day", .ancestry_complete = true };
    const body: TextElement = .{ .tag = "body", .parent = &html };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &body };
    for ([_][]const u8{
        ":root{--wikt-palette-white:#fff;--unrelated:var(--color-destructive)}body{font-feature-settings:\"liga\" on; -webkit-font-feature-settings:\"kern\" on;-moz-font-feature-settings:normal}",
        "@media print{body{font-feature-settings:var(--features)!important}}",
        "@layer x{:root{--unrelated:#000!important}}",
        "a.new{font-feature-settings:\"color:red\"}",
    }) |css| {
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        for ([_]*const TextElement{ &html, &body, &link }) |element|
            try std.testing.expect(try sheet.missingLinkAdditionalPaintUnchangedIn(a, element));
    }
    // Exclusion of glyph features is never font/layout or full visual equality.
    var changed_color = try parseAlloc(a, "a.new{--unrelated:red;color:var(--unrelated)}"); defer changed_color.deinit();
    try std.testing.expect(!try changed_color.missingLinkAdditionalPaintUnchangedIn(a, &link));
}

test "additional Missing paint query keeps applicable paint reset generated and opaque effects unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const html: TextElement = .{ .tag = "html", .ancestry_complete = true };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &html };
    for ([_][]const u8{
        "color:red", "text-decoration:none", "outline:none", "outline-color:blue",
        "all:initial", "color-scheme:dark", "opacity:.5", "filter:invert(1)",
        "display:none", "visibility:hidden", "content:'extra'", "font:inherit",
        "font-feature-settings:normal;color:inherit", "--color-destructive:red",
        "--color-destructive--hover:red", "--color-destructive--active:red",
        "--color-destructive--visited:red", "--color-destructive--visited--hover:red",
        "--color-destructive--visited--active:red", "--outline-color-progressive--focus:red",
        "--color\\2d destructive:red", "font\\2d feature-settings:normal", "unrepresented:1",
    }) |declaration| {
        const css = try std.fmt.allocPrint(a, "a.new:unsupported{{{s}}}", .{declaration});
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, &link));
    }
    for ([_][]const u8{ "@import url('/unknown.css');", "@unknown{a.new{--unrelated:red}}" }) |css| {
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, &link));
    }
    var nonmatching = try parseAlloc(a, ".absent{color:red;all:initial}"); defer nonmatching.deinit();
    try std.testing.expect(try nonmatching.missingLinkAdditionalPaintUnchangedIn(a, &link));
}


test "physical display parent suffix refutes only unequal proved direct edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ".ns-0 #toc > tr > td > ul{display:table}"); defer profile.deinit();
    var absent = profile.displayRules("ul", "", ""); absent.complete_ancestor_classes = "ns-0";
    try std.testing.expect(absent.next().?.uncertain); // A class inventory cannot refute #toc.
    var known = profile.displayRules("ul", "", ""); known.complete_ancestor_classes = "ns-0"; known.physical_parent_tag = "div";
    try std.testing.expect(known.next() == null);
    var possible = profile.displayRules("ul", "", ""); possible.complete_ancestor_classes = "ns-0"; possible.physical_parent_tag = "TD";
    try std.testing.expect(possible.next().?.uncertain); // Matching edge is not a selector match.
    var no_class = profile.displayRules("ul", "", ""); no_class.physical_parent_tag = "div";
    try std.testing.expect(no_class.next() == null); // Independent necessary-edge nonmatch.
}

test "physical display suffix keeps unsupported selector syntax and matching parent uncertain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{
        "td:not(.other)>ul", "td:is(.one,.two)>ul", "td[data-x]>ul", "td+div>ul", "td~div>ul", "t\\64 >ul", "td ul", "td > > ul", "td > * > ul",
    }) |selector| {
        const css = try std.fmt.allocPrint(a, "{s}{{display:none}}", .{selector});
        var profile = try parseAlloc(a, css); defer profile.deinit();
        var iterator = profile.displayRules("ul", "", ""); iterator.physical_parent_tag = "div";
        const candidate = iterator.next() orelse return error.TestUnexpectedResult;
        try std.testing.expect(candidate.uncertain);
    }
}

test "physical display parent capability is per branch and never grants hiding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, "td>ul,div>ul{display:none}"); defer profile.deinit();
    var iterator = profile.displayRules("ul", "", ""); iterator.physical_parent_tag = "div";
    const kept = iterator.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(kept.uncertain and iterator.next() == null);
    var cascade: DisplayCascade = .{}; cascade.consider(null, false, kept.specificity, kept.order, false);
    try std.testing.expect(cascade.hidden == null);
    var conditional = try parseAlloc(a, "@media print{td>ul{display:none}}"); defer conditional.deinit();
    var refuted = conditional.displayRules("ul", "", ""); refuted.physical_parent_tag = "div";
    try std.testing.expect(refuted.next() == null);
}


test "alignment ancestry refutes absent necessary classes and keeps null own only and possible selectors conservative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ".etymology li{text-align:center}"); defer profile.deinit();
    const unknown: TextElement = .{ .tag = "li" };
    try std.testing.expect((try profile.resolveAlignmentIn(a, &unknown, null, "")).unresolved);
    try std.testing.expectEqualDeep(try profile.resolveAlignment(a, "li", "", "", null, ""), try profile.resolveAlignmentIn(a, &unknown, null, ""));
    const absent: TextElement = .{ .tag = "li", .complete_ancestor_classes = "ns-0 mw-parser-output" };
    try std.testing.expectEqualDeep(AlignmentResolution{}, try profile.resolveAlignmentIn(a, &absent, null, ""));
    const own_only: TextElement = .{ .tag = "li", .classes = "etymology" };
    try std.testing.expect((try profile.resolveAlignmentIn(a, &own_only, null, "")).unresolved);
    const own_with_absent_ancestors: TextElement = .{ .tag = "li", .classes = "etymology", .complete_ancestor_classes = "" };
    try std.testing.expectEqualDeep(AlignmentResolution{}, try profile.resolveAlignmentIn(a, &own_with_absent_ancestors, null, ""));
    const possible: TextElement = .{ .tag = "li", .complete_ancestor_classes = "ns-0 etymology" };
    const result = try profile.resolveAlignmentIn(a, &possible, null, "");
    try std.testing.expect(result.specified and result.unresolved and result.value == null);
}

test "alignment ancestry keeps legacy inline important and reset precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ".etymology li{text-align:center!important}"); defer profile.deinit();
    const absent: TextElement = .{ .tag = "li", .complete_ancestor_classes = "ns-0" };
    const possible: TextElement = .{ .tag = "li", .complete_ancestor_classes = "etymology" };
    const legacy = try profile.resolveAlignmentIn(a, &absent, "right", "");
    try std.testing.expect(!legacy.unresolved and legacy.specified and legacy.value.? == .right);
    const authored = try profile.resolveAlignmentIn(a, &possible, "right", "text-align:left!important");
    try std.testing.expect(!authored.unresolved and authored.value.? == .left);
    try std.testing.expect((try profile.resolveAlignmentIn(a, &possible, "right", "text-align:left")).unresolved);
    for ([_][]const u8{ "text-align:inherit", "text-align:unset", "text-align:var(--unknown)", "all:unset" }) |css|
        try std.testing.expect((try profile.resolveAlignmentIn(a, &absent, "right", css)).unresolved);
    var imported = try parseAlloc(a, "@import 'unobserved.css';.etymology li{text-align:center}"); defer imported.deinit();
    try std.testing.expect((try imported.resolveAlignmentIn(a, &absent, null, "text-align:left!important")).unresolved);
}

test "alignment class certificate does not establish physical edges or sibling absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const parent: TextElement = .{ .tag = "div", .complete_ancestor_classes = "ns-0" };
    const element: TextElement = .{ .tag = "li", .parent = &parent, .complete_ancestor_classes = "ns-0" };
    var physical = try parseAlloc(a, ".ns-0 #toc>tr>td>li{text-align:right}"); defer physical.deinit();
    // Even a real parent pointer is not this API's physical-edge capability.
    try std.testing.expect((try physical.resolveAlignmentIn(a, &element, null, "")).unresolved);
    var sibling = try parseAlloc(a, ".absent+li{text-align:center}"); defer sibling.deinit();
    try std.testing.expect((try sibling.resolveAlignmentIn(a, &element, null, "")).unresolved);
}


test "container unsupported positive attributes retain necessary terminal class without matching values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const present: ContainerAttributeTesting.Inventory = .{ .names = &.{"href"} };
    const unknown: ContainerAttributeTesting.Inventory = .{ .known = false };
    for ([_][]const u8{
        ".mw-parser-output a[href$=\".pdf\"].external{background:red;padding-right:18px}",
        ".mw-parser-output a[href*=\"://x.com\"].external{background:red}",
        ".mw-parser-output a[href^='https:'].external#download{color:red}",
    }) |css| {
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        for ([_]?AttributePresenceSource{ null, present.source(), unknown.source() }) |attributes| {
            const missing: TextElement = .{ .tag = "a", .classes = "new", .parent = &root, .attribute_presence = attributes };
            const refused = try sheet.containerRuleMatchesIn(a, &missing); defer a.free(refused.rules);
            try std.testing.expect(!refused.unresolved and refused.rules.len == 0);
            try std.testing.expect(try sheet.missingLinkAdditionalPaintUnchangedIn(a, &missing));
            const possible: TextElement = .{ .tag = "a", .classes = "new external", .id = "download", .parent = &root, .attribute_presence = attributes };
            const retained = try sheet.containerRuleMatchesIn(a, &possible); defer a.free(retained.rules);
            try std.testing.expectEqual(@as(usize, 1), retained.rules.len);
            try std.testing.expectEqual(ContainerSelectorMatch.unknown, retained.rules[0].match);
            try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, &possible));
        }
    }
}

test "container generated suffix retains required direct parent without granting an attribute match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var sheet = try parseAlloc(a, "span[rel=\"mw:referencedBy\"] > a::before{font-weight:bold;content:'reference'}"); defer sheet.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const figure: TextElement = .{ .tag = "figure", .parent = &root };
    const span: TextElement = .{ .tag = "span", .parent = &root };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &figure, .physical_ancestry_complete = true };
    const refused = try sheet.containerRuleMatchesIn(a, &link); defer a.free(refused.rules);
    try std.testing.expect(!refused.unresolved and refused.rules.len == 0);
    try std.testing.expect(try sheet.missingLinkAdditionalPaintUnchangedIn(a, &link));
    // A tracked compiler parent may skip a real SPAN; even a closed logical
    // chain cannot refute the direct edge without physical-path authority.
    const skipped: TextElement = .{ .tag = "a", .classes = "new", .parent = &figure, .ancestry_complete = true };
    const skipped_result = try sheet.containerRuleMatchesIn(a, &skipped); defer a.free(skipped_result.rules);
    try std.testing.expectEqual(@as(usize, 1), skipped_result.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, skipped_result.rules[0].match);
    try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, &skipped));
    const exact_possible: TextElement = .{ .tag = "a", .classes = "new", .parent = &span, .physical_ancestry_complete = true };
    const exact_result = try sheet.containerRuleMatchesIn(a, &exact_possible); defer a.free(exact_result.rules);
    try std.testing.expectEqual(@as(usize, 1), exact_result.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, exact_result.rules[0].match);
    for ([_]?*const TextElement{ null, &span }) |parent| {
        const possible: TextElement = .{ .tag = "a", .classes = "new", .parent = parent };
        const retained = try sheet.containerRuleMatchesIn(a, &possible); defer a.free(retained.rules);
        try std.testing.expectEqual(@as(usize, 1), retained.rules.len);
        try std.testing.expectEqual(ContainerSelectorMatch.unknown, retained.rules[0].match);
        try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, &possible));
    }
    var descendant = try parseAlloc(a, "span[rel=\"mw:referencedBy\"] a::after{content:'reference'}"); defer descendant.deinit();
    const unclosed_figure: TextElement = .{ .tag = "figure" };
    const unclosed_link: TextElement = .{ .tag = "a", .parent = &unclosed_figure };
    const unknown = try descendant.containerRuleMatchesIn(a, &unclosed_link); defer a.free(unknown.rules);
    try std.testing.expectEqual(@as(usize, 1), unknown.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, unknown.rules[0].match);
    const closed = try descendant.containerRuleMatchesIn(a, &link); defer a.free(closed.rules);
    try std.testing.expectEqual(@as(usize, 0), closed.rules.len);
}

test "container necessary chains preserve functional sibling escaped and attribute-only uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const absent: ContainerAttributeTesting.Inventory = .{};
    const figure: TextElement = .{ .tag = "figure", .ancestry_complete = true };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &figure, .attribute_presence = absent.source() };
    for ([_][]const u8{
        "[rel=\"mw:referencedBy\"] > a::before{content:'x'}",
        "span[rel=\"mw:referencedBy\"] + a::before{content:'x'}",
        "span[rel=\"mw:referencedBy\"] ~ a::before{content:'x'}",
        "span:not(.absent) > a::before{content:'x'}",
        "span:is(.one,.two) > a::before{content:'x'}",
        "sp\\61 n[rel=\"mw:referencedBy\"] > a::before{content:'x'}",
        "a:is([href],.new).external{color:red}",
        "a[href$=\".pdf\"].external:future-pseudo{color:red}",
    }) |css| {
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        const result = try sheet.containerRuleMatchesIn(a, &link); defer a.free(result.rules);
        try std.testing.expect(!result.unresolved and result.rules.len != 0);
        for (result.rules) |rule| try std.testing.expectEqual(ContainerSelectorMatch.unknown, rule.match);
    }
}

test "cell minimum width projects independent content floor and preserves table refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "th{min-width:20em;text-align:center}th{min-width:30em}"); defer profile.deinit();
    const cell = try profile.resolveCellWithContext(a, 0, 0, "vsToggleElement", .{ .ancestor_classes = "inflection-table vsSwitcher fi-decl-poss fi-decl-poss-header", .own_id = "" }, true, null, "text-align:left");
    try std.testing.expect(!cell.unresolved);
    try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .em, .value = 30 }), cell.style.?.min_width);
    try std.testing.expectEqual(types.CellTextAlign.left, cell.style.?.text_align.?);
    const independent = try profile.resolveCell(a, 0, true, null, "width:80px");
    try std.testing.expect(!independent.unresolved);
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 80 }, independent.style.?.width.?);
    try std.testing.expectEqualDeep(cell.style.?.min_width, independent.style.?.min_width);
    const table = try profile.resolveTable(a, 0, "", null, "width:80px;min-width:30em");
    try std.testing.expect(table.unresolved);
    try std.testing.expectEqualDeep(@as(?types.StyleWidth, .{ .unit = .px, .value = 80 }), table.style.?.width);
    try std.testing.expect((try resolveInlineTableAlloc(a, "min-width:0")).unresolved);
}

test "cell minimum width keeps importance source order and unknown value winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "th{min-width:var(--missing)}th{min-width:18px!important}th#chosen{min-width:23em}"); defer profile.deinit();
    const selected = try profile.resolveCellWithContext(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "chosen" }, true, null, "min-width:31px");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = 18 }), selected.style.?.min_width);
    const inline_winner = try profile.resolveCellWithContext(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "chosen" }, true, null, "min-width:31px!important;min-width:32px!important");
    try std.testing.expect(!inline_winner.unresolved);
    try std.testing.expectEqual(@as(f32, 32), inline_winner.style.?.min_width.?.value);
    var unknown = try parseAlloc(a, "th{min-width:18px}th{min-width:25%!important}"); defer unknown.deinit();
    const refused = try unknown.resolveCell(a, 0, true, null, "min-width:30em");
    try std.testing.expect(refused.unresolved and (refused.style == null or refused.style.?.min_width == null));
    const restored = try unknown.resolveCell(a, 0, true, null, "min-width:30em!important");
    try std.testing.expect(!restored.unresolved);
    try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .em, .value = 30 }), restored.style.?.min_width);
}

test "cell minimum width uses strict CSS numbers and refuses unsupported positive dimensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    for ([_][]const u8{ "-1px", "-0.1em", "nanpx", "infpx", "0x10px", "1_0px", "1.px", "2", "banana" }) |invalid| {
        const css = try std.fmt.allocPrint(a, "min-width:7px;min-width:{s}", .{invalid});
        const cell = try profile.resolveCell(a, 0, false, null, css);
        try std.testing.expect(!cell.unresolved);
        try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = 7 }), cell.style.?.min_width);
    }
    for ([_][]const u8{ "0", "-0", "+0.0e2", "initial", "unset" }) |zero| {
        const cell = try profile.resolveCell(a, 0, false, null, try std.fmt.allocPrint(a, "min-width:7px;min-width:{s}", .{zero}));
        try std.testing.expect(!cell.unresolved);
        try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .px, .value = 0 }), cell.style.?.min_width);
    }
    for ([_][]const u8{ "25%", "0%", "2rem", "1e999px", "var(--size)", "calc(2px + 1px)", "inherit", "revert", "revert-layer", "auto", "min-content" }) |unsupported| {
        const cell = try profile.resolveCell(a, 0, false, null, try std.fmt.allocPrint(a, "min-width:7px;min-width:{s}", .{unsupported}));
        try std.testing.expect(cell.unresolved and (cell.style == null or cell.style.?.min_width == null));
    }
}

test "cell minimum width preserves selector uncertainty and complete necessary nonmatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, "th{min-width:2em}.foreign th:hover{min-width:4em!important}"); defer profile.deinit();
    const absent = try profile.resolveCellWithContext(a, 0, 0, "", .{ .ancestor_classes = "", .own_id = "" }, true, null, "");
    try std.testing.expect(!absent.unresolved);
    try std.testing.expectEqual(@as(f32, 2), absent.style.?.min_width.?.value);
    const possible = try profile.resolveCellWithContext(a, 0, 0, "", .{ .ancestor_classes = "foreign", .own_id = "" }, true, null, "");
    try std.testing.expect(possible.unresolved and (possible.style == null or possible.style.?.min_width == null));
    var conditional = try parseAlloc(a, "th{min-width:2em}@media screen and (max-width:719px){th{min-width:4em}}"); defer conditional.deinit();
    try std.testing.expect((try conditional.resolveCell(a, 0, true, null, "min-width:5em!important")).unresolved);
    // Existing unsupported selector/rank uncertainty is never dismissed merely
    // because a numeric min-width appears stronger in an incomplete cascade.
    var layered = try parseAlloc(a, "th{min-width:2em!important}@layer x{th{min-width:4em!important}}"); defer layered.deinit();
    try std.testing.expect((try layered.resolveCell(a, 0, true, null, "")).unresolved);
}

test "cell minimum width retains reset escaped property and box sizing refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    for ([_][]const u8{ "min-width:30em;all:initial", "min-width:30em;all:unset!important", "min-width:30em;min\\2d width:40em", "min-width:30em;box-sizing:border-box", "min-width:30em;box-sizing:content-box", "min-width:30em;box-sizing:var(--box)" }) |css| {
        const cell = try profile.resolveCell(a, 0, true, null, css);
        try std.testing.expect(cell.unresolved and (cell.style == null or cell.style.?.min_width == null));
        const inline_cell = try resolveInlineCellAlloc(a, null, css);
        try std.testing.expect(inline_cell.unresolved and (inline_cell.style == null or inline_cell.style.?.min_width == null));
    }
    // Min-width may win while the independent all/box-sizing reset remains
    // unsupported. Prove its priority without projecting a guessed box floor.
    const later_css = "all:initial;min-width:30em";
    const later = try profile.resolveCell(a, 0, true, null, later_css);
    errdefer std.debug.print("CELL_MIN_RESET member=later unresolved={} style={any}\n", .{later.unresolved, later.style});
    try std.testing.expect(later.unresolved);
    try std.testing.expect(later.style == null);
    const later_winners = try profile.cascade(a, .th, 0, 0, "", .{}, null, null, later_css);
    const later_minimum = later_winners.value(.min_width) orelse return error.TestUnexpectedResult;
    try std.testing.expect(later_minimum == .length_value);
    try std.testing.expectEqual(@as(f32, 30), later_minimum.length_value.value);
    try std.testing.expectEqual(types.StyleLengthUnit.em, later_minimum.length_value.unit);
    const later_reset = later_winners.value(.box_sizing) orelse return error.TestUnexpectedResult;
    try std.testing.expect(later_reset == .unsupported);
    const later_candidate = later_winners.slots[@intFromEnum(Property.min_width)] orelse return error.TestUnexpectedResult;
    const later_reset_candidate = later_winners.slots[@intFromEnum(Property.layout_reset)] orelse return error.TestUnexpectedResult;
    try std.testing.expect(later_candidate.priority.wins(later_reset_candidate.priority));
    const later_inline = try resolveInlineCellAlloc(a, null, later_css);
    try std.testing.expect(later_inline.unresolved and later_inline.style == null);
    const important_css = "min-width:30em!important;all:initial";
    const important = try profile.resolveCell(a, 0, true, null, important_css);
    errdefer std.debug.print("CELL_MIN_RESET member=important unresolved={} style={any}\n", .{important.unresolved, important.style});
    try std.testing.expect(important.unresolved);
    try std.testing.expect(important.style == null);
    const important_winners = try profile.cascade(a, .th, 0, 0, "", .{}, null, null, important_css);
    const important_minimum = important_winners.value(.min_width) orelse return error.TestUnexpectedResult;
    try std.testing.expect(important_minimum == .length_value);
    try std.testing.expectEqual(@as(f32, 30), important_minimum.length_value.value);
    try std.testing.expectEqual(types.StyleLengthUnit.em, important_minimum.length_value.unit);
    const important_reset = important_winners.value(.box_sizing) orelse return error.TestUnexpectedResult;
    try std.testing.expect(important_reset == .unsupported);
    const important_candidate = important_winners.slots[@intFromEnum(Property.min_width)] orelse return error.TestUnexpectedResult;
    const important_reset_candidate = important_winners.slots[@intFromEnum(Property.layout_reset)] orelse return error.TestUnexpectedResult;
    try std.testing.expect(important_candidate.priority.important);
    try std.testing.expect(important_candidate.priority.wins(important_reset_candidate.priority));
    const important_inline = try resolveInlineCellAlloc(a, null, important_css);
    try std.testing.expect(important_inline.unresolved and important_inline.style == null);
}

test "inline cell minimum keeps historical alignment only paint domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const cell = try resolveInlineCellAlloc(a, "right", "background:red;border:2px solid blue;padding:3px;color:green;min-width:30em;text-align:left");
    try std.testing.expect(!cell.unresolved and !cell.background_specified and cell.background == null);
    try std.testing.expect(cell.style.?.border == null and cell.style.?.padding == null);
    try std.testing.expectEqual(types.CellTextAlign.left, cell.style.?.text_align.?);
    try std.testing.expectEqualDeep(@as(?types.StyleLength, .{ .unit = .em, .value = 30 }), cell.style.?.min_width);
    const absent = try resolveInlineCellAlloc(a, null, "background:red;padding:3px");
    try std.testing.expect(absent.style == null and !absent.unresolved and absent.background == null and !absent.background_specified);
    const unknown = try resolveInlineCellAlloc(a, "right", "min-width:20px;min-width:var(--size)!important");
    try std.testing.expect(unknown.unresolved);
    try std.testing.expectEqual(types.CellTextAlign.right, unknown.style.?.text_align.?);
    try std.testing.expect(unknown.style.?.min_width == null);
}

test "container fixed height retains auto zero length and independent line height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const absent = try resolveInlineContainerAlloc(a, "");
    try std.testing.expect(!absent.specified and !absent.unresolved and absent.style.height == null);
    for ([_][]const u8{ "auto", "initial", "unset" }) |value| {
        const selected = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "height:8px;height:{s}", .{value}));
        try std.testing.expect(selected.specified and !selected.unresolved and selected.style.height == null);
    }
    for ([_][]const u8{ "0", "+0", "-0.0", "0e3", "0px", "0em" }) |value| {
        const selected = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "height:{s}", .{value}));
        try std.testing.expect(selected.specified and !selected.unresolved);
        try std.testing.expectEqual(@as(f32, 0), selected.style.height.?.value);
        try std.testing.expect(!containerStyleEqual(absent.style, selected.style));
    }
    const length_value = try resolveInlineContainerAlloc(a, "height:1.6em;line-height:2;box-sizing:border-box;padding:3px;border:1px solid #aaa");
    try std.testing.expect(!length_value.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, length_value.style.height.?);
    try std.testing.expectEqual(@as(f32, 2), length_value.style.line_height.?.multiplier);
    try std.testing.expectEqual(types.ContainerBoxSizing.border_box, length_value.style.box_sizing.?);
    try std.testing.expectEqual(@as(f32, 3), length_value.style.padding.?.top.value);
    try std.testing.expectEqual(@as(f32, 1), length_value.style.border.?.solid.width.value);
    const px = try resolveInlineContainerAlloc(a, "height:+1.25e1PX;box-sizing:content-box");
    try std.testing.expect(!px.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 12.5 }, px.style.height.?);
}

test "container height cascade preserves specificity source order important and auto winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const box: TextElement = .{ .tag = "div", .classes = "box", .id = "owner", .ancestry_complete = true };
    var profile = try parseAlloc(a, ".box{height:3px}.box{height:4px}#owner{height:5px}div{height:6px}"); defer profile.deinit();
    const selected = try profile.resolveContainerIn(a, &box, "");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqual(@as(f32, 5), selected.style.height.?.value);
    const inline_value = try profile.resolveContainerIn(a, &box, "height:7px");
    try std.testing.expect(!inline_value.unresolved);
    try std.testing.expectEqual(@as(f32, 7), inline_value.style.height.?.value);
    var important = try parseAlloc(a, ".box{height:8px!important}#owner{height:9px}.box{height:10px!important}"); defer important.deinit();
    const normal_inline = try important.resolveContainerIn(a, &box, "height:11px");
    try std.testing.expect(!normal_inline.unresolved);
    try std.testing.expectEqual(@as(f32, 10), normal_inline.style.height.?.value);
    const reset = try important.resolveContainerIn(a, &box, "height:auto!important");
    try std.testing.expect(reset.specified and !reset.unresolved and reset.style.height == null);
    const unknown = try resolveInlineContainerAlloc(a, "height:var(--size)!important;height:12px");
    try std.testing.expect(unknown.unresolved);
    const recovered = try resolveInlineContainerAlloc(a, "height:var(--size);height:12px");
    try std.testing.expect(!recovered.unresolved);
    try std.testing.expectEqual(@as(f32, 12), recovered.style.height.?.value);
}

test "container height strict numeric syntax ignores invalid declarations and retains unsupported winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "-1px", "-2em", "-3%", "1", "1.px", "0x1p2px", "1_0px", "nan", "inf", "nanpx", "none" }) |value| {
        const selected = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "height:9px;height:{s}!important", .{value}));
        try std.testing.expect(!selected.unresolved);
        try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 9 }, selected.style.height.?);
    }
    for ([_][]const u8{ "10%", "1rem", "1vh", "1lh", "1svh", "1cqh", "1e100px", "var(--height,1px)", "calc(1px + 1px)", "inherit", "revert", "revert-layer", "min-content", "fit-content", "1\\70x" }) |value| {
        const selected = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "height:9px;height:{s}", .{value}));
        try std.testing.expect(selected.unresolved);
        const restored = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "height:{s};height:9px!important", .{value}));
        try std.testing.expect(!restored.unresolved);
        try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 9 }, restored.style.height.?);
    }
}

test "container height keeps uncertain selectors media rank resets and unrelated nonmatches distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const box: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    for ([_][]const u8{ ".box:hover{height:2px}", "@media print{.box{height:2px}}", "@supports (display:block){.box{height:2px}}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &box, "")).unresolved);
        const overridden = try profile.resolveContainerIn(a, &box, "height:3px!important");
        try std.testing.expect(!overridden.unresolved);
        try std.testing.expectEqual(@as(f32, 3), overridden.style.height.?.value);
    }
    var unrelated = try parseAlloc(a, ".other:hover{height:var(--h)}.box{height:4px}"); defer unrelated.deinit();
    const selected = try unrelated.resolveContainerIn(a, &box, "");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqual(@as(f32, 4), selected.style.height.?.value);
    var layer = try parseAlloc(a, "@layer a{.box{height:4px}}"); defer layer.deinit();
    try std.testing.expect((try layer.resolveContainerIn(a, &box, "height:5px!important")).unresolved);
    for ([_][]const u8{ "all:initial;height:1px", "hei\\67ht:1px;height:2px", "height:1px;min-height:10%", "height:1px;max-height:10px", "height:1px;position:absolute", "height:1px;overflow:hidden", "height:1px;column-count:2" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
}

test "container fixed height is unchanged across represented width bands while conditional height remains refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const box: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var width = try parseAlloc(a, ".box{height:1.6em;width:200px}@media screen and (max-width:700px){.box{width:100%}}"); defer width.deinit();
    const selected = try width.resolveContainerIn(a, &box, "");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, selected.style.height.?);
    try std.testing.expectEqual(@as(u32, 700), selected.style.screen_max_width.?.max_width_px);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, selected.style.screen_max_width.?.width.?.length);
    for ([_][]const u8{ "0", "2px", "auto", "inherit" }) |value| {
        var conditional = try parseAlloc(a, try std.fmt.allocPrint(a, ".box{{height:1px}}@media screen and (max-width:700px){{.box{{height:{s}}}}}", .{value})); defer conditional.deinit();
        try std.testing.expect((try conditional.resolveContainerIn(a, &box, "")).unresolved);
        const overridden = try conditional.resolveContainerIn(a, &box, "height:3px!important");
        try std.testing.expect(!overridden.unresolved and overridden.style.screen_max_width == null);
        try std.testing.expectEqual(@as(f32, 3), overridden.style.height.?.value);
    }
    var base_important = try parseAlloc(a, ".box{height:4px!important}@media screen and (max-width:700px){.box{height:8px}}"); defer base_important.deinit();
    const same = try base_important.resolveContainerIn(a, &box, "");
    try std.testing.expect(!same.unresolved and same.style.screen_max_width == null);
    try std.testing.expectEqual(@as(f32, 4), same.style.height.?.value);
}

test "container NavHead fixed height does not grant relative positioning palette or inherited frame geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const frame: TextElement = .{ .tag = "div", .classes = "NavFrame", .ancestry_complete = true };
    const head: TextElement = .{ .tag = "div", .classes = "NavHead", .parent = &frame };
    var profile = try parseAlloc(a, "div.NavFrame div.NavHead{height:1.6em;font-weight:bold;font-size:100%;background-color:#efefef}"); defer profile.deinit();
    const selected = try profile.resolveContainerIn(a, &head, "");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, selected.style.height.?);
    try std.testing.expect(selected.style.line_height == null);
    try std.testing.expectEqualStrings("#efefef", selected.style.background.?.rgb);
    const child: TextElement = .{ .tag = "span", .parent = &head };
    const not_inherited = try profile.resolveContainerIn(a, &child, "");
    try std.testing.expect(!not_inherited.specified and !not_inherited.unresolved and not_inherited.style.height == null);
    const relative = try profile.resolveContainerIn(a, &head, "position:relative");
    try std.testing.expect(!relative.unresolved and relative.style.positioning == .relative_auto);
    try std.testing.expect((try profile.resolveContainerIn(a, &head, "position:absolute")).unresolved);
    try std.testing.expect((try profile.resolveContainerIn(a, &head, "background-color:var(--background-color-neutral,#EAECF0)")).unresolved);
    try std.testing.expect((try profile.resolveContainerIn(a, &head, "border-collapse:collapse")).unresolved);
    var incomplete = head;
    incomplete.parent = null;
    try std.testing.expect((try profile.resolveContainerIn(a, &incomplete, "")).unresolved);
}

test "explicit reading target selects only complete bare media types and preserves legacy unknown" {
    const a = std.testing.allocator;
    const css = "@media screen{.screen{display:none}}@MEDIA PRINT{.print{display:none}}@media all{.all{display:none}}";
    var legacy = try parseAlloc(a, css); defer legacy.deinit();
    try std.testing.expectEqual(ReadingTarget.unknown, legacy.reading_target);
    for ([_][]const u8{ "screen", "print", "all" }) |name| {
        var matches = legacy.displayRules("div", name, "");
        try std.testing.expect(matches.next().?.uncertain);
        try std.testing.expect(matches.next() == null);
    }
    for ([_]ReadingTarget{ .screen, .print }) |target| {
        var profile = try parseForTargetAlloc(a, css, target); defer profile.deinit();
        try std.testing.expectEqual(target, profile.reading_target);
        var included = profile.displayRules("div", @tagName(target), "");
        try std.testing.expect(!included.next().?.uncertain);
        try std.testing.expect(included.next() == null);
        var omitted = profile.displayRules("div", if (target == .screen) "print" else "screen", "");
        try std.testing.expect(omitted.next() == null);
        var all = profile.displayRules("div", "all", "");
        try std.testing.expect(!all.next().?.uncertain);
        try std.testing.expect(all.next() == null);
    }
}

test "reading target leaves compound width theme and modifier conditions uncertain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "screen and (max-width:719px)", "(max-width:719px)", "screen and (prefers-color-scheme:dark)", "screen,print", "not print", "only screen", "screen/**/", "speech" }) |query| {
        const css = try std.fmt.allocPrint(a, "@media {s}{{.x{{display:none}}}}", .{query});
        for ([_]ReadingTarget{ .screen, .print }) |target| {
            var profile = try parseForTargetAlloc(a, css, target); defer profile.deinit();
            var matches = profile.displayRules("div", "x", "");
            try std.testing.expect(matches.next().?.uncertain);
            try std.testing.expect(matches.next() == null);
        }
    }
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    const responsive = ".box{width:250px}@media screen{@media screen and (max-width:719px){.box{width:100%}}}";
    var screen = try parseForTargetAlloc(a, responsive, .screen); defer screen.deinit();
    const resolved = try screen.resolveContainerIn(a, &element, "");
    try std.testing.expect(!resolved.unresolved);
    try std.testing.expectEqual(@as(f32, 250), resolved.style.width.?.length.value);
    try std.testing.expectEqual(@as(u32, 719), resolved.style.screen_max_width.?.max_width_px);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, resolved.style.screen_max_width.?.width.?.length);
    var print = try parseForTargetAlloc(a, ".box{width:250px}@media screen and (max-width:719px){.box{width:100%}}", .print); defer print.deinit();
    try std.testing.expect((try print.resolveContainerIn(a, &element, "")).unresolved);
}

test "reading target nesting retains outer uncertainty rank and exact winner order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ordered = try parseSourcesForTargetAlloc(a, &.{
        .{ .css = ".x{text-align:left}@media screen{.x{text-align:right!important}}", .base_url = "https://example.test/first.css" },
        .{ .css = ".x{text-align:center}@media print{.x{all:initial!important}}", .base_url = "https://example.test/second.css" },
    }, .screen); defer ordered.deinit();
    const result = try ordered.resolveAlignment(a, "div", "x", "", null, "");
    try std.testing.expect(!result.unresolved and result.value.? == .right);
    try std.testing.expectEqual(@as(usize, 2), ordered.sources.len);
    try std.testing.expectEqualStrings("https://example.test/second.css", ordered.sources[1].base_url);
    const inline_result = try ordered.resolveAlignment(a, "div", "x", "", null, "text-align:left!important");
    try std.testing.expect(!inline_result.unresolved and inline_result.value.? == .left);
    for ([_][]const u8{
        "@supports(display:grid){@media screen{.x{display:none}}}",
        "@media (max-width:700px){@media all{.x{display:none}}}",
        "@media screen{.x:hover{display:none}}",
    }) |css| {
        var profile = try parseForTargetAlloc(a, css, .screen); defer profile.deinit();
        var matches = profile.displayRules("div", "x", "");
        try std.testing.expect(matches.next().?.uncertain);
    }
    var layer = try parseForTargetAlloc(a, "@layer x{@media screen{.x{width:20px!important}}}.x{width:10px!important}", .screen); defer layer.deinit();
    const element: TextElement = .{ .tag = "div", .classes = "x", .ancestry_complete = true };
    try std.testing.expect((try layer.resolveContainerIn(a, &element, "")).unresolved);
    var reset = try parseForTargetAlloc(a, "@media screen{.x{all:initial}}", .screen); defer reset.deinit();
    try std.testing.expect((try reset.resolveContainerIn(a, &element, "")).unresolved);
}

test "screen print nonmatch does not waive retained navigation geometry palette or line height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    // Complete print group from the retained German Common.css lines 155-169.
    const css = "@media print{.NavPic,.NavFrame,.NavToggle,.NavToggleAll,.NavToggleConfig,.BoxenVerschmelzen{display:none}.printNav .NavFrame,.printNav .NavContent{display:block!important}}";
    var legacy = try parseAlloc(a, css); defer legacy.deinit();
    var old = legacy.displayRules("div", "NavFrame", "");
    try std.testing.expect(old.next().?.uncertain);
    var screen = try parseForTargetAlloc(a, css, .screen); defer screen.deinit();
    var omitted = screen.displayRules("div", "NavFrame", "");
    try std.testing.expect(omitted.next() == null);
    const element: TextElement = .{ .tag = "div", .classes = "NavFrame", .ancestry_complete = true };
    for ([_][]const u8{
        "clear:both;padding:2px;border:1px solid var(--border-color-base,#AAAAAA);text-align:center;border-collapse:collapse;font-size:95%",
        "height:1.6em;font-weight:bold;font-size:100%;background-color:var(--background-color-neutral,#EAECF0);color:inherit",
        "line-height:var(--unknown)",
    }) |inline_css| try std.testing.expect((try screen.resolveContainerIn(a, &element, inline_css)).unresolved);
    const represented = try screen.resolveContainerIn(a, &element, "padding:2px;border:1px solid #aaaaaa;background:#eaecf0;line-height:1.6em");
    try std.testing.expect(!represented.unresolved);
    try std.testing.expectEqual(@as(f32, 2), represented.style.padding.?.top.value);
    try std.testing.expectEqual(@as(f32, 1), represented.style.border.?.solid.width.value);
    try std.testing.expectEqualStrings("#aaaaaa", represented.style.border.?.solid.color.rgb);
    try std.testing.expectEqualStrings("#eaecf0", represented.style.background.?.rgb);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, represented.style.line_height.?.length);
    var print = try parseForTargetAlloc(a, "", .print); defer print.deinit();
    try std.testing.expectError(error.InvalidStyleProfile, attachCustomProperties(&print, &.{.{ .css = ":root{--paint:red}", .base_url = "" }}, .{
        .dark = null, .ancestors = &.{.{ .tag = "html", .root = true }},
    }));
}


test "EL count columns retain default gap and ignore invalid percentage column widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const css = "width:100%; column-count:2; -webkit-column-count:2; -moz-column-count:2; column-width:50%; -webkit-column-width:50%; -moz-column-width:50%;";
    const selected = try resolveInlineContainerAlloc(a, css);
    try std.testing.expect(selected.specified and !selected.unresolved);
    try std.testing.expectEqual(types.ContainerColumns{ .count = 2, .gap = .{ .unit = .em, .value = 1 } }, selected.style.columns.?);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, selected.style.width.?.length);
    const invalid_after_auto = try resolveInlineContainerAlloc(a, "column-count:2;column-width:auto;column-width:50%!important");
    try std.testing.expect(!invalid_after_auto.unresolved and invalid_after_auto.style.columns.?.count == 2);
    const invalid_after_width = try resolveInlineContainerAlloc(a, "column-count:2;column-width:10em;column-width:50%!important");
    try std.testing.expect(invalid_after_width.unresolved);
    try std.testing.expect(!containerStyleEqual(types.ContainerStyle{}, selected.style));
}

test "count column winners preserve resets important and independent computed gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const box: TextElement = .{ .tag = "div", .classes = "box", .id = "owner", .ancestry_complete = true };
    var profile = try parseAlloc(a, "div{column-count:4}.box{column-count:3;column-gap:2em}#owner{column-count:2}"); defer profile.deinit();
    const selected = try profile.resolveContainerIn(a, &box, "column-gap:0px");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqual(types.ContainerColumns{ .count = 2, .gap = .{ .unit = .px, .value = 0 } }, selected.style.columns.?);
    var important = try parseAlloc(a, ".box{column-count:3!important}#owner{column-count:2}"); defer important.deinit();
    try std.testing.expectEqual(@as(u16, 3), (try important.resolveContainerIn(a, &box, "column-count:4")).style.columns.?.count);
    for ([_][]const u8{ "auto", "initial", "unset" }) |reset| {
        const value = try important.resolveContainerIn(a, &box, try std.fmt.allocPrint(a, "column-count:{s}!important", .{reset}));
        try std.testing.expect(!value.unresolved and value.style.columns == null);
    }
    const recovered = try resolveInlineContainerAlloc(a, "column-count:var(--unknown);column-count:2");
    try std.testing.expect(!recovered.unresolved and recovered.style.columns.?.count == 2);
    try std.testing.expect((try resolveInlineContainerAlloc(a, "column-count:var(--unknown)!important;column-count:2")).unresolved);
    const inherited_child: TextElement = .{ .tag = "span", .parent = &box };
    const child = try profile.resolveContainerIn(a, &inherited_child, "");
    try std.testing.expect(!child.unresolved and child.style.columns == null);
}

test "count column grammar ignores invalid numbers without converting unsupported valid widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "0", "-1", "2.5", "2e0", "10px", "20%" }) |invalid| {
        const selected = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "column-count:2;column-count:{s}!important", .{invalid}));
        try std.testing.expect(!selected.unresolved and selected.style.columns.?.count == 2);
    }
    for ([_][]const u8{ "1", "+2", "65535" }) |valid| {
        const selected = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "column-count:{s};column-gap:normal", .{valid}));
        try std.testing.expect(!selected.unresolved and selected.style.columns != null);
    }
    for ([_][]const u8{ "column-count:65536", "column-count:inherit", "column-count:calc(1 + 1)", "column-count:2;column-width:10em", "column-count:2;column-width:var(--w)", "column-count:2;column-gap:20%", "column-count:2;column-gap:var(--g)", "column-count:2;column-fill:auto" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
}

test "count columns retain conditional selector rank and absent parent uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const box: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    for ([_][]const u8{ ".box:hover{column-count:2}", "@media print{.box{column-count:2}}", "@media screen and (max-width:700px){.box{column-count:2}}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &box, "")).unresolved);
        const overridden = try profile.resolveContainerIn(a, &box, "column-count:3!important");
        try std.testing.expect(!overridden.unresolved and overridden.style.columns.?.count == 3 and overridden.style.screen_max_width == null);
    }
    var unrelated = try parseAlloc(a, ".other:hover{column-count:2}.box{column-count:3}"); defer unrelated.deinit();
    try std.testing.expect(!(try unrelated.resolveContainerIn(a, &box, "")).unresolved);
    var layer = try parseAlloc(a, "@layer a{.box{column-count:2}}"); defer layer.deinit();
    try std.testing.expect((try layer.resolveContainerIn(a, &box, "column-count:3!important")).unresolved);
    var missing_parent = try parseAlloc(a, "div.owner div.box{column-count:2}"); defer missing_parent.deinit();
    const unknown: TextElement = .{ .tag = "div", .classes = "box" };
    try std.testing.expect((try missing_parent.resolveContainerIn(a, &unknown, "")).unresolved);
}

test "count columns do not waive height flex scroll break or adjoining geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "column-count:2;height:0", "column-count:2;display:flex", "column-count:2;overflow:auto", "column-count:2;column-rule:1px solid red", "column-count:2;column-span:all", "column-count:2;break-inside:avoid", "all:initial;column-count:2", "column-count:2;position:relative" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
}


test "count column legacy aliases share real priority slots and preserve unsupported winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const later = try resolveInlineContainerAlloc(a, "column-count:2;-webkit-column-count:3;-moz-column-count:4");
    try std.testing.expect(later.unresolved);
    const important = try resolveInlineContainerAlloc(a, "column-count:2!important;-webkit-column-count:3");
    try std.testing.expect(!important.unresolved and important.style.columns.?.count == 2);
    const gap = try resolveInlineContainerAlloc(a, "column-count:2;-webkit-column-gap:3px;-moz-column-gap:4px");
    try std.testing.expect(gap.unresolved);
    const reset = try resolveInlineContainerAlloc(a, "column-count:2;-webkit-column-count:auto");
    try std.testing.expect(reset.unresolved);
    for ([_][]const u8{ "-webkit-column-width", "-moz-column-width" }) |name| {
        const unsupported = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "column-count:2;{s}:10em", .{name}));
        try std.testing.expect(unsupported.unresolved);
        const invalid = try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "column-count:2;{s}:50%", .{name}));
        try std.testing.expect(!invalid.unresolved and invalid.style.columns.?.count == 2);
    }
    for ([_][]const u8{ "-webkit-column-span:all", "-moz-column-rule:1px solid red", "-webkit-column-break-inside:avoid", "-moz-column-break-before:always" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, try std.fmt.allocPrint(a, "column-count:2;{s}", .{css}))).unresolved);
}

test "column source policy preflight conservatively retains inherited descendant and unknown declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    try std.testing.expect(!try hasColumnFragmentationDeclarationsAlloc(a, "font-size:95%;color:red;column-count:2;column-width:50%"));
    for ([_][]const u8{ "break-inside:avoid", "widows:3", "orphans:4", "column-span:all", "column-rule:1px solid red", "-webkit-column-break-after:always", "all:initial", "br\\65ak-inside:auto", "widows:initial" }) |css|
        try std.testing.expect(try hasColumnFragmentationDeclarationsAlloc(a, css));
    var clean = try parseAlloc(a, ".NavHead{font-weight:bold}div{color:red}"); defer clean.deinit();
    try std.testing.expect(try clean.columnFlowStylesheetPolicyAbsent(a));
    // In this first source domain even a potentially unrelated rule keeps the
    // policy unknown; own classes cannot prove every descendant's attributes.
    for ([_][]const u8{ "li{break-inside:avoid}", ".ancestor{widows:3}", ".other:hover{orphans:4}", "@media print{li{break-before:column}}" }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect(!try profile.columnFlowStylesheetPolicyAbsent(a));
    }
}


test "column aliases admit only engine independent winning semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const same = try resolveInlineContainerAlloc(a, "column-count:2;-webkit-column-count:2;-moz-column-count:2;column-width:50%;-webkit-column-width:50%;-moz-column-width:50%");
    try std.testing.expect(!same.unresolved and same.style.columns.?.count == 2);
    const gap = try resolveInlineContainerAlloc(a, "column-count:2;column-gap:4px;-webkit-column-gap:4px;-moz-column-gap:4px");
    try std.testing.expect(!gap.unresolved and gap.style.columns.?.gap.value == 4);
    const important = try resolveInlineContainerAlloc(a, "column-count:2!important;-webkit-column-count:3;-moz-column-count:4");
    try std.testing.expect(!important.unresolved and important.style.columns.?.count == 2);
    const shadow = try resolveInlineContainerAlloc(a, "column-count:2;-webkit-column-count:2!important;column-count:3");
    try std.testing.expect(shadow.unresolved);
    const only_alias = try resolveInlineContainerAlloc(a, "-webkit-column-count:2");
    try std.testing.expect(only_alias.unresolved);
    const reset = try resolveInlineContainerAlloc(a, "column-count:auto;-webkit-column-count:auto;-moz-column-count:auto");
    try std.testing.expect(!reset.unresolved and reset.style.columns == null);
    const box: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var profile = try parseAlloc(a, ".box{column-count:2}.box{-webkit-column-count:3}"); defer profile.deinit();
    try std.testing.expect((try profile.resolveContainerIn(a, &box, "")).unresolved);
    const inline_restore = try profile.resolveContainerIn(a, &box, "column-count:2!important");
    try std.testing.expect(!inline_restore.unresolved and inline_restore.style.columns.?.count == 2);
}

test "column descendant source policy includes nested column families and aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "column-count:3", "column-width:10em", "column-gap:3px", "columns:2", "-webkit-column-count:3", "-moz-column-width:10em", "-webkit-column-gap:3px" }) |css| {
        try std.testing.expect(try hasColumnDescendantDeclarationsAlloc(a, css));
        try std.testing.expect(!try hasColumnFragmentationDeclarationsAlloc(a, css));
    }
    try std.testing.expect(!try hasColumnDescendantDeclarationsAlloc(a, "color:red;font-size:95%"));
    var nested = try parseAlloc(a, "li{column-count:3}"); defer nested.deinit();
    try std.testing.expect(!try nested.columnFlowStylesheetPolicyAbsent(a));
}
// A source-side conservative refusal, never a reader CSS interpreter. Values
// listed here cannot create an intervening stack/clip/layout context. Every
// unrepresented or unknown candidate is retained even if a later rule might
// override it; no source-context absence is guessed from a text-style getter.
pub fn hasRelativeContextDeclarationsAlloc(a: std.mem.Allocator, css: []const u8) std.mem.Allocator.Error!bool {
    if (css.len > max_css_bytes) return true;
    var pos: usize = 0;
    declarations: while (try nextDeclarationAlloc(a, css, &pos)) |raw| {
        defer a.free(raw);
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = trim(raw[0..colon]);
        const parsed = customPriority(raw[colon + 1 ..]); const value = trim(parsed.value);
        if (std.mem.indexOfScalar(u8, name, '\\') != null or std.ascii.eqlIgnoreCase(name, "all")) return true;
        const reset = std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset");
        if (std.ascii.eqlIgnoreCase(name, "position")) {
            if (parsed.unknown or (!reset and !std.ascii.eqlIgnoreCase(value, "static") and !std.ascii.eqlIgnoreCase(value, "relative"))) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "z-index")) {
            if (parsed.unknown or (!reset and !std.ascii.eqlIgnoreCase(value, "auto"))) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "pointer-events")) {
            if (parsed.unknown or (!std.ascii.eqlIgnoreCase(value, "auto") and !std.ascii.eqlIgnoreCase(value, "initial"))) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "visibility")) {
            if (parsed.unknown or (!std.ascii.eqlIgnoreCase(value, "visible") and !std.ascii.eqlIgnoreCase(value, "initial"))) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "opacity")) {
            if (parsed.unknown) return true;
            if (reset) continue;
            if (!widthNumberSyntax(value)) return true;
            const factor = std.fmt.parseFloat(f64, value) catch return true;
            if (factor != 1) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "overflow") or std.ascii.eqlIgnoreCase(name, "overflow-x") or std.ascii.eqlIgnoreCase(name, "overflow-y")) {
            if (parsed.unknown or (!reset and !std.ascii.eqlIgnoreCase(value, "visible"))) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "display")) {
            if (parsed.unknown) return true;
            if (reset) continue;
            var ordinary = false;
            inline for (.{ "block", "inline", "inline-block", "table", "inline-table", "table-cell", "table-row", "table-row-group", "list-item", "none" }) |known|
                ordinary = ordinary or std.ascii.eqlIgnoreCase(value, known);
            if (!ordinary) return true;
            continue;
        }
        inline for (.{ "transform", "translate", "rotate", "scale", "filter", "backdrop-filter", "perspective", "clip-path", "mask", "mask-image", "contain", "view-transition-name", "animation", "animation-name" }) |property| {
            if (std.ascii.eqlIgnoreCase(name, property)) {
                if (parsed.unknown or (!reset and !std.ascii.eqlIgnoreCase(value, "none"))) return true;
                continue :declarations;
            }
        }
        inline for (.{ "isolation", "clip", "will-change" }, .{ "auto", "auto", "auto" }) |property, ordinary| {
            if (std.ascii.eqlIgnoreCase(name, property)) {
                if (parsed.unknown or (!reset and !std.ascii.eqlIgnoreCase(value, ordinary))) return true;
                continue :declarations;
            }
        }
        inline for (.{ "mix-blend-mode", "container-type", "content-visibility" }, .{ "normal", "normal", "visible" }) |property, ordinary| {
            if (std.ascii.eqlIgnoreCase(name, property)) {
                if (parsed.unknown or (!reset and !std.ascii.eqlIgnoreCase(value, ordinary))) return true;
                continue :declarations;
            }
        }
        // Longhands/future effects are not silently flattened into root paint.
        if (std.ascii.startsWithIgnoreCase(name, "-webkit-transform") or std.ascii.startsWithIgnoreCase(name, "-moz-transform") or
            std.ascii.startsWithIgnoreCase(name, "-webkit-filter") or std.ascii.startsWithIgnoreCase(name, "-webkit-backdrop-filter") or
            std.ascii.startsWithIgnoreCase(name, "-webkit-perspective") or std.ascii.startsWithIgnoreCase(name, "-webkit-mask") or
            std.ascii.eqlIgnoreCase(name, "zoom")) return true;
        if (std.ascii.startsWithIgnoreCase(name, "transform-") or std.ascii.startsWithIgnoreCase(name, "mask-") or
            std.ascii.startsWithIgnoreCase(name, "animation-") or std.ascii.startsWithIgnoreCase(name, "column") or
            std.ascii.startsWithIgnoreCase(name, "-webkit-column-") or std.ascii.startsWithIgnoreCase(name, "-moz-column-")) return true;
    }
    return false;
}

fn relativeAutoInsets(value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "unset")) return true;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c"); var count: usize = 0;
    while (tokens.next()) |token| {
        count += 1; if (count > 4 or !std.ascii.eqlIgnoreCase(token, "auto")) return false;
    }
    return count != 0;
}


test "relative auto requires winning auto offsets and z index while static resets remain explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    const node: TextElement = .{ .tag = "div", .ancestry_complete = true };
    const good = try profile.resolveContainerIn(a, &node, "position:relative;height:1.6em;top:auto;right:auto;bottom:auto;left:auto;z-index:auto");
    try std.testing.expect(!good.unresolved and good.positioning_specified);
    try std.testing.expectEqual(types.ContainerPositioning.relative_auto, good.style.positioning.?);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, good.style.height.?);
    for ([_][]const u8{ "static", "initial", "unset" }) |reset| {
        const css = try std.fmt.allocPrint(a, "position:relative;position:{s}", .{reset});
        const selected = try profile.resolveContainerIn(a, &node, css);
        try std.testing.expect(!selected.unresolved and selected.positioning_specified and selected.style.positioning == null);
    }
    for ([_][]const u8{ "position:absolute", "position:fixed", "position:sticky", "position:var(--unknown)", "position:relative;top:0", "position:relative;inset:0", "position:relative;z-index:0", "position:relative;z-index:inherit", "position:relative;left:var(--unknown)", "position:relative;inset:auto auto auto auto auto" }) |css| {
        errdefer std.debug.print("RELATIVE_PROFILE refusal css={s}\n", .{css});
        try std.testing.expect((try profile.resolveContainerIn(a, &node, css)).unresolved);
    }
    for ([_][]const u8{ "position:relative;left:1px;inset:auto", "position:relative;inset:1px;inset:auto auto auto auto", "position:absolute;position:relative!important", "position:relative;z-index:4;z-index:auto" }) |css|
        try std.testing.expect(!(try profile.resolveContainerIn(a, &node, css)).unresolved);
    try std.testing.expect((try profile.resolveContainerIn(a, &node, "position:relative;left:1px!important;inset:auto")).unresolved);
}

test "relative NavHead style retains real parent matching and conditional positioning remains refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, "div.NavFrame div.NavHead{height:1.6em;position:relative;background-color:#efefef}a.NavToggle{position:absolute;top:0;right:3px}"); defer profile.deinit();
    const frame: TextElement = .{ .tag = "div", .classes = "NavFrame", .ancestry_complete = true };
    const head: TextElement = .{ .tag = "div", .classes = "NavHead", .parent = &frame };
    const selected = try profile.resolveContainerIn(a, &head, "");
    try std.testing.expect(!selected.unresolved and selected.style.positioning == .relative_auto);
    try std.testing.expect(!try profile.relativeContextPolicyPresentIn(a, &head, ""));
    try std.testing.expectEqualStrings("#efefef", selected.style.background.?.rgb);
    var incomplete = head; incomplete.parent = null;
    try std.testing.expect((try profile.resolveContainerIn(a, &incomplete, "")).unresolved);
    var conditional = try parseAlloc(a, "@media screen and (max-width:700px){div{position:relative}}"); defer conditional.deinit();
    try std.testing.expect((try conditional.resolveContainerIn(a, &frame, "")).unresolved);
    var important = try parseAlloc(a, "div{position:absolute}.NavHead{position:relative!important}"); defer important.deinit();
    try std.testing.expect(!(try important.resolveContainerIn(a, &head, "position:absolute")).unresolved);
    try std.testing.expect((try important.resolveContainerIn(a, &head, "position:absolute!important")).unresolved);
}

test "relative context policy proves only noncreating defaults and retains possible ancestor contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "", "position:relative;z-index:auto", "opacity:1;transform:none;translate:none;rotate:none;scale:none;filter:none;overflow:visible", "isolation:auto;clip:auto;mix-blend-mode:normal;contain:none", "display:table-cell;pointer-events:auto;visibility:visible" }) |css|
        try std.testing.expect(!try hasRelativeContextDeclarationsAlloc(a, css));
    for ([_][]const u8{ "opacity:.9", "opacity:var(--unknown)", "transform:translateX(0)", "translate:0px", "rotate:0deg", "scale:1", "translate:var(--unknown)", "filter:blur(0)", "isolation:isolate", "overflow:hidden", "clip:rect(0,1px,1px,0)", "z-index:0", "position:absolute", "display:flex", "pointer-events:none", "visibility:hidden", "-webkit-transform:none", "mask-image:url(x)", "all:initial", "column-count:2" }) |css| {
        errdefer std.debug.print("RELATIVE_CONTEXT refusal css={s}\n", .{css});
        try std.testing.expect(try hasRelativeContextDeclarationsAlloc(a, css));
    }
    var profile = try parseAlloc(a, ".scope{opacity:.5}.other{transform:translateX(0)}"); defer profile.deinit();
    const clean: TextElement = .{ .tag = "div", .classes = "clean", .ancestry_complete = true };
    const creating: TextElement = .{ .tag = "div", .classes = "scope", .ancestry_complete = true };
    try std.testing.expect(!try profile.relativeContextPolicyPresentIn(a, &clean, ""));
    try std.testing.expect(try profile.relativeContextPolicyPresentIn(a, &creating, ""));
    var possible = try parseAlloc(a, ".unknown div{opacity:.5}"); defer possible.deinit();
    const unknown: TextElement = .{ .tag = "div" };
    try std.testing.expect(try possible.relativeContextPolicyPresentIn(a, &unknown, ""));
}

test "container custom paint uses inherited known tokens and exact element overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--panel:#123456;--edge:#A2A9B1}.local{--panel:#abcdef!important}"); defer tokens.deinit();
    var profile = try parseAlloc(a, ".box{background:var(--panel,#f9f9f9);border:var(--edge,#aaa)1px solid;padding:4px}"); defer profile.deinit();
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    const custom = tokens.custom_properties.?;
    const parent = custom.root_environment;
    const actual = try profile.resolveContainerInWithCustom(a, &element, "", parent);
    try std.testing.expect(actual.specified and !actual.unresolved);
    try std.testing.expectEqualStrings("#123456", actual.style.background.?.rgb);
    try std.testing.expectEqualStrings("#a2a9b1", actual.style.border.?.solid.color.rgb);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 1 }, actual.style.border.?.solid.width);
    try std.testing.expectEqual(types.StyleEdges.all(.{ .unit = .px, .value = 4 }), actual.style.padding.?);
    const child = try custom.element(a, parent, .{ .tag = "div", .classes = "local" }, "--panel:#fedcba");
    const overridden = try profile.resolveContainerInWithCustom(a, &element, "", child);
    try std.testing.expect(!overridden.unresolved);
    try std.testing.expectEqualStrings("#abcdef", overridden.style.background.?.rgb);
    try CustomPropertyFixture.known(parent, "--panel", "#123456");
    const important = try custom.element(a, parent, .{ .tag = "div", .classes = "local" }, "--panel:#fedcba!important");
    const inline_selected = try profile.resolveContainerInWithCustom(a, &element, "", important);
    try std.testing.expect(!inline_selected.unresolved);
    try std.testing.expectEqualStrings("#fedcba", inline_selected.style.background.?.rgb);
    try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
}

test "container custom border preserves balanced function component and scalar roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--edge:rgb(1,2,3);--clear:transparent}"); defer tokens.deinit();
    const environment = tokens.custom_properties.?.root_environment;
    const values = [_][]const u8{ "var(--edge,#aaa)1px solid", "solid var(--edge) 2px", "3px solid var(--edge,var(--absent))" };
    for (values, 0..) |value, index| {
        const border = (try containerBorderWithCustomAlloc(a, value, environment)).?;
        try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = @floatFromInt(index + 1) }, border.solid.width);
        try std.testing.expectEqualStrings("#010203", border.solid.color.rgb);
    }
    const transparent = (try containerBorderWithCustomAlloc(a, "var(--clear)0.5em solid", environment)).?;
    try std.testing.expect(transparent.solid.color == .transparent);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 0.5 }, transparent.solid.width);
    for ([_][]const u8{
        "var(--edge)1px solid red", "var(--edge)1pxsolid", "1pxsolid var(--edge)",
        "solidvar(--edge) 1px", "var(--edge) solid var(--edge)", "var(--edge)1px dashed",
        "var(--edge,#aaa 1px solid", "var(--edge,'unterminated) 1px solid", "calc(var(--edge))1px solid",
        "var(--edge)1px solid!important", "var(--edge)1px solid/blue", "var(--edge)1px solid;",
    }) |value| try std.testing.expect((try containerBorderWithCustomAlloc(a, value, environment)) == null);
}

test "container custom paint refuses absent incomplete dynamic and cyclic bindings without fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a,
        ":root{--good:#123456;--self:var(--self,#abcdef);--a:var(--b);--b:var(--a);--empty:initial;--dynamic:light-dark(red,blue);--current:currentColor;--length:12px}"); defer tokens.deinit();
    const environment = tokens.custom_properties.?.root_environment;
    try std.testing.expect(environment.get("--self") == .invalid and environment.get("--a") == .invalid and environment.get("--b") == .invalid);
    for ([_][]const u8{ "--absent", "--self", "--a", "--b", "--empty", "--dynamic", "--current", "--length" }) |name| {
        const value = try std.fmt.allocPrint(a, "var({s},#abcdef)", .{name});
        try std.testing.expect((try containerColorWithCustomAlloc(a, value, environment, true)) == null);
    }
    const incomplete: CustomEnvironment = .{ .values = environment.values, .complete = false };
    try std.testing.expect((try containerColorWithCustomAlloc(a, "var(--good,#abcdef)", incomplete, true)) == null);
    try std.testing.expect((try containerColorWithCustomAlloc(a, "var(--good,#abcdef)", null, true)) == null);
    const unknown: CustomEnvironment = .{ .complete = true, .values = &.{.{ .name = "--good", .value = .unknown }} };
    try std.testing.expect((try containerColorWithCustomAlloc(a, "var(--good,#abcdef)", unknown, true)) == null);
    const literal = (try containerColorWithCustomAlloc(a, "#abcdef", incomplete, false)).?;
    try std.testing.expectEqualStrings("#abcdef", literal.rgb);
    // Existing callers retain the CSS fallback distinction; the new container
    // admission must not redefine CustomEnvironment or customColorValue.
    try std.testing.expectEqualStrings("#abcdef", (try customColorValue(a, environment, "var(--absent,#abcdef)")).known);
}

test "container variable paint obeys winning priority without erasing unknown background context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--paint:#123456;--edge:#654321}"); defer tokens.deinit();
    const environment = tokens.custom_properties.?.root_environment;
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var losing = try parseAlloc(a, ".box{background:var(--absent);border:var(--absent)1px solid}.box{background:var(--paint);border:var(--edge)2px solid}"); defer losing.deinit();
    const selected = try losing.resolveContainerInWithCustom(a, &element, "", environment);
    try std.testing.expect(!selected.unresolved);
    try std.testing.expectEqualStrings("#123456", selected.style.background.?.rgb);
    try std.testing.expectEqualStrings("#654321", selected.style.border.?.solid.color.rgb);
    try std.testing.expectEqual(@as(f32, 2), selected.style.border.?.solid.width.value);
    var important = try parseAlloc(a, ".box{background:var(--absent)!important}.box{background:var(--paint)}"); defer important.deinit();
    try std.testing.expect((try important.resolveContainerInWithCustom(a, &element, "background:var(--paint)", environment)).unresolved);
    const fixed = try important.resolveContainerInWithCustom(a, &element, "background:var(--paint)!important", environment);
    try std.testing.expect(!fixed.unresolved);
    try std.testing.expectEqualStrings("#123456", fixed.style.background.?.rgb);
    var image = try parseAlloc(a, ".box{background:url(image.png);background-color:var(--paint)}"); defer image.deinit();
    try std.testing.expect((try image.resolveContainerInWithCustom(a, &element, "", environment)).unresolved);
    try std.testing.expect(!(try image.resolveContainerInWithCustom(a, &element, "background:var(--paint)", environment)).unresolved);
}

test "container custom environment is identical across base and represented breakpoint cascades" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--paint:#123456;--edge:#654321}"); defer tokens.deinit();
    const environment = tokens.custom_properties.?.root_environment;
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var profile = try parseAlloc(a, ".box{background:var(--paint);border:var(--edge)1px solid;width:250px}@media screen and (max-width:719px){.box{width:100%;max-width:100%;box-sizing:border-box;line-height:1.5}}"); defer profile.deinit();
    const actual = try profile.resolveContainerInWithCustom(a, &element, "", environment);
    try std.testing.expect(!actual.unresolved);
    try std.testing.expectEqualStrings("#123456", actual.style.background.?.rgb);
    try std.testing.expectEqualStrings("#654321", actual.style.border.?.solid.color.rgb);
    try std.testing.expectEqual(@as(f32, 250), actual.style.width.?.length.value);
    const narrow = actual.style.screen_max_width.?;
    try std.testing.expectEqual(@as(u32, 719), narrow.max_width_px);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, narrow.width.?.length);
    try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, narrow.max_width.?.length);
    try std.testing.expectEqual(types.ContainerBoxSizing.border_box, narrow.box_sizing.?);
    try std.testing.expectEqual(@as(f32, 1.5), narrow.line_height.?.multiplier);
    var conditional_paint = try parseAlloc(a, ".box{background:var(--paint)}@media screen and (max-width:719px){.box{background:var(--edge)}}"); defer conditional_paint.deinit();
    try std.testing.expect((try conditional_paint.resolveContainerInWithCustom(a, &element, "", environment)).unresolved);
    try std.testing.expect(!(try conditional_paint.resolveContainerInWithCustom(a, &element, "background:var(--paint)!important", environment)).unresolved);
}

test "container custom paint consumes generic observed day tokens without root or font inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseForTargetAlloc(a, ".box{background:var(--wikt-palette-paleblue,#f9f9f9);border:var(--border-color-base,#aaa)1px solid}", .screen); defer profile.deinit();
    try attachCustomProperties(&profile, &.{.{ .css =
        ":root,.skin-invert,.notheme{--wikt-palette-paleblue:#f8f9fa}@media screen{:root,.skin-invert,.notheme{--border-color-base:#a2a9b1}html.skin-theme-clientpref-night{--border-color-base:#72777d;--wikt-palette-paleblue:#1c2229}}@media screen and (prefers-color-scheme:dark){html.skin-theme-clientpref-os{--border-color-base:#72777d;--wikt-palette-paleblue:#1c2229}}",
        .base_url = "https://example.invalid/observed.css" }}, .{ .dark = null,
        .ancestors = &.{ .{ .tag = "html", .classes = "skin-theme-clientpref-day", .root = true }, .{ .tag = "body" } } });
    const environment = profile.custom_properties.?.root_environment;
    try CustomPropertyFixture.known(environment, "--wikt-palette-paleblue", "#f8f9fa");
    try CustomPropertyFixture.known(environment, "--border-color-base", "#a2a9b1");
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    const actual = try profile.resolveContainerInWithCustom(a, &element, "", environment);
    try std.testing.expect(!actual.unresolved);
    try std.testing.expectEqualStrings("#f8f9fa", actual.style.background.?.rgb);
    try std.testing.expectEqualStrings("#a2a9b1", actual.style.border.?.solid.color.rgb);
    try std.testing.expect(actual.style.float_side == null and actual.style.clear == null and actual.style.margins == null);
    try std.testing.expect(actual.style.line_height == null);
    // This controlled complete ancestor path is not the incomplete actual skin
    // path; the old caller remains unresolved without an attached environment.
    try std.testing.expect((try profile.resolveContainerIn(a, &element, "")).unresolved);
}

test "container literal callers and unsupported numeric or theme values keep their old scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--length:40px;--height:1.5;--paint:#123456}"); defer tokens.deinit();
    const environment = tokens.custom_properties.?.root_environment;
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    var literal = try parseAlloc(a, ".box{width:40px;background:transparent;border:2px solid #abc;text-align:left}"); defer literal.deinit();
    const old = try literal.resolveContainerIn(a, &element, "");
    const with_environment = try literal.resolveContainerInWithCustom(a, &element, "", environment);
    try std.testing.expect(!old.unresolved and !with_environment.unresolved);
    try std.testing.expect(containerStyleEqual(old.style, with_environment.style));
    for ([_][]const u8{ "width:var(--length)", "line-height:var(--height)", "background:light-dark(red,blue)", "background:currentColor", "background:var(--paint) url(image.png)", "all:unset;background:var(--paint)" }) |css| {
        const actual = try literal.resolveContainerInWithCustom(a, &element, css, environment);
        try std.testing.expect(actual.unresolved);
    }
}

test "table and cell palette resolves only a complete element environment with unchanged cascade priority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--base:#ffffff;--panel:var(--base);--edge:#a2a9b1;--ink:#202122}.local{--panel:#abcdef}"); defer tokens.deinit();
    const custom = tokens.custom_properties.?;
    const environment = try custom.element(a, custom.root_environment, .{ .tag = "table", .classes = "local" }, "");
    var profile = try parseAlloc(a, ".paint{background-color:var(--panel,#010203);border:1px solid var(--edge,#aaa)}.paint{background-color:var(--panel)}.cell{background:var(--panel);border:var(--edge)2px solid;color:var(--ink)}"); defer profile.deinit();
    const context: ElementContext = .{ .ancestor_classes = "", .own_id = "", .custom_environment = environment };
    const table = try profile.resolveTableWithContext(a, 0, "paint", context, null, "");
    try std.testing.expect(!table.unresolved);
    try std.testing.expectEqualStrings("#abcdef", table.style.?.background.?);
    try std.testing.expectEqualStrings("#a2a9b1", table.style.?.border.?.solid.color);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 1 }, table.style.?.border.?.solid.width);
    const node: TextElement = .{ .tag = "td", .classes = "cell", .ancestry_complete = true };
    const paint = try profile.resolveTextPaintWithCustom(a, &node, "", environment);
    try std.testing.expectEqualStrings("#202122", paint.color.?.value);
    var cell_context = context;
    cell_context.text_color_consumed = paint.color.? == .value;
    const cell = try profile.resolveCellWithContextAndHints(a, 0, 0, "cell", cell_context, false, null, null, "");
    try std.testing.expect(!cell.unresolved);
    try std.testing.expectEqualStrings("#abcdef", cell.background.?);
    try std.testing.expectEqualStrings("#a2a9b1", cell.style.?.border.?.solid.color);
    try std.testing.expect((try profile.resolveTextPaint(a, &node, "")).color.? == .unknown);
    const inline_win = try profile.resolveTableWithContext(a, 0, "paint", context, null, "background:#123456!important;border:3px solid #654321!important");
    try std.testing.expect(!inline_win.unresolved);
    try std.testing.expectEqualStrings("#123456", inline_win.style.?.background.?);
    try std.testing.expectEqualStrings("#654321", inline_win.style.?.border.?.solid.color);
    var important = try parseAlloc(a, ".paint{background:var(--absent)!important}.paint{background:var(--panel)}"); defer important.deinit();
    try std.testing.expect((try important.resolveTableWithContext(a, 0, "paint", context, null, "background:var(--panel)")).unresolved);
    try std.testing.expect(!(try important.resolveTableWithContext(a, 0, "paint", context, null, "background:var(--panel)!important")).unresolved);
    try std.testing.expect((try profile.resolveTableWithContext(a, 0, "paint", .{ .ancestor_classes = "", .own_id = "" }, null, "")).unresolved);
}

test "table and text palette keeps absent cyclic incomplete conditional and image contexts unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--good:#123456;--self:var(--self,#abcdef);--dynamic:light-dark(red,blue);--clear:transparent}"); defer tokens.deinit();
    const complete = tokens.custom_properties.?.root_environment;
    const environments = [_]?CustomEnvironment{ null, .{ .values = complete.values, .complete = false }, .{ .complete = true } };
    for (environments) |environment| {
        var profile = try parseAlloc(a, ".paint{background:var(--good,#abcdef);border:1px solid var(--good,#abcdef);color:var(--good,#abcdef)}"); defer profile.deinit();
        const table = try profile.resolveTableWithContext(a, 0, "paint", .{ .ancestor_classes = "", .own_id = "", .custom_environment = environment }, null, "");
        try std.testing.expect(table.unresolved and (table.style == null or (table.style.?.background == null and table.style.?.border == null)));
        const node: TextElement = .{ .tag = "table", .classes = "paint", .ancestry_complete = true };
        try std.testing.expect((try profile.resolveTextPaintWithCustom(a, &node, "", environment)).color.? == .unknown);
    }
    for ([_][]const u8{ "--absent", "--self", "--dynamic", "--clear" }) |name| {
        const css = try std.fmt.allocPrint(a, ".paint{{background:var({s},#abcdef);border:1px solid var({s},#abcdef);color:var({s},#abcdef)}}", .{ name, name, name });
        var profile = try parseAlloc(a, css); defer profile.deinit();
        const table = try profile.resolveTableWithContext(a, 0, "paint", .{ .ancestor_classes = "", .own_id = "", .custom_environment = complete }, null, "");
        try std.testing.expect(table.unresolved);
    }
    for ([_][]const u8{
        "@media screen and (max-width:700px){.paint{background:var(--good)}}",
        ".paint:hover{background:var(--good)}",
        ".paint{background-image:var(--good)}",
        ".paint{background:var(--good);all:unset}",
    }) |css| {
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveTableWithContext(a, 0, "paint", .{ .ancestor_classes = "", .own_id = "", .custom_environment = complete }, null, "")).unresolved);
    }
}

test "computed border collapse inherits through actual elements and preserves exact own priority and resets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var sheet = try parseAlloc(a, ".frame{border-collapse:collapse}.middle{border-collapse:inherit}.reset{border-collapse:initial}.strong{border-collapse:separate!important}.tie{border-collapse:collapse}.tie{border-collapse:separate}"); defer sheet.deinit();
    const frame: TextElement = .{ .tag = "div", .classes = "frame" };
    const middle: TextElement = .{ .tag = "div", .classes = "middle", .parent = &frame };
    const table: TextElement = .{ .tag = "table", .parent = &middle };
    const parent = try sheet.resolveBorderCollapseIn(a, &frame, "", null);
    try std.testing.expectEqual(BorderCollapseState.collapse, parent.?);
    const inherited = try sheet.resolveBorderCollapseIn(a, &middle, "", parent);
    try std.testing.expectEqual(parent, inherited);
    try std.testing.expectEqual(parent, try sheet.resolveBorderCollapseIn(a, &table, "", inherited));
    try std.testing.expectEqual(BorderCollapseState.separate, (try sheet.resolveBorderCollapseIn(a, &table, "border-collapse:initial", inherited)).?);
    try std.testing.expectEqual(parent, try sheet.resolveBorderCollapseIn(a, &table, "border-collapse:unset", inherited));
    const strong: TextElement = .{ .tag = "table", .classes = "strong", .parent = &middle };
    try std.testing.expectEqual(BorderCollapseState.separate, (try sheet.resolveBorderCollapseIn(a, &strong, "border-collapse:collapse", inherited)).?);
    try std.testing.expectEqual(BorderCollapseState.collapse, (try sheet.resolveBorderCollapseIn(a, &strong, "border-collapse:collapse!important", inherited)).?);
    const tie: TextElement = .{ .tag = "table", .classes = "tie" };
    try std.testing.expectEqual(BorderCollapseState.separate, (try sheet.resolveBorderCollapseIn(a, &tie, "", null)).?);
    try std.testing.expectEqual(BorderCollapseState.collapse, (try resolveInlineBorderCollapseAlloc(a, "border-collapse:collapse;border-collapse:nonsense", null)).?);
    try std.testing.expect((try resolveInlineBorderCollapseAlloc(a, "", null)) == null);
}

test "computed border collapse keeps unknown parent conditional selector and reset authority unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "frame" };
    for ([_][]const u8{ "border-collapse:inherit", "border-collapse:unset", "border-collapse:var(--model)", "border-collapse:revert", "border-collapse:revert-layer", "border\\2d collapse:collapse" }) |css|
        try std.testing.expectEqual(BorderCollapseState.unknown, (try resolveInlineBorderCollapseAlloc(a, css, null)).?);
    for ([_][]const u8{
        ".frame{border-collapse:collapse}@media (max-width:500px){.frame{border-collapse:separate}}",
        ".frame{border-collapse:collapse}.frame:future-state{border-collapse:separate}",
        ".frame{border-collapse:collapse}@layer order{.frame{border-collapse:separate}}",
    }) |css| {
        var sheet = try parseAlloc(a, css); defer sheet.deinit();
        try std.testing.expectEqual(BorderCollapseState.unknown, (try sheet.resolveBorderCollapseIn(a, &element, "", null)).?);
    }
    var sheet = try parseAlloc(a, ".frame{border-collapse:collapse!important}@media (max-width:500px){.frame{border-collapse:separate}}"); defer sheet.deinit();
    try std.testing.expectEqual(BorderCollapseState.collapse, (try sheet.resolveBorderCollapseIn(a, &element, "", null)).?);
    try std.testing.expectEqual(BorderCollapseState.unknown, (try resolveInlineBorderCollapseAlloc(a, "all:revert", .collapse)).?);
    try std.testing.expectEqual(BorderCollapseState.separate, (try resolveInlineBorderCollapseAlloc(a, "all:initial", .collapse)).?);
}

test "computed border collapse projects only its existing table slot and leaves legacy or unrelated refusals intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var sheet = try parseAlloc(a, ""); defer sheet.deinit();
    const element: TextElement = .{ .tag = "div" };
    const css = "width:fit-content;border-collapse:collapse";
    try std.testing.expect((try sheet.resolveContainerIn(a, &element, css)).unresolved);
    try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    try std.testing.expect(!(try sheet.resolveContainerInWithInheritance(a, &element, css, null, true)).unresolved);
    try std.testing.expect(!(try resolveInlineContainerWithInheritanceAlloc(a, css, true)).unresolved);
    try std.testing.expect((try sheet.resolveContainerInWithInheritance(a, &element, "border-collapse:collapse;border-spacing:3px", null, true)).unresolved);
    const inherited = try sheet.resolveTableWithContext(a, 0, "", .{ .computed_border_collapse = .collapse }, null, "width:24px;padding:2px");
    try std.testing.expect(!inherited.unresolved);
    try std.testing.expectEqual(types.BorderCollapse.collapse, inherited.style.?.collapse.?);
    try std.testing.expectEqual(@as(f32, 24), inherited.style.?.width.?.value);
    const unknown = try sheet.resolveTableWithContext(a, 0, "", .{ .computed_border_collapse = .unknown }, null, "width:24px;padding:2px");
    try std.testing.expect(unknown.unresolved and unknown.style.?.collapse == null and unknown.style.?.padding == null);
    try std.testing.expectEqual(@as(f32, 24), unknown.style.?.width.?.value);
    const inline_table = try resolveInlineTableWithCollapseAlloc(a, "border-collapse:inherit", .collapse);
    try std.testing.expect(!inline_table.unresolved and inline_table.style.?.collapse.? == .collapse);
    try std.testing.expect((try resolveInlineTableAlloc(a, "border-collapse:inherit")).unresolved);
    const cell = try sheet.resolveCellWithContext(a, 0, 0, "", .{ .computed_border_collapse = .collapse }, false, null, "border-collapse:inherit;padding:3px");
    try std.testing.expect(!cell.unresolved and cell.style.?.padding.?.left.value == 3);
    try std.testing.expect((try sheet.resolveCellWithContext(a, 0, 0, "", .{}, false, null, "border-collapse:inherit;padding:3px")).unresolved);
}


test "computed border collapse preserves possible important ancestors until the actual chain is complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var sheet = try parseAlloc(a, ".ancestor table{border-collapse:separate!important}"); defer sheet.deinit();
    const unknown: TextElement = .{ .tag = "table" };
    try std.testing.expectEqual(BorderCollapseState.unknown, (try sheet.resolveBorderCollapseIn(a, &unknown, "border-collapse:collapse", .collapse)).?);
    const complete_absence: TextElement = .{ .tag = "table", .ancestry_complete = true };
    try std.testing.expectEqual(BorderCollapseState.collapse, (try sheet.resolveBorderCollapseIn(a, &complete_absence, "border-collapse:collapse", .collapse)).?);
    const ancestor: TextElement = .{ .tag = "div", .classes = "ancestor", .ancestry_complete = true };
    const present: TextElement = .{ .tag = "table", .parent = &ancestor };
    try std.testing.expectEqual(BorderCollapseState.separate, (try sheet.resolveBorderCollapseIn(a, &present, "border-collapse:collapse", .collapse)).?);
    try std.testing.expectEqual(BorderCollapseState.collapse, (try sheet.resolveBorderCollapseIn(a, &unknown, "border-collapse:collapse!important", .collapse)).?);
    try std.testing.expect(try hasBorderCollapseDeclarationsAlloc(a, "width:20px;border-collapse:inherit"));
    try std.testing.expect(try hasBorderCollapseDeclarationsAlloc(a, "/* before */ border-collapse:collapse"));
    try std.testing.expect(try hasBorderCollapseDeclarationsAlloc(a, "all:unset"));
    try std.testing.expect(!try hasBorderCollapseDeclarationsAlloc(a, "--note:'border-collapse:collapse';color:red"));
    try std.testing.expect(!try hasBorderCollapseDeclarationsAlloc(a, "border:1px solid red"));
}


test "Missing paint first blocker retains exact selector condition source and declaration without changing the bool query" {
    const a = std.testing.allocator;
    const css = "a{--unrelated:red;font-feature-settings:\"kern\"}@media screen and (max-width:640px){a:hover{color:red}}a{background:blue}";
    var styles = try parseSourcesAlloc(a, &.{
        .{ .css = "span{color:green}", .base_url = "https://example.invalid/first.css", .byte_start = 7 },
        .{ .css = css, .base_url = "https://example.invalid/selected.css", .byte_start = 100 },
    });
    defer styles.deinit();
    const element: TextElement = .{ .tag = "a", .ancestry_complete = true };
    const blocked = (try styles.missingLinkAdditionalPaintBlockerIn(a, &element)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(MissingLinkPaintBlocker.Reason.declaration, blocked.reason);
    const rule = blocked.rule orelse return error.TestUnexpectedResult;
    const origin = rule.provenance orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a:hover", origin.selector);
    try std.testing.expectEqual(@as(usize, 1), origin.source_index);
    try std.testing.expectEqual(@as(usize, 100 + std.mem.indexOf(u8, css, "color:red").?), origin.css_byte_start);
    try std.testing.expectEqualStrings("https://example.invalid/selected.css", styles.sources[origin.source_index].base_url);
    try std.testing.expectEqual(@as(usize, 1), origin.conditions.len);
    try std.testing.expectEqualStrings("@media screen and (max-width:640px)", origin.conditions[0]);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, rule.match);
    try std.testing.expectEqual(@as(u32, 640), rule.viewport.screen_max_width_px);
    try std.testing.expect(!rule.rank_unknown);
    try std.testing.expectEqualStrings("color:red", blocked.declaration);
    try std.testing.expectEqual(@as(usize, 0), blocked.declaration_offset);
    try std.testing.expect(!(try styles.missingLinkAdditionalPaintUnchangedIn(a, &element)));
    // Returned selector/declaration slices belong to the Profile, not the freed
    // temporary matches array or declaration-token allocation.
    const next = (try styles.missingLinkAdditionalPaintBlockerIn(a, &element)).?;
    try std.testing.expectEqualStrings(blocked.declaration, next.declaration);
}

test "Missing paint blocker distinguishes global malformed priority and harmless declarations conservatively" {
    const a = std.testing.allocator;
    const element: TextElement = .{ .tag = "a", .ancestry_complete = true };
    var safe = try parseAlloc(a, "span{color:red}a{--unrelated:green;font-feature-settings:\"kern\"}");
    defer safe.deinit();
    try std.testing.expect((try safe.missingLinkAdditionalPaintBlockerIn(a, &element)) == null);
    try std.testing.expect(try safe.missingLinkAdditionalPaintUnchangedIn(a, &element));
    for ([_]struct { css: []const u8, reason: MissingLinkPaintBlocker.Reason }{
        .{ .css = "@unknown x{a{color:red}}", .reason = .global_unresolved },
        .{ .css = "a{opaque}", .reason = .malformed_declaration },
        .{ .css = "a{--unrelated:red!unproved}", .reason = .unknown_priority },
        .{ .css = "a{--color-destructive:red}", .reason = .declaration },
        .{ .css = "a{animation-name:example}", .reason = .declaration },
    }) |case| {
        var styles = try parseAlloc(a, case.css); defer styles.deinit();
        const blocked = (try styles.missingLinkAdditionalPaintBlockerIn(a, &element)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.reason, blocked.reason);
        try std.testing.expect((blocked.rule == null) == (case.reason == .global_unresolved));
        try std.testing.expect(!(try styles.missingLinkAdditionalPaintUnchangedIn(a, &element)));
    }
}


test "explicit keyframe definitions do not become element rules or globally erase unrelated paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const html: TextElement = .{ .tag = "html", .ancestry_complete = true };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &html };
    const ordinary = "table.X{background:#123456}a.other{color:red}";
    var baseline = try parseAlloc(a, ordinary); defer baseline.deinit();
    const expected = try baseline.resolveTable(a, 0, "X", null, "");
    for ([_][]const u8{
        // Exact retained g served response0 bytes3217..3323.
        "@keyframes mw-tmh-player-progress-bar-slide{from{transform:translate(-100%)}to{transform:translate(350%)}}",
        "@keyframes unrelated{0%, 12.5%,5e1%,to{color:red;opacity:0.5}FROM{color:blue}}",
        "@KEYFRAMES independent{ /* frame comment */ 0%{content:'a;{}';transform:translate(1px,2px)}100%{--value:var(--other);opacity:1!important}}",
        "@keyframes empty{}",
        "@media print{@keyframes conditional{from{opacity:0}to{opacity:1}}}",
    }) |definition| {
        errdefer std.debug.print("keyframe definition={s}\n", .{definition});
        var sheet = try parseAlloc(a, try std.mem.concat(a, u8, &.{definition, ordinary})); defer sheet.deinit();
        try std.testing.expect(!sheet.globally_unresolved and sheet.has_unsupported_rules);
        try std.testing.expectEqual(baseline.rules.len, sheet.rules.len);
        try std.testing.expectEqual(baseline.container_rules.len, sheet.container_rules.len);
        try std.testing.expectEqual(baseline.figure_rules.len, sheet.figure_rules.len);
        try std.testing.expectEqual(baseline.text_rules.len, sheet.text_rules.len);
        try std.testing.expectEqualDeep(expected, try sheet.resolveTable(a, 0, "X", null, ""));
        try std.testing.expect(try sheet.missingLinkAdditionalPaintUnchangedIn(a, &link));
    }
}

test "keyframe definitions retain global refusal for malformed unsupported and nested rule syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const html: TextElement = .{ .tag = "html", .ancestry_complete = true };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &html };
    for ([_][]const u8{
        "@keyframes{from{opacity:0}}", "@keyframes none{from{opacity:0}}",
        "@keyframes initial{to{opacity:1}}", "@keyframes two names{from{opacity:0}}",
        "@keyframes 'quoted'{from{opacity:0}}", "@keyframes escaped\\name{to{opacity:1}}",
        "@-webkit-keyframes other{to{opacity:1}}", "@keyframes-extra other{to{opacity:1}}",
        "@keyframes x{a.new{color:red}}", "@keyframes x{101%{opacity:1}}",
        "@keyframes x{-1%{opacity:0}}", "@keyframes x{%,to{opacity:1}}",
        "@keyframes x{50.%{opacity:1}}", "@keyframes x{0%,{opacity:1}}", "@keyframes x{from;}",
        "@keyframes x{@media screen{a.new{color:red}}}",
        "@keyframes x{from{a.new{color:red}}}",
        "@keyframes x{from{@import 'other.css';}}",
        "@keyframes x{from{opacity}}", "@keyframes x{from{:0}}",
        "@keyframes x{from{opacity:}}", "@keyframes x{from{opacity:/* empty */}}",
        "@keyframes x{from{--block:{color:red}}}",
        "@keyframes x{from{transform:fn([)]);}}",
        "@keyframes x{from{transform:fn(1px;}}",
        "@keyframes x{from{opac\\ity:0}}",
    }) |definition| {
        errdefer std.debug.print("refused keyframes={s}\n", .{definition});
        var sheet = try parseAlloc(a, try std.mem.concat(a, u8, &.{definition, "a.other{color:red}"})); defer sheet.deinit();
        try std.testing.expect(sheet.globally_unresolved and sheet.has_unsupported_rules);
        try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, &link));
    }
    for ([_][]const u8{ "@keyframes x{from{opacity:0}", "@keyframes x{from{content:'unterminated}}", "@keyframes x{/* unterminated" }) |broken|
        try std.testing.expectError(error.InvalidStyleProfile, parseAlloc(a, broken));
}

test "valid keyframes keep matching animation names and unknown effects refused on actual element paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const html: TextElement = .{ .tag = "html", .ancestry_complete = true };
    const link: TextElement = .{ .tag = "a", .classes = "new", .parent = &html };
    const definition = "@keyframes pulse{from{color:red;opacity:0}to{color:blue;opacity:1}}";
    for ([_][]const u8{ "animation:pulse 1s infinite", "animation-name:pulse", "animation-name:var(--selected)", "animation:none", "animation-duration:1s", "-webkit-animation:pulse 1s", "transform:translate(10px)", "unrepresented:1" }) |declaration| {
        for ([_][]const u8{ "a.new", "a.new:hover", "html" }) |selector| {
            errdefer std.debug.print("keyframes effect selector={s} declaration={s}\n", .{ selector, declaration });
            var sheet = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}{s}{{{s}}}", .{definition, selector, declaration})); defer sheet.deinit();
            try std.testing.expect(!sheet.globally_unresolved);
            const subject = if (std.mem.eql(u8, selector, "html")) &html else &link;
            const matches = try sheet.containerRuleMatchesIn(a, subject);
            defer a.free(matches.rules);
            try std.testing.expect(!matches.unresolved);
            try std.testing.expectEqual(@as(usize, 1), matches.rules.len);
            try std.testing.expectEqualStrings(declaration, matches.rules[0].css);
            // The normal Book checks the link and each actual ancestor.
            try std.testing.expect(!try sheet.missingLinkAdditionalPaintUnchangedIn(a, subject));
        }
        var table_sheet = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}table.X{{background:red;{s}}}", .{definition, declaration}));
        defer table_sheet.deinit();
        try std.testing.expect(!table_sheet.globally_unresolved);
        try std.testing.expect((try table_sheet.resolveTable(a, 0, "X", null, "")).unresolved);
        var absent = try parseAlloc(a, try std.fmt.allocPrint(a, "{s}.absent{{{s}}}", .{definition, declaration})); defer absent.deinit();
        try std.testing.expect(!absent.globally_unresolved);
        try std.testing.expect(try absent.missingLinkAdditionalPaintUnchangedIn(a, &link));
    }
}


test "merged alias alternatives retain custom palette consumed collapse and relative fixed owner through responsive cascade" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var tokens = try CustomPropertyFixture.profile(a, ":root{--paint:#123456;--edge:#654321}"); defer tokens.deinit();
    const environment = tokens.custom_properties.?.root_environment;
    const element: TextElement = .{ .tag = "div", .classes = "box", .ancestry_complete = true };
    // The first case is a multicol owner; the second is a relative fixed-height
    // header. The shared model intentionally excludes both on the same owner.
    const variants = [_][]const u8{
        "column-count:2;-webkit-column-count:2;-moz-column-count:2;column-width:50%;-webkit-column-width:50%;-moz-column-width:50%",
        "column-count:auto;-webkit-column-count:auto;-moz-column-count:auto;position:relative;inset:auto;z-index:auto;height:1.6em",
    };
    for (variants, 0..) |variant, index| {
        const css = try std.fmt.allocPrint(a, ".box{{{s};background:var(--paint);border:var(--edge)1px solid;border-collapse:collapse;width:240px}}@media screen and (max-width:719px){{.box{{width:100%;max-width:100%;box-sizing:border-box}}}}", .{variant});
        var profile = try parseAlloc(a, css); defer profile.deinit();
        const collapse = try profile.resolveBorderCollapseIn(a, &element, "", null);
        try std.testing.expectEqual(BorderCollapseState.collapse, collapse.?);
        const consumed = collapse != null and collapse.? != .unknown;
        const selected = try profile.resolveContainerInWithInheritance(a, &element, "", environment, consumed);
        errdefer std.debug.print("MERGED_ALIAS_PALETTE member={d} unresolved={}\n", .{index, selected.unresolved});
        try std.testing.expect(selected.specified and !selected.unresolved);
        try std.testing.expectEqualStrings("#123456", selected.style.background.?.rgb);
        try std.testing.expectEqualStrings("#654321", selected.style.border.?.solid.color.rgb);
        try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 1 }, selected.style.border.?.solid.width);
        try std.testing.expectEqual(@as(f32, 240), selected.style.width.?.length.value);
        const narrow = selected.style.screen_max_width.?;
        try std.testing.expectEqual(@as(u32, 719), narrow.max_width_px);
        try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, narrow.width.?.length);
        try std.testing.expectEqual(types.StyleWidth{ .unit = .percent, .value = 100 }, narrow.max_width.?.length);
        try std.testing.expectEqual(types.ContainerBoxSizing.border_box, narrow.box_sizing.?);
        if (index == 0) {
            try std.testing.expectEqual(@as(u16, 2), selected.style.columns.?.count);
            try std.testing.expect(selected.style.positioning == null and selected.style.height == null);
        } else {
            try std.testing.expect(selected.style.columns == null);
            try std.testing.expectEqual(types.ContainerPositioning.relative_auto, selected.style.positioning.?);
            try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, selected.style.height.?);
        }
        // Neither a complete palette nor consumed inherited property may be
        // silently omitted on just one alias or responsive alternative.
        try std.testing.expect((try profile.resolveContainerInWithInheritance(a, &element, "", null, consumed)).unresolved);
        try std.testing.expect((try profile.resolveContainerInWithInheritance(a, &element, "", environment, false)).unresolved);
        const incomplete: CustomEnvironment = .{ .values = environment.values, .complete = false };
        try std.testing.expect((try profile.resolveContainerInWithInheritance(a, &element, "", incomplete, consumed)).unresolved);
        try std.testing.expect((try profile.resolveContainerInWithInheritance(a, &element, "-webkit-column-count:3", environment, consumed)).unresolved);
    }
    const inline_css = "column-count:2;-webkit-column-count:2;-moz-column-count:2;border-collapse:collapse;background:#123456";
    const inline_selected = try resolveInlineContainerWithInheritanceAlloc(a, inline_css, true);
    try std.testing.expect(!inline_selected.unresolved and inline_selected.style.columns.?.count == 2);
    try std.testing.expectEqualStrings("#123456", inline_selected.style.background.?.rgb);
    try std.testing.expect((try resolveInlineContainerWithInheritanceAlloc(a, inline_css, false)).unresolved);
    try std.testing.expect((try resolveInlineContainerWithInheritanceAlloc(a, inline_css ++ ";-moz-column-count:3", true)).unresolved);
}

test "Missing paint ignores exact tab sizing while retaining unknown selector and layout obligations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    // Exact complete rule retained in both selected KU and VI gadget responses.
    const css = "textarea#wpTextbox1+div:last-child,textarea,pre,code,.mw-highlight{-moz-tab-size:4;-o-tab-size:4;tab-size:4}";
    const element: TextElement = .{ .tag = "div", .classes = "mw-page-container", .ancestry_complete = true };
    var styles = try parseAlloc(a, css); defer styles.deinit();
    const matches = try styles.containerRuleMatchesIn(a, &element); defer a.free(matches.rules);
    try std.testing.expectEqual(@as(usize, 1), matches.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, matches.rules[0].match);
    try std.testing.expectEqualStrings("textarea#wpTextbox1+div:last-child", matches.rules[0].provenance.?.selector);
    try std.testing.expect((try styles.missingLinkAdditionalPaintBlockerIn(a, &element)) == null);
    try std.testing.expect(try styles.missingLinkAdditionalPaintUnchangedIn(a, &element));
    // Values and conditions cannot turn these exact properties into a paint
    // setter. This proof does not compute their inherited text-layout effect.
    var dynamic = try parseAlloc(a, "@media screen and (max-width:640px){div:hover{TAB-SIZE:var(--tabs)!important;-moz-tab-size:inherit;-o-tab-size:0}}"); defer dynamic.deinit();
    try std.testing.expect(try dynamic.missingLinkAdditionalPaintUnchangedIn(a, &element));
    var table = try parseAlloc(a, "table{tab-size:4}"); defer table.deinit();
    try std.testing.expect((try table.resolveTable(a, 0, "", null, "")).unresolved);
}

test "Missing paint tab sizing cannot hide paint reset priority or escaped declaration blockers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const element: TextElement = .{ .tag = "div", .classes = "mw-page-container", .ancestry_complete = true };
    for ([_]struct { declaration: []const u8, reason: MissingLinkPaintBlocker.Reason }{
        .{ .declaration = "color:red", .reason = .declaration },
        .{ .declaration = "background:blue", .reason = .declaration },
        .{ .declaration = "text-decoration:none", .reason = .declaration },
        .{ .declaration = "all:initial", .reason = .declaration },
        .{ .declaration = "opacity:0.5", .reason = .declaration },
        .{ .declaration = "animation-name:editor", .reason = .declaration },
        .{ .declaration = "--color-destructive:red", .reason = .declaration },
        .{ .declaration = "tab\\2d size:4", .reason = .declaration },
        .{ .declaration = "tab-size:4!unproved", .reason = .unknown_priority },
    }) |case| {
        const css = try std.fmt.allocPrint(a, "textarea#wpTextbox1+div:last-child{{-moz-tab-size:4;tab-size:4;{s}}}", .{case.declaration});
        var styles = try parseAlloc(a, css); defer styles.deinit();
        const blocker = (try styles.missingLinkAdditionalPaintBlockerIn(a, &element)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.reason, blocker.reason);
        try std.testing.expectEqualStrings(case.declaration, blocker.declaration);
        try std.testing.expectEqual(ContainerSelectorMatch.unknown, blocker.rule.?.match);
        try std.testing.expect(!(try styles.missingLinkAdditionalPaintUnchangedIn(a, &element)));
    }
}

test "table text color consumption discharges only its own slot and never another unsupported property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "color:#123456", "color:var(--ink)" }) |declaration| {
        const css = try std.fmt.allocPrint(a, "table{{{s};background:#abcdef}}", .{declaration});
        var profile = try parseAlloc(a, css); defer profile.deinit();
        try std.testing.expect((try profile.resolveTableWithContext(a, 0, "", .{}, null, "")).unresolved);
        const consumed = try profile.resolveTableWithContext(a, 0, "", .{ .text_color_consumed = true }, null, "");
        try std.testing.expect(!consumed.unresolved);
        try std.testing.expectEqualStrings("#abcdef", consumed.style.?.background.?);
        try std.testing.expect((try profile.resolveTableWithContext(a, 0, "", .{ .text_color_consumed = true }, null, "opacity:0.5")).unresolved);
        try std.testing.expect((try profile.resolveTableWithContext(a, 0, "", .{ .text_color_consumed = true }, null, "all:initial")).unresolved);
    }
    // The compiler must earn this API flag from its own computed text cascade.
    // It cannot be inferred from a non-null inherited foreground alone.
    var cell = try parseAlloc(a, "td{color:var(--absent);border:1px solid red}"); defer cell.deinit();
    const element: TextElement = .{ .tag = "td", .ancestry_complete = true };
    const paint = try cell.resolveTextPaintWithCustom(a, &element, "", .{ .complete = true });
    try std.testing.expectEqual(TextColor.unknown, paint.color.?);
    try std.testing.expect((try cell.resolveCellWithContext(a, 0, 0, "", .{}, false, null, "")).unresolved);
}


test "unquoted positive attribute equality supplies only certified own absence to Missing paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const Presence = struct {
        value: AttributePresence,
        fn get(raw: ?*const anyopaque, name: []const u8) AttributePresence {
            const self: *const @This() = @ptrCast(@alignCast(raw orelse return .unknown));
            return if (std.mem.eql(u8, name, "role")) self.value else .unknown;
        }
    };
    for ([_][]const u8{ "a[role=button]{color:red}", "a[role=\"button\"]{color:red}", "a[role]{color:red}" }) |css| {
        var styles = try parseAlloc(a, css); defer styles.deinit();
        for ([_]AttributePresence{ .absent, .present, .unknown }) |state| {
            const inventory: Presence = .{ .value = state };
            const element: TextElement = .{ .tag = "a", .classes = "new", .attribute_presence = .{ .ctx = &inventory, .get = Presence.get } };
            const matches = try styles.containerRuleMatchesIn(a, &element); defer a.free(matches.rules);
            try std.testing.expect(!matches.unresolved);
            try std.testing.expectEqual(@as(usize, if (state == .absent) 0 else 1), matches.rules.len);
            if (state != .absent) try std.testing.expectEqual(ContainerSelectorMatch.unknown, matches.rules[0].match);
        }
        const unobserved: TextElement = .{ .tag = "a", .classes = "new" };
        const matches = try styles.containerRuleMatchesIn(a, &unobserved); defer a.free(matches.rules);
        try std.testing.expectEqual(@as(usize, 1), matches.rules.len);
        try std.testing.expectEqual(ContainerSelectorMatch.unknown, matches.rules[0].match);
    }
}

test "unquoted required attribute keeps escapes flags operators and invalid tokens unknown" {
    for ([_][]const u8{ "[role=button i]", "[role=button s]", "[role=123]", "[role=]", "[role=--button]", "[role=but\\74on]", "[role~=button]", "[role=button()]", "[role=button extra]" }) |tail|
        try std.testing.expect(requiredOwnAttribute(tail) == null);
    for ([_][]const u8{ "[role=button]", "[role = _button]", "[role=menu-item]" }) |tail|
        try std.testing.expectEqualStrings("role", requiredOwnAttribute(tail) orelse return error.TestUnexpectedResult);
}


test "Container minimum height is a separate noninherited floor with exact winner priority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var styles = try parseForTargetAlloc(a, ".box{height:1em;min-height:1.6em!important}.box{min-height:7px}", .screen); defer styles.deinit();
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    const floor = try styles.resolveContainerIn(a, &node, "min-height:3px");
    try std.testing.expect(!floor.unresolved and floor.specified);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1 }, floor.style.height.?);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1.6 }, floor.style.min_height.?);
    const zero = try styles.resolveContainerIn(a, &node, "min-height:0!important");
    try std.testing.expect(!zero.unresolved and zero.style.min_height.?.value == 0 and zero.style.height.?.value == 1);
    const reset = try resolveInlineContainerAlloc(a, "min-height:4em;min-height:unset");
    try std.testing.expect(!reset.unresolved and reset.style.min_height.?.value == 0);
    const invalid = try resolveInlineContainerAlloc(a, "min-height:2px;min-height:-1px;min-height:nan");
    try std.testing.expect(!invalid.unresolved and invalid.style.min_height.?.value == 2);
    const absent = try resolveInlineContainerAlloc(a, "height:1em");
    try std.testing.expect(!absent.unresolved and absent.style.min_height == null);
}

test "Container minimum height preserves conditional unknown and same owner column flex refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "min-height:10%", "min-height:var(--floor)", "min-height:inherit", "min-height:revert", "min-height:auto",
        "min-height:1px;column-count:2", "min-height:0;display:flex", "min-height:1em;max-height:2em", "all:initial;min-height:0" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    for ([_][]const u8{ "@media screen and (max-width:700px){.box{min-height:1em}}", ".unknown .box{min-height:1em!important}" }) |css| {
        var styles = try parseForTargetAlloc(a, css, .screen); defer styles.deinit();
        try std.testing.expect((try styles.resolveContainerIn(a, &node, "height:2em")).unresolved);
    }
}

test "signed Container margins keep shorthand edge priority resets and strict nonmargin domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var styles = try parseForTargetAlloc(a, ".box{margin-bottom:2px!important;margin:1em -2px -.5em 0}", .screen); defer styles.deinit();
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    const selected = try styles.resolveContainerIn(a, &node, "margin-left:-3px");
    try std.testing.expect(!selected.unresolved);
    const margins = selected.style.margins.?;
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = 1 }, margins.top);
    try std.testing.expectEqual(@as(f32, -2), margins.right.value);
    try std.testing.expectEqual(@as(f32, 2), margins.bottom.value);
    try std.testing.expectEqual(@as(f32, -3), margins.left.value);
    const actual_reference = try resolveInlineContainerAlloc(a, "margin-bottom:-.5em");
    try std.testing.expect(!actual_reference.unresolved);
    try std.testing.expectEqual(types.StyleLength{ .unit = .em, .value = -0.5 }, actual_reference.style.margins.?.bottom);
    const reset = try resolveInlineContainerAlloc(a, "margin:-2px;margin:unset");
    try std.testing.expectEqual(types.StyleEdges.all(.{ .unit = .px, .value = 0 }), reset.style.margins.?);
    for ([_][]const u8{ "margin:auto inherit", "margin:1%", "margin:var(--gap)", "margin:inherit", "margin:1_0px", "margin:0x1px", "margin:1e999px", "margin:nan", "padding:-1px", "width:-1px", "height:1px;min-height:10%" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    try std.testing.expect((try resolveInlineTableAlloc(a, "margin:-1px")).unresolved);
    const paragraph = try styles.resolveBlockGeometryIn(a, &node, "margin:-1px");
    try std.testing.expect(paragraph.unresolved);
}

test "physical border components preserve old uniform variants and exact side priority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{ "border:none", "border:0", "border:initial" }) |css| {
        const none = try resolveInlineContainerAlloc(a, css);
        try std.testing.expect(!none.unresolved and none.style.border.? == .none);
    }
    const solid = try resolveInlineContainerAlloc(a, "border:2px solid red");
    try std.testing.expect(!solid.unresolved and solid.style.border.? == .solid);
    try std.testing.expectEqual(@as(f32, 2), solid.style.border.?.solid.width.value);
    try std.testing.expectEqualStrings("#ff0000", solid.style.border.?.solid.color.rgb);
    const sides = try resolveInlineContainerAlloc(a, "border:2px solid red;border-top:1px dotted #aaa;border-bottom-style:none;border-bottom-style:hidden");
    try std.testing.expect(!sides.unresolved and sides.style.border.? == .edges);
    const edges_value = sides.style.border.?.edges;
    try std.testing.expectEqual(@as(f32, 1), edges_value.top.dotted.width.value);
    try std.testing.expectEqualStrings("#aaaaaa", edges_value.top.dotted.color.rgb);
    try std.testing.expect(edges_value.bottom == .hidden);
    try std.testing.expectEqualDeep(solid.style.border.?.solid.width, edges_value.left.solid.width);
    try std.testing.expectEqualDeep(solid.style.border.?.solid.color, edges_value.left.solid.color);
    try std.testing.expectEqualDeep(solid.style.border.?.solid.width, edges_value.right.solid.width);
    try std.testing.expectEqualDeep(solid.style.border.?.solid.color, edges_value.right.solid.color);
    var styles = try parseForTargetAlloc(a, ".box{border:2px solid red!important;border-top:1px dotted blue}", .screen); defer styles.deinit();
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    const important = try styles.resolveContainerIn(a, &node, "border-top-color:#123456!important");
    try std.testing.expect(!important.unresolved and important.style.border.? == .edges);
    try std.testing.expectEqual(@as(f32, 2), important.style.border.?.edges.top.solid.width.value);
    try std.testing.expectEqualStrings("#123456", important.style.border.?.edges.top.solid.color.rgb);
    try std.testing.expectEqualDeep(solid.style.border.?.solid.width, important.style.border.?.edges.right.solid.width);
    try std.testing.expectEqualDeep(solid.style.border.?.solid.color, important.style.border.?.edges.right.solid.color);
    const reset = try resolveInlineContainerAlloc(a, "border-top:1px dotted red;border:unset");
    try std.testing.expect(!reset.unresolved and reset.style.border.? == .none);
}

test "table cell and Container borders share components and exact qualified custom colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const environment: CustomEnvironment = .{ .complete = true, .values = &.{.{ .name = "--edge", .value = .{ .known = "#123456" } }} };
    var styles = try parseForTargetAlloc(a, "table.box{border:2px solid red;border-top:1px dotted var(--edge,#aaa)}table.box td{border-bottom:1px dotted var(--edge,#aaa)}", .screen); defer styles.deinit();
    const table = try styles.resolveTableWithContext(a, 0, "box", .{ .custom_environment = environment }, null, "");
    try std.testing.expect(!table.unresolved and table.style.?.border.? == .edges);
    try std.testing.expectEqualStrings("#123456", table.style.?.border.?.edges.top.dotted.color);
    try std.testing.expectEqual(@as(f32, 2), table.style.?.border.?.edges.right.solid.width.value);
    const cell = try styles.resolveCellWithContext(a, table.scope, 0, "", .{ .custom_environment = environment }, false, null, "");
    try std.testing.expect(!cell.unresolved and cell.style.?.border.? == .edges);
    try std.testing.expectEqualStrings("#123456", cell.style.?.border.?.edges.bottom.dotted.color);
    try std.testing.expect(cell.style.?.border.?.edges.top == .none);
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    var own = try parseForTargetAlloc(a, ".box{border:var(--edge,#aaa)1px solid;border-right-style:dotted}", .screen); defer own.deinit();
    const selected = try own.resolveContainerInWithInheritance(a, &node, "", environment, false);
    try std.testing.expect(!selected.unresolved and selected.style.border.? == .edges);
    try std.testing.expectEqualStrings("#123456", selected.style.border.?.edges.right.dotted.color.rgb);
    var incomplete = environment; incomplete.complete = false;
    try std.testing.expect((try own.resolveContainerInWithInheritance(a, &node, "", incomplete, false)).unresolved);
    try std.testing.expect((try styles.resolveTableWithContext(a, 0, "box", .{}, null, "")).unresolved);
}

test "border components keep missing width color unknown selectors resets and unrelated effects unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const complete = try resolveInlineContainerAlloc(a, "border-top-style:dotted;border-top-width:1px;border-top-color:#aaa");
    try std.testing.expect(!complete.unresolved and complete.style.border.?.edges.top == .dotted);
    for ([_][]const u8{ "border-top-style:dotted", "border-top:1px dotted", "border:1px solid currentcolor", "border:1px solid red;border-top-color:var(--unknown)",
        "border-top:thin dotted red", "border-top:1px dashed red", "border-top:-1px solid red", "border:1px solid red;border-radius:0",
        "border:1px solid red;border-image:none", "all:initial;border:1px solid red", "border-top:1px solid transparent" }) |css| {
        if (std.mem.eql(u8, css, "border-top:1px solid transparent")) {
            var styles = try parseForTargetAlloc(a, "table.x{border-top:1px solid transparent}", .screen); defer styles.deinit();
            try std.testing.expect((try styles.resolveTable(a, 0, "x", null, "")).unresolved);
        } else try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    }
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    for ([_][]const u8{ ".unknown .box{border-top:1px dotted red!important}", "@media screen and (max-width:700px){.box{border-top:1px dotted red!important}}" }) |css| {
        var styles = try parseForTargetAlloc(a, css, .screen); defer styles.deinit();
        try std.testing.expect((try styles.resolveContainerIn(a, &node, "border:2px solid blue")).unresolved);
    }
}


test "source adjacent sibling selector consumes only an exact issued element relation" {
    // Container resolution colors belong to the caller arena, including
    // candidates retained by an unresolved result.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var styles = try parseForTargetAlloc(a, "div.NavFrame + div.NavFrame{background:#123456}", .screen); defer styles.deinit();
    const source = "<div class=\"NavFrame\"><div>plain label</div></div>";
    const proof: SourceSiblingProof = .{ .anchor_start = 0, .anchor_end = source.len - 6, .name_start = 1, .name_len = 3, .attrs_start = 4, .attrs_len = 17,
        .parent_key = 17, .previous = .{ .tag = "div", .classes = "NavFrame" } };
    const scope: BoundedTextClassScope = .{ .root_tag = "div", .root_classes = "mw-parser-output", .subtree_classes = "NavFrame", .source_siblings = &.{proof}, .source_siblings_source = source };
    var element: TextElement = .{ .tag = "div", .classes = "NavFrame", .source_sibling = &proof,
        .source_sibling_scope = &scope, .source_sibling_source = source };
    const matched = try styles.containerRuleMatchesIn(a, &element); defer a.free(matched.rules);
    try std.testing.expectEqual(@as(usize, 1), matched.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.known, matched.rules[0].match);
    try std.testing.expectEqual((@as(u64, 2) << 21) + 2, matched.rules[0].specificity);
    try std.testing.expect(!(try styles.resolveContainerIn(a, &element, "")).unresolved);
    var other = proof; other.previous = .{ .tag = "span", .classes = "NavFrame" }; element.source_sibling = &other;
    const nonmatch = try styles.containerRuleMatchesIn(a, &element); defer a.free(nonmatch.rules);
    try std.testing.expectEqual(@as(usize, 0), nonmatch.rules.len);
    other.previous = null;
    const first = try styles.containerRuleMatchesIn(a, &element); defer a.free(first.rules);
    try std.testing.expectEqual(@as(usize, 0), first.rules.len);
    other.parent_key = 0;
    const parent_unknown = try styles.containerRuleMatchesIn(a, &element); defer a.free(parent_unknown.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, parent_unknown.rules[0].match);
    element.source_sibling = null;
    const absent = try styles.containerRuleMatchesIn(a, &element); defer a.free(absent.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, absent.rules[0].match);
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    element.source_sibling = &proof; element.source_sibling_source = null;
    const detached = try styles.containerRuleMatchesIn(a, &element); defer a.free(detached.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, detached.rules[0].match);
    const copy = try a.dupe(u8, source); defer a.free(copy); element.source_sibling_source = copy;
    const copied = try styles.containerRuleMatchesIn(a, &element); defer a.free(copied.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, copied.rules[0].match);
    element.source_sibling_source = source; element.source_sibling_scope = null;
    const legacy = try styles.containerRuleMatchesIn(a, &element); defer a.free(legacy.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, legacy.rules[0].match);
}

test "source sibling evidence cannot decide general siblings complex relations or unknown attributes" {
    const a = std.testing.allocator;
    const source = "<div class=\"NavFrame\"><div>plain label</div></div>";
    const proof: SourceSiblingProof = .{ .anchor_start = 0, .anchor_end = source.len - 6, .name_start = 1, .name_len = 3, .attrs_start = 4, .attrs_len = 17,
        .parent_key = 2, .previous = .{ .tag = "div", .classes = "NavFrame" } };
    const scope: BoundedTextClassScope = .{ .root_tag = "div", .root_classes = "mw-parser-output", .subtree_classes = "NavFrame", .source_siblings = &.{proof}, .source_siblings_source = source };
    const node: TextElement = .{ .tag = "div", .classes = "NavFrame", .source_sibling = &proof,
        .source_sibling_scope = &scope, .source_sibling_source = source };
    for ([_][]const u8{ "div.NavFrame ~ div.NavFrame", "div.NavFrame + div.NavFrame + div.NavFrame",
        ".owner div.NavFrame + div.NavFrame", "div.NavFrame[role] + div.NavFrame", "div.NavFrame + div.NavFrame:hover", "div.NavFrame + div.NavFrame,:unsupported" }) |selector| {
        const css = try std.fmt.allocPrint(a, "{s}{{background:red}}", .{selector}); defer a.free(css);
        var styles = try parseForTargetAlloc(a, css, .screen); defer styles.deinit();
        const result = try styles.containerRuleMatchesIn(a, &node); defer a.free(result.rules);
        try std.testing.expect(result.rules.len != 0);
        for (result.rules) |rule| try std.testing.expectEqual(ContainerSelectorMatch.unknown, rule.match);
    }
}

test "table border spacing refuses independently without erasing physical border winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact retained SR infobox declarations; its inline border overrides the
    // indexed border, while the unrepresented spacing remains a refusal.
    var profile = try parseAlloc(a, ".infobox { border:1px solid #a2a9b1; border-spacing:3px; }");
    defer profile.deinit();
    const css = "float:right; border:1px solid #AAAAAA; border-collapse:collapse; margin-left:0.5em; margin-bottom:0.5em;";
    const table = try profile.resolveTableWithContext(a, 0, "infobox vcard", .{ .ancestor_classes = "", .own_id = "" }, null, css);
    try std.testing.expect(table.unresolved);
    const border = table.style.?.border.?;
    try std.testing.expect(border == .solid);
    try std.testing.expectEqual(types.StyleLength{ .unit = .px, .value = 1 }, border.solid.width);
    try std.testing.expectEqualStrings("#aaaaaa", border.solid.color);
    try std.testing.expectEqual(types.TableFloatSide.right, table.style.?.float_side.?);
    try std.testing.expectEqual(types.BorderCollapse.collapse, table.style.?.collapse.?);
    try std.testing.expectEqual(@as(f32, 0.5), table.style.?.margins.?.bottom.value);
    var no_spacing = try parseAlloc(a, ".infobox { border:1px solid #a2a9b1; }");
    defer no_spacing.deinit();
    const plain = try no_spacing.resolveTableWithContext(a, 0, "infobox vcard", .{ .ancestor_classes = "", .own_id = "" }, null, css);
    try std.testing.expect(!plain.unresolved);
    try std.testing.expectEqualDeep(plain.style, table.style);
    // Inline spacing remains unavailable too; it cannot erase its sibling
    // shorthand or make the unsupported table layout appear complete.
    const inline_spacing = try no_spacing.resolveTableWithContext(a, 0, "infobox vcard", .{ .ancestor_classes = "", .own_id = "" }, null,
        "border:1px solid #aaaaaa;border-spacing:3px");
    try std.testing.expect(inline_spacing.unresolved);
    try std.testing.expectEqualDeep(border, inline_spacing.style.?.border.?);
    // A logical/unknown border name can change physical edges, unlike spacing.
    // Preserve the existing refusal and withhold an invented physical border.
    const logical_css = "border:1px solid #aaaaaa;border-inline-start-width:2px";
    const logical = try no_spacing.resolveTableWithContext(a, 0, "infobox vcard", .{ .ancestor_classes = "", .own_id = "" }, null, logical_css);
    try std.testing.expect(logical.unresolved);
    // Withholding the sole border leaves no valid TableStyle at all. The
    // public aggregate is null; that is distinct from a known border:none.
    try std.testing.expect(logical.style == null);
    const logical_winners = try no_spacing.cascade(a, .table, no_spacing.classScope("infobox vcard"), 0,
        "infobox vcard", .{ .ancestor_classes = "", .own_id = "" }, null, null, logical_css);
    const unknown_border = logical_winners.value(.border) orelse return error.ExpectedUnresolvedLogicalBorderWinner;
    try std.testing.expect(unknown_border == .unsupported);
    const unknown_edges = logical_winners.borders.result();
    try std.testing.expect(unknown_edges.unresolved and unknown_edges.value == null);
}


test "cell top alignment retains quote padding without lending inline table semantics or other cell modes" {
    const a = std.testing.allocator;
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    const result = try profile.resolveCell(a, 0, false, null, "padding:0 1.2em; vertical-align:top");
    try std.testing.expect(!result.unresolved);
    try std.testing.expectEqual(types.CellVerticalAlign.top, result.style.?.vertical_align.?);
    try std.testing.expectEqual(@as(f32, 0), result.style.?.padding.?.top.value);
    try std.testing.expectEqual(@as(f32, 1.2), result.style.?.padding.?.right.value);
    try std.testing.expectEqual(types.StyleLengthUnit.em, result.style.?.padding.?.right.unit);
    const absent = try profile.resolveCell(a, 0, false, null, "padding:0 1.2em 0 0");
    try std.testing.expect(!absent.unresolved and absent.style.?.vertical_align == null);
    try std.testing.expectEqual(@as(f32, 0), absent.style.?.padding.?.left.value);
    for ([_][]const u8{ "middle", "bottom", "baseline", "text-top", "var(--unknown)" }) |mode| {
        const css = try std.fmt.allocPrint(a, "vertical-align:{s}", .{mode}); defer a.free(css);
        try std.testing.expect((try profile.resolveCell(a, 0, false, null, css)).unresolved);
    }
    try std.testing.expect((try resolveInlineTableAlloc(a, "vertical-align:top")).unresolved);
    const inline_cell = try resolveInlineCellAlloc(a, null, "vertical-align:top");
    try std.testing.expect(!inline_cell.unresolved and inline_cell.style.?.vertical_align == .top);
    try std.testing.expect((try resolveInlineCellAlloc(a, null, "vertical-align:baseline")).unresolved);
}

test "inline table external top is distinct from cell top and requires actual inline display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    const css = "display:inline-block;vertical-align:top;line-height:1em";
    const direct = try resolveInlineTableAlloc(a, css);
    try std.testing.expect(!direct.unresolved);
    try std.testing.expectEqual(types.InlineBoxVerticalAlign.top, direct.style.?.vertical_align.?);
    try std.testing.expectEqual(types.TableDisplay.inline_block, direct.style.?.display.?);
    const scoped = try profile.resolveTableWithContext(a, 0, "", .{ .ancestor_classes = "", .own_id = "" }, null, css);
    try std.testing.expect(!scoped.unresolved);
    try std.testing.expectEqualDeep(direct.style, scoped.style);
    const middle = try resolveInlineTableAlloc(a, "display:inline-table;vertical-align:top;vertical-align:middle");
    try std.testing.expect(!middle.unresolved and middle.style.?.vertical_align == .middle);
    const important = try resolveInlineTableAlloc(a, "display:inline-block;vertical-align:top!important;vertical-align:middle");
    try std.testing.expect(!important.unresolved and important.style.?.vertical_align == .top);
    for ([_][]const u8{ "vertical-align:top", "display:table;vertical-align:top", "display:inline-block;vertical-align:var(--unknown)!important;vertical-align:top", "display:inline-block;vertical-align:bottom" }) |unsupported| {
        const result = try resolveInlineTableAlloc(a, unsupported);
        try std.testing.expect(result.unresolved);
        if (result.style) |style| try std.testing.expect(style.vertical_align != .top);
    }
    const cell = try resolveInlineCellAlloc(a, null, "vertical-align:top");
    try std.testing.expect(!cell.unresolved and cell.style.?.vertical_align == .top);
    try std.testing.expect((try resolveInlineCellAlloc(a, null, "vertical-align:middle")).unresolved);
}


test "issued observed element relation refutes only absent necessary ancestor classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const css = "div.NavFrame{border:1px solid #aaaaaa}div.Boxmerge div.NavFrame{border-style:none;border-style:hidden}";
    var styles = try parseForTargetAlloc(a, css, .screen); defer styles.deinit();
    const source = "<div class=\"NavFrame\"><div>plain label</div></div>";
    var proofs = [_]SourceSiblingProof{.{ .anchor_start = 0, .anchor_end = source.len - 6,
        .name_start = 1, .name_len = 3, .attrs_start = 4, .attrs_len = 17, .parent_key = 17, .previous = null }};
    var scope: BoundedTextClassScope = .{ .root_tag = "div", .root_classes = "mw-parser-output", .subtree_classes = "NavFrame NavHead",
        .source_siblings = &proofs, .source_siblings_source = source, .complete_ancestor_class_superset = "mw-parser-output NavFrame NavHead" };
    var element: TextElement = .{ .tag = "div", .classes = "NavFrame", .source_sibling = &proofs[0],
        .source_sibling_scope = &scope, .source_sibling_source = source };
    const resolved = try styles.resolveContainerIn(a, &element, "");
    try std.testing.expect(!resolved.unresolved and resolved.style.border != null);
    try std.testing.expect(element.complete_ancestor_classes == null and element.parent == null and !element.ancestry_complete and !element.physical_ancestry_complete);
    const projected: TextElement = .{ .tag = "div", .classes = "Boxmerge" };
    element.parent = &projected;
    const concrete = try styles.containerRuleMatchesIn(a, &element); defer a.free(concrete.rules);
    try std.testing.expectEqual(@as(usize, 2), concrete.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.known, concrete.rules[1].match);
    var cyclic: TextElement = .{ .tag = "div", .classes = "unrelated" };
    cyclic.parent = &cyclic; element.parent = &cyclic;
    const bounded = try styles.containerRuleMatchesIn(a, &element); defer a.free(bounded.rules);
    try std.testing.expectEqual(@as(usize, 2), bounded.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, bounded.rules[1].match);
    element.parent = null;
    scope.complete_ancestor_class_superset = "mw-parser-output Boxmerge NavFrame";
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    scope.complete_ancestor_class_superset = null;
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    scope.complete_ancestor_class_superset = "mw-parser-output NavFrame NavHead";
    const foreign_proof = proofs[0]; element.source_sibling = &foreign_proof;
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    element.source_sibling = &proofs[0]; proofs[0].parent_key = 0;
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    proofs[0].parent_key = 17;
    element.source_sibling_source = try a.dupe(u8, source);
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    element.source_sibling_source = source; element.source_sibling_scope = null;
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    element.source_sibling_scope = &scope; element.source_sibling = null;
    try std.testing.expect((try styles.resolveContainerIn(a, &element, "")).unresolved);
    // A possibly present ancestor class still cannot establish a physical edge,
    // ID, ordinal, or selector match from this negative inventory certificate.
    element.source_sibling = &proofs[0];
    for ([_][]const u8{ "div.NavHead div.NavFrame", "#owner div.NavFrame", "div:nth-child(1) div.NavFrame", "div.NavHead > div.NavFrame" }) |selector| {
        const sheet = try std.fmt.allocPrint(a, "div.NavFrame{{border:1px solid #aaaaaa}}{s}{{border-style:hidden}}", .{selector});
        var uncertain = try parseForTargetAlloc(a, sheet, .screen); defer uncertain.deinit();
        try std.testing.expect((try uncertain.resolveContainerIn(a, &element, "")).unresolved);
    }
}


test "legacy cell valign is a lower priority hint and text valign typo has no CSS effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var styles = try parseAlloc(a, "td.named{vertical-align:top}td.unsupported{vertical-align:bottom}td.uncertain:hover{vertical-align:top}"); defer styles.deinit();
    const html_hint: ElementContext = .{ .legacy_vertical_align = "TOP" };
    const literal = try styles.resolveCellWithContextAndHints(a, 0, 0, "", html_hint, false, null, null, "background:#f8f8f8;text-align:left;text-valign:top");
    try std.testing.expect(!literal.unresolved and literal.style.?.vertical_align == .top);
    const typo_only = try styles.resolveCellWithContextAndHints(a, 0, 0, "", .{}, false, null, null, "text-valign:top");
    try std.testing.expect(!typo_only.unresolved and typo_only.style == null);
    const unsupported = try styles.resolveCellWithContextAndHints(a, styles.classScope("unsupported"), 0, "unsupported", html_hint, false, null, null, "");
    try std.testing.expect(unsupported.unresolved and (unsupported.style == null or unsupported.style.?.vertical_align == null));
    const override = try styles.resolveCellWithContextAndHints(a, 0, 0, "", .{ .legacy_vertical_align = "bottom" }, false, null, null, "vertical-align:top");
    try std.testing.expect(!override.unresolved and override.style.?.vertical_align == .top);
    const named = try styles.resolveCellWithContextAndHints(a, styles.classScope("named"), 0, "named", .{ .legacy_vertical_align = "middle" }, false, null, null, "");
    try std.testing.expect(!named.unresolved and named.style.?.vertical_align == .top);
    const unknown = try styles.resolveCellWithContextAndHints(a, styles.classScope("uncertain"), 0, "uncertain", html_hint, false, null, null, "");
    try std.testing.expect(unknown.unresolved);
    for ([_][]const u8{ "middle", "bottom", "baseline", "unknown", " TOP ", "top ", " top", "top\t" }) |hint| {
        try std.testing.expect((try resolveInlineCellWithVerticalHintAlloc(a, null, hint, "")).unresolved);
        try std.testing.expect((try styles.resolveCellWithContextAndHints(a, 0, 0, "", .{ .legacy_vertical_align = hint }, false, null, null, "")).unresolved);
    }
    for ([_][]const u8{ "vertical-align:bottom", "vertical-align:var(--where)", "all:initial", "all:unset", "vertical-align:inherit", "unknown-property:top", "text-valign-unknown:top" }) |css| {
        try std.testing.expect((try styles.resolveCellWithContextAndHints(a, 0, 0, "", html_hint, false, null, null, css)).unresolved);
    }
    const inline_hint = try resolveInlineCellWithVerticalHintAlloc(a, null, "top", "text-valign:top");
    try std.testing.expect(!inline_hint.unresolved and inline_hint.style.?.vertical_align == .top);
    try std.testing.expect((try styles.resolveTableWithContext(a, 0, "", html_hint, null, "vertical-align:top")).unresolved);
}


test "preferred cell width keeps CSS priority auto and unknown above exact legacy hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var styles = try parseAlloc(a, ".known{width:20%}.unknown:hover{width:30%}.important{width:25%!important}"); defer styles.deinit();
    const F = struct {
        fn cell(allocator: std.mem.Allocator, profile: *const Profile, names: []const u8, hint: ?[]const u8, css: []const u8) std.mem.Allocator.Error!CellResolution {
            return profile.resolveCellWithContextAndHints(allocator, profile.classScope(names), 0, names,
                .{ .legacy_cell_width = hint }, false, null, null, css);
        }
    };
    const actual = try F.cell(a, &styles, "", "80%", "width:48%");
    try std.testing.expect(!actual.unresolved);
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .percent, .value = 48 }, actual.style.?.width.?);
    const named = try F.cell(a, &styles, "known", "80%", "");
    try std.testing.expectEqual(@as(f32, 20), named.style.?.width.?.value);
    const important = try F.cell(a, &styles, "important", "80%", "width:48%");
    try std.testing.expectEqual(@as(f32, 25), important.style.?.width.?.value);
    for ([_][]const u8{ "width:auto", "width:initial", "width:unset" }) |css| {
        const auto = try F.cell(a, &styles, "", "80%", css);
        try std.testing.expect(!auto.unresolved and (auto.style == null or auto.style.?.width == null));
    }
    for ([_][]const u8{ "width:var(--w)", "width:2rem", "width:inherit", "width:48%;box-sizing:border-box", "width:48%;box-sizing:content-box", "all:initial", "all:unset" }) |css| {
        const unknown = try F.cell(a, &styles, "", "80%", css);
        try std.testing.expect(unknown.unresolved and (unknown.style == null or unknown.style.?.width == null));
    }
    const uncertain = try F.cell(a, &styles, "unknown", "80%", "");
    try std.testing.expect(uncertain.unresolved and (uncertain.style == null or uncertain.style.?.width == null));
    for ([_][]const u8{ "width:-1px", "width:nonsense", "width:1_0px", "width:48%;width:-2em" }) |css| {
        const valid_prior = try F.cell(a, &styles, "", "80%", css);
        try std.testing.expect(!valid_prior.unresolved);
        const expected: f32 = if (std.mem.startsWith(u8, css, "width:48%")) 48 else 80;
        try std.testing.expectEqual(expected, valid_prior.style.?.width.?.value);
    }
}

test "preferred cell width separates HTML zero omission CSS zero percent above100 and minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const absent = try resolveInlineCellWithLegacyHintsAlloc(a, null, null, null, "");
    try std.testing.expect(!absent.unresolved and absent.style == null);
    for ([_][]const u8{ "0", "0%", "000", "000%" }) |hint| {
        const zero_hint = try resolveInlineCellWithLegacyHintsAlloc(a, null, null, hint, "");
        try std.testing.expect(!zero_hint.unresolved and zero_hint.style == null);
    }
    for ([_][]const u8{ "120%", "80" }, [_]types.StyleWidth{ .{ .unit = .percent, .value = 120 }, .{ .unit = .px, .value = 80 } }) |hint, expected| {
        const result = try resolveInlineCellWithLegacyHintsAlloc(a, null, null, hint, "");
        try std.testing.expect(!result.unresolved and result.style.?.min_width == null);
        try std.testing.expectEqualDeep(expected, result.style.?.width.?);
    }
    for ([_][]const u8{ "2em", "-1", "80px", "var(--w)", " 80% " }) |hint|
        try std.testing.expect((try resolveInlineCellWithLegacyHintsAlloc(a, null, null, hint, "")).unresolved);
    const independent = try resolveInlineCellWithLegacyHintsAlloc(a, null, "top", "80%", "width:2em;min-width:3em");
    try std.testing.expect(!independent.unresolved and independent.style.?.vertical_align == .top);
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .em, .value = 2 }, independent.style.?.width.?);
    try std.testing.expectEqualDeep(types.StyleLength{ .unit = .em, .value = 3 }, independent.style.?.min_width.?);
    const zero = try resolveInlineCellWithLegacyHintsAlloc(a, null, null, "80%", "width:0");
    try std.testing.expect(!zero.unresolved and zero.style.?.width.?.value == 0);
}

test "automatic local scrollport cascade retains priority exact axes and unsupported contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const auto_only = try resolveInlineContainerAlloc(a, "overflow:auto");
    try std.testing.expect(auto_only.specified and !auto_only.unresolved and auto_only.style.overflow == .auto);
    const actual_japanese = try resolveInlineContainerAlloc(a, "width:auto;margin:0px;overflow:auto;");
    try std.testing.expect(!actual_japanese.unresolved and actual_japanese.style.width.? == .auto);
    try std.testing.expectEqualDeep(types.StyleEdges.all(.{ .unit = .px, .value = 0 }), actual_japanese.style.margins.?);
    const actual_chinese = try resolveInlineContainerAlloc(a, "overflow:auto; max-width:500px; font-size:100%");
    try std.testing.expect(!actual_chinese.unresolved and actual_chinese.style.overflow == .auto);
    try std.testing.expectEqualDeep(types.StyleWidth{ .unit = .px, .value = 500 }, actual_chinese.style.max_width.?.length);
    for ([_][]const u8{ "overflow:auto;overflow:visible", "overflow:auto;overflow-x:visible;overflow-y:visible" }) |css| {
        const reset = try resolveInlineContainerAlloc(a, css);
        try std.testing.expect(!reset.unresolved and reset.style.overflow == null);
    }
    var profile = try parseAlloc(a, ".box{overflow:auto!important}.unknown:hover{overflow:auto}"); defer profile.deinit();
    const box: TextElement = .{ .tag = "div", .classes = "box" };
    const important = try profile.resolveContainerIn(a, &box, "overflow:visible");
    try std.testing.expect(!important.unresolved and important.style.overflow == .auto);
    const unknown: TextElement = .{ .tag = "div", .classes = "unknown" };
    try std.testing.expect((try profile.resolveContainerIn(a, &unknown, "")).unresolved);
    for ([_][]const u8{
        "overflow:hidden", "overflow:scroll", "overflow:var(--unknown)", "overflow:inherit", "all:initial;overflow:auto",
        "overflow:auto;overflow-x:visible", "overflow-x:auto;overflow-y:auto", "overflow:visible auto",
        "overflow:auto;height:0", "overflow:auto;min-height:0", "overflow:auto;display:flex", "overflow:auto;flex:none",
        "overflow:auto;position:relative", "overflow:auto;float:right", "overflow:auto;column-count:2",
        "overflow:auto;width:50%", "overflow:auto;max-width:50%", "overflow:auto;margin-bottom:-1px",
    }) |css| {
        errdefer std.debug.print("SCROLLPORT_REFUSAL css={s}\n", .{css});
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    }
}

test "base auto Container margin cascade preserves values resets and numeric old representation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const actual = try resolveInlineContainerAlloc(a, "background:gainsboro;margin:0 auto;text-align:center");
    try std.testing.expect(!actual.unresolved and actual.specified and actual.style.margins == null);
    const margins = actual.style.margin_values.?;
    try std.testing.expect(margins.left == .auto and margins.right == .auto);
    try std.testing.expectEqualDeep(types.StyleLength{ .unit = .px, .value = 0 }, margins.top.length);
    try std.testing.expectEqualDeep(margins.top, margins.bottom);
    try std.testing.expectEqualStrings("#dcdcdc", actual.style.background.?.rgb);
    try std.testing.expectEqual(types.CellTextAlign.center, actual.style.text_align.?);
    var profile = try parseForTargetAlloc(a, ".box{margin:auto!important;margin-left:4px!important}", .screen); defer profile.deinit();
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    const selected = try profile.resolveContainerIn(a, &node, "margin:0;margin-right:-2em!important");
    try std.testing.expect(!selected.unresolved);
    try std.testing.expect(selected.style.margin_values.?.top == .auto and selected.style.margin_values.?.bottom == .auto);
    try std.testing.expectEqual(@as(f32, 4), selected.style.margin_values.?.left.length.value);
    try std.testing.expectEqualDeep(types.StyleLength{ .unit = .em, .value = -2 }, selected.style.margin_values.?.right.length);
    const reset = try resolveInlineContainerAlloc(a, "margin:auto;margin:unset;margin-left:3px");
    try std.testing.expect(!reset.unresolved and reset.style.margin_values == null);
    try std.testing.expectEqual(@as(f32, 3), reset.style.margins.?.left.value);
    try std.testing.expectEqual(@as(f32, 0), reset.style.margins.?.right.value);
    const numeric = try resolveInlineContainerAlloc(a, "margin:1em -2px -.5em 0");
    try std.testing.expect(!numeric.unresolved and numeric.style.margin_values == null);
    try std.testing.expectEqual(@as(f32, -2), numeric.style.margins.?.right.value);
    try std.testing.expectEqual(@as(f32, -0.5), numeric.style.margins.?.bottom.value);
    try std.testing.expect(!containerStyleEqual(actual.style, reset.style));
    for ([_][]const u8{ "margin:auto", "margin:AUTO 2em auto -1px", "width:200px;max-width:100%;margin:0 auto", "display:flex;flex:none;margin-left:auto", "float:left;margin:auto" }) |css| {
        const result = try resolveInlineContainerAlloc(a, css);
        try std.testing.expect(!result.unresolved and result.style.margin_values != null and result.style.margins == null);
    }
}

test "base auto margins preserve conditional selector reset and nonmargin uncertainty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const node: TextElement = .{ .tag = "div", .classes = "box" };
    for ([_][]const u8{ ".unknown .box{margin:auto!important}", "@media screen and (max-width:700px){.box{margin:auto!important}}", ".box:hover{margin:auto!important}" }) |css| {
        var profile = try parseForTargetAlloc(a, css, .screen); defer profile.deinit();
        try std.testing.expect((try profile.resolveContainerIn(a, &node, "margin:0")).unresolved);
    }
    // The ordinary conditional declaration loses to the exact inline winner
    // in both viewport states; it must not manufacture an unresolved alternative.
    var ordinary = try parseForTargetAlloc(a, "@media screen and (max-width:700px){.box{margin:auto}}", .screen); defer ordinary.deinit();
    const overridden = try ordinary.resolveContainerIn(a, &node, "margin:0");
    const zero = try resolveInlineContainerAlloc(a, "margin:0");
    try std.testing.expect(!overridden.unresolved and !zero.unresolved);
    try std.testing.expectEqualDeep(zero.style, overridden.style);
    try std.testing.expect(overridden.style.margins != null and overridden.style.margin_values == null and overridden.style.screen_max_width == null);
    // Without the inline winner, the conditional margin difference remains
    // outside this single-alternative projection and is still refused.
    try std.testing.expect((try ordinary.resolveContainerIn(a, &node, "")).unresolved);
    for ([_][]const u8{ "margin:auto inherit", "margin:0 auto 0 auto 0", "margin:10% auto", "margin:var(--x)", "margin:calc(1px) auto", "margin:inherit", "margin:auto;all:initial", "margin:auto;padding:auto", "margin:auto;position:absolute", "margin:auto;display:grid", "margin:auto;margin-inline-start:2px" }) |css|
        try std.testing.expect((try resolveInlineContainerAlloc(a, css)).unresolved);
    // Existing Table and BlockStyle contracts receive no base auto capability.
    try std.testing.expect((try resolveInlineTableAlloc(a, "margin:auto")).unresolved);
    var empty = try parseAlloc(a, ""); defer empty.deinit();
    try std.testing.expect((try empty.resolveBlockGeometryIn(a, &node, "margin:auto")).unresolved);
}


test "selected page stylesheet root proves descendants but never an unobserved parent edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var page = try parseForTargetAlloc(a, ".mw-parser-output .panel{background:#123456}.mw-parser-output>.panel{color:#abcdef}", .screen); defer page.deinit();
    page.page_style_parent = &global;
    const root: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
    const child: TextElement = .{ .tag = "div", .classes = "panel", .page_style_root = &root };
    const rules = try page.containerRuleMatchesIn(a, &child); defer a.free(rules.rules);
    try std.testing.expect(!rules.unresolved);
    try std.testing.expectEqual(@as(usize, 2), rules.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.known, rules.rules[0].match);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, rules.rules[1].match);
    const paint = try page.resolveTextPaint(a, &child, "");
    try std.testing.expect(paint.color != null and paint.color.? == .unknown);
    var physical = child; physical.parent = &root; physical.physical_ancestry_complete = true;
    const actual = try page.containerRuleMatchesIn(a, &physical); defer a.free(actual.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.known, actual.rules[1].match);
    const skipped: TextElement = .{ .tag = "figure" };
    var logical = child; logical.parent = &skipped;
    const unknown = try page.containerRuleMatchesIn(a, &logical); defer a.free(unknown.rules);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, unknown.rules[1].match);

    // The normal selected-page matcher uses ID specificity above 32 bits.
    // A later class rule must not replace that winner; equal ranks keep order.
    const alignment_css = ".mw-parser-output #chosen{text-align:right}.mw-parser-output .panel{text-align:left}";
    var alignment_page = try parseForTargetAlloc(a, alignment_css, .screen); defer alignment_page.deinit();
    alignment_page.page_style_parent = &global;
    var aligned = child; aligned.id = "chosen";
    const alignment_rules = try alignment_page.containerRuleMatchesIn(a, &aligned); defer a.free(alignment_rules.rules);
    try std.testing.expectEqual(@as(usize, 2), alignment_rules.rules.len);
    try std.testing.expect(alignment_rules.rules[0].specificity > std.math.maxInt(u32));
    try std.testing.expect(alignment_rules.rules[1].specificity < alignment_rules.rules[0].specificity);
    try std.testing.expect(alignment_rules.rules[1].order > alignment_rules.rules[0].order);
    try std.testing.expectEqualDeep(AlignmentResolution{ .value = .right, .specified = true },
        try alignment_page.resolveAlignmentIn(a, &aligned, null, ""));
    var equal_rank = try parseForTargetAlloc(a, alignment_css ++ ".mw-parser-output #chosen{text-align:center}", .screen); defer equal_rank.deinit();
    equal_rank.page_style_parent = &global;
    try std.testing.expectEqualDeep(AlignmentResolution{ .value = .center, .specified = true },
        try equal_rank.resolveAlignmentIn(a, &aligned, null, ""));
}

test "selected page stylesheet source loss retains refusal and global callers keep their old domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, ".panel{color:#123456}", .screen); defer global.deinit();
    var selected = try parseForTargetAlloc(a, ".panel{color:#123456}", .screen); defer selected.deinit(); selected.page_style_parent = &global;
    const absent: TextElement = .{ .tag = "div", .classes = "panel" };
    try std.testing.expect((try selected.containerRuleMatchesIn(a, &absent)).unresolved);
    const refused = try selected.resolveTextPaint(a, &absent, "color:#abcdef");
    try std.testing.expect(refused.color != null and refused.color.? == .unknown);
    const legacy = try global.resolveTextPaint(a, &absent, "");
    try std.testing.expect(legacy.color != null and legacy.color.? == .value);
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    var present = absent; present.page_style_root = &root;
    const accepted = try selected.resolveTextPaint(a, &present, "");
    try std.testing.expectEqualDeep(legacy, accepted);
}

test "selected page stylesheet table ancestry uses only its exact root capability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var page = try parseForTargetAlloc(a, ".mw-parser-output .table{background:#123456}", .screen); defer page.deinit(); page.page_style_parent = &global;
    const root: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
    const actual = try page.resolveTableWithContext(a, 0, "table", .{ .page_style_root = &root }, null, "");
    try std.testing.expect(!actual.unresolved);
    try std.testing.expectEqualStrings("#123456", actual.style.?.background.?);
    const missing = try page.resolveTableWithContext(a, 0, "table", .{ .ancestor_classes = "mw-parser-output" }, null, "");
    try std.testing.expect(missing.unresolved);
}


test "selected parser root never turns unknown outer Table or Cell ancestors into absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var page = try parseForTargetAlloc(a, ".mw-parser-output .table{background:#123456}.Boxmerge .table{background:red!important}.mw-parser-output td{background:#123456}.Boxmerge td{background:red!important}", .screen); defer page.deinit();
    page.page_style_parent = &global;
    const root: TextElement = .{ .tag = "div", .classes = "mw-content-ltr mw-parser-output" };
    const unknown: ElementContext = .{ .page_style_root = &root };
    try std.testing.expect((try page.resolveTableWithContext(a, 0, "table", unknown, null, "")).unresolved);
    try std.testing.expect((try page.resolveCellWithContext(a, 0, 0, "", unknown, false, null, "")).unresolved);
    const complete: ElementContext = .{ .page_style_root = &root, .ancestor_classes = "mw-content-ltr mw-parser-output" };
    const table = try page.resolveTableWithContext(a, 0, "table", complete, null, "");
    try std.testing.expect(!table.unresolved);
    try std.testing.expectEqualStrings("#123456", table.style.?.background.?);
    const cell = try page.resolveCellWithContext(a, 0, 0, "", complete, false, null, "");
    try std.testing.expect(!cell.unresolved);
    try std.testing.expectEqualStrings("#123456", cell.background.?);
    const present: ElementContext = .{ .page_style_root = &root, .ancestor_classes = "mw-parser-output Boxmerge" };
    const changed = try page.resolveTableWithContext(a, 0, "table", present, null, "");
    try std.testing.expect(!changed.unresolved);
    try std.testing.expectEqualStrings("#ff0000", changed.style.?.background.?);
}


test "selected page join retains global rules order priorities and independent next page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const global_css = try a.dupe(u8, ".panel{width:10px;background:#112233!important}.global{height:7px}");
    var global = try parseSourcesForTargetAlloc(a, &.{.{ .css = global_css, .base_url = "https://example.invalid/Common.css", .byte_start = 4 }}, .screen);
    defer global.deinit();
    // Inputs are retained in the profile's own arena, not in caller scratch.
    global_css[0] = '!';
    const authored: Source = .{ .css = ".mw-parser-output .panel{width:20px;background:#abcdef}", .base_url = "", .byte_start = 81 };
    var selected = try joinPageSourcesAlloc(a, &global, &.{}, &.{authored}); defer selected.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    const node: TextElement = .{ .tag = "div", .classes = "panel global", .page_style_root = &root };
    const result = try selected.resolveContainerIn(a, &node, "");
    try std.testing.expect(!result.unresolved);
    try std.testing.expectEqual(@as(f32, 20), result.style.width.?.length.value);
    try std.testing.expectEqual(@as(f32, 7), result.style.height.?.value);
    try std.testing.expectEqualDeep(types.ContainerColor{ .rgb = "#112233" }, result.style.background.?);
    try std.testing.expectEqual(@as(usize, 2), selected.sources.len);
    try std.testing.expectEqualDeep(global.sources[0], selected.sources[0]);
    try std.testing.expectEqual(@as(usize, 81), selected.sources[1].byte_start);
    try std.testing.expect(selected.sources[1].rule_begin >= selected.sources[0].rule_end);
    var absent = node; absent.page_style_root = null;
    try std.testing.expect((try selected.resolveContainerIn(a, &absent, "")).unresolved);
    const unchanged = try global.resolveContainerIn(a, &absent, "");
    try std.testing.expect(!unchanged.unresolved);
    try std.testing.expectEqual(@as(f32, 10), unchanged.style.width.?.length.value);
    var next = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ".panel{width:30px}", .base_url = "" }}); defer next.deinit();
    const other = try next.resolveContainerIn(a, &node, "");
    try std.testing.expectEqual(@as(f32, 30), other.style.width.?.length.value);
    try std.testing.expectError(error.InvalidStyleProfile, joinPageSourcesAlloc(a, &selected, &.{}, &.{}));
}


test "complete emitted page sources keep paragraph margins and unresolved conditional winners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "p{margin-bottom:2px}", .screen); defer global.deinit();
    const emitted: Source = .{ .css = "p{margin:4px 0 5px 0}", .base_url = "https://example.invalid/core.css" };
    const authored: Source = .{ .css = ".mw-parser-output p{margin-bottom:3px}", .base_url = "", .byte_start = 90 };
    var selected = try joinPageSourcesAlloc(a, &global, &.{emitted}, &.{authored}); defer selected.deinit();
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    const node: TextElement = .{ .tag = "p", .page_style_root = &root };
    const matches = try selected.containerRuleMatchesIn(a, &node); defer a.free(matches.rules);
    try std.testing.expect(!matches.unresolved);
    try std.testing.expectEqual(@as(usize, 3), matches.rules.len);
    try std.testing.expectEqualStrings("margin:4px 0 5px 0", matches.rules[0].css);
    try std.testing.expectEqualStrings("margin-bottom:2px", matches.rules[1].css);
    try std.testing.expectEqualStrings("margin-bottom:3px", matches.rules[2].css);
    try std.testing.expect(matches.rules[0].order < matches.rules[1].order and matches.rules[1].order < matches.rules[2].order);
    var uncertain = try joinPageSourcesAlloc(a, &global,
        &.{.{ .css = "@supports(display:grid){p{margin-top:10px!important}}", .base_url = "https://example.invalid/core.css" }}, &.{authored});
    defer uncertain.deinit();
    const unknown = try uncertain.containerRuleMatchesIn(a, &node); defer a.free(unknown.rules);
    try std.testing.expect(!unknown.unresolved and unknown.rules.len != 0);
    try std.testing.expect(unknown.rules[0].match == .unknown or unknown.rules[0].rank_unknown or unknown.rules[0].viewport != .all);
}


test "selected page outer nodes prove positive descendants without absent or physical edge claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var selected = try joinPageSourcesAlloc(a, &global, &.{.{ .css = ".mw-body-content .mw-parser-output .panel{background:#123456;color:#654321}", .base_url = "" }}, &.{}); defer selected.deinit();
    const outer: TextElement = .{ .tag = "div", .classes = "mw-body-content" };
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .parent = &outer };
    const node: TextElement = .{ .tag = "div", .classes = "panel", .page_style_root = &root };
    const known = try selected.resolveContainerIn(a, &node, "");
    try std.testing.expect(!known.unresolved);
    try std.testing.expectEqualStrings("#123456", known.style.background.?.rgb);
    try std.testing.expectEqualStrings("#654321", (try selected.resolveTextPaint(a, &node, "")).color.?.value);
    const root_only: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    var absent = node; absent.page_style_root = &root_only;
    try std.testing.expect((try selected.resolveContainerIn(a, &absent, "")).unresolved);
    var child = try joinPageSourcesAlloc(a, &global, &.{.{ .css = ".mw-body-content>.mw-parser-output>.panel{background:#123456}", .base_url = "" }}, &.{}); defer child.deinit();
    try std.testing.expect((try child.resolveContainerIn(a, &node, "")).unresolved);
    try std.testing.expect(!node.physical_ancestry_complete and !root.physical_ancestry_complete and !outer.ancestry_complete);
}


test "page ancestor effects remain a refusal with exact rule source and legacy queries unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen);
    defer global.deinit();
    const outer: TextElement = .{ .tag = "body", .classes = "skin" };
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .parent = &outer };
    for ([_][]const u8{ "font-weight:bold", "color:#123456", "line-height:1.6", "font-feature-settings:normal", "opacity:0.5", "tab-size:4" }) |declaration| {
        const css = try std.fmt.allocPrint(a, ".mw-parser-output{{{s}}}", .{declaration});
        var selected = try joinPageSourcesAlloc(a, &global, &.{.{ .css = css, .base_url = "https://example.invalid/root.css" }}, &.{});
        defer selected.deinit();
        const failure = (try selected.pageAncestorEffectBlockerIn(a, &root)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(PageAncestorEffectBlocker.Reason.declaration, failure.reason);
        try std.testing.expectEqual(@as(usize, 0), failure.ancestor_depth);
        try std.testing.expectEqualStrings(declaration, failure.declaration);
        try std.testing.expectEqualStrings(".mw-parser-output", failure.rule.?.provenance.?.selector);
        try std.testing.expectEqual(@as(usize, 0), failure.rule.?.provenance.?.source_index);
        try std.testing.expectEqualStrings("https://example.invalid/root.css", selected.sources[0].base_url);
        try std.testing.expect((try selected.pageAncestorEffectBlockerIn(a, null)).?.reason == .missing_root);
    }
    var child_only = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ".panel{color:#123456}:root{--panel:red}", .base_url = "" }});
    defer child_only.deinit();
    try std.testing.expect((try child_only.pageAncestorEffectBlockerIn(a, &root)) == null);
    const child: TextElement = .{ .tag = "span", .classes = "panel", .page_style_root = &root };
    const missing_path = (try child_only.pageUnprovedInheritanceBlockerIn(a, &root)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(PageAncestorEffectBlocker.Reason.unproved_ancestor_path, missing_path.reason);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, missing_path.rule.?.match);
    try std.testing.expectEqualStrings(".panel", missing_path.rule.?.provenance.?.selector);
    const own = try child_only.resolveTextPaint(a, &child, "color:#abcdef");
    try std.testing.expectEqualStrings("#abcdef", own.color.?.value);
    var inherited = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = "body{font-style:italic}", .base_url = "" }});
    defer inherited.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try inherited.pageAncestorEffectBlockerIn(a, &root)).?.ancestor_depth);
    try std.testing.expect((try global.pageAncestorEffectBlockerIn(a, null)) == null);
    var custom_only = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ":root{--panel:red}", .base_url = "" }});
    defer custom_only.deinit();
    try std.testing.expect((try custom_only.pageUnprovedInheritanceBlockerIn(a, &root)) == null);
    for ([_][]const u8{ ".generated{color:red}", ".generated{opacity:0.5}", ".generated{width:20px}", "@media screen and (max-width:600px){.generated{font-weight:bold}}" }) |css| {
        var possible = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = css, .base_url = "" }});
        defer possible.deinit();
        const failure = (try possible.pageUnprovedInheritanceBlockerIn(a, &root)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(PageAncestorEffectBlocker.Reason.unproved_ancestor_path, failure.reason);
        try std.testing.expectEqual(ContainerSelectorMatch.unknown, failure.rule.?.match);
    }
}


test "complete observed parent text cascade never invents a second parser root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var styles = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ".root{font-weight:bold;color:#123456;font-style:italic}.root .root{font-weight:normal!important}.root > p{color:inherit}", .base_url = "" }}); defer styles.deinit();
    var html: TextElement = .{ .tag = "html", .ancestry_complete = true, .physical_ancestry_complete = true, .observed_inline_style = "" };
    var root: TextElement = .{ .tag = "div", .classes = "root", .parent = &html, .ancestry_complete = true, .physical_ancestry_complete = true, .observed_inline_style = "" };
    html.page_style_root = &root; root.page_style_root = &root;
    const proof: SourceRootChildProof = .{ .anchor_start = 0, .anchor_end = 10, .name_start = 1, .name_len = 1, .attrs_start = 2, .attrs_len = 0 };
    const child: TextElement = .{ .tag = "p", .parent = &root, .page_style_root = &root, .source_root_child = &proof, .ancestry_complete = true, .physical_ancestry_complete = true };
    const paint = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", null);
    try std.testing.expect(paint.weight.?.value and paint.font_style.?.value);
    try std.testing.expectEqualStrings("#123456", paint.color.?.value);
    const own = try styles.resolveTextPaintWithObservedInheritance(a, &child, "font-weight:normal;color:#abcdef;font-style:normal", null);
    try std.testing.expect(!own.weight.?.value and !own.font_style.?.value);
    try std.testing.expectEqualStrings("#abcdef", own.color.?.value);
    try std.testing.expect((try styles.pageUnprovedInheritanceBlockerIn(a, &root)) != null);
    var unproved = child; unproved.source_root_child = null; unproved.physical_ancestry_complete = false;
    const legacy = try styles.resolveTextPaintWithObservedInheritance(a, &unproved, "", null);
    try std.testing.expectEqualDeep(try styles.resolveTextPaintWithCustom(a, &unproved, "", null), legacy);
    root.observed_inline_style = null;
    const missing = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", null);
    try std.testing.expect(missing.weight.? == .unknown and missing.color.? == .unknown and missing.font_style.? == .unknown);
}

test "complete parent path preserves unknown variable effects and exact physical nonmatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var styles = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ".root{color:var(--ancestor);font-weight:bold}.missing p{font-weight:normal!important}.root > p{font-style:italic}", .base_url = "" }}); defer styles.deinit();
    var root: TextElement = .{ .tag = "div", .classes = "root", .ancestry_complete = true, .physical_ancestry_complete = true, .observed_inline_style = "" }; root.page_style_root = &root;
    const proof: SourceRootChildProof = .{ .anchor_start = 0, .anchor_end = 10, .name_start = 1, .name_len = 1, .attrs_start = 2, .attrs_len = 0 };
    var child: TextElement = .{ .tag = "p", .parent = &root, .page_style_root = &root, .source_root_child = &proof, .physical_ancestry_complete = true, .ancestry_complete = true };
    const known = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", null);
    try std.testing.expect(known.weight.?.value and known.font_style.?.value and known.color.? == .unknown);
    child.physical_ancestry_complete = false; child.ancestry_complete = false;
    const uncertain = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", null);
    try std.testing.expect(uncertain.weight.? == .unknown and uncertain.font_style.? == .unknown);
    var toc_styles = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ".root{font-weight:bold}.vector-toc-available p{font-weight:normal!important}.vector-toc-available{color:#ff0000}", .base_url = "" }}); defer toc_styles.deinit();
    var alternative = root; alternative.classes = "root vector-toc-available"; alternative.page_style_root = &alternative;
    root.alternative_ancestry = &alternative;
    child.physical_ancestry_complete = true; child.ancestry_complete = true;
    var alternative_child = child; alternative_child.parent = &alternative; alternative_child.page_style_root = &alternative;
    child.alternative_ancestry = &alternative_child;
    const toc = try toc_styles.resolveTextPaintWithObservedInheritance(a, &child, "", null);
    try std.testing.expect(toc.weight.? == .unknown and toc.color.? == .unknown);
    const independent = try toc_styles.resolveTextPaintWithObservedInheritance(a, &child, "color:#123456", null);
    try std.testing.expectEqualStrings("#123456", independent.color.?.value);
    var ordinal_styles = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = ".root > p:first-child{padding:1px}", .base_url = "" }}); defer ordinal_styles.deinit();
    const ordinal = try ordinal_styles.containerRuleMatchesIn(a, &child); defer a.free(ordinal.rules);
    try std.testing.expectEqual(@as(usize, 1), ordinal.rules.len);
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, ordinal.rules[0].match);
    alternative.observed_inline_style = "font-style:italic";
    try std.testing.expect((try toc_styles.resolveTextPaintWithObservedInheritance(a, &child, "", null)).font_style.? == .unknown);
}


test "inherited text resolves variables at each actual ancestor before descendant redefinition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const css = ":root{--ink:#112233}body{color:var(--ink)}.root{--ink:#445566}.vector-toc-available{--ink:#ff0000}";
    var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
    var styles = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = css, .base_url = "" }}); defer styles.deinit();
    try attachCustomProperties(&styles, &.{.{ .css = css, .base_url = "" }}, .{ .dark = null,
        .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "body" }, .{ .tag = "div", .classes = "root" } } });
    const custom = styles.custom_properties.?;
    var html: TextElement = .{ .tag = "html", .physical_ancestry_complete = true, .ancestry_complete = true, .observed_inline_style = "" };
    var body: TextElement = .{ .tag = "body", .parent = &html, .physical_ancestry_complete = true, .ancestry_complete = true, .observed_inline_style = "" };
    var root: TextElement = .{ .tag = "div", .classes = "root", .parent = &body, .physical_ancestry_complete = true, .ancestry_complete = true, .observed_inline_style = "" };
    html.page_style_root = &root; body.page_style_root = &root; root.page_style_root = &root;
    html.observed_custom_environment = try custom.element(a, .{ .complete = !custom.is_opaque }, .{ .tag = "html", .root = true }, "");
    body.observed_custom_environment = try custom.element(a, html.observed_custom_environment.?, .{ .tag = "body" }, "");
    root.observed_custom_environment = try custom.element(a, body.observed_custom_environment.?, .{ .tag = "div", .classes = "root" }, "");
    try CustomPropertyFixture.known(body.observed_custom_environment.?, "--ink", "#112233");
    try CustomPropertyFixture.known(root.observed_custom_environment.?, "--ink", "#445566");
    const proof: SourceRootChildProof = .{ .anchor_start = 0, .anchor_end = 10, .name_start = 1, .name_len = 1, .attrs_start = 2, .attrs_len = 0 };
    var child: TextElement = .{ .tag = "p", .parent = &root, .page_style_root = &root, .source_root_child = &proof, .physical_ancestry_complete = true, .ancestry_complete = true };
    const inherited = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", root.observed_custom_environment);
    try std.testing.expectEqualStrings("#112233", inherited.color.?.value);
    const own = try styles.resolveTextPaintWithObservedInheritance(a, &child, "color:var(--ink)", root.observed_custom_environment);
    try std.testing.expectEqualStrings("#445566", own.color.?.value);
    var alternate_html = html; alternate_html.classes = "vector-toc-available";
    var alternate_body = body; alternate_body.parent = &alternate_html;
    var alternate_root = root; alternate_root.parent = &alternate_body;
    alternate_html.page_style_root = &alternate_root; alternate_body.page_style_root = &alternate_root; alternate_root.page_style_root = &alternate_root;
    alternate_html.observed_custom_environment = try custom.element(a, .{ .complete = !custom.is_opaque }, .{ .tag = "html", .classes = alternate_html.classes, .root = true }, "");
    alternate_body.observed_custom_environment = try custom.element(a, alternate_html.observed_custom_environment.?, .{ .tag = "body" }, "");
    alternate_root.observed_custom_environment = try custom.element(a, alternate_body.observed_custom_environment.?, .{ .tag = "div", .classes = "root" }, "");
    html.alternative_ancestry = &alternate_html; body.alternative_ancestry = &alternate_body; root.alternative_ancestry = &alternate_root;
    var alternate_child = child; alternate_child.parent = &alternate_root; alternate_child.page_style_root = &alternate_root; child.alternative_ancestry = &alternate_child;
    try CustomPropertyFixture.known(alternate_body.observed_custom_environment.?, "--ink", "#ff0000");
    try CustomPropertyFixture.known(alternate_root.observed_custom_environment.?, "--ink", "#445566");
    // The final root values agree while the body colors do not. Never use that
    // final descendant agreement to manufacture an inherited ancestor color.
    const ambiguous = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", root.observed_custom_environment);
    try std.testing.expect(ambiguous.color.? == .unknown);
    const override = try styles.resolveTextPaintWithObservedInheritance(a, &child, "color:var(--ink)", root.observed_custom_environment);
    try std.testing.expectEqualStrings("#445566", override.color.?.value);
    alternate_body.observed_custom_environment = null;
    try std.testing.expect((try styles.resolveTextPaintWithObservedInheritance(a, &child, "", root.observed_custom_environment)).color.? == .unknown);
    try std.testing.expect((try styles.pageUnprovedInheritanceBlockerIn(a, &root)) != null);
}

test "ancestor variable environments preserve cycles unknown declarations and missing authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const proof: SourceRootChildProof = .{ .anchor_start = 0, .anchor_end = 10, .name_start = 1, .name_len = 1, .attrs_start = 2, .attrs_len = 0 };
    for ([_][]const u8{
        ":root{--a:var(--b);--b:var(--a)}.root{color:var(--a,#abcdef)}",
        ":root{--a:#123456}@supports(display:grid){.root{--a:#654321}}.root{color:var(--a,#abcdef)}",
        ":root{--a:#123456}.root{--escaped\\61:#abcdef;color:var(--a,#abcdef)}",
    }, 0..) |css, mode| {
        var global = try parseForTargetAlloc(a, "", .screen); defer global.deinit();
        var styles = try joinPageSourcesAlloc(a, &global, &.{}, &.{.{ .css = css, .base_url = "" }}); defer styles.deinit();
        try attachCustomProperties(&styles, &.{.{ .css = css, .base_url = "" }}, .{ .dark = null,
            .ancestors = &.{ .{ .tag = "html", .root = true }, .{ .tag = "div", .classes = "root" } } });
        const custom = styles.custom_properties.?;
        var html: TextElement = .{ .tag = "html", .physical_ancestry_complete = true, .ancestry_complete = true, .observed_inline_style = "" };
        var root: TextElement = .{ .tag = "div", .classes = "root", .parent = &html, .physical_ancestry_complete = true, .ancestry_complete = true, .observed_inline_style = "" };
        html.page_style_root = &root; root.page_style_root = &root;
        html.observed_custom_environment = try custom.element(a, .{ .complete = !custom.is_opaque }, .{ .tag = "html", .root = true }, "");
        root.observed_custom_environment = try custom.element(a, html.observed_custom_environment.?, .{ .tag = "div", .classes = "root" }, "");
        const child: TextElement = .{ .tag = "p", .parent = &root, .page_style_root = &root, .source_root_child = &proof, .physical_ancestry_complete = true, .ancestry_complete = true };
        const paint = try styles.resolveTextPaintWithObservedInheritance(a, &child, "", .{ .complete = true });
        if (mode == 0) {
            try std.testing.expect(root.observed_custom_environment.?.get("--a") == .invalid);
            // The generic custom evaluator retains CSS fallback semantics;
            // this paint admission requires a known binding and stays unknown.
            const fallback = try customColorValue(a, root.observed_custom_environment.?, "var(--a,#abcdef)");
            try std.testing.expect(fallback == .known);
            try std.testing.expectEqualStrings("#abcdef", fallback.known);
            const own = try styles.resolveTextPaintWithObservedInheritance(a, &child, "color:#123456", .{ .complete = true });
            try std.testing.expect(own.color != null and own.color.? == .value);
            try std.testing.expectEqualStrings("#123456", own.color.?.value);
        }
        try std.testing.expect(paint.color != null and paint.color.? == .unknown);
        root.observed_custom_environment = null;
        try std.testing.expect((try styles.resolveTextPaintWithObservedInheritance(a, &child, "", .{ .complete = true })).color.? == .unknown);
    }
}

test "table background none resets paint while omitted background and unsupported cell reset stay distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".paint{background:#aabbcc}"); defer profile.deinit();
    const context: ElementContext = .{ .ancestor_classes = "", .own_id = "", .font_size_consumed = true, .text_color_consumed = true };
    const omitted = try profile.resolveTableWithContext(a, 0, "paint", context, null, "");
    try std.testing.expect(!omitted.unresolved and omitted.background_specified);
    try std.testing.expectEqualStrings("#aabbcc", omitted.style.?.background.?);
    const quote = try profile.resolveTableWithContext(a, 0, "paint", context, null,
        "width:auto; background:none; margin-bottom:.5em; font-size:95%; color:#606060; text-align:left");
    try std.testing.expect(!quote.unresolved and quote.background_specified);
    try std.testing.expect(quote.style.?.background == null);
    try std.testing.expectEqualDeep(types.StyleLength{ .unit = .em, .value = 0.5 }, quote.style.?.margins.?.bottom);
    for ([_]bool{false, true}) |header| {
        const reset_cell = try profile.resolveCellWithContext(a, 0, 0, "paint", context, header, "#ff0000", "background:none");
        try std.testing.expect(reset_cell.unresolved and reset_cell.background_specified and reset_cell.background == null);
    }
    const reset_declaration = (try declarationAlloc(a, "background:none", 0)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(representedDeclaration(.table, reset_declaration));
    inline for (.{ Target.td, .th, .cell, .element }) |target| try std.testing.expect(!representedDeclaration(target, reset_declaration));
    const empty_cell = try resolveInlineCellAlloc(a, null, "");
    try std.testing.expect(!empty_cell.unresolved and !empty_cell.background_specified and empty_cell.background == null);
    const later = try profile.resolveTableWithContext(a, 0, "paint", context, null, "background:none;background:#112233");
    try std.testing.expect(!later.unresolved and later.background_specified);
    try std.testing.expectEqualStrings("#112233", later.style.?.background.?);
}

test "table background none respects important order and leaves unsupported paint strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ".paint{background:#aabbcc!important} .clear{background:none!important}"); defer profile.deinit();
    const context: ElementContext = .{ .ancestor_classes = "", .own_id = "" };
    const strong_color = try profile.resolveTableWithContext(a, 0, "paint", context, null, "background:none");
    try std.testing.expect(!strong_color.unresolved);
    try std.testing.expectEqualStrings("#aabbcc", strong_color.style.?.background.?);
    const strong_reset = try profile.resolveTableWithContext(a, 0, "paint", context, null, "background:none!important");
    try std.testing.expect(!strong_reset.unresolved and strong_reset.background_specified and strong_reset.style == null);
    const sheet_reset = try profile.resolveTableWithContext(a, 0, "clear", context, null, "background:#112233");
    try std.testing.expect(!sheet_reset.unresolved and sheet_reset.background_specified and sheet_reset.style == null);
    const cleared_image = try profile.resolveTableWithContext(a, 0, "", context, null, "background-image:url(a);background:none");
    try std.testing.expect(!cleared_image.unresolved and cleared_image.background_specified and cleared_image.style == null);
    for ([_][]const u8{ "background:none;background-image:url(a)", "background:none;background:linear-gradient(red,blue)",
        "background:none;background-size:cover", "background-color:none", "background-image:url(a)!important;background:none",
        "background:none;background-size:cover;background:#112233" }) |css| {
        const strict = try profile.resolveTableWithContext(a, 0, "", context, null, css);
        try std.testing.expect(strict.unresolved);
    }
    var uncertain = try parseAlloc(a, ".paint:hover{background:none}"); defer uncertain.deinit();
    const unknown = try uncertain.resolveTableWithContext(a, 0, "paint", context, null, "");
    try std.testing.expect(unknown.unresolved);
}


test "figure root direction first witness preserves existing decision and Profile-owned source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var profile = try parseAlloc(a, ".mw-content-ltr span{color:red}.mw-content-ltr em{color:blue}"); defer profile.deinit();
    var witness: Profile.FigureRootDirectionWitness = .{};
    const result = profile.figureRootDirectionUseWithWitness(null, null, null, null, false, null, &witness);
    try std.testing.expectEqual(profile.figureRootDirectionUse(null), result);
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, result);
    try std.testing.expectEqual(Profile.FigureRootDirectionWitness.Reason.terminal, witness.reason);
    try std.testing.expectEqual(@as(usize, 0), witness.rule_index);
    try std.testing.expect(!witness.custom_rule);
    try std.testing.expectEqualStrings(profile.figure_rules[0].css, witness.css);
    try std.testing.expect(witness.css.ptr == profile.figure_rules[0].css.ptr);
    var empty = try parseAlloc(a, ""); defer empty.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent,
        empty.figureRootDirectionUseWithWitness(null, null, null, null, false, null, &witness));
    try std.testing.expectEqual(Profile.FigureRootDirectionWitness.Reason.none, witness.reason);
    try std.testing.expectEqual(@as(usize, 0), witness.css.len);
}


test "functional figure root predicates retain only necessary positive caption class refutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const css = ".mw-cite-dir-auto:has(.reference-text:dir(ltr)){direction:ltr;text-align:left}";
    var actual = try parseAlloc(a, css); defer actual.deinit();
    try std.testing.expectEqual(@as(usize, 1), actual.figure_rules.len);
    const selector = actual.figure_rules[0].selector;
    try std.testing.expect(selector.uncertain and selector.root_predicate_unresolved);
    try std.testing.expectEqual(@as(usize, 1), selector.caption_class_guard.len);
    try std.testing.expectEqualStrings("mw-cite-dir-auto", selector.caption_class_guard[0]);
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCaptionClasses(null, "hintergrundfarbe2 rahmenfarbe1"));
    const incomplete: TextElement = .{ .tag = "td", .ancestry_complete = true };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCaptionClasses(&incomplete, ""));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent,
        actual.figureRootDirectionUseWithCompleteClasses(null, "hintergrundfarbe2 rahmenfarbe1", null, null, false, null, "mw-parser-output", null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, "mw-parser-output mw-cite-dir-auto", null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCompleteClasses(null, "mw-cite-dir-auto", null, null, false, null, "mw-parser-output", null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, actual.figureRootDirectionUse(null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCaptionClasses(null, "mw-cite-dir-auto"));
    const parent: TextElement = .{ .tag = "div", .classes = "mw-cite-dir-auto" };
    const child: TextElement = .{ .tag = "td", .parent = &parent };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCaptionClasses(&child, ""));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCompleteClasses(&child, "", null, null, false, null, "mw-parser-output", null));
    const alternate: TextElement = .{ .tag = "html", .classes = "mw-cite-dir-auto" };
    const paired: TextElement = .{ .tag = "td", .alternative_ancestry = &alternate };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCompleteClasses(&paired, "", null, null, false, null, "mw-parser-output", null));
    var cycle: TextElement = .{ .tag = "td" }; cycle.parent = &cycle;
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCompleteClasses(&cycle, "", null, null, false, null, "mw-parser-output", null));
    // Inner functional classes are not necessary classes of the subject.
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        actual.figureRootDirectionUseWithCaptionClasses(null, "mw-cite-dir-auto reference-text"));
    var negated = try parseAlloc(a, ":not(.mw-cite-dir-auto):has(.reference-text:dir(ltr)){direction:ltr}"); defer negated.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        negated.figureRootDirectionUseWithCaptionClasses(null, ""));
    var alternative = try parseAlloc(a, css ++ ":dir(ltr){direction:rtl}"); defer alternative.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        alternative.figureRootDirectionUseWithCaptionClasses(null, ""));
}


test "figure bare attribute presence is direction invariant but remains an uncertain match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    // Exact retained first predicate, with no attribute absence certificate.
    var profile = try parseAlloc(a, "figure [data-mw-tmh][data-mw-tmh][data-mw-tmh]{border:0}"); defer profile.deinit();
    try std.testing.expectEqual(@as(usize, 1), profile.figure_rules.len);
    const selector = profile.figure_rules[0].selector;
    try std.testing.expect(selector.uncertain and !selector.root_predicate_unresolved);
    try std.testing.expectEqual(@as(usize, 2), selector.chain.len);
    try std.testing.expectEqualStrings("figure", selector.chain[0].tag.?);
    try std.testing.expect(selector.chain[1].tag == null);
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output", .ancestry_complete = true };
    const figure: TextElement = .{ .tag = "figure", .parent = &root };
    const image: TextElement = .{ .tag = "img", .parent = &figure, .page_style_root = &root };
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, selector.matchIn(&image, true));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, profile.figureRootDirectionUse(null));
    // A preceding BODY can be outside the inserted root. Presence still has
    // equal truth in both alternatives; its value is deliberately unproved.
    for ([_][]const u8{ "[data-mw-tmh]{border:0}", "body [class] figcaption a{border:0}",
        "body [dir][lang] figcaption a{border:0}" }) |css| {
        var invariant = try parseAlloc(a, css); defer invariant.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent, invariant.figureRootDirectionUse(null));
    }
    for ([_][]const u8{
        "body [class~=\"mw-content-rtl\"] figcaption a{border:0}",
        "body [dir=rtl] figcaption a{border:0}",
        "figure [data-mw-tmh]:dir(ltr){border:0}",
        "figure [data-mw-tmh]:lang(th){border:0}",
        "figure [data-mw-tmh]:has(:dir(ltr)){border:0}",
        "figure :not([data-mw-tmh]){border:0}",
    }) |css| {
        var strict = try parseAlloc(a, css); defer strict.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved, strict.figureRootDirectionUse(null));
    }
    var builder: Builder = .{ .a = a };
    try std.testing.expect(!try builder.contentRootSubjectExcluded("figure [data-mw-tmh]"));
    for ([_][]const u8{ "[data-mw-tmh", "[data\\-mw-tmh]", "[class~=rtl]", "[dir=rtl]", "[data]:hover", ":not([data])", "[]", "[data][x=foo]" }) |part|
        try std.testing.expect(!Builder.bareRootAttributePresenceInvariant(part));
}


test "figure root uncertain chains retain complete-domain necessary ancestor classes without matching attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const css = "@media screen{html.skin-theme-clientpref-night .mw-parser-output [style*='background']{color:#202122}}";
    var profile = try parseAlloc(a, css); defer profile.deinit();
    const selector = profile.figure_rules[0].selector;
    try std.testing.expect(selector.uncertain and selector.root_predicate_unresolved and selector.caption_class_guard_requires_complete);
    try std.testing.expectEqual(@as(usize, 2), selector.caption_class_guard.len);
    try std.testing.expectEqualStrings("skin-theme-clientpref-night", selector.caption_class_guard[0]);
    try std.testing.expectEqualStrings("mw-parser-output", selector.caption_class_guard[1]);
    const day = "skin-theme-clientpref-day mw-parser-output";
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent,
        profile.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, day, null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        profile.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, null, null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        profile.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, "skin-theme-clientpref-night mw-parser-output", null));
    // The inventory is only a necessary-class refutation, never an attribute
    // value match, an outer HTML identity, or an invented root position.
    const root: TextElement = .{ .tag = "div", .classes = "mw-parser-output" };
    const span: TextElement = .{ .tag = "span", .parent = &root };
    try std.testing.expectEqual(ContainerSelectorMatch.unknown, selector.matchIn(&span, true));
    const night: TextElement = .{ .tag = "html", .classes = "skin-theme-clientpref-night" };
    const child: TextElement = .{ .tag = "td", .parent = &night };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        profile.figureRootDirectionUseWithCompleteClasses(&child, "", null, null, false, null, day, null));
    const paired: TextElement = .{ .tag = "td", .alternative_ancestry = &night };
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        profile.figureRootDirectionUseWithCompleteClasses(&paired, "", null, null, false, null, day, null));
    var cycle: TextElement = .{ .tag = "td" }; cycle.parent = &cycle;
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        profile.figureRootDirectionUseWithCompleteClasses(&cycle, "", null, null, false, null, day, null));
    var later = try parseAlloc(a, "body > html.skin-theme-clientpref-night .mw-parser-output [style*='background']{color:#202122}"); defer later.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.independent,
        later.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, day, null));
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        later.figureRootDirectionUseWithCompleteClasses(&child, "", null, null, false, null, day, null));
}

test "figure ancestor class refutation never uses attribute values functional alternatives or malformed chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var builder: Builder = .{ .a = a };
    for ([_][]const u8{
        "html:not(.night) [style*='background']", "html:is(.night,.day) [style*='background']",
        "html:has(.night) [style*='background']", "html.night:hover [style*='background']",
        "html.night + span [style*='background']", "html.night > > span", "html.night >",
        "html.night [style*=background", "html.n\\ight [style*='background']",
    }) |raw| try std.testing.expectEqual(@as(usize, 0), (try builder.figureNecessaryChainClasses(raw)).len);
    const from_value = try builder.figureNecessaryChainClasses("body [class~=mw-content-rtl] figcaption a");
    try std.testing.expectEqual(@as(usize, 0), from_value.len);
    for ([_][]const u8{
        "body [class~=mw-content-rtl] figcaption a{color:#202122}",
        "html:is(.night,.day) .mw-parser-output [style*='background']{color:#202122}",
        "html:not(.night) .mw-parser-output [style*='background']{color:#202122}",
        "html:has(.night) .mw-parser-output [style*='background']{color:#202122}",
        "html.night .mw-parser-output [style*='background'],body [class~=mw-content-rtl] figcaption a{color:#202122}",
    }) |css| {
        var unknown = try parseAlloc(a, css); defer unknown.deinit();
        try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
            unknown.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, "day mw-parser-output", null));
    }
    // A selector alternative with a present necessary ancestor must remain a
    // possible rule even when the other comma arm is independently refuted.
    var alternative = try parseAlloc(a, "html.night .mw-parser-output [style*='background'],html.day .mw-parser-output [style*='background']{color:#202122}"); defer alternative.deinit();
    try std.testing.expectEqual(Profile.FigureRootDirectionUse.unresolved,
        alternative.figureRootDirectionUseWithCompleteClasses(null, "", null, null, false, null, "day mw-parser-output", null));
}

test "border hash atoms preserve complete CSS name and dimension boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "1px solid#a1bdea", "solid#a1bdea 1px", "1px#a1bdea solid", "#a1bdea solid 1px", "solid 1px#a1bdea" }) |value| {
        const border = (try borderAlloc(a, value)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(border == .solid);
        try std.testing.expectEqual(types.StyleLengthUnit.px, border.solid.width.unit);
        try std.testing.expectEqual(@as(f32, 1), border.solid.width.value);
        try std.testing.expectEqualStrings("#a1bdea", border.solid.color);
    }
    for ([_][]const u8{ "1pxsolid#ff0000", "1px solid#ff0000solid", "1px solid#fff_", "1px solid#ff-0000", "1px solid#ff00000", "1px solid#fff#000", "1px solid#fff 2px", "1px solid#fff solid", "1px dotted#fff", "solid#fff", "1pxsolid #fff" }) |value|
        try std.testing.expect((try borderAlloc(a, value)) == null);
    var tokens: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), borderTokens("#ff0000solid", &tokens).?);
    try std.testing.expectEqualStrings("#ff0000solid", tokens[0]);
    try std.testing.expectEqual(@as(usize, 2), borderTokens("solid#ff0000", &tokens).?);
    try std.testing.expectEqualStrings("solid", tokens[0]);
    try std.testing.expectEqualStrings("#ff0000", tokens[1]);
}

test "table literal hash borders preserve cascade geometry and malformed value refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var profile = try parseAlloc(a, ""); defer profile.deinit();
    for ([_][]const u8{ "#a1bdea", "#c9d7e8" }) |color| {
        const css = try std.fmt.allocPrint(a, "clear:right;float:right;margin-left:0.5em;margin-bottom:0.5em;background:#ffffff;color:#000000;border:1px solid{s};text-align:right", .{color});
        const resolved = try profile.resolveTableWithContext(a, 0, "notheme", .{ .text_color_consumed = true }, null, css);
        try std.testing.expect(!resolved.unresolved);
        const style = resolved.style orelse return error.TestUnexpectedResult;
        const border = style.border orelse return error.TestUnexpectedResult;
        try std.testing.expect(border == .solid);
        try std.testing.expectEqualStrings(color, border.solid.color);
        try std.testing.expectEqual(@as(f32, 1), border.solid.width.value);
        try std.testing.expectEqual(types.StyleLengthUnit.px, border.solid.width.unit);
        try std.testing.expectEqual(types.TableFloatSide.right, style.float_side.?);
        try std.testing.expectEqual(types.FigureClear.right, style.clear.?);
        try std.testing.expectEqual(@as(f32, 0.5), style.margins.?.left.value);
        try std.testing.expectEqual(@as(f32, 0.5), style.margins.?.bottom.value);
        try std.testing.expectEqualStrings("#ffffff", style.background.?);
    }
    for ([_][]const u8{ "border:1px solid#ff0000solid", "border:1px solid#fff#000", "border:1px solid var(--unknown)" }) |css| {
        const resolved = try profile.resolveTableWithContext(a, 0, "", .{}, null, css);
        try std.testing.expect(resolved.unresolved);
    }
}

test "border atom hash split preserves balanced function and escape boundaries" {
    var tokens: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), borderTokens("var(--edge, rgb(1, 2, 3))1px solid", &tokens).?);
    try std.testing.expectEqualStrings("var(--edge, rgb(1, 2, 3))", tokens[0]);
    try std.testing.expectEqualStrings("1px", tokens[1]);
    try std.testing.expectEqualStrings("solid", tokens[2]);
    for ([_][]const u8{ "1px solid rgb(1,2,3", "1px solid rgb(1,2,3))", "1px solid#ff\\0000", "1px solid 'unterminated" }) |value|
        try std.testing.expect(borderTokens(value, &tokens) == null);
}
