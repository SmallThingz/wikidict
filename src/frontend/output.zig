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
    float_flow: ?*FloatProjection = null,
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
            if (self.phase == 0 and span.image != null and span.text.len == 0) {
                self.phase = 1;
                return .{ .span = span, .bytes = "[image]", .ends_line = false, .initial = true, .info = self.info };
            }
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

fn canonicalRgb(value: ?[]const u8) ?[3]u8 {
    const text = value orelse return null;
    if (text.len != 7 or text[0] != '#') return null;
    for (text[1..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    }
    return .{
        std.fmt.parseInt(u8, text[1..3], 16) catch return null,
        std.fmt.parseInt(u8, text[3..5], 16) catch return null,
        std.fmt.parseInt(u8, text[5..7], 16) catch return null,
    };
}

// Choose the greater black/white contrast ratio in linear sRGB. Only an
// authored canonical background opts into this display fallback.
fn contrastForeground(background: [3]u8) [3]u8 {
    const weights = [_]f64{ 0.2126, 0.7152, 0.0722 };
    var luminance: f64 = 0;
    for (background, weights) |channel, weight| {
        const srgb = @as(f64, @floatFromInt(channel)) / 255.0;
        const linear = if (srgb <= 0.04045) srgb / 12.92 else std.math.pow(f64, (srgb + 0.055) / 1.055, 2.4);
        luminance += weight * linear;
    }
    const black = (luminance + 0.05) / 0.05;
    const white = 1.05 / (luminance + 0.05);
    return if (black >= white) .{ 0, 0, 0 } else .{ 255, 255, 255 };
}

const SpanContainerPaint = struct { foreground: ?[3]u8 = null, background: ?[3]u8 = null };

fn spanPieceText(w: *std.Io.Writer, piece: SpanPiece, color: bool, whitespace: ?*OrdinaryDisplayWhitespace, scripts: *ScriptDisplayRuns, cell_background: ?[3]u8, inherited_header: bool, container_paint: ?SpanContainerPaint) !void {
    const span = piece.span;
    if (piece.bytes.len == 0) return;
    const explicit_foreground = canonicalRgb(span.foreground);
    const foreground = explicit_foreground orelse if (container_paint) |paint| paint.foreground else null;
    const painted_background = canonicalRgb(span.background) orelse if (container_paint) |paint| paint.background else null;
    const authored_background = painted_background orelse cell_background;
    const contrast_link = foreground == null and authored_background != null and
        (span.kind == .link or span.kind == .external_link);
    if (color and (span.bold or inherited_header)) try w.writeAll("\x1b[1m");
    if (color and span.italic) try w.writeAll("\x1b[3m");
    if (color and (span.underline or contrast_link)) try w.writeAll("\x1b[4m");
    if (color and span.strike) try w.writeAll("\x1b[9m");
    const numeric_small = if (span.font_scale) |scale| scale > 0 and scale < 1 else false;
    if (color and (span.small or numeric_small or span.role == .label or span.role == .citation)) try w.writeAll("\x1b[2m");
    if (color) {
        if (painted_background) |rgb|
            try w.print("\x1b[48;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
        if (foreground) |rgb|
            try w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] })
        else if (authored_background) |background| {
            const ink = contrastForeground(background);
            try w.print("\x1b[38;2;{d};{d};{d}m", .{ ink[0], ink[1], ink[2] });
        } else if (span.kind == .link or span.kind == .external_link)
            try w.writeAll("\x1b[36m");
    }
    try scripts.prefix(w, span, piece.initial);
    if (piece.initial and span.image != null) {
        try w.writeAll("[image");
        if (span.image.?.alt) |alt| if (alt.len != 0) {
            try w.writeAll(": ");
            try terminalText(w, alt);
        };
        try w.writeByte(']');
        if (whitespace) |state| state.space = false;
    } else if (whitespace) |state| try state.write(w, piece.bytes, span.code or piece.info.marked or span.background != null) else try terminalText(w, piece.bytes);
    if (color) try w.writeAll("\x1b[0m");
}

