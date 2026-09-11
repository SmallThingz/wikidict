const std = @import("std");
const ir = @import("vm_ir.zig");
const sem = @import("vm_semantics.zig");
const ssa = @import("vm_ssa.zig");
const facts_mod = @import("vm_link_facts.zig");
const symbols_mod = @import("vm_link_symbols.zig");

const Fact = facts_mod.Fact;

pub const UnknownReason = enum {
    none,
    mutated,
    parameter,
    detached,
    no_writes,
    unknown_write,
    unknown_write_upvalue,
    unknown_write_call,
    unknown_write_field,
    unknown_write_index,
    unknown_write_global,
    unknown_write_move,
    unknown_write_loop,
    unknown_write_nil,
    unknown_write_literal,
    unknown_write_vararg,
    unknown_write_table,
    unknown_write_unary,
    unknown_write_binary,
    unknown_write_concat,
    unknown_write_other,
    conflicting_writes,
    conflicting_sources,
    unresolved_chain,
};

const Edge = struct {
    parent: u32,
    child_upvalue: usize,
    source: ir.Upvalue,
};

pub const Stats = struct {
    stable_locals: u64 = 0,
    stable_multiwrite_locals: u64 = 0,
    known_upvalues: u64 = 0,
    module_upvalues: u64 = 0,
    function_upvalues: u64 = 0,
    native_global_upvalues: u64 = 0,
    native_namespace_upvalues: u64 = 0,
    native_field_upvalues: u64 = 0,
    native_field_candidate_upvalues: u64 = 0,
    function_candidate_upvalues: u64 = 0,
    guard_only_upvalues: u64 = 0,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    offsets: []usize,
    facts: []Fact,
    guard_facts: []Fact,
    reasons: []UnknownReason,
    stats: Stats,
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.offsets);
        if (self.facts.len != 0) self.allocator.free(self.facts);
        if (self.guard_facts.len != 0) self.allocator.free(self.guard_facts);
        if (self.reasons.len != 0) self.allocator.free(self.reasons);
    }

    pub fn forFunction(self: *const Result, program: *const ir.Program, function_id: u32) []const Fact {
        if (function_id >= program.functions.items.len) return &.{};
        return self.facts[self.offsets[function_id]..self.offsets[function_id + 1]];
    }

    pub fn guardsForFunction(self: *const Result, program: *const ir.Program, function_id: u32) []const Fact {
        if (function_id >= program.functions.items.len) return &.{};
        return self.guard_facts[self.offsets[function_id]..self.offsets[function_id + 1]];
    }

    pub fn reasonsForFunction(self: *const Result, program: *const ir.Program, function_id: u32) []const UnknownReason {
        if (function_id >= program.functions.items.len) return &.{};
        return self.reasons[self.offsets[function_id]..self.offsets[function_id + 1]];
    }
};

fn hasFact(fact: Fact) bool {
    return switch (fact) {
        .unknown => false,
        else => true,
    };
}
fn makeOffsets(a: std.mem.Allocator, program: *const ir.Program, upvalues: bool) ![]usize {
    const out = try a.alloc(usize, program.functions.items.len + 1);
    out[0] = 0;
    for (program.functions.items, 0..) |maybe, id| {
        out[id + 1] = out[id] + if (maybe) |function|
            if (upvalues) function.upvalues.items.len else function.reg_count
        else
            0;
    }
    return out;
}

fn noteWrite(captured: []const bool, counts: []u8, flat: usize) void {
    if (flat >= captured.len or !captured[flat]) return;
    counts[flat] +|= 1;
}
fn noteInstructionWrites(
    function: *const ir.Function,
    base: usize,
    captured: []const bool,
    counts: []u8,
    inst: ir.Inst,
) void {
    const info = sem.info(inst.op);
    if (info.defines and inst.dst < function.reg_count)
        noteWrite(captured, counts, base + inst.dst);
    if (info.results) {
        const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
        var i: u32 = 0;
        while (i < width and inst.dst + i < function.reg_count) : (i += 1)
            noteWrite(captured, counts, base + inst.dst + i);
    }
    switch (inst.op) {
        .numeric_for_init => if (inst.dst < function.reg_count)
            noteWrite(captured, counts, base + inst.dst),
        .numeric_for_next => {
            if (inst.a < function.reg_count) noteWrite(captured, counts, base + inst.a);
            if (inst.dst < function.reg_count) noteWrite(captured, counts, base + inst.dst);
        },
        else => {},
    }
}
fn noteLoopWrites(
    function: *const ir.Function,
    base: usize,
    captured: []const bool,
    counts: []u8,
    inst: ir.Inst,
) void {
    if (inst.op != .generic_for_init and inst.op != .generic_for_next) return;
    if (inst.c < function.reg_count) noteWrite(captured, counts, base + inst.c);
    const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
    var i: u32 = 0;
    while (i < width and inst.dst + i < function.reg_count) : (i += 1)
        noteWrite(captured, counts, base + inst.dst + i);
}

