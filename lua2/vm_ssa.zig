const sem = @import("vm_semantics.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const cfg = @import("vm_graph.zig");
const live = @import("vm_liveness.zig");

pub const ValueId = u32;
pub const invalid_value: ValueId = std.math.maxInt(ValueId);

pub const ValueKind = enum {
    parameter,
    instruction,
    phi,
    memory,
};

pub const Value = struct {
    kind: ValueKind,
    reg: u32,
    pc: u32 = std.math.maxInt(u32),
    block: u32 = std.math.maxInt(u32),
    uses: u32 = 0,
};

pub const Phi = struct {
    block: u32,
    reg: u32,
    value: ValueId,
    inputs: std.ArrayList(ValueId) = .empty,

    fn deinit(self: *Phi, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
    }
};

pub const Function = struct {
    allocator: std.mem.Allocator,
    graph: cfg.Graph,
    liveness: live.Analysis,
    values: std.ArrayList(Value) = .empty,
    phis: std.ArrayList(Phi) = .empty,
    captured: []bool,
    entry_states: []?[]ValueId,
    entry_seed: []ValueId = &.{},

    canonical: []ValueId = &.{},
    def_ids: std.AutoHashMapUnmanaged(u64, ValueId) = .empty,
    phi_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub fn deinit(self: *Function) void {
        for (self.phis.items) |*phi| phi.deinit(self.allocator);
        self.phis.deinit(self.allocator);
        self.values.deinit(self.allocator);
        for (self.entry_states) |state| {
            if (state) |items| self.allocator.free(items);
        }
        if (self.entry_states.len != 0) self.allocator.free(self.entry_states);
        if (self.entry_seed.len != 0) self.allocator.free(self.entry_seed);

        if (self.captured.len != 0) self.allocator.free(self.captured);
        if (self.canonical.len != 0) self.allocator.free(self.canonical);
        self.def_ids.deinit(self.allocator);
        self.phi_ids.deinit(self.allocator);
        self.liveness.deinit();
        self.graph.deinit();
    }

    pub fn canonicalValue(self: *const Function, start: ValueId) ValueId {
        if (start == invalid_value or start >= self.canonical.len) return start;
        var id = start;
        var steps: usize = 0;
        while (self.canonical[id] != id and steps < self.canonical.len) : (steps += 1) {
            id = self.canonical[id];
        }
        return id;
    }
};

fn pairKey(high: u32, low: u32) u64 {
    return (@as(u64, high) << 32) | low;
}

fn addValue(out: *Function, value: Value) !ValueId {
    if (out.values.items.len >= invalid_value) return error.TooManyValues;
    const id: ValueId = @intCast(out.values.items.len);
    try out.values.append(out.allocator, value);
    return id;
}

fn defValue(out: *Function, pc: u32, reg: u32) !ValueId {
    const key = pairKey(pc, reg);
    if (out.def_ids.get(key)) |id| return id;
    const id = try addValue(out, .{ .kind = .instruction, .reg = reg, .pc = pc });
    try out.def_ids.put(out.allocator, key, id);
    return id;
}

fn phiValue(out: *Function, block: u32, reg: u32) !ValueId {
    const key = pairKey(block, reg);
    if (out.phi_ids.get(key)) |index| return out.phis.items[index].value;
    const value = try addValue(out, .{ .kind = .phi, .reg = reg, .block = block });
    const index: u32 = @intCast(out.phis.items.len);
    try out.phis.append(out.allocator, .{ .block = block, .reg = reg, .value = value });
    try out.phi_ids.put(out.allocator, key, index);
    return value;
}

fn markCaptured(allocator: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function) ![]bool {
    const captured = try allocator.alloc(bool, function.reg_count);
    @memset(captured, false);
    for (function.insts.items) |inst| {
        const target = sem.captureTarget(inst) orelse continue;
        if (target >= program.functions.items.len) return error.BadFunctionReference;
        if (program.functions.items[target]) |child| {
            for (child.upvalues.items) |upvalue| {
                if (upvalue.source == .local and upvalue.index < captured.len) {
                    captured[upvalue.index] = true;
                }
            }
        }
    }
    return captured;
}

fn singleDest(op: ir.Opcode) bool {
    return switch (op) {
        .load_nil,
        .load_bool,
        .load_number,
        .load_string,
        .load_const,
        .get_global,
        .get_global_slot,
        .get_upvalue,
        .new_table,
        .new_table_shape,
        .get_index,
        .get_field,
        .get_slot,
        .get_choice_slot,
        .closure,
        .load_function,
        .add_number,
        .sub_number,
        .mul_number,
        .div_number,
        .mod_number,
        .pow_number,
        .eq_number,
        .ne_number,
        .lt_number,
        .le_number,
        .gt_number,
        .ge_number,
        .neg_number,
        .len_string,
        .neg,
        .not_,
        .len,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .pow,
        .concat,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        => true,
        else => false,
    };
}

fn setDef(out: *Function, state: []ValueId, pc: u32, reg: u32) !void {
    if (reg >= state.len) return error.BadRegister;
    if (out.captured[reg]) return;
    state[reg] = try defValue(out, pc, reg);
}

fn setDefs(out: *Function, state: []ValueId, pc: u32, base: u32, count: u32) !void {
    if (count == 0) return;
    if (count == ir.multi_count) {
        try setDef(out, state, pc, base);
        return;
    }
    if (@as(u64, base) + count > state.len) return error.BadRegister;
    var i: u32 = 0;
    while (i < count) : (i += 1) try setDef(out, state, pc, base + i);
}

pub fn applyWrites(
    out: *Function,
    function: *const ir.Function,
    state: []ValueId,
    pc: u32,
    successor: ?u32,
) !void {
    const inst = function.insts.items[pc];
    if (inst.op == .move) {
        if (inst.dst >= state.len or inst.a >= state.len) return error.BadRegister;
        if (!out.captured[inst.dst]) state[inst.dst] = state[inst.a];
        return;
    }
    if (singleDest(inst.op)) {
        try setDef(out, state, pc, inst.dst);
        return;
    }

    switch (inst.op) {
        .vararg, .call, .call_vararg, .method_call, .method_call_vararg, .method_call_field, .method_call_field_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg, .direct_call, .direct_call_vararg => {
            try setDefs(out, state, pc, inst.dst, inst.count);
        },
        .numeric_for_init => {
            if (successor) |succ| {
                const target: ?u32 = if (inst.aux < function.insts.items.len)
                    out.graph.block_of_pc[inst.aux]
                else
                    null;
                if (target == null or succ != target.?) try setDef(out, state, pc, inst.dst);
            }
        },
        .numeric_for_next => {
            // The hidden control value is incremented on both outgoing edges.
            try setDef(out, state, pc, inst.a);
            if (successor) |succ| {
                if (inst.aux < function.insts.items.len and succ == out.graph.block_of_pc[inst.aux]) {
                    try setDef(out, state, pc, inst.dst);
                }
            }
        },
        .generic_for_init => {
            if (successor) |succ| {
                const target: ?u32 = if (inst.aux < function.insts.items.len)
                    out.graph.block_of_pc[inst.aux]
                else
                    null;
                if (target == null or succ != target.?) {
                    try setDef(out, state, pc, inst.c);
                    try setDefs(out, state, pc, inst.dst, inst.count);
                }
            }
        },
        .generic_for_next => {
            if (successor) |succ| {
                if (inst.aux < function.insts.items.len and succ == out.graph.block_of_pc[inst.aux]) {
                    try setDef(out, state, pc, inst.c);
                    try setDefs(out, state, pc, inst.dst, inst.count);
                }
            }
        },
        else => {},
    }
}

fn simulateTo(
    out: *Function,
    function: *const ir.Function,
    block: u32,
    input: []const ValueId,
    successor: ?u32,
    dest: []ValueId,
) !void {
    @memcpy(dest, input);
    const cfg_block = out.graph.blocks.items[block];
    for (cfg_block.start..cfg_block.end) |pc_usize| {
        const pc: u32 = @intCast(pc_usize);
        const is_last = pc_usize + 1 == cfg_block.end;
        try applyWrites(out, function, dest, pc, if (is_last) successor else null);
    }
}

fn mergeEntry(out: *Function, block: u32, incoming: []const ValueId) !bool {
    if (out.entry_states[block] == null) {
        out.entry_states[block] = try out.allocator.dupe(ValueId, incoming);
        return true;
    }

    const current = out.entry_states[block].?;
    var changed = false;
    for (current, incoming, 0..) |*dst, src, reg_usize| {
        const reg: u32 = @intCast(reg_usize);
        if (out.captured[reg]) continue;
        if (dst.* == src) continue;
        if (!out.liveness.isLiveIn(block, reg)) continue;
        const phi = try phiValue(out, block, reg);
        if (dst.* != phi) {
            dst.* = phi;
            changed = true;
        }
    }
    return changed;
}

fn buildStates(out: *Function, function: *const ir.Function) !void {
    if (out.graph.blocks.items.len == 0) return;

    const initial = try out.allocator.alloc(ValueId, function.reg_count);
    defer out.allocator.free(initial);
    @memset(initial, invalid_value);

    for (0..function.reg_count) |reg_usize| {
        const reg: u32 = @intCast(reg_usize);
        if (out.captured[reg]) {
            initial[reg] = try addValue(out, .{ .kind = .memory, .reg = reg });
        }
    }

    var reg: u32 = 0;
    while (reg < function.param_count and reg < function.reg_count) : (reg += 1) {
        if (!out.captured[reg]) {
            initial[reg] = try addValue(out, .{ .kind = .parameter, .reg = reg });
        }
    }
    out.entry_states[0] = try out.allocator.dupe(ValueId, initial);
    out.entry_seed = try out.allocator.dupe(ValueId, initial);

    const queued = try out.allocator.alloc(bool, out.graph.blocks.items.len);
    defer out.allocator.free(queued);
    @memset(queued, false);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(out.allocator);
    try queue.append(out.allocator, 0);
    queued[0] = true;

    const scratch = try out.allocator.alloc(ValueId, function.reg_count);
    defer out.allocator.free(scratch);

    while (queue.pop()) |block| {
        queued[block] = false;
        const input = out.entry_states[block] orelse continue;
        for (out.graph.blocks.items[block].succ) |maybe_succ| {
            if (maybe_succ) |succ| {
                try simulateTo(out, function, block, input, succ, scratch);
                if (try mergeEntry(out, succ, scratch)) {
                    if (!queued[succ]) {
                        queued[succ] = true;
                        try queue.append(out.allocator, succ);
                    }
                }
            }
        }
    }
}

fn fillPhiInputs(out: *Function, function: *const ir.Function) !void {
    const scratch = try out.allocator.alloc(ValueId, function.reg_count);
    defer out.allocator.free(scratch);
    for (out.phis.items) |*phi| {
        // Block zero has an implicit predecessor: entry into the function.
        // Without this input, a backedge can alias a parameter to the value
        // replacing it and erase the loop-carried assignment.
        if (phi.block == 0) try phi.inputs.append(out.allocator, out.entry_seed[phi.reg]);
        for (out.graph.blocks.items[phi.block].preds.items) |pred| {
            const input = out.entry_states[pred] orelse continue;
            try simulateTo(out, function, pred, input, phi.block, scratch);
            try phi.inputs.append(out.allocator, scratch[phi.reg]);
        }
    }
}

fn simplifyPhis(out: *Function) void {
    for (out.canonical, 0..) |*slot, index| slot.* = @intCast(index);

    var changed = true;
    while (changed) {
        changed = false;
        for (out.phis.items) |phi| {
            if (out.canonicalValue(phi.value) != phi.value) continue;
            var candidate: ValueId = invalid_value;
            var nontrivial = false;
            for (phi.inputs.items) |raw_input| {
                const input = out.canonicalValue(raw_input);
                if (input == invalid_value) {
                    nontrivial = true;
                    break;
                }
                if (input == phi.value) continue;
                if (candidate == invalid_value) {
                    candidate = input;
                } else if (candidate != input) {
                    nontrivial = true;
                    break;
                }
            }
            if (!nontrivial and candidate != invalid_value) {
                out.canonical[phi.value] = candidate;
                changed = true;
            }
        }
    }

    for (out.canonical, 0..) |*slot, index| {
        slot.* = out.canonicalValue(@intCast(index));
    }
    for (out.entry_states) |maybe_state| {
        if (maybe_state) |state| {
            for (state) |*id| id.* = out.canonicalValue(id.*);
        }
    }
    for (out.phis.items) |*phi| {
        for (phi.inputs.items) |*id| id.* = out.canonicalValue(id.*);
    }
}

fn use(out: *Function, raw_id: ValueId) void {
    const id = out.canonicalValue(raw_id);
    if (id == invalid_value or id >= out.values.items.len) return;
    out.values.items[id].uses +|= 1;
}

fn useReg(out: *Function, state: []const ValueId, reg: u32) void {
    if (reg < state.len) use(out, state[reg]);
}

fn useOperands(out: *Function, state: []const ValueId, function: *const ir.Function, at: u32, count: u32) void {
    if (@as(usize, at) + count > function.operands.items.len) return;
    for (function.operands.items[at .. at + count]) |reg| useReg(out, state, reg);
}

fn countReads(out: *Function, program: *const ir.Program, function: *const ir.Function, state: []const ValueId, inst: ir.Inst) void {
    switch (inst.op) {
        .set_global_slot, .set_global, .check_table_key => useReg(out, state, inst.a),
        .set_upvalue => useReg(out, state, inst.b),
        .move => {
            // A normal move is an SSA alias and disappears. A move into a
            // captured register is a memory-cell store and therefore a use.
            if (inst.dst < out.captured.len and out.captured[inst.dst]) useReg(out, state, inst.a);
        },
        .jump_if_false, .neg, .not_, .len, .neg_number, .len_string => useReg(out, state, inst.a),
        .table_set, .set_index => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.b);
            useReg(out, state, inst.c);
        },
        .table_append, .table_append_var => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.b);
        },
        .get_index, .add, .sub, .mul, .div, .mod, .pow, .eq, .ne, .lt, .le, .gt, .ge, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.b);
        },
        .get_field, .get_slot => useReg(out, state, inst.a),
        .get_choice_slot => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.b);
        },
        .set_slot => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.c);
        },
        .set_choice_slot => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.b);
            useReg(out, state, inst.c);
        },
        .set_field => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.c);
        },
        .closure => {
            if (inst.aux < program.functions.items.len) {
                if (program.functions.items[inst.aux]) |child| {
                    for (child.upvalues.items) |upvalue| {
                        if (upvalue.source == .local) useReg(out, state, upvalue.index);
                    }
                }
            }
        },
        .register_function => useReg(out, state, inst.a),
        .concat => useOperands(out, state, function, inst.aux, inst.count),
        .call, .call_vararg => {
            useReg(out, state, inst.a);
            useOperands(out, state, function, inst.aux, inst.b);
            if (inst.op == .call_vararg) useReg(out, state, inst.c);
        },
        .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg, .direct_call, .direct_call_vararg => {
            useOperands(out, state, function, inst.aux, inst.b);
            if (inst.op == .direct_call_vararg or inst.op == .call_scoped_vararg or inst.op == .call_local_vararg) useReg(out, state, inst.c);
            if (sem.captureTarget(inst)) |target| for (program.functions.items[target].?.upvalues.items) |up| {
                if (up.source == .local) useReg(out, state, up.index);
            };
        },
        .method_call, .method_call_vararg => {
            useOperands(out, state, function, inst.aux, inst.b);
            if (inst.op == .method_call_vararg) useReg(out, state, inst.c);
        },
        .method_call_field, .method_call_field_vararg => {
            useOperands(out, state, function, inst.aux, inst.b);
            if (inst.op == .method_call_field_vararg) useReg(out, state, inst.c);
        },
        .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => {
            useReg(out, state, inst.a);
            useReg(out, state, inst.b);
            useReg(out, state, inst.c);
        },
        .ret => useOperands(out, state, function, inst.aux, inst.count),
        .ret_var => {
            useOperands(out, state, function, inst.aux, inst.count);
            useReg(out, state, inst.a);
        },
        else => {},
    }
}

