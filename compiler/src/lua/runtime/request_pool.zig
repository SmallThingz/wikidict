const std = @import("std");
const builtin = @import("builtin");

/// Worker-local, single-threaded backing for RequestAllocator. Every request
/// must free all its allocations before resetAndTrim; retained capacity never
/// authorizes a surviving page pointer. Live overflow is not denied by the cap.
pub const RequestPool = struct {
    backing: std.mem.Allocator,
    retained_limit: usize,
    bins: [14]Bin = @splat(.{}),
    mapped_bytes: usize = 0,
    peak_mapped_bytes: usize = 0,
    slab_count: usize = 0,
    epoch: u64 = 1,
    // Compile-time disabled for production hot paths; exercised by tests.
    outstanding: usize = 0,
    direct_outstanding: usize = 0,

    const check = builtin.mode != .fast and builtin.mode != .small;
    const alignment: std.mem.Alignment = .@"16";
    const Slab = struct { next: ?*Slab, prev: ?*Slab, raw_len: usize, last_used: u64 };
    const payload_offset = std.mem.alignForward(usize, @sizeOf(Slab), alignment.toByteUnits());
    const Free = struct { next: ?*Free };
    const Bin = struct {
        slabs: ?*Slab = null,
        tail: ?*Slab = null,
        next_unused: ?*Slab = null,
        free_head: ?*Free = null,
        cursor: ?[*]u8 = null,
        remaining: usize = 0,
        mapped_bytes: usize = 0,
    };

    pub fn init(backing: std.mem.Allocator, retained_limit: usize) RequestPool {
        return .{ .backing = backing, .retained_limit = retained_limit };
    }
    pub fn allocator(self: *RequestPool) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    pub fn deinit(self: *RequestPool) void {
        self.retained_limit = 0;
        self.resetAndTrim();
        self.* = undefined;
    }
    fn dropTail(self: *RequestPool, bin: *Bin) void {
        const slab = bin.tail.?;
        if (slab.prev) |prev| prev.next = null else bin.slabs = null;
        bin.tail = slab.prev;
        self.mapped_bytes -= slab.raw_len;
        bin.mapped_bytes -= slab.raw_len;
        self.slab_count -= 1;
        const bytes: [*]u8 = @ptrCast(slab);
        self.backing.rawFree(bytes[0..slab.raw_len], alignment, @returnAddress());
    }
    pub fn resetAndTrim(self: *RequestPool) void {
        if (check) std.debug.assert(self.outstanding == 0 and self.direct_outstanding == 0);
        for (&self.bins) |*bin| {
            while (bin.mapped_bytes > self.retained_limit / 2) self.dropTail(bin);
        }
        while (self.mapped_bytes > self.retained_limit) {
            var victim: ?*Bin = null;
            for (&self.bins) |*bin| {
                const tail = bin.tail orelse continue;
                if (victim == null or tail.last_used < victim.?.tail.?.last_used or
                    (tail.last_used == victim.?.tail.?.last_used and bin.mapped_bytes > victim.?.mapped_bytes)) victim = bin;
            }
            self.dropTail(victim.?);
        }
        // Epoch exhaustion is harmless: discard cached storage once rather than
        // wrap recency ordering or make an allocation depend on a clock.
        if (self.epoch == std.math.maxInt(u64)) {
            for (&self.bins) |*bin| while (bin.tail != null) self.dropTail(bin);
            self.epoch = 1;
        } else self.epoch += 1;
        for (&self.bins) |*bin| {
            bin.next_unused = bin.slabs;
            bin.free_head = null;
            bin.cursor = null;
            bin.remaining = 0;
        }
    }
    fn fromRaw(raw: *anyopaque) *RequestPool {
        return @ptrCast(@alignCast(raw));
    }
    fn sizeClass(len: usize, align_to: std.mem.Alignment) ?usize {
        if (len > 512 * 1024 or align_to.toByteUnits() > alignment.toByteUnits()) return null;
        const bits: usize = @bitSizeOf(usize) - @clz(@max(len, 64) - 1);
        return bits - 6;
    }
    fn alloc(raw: *anyopaque, len: usize, align_to: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = fromRaw(raw);
        const index = sizeClass(len, align_to) orelse {
            const ptr = self.backing.rawAlloc(len, align_to, ra) orelse return null;
            if (check) self.direct_outstanding += 1;
            return ptr;
        };
        const bin = &self.bins[index];
        if (bin.free_head) |entry| {
            bin.free_head = entry.next;
            if (check) self.outstanding += 1;
            return @ptrCast(entry);
        }
        const slot_len = @as(usize, 64) << @intCast(index);
        if (bin.remaining == 0) {
            const slab = if (bin.next_unused) |old| blk: {
                bin.next_unused = old.next;
                break :blk old;
            } else blk: {
                const payload = @max(64 * 1024, slot_len * 4);
                const raw_len = std.mem.alignForward(usize, payload + payload_offset, std.heap.pageSize());
                const bytes = self.backing.rawAlloc(raw_len, alignment, ra) orelse return null;
                const new: *Slab = @ptrCast(@alignCast(bytes));
                new.* = .{ .next = bin.slabs, .prev = null, .raw_len = raw_len, .last_used = self.epoch };
                if (bin.slabs) |head| head.prev = new else bin.tail = new;
                bin.slabs = new;
                self.slab_count += 1;
                self.mapped_bytes += raw_len;
                self.peak_mapped_bytes = @max(self.peak_mapped_bytes, self.mapped_bytes);
                bin.mapped_bytes += raw_len;
                break :blk new;
            };
            slab.last_used = self.epoch;
            const bytes: [*]u8 = @ptrCast(slab);
            bin.cursor = bytes + payload_offset;
            bin.remaining = (slab.raw_len - payload_offset) / slot_len * slot_len;
        }
        const ptr = bin.cursor.?;
        bin.cursor = ptr + slot_len;
        bin.remaining -= slot_len;
        if (check) self.outstanding += 1;
        return ptr;
    }
    fn resize(raw: *anyopaque, memory: []u8, align_to: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self = fromRaw(raw);
        const old = sizeClass(memory.len, align_to);
        const new = sizeClass(new_len, align_to);
        if (old != null or new != null) return old != null and old == new;
        return self.backing.rawResize(memory, align_to, new_len, ra);
    }
    fn remap(raw: *anyopaque, memory: []u8, align_to: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(raw, memory, align_to, new_len, ra)) memory.ptr else null;
    }
    fn free(raw: *anyopaque, memory: []u8, align_to: std.mem.Alignment, ra: usize) void {
        const self = fromRaw(raw);
        const index = sizeClass(memory.len, align_to) orelse {
            if (check) self.direct_outstanding -= 1;
            return self.backing.rawFree(memory, align_to, ra);
        };
        if (check) self.outstanding -= 1;
        const entry: *Free = @ptrCast(@alignCast(memory.ptr));
        entry.* = .{ .next = self.bins[index].free_head };
        self.bins[index].free_head = entry;
    }
};

