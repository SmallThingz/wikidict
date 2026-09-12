const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const facts_mod = @import("vm_link_facts.zig");
const symbols_mod = @import("vm_link_symbols.zig");
const link_image = @import("vm_link_image.zig");
const lua = @import("root.zig");
const model = @import("module_model.zig");
const exec = @import("vm_exec.zig");
const simplify = @import("vm_ir_simplify.zig");
const capture_link = @import("vm_capture_link.zig");
const aot_hint = @import("vm_aot_hint.zig");
const global_abi = @import("vm_global_abi.zig");

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

fn addSource(allocator: std.mem.Allocator, image: *link_image.Image, symbols: *symbols_mod.Index, title: []const u8, source: []const u8) !u32 {
    var chunk = try lua.parse(allocator, source);
    defer chunk.deinit();
    var builder = model.Builder{ .allocator = allocator, .source = chunk.source };
    defer builder.deinit();
    try builder.build(chunk.body);
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    const module_id = try image.appendModule(&program);
    try symbols.addModule(title, image, module_id, &builder);
    return module_id;
}

test "numeric link preserves captured module state" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(std.testing.allocator);
    defer symbols.deinit();
    _ = try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local n=10; local export={}; function export.add(x) n=n+x; return n end; return export");
    const a = try addSource(std.testing.allocator, &image, &symbols, "Module:A", "local m=require('Module:B'); return m.add(4), m.add(5)");

    const stats = try run(std.testing.allocator, &image.program, &symbols);
    const simplified = try simplify.run(std.testing.allocator, &image.program);
    try std.testing.expect(simplified.removed_instructions >= 2);
    try std.testing.expectEqual(@as(u32, 2), stats.direct_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.numeric_imports);
    try std.testing.expectEqual(@as(u32, 1), stats.registrations);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.execute(&image.program, image.modules.items[a].root_function, &.{}, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 14), out[0].number);
    try std.testing.expectEqual(@as(f64, 19), out[1].number);
}

fn countCallableHints(program: *const ir.Program) u32 {
    var count: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.directCallable(inst)) count += 1;
        }
    };
    return count;
}

fn countDirectHints(program: *const ir.Program) u32 {
    var count: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.directTarget(inst) != null) count += 1;
        }
    };
    return count;
}

fn countGuardHints(program: *const ir.Program) u32 {
    var count: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.target(inst) != null) count += 1;
        }
    };
    return count;
}

fn countGlobalGuardHints(program: *const ir.Program) u32 {
    var count: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.nativeGlobal(inst) != null) count += 1;
        }
    };
    return count;
}

fn countNativeFieldGuardHints(program: *const ir.Program) u32 {
    var count: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.nativeField(inst) != null) count += 1;
        }
    };
    return count;
}

fn countNativeCandidateGuardHints(program: *const ir.Program) u32 {
    var count: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.nativeFieldCandidate(inst) != null) count += 1;
        }
    };
    return count;
}

test "different proven function identities merge to callable proof" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A",
        "local function a(x)return x+1 end;local function b(x)return x+2 end;local function run(flag)local f;if flag then f=a else f=b end;return f(3)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expect(stats.proven_callable_calls != 0);
    try std.testing.expect(countCallableHints(&image.program) != 0);
}

test "base native global calls carry guarded AOT hints" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    const module = try addSource(a, &image, &symbols, "Module:A", "local f=type;return f(1),type('x')");
    _ = module;
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 2), stats.guarded_global_calls);
    try std.testing.expectEqual(@as(u32, 2), countGlobalGuardHints(&image.program));
}

test "native global hint leaves rebinding semantics to runtime guard" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    const module = try addSource(a, &image, &symbols, "Module:A", "type=function()return 'patched' end;return type(1)");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_global_calls);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.execute(&image.program, image.modules.items[module].root_function, &.{}, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqualStrings("patched", out[0].string);
}

