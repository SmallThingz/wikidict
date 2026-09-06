const std = @import("std");
const encoder = @import("encoder");

const format = encoder.blob_format;
const language = encoder.language_blob_encoding;
const thesaurus = encoder.thesaurus_encoding;
const reconstruction = encoder.reconstruction_encoding;
const rhymes = encoder.rhymes_encoding;

pub const LanguageRecordView = struct {
    title: []const u8,
    payload: []const u8,
    metadata: format.LanguageMetadata,

    pub fn sectionIterator(self: LanguageRecordView) error{InvalidEncoding}!language.SectionIterator {
        return language.SectionIterator.init(self.payload, .{
            .heading = self.metadata.heading,
            .code = self.metadata.code,
        });
    }
};

pub const ThesaurusRecordView = struct {
    title: []const u8,
    payload: []const u8,

    pub fn recordIterator(self: ThesaurusRecordView) error{InvalidEncoding}!thesaurus.Iterator {
        return thesaurus.iterator(self.payload);
    }
};

pub const RhymesRecordView = struct {
    title: []const u8,
    payload: []const u8,

    pub fn recordIterator(self: RhymesRecordView) error{InvalidEncoding}!rhymes.Iterator {
        return rhymes.iterator(self.payload);
    }
};

pub const ReconstructionRecordView = struct {
    title: []const u8,
    payload: []const u8,

    pub fn inspect(self: ReconstructionRecordView) error{InvalidEncoding}!reconstruction.View {
        return reconstruction.inspect(self.payload, self.title);
    }

    pub fn sectionIterator(self: ReconstructionRecordView) error{InvalidEncoding}!?language.SectionIterator {
        return (try self.inspect()).sectionIterator();
    }
};

pub const RawRecordView = struct {
    title: []const u8,
    source: []const u8,
};

pub const RecordView = union(format.BlobKind) {
    language: LanguageRecordView,
    thesaurus: ThesaurusRecordView,
    citations: RawRecordView,
    reconstruction: ReconstructionRecordView,
    rhymes: RhymesRecordView,
    sign_gloss: RawRecordView,

    pub fn kind(self: RecordView) format.BlobKind {
        return std.meta.activeTag(self);
    }

    pub fn title(self: RecordView) []const u8 {
        return switch (self) {
            .language => |record| record.title,
            .thesaurus => |record| record.title,
            .citations => |record| record.title,
            .reconstruction => |record| record.title,
            .rhymes => |record| record.title,
            .sign_gloss => |record| record.title,
        };
    }
};