fn countUses(out: *Function, program: *const ir.Program, function: *const ir.Function) !void {
    for (out.phis.items) |phi| {
        if (out.canonicalValue(phi.value) != phi.value) continue;
        for (phi.inputs.items) |input| {
            if (input != phi.value) use(out, input);
        }
    }

    const state = try out.allocator.alloc(ValueId, function.reg_count);
    defer out.allocator.free(state);
    for (out.graph.blocks.items, 0..) |block, block_index| {
        const input = out.entry_states[block_index] orelse continue;
        @memcpy(state, input);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            countReads(out, program, function, state, inst);
            try applyWrites(out, function, state, pc, null);
        }
    }
}

pub fn build(allocator: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function) !Function {
    var graph = try cfg.build(allocator, function);
    errdefer graph.deinit();
    var liveness = try live.build(allocator, program, function, &graph);
    errdefer liveness.deinit();
    const captured = try markCaptured(allocator, program, function);
    errdefer if (captured.len != 0) allocator.free(captured);
    const entry_states = try allocator.alloc(?[]ValueId, graph.blocks.items.len);
    errdefer if (entry_states.len != 0) allocator.free(entry_states);
    @memset(entry_states, null);

    var out = Function{
        .allocator = allocator,
        .graph = graph,
        .liveness = liveness,
        .captured = captured,
        .entry_states = entry_states,
    };
    errdefer out.deinit();

    try buildStates(&out, function);
    // Freeze ValueId arrays only after materializing terminal-block definitions.
    const terminal_state = try allocator.alloc(ValueId, function.reg_count);
    defer allocator.free(terminal_state);
    for (out.graph.blocks.items, 0..) |block, bid| {
        const input = out.entry_states[bid] orelse continue;
        if (block.succ[0] == null and block.succ[1] == null)
            try simulateTo(&out, function, @intCast(bid), input, null, terminal_state);
    }
    try fillPhiInputs(&out, function);
    if (out.values.items.len != 0) {
        out.canonical = try allocator.alloc(ValueId, out.values.items.len);
        simplifyPhis(&out);
    }
    try countUses(&out, program, function);
    return out;
}

