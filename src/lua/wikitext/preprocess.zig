const std = @import("std");

fn findCiPos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return @min(start, hay.len);
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1)
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    return null;
}

fn decodedTagEnd(text: []const u8, start: usize) ?usize {
    const p = std.mem.indexOfScalarPos(u8, text, start, '>') orelse return null;
    return p + 1;
}

// Nowiki alone requires a real closed region; an unmatched opener is literal.
// Match source boundaries before interpreting its literal body, without recursion.
fn nowikiRegionEnd(text: []const u8, start: usize) ?usize {
    return nowikiRegionEndCached(text, start, null);
}
fn nowikiRegionEndCached(text: []const u8, start: usize, no_more_close: ?*bool) ?usize {
    if (start >= text.len or text[start] != '<') return null;
    const name_start = start + 1;
    const name_end = name_start + "nowiki".len;
    if (name_end > text.len or !std.ascii.eqlIgnoreCase(text[name_start..name_end], "nowiki") or
        !isTagNameBoundary(text, name_end)) return null;
    const open_end = decodedTagEnd(text, start) orelse return null;
    var before_gt = open_end - 1;
    while (before_gt > start and std.ascii.isWhitespace(text[before_gt - 1])) : (before_gt -= 1) {}
    if (before_gt > start and text[before_gt - 1] == '/') return open_end;
    if (no_more_close) |missing| if (missing.*) return null;
    const end = inclusionCloseEnd(text, open_end, "nowiki");
    if (end == null) {
        if (no_more_close) |missing| missing.* = true;
    }
    return end;
}

pub fn stripDecodedComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    var line_start: usize = 0;
    var line_has_content = false;
    var no_more_nowiki_close = false;
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |open| {
        const prefix = text[pos..open];
        for (prefix, 0..) |byte, at| {
            if (byte == '\n') {
                line_start = out.items.len + at + 1;
                line_has_content = false;
            } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
        }
        try out.appendSlice(a, prefix);
        if (std.mem.startsWith(u8, text[open..], "<!--")) {
            const close = findCiPos(text, open + 4, "-->") orelse {
                pos = text.len;
                break;
            };
            pos = close + 3;
            // Remove only comment-only lines and their terminating newline.
            // Keep the preceding newline, authored blanks and protected bodies.
            if (!line_has_content) {
                var line_end = pos;
                while (line_end < text.len and (text[line_end] == ' ' or text[line_end] == '\t' or text[line_end] == '\r')) : (line_end += 1) {}
                if (line_end == text.len or text[line_end] == '\n') {
                    out.items.len = line_start;
                    pos = if (line_end < text.len) line_end + 1 else line_end;
                }
            }
            continue;
        }
        // Only a real closed/self-closing nowiki protects comments. An
        // unmatched opener remains literal and leaves the remainder active.
        if (nowikiRegionEndCached(text, open, &no_more_nowiki_close)) |end| {
            const protected = text[open..end];
            for (protected, 0..) |byte, at| {
                if (byte == '\n') {
                    line_start = out.items.len + at + 1;
                    line_has_content = false;
                } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
            }
            try out.appendSlice(a, protected);
            pos = end;
            continue;
        }
        // Preserve existing closed pre/code-extension comment behavior.
        if (inclusionTagAt(text, open)) |tag| {
            const code_extension = std.ascii.eqlIgnoreCase(tag.name, "source") or
                std.ascii.eqlIgnoreCase(tag.name, "syntaxhighlight");
            if (std.ascii.eqlIgnoreCase(tag.name, "pre") or code_extension) {
                if (rawTagEnd(text, open)) |opening_end| {
                    var before_gt = opening_end - 1;
                    while (before_gt > open and std.ascii.isWhitespace(text[before_gt - 1])) : (before_gt -= 1) {}
                    const end = if (before_gt > open and text[before_gt - 1] == '/') opening_end else inclusionCloseEnd(text, opening_end, tag.name) orelse opening_end;
                    const protected = text[open..end];
                    for (protected, 0..) |byte, at| {
                        if (byte == '\n') {
                            line_start = out.items.len + at + 1;
                            line_has_content = false;
                        } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
                    }
                    try out.appendSlice(a, protected);
                    pos = end;
                    continue;
                }
            }
        }
        try out.append(a, '<');
        line_has_content = true;
        pos = open + 1;
    }
    try out.appendSlice(a, text[pos..]);
    return out.toOwnedSlice(a);
}

const InclusionTag = struct {
    name: []const u8,
    mode: enum { delimiter, excluded, preserved },
    close_cache_slot: usize = 0,
};