pub fn spansText(w: *std.Io.Writer, spans: []const model.Span, color: bool) !void {
    return spansTextProjected(w, spans, color, null);
}
fn spansTextProjected(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection) !void {
    return spansTextDisplayProjected(w, spans, color, projection, false);
}
fn spansTextDisplayProjected(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection, ordinary: bool) !void {
    return spansTextDisplayOnBackground(w, spans, color, projection, ordinary, null, false);
}
fn spansTextDisplayOnBackground(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection, ordinary: bool, cell_background: ?[3]u8, inherited_header: bool) !void {
    return spansTextDisplayWithContinuation(w, spans, color, projection, ordinary, cell_background, inherited_header, null);
}
fn spansTextDisplayWithContinuation(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection, ordinary: bool, cell_background: ?[3]u8, inherited_header: bool, detail_depth: ?u8) !void {
    return spansTextDisplayWithPaint(w, spans, color, projection, ordinary, cell_background, inherited_header, detail_depth, null);
}
const SpanDisplayState = struct { whitespace: OrdinaryDisplayWhitespace = .{}, scripts: ScriptDisplayRuns = .{} };
fn spansTextDisplayWithPaint(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection, ordinary: bool, cell_background: ?[3]u8, inherited_header: bool, detail_depth: ?u8, container_paint: ?SpanContainerPaint) !void {
    var state: SpanDisplayState = .{};
    return spansTextDisplayWithState(w, spans, color, projection, ordinary, cell_background, inherited_header, detail_depth, container_paint, &state);
}
fn spansTextDisplayWithState(w: *std.Io.Writer, spans: []const model.Span, color: bool, projection: ?*PoemProjection, ordinary: bool, cell_background: ?[3]u8, inherited_header: bool, detail_depth: ?u8, container_paint: ?SpanContainerPaint, state: *SpanDisplayState) !void {
    var collapse = ordinary;
    if (collapse) for (spans) |span| {
        if (PoemInfo.parse(span.classes).marked) {
            collapse = false;
            break;
        }
    };

    var cursor: SpanCursor = .{ .spans = spans };
    var detail_line = false;
    var pending_breaks: usize = 0;
    while (true) {
        var scan = cursor;
        const first = scan.next() orelse break;
        var info = first.info;
        var count: usize = 1;
        var newline = first.ends_line;
        var content = first.bytes.len != 0;
        while (!newline) {
            const piece = scan.next() orelse break;
            // An ordinary boundary break ends the marked line without changing its layout.
            if (!(piece.span.kind == .line_break and piece.ends_line and !piece.info.marked)) info.merge(piece.info);
            count += 1;
            content = content or piece.bytes.len != 0;
            newline = piece.ends_line;
        }
        if (detail_depth) |depth| {
            // Defer hard breaks until another content line appears. The block
            // owns its final newline; source trailing breaks add no blank rows.
            if (!content) {
                cursor = scan;
                if (newline) pending_breaks += 1;
                continue;
            }
            try w.splatByteAll('\n', pending_breaks);
            pending_breaks = 0;
            if (detail_line) {
                try w.splatByteAll(' ', @as(usize, @min(depth, 12)) * 2);
                try w.writeAll("│ ");
            }
            detail_line = true;
        }
        if (projection) |p| try p.record(info) else if (info.marked and !info.rtl) try w.splatByteAll(' ', info.depth);
        for (0..count) |_| try spanPieceText(w, cursor.next().?, color, if (collapse) &state.whitespace else null, &state.scripts, cell_background, inherited_header, container_paint);
        if (projection == null and info.marked and info.rtl) try w.splatByteAll(' ', info.depth);
        if (newline) {
            if (detail_depth != null) pending_breaks += 1 else try w.writeByte('\n');
            state.whitespace.space = false;
            state.scripts = .{};
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
// Cell fill owns its two padding spaces but never the neutral frame/borders.
// Span resets restore the cell base without inheriting the previous span font.
fn tableWrappedLine(w: *std.Io.Writer, line: terminal.RenderRow, width: usize, color: bool, background: ?[3]u8, padding: usize) !void {
    return tableWrappedAlignedLine(w, line, width, color, background, padding, 0);
}
const TextAlign = @import("blob_encoder").presentation_types.CellTextAlign;

pub const FlowOrigin = struct { start: usize, end: usize, row: usize };
pub const FlowEvent = struct {
    kind: enum { text, grid, float_grid, boundary },
    start: usize,
    end: usize,
    alignment: ?TextAlign = null,
    side: ?@import("blob_encoder").presentation_types.TableFloatSide = null,
    left: usize = 0,
    right: usize = 0,
    supported: bool = true,
};
/// Build-only terminal layout coordinates; never semantic text or source markup.
pub const FloatProjection = struct {
    allocator: std.mem.Allocator,
    frame: *std.Io.Writer.Allocating,
    columns: usize,
    events: std.ArrayList(FlowEvent) = .empty,
    enabled: bool = true,
    started: bool = false,
    capturing: bool = false,
    capturing_float: bool = false,
    fn stop(self: *FloatProjection) !void {
        if (!self.enabled) return;
        if (self.started) {
            const offset = self.frame.written().len;
            try self.events.append(self.allocator, .{ .kind = .boundary, .start = offset, .end = offset });
        }
        self.enabled = false;
    }
    fn record(self: *FloatProjection, block: model.Block, start: usize) !void {
        var event: FlowEvent = .{ .kind = .text, .start = start, .end = self.frame.written().len, .alignment = block.text_align };
        if (block.table) |table| {
            event.kind = .grid;
            if (table.style) |style| if (style.float_side) |side| {
                event.kind = .float_grid;
                event.side = side;
                if (style.margins) |margins| {
                    // There is no established vertical or positive-em metric.
                    const left = horizontalFloatMargin(margins.left, self.columns);
                    const right = horizontalFloatMargin(margins.right, self.columns);
                    event.supported = margins.top.value == 0 and margins.bottom.value == 0 and left != null and right != null;
                    event.left = left orelse 0;
                    event.right = right orelse 0;
                }
            };
        } else if (block.kind == .rule or block.kind == .preformatted) event.kind = .grid;
        try self.events.append(self.allocator, event);
    }
};
fn horizontalFloatMargin(value: @import("blob_encoder").presentation_types.StyleLength, columns: usize) ?usize {
    if (!std.math.isFinite(value.value) or value.value < 0) return null;
    if (value.value == 0) return 0;
    if (value.unit != .px) return null;
    const cells = @ceil(@as(f64, value.value) / 8.0);
    if (cells > @as(f64, @floatFromInt(columns)) or cells >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(cells);
}
fn floatRowsWithinBudget(rows: usize, columns: usize, max_cells: usize) bool {
    return columns != 0 and rows <= max_cells / columns;
}
pub const FloatLayout = struct {
    text: []u8,
    rows: []terminal.RenderRow,
    origins: []FlowOrigin,
    unsupported: usize,
    pub fn rowForOffset(self: FloatLayout, offset: usize) usize {
        return flowRowForOffset(self.origins, offset);
    }
    pub fn deinit(self: FloatLayout, a: std.mem.Allocator) void {
        a.free(self.rows);
        a.free(self.origins);
        a.free(self.text);
    }
};
pub fn flowRowForOffset(origins: []const FlowOrigin, offset: usize) usize {
    var selected: usize = 0;
    var distance: usize = std.math.maxInt(usize);
    for (origins) |origin| {
        if (offset >= origin.start and (offset < origin.end or (origin.start == origin.end and offset == origin.start))) return origin.row;
        if (origin.start >= offset and origin.start - offset < distance) {
            selected = origin.row;
            distance = origin.start - offset;
        }
    }
    return selected;
}

const FloatRowBuilder = struct {
    a: std.mem.Allocator,
    source: []const u8,
    columns: usize,
    color: bool,
    max_cells: usize,
    used_cells: usize = 0,
    out: std.Io.Writer.Allocating,
    ranges: std.ArrayList(struct { start: usize, end: usize }) = .empty,
    origins: std.ArrayList(FlowOrigin) = .empty,
    unsupported: usize = 0,
    active: ?struct {
        rows: []terminal.RenderRow,
        next: usize = 0,
        width: usize,
        left: usize,
        right: usize,
        side: @import("blob_encoder").presentation_types.TableFloatSide,
    } = null,
    fn deinit(self: *FloatRowBuilder) void {
        if (self.active) |active| self.a.free(active.rows);
        self.ranges.deinit(self.a);
        self.origins.deinit(self.a);
        self.out.deinit();
    }
    fn gap(self: FloatRowBuilder) usize {
        return if (self.active) |active| self.columns - (active.width + active.left + active.right) else self.columns;
    }
    fn origin(self: *FloatRowBuilder, row: terminal.RenderRow) !void {
        const start = @intFromPtr(row.bytes.ptr) - @intFromPtr(self.source.ptr);
        try self.origins.append(self.a, .{ .start = start, .end = start + row.bytes.len, .row = self.ranges.items.len });
    }
    fn segment(self: *FloatRowBuilder, row: terminal.RenderRow, width: usize, alignment: ?TextAlign, fill: bool) !void {
        const leading = row.left + alignmentLeading(alignment, row, width -| (row.left + row.right));
        if (self.color) try self.out.writer.writeAll("\x1b[0m");
        try self.out.writer.splatByteAll(' ', leading);
        if (self.color) try row.carry.write(&self.out.writer);
        try self.out.writer.writeAll(row.bytes);
        if (self.color) try self.out.writer.writeAll("\x1b[0m");
        if (fill) try self.out.writer.splatByteAll(' ', width -| (leading + terminal.cellWidth(row.bytes)));
    }
    fn emit(self: *FloatRowBuilder, prose_row: ?terminal.RenderRow, alignment: ?TextAlign) !void {
        const start = self.out.written().len;
        const empty: terminal.RenderRow = .{ .bytes = "", .carry = .{} };
        if (self.active) |active| {
            const floated = active.rows[active.next];
            if (active.side == .left) {
                try self.out.writer.splatByteAll(' ', active.left);
                try self.segment(floated, active.width, null, true);
                try self.out.writer.splatByteAll(' ', active.right);
                if (prose_row) |row| try self.segment(row, self.gap(), alignment, false);
            } else {
                if (prose_row) |row| try self.segment(row, self.gap(), alignment, true) else try self.segment(empty, self.gap(), null, true);
                try self.out.writer.splatByteAll(' ', active.left);
                try self.segment(floated, active.width, null, false);
                try self.out.writer.splatByteAll(' ', active.right);
            }
            try self.origin(floated);
            self.active.?.next += 1;
            if (self.active.?.next == active.rows.len) {
                self.a.free(active.rows);
                self.active = null;
            }
        } else if (prose_row) |row| try self.segment(row, self.columns, alignment, false);
        if (prose_row) |row| try self.origin(row);
        const end = self.out.written().len;
        try self.ranges.append(self.a, .{ .start = start, .end = end });
        try self.out.writer.writeByte('\n');
    }
    fn emitFixed(self: *FloatRowBuilder, row: terminal.RenderRow, left: usize, width: usize, alignment: ?TextAlign) !void {
        const start = self.out.written().len;
        try self.out.writer.splatByteAll(' ', left);
        try self.segment(row, width, alignment, false);
        try self.origin(row);
        try self.ranges.append(self.a, .{ .start = start, .end = self.out.written().len });
        try self.out.writer.writeByte('\n');
    }
    fn drain(self: *FloatRowBuilder) !void {
        while (self.active != null) try self.emit(null, null);
    }
    fn poemsFor(self: FloatRowBuilder, a: std.mem.Allocator, poems: []const terminal.PoemLine, start: usize, end: usize) ![]terminal.PoemLine {
        var out: std.ArrayList(terminal.PoemLine) = .empty;
        errdefer out.deinit(a);
        var previous: ?terminal.PoemLine = null;
        for (poems) |line| {
            if (line.offset >= start) break;
            previous = line;
        }
        if (previous) |line| if (std.mem.indexOfScalar(u8, self.source[line.offset..start], '\n') == null) {
            var continuation = line;
            continuation.offset = 0;
            continuation.left = line.continuation_left;
            continuation.lead_bytes = 0;
            continuation.lead_cells = 0;
            try out.append(a, continuation);
        };
        for (poems) |line| if (line.offset >= start and line.offset < end) {
            var local = line;
            local.offset -= start;
            try out.append(a, local);
        };
        return out.toOwnedSlice(a);
    }
    fn prose(self: *FloatRowBuilder, start: usize, end: usize, poems: []const terminal.PoemLine, initial: terminal.TextStyle, alignment: ?TextAlign) !void {
        if (start == end) return;
        var at = start;
        var carry = initial;
        while (at < end) {
            const local_poems = try self.poemsFor(self.a, poems, at, end);
            defer self.a.free(local_poems);
            const rows = try terminal.wrapStyledProjectedFromStyle(self.a, self.source[at..end], self.gap(), local_poems, carry);
            defer self.a.free(rows);
            var count = rows.len;
            if (count != 0 and rows[count - 1].bytes.len == 0 and self.source[end - 1] == '\n') count -= 1;
            var used: usize = 0;
            const had_float = self.active != null;
            while (used < count) : (used += 1) {
                try self.emit(rows[used], alignment);
                if (had_float and self.active == null) { used += 1; break; }
            }
            if (used >= count) return;
            // Reflow the remaining original slice at the now full width. The
            // next row owns both its source offset and exact incoming SGR state.
            at = @intFromPtr(rows[used].bytes.ptr) - @intFromPtr(self.source.ptr);
            carry = rows[used].carry;
        }
    }
    fn grid(self: *FloatRowBuilder, start: usize, end: usize, initial: terminal.TextStyle, event: ?FlowEvent) !void {
        var trimmed = end;
        if (event != null and event.?.kind == .float_grid) while (trimmed > start and self.source[trimmed - 1] == '\n') { trimmed -= 1; };
        if (trimmed == start) return;
        const rows = try terminal.wrapStyledProjectedFromStyle(self.a, self.source[start..trimmed], self.columns, &.{}, initial);
        var transferred = false;
        defer if (!transferred) self.a.free(rows);
        var count = rows.len;
        if (count != 0 and rows[count - 1].bytes.len == 0 and self.source[trimmed - 1] == '\n') count -= 1;
        var width: usize = 0;
        for (rows[0..count]) |row| width = @max(width, terminal.cellWidth(row.bytes));
        if (event) |float_event| if (float_event.kind == .float_grid) {
            const occupied = width +| float_event.left +| float_event.right;
            if (float_event.supported and self.active == null and occupied <= self.columns and self.columns - occupied >= 2 and count != 0 and floatRowsWithinBudget(count, self.columns, self.max_cells -| self.used_cells)) {
                self.used_cells += count * self.columns;
                self.active = .{ .rows = rows, .width = width, .left = float_event.left, .right = float_event.right, .side = float_event.side.? };
                transferred = true;
                return;
            }
            self.unsupported += 1;
            try self.drain();
            var serial = float_event;
            serial.kind = .grid;
            serial.side = null;
            return self.grid(start, end, initial, serial);
        };
        if (self.active != null and width > self.gap()) try self.drain();
        const grid_width = self.gap();
        const grid_left = if (self.active) |active| if (active.side == .left) self.columns - grid_width else 0 else 0;
        const alignment = if (event) |value| value.alignment else null;
        for (rows[0..count]) |row| {
            if (self.active != null) try self.emit(row, alignment) else try self.emitFixed(row, grid_left, grid_width, alignment);
        }
    }
    fn finish(self: *FloatRowBuilder) !FloatLayout {
        try self.drain();
        const text = try self.out.toOwnedSlice();
        errdefer self.a.free(text);
        const rows = try self.a.alloc(terminal.RenderRow, self.ranges.items.len);
        errdefer self.a.free(rows);
        for (rows, self.ranges.items) |*row, range| row.* = .{ .bytes = text[range.start..range.end], .carry = .{} };
        const origins = try self.origins.toOwnedSlice(self.a);
        return .{ .text = text, .rows = rows, .origins = origins, .unsupported = self.unsupported };
    }
};
/// Visual rows own their buffer and map back to logical formatted byte ranges.
/// The input frame, model graph and semantic target/visitor order are unchanged.
pub fn floatLayoutAlloc(a: std.mem.Allocator, text: []const u8, columns: usize, poems: []const terminal.PoemLine, events: []const FlowEvent, color: bool) !FloatLayout {
    return floatLayoutWithBudgetAlloc(a, text, columns, poems, events, color, 4 * 1024 * 1024);
}
fn floatLayoutWithBudgetAlloc(a: std.mem.Allocator, text: []const u8, columns: usize, poems: []const terminal.PoemLine, events: []const FlowEvent, color: bool, max_cells: usize) !FloatLayout {
    if (columns < 2) return error.UnsupportedTerminalWidth;
    var builder: FloatRowBuilder = .{ .a = a, .source = text, .columns = columns, .color = color, .max_cells = max_cells, .out = .init(a) };
    defer builder.deinit();
    var at: usize = 0;
    var style: terminal.TextStyle = .{};
    for (events) |event| {
        if (event.start < at or event.end < event.start or event.end > text.len) return error.InvalidTerminalFlow;
        try builder.prose(at, event.start, poems, style, null);
        style = terminal.styleAfter(style, text[at..event.start]);
        switch (event.kind) {
            .boundary => try builder.drain(),
            .text => try builder.prose(event.start, event.end, poems, style, event.alignment),
            .grid, .float_grid => try builder.grid(event.start, event.end, style, event),
        }
        style = terminal.styleAfter(style, text[event.start..event.end]);
        at = event.end;
    }
    try builder.prose(at, text.len, poems, style, null);
    return builder.finish();
}

const BlockAlignmentPoint = struct { offset: usize, alignment: ?TextAlign };
const BlockAlignments = struct {
    allocator: std.mem.Allocator,
    frame: *std.Io.Writer.Allocating,
    points: std.ArrayList(BlockAlignmentPoint) = .empty,
    fn record(self: *BlockAlignments, alignment: ?TextAlign) !void {
        try self.points.append(self.allocator, .{ .offset = self.frame.written().len, .alignment = alignment });
    }
};
fn alignmentLeading(alignment: ?TextAlign, line: terminal.RenderRow, width: usize) usize {
    const spare = width -| terminal.cellWidth(line.bytes);
    return switch (alignment orelse return 0) { .right => spare, .center => spare / 2, .left => 0 };
}
fn cellProjectedLeading(cell: @import("blob_encoder").presentation_types.Cell, line: terminal.RenderRow, width: usize, text: []const u8, points: []const BlockAlignmentPoint) usize {
    var alignment: ?TextAlign = if (cell.style) |style| style.text_align else null;
    const address = @intFromPtr(line.bytes.ptr);
    const start = @intFromPtr(text.ptr);
    if (address < start or address - start > text.len) return cellLineLeading(cell, line, width);
    const offset = address - start;
    for (points) |point| {
        if (point.offset > offset) break;
        alignment = point.alignment orelse if (cell.style) |style| style.text_align else null;
    }
    return alignmentLeading(alignment, line, width);
}
fn cellLineLeading(cell: @import("blob_encoder").presentation_types.Cell, line: terminal.RenderRow, width: usize) usize {
    const style = cell.style orelse return 0;
    const alignment = style.text_align orelse return 0;
    return alignmentLeading(alignment, line, width);
}
fn tableWrappedAlignedLine(w: *std.Io.Writer, line: terminal.RenderRow, width: usize, color: bool, background: ?[3]u8, padding: usize, leading: usize) !void {
    var base_buffer: [80]u8 = undefined;
    const base: []const u8 = if (color) if (background) |rgb| base: {
        const ink = contrastForeground(rgb);
        break :base try std.fmt.bufPrint(&base_buffer, "\x1b[0m\x1b[48;2;{d};{d};{d}m\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2], ink[0], ink[1], ink[2] });
    } else "" else "";
    try w.writeAll(base);
    try w.splatByteAll(' ', padding);
    try w.splatByteAll(' ', leading);
    if (color) try line.carry.write(w);
    if (base.len != 0) try terminal.writeStyled(w, line.bytes, base) else try w.writeAll(line.bytes);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll(base);
    try w.splatByteAll(' ', (width -| terminal.cellWidth(line.bytes)) -| leading);
    try w.splatByteAll(' ', padding);
    if (base.len != 0) try w.writeAll("\x1b[0m");
}

fn tableText(w: *std.Io.Writer, table: model.Table, color: bool, projection: ?*PoemProjection) anyerror!void {
    return tableTextWidth(w, table, color, projection, if (projection) |p| p.table_columns else null);
}

// Terminal geometry is a deterministic projection, not CSS layout: eight CSS
// pixels per horizontal cell, positive borders one neutral rule. Percent widths
// need an available terminal width; the unbounded CLI leaves those natural.
fn tablePixels(value: u32) usize {
    return (@as(usize, value) + 7) / 8;
}

const CellDisplayStyle = struct { background: ?[3]u8 = null, header: bool = false, foreground: ?[3]u8 = null, content_depth: usize = 0, caption_paint: bool = false };
const BlockDisplayContext = struct {
    cell_style: ?CellDisplayStyle = null,
    columns: ?usize = null,
    table_depth: usize = 0,
    alignments: ?*BlockAlignments = null,
    alignment_suppressed: bool = false,
    ordinal: ?*usize = null,
    content_depth: usize = 0,
    container_paint: ?SpanContainerPaint = null,
};

fn cellHasTable(cell: @import("blob_encoder").presentation_types.Cell) bool {
    if (cell.blocks) |blocks| return contentHasTable(blocks, 0);
    return cell.nested_table != null;
}
fn figureContentHasTable(figure: anytype, depth: usize) bool {
    if (depth >= 16) return false;
    if (figure.caption_blocks) |blocks| return contentHasTable(blocks, depth + 1);
    return false;
}
fn flowContentHasTable(parts: anytype, depth: usize) bool {
    for (parts) |part| switch (part.kind) {
        .@"inline" => {},
        .figure => if (part.figure) |figure| { if (figureContentHasTable(figure, depth)) return true; },
        .scope => if (part.scope) |scope| { if (depth < 16 and flowContentHasTable(scope.parts, depth + 1)) return true; },
    };
    return false;
}
fn contentHasTable(blocks: []const model.Block, depth: usize) bool {
    for (blocks) |block| {
        if (block.table != null) return true;
        if (comptime @hasField(model.Block, "figure")) if (block.figure) |figure| { if (figureContentHasTable(figure, depth)) return true; };
        if (comptime @hasField(model.Block, "flow")) if (block.flow) |parts| { if (depth < 16 and flowContentHasTable(parts, depth + 1)) return true; };
    }
    return false;
}

fn tableCellText(w: *std.Io.Writer, cell: @import("blob_encoder").presentation_types.Cell, color: bool, columns: ?usize, table_depth: usize, inherited: ?CellDisplayStyle) anyerror!void {
    return tableCellTextProjected(w, cell, color, columns, table_depth, inherited, null);
}
fn tableCellTextProjected(w: *std.Io.Writer, cell: @import("blob_encoder").presentation_types.Cell, color: bool, columns: ?usize, table_depth: usize, inherited: ?CellDisplayStyle, alignment_points: ?*BlockAlignments) anyerror!void {
    const style: CellDisplayStyle = .{
        .background = canonicalRgb(cell.background) orelse if (inherited) |value| value.background else null,
        .header = cell.header or if (inherited) |value| value.header else false,
        .foreground = if (inherited) |value| value.foreground else null,
        .content_depth = if (inherited) |value| value.content_depth else 0,
        .caption_paint = if (inherited) |value| value.caption_paint else false,
    };
    if (cell.blocks) |blocks| {
        if (cell.spans.len != 0 or cell.nested_table != null) return error.InvalidPresentation;
        var rendered: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
        defer rendered.deinit();
        var track_alignment = false;
        if (alignment_points != null) for (blocks) |block| {
            if (block.text_align != null) { track_alignment = true; break; }
        };
        var alignments: BlockAlignments = .{ .allocator = std.heap.smp_allocator, .frame = &rendered };
        defer alignments.points.deinit(alignments.allocator);
        try blocksTextInContext(&rendered.writer, blocks, color, null, .{ .cell_style = style, .columns = columns, .table_depth = table_depth, .content_depth = style.content_depth, .container_paint = .{ .foreground = style.foreground }, .alignments = if (track_alignment) &alignments else null });
        if (alignment_points) |points| try points.points.appendSlice(points.allocator, alignments.points.items);
        var end = rendered.written().len;
        // Remove the block renderer's final terminator, not authored newlines.
        if (end != 0 and rendered.written()[end - 1] == '\n') end -= 1;
        try w.writeAll(rendered.written()[0..end]);
        return;
    }
    try spansTextDisplayWithPaint(w, cell.spans, color, null, false, style.background, style.header, null, .{ .foreground = style.foreground });
    if (color) try w.writeAll("\x1b[0m");
    if (cell.nested_table) |child| {
        if (cell.spans.len != 0) try w.writeByte('\n');
        var rendered: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
        defer rendered.deinit();
        // Preserve legacy projection; ordered ancestry carries its cell style.
        try tableTextWidthInContext(&rendered.writer, child, color, null, columns, table_depth, if (inherited != null) style else null);
        try w.writeAll(std.mem.trimEnd(u8, rendered.written(), "\n"));
    }
}

// CSS table width owns precedence even when its physical units are outside
// this logical terminal projection. Never apply a losing legacy HTML request.
fn tableStyleOwnsWidth(table: model.Table) bool {
    return if (table.style) |style| style.width != null else false;
}

fn tableTextWidth(w: *std.Io.Writer, table: model.Table, color: bool, projection: ?*PoemProjection, maximum: ?usize) anyerror!void {
    return tableTextWidthInContext(w, table, color, projection, maximum, 0, null);
}
fn tableTextWidthInContext(w: *std.Io.Writer, table: model.Table, color: bool, projection: ?*PoemProjection, maximum: ?usize, parent_depth: usize, inherited: ?CellDisplayStyle) anyerror!void {
    return tableTextWidthInContextIndented(w, table, color, projection, maximum, parent_depth, inherited, 2);
}
fn tableTextWidthInContextIndented(w: *std.Io.Writer, table: model.Table, color: bool, projection: ?*PoemProjection, maximum: ?usize, parent_depth: usize, inherited: ?CellDisplayStyle, indentation: usize) anyerror!void {
    if (parent_depth >= @import("blob_encoder").presentation_types.max_table_depth) return error.InvalidPresentation;
    const table_depth = parent_depth + 1;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    terminal.initLocale();
    // A typed table surface is visible behind transparent cells. Cell paint
    // remains authoritative; graphical lengths are not terminal geometry.
    const surface: ?CellDisplayStyle = if (table.style) |style| if (canonicalRgb(style.background)) |background|
        .{ .background = background, .header = if (inherited) |value| value.header else false, .foreground = if (inherited) |value| value.foreground else null, .content_depth = if (inherited) |value| value.content_depth else 0, .caption_paint = if (inherited) |value| value.caption_paint else false }
    else inherited else inherited;
    const padding: usize = if (table.geometry) |g| if (g.cell_padding) |v| tablePixels(v) else 1 else 1;
    const spacing: usize = if (table.geometry) |g| if (g.cell_spacing) |v| tablePixels(v) else 0 else 0;
    const border = if (table.geometry) |g| if (g.border) |v| v != 0 else true else true;
    const separator: usize = @intFromBool(border);
    const overhead = 2 * padding + separator + spacing;
    var columns_limit = maximum;
    if (!tableStyleOwnsWidth(table)) if (table.geometry) |g| if (g.width) |width| {
        const requested: ?usize = switch (width.unit) {
            .px => tablePixels(width.value),
            .percent => if (maximum) |available| available * @as(usize, width.value) / 100 else null,
        };
        if (requested) |v| columns_limit = if (maximum) |available| @min(available, v) else v;
    };
    var has_nested = false;
    const Placed = struct { source: @import("blob_encoder").presentation_types.Cell, row: usize, column: usize, colspan: usize, rowspan: usize, text: []const u8, lines: []const []const u8, wrapped: ?[]terminal.RenderRow = null, background: ?[3]u8 = null, alignments: []const BlockAlignmentPoint = &.{} };
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
            has_nested = has_nested or cellHasTable(cell);
            var alignments: BlockAlignments = .{ .allocator = a, .frame = &text };
            try tableCellTextProjected(&text.writer, cell, color, null, table_depth, surface, &alignments);
            const owned = try a.dupe(u8, text.written());
            var lines: std.ArrayList([]const u8) = .empty;
            var split = std.mem.splitScalar(u8, owned, '\n');
            var needed: usize = 0;
            while (split.next()) |line| {
                try lines.append(a, line);
                needed = @max(needed, terminal.cellWidth(line));
            }
            var available: usize = overhead * (colspan - 1);
            for (widths.items[column..][0..colspan]) |width| available += width;
            if (needed > available) widths.items[column + colspan - 1] += needed - available;
            try cells.append(a, .{ .source = cell, .row = r, .column = column, .colspan = colspan, .rowspan = rowspan, .text = owned, .lines = lines.items, .alignments = alignments.points.items, .background = canonicalRgb(cell.background) orelse if (surface) |value| value.background else null });
            column += colspan;
        }
    }
    const rich_caption: ?[]const model.Block = if (comptime @hasField(model.Table, "caption_blocks")) table.caption_blocks else null;
    if (rich_caption) |blocks| {
        if (table.caption.len != 0) return error.InvalidPresentation;
        try richCaptionText(w, blocks, color, projection, .{ .cell_style = surface, .columns = maximum, .table_depth = table_depth, .content_depth = if (surface) |value| value.content_depth else 0, .container_paint = .{ .foreground = if (surface) |value| value.foreground else null, .background = if (surface) |value| if (value.caption_paint) value.background else null else null } });
        if (blocks.len != 0) try w.writeByte('\n');
    } else if (table.caption.len != 0) {
        try spansTextDisplayWithPaint(w, table.caption, color, projection, false, if (surface) |value| value.background else null, if (surface) |value| value.header else false, null, .{ .foreground = if (surface) |value| value.foreground else null, .background = if (surface) |value| if (value.caption_paint) value.background else null else null });
        try w.writeByte('\n');
    }
    if (!tableStyleOwnsWidth(table)) if (table.geometry) |g| if (g.width != null and columns_limit != null and widths.items.len != 0) {
        var natural = (overhead * widths.items.len + indentation + separator) -| spacing;
        for (widths.items) |width| natural += width;
        if (columns_limit.? > natural) widths.items[widths.items.len - 1] += columns_limit.? - natural;
    };
    // The terminal body is at least 36 cells at its supported 40-column size.
    // Keep the natural grid byte-for-byte when it fits, and the CLI unbounded.
    if (columns_limit) |requested| {
        const columns = @max(requested, 8);
        var natural: usize = (overhead * widths.items.len + indentation + separator) -| spacing;
        for (widths.items) |width| natural += width;
        if (natural > columns and widths.items.len != 0) {
            const budget = columns -| ((overhead * widths.items.len + indentation + separator) -| spacing);
            if (budget < (if (has_nested) @as(usize, 8) else 2) * widths.items.len) {
                // A grid cannot give every column one full wide glyph. Stack
                // owned cells with explicit row/column/span identity instead.
                const width = columns -| (indentation + 4);
                for (cells.items) |cell| {
                    try w.splatByteAll(' ', indentation);
                    try w.print("Row {d}, column {d}", .{ cell.row + 1, cell.column + 1 });
                    if (cell.colspan != 1 or cell.rowspan != 1) try w.print(" (span {d} x {d})", .{ cell.colspan, cell.rowspan });
                    try w.writeByte('\n');
                    var nested_text: std.Io.Writer.Allocating = .init(a);
                    defer nested_text.deinit();
                    var alignments: BlockAlignments = .{ .allocator = a, .frame = &nested_text };
                    try tableCellTextProjected(&nested_text.writer, cell.source, color, width, table_depth, surface, &alignments);
                    const wrapped = try tableCellRows(a, nested_text.written(), width);
                    for (wrapped) |line| {
                        try w.splatByteAll(' ', indentation);
                        try w.writeAll("│");
                        try tableWrappedAlignedLine(w, line, width, color, cell.background, 1, cellProjectedLeading(cell.source, line, width, nested_text.written(), alignments.points.items));
                        try w.writeAll("│\n");
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
                var width: usize = overhead * (cell.colspan - 1);
                for (widths.items[cell.column..][0..cell.colspan]) |part| width += part;
                if (!cellHasTable(cell.source)) cell.wrapped = try tableCellRows(a, cell.text, width);
            }
        }
    }
    // A child percentage is relative to its owning cell even when the outer
    // natural grid already fits. Render after final column allocation; never
    // use the viewport as a substitute for the parent cell content budget.
    for (cells.items) |*cell| if (cellHasTable(cell.source)) {
        var width = overhead * (cell.colspan - 1);
        for (widths.items[cell.column..][0..cell.colspan]) |part| width += part;
        var nested_text: std.Io.Writer.Allocating = .init(a);
        defer nested_text.deinit();
        var alignments: BlockAlignments = .{ .allocator = a, .frame = &nested_text };
        try tableCellTextProjected(&nested_text.writer, cell.source, color, width, table_depth, surface, &alignments);
        cell.text = try a.dupe(u8, nested_text.written());
        cell.alignments = alignments.points.items;
        cell.wrapped = try tableCellRows(a, cell.text, width);
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
            try w.splatByteAll(' ', indentation);
            if (border) try w.writeAll("│");
            var column: usize = 0;
            while (column < widths.items.len) {
                var span: usize = 1;
                var line: []const u8 = "";
                var wrapped_line: ?terminal.RenderRow = null;
                var background: ?[3]u8 = null;
                var source: ?@import("blob_encoder").presentation_types.Cell = null;
                if (active[column]) |index| {
                    const cell = cells.items[index];
                    source = cell.source;
                    span = cell.colspan;
                    background = cell.background;
                    if (cell.row == r) {
                        if (cell.wrapped) |wrapped| {
                            if (line_index < wrapped.len) wrapped_line = wrapped[line_index];
                        } else if (line_index < cell.lines.len) line = cell.lines[line_index];
                    }
                }
                var width: usize = overhead * (span - 1);
                for (widths.items[column..][0..span]) |part| width += part;
                const rendered_line = wrapped_line orelse terminal.RenderRow{ .bytes = line, .carry = .{} };
                try tableWrappedAlignedLine(w, rendered_line, width, color, background, padding, if (source) |cell| cellProjectedLeading(cell, rendered_line, width, cells.items[active[column].?].text, cells.items[active[column].?].alignments) else 0);
                column += span;
                if (border) try w.writeAll("│");
                if (column == widths.items.len) try w.writeByte('\n') else try w.splatByteAll(' ', spacing);
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
    return canonicalRgb(feature.data);
}

// Figure layout is a native-reader concern. The terminal consumes the same
// complete image occurrence before its caption, without inventing float geometry
// or flattening image/map actions into caption text. An H-only model has no
// figure values; a J model's present figure is never silently discarded.
fn figureImageSpan(block: model.Block) ?model.Span {
    if (comptime @hasField(model.Block, "figure")) {
        if (block.figure) |figure| return figure.image_span;
    }
    return null;
}

// Project only representable caption container paint into ANSI text. Null
// fallback means the existing terminal reader palette; it is not authored RGB.
// Native-theme cuts inherited RGB. Transparent backgrounds expose the resolved
// frame, then the inherited cell surface only when the frame is transparent.
fn figureCaptionPaint(block: model.Block, inherited_background: ?[3]u8) !SpanContainerPaint {
    if (comptime @hasField(model.Block, "figure")) if (block.figure) |figure| return figureValueCaptionPaint(figure, inherited_background);
    return error.InvalidPresentation;
}
fn figureValueCaptionPaint(figure: anytype, inherited_background: ?[3]u8) !SpanContainerPaint {
        {
            const T = @import("blob_encoder").presentation_types;
            if (!T.validFigureColor(figure.caption_foreground) or !T.validFigureColor(figure.caption_background) or !T.validFigureColor(figure.frame_background))
                return error.InvalidPresentation;
            const foreground: ?[3]u8 = if (figure.caption_foreground.kind == .rgb) canonicalRgb(figure.caption_foreground.value) else null;
            const background: ?[3]u8 = switch (figure.caption_background.kind) {
                .rgb => canonicalRgb(figure.caption_background.value),
                .native_theme => null,
                .transparent => switch (figure.frame_background.kind) {
                    .rgb => canonicalRgb(figure.frame_background.value),
                    .native_theme => null,
                    .transparent => inherited_background,
                },
            };
            // Zero-alpha ink is retained in data and logical text; terminals do
            // not model alpha glyph coverage. Explicit child RGB still wins.
            return .{ .foreground = foreground, .background = background };
        }
}

// Rich caption blocks keep their own internal structure. Only the final block
// renderer terminator is removed when embedding this fragment in its owner.
fn richCaptionText(w: *std.Io.Writer, blocks: []const model.Block, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext) anyerror!void {
    if (context.content_depth >= 16) return error.InvalidPresentation;
    var child = context;
    child.content_depth += 1;
    if (child.cell_style) |*style| style.content_depth = child.content_depth;
    var rendered: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer rendered.deinit();
    // This logical fragment does not manufacture independent poem coordinates.
    try blocksTextInContext(&rendered.writer, blocks, color, null, child);
    var end = rendered.written().len;
    if (end != 0 and rendered.written()[end - 1] == '\n') end -= 1;
    if (blocks.len != 0 and (blocks[blocks.len - 1].kind == .paragraph or blocks[blocks.len - 1].kind == .quotation) and end != 0 and rendered.written()[end - 1] == '\n') end -= 1;
    _ = projection;
    try w.writeAll(rendered.written()[0..end]);
}
fn figureText(w: *std.Io.Writer, figure: anytype, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext, ordinary: bool) anyerror!void {
    const style = context.cell_style orelse CellDisplayStyle{};
    try spansTextDisplayWithContinuation(w, &.{figure.image_span}, color, projection, false, style.background, style.header, null);
    const paint = try figureValueCaptionPaint(figure, style.background);
    if (figure.caption_blocks) |blocks| {
        if (figure.caption.len != 0) return error.InvalidPresentation;
        if (blocks.len != 0) try w.writeByte(' ');
        var caption_context = context;
        caption_context.container_paint = paint;
        caption_context.cell_style = .{ .background = paint.background, .foreground = paint.foreground, .header = style.header, .caption_paint = true };
        caption_context.alignments = null;
        // Caption alignment is data-preserved; no physical float projection.
        try richCaptionText(w, blocks, color, projection, caption_context);
    } else {
        const present = for (figure.caption) |span| {
            if (span.image != null or span.kind == .line_break or span.text.len != 0 or span.trail.len != 0) break true;
        } else false;
        if (present) try w.writeByte(' ');
        try spansTextDisplayWithPaint(w, figure.caption, color, projection, ordinary, null, style.header, null, paint);
    }
}
fn flowText(w: *std.Io.Writer, parts: anytype, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext, paragraph: bool) anyerror!void {
    if (context.content_depth >= 16) return error.InvalidPresentation;
    var child = context;
    child.content_depth += 1;
    var state: SpanDisplayState = .{};
    try flowPartsText(w, parts, color, projection, child, paragraph, &state);
}
fn flowPartsText(w: *std.Io.Writer, parts: anytype, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext, paragraph: bool, state: *SpanDisplayState) anyerror!void {
    const T = @import("blob_encoder").presentation_types;
    const style = context.cell_style orelse CellDisplayStyle{};
    for (parts) |part| {
        if (!T.validFlowPart(part)) return error.InvalidPresentation;
        switch (part.kind) {
            .@"inline" => try spansTextDisplayWithState(w, part.spans, color, projection, paragraph, style.background, style.header, null, context.container_paint orelse .{ .foreground = style.foreground }, state),
            .figure => {
                try figureText(w, part.figure.?, color, projection, context, paragraph);
                state.* = .{};
            },
            .scope => {
                if (context.content_depth >= 16) return error.InvalidPresentation;
                const scope = part.scope.?;
                var child = context;
                child.content_depth += 1;
                try scopeText(w, scope, color, projection, child, paragraph, state);
            },
        }
    }
}

fn scopeText(w: *std.Io.Writer, scope: anytype, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext, paragraph: bool, state: *SpanDisplayState) anyerror!void {
    const allocator = if (projection) |parent| parent.allocator else std.heap.smp_allocator;
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    var metadata: std.ArrayList(terminal.PoemLine) = .empty;
    defer metadata.deinit(allocator);
    var local_projection: PoemProjection = .{ .frame = &rendered, .allocator = allocator, .lines = &metadata, .table_columns = if (projection) |parent| parent.table_columns else null };
    try flowPartsText(&rendered.writer, scope.parts, color, if (projection != null) &local_projection else null, context, paragraph, state);
    // Each real LF starts a new UBA paragraph. Close/reopen this same compiled
    // scope, without changing source separators or claiming terminal bidi support.
    // Nested scope fragments have already closed their inner controls at each LF.
    const prefix: []const u8 = if (scope.mode == .isolate_override)
        (if (scope.resolved_direction == .rtl) "\u{2067}\u{202e}" else "\u{2066}\u{202d}")
    else if (scope.resolved_direction == .rtl) "\u{2067}" else "\u{2066}";
    const suffix: []const u8 = if (scope.mode == .isolate_override) "\u{202c}\u{2069}" else "\u{2069}";
    var source_start: usize = 0;
    var metadata_index: usize = 0;
    var first = true;
    var lines = std.mem.splitScalar(u8, rendered.written(), '\n');
    while (lines.next()) |line| {
        const current = if (projection) |parent| parent.frame.written() else "";
        const line_start = if (projection != null) if (std.mem.lastIndexOfScalar(u8, current, '\n')) |at| at + 1 else 0 else 0;
        const earlier = if (first and projection != null) current[line_start..] else "";
        // Record byte offsets include writer-owned controls; their cells are zero.
        while (metadata_index < metadata.items.len and metadata.items[metadata_index].offset == source_start) : (metadata_index += 1) {
            if (projection) |parent| {
                var point = metadata.items[metadata_index];
                point.offset = line_start;
                point.lead_bytes += earlier.len + prefix.len;
                point.lead_cells += terminal.cellWidth(earlier);
                point.continuation_left += terminal.cellWidth(earlier);
                if (parent.lines.items.len != 0 and parent.lines.items[parent.lines.items.len - 1].offset == point.offset) {
                    const previous = &parent.lines.items[parent.lines.items.len - 1];
                    if (previous.left != point.left or previous.right != point.right) {
                        previous.left = 0; previous.right = 0; previous.continuation_left = point.lead_cells;
                    }
                } else try parent.lines.append(parent.allocator, point);
            }
        }
        try w.writeAll(prefix);
        try w.writeAll(line);
        try w.writeAll(suffix);
        source_start += line.len;
        if (source_start < rendered.written().len) { try w.writeByte('\n'); source_start += 1; }
        first = false;
    }
    if (metadata_index != metadata.items.len) return error.InvalidPresentation;
}

fn blockFlowText(w: *std.Io.Writer, block: model.Block, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext) anyerror!bool {
    if (comptime @hasField(model.Block, "flow")) if (block.flow) |parts| {
        try flowText(w, parts, color, projection, context, block.kind == .paragraph or block.kind == .definition);
        return true;
    };
    return false;
}

fn blocksText(w: *std.Io.Writer, blocks: []const model.Block, color: bool) !void {
    return blocksTextProjected(w, blocks, color, null);
}
fn blocksTextProjected(w: *std.Io.Writer, blocks: []const model.Block, color: bool, projection: ?*PoemProjection) anyerror!void {
    return blocksTextInContext(w, blocks, color, projection, .{ .columns = if (projection) |value| value.table_columns else null });
}
fn listTableText(w: *std.Io.Writer, block: model.Block, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var marker: std.Io.Writer.Allocating = .init(a);
    if (block.number.len != 0) {
        try terminalText(&marker.writer, block.number);
        try marker.writer.writeAll(". ");
    } else try marker.writer.writeAll("• ");
    const indent = @as(usize, @min(block.depth, 12)) * 2;
    const prefix_cells = indent + terminal.cellWidth(marker.written());
    const available: ?usize = if (context.columns) |columns| columns -| prefix_cells else null;
    var rendered: std.Io.Writer.Allocating = .init(a);
    var metadata: std.ArrayList(terminal.PoemLine) = .empty;
    var local: PoemProjection = .{ .frame = &rendered, .allocator = a, .lines = &metadata, .table_columns = available };
    var inherited_style = context.cell_style;
    if (context.content_depth != 0) {
        if (inherited_style == null) inherited_style = .{};
        inherited_style.?.content_depth = context.content_depth;
    }
    try tableTextWidthInContextIndented(&rendered.writer, block.table.?, color, if (projection != null) &local else null, available, context.table_depth, inherited_style, 0);
    // The marker belongs to this item, not to every table continuation or row.
    // Prefix the finished grid so captions, stacked cells and wrapped rows keep
    // their geometry, while projection offsets still refer to the final buffer.
    var lines = std.mem.splitScalar(u8, rendered.written(), '\n');
    var source_offset: usize = 0;
    var metadata_index: usize = 0;
    var first = true;
    while (lines.next()) |line| {
        if (source_offset == rendered.written().len) break;
        const leading = if (first or line.len != 0) prefix_cells else 0;
        if (projection) |parent| {
            while (metadata_index < metadata.items.len and metadata.items[metadata_index].offset < source_offset) metadata_index += 1;
            const has_point = metadata_index < metadata.items.len and metadata.items[metadata_index].offset == source_offset;
            var point: terminal.PoemLine = if (has_point) metadata.items[metadata_index] else .{ .offset = 0 };
            if (has_point) metadata_index += 1;
            if (first or line.len != 0 or has_point) {
                point.offset = parent.frame.written().len;
                point.lead_bytes += if (first) indent + marker.written().len else leading;
                point.lead_cells += leading;
                point.continuation_left += leading;
                try parent.lines.append(parent.allocator, point);
            }
        }
        if (first) {
            try w.splatByteAll(' ', indent);
            try w.writeAll(marker.written());
        } else try w.splatByteAll(' ', leading);
        try w.writeAll(line);
        source_offset += line.len;
        if (source_offset < rendered.written().len) {
            try w.writeByte('\n');
            source_offset += 1;
        }
        first = false;
    }
}
fn alignedBlockText(w: *std.Io.Writer, block: model.Block, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rendered: std.Io.Writer.Allocating = .init(a);
    defer rendered.deinit();
    var metadata: std.ArrayList(terminal.PoemLine) = .empty;
    var local_projection: PoemProjection = .{ .frame = &rendered, .allocator = a, .lines = &metadata, .table_columns = context.columns };
    var local_context = context;
    local_context.alignment_suppressed = true;
    try blocksTextInContext(&rendered.writer, &.{block}, color, if (projection != null) &local_projection else null, local_context);
    const columns = context.columns.?;
    const rows = try terminal.wrapStyledProjected(a, rendered.written(), columns, metadata.items);
    for (rows, 0..) |row, index| {
        const visible = terminal.cellWidth(row.bytes);
        const leading = if (visible == 0) 0 else row.left + alignmentLeading(block.text_align, row, columns -| (row.left + row.right));
        if (projection) |parent| {
            if (row.bytes.len != 0 or index + 1 < rows.len) {
                // Prefix spaces belong to this buffered row, never semantic spans.
                try parent.lines.append(parent.allocator, .{ .offset = parent.frame.written().len, .lead_bytes = leading, .lead_cells = leading, .right = row.right });
            }
        }
        if (color and leading != 0) try w.writeAll("\x1b[0m");
        try w.splatByteAll(' ', leading);
        if (color) try row.carry.write(w);
        try w.writeAll(row.bytes);
        if (index + 1 < rows.len) try w.writeByte('\n');
    }
}
fn blocksTextInContext(w: *std.Io.Writer, blocks: []const model.Block, color: bool, projection: ?*PoemProjection, context: BlockDisplayContext) anyerror!void {
    var local_ordinal: usize = 0;
    const ordinal = context.ordinal orelse &local_ordinal;
    for (blocks) |block| {
        const figure_image = figureImageSpan(block);
        const has_flow = if (comptime @hasField(model.Block, "flow")) block.flow != null else false;
        if (comptime @hasField(model.Block, "flow")) if (has_flow and (block.spans.len != 0 or !@import("blob_encoder").presentation_types.validFlowContext(block.kind, block.depth, block.table != null, block.feature != null, figure_image != null, block.list_path))) return error.InvalidPresentation;
        if (projection) |p| if (p.float_flow) |flow| {
            const floating = if (block.table) |table| if (table.style) |style| style.float_side != null else false else false;
            if (flow.enabled and !flow.capturing and (flow.started or floating)) {
                flow.started = true;
                const start = p.frame.written().len;
                flow.capturing = true;
                flow.capturing_float = floating;
                defer { flow.capturing = false; flow.capturing_float = false; }
                var captured_context = context;
                captured_context.ordinal = ordinal;
                captured_context.alignment_suppressed = true;
                try blocksTextInContext(w, &.{block}, color, projection, captured_context);
                try flow.record(block, start);
                continue;
            }
        };
        // Figure text_align belongs to its caption, not the image/list prefix.
        // This logical projection makes no spatial caption-placement claim.
        if (context.alignments) |alignment| try alignment.record(if (figure_image != null or has_flow) null else block.text_align);
        if (block.kind == .blank) continue;
        if (figure_image == null and !has_flow and !context.alignment_suppressed and context.alignments == null and block.text_align != null and context.columns != null) {
            var aligned_context = context;
            aligned_context.ordinal = ordinal;
            try alignedBlockText(w, block, color, projection, aligned_context);
            continue;
        }
        if (block.kind == .rule) {
            const inherited_header = if (context.cell_style) |style| style.header else false;
            if (color and inherited_header) try w.writeAll("\x1b[1m");
            try w.writeAll("────────────────────────\n");
            if (color and inherited_header) try w.writeAll("\x1b[0m");
            continue;
        }
        if (block.table) |table| {
            if (block.kind == .list_item) {
                try listTableText(w, block, color, projection, context);
                continue;
            }
            if (colorSwatchRgb(block)) |rgb| {
                try w.splatByteAll(' ', @as(usize, @min(block.depth, 12)) * 2);
                if (color) try w.print("[\x1b[48;2;{d};{d};{d}m  \x1b[0m] ", .{ rgb[0], rgb[1], rgb[2] });
                const inherited_header = if (context.cell_style) |style| style.header else false;
                if (color and inherited_header) try w.writeAll("\x1b[1m");
                try w.print("Color sample {s}\n\n", .{block.feature.?.data});
                if (color and inherited_header) try w.writeAll("\x1b[0m");
            } else {
                const floated = if (projection) |p| if (p.float_flow) |flow| flow.capturing_float else false else false;
                var inherited_style = context.cell_style;
                if (context.content_depth != 0) {
                    if (inherited_style == null) inherited_style = .{};
                    inherited_style.?.content_depth = context.content_depth;
                }
                try tableTextWidthInContextIndented(w, table, color, projection, context.columns, context.table_depth, inherited_style, if (floated) 0 else 2);
            }
            continue;
        }
        if (color) if (context.cell_style) |style| if (style.header) try w.writeAll("\x1b[1m");
        try w.splatByteAll(' ', @as(usize, @min(block.depth, 12)) * 2);
        switch (block.kind) {
            .definition => {
                ordinal.* += 1;
                if (block.number.len != 0) {
                    try terminalText(w, block.number);
                    try w.writeAll(". ");
                } else try w.print("{d}. ", .{ordinal.*});
            },
            .example, .quotation => try w.writeAll("│ "),
            .list_item => if (block.number.len != 0) {
                try terminalText(w, block.number);
                try w.writeAll(". ");
            } else try w.writeAll("• "),
            .preformatted => try w.writeAll("    "),
            else => {},
        }
        const style = context.cell_style orelse CellDisplayStyle{};
        var detail_depth: ?u8 = if (block.kind == .example or block.kind == .quotation) block.depth else null;
        // Poem layout owns its source line spacing and projection metadata.
        if (detail_depth != null) for (block.spans) |span| {
            if (PoemInfo.parse(span.classes).marked) {
                detail_depth = null;
                break;
            }
        };
        if (try blockFlowText(w, block, color, projection, context)) {
        } else if (comptime @hasField(model.Block, "figure")) {
            if (block.figure) |figure| {
                if (block.spans.len != 0) return error.InvalidPresentation;
                try figureText(w, figure, color, projection, context, block.kind == .paragraph or block.kind == .definition);
            } else try spansTextDisplayWithPaint(w, block.spans, color, projection, block.kind == .paragraph or block.kind == .definition, style.background, style.header or (context.cell_style != null and block.kind == .heading), detail_depth, context.container_paint orelse .{ .foreground = style.foreground });
        } else try spansTextDisplayWithPaint(w, block.spans, color, projection, block.kind == .paragraph or block.kind == .definition, style.background, style.header or (context.cell_style != null and block.kind == .heading), detail_depth, context.container_paint orelse .{ .foreground = style.foreground });
        if (block.feature) |f| if (f.language.len != 0) {
            if (color and style.header) try w.writeAll("\x1b[1m");
            try w.writeAll("  [");
            try terminalText(w, f.language);
            try w.writeByte(']');
            if (color and style.header) try w.writeAll("\x1b[0m");
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
    if ((if (comptime @hasField(model.Block, "flow")) first.flow != null else false) or figureImageSpan(first) != null or first.kind != .heading or first.level != section.level) return null;
    var navigable = false;
    var explained = false;
    var advised = false;
    var styled_self = false;
    var styled = false;
    var image = false;
    for (first.spans) |span| {
        image = image or span.image != null;
        explained = explained or span.explanation.len != 0;
        advised = advised or span.tooltip != null;
        styled_self = styled_self or selfLinkHeadingSpan(span);
        styled = styled or (span.kind == .text and span.text.len != 0 and span.target.len == 0 and
            (span.bold or span.italic or span.code or span.small or span.superscript or span.subscript or
                span.strike or span.underline or span.foreground != null or span.background != null or span.font_scale != null or span.classes.len != 0 or
                span.language.len != 0 or span.direction.len != 0 or span.role != .normal));
        if (span.kind == .line_break and span.trail.len != 0) return null;
        if ((span.kind == .link or span.kind == .external_link) and
            span.target.len != 0 and (span.text.len != 0 or span.trail.len != 0)) navigable = true;
    }
    if (!navigable and !explained and !advised and !styled_self and !styled and !image and first.depth == 0) return null;
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
    if (sectionHeadingCompanion(section)) |spans| {
        // The companion owns the authored list indentation even when its rich
        // spans are consumed as the section label instead of an ordinary block.
        try w.splatByteAll(' ', @as(usize, @min(section.blocks[0].depth, 12)) * 2);
        try spansTextProjected(w, spans, color, projection);
    } else try terminalText(w, section.title);
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
    inline_seen: []bool,
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
            .inline_seen = try a.alloc(bool, if (observe) media.len else 0),
            .owners = std.StringHashMap(usize).init(a),
            .enabled = observe,
        };
        @memset(result.seen, false);
        @memset(result.inline_seen, false);
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
            if (span.image) |image| {
                self.finish(current);
                current = null;
                for (self.media, 0..) |item, index| {
                    if (item.kind == .image and std.mem.eql(u8, item.file, image.file)) {
                        self.inline_seen[index] = true;
                        if (image.alt) |alt| {
                            if (alt.len != 0 and sameCaption(alt, item.caption)) self.seen[index] = true;
                        }
                    }
                }
                continue;
            }
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
    const Observer = struct {
        owner: *VisibleMediaCaptions,
        fn spans(self: *@This(), values: []const model.Span) !bool {
            try self.owner.observeSpans(values);
            return false;
        }
    };
    fn observeTable(self: *VisibleMediaCaptions, table: model.Table, parent_depth: usize) anyerror!void {
        if (!self.enabled) return;
        var observer: Observer = .{ .owner = self };
        _ = try visitTableSpanListsAtDepth(table, &observer, parent_depth);
    }
    fn observeBlocks(self: *VisibleMediaCaptions, blocks: []const model.Block) anyerror!void {
        return self.observeBlocksAtDepth(blocks, 0);
    }
    fn observeBlocksAtDepth(self: *VisibleMediaCaptions, blocks: []const model.Block, depth: usize) anyerror!void {
        if (!self.enabled) return;
        var observer: Observer = .{ .owner = self };
        _ = try visitBlockSpanLists(blocks, &observer, depth);
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

// Reference bodies are emitted once by entryMetadataProjected. Suppress only
// an empty leaf placeholder when those bodies exist; retain parent headings.
fn emptyReferencePlaceholder(entry: model.Entry, index: usize) bool {
    const section = entry.sections[index];
    if (entry.references.len == 0 or section.blocks.len != 0 or !std.mem.eql(u8, section.title, "References")) return false;
    return index + 1 == entry.sections.len or entry.sections[index + 1].level <= section.level;
}

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
    if ((details or entry.kind == .alias or entry.kind == .supplemental) and entry.preamble_spans.len != 0) {
        try captions.emitSpans(w, entry.preamble_spans, color, projection);
        try w.writeByte('\n');
    }
    const organization = entry.organization;
    // An authored part of speech can have no meanings. Brief output must not
    // hide its stored body merely because that organization is now available.
    const summary_without_senses = organization.lexemes.len != 0 and !details and entry.kind == .language and blk: {
        for (organization.lexemes) |lexeme| if (lexeme.definitions.len != 0) break :blk false;
        break :blk true;
    };
    if (organization.lexemes.len == 0 or summary_without_senses) {
        const has_definitions = blk: {
            for (entry.sections) |section| for (section.blocks) |block| {
                if (block.kind == .definition) break :blk true;
            };
            break :blk false;
        };
        // Supplemental sections are the document body, not lexical supporting details.
        // Language entries still use their existing selective-definition summary.
        const show_sections = details or entry.kind == .supplemental or summary_without_senses or (entry.kind == .language and !has_definitions);
        for (entry.sections, 0..) |section, index| {
            if (details and emptyReferencePlaceholder(entry, index)) continue;
            if (!show_sections) {
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
                    if (companion != null) try captions.emitLabel(w, section, color, projection) else try terminalText(w, part.kind);
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
                    if (details) {
                        // Each detail stream follows source order. Merge them so
                        // nested list children stay after their containing item.
                        const streams = [_][]const usize{ sense.examples, sense.notes, sense.quotations };
                        var positions = [_]usize{ 0, 0, 0 };
                        while (true) {
                            var selected: ?usize = null;
                            for (streams, 0..) |stream, stream_index| {
                                if (positions[stream_index] == stream.len) continue;
                                if (selected == null or stream[positions[stream_index]] < streams[selected.?][positions[selected.?]]) selected = stream_index;
                            }
                            const stream_index = selected orelse break;
                            const i = streams[stream_index][positions[stream_index]];
                            positions[stream_index] += 1;
                            try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                        }
                    }
                }
                if (details) {
                    for (part.other_blocks) |i| {
                        if (rendered_companion and i == 0) continue;
                        try captions.emitBlocks(w, section.blocks[i..][0..1], color, projection);
                    }
                    for (part.related_sections) |i| {
                        if (!emptyReferencePlaceholder(entry, i)) try captions.emitSection(w, entry.sections[i], color, projection);
                    }
                }
            }
        }
        if (details) for (organization.other_sections) |i| {
            if (!emptyReferencePlaceholder(entry, i)) try captions.emitSection(w, entry.sections[i], color, projection);
        };
    }
    if (projection) |p| if (p.float_flow) |flow| try flow.stop();
    if (details) try entryMetadataProjected(w, entry, color, projection, &captions);
}

fn visitTableSpanLists(table: model.Table, visitor: anytype) anyerror!bool {
    return visitTableSpanListsAtDepth(table, visitor, 0);
}
fn visitTableSpanListsAtDepth(table: model.Table, visitor: anytype, parent_depth: usize) anyerror!bool {
    return visitTableSpanListsContent(table, visitor, parent_depth, 0);
}
fn visitFigureSpanLists(figure: anytype, visitor: anytype, table_depth: usize, content_depth: usize) anyerror!bool {
    if (try visitor.spans(&.{figure.image_span})) return true;
    if (figure.caption_blocks) |blocks| {
        if (figure.caption.len != 0 or content_depth >= 16) return error.InvalidPresentation;
        return visitBlockSpanListsContent(blocks, visitor, table_depth, content_depth + 1);
    }
    return visitor.spans(figure.caption);
}
fn visitTableSpanListsContent(table: model.Table, visitor: anytype, parent_depth: usize, content_depth: usize) anyerror!bool {
    if (parent_depth >= @import("blob_encoder").presentation_types.max_table_depth) return error.InvalidPresentation;
    const depth = parent_depth + 1;
    const caption_blocks: ?[]const model.Block = if (comptime @hasField(model.Table, "caption_blocks")) table.caption_blocks else null;
    if (caption_blocks) |blocks| {
        if (table.caption.len != 0 or content_depth >= 16) return error.InvalidPresentation;
        if (try visitBlockSpanListsContent(blocks, visitor, depth, content_depth + 1)) return true;
    } else if (try visitor.spans(table.caption)) return true;
    for (table.rows) |row| for (row.cells) |cell| {
        if (cell.blocks) |blocks| {
            if (try visitBlockSpanListsContent(blocks, visitor, depth, content_depth)) return true;
        } else {
            if (try visitor.spans(cell.spans)) return true;
            if (cell.nested_table) |child| if (try visitTableSpanListsContent(child, visitor, depth, content_depth)) return true;
        }
    };
    return false;
}
fn visitBlockSpanLists(blocks: []const model.Block, visitor: anytype, depth: usize) anyerror!bool {
    return visitBlockSpanListsContent(blocks, visitor, depth, 0);
}
fn visitBlockSpanListsContent(blocks: []const model.Block, visitor: anytype, depth: usize, content_depth: usize) anyerror!bool {
    for (blocks) |block| {
        if (comptime @hasField(model.Block, "flow")) if (block.flow) |parts| {
            if (content_depth >= 16 or block.spans.len != 0) return error.InvalidPresentation;
            if (try visitFlowSpanLists(parts, visitor, depth, content_depth + 1)) return true;
            continue;
        };
        if (comptime @hasField(model.Block, "figure")) if (block.figure) |figure| {
            if (block.spans.len != 0) return error.InvalidPresentation;
            if (try visitFigureSpanLists(figure, visitor, depth, content_depth)) return true;
            continue;
        };
        if (try visitor.spans(block.spans)) return true;
        if (block.table) |table| if (try visitTableSpanListsContent(table, visitor, depth, content_depth)) return true;
    }
    return false;
}

fn visitFlowSpanLists(parts: anytype, visitor: anytype, table_depth: usize, content_depth: usize) anyerror!bool {
    const T = @import("blob_encoder").presentation_types;
    for (parts) |part| {
        if (!T.validFlowPart(part)) return error.InvalidPresentation;
        switch (part.kind) {
            .@"inline" => if (try visitor.spans(part.spans)) return true,
            .figure => if (try visitFigureSpanLists(part.figure.?, visitor, table_depth, content_depth)) return true,
            .scope => {
                if (content_depth >= 16) return error.InvalidPresentation;
                if (try visitFlowSpanLists(part.scope.?.parts, visitor, table_depth, content_depth + 1)) return true;
            },
        }
    }
    return false;
}

// The details view visits compiled span lists without changing body text or links.
fn visitEntrySpanLists(entry: model.Entry, visitor: anytype) !bool {
    if (try visitor.spans(entry.display_title)) return true;
    if (try visitor.spans(entry.preamble_spans)) return true;
    for (entry.sections) |section| if (try visitBlockSpanLists(section.blocks, visitor, 0)) return true;
    for (entry.references) |reference| {
        if (reference.blocks) |blocks| {
            if (reference.spans.len != 0) return error.InvalidPresentation;
            if (try visitBlockSpanLists(blocks, visitor, 0)) return true;
        } else if (try visitor.spans(reference.spans)) return true;
    }
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

// Generic HTML advisory titles remain a separate type from abbreviation
// expansions. They are details only: never mutate main text, links or numbering.
const Advisory = struct { label: []const u8, tooltip: []const u8 };
const AdvisoryContext = struct {
    pub fn hash(_: @This(), item: Advisory) u64 {
        return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, item.label), item.tooltip);
    }
    pub fn eql(_: @This(), lhs: Advisory, rhs: Advisory) bool {
        return std.mem.eql(u8, lhs.label, rhs.label) and std.mem.eql(u8, lhs.tooltip, rhs.tooltip);
    }
};
fn effectiveAdvisory(span: model.Span) ?[]const u8 {
    // An image's own explicit title overrides enclosing advice; empty suppresses
    // it, while nonempty own advice remains available through Text details.
    var optional = span.tooltip;
    if (span.image) |image| if (image.tooltip) |own| { optional = own; };
    const value = optional orelse return null;
    return if (value.len == 0) null else value;
}
const Advisories = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Advisory) = .empty,
    seen: std.HashMapUnmanaged(Advisory, void, AdvisoryContext, 80) = .empty,
    fn init(allocator: std.mem.Allocator, entry: model.Entry) !Advisories {
        var result: Advisories = .{ .allocator = allocator };
        errdefer result.deinit();
        _ = try visitEntrySpanLists(entry, &result);
        return result;
    }
    fn deinit(self: *Advisories) void {
        self.seen.deinit(self.allocator);
        for (self.items.items) |item| self.allocator.free(item.label);
        self.items.deinit(self.allocator);
    }
    fn add(self: *Advisories, text: []const u8, tooltip: []const u8) !void {
        const label = std.mem.trim(u8, text, " \t\r\n");
        if (self.seen.contains(.{ .label = label, .tooltip = tooltip })) return;
        try self.seen.ensureUnusedCapacity(self.allocator, 1);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const item: Advisory = .{ .label = owned_label, .tooltip = tooltip };
        try self.items.append(self.allocator, item);
        self.seen.putAssumeCapacityNoClobber(item, {});
    }
    fn spans(self: *Advisories, values: []const model.Span) !bool {
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(self.allocator);
        var at: usize = 0;
        while (at < values.len) {
            const tooltip = effectiveAdvisory(values[at]) orelse { at += 1; continue; };
            label.clearRetainingCapacity();
            while (at < values.len) : (at += 1) {
                const candidate = effectiveAdvisory(values[at]) orelse break;
                if (!std.mem.eql(u8, candidate, tooltip)) break;
                const value = values[at];
                if (value.kind == .line_break) try label.append(self.allocator, '\n') else try label.appendSlice(self.allocator, value.text);
                try label.appendSlice(self.allocator, value.trail);
                if (value.image) |image| {
                    // This is details context only: do not invent/change alt,
                    // body glyphs, selection or the image's navigation action.
                    const alt = image.alt orelse "";
                    try label.appendSlice(self.allocator, if (std.mem.trim(u8, alt, " \t\r\n").len != 0) alt else image.file);
                }
            }
            // Description-only rows preserve valid advice on empty/whitespace
            // or break ranges without fabricating visible inline characters.
            try self.add(label.items, tooltip);
        }
        return false;
    }
    fn write(self: *const Advisories, w: *std.Io.Writer) !void {
        if (self.items.items.len == 0) return;
        try w.writeAll("\nText details\n");
        for (self.items.items) |item| {
            if (item.label.len != 0) {
                try terminalText(w, item.label);
                try w.writeAll(": ");
            }
            try terminalText(w, item.tooltip);
            try w.writeByte('\n');
        }
    }
};
fn entryHasAdvisories(entry: model.Entry) bool {
    const Presence = struct {
        fn spans(_: *@This(), values: []const model.Span) error{}!bool {
            for (values) |value| if (effectiveAdvisory(value) != null) return true;
            return false;
        }
    };
    var presence: Presence = .{};
    return visitEntrySpanLists(entry, &presence) catch unreachable;
}

fn entryMetadataProjected(w: *std.Io.Writer, entry: model.Entry, color: bool, projection: ?*PoemProjection, captions: *VisibleMediaCaptions) !void {
    if (projection) |p| if (p.float_flow) |flow| try flow.stop();
    // These references are emitted by this same details route below.
    for (entry.references) |ref| {
        if (ref.blocks) |blocks| {
            if (ref.spans.len != 0) return error.InvalidPresentation;
            try captions.observeBlocks(blocks);
        } else try captions.observeSpans(ref.spans);
    }
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
            if (ref.kind == .note) {
                const ordinal = ref.group_number orelse return error.InvalidPresentation;
                if (ref.group.len == 0) try w.print("[{d}] ", .{ordinal}) else {
                    try w.writeByte('[');
                    try terminalText(w, ref.group);
                    try w.print(" {d}] ", .{ordinal});
                }
                if (ref.blocks) |blocks| {
                    if (blocks.len != 0 and blocks[0].table != null) try w.writeByte('\n');
                }
            }
            if (ref.blocks) |blocks| {
                if (ref.spans.len != 0) return error.InvalidPresentation;
                if (blocks.len == 0) try w.writeByte('\n') else try blocksTextProjected(w, blocks, color, projection);
            } else {
                try spansTextDisplayProjected(w, ref.spans, color, projection, true);
                try w.writeByte('\n');
            }
        }
    }
    var abbreviations = try Abbreviations.init(std.heap.smp_allocator, entry);
    defer abbreviations.deinit();
    try abbreviations.write(w);
    var advisories = try Advisories.init(std.heap.smp_allocator, entry);
    defer advisories.deinit();
    try advisories.write(w);
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

test "detailed CLI keeps nested quotation children after their parent across detail streams" {
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "INTRO" }} },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &.{.{ .text = "SENSE_ONE" }} },
        .{ .kind = .quotation, .depth = 2, .list_path = "#*", .spans = &.{.{ .text = "QUOTE_PARENT", .italic = true }} },
        .{ .kind = .list_item, .depth = 3, .list_path = "#*#", .number = "1.1", .spans = &.{.{ .text = "NUMBERED_CHILD" }} },
        .{ .kind = .example, .depth = 2, .list_path = "#:", .spans = &.{.{ .text = "EXAMPLE_AFTER" }} },
        .{ .kind = .quotation, .depth = 2, .list_path = "#*", .spans = &.{.{ .text = "QUOTE_AFTER" }} },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .number = "2", .spans = &.{.{ .text = "SENSE_TWO" }} },
        .{ .kind = .example, .depth = 2, .list_path = "#:", .spans = &.{.{ .text = "SECOND_EXAMPLE" }} },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "OTHER_BLOCK" }} },
    };
    const sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
    const senses = [_]model.Sense{
        .{ .block = 1, .examples = &.{4}, .notes = &.{3}, .quotations = &.{ 2, 5 } },
        .{ .block = 6, .examples = &.{7} },
    };
    const lexemes = [_]model.Lexeme{.{ .language = "English", .kind = "Noun", .section = 0, .definitions = &senses, .introduction = &.{0}, .other_blocks = &.{8} }};
    const entry: model.Entry = .{ .title = "nested", .kind = .language, .language = "English", .sections = &sections, .organization = .{ .lexemes = &lexemes } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |color| {
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, color, true);
        var position: usize = 0;
        for ([_][]const u8{ "INTRO", "SENSE_ONE", "QUOTE_PARENT", "NUMBERED_CHILD", "EXAMPLE_AFTER", "QUOTE_AFTER", "SENSE_TWO", "SECOND_EXAMPLE", "OTHER_BLOCK" }) |text| {
            const found = std.mem.indexOfPos(u8, out.written(), position, text);
            try std.testing.expect(found != null);
            position = found.? + text.len;
        }
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "      1.1. NUMBERED_CHILD") != null);
        if (color) try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3m") != null);
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, color, false);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "SENSE_ONE") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "SENSE_TWO") != null);
        for ([_][]const u8{ "INTRO", "QUOTE_PARENT", "NUMBERED_CHILD", "EXAMPLE_AFTER", "QUOTE_AFTER", "SECOND_EXAMPLE", "OTHER_BLOCK" }) |text| try std.testing.expect(std.mem.indexOf(u8, out.written(), text) == null);
    }
}


