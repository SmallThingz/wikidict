const std = @import("std");

pub const magic = "WIKDIC31";
pub const lookup_kind_title: u8 = 0;
pub const lookup_kind_alternative_form: u8 = 1;

pub const LayoutError = error{ InvalidDictionaryFile, FileTooBig };
pub const VarUIntError = error{InvalidVarUInt};

pub const Header = extern struct {
    magic_bytes: [8]u8,
    raw_count: u32,
    alias_count: u32,

    pub fn init(raw_count: u32, alias_count: u32) Header {
        return .{
            .magic_bytes = magic.*,
            .raw_count = raw_count,
            .alias_count = alias_count,
        };
    }

    pub fn entryCount(self: Header) u32 {
        return self.raw_count + self.alias_count;
    }
};

pub const header_len: usize = @sizeOf(Header);

pub const DictionaryLayout = struct {
    raw_titles_offset: u64,
    raw_titles_len: u64,
    alias_titles_offset: u64,
    alias_titles_len: u64,
    alias_targets_offset: u64,
    alias_targets_len: u64,
    raw_payloads_offset: u64,
    raw_payloads_len: u64,
};

pub const InspectedDictionary = struct {
    header: Header,
    layout: DictionaryLayout,
};

pub fn inspectDictionary(bytes: []const u8) LayoutError!InspectedDictionary {
    if (bytes.len < header_len) return error.InvalidDictionaryFile;

    const header = std.mem.bytesToValue(Header, bytes[0..header_len]);
    if (!std.mem.eql(u8, &header.magic_bytes, magic)) return error.InvalidDictionaryFile;

    var cursor: usize = header_len;
    const raw_titles_offset: u64 = cursor;
    try skipNullTerminatedStrings(bytes, &cursor, bytes.len, header.raw_count);
    const raw_titles_end = cursor;

    const alias_titles_offset: u64 = cursor;
    try skipNullTerminatedStrings(bytes, &cursor, bytes.len, header.alias_count);
    const alias_titles_end = cursor;

    const alias_targets_offset: u64 = cursor;
    const alias_targets_len = std.math.mul(u64, header.alias_count, @sizeOf(u32)) catch return error.FileTooBig;
    if (alias_targets_len > bytes.len - cursor) return error.InvalidDictionaryFile;
    cursor += @intCast(alias_targets_len);

    const raw_payloads_offset: u64 = cursor;
    try skipNullTerminatedStrings(bytes, &cursor, bytes.len, header.raw_count);
    if (cursor != bytes.len) return error.InvalidDictionaryFile;

    return .{
        .header = header,
        .layout = .{
            .raw_titles_offset = raw_titles_offset,
            .raw_titles_len = raw_titles_end - raw_titles_offset,
            .alias_titles_offset = alias_titles_offset,
            .alias_titles_len = alias_titles_end - alias_titles_offset,
            .alias_targets_offset = alias_targets_offset,
            .alias_targets_len = alias_targets_len,
            .raw_payloads_offset = raw_payloads_offset,
            .raw_payloads_len = bytes.len - raw_payloads_offset,
        },
    };
}

pub fn readAliasTargetAt(bytes: []const u8, layout: DictionaryLayout, alias_index: usize) LayoutError!u32 {
    const start = std.math.mul(usize, alias_index, @sizeOf(u32)) catch return error.FileTooBig;
    if (start > layout.alias_targets_len or layout.alias_targets_len - start < @sizeOf(u32)) return error.InvalidDictionaryFile;
    const offset = std.math.cast(usize, layout.alias_targets_offset) orelse return error.FileTooBig;
    const ptr: *const [4]u8 = @ptrCast(bytes[offset + start .. offset + start + @sizeOf(u32)].ptr);
    return std.mem.readInt(u32, ptr, .little);
}

pub fn readNullTerminatedSlice(bytes: []const u8, cursor: *usize, limit: usize) LayoutError![]const u8 {
    if (cursor.* >= limit) return error.InvalidDictionaryFile;
    const terminator = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidDictionaryFile;
    if (terminator >= limit) return error.InvalidDictionaryFile;
    const out = bytes[cursor.*..terminator];
    cursor.* = terminator + 1;
    return out;
}

fn skipNullTerminatedStrings(bytes: []const u8, cursor: *usize, limit: usize, count: u32) LayoutError!void {
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        _ = try readNullTerminatedSlice(bytes, cursor, limit);
    }
}

pub fn encodeVarUInt(buffer: *[10]u8, value_init: u64) []const u8 {
    var value = value_init;
    var index: usize = 0;
    while (value >= 0x80) : (index += 1) {
        buffer[index] = @intCast((value & 0x7f) | 0x80);
        value >>= 7;
    }
    buffer[index] = @intCast(value);
    return buffer[0 .. index + 1];
}

pub fn readVarUInt(bytes: []const u8, cursor: *usize, limit: usize) VarUIntError!u64 {
    var shift: u6 = 0;
    var value: u64 = 0;

    while (true) {
        if (cursor.* >= limit) return error.InvalidVarUInt;
        const byte = bytes[cursor.*];
        cursor.* += 1;

        if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidVarUInt;
        value |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return value;
        if (shift >= 63) return error.InvalidVarUInt;
        shift += 7;
    }
}

test "inspectDictionary parses the stripped final layout" {
    const blob =
        magic ++
        &[_]u8{ 2, 0, 0, 0 } ++
        &[_]u8{ 1, 0, 0, 0 } ++
        "cat\x00dog\x00" ++
        "cats\x00" ++
        &[_]u8{ 0, 0, 0, 0 } ++
        "raw-cat\x00raw-dog\x00";

    const inspected = try inspectDictionary(blob);
    try std.testing.expectEqual(@as(u32, 2), inspected.header.raw_count);
    try std.testing.expectEqual(@as(u32, 1), inspected.header.alias_count);
    try std.testing.expectEqual(@as(u32, 0), try readAliasTargetAt(blob, inspected.layout, 0));
}
