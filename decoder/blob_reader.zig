const std = @import("std");
const encoder = @import("blob_encoder");

const format = encoder.blob_format;
const language = encoder.language_blob_encoding;
const thesaurus = encoder.thesaurus_encoding;
const reconstruction = encoder.reconstruction_encoding;
const rhymes = encoder.rhymes_encoding;

pub const LanguageRecordView = struct {
    symbols_required: bool = false,
    title: []const u8,
    payload: []const u8,
    metadata: format.LanguageMetadata,

    pub fn sectionIterator(self: LanguageRecordView) error{InvalidEncoding}!language.SectionIterator {
        if (self.symbols_required) return error.InvalidEncoding;
        return language.SectionIterator.init(self.payload, .{
            .heading = self.metadata.heading,
            .code = self.metadata.code,
        });
    }
};

pub const ThesaurusRecordView = struct {
    symbols_required: bool = false,
    title: []const u8,
    payload: []const u8,

    pub fn recordIterator(self: ThesaurusRecordView) error{InvalidEncoding}!thesaurus.Iterator {
        if (self.symbols_required) return error.InvalidEncoding;
        return thesaurus.iterator(self.payload);
    }
};

pub const RhymesRecordView = struct {
    symbols_required: bool = false,
    title: []const u8,
    payload: []const u8,

    pub fn recordIterator(self: RhymesRecordView) error{InvalidEncoding}!rhymes.Iterator {
        if (self.symbols_required) return error.InvalidEncoding;
        return rhymes.iterator(self.payload);
    }
};

pub const ReconstructionRecordView = struct {
    symbols_required: bool = false,
    title: []const u8,
    payload: []const u8,

    pub fn inspect(self: ReconstructionRecordView) error{InvalidEncoding}!reconstruction.View {
        if (self.symbols_required) return error.InvalidEncoding;
        return reconstruction.inspect(self.payload, self.title);
    }

    pub fn sectionIterator(self: ReconstructionRecordView) error{InvalidEncoding}!?language.SectionIterator {
        return (try self.inspect()).sectionIterator();
    }
};

pub const RawRecordView = struct {
    symbols_required: bool = false,
    title: []const u8,
    source: []const u8,
};

pub const SupplementRecordView = struct {
    symbols_required: bool = false,
    title: []const u8,
    payload: []const u8,
    metadata: format.LanguageMetadata,
    family: format.PartKind,
};
pub const RecordView = union(format.BlobKind) {
    language: LanguageRecordView,
    thesaurus: ThesaurusRecordView,
    citations: RawRecordView,
    reconstruction: ReconstructionRecordView,
    rhymes: RhymesRecordView,
    sign_gloss: RawRecordView,
    supplement: SupplementRecordView,
    symbols: RawRecordView,
    templates: RawRecordView,
    redirects: RawRecordView,
    pages: RawRecordView,

    pub fn needsSymbols(self: RecordView) bool {
        return switch (self) {
            inline else => |r| r.symbols_required,
        };
    }
    pub fn payloadBytes(self: RecordView) []const u8 {
        return switch (self) {
            inline else => |r| if (@hasField(@TypeOf(r), "payload")) r.payload else r.source,
        };
    }
    /// Called only after the shared catalog has validated and rebound this payload.
    pub fn withBoundPayload(self: RecordView, bytes: []const u8) RecordView {
        var record = self;
        switch (record) {
            inline else => |*r| {
                if (@hasField(@TypeOf(r.*), "payload")) r.payload = bytes else r.source = bytes;
                r.symbols_required = false;
            },
        }
        return record;
    }
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
            .symbols, .templates, .redirects, .pages => |record| record.title,
            .supplement => |record| record.title,
        };
    }
};

pub const BoundRecord = struct {
    allocator: std.mem.Allocator,
    record: RecordView,
    owned: ?[]u8 = null,
    pub fn deinit(self: *BoundRecord) void {
        if (self.owned) |bytes| self.allocator.free(bytes);
        self.* = undefined;
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
            .language_metadata = if (raw.kind == .language or raw.kind == .supplement) try raw.languageMetadata() else null,
        };
    }

    /// Portable, explicit binding. Returned storage is transient and must outlive
    /// its borrowed semantic views; it never becomes a persisted lookup index.
    pub fn bindRecordAlloc(self: BlobView, a: std.mem.Allocator, record: RecordView, names: encoder.call_symbols.Names) !BoundRecord {
        if (record.kind() != self.kind()) return error.UnexpectedBlobKind;
        switch (record.kind()) {
            .symbols, .templates, .redirects => return error.UseRuntimeArtifactReader,
            else => {},
        }
        if (!record.needsSymbols()) return .{ .allocator = a, .record = record };
        if (!std.mem.eql(u8, &self.raw.binding_id, &names.digest())) return error.SymbolIdentityMismatch;
        const bytes = try encoder.call_symbols.decodeAlloc(a, record.payloadBytes(), names);
        return .{ .allocator = a, .record = record.withBoundPayload(bytes orelse record.payloadBytes()), .owned = bytes };
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
        var result: RecordView = switch (self.raw.kind) {
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
            .symbols => .{ .symbols = .{ .title = record.title, .source = record.payload } },
            .templates => .{ .templates = .{ .title = record.title, .source = record.payload } },
            .redirects => .{ .redirects = .{ .title = record.title, .source = record.payload } },
            .pages => .{ .pages = .{ .title = record.title, .source = record.payload } },
            .supplement => .{ .supplement = .{ .title = record.title, .payload = record.payload, .metadata = self.language_metadata.?, .family = self.raw.supplementKind() catch unreachable } },
        };
        const required = self.raw.symbolic and std.mem.indexOfScalar(u8, record.payload, encoder.call_symbols.marker) != null;
        switch (result) {
            inline else => |*r| {
                r.symbols_required = required;
            },
        }
        return result;
    }
};

