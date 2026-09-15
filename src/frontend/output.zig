const std = @import("std");
const model = @import("model.zig");
const args = @import("args.zig");
const store = @import("store.zig");
pub const Match = struct { title: []const u8 };
pub const Response = struct {
    schema: []const u8 = "dict.results.v1",
    operation: args.Command,
    query: []const u8,
    kind: store.Kind,
    language: ?[]const u8,
    match_mode: []const u8 = "exact-utf8-prefix",
    record_count: usize,
    total_matches: usize,
    offset: usize = 0,
    has_more: bool = false,
    matches: []const Match = &.{},
    entries: []const model.Entry = &.{},
};

pub fn terminalText(w: *std.Io.Writer, text: []const u8) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        if (n > text.len - pos) {
            try w.writeAll("�");
            pos += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[pos..][0..n]) catch {
            try w.writeAll("�");
            pos += 1;
            continue;
        };
        if (cp == '\n' or cp == '\t') try w.writeByte(@intCast(cp)) else if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x061c or cp == 0x200e or cp == 0x200f or cp == 0x2028 or cp == 0x2029 or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x206f))
            try w.print("\\u{{{x}}}", .{cp})
        else
            try w.writeAll(text[pos..][0..n]);
        pos += n;
    }
}

pub fn spansText(w: *std.Io.Writer, spans: []const model.Span, color: bool) !void {
    for (spans) |span| {
        if (color and span.bold) try w.writeAll("\x1b[1m");
        if (color and span.italic) try w.writeAll("\x1b[3m");
        if (color and span.underline) try w.writeAll("\x1b[4m");
        if (color and span.strike) try w.writeAll("\x1b[9m");
        if (color and (span.small or span.role == .label or span.role == .citation)) try w.writeAll("\x1b[2m");
        if (color and (span.kind == .link or span.kind == .external_link)) try w.writeAll("\x1b[36m");
        if (span.kind == .line_break) {
            try w.writeByte('\n');
        } else {
            if (span.superscript and span.role != .reference) try w.writeByte('^');
            if (span.subscript) try w.writeByte('_');
            try terminalText(w, span.text);
        }
        try terminalText(w, span.trail);
        if (color) try w.writeAll("\x1b[0m");
    }
}

fn blocksText(w: *std.Io.Writer, blocks: []const model.Block, color: bool) !void {
    var ordinal: usize = 0;
    for (blocks) |block| {
        if (block.kind == .blank) continue;
        if (block.kind == .rule) {
            try w.writeAll("────────────────────────\n");
            continue;
        }
        if (block.table) |table| {
            if (table.caption.len != 0) {
                try spansText(w, table.caption, color);
                try w.writeByte('\n');
            }
            for (table.rows) |row| {
                try w.writeAll("  │ ");
                for (row.cells, 0..) |cell, i| {
                    if (i != 0) try w.writeAll(" │ ");
                    if (color and cell.header) try w.writeAll("\x1b[1m");
                    try spansText(w, cell.spans, color);
                    if (color) try w.writeAll("\x1b[0m");
                }
                try w.writeAll(" │\n");
            }
            try w.writeByte('\n');
            continue;
        }
        try w.splatByteAll(' ', @as(usize, @min(block.depth, 12)) * 2);
        switch (block.kind) {
            .definition => {
                ordinal += 1;
                if (block.number.len != 0) {
                    try terminalText(w, block.number);
                    try w.writeAll(". ");
                } else try w.print("{d}. ", .{ordinal});
            },
            .example, .quotation => try w.writeAll("│ "),
            .list_item => try w.writeAll("• "),
            .preformatted => try w.writeAll("    "),
            else => {},
        }
        try spansText(w, block.spans, color);
        if (block.feature) |f| if (f.language.len != 0) {
            try w.writeAll("  [");
            try terminalText(w, f.language);
            try w.writeByte(']');
        };
        try w.writeByte('\n');
        if (block.kind == .paragraph or block.kind == .quotation) try w.writeByte('\n');
    }
}

