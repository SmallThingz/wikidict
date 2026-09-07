const sem = @import("vm_semantics.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const cg = @import("vm_callgraph.zig");
const lua = @import("root.zig");
const rt = @import("vm_runtime.zig");
const exec = @import("vm_exec.zig");

pub const Stats = struct {
    inlined: u32 = 0,
    blocked_vararg: u32 = 0,
    blocked_nested_closure: u32 = 0,
    blocked_ret_var: u32 = 0,
    blocked_multi_result: u32 = 0,
};

const Patch = struct { index: usize, target: u32 };
fn fixedCall(op: ir.Opcode) ir.Opcode {
    return switch (op) {
        .call_vararg => .call,
        .method_call_vararg => .method_call,
        .method_call_field_vararg => .method_call_field,
        .direct_call_vararg => .direct_call,
        else => unreachable,
    };
}

fn isJump(op: ir.Opcode) bool {
    return switch (op) {
        .jump, .jump_if_false, .branch_compare, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => true,
        else => false,
    };
}

fn hasNestedClosure(function: *const ir.Function) bool {
    for (function.insts.items) |inst| if (inst.op == .closure) return true;
    return false;
}

fn retVarsSupported(function: *const ir.Function) bool {
    for (function.insts.items, 0..) |inst, pc| {
        if (inst.op != .ret_var) continue;
        if (pc == 0) return false;
        const producer = function.insts.items[pc - 1];
        if (producer.dst != inst.a or producer.count != ir.multi_count) return false;
        switch (producer.op) {
            .call, .call_vararg, .method_call, .method_call_vararg, .method_call_field, .method_call_field_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg, .direct_call, .direct_call_vararg => {},
            else => return false,
        }
    }
    return true;
}

const NestedMap = std.AutoHashMapUnmanaged(u32, u32);

fn cloneNestedChildren(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    callee: *const ir.Function,
    reg_base: u32,
    nested: *NestedMap,
    captures: *std.ArrayList(u32),
) !void {
    for (callee.insts.items) |inst| {
        const target = sem.captureTarget(inst) orelse continue;
        if (nested.contains(target)) continue;
        if (target >= program.functions.items.len) return error.BadFunctionReference;
        const child = program.functions.items[target] orelse return error.BadFunctionReference;
        var clone = ir.Function{
            .source_start = child.source_start,
            .source_end = child.source_end,
            .param_count = child.param_count,
            .is_vararg = child.is_vararg,
            .reg_count = child.reg_count,
        };
        var clone_owned = true;
        errdefer if (clone_owned) clone.deinit(allocator);
        for (child.upvalues.items) |upvalue| {
            if (upvalue.source == .local and std.mem.indexOfScalar(u32, captures.items, upvalue.index) == null)
                try captures.append(allocator, upvalue.index);

            const translated: ir.Upvalue = switch (upvalue.source) {
                .local => .{ .source = .local, .index = reg_base + upvalue.index },
                .upvalue => blk: {
                    if (upvalue.index >= callee.upvalues.items.len) return error.BadUpvalue;
                    const parent = callee.upvalues.items[upvalue.index];
                    break :blk switch (parent.source) {
                        .local => .{ .source = .local, .index = parent.index },
                        .upvalue => .{ .source = .upvalue, .index = parent.index },
                    };
                },
            };
            try clone.upvalues.append(allocator, translated);
        }
        try clone.operands.appendSlice(allocator, child.operands.items);
        try clone.insts.appendSlice(allocator, child.insts.items);
        if (program.functions.items.len >= std.math.maxInt(u32)) return error.TooManyFunctions;
        const new_id: u32 = @intCast(program.functions.items.len);
        if (program.module_roots.items.len != 0) {
            if (program.function_modules.items.len != program.functions.items.len) return error.BadModuleMap;
            try program.function_modules.append(allocator, program.function_modules.items[target]);
        }
        try program.functions.append(allocator, clone);

        clone_owned = false;
        try nested.put(allocator, target, new_id);
    }
}

fn appendMappedOperands(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    callee: *const ir.Function,
    at: u32,
    count: u32,
    reg_base: u32,
) !u32 {
    if (@as(usize, at) + count > callee.operands.items.len) return error.BadOperandRange;
    if (caller.operands.items.len + count > std.math.maxInt(u32)) return error.TooManyOperands;
    const out_at: u32 = @intCast(caller.operands.items.len);
    for (callee.operands.items[at .. at + count]) |reg| {
        try caller.operands.append(allocator, reg_base + reg);
    }
    return out_at;
}

fn remapClone(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    callee: *const ir.Function,
    inst: ir.Inst,
    reg_base: u32,
    nested: *const NestedMap,
) !ir.Inst {
    var out = inst;
    switch (inst.op) {
        .load_nil, .load_bool, .load_number, .load_string, .load_const, .get_global, .get_global_slot, .new_table, .new_table_shape, .load_function => out.dst = reg_base + inst.dst,
        .set_global_slot, .set_global, .detach_cell => out.a = reg_base + inst.a,
        .get_upvalue => {
            if (inst.a >= callee.upvalues.items.len) return error.BadUpvalue;
            const upvalue = callee.upvalues.items[inst.a];
            out = switch (upvalue.source) {
                .local => .{ .op = .move, .dst = reg_base + inst.dst, .a = upvalue.index },
                .upvalue => .{ .op = .get_upvalue, .dst = reg_base + inst.dst, .a = upvalue.index },
            };
        },
        .set_upvalue => {
            if (inst.a >= callee.upvalues.items.len) return error.BadUpvalue;
            const upvalue = callee.upvalues.items[inst.a];
            out = switch (upvalue.source) {
                .local => .{ .op = .move, .dst = upvalue.index, .a = reg_base + inst.b },
                .upvalue => .{ .op = .set_upvalue, .a = upvalue.index, .b = reg_base + inst.b },
            };
        },
        .move => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
        },
        .vararg => return error.UnsupportedVararg,
        .table_set, .set_index, .set_choice_slot => {
            out.a = reg_base + inst.a;
            out.b = reg_base + inst.b;
            out.c = reg_base + inst.c;
        },
        .table_append, .table_append_var => {
            out.a = reg_base + inst.a;
            out.b = reg_base + inst.b;
        },
        .get_index, .get_choice_slot => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
            out.b = reg_base + inst.b;
        },
        .get_field, .get_slot => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
        },
        .set_field, .set_slot => {
            out.a = reg_base + inst.a;
            out.c = reg_base + inst.c;
        },
        .init_module => {},
        .check_table_key => out.a = reg_base + inst.a,
        .register_function => out.a = reg_base + inst.a,
        .call_scoped, .call_scoped_vararg => {
            out.dst = reg_base + inst.dst;
            out.a = nested.get(inst.a) orelse return error.BadNestedMap;
            if (inst.op == .call_scoped_vararg) out.c = reg_base + inst.c;
            out.aux = try appendMappedOperands(allocator, caller, callee, inst.aux, inst.b, reg_base);
        },
        .call_local, .call_local_vararg, .direct_call, .direct_call_vararg, .method_call_field, .method_call_field_vararg => {
            out.dst = reg_base + inst.dst;
            if ((inst.op == .direct_call_vararg or inst.op == .call_scoped_vararg or inst.op == .call_local_vararg) or inst.op == .method_call_field_vararg) out.c = reg_base + inst.c;
            out.aux = try appendMappedOperands(allocator, caller, callee, inst.aux, inst.b, reg_base);
        },
        .closure => {
            out.dst = reg_base + inst.dst;
            out.aux = nested.get(inst.aux) orelse return error.BadNestedMap;
        },
        .neg, .not_, .len, .neg_number, .len_string => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
        },
        .add, .sub, .mul, .div, .mod, .pow, .eq, .ne, .lt, .le, .gt, .ge, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
            out.b = reg_base + inst.b;
        },
        .concat => {
            out.dst = reg_base + inst.dst;
            out.aux = try appendMappedOperands(allocator, caller, callee, inst.aux, inst.count, reg_base);
        },
        .jump => {},
        .jump_if_false => out.a = reg_base + inst.a,
        .branch_compare => {
            out.a = reg_base + inst.a;
            out.b = reg_base + inst.b;
        },
        .call, .call_vararg => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
            if (inst.op == .call_vararg) out.c = reg_base + inst.c;
            out.aux = try appendMappedOperands(allocator, caller, callee, inst.aux, inst.b, reg_base);
        },
        .method_call, .method_call_vararg => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
            if (inst.op == .method_call_vararg) out.c = reg_base + inst.c;
            out.aux = try appendMappedOperands(allocator, caller, callee, inst.aux, inst.b, reg_base);
        },
        .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => {
            out.dst = reg_base + inst.dst;
            out.a = reg_base + inst.a;
            out.b = reg_base + inst.b;
            out.c = reg_base + inst.c;
        },
        .ret, .ret_var => unreachable,
    }
    return out;
}

