//! Explicit build-only reviewed exclusions; no title or language heuristics.
const std = @import("std");
const A = std.mem.Allocator;

pub const Row = struct {
    namespace: u32,
    page_id: u64,
    revision_id: u64,
    title: []const u8,
    decoded_source_sha256: []const u8,
};
pub const Manifest = struct {
    schema: []const u8,
    wiki: []const u8,
    date: []const u8,
    namespace_registry_sha256: []const u8,
    dump_sha256: []const u8,
    page_index_sha256: []const u8,
    source_review_sha256: []const u8,
    rows: []const Row,
};

pub fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn parseDigest(raw: []const u8) ![32]u8 {
    if (raw.len != 64) return error.InvalidReviewedNonlexical;
    for (raw) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return error.InvalidReviewedNonlexical;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidReviewedNonlexical;
    return result;
}
fn requireDigest(raw: []const u8, expected: [32]u8) !void {
    if (!std.meta.eql(try parseDigest(raw), expected)) return error.ReviewedNonlexicalIdentityMismatch;
}

pub const Review = struct {
    a: A,
    parsed: std.json.Parsed(Manifest),
    sha256: [32]u8,
    index_seen: []bool,
    consumed: []bool,

    /// Parse the same authority at merge, where authenticated shard coverage
    /// binds this manifest's digest and exact used page-ID union.
    pub fn parseForMerge(a: A, bytes: []const u8, wiki: []const u8, date: []const u8, registry_sha256: [32]u8) !Review {
        const parsed = try std.json.parseFromSlice(Manifest, a, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.schema, "wikidict.reviewed-nonlexical.v1") or
            !std.mem.eql(u8, value.wiki, wiki) or !std.mem.eql(u8, value.date, date)) return error.ReviewedNonlexicalIdentityMismatch;
        try requireDigest(value.namespace_registry_sha256, registry_sha256);
        _ = try parseDigest(value.dump_sha256);
        _ = try parseDigest(value.page_index_sha256);
        _ = try parseDigest(value.source_review_sha256);
        if (value.rows.len == 0 or value.rows.len > 4096) return error.InvalidReviewedNonlexical;
        for (value.rows, 0..) |row, i| {
            if (row.namespace != 0 or row.page_id == 0 or row.revision_id == 0 or row.title.len == 0 or
                std.mem.indexOfAny(u8, row.title, "\t\r\n") != null) return error.InvalidReviewedNonlexical;
            _ = try parseDigest(row.decoded_source_sha256);
            for (value.rows[0..i]) |previous| if (previous.page_id == row.page_id or std.mem.eql(u8, previous.title, row.title)) return error.DuplicateReviewedNonlexical;
        }
        const seen = try a.alloc(bool, value.rows.len);
        errdefer a.free(seen);
        const consumed = try a.alloc(bool, value.rows.len);
        @memset(seen, false);
        @memset(consumed, false);
        return .{ .a = a, .parsed = parsed, .sha256 = digest(bytes), .index_seen = seen, .consumed = consumed };
    }
    /// Both file digests describe actual native build inputs, not asserted paths.
    pub fn init(a: A, bytes: []const u8, wiki: []const u8, date: []const u8, registry_sha256: [32]u8, dump_sha256: [32]u8, page_index: []const u8) !Review {
        var review = try parseForMerge(a, bytes, wiki, date, registry_sha256);
        errdefer review.deinit();
        try requireDigest(review.parsed.value.dump_sha256, dump_sha256);
        try requireDigest(review.parsed.value.page_index_sha256, digest(page_index));
        return review;
    }
    pub fn deinit(self: *Review) void {
        self.a.free(self.index_seen);
        self.a.free(self.consumed);
        self.parsed.deinit();
        self.* = undefined;
    }
    fn rowIndex(self: *const Review, page: anytype) !?usize {
        for (self.parsed.value.rows, 0..) |row, i| {
            if (row.page_id != page.page_id and !std.mem.eql(u8, row.title, page.title)) continue;
            if (page.ns != 0 or !page.has_source or row.page_id != page.page_id or row.revision_id != page.revision_id or
                !std.mem.eql(u8, row.title, page.title)) return error.ReviewedNonlexicalPageMismatch;
            return i;
        }
        return null;
    }
    /// Call for every source-index row, including rows outside a selected shard.
    pub fn preflightPage(self: *Review, page: anytype) !void {
        const i = (try self.rowIndex(page)) orelse return;
        if (self.index_seen[i]) return error.DuplicateReviewedNonlexical;
        self.index_seen[i] = true;
    }
    pub fn finishPreflight(self: *const Review) !void {
        for (self.index_seen) |seen| if (!seen) return error.UnusedReviewedNonlexical;
    }
    pub fn matches(self: *const Review, page: anytype) !bool {
        return (try self.rowIndex(page)) != null;
    }
    /// Call only after reading and decoding the selected page's actual source.
    /// Return false for unlisted lexical/control pages; never infer aliases.
    pub fn consume(self: *Review, page: anytype, decoded_source: []const u8) !bool {
        const i = (try self.rowIndex(page)) orelse return false;
        if (!self.index_seen[i]) return error.UncheckedReviewedNonlexical;
        if (self.consumed[i]) return error.DuplicateReviewedNonlexical;
        try requireDigest(self.parsed.value.rows[i].decoded_source_sha256, digest(decoded_source));
        self.consumed[i] = true;
        return true;
    }
};

