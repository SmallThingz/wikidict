const std = @import("std");
const ir = @import("ir.zig");
const ssa = @import("ssa.zig");
const facts_mod = @import("link_facts.zig");
const symbols_mod = @import("link_symbols.zig");
const link_image = @import("link_image.zig");
const model = @import("module_model.zig");
const simplify = @import("simplify.zig");
const capture_link = @import("capture_link.zig");
const aot_hint = @import("aot_hint.zig");
const global_abi = @import("../abi/globals.zig");

pub const UnresolvedUpvalueCalls = struct {
    total: u32 = 0,
    mutated: u32 = 0,
    parameter: u32 = 0,
    detached: u32 = 0,
    no_writes: u32 = 0,
    unknown_write: u32 = 0,
    unknown_write_upvalue: u32 = 0,
    unknown_write_call: u32 = 0,
    unknown_write_field: u32 = 0,
    unknown_write_index: u32 = 0,
    unknown_write_global: u32 = 0,
    unknown_write_move: u32 = 0,
    unknown_write_loop: u32 = 0,
    unknown_write_nil: u32 = 0,
    unknown_write_literal: u32 = 0,
    unknown_write_vararg: u32 = 0,
    unknown_write_table: u32 = 0,
    unknown_write_unary: u32 = 0,
    unknown_write_binary: u32 = 0,
    unknown_write_concat: u32 = 0,
    unknown_write_other: u32 = 0,
    conflicting_writes: u32 = 0,
    conflicting_sources: u32 = 0,
    unresolved_chain: u32 = 0,
};

pub const Stats = struct {
    direct_calls: u32 = 0,
    proven_direct_calls: u32 = 0,
    proven_callable_calls: u32 = 0,
    numeric_imports: u32 = 0,
    removed_lookup_insts: u32 = 0,
    registrations: u32 = 0,
    guarded_calls: u32 = 0,
    guarded_global_calls: u32 = 0,
    guarded_require_calls: u32 = 0,
    guarded_captured_native_global_calls: u32 = 0,
    guarded_captured_native_field_calls: u32 = 0,
    guarded_captured_native_candidate_calls: u32 = 0,
    guarded_function_candidate_calls: u32 = 0,
    guarded_module_function_calls: u32 = 0,
    predicted_upvalues: u32 = 0,
    predicted_multiwrite_locals: u32 = 0,
    predicted_module_upvalues: u32 = 0,
    predicted_function_upvalues: u32 = 0,
    predicted_callable_upvalues: u32 = 0,
    predicted_native_global_upvalues: u32 = 0,
    predicted_native_field_upvalues: u32 = 0,
    predicted_native_field_candidate_upvalues: u32 = 0,
    predicted_function_candidate_upvalues: u32 = 0,
    predicted_guard_only_upvalues: u32 = 0,
    unresolved_upvalue_calls: UnresolvedUpvalueCalls = .{},
};

fn factOf(analysis: *const facts_mod.Analysis, raw: ssa.ValueId) facts_mod.Fact {
    const id = analysis.ssa_function.canonicalValue(raw);
    if (id == ssa.invalid_value or id >= analysis.facts.len) return .unknown;
    return analysis.facts[id];
}

fn valueUses(analysis: *const facts_mod.Analysis, raw: ssa.ValueId) u32 {
    const id = analysis.ssa_function.canonicalValue(raw);
    if (id == ssa.invalid_value or id >= analysis.ssa_function.values.items.len) return 0;
    return analysis.ssa_function.values.items[id].uses;
}
fn registerableTargets(allocator: std.mem.Allocator, program: *const ir.Program, symbols: *const symbols_mod.Index) ![]bool {
    const result = try allocator.alloc(bool, program.functions.items.len);
    @memset(result, false);
    for (program.module_roots.items) |root_id| {
        if (root_id >= program.functions.items.len) continue;
        const root = program.functions.items[root_id] orelse continue;
        for (root.insts.items) |inst| {
            if (inst.op != .closure and inst.op != .load_function or inst.aux >= result.len) continue;
            if (!symbols.isExportedFunction(inst.aux)) continue;
            if (program.function_modules.items[inst.aux] != program.function_modules.items[root_id]) continue;
            result[inst.aux] = true;
        }
    }
    return result;
}