fn isMultiConsumer(inst: ir.Inst, base: u32) bool {
    return switch (inst.op) {
        .ret_var => inst.a == base,
        .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => inst.c == base,
        .table_append_var => inst.b == base,
        else => false,
    };
}

fn hasJumpTarget(function: *const ir.Function, target: u32) bool {
    for (function.insts.items) |inst| if (isJump(inst.op) and inst.aux == target) return true;
    return false;
}

fn hasJumpTargetOutside(function: *const ir.Function, target: u32, skip_lo: u32, skip_hi: u32) bool {
    for (function.insts.items, 0..) |inst, pc| {
        if (!isJump(inst.op) or inst.aux != target) continue;
        if (pc >= skip_lo and pc < skip_hi) continue;
        return true;
    }
    return false;
}

fn findMultiConsumer(function: *const ir.Function, call_pc: u32, base: u32) ?u32 {
    var pc = call_pc + 1;
    while (pc < function.insts.items.len) {
        const inst = function.insts.items[pc];
        if (inst.op == .jump and inst.aux == pc + 1) {
            if (hasJumpTargetOutside(function, pc, call_pc + 1, pc)) return null;
            pc += 1;
            continue;
        }
        if (!isMultiConsumer(inst, base)) return null;
        if (hasJumpTargetOutside(function, pc, call_pc + 1, pc)) return null;
        return pc;
    }
    return null;
}

const CallPlan = struct {
    call: ir.Inst,
    producer_pc: ?u32 = null,
    producer: ?ir.Inst = null,
};

