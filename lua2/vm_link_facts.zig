const std = @import("std");
const ir = @import("vm_ir.zig");
const global_abi = @import("vm_global_abi.zig");
const ssa = @import("vm_ssa.zig");
const symbols_mod = @import("vm_link_symbols.zig");
const link_image = @import("vm_link_image.zig");
const field_abi = @import("vm_static_field_abi.zig");
const aot_hint = @import("vm_aot_hint.zig");
const lua = @import("root.zig");
const model = @import("module_model.zig");

pub const Fact = union(enum) {
    unknown,
    string: u32,
    require_builtin,
    native_namespace: field_abi.Namespace,
    captured_native_namespace: field_abi.Namespace,
    native_field: aot_hint.NativeField,
    captured_native_field: aot_hint.NativeField,
    module: u32,
    function: u32,
};

pub const Edge = struct {
    caller: u32,
    pc: u32,
    callee: u32,
};

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    ssa_function: ssa.Function,
    facts: []Fact,
    edges: std.ArrayList(Edge) = .empty,

    pub fn deinit(self: *Analysis) void {
        self.edges.deinit(self.allocator);
        if (self.facts.len != 0) self.allocator.free(self.facts);
        self.ssa_function.deinit();
    }
};

fn factEqual(a: Fact, b: Fact) bool {
    return std.meta.eql(a, b);
}

fn known(fact: Fact) bool {
    return switch (fact) {
        .unknown => false,
        else => true,
    };
}

fn factOf(analysis: *const Analysis, raw: ssa.ValueId) Fact {
    const id = analysis.ssa_function.canonicalValue(raw);
    if (id == ssa.invalid_value or id >= analysis.facts.len) return .unknown;
    return analysis.facts[id];
}

fn setFact(analysis: *Analysis, raw: ssa.ValueId, fact: Fact) bool {
    if (!known(fact)) return false;
    const id = analysis.ssa_function.canonicalValue(raw);
    if (id == ssa.invalid_value or id >= analysis.facts.len) return false;
    if (known(analysis.facts[id])) return false;
    analysis.facts[id] = fact;
    return true;
}

pub fn requireBuiltinSafe(program: *const ir.Program) bool {
    for (program.functions.items) |maybe_function| if (maybe_function) |function| {
        for (function.insts.items) |inst| {
            if (inst.op == .set_global_slot and inst.aux == global_abi.id("require")) return false;
            if (inst.op == .set_global and inst.aux < program.strings.items.len and std.mem.eql(u8, program.strings.items[inst.aux], "require")) return false;
        }
    };
    return true;
}

fn phiFact(analysis: *const Analysis, phi: *const ssa.Phi) Fact {
    var candidate: Fact = .unknown;
    for (phi.inputs.items) |input| {
        if (analysis.ssa_function.canonicalValue(input) == phi.value) continue;
        const fact = factOf(analysis, input);
        if (!known(fact)) return .unknown;
        if (!known(candidate)) candidate = fact else if (!factEqual(candidate, fact)) return .unknown;
    }
    return candidate;
}

fn regFact(analysis: *const Analysis, state: []const ssa.ValueId, reg: u32) Fact {
    if (reg >= state.len) return .unknown;
    return factOf(analysis, state[reg]);
}

fn stringFact(program: *const ir.Program, fact: Fact) ?[]const u8 {
    return switch (fact) {
        .string => |sid| if (sid < program.strings.items.len) program.strings.items[sid] else null,
        else => null,
    };
}

fn nativeGlobalNamespace(slot: u32) ?field_abi.Namespace {
    if (slot == global_abi.id("table")) return .table;
    if (slot == global_abi.id("string")) return .string;
    if (slot == global_abi.id("math")) return .math;
    if (slot == global_abi.id("debug")) return .debug;
    if (slot == global_abi.id("mw")) return .mw;
    return null;
}

