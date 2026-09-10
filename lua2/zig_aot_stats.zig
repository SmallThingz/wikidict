const std = @import("std");
const ir = @import("vm_ir.zig");
const aot_hint = @import("vm_aot_hint.zig");
const static_fields = @import("vm_static_field_abi.zig");

pub const Stats = struct {
    functions: u64 = 0,
    instructions: u64 = 0,
    dynamic_calls: u64 = 0,
    guarded_calls: u64 = 0,
    guarded_global_calls: u64 = 0,
    guarded_native_field_calls: u64 = 0,
    guarded_native_candidate_calls: u64 = 0,
    calls: u64 = 0,
    call_varargs: u64 = 0,
    method_calls: u64 = 0,
    method_call_varargs: u64 = 0,
    method_field_calls: u64 = 0,
    method_field_varargs: u64 = 0,

    dynamic_indexes: u64 = 0,
    get_indexes: u64 = 0,
    set_indexes: u64 = 0,
    table_sets: u64 = 0,

    string_fields: u64 = 0,
    get_fields: u64 = 0,
    set_fields: u64 = 0,

    slot_reads: u64 = 0,
    slot_writes: u64 = 0,
    choice_reads: u64 = 0,
    choice_writes: u64 = 0,
    local_calls: u64 = 0,
    scoped_calls: u64 = 0,
    direct_calls: u64 = 0,
};

pub fn collect(program: *const ir.Program) Stats {
    var stats = Stats{};
    for (program.functions.items) |maybe| if (maybe) |function| {
        stats.functions += 1;
        stats.instructions += function.insts.items.len;
        for (function.insts.items) |inst| switch (inst.op) {
            .call => {
                stats.calls += 1;
                stats.dynamic_calls += 1;
                if (aot_hint.target(inst) != null) stats.guarded_calls += 1;
                if (aot_hint.nativeGlobal(inst) != null) stats.guarded_global_calls += 1;
                if (aot_hint.nativeField(inst) != null) stats.guarded_native_field_calls += 1;
                if (aot_hint.nativeFieldCandidate(inst) != null) stats.guarded_native_candidate_calls += 1;
            },
            .call_vararg => {
                stats.call_varargs += 1;
                stats.dynamic_calls += 1;
                if (aot_hint.target(inst) != null) stats.guarded_calls += 1;
                if (aot_hint.nativeGlobal(inst) != null) stats.guarded_global_calls += 1;
                if (aot_hint.nativeField(inst) != null) stats.guarded_native_field_calls += 1;
                if (aot_hint.nativeFieldCandidate(inst) != null) stats.guarded_native_candidate_calls += 1;
            },
            .method_call => {
                stats.method_calls += 1;
                stats.dynamic_calls += 1;
                stats.dynamic_indexes += 1;
            },
            .method_call_vararg => {
                stats.method_call_varargs += 1;
                stats.dynamic_calls += 1;
                stats.dynamic_indexes += 1;
            },
            .method_call_field => {
                stats.method_field_calls += 1;
                stats.dynamic_calls += 1;
                stats.string_fields += 1;
            },
            .method_call_field_vararg => {
                stats.method_field_varargs += 1;
                stats.dynamic_calls += 1;
                stats.string_fields += 1;
            },
            .get_index => {
                stats.get_indexes += 1;
                stats.dynamic_indexes += 1;
            },
            .set_index => {
                stats.set_indexes += 1;
                stats.dynamic_indexes += 1;
            },
            .table_set => {
                stats.table_sets += 1;
                stats.dynamic_indexes += 1;
            },
            .get_field => {
                stats.get_fields += 1;
                stats.string_fields += 1;
            },
            .set_field => {
                stats.set_fields += 1;
                stats.string_fields += 1;
            },
            .get_slot => stats.slot_reads += 1,
            .set_slot => stats.slot_writes += 1,
            .get_choice_slot => stats.choice_reads += 1,
            .set_choice_slot => stats.choice_writes += 1,
            .call_local, .call_local_vararg => stats.local_calls += 1,
            .call_scoped, .call_scoped_vararg => stats.scoped_calls += 1,
            .direct_call, .direct_call_vararg => stats.direct_calls += 1,
            else => {},
        };
    };
    return stats;
}

