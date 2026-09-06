const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
pub const Kind = enc.blob_format.BlobKind;
pub const catalog = enc.blob_catalog;

pub fn parseKind(text: []const u8) ?Kind {
    if (std.mem.eql(u8, text, "sign-gloss")) return .sign_gloss;
    const kind = std.meta.stringToEnum(Kind, text) orelse return null;
    return if ((kind == .supplement or kind == .symbols or kind == .templates or kind == .bytecode or kind == .redirects or kind == .pages)) null else kind;
}
pub fn pathAlloc(a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8) ![]u8 {
    if (kind == .language) {
        var name: [catalog.language_blob_filename_len]u8 = undefined;
        return std.fs.path.join(a, &.{ root, catalog.language_directory, catalog.languageBlobFilename(language, &name) });
    }
    return std.fs.path.join(a, &.{ root, catalog.featureBlobFilename(kind).? });
}

pub const Store = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    index: dec.BlobIndexedView,
    allocator: std.mem.Allocator,
    root: []const u8 = "",
    resolver: ?@import("blob_files").Resolver = null,
    symbols: @import("blob_files").SymbolSource,

    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8, trusted: bool) !Store {
        try @import("blob_files").requireComplete(io, a, root);
        const path = try pathAlloc(a, root, kind, language);
        defer a.free(path);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const len = std.math.cast(usize, (try file.stat(io)).size) orelse return error.FileTooBig;
        if (len == 0) return error.InvalidBlob;
        const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(bytes);
        const view = try dec.openTrustedBlob(bytes);
        if (view.kind() != kind) return error.UnexpectedBlobKind;
        if (kind == .language and !std.mem.eql(u8, view.languageMetadata().?.heading, language)) return error.UnexpectedLanguageBlob;
        const index = if (trusted) try view.buildTrustedIndexAlloc(a) else try view.buildIndexAlloc(a);
        var owned_index = index;
        errdefer owned_index.deinit(a);
        const owned_root = try a.dupe(u8, root);
        return .{ .bytes = bytes, .index = index, .allocator = a, .root = owned_root, .symbols = .{ .io = io, .a = a, .root = owned_root }, .resolver = if (kind == .language) .{ .io = io, .a = a, .root = owned_root, .metadata = view.languageMetadata().?, .symbolic = view.raw.symbolic, .binding_id = view.raw.binding_id } else null };
    }
    pub fn deinit(self: *Store) void {
        if (self.resolver) |*r| r.deinit();
        self.symbols.deinit();
        self.allocator.free(self.root);
        self.index.deinit(self.allocator);
        std.posix.munmap(self.bytes);
        self.* = undefined;
    }
    pub const Resolved = struct {
        record: dec.BlobRecordView,
        a: std.mem.Allocator,
        owned: ?[]u8 = null,
        pub fn deinit(self: *Resolved) void {
            if (self.owned) |bytes| self.a.free(bytes);
        }
    };
    pub fn resolveCoreAlloc(self: *Store, a: std.mem.Allocator, record: dec.BlobRecordView) !Resolved {
        var result: Resolved = .{ .record = record, .a = a };
        const bytes = @import("model.zig").payload(record);
        result.owned = try self.symbols.bindAlloc(a, bytes, self.index.blob.raw.symbolic, self.index.blob.raw.binding_id);
        if (result.owned) |value| result.record = result.record.withBoundPayload(value);
        return result;
    }
    pub fn resolveAlloc(self: *Store, a: std.mem.Allocator, record: dec.BlobRecordView) !Resolved {
        if (record != .language) return self.resolveCoreAlloc(a, record);
        var result: Resolved = .{ .record = record, .a = a };
        if (record == .language) if (self.resolver) |*resolver| {
            resolver.symbols = &self.symbols;
            result.owned = try resolver.resolveAlloc(a, record.title(), record.language.payload);
            if (result.owned) |bytes| result.record = result.record.withBoundPayload(bytes);
        };
        return result;
    }
    pub fn prefix(self: Store, query: []const u8) !Range {
        return prefixRange(self.index, query);
    }
};
pub const Range = struct { start: usize, end: usize };
/// Exact UTF-8 byte prefix, matching the wire's strict bytewise title order.
/// Two binary searches avoid scanning millions of hits for an empty prefix.
pub fn prefixRange(index: dec.BlobIndexedView, query: []const u8) !Range {
    var lo: usize = 0;
    var hi = index.recordCount();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, (try index.recordAt(mid)).title(), query) == .lt) lo = mid + 1 else hi = mid;
    }
    const start = lo;
    hi = index.recordCount();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.startsWith(u8, (try index.recordAt(mid)).title(), query)) lo = mid + 1 else hi = mid;
    }
    return .{ .start = start, .end = lo };
}
test "prefix ranges handle exact matches empty prefixes unicode and misses" {
    const a = std.testing.allocator;
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &.{
        .{ .title = "cat", .payload = "" }, .{ .title = "catfish", .payload = "" },
        .{ .title = "dog", .payload = "" },
        .{ .title = "éclair", .payload = "" },
    });
    defer a.free(bytes);
    const view = try dec.openTrustedBlob(bytes);
    var index = try view.buildIndexAlloc(a);
    defer index.deinit(a);
    try std.testing.expectEqual(Range{ .start = 0, .end = 2 }, try prefixRange(index, "cat"));
    try std.testing.expectEqual(Range{ .start = 0, .end = 4 }, try prefixRange(index, ""));
    try std.testing.expectEqual(Range{ .start = 3, .end = 4 }, try prefixRange(index, "é"));
    try std.testing.expectEqual(Range{ .start = 3, .end = 3 }, try prefixRange(index, "missing"));
}

