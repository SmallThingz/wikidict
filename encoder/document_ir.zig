const std = @import("std");
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

pub const InlineSpan = struct {
    kind: InlineKind,
    text: []const u8,
    target: []const u8 = "",
    trail: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
};

pub const DecodedBlock = struct {
    kind: BlockKind,
    depth: u8,
    text: []const u8,

    pub fn inlineIterator(self: DecodedBlock) InlineIterator {
        return .{ .input = self.text };
    }
};

pub const InlineIterator = struct {
    input: []const u8,
    cursor: usize = 0,
    bold: bool = false,
    italic: bool = false,

    pub fn next(self: *InlineIterator) ?InlineSpan {
        while (self.cursor < self.input.len) {
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
            if (parseInlineLinkAt(self.input, self.cursor)) |link| {
                self.cursor = link.end;
                return .{
                    .kind = .link,
                    .text = link.label,
                    .target = link.target,
                    .trail = link.trail,
                    .bold = self.bold,
                    .italic = self.italic,
                };
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
                continue;
            }

            const start = self.cursor;
            while (self.cursor < self.input.len) : (self.cursor += 1) {
                if (parseTemplateAt(self.input, self.cursor) != null or
                    parseInlineLinkAt(self.input, self.cursor) != null or
                    parseExternalLinkAt(self.input, self.cursor) != null or
                    parseLineBreakAt(self.input, self.cursor) != null or
                    emphasisMarkerAt(self.input, self.cursor, self.bold, self.italic) != null)
                {
                    break;
                }
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
        const block = classifyBlock(self.body[self.line_start..line_end]);
        self.line_start = if (line_end == self.body.len) self.body.len else line_end + 1;
        return block;
    }
};

pub const DecodedSection = struct {
    level: u8,
    title: []const u8,
    kind: SectionKind,
    body: []const u8,
    line_count: usize,
    term_records: ?[]TermRecord = null,

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
        allocator.free(self.title);
        allocator.free(self.body);
        if (self.term_records) |records| {
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

fn classifyBlock(line: []const u8) DecodedBlock {
    if (line.len == 0) return .{ .kind = .blank, .depth = 0, .text = line };

    if (line[0] == '#') {
        var depth: usize = 0;
        while (depth < line.len and line[depth] == '#') : (depth += 1) {}
        const rest = line[depth..];
        if (std.mem.startsWith(u8, rest, ":* ")) return blockWithPrefix(.quotation, depth, line, depth + 3);
        if (std.mem.startsWith(u8, rest, "* ")) return blockWithPrefix(.quotation, depth, line, depth + 2);
        if (std.mem.startsWith(u8, rest, ": ")) return blockWithPrefix(.example, depth, line, depth + 2);
        if (std.mem.startsWith(u8, rest, " ")) return blockWithPrefix(.definition, depth, line, depth + 1);
    }

    if (line[0] == '*') {
        var depth: usize = 0;
        while (depth < line.len and line[depth] == '*') : (depth += 1) {}
        const rest = line[depth..];
        if (std.mem.startsWith(u8, rest, ": ")) return blockWithPrefix(.list_detail, depth, line, depth + 2);
        if (std.mem.startsWith(u8, rest, " ")) return blockWithPrefix(.list_item, depth, line, depth + 1);
    }

    if (line[0] == ':') {
        var depth: usize = 0;
        while (depth < line.len and line[depth] == ':') : (depth += 1) {}
        if (depth < line.len and line[depth] == ' ') return blockWithPrefix(.indent, depth, line, depth + 1);
    }
    if (std.mem.startsWith(u8, line, "; ")) return .{ .kind = .term, .depth = 1, .text = line[2..] };
    return .{ .kind = .paragraph, .depth = 0, .text = line };
}

fn blockWithPrefix(kind: BlockKind, depth: usize, line: []const u8, text_start: usize) DecodedBlock {
    return .{
        .kind = kind,
        .depth = @intCast(@min(depth, std.math.maxInt(u8))),
        .text = line[text_start..],
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

fn parseTemplateAt(input: []const u8, start: usize) ?ParsedTemplate {
    if (start + 4 > input.len or !std.mem.eql(u8, input[start .. start + 2], "{{")) return null;
    if (start != 0 and input[start - 1] == '{') return null;
    if (start + 3 <= input.len and std.mem.eql(u8, input[start .. start + 3], "{{{")) return null;

    const close = findTemplateClose(input, start) orelse return null;
    const body = input[start + 2 .. close];
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    const name = std.mem.trim(u8, body[0..pipe], " \t\r\n");
    if (name.len == 0) return null;
    return .{ .end = close + 2, .name = name, .body = body };
}

fn findTemplateClose(input: []const u8, start: usize) ?usize {
    var template_depth: usize = 1;
    var parameter_depth: usize = 0;
    var cursor = start + 2;
    while (cursor < input.len) {
        if (cursor + 4 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 4], "<!--")) {
            if (std.mem.indexOfPos(u8, input, cursor + 4, "-->")) |comment_end| {
                cursor = comment_end + 3;
                continue;
            }
            return null;
        }
        if (cursor + 3 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 3], "{{{")) {
            parameter_depth += 1;
            cursor += 3;
            continue;
        }
        if (parameter_depth != 0 and cursor + 3 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 3], "}}}")) {
            parameter_depth -= 1;
            cursor += 3;
            continue;
        }
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "{{")) {
            template_depth += 1;
            cursor += 2;
            continue;
        }
        if (cursor + 2 <= input.len and std.mem.eql(u8, input[cursor .. cursor + 2], "}}")) {
            template_depth -= 1;
            if (template_depth == 0 and parameter_depth == 0) return cursor;
            cursor += 2;
            continue;
        }
        cursor += 1;
    }
    return null;
}

