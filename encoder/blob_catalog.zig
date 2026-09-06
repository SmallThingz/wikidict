const std = @import("std");
const format = @import("blob_format.zig");

pub const manifest_header = "heading\tfile\trecords";
pub const language_blob_extension = ".wikblb";
pub const language_blob_filename_len = 64 + language_blob_extension.len;
pub const manifest_filename = "languages.tsv";
pub const language_directory = "languages";

pub fn featureBlobFilename(kind: format.BlobKind) ?[]const u8 {
    return switch (kind) {
        .language => null,
        .thesaurus => "thesaurus.wikblb",
        .citations => "citations.wikblb",
        .reconstruction => "reconstruction.wikblb",
        .rhymes => "rhymes.wikblb",
        .sign_gloss => "sign-gloss.wikblb",
    };
}

pub const Entry = struct {
    heading: []const u8,
    filename: []const u8,
    record_count: u32,
};

pub fn languageBlobFilename(heading: []const u8, out: *[language_blob_filename_len]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(heading, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out[0..hex.len], &hex);
    @memcpy(out[hex.len..], language_blob_extension);
    return out;
}

pub fn writeEntry(writer: *std.Io.Writer, heading: []const u8, filename: []const u8, record_count: u32) !void {
    if (heading.len == 0 or std.mem.indexOfScalar(u8, heading, '\n') != null) return error.InvalidManifest;
    var expected_buf: [language_blob_filename_len]u8 = undefined;
    if (!std.mem.eql(u8, filename, languageBlobFilename(heading, &expected_buf))) return error.InvalidManifest;
    const needs_length_prefix = heading[0] == '#' or std.mem.indexOfScalar(u8, heading, '\t') != null;
    if (needs_length_prefix) {
        try writer.print("#{d}:{s}\t{s}\t{d}\n", .{ heading.len, heading, filename, record_count });
    } else {
        try writer.print("{s}\t{s}\t{d}\n", .{ heading, filename, record_count });
    }
}

pub const Iterator = struct {
    bytes: []const u8,
    cursor: usize,

    pub fn init(bytes: []const u8) error{InvalidManifest}!Iterator {
        const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
        if (!std.mem.eql(u8, bytes[0..end], manifest_header)) return error.InvalidManifest;
        return .{ .bytes = bytes, .cursor = if (end == bytes.len) end else end + 1 };
    }

    pub fn next(self: *Iterator) error{InvalidManifest}!?Entry {
        while (self.cursor < self.bytes.len) {
            const end = std.mem.indexOfScalarPos(u8, self.bytes, self.cursor, '\n') orelse self.bytes.len;
            const line = self.bytes[self.cursor..end];
            self.cursor = if (end == self.bytes.len) end else end + 1;
            if (line.len == 0) continue;

            var heading_start: usize = 0;
            const first_tab = if (line[0] == '#') blk: {
                const colon = std.mem.indexOfScalarPos(u8, line, 1, ':') orelse return error.InvalidManifest;
                if (colon == 1) return error.InvalidManifest;
                const heading_len = std.fmt.parseInt(usize, line[1..colon], 10) catch return error.InvalidManifest;
                heading_start = colon + 1;
                const heading_end = std.math.add(usize, heading_start, heading_len) catch return error.InvalidManifest;
                if (heading_end >= line.len or line[heading_end] != '\t') return error.InvalidManifest;
                break :blk heading_end;
            } else std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidManifest;
            const second_rel = std.mem.indexOfScalar(u8, line[first_tab + 1 ..], '\t') orelse return error.InvalidManifest;
            const second_tab = first_tab + 1 + second_rel;
            if (std.mem.indexOfScalar(u8, line[second_tab + 1 ..], '\t') != null) return error.InvalidManifest;

            const heading = line[heading_start..first_tab];
            const filename = line[first_tab + 1 .. second_tab];
            const count_text = line[second_tab + 1 ..];
            if (heading.len == 0 or filename.len == 0 or count_text.len == 0) return error.InvalidManifest;
            const record_count = std.fmt.parseInt(u32, count_text, 10) catch return error.InvalidManifest;

            var expected_buf: [language_blob_filename_len]u8 = undefined;
            if (!std.mem.eql(u8, filename, languageBlobFilename(heading, &expected_buf))) return error.InvalidManifest;
            return .{ .heading = heading, .filename = filename, .record_count = record_count };
        }
        return null;
    }
};