fn childNativeNamespace(parent: field_abi.Namespace, name: []const u8) ?field_abi.Namespace {
    if (parent != .mw) return null;
    if (std.mem.eql(u8, name, "ustring")) return .ustring;
    if (std.mem.eql(u8, name, "title")) return .title;
    if (std.mem.eql(u8, name, "text")) return .text;
    if (std.mem.eql(u8, name, "uri")) return .uri;
    if (std.mem.eql(u8, name, "html")) return .html;
    if (std.mem.eql(u8, name, "language")) return .language;
    return null;
}

fn fieldName(program: *const ir.Program, inst: ir.Inst) ?[]const u8 {
    return switch (inst.op) {
        .get_field => if (inst.aux < program.strings.items.len) program.strings.items[inst.aux] else null,
        .get_slot => field_abi.nameForRef(inst.aux),
        else => null,
    };
}

fn nativeFieldFact(namespace: field_abi.Namespace, name: []const u8, captured: bool) Fact {
    if (childNativeNamespace(namespace, name)) |child|
        return if (captured) .{ .captured_native_namespace = child } else .{ .native_namespace = child };
    const slot = field_abi.slotForName(namespace, name) orelse return .unknown;
    const field = aot_hint.NativeField{ .namespace = namespace, .slot = slot };
    return if (captured) .{ .captured_native_field = field } else .{ .native_field = field };
}

fn capturedUpvalueFact(fact: Fact) Fact {
    return switch (fact) {
        .native_namespace => |namespace| .{ .captured_native_namespace = namespace },
        .captured_native_namespace => fact,
        .native_field => |field| .{ .captured_native_field = field },
        .captured_native_field => fact,
        else => fact,
    };
}

fn callResultFact(
    analysis: *const Analysis,
    function: *const ir.Function,
    state: []const ssa.ValueId,
    inst: ir.Inst,
) Fact {
    if (inst.op != .call and inst.op != .call_vararg) return .unknown;
    if (regFact(analysis, state, inst.a) != .require_builtin or inst.b == 0) return .unknown;
    if (@as(usize, inst.aux) + inst.b > function.operands.items.len) return .unknown;
    const arg_reg = function.operands.items[inst.aux];
    const arg = regFact(analysis, state, arg_reg);
    return switch (arg) {
        .string => |sid| .{ .module = sid },
        else => .unknown,
    };
}

fn instructionFact(
    analysis: *const Analysis,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function: *const ir.Function,
    state: []const ssa.ValueId,
    inst: ir.Inst,
    require_safe: bool,
    upvalue_facts: []const Fact,
) Fact {
    return switch (inst.op) {
        .load_string => .{ .string = inst.aux },
        .load_const => blk: {
            if (inst.aux >= program.constants.items.len) break :blk .unknown;
            break :blk switch (program.constants.items[inst.aux]) {
                .string => |sid| .{ .string = sid },
                else => .unknown,
            };
        },
        .get_global => blk: {
            if (inst.aux >= program.strings.items.len) break :blk .unknown;
            const name = program.strings.items[inst.aux];
            if (require_safe and std.mem.eql(u8, name, "require")) break :blk .require_builtin;
            const slot = global_abi.find(name) orelse break :blk .unknown;
            if (nativeGlobalNamespace(slot)) |namespace| break :blk .{ .native_namespace = namespace };
            break :blk .unknown;
        },
        .get_global_slot => if (require_safe and inst.aux == global_abi.id("require"))
            .require_builtin
        else if (nativeGlobalNamespace(inst.aux)) |namespace|
            .{ .native_namespace = namespace }
        else
            .unknown,
        .get_upvalue => if (inst.a < upvalue_facts.len) capturedUpvalueFact(upvalue_facts[inst.a]) else .unknown,
        .move => regFact(analysis, state, inst.a),
        .closure, .load_function => .{ .function = inst.aux },
        .call, .call_vararg => callResultFact(analysis, function, state, inst),
        .get_index => blk: {
            const object = regFact(analysis, state, inst.a);
            const key = regFact(analysis, state, inst.b);
            const module_sid = switch (object) {
                .module => |sid| sid,
                else => break :blk .unknown,
            };
            const module_name = if (module_sid < program.strings.items.len) program.strings.items[module_sid] else break :blk .unknown;
            const export_name = stringFact(program, key) orelse break :blk .unknown;
            const target = symbols.resolveExport(module_name, export_name) orelse break :blk .unknown;
            break :blk .{ .function = target };
        },
        .get_field, .get_slot => blk: {
            const object = regFact(analysis, state, inst.a);
            const name = fieldName(program, inst) orelse break :blk .unknown;
            switch (object) {
                .native_namespace => |namespace| break :blk nativeFieldFact(namespace, name, false),
                .captured_native_namespace => |namespace| break :blk nativeFieldFact(namespace, name, true),
                else => {},
            }
            const module_sid = switch (object) {
                .module => |sid| sid,
                else => break :blk .unknown,
            };
            if (module_sid >= program.strings.items.len) break :blk .unknown;
            const target = symbols.resolveExport(program.strings.items[module_sid], name) orelse break :blk .unknown;
            break :blk .{ .function = target };
        },
        else => .unknown,
    };
}

