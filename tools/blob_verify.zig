const std = @import("std");
const encoder = @import("encoder");

const format = encoder.blob_format;
const catalog = encoder.blob_catalog;
const presentation = encoder.presentation_types;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (len == 0) return error.InvalidBlob;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

const Stats = struct {
    language_blobs: usize = 0,
    language_records: usize = 0,
    thesaurus_records: usize = 0,
    citations_records: usize = 0,
    reconstruction_records: usize = 0,
    rhymes_records: usize = 0,
    sign_gloss_records: usize = 0,

    fn add(self: *Stats, kind: format.BlobKind, records: usize) void {
        switch (kind) {
            .language => self.language_records += records,
            .thesaurus => self.thesaurus_records += records,
            .citations => self.citations_records += records,
            .reconstruction => self.reconstruction_records += records,
            .rhymes => self.rhymes_records += records,
            .sign_gloss => self.sign_gloss_records += records,
        }
    }
};

fn verifyRecord(
    allocator: std.mem.Allocator,
    kind: format.BlobKind,
    metadata: ?format.LanguageMetadata,
    record: format.RecordView,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = std.json.parseFromSliceLeaky(presentation.Stored, a, record.payload, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidPresentation;
    try presentation.validateStored(stored, record.title, kind, metadata);
}

fn verifyBlob(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_kind: format.BlobKind,
    expected_language: ?[]const u8,
    stats: *Stats,
) !void {
    var mapped = try mmapPath(io, path);
    defer mapped.deinit();
    const blob = try format.inspect(mapped.bytes);
    if (blob.kind != expected_kind) return error.UnexpectedBlobKind;

    const metadata = if (expected_kind == .language) try blob.languageMetadata() else null;
    if (expected_language) |heading| {
        if (metadata == null or !std.mem.eql(u8, metadata.?.heading, heading)) return error.UnexpectedLanguageBlob;
    } else if (metadata != null) return error.InvalidBlob;

    var records = blob.iterator();
    var count: usize = 0;
    while (try records.next()) |record| {
        try verifyRecord(allocator, expected_kind, metadata, record);
        count += 1;
    }
    stats.add(expected_kind, count);
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
    var manifest = try mmapPath(io, manifest_path);
    defer manifest.deinit();

    var previous: ?[]const u8 = null;
    var entries = try catalog.Iterator.init(manifest.bytes);
    while (try entries.next()) |entry| {
        if (previous) |old| if (std.mem.order(u8, old, entry.heading) != .lt) return error.InvalidManifest;
        previous = entry.heading;

        var filename_buf: [catalog.language_blob_filename_len]u8 = undefined;
        const filename = catalog.languageBlobFilename(entry.heading, &filename_buf);
        const path = try std.fs.path.join(allocator, &.{ root, catalog.language_directory, filename });
        defer allocator.free(path);
        try verifyBlob(io, allocator, path, .language, entry.heading, stats);
        stats.language_blobs += 1;
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
    inline for (.{
        format.BlobKind.thesaurus,
        format.BlobKind.citations,
        format.BlobKind.reconstruction,
        format.BlobKind.rhymes,
        format.BlobKind.sign_gloss,
    }) |kind| try verifyOptionalFeature(init.io, allocator, root, kind, &stats);

    std.debug.print(
        "verified compiled blobs: language_blobs={d} language_records={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d}\n",
        .{
            stats.language_blobs,
            stats.language_records,
            stats.thesaurus_records,
            stats.citations_records,
            stats.reconstruction_records,
            stats.rhymes_records,
            stats.sign_gloss_records,
        },
    );
}