fn collectGraph(
    a: std.mem.Allocator,
    program: *const ir.Program,
    reg_offsets: []const usize,
    up_offsets: []const usize,
    captured: []bool,
    detached: []bool,
    mutated_upvalue: []bool,
    edges: *std.ArrayList(Edge),
) !void {
    for (program.functions.items, 0..) |maybe, parent_usize| {
        const function = maybe orelse continue;
        const parent: u32 = @intCast(parent_usize);
        for (function.insts.items) |inst| {
            if (inst.op == .detach_cell and inst.a < function.reg_count)
                detached[reg_offsets[parent] + inst.a] = true;
            if (inst.op == .set_upvalue) {
                if (inst.a >= function.upvalues.items.len) return error.BadUpvalue;
                mutated_upvalue[up_offsets[parent] + inst.a] = true;
            }
            const child_id = sem.captureTarget(inst) orelse continue;
            if (child_id >= program.functions.items.len) return error.BadFunctionReference;
            const child = program.functions.items[child_id] orelse return error.IncompleteProgram;
            for (child.upvalues.items, 0..) |upvalue, child_index| {
                if (upvalue.source == .local) {
                    if (upvalue.index >= function.reg_count) return error.BadRegister;
                    captured[reg_offsets[parent] + upvalue.index] = true;
                } else if (upvalue.index >= function.upvalues.items.len) {
                    return error.BadUpvalue;
                }
                try edges.append(a, .{
                    .parent = parent,
                    .child_upvalue = up_offsets[child_id] + child_index,
                    .source = upvalue,
                });
            }
        }
    }
}

fn propagateMutations(
    edges: []const Edge,
    reg_offsets: []const usize,
    up_offsets: []const usize,
    mutated_local: []bool,
    mutated_upvalue: []bool,
) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (edges) |edge| {
            if (!mutated_upvalue[edge.child_upvalue]) continue;
            switch (edge.source.source) {
                .local => {
                    const flat = reg_offsets[edge.parent] + edge.source.index;
                    if (!mutated_local[flat]) {
                        mutated_local[flat] = true;
                        changed = true;
                    }
                },
                .upvalue => {
                    const flat = up_offsets[edge.parent] + edge.source.index;
                    if (!mutated_upvalue[flat]) {
                        mutated_upvalue[flat] = true;
                        changed = true;
                    }
                },
            }
        }
    }
}

fn collectWrites(
    program: *const ir.Program,
    reg_offsets: []const usize,
    captured: []const bool,
    counts: []u8,
) void {
    for (program.functions.items, 0..) |maybe, function_id| if (maybe) |function| {
        const base = reg_offsets[function_id];
        for (function.insts.items) |inst| {
            noteInstructionWrites(&function, base, captured, counts, inst);
            noteLoopWrites(&function, base, captured, counts, inst);
        }
    };
}

fn mergeCandidate(candidate: *Fact, bad: *bool, incoming: Fact) void {
    if (!hasFact(incoming)) {
        bad.* = true;
        return;
    }
    if (!hasFact(candidate.*)) {
        candidate.* = incoming;
    } else if (!std.meta.eql(candidate.*, incoming)) {
        bad.* = true;
    }
}

fn unknownWriteReason(op: ir.Opcode) UnknownReason {
    return switch (op) {
        .get_upvalue => .unknown_write_upvalue,
        .call, .call_vararg, .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg, .method_call, .method_call_vararg, .method_call_field, .method_call_field_vararg => .unknown_write_call,
        .get_field, .get_slot => .unknown_write_field,
        .get_index, .get_choice_slot => .unknown_write_index,
        .get_global, .get_global_slot => .unknown_write_global,
        .move => .unknown_write_move,
        .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => .unknown_write_loop,
        .load_nil => .unknown_write_nil,
        .load_bool, .load_number, .load_string, .load_const => .unknown_write_literal,
        .vararg => .unknown_write_vararg,
        .new_table, .new_table_shape => .unknown_write_table,
        .neg, .not_, .len, .neg_number, .len_string => .unknown_write_unary,
        .add, .sub, .mul, .div, .mod, .pow, .eq, .ne, .lt, .le, .gt, .ge, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => .unknown_write_binary,
        .concat => .unknown_write_concat,
        else => .unknown_write_other,
    };
}

