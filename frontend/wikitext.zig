//! Runtime wikitext renderer. No HTML strings are executed and no network/VM is required.
//! Reuses the portable document IR tokenizer, adding block layout, HTML, references,
//! entities, and a deliberately bounded set of Wiktionary template presentations.
const std = @import("std");
const ir = @import("blob_encoder").document_ir;
const entities = @import("html_entities");
const syntax = @import("blob_encoder").wikitext_syntax;
const templates = @import("wiki_templates.zig");
const A = std.mem.Allocator;
pub const media_types = @import("media_types.zig");
pub const Error = A.Error || error{RenderLimit};
pub const Context = struct { title: []const u8 = "Entry", language: []const u8 = "English" };
pub const Role = enum { normal, label, pronunciation, headword, example, quotation, citation, reference };
pub const Style = struct {
    kind: ir.InlineKind = .text,
    target: []const u8 = "",
    language: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    small: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    strike: bool = false,
    underline: bool = false,
    role: Role = .normal,
};
pub const Span = struct {
    kind: ir.InlineKind = .text,
    text: []const u8,
    target: []const u8 = "",
    trail: []const u8 = "",
    language: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    small: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    strike: bool = false,
    underline: bool = false,
    role: Role = .normal,
};
pub const Feature = struct { kind: []const u8, language: []const u8 = "", data: []const u8 = "", tail_kind: []const u8 = "none", tail: []const u8 = "" };
pub const Kind = enum { paragraph, blank, definition, example, quotation, list_item, list_detail, indent, term, heading, preformatted, rule, table };
pub const Cell = struct { spans: []const Span, header: bool = false, colspan: u16 = 1, rowspan: u16 = 1 };
pub const Row = struct { cells: []const Cell };
pub const Table = struct { caption: []const Span = &.{}, rows: []const Row };
pub const Block = struct {
    kind: Kind,
    depth: u8 = 0,
    text: []const u8 = "",
    spans: []const Span = &.{},
    feature: ?Feature = null,
    list_path: []const u8 = "",
    number: []const u8 = "",
    level: u8 = 0,
    table: ?Table = null,
};
pub const Reference = struct { number: usize, name: []const u8 = "", body: []const u8 = "", spans: []const Span = &.{} };
const max_nodes = 100_000;
const max_depth = 48;
fn starts(text: []const u8, prefix: []const u8) bool {
    return syntax.starts(text, prefix);
}
fn trim(text: []const u8) []const u8 {
    return syntax.trim(text);
}
fn oneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}
pub fn safeUrl(url: []const u8) bool {
    if (!(std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://"))) return false;
    for (url) |ch| if (ch <= 32 or ch == 127) return false;
    return true;
}
/// The caller uses an arena for a page; returned arrays/text share its lifetime.
pub const Renderer = struct {
    a: A,
    context: Context,
    rendered_templates: usize = 0,
    unresolved_templates: usize = 0,
    nodes: usize = 0,
    body_depth: usize = 0,
    refs: std.ArrayList(Reference) = .empty,
    media: std.ArrayList(media_types.Media) = .empty,
    media_depth: usize = 0,
    spans: std.ArrayList(Span) = .empty,
    in_reference: bool = false,

    pub fn mediaFile(self: *Renderer, raw: []const u8, caption: []const u8) Error!void {
        if (self.media_depth >= max_depth) return error.RenderLimit;
        self.media_depth += 1;
        defer self.media_depth -= 1;
        const file = try self.a.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        std.mem.replaceScalar(u8, file, '_', ' ');
        const kind = media_types.kind(file) orelse return;
        for (self.media.items) |item| if (std.mem.eql(u8, item.file, file)) return;
        if (self.media.items.len >= 128) return error.RenderLimit;
        const description = try plainText(self.a, try self.parseSpans(caption, .{}));
        try self.media.append(self.a, .{ .file = file, .kind = kind, .caption = description });
    }
    fn spend(self: *Renderer) Error!void {
        self.nodes += 1;
        if (self.nodes > max_nodes) return error.RenderLimit;
    }
    pub fn text(self: *Renderer, value: []const u8, s: Style) Error!void {
        if (value.len == 0) return;
        try self.spend();
        try self.spans.append(self.a, .{ .kind = s.kind, .text = value, .target = s.target, .language = s.language, .bold = s.bold, .italic = s.italic, .code = s.code, .small = s.small, .superscript = s.superscript, .subscript = s.subscript, .strike = s.strike, .underline = s.underline, .role = s.role });
    }
    pub fn lineBreak(self: *Renderer, s: Style) Error!void {
        var style = s;
        style.kind = .line_break;
        try self.text("\n", style);
    }
    pub fn urlEncode(self: *Renderer, value: []const u8) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.a);
        for (value) |ch| {
            if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) out.writer.writeByte(ch) catch return error.OutOfMemory else out.writer.print("%{X:0>2}", .{ch}) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
    fn plain(self: *Renderer, value: []const u8, style: Style) Error!void {
        if (std.mem.indexOfAny(u8, value, "\r\n") == null) return self.text(value, style);
        var out: std.ArrayList(u8) = .empty;
        var whitespace = false;
        for (value) |ch| {
            if (ch == '\n' or ch == '\r' or ch == '\t') {
                if (!whitespace) try out.append(self.a, ' ');
                whitespace = true;
            } else {
                try out.append(self.a, ch);
                whitespace = ch == ' ';
            }
        }
        try self.text(try out.toOwnedSlice(self.a), style);
    }
    fn entity(self: *Renderer, input: []const u8, style: Style) Error!?usize {
        const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 64)], ';') orelse return null;
        if (end < 2) return null;
        const name = input[1..end];
        if (name[0] == '#') {
            const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
            const digits = name[if (hex) @as(usize, 2) else 1..];
            const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else cp, &buf) catch return null;
            try self.text(try self.a.dupe(u8, buf[0..n]), style);
        } else if (entities.lookupNamedEntity(name)) |value| try self.text(value, style) else return null;
        return end + 1;
    }
    fn literal(self: *Renderer, input: []const u8, style: Style) Error!void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) : (i += 1) if (input[i] == '&') {
            try self.text(input[start..i], style);
            if (try self.entity(input[i..], style)) |n| {
                i += n;
                start = i;
                if (i == input.len) break;
                i -= 1;
            } else {
                try self.text("&", style);
                start = i + 1;
            }
        };
        try self.text(input[start..], style);
    }
    pub fn link(self: *Renderer, label: []const u8, target: []const u8, style: Style, depth: usize, external: bool) Error!void {
        var s = style;
        if (target.len != 0 and (!external or safeUrl(target))) {
            s.kind = if (external) .external_link else .link;
            s.target = target;
        }
        try self.inlineText(label, s, depth + 1);
    }
    fn reference(self: *Renderer, name: []const u8, body: []const u8, style: Style) Error!void {
        if (self.in_reference) {
            try self.text("[nested reference]", style);
            return;
        }
        var number: ?usize = null;
        if (name.len != 0) for (self.refs.items, 0..) |*ref, i| if (std.mem.eql(u8, ref.name, name)) {
            number = i;
            if (ref.body.len == 0) ref.body = body;
            break;
        };
        if (number == null) {
            try self.spend();
            number = self.refs.items.len;
            try self.refs.append(self.a, .{ .number = number.? + 1, .name = name, .body = body });
        }
        var s = style;
        s.superscript = true;
        s.role = .reference;
        s.kind = .link;
        s.target = try std.fmt.allocPrint(self.a, "#reference-{d}", .{number.? + 1});
        try self.text(try std.fmt.allocPrint(self.a, "[{d}]", .{number.? + 1}), s);
    }
    pub fn finishReferences(self: *Renderer) Error![]const Reference {
        self.in_reference = true;
        defer self.in_reference = false;
        for (self.refs.items) |*ref| ref.spans = try self.parseSpans(if (ref.body.len != 0) ref.body else "Reference text unavailable", .{});
        return self.refs.items;
    }
    fn htmlTag(self: *Renderer, input: []const u8, at: usize, style: Style, depth: usize) Error!?usize {
        if (starts(input[at..], "<!--")) return syntax.protectedEnd(input, at);
        const tag = syntax.tagAt(input, at) orelse return null;
        if (tag.is("templatestyles")) return tag.end;
        if (tag.is("br")) {
            try self.lineBreak(style);
            return tag.end;
        }
        if (tag.is("references")) return if (syntax.matchingTag(input, tag)) |pair| pair.end else tag.end;
        if (tag.is("ref") and !tag.closing) {
            const pair = syntax.matchingTag(input, tag) orelse return null;
            try self.reference(tag.attr("name") orelse "", if (tag.self_closing) "" else input[tag.end..pair.inner_end], style);
            return pair.end;
        }
        if (tag.is("hr")) {
            try self.lineBreak(style);
            try self.text("────────", style);
            try self.lineBreak(style);
            return tag.end;
        }
        const literal_tag = oneOf(tag.name, &.{ "nowiki", "pre", "source", "syntaxhighlight", "math" });
        if (literal_tag and !tag.closing) {
            if (tag.self_closing) return tag.end;
            const pair = syntax.matchingTag(input, tag) orelse syntax.Pair{ .inner_end = input.len, .end = input.len };
            var s = style;
            s.code = !tag.is("nowiki");
            try self.literal(input[tag.end..pair.inner_end], s);
            return pair.end;
        }
        if (oneOf(tag.name, &.{ "script", "style", "iframe", "object", "embed" })) {
            const pair = syntax.matchingTag(input, tag) orelse syntax.Pair{ .inner_end = input.len, .end = input.len };
            try self.text(try std.fmt.allocPrint(self.a, "[unsupported HTML: {s}]", .{tag.name}), style);
            return pair.end;
        }
        const known = oneOf(tag.name, &.{ "b", "strong", "i", "em", "u", "s", "del", "strike", "sup", "sub", "small", "big", "span", "font", "code", "tt", "kbd", "a", "div", "p", "blockquote", "ul", "ol", "li", "dl", "dt", "dd", "onlyinclude", "includeonly", "noinclude", "table", "tbody", "thead", "tfoot", "tr", "td", "th", "caption" });
        if (!known) return null;
        if (tag.closing or tag.self_closing) return tag.end;
        const pair = syntax.matchingTag(input, tag) orelse return tag.end;
        var s = style;
        if (oneOf(tag.name, &.{ "b", "strong" })) s.bold = true;
        if (oneOf(tag.name, &.{ "i", "em" })) s.italic = true;
        if (tag.is("u")) s.underline = true;
        if (oneOf(tag.name, &.{ "s", "del", "strike" })) s.strike = true;
        if (tag.is("sup")) s.superscript = true;
        if (tag.is("sub")) s.subscript = true;
        if (tag.is("small")) s.small = true;
        if (oneOf(tag.name, &.{ "code", "tt", "kbd" })) s.code = true;
        if (tag.attr("class")) |classes| {
            var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");
            while (tokens.next()) |class| {
                if (std.mem.eql(u8, class, "headword-line") or std.mem.eql(u8, class, "headword")) s.role = .headword;
                if (s.role != .headword and (std.mem.eql(u8, class, "label-content") or std.mem.eql(u8, class, "qualifier-content"))) s.role = .label;
                if (std.mem.eql(u8, class, "IPA")) s.role = .pronunciation;
            }
        }
        if (tag.attr("lang")) |lang| s.language = lang;
        const content = input[tag.end..pair.inner_end];
        if (tag.is("a")) {
            if (tag.attr("href")) |href| {
                // Decode entities in attributes as text, never by reparsing them as markup.
                const decoded = try self.entityText(href);
                if (safeUrl(decoded)) {
                    s.kind = .external_link;
                    s.target = decoded;
                }
            }
        }
        if (tag.is("li")) try self.text("• ", style);
        try self.inlineText(content, s, depth + 1);
        if (oneOf(tag.name, &.{ "p", "div", "blockquote", "li", "dt", "dd", "tr" })) try self.lineBreak(style);
        return pair.end;
    }
    fn entityText(self: *Renderer, value: []const u8) Error![]const u8 {
        const old = self.spans;
        self.spans = .empty;
        defer self.spans = old;
        try self.literal(value, .{});
        var out: std.ArrayList(u8) = .empty;
        for (self.spans.items) |s| try out.appendSlice(self.a, s.text);
        return try out.toOwnedSlice(self.a);
    }
    pub fn inlineText(self: *Renderer, input: []const u8, inherited: Style, depth: usize) Error!void {
        if (depth > max_depth) {
            try self.text("[render nesting limit]", inherited);
            return;
        }
        var it: ir.InlineIterator = .{ .input = input, .bold = inherited.bold, .italic = inherited.italic };
        while (it.cursor < input.len) {
            var s = inherited;
            s.bold = it.bold;
            s.italic = it.italic;
            if (input[it.cursor] == '<') if (try self.htmlTag(input, it.cursor, s, depth)) |end| {
                it.cursor = end;
                continue;
            };
            if (input[it.cursor] == '&') if (try self.entity(input[it.cursor..], s)) |n| {
                it.cursor += n;
                continue;
            };
            if (starts(input[it.cursor..], "{{")) {
                const pair = syntax.balanced(input, it.cursor) orelse {
                    try self.plain(input[it.cursor..], s);
                    break;
                };
                const offset: usize = if (starts(input[it.cursor..], "{{{")) 3 else 2;
                const body = input[it.cursor + offset .. pair.inner_end];
                if (offset == 3) {
                    if (syntax.delimiter(body, "|", 0)) |pipe| try self.inlineText(body[pipe + 1 ..], s, depth + 1) else try self.text("[missing parameter]", s);
                } else {
                    try self.resolveTemplate(body, s, depth);
                }
                it.cursor = pair.end;
                continue;
            }
            const before = it.cursor;
            const token = it.next() orelse break;
            s.bold = token.bold;
            s.italic = token.italic;
            switch (token.kind) {
                .text => {
                    if (std.mem.indexOfAny(u8, token.text, "<&")) |at| {
                        const start = @intFromPtr(token.text.ptr) - @intFromPtr(input.ptr);
                        it.cursor = start + at;
                        if (at != 0) {
                            try self.plain(token.text[0..at], s);
                            continue;
                        }
                        try self.text(token.text[0..1], s);
                        it.cursor += 1;
                    } else try self.plain(token.text, s);
                },
                .line_break => try self.lineBreak(s),
                .link => {
                    const open = std.mem.indexOfPos(u8, input, before, "[[") orelse before;
                    const pair = syntax.balanced(input, open);
                    const inside = if (pair) |found| input[open + 2 .. found.inner_end] else "";
                    const pipe = syntax.delimiter(inside, "|", 0);
                    var target = if (pair != null) trim(inside[0 .. pipe orelse inside.len]) else token.target;
                    var label_value = if (pair != null and pipe != null) inside[pipe.? + 1 ..] else if (pair != null) target else token.text;
                    var trail = token.trail;
                    if (pair) |found| {
                        var end = found.end;
                        while (end < input.len and std.ascii.isAlphabetic(input[end])) : (end += 1) {}
                        trail = input[found.end..end];
                        it.cursor = end;
                    }
                    const explicit = starts(target, ":");
                    if (explicit) target = target[1..];
                    if (!explicit and std.ascii.startsWithIgnoreCase(target, "Category:")) continue;
                    if (!explicit and (std.ascii.startsWithIgnoreCase(target, "File:") or std.ascii.startsWithIgnoreCase(target, "Image:"))) {
                        var start: usize = 0;
                        while (syntax.delimiter(label_value, "|", start)) |n| start = n + 1;
                        label_value = label_value[start..];
                        const file_name = target[(std.mem.indexOfScalar(u8, target, ':').? + 1)..];
                        var width_option = std.mem.endsWith(u8, label_value, "px");
                        if (width_option) for (label_value[0 .. label_value.len - 2]) |ch| if (!std.ascii.isDigit(ch) and ch != 'x') {
                            width_option = false;
                            break;
                        };
                        if (width_option or oneOf(label_value, &.{ "noicon", "thumb", "thumbnail", "frameless", "frame" })) label_value = file_name;
                        try self.mediaFile(file_name, label_value);
                        try self.text(if (media_types.kind(file_name) == .audio) "[Audio: " else "[Image: ", s);
                        try self.inlineText(label_value, s, depth + 1);
                        try self.text("]", s);
                    } else {
                        if (label_value.len == 0) {
                            label_value = target;
                            if (std.mem.indexOfScalar(u8, label_value, ':')) |colon| label_value = label_value[colon + 1 ..];
                            if (std.mem.indexOf(u8, label_value, " (")) |paren| label_value = label_value[0..paren];
                        }
                        try self.link(label_value, target, s, depth + 1, false);
                    }
                    try self.text(trail, s);
                },
                .external_link => try self.link(token.text, token.target, s, depth + 1, true),
                .template => try self.resolveTemplate(token.text, s, depth),
            }
        }
    }
    fn resolveTemplate(self: *Renderer, body: []const u8, style: Style, depth: usize) Error!void {
        const t = try syntax.Template.parse(self.a, body);
        const start = self.spans.items.len;
        if (try templates.render(self, t, style, depth + 1)) {
            self.rendered_templates += 1;
            // Preserve the whole headword line as a semantic unit, separate from media/context.
            if (oneOf(t.name, &.{ "head", "en-noun", "en-proper noun", "en-verb", "en-adj", "en-adv" })) {
                for (self.spans.items[start..]) |*span| span.role = .headword;
            }
        } else {
            self.unresolved_templates += 1;
            // A named passage is actual supplied content even when its citation
            // template cannot run. Keep that template unresolved and inspectable.
            const passage = t.named("passage");
            if (std.ascii.startsWithIgnoreCase(t.name, "RQ:") and passage.len != 0) {
                var quotation = style;
                quotation.role = .quotation;
                try self.inlineText(passage, quotation, depth + 1);
                if (t.named("translation").len != 0) {
                    try self.lineBreak(style);
                    try self.inlineText(t.named("translation"), style, depth + 1);
                }
                try self.lineBreak(style);
                try self.text("Unexpanded source citation: ", .{ .small = true, .role = .citation });
            }
            var missing = style;
            missing.kind = .template;
            missing.target = t.name;
            try self.text(body, missing);
        }
    }
    pub fn parseSpans(self: *Renderer, input: []const u8, style: Style) Error![]const Span {
        const parent = self.spans;
        self.spans = .empty;
        defer self.spans = parent;
        try self.inlineText(input, style, 0);
        return try self.spans.toOwnedSlice(self.a);
    }
    fn block(self: *Renderer, list: *std.ArrayList(Block), kind: Kind, raw: []const u8, path: []const u8, number: []const u8, level: u8) Error!void {
        const spans = if (kind == .preformatted) blk: {
            const parent = self.spans;
            self.spans = .empty;
            defer self.spans = parent;
            try self.literal(raw, .{ .code = true });
            break :blk try self.spans.toOwnedSlice(self.a);
        } else try self.parseSpans(raw, .{});
        if (spans.len == 0 and kind != .heading and kind != .blank and kind != .rule) return;
        try self.spend();
        try list.append(self.a, .{ .kind = kind, .text = raw, .spans = spans, .depth = @intCast(@min(path.len, 255)), .list_path = path[0..@min(path.len, 255)], .number = number, .level = level });
    }
    fn paragraph(self: *Renderer, list: *std.ArrayList(Block), text_value: []const u8) Error!void {
        if (trim(text_value).len == 0) return;
        var kind: Kind = .paragraph;
        const value = trim(text_value);
        if (starts(value, "{{")) if (syntax.balanced(value, 0)) |pair| {
            const t = try syntax.Template.parse(self.a, value[2..pair.inner_end]);
            if (oneOf(t.name, &.{ "ux", "uxi", "uxa", "usex", "co", "coi", "coa" })) kind = .example;
            if (starts(t.name, "quote-")) kind = .quotation;
        };
        try self.block(list, kind, value, "", "", 0);
    }
    pub fn renderBody(self: *Renderer, input: []const u8) Error![]const Block {
        if (self.body_depth >= max_depth) return error.RenderLimit;
        self.body_depth += 1;
        defer self.body_depth -= 1;
        var blocks: std.ArrayList(Block) = .empty;
        var pos: usize = 0;
        var para: ?usize = null;
        var counts: [32]usize = @splat(0);
        while (pos < input.len) {
            const start = pos;
            const end = syntax.logicalEnd(input, pos);
            const line = std.mem.trimEnd(u8, input[start..end], "\r");
            pos = if (end < input.len) end + 1 else end;
            const clean = trim(line);
            const heading = headingLine(clean);
            var multiline_data: ?[]const u8 = null;
            if (starts(clean, "{{multitrans|")) if (syntax.balanced(clean, 0)) |pair| {
                if (pair.end == clean.len) {
                    const t = try syntax.Template.parse(self.a, clean[2..pair.inner_end]);
                    multiline_data = t.named("data");
                }
            };
            var prefix: usize = 0;
            while (prefix < line.len and std.mem.indexOfScalar(u8, "#*:;", line[prefix]) != null) : (prefix += 1) {}
            const html_tag = if (syntax.tagAt(clean, 0)) |tag| (if (!tag.closing and (tag.is("table") or tag.is("div")) and syntax.matchingTag(clean, tag) != null) tag else null) else null;
            const special = html_tag != null or multiline_data != null or clean.len == 0 or heading != null or prefix != 0 or starts(line, " ") or starts(clean, "{|") or starts(clean, "----") or starts(clean, "<pre") or starts(clean, "<syntaxhighlight");
            if (!special) {
                if (para == null) para = start;
                continue;
            }
            if (para) |p| {
                try self.paragraph(&blocks, input[p..start]);
                para = null;
            }
            if (html_tag) |tag| {
                const pair = syntax.matchingTag(clean, tag).?;
                if (tag.is("table")) {
                    if (try self.htmlTable(clean[tag.end..pair.inner_end])) |table_value| {
                        try self.spend();
                        try blocks.append(self.a, .{ .kind = .table, .table = table_value });
                    } else try self.block(&blocks, .preformatted, clean[0..pair.end], "", "", 0);
                } else try blocks.appendSlice(self.a, try self.renderBody(clean[tag.end..pair.inner_end]));
                pos = @intFromPtr(clean.ptr) - @intFromPtr(input.ptr) + pair.end;
                if (pos < input.len and input[pos] == '\n') pos += 1;
                continue;
            }
            if (multiline_data) |data| {
                self.rendered_templates += 1;
                try blocks.appendSlice(self.a, try self.renderBody(data));
                continue;
            }
            if (clean.len == 0) {
                @memset(&counts, 0);
                continue;
            }
            if (heading) |h| {
                try self.block(&blocks, .heading, h.title, "", "", h.level);
                @memset(&counts, 0);
                continue;
            }
            if (starts(clean, "----")) {
                try self.block(&blocks, .rule, "", "", "", 0);
                continue;
            }
            if (starts(clean, "{|")) {
                const table = try self.parseTable(input, pos);
                pos = table.end;
                if (table.closed and table.table.rows.len != 0) try blocks.append(self.a, .{ .kind = .table, .table = table.table }) else try self.block(&blocks, .preformatted, input[start..pos], "", "", 0);
                continue;
            }
            if (starts(clean, "<pre") or starts(clean, "<syntaxhighlight")) {
                if (syntax.tagAt(clean, 0)) |tag| {
                    const pair = syntax.matchingTag(clean, tag) orelse syntax.Pair{ .inner_end = clean.len, .end = clean.len };
                    try self.block(&blocks, .preformatted, clean[tag.end..pair.inner_end], "", "", 0);
                    continue;
                }
            }
            if (starts(line, " ")) {
                try self.block(&blocks, .preformatted, line[1..], "", "", 0);
                continue;
            }
            if (prefix != 0) {
                const path = line[0..prefix];
                const last = path[path.len - 1];
                const kind: Kind = if (path[0] == '#' and std.mem.indexOfScalar(u8, path, '*') != null) .quotation else if (last == '#') .definition else if (last == '*') .list_item else if (last == ';') .term else if (path[0] == '#') .example else .indent;
                var number: []const u8 = "";
                if (last == '#' and prefix <= counts.len) {
                    counts[prefix - 1] += 1;
                    @memset(counts[prefix..], 0);
                    var out: std.Io.Writer.Allocating = .init(self.a);
                    for (path, 0..) |mark, i| if (mark == '#') {
                        if (out.written().len != 0) out.writer.writeByte('.') catch return error.OutOfMemory;
                        out.writer.print("{d}", .{@max(counts[i], 1)}) catch return error.OutOfMemory;
                    };
                    number = try out.toOwnedSlice();
                }
                try self.block(&blocks, kind, std.mem.trimStart(u8, line[prefix..], " \t"), path, number, 0);
            }
        }
        if (para) |p| try self.paragraph(&blocks, input[p..]);
        return try blocks.toOwnedSlice(self.a);
    }
    fn htmlTable(self: *Renderer, input: []const u8) Error!?Table {
        var rows: std.ArrayList(Row) = .empty;
        var caption: []const Span = &.{};
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, input, pos, '<')) |open| {
            const tag = syntax.tagAt(input, open) orelse {
                pos = open + 1;
                continue;
            };
            pos = tag.end;
            if (tag.closing or !(tag.is("tr") or tag.is("caption"))) continue;
            const pair = syntax.matchingTag(input, tag) orelse return null;
            pos = pair.end;
            if (tag.is("caption")) {
                caption = try self.parseSpans(input[tag.end..pair.inner_end], .{});
                continue;
            }
            var cells: std.ArrayList(Cell) = .empty;
            var at = tag.end;
            while (std.mem.indexOfScalarPos(u8, input[0..pair.inner_end], at, '<')) |cell_open| {
                const cell_tag = syntax.tagAt(input, cell_open) orelse {
                    at = cell_open + 1;
                    continue;
                };
                at = cell_tag.end;
                if (cell_tag.closing or !(cell_tag.is("td") or cell_tag.is("th"))) continue;
                const cell_pair = syntax.matchingTag(input[0..pair.inner_end], cell_tag) orelse return null;
                at = cell_pair.end;
                try self.spend();
                try cells.append(self.a, .{ .spans = try self.parseSpans(input[cell_tag.end..cell_pair.inner_end], .{}), .header = cell_tag.is("th"), .colspan = @max(1, @min(100, std.fmt.parseInt(u16, cell_tag.attr("colspan") orelse "1", 10) catch 1)), .rowspan = @max(1, @min(100, std.fmt.parseInt(u16, cell_tag.attr("rowspan") orelse "1", 10) catch 1)) });
            }
            if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
        }
        return .{ .caption = caption, .rows = try rows.toOwnedSlice(self.a) };
    }
    const TableResult = struct { table: Table, end: usize, closed: bool };
    fn parseTable(self: *Renderer, input: []const u8, start: usize) Error!TableResult {
        var rows: std.ArrayList(Row) = .empty;
        var cells: std.ArrayList(Cell) = .empty;
        var cell_source: std.ArrayList(u8) = .empty;
        var current: ?Cell = null;
        var caption: []const Span = &.{};
        var pos = start;
        var closed = false;
        while (pos < input.len) {
            const end = syntax.logicalEnd(input, pos);
            const line = trim(input[pos..end]);
            pos = if (end < input.len) end + 1 else end;
            if (starts(line, "|}") or starts(line, "|-")) {
                try self.finishCell(&cells, &cell_source, &current);
                if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
                if (starts(line, "|}")) {
                    closed = true;
                    break;
                }
            } else if (starts(line, "|+")) {
                caption = try self.parseSpans(cellContent(line[2..]).text, .{});
            } else if (line.len != 0 and (line[0] == '!' or line[0] == '|')) {
                const header = line[0] == '!';
                const separator = if (header) "!!" else "||";
                var offset: usize = 1;
                while (offset <= line.len) {
                    try self.finishCell(&cells, &cell_source, &current);
                    const split_at = syntax.delimiter(line, separator, offset) orelse line.len;
                    const content = cellContent(line[offset..split_at]);
                    current = .{ .spans = &.{}, .header = header, .colspan = content.colspan, .rowspan = content.rowspan };
                    try cell_source.appendSlice(self.a, content.text);
                    if (split_at == line.len) break;
                    offset = split_at + 2;
                }
            } else if (current != null) {
                if (cell_source.items.len != 0) try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, line);
            }
        }
        try self.finishCell(&cells, &cell_source, &current);
        if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
        return .{ .table = .{ .caption = caption, .rows = try rows.toOwnedSlice(self.a) }, .end = pos, .closed = closed };
    }
    fn finishCell(self: *Renderer, cells: *std.ArrayList(Cell), source: *std.ArrayList(u8), current: *?Cell) Error!void {
        if (current.*) |value| {
            try self.spend();
            var cell = value;
            cell.spans = try self.parseSpans(source.items, .{});
            try cells.append(self.a, cell);
            source.* = .empty;
            current.* = null;
        }
    }
};
const Heading = struct { level: u8, title: []const u8 };
fn headingLine(line: []const u8) ?Heading {
    var left: usize = 0;
    while (left < line.len and line[left] == '=') : (left += 1) {}
    if (left == 0 or left > 6) return null;
    var right = line.len;
    while (right > left and line[right - 1] == '=') : (right -= 1) {}
    if (line.len - right < left or trim(line[left..right]).len == 0) return null;
    return .{ .level = @intCast(left), .title = trim(line[left .. line.len - left]) };
}
const CellContent = struct { text: []const u8, colspan: u16 = 1, rowspan: u16 = 1 };
fn cellContent(raw: []const u8) CellContent {
    if (syntax.delimiter(raw, "|", 0)) |pipe| if (std.mem.indexOfScalar(u8, raw[0..pipe], '=') != null) {
        const tag: syntax.Tag = .{ .name = "td", .attrs = raw[0..pipe], .end = 0, .closing = false, .self_closing = false };
        return .{ .text = trim(raw[pipe + 1 ..]), .colspan = @max(1, @min(100, std.fmt.parseInt(u16, tag.attr("colspan") orelse "1", 10) catch 1)), .rowspan = @max(1, @min(100, std.fmt.parseInt(u16, tag.attr("rowspan") orelse "1", 10) catch 1)) };
    };
    return .{ .text = trim(raw) };
}

