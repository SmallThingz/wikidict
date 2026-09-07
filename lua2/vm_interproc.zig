const std = @import("std");
const ir = @import("vm_ir.zig");
const cg = @import("vm_callgraph.zig");
const flow = @import("vm_flow.zig");
const sem = @import("vm_semantics.zig");
pub const Stats = struct { functions: u64 = 0, folded: u64 = 0, branches: u64 = 0, specialized: u64 = 0, removed_control: u64 = 0 };

pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var graph = try cg.build(a, p);
    defer graph.deinit();
    const seeds = try a.alloc(?[]flow.Fact, p.functions.items.len);
    defer a.free(seeds);
    @memset(seeds, null);
    defer for (seeds) |seed| if (seed) |facts| a.free(facts);
    var cursor: usize = 0;
    while (cursor < graph.calls.items.len) {
        const caller_id = graph.calls.items[cursor].caller;
        var end = cursor + 1;
        while (end < graph.calls.items.len and graph.calls.items[end].caller == caller_id) : (end += 1) {}
        const f = &p.functions.items[caller_id].?;
        var analysis = try flow.analyze(a, p, f, &.{});
        defer analysis.deinit();
        const state = try a.alloc(flow.Fact, f.reg_count);
        defer a.free(state);
        for (graph.calls.items[cursor..end]) |site| {
            if (!graph.closed[site.callee]) continue;
            if (analysis.entry[analysis.graph.block_of_pc[site.pc]] == null) continue;
            try flow.stateBefore(a, p, f, &analysis, site.pc, state);
            const inst = f.insts.items[site.pc];
            const regs = try sem.operands(f, inst);
            const n = p.functions.items[site.callee].?.param_count;
            const first = seeds[site.callee] == null;
            if (first) seeds[site.callee] = try a.alloc(flow.Fact, n);
            for (seeds[site.callee].?, 0..) |*seed, i| {
                const fact: flow.Fact = if (i < regs.len) state[regs[i]] else if (inst.op == .call or inst.op == .call_local) .{ .types = flow.nil_type, .literal = .nil } else .{};
                seed.* = if (first) fact else flow.merge(seed.*, fact, false);
            }
        }
        cursor = end;
    }
    var stats = Stats{};
    for (seeds, 0..) |seed, id| if (seed) |parameters| {
        var useful = false;
        for (parameters) |fact| if (fact.types != flow.any_type) {
            useful = true;
            break;
        };
        if (!useful) continue;
        const f = &p.functions.items[id].?;
        var analysis = try flow.analyze(a, p, f, parameters);
        defer analysis.deinit();
        const one = try flow.rewrite(a, p, f, &analysis);
        const changed = one.folded + one.branches + one.specialized + one.removed_control;
        if (changed != 0) stats.functions += 1;
        stats.folded += one.folded;
        stats.branches += one.branches;
        stats.specialized += one.specialized;
        stats.removed_control += one.removed_control;
    };
    return stats;
}
const lua = @import("root.zig");
const verify = @import("vm_verify.zig");
test "all non escaping callers prove a numeric parameter" {
    var chunk = try lua.parse(std.testing.allocator, "local function f(x) return x+1 end; return f(3),f(8)");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try verify.run(std.testing.allocator, &p);
    try std.testing.expect(stats.specialized != 0);
}
test "escaping function does not inherit one observed callers type" {
    var chunk = try lua.parse(std.testing.allocator, "local function f(x) return x+1 end; return f,f(3)");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try std.testing.expectEqual(@as(u64, 0), stats.functions);
}
test "mixed string and number arguments retain coercion semantics" {
    var chunk = try lua.parse(std.testing.allocator, "local function f(x) return x+1 end; return f(3),f('4')");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try std.testing.expectEqual(@as(u64, 0), stats.specialized);
}
