const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_inline.zig");
const cg = @import("vm_callgraph.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const out = try a.alloc(u8, @intCast(st.size));
    _ = try f.readPositionalAll(io, out, 0);
    return out;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    const a = init.arena.allocator();
    const src = try readAll(init.io, a, args[1]);
    var chunk = try lua.parse(a, src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    const stats = try opt.run(a, &p);
    std.debug.print("inlined={d} blocked={d}\n", .{ stats.inlined, stats.blocked_multi_result });
    var graph = try cg.build(a, &p);
    defer graph.deinit();
    for (graph.candidates.items) |c| {
        const f = p.functions.items[c.caller].?;
        const call = f.insts.items[c.pc];
        std.debug.print("CAND caller={d} callee={d} pc={d} op={s} dst={d} count={d}\n", .{ c.caller, c.callee, c.pc, @tagName(call.op), call.dst, call.count });
        const lo: usize = c.pc -| 5;
        const hi: usize = @min(f.insts.items.len, @as(usize, c.pc) + 8);
        for (f.insts.items[lo..hi], lo..) |x, pc| {
            std.debug.print("{d}\t{s}\tdst={d} a={d} b={d} c={d} aux={d} count={d}\n", .{
                pc, @tagName(x.op), x.dst, x.a, x.b, x.c, x.aux, x.count,
            });
        }
    }
}