test "default text retains unorganized nested lists without classifying meanings" {
    const headword = [_]model.Span{.{ .text = "assamese", .bold = true }};
    const meaning = [_]model.Span{.{ .kind = .link, .text = "অসমীয়া", .target = "অসমীয়া" }};
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &headword },
        .{ .kind = .list_item, .depth = 2, .list_path = ":#", .number = "1", .spans = &meaning },
    };
    const sections = [_]model.Section{
        .{ .level = 2, .title = "নাম", .blocks = &blocks },
        .{ .level = 2, .title = "বিশেষণ", .blocks = &blocks },
    };
    const entry: model.Entry = .{ .title = "assamese", .kind = .language, .language = "Unclassified", .sections = &sections };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryTextWithDetails(&out.writer, entry, false, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "নাম") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "বিশেষণ") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "1. অসমীয়া"));
    try std.testing.expect(blocks[1].kind == .list_item);
    try std.testing.expectEqualStrings(":#", blocks[1].list_path);
    try std.testing.expectEqual(@as(usize, 0), entry.organization.lexemes.len);
}

test "default text retains complete body when authored lexemes have no senses" {
    const sections = [_]model.Section{
        .{ .level = 2, .title = "English", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "ENTRY_PREFACE" }} }} },
        .{ .level = 3, .title = "Verb", .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .text = "HEADWORD", .bold = true }} },
            .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &.{.{ .text = "Meaning not yet supplied." }} },
        } },
        .{ .level = 4, .title = "Conjugation", .blocks = &.{.{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{.{ .kind = .link, .text = "FORMS", .target = "forms" }} }} },
        .{ .level = 3, .title = "Noun", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "NOUN_SUPPORT" }} }} },
    };
    const lexemes = [_]model.Lexeme{
        .{ .language = "English", .kind = "Verb", .section = 1, .introduction = &.{ 0, 1 }, .related_sections = &.{2} },
        .{ .language = "English", .kind = "Noun", .section = 3, .introduction = &.{0} },
    };
    var entry: model.Entry = .{ .title = "term", .kind = .language, .language = "English", .sections = &sections };
    var unorganized: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unorganized.deinit();
    var organized: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer organized.deinit();
    for ([_]bool{ false, true }) |color| {
        unorganized.clearRetainingCapacity();
        organized.clearRetainingCapacity();
        entry.organization = .{};
        try entryTextWithDetails(&unorganized.writer, entry, color, true);
        entry.organization = .{ .lexemes = &lexemes, .other_sections = &.{0} };
        try entryTextWithDetails(&organized.writer, entry, color, false);
        try std.testing.expectEqualStrings(unorganized.written(), organized.written());
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, organized.written(), "Meaning not yet supplied."));
        for (entry.organization.lexemes) |lexeme| try std.testing.expectEqual(@as(usize, 0), lexeme.definitions.len);
    }
}

test "default summary keeps real senses when another authored lexeme has none" {
    const sections = [_]model.Section{
        .{ .level = 3, .title = "Verb", .blocks = &.{.{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &.{.{ .text = "Meaning not yet supplied." }} }} },
        .{ .level = 3, .title = "Noun", .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .text = "NOUN_INTRODUCTION" }} },
            .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &.{.{ .text = "The actual meaning." }} },
        } },
    };
    const lexemes = [_]model.Lexeme{
        .{ .language = "English", .kind = "Verb", .section = 0, .introduction = &.{0} },
        .{ .language = "English", .kind = "Noun", .section = 1, .introduction = &.{0}, .definitions = &.{.{ .block = 1 }} },
    };
    const entry: model.Entry = .{ .title = "term", .kind = .language, .language = "English", .sections = &sections, .organization = .{ .lexemes = &lexemes } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |color| {
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, color, false);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "The actual meaning.") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "NOUN_INTRODUCTION") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "Meaning not yet supplied.") == null);
    }
}

test "default text retains selective definitions when organization is absent" {
    const support = [_]model.Span{.{ .text = "support-only paragraph" }};
    const meaning = [_]model.Span{.{ .text = "recognized meaning" }};
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &support },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &meaning },
    };
    const sections = [_]model.Section{.{ .level = 2, .title = "Noun", .blocks = &blocks }};
    const entry: model.Entry = .{ .title = "term", .kind = .language, .language = "English", .sections = &sections };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryTextWithDetails(&out.writer, entry, false, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "recognized meaning") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "support-only paragraph") == null);
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