fn inclusionTagAt(text: []const u8, start: usize) ?InclusionTag {
    const name_start = start + 1;
    var end = name_start;
    if (end < text.len and text[end] == '/') end += 1;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) : (end += 1) {}
    if (end == name_start or end == text.len) return null;
    if (!std.ascii.isWhitespace(text[end]) and text[end] != '>' and
        !std.mem.startsWith(u8, text[end..], "/>")) return null;
    const name = text[name_start..end];
    if (std.ascii.eqlIgnoreCase(name, "includeonly") or std.ascii.eqlIgnoreCase(name, "/includeonly"))
        return .{ .name = name, .mode = .delimiter };
    if (std.ascii.eqlIgnoreCase(name, "noinclude"))
        return .{ .name = name, .mode = .excluded };
    if (opaqueParserTagIndex(name)) |index|
        return .{ .name = name, .mode = .preserved, .close_cache_slot = index + 1 };
    return null;
}

fn inclusionCloseEnd(text: []const u8, start: usize, name: []const u8) ?usize {
    var pos = start;
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |lt| {
        const name_end = lt + 2 + name.len;
        if (name_end <= text.len and text[lt + 1] == '/' and
            std.ascii.eqlIgnoreCase(text[lt + 2 .. name_end], name))
        {
            var end = name_end;
            while (end < text.len and std.ascii.isWhitespace(text[end])) : (end += 1) {}
            if (end < text.len and text[end] == '>') return end + 1;
        }
        pos = lt + 1;
    }
    return null;
}

pub fn transcludeDecodedAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return transcludeDecodedWithBoundariesAlloc(a, text, false);
}

// Empty inclusion nodes must remain separate while parsing template arguments.
// Their text is omitted only when expanding the already separated values.
pub fn transcludeDecodedForParsingAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return transcludeDecodedWithBoundariesAlloc(a, text, true);
}

fn transcludeDecodedWithBoundariesAlloc(a: std.mem.Allocator, text: []const u8, preserve_empty_noinclude: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    // MediaWiki Preprocessor_Hash selects exact onlyinclude delimiters on the
    // raw source, before recognizing comments or extension bodies.
    const onlyinclude = std.mem.indexOf(u8, text, "<onlyinclude>") != null and
        std.mem.indexOf(u8, text, "</onlyinclude>") != null;
    var seeking_onlyinclude = onlyinclude;
    var no_more_gt = false;
    var no_more_close: [opaque_parser_tags.len + 1]bool = @splat(false);
    var pos: usize = 0;
    while (pos < text.len) {
        if (seeking_onlyinclude) {
            const open = std.mem.indexOfPos(u8, text, pos, "<onlyinclude>") orelse break;
            pos = open + "<onlyinclude>".len;
            seeking_onlyinclude = false;
        }
        const lt = std.mem.indexOfScalarPos(u8, text, pos, '<') orelse {
            try out.appendSlice(a, text[pos..]);
            break;
        };
        try out.appendSlice(a, text[pos..lt]);
        if (onlyinclude and std.mem.startsWith(u8, text[lt..], "</onlyinclude>")) {
            pos = lt + "</onlyinclude>".len;
            seeking_onlyinclude = true;
            continue;
        }
        if (std.mem.startsWith(u8, text[lt..], "<!--")) {
            const close = std.mem.indexOfPos(u8, text, lt + 4, "-->") orelse break;
            pos = close + 3;
            continue;
        }
        const tag = inclusionTagAt(text, lt) orelse {
            try out.append(a, '<');
            pos = lt + 1;
            continue;
        };
        // The PHP preprocessor uses the first raw '>', even inside attributes.
        const open_end = (if (no_more_gt) null else decodedTagEnd(text, lt)) orelse {
            no_more_gt = true;
            try out.append(a, '<');
            pos = lt + 1;
            continue;
        };
        if (tag.mode == .delimiter) {
            pos = open_end;
            continue;
        }
        if (text[open_end - 2] == '/') {
            if (tag.mode == .preserved or (preserve_empty_noinclude and tag.mode == .excluded))
                try out.appendSlice(a, text[lt..open_end]);
            pos = open_end;
            continue;
        }
        // Elements end at the first closing tag, without nesting. Cache misses
        // so repeated unclosed extension tags cannot cause quadratic scans.
        const close_end = if (no_more_close[tag.close_cache_slot]) null else inclusionCloseEnd(text, open_end, tag.name);
        if (close_end) |end| {
            if (tag.mode == .preserved) try out.appendSlice(a, text[lt..end]);
            pos = end;
        } else {
            no_more_close[tag.close_cache_slot] = true;
            // The upstream missing-end whitelist uses the original spelling.
            // A lowercase noinclude legitimately excludes through EOF.
            if (std.mem.eql(u8, tag.name, "noinclude")) break;
            try out.appendSlice(a, text[lt..open_end]);
            pos = open_end;
        }
    }
    return out.toOwnedSlice(a);
}

