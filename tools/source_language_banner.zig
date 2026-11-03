//! Source-bound static language banners. This module creates no registry alias.
const std = @import("std");
const encoder = @import("encoder");
const namespaces = @import("namespace_registry");
const languages = @import("language_registry.zig");
const syntax = encoder.wikitext_syntax;
const Behavior = namespaces.behavior_switches.Registry;

fn controlAt(behavior: ?*const Behavior, source: []const u8, at: usize) std.mem.Allocator.Error!?usize {
    return if (behavior) |registry| registry.matchAt(std.heap.page_allocator, source, at) else syntax.behaviorSwitchEnd(source, at);
}
fn containsControl(behavior: ?*const Behavior, source: []const u8) bool {
    for (0..source.len) |at| if ((controlAt(behavior, source, at) catch return true) != null) return true;
    return false;
}
fn plain(source: []const u8) bool {
    if (source.len == 0 or std.mem.indexOfAny(u8, source, "[]{}<>&|=\"'") != null) return false;
    for (source) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn hiddenCategory(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior) bool {
    const input = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, input, "[[") or !std.mem.endsWith(u8, input, "]]")) return false;
    if (std.mem.indexOfAny(u8, input[2 .. input.len - 2], "[]{}<>&") != null or containsControl(behavior, input)) return false;
    for (input) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var iterator: encoder.document_ir.InlineIterator = .{ .input = input, .renderer_boundaries = true };
    const link = iterator.next() orelse return false;
    if (link.kind != .link or link.trail.len != 0 or iterator.cursor != input.len or iterator.next() != null) return false;
    const target = std.mem.trim(u8, link.target, " ");
    if (target.len == 0 or target[0] == ':') return false;
    const category = ns.ofTitle(target);
    return category.id == 14 and std.mem.trim(u8, category.text, " ").len != 0;
}

/// Conservative static source proofs. The known-name branch retains its
/// original grammar; the literal-code branch admits one finite neutral wrapper
/// shape only. Neither branch projects dynamic parameters or emitted prose.
pub fn parse(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    return parseKnownNames(source, ns, behavior, registry, code) orelse
        parseFlaggedName(source, ns, behavior, registry, code) orelse
        parseLiteralCode(source, ns, behavior, registry, code);
}

// A source-authenticated literal banner may prefix its known language name
// with one neutral file icon. The icon itself contributes no language evidence.
fn parseFlaggedName(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code)) return null;
    // Blank lines may precede a banner, but indentation cannot create an H2.
    const input = std.mem.trimStart(u8, source, "\r\n");
    if (input.len == 0 or input[0] != '=') return null;
    const end = std.mem.indexOfScalar(u8, input, '\n') orelse return null;
    const heading = syntax.controlHeading(std.mem.trimEnd(u8, input[0..end], " \t\r"), null) orelse return null;
    if (heading.level != 2 or containsControl(behavior, heading.title) or
        !std.mem.startsWith(u8, heading.title, "[[")) return null;
    const close = std.mem.indexOf(u8, heading.title, "]]") orelse return null;
    const image = heading.title[2..close];
    const pipe = std.mem.indexOfScalar(u8, image, '|') orelse return null;
    const target = image[0..pipe];
    if (std.mem.indexOfAny(u8, target, "[]{}<>&#\r\n") != null) return null;
    const file = ns.ofTitle(target);
    if (file.id != 6 or std.mem.trim(u8, file.text, " \t").len == 0) return null;
    const option = image[pipe + 1 ..];
    if (!std.mem.endsWith(u8, option, "px") or option.len < 3) return null;
    const digits = option[0 .. option.len - 2];
    for (digits) |digit| if (digit < '0' or digit > '9') return null;
    const width = std.fmt.parseInt(u16, digits, 10) catch return null;
    if (width == 0 or width > 4096) return null;
    const suffix = heading.title[close + 2 ..];
    if (suffix.len == 0 or suffix[0] != ' ') return null;
    const label = std.mem.trim(u8, suffix, " ");
    if (!plain(label) or !registry.sourceBannerNameMatches(code, label)) return null;
    // This observed declaration emits only its heading and a hidden category;
    // parameters, projection tags, controls and extra prose cannot supply proof.
    const tail = std.mem.trim(u8, input[end + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, tail, "<includeonly>") or
        !std.mem.endsWith(u8, tail, "</includeonly>")) return null;
    const category = tail["<includeonly>".len .. tail.len - "</includeonly>".len];
    if (!hiddenCategory(category, ns, behavior)) return null;
    return .{ .heading = heading.title, .level = heading.level, .target = label, .label = label };
}

