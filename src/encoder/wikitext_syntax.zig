//! Bounded runtime helpers for template arguments and literal/HTML boundaries.
const std = @import("std");
/// Core MediaWiki behavior switches have no visible dictionary text.
/// Match only registered canonical aliases, retaining their case rules. Never
/// call this on nowiki, opaque extension bodies, decoded entities or attributes.
// The canonical aliases are ASCII. These are the only Unicode16 C/S
// non-ASCII mappings to ASCII (CaseFolding.txt, also used by shared aliases).
// Keep this small matcher std-only for the freestanding blob encoder module.
fn canonicalAliasEqual(name: []const u8, alias: []const u8) bool {
    if (name.len < alias.len or name.len > alias.len * 3) return false;
    if (std.ascii.eqlIgnoreCase(name, alias)) return true;
    var it = (std.unicode.Utf8View.init(name) catch return false).iterator();
    for (alias) |byte| {
        const cp = it.nextCodepoint() orelse return false;
        const folded: u21 = if (cp < 128) std.ascii.toLower(@intCast(cp)) else switch (cp) {
            0x017f => 's',
            0x212a => 'k',
            else => cp,
        };
        if (folded != std.ascii.toLower(byte)) return false;
    }
    return it.nextCodepoint() == null;
}

pub fn behaviorSwitchEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or !starts(text[start..], "__")) return null;
    const close = std.mem.indexOfPos(u8, text, start + 2, "__") orelse return null;
    const name = text[start + 2 .. close];
    inline for (&.{ "NOTOC", "FORCETOC", "TOC", "NOEDITSECTION", "NOGALLERY", "NOCONTENTCONVERT", "NOCC", "NOTITLECONVERT", "NOTC" }) |alias| {
        if (canonicalAliasEqual(name, alias)) return close + 2;
    }
    inline for (&.{ "HIDDENCAT", "INDEX", "NOINDEX", "NEWSECTIONLINK", "NONEWSECTIONLINK", "STATICREDIRECT", "EXPECTUNUSEDCATEGORY", "EXPECTUNUSEDTEMPLATE", "EXPECTSHORTPAGE" }) |alias| {
        if (std.mem.eql(u8, name, alias)) return close + 2;
    }
    return null;
}

pub const ControlMatcher = struct {
    ctx: ?*const anyopaque,
    match: *const fn (?*const anyopaque, []const u8, usize) ?usize,
    toc_match: ?*const fn (?*const anyopaque, []const u8, usize) ?usize = null,

    pub fn end(self: ControlMatcher, text: []const u8, at: usize) ?usize {
        return self.match(self.ctx, text, at);
    }

    pub fn emptyEnd(self: ControlMatcher, text: []const u8, at: usize) ?usize {
        const matched = self.end(text, at) orelse return null;
        const toc = if (self.toc_match) |match_toc|
            match_toc(self.ctx, text, at)
        else if (std.ascii.eqlIgnoreCase(text[at..matched], "__TOC__")) matched else null;
        return if (toc != null and toc.? == matched) null else matched;
    }
};

/// Only empty active controls can join a later-phase structural delimiter.
/// A retained first TOC is a real boundary; page preprocessing removes later TOCs.
pub fn emptyBehaviorControlEnd(text: []const u8, at: usize, matcher: ?ControlMatcher) ?usize {
    if (matcher) |value| return value.emptyEnd(text, at);
    const matched = behaviorSwitchEnd(text, at) orelse return null;
    return if (std.ascii.eqlIgnoreCase(text[at..matched], "__TOC__")) null else matched;
}

/// Leading active controls and a complete suffix after a heading delimiter are invisible.
/// Scan original bytes, retaining protected bodies, attributes and entities.
/// Skip only active controls at the physical start of a heading/list line.
/// This is not table preprocessing: controls before {| leave it literal.
pub fn leadingBehaviorControlOffset(raw: []const u8, matcher: ?ControlMatcher) usize {
    var at: usize = 0;
    while (at < raw.len) {
        const end = emptyBehaviorControlEnd(raw, at, matcher);
        const next = end orelse break;
        if (next <= at or next > raw.len) break;
        at = next;
    }
    return at;
}

pub fn headingControlPrefix(raw: []const u8, matcher: ?ControlMatcher) []const u8 {
    var no_more_nowiki_close = false;
    var opaque_scan: OpaqueScan = .{};
    const line = std.mem.trimEnd(u8, raw[leadingBehaviorControlOffset(raw, matcher)..], " \t");
    if (line.len == 0 or line[0] != '=') return line;
    var at: usize = 0;
    while (at < line.len) {
        if (opaque_scan.protectedEnd(line, at, &no_more_nowiki_close)) |end| {
            at = end;
            continue;
        }
        if (line[at] == '<') if (opaque_scan.tagAt(line, at, &no_more_nowiki_close)) |tag| {
            at = tag.end;
            continue;
        };
        if (starts(line[at..], "{{") or starts(line[at..], "[[")) {
            if (balancedWithOpaqueScan(line, at, &opaque_scan)) |pair| {
                at = pair.end;
                continue;
            }
            return line;
        }
        const end = emptyBehaviorControlEnd(line, at, matcher);
        if (end) |first_end| {
            const prefix = std.mem.trimEnd(u8, line[0..at], " \t");
            if (prefix.len != 0 and prefix[prefix.len - 1] == '=') {
                var cursor = first_end;
                while (cursor < line.len) {
                    if (line[cursor] == ' ' or line[cursor] == '\t') {
                        cursor += 1;
                        continue;
                    }
                    const next = emptyBehaviorControlEnd(line, cursor, matcher);
                    cursor = next orelse break;
                }
                if (cursor == line.len) return prefix;
            }
            at = first_end;
        } else at += 1;
    }
    return line;
}

pub const ControlHeading = struct { level: u8, title: []const u8 };

const EqualsRun = struct {
    count: usize = 0,
    end: usize,
    first_ends: [6]usize = undefined,
    last_starts: [6]usize = undefined,
};

fn controlEqualsRun(line: []const u8, start: usize, matcher: ?ControlMatcher) EqualsRun {
    var result: EqualsRun = .{ .end = start };
    while (result.end < line.len and line[result.end] == '=') {
        const at = result.end;
        result.last_starts[result.count % 6] = at;
        if (result.count < 6) result.first_ends[result.count] = at + 1;
        result.count += 1;
        result.end += 1;
        var next = result.end;
        while (emptyBehaviorControlEnd(line, next, matcher)) |end| {
            if (end <= next or end > line.len) break;
            next = end;
        }
        // Keep controls in the title/body unless they really join another '='.
        if (next < line.len and line[next] == '=') result.end = next;
    }
    return result;
}