test "AOT stats classify string fields indexes and calls" {
    const lua = @import("root.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local k=...;local f=...;local t={};t.x=1;t[k]=2;return t.x,t[k],f()");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = collect(&program);
    try std.testing.expectEqual(@as(u64, 1), stats.functions);
    try std.testing.expect(stats.instructions != 0);
    try std.testing.expectEqual(@as(u64, 2), stats.string_fields);
    try std.testing.expectEqual(@as(u64, 2), stats.dynamic_indexes);
    try std.testing.expectEqual(@as(u64, 1), stats.dynamic_calls);
}

const ssa = @import("vm_ssa.zig");

pub const ValueOrigins = struct {
    function: u64 = 0,
    captured_reg: u64 = 0,
    parameter: u64 = 0,
    phi: u64 = 0,
    get_upvalue: u64 = 0,
    call_result: u64 = 0,
    field_result: u64 = 0,
    index_result: u64 = 0,
    global: u64 = 0,
    table: u64 = 0,
    other_instruction: u64 = 0,
    unknown: u64 = 0,
};

pub const Origins = struct {
    calls: ValueOrigins = .{},
    fields: ValueOrigins = .{},
    indexes: ValueOrigins = .{},
};

const Origin = enum {
    function,
    captured_reg,
    parameter,
    phi,
    get_upvalue,
    call_result,
    field_result,
    index_result,
    global,
    table,
    other_instruction,
    unknown,
};
fn classifyOrigin(function: *const ir.Function, analysis: *const ssa.Function, state: []const ssa.ValueId, reg: u32) Origin {
    if (reg >= state.len) return .unknown;
    if (analysis.captured[reg]) return .captured_reg;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= analysis.values.items.len) return .unknown;
    const node = analysis.values.items[id];
    return switch (node.kind) {
        .parameter => .parameter,
        .phi => .phi,
        .instruction => blk: {
            if (node.pc >= function.insts.items.len) break :blk .unknown;
            break :blk switch (function.insts.items[node.pc].op) {
                .closure, .load_function => .function,
                .get_upvalue => .get_upvalue,
                .call, .call_vararg, .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg => .call_result,
                .get_field, .get_slot => .field_result,
                .get_index, .get_choice_slot => .index_result,
                .get_global, .get_global_slot => .global,
                .new_table, .new_table_shape => .table,
                else => .other_instruction,
            };
        },
        else => .unknown,
    };
}

fn noteOrigin(stats: *ValueOrigins, origin: Origin) void {
    switch (origin) {
        .function => stats.function += 1,
        .captured_reg => stats.captured_reg += 1,
        .parameter => stats.parameter += 1,
        .phi => stats.phi += 1,
        .get_upvalue => stats.get_upvalue += 1,
        .call_result => stats.call_result += 1,
        .field_result => stats.field_result += 1,
        .index_result => stats.index_result += 1,
        .global => stats.global += 1,
        .table => stats.table += 1,
        .other_instruction => stats.other_instruction += 1,
        .unknown => stats.unknown += 1,
    }
}
const global_abi = @import("vm_global_abi.zig");

pub const GlobalFieldCounts = struct {
    slots: [global_abi.names.len]u64 = [_]u64{0} ** global_abi.names.len,
    stores: [global_abi.names.len]u64 = [_]u64{0} ** global_abi.names.len,
    env_reads: u64 = 0,
    named_other: u64 = 0,
};