fn parseKnownNames(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code)) return null;
    // Ordinary transclusion selects onlyinclude globally before control removal.
    // This proof admits no such projection, including inside captured aliases.
    if (std.mem.indexOf(u8, source, "<onlyinclude>") != null or
        std.mem.indexOf(u8, source, "</onlyinclude>") != null) return null;
    var cursor: usize = 0;
    var result: ?languages.SourceLanguageBanner = null;
    var emitted_category = false;
    while (cursor < source.len) {
        if (std.ascii.isWhitespace(source[cursor])) { cursor += 1; continue; }
        if (controlAt(behavior, source, cursor) catch return null) |end| {
            // A recognized control is empty only after earlier source parsing.
            // Do not swallow template, link or markup syntax as proof trivia.
            if (std.mem.indexOfAny(u8, source[cursor..end], "[]{}<>&|=\"'") != null) return null;
            const toc = if (behavior) |captured| captured.tocMatchAt(std.heap.page_allocator, source, cursor) catch return null else if (std.ascii.eqlIgnoreCase(source[cursor..end], "__TOC__")) end else null;
            if (toc != null) return null;
            cursor = end;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<noinclude>")) {
            const begin = cursor + "<noinclude>".len;
            const close = std.mem.indexOfPos(u8, source, begin, "</noinclude>") orelse return null;
            if (std.mem.indexOfScalar(u8, source[begin..close], '<') != null) return null;
            cursor = close + "</noinclude>".len;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<includeonly>")) {
            if (result != null or emitted_category) return null;
            const begin = cursor + "<includeonly>".len;
            const close = std.mem.indexOfPos(u8, source, begin, "</includeonly>") orelse return null;
            if (!hiddenCategory(source[begin..close], ns, behavior)) return null;
            emitted_category = true;
            cursor = close + "</includeonly>".len;
            continue;
        }
        // The heading must occupy a real source line. Removed documentation or
        // controls cannot turn an inline equals string into a new line boundary.
        if (result != null or source[cursor] != '=' or
            (cursor != 0 and source[cursor - 1] != '\n')) return null;
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        const line = std.mem.trimEnd(u8, source[cursor..end], " \t\r");
        const heading = syntax.controlHeading(line, null) orelse return null;
        if (heading.level < 1 or heading.level > 2 or containsControl(behavior, heading.title)) return null;
        const label = heading.title;
        if (!std.mem.startsWith(u8, label, "[[")) return null;
        const close = std.mem.indexOf(u8, label, "]]") orelse return null;
        const body = label[2..close];
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse return null;
        const target = std.mem.trim(u8, body[0..pipe], " ");
        const visible = std.mem.trim(u8, body[pipe + 1 ..], " ");
        if (!plain(target) or !plain(visible) or std.mem.indexOfAny(u8, target, ":#") != null or
            !registry.sourceBannerNameMatches(code, target) or !registry.sourceBannerNameMatches(code, visible)) return null;
        const tail = std.mem.trim(u8, label[close + 2 ..], " ");
        if (tail.len != 0) {
            if (tail.len < 3 or tail[0] != '(' or tail[tail.len - 1] != ')') return null;
            const explanation = tail[1 .. tail.len - 1];
            if (!plain(explanation) or std.mem.indexOfAny(u8, explanation, "()") != null) return null;
        }
        result = .{ .heading = label, .level = heading.level, .target = target, .label = visible };
        cursor = end;
    }
    return result;
}

// A separate finite proof for retained static banners containing an explicit
// registered literal code. Ordinary registry names and the known-name grammar
// above stay unchanged. No rendered-text stripping supplies this authority.
fn unwrapNeutral(input: []const u8, name: []const u8) ?[]const u8 {
    const tag = syntax.tagAt(input, 0) orelse return null;
    if (!tag.is(name) or tag.closing or tag.self_closing or
        std.mem.trim(u8, tag.attrs, " \t\r\n").len != 0) return null;
    const pair = syntax.matchingTag(input, tag) orelse return null;
    if (pair.end != input.len) return null;
    return std.mem.trim(u8, input[tag.end..pair.inner_end], " \t");
}

