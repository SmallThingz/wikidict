const refs = @import("vm_ref.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
pub const dst: u8 = 1;
pub const a: u8 = 2;
pub const b: u8 = 4;
pub const c: u8 = 8;
pub const aux: u8 = 16;
pub const count: u8 = 32;
pub const fields = .{ "dst", "a", "b", "c", "aux", "count" };
pub const Bits = std.DynamicBitSetUnmanaged;
pub const List = enum { none, count, b };
pub const Info = struct {
    fields: u8 = 0,
    reads: u8 = 0,
    addresses: u8 = 0, // register identity without reading its value
    defines: bool = false,
    results: bool = false,
    list: List = .none,
    target: bool = false,
};

// Exhaustive operand semantics shared by verification and encoding.
// Function, string and slot IDs are not register reads.
pub fn captureTarget(inst: ir.Inst) ?u32 {
    return switch (inst.op) {
        .closure, .load_function => inst.aux,
        .call_scoped, .call_scoped_vararg => inst.a,
        else => null,
    };
}
pub fn info(op: ir.Opcode) Info {
    return switch (op) {
        .load_nil, .new_table => .{ .fields = dst, .defines = true },
        .load_bool => .{ .fields = dst | a, .defines = true },
        .load_number, .load_string, .load_const, .get_global, .get_global_slot, .closure, .load_function, .new_table_shape => .{ .fields = dst | aux, .defines = true },
        .get_upvalue => .{ .fields = dst | a, .defines = true },
        .set_upvalue => .{ .fields = a | b, .reads = b },
        .set_global, .set_global_slot, .register_function => .{ .fields = a | aux, .reads = a },
        .move, .neg, .not_, .len, .neg_number, .len_string => .{ .fields = dst | a, .reads = a, .defines = true },
        .vararg => .{ .fields = dst | count, .results = true },
        .get_index, .get_choice_slot => .{ .fields = dst | a | b | (if (op == .get_choice_slot) aux else 0), .reads = a | b, .defines = true },
        .get_field, .get_slot => .{ .fields = dst | a | aux, .reads = a, .defines = true },
        .table_set, .set_index, .set_choice_slot => .{ .fields = a | b | c | (if (op == .set_choice_slot) aux else 0), .reads = a | b | c },
        .set_field, .set_slot => .{ .fields = a | c | aux, .reads = a | c },
        .table_append, .table_append_var => .{ .fields = a | b, .reads = a | b },
        .add, .sub, .mul, .div, .mod, .pow, .eq, .ne, .lt, .le, .gt, .ge, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => .{ .fields = dst | a | b, .reads = a | b, .defines = true },
        .concat => .{ .fields = dst | aux | count, .defines = true, .list = .count },
        .jump => .{ .fields = aux, .target = true },
        .jump_if_false => .{ .fields = a | aux, .reads = a, .target = true },
        .branch_compare => .{ .fields = a | b | aux | count, .reads = a | b, .target = true },
        .detach_cell => .{ .fields = a, .addresses = a },
        .init_module => .{ .fields = aux },
        .check_table_key => .{ .fields = a, .reads = a },
        .call, .call_vararg => .{ .fields = dst | a | b | aux | count | (if (op == .call_vararg) c else 0), .reads = a | (if (op == .call_vararg) c else 0), .results = true, .list = .b },
        .direct_call, .direct_call_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg, .method_call_field, .method_call_field_vararg => .{
            .fields = dst | a | b | aux | count | (if (op == .direct_call_vararg or op == .call_scoped_vararg or op == .call_local_vararg or op == .method_call_field_vararg) c else 0),
            .reads = if (op == .direct_call_vararg or op == .call_scoped_vararg or op == .call_local_vararg or op == .method_call_field_vararg) c else 0,
            .results = true,
            .list = .b,
        },
        .method_call, .method_call_vararg => .{ .fields = dst | b | aux | count | (if (op == .method_call_vararg) c else 0), .reads = if (op == .method_call_vararg) c else 0, .results = true, .list = .b },
        .numeric_for_init, .numeric_for_next => .{ .fields = dst | a | b | c | aux, .reads = a | b | c, .target = true },
        .generic_for_init, .generic_for_next => .{ .fields = dst | a | b | c | aux | count, .reads = a | b | c, .target = true },
        .ret => .{ .fields = aux | count, .list = .count },
        .ret_var => .{ .fields = a | aux | count, .reads = a, .list = .count },
    };
}

pub fn operands(function: *const ir.Function, inst: ir.Inst) ![]const u32 {
    const n = switch (info(inst.op).list) {
        .none => return &.{},
        .count => inst.count,
        .b => inst.b,
    };
    if (inst.aux > function.operands.items.len or n > function.operands.items.len - inst.aux) return error.BadOperandRange;
    return function.operands.items[inst.aux..][0..n];
}
fn mark(bits: *Bits, reg: u32) !void {
    if (reg >= bits.bit_length) return error.BadRegister;
    bits.set(reg);
}
pub fn reads(program: *const ir.Program, function: *const ir.Function, inst: ir.Inst, out: *Bits) !void {
    const description = info(inst.op);

    inline for (fields, 0..) |field, i| if (description.reads & (@as(u8, 1) << i) != 0) {
        const value = @field(inst, field);
        if (refs.isRegister(value)) try mark(out, value) else {
            if (refs.mask(inst.op) & (@as(u8, 1) << i) == 0) return error.BadRegister;
            try refs.validate(program, value);
        }
    };
    inline for (fields, 0..) |field, i| if (description.addresses & (@as(u8, 1) << i) != 0) {
        if (@field(inst, field) >= function.reg_count) return error.BadRegister;
    };
    for (try operands(function, inst)) |value| {
        if (refs.isRegister(value)) try mark(out, value) else try refs.validate(program, value);
    }
    if (captureTarget(inst)) |target| {
        if (target >= program.functions.items.len) return error.BadFunctionReference;
        const child = program.functions.items[target] orelse return error.IncompleteProgram;
        for (child.upvalues.items) |up| switch (up.source) {
            .local => try mark(out, up.index),
            .upvalue => if (up.index >= function.upvalues.items.len) return error.BadUpvalue,
        };
    }
}
fn markRange(out: *Bits, base: u32, n: u32) !void {
    const width = if (n == ir.multi_count) 1 else n;
    if (width == 0) return;
    if (base >= out.bit_length or width > out.bit_length - base) return error.BadRegisterRange;
    for (base..base + width) |reg| out.set(reg);
}
// null describes writes common to every outgoing edge.
pub fn writes(inst: ir.Inst, branch_taken: ?bool, out: *Bits) !void {
    const description = info(inst.op);

    if (description.defines) return mark(out, inst.dst);
    if (description.results) return markRange(out, inst.dst, inst.count);
    switch (inst.op) {
        .numeric_for_init => if (branch_taken == false) {
            try mark(out, inst.dst);
        },
        .numeric_for_next => {
            try mark(out, inst.a);
            if (branch_taken == true) try mark(out, inst.dst);
        },
        .generic_for_init, .generic_for_next => {
            if (branch_taken != null and branch_taken.? == (inst.op == .generic_for_next)) {
                try mark(out, inst.c);
                try markRange(out, inst.dst, inst.count);
            }
        },
        else => {},
    }
}

pub fn canonical(inst: ir.Inst) ir.Inst {
    var result = inst;
    const mask = info(inst.op).fields;
    inline for (fields, 0..) |field, i| if (mask & (@as(u8, 1) << i) == 0) {
        @field(result, field) = 0;
    };
    return result;
}

pub fn isComparison(op: ir.Opcode) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => true,
        else => false,
    };
}

pub fn comparisonOpcode(raw: u32) !ir.Opcode {
    if (raw >= @typeInfo(ir.Opcode).@"enum".fields.len) return error.BadComparison;
    const op: ir.Opcode = @enumFromInt(@as(u8, @intCast(raw)));
    if (!isComparison(op)) return error.BadComparison;
    return op;
}
