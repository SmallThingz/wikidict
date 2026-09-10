const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const global_abi = @import("vm_global_abi.zig");
const fields = @import("vm_static_field_abi.zig");
const aot_hint = @import("vm_aot_hint.zig");

pub const Stats = struct {
    reads: u64 = 0,
    writes: u64 = 0,
    guarded_calls: u64 = 0,
};

fn globalNamespace(slot: u32) ?fields.Namespace {
    if (slot == global_abi.id("table")) return .table;
    if (slot == global_abi.id("string")) return .string;
    if (slot == global_abi.id("math")) return .math;
    if (slot == global_abi.id("debug")) return .debug;
    if (slot == global_abi.id("mw")) return .mw;
    return null;
}

fn instructionGlobalNamespace(program: *const ir.Program, inst: ir.Inst) ?fields.Namespace {
    return switch (inst.op) {
        .get_global_slot => globalNamespace(inst.aux),
        .get_global => if (inst.aux < program.strings.items.len)
            globalNamespace(global_abi.find(program.strings.items[inst.aux]) orelse return null)
        else
            null,
        else => null,
    };
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

fn mergeNativeFieldPhi(
    analysis: *const ssa.Function,
    facts: []const ?aot_hint.NativeField,
    phi: ssa.Phi,
) ?aot_hint.NativeField {
    var selected: ?aot_hint.NativeField = null;
    var any = false;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= facts.len) return null;
        const incoming = facts[id] orelse return null;
        any = true;
        if (selected) |old| {
            if (!std.meta.eql(old, incoming)) return null;
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

fn callResultNamespace(parent: fields.Namespace, field_name: []const u8) ?fields.Namespace {
    return switch (parent) {
        .mw => if (std.mem.eql(u8, field_name, "getCurrentFrame"))
            .frame
        else if (std.mem.eql(u8, field_name, "getContentLanguage") or std.mem.eql(u8, field_name, "getLanguage"))
            .language_value
        else
            null,
        .title => if (std.mem.eql(u8, field_name, "new") or std.mem.eql(u8, field_name, "makeTitle") or std.mem.eql(u8, field_name, "getCurrentTitle")) .title_value else null,
        .language => if (std.mem.eql(u8, field_name, "new") or std.mem.eql(u8, field_name, "getContentLanguage")) .language_value else null,
        .html => if (std.mem.eql(u8, field_name, "create")) .html_node else null,
        .html_node => if (fields.slotForName(.html_node, field_name) != null) .html_node else null,
        .frame => if (std.mem.eql(u8, field_name, "getParent")) .frame else null,
        else => null,
    };
}

fn instructionFieldName(program: *const ir.Program, inst: ir.Inst) ?[]const u8 {
    return switch (inst.op) {
        .get_field => if (inst.aux < program.strings.items.len) program.strings.items[inst.aux] else null,
        .get_slot => fields.nameForRef(inst.aux),
        else => null,
    };
}

fn hasNamespaceRoot(program: *const ir.Program, function: *const ir.Function) bool {
    for (function.insts.items) |inst| {
        if (instructionGlobalNamespace(program, inst) != null) return true;
    }
    return false;
}

fn populateFacts(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    analysis: *ssa.Function,
    facts: []?fields.Namespace,
    call_results: []?fields.Namespace,
    native_fields: []?aot_hint.NativeField,
) !void {
    @memset(facts, null);
    @memset(call_results, null);
    @memset(native_fields, null);
    for (analysis.values.items, 0..) |node, id| if (node.kind == .instruction and node.pc < function.insts.items.len) {
        facts[id] = instructionGlobalNamespace(program, function.insts.items[node.pc]);
    };
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value) continue;
            if (facts[id] == null) if (mergePhi(analysis, facts, phi)) |namespace| {
                facts[id] = namespace;
                changed = true;
            };
            if (call_results[id] == null) if (mergePhi(analysis, call_results, phi)) |namespace| {
                call_results[id] = namespace;
                changed = true;
            };
            if (native_fields[id] == null) if (mergeNativeFieldPhi(analysis, native_fields, phi)) |field| {
                native_fields[id] = field;
                changed = true;
            };
        }
        for (analysis.graph.blocks.items, 0..) |block, block_id| {
            const entry = analysis.entry_states[block_id] orelse continue;
            @memcpy(state, entry);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                var result_namespace: ?fields.Namespace = null;
                var callable_result: ?fields.Namespace = null;
                var native_field: ?aot_hint.NativeField = null;
                if (inst.op == .get_field or inst.op == .get_slot) {
                    if (namespaceForReg(analysis, facts, state, inst.a)) |parent| {
                        if (instructionFieldName(program, inst)) |field_name| {
                            result_namespace = childNamespace(parent, field_name);
                            callable_result = callResultNamespace(parent, field_name);
                            if (fields.slotForName(parent, field_name)) |slot|
                                native_field = .{ .namespace = parent, .slot = slot };
                        }
                    }
                } else if ((inst.op == .call or inst.op == .call_vararg) and inst.a < state.len) {
                    const callee = analysis.canonicalValue(state[inst.a]);
                    if (callee != ssa.invalid_value and callee < call_results.len)
                        result_namespace = call_results[callee];
                }
                try ssa.applyWrites(analysis, function, state, pc, null);
                if (inst.dst < state.len) {
                    const value = analysis.canonicalValue(state[inst.dst]);
                    if (value != ssa.invalid_value and value < facts.len) {
                        if (result_namespace) |namespace| if (facts[value] == null) {
                            facts[value] = namespace;
                            changed = true;
                        };
                        if (callable_result) |namespace| if (call_results[value] == null) {
                            call_results[value] = namespace;
                            changed = true;
                        };
                        if (native_field) |field| if (native_fields[value] == null) {
                            native_fields[value] = field;
                            changed = true;
                        };
                    }
                }
            }
        }
    }
}

