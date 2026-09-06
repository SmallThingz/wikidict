const std = @import("std");

// This is the decompressed logical blob format. Transport/storage compression is
// intentionally external so terminal, browser, and cache consumers all see the
// same byte layout after decompression.
pub const magic = "WIKBLB02";
pub const version: u8 = 2;

pub const BlobKind = enum(u8) {
    language = 1,
    thesaurus = 2,
    citations = 3,
    reconstruction = 4,
    rhymes = 5,
    sign_gloss = 6,
};

pub const Header = extern struct {
    magic_bytes: [8]u8,
    kind: u8,
    flags: u8,
    metadata_len: u16,
    record_count: u32,
    records_len: u32,

    pub fn init(kind: BlobKind, metadata_len: u16, record_count: u32, records_len: u32) Header {
        return .{
            .magic_bytes = magic.*,
            .kind = @intFromEnum(kind),
            .flags = 0,
            .metadata_len = metadata_len,
            .record_count = record_count,
            .records_len = records_len,
        };
    }
};

pub const header_len: usize = magic.len + 1 + 1 + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u32);

pub fn encodeHeader(header: Header) [header_len]u8 {
    var out: [header_len]u8 = undefined;
    @memcpy(out[0..magic.len], &header.magic_bytes);
    out[8] = header.kind;
    out[9] = header.flags;
    std.mem.writeInt(u16, out[10..12], header.metadata_len, .little);
    std.mem.writeInt(u32, out[12..16], header.record_count, .little);
    std.mem.writeInt(u32, out[16..20], header.records_len, .little);
    return out;
}

fn decodeHeader(bytes: []const u8) error{InvalidBlob}!Header {
    if (bytes.len < header_len) return error.InvalidBlob;
    return .{
        .magic_bytes = bytes[0..magic.len].*,
        .kind = bytes[8],
        .flags = bytes[9],
        .metadata_len = std.mem.readInt(u16, bytes[10..12], .little),
        .record_count = std.mem.readInt(u32, bytes[12..16], .little),
        .records_len = std.mem.readInt(u32, bytes[16..20], .little),
    };
}

pub const RecordInput = struct {
    title: []const u8,
    payload: []const u8,
};

pub const RecordView = struct {
    index: u32,
    title: []const u8,
    payload: []const u8,
};

pub const LanguageMetadata = struct {
    code: []const u8,
    heading: []const u8,
};

pub const RecordIterator = struct {
    blob: BlobView,
    index: u32 = 0,

    pub fn next(self: *RecordIterator) error{InvalidBlob}!?RecordView {
        if (self.index >= self.blob.header.record_count) return null;
        const record = try self.blob.recordAt(self.index);
        self.index += 1;
        return record;
    }
};

