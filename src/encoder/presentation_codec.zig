const std = @import("std");
const format = @import("blob_format.zig");
const types = @import("presentation_types.zig");
const A = std.mem.Allocator;

pub const magic = "DPR2";
const max_items: usize = 1 << 20;
const max_string_bytes: usize = 32 * 1024 * 1024;
const no_index: u32 = std.math.maxInt(u32);

const Encoder = struct {
    a: A,
    out: std.ArrayList(u8) = .empty,

    fn deinit(self: *Encoder) void {
        self.out.deinit(self.a);
    }
    fn byte(self: *Encoder, value: u8) !void {
        try self.out.append(self.a, value);
    }
    fn writeU16(self: *Encoder, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.out.appendSlice(self.a, &buf);
    }
    fn writeU32(self: *Encoder, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.out.appendSlice(self.a, &buf);
    }
    fn count(self: *Encoder, value: usize) !void {
        if (value > max_items) return error.PresentationTooLarge;
        try self.writeU32(@intCast(value));
    }
    fn index(self: *Encoder, value: usize) !void {
        const n = std.math.cast(u32, value) orelse return error.PresentationTooLarge;
        if (n == no_index) return error.PresentationTooLarge;
        try self.writeU32(n);
    }
    fn optionalIndex(self: *Encoder, value: ?usize) !void {
        if (value) |n| return self.index(n);
        try self.writeU32(no_index);
    }
    fn string(self: *Encoder, value: []const u8) !void {
        if (value.len > max_string_bytes) return error.PresentationTooLarge;
        try self.writeU32(std.math.cast(u32, value.len) orelse return error.PresentationTooLarge);
        try self.out.appendSlice(self.a, value);
    }
    fn indices(self: *Encoder, values: []const usize) !void {
        try self.count(values.len);
        for (values) |value| try self.index(value);
    }
    inline fn enumByteValue(comptime E: type, value: anytype) !u8 {
        const Source = @TypeOf(value);
        const fields = @typeInfo(Source).@"enum";
        const invalid = std.math.maxInt(u8);
        const map = comptime blk: {
            const target_fields = @typeInfo(E).@"enum";
            var result: [fields.field_names.len]u8 = undefined;
            for (fields.field_names, fields.field_values, 0..) |name, source_value, i| {
                if (source_value != i) @compileError("enumByte source must use dense zero-based values");
                result[i] = invalid;
                for (target_fields.field_names, target_fields.field_values) |target_name, target_value| {
                    if (std.mem.eql(u8, name, target_name)) {
                        result[i] = @intCast(target_value);
                        break;
                    }
                }
            }
            break :blk result;
        };
        const mapped = map[@backingInt(value)];
        if (mapped == invalid) return error.UncompiledTemplate;
        return mapped;
    }
    fn enumByte(self: *Encoder, comptime E: type, value: anytype) !void {
        try self.byte(try enumByteValue(E, value));
    }
    fn span(self: *Encoder, value: anytype) !void {
        const kind = try enumByteValue(types.InlineKind, value.kind);
        const role = try enumByteValue(types.Role, value.role);
        const flags: u8 = if (comptime @hasField(@TypeOf(value), "flags"))
            @bitCast(value.flags)
        else blk: {
            var result: u8 = 0;
            if (value.bold) result |= 1 << 0;
            if (value.italic) result |= 1 << 1;
            if (value.code) result |= 1 << 2;
            if (value.small) result |= 1 << 3;
            if (value.superscript) result |= 1 << 4;
            if (value.subscript) result |= 1 << 5;
            if (value.strike) result |= 1 << 6;
            if (value.underline) result |= 1 << 7;
            break :blk result;
        };
        const trail: []const u8 = if (comptime @hasField(@TypeOf(value), "trail")) value.trail else "";
        const strings = [_][]const u8{ value.text, value.target, trail, value.language, value.classes, value.direction };
        var encoded_len: usize = 3 + strings.len * @sizeOf(u32);
        for (strings) |string_value| {
            if (string_value.len > max_string_bytes) return error.PresentationTooLarge;
            encoded_len += string_value.len;
        }
        try self.out.ensureUnusedCapacity(self.a, encoded_len);
        const encoded = self.out.addManyAsSliceAssumeCapacity(encoded_len);
        encoded[0] = kind;
        encoded[1] = role;
        encoded[2] = flags;
        var pos: usize = 3;
        for (strings) |string_value| {
            std.mem.writeInt(u32, encoded[pos..][0..4], @intCast(string_value.len), .little);
            pos += 4;
            @memcpy(encoded[pos..][0..string_value.len], string_value);
            pos += string_value.len;
        }
        std.debug.assert(pos == encoded.len);
    }
    fn spans(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |value| try self.span(value);
    }
    fn feature(self: *Encoder, value: anytype) !void {
        if (value) |feature_value| {
            try self.byte(1);
            try self.string(feature_value.kind);
            try self.string(feature_value.language);
            try self.string(feature_value.data);
            try self.string(feature_value.tail_kind);
            try self.string(feature_value.tail);
        } else try self.byte(0);
    }
    fn cell(self: *Encoder, value: anytype) !void {
        try self.byte(@intFromBool(value.header));
        try self.writeU16(value.colspan);
        try self.writeU16(value.rowspan);
        try self.spans(value.spans);
    }
    fn row(self: *Encoder, value: anytype) !void {
        try self.count(value.cells.len);
        for (value.cells) |cell_value| try self.cell(cell_value);
    }
    fn table(self: *Encoder, value: anytype) !void {
        if (value) |table_value| {
            try self.byte(1);
            try self.spans(table_value.caption);
            try self.count(table_value.rows.len);
            for (table_value.rows) |row_value| try self.row(row_value);
        } else try self.byte(0);
    }
    fn block(self: *Encoder, value: anytype) !void {
        try self.enumByte(types.BlockKind, value.kind);
        try self.byte(value.depth);
        try self.byte(value.level);
        try self.spans(value.spans);
        try self.feature(value.feature);
        try self.string(value.list_path);
        try self.string(value.number);
        try self.table(value.table);
    }
    fn sections(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |section| {
            try self.byte(section.level);
            try self.string(section.title);
            try self.count(section.blocks.len);
            for (section.blocks) |block_value| try self.block(block_value);
        }
    }
    fn form(self: *Encoder, value: anytype) !void {
        if (value) |form_value| {
            try self.byte(1);
            try self.string(form_value.relation);
            try self.string(form_value.target);
            try self.string(form_value.language);
        } else try self.byte(0);
    }
    fn sense(self: *Encoder, value: anytype) !void {
        try self.index(value.block);
        try self.optionalIndex(value.parent);
        try self.indices(value.examples);
        try self.indices(value.quotations);
        try self.indices(value.notes);
        try self.form(value.form);
    }
    fn layout(self: *Encoder, value: anytype) !void {
        try self.count(value.lexemes.len);
        for (value.lexemes) |lexeme| {
            try self.string(lexeme.language);
            try self.string(lexeme.kind);
            try self.index(lexeme.section);
            try self.optionalIndex(lexeme.etymology);
            try self.count(lexeme.definitions.len);
            for (lexeme.definitions) |sense_value| try self.sense(sense_value);
            try self.indices(lexeme.introduction);
            try self.indices(lexeme.other_blocks);
            try self.indices(lexeme.related_sections);
        }
        try self.indices(value.other_sections);
    }
    fn references(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |reference| {
            try self.index(reference.number);
            try self.index(reference.group_number);
            try self.string(reference.name);
            try self.string(reference.group);
            try self.spans(reference.spans);
        }
    }
    fn media(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |item| {
            try self.string(item.file);
            try self.enumByte(types.MediaKind, item.kind);
            try self.string(item.caption);
        }
    }
};

