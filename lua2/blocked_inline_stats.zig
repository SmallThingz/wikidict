const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const cg = @import("vm_callgraph.zig");
const opt = @import("vm_inline.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const out = try a.alloc(u8, @intCast(st.size));
    _ = try f.readPositionalAll(io, out, 0);
    return out;
}
fn isJump(op: ir.Opcode) bool {
    return switch (op) {
        .jump, .jump_if_false, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => true,
        else => false,
    };
}
fn targeted(f: *const ir.Function, pc: u32) bool {
    for (f.insts.items) |x| if (isJump(x.op) and x.aux == pc) return true;
    return false;
}
fn consumer(x: ir.Inst, base: u32) bool {
    return switch (x.op) {
        .ret_var => x.a == base,
        .call_vararg, .method_call_vararg => x.c == base,
        .table_append_var => x.b == base,
        else => false,
    };
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
    var total: u64 = 0;
    var noncall: u64 = 0;
    var no_next: u64 = 0;
    var bad_consumer: u64 = 0;
    var target: u64 = 0;
    var otherwise: u64 = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], entry.name });
        const src = try readAll(init.io, a, path);
        var chunk = try lua.parse(a, src);
        var p = try ir.lowerChunk(a, &chunk);
        _ = try opt.run(a, &p);
        var g = try cg.build(a, &p);
        for (g.candidates.items) |c| {
            const f = p.functions.items[c.caller].?;
            const call = f.insts.items[c.pc];
            total += 1;
            if (call.op != .call) {
                noncall += 1;
                std.debug.print("NONCALL file={s} caller={d} callee={d} pc={d} op={s} args={d} tail={d} count={d} params={d} vararg={} prev={s} prevdst={d} prevcount={d} adjacent={}\n", .{ entry.name, c.caller, c.callee, c.pc, @tagName(call.op), call.b, call.c, call.count, p.functions.items[c.callee].?.param_count, p.functions.items[c.callee].?.is_vararg, if (c.pc > 0) @tagName(f.insts.items[c.pc - 1].op) else "none", if (c.pc > 0) f.insts.items[c.pc - 1].dst else 0, if (c.pc > 0) f.insts.items[c.pc - 1].count else 0, c.pc > 0 and f.insts.items[c.pc - 1].dst == call.c });
                continue;
            }
            if (call.count != ir.multi_count) {
                otherwise += 1;
                continue;
            }
            if (c.pc + 1 >= f.insts.items.len) {
                no_next += 1;
                continue;
            }
            const next = f.insts.items[c.pc + 1];
            if (!consumer(next, call.dst)) {
                bad_consumer += 1;
                std.debug.print("BADCONSUMER file={s} caller={d} callee={d} pc={d} next={s}\n", .{ entry.name, c.caller, c.callee, c.pc, @tagName(next.op) });
                continue;
            }
            if (targeted(&f, c.pc + 1)) {
                target += 1;
                std.debug.print("TARGET file={s} caller={d} pc={d} next={s}\n", .{ entry.name, c.caller, c.pc, @tagName(next.op) });
                continue;
            }
            otherwise += 1;
        }
        g.deinit();
        p.deinit();
        chunk.deinit();
        modules += 1;
        _ = arena.reset(.retain_capacity);
    }
    std.debug.print("TOTAL modules={d} remaining={d} noncall={d} no_next={d} bad_consumer={d} target={d} otherwise={d}\n", .{ modules, total, noncall, no_next, bad_consumer, target, otherwise });
}
