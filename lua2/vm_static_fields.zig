const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const global_abi = @import("vm_global_abi.zig");
const fields = @import("vm_static_field_abi.zig");

pub const Stats = struct {
    reads: u64 = 0,
    writes: u64 = 0,
};

fn globalNamespace(slot: u32) ?fields.Namespace {
    if (slot == global_abi.id("table")) return .table;
    if (slot == global_abi.id("string")) return .string;
    if (slot == global_abi.id("math")) return .math;
    if (slot == global_abi.id("debug")) return .debug;
    if (slot == global_abi.id("mw")) return .mw;
    return null;
}

fn mergePhi(analysis: *const ssa.Function, facts: []const ?fields.Namespace, phi: ssa.Phi) ?fields.Namespace {
    var selected: ?fields.Namespace = null;
    var any = false;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= facts.len) return null;
        const incoming = facts[id] orelse return null;
        any = true;
        if (selected) |old| {
            if (old != incoming) return null;
        } else selected = incoming;
    }
    return if (any) selected else null;
}

fn namespaceForReg(analysis: *const ssa.Function, facts: []const ?fields.Namespace, state: []const ssa.ValueId, reg: u32) ?fields.Namespace {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= facts.len) return null;
    return facts[id];
}

fn childNamespace(parent: fields.Namespace, field_name: []const u8) ?fields.Namespace {
    if (parent != .mw) return null;
    if (std.mem.eql(u8, field_name, "ustring")) return .ustring;
    if (std.mem.eql(u8, field_name, "title")) return .title;
    if (std.mem.eql(u8, field_name, "text")) return .text;
    if (std.mem.eql(u8, field_name, "uri")) return .uri;
    if (std.mem.eql(u8, field_name, "html")) return .html;
    if (std.mem.eql(u8, field_name, "language")) return .language;
    return null;
}

fn instructionFieldName(program: *const ir.Program, inst: ir.Inst) ?[]const u8 {
    return switch (inst.op) {
        .get_field => if (inst.aux < program.strings.items.len) program.strings.items[inst.aux] else null,
        .get_slot => fields.nameForRef(inst.aux),
        else => null,
    };
}

fn hasNamespaceRoot(function: *const ir.Function) bool {
    for (function.insts.items) |inst| {
        if (inst.op == .get_global_slot and globalNamespace(inst.aux) != null) return true;
    }
    return false;
}

fn runFunction(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function) !Stats {
    if (!hasNamespaceRoot(function)) return .{};
    var analysis = try ssa.build(allocator, program, function);
    defer analysis.deinit();
    const facts = try allocator.alloc(?fields.Namespace, analysis.values.items.len);
    defer if (facts.len != 0) allocator.free(facts);
    @memset(facts, null);
    for (analysis.values.items, 0..) |node, id| if (node.kind == .instruction and node.pc < function.insts.items.len) {
        const inst = function.insts.items[node.pc];
        if (inst.op == .get_global_slot) facts[id] = globalNamespace(inst.aux);
    };
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value or facts[id] != null) continue;
            if (mergePhi(&analysis, facts, phi)) |namespace| {
                facts[id] = namespace;
                changed = true;
            }
        }
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                var child: ?fields.Namespace = null;
                if (inst.op == .get_field or inst.op == .get_slot) {
                    if (namespaceForReg(&analysis, facts, state, inst.a)) |parent| {
                        if (instructionFieldName(program, inst)) |field_name|
                            child = childNamespace(parent, field_name);
                    }
                }
                try ssa.applyWrites(&analysis, function, state, pc, null);
                if (child) |namespace| if (inst.dst < state.len) {
                    const value = analysis.canonicalValue(state[inst.dst]);
                    if (value != ssa.invalid_value and value < facts.len and facts[value] == null) {
                        facts[value] = namespace;
                        changed = true;
                    }
                };
            }
        }
    }
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = &function.insts.items[pc];
            if ((inst.op == .get_field or inst.op == .set_field) and inst.a < state.len and inst.aux < program.strings.items.len) {
                const value = analysis.canonicalValue(state[inst.a]);
                if (value != ssa.invalid_value and value < facts.len) if (facts[value]) |namespace| {
                    const field_name = program.strings.items[inst.aux];
                    if (fields.slotForName(namespace, field_name) != null) {
                        inst.aux = fields.refForName(field_name).?;
                        if (inst.op == .get_field) {
                            inst.op = .get_slot;
                            stats.reads += 1;
                        } else {
                            inst.op = .set_slot;
                            stats.writes += 1;
                        }
                    }
                };
            }
            try ssa.applyWrites(&analysis, function, state, pc, null);
        }
    }
    return stats;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return .{};
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function);
        stats.reads += one.reads;
        stats.writes += one.writes;
    };
    return stats;
}