fn flattened(a: A, spans: []const Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (spans) |s| try out.appendSlice(a, s.text);
    return out.toOwnedSlice(a);
}
test "renderer resolves Wiktionary definitions links labels and multiline quotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{ .title = "cat activation noise" } };
    const blocks = try r.renderBody("{{en-noun}}\n\n#{{lb|en|Internet slang|humorous}} The '''[[trill]]''' sound.\n\n{{quote-text|en|year=2018|title=Why do cats trill?\n|passage=The {{m|en|cat}} makes a noise.}}\n");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
    try std.testing.expectEqualStrings("1", blocks[1].number);
    try std.testing.expectEqualStrings("(Internet slang, humorous) The trill sound.", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.quotation, blocks[2].kind);
    try std.testing.expectEqualStrings("The cat makes a noise.\nWhy do cats trill?, 2018\n", try flattened(a, blocks[2].spans));
    try std.testing.expectEqual(@as(usize, 4), r.rendered_templates);
    try std.testing.expectEqual(@as(usize, 0), r.unresolved_templates);
}
test "renderer protects nowiki decodes entities once and never executes source HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<!--gone--><nowiki>'''[[literal]]''' &amp;</nowiki> &lt;b&gt; <b>bold <i>both</i></b> <a href='javascript:alert(1)'>safe</a>", .{});
    try std.testing.expectEqualStrings("'''[[literal]]''' & <b> bold both safe", try flattened(a, spans));
    var both = false;
    for (spans) |s| {
        try std.testing.expect(!starts(s.target, "javascript:"));
        if (std.mem.eql(u8, s.text, "both")) both = s.bold and s.italic;
    }
    try std.testing.expect(both);
    try std.testing.expect(!safeUrl("https://x\ninvalid"));
}
test "renderer groups wiki tables and ordered nested lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("# one\n## sub\n## next\n# two\n\n{| class=wikitable\n|+ Forms\n! Singular !! Plural\n|-\n| [[cat]] || {{l|en|cats}}\n|}\n");
    try std.testing.expectEqualStrings("1.1", blocks[1].number);
    try std.testing.expectEqualStrings("1.2", blocks[2].number);
    try std.testing.expectEqualStrings("2", blocks[3].number);
    const t = blocks[4].table.?;
    try std.testing.expectEqual(@as(usize, 2), t.rows.len);
    try std.testing.expect(t.rows[0].cells[0].header);
    try std.testing.expectEqualStrings("cats", try flattened(a, t.rows[1].cells[1].spans));
}
test "renderer preserves named forward references and unknown templates explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("A<ref name='x'/> B<ref name=x>Author, ''Book''.</ref> {{custom|do not lose me}}", .{});
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("Author, Book.", try flattened(a, refs[0].spans));
    try std.testing.expectEqual(@as(usize, 1), r.unresolved_templates);
    try std.testing.expectEqual(ir.InlineKind.template, spans[spans.len - 1].kind);
    try std.testing.expectEqualStrings("custom|do not lose me", spans[spans.len - 1].text);
}
fn allocationCase(a: A) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    _ = try r.renderBody("# {{lb|en|rare}} [[cat]] &eacute;<ref>''Book''</ref>\n\n{|\n! A !! B\n|-\n| 1 || {{l|fr|chat}}\n|}\n");
    _ = try r.finishReferences();
}
test "renderer propagates allocation failures with complete page cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