pub const BlobView = struct {
    bytes: []const u8,
    header: Header,
    kind: BlobKind,
    metadata: []const u8,
    offsets: []const u8,
    records: []const u8,

    pub fn recordAt(self: BlobView, index: u32) error{InvalidBlob}!RecordView {
        if (index >= self.header.record_count) return error.InvalidBlob;
        const start = try self.offsetAt(index);
        const end = try self.offsetAt(index + 1);
        if (start >= end or end > self.records.len) return error.InvalidBlob;
        const record = self.records[start..end];
        const title_end = std.mem.indexOfScalar(u8, record, 0) orelse return error.InvalidBlob;
        if (title_end == 0) return error.InvalidBlob;
        return .{
            .index = index,
            .title = record[0..title_end],
            .payload = record[title_end + 1 ..],
        };
    }

    pub fn iterator(self: BlobView) RecordIterator {
        return .{ .blob = self };
    }

    pub fn find(self: BlobView, title: []const u8) error{InvalidBlob}!?RecordView {
        var lo: u32 = 0;
        var hi = self.header.record_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const record = try self.recordAt(mid);
            switch (std.mem.order(u8, record.title, title)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return record,
            }
        }
        return null;
    }

    pub fn languageMetadata(self: BlobView) error{InvalidBlob}!LanguageMetadata {
        if (self.kind != .language) return error.InvalidBlob;
        var cursor: usize = 0;
        const code = try readNulField(self.metadata, &cursor);
        const heading = try readNulField(self.metadata, &cursor);
        if (cursor != self.metadata.len or heading.len == 0) return error.InvalidBlob;
        return .{ .code = code, .heading = heading };
    }

    pub fn validate(self: BlobView) error{InvalidBlob}!void {
        if (try self.offsetAt(0) != 0 or try self.offsetAt(self.header.record_count) != self.records.len) return error.InvalidBlob;
        var previous_end: usize = 0;
        var previous_title: ?[]const u8 = null;
        var index: u32 = 0;
        while (index < self.header.record_count) : (index += 1) {
            const start = try self.offsetAt(index);
            const end = try self.offsetAt(index + 1);
            if (start != previous_end or start >= end) return error.InvalidBlob;
            const record = try self.recordAt(index);
            if (previous_title) |previous| {
                if (std.mem.order(u8, previous, record.title) != .lt) return error.InvalidBlob;
            }
            previous_title = record.title;
            previous_end = end;
        }
        if (self.kind == .language) _ = try self.languageMetadata();
    }

    fn offsetAt(self: BlobView, index: u32) error{InvalidBlob}!usize {
        if (index > self.header.record_count) return error.InvalidBlob;
        const pos = std.math.mul(usize, @as(usize, index), @sizeOf(u32)) catch return error.InvalidBlob;
        const end = std.math.add(usize, pos, @sizeOf(u32)) catch return error.InvalidBlob;
        if (end > self.offsets.len) return error.InvalidBlob;
        return std.mem.readInt(u32, self.offsets[pos..end][0..4], .little);
    }
};

pub fn buildLanguageMetadataAlloc(allocator: std.mem.Allocator, code: []const u8, heading: []const u8) ![]u8 {
    if (heading.len == 0 or std.mem.indexOfScalar(u8, code, 0) != null or std.mem.indexOfScalar(u8, heading, 0) != null) {
        return error.InvalidMetadata;
    }
    const size = std.math.add(usize, code.len + 1, heading.len + 1) catch return error.BlobTooBig;
    const out = try allocator.alloc(u8, size);
    @memcpy(out[0..code.len], code);
    out[code.len] = 0;
    const heading_start = code.len + 1;
    @memcpy(out[heading_start .. heading_start + heading.len], heading);
    out[out.len - 1] = 0;
    return out;
}

pub fn buildAlloc(
    allocator: std.mem.Allocator,
    kind: BlobKind,
    metadata: []const u8,
    records: []const RecordInput,
) ![]u8 {
    const metadata_len = std.math.cast(u16, metadata.len) orelse return error.BlobTooBig;
    const record_count = std.math.cast(u32, records.len) orelse return error.BlobTooBig;

    var records_len: usize = 0;
    var previous_title: ?[]const u8 = null;
    for (records) |record| {
        if (record.title.len == 0 or std.mem.indexOfScalar(u8, record.title, 0) != null) return error.InvalidRecord;
        if (previous_title) |previous| {
            if (std.mem.order(u8, previous, record.title) != .lt) return error.UnsortedRecords;
        }
        previous_title = record.title;
        records_len = std.math.add(usize, records_len, record.title.len + 1) catch return error.BlobTooBig;
        records_len = std.math.add(usize, records_len, record.payload.len) catch return error.BlobTooBig;
    }
    const records_len_u32 = std.math.cast(u32, records_len) orelse return error.BlobTooBig;
    const offset_count = std.math.add(usize, records.len, 1) catch return error.BlobTooBig;
    const offsets_len = std.math.mul(usize, offset_count, @sizeOf(u32)) catch return error.BlobTooBig;
    const prefix_len = std.math.add(usize, header_len + metadata.len, offsets_len) catch return error.BlobTooBig;
    const total_len = std.math.add(usize, prefix_len, records_len) catch return error.BlobTooBig;

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    const header = encodeHeader(Header.init(kind, metadata_len, record_count, records_len_u32));
    @memcpy(out[0..header_len], &header);
    @memcpy(out[header_len .. header_len + metadata.len], metadata);

    const offsets_start = header_len + metadata.len;
    const records_start = offsets_start + offsets_len;
    var record_cursor: usize = 0;
    for (records, 0..) |record, index| {
        writeOffset(out[offsets_start .. offsets_start + offsets_len], index, record_cursor);
        const dest = records_start + record_cursor;
        @memcpy(out[dest .. dest + record.title.len], record.title);
        out[dest + record.title.len] = 0;
        const payload_start = dest + record.title.len + 1;
        @memcpy(out[payload_start .. payload_start + record.payload.len], record.payload);
        record_cursor += record.title.len + 1 + record.payload.len;
    }
    writeOffset(out[offsets_start .. offsets_start + offsets_len], records.len, record_cursor);
    std.debug.assert(record_cursor == records_len);
    return out;
}

