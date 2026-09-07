const std = @import("std");
const ir = @import("vm_ir.zig");
const callgraph = @import("vm_callgraph.zig");
pub const Stats = struct { calls: u64 = 0, scoped_calls: u64 = 0, closures: u64 = 0 };

// Resolved noncapturing functions need no closure object, environment lookup,
// or callable tag dispatch. Escaping identities are retained by ordinary DCE.
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var graph = try callgraph.build(a, p);
    defer graph.deinit();
    var stats = Stats{};
    for (graph.calls.items) |site| {
        const target = p.functions.items[site.callee] orelse return error.BadFunctionReference;
        if (target.upvalues.items.len != 0) continue;
        const inst = &p.functions.items[site.caller].?.insts.items[site.pc];
        if (inst.op != .call and inst.op != .call_vararg) continue;
        inst.op = if (inst.op == .call) .call_local else .call_local_vararg;
        inst.a = site.callee;
        stats.calls += 1;
    }
    return stats;
}

const cfg = @import("vm_graph.zig");
// A nonescaping closure can borrow its defining activation's cells directly.
// Dominance and capture lifetimes allow calls across branches and loops.
// This is a lifetime proof, not an assumption that one call site runs once.
pub fn runScoped(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var graph = try callgraph.build(a, p);
    defer graph.deinit();
    const safe = try a.dupe(bool, graph.closed);
    defer a.free(safe);
    var cursor: usize = 0;
    while (cursor < graph.calls.items.len) {
        const caller = graph.calls.items[cursor].caller;
        var end = cursor + 1;
        while (end < graph.calls.items.len and graph.calls.items[end].caller == caller) : (end += 1) {}
        const f = &p.functions.items[caller].?;
        var blocks = try cfg.build(a, f);
        defer blocks.deinit();
        for (graph.calls.items[cursor..end]) |site| {
            const child = &p.functions.items[site.callee].?;
            if (!safe[site.callee] or child.upvalues.items.len == 0) continue;
            const creation_block = blocks.block_of_pc[site.closure_pc];
            const call_block = blocks.block_of_pc[site.pc];
            const same_block = creation_block == call_block;
            if ((same_block and site.closure_pc >= site.pc) or
                (!same_block and !try dominates(a, &blocks, creation_block, call_block)))
            {
                safe[site.callee] = false;
                continue;
            }
            // Across control flow, reject any possible cell-identity reset in
            // this activation. Shared value mutations are safe: pass cells,
            // not copied values. Same-block calls admit the narrower interval.
            const interval = if (same_block) f.insts.items[site.closure_pc + 1 .. site.pc] else f.insts.items;
            for (interval) |inst| if (inst.op == .detach_cell) {
                for (child.upvalues.items) |up| if (up.source == .local and up.index == inst.a) {
                    safe[site.callee] = false;
                };
            };
        }
        cursor = end;
    }
    var stats = Stats{};
    for (graph.calls.items) |site| {
        if (!safe[site.callee] or p.functions.items[site.callee].?.upvalues.items.len == 0) continue;
        const f = &p.functions.items[site.caller].?;
        const inst = &f.insts.items[site.pc];
        if (inst.op != .call and inst.op != .call_vararg) continue;
        inst.op = if (inst.op == .call) .call_scoped else .call_scoped_vararg;
        inst.a = site.callee;
        stats.scoped_calls += 1;
        const creation = &f.insts.items[site.closure_pc];
        if (creation.op == .closure) {
            creation.* = .{ .op = .load_nil, .dst = creation.dst };
            stats.closures += 1;
        }
    }
    return stats;
}

// The defining block dominates the use exactly when removing it makes the use
// unreachable from the function entry. Cost is compile-time only.
fn dominates(a: std.mem.Allocator, graph: *const cfg.Graph, definition: u32, target: u32) !bool {
    if (definition == 0 or definition == target) return true;
    const visited = try a.alloc(bool, graph.blocks.items.len);
    defer a.free(visited);
    @memset(visited, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    try work.append(a, 0);
    visited[0] = true;
    while (work.pop()) |block| {
        if (block == target) return false;
        for (graph.blocks.items[block].succ) |successor| if (successor) |next| {
            if (next == definition or visited[next]) continue;
            visited[next] = true;
            try work.append(a, next);
        };
    }
    return true;
}
