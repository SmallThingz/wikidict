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
fn isTailProducer(op: ir.Opcode) bool {
    return switch (op) {
        .call, .call_vararg, .method_call, .method_call_vararg, .vararg => true,
        else => false,
    };
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
    var fixed_call: u64 = 0;
    var multi_call: u64 = 0;
    var retvars: u64 = 0;
    var adjacent: u64 = 0;
    var mismatched_base: u64 = 0;
    var bad_producer: u64 = 0;
    var p0: u64 = 0;
    var p1: u64 = 0;
    var p2: u64 = 0;
    var p3p: u64 = 0;
    var prod_call: u64 = 0;
    var prod_call_var: u64 = 0;
    var prod_method: u64 = 0;
    var prod_method_var: u64 = 0;
    var prod_vararg: u64 = 0;
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
            const callee = program.functions.items[cand.callee].?;
            if (!hasRetVar(&callee)) continue;
            candidates += 1;
            const call = caller.insts.items[cand.pc];
            if (call.count == ir.multi_count) multi_call += 1 else fixed_call += 1;
            for (callee.insts.items, 0..) |x, pc| if (x.op == .ret_var) {
                retvars += 1;
                if (x.count == 0) p0 += 1 else if (x.count == 1) p1 += 1 else if (x.count == 2) p2 += 1 else p3p += 1;
                if (pc == 0) {
                    bad_producer += 1;
                    continue;
                }
                const prod = callee.insts.items[pc - 1];
                if (!isTailProducer(prod.op)) {
                    bad_producer += 1;
                    continue;
                }
                adjacent += 1;
                if (prod.dst != x.a) mismatched_base += 1;
                switch (prod.op) {
                    .call => prod_call += 1,
                    .call_vararg => prod_call_var += 1,
                    .method_call => prod_method += 1,
                    .method_call_vararg => prod_method_var += 1,
                    .vararg => prod_vararg += 1,
                    else => {},
                }
            };
        }
        graph.deinit();
        program.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 10000 == 0) std.debug.print("modules={d} candidates={d} retvars={d}\n", .{ modules, candidates, retvars });
        _ = arena.reset(.retain_capacity);
    }
    std.debug.print("TOTAL modules={d} retvar_candidates={d} fixed_call={d} multi_call={d} retvars={d} adjacent={d} mismatch={d} bad_producer={d}\n", .{ modules, candidates, fixed_call, multi_call, retvars, adjacent, mismatched_base, bad_producer });
    std.debug.print("PREFIX p0={d} p1={d} p2={d} p3p={d}\n", .{ p0, p1, p2, p3p });
    std.debug.print("PRODUCER call={d} call_vararg={d} method={d} method_vararg={d} vararg={d}\n", .{ prod_call, prod_call_var, prod_method, prod_method_var, prod_vararg });
}