/// Opens a blob after validating framing, endpoint offsets, and language metadata.
/// This skips the O(record_count) ordering scan; callers must already trust the
/// blob's integrity (for example via a verified external hash) or call validate().
pub fn openTrusted(bytes: []const u8) error{InvalidBlob}!BlobView {
    const header = try decodeHeader(bytes);
    if (!std.mem.eql(u8, &header.magic_bytes, magic) or header.flags != 0) return error.InvalidBlob;
    const kind: BlobKind = switch (header.kind) {
        @intFromEnum(BlobKind.language) => .language,
        @intFromEnum(BlobKind.thesaurus) => .thesaurus,
        @intFromEnum(BlobKind.citations) => .citations,
        @intFromEnum(BlobKind.reconstruction) => .reconstruction,
        @intFromEnum(BlobKind.rhymes) => .rhymes,
        @intFromEnum(BlobKind.sign_gloss) => .sign_gloss,
        else => return error.InvalidBlob,
    };
    const offset_count = std.math.add(usize, @as(usize, header.record_count), 1) catch return error.InvalidBlob;
    const offsets_len = std.math.mul(usize, offset_count, @sizeOf(u32)) catch return error.InvalidBlob;
    const metadata_end = std.math.add(usize, header_len, header.metadata_len) catch return error.InvalidBlob;
    const records_start = std.math.add(usize, metadata_end, offsets_len) catch return error.InvalidBlob;
    const expected_end = std.math.add(usize, records_start, header.records_len) catch return error.InvalidBlob;
    if (expected_end != bytes.len) return error.InvalidBlob;

    const view: BlobView = .{
        .bytes = bytes,
        .header = header,
        .kind = kind,
        .metadata = bytes[header_len..metadata_end],
        .offsets = bytes[metadata_end..records_start],
        .records = bytes[records_start..expected_end],
    };
    if (try view.offsetAt(0) != 0 or try view.offsetAt(header.record_count) != view.records.len) return error.InvalidBlob;
    if (kind == .language) _ = try view.languageMetadata();
    return view;
}

pub fn inspect(bytes: []const u8) error{InvalidBlob}!BlobView {
    const view = try openTrusted(bytes);
    try view.validate();
    return view;
}

fn writeOffset(bytes: []u8, index: usize, value: usize) void {
    const value_u32: u32 = @intCast(value);
    const pos = index * @sizeOf(u32);
    std.mem.writeInt(u32, bytes[pos .. pos + 4][0..4], value_u32, .little);
}

fn readNulField(bytes: []const u8, cursor: *usize) error{InvalidBlob}![]const u8 {
    if (cursor.* > bytes.len) return error.InvalidBlob;
    const end = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidBlob;
    const field = bytes[cursor.*..end];
    cursor.* = end + 1;
    return field;
}

