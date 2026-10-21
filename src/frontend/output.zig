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
    // Optional TUI body width; absent for the existing unbounded CLI.
    table_columns: ?usize = null,
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

// Human ordinary-block display only. Stored spans and JSON retain source bytes.
// A single state crosses style, link-label and trail boundaries; code/Poem are
// explicit literal boundaries, and existing line breaks reset the state.
const OrdinaryDisplayWhitespace = struct {
    space: bool = false,
    fn write(self: *OrdinaryDisplayWhitespace, w: *std.Io.Writer, bytes: []const u8, preserve: bool) !void {
        if (preserve) {
            self.space = false;
            return terminalText(w, bytes);
        }
        var at: usize = 0;
        while (at < bytes.len) {
            if (bytes[at] == ' ' or bytes[at] == '\t') {
                if (!self.space) try w.writeByte(' ');
                self.space = true;
                at += 1;
            } else {
                const start = at;
                while (at < bytes.len and bytes[at] != ' ' and bytes[at] != '\t') : (at += 1) {}
                try terminalText(w, bytes[start..at]);
                self.space = false;
            }
        }
    }
};

// Human text uses one marker per visible script run. Style/link segmentation
// and a link trail do not start a new run; each physical line is independent.
// Existing initial-piece marker eligibility is preserved on raw LF/trail pieces.
// Reference superscripts already carry their own bracket label and stay exempt.
const ScriptDisplayRuns = struct {
    superscript: bool = false,
    subscript: bool = false,
    fn prefix(self: *ScriptDisplayRuns, w: *std.Io.Writer, span: model.Span, initial: bool) !void {
        const superscript = span.superscript and span.role != .reference;
        if (initial and superscript and !self.superscript) try w.writeByte('^');
        if (initial and span.subscript and !self.subscript) try w.writeByte('_');
        self.superscript = superscript;
        self.subscript = span.subscript;
    }
};

fn spanPieceText(w: *std.Io.Writer, piece: SpanPiece, color: bool, whitespace: ?*OrdinaryDisplayWhitespace, scripts: *ScriptDisplayRuns) !void {
    const span = piece.span;
    if (piece.bytes.len == 0) return;
    if (color and span.bold) try w.writeAll("\x1b[1m");
    if (color and span.italic) try w.writeAll("\x1b[3m");
    if (color and span.underline) try w.writeAll("\x1b[4m");
    if (color and span.strike) try w.writeAll("\x1b[9m");
    if (color and (span.small or span.role == .label or span.role == .citation)) try w.writeAll("\x1b[2m");
    if (color and (span.kind == .link or span.kind == .external_link)) try w.writeAll("\x1b[36m");
    try scripts.prefix(w, span, piece.initial);
    if (whitespace) |state| try state.write(w, piece.bytes, span.code or piece.info.marked) else try terminalText(w, piece.bytes);
    if (color) try w.writeAll("\x1b[0m");
}

pub fn spansText(w: *std.Io.Writer, spans: []const model.Span, color: bool) !void {
    return spansTextProjected(w, spans, color, null);
}
fn spansTextProjected(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection) !void {
    return spansTextDisplayProjected(w, spans, color, projection, false);
}
fn spansTextDisplayProjected(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection, ordinary: bool) !void {
    var collapse = ordinary;
    if (collapse) for (spans) |span| {
        if (PoemInfo.parse(span.classes).marked) {
            collapse = false;
            break;
        }
    };
    var whitespace: OrdinaryDisplayWhitespace = .{};
    var scripts: ScriptDisplayRuns = .{};
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
        for (0..count) |_| try spanPieceText(w, cursor.next().?, color, if (collapse) &whitespace else null, &scripts);
        if (projection == null and info.marked and info.rtl) try w.splatByteAll(' ', info.depth);
        if (newline) {
            try w.writeByte('\n');
            whitespace.space = false;
            scripts = .{};
        }
    }
}

// Cell-local line metadata preserves literal spaces at wrap boundaries. It is
// never appended to PoemProjection.lines or serialized presentation data.
fn tableCellRows(a: std.mem.Allocator, text: []const u8, columns: usize) ![]terminal.RenderRow {
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(a);
    try lines.append(a, .{ .offset = 0 });
    for (text, 0..) |byte, i| if (byte == '\n') try lines.append(a, .{ .offset = i + 1 });
    return terminal.wrapStyledProjected(a, text, columns, lines.items);
}
fn tableWrappedLine(w: *std.Io.Writer, line: terminal.RenderRow, width: usize, color: bool) !void {
    if (color) try line.carry.write(w);
    try w.writeAll(line.bytes);
    if (color) try w.writeAll("\x1b[0m");
    try w.splatByteAll(' ', width -| terminal.cellWidth(line.bytes));
}

fn tableText(w: *std.Io.Writer, table: model.Table, color: bool, projection: ?*PoemProjection) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    terminal.initLocale();
    const Placed = struct { row: usize, column: usize, colspan: usize, rowspan: usize, text: []const u8, lines: []const []const u8, wrapped: ?[]terminal.RenderRow = null };
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
            try cells.append(a, .{ .row = r, .column = column, .colspan = colspan, .rowspan = rowspan, .text = owned, .lines = lines.items });
            column += colspan;
        }
    }
    if (table.caption.len != 0) {
        try spansTextProjected(w, table.caption, color, projection);
        try w.writeByte('\n');
    }
    // The terminal body is at least 36 cells at its supported 40-column size.
    // Keep the natural grid byte-for-byte when it fits, and the CLI unbounded.
    if (projection) |display| if (display.table_columns) |requested| {
        const columns = @max(requested, 8);
        var natural: usize = 3 * widths.items.len + 3;
        for (widths.items) |width| natural += width;
        if (natural > columns and widths.items.len != 0) {
            const budget = columns -| (3 * widths.items.len + 3);
            if (budget < 2 * widths.items.len) {
                // A grid cannot give every column one full wide glyph. Stack
                // owned cells with explicit row/column/span identity instead.
                const width = columns - 6;
                for (cells.items) |cell| {
                    try w.print("  Row {d}, column {d}", .{ cell.row + 1, cell.column + 1 });
                    if (cell.colspan != 1 or cell.rowspan != 1) try w.print(" (span {d} x {d})", .{ cell.colspan, cell.rowspan });
                    try w.writeByte('\n');
                    const wrapped = try tableCellRows(a, cell.text, width);
                    for (wrapped) |line| {
                        try w.writeAll("  │ ");
                        try tableWrappedLine(w, line, width, color);
                        try w.writeAll(" │\n");
                    }
                }
                try w.writeByte('\n');
                return;
            }
            const natural_widths = try a.dupe(usize, widths.items);
            const share = budget / widths.items.len;
            var left = budget;
            for (widths.items) |*width| {
                width.* = @min(width.*, share);
                left -= width.*;
            }
            for (widths.items, natural_widths) |*width, original| {
                const extra = @min(left, original - width.*);
                width.* += extra;
                left -= extra;
            }
            for (cells.items) |*cell| {
                var width: usize = 3 * (cell.colspan - 1);
                for (widths.items[cell.column..][0..cell.colspan]) |part| width += part;
                cell.wrapped = try tableCellRows(a, cell.text, width);
            }
        }
    };
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
            height = @max(height, if (cell.wrapped) |wrapped| wrapped.len else cell.lines.len);
        }
        for (0..height) |line_index| {
            try w.writeAll("  │ ");
            var column: usize = 0;
            while (column < widths.items.len) {
                var span: usize = 1;
                var line: []const u8 = "";
                var wrapped_line: ?terminal.RenderRow = null;
                if (active[column]) |index| {
                    const cell = cells.items[index];
                    span = cell.colspan;
                    if (cell.row == r) {
                        if (cell.wrapped) |wrapped| {
                            if (line_index < wrapped.len) wrapped_line = wrapped[line_index];
                        } else if (line_index < cell.lines.len) line = cell.lines[line_index];
                    }
                }
                var width: usize = 3 * (span - 1);
                for (widths.items[column..][0..span]) |part| width += part;
                if (wrapped_line) |value| try tableWrappedLine(w, value, width, color) else {
                    try w.writeAll(line);
                    try w.splatByteAll(' ', width -| terminal.cellWidth(line));
                }
                column += span;
                try w.writeAll(if (column == widths.items.len) " │\n" else " │ ");
            }
        }
    }
    try w.writeByte('\n');
}

