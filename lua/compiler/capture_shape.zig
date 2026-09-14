const std = @import("std");
const ir = @import("ir.zig");
const sem = @import("semantics.zig");
const cfg = @import("graph.zig");
const shape_opt = @import("shape_opt.zig");
const shape_key = @import("../abi/shape_key.zig");

const none = std.math.maxInt(u32);
const unseen = none - 1;

pub const Stats = struct {
    captured_tables: u64 = 0,
    slot_reads: u64 = 0,
    slot_writes: u64 = 0,
};

const Source = struct {
    function_id: u32,
    reg: u32,
    pc: u32,
    existing_shape: u32 = none,
    shape_id: u32 = none,
    fields: std.ArrayList(u32) = .empty,

    fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
    }
};

const CaptureEdge = struct {
    parent: u32,
    child_upvalue: u32,
    source: ir.Upvalue,
};

fn addField(allocator: std.mem.Allocator, source: *Source, sid: u32) !void {
    for (source.fields.items) |old| if (old == sid) return;
    try source.fields.append(allocator, sid);
}

fn rangeContains(base: u32, count: u32, reg: u32) bool {
    const width = if (count == ir.multi_count) @as(u32, 1) else count;
    return reg >= base and reg - base < width;
}
fn writesReg(inst: ir.Inst, reg: u32) bool {
    const info = sem.info(inst.op);
    if (info.defines and inst.dst == reg) return true;
    if (info.results and rangeContains(inst.dst, inst.count, reg)) return true;
    return switch (inst.op) {
        .numeric_for_init => inst.dst == reg,
        .numeric_for_next => inst.a == reg or inst.dst == reg,
        .generic_for_init, .generic_for_next => inst.c == reg or rangeContains(inst.dst, inst.count, reg),
        else => false,
    };
}

fn clearWrites(state: []u32, inst: ir.Inst) void {
    const info = sem.info(inst.op);
    if (info.defines and inst.dst < state.len) state[inst.dst] = none;
    if (info.results) {
        const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
        var i: u32 = 0;
        while (i < width and inst.dst + i < state.len) : (i += 1) state[inst.dst + i] = none;
    }
    switch (inst.op) {
        .numeric_for_init => if (inst.dst < state.len) {
            state[inst.dst] = none;
        },
        .numeric_for_next => {
            if (inst.a < state.len) state[inst.a] = none;
            if (inst.dst < state.len) state[inst.dst] = none;
        },
        .generic_for_init, .generic_for_next => {
            if (inst.c < state.len) state[inst.c] = none;
            const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
            var i: u32 = 0;
            while (i < width and inst.dst + i < state.len) : (i += 1) state[inst.dst + i] = none;
        },
        else => {},
    }
}

fn lessU32(_: void, lhs: u32, rhs: u32) bool {
    return lhs < rhs;
}