/// Observed while the existing decoder consumes one successful DPR2 payload.
/// These are measurements, not a reader compatibility verdict or new limits.
pub const TableGridMetrics = struct {
    exact_compact_columns: ?usize = 0,
    columns_lower_bound: usize = 0,
    column_limit_exceeded: bool = false,
    spans_supported: bool = true,
    occupied_rows: usize = 0,
    max_colspan: u16 = 0,
    max_rowspan: u16 = 0,
};

// Observation only. This mirrors the selected Android sparse placement without
// allocating a dense grid or retaining more than 513 global boundaries.
const GridObserver = struct {
    const Interval = struct { start: u64, end: u64, until_row: usize };
    active: [512]Interval = undefined,
    active_len: usize = 0,
    boundaries: [513]u64 = undefined,
    boundary_len: usize = 1,

    fn init() GridObserver {
        var self: GridObserver = .{};
        self.boundaries[0] = 0;
        return self;
    }
    fn expire(self: *GridObserver, row: usize) void {
        var kept: usize = 0;
        for (self.active[0..self.active_len]) |interval| {
            if (interval.until_row > row) {
                self.active[kept] = interval;
                kept += 1;
            }
        }
        self.active_len = kept;
    }
    fn lowerActive(self: *const GridObserver, column: u64) usize {
        var lo: usize = 0;
        var hi = self.active_len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.active[mid].start < column) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
    fn boundary(self: *GridObserver, value: u64) bool {
        var lo: usize = 0;
        var hi = self.boundary_len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.boundaries[mid] < value) lo = mid + 1 else hi = mid;
        }
        if (lo < self.boundary_len and self.boundaries[lo] == value) return true;
        // A new 514th boundary proves at least 513 compact columns. Do not
        // insert it or pretend the saturated count is the final exact width.
        if (self.boundary_len == self.boundaries.len) return false;
        var i = self.boundary_len;
        while (i > lo) : (i -= 1) self.boundaries[i] = self.boundaries[i - 1];
        self.boundaries[lo] = value;
        self.boundary_len += 1;
        return true;
    }
    fn place(self: *GridObserver, column: *u64, cell: types.Cell, row: usize) bool {
        var end: u64 = undefined;
        var index: usize = undefined;
        while (true) {
            end = column.* + cell.colspan;
            index = self.lowerActive(column.*);
            if (index > 0 and self.active[index - 1].end > column.*) {
                column.* = self.active[index - 1].end;
            } else if (index < self.active_len and self.active[index].start < end) {
                column.* = self.active[index].end;
            } else break;
        }
        if (!self.boundary(column.*) or !self.boundary(end)) return false;
        // Nonoverlapping positive intervals need at most boundaries-1 slots.
        std.debug.assert(self.active_len < self.active.len);
        var i = self.active_len;
        while (i > index) : (i -= 1) self.active[i] = self.active[i - 1];
        self.active[index] = .{ .start = column.*, .end = end, .until_row = row + cell.rowspan };
        self.active_len += 1;
        column.* = end;
        return true;
    }
};

