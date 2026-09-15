const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
pub const Kind = enc.blob_format.BlobKind;
pub const catalog = enc.blob_catalog;

pub fn parseKind(text: []const u8) ?Kind {
    if (std.mem.eql(u8, text, "sign-gloss")) return .sign_gloss;
    return std.meta.stringToEnum(Kind, text);
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

    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8, trusted: bool) !Store {
        _ = trusted;
        try @import("blob_files").requireComplete(io, a, root);
        const path = try pathAlloc(a, root, kind, language);
        defer a.free(path);
        var file = try @import("blob_storage").File.open(io, a, path);
        errdefer file.deinit();
        if (file.view.kind != kind) return error.UnexpectedBlobKind;
        if (kind == .language) {
            const meta = try file.view.languageMetadata();
            if (!std.mem.eql(u8, meta.heading, language)) return error.UnexpectedLanguageBlob;
        }
        return .{ .file = file, .allocator = a, .root = try a.dupe(u8, root) };
    }
    pub fn deinit(self: *Store) void {
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

test "compiled records need no resolution machinery" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const payload_bytes = "{\"schema\":\"dict.presentation.v1\",\"entry\":{\"title\":\"cat\",\"kind\":\"language\"}}";
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{.{ .title = "cat", .payload = payload_bytes }});
    defer a.free(bytes);
    const path = try pathAlloc(a, root, .language, "English");
    defer a.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    var db = try Store.open(io, a, root, .language, "English", false);
    defer db.deinit();
    var raw = try db.recordAlloc(a, (try db.find("cat")).?);
    defer raw.deinit();
    try std.testing.expectEqualStrings(payload_bytes, @import("model.zig").payload(raw.record));
}
