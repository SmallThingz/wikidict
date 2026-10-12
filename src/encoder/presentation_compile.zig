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
        if (syntax.protectedEnd(input, at)) |end| {
            cursor = end;
            continue;
        }
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
fn optionalListItemEnd(input: []const u8, opening: syntax.Tag) syntax.Pair {
    if (opening.self_closing) return .{ .inner_end = opening.end, .end = opening.end };
    var cursor = opening.end;
    while (std.mem.indexOfScalarPos(u8, input, cursor, '<')) |at| {
        if (syntax.protectedEnd(input, at)) |end| {
            cursor = end;
            continue;
        }
        const tag = syntax.tagAt(input, at) orelse {
            cursor = at + 1;
            continue;
        };
        cursor = tag.end;
        if (!tag.closing and (tag.is("ul") or tag.is("ol") or tag.is("dl") or tag.is("table"))) {
            if (syntax.matchingTag(input, tag)) |pair| {
                cursor = pair.end;
                continue;
            }
        }
        if (tag.closing and tag.is(opening.name)) return .{ .inner_end = at, .end = tag.end };
        const sibling = !tag.closing and (if (opening.is("li")) tag.is("li") else tag.is("dt") or tag.is("dd"));
        const parent = tag.closing and (tag.is("ul") or tag.is("ol") or tag.is("dl"));
        if (sibling or parent) return .{ .inner_end = at, .end = at };
    }
    return .{ .inner_end = input.len, .end = input.len };
}
// Explicit ruby fallback punctuation belongs to this ruby, not nested ruby or
// protected literal markup. Existing rp text must pass through unchanged.
fn rubyHasFallback(input: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, input, cursor, '<')) |at| {
        if (syntax.protectedEnd(input, at)) |end| {
            cursor = end;
            continue;
        }
        const tag = syntax.tagAt(input, at) orelse {
            cursor = at + 1;
            continue;
        };
        cursor = tag.end;
        if (tag.closing) continue;
        if (tag.is("rp")) return true;
        if (tag.is("ruby")) {
            if (syntax.matchingTag(input, tag)) |pair| cursor = pair.end;
        }
    }
    return false;
}

fn htmlAttributePresent(tag: syntax.Tag, key: []const u8) bool {
    var at: usize = 0;
    while (at < tag.attrs.len) {
        while (at < tag.attrs.len and (std.ascii.isWhitespace(tag.attrs[at]) or tag.attrs[at] == '/')) : (at += 1) {}
        const begin = at;
        while (at < tag.attrs.len and !std.ascii.isWhitespace(tag.attrs[at]) and tag.attrs[at] != '=' and tag.attrs[at] != '/') : (at += 1) {}
        if (at == begin) {
            at += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tag.attrs[begin..at], key)) return true;
        while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len or tag.attrs[at] != '=') continue;
        at += 1;
        while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len) break;
        const quote = tag.attrs[at];
        const quoted = quote == '\'' or quote == '"';
        if (quoted) at += 1;
        while (at < tag.attrs.len and (if (quoted) tag.attrs[at] != quote else !std.ascii.isWhitespace(tag.attrs[at]))) : (at += 1) {}
        if (quoted and at < tag.attrs.len) at += 1;
    }
    return false;
}
const HtmlListNumberStyle = enum { decimal, lower_alpha, upper_alpha, lower_roman, upper_roman };
fn htmlListNumberStyle(value: []const u8) ?HtmlListNumberStyle {
    if (std.mem.eql(u8, value, "1")) return .decimal;
    if (std.mem.eql(u8, value, "a")) return .lower_alpha;
    if (std.mem.eql(u8, value, "A")) return .upper_alpha;
    if (std.mem.eql(u8, value, "i")) return .lower_roman;
    if (std.mem.eql(u8, value, "I")) return .upper_roman;
    return null;
}
fn htmlListItemCount(input: []const u8) i32 {
    var count: i32 = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, input, cursor, '<')) |at| {
        if (syntax.protectedEnd(input, at)) |end| {
            cursor = end;
            continue;
        }
        const tag = syntax.tagAt(input, at) orelse {
            cursor = at + 1;
            continue;
        };
        cursor = tag.end;
        if (tag.closing) continue;
        if (tag.is("li")) {
            count +|= 1;
            cursor = optionalListItemEnd(input, tag).end;
        } else if (tag.is("ul") or tag.is("ol") or tag.is("dl") or tag.is("table")) {
            if (syntax.matchingTag(input, tag)) |pair| cursor = pair.end;
        }
    }
    return count;
}
pub const media_types = @import("presentation_media.zig");
pub const Error = A.Error || error{RenderLimit};
pub const Context = struct {
    image_options: ?*const @import("namespace_registry").image_options.Registry = null,
    behavior_switches: ?*const @import("namespace_registry").behavior_switches.Registry = null,
    namespace_catalog: ?*const @import("namespace_registry").Registry = null,
    title: []const u8 = "Entry",
    language: []const u8 = "English",
    link_trail: ir.LinkTrail = .{},
};
pub const Role = enum { normal, label, pronunciation, headword, example, quotation, citation, reference };
pub const Provenance = enum { parsed, protected_literal, entity_literal };
pub const Style = struct {
    provenance: Provenance = .parsed,
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
    // Build-only context: decorative file names are not semantic heading text.
    heading: bool = false,
    // Build-only annotation boundary; readers receive ordinary semantic spans.
    ruby_parentheses: bool = false,
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
    // Build-only validation origin. Never serialized into DPR2.
    provenance: Provenance = .parsed,
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

// Quotes are resolved at build time before HTML repair. Internal labels have
// their own quote scope; authored HTML belongs to the surrounding line scope.
const QuoteBoundaries = struct {
    link_close: ?usize,
    template_close: ?usize,
    fn init(input: []const u8) QuoteBoundaries {
        return .{ .link_close = std.mem.lastIndexOf(u8, input, "]]"), .template_close = std.mem.lastIndexOf(u8, input, "}}") };
    }
    fn canClose(self: QuoteBoundaries, input: []const u8, at: usize) bool {
        const last = if (starts(input[at..], "[[")) self.link_close else self.template_close;
        return if (last) |end| end > at else false;
    }
};
fn quoteOpaqueEnd(input: []const u8, at: usize, boundaries: QuoteBoundaries) ?usize {
    if (input[at] == '<') {
        if (syntax.protectedEnd(input, at)) |end| return end;
        if (syntax.tagAt(input, at)) |tag| return tag.end;
    }
    if ((starts(input[at..], "[[") or starts(input[at..], "{{")) and boundaries.canClose(input, at)) {
        if (syntax.balanced(input, at)) |pair| return pair.end;
    }
    return null;
}
fn quoteRun(input: []const u8, at: usize) usize {
    var end = at;
    while (end < input.len and input[end] == '\'') : (end += 1) {}
    return end - at;
}

const QuoteState = enum { none, b, i, bi, ib, both };
const QuoteTransition = struct { prefix: []const u8, suffix: []const u8 = "", state: QuoteState };
fn quoteTransition(out: *std.ArrayList(u8), buffer: *std.ArrayList(u8), a: A, state: *QuoteState, run: usize) Error!void {
    const transitions = [6][3]QuoteTransition{
        .{ .{ .prefix = "<i>", .state = .i }, .{ .prefix = "<b>", .state = .b }, .{ .prefix = "", .state = .both } },
        .{ .{ .prefix = "<i>", .state = .bi }, .{ .prefix = "</b>", .state = .none }, .{ .prefix = "</b><i>", .state = .i } },
        .{ .{ .prefix = "</i>", .state = .none }, .{ .prefix = "<b>", .state = .ib }, .{ .prefix = "</i><b>", .state = .b } },
        .{ .{ .prefix = "</i>", .state = .b }, .{ .prefix = "</i></b><i>", .state = .i }, .{ .prefix = "</i></b>", .state = .none } },
        .{ .{ .prefix = "</b></i><b>", .state = .b }, .{ .prefix = "</b>", .state = .i }, .{ .prefix = "</b></i>", .state = .none } },
        .{ .{ .prefix = "<b><i>", .suffix = "</i>", .state = .b }, .{ .prefix = "<i><b>", .suffix = "</b>", .state = .i }, .{ .prefix = "<i><b>", .suffix = "</b></i>", .state = .none } },
    };
    const index: usize = switch (run) {
        2 => 0,
        3 => 1,
        5 => 2,
        else => unreachable,
    };
    const transition = transitions[@backingInt(state.*)][index];
    try out.appendSlice(a, transition.prefix);
    if (state.* == .both) {
        try out.appendSlice(a, buffer.items);
        buffer.clearRetainingCapacity();
    }
    try out.appendSlice(a, transition.suffix);
    state.* = transition.state;
}
fn quoteFinish(out: *std.ArrayList(u8), buffer: *std.ArrayList(u8), a: A, state: QuoteState) Error!void {
    const close: []const u8 = switch (state) {
        .none => "",
        .b => "</b>",
        .i => "</i>",
        .bi => "</i></b>",
        .ib => "</b></i>",
        .both => "",
    };
    if (state == .both and buffer.items.len != 0) {
        try out.appendSlice(a, "<b><i>");
        try out.appendSlice(a, buffer.items);
        try out.appendSlice(a, "</i></b>");
        buffer.clearRetainingCapacity();
    }
    try out.appendSlice(a, close);
}
fn hasWikiQuoteMarkers(input: []const u8, depth: usize, boundaries: QuoteBoundaries) bool {
    if (depth >= max_depth or std.mem.indexOf(u8, input, "''") == null) return false;
    var at: usize = 0;
    while (at < input.len) {
        if (quoteOpaqueEnd(input, at, boundaries)) |end| {
            if (starts(input[at..], "[[")) {
                const inner = input[at + 2 .. end - 2];
                if (syntax.delimiter(inner, "|", 0)) |pipe| {
                    if (hasWikiQuoteMarkers(inner[pipe + 1 ..], depth + 1, QuoteBoundaries.init(inner[pipe + 1 ..]))) return true;
                }
            }
            at = end;
        } else {
            if (input[at] == '\'' and quoteRun(input, at) >= 2) return true;
            at += 1;
        }
    }
    return false;
}

fn normalizeWikiQuotes(a: A, input: []const u8, depth: usize, label_scope: bool) Error![]const u8 {
    const boundaries = QuoteBoundaries.init(input);
    if (!hasWikiQuoteMarkers(input, depth, boundaries)) return input;
    var out: std.ArrayList(u8) = .empty;
    var buffer: std.ArrayList(u8) = .empty;
    var line_start: usize = 0;
    while (line_start < input.len) {
        var end = line_start;
        var bold_count: usize = 0;
        var italic_count: usize = 0;
        var single: ?usize = null;
        var multi: ?usize = null;
        var space: ?usize = null;
        while (end < input.len and (label_scope or input[end] != '\n')) {
            if (quoteOpaqueEnd(input, end, boundaries)) |skip| {
                end = skip;
                continue;
            }
            const run = quoteRun(input, end);
            const normalized = if (run == 4) @as(usize, 3) else if (run > 5) @as(usize, 5) else run;
            if (normalized == 2 or normalized == 5) italic_count += 1;
            if (normalized == 3 or normalized == 5) bold_count += 1;
            if (normalized == 3) {
                const x1: u8 = if (run == 4) '\'' else if (end > line_start) input[end - 1] else 0;
                const x2: u8 = if (run == 4 and end > line_start) input[end - 1] else if (end > line_start + 1) input[end - 2] else 0;
                if (x1 == ' ') {
                    if (space == null) space = end;
                } else if (x2 == ' ') {
                    if (single == null) single = end;
                } else if (multi == null) multi = end;
            }
            end += if (run == 0) 1 else run;
        }
        const correction: ?usize = if (bold_count % 2 == 1 and italic_count % 2 == 1)
            (if (single) |at| at else if (multi) |at| at else space)
        else
            null;
        var cursor = line_start;
        var state: QuoteState = .none;
        while (cursor < end) {
            const sink = if (state == .both) &buffer else &out;
            if (quoteOpaqueEnd(input, cursor, boundaries)) |skip| {
                if (starts(input[cursor..], "[[")) {
                    const inner = input[cursor + 2 .. skip - 2];
                    if (syntax.delimiter(inner, "|", 0)) |pipe| {
                        try sink.appendSlice(a, input[cursor .. cursor + 2 + pipe + 1]);
                        try sink.appendSlice(a, try normalizeMisnestedHtml(a, try normalizeWikiQuotes(a, inner[pipe + 1 ..], depth + 1, true)));
                        try sink.appendSlice(a, "]]");
                    } else try sink.appendSlice(a, input[cursor..skip]);
                } else try sink.appendSlice(a, input[cursor..skip]);
                cursor = skip;
                continue;
            }
            const run = quoteRun(input, cursor);
            if (run >= 2) {
                var normalized = if (run == 4) @as(usize, 3) else if (run > 5) @as(usize, 5) else run;
                var literal = if (run == 4) @as(usize, 1) else if (run > 5) run - 5 else 0;
                if (correction != null and correction.? == cursor) {
                    normalized = 2;
                    literal += 1;
                }
                // Encoded extras cannot become fresh quote markers in recursive HTML.
                for (0..literal) |_| try sink.appendSlice(a, "&#39;");
                try quoteTransition(&out, &buffer, a, &state, normalized);
                cursor += run;
            } else {
                try sink.append(a, input[cursor]);
                cursor += 1;
            }
        }
        try quoteFinish(&out, &buffer, a, state);
        if (end < input.len) try out.append(a, '\n');
        line_start = if (end < input.len) end + 1 else end;
    }
    return out.toOwnedSlice(a);
}

pub const Reference = struct { number: usize, group_number: usize, name: []const u8 = "", group: []const u8 = "", body: []const u8 = "", spans: []const Span = &.{} };
pub const ReferenceDefinition = struct { name: []const u8, group: []const u8 = "", body: []const u8 = "" };
pub const ReferenceDefinitions = struct { items: []const ReferenceDefinition = &.{}, fallbacks: @import("presentation_fallback.zig").Report = .{} };

/// Collect names once without rendering reference bodies or creating citations.
pub fn referenceDefinitionsAlloc(a: std.mem.Allocator, source: []const u8) Error!ReferenceDefinitions {
    var renderer: Renderer = .{ .a = a, .context = .{} };
    try renderer.referenceDefinitions(source, "");
    return .{ .items = try renderer.ref_defs.toOwnedSlice(a), .fallbacks = renderer.fallbacks };
}

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
    var colon = syntax.delimiter(text, ":", 0) orelse return null;
    // Links become anchors before MediaWiki's definition-list pass. Reuse the
    // accepted bracketed/free-link extents without changing template delimiters.
    var tokens: ir.InlineIterator = .{ .input = text };
    while (true) {
        const before = tokens.cursor;
        const token = tokens.next() orelse break;
        if (tokens.cursor <= before) break;
        if (tokens.cursor <= colon) continue;
        if (token.kind == .external_link and before <= colon) {
            colon = syntax.delimiter(text, ":", tokens.cursor) orelse return null;
            continue;
        }
        break;
    }
    const term = std.mem.trim(u8, text[0..colon], " \t");
    const definition = std.mem.trim(u8, text[colon + 1 ..], " \t");
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
    external_close_at: ?usize = null,
    label_output_start: usize = 0,
    repair_generated: bool = false,
};
const HtmlNormalizationToken = struct { frame: HtmlNormalizationFrame, closing: bool, end: usize };
const max_html_normalization_frames = max_depth * 4;

