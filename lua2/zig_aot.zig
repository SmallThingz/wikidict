const std = @import("std");
const ir = @import("vm_ir.zig");
const refs = @import("vm_ref.zig");
const global_abi = @import("vm_global_abi.zig");
const graph_mod = @import("vm_graph.zig");
const sem = @import("vm_semantics.zig");

const A = std.mem.Allocator;

pub const Stats = struct {
    functions: u32 = 0,
    instructions: u64 = 0,
    dynamic_calls: u64 = 0,
    dynamic_indexes: u64 = 0,
    string_fields: u64 = 0,
};
const Rep = enum { unknown, value, number };

const FunctionPlan = struct {
    allocator: A,
    reps: []Rep,
    captured: []bool,

    fn deinit(self: *FunctionPlan) void {
        self.allocator.free(self.reps);
        self.allocator.free(self.captured);
    }

    fn rep(self: *const FunctionPlan, reg: u32) Rep {
        return if (reg < self.reps.len) self.reps[reg] else .value;
    }
};

fn mergeRep(slot: *Rep, candidate: Rep) bool {
    if (candidate == .unknown) return false;
    const before = slot.*;
    slot.* = switch (before) {
        .unknown => candidate,
        .number => if (candidate == .number) .number else .value,
        .value => .value,
    };
    return slot.* != before;
}
fn refRep(p: *const ir.Program, reps: []const Rep, value: u32) Rep {
    return switch (refs.tag(value)) {
        .register => if (value < reps.len) reps[value] else .unknown,
        .integer => .number,
        .constant => blk: {
            const id = refs.index(value);
            if (id >= p.constants.items.len) break :blk .value;
            break :blk switch (p.constants.items[id]) {
                .number_bits, .integer => .number,
                else => .value,
            };
        },
        else => .value,
    };
}

fn definedRep(p: *const ir.Program, inst: ir.Inst, reps: []const Rep) Rep {
    return switch (inst.op) {
        .load_number, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .neg, .neg_number, .len_string, .len => .number,
        .load_const => blk: {
            if (inst.aux >= p.constants.items.len) break :blk .value;
            break :blk switch (p.constants.items[inst.aux]) {
                .number, .number_bits, .integer => .number,
                else => .value,
            };
        },
        .move => refRep(p, reps, inst.a),
        else => .value,
    };
}
fn analyzePlan(a: A, p: *const ir.Program, function: *const ir.Function) !FunctionPlan {
    const reps = try a.alloc(Rep, function.reg_count);
    errdefer a.free(reps);
    @memset(reps, .unknown);
    const captured = try a.alloc(bool, function.reg_count);
    errdefer a.free(captured);
    @memset(captured, false);
    for (0..@min(@as(usize, function.param_count), reps.len)) |reg| reps[reg] = .value;
    for (function.insts.items) |inst| if (sem.captureTarget(inst)) |target_id| {
        if (target_id >= p.functions.items.len) return error.BadFunctionReference;
        const child = p.functions.items[target_id] orelse return error.IncompleteProgram;
        for (child.upvalues.items) |up| if (up.source == .local) {
            if (up.index >= captured.len) return error.BadRegister;
            captured[up.index] = true;
            reps[up.index] = .value;
        };
    };

    var changed = true;
    while (changed) {
        changed = false;
        for (function.insts.items) |inst| {
            const info = sem.info(inst.op);
            if (info.defines and inst.dst < reps.len and !captured[inst.dst])
                changed = mergeRep(&reps[inst.dst], definedRep(p, inst, reps)) or changed;
            if (info.results) {
                const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
                for (0..width) |i| {
                    const reg = inst.dst + @as(u32, @intCast(i));
                    if (reg < reps.len) changed = mergeRep(&reps[reg], .value) or changed;
                }
            }
        }
    }
    for (function.insts.items) |inst| switch (inst.op) {
        .numeric_for_init => {
            if (inst.dst < reps.len and !captured[inst.dst]) _ = mergeRep(&reps[inst.dst], .number);
        },
        .numeric_for_next => {
            if (inst.a < reps.len and !captured[inst.a]) _ = mergeRep(&reps[inst.a], .number);
            if (inst.dst < reps.len and !captured[inst.dst]) _ = mergeRep(&reps[inst.dst], .number);
        },
        .generic_for_init, .generic_for_next => {
            if (inst.c < reps.len) reps[inst.c] = .value;
            const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
            for (0..width) |i| {
                const reg = inst.dst + @as(u32, @intCast(i));
                if (reg < reps.len) reps[reg] = .value;
            }
        },
        else => {},
    };
    for (reps) |*rep| {
        if (rep.* == .unknown) rep.* = .value;
    }
    return .{ .allocator = a, .reps = reps, .captured = captured };
}

fn text(out: *std.ArrayList(u8), a: A, value: []const u8) !void {
    try out.appendSlice(a, value);
}

fn print(out: *std.ArrayList(u8), a: A, comptime fmt: []const u8, args: anytype) !void {
    try out.print(a, fmt, args);
}