pub const RecordIterator = struct {
    blob: BlobView,
    index: u32 = 0,

    pub fn next(self: *RecordIterator) error{InvalidBlob}!?RecordView {
        if (self.index >= self.blob.raw.header.record_count) return null;
        const raw_record = try self.blob.raw.recordAt(self.index);
        self.index += 1;
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

    pub fn recordCount(self: BlobView) u32 {
        return self.raw.header.record_count;
    }

    pub fn languageMetadata(self: BlobView) ?format.LanguageMetadata {
        return self.language_metadata;
    }

    pub fn recordAt(self: BlobView, index: u32) error{InvalidBlob}!RecordView {
        return self.wrap(try self.raw.recordAt(index));
    }

    pub fn find(self: BlobView, title: []const u8) error{InvalidBlob}!?RecordView {
        const raw_record = (try self.raw.find(title)) orelse return null;
        return self.wrap(raw_record);
    }

    pub fn iterator(self: BlobView) RecordIterator {
        return .{ .blob = self };
    }

    fn wrap(self: BlobView, record: format.RecordView) RecordView {
        return switch (self.raw.kind) {
            .language => .{ .language = .{
                .title = record.title,
                .payload = record.payload,
                .metadata = self.language_metadata.?,
            } },
            .thesaurus => .{ .thesaurus = .{ .title = record.title, .payload = record.payload } },
            .citations => .{ .citations = .{ .title = record.title, .source = record.payload } },
            .reconstruction => .{ .reconstruction = .{ .title = record.title, .payload = record.payload } },
            .rhymes => .{ .rhymes = .{ .title = record.title, .payload = record.payload } },
            .sign_gloss => .{ .sign_gloss = .{ .title = record.title, .source = record.payload } },
        };
    }
};

test "typed blob reader exposes borrowed language sections" {
    const metadata = try format.buildLanguageMetadataAlloc(std.testing.allocator, "en", "English");
    defer std.testing.allocator.free(metadata);
    const source = "==English==\n===Noun===\n# [[cat]]\n";
    const payload = try language.encodeAlloc(std.testing.allocator, source, .{ .heading = "English", .code = "en" });
    defer std.testing.allocator.free(payload);
    const bytes = try format.buildAlloc(std.testing.allocator, .language, metadata, &.{
        .{ .title = "cat", .payload = payload },
    });
    defer std.testing.allocator.free(bytes);

    const blob = try BlobView.inspect(bytes);
    try std.testing.expectEqual(format.BlobKind.language, blob.kind());
    try std.testing.expectEqual(@as(u32, 1), blob.recordCount());
    try std.testing.expectEqualStrings("English", blob.languageMetadata().?.heading);
    const record = (try blob.find("cat")).?;
    try std.testing.expectEqual(format.BlobKind.language, record.kind());
    try std.testing.expectEqualStrings("cat", record.title());
    switch (record) {
        .language => |entry| {
            try std.testing.expectEqualStrings("cat", entry.title);
            var sections = try entry.sectionIterator();
            try std.testing.expectEqualStrings("English", (try sections.next()).?.title);
            try std.testing.expectEqualStrings("Noun", (try sections.next()).?.title);
            try std.testing.expect((try sections.next()) == null);
        },
        else => return error.UnexpectedRecordKind,
    }
}

test "typed blob reader exposes feature-specific borrowed views" {
    const thesaurus_source = "{{ws header|cat}}\n{{ws|en|feline}}\n";
    const thesaurus_payload = try thesaurus.encodeAlloc(std.testing.allocator, thesaurus_source);
    defer std.testing.allocator.free(thesaurus_payload);
    const thesaurus_bytes = try format.buildAlloc(std.testing.allocator, .thesaurus, "", &.{
        .{ .title = "cat", .payload = thesaurus_payload },
    });
    defer std.testing.allocator.free(thesaurus_bytes);
    const thesaurus_blob = try BlobView.inspect(thesaurus_bytes);
    switch ((try thesaurus_blob.find("cat")).?) {
        .thesaurus => |entry| {
            var records = try entry.recordIterator();
            try std.testing.expectEqual(thesaurus.RecordKind.header, (try records.next()).?.kind);
            try std.testing.expectEqual(thesaurus.RecordKind.term, (try records.next()).?.kind);
            try std.testing.expect((try records.next()) == null);
        },
        else => return error.UnexpectedRecordKind,
    }

    const rhymes_source = "* {{l|en|cat}}\n";
    const rhymes_payload = try rhymes.encodeAlloc(std.testing.allocator, rhymes_source);
    defer std.testing.allocator.free(rhymes_payload);
    const rhymes_bytes = try format.buildAlloc(std.testing.allocator, .rhymes, "", &.{
        .{ .title = "English/æt", .payload = rhymes_payload },
    });
    defer std.testing.allocator.free(rhymes_bytes);
    const rhymes_blob = try BlobView.inspect(rhymes_bytes);
    switch ((try rhymes_blob.find("English/æt")).?) {
        .rhymes => |entry| {
            var records = try entry.recordIterator();
            const links = (try records.next()).?;
            try std.testing.expectEqual(rhymes.RecordKind.links, links.kind);
            try std.testing.expectEqual(@as(usize, 1), links.link_count);
        },
        else => return error.UnexpectedRecordKind,
    }

    const reconstruction_source = "{{reconstructed}}\n==Proto-Germanic==\n===Noun===\n# cat\n";
    const reconstruction_payload = try reconstruction.encodeAlloc(std.testing.allocator, reconstruction_source, "Proto-Germanic/kattuz");
    defer std.testing.allocator.free(reconstruction_payload);
    const reconstruction_bytes = try format.buildAlloc(std.testing.allocator, .reconstruction, "", &.{
        .{ .title = "Proto-Germanic/kattuz", .payload = reconstruction_payload },
    });
    defer std.testing.allocator.free(reconstruction_bytes);
    const reconstruction_blob = try BlobView.inspect(reconstruction_bytes);
    switch ((try reconstruction_blob.find("Proto-Germanic/kattuz")).?) {
        .reconstruction => |entry| {
            try std.testing.expectEqual(reconstruction.Kind.language, (try entry.inspect()).kind);
            var sections = (try entry.sectionIterator()).?;
            try std.testing.expectEqualStrings("{{reconstructed}}\n", sections.preamble());
            try std.testing.expectEqualStrings("Proto-Germanic", (try sections.next()).?.title);
        },
        else => return error.UnexpectedRecordKind,
    }
}

test "typed blob reader keeps raw feature payloads borrowed" {
    const bytes = try format.buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "cat", .payload = "raw citation source" },
    });
    defer std.testing.allocator.free(bytes);
    const blob = try BlobView.inspect(bytes);
    const trusted = try BlobView.openTrusted(bytes);
    try trusted.validate();
    try std.testing.expectEqualStrings("cat", (try trusted.find("cat")).?.title());
    switch ((try blob.recordAt(0))) {
        .citations => |entry| {
            try std.testing.expectEqualStrings("cat", entry.title);
            try std.testing.expectEqualStrings("raw citation source", entry.source);
            const begin = @intFromPtr(bytes.ptr);
            const end = begin + bytes.len;
            const source_ptr = @intFromPtr(entry.source.ptr);
            try std.testing.expect(source_ptr >= begin and source_ptr < end);
        },
        else => return error.UnexpectedRecordKind,
    }
    var records = blob.iterator();
    try std.testing.expect((try records.next()) != null);
    try std.testing.expect((try records.next()) == null);
}