// External links are parsed after quotes upstream. Their brackets therefore
// participate in formatting repair, while authored HTML anchors remain literal.
fn htmlNormalizationToken(input: []const u8, at: usize) ?HtmlNormalizationToken {
    if (input[at] == ']') return .{ .frame = .{ .name = "!external", .opener = "", .formatting = true }, .closing = true, .end = at + 1 };
    if (input[at] == '[') {
        if (at + 1 >= input.len or input[at + 1] == '[' or !ir.hasExternalProtocol(input[at + 1 ..])) return null;
        var iterator: ir.InlineIterator = .{ .input = input[at..], .renderer_boundaries = true };
        const token = iterator.next() orelse return null;
        if (token.kind != .external_link) return null;
        const target_end = @intFromPtr(token.target.ptr) - @intFromPtr(input.ptr) + token.target.len;
        return .{ .frame = .{ .name = "!external", .opener = input[at..target_end], .formatting = true, .external_close_at = at + iterator.cursor - 1 }, .closing = false, .end = target_end };
    }
    const tag = syntax.tagAt(input, at) orelse return null;
    if (!normalizableHtmlTag(tag.name) or tag.self_closing) return null;
    return .{ .frame = .{ .name = tag.name, .opener = input[at..tag.end], .formatting = adoptionFormattingTag(tag.name) }, .closing = tag.closing, .end = tag.end };
}
fn htmlNormalizationMatch(frames: []const HtmlNormalizationFrame, token: HtmlNormalizationToken, at: usize) ?usize {
    var index = frames.len;
    while (index != 0) {
        index -= 1;
        if (std.ascii.eqlIgnoreCase(frames[index].name, token.frame.name)) {
            if (frames[index].external_close_at) |close_at| {
                if (close_at != at) continue;
            }
            return index;
        }
    }
    return null;
}
fn hasMisnestedHtml(input: []const u8, depth: usize) bool {
    if (depth >= max_depth) return false;
    const boundaries = QuoteBoundaries.init(input);
    if (std.mem.indexOfScalar(u8, input, '<') == null) return false;
    var frames: [max_html_normalization_frames]HtmlNormalizationFrame = undefined;
    var frame_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, input, pos, "<[]")) |at| {
        if (input[at] == '<') if (syntax.protectedEnd(input, at)) |end| {
            pos = end;
            continue;
        };
        if (starts(input[at..], "[[")) {
            if (boundaries.canClose(input, at)) if (syntax.balanced(input, at)) |pair| {
                const inner = input[at + 2 .. pair.inner_end];
                if (syntax.delimiter(inner, "|", 0)) |pipe| {
                    if (hasMisnestedHtml(inner[pipe + 1 ..], depth + 1)) return true;
                }
                pos = pair.end;
                continue;
            };
            pos = at + 2;
            continue;
        }
        if (input[at] == '<') if (syntax.tagAt(input, at)) |tag| {
            if (!normalizableHtmlTag(tag.name) or tag.self_closing) {
                pos = tag.end;
                continue;
            }
        };
        const token = htmlNormalizationToken(input, at) orelse {
            pos = at + 1;
            continue;
        };
        pos = token.end;
        if (!token.closing) {
            if (frame_count == frames.len) return false;
            frames[frame_count] = token.frame;
            frame_count += 1;
        } else if (htmlNormalizationMatch(frames[0..frame_count], token, at)) |index| {
            if (index + 1 != frame_count) return true;
            frame_count = index;
        }
    }
    return false;
}
fn appendHtmlFrameClose(a: A, out: *std.ArrayList(u8), frame: HtmlNormalizationFrame) Error!void {
    if (frame.external_close_at != null) {
        // Only an empty repair-generated fragment needs a transparent label.
        if (std.mem.trim(u8, out.items[frame.label_output_start..], " \t\r\n").len == 0)
            try out.appendSlice(a, "<span></span>");
        return out.append(a, ']');
    }
    try out.appendSlice(a, "</");
    try out.appendSlice(a, frame.name);
    try out.append(a, '>');
}
fn normalizeMisnestedHtml(a: A, input: []const u8) Error![]const u8 {
    return normalizeMisnestedHtmlDepth(a, input, 0);
}
fn normalizeMisnestedHtmlDepth(a: A, input: []const u8, depth: usize) Error![]const u8 {
    if (!hasMisnestedHtml(input, depth)) return input;
    const boundaries = QuoteBoundaries.init(input);
    var out: std.ArrayList(u8) = .empty;
    var frames: [max_html_normalization_frames]HtmlNormalizationFrame = undefined;
    var frame_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, input, pos, "<[]")) |at| {
        try out.appendSlice(a, input[pos..at]);
        if (input[at] == '<') if (syntax.protectedEnd(input, at)) |end| {
            try out.appendSlice(a, input[at..end]);
            pos = end;
            continue;
        };
        if (starts(input[at..], "[[")) {
            if (boundaries.canClose(input, at)) if (syntax.balanced(input, at)) |pair| {
                const inner = input[at + 2 .. pair.inner_end];
                if (syntax.delimiter(inner, "|", 0)) |pipe| {
                    try out.appendSlice(a, input[at .. at + 2 + pipe + 1]);
                    try out.appendSlice(a, try normalizeMisnestedHtmlDepth(a, inner[pipe + 1 ..], depth + 1));
                    try out.appendSlice(a, "]]");
                } else try out.appendSlice(a, input[at..pair.end]);
                pos = pair.end;
                continue;
            };
            try out.appendSlice(a, input[at .. at + 2]);
            pos = at + 2;
            continue;
        }
        if (input[at] == '<') if (syntax.tagAt(input, at)) |tag| {
            if (!normalizableHtmlTag(tag.name) or tag.self_closing) {
                try out.appendSlice(a, input[at..tag.end]);
                pos = tag.end;
                continue;
            }
        };
        const token = htmlNormalizationToken(input, at) orelse {
            try out.append(a, input[at]);
            pos = at + 1;
            continue;
        };
        const raw = input[at..token.end];
        if (!token.closing) {
            try out.appendSlice(a, raw);
            if (frame_count == frames.len) return input;
            var frame = token.frame;
            if (frame.external_close_at != null) frame.label_output_start = out.items.len;
            frames[frame_count] = frame;
            frame_count += 1;
            pos = token.end;
            continue;
        }
        const index = htmlNormalizationMatch(frames[0..frame_count], token, at) orelse {
            try out.appendSlice(a, raw);
            pos = token.end;
            continue;
        };
        const above = frames[index + 1 .. frame_count];
        var close_index = above.len;
        while (close_index != 0) {
            close_index -= 1;
            try appendHtmlFrameClose(a, &out, above[close_index]);
        }
        const closed = frames[index];
        if (closed.external_close_at != null and closed.repair_generated and
            std.mem.trim(u8, out.items[closed.label_output_start..], " \t\r\n").len == 0)
            try out.appendSlice(a, "<span></span>");
        try out.appendSlice(a, raw);
        var retained: [max_html_normalization_frames]HtmlNormalizationFrame = undefined;
        var retained_len: usize = 0;
        for (above) |frame| if (frame.formatting) {
            retained[retained_len] = frame;
            retained_len += 1;
        };
        frame_count = index;
        for (retained[0..retained_len]) |frame| {
            try out.appendSlice(a, frame.opener);
            var reopened = frame;
            if (frame.external_close_at != null) {
                try out.append(a, ' ');
                reopened.label_output_start = out.items.len;
                reopened.repair_generated = true;
            }
            frames[frame_count] = reopened;
            frame_count += 1;
        }
        pos = token.end;
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
        if (ch < 32 or ch == 127 or std.mem.indexOfScalar(u8, "[]{}", ch) != null) return false;
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
    try std.testing.expect(safeInternalTarget("Tom''s"));
    try std.testing.expect(!safeInternalTarget("[[taking]]"));
    try std.testing.expect(!safeInternalTarget("{{{7}}}"));
    try std.testing.expect(!safeInternalTarget("taking#x[y]"));
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
    block_formatting: SpanFlags = .{},
    refs: std.ArrayList(Reference) = .empty,
    ref_defs: std.ArrayList(ReferenceDefinition) = .empty,
    // Borrowed build-only page definitions. Unused names never become references.
    page_reference_definitions: []const ReferenceDefinition = &.{},
    default_group_reference_count: usize = 0,
    media_caption_spans: std.ArrayList([]const Span) = .empty,
    media: std.ArrayList(media_types.Media) = .empty,
    media_depth: usize = 0,
    spans: std.ArrayList(Span) = .empty,
    in_reference: bool = false,
    semantic_capture: ?*SemanticHints = null,

    fn namespaceOfTarget(self: *const Renderer, title: []const u8) ?i32 {
        const colon = std.mem.indexOfScalar(u8, title, ':') orelse return null;
        const prefix = title[0..colon];
        if (self.context.namespace_catalog) |registry|
            return if (registry.byName(prefix)) |spec| spec.id else null;
        // Canonical standard names are also useful to standalone semantic
        // presentation callers that have no edition-local aliases.
        if (std.ascii.eqlIgnoreCase(prefix, "Category")) return 14;
        if (std.ascii.eqlIgnoreCase(prefix, "File") or std.ascii.eqlIgnoreCase(prefix, "Image")) return 6;
        return null;
    }

    pub fn mediaFile(self: *Renderer, raw: []const u8, caption: []const u8) Error!void {
        return self.mediaFileKind(raw, caption, null);
    }
    fn mediaFileKind(self: *Renderer, raw: []const u8, caption: []const u8, authoritative_kind: ?media_types.Kind) Error!void {
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
        const kind = authoritative_kind orelse media_types.referencedKind(file) orelse return;
        for (self.media.items) |item| if (std.mem.eql(u8, item.file, file)) return;
        if (self.media.items.len >= 128) {
            self.fallbacks.render_limit = true;
            return;
        }
        const caption_spans = try self.parseSpans(caption, .{});
        const description = try plainText(self.a, caption_spans);
        try self.media.append(self.a, .{ .file = file, .kind = kind, .caption = description });
        try self.media_caption_spans.append(self.a, caption_spans);
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
        const flags: SpanFlags = .{ .bold = s.bold, .italic = s.italic, .code = s.code, .small = s.small, .superscript = s.superscript, .subscript = s.subscript, .strike = s.strike, .underline = s.underline };
        const inherited_flags: SpanFlags = @bitCast(@as(u8, @bitCast(flags)) | @as(u8, @bitCast(self.block_formatting)));
        try self.spans.append(self.a, .{ .kind = s.kind, .provenance = s.provenance, .text = value, .target = s.target, .language = s.language, .classes = s.classes, .direction = s.direction, .flags = inherited_flags, .role = s.role });
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
    // Behavior switches act on authored source before link-title decoding.
    // Preserve protected bodies/attributes and entity-authored spellings.
    fn withoutBehaviorControls(self: *Renderer, value: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var emitted: usize = 0;
        var scan: usize = 0;
        while (scan < value.len) {
            if (value[scan] == '<') {
                if (syntax.protectedEnd(value, scan)) |end| {
                    scan = end;
                    continue;
                }
                if (syntax.tagAt(value, scan)) |tag| {
                    scan = tag.end;
                    continue;
                }
            }
            const matched = if (self.context.behavior_switches) |registry|
                try registry.matchAt(self.a, value, scan)
            else
                syntax.behaviorSwitchEnd(value, scan);
            if (matched) |end| {
                try out.appendSlice(self.a, value[emitted..scan]);
                emitted = end;
                scan = end;
            } else scan += 1;
        }
        if (emitted == 0) return value;
        try out.appendSlice(self.a, value[emitted..]);
        return try out.toOwnedSlice(self.a);
    }
    fn plainWithMagicLinks(self: *Renderer, value: []const u8, style: Style) Error!void {
        var emitted: usize = 0;
        var scan: usize = 0;
        while (scan < value.len) {
            const at = scan;
            const matched = if (self.context.behavior_switches) |registry| try registry.matchAt(self.a, value, at) else syntax.behaviorSwitchEnd(value, at);
            if (matched) |end| {
                try self.plainWithMagicLinksVisible(value[emitted..at], style);
                emitted = end;
                scan = end;
            } else scan = at + 1;
        }
        try self.plainWithMagicLinksVisible(value[emitted..], style);
    }
    fn plainWithMagicLinksVisible(self: *Renderer, value: []const u8, style: Style) Error!void {
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

    fn decodeEntity(input: []const u8, buf: *[4]u8, visible_text: bool) ?DecodedEntity {
        const end = std.mem.indexOfScalar(u8, input[0..@min(input.len, 64)], ';') orelse return null;
        if (end < 2) return null;
        const name = input[1..end];
        if (name[0] == '#') {
            const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
            const digits = name[if (hex) @as(usize, 2) else 1..];
            if (digits.len == 0) return null;
            for (digits) |digit| {
                if (!(if (hex) std.ascii.isHex(digit) else std.ascii.isDigit(digit))) return null;
            }
            const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
            // Visible text normalizes references; attributes/URLs retain decoding policy.
            if (visible_text and !(cp == 0x09 or cp == 0x0a or
                (cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xd7ff) or
                (cp >= 0xe000 and cp <= 0xfffd) or (cp >= 0x10000 and cp <= 0x10ffff))) return null;
            const n = std.unicode.utf8Encode(if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else cp, buf) catch return null;
            return .{ .bytes = buf[0..n], .consumed = end + 1, .scratch = true };
        }
        const value = entities.lookupNamedEntity(name) orelse return null;
        return .{ .bytes = value, .consumed = end + 1 };
    }
    fn entity(self: *Renderer, input: []const u8, style: Style) Error!?usize {
        var buf: [4]u8 = undefined;
        const decoded = decodeEntity(input, &buf, true) orelse return null;
        var entity_style = style;
        if (entity_style.provenance == .parsed) entity_style.provenance = .entity_literal;
        try self.text(if (decoded.scratch) try self.a.dupe(u8, decoded.bytes) else decoded.bytes, entity_style);
        return decoded.consumed;
    }
    fn protectedLiteral(self: *Renderer, input: []const u8, style: Style) Error!void {
        var literal_style = style;
        literal_style.provenance = .protected_literal;
        try self.literal(input, literal_style);
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
        if (name.len != 0) for (self.page_reference_definitions) |definition| {
            if (definition.body.len != 0 and std.mem.eql(u8, definition.name, name) and std.mem.eql(u8, definition.group, group)) {
                resolved_body = definition.body;
                break;
            }
        };
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
        try self.referenceDefinitionsInner(content, default_group, 0);
    }
    fn referenceDefinitionsInner(self: *Renderer, content: []const u8, default_group: []const u8, depth: usize) Error!void {
        if (depth >= max_depth) {
            self.fallbacks.render_limit = true;
            return;
        }
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
            if (!tag.closing and tag.is("references")) {
                const pair = syntax.matchingTag(content, tag) orelse continue;
                const own_group = try self.entityText(tag.attr("group") orelse "");
                try self.referenceDefinitionsInner(content[tag.end..pair.inner_end], if (own_group.len != 0) own_group else default_group, depth + 1);
                pos = pair.end;
                continue;
            }
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
            if (!found) {
                if (self.ref_defs.items.len >= max_nodes) {
                    self.fallbacks.render_limit = true;
                    return;
                }
                try self.ref_defs.append(self.a, .{ .name = name, .group = group, .body = body });
            }
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
            const file = if (colon != null and self.namespaceOfTarget(raw_file) == 6) raw_file[colon.? + 1 ..] else raw_file;
            if (media_types.referencedKind(file) == null) continue;
            const options = if (pipe) |at_pipe| trim(line[at_pipe + 1 ..]) else "";
            const selected_label = self.mediaCaptionChoice(options, file, mediaOptionMode(file, true));
            const caption = selected_label.text;
            try self.mediaFile(file, caption);
            if (emitted) try self.lineBreak(style);
            emitted = true;
            var media_style = style;
            media_style.classes = "wikidict-media";
            media_style.kind = .link;
            media_style.target = try std.fmt.allocPrint(self.a, "File:{s}", .{file});
            try self.mediaLabel(if (caption.len == 0) file else caption, media_style, false, selected_label.authored_caption);
        }
    }
    fn imageMap(self: *Renderer, input: []const u8, style: Style, depth: usize) Error!bool {
        var pos: usize = 0;
        var image_seen = false;
        while (pos < input.len) {
            const end = syntax.logicalEnd(input, pos);
            var line = trim(input[pos..end]);
            pos = if (end < input.len) end + 1 else end;
            while (starts(line, "<!--")) {
                const comment_end = syntax.protectedEnd(line, 0) orelse line.len;
                line = trim(line[comment_end..]);
            }
            if (line.len == 0 or line[0] == '#') continue;
            if (!image_seen) {
                const pipe = syntax.delimiter(line, "|", 0) orelse line.len;
                const target = trim(line[0..pipe]);
                if (self.namespaceOfTarget(target) != 6) return false;
                const colon = std.mem.indexOfScalar(u8, target, ':') orelse return false;
                if (media_types.referencedKind(trim(target[colon + 1 ..])) != .image) return false;
                const wrapped = try std.fmt.allocPrint(self.a, "[[{s}]]", .{line});
                const wrapped_pair = syntax.balanced(wrapped, 0) orelse return false;
                if (wrapped_pair.end != wrapped.len) return false;
                try self.inlineText(wrapped, style, depth + 1);
                image_seen = true;
                continue;
            }
            const space = std.mem.indexOfAny(u8, line, " \t") orelse {
                self.fallbacks.unsupported_element = true;
                continue;
            };
            if (std.mem.eql(u8, line[0..space], "desc")) {
                if (!oneOf(trim(line[space..]), &.{ "top-left", "top-right", "bottom-left", "bottom-right", "none" })) self.fallbacks.unsupported_element = true;
                continue;
            }
            if (!oneOf(line[0..space], &.{ "rect", "circle", "poly", "default" })) {
                self.fallbacks.unsupported_element = true;
                continue;
            }
            const link_at = syntax.delimiter(line, "[", space) orelse {
                self.fallbacks.unsupported_element = true;
                continue;
            };
            var coordinates = std.mem.tokenizeAny(u8, line[space..link_at], " \t");
            var count: usize = 0;
            var valid = true;
            while (coordinates.next()) |coordinate| {
                const number = std.fmt.parseFloat(f64, coordinate) catch {
                    valid = false;
                    break;
                };
                if (!std.math.isFinite(number)) valid = false;
                count += 1;
            }
            const command = line[0..space];
            valid = valid and (if (std.mem.eql(u8, command, "rect")) count == 4 else if (std.mem.eql(u8, command, "circle")) count == 3 else if (std.mem.eql(u8, command, "poly")) count >= 6 and count % 2 == 0 else count == 0);
            if (!valid) {
                self.fallbacks.unsupported_element = true;
                continue;
            }
            const internal = starts(line[link_at..], "[[");
            var link_end: usize = undefined;
            var inner_end: usize = undefined;
            if (internal) {
                const pair = syntax.balanced(line, link_at) orelse {
                    self.fallbacks.unsupported_element = true;
                    continue;
                };
                link_end = pair.end;
                inner_end = pair.inner_end;
            } else {
                var cursor = link_at + 1;
                while (cursor < line.len and line[cursor] != ']') {
                    if (syntax.protectedEnd(line, cursor)) |protected_end| cursor = protected_end else cursor += 1;
                }
                if (cursor == line.len) {
                    self.fallbacks.unsupported_element = true;
                    continue;
                }
                inner_end = cursor;
                link_end = cursor + 1;
            }
            var trailing = trim(line[link_end..]);
            while (starts(trailing, "<!--")) trailing = trim(trailing[(syntax.protectedEnd(trailing, 0) orelse trailing.len)..]);
            if (trailing.len != 0) {
                self.fallbacks.unsupported_element = true;
                continue;
            }
            const body = line[link_at + (if (internal) @as(usize, 2) else 1) .. inner_end];
            const separator = if (internal) syntax.delimiter(body, "|", 0) orelse body.len else std.mem.indexOfAny(u8, body, " \t") orelse body.len;
            const target = trim(body[0..separator]);
            const label = if (separator < body.len) trim(body[separator + 1 ..]) else target;
            if (if (internal) target.len == 0 or !safeInternalTarget(target) else !safeUrl(try self.entityText(target))) {
                self.fallbacks.unsupported_element = true;
                continue;
            }
            try self.lineBreak(style);
            try self.link(label, target, style, depth + 1, !internal);
        }
        return image_seen;
    }
    // This is a complete, deliberately small TeX subset. An unbraced
    // superscript consumes one token: 10^12 must not become 10^{12}.
    fn numericPower(self: *Renderer, content: []const u8, style: Style) Error!bool {
        var base_end: usize = 0;
        while (base_end < content.len and std.ascii.isDigit(content[base_end])) : (base_end += 1) {}
        if (base_end == 0 or base_end == content.len or content[base_end] != '^') return false;
        const suffix = content[base_end + 1 ..];
        var exponent = suffix;
        if (suffix.len >= 2 and suffix[0] == '{' and suffix[suffix.len - 1] == '}') {
            exponent = suffix[1 .. suffix.len - 1];
            if (exponent.len == 0) return false;
            for (exponent) |digit| if (!std.ascii.isDigit(digit)) return false;
        } else if (suffix.len != 1 or !std.ascii.isDigit(suffix[0])) return false;

        // No output is emitted until the entire input has matched.
        try self.protectedLiteral(content[0..base_end], style);
        var power_style = style;
        power_style.superscript = true;
        try self.protectedLiteral(exponent, power_style);
        return true;
    }
    fn opaqueExtension(self: *Renderer, input: []const u8, tag: syntax.Tag, style: Style, depth: usize) Error!usize {
        if (tag.self_closing) return tag.end;
        const matched_pair = syntax.matchingTag(input, tag);
        const pair = matched_pair orelse blk: {
            self.fallbacks.unclosed_formatting = true;
            break :blk syntax.Pair{ .inner_end = input.len, .end = input.len };
        };
        const content = input[tag.end..pair.inner_end];
        if (tag.is("math") and matched_pair != null and trim(tag.attrs).len == 0 and try self.numericPower(content, style)) return pair.end;
        if (tag.is("gallery")) {
            try self.gallery(content, style, depth + 1);
        } else if (tag.is("imagemap")) {
            if (!try self.imageMap(content, style, depth + 1)) self.fallbacks.unsupported_element = true;
        } else if (tag.is("poem")) {
            try self.inlineLines(content, style, depth + 1);
        } else if (oneOf(tag.name, &.{ "pre", "source", "syntaxhighlight", "math", "ce", "chem", "score", "timeline", "hiero" })) {
            var literal_style = style;
            literal_style.code = true;
            try self.protectedLiteral(content, literal_style);
            // Readable source is not rendered formula, score or diagram output.
            if (oneOf(tag.name, &.{ "math", "ce", "chem", "score", "timeline", "hiero" })) self.fallbacks.unsupported_element = true;
        } else if (!oneOf(tag.name, &.{ "indicator", "references", "templatestyles", "section", "charinsert" })) {
            // Registered extensions can render data-backed UI that this data-only
            // compiler cannot reproduce. Do not invent substitute prose; report
            // the omission so the final corpus audit names the affected page.
            self.fallbacks.unsupported_element = true;
        }
        return pair.end;
    }
    fn mediaLabel(self: *Renderer, label: []const u8, style: Style, heading: bool, authored_caption: bool) Error!void {
        var caption_style: Style = if (authored_caption) style else .{};
        caption_style.heading = heading;
        caption_style.kind = .text;
        caption_style.target = "";
        const spans = try self.parseSpans(label, caption_style);
        for (spans) |span| {
            var label_style = style;
            label_style.provenance = span.provenance;
            // Authored captions retain visual semantics. Alt and filename
            // fallbacks keep their existing plain flattening and outer style.
            if (authored_caption) {
                label_style.bold = span.flags.bold;
                label_style.italic = span.flags.italic;
                label_style.code = span.flags.code;
                label_style.small = span.flags.small;
                label_style.superscript = span.flags.superscript;
                label_style.subscript = span.flags.subscript;
                label_style.strike = span.flags.strike;
                label_style.underline = span.flags.underline;
                label_style.language = span.language;
                label_style.direction = span.direction;
            }
            if (span.kind == .line_break) {
                try self.lineBreak(label_style);
            } else {
                if (span.kind == .template) {
                    label_style.kind = .template;
                    label_style.target = span.target;
                }
                try self.text(span.text, label_style);
            }
        }
    }
    fn mediaOptionMode(file: []const u8, gallery_mode: bool) @import("namespace_registry").image_options.Mode {
        const ext = std.fs.path.extension(file);
        const timed = media_types.kind(file) == .audio or oneOf(ext, &.{ ".webm", ".ogv", ".mp4" });
        if (gallery_mode) return if (timed) .timed_gallery else .gallery;
        if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf;
        if (std.ascii.eqlIgnoreCase(ext, ".djvu") or std.ascii.eqlIgnoreCase(ext, ".djv")) return .djvu;
        if (std.ascii.eqlIgnoreCase(ext, ".svg")) return .svg;
        return if (timed) .timed else .image;
    }
    fn mediaTime(input: []const u8) bool {
        var parts = std.mem.splitScalar(u8, input, ':');
        var count: usize = 0;
        while (parts.next()) |part| {
            count += 1;
            if (count > 3 or !mediaNumber(trim(part))) return false;
        }
        return true;
    }
    fn mediaOption(self: *Renderer, value: []const u8, mode: @import("namespace_registry").image_options.Mode, seen_format: *bool) ?@import("namespace_registry").image_options.Match {
        const options = @import("namespace_registry").image_options;
        const option = trim(value);
        const found = if (self.context.image_options) |registry| registry.match(option, mode) else options.matchEnglish(option, mode);
        const matched = found orelse return null;
        if (oneOf(matched.id, &.{ "img_thumbnail", "img_framed", "img_frameless", "img_manualthumb" })) {
            const valid = !seen_format.*;
            seen_format.* = true;
            if (!valid) return null;
        } else if (matched.value) |parameter| {
            if (std.mem.eql(u8, matched.id, "img_page")) {
                const page = std.mem.trim(u8, parameter, " \n\r\t\x0b\x00");
                if (mode == .pdf) {
                    if (page.len == 0) return null;
                    for (page) |byte| if (!std.ascii.isDigit(byte)) return null;
                } else {
                    const number = std.fmt.parseInt(i64, page, 10) catch return null;
                    var buffer: [32]u8 = undefined;
                    const canonical = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return null;
                    if (!std.mem.eql(u8, page, canonical)) return null;
                }
            }
            if (std.mem.eql(u8, matched.id, "img_lang") and !mediaLanguageTag(parameter)) return null;
            if (oneOf(matched.id, &.{ "timedmedia_thumbtime", "timedmedia_starttime", "timedmedia_endtime" }) and !mediaTime(parameter)) return null;
            if (std.mem.eql(u8, matched.id, "timedmedia_disablecontrols")) {
                var controls = std.mem.splitScalar(u8, parameter, ',');
                while (controls.next()) |control| {
                    if (!(std.mem.eql(u8, control, "options") or std.mem.eql(u8, control, "timedText") or std.mem.eql(u8, control, "fullscreen"))) return null;
                }
            }
            if (oneOf(matched.id, &.{ "img_upright", "img_left", "img_right", "img_center", "img_none", "img_baseline", "img_sub", "img_super", "img_top", "img_text_top", "img_middle", "img_bottom", "img_text_bottom", "img_border" }) and !mediaNumber(trim(parameter))) return null;
        }
        return matched;
    }
    fn tagAlpha(part: []const u8) bool {
        for (part) |c| if (!std.ascii.isAlphabetic(c)) return false;
        return true;
    }
    fn tagAlnum(part: []const u8) bool {
        for (part) |c| if (!std.ascii.isAlphanumeric(c)) return false;
        return true;
    }
    fn mediaLanguageTag(raw: []const u8) bool {
        // LanguageCode::isWellFormedLanguageTag current retained source, not code registration.
        // PCRE dollar accepts a final LF; no other surrounding whitespace is permitted.
        const input = if (std.mem.endsWith(u8, raw, "\n")) raw[0 .. raw.len - 1] else raw;
        if (oneOf(input, &.{ "en-gb-oed", "i-ami", "i-bnn", "i-default", "i-enochian", "i-hak", "i-klingon", "i-lux", "i-mingo", "i-navajo", "i-pwn", "i-tao", "i-tay", "i-tsu", "no-bok", "no-nyn", "sgn-be-fr", "sgn-be-nl", "sgn-ch-de", "zh-min-nan" })) return true;
        var parts = std.mem.splitScalar(u8, input, '-');
        const primary = parts.next() orelse return false;
        var next = parts.next();
        if (std.ascii.eqlIgnoreCase(primary, "x")) return tagPrivate(next, &parts);
        if (primary.len < 2 or primary.len > 8 or !tagAlpha(primary)) return false;
        if (next) |p| if (primary.len <= 3 and p.len == 3 and tagAlpha(p)) {
            next = parts.next();
        };
        if (next) |p| if (p.len == 4 and tagAlpha(p)) {
            next = parts.next();
        };
        if (next) |p| {
            var region = p.len == 2 and tagAlpha(p);
            if (p.len == 3) {
                region = true;
                for (p) |c| {
                    if (!std.ascii.isDigit(c)) region = false;
                }
            }
            if (region) next = parts.next();
        }
        while (next) |p| {
            if (tagAlnum(p) and ((p.len >= 5 and p.len <= 8) or (p.len == 4 and std.ascii.isDigit(p[0])))) next = parts.next() else break;
        }
        while (next) |p| {
            if (std.ascii.eqlIgnoreCase(p, "x")) return tagPrivate(parts.next(), &parts);
            if (p.len != 1 or !tagAlpha(p)) return false;
            next = parts.next();
            var count: usize = 0;
            while (next) |value| {
                if (value.len < 2 or value.len > 8 or !tagAlnum(value)) break;
                count += 1;
                next = parts.next();
            }
            if (count == 0) return false;
        }
        return true;
    }
    fn tagPrivate(first: ?[]const u8, parts: *std.mem.SplitIterator(u8, .scalar)) bool {
        var next = first;
        if (next == null) return false;
        while (next) |p| {
            if (p.len == 0 or p.len > 8 or !tagAlnum(p)) return false;
            next = parts.next();
        }
        return true;
    }
    fn mediaNumber(input: []const u8) bool {
        // PHP is_numeric's decimal/exponent syntax, without accepting NaN/Inf.
        var cursor: usize = 0;
        if (cursor < input.len and (input[cursor] == '+' or input[cursor] == '-')) cursor += 1;
        var digits: usize = 0;
        while (cursor < input.len and std.ascii.isDigit(input[cursor])) : (cursor += 1) digits += 1;
        if (cursor < input.len and input[cursor] == '.') {
            cursor += 1;
            while (cursor < input.len and std.ascii.isDigit(input[cursor])) : (cursor += 1) digits += 1;
        }
        if (digits == 0) return false;
        if (cursor < input.len and (input[cursor] == 'e' or input[cursor] == 'E')) {
            cursor += 1;
            if (cursor < input.len and (input[cursor] == '+' or input[cursor] == '-')) cursor += 1;
            const begin = cursor;
            while (cursor < input.len and std.ascii.isDigit(input[cursor])) : (cursor += 1) {}
            if (begin == cursor) return false;
        }
        return cursor == input.len;
    }
    const MediaLabelChoice = struct { text: []const u8, authored_caption: bool };
    fn mediaCaption(self: *Renderer, raw: []const u8, fallback: []const u8, mode: @import("namespace_registry").image_options.Mode) []const u8 {
        return self.mediaCaptionChoice(raw, fallback, mode).text;
    }
    fn mediaCaptionChoice(self: *Renderer, raw: []const u8, fallback: []const u8, mode: @import("namespace_registry").image_options.Mode) MediaLabelChoice {
        var candidate: []const u8 = "";
        var seen_format = false;
        var pos: usize = 0;
        while (pos <= raw.len) {
            const end = syntax.delimiter(raw, "|", pos) orelse raw.len;
            const part = trim(raw[pos..end]);
            if (self.mediaOption(part, mode, &seen_format) == null) candidate = part;
            if (end == raw.len) break;
            pos = end + 1;
        }
        return .{ .text = if (candidate.len == 0) fallback else candidate, .authored_caption = candidate.len != 0 };
    }
    fn mediaHeadingCaption(self: *Renderer, raw: []const u8, file: []const u8) MediaLabelChoice {
        var caption: []const u8 = "";
        var alt: []const u8 = "";
        var seen_format = false;
        var pos: usize = 0;
        while (pos <= raw.len) {
            const end = syntax.delimiter(raw, "|", pos) orelse raw.len;
            const part = trim(raw[pos..end]);
            if (self.mediaOption(part, mediaOptionMode(file, false), &seen_format)) |matched| {
                if (std.mem.eql(u8, matched.id, "img_alt")) alt = trim(matched.value orelse "");
            } else caption = part;
            if (end == raw.len) break;
            pos = end + 1;
        }
        return .{ .text = if (caption.len != 0) caption else alt, .authored_caption = caption.len != 0 };
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
            try self.protectedLiteral(input[tag.end..pair.inner_end], s);
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
                if (std.mem.eql(u8, class, "scribunto-error")) self.fallbacks.rendered_lua_error = true;
                if (std.mem.eql(u8, class, "ext-phonos-error")) self.fallbacks.rendered_extension_error = true;
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
        s = try self.htmlLanguageDirection(tag, s);
        const content = input[tag.end..pair.inner_end];
        // This attribute is emitted only after the runtime validates captured
        // AUDIO metadata. Keep canonical file, caption and language independent.
        if (tag.is("span")) if (tag.attr("data-phonos-audio")) |raw_file| {
            try self.mediaFileKind(try self.entityText(raw_file), content, .audio);
        };
        if (tag.is("ol") or tag.is("ul") or tag.is("dl")) {
            // Span-only containers, including ordinary table cells, still need
            // the same list counters and nesting as block HTML. Flatten those
            // semantic blocks instead of converting every li to a bullet.
            var list_blocks: std.ArrayList(Block) = .empty;
            try self.htmlList(&list_blocks, content, tag, "", depth + 1, s);
            if (list_blocks.items.len == 0) return pair.end;
            if (self.spans.items.len != 0 and self.spans.items[self.spans.items.len - 1].kind != .line_break)
                try self.lineBreak(s);
            try self.blocksInline(list_blocks.items, s);
            try self.lineBreak(s);
            return pair.end;
        }
        const block_boundary = oneOf(tag.name, &.{ "p", "div", "blockquote", "center", "li", "dt", "dd", "tr", "h1", "h2", "h3", "h4", "h5", "h6" });
        // An inline block opener separates preceding lexical text from its body.
        // Keep empty bodies and adjacent block boundaries on the existing path.
        if (block_boundary and trim(content).len != 0 and self.spans.items.len != 0 and
            self.spans.items[self.spans.items.len - 1].kind != .line_break)
            try self.lineBreak(style);
        if (tag.is("li")) try self.text("• ", style);
        const annotation = tag.is("rt") or tag.is("rtc");
        const parenthetical = annotation and style.ruby_parentheses;
        if (tag.is("ruby")) s.ruby_parentheses = !rubyHasFallback(content);
        if (annotation) s.ruby_parentheses = false;
        const annotation_start = self.spans.items.len;
        if (parenthetical) try self.text("（", s);
        if (std.mem.indexOf(u8, content, "{|") != null) {
            try self.blocksInline(try self.renderBody(content), s);
        } else try self.inlineText(content, s, depth + 1);
        if (parenthetical and annotation_start < self.spans.items.len and
            std.mem.eql(u8, self.spans.items[annotation_start].text, "（"))
        {
            var visible = false;
            for (self.spans.items[annotation_start + 1 ..]) |span| {
                if (trim(span.text).len != 0) {
                    visible = true;
                    break;
                }
            }
            if (visible) try self.text("）", s) else _ = self.spans.orderedRemove(annotation_start);
        }
        if (block_boundary) try self.lineBreak(style);
        return pair.end;
    }
    fn entityText(self: *Renderer, value: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, value, '&') == null) return value;
        var out: std.ArrayList(u8) = .empty;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, start, '&')) |i| {
            try out.appendSlice(self.a, value[start..i]);
            var buf: [4]u8 = undefined;
            if (decodeEntity(value[i..], &buf, false)) |decoded| {
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
                    const opener_len: usize = if (starts(input[it.cursor..], "{{{")) 3 else 2;
                    try self.plain(input[it.cursor .. it.cursor + opener_len], s);
                    it.cursor += opener_len;
                    continue;
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
            const token_start = it.cursor;
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
                    // An authored inner opener is a separate link. Keep the
                    // malformed outer prefix/suffix visible; never navigate to
                    // a bracket-bearing target or reparse decoded entities.
                    if (std.mem.indexOf(u8, target, "[[") != null) {
                        if (syntax.delimiter(target, "[[", 0)) |nested| {
                            const raw_start = token_start + std.mem.indexOf(u8, input[token_start..it.cursor], "[[").?;
                            const nested_start = @intFromPtr(token.target.ptr) - @intFromPtr(input.ptr) + nested;
                            var literal_style = s;
                            literal_style.kind = .text;
                            literal_style.target = "";
                            self.fallbacks.literal_markup = true;
                            try self.plain(try self.entityText(try self.withoutBehaviorControls(input[raw_start..nested_start])), literal_style);
                            try self.inlineText(input[nested_start..it.cursor], literal_style, depth + 1);
                            continue;
                        }
                    }
                    const authored_target = target;
                    target = try self.withoutBehaviorControls(target);
                    if (target.len != authored_target.len) {
                        target = std.mem.trim(u8, target, " \t");
                        const title_part = if (starts(target, ":")) std.mem.trim(u8, target[1..], " \t") else target;
                        const namespace_only = if (self.namespaceOfTarget(title_part) != null)
                            std.mem.trim(u8, title_part[std.mem.indexOfScalar(u8, title_part, ':').? + 1 ..], " \t").len == 0
                        else
                            false;
                        if (title_part.len == 0 or namespace_only) {
                            // A missing title (including an empty namespace title)
                            // is literal syntax, not category membership or media.
                            const raw_start = token_start + std.mem.indexOf(u8, input[token_start..it.cursor], "[[").?;
                            var literal_style = s;
                            literal_style.kind = .text;
                            literal_style.target = "";
                            if (token.link_has_pipe) {
                                const label_start = @intFromPtr(token.text.ptr) - @intFromPtr(input.ptr);
                                try self.plain(try self.entityText(try self.withoutBehaviorControls(input[raw_start..label_start])), literal_style);
                                // Invalid outer syntax still leaves authored label
                                // emphasis, HTML and inner links eligible for parsing.
                                try self.inlineText(input[label_start..it.cursor], literal_style, depth + 1);
                            } else {
                                try self.plain(try self.entityText(try self.withoutBehaviorControls(input[raw_start..it.cursor])), literal_style);
                            }
                            continue;
                        }
                    }
                    target = try self.entityText(target);
                    if (std.mem.indexOfAny(u8, target, "[]{}") != null) {
                        const raw_start = token_start + std.mem.indexOf(u8, input[token_start..it.cursor], "[[").?;
                        var literal_style = s;
                        literal_style.kind = .text;
                        literal_style.target = "";
                        self.fallbacks.literal_markup = true;
                        // Undefined parameters and encoded invalid targets are
                        // literal output, not another expansion/label input.
                        try self.plain(try self.entityText(try self.withoutBehaviorControls(input[raw_start..it.cursor])), literal_style);
                        continue;
                    }
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
                    // Ordinary links cannot contain another link in their label.
                    // Preserve malformed outer text even when it would not navigate.
                    // Non-explicit File namespace links intentionally allow captions.
                    if (token.link_has_pipe and (explicit or self.namespaceOfTarget(target) != 6)) {
                        if (syntax.delimiter(label_value, "[[", 0) != null) {
                            const raw_start = token_start + std.mem.indexOf(u8, input[token_start..it.cursor], "[[").?;
                            const label_start = @intFromPtr(label_value.ptr) - @intFromPtr(input.ptr);
                            var literal_style = s;
                            literal_style.kind = .text;
                            literal_style.target = "";
                            self.fallbacks.literal_markup = true;
                            // Only the outer opener is literal. Parse the entire label
                            // together so emphasis and HTML can span the inner link.
                            try self.plain(try self.entityText(try self.withoutBehaviorControls(input[raw_start..label_start])), literal_style);
                            try self.inlineText(input[label_start..it.cursor], literal_style, depth + 1);
                            continue;
                        }
                    }
                    if (!explicit and self.namespaceOfTarget(target) == 14) {
                        try self.text(trail, s);
                        continue;
                    }
                    if (!explicit and self.namespaceOfTarget(target) == 6) {
                        const file_name = target[(std.mem.indexOfScalar(u8, target, ':').? + 1)..];
                        var selected_label = self.mediaCaptionChoice(label_value, file_name, mediaOptionMode(file_name, false));
                        selected_label.authored_caption = token.link_has_pipe and selected_label.authored_caption;
                        label_value = selected_label.text;
                        // Keep newly eligible SVG heading decoration out of entry media.
                        if (!s.heading or media_types.kind(file_name) != null) try self.mediaFile(file_name, label_value);
                        if (s.heading) {
                            selected_label = self.mediaHeadingCaption(if (token.link_has_pipe) token.text else "", file_name);
                            label_value = selected_label.text;
                        }
                        var media_style = s;
                        media_style.classes = "wikidict-media";
                        media_style.kind = .link;
                        media_style.target = try std.fmt.allocPrint(self.a, "File:{s}", .{file_name});
                        try self.mediaLabel(label_value, media_style, s.heading, selected_label.authored_caption);
                    } else {
                        if (label_value.len == 0) label_value = pipeTrickLabel(target);
                        if (safeInternalTarget(target)) {
                            if (!token.link_has_pipe) {
                                // The decoded default label is title text, not another wikitext input.
                                var link_style = s;
                                link_style.kind = .link;
                                link_style.target = target;
                                try self.text(label_value, link_style);
                            } else {
                                try self.link(label_value, target, s, depth + 1, false);
                            }
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
                .external_link => {
                    const label = if (token.external_label_prefix.len != 0)
                        try std.fmt.allocPrint(self.a, "{s} {s}", .{ token.external_label_prefix, token.text })
                    else
                        token.text;
                    if (inherited.kind == .link or inherited.kind == .external_link) {
                        if (token.external_label_prefix.len != 0 or std.mem.eql(u8, token.text, token.target))
                            try self.literal(label, s)
                        else
                            try self.text(label, s);
                    } else try self.link(label, token.target, s, depth + 1, true);
                },
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
        try self.inlineText(try normalizeMisnestedHtml(self.a, try normalizeWikiQuotes(self.a, input, 0, false)), style, 0);
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
    fn protectedBlock(self: *Renderer, list: *std.ArrayList(Block), raw: []const u8) Error!void {
        const parent = self.spans;
        self.spans = .empty;
        defer self.spans = parent;
        try self.protectedLiteral(raw, .{ .code = true });
        try self.appendBlockBudgeted(list, .{ .kind = .preformatted, .spans = try self.spans.toOwnedSlice(self.a) });
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
        } else try self.parseSpans(raw, .{ .heading = kind == .heading });
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
    fn blockFormattingFlags(tag: syntax.Tag) ?SpanFlags {
        // Attribute-bearing wrappers still need the ordinary inline HTML path,
        // which retains their language, classes, direction and semantic role.
        if (tag.closing or tag.self_closing or tag.attrs.len != 0) return null;
        if (oneOf(tag.name, &.{ "b", "strong" })) return .{ .bold = true };
        if (oneOf(tag.name, &.{ "i", "em", "cite", "var", "dfn" })) return .{ .italic = true };
        if (oneOf(tag.name, &.{ "u", "ins" })) return .{ .underline = true };
        if (oneOf(tag.name, &.{ "s", "del", "strike" })) return .{ .strike = true };
        if (tag.is("sup")) return .{ .superscript = true };
        if (tag.is("sub")) return .{ .subscript = true };
        if (tag.is("small")) return .{ .small = true };
        if (oneOf(tag.name, &.{ "code", "tt", "kbd", "samp" })) return .{ .code = true };
        return null;
    }
    fn endsAfterLaterWikiListLine(input: []const u8) bool {
        // Reuse logical lines so markers inside comments, nowiki or balanced
        // template/link payloads cannot create a new block boundary.
        var at = syntax.logicalEnd(input, 0);
        if (at == input.len) return false;
        at += 1;
        var ends_with_list = false;
        while (at < input.len) {
            const end = syntax.logicalEnd(input, at);
            if (trim(input[at..end]).len != 0)
                ends_with_list = end > at and std.mem.indexOfScalar(u8, "#*:;", input[at]) != null;
            at = if (end < input.len) end + 1 else end;
        }
        return ends_with_list;
    }
    pub fn renderBody(self: *Renderer, input: []const u8) Error![]const Block {
        return self.renderBodyWithInlineStart(input, false);
    }
    fn renderBodyWithInlineStart(self: *Renderer, input: []const u8, initial_inline: bool) Error![]const Block {
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
        var inline_line_end = if (initial_inline) (std.mem.indexOfScalar(u8, input, '\n') orelse input.len) else 0;
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
            // Expansion can introduce a block newline immediately inside a
            // balanced formatting wrapper, e.g. <small>\n* notice</small>.
            // Match across the whole body before line splitting discards that
            // wrapper. Keep list/table structure and inherit its flags while
            // rendering the enclosed blocks; never repair unmatched markup.
            if (clean.ptr == line.ptr) if (syntax.tagAt(clean, 0)) |tag| {
                if (blockFormattingFlags(tag)) |flags| {
                    const offset = @intFromPtr(clean.ptr) - @intFromPtr(input.ptr);
                    const rest = input[offset..];
                    if (syntax.matchingTag(rest, tag)) |pair| {
                        const closing_line_end = std.mem.indexOfScalarPos(u8, rest, pair.end, '\n') orelse rest.len;
                        // A same-line suffix belongs to its existing inline
                        // block and must not be split off by this path.
                        const first_line_inline = trim(clean[tag.end..]).len != 0;
                        if ((!first_line_inline or (para == null and endsAfterLaterWikiListLine(rest[tag.end..pair.inner_end]))) and
                            trim(rest[pair.end..closing_line_end]).len == 0)
                        {
                            if (para) |p| {
                                try self.paragraph(&blocks, input[p..start]);
                                para = null;
                            }
                            const parent_formatting = self.block_formatting;
                            self.block_formatting = @bitCast(@as(u8, @bitCast(parent_formatting)) | @as(u8, @bitCast(flags)));
                            defer self.block_formatting = parent_formatting;
                            // Removing an inline opener must not move its same-line
                            // text to a wiki line start. Later physical lines retain
                            // normal list/heading/preformatted interpretation.
                            try blocks.appendSlice(self.a, try self.renderBodyWithInlineStart(rest[tag.end..pair.inner_end], first_line_inline));
                            pos = offset + closing_line_end;
                            if (pos < input.len) pos += 1;
                            @memset(&counts, 0);
                            list_root = 0;
                            continue;
                        }
                    }
                }
            };
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
            const control_matcher: ?syntax.ControlMatcher = if (self.context.behavior_switches) |registry| .{
                .ctx = registry,
                .match = struct {
                    fn match(raw: ?*const anyopaque, value: []const u8, at: usize) ?usize {
                        const profile: *const @import("namespace_registry").behavior_switches.Registry = @ptrCast(@alignCast(raw.?));
                        return profile.matchAt(std.heap.page_allocator, value, at) catch null;
                    }
                }.match,
            } else null;
            const anchored_inline = start < inline_line_end;
            const heading = if (anchored_inline) null else headingLine(syntax.headingControlPrefix(line, control_matcher));
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
            const list_line = line[if (anchored_inline) 0 else syntax.leadingBehaviorControlOffset(line, control_matcher)..];
            var prefix: usize = 0;
            while (!anchored_inline and prefix < list_line.len and std.mem.indexOfScalar(u8, "#*:;", list_line[prefix]) != null) : (prefix += 1) {}
            const table_indent: ?[]const u8 = if (anchored_inline) null else wikiTableIndent(clean);
            const html_tag = if (syntax.tagAt(clean, 0)) |tag| (if (!tag.closing and
                oneOf(tag.name, &.{ "table", "div", "blockquote", "p", "ul", "ol", "dl", "center" }) and
                syntax.matchingTag(clean, tag) != null) tag else null) else null;
            const protected_tag = if (syntax.tagAt(clean, 0)) |tag| (if (!tag.closing and
                (tag.is("pre") or tag.is("syntaxhighlight"))) tag else null) else null;
            const special = html_tag != null or protected_tag != null or multiline_data != null or clean.len == 0 or heading != null or prefix != 0 or (!anchored_inline and (starts(line, " ") or table_indent != null or starts(clean, "----")));
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
                            // Literal extension bodies and comments are not table wrappers.
                            if (content[cursor] == '<') if (syntax.protectedEnd(content, cursor)) |protected_end| {
                                try body.appendSlice(self.a, content[cursor..protected_end]);
                                cursor = protected_end;
                                continue;
                            };
                            if (content[cursor] == '<') if (syntax.tagAt(content, cursor)) |cell| {
                                // Keep ordinary tags whole so quoted attribute text is not rescanned.
                                if (!oneOf(cell.name, &.{ "tr", "td", "th", "tbody" }))
                                    try body.appendSlice(self.a, content[cursor..cell.end]);
                                cursor = cell.end;
                                continue;
                            };
                            try body.append(self.a, content[cursor]);
                            cursor += 1;
                        }
                        try blocks.appendSlice(self.a, try self.renderBody(body.items));
                    } else {
                        var fostered: std.ArrayList(Block) = .empty;
                        if (try self.htmlTable(clean[tag.end..pair.inner_end], &fostered)) |table_value| {
                            try blocks.appendSlice(self.a, fostered.items);
                            try self.appendBlockBudgeted(&blocks, .{ .kind = .table, .table = table_value });
                        } else try self.block(&blocks, .preformatted, clean[0..pair.end], "", "", 0);
                    }
                } else if (tag.is("ul") or tag.is("ol") or tag.is("dl")) {
                    try self.htmlList(&blocks, clean[tag.end..pair.inner_end], tag, "", 0, .{});
                } else try blocks.appendSlice(self.a, try self.renderBodyWithInlineStart(clean[tag.end..pair.inner_end], true));
                pos = @intFromPtr(clean.ptr) - @intFromPtr(input.ptr) + pair.end;
                if (pos < input.len and input[pos] == '\n') {
                    pos += 1;
                } else if (pos < input.len) {
                    // A balanced block wrapper does not create a physical line
                    // boundary for following heading/list/table syntax.
                    inline_line_end = syntax.logicalEnd(input, pos);
                }
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
            if (table_indent) |table_path| {
                if (table_path.len != 0) {
                    const root = listRoot(':');
                    if (list_root != 0 and list_root != root) @memset(&counts, 0);
                    list_root = root;
                }
                const body_start = pos;
                const table = try self.parseTable(input, pos);
                pos = table.end;
                // A close-marker suffix remains on its authored physical line;
                // it cannot introduce a new wiki list, heading or leading-space block.
                if (pos != 0 and pos < input.len and input[pos - 1] != '\n')
                    inline_line_end = syntax.logicalEnd(input, pos);
                if (table.table.rows.len != 0 or table.has_caption) {
                    try blocks.appendSlice(self.a, try self.indentTableBlocks(table.fostered, table_path));
                    try self.appendBlockBudgeted(&blocks, .{ .kind = .table, .table = table.table, .depth = @intCast(@min(table_path.len, 255)), .list_path = table_path[0..@min(table_path.len, 255)] });
                } else {
                    self.fallbacks.malformed_table = true;
                    // Rowless layout tables still contain ordinary lists/text.
                    for (try self.indentTableBlocks(try self.renderBody(input[body_start..table.body_end]), table_path)) |block_value|
                        try self.appendBlockBudgeted(&blocks, block_value);
                }
                continue;
            }
            if (protected_tag) |tag| {
                const pair = syntax.matchingTag(clean, tag) orelse syntax.Pair{ .inner_end = clean.len, .end = clean.len };
                try self.protectedBlock(&blocks, clean[tag.end..pair.inner_end]);
                pos = @intFromPtr(clean.ptr) - @intFromPtr(input.ptr) + pair.end;
                if (pos < input.len and input[pos] == '\n') {
                    pos += 1;
                } else if (pos < input.len) {
                    // Text after a protected close stays outside its literal body,
                    // on the existing line rather than a new wiki block start.
                    inline_line_end = syntax.logicalEnd(input, pos);
                }
                continue;
            }
            if (starts(line, " ")) {
                // Leading-space preformatting preserves whitespace, but unlike
                // <pre>/<syntaxhighlight> it still interprets inline markup.
                try self.appendBlockBudgeted(&blocks, .{ .kind = .preformatted, .spans = try self.parseSpans(line[1..], .{ .code = true }) });
                continue;
            }
            if (prefix != 0) {
                const path = list_line[0..prefix];
                const root = listRoot(path[0]);
                if (list_root != 0 and list_root != root) @memset(&counts, 0);
                list_root = root;
                const body = std.mem.trimStart(u8, list_line[prefix..], " \t");
                if (path[path.len - 1] == ';') if (inlineDefinitionSplit(body)) |pair| {
                    const detail_path = try self.a.dupe(u8, path);
                    detail_path[detail_path.len - 1] = ':';
                    try self.block(&blocks, .term, pair.term, path, "", 0);
                    try self.block(&blocks, .list_detail, pair.definition, detail_path, "", 0);
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
    fn htmlLanguageDirection(self: *Renderer, tag: syntax.Tag, inherited: Style) Error!Style {
        var result = inherited;
        if (tag.attr("lang")) |lang| result.language = try self.entityText(lang);
        if (tag.attr("dir")) |dir| {
            const decoded_dir = try self.entityText(dir);
            if (std.ascii.eqlIgnoreCase(decoded_dir, "ltr")) result.direction = "ltr" else if (std.ascii.eqlIgnoreCase(decoded_dir, "rtl")) result.direction = "rtl" else if (std.ascii.eqlIgnoreCase(decoded_dir, "auto")) result.direction = "auto";
        }
        return result;
    }
    fn htmlList(self: *Renderer, blocks: *std.ArrayList(Block), input: []const u8, list_tag: syntax.Tag, parent_path: []const u8, depth: usize, style: Style) Error!void {
        if (depth >= max_depth) {
            self.fallbacks.render_limit = true;
            try self.block(blocks, .preformatted, input, parent_path, "", 0);
            return;
        }
        // Apply explicit container fields after inherited parent-item fields.
        const list_style = try self.htmlLanguageDirection(list_tag, style);
        const reversed = list_tag.is("ol") and htmlAttributePresent(list_tag, "reversed");
        const default_start: i32 = if (reversed) htmlListItemCount(input) else 1;
        var ordinal: i32 = if (list_tag.attr("start")) |value| std.fmt.parseInt(i32, trim(try self.entityText(value)), 10) catch default_start else default_start;
        const number_style = if (list_tag.attr("type")) |value| htmlListNumberStyle(try self.entityText(value)) orelse .decimal else .decimal;
        var cursor: usize = 0;
        var preceding: usize = 0;
        while (std.mem.indexOfScalarPos(u8, input, cursor, '<')) |at| {
            if (self.truncated) break;
            if (syntax.protectedEnd(input, at)) |end| {
                cursor = end;
                continue;
            }
            const item = syntax.tagAt(input, at) orelse {
                cursor = at + 1;
                continue;
            };
            cursor = item.end;
            const accepted = !item.closing and (if (list_tag.is("dl")) item.is("dt") or item.is("dd") else item.is("li"));
            if (!accepted) {
                if (!item.closing and (item.is("ul") or item.is("ol") or item.is("dl") or item.is("table"))) {
                    if (syntax.matchingTag(input, item)) |pair| cursor = pair.end;
                }
                continue;
            }
            try blocks.appendSlice(self.a, try self.renderBody(input[preceding..at]));
            const pair = optionalListItemEnd(input, item);
            const mark: u8 = if (list_tag.is("ol")) '#' else if (list_tag.is("ul")) '*' else if (item.is("dt")) ';' else ':';
            const path = try std.fmt.allocPrint(self.a, "{s}{c}", .{ parent_path, mark });
            var number: []const u8 = "";
            if (list_tag.is("ol")) {
                if (item.attr("value")) |value| ordinal = std.fmt.parseInt(i32, trim(try self.entityText(value)), 10) catch ordinal;
                const item_style = if (item.attr("type")) |value| htmlListNumberStyle(try self.entityText(value)) orelse number_style else number_style;
                const label = try self.htmlListNumber(ordinal, item_style);
                number = label;
                if (reversed) ordinal -|= 1 else ordinal +|= 1;
            }
            const kind: Kind = if (mark == '#' or mark == '*') .list_item else if (mark == ';') .term else .list_detail;
            try self.htmlListItem(blocks, input[item.end..pair.inner_end], kind, path, number, item, depth, list_style);
            cursor = pair.end;
            preceding = cursor;
        }
        try blocks.appendSlice(self.a, try self.renderBody(input[preceding..]));
    }
    fn htmlListNumber(self: *Renderer, ordinal: i32, style: HtmlListNumberStyle) Error![]const u8 {
        if (style == .decimal or ordinal <= 0 or ((style == .lower_roman or style == .upper_roman) and ordinal > 3999))
            return std.fmt.allocPrint(self.a, "{d}", .{ordinal});
        if (style == .lower_alpha or style == .upper_alpha) {
            var buffer: [7]u8 = undefined;
            var begin = buffer.len;
            var value: u32 = @intCast(ordinal);
            while (value != 0) {
                value -= 1;
                begin -= 1;
                buffer[begin] = @as(u8, if (style == .lower_alpha) 'a' else 'A') + @as(u8, @intCast(value % 26));
                value /= 26;
            }
            return self.a.dupe(u8, buffer[begin..]);
        }
        const values = [_]i32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
        const labels = [_][]const u8{ "M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I" };
        var result: std.ArrayList(u8) = .empty;
        var value = ordinal;
        for (values, labels) |amount, label| {
            while (value >= amount) : (value -= amount) try result.appendSlice(self.a, label);
        }
        if (style == .lower_roman) for (result.items) |*byte| {
            byte.* = std.ascii.toLower(byte.*);
        };
        return result.toOwnedSlice(self.a);
    }
    fn htmlListItem(self: *Renderer, blocks: *std.ArrayList(Block), input: []const u8, kind: Kind, path: []const u8, number: []const u8, item: syntax.Tag, depth: usize, style: Style) Error!void {
        var cursor: usize = 0;
        var preceding: usize = 0;
        var emitted = false;
        while (std.mem.indexOfScalarPos(u8, input, cursor, '<')) |at| {
            if (self.truncated) break;
            if (syntax.protectedEnd(input, at)) |end| {
                cursor = end;
                continue;
            }
            const tag = syntax.tagAt(input, at) orelse {
                cursor = at + 1;
                continue;
            };
            cursor = tag.end;
            if (tag.closing or !(tag.is("ul") or tag.is("ol") or tag.is("dl") or tag.is("table"))) continue;
            const pair = syntax.matchingTag(input, tag) orelse continue;
            try self.htmlListItemPart(blocks, input[preceding..at], if (emitted) .list_detail else kind, path, if (emitted) "" else number, item, !emitted, style);
            emitted = true;
            if (tag.is("table")) {
                const nested = try self.renderBody(input[at..pair.end]);
                for (nested) |block_value| {
                    var child = block_value;
                    child.list_path = try std.fmt.allocPrint(self.a, "{s}:", .{path});
                    child.depth = @intCast(@min(child.list_path.len, 255));
                    if (child.kind == .paragraph) child.kind = .list_detail;
                    try self.appendBlockBudgeted(blocks, child);
                }
            } else try self.htmlList(blocks, input[tag.end..pair.inner_end], tag, path, depth + 1, try self.htmlLanguageDirection(item, style));
            cursor = pair.end;
            preceding = cursor;
        }
        try self.htmlListItemPart(blocks, input[preceding..], if (emitted) .list_detail else kind, path, if (emitted) "" else number, item, !emitted, style);
    }
    fn htmlListItemPart(self: *Renderer, blocks: *std.ArrayList(Block), input: []const u8, kind: Kind, path: []const u8, number: []const u8, item: syntax.Tag, keep_empty: bool, style: Style) Error!void {
        // Reuse semantic attribute/style handling while removing only the list
        // marker tag. Its li identity must not reach the inline bullet path.
        const styled = try std.fmt.allocPrint(self.a, "<span{s}>{s}</span>", .{ item.attrs, input });
        const spans = try self.parseSpans(styled, style);
        if (!keep_empty and trim(try plainText(self.a, spans)).len == 0) return;
        const effective_path = if (kind == .list_detail and (path[path.len - 1] == '*' or path[path.len - 1] == '#')) try std.fmt.allocPrint(self.a, "{s}:", .{path}) else path;
        try self.appendBlockBudgeted(blocks, .{ .kind = kind, .spans = spans, .depth = @intCast(@min(effective_path.len, 255)), .list_path = effective_path, .number = number });
    }
    fn htmlTableFostered(self: *Renderer, blocks: *std.ArrayList(Block), input: []const u8, joinable: *bool, formatting: *std.ArrayList([]const u8)) Error!void {
        // HTML moves non-cell table content before the table. Preserve that
        // visible content in ordinary blocks, never in a fabricated caption.
        var source: std.ArrayList(u8) = .empty;
        for (formatting.items) |opening| try source.appendSlice(self.a, opening);
        var local_blocks: std.ArrayList([]const u8) = .empty;
        var at: usize = 0;
        while (at < input.len) {
            if (input[at] == '<') {
                if (syntax.protectedEnd(input, at)) |end| {
                    try source.appendSlice(self.a, input[at..end]);
                    at = end;
                    continue;
                }
                if (syntax.tagAt(input, at)) |tag| {
                    if (!tag.closing and (tag.is("td") or tag.is("th"))) {
                        at = optionalTableEnd(input, tag).end;
                        continue;
                    }
                    if (!tag.closing and tag.is("caption")) if (syntax.matchingTag(input, tag)) |pair| {
                        at = pair.end;
                        continue;
                    };
                    if (oneOf(tag.name, &.{ "tbody", "thead", "tfoot", "tr", "td", "th", "caption" })) {
                        at = tag.end;
                        continue;
                    }
                    if (!tag.closing and oneOf(tag.name, &.{ "script", "style", "iframe", "object", "embed" })) {
                        if (syntax.matchingTag(input, tag)) |pair| {
                            try source.appendSlice(self.a, input[at..pair.end]);
                            at = pair.end;
                            continue;
                        }
                    }
                    const reconstruct = oneOf(tag.name, &.{ "b", "big", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u" });
                    const layout = oneOf(tag.name, &.{ "div", "p", "blockquote", "center" });
                    if (reconstruct or layout) {
                        const stack = if (reconstruct) formatting else &local_blocks;
                        if (tag.closing) {
                            var index = stack.items.len;
                            while (index != 0) {
                                index -= 1;
                                const opening = syntax.tagAt(stack.items[index], 0).?;
                                if (std.ascii.eqlIgnoreCase(opening.name, tag.name)) {
                                    stack.shrinkRetainingCapacity(index);
                                    break;
                                }
                            }
                        } else if (!tag.self_closing and stack.items.len < max_depth) try stack.append(self.a, input[at..tag.end]);
                    }
                    try source.appendSlice(self.a, input[at..tag.end]);
                    at = tag.end;
                    continue;
                }
            }
            try source.append(self.a, input[at]);
            at += 1;
        }
        // Cell entry pops layout wrappers; active HTML formatting elements
        // are reconstructed for subsequent fostered text, not for cell text.
        var closing = local_blocks.items.len;
        while (closing != 0) {
            closing -= 1;
            const tag = syntax.tagAt(local_blocks.items[closing], 0).?;
            try source.appendSlice(self.a, try std.fmt.allocPrint(self.a, "</{s}>", .{tag.name}));
        }
        closing = formatting.items.len;
        while (closing != 0) {
            closing -= 1;
            const tag = syntax.tagAt(formatting.items[closing], 0).?;
            try source.appendSlice(self.a, try std.fmt.allocPrint(self.a, "</{s}>", .{tag.name}));
        }
        var explicit_blocks = false;
        var lines = std.mem.splitScalar(u8, source.items, '\n');
        while (lines.next()) |line| {
            if (line.len != 0 and (std.mem.indexOfScalar(u8, "*#;:=", line[0]) != null or starts(line, "{|"))) explicit_blocks = true;
        }
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, source.items, cursor, '<')) |open| {
            if (syntax.protectedEnd(source.items, open)) |end| {
                cursor = end;
                continue;
            }
            const tag = syntax.tagAt(source.items, open) orelse {
                cursor = open + 1;
                continue;
            };
            cursor = tag.end;
            if (oneOf(tag.name, &.{ "div", "p", "blockquote", "center", "ul", "ol", "dl", "table", "h1", "h2", "h3", "h4", "h5", "h6" })) explicit_blocks = true;
        }
        const produced = if (explicit_blocks) try self.renderBody(source.items) else blk: {
            // Parsing inline character data directly retains source boundary
            // whitespace. Joining adds no separator that was not in source.
            const spans = try self.parseSpans(source.items, .{});
            if (spans.len == 0 or (!joinable.* and trim(try plainText(self.a, spans)).len == 0)) break :blk &.{};
            const result = try self.a.alloc(Block, 1);
            result[0] = .{ .kind = .paragraph, .spans = spans };
            break :blk result;
        };
        if (produced.len == 1 and produced[0].kind == .paragraph and !explicit_blocks and joinable.* and blocks.items.len != 0) {
            // Cell boundaries do not introduce paragraph breaks in fostered
            // character data. Join their already-compiled spans without
            // executing references or other source effects a second time.
            const last = &blocks.items[blocks.items.len - 1];
            var spans: std.ArrayList(Span) = .empty;
            try spans.appendSlice(self.a, last.spans);
            try spans.appendSlice(self.a, produced[0].spans);
            last.spans = try spans.toOwnedSlice(self.a);
        } else try blocks.appendSlice(self.a, produced);
        if (produced.len != 0) joinable.* = produced[produced.len - 1].kind == .paragraph and !explicit_blocks;
    }
    const HtmlTableCellStart = struct { open: usize, tag: syntax.Tag };
    fn nextHtmlTableCell(input: []const u8, start: usize) ?HtmlTableCellStart {
        var at = start;
        while (std.mem.indexOfScalarPos(u8, input, at, '<')) |open| {
            if (syntax.protectedEnd(input, open)) |end| {
                at = end;
                continue;
            }
            const tag = syntax.tagAt(input, open) orelse {
                at = open + 1;
                continue;
            };
            at = tag.end;
            if (!tag.closing and (tag.is("td") or tag.is("th")))
                return .{ .open = open, .tag = tag };
        }
        return null;
    }
    fn htmlTable(self: *Renderer, input: []const u8, fostered: *std.ArrayList(Block)) Error!?Table {
        var rows: std.ArrayList(Row) = .empty;
        var caption: std.ArrayList(Span) = .empty;
        var pos: usize = 0;
        var processed: usize = 0;
        var foster_joinable = false;
        var foster_formatting: std.ArrayList([]const u8) = .empty;
        while (std.mem.indexOfScalarPos(u8, input, pos, '<')) |open| {
            if (self.truncated) break;
            if (syntax.protectedEnd(input, open)) |end| {
                pos = end;
                continue;
            }
            const tag = syntax.tagAt(input, open) orelse {
                pos = open + 1;
                continue;
            };
            pos = tag.end;
            if (tag.closing or !(tag.is("tr") or tag.is("caption"))) continue;
            const pair = if (tag.is("tr")) optionalTableEnd(input, tag) else syntax.matchingTag(input, tag) orelse return null;
            pos = pair.end;
            if (tag.is("caption")) {
                try self.htmlTableFostered(fostered, input[processed..open], &foster_joinable, &foster_formatting);
                try self.appendTableCaption(&caption, try self.parseSpans(input[tag.end..pair.inner_end], .{}));
                processed = pair.end;
                continue;
            }
            var cells: std.ArrayList(Cell) = .empty;
            var at = tag.end;
            while (nextHtmlTableCell(input[0..pair.inner_end], at)) |cell| {
                if (self.truncated) break;
                const cell_open = cell.open;
                const cell_tag = cell.tag;
                at = cell_tag.end;
                const cell_pair = optionalTableEnd(input[0..pair.inner_end], cell_tag);
                at = cell_pair.end;
                // Render each source prefix before its next cell so references
                // and other page-local effects retain source traversal order.
                try self.htmlTableFostered(fostered, input[processed..cell_open], &foster_joinable, &foster_formatting);
                processed = cell_pair.end;
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
        try self.htmlTableFostered(fostered, input[processed..], &foster_joinable, &foster_formatting);
        return .{ .caption = try caption.toOwnedSlice(self.a), .rows = try rows.toOwnedSlice(self.a) };
    }
    const TableResult = struct { table: Table, end: usize, body_end: usize, fostered: []const Block, has_caption: bool };
    fn flushWikiTableFostered(self: *Renderer, blocks: *std.ArrayList(Block), source: *std.ArrayList(u8)) Error!void {
        if (source.items.len == 0) return;
        // Rendered spans may borrow their input; release the accumulated
        // slice from the mutable buffer before another fostered segment.
        const body = try source.toOwnedSlice(self.a);
        try blocks.appendSlice(self.a, try self.renderBody(body));
    }
    fn wikiTableIndent(line: []const u8) ?[]const u8 {
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ':') : (indent += 1) {}
        var content = indent;
        while (content < line.len and std.ascii.isWhitespace(line[content])) : (content += 1) {}
        if (!starts(line[content..], "{|")) return null;
        return line[0..indent];
    }
    fn indentTableBlocks(self: *Renderer, blocks: []const Block, path: []const u8) Error![]const Block {
        if (path.len == 0 or blocks.len == 0) return blocks;
        const indented = try self.a.dupe(Block, blocks);
        for (indented) |*b| {
            const composed = try std.fmt.allocPrint(self.a, "{s}{s}", .{ path, b.list_path });
            b.list_path = composed[0..@min(composed.len, 255)];
            b.depth = @intCast(b.list_path.len);
        }
        return indented;
    }
    fn appendTableCaption(self: *Renderer, caption: *std.ArrayList(Span), spans: []const Span) Error!void {
        if (spans.len == 0) return;
        if (caption.items.len != 0 and self.spend())
            try caption.append(self.a, .{ .kind = .line_break, .text = "" });
        try caption.appendSlice(self.a, spans);
    }
    fn finishWikiTableCaption(self: *Renderer, caption: *std.ArrayList(Span), source: *std.ArrayList(u8), pending: *bool) Error!void {
        if (!pending.*) return;
        // Parsed spans can borrow source bytes; detach the completed caption.
        const body = try source.toOwnedSlice(self.a);
        try self.appendTableCaption(caption, try self.parseSpans(body, .{}));
        pending.* = false;
    }
    fn parseTable(self: *Renderer, input: []const u8, start: usize) Error!TableResult {
        var rows: std.ArrayList(Row) = .empty;
        var fostered: std.ArrayList(Block) = .empty;
        var cells: std.ArrayList(Cell) = .empty;
        var cell_source: std.ArrayList(u8) = .empty;
        var outside_source: std.ArrayList(u8) = .empty;
        defer outside_source.deinit(self.a);
        var current: ?Cell = null;
        var caption: std.ArrayList(Span) = .empty;
        var caption_source: std.ArrayList(u8) = .empty;
        var caption_pending = false;
        var has_caption = false;
        var pos = start;
        var body_end = input.len;
        var nested_tables: usize = 0;
        while (pos < input.len) {
            if (self.truncated) break;
            const line_start = pos;
            const end = syntax.logicalEnd(input, pos);
            const raw_line = std.mem.trimEnd(u8, input[pos..end], "\r");
            const line = trim(raw_line);
            pos = if (end < input.len) end + 1 else end;
            if (wikiTableIndent(line) != null) {
                try self.finishWikiTableCaption(&caption, &caption_source, &caption_pending);
                if (cell_source.items.len != 0) try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, raw_line);
                nested_tables += 1;
                continue;
            }
            if (nested_tables != 0) {
                if (cell_source.items.len != 0) try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, raw_line);
                if (starts(line, "|}")) nested_tables -= 1;
                continue;
            }
            if (starts(line, "|}") or starts(line, "|-")) {
                try self.finishWikiTableCaption(&caption, &caption_source, &caption_pending);
                try self.finishCell(&cells, &cell_source, &current);
                if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
                if (starts(line, "|}")) {
                    body_end = line_start;
                    // Preserve text and HTML following the close marker. A
                    // marker-only line still consumes its existing newline.
                    if (line.len > 2)
                        pos = @intFromPtr(line.ptr) - @intFromPtr(input.ptr) + 2;
                    break;
                }
            } else if (starts(line, "|+")) {
                try self.finishWikiTableCaption(&caption, &caption_source, &caption_pending);
                try self.finishCell(&cells, &cell_source, &current);
                // Preceding outside text registers references before the caption.
                try self.flushWikiTableFostered(&fostered, &outside_source);
                try caption_source.appendSlice(self.a, (try self.cellContent(line[2..])).text);
                caption_pending = true;
                has_caption = true;
            } else if (line.len != 0 and (line[0] == '!' or line[0] == '|')) {
                try self.finishWikiTableCaption(&caption, &caption_source, &caption_pending);
                try self.flushWikiTableFostered(&fostered, &outside_source);
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
                try self.finishWikiTableCaption(&caption, &caption_source, &caption_pending);
                if (syntax.tagAt(line, 0)) |tag| {
                    if (tag.is("tr") and !tag.closing) {
                        const pair = optionalTableEnd(line, tag);
                        if (nextHtmlTableCell(line[0..pair.inner_end], tag.end) == null) {
                            // No cells commit this row. Keep its source for the
                            // same later fostering or full-body rowless recovery,
                            // without registering references before recovery.
                            try self.finishCell(&cells, &cell_source, &current);
                            if (outside_source.items.len != 0) try outside_source.append(self.a, '\n');
                            try outside_source.appendSlice(self.a, raw_line);
                            continue;
                        }
                    }
                }
                try self.flushWikiTableFostered(&fostered, &outside_source);
                try self.finishCell(&cells, &cell_source, &current);
                if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
                if (try self.htmlTable(line, &fostered)) |table| {
                    try rows.appendSlice(self.a, table.rows);
                }
            } else if (caption_pending) {
                if (caption_source.items.len != 0) try caption_source.append(self.a, '\n');
                try caption_source.appendSlice(self.a, raw_line);
            } else if (current != null) {
                // A marker after an empty cell opener starts a block list;
                // the same marker on the opener's own line stays inline text.
                if (cell_source.items.len != 0 or (raw_line.len != 0 and (raw_line[0] == ' ' or std.mem.indexOfScalar(u8, "#*:;", raw_line[0]) != null)))
                    try cell_source.append(self.a, '\n');
                try cell_source.appendSlice(self.a, raw_line);
            } else {
                // Ordinary text outside a wiki cell is fostered before the
                // table, just as the HTML-table path retains non-cell text.
                if (outside_source.items.len != 0) try outside_source.append(self.a, '\n');
                try outside_source.appendSlice(self.a, raw_line);
            }
        }
        try self.finishWikiTableCaption(&caption, &caption_source, &caption_pending);
        try self.finishCell(&cells, &cell_source, &current);
        // Rowless recovery already renders the full body; avoid rendering its
        // outside text twice (including reference-registration side effects).
        if (has_caption or rows.items.len != 0 or cells.items.len != 0)
            try self.flushWikiTableFostered(&fostered, &outside_source);
        if (body_end == input.len) self.fallbacks.malformed_table = true;
        if (cells.items.len != 0) try rows.append(self.a, .{ .cells = try cells.toOwnedSlice(self.a) });
        return .{ .table = .{ .caption = try caption.toOwnedSlice(self.a), .rows = try rows.toOwnedSlice(self.a) }, .end = pos, .body_end = body_end, .fostered = try fostered.toOwnedSlice(self.a), .has_caption = has_caption };
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
        var has_blocks = false;
        var pos: usize = 0;
        while (pos < source.len) {
            const end = syntax.logicalEnd(source, pos);
            if (pos != 0 and end != pos and (source[pos] == ' ' or std.mem.indexOfScalar(u8, "#*:;", source[pos]) != null)) has_blocks = true;
            pos = if (end < source.len) end + 1 else end;
        }
        if (!has_blocks and std.mem.indexOf(u8, source, "{|") == null) return self.parseSpans(source, .{});
        const parent = self.spans;
        self.spans = .empty;
        defer self.spans = parent;
        var body = source;
        // The first line belongs to the cell opener, so its marker is literal
        // even when later lines contain a list or nested table.
        if (source.len != 0 and std.mem.indexOfScalar(u8, "#*:;", source[0]) != null) {
            const end = syntax.logicalEnd(source, 0);
            try self.spans.appendSlice(self.a, try self.parseSpans(source[0..end], .{}));
            body = source[if (end < source.len) end + 1 else end..];
            if (body.len != 0) try self.lineBreak(.{});
        }
        try self.blocksInline(try self.renderBody(body), .{});
        return self.spans.toOwnedSlice(self.a);
    }

    fn tableSpanAttr(self: *Renderer, tag: syntax.Tag, name: []const u8) Error!u16 {
        const raw = tag.attr(name) orelse return 1;
        const decoded = try self.entityText(raw);
        return @max(1, @min(100, std.fmt.parseInt(u16, decoded, 10) catch 1));
    }

    fn cellAttributePipe(raw: []const u8) ?usize {
        // logicalEnd can include a whole multiline HTML wrapper. Attributes
        // belong only to the cell's opening physical line, not its nested body.
        const end = std.mem.indexOfAny(u8, raw, "\r\n") orelse raw.len;
        const line = raw[0..end];
        const interesting = [_]u8{ '|', '<', '{', '[', '\'', '"' };
        var i: usize = 0;
        while (i < line.len) {
            i += std.mem.indexOfAny(u8, line[i..], &interesting) orelse return null;
            if (line[i] == '|') return i;
            if (line[i] == '\'' or line[i] == '"') {
                i = (std.mem.indexOfScalarPos(u8, line, i + 1, line[i]) orelse return null) + 1;
                continue;
            }
            if (line[i] == '<') {
                if (syntax.protectedEnd(line, i)) |protected_end| {
                    i = protected_end;
                    continue;
                }
                if (syntax.tagAt(line, i)) |tag| {
                    i = tag.end;
                    continue;
                }
            }
            if (starts(line[i..], "{{") or starts(line[i..], "[[")) {
                if (syntax.balanced(line, i)) |pair| {
                    i = pair.end;
                    continue;
                }
                return null;
            }
            i += 1;
        }
        return null;
    }

    fn cellContent(self: *Renderer, raw: []const u8) Error!CellContent {
        if (cellAttributePipe(raw)) |pipe| if (std.mem.indexOfScalar(u8, raw[0..pipe], '=') != null) {
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
            // List labels live on blocks, while DPR2 table cells hold spans.
            // Continuation paths (ending in ':') carry no repeated label.
            if (b.list_path.len != 0) switch (b.list_path[b.list_path.len - 1]) {
                '*' => try self.text("• ", style),
                '#' => if (b.number.len != 0) {
                    try self.text(b.number, style);
                    try self.text(". ", style);
                },
                else => {},
            };
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

test "HTML table structure ignores protected row and cell delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(
        "<table><!--<tr><td>hidden</td></tr>-->" ++
            "<tr><nowiki><td>outside cell</td></nowiki><td>before" ++
            "<!--</td></tr><tr><td>hidden-->after" ++
            "<nowiki></td></tr><td>literal</nowiki>end<td>second" ++
            "<tr><td>third</table>",
    );
    const table = blk: {
        for (blocks) |block_value| if (block_value.table) |value| break :blk value;
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].cells.len);
    try std.testing.expectEqualStrings("beforeafter</td></tr><td>literalend", try flattened(a, table.rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("second", try flattened(a, table.rows[0].cells[1].spans));
    try std.testing.expectEqualStrings("third", try flattened(a, table.rows[1].cells[0].spans));
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

test "translation layout stripping preserves protected table tags and neighboring cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(
        "<table class=\"translations\"><tr><td>\n" ++
            "* French: [[chat]]\n" ++
            "* Literal: <nowiki><td>literal</td></nowiki> tail\n" ++
            "</td><td>\n" ++
            "* German: [[Katze]]\n" ++
            "</td></tr></table>",
    );
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    for (blocks) |block_value| try std.testing.expectEqual(Kind.list_item, block_value.kind);
    try std.testing.expectEqualStrings("French: chat", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("Literal: <td>literal</td> tail", try flattened(a, blocks[1].spans));
    try std.testing.expectEqualStrings("German: Katze", try flattened(a, blocks[2].spans));
    var protected_literal = false;
    for (blocks[1].spans) |span| {
        if (span.provenance == .protected_literal and std.mem.eql(u8, span.text, "<td>literal</td>")) protected_literal = true;
    }
    try std.testing.expect(protected_literal);
    var neighboring_links: usize = 0;
    for (blocks) |block_value| for (block_value.spans) |span| {
        if (span.kind == .link and (std.mem.eql(u8, span.target, "chat") or std.mem.eql(u8, span.target, "Katze"))) neighboring_links += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), neighboring_links);

    // A protected-tag spelling inside an ordinary quoted attribute is not an opener.
    var quoted: Renderer = .{ .a = a, .context = .{} };
    const quoted_blocks = try quoted.renderBody(
        "<table class=\"translations\"><tr><td>\n" ++
            "* French: <span title=\"<nowiki>\">[[chat]]</span>\n" ++
            "</td><td>\n" ++
            "* German: [[Katze]]\n" ++
            "</td></tr></table>",
    );
    try std.testing.expectEqual(@as(usize, 2), quoted_blocks.len);
    for (quoted_blocks) |block_value| try std.testing.expectEqual(Kind.list_item, block_value.kind);
    try std.testing.expectEqualStrings("French: chat", try flattened(a, quoted_blocks[0].spans));
    try std.testing.expectEqualStrings("German: Katze", try flattened(a, quoted_blocks[1].spans));
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
    _ = try r.parseSpans("[[File:En-us-cat.ogg|muted|175px]]", .{});
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

    // Authored witnesses: billion revision 1153469 uses 10^{12}; or revision
    // 1139764 uses the hiero body below. Other numeric forms are controls.
    // The supported subset does not implement general TeX or hieroglyphs.
    const power_cases = [_]struct { source: []const u8, base: []const u8, exponent: []const u8 }{
        .{ .source = "<math>10^{12}</math>", .base = "10", .exponent = "12" },
        .{ .source = "<math>10^3</math>", .base = "10", .exponent = "3" },
        .{ .source = "<math>2^{0}</math>", .base = "2", .exponent = "0" },
    };
    for (power_cases) |case| {
        var power: Renderer = .{ .a = a, .context = .{} };
        const power_spans = try power.parseSpans(case.source, .{});
        try std.testing.expectEqual(@as(usize, 2), power_spans.len);
        try std.testing.expectEqualStrings(case.base, power_spans[0].text);
        try std.testing.expectEqualStrings(case.exponent, power_spans[1].text);
        try std.testing.expect(!power_spans[0].flags.superscript and power_spans[1].flags.superscript);
        try std.testing.expect(!power_spans[0].flags.code and !power_spans[1].flags.code);
        try std.testing.expect(!power.fallbacks.any());
    }
    const opaque_cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "<math>10^12</math>", .visible = "10^12" },
        .{ .source = "<math>10^</math>", .visible = "10^" },
        .{ .source = "<math>10^{}</math>", .visible = "10^{}" },
        .{ .source = "<math>10^{{12}}</math>", .visible = "10^{{12}}" },
        .{ .source = "<math>10^{1+2}</math>", .visible = "10^{1+2}" },
        .{ .source = "<math>10^{-2}</math>", .visible = "10^{-2}" },
        .{ .source = "<math>10^{12}+1</math>", .visible = "10^{12}+1" },
        .{ .source = "<math>prefix10^3</math>", .visible = "prefix10^3" },
        .{ .source = "<math>10^3tail</math>", .visible = "10^3tail" },
        .{ .source = "<math> 10^3 </math>", .visible = " 10^3 " },
        .{ .source = "<math>10^{٣}</math>", .visible = "10^{٣}" },
        .{ .source = "<math>\\frac{1}{2}</math>", .visible = "\\frac{1}{2}" },
        .{ .source = "<math>10^{\\alpha}</math>", .visible = "10^{\\alpha}" },
        .{ .source = "<math display='block'>10^{12}</math>", .visible = "10^{12}" },
        .{ .source = "<hiero>r: Z1-p-w</hiero>", .visible = "r: Z1-p-w" },
        .{ .source = "<ce>H2O</ce>", .visible = "H2O" },
        .{ .source = "<chem>CO2</chem>", .visible = "CO2" },
        .{ .source = "<score>{ c'4 d' }</score>", .visible = "{ c'4 d' }" },
        .{ .source = "<timeline>ImageSize = width:100 height:50</timeline>", .visible = "ImageSize = width:100 height:50" },
    };
    for (opaque_cases) |case| {
        var opaque_renderer: Renderer = .{ .a = a, .context = .{} };
        const literal_spans = try opaque_renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, literal_spans));
        try std.testing.expect(opaque_renderer.fallbacks.unsupported_element);
        try std.testing.expect(!opaque_renderer.fallbacks.unclosed_formatting);
        for (literal_spans) |span| {
            try std.testing.expect(span.flags.code);
            try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
        }
    }
    var unclosed_math: Renderer = .{ .a = a, .context = .{} };
    const unclosed_spans = try unclosed_math.parseSpans("<math>10^{12}", .{});
    try std.testing.expectEqualStrings("10^{12}", try flattened(a, unclosed_spans));
    try std.testing.expect(unclosed_math.fallbacks.unclosed_formatting and unclosed_math.fallbacks.unsupported_element);
    for (unclosed_spans) |span| try std.testing.expect(span.flags.code and !span.flags.superscript);
    const literal_cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "<pre>[[literal]]</pre>", .visible = "[[literal]]" },
        .{ .source = "<source>{{literal}}</source>", .visible = "{{literal}}" },
        .{ .source = "<syntaxhighlight>x &amp; y</syntaxhighlight>", .visible = "x & y" },
        .{ .source = "<nowiki><math>10^{12}</math></nowiki>", .visible = "<math>10^{12}</math>" },
    };
    for (literal_cases) |case| {
        var literal_renderer: Renderer = .{ .a = a, .context = .{} };
        const literal_spans = try literal_renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, literal_spans));
        try std.testing.expect(!literal_renderer.fallbacks.any());
    }
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
    try std.testing.expectEqualStrings("frameless", r.media.items[1].caption);
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
    try std.testing.expect(std.mem.indexOf(u8, text_value, "x（reading）") != null);
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

