const std = @import("std");
const ir = @import("vm_ir.zig");
const refs = @import("vm_ref.zig");
const global_abi = @import("vm_global_abi.zig");
const graph_mod = @import("vm_graph.zig");
const sem = @import("vm_semantics.zig");
const aot_hint = @import("vm_aot_hint.zig");
const static_fields = @import("vm_static_field_abi.zig");
const shape_key = @import("vm_shape_key.zig");
const aot_data = @import("zig_aot_data.zig");

const A = std.mem.Allocator;

pub const Stats = struct {
    functions: u32 = 0,
    instructions: u64 = 0,
    dynamic_calls: u64 = 0,
    guarded_calls: u64 = 0,
    dynamic_indexes: u64 = 0,
    string_fields: u64 = 0,
};
const FunctionRange = struct {
    first: u32,
    end: u32,

    fn contains(self: FunctionRange, id: u32) bool {
        return id >= self.first and id < self.end;
    }
};

const module_root_function = std.math.maxInt(u32);
const module_root_empty = module_root_function - 1;

fn moduleRootValue(p: *const ir.Program, function_id: u32) u32 {
    if (function_id == p.root_function or function_id >= p.functions.items.len) return module_root_function;
    const function = p.functions.items[function_id] orelse return module_root_function;
    if (function.insts.items.len == 1) {
        const ret = function.insts.items[0];
        if (ret.op == .ret and ret.count == 0) return module_root_empty;
        return module_root_function;
    }
    if (function.insts.items.len != 2) return module_root_function;
    const load = function.insts.items[0];
    const ret = function.insts.items[1];
    if (load.op != .load_const or ret.op != .ret or ret.count != 1) return module_root_function;
    if (@as(usize, ret.aux) >= function.operands.items.len or function.operands.items[ret.aux] != load.dst) return module_root_function;
    return if (load.aux < module_root_empty) load.aux else module_root_function;
}

pub fn analyzeModuleRootDescriptors(a: A, p: *const ir.Program, enabled: bool) ![]bool {
    const mask = try a.alloc(bool, p.functions.items.len);
    errdefer a.free(mask);
    @memset(mask, false);
    if (!enabled) return mask;
    for (p.module_roots.items) |root| {
        if (root >= mask.len) return error.BadFunctionReference;
        if (moduleRootValue(p, root) != module_root_function) mask[root] = true;
    }
    for (p.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| if (descriptorTarget(inst)) |target| {
            if (target < mask.len) mask[target] = false;
        };
    };
    return mask;
}

fn descriptorTarget(inst: ir.Inst) ?u32 {
    return switch (inst.op) {
        .closure, .load_function, .register_function => inst.aux,
        .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg => inst.a,
        .call, .call_vararg => aot_hint.target(inst),
        else => null,
    };
}

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

fn finishSource(a: A, out: *std.ArrayList(u8)) ![]u8 {
    var read: usize = 0;
    var write: usize = 0;
    var line_start = true;
    while (read < out.items.len) {
        if (line_start) {
            while (read < out.items.len and (out.items[read] == ' ' or out.items[read] == '\t')) read += 1;
            if (read == out.items.len) break;
        }
        const byte = out.items[read];
        out.items[write] = byte;
        write += 1;
        read += 1;
        line_start = byte == '\n';
    }
    out.items.len = write;
    return out.toOwnedSlice(a);
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
                .number_bits => |bits| try print(out, a, "@as(f64, @bitCast(@as(u64, 0x{x})))", .{bits}),
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
            .table => |table| {
                if (table.shape == ir.no_shape)
                    try print(out, a, ".{{ .table = .{{ .first = {d}, .count = {d} }} }}", .{ table.first, table.count })
                else
                    try print(out, a, ".{{ .table = .{{ .first = {d}, .count = {d}, .shape = {d} }} }}", .{ table.first, table.count, table.shape });
            },
            else => try scalarNodeExpr(out, a, p, node),
        }
        try text(out, a, ",\n");
    }
    try text(out, a, "};\nconst constant_entries = [_]rt.ConstantEntry{\n");
    for (p.const_entries.items) |entry| {
        const encoded = (@as(u64, entry.key) << 32) | entry.value;
        try print(out, a, "    0x{x:0>16},\n", .{encoded});
    }
    try text(out, a, "};\n" ++
        "const constant_blocks = [_]rt.ConstantBlock{.{ .first = 0, .values = &constants }};\n" ++
        "const constant_entry_blocks = [_]rt.ConstantEntryBlock{.{ .first = 0, .values = &constant_entries }};\n\n");
}
fn globalCount(p: *const ir.Program) u32 {
    if (p.global_shape) |shape_id| {
        if (shape_id < p.shapes.items.len) return @max(p.shapes.items[shape_id].field_count, global_abi.count);
    }
    var count: u32 = global_abi.count;
    for (p.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| switch (inst.op) {
            .get_global_slot, .set_global_slot => count = @max(count, inst.aux + 1),
            else => {},
        };
    };
    return count;
}

fn emitNativeGlobalShape(out: *std.ArrayList(u8), a: A) !void {
    try text(out, a, "const native_global_keys = [_]rt.Value{");
    for (global_abi.names, 0..) |name, index| {
        if (index != 0) try text(out, a, ", ");
        try text(out, a, ".{ .string = ");
        try stringLiteral(out, a, name);
        try text(out, a, " }");
    }
    try print(out, a, "}};\nconst native_global_shape = rt.Shape{{ .field_keys = &native_global_keys, .field_count = {d}, .open = false }};\n\n", .{global_abi.count});
}

