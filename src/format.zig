const std = @import("std");

pub const magic = "WIKDICT7";
pub const version: u32 = 7;

pub const record_flag_has_raw: u8 = 1 << 0;
pub const record_flag_alias_only: u8 = 1 << 1;

pub const lookup_kind_title: u8 = 0;
pub const lookup_kind_alternative_form: u8 = 1;

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