pub fn find(bytes: []const u8, heading: []const u8) error{InvalidManifest}!?Entry {
    var it = try Iterator.init(bytes);
    var result: ?Entry = null;
    while (try it.next()) |entry| {
        if (!std.mem.eql(u8, entry.heading, heading)) continue;
        if (result != null) return error.InvalidManifest;
        result = entry;
    }
    return result;
}

test "blob catalog derives stable language filenames" {
    var out: [language_blob_filename_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb",
        languageBlobFilename("English", &out),
    );
}

test "blob catalog iterates borrowed manifest rows" {
    var english_name: [language_blob_filename_len]u8 = undefined;
    var french_name: [language_blob_filename_len]u8 = undefined;
    const manifest = try std.fmt.allocPrint(std.testing.allocator, "{s}\nEnglish\t{s}\t3\nFrench\t{s}\t2\n", .{ manifest_header, languageBlobFilename("English", &english_name), languageBlobFilename("French", &french_name) });
    defer std.testing.allocator.free(manifest);

    var it = try Iterator.init(manifest);
    const english = (try it.next()).?;
    try std.testing.expectEqualStrings("English", english.heading);
    try std.testing.expectEqual(@as(u32, 3), english.record_count);
    const french = (try it.next()).?;
    try std.testing.expectEqualStrings("French", french.heading);
    try std.testing.expectEqual(@as(u32, 2), french.record_count);
    try std.testing.expect((try it.next()) == null);

    const found = (try find(manifest, "French")).?;
    try std.testing.expectEqualStrings(french.filename, found.filename);
    try std.testing.expect((try find(manifest, "German")) == null);
}

test "blob catalog rejects mismatched filenames" {
    const manifest = manifest_header ++ "\nEnglish\twrong.wikblb\t1\n";
    var it = try Iterator.init(manifest);
    try std.testing.expectError(error.InvalidManifest, it.next());
}

test "blob catalog names fixed feature blobs" {
    try std.testing.expectEqualStrings("thesaurus.wikblb", featureBlobFilename(.thesaurus).?);
    try std.testing.expectEqualStrings("citations.wikblb", featureBlobFilename(.citations).?);
    try std.testing.expectEqualStrings("reconstruction.wikblb", featureBlobFilename(.reconstruction).?);
    try std.testing.expectEqualStrings("rhymes.wikblb", featureBlobFilename(.rhymes).?);
    try std.testing.expectEqualStrings("sign-gloss.wikblb", featureBlobFilename(.sign_gloss).?);
    try std.testing.expect(featureBlobFilename(.language) == null);
}

test "blob catalog length-prefixes unsafe headings without allocation" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll(manifest_header ++ "\n");

    var tab_name: [language_blob_filename_len]u8 = undefined;
    var hash_name: [language_blob_filename_len]u8 = undefined;
    try writeEntry(&out.writer, "Foo\tBar", languageBlobFilename("Foo\tBar", &tab_name), 7);
    try writeEntry(&out.writer, "#Proto", languageBlobFilename("#Proto", &hash_name), 9);

    var it = try Iterator.init(out.written());
    const tab = (try it.next()).?;
    try std.testing.expectEqualStrings("Foo\tBar", tab.heading);
    try std.testing.expectEqual(@as(u32, 7), tab.record_count);
    const hash = (try it.next()).?;
    try std.testing.expectEqualStrings("#Proto", hash.heading);
    try std.testing.expectEqual(@as(u32, 9), hash.record_count);
    try std.testing.expect((try it.next()) == null);
}

test "blob catalog find rejects duplicate target headings" {
    var name: [language_blob_filename_len]u8 = undefined;
    const filename = languageBlobFilename("English", &name);
    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}\nEnglish\t{s}\t1\nEnglish\t{s}\t2\n",
        .{ manifest_header, filename, filename },
    );
    defer std.testing.allocator.free(manifest);
    try std.testing.expectError(error.InvalidManifest, find(manifest, "English"));
}