fn globalSlotForValue(program: *const ir.Program, function: *const ir.Function, analysis: *const ssa.Function, state: []const ssa.ValueId, reg: u32) ?u32 {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= analysis.values.items.len) return null;
    const node = analysis.values.items[id];
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const producer = function.insts.items[node.pc];
    return switch (producer.op) {
        .get_global_slot => producer.aux,
        .get_global => if (producer.aux < program.strings.items.len) global_abi.find(program.strings.items[producer.aux]) else null,
        else => null,
    };
}

pub fn collectGlobalFields(allocator: std.mem.Allocator, program: *const ir.Program) !GlobalFieldCounts {
    if (program.references_lowered) return error.OriginsRequireSsaProgram;
    var result = GlobalFieldCounts{};
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| switch (inst.op) {
            .get_global_slot => if (inst.aux == global_abi.id("_G")) {
                result.env_reads += 1;
            },
            .get_global => if (inst.aux < program.strings.items.len and std.mem.eql(u8, program.strings.items[inst.aux], "_G")) {
                result.env_reads += 1;
            },
            .set_global_slot => {
                if (inst.aux < result.stores.len) result.stores[inst.aux] += 1;
            },
            .set_global => {
                if (inst.aux < program.strings.items.len) {
                    if (global_abi.find(program.strings.items[inst.aux])) |slot| {
                        if (slot < result.stores.len) result.stores[slot] += 1;
                    }
                }
            },
            else => {},
        };
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                if (inst.op == .get_field or inst.op == .set_field) {
                    if (globalSlotForValue(program, &function, &analysis, state, inst.a)) |slot| {
                        if (slot < result.slots.len) result.slots[slot] += 1 else result.named_other += 1;
                    }
                }
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };
    return result;
}

pub fn collectOrigins(allocator: std.mem.Allocator, program: *const ir.Program) !Origins {
    if (program.references_lowered) return error.OriginsRequireSsaProgram;
    var result = Origins{};
    for (program.functions.items) |maybe| if (maybe) |function| {
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                switch (inst.op) {
                    .call, .call_vararg => noteOrigin(&result.calls, classifyOrigin(&function, &analysis, state, inst.a)),
                    .get_field, .set_field => noteOrigin(&result.fields, classifyOrigin(&function, &analysis, state, inst.a)),
                    .get_index, .set_index, .table_set => noteOrigin(&result.indexes, classifyOrigin(&function, &analysis, state, inst.a)),
                    else => {},
                }
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };
    return result;
}

fn isUnguardedCall(inst: ir.Inst) bool {
    return switch (inst.op) {
        .call => aot_hint.target(inst) == null and aot_hint.nativeGlobal(inst) == null and aot_hint.nativeField(inst) == null and aot_hint.nativeFieldCandidate(inst) == null,
        .call_vararg => aot_hint.target(inst) == null and aot_hint.nativeGlobal(inst) == null and aot_hint.nativeField(inst) == null and aot_hint.nativeFieldCandidate(inst) == null,
        else => false,
    };
}

pub fn collectUnguardedCallOrigins(allocator: std.mem.Allocator, program: *const ir.Program) !ValueOrigins {
    if (program.references_lowered) return error.OriginsRequireSsaProgram;
    var result = ValueOrigins{};
    for (program.functions.items) |maybe| if (maybe) |function| {
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                if (isUnguardedCall(inst))
                    noteOrigin(&result, classifyOrigin(&function, &analysis, state, inst.a));
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };
    return result;
}

