const std = @import("std");
const ir = @import("vm_ir.zig");
const sem = @import("vm_semantics.zig");
const ssa = @import("vm_ssa.zig");
const facts_mod = @import("vm_link_facts.zig");
const symbols_mod = @import("vm_link_symbols.zig");

const Fact = facts_mod.Fact;
const none = std.math.maxInt(u32);

const Edge = struct {
    parent: u32,
    child_upvalue: usize,
    source: ir.Upvalue,
};

pub const Stats = struct {
    stable_locals: u64 = 0,
    known_upvalues: u64 = 0,
    module_upvalues: u64 = 0,
    function_upvalues: u64 = 0,
    native_global_upvalues: u64 = 0,
    native_namespace_upvalues: u64 = 0,
    native_field_upvalues: u64 = 0,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    offsets: []usize,
    facts: []Fact,
    stats: Stats,
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.offsets);
        if (self.facts.len != 0) self.allocator.free(self.facts);
    }

    pub fn forFunction(self: *const Result, program: *const ir.Program, function_id: u32) []const Fact {
        if (function_id >= program.functions.items.len) return &.{};
        return self.facts[self.offsets[function_id]..self.offsets[function_id + 1]];
    }
};

fn hasFact(fact: Fact) bool {
    return switch (fact) {
        .unknown => false,
        else => true,
    };
}
fn makeOffsets(a: std.mem.Allocator, program: *const ir.Program, upvalues: bool) ![]usize {
    const out = try a.alloc(usize, program.functions.items.len + 1);
    out[0] = 0;
    for (program.functions.items, 0..) |maybe, id| {
        out[id + 1] = out[id] + if (maybe) |function|
            if (upvalues) function.upvalues.items.len else function.reg_count
        else
            0;
    }
    return out;
}

fn noteWrite(captured: []const bool, counts: []u8, pcs: []u32, flat: usize, pc: u32) void {
    if (flat >= captured.len or !captured[flat]) return;
    counts[flat] +|= 1;
    if (counts[flat] == 1) pcs[flat] = pc;
}
fn noteInstructionWrites(
    function: *const ir.Function,
    base: usize,
    captured: []const bool,
    counts: []u8,
    pcs: []u32,
    pc: u32,
    inst: ir.Inst,
) void {
    const info = sem.info(inst.op);
    if (info.defines and inst.dst < function.reg_count)
        noteWrite(captured, counts, pcs, base + inst.dst, pc);
    if (info.results) {
        const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
        var i: u32 = 0;
        while (i < width and inst.dst + i < function.reg_count) : (i += 1)
            noteWrite(captured, counts, pcs, base + inst.dst + i, pc);
    }
    switch (inst.op) {
        .numeric_for_init => if (inst.dst < function.reg_count)
            noteWrite(captured, counts, pcs, base + inst.dst, pc),
        .numeric_for_next => {
            if (inst.a < function.reg_count) noteWrite(captured, counts, pcs, base + inst.a, pc);
            if (inst.dst < function.reg_count) noteWrite(captured, counts, pcs, base + inst.dst, pc);
        },
        else => {},
    }
}
fn noteLoopWrites(
    function: *const ir.Function,
    base: usize,
    captured: []const bool,
    counts: []u8,
    pcs: []u32,
    pc: u32,
    inst: ir.Inst,
) void {
    if (inst.op != .generic_for_init and inst.op != .generic_for_next) return;
    if (inst.c < function.reg_count) noteWrite(captured, counts, pcs, base + inst.c, pc);
    const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
    var i: u32 = 0;
    while (i < width and inst.dst + i < function.reg_count) : (i += 1)
        noteWrite(captured, counts, pcs, base + inst.dst + i, pc);
}