fn colorSwatchRgb(block: model.Block) ?[3]u8 {
    if (block.kind != .table or block.table == null) return null;
    const feature = block.feature orelse return null;
    if (!std.mem.eql(u8, feature.kind, "color_swatch") or feature.language.len != 0 or
        !std.mem.eql(u8, feature.tail_kind, "none") or feature.tail.len != 0) return null;
    const data = feature.data;
    if (data.len != 7 or data[0] != '#') return null;
    for (data[1..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    }
    return .{
        std.fmt.parseInt(u8, data[1..3], 16) catch return null,
        std.fmt.parseInt(u8, data[3..5], 16) catch return null,
        std.fmt.parseInt(u8, data[5..7], 16) catch return null,
    };
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
            if (colorSwatchRgb(block)) |rgb| {
                try w.splatByteAll(' ', @as(usize, @min(block.depth, 12)) * 2);
                if (color) try w.print("[\x1b[48;2;{d};{d};{d}m  \x1b[0m] ", .{ rgb[0], rgb[1], rgb[2] });
                try w.print("Color sample {s}\n\n", .{block.feature.?.data});
            } else try tableText(w, table, color, projection);
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
        try spansTextDisplayProjected(w, block.spans, color, projection, block.kind == .paragraph or block.kind == .definition);
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
fn selfLinkHeadingSpan(span: model.Span) bool {
    if (span.kind != .text or span.text.len == 0 or span.target.len != 0) return false;
    var marked = false;
    var selflink = false;
    var tokens = std.mem.tokenizeAny(u8, span.classes, " \t\r\n\x0b\x0c");
    while (tokens.next()) |token| {
        marked = marked or std.mem.eql(u8, token, "mw-selflink");
        selflink = selflink or std.mem.eql(u8, token, "selflink");
    }
    return marked and selflink;
}
fn sectionHeadingCompanion(section: model.Section) ?[]const model.Span {
    if (section.title.len == 0 or section.blocks.len == 0) return null;
    const first = section.blocks[0];
    if (first.kind != .heading or first.level != section.level) return null;
    var navigable = false;
    var explained = false;
    var styled_self = false;
    for (first.spans) |span| {
        explained = explained or span.explanation.len != 0;
        styled_self = styled_self or selfLinkHeadingSpan(span);
        if (span.kind == .line_break and span.trail.len != 0) return null;
        if ((span.kind == .link or span.kind == .external_link) and
            span.target.len != 0 and (span.text.len != 0 or span.trail.len != 0)) navigable = true;
    }
    if (!navigable and !explained and !styled_self) return null;
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

// Observe only span domains that the current output route actually emitted.
// Media metadata still owns file controls; this only avoids repeating a caption.
const VisibleMediaCaptions = struct {
    a: std.mem.Allocator,
    media: []const model.Media,
    seen: []bool,
    owners: std.StringHashMap(usize),
    run: std.ArrayList(u8) = .empty,
    enabled: bool,
    const prefix = "wikidict-media-file-";

    fn init(a: std.mem.Allocator, media: []const model.Media, enabled: bool) !VisibleMediaCaptions {
        const observe = enabled and media.len != 0;
        var result: VisibleMediaCaptions = .{
            .a = a,
            .media = media,
            .seen = try a.alloc(bool, if (observe) media.len else 0),
            .owners = std.StringHashMap(usize).init(a),
            .enabled = observe,
        };
        @memset(result.seen, false);
        if (observe) for (media, 0..) |item, index| {
            // Larger keys cannot occur in the codec's bounded classes string.
            if (item.file.len == 0 or item.file.len > (32 * 1024 * 1024 - prefix.len) / 2) continue;
            const key = try a.alloc(u8, prefix.len + item.file.len * 2);
            @memcpy(key[0..prefix.len], prefix);
            const hex = "0123456789abcdef";
            for (item.file, 0..) |byte, n| {
                key[prefix.len + 2 * n] = hex[byte >> 4];
                key[prefix.len + 2 * n + 1] = hex[byte & 15];
            }
            try result.owners.put(key, index);
        };
        return result;
    }
    fn owner(self: *const VisibleMediaCaptions, span: model.Span) ?usize {
        var tokens = std.mem.tokenizeAny(u8, span.classes, " \t\r\n\x0b\x0c");
        var marked = false;
        var selected: ?[]const u8 = null;
        var count: usize = 0;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "wikidict-media")) marked = true;
            if (std.mem.startsWith(u8, token, prefix)) {
                count += 1;
                selected = token;
            }
        }
        if (!marked) return null;
        // A present bad, unknown or duplicate owner is authoritative refusal.
        if (count != 0) return if (count == 1) self.owners.get(selected.?) else null;
        if (span.kind != .link and span.kind != .line_break) return null;
        if (!std.ascii.startsWithIgnoreCase(span.target, "File:") and
            !std.ascii.startsWithIgnoreCase(span.target, "Image:")) return null;
        const file = span.target[(std.mem.indexOfScalar(u8, span.target, ':') orelse return null) + 1 ..];
        for (self.media, 0..) |item, index| {
            if (file.len != item.file.len) continue;
            var equal = true;
            for (file, item.file) |left, right| if ((if (left == '_') @as(u8, ' ') else left) !=
                (if (right == '_') @as(u8, ' ') else right))
            {
                equal = false;
                break;
            };
            if (equal) return index;
        }
        return null;
    }
    const Words = struct {
        text: []const u8,
        pos: usize = 0,
        fn whitespace(byte: u8) bool {
            // terminalText escapes CR/VT/FF instead of displaying whitespace.
            return byte == ' ' or byte == '\t' or byte == '\n';
        }
        fn next(self: *Words) ?[]const u8 {
            while (self.pos < self.text.len and whitespace(self.text[self.pos])) self.pos += 1;
            const start = self.pos;
            while (self.pos < self.text.len and !whitespace(self.text[self.pos])) self.pos += 1;
            return if (start == self.pos) null else self.text[start..self.pos];
        }
    };
    fn sameCaption(left: []const u8, right: []const u8) bool {
        var a: Words = .{ .text = left };
        var b: Words = .{ .text = right };
        var nonempty = false;
        while (a.next()) |word| {
            const other = b.next() orelse return false;
            if (!std.mem.eql(u8, word, other)) return false;
            nonempty = true;
        }
        return nonempty and b.next() == null;
    }
    fn finish(self: *VisibleMediaCaptions, index: ?usize) void {
        if (index) |owned| for (self.media, 0..) |item, n| {
            if (std.mem.eql(u8, item.file, self.media[owned].file) and sameCaption(self.run.items, item.caption))
                self.seen[n] = true;
        };
        self.run.clearRetainingCapacity();
    }
    fn observeSpans(self: *VisibleMediaCaptions, spans: []const model.Span) !void {
        if (!self.enabled) return;
        var current: ?usize = null;
        for (spans) |span| {
            const next = self.owner(span);
            // Equal Media.file records share ownership, not their caption text.
            const same = if (current != null and next != null)
                std.mem.eql(u8, self.media[current.?].file, self.media[next.?].file)
            else
                false;
            if (!same) self.finish(current);
            current = next;
            if (next != null) {
                if (span.kind == .line_break) try self.run.append(self.a, '\n') else try self.run.appendSlice(self.a, span.text);
                // SpanCursor emits the decoded trail after a break as well.
                try self.run.appendSlice(self.a, span.trail);
            }
        }
        self.finish(current);
    }
    fn observeBlocks(self: *VisibleMediaCaptions, blocks: []const model.Block) !void {
        if (!self.enabled) return;
        for (blocks) |block| {
            if (block.kind == .blank or block.kind == .rule) continue;
            if (block.table) |table| {
                try self.observeSpans(table.caption);
                for (table.rows) |row| for (row.cells) |cell| try self.observeSpans(cell.spans);
            } else try self.observeSpans(block.spans);
        }
    }
    fn emitSpans(self: *VisibleMediaCaptions, w: *std.Io.Writer, values: []const model.Span, color: bool, projection: ?*PoemProjection) !void {
        try spansTextProjected(w, values, color, projection);
        try self.observeSpans(values);
    }
    fn emitBlocks(self: *VisibleMediaCaptions, w: *std.Io.Writer, values: []const model.Block, color: bool, projection: ?*PoemProjection) !void {
        try blocksTextProjected(w, values, color, projection);
        try self.observeBlocks(values);
    }
    fn emitSection(self: *VisibleMediaCaptions, w: *std.Io.Writer, value: model.Section, color: bool, projection: ?*PoemProjection) !void {
        try sectionTextProjected(w, value, color, projection);
        // The companion, if any, was emitted as the section label instead.
        try self.observeBlocks(value.blocks);
    }
    fn emitLabel(self: *VisibleMediaCaptions, w: *std.Io.Writer, value: model.Section, color: bool, projection: ?*PoemProjection) !void {
        try sectionLabelProjected(w, value, color, projection);
        if (sectionHeadingCompanion(value)) |values| try self.observeSpans(values);
    }
};

