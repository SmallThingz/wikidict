const std = @import("std");
const ir = @import("ir.zig");
const ssa = @import("ssa.zig");
const shape_key = @import("../abi/shape_key.zig");
const shape_opt = @import("shape_opt.zig");
const numbers = @import("numbers.zig");

const none = std.math.maxInt(u32);

pub const Stats = struct {
    shaped_templates: u64 = 0,
    slot_reads: u64 = 0,
    slot_writes: u64 = 0,
};

fn constKey(program: *const ir.Program, id: u32) ?u32 {
    if (id >= program.constants.items.len) return null;
    return switch (program.constants.items[id]) {
        .string => |sid| shape_key.string(sid) catch null,
        .integer => |value| shape_key.integer(value),
        .number_bits => |bits| shape_key.number(@bitCast(bits)),
        .number => |sid| if (sid < program.strings.items.len)
            shape_key.number(numbers.parse(program.strings.items[sid]) catch return null)
        else
            null,
        else => null,
    };
}
fn tableChild(program: *const ir.Program, parent: u32, wanted: u32) ?u32 {
    if (parent >= program.constants.items.len or program.constants.items[parent] != .table) return null;
    const table = program.constants.items[parent].table;
    if (table.first > program.const_entries.items.len or table.count > program.const_entries.items.len - table.first) return null;
    var list_index: i64 = 1;
    var result: ?u32 = null;
    for (program.const_entries.items[table.first..][0..table.count]) |entry| {
        const key = if (entry.key == ir.implicit_list_key) blk: {
            const encoded = shape_key.integer(list_index) orelse return null;
            list_index += 1;
            break :blk encoded;
        } else constKey(program, entry.key) orelse continue;
        if (key != wanted) continue;
        result = if (entry.value < program.constants.items.len and program.constants.items[entry.value] == .table)
            entry.value
        else
            null;
    }
    return result;
}

fn mergePhi(analysis: *const ssa.Function, facts: []const u32, phi: ssa.Phi) u32 {
    var selected: u32 = none;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= facts.len or facts[id] == none) return none;
        if (selected == none) selected = facts[id] else if (selected != facts[id]) return none;
    }
    return selected;
}
fn factForReg(analysis: *const ssa.Function, facts: []const u32, state: []const ssa.ValueId, reg: u32) u32 {
    if (reg >= state.len or analysis.captured[reg]) return none;
    const id = analysis.canonicalValue(state[reg]);
    return if (id != ssa.invalid_value and id < facts.len) facts[id] else none;
}

fn keyForReg(
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *const ssa.Function,
    state: []const ssa.ValueId,
    reg: u32,
) ?u32 {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= analysis.values.items.len) return null;
    const node = analysis.values.items[id];
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const inst = function.insts.items[node.pc];
    return switch (inst.op) {
        .load_string => shape_key.string(inst.aux) catch null,
        .load_number => if (inst.aux < program.strings.items.len)
            shape_key.number(numbers.parse(program.strings.items[inst.aux]) catch return null)
        else
            null,
        .load_const => constKey(program, inst.aux),
        else => null,
    };
}
fn pathKey(table_id: u32, key: u32) u64 {
    return (@as(u64, table_id) << 32) | key;
}

fn canFollow(
    parent: u32,
    key: u32,
    unsafe: ?[]const bool,
    mutated: ?*const std.AutoHashMapUnmanaged(u64, void),
) bool {
    if (unsafe) |blocked| if (parent >= blocked.len or blocked[parent]) return false;
    if (mutated) |writes| if (writes.contains(pathKey(parent, key))) return false;
    return true;
}

fn childForInst(
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *const ssa.Function,
    facts: []const u32,
    state: []const ssa.ValueId,
    inst: ir.Inst,
    unsafe: ?[]const bool,
    mutated: ?*const std.AutoHashMapUnmanaged(u64, void),
) ?u32 {
    if (inst.op != .get_field and inst.op != .get_index) return null;
    const parent = factForReg(analysis, facts, state, inst.a);
    if (parent == none) return null;
    const key = if (inst.op == .get_field)
        shape_key.string(inst.aux) catch return null
    else
        keyForReg(program, function, analysis, state, inst.b) orelse return null;
    if (!canFollow(parent, key, unsafe, mutated)) return null;
    return tableChild(program, parent, key);
}
fn buildFacts(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *ssa.Function,
    facts: []u32,
    unsafe: ?[]const bool,
    mutated: ?*const std.AutoHashMapUnmanaged(u64, void),
) !void {
    @memset(facts, none);
    for (analysis.values.items, 0..) |node, id| if (node.kind == .instruction and node.pc < function.insts.items.len) {
        const inst = function.insts.items[node.pc];
        if (inst.op == .load_const and inst.aux < program.constants.items.len and program.constants.items[inst.aux] == .table)
            facts[id] = inst.aux;
    };
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value or facts[id] != none) continue;
            const value = mergePhi(analysis, facts, phi);
            if (value != none) {
                facts[id] = value;
                changed = true;
            }
        }
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                const child = childForInst(program, function, analysis, facts, state, inst, unsafe, mutated);
                try ssa.applyWrites(analysis, function, state, pc, null);
                if (child) |table_id| if (inst.dst < state.len) {
                    const value = analysis.canonicalValue(state[inst.dst]);
                    if (value != ssa.invalid_value and value < facts.len and facts[value] == none) {
                        facts[value] = table_id;
                        changed = true;
                    }
                };
            }
        }
    }
}

