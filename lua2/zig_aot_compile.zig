const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const aot = @import("zig_aot.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try a.alloc(u8, len);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.Truncated;
    return bytes;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const a = std.heap.smp_allocator;
    const source = try readAll(init.io, a, args[1]);
    defer a.free(source);
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    _ = try opt.runAot(a, &program);
    const generated = try aot.generate(a, &program);
    defer a.free(generated.source);
    var file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .truncate = true });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, generated.source, 0);
    std.debug.print(
        "AOT functions={d} instructions={d} dynamic_calls={d} dynamic_indexes={d} string_fields={d} bytes={d}\n",
        .{ generated.stats.functions, generated.stats.instructions, generated.stats.dynamic_calls, generated.stats.dynamic_indexes, generated.stats.string_fields, generated.source.len },
    );
}
