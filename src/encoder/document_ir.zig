const std = @import("std");
const syntax = @import("wikitext_syntax.zig");
pub const SectionKind = enum(u8) {
    lines = 0,
    pos_lines = 1,
    term_list = 2,
    translations = 3,
};

pub const BlockKind = enum {
    paragraph,
    blank,
    definition,
    example,
    quotation,
    list_item,
    list_detail,
    indent,
    term,
};

pub const InlineKind = enum {
    text,
    template,
    link,
    external_link,
    line_break,
};

pub const TermRecordKind = enum {
    line,
    column,
};

pub const TermRecord = struct {
    kind: TermRecordKind,
    text: []const u8 = "",
    columns: ?u8 = null,
    block_layout: bool = false,
    first_line_item_count: usize = 0,
    items: []const []const u8 = &.{},

    pub fn block(self: TermRecord) ?DecodedBlock {
        if (self.kind != .line) return null;
        return classifyLine(self.text);
    }

    pub fn itemInlineIterator(self: TermRecord, index: usize) ?InlineIterator {
        if (self.kind != .column or index >= self.items.len) return null;
        return .{ .input = self.items[index] };
    }

    pub fn deinit(self: *TermRecord, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .line => allocator.free(self.text),
            .column => {
                for (self.items) |item| allocator.free(item);
                allocator.free(self.items);
            },
        }
        self.* = undefined;
    }
};

pub const TranslationRecordKind = enum {
    raw_line,
    group_start,
    group_mid,
    group_end,
    multitrans_start,
    multitrans_end,
    mapping,
};

pub const TranslationSeparator = enum {
    none,
    comma,
    semicolon,
};

pub const TranslationRecord = struct {
    kind: TranslationRecordKind,
    block_kind: BlockKind = .paragraph,
    depth: u8 = 0,
    source_prefix: []const u8 = "",
    text: ?[]const u8 = null,
    label: ?[]const u8 = null,
    label_owned: bool = false,
    language: ?[]const u8 = null,
    template_name: ?[]const u8 = null,
    terms: []const []const u8 = &.{},
    separator: TranslationSeparator = .none,
    check: bool = false,
    explicit_empty: bool = false,

    pub fn inlineIterator(self: TranslationRecord) ?InlineIterator {
        const text = self.text orelse return null;
        return .{ .input = text };
    }

    pub fn deinit(self: *TranslationRecord, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .raw_line, .group_start => if (self.text) |text| allocator.free(text),
            .mapping => {
                if (self.label_owned) if (self.label) |label| allocator.free(label);
                if (self.text) |text| allocator.free(text);
                if (self.terms.len != 0) {
                    for (self.terms) |term| allocator.free(term);
                    allocator.free(self.terms);
                }
            },
            .group_mid, .group_end, .multitrans_start, .multitrans_end => {},
        }
        self.* = undefined;
    }
};

pub const InlineSpan = struct {
    kind: InlineKind,
    text: []const u8,
    target: []const u8 = "",
    trail: []const u8 = "",
    link_has_pipe: bool = false,
    link_empty_label: bool = false,
    literal_tail: bool = false,
    bold: bool = false,
    italic: bool = false,
};

pub const DecodedBlock = struct {
    kind: BlockKind,
    depth: u8,
    text: []const u8,
    list_path: []const u8 = "",

    pub fn inlineIterator(self: DecodedBlock) InlineIterator {
        return .{ .input = self.text };
    }
};

fn englishLinkTrailContains(_: ?*const anyopaque, cp: u21) bool {
    return cp >= 'a' and cp <= 'z';
}

pub const LinkTrail = struct {
    ctx: ?*const anyopaque = null,
    contains_fn: *const fn (?*const anyopaque, u21) bool = englishLinkTrailContains,
    end_fn: ?*const fn (?*const anyopaque, []const u8, usize) usize = null,

    fn end(self: LinkTrail, input: []const u8, start: usize) usize {
        if (self.end_fn) |end_fn| return end_fn(self.ctx, input, start);
        var cursor = start;
        while (cursor < input.len) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(input[cursor]) catch break;
            if (cursor + sequence_len > input.len) break;
            const cp = std.unicode.utf8Decode(input[cursor .. cursor + sequence_len]) catch break;
            if (!self.contains_fn(self.ctx, cp)) break;
            cursor += sequence_len;
        }
        return cursor;
    }
};