const lua = @import("root.zig");
const exec = @import("vm_exec.zig");
const stdlib = @import("lua_stdlib.zig");
const simplify = @import("vm_ir_simplify.zig");

fn execute(source: []const u8) !struct { values: []const exec.Value, program: ir.Program, arena: std.heap.ArenaAllocator, stats: Stats } {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    errdefer program.deinit();
    const stats = try run(a, &program);
    _ = try simplify.run(a, &program);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try stdlib.install(&vm);
    const values = try vm.executeRoot(&program, &.{});
    return .{ .values = values, .program = program, .arena = arena, .stats = stats };
}

fn hasString(program: *const ir.Program, needle: []const u8) bool {
    for (program.strings.items) |text| if (std.mem.eql(u8, text, needle)) return true;
    return false;
}
test "known library field becomes a static numeric ref" {
    var result = try execute("return type(table.insert)");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(u64, 1), result.stats.reads);
    try std.testing.expectEqualStrings("function", result.values[0].string);
    try std.testing.expect(!hasString(&result.program, "insert"));
    var found = false;
    for (result.program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (inst.op == .get_slot and fields.nameForRef(inst.aux) != null) found = true;
        }
    };
    try std.testing.expect(found);
}

test "static field ref observes namespace member mutation" {
    var result = try execute("table.insert=function()return 9 end;return table.insert()");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expect(result.stats.reads != 0 and result.stats.writes != 0);
    try std.testing.expectEqual(@as(f64, 9), result.values[0].number);
    try std.testing.expect(!hasString(&result.program, "insert"));
}
test "static field ref falls back after global namespace rebind" {
    var result = try execute("table={insert=function()return 7 end};return table.insert()");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(f64, 7), result.values[0].number);
    try std.testing.expectEqual(@as(u64, 1), result.stats.reads);
    try std.testing.expect(hasString(&result.program, "insert"));
}

test "static field ref preserves arbitrary table and metatable semantics" {
    var result = try execute(
        "local a={insert=4};local b=setmetatable({},{__index={insert=6}});return a.insert,b.insert",
    );
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(f64, 4), result.values[0].number);
    try std.testing.expectEqual(@as(f64, 6), result.values[1].number);
}

test "native namespace dynamic raw access shares static slots" {
    var result = try execute("rawset(table,'insert',8);return rawget(table,'insert')");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(f64, 8), result.values[0].number);
}

test "static field refs survive bytecode roundtrip without field strings" {
    const codec = @import("vm_codec.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "return type(table.insert)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    _ = try run(a, &program);
    _ = try simplify.run(a, &program);
    const bytes = try codec.serialize(a, &program);
    defer a.free(bytes);
    var restored = try codec.deserialize(a, bytes);
    defer restored.deinit();
    try std.testing.expect(!hasString(&restored, "insert"));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try stdlib.install(&vm);
    const out = try vm.executeRoot(&restored, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqualStrings("function", out[0].string);
}

test "native namespace iteration observes slot and dynamic fields" {
    var result = try execute(
        "table.custom=17;local a,b=false,false;for k,v in pairs(table) do if k=='insert' then a=type(v)=='function' elseif k=='custom' then b=v==17 end end;return a,b",
    );
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expect(result.values[0].boolean);
    try std.testing.expect(result.values[1].boolean);
}

test "namespace provenance follows local aliases" {
    var result = try execute("local lib=table;return type(lib.insert)");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(u64, 1), result.stats.reads);
    try std.testing.expect(!hasString(&result.program, "insert"));
    try std.testing.expectEqualStrings("function", result.values[0].string);
}

test "unproven and wrong-namespace fields remain string operations" {
    var result = try execute("local t={insert=4};return t.insert,string.insert");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(u64, 0), result.stats.reads);
    try std.testing.expect(hasString(&result.program, "insert"));
    try std.testing.expectEqual(@as(f64, 4), result.values[0].number);
    try std.testing.expect(result.values[1] == .nil);
}

test "known child namespace propagates through field result aliases" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local u=mw.ustring;local v=u;return v.gsub");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 2), stats.reads);
    _ = try simplify.run(a, &program);
    try std.testing.expect(!hasString(&program, "ustring"));
    try std.testing.expect(!hasString(&program, "gsub"));
}

test "known nested Scribunto namespaces lower to static slots" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a,
        "return mw.text.split,mw.title.new,mw.uri.encode,mw.html.create,mw.language.new,mw.getLanguage");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 11), stats.reads);
    _ = try simplify.run(a, &program);
    inline for (&.{ "text", "split", "title", "new", "uri", "encode", "html", "create", "language", "getLanguage" }) |name|
        try std.testing.expect(!hasString(&program, name));
}
