//! Build-only Common.css authority borrowed from the normal indexed dump input.
const std = @import("std");
const encoder = @import("encoder");
const dump_source = @import("wikimedia_dump");
const namespace_registry = @import("namespace_registry");
const xml_decode = @import("xml_decode");
const max_source_bytes = 1024 * 1024;
const imports = @import("source_stylesheet_imports.zig");

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
    stylesheet_imports: ?imports.Proof = null,

    pub fn jsonStringify(self: Provenance, jw: anytype) !void {
        if (self.stylesheet_imports != null) {
        try jw.write(.{
            .schema = "wikidict.source-table-styles.v2",
            .stylesheet_imports = self.stylesheet_imports.?,
            .provenance_scope = if (self.stylesheet_imports.?.core != null) "exact indexed Common.css plus reviewed version-bound core projection; outer full-input qualification remains separate" else "exact indexed Common.css plus explicit import snapshot; outer full-input qualification remains separate",
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
            return;
        }
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

pub const Absence = struct {
    namespace_sha256: [32]u8,
    reason: encoder.presentation_compile.FigureStylesheetAbsence,
    page_index_kind: dump_source.PageIndexKind,
    page_index_bytes: usize,
    title_index_bytes: usize,
};
pub const Observation = struct {
    authority: ?Authority = null,
    absence: ?Absence = null,
};

fn requireIndexedAbsence(namespaces: *const namespace_registry.Registry, page_index: []const u8, kind: dump_source.PageIndexKind, title: ?[]const u8) !void {
    // A structurally valid title-index table can omit a member. A negative
    // lookup therefore cannot grant absence without checking the source rows.
    // This runs once only on the absence path and reads no page payload.
    var lines = std.mem.splitScalar(u8, page_index, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const row = try dump_source.parsePageIndexLine(kind, line);
        if (title) |expected| {
            if (std.mem.eql(u8, row.title, expected)) return error.InvalidTableStylesSource;
            if (row.ns == 8) {
                const owner = namespaces.ofTitle(row.title);
                if (owner.id != 8 or std.mem.eql(u8, owner.text, "Common.css")) return error.InvalidTableStylesSource;
            }
        } else if (row.ns == 8) return error.InvalidTableStylesSource;
    }
}

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
    return loadWithImports(a, namespaces, source, page_index, title_index, null);
}

pub fn loadWithImports(
    a: std.mem.Allocator,
    namespaces: *const namespace_registry.Registry,
    source: *dump_source.SourceReader,
    page_index: []const u8,
    title_index: dump_source.PageTitleIndex,
    snapshot: ?[]const u8,
) !?Authority {
    return (try observeWithImports(a, namespaces, source, page_index, title_index, snapshot)).authority;
}

pub fn observeWithImports(
    a: std.mem.Allocator,
    namespaces: *const namespace_registry.Registry,
    source: *dump_source.SourceReader,
    page_index: []const u8,
    title_index: dump_source.PageTitleIndex,
    snapshot: ?[]const u8,
) !Observation {
    return observeWithImportsForTarget(a, namespaces, source, page_index, title_index, snapshot, .unknown);
}

pub fn observeWithImportsForTarget(
    a: std.mem.Allocator,
    namespaces: *const namespace_registry.Registry,
    source: *dump_source.SourceReader,
    page_index: []const u8,
    title_index: dump_source.PageTitleIndex,
    snapshot: ?[]const u8,
    target: encoder.table_style_profile.ReadingTarget,
) !Observation {
    if (title_index.page_index_size != page_index.len or title_index.kind != dump_source.pageIndexKind(page_index)) return error.PageTitleIndexMismatch;
    const spec = namespaces.byId(8) orelse {
        if (snapshot != null) return error.InvalidStylesheetImports;
        try requireIndexedAbsence(namespaces, page_index, title_index.kind, null);
        return .{ .absence = .{ .namespace_sha256 = namespaces.source_sha256, .reason = .namespace_absent,
            .page_index_kind = title_index.kind, .page_index_bytes = page_index.len, .title_index_bytes = title_index.bytes.len } };
    };
    if (spec.role != .compile_only or spec.name.len == 0) return error.InvalidTableStylesSource;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const title = try std.fmt.allocPrint(sa, "{s}:Common.css", .{spec.name});
    if (title.len > 4096) return error.InvalidTableStylesSource;
    const ref = (try title_index.lookup(page_index, title)) orelse {
        if (snapshot != null) return error.InvalidStylesheetImports;
        try requireIndexedAbsence(namespaces, page_index, title_index.kind, title);
        return .{ .absence = .{ .namespace_sha256 = namespaces.source_sha256, .reason = .indexed_common_css_absent,
            .page_index_kind = title_index.kind, .page_index_bytes = page_index.len, .title_index_bytes = title_index.bytes.len } };
    };
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
    const namespace_hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const joined: ?imports.Joined = if (snapshot) |bytes| try imports.joinForTargetAlloc(a, css, .{
        .wiki = namespaces.wiki, .dump_date = namespaces.dump_date, .namespace_sha256 = &namespace_hash,
        .page_id = row.page_id, .revision_id = row.revision_id,
    }, bytes, target) else null;
    return .{ .authority = .{
        .profile = if (joined) |value| value.profile else try encoder.table_style_profile.parseForTargetAlloc(a, css, target),
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
            .stylesheet_imports = if (joined) |value| value.proof else null,
        },
    } };
}

test "explicit stylesheet snapshot rejects absent root namespace and indexed page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const page_index = "# empty raw page index\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "pages.xml", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page-index.tsv", .data = page_index });
    const dump_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/pages.xml", .{tmp.sub_path});
    const index_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/page-index.tsv", .{tmp.sub_path});
    const titles_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/page-title-index.bin", .{tmp.sub_path});
    try dump_source.buildPageTitleIndex(io, a, index_path, titles_path);
    const titles = try std.Io.Dir.cwd().readFileAlloc(io, titles_path, a, .limited(4096));
    const title_index = try dump_source.PageTitleIndex.init(titles);
    var source = try dump_source.SourceReader.open(io, a, std.heap.page_allocator, dump_path, .raw_xml, null);
    defer source.deinit();
    var full = try namespace_registry.Registry.init(a, namespace_registry.english_test_fixture);
    defer full.deinit();
    var filtered: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, namespace_registry.english_test_fixture, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "8\t")) continue;
        try filtered.appendSlice(a, line);
        try filtered.append(a, '\n');
    }
    var missing = try namespace_registry.Registry.init(a, filtered.items);
    defer missing.deinit();
    try std.testing.expect(missing.byId(8) == null);
    for ([_]*const namespace_registry.Registry{ &missing, &full }) |catalog| {
        try std.testing.expect((try load(a, catalog, &source, page_index, title_index)) == null);
        const observation = try observeWithImports(a, catalog, &source, page_index, title_index, null);
        try std.testing.expect(observation.authority == null);
        const absence = observation.absence orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, &catalog.source_sha256, &absence.namespace_sha256);
        try std.testing.expectEqual(if (catalog.byId(8) == null)
            encoder.presentation_compile.FigureStylesheetAbsence.namespace_absent else .indexed_common_css_absent, absence.reason);
        try std.testing.expectEqual(page_index.len, absence.page_index_bytes);
        try std.testing.expectEqual(titles.len, absence.title_index_bytes);
        try std.testing.expectError(error.InvalidStylesheetImports,
            loadWithImports(a, catalog, &source, page_index, title_index, "explicit selected snapshot"));
        try std.testing.expectError(error.InvalidStylesheetImports,
            observeWithImports(a, catalog, &source, page_index, title_index, "explicit selected snapshot"));
        var mismatch = title_index;
        mismatch.page_index_size += 1;
        try std.testing.expectError(error.PageTitleIndexMismatch,
            observeWithImports(a, catalog, &source, page_index, mismatch, null));
        const present = "0\t0\tMediaWiki:Common.css\t\t7\t70\t2026-09-01T00:00:00Z\tA\tcss\t8\t1\t0\n";
        const hidden_bytes = try a.dupe(u8, titles);
        std.mem.writeInt(u64, hidden_bytes[40..48], present.len, .little);
        const hidden = try dump_source.PageTitleIndex.init(hidden_bytes);
        try std.testing.expect(try hidden.lookup(present, "MediaWiki:Common.css") == null);
        try std.testing.expectError(error.InvalidTableStylesSource,
            observeWithImports(a, catalog, &source, present, hidden, null));
        if (catalog.byId(8) != null) {
            const unrelated = "0\t0\tMediaWiki:Other.css\t\t7\t70\t2026-09-01T00:00:00Z\tA\tcss\t8\t1\t0\n";
            std.mem.writeInt(u64, hidden_bytes[40..48], unrelated.len, .little);
            const other_index = try dump_source.PageTitleIndex.init(hidden_bytes);
            const other = try observeWithImports(a, catalog, &source, unrelated, other_index, null);
            try std.testing.expect(other.authority == null and other.absence != null);
            try std.testing.expectEqual(encoder.presentation_compile.FigureStylesheetAbsence.indexed_common_css_absent, other.absence.?.reason);
        }
    }
}

