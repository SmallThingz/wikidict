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

// Display metadata stays outside lexical spans and serialized DPR2 text.
const PoemInfo = struct {
    marked: bool = false,
    depth: u8 = 0,
    rtl: bool = false,
    invalid_depth: bool = false,
    invalid_direction: bool = false,

    fn parse(classes: []const u8) PoemInfo {
        var result: PoemInfo = .{};
        var depth_seen = false;
        var direction_seen = false;
        var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0b\x0c");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "wikidict-poem")) result.marked = true;
            if (std.mem.startsWith(u8, token, "wikidict-poem-indent")) {
                const digits = if (std.mem.startsWith(u8, token, "wikidict-poem-indent-")) token["wikidict-poem-indent-".len..] else "";
                const depth = if (digits.len > 0 and digits.len <= 2 and digits[0] != '0') std.fmt.parseInt(u8, digits, 10) catch 0 else 0;
                var decimal = true;
                for (digits) |digit| if (digit < '0' or digit > '9') {
                    decimal = false;
                };
                if (depth_seen or !decimal or depth == 0 or depth > 32) result.invalid_depth = true;
                depth_seen = true;
                result.depth = depth;
            }
            if (std.mem.startsWith(u8, token, "wikidict-poem-dir")) {
                if (direction_seen) result.invalid_direction = true;
                direction_seen = true;
                if (std.mem.eql(u8, token, "wikidict-poem-dir-rtl")) result.rtl = true else if (!std.mem.eql(u8, token, "wikidict-poem-dir-ltr")) result.invalid_direction = true;
            }
        }
        if (!result.marked) return .{};
        if (result.invalid_depth) result.depth = 0;
        if (result.invalid_direction) result.rtl = false;
        return result;
    }
    fn merge(self: *PoemInfo, other: PoemInfo) void {
        self.invalid_depth = self.invalid_depth or other.invalid_depth or self.depth != other.depth or self.marked != other.marked;
        self.invalid_direction = self.invalid_direction or other.invalid_direction or self.rtl != other.rtl or self.marked != other.marked;
        self.marked = self.marked or other.marked;
        if (self.invalid_depth) self.depth = 0;
        if (self.invalid_direction) self.rtl = false;
    }
};

/// Offsets refer to the formatted buffer, never to padded replacements of link text.
pub const PoemProjection = struct {
    frame: *std.Io.Writer.Allocating,
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(terminal.PoemLine),
    scanned: usize = 0,
    line_start: usize = 0,
    fn record(self: *PoemProjection, info: PoemInfo) !void {
        const text = self.frame.written();
        for (text[self.scanned..], self.scanned..) |byte, offset| if (byte == '\n') {
            self.line_start = offset + 1;
        };
        self.scanned = text.len;
        if (!info.marked) return;
        const prefix = terminal.cellWidth(text[self.line_start..]);
        const line: terminal.PoemLine = .{
            .offset = self.line_start,
            .lead_bytes = text.len - self.line_start,
            .lead_cells = prefix,
            .left = if (info.rtl) 0 else info.depth,
            .continuation_left = prefix + (if (info.rtl) @as(usize, 0) else info.depth),
            .right = if (info.rtl) info.depth else 0,
        };
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].offset == line.offset) {
            const previous = &self.lines.items[self.lines.items.len - 1];
            if (previous.left != line.left or previous.right != line.right) {
                previous.left = 0;
                previous.right = 0;
                previous.continuation_left = prefix;
            }
        } else try self.lines.append(self.allocator, line);
    }
};

const SpanPiece = struct { span: model.Span, bytes: []const u8, ends_line: bool, initial: bool, info: PoemInfo };
const SpanCursor = struct {
    spans: []const model.Span,
    index: usize = 0,
    phase: u2 = 0,
    offset: usize = 0,
    raw_continuation: bool = false,
    info: PoemInfo = .{},
    fn next(self: *SpanCursor) ?SpanPiece {
        while (self.index < self.spans.len) {
            if (self.phase == 2) {
                self.index += 1;
                self.phase = 0;
                self.offset = 0;
                self.raw_continuation = false;
                continue;
            }
            const span = self.spans[self.index];
            if (self.phase == 0 and self.offset == 0 and !self.raw_continuation) self.info = PoemInfo.parse(span.classes);
            if (self.phase == 0 and span.kind == .line_break) {
                self.phase = 1;
                self.raw_continuation = true;
                return .{ .span = span, .bytes = "", .ends_line = true, .initial = false, .info = self.info };
            }
            const text = if (self.phase == 0) span.text else span.trail;
            if (self.offset < text.len or (self.phase == 0 and text.len == 0)) {
                const start = self.offset;
                const end = if (std.mem.indexOfScalar(u8, text[start..], '\n')) |lf| start + lf else text.len;
                const newline = end < text.len;
                var info = self.info;
                if (self.raw_continuation) info.depth = 0;
                const piece: SpanPiece = .{ .span = span, .bytes = text[start..end], .ends_line = newline, .initial = self.phase == 0 and start == 0, .info = info };
                self.offset = if (newline) end + 1 else end;
                if (newline) self.raw_continuation = true;
                if (!newline) {
                    self.phase += 1;
                    self.offset = 0;
                }
                return piece;
            }
            self.phase += 1;
            self.offset = 0;
            if (self.phase == 2) {
                self.index += 1;
                self.phase = 0;
                self.raw_continuation = false;
            }
        }
        return null;
    }
};

