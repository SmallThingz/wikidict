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

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var modules: u64 = 0;
    var cand: u64 = 0;
    var call_fixed: u64 = 0;
    var call_var: u64 = 0;
    var var_fixed: u64 = 0;
    var var_multi: u64 = 0;
    var no_vararg_op: u64 = 0;
    var fixed_no_extra: u64 = 0;
    var fixed_has_extra: u64 = 0;
    var dynamic_calls: u64 = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], entry.name });
        const src = try readAll(init.io, a, path);
        var chunk = try lua.parse(a, src);
        var p = try ir.lowerChunk(a, &chunk);
        _ = try inline_pass.run(a, &p);
        var graph = try cg.build(a, &p);
        for (graph.candidates.items) |c| {
            const callee = p.functions.items[c.callee].?;
            if (!callee.is_vararg) continue;
            cand += 1;
            const caller = p.functions.items[c.caller].?;
            const call = caller.insts.items[c.pc];
            if (call.op == .call) {
                call_fixed += 1;
                if (call.b > callee.param_count) fixed_has_extra += 1 else fixed_no_extra += 1;
            } else if (call.op == .call_vararg) {
                call_var += 1;
                dynamic_calls += 1;
            }
            var saw = false;
            for (callee.insts.items) |x| if (x.op == .vararg) {
                saw = true;
                if (x.count == ir.multi_count) var_multi += 1 else var_fixed += 1;
            };
            if (!saw) no_vararg_op += 1;
            std.debug.print("CAND file={s} caller={d} callee={d} call={s} args={d} params={d} result={d} vararg_ops=", .{ entry.name, c.caller, c.callee, @tagName(call.op), call.b, callee.param_count, call.count });
            var n: u32 = 0;
            for (callee.insts.items) |x| if (x.op == .vararg) {
                if (n != 0) std.debug.print(",", .{});
                std.debug.print("{d}", .{x.count});
                n += 1;
            };
            std.debug.print("\n", .{});
        }
        graph.deinit();
        p.deinit();
        chunk.deinit();
        modules += 1;
        _ = arena.reset(.retain_capacity);
    }
    std.debug.print("TOTAL modules={d} candidates={d} call_fixed={d} call_vararg={d} fixed_no_extra={d} fixed_has_extra={d} dynamic_calls={d} vararg_fixed_ops={d} vararg_multi_ops={d} no_vararg_op={d}\n", .{ modules, cand, call_fixed, call_var, fixed_no_extra, fixed_has_extra, dynamic_calls, var_fixed, var_multi, no_vararg_op });
}