/// Append expanded plain text without leaking empty inclusion-node boundaries.
/// Literal extension bodies keep their authored contents untouched.
pub fn appendParsingText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var pos: usize = 0;
    var copied: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |lt| {
        if (opaqueParserRegionEnd(text, lt)) |end| {
            pos = end;
            continue;
        }
        if (inclusionTagAt(text, lt)) |tag| {
            if (tag.mode == .excluded) {
                if (decodedTagEnd(text, lt)) |end| {
                    if (end >= 2 and text[end - 2] == '/') {
                        try out.appendSlice(a, text[copied..lt]);
                        copied = end;
                        pos = end;
                        continue;
                    }
                }
            }
        }
        pos = lt + 1;
    }
    try out.appendSlice(a, text[copied..]);
}

pub const ConstructKind = enum { template, parameter };

pub const Construct = struct {
    open: usize,
    close: usize,
    kind: ConstructKind,
};

const BracePiece = struct {
    count: usize,
    root: bool,
};

fn repeatedByteRun(s: []const u8, start: usize, byte: u8) usize {
    var end = start;
    while (end < s.len and s[end] == byte) : (end += 1) {}
    return end - start;
}

fn matchingBraceWidth(open_count: usize, close_count: usize) u8 {
    const count = @min(open_count, close_count);
    if (count >= 3) return 3;
    if (count >= 2) return 2;
    return 0;
}

fn findBraceConstruct(s: []const u8, start: usize) ?Construct {
    if (start >= s.len or s[start] != '{') return null;
    const root_count = repeatedByteRun(s, start, '{');
    if (root_count < 2) return null;

    var stack: [128]BracePiece = undefined;
    var depth: usize = 1;
    stack[0] = .{ .count = root_count, .root = true };
    var i = start + root_count;
    while (i < s.len) {
        if (opaqueParserRegionEnd(s, i)) |region_end| {
            i = region_end;
            continue;
        }
        if (s[i] == '{') {
            const count = repeatedByteRun(s, i, '{');
            if (count >= 2) {
                if (depth == stack.len) return null;
                stack[depth] = .{ .count = count, .root = false };
                depth += 1;
                i += count;
                continue;
            }
        }
        if (s[i] == '}' and depth != 0) {
            const close_count = repeatedByteRun(s, i, '}');
            const piece = stack[depth - 1];
            const width = matchingBraceWidth(piece.count, close_count);
            if (width != 0) {
                depth -= 1;
                const remainder = piece.count - width;
                if (remainder >= 2) {
                    stack[depth] = .{ .count = remainder, .root = piece.root };
                    depth += 1;
                } else if (piece.root) {
                    return .{
                        .open = start + @intFromBool(remainder == 1),
                        .close = i,
                        .kind = if (width == 2) .template else .parameter,
                    };
                }
                i += width;
                continue;
            }
        }
        i += 1;
    }
    return null;
}

pub fn findTemplateEnd(s: []const u8, start: usize) ?usize {
    const construct = findBraceConstruct(s, start) orelse return null;
    if (construct.open != start or construct.kind != .template) return null;
    return construct.close;
}

pub fn findParamEnd(s: []const u8, start: usize) ?usize {
    const construct = findBraceConstruct(s, start) orelse return null;
    if (construct.open != start or construct.kind != .parameter) return null;
    return construct.close;
}

const opaque_parser_tags = [_][]const u8{
    "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
    "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
    "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
    "section", "inputbox", "imagemap",     "dynamicpagelist",
};

fn opaqueParserTagIndex(name: []const u8) ?usize {
    inline for (opaque_parser_tags, 0..) |tag, i|
        if (std.ascii.eqlIgnoreCase(name, tag)) return i;
    return null;
}

fn isOpaqueParserTag(name: []const u8) bool {
    return opaqueParserTagIndex(name) != null;
}

fn isLiteralParserTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",          "pre",   "math",  "ce",       "chem",    "score",    "syntaxhighlight", "source",
        "timeline",        "hiero", "graph", "mapframe", "maplink", "inputbox", "imagemap",        "templatestyles",
        "dynamicpagelist",
    }) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn isTagNameBoundary(s: []const u8, pos: usize) bool {
    if (pos >= s.len) return true;
    return s[pos] == '>' or s[pos] == '/' or std.ascii.isWhitespace(s[pos]);
}

pub fn rawTagEnd(s: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '>') return i + 1;
    }
    return null;
}