test "guarded import calls survive whole-image require mutation" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;local function run(x)return f(x)end;return run");
    _ = try addSource(a, &image, &symbols, "Module:Mutator", "require=function()return {}end;return {}");
    try std.testing.expect(!facts_mod.requireBuiltinSafe(&image.program));
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.direct_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.proven_direct_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.numeric_imports);
    try std.testing.expectEqual(@as(u32, 0), countDirectHints(&image.program));
    try std.testing.expect(stats.guarded_calls != 0);
    try std.testing.expect(countGuardHints(&image.program) != 0);
}

test "captured native field carries a guarded AOT hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert; local function run(t,x)return f(t,x)end; return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
}

test "captured native namespace field carries a guarded AOT hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local lib=table; local function run(x)return lib.insert({},x)end; return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
}

test "recursive local function calls become proven AOT direct calls" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local function f(n)if n==0 then return 1 end;return f(n-1)end;return f");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.proven_direct_calls);
    try std.testing.expectEqual(@as(u32, 1), countDirectHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
    try std.testing.expect(stats.predicted_function_upvalues != 0);
}

test "captured local function vararg calls become proven AOT direct calls" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local function f(...)return select('#',...),... end;local function run(...)return f(...)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.proven_direct_calls);
    try std.testing.expectEqual(@as(u32, 1), countDirectHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
}

test "captured native field vararg calls carry guarded AOT hints" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=string.format;local function run(...)return f(...)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
}

test "ordinary nil initialization gets only an advisory captured call guard" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=nil;if ... then f=table.insert end;local function run(t,x)return f(t,x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
    try std.testing.expectEqual(@as(u32, 1), stats.predicted_guard_only_upvalues);
}

test "unknown move alternative emits only a guarded captured call" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=unpack or table.unpack;local function run(t)return f(t)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_global_calls);
    try std.testing.expectEqual(@as(u32, 1), countGlobalGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
    try std.testing.expectEqual(@as(u32, 1), stats.predicted_guard_only_upvalues);
}

test "nil-only captured call remains unguarded" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=nil;local function run()return f()end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), countNativeFieldGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.unknown_write_nil);
}

test "nullable captured local function gets only a guarded call hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=nil;if ... then local function g(x)return x+1 end;f=g end;local function run(x)return f(x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
    try std.testing.expect(stats.predicted_guard_only_upvalues != 0);
}

test "nullable conflicting native fields remain unguarded" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=nil;if ... then f=table.insert else f=table.remove end;local function run(t,x)return f(t,x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), countNativeFieldGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.total);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.conflicting_writes);
}
test "captured candidate field name carries a guarded AOT hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)local f=obj.gsub;local function run(s,p,r)return f(s,p,r)end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.predicted_native_field_candidate_upvalues);
    try std.testing.expectEqual(@as(u32, 1), countNativeCandidateGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
}

test "noncanonical captured field name remains unguarded" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)local f=obj.not_a_native_field;local function run()return f()end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_captured_native_candidate_calls);
    try std.testing.expectEqual(@as(u32, 0), countNativeCandidateGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.total);
}

test "captured local move chains carry guarded native field hints" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local source=table.insert;local function keep()return source end;local alias=source;local function run(t,x)return alias(t,x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
}

test "captured module field chains become proven direct targets when require is immutable" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    _ = try addSource(a, &image, &symbols, "Module:C", "local e={};function e.add(x)return x+2 end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "local m=require('Module:B');local function keep()return m end;local f=m.add;local function run(x)return f(x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.proven_direct_calls);
    try std.testing.expectEqual(@as(u32, 1), countDirectHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.total);
}

test "equal multi-write captured candidate fields preserve one hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(x,y,c)local f=x.gsub;if c then f=y.gsub end;local function run(s,p,r)return f(s,p,r)end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeCandidateGuardHints(&image.program));
    try std.testing.expect(stats.predicted_multiwrite_locals != 0);
}

test "different captured candidate field names remain unpredicted" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(x,y,c)local f=x.gsub;if c then f=y.find end;local function run(s,p,r)return f(s,p,r)end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_captured_native_candidate_calls);
    try std.testing.expectEqual(@as(u32, 0), countNativeCandidateGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.conflicting_writes);
}

