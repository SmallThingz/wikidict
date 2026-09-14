const sem = @import("semantics.zig");
const std = @import("std");
const ir = @import("ir.zig");
const ssa = @import("ssa.zig");
const shape_key = @import("../abi/shape_key.zig");
const numbers = @import("numbers.zig");

pub const Stats = struct {
    shaped_tables: u32 = 0,
    fixed_slots: u32 = 0,
    choice_slots: u32 = 0,
    field_reads: u32 = 0,
    field_writes: u32 = 0,
    choice_reads: u32 = 0,
    choice_writes: u32 = 0,
    anonymous_tables: u32 = 0,
};

const Allocation = struct {
    value: ssa.ValueId,
    pc: u32,
    fields: std.ArrayList(u32) = .empty,
    dynamic_key: ssa.ValueId = ssa.invalid_value,
    dynamic_seen: bool = false,
    dynamic_conflict: bool = false,
    escaped: bool = false,
    array_use: bool = false,
    shape_id: u32 = std.math.maxInt(u32),
    choice: bool = false,

    fn deinit(self: *Allocation, a: std.mem.Allocator) void {
        self.fields.deinit(a);
    }
};
fn addField(a: std.mem.Allocator, alloc: *Allocation, sid: u32) !void {
    for (alloc.fields.items) |old| if (old == sid) return;
    try alloc.fields.append(a, sid);
}

fn noteDynamic(alloc: *Allocation, key: ssa.ValueId) void {
    if (!alloc.dynamic_seen) {
        alloc.dynamic_seen = true;
        alloc.dynamic_key = key;
    } else if (alloc.dynamic_key != key) {
        alloc.dynamic_conflict = true;
    }
}

fn shapeKeyForValue(program: *const ir.Program, function: *const ir.Function, analysis: *const ssa.Function, raw: ssa.ValueId) ?u32 {
    const id = analysis.canonicalValue(raw);
    if (id == ssa.invalid_value or id >= analysis.values.items.len) return null;
    const value = analysis.values.items[id];
    if (value.kind != .instruction or value.pc >= function.insts.items.len) return null;
    const inst = function.insts.items[value.pc];
    return switch (inst.op) {
        .load_string => shape_key.string(inst.aux) catch null,
        .load_number => if (inst.aux < program.strings.items.len)
            shape_key.number(numbers.parse(program.strings.items[inst.aux]) catch return null)
        else
            null,
        .load_const => if (inst.aux < program.constants.items.len) switch (program.constants.items[inst.aux]) {
            .string => |sid| shape_key.string(sid) catch null,
            .number_bits => |bits| shape_key.number(@bitCast(bits)),
            .number => |sid| if (sid < program.strings.items.len)
                shape_key.number(numbers.parse(program.strings.items[sid]) catch return null)
            else
                null,
            .integer => |n| shape_key.integer(n),
            else => null,
        } else null,
        else => null,
    };
}
fn allocIndex(map: *const std.AutoHashMapUnmanaged(ssa.ValueId, u32), analysis: *const ssa.Function, state: []const ssa.ValueId, reg: u32) ?u32 {
    if (reg >= state.len) return null;
    return map.get(analysis.canonicalValue(state[reg]));
}

fn markEscape(map: *const std.AutoHashMapUnmanaged(ssa.ValueId, u32), allocations: []Allocation, analysis: *const ssa.Function, state: []const ssa.ValueId, reg: u32) void {
    if (allocIndex(map, analysis, state, reg)) |index| allocations[index].escaped = true;
}

fn markOperandsEscape(map: *const std.AutoHashMapUnmanaged(ssa.ValueId, u32), allocations: []Allocation, analysis: *const ssa.Function, state: []const ssa.ValueId, function: *const ir.Function, at: u32, count: u32) void {
    if (@as(usize, at) + count > function.operands.items.len) return;
    for (function.operands.items[at .. at + count]) |reg| markEscape(map, allocations, analysis, state, reg);
}

