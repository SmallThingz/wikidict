const std = @import("std");
const encoder = @import("encoder");

const format = encoder.blob_format;
const catalog = encoder.blob_catalog;
const presentation_codec = encoder.presentation_codec;
const file_reader = @import("blob_file_reader.zig");
const feature_kinds = [_]format.BlobKind{ .thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss, .supplemental };

const TableWitness = struct {
    record_ordinal: usize,
    payload_offset: usize,
    payload_bytes: usize,
    table_ordinal: usize,
    title_bytes: usize,
    title_sha256: [32]u8,
    title_prefix: [4096]u8 = undefined,
    title_prefix_bytes: usize,

    fn init(record: file_reader.Record, ordinal: usize, table: usize) TableWitness {
        var value: TableWitness = .{ .record_ordinal = ordinal, .payload_offset = record.payload_offset, .payload_bytes = record.payload_len, .table_ordinal = table, .title_bytes = record.title.len, .title_sha256 = undefined, .title_prefix_bytes = @min(record.title.len, 4096) };
        std.crypto.hash.sha2.Sha256.hash(record.title, &value.title_sha256, .{});
        @memcpy(value.title_prefix[0..value.title_prefix_bytes], record.title[0..value.title_prefix_bytes]);
        return value;
    }
    pub fn jsonStringify(self: TableWitness, jw: anytype) !void {
        const digest = std.fmt.bytesToHex(self.title_sha256, .lower);
        var prefix: [8192]u8 = undefined;
        const digits = "0123456789abcdef";
        for (self.title_prefix[0..self.title_prefix_bytes], 0..) |byte, i| {
            prefix[i * 2] = digits[byte >> 4];
            prefix[i * 2 + 1] = digits[byte & 15];
        }
        try jw.write(.{ .record_ordinal = self.record_ordinal, .payload_offset = self.payload_offset, .payload_bytes = self.payload_bytes, .table_ordinal = self.table_ordinal, .title_bytes = self.title_bytes, .title_sha256 = digest[0..], .title_prefix_hex = prefix[0 .. self.title_prefix_bytes * 2], .title_prefix_truncated = self.title_prefix_bytes < self.title_bytes, .scope = "Zero-based record/table ordinals; table ordinal is nested presentation order for DAL1; raw-byte-safe bounded title prefix" });
    }
};

