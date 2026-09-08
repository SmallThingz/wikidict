const std = @import("std");
const ir = @import("vm_ir.zig");
const shape_key = @import("vm_shape_key.zig");

pub const Stats = struct { scalar_nodes_removed: usize = 0, string_index_bytes_saved: u64 = 0 };
const Scalar = struct { kind: u8, value: u64 };
fn scalar(node: ir.ConstNode) ?Scalar {
    return switch (node) {
        .nil => .{ .kind = 0, .value = 0 },
        .boolean => |v| .{ .kind = 1, .value = @intFromBool(v) },
        .number => |v| .{ .kind = 2, .value = v },
        .number_bits => |v| .{ .kind = 3, .value = v },
        .string => |v| .{ .kind = 4, .value = v },
        .integer => |v| .{ .kind = 5, .value = v },
        .table => null,
    };
}
// Exhaustive: a new opcode cannot silently omit relocation of its string IDs.
fn hasAuxStringOperand(op: ir.Opcode) bool {
    return switch (op) {
        .load_number, .load_string, .get_global, .set_global, .get_field, .set_field => true,
        else => false,
    };
}
fn hasAStringOperand(op: ir.Opcode) bool {
    return op == .method_call_field or op == .method_call_field_vararg;
}
fn compactScalars(p: *ir.Program) !usize {
    const a = p.allocator;
    const remap = try a.alloc(u32, p.constants.items.len);
    defer a.free(remap);
    var known: std.AutoHashMapUnmanaged(Scalar, u32) = .empty;
    defer known.deinit(a);
    var nodes: std.ArrayList(ir.ConstNode) = .empty;
    errdefer nodes.deinit(a);
    for (p.constants.items, 0..) |node, old| {
        if (scalar(node)) |key| {
            const entry = try known.getOrPut(a, key);
            if (entry.found_existing) {
                remap[old] = entry.value_ptr.*;
                continue;
            }
            entry.value_ptr.* = @intCast(nodes.items.len);
        }
        remap[old] = @intCast(nodes.items.len);
        try nodes.append(a, node);
    }
    for (p.const_entries.items) |entry| {
        if (entry.key != ir.implicit_list_key and entry.key >= remap.len) return error.BadConstantReference;
        if (entry.value >= remap.len) return error.BadConstantReference;
    }
    for (p.functions.items) |maybe| if (maybe) |f| for (f.insts.items) |inst|
        if (inst.op == .load_const and inst.aux >= remap.len) return error.BadConstantReference;
    for (p.const_entries.items) |*entry| {
        if (entry.key != ir.implicit_list_key) entry.key = remap[entry.key];
        entry.value = remap[entry.value];
    }
    for (p.functions.items) |*maybe| if (maybe.*) |*f| for (f.insts.items) |*inst|
        if (inst.op == .load_const) {
            inst.aux = remap[inst.aux];
        };
    const removed = p.constants.items.len - nodes.items.len;
    p.constants.deinit(a);
    p.constants = nodes;
    return removed;
}
fn width(id: usize) u64 {
    var value = id;
    var n: u64 = 1;
    while (value >= 128) : (value >>= 7) n += 1;
    return n;
}
fn note(uses: []u64, id: u32) !void {
    if (id >= uses.len) return error.BadStringReference;
    uses[id] += 1;
}
fn orderStrings(p: *ir.Program) !u64 {
    const n = p.strings.items.len;
    if (n <= 128) return 0;
    const a = p.allocator;
    const uses = try a.alloc(u64, n);
    defer a.free(uses);
    @memset(uses, 0);
    const ids = try a.alloc(u32, n);
    defer a.free(ids);
    const remap = try a.alloc(u32, n);
    defer a.free(remap);
    for (ids, 0..) |*id, i| id.* = @intCast(i);
    for (p.constants.items) |node| switch (node) {
        .number, .string => |sid| try note(uses, sid),
        else => {},
    };
    for (p.functions.items) |maybe| if (maybe) |f| for (f.insts.items) |inst|
        if (hasAuxStringOperand(inst.op)) try note(uses, inst.aux) else if (hasAStringOperand(inst.op)) try note(uses, inst.a);
    for (p.shapes.items) |shape| for (shape.field_keys.items) |key| if (shape_key.stringId(key)) |sid| try note(uses, sid);
    std.mem.sort(u32, ids, uses, struct {
        fn less(counts: []const u64, x: u32, y: u32) bool {
            return counts[x] > counts[y] or (counts[x] == counts[y] and x < y);
        }
    }.less);
    var before: u64 = 0;
    var after: u64 = 0;
    for (ids, 0..) |old, new| {
        remap[old] = @intCast(new);
        before += uses[old] * width(old);
        after += uses[old] * width(new);
    }
    if (after >= before) return 0;
    var strings: std.ArrayList([]const u8) = .empty;
    errdefer strings.deinit(a);
    var interned: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer interned.deinit(a);
    try strings.ensureTotalCapacity(a, n);
    for (ids, 0..) |old, new| {
        const text = p.strings.items[old];
        strings.appendAssumeCapacity(text);
        try interned.put(a, text, @intCast(new));
    }
    for (p.constants.items) |*node| switch (node.*) {
        .number => |sid| node.* = .{ .number = remap[sid] },
        .string => |sid| node.* = .{ .string = remap[sid] },
        else => {},
    };
    for (p.functions.items) |*maybe| if (maybe.*) |*f| for (f.insts.items) |*inst| {
        if (hasAuxStringOperand(inst.op)) inst.aux = remap[inst.aux] else if (hasAStringOperand(inst.op)) inst.a = remap[inst.a];
    };
    for (p.shapes.items) |*shape| {
        for (shape.field_keys.items) |*key| {
            if (shape_key.stringId(key.*)) |sid| key.* = try shape_key.string(remap[sid]);
        }
    }
    p.strings.deinit(a);
    p.strings = strings;
    p.interned_strings.deinit(a);
    p.interned_strings = interned;
    return before - after;
}
pub fn run(p: *ir.Program) !Stats {
    return .{ .scalar_nodes_removed = try compactScalars(p), .string_index_bytes_saved = try orderStrings(p) };
}