/// A borrowed raw title slice; only delimiter positions are projected.
/// Protected markup, whitespace and the first TOC cannot join delimiter bytes.
pub fn controlHeading(raw: []const u8, matcher: ?ControlMatcher) ?ControlHeading {
    const line = headingControlPrefix(raw, matcher);
    if (line.len < 3 or line[0] != '=') return null;
    const opening = controlEqualsRun(line, 0, matcher);
    if (opening.end == line.len) {
        // Preserve the existing capped-six delimiter contract for a line made
        // entirely of equals: only unmatched equals can form its title.
        if (opening.count <= 12) return null;
        return .{ .level = 6, .title = line[opening.first_ends[5]..opening.last_starts[(opening.count - 6) % 6]] };
    }
    var closing: ?EqualsRun = null;
    var at = opening.end;
    var no_more_nowiki_close = false;
    var opaque_scan: OpaqueScan = .{};
    while (at < line.len) {
        if (opaque_scan.protectedEnd(line, at, &no_more_nowiki_close)) |end| {
            at = end;
            continue;
        }
        if (line[at] == '<') if (opaque_scan.tagAt(line, at, &no_more_nowiki_close)) |tag| {
            at = tag.end;
            continue;
        };
        if (line[at] == '=') {
            const run = controlEqualsRun(line, at, matcher);
            if (run.end == line.len) {
                closing = run;
                break;
            }
            at = run.end;
        } else at += 1;
    }
    const suffix = closing orelse return null;
    const level = @min(6, @min(opening.count, suffix.count));
    const start = opening.first_ends[level - 1];
    const end = suffix.last_starts[(suffix.count - level) % 6];
    if (start > end) return null;
    const title = std.mem.trim(u8, line[start..end], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(level), .title = title };
}

pub const ControlListPrefix = struct { path: []const u8, body_start: usize };

/// Return the existing raw path when unchanged; changed paths belong to allocator.
pub fn controlListPrefixAlloc(a: std.mem.Allocator, line: []const u8, matcher: ?ControlMatcher) std.mem.Allocator.Error!ControlListPrefix {
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(a);
    var changed = false;
    var at: usize = 0;
    while (at < line.len and std.mem.indexOfScalar(u8, "#*:;", line[at]) != null) {
        if (changed) try path.append(a, line[at]);
        at += 1;
        var next = at;
        while (emptyBehaviorControlEnd(line, next, matcher)) |end| {
            if (end <= next or end > line.len) break;
            next = end;
        }
        if (next != at and next < line.len and std.mem.indexOfScalar(u8, "#*:;", line[next]) != null) {
            if (!changed) {
                try path.appendSlice(a, line[0..at]);
                changed = true;
            }
            at = next;
        }
    }
    return .{ .path = if (changed) try path.toOwnedSlice(a) else line[0..at], .body_start = at };
}

pub const Pair = struct { inner_end: usize, end: usize };
pub fn starts(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}
pub fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}
pub fn isMultilineContainerTag(name: []const u8) bool {
    inline for (&.{ "ref", "table", "div", "blockquote", "p", "ul", "ol", "dl", "center" }) |tag| {
        if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    }
    return false;
}
const opaque_tag_names = [_][]const u8{
    "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
    "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
    "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
    "section", "inputbox", "imagemap",     "dynamicpagelist",
};
pub fn isOpaqueTag(name: []const u8) bool {
    for (opaque_tag_names) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}
// One cache belongs to one input. A missing closer is final only for that
// tag family at or after the observed raw offset, including after lookahead.
pub const OpaqueScan = struct {
    missing: u32 = 0,
    missing_from: [opaque_tag_names.len]usize = @splat(std.math.maxInt(usize)),
    last_angle_known: bool = false,
    last_angle_end: usize = 0,
    pub fn tagAt(self: *OpaqueScan, text: []const u8, start: usize, no_more_nowiki_close: ?*bool) ?Tag {
        if (!self.last_angle_known) {
            self.last_angle_end = if (std.mem.lastIndexOfScalar(u8, text, '>')) |at| at + 1 else 0;
            self.last_angle_known = true;
        }
        if (start >= self.last_angle_end) return null;
        return tagAtWithOpaqueScan(text, start, no_more_nowiki_close, self);
    }
    fn nowikiRegion(self: *OpaqueScan, text: []const u8, start: usize) ?NowikiRegion {
        if (start >= self.last_angle_end) return null;
        const opening = rawNowikiOpeningAt(text, start) orelse return null;
        const found = self.pair(text, opening) orelse return null;
        return .{ .opening_end = opening.end, .inner_end = found.inner_end, .end = found.end, .self_closing = opening.self_closing };
    }
    pub fn pair(self: *OpaqueScan, text: []const u8, tag: Tag) ?Pair {
        if (tag.self_closing) return .{ .inner_end = tag.end, .end = tag.end };
        for (opaque_tag_names, 0..) |name, index| if (tag.is(name)) {
            const mask = @as(u32, 1) << @as(u5, @intCast(index));
            if (self.missing & mask != 0 and tag.end >= self.missing_from[index]) return null;
            const found = opaquePair(text, tag) orelse {
                self.missing |= mask;
                self.missing_from[index] = @min(self.missing_from[index], tag.end);
                return null;
            };
            return found;
        };
        return null;
    }
    pub fn protectedEnd(self: *OpaqueScan, text: []const u8, start: usize, no_more_nowiki_close: ?*bool) ?usize {
        if (start >= text.len) return null;
        if (starts(text[start..], "<!--")) return if (std.mem.indexOfPos(u8, text, start + 4, "-->")) |end| end + 3 else text.len;
        const tag = self.tagAt(text, start, no_more_nowiki_close) orelse return null;
        if (!tag.closing and tag.is("nowiki")) return if (self.pair(text, tag)) |found| found.end else null;
        if (tag.closing or !isOpaqueTag(tag.name)) return null;
        return if (self.pair(text, tag)) |found| found.end else tag.end;
    }
};
pub const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    end: usize,
    closing: bool,
    self_closing: bool,
    pub fn is(self: Tag, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }
    pub fn attr(self: Tag, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.attrs.len) {
            while (i < self.attrs.len and (std.ascii.isWhitespace(self.attrs[i]) or self.attrs[i] == '/')) : (i += 1) {}
            const start = i;
            while (i < self.attrs.len and !std.ascii.isWhitespace(self.attrs[i]) and self.attrs[i] != '=' and self.attrs[i] != '/') : (i += 1) {}
            if (i == start) {
                i += 1;
                continue;
            }
            const name = self.attrs[start..i];
            while (i < self.attrs.len and std.ascii.isWhitespace(self.attrs[i])) : (i += 1) {}
            if (i == self.attrs.len or self.attrs[i] != '=') continue;
            i += 1;
            while (i < self.attrs.len and std.ascii.isWhitespace(self.attrs[i])) : (i += 1) {}
            if (i == self.attrs.len) return null;
            const quote = self.attrs[i];
            const quoted = quote == '\'' or quote == '"';
            if (quoted) i += 1;
            const value_start = i;
            while (i < self.attrs.len and (if (quoted) self.attrs[i] != quote else !std.ascii.isWhitespace(self.attrs[i]))) : (i += 1) {}
            const value = self.attrs[value_start..i];
            if (quoted and i < self.attrs.len) i += 1;
            if (std.ascii.eqlIgnoreCase(name, key)) return value;
        }
        return null;
    }
};
pub const NowikiRegion = struct {
    opening_end: usize,
    inner_end: usize,
    end: usize,
    self_closing: bool,
};
// The source preprocessor recognizes nowiki before ordinary HTML attributes.
// Its opener and first valid closer are raw, nonrecursive source boundaries.
fn rawNowikiOpeningAt(text: []const u8, start: usize) ?Tag {
    if (start >= text.len or text[start] != '<') return null;
    const name_start = start + 1;
    const name_end = name_start + "nowiki".len;
    if (name_end > text.len or !std.ascii.eqlIgnoreCase(text[name_start..name_end], "nowiki")) return null;
    if (name_end < text.len and !std.ascii.isWhitespace(text[name_end]) and text[name_end] != '/' and text[name_end] != '>') return null;
    // The extension-name boundary admits an adjacent slash only as '/>'.
    if (name_end < text.len and text[name_end] == '/' and
        (name_end + 1 >= text.len or text[name_end + 1] != '>')) return null;
    const gt = std.mem.indexOfScalarPos(u8, text, name_end, '>') orelse return null;
    const attrs = std.mem.trimEnd(u8, text[name_end..gt], " \t\r\n");
    const self_closing = gt > name_end and text[gt - 1] == '/';
    return .{ .name = text[name_start..name_end], .attrs = if (self_closing) attrs[0 .. attrs.len - 1] else attrs, .end = gt + 1, .closing = false, .self_closing = self_closing };
}
pub fn nowikiRegionAt(text: []const u8, start: usize) ?NowikiRegion {
    return nowikiRegionAtCached(text, start, null);
}
pub fn nowikiRegionAtCached(text: []const u8, start: usize, no_more_close: ?*bool) ?NowikiRegion {
    const opening = rawNowikiOpeningAt(text, start) orelse return null;
    if (opening.self_closing) return .{ .opening_end = opening.end, .inner_end = opening.end, .end = opening.end, .self_closing = true };
    if (no_more_close) |missing| if (missing.*) return null;
    const pair = opaquePair(text, opening) orelse {
        if (no_more_close) |missing| missing.* = true;
        return null;
    };
    return .{ .opening_end = opening.end, .inner_end = pair.inner_end, .end = pair.end, .self_closing = false };
}

