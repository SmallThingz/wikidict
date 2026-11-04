const std = @import("std");
const format = @import("blob_format.zig");
const types = @import("presentation_types.zig");
const A = std.mem.Allocator;

pub const magic = "DPR2";
pub const explained_magic = "DPR3";
pub const color_magic = "DPR4";
pub const anchor_magic = "DPR5";
pub const background_magic = "DPR6";
pub const nested_magic = "DPR7";
pub const cell_blocks_magic = "DPR8";
pub const reference_items_magic = "DPR9";
pub const font_scale_magic = "DPRA";
pub const font_scale_basis_magic = "DPRB";
const Version = enum { plain, explained, colored, anchored, span_background, nested_tables, cell_blocks, reference_items, font_scale, font_scale_basis };
fn hasRgb(version: Version) bool {
    return version == .colored or version == .anchored or version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis;
}
fn hasAnchorFields(version: Version) bool {
    return version == .anchored or version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis;
}
fn hasSpanBackgroundFields(version: Version) bool {
    return version == .span_background or version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis;
}
fn hasNestedFields(version: Version) bool {
    return version == .nested_tables or version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis;
}
fn hasCellBlockFields(version: Version) bool {
    return version == .cell_blocks or version == .reference_items or version == .font_scale or version == .font_scale_basis;
}
fn hasReferenceFields(version: Version) bool {
    return version == .reference_items or version == .font_scale or version == .font_scale_basis;
}
const max_items: usize = 1 << 20;
const max_string_bytes: usize = 32 * 1024 * 1024;
const no_index: u32 = std.math.maxInt(u32);