fn isUnknownWriteReason(reason: UnknownReason) bool {
    return switch (reason) {
        .unknown_write, .unknown_write_upvalue, .unknown_write_call, .unknown_write_field, .unknown_write_index, .unknown_write_global, .unknown_write_move, .unknown_write_loop, .unknown_write_nil, .unknown_write_literal, .unknown_write_vararg, .unknown_write_table, .unknown_write_unary, .unknown_write_binary, .unknown_write_concat, .unknown_write_other => true,
        else => false,
    };
}

fn mergeUnknownWriteReason(slot: *UnknownReason, incoming: UnknownReason) void {
    if (slot.* == .none) slot.* = incoming else if (slot.* != incoming) slot.* = .unknown_write;
}

fn isLocalFunctionBootstrapNil(function: *const ir.Function, block_end: u32, pc: u32, inst: ir.Inst) bool {
    if (inst.op != .load_nil or block_end - pc < 3) return false;
    const closure = function.insts.items[pc + 1];
    const assign = function.insts.items[pc + 2];
    return closure.op == .closure and closure.dst != inst.dst and
        assign.op == .move and assign.dst == inst.dst and assign.a == closure.dst;
}

fn mergeLocalWrite(
    flat: usize,
    incoming: Fact,
    captured: []const bool,
    detached: []const bool,
    facts: []const Fact,
    candidates: []Fact,
    bad: []bool,
    unknown_write: []UnknownReason,
    conflicting_write: []bool,
    seen: []bool,
    unknown_reason: UnknownReason,
) void {
    if (flat >= captured.len or !captured[flat] or detached[flat] or hasFact(facts[flat])) return;
    seen[flat] = true;
    if (!hasFact(incoming)) {
        bad[flat] = true;
        mergeUnknownWriteReason(&unknown_write[flat], unknown_reason);
        return;
    }
    if (!hasFact(candidates[flat])) {
        candidates[flat] = incoming;
    } else if (!std.meta.eql(candidates[flat], incoming)) {
        bad[flat] = true;
        conflicting_write[flat] = true;
    }
}