fn spanPieceText(w: *std.Io.Writer, piece: SpanPiece, color: bool) !void {
    const span = piece.span;
    if (piece.bytes.len == 0) return;
    if (color and span.bold) try w.writeAll("\x1b[1m");
    if (color and span.italic) try w.writeAll("\x1b[3m");
    if (color and span.underline) try w.writeAll("\x1b[4m");
    if (color and span.strike) try w.writeAll("\x1b[9m");
    if (color and (span.small or span.role == .label or span.role == .citation)) try w.writeAll("\x1b[2m");
    if (color and (span.kind == .link or span.kind == .external_link)) try w.writeAll("\x1b[36m");
    if (piece.initial and span.superscript and span.role != .reference) try w.writeByte('^');
    if (piece.initial and span.subscript) try w.writeByte('_');
    try terminalText(w, piece.bytes);
    if (color) try w.writeAll("\x1b[0m");
}

pub fn spansText(w: *std.Io.Writer, spans: []const model.Span, color: bool) !void {
    return spansTextProjected(w, spans, color, null);
}
fn spansTextProjected(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection) !void {
    var cursor: SpanCursor = .{ .spans = spans };
    while (true) {
        var scan = cursor;
        const first = scan.next() orelse break;
        var info = first.info;
        var count: usize = 1;
        var newline = first.ends_line;
        while (!newline) {
            const piece = scan.next() orelse break;
            // An ordinary boundary break ends the marked line without changing its layout.
            if (!(piece.span.kind == .line_break and piece.ends_line and !piece.info.marked)) info.merge(piece.info);
            count += 1;
            newline = piece.ends_line;
        }
        if (projection) |p| try p.record(info) else if (info.marked and !info.rtl) try w.splatByteAll(' ', info.depth);
        for (0..count) |_| try spanPieceText(w, cursor.next().?, color);
        if (projection == null and info.marked and info.rtl) try w.splatByteAll(' ', info.depth);
        if (newline) try w.writeByte('\n');
    }
}

fn tableText(w: *std.Io.Writer, table: model.Table, color: bool, projection: ?*PoemProjection) !void {
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
        try spansTextProjected(w, table.caption, color, projection);
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
    return blocksTextProjected(w, blocks, color, null);
}
fn blocksTextProjected(w: *std.Io.Writer, blocks: []const model.Block, color: bool, projection: ?*PoemProjection) !void {
    var ordinal: usize = 0;
    for (blocks) |block| {
        if (block.kind == .blank) continue;
        if (block.kind == .rule) {
            try w.writeAll("────────────────────────\n");
            continue;
        }
        if (block.table) |table| {
            try tableText(w, table, color, projection);
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
            .list_item => if (block.number.len != 0) {
                try terminalText(w, block.number);
                try w.writeAll(". ");
            } else try w.writeAll("• "),
            .preformatted => try w.writeAll("    "),
            else => {},
        }
        try spansTextProjected(w, block.spans, color, projection);
        if (block.feature) |f| if (f.language.len != 0) {
            try w.writeAll("  [");
            try terminalText(w, f.language);
            try w.writeByte(']');
        };
        try w.writeByte('\n');
        if (block.kind == .paragraph or block.kind == .quotation) try w.writeByte('\n');
    }
}