fn fieldSlot(fields: []const u32, sid: u32) ?u32 {
    for (fields, 0..) |field, slot| if (field == sid) return @intCast(slot);
    return null;
}
const Analysis = struct {
    allocator: std.mem.Allocator,
    program: *ir.Program,
    reg_offsets: []usize,
    up_offsets: []usize,
    captured: []bool,
    mutated_local: []bool,
    mutated_upvalue: []bool,
    source_for_reg: []u32,
    up_source: []u32,
    sources: std.ArrayList(Source) = .empty,
    edges: std.ArrayList(CaptureEdge) = .empty,

    fn deinit(self: *Analysis) void {
        for (self.sources.items) |*source| source.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.allocator.free(self.reg_offsets);
        self.allocator.free(self.up_offsets);
        if (self.captured.len != 0) self.allocator.free(self.captured);
        if (self.mutated_local.len != 0) self.allocator.free(self.mutated_local);
        if (self.mutated_upvalue.len != 0) self.allocator.free(self.mutated_upvalue);
        if (self.source_for_reg.len != 0) self.allocator.free(self.source_for_reg);
        if (self.up_source.len != 0) self.allocator.free(self.up_source);
    }

    fn flatReg(self: *const Analysis, function_id: u32, reg: u32) ?usize {
        if (function_id >= self.program.functions.items.len) return null;
        const function = self.program.functions.items[function_id] orelse return null;
        if (reg >= function.reg_count) return null;
        return self.reg_offsets[function_id] + reg;
    }

    fn flatUpvalue(self: *const Analysis, function_id: u32, index: u32) ?usize {
        if (function_id >= self.program.functions.items.len) return null;
        const function = self.program.functions.items[function_id] orelse return null;
        if (index >= function.upvalues.items.len) return null;
        return self.up_offsets[function_id] + index;
    }
};
fn initAnalysis(allocator: std.mem.Allocator, program: *ir.Program) !Analysis {
    const reg_offsets = try allocator.alloc(usize, program.functions.items.len + 1);
    errdefer allocator.free(reg_offsets);
    const up_offsets = try allocator.alloc(usize, program.functions.items.len + 1);
    errdefer allocator.free(up_offsets);
    reg_offsets[0] = 0;
    up_offsets[0] = 0;
    for (program.functions.items, 0..) |maybe, id| {
        reg_offsets[id + 1] = reg_offsets[id] + if (maybe) |function| function.reg_count else 0;
        up_offsets[id + 1] = up_offsets[id] + if (maybe) |function| function.upvalues.items.len else 0;
    }
    const captured = try allocator.alloc(bool, reg_offsets[program.functions.items.len]);
    errdefer if (captured.len != 0) allocator.free(captured);
    @memset(captured, false);
    const mutated_local = try allocator.alloc(bool, captured.len);
    errdefer if (mutated_local.len != 0) allocator.free(mutated_local);
    @memset(mutated_local, false);
    const mutated_upvalue = try allocator.alloc(bool, up_offsets[program.functions.items.len]);
    errdefer if (mutated_upvalue.len != 0) allocator.free(mutated_upvalue);
    @memset(mutated_upvalue, false);
    const source_for_reg = try allocator.alloc(u32, captured.len);
    errdefer if (source_for_reg.len != 0) allocator.free(source_for_reg);
    @memset(source_for_reg, none);
    const up_source = try allocator.alloc(u32, mutated_upvalue.len);
    errdefer if (up_source.len != 0) allocator.free(up_source);
    @memset(up_source, none);
    return .{
        .allocator = allocator,
        .program = program,
        .reg_offsets = reg_offsets,
        .up_offsets = up_offsets,
        .captured = captured,
        .mutated_local = mutated_local,
        .mutated_upvalue = mutated_upvalue,
        .source_for_reg = source_for_reg,
        .up_source = up_source,
    };
}
fn collectCaptureGraph(analysis: *Analysis) !void {
    for (analysis.program.functions.items, 0..) |maybe, parent_usize| {
        const parent = maybe orelse continue;
        const parent_id: u32 = @intCast(parent_usize);
        for (parent.insts.items) |inst| {
            if (inst.op == .set_upvalue) {
                const flat = analysis.flatUpvalue(parent_id, inst.a) orelse return error.BadUpvalue;
                analysis.mutated_upvalue[flat] = true;
            }
            const child_id = sem.captureTarget(inst) orelse continue;
            if (child_id >= analysis.program.functions.items.len) return error.BadFunctionReference;
            const child = analysis.program.functions.items[child_id] orelse return error.IncompleteProgram;
            for (child.upvalues.items, 0..) |upvalue, child_index| {
                if (upvalue.source == .local) {
                    const flat = analysis.flatReg(parent_id, upvalue.index) orelse return error.BadRegister;
                    analysis.captured[flat] = true;
                } else if (analysis.flatUpvalue(parent_id, upvalue.index) == null) {
                    return error.BadUpvalue;
                }
                try analysis.edges.append(analysis.allocator, .{
                    .parent = parent_id,
                    .child_upvalue = @intCast(analysis.up_offsets[child_id] + child_index),
                    .source = upvalue,
                });
            }
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.edges.items) |edge| {
            if (!analysis.mutated_upvalue[edge.child_upvalue]) continue;
            switch (edge.source.source) {
                .local => {
                    const flat = analysis.flatReg(edge.parent, edge.source.index) orelse return error.BadRegister;
                    if (!analysis.mutated_local[flat]) {
                        analysis.mutated_local[flat] = true;
                        changed = true;
                    }
                },
                .upvalue => {
                    const flat = analysis.flatUpvalue(edge.parent, edge.source.index) orelse return error.BadUpvalue;
                    if (!analysis.mutated_upvalue[flat]) {
                        analysis.mutated_upvalue[flat] = true;
                        changed = true;
                    }
                },
            }
        }
    }
}
fn noteWrite(
    analysis: *Analysis,
    writes: []u8,
    allocation_pc: []u32,
    allocation_shape: []u32,
    function_id: u32,
    reg: u32,
    pc: u32,
    inst: ir.Inst,
) !void {
    const flat = analysis.flatReg(function_id, reg) orelse return error.BadRegister;
    if (!analysis.captured[flat]) return;
    writes[flat] +|= 1;
    if ((inst.op == .new_table or inst.op == .new_table_shape) and inst.dst == reg) {
        allocation_pc[flat] = pc;
        allocation_shape[flat] = if (inst.op == .new_table_shape) inst.aux else none;
    }
}