pub fn measureTableGrid(table: types.Table) TableGridMetrics {
    var result: TableGridMetrics = .{ .occupied_rows = table.rows.len };
    var observer = GridObserver.init();
    var observe_columns = true;
    for (table.rows, 0..) |row, row_index| {
        if (observe_columns) observer.expire(row_index);
        var column: u64 = 0;
        for (row.cells) |cell| {
            result.occupied_rows = @max(result.occupied_rows, row_index + @as(usize, cell.rowspan));
            result.max_colspan = @max(result.max_colspan, cell.colspan);
            result.max_rowspan = @max(result.max_rowspan, cell.rowspan);
            if (cell.colspan == 0 or cell.colspan > 100 or cell.rowspan == 0 or cell.rowspan > 100) {
                result.spans_supported = false;
                result.exact_compact_columns = null;
                observe_columns = false;
            }
            if (observe_columns and !observer.place(&column, cell, row_index)) {
                result.column_limit_exceeded = true;
                result.exact_compact_columns = null;
                result.columns_lower_bound = 513;
                observe_columns = false;
            }
        }
    }
    if (result.exact_compact_columns != null) {
        result.exact_compact_columns = observer.boundary_len - 1;
        result.columns_lower_bound = observer.boundary_len - 1;
    }
    return result;
}

pub const DecodeMetrics = struct {
    total_items: u64 = 0,
    largest_string_bytes: usize = 0,
    tables: usize = 0,
    table_columns_exact: ?usize = 0,
    table_columns_lower_bound: usize = 0,
    table_column_limit_exceeded: bool = false,
    table_spans_supported: bool = true,
    max_table_rows: usize = 0,
    max_table_colspan: u16 = 0,
    max_table_rowspan: u16 = 0,
    widest_table: ?usize = null,
    tallest_table: ?usize = null,
    span_table: ?usize = null,

    fn table(self: *DecodeMetrics, value: types.Table) void {
        const observed = measureTableGrid(value);
        const ordinal = self.tables;
        self.tables += 1;
        if (self.widest_table == null or observed.columns_lower_bound > self.table_columns_lower_bound or
            (observed.column_limit_exceeded and !self.table_column_limit_exceeded)) self.widest_table = ordinal;
        if (self.tallest_table == null or observed.occupied_rows > self.max_table_rows) self.tallest_table = ordinal;
        if (self.span_table == null or observed.max_colspan > self.max_table_colspan or
            observed.max_rowspan > self.max_table_rowspan or (!observed.spans_supported and self.table_spans_supported)) self.span_table = ordinal;
        self.table_columns_lower_bound = @max(self.table_columns_lower_bound, observed.columns_lower_bound);
        if (self.table_columns_exact) |previous| {
            self.table_columns_exact = if (observed.exact_compact_columns) |columns| @max(previous, columns) else null;
        }
        self.table_column_limit_exceeded = self.table_column_limit_exceeded or observed.column_limit_exceeded;
        self.table_spans_supported = self.table_spans_supported and observed.spans_supported;
        self.max_table_rows = @max(self.max_table_rows, observed.occupied_rows);
        self.max_table_colspan = @max(self.max_table_colspan, observed.max_colspan);
        self.max_table_rowspan = @max(self.max_table_rowspan, observed.max_rowspan);
    }
};

