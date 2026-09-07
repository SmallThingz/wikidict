const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");

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
    if (args.len < 3) return error.Usage;
    const src = try readAll(init.io, init.arena.allocator(), args[1]);
    var chunk = try lua.parse(init.arena.allocator(), src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(init.arena.allocator(), &chunk);
    defer p.deinit();
    if (args.len > 3 and std.mem.eql(u8, args[3], "optimized")) _ = try @import("vm_optimize.zig").run(init.arena.allocator(), &p);
    const id = try std.fmt.parseInt(u32, args[2], 10);
    const f = p.functions.items[id] orelse return error.NoFunction;
    std.debug.print("fn={d} span={d}..{d} regs={d} insts={d}\n", .{ id, f.source_start, f.source_end, f.reg_count, f.insts.items.len });
    std.debug.print("SOURCE\n{s}\nEND_SOURCE\n", .{src[f.source_start..f.source_end]});
    for (f.insts.items, 0..) |inst, pc| {
        std.debug.print("{d}\t{s}\tdst={d} a={d} b={d} c={d} aux={d} count={d}", .{ pc, @tagName(inst.op), inst.dst, inst.a, inst.b, inst.c, inst.aux, inst.count });
        switch (inst.op) {
            .load_string, .load_number, .get_global, .set_global, .get_field, .set_field => std.debug.print("\tstr={s}", .{p.strings.items[inst.aux]}),
            .load_const => std.debug.print("\tconst={any}", .{p.constants.items[inst.aux]}),
            else => {},
        }
        const operands = try @import("vm_semantics.zig").operands(&f, inst);
        if (operands.len != 0) std.debug.print("\targs={any}", .{operands});
        std.debug.print("\n", .{});
    }
}