pub fn findNextConstructOutsideLiteralTags(s: []const u8, start: usize) ?Construct {
    var i = start;
    var no_more_nowiki_close = false;
    while (i + 1 < s.len) {
        if (s[i] == '<') {
            if (nowikiRegionEndCached(s, i, &no_more_nowiki_close)) |end| {
                i = end;
                continue;
            }
            var p = i + 1;
            while (p < s.len and std.ascii.isWhitespace(s[p])) : (p += 1) {}
            const name_start = p;
            while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) : (p += 1) {}
            if (p > name_start and isTagNameBoundary(s, p) and isLiteralParserTag(s[name_start..p]) and
                !std.ascii.eqlIgnoreCase(s[name_start..p], "nowiki"))
            {
                const name = s[name_start..p];
                const open_end = rawTagEnd(s, i) orelse return null;
                var before_gt = open_end - 1;
                while (before_gt > i and std.ascii.isWhitespace(s[before_gt - 1])) : (before_gt -= 1) {}
                if (before_gt > i and s[before_gt - 1] == '/') {
                    i = open_end;
                    continue;
                }
                var search = open_end;
                var closed = false;
                while (std.mem.indexOfScalarPos(u8, s, search, '<')) |lt| {
                    if (lt + 2 + name.len <= s.len and s[lt + 1] == '/' and
                        std.ascii.eqlIgnoreCase(s[lt + 2 .. lt + 2 + name.len], name))
                    {
                        const after = lt + 2 + name.len;
                        if (after >= s.len or s[after] == '>' or std.ascii.isWhitespace(s[after])) {
                            i = rawTagEnd(s, lt) orelse return null;
                            closed = true;
                            break;
                        }
                    }
                    search = lt + 1;
                }
                if (!closed) return null;
                continue;
            }
        }
        if (s[i] == '{' and s[i + 1] == '{') {
            if (findBraceConstruct(s, i)) |construct| return construct;
        }
        i += 1;
    }
    return null;
}

pub fn findTemplateOpenOutsideLiteralTags(s: []const u8, start: usize) ?usize {
    return if (findNextConstructOutsideLiteralTags(s, start)) |construct| construct.open else null;
}

pub fn opaqueParserRegionEnd(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '<') return null;
    if (std.mem.startsWith(u8, s[start..], "<!--")) {
        const close = std.mem.indexOfPos(u8, s, start + 4, "-->") orelse return s.len;
        return close + 3;
    }
    if (nowikiRegionEnd(s, start)) |end| return end;
    var p = start + 1;
    if (p >= s.len or s[p] == '/') return null;
    while (p < s.len and std.ascii.isWhitespace(s[p])) : (p += 1) {}
    const name_start = p;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) : (p += 1) {}
    if (p == name_start) return null;
    if (!isTagNameBoundary(s, p)) return null;
    const name = s[name_start..p];
    if (!isOpaqueParserTag(name) or std.ascii.eqlIgnoreCase(name, "nowiki")) return null;
    const open_end = rawTagEnd(s, start) orelse return s.len;
    var before_gt = open_end - 1;
    while (before_gt > start and std.ascii.isWhitespace(s[before_gt - 1])) : (before_gt -= 1) {}
    if (before_gt > start and s[before_gt - 1] == '/') return open_end;

    var search = open_end;
    while (std.mem.indexOfScalarPos(u8, s, search, '<')) |lt| {
        if (lt + 2 + name.len <= s.len and s[lt + 1] == '/' and std.ascii.eqlIgnoreCase(s[lt + 2 .. lt + 2 + name.len], name)) {
            const after = lt + 2 + name.len;
            if (after >= s.len or s[after] == '>' or std.ascii.isWhitespace(s[after]))
                return rawTagEnd(s, lt) orelse s.len;
        }
        search = lt + 1;
    }
    return s.len;
}

pub fn findTopDelimiter(s: []const u8, needle: u8) ?usize {
    return findTopDelimiterImpl(s, needle, false);
}

pub const ParserColon = struct { index: usize, len: usize };

pub fn findTopParserColon(s: []const u8) ?ParserColon {
    const index = findTopDelimiterImpl(s, ':', true) orelse return null;
    return .{ .index = index, .len = if (s[index] == ':') 1 else "：".len };
}

fn findTopDelimiterImpl(s: []const u8, needle: u8, fullwidth_colon: bool) ?usize {
    var braces: [128]usize = undefined;
    var brace_depth: usize = 0;
    var square: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (opaqueParserRegionEnd(s, i)) |region_end| {
            i = region_end;
            continue;
        }
        if (s[i] == '{') {
            const count = repeatedByteRun(s, i, '{');
            if (count >= 2) {
                if (brace_depth == braces.len) return null;
                braces[brace_depth] = count;
                brace_depth += 1;
                i += count;
                continue;
            }
        }
        if (s[i] == '}' and brace_depth != 0) {
            const close_count = repeatedByteRun(s, i, '}');
            const open_count = braces[brace_depth - 1];
            const width = matchingBraceWidth(open_count, close_count);
            if (width != 0) {
                brace_depth -= 1;
                const remainder = open_count - width;
                if (remainder >= 2) {
                    braces[brace_depth] = remainder;
                    brace_depth += 1;
                }
                i += width;
                continue;
            }
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "[[")) {
            square += 1;
            i += 2;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "]]") and square != 0) {
            square -= 1;
            i += 2;
            continue;
        }
        if (brace_depth == 0 and square == 0 and
            (s[i] == needle or (fullwidth_colon and std.mem.startsWith(u8, s[i..], "：")))) return i;
        i += 1;
    }
    return null;
}