/// Empty authored headings remain visible; synthetic empty labels have no IDs.
pub fn foldedSectionVisible(section: model.Section) bool {
    return section.blocks.len != 0 or section.anchor.len != 0 or section.anchor_fallback.len != 0;
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
        if (!foldedSectionVisible(section)) continue;
        var meaning = false;
        for (section.blocks) |block| if (block.kind == .definition) {
            meaning = true;
            break;
        };
        const initially_closed = if (preferences.details) false else if (std.mem.startsWith(u8, section.title, "Pronunciation")) preferences.collapse_pronunciation else if (std.mem.startsWith(u8, section.title, "Etymology")) preferences.collapse_etymology else if (meaning) preferences.collapse_notes else preferences.collapse_other;
        const toggled = std.mem.indexOfScalar(usize, expanded, index) != null;
        const closed = section.blocks.len != 0 and (initially_closed != toggled);
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
    if (projection) |p| if (p.float_flow) |flow| try flow.stop();
    if (preferences.details) {
        try entryMetadataProjected(w, entry, color, projection, &captions);
    } else if (entryHasAdvisories(entry)) {
        try w.writeAll(if (entry.media.len != 0 or entry.references.len != 0) "\n  d: text details, media and references\n" else "\n  d: text details\n");
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
        try std.testing.expect(!selfLinkHeadingSpan(spans[0]));
        // Nonempty authored classes retain presentation even without a self-link pair.
        try std.testing.expectEqual(classes.len != 0, sectionHeadingCompanion(section) != null);
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

test "unlinked styled heading companions render once and keep title and level guards" {
    const styles = [_]model.Span{
        .{ .text = "Noun", .bold = true },
        .{ .text = "Noun", .italic = true },
        .{ .text = "Noun", .code = true },
        .{ .text = "Noun", .small = true },
        .{ .text = "Noun", .font_scale = 1.0 / 1.2 },
        .{ .text = "Noun", .font_scale = 1.2 },
        .{ .text = "Noun", .font_scale = 0 },
        .{ .text = "Noun", .superscript = true },
        .{ .text = "Noun", .subscript = true },
        .{ .text = "Noun", .strike = true },
        .{ .text = "Noun", .underline = true },
        .{ .text = "Noun", .foreground = "#ff0000" },
        .{ .text = "Noun", .background = "#ff0000" },
        .{ .text = "Noun", .classes = "label" },
        .{ .text = "Noun", .language = "fr" },
        .{ .text = "Noun", .direction = "rtl" },
        .{ .text = "Noun", .role = .label },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (styles) |style| {
        const heading = [_]model.Span{style};
        const meaning = [_]model.Span{.{ .text = "Definition." }};
        const blocks = [_]model.Block{
            .{ .kind = .heading, .level = 3, .spans = &heading },
            .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &meaning },
        };
        const section: model.Section = .{ .level = 3, .title = "Noun", .blocks = &blocks };
        const entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .sections = &.{section} };
        try std.testing.expect(sectionHeadingCompanion(section) != null);
        var wrong = section;
        wrong.title = "Other";
        try std.testing.expect(sectionHeadingCompanion(wrong) == null);
        wrong = section;
        wrong.level = 2;
        try std.testing.expect(sectionHeadingCompanion(wrong) == null);
        for ([_]bool{ false, true }) |color| for ([_]bool{ false, true }) |folded| {
            out.clearRetainingCapacity();
            if (folded) _ = try entryTextFolded(&out, entry, color, .{ .details = true }, &.{}, 0) else try entryText(&out.writer, entry, color);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Noun"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "Definition."));
            if (color and style.font_scale != null and style.font_scale.? > 0 and style.font_scale.? < 1) try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2mNoun") != null);
            if (color and style.italic) try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3mNoun") != null);
            if (color and style.foreground != null) try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[38;2;255;0;0mNoun") != null);
            if (color and style.background != null) {
                const at = std.mem.indexOf(u8, out.written(), "Noun").?;
                try std.testing.expectEqual([3]u8{ 255, 0, 0 }, TypedColorOutputTest.at(out.written(), at).background.?);
                try std.testing.expectEqual([3]u8{ 0, 0, 0 }, TypedColorOutputTest.at(out.written(), at).foreground.?);
            }
        };
    }
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

test "reference display collapses ordinary whitespace and preserves code and Poem" {
    const ordinary = [_]model.Span{
        .{ .text = "one  " },
        .{ .kind = .link, .text = " two", .target = "Two", .trail = "  " },
        .{ .text = "three\t\tfour" },
    };
    const code = [_]model.Span{.{ .text = "code  words", .code = true }};
    const poem = [_]model.Span{.{ .text = "verse  words", .classes = "wikidict-poem" }};
    const references = [_]model.Reference{
        .{ .number = 1, .group_number = 1, .spans = &ordinary },
        .{ .number = 2, .group_number = 2, .spans = &code },
        .{ .number = 3, .group_number = 3, .spans = &poem },
    };
    const entry: model.Entry = .{ .title = "entry", .kind = .citations, .references = &references };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[1] one two three four\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[2] code  words\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[3] verse  words\n") != null);
    try std.testing.expectEqualStrings("one  ", ordinary[0].text);
    try std.testing.expectEqualStrings(" two", ordinary[1].text);
    try std.testing.expectEqualStrings("  ", ordinary[1].trail);
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

test "list table markers share the first row without marking continuation tables" {
    const types = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    terminal.initLocale();
    const cells = [_]types.Cell{.{ .spans = &.{.{ .text = "payload" }} }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const table: model.Table = .{ .rows = &rows };
    for ([_]bool{ false, true }) |color| {
        for ([_][]const u8{ "", "3.2" }) |number| {
            const item: model.Block = .{ .kind = .list_item, .depth = 2, .list_path = "**", .number = number, .table = table };
            const continuation: model.Block = .{ .kind = .table, .depth = 2, .list_path = "**", .table = table };
            var text: std.Io.Writer.Allocating = .init(a);
            defer text.deinit();
            try blocksText(&text.writer, &.{ item, continuation }, color);
            const visible = try NarrowTableTest.plain(a, text.written());
            defer a.free(visible);
            const prefix = if (number.len == 0) "    • │ payload │\n" else "    3.2. │ payload │\n";
            try std.testing.expect(std.mem.startsWith(u8, visible, prefix));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, if (number.len == 0) "• " else "3.2. "));
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, visible, "payload"));
            var legacy: std.Io.Writer.Allocating = .init(a);
            defer legacy.deinit();
            try tableText(&legacy.writer, table, color, null);
            try std.testing.expect(std.mem.endsWith(u8, text.written(), legacy.written()));
            try std.testing.expectEqualStrings("**", item.list_path);
            try std.testing.expectEqualStrings("payload", item.table.?.rows[0].cells[0].spans[0].text);
        }
    }
}

test "list table captions and narrow styled grids preserve marker and projection geometry" {
    const types = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    terminal.initLocale();
    const caption = [_]model.Span{
        .{ .text = "Caption" }, .{ .kind = .line_break },
        .{ .kind = .line_break, .classes = "wikidict-poem wikidict-poem-indent-5" },
        .{ .text = "Second", .classes = "wikidict-poem wikidict-poem-indent-2" }, .{ .kind = .line_break },
        .{ .text = "RTL", .classes = "wikidict-poem wikidict-poem-indent-3 wikidict-poem-dir-rtl" },
    };
    const content = [_]model.Span{.{ .kind = .link, .text = "猫éABCDEFGHIJKLMNO payload tail", .target = "preserved target", .bold = true }};
    const cells = [_]types.Cell{.{ .spans = &content, .background = "#aabbcc" }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const block: model.Block = .{ .kind = .list_item, .depth = 1, .list_path = "*", .table = .{ .caption = &caption, .rows = &rows } };
    for ([_]bool{ false, true }) |color| for ([_]usize{ 36, 76, 116 }) |width| {
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        var metadata: std.ArrayList(terminal.PoemLine) = .empty;
        defer metadata.deinit(a);
        var projection: PoemProjection = .{ .frame = &text, .allocator = a, .lines = &metadata, .table_columns = width };
        try blocksTextProjected(&text.writer, &.{block}, color, &projection);
        const visible = try NarrowTableTest.plain(a, text.written());
        defer a.free(visible);
        try std.testing.expect(std.mem.startsWith(u8, visible, "  • Caption\n\n    Second\n    RTL\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "• "));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "tail"));
        var empty_indented = false;
        var second_indented = false;
        var rtl_indented = false;
        for (metadata.items) |point| {
            empty_indented = empty_indented or (point.left == 5 and point.lead_cells == 0);
            second_indented = second_indented or (point.left == 2 and point.lead_cells == 4);
            rtl_indented = rtl_indented or (point.right == 3 and point.lead_cells == 4);
        }
        try std.testing.expect(empty_indented and second_indented and rtl_indented);
        const wrapped = try terminal.wrapStyledProjected(a, text.written(), width, metadata.items);
        defer a.free(wrapped);
        var first = true;
        var marker_count: usize = 0;
        for (wrapped) |line| {
            try std.testing.expect(terminal.cellWidth(line.bytes) + line.left + line.right <= width);
            marker_count += std.mem.count(u8, line.bytes, "• ");
            if (first) try std.testing.expect(std.mem.startsWith(u8, line.bytes, "  • Caption"));
            first = false;
        }
        try std.testing.expectEqual(@as(usize, 1), marker_count);
        try std.testing.expectEqualStrings("preserved target", content[0].target);
        try std.testing.expectEqualStrings("#aabbcc", cells[0].background.?);
        try std.testing.expect(content[0].bold);
    };
}

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

const TypedColorOutputTest = struct {
    const Colors = struct { foreground: ?[3]u8 = null, background: ?[3]u8 = null };
    // Independent observation of renderer-emitted color and reset atoms only.
    fn at(text: []const u8, limit: usize) Colors {
        var colors: Colors = .{};
        var pos: usize = 0;
        while (pos < limit) {
            if (terminal.sgrLength(text[pos..])) |n| {
                const code = text[pos .. pos + n];
                if (std.mem.eql(u8, code, "\x1b[0m")) colors = .{} else {
                    const foreground = std.mem.startsWith(u8, code, "\x1b[38;2;");
                    if (foreground or std.mem.startsWith(u8, code, "\x1b[48;2;")) {
                        var values = std.mem.splitScalar(u8, code[7 .. code.len - 1], ';');
                        const rgb: [3]u8 = .{
                            std.fmt.parseInt(u8, values.next().?, 10) catch unreachable,
                            std.fmt.parseInt(u8, values.next().?, 10) catch unreachable,
                            std.fmt.parseInt(u8, values.next().?, 10) catch unreachable,
                        };
                        if (foreground) colors.foreground = rgb else colors.background = rgb;
                    }
                }
                pos += n;
            } else pos += 1;
        }
        return colors;
    }
    fn fill(text: []const u8, left: usize, right: usize, rgb: [3]u8) !void {
        var pos = left;
        var visible: usize = 0;
        while (pos < right) {
            if (terminal.sgrLength(text[pos..])) |n| pos += n else {
                try std.testing.expectEqual(rgb, at(text, pos).background.?);
                pos += std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
                visible += 1;
            }
        }
        try std.testing.expect(visible >= 2); // Includes both cell padding spaces.
    }
};

test "typed span foreground preserves plain text links and truecolor wrap state" {
    const a = std.testing.allocator;
    const spans = [_]model.Span{
        .{ .text = "green", .foreground = "#008000" },
        .{ .kind = .link, .text = "blue", .target = "same target", .foreground = "#1c39bb", .italic = true },
        .{ .text = "plain" },
        .{ .text = "invalid", .foreground = "red" },
    };
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try spansText(&plain.writer, &spans, false);
    try spansText(&styled.writer, &spans, true);
    try std.testing.expectEqualStrings("greenblueplaininvalid", plain.written());
    const visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    try std.testing.expectEqual([3]u8{ 0, 128, 0 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "green").?).foreground.?);
    try std.testing.expectEqual([3]u8{ 28, 57, 187 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "blue").?).foreground.?);
    try std.testing.expect(TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "plain").?).foreground == null);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[36m") == null);
    try std.testing.expectEqualStrings("same target", spans[1].target);
    for ([_]?[]const u8{ null, "red", "#FFF000", "#fff", "#ffff0000", "#gggggg", "#ffff00;" }) |invalid| {
        try std.testing.expect(canonicalRgb(invalid) == null);
    }
    const long = [_]model.Span{.{ .text = "ABCDEFGHIJKLMNO", .foreground = "#010924", .bold = true }};
    styled.clearRetainingCapacity();
    try spansText(&styled.writer, &long, true);
    const wrapped = try terminal.wrapStyled(a, styled.written(), 4);
    defer a.free(wrapped);
    try std.testing.expect(wrapped.len >= 3);
    try std.testing.expectEqual([3]u8{ 1, 9, 36 }, wrapped[1].carry.foreground.?);
    try std.testing.expect(wrapped[1].carry.bold and !wrapped[1].carry.strike and !wrapped[1].carry.link);
}

test "typed table backgrounds cover all Bleoh cells padding wraps and rowspans without changing plain output" {
    const types = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    terminal.initLocale();
    const labels = [_][]const u8{ "blæc", "grǣg", "hwīt", "seolfor", "gold", "rēod", "basu", "hǣwen", "grēne", "geolu", "geolorēad" };
    const colors = [_][]const u8{ "#000000", "#808080", "#ffffff", "#c0c0c0", "#ffd700", "#ff0000", "#800080", "#0000ff", "#008000", "#ffff00", "#ffa500" };
    var label_spans: [11][1]model.Span = undefined;
    const blank = [_]model.Span{.{ .text = "\u{a0}" }};
    var cells: [11][2]types.Cell = undefined;
    var rows: [11]types.Row = undefined;
    for (labels, colors, 0..) |label, background, i| {
        label_spans[i] = .{.{ .kind = .link, .text = label, .target = if (i == 3) "Seolfor" else label }};
        cells[i] = .{ .{ .spans = &label_spans[i], .background = "#eeeeee" }, .{ .spans = &blank, .background = background } };
        rows[i] = .{ .cells = &cells[i] };
    }
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try tableText(&plain.writer, .{ .rows = &rows }, false, null);
    try tableText(&styled.writer, .{ .rows = &rows }, true, null);
    const visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain.written(), 0x1b) == null);
    var lines = std.mem.splitScalar(u8, styled.written(), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const first = std.mem.indexOf(u8, line, "│").?;
        const middle = std.mem.indexOfPos(u8, line, first + "│".len, "│").?;
        const last = std.mem.indexOfPos(u8, line, middle + "│".len, "│").?;
        try TypedColorOutputTest.fill(line, first + "│".len, middle, .{ 238, 238, 238 });
        try TypedColorOutputTest.fill(line, middle + "│".len, last, canonicalRgb(colors[count]).?);
        for ([_]usize{ first, middle, last }) |position| try std.testing.expect(TypedColorOutputTest.at(line, position).background == null);
        try std.testing.expect(std.mem.indexOf(u8, line, labels[count]) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\u{a0}") != null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 11), count); // Eleven label cells + eleven swatches.
    try std.testing.expectEqualStrings("Seolfor", label_spans[3][0].target);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "Color sample") == null);
    for (&cells) |*row| {
        for (row) |*cell| cell.background = null;
    }
    var baseline: std.Io.Writer.Allocating = .init(a);
    defer baseline.deinit();
    try tableText(&baseline.writer, .{ .rows = &rows }, false, null);
    try std.testing.expectEqualStrings(baseline.written(), plain.written());

    const long = [_]model.Span{.{ .text = "ABCDEFGH 猫é end", .kind = .link, .target = "unchanged", .foreground = "#010924", .bold = true, .code = true }};
    const first = [_]types.Cell{ .{ .spans = &long, .rowspan = 2, .background = "#01796f" }, .{ .spans = &.{.{ .text = "other" }}, .background = "#ff4040" } };
    const second = [_]types.Cell{.{ .spans = &.{.{ .text = "next" }} }};
    const spanning = [_]types.Row{ .{ .cells = &first }, .{ .cells = &second } };
    plain.clearRetainingCapacity();
    styled.clearRetainingCapacity();
    var pm: std.ArrayList(terminal.PoemLine) = .empty;
    defer pm.deinit(a);
    var sm: std.ArrayList(terminal.PoemLine) = .empty;
    defer sm.deinit(a);
    var pp: PoemProjection = .{ .frame = &plain, .allocator = a, .lines = &pm, .table_columns = 20 };
    var sp: PoemProjection = .{ .frame = &styled, .allocator = a, .lines = &sm, .table_columns = 20 };
    try tableText(&plain.writer, .{ .rows = &spanning }, false, &pp);
    try tableText(&styled.writer, .{ .rows = &spanning }, true, &sp);
    const unstyled = try NarrowTableTest.plain(a, styled.written());
    defer a.free(unstyled);
    try std.testing.expectEqualStrings(plain.written(), unstyled);
    try std.testing.expect(try NarrowTableTest.framed(unstyled, 20) > 2);
    var wrapped_lines = std.mem.splitScalar(u8, styled.written(), '\n');
    while (wrapped_lines.next()) |line| {
        if (line.len == 0) continue;
        const left = std.mem.indexOf(u8, line, "│").?;
        const right = std.mem.indexOfPos(u8, line, left + "│".len, "│").?;
        try TypedColorOutputTest.fill(line, left + "│".len, right, .{ 1, 121, 111 });
    }
    const ordinary = [_]model.Span{.{ .text = "outside" }};
    try spansText(&styled.writer, &ordinary, true);
    const end = std.mem.lastIndexOf(u8, styled.written(), "outside").?;
    try std.testing.expect(TypedColorOutputTest.at(styled.written(), end).background == null);
    try std.testing.expect(TypedColorOutputTest.at(styled.written(), end).foreground == null);
}

test "section heading companions retain authored depth once through plain colored and folded output" {
    const a = std.testing.allocator;
    const title = "Se beiga la conchugazión benasquesa 猫.";
    const rich = [_]model.Span{
        .{ .text = "Se beiga ", .italic = true },
        .{ .kind = .link, .text = "la conchugazión benasquesa 猫", .target = "templlar/conj.BEN", .bold = true, .italic = true, .foreground = "#01796f" },
        .{ .text = ".", .italic = true },
    };
    const plain = [_]model.Span{.{ .text = "Plain indented" }};
    const heading_only = [_]model.Block{.{ .kind = .heading, .level = 4, .depth = 1, .list_path = ":", .spans = &rich }};
    const plain_only = [_]model.Block{.{ .kind = .heading, .level = 4, .depth = 1, .list_path = ":", .spans = &plain }};
    const section: model.Section = .{ .level = 4, .title = title, .blocks = &heading_only };
    const plain_section: model.Section = .{ .level = 4, .title = "Plain indented", .blocks = &plain_only };
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    try std.testing.expect(sectionHeadingCompanion(plain_section) != null);
    var zero_blocks = heading_only;
    zero_blocks[0].depth = 0;
    zero_blocks[0].list_path = "";
    const zero: model.Section = .{ .level = 4, .title = title, .blocks = &zero_blocks };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try sectionTextProjected(&out.writer, section, false, null);
    try std.testing.expectEqualStrings("\n  Se beiga la conchugazión benasquesa 猫.\n", out.written());
    out.clearRetainingCapacity();
    try sectionTextProjected(&out.writer, plain_section, false, null);
    try std.testing.expectEqualStrings("\n  Plain indented\n", out.written());
    out.clearRetainingCapacity();
    try sectionTextProjected(&out.writer, zero, false, null);
    try std.testing.expectEqualStrings("\nSe beiga la conchugazión benasquesa 猫.\n", out.written());
    const sections = [_]model.Section{ section, .{ .level = 3, .title = "After", .blocks = &.{} } };
    const entry: model.Entry = .{ .title = "templlar", .kind = .language, .language = "aragonés", .sections = &sections };
    for ([_]bool{ false, true }) |folded| {
        var expected: std.Io.Writer.Allocating = .init(a);
        defer expected.deinit();
        if (folded) _ = try entryTextFolded(&expected, entry, false, .{ .details = true }, &.{}, 0) else try entryText(&expected.writer, entry, false);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, expected.written(), title));
        try std.testing.expect(std.mem.indexOf(u8, expected.written(), "  Se beiga la conchugazión benasquesa 猫.") != null);
        out.clearRetainingCapacity();
        if (folded) _ = try entryTextFolded(&out, entry, true, .{ .details = true }, &.{}, 0) else try entryText(&out.writer, entry, true);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[38;2;1;121;111m") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[1m") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3m") != null);
        var stripped: std.Io.Writer.Allocating = .init(a);
        defer stripped.deinit();
        var pos: usize = 0;
        while (pos < out.written().len) {
            if (terminal.sgrLength(out.written()[pos..])) |n| pos += n else {
                try stripped.writer.writeByte(out.written()[pos]);
                pos += 1;
            }
        }
        try std.testing.expectEqualStrings(expected.written(), stripped.written());
    }
    try std.testing.expectEqualStrings("templlar/conj.BEN", rich[1].target);
    try std.testing.expectEqualStrings("#01796f", rich[1].foreground.?);
    try std.testing.expect(rich[1].bold and rich[1].italic);
}

test "typed span background paints trails spaces wraps and restores the outer cell base" {
    const types = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    const spans = [_]model.Span{
        .{ .kind = .link, .text = "inner", .trail = "s", .target = "Unchanged", .background = "#ff0000", .foreground = "#0000ff" },
        .{ .text = "  ", .background = "#008000" },
        .{ .text = "outer" },
        .{ .kind = .line_break, .trail = "trail", .background = "#ff0000" },
        .{ .text = "after" },
    };
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try spansText(&plain.writer, &spans, false);
    try spansText(&styled.writer, &spans, true);
    try std.testing.expectEqualStrings("inners  outer\ntrailafter", plain.written());
    const visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    const inner = std.mem.indexOf(u8, styled.written(), "inner").?;
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, TypedColorOutputTest.at(styled.written(), inner).background.?);
    const link_trail = std.mem.indexOfPos(u8, styled.written(), inner + 5, "s").?;
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, TypedColorOutputTest.at(styled.written(), link_trail).background.?);
    const spaces = std.mem.indexOf(u8, styled.written(), "  ").?;
    try std.testing.expectEqual([3]u8{ 0, 128, 0 }, TypedColorOutputTest.at(styled.written(), spaces).background.?);
    try std.testing.expect(TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "outer").?).background == null);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "trail").?).background.?);
    try std.testing.expect(TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "after").?).background == null);
    try std.testing.expectEqualStrings("Unchanged", spans[0].target);

    const painted_spaces = [_]model.Span{ .{ .text = "  ", .background = "#008000" }, .{ .text = "body" } };
    styled.clearRetainingCapacity();
    try spansTextDisplayProjected(&styled.writer, &painted_spaces, true, null, true);
    const painted_visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(painted_visible);
    try std.testing.expectEqualStrings("  body", painted_visible);
    plain.clearRetainingCapacity();
    try spansTextDisplayProjected(&plain.writer, &painted_spaces, false, null, true);
    try std.testing.expectEqualStrings(plain.written(), painted_visible);

    const cells = [_]types.Cell{.{ .spans = spans[0..3], .background = "#abcdef" }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    styled.clearRetainingCapacity();
    try tableText(&styled.writer, .{ .rows = &rows }, true, null);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "inner").?).background.?);
    try std.testing.expectEqual([3]u8{ 171, 205, 239 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "outer").?).background.?);
    const long = [_]model.Span{.{ .text = "ABCDEFGHIJKLMNO", .background = "#010924", .bold = true }};
    styled.clearRetainingCapacity();
    try spansText(&styled.writer, &long, true);
    const wrapped = try terminal.wrapStyled(a, styled.written(), 4);
    defer a.free(wrapped);
    try std.testing.expect(wrapped.len >= 3);
    try std.testing.expectEqual([3]u8{ 1, 9, 36 }, wrapped[1].carry.background.?);
}

test "authored backgrounds select sRGB contrast while explicit foreground and theme links remain authoritative" {
    const types = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, contrastForeground(.{ 255, 253, 208 }));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, contrastForeground(.{ 0, 0, 128 }));
    // This middle gray selects black by the actual contrast ratios.
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, contrastForeground(.{ 119, 119, 119 }));
    const spans = [_]model.Span{
        .{ .text = "pale", .background = "#fffdd0" },
        .{ .text = "dark", .background = "#000080" },
        .{ .text = "authored", .background = "#fffdd0", .foreground = "#123456" },
        .{ .kind = .link, .text = "themeLink", .target = "Theme" },
        .{ .text = "neighbor" },
    };
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try spansText(&plain.writer, &spans, false);
    try spansText(&styled.writer, &spans, true);
    const visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "pale").?).foreground.?);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "dark").?).foreground.?);
    try std.testing.expectEqual([3]u8{ 18, 52, 86 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "authored").?).foreground.?);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[36mthemeLink") != null);
    try std.testing.expect(TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "neighbor").?).foreground == null);

    const long_link = [_]model.Span{.{ .kind = .link, .text = "ABCDEFGHIJKLMNO", .target = "Unchanged", .background = "#fffdd0" }};
    styled.clearRetainingCapacity();
    try spansText(&styled.writer, &long_link, true);
    const wrapped = try terminal.wrapStyled(a, styled.written(), 4);
    defer a.free(wrapped);
    try std.testing.expect(wrapped.len >= 3 and wrapped[1].carry.underline);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, wrapped[1].carry.foreground.?);
    try std.testing.expectEqual([3]u8{ 255, 253, 208 }, wrapped[1].carry.background.?);
    try std.testing.expectEqualStrings("Unchanged", long_link[0].target);

    const cell_spans = [_]model.Span{
        .{ .kind = .link, .text = "cellLink", .target = "Cell" },
        .{ .text = "cellPlain" },
        .{ .text = "override", .background = "#000080" },
        .{ .text = "explicit", .foreground = "#123456" },
    };
    const cells = [_]types.Cell{.{ .spans = &cell_spans, .background = "#fffdd0" }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    styled.clearRetainingCapacity();
    try tableText(&styled.writer, .{ .rows = &rows }, true, null);
    for ([_][]const u8{ "cellLink", "cellPlain" }) |word|
        try std.testing.expectEqual([3]u8{ 0, 0, 0 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), word).?).foreground.?);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "override").?).foreground.?);
    try std.testing.expectEqual([3]u8{ 18, 52, 86 }, TypedColorOutputTest.at(styled.written(), std.mem.indexOf(u8, styled.written(), "explicit").?).foreground.?);
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[4m") != null);
}

test "folded reader retains addressable empty parent headings around pronoun tables" {
    // Port:Binaman has literal empty Personal/Demonstratives parents before
    // their pronoun tables. Empty implicit labels are a separate negative control.
    const personal = [_]model.Span{.{ .kind = .link, .text = "ic", .target = "ic" }};
    const demonstrative = [_]model.Span{.{ .kind = .link, .text = "se", .target = "se" }};
    const first_table = [_]model.Block{.{ .kind = .table, .table = .{
        .rows = &.{.{ .cells = &.{.{ .spans = &personal }} }},
    } }};
    const second_table = [_]model.Block{.{ .kind = .table, .table = .{
        .rows = &.{.{ .cells = &.{.{ .spans = &demonstrative }} }},
    } }};
    const sections = [_]model.Section{
        .{ .level = 2, .title = "Unclassified" },
        .{ .level = 1, .title = "Personal", .anchor = "Personal" },
        .{ .level = 2, .title = "1st", .anchor = "1st", .blocks = &first_table },
        .{ .level = 1, .title = "Demonstratives", .anchor = "Demonstratives" },
        .{ .level = 2, .title = "That, those, the", .anchor = "That,_those,_the", .anchor_fallback = "That.2C_those.2C_the", .blocks = &second_table },
        .{ .level = 2, .title = "Legacy empty placeholder" },
    };
    const a = std.testing.allocator;
    const codec = @import("blob_encoder").presentation_codec;
    const bytes = try codec.encodeAlloc(a, .{ .entry = .{
        .title = "pronoun groups",
        .kind = .language,
        .language = "Unclassified",
        .sections = &sections,
    } });
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decoded = try codec.decodeAlloc(arena.allocator(), bytes, "pronoun groups", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqualStrings("Personal", decoded.entry.sections[1].anchor);
    try std.testing.expectEqualStrings("Demonstratives", decoded.entry.sections[3].anchor);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(a);
    for (decoded.entry.sections, 0..) |section, index| if (foldedSectionVisible(section)) try indices.append(a, index);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, indices.items);
    for ([_]bool{ false, true }) |details| for ([_]usize{ 1, 3 }) |selected| {
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        const offset = try entryTextFolded(&text, decoded.entry, false, .{ .details = details, .collapse_other = true }, &.{}, selected);
        const rendered = text.written();
        try std.testing.expect(std.mem.startsWith(u8, rendered[offset..], if (selected == 1) "> Personal\n" else "> Demonstratives\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "Personal"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "Demonstratives"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "Unclassified"));
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Legacy empty placeholder") == null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Personal").? < std.mem.indexOf(u8, rendered, "1st").?);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "1st").? < std.mem.indexOf(u8, rendered, "Demonstratives").?);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Demonstratives").? < std.mem.indexOf(u8, rendered, "That, those, the").?);
        try std.testing.expectEqual(details, std.mem.indexOf(u8, rendered, "│ ic") != null);
        try std.testing.expectEqual(details, std.mem.indexOf(u8, rendered, "│ se") != null);
    };
}

test "nested tables remain inside four parent cells and traverse abbreviation metadata" {
    const a = std.testing.allocator;
    const T = @import("blob_encoder").presentation_types;
    const child: T.Table = .{ .rows = &.{.{ .cells = &.{
        .{ .spans = &.{}, .header = true },
        .{ .spans = &.{.{ .kind = .link, .text = "child", .target = "destination", .explanation = "nested explanation" }} },
    } }} };
    const table: T.Table = .{ .rows = &.{.{ .cells = &.{
        .{ .spans = &.{}, .nested_table = child },
        .{ .spans = &.{}, .nested_table = child },
        .{ .spans = &.{}, .nested_table = child },
        .{ .spans = &.{}, .nested_table = child },
    } }} };
    const entry: model.Entry = .{ .title = "nested", .kind = .language, .sections = &.{.{ .level = 1, .title = "body", .blocks = &.{.{ .kind = .table, .table = table }} }} };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try tableText(&out.writer, table, false, null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out.written(), "child"));
    // Each child frame is enclosed by its parent cell, rather than emitted after
    // a flattened/root-unwrapped grid. Empty child header is still a real cell.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "│   │") != null);
    try std.testing.expectEqual(@as(usize, 4), table.rows[0].cells.len);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].cells[0].nested_table.?.rows[0].cells.len);
    var narrow: std.Io.Writer.Allocating = .init(a);
    defer narrow.deinit();
    var metadata: std.ArrayList(terminal.PoemLine) = .empty;
    defer metadata.deinit(a);
    var projection: PoemProjection = .{ .frame = &narrow, .allocator = a, .lines = &metadata, .table_columns = 36 };
    try tableText(&narrow.writer, table, false, &projection);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, narrow.written(), "child"));
    var lines = std.mem.splitScalar(u8, narrow.written(), '\n');
    while (lines.next()) |line| try std.testing.expect(terminal.cellWidth(line) <= 36);
    var abbreviations = try Abbreviations.init(a, entry);
    defer abbreviations.deinit();
    var details: std.Io.Writer.Allocating = .init(a);
    defer details.deinit();
    try abbreviations.write(&details.writer);
    try std.testing.expect(std.mem.indexOf(u8, details.written(), "nested explanation") != null);
}

test "authored terminal geometry has explicit border padding and width projection" {
    const a = std.testing.allocator;
    const T = @import("blob_encoder").presentation_types;
    var table: T.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "x" }} }} }} };
    var baseline: std.Io.Writer.Allocating = .init(a);
    defer baseline.deinit();
    try tableText(&baseline.writer, table, false, null);
    try std.testing.expectEqualStrings("  │ x   │\n\n", baseline.written());
    table.geometry = .{ .border = 0, .cell_padding = 0, .cell_spacing = 0, .width = .{ .unit = .px, .value = 80 } };
    var projected: std.Io.Writer.Allocating = .init(a);
    defer projected.deinit();
    try tableText(&projected.writer, table, false, null);
    try std.testing.expect(std.mem.indexOf(u8, projected.written(), "│") == null);
    try std.testing.expectEqual(@as(usize, 10), terminal.cellWidth(std.mem.sliceTo(projected.written(), '\n')));
}

test "nested percent width uses expanded parent content budget without outer overflow" {
    const a = std.testing.allocator;
    const T = @import("blob_encoder").presentation_types;
    const child: T.Table = .{
        .geometry = .{ .width = .{ .unit = .percent, .value = 100 } },
        .rows = &.{.{ .cells = &.{
            .{ .spans = &.{.{ .text = "x" }} },
            .{ .spans = &.{.{ .text = "y" }} },
        } }},
    };
    const parent: T.Table = .{
        .geometry = .{ .border = 0, .cell_padding = 0, .width = .{ .unit = .px, .value = 400 } },
        .rows = &.{.{ .cells = &.{.{ .spans = &.{}, .nested_table = child }} }},
    };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try tableText(&out.writer, parent, false, null);
    const first_line = std.mem.sliceTo(out.written(), '\n');
    // The child's closing rule reaches the parent content edge. Trailing parent
    // fill cannot make a natural-width child satisfy this assertion.
    try std.testing.expectEqual(@as(usize, 50), terminal.cellWidth(std.mem.trimEnd(u8, first_line, " ")));
    try std.testing.expect(std.mem.endsWith(u8, first_line, "│"));
}

test "table header emphasis survives span resets trails newlines and painted wrapping" {
    const T = @import("blob_encoder").presentation_types;
    const Observe = struct {
        fn boldAt(text: []const u8, limit: usize) bool {
            var bold = false;
            var pos: usize = 0;
            while (pos < limit) {
                if (terminal.sgrLength(text[pos..])) |n| {
                    const atom = text[pos .. pos + n];
                    if (std.mem.eql(u8, atom, "\x1b[0m") or std.mem.eql(u8, atom, "\x1b[m") or std.mem.eql(u8, atom, "\x1b[22m")) bold = false;
                    if (std.mem.eql(u8, atom, "\x1b[1m")) bold = true;
                    pos += n;
                } else pos += 1;
            }
            return bold;
        }
        fn visibleState(text: []const u8) !void {
            var pos: usize = 0;
            var header_glyphs: usize = 0;
            var ordinary_glyphs: usize = 0;
            while (pos < text.len) {
                if (terminal.sgrLength(text[pos..])) |n| {
                    pos += n;
                    continue;
                }
                const n = try std.unicode.utf8ByteSequenceLength(text[pos]);
                const cp = try std.unicode.utf8Decode(text[pos..][0..n]);
                if ((cp >= 'A' and cp <= 'Z') or (cp >= 0x0600 and cp <= 0x06ff)) {
                    try std.testing.expect(boldAt(text, pos));
                    header_glyphs += 1;
                } else if (cp >= 'a' and cp <= 'z') {
                    try std.testing.expect(!boldAt(text, pos));
                    ordinary_glyphs += 1;
                }
                pos += n;
            }
            try std.testing.expect(header_glyphs > 20 and ordinary_glyphs == 5);
        }
    };
    const a = std.testing.allocator;
    // Exact captured header segmentation: default-false suffix and linked labels.
    const root_spans = [_]model.Span{ .{ .text = "الجذر" }, .{ .text = ": س ف ر" } };
    const linked_spans = [_]model.Span{
        .{ .text = "أسماء " },
        .{ .kind = .link, .text = "فاعل", .target = "فاعل", .trail = "TRAIL\nNEXT", .foreground = "#123456" },
        .{ .text = " " },
        .{ .kind = .link, .text = "ومفعول", .target = "مفعول", .background = "#abcdef" },
        .{ .text = "ABCDEFGHIJKLMNO" },
    };
    const table: T.Table = .{ .rows = &.{
        .{ .cells = &.{.{ .header = true, .spans = &root_spans }} },
        .{ .cells = &.{.{ .header = true, .spans = &linked_spans, .background = "#010924" }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "plain" }} }} },
    } };
    for ([_]?usize{ null, 16 }) |columns| {
        var styled: std.Io.Writer.Allocating = .init(a);
        defer styled.deinit();
        try tableTextWidth(&styled.writer, table, true, null, columns);
        try Observe.visibleState(styled.written());
        const trail = std.mem.indexOfScalar(u8, styled.written(), 'T').?;
        try std.testing.expectEqual([3]u8{ 18, 52, 86 }, TypedColorOutputTest.at(styled.written(), trail).foreground.?);
        const painted = std.mem.indexOf(u8, styled.written(), "و").?;
        try std.testing.expectEqual([3]u8{ 171, 205, 239 }, TypedColorOutputTest.at(styled.written(), painted).background.?);
        var plain: std.Io.Writer.Allocating = .init(a);
        defer plain.deinit();
        try tableTextWidth(&plain.writer, table, false, null, columns);
        const stripped = try NarrowTableTest.plain(a, styled.written());
        defer a.free(stripped);
        try std.testing.expectEqualStrings(plain.written(), stripped);
    }
    try std.testing.expect(!root_spans[1].bold and !linked_spans[1].bold);
    try std.testing.expectEqualStrings("فاعل", linked_spans[1].target);
    try std.testing.expectEqualStrings("TRAIL\nNEXT", linked_spans[1].trail);
}

const OrderedCellOutputTest = struct {
    fn boldAt(text: []const u8, limit: usize) bool {
        var bold = false;
        var pos: usize = 0;
        while (pos < limit) {
            if (terminal.sgrLength(text[pos..])) |n| {
                const atom = text[pos .. pos + n];
                if (std.mem.eql(u8, atom, "\x1b[0m") or std.mem.eql(u8, atom, "\x1b[m") or std.mem.eql(u8, atom, "\x1b[22m")) bold = false;
                if (std.mem.eql(u8, atom, "\x1b[1m")) bold = true;
                pos += n;
            } else pos += 1;
        }
        return bold;
    }
};

