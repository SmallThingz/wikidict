//! Build-only custody of normal-parser quota observations. An observation
//! supplies a page budget proof; each actual file still needs classification.
const std = @import("std");
pub const media = @import("container_timed_media.zig");

pub const schema = "normal-it-timed-media-budget-inputs.v1";
pub const helper_sha256 = "93dabe0e8c9499ebbe91e454e39e4a072546953f9f77e05e4ab2d1fa40d2a6e3";

pub const Observation = struct {
    title: []const u8,
    page_id: u64,
    revision_id: u64,
    raw_sha256: []const u8,
    expanded_sha256: []const u8,
    response_sha256: []const u8,
    request_sha256: []const u8,
    response: []const u8,
};

pub const Reference = struct {
    schema: []const u8,
    helper_sha256: []const u8,
    source_proof_sha256: []const u8,
    namespace_sha256: []const u8,
    module_selection_sha256: []const u8,
    catalog_sha256: []const u8,
    catalog: []const u8,
    observations: []const Observation,
};

fn invalid() error{InvalidTimedMediaInput} { return error.InvalidTimedMediaInput; }

fn digest(text: []const u8) ![32]u8 {
    if (text.len != 64) return invalid();
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return invalid();
    if (std.mem.allEqual(u8, &result, 0) or !std.mem.eql(u8, text, &std.fmt.bytesToHex(result, .lower))) return invalid();
    return result;
}

fn bound(bytes: []const u8, expected: []const u8) !bool {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    return std.mem.eql(u8, &actual, &(try digest(expected)));
}

pub fn validReference(ref: Reference) !void {
    if (!std.mem.eql(u8, ref.schema, schema) or !std.mem.eql(u8, ref.helper_sha256, helper_sha256) or
        ref.catalog.len == 0 or ref.catalog.len > 16 * 1024 or ref.observations.len > 4096 or
        !try bound(ref.catalog, ref.catalog_sha256)) return invalid();
    _ = try digest(ref.source_proof_sha256);
    _ = try digest(ref.namespace_sha256);
    _ = try digest(ref.module_selection_sha256);
    for (ref.observations, 0..) |row, i| {
        if (row.page_id == 0 or row.revision_id == 0 or row.title.len == 0 or row.title.len > 4096 or
            !std.unicode.utf8ValidateSlice(row.title) or std.mem.indexOfAny(u8, row.title, "\x00\r\n") != null or
            row.response.len == 0 or row.response.len > 128 * 1024 or !try bound(row.response, row.response_sha256)) return invalid();
        _ = try digest(row.raw_sha256);
        _ = try digest(row.expanded_sha256);
        _ = try digest(row.request_sha256);
        for (ref.observations[0..i]) |prior| {
            if (prior.page_id == row.page_id or std.mem.eql(u8, prior.title, row.title)) return invalid();
        }
    }
}

pub const Page = struct { catalog: *const media.Catalog, proof: media.Page };

pub const Book = struct {
    catalog: media.Catalog,
    observations: []const Observation,

    pub fn prepare(a: std.mem.Allocator, ref: Reference, provider: []const u8,
        namespace: [32]u8, selection: [32]u8) !Book
    {
        try validReference(ref);
        if (!std.mem.eql(u8, &namespace, &(try digest(ref.namespace_sha256))) or
            !std.mem.eql(u8, &selection, &(try digest(ref.module_selection_sha256)))) return invalid();
        const catalog_bytes = try a.dupe(u8, ref.catalog);
        const catalog = try media.Catalog.open(catalog_bytes, provider, namespace, selection);
        // No later caller buffer or provider-map mutation can substitute a
        // quota response, identity or source binding for this Book.
        const observations = try a.alloc(Observation, ref.observations.len);
        for (observations, ref.observations) |*owned, row| {
            owned.* = row;
            inline for (.{ "title", "raw_sha256", "expanded_sha256", "response_sha256", "request_sha256", "response" }) |field|
                @field(owned, field) = try a.dupe(u8, @field(row, field));
        }
        return .{ .catalog = catalog, .observations = observations };
    }

    pub fn forPage(self: *const Book, a: std.mem.Allocator, id: media.PageId,
        raw: []const u8, expanded: []const u8) !?Page
    {
        if (media.Page.fromLiteral(raw, expanded)) |proof| return .{ .catalog = &self.catalog, .proof = proof };
        for (self.observations) |row| {
            const same_title = std.mem.eql(u8, row.title, id.title);
            if (!same_title and row.page_id != id.page_id) continue;
            if (!same_title or row.page_id != id.page_id or row.revision_id != id.revision_id or
                !try bound(raw, row.raw_sha256) or !try bound(expanded, row.expanded_sha256)) return null;
            const proof = (try media.Page.fromNormal(a, id, expanded, .{
                .expected_sha256 = try digest(row.response_sha256), .response = row.response,
            })) orelse return null;
            return .{ .catalog = &self.catalog, .proof = proof };
        }
        return null;
    }
};