test "rendered Scribunto error class reports retained visible Lua failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const message = "Lua error in Module:Fixture: intentional failure";
    const spans = try r.parseSpans(
        "before<strong class='error'><span class='fixture scribunto&#45;error another'>" ++ message ++ "</span></strong>after",
        .{},
    );
    try std.testing.expect(r.fallbacks.rendered_lua_error);
    try std.testing.expectEqualStrings("before" ++ message ++ "after", try flattened(a, spans));
    var found = false;
    for (spans) |span| {
        if (!std.mem.eql(u8, span.text, message)) continue;
        found = true;
        try std.testing.expect(span.flags.bold);
        try std.testing.expectEqualStrings("error fixture scribunto-error another", span.classes);
    }
    try std.testing.expect(found);
}

test "Scribunto error words in protected source and near-match classes do not report Lua failures" {
    const cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "scribunto-error / Lua error in Module:Fixture: text", .visible = "scribunto-error / Lua error in Module:Fixture: text" },
        .{ .source = "before<!--<span class='scribunto-error'>hidden</span>-->after", .visible = "beforeafter" },
        .{ .source = "<nowiki><span class='scribunto-error'>literal</span></nowiki>", .visible = "<span class='scribunto-error'>literal</span>" },
        .{ .source = "&lt;span class='scribunto-error'&gt;literal&lt;/span&gt;", .visible = "<span class='scribunto-error'>literal</span>" },
        .{ .source = "<span class='scribunto-error-extra prefix-scribunto-error Scribunto-error'>near match</span>", .visible = "near match" },
        .{ .source = "<span data-note='scribunto-error'>other attribute</span>", .visible = "other attribute" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(case.source, .{});
        try std.testing.expect(!r.fallbacks.rendered_lua_error);
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
    }
}