fn noteKey(a: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function, analysis: *const ssa.Function, alloc: *Allocation, state: []const ssa.ValueId, key_reg: u32) !void {
    if (key_reg >= state.len) return;
    const raw = analysis.canonicalValue(state[key_reg]);
    if (shapeKeyForValue(program, function, analysis, raw)) |key| {
        try addField(a, alloc, key);
    } else {
        noteDynamic(alloc, raw);
    }
}
fn collectAllocations(a: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function, analysis: *ssa.Function, allocations: *std.ArrayList(Allocation), map: *std.AutoHashMapUnmanaged(ssa.ValueId, u32)) !void {
    const state = try a.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) a.free(state);
    for (analysis.graph.blocks.items, 0..) |block, block_index| {
        const entry = analysis.entry_states[block_index] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            try ssa.applyWrites(analysis, function, state, pc, null);
            if (inst.op != .new_table or inst.dst >= state.len or analysis.captured[inst.dst]) continue;
            const value = analysis.canonicalValue(state[inst.dst]);
            if (value == ssa.invalid_value) continue;
            const index: u32 = @intCast(allocations.items.len);
            try allocations.append(a, .{ .value = value, .pc = pc, .escaped = analysis.captured[inst.dst] });
            try map.put(a, value, index);
        }
    }
    _ = program;
}

fn scanUses(a: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function, analysis: *ssa.Function, allocations: []Allocation, map: *const std.AutoHashMapUnmanaged(ssa.ValueId, u32)) !void {
    // A phi may retain an earlier dynamic instance of the same allocation site.
    // Do not confuse allocation-site identity with per-execution object identity.
    for (analysis.phis.items) |phi| for (phi.inputs.items) |raw| {
        if (map.get(analysis.canonicalValue(raw))) |index| allocations[index].escaped = true;
    };
    const state = try a.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) a.free(state);
    for (analysis.graph.blocks.items, 0..) |block, block_index| {
        const entry = analysis.entry_states[block_index] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            switch (inst.op) {
                .get_field => if (allocIndex(map, analysis, state, inst.a)) |index|
                    try addField(a, &allocations[index], try shape_key.string(inst.aux)),
                .set_field => {
                    if (allocIndex(map, analysis, state, inst.a)) |index|
                        try addField(a, &allocations[index], try shape_key.string(inst.aux));
                    markEscape(map, allocations, analysis, state, inst.c);
                },
                .get_index => {
                    if (allocIndex(map, analysis, state, inst.a)) |index| try noteKey(a, program, function, analysis, &allocations[index], state, inst.b);
                    markEscape(map, allocations, analysis, state, inst.b);
                },
                .set_index, .table_set => {
                    markEscape(map, allocations, analysis, state, inst.b);
                    if (allocIndex(map, analysis, state, inst.a)) |index| try noteKey(a, program, function, analysis, &allocations[index], state, inst.b);
                    markEscape(map, allocations, analysis, state, inst.c);
                },
                .table_append => {
                    if (allocIndex(map, analysis, state, inst.a)) |index| allocations[index].array_use = true;
                    markEscape(map, allocations, analysis, state, inst.b);
                },
                .table_append_var => {
                    if (allocIndex(map, analysis, state, inst.a)) |index| allocations[index].array_use = true;
                },
                .move => if (inst.dst < analysis.captured.len and analysis.captured[inst.dst]) markEscape(map, allocations, analysis, state, inst.a),
                .set_global => markEscape(map, allocations, analysis, state, inst.a),
                .set_upvalue => markEscape(map, allocations, analysis, state, inst.b),
                else => {},
            }
            switch (inst.op) {
                .call, .call_vararg => {
                    markEscape(map, allocations, analysis, state, inst.a);
                    markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.b);
                    if (inst.op == .call_vararg) markEscape(map, allocations, analysis, state, inst.c);
                },
                .direct_call, .direct_call_vararg => {
                    markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.b);
                    if (inst.op == .direct_call_vararg) markEscape(map, allocations, analysis, state, inst.c);
                },
                .method_call, .method_call_vararg => {
                    markEscape(map, allocations, analysis, state, inst.a);
                    markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.b);
                    if (inst.op == .method_call_vararg) markEscape(map, allocations, analysis, state, inst.c);
                },
                .method_call_field, .method_call_field_vararg => {
                    markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.b);
                    if (inst.op == .method_call_field_vararg) markEscape(map, allocations, analysis, state, inst.c);
                },
                .ret => markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.count),
                .ret_var => {
                    markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.count);
                    markEscape(map, allocations, analysis, state, inst.a);
                },
                else => {},
            }
            switch (inst.op) {
                .closure => if (inst.aux < program.functions.items.len) if (program.functions.items[inst.aux]) |child| {
                    for (child.upvalues.items) |upvalue| if (upvalue.source == .local)
                        markEscape(map, allocations, analysis, state, upvalue.index);
                },
                .add, .sub, .mul, .div, .mod, .pow, .eq, .ne, .lt, .le, .gt, .ge => {
                    markEscape(map, allocations, analysis, state, inst.a);
                    markEscape(map, allocations, analysis, state, inst.b);
                },
                .len, .neg => markEscape(map, allocations, analysis, state, inst.a),
                .concat => markOperandsEscape(map, allocations, analysis, state, function, inst.aux, inst.count),
                .generic_for_init, .generic_for_next => {
                    markEscape(map, allocations, analysis, state, inst.a);
                    markEscape(map, allocations, analysis, state, inst.b);
                    markEscape(map, allocations, analysis, state, inst.c);
                },
                .get_field, .set_field, .get_index, .set_index, .table_set, .table_append, .table_append_var, .move, .not_, .jump_if_false => {},
                else => {
                    // Prior passes can introduce new observers such as set_slot.
                    // Any unrecognized consumer conservatively retains identity.
                    inline for (sem.fields, 0..) |field, i| {
                        if (sem.info(inst.op).reads & (@as(u8, 1) << i) != 0)
                            markEscape(map, allocations, analysis, state, @field(inst, field));
                    }
                    markOperandsEscape(map, allocations, analysis, state, function, inst.aux, switch (sem.info(inst.op).list) {
                        .none => 0,
                        .count => inst.count,
                        .b => inst.b,
                    });
                },
            }
            try ssa.applyWrites(analysis, function, state, pc, null);
        }
    }
}