const Reader = struct {
    a: A,
    bytes: []const u8,
    pos: usize = 0,
    metrics: ?*DecodeMetrics = null,

    fn remaining(self: Reader) usize {
        return self.bytes.len -| self.pos;
    }
    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.InvalidPresentation;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn readU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn count(self: *Reader, min_bytes: usize) !usize {
        const value: usize = try self.readU32();
        if (value > max_items) return error.InvalidPresentation;
        if (min_bytes != 0 and value > self.remaining() / min_bytes) return error.InvalidPresentation;
        if (self.metrics) |metrics| {
            metrics.total_items = std.math.add(u64, metrics.total_items, @as(u64, value)) catch return error.InvalidPresentation;
        }
        return value;
    }
    fn index(self: *Reader) !usize {
        const value = try self.readU32();
        if (value == no_index) return error.InvalidPresentation;
        return value;
    }
    fn optionalIndex(self: *Reader) !?usize {
        const value = try self.readU32();
        return if (value == no_index) null else @as(usize, value);
    }
    fn string(self: *Reader) ![]const u8 {
        const len: usize = try self.readU32();
        if (len > max_string_bytes) return error.InvalidPresentation;
        const value = try self.take(len);
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidPresentation;
        if (self.metrics) |metrics| metrics.largest_string_bytes = @max(metrics.largest_string_bytes, len);
        return value;
    }
    fn enumValue(self: *Reader, comptime E: type) !E {
        return std.enums.fromInt(E, try self.byte()) orelse return error.InvalidPresentation;
    }
    fn presence(self: *Reader) !bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidPresentation,
        };
    }
    fn indices(self: *Reader) ![]const usize {
        const len = try self.count(4);
        const out = try self.a.alloc(usize, len);
        for (out) |*value| value.* = try self.index();
        return out;
    }
    fn span(self: *Reader) !types.Span {
        const kind = try self.enumValue(types.InlineKind);
        const role = try self.enumValue(types.Role);
        const flags = try self.byte();
        return .{
            .kind = kind,
            .role = role,
            .bold = flags & (1 << 0) != 0,
            .italic = flags & (1 << 1) != 0,
            .code = flags & (1 << 2) != 0,
            .small = flags & (1 << 3) != 0,
            .superscript = flags & (1 << 4) != 0,
            .subscript = flags & (1 << 5) != 0,
            .strike = flags & (1 << 6) != 0,
            .underline = flags & (1 << 7) != 0,
            .text = try self.string(),
            .target = try self.string(),
            .trail = try self.string(),
            .language = try self.string(),
            .classes = try self.string(),
            .direction = try self.string(),
        };
    }
    fn spans(self: *Reader) ![]const types.Span {
        const len = try self.count(27);
        const out = try self.a.alloc(types.Span, len);
        for (out) |*value| value.* = try self.span();
        return out;
    }
    fn feature(self: *Reader) !?types.Feature {
        if (!try self.presence()) return null;
        return .{
            .kind = try self.string(),
            .language = try self.string(),
            .data = try self.string(),
            .tail_kind = try self.string(),
            .tail = try self.string(),
        };
    }
    fn cell(self: *Reader) !types.Cell {
        return .{
            .header = try self.presence(),
            .colspan = try self.readU16(),
            .rowspan = try self.readU16(),
            .spans = try self.spans(),
        };
    }
    fn row(self: *Reader) !types.Row {
        const len = try self.count(9);
        const out = try self.a.alloc(types.Cell, len);
        for (out) |*cell_value| cell_value.* = try self.cell();
        return .{ .cells = out };
    }
    fn table(self: *Reader) !?types.Table {
        if (!try self.presence()) return null;
        const caption = try self.spans();
        const len = try self.count(4);
        const rows = try self.a.alloc(types.Row, len);
        for (rows) |*row_value| row_value.* = try self.row();
        const value: types.Table = .{ .caption = caption, .rows = rows };
        if (self.metrics) |metrics| metrics.table(value);
        return value;
    }
    fn block(self: *Reader) !types.Block {
        return .{
            .kind = try self.enumValue(types.BlockKind),
            .depth = try self.byte(),
            .level = try self.byte(),
            .spans = try self.spans(),
            .feature = try self.feature(),
            .list_path = try self.string(),
            .number = try self.string(),
            .table = try self.table(),
        };
    }
    fn sections(self: *Reader) ![]const types.Section {
        const len = try self.count(9);
        const out = try self.a.alloc(types.Section, len);
        for (out) |*section| {
            section.level = try self.byte();
            section.title = try self.string();
            const block_len = try self.count(17);
            const blocks = try self.a.alloc(types.Block, block_len);
            for (blocks) |*block_value| block_value.* = try self.block();
            section.blocks = blocks;
        }
        return out;
    }
    fn form(self: *Reader) !?types.Form {
        if (!try self.presence()) return null;
        return .{ .relation = try self.string(), .target = try self.string(), .language = try self.string() };
    }
    fn sense(self: *Reader) !types.Sense {
        return .{
            .block = try self.index(),
            .parent = try self.optionalIndex(),
            .examples = try self.indices(),
            .quotations = try self.indices(),
            .notes = try self.indices(),
            .form = try self.form(),
        };
    }
    fn layout(self: *Reader) !types.Layout {
        const len = try self.count(29);
        const lexemes = try self.a.alloc(types.Lexeme, len);
        for (lexemes) |*lexeme| {
            lexeme.language = try self.string();
            lexeme.kind = try self.string();
            lexeme.section = try self.index();
            lexeme.etymology = try self.optionalIndex();
            const senses_len = try self.count(18);
            const senses = try self.a.alloc(types.Sense, senses_len);
            for (senses) |*sense_value| sense_value.* = try self.sense();
            lexeme.definitions = senses;
            lexeme.introduction = try self.indices();
            lexeme.other_blocks = try self.indices();
            lexeme.related_sections = try self.indices();
        }
        return .{ .lexemes = lexemes, .other_sections = try self.indices() };
    }
    fn references(self: *Reader) ![]const types.Reference {
        const len = try self.count(20);
        const out = try self.a.alloc(types.Reference, len);
        for (out) |*reference| reference.* = .{
            .number = try self.index(),
            .group_number = try self.index(),
            .name = try self.string(),
            .group = try self.string(),
            .spans = try self.spans(),
        };
        return out;
    }
    fn media(self: *Reader) ![]const types.Media {
        const len = try self.count(9);
        const out = try self.a.alloc(types.Media, len);
        for (out) |*item| item.* = .{
            .file = try self.string(),
            .kind = try self.enumValue(types.MediaKind),
            .caption = try self.string(),
        };
        return out;
    }
};