fn stringLiteral(out: *std.ArrayList(u8), a: A, value: []const u8) !void {
    try out.append(a, '"');
    for (value) |byte| switch (byte) {
        '"' => try text(out, a, "\\\""),
        '\\' => try text(out, a, "\\\\"),
        '\n' => try text(out, a, "\\n"),
        '\r' => try text(out, a, "\\r"),
        '\t' => try text(out, a, "\\t"),
        else => if (byte >= 0x20 and byte <= 0x7e) try out.append(a, byte) else try print(out, a, "\\x{x:0>2}", .{byte}),
    };
    try out.append(a, '"');
}
fn scalarNodeExpr(out: *std.ArrayList(u8), a: A, p: *const ir.Program, node: ir.ConstNode) !void {
    switch (node) {
        .nil => try text(out, a, ".nil"),
        .boolean => |v| try print(out, a, ".{{ .boolean = {} }}", .{v}),
        .number_bits => |bits| try print(out, a, ".{{ .number = @bitCast(@as(u64, 0x{x})) }}", .{bits}),
        .integer => |v| try print(out, a, ".{{ .number = {d}.0 }}", .{v}),
        .string => |sid| {
            if (sid >= p.strings.items.len) return error.BadStringReference;
            try text(out, a, ".{ .string = ");
            try stringLiteral(out, a, p.strings.items[sid]);
            try text(out, a, " }");
        },
        .number => return error.LegacyNumberConstant,
        .table => return error.TableConstantNotScalar,
    }
}

fn valueExpr(out: *std.ArrayList(u8), a: A, p: *const ir.Program, plan: *const FunctionPlan, value: u32) !void {
    switch (refs.tag(value)) {
        .register => if (plan.rep(value) == .number)
            try print(out, a, ".{{ .number = n_{d} }}", .{value})
        else
            try print(out, a, "frame.get({d})", .{value}),
        .integer => try print(out, a, ".{{ .number = {d}.0 }}", .{refs.integerValue(value)}),
        .string => {
            const sid = refs.index(value);
            if (sid >= p.strings.items.len) return error.BadStringReference;
            try text(out, a, ".{ .string = ");
            try stringLiteral(out, a, p.strings.items[sid]);
            try text(out, a, " }");
        },
        .constant => {
            const id = refs.index(value);
            if (id >= p.constants.items.len) return error.BadConstantReference;
            try scalarNodeExpr(out, a, p, p.constants.items[id]);
        },
        .special => switch (value) {
            refs.nil => try text(out, a, ".nil"),
            refs.false_value => try text(out, a, ".{ .boolean = false }"),
            refs.true_value => try text(out, a, ".{ .boolean = true }"),
            else => return error.BadImmediate,
        },
        else => return error.BadImmediate,
    }
}
fn numberExpr(out: *std.ArrayList(u8), a: A, p: *const ir.Program, plan: *const FunctionPlan, value: u32) !void {
    switch (refs.tag(value)) {
        .register => if (plan.rep(value) == .number)
            try print(out, a, "n_{d}", .{value})
        else
            try print(out, a, "frame.get({d}).number", .{value}),
        .integer => try print(out, a, "{d}.0", .{refs.integerValue(value)}),
        .constant => {
            const id = refs.index(value);
            if (id >= p.constants.items.len) return error.BadConstantReference;
            switch (p.constants.items[id]) {
                .number_bits => |bits| try print(out, a, "@bitCast(@as(u64, 0x{x}))", .{bits}),
                .integer => |v| try print(out, a, "{d}.0", .{v}),
                else => return error.NonNumericReference,
            }
        },
        else => return error.NonNumericReference,
    }
}

fn coercedNumberExpr(out: *std.ArrayList(u8), a: A, p: *const ir.Program, plan: *const FunctionPlan, value: u32) !void {
    const native = switch (refs.tag(value)) {
        .register => plan.rep(value) == .number,
        .integer => true,
        .constant => blk: {
            const id = refs.index(value);
            if (id >= p.constants.items.len) break :blk false;
            break :blk switch (p.constants.items[id]) {
                .number_bits, .integer => true,
                else => false,
            };
        },
        else => false,
    };
    if (native) return numberExpr(out, a, p, plan, value);
    try text(out, a, "(rt.toNumber(");
    try valueExpr(out, a, p, plan, value);
    try text(out, a, ") orelse return error.NumericForType)");
}
fn setPrefix(out: *std.ArrayList(u8), a: A, dst: u32) !void {
    try print(out, a, "frame.set({d}, ", .{dst});
}

fn emitConstants(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    try text(out, a, "const constants = [_]rt.Constant{\n");
    for (p.constants.items) |node| {
        try text(out, a, "    ");
        switch (node) {
            .table => |table| try print(out, a, ".{{ .table = .{{ .first = {d}, .count = {d} }} }}", .{ table.first, table.count }),
            else => try scalarNodeExpr(out, a, p, node),
        }
        try text(out, a, ",\n");
    }
    try text(out, a, "};\nconst constant_entries = [_]rt.ConstantEntry{\n");
    for (p.const_entries.items) |entry| {
        const encoded = (@as(u64, entry.key) << 32) | entry.value;
        try print(out, a, "    0x{x:0>16},\n", .{encoded});
    }
    try text(out, a, "};\n\n");
}
fn globalCount(p: *const ir.Program) u32 {
    if (p.global_shape) |shape_id| {
        if (shape_id < p.shapes.items.len) return p.shapes.items[shape_id].field_count;
    }
    var count: u32 = 0;
    for (p.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| switch (inst.op) {
            .get_global_slot, .set_global_slot => count = @max(count, inst.aux + 1),
            else => {},
        };
    };
    return count;
}

fn emitShapes(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    for (p.shapes.items, 0..) |shape, id| {
        try print(out, a, "const shape_{d}_keys = [_][]const u8{{", .{id});
        for (shape.field_keys.items, 0..) |sid, index| {
            if (sid >= p.strings.items.len) return error.BadStringReference;
            if (index != 0) try text(out, a, ", ");
            try stringLiteral(out, a, p.strings.items[sid]);
        }
        try text(out, a, "};\n");
    }
    try text(out, a, "const shapes = [_]rt.Shape{\n");
    for (p.shapes.items, 0..) |shape, id| {
        try print(out, a, "    .{{ .field_keys = &shape_{d}_keys, .field_count = {d}, .choice_count = {d}, .open = {} }},\n", .{ id, shape.field_count, shape.choice_count, shape.open });
    }
    try text(out, a, "};\n\n");
}