fn literalCodeHeading(heading: []const u8, level: u8, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (containsControl(behavior, heading)) return null;
    const div = syntax.tagAt(heading, 0) orelse return null;
    // The source-observed neutral presentation attributes are exact. In
    // particular no arbitrary class, hidden/style attribute or nested div.
    if (!div.is("div") or div.closing or div.self_closing or
        !std.mem.eql(u8, std.mem.trim(u8, div.attrs, " \t"), "id=\"toc\" class=\"toccolours\"")) return null;
    const pair = syntax.matchingTag(heading, div) orelse return null;
    if (pair.end != heading.len) return null;
    const inner = std.mem.trim(u8, heading[div.end..pair.inner_end], " \t");
    const body = unwrapNeutral(inner, "big") orelse return null;
    if (!std.mem.startsWith(u8, body, "[[")) return null;
    const link = syntax.balanced(body, 0) orelse return null;
    const label_body = body[2..link.inner_end];
    const pipe = std.mem.indexOfScalar(u8, label_body, '|');
    const target = std.mem.trim(u8, label_body[0..pipe orelse label_body.len], " ");
    const visible = std.mem.trim(u8, if (pipe) |at| label_body[at + 1 ..] else label_body, " ");
    if (!plain(target) or !plain(visible) or std.mem.indexOfAny(u8, target, ":#") != null or
        !registry.sourceBannerLiteralCodeNameCompatible(code, target) or
        !registry.sourceBannerLiteralCodeNameCompatible(code, visible)) return null;
    var tail = std.mem.trim(u8, body[link.end..], " \t");
    // Only the source-observed one/two nested small presentation wrappers.
    tail = unwrapNeutral(tail, "small") orelse return null;
    if (std.mem.startsWith(u8, tail, "<")) tail = unwrapNeutral(tail, "small") orelse return null;
    if (tail.len != code.len + 2 or tail[0] != '(' or tail[tail.len - 1] != ')' or
        !std.mem.eql(u8, tail[1 .. tail.len - 1], code)) return null;
    return .{ .heading = heading, .level = level, .target = target, .label = visible, .authority = .literal_code };
}

fn excludedDocumentationEnd(source: []const u8, start: usize) ?usize {
    const begin = start + "<noinclude>".len;
    const close = std.mem.indexOfPos(u8, source, begin, "</noinclude>") orelse return null;
    // Normal transclusion ends at the first closing inclusion tag, without
    // nesting (wikitext/preprocess.zig). Admit plain excluded documentation
    // plus complete comments only; reject other tag/closing interpretations.
    var cursor = begin;
    while (std.mem.indexOfScalarPos(u8, source[0..close], cursor, '<')) |at| {
        if (!std.mem.startsWith(u8, source[at..], "<!--")) return null;
        const end = syntax.protectedEnd(source, at) orelse return null;
        if (end > close or end < at + 7 or !std.mem.endsWith(u8, source[at..end], "-->")) return null;
        if (std.mem.indexOfAny(u8, source[at + 4 .. end - 3], "<>") != null) return null;
        cursor = end;
    }
    return close + "</noinclude>".len;
}

fn parseLiteralCode(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code) or
        std.mem.indexOf(u8, source, "<onlyinclude>") != null or
        std.mem.indexOf(u8, source, "</onlyinclude>") != null) return null;
    var cursor: usize = 0;
    var result: ?languages.SourceLanguageBanner = null;
    var category = false;
    var leading_break = false;
    var trailing_break = false;
    var documentation = false;
    while (cursor < source.len) {
        if (std.ascii.isWhitespace(source[cursor])) { cursor += 1; continue; }
        if (documentation) return null;
        if (controlAt(behavior, source, cursor) catch return null) |end| {
            if (std.mem.indexOfAny(u8, source[cursor..end], "[]{}<>&|=\"'") != null) return null;
            const toc = if (behavior) |captured| captured.tocMatchAt(std.heap.page_allocator, source, cursor) catch return null else if (std.ascii.eqlIgnoreCase(source[cursor..end], "__TOC__")) end else null;
            if (toc != null) return null;
            cursor = end;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<includeonly>")) {
            if (result != null or category or leading_break) return null;
            const begin = cursor + "<includeonly>".len;
            const close = std.mem.indexOfPos(u8, source, begin, "</includeonly>") orelse return null;
            if (!hiddenCategory(source[begin..close], ns, behavior)) return null;
            category = true;
            cursor = close + "</includeonly>".len;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<noinclude>")) {
            if (result == null) return null;
            cursor = excludedDocumentationEnd(source, cursor) orelse return null;
            documentation = true;
            continue;
        }
        if (syntax.tagAt(source, cursor)) |tag| if (tag.is("br") and !tag.closing and
            std.mem.trim(u8, tag.attrs, " \t").len == 0) {
            if (result == null) {
                if (leading_break) return null;
                leading_break = true;
            } else {
                if (trailing_break) return null;
                trailing_break = true;
            }
            cursor = tag.end;
            continue;
        };
        if (result != null or source[cursor] != '=' or
            (cursor != 0 and source[cursor - 1] != '\n')) return null;
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        const line = std.mem.trimEnd(u8, source[cursor..end], " \t\r");
        const parsed = syntax.controlHeading(line, null) orelse return null;
        if (parsed.level < 1 or parsed.level > 2) return null;
        result = literalCodeHeading(parsed.title, parsed.level, behavior, registry, code) orelse return null;
        cursor = end;
    }
    return result;
}
