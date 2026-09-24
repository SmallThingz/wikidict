const std = @import("std");
const model = @import("model.zig");
const args = @import("args.zig");
const store = @import("store.zig");
const terminal = @import("terminal.zig");
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

fn tableText(w: *std.Io.Writer, table: model.Table, color: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    terminal.initLocale();
    const Placed = struct { row: usize, column: usize, colspan: usize, rowspan: usize, lines: []const []const u8 };
    var cells: std.ArrayList(Placed) = .empty;
    var occupied: std.ArrayList(usize) = .empty;
    var widths: std.ArrayList(usize) = .empty;
    for (table.rows, 0..) |row, r| {
        var column: usize = 0;
        for (row.cells) |cell| {
            const colspan = @max(cell.colspan, 1);
            const rowspan = @max(cell.rowspan, 1);
            while (true) {
                while (occupied.items.len < column + colspan) {
                    try occupied.append(a, 0);
                    try widths.append(a, 3);
                }
                var free = true;
                for (occupied.items[column..][0..colspan]) |until| if (until > r) {
                    free = false;
                    break;
                };
                if (free) break;
                column += 1;
            }
            @memset(occupied.items[column..][0..colspan], r + rowspan);
            var text: std.Io.Writer.Allocating = .init(a);
            defer text.deinit();
            if (color and cell.header) try text.writer.writeAll("\x1b[1m");
            try spansText(&text.writer, cell.spans, color);
            if (color) try text.writer.writeAll("\x1b[0m");
            const owned = try a.dupe(u8, text.written());
            var lines: std.ArrayList([]const u8) = .empty;
            var split = std.mem.splitScalar(u8, owned, '\n');
            var needed: usize = 0;
            while (split.next()) |line| {
                try lines.append(a, line);
                needed = @max(needed, terminal.cellWidth(line));
            }
            var available: usize = 3 * (colspan - 1);
            for (widths.items[column..][0..colspan]) |width| available += width;
            if (needed > available) widths.items[column + colspan - 1] += needed - available;
            try cells.append(a, .{ .row = r, .column = column, .colspan = colspan, .rowspan = rowspan, .lines = lines.items });
            column += colspan;
        }
    }
    if (table.caption.len != 0) {
        try spansText(w, table.caption, color);
        try w.writeByte('\n');
    }
    const active = try a.alloc(?usize, widths.items.len);
    @memset(active, null);
    var cursor: usize = 0;
    for (0..table.rows.len) |r| {
        for (active) |*owner| if (owner.*) |index| {
            if (cells.items[index].row + cells.items[index].rowspan <= r) owner.* = null;
        };
        var height: usize = 1;
        while (cursor < cells.items.len and cells.items[cursor].row == r) : (cursor += 1) {
            const cell = cells.items[cursor];
            @memset(active[cell.column..][0..cell.colspan], cursor);
            height = @max(height, cell.lines.len);
        }
        for (0..height) |line_index| {
            try w.writeAll("  │ ");
            var column: usize = 0;
            while (column < widths.items.len) {
                var span: usize = 1;
                var line: []const u8 = "";
                if (active[column]) |index| {
                    const cell = cells.items[index];
                    span = cell.colspan;
                    if (cell.row == r and line_index < cell.lines.len) line = cell.lines[line_index];
                }
                var width: usize = 3 * (span - 1);
                for (widths.items[column..][0..span]) |part| width += part;
                try w.writeAll(line);
                try w.splatByteAll(' ', width -| terminal.cellWidth(line));
                column += span;
                try w.writeAll(if (column == widths.items.len) " │\n" else " │ ");
            }
        }
    }
    try w.writeByte('\n');
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
            try tableText(w, table, color);
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
    if (entry.display_title.len != 0)
        try spansText(w, entry.display_title, color)
    else
        try terminalText(w, entry.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (details and entry.preamble_spans.len != 0) {
        try spansText(w, entry.preamble_spans, color);
        try w.writeByte('\n');
    }
    const organization = entry.organization;
    if (organization.lexemes.len == 0) {
        for (entry.sections) |section| {
            if (!details) {
                var heading = false;
                for (section.blocks) |block| if (block.kind == .definition) {
                    if (!heading) {
                        try terminalText(w, section.title);
                        try w.writeByte('\n');
                        heading = true;
                    }
                    try blocksText(w, &.{block}, color);
                };
                continue;
            }
            if (std.mem.eql(u8, section.title, entry.language orelse ""))
                try blocksText(w, section.blocks, color)
            else
                try sectionText(w, section, color);
        }
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
                if (details) if (part.etymology) |e| {
                    try w.writeAll("  [");
                    try terminalText(w, entry.sections[e].title);
                    try w.writeAll("]\n");
                };
                if (details) for (part.introduction) |i| try blocksText(w, section.blocks[i..][0..1], color);
                for (part.definitions) |sense| {
                    try blocksText(w, section.blocks[sense.block..][0..1], color);
                    if (details) for (sense.examples) |i| try blocksText(w, section.blocks[i..][0..1], color);
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
    if (details) try entryMetadata(w, entry, color);
}

fn entryMetadata(w: *std.Io.Writer, entry: model.Entry, color: bool) !void {
    if (entry.media.len != 0) {
        try w.writeAll("\nMedia\n");
        for (entry.media) |media| {
            try w.print("[{s}] ", .{@tagName(media.kind)});
            try terminalText(w, media.file);
            if (media.caption.len != 0) {
                try w.writeAll(" — ");
                try terminalText(w, media.caption);
            }
            try w.writeByte('\n');
        }
    }
    if (entry.references.len != 0) {
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

/// Terminal folds operate on compiled sections, never by reparsing source.
pub fn entryTextFolded(frame: *std.Io.Writer.Allocating, entry: model.Entry, color: bool, preferences: @import("reading_state.zig").Data, expanded: []const usize, selected: usize) !usize {
    const w = &frame.writer;
    var selected_offset: usize = 0;
    if (entry.display_title.len != 0) try spansText(w, entry.display_title, color) else try terminalText(w, entry.title);
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (entry.preamble_spans.len != 0) {
        try spansText(w, entry.preamble_spans, color);
        try w.writeByte('\n');
    }
    for (entry.sections, 0..) |section, index| {
        if (section.blocks.len == 0) continue;
        var meaning = false;
        for (section.blocks) |block| if (block.kind == .definition) {
            meaning = true;
            break;
        };
        const initially_closed = if (preferences.details) false else if (std.mem.startsWith(u8, section.title, "Pronunciation")) preferences.collapse_pronunciation else if (std.mem.startsWith(u8, section.title, "Etymology")) preferences.collapse_etymology else if (meaning) preferences.collapse_notes else preferences.collapse_other;
        const toggled = std.mem.indexOfScalar(usize, expanded, index) != null;
        const closed = initially_closed != toggled;
        try w.writeByte('\n');
        if (selected == index) selected_offset = frame.written().len;
        if (color and selected == index) try w.writeAll("\x1b[1m");
        try w.writeAll(if (selected == index) "> " else "  ");
        try terminalText(w, section.title);
        if (closed) try w.writeAll(if (meaning) "  [+ notes]" else "  [+]");
        if (color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
        for (section.blocks) |block| if (!closed or (meaning and block.kind == .definition)) try blocksText(w, &.{block}, color);
    }
    if (preferences.details) try entryMetadata(w, entry, color) else if (entry.media.len != 0 or entry.references.len != 0) try w.writeAll("\n  d: media and references\n");
    return selected_offset;
}