const Encoder = struct {
    a: A,
    version: Version = .plain,
    out: std.ArrayList(u8) = .empty,
    table_depth: usize = 0,
    remaining_items: usize = max_items,

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
        if (hasNestedFields(self.version)) {
            if (value > self.remaining_items) return error.PresentationTooLarge;
            self.remaining_items -= value;
        }
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
        const explanation: []const u8 = if (comptime @hasField(@TypeOf(value), "explanation")) value.explanation else "";
        const fields = [_][]const u8{ value.text, value.target, trail, value.language, value.classes, value.direction, explanation };
        const strings = fields[0..if (self.version != .plain) @as(usize, 7) else 6];
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
        if (hasRgb(self.version)) {
            const foreground: ?[]const u8 = if (comptime @hasField(@TypeOf(value), "foreground")) value.foreground else null;
            try self.byte(@intFromBool(foreground != null));
            if (foreground) |color| {
                if (!types.isCanonicalRgb(color)) return error.InvalidPresentation;
                try self.string(color);
            }
        }
        if (hasSpanBackgroundFields(self.version)) {
            const background: ?[]const u8 = if (comptime @hasField(@TypeOf(value), "background")) value.background else null;
            try self.byte(@intFromBool(background != null));
            if (background) |color| {
                if (!types.isCanonicalRgb(color)) return error.InvalidPresentation;
                try self.string(color);
            }
        }
        const scale = spanScale(value);
        const basis = spanScaleBasis(value);
        if (scale) |n| if (!std.math.isFinite(n) or n < 0) return error.InvalidPresentation;
        if (basis == .normal_body and (scale == null or self.version != .font_scale_basis)) return error.InvalidPresentation;
        if (self.version == .font_scale or self.version == .font_scale_basis) {
            try self.byte(@intFromBool(scale != null));
            if (scale) |n| {
                try self.writeU32(@bitCast(n));
                if (self.version == .font_scale_basis) try self.byte(@intFromEnum(basis));
            }
        }
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
    fn cell(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        try self.byte(@intFromBool(value.header));
        try self.writeU16(value.colspan);
        try self.writeU16(value.rowspan);
        if (hasRgb(self.version)) {
            const background: ?[]const u8 = if (comptime @hasField(@TypeOf(value), "background")) value.background else null;
            try self.byte(@intFromBool(background != null));
            if (background) |color| {
                if (!types.isCanonicalRgb(color)) return error.InvalidPresentation;
                try self.string(color);
            }
        }
        try self.spans(value.spans);
        if (hasNestedFields(self.version)) {
            if (comptime @hasField(@TypeOf(value), "nested_table")) {
                if (value.nested_table != null and value.spans.len != 0) return error.InvalidPresentation;
                try self.table(value.nested_table);
            } else try self.byte(0);
        }
        if (hasCellBlockFields(self.version)) {
            if (comptime @hasField(@TypeOf(value), "blocks")) {
                try self.byte(@intFromBool(value.blocks != null));
                if (value.blocks) |blocks| {
                    if (value.spans.len != 0) return error.InvalidPresentation;
                    if (comptime @hasField(@TypeOf(value), "nested_table")) if (value.nested_table != null) return error.InvalidPresentation;
                    try self.count(blocks.len);
                    for (blocks) |block_value| try self.block(block_value);
                }
            } else try self.byte(0);
        }
    }
    fn row(self: *Encoder, value: anytype) !void {
        try self.count(value.cells.len);
        for (value.cells) |cell_value| try self.cell(cell_value);
    }
    fn tableGeometry(self: *Encoder, geometry: ?types.TableGeometry) !void {
        const value = geometry orelse {
            try self.byte(0);
            return;
        };
        if (!types.validTableGeometry(value)) return error.InvalidPresentation;
        const flags: u8 = @as(u8, @intFromBool(value.border != null)) |
            (@as(u8, @intFromBool(value.cell_spacing != null)) << 1) |
            (@as(u8, @intFromBool(value.cell_padding != null)) << 2) |
            (@as(u8, @intFromBool(value.width != null)) << 3);
        try self.byte(flags);
        if (value.border) |n| try self.writeU16(n);
        if (value.cell_spacing) |n| try self.writeU16(n);
        if (value.cell_padding) |n| try self.writeU16(n);
        if (value.width) |width| {
            try self.enumByte(types.TableWidthUnit, width.unit);
            try self.writeU32(width.value);
        }
    }
    fn table(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        if (value) |table_value| {
            if (self.table_depth >= types.max_table_depth) return error.InvalidPresentation;
            self.table_depth += 1;
            defer self.table_depth -= 1;
            try self.byte(1);
            if (hasNestedFields(self.version)) {
                const geometry: ?types.TableGeometry = if (comptime @hasField(@TypeOf(table_value), "geometry")) table_value.geometry else null;
                try self.tableGeometry(geometry);
            }
            try self.spans(table_value.caption);
            try self.count(table_value.rows.len);
            for (table_value.rows) |row_value| try self.row(row_value);
        } else try self.byte(0);
    }
    fn block(self: *Encoder, value: anytype) error{ OutOfMemory, InvalidPresentation, PresentationTooLarge, UncompiledTemplate }!void {
        if ((anchorValue(value).len != 0 or fallbackValue(value).len != 0) and (try enumByteValue(types.BlockKind, value.kind)) != @backingInt(types.BlockKind.heading)) return error.InvalidPresentation;
        try self.enumByte(types.BlockKind, value.kind);
        try self.byte(value.depth);
        try self.byte(value.level);
        try self.spans(value.spans);
        try self.feature(value.feature);
        try self.string(value.list_path);
        try self.string(value.number);
        try self.table(value.table);
        if (hasAnchorFields(self.version)) {
            try self.string(anchorValue(value));
            try self.string(fallbackValue(value));
        }
    }
    fn sections(self: *Encoder, values: anytype) !void {
        try self.count(values.len);
        for (values) |section| {
            try self.byte(section.level);
            try self.string(section.title);
            if (hasAnchorFields(self.version)) {
                try self.string(anchorValue(section));
                try self.string(fallbackValue(section));
            }
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
            const kind = try enumByteValue(types.ReferenceKind, reference.kind);
            if (reference.number == 0) return error.InvalidPresentation;
            if (kind == @backingInt(types.ReferenceKind.note)) {
                const ordinal = reference.group_number orelse return error.InvalidPresentation;
                if (ordinal == 0) return error.InvalidPresentation;
                if (hasReferenceFields(self.version)) try self.byte(kind);
                try self.index(reference.number);
                try self.index(ordinal);
                try self.string(reference.name);
            } else {
                if (!hasReferenceFields(self.version) or reference.group_number != null or reference.name.len != 0)
                    return error.InvalidPresentation;
                try self.byte(kind);
                try self.index(reference.number);
            }
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

    fn tableTree(self: *DecodeMetrics, value: types.Table) void {
        self.table(value);
        for (value.rows) |row| for (row.cells) |cell| {
            if (cell.nested_table) |child| self.tableTree(child);
            if (cell.blocks) |blocks| for (blocks) |block_value| if (block_value.table) |child| self.tableTree(child);
        };
    }

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
    version: Version = .plain,
    bytes: []const u8,
    pos: usize = 0,
    metrics: ?*DecodeMetrics = null,
    table_depth: usize = 0,
    remaining_items: usize = max_items,

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
        if (hasNestedFields(self.version)) {
            if (value > self.remaining_items) return error.InvalidPresentation;
            self.remaining_items -= value;
        }
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
        var result: types.Span = .{
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
            .explanation = if (self.version != .plain) try self.string() else "",
            .foreground = if (hasRgb(self.version) and try self.presence()) foreground: {
                const value = try self.string();
                if (!types.isCanonicalRgb(value)) return error.InvalidPresentation;
                break :foreground value;
            } else null,
            .background = if (hasSpanBackgroundFields(self.version) and try self.presence()) background: {
                const value = try self.string();
                if (!types.isCanonicalRgb(value)) return error.InvalidPresentation;
                break :background value;
            } else null,
        };
        if ((self.version == .font_scale or self.version == .font_scale_basis) and try self.presence()) {
            const n: f32 = @bitCast(try self.readU32());
            if (!std.math.isFinite(n) or n < 0) return error.InvalidPresentation;
            if (self.version == .font_scale_basis) result.font_scale_basis = try self.enumValue(types.FontScaleBasis);
            result.font_scale = if (n == 1 and result.font_scale_basis == .context) null else n;
        }
        return result;
    }
    fn spans(self: *Reader) ![]const types.Span {
        const len = try self.count(if (self.version == .font_scale or self.version == .font_scale_basis) 34 else if (hasSpanBackgroundFields(self.version)) 33 else if (hasRgb(self.version)) 32 else if (self.version == .explained) 31 else 27);
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
    fn cell(self: *Reader) error{ OutOfMemory, InvalidPresentation }!types.Cell {
        var value: types.Cell = .{
            .header = try self.presence(),
            .colspan = try self.readU16(),
            .rowspan = try self.readU16(),
            .background = if (hasRgb(self.version) and try self.presence()) background: {
                const value = try self.string();
                if (!types.isCanonicalRgb(value)) return error.InvalidPresentation;
                break :background value;
            } else null,
            .spans = try self.spans(),
        };
        if (hasNestedFields(self.version)) value.nested_table = try self.table();
        if (value.nested_table != null and value.spans.len != 0) return error.InvalidPresentation;
        if (hasCellBlockFields(self.version) and try self.presence()) {
            if (value.spans.len != 0 or value.nested_table != null) return error.InvalidPresentation;
            const len = try self.count(25);
            const blocks = try self.a.alloc(types.Block, len);
            for (blocks) |*block_value| block_value.* = try self.block();
            value.blocks = blocks;
        }
        return value;
    }
    fn row(self: *Reader) !types.Row {
        const len = try self.count(if (hasCellBlockFields(self.version)) 12 else if (hasNestedFields(self.version)) 11 else if (hasRgb(self.version)) 10 else 9);
        const out = try self.a.alloc(types.Cell, len);
        for (out) |*cell_value| cell_value.* = try self.cell();
        return .{ .cells = out };
    }
    fn tableGeometry(self: *Reader) !?types.TableGeometry {
        const flags = try self.byte();
        if (flags & 0xf0 != 0) return error.InvalidPresentation;
        if (flags == 0) return null;
        const value: types.TableGeometry = .{
            .border = if (flags & 1 != 0) try self.readU16() else null,
            .cell_spacing = if (flags & 2 != 0) try self.readU16() else null,
            .cell_padding = if (flags & 4 != 0) try self.readU16() else null,
            .width = if (flags & 8 != 0) .{ .unit = try self.enumValue(types.TableWidthUnit), .value = try self.readU32() } else null,
        };
        if (!types.validTableGeometry(value)) return error.InvalidPresentation;
        return value;
    }
    fn table(self: *Reader) error{ OutOfMemory, InvalidPresentation }!?types.Table {
        if (!try self.presence()) return null;
        if (self.table_depth >= types.max_table_depth) return error.InvalidPresentation;
        self.table_depth += 1;
        defer self.table_depth -= 1;
        const geometry = if (hasNestedFields(self.version)) try self.tableGeometry() else null;
        const caption = try self.spans();
        const len = try self.count(4);
        const rows = try self.a.alloc(types.Row, len);
        for (rows) |*row_value| row_value.* = try self.row();
        const value: types.Table = .{ .caption = caption, .rows = rows, .geometry = geometry };
        if (self.table_depth == 1) if (self.metrics) |metrics| metrics.tableTree(value);
        return value;
    }
    fn block(self: *Reader) error{ OutOfMemory, InvalidPresentation }!types.Block {
        return .{
            .kind = try self.enumValue(types.BlockKind),
            .depth = try self.byte(),
            .level = try self.byte(),
            .spans = try self.spans(),
            .feature = try self.feature(),
            .list_path = try self.string(),
            .number = try self.string(),
            .table = try self.table(),
            .anchor = if (hasAnchorFields(self.version)) try self.string() else "",
            .anchor_fallback = if (hasAnchorFields(self.version)) try self.string() else "",
        };
    }
    fn sections(self: *Reader) ![]const types.Section {
        const len = try self.count(if (hasAnchorFields(self.version)) 17 else 9);
        const out = try self.a.alloc(types.Section, len);
        for (out) |*section| {
            section.level = try self.byte();
            section.title = try self.string();
            section.anchor = if (hasAnchorFields(self.version)) try self.string() else "";
            section.anchor_fallback = if (hasAnchorFields(self.version)) try self.string() else "";
            const block_len = try self.count(if (hasAnchorFields(self.version)) 25 else 17);
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
        const len = try self.count(if (hasReferenceFields(self.version)) 13 else 20);
        const out = try self.a.alloc(types.Reference, len);
        for (out) |*reference| {
            const kind = if (hasReferenceFields(self.version)) try self.enumValue(types.ReferenceKind) else types.ReferenceKind.note;
            reference.* = .{
                .kind = kind,
                .number = try self.index(),
                .group_number = if (kind == .note) @as(u32, @intCast(try self.index())) else null,
                .name = if (kind == .note) try self.string() else "",
                .group = try self.string(),
                .spans = try self.spans(),
            };
        }
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

fn spanScaleBasis(value: anytype) types.FontScaleBasis {
    if (comptime @hasField(@TypeOf(value), "font_scale_basis")) return value.font_scale_basis;
    return .context;
}
fn spanScale(value: anytype) ?f32 {
    if (comptime @hasField(@TypeOf(value), "font_scale")) {
        if (value.font_scale) |n| return if (n == 1 and spanScaleBasis(value) == .context) null else n;
    }
    return null;
}
fn spansHaveScale(values: anytype) bool {
    for (values) |value| if (spanScale(value) != null) return true;
    return false;
}
fn tableHasScale(table: anytype, depth: usize) bool {
    // The encoder independently rejects excess depth; selection stays bounded.
    if (depth > types.max_table_depth) return false;
    if (spansHaveScale(table.caption)) return true;
    for (table.rows) |row| for (row.cells) |cell| {
        if (spansHaveScale(cell.spans)) return true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| {
            if (tableHasScale(child, depth + 1)) return true;
        };
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks) |blocks| {
            for (blocks) |block| {
                if (spansHaveScale(block.spans)) return true;
                if (block.table) |child| if (tableHasScale(child, depth + 1)) return true;
            }
        };
    };
    return false;
}
fn hasFontScale(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveScale(display) or spansHaveScale(preamble)) return true;
    for (sections) |section| for (section.blocks) |block| {
        if (spansHaveScale(block.spans)) return true;
        if (block.table) |table| if (tableHasScale(table, 1)) return true;
    };
    for (references) |reference| if (spansHaveScale(reference.spans)) return true;
    return false;
}

fn spansHaveBodyScale(values: anytype) bool {
    for (values) |value| if (spanScaleBasis(value) == .normal_body) return true;
    return false;
}
fn tableHasBodyScale(table: anytype, depth: usize) bool {
    // The encoder independently rejects excess depth; selection stays bounded.
    if (depth > types.max_table_depth) return false;
    if (spansHaveBodyScale(table.caption)) return true;
    for (table.rows) |row| for (row.cells) |cell| {
        if (spansHaveBodyScale(cell.spans)) return true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| {
            if (tableHasBodyScale(child, depth + 1)) return true;
        };
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks) |blocks| {
            for (blocks) |block| {
                if (spansHaveBodyScale(block.spans)) return true;
                if (block.table) |child| if (tableHasBodyScale(child, depth + 1)) return true;
            }
        };
    };
    return false;
}
fn hasBodyFontScale(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveBodyScale(display) or spansHaveBodyScale(preamble)) return true;
    for (sections) |section| for (section.blocks) |block| {
        if (spansHaveBodyScale(block.spans)) return true;
        if (block.table) |table| if (tableHasBodyScale(table, 1)) return true;
    };
    for (references) |reference| if (spansHaveBodyScale(reference.spans)) return true;
    return false;
}

fn spansHaveExplanation(values: anytype) bool {
    for (values) |span_value| {
        if (comptime @hasField(@TypeOf(span_value), "explanation"))
            if (span_value.explanation.len != 0) return true;
    }
    return false;
}

// Visit every span that Encoder serializes. Layout contains only indices and
// scalar fields; media descriptions are plain text, not another span tree.
fn hasExplanation(display: anytype, sections_value: anytype, preamble: anytype, references_value: anytype) bool {
    if (spansHaveExplanation(display) or spansHaveExplanation(preamble)) return true;
    for (sections_value) |section| for (section.blocks) |block_value| {
        if (spansHaveExplanation(block_value.spans)) return true;
        if (block_value.table) |table_value| {
            if (spansHaveExplanation(table_value.caption)) return true;
            for (table_value.rows) |row_value| for (row_value.cells) |cell_value|
                if (spansHaveExplanation(cell_value.spans)) return true;
        }
    };
    for (references_value) |reference| if (spansHaveExplanation(reference.spans)) return true;
    return false;
}

fn spansHaveForeground(values: anytype) bool {
    for (values) |span_value| if (comptime @hasField(@TypeOf(span_value), "foreground")) {
        if (span_value.foreground != null) return true;
    };
    return false;
}

fn hasColor(display: anytype, sections_value: anytype, preamble: anytype, references_value: anytype) bool {
    if (spansHaveForeground(display) or spansHaveForeground(preamble)) return true;
    for (sections_value) |section| for (section.blocks) |block_value| {
        if (spansHaveForeground(block_value.spans)) return true;
        if (block_value.table) |table_value| {
            if (spansHaveForeground(table_value.caption)) return true;
            for (table_value.rows) |row_value| for (row_value.cells) |cell_value| {
                if (comptime @hasField(@TypeOf(cell_value), "background")) {
                    if (cell_value.background != null) return true;
                }
                if (spansHaveForeground(cell_value.spans)) return true;
            };
        }
    };
    for (references_value) |reference| if (spansHaveForeground(reference.spans)) return true;
    return false;
}

fn spansHaveBackground(values: anytype) bool {
    for (values) |span| if (comptime @hasField(@TypeOf(span), "background")) {
        if (span.background != null) return true;
    };
    return false;
}

fn hasSpanBackground(display: anytype, sections: anytype, preamble: anytype, references: anytype) bool {
    if (spansHaveBackground(display) or spansHaveBackground(preamble)) return true;
    for (sections) |section| for (section.blocks) |block| {
        if (spansHaveBackground(block.spans)) return true;
        if (block.table) |table| {
            if (spansHaveBackground(table.caption)) return true;
            for (table.rows) |row| for (row.cells) |cell|
                if (spansHaveBackground(cell.spans)) return true;
        }
    };
    for (references) |reference| if (spansHaveBackground(reference.spans)) return true;
    return false;
}

fn hasNestedTables(sections: anytype) bool {
    for (sections) |section| for (section.blocks) |block| if (block.table) |table| {
        if (comptime @hasField(@TypeOf(table), "geometry")) if (table.geometry != null) return true;
        for (table.rows) |row| for (row.cells) |cell| {
            if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table != null) return true;
        };
    };
    return false;
}