pub fn collectUnguardedCallFieldObjectOrigins(allocator: std.mem.Allocator, program: *const ir.Program) !ValueOrigins {
    if (program.references_lowered) return error.OriginsRequireSsaProgram;
    var result = ValueOrigins{};
    for (program.functions.items) |maybe| if (maybe) |function| {
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const object_origins = try allocator.alloc(Origin, analysis.values.items.len);
        defer if (object_origins.len != 0) allocator.free(object_origins);
        @memset(object_origins, .unknown);
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                const field_origin = if (inst.op == .get_field or inst.op == .get_slot)
                    classifyOrigin(&function, &analysis, state, inst.a)
                else
                    Origin.unknown;
                try ssa.applyWrites(&analysis, &function, state, pc, null);
                if ((inst.op == .get_field or inst.op == .get_slot) and inst.dst < state.len) {
                    const value = analysis.canonicalValue(state[inst.dst]);
                    if (value != ssa.invalid_value and value < object_origins.len)
                        object_origins[value] = field_origin;
                }
            }
        }
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                if (isUnguardedCall(inst) and inst.a < state.len) {
                    const value = analysis.canonicalValue(state[inst.a]);
                    if (value != ssa.invalid_value and value < object_origins.len and object_origins[value] != .unknown)
                        noteOrigin(&result, object_origins[value]);
                }
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };
    return result;
}

pub const CallFieldNames = struct {
    allocator: std.mem.Allocator,
    counts: std.StringHashMapUnmanaged(u64) = .empty,
    anonymous_slots: u64 = 0,

    pub fn deinit(self: *CallFieldNames) void {
        self.counts.deinit(self.allocator);
    }
};

pub fn collectUnguardedCallFieldNames(allocator: std.mem.Allocator, program: *const ir.Program) !CallFieldNames {
    if (program.references_lowered) return error.OriginsRequireSsaProgram;
    var result = CallFieldNames{ .allocator = allocator };
    errdefer result.deinit();
    for (program.functions.items) |maybe| if (maybe) |function| {
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                if (isUnguardedCall(inst) and inst.a < state.len) {
                    const id = analysis.canonicalValue(state[inst.a]);
                    if (id != ssa.invalid_value and id < analysis.values.items.len) {
                        const node = analysis.values.items[id];
                        if (node.kind == .instruction and node.pc < function.insts.items.len) {
                            const producer = function.insts.items[node.pc];
                            var name: ?[]const u8 = null;
                            if (producer.op == .get_field and producer.aux < program.strings.items.len) {
                                name = program.strings.items[producer.aux];
                            } else if (producer.op == .get_slot) {
                                name = static_fields.nameForRef(producer.aux);
                                if (name == null) result.anonymous_slots += 1;
                            }
                            if (name) |field_name| {
                                const count = try result.counts.getOrPut(allocator, field_name);
                                if (!count.found_existing) count.value_ptr.* = 0;
                                count.value_ptr.* += 1;
                            }
                        }
                    }
                }
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };
    return result;
}

const sem = @import("vm_semantics.zig");
const no_parent = std.math.maxInt(u32);
const bad_parent = no_parent - 1;

pub const UpvalueOrigins = struct {
    calls: ValueOrigins = .{},
    fields: ValueOrigins = .{},
    indexes: ValueOrigins = .{},
};

fn directDefinitionOrigin(op: ir.Opcode) Origin {
    return switch (op) {
        .closure, .load_function => .function,
        .get_upvalue => .get_upvalue,
        .call, .call_vararg, .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg => .call_result,
        .get_field, .get_slot => .field_result,
        .get_index, .get_choice_slot => .index_result,
        .get_global, .get_global_slot => .global,
        .new_table, .new_table_shape => .table,
        else => .other_instruction,
    };
}

fn noteWriteOrigin(origins: []Origin, writes: []u8, flat: usize, origin: Origin) void {
    writes[flat] +|= 1;
    origins[flat] = if (writes[flat] == 1) origin else .unknown;
}
fn producerUpvalue(function: *const ir.Function, analysis: *const ssa.Function, state: []const ssa.ValueId, reg: u32) ?u32 {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= analysis.values.items.len) return null;
    const node = analysis.values.items[id];
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const inst = function.insts.items[node.pc];
    return if (inst.op == .get_upvalue) inst.a else null;
}