pub fn entryText(w: *std.Io.Writer, entry: model.Entry, color: bool) !void {
    return entryTextWithDetails(w, entry, color, true);
}

pub fn entryTextWithDetails(w: *std.Io.Writer, entry: model.Entry, color: bool, details: bool) !void {
    return entryTextWithDetailsProjected(w, entry, color, details, null);
}
pub fn entryTextWithDetailsProjected(w: *std.Io.Writer, entry: model.Entry, color: bool, details: bool, projection: ?*PoemProjection) !void {
    var caption_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer caption_arena.deinit();
    var captions = try VisibleMediaCaptions.init(caption_arena.allocator(), entry.media, details);
    if (color) try w.writeAll("\x1b[1;36m");
    if (entry.display_title.len != 0)
        try captions.emitSpans(w, entry.display_title, color, projection)
    else
        try terminalText(w, entry.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if ((details or entry.kind == .alias) and entry.preamble_spans.len != 0) {
        try captions.emitSpans(w, entry.preamble_spans, color, projection);
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
                    try captions.emitBlocks(w, &.{block}, color, projection);
                };
                continue;
            }
            if (std.mem.eql(u8, section.title, entry.language orelse "") and sectionHeadingCompanion(section) == null)
                try captions.emitBlocks(w, section.blocks, color, projection)
            else
                try captions.emitSection(w, section, color, projection);
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
                    if (companion) |spans| try captions.emitSpans(w, spans, color, projection) else try terminalText(w, part.kind);
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
                    try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                };
                for (part.definitions) |sense| {
                    try captions.emitBlocks(w, section.blocks[sense.block..][0..1], color, projection);
                    if (details) for (sense.examples) |i| try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                    if (details) {
                        for (sense.notes) |i| try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                        for (sense.quotations) |i| try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                    }
                }
                if (details) {
                    for (part.other_blocks) |i| {
                        if (rendered_companion and i == 0) continue;
                        try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                    }
                    for (part.related_sections) |i| try captions.emitSection(w, entry.sections[i], color, projection);
                }
            }
        }
        if (details) for (organization.other_sections) |i| try captions.emitSection(w, entry.sections[i], color, projection);
    }
    if (details) try entryMetadataProjected(w, entry, color, projection, &captions);
}

// The details view visits compiled span lists without changing body text or links.
fn visitEntrySpanLists(entry: model.Entry, visitor: anytype) !bool {
    if (try visitor.spans(entry.display_title)) return true;
    if (try visitor.spans(entry.preamble_spans)) return true;
    for (entry.sections) |section| for (section.blocks) |block| {
        if (try visitor.spans(block.spans)) return true;
        if (block.table) |table| {
            if (try visitor.spans(table.caption)) return true;
            for (table.rows) |row| for (row.cells) |cell| {
                if (try visitor.spans(cell.spans)) return true;
            };
        }
    };
    for (entry.references) |reference| if (try visitor.spans(reference.spans)) return true;
    return false;
}

const Abbreviation = struct { label: []const u8, explanation: []const u8 };
const AbbreviationContext = struct {
    pub fn hash(_: @This(), item: Abbreviation) u64 {
        return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, item.label), item.explanation);
    }
    pub fn eql(_: @This(), lhs: Abbreviation, rhs: Abbreviation) bool {
        return std.mem.eql(u8, lhs.label, rhs.label) and std.mem.eql(u8, lhs.explanation, rhs.explanation);
    }
};
const Abbreviations = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Abbreviation) = .empty,
    seen: std.HashMapUnmanaged(Abbreviation, void, AbbreviationContext, 80) = .empty,

    fn init(allocator: std.mem.Allocator, entry: model.Entry) !Abbreviations {
        var result: Abbreviations = .{ .allocator = allocator };
        errdefer result.deinit();
        _ = try visitEntrySpanLists(entry, &result);
        return result;
    }
    fn deinit(self: *Abbreviations) void {
        self.seen.deinit(self.allocator);
        for (self.items.items) |item| self.allocator.free(item.label);
        self.items.deinit(self.allocator);
    }
    fn add(self: *Abbreviations, text: []const u8, explanation: []const u8) !void {
        const label = std.mem.trim(u8, text, " \t\r\n");
        if (label.len == 0 or self.seen.contains(.{ .label = label, .explanation = explanation })) return;
        try self.seen.ensureUnusedCapacity(self.allocator, 1);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const item: Abbreviation = .{ .label = owned_label, .explanation = explanation };
        try self.items.append(self.allocator, item);
        self.seen.putAssumeCapacityNoClobber(item, {});
    }
    fn spans(self: *Abbreviations, values: []const model.Span) !bool {
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(self.allocator);
        var at: usize = 0;
        while (at < values.len) {
            const explanation = values[at].explanation;
            if (explanation.len == 0) {
                at += 1;
                continue;
            }
            label.clearRetainingCapacity();
            // Formatting may split an abbreviation into adjacent spans. A new
            // span list is a structural boundary, even if its explanation matches.
            while (at < values.len and std.mem.eql(u8, values[at].explanation, explanation)) : (at += 1) {
                const value = values[at];
                if (value.kind == .line_break) try label.append(self.allocator, '\n') else try label.appendSlice(self.allocator, value.text);
                try label.appendSlice(self.allocator, value.trail);
            }
            try self.add(label.items, explanation);
        }
        return false;
    }
    fn write(self: *const Abbreviations, w: *std.Io.Writer) !void {
        if (self.items.items.len == 0) return;
        try w.writeAll("\nAbbreviations\n");
        for (self.items.items) |item| {
            try terminalText(w, item.label);
            try w.writeAll(": ");
            try terminalText(w, item.explanation);
            try w.writeByte('\n');
        }
    }
};

fn entryHasAbbreviations(entry: model.Entry) bool {
    const Presence = struct {
        fn spans(_: *@This(), values: []const model.Span) error{}!bool {
            for (values) |value| {
                if (value.explanation.len != 0 and
                    ((value.kind != .line_break and std.mem.trim(u8, value.text, " \t\r\n").len != 0) or
                        std.mem.trim(u8, value.trail, " \t\r\n").len != 0)) return true;
            }
            return false;
        }
    };
    var presence: Presence = .{};
    return visitEntrySpanLists(entry, &presence) catch unreachable;
}

