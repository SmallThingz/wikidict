//! Real XZ streams, persistent caches, block crossings and input/cache corruption.
const std = @import("std");
const enc = @import("blob_encoder");
const storage = @import("blob_storage");
fn require(ok: bool) !void {
    if (!ok) return error.AssertionFailed;
}
fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}
fn compress(io: std.Io, a: std.mem.Allocator, path: []const u8, blocked: bool) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = if (blocked) &.{ "xz", "-0", "-c", "--threads=1", "--check=sha256", "--block-size=64KiB", path } else &.{ "xz", "-0", "-c", "--threads=1", path }, .stdout_limit = .limited(32 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("xz: {s}\n", .{result.stderr});
        return error.CompressionFailed;
    }
    return result.stdout;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 2) return error.Usage;
    const dir = try std.fmt.allocPrint(a, "{s}/storage-{d}-{d}", .{ argv[1], std.os.linux.getpid(), std.Io.Clock.awake.now(io).toNanoseconds() });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const records = try a.alloc(enc.blob_format.RecordInput, 256);
    for (records, 0..) |*r, i| {
        const payload = try a.alloc(u8, 32769 + i % 17);
        for (payload, 0..) |*c, n| c.* = @intCast((i + n * 17) % 253);
        r.* = .{ .title = try std.fmt.allocPrint(a, "word-{d:0>4}", .{i}), .payload = payload };
    }
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", records);
    const raw = try std.fs.path.join(a, &.{ dir, "test.wikblb" });
    try write(io, raw, bytes);
    {
        var f = try storage.File.open(io, init.gpa, raw);
        defer f.deinit();
        try require(!f.cache_hit and f.recordCount() == records.len);
    }
    {
        var f = try storage.File.open(io, init.gpa, raw);
        defer f.deinit();
        try require(f.cache_hit);
    }
    const encoded = try compress(io, a, raw, true);
    const xz = try std.mem.concat(a, u8, &.{ raw, ".xz" });
    try write(io, xz, encoded);
    {
        var f = try storage.File.open(io, init.gpa, xz);
        defer f.deinit();
        try require(!f.cache_hit and f.compressed.?.blocks > 100);
    }
    var block_count: u64 = 0;
    var total_blocks: u64 = 0;
    {
        var f = try storage.File.open(io, init.gpa, xz);
        defer f.deinit();
        try require(f.cache_hit and f.compressed.?.decoded_blocks == 0);
        const id = f.find("word-0127") orelse return error.Missing;
        var r = try f.readAlloc(init.gpa, id);
        defer r.deinit();
        try require(std.mem.eql(u8, r.payload, records[id].payload));
        block_count = f.compressed.?.decoded_blocks;
        total_blocks = f.compressed.?.blocks;
        try require(block_count > 0 and block_count <= 2 and block_count < total_blocks);
        var again = try f.readAlloc(init.gpa, id);
        defer again.deinit();
        try require(std.mem.eql(u8, again.payload, r.payload));
    }
    // Cache damage must rebuild, never yield unrelated offsets.
    const cp = try std.fmt.allocPrint(a, "{s}/.dict-cache/test.wikblb.xz.idx", .{dir});
    const cache = try std.Io.Dir.cwd().readFileAlloc(io, cp, a, .limited(32 * 1024 * 1024));
    cache[cache.len - 1] ^= 1;
    try write(io, cp, cache);
    {
        var f = try storage.File.open(io, init.gpa, xz);
        defer f.deinit();
        try require(!f.cache_hit);
    }
    // An existing single-block stream remains supported with bounded decode memory.
    const single = try std.fs.path.join(a, &.{ dir, "single.xz" });
    try write(io, single, try compress(io, a, raw, false));
    {
        var f = try storage.File.open(io, init.gpa, single);
        defer f.deinit();
        try require(f.compressed.?.blocks == 1);
        var r = try f.readAlloc(init.gpa, 255);
        defer r.deinit();
        try require(std.mem.eql(u8, r.payload, records[255].payload));
    }
    // Concatenated streams and padding, split in the middle of a record payload.
    const pa = try std.fs.path.join(a, &.{ dir, "part-a" });
    const pb = try std.fs.path.join(a, &.{ dir, "part-b" });
    const at = bytes.len / 2 + 7;
    try write(io, pa, bytes[0..at]);
    try write(io, pb, bytes[at..]);
    const concat = try std.fs.path.join(a, &.{ dir, "concat.xz" });
    try write(io, concat, try std.mem.concat(a, u8, &.{ try compress(io, a, pa, true), "\x00\x00\x00\x00", try compress(io, a, pb, true), "\x00\x00\x00\x00" }));
    {
        var f = try storage.File.open(io, init.gpa, concat);
        defer f.deinit();
        try require(f.compressed.?.streams == 2);
        for ([_]usize{ 0, 127, 128, 255 }) |id| {
            var r = try f.readAlloc(init.gpa, id);
            defer r.deinit();
            try require(std.mem.eql(u8, r.payload, records[id].payload));
        }
    }
    // Same path and length but changed content invalidates the stat-bound index.
    try write(io, raw, try enc.blob_format.buildAlloc(a, .citations, "", &.{.{ .title = "changed", .payload = "new" }}));
    {
        var f = try storage.File.open(io, init.gpa, raw);
        defer f.deinit();
        try require(!f.cache_hit and f.find("changed") != null);
    }
    const broken = try a.dupe(u8, encoded);
    broken[broken.len - 5] ^= 1;
    const bad = try std.fs.path.join(a, &.{ dir, "broken.xz" });
    try write(io, bad, broken);
    if (storage.File.open(io, init.gpa, bad)) |value| {
        var f = value;
        f.deinit();
        return error.CorruptAccepted;
    } else |err| try require(err == error.InvalidXz);
    std.debug.print("STORAGE_INTEGRATION_PASS cached=true selective_blocks={d}/{d} single_block=true concatenated=true source_invalidation=true corrupted_cache_rebuilt=true corrupt_xz_rejected=true records={d}\nArtifacts: {s}\n", .{ block_count, total_blocks, records.len, dir });
}