fn discoverSources(analysis: *Analysis) !void {
    const total_regs = analysis.captured.len;
    const writes = try analysis.allocator.alloc(u8, total_regs);
    defer if (writes.len != 0) analysis.allocator.free(writes);
    @memset(writes, 0);
    const allocation_pc = try analysis.allocator.alloc(u32, total_regs);
    defer if (allocation_pc.len != 0) analysis.allocator.free(allocation_pc);
    @memset(allocation_pc, none);
    const allocation_shape = try analysis.allocator.alloc(u32, total_regs);
    defer if (allocation_shape.len != 0) analysis.allocator.free(allocation_shape);
    @memset(allocation_shape, none);
    const detached = try analysis.allocator.alloc(bool, total_regs);
    defer if (detached.len != 0) analysis.allocator.free(detached);
    @memset(detached, false);

    for (analysis.program.functions.items, 0..) |maybe, function_usize| {
        const function = maybe orelse continue;
        const function_id: u32 = @intCast(function_usize);
        for (function.insts.items, 0..) |inst, pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const info = sem.info(inst.op);
            if (info.defines) try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.dst, pc, inst);
            if (info.results) {
                const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
                var i: u32 = 0;
                while (i < width) : (i += 1) try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.dst + i, pc, inst);
            }
            switch (inst.op) {
                .numeric_for_init => try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.dst, pc, inst),
                .numeric_for_next => {
                    try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.a, pc, inst);
                    try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.dst, pc, inst);
                },
                .generic_for_init, .generic_for_next => {
                    try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.c, pc, inst);
                    const width: u32 = if (inst.count == ir.multi_count) 1 else inst.count;
                    var i: u32 = 0;
                    while (i < width) : (i += 1) try noteWrite(analysis, writes, allocation_pc, allocation_shape, function_id, inst.dst + i, pc, inst);
                },
                .detach_cell => {
                    const flat = analysis.flatReg(function_id, inst.a) orelse return error.BadRegister;
                    if (analysis.captured[flat]) detached[flat] = true;
                },
                else => {},
            }
        }
    }

    for (analysis.program.functions.items, 0..) |maybe, function_usize| {
        const function = maybe orelse continue;
        const function_id: u32 = @intCast(function_usize);
        for (0..function.reg_count) |reg_usize| {
            const reg: u32 = @intCast(reg_usize);
            const flat = analysis.reg_offsets[function_id] + reg;
            if (!analysis.captured[flat] or reg < function.param_count) continue;
            if (writes[flat] != 1 or allocation_pc[flat] == none) continue;
            if (analysis.mutated_local[flat] or detached[flat]) continue;
            const source_id: u32 = @intCast(analysis.sources.items.len);
            try analysis.sources.append(analysis.allocator, .{
                .function_id = function_id,
                .reg = reg,
                .pc = allocation_pc[flat],
                .existing_shape = allocation_shape[flat],
            });
            analysis.source_for_reg[flat] = source_id;
        }
    }
}
fn resolveUpvalueSources(analysis: *Analysis) !void {
    if (analysis.up_source.len == 0) return;
    const candidate = try analysis.allocator.alloc(u32, analysis.up_source.len);
    defer analysis.allocator.free(candidate);
    const seen = try analysis.allocator.alloc(bool, analysis.up_source.len);
    defer analysis.allocator.free(seen);
    const bad = try analysis.allocator.alloc(bool, analysis.up_source.len);
    defer analysis.allocator.free(bad);
    const unresolved = try analysis.allocator.alloc(bool, analysis.up_source.len);
    defer analysis.allocator.free(unresolved);

    var changed = true;
    while (changed) {
        changed = false;
        @memset(candidate, none);
        @memset(seen, false);
        @memset(bad, false);
        @memset(unresolved, false);
        for (analysis.edges.items) |edge| {
            const child = edge.child_upvalue;
            var source_id: u32 = none;
            switch (edge.source.source) {
                .local => {
                    const flat = analysis.flatReg(edge.parent, edge.source.index) orelse return error.BadRegister;
                    source_id = analysis.source_for_reg[flat];
                    if (source_id == none) bad[child] = true;
                },
                .upvalue => {
                    const flat = analysis.flatUpvalue(edge.parent, edge.source.index) orelse return error.BadUpvalue;
                    source_id = analysis.up_source[flat];
                    if (source_id == none) unresolved[child] = true;
                },
            }
            seen[child] = true;
            if (source_id == none) continue;
            if (candidate[child] == none) candidate[child] = source_id else if (candidate[child] != source_id) bad[child] = true;
        }
        for (analysis.up_source, 0..) |*known, index| {
            if (known.* != none or !seen[index] or bad[index] or unresolved[index] or candidate[index] == none) continue;
            known.* = candidate[index];
            changed = true;
        }
    }
}
const Flow = struct {
    allocator: std.mem.Allocator,
    graph: cfg.Graph,
    entry: []?[]u32,

    fn deinit(self: *Flow) void {
        for (self.entry) |maybe| if (maybe) |state| if (state.len != 0) self.allocator.free(state);
        if (self.entry.len != 0) self.allocator.free(self.entry);
        self.graph.deinit();
    }
};

