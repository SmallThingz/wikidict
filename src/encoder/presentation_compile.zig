//! Build-time wikitext presentation compiler. No HTML strings are executed and no network is required.
//! Reuses the portable document IR tokenizer, adding block layout, HTML, references,
//! entities, and a deliberately bounded set of Wiktionary template presentations.
const std = @import("std");
const ir = @import("blob_encoder").document_ir;
const entities = @import("shared_xml_decode").html_entities;
const syntax = @import("blob_encoder").wikitext_syntax;
const templates = @import("presentation_templates.zig");
const A = std.mem.Allocator;

fn optionalTableEnd(input: []const u8, opening: syntax.Tag) syntax.Pair {
    var cursor = opening.end;
    while (std.mem.indexOfScalarPos(u8, input, cursor, '<')) |at| {
        const tag = syntax.tagAt(input, at) orelse {
            cursor = at + 1;
            continue;
        };
        cursor = tag.end;
        if (!tag.closing and tag.is("table")) {
            if (syntax.matchingTag(input, tag)) |pair| {
                cursor = pair.end;
                continue;
            }
        }
        if (tag.closing and tag.is(opening.name)) return .{ .inner_end = at, .end = tag.end };
        const sibling = !tag.closing and (if (opening.is("tr")) tag.is("tr") else tag.is("td") or tag.is("th") or tag.is("tr"));
        const parent = tag.closing and (tag.is("table") or tag.is("tbody") or tag.is("thead") or tag.is("tfoot") or (!opening.is("tr") and tag.is("tr")));
        if (sibling or parent) return .{ .inner_end = at, .end = at };
    }
    return .{ .inner_end = input.len, .end = input.len };
}
pub const media_types = @import("presentation_media.zig");
pub const Error = A.Error || error{RenderLimit};
pub const Context = struct {
    title: []const u8 = "Entry",
    language: []const u8 = "English",
    link_trail: ir.LinkTrail = .{},
};
pub const Role = enum { normal, label, pronunciation, headword, example, quotation, citation, reference };
pub const Style = struct {
    kind: ir.InlineKind = .text,
    target: []const u8 = "",
    language: []const u8 = "",
    classes: []const u8 = "",
    direction: []const u8 = "",
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
pub const SpanFlags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    small: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    strike: bool = false,
    underline: bool = false,
};
pub const Span = struct {
    kind: ir.InlineKind = .text,
    text: []const u8,
    target: []const u8 = "",
    language: []const u8 = "",
    classes: []const u8 = "",
    direction: []const u8 = "",
    flags: SpanFlags = .{},
    role: Role = .normal,
};
pub const Feature = struct { kind: []const u8, language: []const u8 = "", data: []const u8 = "", tail_kind: []const u8 = "none", tail: []const u8 = "" };
const SemanticHints = struct { relation_note: bool = false };
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
    // Build-only hint captured while rendering; it is not serialized into DPR2.
    relation_note: bool = false,
};
pub const Reference = struct { number: usize, group_number: usize, name: []const u8 = "", group: []const u8 = "", body: []const u8 = "", spans: []const Span = &.{} };
const ReferenceDefinition = struct { name: []const u8, group: []const u8 = "", body: []const u8 = "" };
const max_nodes = 100_000;
const max_depth = 48;
fn starts(text: []const u8, prefix: []const u8) bool {
    return syntax.starts(text, prefix);
}
fn trim(text: []const u8) []const u8 {
    return syntax.trim(text);
}
fn listRoot(mark: u8) u8 {
    return if (mark == ';' or mark == ':') ';' else mark;
}
pub fn inlineDefinitionSplit(text: []const u8) ?struct { term: []const u8, definition: []const u8 } {
    const colon = syntax.delimiter(text, ":", 0) orelse return null;
    const term = std.mem.trim(u8, text[0..colon], " \t");
    const definition = std.mem.trim(u8, text[colon + 1 ..], " \t");
    if (term.len == 0 or definition.len == 0) return null;
    return .{ .term = term, .definition = definition };
}
fn oneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

fn adoptionFormattingTag(name: []const u8) bool {
    return oneOf(name, &.{ "b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u" });
}

fn normalizableHtmlTag(name: []const u8) bool {
    return oneOf(name, &.{
        "b",    "strong", "i",    "em",   "u",    "s",   "del",        "strike", "ins",  "sup",  "sub",  "small",
        "big",  "span",   "font", "code", "tt",   "kbd", "samp",       "var",    "cite", "dfn",  "abbr", "q",
        "time", "mark",   "bdi",  "bdo",  "ruby", "rb",  "rt",         "rtc",    "rp",   "data", "h1",   "h2",
        "h3",   "h4",     "h5",   "h6",   "div",  "p",   "blockquote", "center", "ul",   "ol",   "li",   "dl",
        "dt",   "dd",
    });
}

const HtmlNormalizationFrame = struct {
    name: []const u8,
    opener: []const u8,
    formatting: bool,
};

const max_html_normalization_frames = max_depth * 4;

fn hasMisnestedHtml(input: []const u8) bool {
    if (std.mem.indexOfScalar(u8, input, '<') == null) return false;
    var frames: [max_html_normalization_frames]HtmlNormalizationFrame = undefined;
    var frame_count: usize = 0;
    var pos: usize = 0;

    while (std.mem.indexOfScalarPos(u8, input, pos, '<')) |at| {
        if (syntax.protectedEnd(input, at)) |end| {
            pos = end;
            continue;
        }
        const tag = syntax.tagAt(input, at) orelse {
            pos = at + 1;
            continue;
        };
        pos = tag.end;
        if (!normalizableHtmlTag(tag.name) or tag.self_closing) continue;
        if (!tag.closing) {
            if (frame_count == frames.len) return false;
            frames[frame_count] = .{
                .name = tag.name,
                .opener = input[at..tag.end],
                .formatting = adoptionFormattingTag(tag.name),
            };
            frame_count += 1;
            continue;
        }

        var match: ?usize = null;
        var index = frame_count;
        while (index != 0) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(frames[index].name, tag.name)) {
                match = index;
                break;
            }
        }
        const frame_index = match orelse continue;
        if (frame_index + 1 != frame_count) return true;
        frame_count = frame_index;
    }
    return false;
}

fn normalizeMisnestedHtml(a: A, input: []const u8) Error![]const u8 {
    if (!hasMisnestedHtml(input)) return input;

    var out: std.ArrayList(u8) = .empty;
    var frames: [max_html_normalization_frames]HtmlNormalizationFrame = undefined;
    var frame_count: usize = 0;
    var pos: usize = 0;

    while (std.mem.indexOfScalarPos(u8, input, pos, '<')) |at| {
        try out.appendSlice(a, input[pos..at]);

        if (syntax.protectedEnd(input, at)) |end| {
            try out.appendSlice(a, input[at..end]);
            pos = end;
            continue;
        }

        const tag = syntax.tagAt(input, at) orelse {
            try out.append(a, '<');
            pos = at + 1;
            continue;
        };
        const raw = input[at..tag.end];
        if (!normalizableHtmlTag(tag.name) or tag.self_closing) {
            try out.appendSlice(a, raw);
            pos = tag.end;
            continue;
        }

        if (!tag.closing) {
            try out.appendSlice(a, raw);
            if (frame_count == frames.len) return input;
            frames[frame_count] = .{
                .name = tag.name,
                .opener = raw,
                .formatting = adoptionFormattingTag(tag.name),
            };
            frame_count += 1;
            pos = tag.end;
            continue;
        }

        var match: ?usize = null;
        var index = frame_count;
        while (index != 0) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(frames[index].name, tag.name)) {
                match = index;
                break;
            }
        }
        const frame_index = match orelse {
            try out.appendSlice(a, raw);
            pos = tag.end;
            continue;
        };
        if (frame_index + 1 == frame_count) {
            try out.appendSlice(a, raw);
            frame_count = frame_index;
            pos = tag.end;
            continue;
        }

        const above = frames[frame_index + 1 .. frame_count];
        var close_index = above.len;
        while (close_index != 0) {
            close_index -= 1;
            try out.appendSlice(a, "</");
            try out.appendSlice(a, above[close_index].name);
            try out.append(a, '>');
        }
        try out.appendSlice(a, raw);

        var retained: [max_html_normalization_frames]HtmlNormalizationFrame = undefined;
        var retained_len: usize = 0;
        for (above) |frame| if (frame.formatting) {
            retained[retained_len] = frame;
            retained_len += 1;
        };
        frame_count = frame_index;
        for (retained[0..retained_len]) |frame| {
            try out.appendSlice(a, frame.opener);
            frames[frame_count] = frame;
            frame_count += 1;
        }
        pos = tag.end;
    }
    try out.appendSlice(a, input[pos..]);
    return out.toOwnedSlice(a);
}
inline fn referenceStringEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    if (a.len < 4) {
        const middle = a.len / 2;
        return ((a[0] ^ b[0]) | (a[a.len - 1] ^ b[b.len - 1]) | (a[middle] ^ b[middle])) == 0;
    }
    if (a.len <= 8) {
        return std.mem.readInt(u32, a[0..4], .little) == std.mem.readInt(u32, b[0..4], .little) and
            std.mem.readInt(u32, a[a.len - 4 ..][0..4], .little) == std.mem.readInt(u32, b[b.len - 4 ..][0..4], .little);
    }
    if (a.len <= 16) {
        return std.mem.readInt(u64, a[0..8], .little) == std.mem.readInt(u64, b[0..8], .little) and
            std.mem.readInt(u64, a[a.len - 8 ..][0..8], .little) == std.mem.readInt(u64, b[b.len - 8 ..][0..8], .little);
    }
    return std.mem.eql(u8, a, b);
}

fn pipeTrickLabel(target: []const u8) []const u8 {
    // MediaWiki's pre-save pipe trick is intentionally syntactic: the first
    // colon prefix is removed even when it is not a registered namespace. It
    // does not apply to section/anchor links.
    if (std.mem.indexOfScalar(u8, target, '#') != null) return target;
    var label = target;
    if (std.mem.indexOfScalar(u8, label, ':')) |colon| label = std.mem.trimStart(u8, label[colon + 1 ..], " \t");
    if (label.len != 0 and label[label.len - 1] == ')') {
        if (std.mem.lastIndexOf(u8, label, " (")) |paren| label = label[0..paren];
    } else if (std.mem.indexOf(u8, label, ", ")) |comma| {
        label = label[0..comma];
    }
    return label;
}

pub fn safeUrl(url: []const u8) bool {
    if (!ir.validExternalUrl(url)) return false;
    for (url) |ch| if (ch <= 32 or ch == 127) return false;
    return true;
}

const MagicLinkKind = enum { rfc, pmid, isbn };
const MagicLink = struct {
    kind: MagicLinkKind,
    end: usize,
    text: []const u8,
    payload: []const u8,
};