pub const InlineIterator = struct {
    input: []const u8,
    cursor: usize = 0,
    bold: bool = false,
    italic: bool = false,
    renderer_boundaries: bool = false,
    link_trail: LinkTrail = .{},
    pending_link_start: usize = 0,
    pending_link_inner_end: usize = 0,
    pending_link_end: usize = 0,
    next_free_external: usize = 0,
    free_external_scanned: bool = false,

    fn nextFreeExternal(self: *InlineIterator) usize {
        if (!self.free_external_scanned or self.next_free_external < self.cursor) {
            self.next_free_external = freeExternalStart(self.input, self.cursor) orelse self.input.len;
            self.free_external_scanned = true;
        }
        return self.next_free_external;
    }

    fn clearPendingLink(self: *InlineIterator) void {
        self.pending_link_end = 0;
    }

    fn inlineLink(self: *InlineIterator, link: ParsedInlineLink) InlineSpan {
        self.cursor = link.end;
        return .{
            .kind = .link,
            .text = link.label,
            .target = link.target,
            .trail = link.trail,
            .link_has_pipe = link.has_pipe,
            .link_empty_label = link.empty_label,
            .bold = self.bold,
            .italic = self.italic,
        };
    }

    pub fn next(self: *InlineIterator) ?InlineSpan {
        while (self.cursor < self.input.len) {
            if (self.pending_link_end != 0) {
                if (self.cursor == self.pending_link_start) {
                    const pair: syntax.Pair = .{ .inner_end = self.pending_link_inner_end, .end = self.pending_link_end };
                    self.clearPendingLink();
                    switch (parseInlineLinkAtPair(self.input, self.cursor, pair, self.link_trail)) {
                        .link => |link| return self.inlineLink(link),
                        else => {},
                    }
                } else if (self.cursor > self.pending_link_start) self.clearPendingLink();
            }
            if (parseTemplateAt(self.input, self.cursor)) |template| {
                self.cursor = template.end;
                return .{
                    .kind = .template,
                    .text = template.body,
                    .target = template.name,
                    .bold = self.bold,
                    .italic = self.italic,
                };
            }
            switch (parseInlineLinkAtDetailed(self.input, self.cursor, self.link_trail)) {
                .link => |link| return self.inlineLink(link),
                .unbalanced => {
                    const start = self.cursor;
                    self.cursor = self.input.len;
                    return .{
                        .kind = .text,
                        .text = self.input[start..],
                        .literal_tail = true,
                        .bold = self.bold,
                        .italic = self.italic,
                    };
                },
                .not_link, .invalid => {},
            }
            if (parseExternalLinkAt(self.input, self.cursor)) |link| {
                self.cursor = link.end;
                return .{
                    .kind = .external_link,
                    .text = link.label,
                    .target = link.target,
                    .bold = self.bold,
                    .italic = self.italic,
                };
            }
            if (parseFreeExternalLinkAt(self.input, self.cursor)) |link| {
                self.cursor = link.end;
                return .{
                    .kind = .external_link,
                    .text = link.label,
                    .target = link.target,
                    .bold = self.bold,
                    .italic = self.italic,
                };
            }
            if (parseLineBreakAt(self.input, self.cursor)) |end| {
                self.cursor = end;
                return .{
                    .kind = .line_break,
                    .text = "",
                    .bold = self.bold,
                    .italic = self.italic,
                };
            }
            if (emphasisMarkerAt(self.input, self.cursor, self.bold, self.italic)) |marker| {
                if (marker.bold) self.bold = !self.bold;
                if (marker.italic) self.italic = !self.italic;
                self.cursor += marker.len;
                // Emphasis can expose markup owned by the presentation compiler.
                // Yield after consuming the quotes so its HTML/entity/parameter
                // handlers see the new cursor and the updated style.
                if (self.renderer_boundaries and self.cursor < self.input.len) {
                    const rest = self.input[self.cursor..];
                    if (rest[0] == '<' or rest[0] == '&' or std.mem.startsWith(u8, rest, "{{{"))
                        return .{ .kind = .text, .text = "", .bold = self.bold, .italic = self.italic };
                }
                continue;
            }
            const quote_run = quoteRunLength(self.input, self.cursor);
            if (quote_run >= 2) {
                // Four quotes are one literal plus bold; 6+ are literal extras
                // plus the five-quote bold+italic marker. If a 2/3/5 marker
                // cannot be balanced, preserve the whole run literally.
                const literal = if (quote_run == 4) @as(usize, 1) else if (quote_run > 5) quote_run - 5 else quote_run;
                const start = self.cursor;
                self.cursor += literal;
                return .{ .kind = .text, .text = self.input[start..self.cursor], .bold = self.bold, .italic = self.italic };
            }
            const start = self.cursor;
            // Reuse the next URL candidate across delimiters and calls to next.
            // Renderer-owned entities and tags can yield thousands of short
            // spans before a URL; rescanning every remaining suffix is quadratic.
            scan: while (self.cursor < self.input.len) {
                const external = self.nextFreeExternal();
                const structural = if (std.mem.indexOfAny(u8, self.input[self.cursor..], "{[<&'")) |relative|
                    self.cursor + relative
                else
                    self.input.len;
                self.cursor = @min(structural, external);
                if (self.cursor == self.input.len) break;
                const rest = self.input[self.cursor..];
                if (external == self.cursor and
                    (self.cursor == start or potentialInlineBoundary(self.input, self.cursor)))
                {
                    break :scan;
                }
                if (self.renderer_boundaries and self.cursor != start and
                    (rest[0] == '<' or rest[0] == '&' or std.mem.startsWith(u8, rest, "{{{")))
                {
                    break :scan;
                }
                if (std.mem.startsWith(u8, rest, "{{{")) {
                    if (syntax.balanced(self.input, self.cursor)) |pair| {
                        // Parameters are deliberately plain text to this shared
                        // iterator; frontend expansion may interpret them later.
                        self.cursor = pair.end;
                        continue;
                    }
                    self.cursor = self.input.len;
                    break;
                }
                if (std.mem.startsWith(u8, rest, "{{")) {
                    if (parseTemplateAt(self.input, self.cursor) != null) break;
                    self.cursor = self.input.len;
                    break;
                }
                if (std.mem.startsWith(u8, rest, "[[")) {
                    if (self.pending_link_end != 0 and self.pending_link_start == self.cursor) break :scan;
                    const pair = syntax.balanced(self.input, self.cursor) orelse {
                        self.cursor = self.input.len;
                        break :scan;
                    };
                    switch (parseInlineLinkAtPair(self.input, self.cursor, pair, self.link_trail)) {
                        .link => {
                            self.pending_link_start = self.cursor;
                            self.pending_link_inner_end = pair.inner_end;
                            self.pending_link_end = pair.end;
                            break :scan;
                        },
                        .invalid => if (self.renderer_boundaries) {
                            if (self.cursor != start) break :scan;
                            self.cursor = pair.end;
                            continue :scan;
                        } else {
                            self.cursor = self.input.len;
                            break :scan;
                        },
                        else => {
                            self.cursor = self.input.len;
                            break :scan;
                        },
                    }
                }
                if (rest[0] == '[' and rest.len > 1 and rest[1] != '[' and
                    hasExternalProtocol(rest[1..]))
                {
                    if (parseExternalLinkAt(self.input, self.cursor) != null) break;
                    self.cursor = self.input.len;
                    break;
                }
                if (rest[0] == '<' and rest.len >= 3 and std.ascii.toLower(rest[1]) == 'b' and std.ascii.toLower(rest[2]) == 'r') {
                    if (parseLineBreakAt(self.input, self.cursor) != null) break;
                    if (std.mem.indexOfScalar(u8, rest, '>') == null) {
                        self.cursor = self.input.len;
                        break;
                    }
                }
                const run = quoteRunLength(self.input, self.cursor);
                if (run >= 2) {
                    if (emphasisMarkerAt(self.input, self.cursor, self.bold, self.italic) != null) break;
                    if (run == 4 and emphasisMarkerAt(self.input, self.cursor + 1, self.bold, self.italic) != null) break;
                    if (run > 5 and emphasisMarkerAt(self.input, self.cursor + run - 5, self.bold, self.italic) != null) break;
                    self.cursor += run;
                    continue;
                }
                self.cursor += 1;
            }
            if (self.cursor != start) {
                return .{
                    .kind = .text,
                    .text = self.input[start..self.cursor],
                    .bold = self.bold,
                    .italic = self.italic,
                };
            }
        }
        return null;
    }
};