fn propagate(
    analysis: *Analysis,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function: *const ir.Function,
    require_safe: bool,
    upvalue_facts: []const Fact,
) !void {
    const state = try analysis.allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) analysis.allocator.free(state);
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.ssa_function.phis.items) |*phi| {
            if (analysis.ssa_function.canonicalValue(phi.value) != phi.value) continue;
            changed = setFact(analysis, phi.value, phiFact(analysis, phi)) or changed;
        }
        for (analysis.ssa_function.graph.blocks.items, 0..) |block, block_index| {
            const entry = analysis.ssa_function.entry_states[block_index] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                const fact = instructionFact(analysis, program, symbols, function, state, inst, require_safe, upvalue_facts);
                try ssa.applyWrites(&analysis.ssa_function, function, state, pc, null);
                if (inst.dst < state.len and !analysis.ssa_function.captured[inst.dst]) {
                    changed = setFact(analysis, state[inst.dst], fact) or changed;
                }
            }
        }
    }
}

fn targetForCall(
    analysis: *const Analysis,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function: *const ir.Function,
    state: []const ssa.ValueId,
    inst: ir.Inst,
) ?u32 {
    switch (inst.op) {
        .call_local, .call_local_vararg, .call_scoped, .call_scoped_vararg, .direct_call, .direct_call_vararg => return inst.a,
        else => {},
    }
    if (inst.op == .call or inst.op == .call_vararg) {
        return switch (regFact(analysis, state, inst.a)) {
            .function => |id| id,
            else => null,
        };
    }
    if (inst.op == .method_call_field or inst.op == .method_call_field_vararg) {
        if (inst.b == 0 or inst.aux >= function.operands.items.len or inst.a >= program.strings.items.len) return null;
        const object = regFact(analysis, state, function.operands.items[inst.aux]);
        const module_sid = switch (object) {
            .module => |sid| sid,
            else => return null,
        };
        if (module_sid >= program.strings.items.len) return null;
        return symbols.resolveExport(program.strings.items[module_sid], program.strings.items[inst.a]);
    }
    if (inst.op != .method_call and inst.op != .method_call_vararg) return null;
    const object = regFact(analysis, state, inst.a);
    const module_sid = switch (object) {
        .module => |sid| sid,
        else => return null,
    };
    if (module_sid >= program.strings.items.len) return null;
    if (inst.b == 0 or inst.aux >= function.operands.items.len) return null;
    const key_reg = function.operands.items[inst.aux];
    const key = stringFact(program, regFact(analysis, state, key_reg)) orelse return null;
    return symbols.resolveExport(program.strings.items[module_sid], key);
}

