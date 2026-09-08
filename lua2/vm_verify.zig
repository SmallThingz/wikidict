const std = @import("std");
const ir = @import("vm_ir.zig");
const cfg = @import("vm_graph.zig");
const sem = @import("vm_semantics.zig");
const static_fields = @import("vm_static_field_abi.zig");
const Bits = sem.Bits;

pub fn function(allocator: std.mem.Allocator, program: *const ir.Program, id: u32) !void {
    const f = &(program.functions.items[id] orelse return error.IncompleteProgram);
    if (f.param_count > f.reg_count) return error.BadParameterRange;
    var graph = try cfg.build(allocator, f);
    defer graph.deinit();
    if (graph.blocks.items.len == 0) return;
    const states = try allocator.alloc(Bits, graph.blocks.items.len);
    defer allocator.free(states);
    var initialized: usize = 0;
    defer for (states[0..initialized]) |*state| state.deinit(allocator);
    for (states) |*state| {
        state.* = try Bits.initEmpty(allocator, f.reg_count);
        initialized += 1;
    }
    const reached = try allocator.alloc(bool, states.len);
    defer allocator.free(reached);
    @memset(reached, false);
    const queued = try allocator.alloc(bool, states.len);
    defer allocator.free(queued);
    @memset(queued, false);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    var current = try Bits.initEmpty(allocator, f.reg_count);
    defer current.deinit(allocator);
    var edge_state = try Bits.initEmpty(allocator, f.reg_count);
    defer edge_state.deinit(allocator);
    var uses = try Bits.initEmpty(allocator, f.reg_count);
    defer uses.deinit(allocator);
    for (0..f.param_count) |r| states[0].set(r);
    reached[0] = true;
    queued[0] = true;
    try queue.append(allocator, 0);
    while (queue.pop()) |bid| {
        queued[bid] = false;
        current.unsetAll();
        current.setUnion(states[bid]);
        const block = graph.blocks.items[bid];
        for (block.start..block.end) |pc| try sem.writes(f.insts.items[pc], null, &current);
        const last = f.insts.items[block.end - 1];
        for (block.succ) |maybe_succ| if (maybe_succ) |succ| {
            edge_state.unsetAll();
            edge_state.setUnion(current);
            const taken = sem.info(last.op).target and last.aux < f.insts.items.len and graph.block_of_pc[last.aux] == succ;
            try sem.writes(last, taken, &edge_state);
            var changed = !reached[succ];
            if (!reached[succ]) {
                states[succ].setUnion(edge_state);
                reached[succ] = true;
            } else {
                edge_state.setIntersection(states[succ]);
                changed = !states[succ].eql(edge_state);
                states[succ].unsetAll();
                states[succ].setUnion(edge_state);
            }
            if (changed and !queued[succ]) {
                try queue.append(allocator, succ);
                queued[succ] = true;
            }
        };
    }
    for (graph.blocks.items, 0..) |block, bid| {
        if (!reached[bid]) continue;
        current.unsetAll();
        current.setUnion(states[bid]);
        for (block.start..block.end) |pc| {
            const inst = f.insts.items[pc];
            uses.unsetAll();
            try sem.reads(program, f, inst, &uses);
            var it = uses.iterator(.{});
            while (it.next()) |r| if (!current.isSet(r)) {
                std.debug.print("UNDEFINED function={d} pc={d} op={s} register={d}\n", .{ id, pc, @tagName(inst.op), r });
                return error.UndefinedRegister;
            };
            try sem.writes(inst, null, &current);
            switch (inst.op) {
                .get_global_slot, .set_global_slot => {
                    const count = if (program.global_shape) |sid| program.shapes.items[sid].field_count else @import("vm_global_abi.zig").count;
                    if (inst.aux >= count) return error.BadGlobalSlot;
                },
                .get_slot, .set_slot => {
                    if (inst.aux & static_fields.marker != 0 and static_fields.nameForRef(inst.aux) == null)
                        return error.BadStaticField;
                },
                .branch_compare => {
                    const op = try @import("vm_semantics.zig").comparisonOpcode(inst.count);
                    if (!sem.isComparison(op)) return error.BadComparison;
                },

                .load_number, .load_string, .get_global, .set_global, .get_field, .set_field => if (inst.aux >= program.strings.items.len) {
                    return error.BadStringReference;
                },
                .method_call_field, .method_call_field_vararg => if (inst.a >= program.strings.items.len) {
                    return error.BadStringReference;
                },
                .load_const => if (inst.aux >= program.constants.items.len) {
                    return error.BadConstantReference;
                },
                .get_upvalue, .set_upvalue => if (inst.a >= f.upvalues.items.len) {
                    return error.BadUpvalue;
                },
                .new_table_shape => if (inst.aux >= program.shapes.items.len) {
                    return error.BadShape;
                },
                .init_module => if (inst.aux >= program.module_roots.items.len) {
                    return error.BadModuleId;
                },
                .load_function => {
                    if (inst.aux >= program.functions.items.len) return error.BadFunctionReference;
                    if (program.function_modules.items.len != program.functions.items.len or id >= program.function_modules.items.len) return error.NotLinkedProgram;
                    const module_id = program.function_modules.items[id];
                    if (module_id >= program.module_roots.items.len or program.module_roots.items[module_id] != id) return error.StaticFunctionOutsideModuleRoot;
                    const child = program.functions.items[inst.aux] orelse return error.IncompleteProgram;
                    for (child.upvalues.items) |up| {
                        if (up.source != .local or up.index >= f.reg_count) return error.BadStaticEnvironment;
                    }
                },
                .register_function => if (inst.aux >= program.functions.items.len) {
                    return error.BadFunctionReference;
                },
                .call_local, .call_local_vararg => {
                    if (inst.a >= program.functions.items.len) return error.BadFunctionReference;
                    if (program.functions.items[inst.a].?.upvalues.items.len != 0) return error.MissingCallEnvironment;
                },
                .direct_call, .direct_call_vararg, .call_scoped, .call_scoped_vararg => if (inst.a >= program.functions.items.len) {
                    return error.BadFunctionReference;
                },
                else => {},
            }
        }
    }
}