test "warm slabs survive page reset without remapping and small frees reuse slots" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var pool = RequestPool.init(backing.allocator(), 8 * 1024 * 1024);
        defer pool.deinit();
        const a = pool.allocator();
        const first = try a.alloc(u8, 64);
        a.free(first);
        const again = try a.alloc(u8, 63);
        try std.testing.expect(first.ptr == again.ptr);
        a.free(again);
        pool.resetAndTrim();
        const allocated = backing.allocated_bytes;
        const later = try a.alloc(u8, 64);
        try std.testing.expect(later.ptr == first.ptr);
        try std.testing.expectEqual(allocated, backing.allocated_bytes);
        a.free(later);
        pool.resetAndTrim();
    }
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "live demand can exceed cap but boundary trimming accounts rounded bytes" {
    var pool = RequestPool.init(std.testing.allocator, 128 * 1024);
    defer pool.deinit();
    const a = pool.allocator();
    var buffers: [8][]u8 = undefined;
    for (&buffers) |*b| b.* = try a.alloc(u8, 256 * 1024 + 100);
    try std.testing.expect(pool.mapped_bytes > pool.retained_limit);
    for (buffers) |b| a.free(b);
    pool.resetAndTrim();
    try std.testing.expect(pool.mapped_bytes <= pool.retained_limit);
    try std.testing.expect(pool.mapped_bytes % std.heap.pageSize() == 0);
}

test "large invoke arena classes are retained and resize never crosses domains" {
    var pool = RequestPool.init(std.testing.allocator, 16 * 1024 * 1024);
    defer pool.deinit();
    const a = pool.allocator();
    var bytes = try a.alloc(u8, 256 * 1024 + 72);
    @memset(bytes, 43);
    try std.testing.expect(a.resize(bytes, 512 * 1024));
    bytes = bytes.ptr[0 .. 512 * 1024];
    try std.testing.expect(!a.resize(bytes, 512 * 1024 + 1));
    try std.testing.expect(!a.resize(bytes, 128));
    bytes = try a.realloc(bytes, 512 * 1024 + 1);
    try std.testing.expectEqual(@as(u8, 43), bytes[200000]);
    try std.testing.expect(!a.resize(bytes, 512 * 1024));
    a.free(bytes);
    const aligned = try a.alignedAlloc(u8, .fromByteUnits(4096), 70);
    try std.testing.expect(@intFromPtr(aligned.ptr) % 4096 == 0);
    a.free(aligned);
    pool.resetAndTrim();
}