fn runFunction(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function, rewrite_fields: bool) !Stats {
    if (!hasNamespaceRoot(program, function)) return .{};
    var analysis = try ssa.build(allocator, program, function);
    defer analysis.deinit();
    const facts = try allocator.alloc(?fields.Namespace, analysis.values.items.len);
    defer if (facts.len != 0) allocator.free(facts);
    const call_results = try allocator.alloc(?fields.Namespace, analysis.values.items.len);
    defer if (call_results.len != 0) allocator.free(call_results);
    const native_fields = try allocator.alloc(?aot_hint.NativeField, analysis.values.items.len);
    defer if (native_fields.len != 0) allocator.free(native_fields);
    try populateFacts(allocator, program, function, &analysis, facts, call_results, native_fields);
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = &function.insts.items[pc];
            if (rewrite_fields and (inst.op == .get_field or inst.op == .set_field) and inst.a < state.len and inst.aux < program.strings.items.len) {
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
            if (inst.op == .call and inst.a < state.len and aot_hint.target(inst.*) == null and aot_hint.nativeGlobal(inst.*) == null and aot_hint.nativeField(inst.*) == null) {
                const value = analysis.canonicalValue(state[inst.a]);
                if (value != ssa.invalid_value and value < native_fields.len) if (native_fields[value]) |field| {
                    try aot_hint.setNativeField(inst, field.namespace, field.slot);
                    stats.guarded_calls += 1;
                };
            }
            try ssa.applyWrites(&analysis, function, state, pc, null);
        }
    }
    return stats;
}

pub fn tagCallHints(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return .{};
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function, false);
        stats.guarded_calls += one.guarded_calls;
    };
    return stats;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return .{};
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function, true);
        stats.reads += one.reads;
        stats.writes += one.writes;
        stats.guarded_calls += one.guarded_calls;
    };
    return stats;
}

const lua = @import("root.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");
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

