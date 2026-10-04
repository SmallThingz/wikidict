const std = @import("std");

/// Bounds live raw allocation requests, including arena chunk headers and
/// slack. This is a single-threaded admission budget, not an RSS measurement.
/// Keep it at a stable address while any allocator handle points to it.
pub const AllocationBudget = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *AllocationBudget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn fromRaw(raw: *anyopaque) *AllocationBudget {
        return @ptrCast(@alignCast(raw));
    }

    fn record(self: *AllocationBudget, old: usize, new: usize) void {
        std.debug.assert(old <= self.used);
        self.used = self.used - old + new;
        self.peak = @max(self.peak, self.used);
        std.debug.assert(self.used <= self.limit);
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = fromRaw(raw);
        if (len > self.limit - self.used) return null;
        const ptr = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.record(0, len);
        return ptr;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new: usize, ra: usize) bool {
        const self = fromRaw(raw);
        if (new -| memory.len > self.limit - self.used) return false;
        if (!self.backing.rawResize(memory, alignment, new, ra)) return false;
        self.record(memory.len, new);
        return true;
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
        const self = fromRaw(raw);
        if (new -| memory.len > self.limit - self.used) return null;
        const ptr = self.backing.rawRemap(memory, alignment, new, ra) orelse return null;
        self.record(memory.len, new);
        return ptr;
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = fromRaw(raw);
        self.backing.rawFree(memory, alignment, ra);
        self.record(memory.len, 0);
    }
};

test "allocation budget rejects growth and permits reuse after free" {
    var budget = AllocationBudget{ .backing = std.testing.allocator, .limit = 64 };
    const a = budget.allocator();
    const first = try a.alloc(u8, 48);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 17));
    try std.testing.expect(!a.resize(first, 65));
    try std.testing.expect(a.remap(first, 65) == null);
    const second = try a.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 64), budget.peak);
    a.free(second);
    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "committed arena can detach its temporary budget" {
    var budget = AllocationBudget{ .backing = std.testing.allocator, .limit = 4096 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    const data = try arena.allocator().dupe(u8, "retained");
    try std.testing.expect(budget.used > data.len);
    arena.child_allocator = budget.backing;
    try std.testing.expectEqualStrings("retained", data);
}