pub fn plainText(a: A, spans: []const Span) A.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (spans) |span| {
        if (span.kind == .template) {
            try out.appendSlice(a, "[unavailable template: ");
            try out.appendSlice(a, span.target);
            try out.append(a, ']');
        } else if (span.kind == .line_break) try out.append(a, '\n') else try out.appendSlice(a, span.text);
        try out.appendSlice(a, span.trail);
    }
    return out.toOwnedSlice(a);
}

test "emphasis template boundaries and nested image captions render without raw wiki delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("'''{{m|en|cat}}''' [[File:Cat.jpg|thumb|A [[domestic cat]]]] {{syn|en|kitty<q:rare>}}", .{});
    try std.testing.expectEqualStrings("cat [Image: A domestic cat] Synonyms: kitty (rare)", try flattened(a, spans));
    try std.testing.expect(spans[0].bold);
}
test "multitrans produces real blocks and malformed tables retain literal content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{{multitrans|data=\n{{trans-top|animal}}\n* French: {{t|fr|chat|m}}\n{{trans-bottom}}\n}}\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("French: chat m", try flattened(a, blocks[1].spans));
    const bad = try r.renderBody("{|\nimportant text without a cell or closing marker");
    try std.testing.expectEqual(Kind.preformatted, bad[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, bad[0].text, "important text") != null);
}
test "bounded malformed wikitext stress never traps and preserves allocator ownership" {
    const alphabet = "{}[]=|*#\n\r<>/ abcXYZ0123456789_:-'\"&;!";
    var state: u64 = 0x41df_ea37_1234;
    var bytes: [512]u8 = undefined;
    for (0..4000) |_| {
        state = state *% 6364136223846793005 +% 1;
        const len: usize = @intCast(state % bytes.len);
        for (bytes[0..len]) |*byte| {
            state = state *% 6364136223846793005 +% 1;
            byte.* = alphabet[@intCast(state % alphabet.len)];
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
        _ = try r.renderBody(bytes[0..len]);
        _ = try r.finishReferences();
    }
}

test "compiled template HTML tables retain cells and supplied inflections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<div><table class=inflection>\n<caption>Forms</caption><tbody><tr><th>Singular</th><th>Plural</th></tr>\n<tr><td>mouse</td><td><b>mice</b></td></tr></tbody></table></div>\n# After table\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    const t = blocks[0].table.?;
    try std.testing.expectEqualStrings("Forms", try flattened(a, t.caption));
    try std.testing.expectEqualStrings("mice", try flattened(a, t.rows[1].cells[1].spans));
    try std.testing.expect(t.rows[1].cells[1].spans[0].bold);
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
}