const TestPage = struct { ns: u32 = 0, page_id: u64, revision_id: u64, title: []const u8, has_source: bool = true };
fn testManifest(a: A, rows: []const Row) ![]const u8 {
    const zero = std.fmt.bytesToHex(@as([32]u8, @splat(0)), .lower);
    const index = std.fmt.bytesToHex(digest("index"), .lower);
    return std.json.Stringify.valueAlloc(a, Manifest{ .schema = "wikidict.reviewed-nonlexical.v1", .wiki = "testwiki", .date = "20261001", .namespace_registry_sha256 = &zero, .dump_sha256 = &zero, .page_index_sha256 = &index, .source_review_sha256 = &zero, .rows = rows }, .{});
}
test "reviewed exclusions authenticate exact source and leave independent lexical pages" {
    const a = std.testing.allocator;
    const body_hash = std.fmt.bytesToHex(digest("authored notice"), .lower);
    const rows = [_]Row{.{ .namespace = 0, .page_id = 1, .revision_id = 2, .title = "Authored notice", .decoded_source_sha256 = &body_hash }};
    const bytes = try testManifest(a, &rows);
    defer a.free(bytes);
    var review = try Review.init(a, bytes, "testwiki", "20261001", @splat(0), @splat(0), "index");
    defer review.deinit();
    const page: TestPage = .{ .page_id = 1, .revision_id = 2, .title = "Authored notice" };
    const lexical: TestPage = .{ .page_id = 3, .revision_id = 4, .title = "Independent word" };
    try review.preflightPage(page);
    try review.preflightPage(lexical);
    try review.finishPreflight();
    try std.testing.expect(!try review.matches(lexical));
    try std.testing.expect(!try review.consume(lexical, "==English==\n# authored definition"));
    try std.testing.expectError(error.ReviewedNonlexicalIdentityMismatch, review.consume(page, "changed body"));
    try std.testing.expect(try review.consume(page, "authored notice"));
    try std.testing.expectError(error.DuplicateReviewedNonlexical, review.consume(page, "authored notice"));
}
test "reviewed exclusions reject identity changes duplicate and unused rows" {
    const a = std.testing.allocator;
    const body_hash = std.fmt.bytesToHex(digest("notice"), .lower);
    const row: Row = .{ .namespace = 0, .page_id = 1, .revision_id = 2, .title = "Notice", .decoded_source_sha256 = &body_hash };
    const bytes = try testManifest(a, &.{row});
    defer a.free(bytes);
    try std.testing.expectError(error.ReviewedNonlexicalIdentityMismatch, Review.init(a, bytes, "wrongwiki", "20261001", @splat(0), @splat(0), "index"));
    try std.testing.expectError(error.ReviewedNonlexicalIdentityMismatch, Review.init(a, bytes, "testwiki", "20261002", @splat(0), @splat(0), "index"));
    try std.testing.expectError(error.ReviewedNonlexicalIdentityMismatch, Review.init(a, bytes, "testwiki", "20261001", @splat(1), @splat(0), "index"));
    try std.testing.expectError(error.ReviewedNonlexicalIdentityMismatch, Review.init(a, bytes, "testwiki", "20261001", @splat(0), @splat(1), "index"));
    try std.testing.expectError(error.ReviewedNonlexicalIdentityMismatch, Review.init(a, bytes, "testwiki", "20261001", @splat(0), @splat(0), "changed index"));
    const duplicate = try testManifest(a, &.{ row, row });
    defer a.free(duplicate);
    try std.testing.expectError(error.DuplicateReviewedNonlexical, Review.init(a, duplicate, "testwiki", "20261001", @splat(0), @splat(0), "index"));
    var review = try Review.init(a, bytes, "testwiki", "20261001", @splat(0), @splat(0), "index");
    defer review.deinit();
    try std.testing.expectError(error.UnusedReviewedNonlexical, review.finishPreflight());
    try std.testing.expectError(error.ReviewedNonlexicalPageMismatch, review.preflightPage(TestPage{ .page_id = 1, .revision_id = 3, .title = "Notice" }));
    try std.testing.expectError(error.ReviewedNonlexicalPageMismatch, review.preflightPage(TestPage{ .page_id = 1, .revision_id = 2, .title = "Changed" }));
    try std.testing.expectError(error.ReviewedNonlexicalPageMismatch, review.preflightPage(TestPage{ .ns = 1, .page_id = 1, .revision_id = 2, .title = "Notice" }));
    try std.testing.expectError(error.ReviewedNonlexicalPageMismatch, review.preflightPage(TestPage{ .page_id = 1, .revision_id = 2, .title = "Notice", .has_source = false }));
    const page: TestPage = .{ .page_id = 1, .revision_id = 2, .title = "Notice" };
    try review.preflightPage(page);
    try std.testing.expectError(error.DuplicateReviewedNonlexical, review.preflightPage(page));
}