test "malformed and invalid numeric wikitext entities stay literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("&#0;|&#xD800;|&#x110000;|&definitelyNotAnEntity;|&amp", .{});
    const text_value = try flattened(a, spans);
    try std.testing.expectEqualStrings("&#0;|&#xD800;|&#x110000;|&definitelyNotAnEntity;|&amp", text_value);
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

    // Entity-generated quotes stay literal in both default and explicit labels.
    const quote_labels = try r.parseSpans("[[&#39;&#39;word&#39;&#39;]] | [[&#39;&#39;word&#39;&#39;|&#39;&#39;word&#39;&#39;]]", .{});
    try std.testing.expectEqualStrings("''word'' | ''word''", try flattened(a, quote_labels));
    for (quote_labels) |span| if (span.kind == .link) {
        try std.testing.expectEqualStrings("''word''", span.target);
        try std.testing.expect(!span.flags.italic and !span.flags.bold);
    };
    const raw_quotes = try r.parseSpans("[[Lista d''e paise d''o munno]]", .{});
    try std.testing.expectEqualStrings("Lista d''e paise d''o munno", try flattened(a, raw_quotes));
    for (raw_quotes) |span| try std.testing.expect(!span.flags.italic);
    // Authored rich alternate labels and outer formatting remain active.
    const rich = try r.parseSpans("[[Title|''rich'']]", .{});
    try std.testing.expectEqualStrings("rich", try flattened(a, rich));
    try std.testing.expect(rich[0].flags.italic);
    try std.testing.expectEqualStrings("Title", rich[0].target);
    const outer = try r.parseSpans("''[[plain]]''", .{});
    try std.testing.expectEqualStrings("plain", try flattened(a, outer));
    try std.testing.expect(outer[0].flags.italic);
    const literal_entities = try r.parseSpans("A&amp;amp;B &#39;&#39;word&#39;&#39; <nowiki>&#39;&#39;word&#39;&#39;</nowiki>", .{});
    try std.testing.expectEqualStrings("A&amp;B ''word'' ''word''", try flattened(a, literal_entities));
    for (literal_entities) |span| try std.testing.expect(!span.flags.italic);

    // Retained Arabic plural expansion wraps an already linked argument.
    // The live MediaWiki oracle preserves the outer brackets as text and
    // navigates only the inner link. Invalid parameter targets remain literal.
    const invalid_links = [_]struct { source: []const u8, visible: []const u8, target: []const u8 = "", label: []const u8 = "", bold: bool = false, italic: bool = false, link_spans: usize = 1 }{
        .{ .source = "[[[[taking]]]]", .visible = "[[taking]]", .target = "taking", .label = "taking" },
        .{ .source = "'''[[[[taking]]s]]'''", .visible = "[[takings]]", .target = "taking", .label = "takings", .bold = true, .link_spans = 2 },
        .{ .source = "[[[[bacterium]]]]", .visible = "[[bacterium]]", .target = "bacterium", .label = "bacterium" },
        .{ .source = "[[[[planer]]]]", .visible = "[[planer]]", .target = "planer", .label = "planer" },
        .{ .source = "[[[[smithy]]]]", .visible = "[[smithy]]", .target = "smithy", .label = "smithy" },
        .{ .source = "[[prefix [[taking]] suffix]]", .visible = "[[prefix taking suffix]]", .target = "taking", .label = "taking" },
        .{ .source = "[[[[taking]]|label]]", .visible = "[[taking|label]]", .target = "taking", .label = "taking" },
        .{ .source = "[[[[Tom&#39;&#39;s]]]]", .visible = "[[Tom''s]]", .target = "Tom''s", .label = "Tom''s" },
        .{ .source = "[[{{{7}}}]]", .visible = "[[{{{7}}}]]" },
        .{ .source = "[[{{{7}}}|label]]", .visible = "[[{{{7}}}|label]]" },
        .{ .source = "[[a[b]c]]", .visible = "[[a[b]c]]" },
        .{ .source = "[[a{b}c]]", .visible = "[[a{b}c]]" },
        .{ .source = "[[taking#x[y]]]", .visible = "[[taking#x[y]]]" },
        .{ .source = "[[a&#91;b&#93;c|label]]", .visible = "[[a[b]c|label]]" },
        .{ .source = "[[&#91;&#91;taking&#93;&#93;]]", .visible = "[[[[taking]]]]" },
    };
    for (invalid_links) |case| {
        var invalid_renderer: Renderer = .{ .a = a, .context = .{} };
        const invalid_spans = try invalid_renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, invalid_spans));
        try std.testing.expect(invalid_renderer.fallbacks.literal_markup);
        var link_count: usize = 0;
        var linked_text: std.ArrayList(u8) = .empty;
        defer linked_text.deinit(a);
        for (invalid_spans) |span| {
            try std.testing.expectEqual(case.bold, span.flags.bold);
            try std.testing.expectEqual(case.italic, span.flags.italic);
            if (span.kind == .link) {
                link_count += 1;
                try std.testing.expect(case.target.len != 0);
                try std.testing.expectEqualStrings(case.target, span.target);
                try linked_text.appendSlice(a, span.text);
                try std.testing.expect(safeInternalTarget(span.target));
            } else {
                try std.testing.expect(span.kind == .text);
                try std.testing.expectEqualStrings("", span.target);
            }
        }
        try std.testing.expectEqual(@as(usize, if (case.target.len == 0) 0 else case.link_spans), link_count);
        try std.testing.expectEqualStrings(case.label, linked_text.items);
    }
    const valid_links = [_]struct { source: []const u8, visible: []const u8, target: []const u8 }{
        .{ .source = "[[Tom&#39;&#39;s]]", .visible = "Tom''s", .target = "Tom''s" },
        .{ .source = "[[x|&#91;&#91;literal&#93;&#93;]]", .visible = "[[literal]]", .target = "x" },
        .{ .source = "[[x|<nowiki>[[literal]]</nowiki>]]", .visible = "[[literal]]", .target = "x" },
    };
    for (valid_links) |case| {
        var valid_renderer: Renderer = .{ .a = a, .context = .{} };
        const valid_spans = try valid_renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, valid_spans));
        try std.testing.expect(!valid_renderer.fallbacks.any());
        var link_count: usize = 0;
        for (valid_spans) |span| if (span.kind == .link) {
            link_count += 1;
            try std.testing.expectEqualStrings(case.target, span.target);
            try std.testing.expect(!span.flags.bold and !span.flags.italic);
        };
        try std.testing.expect(link_count != 0);
    }
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

    // Same upstream rule as the observed scheme-colon loss, including a colon
    // in the label and a later real separator. Preserve the typed link target.
    const external_cases = [_]struct { source: []const u8, label: []const u8, target: []const u8 }{
        .{ .source = "[https://example.org label] : definition", .label = "label", .target = "https://example.org" },
        .{ .source = "https://example.org : definition", .label = "https://example.org", .target = "https://example.org" },
        .{ .source = "https://example.org:8443/a:b?q=c:d : definition", .label = "https://example.org:8443/a:b?q=c:d", .target = "https://example.org:8443/a:b?q=c:d" },
        .{ .source = "[https://example.org:8443/a:b?q=c:d label: detail] : definition", .label = "label: detail", .target = "https://example.org:8443/a:b?q=c:d" },
        .{ .source = "[//example.org/a:b relative: label] : definition", .label = "relative: label", .target = "//example.org/a:b" },
        .{ .source = "[https://example.org <nowiki>]:</nowiki> label] : definition", .label = "]: label", .target = "https://example.org" },
        .{ .source = "[https://example.org<span title=']:'>label: detail</span>] : definition", .label = "label: detail", .target = "https://example.org" },
    };
    for (external_cases) |case| {
        var linked_renderer: Renderer = .{ .a = a, .context = .{} };
        const body = try std.fmt.allocPrint(a, "; {s}\n", .{case.source});
        const linked_blocks = try linked_renderer.renderBody(body);
        try std.testing.expectEqual(@as(usize, 2), linked_blocks.len);
        try std.testing.expectEqual(Kind.term, linked_blocks[0].kind);
        try std.testing.expectEqual(Kind.list_detail, linked_blocks[1].kind);
        try std.testing.expectEqualStrings(";", linked_blocks[0].list_path);
        try std.testing.expectEqualStrings(":", linked_blocks[1].list_path);
        try std.testing.expectEqualStrings(case.label, try flattened(a, linked_blocks[0].spans));
        try std.testing.expectEqualStrings("definition", try flattened(a, linked_blocks[1].spans));
        var linked_text: std.ArrayList(u8) = .empty;
        for (linked_blocks[0].spans) |span| {
            try std.testing.expect(span.kind == .external_link);
            try std.testing.expectEqualStrings(case.target, span.target);
            try linked_text.appendSlice(a, span.text);
        }
        try std.testing.expectEqualStrings(case.label, linked_text.items);
        try std.testing.expect(!linked_renderer.fallbacks.any());
    }
    try std.testing.expect(inlineDefinitionSplit("[https://example.org label: detail]") == null);
    try std.testing.expect(inlineDefinitionSplit("https://example.org") == null);
    const successive = inlineDefinitionSplit("https://one.example [https://two.example two: label] : definition") orelse return error.ExpectedSuccessiveLinkSplit;
    try std.testing.expectEqualStrings("https://one.example [https://two.example two: label]", successive.term);
    try std.testing.expectEqualStrings("definition", successive.definition);
    const unchanged_cases = [_]struct { source: []const u8, term: []const u8, definition: []const u8 }{
        .{ .source = "[https://example.org unclosed : definition", .term = "[https", .definition = "//example.org unclosed : definition" },
        .{ .source = "[javascript:bad label] : definition", .term = "[javascript", .definition = "bad label] : definition" },
        .{ .source = "[ordinary : bracket] : definition", .term = "[ordinary", .definition = "bracket] : definition" },
        .{ .source = "{{x|a:b}} : definition", .term = "{{x|a:b}}", .definition = "definition" },
        .{ .source = "<nowiki>a:b</nowiki> : definition", .term = "<nowiki>a:b</nowiki>", .definition = "definition" },
        .{ .source = "<span title='a:b'>term</span> : definition", .term = "<span title='a:b'>term</span>", .definition = "definition" },
    };
    for (unchanged_cases) |case| {
        const pair = inlineDefinitionSplit(case.source) orelse return error.ExpectedDefinitionSplit;
        try std.testing.expectEqualStrings(case.term, pair.term);
        try std.testing.expectEqualStrings(case.definition, pair.definition);
    }
    try std.testing.expect(inlineDefinitionSplit("[[unclosed:link : definition") == null);
    try std.testing.expect(inlineDefinitionSplit("{{unclosed:template : definition") == null);
    const empty_term = inlineDefinitionSplit(": empty term") orelse return error.ExpectedEmptyTerm;
    try std.testing.expectEqualStrings("", empty_term.term);
    try std.testing.expectEqualStrings("empty term", empty_term.definition);
    const empty_definition = inlineDefinitionSplit("empty definition :") orelse return error.ExpectedEmptyDefinition;
    try std.testing.expectEqualStrings("empty definition", empty_definition.term);
    try std.testing.expectEqualStrings("", empty_definition.definition);
}

test "nested same-line definition lists retain their parent list paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("*; [[HTTP:foo|term]] : description\n**; child : nested description\n#; ordered : ordered description\n");
    try std.testing.expectEqual(@as(usize, 6), blocks.len);
    const paths = [_][]const u8{ "*;", "*:", "**;", "**:", "#;", "#:" };
    const labels = [_][]const u8{ "term", "description", "child", "nested description", "ordered", "ordered description" };
    for (blocks, paths, labels, 0..) |block_value, path, label, i| {
        try std.testing.expectEqualStrings(path, block_value.list_path);
        try std.testing.expectEqual(@as(u8, @intCast(path.len)), block_value.depth);
        try std.testing.expectEqual(if (i % 2 == 0) Kind.term else Kind.list_detail, block_value.kind);
        try std.testing.expectEqualStrings(label, try flattened(a, block_value.spans));
    }
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

test "malformed link opener preserves brackets while following HTML and entities render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const source = "[[broken <b>bold</b> &amp; tail";
    const spans = try r.parseSpans(source, .{});
    try std.testing.expectEqualStrings("[[broken bold & tail", try flattened(a, spans));
    for (spans) |span| {
        try std.testing.expect(span.kind == .text and !span.flags.italic);
        try std.testing.expectEqual(std.mem.indexOf(u8, span.text, "bold") != null, span.flags.bold);
    }
    const protected = try r.parseSpans("<nowiki>[[broken <b>bold</b> &amp; tail</nowiki>", .{});
    try std.testing.expectEqualStrings("[[broken <b>bold</b> & tail", try flattened(a, protected));
    for (protected) |span| try std.testing.expect(!span.flags.bold and !span.flags.italic);
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
    try std.testing.expect(std.mem.indexOf(u8, text_value, "abbr cite inserted sample 漢（kan）ok") != null);
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

    // Captions and alt text carry meaning; an implicit file name does not.
    const media_cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "[[File:Icon.svg]]", .expected = "" },
        .{ .source = "[[Image:Icon.svg|25px|link=]]", .expected = "" },
        .{ .source = "[[File:Icon.svg|alt=]]", .expected = "" },
        .{ .source = "[[File:Icon.svg|alt=Sound]]", .expected = "Sound" },
        .{ .source = "[[File:Icon.svg|ALT=Sound|alt=]]", .expected = "ALT=Sound" },
        .{ .source = "[[File:Icon.svg|alt=Sound|[[pronunciation|Speech]]]]", .expected = "Speech" },
        .{ .source = "[[File:Icon.svg|First|Second|alt=Sound]]", .expected = "Second" },
        .{ .source = "[[File:Icon.svg|Icon.svg]]", .expected = "Icon.svg" },
        .{ .source = "[[:File:Icon.svg]]", .expected = "File:Icon.svg" },
        .{ .source = "[[:File:Icon.svg|Picture]]", .expected = "Picture" },
        .{ .source = "Icon.svg", .expected = "Icon.svg" },
        .{ .source = "<span>[[File:Icon.svg|25px]]</span>Speech", .expected = "Speech" },
        .{ .source = "[[File:Outer.svg|[[File:Inner.svg|25px]]Speech]]", .expected = "Speech" },
    };
    for (media_cases) |case| {
        const heading = try r.renderBody(try std.fmt.allocPrint(a, "=={s}==\n[[File:Body.jpg|20px]]", .{case.source}));
        try std.testing.expectEqual(Kind.heading, heading[0].kind);
        try std.testing.expectEqualStrings(case.expected, try flattened(a, heading[0].spans));
        try std.testing.expectEqualStrings("Body.jpg", try flattened(a, heading[1].spans));
    }
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

test "localized namespace aliases classify media and category membership" {
    const a = std.testing.allocator;
    var registry = try @import("namespace_registry").Registry.init(a, @import("namespace_registry").french_test_fixture);
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var renderer: Renderer = .{ .a = arena.allocator(), .context = .{ .namespace_catalog = &registry } };
    const spans = try renderer.parseSpans("[[Fichier:Cat.jpg|thumb|Un chat]] [[Catégorie:Animaux]] [[:Catégorie:Animaux]]", .{});
    try std.testing.expectEqual(@as(usize, 1), renderer.media.items.len);
    const text = try plainText(arena.allocator(), spans);
    try std.testing.expect(std.mem.indexOf(u8, text, "Un chat") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Catégorie:Animaux"));
    try std.testing.expect(std.mem.indexOf(u8, text, "Fichier:Cat.jpg") == null);

    const headings = try renderer.renderBody("==[[Fichier:Icon.svg|25px]]Titre==\n==[[Fichier:Icon.svg|alt=Sens]]==\n[[Fichier:Body.jpg|20px]]");
    try std.testing.expectEqualStrings("Titre", try plainText(arena.allocator(), headings[0].spans));
    try std.testing.expectEqualStrings("Sens", try plainText(arena.allocator(), headings[1].spans));
    try std.testing.expectEqualStrings("Body.jpg", try plainText(arena.allocator(), headings[2].spans));
}

test "Phonos presentation keeps canonical audio caption and language with explicit error flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("<span class=\"ext-phonos ext-phonos-PhonosButton\" lang=\"id\" data-phonos-audio=\"Actual audio.opus\"><span class=\"e-example\">Dengerin</span></span>", .{});
    try std.testing.expectEqual(@as(usize, 1), renderer.media.items.len);
    const media = renderer.media.items[0];
    try std.testing.expectEqualStrings("Actual audio.opus", media.file);
    try std.testing.expectEqualStrings("Dengerin", media.caption);
    try std.testing.expectEqual(media_types.Kind.audio, media.kind);
    try std.testing.expectEqualStrings("Dengerin", try plainText(a, spans));
    try std.testing.expectEqualStrings("id", spans[0].language);
    try std.testing.expect(!renderer.fallbacks.rendered_extension_error);
    _ = try renderer.parseSpans("<span class=\"ext-phonos-error\" lang=\"id\" data-phonos-error=\"phonos-file-not-found\">Dengerin Unable to play audio</span>", .{});
    try std.testing.expect(renderer.fallbacks.rendered_extension_error);
    try std.testing.expectEqual(@as(usize, 1), renderer.media.items.len);
}

test "Belarusian legacy layout tables retain all four sampled translation groups" {
    // These are the expanded forms of the source-shaped runtime regression.
    // Rowless inner layout tables remain flagged, but must preserve their lists.
    const cases = [_]struct { left: []const u8, right: []const u8, terms: []const []const u8 }{
        .{ .left = "", .right = "* ru: [[увы]], [[ах]]", .terms = &.{ "увы", "ах" } },
        .{ .left = "", .right = "* ru: [[ОМОН]]", .terms = &.{"ОМОН"} },
        .{ .left = "* af: [[Australië]]\n* da: [[Australien]]\n* en: [[Australia]]", .right = "", .terms = &.{ "Australië", "Australien", "Australia" } },
        .{ .left = "* ca: [[Bielorússia]]\n* chr: [[ᏇᎳᎷᏒ]]\n* da: [[Hviderusland]]", .right = "", .terms = &.{ "Bielorússia", "ᏇᎳᎷᏒ", "Hviderusland" } },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var r: Renderer = .{ .a = a, .context = .{} };
        const input = try std.fmt.allocPrint(a, "# Kept definition\n<div class=\"NavFrame\"><div class=\"NavContent\">\n" ++
            "{{| border=\"0\" width=\"100%\"\n|-\n| valign=\"top\" width=\"48%\" |\n{{|\n{s}\n|}}\n" ++
            "| width=\"1%\" |\n| valign=\"top\" width=\"48%\" |\n{{|\n{s}\n|}}\n|}}</div></div>\nAfter", .{ case.left, case.right });
        const blocks = try r.renderBody(input);
        try std.testing.expectEqualStrings("Kept definition", try flattened(a, blocks[0].spans));
        try r.blocksInline(blocks, .{});
        const all = try flattened(a, r.spans.items);
        for (case.terms) |term| try std.testing.expect(std.mem.indexOf(u8, all, term) != null);
        try std.testing.expect(std.mem.indexOf(u8, all, "After") != null);
        var links: usize = 0;
        for (r.spans.items) |span| for (case.terms) |term| {
            if (std.mem.eql(u8, span.target, term)) links += 1;
        };
        try std.testing.expectEqual(case.terms.len, links);
    }
}

test "balanced formatting wrapper preserves implicit block newline and list styling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Trailing paragraph continuity is deliberately outside the new list-only path.
    var trailing: Renderer = .{ .a = a, .context = .{} };
    const trailing_blocks = try trailing.renderBody("<s>one\n* later\nlast paragraph\n</s>\nafter");
    try std.testing.expectEqualStrings("last paragraph  after", try flattened(a, trailing_blocks[trailing_blocks.len - 1].spans));
    try std.testing.expect(trailing.fallbacks.unclosed_formatting);

    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<small>\n* هذه الصفحة معتمدة على [[مرجع|كتاب]]\n* <b>notice</b></small>\nAfter");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    for (blocks[0..2]) |block_value| {
        try std.testing.expectEqual(Kind.list_item, block_value.kind);
        try std.testing.expectEqualStrings("*", block_value.list_path);
        try std.testing.expectEqual(@as(u8, 1), block_value.depth);
        for (block_value.spans) |span| try std.testing.expect(span.flags.small);
    }
    try std.testing.expectEqualStrings("هذه الصفحة معتمدة على كتاب", try flattened(a, blocks[0].spans));
    var linked = false;
    for (blocks[0].spans) |span| if (span.kind == .link) {
        linked = true;
        try std.testing.expectEqualStrings("مرجع", span.target);
        try std.testing.expectEqualStrings("كتاب", span.text);
    };
    try std.testing.expect(linked);
    try std.testing.expectEqualStrings("notice", try flattened(a, blocks[1].spans));
    try std.testing.expect(blocks[1].spans[0].flags.bold);
    try std.testing.expectEqualStrings("After", try flattened(a, blocks[2].spans));
    for (blocks[2].spans) |span| try std.testing.expect(!span.flags.small);
    try std.testing.expect(!r.fallbacks.unclosed_formatting);
    // Authored clinometer rev1115142 pairs s across later line-start list
    // markers. The first # follows an inline opener and stays literal text.
    var clinical: Renderer = .{ .a = a, .context = .{} };
    const clinical_blocks = try clinical.renderBody("<s># مقياس الميل\n2222231\n23154+6\n*\n*\n</s>");
    try std.testing.expect(!clinical.fallbacks.unclosed_formatting);
    try std.testing.expectEqual(Kind.paragraph, clinical_blocks[0].kind);
    try std.testing.expectEqualStrings("# مقياس الميل 2222231 23154+6", try flattened(a, clinical_blocks[0].spans));
    for (clinical_blocks[0].spans) |span| try std.testing.expect(span.flags.strike);
    // Nonempty controlled list proves scope retention, not corpus incidence.
    var scoped: Renderer = .{ .a = a, .context = .{} };
    const scoped_blocks = try scoped.renderBody("<s># literal\ncontinuation\n* later [[target|item]]\n</s>\nAfter");
    try std.testing.expectEqual(@as(usize, 3), scoped_blocks.len);
    try std.testing.expectEqual(Kind.paragraph, scoped_blocks[0].kind);
    try std.testing.expectEqualStrings("# literal continuation", try flattened(a, scoped_blocks[0].spans));
    try std.testing.expectEqual(Kind.list_item, scoped_blocks[1].kind);
    try std.testing.expectEqualStrings("*", scoped_blocks[1].list_path);
    try std.testing.expectEqualStrings("later item", try flattened(a, scoped_blocks[1].spans));
    for (scoped_blocks[0..2]) |part| for (part.spans) |span| try std.testing.expect(span.flags.strike);
    try std.testing.expectEqualStrings("After", try flattened(a, scoped_blocks[2].spans));
    for (scoped_blocks[2].spans) |span| try std.testing.expect(!span.flags.strike);
    try std.testing.expect(!scoped.fallbacks.unclosed_formatting);

    // Ordinary soft-newline wrappers must remain in their original paragraph.
    for ([_]struct { source: []const u8, text: []const u8 }{
        .{ .source = "<s>one\ntwo</s>\nthree", .text = "one two three" },
        .{ .source = "before\n<s>one\ntwo</s>", .text = "before one two" },
    }) |case| {
        var continuous: Renderer = .{ .a = a, .context = .{} };
        const continuous_blocks = try continuous.renderBody(case.source);
        try std.testing.expectEqual(@as(usize, 1), continuous_blocks.len);
        try std.testing.expectEqual(Kind.paragraph, continuous_blocks[0].kind);
        try std.testing.expectEqualStrings(case.text, try flattened(a, continuous_blocks[0].spans));
        try std.testing.expect(!continuous.fallbacks.unclosed_formatting);
    }

    // Consuming an extension on that same physical line must not re-anchor #.
    var rescanned: Renderer = .{ .a = a, .context = .{} };
    const rescanned_blocks = try rescanned.renderBody("<s><templatestyles src=\"x\"/># literal\n* later\n</s>\nAfter");
    try std.testing.expectEqual(@as(usize, 3), rescanned_blocks.len);
    try std.testing.expectEqual(Kind.paragraph, rescanned_blocks[0].kind);
    try std.testing.expectEqualStrings("# literal", try flattened(a, rescanned_blocks[0].spans));
    try std.testing.expectEqual(Kind.list_item, rescanned_blocks[1].kind);
    try std.testing.expect(!rescanned.fallbacks.unclosed_formatting);

    // An already active paragraph keeps its old continuity and limitation;
    // this narrow repair does not promote or claim to repair that path.
    var preceding: Renderer = .{ .a = a, .context = .{} };
    const preceding_blocks = try preceding.renderBody("before\n<s># inline\n* later\n</s>");
    try std.testing.expectEqual(@as(usize, 2), preceding_blocks.len);
    try std.testing.expectEqual(Kind.paragraph, preceding_blocks[0].kind);
    try std.testing.expectEqualStrings("before # inline", try flattened(a, preceding_blocks[0].spans));
    try std.testing.expectEqual(Kind.list_item, preceding_blocks[1].kind);
    try std.testing.expect(preceding.fallbacks.unclosed_formatting);
    for (preceding_blocks[1].spans) |span| try std.testing.expect(!span.flags.strike);
}