pub fn splitWikitextTop(a: std.mem.Allocator, s: []const u8, delimiter: u8, out: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        const rel = findTopDelimiter(s[pos..], delimiter) orelse break;
        const cut = pos + rel;
        try out.append(a, s[start..cut]);
        start = cut + 1;
        pos = start;
    }
    try out.append(a, s[start..]);
}

test "parser colon recognizes ASCII and fullwidth outside nested constructs" {
    try std.testing.expectEqual(ParserColon{ .index = 3, .len = 3 }, findTopParserColon("#if：yes").?);
    try std.testing.expectEqual(ParserColon{ .index = 3, .len = 1 }, findTopParserColon("#if:yes").?);
    const head = "{{name|inner：value}}：argument:tail";
    try std.testing.expectEqual(ParserColon{ .index = "{{name|inner：value}}".len, .len = 3 }, findTopParserColon(head).?);
    try std.testing.expect(findTopParserColon("[[a：b]]<nowiki>:</nowiki>") == null);
}

pub const ParameterSplit = struct { key: []const u8, default: ?[]const u8 };
pub fn splitParameter(s: []const u8) ParameterSplit {
    if (findTopDelimiter(s, '|')) |bar| return .{ .key = s[0..bar], .default = s[bar + 1 ..] };
    return .{ .key = s, .default = null };
}

test "template opener scan skips literal extension bodies but enters wikitext extensions" {
    const source = "a<NoWiKi class='x'>{{hidden}}</NoWiKi>b{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(source, 0).?);
    try std.testing.expectEqual(@as(usize, 8), findTemplateOpenOutsideLiteralTags("<nowiki>{{hidden}}", 0).?);
    try std.testing.expectEqual(@as(usize, 10), findTemplateOpenOutsideLiteralTags("<nowiki/> {{x}}", 0).?);
    const math = "<math>{{hidden}}</math>{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, math, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(math, 0).?);
    const syntax = "<syntaxhighlight lang='lua'>{{hidden}}</syntaxhighlight>{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, syntax, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(syntax, 0).?);
    try std.testing.expectEqual(@as(usize, 5), findTemplateOpenOutsideLiteralTags("<ref>{{visible}}</ref>", 0).?);
    try std.testing.expectEqual(@as(usize, 6), findTemplateOpenOutsideLiteralTags("<poem>{{visible}}</poem>", 0).?);
    try std.testing.expectEqual(@as(usize, 5), findTemplateOpenOutsideLiteralTags("<pre:{{visible}}>", 0).?);
}

test "nested template and parameter boundaries match MediaWiki preprocessing" {
    const template = "{{a|{{b|x={{{p|q}}}}}|z}}";
    try std.testing.expectEqual(template.len - 2, findTemplateEnd(template, 0).?);
    const parameter = "{{{x|{{y|z}}}}}";
    try std.testing.expectEqual(parameter.len - 3, findParamEnd(parameter, 0).?);
    const dynamic_template = "{{{{{name|Hello}}}|Bob}}";
    const dynamic = findNextConstructOutsideLiteralTags(dynamic_template, 0).?;
    try std.testing.expectEqual(@as(usize, 0), dynamic.open);
    try std.testing.expectEqual(ConstructKind.template, dynamic.kind);
    try std.testing.expectEqual(dynamic_template.len - 2, dynamic.close);
    const dynamic_parameter = "{{{{{safesubst:#if:{{{defparam|}}}|{{{defparam}}}|def}}|d}}}";
    const parameter_construct = findNextConstructOutsideLiteralTags(dynamic_parameter, 0).?;
    try std.testing.expectEqual(@as(usize, 0), parameter_construct.open);
    try std.testing.expectEqual(ConstructKind.parameter, parameter_construct.kind);
    try std.testing.expectEqual(dynamic_parameter.len - 3, parameter_construct.close);
    const literal_then_parameter = "{{{{name}}}}";
    const literal_construct = findNextConstructOutsideLiteralTags(literal_then_parameter, 0).?;
    try std.testing.expectEqual(@as(usize, 1), literal_construct.open);
    try std.testing.expectEqual(ConstructKind.parameter, literal_construct.kind);
    try std.testing.expectEqual(literal_then_parameter.len - 4, literal_construct.close);
    try std.testing.expectEqual(@as(usize, 2), findTopDelimiter("nm=&nbsp;{{{{{5}}}|x}}", '=').?);
    try std.testing.expect(findTopDelimiter("x=<math>a=b</math>", '=') == 1);
    try std.testing.expect(findTopDelimiter("<math>a=b</math>", '=') == null);
    const pronunciation =
        "it-pr|À*<pre:{{q|letter name}}><hmp:a>|a<pre:{{q|phonemic realization}}><rhyme:->";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(std.testing.allocator);
    try splitWikitextTop(std.testing.allocator, pronunciation, '|', &parts);
    try std.testing.expectEqual(@as(usize, 3), parts.items.len);
    try std.testing.expectEqualStrings("it-pr", parts.items[0]);
    try std.testing.expectEqualStrings("À*<pre:{{q|letter name}}><hmp:a>", parts.items[1]);
    try std.testing.expectEqualStrings("a<pre:{{q|phonemic realization}}><rhyme:->", parts.items[2]);
}

