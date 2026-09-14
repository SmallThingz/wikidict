const std = @import("std");
const ir = @import("ir.zig");

pub const Block = struct {
    start: u32,
    end: u32,
    succ: [2]?u32 = .{ null, null },
    preds: std.ArrayList(u32) = .empty,

    fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.preds.deinit(allocator);
    }
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,
    block_of_pc: []u32 = &.{},

    pub fn deinit(self: *Graph) void {
        for (self.blocks.items) |*block| block.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        if (self.block_of_pc.len != 0) self.allocator.free(self.block_of_pc);
    }
};

fn hasTarget(op: ir.Opcode) bool {
    return switch (op) {
        .jump,
        .jump_if_false,
        .branch_compare,
        .numeric_for_init,
        .numeric_for_next,
        .generic_for_init,
        .generic_for_next,
        => true,
        else => false,
    };
}

fn terminatesBlock(op: ir.Opcode) bool {
    return hasTarget(op) or op == .ret or op == .ret_var;
}

fn addSucc(graph: *Graph, from: u32, to: u32) !void {
    if (from >= graph.blocks.items.len or to >= graph.blocks.items.len) return error.BadJumpTarget;
    const block = &graph.blocks.items[from];
    if (block.succ[0] == to or block.succ[1] == to) return;
    if (block.succ[0] == null) {
        block.succ[0] = to;
    } else if (block.succ[1] == null) {
        block.succ[1] = to;
    } else {
        return error.TooManySuccessors;
    }
    try graph.blocks.items[to].preds.append(graph.allocator, from);
}

pub fn build(allocator: std.mem.Allocator, function: *const ir.Function) !Graph {
    var graph = Graph{ .allocator = allocator };
    errdefer graph.deinit();

    const instruction_count = function.insts.items.len;
    if (instruction_count == 0) return graph;

    const boundary = try allocator.alloc(bool, instruction_count + 1);
    defer allocator.free(boundary);
    @memset(boundary, false);
    boundary[0] = true;
    boundary[instruction_count] = true;

    for (function.insts.items, 0..) |inst, pc| {
        if (hasTarget(inst.op)) {
            if (inst.aux > instruction_count) return error.BadJumpTarget;
            boundary[inst.aux] = true;
        }
        if (terminatesBlock(inst.op)) boundary[pc + 1] = true;
    }

    var start: usize = 0;
    var pc: usize = 1;
    while (pc <= instruction_count) : (pc += 1) {
        if (!boundary[pc]) continue;
        if (pc > start) {
            try graph.blocks.append(allocator, .{
                .start = @intCast(start),
                .end = @intCast(pc),
            });
        }
        start = pc;
    }

    graph.block_of_pc = try allocator.alloc(u32, instruction_count);
    for (graph.blocks.items, 0..) |block, block_index| {
        for (block.start..block.end) |block_pc| {
            graph.block_of_pc[block_pc] = @intCast(block_index);
        }
    }

    for (graph.blocks.items, 0..) |block, block_index_usize| {
        const block_index: u32 = @intCast(block_index_usize);
        const last = function.insts.items[block.end - 1];
        if (last.op == .ret or last.op == .ret_var) continue;

        const fallthrough_pc: usize = block.end;
        switch (last.op) {
            .jump => {
                if (last.aux < instruction_count) {
                    try addSucc(&graph, block_index, graph.block_of_pc[last.aux]);
                }
            },
            .jump_if_false,
            .branch_compare,
            .numeric_for_init,
            .numeric_for_next,
            .generic_for_init,
            .generic_for_next,
            => {
                if (last.aux < instruction_count) {
                    try addSucc(&graph, block_index, graph.block_of_pc[last.aux]);
                }
                if (fallthrough_pc < instruction_count) {
                    try addSucc(&graph, block_index, graph.block_of_pc[fallthrough_pc]);
                }
            },
            else => {
                if (fallthrough_pc < instruction_count) {
                    try addSucc(&graph, block_index, graph.block_of_pc[fallthrough_pc]);
                }
            },
        }
    }

    return graph;
}

test "CFG records branch join predecessors" {
    var function = ir.Function{};
    defer function.deinit(std.testing.allocator);
    try function.insts.appendSlice(std.testing.allocator, &.{
        .{ .op = .load_bool, .dst = 0, .a = 1 },
        .{ .op = .jump_if_false, .a = 0, .aux = 4 },
        .{ .op = .load_nil, .dst = 1 },
        .{ .op = .jump, .aux = 5 },
        .{ .op = .load_bool, .dst = 1, .a = 1 },
        .{ .op = .ret, .count = 0 },
    });

    var graph = try build(std.testing.allocator, &function);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 4), graph.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), graph.blocks.items[3].preds.items.len);
}