test "nested block formatting restores parent flags and keeps unclosed reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<small>\n<strong>\n# first\n# second</strong>\n\nEnd\n</small>\nAfter");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    for (blocks[0..2], 0..) |block_value, index| {
        try std.testing.expectEqual(Kind.definition, block_value.kind);
        try std.testing.expectEqualStrings(if (index == 0) "1" else "2", block_value.number);
        for (block_value.spans) |span| {
            try std.testing.expect(span.flags.small);
            try std.testing.expect(span.flags.bold);
        }
    }
    try std.testing.expectEqualStrings("End", try flattened(a, blocks[2].spans));
    for (blocks[2].spans) |span| {
        try std.testing.expect(span.flags.small);
        try std.testing.expect(!span.flags.bold);
    }
    try std.testing.expectEqualStrings("After", try flattened(a, blocks[3].spans));
    for (blocks[3].spans) |span| try std.testing.expect(!span.flags.small and !span.flags.bold);
    try std.testing.expect(!r.fallbacks.unclosed_formatting);
    var unmatched: Renderer = .{ .a = a, .context = .{} };
    const unfinished = try unmatched.renderBody("<small>\n* notice");
    try std.testing.expect(unmatched.fallbacks.unclosed_formatting);
    try std.testing.expectEqual(@as(usize, 1), unfinished.len);
    try std.testing.expectEqual(Kind.list_item, unfinished[0].kind);
    try std.testing.expectEqualStrings("notice", try flattened(a, unfinished[0].spans));
    var indented: Renderer = .{ .a = a, .context = .{} };
    const preformatted = try indented.renderBody(" <small>\n* notice</small>");
    try std.testing.expectEqual(@as(usize, 2), preformatted.len);
    try std.testing.expectEqual(Kind.preformatted, preformatted[0].kind);
    try std.testing.expect(indented.fallbacks.unclosed_formatting);
    for (preformatted[1].spans) |span| try std.testing.expect(!span.flags.small);
}

test "behavior controls are compiled away only in parsed source text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "before__NOEDITSECTION__after__notoc__", .visible = "beforeafter" },
        .{ .source = "__UNKNOWN____index__", .visible = "__UNKNOWN____index__" },
        .{ .source = "<!--__NOTOC__-->kept", .visible = "kept" },
        .{ .source = "<nowiki>__NOEDITSECTION__</nowiki>", .visible = "__NOEDITSECTION__" },
        .{ .source = "<pre>__NOTOC__</pre>", .visible = "__NOTOC__" },
        .{ .source = "&#95;&#95;NOTOC&#95;&#95;", .visible = "__NOTOC__" },
        .{ .source = "<span title='__NOTOC__'>kept</span>", .visible = "kept" },
        .{ .source = "<code><nowiki>__NOTOC__</nowiki></code>", .visible = "__NOTOC__" },
        .{ .source = "<code>before__NOTOC__after</code>", .visible = "beforeafter" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.visible, try flattened(a, try r.parseSpans(case.source, .{})));
}

test "localized behavior controls use complete captured aliases and protect literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const registry_type = @import("namespace_registry").behavior_switches;
    const raw = registry_type.header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\nnoeditsection\t0\t__لاتحريرقسم__\nindex\t1\t__INDEX__\n";
    var registry = try registry_type.Registry.init(a, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer registry.deinit();
    var renderer: Renderer = .{ .a = a, .context = .{ .behavior_switches = &registry } };
    const spans = try renderer.parseSpans("a＿＿目次非表示＿＿b__لاتحريرقسم__c __index__ __NOTOC__ <nowiki>＿＿目次非表示＿＿</nowiki>", .{});
    try std.testing.expectEqualStrings("abc __index__ __NOTOC__ ＿＿目次非表示＿＿", try flattened(a, spans));
}

// Append to presentation_compile.zig for a focused current-behavior regression.
// Expected failure today: non-cell visible text is dropped by htmlTable.
test "HTML tables preserve fostered visible text outside cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table>before<tbody><tr><nowiki>outside cell</nowiki><td>inside</td></tr></tbody>after</table>");
    const parent = r.spans;
    r.spans = .empty;
    defer r.spans = parent;
    try r.blocksInline(blocks, .{});
    const visible = try flattened(a, r.spans.items);
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
    try std.testing.expectEqualStrings("beforeoutside cellafter", try flattened(a, blocks[0].spans));
    try std.testing.expect(std.mem.indexOf(u8, visible, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "outside cell") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "inside") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "after") != null);
}

test "fostered table text neither invents captions nor duplicates cell contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table><caption>actual caption</caption><b>before</b><tr><td>inside</td></tr>after</table>");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("beforeafter", try flattened(a, blocks[0].spans));
    try std.testing.expect(blocks[0].spans[0].flags.bold);
    const table = blocks[1].table.?;
    try std.testing.expectEqualStrings("actual caption", try flattened(a, table.caption));
    try std.testing.expectEqualStrings("inside", try flattened(a, table.rows[0].cells[0].spans));
}

test "mixed wiki HTML table rows retain their fostered visible text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\n<tr>outside<td>inside</td></tr>\n|}\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("outside", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("inside", try flattened(a, blocks[1].table.?.rows[0].cells[0].spans));
}

test "fostered wikitext lists keep their semantic blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table>\n* outside list\n<tr><td>inside</td></tr></table>");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.list_item, blocks[0].kind);
    try std.testing.expectEqualStrings("outside list", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
}

test "fostered div paragraph and list content retains separate semantic blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table><div>first</div><p>second</p>\n* outside list\n<tr><td>inside</td></tr></table>");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
    try std.testing.expectEqual(Kind.list_item, blocks[2].kind);
    try std.testing.expectEqual(Kind.table, blocks[3].kind);
    try std.testing.expectEqualStrings("first", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("second", try flattened(a, blocks[1].spans));
    try std.testing.expectEqualStrings("outside list", try flattened(a, blocks[2].spans));
}

test "fostered reference registration retains source order around table cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    _ = try r.renderBody("<table><ref name='before'>first</ref><tr><td><ref name='cell'>second</ref></td></tr><ref name='after'>third</ref></table>");
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 3), refs.len);
    try std.testing.expectEqualStrings("before", refs[0].name);
    try std.testing.expectEqualStrings("cell", refs[1].name);
    try std.testing.expectEqualStrings("after", refs[2].name);
}

test "fostered whitespace and reconstructed formatting cross cell boundaries exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spaced = try r.renderBody("<table>before <tr><td>inside</td></tr> after</table>");
    try std.testing.expectEqualStrings("before  after", try flattened(a, spaced[0].spans));
    const adjacent = try r.renderBody("<table>before<tr><td>inside</td></tr>after</table>");
    try std.testing.expectEqualStrings("beforeafter", try flattened(a, adjacent[0].spans));
    const styled = try r.renderBody("<table><b>before<tr><td>inside</td></tr>after</b></table>");
    try std.testing.expectEqualStrings("beforeafter", try flattened(a, styled[0].spans));
    for (styled[0].spans) |span| try std.testing.expect(span.flags.bold);
    for (styled[1].table.?.rows[0].cells[0].spans) |span| try std.testing.expect(!span.flags.bold);
    const layout = try r.renderBody("<table><div>before<tr><td>inside</td></tr>after</div></table>");
    try std.testing.expectEqual(@as(usize, 3), layout.len);
    try std.testing.expectEqualStrings("before", try flattened(a, layout[0].spans));
    try std.testing.expectEqualStrings("after", try flattened(a, layout[1].spans));
    try std.testing.expect(!r.fallbacks.unclosed_formatting);
}
// Append to presentation_compile.zig for separate open HTML-list gaps.
// Expected failure today: ul/ol wrappers are stripped; li contents become inline paragraphs.
test "HTML ordered lists preserve numbering as semantic list blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<ol><li>first</li><li>second</li></ol>");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.list_item, blocks[0].kind);
    try std.testing.expectEqualStrings("#", blocks[0].list_path);
    try std.testing.expectEqualStrings("1", blocks[0].number);
    try std.testing.expectEqualStrings("2", blocks[1].number);
    try std.testing.expectEqualStrings("first", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("second", try flattened(a, blocks[1].spans));
    const sections = [_]struct { title: []const u8, level: u8, blocks: []const Block }{.{ .title = "Noun", .level = 3, .blocks = blocks }};
    const organization = try @import("presentation_layout.zig").build(a, &sections);
    try std.testing.expectEqual(@as(usize, 0), organization.lexemes[0].definitions.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, organization.lexemes[0].introduction);
}

test "HTML unordered lists honor optional item closure without merging visible words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<ul><li>first<li>second</ul>");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("*", blocks[0].list_path);
    try std.testing.expectEqualStrings("*", blocks[1].list_path);
    try std.testing.expectEqualStrings("first", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("second", try flattened(a, blocks[1].spans));
}
test "HTML lists preserve nested order explicit ordinals attributes and trailing item content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<ol start='3'><li lang='en' class='IPA'>parent<ul><li>child<ol><li>grandchild</ol></ul>tail<li value='8'>next<li>last</ol>");
    try std.testing.expectEqual(@as(usize, 6), blocks.len);
    const paths = [_][]const u8{ "#", "#*", "#*#", "#:", "#", "#" };
    const numbers = [_][]const u8{ "3", "", "1", "", "8", "9" };
    const labels = [_][]const u8{ "parent", "child", "grandchild", "tail", "next", "last" };
    for (blocks, paths, numbers, labels) |block_value, path, number, label| {
        try std.testing.expectEqualStrings(path, block_value.list_path);
        try std.testing.expectEqualStrings(number, block_value.number);
        try std.testing.expectEqualStrings(label, try flattened(a, block_value.spans));
    }
    try std.testing.expectEqualStrings("en", blocks[0].spans[0].language);
    try std.testing.expectEqual(Role.pronunciation, blocks[0].spans[0].role);
    // The existing fixture's child and grandchild inherit the explicit li language.
    try std.testing.expectEqualStrings("en", blocks[1].spans[0].language);
    try std.testing.expectEqualStrings("en", blocks[2].spans[0].language);
    try std.testing.expectEqualStrings("en", blocks[3].spans[0].language);
    try std.testing.expectEqualStrings("", blocks[4].spans[0].language);
    try std.testing.expectEqualStrings("", blocks[5].spans[0].language);

    const language_direction_cases = [_]struct {
        source: []const u8,
        language: []const u8,
        direction: []const u8,
    }{
        .{ .source = "<ul><li lang='ar' dir='rtl'>parent<ol><li>child</li></ol></li></ul>", .language = "ar", .direction = "rtl" },
        .{ .source = "<ul><li lang='ar' dir='auto'>parent<ol><li>child</li></ol></li></ul>", .language = "ar", .direction = "auto" },
        .{ .source = "<ul lang='ar' dir='rtl'><li>parent<ol><li>child</li></ol></li></ul>", .language = "ar", .direction = "rtl" },
        .{ .source = "<ol lang='ar' dir='rtl'><li>parent<ul><li>child</li></ul></li></ol>", .language = "ar", .direction = "rtl" },
        .{ .source = "<ul lang='a&#114;' dir='R&#84;L'><li>parent<ol><li>child</li></ol></li></ul>", .language = "ar", .direction = "rtl" },
        .{ .source = "<ul><li>parent<ol><li>child</li></ol></li></ul>", .language = "", .direction = "" },
    };
    for (language_direction_cases) |case| {
        var list_renderer: Renderer = .{ .a = a, .context = .{} };
        const list_blocks = try list_renderer.renderBody(case.source);
        try std.testing.expectEqual(@as(usize, 2), list_blocks.len);
        for (list_blocks, [_][]const u8{ "parent", "child" }) |list_block, expected_text| {
            try std.testing.expectEqualStrings(expected_text, try flattened(a, list_block.spans));
            for (list_block.spans) |span| {
                try std.testing.expectEqualStrings(case.language, span.language);
                try std.testing.expectEqualStrings(case.direction, span.direction);
            }
        }
        try std.testing.expect(!list_renderer.fallbacks.any());
        // Inline HTML list rendering keeps the same explicit-field contract.
        var inline_renderer: Renderer = .{ .a = a, .context = .{} };
        const inline_spans = try inline_renderer.parseSpans(case.source, .{});
        var saw_parent = false;
        var saw_child = false;
        for (inline_spans) |span| {
            const has_parent = std.mem.indexOf(u8, span.text, "parent") != null;
            const has_child = std.mem.indexOf(u8, span.text, "child") != null;
            if (has_parent or has_child) {
                saw_parent = saw_parent or has_parent;
                saw_child = saw_child or has_child;
                try std.testing.expectEqualStrings(case.language, span.language);
                try std.testing.expectEqualStrings(case.direction, span.direction);
            }
        }
        try std.testing.expect(saw_parent and saw_child);
    }

    var override_renderer: Renderer = .{ .a = a, .context = .{} };
    const override_blocks = try override_renderer.renderBody("<ul><li lang='en' dir='ltr'>parent<ol lang='ar' dir='rtl'><li lang='de' dir='ltr'>override</li><li>sibling</li></ol>tail</li><li>outside</li></ul>");
    try std.testing.expectEqual(@as(usize, 5), override_blocks.len);
    const expected_texts = [_][]const u8{ "parent", "override", "sibling", "tail", "outside" };
    const expected_languages = [_][]const u8{ "en", "de", "ar", "en", "" };
    const expected_directions = [_][]const u8{ "ltr", "ltr", "rtl", "ltr", "" };
    const expected_paths = [_][]const u8{ "*", "*#", "*#", "*:", "*" };
    const expected_numbers = [_][]const u8{ "", "1", "2", "", "" };
    for (override_blocks, expected_texts, expected_languages, expected_directions, expected_paths, expected_numbers) |list_block, expected_text, language, direction, expected_path, expected_number| {
        try std.testing.expectEqualStrings(expected_text, try flattened(a, list_block.spans));
        try std.testing.expectEqualStrings(expected_path, list_block.list_path);
        try std.testing.expectEqualStrings(expected_number, list_block.number);
        for (list_block.spans) |span| {
            try std.testing.expectEqualStrings(language, span.language);
            try std.testing.expectEqualStrings(direction, span.direction);
        }
    }
    try std.testing.expect(!override_renderer.fallbacks.any());

    var definition_renderer: Renderer = .{ .a = a, .context = .{} };
    const definition_blocks = try definition_renderer.renderBody("<dl lang='ar' dir='rtl'><dt>term</dt><dd>detail<ul><li>child</li></ul></dd></dl>");
    try std.testing.expectEqual(@as(usize, 3), definition_blocks.len);
    for (definition_blocks, [_][]const u8{ "term", "detail", "child" }, [_][]const u8{ ";", ":", ":*" }) |list_block, expected_text, expected_path| {
        try std.testing.expectEqualStrings(expected_text, try flattened(a, list_block.spans));
        try std.testing.expectEqualStrings(expected_path, list_block.list_path);
        for (list_block.spans) |span| {
            try std.testing.expectEqualStrings("ar", span.language);
            try std.testing.expectEqualStrings("rtl", span.direction);
        }
    }
    try std.testing.expect(!definition_renderer.fallbacks.any());

    var empty_invalid_renderer: Renderer = .{ .a = a, .context = .{} };
    const empty_invalid = try empty_invalid_renderer.renderBody("<ul lang='ar' dir='rtl'><li lang='' dir='invalid'>cleared</li><li>inherited</li></ul>");
    try std.testing.expectEqual(@as(usize, 2), empty_invalid.len);
    try std.testing.expectEqualStrings("", empty_invalid[0].spans[0].language);
    try std.testing.expectEqualStrings("rtl", empty_invalid[0].spans[0].direction);
    try std.testing.expectEqualStrings("ar", empty_invalid[1].spans[0].language);
    try std.testing.expectEqualStrings("rtl", empty_invalid[1].spans[0].direction);
}

test "HTML definition lists optional closures retain protected item-looking text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<dl><dt>term<dd>before<!--<dt>hidden--><nowiki><dd>literal</nowiki>after<dt>other<dd>definition</dl>");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.term, blocks[0].kind);
    try std.testing.expectEqual(Kind.list_detail, blocks[1].kind);
    try std.testing.expectEqualStrings("before<dd>literalafter", try flattened(a, blocks[1].spans));
}

test "HTML ordered list types reversed order and explicit resets compile to labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<ol reversed type='i'><li>first<ul><li>nested</ul><li type='A' value='27'>reset<li>last</ol>");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("iii", blocks[0].number);
    try std.testing.expectEqualStrings("", blocks[1].number);
    try std.testing.expectEqualStrings("AA", blocks[2].number);
    try std.testing.expectEqualStrings("xxvi", blocks[3].number);
    const explicit = try r.renderBody("<ol reversed='false' start='2' type='a'><li>first<li>second<li>third</ol>");
    try std.testing.expectEqualStrings("b", explicit[0].number);
    try std.testing.expectEqualStrings("a", explicit[1].number);
    try std.testing.expectEqualStrings("0", explicit[2].number);
    const ordinary = try r.renderBody("<ol data-note='reversed'><li>first<li>second</ol>");
    try std.testing.expectEqualStrings("1", ordinary[0].number);
    try std.testing.expectEqualStrings("2", ordinary[1].number);
}

test "HTML ordered nested lists use their own counters and retain item block boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const nested = try r.renderBody("<ol start='27' type='A'><li>outer<ol start='3' type='i'><li>inner</li></ol></li></ol>");
    try std.testing.expectEqualStrings("AA", nested[0].number);
    try std.testing.expectEqualStrings("iii", nested[1].number);
    try std.testing.expectEqualStrings("##", nested[1].list_path);
    const blocks = try r.renderBody("<ol><li><p>one</p><p>two</p><table><tr><td>left</td><td>right</td></tr></table>tail</li></ol>");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(Kind.list_item, blocks[0].kind);
    try std.testing.expectEqualStrings("1", blocks[0].number);
    var breaks: usize = 0;
    for (blocks[0].spans) |span| {
        if (span.kind == .line_break) breaks += 1;
    }
    try std.testing.expect(breaks >= 2);
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
    try std.testing.expectEqualStrings("#:", blocks[1].list_path);
    try std.testing.expectEqual(@as(usize, 2), blocks[1].table.?.rows[0].cells.len);
    try std.testing.expectEqualStrings("left", try flattened(a, blocks[1].table.?.rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("right", try flattened(a, blocks[1].table.?.rows[0].cells[1].spans));
    try std.testing.expectEqual(Kind.list_detail, blocks[2].kind);
    try std.testing.expectEqualStrings("tail", try flattened(a, blocks[2].spans));
}

const image_option_test_identity = @import("namespace_registry").image_options.header ++ "\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n# behavior-switches-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n";
test "image option localized aliases preserve real body heading and gallery captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns = @import("namespace_registry");
    var namespaces = try ns.Registry.init(a, ns.german_test_fixture);
    defer namespaces.deinit();
    var options = try ns.image_options.Registry.init(a, image_option_test_identity ++ "img_thumbnail\t1\t\"miniatur\"\nimg_right\t1\t\"rechts\"\nimg_alt\t1\t\"alternativtext=$1\"\nimg_width\t1\t\"$1px\"\n", "dewiktionary", "20261001", "de", @splat(0), @splat(0));
    defer options.deinit();
    var r: Renderer = .{ .a = a, .context = .{ .namespace_catalog = &namespaces, .image_options = &options } };
    _ = try r.parseSpans("[[Datei:Example.jpg|miniatur|CaptionProbeAlpha|rechts|alternativtext=HiddenAlt]]", .{});
    try std.testing.expectEqualStrings("CaptionProbeAlpha", r.media.items[0].caption);
    const heading = try r.parseSpans("[[Datei:Heading.jpg|alternativtext=GermanHeadingAlt]]", .{ .heading = true });
    try std.testing.expectEqualStrings("GermanHeadingAlt", try flattened(a, heading));
    _ = try r.parseSpans("<gallery>\nDatei:Gallery.jpg|GalleryCaption|alternativtext=HiddenAlt\nDatei:Width.jpg|GalleryCaption|200px\n</gallery>", .{});
    try std.testing.expectEqualStrings("GalleryCaption", r.media.items[2].caption);
    try std.testing.expectEqualStrings("200px", r.media.items[3].caption);
}
test "image option case invalid widths formats and unsupported parameters remain visible captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    _ = try r.parseSpans("[[File:Case.jpg|thumb|THUMB]] [[File:Zero.jpg|Caption|0px]] [[File:Malformed.jpg|Caption|200xx100px]] [[File:Good.jpg|Caption|x100px]] [[File:Handler.jpg|Caption|page=bad]] [[File:Scale.jpg|Caption|upright=bogus]] [[File:Format.jpg|thumb|Caption|frameless]]", .{});
    const captions = [_][]const u8{ "THUMB", "0px", "200xx100px", "Caption", "page=bad", "upright=bogus", "frameless" };
    try std.testing.expectEqual(captions.len, r.media.items.len);
    for (r.media.items, captions) |media, caption| try std.testing.expectEqualStrings(caption, media.caption);
}

test "image option timed audio handler validates values without hiding unsupported captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    _ = try r.parseSpans("[[File:Audio.ogg|AudioCaption|LOOP|MUTED|START=-1: 2e1|disablecontrols=options,timedText]] [[File:Image.jpg|ImageCaption|loop]] [[File:Bad.ogg|AudioCaption|start=1:2:3:4]] [[File:BadControls.ogg|AudioCaption|disablecontrols=options, fullscreen]] [[File:Unsupported.ogg|AudioCaption|autoplay]] [[File:NoIcon.ogg|AudioCaption|noicon]] <gallery>\nFile:Gallery.ogg|GalleryAudioCaption|loop|muted\n</gallery>", .{});
    const captions = [_][]const u8{ "AudioCaption", "loop", "start=1:2:3:4", "disablecontrols=options, fullscreen", "autoplay", "noicon", "GalleryAudioCaption" };
    try std.testing.expectEqual(captions.len, r.media.items.len);
    for (r.media.items, captions) |media, caption| try std.testing.expectEqualStrings(caption, media.caption);
}

test "typed image handler options preserve valid captions without swallowing unrelated options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const cases = [_]struct { file: []const u8, option: []const u8, expected: []const u8 }{
        .{ .file = "Doc.pdf", .option = "page=002", .expected = "Caption" },
        .{ .file = "Doc.PDF", .option = "page=0", .expected = "Caption" },
        .{ .file = "Doc.pdf", .option = "page=+2", .expected = "page=+2" },
        .{ .file = "Doc.djvu", .option = "page=-2", .expected = "Caption" },
        .{ .file = "Doc.djv", .option = "page=02", .expected = "page=02" },
        .{ .file = "Map.svg", .option = "lang=zh-Hant-TW", .expected = "Caption" },
        .{ .file = "Map.svg", .option = "lang=en_US", .expected = "lang=en_US" },
        .{ .file = "Photo.jpg", .option = "page=2", .expected = "page=2" },
        .{ .file = "Photo.jpg", .option = "lang=de", .expected = "lang=de" },
        .{ .file = "Scan.tiff", .option = "page=2", .expected = "page=2" },
        .{ .file = "Scan.tiff", .option = "lossy=1", .expected = "lossy=1" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, r.mediaCaption(try std.fmt.allocPrint(r.a, "Caption|{s}", .{case.option}), case.file, Renderer.mediaOptionMode(case.file, false)));
    for ([_][]const u8{ "de", "ZH-hant-TW", "x-private", "i-klingon", "en-a-test-b-more-x-p", "en-123", "en\n" }) |tag| try std.testing.expect(Renderer.mediaLanguageTag(tag));
    for ([_][]const u8{ "", "en_US", "e", "en-1-test", "en-a", "en-x", "en--US", "en-abcdefghi", "en\n\n" }) |tag| try std.testing.expect(!Renderer.mediaLanguageTag(tag));
}

test "page reference context preserves first definitions groups protection and used only output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const context = try referenceDefinitionsAlloc(a, "<ref name='a&amp;b'/><ref name='a&amp;b'>First</ref><ref name='a&amp;b'>Later</ref>" ++
        "<references group='g&amp;x'><ref name=a>Grouped</ref><ref name=a group=other>Other</ref></references>" ++
        "<!-- <ref name=comment>Wrong</ref> --><nowiki><ref name=raw>Wrong</ref></nowiki>" ++
        "<pre><ref name=pre>Wrong</ref></pre><code><nowiki><ref name=nested>Wrong</ref></nowiki><ref name=code>Parsed code</ref></code>" ++
        "<ref name=unused>{{uncompiled-neighbor}}</ref><ref name=forward>Forward</ref>");
    try std.testing.expectEqual(@as(usize, 6), context.items.len);
    var r: Renderer = .{ .a = a, .context = .{}, .page_reference_definitions = context.items };
    const spans = try r.parseSpans("Body<ref name='a&amp;b'>Conflicting local</ref><ref name=a group='g&amp;x'/><ref name=a group=other/><ref name=code/><ref name=forward/><ref name=missing/>", .{});
    try std.testing.expectEqualStrings("Body[1][g&x 1][other 1][2][3][4]", try flattened(a, spans));
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 6), refs.len);
    inline for (.{ "First", "Grouped", "Other", "Parsed code", "Forward", "Reference text unavailable" }, 0..) |expected, i| {
        try std.testing.expectEqualStrings(expected, try flattened(a, refs[i].spans));
    }
    try std.testing.expect(!r.fallbacks.template_presentation);
}

test "imagemap preserves source backed image and hotspot link occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    // Source-instantiated picdic/picdicimg syntax, not captured page expansion.
    const spans = try r.parseSpans("<imagemap>\n# source comment [[hidden]]\n<!--header-->\nimage:G50.png|310x150px|Picture|alt=Picture\nrect 0 0 1 1 [[vogel|Bird]]\ndefault [[voël|Voël]]\nrect 0 0 2 2 [https://example.test/picture Outside source]\ndesc none\n</imagemap>[[voël|Outside]]", .{});
    try std.testing.expectEqual(@as(usize, 1), r.media.items.len);
    try std.testing.expectEqualStrings("G50.png", r.media.items[0].file);
    try std.testing.expectEqualStrings("Picture", r.media.items[0].caption);
    var links: std.ArrayList(Span) = .empty;
    for (spans) |span| if (span.kind == .link) {
        try links.append(a, span);
    };
    try std.testing.expectEqual(@as(usize, 4), links.items.len);
    try std.testing.expectEqualStrings("File:G50.png", links.items[0].target);
    try std.testing.expectEqualStrings("vogel", links.items[1].target);
    try std.testing.expectEqualStrings("voël", links.items[2].target);
    try std.testing.expectEqualStrings("voël", links.items[3].target);
    try std.testing.expectEqualStrings("Outside", links.items[3].text);
    var external_count: usize = 0;
    for (spans) |span| if (span.kind == .external_link) {
        try std.testing.expectEqualStrings("https://example.test/picture", span.target);
        external_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), external_count);
    try std.testing.expect(!r.fallbacks.unsupported_element);
    const text = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, text, "rect") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "desc") == null);
    // Actual retained oog picdic file/header shape, instantiated rather than captured expansion.
    var svg: Renderer = .{ .a = a, .context = .{} };
    const svg_spans = try svg.parseSpans("<imagemap>image:Human head and brain diagram.svg|310x310px|oog|alt=oog\nrect 0 0 1 1 [[oog]]\ndesc none\n</imagemap>[[oog|Outside]]", .{});
    try std.testing.expectEqual(@as(usize, 1), svg.media.items.len);
    try std.testing.expectEqualStrings("Human head and brain diagram.svg", svg.media.items[0].file);
    try std.testing.expectEqualStrings("oog", svg.media.items[0].caption);
    try std.testing.expectEqual(media_types.Kind.image, svg.media.items[0].kind);
    var svg_links: std.ArrayList(Span) = .empty;
    for (svg_spans) |span| if (span.kind == .link) {
        try svg_links.append(a, span);
    };
    try std.testing.expectEqual(@as(usize, 3), svg_links.items.len);
    try std.testing.expectEqualStrings("File:Human head and brain diagram.svg", svg_links.items[0].target);
    try std.testing.expectEqualStrings("oog", svg_links.items[1].target);
    try std.testing.expectEqualStrings("oog", svg_links.items[2].target);
    try std.testing.expectEqualStrings("Outside", svg_links.items[2].text);
    try std.testing.expect(!svg.fallbacks.unsupported_element);
    try std.testing.expect(media_types.kind("file.JPG") == .image);
    var file_ref: Renderer = .{ .a = a, .context = .{} };
    _ = try file_ref.parseSpans("[[File:Human head and brain diagram.svg|thumb|File caption]]", .{});
    try std.testing.expectEqual(@as(usize, 1), file_ref.media.items.len);
    try std.testing.expectEqualStrings("File caption", file_ref.media.items[0].caption);
    var gallery_ref: Renderer = .{ .a = a, .context = .{} };
    _ = try gallery_ref.parseSpans("<gallery>Human head and brain diagram.svg|Gallery caption</gallery>", .{});
    try std.testing.expectEqual(@as(usize, 1), gallery_ref.media.items.len);
    try std.testing.expectEqualStrings("Gallery caption", gallery_ref.media.items[0].caption);
    var heading_then_body: Renderer = .{ .a = a, .context = .{} };
    const blocks = try heading_then_body.renderBody("==[[File:Human head and brain diagram.svg|alt=Heading]] Title==\n[[File:Human head and brain diagram.svg|thumb|Body caption]]\n==[[File:Heading.png|20px]]Raster title==\n");
    try std.testing.expectEqualStrings("Heading Title", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("File:Human head and brain diagram.svg", blocks[0].spans[0].target);
    try std.testing.expectEqual(@as(usize, 2), heading_then_body.media.items.len);
    try std.testing.expectEqualStrings("Human head and brain diagram.svg", heading_then_body.media.items[0].file);
    try std.testing.expectEqualStrings("Body caption", heading_then_body.media.items[0].caption);
    try std.testing.expectEqualStrings("Heading.png", heading_then_body.media.items[1].file);
    try std.testing.expectEqualStrings("Heading.png", heading_then_body.media.items[1].caption);
    // References are metadata only; raw SVG is still ineligible for inline export.
    try std.testing.expect(media_types.kind("script.svg") == null);
    try std.testing.expect(media_types.mime("<svg onload='alert(1)'>") == null);
}