// Match the producer's data-only rich heading companion without allocating or
// interpreting source. Section names and all block/layout indices stay intact.
const HeadingBytes = struct {
    spans: []const model.Span,
    index: usize = 0,
    phase: u2 = 0,
    offset: usize = 0,
    fn next(self: *HeadingBytes) ?u8 {
        while (self.index < self.spans.len) {
            const span = self.spans[self.index];
            const part = if (span.kind == .line_break)
                (if (self.phase == 0) "\n" else "")
            else if (self.phase == 0) span.text else span.trail;
            if (self.offset < part.len) {
                const byte = part[self.offset];
                self.offset += 1;
                return byte;
            }
            self.offset = 0;
            self.phase += 1;
            if (self.phase == 2) {
                self.phase = 0;
                self.index += 1;
            }
        }
        return null;
    }
};
fn sectionHeadingCompanion(section: model.Section) ?[]const model.Span {
    if (section.title.len == 0 or section.blocks.len == 0) return null;
    const first = section.blocks[0];
    if (first.kind != .heading or first.level != section.level) return null;
    var navigable = false;
    for (first.spans) |span| {
        if (span.kind == .line_break and span.trail.len != 0) return null;
        if ((span.kind == .link or span.kind == .external_link) and
            span.target.len != 0 and (span.text.len != 0 or span.trail.len != 0)) navigable = true;
    }
    if (!navigable) return null;
    var cursor: HeadingBytes = .{ .spans = first.spans };
    var offset: usize = 0;
    var begin: ?usize = null;
    var end: usize = 0;
    while (cursor.next()) |byte| {
        const start = offset;
        offset += 1;
        var edge = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
        if (byte == 0xc2) {
            var lookahead = cursor;
            if (lookahead.next() == 0xa0) {
                cursor = lookahead;
                offset += 1;
                edge = true;
            }
        }
        if (!edge) {
            if (begin == null) begin = start;
            end = offset;
        }
    }
    const start = begin orelse return null;
    if (end - start != section.title.len) return null;
    cursor = .{ .spans = first.spans };
    for (0..start) |_| _ = cursor.next();
    for (section.title) |byte| if (cursor.next() != byte) return null;
    return first.spans;
}
fn sectionLabelProjected(w: *std.Io.Writer, section: model.Section, color: bool, projection: ?*PoemProjection) !void {
    if (sectionHeadingCompanion(section)) |spans|
        try spansTextProjected(w, spans, color, projection)
    else
        try terminalText(w, section.title);
}

fn sectionTextProjected(w: *std.Io.Writer, section: model.Section, color: bool, projection: ?*PoemProjection) !void {
    try w.writeByte('\n');
    if (color) try w.writeAll("\x1b[1m");
    try sectionLabelProjected(w, section, color, projection);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeByte('\n');
    const first: usize = if (sectionHeadingCompanion(section) != null) 1 else 0;
    try blocksTextProjected(w, section.blocks[first..], color, projection);
}

pub fn entryText(w: *std.Io.Writer, entry: model.Entry, color: bool) !void {
    return entryTextWithDetails(w, entry, color, true);
}

pub fn entryTextWithDetails(w: *std.Io.Writer, entry: model.Entry, color: bool, details: bool) !void {
    return entryTextWithDetailsProjected(w, entry, color, details, null);
}
pub fn entryTextWithDetailsProjected(w: *std.Io.Writer, entry: model.Entry, color: bool, details: bool, projection: ?*PoemProjection) !void {
    if (color) try w.writeAll("\x1b[1;36m");
    if (entry.display_title.len != 0)
        try spansTextProjected(w, entry.display_title, color, projection)
    else
        try terminalText(w, entry.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if ((details or entry.kind == .alias) and entry.preamble_spans.len != 0) {
        try spansTextProjected(w, entry.preamble_spans, color, projection);
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
                    try blocksTextProjected(w, &.{block}, color, projection);
                };
                continue;
            }
            if (std.mem.eql(u8, section.title, entry.language orelse "") and sectionHeadingCompanion(section) == null)
                try blocksTextProjected(w, section.blocks, color, projection)
            else
                try sectionTextProjected(w, section, color, projection);
        }
    } else {
        for (organization.lexemes, 0..) |lexeme, l| {
            var seen = false;
            for (organization.lexemes[0..l]) |previous| if (std.mem.eql(u8, previous.kind, lexeme.kind) and std.mem.eql(u8, previous.language, lexeme.language)) {
                seen = true;
                break;
            };
            if (seen) continue;
            var per_part_headers = false;
            if (details) for (organization.lexemes) |part| {
                if (std.mem.eql(u8, part.kind, lexeme.kind) and std.mem.eql(u8, part.language, lexeme.language) and
                    sectionHeadingCompanion(entry.sections[part.section]) != null)
                {
                    per_part_headers = true;
                    break;
                }
            };
            if (!per_part_headers) {
                try w.writeByte('\n');
                if (color) try w.writeAll("\x1b[1m");
                try terminalText(w, lexeme.kind);
                if (lexeme.language.len != 0 and !std.mem.eql(u8, lexeme.language, entry.language orelse "")) {
                    try w.writeAll(" / ");
                    try terminalText(w, lexeme.language);
                }
                if (color) try w.writeAll("\x1b[0m");
                try w.writeByte('\n');
            }
            for (organization.lexemes) |part| {
                if (!std.mem.eql(u8, part.kind, lexeme.kind) or !std.mem.eql(u8, part.language, lexeme.language)) continue;
                const section = entry.sections[part.section];
                const companion = sectionHeadingCompanion(section);
                const rendered_companion = per_part_headers and companion != null;
                if (per_part_headers) {
                    try w.writeByte('\n');
                    if (color) try w.writeAll("\x1b[1m");
                    if (companion) |spans| try spansTextProjected(w, spans, color, projection) else try terminalText(w, part.kind);
                    if (part.language.len != 0 and !std.mem.eql(u8, part.language, entry.language orelse "")) {
                        try w.writeAll(" / ");
                        try terminalText(w, part.language);
                    }
                    if (color) try w.writeAll("\x1b[0m");
                    try w.writeByte('\n');
                }
                if (details) if (part.etymology) |e| {
                    try w.writeAll("  [");
                    try terminalText(w, entry.sections[e].title);
                    try w.writeAll("]\n");
                };
                if (details) for (part.introduction) |i| {
                    if (rendered_companion and i == 0) continue;
                    try blocksTextProjected(w, section.blocks[i..][0..1], color, projection);
                };
                for (part.definitions) |sense| {
                    try blocksTextProjected(w, section.blocks[sense.block..][0..1], color, projection);
                    if (details) for (sense.examples) |i| try blocksTextProjected(w, section.blocks[i..][0..1], color, projection);
                    if (details) {
                        for (sense.notes) |i| try blocksTextProjected(w, section.blocks[i..][0..1], color, projection);
                        for (sense.quotations) |i| try blocksTextProjected(w, section.blocks[i..][0..1], color, projection);
                    }
                }
                if (details) {
                    for (part.other_blocks) |i| {
                        if (rendered_companion and i == 0) continue;
                        try blocksTextProjected(w, section.blocks[i..][0..1], color, projection);
                    }
                    for (part.related_sections) |i| try sectionTextProjected(w, entry.sections[i], color, projection);
                }
            }
        }
        if (details) for (organization.other_sections) |i| try sectionTextProjected(w, entry.sections[i], color, projection);
    }
    if (details) try entryMetadataProjected(w, entry, color, projection);
}

