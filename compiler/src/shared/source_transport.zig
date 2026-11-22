const std = @import("std");

pub const FileIdentity = struct { device_major: u32, device_minor: u32, inode: u64, size: u64, mtime_ns: i128, ctime_ns: i128 };
pub fn pathIdentity(io: std.Io, path: []const u8) !FileIdentity {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const linux = std.os.linux;
    var stat: linux.Statx = undefined;
    if (linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat) != 0 or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME or !stat.mask.TYPE or (stat.mode & linux.S.IFMT) != linux.S.IFREG) return error.SourceStatFailed;
    return .{ .device_major = stat.dev_major, .device_minor = stat.dev_minor, .inode = stat.ino, .size = stat.size, .mtime_ns = @as(i128, stat.mtime.sec) * std.time.ns_per_s + stat.mtime.nsec, .ctime_ns = @as(i128, stat.ctime.sec) * std.time.ns_per_s + stat.ctime.nsec };
}

pub const Descriptor = struct {
    format: []const u8,
    transport: []const u8,
    block_directory: []const u8,
    source_directory: []const u8,
};
pub const Binding = struct {
    kind: []const u8,
    descriptor_sha256: [32]u8,
    block_directory_sha256: [32]u8,
};
const Receipt = struct { version: u32, source: FileIdentity, transport: ?Binding = null };
pub const Selected = struct {
    descriptor: std.json.Parsed(Descriptor),
    binding: Binding,
    pub fn deinit(self: *Selected) void { self.descriptor.deinit(); self.* = undefined; }
};

fn digest(bytes: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

// This is explicit receipt selection, not JSON/suffix transport detection.
// Legacy input authority stays with the ordinary v2 intake. A v3 receipt never
// falls back when its descriptor, kind, selected dump, or byte digests disagree.
pub fn load(io: std.Io, a: std.mem.Allocator, root: []const u8, requested_dump: []const u8) !?Selected {
    const receipt_path = try std.fs.path.join(a, &.{ root, "extraction-source.json" });
    defer a.free(receipt_path);
    const descriptor_path = try std.fs.path.join(a, &.{ root, "source-transport.json" });
    defer a.free(descriptor_path);
    const receipt_bytes = std.Io.Dir.cwd().readFileAlloc(io, receipt_path, a, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (receipt_bytes) |bytes| a.free(bytes);
    const descriptor_bytes = std.Io.Dir.cwd().readFileAlloc(io, descriptor_path, a, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (descriptor_bytes) |bytes| a.free(bytes);
    if (receipt_bytes == null) {
        if (descriptor_bytes != null) return error.MissingBzip2SourceReceipt;
        return null;
    }
    const receipt = try std.json.parseFromSlice(Receipt, a, receipt_bytes.?, .{ .ignore_unknown_fields = true });
    defer receipt.deinit();
    if (receipt.value.version == 2) {
        if (descriptor_bytes != null or receipt.value.transport != null) return error.UnselectedBzip2Transport;
        return null;
    }
    if (receipt.value.version != 3) return error.UnsupportedSourceReceipt;
    const selected_binding = receipt.value.transport orelse return error.MissingBzip2SourceTransport;
    if (!std.mem.eql(u8, selected_binding.kind, "bzip2-blocks")) return error.UnsupportedSourceTransport;
    const bytes = descriptor_bytes orelse return error.MissingBzip2SourceTransport;
    if (!std.mem.eql(u8, &digest(bytes), &selected_binding.descriptor_sha256)) return error.SourceTransportChanged;
    var descriptor = try std.json.parseFromSlice(Descriptor, a, bytes, .{ .allocate = .alloc_always });
    errdefer descriptor.deinit();
    const d = descriptor.value;
    if (!std.mem.eql(u8, d.format, "wikidict-source-transport-v1") or !std.mem.eql(u8, d.transport, "bzip2-blocks") or
        !std.fs.path.isAbsolute(d.block_directory) or !std.fs.path.isAbsolute(d.source_directory) or
        std.mem.indexOfScalar(u8, d.block_directory, 0) != null or std.mem.indexOfScalar(u8, d.source_directory, 0) != null or
        !std.mem.eql(u8, d.block_directory, requested_dump)) return error.SourceTransportMismatch;
    const before = try pathIdentity(io, requested_dump);
    if (!std.meta.eql(before, receipt.value.source)) return error.ExtractionSourceChanged;
    const directory_bytes = try std.Io.Dir.cwd().readFileAlloc(io, requested_dump, a, .limited(64 * 1024 * 1024));
    defer a.free(directory_bytes);
    if (!std.mem.eql(u8, &digest(directory_bytes), &selected_binding.block_directory_sha256) or
        !std.meta.eql(before, try pathIdentity(io, requested_dump))) return error.SourceTransportChanged;
    return .{ .descriptor = descriptor, .binding = .{ .kind = "bzip2-blocks", .descriptor_sha256 = selected_binding.descriptor_sha256, .block_directory_sha256 = selected_binding.block_directory_sha256 } };
}