fn magicSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn magicLinkAt(input: []const u8, start: usize) ?MagicLink {
    if (!ir.linkBoundaryBefore(input, start)) return null;
    const Prefix = struct { kind: MagicLinkKind, len: usize };
    const prefix: Prefix = if (std.mem.startsWith(u8, input[start..], "RFC"))
        .{ .kind = .rfc, .len = 3 }
    else if (std.mem.startsWith(u8, input[start..], "PMID"))
        .{ .kind = .pmid, .len = 4 }
    else if (std.mem.startsWith(u8, input[start..], "ISBN"))
        .{ .kind = .isbn, .len = 4 }
    else
        return null;

    const kind = prefix.kind;
    var pos = start + prefix.len;
    if (pos >= input.len or !magicSpace(input[pos])) return null;
    while (pos < input.len and magicSpace(input[pos])) : (pos += 1) {}
    const payload_start = pos;

    if (kind == .rfc or kind == .pmid) {
        while (pos < input.len and std.ascii.isDigit(input[pos])) : (pos += 1) {}
        if (pos == payload_start or !ir.linkBoundaryAfter(input, pos)) return null;
        return .{ .kind = kind, .end = pos, .text = input[start..pos], .payload = input[payload_start..pos] };
    }

    while (pos < input.len) : (pos += 1) {
        const ch = input[pos];
        if (!std.ascii.isDigit(ch) and ch != 'X' and ch != 'x' and ch != '-' and !magicSpace(ch)) break;
    }
    var end = pos;
    while (end > payload_start and (input[end - 1] == '-' or magicSpace(input[end - 1]))) : (end -= 1) {}
    if (end == payload_start or !ir.linkBoundaryAfter(input, end)) return null;

    var normalized: [13]u8 = undefined;
    var count: usize = 0;
    for (input[payload_start..end]) |ch| {
        if (ch == '-' or magicSpace(ch)) continue;
        if (count == normalized.len) return null;
        normalized[count] = if (ch == 'x') 'X' else ch;
        count += 1;
    }
    const valid_ten = count == 10 and blk: {
        for (normalized[0..9]) |ch| if (!std.ascii.isDigit(ch)) break :blk false;
        break :blk std.ascii.isDigit(normalized[9]) or normalized[9] == 'X';
    };
    const valid_thirteen = count == 13 and
        (std.mem.eql(u8, normalized[0..3], "978") or std.mem.eql(u8, normalized[0..3], "979")) and blk: {
        for (normalized[3..12]) |ch| if (!std.ascii.isDigit(ch)) break :blk false;
        break :blk std.ascii.isDigit(normalized[12]) or normalized[12] == 'X';
    };
    if (!valid_ten and !valid_thirteen) return null;
    return .{ .kind = .isbn, .end = end, .text = input[start..end], .payload = input[payload_start..end] };
}

fn magicLinkStart(input: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < input.len) {
        const relative = std.mem.indexOfAny(u8, input[pos..], "RPI") orelse return null;
        pos += relative;
        if (magicLinkAt(input, pos) != null) return pos;
        pos += 1;
    }
    return null;
}
fn safeInternalTarget(target: []const u8) bool {
    var has_non_ascii = false;
    for (target) |ch| {
        if (ch < 32 or ch == 127) return false;
        has_non_ascii = has_non_ascii or ch >= 128;
    }
    if (!has_non_ascii) return true;
    if (!std.unicode.utf8ValidateSlice(target)) return false;
    var view = std.unicode.Utf8View.initUnchecked(target);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (cp >= 0x80 and cp <= 0x9f) return false;
    return true;
}
test "safe internal target ASCII fast path preserves Unicode and control checks" {
    try std.testing.expect(safeInternalTarget("cat#section"));
    try std.testing.expect(safeInternalTarget("caf\xc3\xa9"));
    try std.testing.expect(safeInternalTarget("cat \xf0\x9f\x90\x88"));
    try std.testing.expect(!safeInternalTarget("cat\x7f"));
    try std.testing.expect(!safeInternalTarget("cat\xc2\x85"));
    try std.testing.expect(!safeInternalTarget("cat\xff"));
}

