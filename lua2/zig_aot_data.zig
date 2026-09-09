const std = @import("std");

pub const magic = "ZAOTD001";
pub const header_size: usize = 40;
pub const record_size: usize = 24;

pub const Tag = enum(u8) {
    nil = 0,
    boolean = 1,
    number = 2,
    string = 3,
    table = 4,
};

pub const Table = struct {
    first: u32,
    count: u32,
    shape: u32,
};

pub const Constant = union(enum) {
    nil,
    boolean: bool,
    number_bits: u64,
    string: []const u8,
    table: Table,
};

pub const Layout = struct {
    constant_count: usize,
    entry_count: usize,
    string_bytes: usize,
    records_offset: usize = header_size,
    entries_offset: usize,
    strings_offset: usize,
    total: usize,
};
pub fn layout(constant_count: usize, entry_count: usize, string_bytes: usize) !Layout {
    if (constant_count > std.math.maxInt(u32) or entry_count > std.math.maxInt(u32))
        return error.ProgramDataTooLarge;
    const records_len = std.math.mul(usize, constant_count, record_size) catch return error.ProgramDataTooLarge;
    const entries_len = std.math.mul(usize, entry_count, @sizeOf(u64)) catch return error.ProgramDataTooLarge;
    const entries_offset = std.math.add(usize, header_size, records_len) catch return error.ProgramDataTooLarge;
    const strings_offset = std.math.add(usize, entries_offset, entries_len) catch return error.ProgramDataTooLarge;
    const total = std.math.add(usize, strings_offset, string_bytes) catch return error.ProgramDataTooLarge;
    return .{
        .constant_count = constant_count,
        .entry_count = entry_count,
        .string_bytes = string_bytes,
        .entries_offset = entries_offset,
        .strings_offset = strings_offset,
        .total = total,
    };
}

