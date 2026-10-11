//! Bounded runtime helpers for template arguments and literal/HTML boundaries.
const std = @import("std");
/// Core MediaWiki behavior switches have no visible dictionary text.
/// Match only registered canonical aliases, retaining their case rules. Never
/// call this on nowiki, opaque extension bodies, decoded entities or attributes.
pub fn behaviorSwitchEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or !starts(text[start..], "__")) return null;
    const close = std.mem.indexOfPos(u8, text, start + 2, "__") orelse return null;
    const name = text[start + 2 .. close];
    inline for (&.{ "NOTOC", "FORCETOC", "TOC", "NOEDITSECTION", "NOGALLERY", "NOCONTENTCONVERT", "NOCC", "NOTITLECONVERT", "NOTC" }) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias)) return close + 2;
    }
    inline for (&.{ "HIDDENCAT", "INDEX", "NOINDEX", "NEWSECTIONLINK", "NONEWSECTIONLINK", "STATICREDIRECT", "EXPECTUNUSEDCATEGORY", "EXPECTUNUSEDTEMPLATE", "EXPECTSHORTPAGE" }) |alias| {
        if (std.mem.eql(u8, name, alias)) return close + 2;
    }
    return null;
}

pub const ControlMatcher = struct {
    ctx: ?*const anyopaque,
    match: *const fn (?*const anyopaque, []const u8, usize) ?usize,

    pub fn end(self: ControlMatcher, text: []const u8, at: usize) ?usize {
        return self.match(self.ctx, text, at);
    }
};

