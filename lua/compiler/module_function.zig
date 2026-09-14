const std = @import("std");
const ir = @import("ir.zig");
const cfg = @import("graph.zig");

pub const Stats = struct {
    functions: u64 = 0,
    captured_functions: u64 = 0,
    cyclic: u64 = 0,
    detached: u64 = 0,
    outer_upvalue: u64 = 0,
};

fn reaches(a: std.mem.Allocator, graph: *const cfg.Graph, start: u32, target: u32) !bool {
    const seen = try a.alloc(bool, graph.blocks.items.len);
    defer a.free(seen);
    @memset(seen, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    try work.append(a, start);
    seen[start] = true;
    while (work.pop()) |block| {
        if (block == target) return true;
        for (graph.blocks.items[block].succ) |next_opt| if (next_opt) |next| {
            if (seen[next]) continue;
            seen[next] = true;
            try work.append(a, next);
        };
    }
    return false;
}
fn cyclicBlock(a: std.mem.Allocator, graph: *const cfg.Graph, block: u32) !bool {
    for (graph.blocks.items[block].succ) |next_opt| if (next_opt) |next| {
        if (try reaches(a, graph, next, block)) return true;
    };
    return false;
}

const CaptureStatus = enum { safe, detached, outer_upvalue };
fn captureStatus(root: *const ir.Function, child: *const ir.Function) CaptureStatus {
    for (child.upvalues.items) |up| {
        if (up.source != .local or up.index >= root.reg_count) return .outer_upvalue;
        for (root.insts.items) |inst| {
            if (inst.op == .detach_cell and inst.a == up.index) return .detached;
        }
    }
    return .safe;
}

pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    if (p.module_roots.items.len == 0) return stats;
    for (p.module_roots.items) |root_id| {
        if (root_id >= p.functions.items.len) return error.BadFunctionReference;
        const root = &(p.functions.items[root_id] orelse return error.IncompleteProgram);
        var graph = try cfg.build(a, root);
        defer graph.deinit();
        const cyclic = try a.alloc(?bool, graph.blocks.items.len);
        defer a.free(cyclic);
        @memset(cyclic, null);
        for (root.insts.items, 0..) |*inst, pc| {
            if (inst.op != .closure) continue;
            if (inst.aux >= p.functions.items.len) return error.BadFunctionReference;
            const child = p.functions.items[inst.aux] orelse return error.IncompleteProgram;
            const block = graph.block_of_pc[pc];
            const repeats = if (cyclic[block]) |value| value else blk: {
                const value = try cyclicBlock(a, &graph, block);
                cyclic[block] = value;
                break :blk value;
            };
            if (repeats) {
                stats.cyclic += 1;
                continue;
            }
            switch (captureStatus(root, &child)) {
                .safe => {},
                .detached => {
                    stats.detached += 1;
                    continue;
                },
                .outer_upvalue => {
                    stats.outer_upvalue += 1;
                    continue;
                },
            }
            inst.op = .load_function;
            stats.functions += 1;
            stats.captured_functions += @intFromBool(child.upvalues.items.len != 0);
        }
    }
    return stats;
}