test "decoded comments and transclusion tags share one preprocessing core" {
    const a = std.testing.allocator;
    const stripped = try stripDecodedComments(a, "a<!--x-->b");
    defer a.free(stripped);
    try std.testing.expectEqualStrings("ab", stripped);
    const transcluded = try transcludeDecodedAlloc(a, "A<noinclude>X</noinclude>B<includeonly>C</includeonly>D");
    defer a.free(transcluded);
    try std.testing.expectEqualStrings("ABCD", transcluded);
    const only = try transcludeDecodedAlloc(a, "A<onlyinclude>B</onlyinclude>C");
    defer a.free(only);
    try std.testing.expectEqualStrings("B", only);
}

test "unclosed corpus noinclude tails preserve transcluded content" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        // Exact 2026-10-01 bodies: af:Sjabloon:Sub and an:Plantilla:io/ms.
        .{ .source = "<includeonly><sub>{{{1}}}</sub></includeonly><noinclude>", .expected = "<sub>{{{1}}}</sub>" },
        .{ .source = "[[ido|Ido]] <noinclude>", .expected = "[[ido|Ido]] " },
        .{ .source = "[[malayo|Malayo]]<noinclude>[[categoría:Plantillas de traducción|ms]]", .expected = "[[malayo|Malayo]]" },
        .{ .source = "<!--old--><includeonly>category</includeonly><noinclude>docs</noinclude>\n{{betekenisse}}\n#meaning\n<noinclude>", .expected = "category\n{{betekenisse}}\n#meaning\n" },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "inclusion tag boundaries attributes first close and missing ends follow MediaWiki" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "A<noinclude>B", .expected = "A" },
        .{ .source = "A<NOINCLUDE>B", .expected = "A<NOINCLUDE>B" },
        .{ .source = "A<NOINCLUDE>B</noinclude>C", .expected = "AC" },
        .{ .source = "A<noinclude>B</NOINCLUDE >C", .expected = "AC" },
        .{ .source = "A<noinclude>B</noinclude/>C", .expected = "A" },
        .{ .source = "A<noinclude>B</noinclude x>C", .expected = "A" },
        .{ .source = "A</noinclude>B", .expected = "A</noinclude>B" },
        .{ .source = "A<noinclude x=1>B</noinclude>C", .expected = "AC" },
        .{ .source = "A<noinclude/>B", .expected = "AB" },
        .{ .source = "A<NOINCLUDE />B", .expected = "AB" },
        .{ .source = "A<noinclude / >B", .expected = "A" },
        .{ .source = "A<noinclude/ >B", .expected = "A<noinclude/ >B" },
        .{ .source = "A<noinclude>B<noinclude>C</noinclude>D</noinclude>E", .expected = "AD</noinclude>E" },
        .{ .source = "A<includeonly x=1>B</includeonly x=2>C", .expected = "ABC" },
        .{ .source = "A<includeonly x=\">\">B</includeonly>C", .expected = "A\">BC" },
        .{ .source = "A<noincludeX>B</noincludeX>C", .expected = "A<noincludeX>B</noincludeX>C" },
        .{ .source = "A< includeonly>B</ includeonly>C", .expected = "A< includeonly>B</ includeonly>C" },
        .{ .source = "A<noinclude", .expected = "A<noinclude" },
        .{ .source = "A<includeonly ", .expected = "A<includeonly " },
        .{ .source = "A<noinclude <!--hidden", .expected = "A<noinclude " },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "onlyinclude uses exact raw delimiters and a flat selector" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "A<onlyinclude>B", .expected = "A<onlyinclude>B" },
        .{ .source = "A<onlyinclude/>B", .expected = "A<onlyinclude/>B" },
        .{ .source = "A<ONLYINCLUDE>B</ONLYINCLUDE>C", .expected = "A<ONLYINCLUDE>B</ONLYINCLUDE>C" },
        .{ .source = "A<onlyinclude x=1>B</onlyinclude>C", .expected = "A<onlyinclude x=1>B</onlyinclude>C" },
        .{ .source = "A<onlyinclude>B</onlyinclude >C", .expected = "A<onlyinclude>B</onlyinclude >C" },
        .{ .source = "A</onlyinclude>B<onlyinclude>C", .expected = "C" },
        .{ .source = "A<onlyinclude>B</onlyinclude>C<onlyinclude>D", .expected = "BD" },
        .{ .source = "A<onlyinclude>B<onlyinclude>C</onlyinclude>D</onlyinclude>E", .expected = "B<onlyinclude>C" },
        .{ .source = "A<!--<onlyinclude>B</onlyinclude>-->C", .expected = "B" },
        .{ .source = "A<nowiki><onlyinclude>B</onlyinclude></nowiki>C", .expected = "B" },
        .{ .source = "A<noinclude><onlyinclude>B</onlyinclude></noinclude>C", .expected = "B" },
        .{ .source = "<onlyinclude>A<!--</onlyinclude>-->B", .expected = "AB" },
        .{ .source = "<onlyinclude>A<noinclude></onlyinclude></noinclude>B", .expected = "AB" },
        .{ .source = "<onlyinclude>A<nowiki></onlyinclude></nowiki>B", .expected = "A<nowiki></onlyinclude></nowiki>B" },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "transclusion preserves first opened literal regions" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "<nowiki>A<noinclude>B</noinclude>C<!--D--></nowiki>", .expected = "<nowiki>A<noinclude>B</noinclude>C<!--D--></nowiki>" },
        .{ .source = "<ref><includeonly>A</includeonly></ref>", .expected = "<ref><includeonly>A</includeonly></ref>" },
        .{ .source = "A<noinclude>B<!--</noinclude>-->C", .expected = "A-->C" },
        .{ .source = "A<noinclude>B<nowiki></noinclude></nowiki>C", .expected = "A</nowiki>C" },
        .{ .source = "<nowiki>A<noinclude>B", .expected = "<nowiki>A" },
        .{ .source = "A<!--<noinclude>B--><includeonly>C</includeonly>", .expected = "AC" },
        .{ .source = "<nowiki/><includeonly>A</includeonly>", .expected = "<nowiki/>A" },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "grammar syntax oracle comment only line preserves list adjacency and authored blanks" {
    const a = std.testing.allocator;
    // A comment occupying its entire physical line vanishes upstream, including
    // the redundant newline; authored blank lines must still remain blank.
    const joined = try stripDecodedComments(a, "# first\n<!--hidden-->\n# second");
    defer a.free(joined);
    const blank = try stripDecodedComments(a, "# first\n\n# second");
    defer a.free(blank);
    try std.testing.expectEqualStrings("# first\n\n# second", blank);
    const inline_comment = try stripDecodedComments(a, "before<!--hidden-->after");
    defer a.free(inline_comment);
    try std.testing.expectEqualStrings("beforeafter", inline_comment);
    const protected = try stripDecodedComments(a, "<nowiki><!--hidden--></nowiki>");
    defer a.free(protected);
    try std.testing.expectEqualStrings("<nowiki><!--hidden--></nowiki>", protected);
    try std.testing.expectEqualStrings("# first\n# second", joined);
}