fn crossExport(program: *const ir.Program, symbols: *const symbols_mod.Index, caller: u32, callee: u32, registerable: []const bool) bool {
    if (caller >= program.function_modules.items.len or callee >= program.function_modules.items.len) return false;
    if (callee >= registerable.len or !registerable[callee]) return false;
    if (!symbols.isExportedFunction(callee)) return false;
    return program.function_modules.items[caller] != program.function_modules.items[callee];
}

fn compactInstructions(allocator: std.mem.Allocator, function: *ir.Function, remove: []const bool) !u32 {
    const old_len = function.insts.items.len;
    const remap = try allocator.alloc(u32, old_len + 1);
    defer allocator.free(remap);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(allocator);
    for (function.insts.items, 0..) |inst, pc| {
        remap[pc] = @intCast(out.items.len);
        if (!remove[pc]) try out.append(allocator, inst);
    }
    remap[old_len] = @intCast(out.items.len);
    for (out.items) |*inst| switch (inst.op) {
        .jump, .jump_if_false, .branch_compare, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => {
            if (inst.aux > old_len) return error.BadJump;
            inst.aux = remap[inst.aux];
        },
        else => {},
    };
    var removed: u32 = 0;
    for (remove) |dead| removed += @intFromBool(dead);
    function.insts.deinit(allocator);
    function.insts = out;
    return removed;
}