fn emitShapes(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    for (p.shapes.items, 0..) |shape, id| {
        try print(out, a, "const shape_{d}_keys = [_]rt.Value{{", .{id});
        for (shape.field_keys.items, 0..) |key, index| {
            if (index != 0) try text(out, a, ", ");
            if (shape_key.stringId(key)) |sid| {
                if (sid >= p.strings.items.len) return error.BadStringReference;
                try text(out, a, ".{ .string = ");
                try stringLiteral(out, a, p.strings.items[sid]);
                try text(out, a, " }");
            } else if (shape_key.integerValue(key)) |integer| {
                try print(out, a, ".{{ .number = {d} }}", .{integer});
            } else return error.BadShapeKey;
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

fn emitRootDeclarations(out: *std.ArrayList(u8), a: A, p: *const ir.Program) !void {
    try emitDeclarations(out, a, p);
    try text(out, a, "const lua_stdlib = @import(\"zig_stdlib\");\nconst lua_scribunto = @import(\"zig_scribunto\");\n\n");
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

fn moduleCaptureSlot(function: *const ir.Function, upvalue: u32) !u32 {
    if (upvalue >= function.upvalues.items.len) return error.BadUpvalue;
    const desc = function.upvalues.items[upvalue];
    return if (desc.source == .local) desc.index else std.math.maxInt(u32);
}

fn emitUpvalueCellExpr(out: *std.ArrayList(u8), a: A, function: *const ir.Function, upvalue: u32) !void {
    try print(out, a, "(try upvalues.cell({d}, {d}))", .{ upvalue, try moduleCaptureSlot(function, upvalue) });
}

fn emitCaptures(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, target_id: u32, pc: usize) !void {
    if (target_id >= p.functions.items.len) return error.BadFunctionReference;
    const target = p.functions.items[target_id] orelse return error.IncompleteProgram;
    try print(out, a, "            var captures_{d}: [{d}]*rt.Cell = undefined;\n", .{ pc, target.upvalues.items.len });
    for (target.upvalues.items, 0..) |up, index| switch (up.source) {
        .local => try print(out, a, "            captures_{d}[{d}] = try frame.ensureCell(ctx, {d});\n", .{ pc, index, up.index }),
        .upvalue => {
            try print(out, a, "            captures_{d}[{d}] = ", .{ pc, index });
            try emitUpvalueCellExpr(out, a, function, up.index);
            try text(out, a, ";\n");
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
fn emitSimple(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
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
        } else try print(out, a, "            frame.set({d}, try ctx.materializeConstant({d}));\n", .{ inst.dst, inst.aux }),
        .get_global_slot => try print(out, a, "            frame.set({d}, ctx.getGlobal({d}));\n", .{ inst.dst, inst.aux }),
        .set_global_slot => {
            try print(out, a, "            try ctx.setGlobal({d}, ", .{inst.aux});
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ");\n");
        },
        .get_global, .set_global => return error.UnresolvedStringGlobal,
        .get_upvalue => {
            try print(out, a, "            frame.set({d}, ", .{inst.dst});
            try emitUpvalueCellExpr(out, a, function, inst.a);
            try text(out, a, ".value);\n");
        },
        .set_upvalue => {
            try text(out, a, "            ");
            try emitUpvalueCellExpr(out, a, function, inst.a);
            try text(out, a, ".value = ");
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
        else => try emitSimple2(out, a, p, function, plan, inst, pc, stats, range),
    }
}
fn emitSimple2(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
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
        else => try emitSimple3(out, a, p, function, plan, inst, pc, stats, range),
    }
}
fn emitSimple3(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
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
        .closure => {
            try emitCaptures(out, a, p, function, inst.aux, pc);
            try print(out, a, "            frame.set({d}, try ctx.makeFunction({d}, &captures_{d}));\n", .{ inst.dst, inst.aux, pc });
        },
        .load_function => {
            if (inst.aux >= p.functions.items.len) return error.BadFunctionReference;
            const target = p.functions.items[inst.aux] orelse return error.IncompleteProgram;
            if (target.upvalues.items.len == 0) {
                try print(out, a, "            frame.set({d}, try ctx.makeFunction({d}, &.{{}}));\n", .{ inst.dst, inst.aux });
            } else {
                for (target.upvalues.items) |up| {
                    if (up.source != .local) return error.BadStaticEnvironment;
                    try print(out, a, "            _ = try frame.ensureCell(ctx, {d});\n", .{up.index});
                }
                try print(out, a, "            frame.set({d}, ctx.makeModuleFunction({d}, try frame.ensureModuleEnv(ctx)));\n", .{ inst.dst, inst.aux });
            }
        },
        .register_function => {
            if (inst.aux >= p.function_modules.items.len or inst.aux >= p.functions.items.len) return error.BadFunctionReference;
            const target = p.functions.items[inst.aux] orelse return error.IncompleteProgram;
            if (target.upvalues.items.len != 0)
                try print(out, a, "            try ctx.bindModuleEnv({d}, try frame.ensureModuleEnv(ctx));\n", .{p.function_modules.items[inst.aux]});
        },
        .check_table_key => {
            try text(out, a, "            try rt.validateTableKey(");
            try valueExpr(out, a, p, plan, inst.a);
            try text(out, a, ");\n");
        },
        else => try emitSimple4(out, a, p, function, plan, inst, pc, stats, range),
    }
}
fn emitSimple4(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
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
        else => try emitSimple5(out, a, p, function, plan, inst, pc, stats, range),
    }
}
fn emitSimple5(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
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
        .call, .call_vararg, .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg, .method_call, .method_call_vararg, .method_call_field, .method_call_field_vararg => try emitCall(out, a, p, function, plan, inst, pc, stats, range),
        .init_module => try print(out, a, "            try ctx.ensureModule({d});\n", .{inst.aux}),
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

fn emitCall(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
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
    } else try emitPlainCall(out, a, p, function, plan, inst, pc, stats, range);
    try print(out, a, "            frame.storeResults({d}, {d}, result_{d}, true);\n", .{ inst.dst, inst.count, pc });
    try text(out, a, "            }\n");
}
const NativeFieldPath = struct { root_slot: u32, child_slot: ?u32 = null };
fn nativeFieldPath(namespace: static_fields.Namespace) ?NativeFieldPath {
    return switch (namespace) {
        .table => .{ .root_slot = global_abi.id("table") },
        .string => .{ .root_slot = global_abi.id("string") },
        .math => .{ .root_slot = global_abi.id("math") },
        .debug => .{ .root_slot = global_abi.id("debug") },
        .mw => .{ .root_slot = global_abi.id("mw") },
        .ustring, .title, .text, .uri, .html, .language => .{
            .root_slot = global_abi.id("mw"),
            .child_slot = static_fields.slotForName(.mw, @tagName(namespace)) orelse return null,
        },
        .frame, .title_value, .language_value, .html_node => null,
    };
}

fn nativeFieldCandidateCount(field_id: u32) !u32 {
    const field_ref = try static_fields.encode(field_id);
    var count: u32 = 0;
    inline for (std.meta.fields(static_fields.Namespace)) |field| {
        const namespace: static_fields.Namespace = @enumFromInt(field.value);
        if (comptime !static_fields.isCanonicalLibrary(namespace)) continue;
        if (static_fields.slotForRef(namespace, field_ref) != null) count += 1;
    }
    return count;
}

fn emitNativeFieldCandidateGuards(out: *std.ArrayList(u8), a: A, field_id: u32) !void {
    const field_ref = try static_fields.encode(field_id);
    var first = true;
    inline for (std.meta.fields(static_fields.Namespace)) |field| {
        const namespace: static_fields.Namespace = @enumFromInt(field.value);
        if (comptime !static_fields.isCanonicalLibrary(namespace)) continue;
        const slot = static_fields.slotForRef(namespace, field_ref);
        if (slot != null) {
            const path = comptime nativeFieldPath(namespace).?;
            if (!first) try text(out, a, ", ");
            first = false;
            try print(out, a, ".{{ .namespace = .{s}, .slot = {d}, .root = ctx.getGlobal({d}), .child_slot = ", .{ @tagName(namespace), slot.?, path.root_slot });
            if (path.child_slot) |child| try print(out, a, "{d}", .{child}) else try text(out, a, "null");
            try text(out, a, " }");
        }
    }
}

fn emitPlainCall(out: *std.ArrayList(u8), a: A, p: *const ir.Program, function: *const ir.Function, plan: *const FunctionPlan, inst: ir.Inst, pc: usize, stats: *Stats, range: ?FunctionRange) !void {
    switch (inst.op) {
        .call, .call_vararg => {
            if (aot_hint.target(inst)) |target| {
                if (target >= p.functions.items.len) return error.BadFunctionReference;
                if (p.functions.items[target] != null and (range == null or range.?.contains(target))) {
                    try print(out, a, "            const result_{d} = try ctx.callKnownDirect(", .{pc});
                    try valueExpr(out, a, p, plan, inst.a);
                    try print(out, a, ", {d}, f_{d}, argv_{d});\n", .{ target, target, pc });
                } else {
                    try print(out, a, "            const result_{d} = try ctx.callKnown(", .{pc});
                    try valueExpr(out, a, p, plan, inst.a);
                    try print(out, a, ", {d}, argv_{d});\n", .{ target, pc });
                }
                stats.guarded_calls += 1;
            } else if (aot_hint.nativeGlobal(inst)) |slot| {
                if (slot >= global_abi.count) return error.BadGlobalReference;
                try print(out, a, "            const result_{d} = try ctx.callKnownNative(", .{pc});
                try valueExpr(out, a, p, plan, inst.a);
                try print(out, a, ", ctx.getGlobal({d}), argv_{d});\n", .{ slot, pc });
                stats.guarded_calls += 1;
            } else if (aot_hint.nativeField(inst)) |field| {
                if (field.slot >= static_fields.fieldCount(field.namespace)) return error.BadStaticField;
                if (nativeFieldPath(field.namespace)) |path| {
                    try print(out, a, "            const result_{d} = try ctx.callKnownNativeField(", .{pc});
                    try valueExpr(out, a, p, plan, inst.a);
                    try print(out, a, ", .{s}, {d}, ctx.getGlobal({d}), ", .{ @tagName(field.namespace), field.slot, path.root_slot });
                    if (path.child_slot) |child| try print(out, a, "{d}", .{child}) else try text(out, a, "null");
                    try print(out, a, ", argv_{d});\n", .{pc});
                    stats.guarded_calls += 1;
                } else {
                    try print(out, a, "            const result_{d} = try ctx.callValue(", .{pc});
                    try valueExpr(out, a, p, plan, inst.a);
                    try print(out, a, ", argv_{d});\n", .{pc});
                }
            } else if (aot_hint.nativeFieldCandidate(inst)) |field_id| {
                if (field_id >= static_fields.names.len) return error.BadStaticField;
                if (try nativeFieldCandidateCount(field_id) != 0) {
                    try print(out, a, "            const result_{d} = try ctx.callKnownNativeFieldCandidates(", .{pc});
                    try valueExpr(out, a, p, plan, inst.a);
                    try text(out, a, ", &.{");
                    try emitNativeFieldCandidateGuards(out, a, field_id);
                    try print(out, a, "}}, argv_{d});\n", .{pc});
                    stats.guarded_calls += 1;
                } else {
                    try print(out, a, "            const result_{d} = try ctx.callValue(", .{pc});
                    try valueExpr(out, a, p, plan, inst.a);
                    try print(out, a, ", argv_{d});\n", .{pc});
                }
            } else {
                try print(out, a, "            const result_{d} = try ctx.callValue(", .{pc});
                try valueExpr(out, a, p, plan, inst.a);
                try print(out, a, ", argv_{d});\n", .{pc});
            }
            stats.dynamic_calls += 1;
        },
        .call_local, .call_local_vararg => {
            if (inst.a >= p.functions.items.len) return error.BadFunctionReference;
            if (range == null or range.?.contains(inst.a))
                try print(out, a, "            const result_{d} = try f_{d}(ctx, .{{ .direct = &.{{}} }}, argv_{d});\n", .{ pc, inst.a, pc })
            else
                try print(out, a, "            const result_{d} = try ctx.invokeKnown({d}, .{{ .direct = &.{{}} }}, argv_{d});\n", .{ pc, inst.a, pc });
        },
        .call_scoped, .call_scoped_vararg => {
            try emitCaptures(out, a, p, function, inst.a, pc);
            if (range == null or range.?.contains(inst.a))
                try print(out, a, "            const result_{d} = try f_{d}(ctx, .{{ .direct = &captures_{d} }}, argv_{d});\n", .{ pc, inst.a, pc, pc })
            else
                try print(out, a, "            const result_{d} = try ctx.invokeKnown({d}, .{{ .direct = &captures_{d} }}, argv_{d});\n", .{ pc, inst.a, pc, pc });
        },
        .direct_call, .direct_call_vararg => {
            if (inst.a >= p.functions.items.len or p.function_modules.items.len != p.functions.items.len) return error.BadFunctionReference;
            const module_id = p.function_modules.items[inst.a];
            const target = p.functions.items[inst.a] orelse return error.IncompleteProgram;
            try print(out, a, "            try ctx.ensureModule({d});\n", .{module_id});
            if (target.upvalues.items.len == 0)
                try print(out, a, "            const static_caps_{d}: rt.Captures = .{{ .direct = &.{{}} }};\n", .{pc})
            else
                try print(out, a, "            const static_caps_{d} = try ctx.moduleCaptures({d});\n", .{ pc, module_id });
            if (range == null or range.?.contains(inst.a))
                try print(out, a, "            const result_{d} = try f_{d}(ctx, static_caps_{d}, argv_{d});\n", .{ pc, inst.a, pc, pc })
            else
                try print(out, a, "            const result_{d} = try ctx.invokeKnown({d}, static_caps_{d}, argv_{d});\n", .{ pc, inst.a, pc, pc });
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
    try text(out, a, "            { const iter: rt.Value = ");
    try valueExpr(out, a, p, plan, inst.a);
    try text(out, a, "; const state: rt.Value = ");
    try valueExpr(out, a, p, plan, inst.b);
    try text(out, a, "; const control: rt.Value = ");
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
fn emitFunction(out: *std.ArrayList(u8), a: A, p: *const ir.Program, id: u32, stats: *Stats, range: ?FunctionRange) !void {
    if (id >= p.functions.items.len) return error.BadFunctionReference;
    const function = p.functions.items[id] orelse return error.IncompleteProgram;
    var plan = try analyzePlan(a, p, &function);
    defer plan.deinit();
    var graph = try graph_mod.build(a, &function);
    defer graph.deinit();
    const needs_frame = try requiresFrame(&function, &plan);
    try print(out, a, "{s}fn f_{d}(ctx: *rt.Context, upvalues: rt.Captures, args: []const rt.Value) anyerror![]const rt.Value {{\n", .{ if (range == null) "" else "pub ", id });
    try text(out, a, "    rt.touch(ctx);\n    rt.touch(upvalues);\n    rt.touch(args);\n");
    if (needs_frame) {
        try print(out, a, "    var regs: [{d}]rt.Value = undefined;\n    var cells: [{d}]?*rt.Cell = undefined;\n", .{ function.reg_count, function.reg_count });
        try print(out, a, "    var frame = try rt.Frame.init(&regs, &cells, args, {d}, {});\n    defer frame.deinit();\n", .{ function.param_count, function.is_vararg });
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
                try emitSimple(out, a, p, &function, &plan, inst, pc, stats, range);
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
    try print(out, a, "const function_table = blk: {{\n    @setEvalBranchQuota({d});\n    break :blk [_]rt.FunctionFn{{\n", .{p.functions.items.len * 4 + 1000});
    for (p.functions.items, 0..) |maybe, id| {
        if (maybe == null) return error.IncompleteProgram;
        try print(out, a, "        rt.stabilize(f_{d}),\n", .{id});
    }
    try text(out, a, "    };\n};\nconst function_blocks = [_]rt.FunctionBlock{.{ .first = 0, .values = &function_table }};\n");
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
        "    var ctx = try rt.Context.initProgram(allocator, global_count, module_roots.len);\n" ++
        "    ctx.shapes = &shapes;\n" ++
        "    ctx.function_blocks = &function_blocks;\n" ++
        "    ctx.constant_blocks = &constant_blocks;\n" ++
        "    ctx.constant_entry_blocks = &constant_entry_blocks;\n" ++
        "    ctx.module_roots = &module_roots;\n");
    const env_slot = global_abi.id("_G");
    if (globals > env_slot) {
        if (p.global_shape) |shape_id| {
            if (shape_id >= p.shapes.items.len) return error.BadGlobalLayout;
            try print(out, a, "    try rt.bindGlobalTable(&ctx, &shapes[{d}], {d});\n", .{ shape_id, env_slot });
        } else {
            try print(out, a, "    try rt.bindGlobalTable(&ctx, &native_global_shape, {d});\n", .{env_slot});
        }
    }
    try text(out, a, "    try lua_stdlib.install(&ctx);\n");
    try print(out, a, "    try lua_scribunto.install(&ctx, {d}, {d}, {d});\n", .{ global_abi.id("_G"), global_abi.id("string"), global_abi.id("mw") });
    try text(out, a, "    return ctx;\n}\n\n");
    try text(out, a, "pub const Host = lua_scribunto.Host;\npub const FrameArg = lua_scribunto.FrameArg;\npub const WikitextProvider = lua_scribunto.WikitextProvider;\npub const WikitextExpander = lua_scribunto.WikitextExpander;\npub fn setHost(ctx: *rt.Context, host: ?*Host) void { lua_scribunto.setHost(ctx, host); }\npub fn makeFrame(ctx: *rt.Context, title: []const u8, args: []const FrameArg, parent: ?rt.Value) !rt.Value { return lua_scribunto.makeFrame(ctx, title, args, parent); }\npub fn invoke(ctx: *rt.Context, module_name: []const u8, function_name: []const u8, frame: rt.Value) anyerror![]const rt.Value { return lua_scribunto.invoke(ctx, module_name, function_name, frame); }\npub fn initExpander(ctx: *rt.Context, provider: WikitextProvider) WikitextExpander { return lua_scribunto.makeWikitextExpander(ctx, 0, 18, 23, provider); }\n\n");
    try print(out, a, "pub fn executeRoot(ctx: *rt.Context, args: []const rt.Value) anyerror![]const rt.Value {{\n    return f_{d}(ctx, .{{ .direct = &.{{}} }}, args);\n}}\n\n", .{p.root_function});
}
pub fn generate(a: A, p: *const ir.Program) !struct { source: []u8, stats: Stats } {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    if (p.root_function >= p.functions.items.len) return error.BadFunctionReference;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var stats = Stats{};
    try emitRootDeclarations(&out, a, p);
    try emitNativeGlobalShape(&out, a);
    try emitShapes(&out, a, p);
    try emitConstants(&out, a, p);
    for (p.functions.items, 0..) |_, id| try emitFunction(&out, a, p, @intCast(id), &stats, null);
    try emitProgramTables(&out, a, p);
    try emitRuntimeEntry(&out, a, p);
    return .{ .source = try finishSource(a, &out), .stats = stats };
}

test "generated source strips indentation without changing line structure" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "  alpha\n\tbeta\n    gamma\n");
    const compact = try finishSource(allocator, &out);
    defer allocator.free(compact);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", compact);
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
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const lua_stdlib = @import(\"zig_stdlib\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const lua_scribunto = @import(\"zig_scribunto\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "try lua_stdlib.install(&ctx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "try lua_scribunto.install(&ctx, 0, 18, 23)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const Host = lua_scribunto.Host") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn setHost(ctx: *rt.Context, host: ?*Host)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const FrameArg = lua_scribunto.FrameArg") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const WikitextProvider = lua_scribunto.WikitextProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn initExpander(ctx: *rt.Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn makeFrame(ctx: *rt.Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn invoke(ctx: *rt.Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const native_global_keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "&native_global_shape") != null);
    try std.testing.expect(globalCount(&p) >= global_abi.count);
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

test "generic for boxes numeric scalar iterator operands as runtime values" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local function f(t) if #t == 1 then return t end; for x in #t do return x end end; return f");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.runAot(a, &p);
    const generated = try generate(a, &p);
    defer a.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const iter: rt.Value = .{ .number = n_") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const state: rt.Value =") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const control: rt.Value =") != null);
}

test "constant templates emit static data instead of generated materializer functions" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local e={numbers={}};e.numbers[1]=4;e.numbers[2]=5;return e.numbers[1],e.numbers[2]");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.runAot(a, &p);
    const generated = try generate(a, &p);
    defer a.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "const constants = [_]rt.Constant") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.materializeConstant") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".shape = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "fn c_") == null);
}