const ReaderEnvelope = struct {
    catalog_bytes: ?usize = null,
    logical_bytes: usize,
    header_bytes: usize,
    records: usize = 0,
    // Native storage's packed index is 16 bytes per record plus title bytes/NUL.
    native_index_bytes: usize = 0,
    largest_record_bytes: usize = 0,
    largest_nul_field_bytes: usize = 0,
    largest_dpr2_string_bytes: usize = 0,
    largest_dpr2_total_items: u64 = 0,
    tables: usize = 0,
    table_columns_exact: ?usize = 0,
    table_columns_lower_bound: usize = 0,
    table_column_limit_exceeded: bool = false,
    table_spans_supported: bool = true,
    max_table_rows: usize = 0,
    max_table_colspan: u16 = 0,
    max_table_rowspan: u16 = 0,
    widest_table_witness: ?TableWitness = null,
    tallest_table_witness: ?TableWitness = null,
    span_table_witness: ?TableWitness = null,

    fn observe(self: *ReaderEnvelope, record: file_reader.Record, metrics: presentation_codec.DecodeMetrics) !void {
        const ordinal = self.records;
        if (metrics.widest_table) |table| {
            if (self.widest_table_witness == null or metrics.table_columns_lower_bound > self.table_columns_lower_bound or
                (metrics.table_column_limit_exceeded and !self.table_column_limit_exceeded)) self.widest_table_witness = TableWitness.init(record, ordinal, table);
        }
        if (metrics.tallest_table) |table| {
            if (self.tallest_table_witness == null or metrics.max_table_rows > self.max_table_rows) self.tallest_table_witness = TableWitness.init(record, ordinal, table);
        }
        if (metrics.span_table) |table| {
            if (self.span_table_witness == null or metrics.max_table_colspan > self.max_table_colspan or
                metrics.max_table_rowspan > self.max_table_rowspan or (!metrics.table_spans_supported and self.table_spans_supported)) self.span_table_witness = TableWitness.init(record, ordinal, table);
        }
        self.tables += metrics.tables;
        self.table_columns_lower_bound = @max(self.table_columns_lower_bound, metrics.table_columns_lower_bound);
        if (self.table_columns_exact) |previous| {
            self.table_columns_exact = if (metrics.table_columns_exact) |columns| @max(previous, columns) else null;
        }
        self.table_column_limit_exceeded = self.table_column_limit_exceeded or metrics.table_column_limit_exceeded;
        self.table_spans_supported = self.table_spans_supported and metrics.table_spans_supported;
        self.max_table_rows = @max(self.max_table_rows, metrics.max_table_rows);
        self.max_table_colspan = @max(self.max_table_colspan, metrics.max_table_colspan);
        self.max_table_rowspan = @max(self.max_table_rowspan, metrics.max_table_rowspan);
        self.records = try std.math.add(usize, self.records, 1);
        const title_bytes = try std.math.add(usize, record.title.len, 1);
        self.native_index_bytes = try std.math.add(usize, self.native_index_bytes, try std.math.add(usize, 16, title_bytes));
        self.largest_record_bytes = @max(self.largest_record_bytes, record.payload_len);
        self.largest_nul_field_bytes = @max(self.largest_nul_field_bytes, record.title.len);
        self.largest_dpr2_string_bytes = @max(self.largest_dpr2_string_bytes, metrics.largest_string_bytes);
        self.largest_dpr2_total_items = @max(self.largest_dpr2_total_items, metrics.total_items);
    }
};

const Stats = struct {
    last_reader_envelope: ?ReaderEnvelope = null,
    catalog_bytes: ?usize = null,
    language_blobs: usize = 0,
    language_records: usize = 0,
    unverified_blobs: usize = 0,
    unverified_records: usize = 0,
    thesaurus_records: usize = 0,
    citations_records: usize = 0,
    reconstruction_records: usize = 0,
    rhymes_records: usize = 0,
    sign_gloss_records: usize = 0,
    supplemental_records: usize = 0,
    alias_records: usize = 0,
    alias_namespaces: std.AutoHashMapUnmanaged(u32, struct { kind: format.BlobKind, count: u64 }) = .empty,

    fn deinit(self: *Stats, a: std.mem.Allocator) void {
        self.alias_namespaces.deinit(a);
    }

    fn add(self: *Stats, kind: format.BlobKind, records: usize) void {
        switch (kind) {
            .language => self.language_records += records,
            .thesaurus => self.thesaurus_records += records,
            .citations => self.citations_records += records,
            .reconstruction => self.reconstruction_records += records,
            .rhymes => self.rhymes_records += records,
            .sign_gloss => self.sign_gloss_records += records,
            .supplemental => self.supplemental_records += records,
            .alias => self.alias_records += records,
        }
    }
};

fn verifyRecord(
    allocator: std.mem.Allocator,
    kind: format.BlobKind,
    metadata: ?format.LanguageMetadata,
    reader: *file_reader.Reader,
    record: file_reader.Record,
    stats: *Stats,
) !presentation_codec.DecodeMetrics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try reader.readPayloadAlloc(a, record);
    var metrics: presentation_codec.DecodeMetrics = .{};
    if (kind == .alias) {
        const alias = try encoder.alias_codec.decode(payload);
        try encoder.alias_codec.validateKey(record.title, alias);
        _ = try presentation_codec.decodeWithMetricsAlloc(a, alias.presentation, alias.source_title, .alias, null, &metrics);
        const slot = try stats.alias_namespaces.getOrPut(allocator, alias.source_namespace);
        if (!slot.found_existing) slot.value_ptr.* = .{ .kind = alias.source_kind, .count = 0 };
        if (slot.value_ptr.kind != alias.source_kind) return error.InvalidAlias;
        slot.value_ptr.count = try std.math.add(u64, slot.value_ptr.count, 1);
        return metrics;
    }
    _ = presentation_codec.decodeWithMetricsAlloc(a, payload, record.title, kind, metadata, &metrics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPresentation,
    };
    return metrics;
}