fn entryMetadataProjected(w: *std.Io.Writer, entry: model.Entry, color: bool, projection: ?*PoemProjection) !void {
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
            try spansTextProjected(w, ref.spans, color, projection);
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

test "compact terminal output retains the displayed alias destination" {
    const spans = [_]model.Span{.{ .kind = .link, .text = "C", .target = "C#Noun" }};
    var entry: model.Entry = .{
        .title = "B",
        .kind = .alias,
        .preamble_spans = &spans,
        .redirect = .{ .source_title = "A", .target_title = "B", .fragment = "Incoming", .followed = true },
        .alias = .{ .xml_target = "C", .target_title = "C", .fragment = "Noun" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryTextWithDetails(&out.writer, entry, false, false);
    try std.testing.expectEqualStrings("B  / alias\nC\n", out.written());
    entry.kind = .citations;
    entry.redirect = null;
    entry.alias = null;
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, false);
    try std.testing.expectEqualStrings("B  / citations\n", out.written());
}

/// Terminal folds operate on compiled sections, never by reparsing source.
pub fn entryTextFolded(frame: *std.Io.Writer.Allocating, entry: model.Entry, color: bool, preferences: @import("reading_state.zig").Data, expanded: []const usize, selected: usize) !usize {
    return entryTextFoldedProjected(frame, entry, color, preferences, expanded, selected, null);
}
pub fn entryTextFoldedProjected(frame: *std.Io.Writer.Allocating, entry: model.Entry, color: bool, preferences: @import("reading_state.zig").Data, expanded: []const usize, selected: usize, projection: ?*PoemProjection) !usize {
    const w = &frame.writer;
    var selected_offset: usize = 0;
    if (entry.display_title.len != 0) try spansTextProjected(w, entry.display_title, color, projection) else try terminalText(w, entry.title);
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (entry.preamble_spans.len != 0) {
        try spansTextProjected(w, entry.preamble_spans, color, projection);
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
        try sectionLabelProjected(w, section, color, projection);
        if (closed) try w.writeAll(if (meaning) "  [+ notes]" else "  [+]");
        if (color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
        const first: usize = if (sectionHeadingCompanion(section) != null) 1 else 0;
        for (section.blocks[first..]) |block| if (!closed or (meaning and block.kind == .definition)) try blocksTextProjected(w, &.{block}, color, projection);
    }
    if (preferences.details) try entryMetadataProjected(w, entry, color, projection) else if (entry.media.len != 0 or entry.references.len != 0) try w.writeAll("\n  d: media and references\n");
    return selected_offset;
}
test "ordered list items render numbers without becoming dictionary meanings" {
    const spans = [_]model.Span{.{ .text = "instruction" }};
    const blocks = [_]model.Block{
        .{ .kind = .list_item, .depth = 1, .list_path = "#", .number = "3", .spans = &spans },
        .{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &spans },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try blocksText(&out.writer, &blocks, false);
    try std.testing.expectEqualStrings("  3. instruction\n  • instruction\n", out.written());
}

test "Poem class projection rejects malformed conflicting layout without changing lexical text" {
    const valid = PoemInfo.parse("other wikidict-poem mw-poem-indented wikidict-poem-indent-3 wikidict-poem-dir-rtl");
    try std.testing.expect(valid.marked and valid.depth == 3 and valid.rtl);
    for ([_][]const u8{ "0", "03", "+3", "33", "", "x" }) |suffix| {
        var name: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer name.deinit();
        try name.writer.print("wikidict-poem wikidict-poem-indent-{s}", .{suffix});
        try std.testing.expectEqual(@as(u8, 0), PoemInfo.parse(name.written()).depth);
    }
    try std.testing.expectEqual(@as(u8, 0), PoemInfo.parse("wikidict-poem-indent-3").depth);
    try std.testing.expectEqual(@as(u8, 0), PoemInfo.parse("wikidict-poem wikidict-poem-indent-3 wikidict-poem-indent-3").depth);
    const bad_direction = PoemInfo.parse("wikidict-poem wikidict-poem-indent-3 wikidict-poem-dir-rtl wikidict-poem-dir-ltr");
    try std.testing.expect(bad_direction.depth == 3 and !bad_direction.rtl);
    const spans = [_]model.Span{
        .{ .kind = .link, .text = "cat", .target = "cat", .classes = "wikidict-poem wikidict-poem-indent-2" },
        .{ .text = " word", .classes = "wikidict-poem wikidict-poem-indent-3" },
        .{ .kind = .line_break, .classes = "wikidict-poem wikidict-poem-indent-2" },
    };
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try spansText(&text.writer, &spans, false);
    try std.testing.expectEqualStrings("cat word\n", text.written());
    try std.testing.expectEqualStrings("cat", spans[0].text);
    try std.testing.expectEqualStrings("cat", spans[0].target);
}

test "Poem typed spans preserve links blank stanzas and first and wrapped row margins" {
    terminal.initLocale();
    const classes = "wikidict-poem mw-poem-indented wikidict-poem-indent-2";
    const spans = [_]model.Span{
        .{ .kind = .link, .text = "ab", .target = "cat", .classes = classes },
        .{ .text = "cdef", .bold = true, .classes = classes },
        .{ .kind = .line_break, .classes = classes },
        .{ .kind = .line_break, .classes = "wikidict-poem" },
        .{ .text = "z", .classes = "wikidict-poem" },
        .{ .kind = .line_break, .classes = "wikidict-poem" },
    };
    const codec = @import("blob_encoder").presentation_codec;
    const encoded = try codec.encodeAlloc(std.testing.allocator, .{ .entry = .{ .title = "verse", .kind = .citations, .preamble_spans = &spans } });
    defer std.testing.allocator.free(encoded);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try codec.decodeAlloc(arena.allocator(), encoded, "verse", .citations, null);
    try std.testing.expectEqualStrings("ab", decoded.entry.preamble_spans[0].text);
    try std.testing.expectEqualStrings("cat", decoded.entry.preamble_spans[0].target);
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var projection: PoemProjection = .{ .frame = &text, .allocator = std.testing.allocator, .lines = &lines };
    try spansTextProjected(&text.writer, decoded.entry.preamble_spans, true, &projection);
    const rows = try terminal.wrapStyledProjected(std.testing.allocator, text.written(), 5, lines.items);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows[0].left);
    try std.testing.expectEqual(@as(usize, 2), rows[1].left);
    try std.testing.expect(rows[1].carry.bold);
    try std.testing.expectEqual(@as(usize, 0), rows[2].bytes.len);
    try std.testing.expect(std.mem.startsWith(u8, rows[3].bytes, "z"));
    try std.testing.expectEqual(@as(usize, 1), terminal.cellWidth(rows[3].bytes));
    try std.testing.expectEqual(@as(usize, 0), rows[4].bytes.len);
    for (rows) |row| {
        const at = @intFromPtr(row.bytes.ptr) - @intFromPtr(text.written().ptr);
        try std.testing.expect(at <= text.written().len);
        try std.testing.expect(terminal.cellWidth(row.bytes) + row.left + row.right <= 5);
    }
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    try spansText(&plain.writer, decoded.entry.preamble_spans, false);
    try std.testing.expectEqualStrings("  abcdef\n\nz\n", plain.written());
}

test "Poem raw line feeds reset depth and explicit RTL margins ignore child direction" {
    terminal.initLocale();
    const raw = [_]model.Span{.{ .text = "first\nnext", .classes = "wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-rtl", .direction = "ltr" }};
    var cursor: SpanCursor = .{ .spans = &raw };
    const first = cursor.next().?;
    const next = cursor.next().?;
    try std.testing.expect(first.info.depth == 2 and first.info.rtl and first.ends_line);
    try std.testing.expect(next.info.depth == 0 and next.info.rtl and !next.ends_line);

    const spans = [_]model.Span{
        .{ .text = "a\nb", .classes = "wikidict-poem wikidict-poem-indent-2" },
        .{ .kind = .line_break, .classes = "wikidict-poem" },
        .{ .text = "c", .direction = "ltr", .classes = "wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-rtl" },
        .{ .kind = .line_break, .classes = "wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-rtl" },
        .{ .text = "ordinary" },
    };
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var projection: PoemProjection = .{ .frame = &text, .allocator = std.testing.allocator, .lines = &lines };
    try spansTextProjected(&text.writer, &spans, false, &projection);
    try std.testing.expectEqualStrings("a\nb\nc\nordinary", text.written());
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].left);
    try std.testing.expectEqual(@as(usize, 0), lines.items[1].left);
    try std.testing.expectEqual(@as(usize, 0), lines.items[2].left);
    try std.testing.expectEqual(@as(usize, 2), lines.items[2].right);
    const rows = try terminal.wrapStyledProjected(std.testing.allocator, text.written(), 5, lines.items);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 0), rows[3].left);
    try std.testing.expectEqual(@as(usize, 0), rows[3].right);
}