pub fn generateProgramData(a: A, p: *const ir.Program) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    var string_bytes: usize = 0;
    for (p.constants.items) |node| switch (node) {
        .string => |sid| {
            if (sid >= p.strings.items.len) return error.BadStringReference;
            string_bytes = std.math.add(usize, string_bytes, p.strings.items[sid].len) catch return error.ProgramDataTooLarge;
        },
        .number => return error.LegacyNumberConstant,
        else => {},
    };
    const l = try aot_data.layout(p.constants.items.len, p.const_entries.items.len, string_bytes);
    const out = try a.alloc(u8, l.total);
    errdefer a.free(out);
    @memset(out, 0);
    try aot_data.writeHeader(out, l);

    var string_at: usize = 0;
    for (p.constants.items, 0..) |node, id| {
        switch (node) {
            .nil => try aot_data.writeRecord(out, l, id, .nil, 0, 0),
            .boolean => |value| try aot_data.writeRecord(out, l, id, .boolean, @intFromBool(value), 0),
            .number_bits => |bits| try aot_data.writeRecord(out, l, id, .number, bits, 0),
            .integer => |value| try aot_data.writeRecord(out, l, id, .number, @bitCast(@as(f64, @floatFromInt(value))), 0),
            .string => |sid| {
                if (sid >= p.strings.items.len) return error.BadStringReference;
                const value = p.strings.items[sid];
                try aot_data.writeRecord(out, l, id, .string, string_at, value.len);
                @memcpy(out[l.strings_offset + string_at ..][0..value.len], value);
                string_at += value.len;
            },
            .table => |table| {
                const encoded = (@as(u64, table.count) << 32) | table.first;
                try aot_data.writeRecord(out, l, id, .table, encoded, table.shape);
            },
            .number => return error.LegacyNumberConstant,
        }
    }
    if (string_at != string_bytes) return error.ProgramDataSizeMismatch;
    for (p.const_entries.items, 0..) |entry, id|
        try aot_data.writeEntry(out, l, id, (@as(u64, entry.key) << 32) | entry.value);
    return out;
}