test "ordered cell blocks retain heading identity order styles and metadata through codec" {
    const a = std.testing.allocator;
    const E = @import("blob_encoder");
    const T = E.presentation_types;
    const owner = "wikidict-media wikidict-media-file-c38963686f20f09f948a2e6f6767";
    const child: T.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &.{
        .{ .kind = .heading, .level = 4, .anchor = "child", .anchor_fallback = "child_legacy", .spans = &.{.{ .kind = .link, .text = "CHILD", .target = "deep" }} },
    } }} }} };
    const body = [_]T.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "BEFORE", .target = "before" }} },
        .{ .kind = .heading, .level = 3, .anchor = "cell_heading", .anchor_fallback = "cell.20heading", .spans = &.{.{ .kind = .link, .text = "HEADING", .target = "middle", .explanation = "heading expansion" }} },
        .{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{.{ .text = "LIST", .explanation = "list expansion" }}, .feature = .{ .kind = "native-test-language", .language = "ang" } },
        .{ .kind = .rule },
        .{ .kind = .table, .table = child },
        .{ .kind = .paragraph, .spans = &.{ .{ .text = "AFTER " }, .{ .kind = .link, .text = "owned caption", .target = "caption-target", .classes = owner } } },
    };
    const table: T.Table = .{ .rows = &.{.{ .cells = &.{
        .{ .blocks = &body, .header = true, .background = "#ffffe0" },
        .{ .spans = &.{.{ .text = "control" }} },
    } }} };
    const entry: model.Entry = .{
        .title = "ordered",
        .kind = .language,
        .language = "Unclassified",
        .sections = &.{.{ .level = 2, .title = "Outer", .anchor = "Outer", .blocks = &.{.{ .kind = .table, .table = table }} }},
        .media = &.{.{ .file = "Écho 🔊.ogg", .kind = .audio, .caption = "owned caption" }},
    };
    const bytes = try E.presentation_codec.encodeAlloc(a, .{ .entry = entry });
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const stored = try E.presentation_codec.decodeAlloc(arena.allocator(), bytes, "ordered", .language, .{ .code = "", .heading = "Unclassified" });
    const restored = stored.entry.sections[0].blocks[0].table.?;
    const ordered = restored.rows[0].cells[0].blocks.?;
    try std.testing.expectEqual(@as(usize, 1), stored.entry.sections.len);
    try std.testing.expectEqual(@as(u8, 3), ordered[1].level);
    try std.testing.expectEqualStrings("cell_heading", ordered[1].anchor);
    try std.testing.expectEqualStrings("cell.20heading", ordered[1].anchor_fallback);
    try std.testing.expectEqual(@as(u8, 4), ordered[4].table.?.rows[0].cells[0].blocks.?[0].level);
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    try tableText(&plain.writer, restored, false, null);
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try tableText(&styled.writer, restored, true, null);
    const stripped = try NarrowTableTest.plain(a, styled.written());
    defer a.free(stripped);
    try std.testing.expectEqualStrings(plain.written(), stripped);
    var previous: usize = 0;
    for ([_][]const u8{ "BEFORE", "HEADING", "LIST", "CHILD", "AFTER", "owned caption" }) |label| {
        const at = std.mem.indexOf(u8, plain.written(), label).?;
        try std.testing.expect(at >= previous);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain.written(), label));
        previous = at + label.len;
        const styled_at = std.mem.indexOf(u8, styled.written(), label).?;
        try std.testing.expect(OrderedCellOutputTest.boldAt(styled.written(), styled_at));
        try std.testing.expectEqual([3]u8{ 0, 0, 0 }, TypedColorOutputTest.at(styled.written(), styled_at).foreground.?);
    }
    try std.testing.expect(OrderedCellOutputTest.boldAt(styled.written(), std.mem.indexOf(u8, styled.written(), "[ang]").?));
    try std.testing.expect(OrderedCellOutputTest.boldAt(styled.written(), std.mem.indexOf(u8, styled.written(), "•").?));
    try std.testing.expect(OrderedCellOutputTest.boldAt(styled.written(), std.mem.indexOf(u8, styled.written(), "────────────────────────").?));
    try std.testing.expect(!OrderedCellOutputTest.boldAt(styled.written(), std.mem.indexOf(u8, styled.written(), "control").?));
    const Links = struct {
        targets: [4][]const u8 = undefined,
        count: usize = 0,
        fn spans(self: *@This(), values: []const model.Span) !bool {
            for (values) |span| if (span.kind == .link or span.kind == .external_link) {
                if (self.count >= self.targets.len) return error.TooManyLinks;
                self.targets[self.count] = span.target;
                self.count += 1;
            };
            return false;
        }
    };
    var links: Links = .{};
    _ = try visitEntrySpanLists(stored.entry, &links);
    try std.testing.expectEqual(@as(usize, 4), links.count);
    for ([_][]const u8{ "before", "middle", "deep", "caption-target" }, links.targets) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    var abbreviations = try Abbreviations.init(a, stored.entry);
    defer abbreviations.deinit();
    try std.testing.expectEqual(@as(usize, 2), abbreviations.items.items.len);
    try std.testing.expectEqualStrings("HEADING", abbreviations.items.items[0].label);
    try std.testing.expectEqualStrings("LIST", abbreviations.items.items[1].label);
    var captions = try VisibleMediaCaptions.init(arena.allocator(), stored.entry.media, true);
    try captions.observeBlocks(stored.entry.sections[0].blocks);
    try std.testing.expect(captions.seen[0]);
    var folded: std.Io.Writer.Allocating = .init(a);
    defer folded.deinit();
    _ = try entryTextFolded(&folded, stored.entry, false, .{ .details = true }, &.{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, folded.written(), "> Outer\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded.written(), "> HEADING") == null);
}

test "ordered cell tables retain owning width and explicit empty authority" {
    const a = std.testing.allocator;
    const T = @import("blob_encoder").presentation_types;
    const child: T.Table = .{ .geometry = .{ .width = .{ .unit = .percent, .value = 100 } }, .rows = &.{.{ .cells = &.{
        .{ .spans = &.{.{ .text = "x" }} }, .{ .spans = &.{.{ .text = "y" }} },
    } }} };
    const parent: T.Table = .{
        .geometry = .{ .border = 0, .cell_padding = 0, .width = .{ .unit = .px, .value = 400 } },
        .rows = &.{.{ .cells = &.{.{ .blocks = &.{
            .{ .kind = .heading, .level = 3, .anchor = "top", .spans = &.{.{ .text = "TOP" }} },
            .{ .kind = .table, .table = child },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "TAIL" }} },
        } }} }},
    };
    for ([_]?usize{ null, 36, 76, 116 }) |columns| {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try tableTextWidth(&out.writer, parent, false, null, columns);
        const top = std.mem.indexOf(u8, out.written(), "TOP").?;
        const child_at = std.mem.indexOfScalar(u8, out.written(), 'x').?;
        const tail = std.mem.indexOf(u8, out.written(), "TAIL").?;
        try std.testing.expect(top < child_at and child_at < tail);
        var lines = std.mem.splitScalar(u8, out.written(), '\n');
        while (lines.next()) |line| {
            try std.testing.expect(terminal.cellWidth(line) <= (columns orelse 50));
            if (std.mem.indexOfScalar(u8, line, 'x') != null) {
                try std.testing.expectEqual(@min(columns orelse 50, 50), terminal.cellWidth(std.mem.trimEnd(u8, line, " ")));
                try std.testing.expect(std.mem.endsWith(u8, line, "│"));
            }
        }
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try tableCellText(&out.writer, .{ .blocks = &.{}, .header = true, .background = "#123456" }, false, 20, 1, null);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try tableCellText(&out.writer, .{ .spans = &.{.{ .text = "legacy" }} }, false, 20, 1, null);
    try std.testing.expectEqualStrings("legacy", out.written());
    try std.testing.expectError(error.InvalidPresentation, tableCellText(&out.writer, .{ .blocks = &.{}, .spans = &.{.{ .text = "mixed" }} }, false, 20, 1, null));
}

test "native ordered cell walks keep the enclosing table depth limit" {
    const T = @import("blob_encoder").presentation_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table: T.Table = .{ .rows = &.{} };
    for (0..T.max_table_depth) |_| {
        const blocks = try a.alloc(T.Block, 1);
        blocks[0] = .{ .kind = .table, .table = table };
        const cells = try a.alloc(T.Cell, 1);
        cells[0] = .{ .blocks = blocks };
        const rows = try a.alloc(T.Row, 1);
        rows[0] = .{ .cells = cells };
        table = .{ .rows = rows };
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expectError(error.InvalidPresentation, tableText(&out.writer, table, false, null));
    const Visitor = struct {
        fn spans(_: *@This(), _: []const model.Span) error{}!bool {
            return false;
        }
    };
    var visitor: Visitor = .{};
    try std.testing.expectError(error.InvalidPresentation, visitTableSpanLists(table, &visitor));
    var captions = try VisibleMediaCaptions.init(a, &.{.{ .file = "depth-control.ogg", .kind = .audio, .caption = "" }}, true);
    try std.testing.expectError(error.InvalidPresentation, captions.observeBlocks(&.{.{ .kind = .table, .table = table }}));
}

test "detail continuation lines retain quotation rails and terminate once" {
    const example = [_]model.Span{
        .{ .text = "ORIGINAL", .italic = true },
        .{ .kind = .line_break },
        .{ .text = "TRANSLATION", .bold = true },
        .{ .kind = .line_break },
        .{ .kind = .line_break },
    };
    const quotation = [_]model.Span{.{ .text = "QUOTE_ONE\nQUOTE_TWO\n", .italic = true }};
    const blocks = [_]model.Block{
        .{ .kind = .example, .depth = 2, .spans = &example },
        .{ .kind = .quotation, .depth = 1, .spans = &quotation },
    };
    const expected = "    │ ORIGINAL\n    │ TRANSLATION\n  │ QUOTE_ONE\n  │ QUOTE_TWO\n\n";
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    try blocksText(&plain.writer, &blocks, false);
    try std.testing.expectEqualStrings(expected, plain.written());
    var ansi: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ansi.deinit();
    try blocksText(&ansi.writer, &blocks, true);
    const visible = try NarrowTableTest.plain(std.testing.allocator, ansi.written());
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings(expected, visible);
    try std.testing.expect(std.mem.indexOf(u8, ansi.written(), "ORIGINAL\x1b[0m\n    │ \x1b[1mTRANSLATION\x1b[0m\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, ansi.written(), "QUOTE_TWO\x1b[0m\n\n"));
}

test "only empty leaf reference placeholders with actual references are omitted" {
    const sections = [_]model.Section{
        .{ .level = 3, .title = "References" },
        .{ .level = 3, .title = "Further reading" },
    };
    const refs = [_]model.Reference{.{ .number = 1, .group_number = 1, .spans = &.{.{ .text = "REFERENCE_BODY" }} }};
    var entry: model.Entry = .{ .title = "test", .kind = .language, .language = "English", .sections = &sections, .references = &refs };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |organized| {
        entry.organization = if (organized) .{ .lexemes = &.{.{ .kind = "Noun", .section = 1 }}, .other_sections = &.{0} } else .{};
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, false, true);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\nReferences\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "REFERENCE_BODY"));
    }
    entry.organization = .{};
    entry.sections = &.{ .{ .level = 3, .title = "References" }, .{ .level = 4, .title = "Child" }, .{ .level = 3, .title = "Other empty heading" } };
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, true);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\nReferences\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Other empty heading") != null);
    entry.sections = &sections;
    entry.references = &.{};
    out.clearRetainingCapacity();
    try entryTextWithDetails(&out.writer, entry, false, true);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\nReferences\n"));
}

test "detail blank rows stay unprefixed and poem blocks retain their layout" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const prose = [_]model.Span{.{ .text = "ORIGINAL\n\nTRANSLATION\n" }};
    const verse = [_]model.Span{
        .{ .text = "VERSE_A", .classes = "wikidict-poem wikidict-poem-indent-2" },
        .{ .kind = .line_break, .classes = "wikidict-poem wikidict-poem-indent-2" },
        .{ .kind = .line_break, .classes = "wikidict-poem" },
        .{ .text = "VERSE_B", .classes = "wikidict-poem wikidict-poem-indent-2" },
        .{ .kind = .line_break, .classes = "wikidict-poem wikidict-poem-indent-2" },
    };
    for ([_]model.Block{ .{ .kind = .example }, .{ .kind = .quotation } }) |sample| {
        const kind = sample.kind;
        out.clearRetainingCapacity();
        try blocksText(&out.writer, &.{.{ .kind = kind, .depth = 1, .spans = &prose }}, false);
        const expected = if (kind == .quotation) "  │ ORIGINAL\n\n  │ TRANSLATION\n\n" else "  │ ORIGINAL\n\n  │ TRANSLATION\n";
        try std.testing.expectEqualStrings(expected, out.written());
        out.clearRetainingCapacity();
        try blocksText(&out.writer, &.{.{ .kind = kind, .depth = 1, .spans = &verse }}, false);
        const expected_verse = if (kind == .quotation) "  │   VERSE_A\n\n  VERSE_B\n\n\n" else "  │   VERSE_A\n\n  VERSE_B\n\n";
        try std.testing.expectEqualStrings(expected_verse, out.written());
    }
}

test "reference fragments retain rich footer content without a synthesized label" {
    const fragments = [_]model.Span{.{ .kind = .link, .text = "ORPHAN", .target = "Destination", .bold = true }};
    const refs = [_]model.Reference{
        .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &fragments },
        .{ .number = 2, .group_number = 1, .group = "notes", .spans = &.{.{ .text = "NUMBERED" }} },
    };
    const entry: model.Entry = .{ .title = "entry", .kind = .supplemental, .references = &refs };
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    var ansi: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ansi.deinit();
    try entryText(&plain.writer, entry, false);
    try entryText(&ansi.writer, entry, true);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "\nReferences\nORPHAN\n[notes 1] NUMBERED\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "[notes 8]") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "null") == null);
    const visible = try NarrowTableTest.plain(std.testing.allocator, ansi.written());
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    try std.testing.expect(std.mem.indexOf(u8, ansi.written(), "\x1b[1m\x1b[36mORPHAN\x1b[0m") != null);
    try std.testing.expectEqualStrings("Destination", entry.references[0].spans[0].target);
    try std.testing.expectEqual(@as(usize, 8), entry.references[0].number);
}


test "numeric reduced text preserves legacy dim cue plain bytes and terminal escaping" {
    const cases = [_]struct { scale: ?f32, legacy: bool = false, dim: bool = false }{
        .{ .scale = null },
        .{ .scale = 1.0 / 1.2, .dim = true },
        .{ .scale = 0.01, .dim = true },
        .{ .scale = 1 },
        .{ .scale = 1.2 },
        .{ .scale = 0 },
        .{ .scale = null, .legacy = true, .dim = true },
        .{ .scale = 1.2, .legacy = true, .dim = true },
    };
    const text = "A\x1b[31mB C";
    const baseline = [_]model.Span{.{ .text = text }};
    var plain_reference: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain_reference.deinit();
    try spansText(&plain_reference.writer, &baseline, false);
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    var colored: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer colored.deinit();
    for (cases) |case| {
        const spans = [_]model.Span{.{ .text = text, .font_scale = case.scale, .small = case.legacy }};
        plain.clearRetainingCapacity();
        colored.clearRetainingCapacity();
        try spansText(&plain.writer, &spans, false);
        try spansText(&colored.writer, &spans, true);
        try std.testing.expectEqualStrings(plain_reference.written(), plain.written());
        try std.testing.expectEqual(case.dim, std.mem.indexOf(u8, colored.written(), "\x1b[2m") != null);
        try std.testing.expect(std.mem.indexOf(u8, colored.written(), "\x1b[31m") == null);
        try std.testing.expect(std.mem.indexOf(u8, colored.written(), plain_reference.written()) != null);
        try std.testing.expectEqualStrings(text, spans[0].text);
        try std.testing.expectEqual(case.scale, spans[0].font_scale);
    }
}


test "reference blocks preserve HR table order rich visitors and note identity" {
    const T = @import("blob_encoder").presentation_types;
    const a = std.testing.allocator;
    const headers = [_][]const u8{ "Latinski", "Talijanski", "Njemački", "Hrvatski", "Madžarski" };
    const values = [_][]const u8{ "Locuſta", "Locusta", "Heüſchreück", "Szkakavicza", "Saaská" };
    var header_cells: [5]T.Cell = undefined;
    var body_cells: [5]T.Cell = undefined;
    var header_spans: [5][1]model.Span = undefined;
    var body_spans: [5][1]model.Span = undefined;
    for (headers, values, 0..) |header, value, i| {
        header_spans[i] = .{.{ .text = header }};
        body_spans[i] = .{.{ .kind = .link, .text = value, .target = value, .font_scale = 0.8, .font_scale_basis = .normal_body, .explanation = "HR lexical form" }};
        header_cells[i] = .{ .header = true, .spans = &header_spans[i] };
        body_cells[i] = .{ .spans = &body_spans[i] };
    }
    const body = [_]model.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "CITATION_PROSE" }} },
        .{ .kind = .table, .table = .{ .rows = &.{ .{ .cells = &header_cells }, .{ .cells = &body_cells } } } },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "owned caption", .classes = "wikidict-media wikidict-media-file-736f756e642e6f6767" }} },
    };
    const refs = [_]model.Reference{
        .{ .number = 91, .group_number = 2, .group = "notes", .blocks = &body },
        .{ .kind = .fragment, .number = 92, .group_number = null, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "FOOTER_FRAGMENT" }} }} },
    };
    const entry: model.Entry = .{ .title = "HR", .kind = .citations, .references = &refs, .media = &.{.{ .file = "sound.ogg", .kind = .audio, .caption = "owned caption" }} };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try entryText(&out.writer, entry, false);
    const text = out.written();
    const prose = std.mem.indexOf(u8, text, "[notes 2] CITATION_PROSE").?;
    for (headers, values) |header, value| {
        try std.testing.expect(std.mem.indexOf(u8, text, header).? > prose);
        try std.testing.expect(std.mem.indexOf(u8, text, value).? > std.mem.indexOf(u8, text, header).?);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "owned caption"));
    try std.testing.expect(std.mem.indexOf(u8, text, "[92]") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "FOOTER_FRAGMENT") != null);
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try entryText(&styled.writer, entry, true);
    const plain = try NarrowTableTest.plain(a, styled.written());
    defer a.free(plain);
    try std.testing.expectEqualStrings(text, plain);
    for (headers) |header| try std.testing.expect(OrderedCellOutputTest.boldAt(styled.written(), std.mem.indexOf(u8, styled.written(), header).?));
    try std.testing.expect(std.mem.indexOf(u8, styled.written(), "\x1b[2m") != null);
    const Links = struct {
        count: usize = 0,
        fn spans(self: *@This(), span_items: []const model.Span) !bool {
            for (span_items) |span| if (span.kind == .link) {
                try std.testing.expectEqualStrings(span.text, span.target);
                try std.testing.expectEqual(@as(?f32, 0.8), span.font_scale);
                try std.testing.expectEqual(@import("blob_encoder").presentation_types.FontScaleBasis.normal_body, span.font_scale_basis);
                self.count += 1;
            };
            return false;
        }
    };
    var links: Links = .{};
    _ = try visitEntrySpanLists(entry, &links);
    try std.testing.expectEqual(@as(usize, 5), links.count);
    var abbreviations = try Abbreviations.init(a, entry);
    defer abbreviations.deinit();
    try std.testing.expectEqual(@as(usize, 5), abbreviations.items.items.len);
    try std.testing.expectEqual(@as(usize, 91), entry.references[0].number);
}

test "reference block empty authority legacy null and mixed payload rejection" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const entry: model.Entry = .{ .title = "control", .kind = .citations, .references = &.{
        .{ .number = 1, .group_number = 1, .spans = &.{.{ .text = "LEGACY" }} },
        .{ .number = 2, .group_number = 2, .blocks = &.{} },
        .{ .kind = .fragment, .number = 3, .group_number = null, .blocks = &.{} },
    } };
    try entryText(&out.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\nReferences\n[1] LEGACY\n[2] \n\n") != null);
    var invalid = entry;
    invalid.references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{}, .spans = &.{.{ .text = "MIXED" }} }};
    out.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidPresentation, entryText(&out.writer, invalid, false));
    const Visitor = struct {
        fn spans(_: *@This(), _: []const model.Span) error{}!bool { return false; }
    };
    var visitor: Visitor = .{};
    try std.testing.expectError(error.InvalidPresentation, visitEntrySpanLists(invalid, &visitor));
}


test "reference blocks pass poem metadata to the owning frame projection" {
    const a = std.testing.allocator;
    const entry: model.Entry = .{ .title = "poem", .kind = .citations, .references = &.{.{
        .kind = .fragment, .number = 1, .group_number = null,
        .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "VERSE", .classes = "wikidict-poem wikidict-poem-indent-2" }} }},
    }} };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var lines: std.ArrayList(terminal.PoemLine) = .empty;
    defer lines.deinit(a);
    var projection: PoemProjection = .{ .frame = &out, .allocator = a, .lines = &lines };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var captions = try VisibleMediaCaptions.init(arena.allocator(), entry.media, true);
    try entryMetadataProjected(&out.writer, entry, false, &projection, &captions);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].left);
    try std.testing.expect(std.mem.startsWith(u8, out.written()[lines.items[0].offset..], "VERSE"));
}


test "table first reference note labels leave every grid row aligned" {
    const a = std.testing.allocator;
    const body = [_]model.Block{.{ .kind = .table, .table = .{ .rows = &.{
        .{ .cells = &.{.{ .header = true, .spans = &.{.{ .text = "HEADER" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "value" }} }} },
    } } }};
    const entry: model.Entry = .{ .title = "grid", .kind = .citations, .references = &.{.{ .number = 77, .group_number = 3, .group = "notes", .blocks = &body }} };
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var ansi: std.Io.Writer.Allocating = .init(a);
    defer ansi.deinit();
    try entryText(&plain.writer, entry, false);
    try entryText(&ansi.writer, entry, true);
    const visible = try NarrowTableTest.plain(a, ansi.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    const label = std.mem.indexOf(u8, visible, "[notes 3] \n").?;
    const grid = visible[label + "[notes 3] \n".len..];
    var lines = std.mem.splitScalar(u8, grid, '\n');
    const first = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, first, "  │"));
    const width = terminal.cellWidth(first);
    var rows: usize = 1;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        try std.testing.expectEqual(width, terminal.cellWidth(line));
        try std.testing.expect(std.mem.startsWith(u8, line, "  │"));
        rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), rows);
}


test "typed table surface reaches reference cells without changing terminal geometry" {
    const a = std.testing.allocator;
    const spans = [_]model.Span{.{ .kind = .link, .text = "SURFACE", .target = "Destination" }};
    const table: model.Table = .{ .style = .{ .background = "#010924" }, .rows = &.{.{ .cells = &.{
        .{ .spans = &spans },
        .{ .background = "#ffffe0", .header = true, .spans = &.{.{ .text = "OVERRIDE" }} },
    } }} };
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try tableText(&plain.writer, table, false, null);
    try tableText(&styled.writer, table, true, null);
    const visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    const link = std.mem.indexOf(u8, styled.written(), "SURFACE").?;
    try std.testing.expectEqual([3]u8{ 1, 9, 36 }, TypedColorOutputTest.at(styled.written(), link).background.?);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, TypedColorOutputTest.at(styled.written(), link).foreground.?);
    const cell = std.mem.indexOf(u8, styled.written(), "OVERRIDE").?;
    try std.testing.expectEqual([3]u8{ 255, 255, 224 }, TypedColorOutputTest.at(styled.written(), cell).background.?);
    try std.testing.expect(OrderedCellOutputTest.boldAt(styled.written(), cell));
    var legacy = table;
    legacy.style = null;
    var unpainted: std.Io.Writer.Allocating = .init(a);
    defer unpainted.deinit();
    try tableText(&unpainted.writer, legacy, false, null);
    try std.testing.expectEqualStrings(unpainted.written(), plain.written());
    try std.testing.expectEqualStrings("Destination", spans[0].target);
}

test "typed graphical lengths remain data rather than terminal column guesses" {
    const a = std.testing.allocator;
    var table: model.Table = .{ .rows = &.{.{ .cells = &.{.{
        .spans = &.{.{ .text = "DATA" }},
        .style = .{ .text_align = .center, .padding = .{
            .top = .{ .unit = .em, .value = 0 }, .right = .{ .unit = .px, .value = 10 },
            .bottom = .{ .unit = .em, .value = 1.5 }, .left = .{ .unit = .px, .value = 0 },
        } },
    }} }} };
    table.style = .{ .collapse = .collapse, .border = .{ .solid = .{ .width = .{ .unit = .em, .value = 0 }, .color = "#123456" } }, .margins = .{
        .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .em, .value = 1 },
        .bottom = .{ .unit = .px, .value = 10 }, .left = .{ .unit = .em, .value = 0 },
    } };
    var projected: std.Io.Writer.Allocating = .init(a);
    defer projected.deinit();
    try tableText(&projected.writer, table, false, null);
    var legacy = table;
    legacy.style = null;
    legacy.rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "DATA" }} }} }};
    var expected: std.Io.Writer.Allocating = .init(a);
    defer expected.deinit();
    try tableText(&expected.writer, legacy, false, null);
    try std.testing.expectEqualStrings(expected.written(), projected.written());
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    try std.json.Stringify.value(table, .{}, &encoded.writer);
    for ([_][]const u8{ "\"margins\"", "\"padding\"", "\"text_align\":\"center\"", "\"unit\":\"em\"", "\"value\":0", "#123456" }) |field|
        try std.testing.expect(std.mem.indexOf(u8, encoded.written(), field) != null);
}


test "typed cell alignment uses visible terminal width including Unicode and ANSI" {
    terminal.initLocale();
    const line: terminal.RenderRow = .{ .bytes = "\x1b[1m猫\x1b[0m", .carry = .{} };
    const right: @import("blob_encoder").presentation_types.Cell = .{ .style = .{ .text_align = .right } };
    const center: @import("blob_encoder").presentation_types.Cell = .{ .style = .{ .text_align = .center } };
    try std.testing.expectEqual(@as(usize, 4), cellLineLeading(right, line, 6));
    try std.testing.expectEqual(@as(usize, 2), cellLineLeading(center, line, 6));
    try std.testing.expectEqual(@as(usize, 0), cellLineLeading(.{}, line, 6));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try tableWrappedAlignedLine(&out.writer, line, 6, true, null, 1, cellLineLeading(right, line, 6));
    const plain = try NarrowTableTest.plain(std.testing.allocator, out.written());
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("     猫 ", plain);
}


test "inline images keep occurrence order and heading text authority separate" {
    const a = std.testing.allocator;
    const spans = [_]model.Span{
        .{ .text = "Heading " },
        .{ .kind = .link, .target = "File:Vraagteken-2.svg", .font_scale = 0, .image = .{ .file = "Vraagteken-2.svg", .width_px = 15 } },
        .{ .text = " AFTER " },
        .{ .kind = .external_link, .target = "https://example.test/image", .image = .{ .file = "X mark.svg", .width_px = 15, .alt = "איקס", .tooltip = "TOOLTIP_ONLY" } },
        .{ .image = .{ .file = "Yes check.svg", .height_px = 15, .alt = "", .tooltip = "" } },
    };
    var plain: std.Io.Writer.Allocating = .init(a);
    defer plain.deinit();
    var styled: std.Io.Writer.Allocating = .init(a);
    defer styled.deinit();
    try spansText(&plain.writer, &spans, false);
    try spansText(&styled.writer, &spans, true);
    try std.testing.expectEqualStrings("Heading [image] AFTER [image: איקס][image]", plain.written());
    const visible = try NarrowTableTest.plain(a, styled.written());
    defer a.free(visible);
    try std.testing.expectEqualStrings(plain.written(), visible);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "Vraagteken") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "TOOLTIP_ONLY") == null);
    const section: model.Section = .{ .level = 3, .title = "Heading  AFTER", .anchor = "unchanged", .blocks = &.{.{ .kind = .heading, .level = 3, .spans = &spans }} };
    try std.testing.expect(sectionHeadingCompanion(section) != null);
    var heading: std.Io.Writer.Allocating = .init(a);
    defer heading.deinit();
    var cursor: HeadingBytes = .{ .spans = &spans };
    while (cursor.next()) |byte| try heading.writer.writeByte(byte);
    try std.testing.expectEqualStrings("Heading  AFTER ", heading.written());
    try std.testing.expectEqualStrings("unchanged", section.anchor);
    try std.testing.expectEqualStrings("", spans[1].text);
    try std.testing.expectEqualStrings("File:Vraagteken-2.svg", spans[1].target);
    try std.testing.expectEqual(@as(?u32, 15), spans[1].image.?.width_px);
}

