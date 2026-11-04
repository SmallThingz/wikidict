//! Build-only Common.css authority borrowed from the normal indexed dump input.
const std = @import("std");
const encoder = @import("encoder");
const dump_source = @import("wikimedia_dump");
const namespace_registry = @import("namespace_registry");
const xml_decode = @import("xml_decode");
const max_source_bytes = 1024 * 1024;

pub const Provenance = struct {
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: [64]u8,
    title: []const u8,
    page_id: u64,
    revision_id: u64,
    revision_timestamp: []const u8,
    content_model: []const u8,
    page_index_kind: dump_source.PageIndexKind,
    page_index_bytes: usize,
    index_offset: usize,
    ordinal: usize,
    source: dump_source.PageSource,
    source_needs_decode: bool,
    index_row_sha256: [64]u8,
    encoded_source_bytes: usize,
    encoded_source_sha256: [64]u8,
    decoded_source_bytes: usize,
    decoded_source_sha256: [64]u8,

    pub fn jsonStringify(self: Provenance, jw: anytype) !void {
        try jw.write(.{
            .schema = "wikidict.source-table-styles.v1",
            .provenance_scope = "exact indexed Common.css; outer full-input qualification remains separate",
            .wiki = self.wiki,
            .dump_date = self.dump_date,
            .namespace_sha256 = self.namespace_sha256[0..],
            .title = self.title,
            .page_id = self.page_id,
            .revision_id = self.revision_id,
            .revision_timestamp = self.revision_timestamp,
            .content_model = self.content_model,
            .page_index_kind = self.page_index_kind,
            .page_index_bytes = self.page_index_bytes,
            .index_offset = self.index_offset,
            .ordinal = self.ordinal,
            .source = self.source,
            .source_needs_decode = self.source_needs_decode,
            .index_row_sha256 = self.index_row_sha256[0..],
            .encoded_source_bytes = self.encoded_source_bytes,
            .encoded_source_sha256 = self.encoded_source_sha256[0..],
            .decoded_source_bytes = self.decoded_source_bytes,
            .decoded_source_sha256 = self.decoded_source_sha256[0..],
        });
    }
};

pub const Authority = struct {
    profile: encoder.table_style_profile.Profile,
    // Strings borrow the immutable namespace registry and page-index mapping.
    // The ordinary build keeps both alive through all Writer completion.
    provenance: Provenance,

    pub fn deinit(self: *Authority) void {
        self.profile.deinit();
    }
};

fn sha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn load(
    a: std.mem.Allocator,
    namespaces: *const namespace_registry.Registry,
    source: *dump_source.SourceReader,
    page_index: []const u8,
    title_index: dump_source.PageTitleIndex,
) !?Authority {
    if (title_index.page_index_size != page_index.len or title_index.kind != dump_source.pageIndexKind(page_index)) return error.PageTitleIndexMismatch;
    const spec = namespaces.byId(8) orelse return null;
    if (spec.role != .compile_only or spec.name.len == 0) return error.InvalidTableStylesSource;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const title = try std.fmt.allocPrint(sa, "{s}:Common.css", .{spec.name});
    if (title.len > 4096) return error.InvalidTableStylesSource;
    const ref = (try title_index.lookup(page_index, title)) orelse return null;
    const offset = dump_source.pageRowRefOffset(ref);
    if (offset >= page_index.len or (offset != 0 and page_index[offset - 1] != '\n')) return error.InvalidPageIndex;
    const end = std.mem.indexOfScalarPos(u8, page_index, offset, '\n') orelse page_index.len;
    const line = page_index[offset..end];
    if (line.len > 16 * 1024) return error.InvalidTableStylesSource;
    const row = try dump_source.parsePageIndexLine(title_index.kind, line);
    if (row.ns != 8 or !row.has_source or row.redirect != null or
        !std.mem.eql(u8, row.content_model, "css") or !std.mem.eql(u8, row.title, title) or
        row.page_id == 0 or row.revision_id == 0 or dump_source.sourceLen(row.source) > max_source_bytes)
        return error.InvalidTableStylesSource;
    const raw = try source.readAlloc(sa, row.source);
    if (raw.len != dump_source.sourceLen(row.source)) return error.InvalidTableStylesSource;
    const css = if (row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(sa, raw) else raw;
    if (css.len > max_source_bytes or !std.unicode.utf8ValidateSlice(css)) return error.InvalidTableStylesSource;
    return .{
        .profile = try encoder.table_style_profile.parseAlloc(a, css),
        .provenance = .{
            .wiki = namespaces.wiki,
            .dump_date = namespaces.dump_date,
            .namespace_sha256 = std.fmt.bytesToHex(namespaces.source_sha256, .lower),
            .title = row.title,
            .page_id = row.page_id,
            .revision_id = row.revision_id,
            .revision_timestamp = row.revision_timestamp,
            .content_model = row.content_model,
            .page_index_kind = title_index.kind,
            .page_index_bytes = page_index.len,
            .index_offset = offset,
            .ordinal = dump_source.pageRowRefOrdinal(ref),
            .source = row.source,
            .source_needs_decode = row.source_needs_decode,
            .index_row_sha256 = sha256(line),
            .encoded_source_bytes = raw.len,
            .encoded_source_sha256 = sha256(raw),
            .decoded_source_bytes = css.len,
            .decoded_source_sha256 = sha256(css),
        },
    };
}