fn collectLocalCandidates(
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function: *const ir.Function,
    analysis: *facts_mod.Analysis,
    upvalues: []const Fact,
    base: usize,
    captured: []const bool,
    detached: []const bool,
    facts: []const Fact,
    candidates: []Fact,
    bad: []bool,
    unknown_write: []UnknownReason,
    conflicting_write: []bool,
    seen: []bool,
) !void {
    const state = try analysis.allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) analysis.allocator.free(state);
    for (analysis.ssa_function.graph.blocks.items, 0..) |block, block_index| {
        const entry = analysis.ssa_function.entry_states[block_index] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            const fact = facts_mod.predictInstruction(analysis, program, symbols, function, state, inst, true, upvalues);
            const info = sem.info(inst.op);
            // `local function f()` lowers to `nil f; closure tmp; f = tmp` so
            // recursive closure creation observes the bound cell. No Lua code
            // can run between these instructions, so only the final value is a
            // candidate for calls made after the declaration completes.
            const bootstrap_nil = isLocalFunctionBootstrapNil(function, block.end, pc, inst);
            if (info.defines and inst.dst < function.reg_count and !bootstrap_nil)
                mergeLocalWrite(base + inst.dst, fact, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op));
            if (info.results) {
                const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
                var i: u32 = 0;
                while (i < width and inst.dst + i < function.reg_count) : (i += 1)
                    mergeLocalWrite(base + inst.dst + i, fact, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op));
            }
            switch (inst.op) {
                .numeric_for_init => if (inst.dst < function.reg_count)
                    mergeLocalWrite(base + inst.dst, .unknown, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op)),
                .numeric_for_next => {
                    if (inst.a < function.reg_count)
                        mergeLocalWrite(base + inst.a, .unknown, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op));
                    if (inst.dst < function.reg_count)
                        mergeLocalWrite(base + inst.dst, .unknown, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op));
                },
                .generic_for_init, .generic_for_next => {
                    if (inst.c < function.reg_count)
                        mergeLocalWrite(base + inst.c, .unknown, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op));
                    const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
                    var i: u32 = 0;
                    while (i < width and inst.dst + i < function.reg_count) : (i += 1)
                        mergeLocalWrite(base + inst.dst + i, .unknown, captured, detached, facts, candidates, bad, unknown_write, conflicting_write, seen, unknownWriteReason(inst.op));
                },
                else => {},
            }
            try ssa.applyWrites(&analysis.ssa_function, function, state, pc, null);
        }
    }
}
pub fn build(
    a: std.mem.Allocator,
    program: *ir.Program,
    symbols: *const symbols_mod.Index,
) !Result {
    const reg_offsets = try makeOffsets(a, program, false);
    defer a.free(reg_offsets);
    const up_offsets = try makeOffsets(a, program, true);
    errdefer a.free(up_offsets);
    const total_regs = reg_offsets[program.functions.items.len];
    const total_upvalues = up_offsets[program.functions.items.len];

    const captured = try a.alloc(bool, total_regs);
    defer if (captured.len != 0) a.free(captured);
    @memset(captured, false);
    const detached = try a.alloc(bool, total_regs);
    defer if (detached.len != 0) a.free(detached);
    @memset(detached, false);
    const mutated_local = try a.alloc(bool, total_regs);
    defer if (mutated_local.len != 0) a.free(mutated_local);
    @memset(mutated_local, false);
    const mutated_upvalue = try a.alloc(bool, total_upvalues);
    defer if (mutated_upvalue.len != 0) a.free(mutated_upvalue);
    @memset(mutated_upvalue, false);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(a);
    try collectGraph(a, program, reg_offsets, up_offsets, captured, detached, mutated_upvalue, &edges);
    propagateMutations(edges.items, reg_offsets, up_offsets, mutated_local, mutated_upvalue);

    const write_counts = try a.alloc(u8, total_regs);
    defer if (write_counts.len != 0) a.free(write_counts);
    @memset(write_counts, 0);
    collectWrites(program, reg_offsets, captured, write_counts);

    const local_facts = try a.alloc(Fact, total_regs);
    defer if (local_facts.len != 0) a.free(local_facts);
    for (local_facts) |*fact| fact.* = .unknown;
    const local_candidates = try a.alloc(Fact, total_regs);
    defer if (local_candidates.len != 0) a.free(local_candidates);
    const local_bad = try a.alloc(bool, total_regs);
    defer if (local_bad.len != 0) a.free(local_bad);
    const local_unknown_write = try a.alloc(UnknownReason, total_regs);
    defer if (local_unknown_write.len != 0) a.free(local_unknown_write);
    const local_conflicting_write = try a.alloc(bool, total_regs);
    defer if (local_conflicting_write.len != 0) a.free(local_conflicting_write);
    const local_seen = try a.alloc(bool, total_regs);
    defer if (local_seen.len != 0) a.free(local_seen);
    const upvalue_facts = try a.alloc(Fact, total_upvalues);
    errdefer if (upvalue_facts.len != 0) a.free(upvalue_facts);
    for (upvalue_facts) |*fact| fact.* = .unknown;
    const candidates = try a.alloc(Fact, total_upvalues);
    defer if (candidates.len != 0) a.free(candidates);
    const bad = try a.alloc(bool, total_upvalues);
    defer if (bad.len != 0) a.free(bad);
    const seen = try a.alloc(bool, total_upvalues);
    defer if (seen.len != 0) a.free(seen);

    var stats = Stats{};
    var changed = true;
    while (changed) {
        changed = false;
        for (local_candidates) |*fact| fact.* = .unknown;
        @memset(local_bad, false);
        @memset(local_unknown_write, .none);
        @memset(local_conflicting_write, false);
        @memset(local_seen, false);
        for (program.functions.items, 0..) |maybe, function_usize| {
            const function = maybe orelse continue;
            const function_id: u32 = @intCast(function_usize);
            var needs_analysis = false;
            for (0..function.reg_count) |reg| {
                const flat = reg_offsets[function_usize] + reg;
                if (captured[flat] and write_counts[flat] != 0 and
                    !detached[flat] and !hasFact(local_facts[flat]))
                {
                    needs_analysis = true;
                    break;
                }
            }
            if (!needs_analysis) continue;
            const upvalues = upvalue_facts[up_offsets[function_usize]..up_offsets[function_usize + 1]];
            var analysis = try facts_mod.buildFunctionWithUpvalues(
                a,
                program,
                symbols,
                function_id,
                true,
                upvalues,
            );
            defer analysis.deinit();
            try collectLocalCandidates(
                program,
                symbols,
                &function,
                &analysis,
                upvalues,
                reg_offsets[function_usize],
                captured,
                detached,
                local_facts,
                local_candidates,
                local_bad,
                local_unknown_write,
                local_conflicting_write,
                local_seen,
            );
        }
        for (local_facts, 0..) |*fact, flat| {
            if (mutated_local[flat] or hasFact(fact.*) or !local_seen[flat] or local_bad[flat] or !hasFact(local_candidates[flat])) continue;
            fact.* = local_candidates[flat];
            stats.stable_locals += 1;
            if (write_counts[flat] > 1) stats.stable_multiwrite_locals += 1;
            changed = true;
        }

        for (candidates) |*fact| fact.* = .unknown;
        @memset(bad, false);
        @memset(seen, false);
        for (edges.items) |edge| {
            const child = edge.child_upvalue;
            if (child >= upvalue_facts.len or mutated_upvalue[child] or hasFact(upvalue_facts[child])) continue;
            const source_fact = switch (edge.source.source) {
                .local => local_facts[reg_offsets[edge.parent] + edge.source.index],
                .upvalue => upvalue_facts[up_offsets[edge.parent] + edge.source.index],
            };
            seen[child] = true;
            mergeCandidate(&candidates[child], &bad[child], source_fact);
        }
        for (upvalue_facts, 0..) |*fact, index| {
            if (mutated_upvalue[index] or hasFact(fact.*) or !seen[index] or bad[index] or !hasFact(candidates[index])) continue;
            fact.* = candidates[index];
            changed = true;
        }
    }

    for (upvalue_facts) |fact| if (hasFact(fact)) {
        stats.known_upvalues += 1;
        switch (fact) {
            .module => stats.module_upvalues += 1,
            .function => stats.function_upvalues += 1,
            .native_global, .captured_native_global => stats.native_global_upvalues += 1,
            .native_namespace, .captured_native_namespace => stats.native_namespace_upvalues += 1,
            .native_field, .captured_native_field => stats.native_field_upvalues += 1,
            .native_field_candidate, .captured_native_field_candidate => stats.native_field_candidate_upvalues += 1,
            .function_candidate, .captured_function_candidate => stats.function_candidate_upvalues += 1,
            else => {},
        }
    };

    const reasons = try a.alloc(UnknownReason, total_upvalues);
    errdefer if (reasons.len != 0) a.free(reasons);
    @memset(reasons, .none);
    for (upvalue_facts, 0..) |fact, index| {
        if (!hasFact(fact) and mutated_upvalue[index]) reasons[index] = .mutated;
    }
    var reasons_changed = true;
    while (reasons_changed) {
        reasons_changed = false;
        for (upvalue_facts, 0..) |fact, child| {
            if (hasFact(fact) or reasons[child] == .mutated) continue;
            var candidate: Fact = .unknown;
            var conflict = false;
            var unresolved = false;
            var source_reason: UnknownReason = .none;
            for (edges.items) |edge| {
                if (edge.child_upvalue != child) continue;
                const source_fact = switch (edge.source.source) {
                    .local => local_facts[reg_offsets[edge.parent] + edge.source.index],
                    .upvalue => upvalue_facts[up_offsets[edge.parent] + edge.source.index],
                };
                if (hasFact(source_fact)) {
                    if (!hasFact(candidate)) candidate = source_fact else if (!std.meta.eql(candidate, source_fact)) conflict = true;
                    continue;
                }
                unresolved = true;
                const reason = switch (edge.source.source) {
                    .local => blk: {
                        const flat = reg_offsets[edge.parent] + edge.source.index;
                        if (mutated_local[flat]) break :blk UnknownReason.mutated;
                        if (detached[flat]) break :blk UnknownReason.detached;
                        if (write_counts[flat] == 0) {
                            const parent_function = program.functions.items[edge.parent] orelse break :blk UnknownReason.no_writes;
                            if (edge.source.index < parent_function.param_count) break :blk UnknownReason.parameter;
                            break :blk UnknownReason.no_writes;
                        }
                        if (local_conflicting_write[flat]) break :blk UnknownReason.conflicting_writes;
                        if (local_unknown_write[flat] != .none) break :blk local_unknown_write[flat];
                        break :blk UnknownReason.unresolved_chain;
                    },
                    .upvalue => blk: {
                        const parent = up_offsets[edge.parent] + edge.source.index;
                        break :blk if (reasons[parent] != .none) reasons[parent] else UnknownReason.unresolved_chain;
                    },
                };
                if (source_reason == .none) {
                    source_reason = reason;
                } else if (source_reason != reason) {
                    source_reason = if (isUnknownWriteReason(source_reason) and isUnknownWriteReason(reason)) .unknown_write else .unresolved_chain;
                }
            }
            const next: UnknownReason = if (conflict)
                .conflicting_sources
            else if (unresolved)
                if (source_reason != .none) source_reason else .unresolved_chain
            else
                .unresolved_chain;
            if (reasons[child] != next) {
                reasons[child] = next;
                reasons_changed = true;
            }
        }
    }
    // Guard facts are advisory: descendant mutation may invalidate the predicted
    // value, but generated calls still guard the live identity and fall back.
    const guard_local_facts = try a.dupe(Fact, local_facts);
    defer if (guard_local_facts.len != 0) a.free(guard_local_facts);
    for (guard_local_facts, 0..) |*fact, flat| {
        if (hasFact(fact.*) or !local_seen[flat] or !hasFact(local_candidates[flat])) continue;
        const nullable = !local_conflicting_write[flat] and local_unknown_write[flat] == .unknown_write_nil;
        const mutated = mutated_local[flat] and !local_bad[flat];
        if (!nullable and !mutated) continue;
        fact.* = local_candidates[flat];
    }

    const guard_upvalue_facts = try a.dupe(Fact, upvalue_facts);
    errdefer if (guard_upvalue_facts.len != 0) a.free(guard_upvalue_facts);
    var guard_changed = true;
    while (guard_changed) {
        guard_changed = false;
        for (candidates) |*fact| fact.* = .unknown;
        @memset(bad, false);
        @memset(seen, false);
        for (edges.items) |edge| {
            const child = edge.child_upvalue;
            if (child >= guard_upvalue_facts.len or hasFact(guard_upvalue_facts[child])) continue;
            const source_fact = switch (edge.source.source) {
                .local => guard_local_facts[reg_offsets[edge.parent] + edge.source.index],
                .upvalue => guard_upvalue_facts[up_offsets[edge.parent] + edge.source.index],
            };
            seen[child] = true;
            mergeCandidate(&candidates[child], &bad[child], source_fact);
        }
        for (guard_upvalue_facts, 0..) |*fact, index| {
            if (hasFact(fact.*) or !seen[index] or bad[index] or !hasFact(candidates[index])) continue;
            fact.* = candidates[index];
            guard_changed = true;
        }
    }
    for (guard_upvalue_facts, upvalue_facts) |guard_fact, strict_fact| {
        if (!hasFact(strict_fact) and hasFact(guard_fact)) stats.guard_only_upvalues += 1;
    }
    return .{
        .allocator = a,
        .offsets = up_offsets,
        .facts = upvalue_facts,
        .guard_facts = guard_upvalue_facts,
        .reasons = reasons,
        .stats = stats,
    };
}