fn transfer(analysis: *const Analysis, function_id: u32, function: *const ir.Function, pc: u32, state: []u32) !void {
    const inst = function.insts.items[pc];
    switch (inst.op) {
        .move => {
            const source = if (inst.a < state.len) state[inst.a] else none;
            clearWrites(state, inst);
            if (inst.dst < state.len) state[inst.dst] = source;
        },
        .new_table, .new_table_shape => {
            clearWrites(state, inst);
            const flat = analysis.flatReg(function_id, inst.dst) orelse return error.BadRegister;
            const source_id = analysis.source_for_reg[flat];
            if (source_id != none and analysis.sources.items[source_id].pc == pc) state[inst.dst] = source_id;
        },
        .get_upvalue => {
            clearWrites(state, inst);
            const flat = analysis.flatUpvalue(function_id, inst.a) orelse return error.BadUpvalue;
            if (inst.dst < state.len) state[inst.dst] = analysis.up_source[flat];
        },
        else => clearWrites(state, inst),
    }
}

fn mergeState(dst: []u32, src: []const u32) bool {
    var changed = false;
    for (dst, src) |*old, incoming| {
        if (old.* == incoming or old.* == none) continue;
        old.* = none;
        changed = true;
    }
    return changed;
}
fn buildFlow(analysis: *const Analysis, function_id: u32, function: *const ir.Function) !Flow {
    var graph = try cfg.build(analysis.allocator, function);
    errdefer graph.deinit();
    const entry = try analysis.allocator.alloc(?[]u32, graph.blocks.items.len);
    errdefer if (entry.len != 0) analysis.allocator.free(entry);
    @memset(entry, null);
    var flow = Flow{ .allocator = analysis.allocator, .graph = graph, .entry = entry };
    errdefer flow.deinit();
    if (flow.entry.len == 0) return flow;
    flow.entry[0] = try analysis.allocator.alloc(u32, function.reg_count);
    @memset(flow.entry[0].?, none);

    const queued = try analysis.allocator.alloc(bool, flow.entry.len);
    defer analysis.allocator.free(queued);
    @memset(queued, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(analysis.allocator);
    try work.append(analysis.allocator, 0);
    queued[0] = true;
    const state = try analysis.allocator.alloc(u32, function.reg_count);
    defer if (state.len != 0) analysis.allocator.free(state);

    while (work.pop()) |block_id| {
        queued[block_id] = false;
        const input = flow.entry[block_id] orelse continue;
        @memcpy(state, input);
        const block = flow.graph.blocks.items[block_id];
        for (block.start..block.end) |pc| try transfer(analysis, function_id, function, @intCast(pc), state);
        for (block.succ) |next_opt| if (next_opt) |next| {
            var changed = false;
            if (flow.entry[next]) |dest| {
                changed = mergeState(dest, state);
            } else {
                flow.entry[next] = try analysis.allocator.dupe(u32, state);
                changed = true;
            }
            if (changed and !queued[next]) {
                try work.append(analysis.allocator, next);
                queued[next] = true;
            }
        };
    }
    return flow;
}
fn collectFields(analysis: *Analysis) !void {
    for (analysis.program.functions.items, 0..) |maybe, function_usize| {
        const function = maybe orelse continue;
        const function_id: u32 = @intCast(function_usize);
        var flow = try buildFlow(analysis, function_id, &function);
        defer flow.deinit();
        const state = try analysis.allocator.alloc(u32, function.reg_count);
        defer if (state.len != 0) analysis.allocator.free(state);
        for (flow.graph.blocks.items, 0..) |block, block_id| {
            const input = flow.entry[block_id] orelse continue;
            @memcpy(state, input);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = function.insts.items[pc];
                if ((inst.op == .get_field or inst.op == .set_field) and inst.a < state.len) {
                    const source_id = state[inst.a];
                    if (source_id != none) try addField(analysis.allocator, &analysis.sources.items[source_id], try shape_key.string(inst.aux));
                }
                try transfer(analysis, function_id, &function, pc, state);
            }
        }
    }
}