test "grammar syntax oracle standalone comment variants retain list adjacency" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "# first\n  <!-- hidden --> \t\n# second",
        "# first\n<!-- hidden\nmore hidden -->\n# second",
        "# first\n<!-- one -->\n<!-- two -->\n# second",
    }) |source| {
        const result = try stripDecodedComments(a, source);
        defer a.free(result);
        try std.testing.expectEqualStrings("# first\n# second", result);
    }
    const source = "# first\n<nowiki><!--hidden--></nowiki>\n# second";
    const protected = try stripDecodedComments(a, source);
    defer a.free(protected);
    try std.testing.expectEqualStrings(source, protected);
    const blanks = try stripDecodedComments(a, "# first\n\n<!--hidden-->\n\n# second");
    defer a.free(blanks);
    try std.testing.expectEqualStrings("# first\n\n\n# second", blanks);
}

test "grammar syntax oracle multiple comments on a line preserve visible content" {
    const a = std.testing.allocator;
    const standalone = try stripDecodedComments(a, "# first\n<!--one--> <!--two-->\n# second");
    defer a.free(standalone);
    try std.testing.expectEqualStrings("# first\n# second", standalone);
    const inline_comments = try stripDecodedComments(a, "before<!--one--> <!--two-->after");
    defer a.free(inline_comments);
    try std.testing.expectEqualStrings("before after", inline_comments);
    const protected = try stripDecodedComments(a, "<nowiki>first\n<!--one--></nowiki>\n<!--two-->\nafter");
    defer a.free(protected);
    try std.testing.expectEqualStrings("<nowiki>first\n<!--one--></nowiki>\nafter", protected);
}

