const std = @import("std");
const ir = @import("vm_ir.zig");
const facts_mod = @import("vm_link_facts.zig");
const symbols_mod = @import("vm_link_symbols.zig");
const link_image = @import("vm_link_image.zig");
const lua = @import("root.zig");
const model = @import("module_model.zig");

pub const Edge = facts_mod.Edge;

pub const Graph = struct {
    allocator: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    incoming: []u32,
    component: []u32,
    component_count: u32 = 0,

    pub fn deinit(self: *Graph) void {
        self.edges.deinit(self.allocator);
        if (self.incoming.len != 0) self.allocator.free(self.incoming);
        if (self.component.len != 0) self.allocator.free(self.component);
    }

    pub fn sameScc(self: *const Graph, a: u32, b: u32) bool {
        return a < self.component.len and b < self.component.len and self.component[a] == self.component[b];
    }
};

const Csr = struct {
    allocator: std.mem.Allocator,
    offsets: []u32,
    targets: []u32,
    fn deinit(self: *Csr) void {
        if (self.offsets.len != 0) self.allocator.free(self.offsets);
        if (self.targets.len != 0) self.allocator.free(self.targets);
    }
};

fn buildCsr(allocator: std.mem.Allocator, node_count: usize, edges: []const Edge, reverse: bool) !Csr {
    const offsets = try allocator.alloc(u32, node_count + 1);
    errdefer allocator.free(offsets);
    @memset(offsets, 0);
    for (edges) |edge| {
        const from = if (reverse) edge.callee else edge.caller;
        const to = if (reverse) edge.caller else edge.callee;
        if (from >= node_count or to >= node_count) continue;
        offsets[from + 1] += 1;
    }
    for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
    const targets = try allocator.alloc(u32, offsets[node_count]);
    errdefer allocator.free(targets);
    const cursor = try allocator.dupe(u32, offsets[0..node_count]);
    defer allocator.free(cursor);
    for (edges) |edge| {
        const from = if (reverse) edge.callee else edge.caller;
        const to = if (reverse) edge.caller else edge.callee;
        if (from >= node_count or to >= node_count) continue;
        targets[cursor[from]] = to;
        cursor[from] += 1;
    }
    return .{ .allocator = allocator, .offsets = offsets, .targets = targets };
}

const DfsFrame = struct { node: u32, next: u32 };

fn assignScc(graph: *Graph, node_count: usize) !void {
    var forward = try buildCsr(graph.allocator, node_count, graph.edges.items, false);
    defer forward.deinit();
    var reverse = try buildCsr(graph.allocator, node_count, graph.edges.items, true);
    defer reverse.deinit();
    const seen = try graph.allocator.alloc(bool, node_count);
    defer graph.allocator.free(seen);
    @memset(seen, false);
    var finish: std.ArrayList(u32) = .empty;
    defer finish.deinit(graph.allocator);
    var dfs: std.ArrayList(DfsFrame) = .empty;
    defer dfs.deinit(graph.allocator);

    for (0..node_count) |start_usize| {
        if (seen[start_usize]) continue;
        const start: u32 = @intCast(start_usize);
        seen[start] = true;
        try dfs.append(graph.allocator, .{ .node = start, .next = forward.offsets[start] });
        while (dfs.items.len != 0) {
            const top_index = dfs.items.len - 1;
            const node = dfs.items[top_index].node;
            if (dfs.items[top_index].next < forward.offsets[node + 1]) {
                const edge_index = dfs.items[top_index].next;
                dfs.items[top_index].next += 1;
                const target = forward.targets[edge_index];
                if (!seen[target]) {
                    seen[target] = true;
                    try dfs.append(graph.allocator, .{ .node = target, .next = forward.offsets[target] });
                }
            } else {
                _ = dfs.pop();
                try finish.append(graph.allocator, node);
            }
        }
    }

    @memset(graph.component, std.math.maxInt(u32));
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(graph.allocator);
    var component_id: u32 = 0;
    var order_index = finish.items.len;
    while (order_index != 0) {
        order_index -= 1;
        const start = finish.items[order_index];
        if (graph.component[start] != std.math.maxInt(u32)) continue;
        graph.component[start] = component_id;
        try stack.append(graph.allocator, start);
        while (stack.pop()) |node| {
            var edge_index = reverse.offsets[node];
            while (edge_index < reverse.offsets[node + 1]) : (edge_index += 1) {
                const target = reverse.targets[edge_index];
                if (graph.component[target] != std.math.maxInt(u32)) continue;
                graph.component[target] = component_id;
                try stack.append(graph.allocator, target);
            }
        }
        component_id += 1;
    }
    graph.component_count = component_id;
}

pub fn build(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    symbols: *const symbols_mod.Index,
) !Graph {
    const incoming = try allocator.alloc(u32, program.functions.items.len);
    errdefer allocator.free(incoming);
    @memset(incoming, 0);
    const component = try allocator.alloc(u32, program.functions.items.len);
    errdefer allocator.free(component);
    var graph = Graph{ .allocator = allocator, .incoming = incoming, .component = component };
    errdefer graph.deinit();
    const require_safe = facts_mod.requireBuiltinSafe(program);
    for (program.functions.items, 0..) |maybe_function, function_index| {
        if (maybe_function == null) continue;
        const function_id: u32 = @intCast(function_index);
        var analysis = try facts_mod.buildFunction(allocator, program, symbols, function_id, require_safe);
        defer analysis.deinit();
        for (analysis.edges.items) |edge| {
            if (edge.callee >= incoming.len) return error.BadCallTarget;
            try graph.edges.append(allocator, edge);
            incoming[edge.callee] +|= 1;
        }
    }
    try assignScc(&graph, program.functions.items.len);
    return graph;
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

test "global call graph counts one cross-module caller" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(std.testing.allocator);
    defer symbols.deinit();
    _ = try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local export={}; function export.add(x) return x+1 end; return export");
    _ = try addSource(std.testing.allocator, &image, &symbols, "Module:A", "local m=require('Module:B'); return m.add(4)");
    const target = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    var graph = try build(std.testing.allocator, &image.program, &symbols);
    defer graph.deinit();
    try std.testing.expectEqual(@as(u32, 1), graph.incoming[target]);
    var found = false;
    for (graph.edges.items) |edge| {
        if (edge.callee == target) {
            found = true;
            try std.testing.expect(!graph.sameScc(edge.caller, edge.callee));
        }
    }
    try std.testing.expect(found);
}

test "SCC assignment detects recursive components" {
    const allocator = std.testing.allocator;
    const incoming = try allocator.alloc(u32, 3);
    @memset(incoming, 0);
    const component = try allocator.alloc(u32, 3);
    var graph = Graph{ .allocator = allocator, .incoming = incoming, .component = component };
    defer graph.deinit();
    try graph.edges.append(allocator, .{ .caller = 0, .pc = 0, .callee = 1 });
    try graph.edges.append(allocator, .{ .caller = 1, .pc = 0, .callee = 0 });
    try graph.edges.append(allocator, .{ .caller = 1, .pc = 1, .callee = 2 });
    try assignScc(&graph, 3);
    try std.testing.expect(graph.sameScc(0, 1));
    try std.testing.expect(!graph.sameScc(1, 2));
}