test "normal indexed stylesheet loader carries explicit target while legacy callers remain unknown" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const css = "@media print{.readingOnly{text-align:left}}@media screen{.readingOnly{text-align:right}}";
    const page_index = try std.fmt.allocPrint(a, "0\t{d}\tMediaWiki:Common.css\t\t7\t70\t2026-09-01T00:00:00Z\tA\tcss\t8\t1\t0\n", .{css.len});
    try tmp.dir.writeFile(io, .{ .sub_path = "pages.xml", .data = css });
    try tmp.dir.writeFile(io, .{ .sub_path = "page-index.tsv", .data = page_index });
    const dump_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/pages.xml", .{tmp.sub_path});
    const index_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/page-index.tsv", .{tmp.sub_path});
    const title_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/page-title-index.bin", .{tmp.sub_path});
    try dump_source.buildPageTitleIndex(io, a, index_path, title_path);
    const title_bytes = try std.Io.Dir.cwd().readFileAlloc(io, title_path, a, .limited(4096));
    const title_index = try dump_source.PageTitleIndex.init(title_bytes);
    var source = try dump_source.SourceReader.open(io, a, std.heap.page_allocator, dump_path, .raw_xml, null); defer source.deinit();
    var namespaces = try namespace_registry.Registry.init(a, namespace_registry.english_test_fixture); defer namespaces.deinit();
    var old = (try observeWithImports(a, &namespaces, &source, page_index, title_index, null)).authority.?; defer old.deinit();
    try std.testing.expectEqual(encoder.table_style_profile.ReadingTarget.unknown, old.profile.reading_target);
    try std.testing.expect((try old.profile.resolveAlignment(a, "div", "readingOnly", "", null, "")).unresolved);
    for ([_]encoder.table_style_profile.ReadingTarget{ .screen, .print }) |target| {
        var selected = (try observeWithImportsForTarget(a, &namespaces, &source, page_index, title_index, null, target)).authority.?; defer selected.deinit();
        try std.testing.expectEqual(target, selected.profile.reading_target);
        try std.testing.expectEqualDeep(old.provenance, selected.provenance);
        try std.testing.expectEqualStrings(&sha256(css), &selected.provenance.decoded_source_sha256);
        const alignment = try selected.profile.resolveAlignment(a, "div", "readingOnly", "", null, "");
        try std.testing.expect(!alignment.unresolved);
        try std.testing.expectEqual(if (target == .screen) encoder.presentation_types.CellTextAlign.right else .left, alignment.value.?);
    }
    var mismatched = title_index; mismatched.page_index_size += 1;
    try std.testing.expectError(error.PageTitleIndexMismatch, observeWithImportsForTarget(a, &namespaces, &source, page_index, mismatched, null, .screen));
}