fn isMultiTailConsumer(inst: ir.Inst, base: u32) bool {
    return switch (inst.op) {
        .ret_var => inst.a == base,
        .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => inst.c == base,
        .table_append_var => inst.b == base,
        else => false,
    };
}

fn multiBaseUsedAfter(function: *const ir.Function, pc: u32, base: u32) bool {
    var i: usize = pc + 1;
    while (i < function.insts.items.len) : (i += 1) {
        if (isMultiTailConsumer(function.insts.items[i], base)) return true;
    }
    return false;
}

fn callSiteSupported(caller: *const ir.Function, callee: *const ir.Function, pc: u32) bool {
    if (pc >= caller.insts.items.len) return false;
    const call = caller.insts.items[pc];
    if (call.op == .call) return true;
    if (call.op != .call_vararg or callee.is_vararg) return false;
    const needed = callee.param_count -| call.b;
    if (needed <= 1) return true;
    if (pc == 0 or multiBaseUsedAfter(caller, pc, call.c)) return false;
    const producer = caller.insts.items[pc - 1];
    if (producer.dst != call.c or producer.count != ir.multi_count) return false;
    switch (producer.op) {
        .call, .call_vararg, .method_call, .method_call_vararg, .vararg => {},
        else => return false,
    }
    const output_slots: u32 = if (call.count == 0 or call.count == ir.multi_count) 1 else call.count;
    return call.dst == call.c + 1 and needed - 1 <= output_slots;
}

fn planCall(allocator: std.mem.Allocator, caller: *ir.Function, callee: *const ir.Function, pc: u32) !CallPlan {
    var call = caller.insts.items[pc];
    if (call.op == .call) return .{ .call = call };
    if (!callSiteSupported(caller, callee, pc)) return error.UnsupportedCall;
    const needed = callee.param_count -| call.b;
    if (@as(usize, call.aux) + call.b > caller.operands.items.len) return error.BadOperandRange;
    const fixed = try allocator.dupe(u32, caller.operands.items[call.aux .. call.aux + call.b]);
    defer if (fixed.len != 0) allocator.free(fixed);
    const at: u32 = @intCast(caller.operands.items.len);
    try caller.operands.appendSlice(allocator, fixed);
    var i: u32 = 0;
    while (i < needed) : (i += 1) try caller.operands.append(allocator, call.c + i);
    call.op = .call;
    call.aux = at;
    call.b += needed;
    call.c = 0;
    if (needed <= 1) return .{ .call = call };
    var producer = caller.insts.items[pc - 1];
    producer.count = needed;
    return .{ .call = call, .producer_pc = pc - 1, .producer = producer };
}

fn appendMixedOperands(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    fixed: []const u32,
    mapped: []const u32,
    reg_base: u32,
) !u32 {
    if (caller.operands.items.len + fixed.len + mapped.len > std.math.maxInt(u32)) return error.TooManyOperands;
    const fixed_copy = try allocator.dupe(u32, fixed);
    defer if (fixed_copy.len != 0) allocator.free(fixed_copy);
    const at: u32 = @intCast(caller.operands.items.len);
    try caller.operands.appendSlice(allocator, fixed_copy);
    for (mapped) |reg| try caller.operands.append(allocator, reg_base + reg);
    return at;
}

fn emitFixedMultiConsumer(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    consumer: ir.Inst,
    returned: []const u32,
    reg_base: u32,
    snippet: *std.ArrayList(ir.Inst),
) !bool {
    switch (consumer.op) {
        .ret_var => {
            if (@as(usize, consumer.aux) + consumer.count > caller.operands.items.len) return error.BadOperandRange;
            const fixed = caller.operands.items[consumer.aux .. consumer.aux + consumer.count];
            const at = try appendMixedOperands(allocator, caller, fixed, returned, reg_base);
            const count = std.math.cast(u32, fixed.len + returned.len) orelse return error.TooManyOperands;
            try snippet.append(allocator, .{ .op = .ret, .aux = at, .count = count });
            return true;
        },
        .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => {
            if (@as(usize, consumer.aux) + consumer.b > caller.operands.items.len) return error.BadOperandRange;
            const fixed = caller.operands.items[consumer.aux .. consumer.aux + consumer.b];
            const at = try appendMixedOperands(allocator, caller, fixed, returned, reg_base);
            var out = consumer;
            out.op = fixedCall(consumer.op);
            out.aux = at;
            out.b = std.math.cast(u32, fixed.len + returned.len) orelse return error.TooManyOperands;
            out.c = 0;
            try snippet.append(allocator, out);
            return false;
        },
        .table_append_var => {
            for (returned) |reg| try snippet.append(allocator, .{ .op = .table_append, .a = consumer.a, .b = reg_base + reg });
            return false;
        },
        else => return error.UnsupportedMultiConsumer,
    }
}