test "inline media ownership preserves unmatched captions and counts repeated occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const media = [_]model.Media{
        .{ .file = "same.svg", .kind = .image, .caption = "authored distinct caption" },
        .{ .file = "match.svg", .kind = .image, .caption = "וי" },
    };
    const occurrences = [_]model.Span{
        .{ .kind = .link, .target = "File:same.svg", .image = .{ .file = "same.svg", .width_px = 15, .alt = "איקס" } },
        .{ .image = .{ .file = "same.svg", .width_px = 30, .alt = "" } },
        .{ .image = .{ .file = "match.svg", .alt = "וי", .tooltip = "וי" } },
    };
    var captions = try VisibleMediaCaptions.init(a, &media, true);
    try captions.observeSpans(&occurrences);
    try std.testing.expect(captions.inline_seen[0] and captions.inline_seen[1]);
    try std.testing.expect(!captions.seen[0] and captions.seen[1]);
    const entry: model.Entry = .{ .title = "media", .kind = .citations, .media = &media, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{.{ .kind = .paragraph, .spans = &occurrences }} }} };
    const original_graph = try std.json.Stringify.valueAlloc(a, entry, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer std.debug.print("inline media ownership detailed output ({d} bytes):\n{s}\n", .{ out.written().len, out.written()[0..@min(out.written().len, 8192)] });
    try entryText(&out.writer, entry, false);
    // The own tooltip is separate details metadata, not a second visible caption.
    const advisory_footer = "\nText details\nוי: וי\n";
    try std.testing.expect(std.mem.endsWith(u8, out.written(), advisory_footer));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), advisory_footer));
    const body = out.written()[0 .. out.written().len - advisory_footer.len];
    try std.testing.expect(std.mem.endsWith(u8, body, "\nReferences\n[image: איקס][image][image: וי]\n\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "[image] same.svg — authored distinct caption\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "[image] match.svg\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "authored distinct caption"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "וי"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.written(), "וי"));
    try std.testing.expectEqualStrings(original_graph, try std.json.Stringify.valueAlloc(a, entry, .{}));
    try std.testing.expectEqual(@as(usize, 2), entry.media.len);
}

test "inline image visitors retain empty action spans across recursive sinks and JSON" {
    const a = std.testing.allocator;
    const image = [_]model.Span{.{ .kind = .link, .target = "Target", .image = .{ .file = "asset.svg", .width_px = 15, .alt = "", .tooltip = "" } }};
    const child: model.Table = .{ .caption = &image, .rows = &.{.{ .cells = &.{.{ .blocks = &.{.{ .kind = .paragraph, .spans = &image }} }} }} };
    const entry: model.Entry = .{ .title = "recursive", .kind = .citations, .preamble_spans = &image,
        .sections = &.{.{ .level = 3, .title = "Section", .blocks = &.{.{ .kind = .table, .table = child }} }},
        .references = &.{
            .{ .number = 1, .group_number = 1, .spans = &image },
            .{ .kind = .fragment, .number = 2, .group_number = null, .blocks = &.{.{ .kind = .table, .table = child }} },
        },
        .media = &.{.{ .file = "asset.svg", .kind = .image, .caption = "" }},
    };
    const Images = struct {
        count: usize = 0,
        fn spans(self: *@This(), values: []const model.Span) !bool {
            for (values) |span| if (span.image) |item| {
                try std.testing.expectEqualStrings("", span.text);
                try std.testing.expectEqualStrings("Target", span.target);
                try std.testing.expectEqualStrings("asset.svg", item.file);
                self.count += 1;
            };
            return false;
        }
    };
    var images: Images = .{};
    _ = try visitEntrySpanLists(entry, &images);
    try std.testing.expectEqual(@as(usize, 6), images.count);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.json.Stringify.value(image[0], .{}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"image\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"alt\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"tooltip\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "height_px") == null);
    out.clearRetainingCapacity();
    try std.json.Stringify.value(model.Span{ .text = "legacy" }, .{}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"image\"") == null);
}


test "default text exposes Slovak child meanings through their local noun sense addresses" {
    const cases = .{
        .{ "biola", "slovenčina", "sk", "slangový výraz pre biológiu." },
        .{ "houslista", "čeština", "cs", "huslista" },
    };
    inline for (cases) |case| {
        const gender = [_]model.Span{.{ .text = "parent gender support" }};
        const meaning = [_]model.Span{.{ .text = case[3] }};
        const parent_blocks = [_]model.Block{.{ .kind = .list_item, .list_path = "*", .depth = 1, .spans = &gender }};
        const child_blocks = [_]model.Block{.{ .kind = .definition, .list_path = "#", .number = "1", .depth = 1, .spans = &meaning }};
        const sections = [_]model.Section{
            .{ .level = 3, .title = "Podstatné meno", .blocks = &parent_blocks },
            .{ .level = 4, .title = "Význam", .blocks = &child_blocks },
        };
        const senses = [_]model.Sense{.{ .block = 0 }};
        const lexemes = [_]model.Lexeme{.{ .language = case[1], .kind = "Noun", .section = 1, .definitions = &senses }};
        const entry: model.Entry = .{
            .title = case[0], .kind = .language, .language = case[1], .language_code = case[2], .sections = &sections,
            .organization = .{ .lexemes = &lexemes, .other_sections = &.{0} },
        };
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        for ([_]bool{ false, true }) |color| {
            out.clearRetainingCapacity();
            try entryTextWithDetails(&out.writer, entry, color, false);
            try std.testing.expect(std.mem.indexOf(u8, out.written(), "Noun") != null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), case[3]));
            try std.testing.expect(std.mem.indexOf(u8, out.written(), "parent gender support") == null);
        }
    }
}

test "default text exposes Croatian inline senses and details retain every local support block" {
    const cases = .{
        .{ "skakavica", "Noun", "(1.1) (čakavski) kukci, pripadnici reda ravnokrilaca; skakavac.[1]", true },
        .{ "intrigantan", "Adjective", "intrigàntan prid. <odr. intrigàntnī> koji pobuđuje na razmišljanje, koji izaziva asocijacije, takav da se može problematizirati [~ fenomen plasmana Hrvatske na Biennalu nije samo odabir umjetnika]", false },
    };
    inline for (cases) |case| {
        const blocks = [_]model.Block{
            .{ .kind = .paragraph, .spans = &.{.{ .text = "headword support" }} },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "inflection support" }} },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "authored POS marker" }} },
            .{ .kind = if (case[3]) .indent else .list_item, .list_path = if (case[3]) ":" else "*", .depth = 1, .spans = &.{.{ .text = case[2] }} },
            .{ .kind = .indent, .list_path = ":", .depth = 1, .spans = &.{.{ .text = "empty source marker support" }} },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "synonyms and related-word support" }} },
        };
        const sections = [_]model.Section{
            .{ .level = 2, .title = "authored headword", .blocks = &blocks },
            .{ .level = 3, .title = "translations", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "translation support" }} }} },
            .{ .level = 2, .title = "source", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "bibliography support" }} }} },
        };
        const senses = [_]model.Sense{.{ .block = 3 }};
        const lexemes = [_]model.Lexeme{.{ .language = "hrvatski", .kind = case[1], .section = 0, .definitions = &senses, .introduction = &.{ 0, 1, 2 }, .other_blocks = &.{ 4, 5 }, .related_sections = &.{1} }};
        const entry: model.Entry = .{ .title = case[0], .kind = .language, .language = "hrvatski", .language_code = "hr", .sections = &sections, .organization = .{ .lexemes = &lexemes, .other_sections = &.{2} } };
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try entryTextWithDetails(&out.writer, entry, false, false);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}  / hrvatski\n\n{s}\n  {s}{s}\n", .{ case[0], case[1], if (case[3]) "" else "• ", case[2] });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, out.written());
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, false, true);
        for ([_][]const u8{ "headword support", "inflection support", "authored POS marker", case[2], "empty source marker support", "synonyms and related-word support", "translation support", "bibliography support" }) |witness|
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), witness));
    }
}

test "bordered image text projection stays honest while JSON retains decoration and action" {
    const a = std.testing.allocator;
    const spans = [_]model.Span{ .{ .text = "before " }, .{ .kind = .link, .target = "File:Flag of Poland.svg", .image = .{ .file = "Flag of Poland.svg", .width_px = 40, .alt = "Poland", .border = true } }, .{ .text = " after" } };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try spansText(&out.writer, &spans, false);
    try std.testing.expectEqualStrings("before [image: Poland] after", out.written());
    out.clearRetainingCapacity();
    try std.json.Stringify.value(spans[1], .{}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"border\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"width_px\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "File:Flag of Poland.svg") != null);
}

test "explicit terminal block alignment overrides cell inheritance after styled Unicode wrapping" {
    terminal.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "1", .target = "One" }} },
        .{ .kind = .paragraph, .text_align = .center, .spans = &.{.{ .kind = .link, .text = "猫אב猫אב", .target = "Two", .bold = true, .foreground = "#123456" }} },
        .{ .kind = .paragraph, .text_align = .left, .spans = &.{.{ .kind = .external_link, .text = "3", .trail = "!", .target = "https://example.test/three" }} },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "4" }} },
    };
    const cell: @import("blob_encoder").presentation_types.Cell = .{ .blocks = &blocks, .style = .{ .text_align = .right } };
    const original = try std.json.Stringify.valueAlloc(a, cell, .{});
    for ([_]usize{ 4, 8, 16 }) |width| for ([_]bool{ false, true }) |color| {
        var text: std.Io.Writer.Allocating = .init(a);
        var alignments: BlockAlignments = .{ .allocator = a, .frame = &text };
        try tableCellTextProjected(&text.writer, cell, color, width, 1, null, &alignments);
        try std.testing.expectEqual(@as(usize, 4), alignments.points.items.len);
        const rows = try tableCellRows(a, text.written(), width);
        var seen_center = false;
        var seen_left = false;
        var seen_last = false;
        for (rows) |row| {
            if (terminal.cellWidth(row.bytes) == 0) continue;
            const offset = @intFromPtr(row.bytes.ptr) - @intFromPtr(text.written().ptr);
            const leading = cellProjectedLeading(cell, row, width, text.written(), alignments.points.items);
            if (offset >= alignments.points.items[3].offset) {
                seen_last = true;
                try std.testing.expectEqual(width - 1, leading);
            } else if (offset >= alignments.points.items[2].offset) {
                seen_left = true;
                try std.testing.expectEqual(@as(usize, 0), leading);
            } else if (offset >= alignments.points.items[1].offset) {
                seen_center = true;
                try std.testing.expectEqual((width -| terminal.cellWidth(row.bytes)) / 2, leading);
            } else try std.testing.expectEqual(width - 1, leading);
            try std.testing.expect(terminal.cellWidth(row.bytes) <= width);
        }
        try std.testing.expect(seen_center and seen_left and seen_last);
        const plain = try NarrowTableTest.plain(a, text.written());
        try std.testing.expect(std.mem.indexOf(u8, plain, "猫אב猫אב") != null);
        try std.testing.expect(std.mem.indexOf(u8, plain, "3!") != null);
    };
    try std.testing.expectEqualStrings(original, try std.json.Stringify.valueAlloc(a, cell, .{}));
}

test "terminal number cell renders right center right in the actual grid at bounded widths" {
    terminal.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paragraphs = [_]model.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "1", .target = "One" }} },
        .{ .kind = .paragraph, .text_align = .center, .spans = &.{.{ .kind = .link, .text = "2", .target = "Two", .bold = true, .font_scale = 2 }} },
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "3", .target = "Three" }} },
    };
    const table: model.Table = .{
        .rows = &.{.{ .cells = &.{.{ .blocks = &paragraphs, .style = .{ .text_align = .right }, .background = "#b4cdcd" }} }},
        .geometry = .{ .width = .{ .unit = .px, .value = 128 } },
    };
    for ([_]usize{ 12, 16, 40 }) |width| for ([_]bool{ false, true }) |color| {
        var text: std.Io.Writer.Allocating = .init(a);
        try tableTextWidth(&text.writer, table, color, null, width);
        const plain = try NarrowTableTest.plain(a, text.written());
        var lines = std.mem.splitScalar(u8, plain, '\n');
        var positions: [3]usize = undefined;
        var count: usize = 0;
        while (lines.next()) |line| {
            for ("123", 0..) |number, index| if (std.mem.indexOfScalar(u8, line, number)) |at| {
                positions[index] = terminal.cellWidth(line[0..at]);
                count += 1;
                try std.testing.expect(terminal.cellWidth(line) <= width);
            };
        }
        try std.testing.expectEqual(@as(usize, 3), count);
        try std.testing.expectEqual(positions[0], positions[2]);
        try std.testing.expect(positions[1] < positions[0]);
        try std.testing.expectEqual(@as(usize, 4) + (positions[0] - 4) / 2, positions[1]);
    };
}

test "terminal null block alignment keeps legacy grid and bounded body bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const table: model.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "old" }} }} }} };
    var grid: std.Io.Writer.Allocating = .init(a);
    try tableTextWidth(&grid.writer, table, false, null, 40);
    try std.testing.expectEqualStrings("  │ old │\n\n", grid.written());
    const blocks = [_]model.Block{
        .{ .kind = .paragraph, .text_align = null, .spans = &.{.{ .kind = .link, .text = "same", .trail = "s", .target = "Same", .italic = true }} },
        .{ .kind = .table, .table = table },
    };
    for ([_]bool{ false, true }) |color| {
        var unchanged: std.Io.Writer.Allocating = .init(a);
        var suppressed: std.Io.Writer.Allocating = .init(a);
        try blocksTextInContext(&unchanged.writer, &blocks, color, null, .{ .columns = 40 });
        try blocksTextInContext(&suppressed.writer, &blocks, color, null, .{ .columns = 40, .alignment_suppressed = true });
        try std.testing.expectEqualStrings(suppressed.written(), unchanged.written());
    }
}

test "bounded top level alignment uses physical sides and keeps source spans unchanged" {
    terminal.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]model.Span{.{ .kind = .link, .text = "猫אב", .trail = "!", .target = "Target", .bold = true, .foreground = "#123456" }};
    const before = try std.json.Stringify.valueAlloc(a, spans, .{});
    for ([_]usize{ 8, 16, 36 }) |width| for ([_]TextAlign{ .left, .center, .right }) |alignment| for ([_]bool{ false, true }) |color| {
        const block: model.Block = .{ .kind = .paragraph, .text_align = alignment, .spans = &spans };
        var text: std.Io.Writer.Allocating = .init(a);
        var metadata: std.ArrayList(terminal.PoemLine) = .empty;
        var projection: PoemProjection = .{ .frame = &text, .allocator = a, .lines = &metadata, .table_columns = width };
        try blocksTextProjected(&text.writer, &.{block}, color, &projection);
        const plain = try NarrowTableTest.plain(a, text.written());
        const expected = switch (alignment) { .left => @as(usize, 0), .center => (width - 5) / 2, .right => width - 5 };
        try std.testing.expectEqual(expected, std.mem.indexOf(u8, plain, "猫אב!").?);
        const rows = try terminal.wrapStyledProjected(a, text.written(), width, metadata.items);
        for (rows) |row| try std.testing.expect(terminal.cellWidth(row.bytes) + row.left + row.right <= width);
        var unbounded: std.Io.Writer.Allocating = .init(a);
        var legacy: std.Io.Writer.Allocating = .init(a);
        try blocksText(&unbounded.writer, &.{block}, color);
        var no_alignment = block;
        no_alignment.text_align = null;
        try blocksText(&legacy.writer, &.{no_alignment}, color);
        try std.testing.expectEqualStrings(legacy.written(), unbounded.written());
    };
    try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(a, spans, .{}));
}

test "aligned nested cell blocks and stacked narrow grids retain per block alignment metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paragraphs = [_]model.Block{
        .{ .kind = .paragraph, .text_align = .left, .spans = &.{.{ .text = "L" }} },
        .{ .kind = .paragraph, .text_align = .center, .spans = &.{.{ .text = "M" }} },
    };
    const child: model.Table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &paragraphs, .style = .{ .text_align = .right } }} }} };
    const outer: model.Table = .{ .rows = &.{.{ .cells = &.{
        .{ .blocks = &.{.{ .kind = .table, .table = child }} },
        .{ .blocks = &paragraphs, .style = .{ .text_align = .right } },
    } }} };
    for ([_]usize{ 12, 24, 60 }) |width| {
        var text: std.Io.Writer.Allocating = .init(a);
        try tableTextWidth(&text.writer, outer, true, null, width);
        const plain = try NarrowTableTest.plain(a, text.written());
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, plain, "L"));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, plain, "M"));
        if (width == 12) {
            const second = std.mem.indexOf(u8, plain, "Row 1, column 2").?;
            try std.testing.expect(std.mem.indexOf(u8, plain[second..], "\n  │ L") != null);
            try std.testing.expect(std.mem.indexOf(u8, plain[second..], "\n  │   M") != null);
        } else {
            var left_columns: [2]usize = undefined;
            var middle_columns: [2]usize = undefined;
            var left_count: usize = 0;
            var middle_count: usize = 0;
            var lines = std.mem.splitScalar(u8, plain, '\n');
            while (lines.next()) |line| for (line, 0..) |byte, offset| {
                if (byte == 'L') { left_columns[left_count] = terminal.cellWidth(line[0..offset]); left_count += 1; }
                if (byte == 'M') { middle_columns[middle_count] = terminal.cellWidth(line[0..offset]); middle_count += 1; }
            };
            try std.testing.expectEqual(@as(usize, 2), left_count);
            try std.testing.expectEqual(@as(usize, 2), middle_count);
            for (left_columns, middle_columns) |left, middle| try std.testing.expectEqual(left + 1, middle);
        }
    }
}

test "aligned terminal definitions share numbering with ordinary siblings" {
    const a = std.testing.allocator;
    const blocks = [_]model.Block{
        .{ .kind = .definition, .spans = &.{.{ .text = "A" }} },
        .{ .kind = .definition, .text_align = .center, .spans = &.{.{ .text = "B" }} },
        .{ .kind = .definition, .spans = &.{.{ .text = "C" }} },
        .{ .kind = .definition, .text_align = .right, .spans = &.{.{ .text = "D" }} },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try blocksTextInContext(&out.writer, &blocks, false, null, .{ .columns = 12 });
    try std.testing.expectEqualStrings("1. A\n    2. B\n3. C\n        4. D\n", out.written());
}


const CrossSectionFloatTest = struct {
    // Source-derived/synthetic expected E shape; not an earned EU Reader fixture.
    const entry: model.Entry = .{
        .title = "dwa", .kind = .language, .language = "poloniera", .language_code = "pl",
        .sections = &.{
            .{ .level = 2, .title = "Poloniera", .blocks = &.{.{ .kind = .table, .table = .{
                .geometry = .{ .width = .{ .unit = .px, .value = 250 }, .border = 2, .cell_padding = 4, .cell_spacing = 0 },
                .style = .{ .float_side = .right, .margins = .{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .px, .value = 0 }, .bottom = .{ .unit = .px, .value = 0 }, .left = .{ .unit = .px, .value = 20 } } },
                .rows = &.{
                    .{ .cells = &.{.{ .colspan = 2, .background = "#b4cdcd", .style = .{ .text_align = .right }, .blocks = &.{
                        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "N_ONE", .target = "one" }} },
                        .{ .kind = .paragraph, .text_align = .center, .spans = &.{.{ .kind = .link, .text = "N_TWO", .target = "two", .bold = true }} },
                        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "N_TRI", .target = "three" }} },
                    } }} },
                    .{ .cells = &.{ .{ .spans = &.{.{ .text = "cardinal" }} }, .{ .spans = &.{.{ .text = "dwa" }} } } },
                    .{ .cells = &.{ .{ .spans = &.{.{ .text = "ordinal" }} }, .{ .spans = &.{.{ .text = "drugi" }} } } },
                },
            } }} },
            .{ .level = 3, .title = "Ahoskera", .blocks = &.{
                .{ .kind = .list_item, .depth = 2, .list_path = ":*", .spans = &.{.{ .kind = .link, .text = "AHO_A", .target = "pronunciation", .trail = "!", .foreground = "#123456" }} },
                .{ .kind = .list_item, .depth = 2, .list_path = ":*", .spans = &.{.{ .text = "AHO_B" }} },
            } },
            .{ .level = 3, .title = "Adjektiboa", .blocks = &.{
                .{ .kind = .indent, .depth = 1, .list_path = ":", .spans = &.{.{ .text = "ADJ_I" }} },
                .{ .kind = .list_item, .depth = 2, .list_path = ":#", .spans = &.{.{ .kind = .external_link, .text = "ADJ_L", .target = "https://example.test/two" }} },
            } },
            .{ .level = 3, .title = "Later", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "AFTER_FLOW" }} }} },
        },
        .references = &.{.{ .number = 1, .group_number = 1, .spans = &.{.{ .text = "FOOT_NOTE" }} }},
    };
    const Capture = struct {
        text: []u8, events: []FlowEvent, poems: []terminal.PoemLine, selected: usize,
        fn deinit(self: Capture, a: std.mem.Allocator) void { a.free(self.poems); a.free(self.events); a.free(self.text); }
    };
    fn capture(a: std.mem.Allocator, value: model.Entry, width: usize, color: bool, expanded: []const usize) !Capture {
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        var poems: std.ArrayList(terminal.PoemLine) = .empty;
        defer poems.deinit(a);
        var flow: FloatProjection = .{ .allocator = a, .frame = &text, .columns = width };
        defer flow.events.deinit(a);
        var projection: PoemProjection = .{ .frame = &text, .allocator = a, .lines = &poems, .table_columns = width, .float_flow = &flow };
        const selected = try entryTextFoldedProjected(&text, value, color, .{ .details = true }, expanded, 1, &projection);
        const owned = try text.toOwnedSlice();
        errdefer a.free(owned);
        const events = try flow.events.toOwnedSlice(a);
        errdefer a.free(events);
        return .{ .text = owned, .events = events, .poems = try poems.toOwnedSlice(a), .selected = selected };
    }
    fn column(line: []const u8, marker: []const u8) ?usize {
        const at = std.mem.indexOf(u8, line, marker) orelse return null;
        return terminal.cellWidth(line[0..at]);
    }
};

test "cross section terminal float admits source derived EU heading list and indent shape" {
    terminal.initLocale();
    const a = std.testing.allocator;
    const F = CrossSectionFloatTest;
    const before = try std.json.Stringify.valueAlloc(a, F.entry, .{});
    defer a.free(before);
    const captured = try F.capture(a, F.entry, 52, true, &.{});
    defer captured.deinit(a);
    const layout = try floatLayoutAlloc(a, captured.text, 52, captured.poems, captured.events, true);
    defer layout.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), layout.unsupported);
    const plain = try NarrowTableTest.plain(a, layout.text);
    defer a.free(plain);
    for ([_][]const u8{ "N_ONE", "N_TWO", "N_TRI", "AHO_A!", "AHO_B", "ADJ_I", "ADJ_L", "AFTER_FLOW", "FOOT_NOTE" }) |marker| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, marker));
    var crossed_heading = false;
    var crossed_list = false;
    var crossed_indent = false;
    var lines = std.mem.splitScalar(u8, plain, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Ahoskera") != null) { crossed_heading = std.mem.indexOf(u8, line, "│") != null; }
        if (std.mem.indexOf(u8, line, "AHO_A!") != null) { crossed_list = std.mem.indexOf(u8, line, "│") != null; }
        if (std.mem.indexOf(u8, line, "ADJ_I") != null) { crossed_indent = std.mem.indexOf(u8, line, "│") != null; }
    }
    try std.testing.expect(crossed_heading and crossed_list and crossed_indent);
    const selected_row = layout.rowForOffset(captured.selected);
    const selected_plain = try NarrowTableTest.plain(a, layout.rows[selected_row].bytes);
    defer a.free(selected_plain);
    try std.testing.expect(std.mem.indexOf(u8, selected_plain, "Ahoskera") != null);
    const after = try std.json.Stringify.valueAlloc(a, F.entry, .{});
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "cross section terminal floats use physical sides checked px and explicit unsupported metrics" {
    terminal.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = CrossSectionFloatTest;
    for ([_]@import("blob_encoder").presentation_types.TableFloatSide{ .left, .right }) |side| {
        const sections = try a.dupe(model.Section, F.entry.sections);
        const blocks = try a.dupe(model.Block, sections[0].blocks);
        blocks[0].table.?.style.?.float_side = side;
        sections[0].blocks = blocks;
        var value = F.entry;
        value.sections = sections;
        const captured = try F.capture(a, value, 52, false, &.{});
        const layout = try floatLayoutAlloc(a, captured.text, 52, captured.poems, captured.events, false);
        try std.testing.expectEqual(@as(usize, 0), layout.unsupported);
        var saw = false;
        for (layout.rows) |row| if (std.mem.indexOf(u8, row.bytes, "AHO_A!") != null) {
            saw = true;
            const prose_column = F.column(row.bytes, "AHO_A!").?;
            const border_column = F.column(row.bytes, "│").?;
            if (side == .right) {
                try std.testing.expectEqual(@as(usize, 20), border_column);
                try std.testing.expect(prose_column < border_column);
            } else {
                try std.testing.expectEqual(@as(usize, 3), border_column);
                try std.testing.expect(prose_column > border_column);
            }
            try std.testing.expect(terminal.cellWidth(row.bytes) <= 52);
        };
        try std.testing.expect(saw);
        const narrow = try F.capture(a, value, 36, false, &.{});
        const narrow_layout = try floatLayoutAlloc(a, narrow.text, 36, narrow.poems, narrow.events, false);
        try std.testing.expectEqual(@as(usize, 1), narrow_layout.unsupported);
        for (narrow_layout.rows) |row| if (std.mem.indexOf(u8, row.bytes, "AHO_A!") != null) try std.testing.expect(std.mem.indexOf(u8, row.bytes, "│") == null);
    }
    try std.testing.expect(floatRowsWithinBudget(24, 52, 4 * 1024 * 1024));
    try std.testing.expect(!floatRowsWithinBudget(std.math.maxInt(usize), 52, 4 * 1024 * 1024));
    try std.testing.expectEqual(@as(?usize, 3), horizontalFloatMargin(.{ .unit = .px, .value = 20 }, 52));
    try std.testing.expectEqual(@as(?usize, 0), horizontalFloatMargin(.{ .unit = .em, .value = 0 }, 52));
    try std.testing.expect(horizontalFloatMargin(.{ .unit = .em, .value = 0.5 }, 52) == null);
    try std.testing.expect(horizontalFloatMargin(.{ .unit = .px, .value = std.math.floatMax(f32) }, 52) == null);
    const sections = try a.dupe(model.Section, F.entry.sections);
    const blocks = try a.dupe(model.Block, sections[0].blocks);
    blocks[0].table.?.style.?.margins.?.top = .{ .unit = .px, .value = 1 };
    sections[0].blocks = blocks;
    var value = F.entry;
    value.sections = sections;
    const captured = try F.capture(a, value, 52, false, &.{});
    const layout = try floatLayoutAlloc(a, captured.text, 52, captured.poems, captured.events, false);
    try std.testing.expectEqual(@as(usize, 1), layout.unsupported);
}

test "high terminal float drains before normal wide grid and footer references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = CrossSectionFloatTest;
    const rows = try a.alloc(@import("blob_encoder").presentation_types.Row, 24);
    for (rows, 0..) |*row, index| {
        const cells = try a.alloc(@import("blob_encoder").presentation_types.Cell, 1);
        const spans = try a.alloc(model.Span, 1);
        spans[0] = .{ .text = try std.fmt.allocPrint(a, "HIGH_{d}", .{index}) };
        cells[0] = .{ .spans = spans };
        row.* = .{ .cells = cells };
    }
    const sections = try a.dupe(model.Section, F.entry.sections);
    const first = try a.dupe(model.Block, sections[0].blocks);
    first[0].table.?.rows = rows;
    sections[0].blocks = first;
    var value = F.entry;
    value.sections = sections;
    const captured = try F.capture(a, value, 52, true, &.{});
    const layout = try floatLayoutAlloc(a, captured.text, 52, captured.poems, captured.events, true);
    const plain = try NarrowTableTest.plain(a, layout.text);
    try std.testing.expect(std.mem.indexOf(u8, plain, "HIGH_23").? < std.mem.indexOf(u8, plain, "References").?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "FOOT_NOTE"));
    for (layout.rows) |row| {
        const visible = try NarrowTableTest.plain(a, row.bytes);
        if (std.mem.indexOf(u8, visible, "References") != null or std.mem.indexOf(u8, visible, "FOOT_NOTE") != null) try std.testing.expect(std.mem.indexOf(u8, visible, "│") == null);
    }
    const later = try a.dupe(model.Block, sections[3].blocks);
    later[0] = .{ .kind = .table, .table = .{ .geometry = .{ .width = .{ .unit = .px, .value = 400 } }, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "WIDE_LATER" }} }} }} } };
    sections[3].blocks = later;
    const with_grid = try F.capture(a, value, 52, false, &.{});
    const with_grid_layout = try floatLayoutAlloc(a, with_grid.text, 52, with_grid.poems, with_grid.events, false);
    try std.testing.expect(std.mem.indexOf(u8, with_grid_layout.text, "HIGH_23").? < std.mem.indexOf(u8, with_grid_layout.text, "WIDE_LATER").?);
    // A fitting ordinary table is one rectangular box even when the adjacent
    // float ends before its final row. Both physical sides retain that origin.
    const prefix = "│F0│\n│F1│\n";
    const logical = prefix ++ "│G0│\n│G1│\n│G2│\n│G3│\n";
    for ([_]@import("blob_encoder").presentation_types.TableFloatSide{ .left, .right }) |side| for ([_]?TextAlign{ null, .center, .right }) |alignment| {
        const events = [_]FlowEvent{
            .{ .kind = .float_grid, .start = 0, .end = prefix.len, .side = side },
            .{ .kind = .grid, .start = prefix.len, .end = logical.len, .alignment = alignment },
        };
        const fixed = try floatLayoutAlloc(a, logical, 16, &.{}, &events, false);
        var grid_rows: usize = 0;
        for (fixed.rows) |row| if (CrossSectionFloatTest.column(row.bytes, "│G")) |column| {
            grid_rows += 1;
            const extra: usize = if (alignment == .right) 8 else if (alignment == .center) 4 else 0;
            try std.testing.expectEqual(@as(usize, if (side == .left) 4 else 0) + extra, column);
            try std.testing.expect(terminal.cellWidth(row.bytes) <= 16);
        };
        try std.testing.expectEqual(@as(usize, 4), grid_rows);
    };
    // Exercise the real capture route as well as the fixed-rectangle event case.
    later[0] = .{ .kind = .table, .table = .{ .geometry = .{ .width = .{ .unit = .px, .value = 64 } }, .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "AG" }} }} }} } };
    for ([_]@import("blob_encoder").presentation_types.TableFloatSide{ .left, .right }) |side| {
        first[0].table.?.style.?.float_side = side;
        var prior_column: ?usize = null;
        for ([_]?TextAlign{ null, .center, .right }) |alignment| {
            later[0].text_align = alignment;
            const aligned = try F.capture(a, value, 52, false, &.{});
            var saw_aligned_grid = false;
            for (aligned.events) |event| if (event.kind == .grid and event.alignment == alignment) { saw_aligned_grid = true; };
            try std.testing.expect(saw_aligned_grid);
            const placed = try floatLayoutAlloc(a, aligned.text, 52, aligned.poems, aligned.events, false);
            var marker_column: ?usize = null;
            for (placed.rows) |row| if (F.column(row.bytes, "AG")) |column| { marker_column = column; };
            try std.testing.expect(marker_column != null);
            if (prior_column) |column| try std.testing.expect(marker_column.? > column);
            prior_column = marker_column;
        }
    }
}