fn entryMetadataProjected(w: *std.Io.Writer, entry: model.Entry, color: bool, projection: ?*PoemProjection, captions: *VisibleMediaCaptions) !void {
    // These references are emitted by this same details route below.
    for (entry.references) |ref| try captions.observeSpans(ref.spans);
    if (entry.media.len != 0) {
        try w.writeAll("\nMedia\n");
        for (entry.media, 0..) |media, media_index| {
            try w.print("[{s}] ", .{@tagName(media.kind)});
            try terminalText(w, media.file);
            if (media.caption.len != 0 and !captions.seen[media_index]) {
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
    var abbreviations = try Abbreviations.init(std.heap.smp_allocator, entry);
    defer abbreviations.deinit();
    try abbreviations.write(w);
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
    var caption_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer caption_arena.deinit();
    var captions = try VisibleMediaCaptions.init(caption_arena.allocator(), entry.media, preferences.details);
    const w = &frame.writer;
    var selected_offset: usize = 0;
    if (entry.display_title.len != 0) try captions.emitSpans(w, entry.display_title, color, projection) else try terminalText(w, entry.title);
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (entry.preamble_spans.len != 0) {
        try captions.emitSpans(w, entry.preamble_spans, color, projection);
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
        try captions.emitLabel(w, section, color, projection);
        if (closed) try w.writeAll(if (meaning) "  [+ notes]" else "  [+]");
        if (color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
        const first: usize = if (sectionHeadingCompanion(section) != null) 1 else 0;
        for (section.blocks[first..]) |block| if (!closed or (meaning and block.kind == .definition)) try captions.emitBlocks(w, &.{block}, color, projection);
    }
    if (preferences.details) {
        try entryMetadataProjected(w, entry, color, projection, &captions);
    } else if (entryHasAbbreviations(entry)) {
        try w.writeAll(if (entry.media.len != 0 or entry.references.len != 0) "\n  d: abbreviations, media and references\n" else "\n  d: abbreviations\n");
    } else if (entry.media.len != 0 or entry.references.len != 0) try w.writeAll("\n  d: media and references\n");
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

test "self link heading companions require exact semantic markers and labels" {
    var spans = [_]model.Span{.{ .text = "Nouns", .bold = true, .italic = true, .classes = "label\tmw-selflink\nselflink" }};
    var blocks = [_]model.Block{.{ .kind = .heading, .level = 3, .spans = &spans }};
    var section: model.Section = .{ .level = 3, .title = "Nouns", .blocks = &blocks };
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    // Explicit font-weight:normal can override the self link's default bold.
    spans[0].bold = false;
    spans[0].italic = false;
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    for ([_][]const u8{ "", "mw-selflink", "selflink", "xmw-selflink selflink", "mw-selflink selflink-x" }) |classes| {
        spans[0].classes = classes;
        try std.testing.expect(sectionHeadingCompanion(section) == null);
    }
    spans[0].classes = "selflink mw-selflink";
    spans[0].target = "Page";
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    spans[0].target = "";
    spans[0].kind = .line_break;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    spans[0].kind = .text;
    section.title = "Noun";
    try std.testing.expect(sectionHeadingCompanion(section) == null);
    section.title = "Nouns";
    blocks[0].level = 2;
    try std.testing.expect(sectionHeadingCompanion(section) == null);
}

test "self link headings render once in plain styled detailed and folded output" {
    var heading = [_]model.Span{.{ .text = "Nouns", .bold = true, .italic = true, .classes = "mw-selflink selflink" }};
    const definition = [_]model.Span{ .{ .text = "Retained definition " }, .{ .kind = .link, .text = "Related", .target = "Other" } };
    const blocks = [_]model.Block{ .{ .kind = .heading, .level = 3, .spans = &heading }, .{ .kind = .definition, .spans = &definition } };
    const sections = [_]model.Section{.{ .level = 3, .title = "Nouns", .blocks = &blocks }};
    const senses = [_]model.Sense{.{ .block = 1 }};
    const lexemes = [_]model.Lexeme{.{ .language = "English", .kind = "Nouns", .section = 0, .introduction = &.{0}, .definitions = &senses }};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |organized| {
        const entry: model.Entry = .{ .title = "Page", .kind = .language, .language = "English", .sections = &sections, .organization = .{ .lexemes = if (organized) &lexemes else &.{} } };
        for ([_]bool{ false, true }) |color| {
            for (0..4) |mode| {
                out.clearRetainingCapacity();
                switch (mode) {
                    0 => try entryText(&out.writer, entry, color),
                    1 => try entryTextWithDetails(&out.writer, entry, color, false),
                    2, 3 => {
                        const toggles: []const usize = if (mode == 3) &.{0} else &.{};
                        _ = try entryTextFolded(&out, entry, color, .{ .details = true }, toggles, 0);
                    },
                    else => unreachable,
                }
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Nouns"));
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Retained definition"));
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Related"));
                if (color) {
                    // The existing short display uses a plain lexical label.
                    try std.testing.expectEqual(@as(usize, if (mode == 1) 0 else 1), std.mem.count(u8, out.written(), "\x1b[1m\x1b[3mNouns"));
                    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\x1b[36mRelated"));
                    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\x1b[36m"));
                }
            }
        }
        heading[0].bold = false;
        heading[0].italic = false;
        out.clearRetainingCapacity();
        try entryText(&out.writer, entry, true);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Nouns"));
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3mNouns") == null);
        heading[0].bold = true;
        heading[0].italic = true;
    }
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

test "visible media captions deduplicate metadata without replacing authored actions through DPR2" {
    const tone = "wikidict-media wikidict-media-file-546f6e652e6f6767";
    const mixed = [_]model.Span{
        .{ .kind = .link, .text = "A ", .target = "File:Tone.ogg", .classes = tone },
        .{ .kind = .link, .text = "domestic cat", .target = "cat", .classes = tone, .bold = true },
        .{ .kind = .link, .text = " and ", .target = "File:Tone.ogg", .classes = tone },
        .{ .kind = .external_link, .text = "external", .target = "https://example.org", .classes = tone },
        .{ .kind = .link, .text = ".", .target = "File:Tone.ogg", .classes = tone },
    };
    const authored = [_]model.Span{
        .{ .kind = .link, .text = "domestic", .trail = " cat", .target = "cat", .classes = tone, .bold = true },
    };
    const codec = @import("blob_encoder").presentation_codec;
    for ([_][]const model.Span{ &mixed, &authored }, [_][]const u8{ "A domestic cat and external.", "domestic cat" }) |values, caption| {
        const media = [_]model.Media{.{ .file = "Tone.ogg", .kind = .audio, .caption = caption }};
        const entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .language_code = "en", .preamble_spans = values, .media = &media };
        const bytes = try codec.encodeAlloc(std.testing.allocator, .{ .entry = entry });
        defer std.testing.allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const decoded = try codec.decodeAlloc(arena.allocator(), bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        const linked_index: usize = if (values.len == 1) 0 else 1;
        try std.testing.expectEqualStrings("cat", decoded.entry.preamble_spans[linked_index].target);
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try entryTextWithDetails(&out.writer, decoded.entry, false, true);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), caption));
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg\n") != null);
        out.clearRetainingCapacity();
        _ = try entryTextFolded(&out, decoded.entry, false, .{ .details = true }, &.{}, 0);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), caption));
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg\n") != null);
        // Output is a read-only projection: lexical targets and styles survive.
        try std.testing.expectEqualStrings("cat", decoded.entry.preamble_spans[linked_index].target);
        try std.testing.expect(decoded.entry.preamble_spans[linked_index].bold);
    }
}

test "caption deduplication follows actual folded and organized visibility" {
    const owner = "wikidict-media wikidict-media-file-546f6e652e6f6767";
    const caption = [_]model.Span{.{ .kind = .link, .text = "visible caption", .target = "cat", .classes = owner }};
    const meaning = [_]model.Span{.{ .text = "meaning" }};
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &caption },
        .{ .kind = .definition, .depth = 1, .spans = &meaning },
    };
    const sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
    const media = [_]model.Media{.{ .file = "Tone.ogg", .kind = .audio, .caption = "visible caption" }};
    var entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .sections = &sections, .media = &media };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // Explicitly folded body: the fallback caption is its sole visible copy.
    _ = try entryTextFolded(&out, entry, false, .{ .details = true }, &.{0}, 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "visible caption"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg — visible caption") != null);
    out.clearRetainingCapacity();
    _ = try entryTextFolded(&out, entry, false, .{ .details = true }, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "visible caption"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg\n") != null);
    // Layout indices stay authoritative: an unselected paragraph cannot dedup.
    const senses = [_]model.Sense{.{ .block = 1 }};
    const hidden = [_]model.Lexeme{.{ .kind = "Noun", .section = 0, .definitions = &senses }};
    entry.organization = .{ .lexemes = &hidden };
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg — visible caption") != null);
    const shown = [_]model.Lexeme{.{ .kind = "Noun", .section = 0, .introduction = &.{0}, .definitions = &senses }};
    entry.organization = .{ .lexemes = &shown };
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, true);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "visible caption"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg\n") != null);
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "visible caption") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Media") == null);
}