pub const ShardConfig = struct {
    functions_per_shard: usize = 1024,
    constants_per_shard: usize = 131072,
    entries_per_shard: usize = 262144,
    module_registry: bool = false,
    external_data: bool = false,
    external_functions: bool = false,
};

fn shardCount(total: usize, per_shard: usize) !usize {
    if (per_shard == 0) return error.InvalidShardSize;
    return if (total == 0) 0 else 1 + (total - 1) / per_shard;
}

fn shardBounds(total: usize, per_shard: usize, shard_index: usize) !struct { first: usize, end: usize } {
    const count = try shardCount(total, per_shard);
    if (shard_index >= count) return error.BadShardIndex;
    const first = std.math.mul(usize, shard_index, per_shard) catch return error.BadShardIndex;
    return .{ .first = first, .end = @min(first + per_shard, total) };
}

pub fn functionShardCount(p: *const ir.Program, config: ShardConfig) !usize {
    return shardCount(p.functions.items.len, config.functions_per_shard);
}

pub fn constantShardCount(p: *const ir.Program, config: ShardConfig) !usize {
    return shardCount(p.constants.items.len, config.constants_per_shard);
}

pub fn entryShardCount(p: *const ir.Program, config: ShardConfig) !usize {
    return shardCount(p.const_entries.items.len, config.entries_per_shard);
}