// MediaWiki ends a tag at the first raw greater-than, including in quoted
// attribute text. Attribute value extraction remains the responsibility of Tag.attr.
pub fn tagAt(text: []const u8, start: usize) ?Tag {
    return tagAtCached(text, start, null);
}
// A missing-closer cache belongs to one monotonically forward scan of one input.
pub fn tagAtCached(text: []const u8, start: usize, no_more_nowiki_close: ?*bool) ?Tag {
    return tagAtWithOpaqueScan(text, start, no_more_nowiki_close, null);
}
fn tagAtWithOpaqueScan(text: []const u8, start: usize, no_more_nowiki_close: ?*bool, opaque_scan: ?*OpaqueScan) ?Tag {
    if (start >= text.len or text[start] != '<') return null;
    var i = start + 1;
    const closing = i < text.len and text[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) : (i += 1) {}
    if (i == name_start or !std.ascii.isAlphabetic(text[name_start])) return null;
    const name = text[name_start..i];
    if (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != '/' and text[i] != '>') return null;
    if (!closing and isOpaqueTag(name) and i < text.len and text[i] == '/' and
        (i + 1 >= text.len or text[i + 1] != '>')) return null;
    if (!closing and std.ascii.eqlIgnoreCase(name, "nowiki")) return rawNowikiOpeningAt(text, start);
    const attr_start = i;
    // Attribute lookahead is speculative: on failure the caller resumes
    // before markers already visited here. Never publish a later miss backward.
    var local_missing = if (no_more_nowiki_close) |cache| cache.* else false;
    const missing = &local_missing;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '>') {
            const attrs = std.mem.trimEnd(u8, text[attr_start..i], " \t\r\n");
            const self_closing = if (isOpaqueTag(name)) i > attr_start and text[i - 1] == '/' else std.mem.endsWith(u8, attrs, "/");
            return .{ .name = name, .attrs = if (self_closing) attrs[0 .. attrs.len - 1] else attrs, .end = i + 1, .closing = closing, .self_closing = self_closing };
        }
        if (ch == '<') {
            const region_at = if (opaque_scan) |cache| cache.nowikiRegion(text, i) else nowikiRegionAtCached(text, i, missing);
            if (region_at) |region| {
                i = region.end - 1;
                continue;
            }
            return null;
        }
    }
    return null;
}
fn opaquePair(text: []const u8, tag: Tag) ?Pair {
    if (tag.self_closing) return .{ .inner_end = tag.end, .end = tag.end };
    var i = tag.end;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        // Opaque bodies do not contain HTML attributes: even a closer inside
        // a literal quoted pseudo-tag terminates the region. Match only the
        // closing name plus optional whitespace, as the source preprocessor does.
        const name_end = open + 2 + tag.name.len;
        if (name_end <= text.len and text[open + 1] == '/' and
            std.ascii.eqlIgnoreCase(text[open + 2 .. name_end], tag.name))
        {
            var end = name_end;
            while (end < text.len and std.ascii.isWhitespace(text[end])) : (end += 1) {}
            if (end < text.len and text[end] == '>')
                return .{ .inner_end = open, .end = end + 1 };
        }
        i = open + 1;
    }
    return null;
}
pub fn matchingTag(text: []const u8, tag: Tag) ?Pair {
    var opaque_scan: OpaqueScan = .{};
    return matchingTagWithOpaqueScan(text, tag, &opaque_scan);
}
pub fn matchingTagWithOpaqueScan(text: []const u8, tag: Tag, opaque_scan: *OpaqueScan) ?Pair {
    if (tag.self_closing) return .{ .inner_end = tag.end, .end = tag.end };
    // MediaWiki extension bodies are opaque: an opening tag of the same name
    // inside the body is literal text, not a nested extension.
    if (isOpaqueTag(tag.name)) return opaque_scan.pair(text, tag);
    var i = tag.end;
    var nesting: usize = 1;
    var no_more_nowiki_close = false;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        if (starts(text[open..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, text, open + 4, "-->")) |end| end + 3 else text.len;
            continue;
        }
        if (opaque_scan.tagAt(text, open, &no_more_nowiki_close)) |next| {
            // Closing-looking text inside nowiki/ref/math/etc. cannot close the
            // surrounding ordinary HTML element.
            if (!next.closing and next.is("nowiki")) {
                i = if (opaque_scan.pair(text, next)) |pair| pair.end else next.end;
                continue;
            }
            if (!next.closing and isOpaqueTag(next.name)) {
                i = if (opaque_scan.pair(text, next)) |pair| pair.end else next.end;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(next.name, tag.name)) {
                if (next.closing) nesting -= 1 else if (!next.self_closing) nesting += 1;
                if (nesting == 0) return .{ .inner_end = open, .end = next.end };
            }
            i = next.end;
        } else i = open + 1;
    }
    return null;
}
pub fn protectedEnd(text: []const u8, start: usize) ?usize {
    return protectedEndCached(text, start, null);
}
pub fn protectedEndCached(text: []const u8, start: usize, no_more_nowiki_close: ?*bool) ?usize {
    if (rawNowikiOpeningAt(text, start) != null)
        return if (nowikiRegionAtCached(text, start, no_more_nowiki_close)) |region| region.end else null;
    var opaque_scan: OpaqueScan = .{};
    return opaque_scan.protectedEnd(text, start, no_more_nowiki_close);
}
/// Stack-based matching prevents pipes in links/parameters from becoming template delimiters.
pub fn balanced(text: []const u8, start: usize) ?Pair {
    var opaque_scan: OpaqueScan = .{};
    return balancedWithOpaqueScan(text, start, &opaque_scan);
}
pub fn balancedWithOpaqueScan(text: []const u8, start: usize, opaque_scan: *OpaqueScan) ?Pair {
    var no_more_nowiki_close = false;
    if (start + 2 <= text.len and starts(text[start..], "[[")) {
        var i = start + 2;
        while (i < text.len) {
            const ch = text[i];
            if (ch == ']') {
                if (i + 1 < text.len and text[i + 1] == ']') return .{ .inner_end = i, .end = i + 2 };
                i += 1;
                continue;
            }
            if (ch == '{' or ch == '[' or ch == '<') break;
            i += 1;
        }
        if (i == text.len) return null;
    }
    const Kind = enum { template, parameter, link };
    var stack: [128]Kind = undefined;
    var n: usize = 0;
    var i = start;
    while (i < text.len) {
        if (text[i] == '<') {
            if (opaque_scan.protectedEnd(text, i, &no_more_nowiki_close)) |end| {
                i = end;
                continue;
            }
            // Attribute delimiters are HTML syntax only inside a root link frame.
            // Template and parameter braces retain their existing semantics.
            if (n == 1 and stack[0] == .link) if (opaque_scan.tagAt(text, i, &no_more_nowiki_close)) |tag| {
                i = tag.end;
                continue;
            };
        }
        const rest = text[i..];
        const open: ?struct { kind: Kind, len: usize } = if (starts(rest, "{{{")) .{ .kind = .parameter, .len = 3 } else if (starts(rest, "{{")) .{ .kind = .template, .len = 2 } else if (starts(rest, "[[")) .{ .kind = .link, .len = 2 } else null;
        if (open) |item| {
            if (n == stack.len) return null;
            stack[n] = item.kind;
            n += 1;
            i += item.len;
            continue;
        }
        if (n == 0) return null;
        const close: []const u8 = switch (stack[n - 1]) {
            .template => "}}",
            .parameter => "}}}",
            .link => "]]",
        };
        if (starts(rest, close)) {
            n -= 1;
            if (n == 0) return .{ .inner_end = i, .end = i + close.len };
            i += close.len;
            continue;
        }
        i += 1;
    }
    return null;
}
/// A logical line may span physical newlines inside templates, comments or protected tags.
pub fn logicalEnd(text: []const u8, start: usize) usize {
    return logicalEndCached(text, start, null);
}
pub fn logicalEndCached(text: []const u8, start: usize, no_more_nowiki_close: ?*bool) usize {
    var opaque_scan: OpaqueScan = .{};
    return logicalEndWithOpaqueScan(text, start, no_more_nowiki_close, &opaque_scan);
}
pub fn logicalEndWithOpaqueScan(text: []const u8, start: usize, no_more_nowiki_close: ?*bool, opaque_scan: *OpaqueScan) usize {
    var local_missing = false;
    const missing = no_more_nowiki_close orelse &local_missing;
    var i = start;
    var line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    while (i < text.len) {
        if (i >= line_end) return line_end;
        const relative = std.mem.indexOfAny(u8, text[i..line_end], "<[{") orelse return line_end;
        i += relative;
        var skip_to: ?usize = null;
        if (text[i] == '<') {
            if (opaque_scan.protectedEnd(text, i, missing)) |end| {
                skip_to = end;
            } else if (opaque_scan.tagAt(text, i, missing)) |tag| {
                skip_to = tag.end;
                if (!tag.closing and isMultilineContainerTag(tag.name)) {
                    if (matchingTagWithOpaqueScan(text, tag, opaque_scan)) |pair| skip_to = pair.end;
                }
            }
        } else if ((text[i] == '{' and starts(text[i..], "{{")) or
            (text[i] == '[' and starts(text[i..], "[[")))
        {
            if (balancedWithOpaqueScan(text, i, opaque_scan)) |pair| skip_to = pair.end;
        }
        if (skip_to) |end| {
            i = end;
            if (end > line_end) line_end = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
            continue;
        }
        i += 1;
    }
    return i;
}
fn delimiterByte(text: []const u8, needle: u8, start: usize) ?usize {
    var no_more_nowiki_close = false;
    var opaque_scan: OpaqueScan = .{};
    const interesting = [_]u8{ needle, '<', '{', '[' };
    var i = start;
    while (i < text.len) {
        const relative = std.mem.indexOfAny(u8, text[i..], &interesting) orelse return null;
        i += relative;
        if (text[i] == needle) return i;
        if (text[i] == '<') {
            if (opaque_scan.protectedEnd(text, i, &no_more_nowiki_close)) |end| {
                i = end;
                continue;
            }
            if (opaque_scan.tagAt(text, i, &no_more_nowiki_close)) |tag| {
                i = tag.end;
                continue;
            }
        }
        if (starts(text[i..], "{{") or starts(text[i..], "[[")) {
            if (balancedWithOpaqueScan(text, i, &opaque_scan)) |pair| {
                i = pair.end;
                continue;
            }
            return null;
        }
        i += 1;
    }
    return null;
}
pub fn delimiter(text: []const u8, needle: []const u8, start: usize) ?usize {
    var no_more_nowiki_close = false;
    var opaque_scan: OpaqueScan = .{};
    if (needle.len == 1) return delimiterByte(text, needle[0], start);
    var i = start;
    while (i < text.len) {
        if (starts(text[i..], needle)) return i;
        if (text[i] == '<') {
            if (opaque_scan.protectedEnd(text, i, &no_more_nowiki_close)) |end| {
                i = end;
                continue;
            }
            if (opaque_scan.tagAt(text, i, &no_more_nowiki_close)) |tag| {
                i = tag.end;
                continue;
            }
        }
        if (starts(text[i..], "{{") or starts(text[i..], "[[")) {
            if (balancedWithOpaqueScan(text, i, &opaque_scan)) |pair| {
                i = pair.end;
                continue;
            }
            // An unbalanced nested construct makes following separators
            // ambiguous. Preserve the remainder instead of repeatedly probing
            // every overlapping opener.
            return null;
        }
        i += 1;
    }
    return null;
}
pub const Param = struct { key: []const u8, position: usize = 0, value: []const u8 };
const max_template_params: usize = 16 * 1024;
pub const Template = struct {
    name: []const u8,
    params: []const Param,
    pub fn parse(a: std.mem.Allocator, body: []const u8) !Template {
        const first = delimiter(body, "|", 0) orelse body.len;
        var params: std.ArrayList(Param) = .empty;
        errdefer params.deinit(a);
        if (first == body.len) return .{ .name = trim(body), .params = try params.toOwnedSlice(a) };
        var pos = first + 1;
        var automatic: usize = 0;
        while (true) {
            if (params.items.len >= max_template_params) return error.RenderLimit;
            const end = delimiter(body, "|", pos) orelse body.len;
            const part = body[pos..end];
            if (delimiter(part, "=", 0)) |eq| {
                const key = trim(part[0..eq]);
                if (key.len == 0) {
                    if (end == body.len) break;
                    pos = end + 1;
                    continue;
                }
                const position = std.fmt.parseInt(usize, key, 10) catch 0;
                try params.append(a, .{ .key = key, .position = position, .value = trim(part[eq + 1 ..]) });
            } else {
                automatic += 1;
                // MediaWiki preserves whitespace for unnamed positional values.
                // Named (including explicitly numbered) values are trimmed above.
                try params.append(a, .{ .key = "", .position = automatic, .value = part });
            }
            if (end == body.len) break;
            pos = end + 1;
        }
        return .{ .name = trim(body[0..first]), .params = try params.toOwnedSlice(a) };
    }
    pub fn get(self: Template, n: usize) []const u8 {
        var i = self.params.len;
        while (i != 0) {
            i -= 1;
            if (self.params[i].position == n) return self.params[i].value;
        }
        return "";
    }
    pub fn named(self: Template, key: []const u8) []const u8 {
        var i = self.params.len;
        while (i != 0) {
            i -= 1;
            if (std.mem.eql(u8, self.params[i].key, key)) return self.params[i].value;
        }
        return "";
    }
    pub fn last(self: Template) usize {
        var max: usize = 0;
        for (self.params) |param| max = @max(max, param.position);
        return max;
    }
};
test "balanced handles simple and nested internal links identically" {
    const simple = "[[cat|feline]]tail";
    const simple_pair = balanced(simple, 0).?;
    try std.testing.expectEqual(@as(usize, 12), simple_pair.inner_end);
    try std.testing.expectEqual(@as(usize, 14), simple_pair.end);

    const nested = "[[cat|{{l|en|feline}}]]tail";
    const nested_pair = balanced(nested, 0).?;
    try std.testing.expectEqual(@as(usize, 21), nested_pair.inner_end);
    try std.testing.expectEqual(@as(usize, 23), nested_pair.end);
}

