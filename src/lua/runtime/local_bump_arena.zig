const std = @import("std");

/// Private, single-thread arena for one native #invoke lifetime. The caller
/// destroys it before the containing page/request allocator. This allocator
/// intentionally does not return individual slices to its backing allocator.
pub const LocalBumpArena = struct {
    backing: std.mem.Allocator,
    head: ?*Block = null,
    next_capacity: usize = initial_capacity,

    const initial_capacity: usize = 16 * 1024;
    const max_growing_capacity: usize = 256 * 1024;
    const Block = struct {
        next: ?*Block,
        raw_len: usize,
        used: usize,
    };

    pub fn init(backing: std.mem.Allocator) LocalBumpArena {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *LocalBumpArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    pub fn deinit(self: *LocalBumpArena) void {
        var cursor = self.head;
        while (cursor) |block| {
            const next = block.next;
            const bytes: [*]u8 = @ptrCast(block);
            self.backing.rawFree(bytes[0..block.raw_len], .of(Block), @returnAddress());
            cursor = next;
        }
        self.* = undefined;
    }

    fn fromRaw(raw: *anyopaque) *LocalBumpArena {
        return @ptrCast(@alignCast(raw));
    }

    fn tryBlock(block: *Block, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const base = @intFromPtr(block) + @sizeOf(Block);
        const cursor = std.math.add(usize, base, block.used) catch return null;
        const align_bytes = alignment.toByteUnits();
        const padded = std.math.add(usize, cursor, align_bytes - 1) catch return null;
        const aligned = padded & ~(align_bytes - 1);
        const end = std.math.add(usize, aligned - base, @max(len, 1)) catch return null;
        if (end > block.raw_len - @sizeOf(Block)) return null;
        block.used = end;
        return @ptrFromInt(aligned);
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = fromRaw(raw);
        if (self.head) |head| if (tryBlock(head, len, alignment)) |ptr| return ptr;
        const payload = std.math.add(usize, @max(len, 1), alignment.toByteUnits()) catch return null;
        const capacity = @max(payload, self.next_capacity);
        const raw_len = std.math.add(usize, @sizeOf(Block), capacity) catch return null;
        const bytes = self.backing.rawAlloc(raw_len, .of(Block), ret_addr) orelse return null;
        const block: *Block = @ptrCast(@alignCast(bytes));
        block.* = .{ .next = self.head, .raw_len = raw_len, .used = 0 };
        self.head = block;
        self.next_capacity = @min(max_growing_capacity, self.next_capacity * 2);
        return tryBlock(block, len, alignment) orelse unreachable;
    }

    fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        // Shrinking keeps the same pointer; growth uses allocate-and-copy.
        // Old arena slices may still be referenced until invocation exit.
        return new_len <= memory.len;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
};

test "local bump arena honors alignment and bulk cleanup" {
    var arena = LocalBumpArena.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const small = try a.alloc(u8, 7);
    const aligned = try a.alignedAlloc(u8, .of(u128), 19);
    const large = try a.alloc(u8, 500_000);
    try std.testing.expect(@intFromPtr(aligned.ptr) % @alignOf(u128) == 0);
    @memset(small, 0x37);
    @memset(aligned, 0x53);
    @memset(large, 0x67);
    try std.testing.expectEqual(@as(u8, 0x37), small[0]);
    try std.testing.expectEqual(@as(u8, 0x53), aligned[0]);
    const larger = try a.realloc(small, 70);
    try std.testing.expectEqual(@as(u8, 0x37), larger[0]);
    const smaller = try a.realloc(larger, 3);
    try std.testing.expectEqual(@as(u8, 0x37), smaller[0]);
    a.free(smaller);
}

test "local bump arena rejects impossible alignment without changing a live block" {
    var backing_bytes: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing_bytes);
    var arena = LocalBumpArena.init(fixed.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    _ = a.rawAlloc(1, .of(u8), @returnAddress()) orelse return error.TestUnexpectedResult;
    const head = arena.head.?;
    const used = head.used;
    try std.testing.expect(a.rawAlloc(1, @fromBackingInt(@intCast(@bitSizeOf(usize) - 1)), @returnAddress()) == null);
    try std.testing.expect(arena.head.? == head);
    try std.testing.expectEqual(used, head.used);
    // A failed extreme request must not poison an ordinary aligned allocation.
    const high = a.rawAlloc(8, @fromBackingInt(@intCast(12)), @returnAddress()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(@intFromPtr(high) % 4096 == 0);
}

test "local bump OOM and remap preserve existing allocations" {
    var bytes: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    var arena = LocalBumpArena.init(fixed.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const live = try a.alloc(u8, 64);
    @memset(live, 0x5a);
    const head = arena.head.?;
    const used = head.used;
    const capacity = arena.next_capacity;
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 64 * 1024));
    try std.testing.expect(a.rawAlloc(std.math.maxInt(usize), .of(u8), @returnAddress()) == null);
    try std.testing.expect(arena.head.? == head);
    try std.testing.expectEqual(used, head.used);
    try std.testing.expectEqual(capacity, arena.next_capacity);
    try std.testing.expect(!a.rawResize(live, .of(u8), 128, @returnAddress()));
    try std.testing.expect(a.rawRemap(live, .of(u8), 128, @returnAddress()) == null);
    try std.testing.expect(a.rawResize(live, .of(u8), 16, @returnAddress()));
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0x5a))), live[0..16]);
    const next = try a.alloc(u64, 8);
    @memset(next, 17);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0x5a))), live[0..16]);
}

test "local bump nested invocations preserve parent data and release all backing blocks" {
    const RequestAllocator = @import("request_allocator.zig").RequestAllocator;
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    for (0..32) |_| {
        {
            var parent = LocalBumpArena.init(request.allocator());
            defer parent.deinit();
            const live = try parent.allocator().alloc(u8, 80_000);
            @memset(live, 0x39);
            const parent_blocks = request.live_count;
            {
                var child = LocalBumpArena.init(request.allocator());
                defer child.deinit();
                const temporary = try child.allocator().alloc(u8, 600_000);
                @memset(temporary, 0xa7);
                try std.testing.expect(request.live_count > parent_blocks);
            }
            try std.testing.expectEqual(parent_blocks, request.live_count);
            for (live) |byte| try std.testing.expectEqual(@as(u8, 0x39), byte);
        }
        try std.testing.expectEqual(@as(usize, 0), request.live_count);
    }
}