fn collectEdges(
    analysis: *Analysis,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function_id: u32,
    function: *const ir.Function,
) !void {
    const state = try analysis.allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) analysis.allocator.free(state);
    for (analysis.ssa_function.graph.blocks.items, 0..) |block, block_index| {
        const entry = analysis.ssa_function.entry_states[block_index] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = function.insts.items[pc];
            if (targetForCall(analysis, program, symbols, function, state, inst)) |callee| {
                try analysis.edges.append(analysis.allocator, .{ .caller = function_id, .pc = pc, .callee = callee });
            }
            try ssa.applyWrites(&analysis.ssa_function, function, state, pc, null);
        }
    }
}

pub fn buildFunctionWithUpvalues(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function_id: u32,
    require_safe: bool,
    upvalue_facts: []const Fact,
) !Analysis {
    if (function_id >= program.functions.items.len) return error.BadFunctionId;
    const function = &(program.functions.items[function_id] orelse return error.IncompleteProgram);
    var ssa_function = try ssa.build(allocator, program, function);
    errdefer ssa_function.deinit();
    const facts = try allocator.alloc(Fact, ssa_function.values.items.len);
    errdefer if (facts.len != 0) allocator.free(facts);
    for (facts) |*fact| fact.* = .unknown;
    var analysis = Analysis{
        .allocator = allocator,
        .ssa_function = ssa_function,
        .facts = facts,
    };
    errdefer analysis.deinit();
    try propagate(&analysis, program, symbols, function, require_safe, upvalue_facts);
    try collectEdges(&analysis, program, symbols, function_id, function);
    return analysis;
}

pub fn buildFunction(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function_id: u32,
    require_safe: bool,
) !Analysis {
    return buildFunctionWithUpvalues(allocator, program, symbols, function_id, require_safe, &.{});
}

pub fn predictInstruction(
    analysis: *const Analysis,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
    function: *const ir.Function,
    state: []const ssa.ValueId,
    inst: ir.Inst,
    require_safe: bool,
    upvalue_facts: []const Fact,
) Fact {
    return instructionFact(analysis, program, symbols, function, state, inst, require_safe, upvalue_facts);
}

fn addSource(
    allocator: std.mem.Allocator,
    image: *link_image.Image,
    symbols: *symbols_mod.Index,
    title: []const u8,
    source: []const u8,
) !u32 {
    var chunk = try lua.parse(allocator, source);
    defer chunk.deinit();
    var builder = model.Builder{ .allocator = allocator, .source = chunk.source };
    defer builder.deinit();
    try builder.build(chunk.body);
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    const module_index = try image.appendModule(&program);
    try symbols.addModule(title, image, module_index, &builder);
    return module_index;
}

test "SSA facts resolve literal require export calls across modules" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(std.testing.allocator);
    defer symbols.deinit();
    const b = try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local export={}; function export.add(x) return x+1 end; return export");
    const a = try addSource(std.testing.allocator, &image, &symbols, "Module:A", "local m=require('Module:B'); local f=m.add; return f(4)");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    try std.testing.expect(target >= image.modules.items[b].function_base);
    const root = image.modules.items[a].root_function;
    const safe = requireBuiltinSafe(&image.program);
    try std.testing.expect(safe);
    var facts = try buildFunction(std.testing.allocator, &image.program, &symbols, root, safe);
    defer facts.deinit();
    var found = false;
    for (facts.edges.items) |edge| {
        if (edge.callee == target) found = true;
    }
    try std.testing.expect(found);
}

test "global require mutation disables require resolution" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(std.testing.allocator);
    defer symbols.deinit();
    _ = try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local export={}; function export.add(x) return x+1 end; return export");
    const a = try addSource(std.testing.allocator, &image, &symbols, "Module:A", "require=function() return {add=function() return 9 end} end; local m=require('Module:B'); return m.add(4)");
    try std.testing.expect(!requireBuiltinSafe(&image.program));
    const root = image.modules.items[a].root_function;
    var facts = try buildFunction(std.testing.allocator, &image.program, &symbols, root, false);
    defer facts.deinit();
    try std.testing.expectEqual(@as(usize, 0), facts.edges.items.len);
}