fn invalidateLoopWrites(function: *const ir.Function, inst: ir.Inst, base: usize, origins: []Origin, writes: []u8) void {
    switch (inst.op) {
        .numeric_for_init => if (inst.dst < function.reg_count)
            noteWriteOrigin(origins, writes, base + inst.dst, .unknown),
        .numeric_for_next => {
            if (inst.a < function.reg_count) noteWriteOrigin(origins, writes, base + inst.a, .unknown);
            if (inst.dst < function.reg_count) noteWriteOrigin(origins, writes, base + inst.dst, .unknown);
        },
        .generic_for_init, .generic_for_next => {
            if (inst.c < function.reg_count) noteWriteOrigin(origins, writes, base + inst.c, .unknown);
        },
        else => {},
    }
}

fn collectUpvalueOriginsFiltered(allocator: std.mem.Allocator, program: *const ir.Program, unguarded_calls_only: bool) !UpvalueOrigins {
    if (program.references_lowered) return error.OriginsRequireSsaProgram;
    const function_count = program.functions.items.len;
    const parents = try allocator.alloc(u32, function_count);
    defer allocator.free(parents);
    @memset(parents, no_parent);
    for (program.functions.items, 0..) |maybe, parent_usize| if (maybe) |function| {
        const parent: u32 = @intCast(parent_usize);
        for (function.insts.items) |inst| {
            if (inst.op != .closure and inst.op != .load_function) continue;
            if (inst.aux >= parents.len) continue;
            const old = parents[inst.aux];
            if (old == no_parent) parents[inst.aux] = parent else if (old != parent) parents[inst.aux] = bad_parent;
        }
    };

    const reg_offsets = try allocator.alloc(usize, function_count + 1);
    defer allocator.free(reg_offsets);
    const up_offsets = try allocator.alloc(usize, function_count + 1);
    defer allocator.free(up_offsets);
    reg_offsets[0] = 0;
    up_offsets[0] = 0;
    for (program.functions.items, 0..) |maybe, id| {
        reg_offsets[id + 1] = reg_offsets[id] + if (maybe) |function| function.reg_count else 0;
        up_offsets[id + 1] = up_offsets[id] + if (maybe) |function| function.upvalues.items.len else 0;
    }
    const local_origins = try allocator.alloc(Origin, reg_offsets[function_count]);
    defer if (local_origins.len != 0) allocator.free(local_origins);
    @memset(local_origins, .unknown);
    const writes = try allocator.alloc(u8, local_origins.len);
    defer if (writes.len != 0) allocator.free(writes);
    @memset(writes, 0);
    for (program.functions.items, 0..) |maybe, function_id| if (maybe) |function| {
        const base = reg_offsets[function_id];
        for (0..@min(@as(usize, function.param_count), function.reg_count)) |reg|
            noteWriteOrigin(local_origins, writes, base + reg, .parameter);
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                const info = sem.info(inst.op);
                if (info.defines and inst.dst < function.reg_count) {
                    const origin = if (inst.op == .move)
                        classifyOrigin(&function, &analysis, state, inst.a)
                    else
                        directDefinitionOrigin(inst.op);
                    noteWriteOrigin(local_origins, writes, base + inst.dst, origin);
                }
                if (info.results) {
                    const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
                    for (0..width) |i| if (inst.dst + i < function.reg_count)
                        noteWriteOrigin(local_origins, writes, base + inst.dst + i, directDefinitionOrigin(inst.op));
                }
                invalidateLoopWrites(&function, inst, base, local_origins, writes);
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };

    const up_origins = try allocator.alloc(Origin, up_offsets[function_count]);
    defer if (up_origins.len != 0) allocator.free(up_origins);
    @memset(up_origins, .unknown);
    var changed = true;
    while (changed) {
        changed = false;
        for (program.functions.items, 0..) |maybe, child_id| if (maybe) |child| {
            const parent = parents[child_id];
            if (parent == no_parent or parent == bad_parent or parent >= function_count) continue;
            for (child.upvalues.items, 0..) |upvalue, up_index| {
                const candidate = switch (upvalue.source) {
                    .local => blk: {
                        const parent_function = program.functions.items[parent] orelse break :blk Origin.unknown;
                        if (upvalue.index >= parent_function.reg_count) break :blk Origin.unknown;
                        break :blk local_origins[reg_offsets[parent] + upvalue.index];
                    },
                    .upvalue => blk: {
                        const parent_function = program.functions.items[parent] orelse break :blk Origin.unknown;
                        if (upvalue.index >= parent_function.upvalues.items.len) break :blk Origin.unknown;
                        break :blk up_origins[up_offsets[parent] + upvalue.index];
                    },
                };
                const slot = up_offsets[child_id] + up_index;
                if (up_origins[slot] == .unknown and candidate != .unknown) {
                    up_origins[slot] = candidate;
                    changed = true;
                }
            }
        };
    }

    var result = UpvalueOrigins{};
    for (program.functions.items, 0..) |maybe, function_id| if (maybe) |function| {
        var analysis = try ssa.build(allocator, program, &function);
        defer analysis.deinit();
        const state = try allocator.alloc(ssa.ValueId, function.reg_count);
        defer if (state.len != 0) allocator.free(state);
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                const observed_reg: ?u32 = switch (inst.op) {
                    .call, .call_vararg => inst.a,
                    .get_field, .set_field, .get_index, .set_index, .table_set => inst.a,
                    else => null,
                };
                if (observed_reg) |reg| if (producerUpvalue(&function, &analysis, state, reg)) |up_index| {
                    if (up_index < function.upvalues.items.len) {
                        const origin = up_origins[up_offsets[function_id] + up_index];
                        switch (inst.op) {
                            .call, .call_vararg => if (!unguarded_calls_only or isUnguardedCall(inst)) noteOrigin(&result.calls, origin),
                            .get_field, .set_field => noteOrigin(&result.fields, origin),
                            .get_index, .set_index, .table_set => noteOrigin(&result.indexes, origin),
                            else => unreachable,
                        }
                    }
                };
                try ssa.applyWrites(&analysis, &function, state, pc, null);
            }
        }
    };
    return result;
}

