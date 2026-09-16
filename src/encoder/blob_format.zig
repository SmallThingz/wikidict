const std = @import("std");

// Logical, uncompressed blob format. Storage/transport compression stays external.
pub const magic = "WIKBLB08";
pub const version: u8 = 8;
pub const header_len: usize = magic.len + 1;
pub const max_varuint_len: usize = 10;

pub const BlobKind = enum(u8) {
    language = 1,
    thesaurus = 2,
    citations = 3,
    reconstruction = 4,
    rhymes = 5,
    sign_gloss = 6,
};

pub const RecordInput = struct {
    title: []const u8,
    payload: []const u8,
};

pub const RecordView = struct {
    title: []const u8,
    payload: []const u8,
};

pub const LanguageMetadata = struct {
    code: []const u8,
    heading: []const u8,
};
pub const RecordIterator = struct {
    blob: BlobView,
    cursor: usize = 0,

    pub fn next(self: *RecordIterator) error{InvalidBlob}!?RecordView {
        if (self.cursor == self.blob.records.len) return null;
        if (self.cursor > self.blob.records.len) return error.InvalidBlob;
        const parsed = try self.blob.parseRecordAt(self.cursor);
        self.cursor = parsed.next;
        return parsed.record;
    }
};

pub const IndexedBlobView = struct {
    blob: BlobView,
    offsets: []usize,

    pub fn deinit(self: *IndexedBlobView, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        self.offsets = &.{};
    }

    pub fn recordCount(self: IndexedBlobView) usize {
        return self.offsets.len;
    }

    pub fn recordAt(self: IndexedBlobView, index: usize) error{InvalidBlob}!RecordView {
        if (index >= self.offsets.len) return error.InvalidBlob;
        return (try self.blob.parseRecordAt(self.offsets[index])).record;
    }
    pub fn find(self: IndexedBlobView, title: []const u8) error{InvalidBlob}!?RecordView {
        var lo: usize = 0;
        var hi = self.offsets.len;
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
};

const ParsedRecord = struct {
    record: RecordView,
    next: usize,
};

pub const BlobView = struct {
    bytes: []const u8,
    kind: BlobKind,
    metadata: []const u8,
    records: []const u8,

    pub fn iterator(self: BlobView) RecordIterator {
        return .{ .blob = self };
    }
    pub fn languageMetadata(self: BlobView) error{InvalidBlob}!LanguageMetadata {
        if (self.kind != .language) return error.InvalidBlob;
        var cursor: usize = 0;
        const code = try readNulField(self.metadata, &cursor);
        const heading = try readNulField(self.metadata, &cursor);
        if (heading.len == 0 or cursor != self.metadata.len) return error.InvalidBlob;
        return .{ .code = code, .heading = heading };
    }

    pub fn validate(self: BlobView) error{InvalidBlob}!void {
        var cursor: usize = 0;
        var previous_title: ?[]const u8 = null;
        while (cursor < self.records.len) {
            const parsed = try self.parseRecordAt(cursor);
            if (previous_title) |previous| {
                if (std.mem.order(u8, previous, parsed.record.title) != .lt) return error.InvalidBlob;
            }
            previous_title = parsed.record.title;
            cursor = parsed.next;
        }
        if (cursor != self.records.len) return error.InvalidBlob;
        if (self.kind == .language) _ = try self.languageMetadata();
    }

    pub fn buildIndexAlloc(self: BlobView, allocator: std.mem.Allocator) !IndexedBlobView {
        return self.buildIndex(allocator, true);
    }

    pub fn buildTrustedIndexAlloc(self: BlobView, allocator: std.mem.Allocator) !IndexedBlobView {
        return self.buildIndex(allocator, false);
    }
    fn buildIndex(self: BlobView, allocator: std.mem.Allocator, validate_order: bool) !IndexedBlobView {
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(allocator);
        var cursor: usize = 0;
        var previous_title: ?[]const u8 = null;
        while (cursor < self.records.len) {
            const parsed = try self.parseRecordAt(cursor);
            if (validate_order) {
                if (previous_title) |previous| {
                    if (std.mem.order(u8, previous, parsed.record.title) != .lt) return error.InvalidBlob;
                }
                previous_title = parsed.record.title;
            }
            try offsets.append(allocator, cursor);
            cursor = parsed.next;
        }
        if (cursor != self.records.len) return error.InvalidBlob;
        return .{ .blob = self, .offsets = try offsets.toOwnedSlice(allocator) };
    }

    fn parseRecordAt(self: BlobView, start: usize) error{InvalidBlob}!ParsedRecord {
        if (start >= self.records.len) return error.InvalidBlob;
        const title_end = std.mem.indexOfScalarPos(u8, self.records, start, 0) orelse return error.InvalidBlob;
        if (title_end == start) return error.InvalidBlob;
        var cursor = title_end + 1;
        const payload_len = try readPayloadLength(self.records, &cursor);
        const payload_end = std.math.add(usize, cursor, payload_len) catch return error.InvalidBlob;
        if (payload_end > self.records.len) return error.InvalidBlob;
        return .{
            .record = .{ .title = self.records[start..title_end], .payload = self.records[cursor..payload_end] },
            .next = payload_end,
        };
    }
};
pub fn encodeHeader(kind: BlobKind) [header_len]u8 {
    var out: [header_len]u8 = undefined;
    @memcpy(out[0..magic.len], magic);
    out[magic.len] = @intFromEnum(kind);
    return out;
}

fn decodeKind(bytes: []const u8) error{InvalidBlob}!BlobKind {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidBlob;
    return switch (bytes[magic.len]) {
        @intFromEnum(BlobKind.language) => .language,
        @intFromEnum(BlobKind.thesaurus) => .thesaurus,
        @intFromEnum(BlobKind.citations) => .citations,
        @intFromEnum(BlobKind.reconstruction) => .reconstruction,
        @intFromEnum(BlobKind.rhymes) => .rhymes,
        @intFromEnum(BlobKind.sign_gloss) => .sign_gloss,
        else => error.InvalidBlob,
    };
}

pub fn encodePayloadLength(value: usize, out: *[max_varuint_len]u8) []const u8 {
    var remaining: u64 = value;
    var index: usize = 0;
    while (remaining >= 0x80) : (index += 1) {
        out[index] = @intCast((remaining & 0x7f) | 0x80);
        remaining >>= 7;
    }
    out[index] = @intCast(remaining);
    return out[0 .. index + 1];
}
fn varUIntLen(value: usize) usize {
    var remaining: u64 = value;
    var len: usize = 1;
    while (remaining >= 0x80) : (len += 1) remaining >>= 7;
    return len;
}

pub fn readPayloadLength(bytes: []const u8, cursor: *usize) error{InvalidBlob}!usize {
    const start = cursor.*;
    var shift: u6 = 0;
    var value: u64 = 0;
    while (true) {
        if (cursor.* >= bytes.len) return error.InvalidBlob;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidBlob;
        value |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) break;
        if (shift >= 63) return error.InvalidBlob;
        shift += 7;
    }
    const result = std.math.cast(usize, value) orelse return error.InvalidBlob;
    if (cursor.* - start != varUIntLen(result)) return error.InvalidBlob;
    return result;
}