test "media caption owners reject forged ambiguous partial and cross-file matches" {
    const tone = "wikidict-media wikidict-media-file-546f6e652e6f6767";
    const token = "wikidict-media-file-546f6e652e6f6767";
    const media = [_]model.Media{
        .{ .file = "Tone.ogg", .kind = .audio, .caption = "same caption" },
        .{ .file = "Other.ogg", .kind = .audio, .caption = "same caption" },
    };
    var values = [_]model.Span{.{ .kind = .link, .text = "same caption", .target = "cat", .classes = tone }};
    var entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .preamble_spans = &values, .media = &media };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "same caption"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Other.ogg — same caption") != null);
    // A legacy caption is identified only by the unmarked File/Image action.
    values[0].classes = "wikidict-media";
    values[0].target = "Image:Tone.ogg";
    out.clearRetainingCapacity();
    try entryText(&out.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg\n") != null);
    for ([_][]const u8{
        "wikidict-media wikidict-media-file-",
        "wikidict-media wikidict-media-file-0",
        "wikidict-media wikidict-media-file-ff",
        "wikidict-media wikidict-media-file-546F6E652E6F6767",
        "wikidict-media wikidict-media-file-556e6b6e6f776e2e6f6767",
        "wikidict-media " ++ token ++ " " ++ token,
        "wikidict-media " ++ token ++ " wikidict-media-file-4f746865722e6f6767",
        "not-wikidict-media " ++ token,
    }) |bad| {
        values[0].classes = bad;
        out.clearRetainingCapacity();
        try entryText(&out.writer, entry, false);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg — same caption") != null);
    }
    const partial = [_]model.Span{
        .{ .kind = .link, .text = "same ", .target = "cat", .classes = tone },
        .{ .kind = .line_break },
        .{ .kind = .link, .text = "caption", .target = "cat", .classes = tone },
    };
    entry.preamble_spans = &partial;
    out.clearRetainingCapacity();
    try entryText(&out.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Tone.ogg — same caption") != null);
    // DPR2 permits break trails and escaped controls. Compare the bytes which
    // this terminal consumer actually displays, not generic HTML whitespace.
    const break_trail = [_]model.Span{
        .{ .kind = .link, .text = "a", .target = "cat", .classes = tone },
        .{ .kind = .line_break, .trail = "EXTRA", .classes = tone },
        .{ .kind = .link, .text = "b", .target = "cat", .classes = tone },
    };
    const ordinary = [_]model.Span{.{ .kind = .link, .text = "a b", .target = "cat", .classes = tone }};
    const cases = [_]struct { values: []const model.Span, caption: []const u8, metadata: []const u8 }{
        .{ .values = &break_trail, .caption = "a b", .metadata = "[audio] Tone.ogg — a b\n" },
        .{ .values = &break_trail, .caption = "a EXTRAb", .metadata = "[audio] Tone.ogg\n" },
        .{ .values = &ordinary, .caption = "a\rb", .metadata = "[audio] Tone.ogg — a\\u{d}b\n" },
        .{ .values = &ordinary, .caption = "a\x0bb", .metadata = "[audio] Tone.ogg — a\\u{b}b\n" },
        .{ .values = &ordinary, .caption = "a\x0cb", .metadata = "[audio] Tone.ogg — a\\u{c}b\n" },
    };
    const codec = @import("blob_encoder").presentation_codec;
    for (cases) |case| {
        const wire_media = [_]model.Media{.{ .kind = .audio, .file = "Tone.ogg", .caption = case.caption }};
        const wire_entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .language_code = "en", .preamble_spans = case.values, .media = &wire_media };
        const bytes = try codec.encodeAlloc(std.testing.allocator, .{ .entry = wire_entry });
        defer std.testing.allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const decoded = try codec.decodeAlloc(arena.allocator(), bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        out.clearRetainingCapacity();
        try entryText(&out.writer, decoded.entry, false);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), case.metadata) != null);
        if (case.values.len == 3) {
            try std.testing.expectEqualStrings("EXTRA", decoded.entry.preamble_spans[1].trail);
            try std.testing.expect(std.mem.indexOf(u8, out.written(), "a\nEXTRAb\n") != null);
        } else try std.testing.expect(std.mem.indexOf(u8, out.written(), "a b\n") != null);
    }
}

test "caption observation keeps table reference and projected span domains local" {
    const unicode_owner = "wikidict-media wikidict-media-file-c38963686f20f09f948a2e6f6767";
    const spans = [_]model.Span{.{ .kind = .link, .text = "unicode caption", .target = "cat", .classes = unicode_owner }};
    const cells = [_]@import("blob_encoder").presentation_types.Cell{.{ .spans = &spans }};
    const rows = [_]@import("blob_encoder").presentation_types.Row{.{ .cells = &cells }};
    const blocks = [_]model.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]model.Section{.{ .level = 3, .title = "Table", .blocks = &blocks }};
    const media = [_]model.Media{.{ .file = "Écho 🔊.ogg", .kind = .audio, .caption = "unicode caption" }};
    var entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .sections = &sections, .media = &media };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "unicode caption"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Écho 🔊.ogg\n") != null);
    const references = [_]model.Reference{.{ .number = 1, .group_number = 1, .spans = &spans }};
    entry.sections = &.{};
    entry.references = &references;
    out.clearRetainingCapacity();
    try entryText(&out.writer, entry, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "unicode caption"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Écho 🔊.ogg\n") != null);

    const poem = [_]model.Span{
        .{ .kind = .link, .text = "unicode", .target = "cat", .classes = unicode_owner ++ " wikidict-poem wikidict-poem-indent-2" },
        .{ .kind = .line_break, .classes = unicode_owner ++ " wikidict-poem" },
        .{ .kind = .external_link, .text = "caption", .target = "https://example.org", .classes = unicode_owner ++ " wikidict-poem" },
    };
    entry.references = &.{};
    entry.preamble_spans = &poem;
    out.clearRetainingCapacity();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var projection: PoemProjection = .{ .frame = &out, .allocator = std.testing.allocator, .lines = &lines };
    _ = try entryTextFoldedProjected(&out, entry, false, .{ .details = true }, &.{}, 0, &projection);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "unicode\ncaption") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[audio] Écho 🔊.ogg\n") != null);
    try std.testing.expect(lines.items.len >= 2);
}