pub fn collectUpvalueOrigins(allocator: std.mem.Allocator, program: *const ir.Program) !UpvalueOrigins {
    return collectUpvalueOriginsFiltered(allocator, program, false);
}

pub fn collectUnguardedUpvalueCallOrigins(allocator: std.mem.Allocator, program: *const ir.Program) !ValueOrigins {
    return (try collectUpvalueOriginsFiltered(allocator, program, true)).calls;
}

test "unguarded call origins exclude compiler-only AOT hints" {
    const lua = @import("root.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local f=...;return f()");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const before = try collectUnguardedCallOrigins(a, &program);
    var before_total: u64 = 0;
    inline for (std.meta.fields(ValueOrigins)) |field| before_total += @field(before, field.name);
    try std.testing.expectEqual(@as(u64, 1), before_total);
    var hinted = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call) {
            try aot_hint.setNativeGlobal(inst, 1);
            hinted = true;
            break;
        };
        if (hinted) break;
    };
    try std.testing.expect(hinted);
    const after = try collectUnguardedCallOrigins(a, &program);
    var after_total: u64 = 0;
    inline for (std.meta.fields(ValueOrigins)) |field| after_total += @field(after, field.name);
    try std.testing.expectEqual(@as(u64, 0), after_total);

    const field_id = static_fields.find("gsub") orelse return error.MissingStaticField;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call) try aot_hint.setNativeFieldCandidate(inst, field_id);
    };
    const candidate_after = try collectUnguardedCallOrigins(a, &program);
    var candidate_total: u64 = 0;
    inline for (std.meta.fields(ValueOrigins)) |field| candidate_total += @field(candidate_after, field.name);
    try std.testing.expectEqual(@as(u64, 0), candidate_total);
}
