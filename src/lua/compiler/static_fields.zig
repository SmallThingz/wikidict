const std = @import("std");
const ir = @import("ir.zig");
const ssa = @import("ssa.zig");
const global_abi = @import("../abi/globals.zig");
const fields = @import("../abi/static_fields.zig");
const aot_hint = @import("aot_hint.zig");

pub const Stats = struct {
    reads: u64 = 0,
    writes: u64 = 0,
    guarded_calls: u64 = 0,
    candidate_calls: u64 = 0,
};

fn globalNamespace(slot: u32) ?fields.Namespace {
    if (slot == global_abi.id("table")) return .table;
    if (slot == global_abi.id("string")) return .string;
    if (slot == global_abi.id("math")) return .math;
    if (slot == global_abi.id("debug")) return .debug;
    if (slot == global_abi.id("mw")) return .mw;
    return null;
}

fn instructionGlobalNamespace(program: *const ir.Program, inst: ir.Inst) ?fields.Namespace {
    return switch (inst.op) {
        .get_global_slot => globalNamespace(inst.aux),
        .get_global => if (inst.aux < program.strings.items.len)
            globalNamespace(global_abi.find(program.strings.items[inst.aux]) orelse return null)
        else
            null,
        else => null,
    };
}

fn mergePhi(analysis: *const ssa.Function, facts: []const ?fields.Namespace, phi: ssa.Phi) ?fields.Namespace {
    var selected: ?fields.Namespace = null;
    var any = false;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= facts.len) return null;
        const incoming = facts[id] orelse return null;
        any = true;
        if (selected) |old| {
            if (old != incoming) return null;
        } else selected = incoming;
    }
    return if (any) selected else null;
}

fn mergeNativeFieldPhi(
    analysis: *const ssa.Function,
    facts: []const ?aot_hint.NativeField,
    phi: ssa.Phi,
) ?aot_hint.NativeField {
    var selected: ?aot_hint.NativeField = null;
    var any = false;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= facts.len) return null;
        const incoming = facts[id] orelse return null;
        any = true;
        if (selected) |old| {
            if (!std.meta.eql(old, incoming)) return null;
        } else selected = incoming;
    }
    return if (any) selected else null;
}

fn namespaceForReg(analysis: *const ssa.Function, facts: []const ?fields.Namespace, state: []const ssa.ValueId, reg: u32) ?fields.Namespace {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= facts.len) return null;
    return facts[id];
}

fn childNamespace(parent: fields.Namespace, field_name: []const u8) ?fields.Namespace {
    if (parent != .mw) return null;
    if (std.mem.eql(u8, field_name, "ustring")) return .ustring;
    if (std.mem.eql(u8, field_name, "title")) return .title;
    if (std.mem.eql(u8, field_name, "text")) return .text;
    if (std.mem.eql(u8, field_name, "uri")) return .uri;
    if (std.mem.eql(u8, field_name, "html")) return .html;
    if (std.mem.eql(u8, field_name, "language")) return .language;
    return null;
}

fn callResultNamespace(parent: fields.Namespace, field_name: []const u8) ?fields.Namespace {
    return switch (parent) {
        .mw => if (std.mem.eql(u8, field_name, "getCurrentFrame"))
            .frame
        else if (std.mem.eql(u8, field_name, "getContentLanguage") or std.mem.eql(u8, field_name, "getLanguage"))
            .language_value
        else
            null,
        .title => if (std.mem.eql(u8, field_name, "new") or std.mem.eql(u8, field_name, "makeTitle") or std.mem.eql(u8, field_name, "getCurrentTitle")) .title_value else null,
        .language => if (std.mem.eql(u8, field_name, "new") or std.mem.eql(u8, field_name, "getContentLanguage")) .language_value else null,
        .html => if (std.mem.eql(u8, field_name, "create")) .html_node else null,
        .html_node => if (fields.slotForName(.html_node, field_name) != null) .html_node else null,
        .frame => if (std.mem.eql(u8, field_name, "getParent")) .frame else null,
        else => null,
    };
}

fn instructionFieldName(program: *const ir.Program, inst: ir.Inst) ?[]const u8 {
    return switch (inst.op) {
        .get_field => if (inst.aux < program.strings.items.len) program.strings.items[inst.aux] else null,
        .get_slot => fields.nameForRef(inst.aux),
        else => null,
    };
}

fn hasNamespaceRoot(program: *const ir.Program, function: *const ir.Function) bool {
    for (function.insts.items) |inst| {
        if (instructionGlobalNamespace(program, inst) != null) return true;
    }
    return false;
}

fn hasCandidateField(program: *const ir.Program, function: *const ir.Function) bool {
    for (function.insts.items) |inst| {
        if (inst.op != .get_field and inst.op != .get_slot) continue;
        const name = instructionFieldName(program, inst) orelse continue;
        if (fields.hasCanonicalLibraryField(name)) return true;
    }
    return false;
}

fn candidateFieldForValue(program: *const ir.Program, function: *const ir.Function, analysis: *const ssa.Function, value: ssa.ValueId) ?u32 {
    if (value == ssa.invalid_value or value >= analysis.values.items.len) return null;
    const node = analysis.values.items[value];
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const name = instructionFieldName(program, function.insts.items[node.pc]) orelse return null;
    if (!fields.hasCanonicalLibraryField(name)) return null;
    return fields.find(name);
}

