const std = @import("std");
const ir = @import("vm_ir.zig");
const data = @import("vm_data.zig");
const Key = data.TableKey;
const Context = data.TableContext;
pub const Stats = struct { before: u64 = 0, after: u64 = 0, shared_ranges: u64 = 0 };
fn equal(a: []const ir.ConstEntry, b: []const ir.ConstEntry) bool {
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}
// Immutable entry sequences may overlap. Every runtime materialization remains fresh.
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{ .before = p.const_entries.items.len };
    var entries: std.ArrayList(ir.ConstEntry) = .empty;
    errdefer entries.deinit(a);
    try entries.ensureTotalCapacity(a, p.const_entries.items.len);
    const firsts = try a.alloc(u32, p.constants.items.len);
    defer a.free(firsts);
    var slices: std.HashMapUnmanaged(Key, u32, Context, 80) = .empty;
    defer slices.deinit(a);
    const context = Context{ .entries = &entries };
    for (p.constants.items, 0..) |node, id| if (node == .table) {
        const t = node.table;
        if (@as(u64, t.first) + t.count > p.const_entries.items.len) return error.BadTableEntries;
        const rows = p.const_entries.items[t.first..][0..t.count];
        const mark = entries.items.len;
        var overlap = @min(@min(mark, rows.len), 8);
        while (overlap != 0 and !equal(entries.items[mark - overlap ..], rows[0..overlap])) overlap -= 1;
        var first: u32 = @intCast(mark - overlap);
        try entries.appendSlice(a, rows[overlap..]);
        const key = Key{ .first = first, .count = t.count, .shape = 0 };
        if (slices.getContext(key, context)) |existing| {
            first = existing;
            entries.shrinkRetainingCapacity(mark);
            stats.shared_ranges += 1;
        }
        firsts[id] = first;
        try indexSlice(a, &slices, context, .{ .first = first, .count = t.count, .shape = 0 });
        for (1..@min(t.count, 8) + 1) |length| {
            const n: u32 = @intCast(length);
            try indexSlice(a, &slices, context, .{ .first = first, .count = n, .shape = 0 });
            try indexSlice(a, &slices, context, .{ .first = first + t.count - n, .count = n, .shape = 0 });
        }
    };
    // Compare all logical records exactly before replacing the old backing store.
    for (p.constants.items, 0..) |node, id| if (node == .table) {
        const table = node.table;
        if (!equal(p.const_entries.items[table.first..][0..table.count], entries.items[firsts[id]..][0..table.count]))
            return error.EntryPoolChangedValues;
    };
    for (p.constants.items, 0..) |*node, id| if (node.* == .table) {
        node.table.first = firsts[id];
    };
    p.const_entries.deinit(a);
    p.const_entries = entries;
    stats.after = entries.items.len;
    return stats;
}
fn indexSlice(a: std.mem.Allocator, map: *std.HashMapUnmanaged(Key, u32, Context, 80), ctx: Context, key: Key) !void {
    const result = try map.getOrPutContext(a, key, ctx);
    if (!result.found_existing) result.value_ptr.* = key.first;
}

test "entry subsequences share storage but not mutable table identity" {
    const lua = @import("root.zig");
    const exec = @import("vm_exec.zig");
    var chunk = try lua.parse(std.testing.allocator, "local a={x=1,y=2,z=3}; local b={x=1,y=2}; a.x=9; return a.x,b.x,b.y,a==b");
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    _ = try data.run(std.testing.allocator, &program);
    const stats = try run(std.testing.allocator, &program);
    try std.testing.expect(stats.after < stats.before);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(f64, 9), values[0].number);
    try std.testing.expectEqual(@as(f64, 1), values[1].number);
    try std.testing.expectEqual(@as(f64, 2), values[2].number);
    try std.testing.expect(!values[3].boolean);
}
