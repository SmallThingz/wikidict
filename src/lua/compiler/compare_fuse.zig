const std = @import("std");
const ir = @import("ir.zig");
const sem = @import("semantics.zig");
const cfg = @import("graph.zig");
const liveness = @import("liveness.zig");
pub const Stats = struct { branches: u64 = 0 };
fn runFunction(a: std.mem.Allocator, p: *const ir.Program, f: *ir.Function) !u64 {
    var graph = try cfg.build(a, f);
    defer graph.deinit();
    var live = try liveness.build(a, p, f, &graph);
    defer live.deinit();
    const captured = try a.alloc(bool, f.reg_count);
    defer a.free(captured);
    @memset(captured, false);
    for (f.insts.items) |inst| if (inst.op == .closure) {
        for (p.functions.items[inst.aux].?.upvalues.items) |up| if (up.source == .local) {
            captured[up.index] = true;
        };
    };
    const remove = try a.alloc(bool, f.insts.items.len);
    defer a.free(remove);
    @memset(remove, false);
    var fused: u64 = 0;
    for (f.insts.items, 0..) |inst, pc| {
        if (!sem.isComparison(inst.op) or pc + 1 >= f.insts.items.len) continue;
        if (captured[inst.dst]) continue;
        const next = f.insts.items[pc + 1];
        if (next.op != .jump_if_false or next.a != inst.dst) continue;
        const bid = graph.block_of_pc[pc];
        if (graph.block_of_pc[pc + 1] != bid) continue;
        var live_after = false;
        for (graph.blocks.items[bid].succ) |succ| if (succ) |s| {
            live_after = live_after or live.isLiveIn(s, inst.dst);
        };
        if (live_after) continue;
        // Preserve comparison evaluation and metamethod effects, but do not
        // materialize a boolean whose sole use is this branch.
        f.insts.items[pc] = .{ .op = .branch_compare, .a = inst.a, .b = inst.b, .aux = next.aux, .count = @intFromEnum(inst.op) };
        remove[pc + 1] = true;
        fused += 1;
    }
    if (fused == 0) return 0;
    const map = try a.alloc(u32, f.insts.items.len + 1);
    defer a.free(map);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(a);
    for (f.insts.items, 0..) |inst, pc| {
        map[pc] = @intCast(out.items.len);
        if (!remove[pc]) try out.append(a, inst);
    }
    map[f.insts.items.len] = @intCast(out.items.len);
    for (out.items) |*inst| if (sem.info(inst.op).target) {
        inst.aux = map[inst.aux];
    };
    f.insts.deinit(a);
    f.insts = out;
    return fused;
}
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    for (p.functions.items) |*maybe| if (maybe.*) |*f| {
        stats.branches += try runFunction(a, p, f);
    };
    return stats;
}
