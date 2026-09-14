const std = @import("std");
const ir = @import("ir.zig");
const shape_key = @import("../abi/shape_key.zig");
const ssa = @import("ssa.zig");
const cg = @import("callgraph.zig");
const sem = @import("semantics.zig");
const none = std.math.maxInt(u32);
pub const Stats = struct { returns: u64 = 0, parameters: u64 = 0, slot_reads: u64 = 0, slot_writes: u64 = 0 };
const Facts = struct {
    analysis: ssa.Function,
    shapes: []u32,
    a: std.mem.Allocator,
    fn deinit(self: *@This()) void {
        self.analysis.deinit();
        self.a.free(self.shapes);
    }
    fn value(self: *const @This(), values: []const u32, raw: u32) u32 {
        const id = self.analysis.canonicalValue(raw);
        return if (id < values.len) values[id] else none;
    }
    fn reg(self: *const @This(), values: []const u32, state: []const u32, r: u32) u32 {
        return if (r < state.len and !self.analysis.captured[r]) self.value(values, state[r]) else none;
    }
};
fn mergePhi(facts: *Facts, values: []const u32, phi: ssa.Phi) u32 {
    var result: u32 = none;
    for (phi.inputs.items) |input| {
        if (facts.analysis.canonicalValue(input) == phi.value) continue;
        const id = facts.value(values, input);
        if (id == none) return none;
        if (result == none) result = id else if (result != id) return none;
    }
    return result;
}
fn analyze(a: std.mem.Allocator, p: *const ir.Program, f: *const ir.Function, sites: []const cg.CallSite, returns: []const u32, canonical: []const u32, params: []const u32) !Facts {
    var analysis = try ssa.build(a, p, f);
    errdefer analysis.deinit();
    const shapes = try a.alloc(u32, analysis.values.items.len);
    errdefer a.free(shapes);
    @memset(shapes, none);
    const targets = try a.alloc(u32, f.insts.items.len);
    defer a.free(targets);
    @memset(targets, none);
    for (sites) |site| targets[site.pc] = site.callee;
    var out = Facts{ .analysis = analysis, .shapes = shapes, .a = a };
    for (out.analysis.values.items, 0..) |node, id| switch (node.kind) {
        .parameter => if (node.reg < params.len) {
            shapes[id] = params[node.reg];
        },
        .instruction => {
            const inst = f.insts.items[node.pc];
            switch (inst.op) {
                .new_table_shape => shapes[id] = canonical[inst.aux],
                .call, .call_vararg, .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg => if (node.reg == inst.dst and targets[node.pc] != none) {
                    shapes[id] = returns[targets[node.pc]];
                },
                else => {},
            }
        },
        else => {},
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (out.analysis.phis.items) |phi| {
            if (out.analysis.canonicalValue(phi.value) != phi.value) continue;
            {
                const values = out.shapes;
                if (values[phi.value] == none) {
                    const value = mergePhi(&out, values, phi);
                    if (value != none) {
                        values[phi.value] = value;
                        changed = true;
                    }
                }
            }
        }
    }
    return out;
}
fn returnShape(a: std.mem.Allocator, facts: *Facts, f: *const ir.Function) !u32 {
    const state = try a.alloc(u32, f.reg_count);
    defer a.free(state);
    var found = false;
    var result: u32 = none;
    for (f.insts.items, 0..) |inst, pc| {
        if (inst.op != .ret and inst.op != .ret_var) continue;
        if (facts.analysis.entry_states[facts.analysis.graph.block_of_pc[pc]] == null) continue;
        try ssa.stateBefore(&facts.analysis, f, @intCast(pc), state);
        const operands = try sem.operands(f, inst);
        const reg = if (operands.len != 0) operands[0] else if (inst.op == .ret_var) inst.a else return none;
        const shape = facts.reg(facts.shapes, state, reg);
        if (shape == none or (found and result != shape)) return none;
        found = true;
        result = shape;
    }
    return if (found) result else none;
}
fn collectParamFacts(
    a: std.mem.Allocator,
    p: *const ir.Program,
    f: *const ir.Function,
    sites: []const cg.CallSite,
    facts: *Facts,
    offsets: []const usize,
    candidate: []u32,
    seen: []bool,
    invalid: []bool,
    closed: []const bool,
) !void {
    const state = try a.alloc(u32, f.reg_count);
    defer a.free(state);
    for (sites) |site| {
        if (site.callee >= p.functions.items.len or !closed[site.callee]) continue;
        const target = p.functions.items[site.callee] orelse continue;
        if (site.pc >= f.insts.items.len) continue;
        try ssa.stateBefore(&facts.analysis, f, site.pc, state);
        const args = try sem.operands(f, f.insts.items[site.pc]);
        for (0..target.param_count) |param| {
            const slot = offsets[site.callee] + param;
            if (param >= args.len) {
                invalid[slot] = true;
                continue;
            }
            const shape = facts.reg(facts.shapes, state, args[param]);
            if (shape == none) {
                invalid[slot] = true;
                continue;
            }
            if (!seen[slot]) {
                candidate[slot] = shape;
                seen[slot] = true;
            } else if (candidate[slot] != shape) invalid[slot] = true;
        }
    }
}
fn rewrite(p: *const ir.Program, f: *ir.Function, facts: *Facts, stats: *Stats) !void {
    const state = try facts.a.alloc(u32, f.reg_count);
    defer facts.a.free(state);
    for (facts.analysis.graph.blocks.items, 0..) |block, bid| {
        const input = facts.analysis.entry_states[bid] orelse continue;
        @memcpy(state, input);
        for (block.start..block.end) |pc| {
            const inst = f.insts.items[pc];
            var replacement = inst;
            if (inst.op == .get_field or inst.op == .set_field) {
                const shape = facts.reg(facts.shapes, state, inst.a);
                if (shape != none) {
                    const fields = p.shapes.items[shape].field_keys.items;
                    const key = try shape_key.string(inst.aux);
                    if (std.mem.indexOfScalar(u32, fields, key)) |slot| {
                        replacement.aux = @intCast(slot);
                        if (inst.op == .get_field) {
                            replacement.op = .get_slot;
                            stats.slot_reads += 1;
                        } else {
                            replacement.op = .set_slot;
                            stats.slot_writes += 1;
                        }
                    }
                }
            }
            try ssa.applyWrites(&facts.analysis, f, state, @intCast(pc), null);
            f.insts.items[pc] = replacement;
        }
    }
}

pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    if (p.references_lowered) return error.LateShapeAnalysis;
    var calls = try cg.build(a, p);
    defer calls.deinit();
    var layouts: std.StringHashMapUnmanaged(u32) = .empty;
    defer layouts.deinit(a);
    const canonical = try a.alloc(u32, p.shapes.items.len);
    defer a.free(canonical);
    for (p.shapes.items, 0..) |shape, id| {
        canonical[id] = none;
        if (shape.field_keys.items.len == 0) continue;
        const entry = try layouts.getOrPut(a, std.mem.sliceAsBytes(shape.field_keys.items));
        if (!entry.found_existing) entry.value_ptr.* = @intCast(id);
        canonical[id] = entry.value_ptr.*;
    }

    const offsets = try a.alloc(usize, p.functions.items.len + 1);
    defer a.free(offsets);
    offsets[0] = 0;
    for (p.functions.items, 0..) |maybe, id| {
        offsets[id + 1] = offsets[id] + if (maybe) |fun| fun.param_count else 0;
    }
    const params = try a.alloc(u32, offsets[p.functions.items.len]);
    defer a.free(params);
    @memset(params, none);
    const candidate = try a.alloc(u32, params.len);
    defer a.free(candidate);
    const seen = try a.alloc(bool, params.len);
    defer a.free(seen);
    const invalid = try a.alloc(bool, params.len);
    defer a.free(invalid);
    const returns = try a.alloc(u32, p.functions.items.len);
    defer a.free(returns);
    @memset(returns, none);

    var stats = Stats{};
    var changed = true;
    while (changed) {
        changed = false;
        @memset(candidate, none);
        @memset(seen, false);
        @memset(invalid, false);
        var cursor: usize = 0;
        for (p.functions.items, 0..) |maybe, id| {
            var finish = cursor;
            while (finish < calls.calls.items.len and calls.calls.items[finish].caller == id) : (finish += 1) {}
            defer cursor = finish;
            const fun = &(maybe orelse continue);
            const param_slice = params[offsets[id]..offsets[id + 1]];
            var facts = try analyze(a, p, fun, calls.calls.items[cursor..finish], returns, canonical, param_slice);
            defer facts.deinit();
            if (returns[id] == none) {
                const shape = try returnShape(a, &facts, fun);
                if (shape != none) {
                    returns[id] = shape;
                    stats.returns += 1;
                    changed = true;
                }
            }
            try collectParamFacts(a, p, fun, calls.calls.items[cursor..finish], &facts, offsets, candidate, seen, invalid, calls.closed);
        }
        for (p.functions.items, 0..) |_, id| {
            if (!calls.closed[id]) continue;
            for (offsets[id]..offsets[id + 1]) |slot| {
                if (params[slot] != none or !seen[slot] or invalid[slot]) continue;
                params[slot] = candidate[slot];
                stats.parameters += 1;
                changed = true;
            }
        }
    }
    var cursor: usize = 0;
    for (p.functions.items, 0..) |*maybe, id| {
        var finish = cursor;
        while (finish < calls.calls.items.len and calls.calls.items[finish].caller == id) : (finish += 1) {}
        defer cursor = finish;
        const fun = if (maybe.*) |*value| value else continue;
        const param_slice = params[offsets[id]..offsets[id + 1]];
        var facts = try analyze(a, p, fun, calls.calls.items[cursor..finish], returns, canonical, param_slice);
        defer facts.deinit();
        try rewrite(p, fun, &facts, &stats);
    }
    return stats;
}