test "malformed generated tables retain source rather than abort rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const blocks = try r.renderBody("<table><tr><td>valuable content</tr></table>");
    try std.testing.expectEqual(Kind.preformatted, blocks[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text, "valuable content") != null);
}

test "anagrams render only supplied terms with language and preserve unsupported options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("{{anagrams|en|a=acst|acts|cast|scat}}", .{});
    try std.testing.expectEqualStrings("acts, cast, scat", try flattened(a, spans));
    try std.testing.expectEqual(@as(usize, 1), r.rendered_templates);
    try std.testing.expectEqual(@as(usize, 0), r.unresolved_templates);
    var links: usize = 0;
    for (spans) |s| if (s.kind == .link) {
        links += 1;
        try std.testing.expectEqualStrings("en", s.language);
    };
    try std.testing.expectEqual(@as(usize, 3), links);
    const unknown = try r.parseSpans("{{anagrams|en|acts|unknown=something}}", .{});
    try std.testing.expectEqual(ir.InlineKind.template, unknown[0].kind);
    try std.testing.expectEqual(@as(usize, 1), r.unresolved_templates);
}
test "supplied RQ passage is visible without claiming its citation template was expanded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("{{RQ:Unknown Work|page=17|passage=The '''[[cat]]''' sleeps.|translation=Le chat dort.}}", .{});
    const text = try flattened(a, spans);
    try std.testing.expect(std.mem.startsWith(u8, text, "The cat sleeps.\nLe chat dort.\nUnexpanded source citation: "));
    try std.testing.expectEqual(@as(usize, 1), r.unresolved_templates);
    try std.testing.expectEqual(@as(usize, 0), r.rendered_templates);
    try std.testing.expectEqual(ir.InlineKind.template, spans[spans.len - 1].kind);
    try std.testing.expect(std.mem.indexOf(u8, spans[spans.len - 1].text, "page=17") != null);
    var bold_link = false;
    for (spans) |s| if (s.kind == .link and s.bold and std.mem.eql(u8, s.target, "cat")) {
        bold_link = true;
    };
    try std.testing.expect(bold_link);
}

test "explicit positional anagrams do not turn language or ordering keys into words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("{{anagrams|1=en|2=acts|4=cast|a=acst}}", .{});
    try std.testing.expectEqualStrings("acts, cast", try flattened(a, spans));
    try std.testing.expectEqual(@as(usize, 0), r.unresolved_templates);
}

test "generated audio layout is rendered and media stays typed rather than emitted as HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<templatestyles src='audio/styles.css'/><table><tr><td>Audio</td><td>[[File:Voice.ogg|noicon|175px]]</td></tr></table> [[File:Cat.jpg|thumb|A [[cat]]]]", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "table") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "templatestyles") == null);
    try std.testing.expectEqual(@as(usize, 2), r.media.items.len);
    try std.testing.expectEqual(media_types.Kind.audio, r.media.items[0].kind);
    try std.testing.expectEqualStrings("A cat", r.media.items[1].caption);
}

test "audio layout width is not mistaken for its caption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    _ = try r.parseSpans("[[File:En-us-cat.ogg|noicon|175px]]", .{});
    try std.testing.expectEqualStrings("En-us-cat.ogg", r.media.items[0].caption);
}
