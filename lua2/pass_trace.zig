const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const sem = @import("vm_semantics.zig");
fn show(p: *const ir.Program, span: u32, label: []const u8) void {
    for (p.functions.items, 0..) |maybe, id| if (maybe) |f| {
        if (f.source_start != span) continue;
        std.debug.print("\nSTAGE {s} fn={d} regs={d}\n", .{ label, id, f.reg_count });
        for (f.insts.items, 0..) |inst, pc| {
            std.debug.print("{d} {s} dst={d} a={d} b={d} c={d} aux={d} count={d}", .{ pc, @tagName(inst.op), inst.dst, inst.a, inst.b, inst.c, inst.aux, inst.count });
            const ops = sem.operands(&f, inst) catch &.{};
            if (ops.len != 0) std.debug.print(" args={any}", .{ops});
            std.debug.print("\n", .{});
        }
    };
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    var file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    const source = try a.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(init.io, source, 0) != source.len) return error.Truncated;
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    const span = try std.fmt.parseInt(u32, args[2], 10);
    show(&p, span, "lowered");
    for (0..3) |round| {
        std.debug.print("\nROUND {d}\n", .{round});
        _ = try @import("vm_flow.zig").run(a, &p);
        show(&p, span, "flow");
        _ = try @import("vm_inline.zig").run(a, &p);
        show(&p, span, "inline");
        _ = try @import("vm_dce.zig").removeUnreachableFunctions(a, &p);
        _ = try @import("vm_interproc.zig").run(a, &p);
        show(&p, span, "interproc");
        _ = try @import("vm_shape_opt.zig").run(a, &p);
        show(&p, span, "shape");
        _ = try @import("vm_scalar_replace.zig").run(a, &p);
        show(&p, span, "scalar");
        _ = try @import("vm_value_numbering.zig").run(a, &p);
        show(&p, span, "numbering");
        _ = try @import("vm_ir_simplify.zig").run(a, &p);
        show(&p, span, "simplify");
        try @import("vm_verify.zig").run(a, &p);
    }
    _ = try @import("vm_ref_lower.zig").run(a, &p);
    show(&p, span, "references");
    _ = try @import("vm_ir_simplify.zig").run(a, &p);
    show(&p, span, "simplify-refs");
    _ = try @import("vm_data.zig").run(a, &p);
    _ = try @import("vm_ir_simplify.zig").run(a, &p);
    _ = try @import("vm_regalloc.zig").run(a, &p);
    show(&p, span, "allocation");
    try @import("vm_verify.zig").run(a, &p);
}
