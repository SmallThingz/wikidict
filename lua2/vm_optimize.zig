const module_function = @import("vm_module_function.zig");
const shape_flow = @import("vm_shape_flow.zig");
const global_lower = @import("vm_global_lower.zig");
const static_fields = @import("vm_static_fields.zig");
const devirtualize = @import("vm_devirtualize.zig");
const ref_lower = @import("vm_ref_lower.zig");
const compare_fuse = @import("vm_compare_fuse.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const inline_pass = @import("vm_inline.zig");
const dce = @import("vm_dce.zig");
const regalloc = @import("vm_regalloc.zig");
const flow = @import("vm_flow.zig");
const shape = @import("vm_shape_opt.zig");
const const_shape = @import("vm_const_shape.zig");
const capture_shape = @import("vm_capture_shape.zig");
const scalar = @import("vm_scalar_replace.zig");
const data = @import("vm_data.zig");
const numbering = @import("vm_value_numbering.zig");
const interproc = @import("vm_interproc.zig");
const simplify = @import("vm_ir_simplify.zig");
const verify = @import("vm_verify.zig");
const lua = @import("root.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");

pub const Stats = struct {
    inlining: inline_pass.Stats = .{},
    removed_functions: u32 = 0,
    registers: regalloc.Stats = .{},
    flow: flow.Stats = .{},
    shapes: shape.Stats = .{},
    const_shapes: const_shape.Stats = .{},
    captured_shapes: capture_shape.Stats = .{},
    layouts: shape_flow.Stats = .{},
    scalar: scalar.Stats = .{},
    data: data.Stats = .{},
    numbering: numbering.Stats = .{},
    interproc: interproc.Stats = .{},
    cleanup: simplify.Stats = .{},
    rounds: u32 = 0,
    references: ref_lower.Stats = .{},
    comparisons: compare_fuse.Stats = .{},
    globals: global_lower.Stats = .{},
    static_fields: static_fields.Stats = .{},
    direct: devirtualize.Stats = .{},
    module_functions: module_function.Stats = .{},
};

fn addStats(comptime T: type, target: *T, value: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| @field(target, field.name) += @field(value, field.name);
}
pub fn runSemantics(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    try verify.run(allocator, program);
    if (program.references_lowered) return error.AlreadyFinalized;
    while (true) {
        stats.rounds += 1;
        const facts = try flow.run(allocator, program);
        addStats(flow.Stats, &stats.flow, facts);
        const inlined = try inline_pass.run(allocator, program);
        addStats(inline_pass.Stats, &stats.inlining, inlined);
        const direct = try devirtualize.run(allocator, program);
        addStats(devirtualize.Stats, &stats.direct, direct);
        const removed = try dce.removeUnreachableFunctions(allocator, program);
        stats.removed_functions += removed;
        const summaries = try interproc.run(allocator, program);
        addStats(interproc.Stats, &stats.interproc, summaries);
        const shapes = try shape.run(allocator, program);
        addStats(shape.Stats, &stats.shapes, shapes);
        const const_shapes = try const_shape.run(allocator, program);
        addStats(const_shape.Stats, &stats.const_shapes, const_shapes);
        const captures = try capture_shape.run(allocator, program);
        addStats(capture_shape.Stats, &stats.captured_shapes, captures);
        const layouts = try shape_flow.run(allocator, program);
        addStats(shape_flow.Stats, &stats.layouts, layouts);
        const scalar_stats = try scalar.run(allocator, program);
        addStats(scalar.Stats, &stats.scalar, scalar_stats);
        const numbered = try numbering.run(allocator, program);
        addStats(numbering.Stats, &stats.numbering, numbered);
        const clean = try simplify.run(allocator, program);
        addStats(simplify.Stats, &stats.cleanup, clean);
        try verify.run(allocator, program);
        if (layouts.slot_reads + layouts.slot_writes + const_shapes.shaped_templates + const_shapes.slot_reads + const_shapes.slot_writes + captures.captured_tables + captures.slot_reads + captures.slot_writes + direct.calls + facts.folded + facts.branches + facts.removed_control + facts.specialized + inlined.inlined + removed + shapes.shaped_tables + summaries.folded + summaries.branches + summaries.specialized + summaries.removed_control + scalar_stats.objects + numbered.expressions + numbered.forwarded_reads + clean.removed_instructions == 0) break;
    }
    return stats;
}

// Whole-program facts and rewrites run before this irreversible boundary.
pub fn finalize(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    try verify.run(allocator, program);
    if (program.references_lowered) return stats;
    stats.direct = try devirtualize.runScoped(allocator, program);
    addStats(shape_flow.Stats, &stats.layouts, try shape_flow.run(allocator, program));
    stats.module_functions = try module_function.run(allocator, program);
    stats.globals = try global_lower.run(allocator, program);
    stats.static_fields = try static_fields.run(allocator, program);
    stats.references = try ref_lower.run(allocator, program);

    addStats(simplify.Stats, &stats.cleanup, try simplify.run(allocator, program));
    stats.data = try data.run(allocator, program);
    addStats(simplify.Stats, &stats.cleanup, try simplify.run(allocator, program));
    stats.comparisons = try compare_fuse.run(allocator, program);
    stats.registers = try regalloc.run(allocator, program);
    try verify.run(allocator, program);
    return stats;
}

pub fn finalizeAot(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    try verify.run(allocator, program);
    if (program.references_lowered) return stats;
    stats.direct = try devirtualize.runScoped(allocator, program);
    addStats(shape_flow.Stats, &stats.layouts, try shape_flow.run(allocator, program));
    stats.module_functions = try module_function.run(allocator, program);
    stats.globals = try global_lower.run(allocator, program);
    stats.static_fields = try static_fields.run(allocator, program);
    stats.references = try ref_lower.run(allocator, program);
    addStats(simplify.Stats, &stats.cleanup, try simplify.run(allocator, program));
    stats.data = try data.run(allocator, program);
    addStats(simplify.Stats, &stats.cleanup, try simplify.run(allocator, program));
    stats.comparisons = try compare_fuse.run(allocator, program);
    try verify.run(allocator, program);
    return stats;
}

pub fn runAot(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return finalizeAot(allocator, program);
    var stats = try runSemantics(allocator, program);
    const lowered = try finalizeAot(allocator, program);
    stats.references = lowered.references;
    stats.globals = lowered.globals;
    stats.static_fields = lowered.static_fields;
    addStats(devirtualize.Stats, &stats.direct, lowered.direct);
    stats.module_functions = lowered.module_functions;
    stats.data = lowered.data;
    stats.comparisons = lowered.comparisons;
    addStats(simplify.Stats, &stats.cleanup, lowered.cleanup);
    return stats;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return finalize(allocator, program);
    var stats = try runSemantics(allocator, program);
    const lowered = try finalize(allocator, program);
    stats.references = lowered.references;
    stats.globals = lowered.globals;
    stats.static_fields = lowered.static_fields;
    addStats(devirtualize.Stats, &stats.direct, lowered.direct);
    stats.module_functions = lowered.module_functions;
    stats.data = lowered.data;
    stats.comparisons = lowered.comparisons;
    stats.registers = lowered.registers;
    addStats(simplify.Stats, &stats.cleanup, lowered.cleanup);
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

test "optimizer composes inlining DCE and register allocation" {
    try expectSame(
        \\local x = 2
        \\local function f(a) x = x + a; return x end
        \\local y = f(5)
        \\return y, x
    );
}

test "optimizer preserves nested closure after inlining and coloring" {
    try expectSame(
        \\local outer = 9
        \\local function make(x)
        \\  return function(z) return outer + x + z end
        \\end
        \\local f = make(4)
        \\return f(8)
    );
}

test "optimizer preserves ret-var specialization through coloring" {
    try expectSame(
        \\local n = 0
        \\local function g(x) n = n + 1; return x, x + 1 end
        \\local function f(x) return 7, g(x) end
        \\local a, b, c = f(5)
        \\return a, b, c, n
    );
}

test "optimizer preserves multi-result continuation fusion through coloring" {
    try expectSame(
        \\local function pair(x) return x, x + 1 end
        \\local function pass(x) return pair(x) end
        \\local function sum(a, b) return a + b end
        \\return sum(pass(6))
    );
}

test "optimizer preserves a loop header value throughout the body" {
    try expectSame("local limit=7; local i=0; local s=0; while i<limit do local t=i*2; s=s+t; i=i+1 end; return i,s");
}
test "optimizer preserves escaping record fields" {
    try expectSame("local function make(x) local t={}; t.x=x; return t end; local a=make(2); local b=make(3); return a.x,b.x");
}
test "optimizer preserves object aliases across branch joins" {
    try expectSame("local a={}; local b={}; a.x=4; b.x=7; local t; if (...) then t=a else t=b end; t.x=9; return a.x,b.x,t.x");
}
test "optimizer does not conflate per iteration dynamic keys" {
    try expectSame("local t={}; local i=0; while i<3 do i=i+1; t[i]=i*2 end; return t[1],t[2],t[3]");
}
test "optimizer removes a constant record and every field spelling" {
    var chunk = try lua.parse(std.testing.allocator, "local t={}; t.alpha=2; t.beta=3; return t.alpha+t.beta");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try std.testing.expectEqual(@as(u64, 1), stats.scalar.objects);
    const f = p.functions.items[p.root_function].?;
    try std.testing.expect(f.insts.items.len <= 2);
    for (p.strings.items) |text| {
        try std.testing.expect(!std.mem.eql(u8, text, "alpha"));
        try std.testing.expect(!std.mem.eql(u8, text, "beta"));
    }
}

fn expectNumbers(source: []const u8, expected: []const f64) !void {
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    _ = try run(std.testing.allocator, &p);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(expected.len, out.len);
    for (out, expected) |value, n| try std.testing.expectEqual(n, value.number);
}
test "argument expressions snapshot captured bindings before later effects" {
    try expectNumbers("local x=2; local function change() x=9; return 0 end; local function pair(a,b) return a,b end; local a,b=pair(x,change()); return a,b,x", &.{ 2, 0, 9 });
}
test "method identity is read before argument mutation" {
    try expectNumbers("local t={}; function t:f(x) return 1 end; local function change() t.f=function() return 9 end; return 0 end; return t:f(change())", &.{1});
}
test "numeric for bounds are snapshots rather than mutable aliases" {
    try expectNumbers("local limit=3; local n=0; for i=1,limit do n=n+1; limit=1 end; return n,limit", &.{ 3, 1 });
}
test "parallel assignment snapshots earlier RHS before a mutating call" {
    try expectNumbers("local a=1; local b; local function change() a=9; return 4 end; a,b=a,change(); return a,b", &.{ 1, 4 });
}
test "indexed object identity is fixed before evaluating its key" {
    try expectNumbers("local t={7}; local function change() t={9}; return 1 end; local x=t[change()]; return x,t[1]", &.{ 7, 9 });
}

test "late value references eliminate constant loads and all frame slots" {
    var chunk = try lua.parse(std.testing.allocator, "return 7, -3, true, false, nil, 'text', -0, 0.5, 268435456");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try std.testing.expect(stats.references.immediate_uses >= 5);
    try std.testing.expect(stats.references.constant_uses >= 3);
    try std.testing.expect(stats.references.string_uses >= 1);
    const f = p.functions.items[p.root_function].?;
    try std.testing.expectEqual(@as(usize, 1), f.insts.items.len);
    try std.testing.expectEqual(@as(u32, 0), f.reg_count);
    const codec = @import("vm_codec.zig");
    const bytes = try codec.serialize(std.testing.allocator, &p);
    defer std.testing.allocator.free(bytes);
    var q = try codec.deserializeBorrowed(std.testing.allocator, bytes);
    defer q.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&q, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(usize, 9), values.len);
    try std.testing.expectEqual(@as(f64, 7), values[0].number);
    try std.testing.expectEqual(@as(f64, -3), values[1].number);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(values[6].number)));
    try std.testing.expectEqual(@as(f64, 0.5), values[7].number);
    try std.testing.expectEqual(@as(f64, 268435456), values[8].number);
}