fn populateFacts(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *ssa.Function,
    facts: []?fields.Namespace,
    call_results: []?fields.Namespace,
    native_fields: []?aot_hint.NativeField,
) !void {
    @memset(facts, null);
    @memset(call_results, null);
    @memset(native_fields, null);
    for (analysis.values.items, 0..) |node, id| if (node.kind == .instruction and node.pc < function.insts.items.len) {
        facts[id] = instructionGlobalNamespace(program, function.insts.items[node.pc]);
    };
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value) continue;
            if (facts[id] == null) if (mergePhi(analysis, facts, phi)) |namespace| {
                facts[id] = namespace;
                changed = true;
            };
            if (call_results[id] == null) if (mergePhi(analysis, call_results, phi)) |namespace| {
                call_results[id] = namespace;
                changed = true;
            };
            if (native_fields[id] == null) if (mergeNativeFieldPhi(analysis, native_fields, phi)) |field| {
                native_fields[id] = field;
                changed = true;
            };
        }
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                var result_namespace: ?fields.Namespace = null;
                var callable_result: ?fields.Namespace = null;
                var native_field: ?aot_hint.NativeField = null;
                if (inst.op == .get_field or inst.op == .get_slot) {
                    if (namespaceForReg(analysis, facts, state, inst.a)) |parent| {
                        if (instructionFieldName(program, inst)) |field_name| {
                            result_namespace = childNamespace(parent, field_name);
                            callable_result = callResultNamespace(parent, field_name);
                            if (fields.slotForName(parent, field_name)) |slot|
                                native_field = .{ .namespace = parent, .slot = slot };
                        }
                    }
                } else if ((inst.op == .call or inst.op == .call_vararg) and inst.a < state.len) {
                    const callee = analysis.canonicalValue(state[inst.a]);
                    if (callee != ssa.invalid_value and callee < call_results.len)
                        result_namespace = call_results[callee];
                }
                try ssa.applyWrites(analysis, function, state, pc, null);
                if (inst.dst < state.len) {
                    const value = analysis.canonicalValue(state[inst.dst]);
                    if (value != ssa.invalid_value and value < facts.len) {
                        if (result_namespace) |namespace| if (facts[value] == null) {
                            facts[value] = namespace;
                            changed = true;
                        };
                        if (callable_result) |namespace| if (call_results[value] == null) {
                            call_results[value] = namespace;
                            changed = true;
                        };
                        if (native_field) |field| if (native_fields[value] == null) {
                            native_fields[value] = field;
                            changed = true;
                        };
                    }
                }
            }
        }
    }
}

fn runFunction(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function, rewrite_fields: bool) !Stats {
    if (!hasNamespaceRoot(program, function) and !hasCandidateField(program, function)) return .{};
    var analysis = try ssa.build(allocator, program, function);
    defer analysis.deinit();
    const facts = try allocator.alloc(?fields.Namespace, analysis.values.items.len);
    defer if (facts.len != 0) allocator.free(facts);
    const call_results = try allocator.alloc(?fields.Namespace, analysis.values.items.len);
    defer if (call_results.len != 0) allocator.free(call_results);
    const native_fields = try allocator.alloc(?aot_hint.NativeField, analysis.values.items.len);
    defer if (native_fields.len != 0) allocator.free(native_fields);
    try populateFacts(allocator, program, function, &analysis, facts, call_results, native_fields);
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = &function.insts.items[pc];
            if (rewrite_fields and (inst.op == .get_field or inst.op == .set_field) and inst.a < state.len and inst.aux < program.strings.items.len) {
                const value = analysis.canonicalValue(state[inst.a]);
                if (value != ssa.invalid_value and value < facts.len) if (facts[value]) |namespace| {
                    const field_name = program.strings.items[inst.aux];
                    if (fields.slotForName(namespace, field_name) != null) {
                        inst.aux = fields.refForName(field_name).?;
                        if (inst.op == .get_field) {
                            inst.op = .get_slot;
                            stats.reads += 1;
                        } else {
                            inst.op = .set_slot;
                            stats.writes += 1;
                        }
                    }
                };
            }
            if ((inst.op == .call or inst.op == .call_vararg) and inst.a < state.len and aot_hint.target(inst.*) == null and aot_hint.nativeGlobal(inst.*) == null and aot_hint.nativeField(inst.*) == null and aot_hint.nativeFieldCandidate(inst.*) == null) {
                const value = analysis.canonicalValue(state[inst.a]);
                if (value != ssa.invalid_value and value < native_fields.len) {
                    if (native_fields[value]) |field| {
                        try aot_hint.setNativeField(inst, field.namespace, field.slot);
                        stats.guarded_calls += 1;
                    } else if (candidateFieldForValue(program, function, &analysis, value)) |field_id| {
                        try aot_hint.setNativeFieldCandidate(inst, field_id);
                        stats.candidate_calls += 1;
                    }
                }
            }
            try ssa.applyWrites(&analysis, function, state, pc, null);
        }
    }
    return stats;
}

pub fn tagCallHints(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return .{};
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function, false);
        stats.guarded_calls += one.guarded_calls;
        stats.candidate_calls += one.candidate_calls;
    };
    return stats;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return .{};
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function, true);
        stats.reads += one.reads;
        stats.writes += one.writes;
        stats.guarded_calls += one.guarded_calls;
        stats.candidate_calls += one.candidate_calls;
    };
    return stats;
}