fn tableHasCellBlocks(table: anytype, depth: usize) bool {
    // Encoding rejects excess depth; version detection must also remain bounded.
    if (depth > types.max_table_depth) return false;
    for (table.rows) |row| for (row.cells) |cell| {
        if (comptime @hasField(@TypeOf(cell), "blocks")) if (cell.blocks != null) return true;
        if (comptime @hasField(@TypeOf(cell), "nested_table")) if (cell.nested_table) |child| {
            if (tableHasCellBlocks(child, depth + 1)) return true;
        };
    };
    return false;
}

fn hasCellBlocks(sections: anytype) bool {
    for (sections) |section| for (section.blocks) |block_value| if (block_value.table) |table| {
        if (tableHasCellBlocks(table, 1)) return true;
    };
    return false;
}

fn anchorValue(value: anytype) []const u8 {
    return if (comptime @hasField(@TypeOf(value), "anchor")) value.anchor else "";
}

fn fallbackValue(value: anytype) []const u8 {
    return if (comptime @hasField(@TypeOf(value), "anchor_fallback")) value.anchor_fallback else "";
}

fn hasAnchors(sections: anytype) bool {
    for (sections) |section| {
        if (anchorValue(section).len != 0 or fallbackValue(section).len != 0) return true;
        for (section.blocks) |block_value| if (anchorValue(block_value).len != 0 or fallbackValue(block_value).len != 0) return true;
    }
    return false;
}

fn hasReferenceFragments(references: anytype) bool {
    for (references) |reference| if (reference.kind == .fragment) return true;
    return false;
}

fn versionMagic(version: Version) []const u8 {
    return switch (version) {
        .plain => magic,
        .explained => explained_magic,
        .colored => color_magic,
        .anchored => anchor_magic,
        .span_background => background_magic,
        .nested_tables => nested_magic,
        .cell_blocks => cell_blocks_magic,
        .reference_items => reference_items_magic,
        .font_scale => font_scale_magic,
        .font_scale_basis => font_scale_basis_magic,
    };
}

pub fn encodeAlloc(a: A, stored: types.Stored) ![]u8 {
    if (!std.mem.eql(u8, stored.schema, types.schema)) return error.InvalidPresentation;
    const version: Version = if (hasBodyFontScale(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .font_scale_basis else if (hasFontScale(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .font_scale else if (hasReferenceFragments(stored.entry.references)) .reference_items else if (hasCellBlocks(stored.entry.sections)) .cell_blocks else if (hasNestedTables(stored.entry.sections)) .nested_tables else if (hasSpanBackground(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .span_background else if (hasAnchors(stored.entry.sections)) .anchored else if (hasColor(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .colored else if (hasExplanation(stored.entry.display_title, stored.entry.sections, stored.entry.preamble_spans, stored.entry.references)) .explained else .plain;
    var encoder: Encoder = .{ .a = a, .version = version };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, versionMagic(version));
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
    const version: Version = if (hasBodyFontScale(display_title, sections, @as([]const types.Span, &.{}), references_value)) .font_scale_basis else if (hasFontScale(display_title, sections, @as([]const types.Span, &.{}), references_value)) .font_scale else if (hasReferenceFragments(references_value)) .reference_items else if (hasCellBlocks(sections)) .cell_blocks else if (hasNestedTables(sections)) .nested_tables else if (hasSpanBackground(display_title, sections, @as([]const types.Span, &.{}), references_value)) .span_background else if (hasAnchors(sections)) .anchored else if (hasColor(display_title, sections, @as([]const types.Span, &.{}), references_value)) .colored else if (hasExplanation(display_title, sections, @as([]const types.Span, &.{}), references_value)) .explained else .plain;
    var encoder: Encoder = .{ .a = a, .version = version };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, versionMagic(version));
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
    if (payload.len < magic.len) return error.InvalidPresentation;
    const version: Version = if (std.mem.eql(u8, payload[0..magic.len], magic)) .plain else if (std.mem.eql(u8, payload[0..explained_magic.len], explained_magic)) .explained else if (std.mem.eql(u8, payload[0..color_magic.len], color_magic)) .colored else if (std.mem.eql(u8, payload[0..anchor_magic.len], anchor_magic)) .anchored else if (std.mem.eql(u8, payload[0..background_magic.len], background_magic)) .span_background else if (std.mem.eql(u8, payload[0..nested_magic.len], nested_magic)) .nested_tables else if (std.mem.eql(u8, payload[0..cell_blocks_magic.len], cell_blocks_magic)) .cell_blocks else if (std.mem.eql(u8, payload[0..reference_items_magic.len], reference_items_magic)) .reference_items else if (std.mem.eql(u8, payload[0..font_scale_magic.len], font_scale_magic)) .font_scale else if (std.mem.eql(u8, payload[0..font_scale_basis_magic.len], font_scale_basis_magic)) .font_scale_basis else return error.InvalidPresentation;
    var reader: Reader = .{ .a = a, .version = version, .bytes = payload, .pos = magic.len, .metrics = metrics };
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
    try std.testing.expectEqual(@as(?u32, 2), decoded.entry.references[0].group_number);
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

test "legacy DPR2 compact spans remain readable and byte identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Independently framed pre-extension DPR2: eight minimal empty spans and
    // six empty following lists. This also distinguishes the 27/31 minimum.
    const legacy = "\x44\x50\x52\x32\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const parsed = try decodeAlloc(a, legacy, "entry", .supplemental, null);
    try std.testing.expectEqualStrings("dict.presentation.v3", parsed.schema);
    try std.testing.expectEqual(@as(usize, 8), parsed.entry.display_title.len);
    for (parsed.entry.display_title) |span_value| try std.testing.expectEqualStrings("", span_value.explanation);
    try std.testing.expectEqualStrings(legacy, try encodeAlloc(a, parsed));
    try std.testing.expectEqualStrings(legacy, try encodeBuildAlloc(a, parsed.entry.display_title, parsed.entry.sections, parsed.entry.organization, parsed.entry.references, parsed.entry.media));
}

test "DPR3 explanations traverse every stored span container and reject corrupt fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const note = "feminine gender explanation";
    const annotated = [_]types.Span{.{ .kind = .link, .text = "f", .target = "glossary", .explanation = note, .italic = true }};
    const blank: []const types.Span = &.{};
    for (0..6) |location| {
        const cells = [_]types.Cell{.{ .spans = if (location == 3) &annotated else blank }};
        const rows = [_]types.Row{.{ .cells = &cells }};
        const table_value: types.Table = .{ .caption = if (location == 2) &annotated else blank, .rows = &rows };
        const blocks = [_]types.Block{.{ .kind = .table, .spans = if (location == 1) &annotated else blank, .table = table_value }};
        const sections_value = [_]types.Section{.{ .level = 3, .title = "Noun", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 4) &annotated else blank }};
        const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .display_title = if (location == 0) &annotated else blank, .sections = &sections_value, .preamble_spans = if (location == 5) &annotated else blank, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(explained_magic, bytes[0..4]);
        var metrics: DecodeMetrics = .{};
        const parsed = try decodeWithMetricsAlloc(a, bytes, "entry", .supplemental, null, &metrics);
        const actual = switch (location) {
            0 => parsed.entry.display_title[0],
            1 => parsed.entry.sections[0].blocks[0].spans[0],
            2 => parsed.entry.sections[0].blocks[0].table.?.caption[0],
            3 => parsed.entry.sections[0].blocks[0].table.?.rows[0].cells[0].spans[0],
            4 => parsed.entry.references[0].spans[0],
            else => parsed.entry.preamble_spans[0],
        };
        try std.testing.expectEqualStrings(note, actual.explanation);
        try std.testing.expectEqualStrings("f", actual.text);
        try std.testing.expectEqualStrings("glossary", actual.target);
        try std.testing.expect(actual.italic and actual.kind == .link);
        try std.testing.expectEqual(note.len, metrics.largest_string_bytes);
        const built = try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media);
        if (location != 5) try std.testing.expectEqualStrings(bytes, built) else try std.testing.expectEqualStrings(magic, built[0..4]);
        const at = std.mem.indexOf(u8, bytes, note).?;
        const invalid = try a.dupe(u8, bytes);
        invalid[at] = 0xff;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, invalid, "entry", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. at + note.len - 1], "entry", .supplemental, null));
        const oversized = try a.dupe(u8, bytes);
        std.mem.writeInt(u32, oversized[at - 4 ..][0..4], max_string_bytes + 1, .little);
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, oversized, "entry", .supplemental, null));
        const unknown = try a.dupe(u8, bytes);
        unknown[3] = '9';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "entry", .supplemental, null));
    }
}