pub fn validateMetadata(kind: BlobKind, metadata: []const u8) error{InvalidMetadata}!void {
    if (kind != .language) {
        if (metadata.len != 0) return error.InvalidMetadata;
        return;
    }
    var cursor: usize = 0;
    _ = readNulFieldMetadata(metadata, &cursor) catch return error.InvalidMetadata;
    const heading = readNulFieldMetadata(metadata, &cursor) catch return error.InvalidMetadata;
    if (heading.len == 0 or cursor != metadata.len) return error.InvalidMetadata;
}

pub fn validateRecordInput(record: RecordInput) error{InvalidRecord}!void {
    if (record.title.len == 0 or std.mem.indexOfScalar(u8, record.title, 0) != null) return error.InvalidRecord;
}

pub fn buildLanguageMetadataAlloc(allocator: std.mem.Allocator, code: []const u8, heading: []const u8) ![]u8 {
    if (heading.len == 0 or std.mem.indexOfScalar(u8, code, 0) != null or std.mem.indexOfScalar(u8, heading, 0) != null) {
        return error.InvalidMetadata;
    }
    const code_part = std.math.add(usize, code.len, 1) catch return error.BlobTooBig;
    const heading_part = std.math.add(usize, heading.len, 1) catch return error.BlobTooBig;
    const size = std.math.add(usize, code_part, heading_part) catch return error.BlobTooBig;
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
    try validateMetadata(kind, metadata);
    var total_len = std.math.add(usize, header_len, metadata.len) catch return error.BlobTooBig;
    var previous_title: ?[]const u8 = null;
    for (records) |record| {
        try validateRecordInput(record);
        if (previous_title) |previous| {
            if (std.mem.order(u8, previous, record.title) != .lt) return error.UnsortedRecords;
        }
        previous_title = record.title;
        total_len = std.math.add(usize, total_len, record.title.len + 1) catch return error.BlobTooBig;
        total_len = std.math.add(usize, total_len, varUIntLen(record.payload.len)) catch return error.BlobTooBig;
        total_len = std.math.add(usize, total_len, record.payload.len) catch return error.BlobTooBig;
    }

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    const header = encodeHeader(kind);
    @memcpy(out[0..header_len], &header);
    @memcpy(out[header_len .. header_len + metadata.len], metadata);
    var cursor = header_len + metadata.len;
    for (records) |record| {
        @memcpy(out[cursor .. cursor + record.title.len], record.title);
        cursor += record.title.len;
        out[cursor] = 0;
        cursor += 1;
        var length_buf: [max_varuint_len]u8 = undefined;
        const length_bytes = encodePayloadLength(record.payload.len, &length_buf);
        @memcpy(out[cursor .. cursor + length_bytes.len], length_bytes);
        cursor += length_bytes.len;
        @memcpy(out[cursor .. cursor + record.payload.len], record.payload);
        cursor += record.payload.len;
    }
    std.debug.assert(cursor == out.len);
    return out;
}