pub fn encodeAlloc(a: A, stored: types.Stored) ![]u8 {
    if (!std.mem.eql(u8, stored.schema, types.schema)) return error.InvalidPresentation;
    var encoder: Encoder = .{ .a = a };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, magic);
    try encoder.spans(stored.entry.display_title);
    try encoder.sections(stored.entry.sections);
    try encoder.spans(stored.entry.preamble_spans);
    try encoder.layout(stored.entry.organization);
    try encoder.references(stored.entry.references);
    try encoder.media(stored.entry.media);
    return encoder.out.toOwnedSlice(a);
}

/// Build-time fast path: serialize compiler/layout structures directly instead of
/// allocating a second presentation tree with the same fields.
pub fn encodeBuildAlloc(
    a: A,
    display_title: anytype,
    sections: anytype,
    layout_value: anytype,
    references_value: anytype,
    media_value: anytype,
) ![]u8 {
    var encoder: Encoder = .{ .a = a };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, magic);
    try encoder.spans(display_title);
    try encoder.sections(sections);
    try encoder.count(0); // no preamble is emitted by the bundle compiler
    try encoder.layout(layout_value);
    try encoder.references(references_value);
    try encoder.media(media_value);
    return encoder.out.toOwnedSlice(a);
}

/// Structural slices are allocated from `a`; all decoded strings borrow `payload`,
/// `expected_title`, or `language_metadata`. Those backing bytes must outlive the result.
pub fn decodeAlloc(
    a: A,
    payload: []const u8,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
) !types.Stored {
    return decodeImpl(a, payload, expected_title, expected_kind, language_metadata, null);
}

/// Commit measurements only after ordinary framing and semantic validation pass.
pub fn decodeWithMetricsAlloc(
    a: A,
    payload: []const u8,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
    metrics: *DecodeMetrics,
) !types.Stored {
    var observed: DecodeMetrics = .{};
    const stored = try decodeImpl(a, payload, expected_title, expected_kind, language_metadata, &observed);
    metrics.* = observed;
    return stored;
}

fn decodeImpl(
    a: A,
    payload: []const u8,
    expected_title: []const u8,
    expected_kind: format.BlobKind,
    language_metadata: ?format.LanguageMetadata,
    metrics: ?*DecodeMetrics,
) !types.Stored {
    if (payload.len < magic.len or !std.mem.eql(u8, payload[0..magic.len], magic)) return error.InvalidPresentation;
    var reader: Reader = .{ .a = a, .bytes = payload, .pos = magic.len, .metrics = metrics };
    const display_title = try reader.spans();
    const sections = try reader.sections();
    const preamble = try reader.spans();
    const layout = try reader.layout();
    const references = try reader.references();
    const media = try reader.media();
    if (reader.pos != payload.len) return error.InvalidPresentation;

    const title = expected_title;
    const language = if (expected_kind == .language)
        (language_metadata orelse return error.InvalidPresentation).heading
    else
        null;
    const language_code = if (expected_kind == .language) language_metadata.?.code else "";
    const stored: types.Stored = .{ .entry = .{
        .organization = layout,
        .title = title,
        .display_title = display_title,
        .kind = expected_kind,
        .language = language,
        .language_code = language_code,
        .sections = sections,
        .preamble_spans = preamble,
        .references = references,
        .media = media,
    } };
    try types.validateStored(stored, expected_title, expected_kind, language_metadata);
    return stored;
}

test "enum encoding maps build-only tags without runtime name lookup" {
    const BuildInlineKind = enum { text, template, link, external_link, line_break };
    var encoder: Encoder = .{ .a = std.testing.allocator };
    defer encoder.deinit();

    try encoder.enumByte(types.InlineKind, BuildInlineKind.link);
    try std.testing.expectEqualSlices(u8, &.{@backingInt(types.InlineKind.link)}, encoder.out.items);
    try std.testing.expectError(error.UncompiledTemplate, encoder.enumByte(types.InlineKind, BuildInlineKind.template));
}