test "typed blob reader exposes borrowed language sections through runtime index" {
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
    var index = try blob.buildTrustedIndexAlloc(std.testing.allocator);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(format.BlobKind.language, blob.kind());
    try std.testing.expectEqual(@as(usize, 1), index.recordCount());
    try std.testing.expectEqualStrings("English", blob.languageMetadata().?.heading);
    const record = (try index.find("cat")).?;
    try std.testing.expectEqual(format.BlobKind.language, record.kind());
    try std.testing.expectEqualStrings("cat", record.title());
    switch (record) {
        .language => |entry| {
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
    var thesaurus_index = try thesaurus_blob.buildTrustedIndexAlloc(std.testing.allocator);
    defer thesaurus_index.deinit(std.testing.allocator);
    switch ((try thesaurus_index.find("cat")).?) {
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
    var rhymes_index = try rhymes_blob.buildTrustedIndexAlloc(std.testing.allocator);
    defer rhymes_index.deinit(std.testing.allocator);
    switch ((try rhymes_index.find("English/æt")).?) {
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
    var reconstruction_index = try reconstruction_blob.buildTrustedIndexAlloc(std.testing.allocator);
    defer reconstruction_index.deinit(std.testing.allocator);
    switch ((try reconstruction_index.find("Proto-Germanic/kattuz")).?) {
        .reconstruction => |entry| {
            try std.testing.expectEqual(reconstruction.Kind.language, (try entry.inspect()).kind);
            var sections = (try entry.sectionIterator()).?;
            try std.testing.expectEqualStrings("{{reconstructed}}\n", sections.preamble());
            try std.testing.expectEqualStrings("Proto-Germanic", (try sections.next()).?.title);
        },
        else => return error.UnexpectedRecordKind,
    }
}

test "typed blob reader keeps raw feature payloads borrowed without persistent index" {
    const bytes = try format.buildAlloc(std.testing.allocator, .citations, "", &.{
        .{ .title = "cat", .payload = "raw citation source" },
    });
    defer std.testing.allocator.free(bytes);
    const blob = try BlobView.inspect(bytes);
    const trusted = try BlobView.openTrusted(bytes);
    var index = try trusted.buildTrustedIndexAlloc(std.testing.allocator);
    defer index.deinit(std.testing.allocator);
    try trusted.validate();
    try std.testing.expectEqualStrings("cat", (try index.find("cat")).?.title());
    switch ((try index.recordAt(0))) {
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

test "typed supplement records expose language identity and family without a persisted index" {
    const a = std.testing.allocator;
    const bytes = try format.buildAlloc(a, .supplement, "en\x00English\x00\x01", &.{.{ .title = "cat", .payload = "\x07origin\n" }});
    defer a.free(bytes);
    const blob = try BlobView.inspect(bytes);
    try std.testing.expectEqualStrings("en", blob.languageMetadata().?.code);
    var index = try blob.buildIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("cat")).?.supplement;
    try std.testing.expectEqual(format.PartKind.etymology, record.family);
    try std.testing.expectEqualStrings("\x07origin\n", record.payload);
}

test "portable linked reader requires explicit shared catalog binding" {
    const a = std.testing.allocator;
    var builder: encoder.call_symbols.Builder = .{ .a = a };
    defer builder.deinit();
    try builder.collect("{{en-noun}}");
    const keys = try builder.sorted();
    defer a.free(keys);
    const names: encoder.call_symbols.Names = .{ .keys = keys };
    const source = "==English==\n===Noun===\n{{en-noun}}\n# A cat.\n";
    const payload = try language.encodeAlloc(a, source, .{ .heading = "English" });
    defer a.free(payload);
    const linked = try encoder.call_symbols.encodeAlloc(a, payload, names);
    defer a.free(linked);
    const metadata = try format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const bytes = try format.buildAlloc(a, .language, metadata, &.{.{ .title = "cat", .payload = linked }});
    defer a.free(bytes);
    @memcpy(bytes[0..format.header_len], &format.encodeLinkedHeader(.language, names.digest()));
    const view = try BlobView.inspect(bytes);
    var it = view.iterator();
    const record = (try it.next()).?;
    try std.testing.expect(record.needsSymbols());
    try std.testing.expectError(error.InvalidEncoding, record.language.sectionIterator());
    try std.testing.expectError(error.SymbolIdentityMismatch, view.bindRecordAlloc(a, record, .{ .keys = &.{"twrong"} }));
    var bound = try view.bindRecordAlloc(a, record, names);
    defer bound.deinit();
    try std.testing.expect(!bound.record.needsSymbols());
    const decoded = try language.decodeAlloc(a, bound.record.language.payload, .{ .heading = "English" });
    defer a.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}