fn appendUnique(allocator: std.mem.Allocator, keys: *std.ArrayList(u32), values: []const u32) !void {
    for (values) |value| {
        var found = false;
        for (keys.items) |old| if (old == value) {
            found = true;
            break;
        };
        if (!found) try keys.append(allocator, value);
    }
}
fn assignShapes(analysis: *Analysis, stats: *Stats) !void {
    for (analysis.sources.items) |*source| {
        if (source.fields.items.len == 0) continue;
        std.sort.heap(u32, source.fields.items, {}, lessU32);
        const function = &(analysis.program.functions.items[source.function_id] orelse return error.IncompleteProgram);
        if (source.pc >= function.insts.items.len) return error.BadAllocation;
        const allocation = &function.insts.items[source.pc];
        if (allocation.op != .new_table and allocation.op != .new_table_shape) return error.BadAllocation;

        var keys: std.ArrayList(u32) = .empty;
        defer keys.deinit(analysis.allocator);
        var choice_count: u32 = 0;
        if (source.existing_shape != none) {
            if (source.existing_shape >= analysis.program.shapes.items.len) return error.BadShape;
            const old = analysis.program.shapes.items[source.existing_shape];
            if (old.field_keys.items.len != old.field_count) continue;
            try keys.appendSlice(analysis.allocator, old.field_keys.items);
            choice_count = old.choice_count;
        }
        try appendUnique(analysis.allocator, &keys, source.fields.items);
        if (keys.items.len == 0) continue;
        const shape_id = try shape_opt.findOrAddShape(
            analysis.allocator,
            analysis.program,
            @intCast(keys.items.len),
            keys.items,
            choice_count,
            true,
        );
        source.shape_id = shape_id;
        if (allocation.op != .new_table_shape or allocation.aux != shape_id) {
            allocation.op = .new_table_shape;
            allocation.aux = shape_id;
            stats.captured_tables += 1;
        }
    }
}
fn rewriteFields(analysis: *Analysis, stats: *Stats) !void {
    for (analysis.program.functions.items, 0..) |*maybe, function_usize| {
        const function = if (maybe.*) |*value| value else continue;
        const function_id: u32 = @intCast(function_usize);
        var flow = try buildFlow(analysis, function_id, function);
        defer flow.deinit();
        const state = try analysis.allocator.alloc(u32, function.reg_count);
        defer if (state.len != 0) analysis.allocator.free(state);
        for (flow.graph.blocks.items, 0..) |block, block_id| {
            const input = flow.entry[block_id] orelse continue;
            @memcpy(state, input);
            for (block.start..block.end) |pc_usize| {
                const pc: u32 = @intCast(pc_usize);
                const inst = &function.insts.items[pc];
                if ((inst.op == .get_field or inst.op == .set_field) and inst.a < state.len) {
                    const source_id = state[inst.a];
                    if (source_id != none) {
                        const source = analysis.sources.items[source_id];
                        if (source.shape_id != none) {
                            const fields = analysis.program.shapes.items[source.shape_id].field_keys.items;
                            if (fieldSlot(fields, try shape_key.string(inst.aux))) |slot| {
                                if (inst.op == .get_field) {
                                    inst.op = .get_slot;
                                    stats.slot_reads += 1;
                                } else {
                                    inst.op = .set_slot;
                                    stats.slot_writes += 1;
                                }
                                inst.aux = slot;
                            }
                        }
                    }
                }
                try transfer(analysis, function_id, function, pc, state);
            }
        }
    }
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return error.LateCaptureShapeAnalysis;
    var analysis = try initAnalysis(allocator, program);
    defer analysis.deinit();
    try collectCaptureGraph(&analysis);
    try discoverSources(&analysis);
    if (analysis.sources.items.len == 0) return .{};
    try resolveUpvalueSources(&analysis);
    try collectFields(&analysis);
    var stats = Stats{};
    try assignShapes(&analysis, &stats);
    try rewriteFields(&analysis, &stats);
    return stats;
}