test "imagemap invalid directives and protected source retain conservative diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    _ = try r.parseSpans("<imagemap>not an image\ndefault [[wrong]]</imagemap>", .{});
    try std.testing.expectEqual(@as(usize, 0), r.media.items.len);
    try std.testing.expect(r.fallbacks.unsupported_element);
    var escaped: Renderer = .{ .a = a, .context = .{} };
    _ = try escaped.parseSpans("<imagemap>image:G50.png|x]] [[File:Other.png|other\ndefault [[wrong]]</imagemap>", .{});
    try std.testing.expectEqual(@as(usize, 0), escaped.media.items.len);
    try std.testing.expect(escaped.fallbacks.unsupported_element);
    var valid: Renderer = .{ .a = a, .context = .{} };
    const spans = try valid.parseSpans("<imagemap>image:G50.png|Caption\nrect NaN 0 1 1 [[wrong]]\ndefault [[wrong]] [[extra]]\ndefault [[wrong]] garbage\ndesc garbage\ndefault [[|empty]]\n<!-- default [[hidden]] -->\ncircle 1 2 3 [[shown]]\npoly 0 0 1 0 1 1 [[polygon]]</imagemap>", .{});
    try std.testing.expectEqual(@as(usize, 1), valid.media.items.len);
    try std.testing.expect(valid.fallbacks.unsupported_element);
    var count: usize = 0;
    for (spans) |span| if (span.kind == .link and !std.mem.startsWith(u8, span.target, "File:")) {
        try std.testing.expect(!std.mem.eql(u8, span.target, "wrong"));
        try std.testing.expect(!std.mem.eql(u8, span.target, "hidden"));
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), count);
    var protected: Renderer = .{ .a = a, .context = .{} };
    _ = try protected.parseSpans("<nowiki><imagemap>image:G50.png\ndefault [[vogel]]</imagemap></nowiki><pre><imagemap>image:G50.png\ndefault [[vogel]]</imagemap></pre>", .{});
    try std.testing.expectEqual(@as(usize, 0), protected.media.items.len);
}

test "ruby Japanese 日 keeps annotation separate from prose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    // jawiktionary page 925, revision 2299765 (20261001 dump).
    const spans = try r.parseSpans("日とは<ruby>実<rt>じつ</rt></ruby>である", .{});
    try std.testing.expectEqualStrings("日とは実（じつ）である", try flattened(arena.allocator(), spans));
}

test "ruby Japanese 火 keeps the supplied multi-character reading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    // jawiktionary page 967, revision 2173516 (20261001 dump).
    const spans = try r.parseSpans("七月に<ruby>心宿<rt>なかごぼし</rt></ruby>が天頂を過ぎ", .{});
    try std.testing.expectEqualStrings("七月に心宿（なかごぼし）が天頂を過ぎ", try flattened(arena.allocator(), spans));
}

test "ruby Japanese 月 retains trailing inflection outside its reading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    // jawiktionary page 1744, revision 2351336 (20261001 dump).
    const spans = try r.parseSpans("月光を<ruby>看<rt>み</rt></ruby>る", .{});
    try std.testing.expectEqualStrings("月光を看（み）る", try flattened(arena.allocator(), spans));
}

test "ruby explicit rp fallback punctuation is preserved exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const spans = try r.parseSpans("<ruby>漢<rp>〔</rp><rt>かん</rt><rp>〕</rp></ruby>", .{});
    try std.testing.expectEqualStrings("漢〔かん〕", try flattened(arena.allocator(), spans));
}

test "ruby annotation links emphasis and language remain typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const spans = try r.parseSpans("<ruby lang='ja'>[[看]]<rt>''[[み]]''</rt></ruby>る", .{});
    try std.testing.expectEqualStrings("看（み）る", try flattened(arena.allocator(), spans));
    var base = false;
    var reading = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "看")) base = span.kind == .link and std.mem.eql(u8, span.target, "看") and std.mem.eql(u8, span.language, "ja");
        if (std.mem.eql(u8, span.text, "み")) reading = span.kind == .link and std.mem.eql(u8, span.target, "み") and span.flags.italic and std.mem.eql(u8, span.language, "ja");
        if (std.mem.eql(u8, span.text, "る")) try std.testing.expect(span.kind == .text and span.target.len == 0 and !span.flags.italic);
    }
    try std.testing.expect(base and reading);
}

test "ruby protected markup is literal and cannot supply fallback punctuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const literal = "<ruby>漢<rt>かん</rt></ruby>";
    const protected = try r.parseSpans("<nowiki>" ++ literal ++ "</nowiki>", .{});
    try std.testing.expectEqualStrings(literal, try flattened(arena.allocator(), protected));
    for (protected) |span| try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
    const inner = try r.parseSpans("<ruby>字<nowiki><rp></nowiki><rt>じ</rt></ruby>", .{});
    try std.testing.expectEqualStrings("字<rp>（じ）", try flattened(arena.allocator(), inner));
}

test "ruby nested fallbacks and grouped annotations do not duplicate delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const nested = try r.parseSpans("<ruby>外<rt>そと</rt><ruby>内<rp>[</rp><rt>うち</rt><rp>]</rp></ruby></ruby>", .{});
    try std.testing.expectEqualStrings("外（そと）内[うち]", try flattened(arena.allocator(), nested));
    const grouped = try r.parseSpans("<ruby><rb>漢字</rb><rtc><rt>かんじ</rt></rtc></ruby>", .{});
    try std.testing.expectEqualStrings("漢字（かんじ）", try flattened(arena.allocator(), grouped));
}

test "ruby empty annotations do not invent a reading and bare rt remains transparent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const spans = try r.parseSpans("<ruby>字<rt><!-- absent --></rt></ruby><rt>plain</rt>", .{});
    try std.testing.expectEqualStrings("字plain", try flattened(arena.allocator(), spans));
}

test "internal link HTML quoted attributes retain visible labels and protected controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const witness = "[[cat|<span title=\"]]\">visible</span>]]";
    const spans = try renderer.parseSpans(witness, .{});
    try std.testing.expectEqualStrings("visible", try flattened(a, spans));
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].kind == .link);
    try std.testing.expectEqualStrings("cat", spans[0].target);
    try std.testing.expectEqualStrings("visible", spans[0].text);
    const external = try renderer.parseSpans("[https://example.test <span title=\"]\">visible</span>]", .{});
    try std.testing.expectEqualStrings("visible", try flattened(a, external));
    try std.testing.expectEqual(@as(usize, 1), external.len);
    try std.testing.expect(external[0].kind == .external_link);
    try std.testing.expectEqualStrings("https://example.test", external[0].target);
    const protected_external = try renderer.parseSpans("<nowiki>[https://example.test <span title=\"]\">visible</span>]</nowiki>", .{});
    try std.testing.expectEqualStrings("[https://example.test <span title=\"]\">visible</span>]", try flattened(a, protected_external));
    for (protected_external) |span| try std.testing.expect(span.kind != .external_link);
    const plain = try renderer.parseSpans("A<span title=\"]]\">visible</span>Z", .{});
    try std.testing.expectEqualStrings("AvisibleZ", try flattened(a, plain));
    const protected = try renderer.parseSpans("<nowiki>[[cat|<span title=\"]]\">visible</span>]]</nowiki>", .{});
    try std.testing.expectEqualStrings(witness, try flattened(a, protected));
    for (protected) |span| try std.testing.expect(span.kind != .link);
}

test "external sequential closing bracket retains a literal unlinked tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var renderer: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const spans = try renderer.parseSpans("[https://example.test visible]]", .{});
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expect(spans[0].kind == .external_link);
    try std.testing.expectEqualStrings("visible", spans[0].text);
    try std.testing.expectEqualStrings("https://example.test", spans[0].target);
    try std.testing.expect(spans[1].kind == .text and spans[1].target.len == 0);
    try std.testing.expectEqualStrings("]", spans[1].text);
}

test "heading control suffix renders headings through exact profile and preserves literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody("=English=__NOTOC__ __NOEDITSECTION__\nbody\n=French=\nsecond");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.heading, blocks[0].kind);
    try std.testing.expectEqualStrings("English", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
    try std.testing.expectEqualStrings("body", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.heading, blocks[2].kind);
    try std.testing.expectEqualStrings("French", try flattened(a, blocks[2].spans));
    const registry_type = @import("namespace_registry").behavior_switches;
    const raw = registry_type.header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\n";
    var registry = try registry_type.Registry.init(a, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer registry.deinit();
    renderer.context.behavior_switches = &registry;
    const localized = try renderer.renderBody("=English=＿＿目次非表示＿＿");
    try std.testing.expectEqual(@as(usize, 1), localized.len);
    try std.testing.expectEqual(Kind.heading, localized[0].kind);
    try std.testing.expectEqualStrings("English", try flattened(a, localized[0].spans));
    for ([_][]const u8{ "=English=__NOTOC__", "=English=__UNKNOWN__", "=English=&#95;&#95;NOTOC&#95;&#95;", "=English=<nowiki>＿＿目次非表示＿＿</nowiki>" }) |literal| {
        const retained = try renderer.renderBody(literal);
        try std.testing.expectEqual(@as(usize, 1), retained.len);
        try std.testing.expectEqual(Kind.paragraph, retained[0].kind);
        try std.testing.expect(std.mem.startsWith(u8, try flattened(a, retained[0].spans), "=English="));
    }
}

test "ordinary table cells preserve list labels links and literal markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{| class=\"wikitable\"\n|\n* [[first]]\n* second\n|-\n|\n# [[first]]\n## [[second]]\n# third\n|-\n| * literal\n|-\n| <nowiki>\n* protected\n</nowiki>\n|}\n");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const rows = blocks[0].table.?.rows;
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqualStrings("• first\n• second", try flattened(a, rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("1. first\n1.1. second\n2. third", try flattened(a, rows[1].cells[0].spans));
    try std.testing.expectEqualStrings("* literal", try flattened(a, rows[2].cells[0].spans));
    const protected = try flattened(a, rows[3].cells[0].spans);
    try std.testing.expect(std.mem.indexOf(u8, protected, "* protected") != null);
    try std.testing.expect(std.mem.indexOf(u8, protected, "• ") == null);
    var links: usize = 0;
    for (rows[1].cells[0].spans) |span| if (span.kind == .link) {
        try std.testing.expectEqualStrings(if (links == 0) "first" else "second", span.target);
        links += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), links);
    const mixed = try r.renderBody("{|\n| * [[literal]]\n* [[listed]]\n|}\n");
    try std.testing.expectEqualStrings("* literal\n• listed", try flattened(a, mixed[0].table.?.rows[0].cells[0].spans));
}

test "span-only block flattening labels lists without repeating continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("* first\n*: detail\n** [[nested]]\n# numbered\nplain");
    try r.blocksInline(blocks, .{});
    try std.testing.expectEqualStrings("• first\ndetail\n• nested\n1. numbered\nplain", try flattened(a, r.spans.items));
    const wrapped = try r.parseSpans("<li>outer\n{|\n|\n* inner\n|}\n</li>", .{});
    try std.testing.expectEqualStrings("• outer\n• inner\n", try flattened(a, wrapped));
}

test "mixed apostrophe transitions preserve component styles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const Case = struct { source: []const u8, a_bold: bool, a_italic: bool, b_bold: bool, b_italic: bool };
    for ([_]Case{
        .{ .source = "''a'''''b'''", .a_bold = false, .a_italic = true, .b_bold = true, .b_italic = false },
        .{ .source = "'''a'''''b''", .a_bold = true, .a_italic = false, .b_bold = false, .b_italic = true },
        .{ .source = "'''''a'''b''", .a_bold = true, .a_italic = true, .b_bold = false, .b_italic = true },
    }) |case| {
        const spans = try r.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings("ab", try flattened(a, spans));
        try std.testing.expectEqual(@as(usize, 2), spans.len);
        try std.testing.expectEqualStrings("a", spans[0].text);
        try std.testing.expectEqualStrings("b", spans[1].text);
        try std.testing.expectEqual(case.a_bold, spans[0].flags.bold);
        try std.testing.expectEqual(case.a_italic, spans[0].flags.italic);
        try std.testing.expectEqual(case.b_bold, spans[1].flags.bold);
        try std.testing.expectEqual(case.b_italic, spans[1].flags.italic);
    }
    const protected = try r.parseSpans("<nowiki>''a'''''b'''</nowiki>", .{});
    try std.testing.expectEqualStrings("''a'''''b'''", try flattened(a, protected));
    for (protected) |span| try std.testing.expect(!span.flags.bold and !span.flags.italic);
    const malformed = try r.parseSpans("''unclosed", .{});
    try std.testing.expectEqualStrings("unclosed", try flattened(a, malformed));
    for (malformed) |span| try std.testing.expect(span.flags.italic);
}

test "normalized closing apostrophes retain literal extras and emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const Case = struct { source: []const u8, plain: []const u8, bold: bool, italic: bool };
    var all_balanced = true;
    for ([_]Case{
        .{ .source = "'''word''''", .plain = "word'", .bold = true, .italic = false },
        .{ .source = "'''''word''''''", .plain = "word'", .bold = true, .italic = true },
        .{ .source = "'''''word'''''''", .plain = "word''", .bold = true, .italic = true },
        .{ .source = "'''word'''", .plain = "word", .bold = true, .italic = false },
        .{ .source = "'''''word'''''", .plain = "word", .bold = true, .italic = true },
    }) |case| {
        const spans = try r.parseSpans(case.source, .{});
        const plain = try flattened(a, spans);
        var matched = spans.len > 0 and std.mem.eql(u8, case.plain, plain);
        for (spans) |span| {
            if (span.flags.bold != case.bold or span.flags.italic != case.italic) matched = false;
        }
        std.debug.print("QUOTE_CLOSE source={s} plain={s} styles={s}\n", .{ case.source, plain, if (matched) "matched" else "mismatched" });
        all_balanced = all_balanced and matched;
    }
    const leading = try r.parseSpans("''''n'''", .{});
    try std.testing.expectEqualStrings("'n", try flattened(a, leading));
    try std.testing.expectEqual(@as(usize, 2), leading.len);
    try std.testing.expect(!leading[0].flags.bold and !leading[0].flags.italic);
    try std.testing.expect(leading[1].flags.bold and !leading[1].flags.italic);
    const protected = try r.parseSpans("'''word<nowiki>''''</nowiki>", .{});
    try std.testing.expectEqualStrings("word''''", try flattened(a, protected));
    for (protected) |span| try std.testing.expect(span.flags.bold and !span.flags.italic);
    const unclosed = try r.parseSpans("'''word", .{});
    try std.testing.expectEqualStrings("word", try flattened(a, unclosed));
    for (unclosed) |span| try std.testing.expect(span.flags.bold and !span.flags.italic);
    try std.testing.expect(all_balanced);
}

test "HTML ordered lists in ordinary table cells retain numbering and links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "<table><tr><td><ol start='3'><li>[[first]]</li><li value='7'>second</li></ol></td></tr></table>",
        "{|\n| <ol start='3'><li>[[first]]</li><li value='7'>second</li></ol>\n|}\n",
    };
    for (cases) |input| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(input);
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqual(Kind.table, blocks[0].kind);
        const rows = blocks[0].table.?.rows;
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqual(@as(usize, 1), rows[0].cells.len);
        const spans = rows[0].cells[0].spans;
        try std.testing.expectEqualStrings("3. first\n7. second\n", try flattened(a, spans));
        var links: usize = 0;
        for (spans) |span| if (span.kind == .link) {
            try std.testing.expectEqualStrings("first", span.text);
            try std.testing.expectEqualStrings("first", span.target);
            links += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), links);
    }
    var empty: Renderer = .{ .a = a, .context = .{} };
    const no_items = try empty.renderBody("<table><tr><td>before<ol></ol>after</td></tr></table>");
    try std.testing.expectEqualStrings("beforeafter", try flattened(a, no_items[0].table.?.rows[0].cells[0].spans));
    var protected: Renderer = .{ .a = a, .context = .{} };
    const literal = try protected.renderBody("{|\n| <nowiki><ol><li>literal</li></ol></nowiki>\n|}\n");
    try std.testing.expectEqualStrings("<ol><li>literal</li></ol>", try flattened(a, literal[0].table.?.rows[0].cells[0].spans));
}

test "HTML table cell lists retain nested counters surrounding text and inline style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table><tr><td>before<ol start='3'><li>outer<ol type='i' start='4'><li>[[inner]]</li><li value='9'>next</li></ol>tail</li><li value='7'><b>last</b></li></ol>after</td></tr></table>");
    const spans = blocks[0].table.?.rows[0].cells[0].spans;
    try std.testing.expectEqualStrings("before\n3. outer\niv. inner\nix. next\ntail\n7. last\nafter", try flattened(a, spans));
    var inner_link = false;
    var bold_last = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "inner")) inner_link = span.kind == .link and std.mem.eql(u8, span.target, "inner");
        if (std.mem.eql(u8, span.text, "last")) bold_last = span.flags.bold;
    }
    try std.testing.expect(inner_link and bold_last);
    const styled = try r.renderBody("{|\n| <small lang='an'><ol><li>[[word]]</li></ol></small>\n|}\n");
    var inherited_style = false;
    for (styled[0].table.?.rows[0].cells[0].spans) |span| {
        if (span.kind == .link) inherited_style = span.flags.small and std.mem.eql(u8, span.language, "an");
    }
    try std.testing.expect(inherited_style);
}

test "media labels preserve authored caption styles and plain alt fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8, heading: bool = false, inherited: bool = false, bold: bool = false, italic: bool = false, language: []const u8 = "", direction: []const u8 = "", provenance: Provenance = .parsed }{
        .{ .source = "[[File:Cat.jpg|thumb|''cat'']]", .visible = "cat", .italic = true },
        .{ .source = "<gallery>\nFile:Cat.jpg|'''cat'''\n</gallery>", .visible = "cat", .bold = true },
        .{ .source = "[[File:Cat.jpg|thumb|cat]]", .visible = "cat" },
        .{ .source = "[[File:Icon.svg|alt=''alternative'']]", .visible = "alternative", .heading = true },
        .{ .source = "[[File:Icon.svg|alt=''alternative'']]", .visible = "alternative", .heading = true, .inherited = true, .bold = true, .language = "en", .direction = "rtl" },
        .{ .source = "[[File:Cat.jpg|alt=''alternative'']]", .visible = "Cat.jpg" },
        .{ .source = "<gallery>\nFile:Cat.jpg|alt=''alternative''\n</gallery>", .visible = "Cat.jpg" },
        .{ .source = "[[File:Cat.jpg|thumb|plain]]", .visible = "plain", .inherited = true, .bold = true, .language = "en", .direction = "rtl" },
        .{ .source = "[[File:Cat.jpg|thumb|''cat'']]", .visible = "cat", .inherited = true, .bold = true, .italic = true, .language = "en", .direction = "rtl" },
        .{ .source = "[[File:Cat.jpg|thumb|<nowiki>''cat''</nowiki>]]", .visible = "''cat''", .inherited = true, .bold = true, .language = "en", .direction = "rtl", .provenance = .protected_literal },
        .{ .source = "[[File:Cat.jpg|thumb|[[cat|<span lang='ja' dir='ltr'>''cat''</span>]]]]", .visible = "cat", .inherited = true, .bold = true, .italic = true, .language = "ja", .direction = "ltr" },
        .{ .source = "[[File:Cat.jpg|thumb|<span lang=''>cat</span>]]", .visible = "cat", .inherited = true, .bold = true, .language = "", .direction = "rtl" },
        .{ .source = "[[File:Cat.jpg|thumb|Cat.jpg]]", .visible = "Cat.jpg" },
        .{ .source = "[[File:Icon.svg|''caption'']]", .visible = "caption", .heading = true, .inherited = true, .bold = true, .italic = true, .language = "en", .direction = "rtl" },
        .{ .source = "[[File:Cat.jpg]]", .visible = "File:Cat.jpg", .inherited = true, .bold = true, .language = "en", .direction = "rtl" },
    };
    for (cases) |case| {
        var renderer: Renderer = .{ .a = a, .context = .{} };
        const style: Style = .{ .heading = case.heading, .bold = case.inherited, .language = if (case.inherited) "en" else "", .direction = if (case.inherited) "rtl" else "" };
        const spans = try renderer.parseSpans(case.source, style);
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        try std.testing.expect(spans.len != 0);
        for (spans) |span| {
            try std.testing.expectEqual(case.bold, span.flags.bold);
            try std.testing.expectEqual(case.italic, span.flags.italic);
            try std.testing.expectEqualStrings(case.language, span.language);
            try std.testing.expectEqualStrings(case.direction, span.direction);
            try std.testing.expectEqual(case.provenance, span.provenance);
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings(if (case.heading) "File:Icon.svg" else "File:Cat.jpg", span.target);
        }
    }
}

test "grammar syntax oracle wiki table leading space retains code semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\n| before\n code line\n|}");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    const spans = blocks[0].table.?.rows[0].cells[0].spans;
    const visible = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, visible, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "code line") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "{|") == null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "|}") == null);
    var code_found = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "code line") != null) {
            code_found = true;
            try std.testing.expect(span.flags.code);
        }
        if (std.mem.indexOf(u8, span.text, "before") != null) try std.testing.expect(!span.flags.code);
    }
    try std.testing.expect(code_found);
}

test "grammar syntax oracle invalid numeric wikitext entities stay literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    // This tests decoded wikitext rendering, not XML dump transport decoding.
    const invalid = "&#128; &#x80; &#0; &#xD800; &#99999999;";
    const controls = try r.parseSpans("&#233; &#xE9; &amp;", .{});
    try std.testing.expectEqualStrings("é é &", try flattened(a, controls));
    const spans = try r.parseSpans(invalid, .{});
    try std.testing.expectEqualStrings(invalid, try flattened(a, spans));
}

test "grammar syntax oracle numeric references follow MediaWiki accepted ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    for ([_]u21{ 9, 10, 0x20, 0x7e, 0xa0, 0xd7ff, 0xe000, 0xfdcf, 0xfdd0, 0xfdef, 0xfdf0, 0xfffd, 0x10000, 0x1fffe, 0x1ffff, 0x10fffd, 0x10fffe, 0x10ffff }) |cp| {
        const source = try std.fmt.allocPrint(a, "&#x{x};", .{cp});
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try std.testing.expectEqualStrings(buf[0..n], try flattened(a, try r.parseSpans(source, .{})));
    }
    for ([_]u32{ 0, 1, 8, 11, 12, 13, 14, 31, 0x7f, 0x80, 0x9f, 0xd800, 0xdfff, 0xfffe, 0xffff, 0x110000 }) |cp| {
        const source = try std.fmt.allocPrint(a, "&#x{x};", .{cp});
        try std.testing.expectEqualStrings(source, try flattened(a, try r.parseSpans(source, .{})));
    }
}

test "grammar syntax oracle empty wiki cell opener preserves preformatted continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\n|\n code line\n|-\n|   ordinary   || * literal\n|}");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const rows = blocks[0].table.?.rows;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    var code_found = false;
    for (rows[0].cells[0].spans) |span| {
        if (std.mem.indexOf(u8, span.text, "code line") != null) {
            code_found = true;
            try std.testing.expect(span.flags.code);
        }
    }
    try std.testing.expect(code_found);
    try std.testing.expectEqualStrings("ordinary", try flattened(a, rows[1].cells[0].spans));
    try std.testing.expectEqualStrings("* literal", try flattened(a, rows[1].cells[1].spans));
    for (rows[1].cells) |cell| for (cell.spans) |span| try std.testing.expect(!span.flags.code);
}

test "quote scope oracle unmatched and excess markers autoclose on their line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { source: []const u8, visible: []const u8, bold: bool, italic: bool };
    for ([_]Case{
        .{ .source = "''word", .visible = "word", .bold = false, .italic = true },
        .{ .source = "'''word", .visible = "word", .bold = true, .italic = false },
        .{ .source = "'''''word", .visible = "word", .bold = true, .italic = true },
        .{ .source = "''''word", .visible = "'word", .bold = true, .italic = false },
        .{ .source = "''''''word", .visible = "'word", .bold = true, .italic = true },
        .{ .source = "'''''''word", .visible = "''word", .bold = true, .italic = true },
    }) |case| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        var found = false;
        for (spans) |span| if (std.mem.indexOf(u8, span.text, "word") != null) {
            found = true;
            try std.testing.expectEqual(case.bold, span.flags.bold);
            try std.testing.expectEqual(case.italic, span.flags.italic);
        };
        try std.testing.expect(found);
    }
}

test "quote scope oracle labels inherit style while keeping local quotes independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "[[cat|''inside]] after''", "''before [[cat|inside'']] after", "''before [[cat|''inside'' tail]] after'' plain" }, 0..) |source, index| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(source, .{});
        const expected = [_][]const u8{ "inside after", "before inside after", "before inside tail after plain" };
        try std.testing.expectEqualStrings(expected[index], try flattened(a, spans));
        var inside = false;
        var after = false;
        for (spans) |span| {
            if (std.mem.indexOf(u8, span.text, "inside") != null) {
                inside = true;
                try std.testing.expectEqual(ir.InlineKind.link, span.kind);
                try std.testing.expectEqualStrings("cat", span.target);
                try std.testing.expect(span.flags.italic);
            }
            if (std.mem.indexOf(u8, span.text, "after") != null) {
                after = true;
                try std.testing.expect(span.kind != .link);
                try std.testing.expect(span.flags.italic == (index != 0));
            }
            if (std.mem.indexOf(u8, span.text, "plain") != null) try std.testing.expect(!span.flags.italic);
        }
        try std.testing.expect(inside and after);
    }
}

test "quote scope oracle HTML nesting line resets protection and odd counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const html = try r.parseSpans("<b>outer ''inner'' tail</b> plain", .{});
    try std.testing.expectEqualStrings("outer inner tail plain", try flattened(a, html));
    for (html) |span| {
        if (std.mem.indexOf(u8, span.text, "inner") != null) try std.testing.expect(span.flags.bold and span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "tail") != null) try std.testing.expect(span.flags.bold and !span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "plain") != null) try std.testing.expect(!span.flags.bold and !span.flags.italic);
    }
    try std.testing.expectEqualStrings("<i>first</i>\nsecond", try normalizeWikiQuotes(a, "''first\nsecond", 0, false));
    const newline = try r.parseSpans("''first\nsecond", .{});
    try std.testing.expectEqualStrings("first second", try flattened(a, newline));
    for (newline) |span| {
        if (std.mem.indexOf(u8, span.text, "first") != null) try std.testing.expect(span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "second") != null) try std.testing.expect(!span.flags.italic);
    }
    const protected = try r.parseSpans("''word<nowiki>''literal</nowiki>", .{});
    try std.testing.expectEqualStrings("word''literal", try flattened(a, protected));
    for (protected) |span| try std.testing.expect(span.flags.italic);
    const pre = try r.parseSpans("<pre>''literal</pre>", .{});
    try std.testing.expectEqualStrings("''literal", try flattened(a, pre));
    for (pre) |span| try std.testing.expect(!span.flags.italic and !span.flags.bold);
    const odd = try r.parseSpans("a '''b ''c", .{});
    try std.testing.expectEqualStrings("a 'b c", try flattened(a, odd));
    for (odd) |span| {
        try std.testing.expect(!span.flags.bold);
        if (std.mem.indexOf(u8, span.text, "b ") != null) try std.testing.expect(span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "c") != null) try std.testing.expect(!span.flags.italic);
    }
    const blocks = try r.renderBody("''first\n\nsecond");
    for (blocks) |block_value| for (block_value.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "second") != null) try std.testing.expect(!span.flags.italic);
    };
    const malformed = try r.parseSpans("[[broken ''word", .{});
    try std.testing.expectEqualStrings("[[broken word", try flattened(a, malformed));
}

test "quote scope oracle authored HTML crossing retains text and scoped metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const crossing = try r.parseSpans("''before <span lang='fr'>inside'' tail</span> plain", .{});
    try std.testing.expectEqualStrings("before inside tail plain", try flattened(a, crossing));
    for (crossing) |span| {
        if (std.mem.indexOf(u8, span.text, "inside") != null) {
            try std.testing.expect(span.flags.italic);
            try std.testing.expectEqualStrings("fr", span.language);
        }
        if (std.mem.indexOf(u8, span.text, "tail") != null or std.mem.indexOf(u8, span.text, "plain") != null) {
            try std.testing.expect(!span.flags.italic);
            try std.testing.expectEqualStrings("", span.language);
        }
    }
    const nested = try r.parseSpans("''before <span lang='fr' dir='rtl' class='sample'>mid '''bold''' tail</span> after'' plain", .{});
    try std.testing.expectEqualStrings("before mid bold tail after plain", try flattened(a, nested));
    for (nested) |span| {
        if (std.mem.indexOf(u8, span.text, "mid") != null or std.mem.indexOf(u8, span.text, "bold") != null or std.mem.indexOf(u8, span.text, "tail") != null) {
            try std.testing.expect(span.flags.italic);
            try std.testing.expectEqualStrings("fr", span.language);
            try std.testing.expectEqualStrings("rtl", span.direction);
            try std.testing.expectEqualStrings("sample", span.classes);
        }
        if (std.mem.indexOf(u8, span.text, "bold") != null) try std.testing.expect(span.flags.bold);
        if (std.mem.indexOf(u8, span.text, "mid") != null or std.mem.indexOf(u8, span.text, "tail") != null) try std.testing.expect(!span.flags.bold);
        if (std.mem.indexOf(u8, span.text, "before") != null or std.mem.indexOf(u8, span.text, "after") != null or std.mem.indexOf(u8, span.text, "plain") != null) {
            try std.testing.expectEqualStrings("", span.language);
            try std.testing.expectEqualStrings("", span.direction);
            try std.testing.expectEqualStrings("", span.classes);
        }
        if (std.mem.indexOf(u8, span.text, "plain") != null) try std.testing.expect(!span.flags.italic and !span.flags.bold);
    }
}

test "quote scope oracle external labels and URL delimiters preserve targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { source: []const u8, visible: []const u8, target: []const u8, after_italic: bool };
    for ([_]Case{
        .{ .source = "[https://example.test ''inside] after''", .visible = "inside after", .target = "https://example.test", .after_italic = true },
        .{ .source = "''before [https://example.test ''inside'' tail] after'' plain", .visible = "before inside tail after plain", .target = "https://example.test", .after_italic = true },
        .{ .source = "[https://example.test/path''part label] tail", .visible = "part label tail", .target = "https://example.test/path", .after_italic = true },
        .{ .source = "''https://example.test/path'' plain", .visible = "https://example.test/path plain", .target = "https://example.test/path", .after_italic = false },
        .{ .source = "https://example.test/path''part tail", .visible = "https://example.test/pathpart tail", .target = "https://example.test/path", .after_italic = true },
    }, 0..) |case, index| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        var linked = false;
        for (spans) |span| {
            if (span.kind == .external_link) {
                linked = true;
                try std.testing.expectEqualStrings(case.target, span.target);
                if (std.mem.indexOf(u8, span.text, "inside") != null) try std.testing.expect(span.flags.italic == (index == 0));
                if (std.mem.indexOf(u8, span.text, "part") != null or std.mem.indexOf(u8, span.text, "tail") != null or index == 3) try std.testing.expect(span.flags.italic);
            }
            if (std.mem.indexOf(u8, span.text, "after") != null or (std.mem.indexOf(u8, span.text, "tail") != null and span.kind != .external_link)) {
                try std.testing.expect(span.kind != .external_link);
                try std.testing.expectEqual(case.after_italic, span.flags.italic);
            }
            if (std.mem.indexOf(u8, span.text, "plain") != null) try std.testing.expect(!span.flags.italic);
        }
        try std.testing.expect(linked);
    }
    var r: Renderer = .{ .a = a, .context = .{} };
    const unchanged = try r.parseSpans("[https://example.test inside] after", .{});
    try std.testing.expectEqualStrings("inside after", try flattened(a, unchanged));
    for (unchanged) |span| {
        try std.testing.expect(!span.flags.italic and !span.flags.bold);
        if (span.kind == .external_link) try std.testing.expectEqualStrings("https://example.test", span.target);
    }
    const no_label = try r.parseSpans("[https://example.test]", .{});
    try std.testing.expectEqualStrings("https://example.test", try flattened(a, no_label));
    for (no_label) |span| try std.testing.expectEqualStrings("https://example.test", span.target);
    const protected = try r.parseSpans("<nowiki>[https://example.test ''literal]</nowiki>", .{});
    try std.testing.expectEqualStrings("[https://example.test ''literal]", try flattened(a, protected));
    for (protected) |span| try std.testing.expect(span.kind != .external_link and !span.flags.italic);
}

