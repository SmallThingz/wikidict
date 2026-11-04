const std = @import("std");
const types = @import("blob_encoder").presentation_types;

pub const Scope = u64;
pub const TableResolution = struct { style: ?types.TableStyle, scope: Scope, unresolved: bool, margin_basis_unresolved: bool = false, background_specified: bool = false, descendant_style_unresolved: bool = false };
pub const CellResolution = struct { style: ?types.CellStyle, background: ?[]const u8, background_specified: bool, unresolved: bool, padding_basis_unresolved: bool = false };
const max_css_bytes = 1024 * 1024;
const max_rules = 4096;
const Target = enum { table, cell, th, td };
const Property = enum { background, border, collapse, margins, padding, text_align, other };
const Value = union(enum) {
    color: []const u8,
    border: types.StyleBorder,
    collapse: types.BorderCollapse,
    edges: types.StyleEdges,
    align_value: types.CellTextAlign,
    unsupported,
};
const Declaration = struct { property: Property, value: Value, important: bool, order: u32, affects_font_basis: bool = false };
const Selector = struct { target: Target, mask: Scope, specificity: u32, unsupported: bool };
const Rule = struct { selector: Selector, declarations: []const Declaration, number: u32 };
const Priority = struct {
    important: bool = false,
    specificity: u32 = 0,
    order: u32 = 0,
    fn wins(self: Priority, prior: Priority) bool {
        if (self.important != prior.important) return self.important;
        if (self.specificity != prior.specificity) return self.specificity > prior.specificity;
        return self.order >= prior.order;
    }
};
const Winner = struct { value: Value, priority: Priority };
const Winners = struct {
    slots: [7]?Winner = @splat(null),
    selector_unresolved: bool = false,
    font_basis_unresolved: bool = false,
    fn add(self: *Winners, declaration: Declaration, specificity: u32, conditional: bool) void {
        if (declaration.affects_font_basis) self.font_basis_unresolved = true;
        const index = @backingInt(declaration.property);
        const next: Priority = .{ .important = declaration.important, .specificity = specificity, .order = declaration.order };
        if (self.slots[index]) |prior| if (!next.wins(prior.priority)) return;
        self.slots[index] = .{ .value = if (conditional) .unsupported else declaration.value, .priority = next };
    }
    fn value(self: Winners, property: Property) ?Value {
        return if (self.slots[@backingInt(property)]) |winner| winner.value else null;
    }
    fn unresolved(self: Winners) bool {
        if (self.selector_unresolved) return true;
        for (self.slots) |slot| if (slot) |winner| if (winner.value == .unsupported) return true;
        return false;
    }
};