test "DPR4 RGB fields roundtrip every span container and preserve legacy table bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = "\x44\x50\x52\x32\x00\x00\x00\x00\x01\x00\x00\x00\x02\x06\x00\x00\x00\x63\x6f\x6c\x6f\x72\x73\x01\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x01\x00\x01\x00\x01\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\xc2\xa0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const old = try decodeAlloc(a, legacy, "colors", .supplemental, null);
    const old_cell = old.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
    try std.testing.expect(old_cell.background == null and old_cell.spans[0].foreground == null);
    try std.testing.expectEqualStrings(" ", old_cell.spans[0].text);
    try std.testing.expectEqualStrings(legacy, try encodeAlloc(a, old));
    try std.testing.expectEqualStrings(legacy, try encodeBuildAlloc(a, old.entry.display_title, old.entry.sections, old.entry.organization, old.entry.references, old.entry.media));
    const json = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"background\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"foreground\":null") != null);
    const note = "authored dialect explanation";
    const annotated = [_]types.Span{.{ .kind = .link, .text = "dialect", .target = "A", .foreground = "#1c39bb", .explanation = note, .italic = true }};
    const ordinary = [_]types.Span{.{ .text = "plain" }};
    for (0..7) |location| {
        const cells = [_]types.Cell{ .{ .spans = if (location == 3) &annotated else &ordinary, .background = if (location == 6) "#eeeeee" else null }, .{ .spans = &ordinary } };
        const rows = [_]types.Row{.{ .cells = &cells }};
        const table: types.Table = .{ .caption = if (location == 2) &annotated else &ordinary, .rows = &rows };
        const blocks = [_]types.Block{.{ .kind = .table, .spans = if (location == 1) &annotated else &ordinary, .table = table }};
        const sections = [_]types.Section{.{ .level = 2, .title = "colors", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 4) &annotated else &ordinary }};
        const stored: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = if (location == 0) &annotated else &ordinary, .sections = &sections, .preamble_spans = if (location == 5) &annotated else &ordinary, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(color_magic, bytes[0..4]);
        // The archived reader recognizes only DPR2/DPR3, so this new record
        // cannot silently enter its old cell/span decoder.
        try std.testing.expect(!std.mem.eql(u8, bytes[0..4], magic) and !std.mem.eql(u8, bytes[0..4], explained_magic));
        var metrics: DecodeMetrics = .{};
        const parsed = try decodeWithMetricsAlloc(a, bytes, "colors", .supplemental, null, &metrics);
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, parsed, .{}));
        try std.testing.expect(parsed.entry.sections[0].blocks[0].table.?.rows[0].cells[1].background == null);
        try std.testing.expect(parsed.entry.sections[0].blocks[0].table.?.rows[0].cells[1].spans[0].foreground == null);
        try std.testing.expectEqualStrings(bytes, try encodeAlloc(a, parsed));
        const built = try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media);
        const built_parsed = try decodeAlloc(a, built, "colors", .supplemental, null);
        var built_expected = stored;
        built_expected.entry.preamble_spans = &.{};
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, built_expected, .{}), try std.json.Stringify.valueAlloc(a, built_parsed, .{}));
        try std.testing.expectEqualStrings(if (location == 5) magic else color_magic, built[0..4]);

        const selected = if (location == 6) "#eeeeee" else "#1c39bb";
        const at = std.mem.indexOf(u8, bytes, selected).?;
        const corrupt = try a.dupe(u8, bytes);
        corrupt[at + 1] = 'G';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, corrupt, "colors", .supplemental, null));
        const bad_presence = try a.dupe(u8, bytes);
        bad_presence[at - 5] = 2;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bad_presence, "colors", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. bytes.len - 1], "colors", .supplemental, null));
        const unknown = try a.dupe(u8, bytes);
        unknown[3] = '9';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "colors", .supplemental, null));
    }
    const invalid = [_]types.Span{.{ .text = "invalid", .foreground = "red" }};
    const invalid_stored: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = &invalid } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, invalid_stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(invalid_stored, "colors", .supplemental, null));
}

test "DPR5 preserves section and standalone heading anchors with rich fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = [_]types.Block{
        .{ .kind = .heading, .level = 3, .anchor = "Usage_notes_2", .anchor_fallback = "Usage.20notes_2", .spans = &.{.{ .text = "Usage notes", .explanation = "note", .foreground = "#123abc" }} },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "body" }} },
        .{ .kind = .table, .table = .{ .rows = &.{.{ .cells = &.{.{ .background = "#abcdef", .spans = &.{.{ .text = "cell", .foreground = "#123abc" }} }} }} } },
    };
    const sections = [_]types.Section{.{ .level = 2, .title = "English", .anchor = "English_2", .anchor_fallback = "English.202", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "test", .kind = .supplemental, .sections = &sections } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(anchor_magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("English_2", decoded.entry.sections[0].anchor);
    const heading = decoded.entry.sections[0].blocks[0];
    try std.testing.expectEqualStrings("Usage_notes_2", heading.anchor);
    try std.testing.expectEqualStrings("Usage.20notes_2", heading.anchor_fallback);
    try std.testing.expectEqualStrings("English.202", decoded.entry.sections[0].anchor_fallback);
    try std.testing.expectEqualStrings("note", heading.spans[0].explanation);
    try std.testing.expectEqualStrings("#123abc", heading.spans[0].foreground.?);
    try std.testing.expectEqualStrings("", decoded.entry.sections[0].blocks[1].anchor);
    const cell = decoded.entry.sections[0].blocks[2].table.?.rows[0].cells[0];
    try std.testing.expectEqualStrings("#abcdef", cell.background.?);
    try std.testing.expectEqualStrings("#123abc", cell.spans[0].foreground.?);
    const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor\":\"English_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor\":\"Usage_notes_2\"") != null);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const built = try encodeBuildAlloc(a, stored.entry.display_title, &sections, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualSlices(u8, bytes, built);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor_fallback\":\"English.202\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anchor_fallback\":\"Usage.20notes_2\"") != null);
    const malformed_fallback = try a.dupe(u8, bytes);
    malformed_fallback[std.mem.indexOf(u8, malformed_fallback, "Usage.20notes_2").?] = 0xff;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, malformed_fallback, "test", .supplemental, null));
    const FallbackSection = struct { level: u8, title: []const u8, anchor_fallback: []const u8, blocks: []const types.Block = &.{} };
    const fallback_sections = [_]FallbackSection{.{ .level = 2, .title = "English", .anchor_fallback = "English.202" }};
    const fallback_bytes = try encodeBuildAlloc(a, stored.entry.display_title, &fallback_sections, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualStrings(anchor_magic, fallback_bytes[0..4]);
    const fallback_decoded = try decodeAlloc(a, fallback_bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("", fallback_decoded.entry.sections[0].anchor);
    try std.testing.expectEqualStrings("English.202", fallback_decoded.entry.sections[0].anchor_fallback);
    const malformed = try a.dupe(u8, bytes);
    const anchor_offset = std.mem.indexOf(u8, malformed, "English_2").?;
    malformed[anchor_offset] = 0xff;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, malformed, "test", .supplemental, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. bytes.len - 1], "test", .supplemental, null));
    const standalone = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &blocks }};
    const standalone_bytes = try encodeBuildAlloc(a, stored.entry.display_title, &standalone, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualStrings(anchor_magic, standalone_bytes[0..4]);
    const fallback_blocks = [_]types.Block{.{ .kind = .heading, .anchor_fallback = "Usage.20notes" }};
    const fallback_block_sections = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &fallback_blocks }};
    const fallback_block_bytes = try encodeBuildAlloc(a, stored.entry.display_title, &fallback_block_sections, stored.entry.organization, stored.entry.references, stored.entry.media);
    try std.testing.expectEqualStrings(anchor_magic, fallback_block_bytes[0..4]);
    const fallback_block_decoded = try decodeAlloc(a, fallback_block_bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("Usage.20notes", fallback_block_decoded.entry.sections[0].blocks[0].anchor_fallback);
    const invalid_blocks = [_]types.Block{.{ .kind = .paragraph, .anchor_fallback = "invalid" }};
    const invalid_sections = [_]types.Section{.{ .level = 2, .title = "English", .blocks = &invalid_blocks }};
    try std.testing.expectError(error.InvalidPresentation, encodeBuildAlloc(a, stored.entry.display_title, &invalid_sections, stored.entry.organization, stored.entry.references, stored.entry.media));
}