const lua = @import("root.zig");
const codec = @import("vm_codec.zig");
const exec = @import("vm_exec.zig");
fn checkSource(source: []const u8) !Stats {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    const original = try codec.serialize(a, &p);
    defer a.free(original);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const expected = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(expected);
    const stats = try run(&p);
    const bytes = try codec.serialize(a, &p);
    defer a.free(bytes);
    try std.testing.expect(bytes.len <= original.len);
    var decoded = try codec.deserializeBorrowed(a, bytes);
    defer decoded.deinit();
    const actual = try vm.executeRoot(&decoded, &.{});
    defer exec.Vm.freeResults(actual);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |x, y| try std.testing.expect(@import("vm_runtime.zig").rawEqual(x, y));
    const second = try run(&p);
    try std.testing.expectEqualDeep(Stats{}, second);
    const again = try codec.serialize(a, &p);
    defer a.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    return stats;
}
test "scalar pooling preserves mutable table identity and content" {
    const stats = try checkSource("local t={{a=1,b=2},{a=1,b=2}};t[1].a=7;return t[1].a,t[2].a,t[1]==t[2],t[1].b,t[2].b");
    try std.testing.expect(stats.scalar_nodes_removed > 0);
}
test "frequent strings get short IDs without changing their values" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "local t={");
    for (0..140) |i| try source.print(a, "'cold-{d}',", .{i});
    try source.appendSlice(a, "};return t[1],t[140]");
    for (0..100) |_| try source.appendSlice(a, ",'hot'");
    const stats = try checkSource(source.items);
    try std.testing.expect(stats.string_index_bytes_saved > 80);
}
test "scalar pooling keeps Lua literal number spellings" {
    _ = try checkSource("local t={-0,-0,1,1.0,0x1,1e0};return 1/t[1],1/t[2],t[3],t[4],t[5],t[6]");
}
test "empty pools and malformed scalar references are handled" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    try std.testing.expectEqualDeep(Stats{}, try run(&p));
    try p.const_entries.append(a, .{ .key = 0, .value = 0 });
    try std.testing.expectError(error.BadConstantReference, run(&p));
}