/// The caller uses an arena for a page; returned arrays/text share its lifetime.
pub const Renderer = struct {
    fallbacks: @import("presentation_fallback.zig").Report = .{},
    a: A,
    context: Context,
    rendered_templates: usize = 0,
    unresolved_templates: usize = 0,
    nodes: usize = 0,
    truncated: bool = false,
    span_limit_marker: bool = false,
    block_limit_reached: bool = false,
    body_depth: usize = 0,
    refs: std.ArrayList(Reference) = .empty,
    ref_defs: std.ArrayList(ReferenceDefinition) = .empty,
    default_group_reference_count: usize = 0,
    media: std.ArrayList(media_types.Media) = .empty,
    media_depth: usize = 0,
    spans: std.ArrayList(Span) = .empty,
    in_reference: bool = false,
    semantic_capture: ?*SemanticHints = null,

    pub fn mediaFile(self: *Renderer, raw: []const u8, caption: []const u8) Error!void {
        // Media is supplemental presentation. Pathological nesting or a page with
        // hundreds of assets must not make the entry itself unreadable.
        if (self.media_depth >= max_depth) {
            self.fallbacks.render_limit = true;
            return;
        }
        self.media_depth += 1;
        defer self.media_depth -= 1;
        const file = try self.a.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        std.mem.replaceScalar(u8, file, '_', ' ');
        const kind = media_types.kind(file) orelse return;
        for (self.media.items) |item| if (std.mem.eql(u8, item.file, file)) return;
        if (self.media.items.len >= 128) {
            self.fallbacks.render_limit = true;
            return;
        }
        const description = try plainText(self.a, try self.parseSpans(caption, .{}));
        try self.media.append(self.a, .{ .file = file, .kind = kind, .caption = description });
    }
    fn spend(self: *Renderer) bool {
        if (self.nodes >= max_nodes) {
            self.fallbacks.render_limit = true;
            self.truncated = true;
            return false;
        }
        self.nodes += 1;
        return true;
    }
    pub inline fn text(self: *Renderer, value: []const u8, s: Style) Error!void {
        if (value.len == 0) return;
        if (!self.spend()) {
            if (!self.span_limit_marker) {
                self.span_limit_marker = true;
                try self.spans.append(self.a, .{ .kind = .text, .text = "[render output truncated]", .role = .normal });
            }
            return;
        }
        try self.spans.append(self.a, .{ .kind = s.kind, .text = value, .target = s.target, .language = s.language, .classes = s.classes, .direction = s.direction, .flags = .{ .bold = s.bold, .italic = s.italic, .code = s.code, .small = s.small, .superscript = s.superscript, .subscript = s.subscript, .strike = s.strike, .underline = s.underline }, .role = s.role });
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
    fn renderMagicLink(self: *Renderer, link_value: MagicLink, style: Style) Error!void {
        var link_style = style;
        switch (link_value.kind) {
            .rfc => {
                link_style.kind = .external_link;
                link_style.target = try std.fmt.allocPrint(self.a, "https://datatracker.ietf.org/doc/html/rfc{s}", .{link_value.payload});
            },
            .pmid => {
                link_style.kind = .external_link;
                link_style.target = try std.fmt.allocPrint(self.a, "//www.ncbi.nlm.nih.gov/pubmed/{s}?dopt=Abstract", .{link_value.payload});
            },
            .isbn => {
                var normalized: std.ArrayList(u8) = .empty;
                for (link_value.payload) |ch| {
                    if (ch == '-' or magicSpace(ch)) continue;
                    try normalized.append(self.a, if (ch == 'x') 'X' else ch);
                }
                link_style.kind = .link;
                link_style.target = try std.fmt.allocPrint(self.a, "Special:BookSources/{s}", .{normalized.items});
            },
        }
        try self.plain(link_value.text, link_style);
    }
    fn plainWithMagicLinks(self: *Renderer, value: []const u8, style: Style) Error!void {
        if (style.kind == .link or style.kind == .external_link) return self.plain(value, style);
        var pos: usize = 0;
        while (magicLinkStart(value, pos)) |start| {
            const link_value = magicLinkAt(value, start).?;
            try self.plain(value[pos..start], style);
            try self.renderMagicLink(link_value, style);
            pos = link_value.end;
        }
        try self.plain(value[pos..], style);
    }
    const DecodedEntity = struct { bytes: []const u8, consumed: usize, scratch: bool = false };

    fn decodeEntity(input: []const u8, buf: *[4]u8) ?DecodedEntity {
        const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 64)], ';') orelse return null;
        if (end < 2) return null;
        const name = input[1..end];
        if (name[0] == '#') {
            const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
            const digits = name[if (hex) @as(usize, 2) else 1..];
            const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
            const n = std.unicode.utf8Encode(if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else cp, buf) catch return null;
            return .{ .bytes = buf[0..n], .consumed = end + 1, .scratch = true };
        }
        const value = entities.lookupNamedEntity(name) orelse return null;
        return .{ .bytes = value, .consumed = end + 1 };
    }
    fn entity(self: *Renderer, input: []const u8, style: Style) Error!?usize {
        var buf: [4]u8 = undefined;
        const decoded = decodeEntity(input, &buf) orelse return null;
        try self.text(if (decoded.scratch) try self.a.dupe(u8, decoded.bytes) else decoded.bytes, style);
        return decoded.consumed;
    }
    fn literal(self: *Renderer, input: []const u8, style: Style) Error!void {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, input, start, '&')) |i| {
            try self.text(input[start..i], style);
            if (try self.entity(input[i..], style)) |n| {
                start = i + n;
            } else {
                try self.text("&", style);
                start = i + 1;
            }
        }
        try self.text(input[start..], style);
    }
    pub fn link(self: *Renderer, label: []const u8, target: []const u8, style: Style, depth: usize, external: bool) Error!void {
        var s = style;
        const resolved_target = if (external) try self.entityText(target) else target;
        if (resolved_target.len != 0 and (!external or safeUrl(resolved_target))) {
            s.kind = if (external) .external_link else .link;
            s.target = resolved_target;
        }
        if (external and std.mem.eql(u8, label, target)) {
            try self.text(try self.entityText(label), s);
            return;
        }
        try self.inlineText(label, s, depth + 1);
    }
    fn referenceIndex(self: *Renderer, name: []const u8, group: []const u8, body: []const u8) Error!?usize {
        const use_short_name_compare = self.refs.items.len >= 16;
        if (name.len != 0) for (self.refs.items, 0..) |*ref, i| {
            const same_name = if (use_short_name_compare) referenceStringEqual(ref.name, name) else std.mem.eql(u8, ref.name, name);
            if (!same_name or !std.mem.eql(u8, ref.group, group)) continue;
            if (ref.body.len == 0 and body.len != 0) ref.body = body;
            return i;
        };
        var resolved_body = body;
        if (name.len != 0 and resolved_body.len == 0) for (self.ref_defs.items) |definition| {
            if (std.mem.eql(u8, definition.name, name) and std.mem.eql(u8, definition.group, group)) {
                resolved_body = definition.body;
                break;
            }
        };
        if (!self.spend()) return null;
        const index = self.refs.items.len;
        var group_number: usize = 1;
        if (group.len == 0) {
            self.default_group_reference_count += 1;
            group_number = self.default_group_reference_count;
        } else {
            for (self.refs.items) |ref| {
                if (std.mem.eql(u8, ref.group, group)) group_number += 1;
            }
        }
        try self.refs.append(self.a, .{ .number = index + 1, .group_number = group_number, .name = name, .group = group, .body = resolved_body });
        return index;
    }
    fn reference(self: *Renderer, name: []const u8, group: []const u8, body: []const u8, style: Style) Error!void {
        if (self.in_reference) {
            try self.text("[nested reference]", style);
            return;
        }
        const index = (try self.referenceIndex(name, group, body)) orelse {
            try self.text("[render output truncated]", style);
            return;
        };
        const ref = self.refs.items[index];
        var s = style;
        s.superscript = true;
        s.role = .reference;
        s.kind = .link;
        s.target = try std.fmt.allocPrint(self.a, "#reference-{d}", .{ref.number});
        const marker = if (group.len == 0)
            try std.fmt.allocPrint(self.a, "[{d}]", .{ref.group_number})
        else
            try std.fmt.allocPrint(self.a, "[{s} {d}]", .{ group, ref.group_number });
        try self.text(marker, s);
    }
    fn referenceDefinitions(self: *Renderer, content: []const u8, default_group: []const u8) Error!void {
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, content, pos, '<')) |open| {
            if (starts(content[open..], "<!--")) {
                pos = syntax.protectedEnd(content, open) orelse content.len;
                continue;
            }
            const tag = syntax.tagAt(content, open) orelse {
                pos = open + 1;
                continue;
            };
            pos = tag.end;
            if (!tag.closing and syntax.isOpaqueTag(tag.name) and !tag.is("ref")) {
                pos = if (syntax.matchingTag(content, tag)) |pair| pair.end else content.len;
                continue;
            }
            if (tag.closing or !tag.is("ref")) continue;
            const pair = syntax.matchingTag(content, tag) orelse continue;
            const name = try self.entityText(tag.attr("name") orelse "");
            if (name.len == 0) {
                pos = pair.end;
                continue;
            }
            const own_group = try self.entityText(tag.attr("group") orelse "");
            const group = if (own_group.len != 0) own_group else default_group;
            const body = if (tag.self_closing) "" else content[tag.end..pair.inner_end];
            var found = false;
            for (self.ref_defs.items) |*definition| {
                if (!std.mem.eql(u8, definition.name, name) or !std.mem.eql(u8, definition.group, group)) continue;
                if (definition.body.len == 0 and body.len != 0) definition.body = body;
                found = true;
                break;
            }
            if (!found) try self.ref_defs.append(self.a, .{ .name = name, .group = group, .body = body });
            for (self.refs.items) |*ref| {
                if (std.mem.eql(u8, ref.name, name) and std.mem.eql(u8, ref.group, group) and ref.body.len == 0 and body.len != 0) ref.body = body;
            }
            pos = pair.end;
        }
    }
    pub fn finishReferences(self: *Renderer) Error![]const Reference {
        self.in_reference = true;
        defer self.in_reference = false;
        for (self.refs.items) |*ref| ref.spans = try self.parseSpans(if (ref.body.len != 0) ref.body else "Reference text unavailable", .{});
        return self.refs.items;
    }
    fn inlineLines(self: *Renderer, input: []const u8, style: Style, depth: usize) Error!void {
        var lines = std.mem.splitScalar(u8, input, '\n');
        var first_line = true;
        while (lines.next()) |line| {
            if (!first_line) try self.lineBreak(style);
            first_line = false;
            try self.inlineText(std.mem.trimEnd(u8, line, "\r"), style, depth + 1);
        }
    }
    fn gallery(self: *Renderer, input: []const u8, style: Style, _: usize) Error!void {
        var lines = std.mem.splitScalar(u8, input, '\n');
        var emitted = false;
        while (lines.next()) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0) continue;
            const pipe = syntax.delimiter(line, "|", 0);
            const raw_file = trim(line[0 .. pipe orelse line.len]);
            const colon = std.mem.indexOfScalar(u8, raw_file, ':');
            const file = if (colon != null and (std.ascii.eqlIgnoreCase(raw_file[0..colon.?], "File") or std.ascii.eqlIgnoreCase(raw_file[0..colon.?], "Image"))) raw_file[colon.? + 1 ..] else raw_file;
            if (media_types.kind(file) == null) continue;
            const options = if (pipe) |at_pipe| trim(line[at_pipe + 1 ..]) else "";
            const caption = mediaCaption(options, file);
            try self.mediaFile(file, caption);
            if (emitted) try self.lineBreak(style);
            emitted = true;
            var media_style = style;
            media_style.classes = "wikidict-media";
            media_style.kind = .link;
            media_style.target = try std.fmt.allocPrint(self.a, "File:{s}", .{file});
            try self.text(try plainText(self.a, try self.parseSpans(if (caption.len == 0) file else caption, .{})), media_style);
        }
    }
    fn opaqueExtension(self: *Renderer, input: []const u8, tag: syntax.Tag, style: Style, depth: usize) Error!usize {
        if (tag.self_closing) return tag.end;
        const pair = syntax.matchingTag(input, tag) orelse blk: {
            self.fallbacks.unclosed_formatting = true;
            break :blk syntax.Pair{ .inner_end = input.len, .end = input.len };
        };
        const content = input[tag.end..pair.inner_end];
        if (tag.is("gallery")) {
            try self.gallery(content, style, depth + 1);
        } else if (tag.is("poem")) {
            try self.inlineLines(content, style, depth + 1);
        } else if (oneOf(tag.name, &.{ "pre", "source", "syntaxhighlight", "math", "ce", "chem", "score", "timeline", "hiero" })) {
            var literal_style = style;
            literal_style.code = true;
            try self.literal(content, literal_style);
        } else if (!oneOf(tag.name, &.{ "indicator", "references", "templatestyles", "section", "charinsert" })) {
            // Registered extensions can render data-backed UI that this data-only
            // compiler cannot reproduce. Do not invent substitute prose; report
            // the omission so the final corpus audit names the affected page.
            self.fallbacks.unsupported_element = true;
        }
        return pair.end;
    }
    fn mediaOption(value: []const u8) bool {
        const option = trim(value);
        if (option.len == 0) return true;
        if (oneOf(option, &.{ "thumb", "thumbnail", "frame", "frameless", "border", "left", "right", "center", "none", "baseline", "sub", "super", "top", "text-top", "middle", "bottom", "text-bottom", "noicon", "muted", "loop", "autoplay", "disablecontrols" })) return true;
        inline for (&.{ "alt=", "link=", "lang=", "page=", "class=", "upright=", "thumbtime=", "start=", "end=", "manualthumb=" }) |prefix| if (std.ascii.startsWithIgnoreCase(option, prefix)) return true;
        if (std.ascii.eqlIgnoreCase(option, "upright")) return true;
        if (std.mem.endsWith(u8, option, "px")) {
            const size = option[0 .. option.len - 2];
            if (size.len != 0) {
                var valid = true;
                for (size) |ch| if (!std.ascii.isDigit(ch) and ch != 'x') {
                    valid = false;
                    break;
                };
                if (valid) return true;
            }
        }
        return false;
    }
    fn mediaCaption(raw: []const u8, fallback: []const u8) []const u8 {
        var candidate: []const u8 = "";
        var pos: usize = 0;
        while (pos <= raw.len) {
            const end = syntax.delimiter(raw, "|", pos) orelse raw.len;
            const part = trim(raw[pos..end]);
            if (!mediaOption(part)) candidate = part;
            if (end == raw.len) break;
            pos = end + 1;
        }
        return if (candidate.len == 0) fallback else candidate;
    }
    fn htmlTag(self: *Renderer, input: []const u8, at: usize, style: Style, depth: usize) Error!?usize {
        if (starts(input[at..], "<!--")) return syntax.protectedEnd(input, at);
        const tag = syntax.tagAt(input, at) orelse return null;
        if (tag.is("br")) {
            if (!tag.closing) try self.lineBreak(style);
            return tag.end;
        }
        if (tag.is("wbr")) return tag.end;
        if ((tag.is("meta") or tag.is("link")) and !tag.closing) {
            if (tag.attr("itemprop") == null) return null;
            if (tag.is("meta")) {
                if (tag.attr("content") == null) return null;
            } else {
                _ = tag.attr("href") orelse return null;
            }
            return tag.end;
        }
        if (tag.is("includeonly") and !tag.closing) {
            if (tag.self_closing) return tag.end;
            const pair = syntax.matchingTag(input, tag) orelse return input.len;
            return pair.end;
        }
        if (oneOf(tag.name, &.{ "tr", "td", "th", "caption" })) {
            if (tag.closing or tag.self_closing) return tag.end;
            const pair = syntax.matchingTag(input, tag) orelse syntax.Pair{ .inner_end = input.len, .end = input.len };
            try self.inlineText(input[tag.end..pair.inner_end], style, depth + 1);
            return pair.end;
        }
        if (tag.is("ref") and !tag.closing) {
            const pair = syntax.matchingTag(input, tag) orelse {
                try self.literal(input[tag.end..], style);
                return input.len;
            };
            const name = try self.entityText(tag.attr("name") orelse "");
            const group = try self.entityText(tag.attr("group") orelse "");
            try self.reference(name, group, if (tag.self_closing) "" else input[tag.end..pair.inner_end], style);
            return pair.end;
        }
        if (tag.is("references") and !tag.closing) {
            if (tag.self_closing) return tag.end;
            const pair = syntax.matchingTag(input, tag) orelse {
                try self.literal(input[tag.end..], style);
                return input.len;
            };
            const group = try self.entityText(tag.attr("group") orelse "");
            try self.referenceDefinitions(input[tag.end..pair.inner_end], group);
            return pair.end;
        }
        if (tag.name.len == "small".len and tag.attrs.len == 0 and tag.is("small")) {
            if (tag.closing or tag.self_closing) return tag.end;
            const pair = syntax.matchingTag(input, tag) orelse blk: {
                self.fallbacks.unclosed_formatting = true;
                break :blk syntax.Pair{ .inner_end = input.len, .end = input.len };
            };
            var s = style;
            s.small = true;
            try self.inlineText(input[tag.end..pair.inner_end], s, depth + 1);
            return pair.end;
        }
        if (syntax.isOpaqueTag(tag.name) and !tag.closing and !tag.is("nowiki")) return try self.opaqueExtension(input, tag, style, depth);
        if (tag.is("hr")) {
            if (!tag.closing) {
                try self.lineBreak(style);
                try self.text("────────", style);
                try self.lineBreak(style);
            }
            return tag.end;
        }
        const literal_tag = tag.is("nowiki");
        if (literal_tag and !tag.closing) {
            if (tag.self_closing) return tag.end;
            const pair = syntax.matchingTag(input, tag) orelse blk: {
                self.fallbacks.unclosed_formatting = true;
                break :blk syntax.Pair{ .inner_end = input.len, .end = input.len };
            };
            var s = style;
            s.code = !tag.is("nowiki");
            try self.literal(input[tag.end..pair.inner_end], s);
            return pair.end;
        }
        if (oneOf(tag.name, &.{ "script", "style", "iframe", "object", "embed" })) {
            self.fallbacks.unsupported_element = true;
            if (tag.closing) {
                try self.literal(input[at..tag.end], style);
                return tag.end;
            }
            // MediaWiki escapes these disallowed HTML elements as literal text.
            // Preserve the exact visible source instead of fabricating a marker.
            if (tag.self_closing) {
                try self.literal(input[at..tag.end], style);
                return tag.end;
            }
            if (syntax.matchingTag(input, tag)) |pair| {
                try self.literal(input[at..pair.end], style);
                return pair.end;
            }
            self.fallbacks.unclosed_formatting = true;
            try self.literal(input[at..], style);
            return input.len;
        }
        const known = oneOf(tag.name, &.{
            "b",         "strong", "i",    "em", "u",          "s",      "del", "strike", "ins", "sup",  "sub", "small", "big",
            "span",      "font",   "code", "tt", "kbd",        "samp",   "var", "cite",   "dfn", "abbr", "q",   "time",  "mark",
            "bdi",       "bdo",    "ruby", "rb", "rt",         "rtc",    "rp",  "data",   "wbr", "h1",   "h2",  "h3",    "h4",
            "h5",        "h6",     "div",  "p",  "blockquote", "center", "ul",  "ol",     "li",  "dl",   "dt",  "dd",    "onlyinclude",
            "noinclude", "table",
        });
        if (!known) return null;
        if (tag.closing or tag.self_closing) return tag.end;
        // Wiktionary's senseid emits an intentionally unclosed li inside a
        // wikitext list item. The block parser already owns that item's extent.
        // Consume the marker, not its contents: those still contain wiki links
        // and semantic HTML that must pass through the inline compiler.
        if (tag.is("li") and syntax.matchingTag(input, tag) == null) return tag.end;
        const matched = syntax.matchingTag(input, tag);
        if (matched == null) self.fallbacks.unclosed_formatting = true;
        // Unclosed layout containers have no inline style to scope. Consume
        // them iteratively, including long runs of malformed openers.
        if (matched == null and oneOf(tag.name, &.{ "div", "span", "p", "center", "ul", "ol", "dl" })) return tag.end;
        const pair = matched orelse syntax.Pair{ .inner_end = input.len, .end = input.len };
        var s = style;
        if (oneOf(tag.name, &.{ "b", "strong" })) s.bold = true;
        if (oneOf(tag.name, &.{ "i", "em", "cite", "var", "dfn" })) s.italic = true;
        if (tag.is("u") or tag.is("ins")) s.underline = true;
        if (oneOf(tag.name, &.{ "s", "del", "strike" })) s.strike = true;
        if (tag.is("sup")) s.superscript = true;
        if (tag.is("sub")) s.subscript = true;
        if (tag.is("small")) s.small = true;
        if (oneOf(tag.name, &.{ "code", "tt", "kbd", "samp" })) s.code = true;
        if (tag.attr("class")) |classes| {
            const decoded_classes = try self.entityText(classes);
            var safe_classes: std.ArrayList(u8) = .empty;
            defer safe_classes.deinit(self.a);
            var tokens = std.mem.tokenizeAny(u8, decoded_classes, " \t\r\n");
            while (tokens.next()) |class| {
                var safe = class.len != 0;
                for (class) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) {
                    safe = false;
                    break;
                };
                if (!safe) continue;
                if (safe_classes.items.len != 0) try safe_classes.append(self.a, ' ');
                try safe_classes.appendSlice(self.a, class);
                if (std.mem.eql(u8, class, "headword-line") or std.mem.eql(u8, class, "headword")) s.role = .headword;
                if (s.role != .headword and (std.mem.eql(u8, class, "label-content") or std.mem.eql(u8, class, "qualifier-content"))) s.role = .label;
                if (std.mem.eql(u8, class, "IPA")) s.role = .pronunciation;
                if (std.mem.eql(u8, class, "nyms")) {
                    if (self.semantic_capture) |hints| hints.relation_note = true;
                }
            }
            if (safe_classes.items.len != 0) {
                s.classes = if (s.classes.len == 0)
                    try self.a.dupe(u8, safe_classes.items)
                else
                    try std.fmt.allocPrint(self.a, "{s} {s}", .{ s.classes, safe_classes.items });
            }
        }
        if (tag.attr("lang")) |lang| s.language = try self.entityText(lang);
        if (tag.attr("dir")) |dir| {
            const decoded_dir = try self.entityText(dir);
            if (std.ascii.eqlIgnoreCase(decoded_dir, "ltr")) s.direction = "ltr" else if (std.ascii.eqlIgnoreCase(decoded_dir, "rtl")) s.direction = "rtl" else if (std.ascii.eqlIgnoreCase(decoded_dir, "auto")) s.direction = "auto";
        }
        const content = input[tag.end..pair.inner_end];
        if (tag.is("li")) try self.text("• ", style);
        if (std.mem.indexOf(u8, content, "{|") != null) {
            try self.blocksInline(try self.renderBody(content), s);
        } else try self.inlineText(content, s, depth + 1);
        if (oneOf(tag.name, &.{ "p", "div", "blockquote", "center", "li", "dt", "dd", "tr", "h1", "h2", "h3", "h4", "h5", "h6" })) try self.lineBreak(style);
        return pair.end;
    }
    fn entityText(self: *Renderer, value: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, value, '&') == null) return value;
        var out: std.ArrayList(u8) = .empty;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, start, '&')) |i| {
            try out.appendSlice(self.a, value[start..i]);
            var buf: [4]u8 = undefined;
            if (decodeEntity(value[i..], &buf)) |decoded| {
                try out.appendSlice(self.a, decoded.bytes);
                start = i + decoded.consumed;
            } else {
                try out.append(self.a, '&');
                start = i + 1;
            }
        }
        try out.appendSlice(self.a, value[start..]);
        return try out.toOwnedSlice(self.a);
    }
    pub fn inlineText(self: *Renderer, input: []const u8, inherited: Style, depth: usize) Error!void {
        if (depth > max_depth) {
            self.fallbacks.render_limit = true;
            try self.text("[render nesting limit]", inherited);
            return;
        }
        var it: ir.InlineIterator = .{
            .input = input,
            .bold = inherited.bold,
            .italic = inherited.italic,
            .renderer_boundaries = true,
            .link_trail = self.context.link_trail,
        };
        while (it.cursor < input.len) {
            if (self.truncated and self.span_limit_marker) return;
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
            const token = it.next() orelse break;
            s.bold = token.bold;
            s.italic = token.italic;
            switch (token.kind) {
                .text => if (token.literal_tail)
                    try self.plain(token.text, s)
                else
                    try self.plainWithMagicLinks(token.text, s),
                .line_break => try self.lineBreak(s),
                .link => {
                    var target = token.target;
                    var label_value = if (token.link_empty_label) "" else token.text;
                    const trail = token.trail;
                    target = try self.entityText(target);
                    if (std.mem.indexOfScalar(u8, target, '_') != null) {
                        const normalized = try self.a.dupe(u8, target);
                        std.mem.replaceScalar(u8, normalized, '_', ' ');
                        target = normalized;
                    }
                    if (!token.link_has_pipe) label_value = target;
                    const explicit = starts(target, ":");
                    if (explicit) {
                        target = target[1..];
                        if (!token.link_has_pipe) label_value = target;
                    }
                    if (!explicit and std.ascii.startsWithIgnoreCase(target, "Category:")) {
                        try self.text(trail, s);
                        continue;
                    }
                    if (!explicit and (std.ascii.startsWithIgnoreCase(target, "File:") or std.ascii.startsWithIgnoreCase(target, "Image:"))) {
                        const file_name = target[(std.mem.indexOfScalar(u8, target, ':').? + 1)..];
                        label_value = mediaCaption(label_value, file_name);
                        try self.mediaFile(file_name, label_value);
                        var media_style = s;
                        media_style.classes = "wikidict-media";
                        media_style.kind = .link;
                        media_style.target = try std.fmt.allocPrint(self.a, "File:{s}", .{file_name});
                        try self.text(try plainText(self.a, try self.parseSpans(label_value, .{})), media_style);
                    } else {
                        if (label_value.len == 0) label_value = pipeTrickLabel(target);
                        if (safeInternalTarget(target)) {
                            try self.link(label_value, target, s, depth + 1, false);
                            if (trail.len != 0) {
                                var trail_style = s;
                                trail_style.kind = .link;
                                trail_style.target = target;
                                try self.text(trail, trail_style);
                            }
                        } else {
                            try self.inlineText(label_value, s, depth + 1);
                            try self.text(trail, s);
                        }
                        continue;
                    }
                    try self.text(trail, s);
                },
                .external_link => if (inherited.kind == .link or inherited.kind == .external_link)
                    try self.text(token.text, s)
                else
                    try self.link(token.text, token.target, s, depth + 1, true),
                .template => try self.resolveTemplate(token.text, s, depth),
            }
        }
    }
    fn resolveTemplate(self: *Renderer, body: []const u8, style: Style, depth: usize) Error!void {
        const t = syntax.Template.parse(self.a, body) catch |err| switch (err) {
            error.RenderLimit => {
                self.unresolved_templates += 1;
                var missing = style;
                missing.kind = .template;
                const first = syntax.delimiter(body, "|", 0) orelse body.len;
                missing.target = trim(body[0..first]);
                try self.text(body, missing);
                return;
            },
            else => return err,
        };
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
        self.spans = try .initCapacity(self.a, 4);
        defer self.spans = parent;
        try self.inlineText(try normalizeMisnestedHtml(self.a, input), style, 0);
        return try self.spans.toOwnedSlice(self.a);
    }
    fn appendBlockBudgeted(self: *Renderer, list: *std.ArrayList(Block), value: Block) Error!void {
        if (self.spend()) {
            try list.append(self.a, value);
            return;
        }
        if (self.block_limit_reached) return;
        self.block_limit_reached = true;
        try list.append(self.a, value);
    }
    fn block(self: *Renderer, list: *std.ArrayList(Block), kind: Kind, raw: []const u8, path: []const u8, number: []const u8, level: u8) Error!void {
        var hints: SemanticHints = .{};
        const parent_capture = self.semantic_capture;
        self.semantic_capture = &hints;
        defer self.semantic_capture = parent_capture;
        const spans = if (kind == .preformatted) blk: {
            const parent = self.spans;
            self.spans = .empty;
            defer self.spans = parent;
            try self.literal(raw, .{ .code = true });
            break :blk try self.spans.toOwnedSlice(self.a);
        } else try self.parseSpans(raw, .{});
        if (spans.len == 0 and kind != .heading and kind != .blank and kind != .rule) return;
        try self.appendBlockBudgeted(list, .{ .kind = kind, .text = raw, .spans = spans, .depth = @intCast(@min(path.len, 255)), .list_path = path[0..@min(path.len, 255)], .number = number, .level = level, .relation_note = hints.relation_note });
    }
    fn paragraph(self: *Renderer, list: *std.ArrayList(Block), text_value: []const u8) Error!void {
        if (trim(text_value).len == 0) return;
        var kind: Kind = .paragraph;
        const value = trim(text_value);
        if (starts(value, "{{")) if (syntax.balanced(value, 0)) |pair| {
            if (syntax.Template.parse(self.a, value[2..pair.inner_end])) |t| {
                if (oneOf(t.name, &.{ "ux", "uxi", "uxa", "usex", "co", "coi", "coa" })) kind = .example;
                if (starts(t.name, "quote-")) kind = .quotation;
            } else |err| switch (err) {
                error.RenderLimit => {},
                else => return err,
            }
        };
        try self.block(list, kind, value, "", "", 0);
    }
    pub fn renderBody(self: *Renderer, input: []const u8) Error![]const Block {
        if (self.body_depth >= max_depth) {
            self.fallbacks.render_limit = true;
            var fallback: std.ArrayList(Block) = .empty;
            try self.block(&fallback, .preformatted, input, "", "", 0);
            return fallback.toOwnedSlice(self.a);
        }
        self.body_depth += 1;
        defer self.body_depth -= 1;
        const line_capacity = std.mem.count(u8, input, "\n") + @intFromBool(input.len != 0 and input[input.len - 1] != '\n');
        var blocks: std.ArrayList(Block) = try .initCapacity(self.a, line_capacity);
        var pos: usize = 0;
        var para: ?usize = null;
        var counts: [32]usize = @splat(0);
        var list_root: u8 = 0;
        while (pos < input.len) {
            if (self.truncated) break;
            const start = pos;
            const end = syntax.logicalEnd(input, pos);
            const line = std.mem.trimEnd(u8, input[start..end], "\r");
            pos = if (end < input.len) end + 1 else end;
            const clean = trim(line);
            // TemplateStyles commonly precedes a NavFrame on the same line.
            // Consume this non-presentational extension before classifying the
            // following block, or its nested wiki table becomes inline text.
            if (syntax.tagAt(clean, 0)) |tag| {
                if (!tag.closing and tag.is("templatestyles")) {
                    if (syntax.matchingTag(clean, tag)) |pair| {
                        if (para) |p| {
                            try self.paragraph(&blocks, input[p..start]);
                            para = null;
                        }
                        pos = @intFromPtr(clean.ptr) - @intFromPtr(input.ptr) + pair.end;
                        continue;
                    }
                }
            }
            const heading = headingLine(std.mem.trimEnd(u8, line, " \t"));
            var multiline_data: ?[]const u8 = null;
            if (starts(clean, "{{multitrans|")) if (syntax.balanced(clean, 0)) |pair| {
                if (pair.end == clean.len) {
                    if (syntax.Template.parse(self.a, clean[2..pair.inner_end])) |t| {
                        multiline_data = t.named("data");
                    } else |err| switch (err) {
                        error.RenderLimit => {},
                        else => return err,
                    }
                }
            };
            var prefix: usize = 0;
            while (prefix < line.len and std.mem.indexOfScalar(u8, "#*:;", line[prefix]) != null) : (prefix += 1) {}
            const html_tag = if (syntax.tagAt(clean, 0)) |tag| (if (!tag.closing and
                oneOf(tag.name, &.{ "table", "div", "blockquote", "p", "ul", "ol", "dl", "center" }) and
                syntax.matchingTag(clean, tag) != null) tag else null) else null;
            const special = html_tag != null or multiline_data != null or clean.len == 0 or heading != null or prefix != 0 or starts(line, " ") or starts(clean, "{|") or starts(clean, "----") or starts(clean, "<pre") or starts(clean, "<syntaxhighlight");
            if (!special) {
                if (para == null) {
                    para = start;
                    @memset(&counts, 0);
                    list_root = 0;
                }
                continue;
            }
            if (para) |p| {
                try self.paragraph(&blocks, input[p..start]);
                para = null;
            }
            if (prefix == 0) {
                @memset(&counts, 0);
                list_root = 0;
            }
            if (html_tag) |tag| {
                const pair = syntax.matchingTag(clean, tag).?;
                if (tag.is("table")) {
                    if (std.mem.eql(u8, tag.attr("class") orelse "", "translations")) {
                        // Translation tables are layout wrappers around wiki lists,
                        // with optional tr/td end tags. Keep their reading blocks.
                        var body: std.ArrayList(u8) = .empty;
                        const content = clean[tag.end..pair.inner_end];
                        var cursor: usize = 0;
                        while (cursor < content.len) {
                            if (content[cursor] == '<') if (syntax.tagAt(content, cursor)) |cell| {
                                if (oneOf(cell.name, &.{ "tr", "td", "th", "tbody" })) {
                                    cursor = cell.end;
                                    continue;
                                }
                            };
                            try body.append(self.a, content[cursor]);
                            cursor += 1;
                        }
                        try blocks.appendSlice(self.a, try self.renderBody(body.items));
                    } else if (try self.htmlTable(clean[tag.end..pair.inner_end])) |table_value| {
                        try self.appendBlockBudgeted(&blocks, .{ .kind = .table, .table = table_value });
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
                const body_start = pos;
                const table = try self.parseTable(input, pos);
                pos = table.end;
                if (table.table.rows.len != 0) {
                    try self.appendBlockBudgeted(&blocks, .{ .kind = .table, .table = table.table });
                } else {
                    self.fallbacks.malformed_table = true;
                    // Rowless layout tables still contain ordinary lists/text.
                    for (try self.renderBody(input[body_start..table.body_end])) |block_value|
                        try self.appendBlockBudgeted(&blocks, block_value);
                }
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
                // Leading-space preformatting preserves whitespace, but unlike
                // <pre>/<syntaxhighlight> it still interprets inline markup.
                try self.appendBlockBudgeted(&blocks, .{ .kind = .preformatted, .spans = try self.parseSpans(line[1..], .{ .code = true }) });
                continue;
            }
            if (prefix != 0) {
                const path = line[0..prefix];
                const root = listRoot(path[0]);
                if (list_root != 0 and list_root != root) @memset(&counts, 0);
                list_root = root;
                const body = std.mem.trimStart(u8, line[prefix..], " \t");
                if (path.len == 1 and path[0] == ';') if (inlineDefinitionSplit(body)) |pair| {
                    try self.block(&blocks, .term, pair.term, ";", "", 0);
                    try self.block(&blocks, .list_detail, pair.definition, ":", "", 0);
                    continue;
                };
                const last = path[path.len - 1];
                const kind: Kind = if (path[0] == '#' and std.mem.indexOfScalar(u8, path, '*') != null)
                    .quotation
                else if (last == '#')
                    .definition
                else if (last == '*')
                    .list_item
                else if (last == ';')
                    .term
                else if (path[0] == '*' and last == ':')
                    .list_detail
                else if (path[0] == '#')
                    .example
                else
                    .indent;
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
                try self.block(&blocks, kind, body, path, number, 0);
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
            if (self.truncated) break;
            const tag = syntax.tagAt(input, open) orelse {
                pos = open + 1;
                continue;
            };
            pos = tag.end;
            if (tag.closing or !(tag.is("tr") or tag.is("caption"))) continue;
            const pair = if (tag.is("tr")) optionalTableEnd(input, tag) else syntax.matchingTag(input, tag) orelse return null;
            pos = pair.end;
            if (tag.is("caption")) {
                caption = try self.parseSpans(input[tag.end..pair.inner_end], .{});
                continue;
            }
            var cells: std.ArrayList(Cell) = .empty;
            var at = tag.end;
            while (std.mem.indexOfScalarPos(u8, input[0..pair.inner_end], at, '<')) |cell_open| {
                if (self.truncated) break;
                const cell_tag = syntax.tagAt(input, cell_open) orelse {
                    at = cell_open + 1;
                    continue;
                };
                at = cell_tag.end;
                if (cell_tag.closing or !(cell_tag.is("td") or cell_tag.is("th"))) continue;
                const cell_pair = optionalTableEnd(input[0..pair.inner_end], cell_tag);
                at = cell_pair.end;
                if (!self.spend()) continue;
                try cells.append(self.a, .{
                    .spans = try self.cellSpans(input[cell_tag.end..cell_pair.inner_end]),
                    .header = cell_tag.is("th"),
                    .colspan = try self.tableSpanAttr(cell_tag, "colspan"),
                    .rowspan = try self.tableSpanAttr(cell_tag, "rowspan"),
                });
            }
            if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
        }
        return .{ .caption = caption, .rows = try rows.toOwnedSlice(self.a) };
    }
    const TableResult = struct { table: Table, end: usize, body_end: usize };
    fn parseTable(self: *Renderer, input: []const u8, start: usize) Error!TableResult {
        var rows: std.ArrayList(Row) = .empty;
        var cells: std.ArrayList(Cell) = .empty;
        var cell_source: std.ArrayList(u8) = .empty;
        var current: ?Cell = null;
        var caption: []const Span = &.{};
        var pos = start;
        var body_end = input.len;
        var nested_tables: usize = 0;
        while (pos < input.len) {
            if (self.truncated) break;
            const line_start = pos;
            const end = syntax.logicalEnd(input, pos);
            const line = trim(input[pos..end]);
            pos = if (end < input.len) end + 1 else end;
            if (starts(line, "{|")) {
                if (cell_source.items.len != 0) try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, line);
                nested_tables += 1;
                continue;
            }
            if (nested_tables != 0) {
                if (cell_source.items.len != 0) try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, line);
                if (starts(line, "|}")) nested_tables -= 1;
                continue;
            }
            if (starts(line, "|}") or starts(line, "|-")) {
                try self.finishCell(&cells, &cell_source, &current);
                if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
                if (starts(line, "|}")) {
                    body_end = line_start;
                    break;
                }
            } else if (starts(line, "|+")) {
                caption = try self.parseSpans((try self.cellContent(line[2..])).text, .{});
            } else if (line.len != 0 and (line[0] == '!' or line[0] == '|')) {
                const header = line[0] == '!';
                const separator = if (header) "!!" else "||";
                var offset: usize = 1;
                while (offset <= line.len) {
                    try self.finishCell(&cells, &cell_source, &current);
                    const split_at = syntax.delimiter(line, separator, offset) orelse line.len;
                    const content = try self.cellContent(line[offset..split_at]);
                    current = .{ .spans = &.{}, .header = header, .colspan = content.colspan, .rowspan = content.rowspan };
                    try cell_source.appendSlice(self.a, content.text);
                    if (split_at == line.len) break;
                    offset = split_at + 2;
                }
            } else if (starts(line, "<tr")) {
                try self.finishCell(&cells, &cell_source, &current);
                if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
                if (try self.htmlTable(line)) |table| try rows.appendSlice(self.a, table.rows);
            } else if (current != null) {
                if (cell_source.items.len != 0) try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, line);
            }
        }
        try self.finishCell(&cells, &cell_source, &current);
        if (body_end == input.len) self.fallbacks.malformed_table = true;
        if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
        return .{ .table = .{ .caption = caption, .rows = try rows.toOwnedSlice(self.a) }, .end = pos, .body_end = body_end };
    }
    fn finishCell(self: *Renderer, cells: *std.ArrayList(Cell), source: *std.ArrayList(u8), current: *?Cell) Error!void {
        if (current.*) |value| {
            if (!self.spend()) {
                source.* = .empty;
                current.* = null;
                return;
            }
            var cell = value;
            cell.spans = try self.cellSpans(source.items);
            try cells.append(self.a, cell);
            source.* = .empty;
            current.* = null;
        }
    }

    fn cellSpans(self: *Renderer, source: []const u8) Error![]const Span {
        if (std.mem.indexOf(u8, source, "{|") == null) return self.parseSpans(source, .{});
        const parent = self.spans;
        self.spans = .empty;
        defer self.spans = parent;
        try self.blocksInline(try self.renderBody(source), .{});
        return self.spans.toOwnedSlice(self.a);
    }

    fn tableSpanAttr(self: *Renderer, tag: syntax.Tag, name: []const u8) Error!u16 {
        const raw = tag.attr(name) orelse return 1;
        const decoded = try self.entityText(raw);
        return @max(1, @min(100, std.fmt.parseInt(u16, decoded, 10) catch 1));
    }

    fn cellContent(self: *Renderer, raw: []const u8) Error!CellContent {
        if (syntax.delimiter(raw, "|", 0)) |pipe| if (std.mem.indexOfScalar(u8, raw[0..pipe], '=') != null) {
            const tag: syntax.Tag = .{ .name = "td", .attrs = raw[0..pipe], .end = 0, .closing = false, .self_closing = false };
            return .{
                .text = trim(raw[pipe + 1 ..]),
                .colspan = try self.tableSpanAttr(tag, "colspan"),
                .rowspan = try self.tableSpanAttr(tag, "rowspan"),
            };
        };
        return .{ .text = trim(raw) };
    }

    // DPR2 cells contain spans, not nested grids. Preserve nested table reading
    // order with explicit row/cell boundaries, never embedded table source.
    fn blocksInline(self: *Renderer, blocks: []const Block, style: Style) Error!void {
        for (blocks, 0..) |b, index| {
            if (index != 0) try self.lineBreak(style);
            try self.spans.appendSlice(self.a, b.spans);
            if (b.table) |table| {
                try self.spans.appendSlice(self.a, table.caption);
                for (table.rows, 0..) |row, ri| {
                    if (ri != 0 or table.caption.len != 0) try self.lineBreak(style);
                    for (row.cells, 0..) |cell, ci| {
                        if (ci != 0) try self.text(" · ", style);
                        try self.spans.appendSlice(self.a, cell.spans);
                    }
                }
            }
        }
    }
};
const Heading = struct { level: u8, title: []const u8 };
fn headingLine(line: []const u8) ?Heading {
    var left: usize = 0;
    while (left < line.len and line[left] == '=') : (left += 1) {}
    if (left == 0) return null;
    var right = line.len;
    while (right != 0 and line[right - 1] == '=') : (right -= 1) {}
    const right_width = line.len - right;
    if (right_width == 0) return null;

    // MediaWiki uses the shorter delimiter run as the heading level.
    // Any unmatched equals remain visible at the corresponding title edge.
    const level: usize = @min(6, @min(left, right_width));
    if (line.len < level * 2) return null;
    const title = trim(line[level .. line.len - level]);
    if (title.len == 0) return null;
    return .{ .level = @intCast(level), .title = title };
}
const CellContent = struct { text: []const u8, colspan: u16 = 1, rowspan: u16 = 1 };