test "quote scope oracle malformed opener retains parsed HTML and nested targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const html = try r.parseSpans("[[broken <b>bold</b> tail", .{});
    try std.testing.expectEqualStrings("[[broken bold tail", try flattened(a, html));
    for (html) |span| if (std.mem.indexOf(u8, span.text, "bold") != null) try std.testing.expect(span.flags.bold);
    const nested = try r.parseSpans("[[broken [[cat|inside]] tail", .{});
    try std.testing.expectEqualStrings("[[broken inside tail", try flattened(a, nested));
    var inside = false;
    for (nested) |span| {
        if (std.mem.indexOf(u8, span.text, "inside") != null) {
            inside = true;
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings("cat", span.target);
        } else try std.testing.expect(span.kind != .link);
    }
    try std.testing.expect(inside);
}

test "quote scope oracle deferred both preserves transition styles and metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { source: []const u8, visible: []const u8, tail_bold: bool, tail_italic: bool };
    for ([_]Case{
        .{ .source = "'''''both''bold''' plain", .visible = "bothbold plain", .tail_bold = true, .tail_italic = false },
        .{ .source = "'''''both'''italic'' plain", .visible = "bothitalic plain", .tail_bold = false, .tail_italic = true },
        .{ .source = "'''''both''''' plain", .visible = "both plain", .tail_bold = false, .tail_italic = false },
    }) |case| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        for (spans) |span| {
            if (std.mem.indexOf(u8, span.text, "both") != null) try std.testing.expect(span.flags.bold and span.flags.italic);
            if (std.mem.indexOf(u8, span.text, "bold") != null or std.mem.indexOf(u8, span.text, "italic") != null) {
                try std.testing.expectEqual(case.tail_bold, span.flags.bold);
                try std.testing.expectEqual(case.tail_italic, span.flags.italic);
            }
            if (std.mem.indexOf(u8, span.text, "plain") != null) try std.testing.expect(!span.flags.bold and !span.flags.italic);
        }
    }
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("'''''<span lang='fr' dir='rtl'>both</span>", .{});
    try std.testing.expectEqualStrings("both", try flattened(a, spans));
    for (spans) |span| {
        try std.testing.expect(span.flags.bold and span.flags.italic);
        try std.testing.expectEqualStrings("fr", span.language);
        try std.testing.expectEqualStrings("rtl", span.direction);
    }
}

test "quote scope oracle multiline internal label retains its whole label scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    try std.testing.expectEqualStrings("[[cat|<i>first\nsecond</i>]] after", try normalizeWikiQuotes(a, "[[cat|''first\nsecond]] after", 0, false));
    const spans = try r.parseSpans("[[cat|''first\nsecond]] after", .{});
    try std.testing.expectEqualStrings("first second after", try flattened(a, spans));
    var first = false;
    var second = false;
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "first") != null or std.mem.indexOf(u8, span.text, "second") != null) {
            first = first or std.mem.indexOf(u8, span.text, "first") != null;
            second = second or std.mem.indexOf(u8, span.text, "second") != null;
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings("cat", span.target);
            try std.testing.expect(span.flags.italic);
        }
        if (std.mem.indexOf(u8, span.text, "after") != null) try std.testing.expect(span.kind != .link and !span.flags.italic);
    }
    try std.testing.expect(first and second);
}

test "quote scope oracle empty reopened external fragment has no URL label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("''[https://example.test inside'']", .{});
    try std.testing.expectEqualStrings("inside", try flattened(a, spans));
    for (spans) |span| {
        try std.testing.expectEqual(ir.InlineKind.external_link, span.kind);
        try std.testing.expectEqualStrings("https://example.test", span.target);
        try std.testing.expect(span.flags.italic);
    }
    const authored = try r.parseSpans("[https://example.test ]", .{});
    try std.testing.expectEqualStrings("https://example.test", try flattened(a, authored));
    for (authored) |span| try std.testing.expectEqualStrings("https://example.test", span.target);
}

test "quote scope oracle unchanged label retains existing HTML repair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("[[cat|<b>bold <i>both</b> italic</i>]] plain", .{});
    try std.testing.expectEqualStrings("bold both italic plain", try flattened(a, spans));
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, "bold") != null) try std.testing.expect(span.flags.bold and !span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "both") != null) try std.testing.expect(span.flags.bold and span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "italic") != null) try std.testing.expect(!span.flags.bold and span.flags.italic);
        if (std.mem.indexOf(u8, span.text, "plain") != null) {
            try std.testing.expect(span.kind != .link and !span.flags.bold and !span.flags.italic);
        } else {
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings("cat", span.target);
        }
    }
    const borrowed: []const u8 = "[[cat|<b>balanced</b>]] <nowiki>''literal</nowiki>";
    const normalized = try normalizeMisnestedHtml(a, try normalizeWikiQuotes(a, borrowed, 0, false));
    try std.testing.expect(normalized.ptr == borrowed.ptr);
}

test "table closing oracle suffix stays visible without new line semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "{|\n| cell\n|}tail", .visible = "tail" },
        .{ .source = "{|\n| cell\n|} tail", .visible = "tail" },
        .{ .source = "{|\n| cell\n|}# tail", .visible = "# tail" },
        .{ .source = "{|\n| cell\n|}| tail", .visible = "| tail" },
    }) |case| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(case.source);
        try std.testing.expectEqual(@as(usize, 2), blocks.len);
        try std.testing.expectEqual(Kind.table, blocks[0].kind);
        try std.testing.expectEqualStrings("cell", try flattened(a, blocks[0].table.?.rows[0].cells[0].spans));
        try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
        try std.testing.expectEqualStrings(case.visible, trim(try flattened(a, blocks[1].spans)));
        for (blocks[1].spans) |span| try std.testing.expect(!span.flags.code);
    }
    var newline: Renderer = .{ .a = a, .context = .{} };
    const blocks = try newline.renderBody("{|\n| cell\n|}\n# real list\n code line");
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
    try std.testing.expectEqualStrings("real list", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.preformatted, blocks[2].kind);
    try std.testing.expectEqualStrings("code line", trim(try flattened(a, blocks[2].spans)));
}

test "table closing oracle inline HTML and wrapper suffix retain text and style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\n| cell\n|}<i>tail</i> after");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
    try std.testing.expectEqualStrings("tail after", try flattened(a, blocks[1].spans));
    var italic_found = false;
    for (blocks[1].spans) |span| {
        if (std.mem.indexOf(u8, span.text, "tail") != null) {
            italic_found = true;
            try std.testing.expect(span.flags.italic);
        }
        if (std.mem.indexOf(u8, span.text, "after") != null) try std.testing.expect(!span.flags.italic);
    }
    try std.testing.expect(italic_found);
    var wrapper: Renderer = .{ .a = a, .context = .{} };
    const wrapped = try wrapper.renderBody("<div>before\n{|\n| cell\n|}</div><b>tail</b> after");
    var before_found = false;
    var table_found = false;
    var tail_found = false;
    for (wrapped) |block_value| {
        if (block_value.kind == .table) {
            table_found = true;
            try std.testing.expectEqualStrings("cell", try flattened(a, block_value.table.?.rows[0].cells[0].spans));
        }
        for (block_value.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "before") != null) before_found = true;
            if (std.mem.indexOf(u8, span.text, "tail") != null) {
                tail_found = true;
                try std.testing.expect(span.flags.bold);
            }
            if (std.mem.indexOf(u8, span.text, "after") != null) try std.testing.expect(!span.flags.bold);
            try std.testing.expect(std.mem.indexOf(u8, span.text, "|}") == null);
            try std.testing.expect(std.mem.indexOf(u8, span.text, "</div>") == null);
        }
    }
    try std.testing.expect(before_found and table_found and tail_found);
}

test "table closing oracle nested tails and protected markers preserve cell ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\n| outer cell\n{|\n| inner cell\n|}inner tail\n|}outer tail");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    const cell = try flattened(a, blocks[0].table.?.rows[0].cells[0].spans);
    for ([_][]const u8{ "outer cell", "inner cell", "inner tail" }) |part| try std.testing.expect(std.mem.indexOf(u8, cell, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, cell, "outer tail") == null);
    try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
    try std.testing.expectEqualStrings("outer tail", try flattened(a, blocks[1].spans));
    var protected: Renderer = .{ .a = a, .context = .{} };
    const literal = try protected.renderBody("{|\n| <nowiki>|}literal</nowiki>\n|}tail");
    try std.testing.expectEqual(@as(usize, 2), literal.len);
    try std.testing.expectEqual(Kind.table, literal[0].kind);
    try std.testing.expectEqualStrings("|}literal", try flattened(a, literal[0].table.?.rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("tail", try flattened(a, literal[1].spans));
}

test "visible preservation oracle protected blocks retain same-line suffix and newline ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, tail: []const u8, kind: Kind = .paragraph }{
        .{ .source = "<pre>code</pre>after", .tail = "after" },
        .{ .source = "<pre>code</pre> #after", .tail = "#after" },
        .{ .source = "<pre>one\ntwo</pre><b>after</b>", .tail = "after" },
        .{ .source = "<pre>code</pre>\n# after", .tail = "after", .kind = .definition },
        .{ .source = "<syntaxhighlight lang='text'>code</syntaxhighlight>after", .tail = "after" },
    };
    for (cases) |case| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(case.source);
        try std.testing.expectEqual(@as(usize, 2), blocks.len);
        try std.testing.expectEqual(Kind.preformatted, blocks[0].kind);
        try std.testing.expectEqual(case.kind, blocks[1].kind);
        try std.testing.expectEqualStrings(case.tail, try flattened(a, blocks[1].spans));
        for (blocks[0].spans) |span| try std.testing.expect(span.flags.code);
        for (blocks[1].spans) |span| try std.testing.expect(!span.flags.code);
        if (std.mem.indexOf(u8, case.source, "<b>after") != null) try std.testing.expect(blocks[1].spans[0].flags.bold);
    }
    var protected: Renderer = .{ .a = a, .context = .{} };
    const literal = try protected.renderBody("<nowiki><pre>code</pre>after</nowiki>");
    try std.testing.expectEqual(@as(usize, 1), literal.len);
    try std.testing.expectEqualStrings("<pre>code</pre>after", try flattened(a, literal[0].spans));
    var negative: Renderer = .{ .a = a, .context = .{} };
    const unrelated = try negative.renderBody("<prefix>code</prefix>after");
    try std.testing.expectEqualStrings("<prefix>code</prefix>after", try flattened(a, unrelated[0].spans));
}

test "visible preservation oracle wiki-table outside text retains blocks without inventing cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\nloose\n| cell\n|}");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("loose", try flattened(a, blocks[0].spans));
    const table = blocks[1].table.?;
    try std.testing.expectEqual(@as(usize, 0), table.caption.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqualStrings("cell", try flattened(a, table.rows[0].cells[0].spans));
    var rows: Renderer = .{ .a = a, .context = .{} };
    const separated = try rows.renderBody("{|\n| first\n|-\n<b>loose</b>\n| second\n|}");
    try std.testing.expectEqual(@as(usize, 2), separated.len);
    try std.testing.expectEqualStrings("loose", try flattened(a, separated[0].spans));
    try std.testing.expect(separated[0].spans[0].flags.bold);
    try std.testing.expectEqual(@as(usize, 2), separated[1].table.?.rows.len);
    try std.testing.expectEqualStrings("first", try flattened(a, separated[1].table.?.rows[0].cells[0].spans));
    try std.testing.expectEqualStrings("second", try flattened(a, separated[1].table.?.rows[1].cells[0].spans));
    var lists: Renderer = .{ .a = a, .context = .{} };
    const notice = try lists.renderBody("{|\n* notice\n| <nowiki>loose |} literal</nowiki>\n|}");
    try std.testing.expectEqual(@as(usize, 2), notice.len);
    try std.testing.expectEqual(Kind.list_item, notice[0].kind);
    try std.testing.expectEqualStrings("notice", try flattened(a, notice[0].spans));
    try std.testing.expectEqualStrings("loose |} literal", try flattened(a, notice[1].table.?.rows[0].cells[0].spans));
    var rowless: Renderer = .{ .a = a, .context = .{} };
    const recovered = try rowless.renderBody("{|\nloose\n|}");
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqualStrings("loose", try flattened(a, recovered[0].spans));
    var mixed_rowless: Renderer = .{ .a = a, .context = .{} };
    _ = try mixed_rowless.renderBody("{|\nloose<ref>once</ref>\n<tr></tr>\n|}");
    const once = try mixed_rowless.finishReferences();
    try std.testing.expectEqual(@as(usize, 1), once.len);
    try std.testing.expectEqualStrings("once", once[0].body);
    var mixed_order: Renderer = .{ .a = a, .context = .{} };
    _ = try mixed_order.renderBody("{|\n<ref>before</ref>\n<tr><nowiki><td>literal</td></nowiki></tr>\n<tr><td><ref>cell</ref></td></tr>\n|}");
    const ordered = try mixed_order.finishReferences();
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqualStrings("before", ordered[0].body);
    try std.testing.expectEqualStrings("cell", ordered[1].body);
    var ordinary: Renderer = .{ .a = a, .context = .{} };
    const normal = try ordinary.renderBody("{|\n| loose\n|}");
    try std.testing.expectEqual(@as(usize, 1), normal.len);
    try std.testing.expectEqualStrings("loose", try flattened(a, normal[0].table.?.rows[0].cells[0].spans));
}

test "wiki table boundary: colon-indented retain typed indentation and close-line suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, path: []const u8 }{
        .{ .source = ": {|\n| ''cell''\n|} #tail", .path = ":" },
        .{ .source = "::{|\n| ''cell''\n|} #tail", .path = "::" },
        .{ .source = " : {|\n| ''cell''\n|} #tail", .path = ":" },
    };
    for (cases) |c| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(c.source);
        try std.testing.expectEqual(@as(usize, 2), blocks.len);
        try std.testing.expectEqual(Kind.table, blocks[0].kind);
        try std.testing.expectEqualStrings(c.path, blocks[0].list_path);
        try std.testing.expectEqual(@as(u8, @intCast(c.path.len)), blocks[0].depth);
        const table = blocks[0].table.?;
        try std.testing.expectEqual(@as(usize, 1), table.rows.len);
        try std.testing.expectEqual(@as(usize, 1), table.rows[0].cells.len);
        try std.testing.expectEqualStrings("cell", try flattened(a, table.rows[0].cells[0].spans));
        try std.testing.expect(table.rows[0].cells[0].spans[0].flags.italic);
        try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
        try std.testing.expectEqualStrings("#tail", try flattened(a, blocks[1].spans));
        try std.testing.expect(!r.fallbacks.malformed_table);
    }
    var ordinary: Renderer = .{ .a = a, .context = .{} };
    const normal = try ordinary.renderBody("{|\n| cell\n|}\n# after");
    try std.testing.expectEqual(Kind.table, normal[0].kind);
    try std.testing.expectEqualStrings("", normal[0].list_path);
    try std.testing.expectEqual(@as(u8, 0), normal[0].depth);
    try std.testing.expectEqual(Kind.definition, normal[1].kind);
    var fostered: Renderer = .{ .a = a, .context = .{} };
    const loose = try fostered.renderBody(": {|\nloose\n|+ Forms\n| cell\n|}");
    try std.testing.expectEqual(@as(usize, 2), loose.len);
    try std.testing.expectEqualStrings("loose", try flattened(a, loose[0].spans));
    try std.testing.expectEqualStrings(":", loose[0].list_path);
    try std.testing.expectEqual(@as(u8, 1), loose[0].depth);
    try std.testing.expectEqual(Kind.table, loose[1].kind);
    try std.testing.expectEqualStrings(":", loose[1].list_path);
    try std.testing.expectEqualStrings("Forms", try flattened(a, loose[1].table.?.caption));
}

test "wiki table boundary: colon-indented preserve literal and non-table controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "<nowiki>: {|\n| cell\n|}</nowiki>",
        "<nowiki>: {|\n| cell\n|}",
        "*: {|\n| cell\n|}",
        "<pre>code</pre>: {|\n| cell\n|}",
    }) |source| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(source);
        var visible: std.ArrayList(u8) = .empty;
        for (blocks) |b| {
            try std.testing.expect(b.table == null);
            try visible.appendSlice(a, try flattened(a, b.spans));
        }
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "{|") != null);
    }
    var indented: Renderer = .{ .a = a, .context = .{} };
    const text = try indented.renderBody(": ordinary");
    try std.testing.expectEqual(Kind.indent, text[0].kind);
    try std.testing.expectEqualStrings(":", text[0].list_path);
    try std.testing.expectEqualStrings("ordinary", try flattened(a, text[0].spans));
    var pre: Renderer = .{ .a = a, .context = .{} };
    const spaced = try pre.renderBody(" : ordinary");
    try std.testing.expectEqual(Kind.preformatted, spaced[0].kind);
    try std.testing.expectEqualStrings(": ordinary", try flattened(a, spaced[0].spans));
    try std.testing.expect(spaced[0].spans[0].flags.code);
}

test "wiki table boundary: colon-indented retain nested and unterminated content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nested: Renderer = .{ .a = a, .context = .{} };
    const blocks = try nested.renderBody(": {|\n| outer\n:: {|\n| inner\n|}\ntail\n|} after");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    try std.testing.expectEqualStrings(":", blocks[0].list_path);
    const content = try flattened(a, blocks[0].table.?.rows[0].cells[0].spans);
    try std.testing.expect(std.mem.indexOf(u8, content, "outer") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "inner"));
    try std.testing.expect(std.mem.indexOf(u8, content, "tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "{|") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "|}") == null);
    try std.testing.expectEqualStrings("after", try flattened(a, blocks[1].spans));
    try std.testing.expect(!nested.fallbacks.malformed_table);
    // Preserve the existing ordinary-table recovery diagnostic; this control
    // makes no fresh malformed-wikitext parity claim against MediaWiki.
    var unclosed: Renderer = .{ .a = a, .context = .{} };
    const recovered = try unclosed.renderBody(": {|\n| cell");
    try std.testing.expectEqual(Kind.table, recovered[0].kind);
    try std.testing.expectEqualStrings(":", recovered[0].list_path);
    try std.testing.expectEqualStrings("cell", try flattened(a, recovered[0].table.?.rows[0].cells[0].spans));
    try std.testing.expect(unclosed.fallbacks.malformed_table);
}

test "wiki table boundary: caption-only tables retain links and continuation references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plain: Renderer = .{ .a = a, .context = .{} };
    const simple = try plain.renderBody("{|\n|+ Caption [[word]]\n|-\n|}");
    try std.testing.expectEqual(@as(usize, 1), simple.len);
    try std.testing.expectEqual(Kind.table, simple[0].kind);
    try std.testing.expectEqual(@as(usize, 0), simple[0].table.?.rows.len);
    try std.testing.expectEqualStrings("Caption word", try flattened(a, simple[0].table.?.caption));
    var word_link = false;
    for (simple[0].table.?.caption) |s| if (std.mem.eql(u8, s.text, "word")) {
        word_link = s.kind == .link and std.mem.eql(u8, s.target, "word");
    };
    try std.testing.expect(word_link);
    try std.testing.expect(!plain.fallbacks.malformed_table);
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(": {|\nbefore <ref name=b>Before</ref>\n|+ Caption <ref name=c>Caption</ref>\nafter <ref name=a>After</ref>\n|-\n|}");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings(":", blocks[0].list_path);
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
    try std.testing.expectEqualStrings(":", blocks[1].list_path);
    const before_text = try flattened(a, blocks[0].spans);
    const caption_text = try flattened(a, blocks[1].table.?.caption);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, before_text, "before"));
    try std.testing.expect(std.mem.indexOf(u8, before_text, "after") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, caption_text, "Caption"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, caption_text, "after"));
    try std.testing.expect(std.mem.indexOf(u8, caption_text, "|+") == null);
    try std.testing.expect(std.mem.indexOf(u8, caption_text, "|-") == null);
    const refs = try r.finishReferences();
    try std.testing.expectEqual(@as(usize, 3), refs.len);
    for ([_][]const u8{ "b", "c", "a" }, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, refs[i].name);
        try std.testing.expectEqual(i + 1, refs[i].number);
    }
    try std.testing.expect(!r.fallbacks.malformed_table);
    var empty: Renderer = .{ .a = a, .context = .{} };
    const empty_blocks = try empty.renderBody("{|\n|+\n|}");
    try std.testing.expectEqual(Kind.table, empty_blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 0), empty_blocks[0].table.?.caption.len);
    try std.testing.expect(!empty.fallbacks.malformed_table);
    var rowless: Renderer = .{ .a = a, .context = .{} };
    const recovery = try rowless.renderBody("{|\nloose\n|}");
    try std.testing.expectEqualStrings("loose", try flattened(a, recovery[0].spans));
    try std.testing.expect(rowless.fallbacks.malformed_table);
}

test "wiki table boundary: fostered list ancestry and numbered-list transitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(": {|\n* notice\n| cell\n|}");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.list_item, blocks[0].kind);
    try std.testing.expectEqualStrings(":*", blocks[0].list_path);
    try std.testing.expectEqual(@as(u8, 2), blocks[0].depth);
    try std.testing.expectEqualStrings("notice", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
    var numbered: Renderer = .{ .a = a, .context = .{} };
    const ordered = try numbered.renderBody("# before\n: {|\n| cell\n|}\n# after");
    try std.testing.expectEqual(@as(usize, 3), ordered.len);
    try std.testing.expectEqual(Kind.definition, ordered[0].kind);
    try std.testing.expectEqualStrings("1", ordered[0].number);
    try std.testing.expectEqual(Kind.table, ordered[1].kind);
    try std.testing.expectEqual(Kind.definition, ordered[2].kind);
    try std.testing.expectEqualStrings("1", ordered[2].number);
}

test "wiki cell attributes stop before a nested Finnish NavFrame table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    // Reduced from YYA -> fi-decl-maa-dot -> fi-decl-internal -> fi-decl-table.
    // The authored template puts this HTML-wrapped grid inside a layout cell.
    const blocks = try r.renderBody(
        "{| width=\"40%\"\n|-\n|<div class=\"NavFrame\">\n" ++
            "<div class=\"NavHead fi-decl-header-row\">Inflection of YYA</div>\n" ++
            "<div class=\"NavContent\">\n" ++
            "{| class=\"inflection-table fi-decl fi-decl-old\" cellspacing=\"1\" cellpadding=\"2\"\n" ++
            "|-\n! class=\"thnum\" |\n! class=\"thnum\" | singular\n! class=\"thnum\" | plural\n" ++
            "|-\n! nominative\n| [[YYA]]\n| &ndash;\n" ++
            "|-\n! genitive\n| [[YYA:n]]\n| &ndash;\n|-\n|}\n" ++
            "</div>\n</div>\n|}\n",
    );
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(Kind.table, blocks[0].kind);
    const table = blocks[0].table.?;
    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows[0].cells.len);
    const text_value = try flattened(a, table.rows[0].cells[0].spans);
    try std.testing.expect(std.mem.startsWith(u8, text_value, "Inflection of YYA\n"));
    try std.testing.expect(std.mem.indexOf(u8, text_value, "singular · plural") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "nominative · YYA · –") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_value, "genitive · YYA:n · –") != null);
    inline for (.{ "{|", "|-", "|}", "class=", "cellspacing=" }) |raw_control|
        try std.testing.expect(std.mem.indexOf(u8, text_value, raw_control) == null);
    try std.testing.expect(!r.fallbacks.malformed_table);
}

test "wiki cell attributes retain legitimate colspan rowspan and style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r: Renderer = .{ .a = arena.allocator(), .context = .{} };
    const first = try r.cellContent(" colspan=2 style=\"color: red\" | kept");
    try std.testing.expectEqualStrings("kept", first.text);
    try std.testing.expectEqual(@as(u16, 2), first.colspan);
    try std.testing.expectEqual(@as(u16, 1), first.rowspan);
    const second = try r.cellContent(" style='text-align:center' rowspan='3' | other");
    try std.testing.expectEqualStrings("other", second.text);
    try std.testing.expectEqual(@as(u16, 1), second.colspan);
    try std.testing.expectEqual(@as(u16, 3), second.rowspan);
    const body = "<div class=\"NavFrame\">\n{| class=inflection\n| value\n|}\n</div>";
    const unchanged = try r.cellContent(body);
    try std.testing.expectEqualStrings(body, unchanged.text);
}

test "wiki cell attribute pipes inside quotes remain attribute values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(
        "{|\n|-\n| colspan=\"2\" style=\"font-family:'a|b'\" | [[kept]]\n" ++
            "| rowspan='3' style='font-family:\"c|d\"' | other\n|}\n",
    );
    const cells = blocks[0].table.?.rows[0].cells;
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    try std.testing.expectEqualStrings("kept", try flattened(a, cells[0].spans));
    try std.testing.expectEqual(@as(u16, 2), cells[0].colspan);
    try std.testing.expectEqualStrings("other", try flattened(a, cells[1].spans));
    try std.testing.expectEqual(@as(u16, 3), cells[1].rowspan);
    const unmatched = "style=\"unclosed | body";
    try std.testing.expectEqualStrings(unmatched, (try r.cellContent(unmatched)).text);
}

test "unknown parser entity braces keep complete external target and intended label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{ .title = "शारदा", .language = "Hindi" } };
    const spans = try renderer.parseSpans("[https://hindwidictionary.com/search?keyword=&#123;&#123;#urlencode:शारदा&#125;&#125; शारदा]", .{});
    try std.testing.expectEqualStrings("शारदा", try flattened(a, spans));
    try std.testing.expect(spans.len != 0);
    for (spans) |span| {
        try std.testing.expectEqual(ir.InlineKind.external_link, span.kind);
        try std.testing.expectEqualStrings("https://hindwidictionary.com/search?keyword={{#urlencode:शारदा}}", span.target);
    }
    const spaces = try renderer.parseSpans("[https://example.test/?q=&#123;&#123;#urlencode:alpha beta&#125;&#125; label]", .{});
    try std.testing.expectEqualStrings("beta}} label", try flattened(a, spaces));
    for (spaces) |span| try std.testing.expectEqualStrings("https://example.test/?q={{#urlencode:alpha", span.target);
    const authored_nowiki = try renderer.parseSpans("[https://example.test/?q=<nowiki>{{alpha beta}}</nowiki> label]", .{});
    try std.testing.expectEqualStrings("{{alpha beta}} label", try flattened(a, authored_nowiki));
    for (authored_nowiki) |span| try std.testing.expectEqualStrings("https://example.test/?q=", span.target);
    const html_label = try renderer.parseSpans("[https://example.test/?q=x <i>label</i>]", .{});
    try std.testing.expectEqualStrings("label", try flattened(a, html_label));
    for (html_label) |span| try std.testing.expectEqualStrings("https://example.test/?q=x", span.target);
    var literal: Renderer = .{ .a = a, .context = .{} };
    const protected = try literal.parseSpans("<nowiki>{{#urlencode:x}}</nowiki>", .{});
    try std.testing.expectEqualStrings("{{#urlencode:x}}", try flattened(a, protected));
    for (protected) |span| {
        try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
        try std.testing.expectEqual(ir.InlineKind.text, span.kind);
    }
}

test "unclosed div attribute Greek headwords retain lexical links without markup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<div class='mw-collapsible mw-collapsed' style='display: inline' data-expandtext='2 headwords><ul><li>[[caw]] idem, page 120.</li><li>[[croak]] idem, page 185.</li></ul></div>", .{});
    const visible = try flattened(a, spans);
    try std.testing.expect(std.mem.indexOf(u8, visible, "<div") == null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "caw idem, page 120.") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "croak idem, page 185.") != null);
    var links: usize = 0;
    for (spans) |span| if (span.kind == .link) {
        links += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), links);
    const ordinary = syntax.tagAt("<div title=\"ordinary title>body</div>", 0).?;
    try std.testing.expectEqualStrings("ordinary title", ordinary.attr("title").?);
}

test "unclosed div attribute Marathi NavFrame retains heading and table cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody(
        "<div class=\"NavFrame\" style=\"display: table;>\n" ++
            "<div class=\"NavHead\">Personal forms of पाघळणे</div>\n<div class=\"NavContent\">\n" ++
            "{| class=\"inflection-table\"\n! colspan=\"2\" | future\n|-\n| [[पाघळणे]] || [[पाघळ-]]\n|}\n</div></div>\nAfter",
    );
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("Personal forms of पाघळणे", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.table, blocks[1].kind);
    const table = blocks[1].table.?;
    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(u16, 2), table.rows[0].cells[0].colspan);
    try std.testing.expectEqualStrings("पाघळणे", try flattened(a, table.rows[1].cells[0].spans));
    try std.testing.expectEqualStrings("पाघळ-", try flattened(a, table.rows[1].cells[1].spans));
    try std.testing.expectEqualStrings("After", try flattened(a, blocks[2].spans));
}

