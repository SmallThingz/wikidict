const std = @import("std");
const compact = @import("compact_encoding.zig");
const generated = @import("generated_structure_tables");

pub const magic = "WIKDIC28";
pub const version: u32 = 28;
pub const max_serialized_payload_len: u32 = 0x00ff_ffff;
pub const legacy_magic_v25 = "WIKDIC25";
pub const legacy_version_v25: u32 = 25;
pub const legacy_magic_v24 = "WIKDIC24";
pub const legacy_version_v24: u32 = 24;
pub const legacy_magic_v23 = "WIKDIC23";
pub const legacy_version_v23: u32 = 23;
pub const legacy_magic_v22 = "WIKDIC22";
pub const legacy_version_v22: u32 = 22;
pub const structure_fingerprint: u32 = generated.structure_fingerprint;

pub const record_flag_has_raw: u8 = 1 << 0;

pub const lookup_kind_title: u8 = 0;
pub const lookup_kind_alternative_form: u8 = 1;

pub const PayloadError = error{InvalidEncoding};
pub const LayoutError = error{ InvalidDictionaryFile, FileTooBig };
pub const U24Error = error{ValueTooLarge};

pub const RawRecordMetadata = struct {
    alt_forms: []const []const u8,
    canonical_targets: []const []const u8,
    alias_only: bool,

    pub fn deinit(self: *RawRecordMetadata, allocator: std.mem.Allocator) void {
        for (self.alt_forms) |alt_form| allocator.free(alt_form);
        allocator.free(self.alt_forms);
        for (self.canonical_targets) |target| allocator.free(target);
        allocator.free(self.canonical_targets);
    }
};

pub const DictionaryLayout = struct {
    entry_count: u32,
    lengths_offset: u64,
    lengths_len: u64,
    titles_offset: u64,
    titles_len: u64,
    records_offset: u64,
    records_len: u64,
};

pub const Header = struct {
    magic_bytes: [8]u8,
    version: u32,
    entry_count: u32,
    raw_entry_count: u32,
    redirect_count: u32,
    reserved0: u32,
    lengths_offset: u64,
    lengths_len: u64,
    titles_offset: u64,
    titles_len: u64,
    records_offset: u64,
    records_len: u64,

    pub fn init(
        entry_count: u32,
        raw_entry_count: u32,
        redirect_count: u32,
        lengths_offset: u64,
        lengths_len: u64,
        titles_offset: u64,
        titles_len: u64,
        records_offset: u64,
        records_len: u64,
    ) Header {
        return .{
            .magic_bytes = magic.*,
            .version = version,
            .entry_count = entry_count,
            .raw_entry_count = raw_entry_count,
            .redirect_count = redirect_count,
            .reserved0 = structure_fingerprint,
            .lengths_offset = lengths_offset,
            .lengths_len = lengths_len,
            .titles_offset = titles_offset,
            .titles_len = titles_len,
            .records_offset = records_offset,
            .records_len = records_len,
        };
    }
};

pub const InspectedDictionary = struct {
    header: Header,
    layout: DictionaryLayout,
};

test "header magic is stable" {
    try std.testing.expectEqualStrings(magic, &Header.init(0, 0, 0, 4, 0, 4, 0, 4, 0).magic_bytes);
}

test "header stores structure fingerprint" {
    try std.testing.expectEqual(structure_fingerprint, Header.init(0, 0, 0, 4, 0, 4, 0, 4, 0).reserved0);
}

pub fn writeU24(buffer: *[3]u8, value: usize) U24Error![]const u8 {
    const value_u32 = std.math.cast(u32, value) orelse return error.ValueTooLarge;
    if (value_u32 > max_serialized_payload_len) return error.ValueTooLarge;

    buffer[0] = @intCast(value_u32 & 0xff);
    buffer[1] = @intCast((value_u32 >> 8) & 0xff);
    buffer[2] = @intCast((value_u32 >> 16) & 0xff);
    return buffer[0..];
}

pub fn readU24(bytes: []const u8) LayoutError!u32 {
    if (bytes.len < 3) return error.InvalidDictionaryFile;
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16);
}

pub fn payloadLengthAt(length_bytes: []const u8, entry_index: usize) LayoutError!u32 {
    const start = std.math.mul(usize, entry_index, 3) catch return error.FileTooBig;
    if (start > length_bytes.len or length_bytes.len - start < 3) return error.InvalidDictionaryFile;
    return readU24(length_bytes[start .. start + 3]);
}