fn sectionText(w: *std.Io.Writer, section: model.Section, color: bool) !void {
    try w.writeByte('\n');
    if (color) try w.writeAll("\x1b[1m");
    try terminalText(w, section.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeByte('\n');
    try blocksText(w, section.blocks, color);
}

pub fn entryText(w: *std.Io.Writer, entry: model.Entry, color: bool) !void {
    return entryTextWithDetails(w, entry, color, true);
}

pub fn entryTextWithDetails(w: *std.Io.Writer, entry: model.Entry, color: bool, details: bool) !void {
    if (color) try w.writeAll("\x1b[1;36m");
    try terminalText(w, entry.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (entry.preamble_spans.len != 0) {
        try spansText(w, entry.preamble_spans, color);
        try w.writeByte('\n');
    }
    const organization = entry.organization;
    if (organization.lexemes.len == 0) {
        for (entry.sections) |section| try sectionText(w, section, color);
    } else {
        for (organization.lexemes, 0..) |lexeme, l| {
            var seen = false;
            for (organization.lexemes[0..l]) |previous| if (std.mem.eql(u8, previous.kind, lexeme.kind) and std.mem.eql(u8, previous.language, lexeme.language)) {
                seen = true;
                break;
            };
            if (seen) continue;
            try w.writeByte('\n');
            if (color) try w.writeAll("\x1b[1m");
            try terminalText(w, lexeme.kind);
            if (lexeme.language.len != 0 and !std.mem.eql(u8, lexeme.language, entry.language orelse "")) {
                try w.writeAll(" / ");
                try terminalText(w, lexeme.language);
            }
            if (color) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
            for (organization.lexemes) |part| {
                if (!std.mem.eql(u8, part.kind, lexeme.kind) or !std.mem.eql(u8, part.language, lexeme.language)) continue;
                const section = entry.sections[part.section];
                if (part.etymology) |e| {
                    try w.writeAll("  [");
                    try terminalText(w, entry.sections[e].title);
                    try w.writeAll("]\n");
                }
                for (part.introduction) |i| try blocksText(w, section.blocks[i..][0..1], color);
                for (part.definitions) |sense| {
                    try blocksText(w, section.blocks[sense.block..][0..1], color);
                    for (sense.examples) |i| try blocksText(w, section.blocks[i..][0..1], color);
                    if (details) {
                        for (sense.notes) |i| try blocksText(w, section.blocks[i..][0..1], color);
                        for (sense.quotations) |i| try blocksText(w, section.blocks[i..][0..1], color);
                    }
                }
                if (details) {
                    for (part.other_blocks) |i| try blocksText(w, section.blocks[i..][0..1], color);
                    for (part.related_sections) |i| try sectionText(w, entry.sections[i], color);
                }
            }
        }
        if (details) for (organization.other_sections) |i| try sectionText(w, entry.sections[i], color);
    }
    if (details and entry.references.len != 0) {
        try w.writeAll("\nReferences\n");
        for (entry.references) |ref| {
            if (ref.group.len == 0) try w.print("[{d}] ", .{ref.group_number}) else {
                try w.writeByte('[');
                try terminalText(w, ref.group);
                try w.print(" {d}] ", .{ref.group_number});
            }
            try spansText(w, ref.spans, color);
            try w.writeByte('\n');
        }
    }
}

pub fn json(w: *std.Io.Writer, response: Response) !void {
    try std.json.Stringify.value(response, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

test "terminal output neutralizes control and bidi sequences without corrupting unicode" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try terminalText(&w.writer, "é猫\x1b[2J\u{9b}31m\u{61c}a\u{200e}b\u{200f}c\u{2028}d\u{2029}e\u{202e}f\u{206a}g\u{206f}x");
    try std.testing.expectEqualStrings("é猫\\u{1b}[2J\\u{9b}31m\\u{61c}a\\u{200e}b\\u{200f}c\\u{2028}d\\u{2029}e\\u{202e}f\\u{206a}g\\u{206f}x", w.written());
}

test "JSON output is a complete versioned machine response" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try json(&w.writer, .{ .operation = .search, .query = "a\"", .kind = .language, .language = "English", .record_count = 2, .total_matches = 0 });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dict.results.v1", parsed.value.object.get("schema").?.string);
}

test "human renderer consumes compiled spans only" {
    const spans = [_]model.Span{.{ .text = "A small feline.", .bold = true }};
    const blocks = [_]model.Block{.{ .kind = .definition, .depth = 1, .spans = &spans, .list_path = "#" }};
    const sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
    const senses = [_]model.Sense{.{ .block = 0 }};
    const lexemes = [_]model.Lexeme{.{ .language = "English", .kind = "Noun", .section = 0, .definitions = &senses }};
    const entry: model.Entry = .{ .title = "cat", .kind = .language, .language = "English", .sections = &sections, .organization = .{ .lexemes = &lexemes } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A small feline.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[[") == null);
}