test "template parameters respect nested constructs and last-value wins" {
    const a = std.testing.allocator;
    const t = try Template.parse(a, "ux|en|[[a|b]] {{q|x}} <nowiki>|=</nowiki>|translation|2=replaced|q=rare");
    defer a.free(t.params);
    try std.testing.expectEqualStrings("replaced", t.get(2));
    try std.testing.expectEqualStrings("translation", t.get(3));
    try std.testing.expectEqualStrings("rare", t.named("q"));
    const source = "{{a|{{{1|[[b|c]]}}}}}tail";
    try std.testing.expectEqual(source.len - 4, balanced(source, 0).?.end);
}

test "template arguments scale to real Wiktionary columns while remaining bounded" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "col|en");
    for (0..1_200) |_| try body.appendSlice(a, "|term");
    const t = try Template.parse(a, body.items);
    defer a.free(t.params);
    try std.testing.expectEqual(@as(usize, 1_201), t.last());
    try std.testing.expectEqualStrings("term", t.get(1_201));

    body.clearRetainingCapacity();
    try body.appendSlice(a, "col");
    for (0..max_template_params + 1) |_| try body.appendSlice(a, "|x");
    try std.testing.expectError(error.RenderLimit, Template.parse(a, body.items));

    const sparse = try Template.parse(a, "col|en|2=two|999999999=last|2=override");
    defer a.free(sparse.params);
    try std.testing.expectEqualStrings("override", sparse.get(2));
    try std.testing.expectEqualStrings("last", sparse.get(999_999_999));
}