fn emitDeclarations(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    _ = p;
    try text(out, a, "const std = @import(\"std\");\nconst rt = @import(\"zig_runtime\");\n\n");
}
fn emitArgs(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, first: u32, count: u32, skip: usize) !void {
    if (@as(usize, first) + count > function.operands.items.len or skip > count) return error.BadOperandRange;
    try text(out, a, "&[_]rt.Value{");
    for (function.operands.items[first .. first + count][skip..], 0..) |value, index| {
        if (index != 0) try text(out, a, ", ");
        try valueExpr(out, a, p, plan, value);
    }
    try text(out, a, "}");
}

fn emitCaptures(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, target_id: u32, pc: usize) !void {
    if (target_id >= p.functions.items.len) return error.BadFunctionReference;
    const target = p.functions.items[target_id] orelse return error.IncompleteProgram;
    try print(out, a, "            var captures_{d}: [{d}]*rt.Cell = undefined;\n", .{ pc, target.upvalues.items.len });
    for (target.upvalues.items, 0..) |up, index| switch (up.source) {
        .local => try print(out, a, "            captures_{d}[{d}] = try frame.ensureCell(ctx, {d});\n", .{ pc, index, up.index }),
        .upvalue => {
            if (up.index >= function.upvalues.items.len) return error.BadUpvalue;
            try print(out, a, "            captures_{d}[{d}] = upvalues[{d}];\n", .{ pc, index, up.index });
        },
    };
}

fn arithName(op: ir.Opcode) ![]const u8 {
    return switch (op) {
        .add, .add_number => "add",
        .sub, .sub_number => "sub",
        .mul, .mul_number => "mul",
        .div, .div_number => "div",
        .mod, .mod_number => "mod",
        .pow, .pow_number => "pow",
        else => error.NotArithmetic,
    };
}