pub fn run(allocator: std.mem.Allocator, program: *const ir.Program) !void {
    if (program.global_shape) |id| {
        if (id >= program.shapes.items.len or program.shapes.items[id].field_count < @import("vm_global_abi.zig").count) return error.BadGlobalLayout;
    }
    if (program.root_function >= program.functions.items.len) return error.BadRootFunction;
    if (program.module_roots.items.len != 0 and program.function_modules.items.len != program.functions.items.len) return error.BadModuleMap;
    for (program.module_roots.items) |root| if (root >= program.functions.items.len) {
        return error.BadRootFunction;
    };
    for (program.function_modules.items) |module| if (module >= program.module_roots.items.len) {
        return error.BadModuleId;
    };
    for (program.constants.items) |node| switch (node) {
        .number, .string => |sid| if (sid >= program.strings.items.len) {
            return error.BadStringReference;
        },
        .table => |table| if (table.first > program.const_entries.items.len or table.count > program.const_entries.items.len - table.first) {
            return error.BadConstantReference;
        },
        else => {},
    };
    for (program.const_entries.items) |entry| {
        if ((entry.key != ir.implicit_list_key and entry.key >= program.constants.items.len) or entry.value >= program.constants.items.len) return error.BadConstantReference;
    }
    for (program.shapes.items) |shape| {
        if (shape.field_keys.items.len != 0 and shape.field_keys.items.len != shape.field_count) return error.BadShape;
        for (shape.field_keys.items) |sid| if (sid >= program.strings.items.len) {
            return error.BadStringReference;
        };
    }
    for (program.functions.items, 0..) |_, id| try function(allocator, program, @intCast(id));
}

test "verifier accepts loop edge definitions" {
    const lua = @import("root.zig");
    var chunk = try lua.parse(std.testing.allocator, "local s=0; for i=1,3 do s=s+i end; return s");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    try run(std.testing.allocator, &p);
}

test "verifier rejects unknown static field refs" {
    const lua = @import("root.zig");
    var chunk = try lua.parse(std.testing.allocator, "local t=...;return t.insert");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    var changed = false;
    for (p.functions.items) |*maybe| if (maybe.*) |*f| {
        for (f.insts.items) |*inst| if (inst.op == .get_field) {
            inst.op = .get_slot;
            inst.aux = static_fields.marker | 999;
            changed = true;
        };
    };
    try std.testing.expect(changed);
    try std.testing.expectError(error.BadStaticField, run(std.testing.allocator, &p));
}