fn verifyBlob(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_kind: format.BlobKind,
    expected_language: ?[]const u8,
    stats: *Stats,
) !void {
    stats.last_reader_envelope = null;
    var reader = try file_reader.Reader.init(io, allocator, path);
    defer reader.deinit();
    try reader.validate();
    if (reader.kind != expected_kind) return error.UnexpectedBlobKind;

    const metadata = if (expected_kind == .language) try reader.languageMetadata() else null;
    const unverified = if (metadata) |language| language.code.len == 0 else false;
    // The encoder retains unresolved language declarations in this reserved
    // bucket. It remains unverified and receives the same payload validation.
    if (unverified and !std.mem.eql(u8, metadata.?.heading, "Unclassified")) return error.UnverifiedLanguage;
    if (expected_language) |heading| {
        if (metadata == null or !std.mem.eql(u8, metadata.?.heading, heading)) return error.UnexpectedLanguageBlob;
    } else if (metadata != null) return error.InvalidBlob;

    var envelope: ReaderEnvelope = .{ .catalog_bytes = stats.catalog_bytes, .logical_bytes = reader.window.size, .header_bytes = reader.records_start };
    if (metadata) |language| envelope.largest_nul_field_bytes = @max(language.code.len, language.heading.len);
    var count: usize = 0;
    while (try reader.next()) |record| {
        const metrics = try verifyRecord(allocator, expected_kind, metadata, &reader, record, stats);
        try envelope.observe(record, metrics);
        count += 1;
    }
    stats.add(expected_kind, count);
    if (unverified) {
        stats.unverified_blobs += 1;
        stats.unverified_records += count;
    }
    const line = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "wikidict.verified-blob-reader-envelope.v1",
        .path = path,
        .kind = @tagName(expected_kind),
        .measurements = envelope,
        .scope = "Successful existing verification only; no inferred app compatibility pass",
    }, .{});
    defer allocator.free(line);
    std.debug.print("BLOB_READER_ENVELOPE {s}\n", .{line});
    stats.last_reader_envelope = envelope;
}

fn verifyOptionalFeature(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: format.BlobKind,
    stats: *Stats,
) !void {
    const filename = catalog.featureBlobFilename(kind) orelse return error.InvalidBlobKind;
    const path = try std.fs.path.join(allocator, &.{ root, filename });
    defer allocator.free(path);
    verifyBlob(io, allocator, path, kind, null, stats) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn verifyLanguages(io: std.Io, allocator: std.mem.Allocator, root: []const u8, stats: *Stats) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ root, catalog.manifest_filename });
    defer allocator.free(manifest_path);
    var manifest = try file_reader.Window.init(io, manifest_path);
    defer manifest.deinit();
    if (manifest.size == 0) return error.InvalidBlob;
    stats.catalog_bytes = manifest.size;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    var previous: std.ArrayList(u8) = .empty;
    defer previous.deinit(allocator);
    var cursor: usize = 0;
    try manifest.readDelimited(allocator, &cursor, '\n', &line, true);
    _ = try catalog.Iterator.init(line.items);
    while (cursor < manifest.size) {
        line.clearRetainingCapacity();
        try manifest.readDelimited(allocator, &cursor, '\n', &line, true);
        if (line.items.len == 0) return error.InvalidManifest;
        if (previous.items.len != 0 and std.mem.order(u8, previous.items, line.items) != .lt) return error.InvalidManifest;
        previous.clearRetainingCapacity();
        try previous.appendSlice(allocator, line.items);
        var filename_buf: [catalog.language_blob_filename_len]u8 = undefined;
        const filename = catalog.languageBlobFilename(line.items, &filename_buf);
        const path = try std.fs.path.join(allocator, &.{ root, catalog.language_directory, filename });
        defer allocator.free(path);
        try verifyBlob(io, allocator, path, .language, line.items, stats);
        stats.language_blobs += 1;
    }
    try manifest.checkIdentity();
}