test "unclosed div attribute recovery preserves quoted and protected literal controls" {
    const quoted = syntax.tagAt("<div style=\"a>b\">body</div>", 0).?;
    try std.testing.expectEqualStrings("a>b", quoted.attr("style").?);
    const multiline = syntax.tagAt("<div style=\"a>b\nline two\">body</div>", 0).?;
    try std.testing.expectEqualStrings("a>b\nline two", multiline.attr("style").?);
    const angles = syntax.tagAt("<div title=\"a><b>foo\">body</div>", 0).?;
    try std.testing.expectEqualStrings("a><b>foo", angles.attr("title").?);
    const multiline_angles = syntax.tagAt("<div title=\"a>\n<b>foo\">body</div>", 0).?;
    try std.testing.expectEqualStrings("a>\n<b>foo", multiline_angles.attr("title").?);
    try std.testing.expect(syntax.tagAt("<widget title=\"literal>body</widget>", 0) == null);
    try std.testing.expect(syntax.tagAt("<re>ctis", 0).?.is("re"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const literal = "<div class=\"NavFrame\" style=\"display: table;>";
    inline for (&.{ "nowiki", "pre" }) |name| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const input = try std.fmt.allocPrint(a, "<{s}>{s}</{s}>", .{ name, literal, name });
        const spans = try r.parseSpans(input, .{});
        try std.testing.expectEqualStrings(literal, try flattened(a, spans));
    }
    var code: Renderer = .{ .a = a, .context = .{} };
    const code_spans = try code.parseSpans("<code>&lt;div class=&quot;NavFrame&quot; style=&quot;display: table;&gt;</code>", .{});
    try std.testing.expectEqualStrings(literal, try flattened(a, code_spans));
    for (code_spans) |span| try std.testing.expect(span.flags.code);
    var editorial: Renderer = .{ .a = a, .context = .{} };
    try std.testing.expectEqualStrings("<re>ctis", try flattened(a, try editorial.parseSpans("<re>ctis", .{})));
}

fn externalDelimiterCheck(source: []const u8, visible: []const u8, target: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans(source, .{});
    var out: std.ArrayList(u8) = .empty;
    for (spans) |span| {
        try out.appendSlice(a, span.text);
        if (target) |url| {
            try std.testing.expectEqual(.external_link, span.kind);
            try std.testing.expectEqualStrings(url, span.target);
        } else {
            try std.testing.expectEqual(.text, span.kind);
            try std.testing.expectEqualStrings("", span.target);
        }
    }
    try std.testing.expectEqualStrings(visible, out.items);
}
test "external delimiter fixture raw Unicode Zs labels" {
    for ([_]u21{ 0x00a0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x202f, 0x205f, 0x3000 }) |cp| {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        var source: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(&source, "[https://example.test{s}label]", .{buf[0..n]});
        try externalDelimiterCheck(input, "label", "https://example.test");
    }
    try externalDelimiterCheck("[https://example.test \xc2\xa0\xe2\x80\x82\tlabel]", "label", "https://example.test");
}
test "external delimiter fixture encoded-angle URL suffix belongs to label" {
    try externalDelimiterCheck("[https://example.test&lt;word label]", "<word label", "https://example.test");
    try externalDelimiterCheck("[https://example.test&gt;word label]", ">word label", "https://example.test");
    try externalDelimiterCheck("[https://example.test&lt;word&amp;x label]", "<word&x label", "https://example.test");
    try externalDelimiterCheck("[https://example.test&lt;word&gt; label]", "<word> label", "https://example.test");
    // Parser.php constructs a nonempty suffix plus one ASCII space even without
    // an authored label. This checks that exact compiler label, not browser layout.
    try externalDelimiterCheck("[https://example.test&lt;word]", "<word ", "https://example.test");
    try externalDelimiterCheck("[https://example.test&gt;word]", ">word ", "https://example.test");
    try externalDelimiterCheck("[https://example.test&lt;word \xc2\xa0\xe2\x80\x82label]", "<word label", "https://example.test");
}
test "external delimiter fixture protected literals and existing URLs" {
    try externalDelimiterCheck("<nowiki>[https://example.test\xc2\xa0label]</nowiki>", "[https://example.test\xc2\xa0label]", null);
    try externalDelimiterCheck("<pre>[https://example.test&lt;word label]</pre>", "[https://example.test<word label]", null);
    try externalDelimiterCheck("<code><nowiki>[https://example.test&gt;word label]</nowiki></code>", "[https://example.test>word label]", null);
    try externalDelimiterCheck("[https://example.test/?a=1&amp;b=2 label]", "label", "https://example.test/?a=1&b=2");
    try externalDelimiterCheck("[https://example.test/?a=1&amp;b=2]", "https://example.test/?a=1&b=2", "https://example.test/?a=1&b=2");
    try externalDelimiterCheck("https://example.test/?a=1&amp;b=2", "https://example.test/?a=1&b=2", "https://example.test/?a=1&b=2");
    try externalDelimiterCheck("[https://example.test <nowiki>&lt;word</nowiki> label]", "<word label", "https://example.test");
    try externalDelimiterCheck("https://example.test&lt;word", "https://example.test<word", null);
    try externalDelimiterCheck("[https://example.test&#60;word label]", "label", null);
    try externalDelimiterCheck("[https://example.test&LT;word label]", "label", null);
}

test "nested label fixture ordinary link recovery preserves outer text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try @import("namespace_registry").Registry.init(a, @import("namespace_registry").french_test_fixture);
    defer registry.deinit();
    const cases = [_]struct { source: []const u8, visible: []const u8, linked: []const u8, target: []const u8 }{
        .{ .source = "[[A|[[B]]]]", .visible = "[[A|B]]", .linked = "B", .target = "B" },
        .{ .source = "[[A|before [[B|inside]] after]]", .visible = "[[A|before inside after]]", .linked = "inside", .target = "B" },
        .{ .source = "[[:|[[B]]]]", .visible = "[[:|B]]", .linked = "B", .target = "B" },
        .{ .source = "[[Category:A|[[B]]]]", .visible = "[[Category:A|B]]", .linked = "B", .target = "B" },
        .{ .source = "[[Catégorie:A|[[B]]]]", .visible = "[[Catégorie:A|B]]", .linked = "B", .target = "B" },
        .{ .source = "[[:Fichier:Cat.jpg|[[B]]]]", .visible = "[[:Fichier:Cat.jpg|B]]", .linked = "B", .target = "B" },
        .{ .source = "[[broken [[cat|inside]] tail", .visible = "[[broken inside tail", .linked = "inside", .target = "cat" },
    };
    for (cases) |case| {
        var renderer: Renderer = .{ .a = a, .context = .{ .namespace_catalog = &registry } };
        const spans = try renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        var links: usize = 0;
        for (spans) |span| {
            if (span.kind == .link) {
                links += 1;
                try std.testing.expectEqualStrings(case.linked, span.text);
                try std.testing.expectEqualStrings(case.target, span.target);
            } else {
                try std.testing.expectEqualStrings("", span.target);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), links);
    }
    const formatted = [_]struct { source: []const u8, prefix_bold: bool = false, prefix_italic: bool = false, link_bold: bool = false, link_italic: bool = false }{
        .{ .source = "[[A|''before'' [[B]] after]]", .prefix_italic = true },
        .{ .source = "[[A|<b>before</b> [[B]] after]]", .prefix_bold = true },
        .{ .source = "[[A|''before [[B]] after'']]", .prefix_italic = true, .link_italic = true },
        .{ .source = "[[A|<b>before [[B]] after</b>]]", .prefix_bold = true, .link_bold = true },
    };
    for (formatted) |case| {
        var renderer: Renderer = .{ .a = a, .context = .{} };
        const spans = try renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings("[[A|before B after]]", try flattened(a, spans));
        var saw_prefix = false;
        var links: usize = 0;
        for (spans) |span| {
            if (std.mem.indexOf(u8, span.text, "before") != null) {
                saw_prefix = true;
                try std.testing.expectEqual(case.prefix_bold, span.flags.bold);
                try std.testing.expectEqual(case.prefix_italic, span.flags.italic);
            }
            if (span.kind == .link) {
                links += 1;
                try std.testing.expectEqualStrings("B", span.text);
                try std.testing.expectEqualStrings("B", span.target);
                try std.testing.expectEqual(case.link_bold, span.flags.bold);
                try std.testing.expectEqual(case.link_italic, span.flags.italic);
            }
        }
        try std.testing.expect(saw_prefix);
        try std.testing.expectEqual(@as(usize, 1), links);
    }
}

test "nested label fixture protected literal content stays literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var literal: Renderer = .{ .a = a, .context = .{} };
    const literal_spans = try literal.parseSpans("<nowiki>[[A|[[B]]]]</nowiki>", .{});
    try std.testing.expectEqualStrings("[[A|[[B]]]]", try flattened(a, literal_spans));
    for (literal_spans) |span| try std.testing.expect(span.kind != .link);
    var label: Renderer = .{ .a = a, .context = .{} };
    const label_spans = try label.parseSpans("[[A|<nowiki>[[B]]</nowiki>]]", .{});
    try std.testing.expectEqualStrings("[[B]]", try flattened(a, label_spans));
    for (label_spans) |span| {
        try std.testing.expect(span.kind == .link);
        try std.testing.expectEqualStrings("A", span.target);
    }
    var attribute: Renderer = .{ .a = a, .context = .{} };
    const attribute_spans = try attribute.parseSpans("[[A|<span title=\"[[B]]\">label</span>]]", .{});
    try std.testing.expectEqualStrings("label", try flattened(a, attribute_spans));
    for (attribute_spans) |span| try std.testing.expectEqualStrings("A", span.target);
}

test "nested label fixture valid File caption keeps its nested link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try @import("namespace_registry").Registry.init(a, @import("namespace_registry").french_test_fixture);
    defer registry.deinit();
    for ([_][]const u8{
        "[[File:Cat.jpg|thumb|A [[domestic cat]]]]",
        "[[Image:Cat.jpg|thumb|A [[domestic cat]]]]",
        "[[Fichier:Cat.jpg|thumb|A [[domestic cat]]]]",
    }) |source| {
        var renderer: Renderer = .{ .a = a, .context = .{ .namespace_catalog = &registry } };
        const spans = try renderer.parseSpans(source, .{});
        try std.testing.expectEqualStrings("A domestic cat", try flattened(a, spans));
        try std.testing.expectEqual(@as(usize, 1), renderer.media.items.len);
        try std.testing.expect(!renderer.fallbacks.literal_markup);
    }
}

test "behavior target fixture active switches normalize link navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8, target: ?[]const u8, italic_label: bool = false }{
        .{ .source = "[[A__NOTOC__]]", .visible = "A", .target = "A" },
        .{ .source = "[[A&#91;__NOTOC__|label]]", .visible = "[[A[|label]]", .target = null },
        .{ .source = "[[A__NOEDITSECTION__B|label]]", .visible = "label", .target = "AB" },
        .{ .source = "[[__NOTOC__]]", .visible = "[[]]", .target = null },
        .{ .source = "[[__NOTOC__|label]]", .visible = "[[|label]]", .target = null },
        .{ .source = "[[:__NOTOC__]]", .visible = "[[:]]", .target = null },
        .{ .source = "[[Category:__NOTOC__]]", .visible = "[[Category:]]", .target = null },
        .{ .source = "[[File:__NOTOC__|caption]]", .visible = "[[File:|caption]]", .target = null },
        .{ .source = "[[File:__NOTOC__|''caption'']]", .visible = "[[File:|caption]]", .target = null, .italic_label = true },
        .{ .source = "[[:Category:A__NOTOC__|label]]", .visible = "label", .target = "Category:A" },
        .{ .source = "[[A__NOTOC__|[[B]]]]", .visible = "[[A|B]]", .target = "B" },
        .{ .source = "[[broken__NOTOC__ [[cat|inside]] tail", .visible = "[[broken inside tail", .target = "cat" },
    };
    for (cases) |case| {
        var renderer: Renderer = .{ .a = a, .context = .{} };
        const spans = try renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        var links: usize = 0;
        for (spans) |span| if (span.kind == .link) {
            links += 1;
            try std.testing.expectEqualStrings(case.target orelse return error.UnexpectedNavigation, span.target);
        };
        try std.testing.expectEqual(@as(usize, if (case.target != null) 1 else 0), links);
        if (case.target == null) try std.testing.expectEqual(@as(usize, 0), renderer.media.items.len);
        if (case.italic_label) {
            var italic_caption = false;
            for (spans) |span| if (std.mem.indexOf(u8, span.text, "caption") != null) {
                italic_caption = span.flags.italic;
            };
            try std.testing.expect(italic_caption);
        }
    }
    var media: Renderer = .{ .a = a, .context = .{} };
    const caption = try media.parseSpans("[[File:A__NOTOC__.jpg|thumb|caption]]", .{});
    try std.testing.expectEqualStrings("caption", try flattened(a, caption));
    try std.testing.expectEqual(@as(usize, 1), media.media.items.len);
    try std.testing.expectEqualStrings("A.jpg", media.media.items[0].file);
}

test "behavior target fixture protected encoded and unknown controls remain literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const literals = [_][]const u8{
        "<nowiki>[[A__NOTOC__]]</nowiki>",
        "<pre>[[A__NOTOC__]]</pre>",
        "<code><nowiki>[[A__NOTOC__]]</nowiki></code>",
    };
    for (literals) |source| {
        var renderer: Renderer = .{ .a = a, .context = .{} };
        const spans = try renderer.parseSpans(source, .{});
        try std.testing.expectEqualStrings("[[A__NOTOC__]]", try flattened(a, spans));
        for (spans) |span| try std.testing.expect(span.kind != .link);
    }
    var encoded: Renderer = .{ .a = a, .context = .{} };
    const encoded_spans = try encoded.parseSpans("[[A&#95;&#95;NOTOC&#95;&#95;Z|encoded]]", .{});
    try std.testing.expectEqualStrings("encoded", try flattened(a, encoded_spans));
    for (encoded_spans) |span| {
        try std.testing.expect(span.kind == .link);
        // Entity-authored underscores use existing title normalization;
        // they must not remove the NOTOC word as an active source control.
        try std.testing.expectEqualStrings("A  NOTOC  Z", span.target);
    }
    var label: Renderer = .{ .a = a, .context = .{} };
    const label_spans = try label.parseSpans("[[A|<nowiki>__NOTOC__</nowiki>]]", .{});
    try std.testing.expectEqualStrings("__NOTOC__", try flattened(a, label_spans));
    for (label_spans) |span| try std.testing.expectEqualStrings("A", span.target);
    var attribute: Renderer = .{ .a = a, .context = .{} };
    const attribute_spans = try attribute.parseSpans("[[A|<span title='__NOTOC__'>label</span>]]", .{});
    try std.testing.expectEqualStrings("label", try flattened(a, attribute_spans));
    for (attribute_spans) |span| try std.testing.expectEqualStrings("A", span.target);
    var unknown: Renderer = .{ .a = a, .context = .{} };
    try std.testing.expectEqualStrings("__UNKNOWN__ __NOTOC__", try flattened(a, try unknown.parseSpans("__UNKNOWN__ &#95;&#95;NOTOC&#95;&#95;", .{})));
}

test "behavior target fixture localized aliases use captured matching policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const registry_type = @import("namespace_registry").behavior_switches;
    const raw = registry_type.header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\nnoeditsection\t0\t__لاتحريرقسم__\nindex\t1\t__INDEX__\n";
    var registry = try registry_type.Registry.init(a, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer registry.deinit();
    const cases = [_]struct { source: []const u8, target: []const u8 }{
        .{ .source = "[[A＿＿目次非表示＿＿B|label]]", .target = "AB" },
        .{ .source = "[[A__لاتحريرقسم__B|label]]", .target = "AB" },
        .{ .source = "[[A__INDEX__B|label]]", .target = "AB" },
        .{ .source = "[[A__index__B|label]]", .target = "A  index  B" },
        .{ .source = "[[A__NOTOC__B|label]]", .target = "A  NOTOC  B" },
    };
    for (cases) |case| {
        var renderer: Renderer = .{ .a = a, .context = .{ .behavior_switches = &registry } };
        const spans = try renderer.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings("label", try flattened(a, spans));
        try std.testing.expect(spans.len != 0);
        for (spans) |span| try std.testing.expectEqualStrings(case.target, span.target);
    }
}

test "block HTML suffix fixture preserves literal same-line list marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<div>lead</div># following lexical text\n# real definition");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("lead", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.paragraph, blocks[1].kind);
    try std.testing.expectEqualStrings("# following lexical text", trim(try flattened(a, blocks[1].spans)));
    try std.testing.expectEqual(Kind.definition, blocks[2].kind);
    try std.testing.expectEqualStrings("real definition", try flattened(a, blocks[2].spans));
}

test "block HTML suffix fixture retains real next-line block ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<div>lead</div>\n# real definition\n== Real heading ==\n{|\n| real cell\n|}");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
    try std.testing.expectEqualStrings("real definition", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.heading, blocks[2].kind);
    try std.testing.expectEqualStrings("Real heading", try flattened(a, blocks[2].spans));
    try std.testing.expectEqual(Kind.table, blocks[3].kind);
    try std.testing.expectEqualStrings("real cell", try flattened(a, blocks[3].table.?.rows[0].cells[0].spans));
}

fn unclosedExternalRecoveryHasLink(spans: []const Span, kind: @TypeOf(@as(Span, undefined).kind), target: []const u8) bool {
    for (spans) |span| {
        if (span.kind == kind and std.mem.eql(u8, span.target, target)) return true;
    }
    return false;
}

test "unclosed external recovery fixture preserves following links emphasis and lexical text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("Before [https://example.test unfinished ''kept'' [[B]] tail", .{});
    try std.testing.expectEqualStrings("Before [https://example.test unfinished kept B tail", try plainText(a, spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .external_link, "https://example.test"));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .link, "B"));
    var kept = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "kept") and span.flags.italic) kept = true;
    }
    try std.testing.expect(kept);
}

test "unclosed external recovery fixture retains closed link label and following navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("Closed: [https://example.test label] after [[C]]", .{});
    try std.testing.expectEqualStrings("Closed: label after C", try plainText(a, spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .external_link, "https://example.test"));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .link, "C"));
}

test "unclosed external recovery fixture preserves protected opener literally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("Protected: <nowiki>[https://example.test unfinished [[B]]</nowiki> after [[D]]", .{});
    try std.testing.expectEqualStrings("Protected: [https://example.test unfinished [[B]] after D", try plainText(a, spans));
    try std.testing.expect(!unclosedExternalRecoveryHasLink(spans, .external_link, "https://example.test"));
    try std.testing.expect(!unclosedExternalRecoveryHasLink(spans, .link, "B"));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .link, "D"));
}

test "numeric entity spelling fixture rejects signs and separators in ordinary text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "&#+65; &#x+41; &#6_5; &#x4_1; &#-65; &#x-41; &# 65; &#x 41; &#; &#x;";
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans(source, .{});
    try std.testing.expectEqualStrings(source, try flattened(a, spans));
}

test "numeric entity spelling fixture retains valid references and once-only decoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("&#65; &#x41; &#X41; &#00065; &amp;#65; &#38;#65; &#91;&#91;B&#93;&#93;", .{});
    try std.testing.expectEqualStrings("A A A A &#65; &#65; [[B]]", try flattened(a, spans));
    for (spans) |span| try std.testing.expect(span.kind != .link);
}

test "numeric entity spelling fixture preserves protected literal content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const spans = try renderer.parseSpans("<nowiki>&#+65; &#x+41; &#6_5; &#x4_1; &#65; &#x41; &amp;#65; [[B]]</nowiki>", .{});
    try std.testing.expectEqualStrings("&#+65; &#x+41; &#6_5; &#x4_1; A A &#65; [[B]]", try flattened(a, spans));
    for (spans) |span| try std.testing.expect(span.kind != .link);
}

test "block opener boundary fixture keeps same-line wiki list punctuation literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<div># same-line lexical text</div>\n<div>\n# physical-line definition\n</div>");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("# same-line lexical text", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
    try std.testing.expectEqualStrings("physical-line definition", try flattened(a, blocks[1].spans));
}

test "block opener boundary fixture retains definition-list punctuation and protected controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<blockquote>; term : lexical detail</blockquote>\n<blockquote>\n; real term : real detail\n</blockquote>\n<div><nowiki># protected literal</nowiki></div>");
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("; term : lexical detail", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.term, blocks[1].kind);
    try std.testing.expectEqualStrings("real term", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.list_detail, blocks[2].kind);
    try std.testing.expectEqualStrings("real detail", try flattened(a, blocks[2].spans));
    try std.testing.expectEqual(Kind.paragraph, blocks[3].kind);
    try std.testing.expectEqualStrings("# protected literal", try flattened(a, blocks[3].spans));
}

test "block opener boundary fixture retains later physical headings tables and closing tails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<div># literal opener\n== True heading ==\n{|\n| real cell\n|}\n# true definition\n</div># same-line tail\n# outside definition");
    try std.testing.expectEqual(@as(usize, 6), blocks.len);
    try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("# literal opener", try flattened(a, blocks[0].spans));
    try std.testing.expectEqual(Kind.heading, blocks[1].kind);
    try std.testing.expectEqualStrings("True heading", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.table, blocks[2].kind);
    try std.testing.expectEqualStrings("real cell", try flattened(a, blocks[2].table.?.rows[0].cells[0].spans));
    try std.testing.expectEqual(Kind.definition, blocks[3].kind);
    try std.testing.expectEqualStrings("true definition", try flattened(a, blocks[3].spans));
    try std.testing.expectEqual(Kind.paragraph, blocks[4].kind);
    try std.testing.expectEqualStrings("# same-line tail", try flattened(a, blocks[4].spans));
    try std.testing.expectEqual(Kind.definition, blocks[5].kind);
    try std.testing.expectEqualStrings("outside definition", try flattened(a, blocks[5].spans));
}

test "unclosed template recovery fixture keeps following link and emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("Before {{broken [[B]] ''kept'' tail", .{});
    try std.testing.expectEqualStrings("Before {{broken B kept tail", try flattened(a, spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .link, "B"));
    var kept = false;
    for (spans) |span| if (span.flags.italic and std.mem.eql(u8, span.text, "kept")) {
        kept = true;
    };
    try std.testing.expect(kept);
    var nested: Renderer = .{ .a = a, .context = .{} };
    const nested_spans = try nested.parseSpans("Before {{broken {{!}} [[B]] tail", .{});
    try std.testing.expectEqualStrings("Before {{broken | B tail", try flattened(a, nested_spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(nested_spans, .link, "B"));
    var emphasized: Renderer = .{ .a = a, .context = .{} };
    const emphasized_spans = try emphasized.parseSpans("Before ''{{broken [[B]] kept'' tail", .{});
    try std.testing.expectEqualStrings("Before {{broken B kept tail", try flattened(a, emphasized_spans));
    var italic_link = false;
    var italic_text = false;
    var plain_tail = false;
    for (emphasized_spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "B") and span.flags.italic) italic_link = true;
        if (span.flags.italic and std.mem.indexOf(u8, span.text, "kept") != null) italic_text = true;
        if (!span.flags.italic and std.mem.indexOf(u8, span.text, "tail") != null) plain_tail = true;
    }
    try std.testing.expect(italic_link and italic_text and plain_tail);
}

test "unclosed template recovery fixture keeps parameter opener and following HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("Before {{{broken [[B]] <i>kept</i> tail", .{});
    try std.testing.expectEqualStrings("Before {{{broken B kept tail", try flattened(a, spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(spans, .link, "B"));
    var kept = false;
    for (spans) |span| if (span.flags.italic and std.mem.eql(u8, span.text, "kept")) {
        kept = true;
    };
    try std.testing.expect(kept);
}

test "unclosed template recovery fixture preserves protected and encoded braces and valid parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const spans = try r.parseSpans("<nowiki>{{broken [[B]] ''kept''</nowiki> &#123;&#123;encoded {{{p|default}}} tail", .{});
    try std.testing.expectEqualStrings("{{broken [[B]] ''kept'' {{encoded default tail", try flattened(a, spans));
    for (spans) |span| try std.testing.expect(span.kind != .link);
}

test "nested external URL label fixture decodes once and preserves outer navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8, code: bool = false }{
        .{ .source = "[[A|https://example.test/?x=%26&amp;y=2]]", .visible = "https://example.test/?x=%26&y=2" },
        .{ .source = "[[A|https://example.test/?x=%26&amp;amp;y=2]]", .visible = "https://example.test/?x=%26&amp;y=2" },
        .{ .source = "[[A|<code>https://example.test/?x=%26&amp;y=2</code>]]", .visible = "https://example.test/?x=%26&y=2", .code = true },
    };
    for (cases) |case| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const spans = try r.parseSpans(case.source, .{});
        try std.testing.expectEqualStrings(case.visible, try flattened(a, spans));
        try std.testing.expect(spans.len != 0);
        for (spans) |span| {
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings("A", span.target);
            try std.testing.expectEqual(case.code, span.flags.code);
        }
    }
}

test "nested external URL label fixture retains protected literals and ordinary external URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "nowiki", "pre" }) |tag| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const source = try std.fmt.allocPrint(a, "[[A|<{s}>https://example.test/?x=%26&amp;amp;y=2</{s}>]]", .{ tag, tag });
        const spans = try r.parseSpans(source, .{});
        try std.testing.expectEqualStrings("https://example.test/?x=%26&amp;y=2", try flattened(a, spans));
        for (spans) |span| {
            try std.testing.expectEqual(ir.InlineKind.link, span.kind);
            try std.testing.expectEqualStrings("A", span.target);
            try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
        }
    }
    var external: Renderer = .{ .a = a, .context = .{} };
    const external_spans = try external.parseSpans("[https://example.test/?x=%26&amp;y=2 ordinary]", .{});
    try std.testing.expectEqualStrings("ordinary", try flattened(a, external_spans));
    for (external_spans) |span| {
        try std.testing.expectEqual(ir.InlineKind.external_link, span.kind);
        try std.testing.expectEqualStrings("https://example.test/?x=%26&y=2", span.target);
    }
}

test "repeated table caption fixture retains wiki lexical labels and cell content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("{|\n|+ First [[A|lexical label]]\n|+ Second caption\n| cell\n|}");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const table = blocks[0].table.?;
    try std.testing.expectEqualStrings("First lexical label\nSecond caption", try flattened(a, table.caption));
    var linked = false;
    for (table.caption) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "A") and std.mem.eql(u8, span.text, "lexical label")) {
        linked = true;
    };
    try std.testing.expect(linked);
    try std.testing.expectEqualStrings("cell", try flattened(a, table.rows[0].cells[0].spans));
}

test "repeated table caption fixture retains HTML captions styles and navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("<table><caption><b>First</b> [[A|lexical label]]</caption><caption><i>Second caption</i></caption><tr><td>cell</td></tr></table>");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const table = blocks[0].table.?;
    try std.testing.expectEqualStrings("First lexical label\nSecond caption", try flattened(a, table.caption));
    var first_bold = false;
    var second_italic = false;
    var linked = false;
    for (table.caption) |span| {
        if (std.mem.eql(u8, span.text, "First") and span.flags.bold) first_bold = true;
        if (std.mem.eql(u8, span.text, "Second caption") and span.flags.italic) second_italic = true;
        if (span.kind == .link and std.mem.eql(u8, span.target, "A")) linked = true;
    }
    try std.testing.expect(first_bold and second_italic and linked);
    try std.testing.expectEqualStrings("cell", try flattened(a, table.rows[0].cells[0].spans));
}

test "repeated table caption fixture empty captions retain protected and single caption text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{|\n|+ <nowiki>|+ literal &amp;</nowiki>\n|+\n| cell\n|}",
        "<table><caption><nowiki>|+ literal &amp;</nowiki></caption><caption></caption><tr><td>cell</td></tr></table>",
    }) |input| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(input);
        const table = blocks[0].table.?;
        try std.testing.expectEqualStrings("|+ literal &", try flattened(a, table.caption));
        for (table.caption) |span| try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
        try std.testing.expectEqualStrings("cell", try flattened(a, table.rows[0].cells[0].spans));
    }
    var single: Renderer = .{ .a = a, .context = .{} };
    const blocks = try single.renderBody("{|\n|+ Only caption\n| cell\n|}");
    try std.testing.expectEqualStrings("Only caption", try flattened(a, blocks[0].table.?.caption));
}

test "empty definition boundary fixture keeps lexical content in term and detail roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("; term :\n; : definition\n; plain term");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    const kinds = [_]Kind{ .term, .list_detail, .term };
    const texts = [_][]const u8{ "term", "definition", "plain term" };
    for (blocks, kinds, texts) |block_value, kind, text| {
        try std.testing.expectEqual(kind, block_value.kind);
        try std.testing.expectEqualStrings(text, try flattened(a, block_value.spans));
    }
}

test "empty definition boundary fixture retains parent paths protected and link colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Renderer = .{ .a = a, .context = .{} };
    const blocks = try r.renderBody("#; term :\n#; : definition\n; [[A|term: label]] : detail\n; <nowiki>literal : marker</nowiki>");
    try std.testing.expectEqual(@as(usize, 5), blocks.len);
    for (blocks[0..2], [_][]const u8{ "#;", "#:" }, [_]Kind{ .term, .list_detail }) |block_value, path, kind| {
        try std.testing.expectEqualStrings(path, block_value.list_path);
        try std.testing.expectEqual(kind, block_value.kind);
    }
    try std.testing.expectEqualStrings("term", try flattened(a, blocks[0].spans));
    try std.testing.expectEqualStrings("definition", try flattened(a, blocks[1].spans));
    try std.testing.expectEqual(Kind.term, blocks[2].kind);
    try std.testing.expectEqualStrings("term: label", try flattened(a, blocks[2].spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(blocks[2].spans, .link, "A"));
    try std.testing.expectEqual(Kind.list_detail, blocks[3].kind);
    try std.testing.expectEqualStrings("detail", try flattened(a, blocks[3].spans));
    try std.testing.expectEqual(Kind.term, blocks[4].kind);
    try std.testing.expectEqualStrings("literal : marker", try flattened(a, blocks[4].spans));
    for (blocks[4].spans) |span| try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
}

test "inline block opening fixture separates linked lexical text for div paragraph and heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "alpha<div>[[A|beta]]</div>gamma",
        "alpha<p>[[A|beta]]</p>gamma",
        "alpha<h3>[[A|beta]]</h3>gamma",
    }) |input| {
        var r: Renderer = .{ .a = a, .context = .{} };
        const blocks = try r.renderBody(input);
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqualStrings("alpha\nbeta\ngamma", try flattened(a, blocks[0].spans));
        try std.testing.expect(unclosedExternalRecoveryHasLink(blocks[0].spans, .link, "A"));
    }
}

test "inline block opening fixture preserves inline and protected literal controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inline_renderer: Renderer = .{ .a = a, .context = .{} };
    try std.testing.expectEqualStrings("alphabetagamma", try flattened(a, try inline_renderer.parseSpans("alpha<span>[[A|beta]]</span>gamma", .{})));
    var protected_renderer: Renderer = .{ .a = a, .context = .{} };
    const protected = try protected_renderer.parseSpans("alpha<nowiki><div>[[A|beta]]</div></nowiki>gamma", .{});
    try std.testing.expectEqualStrings("alpha<div>[[A|beta]]</div>gamma", try flattened(a, protected));
    try std.testing.expect(!unclosedExternalRecoveryHasLink(protected, .link, "A"));
    var retained = false;
    for (protected) |span| {
        if (std.mem.indexOf(u8, span.text, "<div>") != null) {
            try std.testing.expectEqual(Provenance.protected_literal, span.provenance);
            retained = true;
        }
    }
    try std.testing.expect(retained);
}

test "inline block opening fixture retains empty and adjacent block boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var empty: Renderer = .{ .a = a, .context = .{} };
    try std.testing.expectEqualStrings("alpha\ngamma", try flattened(a, try empty.parseSpans("alpha<div></div>gamma", .{})));
    var adjacent: Renderer = .{ .a = a, .context = .{} };
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\ntail", try flattened(a, try adjacent.parseSpans("alpha<div>beta</div><p>gamma</p>tail", .{})));
}

test "leading behavior switch preserves heading and numbered lexical roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody("__NOEDITSECTION__== English ==\n__NOEDITSECTION__# [[cat|lexical sense]]\n__NOTOC____NOEDITSECTION__# second");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(Kind.heading, blocks[0].kind);
    try std.testing.expectEqualStrings("English", try flattened(a, blocks[0].spans));
    for (blocks[1..], [_][]const u8{ "1", "2" }) |block_value, number| {
        try std.testing.expectEqual(Kind.definition, block_value.kind);
        try std.testing.expectEqualStrings("#", block_value.list_path);
        try std.testing.expectEqualStrings(number, block_value.number);
    }
    try std.testing.expectEqualStrings("lexical sense", try flattened(a, blocks[1].spans));
    try std.testing.expect(unclosedExternalRecoveryHasLink(blocks[1].spans, .link, "cat"));
}

test "leading behavior control preserves table protected and unknown literal boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "__NOEDITSECTION__{|\n| lexical cell\n|}", "<nowiki>__NOEDITSECTION__# literal</nowiki>", "__UNKNOWN__# literal", "&#95;&#95;NOEDITSECTION&#95;&#95;# literal" }) |source| {
        var renderer: Renderer = .{ .a = a, .context = .{} };
        const blocks = try renderer.renderBody(source);
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqual(Kind.paragraph, blocks[0].kind);
        try std.testing.expect(blocks[0].table == null and blocks[0].list_path.len == 0);
        const text = try flattened(a, blocks[0].spans);
        if (std.mem.indexOf(u8, source, "lexical cell") != null) {
            try std.testing.expect(std.mem.indexOf(u8, text, "{|") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "lexical cell") != null);
        } else try std.testing.expect(std.mem.indexOf(u8, text, "# literal") != null);
    }
}

test "leading localized behavior controls use captured profile for heading and list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const registry_type = @import("namespace_registry").behavior_switches;
    const raw = registry_type.header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\n";
    var registry = try registry_type.Registry.init(a, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer registry.deinit();
    var renderer: Renderer = .{ .a = a, .context = .{ .behavior_switches = &registry } };
    const blocks = try renderer.renderBody("＿＿目次非表示＿＿== English ==\n＿＿目次非表示＿＿# sense");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(Kind.heading, blocks[0].kind);
    try std.testing.expectEqual(Kind.definition, blocks[1].kind);
    try std.testing.expectEqualStrings("sense", try flattened(a, blocks[1].spans));
}