test "protected comment boundary preserves closed pre and removes outside comments" {
    const a = std.testing.allocator;
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "outside<!--hide--><pre title='>'><!--literal-->&lt;b&gt;&amp;lt;[[B]]</pre><!--hide-->tail", .expected = "outside<pre title='>'><!--literal-->&lt;b&gt;&amp;lt;[[B]]</pre>tail" },
        .{ .source = "<PRE><!--literal--></PRE ><!--hide-->tail", .expected = "<PRE><!--literal--></PRE >tail" },
        .{ .source = "<pre/><!--hide-->tail", .expected = "<pre/>tail" },
        .{ .source = "A<pre>B<!--hidden-->&lt;i&gt;[[C]]", .expected = "A<pre>B&lt;i&gt;[[C]]" },
        .{ .source = "<nowiki><!--literal-->&lt;/nowiki&gt;</nowiki><!--hide-->tail", .expected = "<nowiki><!--literal-->&lt;/nowiki&gt;</nowiki>tail" },
    };
    for (cases) |case| {
        const actual = try stripDecodedComments(a, case.source);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "closed code extensions keep literal comments before behavior control matching" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "source", "syntaxhighlight" }) |tag| {
        const input = try std.fmt.allocPrint(a, "<{s} lang=\"text\">\n<!--__NOEDITSECTION__-->\n&#95;&#95;NOEDITSECTION&#95;&#95; {{{{T}}}}\n</{s}><!--outside-->tail", .{ tag, tag });
        defer a.free(input);
        const expected = try std.fmt.allocPrint(a, "<{s} lang=\"text\">\n<!--__NOEDITSECTION__-->\n&#95;&#95;NOEDITSECTION&#95;&#95; {{{{T}}}}\n</{s}>tail", .{ tag, tag });
        defer a.free(expected);
        const actual = try stripDecodedComments(a, input);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
        const unclosed = try std.fmt.allocPrint(a, "<{s}>A<!--ordinary-->B", .{tag});
        defer a.free(unclosed);
        const unchanged = try std.fmt.allocPrint(a, "<{s}>AB", .{tag});
        defer a.free(unchanged);
        const recovered = try stripDecodedComments(a, unclosed);
        defer a.free(recovered);
        try std.testing.expectEqualStrings(unchanged, recovered);
    }
    const joined = try stripDecodedComments(a, "__NOEDIT<!--ordinary-->SECTION__A");
    defer a.free(joined);
    try std.testing.expectEqualStrings("__NOEDITSECTION__A", joined);
}

test "nowiki preprocessing requires immediate name and first valid closer" {
    const a = std.testing.allocator;
    const unclosed = "<nowiki>A<!--hide-->{{visible}}";
    const stripped = try stripDecodedComments(a, unclosed);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("<nowiki>A{{visible}}", stripped);
    try std.testing.expect(opaqueParserRegionEnd(unclosed, 0) == null);
    try std.testing.expectEqual(@as(usize, 20), findTemplateOpenOutsideLiteralTags(unclosed, 0).?);
    const malformed_open = "< nowiki>{{visible}}</nowiki>";
    try std.testing.expect(opaqueParserRegionEnd(malformed_open, 0) == null);
    try std.testing.expectEqual(@as(usize, 9), findTemplateOpenOutsideLiteralTags(malformed_open, 0).?);
    const closed = "<NoWiKi>{{hidden}}<!--literal--></nowiki extra>{{alsohidden}}</NOWIKI \t>{{visible}}";
    const preserved = try stripDecodedComments(a, closed);
    defer a.free(preserved);
    try std.testing.expectEqualStrings(closed, preserved);
    try std.testing.expectEqual(closed.len - "{{visible}}".len, opaqueParserRegionEnd(closed, 0).?);
    try std.testing.expectEqual(closed.len - "{{visible}}".len, findTemplateOpenOutsideLiteralTags(closed, 0).?);
    try std.testing.expectEqual(@as(usize, 11), opaqueParserRegionEnd("<nowiki / >{{visible}}", 0).?);
    try std.testing.expectEqual(@as(usize, 11), findTemplateOpenOutsideLiteralTags("<nowiki / >{{visible}}", 0).?);
    // The other literal extension recovery policy is deliberately unchanged.
    try std.testing.expect(findTemplateOpenOutsideLiteralTags("<math>{{hidden}}", 0) == null);
}

test "missing nowiki closer cache retains later self-closing markers" {
    var missing = false;
    const input = "<nowiki><!--ordinary--><nowiki/><nowiki>{{visible}}";
    try std.testing.expect(nowikiRegionEndCached(input, 0, &missing) == null);
    try std.testing.expect(missing);
    try std.testing.expectEqual(@as(usize, 32), nowikiRegionEndCached(input, 23, &missing).?);
    try std.testing.expect(nowikiRegionEndCached(input, 32, &missing) == null);
    try std.testing.expectEqual(@as(usize, 40), findTemplateOpenOutsideLiteralTags(input, 0).?);
    const stripped = try stripDecodedComments(std.testing.allocator, input);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("<nowiki><nowiki/><nowiki>{{visible}}", stripped);
}