pub fn generateFunctionShard(a: A, p: *const ir.Program, config: ShardConfig, shard_index: usize, stats: *Stats) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    const descriptor_roots = try analyzeModuleRootDescriptors(a, p, config.module_registry);
    defer a.free(descriptor_roots);
    return generateFunctionShardWithDescriptors(a, p, config, descriptor_roots, shard_index, stats);
}

pub fn generateFunctionShardWithDescriptors(a: A, p: *const ir.Program, config: ShardConfig, descriptor_roots: []const bool, shard_index: usize, stats: *Stats) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    if (descriptor_roots.len != p.functions.items.len) return error.BadDescriptorRootMask;
    const bounds = try shardBounds(p.functions.items.len, config.functions_per_shard, shard_index);
    const first: u32 = std.math.cast(u32, bounds.first) orelse return error.ProgramTooLarge;
    const end: u32 = std.math.cast(u32, bounds.end) orelse return error.ProgramTooLarge;
    const range = FunctionRange{ .first = first, .end = end };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try emitDeclarations(&out, a, p);
    for (bounds.first..bounds.end) |id| {
        if (config.module_registry and descriptor_roots[id]) {
            const function = p.functions.items[id] orelse return error.IncompleteProgram;
            stats.functions += 1;
            stats.instructions += function.insts.items.len;
        } else try emitFunction(&out, a, p, @intCast(id), stats, range);
    }
    try print(&out, a, "pub const functions = blk: {{\n    @setEvalBranchQuota({d});\n    break :blk [_]rt.FunctionFn{{\n", .{(bounds.end - bounds.first) * 4 + 1000});
    for (bounds.first..bounds.end) |id| {
        if (config.module_registry and descriptor_roots[id])
            try text(&out, a, "        rt.stabilize(rt.descriptorModuleRootStub),\n")
        else
            try print(&out, a, "        rt.stabilize(f_{d}),\n", .{id});
    }
    try text(&out, a, "    };\n};\n");
    if (config.external_functions) {
        try print(&out, a, "pub export const dict_aot_functions_{d:0>4}: [functions.len]*const anyopaque = blk: {{\n", .{shard_index});
        try text(&out, a, "    @setEvalBranchQuota(functions.len * 4 + 1000);\n    var values: [functions.len]*const anyopaque = undefined;\n    for (functions, 0..) |function, index| values[index] = @ptrCast(function);\n    break :blk values;\n};\n");
    }
    return finishSource(a, &out);
}