test "legacy generic sections without anchors retain DPR2 and decode empty anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const LegacySection = struct { level: u8, title: []const u8, blocks: []const types.Block = &.{} };
    const sections = [_]LegacySection{.{ .level = 2, .title = "English" }};
    const bytes = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, @as(types.Layout, .{}), @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualStrings(magic, bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "test", .supplemental, null);
    try std.testing.expectEqualStrings("", decoded.entry.sections[0].anchor);
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
}

test "DPR6 span backgrounds roundtrip every container with anchors and legacy fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const painted = [_]types.Span{.{ .kind = .link, .text = "painted", .target = "Target", .trail = "s", .background = "#123456", .foreground = "#654321", .explanation = "note", .italic = true }};
    const ordinary = [_]types.Span{.{ .text = "plain" }};
    for (0..6) |location| {
        const cells = [_]types.Cell{
            .{ .spans = if (location == 3) &painted else &ordinary, .background = "#eeeeee" },
            .{ .spans = &ordinary },
        };
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{
            .{ .kind = .heading, .level = 3, .anchor = "Heading_2", .anchor_fallback = "Heading.202", .spans = if (location == 1) &painted else &ordinary },
            .{ .kind = .table, .table = .{ .caption = if (location == 2) &painted else &ordinary, .rows = &rows } },
        };
        const sections = [_]types.Section{.{ .level = 2, .title = "colors", .anchor = "colors", .blocks = &blocks }};
        const refs = [_]types.Reference{.{ .number = 1, .group_number = 1, .spans = if (location == 4) &painted else &ordinary }};
        const stored: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = if (location == 0) &painted else &ordinary, .sections = &sections, .preamble_spans = if (location == 5) &painted else &ordinary, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings(background_magic, bytes[0..4]);
        const parsed = try decodeAlloc(a, bytes, "colors", .supplemental, null);
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, parsed, .{}));
        try std.testing.expectEqualStrings("colors", parsed.entry.sections[0].anchor);
        try std.testing.expectEqualStrings("Heading_2", parsed.entry.sections[0].blocks[0].anchor);
        try std.testing.expectEqualStrings("Heading.202", parsed.entry.sections[0].blocks[0].anchor_fallback);
        try std.testing.expectEqualStrings("#eeeeee", parsed.entry.sections[0].blocks[1].table.?.rows[0].cells[0].background.?);
        try std.testing.expect(parsed.entry.sections[0].blocks[1].table.?.rows[0].cells[1].spans[0].background == null);
        try std.testing.expectEqualStrings(bytes, try encodeAlloc(a, parsed));
        const built = try encodeBuildAlloc(a, stored.entry.display_title, stored.entry.sections, stored.entry.organization, stored.entry.references, stored.entry.media);
        try std.testing.expectEqualStrings(if (location == 5) anchor_magic else background_magic, built[0..4]);
        const built_parsed = try decodeAlloc(a, built, "colors", .supplemental, null);
        var expected = stored;
        expected.entry.preamble_spans = &.{};
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, expected, .{}), try std.json.Stringify.valueAlloc(a, built_parsed, .{}));
        const at = std.mem.indexOf(u8, bytes, "#123456").?;
        const corrupt = try a.dupe(u8, bytes);
        corrupt[at + 1] = 'G';
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, corrupt, "colors", .supplemental, null));
        const presence = try a.dupe(u8, bytes);
        presence[at - 5] = 2;
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, presence, "colors", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, bytes[0 .. at + 3], "colors", .supplemental, null));
    }
    const invalid = [_]types.Span{.{ .text = "invalid", .background = "red" }};
    const bad: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = &invalid } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, bad));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(bad, "colors", .supplemental, null));
    // Independently framed eight minimal DPR6 spans are exactly 33 bytes each.
    var minimal: [4 + 4 + 8 * 33 + 6 * 4]u8 = @splat(0);
    @memcpy(minimal[0..4], background_magic);
    minimal[4] = 8;
    const compact = try decodeAlloc(a, &minimal, "colors", .supplemental, null);
    try std.testing.expectEqual(@as(usize, 8), compact.entry.display_title.len);
    for (compact.entry.display_title) |span| try std.testing.expect(span.background == null);
}

test "absent span backgrounds preserve established JSON and legacy selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const span: types.Span = .{ .text = "plain" };
    const legacy_json = "{\"kind\":\"text\",\"text\":\"plain\",\"target\":\"\",\"trail\":\"\",\"language\":\"\",\"classes\":\"\",\"direction\":\"\",\"explanation\":\"\",\"foreground\":null,\"bold\":false,\"italic\":false,\"code\":false,\"small\":false,\"superscript\":false,\"subscript\":false,\"strike\":false,\"underline\":false,\"role\":\"normal\"}";
    try std.testing.expectEqualStrings(legacy_json, try std.json.Stringify.valueAlloc(a, span, .{}));
    var annotated = span;
    annotated.background = "#abcdef";
    const json = try std.json.Stringify.valueAlloc(a, annotated, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"background\":\"#abcdef\"") != null);
    const values = [_]types.Span{span};
    const plain: types.Stored = .{ .entry = .{ .title = "colors", .kind = .supplemental, .display_title = &values } };
    const bytes = try encodeAlloc(a, plain);
    try std.testing.expectEqualStrings(magic, bytes[0..4]);
    const parsed = try decodeAlloc(a, bytes, "colors", .supplemental, null);
    try std.testing.expect(parsed.entry.display_title[0].background == null);
    try std.testing.expectEqualStrings(bytes, try encodeAlloc(a, parsed));
}