pub const BlockIterator = struct {
    body: []const u8,
    line_count: usize,
    line_index: usize = 0,
    line_start: usize = 0,

    pub fn next(self: *BlockIterator) ?DecodedBlock {
        if (self.line_index >= self.line_count) return null;
        self.line_index += 1;

        if (self.body.len == 0) return .{ .kind = .blank, .depth = 0, .text = "" };
        const line_end = std.mem.indexOfScalarPos(u8, self.body, self.line_start, '\n') orelse self.body.len;
        const block = classifyLine(self.body[self.line_start..line_end]);
        self.line_start = if (line_end == self.body.len) self.body.len else line_end + 1;
        return block;
    }
};

pub const DecodedSection = struct {
    level: u8,
    title: []const u8,
    title_owned: bool = false,
    kind: SectionKind,
    body: []const u8,
    line_count: usize,
    term_records: ?[]TermRecord = null,
    translation_records: ?[]TranslationRecord = null,

    pub fn blockIterator(self: *const DecodedSection) BlockIterator {
        return .{ .body = self.body, .line_count = self.line_count };
    }

    pub fn blocksAlloc(self: *const DecodedSection, allocator: std.mem.Allocator) ![]DecodedBlock {
        const blocks = try allocator.alloc(DecodedBlock, self.line_count);
        var iterator = self.blockIterator();
        var index: usize = 0;
        while (iterator.next()) |block| : (index += 1) blocks[index] = block;
        std.debug.assert(index == blocks.len);
        return blocks;
    }

    pub fn deinit(self: *DecodedSection, allocator: std.mem.Allocator) void {
        if (self.title_owned) allocator.free(self.title);
        allocator.free(self.body);
        if (self.term_records) |records| {
            for (records) |*record| record.deinit(allocator);
            allocator.free(records);
        }
        if (self.translation_records) |records| {
            for (records) |*record| record.deinit(allocator);
            allocator.free(records);
        }
        self.* = undefined;
    }
};

