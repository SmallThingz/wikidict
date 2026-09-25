//! Shared, read-only raw template source produced by the existing corpus walk.
//! The enclosing expander .incomplete/ready marker is the publication boundary.
const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const data_name = "template-source.bin";
pub const index_name = "template-source.idx";
const magic = "DTMPSR01";
const version: u32 = 1;
const header_len: usize = 160;
const record_len: usize = 40;
const max_data_bytes: u64 = 512 * 1024 * 1024;
const max_records: u64 = 1_000_000;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn open(io: Io, path: []const u8, max_size: ?u64) !Mapped {
        var file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const size = (try file.stat(io)).size;
        if (max_size) |limit| if (size > limit) return error.TemplateSourceTooLarge;
        const len = std.math.cast(usize, size) orelse return error.TemplateSourceTooLarge;
        if (len == 0) return .{ .bytes = &.{} };
        return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0) };
    }
    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.* = undefined;
    }
};

fn hash(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn recordAt(bytes: []const u8, index: usize) []const u8 {
    const start = header_len + index * record_len;
    return bytes[start .. start + record_len];
}

pub const TemplateSource = struct {
    index: Mapped,
    data: Mapped,
    record_count: usize,

    /// Both assets must be absent for an old expander to use the compressed dump.
    /// A partial or malformed sidecar is a build failure, not a silent fallback.
    pub fn open(io: Io, allocator: A, root: []const u8, page_index: []const u8) !?TemplateSource {
        const idx_path = try std.fs.path.join(allocator, &.{ root, index_name });
        defer allocator.free(idx_path);
        const bin_path = try std.fs.path.join(allocator, &.{ root, data_name });
        defer allocator.free(bin_path);
        var maybe_idx: ?Mapped = Mapped.open(io, idx_path, header_len + max_records * record_len) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        errdefer if (maybe_idx) |*mapped| mapped.deinit();
        var maybe_bin: ?Mapped = Mapped.open(io, bin_path, max_data_bytes) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        errdefer if (maybe_bin) |*mapped| mapped.deinit();
        if (maybe_idx == null and maybe_bin == null) return null;
        if (maybe_idx == null or maybe_bin == null) return error.TemplateSourceIncomplete;
        const idx = maybe_idx.?.bytes;
        const bin = maybe_bin.?.bytes;
        if (idx.len < header_len or !std.mem.eql(u8, idx[0..8], magic)) return error.InvalidTemplateSourceIndex;
        if (std.mem.readInt(u32, idx[8..12], .little) != version or
            std.mem.readInt(u32, idx[12..16], .little) != record_len) return error.UnsupportedTemplateSourceVersion;
        const source_index_size = std.mem.readInt(u64, idx[16..24], .little);
        const source_size = std.mem.readInt(u64, idx[56..64], .little);
        const count64 = std.mem.readInt(u64, idx[64..72], .little);
        if (source_index_size != @as(u64, @intCast(page_index.len)) or source_size != @as(u64, @intCast(bin.len)) or
            source_size > max_data_bytes or count64 > max_records) return error.InvalidTemplateSourceIndex;
        for (idx[136..header_len]) |byte| if (byte != 0) return error.InvalidTemplateSourceIndex;
        const count = std.math.cast(usize, count64) orelse return error.InvalidTemplateSourceIndex;
        const records_bytes = std.math.mul(usize, count, record_len) catch return error.InvalidTemplateSourceIndex;
        const expected_len = std.math.add(usize, header_len, records_bytes) catch return error.InvalidTemplateSourceIndex;
        if (idx.len != expected_len) return error.InvalidTemplateSourceIndex;
        const page_index_sha = hash(page_index);
        const data_sha = hash(bin);
        const records_sha = hash(idx[header_len..]);
        if (!std.mem.eql(u8, idx[24..56], &page_index_sha) or
            !std.mem.eql(u8, idx[72..104], &data_sha) or
            !std.mem.eql(u8, idx[104..136], &records_sha)) return error.TemplateSourceChecksumMismatch;
        var prev_ordinal: ?u64 = null;
        var previous_end: u64 = 0;
        for (0..count) |n| {
            const row = recordAt(idx, n);
            const ordinal = std.mem.readInt(u64, row[0..8], .little);
            const offset = std.mem.readInt(u64, row[24..32], .little);
            const len = std.mem.readInt(u64, row[32..40], .little);
            if ((prev_ordinal != null and ordinal <= prev_ordinal.?) or
                offset != previous_end or offset > source_size or len > source_size - offset) return error.InvalidTemplateSourceIndex;
            previous_end = offset + len;
            prev_ordinal = ordinal;
        }
        if (previous_end != source_size) return error.InvalidTemplateSourceIndex;
        return .{ .index = maybe_idx.?, .data = maybe_bin.?, .record_count = count };
    }

    pub fn deinit(self: *TemplateSource) void {
        self.index.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: *const TemplateSource, ordinal: u64, page_id: u64, revision_id: u64) !?[]const u8 {
        var lo: usize = 0;
        var hi: usize = self.record_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const row = recordAt(self.index.bytes, mid);
            const found = std.mem.readInt(u64, row[0..8], .little);
            if (found < ordinal) {
                lo = mid + 1;
                continue;
            }
            hi = mid;
        }
        if (lo == self.record_count) return null;
        const row = recordAt(self.index.bytes, lo);
        if (std.mem.readInt(u64, row[0..8], .little) != ordinal) return null;
        if (std.mem.readInt(u64, row[8..16], .little) != page_id or
            std.mem.readInt(u64, row[16..24], .little) != revision_id) return error.TemplateSourceIdentityMismatch;
        const offset: usize = @intCast(std.mem.readInt(u64, row[24..32], .little));
        const len: usize = @intCast(std.mem.readInt(u64, row[32..40], .little));
        return self.data.bytes[offset .. offset + len];
    }
};