fn flattened(a: A, spans: []const Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (spans) |s| try out.appendSlice(a, s.text);
    return out.toOwnedSlice(a);
}
test "reference identity fast paths remain exact" {
    try std.testing.expect(referenceStringEqual("", ""));
    try std.testing.expect(referenceStringEqual("r7", "r7"));
    try std.testing.expect(!referenceStringEqual("r7", "r8"));
    try std.testing.expect(referenceStringEqual("abc", "abc"));
    try std.testing.expect(!referenceStringEqual("abc", "abd"));
    try std.testing.expect(referenceStringEqual("abcdefgh", "abcdefgh"));
    try std.testing.expect(!referenceStringEqual("abcdefgh", "abcdxfgh"));
    try std.testing.expect(referenceStringEqual("abcdefghijklmnop", "abcdefghijklmnop"));
    try std.testing.expect(!referenceStringEqual("abcdefghijklmnop", "abcdefxhijklmnop"));
    try std.testing.expect(!referenceStringEqual("same", "same!"));
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
    try std.testing.expectEqualStrings("'''[[literal]]''' & <b> bold both <a href='javascript:alert(1)'>safe</a>", try flattened(a, spans));
    var both = false;
    for (spans) |s| {
        try std.testing.expect(!starts(s.target, "javascript:"));
        if (std.mem.eql(u8, s.text, "both")) both = s.flags.bold and s.flags.italic;
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
    }
    return out.toOwnedSlice(a);
}