fn readU32(bytes: []const u8, at: usize) !u32 {
    if (at > bytes.len or bytes.len - at < 4) return error.TruncatedProgramData;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) !u64 {
    if (at > bytes.len or bytes.len - at < 8) return error.TruncatedProgramData;
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

pub fn writeU32(bytes: []u8, at: usize, value: u32) !void {
    if (at > bytes.len or bytes.len - at < 4) return error.TruncatedProgramData;
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

pub fn writeU64(bytes: []u8, at: usize, value: u64) !void {
    if (at > bytes.len or bytes.len - at < 8) return error.TruncatedProgramData;
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}
pub fn writeHeader(bytes: []u8, l: Layout) !void {
    if (bytes.len != l.total) return error.BadProgramDataSize;
    @memset(bytes[0..header_size], 0);
    @memcpy(bytes[0..magic.len], magic);
    try writeU64(bytes, 8, l.constant_count);
    try writeU64(bytes, 16, l.entry_count);
    try writeU64(bytes, 24, l.string_bytes);
    try writeU32(bytes, 32, record_size);
}

pub fn writeRecord(bytes: []u8, l: Layout, id: usize, tag: Tag, a: u64, b: u64) !void {
    if (id >= l.constant_count) return error.BadConstantReference;
    const at = l.records_offset + id * record_size;
    @memset(bytes[at .. at + record_size], 0);
    bytes[at] = @intFromEnum(tag);
    try writeU64(bytes, at + 8, a);
    try writeU64(bytes, at + 16, b);
}

pub fn writeEntry(bytes: []u8, l: Layout, id: usize, entry: u64) !void {
    if (id >= l.entry_count) return error.BadConstantEntryRange;
    try writeU64(bytes, l.entries_offset + id * @sizeOf(u64), entry);
}

pub const View = struct {
    bytes: []const u8,
    layout: Layout,

    pub fn parse(bytes: []const u8) !View {
        if (bytes.len < header_size) return error.TruncatedProgramData;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadProgramDataMagic;
        if (try readU32(bytes, 32) != record_size) return error.BadProgramDataRecordSize;
        if (!std.mem.allEqual(u8, bytes[36..40], 0)) return error.BadProgramDataHeader;
        const constants = std.math.cast(usize, try readU64(bytes, 8)) orelse return error.ProgramDataTooLarge;
        const entries = std.math.cast(usize, try readU64(bytes, 16)) orelse return error.ProgramDataTooLarge;
        const strings = std.math.cast(usize, try readU64(bytes, 24)) orelse return error.ProgramDataTooLarge;
        const l = try layout(constants, entries, strings);
        if (bytes.len != l.total) return error.BadProgramDataSize;
        return .{ .bytes = bytes, .layout = l };
    }
    pub fn constant(self: View, id: u32) !Constant {
        if (id >= self.layout.constant_count) return error.BadConstantReference;
        const at = self.layout.records_offset + @as(usize, id) * record_size;
        if (!std.mem.allEqual(u8, self.bytes[at + 1 .. at + 8], 0)) return error.BadProgramDataRecord;
        const a = try readU64(self.bytes, at + 8);
        const b = try readU64(self.bytes, at + 16);
        return switch (self.bytes[at]) {
            @intFromEnum(Tag.nil) => .nil,
            @intFromEnum(Tag.boolean) => if (a <= 1 and b == 0)
                .{ .boolean = a != 0 }
            else
                error.BadProgramDataRecord,
            @intFromEnum(Tag.number) => if (b == 0)
                .{ .number_bits = a }
            else
                error.BadProgramDataRecord,
            @intFromEnum(Tag.string) => blk: {
                const offset = std.math.cast(usize, a) orelse return error.BadProgramDataString;
                const len = std.math.cast(usize, b) orelse return error.BadProgramDataString;
                if (offset > self.layout.string_bytes or len > self.layout.string_bytes - offset)
                    return error.BadProgramDataString;
                break :blk .{ .string = self.bytes[self.layout.strings_offset + offset ..][0..len] };
            },
            @intFromEnum(Tag.table) => if (b <= std.math.maxInt(u32))
                .{ .table = .{
                    .first = @truncate(a),
                    .count = @truncate(a >> 32),
                    .shape = @intCast(b),
                } }
            else
                error.BadProgramDataRecord,
            else => error.BadProgramDataTag,
        };
    }

    pub fn entry(self: View, id: u32) !u64 {
        if (id >= self.layout.entry_count) return error.BadConstantEntryRange;
        return readU64(self.bytes, self.layout.entries_offset + @as(usize, id) * @sizeOf(u64));
    }
};
test "external AOT data roundtrips fixed records entries and strings" {
    const l = try layout(5, 2, 3);
    const bytes = try std.testing.allocator.alloc(u8, l.total);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    try writeHeader(bytes, l);
    try writeRecord(bytes, l, 0, .nil, 0, 0);
    try writeRecord(bytes, l, 1, .boolean, 1, 0);
    try writeRecord(bytes, l, 2, .number, @bitCast(@as(f64, 4.5)), 0);
    try writeRecord(bytes, l, 3, .string, 0, 3);
    try writeRecord(bytes, l, 4, .table, (@as(u64, 2) << 32) | 7, 9);
    try writeEntry(bytes, l, 0, 0xffffffff00000003);
    try writeEntry(bytes, l, 1, 0x0000000100000002);
    @memcpy(bytes[l.strings_offset..], "abc");

    const view = try View.parse(bytes);
    try std.testing.expect((try view.constant(0)) == .nil);
    try std.testing.expect((try view.constant(1)).boolean);
    try std.testing.expectEqual(@as(f64, 4.5), @as(f64, @bitCast((try view.constant(2)).number_bits)));
    try std.testing.expectEqualStrings("abc", (try view.constant(3)).string);
    const table = (try view.constant(4)).table;
    try std.testing.expectEqual(@as(u32, 7), table.first);
    try std.testing.expectEqual(@as(u32, 2), table.count);
    try std.testing.expectEqual(@as(u32, 9), table.shape);
    try std.testing.expectEqual(@as(u64, 0xffffffff00000003), try view.entry(0));
    try std.testing.expectEqual(@as(u64, 0x0000000100000002), try view.entry(1));
}

test "external AOT data rejects truncated and corrupt envelopes" {
    try std.testing.expectError(error.TruncatedProgramData, View.parse("short"));
    const l = try layout(0, 0, 0);
    var bytes: [header_size]u8 = @splat(0);
    try writeHeader(&bytes, l);
    bytes[0] = 'X';
    try std.testing.expectError(error.BadProgramDataMagic, View.parse(&bytes));
}
