const refs = @import("vm_ref.zig");
fn markReference(ctx: anytype, value: u32) !u32 {
    if (refs.tag(value) == .constant) try mark(ctx.allocator, ctx.used, ctx.stack, refs.index(value));
    return value;
}
const std = @import("std");
const ir = @import("vm_ir.zig");
const exec = @import("vm_exec.zig");
pub const TableKey = struct { first: u32, count: u32, shape: u32 };
pub const TableContext = struct {
    entries: *const std.ArrayList(ir.ConstEntry),
    pub fn hash(self: @This(), key: TableKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(self.entries.items[key.first..][0..key.count]));
        h.update(std.mem.asBytes(&key.shape));
        return h.final();
    }
    pub fn eql(self: @This(), a: TableKey, b: TableKey) bool {
        if (a.count != b.count or a.shape != b.shape) return false;
        return std.mem.eql(u8, std.mem.sliceAsBytes(self.entries.items[a.first..][0..a.count]), std.mem.sliceAsBytes(self.entries.items[b.first..][0..b.count]));
    }
};
pub const Stats = struct { removed_constants: u64 = 0, removed_entries: u64 = 0, removed_shapes: u64 = 0 };
const Key = struct { tag: u8, bits: u64 };
fn scalarKey(p: *const ir.Program, node: ir.ConstNode) !?Key {
    return switch (node) {
        .nil => .{ .tag = 0, .bits = 0 },
        .boolean => |v| .{ .tag = 1, .bits = @intFromBool(v) },
        .string => |sid| .{ .tag = 3, .bits = sid },
        .number_bits => |bits| .{ .tag = 6, .bits = bits },
        .number => |sid| .{ .tag = 6, .bits = @bitCast(try exec.Vm.parseLuaNumber(p.strings.items[sid])) },
        .integer => |v| .{ .tag = 6, .bits = @bitCast(@as(f64, @floatFromInt(v))) },
        .table => null,
    };
}
fn mark(a: std.mem.Allocator, used: []bool, stack: *std.ArrayList(u32), id: u32) !void {
    if (id >= used.len) return error.BadConstantReference;
    if (!used[id]) {
        used[id] = true;
        try stack.append(a, id);
    }
}
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    const used = try a.alloc(bool, p.constants.items.len);
    defer a.free(used);
    @memset(used, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    for (p.functions.items) |maybe| if (maybe) |f| for (f.insts.items) |inst| if (inst.op == .load_const) try mark(a, used, &stack, inst.aux);
    for (p.functions.items) |*maybe| if (maybe.*) |*f| try refs.visit(f, .{ .allocator = a, .used = used, .stack = &stack }, markReference);
    while (stack.pop()) |id| switch (p.constants.items[id]) {
        .table => |table| for (p.const_entries.items[table.first..][0..table.count]) |entry| {
            if (entry.key != ir.implicit_list_key) try mark(a, used, &stack, entry.key);
            try mark(a, used, &stack, entry.value);
        },
        else => {},
    };
    const remap = try a.alloc(u32, used.len);
    defer a.free(remap);
    @memset(remap, ir.implicit_list_key);
    var constants: std.ArrayList(ir.ConstNode) = .empty;
    errdefer constants.deinit(a);
    var entries: std.ArrayList(ir.ConstEntry) = .empty;
    errdefer entries.deinit(a);
    var tables: std.HashMapUnmanaged(TableKey, u32, TableContext, 80) = .empty;
    defer tables.deinit(a);
    const table_context = TableContext{ .entries = &entries };
    var intern: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer intern.deinit(a);
    for (p.constants.items, 0..) |node, old| {
        if (!used[old]) continue;
        if (try scalarKey(p, node)) |key| {
            if (intern.get(key)) |id| {
                remap[old] = id;
                continue;
            }
            const id: u32 = @intCast(constants.items.len);
            const normalized: ir.ConstNode = switch (key.tag) {
                0 => .nil,
                1 => .{ .boolean = key.bits != 0 },
                3 => .{ .string = @intCast(key.bits) },
                6 => .{ .number_bits = key.bits },
                else => unreachable,
            };
            try constants.append(a, normalized);
            try intern.put(a, key, id);
            remap[old] = id;
        } else {
            const table = node.table;
            const first: u32 = @intCast(entries.items.len);
            for (p.const_entries.items[table.first..][0..table.count]) |entry| {
                const key = if (entry.key == ir.implicit_list_key) ir.implicit_list_key else remap[entry.key];
                const value = remap[entry.value];
                if (value == ir.implicit_list_key or (entry.key != ir.implicit_list_key and key == ir.implicit_list_key)) return error.NonTopologicalConstant;
                try entries.append(a, .{ .key = key, .value = value });
            }
            const key = TableKey{ .first = first, .count = table.count, .shape = table.shape };
            if (tables.getContext(key, table_context)) |id| {
                remap[old] = id;
                entries.shrinkRetainingCapacity(first);
            } else {
                remap[old] = @intCast(constants.items.len);
                try constants.append(a, .{ .table = .{ .first = first, .count = table.count, .shape = table.shape } });
                try tables.putContext(a, key, remap[old], table_context);
            }
        }
    }
    for (p.functions.items) |*maybe| if (maybe.*) |*f| for (f.insts.items) |*inst| if (inst.op == .load_const) {
        inst.aux = remap[inst.aux];
    };
    for (p.functions.items) |*maybe| if (maybe.*) |*f| try refs.visit(f, @as([]const u32, remap), refs.remapConstant);
    stats.removed_constants = p.constants.items.len - constants.items.len;
    stats.removed_entries = p.const_entries.items.len - entries.items.len;
    p.constants.deinit(a);
    p.constants = constants;
    p.const_entries.deinit(a);
    p.const_entries = entries;
    p.folded_numbers.clearRetainingCapacity();
    for (p.constants.items, 0..) |node, id| if (node == .number_bits) try p.folded_numbers.put(a, node.number_bits, @intCast(id));
    const shape_used = try a.alloc(bool, p.shapes.items.len);
    defer a.free(shape_used);
    @memset(shape_used, false);
    if (p.global_shape) |id| shape_used[id] = true;
    for (p.constants.items) |node| if (node == .table and node.table.shape != ir.no_shape) {
        if (node.table.shape >= shape_used.len) return error.BadShape;
        shape_used[node.table.shape] = true;
    };
    for (p.functions.items) |maybe| if (maybe) |f| for (f.insts.items) |inst| if (inst.op == .new_table_shape) {
        shape_used[inst.aux] = true;
    };
    const shape_map = try a.alloc(u32, shape_used.len);
    defer a.free(shape_map);
    var shapes: std.ArrayList(ir.Shape) = .empty;
    errdefer shapes.deinit(a);
    try shapes.ensureTotalCapacity(a, p.shapes.items.len);
    for (p.shapes.items, 0..) |*shape, id| {
        if (shape_used[id]) {
            shape_map[id] = @intCast(shapes.items.len);
            shapes.appendAssumeCapacity(shape.*);
        } else {
            shape.deinit(a);
            stats.removed_shapes += 1;
        }
    }
    for (p.functions.items) |*maybe| if (maybe.*) |*f| for (f.insts.items) |*inst| if (inst.op == .new_table_shape) {
        inst.aux = shape_map[inst.aux];
    };
    for (p.constants.items) |*node| if (node.* == .table and node.table.shape != ir.no_shape) {
        node.table.shape = shape_map[node.table.shape];
    };
    if (p.global_shape) |id| p.global_shape = shape_map[id];
    p.shapes.deinit(a);
    p.shapes = shapes;
    return stats;
}
const lua = @import("root.zig");
const codec = @import("vm_codec.zig");
test "list positions are implicit and repeated scalar nodes deduplicate" {
    var chunk = try lua.parse(std.testing.allocator, "return {'same','same', [1]='replacement', 'last'}");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try std.testing.expect(stats.removed_constants != 0);
    for (p.constants.items) |node| try std.testing.expect(node != .integer);
    const bytes = try codec.serialize(std.testing.allocator, &p);
    defer std.testing.allocator.free(bytes);
    var decoded = try codec.deserialize(std.testing.allocator, bytes);
    defer decoded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&decoded, &.{});
    defer exec.Vm.freeResults(values);
    const table = values[0].table;
    try std.testing.expectEqualStrings("replacement", table.rawGet(.{ .number = 1 }).?.string);
    try std.testing.expectEqualStrings("same", table.rawGet(.{ .number = 2 }).?.string);
    try std.testing.expectEqualStrings("last", table.rawGet(.{ .number = 3 }).?.string);
}

test "deduplicated table templates still materialize distinct mutable objects" {
    const source = "local t={{x=1},{x=1}}; t[1].x=9; return t[1].x,t[2].x,t[1]==t[2]";
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try run(std.testing.allocator, &p);
    try std.testing.expect(stats.removed_entries != 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = @import("vm_exec.zig");
    var vm = try execution.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&p, &.{});
    defer execution.Vm.freeResults(values);
    try std.testing.expectEqual(@as(f64, 9), values[0].number);
    try std.testing.expectEqual(@as(f64, 1), values[1].number);
    try std.testing.expect(!values[2].boolean);
}

test "constant-table shapes survive constant and shape compaction" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local e={numbers={}};e.numbers[1]=4;e.numbers[2]=5;return e.numbers[1],e.numbers[2]");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try @import("vm_const_shape.zig").run(a, &p);
    _ = try run(a, &p);
    var saw_shape = false;
    for (p.constants.items) |node| {
        if (node == .table and node.table.shape != ir.no_shape) saw_shape = true;
    }
    try std.testing.expect(saw_shape);
    try @import("vm_verify.zig").run(a, &p);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 4), out[0].number);
    try std.testing.expectEqual(@as(f64, 5), out[1].number);
}