const test_lua = @import("root.zig");
const test_image = @import("vm_link_image.zig");
const test_model = @import("module_model.zig");

fn addTestModule(
    a: std.mem.Allocator,
    image: *test_image.Image,
    symbols: *symbols_mod.Index,
    title: []const u8,
    source: []const u8,
) !u32 {
    var chunk = try test_lua.parse(a, source);
    defer chunk.deinit();
    var model = test_model.Builder{ .allocator = a, .source = chunk.source };
    defer model.deinit();
    try model.build(chunk.body);
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const module = try image.appendModule(&program);
    try symbols.addModule(title, image, module, &model);
    return module;
}
test "captured imported function predicts one guarded target" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B'); local f=m.add; local function run(x)return f(x)end; return run");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var found = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        for (result.forFunction(&image.program, @intCast(function_id))) |fact| switch (fact) {
            .function => |id| found = found or id == target,
            else => {},
        };
    }
    try std.testing.expect(found);
    try std.testing.expect(result.stats.function_upvalues != 0);
}
test "mutated captured import remains unpredicted" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B'); local f=m.add; local function run(x)return f(x)end; f=function(x)return x+9 end; return run");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var saw_capture = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        if (function.upvalues.items.len == 0) continue;
        saw_capture = true;
        for (result.forFunction(&image.program, @intCast(function_id))) |fact|
            try std.testing.expect(fact == .unknown);
    }
    try std.testing.expect(saw_capture);
}