fn collectGraph(
    a: std.mem.Allocator,
    program: *const ir.Program,
    reg_offsets: []const usize,
    up_offsets: []const usize,
    captured: []bool,
    detached: []bool,
    mutated_upvalue: []bool,
    edges: *std.ArrayList(Edge),
) !void {
    for (program.functions.items, 0..) |maybe, parent_usize| {
        const function = maybe orelse continue;
        const parent: u32 = @intCast(parent_usize);
        for (function.insts.items) |inst| {
            if (inst.op == .detach_cell and inst.a < function.reg_count)
                detached[reg_offsets[parent] + inst.a] = true;
            if (inst.op == .set_upvalue) {
                if (inst.a >= function.upvalues.items.len) return error.BadUpvalue;
                mutated_upvalue[up_offsets[parent] + inst.a] = true;
            }
            const child_id = sem.captureTarget(inst) orelse continue;
            if (child_id >= program.functions.items.len) return error.BadFunctionReference;
            const child = program.functions.items[child_id] orelse return error.IncompleteProgram;
            for (child.upvalues.items, 0..) |upvalue, child_index| {
                if (upvalue.source == .local) {
                    if (upvalue.index >= function.reg_count) return error.BadRegister;
                    captured[reg_offsets[parent] + upvalue.index] = true;
                } else if (upvalue.index >= function.upvalues.items.len) {
                    return error.BadUpvalue;
                }
                try edges.append(a, .{
                    .parent = parent,
                    .child_upvalue = up_offsets[child_id] + child_index,
                    .source = upvalue,
                });
            }
        }
    }
}

fn propagateMutations(
    edges: []const Edge,
    reg_offsets: []const usize,
    up_offsets: []const usize,
    mutated_local: []bool,
    mutated_upvalue: []bool,
) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (edges) |edge| {
            if (!mutated_upvalue[edge.child_upvalue]) continue;
            switch (edge.source.source) {
                .local => {
                    const flat = reg_offsets[edge.parent] + edge.source.index;
                    if (!mutated_local[flat]) {
                        mutated_local[flat] = true;
                        changed = true;
                    }
                },
                .upvalue => {
                    const flat = up_offsets[edge.parent] + edge.source.index;
                    if (!mutated_upvalue[flat]) {
                        mutated_upvalue[flat] = true;
                        changed = true;
                    }
                },
            }
        }
    }
}

fn collectWrites(
    program: *const ir.Program,
    reg_offsets: []const usize,
    captured: []const bool,
    counts: []u8,
    pcs: []u32,
) void {
    for (program.functions.items, 0..) |maybe, function_id| if (maybe) |function| {
        const base = reg_offsets[function_id];
        for (function.insts.items, 0..) |inst, pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            noteInstructionWrites(&function, base, captured, counts, pcs, pc, inst);
            noteLoopWrites(&function, base, captured, counts, pcs, pc, inst);
        }
    };
}