pub const DecodedDocument = struct {
    trailing_newline: bool,
    sections: []DecodedSection,

    pub fn deinit(self: *DecodedDocument, allocator: std.mem.Allocator) void {
        for (self.sections) |*section| section.deinit(allocator);
        allocator.free(self.sections);
        self.* = undefined;
    }
};

pub fn classifyLine(line: []const u8) DecodedBlock {
    if (line.len == 0) return .{ .kind = .blank, .depth = 0, .text = line };
    var prefix: usize = 0;
    while (prefix < line.len and std.mem.indexOfScalar(u8, "#*:;", line[prefix]) != null) : (prefix += 1) {}
    if (prefix == 0) return .{ .kind = .paragraph, .depth = 0, .text = line };

    const path = line[0..prefix];
    const last = path[path.len - 1];
    const kind: BlockKind = if (path[0] == '#' and std.mem.indexOfScalar(u8, path, '*') != null)
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
    return .{
        .kind = kind,
        .depth = @intCast(@min(prefix, std.math.maxInt(u8))),
        .text = std.mem.trimStart(u8, line[prefix..], " \t"),
        .list_path = path[0..@min(prefix, std.math.maxInt(u8))],
    };
}

const ParsedTemplate = struct {
    end: usize,
    name: []const u8,
    body: []const u8,
};

const ParsedInlineLink = struct {
    end: usize,
    target: []const u8,
    label: []const u8,
    trail: []const u8,
    has_pipe: bool,
    empty_label: bool,
};

const InlineLinkParse = union(enum) {
    not_link,
    unbalanced,
    invalid,
    link: ParsedInlineLink,
};

const ParsedExternalLink = struct {
    end: usize,
    target: []const u8,
    label: []const u8,
};

const EmphasisMarker = struct {
    len: usize,
    bold: bool,
    italic: bool,
};

const external_protocols = [_][]const u8{
    "bitcoin:", "ftp://",  "ftps://",  "geo:",      "git://",  "gopher://",    "http://",
    "https://", "irc://",  "ircs://",  "magnet:",   "mailto:", "matrix:",      "mms://",
    "news:",    "nntp://", "redis://", "sftp://",   "sip:",    "sips:",        "sms:",
    "ssh://",   "svn://",  "tel:",     "telnet://", "urn:",    "wikipedia://", "worldwind://",
    "xmpp:",    "//",
};

pub fn hasExternalProtocol(input: []const u8) bool {
    for (external_protocols) |protocol|
        if (startsWithAsciiIgnoreCase(input, protocol)) return true;
    return false;
}

fn hasAbsoluteExternalProtocol(input: []const u8) bool {
    for (external_protocols) |protocol| {
        if (std.mem.eql(u8, protocol, "//")) continue;
        if (startsWithAsciiIgnoreCase(input, protocol)) return true;
    }
    return false;
}

fn externalProtocolLen(input: []const u8, allow_relative: bool) ?usize {
    for (external_protocols) |protocol| {
        if (!allow_relative and std.mem.eql(u8, protocol, "//")) continue;
        if (startsWithAsciiIgnoreCase(input, protocol)) return protocol.len;
    }
    return null;
}

fn externalUrlByte(byte: u8) bool {
    return byte > 0x20 and byte != 0x7f and
        byte != '[' and byte != ']' and byte != '<' and byte != '>' and byte != '"';
}

