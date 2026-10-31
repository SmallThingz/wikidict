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

/// Conservative subset of ordinary transclusion: empty controls, fully excluded
/// documentation, one hidden category wrapper, and one literal physical banner.
/// No onlyinclude, additional HTML, parameters or emitted prose are projected.
pub fn parse(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
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