fn emitDynamicMultiConsumer(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    consumer: ir.Inst,
    prefix: []const u32,
    tail_base: u32,
    reg_base: u32,
    snippet: *std.ArrayList(ir.Inst),
) !bool {
    switch (consumer.op) {
        .ret_var => {
            if (@as(usize, consumer.aux) + consumer.count > caller.operands.items.len) return error.BadOperandRange;
            const fixed = caller.operands.items[consumer.aux .. consumer.aux + consumer.count];
            const at = try appendMixedOperands(allocator, caller, fixed, prefix, reg_base);
            const count = std.math.cast(u32, fixed.len + prefix.len) orelse return error.TooManyOperands;
            try snippet.append(allocator, .{ .op = .ret_var, .a = reg_base + tail_base, .aux = at, .count = count });
            return true;
        },
        .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => {
            if (@as(usize, consumer.aux) + consumer.b > caller.operands.items.len) return error.BadOperandRange;
            const fixed = caller.operands.items[consumer.aux .. consumer.aux + consumer.b];
            const at = try appendMixedOperands(allocator, caller, fixed, prefix, reg_base);
            var out = consumer;
            out.aux = at;
            out.b = std.math.cast(u32, fixed.len + prefix.len) orelse return error.TooManyOperands;
            out.c = reg_base + tail_base;
            try snippet.append(allocator, out);
            return false;
        },
        .table_append_var => {
            for (prefix) |reg| try snippet.append(allocator, .{ .op = .table_append, .a = consumer.a, .b = reg_base + reg });
            var out = consumer;
            out.b = reg_base + tail_base;
            try snippet.append(allocator, out);
            return false;
        },
        else => return error.UnsupportedMultiConsumer,
    }
}

fn varArgsSupported(function: *const ir.Function) bool {
    if (!function.is_vararg) return true;
    for (function.insts.items, 0..) |inst, pc| {
        if (inst.op != .vararg or inst.count != ir.multi_count) continue;
        if (pc + 1 >= function.insts.items.len) return false;
        const next = function.insts.items[pc + 1];
        const consumes = switch (next.op) {
            .table_append_var => next.b == inst.dst,
            .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => next.c == inst.dst,
            else => false,
        };
        if (!consumes) return false;
        for (function.insts.items) |jump| if (isJump(jump.op) and jump.aux == pc + 1) return false;
    }
    return true;
}

fn varargConsumesNext(vararg_inst: ir.Inst, consumer: ir.Inst) bool {
    if (vararg_inst.op != .vararg or vararg_inst.count != ir.multi_count) return false;
    return switch (consumer.op) {
        .table_append_var => consumer.b == vararg_inst.dst,
        .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => consumer.c == vararg_inst.dst,
        else => false,
    };
}

fn appendMappedAndRawOperands(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    callee: *const ir.Function,
    at: u32,
    count: u32,
    reg_base: u32,
    raw: []const u32,
) !u32 {
    if (@as(usize, at) + count > callee.operands.items.len) return error.BadOperandRange;
    if (caller.operands.items.len + count + raw.len > std.math.maxInt(u32)) return error.TooManyOperands;
    const out_at: u32 = @intCast(caller.operands.items.len);
    for (callee.operands.items[at .. at + count]) |reg| try caller.operands.append(allocator, reg_base + reg);
    try caller.operands.appendSlice(allocator, raw);
    return out_at;
}

fn emitStaticVararg(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    callee: *const ir.Function,
    inst: ir.Inst,
    next: ?ir.Inst,
    call_args: []const u32,
    reg_base: u32,
    snippet: *std.ArrayList(ir.Inst),
) !bool {
    const extra_start: usize = @min(@as(usize, callee.param_count), call_args.len);
    const extra = call_args[extra_start..];
    if (inst.count != ir.multi_count) {
        var i: u32 = 0;
        while (i < inst.count) : (i += 1) {
            if (i < extra.len) try snippet.append(allocator, .{ .op = .move, .dst = reg_base + inst.dst + i, .a = extra[i] }) else try snippet.append(allocator, .{ .op = .load_nil, .dst = reg_base + inst.dst + i });
        }
        return false;
    }

    const consumer = next orelse return error.UnsupportedVararg;
    switch (consumer.op) {
        .table_append_var => {
            if (consumer.b != inst.dst) return error.UnsupportedVararg;
            for (extra) |reg| try snippet.append(allocator, .{ .op = .table_append, .a = reg_base + consumer.a, .b = reg });
        },
        .call_vararg, .method_call_vararg, .method_call_field_vararg, .direct_call_vararg => {
            if (consumer.c != inst.dst) return error.UnsupportedVararg;
            const at = try appendMappedAndRawOperands(allocator, caller, callee, consumer.aux, consumer.b, reg_base, extra);
            var out = consumer;
            out.op = fixedCall(consumer.op);
            out.dst = reg_base + consumer.dst;
            if (consumer.op == .call_vararg or consumer.op == .method_call_vararg)
                out.a = reg_base + consumer.a;
            out.aux = at;
            out.b = std.math.cast(u32, @as(usize, consumer.b) + extra.len) orelse return error.TooManyOperands;
            out.c = 0;
            try snippet.append(allocator, out);
        },
        else => return error.UnsupportedVararg,
    }
    return true;
}

