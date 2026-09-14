const std = @import("std");
const ir = @import("ir.zig");
const cfg = @import("graph.zig");
const sem = @import("semantics.zig");

const Bits = std.DynamicBitSetUnmanaged;

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    live_in: []Bits,
    uses: []Bits,
    defs: []Bits,

    pub fn deinit(self: *Analysis) void {
        for (self.live_in) |*bits| bits.deinit(self.allocator);
        for (self.uses) |*bits| bits.deinit(self.allocator);
        for (self.defs) |*bits| bits.deinit(self.allocator);
        self.allocator.free(self.live_in);
        self.allocator.free(self.uses);
        self.allocator.free(self.defs);
    }

    pub fn isLiveIn(self: *const Analysis, block: u32, reg: u32) bool {
        if (block >= self.live_in.len) return false;
        if (reg >= self.live_in[block].bit_length) return false;
        return self.live_in[block].isSet(reg);
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    graph: *const cfg.Graph,
) !Analysis {
    const block_count = graph.blocks.items.len;
    const live_in = try allocator.alloc(Bits, block_count);
    const uses = try allocator.alloc(Bits, block_count);
    const defs = try allocator.alloc(Bits, block_count);

    var initialized: usize = 0;
    errdefer {
        for (0..initialized) |i| {
            live_in[i].deinit(allocator);
            uses[i].deinit(allocator);
            defs[i].deinit(allocator);
        }
        allocator.free(live_in);
        allocator.free(uses);
        allocator.free(defs);
    }

    for (0..block_count) |i| {
        live_in[i] = try Bits.initEmpty(allocator, function.reg_count);
        uses[i] = try Bits.initEmpty(allocator, function.reg_count);
        defs[i] = try Bits.initEmpty(allocator, function.reg_count);
        initialized += 1;
    }

    // One exhaustive operand contract for allocation, verification and encoding.
    var reads = try Bits.initEmpty(allocator, function.reg_count);
    defer reads.deinit(allocator);
    for (graph.blocks.items, 0..) |block, block_index| {
        for (block.start..block.end) |pc| {
            const inst = function.insts.items[pc];
            reads.unsetAll();
            try sem.reads(program, function, inst, &reads);
            var it = reads.iterator(.{});
            while (it.next()) |reg| if (!defs[block_index].isSet(reg)) {
                uses[block_index].set(reg);
            };
            // Keep the conservative union for edge-specific loop definitions.
            if (!sem.info(inst.op).target) try sem.writes(inst, null, &defs[block_index]);
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        var block_index = block_count;
        while (block_index > 0) {
            block_index -= 1;
            var next = try Bits.initEmpty(allocator, function.reg_count);
            defer next.deinit(allocator);
            for (graph.blocks.items[block_index].succ) |maybe_succ| {
                if (maybe_succ) |succ| next.setUnion(live_in[succ]);
            }

            var not_defs = try defs[block_index].clone(allocator);
            defer not_defs.deinit(allocator);
            not_defs.toggleAll();
            next.setIntersection(not_defs);
            next.setUnion(uses[block_index]);

            if (!next.eql(live_in[block_index])) {
                live_in[block_index].unsetAll();
                live_in[block_index].setUnion(next);
                changed = true;
            }
        }
    }

    return .{ .allocator = allocator, .live_in = live_in, .uses = uses, .defs = defs };
}

test "liveness excludes dead branch temporary at join" {
    var program = ir.Program{ .allocator = std.testing.allocator };
    defer program.deinit();
    var function = ir.Function{ .param_count = 1, .reg_count = 3 };
    try function.insts.appendSlice(std.testing.allocator, &.{
        .{ .op = .jump_if_false, .a = 0, .aux = 3 },
        .{ .op = .load_bool, .dst = 1, .a = 1 },
        .{ .op = .jump, .aux = 4 },
        .{ .op = .load_nil, .dst = 1 },
        .{ .op = .load_bool, .dst = 2, .a = 1 },
        .{ .op = .ret, .count = 0 },
    });
    try program.functions.append(std.testing.allocator, function);

    var graph = try cfg.build(std.testing.allocator, &program.functions.items[0].?);
    defer graph.deinit();
    var analysis = try build(std.testing.allocator, &program, &program.functions.items[0].?, &graph);
    defer analysis.deinit();
    try std.testing.expect(!analysis.isLiveIn(graph.block_of_pc[4], 1));
}