fn unicodeSpaceSeparator(cp: u21) bool {
    return cp == 0x00a0 or cp == 0x1680 or
        (cp >= 0x2000 and cp <= 0x200a) or
        cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn unicodeNonWordBoundary(cp: u21) bool {
    return unicodeSpaceSeparator(cp) or
        (cp >= 0x00a1 and cp <= 0x00bf) or
        (cp >= 0x2000 and cp <= 0x206f) or
        (cp >= 0x20a0 and cp <= 0x20cf) or
        (cp >= 0x2190 and cp <= 0x23ff) or
        (cp >= 0x2500 and cp <= 0x27bf) or
        (cp >= 0x2b00 and cp <= 0x2bff) or
        (cp >= 0x2e00 and cp <= 0x2e7f) or
        (cp >= 0x3000 and cp <= 0x303f) or
        (cp >= 0xfe10 and cp <= 0xfe1f) or
        (cp >= 0xfe30 and cp <= 0xfe4f) or
        (cp >= 0xff01 and cp <= 0xff0f) or
        (cp >= 0xff1a and cp <= 0xff20) or
        (cp >= 0xff3b and cp <= 0xff40) or
        (cp >= 0xff5b and cp <= 0xff65) or
        (cp >= 0x1f000 and cp <= 0x1faff);
}

fn codepointBefore(input: []const u8, index: usize) ?u21 {
    if (index == 0 or index > input.len) return null;
    var start = index - 1;
    while (start != 0 and input[start] & 0xc0 == 0x80) : (start -= 1) {}
    return std.unicode.utf8Decode(input[start..index]) catch null;
}

fn codepointAt(input: []const u8, index: usize) ?u21 {
    if (index >= input.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(input[index]) catch return null;
    if (index + len > input.len) return null;
    return std.unicode.utf8Decode(input[index .. index + len]) catch null;
}

pub fn linkBoundaryBefore(input: []const u8, index: usize) bool {
    if (index == 0) return true;
    const prev = input[index - 1];
    if (prev < 0x80) return !std.ascii.isAlphanumeric(prev) and prev != '_';
    return if (codepointBefore(input, index)) |cp| unicodeNonWordBoundary(cp) else false;
}

pub fn linkBoundaryAfter(input: []const u8, index: usize) bool {
    if (index >= input.len) return true;
    const next = input[index];
    if (next < 0x80) return !std.ascii.isAlphanumeric(next) and next != '_';
    return if (codepointAt(input, index)) |cp| unicodeNonWordBoundary(cp) else false;
}

fn entityEndsAt(input: []const u8, end: usize) bool {
    if (end == 0 or input[end - 1] != ';') return false;
    const amp = std.mem.lastIndexOfScalar(u8, input[0 .. end - 1], '&') orelse return false;
    const body = input[amp + 1 .. end - 1];
    if (body.len == 0) return false;
    if (body[0] == '#') {
        const digits = body[1..];
        if (digits.len == 0) return false;
        if (digits[0] == 'x' or digits[0] == 'X') {
            if (digits.len == 1) return false;
            for (digits[1..]) |ch| if (!std.ascii.isHex(ch)) return false;
            return true;
        }
        for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }
    for (body) |ch| if (!std.ascii.isAlphabetic(ch)) return false;
    return true;
}

fn externalUrlEnd(input: []const u8, start: usize, allow_relative: bool, trim_trailing: bool) ?usize {
    const protocol_len = externalProtocolLen(input[start..], allow_relative) orelse return null;
    var end = start + protocol_len;
    const address_start = end;
    while (end < input.len) {
        if (!externalUrlByte(input[end])) break;
        if (input[end] < 0x80) {
            end += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[end]) catch break;
        if (end + sequence_len > input.len) break;
        const cp = std.unicode.utf8Decode(input[end .. end + sequence_len]) catch break;
        if (cp == 0xfffd or unicodeSpaceSeparator(cp)) break;
        end += sequence_len;
    }
    if (end == address_start) return null;
    if (!trim_trailing) return end;

    const has_left_paren = std.mem.indexOfScalar(u8, input[start..end], '(') != null;
    while (end > address_start) {
        const ch = input[end - 1];
        const punctuation = std.mem.indexOfScalar(u8, ",;\\.:!?", ch) != null or
            (ch == ')' and !has_left_paren);
        if (!punctuation) break;
        if (ch == ';' and entityEndsAt(input[start..end], end - start)) break;
        end -= 1;
    }
    if (end == address_start) return null;
    return end;
}

pub fn validExternalUrl(input: []const u8) bool {
    return (externalUrlEnd(input, 0, true, false) orelse return false) == input.len;
}

fn freeExternalStart(input: []const u8, start: usize) ?usize {
    var pos = start;
    const initials = "bBfFgGhHiImMnNrRsStTuUwWxX";
    while (pos < input.len) {
        const relative = std.mem.indexOfAny(u8, input[pos..], initials) orelse return null;
        pos += relative;
        if (!linkBoundaryBefore(input, pos)) {
            pos += 1;
            continue;
        }
        if (!hasAbsoluteExternalProtocol(input[pos..])) {
            pos += 1;
            continue;
        }
        if (externalUrlEnd(input, pos, false, true) != null) return pos;
        pos += 1;
    }
    return null;
}

fn potentialInlineBoundary(input: []const u8, start: usize) bool {
    if (start >= input.len) return false;
    const rest = input[start..];
    if (std.mem.startsWith(u8, rest, "{{") or std.mem.startsWith(u8, rest, "[[")) return true;
    if (input[start] == '[' and start + 1 < input.len and input[start + 1] != '[') {
        const body = input[start + 1 ..];
        if (hasExternalProtocol(body)) return true;
    }
    if (hasAbsoluteExternalProtocol(rest) and linkBoundaryBefore(input, start)) return true;
    if (input[start] == '<' and rest.len >= 3 and std.ascii.toLower(rest[1]) == 'b' and std.ascii.toLower(rest[2]) == 'r') return true;
    return quoteRunLength(input, start) >= 2;
}

fn parseTemplateAt(input: []const u8, start: usize) ?ParsedTemplate {
    if (start + 4 > input.len or !std.mem.eql(u8, input[start .. start + 2], "{{")) return null;
    if (start != 0 and input[start - 1] == '{') return null;
    if (start + 3 <= input.len and std.mem.eql(u8, input[start .. start + 3], "{{{")) return null;

    const pair = syntax.balanced(input, start) orelse return null;
    const body = input[start + 2 .. pair.inner_end];
    const pipe = syntax.delimiter(body, "|", 0) orelse body.len;
    const name = std.mem.trim(u8, body[0..pipe], " \t\r\n");
    if (name.len == 0) return null;
    return .{ .end = pair.end, .name = name, .body = body };
}

fn parseInlineLinkAtDetailed(input: []const u8, start: usize, link_trail: LinkTrail) InlineLinkParse {
    if (start + 2 > input.len or !std.mem.eql(u8, input[start .. start + 2], "[[")) return .not_link;
    const pair = syntax.balanced(input, start) orelse return .unbalanced;
    return parseInlineLinkAtPair(input, start, pair, link_trail);
}

fn parseInlineLinkAtPair(input: []const u8, start: usize, pair: syntax.Pair, link_trail: LinkTrail) InlineLinkParse {
    const inside = input[start + 2 .. pair.inner_end];
    if (inside.len == 0) return .invalid;
    const pipe = syntax.delimiter(inside, "|", 0);
    const raw_target = if (pipe) |index| inside[0..index] else inside;
    const target = std.mem.trim(u8, raw_target, " \t");
    if (target.len == 0) return .invalid;
    const raw_label = if (pipe) |index| inside[index + 1 ..] else target;
    const label = if (raw_label.len == 0) target else raw_label;
    const trail_end = link_trail.end(input, pair.end);
    return .{ .link = .{
        .end = trail_end,
        .target = target,
        .label = label,
        .trail = input[pair.end..trail_end],
        .has_pipe = pipe != null,
        .empty_label = pipe != null and raw_label.len == 0,
    } };
}

fn parseExternalLinkAt(input: []const u8, start: usize) ?ParsedExternalLink {
    if (start + 3 > input.len or input[start] != '[' or input[start + 1] == '[') return null;
    const body_start = start + 1;
    if (!hasExternalProtocol(input[body_start..])) return null;

    const close = findExternalLinkClose(input, start) orelse return null;
    const body = input[body_start..close];
    var separator: ?usize = null;
    for (body, 0..) |byte, index| {
        if (byte == ' ' or byte == '\t') {
            separator = index;
            break;
        }
    }
    const raw_target = if (separator) |index| body[0..index] else body;
    const target = std.mem.trim(u8, raw_target, " \t");
    if (target.len == 0 or !validExternalUrl(target)) return null;
    const raw_label = if (separator) |index| std.mem.trimStart(u8, body[index + 1 ..], " \t") else target;
    const label = if (raw_label.len == 0) target else raw_label;
    return .{ .end = close + 1, .target = target, .label = label };
}

fn parseFreeExternalLinkAt(input: []const u8, start: usize) ?ParsedExternalLink {
    if (!linkBoundaryBefore(input, start)) return null;
    const end = externalUrlEnd(input, start, false, true) orelse return null;
    const target = input[start..end];
    return .{ .end = end, .target = target, .label = target };
}

fn findExternalLinkClose(input: []const u8, start: usize) ?usize {
    var template_depth: usize = 0;
    var link_depth: usize = 0;
    var cursor = start + 1;
    while (cursor < input.len) : (cursor += 1) {
        if (input[cursor] == '<') if (syntax.protectedEnd(input, cursor)) |end| {
            cursor = end - 1;
            continue;
        };
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "{{")) {
            template_depth += 1;
            cursor += 1;
            continue;
        }
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "}}")) {
            if (template_depth != 0) template_depth -= 1;
            cursor += 1;
            continue;
        }
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "[[")) {
            link_depth += 1;
            cursor += 1;
            continue;
        }
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "]]")) {
            if (link_depth != 0) link_depth -= 1;
            cursor += 1;
            continue;
        }
        if (input[cursor] == ']' and template_depth == 0 and link_depth == 0) return cursor;
    }
    return null;
}

