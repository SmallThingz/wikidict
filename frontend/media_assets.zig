//! HTML embeds local, verified bytes only. Network acquisition is a separate tool.
const std = @import("std");
const types = @import("media_types.zig");
const A = std.mem.Allocator;
pub fn attach(io: std.Io, a: A, root: []const u8, items: []const types.Media) ![]const types.Media {
    const result = try a.dupe(types.Media, items);
    for (result) |*item| {
        const id = types.key(item.file);
        const meta_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ root, id });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, meta_path, a, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const parsed = try std.json.parseFromSlice(types.Metadata, a, bytes, .{ .allocate = .alloc_always });
        const meta = parsed.value;
        if (!std.mem.eql(u8, meta.file, item.file) or meta.sha256.len != 64 or !std.mem.startsWith(u8, meta.source_url, "https://")) return error.InvalidMediaMetadata;
        const path = try std.fmt.allocPrint(a, "{s}/{s}.bin", .{ root, id });
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
        const actual = types.mime(data) orelse return error.UnsupportedMedia;
        if (!std.mem.eql(u8, actual, meta.mime) or !std.mem.startsWith(u8, actual, if (item.kind == .image) "image/" else "audio/")) return error.MediaTypeMismatch;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), meta.sha256)) return error.MediaHashMismatch;
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
        _ = std.base64.standard.Encoder.encode(encoded, data);
        item.data_url = try std.fmt.allocPrint(a, "data:{s};base64,{s}", .{ actual, encoded });
        item.author = meta.author;
        item.license = meta.license;
        item.license_url = meta.license_url;
        item.source_url = meta.source_url;
        item.license_text = meta.license_text;
    }
    return result;
}