/// Producer-only static table styles. No selector or declaration text enters a reader.
pub const Profile = struct {
    arena: std.heap.ArenaAllocator,
    rules: []const Rule,
    classes: []const []const u8,
    admitted_rule_numbers: []const u32,
    has_unsupported_rules: bool,
    globally_unresolved: bool = false,

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

    fn hasUnindexedClass(self: *const Profile, names: []const u8) bool {
        var tokens = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
        while (tokens.next()) |token| {
            var found = false;
            for (self.classes) |name| if (std.mem.eql(u8, token, name)) {
                found = true;
                break;
            };
            if (!found) return true;
        }
        return false;
    }

    fn cascade(self: *const Profile, a: std.mem.Allocator, target: Target, scope: Scope, legacy_bg: ?[]const u8, inline_css: []const u8) !Winners {
        var winners: Winners = .{};
        if (legacy_bg) |raw| if (try canonicalColorAlloc(a, raw)) |color| {
            winners.add(.{ .property = .background, .value = .{ .color = color }, .important = false, .order = 0 }, 0, false);
        };
        for (self.rules) |rule| {
            const selector = rule.selector;
            if (selector.target != target and !(selector.target == .cell and (target == .th or target == .td))) continue;
            if (selector.mask != 0 and selector.mask & scope == 0) continue;
            if (selector.unsupported) winners.selector_unresolved = true;
            for (rule.declarations) |declaration| winners.add(declaration, selector.specificity, selector.unsupported or !representedProperty(target, declaration.property));
        }
        var order: u32 = max_rules * 1024;
        var pos: usize = 0;
        while (try nextDeclarationAlloc(a, inline_css, &pos)) |raw| {
            defer a.free(raw);
            order += 1;
            if (try declarationAlloc(a, raw, order)) |declaration| winners.add(declaration, 1000, !representedProperty(target, declaration.property));
        }
        return winners;
    }

    pub fn resolveTable(self: *const Profile, a: std.mem.Allocator, inherited_scope: Scope, classes: []const u8, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!TableResolution {
        if (self.globally_unresolved or inline_css.len > max_css_bytes) return .{ .style = null, .scope = inherited_scope | self.classScope(classes), .unresolved = true, .background_specified = true, .margin_basis_unresolved = true, .descendant_style_unresolved = true };
        const own_scope = self.classScope(classes);
        if (self.hasUnindexedClass(classes)) return .{ .style = null, .scope = inherited_scope | own_scope, .unresolved = true, .background_specified = true, .margin_basis_unresolved = true, .descendant_style_unresolved = true };
        const winners = try self.cascade(a, .table, own_scope, legacy_bg, inline_css);
        var style: types.TableStyle = .{};
        if (winners.value(.background)) |value| if (value == .color) {
            style.background = value.color;
        };
        if (winners.value(.border)) |value| if (value == .border) {
            style.border = value.border;
        };
        if (winners.value(.collapse)) |value| if (value == .collapse) {
            style.collapse = value.collapse;
        };
        if (winners.value(.margins)) |value| if (value == .edges) {
            style.margins = value.edges;
        };
        return .{ .style = if (types.validTableStyle(style)) style else null, .scope = inherited_scope | own_scope, .unresolved = winners.unresolved(), .margin_basis_unresolved = winners.font_basis_unresolved or self.inheritedFontBasisUnresolved(inherited_scope), .background_specified = winners.value(.background) != null };
    }

    fn inheritedFontBasisUnresolved(self: *const Profile, scope: Scope) bool {
        for (self.rules) |rule| {
            if (rule.selector.target != .table or (rule.selector.mask != 0 and rule.selector.mask & scope == 0)) continue;
            for (rule.declarations) |declaration| if (declaration.affects_font_basis) return true;
        }
        return false;
    }

    pub fn resolveCell(self: *const Profile, a: std.mem.Allocator, scope: Scope, header: bool, legacy_bg: ?[]const u8, inline_css: []const u8) std.mem.Allocator.Error!CellResolution {
        if (self.globally_unresolved or inline_css.len > max_css_bytes) return .{ .style = null, .background = null, .background_specified = true, .unresolved = true, .padding_basis_unresolved = true };
        const winners = try self.cascade(a, if (header) .th else .td, scope, legacy_bg, inline_css);
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
        return .{ .style = if (types.validCellStyle(style)) style else null, .background = if (background) |value| (if (value == .color) value.color else null) else null, .background_specified = background != null, .unresolved = winners.unresolved(), .padding_basis_unresolved = winners.font_basis_unresolved or self.inheritedFontBasisUnresolved(scope) };
    }
};

const Builder = struct {
    a: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,
    classes: std.ArrayList([]const u8) = .empty,
    numbers: std.ArrayList(u32) = .empty,
    number: u32 = 0,
    declaration_order: u32 = 0,
    unsupported: bool = false,
    globally_unresolved: bool = false,

    fn classBit(self: *Builder, name: []const u8) !Scope {
        for (self.classes.items, 0..) |prior, i| if (std.mem.eql(u8, prior, name)) return @as(Scope, 1) << @intCast(i);
        if (self.classes.items.len == 64) return error.StyleProfileLimit;
        try self.classes.append(self.a, try self.a.dupe(u8, name));
        return @as(Scope, 1) << @intCast(self.classes.items.len - 1);
    }

    fn selector(self: *Builder, raw: []const u8, conditional: bool) !?Selector {
        const text = trim(raw);
        if (text.len == 0) return null;
        // Only table.class and its whitespace-separated th/td descendants are admitted.
        if (std.mem.startsWith(u8, text, "table.")) {
            const end = identifierEnd(text, 6);
            if (end == 6) return .{ .target = .table, .mask = 0, .specificity = 11, .unsupported = true };
            const bit = try self.classBit(text[6..end]);
            const suffix = trim(text[end..]);
            if (suffix.len == 0) return .{ .target = .table, .mask = bit, .specificity = 11, .unsupported = conditional };
            const spaced = std.ascii.isWhitespace(text[end]);
            if (spaced and std.mem.eql(u8, suffix, "th")) return .{ .target = .th, .mask = bit, .specificity = 12, .unsupported = conditional };
            if (spaced and std.mem.eql(u8, suffix, "td")) return .{ .target = .td, .mask = bit, .specificity = 12, .unsupported = conditional };
            if (spaced and std.mem.eql(u8, suffix, "caption")) {
                self.unsupported = true;
                return null;
            }
        }
        // Preserve partial status for potentially matching table/cell selectors.
        // An unknown suffix is never reduced to an unconditional old winner.
        var target: ?Target = null;
        var mask: Scope = 0;
        var cursor: usize = 0;
        while (cursor < text.len) {
            if (text[cursor] == '.') {
                const end = identifierEnd(text, cursor + 1);
                for (self.classes.items, 0..) |name, i| if (std.mem.eql(u8, text[cursor + 1 .. end], name)) {
                    mask |= @as(Scope, 1) << @intCast(i);
                };
                cursor = @max(end, cursor + 1);
                continue;
            }
            if (std.ascii.isAlphabetic(text[cursor])) {
                const end = identifierEnd(text, cursor);
                const word = text[cursor..end];
                if (std.mem.eql(u8, word, "table")) target = .table;
                if (std.mem.eql(u8, word, "th")) target = .th;
                if (std.mem.eql(u8, word, "td")) target = .td;
                if (std.mem.eql(u8, word, "caption")) {
                    self.unsupported = true;
                    return null;
                }
                cursor = end;
            } else cursor += 1;
        }
        if (target == null and mask != 0) target = .table;
        if (target == null) return null;
        return .{ .target = target.?, .mask = mask, .specificity = 100, .unsupported = true };
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
                self.unsupported = true;
                self.globally_unresolved = true;
                continue;
            }
            if (boundary != '{') return error.InvalidStyleProfile;
            const body_start = pos;
            const end = try closingBrace(css, &pos);
            if (prelude.len != 0 and prelude[0] == '@') {
                self.unsupported = true;
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
            while (try nextDeclarationAlloc(self.a, css[body_start..end], &declaration_pos)) |raw| {
                self.declaration_order += 1;
                if (self.declaration_order >= max_rules * 1024) return error.StyleProfileLimit;
                if (try declarationAlloc(self.a, raw, self.declaration_order)) |declaration| try declarations.append(self.a, declaration);
            }
            var selectors = std.mem.splitScalar(u8, prelude, ',');
            var admitted = false;
            while (selectors.next()) |raw| {
                if (try self.selector(raw, conditional)) |selector_value| {
                    if (self.rules.items.len == max_rules) return error.StyleProfileLimit;
                    if (selector_value.unsupported) self.unsupported = true;
                    for (declarations.items) |declaration| if (declaration.value == .unsupported) {
                        self.unsupported = true;
                    };
                    try self.rules.append(self.a, .{ .selector = selector_value, .declarations = declarations.items, .number = self.number });
                    admitted = true;
                }
            }
            if (admitted) try self.numbers.append(self.a, self.number);
        }
    }
};