fn buildMultiSnippet(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    callee: *const ir.Function,
    call: ir.Inst,
    consumer: ir.Inst,
    reg_base: u32,
    nested: *const NestedMap,
    captures: []const u32,
) !std.ArrayList(ir.Inst) {
    var snippet: std.ArrayList(ir.Inst) = .empty;
    errdefer snippet.deinit(allocator);
    var patches: std.ArrayList(Patch) = .empty;
    defer patches.deinit(allocator);
    var continuation_jumps: std.ArrayList(usize) = .empty;
    defer continuation_jumps.deinit(allocator);
    const map = try allocator.alloc(u32, callee.insts.items.len + 1);
    defer allocator.free(map);

    if (call.op != .call) return error.UnsupportedVarargCall;
    if (@as(usize, call.aux) + call.b > caller.operands.items.len) return error.BadOperandRange;
    const args_view = caller.operands.items[call.aux .. call.aux + call.b];
    const args = try allocator.dupe(u32, args_view);
    defer if (args.len != 0) allocator.free(args);
    for (captures) |reg| try snippet.append(allocator, .{ .op = .detach_cell, .a = reg_base + reg });
    var param: u32 = 0;
    while (param < callee.param_count) : (param += 1) {
        if (param < args.len) try snippet.append(allocator, .{ .op = .move, .dst = reg_base + param, .a = args[param] }) else try snippet.append(allocator, .{ .op = .load_nil, .dst = reg_base + param });
    }

    for (callee.insts.items, 0..) |inst, pc| {
        map[pc] = @intCast(snippet.items.len);
        if (pc > 0 and varargConsumesNext(callee.insts.items[pc - 1], inst)) continue;
        if (inst.op == .vararg) {
            const next: ?ir.Inst = if (pc + 1 < callee.insts.items.len) callee.insts.items[pc + 1] else null;
            _ = try emitStaticVararg(allocator, caller, callee, inst, next, args, reg_base, &snippet);
            continue;
        }
        if (inst.op == .ret) {
            if (@as(usize, inst.aux) + inst.count > callee.operands.items.len) return error.BadOperandRange;
            const returned = callee.operands.items[inst.aux .. inst.aux + inst.count];
            const terminal = try emitFixedMultiConsumer(allocator, caller, consumer, returned, reg_base, &snippet);
            if (!terminal) {
                const jump_index = snippet.items.len;
                try snippet.append(allocator, .{ .op = .jump });
                try continuation_jumps.append(allocator, jump_index);
            }
            continue;
        }
        if (inst.op == .ret_var) {
            if (pc == 0) return error.UnsupportedRetVar;
            const producer = callee.insts.items[pc - 1];
            if (producer.dst != inst.a or producer.count != ir.multi_count) return error.UnsupportedRetVar;
            if (@as(usize, inst.aux) + inst.count > callee.operands.items.len) return error.BadOperandRange;
            const prefix = callee.operands.items[inst.aux .. inst.aux + inst.count];
            const terminal = try emitDynamicMultiConsumer(allocator, caller, consumer, prefix, inst.a, reg_base, &snippet);
            if (!terminal) {
                const jump_index = snippet.items.len;
                try snippet.append(allocator, .{ .op = .jump });
                try continuation_jumps.append(allocator, jump_index);
            }
            continue;
        }
        var clone = try remapClone(allocator, caller, callee, inst, reg_base, nested);
        if (isJump(inst.op)) {
            const index = snippet.items.len;
            try patches.append(allocator, .{ .index = index, .target = inst.aux });
            clone.aux = 0;
        }
        try snippet.append(allocator, clone);
    }
    map[callee.insts.items.len] = @intCast(snippet.items.len);
    for (patches.items) |patch| {
        if (patch.target > callee.insts.items.len) return error.BadJumpTarget;
        snippet.items[patch.index].aux = map[patch.target];
    }
    const end: u32 = @intCast(snippet.items.len);
    for (continuation_jumps.items) |index| snippet.items[index].aux = end;
    return snippet;
}

