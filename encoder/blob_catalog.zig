const std = @import("std");

pub const manifest_header = "heading\tfile\trecords";
pub const language_blob_extension = ".wikblb";
pub const language_blob_filename_len = 64 + language_blob_extension.len;

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

            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidManifest;
            const second_rel = std.mem.indexOfScalar(u8, line[first_tab + 1 ..], '\t') orelse return error.InvalidManifest;
            const second_tab = first_tab + 1 + second_rel;
            if (std.mem.indexOfScalar(u8, line[second_tab + 1 ..], '\t') != null) return error.InvalidManifest;

            const heading = line[0..first_tab];
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
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.heading, heading)) return entry;
    }
    return null;
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