fn parseInlineLinkAt(input: []const u8, start: usize) ?ParsedInlineLink {
    if (start + 4 > input.len or !std.mem.eql(u8, input[start .. start + 2], "[[")) return null;

    var close = start + 2;
    while (close + 1 < input.len) : (close += 1) {
        if (input[close] != ']' or input[close + 1] != ']') continue;

        const inside = input[start + 2 .. close];
        if (inside.len == 0) return null;
        const pipe = std.mem.indexOfScalar(u8, inside, '|');
        const raw_target = if (pipe) |index| inside[0..index] else inside;
        const target = std.mem.trim(u8, raw_target, " \t");
        if (target.len == 0) return null;
        const raw_label = if (pipe) |index| inside[index + 1 ..] else target;
        const label = if (raw_label.len == 0) target else raw_label;
        var trail_end = close + 2;
        while (trail_end < input.len and std.ascii.isAlphabetic(input[trail_end])) : (trail_end += 1) {}
        return .{
            .end = trail_end,
            .target = target,
            .label = label,
            .trail = input[close + 2 .. trail_end],
        };
    }
    return null;
}

fn parseExternalLinkAt(input: []const u8, start: usize) ?ParsedExternalLink {
    if (start + 3 > input.len or input[start] != '[' or input[start + 1] == '[') return null;
    const body_start = start + 1;
    if (!startsWithAsciiIgnoreCase(input[body_start..], "http://") and
        !startsWithAsciiIgnoreCase(input[body_start..], "https://"))
    {
        return null;
    }

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
    if (target.len == 0) return null;
    const raw_label = if (separator) |index| std.mem.trimStart(u8, body[index + 1 ..], " \t") else target;
    const label = if (raw_label.len == 0) target else raw_label;
    return .{ .end = close + 1, .target = target, .label = label };
}

fn findExternalLinkClose(input: []const u8, start: usize) ?usize {
    var template_depth: usize = 0;
    var link_depth: usize = 0;
    var cursor = start + 1;
    while (cursor < input.len) : (cursor += 1) {
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
