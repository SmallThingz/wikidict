const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
pub const Kind = enc.blob_format.BlobKind;
pub const catalog = enc.blob_catalog;

pub fn parseKind(text: []const u8) ?Kind {
    if (std.mem.eql(u8, text, "sign-gloss")) return .sign_gloss;
    const kind = std.meta.stringToEnum(Kind, text) orelse return null;
    return if ((kind == .supplement or kind == .symbols or kind == .templates or kind == .redirects or kind == .pages)) null else kind;
}
pub fn pathAlloc(a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8) ![]u8 {
    if (kind == .language) {
        var name: [catalog.language_blob_filename_len]u8 = undefined;
        return std.fs.path.join(a, &.{ root, catalog.language_directory, catalog.languageBlobFilename(language, &name) });
    }
    return std.fs.path.join(a, &.{ root, catalog.featureBlobFilename(kind).? });
}

pub const Store = struct {
    file: @import("blob_storage").File,
    allocator: std.mem.Allocator,
    root: []const u8 = "",
    resolver: ?@import("blob_files").Resolver = null,
    symbols: @import("blob_files").SymbolSource,
    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8, trusted: bool) !Store {
        _ = trusted; // A reusable disk cache is always built from validated source.
        try @import("blob_files").requireComplete(io, a, root);
        const path = try pathAlloc(a, root, kind, language);
        defer a.free(path);
        var file = try @import("blob_storage").File.open(io, a, path);
        errdefer file.deinit();
        if (file.view.kind != kind) return error.UnexpectedBlobKind;
        const meta = if (kind == .language) try file.view.languageMetadata() else null;
        if (meta) |m| if (!std.mem.eql(u8, m.heading, language)) return error.UnexpectedLanguageBlob;
        const owned_root = try a.dupe(u8, root);
        return .{ .file = file, .allocator = a, .root = owned_root, .symbols = .{ .io = io, .a = a, .root = owned_root }, .resolver = if (meta) |m| .{ .io = io, .a = a, .root = owned_root, .metadata = m, .symbolic = file.view.symbolic, .binding_id = file.view.binding_id } else null };
    }
    pub fn deinit(self: *Store) void {
        if (self.resolver) |*r| r.deinit();
        self.symbols.deinit();
        self.file.deinit();
        self.allocator.free(self.root);
        self.* = undefined;
    }
    pub fn count(self: Store) usize {
        return self.file.recordCount();
    }
    pub fn titleAt(self: Store, index: usize) ![]const u8 {
        return self.file.titleAt(index);
    }
    pub fn find(self: Store, title: []const u8) !?usize {
        return self.file.find(title);
    }
    pub fn metadata(self: Store) ?enc.blob_format.LanguageMetadata {
        return if (self.file.view.kind == .language) self.file.view.languageMetadata() catch null else null;
    }
    pub const Raw = struct {
        record: dec.BlobRecordView,
        storage: @import("blob_storage").Record,
        pub fn deinit(self: *Raw) void {
            self.storage.deinit();
        }
    };
    pub fn recordAlloc(self: *Store, a: std.mem.Allocator, index: usize) !Raw {
        var r = try self.file.readAlloc(a, index);
        errdefer r.deinit();
        const view = try dec.openTrustedBlob(self.file.directory.header);
        return .{ .record = view.wrapRecord(.{ .title = r.title, .payload = r.payload }), .storage = r };
    }
    pub const Resolved = struct {
        record: dec.BlobRecordView,
        a: std.mem.Allocator,
        owned: ?[]u8 = null,
        pub fn deinit(self: *Resolved) void {
            if (self.owned) |b| self.a.free(b);
        }
    };
    pub fn resolveCoreAlloc(self: *Store, a: std.mem.Allocator, record: dec.BlobRecordView) !Resolved {
        var r: Resolved = .{ .record = record, .a = a };
        r.owned = try self.symbols.bindAlloc(a, @import("model.zig").payload(record), self.file.view.symbolic, self.file.view.binding_id);
        if (r.owned) |b| r.record = r.record.withBoundPayload(b);
        return r;
    }
    pub fn resolveAlloc(self: *Store, a: std.mem.Allocator, record: dec.BlobRecordView) !Resolved {
        if (record != .language) return self.resolveCoreAlloc(a, record);
        var r: Resolved = .{ .record = record, .a = a };
        if (self.resolver) |*resolver| {
            resolver.symbols = &self.symbols;
            r.owned = try resolver.resolveAlloc(a, record.title(), record.language.payload);
            if (r.owned) |b| r.record = r.record.withBoundPayload(b);
        }
        return r;
    }
    pub fn prefix(self: Store, text: []const u8) !Range {
        const p = self.file.prefix(text);
        return .{ .start = p.start, .end = p.end };
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
    var raw = try db.recordAlloc(a, (try db.find("cat")).?);
    defer raw.deinit();
    const record = raw.record;
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