test "terminal float ending mid prose reflows original Unicode with seeded SGR and origins" {
    terminal.initLocale();
    const a = std.testing.allocator;
    const prefix = "│F0│\n│F1│\n";
    const logical = prefix ++ "\x1b[1;38;2;18;52;86mאב猫é 👩‍💻 אב猫é 👩‍💻 אב猫é 👩‍💻 END_MARK\x1b[0m\n";
    const events = [_]FlowEvent{
        .{ .kind = .float_grid, .start = 0, .end = prefix.len, .side = .right },
        .{ .kind = .text, .start = prefix.len, .end = logical.len },
    };
    const layout = try floatLayoutAlloc(a, logical, 18, &.{}, &events, true);
    defer layout.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), layout.unsupported);
    const plain = try NarrowTableTest.plain(a, layout.text);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "END_MARK"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, plain, "猫"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, plain, "👩‍💻"));
    try std.testing.expect(layout.rows.len > 2);
    try std.testing.expect(std.mem.indexOf(u8, layout.rows[2].bytes, "\x1b[38;2;18;52;86m") != null);
    for (layout.rows) |row| try std.testing.expect(terminal.cellWidth(row.bytes) <= 18);
    try std.testing.expectEqual(@as(usize, 0), layout.rowForOffset(prefix.len));
    try std.testing.expect(layout.rowForOffset(logical.len - 8) >= 2);
}

test "terminal float layout allocation failures keep borrowed logical input unchanged" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            const prefix = "│F│\n";
            const text = prefix ++ "word word word\n";
            const events = [_]FlowEvent{
                .{ .kind = .float_grid, .start = 0, .end = prefix.len, .side = .left },
                .{ .kind = .text, .start = prefix.len, .end = text.len },
            };
            // All output writers inside this call are Writer.Allocating. Its
            // installed drain maps allocation failure to WriteFailed; normalize
            // only that known harness boundary for the allocator-failure sweep.
            const layout = floatLayoutAlloc(a, text, 16, &.{}, &events, true) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer layout.deinit(a);
            try std.testing.expectEqualStrings("│F│\nword word word\n", text);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "terminal float render budget falls back to complete serial body without model changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = CrossSectionFloatTest;
    const sections = try a.dupe(model.Section, F.entry.sections);
    const blocks = try a.dupe(model.Block, sections[0].blocks);
    blocks[0].table.?.caption = &.{.{ .kind = .link, .text = "BUDGET_CAPTION", .target = "caption-target", .trail = "!" }};
    sections[0].blocks = blocks;
    var value = F.entry;
    value.sections = sections;
    const before = try std.json.Stringify.valueAlloc(a, value, .{});
    const captured = try F.capture(a, value, 52, false, &.{});
    const serial = try floatLayoutWithBudgetAlloc(a, captured.text, 52, captured.poems, captured.events, false, 1);
    try std.testing.expectEqual(@as(usize, 1), serial.unsupported);
    // Every line fits: declining placement must preserve exact serial output,
    // including the authored caption/trail and the article/reference remainder.
    try std.testing.expectEqualStrings(captured.text, serial.text);
    for ([_][]const u8{ "BUDGET_CAPTION!", "N_ONE", "N_TWO", "N_TRI", "AHO_A!", "AHO_B", "ADJ_I", "ADJ_L", "AFTER_FLOW", "FOOT_NOTE" }) |marker| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, serial.text, marker));
    const after = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings("caption-target", value.sections[0].blocks[0].table.?.caption[0].target);
}


test "generic advisory details preserve plain ANSI body links and distinct abbreviation meaning" {
    const a = std.testing.allocator;
    const spans = [_]model.Span{
        .{ .kind = .link, .text = "label", .target = "Destination", .tooltip = "link advice" },
        .{ .text = " " }, .{ .text = "abbr", .explanation = "expansion B" },
        .{ .text = " clear", .tooltip = "" },
        .{ .kind = .line_break, .tooltip = "line advice" },
        .{ .image = .{ .file = "Diagram.svg", .alt = "  " }, .tooltip = "image advice" },
        .{ .image = .{ .file = "Empty.svg", .tooltip = "" }, .tooltip = "blocked ancestor" },
        .{ .image = .{ .file = "Own.svg", .tooltip = "own image" }, .tooltip = "blocked ancestor" },
        .{ .text = "zero", .font_scale = 0, .tooltip = "zero advice" },
    };
    const entry: model.Entry = .{ .title = "advice", .kind = .citations, .preamble_spans = &spans };
    const plain_spans = try a.dupe(model.Span, &spans); defer a.free(plain_spans);
    for (plain_spans) |*span| span.tooltip = null;
    var plain = entry; plain.preamble_spans = plain_spans;
    var actual: std.Io.Writer.Allocating = .init(a); defer actual.deinit();
    var expected: std.Io.Writer.Allocating = .init(a); defer expected.deinit();
    for ([_]bool{ false, true }) |color| {
        actual.clearRetainingCapacity(); expected.clearRetainingCapacity();
        try entryTextWithDetails(&actual.writer, entry, color, false);
        try entryTextWithDetails(&expected.writer, plain, color, false);
        try std.testing.expectEqualStrings(expected.written(), actual.written());
    }
    var advice = try Advisories.init(a, entry); defer advice.deinit();
    try std.testing.expectEqual(@as(usize, 5), advice.items.items.len);
    try std.testing.expectEqualStrings("label", advice.items.items[0].label);
    try std.testing.expectEqualStrings("link advice", advice.items.items[0].tooltip);
    try std.testing.expectEqualStrings("", advice.items.items[1].label);
    try std.testing.expectEqualStrings("line advice", advice.items.items[1].tooltip);
    try std.testing.expectEqualStrings("Diagram.svg", advice.items.items[2].label);
    try std.testing.expectEqualStrings("image advice", advice.items.items[2].tooltip);
    try std.testing.expectEqualStrings("Own.svg", advice.items.items[3].label);
    try std.testing.expectEqualStrings("own image", advice.items.items[3].tooltip);
    try std.testing.expectEqualStrings("zero advice", advice.items.items[4].tooltip);
    var abbreviation = try Abbreviations.init(a, entry); defer abbreviation.deinit();
    try std.testing.expectEqual(@as(usize, 1), abbreviation.items.items.len);
    try std.testing.expectEqualStrings("expansion B", abbreviation.items.items[0].explanation);
    actual.clearRetainingCapacity(); try entryText(&actual.writer, entry, false);
    try std.testing.expect(std.mem.indexOf(u8, actual.written(), "\nAbbreviations\nabbr: expansion B\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual.written(), "\nText details\nlabel: link advice\nline advice\nDiagram.svg: image advice\nOwn.svg: own image\nzero: zero advice\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual.written(), "blocked ancestor") == null);
    actual.clearRetainingCapacity(); _ = try entryTextFolded(&actual, entry, false, .{ .details = false }, &.{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, actual.written(), "d: text details") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual.written(), "link advice") == null);
    try std.testing.expectEqualStrings("Destination", spans[0].target);
    const own_only = [_]model.Span{.{ .image = .{ .file = "Own.svg", .tooltip = "own image" } }};
    const own_entry: model.Entry = .{ .title = "own image", .kind = .citations, .preamble_spans = &own_only };
    try std.testing.expect(entryHasAdvisories(own_entry));
}

test "tooltip only heading companions render once and advisory traversal keeps nested scopes" {
    const a = std.testing.allocator;
    const heading = [_]model.Span{.{ .text = "Noun", .tooltip = "" }};
    const body = [_]model.Span{.{ .text = "Body." }};
    const normal_blocks = [_]model.Block{.{ .kind = .paragraph, .spans = &body }};
    const rich_blocks = [_]model.Block{.{ .kind = .heading, .level = 3, .spans = &heading }, .{ .kind = .paragraph, .spans = &body }};
    const normal_sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &normal_blocks }};
    const rich_sections = [_]model.Section{.{ .level = 3, .title = "Noun", .blocks = &rich_blocks }};
    const entry: model.Entry = .{ .title = "entry", .kind = .language, .language = "English", .sections = &rich_sections };
    var normal = entry; normal.sections = &normal_sections;
    try std.testing.expect(sectionHeadingCompanion(rich_sections[0]) != null);
    var actual: std.Io.Writer.Allocating = .init(a); defer actual.deinit();
    var expected: std.Io.Writer.Allocating = .init(a); defer expected.deinit();
    try entryText(&actual.writer, entry, false); try entryText(&expected.writer, normal, false);
    try std.testing.expectEqualStrings(expected.written(), actual.written());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, actual.written(), "Noun"));
    const advice_span = [_]model.Span{.{ .kind = .link, .text = "cell", .target = "Cell", .tooltip = "nested advice" }};
    const child_blocks = [_]model.Block{.{ .kind = .paragraph, .spans = &advice_span }};
    const rows = [_]@import("blob_encoder").presentation_types.Row{.{ .cells = &.{.{ .blocks = &child_blocks }} }};
    const tables = [_]model.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const refs = [_]model.Reference{.{ .number = 1, .group_number = 1, .blocks = &tables }};
    var nested = entry; nested.references = &refs;
    var advice = try Advisories.init(a, nested); defer advice.deinit();
    try std.testing.expectEqual(@as(usize, 1), advice.items.items.len);
    try std.testing.expectEqualStrings("cell", advice.items.items[0].label);
    try std.testing.expectEqualStrings("nested advice", advice.items.items[0].tooltip);
    try std.testing.expect(entryHasAdvisories(nested));
    actual.clearRetainingCapacity(); try advice.write(&actual.writer);
    try std.testing.expectEqualStrings("\nText details\ncell: nested advice\n", actual.written());
}


test "generic advisory details clean every owned label allocation failure" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            const values = [_]model.Span{
                .{ .kind = .link, .text = "word", .target = "Word", .tooltip = "one" },
                .{ .text = " " }, .{ .kind = .line_break, .tooltip = "two" },
                .{ .image = .{ .file = "Picture.svg" }, .tooltip = "three" },
            };
            const entry: model.Entry = .{ .title = "advice allocation", .kind = .citations, .preamble_spans = &values };
            var advice = try Advisories.init(a, entry); defer advice.deinit();
            try std.testing.expectEqual(@as(usize, 3), advice.items.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

// Source-only J figure controls. An older H model must report these skipped,
// never earn figure qualification merely by compiling the compatibility helper.
const FigureOutputTest = struct {
    fn block(kind: @FieldType(model.Block, "kind")) model.Block {
        const T = @import("blob_encoder").presentation_types;
        const edges = T.StyleEdges.all(.{ .unit = .px, .value = 0 });
        return .{ .kind = kind, .figure = .{
            .caption = &.{.{ .kind = .link, .text = "Caption", .target = "Caption target", .bold = true,
                .explanation = "Caption expansion", .tooltip = "Caption advice" }},
            .image_span = .{ .kind = .link, .target = "File:Map.svg", .tooltip = "Image advice", .image = .{
                .file = "Map.svg", .width_px = 400, .alt = "Map", .border = true, .map = .{
                    .regions = &.{.{ .shape = .rectangle, .coordinates = &.{ 0, 0, 400, 200 },
                        .action = .{ .kind = .internal, .target = "Region target", .target_fragment = "Part", .label = "Region label" } }},
                    .default_action = .{ .kind = .external, .target = "https://example.invalid/default", .label = "Default label" },
                    .description = .bottom_right,
                },
            } },
            .format = .thumbnail, .sizing = .requested_fit, .placement = .float_right, .clear = .right,
            .margins = edges, .image_insets = edges, .caption_padding = edges,
            .caption_font_scale = 0.884, .caption_line_height = .{ .unit = .em, .value = 1.2376 },
            .frame_background = .{ .kind = .native_theme }, .frame_border = .{ .kind = .none },
            .image_background = .{ .kind = .transparent }, .image_border = .{ .kind = .none },
            .caption_foreground = .{ .kind = .native_theme }, .caption_background = .{ .kind = .transparent },
        } };
    }
    fn entry() model.Entry {
        return comptime fixture: {
        var numbered = block(.list_item);
        numbered.depth = 2; numbered.list_path = "*#"; numbered.number = "7";
        numbered.figure.?.image_span.image.?.width_px = 200;
        break :fixture .{ .title = "Figure", .kind = .language, .language = "Unclassified", .sections = &.{.{ .level = 3, .title = "Body", .blocks = &.{
            block(.paragraph),
            .{ .kind = .paragraph, .spans = &.{
                .{ .kind = .link, .text = "Region fallback", .target = "Region target", .target_fragment = "Part" },
                .{ .kind = .text, .text = " / " },
                .{ .kind = .external_link, .text = "Default fallback", .target = "https://example.invalid/default" },
            } },
            .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .blocks = &.{numbered} }} }} } },
        } }}, .references = &.{.{ .kind = .fragment, .number = 1, .group_number = null, .blocks = &.{block(.paragraph)} }},
            .media = &.{.{ .file = "Map.svg", .kind = .image, .caption = "Map" }} };
        };
    }
};

test "figure logical body keeps image caption order and list marker outside once" {
    if (comptime @hasField(model.Block, "figure")) {
        const a = std.testing.allocator;
        var value = FigureOutputTest.block(.paragraph);
        const before = try std.json.Stringify.valueAlloc(a, value, .{});
        defer a.free(before);
        for ([_]bool{ false, true }) |color| {
            var out: std.Io.Writer.Allocating = .init(a);
            defer out.deinit();
            try blocksText(&out.writer, &.{value}, color);
            const plain = try NarrowTableTest.plain(a, out.written());
            defer a.free(plain);
            try std.testing.expectEqualStrings("[image: Map] Caption\n\n", plain);
            if (color) try std.testing.expect(OrderedCellOutputTest.boldAt(out.written(), std.mem.indexOf(u8, out.written(), "Caption").?));
            out.clearRetainingCapacity();
            value.kind = .list_item; value.depth = 2; value.list_path = "*#"; value.number = "7";
            try blocksTextInContext(&out.writer, &.{value}, color, null, .{ .columns = 80 });
            const numbered = try NarrowTableTest.plain(a, out.written());
            defer a.free(numbered);
            try std.testing.expectEqualStrings("    7. [image: Map] Caption\n", numbered);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, numbered, "7. "));
            value = FigureOutputTest.block(.paragraph);
        }
        var captionless = value; captionless.figure.?.caption = &.{};
        var empty: std.Io.Writer.Allocating = .init(a); defer empty.deinit();
        try blocksText(&empty.writer, &.{captionless}, false);
        try std.testing.expectEqualStrings("[image: Map]\n\n", empty.written());
        // Caption alignment is not placement for the whole image/list item.
        value.text_align = .right;
        empty.clearRetainingCapacity();
        try blocksTextInContext(&empty.writer, &.{value}, false, null, .{ .columns = 80 });
        try std.testing.expectEqualStrings("[image: Map] Caption\n\n", empty.written());
        value.text_align = null;
        // Physical figure paint is preserved as data, not invented ANSI frame
        // geometry. Both explicit no-paint and solid/RGB tags remain unchanged.
        var painted = value;
        painted.figure.?.frame_background = .{ .kind = .rgb, .value = "#ffeecc" };
        painted.figure.?.frame_border = .{ .kind = .solid, .width = .{ .unit = .px, .value = 2 }, .color = .{ .kind = .transparent } };
        const paint_before = try std.json.Stringify.valueAlloc(a, painted, .{}); defer a.free(paint_before);
        empty.clearRetainingCapacity();
        try blocksText(&empty.writer, &.{painted}, false);
        try std.testing.expectEqualStrings("[image: Map] Caption\n\n", empty.written());
        const paint_after = try std.json.Stringify.valueAlloc(a, painted, .{}); defer a.free(paint_after);
        try std.testing.expectEqualStrings(paint_before, paint_after);
        const after = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
        try std.testing.expect(value.figure.?.image_span.image.?.border);
        try std.testing.expect(value.figure.?.image_border.kind == .none);
        try std.testing.expect(value.figure.?.image_background.kind == .transparent);
        try std.testing.expectEqualStrings("Region target", value.figure.?.image_span.image.?.map.?.regions[0].action.target);
        try std.testing.expectEqualStrings("https://example.invalid/default", value.figure.?.image_span.image.?.map.?.default_action.?.target);
        try std.testing.expectEqualSlices(f64, &.{ 0, 0, 400, 200 }, value.figure.?.image_span.image.?.map.?.regions[0].coordinates);
    } else return error.SkipZigTest;
}

test "figure recursive visitors keep real actions details and media ownership once" {
    if (comptime @hasField(model.Block, "figure")) {
        const a = std.testing.allocator;
        const value = FigureOutputTest.entry();
        const before = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(before);
        const Links = struct {
            count: usize = 0,
            fn spans(self: *@This(), values: []const model.Span) !bool {
                const expected = [_][]const u8{ "File:Map.svg", "Caption target", "Region target", "https://example.invalid/default", "File:Map.svg", "Caption target", "File:Map.svg", "Caption target" };
                for (values) |span| if (span.kind == .link or span.kind == .external_link) {
                    try std.testing.expect(self.count < expected.len);
                    try std.testing.expectEqualStrings(expected[self.count], span.target);
                    self.count += 1;
                };
                return false;
            }
        };
        var links: Links = .{}; _ = try visitEntrySpanLists(value, &links);
        try std.testing.expectEqual(@as(usize, 8), links.count);
        var abbreviations = try Abbreviations.init(a, value); defer abbreviations.deinit();
        try std.testing.expectEqual(@as(usize, 1), abbreviations.items.items.len);
        try std.testing.expectEqualStrings("Caption expansion", abbreviations.items.items[0].explanation);
        var advice = try Advisories.init(a, value); defer advice.deinit();
        try std.testing.expectEqual(@as(usize, 2), advice.items.items.len);
        try std.testing.expectEqualStrings("Image advice", advice.items.items[0].tooltip);
        try std.testing.expectEqualStrings("Caption advice", advice.items.items[1].tooltip);
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        var captions = try VisibleMediaCaptions.init(arena.allocator(), value.media, true);
        try captions.observeBlocks(value.sections[0].blocks);
        try std.testing.expect(captions.inline_seen[0] and captions.seen[0]);
        var rendered: std.Io.Writer.Allocating = .init(a); defer rendered.deinit();
        try entryText(&rendered.writer, value, false);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rendered.written(), "[image: Map]"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered.written(), "Map.svg"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered.written(), "Region fallback"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered.written(), "Default fallback"));
        var image_only = FigureOutputTest.block(.paragraph); image_only.figure.?.caption = &.{};
        const image_entry: model.Entry = .{ .title = "Image advice", .kind = .language, .sections = &.{.{ .level = 3, .title = "Body", .blocks = &.{image_only} }} };
        try std.testing.expect(entryHasAdvisories(image_entry));
        const after = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
    } else return error.SkipZigTest;
}

test "figure detail labels clean every owned allocation failure" {
    if (comptime @hasField(model.Block, "figure")) {
        const Routine = struct {
            fn run(a: std.mem.Allocator) !void {
                const value = FigureOutputTest.entry();
                var abbreviations = try Abbreviations.init(a, value); defer abbreviations.deinit();
                var advice = try Advisories.init(a, value); defer advice.deinit();
                try std.testing.expectEqual(@as(usize, 1), abbreviations.items.items.len);
                try std.testing.expectEqual(@as(usize, 2), advice.items.items.len);
            }
        };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Routine.run, .{});
    } else return error.SkipZigTest;
}

test "figure caption ANSI inherits RGB paint while child overrides and logical text stay intact" {
    if (comptime @hasField(model.Block, "figure")) {
        const a = std.testing.allocator;
        const T = @import("blob_encoder").presentation_types;
        const inherited = [3]u8{ 119, 136, 153 };
        const following: model.Block = .{ .kind = .paragraph, .spans = &.{.{ .text = "Following body" }} };
        const Render = struct {
            fn run(allocator: std.mem.Allocator, block: model.Block, tail: model.Block, color: bool) ![]u8 {
                var out: std.Io.Writer.Allocating = .init(allocator); defer out.deinit();
                try blocksTextInContext(&out.writer, &.{ block, tail }, color, null,
                    .{ .cell_style = .{ .background = .{ 119, 136, 153 } } });
                return allocator.dupe(u8, out.written());
            }
        };
        var value = FigureOutputTest.block(.paragraph);
        value.figure.?.caption = &.{
            .{ .kind = .link, .text = "Fallback   spacing ", .target = "Paint target" },
            .{ .text = "Child foreground ", .foreground = "#cc0000" },
            .{ .text = "Child background", .background = "#000000" },
            .{ .kind = .line_break, .trail = "Break   trail" },
        };
        value.figure.?.caption_foreground = .{ .kind = .rgb, .value = "#123456" };
        const Case = struct { caption: T.FigureColor, frame: T.FigureColor, expected: ?[3]u8 };
        const cases = [_]Case{
            .{ .caption = .{ .kind = .rgb, .value = "#ffeecc" }, .frame = .{ .kind = .rgb, .value = "#334455" }, .expected = .{ 255, 238, 204 } },
            .{ .caption = .{ .kind = .transparent }, .frame = .{ .kind = .rgb, .value = "#334455" }, .expected = .{ 51, 68, 85 } },
            .{ .caption = .{ .kind = .transparent }, .frame = .{ .kind = .transparent }, .expected = inherited },
            .{ .caption = .{ .kind = .native_theme }, .frame = .{ .kind = .rgb, .value = "#334455" }, .expected = null },
            .{ .caption = .{ .kind = .transparent }, .frame = .{ .kind = .native_theme }, .expected = null },
        };
        var old_body: std.Io.Writer.Allocating = .init(a); defer old_body.deinit();
        try blocksTextInContext(&old_body.writer, &.{following}, true, null, .{ .cell_style = .{ .background = inherited } });
        const expected_following = TypedColorOutputTest.at(old_body.written(), std.mem.indexOf(u8, old_body.written(), "Following").?);
        var old_image: std.Io.Writer.Allocating = .init(a); defer old_image.deinit();
        try spansTextDisplayOnBackground(&old_image.writer, &.{value.figure.?.image_span}, true, null, false, inherited, false);
        const expected_image = TypedColorOutputTest.at(old_image.written(), std.mem.indexOf(u8, old_image.written(), "[image").?);
        for (cases) |case| {
            value.figure.?.caption_background = case.caption; value.figure.?.frame_background = case.frame;
            const before = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(before);
            const plain = try Render.run(a, value, following, false); defer a.free(plain);
            const ansi = try Render.run(a, value, following, true); defer a.free(ansi);
            const ansi_plain = try NarrowTableTest.plain(a, ansi); defer a.free(ansi_plain);
            try std.testing.expectEqualStrings(plain, ansi_plain);
            try std.testing.expect(std.mem.indexOf(u8, plain, "Fallback spacing") != null);
            try std.testing.expect(std.mem.indexOf(u8, plain, "Break trail") != null);
            const at = struct {
                fn text(bytes: []const u8, needle: []const u8) TypedColorOutputTest.Colors {
                    return TypedColorOutputTest.at(bytes, std.mem.indexOf(u8, bytes, needle).?);
                }
            }.text;
            const fallback = at(ansi, "Fallback");
            const child_foreground = at(ansi, "Child foreground");
            const child_background = at(ansi, "Child background");
            const trail = at(ansi, "Break");
            try std.testing.expectEqual(@as(?[3]u8, .{ 18, 52, 86 }), fallback.foreground);
            try std.testing.expectEqual(case.expected, fallback.background);
            try std.testing.expectEqual(@as(?[3]u8, .{ 204, 0, 0 }), child_foreground.foreground);
            try std.testing.expectEqual(case.expected, child_foreground.background);
            try std.testing.expectEqual(@as(?[3]u8, .{ 18, 52, 86 }), child_background.foreground);
            try std.testing.expectEqual(@as(?[3]u8, .{ 0, 0, 0 }), child_background.background);
            try std.testing.expectEqualDeep(fallback, trail);
            try std.testing.expectEqualDeep(expected_image, at(ansi, "[image"));
            try std.testing.expectEqualDeep(expected_following, at(ansi, "Following"));
            const after = try std.json.Stringify.valueAlloc(a, value, .{}); defer a.free(after);
            try std.testing.expectEqualStrings(before, after);
        }
        // Native-theme uses the default terminal palette, not frame/inherited
        // author RGB. Transparent ink has no terminal alpha simulation claim.
        for ([_]T.FigureColor{ .{ .kind = .native_theme }, .{ .kind = .transparent } }) |foreground| {
            value.figure.?.caption_foreground = foreground;
            value.figure.?.caption_background = .{ .kind = .native_theme };
            value.figure.?.frame_background = .{ .kind = .rgb, .value = "#334455" };
            const plain = try Render.run(a, value, following, false); defer a.free(plain);
            const ansi = try Render.run(a, value, following, true); defer a.free(ansi);
            const ansi_plain = try NarrowTableTest.plain(a, ansi); defer a.free(ansi_plain);
            try std.testing.expectEqualStrings(plain, ansi_plain);
            const fallback = TypedColorOutputTest.at(ansi, std.mem.indexOf(u8, ansi, "Fallback").?);
            try std.testing.expect(fallback.foreground == null and fallback.background == null);
            const child = TypedColorOutputTest.at(ansi, std.mem.indexOf(u8, ansi, "Child foreground").?);
            try std.testing.expectEqual(@as(?[3]u8, .{ 204, 0, 0 }), child.foreground);
        }
    } else return error.SkipZigTest;
}

// Revised J content ownership controls. These are source-authored, not executed.
test "figure flow keeps anonymous inline figure suffix and parent marker once" {
    if (comptime @hasField(model.Block, "flow")) {
        const a = std.testing.allocator;
        const figure = FigureOutputTest.block(.paragraph).figure.?;
        const parts = [_]@import("blob_encoder").presentation_types.FlowPart{
            .{ .kind = .@"inline", .spans = &.{.{ .text = "Before  " }} },
            .{ .kind = .@"inline", .spans = &.{.{ .text = " prefix " }} },
            .{ .kind = .figure, .figure = figure },
            .{ .kind = .@"inline", .spans = &.{.{ .text = " suffix" }} },
        };
        var owner: model.Block = .{ .kind = .paragraph, .flow = &parts };
        const before = try std.json.Stringify.valueAlloc(a, owner, .{}); defer a.free(before);
        for ([_]bool{false, true}) |color| {
            var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
            try blocksText(&out.writer, &.{owner}, color);
            const plain = try NarrowTableTest.plain(a, out.written()); defer a.free(plain);
            try std.testing.expectEqualStrings("Before prefix [image: Map] Caption suffix\n\n", plain);
            owner.kind = .list_item; owner.number = "4"; owner.list_path = "#";
            out.clearRetainingCapacity(); try blocksText(&out.writer, &.{owner}, color);
            const listed = try NarrowTableTest.plain(a, out.written()); defer a.free(listed);
            try std.testing.expectEqualStrings("4. Before   prefix [image: Map] Caption suffix\n", listed);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, listed, "4. "));
            owner.kind = .paragraph; owner.number = ""; owner.list_path = "";
        }
        var spaced_figure = figure;
        spaced_figure.caption = &.{.{ .text = "Caption   spacing", .trail = "   trail" }};
        const spaced_owner: model.Block = .{ .kind = .paragraph, .flow = &.{
            .{ .kind = .@"inline", .spans = &.{.{ .text = "Before " }} },
            .{ .kind = .figure, .figure = spaced_figure },
            .{ .kind = .@"inline", .spans = &.{.{ .text = " suffix" }} },
        } };
        for ([_]bool{false, true}) |color| {
            var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
            try blocksText(&out.writer, &.{spaced_owner}, color);
            const plain = try NarrowTableTest.plain(a, out.written()); defer a.free(plain);
            try std.testing.expectEqualStrings("Before [image: Map] Caption spacing trail suffix\n\n", plain);
        }
        const after = try std.json.Stringify.valueAlloc(a, owner, .{}); defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
    } else return error.SkipZigTest;
}