fn verifyNamespaceRecords(io: std.Io, allocator: std.mem.Allocator, root: []const u8, stats: *const Stats) !void {
    var coverage = encoder.namespace_coverage.Table.read(io, allocator, root) catch |err| switch (err) {
        error.FileNotFound => if (stats.alias_records == 0) return else return error.NamespaceCoverageMissing,
        else => return err,
    };
    defer coverage.deinit(allocator);
    var expected_aliases: u64 = 0;
    var alias_rows = coverage.rows.valueIterator();
    while (alias_rows.next()) |row| {
        const actual = stats.alias_namespaces.get(row.id);
        if (row.alias_pages != (if (actual) |v| v.count else 0) or (if (actual) |v| row.kind != v.kind else false)) return error.NamespaceCoverageAliasMismatch;
        expected_aliases = try std.math.add(u64, expected_aliases, row.alias_pages);
    }
    if (expected_aliases != stats.alias_records) return error.NamespaceCoverageAliasMismatch;
    // Fixed-kind pages emit one record each. Language pages can emit several.
    inline for (feature_kinds) |kind| {
        var expected: u64 = 0;
        var rows = coverage.rows.valueIterator();
        while (rows.next()) |row| {
            if (row.kind != kind) continue;
            expected = try std.math.add(u64, expected, (try std.math.add(u64, row.expanded_pages, row.fallback_pages)) - row.alias_pages);
        }
        const actual = @field(stats.*, @tagName(kind) ++ "_records");
        if (expected != actual) {
            std.debug.print("namespace record coverage mismatch: kind={s} expected={d} actual={d}\n", .{ @tagName(kind), expected, actual });
            return error.NamespaceCoverageRecordMismatch;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: dict-blob-verify <output-root>\n", .{});
        return error.Usage;
    }
    const allocator = std.heap.smp_allocator;
    const root = args[1];
    try encoder.blob_files.requireComplete(init.io, allocator, root);

    var stats: Stats = .{};
    defer stats.deinit(allocator);
    try verifyLanguages(init.io, allocator, root, &stats);
    inline for (feature_kinds) |kind| try verifyOptionalFeature(init.io, allocator, root, kind, &stats);
    try verifyOptionalFeature(init.io, allocator, root, .alias, &stats);
    try verifyNamespaceRecords(init.io, allocator, root, &stats);

    std.debug.print(
        "verified compiled blobs: language_blobs={d} language_records={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d} supplemental={d} alias_records={d}\n",
        .{
            stats.language_blobs,
            stats.language_records,
            stats.thesaurus_records,
            stats.citations_records,
            stats.reconstruction_records,
            stats.rhymes_records,
            stats.sign_gloss_records,
            stats.supplemental_records,
            stats.alias_records,
        },
    );
    std.debug.print("unverified language data: blobs={d} records={d}\n", .{ stats.unverified_blobs, stats.unverified_records });
}

test "window verification preserves framing kind metadata and presentation error precedence" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/input", .{tmp.sub_path});
    defer a.free(path);
    var stats: Stats = .{};
    // Later malformed framing must win over an earlier undecodable payload.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x07a\x00\x00b\x00\x80" });
    try std.testing.expectError(error.InvalidBlob, verifyBlob(io, a, path, .supplemental, null, &stats));
    // Even a wrong-kind source is fully framing-validated first.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x02a\x00\x80" });
    try std.testing.expectError(error.InvalidBlob, verifyBlob(io, a, path, .supplemental, null, &stats));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x02a\x00\x00" });
    try std.testing.expectError(error.UnexpectedBlobKind, verifyBlob(io, a, path, .supplemental, null, &stats));
    // Correct framing and kind now reaches presentation validation.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x07a\x00\x00" });
    try std.testing.expectError(error.InvalidPresentation, verifyBlob(io, a, path, .supplemental, null, &stats));
    // Unclassified is the sole accepted empty-code language heading.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x01\x00English\x00" });
    try std.testing.expectError(error.UnverifiedLanguage, verifyBlob(io, a, path, .language, "English", &stats));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x01en\x00English\x00" });
    try std.testing.expectError(error.UnexpectedLanguageBlob, verifyBlob(io, a, path, .language, "French", &stats));
    try std.testing.expectEqual(@as(usize, 0), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.supplemental_records);
    try std.testing.expect(stats.last_reader_envelope == null);
}