test "binary presentation codec round trips semantic structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{ .kind = .link, .text = "cat", .target = "cat", .bold = true, .role = .headword }};
    const display_title = [_]types.Span{.{ .text = "cat", .italic = true, .classes = "Latn", .language = "en", .direction = "ltr", .role = .headword }};
    const blocks = [_]types.Block{.{ .kind = .definition, .spans = &spans }};
    const sections = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &blocks }};
    const senses = [_]types.Sense{.{ .block = 0 }};
    const lexemes = [_]types.Lexeme{.{ .language = "English", .kind = "Noun", .section = 0, .definitions = &senses }};
    const stored: types.Stored = .{ .entry = .{
        .organization = .{ .lexemes = &lexemes },
        .title = "cat",
        .display_title = &display_title,
        .kind = .language,
        .language = "English",
        .language_code = "en",
        .sections = &sections,
    } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("cat", decoded.entry.title);
    try std.testing.expectEqualStrings("English", decoded.entry.language.?);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.display_title.len);
    try std.testing.expect(decoded.entry.display_title[0].italic);
    try std.testing.expectEqualStrings("cat", decoded.entry.display_title[0].text);
    try std.testing.expectEqualStrings("Latn", decoded.entry.display_title[0].classes);
    try std.testing.expectEqualStrings("en", decoded.entry.display_title[0].language);
    try std.testing.expectEqualStrings("ltr", decoded.entry.display_title[0].direction);
    try std.testing.expectEqual(types.BlockKind.definition, decoded.entry.sections[0].blocks[0].kind);
    try std.testing.expect(decoded.entry.sections[0].blocks[0].spans[0].bold);
    try std.testing.expectEqualStrings("cat", decoded.entry.sections[0].blocks[0].spans[0].target);
}

test "binary presentation codec borrows decoded strings" {
    const a = std.testing.allocator;
    const spans = [_]types.Span{.{ .text = "borrow-me" }};
    const blocks = [_]types.Block{.{ .kind = .paragraph, .spans = &spans }};
    const sections = [_]types.Section{.{ .level = 1, .title = "body", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "cat", .kind = .citations, .sections = &sections } };
    const bytes = try encodeAlloc(a, stored);
    defer a.free(bytes);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const expected_title = "cat";
    const decoded = try decodeAlloc(arena.allocator(), bytes, expected_title, .citations, null);
    const text = decoded.entry.sections[0].blocks[0].spans[0].text;
    const payload_start = @intFromPtr(bytes.ptr);
    const payload_end = payload_start + bytes.len;
    const text_ptr = @intFromPtr(text.ptr);
    try std.testing.expect(text_ptr >= payload_start and text_ptr + text.len <= payload_end);
    try std.testing.expectEqual(@intFromPtr(expected_title.ptr), @intFromPtr(decoded.entry.title.ptr));
}

test "binary presentation codec preserves composite semantic fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = [_]types.Span{.{
        .kind = .external_link,
        .role = .quotation,
        .text = "quoted",
        .target = "https://example.invalid",
        .trail = "!",
        .language = "en",
        .bold = true,
        .italic = true,
        .code = true,
        .small = true,
        .superscript = true,
        .subscript = true,
        .strike = true,
        .underline = true,
    }};
    const cells = [_]types.Cell{.{ .header = true, .colspan = 2, .rowspan = 3, .spans = &spans }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{
        .{
            .kind = .definition,
            .depth = 2,
            .level = 3,
            .spans = &spans,
            .feature = .{ .kind = "audio", .language = "en", .data = "Cat.ogg", .tail_kind = "label", .tail = "RP" },
            .list_path = "##",
            .number = "2",
            .table = .{ .caption = &spans, .rows = &rows },
        },
        .{ .kind = .example, .spans = &spans },
        .{ .kind = .table, .depth = 2, .list_path = "::", .table = .{ .caption = &spans } },
    };
    const sections = [_]types.Section{
        .{ .level = 3, .title = "Etymology" },
        .{ .level = 3, .title = "Noun", .blocks = &blocks },
    };
    const examples = [_]usize{1};
    const senses = [_]types.Sense{.{
        .block = 0,
        .examples = &examples,
        .form = .{ .relation = "plural", .target = "cats", .language = "en" },
    }};
    const intro = [_]usize{1};
    const related = [_]usize{0};
    const lexemes = [_]types.Lexeme{.{
        .language = "English",
        .kind = "Noun",
        .section = 1,
        .etymology = 0,
        .definitions = &senses,
        .introduction = &intro,
        .related_sections = &related,
    }};
    const other_sections = [_]usize{0};
    const references = [_]types.Reference{.{ .number = 1, .group_number = 2, .name = "ref", .group = "notes", .spans = &spans }};
    const media = [_]types.Media{
        .{ .file = "Cat.svg", .kind = .image, .caption = "A cat" },
        .{ .file = "Cat.ogg", .kind = .audio, .caption = "Pronunciation" },
    };
    const stored: types.Stored = .{ .entry = .{
        .organization = .{ .lexemes = &lexemes, .other_sections = &other_sections },
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
        .sections = &sections,
        .preamble_spans = &spans,
        .references = &references,
        .media = &media,
    } };
    const bytes = try encodeAlloc(a, stored);
    const decoded = try decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    var metrics: DecodeMetrics = .{};
    const measured = try decodeWithMetricsAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" }, &metrics);
    // Nested table rows/cells/spans, lexical indices, references and media all
    // contribute to Android's per-record aggregate count budget.
    try std.testing.expectEqual(@as(u64, 23), metrics.total_items);
    try std.testing.expectEqual("https://example.invalid".len, metrics.largest_string_bytes);
    const measured_json = try std.json.Stringify.valueAlloc(a, measured, .{});
    const ordinary_json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expectEqualStrings(ordinary_json, measured_json);
    const span = decoded.entry.sections[1].blocks[0].spans[0];
    try std.testing.expect(span.bold and span.italic and span.code and span.small and span.superscript and span.subscript and span.strike and span.underline);
    try std.testing.expectEqual(types.Role.quotation, span.role);
    try std.testing.expectEqualStrings("https://example.invalid", span.target);
    try std.testing.expectEqualStrings("audio", decoded.entry.sections[1].blocks[0].feature.?.kind);
    try std.testing.expectEqual(@as(u16, 2), decoded.entry.sections[1].blocks[0].table.?.rows[0].cells[0].colspan);
    try std.testing.expectEqualStrings("cats", decoded.entry.organization.lexemes[0].definitions[0].form.?.target);
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.references[0].group_number);
    try std.testing.expectEqual(types.MediaKind.audio, decoded.entry.media[1].kind);
    const caption_only = decoded.entry.sections[1].blocks[2];
    try std.testing.expectEqual(types.BlockKind.table, caption_only.kind);
    try std.testing.expectEqual(@as(u8, 2), caption_only.depth);
    try std.testing.expectEqualStrings("::", caption_only.list_path);
    try std.testing.expectEqual(@as(usize, 0), caption_only.table.?.rows.len);
    try std.testing.expectEqual(@as(usize, 1), caption_only.table.?.caption.len);
    const caption_span = caption_only.table.?.caption[0];
    try std.testing.expectEqual(types.InlineKind.external_link, caption_span.kind);
    try std.testing.expectEqualStrings("quoted", caption_span.text);
    try std.testing.expectEqualStrings("https://example.invalid", caption_span.target);
    try std.testing.expectEqualStrings("en", caption_span.language);
    try std.testing.expect(caption_span.bold and caption_span.italic);

    const expected_json = try std.json.Stringify.valueAlloc(a, stored, .{});
    const decoded_json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expectEqualStrings(expected_json, decoded_json);
}