pub fn parseAlloc(a: std.mem.Allocator, css: []const u8) !Profile {
    if (css.len > max_css_bytes) return error.StyleProfileLimit;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var builder: Builder = .{ .a = arena.allocator() };
    try builder.parse(css, false, 0, true);
    try builder.parse(css, false, 0, false);
    return .{ .arena = arena, .rules = builder.rules.items, .classes = builder.classes.items, .admitted_rule_numbers = builder.numbers.items, .has_unsupported_rules = builder.unsupported, .globally_unresolved = builder.globally_unresolved };
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

fn representedProperty(target: Target, property: Property) bool {
    return switch (property) {
        .background, .border, .other => true,
        .collapse, .margins => target == .table,
        .padding, .text_align => target != .table,
    };
}

fn propertyFor(name: []const u8) ?Property {
    if (std.ascii.eqlIgnoreCase(name, "background") or std.ascii.eqlIgnoreCase(name, "background-color") or std.ascii.eqlIgnoreCase(name, "background-image")) return .background;
    if (std.ascii.eqlIgnoreCase(name, "border-collapse")) return .collapse;
    if (std.ascii.eqlIgnoreCase(name, "border") or std.ascii.startsWithIgnoreCase(name, "border-")) return .border;
    if (std.ascii.eqlIgnoreCase(name, "margin") or std.ascii.startsWithIgnoreCase(name, "margin-")) return .margins;
    if (std.ascii.eqlIgnoreCase(name, "padding") or std.ascii.startsWithIgnoreCase(name, "padding-")) return .padding;
    if (std.ascii.eqlIgnoreCase(name, "text-align")) return .text_align;
    // These affect table/cell presentation but have no projection in this ABI.
    inline for (.{ "width", "height", "min-width", "max-width", "min-height", "max-height", "display", "visibility", "float", "position", "color", "font", "font-size", "font-family", "font-weight", "vertical-align", "table-layout", "border-spacing", "opacity", "transform", "all" }) |relevant| if (std.ascii.eqlIgnoreCase(name, relevant)) return .other;
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
    if (dynamicValue(value)) return true;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var count: usize = 0;
    while (tokens.next()) |token| {
        count += 1;
        if (count > 4) return false;
        var recognized = false;
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
        .text_align => {
            if (std.ascii.eqlIgnoreCase(value, "left")) {
                projection = .{ .align_value = .left };
            } else if (std.ascii.eqlIgnoreCase(value, "center")) {
                projection = .{ .align_value = .center };
            } else if (std.ascii.eqlIgnoreCase(value, "right")) {
                projection = .{ .align_value = .right };
            } else if (std.ascii.eqlIgnoreCase(value, "justify") or std.ascii.eqlIgnoreCase(value, "start") or std.ascii.eqlIgnoreCase(value, "end") or dynamicValue(value)) {} else return null;
        },
        .other => {},
    }
    return .{ .property = property, .value = projection, .important = important, .order = order, .affects_font_basis = std.ascii.eqlIgnoreCase(name, "font") or std.ascii.eqlIgnoreCase(name, "font-size") or std.ascii.eqlIgnoreCase(name, "all") };
}

pub fn canonicalColorAlloc(a: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const value = trim(raw);
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
    const th = try profile.resolveCell(a, table.scope, true, null, "");
    const td = try profile.resolveCell(a, table.scope, false, null, "");
    try std.testing.expect(!th.unresolved and !td.unresolved);
    try std.testing.expectEqualStrings("#f2f2f2", th.background.?);
    try std.testing.expect(td.background == null and !td.background_specified);
    try std.testing.expectEqual(types.CellTextAlign.center, th.style.?.text_align.?);
    try std.testing.expect(td.style.?.text_align == null);
    try std.testing.expectEqual(@as(f32, 0.2), th.style.?.padding.?.left.value);
    try std.testing.expectEqual(types.StyleLengthUnit.em, th.style.?.padding.?.left.unit);
    try std.testing.expect(!th.padding_basis_unresolved);
    const classes_case = try profile.resolveTable(a, 0, "Wikitable", null, "");
    try std.testing.expect(classes_case.style == null and classes_case.scope == 0 and classes_case.unresolved);
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
    try std.testing.expect(unknown_class.unresolved and unknown_class.style == null and unknown_class.background_specified and unknown_class.margin_basis_unresolved and unknown_class.descendant_style_unresolved);
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
        "@charset \"UTF-8\";",
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
