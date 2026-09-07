const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const cg = @import("vm_callgraph.zig");
const inline_pass = @import("vm_inline.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const out = try a.alloc(u8, @intCast(st.size));
    _ = try f.readPositionalAll(io, out, 0);
    return out;
}
fn hasRetVar(f: *const ir.Function) bool {
    for (f.insts.items) |x| if (x.op == .ret_var) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var modules: u64 = 0;
    var candidates: u64 = 0;
    var next_retvar: u64 = 0;
    var next_callvar: u64 = 0;
    var next_methodvar: u64 = 0;
    var next_appendvar: u64 = 0;
    var next_other: u64 = 0;
    var callee_retvar: u64 = 0;
    var callee_fixed_only: u64 = 0;
    var ret0: u64 = 0;
    var ret1: u64 = 0;
    var ret2: u64 = 0;
    var ret3p: u64 = 0;
    var callvar_site: u64 = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], entry.name });
        const src = try readAll(init.io, a, path);
        var chunk = try lua.parse(a, src);
        var program = try ir.lowerChunk(a, &chunk);
        _ = try inline_pass.run(a, &program);
        var graph = try cg.build(a, &program);
        for (graph.candidates.items) |cand| {
            const caller = program.functions.items[cand.caller].?;
            const call = caller.insts.items[cand.pc];
            if (call.count != ir.multi_count) continue;
            candidates += 1;
            if (call.op == .call_vararg) callvar_site += 1;
            if (cand.pc + 1 < caller.insts.items.len) {
                const next = caller.insts.items[cand.pc + 1];
                if (next.op == .ret_var and next.a == call.dst) next_retvar += 1 else if (next.op == .call_vararg and next.c == call.dst) next_callvar += 1 else if (next.op == .method_call_vararg and next.c == call.dst) next_methodvar += 1 else if (next.op == .table_append_var and next.b == call.dst) next_appendvar += 1 else next_other += 1;
            } else next_other += 1;
            const callee = program.functions.items[cand.callee].?;
            if (hasRetVar(&callee)) callee_retvar += 1 else callee_fixed_only += 1;
            for (callee.insts.items) |x| if (x.op == .ret) {
                if (x.count == 0) ret0 += 1 else if (x.count == 1) ret1 += 1 else if (x.count == 2) ret2 += 1 else ret3p += 1;
            };
        }
        graph.deinit();
        program.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 10000 == 0) std.debug.print("modules={d} multi={d}\n", .{ modules, candidates });
        _ = arena.reset(.retain_capacity);
    }
    std.debug.print("TOTAL modules={d} multi_candidates={d} callvar_sites={d} callee_fixed_only={d} callee_retvar={d}\n", .{ modules, candidates, callvar_site, callee_fixed_only, callee_retvar });
    std.debug.print("NEXT retvar={d} callvar={d} methodvar={d} appendvar={d} other={d}\n", .{ next_retvar, next_callvar, next_methodvar, next_appendvar, next_other });
    std.debug.print("FIXED_RETURNS r0={d} r1={d} r2={d} r3p={d}\n", .{ ret0, ret1, ret2, ret3p });
}