test "captured candidate field propagates through nested closures" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)local f=obj.gsub;local function outer()local function inner(s,p,r)return f(s,p,r)end;return inner end;return outer end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeCandidateGuardHints(&image.program));
}

test "descendant mutation keeps candidate field guard advisory" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)local f=obj.gsub;local function mutate()f=function()return 9 end end;local function run(s,p,r)return f(s,p,r)end;return run,mutate end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeCandidateGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.mutated);
    try std.testing.expect(stats.predicted_guard_only_upvalues != 0);
}

test "equal multi-write captured native field carries one guarded hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert;if ... then f=table.insert end;local function run(t,x)return f(t,x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
    try std.testing.expect(stats.predicted_multiwrite_locals != 0);
}

test "different multi-write captured native fields remain unpredicted" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert;if ... then f=table.remove end;local function run(t,x)return f(t,x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 0), countNativeFieldGuardHints(&image.program));
}

test "equal multi-write captured native field propagates through nested closures" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert;if ... then f=table.insert end;local function outer()local function inner(t,x)return f(t,x)end;return inner end;return outer");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
    try std.testing.expect(stats.predicted_multiwrite_locals != 0);
}

test "descendant mutation keeps equal multi-write native field guard advisory" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert;if ... then f=table.insert end;local function mutate()f=function()return 9 end end;local function run(t,x)return f(t,x)end;return run,mutate");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.predicted_multiwrite_locals);
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.mutated);
    try std.testing.expect(stats.predicted_guard_only_upvalues != 0);
}

test "captured parameter calls are classified separately" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(f)local function run()return f()end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.total);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.parameter);
}

test "unknown captured writes are classified separately" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert;if ... then f=(...) end;local function run(t,x)return f(t,x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.total);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.unknown_write);
}

test "captured vararg calls are included in unresolved cause totals" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(f)local function run(...)return f(...)end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.total);
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.parameter);
}

test "mutated captured native field remains unpredicted" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(
        a,
        &image,
        &symbols,
        "Module:A",
        "local f=table.insert; local function run(t,x)return f(t,x)end; f=function()return 9 end; return run",
    );
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 0), countNativeFieldGuardHints(&image.program));
}

test "mutated captured native namespace remains unpredicted" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(
        a,
        &image,
        &symbols,
        "Module:A",
        "local lib=table; local function run(x)return lib.insert({},x)end; lib={insert=function()return 9 end}; return run",
    );
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 0), countNativeFieldGuardHints(&image.program));
}

test "captured native field fact propagates through nested closures" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert; local function outer() local function inner(t,x)return f(t,x)end return inner end; return outer");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
}

test "captured native global carries a guarded AOT hint" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=type; local function run(x)return f(x)end; return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_global_calls);
    try std.testing.expectEqual(@as(u32, 1), countGlobalGuardHints(&image.program));
}

test "mutated captured native global remains unpredicted" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=type; local function run(x)return f(x)end; f=function()return 'patched' end; return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_captured_native_global_calls);
    try std.testing.expectEqual(@as(u32, 0), countGlobalGuardHints(&image.program));
}

test "captured native global hint remains advisory after rebinding" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(
        a,
        &image,
        &symbols,
        "Module:A",
        "type=function()return 'patched' end; local f=type; local function run(x)return f(x)end; return run",
    );
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_global_calls);
    try std.testing.expectEqual(@as(u32, 1), countGlobalGuardHints(&image.program));
}
test "require calls stay advisory when whole image mutates require" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "return {}");
    _ = try addSource(a, &image, &symbols, "Module:A", "return require('Module:B')");
    _ = try addSource(a, &image, &symbols, "Module:Mutator", "require=function()return {}end;return {}");
    try std.testing.expect(!facts_mod.requireBuiltinSafe(&image.program));
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.direct_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.numeric_imports);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_require_calls);
    try std.testing.expectEqual(@as(u32, 1), countGlobalGuardHints(&image.program));
}

test "captured require remains a guard only across global rebinding" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local r=require;local function run(x)return r(x)end;require=function()return 9 end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.direct_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_require_calls);
    try std.testing.expectEqual(@as(u32, 1), countGlobalGuardHints(&image.program));
}