test "figure rich captions tables references and flow visit real spans once in order" {
    if (comptime @hasField(model.Block, "flow")) {
        const a = std.testing.allocator;
        const fixture: model.Entry = comptime make: {
            var nested = FigureOutputTest.block(.paragraph).figure.?;
            nested.image_span.image.?.alt = "Inner";
            nested.image_span.target = "Inner file";
            nested.image_span.tooltip = null;
            nested.caption = &.{.{ .kind = .link, .text = "Inner caption", .target = "Inner caption target", .tooltip = "Inner advice" }};
            var outer = FigureOutputTest.block(.paragraph).figure.?;
            outer.caption = &.{};
            outer.caption_foreground = .{ .kind = .rgb, .value = "#123456" };
            outer.caption_background = .{ .kind = .rgb, .value = "#ffeecc" };
            outer.caption_blocks = &.{
                .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "Rich first", .target = "Rich target", .explanation = "Rich expansion" }} },
                .{ .kind = .table, .table = .{ .caption_blocks = &.{.{ .kind = .paragraph, .flow = &.{
                    .{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = "Table caption", .target = "Table caption target", .tooltip = "Table advice" }} },
                    .{ .kind = .@"inline", .spans = &.{.{ .text = " child paint", .foreground = "#cc0000", .background = "#000000" }} },
                } }}, .rows = &.{.{ .cells = &.{.{ .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .figure, .figure = nested }} }} }} }} } },
                .{ .kind = .paragraph, .spans = &.{.{ .text = "Rich last" }} },
            };
            break :make .{ .title = "Rich fixture", .kind = .language, .sections = &.{.{ .level = 3, .title = "Body", .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .figure, .figure = outer }, .{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = " suffix", .target = "Suffix target" }} }} }} }}, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "Reference", .target = "Reference target" }} }} }}, .media = &.{.{ .file = "Map.svg", .kind = .image, .caption = "Map" }} };
        };
        const before = try std.json.Stringify.valueAlloc(a, fixture, .{}); defer a.free(before);
        const Links = struct {
            count: usize = 0,
            fn spans(self: *@This(), values: []const model.Span) !bool {
                const expected = [_][]const u8{ "File:Map.svg", "Rich target", "Table caption target", "Inner file", "Inner caption target", "Suffix target", "Reference target" };
                for (values) |span| if (span.kind == .link or span.kind == .external_link) {
                    try std.testing.expect(self.count < expected.len);
                    try std.testing.expectEqualStrings(expected[self.count], span.target);
                    self.count += 1;
                };
                return false;
            }
        };
        var links: Links = .{}; _ = try visitEntrySpanLists(fixture, &links);
        try std.testing.expectEqual(@as(usize, 7), links.count);
        var advice = try Advisories.init(a, fixture); defer advice.deinit();
        try std.testing.expectEqual(@as(usize, 3), advice.items.items.len);
        var abbreviations = try Abbreviations.init(a, fixture); defer abbreviations.deinit();
        try std.testing.expectEqual(@as(usize, 1), abbreviations.items.items.len);
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        var media = try VisibleMediaCaptions.init(arena.allocator(), fixture.media, true);
        try media.observeBlocks(fixture.sections[0].blocks);
        try std.testing.expect(media.inline_seen[0]);
        var plain: std.Io.Writer.Allocating = .init(a); defer plain.deinit();
        var ansi: std.Io.Writer.Allocating = .init(a); defer ansi.deinit();
        try blocksText(&plain.writer, fixture.sections[0].blocks, false);
        try blocksText(&ansi.writer, fixture.sections[0].blocks, true);
        const stripped = try NarrowTableTest.plain(a, ansi.written()); defer a.free(stripped);
        try std.testing.expectEqualStrings(plain.written(), stripped);
        for ([_][]const u8{ "[image: Map]", "Rich first", "Table caption", "[image: Inner]", "Inner caption", "Rich last suffix" }) |needle|
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain.written(), needle));
        try std.testing.expect(std.mem.indexOf(u8, plain.written(), "Rich first").? < std.mem.indexOf(u8, plain.written(), "Table caption").?);
        try std.testing.expect(std.mem.indexOf(u8, plain.written(), "Table caption").? < std.mem.indexOf(u8, plain.written(), "[image: Inner]").?);
        const first_color = TypedColorOutputTest.at(ansi.written(), std.mem.indexOf(u8, ansi.written(), "Rich first").?);
        try std.testing.expectEqual(@as(?[3]u8, .{18,52,86}), first_color.foreground);
        try std.testing.expectEqual(@as(?[3]u8, .{255,238,204}), first_color.background);
        const table_color = TypedColorOutputTest.at(ansi.written(), std.mem.indexOf(u8, ansi.written(), "Table caption").?);
        try std.testing.expectEqual(@as(?[3]u8, .{18,52,86}), table_color.foreground);
        try std.testing.expectEqual(@as(?[3]u8, .{255,238,204}), table_color.background);
        const child_color = TypedColorOutputTest.at(ansi.written(), std.mem.indexOf(u8, ansi.written(), "child paint").?);
        try std.testing.expectEqual(@as(?[3]u8, .{204,0,0}), child_color.foreground);
        try std.testing.expectEqual(@as(?[3]u8, .{0,0,0}), child_color.background);
        const after = try std.json.Stringify.valueAlloc(a, fixture, .{}); defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
    } else return error.SkipZigTest;
}

test "figure authoritative empty rich captions have no flat duplicate or added gap" {
    if (comptime @hasField(model.Block, "flow")) {
        const a = std.testing.allocator;
        var value = FigureOutputTest.block(.paragraph);
        value.figure.?.caption = &.{}; value.figure.?.caption_blocks = &.{};
        const owner: model.Block = .{ .kind = .paragraph, .flow = &.{
            .{ .kind = .@"inline", .spans = &.{.{ .text = "A" }} },
            .{ .kind = .figure, .figure = value.figure },
            .{ .kind = .@"inline", .spans = &.{.{ .text = "B" }} },
        } };
        var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
        try blocksText(&out.writer, &.{owner}, false);
        try std.testing.expectEqualStrings("A[image: Map]B\n\n", out.written());
        const empty_table: model.Table = .{ .caption_blocks = &.{}, .rows = &.{} };
        out.clearRetainingCapacity(); try tableTextWidth(&out.writer, empty_table, false, null, null);
        try std.testing.expectEqualStrings("\n", out.written());
        value.figure.?.caption = &.{.{ .text = "invalid duplicate" }};
        try std.testing.expectError(error.InvalidPresentation, blocksText(&out.writer, &.{value}, false));
    } else return error.SkipZigTest;
}

// Compiled scope tests exercise the terminal's logical image/caption projection,
// not native float geometry or an unobserved terminal bidi implementation.
test "compiled bidi scopes enclose complete logical figures without marker or language labels" {
    if (comptime @hasField(model.Block, "flow")) {
        const T = @import("blob_encoder").presentation_types;
        if (comptime !@hasField(T.FlowPart, "scope")) return error.SkipZigTest;
        const a = std.testing.allocator;
        for ([_]?[]const u8{ null, "", "he" }) |language| for ([_]T.BidiResolvedDirection{ .ltr, .rtl }) |direction| for ([_]T.BidiMode{ .isolate, .isolate_override }) |mode| {
            const scope: T.BidiScope = .{ .mode = mode, .authored_direction = if (mode == .isolate) .auto else if (direction == .ltr) .ltr else .rtl,
                .resolved_direction = direction, .language = language, .parts = &.{
                    .{ .kind = .@"inline", .spans = &.{.{ .text = "A" }} },
                    .{ .kind = .figure, .figure = FigureOutputTest.block(.paragraph).figure },
                    .{ .kind = .@"inline", .spans = &.{.{ .text = "Z" }} },
                } };
            const owner: model.Block = .{ .kind = .list_item, .number = "9", .list_path = "#", .flow = &.{.{ .kind = .scope, .scope = scope }} };
            const before = try std.json.Stringify.valueAlloc(a, owner, .{}); defer a.free(before);
            for ([_]bool{false, true}) |color| {
                var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
                try blocksText(&out.writer, &.{owner}, color);
                const plain = try NarrowTableTest.plain(a, out.written()); defer a.free(plain);
                const prefix = if (direction == .ltr) "\u{2066}" else "\u{2067}";
                const override = if (mode == .isolate) "" else if (direction == .ltr) "\u{202d}" else "\u{202e}";
                const close_override = if (mode == .isolate) "" else "\u{202c}";
                const expected = try std.fmt.allocPrint(a,"9. {s}{s}A[image: Map] CaptionZ{s}{s}\n",.{prefix,override,close_override,"\u{2069}"}); defer a.free(expected);
                try std.testing.expectEqualStrings(expected, plain);
                try std.testing.expectEqual(@as(usize,1), std.mem.count(u8,plain,"9. "));
            }
            const after = try std.json.Stringify.valueAlloc(a, owner, .{}); defer a.free(after);
            try std.testing.expectEqualStrings(before,after);
            const parsed = try std.json.parseFromSlice(model.Block,a,before,.{}); defer parsed.deinit();
            try std.testing.expectEqualDeep(language,parsed.value.flow.?[0].scope.?.language);
        };
    } else return error.SkipZigTest;
}

test "scope nesting preserves whitespace scripts authored controls and recursive figure details once" {
    if (comptime @hasField(model.Block, "flow")) {
        const T = @import("blob_encoder").presentation_types;
        if (comptime !@hasField(T.FlowPart, "scope")) return error.SkipZigTest;
        const a = std.testing.allocator;
        const entry: model.Entry = comptime fixture: {
            var figure = FigureOutputTest.block(.paragraph).figure.?;
            figure.caption = &.{};
            figure.caption_blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{
                .mode = .isolate, .resolved_direction = .rtl, .language = "", .parts = &.{.{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = "Caption", .target = "Caption target", .explanation = "Caption expansion", .tooltip = "Caption advice" }} }},
            } }} }};
            break :fixture .{ .title = "Scoped", .kind = .language, .sections = &.{.{ .level = 3, .title = "Body", .blocks = &.{.{ .kind = .paragraph, .flow = &.{
                .{ .kind = .@"inline", .spans = &.{.{ .text = "Before " }} },
                .{ .kind = .scope, .scope = .{ .mode = .isolate, .authored_direction = .auto, .resolved_direction = .ltr, .parts = &.{
                    .{ .kind = .@"inline", .spans = &.{.{ .text = "  A", .superscript = true }} },
                    .{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .rtl, .language = "he", .parts = &.{.{ .kind = .@"inline", .spans = &.{.{ .text = "B", .superscript = true }} }} } },
                    .{ .kind = .figure, .figure = figure },
                    .{ .kind = .@"inline", .spans = &.{.{ .text = " authored\u{202e}" }} },
                } } },
                .{ .kind = .@"inline", .spans = &.{.{ .text = " after" }} },
            } }} }}, .references = &.{.{ .number = 1, .group_number = 1, .blocks = &.{.{ .kind = .table, .table = .{ .caption_blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .@"inline", .spans = &.{.{ .kind = .link, .text = "Reference", .target = "Reference target" }} }} } }} }}, .rows = &.{} } }} }}, .media = &.{.{ .file = "Map.svg", .kind = .image, .caption = "Map" }} };
        };
        const before = try std.json.Stringify.valueAlloc(a,entry,.{}); defer a.free(before);
        const Links = struct {
            count: usize = 0,
            fn spans(self: *@This(), values: []const model.Span) !bool {
                const expected = [_][]const u8{"File:Map.svg","Caption target","Reference target"};
                for (values) |span| if (span.kind == .link) { try std.testing.expect(self.count < expected.len); try std.testing.expectEqualStrings(expected[self.count],span.target); self.count += 1; };
                return false;
            }
        };
        var links: Links = .{}; _ = try visitEntrySpanLists(entry,&links); try std.testing.expectEqual(@as(usize,3),links.count);
        var advice = try Advisories.init(a,entry); defer advice.deinit(); try std.testing.expectEqual(@as(usize,2),advice.items.items.len);
        var abbreviations = try Abbreviations.init(a,entry); defer abbreviations.deinit(); try std.testing.expectEqual(@as(usize,1),abbreviations.items.items.len);
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        var media = try VisibleMediaCaptions.init(arena.allocator(),entry.media,true); try media.observeBlocks(entry.sections[0].blocks); try std.testing.expect(media.inline_seen[0]);
        var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
        try blocksText(&out.writer,entry.sections[0].blocks,false);
        try std.testing.expectEqualStrings("Before \u{2066}^A\u{2067}B\u{2069}[image: Map] \u{2067}Caption\u{2069} authored\\u{202e}\u{2069} after\n\n",out.written());
        const after = try std.json.Stringify.valueAlloc(a,entry,.{}); defer a.free(after); try std.testing.expectEqualStrings(before,after);
    } else return error.SkipZigTest;
}

test "scope content depth carries through figures and rejects invalid inactive payloads" {
    if (comptime @hasField(model.Block, "flow")) {
        const T = @import("blob_encoder").presentation_types;
        if (comptime !@hasField(T.FlowPart, "scope")) return error.SkipZigTest;
        const a = std.testing.allocator;
        var nodes: [16]T.FlowPart = undefined;
        var i: usize = nodes.len;
        while (i != 0) { i -= 1; nodes[i] = .{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = if (i+1 == nodes.len) &.{} else nodes[i+1..][0..1] } }; }
        const Visitor = struct { fn spans(_: *@This(), _: []const model.Span) !bool { return false; } };
        var visitor: Visitor = .{};
        var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
        const accepted: model.Block = .{ .kind = .paragraph, .flow = nodes[1..2] };
        try blocksText(&out.writer,&.{accepted},false); _ = try visitBlockSpanLists(&.{accepted},&visitor,0);
        const too_deep: model.Block = .{ .kind = .paragraph, .flow = nodes[0..1] };
        try std.testing.expectError(error.InvalidPresentation,blocksText(&out.writer,&.{too_deep},false));
        try std.testing.expectError(error.InvalidPresentation,visitBlockSpanLists(&.{too_deep},&visitor,0));
        var figure = FigureOutputTest.block(.paragraph).figure.?; figure.caption = &.{}; figure.caption_blocks = &.{accepted};
        const through_caption: model.Block = .{ .kind = .paragraph, .figure = figure };
        try std.testing.expectError(error.InvalidPresentation,blocksText(&out.writer,&.{through_caption},false));
        try std.testing.expectError(error.InvalidPresentation,visitBlockSpanLists(&.{through_caption},&visitor,0));
        const bad: model.Block = .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .spans = &.{.{ .text = "duplicate" }}, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{} } }} };
        try std.testing.expectError(error.InvalidPresentation,blocksText(&out.writer,&.{bad},false));
        try std.testing.expectError(error.InvalidPresentation,visitBlockSpanLists(&.{bad},&visitor,0));
    } else return error.SkipZigTest;
}

test "scope paragraph boundaries reopen compiled direction around rich captions and retain poem offsets" {
    if (comptime @hasField(model.Block, "flow")) {
        const T = @import("blob_encoder").presentation_types;
        if (comptime !@hasField(T.FlowPart, "scope")) return error.SkipZigTest;
        const a = std.testing.allocator;
        var figure = FigureOutputTest.block(.paragraph).figure.?;
        figure.caption = &.{}; figure.caption_blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .text = "One" }} },
            .{ .kind = .paragraph, .spans = &.{.{ .text = "Two" }} },
        };
        const owner: model.Block = .{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{
            .mode = .isolate_override, .authored_direction = .rtl, .resolved_direction = .rtl, .parts = &.{
                .{ .kind = .figure, .figure = figure }, .{ .kind = .@"inline", .spans = &.{.{ .text = " suffix" }} },
            },
        } }} };
        var out: std.Io.Writer.Allocating = .init(a); defer out.deinit();
        try blocksText(&out.writer,&.{owner},false);
        try std.testing.expectEqualStrings("\u{2067}\u{202e}[image: Map] One\u{202c}\u{2069}\n\u{2067}\u{202e}\u{202c}\u{2069}\n\u{2067}\u{202e}Two suffix\u{202c}\u{2069}\n\n",out.written());
        out.clearRetainingCapacity();
        var metadata: std.ArrayList(terminal.PoemLine) = .empty; defer metadata.deinit(a);
        var projection: PoemProjection = .{ .allocator = a, .frame = &out, .lines = &metadata };
        const poem: model.Block = .{ .kind = .paragraph, .flow = &.{
            .{ .kind = .@"inline", .spans = &.{.{ .text = "prefix " }} },
            .{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{
                .{ .kind = .@"inline", .spans = &.{
                    .{ .text = "first", .classes = "wikidict-poem wikidict-poem-indent-2" },
                    .{ .kind = .line_break, .classes = "wikidict-poem wikidict-poem-indent-2" },
                    .{ .text = "second", .classes = "wikidict-poem wikidict-poem-indent-2" },
                } },
            } } },
        } };
        try blocksTextInContext(&out.writer,&.{poem},false,&projection,.{});
        try std.testing.expectEqualStrings("prefix \u{2066}first\u{2069}\n\u{2066}second\u{2069}\n\n",out.written());
        try std.testing.expectEqual(@as(usize,2),metadata.items.len);
        try std.testing.expectEqual(@as(usize,0),metadata.items[0].offset);
        try std.testing.expectEqual(@as(usize,7+3),metadata.items[0].lead_bytes);
        try std.testing.expectEqual(@as(usize,7),metadata.items[0].lead_cells);
        try std.testing.expectEqual(std.mem.indexOfScalar(u8,out.written(),'\n').?+1,metadata.items[1].offset);
        try std.testing.expectEqual(@as(usize,3),metadata.items[1].lead_bytes);
        try std.testing.expectEqual(@as(usize,0),metadata.items[1].lead_cells);
        try std.testing.expectEqual(@as(usize,2),metadata.items[0].left);
        try std.testing.expectEqual(@as(usize,2),metadata.items[1].left);
    } else return error.SkipZigTest;
}

test "scope preserves all compiled list roles and discovers rich caption grids for narrow projection" {
    if (comptime @hasField(model.Block, "flow")) {
        const T = @import("blob_encoder").presentation_types;
        if (comptime !@hasField(T.FlowPart, "scope")) return error.SkipZigTest;
        const a = std.testing.allocator;
        for ([_]T.BlockKind{ .list_item, .definition, .example, .quotation, .term, .list_detail, .indent }) |kind| {
            var ordinary: model.Block = .{ .kind = kind, .depth = 1, .list_path = "#:", .number = "3", .spans = &.{.{ .text = "X" }} };
            var old: std.Io.Writer.Allocating = .init(a); defer old.deinit();
            try blocksText(&old.writer,&.{ordinary},false);
            ordinary.spans = &.{}; ordinary.flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .@"inline", .spans = &.{.{ .text = "X" }} }} } }};
            var scoped: std.Io.Writer.Allocating = .init(a); defer scoped.deinit();
            try blocksText(&scoped.writer,&.{ordinary},false);
            const at = std.mem.indexOf(u8,old.written(),"X").?;
            const expected = try std.fmt.allocPrint(a,"{s}{s}X{s}{s}",.{old.written()[0..at],"\u{2066}","\u{2069}",old.written()[at+1..]}); defer a.free(expected);
            try std.testing.expectEqualStrings(expected,scoped.written());
        }
        var figure = FigureOutputTest.block(.paragraph).figure.?;
        figure.caption = &.{}; figure.caption_blocks = &.{.{ .kind = .table, .table = .{ .geometry = .{ .width = .{ .unit = .percent, .value = 100 } }, .rows = &.{.{ .cells = &.{
            .{ .spans = &.{.{ .text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron" }} },
            .{ .spans = &.{.{ .text = "tail" }} },
        } }} } }};
        const cell: T.Cell = .{ .blocks = &.{.{ .kind = .paragraph, .flow = &.{.{ .kind = .scope, .scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{.{ .kind = .figure, .figure = figure }} } }} }} };
        try std.testing.expect(cellHasTable(cell));
        const table: model.Table = .{ .rows = &.{.{ .cells = &.{cell} }} };
        const before = try std.json.Stringify.valueAlloc(a,table,.{}); defer a.free(before);
        var wide: std.Io.Writer.Allocating = .init(a); defer wide.deinit();
        var narrow: std.Io.Writer.Allocating = .init(a); defer narrow.deinit();
        try tableTextWidth(&wide.writer,table,false,null,null); try tableTextWidth(&narrow.writer,table,false,null,40);
        const Max = struct { fn width(text: []const u8) usize { var lines=std.mem.splitScalar(u8,text,'\n');var result:usize=0;while(lines.next()) |line| result=@max(result,terminal.cellWidth(line));return result; } };
        try std.testing.expect(Max.width(narrow.written()) < Max.width(wide.written()));
        for ([_][]const u8{"[image: Map]","alpha","omicron","tail"}) |needle| try std.testing.expectEqual(@as(usize,1),std.mem.count(u8,narrow.written(),needle));
        const after = try std.json.Stringify.valueAlloc(a,table,.{}); defer a.free(after); try std.testing.expectEqualStrings(before,after);
    } else return error.SkipZigTest;
}

test "definition direct and anonymous figure captions share ordinary whitespace and ANSI policy" {
    if (comptime @hasField(model.Block, "flow")) {
        const a = std.testing.allocator;
        var direct = FigureOutputTest.block(.definition);
        direct.number = "2";
        direct.figure.?.caption = &.{.{ .kind = .link, .text = "Spacing   words", .trail = "   trail", .target = "Caption target" }};
        direct.figure.?.caption_foreground = .{ .kind = .rgb, .value = "#123456" };
        direct.figure.?.caption_background = .{ .kind = .rgb, .value = "#ffeecc" };
        var anonymous = direct; anonymous.figure = null;
        anonymous.flow = &.{.{ .kind = .figure, .figure = direct.figure }};
        const before = try std.json.Stringify.valueAlloc(a,&.{direct,anonymous},.{}); defer a.free(before);
        for ([_]bool{false,true}) |color| {
            var direct_out: std.Io.Writer.Allocating = .init(a); defer direct_out.deinit();
            var flow_out: std.Io.Writer.Allocating = .init(a); defer flow_out.deinit();
            try blocksText(&direct_out.writer,&.{direct},color); try blocksText(&flow_out.writer,&.{anonymous},color);
            try std.testing.expectEqualStrings(direct_out.written(),flow_out.written());
            const plain = try NarrowTableTest.plain(a,direct_out.written()); defer a.free(plain);
            try std.testing.expectEqualStrings("2. [image: Map] Spacing words trail\n",plain);
            if (color) {
                const paint = TypedColorOutputTest.at(direct_out.written(),std.mem.indexOf(u8,direct_out.written(),"Spacing").?);
                try std.testing.expectEqual(@as(?[3]u8,.{18,52,86}),paint.foreground);
                try std.testing.expectEqual(@as(?[3]u8,.{255,238,204}),paint.background);
            }
        }
        const after = try std.json.Stringify.valueAlloc(a,&.{direct,anonymous},.{}); defer a.free(after);
        try std.testing.expectEqualStrings(before,after);
    } else return error.SkipZigTest;
}

test "typed table width suppresses losing legacy terminal request without dropping stored box fields" {
    const T = @import("blob_encoder").presentation_types;
    if (comptime @hasField(T.TableStyle, "width")) {
        const a = std.testing.allocator;
        for ([_]T.StyleWidth{ .{ .unit = .em, .value = 16 }, .{ .unit = .px, .value = 0 }, .{ .unit = .percent, .value = 150 } }) |width| {
            const table: model.Table = .{ .style = .{ .width = width, .padding = T.StyleEdges.all(.{ .unit = .em, .value = 0.16 }), .clear = .none },
                .geometry = .{ .width = .{ .unit = .px, .value = 80 }, .cell_padding = 1, .cell_spacing = 0, .border = 0 },
                .rows = &.{.{ .cells = &.{.{ .spans = &.{.{ .text = "body" }} }} }} };
            const before = try std.json.Stringify.valueAlloc(a,table,.{}); defer a.free(before);
            var without_attr = table; without_attr.geometry.?.width = null;
            var legacy_only = table; legacy_only.style = null;
            var conflict_out: std.Io.Writer.Allocating = .init(a); defer conflict_out.deinit();
            var no_attr_out: std.Io.Writer.Allocating = .init(a); defer no_attr_out.deinit();
            var legacy_out: std.Io.Writer.Allocating = .init(a); defer legacy_out.deinit();
            try tableTextWidth(&conflict_out.writer,table,false,null,80);
            try tableTextWidth(&no_attr_out.writer,without_attr,false,null,80);
            try tableTextWidth(&legacy_out.writer,legacy_only,false,null,80);
            try std.testing.expectEqualStrings(no_attr_out.written(),conflict_out.written());
            try std.testing.expect(!std.mem.eql(u8,legacy_out.written(),conflict_out.written()));
            try std.testing.expectEqual(@as(usize,1),std.mem.count(u8,conflict_out.written(),"body"));
            const entry: model.Entry = .{ .title = "Table", .kind = .citations, .sections = &.{.{ .level = 3, .title = "Body", .blocks = &.{.{ .kind = .table, .table = table }} }} };
            var response: std.Io.Writer.Allocating = .init(a); defer response.deinit();
            try json(&response.writer,.{ .operation = .lookup, .query = "Table", .kind = .citations, .language = null, .record_count = 1, .total_matches = 1, .entries = &.{entry} });
            const parsed = try std.json.parseFromSlice(std.json.Value,a,response.written(),.{}); defer parsed.deinit();
            const exported = parsed.value.object.get("entries").?.array.items[0].object.get("sections").?.array.items[0].object.get("blocks").?.array.items[0].object.get("table").?.object;
            const style = exported.get("style").?.object;
            const exported_width = style.get("width").?.object;
            try std.testing.expectEqualStrings(@tagName(width.unit),exported_width.get("unit").?.string);
            const number = switch (exported_width.get("value").?) { .integer => |value| @as(f64,@floatFromInt(value)), .float => |value| value, else => return error.UnexpectedJsonNumber };
            try std.testing.expectEqual(@as(f64,width.value),number);
            try std.testing.expect(style.get("padding") != null);
            try std.testing.expectEqualStrings("none",style.get("clear").?.string);
            try std.testing.expectEqual(@as(i64,80),exported.get("geometry").?.object.get("width").?.object.get("value").?.integer);
            const after = try std.json.Stringify.valueAlloc(a,table,.{}); defer a.free(after);
            try std.testing.expectEqualStrings(before,after);
        }
    } else return error.SkipZigTest;
}

test "compact supplemental text retains the actual PL144 manager body" {
    var parsed = try std.json.parseFromSlice(Response, std.testing.allocator,
        @embedFile("testdata/pl144-manager-results.json"), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const entry = parsed.value.entries[0];
    try std.testing.expectEqualStrings("Portal:Jidysz/manager", entry.title);
    try std.testing.expect(entry.kind == .supplemental and entry.language == null);
    try std.testing.expectEqual(@as(usize, 0), entry.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 2), entry.sections.len);
    var tables: usize = 0;
    var cells: usize = 0;
    for (entry.sections) |section| for (section.blocks) |block| {
        if (block.table) |table| {
            tables += 1;
            for (table.rows) |row| cells += row.cells.len;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), tables);
    try std.testing.expectEqual(@as(usize, 86), cells);
    var actions: struct {
        count: usize = 0,
        fn spans(self: *@This(), items: []const model.Span) !bool {
            for (items) |span| {
                if (span.kind == .link or span.kind == .external_link) self.count += 1;
            }
            return false;
        }
    } = .{};
    _ = try visitEntrySpanLists(entry, &actions);
    try std.testing.expectEqual(@as(usize, 89), actions.count);
    var compact: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compact.deinit();
    var complete: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer complete.deinit();
    for ([_]bool{ false, true }) |color| {
        compact.clearRetainingCapacity();
        complete.clearRetainingCapacity();
        try entryTextWithDetails(&compact.writer, entry, color, false);
        try entryTextWithDetails(&complete.writer, entry, color, true);
        // This retained document has no catalogue/reference metadata. Its whole
        // detailed body is consequently also the ordinary supplemental body.
        try std.testing.expectEqualStrings(complete.written(), compact.written());
        try std.testing.expect(compact.written().len > @embedFile("testdata/pl144-manager-header-only.txt").len);
        var position: usize = 0;
        for ([_][]const u8{ "struktura", "strona główna", "tłumaczenia interfejsu", "domyślny", "uselang", "Portal:Jidysz/pl/mainpage" }) |text| {
            const found = std.mem.indexOfPos(u8, compact.written(), position, text);
            try std.testing.expect(found != null);
            position = found.? + text.len;
        }
    }
}

test "compact supplemental body preserves preamble and support beside definitions" {
    const sections = [_]model.Section{.{ .level = 2, .title = "Authored heading", .blocks = &.{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "PRIMARY_BODY" }} },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &.{.{ .text = "DEFINITION_BODY" }} },
    } }};
    var entry: model.Entry = .{ .title = "Document", .kind = .supplemental,
        .preamble_spans = &.{.{ .text = "PRIMARY_PREFACE" }}, .sections = &sections };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for ([_]bool{ false, true }) |color| {
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, color, false);
        for ([_][]const u8{ "PRIMARY_PREFACE", "Authored heading", "PRIMARY_BODY", "DEFINITION_BODY" }) |text|
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), text));
        entry.kind = .language;
        out.clearRetainingCapacity();
        try entryTextWithDetails(&out.writer, entry, color, false);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "PRIMARY_PREFACE") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "PRIMARY_BODY") == null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "DEFINITION_BODY"));
        entry.kind = .supplemental;
    }
}
