//! Build disposable indexes after raw or XZ blobs have been produced.
const std = @import("std");
const storage = @import("blob_storage");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len < 2) {
        std.debug.print("usage: index-blobs FILE.wikblb[.xz] ...\n", .{});
        return error.Usage;
    }
    for (argv[1..]) |path| {
        var file = try storage.File.open(init.io, init.gpa, path);
        defer file.deinit();
        std.debug.print("{s}: records={d} index_bytes={d} index_heap_bytes={d} cache_map_bytes={d} cache={s} xz_blocks={d} uncompressed_bytes={d}\n", .{ path, file.recordCount(), file.indexBytes(), file.indexHeapBytes(), file.cacheMappedBytes(), if (file.cache_hit) "hit" else if (file.cache_saved) "written" else "memory-only", if (file.compressed) |x| x.blocks else 0, file.size });
    }
}