pub fn openTrusted(bytes: []const u8) error{InvalidBlob}!BlobView {
    const kind = try decodeKind(bytes);
    var records_start = header_len;
    if (kind == .language) {
        var cursor = records_start;
        _ = try readNulField(bytes, &cursor);
        const heading = try readNulField(bytes, &cursor);
        if (heading.len == 0) return error.InvalidBlob;
        records_start = cursor;
    }
    return .{
        .bytes = bytes,
        .kind = kind,
        .metadata = bytes[header_len..records_start],
        .records = bytes[records_start..],
    };
}
pub fn inspect(bytes: []const u8) error{InvalidBlob}!BlobView {
    const view = try openTrusted(bytes);
    try view.validate();
    return view;
}

fn readNulField(bytes: []const u8, cursor: *usize) error{InvalidBlob}![]const u8 {
    if (cursor.* > bytes.len) return error.InvalidBlob;
    const end = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidBlob;
    const field = bytes[cursor.*..end];
    cursor.* = end + 1;
    return field;
}

fn readNulFieldMetadata(bytes: []const u8, cursor: *usize) error{InvalidMetadata}![]const u8 {
    if (cursor.* > bytes.len) return error.InvalidMetadata;
    const end = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidMetadata;
    const field = bytes[cursor.*..end];
    cursor.* = end + 1;
    return field;
}

test "data blob header carries only v8 magic and kind" {
    const encoded = encodeHeader(.rhymes);
    try std.testing.expectEqualSlices(u8, &.{
        'W', 'I', 'K', 'B', 'L', 'B', '0', '8', @intFromEnum(BlobKind.rhymes),
    }, encoded[0..header_len]);
    try std.testing.expectEqual(BlobKind.rhymes, try decodeKind(&encoded));
}

test "data blob stores only necessary record framing" {
    const encoded = try buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "a", .payload = "x" },
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, "WIKBLB08\x03a\x00\x01x", encoded);
}
test "data blob builds runtime index over borrowed records" {
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
    try std.testing.expectEqualStrings("English", language.heading);
    var index = try blob.buildTrustedIndexAlloc(std.testing.allocator);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), index.recordCount());
    try std.testing.expectEqualSlices(u8, &payload_a, (try index.find("apple")).?.payload);
    try std.testing.expect((try index.find("absent")) == null);
    try std.testing.expectEqualStrings("banana", (try index.recordAt(1)).title);

    var iterator = blob.iterator();
    try std.testing.expectEqualStrings("apple", (try iterator.next()).?.title);
    try std.testing.expectEqualStrings("banana", (try iterator.next()).?.title);
    try std.testing.expect((try iterator.next()) == null);
}
test "data blob rejects malformed framing and unsorted records" {
    try std.testing.expectError(error.UnsortedRecords, buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "b", .payload = "1" },
        .{ .title = "a", .payload = "2" },
    }));

    const encoded = try buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "a", .payload = "x" },
    });
    defer std.testing.allocator.free(encoded);
    const broken = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(broken);
    const length_pos = header_len + 2;
    broken[length_pos] = 127;
    try std.testing.expectError(error.InvalidBlob, inspect(broken));
}