test "Poem wrapping keeps ordinary list and definition leads with verse and valid section offsets" {
    terminal.initLocale();
    const spans = [_]model.Span{.{ .text = "abcdef", .classes = "wikidict-poem wikidict-poem-indent-2" }};
    const blocks = [_]model.Block{
        .{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &spans },
        .{ .kind = .definition, .number = "1", .spans = &spans },
        .{ .kind = .example, .spans = &spans },
    };
    const sections = [_]model.Section{.{ .level = 3, .title = "Verse", .blocks = &blocks }};
    const entry: model.Entry = .{ .title = "verse", .kind = .citations, .sections = &sections };
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var projection: PoemProjection = .{ .frame = &text, .allocator = std.testing.allocator, .lines = &lines };
    const selected = try entryTextFoldedProjected(&text, entry, false, .{ .details = true }, &.{}, 0, &projection);
    try std.testing.expect(std.mem.startsWith(u8, text.written()[selected..], "> Verse"));
    const rows = try terminal.wrapStyledProjected(std.testing.allocator, text.written(), 8, lines.items);
    defer std.testing.allocator.free(rows);
    var list = false;
    var definition = false;
    var example = false;
    for (rows) |row| {
        const offset = @intFromPtr(row.bytes.ptr) - @intFromPtr(text.written().ptr);
        try std.testing.expect(offset <= text.written().len);
        if (std.mem.indexOf(u8, row.bytes, "•")) |_| {
            list = true;
            try std.testing.expect(std.mem.indexOf(u8, row.bytes, "ab") != null);
        }
        if (std.mem.startsWith(u8, row.bytes, "1.")) {
            definition = true;
            try std.testing.expect(std.mem.indexOf(u8, row.bytes, "ab") != null);
        }
        if (std.mem.indexOf(u8, row.bytes, "│")) |_| {
            example = true;
            try std.testing.expect(std.mem.indexOf(u8, row.bytes, "ab") != null);
        }
    }
    try std.testing.expect(list and definition and example);
}