test "captured imported function survives a stable local alias" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B');local raw=m.add;local f=raw;local function run(x)return f(x)end;return run");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var found = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        for (result.forFunction(&image.program, @intCast(function_id))) |fact| switch (fact) {
            .function => |id| found = found or id == target,
            else => {},
        };
    }
    try std.testing.expect(found);
}

test "recursive local function bootstrap nil preserves its captured function fact" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local function f(n)if n==0 then return 1 end;return f(n-1)end;return f");
    const root_id = image.modules.items[module].root_function;
    const root = image.program.functions.items[root_id] orelse return error.IncompleteProgram;
    var recursive_id: ?u32 = null;
    for (root.insts.items) |inst| if (inst.op == .closure) {
        recursive_id = inst.aux;
        break;
    };
    const target = recursive_id orelse return error.MissingRecursiveFunction;
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const facts = result.forFunction(&image.program, target);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    switch (facts[0]) {
        .function => |id| try std.testing.expectEqual(target, id),
        else => return error.MissingRecursiveFunctionFact,
    }
    try std.testing.expect(result.stats.stable_multiwrite_locals != 0);
}

test "ordinary nil initialization remains an unresolved captured write" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local f=nil;if ... then f=table.insert end;local function run(t,x)return f(t,x)end;return run");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var saw_nil = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        const facts = result.forFunction(&image.program, @intCast(function_id));
        const guards = result.guardsForFunction(&image.program, @intCast(function_id));
        const reasons = result.reasonsForFunction(&image.program, @intCast(function_id));
        for (function.upvalues.items, 0..) |_, index| {
            if (reasons[index] != .unknown_write_nil) continue;
            saw_nil = true;
            try std.testing.expect(facts[index] == .unknown);
            try std.testing.expect(guards[index] == .native_field);
        }
    }
    try std.testing.expect(saw_nil);
    try std.testing.expect(result.stats.guard_only_upvalues != 0);
}

