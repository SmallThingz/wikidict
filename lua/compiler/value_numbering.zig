const std = @import("std");
const ir = @import("ir.zig");
const ssa = @import("ssa.zig");
const sem = @import("semantics.zig");
pub const Stats = struct { expressions: u64 = 0, forwarded_reads: u64 = 0 };
const Key = struct { op: ir.Opcode, a: u32 = 0, b: u32 = 0, aux: u32 = 0 };
const Available = struct { reg: u32, value: u32 };
fn eligible(p: *const ir.Program, inst: ir.Inst) bool {
    return switch (inst.op) {
        .load_nil, .load_bool, .load_string, .not_, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number, .neg_number, .len_string => true,
        .load_const => p.constants.items[inst.aux] != .table,
        else => false,
    };
}
fn root(representatives: []const u32, start: u32) u32 {
    if (start == ssa.invalid_value or start >= representatives.len) return start;
    var id = start;
    while (representatives[id] != id) id = representatives[id];
    return id;
}
fn value(analysis: *const ssa.Function, reps: []const u32, state: []const u32, reg: u32) u32 {
    if (reg >= state.len or analysis.captured[reg]) return ssa.invalid_value;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or analysis.values.items[id].kind == .memory) return ssa.invalid_value;
    return root(reps, id);
}
fn forward(map: *const std.AutoHashMapUnmanaged(u32, u32), analysis: *const ssa.Function, reps: []const u32, state: []const u32, reg: u32, stats: *Stats) u32 {
    const id = value(analysis, reps, state, reg);
    if (id == ssa.invalid_value) return reg;
    const other = map.get(id) orelse return reg;
    if (other != reg and value(analysis, reps, state, other) == id) {
        stats.forwarded_reads += 1;
        return other;
    }
    return reg;
}
fn runFunction(a: std.mem.Allocator, p: *ir.Program, f: *ir.Function) !Stats {
    var analysis = try ssa.build(a, p, f);
    defer analysis.deinit();
    const reps = try a.alloc(u32, analysis.values.items.len);
    defer a.free(reps);
    for (reps, 0..) |*r, i| r.* = @intCast(i);
    const state = try a.alloc(u32, f.reg_count);
    defer a.free(state);
    var available: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer available.deinit(a);
    var expressions: std.AutoHashMapUnmanaged(Key, Available) = .empty;
    defer expressions.deinit(a);
    var operands: std.ArrayList(u32) = .empty;
    errdefer operands.deinit(a);
    var defs = try sem.Bits.initEmpty(a, f.reg_count);
    defer defs.deinit(a);
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, bid| {
        const input = analysis.entry_states[bid];
        if (input) |s| @memcpy(state, s);
        available.clearRetainingCapacity();
        expressions.clearRetainingCapacity();
        if (input != null) for (state, 0..) |_, reg| {
            if (!analysis.liveness.isLiveIn(@intCast(bid), @intCast(reg))) continue;
            const id = value(&analysis, reps, state, @intCast(reg));
            if (id != ssa.invalid_value) try available.put(a, id, @intCast(reg));
        };
        for (block.start..block.end) |pc| {
            const original = f.insts.items[pc];
            var inst = original;
            const d = sem.info(inst.op);
            if (input != null and !d.target) inline for (sem.fields, 0..) |field, i| {
                if (d.reads & (@as(u8, 1) << i) != 0) @field(inst, field) = forward(&available, &analysis, reps, state, @field(original, field), &stats);
            };
            if (d.list != .none) {
                const list = try sem.operands(f, original);
                inst.aux = @intCast(operands.items.len);
                for (list) |reg| try operands.append(a, if (input == null) reg else forward(&available, &analysis, reps, state, reg, &stats));
            }
            var key: ?Key = null;
            var duplicate: ?Available = null;
            if (input != null and eligible(p, original) and !analysis.captured[original.dst]) {
                var k = Key{ .op = original.op };
                if (d.reads & sem.a != 0) k.a = value(&analysis, reps, state, original.a) else k.a = original.a;
                if (d.reads & sem.b != 0) k.b = value(&analysis, reps, state, original.b);
                if (d.fields & sem.aux != 0) k.aux = original.aux;
                if (k.a != ssa.invalid_value and k.b != ssa.invalid_value) {
                    key = k;
                    if (expressions.get(k)) |found| if (value(&analysis, reps, state, found.reg) == root(reps, found.value)) {
                        duplicate = found;
                    };
                }
            }
            if (input != null) {
                try ssa.applyWrites(&analysis, f, state, @intCast(pc), null);
                if (key) |k| {
                    const id = analysis.canonicalValue(state[original.dst]);
                    if (duplicate) |found| {
                        inst = .{ .op = .move, .dst = original.dst, .a = found.reg };
                        reps[id] = root(reps, found.value);
                        stats.expressions += 1;
                    } else try expressions.put(a, k, .{ .reg = original.dst, .value = id });
                }
                defs.unsetAll();
                try sem.writes(original, null, &defs);
                var it = defs.iterator(.{});
                while (it.next()) |reg| {
                    const id = value(&analysis, reps, state, @intCast(reg));
                    if (id == ssa.invalid_value) continue;
                    if (available.get(id)) |prior| if (value(&analysis, reps, state, prior) == id) {
                        continue;
                    };
                    try available.put(a, id, @intCast(reg));
                }
            }
            f.insts.items[pc] = sem.canonical(inst);
        }
    }
    f.operands.deinit(a);
    f.operands = operands;
    return stats;
}
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    for (p.functions.items) |*maybe| if (maybe.*) |*f| {
        const one = try runFunction(a, p, f);
        stats.expressions += one.expressions;
        stats.forwarded_reads += one.forwarded_reads;
    };
    return stats;
}
