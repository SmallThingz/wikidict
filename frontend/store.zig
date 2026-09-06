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
    bytes: []align(std.heap.page_size_min) const u8,
    index: dec.BlobIndexedView,
    allocator: std.mem.Allocator,

    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8, trusted: bool) !Store {
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
        return .{ .bytes = bytes, .index = index, .allocator = a };
    }
    pub fn deinit(self: *Store) void {
        self.index.deinit(self.allocator);
        std.posix.munmap(self.bytes);
        self.* = undefined;
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