pub fn generateConstantShard(a: A, p: *const ir.Program, config: ShardConfig, shard_index: usize) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    const bounds = try shardBounds(p.constants.items.len, config.constants_per_shard, shard_index);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try text(&out, a, "const rt = @import(\"zig_runtime\");\n\npub const constants = [_]rt.Constant{\n");
    for (p.constants.items[bounds.first..bounds.end]) |node| {
        try text(&out, a, "    ");
        switch (node) {
            .table => |table| {
                if (table.shape == ir.no_shape)
                    try print(&out, a, ".{{ .table = .{{ .first = {d}, .count = {d} }} }}", .{ table.first, table.count })
                else
                    try print(&out, a, ".{{ .table = .{{ .first = {d}, .count = {d}, .shape = {d} }} }}", .{ table.first, table.count, table.shape });
            },
            else => try scalarNodeExpr(&out, a, p, node),
        }
        try text(&out, a, ",\n");
    }
    try text(&out, a, "};\n");
    return finishSource(a, &out);
}

pub fn generateEntryShard(a: A, p: *const ir.Program, config: ShardConfig, shard_index: usize) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    const bounds = try shardBounds(p.const_entries.items.len, config.entries_per_shard, shard_index);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try text(&out, a, "const rt = @import(\"zig_runtime\");\n\npub const entries = [_]rt.ConstantEntry{\n");
    for (p.const_entries.items[bounds.first..bounds.end]) |entry| {
        const encoded = (@as(u64, entry.key) << 32) | entry.value;
        try print(&out, a, "    0x{x:0>16},\n", .{encoded});
    }
    try text(&out, a, "};\n");
    return finishSource(a, &out);
}

pub fn generateShardedRoot(a: A, p: *const ir.Program, config: ShardConfig) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    const descriptor_roots = try analyzeModuleRootDescriptors(a, p, config.module_registry);
    defer a.free(descriptor_roots);
    return generateShardedRootWithDescriptors(a, p, config, descriptor_roots);
}

pub fn generateShardedRootWithDescriptors(a: A, p: *const ir.Program, config: ShardConfig, descriptor_roots: []const bool) ![]u8 {
    if (!p.references_lowered) return error.ProgramNotFinalized;
    if (p.root_function >= p.functions.items.len) return error.BadFunctionReference;
    if (descriptor_roots.len != p.functions.items.len) return error.BadDescriptorRootMask;
    const function_shards = try functionShardCount(p, config);
    const constant_shards = if (config.external_data) 0 else try constantShardCount(p, config);
    const entry_shards = if (config.external_data) 0 else try entryShardCount(p, config);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try emitRootDeclarations(&out, a, p);
    if (config.module_registry) try text(&out, a, "const module_registry = @import(\"module_registry.zig\");\n\n");
    try emitNativeGlobalShape(&out, a);
    if (config.external_functions) {
        for (0..function_shards) |index| {
            const bounds = try shardBounds(p.functions.items.len, config.functions_per_shard, index);
            const count = bounds.end - bounds.first;
            try print(&out, a, "extern const dict_aot_functions_{d:0>4}: [{d}]*const anyopaque;\n", .{ index, count });
            try print(&out, a, "const function_values_{d:0>4}: *const [{d}]rt.FunctionFn = @ptrCast(&dict_aot_functions_{d:0>4});\n", .{ index, count, index });
        }
    } else for (0..function_shards) |index|
        try print(&out, a, "const functions_{d:0>4} = @import(\"functions_{d:0>4}.zig\");\n", .{ index, index });
    for (0..constant_shards) |index|
        try print(&out, a, "const constants_{d:0>4} = @import(\"constants_{d:0>4}.zig\");\n", .{ index, index });
    for (0..entry_shards) |index|
        try print(&out, a, "const entries_{d:0>4} = @import(\"entries_{d:0>4}.zig\");\n", .{ index, index });
    try text(&out, a, "\n");
    try emitShapes(&out, a, p);

    try text(&out, a, "const function_blocks = [_]rt.FunctionBlock{\n");
    for (0..function_shards) |index| {
        const bounds = try shardBounds(p.functions.items.len, config.functions_per_shard, index);
        if (config.external_functions)
            try print(&out, a, "    .{{ .first = {d}, .values = function_values_{d:0>4} }},\n", .{ bounds.first, index })
        else
            try print(&out, a, "    .{{ .first = {d}, .values = &functions_{d:0>4}.functions }},\n", .{ bounds.first, index });
    }
    try text(&out, a, "};\nconst constant_blocks = [_]rt.ConstantBlock{\n");
    for (0..constant_shards) |index| {
        const bounds = try shardBounds(p.constants.items.len, config.constants_per_shard, index);
        try print(&out, a, "    .{{ .first = {d}, .values = &constants_{d:0>4}.constants }},\n", .{ bounds.first, index });
    }
    try text(&out, a, "};\nconst constant_entry_blocks = [_]rt.ConstantEntryBlock{\n");
    for (0..entry_shards) |index| {
        const bounds = try shardBounds(p.const_entries.items.len, config.entries_per_shard, index);
        try print(&out, a, "    .{{ .first = {d}, .values = &entries_{d:0>4}.entries }},\n", .{ bounds.first, index });
    }
    try text(&out, a, "};\nconst module_roots = [_]u32{");
    for (p.module_roots.items, 0..) |root, index| {
        if (index != 0) try text(&out, a, ", ");
        try print(&out, a, "{d}", .{root});
    }
    try text(&out, a, "};\n");
    if (config.module_registry) {
        try text(&out, a, "const module_root_values = [_]u32{");
        for (p.module_roots.items, 0..) |root, index| {
            if (root >= descriptor_roots.len) return error.BadFunctionReference;
            if (index != 0) try text(&out, a, ", ");
            const value = if (descriptor_roots[root]) moduleRootValue(p, root) else module_root_function;
            if (value == module_root_function)
                try text(&out, a, "rt.module_root_function")
            else if (value == module_root_empty)
                try text(&out, a, "rt.module_root_empty")
            else
                try print(&out, a, "{d}", .{value});
        }
        try text(&out, a, "};\n");
    }
    try text(&out, a, "\n");

    const globals = globalCount(p);
    try print(&out, a, "pub const global_count: u32 = {d};\n", .{globals});
    try print(&out, a, "pub const root_function: u32 = {d};\n", .{p.root_function});
    try print(&out, a, "pub const requires_program_data = {};\n\n", .{config.external_data});
    try text(&out, a, "fn initContextImpl(allocator: std.mem.Allocator, program_data: ?rt.ProgramData) !rt.Context {\n");
    try text(&out, a, "    var ctx = try rt.Context.initProgram(allocator, global_count, module_roots.len);\n");
    if (config.external_data)
        try text(&out, a, "    ctx.program_data = program_data orelse return error.ExternalProgramDataRequired;\n")
    else
        try text(&out, a, "    if (program_data) |value| ctx.program_data = value;\n");
    try text(
        &out,
        a,
        "    ctx.shapes = &shapes;\n" ++
            "    ctx.function_blocks = &function_blocks;\n" ++
            "    ctx.constant_blocks = &constant_blocks;\n" ++
            "    ctx.constant_entry_blocks = &constant_entry_blocks;\n" ++
            "    ctx.module_roots = &module_roots;\n",
    );
    if (config.module_registry) try text(&out, a, "    ctx.module_root_values = &module_root_values;\n");
    const env_slot = global_abi.id("_G");
    if (globals > env_slot) {
        if (p.global_shape) |shape_id| {
            if (shape_id >= p.shapes.items.len) return error.BadGlobalLayout;
            try print(&out, a, "    try rt.bindGlobalTable(&ctx, &shapes[{d}], {d});\n", .{ shape_id, env_slot });
        } else {
            try print(&out, a, "    try rt.bindGlobalTable(&ctx, &native_global_shape, {d});\n", .{env_slot});
        }
    }
    try text(&out, a, "    try lua_stdlib.install(&ctx);\n");
    try print(&out, a, "    try lua_scribunto.install(&ctx, {d}, {d}, {d});\n", .{ global_abi.id("_G"), global_abi.id("string"), global_abi.id("mw") });
    if (config.module_registry) try text(&out, a, "    module_registry.registry.configure(&ctx);\n");
    try text(&out, a, "    return ctx;\n}\n");
    if (config.external_data)
        try text(&out, a, "pub fn initContext(_: std.mem.Allocator) !rt.Context { return error.ExternalProgramDataRequired; }\n")
    else
        try text(&out, a, "pub fn initContext(allocator: std.mem.Allocator) !rt.Context { return initContextImpl(allocator, null); }\n");
    try text(&out, a, "pub fn initContextWithData(allocator: std.mem.Allocator, program_data: rt.ProgramData) !rt.Context { return initContextImpl(allocator, program_data); }\n\n");
    try text(&out, a, "pub const Host = lua_scribunto.Host;\npub const FrameArg = lua_scribunto.FrameArg;\npub const WikitextProvider = lua_scribunto.WikitextProvider;\npub const WikitextExpander = lua_scribunto.WikitextExpander;\npub fn setHost(ctx: *rt.Context, host: ?*Host) void { lua_scribunto.setHost(ctx, host); }\npub fn makeFrame(ctx: *rt.Context, title: []const u8, args: []const FrameArg, parent: ?rt.Value) !rt.Value { return lua_scribunto.makeFrame(ctx, title, args, parent); }\npub fn invoke(ctx: *rt.Context, module_name: []const u8, function_name: []const u8, frame: rt.Value) anyerror![]const rt.Value { return lua_scribunto.invoke(ctx, module_name, function_name, frame); }\npub fn initExpander(ctx: *rt.Context, provider: WikitextProvider) WikitextExpander { return lua_scribunto.makeWikitextExpander(ctx, 0, 18, 23, provider); }\n\n");
    try text(&out, a, "pub fn executeRoot(ctx: *rt.Context, args: []const rt.Value) anyerror![]const rt.Value {\n    return ctx.invokeKnown(root_function, .{ .direct = &.{} }, args);\n}\n");
    return finishSource(a, &out);
}

