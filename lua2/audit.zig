const std = @import("std");
const lua2 = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const base = if (args.len >= 2) args[1] else ".zig-cache/wiktionary-lua-2026-04-01/modules";
    var dir = try std.Io.Dir.cwd().openDir(init.io, base, .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    var total: usize = 0;
    var ok_count: usize = 0;
    var failed: usize = 0;
    var source_bytes: u64 = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        total += 1;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
        defer allocator.free(path);
        var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
        defer file.close(init.io);
        const stat = try file.stat(init.io);
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        source_bytes += stat.size;
        const source = try allocator.alloc(u8, len);
        defer allocator.free(source);
        _ = try file.readPositionalAll(init.io, source, 0);
        var chunk = lua2.parse(allocator, source) catch |err| {
            failed += 1;
            std.debug.print("FAIL\t{s}\t{s}\n", .{ entry.name, @errorName(err) });
            continue;
        };
        chunk.deinit();
        ok_count += 1;
        if (total % 5000 == 0) std.debug.print("checked {d} ok={d} fail={d}\n", .{ total, ok_count, failed });
    }
    std.debug.print("TOTAL {d} OK {d} FAIL {d} BYTES {d}\n", .{ total, ok_count, failed, source_bytes });
    if (failed != 0) return error.CorpusParseFailed;
}
