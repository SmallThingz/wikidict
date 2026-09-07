const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
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
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var modules: u64 = 0;
    var functions: u64 = 0;
    var calls: u64 = 0;
    var candidates: u64 = 0;
    var body_insts: u64 = 0;
    var no_upvalues: u64 = 0;
    var fixed_arity: u64 = 0;
    var nested_closure: u64 = 0;
    var ret_var: u64 = 0;
    var caller_multi: u64 = 0;
    var caller_zero: u64 = 0;
    var caller_one: u64 = 0;
    var caller_fixed_many: u64 = 0;
    var directly_inlineable_v1: u64 = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], entry.name });
        const src = try readAll(init.io, a, path);
        var chunk = try lua.parse(a, src);
        var p = try ir.lowerChunk(a, &chunk);
        functions += p.functions.items.len;
        var graph = try cg.build(a, &p);
        calls += graph.calls.items.len;
        candidates += graph.candidates.items.len;
        for (graph.candidates.items) |candidate| {
            const f = p.functions.items[candidate.callee].?;
            const caller = p.functions.items[candidate.caller].?;
            const call = caller.insts.items[candidate.pc];
            body_insts += f.insts.items.len;
            if (f.upvalues.items.len == 0) no_upvalues += 1;
            if (!f.is_vararg) fixed_arity += 1;
            var has_nested = false;
            var has_ret_var = false;
            for (f.insts.items) |inst| {
                has_nested = has_nested or inst.op == .closure;
                has_ret_var = has_ret_var or inst.op == .ret_var;
            }
            nested_closure += @intFromBool(has_nested);
            ret_var += @intFromBool(has_ret_var);
            if (call.count == ir.multi_count) caller_multi += 1 else if (call.count == 0) caller_zero += 1 else if (call.count == 1) caller_one += 1 else caller_fixed_many += 1;
            if (!f.is_vararg and !has_nested and !has_ret_var and call.op == .call and call.count != ir.multi_count) directly_inlineable_v1 += 1;
        }
        graph.deinit();
        p.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 10000 == 0) std.debug.print("modules={d} candidates={d}\n", .{ modules, candidates });
        _ = arena.reset(.retain_capacity);
    }
    std.debug.print("TOTAL modules={d} functions={d} resolved_calls={d} candidates={d} body_insts={d}\n", .{ modules, functions, calls, candidates, body_insts });
    std.debug.print("SHAPE no_upvalues={d} fixed_arity={d} nested_closure={d} ret_var={d} caller_multi={d} caller_zero={d} caller_one={d} caller_fixed_many={d} v1={d}\n", .{ no_upvalues, fixed_arity, nested_closure, ret_var, caller_multi, caller_zero, caller_one, caller_fixed_many, directly_inlineable_v1 });
}