test "emphasis template boundaries and nested image captions render without raw wiki delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("'''{{m|en|cat}}''' [[File:Cat.jpg|thumb|A [[domestic cat]]]] {{syn|en|kitty<q:rare>}}", .{});
    try std.testing.expectEqualStrings("cat A domestic cat Synonyms: kitty (rare)", try flattened(a, spans));
    try std.testing.expect(spans[0].flags.bold);
}

test "senseid optional list closure keeps links and nowiki semantic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("# <li class=\"senseid\" id=\"English:_Q108\">The first [[month]]. <span class=\"defdate\"><nowiki>[</nowiki>from 20th c.<nowiki>]</nowiki></span>\n");
    try std.testing.expectEqualStrings("The first month. [from 20th c.]", try flattened(a, blocks[0].spans));
    try std.testing.expect(blocks[0].spans[1].kind == .link);
}

test "leading space preformatting still compiles links and HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(" A <b>[[pie]]</b>.\n");
    try std.testing.expectEqual(Kind.preformatted, blocks[0].kind);
    try std.testing.expectEqualStrings("A pie.", try flattened(a, blocks[0].spans));
    try std.testing.expect(blocks[0].spans[1].flags.bold);
}
test "multitrans produces real blocks and malformed tables retain readable content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{{multitrans|data=\n{{trans-top|animal}}\n* French: {{t|fr|chat|m}}\n{{trans-bottom}}\n}}\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("French: chat m", try flattened(a, blocks[1].spans));
    const bad = try r.renderBody("{|\nimportant text without a cell or closing marker");
    try std.testing.expectEqual(Kind.paragraph, bad[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, try flattened(a, bad[0].spans), "important text") != null);
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
    try std.testing.expect(t.rows[1].cells[1].spans[0].flags.bold);
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
}

