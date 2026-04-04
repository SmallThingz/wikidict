const std = @import("std");
const compact = @import("compact_encoding.zig");

pub const magic = "WIKDIC22";
pub const version: u32 = 22;

pub const record_flag_has_raw: u8 = 1 << 0;

pub const lookup_kind_title: u8 = 0;
pub const lookup_kind_alternative_form: u8 = 1;

pub const PayloadError = error{InvalidEncoding};

pub const RawAltForm = struct {
    value: []const u8,
    // Precomputed normalized lookup key for the alternative form.
    normalized: []const u8,
};

pub const RawRecordMetadata = struct {
    alt_forms: []const RawAltForm,
    // Canonical targets are stored normalized so the decoder can index redirects without re-normalizing.
    normalized_targets: []const []const u8,

    pub fn deinit(self: *RawRecordMetadata, allocator: std.mem.Allocator) void {
        for (self.alt_forms) |alt_form| {
            allocator.free(alt_form.value);
            allocator.free(alt_form.normalized);
        }
        allocator.free(self.alt_forms);
        for (self.normalized_targets) |target| allocator.free(target);
        allocator.free(self.normalized_targets);
    }
};

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
    alt_forms: []const RawAltForm,
    normalized_targets: []const []const u8,
    encoded_english: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var buf: [10]u8 = undefined;
    try out.appendSlice(allocator, encodeVarUInt(&buf, alt_forms.len));
    for (alt_forms) |alt_form| {
        try appendCompactSlice(&out, allocator, alt_form.value);
        try appendCompactSlice(&out, allocator, alt_form.normalized);
    }

    try out.appendSlice(allocator, encodeVarUInt(&buf, normalized_targets.len));
    for (normalized_targets) |target| {
        try appendCompactSlice(&out, allocator, target);
    }

    try appendBytesSlice(&out, allocator, encoded_english);
    return out.toOwnedSlice(allocator);
}

pub fn decodeRawRecordMetadataAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    const alt_forms = try allocator.alloc(RawAltForm, alt_form_count);
    errdefer allocator.free(alt_forms);

    var alt_index: usize = 0;
    errdefer {
        while (alt_index > 0) : (alt_index -= 1) {
            allocator.free(alt_forms[alt_index - 1].value);
            allocator.free(alt_forms[alt_index - 1].normalized);
        }
    }
    while (alt_index < alt_forms.len) : (alt_index += 1) {
        alt_forms[alt_index] = .{
            .value = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len),
            .normalized = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len),
        };
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    const normalized_targets = try allocator.alloc([]const u8, target_count);
    errdefer allocator.free(normalized_targets);

    var target_index: usize = 0;
    errdefer while (target_index > 0) : (target_index -= 1) allocator.free(normalized_targets[target_index - 1]);
    while (target_index < normalized_targets.len) : (target_index += 1) {
        normalized_targets[target_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    }

    _ = try rawRecordEnglishPayload(payload);
    return .{
        .alt_forms = alt_forms,
        .normalized_targets = normalized_targets,
    };
}

pub fn rawRecordEnglishPayload(payload: []const u8) PayloadError![]const u8 {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    for (0..alt_form_count) |_| {
        _ = readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
        _ = readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    for (0..target_count) |_| {
        _ = readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    }

    return readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
}

pub fn encodeAliasRecordPayloadAlloc(
    allocator: std.mem.Allocator,
    target: []const u8,
    normalized_target: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCompactSlice(&out, allocator, target);
    try appendCompactSlice(&out, allocator, normalized_target);
    return out.toOwnedSlice(allocator);
}

pub fn decodeAliasRecordTargetAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    var cursor: usize = 0;
    return readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
}

pub fn decodeAliasRecordNormalizedTargetAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    var cursor: usize = 0;
    const target = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    defer allocator.free(target);
    return readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
}

fn appendCompactSlice(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const encoded = try compact.encodeAlloc(allocator, text);
    defer allocator.free(encoded);
    try appendBytesSlice(out, allocator, encoded);
}

fn appendBytesSlice(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    var buf: [10]u8 = undefined;
    try out.appendSlice(allocator, encodeVarUInt(&buf, value.len));
    try out.appendSlice(allocator, value);
}

fn readCompactSliceAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
    limit: usize,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    const encoded = readLengthPrefixedSlice(bytes, cursor, limit) catch return error.InvalidEncoding;
    return compact.decodeAlloc(allocator, encoded) catch return error.InvalidEncoding;
}

fn readLengthPrefixedSlice(bytes: []const u8, cursor: *usize, limit: usize) PayloadError![]const u8 {
    const len_u64 = readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
    const len = std.math.cast(usize, len_u64) orelse return error.InvalidEncoding;
    if (cursor.* > limit or len > limit - cursor.*) return error.InvalidEncoding;
    const start = cursor.*;
    cursor.* += len;
    return bytes[start .. start + len];
}

test "raw record payload round trips metadata and english bytes" {
    const allocator = std.testing.allocator;
    const encoded = try encodeRawRecordPayloadAlloc(
        allocator,
        &.{
            .{ .value = "colour", .normalized = "colour" },
            .{ .value = "co lor", .normalized = "co lor" },
        },
        &.{ "color", "color entry" },
        "encoded-english",
    );
    defer allocator.free(encoded);

    var metadata = try decodeRawRecordMetadataAlloc(allocator, encoded);
    defer metadata.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), metadata.alt_forms.len);
    try std.testing.expectEqualStrings("colour", metadata.alt_forms[0].value);
    try std.testing.expectEqualStrings("colour", metadata.alt_forms[0].normalized);
    try std.testing.expectEqual(@as(usize, 2), metadata.normalized_targets.len);
    try std.testing.expectEqualStrings("color", metadata.normalized_targets[0]);
    try std.testing.expectEqualStrings("encoded-english", try rawRecordEnglishPayload(encoded));
}

test "alias record payload round trips target and normalized target" {
    const allocator = std.testing.allocator;
    const encoded = try encodeAliasRecordPayloadAlloc(allocator, "Color", "color");
    defer allocator.free(encoded);

    const target = try decodeAliasRecordTargetAlloc(allocator, encoded);
    defer allocator.free(target);
    try std.testing.expectEqualStrings("Color", target);

    const normalized_target = try decodeAliasRecordNormalizedTargetAlloc(allocator, encoded);
    defer allocator.free(normalized_target);
    try std.testing.expectEqualStrings("color", normalized_target);
}