fn compareName(op: ir.Opcode) ![]const u8 {
    return switch (op) {
        .eq, .eq_number => "eq",
        .ne, .ne_number => "ne",
        .lt, .lt_number => "lt",
        .le, .le_number => "le",
        .gt, .gt_number => "gt",
        .ge, .ge_number => "ge",
        else => error.NotComparison,
    };
}
fn emitSimple(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    switch (inst.op) {
        .load_nil => try print(out, a, "            frame.set({d}, .nil);\n", .{inst.dst}),
        .load_bool => try print(out, a, "            frame.set({d}, .{{ .boolean = {} }});\n", .{ inst.dst, inst.a != 0 }),
        .load_number => {
            if (inst.aux >= p.strings.items.len) return error.BadStringReference;
            const number = try @import("vm_exec.zig").Vm.parseLuaNumber(p.strings.items[inst.aux]);
            if (plan.rep(inst.dst) == .number)
                try print(out, a, "            n_{d} = @bitCast(@as(u64, 0x{x}));\n", .{ inst.dst, @as(u64, @bitCast(number)) })
            else
                try print(out, a, "            frame.set({d}, .{{ .number = @bitCast(@as(u64, 0x{x})) }});\n", .{ inst.dst, @as(u64, @bitCast(number)) });
        },
        .load_string => {
            if (inst.aux >= p.strings.items.len) return error.BadStringReference;
            try print(out, a, "            frame.set({d}, .{{ .string = ", .{inst.dst});
            try stringLiteral(out, a, p.strings.items[inst.aux]);
            try text(out, a, " });\n");
        },
        .load_const => if (plan.rep(inst.dst) == .number) {
            try print(out, a, "            n_{d} = ", .{inst.dst});
            try numberExpr(out, a, p, plan, try refs.constant(inst.aux));
            try text(out, a, ";\n");
        } else try print(out, a, "            frame.set({d}, try ctx.materializeConstant(&constants, &constant_entries, {d}));\n", .{ inst.dst, inst.aux }),
        .get_global_slot => try print(out, a, "            frame.set({d}, ctx.getGlobal({d}));\n", .{ inst.dst, inst.aux }),
        .set_global_slot => {
            try print(out, a, "            try ctx.setGlobal({d}, ", .{inst.aux});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ");\n");
        },
        .get_global, .set_global => return error.UnresolvedStringGlobal,
        .get_upvalue => try print(out, a, "            frame.set({d}, upvalues[{d}].value);\n", .{ inst.dst, inst.a }),
        .set_upvalue => {
            try print(out, a, "            upvalues[{d}].value = ", .{inst.a});
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, ";\n");
        },
        .move => if (plan.rep(inst.dst) == .number) {
            try print(out, a, "            n_{d} = ", .{inst.dst});
            try numberExpr(out, a, p, plan, inst.a);
            try text(out, a, ";\n");
        } else {
            try print(out, a, "            frame.set({d}, ", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ");\n");
        },
        .detach_cell => try print(out, a, "            frame.detachCell({d});\n", .{inst.a}),
        else => try emitSimple2(out, a, p, function, plan, inst, pc, stats),
    }
}
fn emitSimple2(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    switch (inst.op) {
        .vararg => try print(out, a, "            frame.storeResults({d}, {d}, frame.varargs, false);\n", .{ inst.dst, inst.count }),
        .new_table => try print(out, a, "            frame.set({d}, .{{ .table = try ctx.newTable() }});\n", .{inst.dst}),
        .new_table_shape => try print(out, a, "            frame.set({d}, .{{ .table = try ctx.newShape({d}) }});\n", .{ inst.dst, inst.aux }),
        .table_set, .set_index => {
            try text(out, a, "            try ctx.setIndex(");
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ", ");
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, ", ");
            try valueExpr(out, a, p, plan, inst.c);
            try text(out, a, ");\n");
            stats.dynamic_indexes += 1;
        },
        .get_index => {
            try print(out, a, "            frame.set({d}, try ctx.getIndex(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ", ");
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, "));\n");
            stats.dynamic_indexes += 1;
        },
        .get_slot => {
            try print(out, a, "            frame.set({d}, try ctx.getSlot(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, ", {d}));\n", .{inst.aux});
        },
        .set_slot => {
            try text(out, a, "            try ctx.setSlot(");
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, ", {d}, ", .{inst.aux});
            try valueExpr(out, a, p, plan, inst.c);
            try text(out, a, ");\n");
        },
        .get_choice_slot => {
            try print(out, a, "            frame.set({d}, try ctx.getChoice(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, ", {d}, ", .{inst.aux});
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, "));\n");
        },
        .set_choice_slot => {
            try text(out, a, "            try ctx.setChoice(");
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, ", {d}, ", .{inst.aux});
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, ", ");
            try valueExpr(out, a, p, plan, inst.c);
            try text(out, a, ");\n");
        },
        else => try emitSimple3(out, a, p, function, plan, inst, pc, stats),
    }
}
fn emitSimple3(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    switch (inst.op) {
        .get_field => {
            if (inst.aux >= p.strings.items.len) return error.BadStringReference;
            try print(out, a, "            frame.set({d}, try ctx.getIndex(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ", .{ .string = ");
            try stringLiteral(out, a, p.strings.items[inst.aux]);
            try text(out, a, " }));\n");
            stats.string_fields += 1;
        },
        .set_field => {
            if (inst.aux >= p.strings.items.len) return error.BadStringReference;
            try text(out, a, "            try ctx.setIndex(");
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ", .{ .string = ");
            try stringLiteral(out, a, p.strings.items[inst.aux]);
            try text(out, a, " }, ");
            try valueExpr(out, a, p, plan, inst.c);
            try text(out, a, ");\n");
            stats.string_fields += 1;
        },
        .table_append => {
            try text(out, a, "            { const object = ");
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, "; if (object != .table) return error.TableExpected; try object.table.append(ctx.allocator, ");
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, "); }\n");
        },
        .table_append_var => {
            try text(out, a, "            { const object = ");
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, "; if (object != .table) return error.TableExpected; for (frame.multiAt({d})) |value| try object.table.append(ctx.allocator, value); }}\n", .{inst.b});
        },
        .closure, .load_function => {
            try emitCaptures(out, a, p, function, inst.aux, pc);
            try print(out, a, "            frame.set({d}, try ctx.makeFunction({d}, &captures_{d}));\n", .{ inst.dst, inst.aux, pc });
        },
        .register_function => {
            try print(out, a, "            if ({d} >= ctx.static_functions.len) return error.BadFunctionId; ctx.static_functions[{d}] = ", .{ inst.aux, inst.aux });
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ";\n");
        },
        .check_table_key => {
            try text(out, a, "            try rt.validateTableKey(");
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ");\n");
        },
        else => try emitSimple4(out, a, p, function, plan, inst, pc, stats),
    }
}
fn emitSimple4(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    switch (inst.op) {
        .not_ => {
            try print(out, a, "            frame.set({d}, .{{ .boolean = !(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ").truthy() });\n");
        },
        .neg => if (plan.rep(inst.dst) == .number) {
            try print(out, a, "            n_{d} = -(rt.toNumber(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ") orelse return error.ArithmeticType);\n");
        } else {
            try print(out, a, "            frame.set({d}, .{{ .number = -(rt.toNumber(", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ") orelse return error.ArithmeticType) });\n");
        },
        .len => {
            try text(out, a, "            { const value = ");
            try valueExpr(out, a, p, plan, inst.a);
            if (plan.rep(inst.dst) == .number)
                try print(out, a, "; n_{d} = switch (value) {{ .string => |s| @floatFromInt(s.len), .table => |t| @floatFromInt(t.rawLen()), else => return error.LengthType }}; }}\n", .{inst.dst})
            else
                try print(out, a, "; frame.set({d}, switch (value) {{ .string => |s| .{{ .number = @floatFromInt(s.len) }}, .table => |t| .{{ .number = @floatFromInt(t.rawLen()) }}, else => return error.LengthType }}); }}\n", .{inst.dst});
        },
        .add, .sub, .mul, .div, .mod, .pow => {
            const name = try arithName(inst.op);
            try print(out, a, "            frame.set({d}, try ctx.binaryArith(.{s}, ", .{ inst.dst, name });
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ", ");
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, "));\n");
        },
        .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number => {
            const name = try arithName(inst.op);
            const native_dst = plan.rep(inst.dst) == .number;
            if (native_dst)
                try print(out, a, "            n_{d} = ", .{inst.dst})
            else
                try print(out, a, "            frame.set({d}, .{{ .number = ", .{inst.dst});
            if (inst.op == .mod_number) {
                try text(out, a, "blk: { const x = ");
                try numberExpr(out, a, p, plan, inst.a);
                try text(out, a, "; const y = ");
                try numberExpr(out, a, p, plan, inst.b);
                try text(out, a, "; break :blk x - @floor(x / y) * y; }");
            } else if (inst.op == .pow_number) {
                try text(out, a, "std.math.pow(f64, ");
                try numberExpr(out, a, p, plan, inst.a);
                try text(out, a, ", ");
                try numberExpr(out, a, p, plan, inst.b);
                try text(out, a, ")");
            } else {
                try numberExpr(out, a, p, plan, inst.a);
                try print(out, a, " {s} ", .{switch (name[0]) {
                    'a' => "+",
                    's' => "-",
                    'm' => "*",
                    'd' => "/",
                    else => unreachable,
                }});
                try numberExpr(out, a, p, plan, inst.b);
            }
            try text(out, a, if (native_dst) ";\n" else " });\n");
        },
        else => try emitSimple5(out, a, p, function, plan, inst, pc, stats),
    }
}
fn emitSimple5(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    switch (inst.op) {
        .neg_number => {
            const native_dst = plan.rep(inst.dst) == .number;
            if (native_dst)
                try print(out, a, "            n_{d} = -(", .{inst.dst})
            else
                try print(out, a, "            frame.set({d}, .{{ .number = -(", .{inst.dst});
            try numberExpr(out, a, p, plan, inst.a);
            try text(out, a, if (native_dst) ");\n" else ") });\n");
        },
        .len_string => {
            const native_dst = plan.rep(inst.dst) == .number;
            if (native_dst)
                try print(out, a, "            n_{d} = @floatFromInt((", .{inst.dst})
            else
                try print(out, a, "            frame.set({d}, .{{ .number = @floatFromInt((", .{inst.dst});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, if (native_dst) ").string.len);\n" else ").string.len) });\n");
        },
        .eq, .ne, .lt, .le, .gt, .ge => {
            const name = try compareName(inst.op);
            try print(out, a, "            frame.set({d}, .{{ .boolean = try ctx.comparison(.{s}, ", .{ inst.dst, name });
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ", ");
            try valueExpr(out, a, p, plan, inst.b);
            try text(out, a, ") });\n");
        },
        .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => {
            const name = try compareName(inst.op);
            try print(out, a, "            frame.set({d}, .{{ .boolean = rt.numericCompare(.{s}, ", .{ inst.dst, name });
            try numberExpr(out, a, p, plan, inst.a);
            try text(out, a, ", ");
            try numberExpr(out, a, p, plan, inst.b);
            try text(out, a, ") });\n");
        },
        .concat => {
            if (@as(usize, inst.aux) + inst.count > function.operands.items.len) return error.BadOperandRange;
            try print(out, a, "            frame.set({d}, try ctx.concatValues(", .{inst.dst});
            try emitArgs(out, a, p, function, plan, inst.aux, inst.count, 0);
            try text(out, a, "));\n");
        },
        .call, .call_vararg, .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg, .method_call, .method_call_vararg, .method_call_field, .method_call_field_vararg => try emitCall(out, a, p, function, plan, inst, pc, stats),
        .init_module => try print(out, a, "            try ensureModule(ctx, {d});\n", .{inst.aux}),
        .jump, .jump_if_false, .branch_compare, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next, .ret, .ret_var => return error.ControlInstructionInBody,
        else => return error.UnsupportedOpcode,
    }
}
fn emitCallArgs(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, skip: usize, vararg: bool) !void {
    try print(out, a, "            const fixed_{d} = ", .{pc});
    try emitArgs(out, a, p, function, plan, inst.aux, inst.b, skip);
    try text(out, a, ";\n");
    if (vararg) {
        try print(out, a, "            const argv_{d} = try rt.mergeValues(fixed_{d}, frame.multiAt({d}));\n", .{ pc, pc, inst.c });
        try print(out, a, "            defer rt.freeValues(argv_{d});\n", .{pc});
    } else {
        try print(out, a, "            const argv_{d}: []const rt.Value = fixed_{d};\n", .{ pc, pc });
    }
}