test "unique linked export field carries a guarded function candidate" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)return obj.add(4)end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
}

test "captured unique linked export field carries the same guarded candidate" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)local f=obj.add;local function run(x)return f(x)end;return run end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
    try std.testing.expect(stats.predicted_function_candidate_upvalues != 0);
}

test "ambiguous linked export field names remain unguarded" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    _ = try addSource(a, &image, &symbols, "Module:C", "local e={};function e.add(x)return x+2 end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)return obj.add(4)end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
}

test "linked export candidates never preempt static ABI field names" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.getCode()return 'lua' end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "return function(obj)return obj.getCode()end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
}

test "descendant mutation keeps local function guard advisory" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:A", "local function f(x)return x+1 end;local function mutate()f=function(x)return x+100 end end;local function run(x)return f(x)end;return run,mutate");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.mutated);
    try std.testing.expect(stats.predicted_guard_only_upvalues != 0);
}

test "detached captured native field keeps an advisory guard" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    const module = try addSource(a, &image, &symbols, "Module:A", "local f=table.insert;local function run(t,x)return f(t,x)end;return run");
    const root_id = image.modules.items[module].root_function;
    var root = &image.program.functions.items[root_id].?;
    var closure_pc: ?usize = null;
    var capture_reg: u32 = 0;
    for (root.insts.items, 0..) |inst, pc| if (inst.op == .closure) {
        const child = image.program.functions.items[inst.aux] orelse continue;
        if (child.upvalues.items.len == 0 or child.upvalues.items[0].source != .local) continue;
        closure_pc = pc;
        capture_reg = child.upvalues.items[0].index;
        break;
    };
    const at = closure_pc orelse return error.MissingClosure;
    var insts: std.ArrayList(ir.Inst) = .empty;
    for (root.insts.items, 0..) |inst, pc| {
        try insts.append(a, inst);
        if (pc == at) try insts.append(a, .{ .op = .detach_cell, .a = capture_reg });
    }
    root.insts.deinit(a);
    root.insts = insts;
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_captured_native_field_calls);
    try std.testing.expectEqual(@as(u32, 1), countNativeFieldGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.detached);
    try std.testing.expect(stats.predicted_guard_only_upvalues != 0);
}

test "captured callable module carries a guarded function target" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:F", "local function f(x)return x+1 end;return f");
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=require('Module:F');local e={};function e.run(x)return f(x)end;return e");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_module_function_calls);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.unresolved_chain);
}

test "noncallable module remains unguarded" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:T", "return {}");
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=require('Module:T');local function run()return f()end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), stats.guarded_module_function_calls);
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
}

test "captured callable module vararg call keeps the same guard" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:F", "return function(...)return ... end");
    _ = try addSource(a, &image, &symbols, "Module:A", "local f=require('Module:F');return function(...)return f(...)end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_module_function_calls);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
}

test "dynamic known module export field carries a guarded candidate" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;if flag then e.add=function(x)return x+100 end end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;local function run(x)return f(x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.unknown_write_field);
}

test "known module ABI-name collision keeps a guarded export candidate" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};function e.ucfirst(x)return x end;if flag then e.ucfirst=function(x)return x..'!' end end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.ucfirst;local function run(x)return f(x)end;return run");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 1), stats.guarded_function_candidate_calls);
    try std.testing.expectEqual(@as(u32, 1), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 0), stats.unresolved_upvalue_calls.unknown_write_field);
}

test "dynamic known module missing export stays unguarded" {
    const a = std.testing.allocator;
    var image = link_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addSource(a, &image, &symbols, "Module:B", "local e={};if flag then e.add=function(x)return x+1 end end;return e");
    _ = try addSource(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;return function(x)return f(x)end");
    const stats = try run(a, &image.program, &symbols);
    try std.testing.expectEqual(@as(u32, 0), countGuardHints(&image.program));
    try std.testing.expectEqual(@as(u32, 1), stats.unresolved_upvalue_calls.unknown_write_field);
}
