const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const sem = @import("vm_semantics.zig");
const refs = @import("vm_ref.zig");
const exec = @import("vm_exec.zig");
pub const Stats = struct { immediate_uses: u64 = 0, constant_uses: u64 = 0, string_uses: u64 = 0, loop_invariants_kept: u64 = 0 };
const unknown: u32 = std.math.maxInt(u32);
fn numeric(p: *ir.Program, n: f64) !u32 {
    return refs.number(n) orelse try refs.constant(try p.numberConstant(@bitCast(n)));
}
fn literal(p: *ir.Program, f: *const ir.Function, node: ssa.Value) !u32 {
    if (node.kind != .instruction or node.pc >= f.insts.items.len) return unknown;
    const inst = f.insts.items[node.pc];
    return switch (inst.op) {
        .load_nil => refs.nil,
        .load_bool => if (inst.a != 0) refs.true_value else refs.false_value,
        .load_string => try refs.string(inst.aux),
        .load_number => try numeric(p, try exec.Vm.parseLuaNumber(p.strings.items[inst.aux])),
        .load_const => switch (p.constants.items[inst.aux]) {
            .nil => refs.nil,
            .boolean => |v| if (v) refs.true_value else refs.false_value,
            .number_bits => |bits| try numeric(p, @bitCast(bits)),
            .number => |sid| try numeric(p, try exec.Vm.parseLuaNumber(p.strings.items[sid])),
            .integer => |n| try numeric(p, @floatFromInt(n)),
            .string => |sid| try refs.string(sid),
            .table => unknown,
        },
        else => unknown,
    };
}
fn useful(value: u32, uses: u32) bool {
    if (value == unknown) return false;
    if (uses <= 1 or refs.tag(value) == .special) return true;
    const encoded = refs.encode(value) catch return false;
    return encoded < 128;
}
fn substitute(analysis: *const ssa.Function, facts: []const u32, state: []const u32, reg: u32, pc: usize, loop_depth: []const u32, stats: *Stats) u32 {
    if (reg >= state.len or analysis.captured[reg]) return reg;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= facts.len) return reg;
    const value = facts[id];
    if (!useful(value, analysis.values.items[id].uses)) return reg;
    // A one-use literal can execute millions of times. Preserve an already
    // hoisted numeric constant rather than decoding/converting it per iteration.
    const definition = analysis.values.items[id];
    if ((refs.tag(value) == .integer or refs.tag(value) == .constant) and
        definition.kind == .instruction and definition.pc < loop_depth.len and
        loop_depth[pc] > loop_depth[definition.pc])
    {
        stats.loop_invariants_kept += 1;
        return reg;
    }
    switch (refs.tag(value)) {
        .string => stats.string_uses += 1,
        .constant => stats.constant_uses += 1,
        .integer, .special => stats.immediate_uses += 1,
        else => unreachable,
    }
    return value;
}
fn runFunction(a: std.mem.Allocator, p: *ir.Program, f: *ir.Function) !Stats {
    var analysis = try ssa.build(a, p, f);
    defer analysis.deinit();
    const facts = try a.alloc(u32, analysis.values.items.len);
    defer a.free(facts);
    for (analysis.values.items, 0..) |node, id| facts[id] = try literal(p, f, node);
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value or facts[id] != unknown) continue;
            var selected: u32 = unknown;
            var valid = true;
            for (phi.inputs.items) |input| {
                const incoming = analysis.canonicalValue(input);
                if (incoming == id) continue;
                if (incoming == ssa.invalid_value or incoming >= facts.len or facts[incoming] == unknown) {
                    valid = false;
                    break;
                }
                if (selected == unknown) selected = facts[incoming] else if (selected != facts[incoming]) {
                    valid = false;
                    break;
                }
            }
            if (valid and selected != unknown) {
                facts[id] = selected;
                changed = true;
            }
        }
    }
    const loop_depth = try a.alloc(u32, f.insts.items.len);
    defer a.free(loop_depth);
    @memset(loop_depth, 0);
    for (f.insts.items, 0..) |inst, pc| {
        if (!sem.info(inst.op).target or inst.aux > pc) continue;
        for (loop_depth[inst.aux .. pc + 1]) |*depth| depth.* +|= 1;
    }
    const state = try a.alloc(u32, f.reg_count);
    defer a.free(state);
    var operands: std.ArrayList(u32) = .empty;
    errdefer operands.deinit(a);
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, bid| {
        const input = analysis.entry_states[bid];
        if (input) |s| @memcpy(state, s);
        for (block.start..block.end) |pc| {
            const original = f.insts.items[pc];
            var inst = original;
            if (input != null) inline for (sem.fields, 0..) |field, i| {
                if (refs.mask(inst.op) & (@as(u8, 1) << i) != 0) @field(inst, field) = substitute(&analysis, facts, state, @field(original, field), pc, loop_depth, &stats);
            };
            if (sem.info(inst.op).list != .none) {
                const old = try sem.operands(f, original);
                inst.aux = @intCast(operands.items.len);
                for (old) |reg| try operands.append(a, if (input != null) substitute(&analysis, facts, state, reg, pc, loop_depth, &stats) else reg);
            }
            if (input != null) try ssa.applyWrites(&analysis, f, state, @intCast(pc), null);
            f.insts.items[pc] = inst;
        }
    }
    f.operands.deinit(a);
    f.operands = operands;
    return stats;
}
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    if (p.references_lowered) return .{};
    var stats = Stats{};
    for (p.functions.items) |*maybe| if (maybe.*) |*f| {
        const one = try runFunction(a, p, f);
        stats.immediate_uses += one.immediate_uses;
        stats.constant_uses += one.constant_uses;
        stats.string_uses += one.string_uses;
        stats.loop_invariants_kept += one.loop_invariants_kept;
    };
    p.references_lowered = true;
    return stats;
}