test "abbreviation details preserve compact styled labels and independent navigation" {
    const values = [_]model.Span{
        .{ .kind = .link, .text = "f", .target = "Appendix:Glossary#feminine", .explanation = "feminine gender" },
        .{ .text = " " },
        .{ .text = "ab", .explanation = "abbreviation" },
        .{ .text = "br", .italic = true, .explanation = "abbreviation" },
        .{ .text = " " },
        .{ .text = "f", .explanation = "a different meaning" },
    };
    const entry: model.Entry = .{ .title = "entry", .kind = .citations, .preamble_spans = &values };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try spansText(&out.writer, &values, false);
    try std.testing.expectEqualStrings("f abbr f", out.written());
    out.clearRetainingCapacity();
    try entryText(&out.writer, entry, false);
    try std.testing.expectEqualStrings("entry  / citations\nf abbr f\n\nAbbreviations\nf: feminine gender\nabbr: abbreviation\nf: a different meaning\n", out.written());
    out.clearRetainingCapacity();
    _ = try entryTextFolded(&out, entry, false, .{ .details = false }, &.{}, 0);
    try std.testing.expectEqualStrings("entry  / citations\nf abbr f\n\n  d: abbreviations\n", out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "feminine gender") == null);
    out.clearRetainingCapacity();
    _ = try entryTextFolded(&out, entry, false, .{ .details = true }, &.{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "abbr: abbreviation\n") != null);
    out.clearRetainingCapacity();
    try json(&out.writer, .{ .operation = .search, .query = "entry", .kind = .citations, .language = null, .record_count = 1, .total_matches = 1, .entries = &.{entry} });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const first = parsed.value.object.get("entries").?.array.items[0].object.get("preamble_spans").?.array.items[0].object;
    try std.testing.expectEqualStrings("f", first.get("text").?.string);
    try std.testing.expectEqualStrings("feminine gender", first.get("explanation").?.string);
    try std.testing.expectEqualStrings("Appendix:Glossary#feminine", first.get("target").?.string);
}

test "abbreviation details traverse every compiled span container without crossing boundaries" {
    const types = @import("blob_encoder").presentation_types;
    const display = [_]model.Span{.{ .text = "D", .explanation = "display title" }};
    const preamble = [_]model.Span{.{ .text = "P", .explanation = "preamble" }};
    const first = [_]model.Span{.{ .text = "ab", .explanation = "shared explanation" }};
    const second = [_]model.Span{.{ .text = "br", .explanation = "shared explanation" }};
    const caption = [_]model.Span{.{ .text = "C", .explanation = "caption" }};
    const cell = [_]model.Span{.{ .text = "T", .explanation = "table cell" }};
    const reference = [_]model.Span{.{ .text = "R", .explanation = "reference" }};
    const cells = [_]types.Cell{ .{ .spans = &cell }, .{ .spans = &first } };
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &first },
        .{ .kind = .paragraph, .spans = &second },
        .{ .kind = .table, .table = .{ .caption = &caption, .rows = &rows } },
    };
    const sections = [_]model.Section{.{ .level = 2, .title = "Body", .blocks = &blocks }};
    const references = [_]model.Reference{.{ .number = 1, .group_number = 1, .spans = &reference }};
    const entry: model.Entry = .{ .title = "entry", .kind = .citations, .display_title = &display, .preamble_spans = &preamble, .sections = &sections, .references = &references };
    var collected = try Abbreviations.init(std.testing.allocator, entry);
    defer collected.deinit();
    try std.testing.expectEqual(@as(usize, 7), collected.items.items.len);
    const labels = [_][]const u8{ "D", "P", "ab", "br", "C", "T", "R" };
    for (collected.items.items, labels) |item, label| try std.testing.expectEqualStrings(label, item.label);
    try std.testing.expect(entryHasAbbreviations(entry));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try collected.write(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "abbr:") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "ab: shared explanation\n"));
}

test "abbreviation details escape plain metadata and leave unannotated output unchanged" {
    const values = [_]model.Span{.{ .text = "?", .explanation = "uncertain\x1b[31m\u{202e}" }};
    var entry: model.Entry = .{ .title = "entry", .kind = .citations, .preamble_spans = &values };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "?: uncertain\\u{1b}[31m\\u{202e}\n") != null);
    const plain = [_]model.Span{ .{ .text = "?" }, .{ .text = " ", .explanation = "no visible abbreviation" } };
    entry.preamble_spans = &plain;
    try std.testing.expect(!entryHasAbbreviations(entry));
    out.clearRetainingCapacity();
    try entryText(&out.writer, entry, false);
    try std.testing.expectEqualStrings("entry  / citations\n? \n", out.written());
    out.clearRetainingCapacity();
    _ = try entryTextFolded(&out, entry, false, .{ .details = false }, &.{}, 0);
    try std.testing.expectEqualStrings("entry  / citations\n? \n", out.written());
}

test "explained heading companions render once with exact title and level guards" {
    const heading = [_]model.Span{.{ .text = "Noun", .explanation = "part of speech" }};
    const meaning = [_]model.Span{.{ .text = "Definition." }};
    const blocks = [_]model.Block{
        .{ .kind = .heading, .level = 3, .spans = &heading },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &meaning },
    };
    const sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
    const entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .sections = &sections };
    try std.testing.expect(sectionHeadingCompanion(sections[0]) != null);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |folded| {
        out.clearRetainingCapacity();
        if (folded) _ = try entryTextFolded(&out, entry, false, .{ .details = true }, &.{}, 0) else try entryText(&out.writer, entry, false);
        const note_start = std.mem.indexOf(u8, out.written(), "\nAbbreviations\n").?;
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written()[0..note_start], "Noun"));
        try std.testing.expect(std.mem.indexOf(u8, out.written()[0..note_start], "Definition.") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written()[note_start..], "Noun: part of speech\n") != null);
    }
    var wrong_title = sections[0];
    wrong_title.title = "Other";
    try std.testing.expect(sectionHeadingCompanion(wrong_title) == null);
    var wrong_level = sections[0];
    wrong_level.level = 2;
    try std.testing.expect(sectionHeadingCompanion(wrong_level) == null);
    const plain_heading = [_]model.Span{.{ .text = "Noun" }};
    const plain_blocks = [_]model.Block{.{ .kind = .heading, .level = 3, .spans = &plain_heading }};
    try std.testing.expect(sectionHeadingCompanion(.{ .level = 3, .title = "Noun", .blocks = &plain_blocks }) == null);
}

test "typed color swatches render RGB samples and readable plain labels once" {
    const types = @import("blob_encoder").presentation_types;
    const spans = [_]model.Span{.{ .text = "retained table" }};
    const cells = [_]types.Cell{.{ .spans = &spans }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const table: model.Table = .{ .rows = &rows };
    const cases = .{
        .{ "#ffff00", "\x1b[48;2;255;255;0m" },
        .{ "#008000", "\x1b[48;2;0;128;0m" },
        .{ "#000000", "\x1b[48;2;0;0;0m" },
        .{ "#ffffff", "\x1b[48;2;255;255;255m" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    inline for (cases) |case| {
        const block: model.Block = .{ .kind = .table, .depth = 1, .spans = &.{}, .table = table, .feature = .{ .kind = "color_swatch", .data = case[0] } };
        try blocksText(&out.writer, &.{block}, false);
        try std.testing.expectEqualStrings("  Color sample " ++ case[0] ++ "\n\n", out.written());
        out.clearRetainingCapacity();
        try blocksText(&out.writer, &.{block}, true);
        try std.testing.expectEqualStrings("  [" ++ case[1] ++ "  \x1b[0m] Color sample " ++ case[0] ++ "\n\n", out.written());
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), case[0]));
        try std.testing.expectEqual(@as(usize, 27), terminal.cellWidth(std.mem.trimEnd(u8, out.written(), "\n")));
        try std.testing.expectEqualStrings("retained table", block.table.?.rows[0].cells[0].spans[0].text);
        out.clearRetainingCapacity();
    }
}