test "single-byte delimiter jump scan preserves structural skipping" {
    try std.testing.expectEqual(@as(?usize, 8), delimiter("a{{x|y}}|z", "|", 0));
    const protected = "<nowiki>|</nowiki>|tail";
    try std.testing.expectEqual(std.mem.lastIndexOfScalar(u8, protected, '|'), delimiter(protected, "|", 0));
    try std.testing.expectEqual(@as(?usize, 1), delimiter("a||b", "||", 0));
}

test "opaque extension bodies never split template arguments" {
    const a = std.testing.allocator;
    const t = try Template.parse(a, "x|<math>a|b=c</math>|<gallery>File:A.jpg|caption</gallery>|tail");
    defer a.free(t.params);
    try std.testing.expectEqualStrings("<math>a|b=c</math>", t.get(1));
    try std.testing.expectEqualStrings("<gallery>File:A.jpg|caption</gallery>", t.get(2));
    try std.testing.expectEqualStrings("tail", t.get(3));
    try std.testing.expectEqual(@as(?usize, null), delimiter("<syntaxhighlight>|=</syntaxhighlight>", "|", 0));
}

test "template parsing ignores empty named keys like runtime expansion" {
    const a = std.testing.allocator;
    const t = try Template.parse(a, "x|=ignored|one|name=value");
    defer a.free(t.params);
    try std.testing.expectEqual(@as(usize, 2), t.params.len);
    try std.testing.expectEqualStrings("one", t.get(1));
    try std.testing.expectEqualStrings("value", t.named("name"));
}

test "template parsing preserves positional whitespace but trims named values" {
    const a = std.testing.allocator;
    const t = try Template.parse(a, "x|  positional  |named=  named value  |2=  explicit numeric  ");
    defer a.free(t.params);
    try std.testing.expectEqualStrings("  positional  ", t.get(1));
    try std.testing.expectEqualStrings("explicit numeric", t.get(2));
    try std.testing.expectEqualStrings("named value", t.named("named"));
}

test "template parsing preserves explicit trailing empty parameters" {
    const a = std.testing.allocator;
    const one = try Template.parse(a, "x|");
    defer a.free(one.params);
    try std.testing.expectEqual(@as(usize, 1), one.params.len);
    try std.testing.expectEqual(@as(usize, 1), one.last());
    try std.testing.expectEqualStrings("", one.get(1));

    const several = try Template.parse(a, "x|a||");
    defer a.free(several.params);
    try std.testing.expectEqual(@as(usize, 3), several.params.len);
    try std.testing.expectEqual(@as(usize, 3), several.last());
    try std.testing.expectEqualStrings("a", several.get(1));
    try std.testing.expectEqualStrings("", several.get(2));
    try std.testing.expectEqualStrings("", several.get(3));
}

test "ordinary HTML matching ignores fake closers in comments and opaque extensions" {
    const source = "<div><!-- </div> --><nowiki></div></nowiki><b>kept</b></div>tail";
    const outer = tagAt(source, 0).?;
    const pair = matchingTag(source, outer).?;
    try std.testing.expectEqualStrings("tail", source[pair.end..]);
    try std.testing.expect(std.mem.indexOf(u8, source[outer.end..pair.inner_end], "<b>kept</b>") != null);

    const raw_source = "<nowiki><nowiki>x</nowiki>tail";
    const raw = tagAt(raw_source, 0).?;
    const raw_pair = matchingTag(raw_source, raw).?;
    try std.testing.expectEqualStrings("<nowiki>x", raw_source[raw.end..raw_pair.inner_end]);
    try std.testing.expectEqualStrings("tail", raw_source[raw_pair.end..]);
}

