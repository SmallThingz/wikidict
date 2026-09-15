const std = @import("std");
const encoder = @import("blob_encoder");
const format = encoder.blob_format;

pub const DataRecordView = struct {
    title: []const u8,
    payload: []const u8,
};

pub const LanguageRecordView = struct {
    title: []const u8,
    payload: []const u8,
    metadata: format.LanguageMetadata,
};

pub const RecordView = union(format.BlobKind) {
    language: LanguageRecordView,
    thesaurus: DataRecordView,
    citations: DataRecordView,
    reconstruction: DataRecordView,
    rhymes: DataRecordView,
    sign_gloss: DataRecordView,

    pub fn kind(self: RecordView) format.BlobKind {
        return std.meta.activeTag(self);
    }

    pub fn title(self: RecordView) []const u8 {
        return switch (self) {
            inline else => |record| record.title,
        };
    }

    pub fn payload(self: RecordView) []const u8 {
        return switch (self) {
            inline else => |record| record.payload,
        };
    }
};

pub const RecordIterator = struct {
    blob: BlobView,
    raw: format.RecordIterator,

    pub fn next(self: *RecordIterator) error{InvalidBlob}!?RecordView {
        const raw_record = (try self.raw.next()) orelse return null;
        return self.blob.wrap(raw_record);
    }
};

pub const IndexedBlobView = struct {
    blob: BlobView,
    raw: format.IndexedBlobView,

    pub fn deinit(self: *IndexedBlobView, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
    }

    pub fn recordCount(self: IndexedBlobView) usize {
        return self.raw.recordCount();
    }

    pub fn recordAt(self: IndexedBlobView, index: usize) error{InvalidBlob}!RecordView {
        return self.blob.wrap(try self.raw.recordAt(index));
    }

    pub fn find(self: IndexedBlobView, title: []const u8) error{InvalidBlob}!?RecordView {
        const raw_record = (try self.raw.find(title)) orelse return null;
        return self.blob.wrap(raw_record);
    }
};

pub const BlobView = struct {
    raw: format.BlobView,
    language_metadata: ?format.LanguageMetadata,

    pub fn inspect(bytes: []const u8) error{InvalidBlob}!BlobView {
        return fromRaw(try format.inspect(bytes));
    }

    pub fn openTrusted(bytes: []const u8) error{InvalidBlob}!BlobView {
        return fromRaw(try format.openTrusted(bytes));
    }

    fn fromRaw(raw: format.BlobView) error{InvalidBlob}!BlobView {
        return .{
            .raw = raw,
            .language_metadata = if (raw.kind == .language) try raw.languageMetadata() else null,
        };
    }

    pub fn validate(self: BlobView) error{InvalidBlob}!void {
        try self.raw.validate();
    }

    pub fn kind(self: BlobView) format.BlobKind {
        return self.raw.kind;
    }

    pub fn languageMetadata(self: BlobView) ?format.LanguageMetadata {
        return self.language_metadata;
    }

    pub fn iterator(self: BlobView) RecordIterator {
        return .{ .blob = self, .raw = self.raw.iterator() };
    }

    pub fn buildIndexAlloc(self: BlobView, allocator: std.mem.Allocator) !IndexedBlobView {
        return .{ .blob = self, .raw = try self.raw.buildIndexAlloc(allocator) };
    }

    pub fn buildTrustedIndexAlloc(self: BlobView, allocator: std.mem.Allocator) !IndexedBlobView {
        return .{ .blob = self, .raw = try self.raw.buildTrustedIndexAlloc(allocator) };
    }

    pub fn wrapRecord(self: BlobView, record: format.RecordView) RecordView {
        return self.wrap(record);
    }

    fn wrap(self: BlobView, record: format.RecordView) RecordView {
        return switch (self.raw.kind) {
            .language => .{ .language = .{
                .title = record.title,
                .payload = record.payload,
                .metadata = self.language_metadata.?,
            } },
            .thesaurus => .{ .thesaurus = .{ .title = record.title, .payload = record.payload } },
            .citations => .{ .citations = .{ .title = record.title, .payload = record.payload } },
            .reconstruction => .{ .reconstruction = .{ .title = record.title, .payload = record.payload } },
            .rhymes => .{ .rhymes = .{ .title = record.title, .payload = record.payload } },
            .sign_gloss => .{ .sign_gloss = .{ .title = record.title, .payload = record.payload } },
        };
    }
};

test "typed blob reader exposes compiled language payload and metadata" {
    const a = std.testing.allocator;
    const metadata = try format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const payload = "{\"schema\":\"dict.presentation.v1\"}";
    const bytes = try format.buildAlloc(a, .language, metadata, &.{.{ .title = "cat", .payload = payload }});
    defer a.free(bytes);

    const blob = try BlobView.inspect(bytes);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    try std.testing.expectEqualStrings("English", blob.languageMetadata().?.heading);
    const record = (try index.find("cat")).?;
    try std.testing.expectEqual(format.BlobKind.language, record.kind());
    try std.testing.expectEqualStrings("cat", record.title());
    try std.testing.expectEqualStrings(payload, record.payload());
}

test "typed blob reader exposes compiled feature payloads without source facades" {
    const a = std.testing.allocator;
    inline for (.{
        format.BlobKind.thesaurus,
        format.BlobKind.citations,
        format.BlobKind.reconstruction,
        format.BlobKind.rhymes,
        format.BlobKind.sign_gloss,
    }) |kind| {
        const payload = "{\"schema\":\"dict.presentation.v1\"}";
        const bytes = try format.buildAlloc(a, kind, "", &.{.{ .title = "cat", .payload = payload }});
        defer a.free(bytes);
        const blob = try BlobView.inspect(bytes);
        var index = try blob.buildIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("cat")).?;
        try std.testing.expectEqual(kind, record.kind());
        try std.testing.expectEqualStrings(payload, record.payload());
        const begin = @intFromPtr(bytes.ptr);
        const ptr = @intFromPtr(record.payload().ptr);
        try std.testing.expect(ptr >= begin and ptr < begin + bytes.len);
    }
}
