const std = @import("std");
pub const Kind = enum { image, audio };
pub const Media = struct { file: []const u8, kind: Kind, caption: []const u8, data_url: ?[]const u8 = null, author: ?[]const u8 = null, license: ?[]const u8 = null, license_url: ?[]const u8 = null, source_url: ?[]const u8 = null, license_text: ?[]const u8 = null };
pub fn kind(file: []const u8) ?Kind {
    const extension = std.fs.path.extension(file);
    for ([_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp" }) |s| if (std.ascii.eqlIgnoreCase(extension, s)) return .image;
    for ([_][]const u8{ ".ogg", ".oga", ".wav", ".mp3", ".flac" }) |s| if (std.ascii.eqlIgnoreCase(extension, s)) return .audio;
    return null;
}
pub fn key(file: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub const Metadata = struct { file: []const u8, mime: []const u8, sha256: []const u8, author: []const u8, license: []const u8, license_url: []const u8, source_url: []const u8, license_text: ?[]const u8 = null };
pub fn mime(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF")) {
        if (std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
        if (std.mem.eql(u8, bytes[8..12], "WAVE")) return "audio/wav";
    }
    if (std.mem.startsWith(u8, bytes, "OggS")) return "audio/ogg";
    if (std.mem.startsWith(u8, bytes, "fLaC")) return "audio/flac";
    if (std.mem.startsWith(u8, bytes, "ID3") or (bytes.len > 2 and bytes[0] == 0xff and bytes[1] & 0xe0 == 0xe0)) return "audio/mpeg";
    return null;
}

test "only passive supported media formats are eligible for inline export" {
    try std.testing.expect(kind("script.svg") == null);
    try std.testing.expect(mime("<svg onload='alert(1)'>") == null);
    try std.testing.expectEqualStrings("image/png", mime("\x89PNG\r\n\x1a\n").?);
    try std.testing.expectEqualStrings("audio/ogg", mime("OggS").?);
    try std.testing.expectEqual(Kind.audio, kind("file.OGG").?);
}
