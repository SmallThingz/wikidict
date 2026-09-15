//! Bounded runtime helpers for template arguments and literal/HTML boundaries.
const std = @import("std");
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
pub fn isOpaqueTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",  "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",      "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert", "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",
    }) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}
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
pub fn tagAt(text: []const u8, start: usize) ?Tag {
    if (start >= text.len or text[start] != '<') return null;
    var i = start + 1;
    const closing = i < text.len and text[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) : (i += 1) {}
    if (i == name_start or !std.ascii.isAlphabetic(text[name_start])) return null;
    const name = text[name_start..i];
    if (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != '/' and text[i] != '>') return null;
    const attr_start = i;
    var quote: u8 = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '\'' or ch == '"') {
            quote = ch;
            continue;
        }
        if (ch == '>') {
            const attrs = std.mem.trimEnd(u8, text[attr_start..i], " \t\r\n");
            const self_closing = std.mem.endsWith(u8, attrs, "/");
            return .{ .name = name, .attrs = if (self_closing) attrs[0 .. attrs.len - 1] else attrs, .end = i + 1, .closing = closing, .self_closing = self_closing };
        }
        if (ch == '<') return null;
    }
    return null;
}
fn opaquePair(text: []const u8, tag: Tag) ?Pair {
    if (tag.self_closing) return .{ .inner_end = tag.end, .end = tag.end };
    var i = tag.end;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        if (tagAt(text, open)) |next| {
            if (next.closing and std.ascii.eqlIgnoreCase(next.name, tag.name))
                return .{ .inner_end = open, .end = next.end };
            i = next.end;
        } else i = open + 1;
    }
    return null;
}
pub fn matchingTag(text: []const u8, tag: Tag) ?Pair {
    if (tag.self_closing) return .{ .inner_end = tag.end, .end = tag.end };
    // MediaWiki extension bodies are opaque: an opening tag of the same name
    // inside the body is literal text, not a nested extension.
    if (isOpaqueTag(tag.name)) return opaquePair(text, tag);
    var i = tag.end;
    var nesting: usize = 1;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        if (starts(text[open..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, text, open + 4, "-->")) |end| end + 3 else text.len;
            continue;
        }
        if (tagAt(text, open)) |next| {
            // Closing-looking text inside nowiki/ref/math/etc. cannot close the
            // surrounding ordinary HTML element.
            if (!next.closing and isOpaqueTag(next.name)) {
                const pair = opaquePair(text, next) orelse return null;
                i = pair.end;
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
    if (starts(text[start..], "<!--")) return if (std.mem.indexOfPos(u8, text, start + 4, "-->")) |end| end + 3 else text.len;
    const tag = tagAt(text, start) orelse return null;
    if (tag.closing or !isOpaqueTag(tag.name)) return null;
    return if (matchingTag(text, tag)) |pair| pair.end else text.len;
}
/// Stack-based matching prevents pipes in links/parameters from becoming template delimiters.
pub fn balanced(text: []const u8, start: usize) ?Pair {
    const Kind = enum { template, parameter, link };
    var stack: [128]Kind = undefined;
    var n: usize = 0;
    var i = start;
    while (i < text.len) {
        if (text[i] == '<') if (protectedEnd(text, i)) |end| {
            i = end;
            continue;
        };
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
    var i = start;
    while (i < text.len) {
        if (text[i] == '\n') return i;
        if (text[i] == '<') {
            if (protectedEnd(text, i)) |end| {
                i = end;
                continue;
            }
            if (tagAt(text, i)) |tag| if (!tag.closing and isMultilineContainerTag(tag.name)) {
                if (matchingTag(text, tag)) |pair| {
                    i = pair.end;
                    continue;
                }
            };
        }
        if (starts(text[i..], "{{") or starts(text[i..], "[[")) if (balanced(text, i)) |pair| {
            i = pair.end;
            continue;
        };
        i += 1;
    }
    return i;
}
pub fn delimiter(text: []const u8, needle: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len) {
        if (starts(text[i..], needle)) return i;
        if (text[i] == '<') {
            if (protectedEnd(text, i)) |end| {
                i = end;
                continue;
            }
            if (tagAt(text, i)) |tag| {
                i = tag.end;
                continue;
            }
        }
        if (starts(text[i..], "{{") or starts(text[i..], "[[")) {
            if (balanced(text, i)) |pair| {
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

test "HTML tag scanning respects quoted delimiters self-closing whitespace and malformed quotes" {
    const source = "<REF name=\"a>b\" group='g&amp;x' / >tail";
    const tag = tagAt(source, 0).?;
    try std.testing.expect(tag.is("ref"));
    try std.testing.expect(tag.self_closing);
    try std.testing.expectEqualStrings("a>b", tag.attr("name").?);
    try std.testing.expectEqualStrings("g&amp;x", tag.attr("GROUP").?);
    try std.testing.expectEqualStrings("tail", source[tag.end..]);
    try std.testing.expect(tagAt("<span title='unterminated>", 0) == null);
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
