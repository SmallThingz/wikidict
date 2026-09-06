//! Bounded runtime helpers for template arguments and literal/HTML boundaries.
const std = @import("std");
pub const Pair = struct { inner_end: usize, end: usize };
pub fn starts(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}
pub fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
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
pub fn matchingTag(text: []const u8, tag: Tag) ?Pair {
    if (tag.self_closing) return .{ .inner_end = tag.end, .end = tag.end };
    var i = tag.end;
    var nesting: usize = 1;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        if (tagAt(text, open)) |next| {
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
    if (tag.closing or !(tag.is("nowiki") or tag.is("pre") or tag.is("syntaxhighlight") or tag.is("source") or tag.is("math"))) return null;
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
            if (tagAt(text, i)) |tag| if (!tag.closing and tag.is("ref")) {
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
        if (starts(text[i..], "{{") or starts(text[i..], "[[")) if (balanced(text, i)) |pair| {
            i = pair.end;
            continue;
        };
        i += 1;
    }
    return null;
}
pub const Param = struct { key: []const u8, position: usize = 0, value: []const u8 };
pub const Template = struct {
    name: []const u8,
    params: []const Param,
    pub fn parse(a: std.mem.Allocator, body: []const u8) !Template {
        const first = delimiter(body, "|", 0) orelse body.len;
        var params: std.ArrayList(Param) = .empty;
        errdefer params.deinit(a);
        var pos = @min(first + 1, body.len);
        var automatic: usize = 0;
        while (pos < body.len) {
            if (params.items.len >= 512) return error.RenderLimit;
            const end = delimiter(body, "|", pos) orelse body.len;
            const part = body[pos..end];
            if (delimiter(part, "=", 0)) |eq| {
                const key = trim(part[0..eq]);
                const position = std.fmt.parseInt(usize, key, 10) catch 0;
                if (position > 512) return error.RenderLimit;
                try params.append(a, .{ .key = key, .position = position, .value = trim(part[eq + 1 ..]) });
            } else {
                automatic += 1;
                try params.append(a, .{ .key = "", .position = automatic, .value = trim(part) });
            }
            pos = @min(end + 1, body.len);
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

test "template arguments are bounded without silently truncating supported terms" {
    const a = std.testing.allocator;
    const body = "col|en" ++ "|term" ** 300;
    const t = try Template.parse(a, body);
    defer a.free(t.params);
    try std.testing.expectEqual(@as(usize, 301), t.last());
    try std.testing.expectEqualStrings("term", t.get(301));
    try std.testing.expectError(error.RenderLimit, Template.parse(a, "col|en" ++ "|term" ** 512));
    try std.testing.expectError(error.RenderLimit, Template.parse(a, "q|999999999=oversized"));
}