test "HTML tag scanning ends attributes at raw greater-than and retains self-closing whitespace" {
    const source = "<REF name=\"ab\" group='g&amp;x' / >tail";
    const tag = tagAt(source, 0).?;
    try std.testing.expect(tag.is("ref"));
    try std.testing.expect(tag.self_closing);
    try std.testing.expectEqualStrings("ab", tag.attr("name").?);
    try std.testing.expectEqualStrings("g&amp;x", tag.attr("GROUP").?);
    try std.testing.expectEqualStrings("tail", source[tag.end..]);
    try std.testing.expectEqualStrings("unterminated", tagAt("<span title='unterminated>", 0).?.attr("title").?);
    try std.testing.expect(tagAt("<9invalid>", 0) == null);
}

test "logical lines span safe multiline block containers" {
    const source = "<blockquote>\n# inside\n</blockquote>\n# outside";
    const end = logicalEnd(source, 0);
    try std.testing.expectEqualStrings("<blockquote>\n# inside\n</blockquote>", source[0..end]);
    try std.testing.expectEqual(@as(u8, '\n'), source[end]);
}

test "delimiter search stops conservatively at malformed nested opener storms" {
    const a = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "prefix");
    for (0..8_000) |_| try text.appendSlice(a, "{{broken");
    try text.appendSlice(a, "|not-top-level");
    try std.testing.expect(delimiter(text.items, "|", 0) == null);
}

test "behavior switches preserve unknown names and source case rules" {
    try std.testing.expectEqual(@as(?usize, 17), behaviorSwitchEnd("__NOEDITSECTION__", 0));
    try std.testing.expectEqual(@as(?usize, 9), behaviorSwitchEnd("__notoc__", 0));
    for ([_][]const u8{ "__unknown__", "__index__", "__NOEDITSECTION_", "__NOTOC extra__", "ordinary" }) |value|
        try std.testing.expectEqual(@as(?usize, null), behaviorSwitchEnd(value, 0));
}

test "redundant and missing terminal attribute quotes keep the raw tag boundary" {
    const input = "<span style=\"color:#6b5a40;\"\">tail";
    const tag = tagAt(input, 0).?;
    try std.testing.expect(tag.is("span"));
    try std.testing.expectEqualStrings("color:#6b5a40;", tag.attr("style").?);
    try std.testing.expectEqualStrings("tail", input[tag.end..]);
    try std.testing.expectEqualStrings("unterminated", tagAt("<span title=\"unterminated>", 0).?.attr("title").?);
    try std.testing.expectEqualStrings("unterminated", tagAt("<span title='unterminated>", 0).?.attr("title").?);
    const quoted = tagAt("<span title=\"a>b\">tail", 0).?;
    try std.testing.expectEqualStrings("a", quoted.attr("title").?);
    try std.testing.expectEqualStrings("b\">tail", "<span title=\"a>b\">tail"[quoted.end..]);
}

test "balanced internal links ignore quoted HTML attribute brackets only in link frames" {
    for ([_][]const u8{
        "[[cat|<span title=\"]]\">visible</span>]]",
        "[[cat|<span title=\"[[ ]]\">visible</span>]]",
        "[[cat|<span title=']]'>visible</span>]]",
        "[[cat|<nowiki>]]</nowiki>visible]]",
    }) |source| {
        try std.testing.expectEqual(source.len, balanced(source, 0).?.end);
    }
    const nested = "{{x|[[cat|<span title=\"]]\">visible</span>]]|tail}}";
    try std.testing.expectEqual(nested.len, balanced(nested, 0).?.end);
    // A nested link must not hide braces from its outer template scan.
    const nested_braces = "{{x|[[cat|<span title=\"{{\">visible</span>]]|tail}}";
    try std.testing.expect(balanced(nested_braces, 0) == null);
    const template = "{{x|<span title=\"}}\">visible</span>}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, template, "}}").? + 2, balanced(template, 0).?.end);
    const parameter = "{{{x|<span title=\"}}}\">visible</span>}}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, parameter, "}}}").? + 3, balanced(parameter, 0).?.end);
    const malformed = "[[cat|<span title=\"]] visible";
    try std.testing.expectEqual(std.mem.indexOf(u8, malformed, "]]").? + 2, balanced(malformed, 0).?.end);
}

test "logical lines skip complete quoted HTML tags without hiding content breaks" {
    const blank = "before <span title=\"one\n\ntwo\">visible</span> after\nnext";
    const ordinary = "before <span title=\"one\ntwo\">visible</span> after\nnext";
    try std.testing.expectEqual(blank.len - 5, logicalEnd(blank, 0));
    try std.testing.expectEqual(ordinary.len - 5, logicalEnd(ordinary, 0));
    const protected = "before <nowiki>one\n\ntwo</nowiki> after\nnext";
    try std.testing.expectEqual(protected.len - 5, logicalEnd(protected, 0));
    const content = "before <span>one\n\ntwo</span> after";
    try std.testing.expectEqual(std.mem.indexOfScalar(u8, content, '\n').?, logicalEnd(content, 0));
    const malformed = "before <span title=\"one\n\ntwo>visible";
    try std.testing.expectEqual(malformed.len, logicalEnd(malformed, 0));
}

test "typographic and missing attribute quotes end at the first raw tag delimiter" {
    const Fixture = struct { source: []const u8, attribute: []const u8, suffix: []const u8 };
    for ([_]Fixture{
        .{ .source = "<big style=\"color: #00008B;”>first</big>", .attribute = "color: #00008B;”", .suffix = "first</big>" },
        .{ .source = "<big style=\"literal ”> </big>\n still quoted\">visible</big>", .attribute = "literal ”", .suffix = " </big>\n still quoted\">visible</big>" },
        .{ .source = "<big style=\"unterminated>first</big>", .attribute = "unterminated", .suffix = "first</big>" },
        .{ .source = "<big style=\"color:red;”>no closing element", .attribute = "color:red;”", .suffix = "no closing element" },
        .{ .source = "<big style=\"one ”> two ”> three ”> end\">visible</big>", .attribute = "one ”", .suffix = " two ”> three ”> end\">visible</big>" },
    }) |fixture| {
        const tag = tagAt(fixture.source, 0).?;
        try std.testing.expectEqualStrings(fixture.attribute, tag.attr("style").?);
        try std.testing.expectEqualStrings(fixture.suffix, fixture.source[tag.end..]);
    }
    const multiline = "<big style=\"color:\nred;\">tail</big>";
    try std.testing.expectEqualStrings("color:\nred;", tagAt(multiline, 0).?.attr("style").?);
    try std.testing.expect(tagAt("<div title=\"a<b\">word</div>", 0) == null);
}