test "sharded AOT splits code and data while preserving numeric cross-shard calls" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local function make() return {x=4,{y=7}} end; local a=make(); local b=make(); return a.x,a[1].y,a==b,a[1]==b[1]");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    const config = ShardConfig{ .functions_per_shard = 1, .constants_per_shard = 2, .entries_per_shard = 1 };
    try std.testing.expect(try functionShardCount(&program, config) >= 2);
    try std.testing.expect(try constantShardCount(&program, config) >= 2);

    const root = try generateShardedRoot(allocator, &program, config);
    defer allocator.free(root);
    try std.testing.expect(std.mem.indexOf(u8, root, "functions_0000.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "constant_blocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "module_root_values") == null);
    try std.testing.expect(std.mem.indexOf(u8, root, "ctx.invokeKnown(root_function") != null);
    const registry_root = try generateShardedRoot(allocator, &program, .{ .functions_per_shard = 1, .constants_per_shard = 2, .entries_per_shard = 1, .module_registry = true });
    defer allocator.free(registry_root);
    try std.testing.expect(std.mem.indexOf(u8, registry_root, "@import(\"module_registry.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_root, "module_root_values") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_root, "module_registry.registry.configure(&ctx)") != null);

    const external_config = ShardConfig{ .functions_per_shard = 1, .constants_per_shard = 2, .entries_per_shard = 1, .module_registry = true, .external_data = true, .external_functions = true };
    const external_root = try generateShardedRoot(allocator, &program, external_config);
    defer allocator.free(external_root);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "constants_0000.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "entries_0000.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "@import(\"functions_0000.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "extern const dict_aot_functions_0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "function_values_0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "pub const requires_program_data = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, external_root, "pub fn initContextWithData") != null);
    const external_data = try generateProgramData(allocator, &program);
    defer allocator.free(external_data);
    const external_view = try aot_data.View.parse(external_data);
    try std.testing.expectEqual(program.constants.items.len, external_view.layout.constant_count);
    try std.testing.expectEqual(program.const_entries.items.len, external_view.layout.entry_count);

    var stats = Stats{};
    const first = try generateFunctionShard(allocator, &program, config, 0, &stats);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "pub fn f_") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "rt.stabilize(f_") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "@setEvalBranchQuota") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "ctx.invokeKnown(") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "vm_codec") == null);
    var external_stats = Stats{};
    const external_first = try generateFunctionShard(allocator, &program, external_config, 0, &external_stats);
    defer allocator.free(external_first);
    try std.testing.expect(std.mem.indexOf(u8, external_first, "pub export const dict_aot_functions_0000") != null);

    const constants = try generateConstantShard(allocator, &program, config, 0);
    defer allocator.free(constants);
    try std.testing.expect(std.mem.indexOf(u8, constants, "pub const constants") != null);
    if (try entryShardCount(&program, config) != 0) {
        const entries = try generateEntryShard(allocator, &program, config, 0);
        defer allocator.free(entries);
        try std.testing.expect(std.mem.indexOf(u8, entries, "pub const entries") != null);
    }
}