test "blob header wire encoding is explicitly little endian" {
    const header = Header.init(.rhymes, 0x1234, 0x01020304, 0xa1b2c3d4);
    const encoded = encodeHeader(header);
    try std.testing.expectEqualSlices(u8, &.{
        'W',                           'I',  'K',  'B',  'L',  'B',  '0',  '2',
        @intFromEnum(BlobKind.rhymes), 0,    0x34, 0x12, 0x04, 0x03, 0x02, 0x01,
        0xd4,                          0xc3, 0xb2, 0xa1,
    }, &encoded);
    const decoded = try decodeHeader(&encoded);
    try std.testing.expectEqual(header.metadata_len, decoded.metadata_len);
    try std.testing.expectEqual(header.record_count, decoded.record_count);
    try std.testing.expectEqual(header.records_len, decoded.records_len);
}

test "blob format exposes sorted zero-copy records and language metadata" {
    const metadata = try buildLanguageMetadataAlloc(std.testing.allocator, "", "English");
    defer std.testing.allocator.free(metadata);
    const payload_a = [_]u8{ 0, 1, 2, 0, 3 };
    const payload_b = [_]u8{ 9, 8, 7 };
    const encoded = try buildAlloc(std.testing.allocator, .language, metadata, &.{
        .{ .title = "apple", .payload = &payload_a },
        .{ .title = "banana", .payload = &payload_b },
    });
    defer std.testing.allocator.free(encoded);

    const blob = try inspect(encoded);
    const language = try blob.languageMetadata();
    try std.testing.expectEqualStrings("", language.code);
    try std.testing.expectEqualStrings("English", language.heading);
    const apple = (try blob.find("apple")).?;
    try std.testing.expectEqualSlices(u8, &payload_a, apple.payload);
    try std.testing.expect((try blob.find("absent")) == null);
    const banana = try blob.recordAt(1);
    try std.testing.expectEqualStrings("banana", banana.title);
    try std.testing.expectEqualSlices(u8, &payload_b, banana.payload);
    var iterator = blob.iterator();
    try std.testing.expectEqualStrings("apple", (try iterator.next()).?.title);
    try std.testing.expectEqualStrings("banana", (try iterator.next()).?.title);
    try std.testing.expect((try iterator.next()) == null);
}

test "blob format rejects malformed offsets and unsorted records" {
    const metadata = try buildLanguageMetadataAlloc(std.testing.allocator, "en", "English");
    defer std.testing.allocator.free(metadata);
    try std.testing.expectError(error.UnsortedRecords, buildAlloc(std.testing.allocator, .language, metadata, &.{
        .{ .title = "b", .payload = "1" },
        .{ .title = "a", .payload = "2" },
    }));

    const encoded = try buildAlloc(std.testing.allocator, .thesaurus, "", &.{
        .{ .title = "a", .payload = "x" },
    });
    defer std.testing.allocator.free(encoded);
    const broken = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(broken);
    const offsets_start = header_len;
    std.mem.writeInt(u32, broken[offsets_start + 4 .. offsets_start + 8][0..4], 0, .little);
    try std.testing.expectError(error.InvalidBlob, inspect(broken));
}

test "trusted blob open skips global title-order scan" {
    const encoded = try buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "aa", .payload = "1" },
        .{ .title = "bb", .payload = "2" },
    });
    defer std.testing.allocator.free(encoded);
    const broken = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(broken);

    const original = try openTrusted(broken);
    const first = try original.recordAt(0);
    const title_offset = @intFromPtr(first.title.ptr) - @intFromPtr(broken.ptr);
    broken[title_offset] = 'z';

    const trusted = try openTrusted(broken);
    try std.testing.expectEqualStrings("za", (try trusted.recordAt(0)).title);
    try std.testing.expectError(error.InvalidBlob, trusted.validate());
    try std.testing.expectError(error.InvalidBlob, inspect(broken));
}

test "blob offset bounds reject terminal 32-bit overflow" {
    if (@sizeOf(usize) != 4) return error.SkipZigTest;
    const view: BlobView = .{
        .bytes = &.{},
        .header = Header.init(.citations, 0, std.math.maxInt(u32), 0),
        .kind = .citations,
        .metadata = &.{},
        .offsets = &.{},
        .records = &.{},
    };
    try std.testing.expectError(error.InvalidBlob, view.offsetAt(std.math.maxInt(u32)));
}