fn rewriteFunction(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    symbols: *const symbols_mod.Index,
    function_id: u32,
    require_safe: bool,
    registerable: []const bool,
    used_targets: []bool,
) !Stats {
    const function = &(program.functions.items[function_id] orelse return error.IncompleteProgram);
    var analysis = try facts_mod.buildFunction(allocator, program, symbols, function_id, require_safe);
    defer analysis.deinit();
    const direct = try allocator.alloc(u32, function.insts.items.len);
    defer allocator.free(direct);
    @memset(direct, std.math.maxInt(u32));
    const remove = try allocator.alloc(bool, function.insts.items.len);
    defer allocator.free(remove);
    @memset(remove, false);
    var module_uses: std.AutoHashMapUnmanaged(ssa.ValueId, u32) = .empty;
    defer module_uses.deinit(allocator);
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);

    for (analysis.ssa_function.graph.blocks.items, 0..) |block, block_index| {
        const entry = analysis.ssa_function.entry_states[block_index] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            if ((inst.op == .call or inst.op == .call_vararg) and inst.a < state.len) {
                const callee = switch (factOf(&analysis, state[inst.a])) {
                    .function => |id| id,
                    else => std.math.maxInt(u32),
                };
                if (callee != std.math.maxInt(u32) and crossExport(program, symbols, function_id, callee, registerable)) direct[pc] = callee;
            }
            try ssa.applyWrites(&analysis.ssa_function, function, state, pc, null);
        }
    }
    var direct_value_uses: std.AutoHashMapUnmanaged(ssa.ValueId, u32) = .empty;
    defer direct_value_uses.deinit(allocator);
    for (direct, 0..) |target, pc_usize| {
        if (target == std.math.maxInt(u32)) continue;
        const pc: u32 = @intCast(pc_usize);
        try ssa.stateBefore(&analysis.ssa_function, function, pc, state);
        const inst = function.insts.items[pc];
        const value = analysis.ssa_function.canonicalValue(state[inst.a]);
        const gop = try direct_value_uses.getOrPut(allocator, value);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var value_it = direct_value_uses.iterator();
    while (value_it.next()) |entry| {
        const value_id = entry.key_ptr.*;
        if (value_id >= analysis.ssa_function.values.items.len) continue;
        const value = analysis.ssa_function.values.items[value_id];
        if (value.kind != .instruction or value.uses != entry.value_ptr.*) continue;
        if (value.pc >= function.insts.items.len) continue;
        const producer = function.insts.items[value.pc];
        if (producer.op != .get_index and producer.op != .get_field) continue;
        try ssa.stateBefore(&analysis.ssa_function, function, value.pc, state);
        const object_id = analysis.ssa_function.canonicalValue(state[producer.a]);
        if (factOf(&analysis, object_id) != .module) continue;
        remove[value.pc] = true;
        const gop = try module_uses.getOrPut(allocator, object_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    const imports = try allocator.alloc(u32, function.insts.items.len);
    defer allocator.free(imports);
    @memset(imports, std.math.maxInt(u32));
    for (function.insts.items, 0..) |inst, pc_usize| {
        if (inst.op != .call and inst.op != .call_vararg) continue;
        const pc: u32 = @intCast(pc_usize);
        try ssa.stateBefore(&analysis.ssa_function, function, pc, state);
        try ssa.applyWrites(&analysis.ssa_function, function, state, pc, null);
        if (inst.dst >= state.len) continue;
        const value_id = analysis.ssa_function.canonicalValue(state[inst.dst]);
        const module_sid = switch (factOf(&analysis, value_id)) {
            .module => |sid| sid,
            else => continue,
        };
        const erased_uses = module_uses.get(value_id) orelse continue;
        if (valueUses(&analysis, value_id) != erased_uses) continue;
        if (module_sid >= program.strings.items.len) continue;
        imports[pc] = symbols.moduleId(program.strings.items[module_sid]) orelse continue;
    }

    var stats = Stats{};
    for (function.insts.items, 0..) |*inst, pc| {
        if (direct[pc] != std.math.maxInt(u32)) {
            const target = direct[pc];
            inst.op = if (inst.op == .call_vararg) .direct_call_vararg else .direct_call;
            inst.a = target;
            used_targets[target] = true;
            stats.direct_calls += 1;
        } else if (imports[pc] != std.math.maxInt(u32)) {
            inst.* = .{ .op = .init_module, .aux = imports[pc] };
            stats.numeric_imports += 1;
        }
    }
    stats.removed_lookup_insts = try compactInstructions(allocator, function, remove);
    return stats;
}

fn insertRegistrations(allocator: std.mem.Allocator, program: *ir.Program, targets: []const bool) !u32 {
    var inserted: u32 = 0;
    for (program.module_roots.items) |root_id| {
        const function = &(program.functions.items[root_id] orelse return error.IncompleteProgram);
        const old_len = function.insts.items.len;
        const remap = try allocator.alloc(u32, old_len + 1);
        defer allocator.free(remap);
        var out: std.ArrayList(ir.Inst) = .empty;
        errdefer out.deinit(allocator);
        for (function.insts.items, 0..) |inst, pc| {
            remap[pc] = @intCast(out.items.len);
            try out.append(allocator, inst);
            if ((inst.op == .closure or inst.op == .load_function) and inst.aux < targets.len and targets[inst.aux]) {
                try out.append(allocator, .{ .op = .register_function, .a = inst.dst, .aux = inst.aux });
                inserted += 1;
            }
        }
        remap[old_len] = @intCast(out.items.len);
        for (out.items) |*inst| switch (inst.op) {
            .jump, .jump_if_false, .branch_compare, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => {
                if (inst.aux > old_len) return error.BadJump;
                inst.aux = remap[inst.aux];
            },
            else => {},
        };
        function.insts.deinit(allocator);
        function.insts = out;
    }
    return inserted;
}

fn guardableNativeGlobal(
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *const facts_mod.Analysis,
    state: []const ssa.ValueId,
    reg: u32,
) ?u32 {
    if (reg >= state.len) return null;
    const id = analysis.ssa_function.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= analysis.ssa_function.values.items.len) return null;
    const node = analysis.ssa_function.values.items[id];
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const producer = function.insts.items[node.pc];
    const slot = switch (producer.op) {
        .get_global_slot => producer.aux,
        .get_global => if (producer.aux < program.strings.items.len) global_abi.find(program.strings.items[producer.aux]) orelse return null else return null,
        else => return null,
    };
    if (slot < global_abi.id("type") or slot > global_abi.id("pcall")) return null;
    return slot;
}

fn producerUpvalue(function: *const ir.Function, analysis: *const facts_mod.Analysis, state: []const ssa.ValueId, reg: u32) ?u32 {
    if (reg >= state.len or analysis.ssa_function.captured[reg]) return null;
    const id = analysis.ssa_function.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= analysis.ssa_function.values.items.len) return null;
    const node = analysis.ssa_function.values.items[id];
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const producer = function.insts.items[node.pc];
    return if (producer.op == .get_upvalue) producer.a else null;
}