test "optional table cell closures compile semantic cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const blocks = try r.renderBody("<table><tr><td>valuable content</tr></table>");
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    try std.testing.expectEqualStrings("valuable content", try flattened(arena.allocator(), blocks[0].table.?.rows[0].cells[0].spans));
}

test "table span attributes decode entities and stay bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };

    const html = try r.renderBody("<table><tr><td colspan='&#50;' rowspan='999'>cell</td></tr></table>");
    const html_cell = html[0].table.?.rows[0].cells[0];
    try std.testing.expectEqual(@as(u16, 2), html_cell.colspan);
    try std.testing.expectEqual(@as(u16, 100), html_cell.rowspan);

    const wiki = try r.renderBody("{|\n|-\n| colspan=&#51; rowspan=0 | cell\n|}\n");
    const wiki_cell = wiki[0].table.?.rows[0].cells[0];
    try std.testing.expectEqual(@as(u16, 3), wiki_cell.colspan);
    try std.testing.expectEqual(@as(u16, 1), wiki_cell.rowspan);
}

test "translation layout tables preserve lists with optional closing tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table class=\"translations\"><tr><td>\n* French: <span lang=\"fr\">[[chat]]</span>\n* German: [[Katze]]\n</table>");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.list_item, blocks[0].kind);
    try std.testing.expectEqualStrings("French: chat", try flattened(a, blocks[0].spans));
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
    for (spans) |s| if (s.kind == .link and s.flags.bold and std.mem.eql(u8, s.target, "cat")) {
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

test "opaque extensions render safely without leaking parser delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<poem>first [[cat]]\nsecond</poem><gallery>\nFile:Cat.jpg|A [[cat]]\n</gallery><math>a|b=c</math><graph>{\"value\":\"{{x|y}}\"}</graph><dynamicpagelist>category=Tea room\ncount=100</dynamicpagelist>", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "first cat\nsecond") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "A cat") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "a|b=c") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "unsupported extension") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "category=Tea room") == null);
    try std.testing.expect(r.fallbacks.unsupported_element);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "<gallery") == null);
    try std.testing.expectEqual(@as(usize, 1), r.media.items.len);
    try std.testing.expectEqualStrings("A cat", r.media.items[0].caption);
}

test "reference identity includes group and decodes attribute entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("A<ref name='same&amp;x' group='note'>one</ref> B<ref name='same&amp;x' group='source'>two</ref> C<ref name='same&amp;x' group='note'/>", .{});
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("same&x", refs[0].name);
    try std.testing.expectEqualStrings("note", refs[0].group);
    try std.testing.expectEqualStrings("source", refs[1].group);
    try std.testing.expectEqualStrings("one", try flattened(a, refs[0].spans));
    try std.testing.expectEqualStrings("two", try flattened(a, refs[1].spans));
    const text_value = try flattened(a, spans);
    try std.testing.expectEqualStrings("A[note 1] B[source 1] C[note 1]", text_value);
    try std.testing.expectEqual(@as(usize, 1), refs[0].group_number);
    try std.testing.expectEqual(@as(usize, 1), refs[1].group_number);
}

test "media options do not become captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[File:Cat.jpg|thumb|right|200px|alt=cat photo|A [[cat]] resting]] [[File:Dog.jpg|frameless|alt=dog]]", .{});
    try std.testing.expectEqual(@as(usize, 2), r.media.items.len);
    try std.testing.expectEqualStrings("A cat resting", r.media.items[0].caption);
    try std.testing.expectEqualStrings("Dog.jpg", r.media.items[1].caption);
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "alt=cat") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "200px") == null);

    const audio = try r.parseSpans("[[File:Voice.ogg|noicon|start=2|end=4|loop|Spoken example]]", .{});
    try std.testing.expect(std.mem.indexOf(u8, try flattened(a, audio), "start=2") == null);
    try std.testing.expectEqualStrings("Spoken example", r.media.items[r.media.items.len - 1].caption);
}

test "nested wiki tables do not close their parent table early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const source = "{|\n|-\n| outer\n{|\n|-\n| inner\n|}\n| sibling\n|-\n| final\n|}\n# after\n";
    const blocks = try r.renderBody(source);
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].table.?.rows.len);
    try std.testing.expectEqualStrings("outer\ninner", try flattened(a, blocks[0].table.?.rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("final", try flattened(a, blocks[0].table.?.rows[1].cells[0].spans));
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
    try std.testing.expectEqualStrings("after", try flattened(a, blocks[1].spans));
}

test "wide and sparse column templates render without artificial index walks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "{{col|en");
    for (0..1_200) |_| try source.appendSlice(a, "|term");
    try source.appendSlice(a, "}}");
    const wide = try r.parseSpans(source.items, .{});
    var links: usize = 0;
    for (wide) |span| {
        if (span.kind == .link) links += 1;
    }
    try std.testing.expectEqual(@as(usize, 1_200), links);
    try std.testing.expectEqual(@as(usize, 0), r.unresolved_templates);

    const sparse = try r.parseSpans("{{col|en|2=two|999999999=last|2=override}}", .{});
    try std.testing.expectEqualStrings("override, last", try flattened(a, sparse));
}

test "list continuations keep list-detail semantics for nested rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("* parent\n*: detail\n** child\n:: plain indent\n");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.list_item, blocks[0].kind);
    try std.testing.expectEqualStrings("*", blocks[0].list_path);
    try std.testing.expectEqual(Kind.list_detail, blocks[1].kind);
    try std.testing.expectEqualStrings("*:", blocks[1].list_path);
    try std.testing.expectEqualStrings("detail", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.list_item, blocks[2].kind);
    try std.testing.expectEqualStrings("**", blocks[2].list_path);
    try std.testing.expectEqual(Kind.indent, blocks[3].kind);
}

test "gallery media options stay metadata instead of leaking into captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<gallery>\nFile:Cat.jpg|thumb|200px|alt=cat photo|A [[cat]] resting\nFile:Dog.jpg|frameless|alt=dog photo\n</gallery>", .{});
    try std.testing.expectEqual(@as(usize, 2), r.media.items.len);
    try std.testing.expectEqualStrings("A cat resting", r.media.items[0].caption);
    try std.testing.expectEqualStrings("Dog.jpg", r.media.items[1].caption);
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "thumb") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "200px") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "alt=cat") == null);
}

test "HTML comments and opaque bodies cannot prematurely close an outer element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<div><!-- </div> --><nowiki></div></nowiki><b>kept</b></div> tail", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "<!--") == null);
    var kept_bold = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "kept")) kept_bold = span.flags.bold;
    }
    try std.testing.expect(kept_bold);
}

test "external links ignore closing brackets inside nowiki and retain the label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[https://example.test <nowiki>]</nowiki> docs] tail", .{});
    try std.testing.expectEqualStrings("] docs tail", try flattened(a, spans));
    var linked = false;
    for (spans) |span| {
        if (span.kind == .external_link and std.mem.eql(u8, span.target, "https://example.test")) linked = true;
    }
    try std.testing.expect(linked);
}

test "renderer preserves MediaWiki external protocols and free links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(
        "[ftp://example.test/file ftp] [mailto:x@example.test mail] " ++
            "[//example.test/path relative] https://example.test/free. https://example.test/?a=1&amp;b=2",
        .{},
    );
    try std.testing.expectEqualStrings("ftp mail relative https://example.test/free. https://example.test/?a=1&b=2", try flattened(a, spans));
    var links: usize = 0;
    var entity_target = false;
    for (spans) |span| {
        if (span.kind != .external_link) continue;
        links += 1;
        try std.testing.expect(safeUrl(span.target));
        if (std.mem.eql(u8, span.target, "https://example.test/?a=1&b=2")) entity_target = true;
    }
    try std.testing.expectEqual(@as(usize, 5), links);
    try std.testing.expect(entity_target);
    try std.testing.expect(!safeUrl("javascript:alert(1)"));
    try std.testing.expect(!safeUrl("http://"));
}

test "raw anchors do not suppress free links in their visible source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const source = "<a href='/wiki/target'>https://example.test/free</a>";
    const spans = try r.parseSpans(source, .{});
    try std.testing.expectEqualStrings(source, try flattened(a, spans));
    var external = false;
    for (spans) |span| {
        try std.testing.expect(span.kind != .link);
        if (span.kind == .external_link and std.mem.eql(u8, span.target, "https://example.test/free")) external = true;
    }
    try std.testing.expect(external);
}