fn mergeCandidate(candidate: *Fact, bad: *bool, incoming: Fact) void {
    if (!hasFact(incoming)) {
        bad.* = true;
        return;
    }
    if (!hasFact(candidate.*)) {
        candidate.* = incoming;
    } else if (!std.meta.eql(candidate.*, incoming)) {
        bad.* = true;
    }
}
pub fn build(
    a: std.mem.Allocator,
    program: *ir.Program,
    symbols: *const symbols_mod.Index,
) !Result {
    const reg_offsets = try makeOffsets(a, program, false);
    defer a.free(reg_offsets);
    const up_offsets = try makeOffsets(a, program, true);
    errdefer a.free(up_offsets);
    const total_regs = reg_offsets[program.functions.items.len];
    const total_upvalues = up_offsets[program.functions.items.len];

    const captured = try a.alloc(bool, total_regs);
    defer if (captured.len != 0) a.free(captured);
    @memset(captured, false);
    const detached = try a.alloc(bool, total_regs);
    defer if (detached.len != 0) a.free(detached);
    @memset(detached, false);
    const mutated_local = try a.alloc(bool, total_regs);
    defer if (mutated_local.len != 0) a.free(mutated_local);
    @memset(mutated_local, false);
    const mutated_upvalue = try a.alloc(bool, total_upvalues);
    defer if (mutated_upvalue.len != 0) a.free(mutated_upvalue);
    @memset(mutated_upvalue, false);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(a);
    try collectGraph(a, program, reg_offsets, up_offsets, captured, detached, mutated_upvalue, &edges);
    propagateMutations(edges.items, reg_offsets, up_offsets, mutated_local, mutated_upvalue);

    const write_counts = try a.alloc(u8, total_regs);
    defer if (write_counts.len != 0) a.free(write_counts);
    @memset(write_counts, 0);
    const write_pcs = try a.alloc(u32, total_regs);
    defer if (write_pcs.len != 0) a.free(write_pcs);
    @memset(write_pcs, none);
    collectWrites(program, reg_offsets, captured, write_counts, write_pcs);

    const local_facts = try a.alloc(Fact, total_regs);
    defer if (local_facts.len != 0) a.free(local_facts);
    for (local_facts) |*fact| fact.* = .unknown;
    const upvalue_facts = try a.alloc(Fact, total_upvalues);
    errdefer if (upvalue_facts.len != 0) a.free(upvalue_facts);
    for (upvalue_facts) |*fact| fact.* = .unknown;
    const candidates = try a.alloc(Fact, total_upvalues);
    defer if (candidates.len != 0) a.free(candidates);
    const bad = try a.alloc(bool, total_upvalues);
    defer if (bad.len != 0) a.free(bad);
    const seen = try a.alloc(bool, total_upvalues);
    defer if (seen.len != 0) a.free(seen);

    var stats = Stats{};
    var changed = true;
    while (changed) {
        changed = false;
        for (program.functions.items, 0..) |maybe, function_usize| {
            const function = maybe orelse continue;
            const function_id: u32 = @intCast(function_usize);
            var needs_analysis = false;
            for (0..function.reg_count) |reg| {
                const flat = reg_offsets[function_usize] + reg;
                if (captured[flat] and write_counts[flat] == 1 and
                    !detached[flat] and !mutated_local[flat] and !hasFact(local_facts[flat]))
                {
                    needs_analysis = true;
                    break;
                }
            }
            if (!needs_analysis) continue;
            const upvalues = upvalue_facts[up_offsets[function_usize]..up_offsets[function_usize + 1]];
            var analysis = try facts_mod.buildFunctionWithUpvalues(
                a,
                program,
                symbols,
                function_id,
                true,
                upvalues,
            );
            defer analysis.deinit();
            const state = try a.alloc(ssa.ValueId, function.reg_count);
            defer if (state.len != 0) a.free(state);
            for (0..function.reg_count) |reg| {
                const flat = reg_offsets[function_usize] + reg;
                if (!captured[flat] or write_counts[flat] != 1 or detached[flat] or mutated_local[flat] or hasFact(local_facts[flat])) continue;
                const pc = write_pcs[flat];
                if (pc >= function.insts.items.len) continue;
                try ssa.stateBefore(&analysis.ssa_function, &function, pc, state);
                const fact = facts_mod.predictInstruction(
                    &analysis,
                    program,
                    symbols,
                    &function,
                    state,
                    function.insts.items[pc],
                    true,
                    upvalues,
                );
                if (hasFact(fact)) {
                    local_facts[flat] = fact;
                    stats.stable_locals += 1;
                    changed = true;
                }
            }
        }

        for (candidates) |*fact| fact.* = .unknown;
        @memset(bad, false);
        @memset(seen, false);
        for (edges.items) |edge| {
            const child = edge.child_upvalue;
            if (child >= upvalue_facts.len or mutated_upvalue[child] or hasFact(upvalue_facts[child])) continue;
            const source_fact = switch (edge.source.source) {
                .local => local_facts[reg_offsets[edge.parent] + edge.source.index],
                .upvalue => upvalue_facts[up_offsets[edge.parent] + edge.source.index],
            };
            seen[child] = true;
            mergeCandidate(&candidates[child], &bad[child], source_fact);
        }
        for (upvalue_facts, 0..) |*fact, index| {
            if (mutated_upvalue[index] or hasFact(fact.*) or !seen[index] or bad[index] or !hasFact(candidates[index])) continue;
            fact.* = candidates[index];
            changed = true;
        }
    }

    for (upvalue_facts) |fact| if (hasFact(fact)) {
        stats.known_upvalues += 1;
        switch (fact) {
            .module => stats.module_upvalues += 1,
            .function => stats.function_upvalues += 1,
            .native_global, .captured_native_global => stats.native_global_upvalues += 1,
            .native_namespace, .captured_native_namespace => stats.native_namespace_upvalues += 1,
            .native_field, .captured_native_field => stats.native_field_upvalues += 1,
            else => {},
        }
    };
    return .{
        .allocator = a,
        .offsets = up_offsets,
        .facts = upvalue_facts,
        .stats = stats,
    };
}

