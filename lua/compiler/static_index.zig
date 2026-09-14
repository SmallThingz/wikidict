const std = @import("std");
const ir = @import("ir.zig");
const ssa = @import("ssa.zig");
const static_key = @import("../abi/static_keys.zig");
const numbers = @import("numbers.zig");

const none = std.math.maxInt(u32);

pub const Stats = struct {
    reads: u64 = 0,
    writes: u64 = 0,
};

fn literalRef(program: *const ir.Program, function: *const ir.Function, node: ssa.Value) ?u32 {
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const inst = function.insts.items[node.pc];
    const number: f64 = switch (inst.op) {
        .load_number => if (inst.aux < program.strings.items.len)
            numbers.parse(program.strings.items[inst.aux]) catch return null
        else
            return null,
        .load_const => if (inst.aux < program.constants.items.len) switch (program.constants.items[inst.aux]) {
            .integer => |n| @floatFromInt(n),
            .number_bits => |bits| @bitCast(bits),
            .number => |sid| if (sid < program.strings.items.len)
                numbers.parse(program.strings.items[sid]) catch return null
            else
                return null,
            else => return null,
        } else return null,
        else => return null,
    };
    return static_key.refForNumber(number);
}
fn mergePhi(analysis: *const ssa.Function, refs: []const u32, phi: ssa.Phi) u32 {
    var selected: u32 = none;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= refs.len or refs[id] == none) return none;
        if (selected == none) selected = refs[id] else if (selected != refs[id]) return none;
    }
    return selected;
}

fn buildRefs(analysis: *const ssa.Function, program: *const ir.Program, function: *const ir.Function, refs: []u32) void {
    @memset(refs, none);
    for (analysis.values.items, 0..) |node, id| {
        if (literalRef(program, function, node)) |ref| refs[id] = ref;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value or refs[id] != none) continue;
            const ref = mergePhi(analysis, refs, phi);
            if (ref != none) {
                refs[id] = ref;
                changed = true;
            }
        }
    }
}

fn refForReg(analysis: *const ssa.Function, refs: []const u32, state: []const ssa.ValueId, reg: u32) ?u32 {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= refs.len or refs[id] == none) return null;
    return refs[id];
}
fn hasIndex(function: *const ir.Function) bool {
    for (function.insts.items) |inst| switch (inst.op) {
        .get_index, .set_index, .table_set => return true,
        else => {},
    };
    return false;
}

fn runFunction(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function) !Stats {
    if (!hasIndex(function)) return .{};
    var analysis = try ssa.build(allocator, program, function);
    defer analysis.deinit();
    const refs = try allocator.alloc(u32, analysis.values.items.len);
    defer if (refs.len != 0) allocator.free(refs);
    buildRefs(&analysis, program, function, refs);
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = &function.insts.items[pc];
            if (inst.op == .get_index or inst.op == .set_index or inst.op == .table_set) {
                if (refForReg(&analysis, refs, state, inst.b)) |ref| {
                    inst.aux = ref;
                    if (inst.op == .get_index) {
                        inst.op = .get_slot;
                        stats.reads += 1;
                    } else {
                        inst.op = .set_slot;
                        stats.writes += 1;
                    }
                }
            }
            try ssa.applyWrites(&analysis, function, state, pc, null);
        }
    }
    return stats;
}
pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return error.LateStaticIndexAnalysis;
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function);
        stats.reads += one.reads;
        stats.writes += one.writes;
    };
    return stats;
}