test "unquoted quote and equals bytes preserve attribute extraction at the raw tag boundary" {
    const Fixture = struct { source: []const u8, title: []const u8 };
    for ([_]Fixture{
        .{ .source = "<span title=can't>tail", .title = "can't" },
        .{ .source = "<span title=abc\"def>tail", .title = "abc\"def" },
        .{ .source = "<span title=left=can't>tail", .title = "left=can't" },
        .{ .source = "<span title=left=abc\"def>tail", .title = "left=abc\"def" },
        .{ .source = "<span title=can't lang='en'>tail", .title = "can't" },
    }) |fixture| {
        const tag = tagAt(fixture.source, 0).?;
        try std.testing.expectEqualStrings(fixture.title, tag.attr("title").?);
        try std.testing.expectEqualStrings("tail", fixture.source[tag.end..]);
    }
    for ([_][]const u8{ "span", "div", "b", "code", "nowiki", "pre", "ref", "source", "syntaxhighlight" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "<{s} title=\"alpha > beta\">body</{s}>", .{ name, name });
        defer std.testing.allocator.free(source);
        const tag = tagAt(source, 0).?;
        try std.testing.expectEqualStrings("alpha", tag.attr("title").?);
        try std.testing.expect(std.mem.startsWith(u8, source[tag.end..], " beta\">body"));
    }
}

test "heading control suffix keeps protected unknown and entity literals" {
    try std.testing.expectEqualStrings("=English=", headingControlPrefix("=English=__NOTOC__ __NOEDITSECTION__", null));
    for ([_][]const u8{ "=English=__UNKNOWN__", "=English=&#95;&#95;NOTOC__", "=English=<nowiki>__NOTOC__</nowiki>", "=English=<span title=\"__NOTOC__\">text</span>", "=English=__NOTOC__ tail" }) |line|
        try std.testing.expectEqualStrings(line, headingControlPrefix(line, null));
}

test "leading active controls affect heading boundary and preserve protected spelling" {
    try std.testing.expectEqualStrings("== English ==", headingControlPrefix("__NOEDITSECTION__== English ==", null));
    try std.testing.expectEqualStrings("== English ==", headingControlPrefix("__NOTOC____NOEDITSECTION__== English ==__NOTOC__", null));
    for ([_][]const u8{ "__UNKNOWN__== English ==", "&#95;&#95;NOEDITSECTION&#95;&#95;== English ==", "<nowiki>__NOEDITSECTION__</nowiki>== English ==" }) |source| {
        try std.testing.expectEqual(@as(usize, 0), leadingBehaviorControlOffset(source, null));
        try std.testing.expectEqualStrings(source, headingControlPrefix(source, null));
    }
}

test "opaque first closer is not hidden by literal pseudo-tag quotes" {
    for ([_][]const u8{ "nowiki", "pre" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "<{s}><span title=\"</{s}>\">[[B]]", .{ name, name });
        defer std.testing.allocator.free(source);
        const opening = tagAt(source, 0).?;
        const pair = matchingTag(source, opening).?;
        try std.testing.expectEqualStrings("<span title=\"", source[opening.end..pair.inner_end]);
        try std.testing.expectEqualStrings("\">[[B]]", source[pair.end..]);
    }
    for ([_][]const u8{ "</nowiki x>", "</nowiki/>", "</nowikix>", "&lt;/nowiki&gt;" }) |literal| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "<nowiki>{s}[[B]]</NOWIKI \t>[[C]]", .{literal});
        defer std.testing.allocator.free(source);
        const opening = tagAt(source, 0).?;
        const pair = matchingTag(source, opening).?;
        try std.testing.expectEqualStrings("[[C]]", source[pair.end..]);
        try std.testing.expect(std.mem.endsWith(u8, source[opening.end..pair.inner_end], "[[B]]"));
    }
}

test "canonical behavior controls use simple Unicode caseless equivalence" {
    try std.testing.expectEqual(@as(?usize, "__NOEDITſECTION__".len), behaviorSwitchEnd("__NOEDITſECTION__tail", 0));
    try std.testing.expectEqual(@as(?usize, 1 + "__NOEDITſECTION__".len), behaviorSwitchEnd("x__NOEDITſECTION__tail", 1));
    try std.testing.expect(canonicalAliasEqual("K", "K"));
    for ([_][]const u8{ "__ſTATICREDIRECT__", "__NOEDİTSECTION__", "__UNKNOWN__", "__NOEDIT\xc0\xafECTION__" }) |source|
        try std.testing.expectEqual(@as(?usize, null), behaviorSwitchEnd(source, 0));
}

test "nowiki source regions preserve raw offsets and active unclosed remainder" {
    const closed = "<nowiki>raw > <span title=\"</nowiki extra>\">[[hidden]]</NOWIKI \t>tail";
    const region = nowikiRegionAt(closed, 0).?;
    try std.testing.expectEqualStrings("raw > <span title=\"</nowiki extra>\">[[hidden]]", closed[region.opening_end..region.inner_end]);
    try std.testing.expectEqualStrings("tail", closed[region.end..]);
    try std.testing.expect(nowikiRegionAt("< nowiki>literal</nowiki>", 0) == null);
    try std.testing.expect(protectedEnd("<nowiki>[[active]]", 0) == null);
    try std.testing.expectEqual(@as(?usize, "<pre>".len), protectedEnd("<pre>[[active]]", 0));
    const ordinary = "<span title=\"<nowiki>raw > \" </nowiki>suffix\">word</span>";
    const tag = tagAt(ordinary, 0).?;
    try std.testing.expectEqualStrings("word</span>", ordinary[tag.end..]);
    try std.testing.expectEqualStrings(" title=\"<nowiki>raw > \" </nowiki>suffix\"", tag.attrs);
    try std.testing.expect(tagAt("<span title=\"<nowiki>unclosed>word", 0) == null);
    const container = "<div><nowiki>active</div>tail";
    try std.testing.expectEqualStrings("tail", container[matchingTag(container, tagAt(container, 0).?).?.end..]);
    const template = "{{T|<nowiki>active|second}}tail";
    const parsed = try Template.parse(std.testing.allocator, template[2..balanced(template, 0).?.inner_end]);
    defer std.testing.allocator.free(parsed.params);
    try std.testing.expectEqualStrings("<nowiki>active", parsed.get(1));
    try std.testing.expectEqualStrings("second", parsed.get(2));
    var missing = false;
    try std.testing.expect(nowikiRegionAtCached("<nowiki>unclosed", 0, &missing) == null);
    try std.testing.expect(missing);
    try std.testing.expect(nowikiRegionAtCached("<nowiki/>", 0, &missing).?.self_closing);
}

test "failed attribute lookahead cannot invalidate an earlier closed nowiki" {
    const source = "<span title=\"<nowiki>|hidden</nowiki><nowiki>unclosed";
    var missing = false;
    try std.testing.expect(tagAtCached(source, 0, &missing) == null);
    try std.testing.expect(!missing);
    try std.testing.expect(delimiter(source, "|", 0) == null);
    const later_pipe = source ++ "|active";
    try std.testing.expectEqual(source.len, delimiter(later_pipe, "|", 0).?);
    const lines = "<span title=\"<nowiki>hidden\nline</nowiki><nowiki>unclosed\nvisible";
    try std.testing.expectEqualStrings("<span title=\"<nowiki>hidden\nline</nowiki><nowiki>unclosed", lines[0..logicalEnd(lines, 0)]);
}