fn lessU32(_: void, lhs: u32, rhs: u32) bool {
    return lhs < rhs;
}

fn fieldSlot(fields: []const u32, sid: u32) ?u32 {
    for (fields, 0..) |field, slot| if (field == sid) return @intCast(slot);
    return null;
}
pub fn findOrAddShape(a: std.mem.Allocator, program: *ir.Program, field_count: u32, keys: []const u32, choice_count: u32, open: bool) !u32 {
    for (program.shapes.items, 0..) |shape, index| {
        if (shape.field_count != field_count or shape.choice_count != choice_count or shape.open != open) continue;
        if (!std.mem.eql(u32, shape.field_keys.items, keys)) continue;
        return @intCast(index);
    }
    var shape = ir.Shape{ .field_count = field_count, .choice_count = choice_count, .open = open };
    errdefer shape.deinit(a);
    try shape.field_keys.appendSlice(a, keys);
    const id: u32 = @intCast(program.shapes.items.len);
    try program.shapes.append(a, shape);
    return id;
}

fn stableKey(a: std.mem.Allocator, analysis: *const ssa.Function, alloc_pc: u32, key: ssa.Value) !bool {
    if (key.kind == .parameter) return true;
    const key_block = switch (key.kind) {
        .instruction => analysis.graph.block_of_pc[key.pc],
        .phi => key.block,
        else => return false,
    };
    const alloc_block = analysis.graph.block_of_pc[alloc_pc];
    if (key_block == alloc_block) return true;
    // A key definition may run again only after this object is recreated.
    // Removing the allocation block must break every cycle through the key.
    const seen = try a.alloc(bool, analysis.graph.blocks.items.len);
    defer a.free(seen);
    @memset(seen, false);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(a);
    for (analysis.graph.blocks.items[key_block].succ) |succ| if (succ) |s| try pending.append(a, s);
    while (pending.pop()) |block| {
        if (block == alloc_block) continue;
        if (block == key_block) return false;
        if (seen[block]) continue;
        seen[block] = true;
        for (analysis.graph.blocks.items[block].succ) |succ| if (succ) |s| try pending.append(a, s);
    }
    return true;
}