pub const Writer = struct {
    io: Io,
    allocator: A,
    data_file: Io.File,
    index_file: Io.File,
    data_final: []const u8,
    index_final: []const u8,
    data_part: []const u8,
    index_part: []const u8,
    bytes_written: u64 = 0,
    records_written: u64 = 0,
    last_ordinal: ?u64 = null,
    source_hash: Sha256 = Sha256.init(.{}),
    record_hash: Sha256 = Sha256.init(.{}),
    finished: bool = false,

    pub fn init(io: Io, allocator: A, root: []const u8) !Writer {
        const data_final = try std.fs.path.join(allocator, &.{ root, data_name });
        errdefer allocator.free(data_final);
        const index_final = try std.fs.path.join(allocator, &.{ root, index_name });
        errdefer allocator.free(index_final);
        const data_part = try std.fmt.allocPrint(allocator, "{s}.part", .{data_final});
        errdefer allocator.free(data_part);
        const index_part = try std.fmt.allocPrint(allocator, "{s}.part", .{index_final});
        errdefer allocator.free(index_part);
        var data_file = try Io.Dir.cwd().createFile(io, data_part, .{ .truncate = true });
        errdefer {
            data_file.close(io);
            Io.Dir.cwd().deleteFile(io, data_part) catch {};
        }
        var index_file = try Io.Dir.cwd().createFile(io, index_part, .{ .truncate = true });
        errdefer {
            index_file.close(io);
            Io.Dir.cwd().deleteFile(io, index_part) catch {};
        }
        const blank: [header_len]u8 = @splat(0);
        try index_file.writePositionalAll(io, &blank, 0);
        return .{ .io = io, .allocator = allocator, .data_file = data_file, .index_file = index_file, .data_final = data_final, .index_final = index_final, .data_part = data_part, .index_part = index_part };
    }

    pub fn deinit(self: *Writer) void {
        self.data_file.close(self.io);
        self.index_file.close(self.io);
        if (!self.finished) {
            Io.Dir.cwd().deleteFile(self.io, self.data_part) catch {};
            Io.Dir.cwd().deleteFile(self.io, self.index_part) catch {};
        }
        self.allocator.free(self.data_final);
        self.allocator.free(self.index_final);
        self.allocator.free(self.data_part);
        self.allocator.free(self.index_part);
    }

    pub fn append(self: *Writer, ordinal: u64, page_id: u64, revision_id: u64, raw: []const u8) !void {
        if (self.records_written >= max_records or raw.len > max_data_bytes -| self.bytes_written) return error.TemplateSourceTooLarge;
        if (self.last_ordinal) |last| if (ordinal <= last) return error.TemplateSourceOrdinalOrder;
        try self.data_file.writePositionalAll(self.io, raw, self.bytes_written);
        self.source_hash.update(raw);
        var row: [record_len]u8 = undefined;
        std.mem.writeInt(u64, row[0..8], ordinal, .little);
        std.mem.writeInt(u64, row[8..16], page_id, .little);
        std.mem.writeInt(u64, row[16..24], revision_id, .little);
        std.mem.writeInt(u64, row[24..32], self.bytes_written, .little);
        std.mem.writeInt(u64, row[32..40], @intCast(raw.len), .little);
        try self.index_file.writePositionalAll(self.io, &row, @as(u64, header_len) + self.records_written * @as(u64, record_len));
        self.record_hash.update(&row);
        self.bytes_written += raw.len;
        self.records_written += 1;
        self.last_ordinal = ordinal;
    }

    /// Finish after the page-index writer has flushed every row. The caller's
    /// enclosing expander-ready marker is published only after this returns.
    pub fn finish(self: *Writer, page_index_path: []const u8) !void {
        var mapped = try Mapped.open(self.io, page_index_path, null);
        defer mapped.deinit();
        var header: [header_len]u8 = @splat(0);
        @memcpy(header[0..8], magic);
        std.mem.writeInt(u32, header[8..12], version, .little);
        std.mem.writeInt(u32, header[12..16], record_len, .little);
        std.mem.writeInt(u64, header[16..24], mapped.bytes.len, .little);
        const index_sha = hash(mapped.bytes);
        @memcpy(header[24..56], &index_sha);
        std.mem.writeInt(u64, header[56..64], self.bytes_written, .little);
        std.mem.writeInt(u64, header[64..72], self.records_written, .little);
        var data_sha: [32]u8 = undefined;
        self.source_hash.final(&data_sha);
        @memcpy(header[72..104], &data_sha);
        var records_sha: [32]u8 = undefined;
        self.record_hash.final(&records_sha);
        @memcpy(header[104..136], &records_sha);
        try self.index_file.writePositionalAll(self.io, &header, 0);
        try self.data_file.sync(self.io);
        try self.index_file.sync(self.io);
        try Io.Dir.cwd().rename(self.data_part, Io.Dir.cwd(), self.data_final, self.io);
        try Io.Dir.cwd().rename(self.index_part, Io.Dir.cwd(), self.index_final, self.io);
        self.finished = true;
    }
};

