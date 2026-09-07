const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const inline_pass = @import("vm_inline.zig");
const dce = @import("vm_dce.zig");
const codec = @import("vm_codec.zig");
const regalloc = @import("vm_regalloc.zig");

const Totals = struct {
    functions: u64 = 0,
    instructions: u64 = 0,
    regs: u64 = 0,
    operands: u64 = 0,
    bytes: u64 = 0,
};

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try a.alloc(u8, @intCast(stat.size));
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

fn addProgram(a: std.mem.Allocator, totals: *Totals, program: *const ir.Program) !void {
    totals.functions += program.functions.items.len;
    for (program.functions.items) |maybe_function| if (maybe_function) |function| {
        totals.instructions += function.insts.items.len;
        totals.regs += function.reg_count;
        totals.operands += function.operands.items.len;
    };
    const bytes = try codec.serialize(a, program);
    defer a.free(bytes);
    totals.bytes += bytes.len;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var iterator = dir.iterate();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var modules: u64 = 0;
    var before = Totals{};
    var after = Totals{};
    var inlined: u64 = 0;
    var removed_functions: u64 = 0;
    var blocked_vararg: u64 = 0;
    var blocked_nested: u64 = 0;
    var blocked_ret_var: u64 = 0;
    var blocked_multi: u64 = 0;
    var removed_moves: u64 = 0;

    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], entry.name });
        const source = try readAll(init.io, a, path);
        var chunk = try lua.parse(a, source);
        var program = try ir.lowerChunk(a, &chunk);
        try addProgram(a, &before, &program);
        const stats = try inline_pass.run(a, &program);
        inlined += stats.inlined;
        blocked_vararg += stats.blocked_vararg;
        blocked_nested += stats.blocked_nested_closure;
        blocked_ret_var += stats.blocked_ret_var;
        blocked_multi += stats.blocked_multi_result;
        removed_functions += try dce.removeUnreachableFunctions(a, &program);
        const reg_stats = try regalloc.run(a, &program);
        removed_moves += reg_stats.removed_moves;
        try addProgram(a, &after, &program);
        program.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 10000 == 0) std.debug.print("modules={d} inlined={d} bytes={d}->{d}\n", .{ modules, inlined, before.bytes, after.bytes });
        _ = arena.reset(.retain_capacity);
    }

    std.debug.print("TOTAL modules={d} inlined={d} removed_functions={d} blocked_vararg={d} blocked_nested={d} blocked_ret_var={d} blocked_multi={d} removed_moves={d}\\n", .{ modules, inlined, removed_functions, blocked_vararg, blocked_nested, blocked_ret_var, blocked_multi, removed_moves });
    std.debug.print("BEFORE functions={d} instructions={d} regs={d} operands={d} bytes={d}\n", .{ before.functions, before.instructions, before.regs, before.operands, before.bytes });
    std.debug.print("AFTER functions={d} instructions={d} regs={d} operands={d} bytes={d}\n", .{ after.functions, after.instructions, after.regs, after.operands, after.bytes });
}