// Offsource nested-grid controls. These have not been executed during preparation.
test "DPR7 nested empty painted header and authored zero geometry round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child_cells = [_]types.Cell{
        .{ .header = true, .background = "#efafef" },
        .{ .spans = &.{.{ .kind = .link, .text = "form", .target = "acan", .explanation = "source action", .background = "#efefef" }} },
    };
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const outer_cells = [_]types.Cell{.{ .nested_table = .{
        .rows = &child_rows,
        .geometry = .{ .border = 1, .cell_padding = 2, .width = .{ .unit = .percent, .value = 100 } },
    } }};
    const outer_rows = [_]types.Row{.{ .cells = &outer_cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{
        .rows = &outer_rows,
        .geometry = .{ .border = 0, .cell_spacing = 15 },
    } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Unclassified", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "nested", .kind = .language, .language = "Unclassified", .sections = &sections } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(nested_magic, encoded[0..4]);
    var metrics: DecodeMetrics = .{};
    const decoded = try decodeWithMetricsAlloc(a, encoded, "nested", .language, .{ .code = "", .heading = "Unclassified" }, &metrics);
    const outer = decoded.entry.sections[0].blocks[0].table.?;
    try std.testing.expectEqual(@as(?u16, 0), outer.geometry.?.border);
    try std.testing.expectEqual(@as(?u16, 15), outer.geometry.?.cell_spacing);
    try std.testing.expect(outer.geometry.?.cell_padding == null);
    try std.testing.expectEqual(@as(usize, 0), outer.rows[0].cells[0].spans.len);
    const child = outer.rows[0].cells[0].nested_table.?;
    try std.testing.expectEqual(@as(?u16, 1), child.geometry.?.border);
    try std.testing.expectEqual(@as(?u16, 2), child.geometry.?.cell_padding);
    try std.testing.expectEqual(types.TableWidthUnit.percent, child.geometry.?.width.?.unit);
    try std.testing.expectEqual(@as(u32, 100), child.geometry.?.width.?.value);
    try std.testing.expect(child.rows[0].cells[0].header);
    try std.testing.expectEqual(@as(usize, 0), child.rows[0].cells[0].spans.len);
    try std.testing.expectEqualStrings("#efafef", child.rows[0].cells[0].background.?);
    try std.testing.expectEqualStrings("acan", child.rows[0].cells[1].spans[0].target);
    try std.testing.expectEqualStrings("source action", child.rows[0].cells[1].spans[0].explanation);
    try std.testing.expectEqualStrings("#efefef", child.rows[0].cells[1].spans[0].background.?);
    try std.testing.expectEqual(@as(usize, 2), metrics.tables);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
}

test "legacy flat cell and table JSON omit all extension fields" {
    const a = std.testing.allocator;
    const cell_json = try std.json.Stringify.valueAlloc(a, types.Cell{}, .{});
    defer a.free(cell_json);
    try std.testing.expectEqualStrings("{\"spans\":[],\"header\":false,\"colspan\":1,\"rowspan\":1,\"background\":null}", cell_json);
    const table_json = try std.json.Stringify.valueAlloc(a, types.Table{}, .{});
    defer a.free(table_json);
    try std.testing.expectEqualStrings("{\"caption\":[],\"rows\":[]}", table_json);
}

test "DPR7 rejects mixed nested spans invalid geometry and excess table depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [17][1]types.Cell = undefined;
    var rows: [17][1]types.Row = undefined;
    var tables: [17]types.Table = undefined;
    var i: usize = 17;
    while (i != 0) {
        i -= 1;
        cells[i] = .{.{ .nested_table = if (i + 1 < tables.len) tables[i + 1] else null }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .rows = &rows[i] };
    }
    var blocks = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const sections = [_]types.Section{.{ .level = 2, .title = "U", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .language, .language = "U", .sections = &sections } };
    const sixteen = try encodeAlloc(a, stored);
    _ = try decodeAlloc(a, sixteen, "depth", .language, .{ .code = "", .heading = "U" });
    blocks[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    blocks[0].table = .{ .geometry = .{ .width = .{ .unit = .percent, .value = 101 } } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    const mixed_cells = [_]types.Cell{.{ .spans = &.{.{ .text = "must not disappear" }}, .nested_table = .{} }};
    const mixed_rows = [_]types.Row{.{ .cells = &mixed_cells }};
    blocks[0].table = .{ .rows = &mixed_rows };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
}

test "DPR7 collection counts share one item budget" {
    var encoder: Encoder = .{ .a = std.testing.allocator, .version = .nested_tables, .remaining_items = 1 };
    defer encoder.deinit();
    try encoder.count(1);
    try std.testing.expectError(error.PresentationTooLarge, encoder.count(1));
    var reader: Reader = .{ .a = std.testing.allocator, .version = .nested_tables, .bytes = &.{ 1, 0, 0, 0, 1, 0, 0, 0 }, .remaining_items = 1 };
    try std.testing.expectEqual(@as(usize, 1), try reader.count(0));
    try std.testing.expectError(error.InvalidPresentation, reader.count(0));
}

test "DPR8 ordered cell blocks retain headings actions paint and nested metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child_cells = [_]types.Cell{.{ .spans = &.{.{ .kind = .link, .text = "inner", .target = "Inner", .trail = "s", .background = "#ffffe0" }} }};
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const contents = [_]types.Block{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "before" }} },
        .{ .kind = .heading, .level = 3, .anchor = "翻訳_2", .anchor_fallback = ".E7.BF.BB.E8.A8.B3_2", .spans = &.{.{ .text = "翻訳", .bold = true }} },
        .{ .kind = .list_item, .depth = 2, .list_path = "*#", .number = "2", .spans = &.{.{ .kind = .link, .text = "item", .target = "Item", .explanation = "retained action" }} },
        .{ .kind = .rule },
        .{ .kind = .table, .table = .{ .rows = &child_rows, .geometry = .{ .width = .{ .unit = .percent, .value = 50 } } } },
        .{ .kind = .paragraph, .feature = .{ .kind = "tail", .data = "compiled" }, .spans = &.{.{ .text = "after", .foreground = "#123456" }} },
    };
    const cells = [_]types.Cell{
        .{ .header = true, .background = "#fffdd0", .blocks = &contents },
        .{ .blocks = &.{} },
        .{ .spans = &.{.{ .text = "legacy neighbor" }} },
    };
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "English", .anchor = "English", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "ordered", .kind = .supplemental, .sections = &sections } };
    const encoded = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(cell_blocks_magic, encoded[0..4]);
    var metrics: DecodeMetrics = .{};
    const decoded = try decodeWithMetricsAlloc(a, encoded, "ordered", .supplemental, null, &metrics);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqual(@as(usize, 2), metrics.tables);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
    const decoded_cells = decoded.entry.sections[0].blocks[0].table.?.rows[0].cells;
    try std.testing.expectEqual(@as(usize, 6), decoded_cells[0].blocks.?.len);
    try std.testing.expectEqual(@as(u8, 3), decoded_cells[0].blocks.?[1].level);
    try std.testing.expectEqualStrings("翻訳_2", decoded_cells[0].blocks.?[1].anchor);
    try std.testing.expectEqual(@as(usize, 0), decoded_cells[1].blocks.?.len);
    try std.testing.expect(decoded_cells[2].blocks == null);
    try std.testing.expectEqualSlices(u8, encoded, try encodeAlloc(a, decoded));
    try std.testing.expectEqualSlices(u8, encoded, try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, stored.entry.organization, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{})));
    const json = try std.json.Stringify.valueAlloc(a, types.Cell{ .blocks = &.{} }, .{});
    try std.testing.expectEqualStrings("{\"spans\":[],\"header\":false,\"colspan\":1,\"rowspan\":1,\"background\":null,\"blocks\":[]}", json);
}

test "DPR8 presence and empty content preserve legacy cell framing" {
    const a = std.testing.allocator;
    const legacy = [_]u8{ 0, 1, 0, 1, 0, 0, 0, 0, 0 };
    for ([_]Version{ .plain, .explained, .colored, .anchored, .span_background, .nested_tables }) |version| {
        var encoder: Encoder = .{ .a = a, .version = version };
        defer encoder.deinit();
        try encoder.cell(types.Cell{});
        try std.testing.expectEqual(@as(usize, if (version == .nested_tables) 11 else if (hasRgb(version)) 10 else 9), encoder.out.items.len);
        try std.testing.expectEqualSlices(u8, &legacy, encoder.out.items[0..9]);
        for (encoder.out.items[9..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
    var encoder: Encoder = .{ .a = a, .version = .cell_blocks };
    defer encoder.deinit();
    try encoder.cell(types.Cell{ .blocks = &.{} });
    const present_empty = [_]u8{ 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &present_empty, encoder.out.items);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader: Reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = &present_empty };
    try std.testing.expectEqual(@as(usize, 0), (try reader.cell()).blocks.?.len);
    var invalid = present_empty;
    invalid[11] = 2;
    reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = &invalid };
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
    reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = present_empty[0..15] };
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
    // A present block vector cannot claim a 25-byte block from an empty tail.
    invalid = present_empty;
    invalid[12] = 1;
    reader = .{ .a = arena.allocator(), .version = .cell_blocks, .bytes = &invalid };
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
}

test "DPR8 rejects mixed cell modes and validates nested semantic colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells = [_]types.Cell{.{ .blocks = &.{}, .spans = &.{.{ .text = "preserve me" }} }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "U", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "modes", .kind = .supplemental, .sections = &sections } };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(stored, "modes", .supplemental, null));
    cells[0] = .{ .blocks = &.{}, .nested_table = .{} };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(stored, "modes", .supplemental, null));
    cells[0] = .{ .blocks = &.{.{ .kind = .heading, .level = 3, .anchor = "Color", .spans = &.{.{ .text = "color", .background = "red" }} }} };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(stored, "modes", .supplemental, null));
    cells[0] = .{ .blocks = &.{.{ .kind = .paragraph, .anchor = "not a heading" }} };
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(stored, "modes", .supplemental, null));
}

