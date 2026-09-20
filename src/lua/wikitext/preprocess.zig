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
    errdefer out.deinit(a);
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
    errdefer out.deinit(a);
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

fn isOpaqueParserTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",     "dynamicpagelist",
    }) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
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

pub fn findNextConstructOutsideLiteralTags(s: []const u8, start: usize) ?Construct {
    var i = start;
    while (i + 1 < s.len) {
        if (s[i] == '<') {
            var p = i + 1;
            while (p < s.len and std.ascii.isWhitespace(s[p])) : (p += 1) {}
            const name_start = p;
            while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) : (p += 1) {}
            if (p > name_start and isTagNameBoundary(s, p) and isLiteralParserTag(s[name_start..p])) {
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
    if (!isTagNameBoundary(s, p)) return null;
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

test "template opener scan skips literal extension bodies but enters wikitext extensions" {
    const source = "a<NoWiKi class='x'>{{hidden}}</NoWiKi>b{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(source, 0).?);
    try std.testing.expect(findTemplateOpenOutsideLiteralTags("<nowiki>{{hidden}}", 0) == null);
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