fn emitCall(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    const vararg = switch (inst.op) {
        .call_vararg, .call_local_vararg, .call_scoped_vararg, .direct_call_vararg, .method_call_vararg, .method_call_field_vararg => true,
        else => false,
    };
    const method = inst.op == .method_call or inst.op == .method_call_vararg;
    const method_field = inst.op == .method_call_field or inst.op == .method_call_field_vararg;
    try text(out, a, "            {\n");
    try emitCallArgs(out, a, p, function, plan, inst, pc, if (method) 1 else 0, vararg);
    if (method) {
        if (@as(usize, inst.aux) + inst.b > function.operands.items.len or inst.b < 2) return error.BadOperandRange;
        try print(out, a, "            const method_{d} = try ctx.getIndex(", .{pc});
        try valueExpr(out, a, p, plan, function.operands.items[inst.aux + 1]);
        try text(out, a, ", ");
        try valueExpr(out, a, p, plan, function.operands.items[inst.aux]);
        try text(out, a, ");\n");
        try print(out, a, "            const result_{d} = try ctx.callValue(method_{d}, argv_{d});\n", .{ pc, pc, pc });
        stats.dynamic_calls += 1;
        stats.dynamic_indexes += 1;
    } else if (method_field) {
        if (inst.a >= p.strings.items.len or inst.b < 1) return error.BadStringReference;
        try print(out, a, "            const method_{d} = try ctx.getIndex(fixed_{d}[0], .{{ .string = ", .{ pc, pc });
        try stringLiteral(out, a, p.strings.items[inst.a]);
        try text(out, a, " });\n");
        try print(out, a, "            const result_{d} = try ctx.callValue(method_{d}, argv_{d});\n", .{ pc, pc, pc });
        stats.dynamic_calls += 1;
        stats.string_fields += 1;
    } else try emitPlainCall(out, a, p, function, plan, inst, pc, stats);
    try print(out, a, "            frame.storeResults({d}, {d}, result_{d}, true);\n", .{ inst.dst, inst.count, pc });
    try text(out, a, "            }\n");
}
fn emitPlainCall(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats) !void {
    switch (inst.op) {
        .call, .call_vararg => {
            try print(out, a, "            const result_{d} = try ctx.callValue(", .{pc});
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, ", argv_{d});\n", .{pc});
            stats.dynamic_calls += 1;
        },
        .call_local, .call_local_vararg => {
            if (inst.a >= p.functions.items.len) return error.BadFunctionReference;
            try print(out, a, "            const result_{d} = try f_{d}(ctx, &.{{}}, argv_{d});\n", .{ pc, inst.a, pc });
        },
        .call_scoped, .call_scoped_vararg => {
            try emitCaptures(out, a, p, function, inst.a, pc);
            try print(out, a, "            const result_{d} = try f_{d}(ctx, &captures_{d}, argv_{d});\n", .{ pc, inst.a, pc, pc });
        },
        .direct_call, .direct_call_vararg => {
            if (inst.a >= p.functions.items.len or p.function_modules.items.len != p.functions.items.len) return error.BadFunctionReference;
            const module_id = p.function_modules.items[inst.a];
            try print(out, a, "            try ensureModule(ctx, {d});\n", .{module_id});
            try print(out, a, "            if ({d} >= ctx.static_functions.len or ctx.static_functions[{d}] != .function) return error.UnregisteredStaticFunction;\n", .{ inst.a, inst.a });
            try print(out, a, "            const static_{d} = ctx.static_functions[{d}].function;\n", .{ pc, inst.a });
            try print(out, a, "            const static_caps_{d}: []const *rt.Cell = if (static_{d}.env) |env| env.captures else &.{{}};\n", .{ pc, pc });
            try print(out, a, "            const result_{d} = try f_{d}(ctx, static_caps_{d}, argv_{d});\n", .{ pc, inst.a, pc, pc });
        },
        else => return error.NotPlainCall,
    }
}
fn fallthroughBlock(graph: *const graph_mod.Graph, function: *const ir.Function, pc: usize) !u32 {
    const next = pc + 1;
    if (next >= function.insts.items.len) return error.MissingFallthrough;
    return graph.block_of_pc[next];
}

