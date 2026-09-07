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