test "binary presentation codec rejects encoder collection overflow" {
    var encoder: Encoder = .{ .a = std.testing.allocator };
    defer encoder.deinit();
    try std.testing.expectError(error.PresentationTooLarge, encoder.count(max_items + 1));
}

test "binary presentation codec keeps string and collection limits independent" {
    const a = std.testing.allocator;
    const value = try a.alloc(u8, max_items + 1);
    defer a.free(value);
    @memset(value, 'x');
    var encoder: Encoder = .{ .a = a };
    defer encoder.deinit();
    try encoder.string(value);
    try std.testing.expectEqual(@as(usize, 4 + value.len), encoder.out.items.len);
}

test "binary presentation codec rejects invalid UTF-8 strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored: types.Stored = .{ .entry = .{
        .title = "cat",
        .kind = .citations,
        .sections = &.{.{ .level = 1, .title = "x" }},
    } };
    const bytes = try encodeAlloc(a, stored);
    const damaged = try a.dupe(u8, bytes);
    const title_at = magic.len + 4 + 1 + 4;
    damaged[title_at] = 0xff;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, damaged, "cat", .citations, null));
}

test "binary presentation codec rejects invalid framing and trailing bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, "{}", "cat", .citations, null));
    const stored: types.Stored = .{ .entry = .{ .title = "cat", .kind = .citations } };
    const bytes = try encodeAlloc(a, stored);
    const damaged = try std.mem.concat(a, u8, &.{ bytes, "x" });
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, damaged, "cat", .citations, null));
}

test "failed presentation decoding never commits successful metrics" {
    var metrics: DecodeMetrics = .{ .total_items = 99, .largest_string_bytes = 77 };
    try std.testing.expectError(error.InvalidPresentation, decodeWithMetricsAlloc(std.testing.allocator, "DPR2", "x", .supplemental, null, &metrics));
    try std.testing.expectEqual(@as(u64, 99), metrics.total_items);
    try std.testing.expectEqual(@as(usize, 77), metrics.largest_string_bytes);
}