fn buildSnippet(
    allocator: std.mem.Allocator,
    caller: *ir.Function,
    callee: *const ir.Function,
    call: ir.Inst,
    reg_base: u32,
    nested: *const NestedMap,
    captures: []const u32,
) !std.ArrayList(ir.Inst) {
    var snippet: std.ArrayList(ir.Inst) = .empty;
    errdefer snippet.deinit(allocator);
    var patches: std.ArrayList(Patch) = .empty;
    defer patches.deinit(allocator);
    var return_jumps: std.ArrayList(usize) = .empty;
    defer return_jumps.deinit(allocator);
    const map = try allocator.alloc(u32, callee.insts.items.len + 1);
    defer allocator.free(map);
    if (@as(usize, call.aux) + call.b > caller.operands.items.len) return error.BadOperandRange;
    const args_view = caller.operands.items[call.aux .. call.aux + call.b];
    const args = try allocator.dupe(u32, args_view);
    defer if (args.len != 0) allocator.free(args);
    for (captures) |reg| try snippet.append(allocator, .{ .op = .detach_cell, .a = reg_base + reg });
    var param: u32 = 0;
    while (param < callee.param_count) : (param += 1) {
        if (param < args.len) {
            try snippet.append(allocator, .{ .op = .move, .dst = reg_base + param, .a = args[param] });
        } else {
            try snippet.append(allocator, .{ .op = .load_nil, .dst = reg_base + param });
        }
    }

    for (callee.insts.items, 0..) |inst, pc| {
        map[pc] = @intCast(snippet.items.len);
        if (pc > 0 and varargConsumesNext(callee.insts.items[pc - 1], inst)) continue;
        if (inst.op == .vararg) {
            const next: ?ir.Inst = if (pc + 1 < callee.insts.items.len) callee.insts.items[pc + 1] else null;
            _ = try emitStaticVararg(allocator, caller, callee, inst, next, args, reg_base, &snippet);
            continue;
        }
        if (inst.op == .ret) {
            if (@as(usize, inst.aux) + inst.count > callee.operands.items.len) return error.BadOperandRange;
            const returned = callee.operands.items[inst.aux .. inst.aux + inst.count];
            var i: u32 = 0;
            while (i < call.count) : (i += 1) {
                if (i < returned.len) {
                    try snippet.append(allocator, .{ .op = .move, .dst = call.dst + i, .a = reg_base + returned[i] });
                } else {
                    try snippet.append(allocator, .{ .op = .load_nil, .dst = call.dst + i });
                }
            }
            const jump_index = snippet.items.len;
            try snippet.append(allocator, .{ .op = .jump });
            try return_jumps.append(allocator, jump_index);
            continue;
        }
        if (inst.op == .ret_var) {
            if (pc == 0) return error.UnsupportedRetVar;
            const producer = callee.insts.items[pc - 1];
            if (producer.dst != inst.a or producer.count != ir.multi_count) return error.UnsupportedRetVar;
            if (@as(usize, inst.aux) + inst.count > callee.operands.items.len) return error.BadOperandRange;
            const prefix = callee.operands.items[inst.aux .. inst.aux + inst.count];
            const prefix_take: u32 = @min(inst.count, call.count);
            if (pc >= 2 and varargConsumesNext(callee.insts.items[pc - 2], producer)) {
                if (snippet.items.len == 0) return error.UnsupportedRetVar;
                const remaining = call.count - prefix_take;
                const emitted = &snippet.items[snippet.items.len - 1];
                switch (emitted.op) {
                    .call, .method_call, .method_call_field, .direct_call => {},
                    else => return error.UnsupportedRetVar,
                }
                emitted.count = remaining;
                if (remaining != 0) emitted.dst = call.dst + prefix_take;
            }
            var i: u32 = 0;
            while (i < prefix_take) : (i += 1) {
                try snippet.append(allocator, .{ .op = .move, .dst = call.dst + i, .a = reg_base + prefix[i] });
            }
            const jump_index = snippet.items.len;
            try snippet.append(allocator, .{ .op = .jump });
            try return_jumps.append(allocator, jump_index);
            continue;
        }
        var clone = try remapClone(allocator, caller, callee, inst, reg_base, nested);
        if (pc + 1 < callee.insts.items.len) {
            const next = callee.insts.items[pc + 1];
            if (next.op == .ret_var and next.a == inst.dst) {
                if (inst.count != ir.multi_count) return error.UnsupportedRetVar;
                const prefix_take: u32 = @min(next.count, call.count);
                const remaining = call.count - prefix_take;
                clone.count = remaining;
                if (remaining != 0) clone.dst = call.dst + prefix_take;
            }
        }
        if (isJump(inst.op)) {
            const index = snippet.items.len;
            try patches.append(allocator, .{ .index = index, .target = inst.aux });
            clone.aux = 0;
        }
        try snippet.append(allocator, clone);
    }
    map[callee.insts.items.len] = @intCast(snippet.items.len);

    for (patches.items) |patch| {
        if (patch.target > callee.insts.items.len) return error.BadJumpTarget;
        snippet.items[patch.index].aux = map[patch.target];
    }
    const end: u32 = @intCast(snippet.items.len);
    for (return_jumps.items) |index| snippet.items[index].aux = end;
    return snippet;
}