test "sharded module registry replaces constant-only roots with descriptors" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const data = @import("vm_data.zig");
    const link = @import("vm_link_image.zig");
    const allocator = std.testing.allocator;
    var image = link.Image.init(allocator);
    defer image.deinit();

    for ([_][]const u8{ "local function f() return 1 end; return f", "return {x=1,y=2}" }) |source| {
        var chunk = try lua.parse(allocator, source);
        defer chunk.deinit();
        var module = try ir.lowerChunk(allocator, &chunk);
        defer module.deinit();
        _ = try opt.runSemantics(allocator, &module);
        _ = try data.run(allocator, &module);
        _ = try image.appendModule(&module);
    }
    _ = try data.run(allocator, &image.program);
    _ = try opt.finalizeAot(allocator, &image.program);
    const descriptor_id = image.program.module_roots.items[1];
    const descriptor_value = moduleRootValue(&image.program, descriptor_id);
    try std.testing.expect(descriptor_value != module_root_function and descriptor_value != module_root_empty);

    const config = ShardConfig{ .functions_per_shard = 64, .constants_per_shard = 64, .entries_per_shard = 64, .module_registry = true };
    const descriptor_roots = try analyzeModuleRootDescriptors(allocator, &image.program, true);
    defer allocator.free(descriptor_roots);
    try std.testing.expect(descriptor_roots[descriptor_id]);
    const root = try generateShardedRootWithDescriptors(allocator, &image.program, config, descriptor_roots);
    defer allocator.free(root);
    try std.testing.expect(std.mem.indexOf(u8, root, "const module_root_values") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "ctx.module_root_values = &module_root_values") != null);

    var stats = Stats{};
    const shard = try generateFunctionShardWithDescriptors(allocator, &image.program, config, descriptor_roots, 0, &stats);
    defer allocator.free(shard);
    const declaration = try std.fmt.allocPrint(allocator, "pub fn f_{d}(", .{descriptor_id});
    defer allocator.free(declaration);
    try std.testing.expect(std.mem.indexOf(u8, shard, declaration) == null);
    try std.testing.expect(std.mem.indexOf(u8, shard, "rt.descriptorModuleRootStub") != null);

    const observer_id = image.program.module_roots.items[0];
    const observer = &image.program.functions.items[observer_id].?;
    var vararg_call = ir.Inst{ .op = .call_vararg, .a = 0, .c = 0 };
    try aot_hint.set(&vararg_call, descriptor_id);
    try observer.insts.append(allocator, vararg_call);
    const vararg_mask = try analyzeModuleRootDescriptors(allocator, &image.program, true);
    defer allocator.free(vararg_mask);
    try std.testing.expect(!vararg_mask[descriptor_id]);
    _ = observer.insts.pop();
    try image.program.functions.items[observer_id].?.insts.append(allocator, .{ .op = .register_function, .a = 0, .aux = descriptor_id });
    const fallback_mask = try analyzeModuleRootDescriptors(allocator, &image.program, true);
    defer allocator.free(fallback_mask);
    try std.testing.expect(!fallback_mask[descriptor_id]);
    var fallback_stats = Stats{};
    const fallback_shard = try generateFunctionShardWithDescriptors(allocator, &image.program, config, fallback_mask, 0, &fallback_stats);
    defer allocator.free(fallback_shard);
    try std.testing.expect(std.mem.indexOf(u8, fallback_shard, declaration) != null);
}

test "captured module functions share one generated activation environment" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const link = @import("vm_link_image.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local n=1;local function add(x)n=n+x;return n end;local function get()return n end;return add,get");
    defer chunk.deinit();
    var module = try ir.lowerChunk(allocator, &chunk);
    defer module.deinit();
    _ = try opt.runSemantics(allocator, &module);
    var image = link.Image.init(allocator);
    defer image.deinit();
    _ = try image.appendModule(&module);
    _ = try opt.finalizeAot(allocator, &image.program);
    const generated = try generate(allocator, &image.program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.makeModuleFunction(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "try frame.ensureModuleEnv(ctx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "upvalues.cell(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "var captures_") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "static_functions") == null);
}

test "numeric bit constants are explicitly typed in native expressions" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local s=0;for i=1,4,0.25 do s=s+i end;return s");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    const generated = try generate(allocator, &program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "@as(f64, @bitCast(@as(u64, 0x3fd0000000000000)))") != null);
}

test "native global call hints emit guarded native dispatch" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local f=type;return f(1)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    var hinted = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call) {
            try aot_hint.setNativeGlobal(inst, global_abi.id("type"));
            hinted = true;
            break;
        };
        if (hinted) break;
    };
    try std.testing.expect(hinted);
    const generated = try generate(allocator, &program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.callKnownNative(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.getGlobal(1)") != null);
}

test "vararg call hints emit guards after merging the dynamic tail" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local f=type;return f(...)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    var hinted = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call_vararg) {
            try aot_hint.setNativeGlobal(inst, global_abi.id("type"));
            hinted = true;
            break;
        };
        if (hinted) break;
    };
    try std.testing.expect(hinted);
    const generated = try generate(allocator, &program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "rt.mergeValues(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.callKnownNative(") != null);
}

test "canonical native field hints emit guarded native dispatch" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local f=type;return f(1)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    var hinted = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call) {
            const slot = static_fields.slotForName(.table, "insert") orelse return error.MissingStaticField;
            try aot_hint.setNativeField(inst, .table, slot);
            hinted = true;
            break;
        };
        if (hinted) break;
    };
    try std.testing.expect(hinted);
    const generated = try generate(allocator, &program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.callKnownNativeField(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ", .table, 0, ctx.getGlobal(17), null, argv_") != null);
}

test "return object native field hints stay on generic dispatch" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local f=type;return f(1)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    var hinted = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call) {
            const slot = static_fields.slotForName(.frame, "getParent") orelse return error.MissingStaticField;
            try aot_hint.setNativeField(inst, .frame, slot);
            hinted = true;
            break;
        };
        if (hinted) break;
    };
    try std.testing.expect(hinted);
    const generated = try generate(allocator, &program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.callKnownNativeField(") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.callValue(") != null);
}

test "native field candidates emit live multi-identity guards" {
    const lua = @import("root.zig");
    const opt = @import("vm_optimize.zig");
    const allocator = std.testing.allocator;
    var chunk = try lua.parse(allocator, "local f=type;return f(1)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);
    const field_id = static_fields.find("gsub") orelse return error.MissingStaticField;
    var candidate = false;
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        for (function.insts.items) |*inst| if (inst.op == .call) {
            try aot_hint.setNativeFieldCandidate(inst, field_id);
            candidate = true;
            break;
        };
        if (candidate) break;
    };
    try std.testing.expect(candidate);
    const generated = try generate(allocator, &program);
    defer allocator.free(generated.source);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "ctx.callKnownNativeFieldCandidates(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".namespace = .string") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".namespace = .ustring") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".root = ctx.getGlobal(") != null);
}