fn markFact(unsafe: []bool, analysis: *const ssa.Function, facts: []const u32, state: []const ssa.ValueId, reg: u32) void {
    const table_id = factForReg(analysis, facts, state, reg);
    if (table_id != none and table_id < unsafe.len) unsafe[table_id] = true;
}

fn markOperands(
    unsafe: []bool,
    analysis: *const ssa.Function,
    facts: []const u32,
    state: []const ssa.ValueId,
    function: *const ir.Function,
    at: u32,
    count: u32,
) void {
    if (@as(usize, at) + count > function.operands.items.len) return;
    for (function.operands.items[at .. at + count]) |reg| markFact(unsafe, analysis, facts, state, reg);
}
fn collectSafety(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *ssa.Function,
    facts: []const u32,
    unsafe: []bool,
    mutated: *std.AutoHashMapUnmanaged(u64, void),
) !void {
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            if (inst.op == .set_field) {
                const table_id = factForReg(analysis, facts, state, inst.a);
                if (table_id != none) try mutated.put(allocator, pathKey(table_id, try shape_key.string(inst.aux)), {});
                markFact(unsafe, analysis, facts, state, inst.c);
            } else if (inst.op == .set_index or inst.op == .table_set) {
                const table_id = factForReg(analysis, facts, state, inst.a);
                if (table_id != none) {
                    if (keyForReg(program, function, analysis, state, inst.b)) |key|
                        try mutated.put(allocator, pathKey(table_id, key), {})
                    else if (table_id < unsafe.len)
                        unsafe[table_id] = true;
                }
                markFact(unsafe, analysis, facts, state, inst.c);
            }
            switch (inst.op) {
                .call, .call_vararg => {
                    markFact(unsafe, analysis, facts, state, inst.a);
                    markOperands(unsafe, analysis, facts, state, function, inst.aux, inst.b);
                    if (inst.op == .call_vararg) markFact(unsafe, analysis, facts, state, inst.c);
                },
                .direct_call, .direct_call_vararg => {
                    markOperands(unsafe, analysis, facts, state, function, inst.aux, inst.b);
                    if (inst.op == .direct_call_vararg) markFact(unsafe, analysis, facts, state, inst.c);
                },
                .method_call, .method_call_vararg => {
                    markFact(unsafe, analysis, facts, state, inst.a);
                    markOperands(unsafe, analysis, facts, state, function, inst.aux, inst.b);
                    if (inst.op == .method_call_vararg) markFact(unsafe, analysis, facts, state, inst.c);
                },
                .method_call_field, .method_call_field_vararg => {
                    markFact(unsafe, analysis, facts, state, inst.a);
                    markOperands(unsafe, analysis, facts, state, function, inst.aux, inst.b);
                    if (inst.op == .method_call_field_vararg) markFact(unsafe, analysis, facts, state, inst.c);
                },
                .set_global, .set_global_slot => markFact(unsafe, analysis, facts, state, inst.a),
                .set_upvalue => markFact(unsafe, analysis, facts, state, inst.b),
                .table_append => markFact(unsafe, analysis, facts, state, inst.b),
                else => {},
            }
            if (inst.op == .closure or inst.op == .load_function) {
                if (inst.aux < program.functions.items.len) if (program.functions.items[inst.aux]) |child| {
                    for (child.upvalues.items) |upvalue| if (upvalue.source == .local)
                        markFact(unsafe, analysis, facts, state, upvalue.index);
                };
            }
            try ssa.applyWrites(analysis, function, state, pc, null);
        }
    }
}

fn addKey(
    allocator: std.mem.Allocator,
    layouts: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)),
    table_id: u32,
    key: u32,
) !void {
    const entry = try layouts.getOrPut(allocator, table_id);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    for (entry.value_ptr.items) |old| if (old == key) return;
    try entry.value_ptr.append(allocator, key);
}

fn lessU32(_: void, lhs: u32, rhs: u32) bool {
    return lhs < rhs;
}
fn collectKeys(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *ssa.Function,
    facts: []const u32,
    layouts: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)),
) !void {
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            if (inst.op == .get_field or inst.op == .set_field) {
                const table_id = factForReg(analysis, facts, state, inst.a);
                if (table_id != none) try addKey(allocator, layouts, table_id, try shape_key.string(inst.aux));
            } else if (inst.op == .get_index or inst.op == .set_index or inst.op == .table_set) {
                const table_id = factForReg(analysis, facts, state, inst.a);
                if (table_id != none) if (keyForReg(program, function, analysis, state, inst.b)) |key|
                    try addKey(allocator, layouts, table_id, key);
            }
            try ssa.applyWrites(analysis, function, state, pc, null);
        }
    }
}