test "DPR8 cell block tables retain depth and shared collection limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells: [17][1]types.Cell = undefined;
    var rows: [17][1]types.Row = undefined;
    var tables: [17]types.Table = undefined;
    var contents: [17][1]types.Block = undefined;
    var i: usize = 17;
    while (i != 0) {
        i -= 1;
        contents[i] = .{.{ .kind = .table, .table = if (i + 1 < tables.len) tables[i + 1] else null }};
        cells[i] = .{.{ .blocks = &contents[i] }};
        rows[i] = .{.{ .cells = &cells[i] }};
        tables[i] = .{ .rows = &rows[i] };
    }
    var blocks = [_]types.Block{.{ .kind = .table, .table = tables[1] }};
    const sections = [_]types.Section{.{ .level = 2, .title = "U", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "depth", .kind = .supplemental, .sections = &sections } };
    const sixteen = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings(cell_blocks_magic, sixteen[0..4]);
    var metrics: DecodeMetrics = .{};
    _ = try decodeWithMetricsAlloc(a, sixteen, "depth", .supplemental, null, &metrics);
    try std.testing.expectEqual(@as(usize, 16), metrics.tables);
    // Starting inside an enclosing table must not reset depth at a cell Block.table.
    var nested_encoder: Encoder = .{ .a = a, .version = .cell_blocks };
    defer nested_encoder.deinit();
    try nested_encoder.table(@as(?types.Table, tables[15]));
    var nested_reader: Reader = .{ .a = a, .version = .cell_blocks, .bytes = nested_encoder.out.items, .table_depth = 14 };
    _ = try nested_reader.table();
    nested_reader = .{ .a = a, .version = .cell_blocks, .bytes = nested_encoder.out.items, .table_depth = 15 };
    try std.testing.expectError(error.InvalidPresentation, nested_reader.table());
    blocks[0].table = tables[0];
    try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, stored));
    try std.testing.expectError(error.InvalidPresentation, types.validateStored(stored, "depth", .supplemental, null));
    var encoder: Encoder = .{ .a = a, .version = .cell_blocks, .remaining_items = 1 };
    defer encoder.deinit();
    try encoder.cell(types.Cell{ .blocks = &.{.{ .kind = .paragraph }} });
    const first = try a.dupe(u8, encoder.out.items);
    try std.testing.expectError(error.PresentationTooLarge, encoder.cell(types.Cell{ .blocks = &.{.{ .kind = .paragraph }} }));
    const two_cells = try std.mem.concat(a, u8, &.{ first, first });
    var reader: Reader = .{ .a = a, .version = .cell_blocks, .bytes = two_cells, .remaining_items = 1 };
    _ = try reader.cell();
    try std.testing.expectError(error.InvalidPresentation, reader.cell());
    // The old per-string bound is unchanged in the new version.
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, max_string_bytes + 1, .little);
    reader = .{ .a = a, .version = .cell_blocks, .bytes = &length };
    try std.testing.expectError(error.InvalidPresentation, reader.string());
}

test "DPR9 reference fragments preserve footer order identities groups and rich bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rich = [_]types.Span{.{ .kind = .external_link, .text = "orphan", .target = "https://example.test/fragment", .bold = true, .explanation = "source note", .foreground = "#123456", .background = "#abcdef" }};
    const refs = [_]types.Reference{
        .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &rich },
        .{ .number = 2, .group_number = 1, .name = "parent", .group = "notes", .spans = &.{.{ .text = "numbered" }} },
    };
    const child = [_]types.Block{.{ .kind = .heading, .level = 3, .anchor = "child", .spans = &.{.{ .text = "Child" }} }};
    const cells = [_]types.Cell{.{ .blocks = &child }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Body", .anchor = "body", .blocks = &blocks }};
    const media = [_]types.Media{.{ .file = "Example.svg", .kind = .image, .caption = "caption" }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .sections = &sections, .references = &refs, .media = &media } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPR9", bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "entry", .supplemental, null);
    try std.testing.expectEqual(types.ReferenceKind.fragment, decoded.entry.references[0].kind);
    try std.testing.expectEqual(@as(usize, 8), decoded.entry.references[0].number);
    try std.testing.expectEqual(@as(?u32, null), decoded.entry.references[0].group_number);
    try std.testing.expectEqualStrings("", decoded.entry.references[0].name);
    try std.testing.expectEqualStrings("notes", decoded.entry.references[0].group);
    try std.testing.expectEqual(@as(usize, 2), decoded.entry.references[1].number);
    try std.testing.expectEqual(@as(?u32, 1), decoded.entry.references[1].group_number);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    // The compiler path uses a distinct enum type with the same semantic names.
    const BuildKind = enum { note, fragment };
    const BuildReference = struct { kind: BuildKind = .note, number: usize, group_number: ?u32, name: []const u8 = "", group: []const u8 = "", spans: []const types.Span = &.{} };
    const build_refs = [_]BuildReference{.{ .kind = .fragment, .number = 7, .group_number = null, .spans = &rich }};
    const built = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), @as([]const types.Section, &.{}), types.Layout{}, &build_refs, @as([]const types.Media, &.{}));
    const build_decoded = try decodeAlloc(a, built, "entry", .supplemental, null);
    try std.testing.expectEqual(@as(usize, 7), build_decoded.entry.references[0].number);
    try std.testing.expectEqualStrings("https://example.test/fragment", build_decoded.entry.references[0].spans[0].target);
}

test "legacy note reference bytes and JSON stay unchanged without fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = [_]types.Reference{.{ .number = 9, .group_number = 2 }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .references = &refs } };
    // Independent legacy framing: five empty collections, one note, empty media.
    const legacy = "DPR2" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x01\x00\x00\x00\x09\x00\x00\x00\x02\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectEqualSlices(u8, legacy, try encodeAlloc(a, stored));
    const decoded = try decodeAlloc(a, legacy, "entry", .supplemental, null);
    try std.testing.expectEqual(types.ReferenceKind.note, decoded.entry.references[0].kind);
    try std.testing.expectEqualStrings("{\"number\":9,\"group_number\":2,\"name\":\"\",\"group\":\"\",\"spans\":[]}", try std.json.Stringify.valueAlloc(a, decoded.entry.references[0], .{}));
    try std.testing.expectEqualSlices(u8, legacy, try encodeAlloc(a, decoded));
}

test "DPR9 reference tags and semantic invariants reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = [_]types.Reference{.{ .kind = .fragment, .number = 1, .group_number = null }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .references = &refs } };
    const valid = try encodeAlloc(a, stored);
    // The first item follows magic, five empty collection counts and ref count.
    const tag_at = 28;
    try std.testing.expectEqual(@as(u8, 1), valid[tag_at]);
    const unknown = try a.dupe(u8, valid);
    unknown[tag_at] = 2;
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, unknown, "entry", .supplemental, null));
    const zero_id = try a.dupe(u8, valid);
    @memset(zero_id[tag_at + 1 .. tag_at + 5], 0);
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, zero_id, "entry", .supplemental, null));
    try std.testing.expectError(error.InvalidPresentation, decodeAlloc(a, valid[0 .. valid.len - 1], "entry", .supplemental, null));
    const invalid = [_]types.Reference{
        .{ .number = 1, .group_number = null },
        .{ .number = 1, .group_number = 0 },
        .{ .kind = .fragment, .number = 0, .group_number = null },
        .{ .kind = .fragment, .number = 1, .group_number = 1 },
        .{ .kind = .fragment, .number = 1, .group_number = null, .name = "named" },
    };
    for (invalid) |reference| {
        var bad = stored;
        bad.entry.references = &.{reference};
        try std.testing.expectError(error.InvalidPresentation, types.validateStored(bad, "entry", .supplemental, null));
        try std.testing.expectError(error.InvalidPresentation, encodeAlloc(a, bad));
    }
    // Encoder selection is canonical, but a valid note-only DPR9 remains readable.
    var encoder: Encoder = .{ .a = a, .version = .reference_items };
    defer encoder.deinit();
    try encoder.out.appendSlice(a, reference_items_magic);
    for (0..5) |_| try encoder.count(0);
    try encoder.references(&[_]types.Reference{.{ .number = 4, .group_number = 2 }});
    try encoder.media(@as([]const types.Media, &.{}));
    const notes = try decodeAlloc(a, encoder.out.items, "entry", .supplemental, null);
    try std.testing.expectEqual(types.ReferenceKind.note, notes.entry.references[0].kind);
    try std.testing.expectEqual(@as(usize, 4), notes.entry.references[0].number);
}