pub fn stateBefore(self: *Function, function: *const ir.Function, pc: u32, dest: []ValueId) !void {
    if (pc >= function.insts.items.len) return error.BadPc;
    if (dest.len != function.reg_count) return error.BadStateSize;
    const block = self.graph.block_of_pc[pc];
    const input = self.entry_states[block] orelse return error.UnreachableBlock;
    @memcpy(dest, input);
    const cfg_block = self.graph.blocks.items[block];
    for (cfg_block.start..pc) |prior_pc| {
        try applyWrites(self, function, dest, @intCast(prior_pc), null);
    }
    for (dest) |*id| id.* = self.canonicalValue(id.*);
}

test "SSA aliases moves and prunes dead branch values" {
    var program = ir.Program{ .allocator = std.testing.allocator };
    defer program.deinit();
    var function = ir.Function{ .param_count = 1, .reg_count = 4 };
    try function.insts.appendSlice(std.testing.allocator, &.{
        .{ .op = .move, .dst = 1, .a = 0 },
        .{ .op = .jump_if_false, .a = 0, .aux = 4 },
        .{ .op = .load_bool, .dst = 2, .a = 1 },
        .{ .op = .jump, .aux = 5 },
        .{ .op = .load_nil, .dst = 2 },
        .{ .op = .move, .dst = 3, .a = 1 },
        .{ .op = .ret, .count = 0 },
    });
    try program.functions.append(std.testing.allocator, function);

    var ssa = try build(std.testing.allocator, &program, &program.functions.items[0].?);
    defer ssa.deinit();
    try std.testing.expectEqual(@as(usize, 0), ssa.phis.items.len);
    try std.testing.expect(ssa.def_ids.get(pairKey(0, 1)) == null);
}