fn emitReturn(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst) !void {
    if (@as(usize, inst.aux) + inst.count > function.operands.items.len) return error.BadOperandRange;
    if (inst.op == .ret) {
        try print(out, a, "            const result = try std.heap.smp_allocator.alloc(rt.Value, {d});\n", .{inst.count});
        for (function.operands.items[inst.aux .. inst.aux + inst.count], 0..) |value, index| {
            try print(out, a, "            result[{d}] = ", .{index});
            try valueExpr(out, a, p, plan, value);
            try text(out, a, ";\n");
        }
        try text(out, a, "            return result;\n");
    } else {
        try print(out, a, "            const tail = frame.multiAt({d});\n", .{inst.a});
        try print(out, a, "            const result = try std.heap.smp_allocator.alloc(rt.Value, {d} + tail.len);\n", .{inst.count});
        for (function.operands.items[inst.aux .. inst.aux + inst.count], 0..) |value, index| {
            try print(out, a, "            result[{d}] = ", .{index});
            try valueExpr(out, a, p, plan, value);
            try text(out, a, ";\n");
        }
        try print(out, a, "            @memcpy(result[{d}..], tail);\n            return result;\n", .{inst.count});
    }
}

fn emitBranchCondition(out: *std.ArrayList(u8), a: A, p: *const ir.Program, plan: *const FunctionPlan, inst: ir.Inst) !void {
    const op = try sem.comparisonOpcode(inst.count);
    const name = try compareName(op);
    if (op == .eq_number or op == .ne_number or op == .lt_number or op == .le_number or op == .gt_number or op == .ge_number) {
        try print(out, a, "rt.numericCompare(.{s}, ", .{name});
        try numberExpr(out, a, p, plan, inst.a);
        try text(out, a, ", ");
        try numberExpr(out, a, p, plan, inst.b);
        try text(out, a, ")");
    } else {
        try print(out, a, "try ctx.comparison(.{s}, ", .{name});
        try valueExpr(out, a, p, plan, inst.a);
        try text(out, a, ", ");
        try valueExpr(out, a, p, plan, inst.b);
        try text(out, a, ")");
    }
}
fn emitTerminator(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, graph: *const graph_mod.Graph, inst: ir.Inst, pc: usize) !void {
    switch (inst.op) {
        .ret, .ret_var => try emitReturn(out, a, p, function, plan, inst),
        .jump => {
            if (inst.aux >= function.insts.items.len) return error.BadJump;
            try print(out, a, "            block = {d};\n", .{graph.block_of_pc[inst.aux]});
        },
        .jump_if_false => {
            const fall = try fallthroughBlock(graph, function, pc);
            if (inst.aux >= function.insts.items.len) return error.BadJump;
            const target = graph.block_of_pc[inst.aux];
            try text(out, a, "            if (!(");
            try valueExpr(out, a, p, plan, inst.a);
            try print(out, a, ").truthy()) block = {d} else block = {d};\n", .{ target, fall });
        },
        .branch_compare => {
            const fall = try fallthroughBlock(graph, function, pc);
            if (inst.aux >= function.insts.items.len) return error.BadJump;
            const target = graph.block_of_pc[inst.aux];
            try text(out, a, "            if (!(");
            try emitBranchCondition(out, a, p, plan, inst);
            try print(out, a, ")) block = {d} else block = {d};\n", .{ target, fall });
        },
        .numeric_for_init => try emitNumericFor(out, a, p, function, plan, graph, inst, pc, false),
        .numeric_for_next => try emitNumericFor(out, a, p, function, plan, graph, inst, pc, true),
        .generic_for_init => try emitGenericFor(out, a, p, function, plan, graph, inst, pc, false),
        .generic_for_next => try emitGenericFor(out, a, p, function, plan, graph, inst, pc, true),
        else => return error.NotTerminator,
    }
}

