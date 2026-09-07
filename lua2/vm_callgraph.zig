const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const lua = @import("root.zig");

pub const CallSite = struct {
    caller: u32,
    pc: u32,
    callee: u32,
    callee_value: ssa.ValueId,
    closure_pc: u32 = ssa.invalid_value,
};

pub const InlineCandidate = struct {
    caller: u32,
    pc: u32,
    callee: u32,
    closure_pc: u32,
    closure_value: ssa.ValueId,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(CallSite) = .empty,
    candidates: std.ArrayList(InlineCandidate) = .empty,
    static_call_count: []u32,
    closed: []bool,

    pub fn deinit(self: *Graph) void {
        self.calls.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.allocator.free(self.closed);
        if (self.static_call_count.len != 0) self.allocator.free(self.static_call_count);
    }
};

fn directClosureTarget(
    graph_function: *const ssa.Function,
    caller: *const ir.Function,
    value: ssa.ValueId,
) ?struct { target: u32, closure_pc: u32, closure_value: ssa.ValueId } {
    const canonical = graph_function.canonicalValue(value);
    if (canonical == ssa.invalid_value or canonical >= graph_function.values.items.len) return null;
    const node = graph_function.values.items[canonical];
    if (node.kind != .instruction or node.pc >= caller.insts.items.len) return null;
    const producer = caller.insts.items[node.pc];
    if (producer.op != .closure and producer.op != .load_function) return null;
    return .{ .target = producer.aux, .closure_pc = node.pc, .closure_value = canonical };
}

pub fn build(allocator: std.mem.Allocator, program: *const ir.Program) !Graph {
    const static_call_count = try allocator.alloc(u32, program.functions.items.len);
    @memset(static_call_count, 0);
    const closed = try allocator.alloc(bool, program.functions.items.len);
    @memset(closed, true);
    closed[program.root_function] = false;
    var graph = Graph{ .allocator = allocator, .static_call_count = static_call_count, .closed = closed };
    errdefer graph.deinit();

    for (program.functions.items, 0..) |maybe_caller, caller_id_usize| {
        const caller = maybe_caller orelse continue;
        const caller_id: u32 = @intCast(caller_id_usize);
        var graph_function = try ssa.build(allocator, program, &caller);
        defer graph_function.deinit();
        const state = try allocator.alloc(ssa.ValueId, caller.reg_count);
        defer if (state.len != 0) allocator.free(state);

        var value_calls: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer value_calls.deinit(allocator);
        for (caller.insts.items, 0..) |inst, pc_usize| {
            if (inst.op == .call_local or inst.op == .call_local_vararg or
                inst.op == .call_scoped or inst.op == .call_scoped_vararg or
                inst.op == .direct_call or inst.op == .direct_call_vararg) {
                if (inst.a >= program.functions.items.len) return error.BadFunctionReference;
                graph.static_call_count[inst.a] +|= 1;
                try graph.calls.append(allocator, .{ .caller = caller_id, .pc = @intCast(pc_usize), .callee = inst.a, .callee_value = ssa.invalid_value });
                continue;
            }
            if (inst.op != .call and inst.op != .call_vararg) continue;
            if (inst.a >= state.len) continue;
            const pc: u32 = @intCast(pc_usize);
            if (graph_function.entry_states[graph_function.graph.block_of_pc[pc]] == null) continue;
            try ssa.stateBefore(&graph_function, &caller, pc, state);
            const resolved = directClosureTarget(&graph_function, &caller, state[inst.a]) orelse continue;
            if (resolved.target >= program.functions.items.len or program.functions.items[resolved.target] == null) continue;
            const use_entry = try value_calls.getOrPut(allocator, resolved.closure_value);
            if (!use_entry.found_existing) use_entry.value_ptr.* = 0;
            use_entry.value_ptr.* += 1;
            graph.static_call_count[resolved.target] +|= 1;
            try graph.calls.append(allocator, .{
                .caller = caller_id,
                .pc = pc,
                .callee = resolved.target,
                .callee_value = resolved.closure_value,
                .closure_pc = resolved.closure_pc,
            });
            if (graph_function.values.items[resolved.closure_value].uses == 1) {
                try graph.candidates.append(allocator, .{
                    .caller = caller_id,
                    .pc = pc,
                    .callee = resolved.target,
                    .closure_pc = resolved.closure_pc,
                    .closure_value = resolved.closure_value,
                });
            }
        }
        for (caller.insts.items, 0..) |inst, pc| if (inst.op == .closure or inst.op == .load_function) {
            const raw = graph_function.def_ids.get((@as(u64, pc) << 32) | inst.dst) orelse {
                graph.closed[inst.aux] = false;
                continue;
            };
            const id = graph_function.canonicalValue(raw);
            if (graph_function.values.items[id].uses != (value_calls.get(id) orelse 0)) graph.closed[inst.aux] = false;
        };
    }

    // The single-use test above is local to a closure SSA value. Require the
    // target function itself to have exactly one statically resolved call as
    // well before exposing it as a mandatory-inline candidate.
    var write: usize = 0;
    for (graph.candidates.items) |candidate| {
        if (graph.static_call_count[candidate.callee] != 1 or !graph.closed[candidate.callee]) continue;
        graph.candidates.items[write] = candidate;
        write += 1;
    }
    graph.candidates.shrinkRetainingCapacity(write);
    return graph;
}

test "single-use local closure becomes mandatory-inline candidate" {
    const source =
        \\local function add1(x)
        \\  return x + 1
        \\end
        \\return add1(4)
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.candidates.items.len);
    try std.testing.expectEqual(@as(u32, 1), graph.candidates.items[0].callee);
}

test "escaping closure is not mandatory-inline candidate" {
    const source =
        \\local function add1(x)
        \\  return x + 1
        \\end
        \\local keep = add1
        \\return keep, add1(4)
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 0), graph.candidates.items.len);
}

test "recursive local closure is not a mandatory-inline candidate" {
    const source =
        \\local function fact(n)
        \\  if n <= 1 then return 1 end
        \\  return n * fact(n - 1)
        \\end
        \\return fact(4)
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 0), graph.candidates.items.len);
}

test "module function values remain escaping after numeric direct calls" {
    const source = "local function f(x)return x+1 end;local keep=f;return keep";
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    const root = &program.functions.items[program.root_function].?;
    var target: ?u32 = null;
    for (root.insts.items) |*inst| {
        if (inst.op != .closure) continue;
        target = inst.aux;
        inst.op = .load_function;
        break;
    }
    const callee = target orelse return error.MissingFunction;
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit();
    try std.testing.expect(!graph.closed[callee]);
}
