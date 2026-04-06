const std = @import("std");
const compact = @import("compact_runtime.zig");

pub const magic = "WIKDIC29";
pub const version: u32 = 29;
pub const max_serialized_payload_len: u32 = 0x00ff_ffff;

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
    mappings_offset: u64,
    mappings_len: u64,
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
    mappings_offset: u64,
    mappings_len: u64,
    titles_offset: u64,
    titles_len: u64,
    records_offset: u64,
    records_len: u64,

    pub fn init(
        entry_count: u32,
        raw_entry_count: u32,
        redirect_count: u32,
        mapping_fingerprint: u32,
        lengths_offset: u64,
        lengths_len: u64,
        mappings_offset: u64,
        mappings_len: u64,
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
            .reserved0 = mapping_fingerprint,
            .lengths_offset = lengths_offset,
            .lengths_len = lengths_len,
            .mappings_offset = mappings_offset,
            .mappings_len = mappings_len,
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
    if (bytes.len < 8) return error.InvalidDictionaryFile;

    const entry_count = std.mem.readInt(u32, bytes[0..4], .little);
    const mappings_len = std.mem.readInt(u32, bytes[4..8], .little);
    const lengths_len = std.math.mul(u64, entry_count, 3) catch return error.FileTooBig;
    const mappings_offset = std.math.add(u64, 8, lengths_len) catch return error.FileTooBig;
    const titles_offset = std.math.add(u64, mappings_offset, mappings_len) catch return error.FileTooBig;
    if (titles_offset > bytes.len) return error.InvalidDictionaryFile;

    const lengths_offset: u64 = 8;
    const length_bytes = bytes[@as(usize, @intCast(lengths_offset))..@as(usize, @intCast(mappings_offset))];
    const mapping_bytes = bytes[@as(usize, @intCast(mappings_offset))..@as(usize, @intCast(titles_offset))];
    const mapping_fingerprint = try inspectMappingFingerprint(mapping_bytes);

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
        .mappings_offset = mappings_offset,
        .mappings_len = mappings_len,
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
            mapping_fingerprint,
            layout.lengths_offset,
            layout.lengths_len,
            layout.mappings_offset,
            layout.mappings_len,
            layout.titles_offset,
            layout.titles_len,
            layout.records_offset,
            layout.records_len,
        ),
        .layout = layout,
    };
}

pub fn parseCompactMappingsAlloc(
    allocator: std.mem.Allocator,
    blob: []const u8,
) (std.mem.Allocator.Error || LayoutError)!compact.OwnedRuntimeMappings {
    if (blob.len < 28) return error.InvalidDictionaryFile;

    var cursor: usize = 0;
    const fingerprint = try readFixedU32(blob, &cursor);
    const direct_count = try readFixedU32(blob, &cursor);
    const escaped_count = try readFixedU32(blob, &cursor);
    const extended_count = try readFixedU32(blob, &cursor);
    const line_template_count = try readFixedU32(blob, &cursor);
    const translation_template_count = try readFixedU32(blob, &cursor);
    const heading_level_count = try readFixedU32(blob, &cursor);

    var owned: compact.OwnedRuntimeMappings = .{
        .direct_patterns = try allocator.alloc([]const u8, std.math.cast(usize, direct_count) orelse return error.FileTooBig),
        .escaped_patterns = try allocator.alloc([]const u8, std.math.cast(usize, escaped_count) orelse return error.FileTooBig),
        .extended_patterns = try allocator.alloc([]const u8, std.math.cast(usize, extended_count) orelse return error.FileTooBig),
        .line_templates = try allocator.alloc(compact.RuntimeLineTemplate, std.math.cast(usize, line_template_count) orelse return error.FileTooBig),
        .translation_templates = try allocator.alloc(compact.RuntimeTranslationTemplate, std.math.cast(usize, translation_template_count) orelse return error.FileTooBig),
        .heading_levels = try allocator.alloc(compact.RuntimeHeadingLevelSpec, std.math.cast(usize, heading_level_count) orelse return error.FileTooBig),
    };
    errdefer owned.deinit(allocator);

    for (owned.direct_patterns) |*pattern| pattern.* = try readMappingString(blob, &cursor);
    for (owned.escaped_patterns) |*pattern| pattern.* = try readMappingString(blob, &cursor);
    for (owned.extended_patterns) |*pattern| pattern.* = try readMappingString(blob, &cursor);
    for (owned.line_templates) |*entry| {
        entry.* = .{
            .code = try readFixedU16(blob, &cursor),
            .name = try readMappingString(blob, &cursor),
        };
    }
    for (owned.translation_templates) |*entry| {
        entry.* = .{
            .code = try readFixedU16(blob, &cursor),
            .name = try readMappingString(blob, &cursor),
        };
    }
    for (owned.heading_levels) |*entry| {
        const code = try readFixedU16(blob, &cursor);
        if (cursor + 2 > blob.len) return error.InvalidDictionaryFile;
        const level = blob[cursor];
        const kind_raw = blob[cursor + 1];
        cursor += 2;
        entry.* = .{
            .code = code,
            .level = level,
            .title = try readMappingString(blob, &cursor),
            .kind = switch (kind_raw) {
                0 => .lines,
                1 => .pos_lines,
                2 => .term_list,
                3 => .translations,
                else => return error.InvalidDictionaryFile,
            },
        };
    }

    if (cursor != blob.len) return error.InvalidDictionaryFile;
    if (compact.mappingFingerprint(owned.view()) != fingerprint) return error.InvalidDictionaryFile;
    return owned;
}