test "sparse table observations preserve global boundaries and rowspan placement" {
    const a = std.testing.allocator;
    var broad: [6]types.Cell = undefined;
    @memset(&broad, .{ .colspan = 100 });
    const broad_rows = [_]types.Row{.{ .cells = &broad }};
    const wide = measureTableGrid(.{ .rows = &broad_rows });
    try std.testing.expectEqual(@as(?usize, 6), wide.exact_compact_columns);
    try std.testing.expectEqual(@as(usize, 1), wide.occupied_rows);
    const first = [_]types.Cell{ .{ .colspan = 100, .rowspan = 2 }, .{ .colspan = 100 } };
    const second = [_]types.Cell{ .{ .colspan = 50 }, .{ .colspan = 50 } };
    const split_rows = [_]types.Row{ .{ .cells = &first }, .{ .cells = &second } };
    const split = measureTableGrid(.{ .rows = &split_rows });
    try std.testing.expectEqual(@as(?usize, 3), split.exact_compact_columns);
    try std.testing.expectEqual(@as(usize, 2), split.occupied_rows);
    const old_a = [_]types.Cell{ .{ .rowspan = 2 }, .{ .colspan = 2 } };
    const old_b = [_]types.Cell{ .{}, .{} };
    const old_c = [_]types.Cell{ .{}, .{}, .{} };
    const old_rows = [_]types.Row{ .{ .cells = &old_a }, .{ .cells = &old_b }, .{ .cells = &old_c } };
    try std.testing.expectEqual(@as(?usize, 3), measureTableGrid(.{ .rows = &old_rows }).exact_compact_columns);
    try std.testing.expectEqual(@as(?usize, 0), measureTableGrid(.{}).exact_compact_columns);
    const empty_rows = [_]types.Row{ .{}, .{} };
    try std.testing.expectEqual(@as(usize, 2), measureTableGrid(.{ .rows = &empty_rows }).occupied_rows);
    const trailing = [_]types.Cell{.{ .rowspan = 100 }};
    const trailing_rows = [_]types.Row{.{ .cells = &trailing }};
    try std.testing.expectEqual(@as(usize, 100), measureTableGrid(.{ .rows = &trailing_rows }).occupied_rows);
    const cells = try a.alloc(types.Cell, 513);
    defer a.free(cells);
    @memset(cells, .{ .colspan = 100 });
    const exact_rows = [_]types.Row{.{ .cells = cells[0..512] }};
    try std.testing.expectEqual(@as(?usize, 512), measureTableGrid(.{ .rows = &exact_rows }).exact_compact_columns);
    cells[512].rowspan = 100;
    const saturated_rows = [_]types.Row{ .{ .cells = cells }, .{}, .{} };
    const saturated = measureTableGrid(.{ .rows = &saturated_rows });
    try std.testing.expect(saturated.column_limit_exceeded);
    try std.testing.expect(saturated.exact_compact_columns == null);
    try std.testing.expectEqual(@as(usize, 513), saturated.columns_lower_bound);
    try std.testing.expectEqual(@as(usize, 100), saturated.occupied_rows);
}

test "unsupported spans remain ordinary decode values while observation is explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]types.Cell{ .{ .colspan = 0 }, .{ .colspan = 101 }, .{ .rowspan = 0 }, .{ .rowspan = 101 } }) |cell| {
        const cells = [_]types.Cell{cell};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
        const sections = [_]types.Section{.{ .level = 2, .title = "Table", .blocks = &blocks }};
        const stored: types.Stored = .{ .entry = .{ .title = "table", .kind = .supplemental, .sections = &sections } };
        const payload = try encodeAlloc(a, stored);
        const ordinary = try decodeAlloc(a, payload, "table", .supplemental, null);
        var metrics: DecodeMetrics = .{};
        const measured = try decodeWithMetricsAlloc(a, payload, "table", .supplemental, null, &metrics);
        try std.testing.expectEqual(ordinary.entry.sections[0].blocks[0].table.?.rows[0].cells[0].colspan, measured.entry.sections[0].blocks[0].table.?.rows[0].cells[0].colspan);
        try std.testing.expect(!metrics.table_spans_supported);
        try std.testing.expect(metrics.table_columns_exact == null);
        try std.testing.expect(!metrics.table_column_limit_exceeded);
        try std.testing.expectEqual(@as(usize, 1), metrics.tables);
    }
}

test "table observations preserve round trips and do not commit failed decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [6]types.Cell = undefined;
    @memset(&cells, .{ .colspan = 100 });
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Table", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "wide", .kind = .supplemental, .sections = &sections } };
    const payload = try encodeAlloc(a, stored);
    const ordinary = try decodeAlloc(a, payload, "wide", .supplemental, null);
    var metrics: DecodeMetrics = .{};
    const measured = try decodeWithMetricsAlloc(a, payload, "wide", .supplemental, null, &metrics);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, ordinary, .{}), try std.json.Stringify.valueAlloc(a, measured, .{}));
    try std.testing.expectEqual(@as(?usize, 6), metrics.table_columns_exact);
    try std.testing.expectEqual(@as(usize, 1), metrics.max_table_rows);
    try std.testing.expectEqual(@as(u16, 100), metrics.max_table_colspan);
    const corrupt = try a.alloc(u8, payload.len + 1);
    @memcpy(corrupt[0..payload.len], payload);
    corrupt[payload.len] = 0;
    metrics.table_columns_exact = 77;
    metrics.tables = 99;
    try std.testing.expectError(error.InvalidPresentation, decodeWithMetricsAlloc(a, corrupt, "wide", .supplemental, null, &metrics));
    try std.testing.expectEqual(@as(?usize, 77), metrics.table_columns_exact);
    try std.testing.expectEqual(@as(usize, 99), metrics.tables);
}