test "Poem ordinary boundary break retains ending indentation and resets following text" {
    terminal.initLocale();
    const spans = [_]model.Span{
        .{ .text = "verse", .classes = "wikidict-poem wikidict-poem-indent-2" },
        .{ .kind = .line_break },
        .{ .text = "ordinary" },
    };
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    try spansText(&plain.writer, &spans, false);
    try std.testing.expectEqualStrings("  verse\nordinary", plain.written());
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var projection: PoemProjection = .{ .frame = &text, .allocator = std.testing.allocator, .lines = &lines };
    try spansTextProjected(&text.writer, &spans, false, &projection);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].left);
    const rows = try terminal.wrapStyledProjected(std.testing.allocator, text.written(), 7, lines.items);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows[0].left);
    try std.testing.expectEqualStrings("verse", rows[0].bytes);
    try std.testing.expectEqual(@as(usize, 0), rows[1].left);
}

test "rich heading companion matcher preserves exact title level Unicode and trails" {
    const linked = [_]model.Span{.{ .kind = .link, .text = " \t\xc2\xa0词", .trail = "s\r\n", .target = "SpaceTarget" }};
    const good = [_]model.Block{.{ .kind = .heading, .depth = 0, .level = 3, .spans = &linked }};
    var section: model.Section = .{ .level = 3, .title = "词s", .blocks = &good };
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    section.level = 2;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    section.level = 3;
    section.title = "词S";
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    section.title = "词s";
    const wide = [_]model.Span{.{ .kind = .external_link, .text = "\xe2\x80\x83词s\xe2\x80\x83", .target = "https://example.test/" }};
    const wide_blocks = [_]model.Block{.{ .kind = .heading, .depth = 0, .level = 3, .spans = &wide }};
    section.blocks = &wide_blocks;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    section.title = "\xe2\x80\x83词s\xe2\x80\x83";
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    const break_spans = [_]model.Span{ .{ .kind = .link, .text = "French", .target = "BreakTarget" }, .{ .kind = .line_break, .text = "ignored" } };
    const break_blocks = [_]model.Block{.{ .kind = .heading, .depth = 0, .level = 3, .spans = &break_spans }};
    section = .{ .level = 3, .title = "French", .blocks = &break_blocks };
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    var bad_break = break_spans;
    bad_break[1].trail = "hidden";
    const bad_blocks = [_]model.Block{.{ .kind = .heading, .depth = 0, .level = 3, .spans = &bad_break }};
    section.blocks = &bad_blocks;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    const later = [_]model.Block{ .{ .kind = .paragraph }, good[0] };
    section = .{ .level = 3, .title = "词s", .blocks = &later };
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    const plain = [_]model.Span{.{ .text = "词s" }};
    const no_link = [_]model.Block{.{ .kind = .heading, .depth = 0, .level = 3, .spans = &plain }};
    section.blocks = &no_link;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    const trailing = [_]model.Span{.{ .kind = .link, .trail = "词s", .target = "TrailTarget" }};
    const trailing_blocks = [_]model.Block{.{ .kind = .heading, .depth = 0, .level = 3, .spans = &trailing }};
    section = .{ .level = 3, .title = "词s", .blocks = &trailing_blocks };
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    var wrong_depth = good;
    wrong_depth[0].depth = 3;
    wrong_depth[0].level = 0;
    section.blocks = &wrong_depth;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
}