test "request cleanup and nested bump arenas precede reset" {
    const RequestAllocator = @import("request_allocator.zig").RequestAllocator;
    const LocalBumpArena = @import("local_bump_arena.zig").LocalBumpArena;
    var pool = RequestPool.init(std.testing.allocator, 16 * 1024 * 1024);
    defer pool.deinit();
    for (0..5) |_| {
        var request = RequestAllocator.init(pool.allocator());
        const a = request.allocator();
        const parent = try a.alloc(u8, 200);
        @memset(parent, 19);
        {
            var inner = LocalBumpArena.init(a);
            defer inner.deinit();
            const child = try inner.allocator().alloc(u8, 100000);
            @memset(child, 42);
            for (parent) |v| try std.testing.expectEqual(@as(u8, 19), v);
        }
        _ = try a.alloc(u8, 2 * 1024 * 1024); // leftover direct allocation
        request.deinit();
        try std.testing.expectEqual(@as(usize, 0), pool.outstanding);
        try std.testing.expectEqual(@as(usize, 0), pool.direct_outstanding);
        pool.resetAndTrim();
    }
}

test "retained multi-slab traversal never aliases live allocations and trims partially" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = RequestPool.init(backing.allocator(), 1024 * 1024);
    defer pool.deinit();
    const a = pool.allocator();
    var buffers: [30][]u8 = undefined;
    for (0..3) |_| {
        for (&buffers, 0..) |*b, i| {
            b.* = try a.alloc(u8, 32768);
            @memset(b.*, @intCast(i));
            for (buffers[0..i], 0..) |prior, n| {
                try std.testing.expect(prior.ptr != b.ptr);
                try std.testing.expectEqual(@as(u8, @intCast(n)), prior[0]);
            }
        }
        for (buffers) |b| a.free(b);
        pool.resetAndTrim();
        try std.testing.expect(pool.slab_count > 0 and pool.slab_count < 15);
        const allocated = backing.allocated_bytes;
        const first = try a.alloc(u8, 32768);
        try std.testing.expectEqual(allocated, backing.allocated_bytes);
        a.free(first);
        pool.resetAndTrim();
    }
}

test "allocation failure preserves retained lists and live canaries" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = RequestPool.init(backing.allocator(), 8 * 1024 * 1024);
    defer pool.deinit();
    const a = pool.allocator();
    const first = try a.alloc(u8, 32768);
    @memset(first, 77);
    const second = try a.alloc(u8, 32768);
    const third = try a.alloc(u8, 32768);
    const fourth = try a.alloc(u8, 32768);
    backing.fail_index = backing.alloc_index;
    const mapped = pool.mapped_bytes;
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 32768));
    try std.testing.expectEqual(mapped, pool.mapped_bytes);
    try std.testing.expectEqual(@as(u8, 77), first[0]);
    a.free(first);
    a.free(second);
    a.free(third);
    a.free(fourth);
    pool.resetAndTrim();
    const reused = try a.alloc(u8, 32768);
    a.free(reused);
    pool.resetAndTrim();
}

test "cold classes yield retained budget to a later request and epochs never wrap" {
    var pool = RequestPool.init(std.testing.allocator, 2 * 1024 * 1024);
    defer pool.deinit();
    const a = pool.allocator();
    var first: [30][]u8 = undefined;
    for (&first) |*b| b.* = try a.alloc(u8, 32768);
    for (first) |b| a.free(b);
    pool.resetAndTrim();
    const oldest = pool.bins[9].mapped_bytes;
    var second: [60][]u8 = undefined;
    for (&second) |*b| b.* = try a.alloc(u8, 16384);
    for (second) |b| a.free(b);
    pool.resetAndTrim();
    var third: [12][]u8 = undefined;
    for (&third) |*b| b.* = try a.alloc(u8, 65536);
    for (third) |b| a.free(b);
    pool.resetAndTrim();
    try std.testing.expect(pool.mapped_bytes <= pool.retained_limit);
    try std.testing.expect(pool.bins[10].mapped_bytes > 0);
    try std.testing.expect(pool.bins[9].mapped_bytes < oldest);
    pool.epoch = std.math.maxInt(u64);
    pool.resetAndTrim();
    try std.testing.expectEqual(@as(usize, 0), pool.mapped_bytes);
    try std.testing.expectEqual(@as(u64, 1), pool.epoch);
}

test "direct allocations realloc into pooling only through copy and free" {
    var pool = RequestPool.init(std.testing.allocator, 8 * 1024 * 1024);
    defer pool.deinit();
    const a = pool.allocator();
    var bytes = try a.alloc(u8, 512 * 1024 + 1);
    @memset(bytes, 62);
    const old_ptr = bytes.ptr;
    bytes = try a.realloc(bytes, 128);
    try std.testing.expect(old_ptr != bytes.ptr);
    for (bytes) |v| try std.testing.expectEqual(@as(u8, 62), v);
    a.free(bytes);
    var aligned = try a.alignedAlloc(u8, .fromByteUnits(4096), 200);
    @memset(aligned, 71);
    aligned = try a.realloc(aligned, 400);
    try std.testing.expect(@intFromPtr(aligned.ptr) % 4096 == 0);
    for (aligned[0..200]) |v| try std.testing.expectEqual(@as(u8, 71), v);
    a.free(aligned);
    pool.resetAndTrim();
}
