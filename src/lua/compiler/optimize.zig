const module_function = @import("module_function.zig");
const shape_flow = @import("shape_flow.zig");
const global_lower = @import("global_lower.zig");
const static_fields = @import("static_fields.zig");
const static_index = @import("static_index.zig");
const devirtualize = @import("devirtualize.zig");
const callgraph = @import("callgraph.zig");
const ref_lower = @import("ref_lower.zig");
const compare_fuse = @import("compare_fuse.zig");
const std = @import("std");
const ir = @import("ir.zig");
const inline_pass = @import("inline.zig");
const dce = @import("dce.zig");
const regalloc = @import("regalloc.zig");
const flow = @import("flow.zig");
const shape = @import("shape_opt.zig");
const const_shape = @import("const_shape.zig");
const capture_shape = @import("capture_shape.zig");
const scalar = @import("scalar_replace.zig");
const data = @import("data.zig");
const numbering = @import("value_numbering.zig");
const interproc = @import("interproc.zig");
const simplify = @import("simplify.zig");
const verify = @import("verify.zig");

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
    static_indexes: static_index.Stats = .{},
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
    stats.static_indexes = try static_index.run(allocator, program);
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

fn markAotDynamicCallables(allocator: std.mem.Allocator, program: *ir.Program) !void {
    var graph = try callgraph.build(allocator, program);
    defer graph.deinit();
    for (program.functions.items, 0..) |*maybe_function, id| {
        if (maybe_function.*) |*function| {
            function.aot_dynamic_callable = !graph.closed[id];
        }
    }
}

pub fn finalizeAot(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    try verify.run(allocator, program);
    if (program.references_lowered) return stats;
    stats.direct = try devirtualize.runScoped(allocator, program);
    addStats(shape_flow.Stats, &stats.layouts, try shape_flow.run(allocator, program));
    stats.module_functions = try module_function.run(allocator, program);
    try markAotDynamicCallables(allocator, program);
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