fn emitNumberSetName(out: *std.ArrayList(u8), a: A, plan: *const FunctionPlan, reg: u32, name: []const u8) !void {
    if (plan.rep(reg) == .number)
        try print(out, a, "n_{d} = {s}; ", .{ reg, name })
    else
        try print(out, a, "frame.set({d}, .{{ .number = {s} }}); ", .{ reg, name });
}
fn emitNumericFor(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, graph: *const graph_mod.Graph, inst: ir.Inst, pc: usize, next: bool) !void {
    if (inst.aux >= function.insts.items.len) return error.BadJump;
    const target = graph.block_of_pc[inst.aux];
    const fall = try fallthroughBlock(graph, function, pc);
    try text(out, a, if (next) "            { var current = " else "            { const current = ");
    try coercedNumberExpr(out, a, p, plan, inst.a);
    try text(out, a, "; const limit = ");
    try coercedNumberExpr(out, a, p, plan, inst.b);
    try text(out, a, "; const step = ");
    try coercedNumberExpr(out, a, p, plan, inst.c);
    try text(out, a, "; ");
    if (next) {
        try text(out, a, "current += step; ");
        try emitNumberSetName(out, a, plan, inst.a, "current");
    }
    try text(out, a, "if ((step > 0 and current <= limit) or (step <= 0 and current >= limit)) { ");
    try emitNumberSetName(out, a, plan, inst.dst, "current");
    try print(out, a, "block = {d}; }} else block = {d}; }}\n", .{ if (next) target else fall, if (next) fall else target });
}
fn emitGenericFor(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, graph: *const graph_mod.Graph, inst: ir.Inst, pc: usize, next: bool) !void {
    if (inst.aux >= function.insts.items.len) return error.BadJump;
    const target = graph.block_of_pc[inst.aux];
    const fall = try fallthroughBlock(graph, function, pc);
    try text(out, a, "            { const iter = ");
    try valueExpr(out, a, p, plan, inst.a);
    try text(out, a, "; const state = ");
    try valueExpr(out, a, p, plan, inst.b);
    try text(out, a, "; const control = ");
    try valueExpr(out, a, p, plan, inst.c);
    try print(out, a, "; const values_{d} = try ctx.callValue(iter, &[_]rt.Value{{ state, control }}); defer rt.freeResults(values_{d}); ", .{ pc, pc });
    try print(out, a, "const first = if (values_{d}.len == 0) rt.Value.nil else values_{d}[0]; ", .{ pc, pc });
    if (!next) {
        try print(out, a, "if (first == .nil) block = {d} else {{ frame.set({d}, first); ", .{ target, inst.c });
        for (0..inst.count) |i| try print(out, a, "frame.set({d}, if ({d} < values_{d}.len) values_{d}[{d}] else .nil); ", .{ inst.dst + @as(u32, @intCast(i)), i, pc, pc, i });
        try print(out, a, "block = {d}; }} }}\n", .{fall});
    } else {
        try print(out, a, "if (first == .nil) block = {d} else {{ frame.set({d}, first); ", .{ fall, inst.c });
        for (0..inst.count) |i| try print(out, a, "frame.set({d}, if ({d} < values_{d}.len) values_{d}[{d}] else .nil); ", .{ inst.dst + @as(u32, @intCast(i)), i, pc, pc, i });
        try print(out, a, "block = {d}; }} }}\n", .{target});
    }
}
fn isControl(op: ir.Opcode) bool {
    return sem.info(op).target or op == .ret or op == .ret_var;
}

fn refNeedsFrame(plan: *const FunctionPlan, value: u32) bool {
    return refs.isRegister(value) and plan.rep(value) != .number;
}

fn requiresFrame(function: *const ir.Function, plan: *const FunctionPlan) !bool {
    for (plan.captured) |captured| if (captured) return true;
    for (function.insts.items) |inst| {
        const info = sem.info(inst.op);
        if (info.defines and inst.dst < plan.reps.len and plan.rep(inst.dst) != .number) return true;
        if (info.results) return true;
        inline for (sem.fields, 0..) |field, index| {
            if (info.reads & (@as(u8, 1) << index) != 0 and refNeedsFrame(plan, @field(inst, field))) return true;
        }
        for (try sem.operands(function, inst)) |value| if (refNeedsFrame(plan, value)) return true;
        switch (inst.op) {
            .vararg, .ret_var, .table_append_var, .closure, .load_function, .detach_cell, .generic_for_init, .generic_for_next => return true,
            .numeric_for_init => if (plan.rep(inst.dst) != .number) return true,
            .numeric_for_next => if (plan.rep(inst.a) != .number or plan.rep(inst.dst) != .number) return true,
            else => {},
        }
    }
    return false;
}
fn emitFunction(out: *std.ArrayList(u8), a: A, p: *const ir.Program, id: u32, stats: *Stats) !void {
    if (id >= p.functions.items.len) return error.BadFunctionReference;
    const function = p.functions.items[id] orelse return error.IncompleteProgram;
    var plan = try analyzePlan(a, p, &function);
    defer plan.deinit();
    var graph = try graph_mod.build(a, &function);
    defer graph.deinit();
    const needs_frame = try requiresFrame(&function, &plan);
    try print(out, a, "fn f_{d}(ctx: *rt.Context, upvalues: []const *rt.Cell, args: []const rt.Value) anyerror![]const rt.Value {{\n", .{id});
    try text(out, a, "    rt.touch(ctx);\n    rt.touch(upvalues);\n    rt.touch(args);\n");
    if (needs_frame) {
        try print(out, a, "    var regs: [{d}]rt.Value = undefined;\n    var cells: [{d}]?*rt.Cell = undefined;\n", .{ function.reg_count, function.reg_count });
        try print(out, a, "    var frame = try rt.Frame.init(&regs, &cells, upvalues, args, {d}, {});\n    defer frame.deinit();\n", .{ function.param_count, function.is_vararg });
    }
    for (plan.reps, 0..) |rep, reg| if (rep == .number) {
        try print(out, a, "    var n_{d}: f64 = undefined;\n", .{reg});
    };
    try text(out, a, "    var block: u32 = 0;\n    _ = &block;\n    while (true) {\n        switch (block) {\n");
    for (graph.blocks.items, 0..) |basic, block_id| {
        try print(out, a, "        {d} => {{\n", .{block_id});
        for (basic.start..basic.end) |pc| {
            const inst = function.insts.items[pc];
            stats.instructions += 1;
            if (pc + 1 == basic.end and isControl(inst.op))
                try emitTerminator(out, a, p, &function, &plan, &graph, inst, pc)
            else
                try emitSimple(out, a, p, &function, &plan, inst, pc, stats);
        }
        const last = if (basic.end != 0) function.insts.items[basic.end - 1] else null;
        if (last == null or !isControl(last.?.op)) {
            var successor: ?u32 = null;
            for (basic.succ) |item| if (item) |next| {
                if (successor != null and successor.? != next) return error.AmbiguousFallthrough;
                successor = next;
            };
            if (successor) |next| try print(out, a, "            block = {d};\n", .{next}) else try text(out, a, "            return &.{};\n");
        }
        try text(out, a, "        },\n");
    }
    try text(out, a, "        else => return error.BadControlFlow,\n        }\n    }\n}\n\n");
    stats.functions += 1;
}
fn emitProgramTables(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    try text(out, a, "const function_table = [_]rt.FunctionFn{\n");
    for (p.functions.items, 0..) |maybe, id| {
        if (maybe == null) return error.IncompleteProgram;
        try print(out, a, "    f_{d},\n", .{id});
    }
    try text(out, a, "};\n");
    try text(out, a, "const module_roots = [_]u32{");
    for (p.module_roots.items, 0..) |root, index| {
        if (index != 0) try text(out, a, ", ");
        try print(out, a, "{d}", .{root});
    }
    try text(out, a, "};\n\n");
}