fn fieldSlot(fields: []const u32, key: u32) ?u32 {
    for (fields, 0..) |candidate, slot| if (candidate == key) return @intCast(slot);
    return null;
}
fn attachLayouts(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    layouts: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)),
    stats: *Stats,
) !void {
    var it = layouts.iterator();
    while (it.next()) |entry| {
        const table_id = entry.key_ptr.*;
        if (table_id >= program.constants.items.len or program.constants.items[table_id] != .table) continue;
        const table = &program.constants.items[table_id].table;
        const keys = entry.value_ptr;
        var choice_count: u32 = 0;
        if (table.shape != ir.no_shape) {
            if (table.shape >= program.shapes.items.len) return error.BadShape;
            const old = program.shapes.items[table.shape];
            choice_count = old.choice_count;
            for (old.field_keys.items) |key| {
                var found = false;
                for (keys.items) |candidate| if (candidate == key) {
                    found = true;
                    break;
                };
                if (!found) try keys.append(allocator, key);
            }
        }
        std.sort.heap(u32, keys.items, {}, lessU32);
        const shape_id = try shape_opt.findOrAddShape(allocator, program, @intCast(keys.items.len), keys.items, choice_count, true);
        if (table.shape != shape_id) {
            table.shape = shape_id;
            stats.shaped_templates += 1;
        }
    }
}
fn rewrite(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *ir.Function,
    analysis: *ssa.Function,
    facts: []const u32,
    stats: *Stats,
) !void {
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = &function.insts.items[pc];
            const table_id = if (inst.op == .get_field or inst.op == .set_field or inst.op == .get_index or inst.op == .set_index or inst.op == .table_set)
                factForReg(analysis, facts, state, inst.a)
            else
                none;
            if (table_id != none and table_id < program.constants.items.len and program.constants.items[table_id] == .table) {
                const shape_id = program.constants.items[table_id].table.shape;
                if (shape_id != ir.no_shape and shape_id < program.shapes.items.len) {
                    var key: ?u32 = null;
                    if (inst.op == .get_field or inst.op == .set_field)
                        key = shape_key.string(inst.aux) catch null
                    else if (inst.op == .get_index or inst.op == .set_index or inst.op == .table_set)
                        key = keyForReg(program, function, analysis, state, inst.b);
                    if (key) |encoded| if (fieldSlot(program.shapes.items[shape_id].field_keys.items, encoded)) |slot| {
                        inst.aux = slot;
                        if (inst.op == .get_field or inst.op == .get_index) {
                            inst.op = .get_slot;
                            stats.slot_reads += 1;
                        } else {
                            inst.op = .set_slot;
                            stats.slot_writes += 1;
                        }
                    };
                }
            }
            try ssa.applyWrites(analysis, function, state, pc, null);
        }
    }
}

fn deinitLayouts(allocator: std.mem.Allocator, layouts: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32))) void {
    var it = layouts.valueIterator();
    while (it.next()) |keys| keys.deinit(allocator);
    layouts.deinit(allocator);
}

fn runFunction(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function) !Stats {
    var has_table_root = false;
    for (function.insts.items) |inst| if (inst.op == .load_const and inst.aux < program.constants.items.len and program.constants.items[inst.aux] == .table) {
        has_table_root = true;
        break;
    };
    if (!has_table_root) return .{};
    var analysis = try ssa.build(allocator, program, function);
    defer analysis.deinit();
    const facts = try allocator.alloc(u32, analysis.values.items.len);
    defer if (facts.len != 0) allocator.free(facts);
    try buildFacts(allocator, program, function, &analysis, facts, null, null);
    const unsafe = try allocator.alloc(bool, program.constants.items.len);
    defer if (unsafe.len != 0) allocator.free(unsafe);
    @memset(unsafe, false);
    var mutated: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer mutated.deinit(allocator);
    try collectSafety(allocator, program, function, &analysis, facts, unsafe, &mutated);
    try buildFacts(allocator, program, function, &analysis, facts, unsafe, &mutated);

    var layouts: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer deinitLayouts(allocator, &layouts);
    try collectKeys(allocator, program, function, &analysis, facts, &layouts);
    var stats = Stats{};
    try attachLayouts(allocator, program, &layouts, &stats);
    try rewrite(allocator, program, function, &analysis, facts, &stats);
    return stats;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return error.LateConstShapeAnalysis;
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function);
        stats.shaped_templates += one.shaped_templates;
        stats.slot_reads += one.slot_reads;
        stats.slot_writes += one.slot_writes;
    };
    return stats;
}