pub fn decodeRawRecordMetadataAllocWithMappings(
    allocator: std.mem.Allocator,
    payload: []const u8,
    mappings: compact.RuntimeMappings,
) (std.mem.Allocator.Error || PayloadError)!RawRecordMetadata {
    var cursor: usize = 0;

    const alt_form_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const alt_form_count = std.math.cast(usize, alt_form_count_u64) orelse return error.InvalidEncoding;
    const alt_forms = try allocator.alloc([]const u8, alt_form_count);
    errdefer allocator.free(alt_forms);

    var alt_index: usize = 0;
    errdefer while (alt_index > 0) : (alt_index -= 1) allocator.free(alt_forms[alt_index - 1]);
    while (alt_index < alt_forms.len) : (alt_index += 1) {
        alt_forms[alt_index] = try readCompactSliceAllocWithMappings(allocator, payload, &cursor, payload.len, mappings);
    }

    const target_count_u64 = readVarUInt(payload, &cursor, payload.len) catch return error.InvalidEncoding;
    const target_count = std.math.cast(usize, target_count_u64) orelse return error.InvalidEncoding;
    const canonical_targets = try allocator.alloc([]const u8, target_count);
    errdefer allocator.free(canonical_targets);

    var target_index: usize = 0;
    errdefer while (target_index > 0) : (target_index -= 1) allocator.free(canonical_targets[target_index - 1]);
    while (target_index < canonical_targets.len) : (target_index += 1) {
        canonical_targets[target_index] = try readCompactSliceAllocWithMappings(allocator, payload, &cursor, payload.len, mappings);
    }

    if (cursor >= payload.len) return error.InvalidEncoding;
    const alias_only = payload[cursor] != 0;
    cursor += 1;
    _ = try rawRecordContentPayloadVersion(payload, version);

    return .{
        .alt_forms = alt_forms,
        .canonical_targets = canonical_targets,
        .alias_only = alias_only,
    };
}

pub fn rawRecordContentPayloadVersion(payload: []const u8, dictionary_version: u32) PayloadError![]const u8 {
    if (dictionary_version != version) return error.InvalidEncoding;

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

pub fn decodeAliasRecordTargetAllocWithMappings(
    allocator: std.mem.Allocator,
    payload: []const u8,
    mappings: compact.RuntimeMappings,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    var cursor: usize = 0;
    return readCompactSliceAllocWithMappings(allocator, payload, &cursor, payload.len, mappings);
}

pub const VarUIntError = error{InvalidVarUInt};

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

fn inspectMappingFingerprint(mapping_bytes: []const u8) LayoutError!u32 {
    if (mapping_bytes.len < 4) return error.InvalidDictionaryFile;
    return std.mem.readInt(u32, mapping_bytes[0..4], .little);
}

fn readFixedU32(bytes: []const u8, cursor: *usize) LayoutError!u32 {
    if (cursor.* + 4 > bytes.len) return error.InvalidDictionaryFile;
    const value = @as(u32, bytes[cursor.*]) |
        (@as(u32, bytes[cursor.* + 1]) << 8) |
        (@as(u32, bytes[cursor.* + 2]) << 16) |
        (@as(u32, bytes[cursor.* + 3]) << 24);
    cursor.* += 4;
    return value;
}

fn readFixedU16(bytes: []const u8, cursor: *usize) LayoutError!u16 {
    if (cursor.* + 2 > bytes.len) return error.InvalidDictionaryFile;
    const value = @as(u16, bytes[cursor.*]) |
        (@as(u16, bytes[cursor.* + 1]) << 8);
    cursor.* += 2;
    return value;
}

fn readMappingString(bytes: []const u8, cursor: *usize) LayoutError![]const u8 {
    return readLengthPrefixedSlice(bytes, cursor, bytes.len) catch return error.InvalidDictionaryFile;
}

fn readCompactSliceAllocWithMappings(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
    limit: usize,
    mappings: compact.RuntimeMappings,
) (std.mem.Allocator.Error || PayloadError)![]u8 {
    const encoded = readLengthPrefixedSlice(bytes, cursor, limit) catch return error.InvalidEncoding;
    return compact.decodeAllocWithMappings(allocator, encoded, mappings) catch return error.InvalidEncoding;
}

fn readLengthPrefixedSlice(bytes: []const u8, cursor: *usize, limit: usize) PayloadError![]const u8 {
    const len_u64 = readVarUInt(bytes, cursor, limit) catch return error.InvalidEncoding;
    const len = std.math.cast(usize, len_u64) orelse return error.InvalidEncoding;
    if (cursor.* > limit or len > limit - cursor.*) return error.InvalidEncoding;
    const start = cursor.*;
    cursor.* += len;
    return bytes[start .. start + len];
}