test "typed definition remains live before its first later use" {
    try expectNumbers(
        "local function f(p) local first=#p+1; if not p.ready then return first end; return first end; return f({ready=true}),f({ready=false})",
        &.{ 1, 1 },
    );
}

test "loop carried object assignment survives a method call and backedge" {
    try expectNumbers(
        \\local root={}
        \\root.getParent=function(self) return self.parent end
        \\local leaf={parent=root,getParent=root.getParent}
        \\local function walk(lang)
        \\  local n=0
        \\  while lang do
        \\    n=n+1
        \\    if n>3 then return -1 end
        \\    lang=lang:getParent()
        \\  end
        \\  return n
        \\end
        \\return walk(root),walk(leaf)
    , &.{ 1, 2 });
}

test "entry block loop keeps initial parameter and backedge values distinct" {
    try expectNumbers(
        \\local count=0
        \\local function walk(lang)
        \\  while lang do
        \\    count=count+1
        \\    if count>3 then return -1 end
        \\    lang=lang.parent
        \\  end
        \\  return count
        \\end
        \\return walk({parent={}}),walk(nil)
    , &.{ 2, 2 });
}

test "inlined factory retains separate captured cells across loop calls" {
    try expectNumbers(
        \\local function make(x)
        \\  return function() return x end
        \\end
        \\local values={}
        \\for i=1,3 do values[i]=make(i) end
        \\return values[1](),values[2](),values[3]()
    , &.{ 1, 2, 3 });
}

test "factory activations separate local state but retain their shared outer cell" {
    try expectNumbers(
        \\local outer=0
        \\local function make(x)
        \\  local state=x
        \\  return function(delta) state=state+delta;outer=outer+delta;return state,outer end
        \\end
        \\local fs={}
        \\for i=1,3 do fs[i]=make(i*10) end
        \\local a,b=fs[1](1)
        \\local c,d=fs[2](2)
        \\local e,f=fs[1](3)
        \\return a,b,c,d,e,f,outer
    , &.{ 11, 1, 22, 3, 14, 6, 6 });
}
test "multi result inlining preserves activation identity for both returned closures" {
    try expectNumbers(
        \\local function make(x)
        \\  return function() x=x+1;return x end, function() return x end
        \\end
        \\local a,b={},{}
        \\for i=1,3 do a[i],b[i]=make(i*10) end
        \\return a[1](),b[1](),b[2](),a[3](),b[3]()
    , &.{ 11, 11, 20, 31, 31 });
}