test "window verification streams manifest lines and retains empty-line rules" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const manifest_path = try std.fs.path.join(a, &.{ root, catalog.manifest_filename });
    defer a.free(manifest_path);
    for ([_][]const u8{ "heading", "heading\n" }) |bytes| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = bytes });
        var stats: Stats = .{};
        try verifyLanguages(io, a, root, &stats);
        try std.testing.expectEqual(@as(usize, 0), stats.language_blobs);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = "" });
    var stats: Stats = .{};
    try std.testing.expectError(error.InvalidBlob, verifyLanguages(io, a, root, &stats));
    for ([_][]const u8{ "wrong", "heading\n\n" }) |bytes| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = bytes });
        try std.testing.expectError(error.InvalidManifest, verifyLanguages(io, a, root, &stats));
    }
    // A valid heading crossing a default window must remain available while
    // its separately opened blob is validated against that exact heading.
    const heading = try a.alloc(u8, 256 * 1024 + 17);
    defer a.free(heading);
    @memset(heading, 'h');
    var manifest: std.Io.Writer.Allocating = .init(a);
    defer manifest.deinit();
    try manifest.writer.writeAll("heading\n");
    try manifest.writer.writeAll(heading); // No final newline is legal.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest.written() });
    const language_root = try std.fs.path.join(a, &.{ root, catalog.language_directory });
    defer a.free(language_root);
    try std.Io.Dir.cwd().createDirPath(io, language_root);
    var filename_buffer: [catalog.language_blob_filename_len]u8 = undefined;
    const filename = catalog.languageBlobFilename(heading, &filename_buffer);
    const blob_path = try std.fs.path.join(a, &.{ language_root, filename });
    defer a.free(blob_path);
    const metadata = try format.buildLanguageMetadataAlloc(a, "en", heading);
    defer a.free(metadata);
    const blob = try format.buildAlloc(a, .language, metadata, &.{});
    defer a.free(blob);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = blob_path, .data = blob });
    try verifyLanguages(io, a, root, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
}