test "detailed and folded rich headings render once without losing owner links or bodies" {
    const rich = [_]model.Span{.{ .kind = .link, .text = "English", .target = "EnglishTarget" }};
    const body = [_]model.Span{.{ .text = "Retained definition" }};
    const blocks = [_]model.Block{ .{ .kind = .heading, .depth = 0, .level = 2, .spans = &rich }, .{ .kind = .definition, .spans = &body } };
    const sections = [_]model.Section{.{ .level = 2, .title = "English", .blocks = &blocks }};
    const entry: model.Entry = .{ .title = "cat", .kind = .language, .language = "English", .sections = &sections };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, true);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\x1b[36mEnglish"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Retained definition"));
    try std.testing.expectEqualStrings("English", entry.sections[0].title);
    try std.testing.expectEqual(@as(u8, 2), entry.sections[0].level);
    for ([_]bool{ false, true }) |closed| {
        out.clearRetainingCapacity();
        const toggles: []const usize = if (closed) &.{0} else &.{};
        _ = try entryTextFolded(&out, entry, true, .{ .details = true }, toggles, 0);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\x1b[36mEnglish"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Retained definition"));
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "> ") != null);
    }
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "English\n1. Retained definition") != null);
}

test "organized rich homonyms preserve each target heading and shifted sense indices" {
    const heading_a = [_]model.Span{.{ .kind = .link, .text = "Noun", .target = "NounTargetA" }};
    const heading_b = [_]model.Span{.{ .kind = .link, .text = "Noun", .target = "NounTargetB" }};
    const definition_a = [_]model.Span{.{ .text = "first definition" }};
    const definition_b = [_]model.Span{.{ .text = "second definition" }};
    const example_a = [_]model.Span{.{ .text = "first example" }};
    const example_b = [_]model.Span{.{ .text = "second example" }};
    const blocks_a = [_]model.Block{ .{ .kind = .heading, .depth = 0, .level = 3, .spans = &heading_a }, .{ .kind = .definition, .spans = &definition_a }, .{ .kind = .example, .spans = &example_a } };
    const blocks_b = [_]model.Block{ .{ .kind = .heading, .depth = 0, .level = 3, .spans = &heading_b }, .{ .kind = .definition, .spans = &definition_b }, .{ .kind = .example, .spans = &example_b } };
    const sections = [_]model.Section{ .{ .level = 3, .title = "Noun", .blocks = &blocks_a }, .{ .level = 3, .title = "Noun", .blocks = &blocks_b } };
    const senses = [_]model.Sense{.{ .block = 1, .examples = &.{2} }};
    const lexemes = [_]model.Lexeme{ .{ .language = "English", .kind = "Noun", .section = 0, .introduction = &.{0}, .definitions = &senses }, .{ .language = "English", .kind = "Noun", .section = 1, .introduction = &.{0}, .definitions = &senses } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]usize{ 1, 2 }) |parts| {
        const entry: model.Entry = .{ .title = "cat", .kind = .language, .language = "English", .sections = sections[0..parts], .organization = .{ .lexemes = lexemes[0..parts] } };
        out.clearRetainingCapacity();
        try entryText(&out.writer, entry, true);
        try std.testing.expectEqual(parts, std.mem.count(u8, out.written(), "Noun"));
        try std.testing.expectEqual(parts, std.mem.count(u8, out.written(), "\x1b[36mNoun"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "first definition"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "first example"));
        if (parts == 2) {
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "second definition"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "second example"));
        }
        try std.testing.expectEqual(@as(usize, 1), entry.organization.lexemes[0].definitions[0].block);
        try std.testing.expectEqual(@as(usize, 2), entry.organization.lexemes[0].definitions[0].examples[0]);
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, false, false);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Noun"));
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "first definition") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "first example") == null);
        out.clearRetainingCapacity();
        try json(&out.writer, .{ .operation = .search, .query = "cat", .kind = .language, .language = "English", .record_count = 1, .total_matches = 1, .entries = &.{entry} });
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "NounTargetA") != null);
        if (parts == 2) try std.testing.expect(std.mem.indexOf(u8, out.written(), "NounTargetB") != null);
    }
}