fn parseLineBreakAt(input: []const u8, start: usize) ?usize {
    if (start + 3 > input.len or input[start] != '<' or
        std.ascii.toLower(input[start + 1]) != 'b' or std.ascii.toLower(input[start + 2]) != 'r')
    {
        return null;
    }
    if (start + 3 < input.len) {
        const next = input[start + 3];
        if (next != '>' and next != '/' and next != ' ' and next != '\t') return null;
    }
    const close = std.mem.indexOfScalarPos(u8, input, start + 3, '>') orelse return null;
    return close + 1;
}

fn startsWithAsciiIgnoreCase(input: []const u8, prefix: []const u8) bool {
    if (input.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(input[0..prefix.len], prefix);
}

fn emphasisMarkerAt(input: []const u8, start: usize, bold: bool, italic: bool) ?EmphasisMarker {
    const run = quoteRunLength(input, start);
    const marker: EmphasisMarker = switch (run) {
        2 => .{ .len = 2, .bold = false, .italic = true },
        3 => .{ .len = 3, .bold = true, .italic = false },
        5 => .{ .len = 5, .bold = true, .italic = true },
        else => return null,
    };
    const closes_active = (!marker.bold or bold) and (!marker.italic or italic);
    if (!closes_active and !hasMatchingEmphasis(input, start + marker.len, marker.len)) return null;
    return marker;
}

fn quoteRunLength(input: []const u8, start: usize) usize {
    if (start >= input.len or input[start] != '\'') return 0;
    var end = start;
    while (end < input.len and input[end] == '\'') : (end += 1) {}
    return end - start;
}

fn hasMatchingEmphasis(input: []const u8, start: usize, marker_len: usize) bool {
    var cursor = start;
    while (cursor < input.len) {
        const run = quoteRunLength(input, cursor);
        if (run == marker_len) return true;
        cursor += if (run == 0) 1 else run;
    }
    return false;
}

test "external link closing ignores brackets inside protected extension bodies" {
    const block = DecodedBlock{
        .kind = .paragraph,
        .depth = 0,
        .text = "[https://example.test <nowiki>]</nowiki> docs] tail",
    };
    var iterator = block.inlineIterator();
    const link = iterator.next().?;
    try std.testing.expectEqual(InlineKind.external_link, link.kind);
    try std.testing.expectEqualStrings("https://example.test", link.target);
    try std.testing.expectEqualStrings("<nowiki>]</nowiki> docs", link.text);
    const tail = iterator.next().?;
    try std.testing.expectEqual(InlineKind.text, tail.kind);
    try std.testing.expectEqualStrings(" tail", tail.text);
    try std.testing.expect(iterator.next() == null);
}

test "external links cover MediaWiki protocols and free-link punctuation" {
    const cases = [_]struct { source: []const u8, target: []const u8, label: []const u8 }{
        .{ .source = "[ftp://example.test/file file]", .target = "ftp://example.test/file", .label = "file" },
        .{ .source = "[mailto:x@example.test mail]", .target = "mailto:x@example.test", .label = "mail" },
        .{ .source = "[//example.test/path protocol-relative]", .target = "//example.test/path", .label = "protocol-relative" },
        .{ .source = "https://example.test/a(b).", .target = "https://example.test/a(b)", .label = "https://example.test/a(b)" },
        .{ .source = "urn:isbn:9780000000000, next", .target = "urn:isbn:9780000000000", .label = "urn:isbn:9780000000000" },
    };
    for (cases) |case| {
        var it: InlineIterator = .{ .input = case.source };
        const link = it.next().?;
        try std.testing.expectEqual(InlineKind.external_link, link.kind);
        try std.testing.expectEqualStrings(case.target, link.target);
        try std.testing.expectEqualStrings(case.label, link.text);
    }

    var embedded: InlineIterator = .{ .input = "nothttp://example.test" };
    try std.testing.expectEqual(InlineKind.text, embedded.next().?.kind);
    var unsafe: InlineIterator = .{ .input = "[javascript:alert(1) nope]" };
    try std.testing.expectEqual(InlineKind.text, unsafe.next().?.kind);
    var lone_protocol: InlineIterator = .{ .input = "[http:// label]" };
    try std.testing.expectEqual(InlineKind.text, lone_protocol.next().?.kind);
    var unicode_space: InlineIterator = .{ .input = "https://example.test/a\xc2\xa0tail" };
    const unicode_link = unicode_space.next().?;
    try std.testing.expectEqualStrings("https://example.test/a", unicode_link.target);

    var unicode_word_prefix: InlineIterator = .{ .input = "éhttps://example.test/a" };
    try std.testing.expectEqualStrings("éhttps://example.test/a", unicode_word_prefix.next().?.text);
    var unicode_punctuation_prefix: InlineIterator = .{ .input = "—https://example.test/a" };
    try std.testing.expectEqualStrings("—", unicode_punctuation_prefix.next().?.text);
    try std.testing.expectEqualStrings("https://example.test/a", unicode_punctuation_prefix.next().?.target);
}

test "inline iterator scans markup-heavy text without losing trailing free links" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    for (0..8_000) |_| try input.appendSlice(a, "<x ");
    try input.appendSlice(a, "https://example.test/end");
    var it: InlineIterator = .{ .input = input.items };
    const text_span = it.next().?;
    try std.testing.expectEqual(InlineKind.text, text_span.kind);
    try std.testing.expectEqualStrings(input.items[0 .. input.items.len - "https://example.test/end".len], text_span.text);
    const link = it.next().?;
    try std.testing.expectEqual(InlineKind.external_link, link.kind);
    try std.testing.expectEqualStrings("https://example.test/end", link.target);
    try std.testing.expect(it.next() == null);
}

