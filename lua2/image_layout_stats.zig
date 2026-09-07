const std = @import("std");
const codec = @import("vm_codec.zig");
const ir = @import("vm_ir.zig");
const wire = @import("vm_wire.zig");
fn bytes(n: u64) u64 {
    var x = n;
    var out: u64 = 1;
    while (x >= 128) : (x >>= 7) out += 1;
    return out;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    const raw = try std.posix.mmap(null, @intCast(stat.size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(raw);
    var p = try codec.deserializeBorrowed(std.heap.smp_allocator, raw);
    defer p.deinit();
    var old: u64 = 0;
    var delta: u64 = 0;
    var key_bytes: u64 = 0;
    var last: i64 = 0;
    var list: u64 = 0;
    var key_delta: u64 = 0;
    var previous_key: i64 = 0;
    for (p.const_entries.items) |e| {
        const k: u64 = if (e.key == ir.implicit_list_key) 0 else @as(u64, e.key) + 1;
        old += bytes(k) + bytes(e.value);
        key_bytes += bytes(k);
        delta += bytes(k) + bytes(wire.zigzag(@as(i64, e.value) - last));
        last = e.value;
        if (k == 0) {
            list += 1;
            key_delta += 1;
        } else {
            key_delta += bytes(wire.zigzag(@as(i64, @intCast(k)) - previous_key) + 1);
            previous_key = @intCast(k);
        }
    }
    std.debug.print("LAYOUT entries={d} list_entries={d} old_bytes={d} value_delta_bytes={d} key_bytes={d} key_delta_bytes={d} saved={d}\n", .{ p.const_entries.items.len, list, old, delta, key_bytes, key_delta, @as(i64, @intCast(old)) - @as(i64, @intCast(delta)) });
}