test "renderer preserves MediaWiki RFC PMID and ISBN magic links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(
        "RFC 2616 | PMID 000123 | ISBN 978-0-306-40615-8 | ISBN 123456789x | " ++
            "ISBN 978030640615X | xRFC 1 | RFC 4x | ISBN 1234567890123",
        .{},
    );
    try std.testing.expectEqualStrings(
        "RFC 2616 | PMID 000123 | ISBN 978-0-306-40615-8 | ISBN 123456789x | " ++
            "ISBN 978030640615X | xRFC 1 | RFC 4x | ISBN 1234567890123",
        try flattened(a, spans),
    );
    var rfc = false;
    var pmid = false;
    var isbn13 = false;
    var isbn13_x = false;
    var isbn10 = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "RFC 2616")) {
            rfc = span.kind == .external_link and std.mem.eql(u8, span.target, "https://datatracker.ietf.org/doc/html/rfc2616");
        } else if (std.mem.eql(u8, span.text, "PMID 000123")) {
            pmid = span.kind == .external_link and std.mem.eql(u8, span.target, "//www.ncbi.nlm.nih.gov/pubmed/000123?dopt=Abstract");
        } else if (std.mem.eql(u8, span.text, "ISBN 978-0-306-40615-8")) {
            isbn13 = span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/9780306406158");
        } else if (std.mem.eql(u8, span.text, "ISBN 978030640615X")) {
            isbn13_x = span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/978030640615X");
        } else if (std.mem.eql(u8, span.text, "ISBN 123456789x")) {
            isbn10 = span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/123456789X");
        }
    }
    try std.testing.expect(rfc);
    try std.testing.expect(pmid);
    try std.testing.expect(isbn13);
    try std.testing.expect(isbn13_x);
    try std.testing.expect(isbn10);

    const unicode_boundaries = try r.parseSpans("éRFC 1 | —RFC 2 | PMID 3猫 | PMID 4。", .{});
    var unicode_magic: usize = 0;
    for (unicode_boundaries) |span| {
        if (span.kind == .external_link) unicode_magic += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), unicode_magic);
}

test "renderer accepts current MediaWiki semantic HTML tags without leaking tag source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(
        "A<h3>heading</h3><data value='1'>shown</data><ruby>x<rtc>reading</rtc></ruby>" ++
            "<meta itemprop='x' content='y'>Z",
        .{},
    );
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "<h3>") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "<data") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "<rtc>") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "<meta") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "shown") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "xreading") != null);
    try std.testing.expect(std.mem.endsWith(u8, text_value, "Z"));
}

test "itemprop metadata tags follow MediaWiki visibility rules without retaining URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };

    const accepted = try r.parseSpans(
        "A<meta itemprop='x' content='y'><link itemprop='url' href='//example.test/x'>" ++
            "<link itemprop='x' href='mw-data:foo'>Z",
        .{},
    );
    try std.testing.expectEqualStrings("AZ", try flattened(a, accepted));

    const rejected = try r.parseSpans("A<meta itemprop='x'><link itemprop='x'>Z", .{});
    try std.testing.expectEqualStrings("A<meta itemprop='x'><link itemprop='x'>Z", try flattened(a, rejected));
}

test "transclusion controls and table containers keep page-context visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };

    const controls = try r.parseSpans(
        "A<noinclude>N</noinclude><includeonly>I</includeonly><onlyinclude>O</onlyinclude>Z",
        .{},
    );
    try std.testing.expectEqualStrings("ANOZ", try flattened(a, controls));

    const containers = try r.parseSpans(
        "A<tbody>B</tbody><thead>H</thead><tfoot>F</tfoot><tr>R</tr><td>D</td><th>T</th><caption>C</caption>Z",
        .{},
    );
    try std.testing.expectEqualStrings(
        "A<tbody>B</tbody><thead>H</thead><tfoot>F</tfoot>RDTCZ",
        try flattened(a, containers),
    );
}

test "semantic HTML decodes class language and direction attributes before use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(
        "<span class='&#73;PA' lang='e&#110;' dir='&#114;tl'>/kat/</span>",
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("IPA", spans[0].classes);
    try std.testing.expectEqualStrings("en", spans[0].language);
    try std.testing.expectEqualStrings("rtl", spans[0].direction);
    try std.testing.expectEqual(Role.pronunciation, spans[0].role);
}

test "malformed entities stay literal while invalid Unicode scalars become replacement characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("&#0;|&#xD800;|&#x110000;|&definitelyNotAnEntity;|&amp", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.startsWith(u8, text_value, "�|�|"));
    try std.testing.expect(std.mem.indexOf(u8, text_value, "&definitelyNotAnEntity;") != null);
    try std.testing.expect(std.mem.endsWith(u8, text_value, "|&amp"));
}

test "attribute entity decoding does not spend presentation node budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const before = r.nodes;
    try std.testing.expectEqualStrings("plain", try r.entityText("plain"));
    try std.testing.expectEqualStrings("A&B � &bogus;", try r.entityText("A&amp;B &#x110000; &bogus;"));
    try std.testing.expectEqual(before, r.nodes);
}

test "renderer degrades oversized templates instead of failing the whole entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "{{oversized");
    for (0..16_385) |_| try source.appendSlice(a, "|x");
    try source.appendSlice(a, "}} tail");
    const spans = try r.parseSpans(source.items, .{});
    try std.testing.expectEqual(@as(usize, 1), r.unresolved_templates);
    try std.testing.expect(spans.len >= 2);
    try std.testing.expectEqual(ir.InlineKind.template, spans[0].kind);
    try std.testing.expectEqualStrings("oversized", spans[0].target);
    try std.testing.expect(std.mem.endsWith(u8, try flattened(a, spans), " tail"));
}

test "media collection caps without turning excess assets into a render failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    var source: std.ArrayList(u8) = .empty;
    for (0..140) |i| {
        const item = try std.fmt.allocPrint(a, "[[File:{d}.jpg|thumb|image {d}]] ", .{ i, i });
        try source.appendSlice(a, item);
    }
    const spans = try r.parseSpans(source.items, .{});
    try std.testing.expectEqual(@as(usize, 128), r.media.items.len);
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "image 139") != null);
}

test "extreme nested block HTML falls back to bounded preformatted content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    var source: std.ArrayList(u8) = .empty;
    for (0..60) |_| try source.appendSlice(a, "<div>\n");
    try source.appendSlice(a, "deep content\n");
    for (0..60) |_| try source.appendSlice(a, "</div>\n");
    const blocks = try r.renderBody(source.items);
    try std.testing.expect(blocks.len != 0);
    var saw_deep = false;
    for (blocks) |block_value| {
        const text_value = try flattened(a, block_value.spans);
        if (std.mem.indexOf(u8, text_value, "deep content") != null) saw_deep = true;
    }
    try std.testing.expect(saw_deep);
}

test "structured inline edge fuzz keeps valid UTF8 and trailing content reachable" {
    const fragments = [_][]const u8{
        "plain é猫 ",
        "'''bold''' ",
        "''italic'' ",
        "[[cat|c{{small|a}}t]]s ",
        "[https://example.test <nowiki>]</nowiki> docs] ",
        "<ref name='r&amp;x' group='g'>{{q|rare}} [[cat]]</ref> ",
        "<nowiki>{{x|y}} [[z]] &amp;</nowiki> ",
        "<math>a|b=c</math> ",
        "<span class='IPA'>/kæt/</span> ",
        "&NotGreaterFullEqual; ",
        "{{l|en|cat<q:rare>}} ",
        "[[File:Cat.jpg|thumb|200px|A [[cat]]]] ",
        "<gallery>\nFile:Cat.jpg|thumb|A [[cat]]\n</gallery> ",
        "<b>open ",
        "<weird>literal</weird> ",
        "{{broken ",
    };
    var state: u64 = 0x90c4_771a_2b13_8d5f;
    for (0..1_000) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var source: std.ArrayList(u8) = .empty;
        const count: usize = @intCast(1 + state % 12);
        for (0..count) |_| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            try source.appendSlice(a, fragments[@intCast(state % fragments.len)]);
        }
        try source.appendSlice(a, "EDGE_SENTINEL");
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(source.items, .{});
        _ = try r.finishReferences();
        const text_value = try flattened(a, spans);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text_value));
        try std.testing.expect(std.mem.indexOf(u8, text_value, "EDGE_SENTINEL") != null);
    }
}

fn edgeAllocationCase(a: A) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const source = "<div><!-- fake </div> --><gallery>\nFile:Cat.jpg|thumb|200px|A [[cat]]\n</gallery>" ++
        "<ref name='x&amp;y' group='note'>{{q|rare}} [[cat]]</ref></div>\n" ++
        "{|\n! A !! B\n|-\n| <math>a|b</math> || [[dog]]\n|}\n";
    _ = try r.renderBody(source);
    _ = try r.finishReferences();
}

test "edge renderer paths release every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, edgeAllocationCase, .{});
}

test "wiki link trails stay linked while hidden category trails remain visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[cat]]s [[Category:Animals]]tail [[:Category:Animals]]s", .{});
    try std.testing.expectEqualStrings("cats tail Category:Animalss", try flattened(a, spans));
    var linked_s: usize = 0;
    var plain_tail = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "s") and span.kind == .link) linked_s += 1;
        if (std.mem.eql(u8, span.text, "tail") and span.kind == .text) plain_tail = true;
    }
    try std.testing.expectEqual(@as(usize, 2), linked_s);
    try std.testing.expect(plain_tail);
}

test "pipe trick strips syntactic colon prefixes and final disambiguators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[Thesaurus:cat|]] | [[MOD:test|]] | [[Foo (bar)|]] | [[Boston, Massachusetts|]] | [[Music: My life|]] | [[Help:Links#Pipe trick|]]", .{});
    try std.testing.expectEqualStrings("cat | test | Foo | Boston | My life | Help:Links#Pipe trick", try flattened(a, spans));
}

test "same-line definition lists split term and definition without splitting nested colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("; [[HTTP:foo|term]] : a definition\n; plain term : another\n");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.term, blocks[0].kind);
    try std.testing.expectEqual(Kind.list_detail, blocks[1].kind);
    try std.testing.expectEqualStrings("term", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("a definition", try flattened(a, blocks[1].spans));
    try std.testing.expectEqualStrings("plain term", try flattened(a, blocks[2].spans));
    try std.testing.expectEqualStrings("another", try flattened(a, blocks[3].spans));
}

test "parameter defaults remain visible when preceded by ordinary text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("prefix {{{missing|[[cat|fallback]]}}} suffix", .{});
    try std.testing.expectEqualStrings("prefix fallback suffix", try flattened(a, spans));
    var linked = false;
    for (spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "cat")) linked = true;
    }
    try std.testing.expect(linked);
}

test "malformed link tail stays literal at the current cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const source = "[[broken <b>bold</b> &amp; tail";
    const spans = try r.parseSpans(source, .{});
    try std.testing.expectEqualStrings(source, try flattened(a, spans));
}

test "empty link remains literal while following inline content renders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[]]<b>bold</b> &amp;", .{});
    try std.testing.expectEqualStrings("[[]]bold &", try flattened(a, spans));
    const after_prefix = try r.parseSpans("prefix [[]] suffix", .{});
    try std.testing.expectEqualStrings("prefix [[]] suffix", try flattened(a, after_prefix));
}

test "malformed template and link opener storms preserve the tail without trapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "prefix ");
    for (0..8_000) |_| try source.appendSlice(a, "{{broken [[broken ");
    try source.appendSlice(a, "EDGE_SENTINEL");
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(source.items, .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "EDGE_SENTINEL") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text_value));
}

test "benign semantic HTML renders content while dangerous HTML stays inert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<abbr title='abbreviation'>abbr</abbr> <cite>cite</cite> <ins>inserted</ins> <samp>sample</samp> <ruby>漢<rt>kan</rt></ruby><wbr>ok <script>alert(1)</script>", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "abbr cite inserted sample 漢kanok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "alert(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "unsupported HTML") == null);
    try std.testing.expect(r.fallbacks.unsupported_element);
    var styled = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "cite") and span.flags.italic) styled = true;
    }
    try std.testing.expect(styled);
}