test "alias envelope measures outer records nested DPR2 and per-record maxima" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(temporary, ".zig-cache/tmp/{s}/aliases.wikblb", .{tmp.sub_path});
    const types = encoder.presentation_types;
    const caption = [_]types.Span{.{ .kind = .text, .text = "largest nested caption" }};
    const cell_spans = [_]types.Span{.{ .kind = .text, .text = "cell" }};
    const cells = [_]types.Cell{.{ .spans = &cell_spans }};
    const rows = [_]types.Row{.{ .cells = &cells }};
    const blocks = [_]types.Block{.{ .kind = .table, .table = .{ .caption = &caption, .rows = &rows } }};
    const sections = [_]types.Section{.{ .level = 2, .title = "Details", .blocks = &blocks }};
    const presentation = try presentation_codec.encodeAlloc(temporary, .{ .entry = .{ .title = "AliasA", .kind = .alias, .sections = &sections } });
    const alias_a = try encoder.alias_codec.encodeAlloc(temporary, .{
        .source_namespace = 0,
        .source_kind = .language,
        .source_title = "AliasA",
        .source_key = "AliasA",
        .xml_target = "Target",
        .target_title = "Target",
        .target_namespace = 0,
        .target_kind = .language,
        .target_key = "Target",
        .fragment = "",
        .presentation = presentation,
    });
    const alias_b = try encoder.alias_codec.encodeAlloc(temporary, .{
        .source_namespace = 0,
        .source_kind = .language,
        .source_title = "AliasB",
        .source_key = "AliasB",
        .xml_target = "Target",
        .target_title = "Target",
        .target_namespace = 0,
        .target_kind = .language,
        .target_key = "Target",
        .fragment = "",
        .presentation = presentation,
    });
    const blob = try format.buildAlloc(temporary, .alias, "", &.{
        .{ .title = "1\tAliasA", .payload = alias_a },
        .{ .title = "1\tAliasB", .payload = alias_b },
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blob });
    var stats: Stats = .{};
    defer stats.deinit(a);
    try verifyBlob(io, a, path, .alias, null, &stats);
    const envelope = stats.last_reader_envelope.?;
    try std.testing.expectEqual(blob.len, envelope.logical_bytes);
    try std.testing.expectEqual(format.header_len, envelope.header_bytes);
    try std.testing.expectEqual(@as(usize, 2), envelope.records);
    try std.testing.expectEqual(@as(usize, 2 * (16 + "1\tAliasA".len + 1)), envelope.native_index_bytes);
    try std.testing.expectEqual(alias_a.len, envelope.largest_record_bytes);
    try std.testing.expect(envelope.largest_record_bytes > presentation.len);
    try std.testing.expectEqual("1\tAliasA".len, envelope.largest_nul_field_bytes);
    try std.testing.expectEqual("largest nested caption".len, envelope.largest_dpr2_string_bytes);
    try std.testing.expectEqual(@as(u64, 6), envelope.largest_dpr2_total_items);
    try std.testing.expectEqual(@as(usize, 2), envelope.tables);
    try std.testing.expectEqual(@as(?usize, 1), envelope.table_columns_exact);
    try std.testing.expectEqual(@as(usize, 1), envelope.max_table_rows);
    try std.testing.expectEqual(@as(usize, 0), envelope.widest_table_witness.?.record_ordinal);
    try std.testing.expectEqual(@as(usize, 0), envelope.widest_table_witness.?.table_ordinal);
    try std.testing.expectEqualStrings("1\tAliasA", envelope.widest_table_witness.?.title_prefix[0..envelope.widest_table_witness.?.title_prefix_bytes]);
    try std.testing.expectEqual(@as(usize, 2), stats.alias_records);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x08bad\x00\x80" });
    try std.testing.expectError(error.InvalidBlob, verifyBlob(io, a, path, .alias, null, &stats));
    try std.testing.expect(stats.last_reader_envelope == null);
}

test "table witness owns raw title bytes and bounded JSON provenance" {
    const a = std.testing.allocator;
    var title = [_]u8{ 'x', 255, 'y' };
    const record: file_reader.Record = .{ .title = &title, .payload_offset = 27, .payload_len = 99 };
    const witness = TableWitness.init(record, 4, 2);
    title[0] = 'z';
    const json = try std.json.Stringify.valueAlloc(a, witness, .{});
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "78ff79") != null);
    try std.testing.expectEqual(@as(usize, 4), witness.record_ordinal);
    try std.testing.expectEqual(@as(usize, 27), witness.payload_offset);
    var long: [4100]u8 = undefined;
    @memset(&long, 'a');
    const bounded = TableWitness.init(.{ .title = &long, .payload_offset = 8, .payload_len = 9 }, 0, 0);
    try std.testing.expectEqual(@as(usize, 4096), bounded.title_prefix_bytes);
    try std.testing.expectEqual(@as(usize, 4100), bounded.title_bytes);
}