fn emitRuntimeEntry(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    const globals = globalCount(p);
    try print(out, a, "pub const global_count: u32 = {d};\n", .{globals});
    try print(out, a, "pub const root_function: u32 = {d};\n\n", .{p.root_function});
    try text(out, a, "pub fn initContext(allocator: std.mem.Allocator) !rt.Context {\n" ++
        "    var ctx = try rt.Context.initProgram(allocator, global_count, module_roots.len, function_table.len);\n" ++
        "    ctx.shapes = &shapes;\n" ++
        "    ctx.functions = &function_table;\n");
    const env_slot = global_abi.id("_G");
    if (globals > env_slot) {
        if (p.global_shape) |shape_id| {
            if (shape_id >= p.shapes.items.len) return error.BadGlobalLayout;
            try print(out, a, "    try rt.bindGlobalTable(&ctx, &shapes[{d}], {d});\n", .{ shape_id, env_slot });
        } else {
            try print(out, a, "    try rt.bindGlobalTable(&ctx, null, {d});\n", .{env_slot});
        }
    }
    try text(out, a, "    return ctx;\n}\n\n");
    try print(out, a, "pub fn executeRoot(ctx: *rt.Context, args: []const rt.Value) anyerror![]const rt.Value {{\n    return f_{d}(ctx, &.{{}}, args);\n}}\n\n", .{p.root_function});
}
fn emitEnsureModule(out: *std.ArrayList(u8), a: A) !void {
    try text(out, a, "fn ensureModule(ctx: *rt.Context, module_id: u32) anyerror!void {\n" ++
        "    if (module_id >= module_roots.len or module_id >= ctx.module_state.len) return error.BadModuleId;\n" ++
        "    if (ctx.module_state[module_id] == 2) return;\n" ++
        "    if (ctx.module_state[module_id] == 1) return error.ModuleLoadLoop;\n" ++
        "    ctx.module_state[module_id] = 1;\n" ++
        "    errdefer ctx.module_state[module_id] = 0;\n" ++
        "    const root = module_roots[module_id];\n" ++
        "    if (root >= function_table.len) return error.BadFunctionId;\n" ++
        "    const values = try function_table[root](ctx, &.{}, &.{});\n" ++
        "    rt.freeResults(values);\n" ++
        "    ctx.module_state[module_id] = 2;\n" ++
        "}\n\n");
}

pub fn generate(a: A, p: *const ir.Program) !struct { source: []u8, stats: Stats } {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    if (p.root_function >= p.functions.items.len) return error.BadFunctionReference;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var stats = Stats{};
    try emitDeclarations(&out, a, p);
    try emitShapes(&out, a, p);
    try emitConstants(&out, a, p);
    for (p.functions.items, 0..) |_, id| try emitFunction(&out, a, p, @intCast(id), &stats);
    try emitProgramTables(&out, a, p);
    try emitEnsureModule(&out, a);
    try emitRuntimeEntry(&out, a, p);
    return .{ .source = try out.toOwnedSlice(a), .stats = stats };
}
test "finalized IR emits native Zig without bytecode dispatch" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local function add(a,b)return a+b end;local t={};t.x=4;return add(t.x,3)");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.runAot(a, &p);
    const generated = try generate(a, &p);
    defer a.free(generated.source);
    try std.testing.expect(generated.stats.functions != 0);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "vm_codec") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "inst.op") == null);
}

test "numeric hot loop emits native scalars without a Lua frame" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local s=0;for i=1,100 do s=s+i end;return s");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.runAot(a, &p);
    const generated = try generate(a, &p);
    defer a.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "var n_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "var regs:") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "rt.toNumber(.{ .number") == null);
}

test "constant templates emit static data instead of generated materializer functions" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "return {x=1,{2}}");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.runAot(a, &p);
    const generated = try generate(a, &p);
    defer a.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const constants = [_]rt.Constant") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.materializeConstant(&constants, &constant_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn c_") == null);
}