fn noteUnresolvedUpvalueCall(stats: *Stats, reason: capture_link.UnknownReason) void {
    stats.unresolved_upvalue_calls.total += 1;
    switch (reason) {
        .mutated => stats.unresolved_upvalue_calls.mutated += 1,
        .parameter => stats.unresolved_upvalue_calls.parameter += 1,
        .detached => stats.unresolved_upvalue_calls.detached += 1,
        .no_writes => stats.unresolved_upvalue_calls.no_writes += 1,
        .unknown_write => stats.unresolved_upvalue_calls.unknown_write += 1,
        .unknown_write_upvalue => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_upvalue += 1;
        },
        .unknown_write_call => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_call += 1;
        },
        .unknown_write_field => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_field += 1;
        },
        .unknown_write_index => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_index += 1;
        },
        .unknown_write_global => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_global += 1;
        },
        .unknown_write_move => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_move += 1;
        },
        .unknown_write_loop => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_loop += 1;
        },
        .unknown_write_nil => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_nil += 1;
        },
        .unknown_write_literal => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_literal += 1;
        },
        .unknown_write_vararg => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_vararg += 1;
        },
        .unknown_write_table => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_table += 1;
        },
        .unknown_write_unary => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_unary += 1;
        },
        .unknown_write_binary => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_binary += 1;
        },
        .unknown_write_concat => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_concat += 1;
        },
        .unknown_write_other => {
            stats.unresolved_upvalue_calls.unknown_write += 1;
            stats.unresolved_upvalue_calls.unknown_write_other += 1;
        },
        .conflicting_writes => stats.unresolved_upvalue_calls.conflicting_writes += 1,
        .conflicting_sources => stats.unresolved_upvalue_calls.conflicting_sources += 1,
        .none, .unresolved_chain => stats.unresolved_upvalue_calls.unresolved_chain += 1,
    }
}

fn tagCallFact(program: *const ir.Program, symbols: *const symbols_mod.Index, inst: *ir.Inst, fact: facts_mod.Fact, stats: *Stats, tagged: *u32) !bool {
    switch (fact) {
        .function => |target| if (target < program.functions.items.len) {
            try aot_hint.set(inst, target);
            tagged.* += 1;
            return true;
        },
        .module => |sid| if (sid < program.strings.items.len) {
            if (symbols.resolveCallableModule(program.strings.items[sid])) |target| {
                if (target >= program.functions.items.len) return false;
                try aot_hint.set(inst, target);
                tagged.* += 1;
                stats.guarded_module_function_calls += 1;
                return true;
            }
        },
        .require_builtin => {
            try aot_hint.setNativeGlobal(inst, global_abi.id("require"));
            stats.guarded_require_calls += 1;
            return true;
        },
        .captured_native_global => |slot| {
            try aot_hint.setNativeGlobal(inst, slot);
            stats.guarded_captured_native_global_calls += 1;
            return true;
        },
        .captured_native_field => |field| {
            try aot_hint.setNativeField(inst, field.namespace, field.slot);
            stats.guarded_captured_native_field_calls += 1;
            return true;
        },
        .captured_native_field_candidate => |field_id| {
            try aot_hint.setNativeFieldCandidate(inst, field_id);
            stats.guarded_captured_native_candidate_calls += 1;
            return true;
        },
        .function_candidate, .captured_function_candidate => |target| {
            if (target >= program.functions.items.len) return false;
            try aot_hint.set(inst, target);
            tagged.* += 1;
            stats.guarded_function_candidate_calls += 1;
            return true;
        },
        else => {},
    }
    return false;
}
fn tagDirectFact(program: *const ir.Program, inst: *ir.Inst, fact: facts_mod.Fact, stats: *Stats) !bool {
    switch (fact) {
        .function => |target| if (target < program.functions.items.len) {
            try aot_hint.setDirect(inst, target);
            stats.proven_direct_calls += 1;
            return true;
        },
        .callable, .require_builtin => {
            try aot_hint.setDirectCallable(inst);
            stats.proven_callable_calls += 1;
            return true;
        },
        else => {},
    }
    return false;
}

