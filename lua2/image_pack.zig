const std = @import("std");
const codec = @import("vm_codec.zig");
const verify = @import("vm_verify.zig");
const pool = @import("vm_entry_pool.zig");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or std.mem.eql(u8, args[1], args[2])) return error.Usage;
    const a = std.heap.smp_allocator;
    var input = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer input.close(init.io);
    const stat = try input.stat(init.io);
    const source = try a.alloc(u8, std.math.cast(usize, stat.size) orelse return error.FileTooBig);
    defer a.free(source);
    if (try input.readPositionalAll(init.io, source, 0) != source.len) return error.Truncated;
    var program = try codec.deserializeBorrowed(a, source);
    defer program.deinit();
    try verify.run(a, &program);
    const stats = try pool.run(a, &program);
    try verify.run(a, &program);
    const bytes = try codec.serialize(a, &program);
    defer a.free(bytes);
    var output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .truncate = true });
    defer output.close(init.io);
    try output.writePositionalAll(init.io, bytes, 0);
    std.debug.print("PACK before_bytes={d} after_bytes={d} entries={any} exact_table_contents=true verifier=pass\n", .{ source.len, bytes.len, stats });
}