const test_lua = @import("root.zig");
const test_image = @import("vm_link_image.zig");
const test_model = @import("module_model.zig");

fn addTestModule(
    a: std.mem.Allocator,
    image: *test_image.Image,
    symbols: *symbols_mod.Index,
    title: []const u8,
    source: []const u8,
) !u32 {
    var chunk = try test_lua.parse(a, source);
    defer chunk.deinit();
    var model = test_model.Builder{ .allocator = a, .source = chunk.source };
    defer model.deinit();
    try model.build(chunk.body);
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const module = try image.appendModule(&program);
    try symbols.addModule(title, image, module, &model);
    return module;
}
test "captured imported function predicts one guarded target" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B'); local f=m.add; local function run(x)return f(x)end; return run");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var found = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        for (result.forFunction(&image.program, @intCast(function_id))) |fact| switch (fact) {
            .function => |id| found = found or id == target,
            else => {},
        };
    }
    try std.testing.expect(found);
    try std.testing.expect(result.stats.function_upvalues != 0);
}
test "mutated captured import remains unpredicted" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B'); local f=m.add; local function run(x)return f(x)end; f=function(x)return x+9 end; return run");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var saw_capture = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        if (function.upvalues.items.len == 0) continue;
        saw_capture = true;
        for (result.forFunction(&image.program, @intCast(function_id))) |fact|
            try std.testing.expect(fact == .unknown);
    }
    try std.testing.expect(saw_capture);
}

test "captured imported function survives a stable local alias" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={}; function e.add(x)return x+1 end; return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B');local raw=m.add;local f=raw;local function run(x)return f(x)end;return run");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var found = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        for (result.forFunction(&image.program, @intCast(function_id))) |fact| switch (fact) {
            .function => |id| found = found or id == target,
            else => {},
        };
    }
    try std.testing.expect(found);
}

test "descendant upvalue mutation invalidates sibling capture facts" {
    const a = std.testing.allocator;
    var image = test_image.Image.init(a);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(a);
    defer symbols.deinit();
    _ = try addTestModule(a, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    const module = try addTestModule(a, &image, &symbols, "Module:A", "local m=require('Module:B');local f=m.add;local function mutate()f=function(x)return x+9 end end;local function run(x)return f(x)end;return run");
    var result = try build(a, &image.program, &symbols);
    defer result.deinit();
    const linked = image.modules.items[module];
    var captured = false;
    for (linked.function_base..linked.function_base + linked.function_count) |function_id| {
        const function = image.program.functions.items[function_id] orelse continue;
        if (function.upvalues.items.len == 0) continue;
        captured = true;
        for (result.forFunction(&image.program, @intCast(function_id))) |fact|
            try std.testing.expect(fact == .unknown);
    }
    try std.testing.expect(captured);
}