fn inlineOne(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    candidate: cg.InlineCandidate,
) !void {
    const callee_before = program.functions.items[candidate.callee] orelse return error.BadCallee;
    var nested_slots: usize = 0;
    for (callee_before.insts.items) |inst| nested_slots += @intFromBool(sem.captureTarget(inst) != null);
    if (nested_slots != 0) try program.functions.ensureUnusedCapacity(allocator, nested_slots);

    const function_mark = program.functions.items.len;
    errdefer {
        var i = program.functions.items.len;
        while (i > function_mark) {
            i -= 1;
            if (program.functions.items[i]) |*function| function.deinit(allocator);
        }
        program.functions.shrinkRetainingCapacity(function_mark);
    }

    const caller = &(program.functions.items[candidate.caller] orelse return error.BadCaller);
    const callee = &(program.functions.items[candidate.callee] orelse return error.BadCallee);
    if (candidate.pc >= caller.insts.items.len or candidate.closure_pc >= caller.insts.items.len) return error.BadPc;
    const original_call = caller.insts.items[candidate.pc];
    if (!callSiteSupported(caller, callee, candidate.pc)) return error.UnsupportedCall;
    if (callee.is_vararg and !varArgsSupported(callee)) return error.UnsupportedVararg;
    if (!retVarsSupported(callee)) return error.UnsupportedRetVar;
    if (@as(u64, caller.reg_count) + callee.reg_count > std.math.maxInt(u32)) return error.TooManyRegisters;

    const multi = original_call.count == ir.multi_count;
    var consumer_pc: ?u32 = null;
    var consumer: ir.Inst = undefined;
    if (multi) {
        consumer_pc = findMultiConsumer(caller, candidate.pc, original_call.dst) orelse return error.UnsupportedMultiConsumer;
        consumer = caller.insts.items[consumer_pc.?];
    }

    var closure_ssa = try ssa.build(allocator, program, caller);
    defer closure_ssa.deinit();
    const remove_alias = try allocator.alloc(bool, caller.insts.items.len);
    defer allocator.free(remove_alias);
    @memset(remove_alias, false);
    const alias_state = try allocator.alloc(ssa.ValueId, caller.reg_count);
    defer if (alias_state.len != 0) allocator.free(alias_state);
    for (caller.insts.items, 0..) |inst, pc_usize| {
        if (inst.op != .move or closure_ssa.captured[inst.dst]) continue;
        const pc: u32 = @intCast(pc_usize);
        try ssa.stateBefore(&closure_ssa, caller, pc, alias_state);
        if (inst.a < alias_state.len and closure_ssa.canonicalValue(alias_state[inst.a]) == candidate.closure_value) {
            remove_alias[pc_usize] = true;
        }
    }

    const operand_mark = caller.operands.items.len;
    errdefer caller.operands.shrinkRetainingCapacity(operand_mark);
    const plan = try planCall(allocator, caller, callee, candidate.pc);
    const call = plan.call;
    const reg_base = caller.reg_count;
    var nested: NestedMap = .empty;
    defer nested.deinit(allocator);
    var captures: std.ArrayList(u32) = .empty;
    defer captures.deinit(allocator);
    try cloneNestedChildren(allocator, program, callee, reg_base, &nested, &captures);

    var snippet = if (multi)
        try buildMultiSnippet(allocator, caller, callee, call, consumer, reg_base, &nested, captures.items)
    else
        try buildSnippet(allocator, caller, callee, call, reg_base, &nested, captures.items);
    defer snippet.deinit(allocator);

    const old_len = caller.insts.items.len;
    const old_to_new = try allocator.alloc(u32, old_len + 1);
    defer allocator.free(old_to_new);
    var new_insts: std.ArrayList(ir.Inst) = .empty;
    errdefer new_insts.deinit(allocator);
    var outer_patches: std.ArrayList(Patch) = .empty;
    defer outer_patches.deinit(allocator);

    for (caller.insts.items, 0..) |inst, pc| {
        old_to_new[pc] = @intCast(new_insts.items.len);
        if (pc == candidate.closure_pc or remove_alias[pc]) continue;
        if (pc == candidate.pc) {
            const base: u32 = @intCast(new_insts.items.len);
            for (snippet.items) |snippet_inst_raw| {
                var snippet_inst = snippet_inst_raw;
                if (isJump(snippet_inst.op)) snippet_inst.aux += base;
                try new_insts.append(allocator, snippet_inst);
            }
            continue;
        }
        if (consumer_pc != null and pc > candidate.pc and pc <= consumer_pc.?) continue;
        const new_index = new_insts.items.len;
        var copy = if (plan.producer_pc != null and pc == plan.producer_pc.?) plan.producer.? else inst;
        if (isJump(copy.op)) {
            try outer_patches.append(allocator, .{ .index = new_index, .target = copy.aux });
            copy.aux = 0;
        }
        try new_insts.append(allocator, copy);
    }
    old_to_new[old_len] = @intCast(new_insts.items.len);
    for (outer_patches.items) |patch| {
        if (patch.target > old_len) return error.BadJumpTarget;
        new_insts.items[patch.index].aux = old_to_new[patch.target];
    }

    caller.insts.deinit(allocator);
    caller.insts = new_insts;
    caller.reg_count = reg_base + callee.reg_count;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    while (true) {
        var graph = try cg.build(allocator, program);
        defer graph.deinit();
        var chosen: ?cg.InlineCandidate = null;
        for (graph.candidates.items) |candidate| {
            const caller = program.functions.items[candidate.caller] orelse continue;
            const callee = program.functions.items[candidate.callee] orelse continue;
            const call = caller.insts.items[candidate.pc];
            if ((callee.is_vararg and !varArgsSupported(&callee)) or !retVarsSupported(&callee)) continue;
            if (!callSiteSupported(&caller, &callee, candidate.pc)) continue;
            if (call.count == ir.multi_count and findMultiConsumer(&caller, candidate.pc, call.dst) == null) continue;
            chosen = candidate;
            break;
        }
        if (chosen) |candidate| {
            try inlineOne(allocator, program, candidate);
            stats.inlined += 1;
            continue;
        }
        for (graph.candidates.items) |candidate| {
            const caller = program.functions.items[candidate.caller] orelse continue;
            const callee = program.functions.items[candidate.callee] orelse continue;
            const call = caller.insts.items[candidate.pc];
            if (callee.is_vararg and !varArgsSupported(&callee)) stats.blocked_vararg += 1 else if (!retVarsSupported(&callee)) stats.blocked_ret_var += 1 else if (!callSiteSupported(&caller, &callee, candidate.pc)) stats.blocked_multi_result += 1 else if (call.count == ir.multi_count and findMultiConsumer(&caller, candidate.pc, call.dst) == null) stats.blocked_multi_result += 1;
        }
        break;
    }
    return stats;
}

