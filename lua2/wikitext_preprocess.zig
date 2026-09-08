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

fn decodedSelfClosing(text: []const u8, start: usize, end: usize) bool {
    if (end <= start + 1) return false;
    var i = end - 2;
    while (i > start and std.ascii.isWhitespace(text[i])) : (i -= 1) {}
    return text[i] == '/';
}

pub fn stripDecodedComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (findCiPos(text, pos, "<!--")) |open| {
        try out.appendSlice(a, text[pos..open]);
        const close = findCiPos(text, open + 4, "-->") orelse {
            pos = text.len;
            break;
        };
        pos = close + 3;
    }
    try out.appendSlice(a, text[pos..]);
    return out.toOwnedSlice(a);
}

fn appendDecodedTranscludedRange(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, begin: usize, end: usize) !void {
    var pos = begin;
    while (pos < end) {
        const lt = std.mem.indexOfScalarPos(u8, text, pos, '<') orelse {
            try out.appendSlice(a, text[pos..end]);
            break;
        };
        if (lt >= end) {
            try out.appendSlice(a, text[pos..end]);
            break;
        }
        try out.appendSlice(a, text[pos..lt]);
        if (findCiPos(text, lt, "<noinclude") == lt) {
            const open_end = decodedTagEnd(text, lt) orelse return error.MalformedTransclusionTag;
            if (open_end > end) return error.MalformedTransclusionTag;
            if (decodedSelfClosing(text, lt, open_end)) {
                pos = open_end;
                continue;
            }
            const close = findCiPos(text, open_end, "</noinclude") orelse return error.MalformedTransclusionTag;
            pos = decodedTagEnd(text, close) orelse return error.MalformedTransclusionTag;
            continue;
        }
        if (findCiPos(text, lt, "</noinclude") == lt or
            findCiPos(text, lt, "<includeonly") == lt or
            findCiPos(text, lt, "</includeonly") == lt or
            findCiPos(text, lt, "<onlyinclude") == lt or
            findCiPos(text, lt, "</onlyinclude") == lt)
        {
            pos = decodedTagEnd(text, lt) orelse return error.MalformedTransclusionTag;
            continue;
        }
        try out.append(a, '<');
        pos = lt + 1;
    }
}

pub fn transcludeDecodedAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const no_comments = try stripDecodedComments(a, text);
    defer a.free(no_comments);
    var out: std.ArrayList(u8) = .empty;
    if (findCiPos(no_comments, 0, "<onlyinclude")) |_| {
        var pos: usize = 0;
        while (findCiPos(no_comments, pos, "<onlyinclude")) |open| {
            const open_end = decodedTagEnd(no_comments, open) orelse break;
            const close = findCiPos(no_comments, open_end, "</onlyinclude") orelse break;
            try appendDecodedTranscludedRange(a, &out, no_comments, open_end, close);
            pos = decodedTagEnd(no_comments, close) orelse no_comments.len;
        }
    } else try appendDecodedTranscludedRange(a, &out, no_comments, 0, no_comments.len);
    return out.toOwnedSlice(a);
}

pub fn findTemplateEnd(s: []const u8, start: usize) ?usize {
    if (start + 1 >= s.len or !std.mem.eql(u8, s[start .. start + 2], "{{")) return null;
    var stack: [128]u8 = undefined;
    var depth: usize = 1;
    stack[0] = 2;
    var i = start + 2;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 3;
            depth += 1;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 2;
            depth += 1;
            i += 2;
            continue;
        }
        if (stack[depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            depth -= 1;
            i += 3;
            continue;
        }
        if (stack[depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            depth -= 1;
            if (depth == 0) return i;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

pub fn findParamEnd(s: []const u8, start: usize) ?usize {
    if (start + 2 >= s.len or !std.mem.eql(u8, s[start .. start + 3], "{{{")) return null;
    var stack: [128]u8 = undefined;
    var depth: usize = 1;
    stack[0] = 3;
    var i = start + 3;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 3;
            depth += 1;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 2;
            depth += 1;
            i += 2;
            continue;
        }
        if (stack[depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            depth -= 1;
            if (depth == 0) return i;
            i += 3;
            continue;
        }
        if (stack[depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            depth -= 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn isOpaqueParserTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",  "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",      "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert", "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",
    }) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn rawTagEnd(s: []const u8, start: usize) ?usize {
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

fn opaqueParserRegionEnd(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '<') return null;
    if (std.mem.startsWith(u8, s[start..], "<!--")) {
        const close = std.mem.indexOfPos(u8, s, start + 4, "-->") orelse return s.len;
        return close + 3;
    }
    var p = start + 1;
    if (p >= s.len or s[p] == '/') return null;
    while (p < s.len and std.ascii.isWhitespace(s[p])) : (p += 1) {}
    const name_start = p;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) : (p += 1) {}
    if (p == name_start) return null;
    const name = s[name_start..p];
    if (!isOpaqueParserTag(name)) return null;
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
    var braces: [128]u8 = undefined;
    var brace_depth: usize = 0;
    var square: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (opaqueParserRegionEnd(s, i)) |end| {
            i = end;
            continue;
        }
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (brace_depth == braces.len) return null;
            braces[brace_depth] = 3;
            brace_depth += 1;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (brace_depth == braces.len) return null;
            braces[brace_depth] = 2;
            brace_depth += 1;
            i += 2;
            continue;
        }
        if (brace_depth != 0 and braces[brace_depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            brace_depth -= 1;
            i += 3;
            continue;
        }
        if (brace_depth != 0 and braces[brace_depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            brace_depth -= 1;
            i += 2;
            continue;
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
        if (s[i] == needle and brace_depth == 0 and square == 0) return i;
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

pub const ParameterSplit = struct { key: []const u8, default: ?[]const u8 };
pub fn splitParameter(s: []const u8) ParameterSplit {
    if (findTopDelimiter(s, '|')) |bar| return .{ .key = s[0..bar], .default = s[bar + 1 ..] };
    return .{ .key = s, .default = null };
}

test "nested template and parameter boundaries match MediaWiki preprocessing" {
    const template = "{{a|{{b|x={{{p|q}}}}}|z}}";
    try std.testing.expectEqual(template.len - 2, findTemplateEnd(template, 0).?);
    const parameter = "{{{x|{{y|z}}}}}";
    try std.testing.expectEqual(parameter.len - 3, findParamEnd(parameter, 0).?);
    try std.testing.expect(findTopDelimiter("x=<math>a=b</math>", '=') == 1);
    try std.testing.expect(findTopDelimiter("<math>a=b</math>", '=') == null);
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