fn countNativeFieldGuardHints(program: *const ir.Program) u64 {
    var count: u64 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if (aot_hint.nativeField(inst) != null) count += 1;
        }
    };
    return count;
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
    try std.testing.expectEqual(@as(u64, 1), result.stats.guarded_calls);
    try std.testing.expectEqual(@as(u64, 1), countNativeFieldGuardHints(&result.program));
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

test "native field provenance follows callable aliases and phis" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(
        a,
        "local g=mw.ustring.gsub;" ++
            "local function pick(b)local f;if b then f=table.insert else f=table.insert end;return f({},1) end;" ++
            "return pick(true),g('a','a','b')",
    );
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 2), stats.guarded_calls);
    try std.testing.expectEqual(@as(u64, 2), countNativeFieldGuardHints(&program));
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
    var chunk = try lua.parse(a, "return mw.text.split,mw.title.new,mw.uri.encode,mw.html.create,mw.language.new,mw.getLanguage");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 11), stats.reads);
    _ = try simplify.run(a, &program);
    inline for (&.{ "text", "split", "title", "new", "uri", "encode", "html", "create", "language", "getLanguage" }) |name|
        try std.testing.expect(!hasString(&program, name));
}

test "known Scribunto call results retain static object layouts" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local f=mw.getCurrentFrame();local t=mw.title.new('x');local l=mw.language.new('en');local h=mw.html.create('div');return f.args,t.text,l.getCode,h.tag");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 11), stats.reads);
    _ = try simplify.run(a, &program);
    inline for (&.{ "getCurrentFrame", "args", "title", "new", "text", "language", "getCode", "html", "create", "tag" }) |name|
        try std.testing.expect(!hasString(&program, name));
}

fn returnStaticFieldTestTable(ctx_raw: ?*anyopaque, _: *anyopaque, _: []const rt.Value, _: std.mem.Allocator) ![]const rt.Value {
    const table: *rt.Table = @ptrCast(@alignCast(ctx_raw.?));
    const out = try std.heap.smp_allocator.alloc(rt.Value, 1);
    out[0] = .{ .table = table };
    return out;
}

test "call result layout uses slots and falls back after constructor mutation" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local f=mw.getCurrentFrame();return f.args");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 2), stats.reads);
    _ = try simplify.run(a, &program);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try stdlib.install(&vm);
    const mw = try rt.newNativeNamespace(arena.allocator(), .mw);
    try vm.setGlobal("mw", .{ .table = mw });
    const shaped = try rt.newNativeNamespace(arena.allocator(), .frame);
    try shaped.rawSet(arena.allocator(), .{ .string = "args" }, .{ .number = 7 });
    try mw.rawSet(arena.allocator(), .{ .string = "getCurrentFrame" }, try rt.newNative(arena.allocator(), shaped, returnStaticFieldTestTable));
    const fast = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(fast);
    try std.testing.expectEqual(@as(f64, 7), fast[0].number);

    const generic = try rt.newTable(arena.allocator());
    try generic.rawSet(arena.allocator(), .{ .string = "args" }, .{ .number = 9 });
    try mw.rawSet(arena.allocator(), .{ .string = "getCurrentFrame" }, try rt.newNative(arena.allocator(), generic, returnStaticFieldTestTable));
    const fallback = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(fallback);
    try std.testing.expectEqual(@as(f64, 9), fallback[0].number);
}

test "staged native call hints preserve later field rewriting" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local f=table.insert;local t={};f(t,1);return table.concat(t,',')");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const staged = try tagCallHints(a, &program);
    try std.testing.expect(staged.guarded_calls >= 2);
    const rewritten = try run(a, &program);
    try std.testing.expect(rewritten.reads >= 2);
    try std.testing.expectEqual(@as(u64, 0), rewritten.guarded_calls);
    try std.testing.expectEqual(staged.guarded_calls, countNativeFieldGuardHints(&program));
}
