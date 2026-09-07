const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const codec = @import("vm_codec.zig");
const pool = @import("vm_pool_compact.zig");
const bundle = @import("vm_bundle.zig");

const ManifestRow = struct { page_id: u64, title: []const u8 };

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const n = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const out = try a.alloc(u8, n);
    _ = try file.readPositionalAll(io, out, 0);
    return out;
}

fn putU32(w: *std.Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try w.writeAll(&buf);
}
fn putU64(w: *std.Io.Writer, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try w.writeAll(&buf);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.Usage;
    const manifest_bytes = try readAll(init.io, init.arena.allocator(), args[1]);
    var count: u32 = 0;
    var count_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (count_it.next()) |line| if (line.len != 0) {
        count += 1;
    };

    var output = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
    defer output.close(init.io);
    var out_buf: [1024 * 1024]u8 = undefined;
    var writer = output.writer(init.io, &out_buf);
    const w = &writer.interface;
    try w.writeAll(bundle.magic);
    try putU32(w, count);

    var module_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer module_arena.deinit();
    var lines = std.mem.splitScalar(u8, manifest_bytes, '\n');
    var done: u32 = 0;
    var total_blob: u64 = 0;
    var removed_scalars: u64 = 0;
    var saved_string_indexes: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const a = module_arena.allocator();
        const row = try std.json.parseFromSliceLeaky(ManifestRow, a, line, .{ .ignore_unknown_fields = true });
        const path = try std.fmt.allocPrint(a, "{s}/{d}.lua", .{ args[2], row.page_id });
        const source = try readAll(init.io, a, path);
        var chunk = try lua.parse(a, source);
        var program = try ir.lowerChunk(a, &chunk);
        const compacted = try pool.run(&program);
        removed_scalars += compacted.scalar_nodes_removed;
        saved_string_indexes += compacted.string_index_bytes_saved;
        const blob = try codec.serialize(a, &program);

        try putU32(w, @intCast(row.title.len));
        try putU64(w, blob.len);
        try w.writeAll(row.title);
        try w.writeAll(blob);
        total_blob += blob.len;
        done += 1;
        if (done % 1000 == 0) {
            try w.flush();
            std.debug.print("modules={d}/{d} payload={d}\n", .{ done, count, total_blob });
        }
        _ = module_arena.reset(.retain_capacity);
    }
    try w.flush();
    std.debug.print("TOTAL modules={d} payload={d}\n", .{ done, total_blob });
    std.debug.print("POOL scalar_nodes_removed={d} string_index_bytes_saved={d}\n", .{ removed_scalars, saved_string_indexes });
}