test "numbered lists restart after non-list blocks and root-list changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("# one\n## child\n# two\nplain paragraph\n# fresh\n* bullet\n# fresh again\n");
    var numbers: std.ArrayList([]const u8) = .empty;
    for (blocks) |block_value| if (block_value.kind == .definition) try numbers.append(a, block_value.number);
    try std.testing.expectEqual(@as(usize, 5), numbers.items.len);
    try std.testing.expectEqualStrings("1", numbers.items[0]);
    try std.testing.expectEqualStrings("1.1", numbers.items[1]);
    try std.testing.expectEqualStrings("2", numbers.items[2]);
    try std.testing.expectEqualStrings("1", numbers.items[3]);
    try std.testing.expectEqualStrings("1", numbers.items[4]);
}

test "headings follow MediaWiki whitespace width and level-six clamping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };

    const valid = try r.renderBody("=== Head ===\nAfter");
    try std.testing.expectEqual(Kind.heading, valid[0].kind);
    try std.testing.expectEqualStrings("Head", try flattened(a, valid[0].spans));

    const extra_right = try r.renderBody("=== Head ====\nAfter");
    try std.testing.expectEqual(Kind.heading, extra_right[0].kind);
    try std.testing.expectEqual(@as(u8, 3), extra_right[0].level);
    try std.testing.expectEqualStrings("Head =", try flattened(a, extra_right[0].spans));

    const extra_left = try r.renderBody("==== Head ===\nAfter");
    try std.testing.expectEqual(Kind.heading, extra_left[0].kind);
    try std.testing.expectEqual(@as(u8, 3), extra_left[0].level);
    try std.testing.expectEqualStrings("= Head", try flattened(a, extra_left[0].spans));

    const leading_space = try r.renderBody(" == Head ==\nAfter");
    try std.testing.expectEqual(Kind.preformatted, leading_space[0].kind);
    try std.testing.expectEqualStrings("== Head ==", try flattened(a, leading_space[0].spans));

    const trailing_space = try r.renderBody("== Head == \nAfter");
    try std.testing.expectEqual(Kind.heading, trailing_space[0].kind);
    try std.testing.expectEqualStrings("Head", try flattened(a, trailing_space[0].spans));

    const seven = try r.renderBody("======= Head =======\nAfter");
    try std.testing.expectEqual(Kind.heading, seven[0].kind);
    try std.testing.expectEqual(@as(u8, 6), seven[0].level);
    try std.testing.expectEqualStrings("= Head =", try flattened(a, seven[0].spans));
}

test "misnested formatting follows MediaWiki visible style ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("A<b>B<i>I</b>X</i>Z", .{});
    try std.testing.expectEqualStrings("ABIXZ", try flattened(a, spans));

    var saw_b = false;
    var saw_i = false;
    var saw_x = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "B")) {
            saw_b = true;
            try std.testing.expect(span.flags.bold);
            try std.testing.expect(!span.flags.italic);
        } else if (std.mem.eql(u8, span.text, "I")) {
            saw_i = true;
            try std.testing.expect(span.flags.bold);
            try std.testing.expect(span.flags.italic);
        } else if (std.mem.eql(u8, span.text, "X")) {
            saw_x = true;
            try std.testing.expect(!span.flags.bold);
            try std.testing.expect(span.flags.italic);
        }
    }
    try std.testing.expect(saw_b and saw_i and saw_x);
}

test "multiline safe block HTML keeps inner list structure inside the container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<blockquote>\n# quoted definition\n#: quoted example\n</blockquote>\n# outside\n");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(Kind.definition, blocks[0].kind);
    try std.testing.expectEqualStrings("quoted definition", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.example, blocks[1].kind);
    try std.testing.expectEqualStrings("quoted example", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.definition, blocks[2].kind);
    try std.testing.expectEqualStrings("1", blocks[2].number);
}

test "stray and unclosed dangerous HTML cannot swallow following dictionary text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("before </script> after <script>literal tail", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "unsupported HTML") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "literal tail") != null);
    try std.testing.expect(r.fallbacks.unsupported_element);
    try std.testing.expect(r.fallbacks.unclosed_formatting);

    const breaks = try r.parseSpans("a<br>b</br>c<hr>d</hr>e", .{});
    const break_text = try flattened(a, breaks);
    try std.testing.expectEqualStrings("a\nbc\n────────\nde", break_text);
}

test "raw HTML anchors stay literal while attribute URLs retain MediaWiki free-link semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const source = "<a href='/wiki/cat_activation_noise#See_also'>cat</a> <a href='#Usage_notes'>notes</a> <a href='//example.test/x'>plain</a> <a href='https://example.test/x'>external</a> <a href='javascript:alert(1)'>bad</a>";
    const spans = try r.parseSpans(source, .{});
    try std.testing.expectEqualStrings(source, try flattened(a, spans));
    var external = false;
    for (spans) |span| {
        try std.testing.expect(span.kind != .link);
        if (span.kind == .external_link and std.mem.eql(u8, span.target, "https://example.test/x'")) external = true;
        try std.testing.expect(!std.mem.startsWith(u8, span.target, "javascript:"));
    }
    try std.testing.expect(external);
}

test "internal link targets decode entities and normalize underscores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[A&amp;B]] [[cat_activation_noise]] [[cat_activation_noise#See_also|entry]]", .{});
    try std.testing.expectEqualStrings("A&B cat activation noise entry", try flattened(a, spans));
    var first = false;
    var second = false;
    for (spans) |span| {
        if (span.kind != .link) continue;
        if (std.mem.eql(u8, span.target, "A&B")) first = true;
        if (std.mem.eql(u8, span.target, "cat activation noise#See also")) second = true;
    }
    try std.testing.expect(first);
    try std.testing.expect(second);
}

test "list-defined references populate named citations without emitting fake markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("A<ref name=x/> B<ref name=y group=note/> <references><ref name=x>Alpha ''Book''</ref></references><references group=note><ref name=y>Beta</ref></references>", .{});
    try std.testing.expectEqualStrings("A[1] B[note 1] ", try flattened(a, spans));
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("Alpha Book", try flattened(a, refs[0].spans));
    try std.testing.expectEqualStrings("Beta", try flattened(a, refs[1].spans));
}

test "list-defined reference may precede its later citation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<references><ref name=x>X body</ref><ref name=y>Y body</ref></references>Y<ref name=y/> X<ref name=x/>", .{});
    try std.testing.expectEqualStrings("Y[1] X[2]", try flattened(a, spans));
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("y", refs[0].name);
    try std.testing.expectEqualStrings("Y body", try flattened(a, refs[0].spans));
    try std.testing.expectEqualStrings("x", refs[1].name);
    try std.testing.expectEqualStrings("X body", try flattened(a, refs[1].spans));
}

test "list-defined references ignore ref-looking text in protected regions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const source = "<references><!-- <ref name=comment>bad</ref> --><nowiki><ref name=raw>bad</ref></nowiki><math><ref name=math>bad</ref></math><ref name=real>good</ref></references>R<ref name=real/>";
    const spans = try r.parseSpans(source, .{});
    try std.testing.expectEqualStrings("R[1]", try flattened(a, spans));
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("real", refs[0].name);
    try std.testing.expectEqualStrings("good", try flattened(a, refs[0].spans));
}

test "control characters in decoded internal targets never become navigation links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[bad&#x85;title|visible]]", .{});
    try std.testing.expectEqualStrings("visible", try flattened(a, spans));
    for (spans) |span| try std.testing.expect(span.kind != .link);
}

test "presentation node budget truncates explicitly instead of returning RenderLimit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    for (0..max_nodes + 32) |_| try source.appendSlice(a, "&amp;");
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(source.items, .{});
    try std.testing.expect(r.truncated);
    try std.testing.expect(r.nodes <= max_nodes);
    try std.testing.expect(spans.len <= max_nodes + 1);
    try std.testing.expectEqualStrings("[render output truncated]", spans[spans.len - 1].text);
}

test "unclosed HTML opener storms are consumed once and preserve the tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "prefix <div>");
    for (0..8_000) |_| try source.appendSlice(a, "<div>");
    try source.appendSlice(a, "EDGE_SENTINEL");
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(source.items, .{});
    const text_value = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "EDGE_SENTINEL") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text_value));
}

test "default reference numbering stays independent of named groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(
        "A<ref>a</ref> B<ref group='note'>b</ref> C<ref>c</ref> D<ref group='note'>d</ref>",
        .{},
    );
    try std.testing.expectEqualStrings("A[1] B[note 1] C[2] D[note 2]", try flattened(a, spans));
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 4), refs.len);
    try std.testing.expectEqual(@as(usize, 1), refs[0].group_number);
    try std.testing.expectEqual(@as(usize, 1), refs[1].group_number);
    try std.testing.expectEqual(@as(usize, 2), refs[2].group_number);
    try std.testing.expectEqual(@as(usize, 2), refs[3].group_number);
}

test "emphasis exposes nested HTML entities and parameters to the compiler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans(
        "'''<span class=\"Jpan\" lang=\"ja\">兇</span>''' / " ++
            "''<span lang=\"ja\">[[:凶#Japanese|凶]]</span>'' / " ++
            "'''&amp;''' / '''{{{missing|fallback}}}'''",
        .{},
    );
    try std.testing.expectEqualStrings("兇 / 凶 / & / fallback", try flattened(a, spans));
    try std.testing.expect(spans[0].flags.bold);
    try std.testing.expectEqualStrings("ja", spans[0].language);
    try std.testing.expectEqualStrings("Jpan", spans[0].classes);
    var linked = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "凶")) {
            linked = true;
            try std.testing.expect(span.flags.italic);
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings("凶#Japanese", span.target);
            try std.testing.expectEqualStrings("ja", span.language);
        }
    }
    try std.testing.expect(linked);
}

test "packed compiler span flags preserve DPR2 bit positions" {
    inline for ([_]struct { flags: SpanFlags, byte: u8 }{
        .{ .flags = .{ .bold = true }, .byte = 1 << 0 },
        .{ .flags = .{ .italic = true }, .byte = 1 << 1 },
        .{ .flags = .{ .code = true }, .byte = 1 << 2 },
        .{ .flags = .{ .small = true }, .byte = 1 << 3 },
        .{ .flags = .{ .superscript = true }, .byte = 1 << 4 },
        .{ .flags = .{ .subscript = true }, .byte = 1 << 5 },
        .{ .flags = .{ .strike = true }, .byte = 1 << 6 },
        .{ .flags = .{ .underline = true }, .byte = 1 << 7 },
    }) |case| try std.testing.expectEqual(case.byte, @as(u8, @bitCast(case.flags)));
}

test "TemplateStyles before NavFrame preserves semantic conjugation tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(
        "<templatestyles src=\"Module:verbs/style.css\" /><div class=\"NavFrame\">\n" ++
            "<div class=\"NavHead\">Conjugation</div>\n<div class=\"NavContent\">\n" ++
            "{| class=\"inflection-table\"\n! colspan=\"2\" | future\n|-\n" ++
            "| [[აღმოვაჩენ]] || [[აღმოაჩენ]]\n|}\n</div></div>\nAfter",
    );
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("Conjugation", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
    const table = blocks[1].table.?;
    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(u16, 2), table.rows[0].cells[0].colspan);
    try std.testing.expectEqualStrings("აღმოვაჩენ", try flattened(a, table.rows[1].cells[0].spans));
    try std.testing.expectEqualStrings("აღმოაჩენ", try flattened(a, table.rows[1].cells[1].spans));
    try std.testing.expectEqualStrings("After", try flattened(a, blocks[2].spans));
}

test "unclosed formatting and rowless nested tables compile their contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<small>[[word]]<small> tail", .{});
    try std.testing.expectEqualStrings("word tail", try flattened(a, spans));
    try std.testing.expect(spans[0].flags.small);
    const blocks = try r.renderBody("{|\n{|\n* [[one]]\n|}\n{|\n* [[two]]\n|}\n|}\n|}\nAfter");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("one", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("two", try flattened(a, blocks[1].spans));
    try std.testing.expectEqualStrings("|} After", try flattened(a, blocks[2].spans));
}