fn expectSame(source: []const u8) !void {
    var chunk_a = try lua.parse(std.testing.allocator, source);
    defer chunk_a.deinit();
    var chunk_b = try lua.parse(std.testing.allocator, source);
    defer chunk_b.deinit();
    var baseline = try ir.lowerChunk(std.testing.allocator, &chunk_a);
    defer baseline.deinit();
    var optimized = try ir.lowerChunk(std.testing.allocator, &chunk_b);
    defer optimized.deinit();
    _ = try run(std.testing.allocator, &optimized);

    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    var vm_a = try exec.Vm.init(arena_a.allocator());
    var vm_b = try exec.Vm.init(arena_b.allocator());
    const a = try vm_a.executeRoot(&baseline, &.{});
    defer exec.Vm.freeResults(a);
    const b = try vm_b.executeRoot(&optimized, &.{});
    defer exec.Vm.freeResults(b);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |lhs, rhs| try std.testing.expect(rt.rawEqual(lhs, rhs));
}

test "mandatory inliner handles fixed call and branch returns" {
    try expectSame(
        \\local function choose(x)
        \\  if x then return 11 else return 22 end
        \\end
        \\return choose(false)
    );
}

test "mandatory inliner rewrites captured upvalue reads and writes" {
    try expectSame(
        \\local x = 1
        \\local function bump(n)
        \\  x = x + n
        \\  return x
        \\end
        \\local y = bump(4)
        \\return y, x
    );
}

test "mandatory inliner preserves nested closures and translated captures" {
    try expectSame(
        \\local outer = 10
        \\local function make(x)
        \\  return function(z) return x + outer + z end
        \\end
        \\local f = make(3)
        \\return f(4)
    );
}

test "mandatory inliner preserves ignored results and missing parameters" {
    try expectSame(
        \\local x = 0
        \\local function f(a, b)
        \\  x = (a or 3) + (b or 4)
        \\  return 99
        \\end
        \\f()
        \\return x
    );
}

test "mandatory inliner specializes ret-var tail results to fixed caller arity" {
    try expectSame(
        \\local count = 0
        \\local function g(x) count = count + 1; return x, x + 1 end
        \\local function f(x) return 99, g(x) end
        \\local a, b, c = f(4)
        \\return a, b, c, count
    );
}

test "mandatory inliner executes discarded ret-var tail calls" {
    try expectSame(
        \\local count = 0
        \\local function g(x) count = count + 1; return x, x + 1 end
        \\local function f(x) return 99, g(x) end
        \\local a = f(4)
        \\return a, count
    );
}

test "mandatory inliner removes dead closure alias moves" {
    const source =
        \\local function add1(x) return x + 1 end
        \\local y = add1(4)
        \\return y
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var graph = try cg.build(std.testing.allocator, &program);
    const candidate = graph.candidates.items[0];
    const closure_dst = program.functions.items[candidate.caller].?.insts.items[candidate.closure_pc].dst;
    graph.deinit();
    _ = try run(std.testing.allocator, &program);
    const root = program.functions.items[program.root_function].?;
    for (root.insts.items) |inst| try std.testing.expect(!(inst.op == .move and inst.a == closure_dst));
}

test "mandatory inliner forwards multi result into return" {
    try expectSame(
        \\local function one(x) return x + 1 end
        \\return 7, one(4)
    );
}

test "mandatory inliner forwards multi result into vararg call" {
    try expectSame(
        \\local function one(x) return x + 1 end
        \\local function sum(a, b) return a + b end
        \\return sum(10, one(4))
    );
}

test "mandatory inliner forwards multi result into table append" {
    try expectSame(
        \\local function one() return 2 end
        \\local t = { 1, one() }
        \\return t[1], t[2]
    );
}

test "mandatory inliner forwards dynamic ret-var tail into consumer" {
    try expectSame(
        \\local function pair(x) return x, x + 1 end
        \\local function pass(x) return pair(x) end
        \\local function sum(a, b) return a + b end
        \\return sum(pass(4))
    );
}

test "mandatory inliner forwards multi result into method vararg" {
    try expectSame(
        \\local function one() return 3 end
        \\local t = { base = 5, add = function(self, x) return self.base + x end }
        \\return t:add(one())
    );
}

test "mandatory inliner specializes static varargs into table append" {
    try expectSame(
        \\local function f(...)
        \\  local t = {...}
        \\  return t[1] + t[2]
        \\end
        \\local y = f(3, 4)
        \\return y
    );
}

test "mandatory inliner specializes static varargs forwarded to call" {
    try expectSame(
        \\local function g(a, b) return a + b end
        \\local function f(...) return g(...) end
        \\local y = f(3, 4)
        \\return y
    );
}

test "mandatory inliner consumes one dynamic tail argument" {
    try expectSame(
        \\local t = { pair = function() return 3, 4 end }
        \\local function f(a) return a + 1 end
        \\local y = f(t.pair())
        \\return y
    );
}

test "mandatory inliner materializes two dynamic tail arguments" {
    try expectSame(
        \\local t = { pair = function() return 3, 4 end }
        \\local function f(prefix, a, b) return prefix + a + b end
        \\local y = f(10, t.pair())
        \\return y
    );
}