fn assignShapes(a: std.mem.Allocator, program: *ir.Program, analysis: *const ssa.Function, allocations: []Allocation, stats: *Stats) !void {
    for (allocations) |*alloc| {
        // Unknown observers keep the shared key descriptor and generic fallback.
        // Only private objects may erase their field names.
        if (alloc.dynamic_conflict and alloc.fields.items.len == 0) continue;
        if (alloc.dynamic_seen) {
            if (alloc.dynamic_key >= analysis.values.items.len) continue;
            const key = analysis.values.items[alloc.dynamic_key];
            const stable = try stableKey(a, analysis, alloc.pc, key);
            if (!stable) alloc.dynamic_conflict = true;
        }
        std.sort.heap(u32, alloc.fields.items, {}, lessU32);
        alloc.choice = alloc.dynamic_seen and !alloc.dynamic_conflict and !alloc.escaped and !alloc.array_use and alloc.fields.items.len == 0 and alloc.dynamic_key != ssa.invalid_value;
        const open = alloc.escaped or alloc.array_use or (alloc.dynamic_seen and !alloc.choice);
        if (alloc.fields.items.len == 0 and !alloc.choice) continue;
        const keys = if (open) alloc.fields.items else &.{};
        alloc.shape_id = try findOrAddShape(a, program, @intCast(alloc.fields.items.len), keys, @intFromBool(alloc.choice), open);
        stats.shaped_tables += 1;
        stats.fixed_slots += @intCast(alloc.fields.items.len);
        stats.choice_slots += @intFromBool(alloc.choice);
        if (!open) stats.anonymous_tables += 1;
    }
}
fn rewriteFunction(a: std.mem.Allocator, program: *ir.Program, function: *ir.Function, analysis: *ssa.Function, allocations: []Allocation, map: *const std.AutoHashMapUnmanaged(ssa.ValueId, u32), stats: *Stats) !void {
    for (allocations) |alloc| if (alloc.shape_id != std.math.maxInt(u32)) {
        function.insts.items[alloc.pc].op = .new_table_shape;
        function.insts.items[alloc.pc].aux = alloc.shape_id;
    };
    const state = try a.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) a.free(state);
    for (analysis.graph.blocks.items, 0..) |block, block_index| {
        const entry = analysis.entry_states[block_index] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            var inst = &function.insts.items[pc];
            switch (inst.op) {
                .get_field, .set_field => if (allocIndex(map, analysis, state, inst.a)) |index| {
                    const alloc = &allocations[index];
                    const key = try shape_key.string(inst.aux);
                    if (alloc.shape_id != std.math.maxInt(u32)) if (fieldSlot(alloc.fields.items, key)) |slot| {
                        if (inst.op == .get_field) {
                            inst.op = .get_slot;
                            stats.field_reads += 1;
                        } else {
                            inst.op = .set_slot;
                            stats.field_writes += 1;
                        }
                        inst.aux = slot;
                    };
                },
                else => {},
            }
            switch (inst.op) {
                .get_index, .set_index, .table_set => if (allocIndex(map, analysis, state, inst.a)) |index| {
                    const alloc = &allocations[index];
                    if (alloc.shape_id != std.math.maxInt(u32) and inst.b < state.len) {
                        const key_value = analysis.canonicalValue(state[inst.b]);
                        if (shapeKeyForValue(program, function, analysis, key_value)) |key| {
                            if (fieldSlot(alloc.fields.items, key)) |slot| {
                                if (inst.op == .get_index) {
                                    inst.op = .get_slot;
                                    stats.field_reads += 1;
                                } else {
                                    inst.op = .set_slot;
                                    stats.field_writes += 1;
                                }
                                inst.aux = slot;
                            }
                        } else if (alloc.choice and key_value == alloc.dynamic_key) {
                            if (inst.op == .get_index) {
                                inst.op = .get_choice_slot;
                                stats.choice_reads += 1;
                            } else {
                                inst.op = .set_choice_slot;
                                stats.choice_writes += 1;
                            }
                            inst.aux = 0;
                        }
                    }
                },
                else => {},
            }
            try ssa.applyWrites(analysis, function, state, pc, null);
        }
    }
}
pub fn run(a: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    for (program.functions.items) |*maybe_function| if (maybe_function.*) |*function| {
        var analysis = try ssa.build(a, program, function);
        defer analysis.deinit();
        var allocations: std.ArrayList(Allocation) = .empty;
        defer {
            for (allocations.items) |*alloc| alloc.deinit(a);
            allocations.deinit(a);
        }
        var map: std.AutoHashMapUnmanaged(ssa.ValueId, u32) = .empty;
        defer map.deinit(a);
        try collectAllocations(a, program, function, &analysis, &allocations, &map);
        if (allocations.items.len == 0) continue;
        try scanUses(a, program, function, &analysis, allocations.items, &map);
        try assignShapes(a, program, &analysis, allocations.items, &stats);
        try rewriteFunction(a, program, function, &analysis, allocations.items, &map, &stats);
    };
    return stats;
}
