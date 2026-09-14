const std = @import("std");
const format = @import("blob_format.zig");

pub const manifest_header = "heading";
pub const language_blob_extension = ".wikblb";
pub const language_blob_filename_len = 64 + language_blob_extension.len;
pub const manifest_filename = "languages.tsv";
pub const language_directory = "languages";

pub fn featureBlobFilename(kind: format.BlobKind) ?[]const u8 {
    return switch (kind) {
        .language, .supplement, .symbols, .templates, .redirects, .pages => null,
        .thesaurus => "thesaurus.wikblb",
        .citations => "citations.wikblb",
        .reconstruction => "reconstruction.wikblb",
        .rhymes => "rhymes.wikblb",
        .sign_gloss => "sign-gloss.wikblb",
    };
}

pub const Entry = struct {
    heading: []const u8,
};

pub fn languageBlobFilename(heading: []const u8, out: *[language_blob_filename_len]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(heading, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out[0..hex.len], &hex);
    @memcpy(out[hex.len..], language_blob_extension);
    return out;
}

pub fn writeEntry(writer: *std.Io.Writer, heading: []const u8) !void {
    if (heading.len == 0 or std.mem.indexOfScalar(u8, heading, '\n') != null) return error.InvalidManifest;
    try writer.writeAll(heading);
    try writer.writeByte('\n');
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
        if (self.cursor == self.bytes.len) return null;
        if (self.cursor > self.bytes.len) return error.InvalidManifest;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.cursor, '\n') orelse self.bytes.len;
        const heading = self.bytes[self.cursor..end];
        self.cursor = if (end == self.bytes.len) end else end + 1;
        if (heading.len == 0) return error.InvalidManifest;
        return .{ .heading = heading };
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

test "blob catalog stores only language headings" {
    const manifest = manifest_header ++ "\nEnglish\nFrench\n";
    var it = try Iterator.init(manifest);
    try std.testing.expectEqualStrings("English", (try it.next()).?.heading);
    try std.testing.expectEqualStrings("French", (try it.next()).?.heading);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectEqualStrings("French", (try find(manifest, "French")).?.heading);
    try std.testing.expect((try find(manifest, "German")) == null);
}
test "blob catalog headings need no field escaping" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll(manifest_header ++ "\n");
    try writeEntry(&out.writer, "Foo\tBar");
    try writeEntry(&out.writer, "#Proto");

    var it = try Iterator.init(out.written());
    try std.testing.expectEqualStrings("Foo\tBar", (try it.next()).?.heading);
    try std.testing.expectEqualStrings("#Proto", (try it.next()).?.heading);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectError(error.InvalidManifest, writeEntry(&out.writer, "bad\nheading"));
}

test "blob catalog find rejects duplicate target headings" {
    const manifest = manifest_header ++ "\nEnglish\nEnglish\n";
    try std.testing.expectError(error.InvalidManifest, find(manifest, "English"));
}

test "blob catalog names fixed feature blobs" {
    try std.testing.expectEqualStrings("thesaurus.wikblb", featureBlobFilename(.thesaurus).?);
    try std.testing.expectEqualStrings("citations.wikblb", featureBlobFilename(.citations).?);
    try std.testing.expectEqualStrings("reconstruction.wikblb", featureBlobFilename(.reconstruction).?);
    try std.testing.expectEqualStrings("rhymes.wikblb", featureBlobFilename(.rhymes).?);
    try std.testing.expectEqualStrings("sign-gloss.wikblb", featureBlobFilename(.sign_gloss).?);
    try std.testing.expect(featureBlobFilename(.language) == null);
}

pub fn supplementPathAlloc(a: std.mem.Allocator, root: []const u8, heading: []const u8, kind: format.PartKind) ![]u8 {
    var name: [language_blob_filename_len]u8 = undefined;
    return std.fs.path.join(a, &.{ root, "details", @tagName(kind), languageBlobFilename(heading, &name) });
}