test "mutated capture keeps only a guard fact" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local f=table.insert;local function mutate()f=function()return 9 end end;local function run(t,x)return f(t,x)end;return run,mutate");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var saw_mutated = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        const facts = result.forFunction(&image.program, @intCast(function_id));
        const guards = result.guardsForFunction(&image.program, @intCast(function_id));
        const reasons = result.reasonsForFunction(&image.program, @intCast(function_id));
        for (function.upvalues.items, 0..) |_, index| {
            if (reasons[index] != .mutated) continue;
            saw_mutated = true;
            try std.testing.expect(facts[index] == .unknown);
            try std.testing.expect(guards[index] == .native_field);
        }
    }
    try std.testing.expect(saw_mutated);
    try std.testing.expect(result.stats.guard_only_upvalues != 0);
}

test "equal multi-write captured imports preserve one guarded target" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;if ... then f=m.add end;local function run(x)return f(x)end;return run");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var found = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        for (result.forFunction(&image.program, @intCast(function_id))) |fact| switch (fact) {
            .function => |id| found = found or id == target,
            else => {},
        };
    }
    try std.testing.expect(found);
    try std.testing.expect(result.stats.stable_multiwrite_locals != 0);
}

test "different multi-write captured imports remain unpredicted" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;function e.sub(x)return x-1 end;return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;if ... then f=m.sub end;local function run(x)return f(x)end;return run");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var saw_capture = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        if (function.upvalues.items.len == 0) continue;
        saw_capture = true;
        for (result.forFunction(&image.program, @intCast(function_id))) |fact|
            try std.testing.expect(fact == .unknown);
    }
    try std.testing.expect(saw_capture);
}

test "descendant upvalue mutation invalidates sibling capture facts" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;local function mutate()f=function(x)return x+9 end end;local function run(x)return f(x)end;return run");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var captured = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        if (function.upvalues.items.len == 0) continue;
        captured = true;
        for (result.forFunction(&image.program, @intCast(function_id))) |fact|
            try std.testing.expect(fact == .unknown);
    }
    try std.testing.expect(captured);
}
