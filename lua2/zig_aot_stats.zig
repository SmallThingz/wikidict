const std = @import("std");
const ir = @import("vm_ir.zig");

pub const Stats = struct {
    dynamic_calls: u64 = 0,
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
        for (function.insts.items) |inst| switch (inst.op) {
            .call => { stats.calls += 1; stats.dynamic_calls += 1; },
            .call_vararg => { stats.call_varargs += 1; stats.dynamic_calls += 1; },
            .method_call => { stats.method_calls += 1; stats.dynamic_calls += 1; stats.dynamic_indexes += 1; },
            .method_call_vararg => { stats.method_call_varargs += 1; stats.dynamic_calls += 1; stats.dynamic_indexes += 1; },
            .method_call_field => { stats.method_field_calls += 1; stats.dynamic_calls += 1; stats.string_fields += 1; },
            .method_call_field_vararg => { stats.method_field_varargs += 1; stats.dynamic_calls += 1; stats.string_fields += 1; },
            .get_index => { stats.get_indexes += 1; stats.dynamic_indexes += 1; },
            .set_index => { stats.set_indexes += 1; stats.dynamic_indexes += 1; },
            .table_set => { stats.table_sets += 1; stats.dynamic_indexes += 1; },
            .get_field => { stats.get_fields += 1; stats.string_fields += 1; },
            .set_field => { stats.set_fields += 1; stats.string_fields += 1; },
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
    try std.testing.expectEqual(@as(u64, 2), stats.string_fields);
    try std.testing.expectEqual(@as(u64, 2), stats.dynamic_indexes);
    try std.testing.expectEqual(@as(u64, 1), stats.dynamic_calls);
}

const ssa = @import("vm_ssa.zig");

pub const ValueOrigins = struct {
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
    fields: ValueOrigins = .{},
    indexes: ValueOrigins = .{},
};

const Origin = enum {
    captured_reg, parameter, phi, get_upvalue, call_result, field_result,
    index_result, global, table, other_instruction, unknown,
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
                .get_upvalue => .get_upvalue,
                .call, .call_vararg, .call_local, .call_local_vararg,
                .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg => .call_result,
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
