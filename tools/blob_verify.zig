const std = @import("std");
const encoder = @import("encoder");

const format = encoder.blob_format;
const catalog = encoder.blob_catalog;
const presentation_codec = encoder.presentation_codec;
const file_reader = @import("blob_file_reader.zig");
const feature_kinds = [_]format.BlobKind{ .thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss, .supplemental };

const Stats = struct {
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

    fn add(self: *Stats, kind: format.BlobKind, records: usize) void {
        switch (kind) {
            .language => self.language_records += records,
            .thesaurus => self.thesaurus_records += records,
            .citations => self.citations_records += records,
            .reconstruction => self.reconstruction_records += records,
            .rhymes => self.rhymes_records += records,
            .sign_gloss => self.sign_gloss_records += records,
            .supplemental => self.supplemental_records += records,
        }
    }
};

fn verifyRecord(
    allocator: std.mem.Allocator,
    kind: format.BlobKind,
    metadata: ?format.LanguageMetadata,
    reader: *file_reader.Reader,
    record: file_reader.Record,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try reader.readPayloadAlloc(a, record);
    _ = presentation_codec.decodeAlloc(a, payload, record.title, kind, metadata) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPresentation,
    };
}

fn verifyBlob(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_kind: format.BlobKind,
    expected_language: ?[]const u8,
    stats: *Stats,
) !void {
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

    var count: usize = 0;
    while (try reader.next()) |record| {
        try verifyRecord(allocator, expected_kind, metadata, &reader, record);
        count += 1;
    }
    stats.add(expected_kind, count);
    if (unverified) {
        stats.unverified_blobs += 1;
        stats.unverified_records += count;
    }
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
        error.FileNotFound => return,
        else => return err,
    };
    defer coverage.deinit(allocator);
    // Fixed-kind pages emit one record each. Language pages can emit several.
    inline for (feature_kinds) |kind| {
        var expected: u64 = 0;
        var rows = coverage.rows.valueIterator();
        while (rows.next()) |row| {
            if (row.kind != kind) continue;
            expected = try std.math.add(u64, expected, try std.math.add(u64, row.expanded_pages, row.fallback_pages));
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
    try verifyLanguages(init.io, allocator, root, &stats);
    inline for (feature_kinds) |kind| try verifyOptionalFeature(init.io, allocator, root, kind, &stats);
    try verifyNamespaceRecords(init.io, allocator, root, &stats);

    std.debug.print(
        "verified compiled blobs: language_blobs={d} language_records={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d} supplemental={d}\n",
        .{
            stats.language_blobs,
            stats.language_records,
            stats.thesaurus_records,
            stats.citations_records,
            stats.reconstruction_records,
            stats.rhymes_records,
            stats.sign_gloss_records,
            stats.supplemental_records,
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
