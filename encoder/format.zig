const std = @import("std");
const compact = @import("compact_encoding.zig");
const normalize = @import("normalize");

pub const magic = "WIKDIC21";
pub const version: u32 = 21;

pub const record_flag_has_raw: u8 = 1 << 0;

pub const lookup_kind_title: u8 = 0;
pub const lookup_kind_alternative_form: u8 = 1;

pub const PayloadError = error{InvalidEncoding};

pub const Header = extern struct {
    magic_bytes: [8]u8,
    version: u32,
    header_size: u32,
    entry_count: u32,
    raw_entry_count: u32,
    redirect_count: u32,
    reserved0: u32 = 0,
    records_offset: u64,
    records_len: u64,

    pub fn init(
        entry_count: u32,
        raw_entry_count: u32,
        redirect_count: u32,
        records_offset: u64,
        records_len: u64,
    ) Header {
        return .{
            .magic_bytes = magic.*,
            .version = version,
            .header_size = @sizeOf(Header),
            .entry_count = entry_count,
            .raw_entry_count = raw_entry_count,
            .redirect_count = redirect_count,
            .records_offset = records_offset,
            .records_len = records_len,
        };
    }
};

test "header magic is stable" {
    try std.testing.expectEqualStrings(magic, &Header.init(0, 0, 0, 0, 0).magic_bytes);
}

pub const VarUIntError = error{InvalidVarUInt};

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

test "varuint round trips representative values" {
    const values = [_]u64{
        0,
        1,
        127,
        128,
        255,
        16_384,
        std.math.maxInt(u32),
        std.math.maxInt(u64),
    };

    for (values) |value| {
        var buffer: [10]u8 = undefined;
        const encoded = encodeVarUInt(&buffer, value);
        var cursor: usize = 0;
        const decoded = try readVarUInt(encoded, &cursor, encoded.len);
        try std.testing.expectEqual(value, decoded);
        try std.testing.expectEqual(encoded.len, cursor);
    }
}

pub fn encodeRawRecordPayloadAlloc(
    allocator: std.mem.Allocator,
    encoded_english: []const u8,
) ![]u8 {
    return allocator.dupe(u8, encoded_english);
}

pub fn rawRecordEnglishPayload(payload: []const u8) PayloadError![]const u8 {
    if (payload.len == 0) return error.InvalidEncoding;
    return payload;
}

pub fn encodeAliasRecordPayloadAlloc(
    allocator: std.mem.Allocator,
    target: []const u8,
) ![]u8 {
    return compact.encodeAlloc(allocator, target);
}

pub fn decodeAliasRecordTargetAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    return compact.decodeAlloc(allocator, payload) catch return error.InvalidEncoding;
}

pub fn decodeAliasRecordNormalizedTargetAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    const target = compact.decodeAlloc(allocator, payload) catch return error.InvalidEncoding;
    defer allocator.free(target);
    return normalize.normalizeAlloc(allocator, target);
}

test "raw record payload round trips english bytes" {
    const allocator = std.testing.allocator;
    const encoded = try encodeRawRecordPayloadAlloc(
        allocator,
        "encoded-english",
    );
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("encoded-english", try rawRecordEnglishPayload(encoded));
}

test "alias record payload round trips target and derives normalized target" {
    const allocator = std.testing.allocator;
    const encoded = try encodeAliasRecordPayloadAlloc(allocator, "Color");
    defer allocator.free(encoded);

    const target = try decodeAliasRecordTargetAlloc(allocator, encoded);
    defer allocator.free(target);
    try std.testing.expectEqualStrings("Color", target);

    const normalized_target = try decodeAliasRecordNormalizedTargetAlloc(allocator, encoded);
    defer allocator.free(normalized_target);
    try std.testing.expectEqualStrings("color", normalized_target);
}