test "template source sidecar preserves exact ordinal and raw XML bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    const page_index = "# sample index\n5\tTemplate:Same\n9\tTemplate:Same\n";
    const page_index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(page_index_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = page_index_path, .data = page_index });
    try std.testing.expect((try TemplateSource.open(io, a, root, page_index)) == null);
    {
        var writer = try Writer.init(io, a, root);
        defer writer.deinit();
        try writer.append(5, 10, 100, "A &amp; B");
        try writer.append(9, 11, 101, "latest");
        try writer.append(12, 12, 102, "");
        try std.testing.expectError(error.TemplateSourceOrdinalOrder, writer.append(9, 12, 102, "bad"));
        try writer.finish(page_index_path);
    }
    {
        var sidecar = (try TemplateSource.open(io, a, root, page_index)).?;
        defer sidecar.deinit();
        try std.testing.expectEqualStrings("A &amp; B", (try sidecar.lookup(5, 10, 100)).?);
        try std.testing.expectEqualStrings("latest", (try sidecar.lookup(9, 11, 101)).?);
        try std.testing.expectEqualStrings("", (try sidecar.lookup(12, 12, 102)).?);
        try std.testing.expect((try sidecar.lookup(6, 11, 101)) == null);
        try std.testing.expectError(error.TemplateSourceIdentityMismatch, sidecar.lookup(9, 10, 100));
    }
    const stale_index = "! sample index\n5\tTemplate:Same\n9\tTemplate:Same\n";
    try std.testing.expectError(error.TemplateSourceChecksumMismatch, TemplateSource.open(io, a, root, stale_index));
    const index_path = try std.fs.path.join(a, &.{ root, index_name });
    defer a.free(index_path);
    const index_bytes = try Io.Dir.cwd().readFileAlloc(io, index_path, a, .limited(4096));
    defer a.free(index_bytes);
    index_bytes[header_len + 8] ^= 1;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_bytes });
    try std.testing.expectError(error.TemplateSourceChecksumMismatch, TemplateSource.open(io, a, root, page_index));
    index_bytes[header_len + 8] ^= 1;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_bytes });
    const data_path = try std.fs.path.join(a, &.{ root, data_name });
    defer a.free(data_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = data_path, .data = "A &amp; Xlatest" });
    try std.testing.expectError(error.TemplateSourceChecksumMismatch, TemplateSource.open(io, a, root, page_index));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = data_path, .data = "A" });
    try std.testing.expectError(error.InvalidTemplateSourceIndex, TemplateSource.open(io, a, root, page_index));
    try Io.Dir.cwd().deleteFile(io, data_path);
    try std.testing.expectError(error.TemplateSourceIncomplete, TemplateSource.open(io, a, root, page_index));
}