test "core reading opens no companions and a missing package can be installed into the same session" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const original = "==English==\n===Etymology===\nHistory\n===Noun===\n# An animal.\n";
    const payload_bytes = try enc.language_blob_encoding.encodeAlloc(a, original, .{ .heading = "English" });
    defer a.free(payload_bytes);
    var split = try enc.language_parts.splitAlloc(a, payload_bytes, .{ .heading = "English" });
    defer split.deinit(a);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const core = try enc.blob_format.buildAlloc(a, .language, metadata, &.{.{ .title = "cat", .payload = split.core }});
    defer a.free(core);
    const core_path = try pathAlloc(a, root, .language, "English");
    defer a.free(core_path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(core_path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = core_path, .data = core });
    var db = try Store.open(io, a, root, .language, "English", false);
    defer db.deinit();
    const record = (try db.index.find("cat")).?;
    var doc = try @import("model.zig").fromCoreRecord(a, record);
    defer doc.deinit();
    try std.testing.expectEqual(.core, doc.entry.content);
    for (db.resolver.?.files, db.resolver.?.attempted) |file, attempted| {
        try std.testing.expect(file == null and !attempted);
    }
    try std.testing.expectError(error.MissingSupplement, db.resolveAlloc(a, record));
    const supplement_metadata = try std.mem.concat(a, u8, &.{ metadata, &.{@intFromEnum(enc.language_parts.Kind.etymology)} });
    defer a.free(supplement_metadata);
    const supplement = try enc.blob_format.buildAlloc(a, .supplement, supplement_metadata, &.{.{ .title = "cat", .payload = split.bodies[0] }});
    defer a.free(supplement);
    const detail_path = try catalog.supplementPathAlloc(a, root, "English", .etymology);
    defer a.free(detail_path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(detail_path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = detail_path, .data = supplement });
    var resolved = try db.resolveAlloc(a, record);
    defer resolved.deinit();
    const recovered = try @import("model.zig").sourceAlloc(a, resolved.record);
    defer a.free(recovered);
    try std.testing.expectEqualStrings(original, recovered);
    try std.testing.expect(db.resolver.?.files[0] != null);
    for (db.resolver.?.files[1..]) |file| try std.testing.expect(file == null);
}