pub fn inspectDictionary(bytes: []const u8) LayoutError!InspectedDictionary {
    if (bytes.len < 4) return error.InvalidDictionaryFile;

    const entry_count = std.mem.readInt(u32, bytes[0..4], .little);
    const lengths_len = std.math.mul(u64, entry_count, 3) catch return error.FileTooBig;
    const titles_offset = std.math.add(u64, 4, lengths_len) catch return error.FileTooBig;
    if (titles_offset > bytes.len) return error.InvalidDictionaryFile;

    const lengths_offset: u64 = 4;
    const length_bytes = bytes[@as(usize, @intCast(lengths_offset))..@as(usize, @intCast(titles_offset))];

    var payload_bytes_total: u64 = 0;
    for (0..entry_count) |idx| {
        const payload_len = try payloadLengthAt(length_bytes, idx);
        if (payload_len == 0) return error.InvalidDictionaryFile;
        payload_bytes_total = std.math.add(u64, payload_bytes_total, payload_len) catch return error.FileTooBig;
    }

    if (payload_bytes_total > bytes.len - @as(usize, @intCast(titles_offset))) return error.InvalidDictionaryFile;
    const records_offset = @as(u64, @intCast(bytes.len)) - payload_bytes_total;
    const titles_len = records_offset - titles_offset;

    var title_cursor: usize = @intCast(titles_offset);
    const records_start: usize = @intCast(records_offset);
    for (0..entry_count) |_| {
        const terminator = std.mem.indexOfScalarPos(u8, bytes, title_cursor, 0) orelse return error.InvalidDictionaryFile;
        if (terminator >= records_start) return error.InvalidDictionaryFile;
        title_cursor = terminator + 1;
    }
    if (title_cursor != records_start) return error.InvalidDictionaryFile;

    var payload_cursor: usize = records_start;
    var raw_entry_count: u32 = 0;
    var redirect_count: u32 = 0;
    for (0..entry_count) |idx| {
        const payload_len = try payloadLengthAt(length_bytes, idx);
        if (payload_len > bytes.len - payload_cursor) return error.InvalidDictionaryFile;

        const payload = bytes[payload_cursor .. payload_cursor + payload_len];
        switch (payload[0]) {
            record_flag_has_raw => raw_entry_count += 1,
            0 => redirect_count += 1,
            else => return error.InvalidDictionaryFile,
        }
        payload_cursor += payload_len;
    }
    if (payload_cursor != bytes.len) return error.InvalidDictionaryFile;

    const layout: DictionaryLayout = .{
        .entry_count = entry_count,
        .lengths_offset = lengths_offset,
        .lengths_len = lengths_len,
        .titles_offset = titles_offset,
        .titles_len = titles_len,
        .records_offset = records_offset,
        .records_len = payload_bytes_total,
    };
    return .{
        .header = Header.init(
            entry_count,
            raw_entry_count,
            redirect_count,
            layout.lengths_offset,
            layout.lengths_len,
            layout.titles_offset,
            layout.titles_len,
            layout.records_offset,
            layout.records_len,
        ),
        .layout = layout,
    };
}

test "manual u24 serialization round trips" {
    var bytes: [3]u8 = undefined;
    _ = try writeU24(&bytes, 0x12_34_56);
    try std.testing.expectEqual(@as(u8, 0x56), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x34), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x12), bytes[2]);
    try std.testing.expectEqual(@as(u32, 0x12_34_56), try readU24(&bytes));
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
    alt_forms: []const []const u8,
    canonical_targets: []const []const u8,
    alias_only: bool,
    encoded_raw_content: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var buf: [10]u8 = undefined;
    try out.appendSlice(allocator, encodeVarUInt(&buf, alt_forms.len));
    for (alt_forms) |alt_form| {
        try appendCompactSlice(&out, allocator, alt_form);
    }

    try out.appendSlice(allocator, encodeVarUInt(&buf, canonical_targets.len));
    for (canonical_targets) |target| {
        try appendCompactSlice(&out, allocator, target);
    }

    try out.append(allocator, if (alias_only) 1 else 0);
    try appendBytesSlice(&out, allocator, encoded_raw_content);
    return out.toOwnedSlice(allocator);
}

pub fn decodeRawRecordMetadataAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    return decodeRawRecordMetadataAllocVersion(allocator, payload, version);
}

pub fn decodeRawRecordMetadataAllocVersion(
    allocator: std.mem.Allocator,
    payload: []const u8,
    dictionary_version: u32,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    return switch (dictionary_version) {
        version => decodeRawRecordMetadataAllocCurrent(allocator, payload),
        legacy_version_v25 => decodeRawRecordMetadataAllocV25(allocator, payload),
        legacy_version_v23 => decodeRawRecordMetadataAllocV25(allocator, payload),
        legacy_version_v22 => decodeRawRecordMetadataAllocV22(allocator, payload),
        else => error.InvalidEncoding,
    };
}