test "renderer boundaries reuse free-link search across many short spans" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    for (0..8_000) |_| try input.appendSlice(a, "text&");
    try input.appendSlice(a, "https://example.test/end");
    var it: InlineIterator = .{ .input = input.items, .renderer_boundaries = true };
    var total: usize = 0;
    var pieces: usize = 0;
    var saw_link = false;
    while (it.next()) |span| {
        total += span.text.len;
        pieces += 1;
        if (span.kind == .external_link) {
            try std.testing.expectEqualStrings("https://example.test/end", span.target);
            saw_link = true;
        }
    }
    try std.testing.expect(pieces > 4_000);
    try std.testing.expectEqual(input.items.len, total);
    try std.testing.expect(saw_link);
}

test "inline iterator makes bounded progress across malformed opener storms" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a, "prefix ");
    for (0..8_000) |_| try input.appendSlice(a, "[[broken ");
    try input.appendSlice(a, "EDGE_SENTINEL");
    var it: InlineIterator = .{ .input = input.items };
    var total: usize = 0;
    var saw_sentinel = false;
    while (it.next()) |span| {
        total += span.text.len;
        if (std.mem.indexOf(u8, span.text, "EDGE_SENTINEL") != null) saw_sentinel = true;
    }
    try std.testing.expect(saw_sentinel);
    try std.testing.expectEqual(input.items.len, total);
}