test "SSA inserts one live branch phi" {
    var program = ir.Program{ .allocator = std.testing.allocator };
    defer program.deinit();
    var function = ir.Function{ .param_count = 1, .reg_count = 3 };
    try function.operands.append(std.testing.allocator, 1);
    try function.insts.appendSlice(std.testing.allocator, &.{
        .{ .op = .jump_if_false, .a = 0, .aux = 3 },
        .{ .op = .load_bool, .dst = 1, .a = 1 },
        .{ .op = .jump, .aux = 4 },
        .{ .op = .load_nil, .dst = 1 },
        .{ .op = .ret, .aux = 0, .count = 1 },
    });
    try program.functions.append(std.testing.allocator, function);

    var ssa = try build(std.testing.allocator, &program, &program.functions.items[0].?);
    defer ssa.deinit();
    try std.testing.expectEqual(@as(usize, 1), ssa.phis.items.len);
    try std.testing.expectEqual(@as(u32, 1), ssa.phis.items[0].reg);
}

test "SSA numeric loop carries loop variable through header phi" {
    var program = ir.Program{ .allocator = std.testing.allocator };
    defer program.deinit();
    var function = ir.Function{ .reg_count = 5 };
    try function.insts.appendSlice(std.testing.allocator, &.{
        .{ .op = .load_number, .dst = 0 },
        .{ .op = .load_number, .dst = 1 },
        .{ .op = .load_number, .dst = 2 },
        .{ .op = .new_table, .dst = 4 },
        .{ .op = .numeric_for_init, .dst = 3, .a = 0, .b = 1, .c = 2, .aux = 7 },
        .{ .op = .table_append, .a = 4, .b = 3 },
        .{ .op = .numeric_for_next, .dst = 3, .a = 0, .b = 1, .c = 2, .aux = 5 },
        .{ .op = .ret, .count = 0 },
    });
    try program.functions.append(std.testing.allocator, function);

    var ssa = try build(std.testing.allocator, &program, &program.functions.items[0].?);
    defer ssa.deinit();
    var saw_loop_phi = false;
    for (ssa.phis.items) |phi| {
        if (phi.reg == 3 and ssa.canonicalValue(phi.value) == phi.value) saw_loop_phi = true;
    }
    try std.testing.expect(saw_loop_phi);
}