test "unsupported color features preserve exact existing table output" {
    const types = @import("blob_encoder").presentation_types;
    const spans = [_]model.Span{.{ .kind = .link, .text = "Fallback entry", .target = "fallback", .bold = true }};
    const cells = [_]types.Cell{.{ .spans = &spans }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    var block: model.Block = .{ .kind = .table, .spans = &.{}, .table = .{ .rows = &rows } };
    const features = [_]?model.Feature{
        null,
        .{ .kind = "future_feature", .data = "#ffff00" },
        .{ .kind = "color_swatch", .data = "#FFFF00" },
        .{ .kind = "color_swatch", .data = "#ff0" },
        .{ .kind = "color_swatch", .data = "#ffff000" },
        .{ .kind = "color_swatch", .data = "#ffff0g" },
        .{ .kind = "color_swatch", .data = " #ffff00" },
        .{ .kind = "color_swatch", .data = "#ffff00\x1b[0m" },
        .{ .kind = "color_swatch", .data = "#ffff00", .language = "en" },
        .{ .kind = "color_swatch", .data = "#ffff00", .tail_kind = "text" },
        .{ .kind = "color_swatch", .data = "#ffff00", .tail = "extra" },
    };
    var baseline: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer baseline.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |color| {
        try tableText(&baseline.writer, block.table.?, color, null);
        for (features) |feature| {
            block.feature = feature;
            try blocksText(&out.writer, &.{block}, color);
            try std.testing.expectEqualStrings(baseline.written(), out.written());
            out.clearRetainingCapacity();
        }
        block.feature = .{ .kind = "color_swatch", .data = "#ffff00" };
        block.kind = .paragraph;
        try blocksText(&out.writer, &.{block}, color);
        try std.testing.expectEqualStrings(baseline.written(), out.written());
        out.clearRetainingCapacity();
        block.kind = .table;
        baseline.clearRetainingCapacity();
    }
    block.table = null;
    try std.testing.expect(colorSwatchRgb(block) == null);
}

test "ordinary block display collapses ASCII runs across styles links and trails without editing spans" {
    const values = [_]model.Span{
        .{ .text = "ste  " },
        .{ .kind = .link, .text = " street", .target = "Street target", .trail = "  ", .bold = true },
        .{ .text = "save\t\tword", .italic = true },
    };
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    try spansTextDisplayProjected(&plain.writer, &values, false, null, true);
    try std.testing.expectEqualStrings("ste street save word", plain.written());
    var styled: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer styled.deinit();
    try spansTextDisplayProjected(&styled.writer, &values, true, null, true);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[36mstreet") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "  ") == null);
    try std.testing.expectEqualStrings("ste  ", values[0].text);
    try std.testing.expectEqualStrings(" street", values[1].text);
    try std.testing.expectEqualStrings("Street target", values[1].target);
    try std.testing.expectEqualStrings("  ", values[1].trail);
}

test "ordinary display keeps code Poem NBSP explicit breaks and existing raw span output" {
    const values = [_]model.Span{
        .{ .text = "a\u{a0}\u{a0}b  " },
        .{ .kind = .line_break },
        .{ .text = "  c\t d", .code = true },
        .{ .kind = .line_break },
        .{ .text = "  e\t\t f" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try spansTextDisplayProjected(&out.writer, &values, false, null, true);
    try std.testing.expectEqualStrings("a\u{a0}\u{a0}b \n  c\t d\n e f", out.written());
    out.clearRetainingCapacity();
    try spansText(&out.writer, &values, false);
    try std.testing.expectEqualStrings("a\u{a0}\u{a0}b  \n  c\t d\n  e\t\t f", out.written());
    const poem = [_]model.Span{
        .{ .text = "p  q" },
        .{ .text = " r  s", .classes = "wikidict-poem" },
    };
    out.clearRetainingCapacity();
    try spansTextDisplayProjected(&out.writer, &poem, false, null, true);
    try std.testing.expectEqualStrings("p  q r  s", out.written());
}

test "human block whitespace projection preserves preformatted table and JSON data" {
    const values = [_]model.Span{.{ .text = "ste  street" }};
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &values },
        .{ .kind = .preformatted, .spans = &values },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try blocksText(&out.writer, &blocks, false);
    try std.testing.expectEqualStrings("ste street\n\n    ste  street\n", out.written());
    out.clearRetainingCapacity();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var projection: PoemProjection = .{ .frame = &out, .allocator = std.testing.allocator, .lines = &lines };
    try blocksTextProjected(&out.writer, &blocks, false, &projection);
    try std.testing.expectEqualStrings("ste street\n\n    ste  street\n", out.written());
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
    const types = @import("blob_encoder").presentation_types;
    const cells = [_]types.Cell{.{ .spans = &values }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    out.clearRetainingCapacity();
    try tableText(&out.writer, .{ .rows = &rows }, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ste  street") != null);
    const sections = [_]model.Section{.{ .level = 2, .title = "ordinary", .blocks = &blocks }};
    const entries = [_]model.Entry{.{ .title = "entry", .kind = .language, .sections = &sections }};
    out.clearRetainingCapacity();
    try json(&out.writer, .{ .operation = .lookup, .query = "entry", .kind = .language, .language = null, .record_count = 1, .total_matches = 1, .entries = &entries });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ste  street") != null);
    try std.testing.expectEqualStrings("ste  street", entries[0].sections[0].blocks[0].spans[0].text);
}

test "script display keeps one marker across source welcome parentheses and external link" {
    const spans = [_]model.Span{
        .{ .kind = .link, .text = "IPA", .target = "IPA" },
        .{ .text = "(", .superscript = true },
        .{ .kind = .external_link, .text = "am", .target = "https://en.wikipedia.org/wiki/Amharic#Phonology", .superscript = true },
        .{ .text = ")", .superscript = true },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |color| {
        out.clearRetainingCapacity();
        try spansText(&out.writer, &spans, color);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "^"));
        try std.testing.expectEqual(@as(usize, 8), terminal.cellWidth(out.written()));
        if (!color) try std.testing.expectEqualStrings("IPA^(am)", out.written());
        if (color) try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[36mam") != null);
    }
    try std.testing.expectEqualStrings("am", spans[2].text);
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Amharic#Phonology", spans[2].target);
}

test "script display preserves trails references style boundaries and physical lines" {
    const spans = [_]model.Span{
        .{ .kind = .link, .text = "ab", .trail = "cd", .target = "target", .superscript = true },
        .{ .text = "", .italic = true },
        .{ .text = "E", .bold = true, .superscript = true },
        .{ .text = " / " },
        .{ .text = "x", .subscript = true },
        .{ .text = "y", .italic = true, .subscript = true },
        .{ .text = "[1]", .role = .reference, .superscript = true },
        .{ .text = "Z", .superscript = true },
        .{ .kind = .line_break },
        .{ .text = "Q\nR", .superscript = true },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try spansText(&out.writer, &spans, false);
    try std.testing.expectEqualStrings("^abcdE / _xy[1]^Z\n^Q\nR", out.written());
    try std.testing.expectEqualStrings("cd", spans[0].trail);
    out.clearRetainingCapacity();
    try spansText(&out.writer, spans[2..3], false);
    try std.testing.expectEqualStrings("^E", out.written());
}

test "script display table widths ignore semantic span fragmentation" {
    terminal.initLocale();
    const types = @import("blob_encoder").presentation_types;
    const parts = [_]model.Span{
        .{ .text = "(", .superscript = true },
        .{ .kind = .external_link, .text = "am", .target = "https://en.wikipedia.org/wiki/Amharic#Phonology", .superscript = true },
        .{ .text = ")", .superscript = true },
    };
    const whole = [_]model.Span{.{ .text = "(am)", .superscript = true }};
    const plain = [_]model.Span{.{ .text = "next" }};
    const split_cells = [_]types.Cell{ .{ .spans = &parts }, .{ .spans = &plain } };
    const whole_cells = [_]types.Cell{ .{ .spans = &whole }, .{ .spans = &plain } };
    const split_rows = [_]types.Row{.{ .cells = &split_cells }};
    const whole_rows = [_]types.Row{.{ .cells = &whole_cells }};
    var a: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer b.deinit();
    try tableText(&a.writer, .{ .rows = &split_rows }, false, null);
    try tableText(&b.writer, .{ .rows = &whole_rows }, false, null);
    try std.testing.expectEqualStrings(b.written(), a.written());
    const width = terminal.cellWidth(a.written());
    a.clearRetainingCapacity();
    try tableText(&a.writer, .{ .rows = &split_rows }, true, null);
    try std.testing.expectEqual(width, terminal.cellWidth(a.written()));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, a.written(), "^"));
}

const NarrowTableTest = struct {
    fn plain(a: std.mem.Allocator, text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var i: usize = 0;
        while (i < text.len) {
            if (terminal.sgrLength(text[i..])) |n| i += n else {
                try out.append(a, text[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(a);
    }
    fn framed(text: []const u8, columns: usize) !usize {
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or std.mem.startsWith(u8, line, "  Row ")) continue;
            try std.testing.expect(terminal.cellWidth(line) <= columns);
            try std.testing.expect(std.mem.startsWith(u8, line, "  │ "));
            try std.testing.expect(std.mem.endsWith(u8, line, " │"));
            count += 1;
        }
        return count;
    }
};

test "typed tables fit welcome body widths without changing unbounded display" {
    const types = @import("blob_encoder").presentation_types;
    const heading = [_]model.Span{.{ .text = "translation" }};
    const french = [_]model.Span{ .{ .text = "French : " }, .{ .kind = .link, .text = "Bienvenue sur le Wiktionnaire", .target = "Bienvenue sur le Wiktionnaire" } };
    const greek = [_]model.Span{ .{ .text = "greek : " }, .{ .kind = .link, .text = "καλωσορίσατε στο Βικιλεξικό", .target = "καλωσορίσατε στο Βικιλεξικό" }, .{ .text = "!" } };
    const h = [_]types.Cell{.{ .header = true, .spans = &heading }};
    const f = [_]types.Cell{.{ .spans = &french }};
    const g = [_]types.Cell{.{ .spans = &greek }};
    const rows = [_]types.Row{ .{ .cells = &h }, .{ .cells = &f }, .{ .cells = &g } };
    const table: model.Table = .{ .rows = &rows };
    const a = std.testing.allocator;
    terminal.initLocale();
    for ([_]bool{ false, true }) |color| {
        var baseline: std.Io.Writer.Allocating = .init(a);
        defer baseline.deinit();
        try tableText(&baseline.writer, table, color, null);
        try std.testing.expectEqual(@as(usize, 3), try NarrowTableTest.framed(baseline.written(), 44));
        for ([_]usize{ 40, 80, 120 }) |screen| {
            const column = if (screen < 80) 3 else @min(36, screen / 3) + 3;
            const width = screen - column - 1;
            var text: std.Io.Writer.Allocating = .init(a);
            defer text.deinit();
            var metadata: std.ArrayList(terminal.PoemLine) = .empty;
            defer metadata.deinit(a);
            var projection: PoemProjection = .{ .frame = &text, .allocator = a, .lines = &metadata, .table_columns = width };
            try tableText(&text.writer, table, color, &projection);
            const framed = try NarrowTableTest.framed(text.written(), width);
            try std.testing.expectEqual(@as(usize, 0), metadata.items.len);
            if (screen == 40) try std.testing.expect(framed > 3) else try std.testing.expectEqualStrings(baseline.written(), text.written());
            const visible = try NarrowTableTest.plain(a, text.written());
            defer a.free(visible);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "translation"));
            const wrapped = try terminal.wrapStyledProjected(a, text.written(), width, metadata.items);
            defer a.free(wrapped);
            var physical: usize = 0;
            for (wrapped) |line| if (line.bytes.len != 0) {
                try std.testing.expect(std.mem.startsWith(u8, line.bytes, "  │ ") and std.mem.endsWith(u8, line.bytes, " │"));
                physical += 1;
            };
            try std.testing.expectEqual(framed, physical);
        }
    }
    try std.testing.expectEqualStrings("Bienvenue sur le Wiktionnaire", french[1].target);
    try std.testing.expectEqualStrings("καλωσορίσατε στο Βικιλεξικό", greek[1].text);
}

test "narrow typed table cells preserve Unicode styles spans and literal whitespace" {
    const types = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    terminal.initLocale();
    const literal = "  猫é猫éABCDEFGHIJKLMNO   tail  ";
    const values = [_]model.Span{.{ .kind = .link, .text = literal, .target = "same target", .bold = true, .italic = true, .code = true }};
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try spansText(&styled.writer, &values, true);
    const cell_lines = try tableCellRows(a, styled.written(), 8);
    defer a.free(cell_lines);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    var carried = false;
    for (cell_lines, 0..) |line, i| {
        try std.testing.expect(terminal.cellWidth(line.bytes) <= 8);
        const visible = try NarrowTableTest.plain(a, line.bytes);
        defer a.free(visible);
        try std.testing.expect(std.unicode.utf8ValidateSlice(visible));
        try joined.appendSlice(a, visible);
        if (i != 0 and line.carry.link and line.carry.bold and line.carry.italic) carried = true;
    }
    try std.testing.expect(carried);
    try std.testing.expectEqualStrings(literal, joined.items);
    const head = [_]model.Span{.{ .text = "wide header with a colspan" }};
    const first = [_]types.Cell{ .{ .spans = &head, .header = true, .colspan = 2 }, .{ .spans = &.{.{ .text = "third" }} } };
    const second = [_]types.Cell{ .{ .spans = &values, .rowspan = 2 }, .{ .spans = &.{.{ .text = "other long unbreakable ABCDEFGHIJKLMNOP" }}, .colspan = 2 } };
    const third = [_]types.Cell{ .{ .spans = &.{.{ .text = "next" }} }, .{ .spans = &.{.{ .text = "last" }} } };
    const rows = [_]types.Row{ .{ .cells = &first }, .{ .cells = &second }, .{ .cells = &third } };
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    var metadata: std.ArrayList(terminal.PoemLine) = .empty;
    defer metadata.deinit(a);
    var projection: PoemProjection = .{ .frame = &text, .allocator = a, .lines = &metadata, .table_columns = 36 };
    try tableText(&text.writer, .{ .rows = &rows }, true, &projection);
    try std.testing.expect(try NarrowTableTest.framed(text.written(), 36) > 3);
    try std.testing.expectEqual(@as(u16, 2), first[0].colspan);
    try std.testing.expectEqual(@as(u16, 2), second[0].rowspan);
    try std.testing.expectEqualStrings("same target", values[0].target);
    // Seven columns cannot each retain a two-cell glyph and separators in36.
    const many = [_]types.Cell{
        .{ .spans = &head, .header = true }, .{ .spans = &values }, .{ .spans = &head },
        .{ .spans = &head },                 .{ .spans = &head },   .{ .spans = &head },
        .{ .spans = &head },
    };
    const crowded = [_]types.Row{.{ .cells = &many }};
    text.clearRetainingCapacity();
    try tableText(&text.writer, .{ .rows = &crowded }, true, &projection);
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, text.written(), "  Row 1, column "));
    try std.testing.expect(try NarrowTableTest.framed(text.written(), 36) >= 7);
}