test "inline iterator reuses balanced link boundaries found after leading text" {
    var it: InlineIterator = .{ .input = "before [[cat|feline]] after" };
    const before = it.next().?;
    try std.testing.expectEqual(InlineKind.text, before.kind);
    try std.testing.expectEqualStrings("before ", before.text);
    try std.testing.expect(it.pending_link_end != 0);
    const link = it.next().?;
    try std.testing.expectEqual(InlineKind.link, link.kind);
    try std.testing.expectEqualStrings("cat", link.target);
    try std.testing.expectEqualStrings("feline", link.text);
    try std.testing.expectEqual(@as(usize, 0), it.pending_link_end);
    const after = it.next().?;
    try std.testing.expectEqualStrings(" after", after.text);
}

test "inline iterator drops cached link boundaries after caller skips past them" {
    const input = "before [[cat]] after";
    var it: InlineIterator = .{ .input = input };
    _ = it.next().?;
    try std.testing.expect(it.pending_link_end != 0);
    it.cursor = std.mem.indexOf(u8, input, "after").?;
    const after = it.next().?;
    try std.testing.expectEqualStrings("after", after.text);
    try std.testing.expectEqual(@as(usize, 0), it.pending_link_end);
}

test "renderer boundaries stop text before renderer-owned markup" {
    const cases = [_][]const u8{ "plain <b>bold</b>", "plain &amp; tail", "plain {{{p|default}}} tail" };
    for (cases) |input| {
        var it: InlineIterator = .{ .input = input, .renderer_boundaries = true };
        const text = it.next().?;
        try std.testing.expectEqual(InlineKind.text, text.kind);
        try std.testing.expectEqualStrings("plain ", text.text);
        try std.testing.expectEqual(@as(usize, "plain ".len), it.cursor);
    }
}

test "link trail stops before uppercase suffixes" {
    var it: InlineIterator = .{ .input = "[[Help]]ingBUT" };
    const link = it.next().?;
    try std.testing.expectEqual(InlineKind.link, link.kind);
    try std.testing.expectEqualStrings("ing", link.trail);
    const tail = it.next().?;
    try std.testing.expectEqualStrings("BUT", tail.text);
}

test "link trail policy handles edition-specific Unicode suffixes" {
    const trail: LinkTrail = .{
        .contains_fn = struct {
            fn contains(_: ?*const anyopaque, cp: u21) bool {
                return cp == 'ы';
            }
        }.contains,
    };
    var it: InlineIterator = .{ .input = "[[кот]]ыZ", .link_trail = trail };
    const link = it.next().?;
    try std.testing.expectEqual(InlineKind.link, link.kind);
    try std.testing.expectEqualStrings("кот", link.target);
    try std.testing.expectEqualStrings("ы", link.trail);
    const tail = it.next().?;
    try std.testing.expectEqualStrings("Z", tail.text);
}

test "block classifier accepts compact and mixed MediaWiki list markers" {
    const cases = [_]struct { source: []const u8, kind: BlockKind, path: []const u8, text: []const u8 }{
        .{ .source = "#definition", .kind = .definition, .path = "#", .text = "definition" },
        .{ .source = "##child", .kind = .definition, .path = "##", .text = "child" },
        .{ .source = "#:example", .kind = .example, .path = "#:", .text = "example" },
        .{ .source = "#*quote", .kind = .quotation, .path = "#*", .text = "quote" },
        .{ .source = "*:detail", .kind = .list_detail, .path = "*:", .text = "detail" },
        .{ .source = "**child", .kind = .list_item, .path = "**", .text = "child" },
        .{ .source = ";term : definition", .kind = .term, .path = ";", .text = "term : definition" },
        .{ .source = "::indent", .kind = .indent, .path = "::", .text = "indent" },
    };
    for (cases) |case| {
        const block = classifyLine(case.source);
        try std.testing.expectEqual(case.kind, block.kind);
        try std.testing.expectEqualStrings(case.path, block.list_path);
        try std.testing.expectEqualStrings(case.text, block.text);
        try std.testing.expectEqual(@as(u8, @intCast(case.path.len)), block.depth);
    }
}