test "nowiki adjacent slash requires immediate closing angle" {
    for ([_][]const u8{ "<nowiki/ >[[cat]]</nowiki>", "<NoWiKi/\t>[[cat]]</nowiki>", "<nowiki/attr>[[cat]]</nowiki>" }) |source| {
        var missing = false;
        try std.testing.expect(tagAt(source, 0) == null);
        try std.testing.expect(nowikiRegionAtCached(source, 0, &missing) == null);
        try std.testing.expect(!missing);
        try std.testing.expect(protectedEnd(source, 0) == null);
    }
    for ([_][]const u8{ "<nowiki/>", "<NoWiKi />" }) |source| {
        const region = nowikiRegionAt(source, 0).?;
        try std.testing.expect(region.self_closing);
        try std.testing.expectEqual(source.len, region.end);
    }
    const quoted = "<nowiki a='>'>[[cat]]</nowiki>";
    const region = nowikiRegionAt(quoted, 0).?;
    try std.testing.expect(!region.self_closing);
    try std.testing.expectEqualStrings("'>[[cat]]", quoted[region.opening_end..region.inner_end]);
}

test "structural controls join empty heading and list delimiter runs only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "=__NOEDITSECTION__=French==",
        "==French=__NOGALLERY__=",
        "=__NOEDITSECTION__=French=__NOTOC__=",
    }) |source| {
        const heading = controlHeading(source, null).?;
        try std.testing.expectEqual(@as(u8, 2), heading.level);
        try std.testing.expectEqualStrings("French", heading.title);
    }
    try std.testing.expect(controlHeading("============", null) == null);
    const equals_only = controlHeading("=============", null).?;
    try std.testing.expectEqual(@as(u8, 6), equals_only.level);
    try std.testing.expectEqualStrings("=", equals_only.title);
    const extra = controlHeading("===__NOEDITSECTION__=Title==", null).?;
    try std.testing.expectEqual(@as(u8, 2), extra.level);
    try std.testing.expectEqualStrings("=__NOEDITSECTION__=Title", extra.title);
    for ([_][]const u8{
        "=__TOC__=French==",
        "=__UNKNOWN__=French==",
        "=__NOEDITSECTION__ =French==",
        "=<nowiki>__NOEDITSECTION__</nowiki>=French==",
        "=&#95;&#95;NOEDITSECTION&#95;&#95;=French==",
    }) |source| try std.testing.expectEqual(@as(u8, 1), controlHeading(source, null).?.level);
    try std.testing.expect(controlHeading("__TOC__==French==", null) == null);
    const nested = try controlListPrefixAlloc(a, "*__NOEDITSECTION__#__NOTOC__:", null);
    try std.testing.expectEqualStrings("*#:", nested.path);
    try std.testing.expectEqual(@as(usize, "*__NOEDITSECTION__#__NOTOC__:".len), nested.body_start);
    for ([_][]const u8{
        "*__TOC__# literal",
        "*__UNKNOWN__# literal",
        "*__NOEDITSECTION__ # literal",
        "*<nowiki>__NOEDITSECTION__</nowiki># literal",
        "*&#95;&#95;NOEDITSECTION&#95;&#95;# literal",
    }) |source| {
        const prefix = try controlListPrefixAlloc(a, source, null);
        try std.testing.expectEqualStrings("*", prefix.path);
        try std.testing.expectEqual(@as(usize, 1), prefix.body_start);
    }
    const body = "*__NOEDITSECTION__ body";
    const unchanged = try controlListPrefixAlloc(a, body, null);
    try std.testing.expectEqualStrings("__NOEDITSECTION__ body", body[unchanged.body_start..]);
}

test "unmatched opaque scopes resume outer tags delimiters and logical lines" {
    for (opaque_tag_names) |name| {
        if (std.ascii.eqlIgnoreCase(name, "nowiki")) continue;
        const source = try std.fmt.allocPrint(std.testing.allocator, "<div><{s}>[[cat]]</div>tail", .{name});
        defer std.testing.allocator.free(source);
        const outer = matchingTag(source, tagAt(source, 0).?).?;
        try std.testing.expectEqualStrings("tail", source[outer.end..]);
        try std.testing.expectEqual(@as(?usize, 5 + name.len + 2), protectedEnd(source, 5));
        const lines = try std.fmt.allocPrint(std.testing.allocator, "<{s}>active\n== Heading ==", .{name});
        defer std.testing.allocator.free(lines);
        try std.testing.expectEqual(std.mem.indexOfScalar(u8, lines, '\n').?, logicalEnd(lines, 0));
        const templ = try std.fmt.allocPrint(std.testing.allocator, "{{{{T|<{s}>active|second}}}}tail", .{name});
        defer std.testing.allocator.free(templ);
        try std.testing.expectEqualStrings("tail", templ[balanced(templ, 0).?.end..]);
    }
    const closed = "<div><source></div>hidden</source></div>tail";
    try std.testing.expectEqualStrings("tail", closed[matchingTag(closed, tagAt(closed, 0).?).?.end..]);
    try std.testing.expectEqual(@as(?usize, 15), protectedEnd("<!-- unfinished", 0));
}

test "opaque missing closer cache is family local forward and selfclosing safe" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..4000) |_| try bytes.appendSlice(std.testing.allocator, "<source><pre><math>");
    try bytes.appendSlice(std.testing.allocator, "<ref>closed</ref><source/>[[cat]]");
    var scan: OpaqueScan = .{};
    var at: usize = 0;
    var missing_nowiki = false;
    while (at < bytes.items.len and bytes.items[at] == '<') {
        const end = scan.protectedEnd(bytes.items, at, &missing_nowiki).?;
        try std.testing.expect(end > at);
        at = end;
    }
    try std.testing.expectEqualStrings("[[cat]]", bytes.items[at..]);
    try std.testing.expectEqual(@as(u32, 3), @popCount(scan.missing));
}

test "opaque selfclosing needs adjacent slash and later misses do not poison earlier pairs" {
    for ([_][]const u8{ "nowiki", "pre", "source", "math", "ref" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "<{s} / >[[hidden]]</{s}>tail", .{ name, name });
        defer std.testing.allocator.free(source);
        const tag = tagAt(source, 0).?;
        try std.testing.expect(!tag.self_closing);
        const pair = matchingTag(source, tag).?;
        try std.testing.expectEqualStrings("[[hidden]]", source[tag.end..pair.inner_end]);
        try std.testing.expectEqualStrings("tail", source[pair.end..]);
        const invalid = try std.fmt.allocPrint(std.testing.allocator, "<{s}/ >[[active]]</{s}>", .{ name, name });
        defer std.testing.allocator.free(invalid);
        try std.testing.expect(tagAt(invalid, 0) == null);
        try std.testing.expect(protectedEnd(invalid, 0) == null);
    }
    const source = "<source>closed</source><source>missing";
    var scan: OpaqueScan = .{};
    const later = std.mem.lastIndexOf(u8, source, "<source>").?;
    try std.testing.expect(scan.pair(source, tagAt(source, later).?) == null);
    const earlier = scan.pair(source, tagAt(source, 0).?).?;
    try std.testing.expectEqualStrings("closed", source[8..earlier.inner_end]);
    try std.testing.expect(tagAt("<div / >", 0).?.self_closing);
}