fn tagGuardedCalls(allocator: std.mem.Allocator, program: *ir.Program, symbols: *const symbols_mod.Index, require_safe: bool, stats: *Stats) !u32 {
    var captures = try capture_link.build(allocator, program, symbols);
    defer captures.deinit();
    stats.predicted_upvalues = @intCast(captures.stats.known_upvalues);
    stats.predicted_multiwrite_locals = @intCast(captures.stats.stable_multiwrite_locals);
    stats.predicted_module_upvalues = @intCast(captures.stats.module_upvalues);
    stats.predicted_function_upvalues = @intCast(captures.stats.function_upvalues);
    stats.predicted_callable_upvalues = @intCast(captures.stats.callable_upvalues);
    stats.predicted_native_global_upvalues = @intCast(captures.stats.native_global_upvalues);
    stats.predicted_native_field_upvalues = @intCast(captures.stats.native_field_upvalues);
    stats.predicted_native_field_candidate_upvalues = @intCast(captures.stats.native_field_candidate_upvalues);
    stats.predicted_function_candidate_upvalues = @intCast(captures.stats.function_candidate_upvalues);
    stats.predicted_guard_only_upvalues = @intCast(captures.stats.guard_only_upvalues);
    var tagged: u32 = 0;
    var function_id: u32 = 0;
    while (function_id < program.functions.items.len) : (function_id += 1) {
        const function = &(program.functions.items[function_id] orelse continue);
        const capture_reasons = captures.reasonsForFunction(program, function_id);
        const strict_upvalues = if (require_safe) captures.forFunction(program, function_id) else &.{};
        var strict_analysis = try facts_mod.buildFunctionWithUpvalues(allocator, program, symbols, function_id, require_safe, strict_upvalues);
        defer strict_analysis.deinit();
        var analysis = try facts_mod.buildFunctionWithUpvalues(allocator, program, symbols, function_id, true, captures.guardsForFunction(program, function_id));
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        const strict_state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (strict_state.len != 0) allocator.free(strict_state);
        for (analysis.ssa_function.graph.blocks.items, 0..) |block, block_index| {
            const entry = analysis.ssa_function.entry_states[block_index] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = &function.insts.items[pc];
                if ((inst.op == .call or inst.op == .call_vararg) and inst.a < state.len) {
                    try ssa.stateBefore(&strict_analysis.ssa_function, function, pc, strict_state);
                    var tagged_any = if (inst.a < strict_state.len)
                        try tagDirectFact(program, inst, factOf(&strict_analysis, strict_state[inst.a]), stats)
                    else
                        false;
                    if (!tagged_any) tagged_any = try tagCallFact(program, symbols, inst, factOf(&analysis, state[inst.a]), stats, &tagged);
                    if (!tagged_any) {
                        if (guardableNativeGlobal(program, function, &analysis, state, inst.a)) |slot| {
                            try aot_hint.setNativeGlobal(inst, slot);
                            stats.guarded_global_calls += 1;
                            tagged_any = true;
                        }
                    }
                    if (!tagged_any) if (producerUpvalue(function, &analysis, state, inst.a)) |up_index| {
                        const reason = if (up_index < capture_reasons.len) capture_reasons[up_index] else capture_link.UnknownReason.unresolved_chain;
                        noteUnresolvedUpvalueCall(stats, reason);
                    };
                }
                try ssa.applyWrites(&analysis.ssa_function, function, state, pc, null);
            }
        }
    }
    return tagged;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program, symbols: *const symbols_mod.Index) !Stats {
    if (program.function_modules.items.len != program.functions.items.len) return error.NotLinkedProgram;
    const registerable = try registerableTargets(allocator, program, symbols);
    defer allocator.free(registerable);
    const used_targets = try allocator.alloc(bool, program.functions.items.len);
    defer allocator.free(used_targets);
    @memset(used_targets, false);
    var stats = Stats{};
    const require_safe = facts_mod.requireBuiltinSafe(program);
    var function_id: u32 = 0;
    while (function_id < program.functions.items.len) : (function_id += 1) {
        if (program.functions.items[function_id] == null) continue;
        const one = try rewriteFunction(allocator, program, symbols, function_id, require_safe, registerable, used_targets);
        stats.direct_calls += one.direct_calls;
        stats.numeric_imports += one.numeric_imports;
        stats.removed_lookup_insts += one.removed_lookup_insts;
    }
    stats.registrations = try insertRegistrations(allocator, program, used_targets);
    stats.guarded_calls = try tagGuardedCalls(allocator, program, symbols, require_safe, &stats);
    return stats;
}