test "plain organized headings and unmatched first blocks keep existing output" {
    const definition = [_]model.Span{.{ .text = "ordinary definition" }};
    const blocks = [_]model.Block{.{ .kind = .definition, .spans = &definition }};
    const sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
    const senses = [_]model.Sense{.{ .block = 0 }};
    const lexemes = [_]model.Lexeme{.{ .language = "English", .kind = "Noun", .section = 0, .definitions = &senses }};
    const entry: model.Entry = .{ .title = "cat", .kind = .language, .language = "English", .sections = &sections, .organization = .{ .lexemes = &lexemes } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    try std.testing.expectEqualStrings("cat  / English\n\nNoun\n1. ordinary definition\n", out.written());
    const mismatch_heading = [_]model.Span{.{ .kind = .link, .text = "Different", .target = "OtherTarget" }};
    const mismatched_blocks = [_]model.Block{ .{ .kind = .heading, .depth = 0, .level = 3, .spans = &mismatch_heading }, blocks[0] };
    out.clearRetainingCapacity();
    try sectionTextProjected(&out.writer, .{ .level = 3, .title = "Noun", .blocks = &mismatched_blocks }, false, null);
    try std.testing.expectEqualStrings("\nNoun\nDifferent\n1. ordinary definition\n", out.written());
}

test "DPR2 rich heading wire fields preserve level trails targets and indexed body" {
    const codec = @import("blob_encoder").presentation_codec;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const heading = [_]model.Span{.{ .kind = .link, .text = "Noun", .trail = "s", .target = "WireTarget" }};
    const definition = [_]model.Span{.{ .text = "wire definition" }};
    const example = [_]model.Span{.{ .text = "wire example" }};
    const blocks = [_]model.Block{
        .{ .kind = .heading, .depth = 0, .level = 3, .spans = &heading },
        .{ .kind = .definition, .spans = &definition },
        .{ .kind = .example, .spans = &example },
    };
    const sections = [_]model.Section{.{ .level = 3, .title = "Nouns", .blocks = &blocks }};
    const senses = [_]model.Sense{.{ .block = 1, .examples = &.{2} }};
    const lexemes = [_]model.Lexeme{.{ .language = "English", .kind = "Nouns", .section = 0, .introduction = &.{0}, .definitions = &senses }};
    const bytes = try codec.encodeAlloc(a, .{ .entry = model.Entry{ .title = "cat", .kind = .language, .language = "English", .language_code = "en", .sections = &sections, .organization = .{ .lexemes = &lexemes } } });
    const decoded = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    const section = decoded.entry.sections[0];
    try std.testing.expectEqual(@as(u8, 0), section.blocks[0].depth);
    try std.testing.expectEqual(@as(u8, 3), section.blocks[0].level);
    try std.testing.expectEqual(@as(u8, 3), section.level);
    try std.testing.expectEqualStrings("WireTarget", section.blocks[0].spans[0].target);
    try std.testing.expectEqualStrings("s", section.blocks[0].spans[0].trail);
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.organization.lexemes[0].definitions[0].block);
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.organization.lexemes[0].definitions[0].examples[0]);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, decoded.entry, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Nouns"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "wire definition"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "wire example"));
    out.clearRetainingCapacity();
    _ = try entryTextFolded(&out, decoded.entry, false, .{ .details = true }, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Nouns"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "wire definition"));
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, decoded.entry, false, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Nouns"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "wire example") == null);
}