test "DPRA preserves ARchar scale and all DPR9 reference and ordered cell fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rich = [_]types.Span{.{ .kind = .link, .text = "سبتمبر", .target = "سبتمبر", .classes = "AR", .font_scale = 1.25, .small = true, .superscript = true, .subscript = true, .background = "#abcdef" }};
    const refs = [_]types.Reference{
        .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &rich },
        .{ .number = 2, .group_number = 1, .name = "parent", .group = "notes", .spans = &rich },
    };
    const child = [_]types.Block{.{ .kind = .heading, .level = 3, .anchor = "child", .spans = &rich }};
    const cells = [_]types.Cell{.{ .blocks = &child }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .caption = &rich, .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Body", .anchor = "body", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .display_title = &rich, .preamble_spans = &rich, .sections = &sections, .references = &refs } };
    const bytes = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPRA", bytes[0..4]);
    const decoded = try decodeAlloc(a, bytes, "entry", .supplemental, null);
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, stored, .{}), try std.json.Stringify.valueAlloc(a, decoded, .{}));
    try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
    const built = try encodeBuildAlloc(a, &rich, &sections, types.Layout{}, &refs, @as([]const types.Media, &.{}));
    const build_decoded = try decodeAlloc(a, built, "entry", .supplemental, null);
    try std.testing.expectEqual(@as(?f32, 1.25), build_decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].blocks.?[0].spans[0].font_scale);
}

test "font scale selection recurses into nested tables and canonical identity retains legacy bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spans = [_]types.Span{.{ .text = "sized", .font_scale = 1 }};
    const child_cells = [_]types.Cell{.{ .spans = &spans }};
    const child_rows = [_]types.Row{.{ .cells = &child_cells }};
    const cells = [_]types.Cell{.{ .nested_table = .{ .rows = &child_rows } }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Body", .blocks = &blocks }};
    const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .sections = &sections } };
    const identity = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPR7", identity[0..4]);
    spans[0].font_scale = null;
    try std.testing.expectEqualSlices(u8, identity, try encodeAlloc(a, stored));
    spans[0].font_scale = 0;
    const zero = try encodeAlloc(a, stored);
    try std.testing.expectEqualStrings("DPRA", zero[0..4]);
    const decoded = try decodeAlloc(a, zero, "entry", .supplemental, null);
    try std.testing.expectEqual(@as(?f32, 0), decoded.entry.sections[0].blocks[0].table.?.rows[0].cells[0].nested_table.?.rows[0].cells[0].spans[0].font_scale);
    const built = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
    try std.testing.expectEqualStrings("DPRA", built[0..4]);
}

test "font scale codec rejects malformed numeric fields without rejecting valid zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        var encoder: Encoder = .{ .a = a, .version = .font_scale };
        defer encoder.deinit();
        try std.testing.expectError(error.InvalidPresentation, encoder.span(types.Span{ .font_scale = invalid }));
    }
    var encoder: Encoder = .{ .a = a, .version = .font_scale };
    defer encoder.deinit();
    try encoder.span(types.Span{ .font_scale = 1.25 });
    const encoded = encoder.out.items;
    var truncated: Reader = .{ .a = a, .version = .font_scale, .bytes = encoded[0 .. encoded.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, truncated.span());
    const bad = try a.dupe(u8, encoded);
    std.mem.writeInt(u32, bad[bad.len - 4 ..][0..4], @bitCast(std.math.inf(f32)), .little);
    var nonfinite: Reader = .{ .a = a, .version = .font_scale, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, nonfinite.span());
}

test "DPRB body identity and zero retain references ordered cells and nested selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f32{ 1, 0, 1.25 }) |number| {
        const rich = [_]types.Span{.{ .kind = .link, .text = "body", .target = "Target", .font_scale = number, .font_scale_basis = .normal_body, .small = true, .superscript = true, .subscript = true, .background = "#abcdef" }};
        const refs = [_]types.Reference{
            .{ .kind = .fragment, .number = 8, .group_number = null, .group = "notes", .spans = &rich },
            .{ .number = 2, .group_number = 1, .name = "parent", .group = "notes", .spans = &rich },
        };
        const nested_cells = [_]types.Cell{.{ .spans = &rich }};
        const nested_rows = [_]types.Row{.{ .cells = &nested_cells }};
        const child = [_]types.Block{.{ .kind = .heading, .level = 3, .anchor = "child", .spans = &rich }};
        const cells = [_]types.Cell{ .{ .blocks = &child }, .{ .nested_table = .{ .rows = &nested_rows } } };
        const rows = [_]types.Row{.{ .cells = &cells }};
        const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .caption = &rich, .rows = &rows } }};
        const sections = [_]types.Section{.{ .level = 2, .title = "Body", .anchor = "body", .blocks = &blocks }};
        const stored: types.Stored = .{ .entry = .{ .title = "entry", .kind = .supplemental, .display_title = &rich, .preamble_spans = &rich, .sections = &sections, .references = &refs } };
        const bytes = try encodeAlloc(a, stored);
        try std.testing.expectEqualStrings("DPRB", bytes[0..4]);
        const decoded = try decodeAlloc(a, bytes, "entry", .supplemental, null);
        try std.testing.expectEqualDeep(stored, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encodeAlloc(a, decoded));
        const built = try encodeBuildAlloc(a, &rich, &sections, types.Layout{}, &refs, @as([]const types.Media, &.{}));
        try std.testing.expectEqualStrings("DPRB", built[0..4]);
        const build_decoded = try decodeAlloc(a, built, "entry", .supplemental, null);
        try std.testing.expectEqualDeep(sections[0], build_decoded.entry.sections[0]);
        const nested_only = try encodeBuildAlloc(a, @as([]const types.Span, &.{}), &sections, types.Layout{}, @as([]const types.Reference, &.{}), @as([]const types.Media, &.{}));
        try std.testing.expectEqualStrings("DPRB", nested_only[0..4]);
        const json = try std.json.Stringify.valueAlloc(a, rich[0], .{});
        try std.testing.expect(std.mem.indexOf(u8, json, "\"font_scale_basis\":\"normal_body\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"font_scale\":") != null);
    }
}

test "context-only scale keeps exact DPRA span bytes and legacy identity JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder: Encoder = .{ .a = a, .version = .font_scale };
    defer encoder.deinit();
    try encoder.span(types.Span{ .font_scale = 1.25 });
    // Old DPRA empty span: 3 flags, 7 empty strings, two absent paints,
    // scale presence, then little-endian 1.25f. No basis byte is added.
    const absent_fields: [33]u8 = @splat(0);
    const old_bytes = absent_fields ++ [_]u8{ 1, 0, 0, 0xa0, 0x3f };
    try std.testing.expectEqualSlices(u8, &old_bytes, encoder.out.items);
    var reader: Reader = .{ .a = a, .version = .font_scale, .bytes = &old_bytes };
    const decoded = try reader.span();
    try std.testing.expectEqual(@as(?f32, 1.25), decoded.font_scale);
    try std.testing.expectEqual(types.FontScaleBasis.context, decoded.font_scale_basis);
    const plain_json = try std.json.Stringify.valueAlloc(a, types.Span{}, .{});
    const identity_json = try std.json.Stringify.valueAlloc(a, types.Span{ .font_scale = 1 }, .{});
    try std.testing.expectEqualStrings(plain_json, identity_json);
    try std.testing.expect(std.mem.indexOf(u8, plain_json, "font_scale") == null);
    const scaled_json = try std.json.Stringify.valueAlloc(a, decoded, .{});
    try std.testing.expect(std.mem.indexOf(u8, scaled_json, "font_scale_basis") == null);
}

test "DPRB count floor admits absent scales and rejects invalid basis pairs and bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var values: [64]types.Span = @splat(.{});
    values[63] = .{ .font_scale = 1, .font_scale_basis = .normal_body };
    var encoder: Encoder = .{ .a = a, .version = .font_scale_basis };
    defer encoder.deinit();
    try encoder.spans(&values);
    var reader: Reader = .{ .a = a, .version = .font_scale_basis, .bytes = encoder.out.items };
    try std.testing.expectEqualDeep(@as([]const types.Span, &values), try reader.spans());
    var invalid: Encoder = .{ .a = a, .version = .font_scale_basis };
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidPresentation, invalid.span(types.Span{ .font_scale_basis = .normal_body }));
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |number| {
        try std.testing.expectError(error.InvalidPresentation, invalid.span(types.Span{ .font_scale = number, .font_scale_basis = .normal_body }));
    }
    var single: Encoder = .{ .a = a, .version = .font_scale_basis };
    defer single.deinit();
    try single.span(types.Span{ .font_scale = 1, .font_scale_basis = .normal_body });
    const bad = try a.dupe(u8, single.out.items);
    bad[bad.len - 1] = 2;
    var unknown: Reader = .{ .a = a, .version = .font_scale_basis, .bytes = bad };
    try std.testing.expectError(error.InvalidPresentation, unknown.span());
    var truncated: Reader = .{ .a = a, .version = .font_scale_basis, .bytes = single.out.items[0 .. single.out.items.len - 1] };
    try std.testing.expectError(error.InvalidPresentation, truncated.span());
    var old: Encoder = .{ .a = a, .version = .font_scale };
    defer old.deinit();
    try std.testing.expectError(error.InvalidPresentation, old.span(types.Span{ .font_scale = 1, .font_scale_basis = .normal_body }));
}