test "trusted open skips title-order scan while runtime index can validate it" {
    const encoded = try buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "aa", .payload = "1" },
        .{ .title = "bb", .payload = "2" },
    });
    defer std.testing.allocator.free(encoded);
    const broken = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(broken);
    broken[header_len] = 'z';

    const trusted = try openTrusted(broken);
    var trusted_index = try trusted.buildTrustedIndexAlloc(std.testing.allocator);
    defer trusted_index.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("za", (try trusted_index.recordAt(0)).title);
    try std.testing.expectError(error.InvalidBlob, trusted.validate());
    try std.testing.expectError(error.InvalidBlob, trusted.buildIndexAlloc(std.testing.allocator));
}
test "data blob rejects non-canonical payload lengths" {
    const broken = [_]u8{
        'W', 'I', 'K',  'B',  'L', 'B', '0', '5', @intFromEnum(BlobKind.citations),
        'a', 0,   0x81, 0x00, 'x',
    };
    try std.testing.expectError(error.InvalidBlob, inspect(&broken));
}

test "data blob metadata is semantic rather than length-indexed" {
    const metadata = try buildLanguageMetadataAlloc(std.testing.allocator, "en", "English");
    defer std.testing.allocator.free(metadata);
    const encoded = try buildAlloc(std.testing.allocator, .language, metadata, &.{});
    defer std.testing.allocator.free(encoded);
    const blob = try inspect(encoded);
    const language = try blob.languageMetadata();
    try std.testing.expectEqualStrings("en", language.code);
    try std.testing.expectEqualStrings("English", language.heading);
    try std.testing.expectEqual(@as(usize, header_len + metadata.len), encoded.len);
    try std.testing.expectError(error.InvalidMetadata, buildAlloc(std.testing.allocator, .citations, "x", &.{}));
}

test "data blob empty stream needs no runtime index storage" {
    const bytes = encodeHeader(.citations);
    const blob = try inspect(&bytes);
    var records = blob.iterator();
    try std.testing.expect((try records.next()) == null);
    var index = try blob.buildIndexAlloc(std.testing.allocator);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), index.recordCount());
    try std.testing.expect((try index.find("absent")) == null);
    try std.testing.expectError(error.InvalidBlob, index.recordAt(0));
}

test "data blob payload lengths round trip at integer boundaries" {
    const values = [_]usize{ 0, 1, 127, 128, 16383, 16384, std.math.maxInt(usize) };
    for (values) |value| {
        var buffer: [max_varuint_len]u8 = undefined;
        const encoded = encodePayloadLength(value, &buffer);
        var cursor: usize = 0;
        try std.testing.expectEqual(value, try readPayloadLength(encoded, &cursor));
        try std.testing.expectEqual(encoded.len, cursor);
    }
    var cursor: usize = 0;
    try std.testing.expectError(error.InvalidBlob, readPayloadLength(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02 }, &cursor));
    if (@sizeOf(usize) == 4) {
        cursor = 0;
        try std.testing.expectError(error.InvalidBlob, readPayloadLength(&.{ 0x80, 0x80, 0x80, 0x80, 0x10 }, &cursor));
    }
}

test "data blob rejects old magic and malformed record framing" {
    const invalid = [_][]const u8{
        "WIKBLB02\x03",
        "WIKBLB03\x03",
        "WIKBLB04\x00",
        "WIKBLB04\x01\x00\x00",
        "WIKBLB04\x03unterminated",
        "WIKBLB04\x03\x00\x00",
        "WIKBLB04\x03a\x00",
        "WIKBLB04\x03a\x00\x80",
        "WIKBLB04\x03a\x00\x80\x00",
        "WIKBLB04\x03a\x00\x02x",
        "WIKBLB04\x03b\x00\x00a\x00\x00",
        "WIKBLB04\x03a\x00\x00a\x00\x00",
        "WIKBLB06\x03a\x00\x00",
        "WIKBLB07\x03a\x00\x00",
    };
    for (invalid) |bytes| {
        try std.testing.expectError(error.InvalidBlob, inspect(bytes));
        if (openTrusted(bytes)) |blob| {
            try std.testing.expectError(error.InvalidBlob, blob.buildIndexAlloc(std.testing.allocator));
        } else |err| try std.testing.expectEqual(error.InvalidBlob, err);
    }
}

fn testIndexAllocationFailures(allocator: std.mem.Allocator) !void {
    const blob = try openTrusted("WIKBLB08\x03a\x00\x01xb\x00\x00");
    var index = try blob.buildIndexAlloc(allocator);
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), index.recordCount());
}

test "data blob runtime index cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testIndexAllocationFailures, .{});
}