fn decodeRawRecordMetadataAllocCurrent(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    const alt_forms = try allocator.alloc([]const u8, alt_form_count);
    errdefer allocator.free(alt_forms);

    var alt_index: usize = 0;
    errdefer while (alt_index > 0) : (alt_index -= 1) allocator.free(alt_forms[alt_index - 1]);
    while (alt_index < alt_forms.len) : (alt_index += 1) {
        alt_forms[alt_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    const canonical_targets = try allocator.alloc([]const u8, target_count);
    errdefer allocator.free(canonical_targets);

    var target_index: usize = 0;
    errdefer while (target_index > 0) : (target_index -= 1) allocator.free(canonical_targets[target_index - 1]);
    while (target_index < canonical_targets.len) : (target_index += 1) {
        canonical_targets[target_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    }

    if (cursor >= payload.len) return error.InvalidEncoding;
    const alias_only = payload[cursor] != 0;
    cursor += 1;
    _ = try rawRecordContentPayload(payload);
    return .{
        .alt_forms = alt_forms,
        .canonical_targets = canonical_targets,
        .alias_only = alias_only,
    };
}

fn decodeRawRecordMetadataAllocV25(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    var metadata = try decodeRawRecordMetadataAllocCurrentV23(allocator, payload);
    metadata.alias_only = false;
    return metadata;
}

fn decodeRawRecordMetadataAllocCurrentV23(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    const alt_forms = try allocator.alloc([]const u8, alt_form_count);
    errdefer allocator.free(alt_forms);

    var alt_index: usize = 0;
    errdefer while (alt_index > 0) : (alt_index -= 1) allocator.free(alt_forms[alt_index - 1]);
    while (alt_index < alt_forms.len) : (alt_index += 1) {
        alt_forms[alt_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    const canonical_targets = try allocator.alloc([]const u8, target_count);
    errdefer allocator.free(canonical_targets);

    var target_index: usize = 0;
    errdefer while (target_index > 0) : (target_index -= 1) allocator.free(canonical_targets[target_index - 1]);
    while (target_index < canonical_targets.len) : (target_index += 1) {
        canonical_targets[target_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    }

    _ = try rawRecordContentPayloadVersion(payload, legacy_version_v25);
    return .{
        .alt_forms = alt_forms,
        .canonical_targets = canonical_targets,
        .alias_only = false,
    };
}

pub fn rawRecordContentPayload(payload: []const u8) PayloadError![]const u8 {
    return rawRecordContentPayloadVersion(payload, version);
}

pub fn rawRecordContentPayloadVersion(payload: []const u8, dictionary_version: u32) PayloadError![]const u8 {
    return switch (dictionary_version) {
        version => rawRecordContentPayloadCurrent(payload),
        legacy_version_v25 => rawRecordContentPayloadV25(payload),
        legacy_version_v23 => rawRecordContentPayloadV25(payload),
        legacy_version_v22 => rawRecordEnglishPayloadV22(payload),
        else => error.InvalidEncoding,
    };
}

pub fn rawRecordEnglishPayload(payload: []const u8) PayloadError![]const u8 {
    return rawRecordContentPayload(payload);
}

pub fn rawRecordEnglishPayloadVersion(payload: []const u8, dictionary_version: u32) PayloadError![]const u8 {
    return rawRecordContentPayloadVersion(payload, dictionary_version);
}

fn rawRecordContentPayloadCurrent(payload: []const u8) PayloadError![]const u8 {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    for (0..alt_form_count) |_| {
        _ = readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    for (0..target_count) |_| {
        _ = readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    }

    if (cursor >= payload.len) return error.InvalidEncoding;
    cursor += 1;
    return readLengthPrefixedSlice(payload, &cursor, payload.len) catch return error.InvalidEncoding;
}

fn rawRecordContentPayloadV25(payload: []const u8) PayloadError![]const u8 {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    for (0..alt_form_count) |_| {
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
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCompactSlice(&out, allocator, target);
    return out.toOwnedSlice(allocator);
}

pub fn decodeAliasRecordTargetAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    return decodeAliasRecordTargetAllocVersion(allocator, payload, version);
}

pub fn decodeAliasRecordTargetAllocVersion(
    allocator: std.mem.Allocator,
    payload: []const u8,
    dictionary_version: u32,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    return switch (dictionary_version) {
        version => decodeAliasRecordTargetAllocCurrent(allocator, payload),
        legacy_version_v25 => decodeAliasRecordTargetAllocCurrent(allocator, payload),
        legacy_version_v23 => decodeAliasRecordTargetAllocCurrent(allocator, payload),
        legacy_version_v22 => decodeAliasRecordTargetAllocV22(allocator, payload),
        else => error.InvalidEncoding,
    };
}

fn decodeAliasRecordTargetAllocCurrent(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    var cursor: usize = 0;
    return readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
}

fn decodeRawRecordMetadataAllocV22(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    const alt_forms = try allocator.alloc([]const u8, alt_form_count);
    errdefer allocator.free(alt_forms);

    var alt_index: usize = 0;
    errdefer while (alt_index > 0) : (alt_index -= 1) allocator.free(alt_forms[alt_index - 1]);
    while (alt_index < alt_forms.len) : (alt_index += 1) {
        alt_forms[alt_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
        const normalized = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
        allocator.free(normalized);
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    const canonical_targets = try allocator.alloc([]const u8, target_count);
    errdefer allocator.free(canonical_targets);

    var target_index: usize = 0;
    errdefer while (target_index > 0) : (target_index -= 1) allocator.free(canonical_targets[target_index - 1]);
    while (target_index < canonical_targets.len) : (target_index += 1) {
        canonical_targets[target_index] = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    }

    _ = try rawRecordEnglishPayloadV22(payload);
    return .{
        .alt_forms = alt_forms,
        .canonical_targets = canonical_targets,
        .alias_only = false,
    };
}

fn rawRecordEnglishPayloadV22(payload: []const u8) PayloadError![]const u8 {
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

fn decodeAliasRecordTargetAllocV22(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    var cursor: usize = 0;
    const target = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    const normalized = try readCompactSliceAlloc(allocator, payload, &cursor, payload.len);
    allocator.free(normalized);
    return target;
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
            "colour",
            "co lor",
        },
        &.{ "color", "color entry" },
        true,
        "encoded-english",
    );
    defer allocator.free(encoded);

    var metadata = try decodeRawRecordMetadataAlloc(allocator, encoded);
    defer metadata.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), metadata.alt_forms.len);
    try std.testing.expectEqualStrings("colour", metadata.alt_forms[0]);
    try std.testing.expectEqual(@as(usize, 2), metadata.canonical_targets.len);
    try std.testing.expectEqualStrings("color", metadata.canonical_targets[0]);
    try std.testing.expect(metadata.alias_only);
    try std.testing.expectEqualStrings("encoded-english", try rawRecordEnglishPayload(encoded));
}

test "alias record payload round trips target" {
    const allocator = std.testing.allocator;
    const encoded = try encodeAliasRecordPayloadAlloc(allocator, "Color");
    defer allocator.free(encoded);

    const target = try decodeAliasRecordTargetAlloc(allocator, encoded);
    defer allocator.free(target);
    try std.testing.expectEqualStrings("Color", target);
}

test "versioned raw record decoding accepts v22 payloads" {
    const allocator = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var buf: [10]u8 = undefined;
    try out.appendSlice(allocator, encodeVarUInt(&buf, 1));
    try appendCompactSlice(&out, allocator, "colour");
    try appendCompactSlice(&out, allocator, "colour");
    try out.appendSlice(allocator, encodeVarUInt(&buf, 1));
    try appendCompactSlice(&out, allocator, "color");
    try appendBytesSlice(&out, allocator, "encoded-english");

    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);

    var metadata = try decodeRawRecordMetadataAllocVersion(allocator, payload, legacy_version_v22);
    defer metadata.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), metadata.alt_forms.len);
    try std.testing.expectEqualStrings("colour", metadata.alt_forms[0]);
    try std.testing.expectEqual(@as(usize, 1), metadata.canonical_targets.len);
    try std.testing.expectEqualStrings("color", metadata.canonical_targets[0]);
    try std.testing.expect(!metadata.alias_only);
    try std.testing.expectEqualStrings("encoded-english", try rawRecordEnglishPayloadVersion(payload, legacy_version_v22));
}

test "versioned alias decoding accepts v22 payloads" {
    const allocator = std.testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendCompactSlice(&out, allocator, "Color");
    try appendCompactSlice(&out, allocator, "color");

    const payload = try out.toOwnedSlice(allocator);
    defer allocator.free(payload);

    const target = try decodeAliasRecordTargetAllocVersion(allocator, payload, legacy_version_v22);
    defer allocator.free(target);
    try std.testing.expectEqualStrings("Color", target);
}
