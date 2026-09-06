const std = @import("std");
const encoder = @import("encoder");
const decoder = @import("decoder");

const format = encoder.blob_format;
const catalog = encoder.blob_catalog;

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
    if (len == 0) return .{ .bytes = &.{} };
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}
fn parseKind(text: []const u8) ?format.BlobKind {
    inline for (std.meta.tags(format.BlobKind)) |kind| {
        if (std.mem.eql(u8, text, @tagName(kind))) return kind;
    }
    if (std.mem.eql(u8, text, "sign-gloss")) return .sign_gloss;
    return null;
}

fn blobPathAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: format.BlobKind,
    language_heading: ?[]const u8,
) ![]u8 {
    if (kind == .language) {
        var filename_buf: [catalog.language_blob_filename_len]u8 = undefined;
        const filename = catalog.languageBlobFilename(language_heading.?, &filename_buf);
        return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ root, catalog.language_directory, filename });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, catalog.featureBlobFilename(kind).? });
}

fn usage() void {
    std.debug.print("usage:\n", .{});
    std.debug.print("  dict-blob-query <root> language <heading> <title> [--validate]\n", .{});
    std.debug.print("  dict-blob-query <root> <thesaurus|citations|reconstruction|rhymes|sign-gloss> <title> [--validate]\n", .{});
}
fn printLanguage(record: decoder.BlobLanguageRecordView) !void {
    var sections = try record.sectionIterator();
    if (sections.preamble().len != 0) {
        std.debug.print("preamble_bytes={d}\n", .{sections.preamble().len});
    }
    var count: usize = 0;
    while (try sections.next()) |section| {
        std.debug.print(
            "section level={d} title={s} body_bytes={d}\n",
            .{ section.level, section.title, section.raw_body.len },
        );
        count += 1;
    }
    std.debug.print("sections={d}\n", .{count});
}

fn printThesaurus(record: decoder.BlobThesaurusRecordView) !void {
    var it = try record.recordIterator();
    var count: usize = 0;
    while (try it.next()) |item| {
        std.debug.print("record kind={s} language={s} data_bytes={d}\n", .{
            @tagName(item.kind), item.language, item.data.len,
        });
        count += 1;
    }
    std.debug.print("records={d}\n", .{count});
}
fn printRhymes(record: decoder.BlobRhymesRecordView) !void {
    var it = try record.recordIterator();
    var count: usize = 0;
    while (try it.next()) |item| {
        std.debug.print("record kind={s} language={s} data_bytes={d} links={d}\n", .{
            @tagName(item.kind), item.language, item.data.len, item.link_count,
        });
        count += 1;
    }
    std.debug.print("records={d}\n", .{count});
}

fn printReconstruction(record: decoder.BlobReconstructionRecordView) !void {
    const view = try record.inspect();
    std.debug.print("reconstruction_kind={s} body_bytes={d}\n", .{ @tagName(view.kind), view.body.len });
    var sections = (try record.sectionIterator()) orelse return;
    if (sections.preamble().len != 0) std.debug.print("preamble_bytes={d}\n", .{sections.preamble().len});
    var count: usize = 0;
    while (try sections.next()) |section| {
        std.debug.print("section level={d} title={s} body_bytes={d}\n", .{
            section.level, section.title, section.raw_body.len,
        });
        count += 1;
    }
    std.debug.print("sections={d}\n", .{count});
}
fn printRecord(record: decoder.BlobRecordView) !void {
    switch (record) {
        .language => |entry| try printLanguage(entry),
        .thesaurus => |entry| try printThesaurus(entry),
        .citations => |entry| std.debug.print("source_bytes={d}\n", .{entry.source.len}),
        .reconstruction => |entry| try printReconstruction(entry),
        .rhymes => |entry| try printRhymes(entry),
        .sign_gloss => |entry| std.debug.print("source_bytes={d}\n", .{entry.source.len}),
    }
}

fn parseValidate(args: []const []const u8, index: usize) !bool {
    if (args.len == index) return false;
    if (args.len != index + 1 or !std.mem.eql(u8, args[index], "--validate")) return error.Usage;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 4) {
        usage();
        return error.Usage;
    }
    const root = args[1];
    const kind = parseKind(args[2]) orelse {
        usage();
        return error.Usage;
    };
    const language_heading: ?[]const u8 = if (kind == .language) blk: {
        if (args.len < 5) {
            usage();
            return error.Usage;
        }
        break :blk args[3];
    } else null;
    const title = if (kind == .language) args[4] else args[3];
    const validate = parseValidate(args, if (kind == .language) 5 else 4) catch {
        usage();
        return error.Usage;
    };

    const path = try blobPathAlloc(allocator, root, kind, language_heading);
    var mapped = try mmapPath(init.io, path);
    defer mapped.deinit();
    const blob = try decoder.openTrustedBlob(mapped.bytes);
    if (blob.kind() != kind) return error.UnexpectedBlobKind;
    if (language_heading) |heading| {
        const metadata = blob.languageMetadata() orelse return error.MissingLanguageMetadata;
        if (!std.mem.eql(u8, metadata.heading, heading)) return error.UnexpectedLanguageBlob;
    }
    var index = if (validate) try blob.buildIndexAlloc(allocator) else try blob.buildTrustedIndexAlloc(allocator);
    defer index.deinit(allocator);

    const record = (try index.find(title)) orelse {
        std.debug.print("no match kind={s} title={s}\n", .{ @tagName(kind), title });
        return;
    };
    std.debug.print("path={s}\nkind={s}\ntitle={s}\nrecords={d}\npayload_bytes={d}\n", .{
        path,
        @tagName(kind),
        record.title(),
        index.recordCount(),
        switch (record) {
            .language => |entry| entry.payload.len,
            .thesaurus => |entry| entry.payload.len,
            .citations => |entry| entry.source.len,
            .reconstruction => |entry| entry.payload.len,
            .rhymes => |entry| entry.payload.len,
            .sign_gloss => |entry| entry.source.len,
        },
    });
    try printRecord(record);
}

test "blob query parses public kind names" {
    try std.testing.expectEqual(format.BlobKind.language, parseKind("language").?);
    try std.testing.expectEqual(format.BlobKind.sign_gloss, parseKind("sign-gloss").?);
    try std.testing.expect(parseKind("unknown") == null);
}

test "blob query derives language and feature paths" {
    const language_path = try blobPathAlloc(std.testing.allocator, "/tmp/blobs", .language, "English");
    defer std.testing.allocator.free(language_path);
    try std.testing.expectEqualStrings(
        "/tmp/blobs/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb",
        language_path,
    );
    const feature_path = try blobPathAlloc(std.testing.allocator, "/tmp/blobs", .thesaurus, null);
    defer std.testing.allocator.free(feature_path);
    try std.testing.expectEqualStrings("/tmp/blobs/thesaurus.wikblb", feature_path);
}