/// Only an active, complete suffix after a heading delimiter is invisible.
/// Scan original bytes, retaining protected bodies, attributes and entities.
pub fn headingControlPrefix(raw: []const u8, matcher: ?ControlMatcher) []const u8 {
    const line = std.mem.trimEnd(u8, raw, " \t");
    if (line.len == 0 or line[0] != '=') return line;
    var at: usize = 0;
    while (at < line.len) {
        if (protectedEnd(line, at)) |end| {
            at = end;
            continue;
        }
        if (line[at] == '<') if (tagAt(line, at)) |tag| {
            at = tag.end;
            continue;
        };
        if (starts(line[at..], "{{") or starts(line[at..], "[[")) {
            if (balanced(line, at)) |pair| {
                at = pair.end;
                continue;
            }
            return line;
        }
        const end = if (matcher) |m| m.end(line, at) else behaviorSwitchEnd(line, at);
        if (end) |first_end| {
            const prefix = std.mem.trimEnd(u8, line[0..at], " \t");
            if (prefix.len != 0 and prefix[prefix.len - 1] == '=') {
                var cursor = first_end;
                while (cursor < line.len) {
                    if (line[cursor] == ' ' or line[cursor] == '\t') {
                        cursor += 1;
                        continue;
                    }
                    const next = if (matcher) |m| m.end(line, cursor) else behaviorSwitchEnd(line, cursor);
                    cursor = next orelse break;
                }
                if (cursor == line.len) return prefix;
            }
            at = first_end;
        } else at += 1;
    }
    return line;
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
pub fn isOpaqueTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
        "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
        "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
        "section", "inputbox", "imagemap",     "dynamicpagelist",
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
// Recover only the source-proven malformed style terminator. A genuine ASCII
// closure at an attribute boundary wins even when its quoted data contains
// typographic quotes, >, markup-looking text or line breaks.
fn recoverTypographicStyleEnd(text: []const u8, name: []const u8, attr_start: usize, quote_start: usize, end: usize, quote: u8) bool {
    if (end < 3 or quote_start == 0) return false;
    const typographic = if (quote == '"') "”" else "’";
    if (!std.mem.endsWith(u8, text[quote_start..end], typographic)) return false;
    const before_quote = std.mem.trimEnd(u8, text[attr_start .. quote_start - 1], " \t\r\n");
    if (!std.mem.endsWith(u8, before_quote, "=")) return false;
    const before_equal = std.mem.trimEnd(u8, before_quote[0 .. before_quote.len - 1], " \t\r\n");
    if (before_equal.len < 5 or !std.ascii.eqlIgnoreCase(before_equal[before_equal.len - 5 ..], "style")) return false;
    if (before_equal.len > 5 and !std.ascii.isWhitespace(before_equal[before_equal.len - 6])) return false;
    const ascii_close = std.mem.indexOfScalarPos(u8, text, end + 1, quote);
    if (ascii_close) |close| {
        if (close + 1 == text.len or std.ascii.isWhitespace(text[close + 1]) or
            text[close + 1] == '/' or text[close + 1] == '>') return false;
    }
    const limit = ascii_close orelse text.len;
    var cursor = end + 1;
    while (std.mem.indexOfPos(u8, text, cursor, "</")) |open| {
        if (open >= limit) break;
        const start = open + 2;
        if (start + name.len <= limit and std.ascii.eqlIgnoreCase(text[start .. start + name.len], name)) {
            var close = start + name.len;
            while (close < limit and std.ascii.isWhitespace(text[close])) : (close += 1) {}
            if (close < limit and text[close] == '>') return true;
        }
        cursor = start;
    }
    return false;
}

// The captured Greek Woodhouse and Marathi personal-form modules omit the
// final quote of an ordinary div attribute value. MediaWiki closes those
// values at the physical tag end. Prefer the strict tokenizer first, retaining
// valid quoted greater-than characters and multiline attributes unchanged.
pub fn tagAt(text: []const u8, start: usize) ?Tag {
    return tagAtStrict(text, start) orelse recoverUnclosedDivAttribute(text, start);
}
fn recoverUnclosedDivAttribute(text: []const u8, start: usize) ?Tag {
    if (start >= text.len or text[start] != '<') return null;
    const name_end = start + 4;
    if (name_end >= text.len or !std.ascii.eqlIgnoreCase(text[start + 1 .. name_end], "div") or
        !std.ascii.isWhitespace(text[name_end])) return null;
    const line_end = std.mem.indexOfScalarPos(u8, text, name_end, '\n') orelse text.len;
    const end = std.mem.indexOfScalarPos(u8, text, name_end, '>') orelse return null;
    if (end >= line_end) return null;
    var at = name_end;
    while (at < end) {
        while (at < end and std.ascii.isWhitespace(text[at])) : (at += 1) {}
        if (at == end) return null;
        const key_start = at;
        while (at < end and (std.ascii.isAlphanumeric(text[at]) or text[at] == '-' or text[at] == '_' or text[at] == ':')) : (at += 1) {}
        if (at == key_start) return null;
        while (at < end and std.ascii.isWhitespace(text[at])) : (at += 1) {}
        if (at == end or text[at] != '=') continue;
        at += 1;
        while (at < end and std.ascii.isWhitespace(text[at])) : (at += 1) {}
        if (at == end) return null;
        const quote = text[at];
        if (quote != '\'' and quote != '"') {
            while (at < end and !std.ascii.isWhitespace(text[at])) : (at += 1) {}
            continue;
        }
        at += 1;
        if (std.mem.indexOfScalarPos(u8, text[0..line_end], at, quote)) |close| {
            // A quote after this greater-than belongs to an authored quoted
            // value, not the concrete missing-final-quote recovery.
            if (close >= end) return null;
            at = close + 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, text[at..end], '<') != null) return null;
        return .{ .name = text[start + 1 .. name_end], .attrs = text[name_end..end],
            .end = end + 1, .closing = false, .self_closing = false };
    }
    return null;
}
fn tagAtStrict(text: []const u8, start: usize) ?Tag {
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
    var quote_start: usize = 0;
    var quote_recovery_attempted = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote != 0) {
            if (ch == quote) {
                quote = 0;
                continue;
            }
            if (ch != '>' or quote_recovery_attempted) continue;
            const typographic = if (quote == '"') "”" else "’";
            if (!std.mem.endsWith(u8, text[quote_start..i], typographic)) continue;
            // At most one suffix lookahead per quoted value; repeated literal
            // typographic delimiters in valid data cannot cause quadratic work.
            quote_recovery_attempted = true;
            if (!recoverTypographicStyleEnd(text, name, attr_start, quote_start, i, quote)) continue;
            quote = 0;
        }
        if (ch == '\'' or ch == '"') {
            // HTML tokenization tolerates a redundant quote in the attribute
            // name position after a completed quoted value. Admit only the
            // exact adjacent-quote-before-close form; unclosed values remain
            // conservative and literal.
            if (i > attr_start and text[i - 1] == ch and
                i + 1 < text.len and text[i + 1] == '>') continue;
            quote = ch;
            quote_start = i + 1;
            quote_recovery_attempted = false;
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
            if (protectedEnd(text, i)) |end| {
                i = end;
                continue;
            }
            // Attribute delimiters are HTML syntax only inside a root link frame.
            // Template and parameter braces retain their existing semantics.
            if (n == 1 and stack[0] == .link) if (tagAt(text, i)) |tag| {
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
    var i = start;
    var line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    while (i < text.len) {
        if (i >= line_end) return line_end;
        const relative = std.mem.indexOfAny(u8, text[i..line_end], "<[{") orelse return line_end;
        i += relative;
        var skip_to: ?usize = null;
        if (text[i] == '<') {
            if (protectedEnd(text, i)) |end| {
                skip_to = end;
            } else if (tagAt(text, i)) |tag| {
                skip_to = tag.end;
                if (!tag.closing and isMultilineContainerTag(tag.name)) {
                    if (matchingTag(text, tag)) |pair| skip_to = pair.end;
                }
            }
        } else if ((text[i] == '{' and starts(text[i..], "{{")) or
            (text[i] == '[' and starts(text[i..], "[[")))
        {
            if (balanced(text, i)) |pair| skip_to = pair.end;
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
    const interesting = [_]u8{ needle, '<', '{', '[' };
    var i = start;
    while (i < text.len) {
        const relative = std.mem.indexOfAny(u8, text[i..], &interesting) orelse return null;
        i += relative;
        if (text[i] == needle) return i;
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
            return null;
        }
        i += 1;
    }
    return null;
}
pub fn delimiter(text: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 1) return delimiterByte(text, needle[0], start);
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

test "behavior switches preserve unknown names and source case rules" {
    try std.testing.expectEqual(@as(?usize, 17), behaviorSwitchEnd("__NOEDITSECTION__", 0));
    try std.testing.expectEqual(@as(?usize, 9), behaviorSwitchEnd("__notoc__", 0));
    for ([_][]const u8{ "__unknown__", "__index__", "__NOEDITSECTION_", "__NOTOC extra__", "ordinary" }) |value|
        try std.testing.expectEqual(@as(?usize, null), behaviorSwitchEnd(value, 0));
}

test "redundant terminal attribute quote follows HTML recovery without unclosing values" {
    const input = "<span style=\"color:#6b5a40;\"\">tail";
    const tag = tagAt(input, 0).?;
    try std.testing.expect(tag.is("span"));
    try std.testing.expectEqualStrings("color:#6b5a40;", tag.attr("style").?);
    try std.testing.expectEqualStrings("tail", input[tag.end..]);
    try std.testing.expect(tagAt("<span title=\"unterminated>", 0) == null);
    try std.testing.expect(tagAt("<span title='unterminated>", 0) == null);
    const quoted = tagAt("<span title=\"a>b\">tail", 0).?;
    try std.testing.expectEqualStrings("a>b", quoted.attr("title").?);
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
    try std.testing.expectEqual(std.mem.indexOfScalar(u8, malformed, '\n').?, logicalEnd(malformed, 0));
}

test "malformed typographic style terminator preserves later readings without changing valid quote data" {
    const malformed = "<big style=\"color: #00008B;”>first</big>\n<big style=\"color: #00008B;”>second</big>";
    const first = tagAt(malformed, 0).?;
    try std.testing.expectEqualStrings("first</big>\n<big style=\"color: #00008B;”>second</big>", malformed[first.end..]);
    const second_start = std.mem.indexOfPos(u8, malformed, first.end, "<big").?;
    const second = tagAt(malformed, second_start).?;
    try std.testing.expectEqualStrings("second</big>", malformed[second.end..]);
    // A real closure wins despite the exact apparent recovery trigger in data.
    const valid = "<big style=\"literal ”> </big>\n still quoted\">visible</big>";
    const good = tagAt(valid, 0).?;
    try std.testing.expectEqualStrings("literal ”> </big>\n still quoted", good.attr("style").?);
    try std.testing.expectEqualStrings("visible</big>", valid[good.end..]);
    const title = "<span title=\"literal ”> </span>\">tail</span>";
    try std.testing.expectEqualStrings("literal ”> </span>", tagAt(title, 0).?.attr("title").?);
    try std.testing.expect(tagAt("<big style=\"unterminated>first</big>", 0) == null);
    try std.testing.expect(tagAt("<big style=\"color:red;”>no closing element", 0) == null);
    const repeated = "<big style=\"one ”> two ”> three ”> end\">visible</big>";
    try std.testing.expectEqualStrings("one ”> two ”> three ”> end", tagAt(repeated, 0).?.attr("style").?);
    const multiline = "<big style=\"color:\nred;\">tail</big>";
    try std.testing.expectEqualStrings("color:\nred;", tagAt(multiline, 0).?.attr("style").?);
}

test "heading control suffix keeps protected unknown and entity literals" {
    try std.testing.expectEqualStrings("=English=", headingControlPrefix("=English=__NOTOC__ __NOEDITSECTION__", null));
    for ([_][]const u8{ "=English=__UNKNOWN__", "=English=&#95;&#95;NOTOC__", "=English=<nowiki>__NOTOC__</nowiki>", "=English=<span title=\"__NOTOC__\">text</span>", "=English=__NOTOC__ tail" }) |line|
        try std.testing.expectEqualStrings(line, headingControlPrefix(line, null));
}
