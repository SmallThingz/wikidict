const std = @import("std");

/// Page/request allocator that honors ordinary frees while retaining arena-like
/// bulk cleanup for Lua objects whose ownership is intentionally page-scoped.
pub const RequestAllocator = struct {
    backing: std.mem.Allocator,
    live: std.AutoHashMapUnmanaged(usize, Allocation) = .empty,

    const Allocation = struct {
        len: usize,
        alignment: std.mem.Alignment,
    };

    pub fn init(backing: std.mem.Allocator) RequestAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *RequestAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn deinit(self: *RequestAllocator) void {
        var it = self.live.iterator();
        while (it.next()) |entry| {
            const allocation = entry.value_ptr.*;
            const ptr: [*]u8 = @ptrFromInt(entry.key_ptr.*);
            self.backing.rawFree(ptr[0..allocation.len], allocation.alignment, @returnAddress());
        }
        self.live.deinit(self.backing);
        self.* = undefined;
    }

    fn selfFrom(raw: *anyopaque) *RequestAllocator {
        return @ptrCast(@alignCast(raw));
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = selfFrom(raw);
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live.put(self.backing, @intFromPtr(ptr), .{
            .len = len,
            .alignment = alignment,
        }) catch {
            self.backing.rawFree(ptr[0..len], alignment, ret_addr);
            return null;
        };
        return ptr;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = selfFrom(raw);
        const allocation = self.live.getPtr(@intFromPtr(memory.ptr)) orelse @panic("request allocator resize of unknown allocation");
        std.debug.assert(allocation.len == memory.len and allocation.alignment == alignment);
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        allocation.len = new_len;
        return true;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Returning null makes Allocator.realloc use alloc-copy-free, which keeps
        // tracking atomic even when the backing allocator could relocate.
        return null;
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = selfFrom(raw);
        const removed = self.live.fetchRemove(@intFromPtr(memory.ptr)) orelse @panic("request allocator free of unknown allocation");
        std.debug.assert(removed.value.len == memory.len and removed.value.alignment == alignment);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "request allocator honors frees and bulk-reclaims leftovers" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    const first = try a.alloc(u8, 4096);
    try std.testing.expectEqual(@as(usize, 1), request.live.count());
    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), request.live.count());

    _ = try a.alloc(u64, 128);
    _ = try a.alloc(u8, 8192);
    try std.testing.expectEqual(@as(usize, 2), request.live.count());
}

test "request allocator survives repeated allocation churn" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    for (0..4096) |_| {
        const bytes = try a.alloc(u8, 16 * 1024);
        a.free(bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), request.live.count());
}

test "request allocator keeps realloc tracking exact" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    var bytes = try a.alloc(u8, 128);
    @memset(bytes, 0x5a);
    bytes = try a.realloc(bytes, 4096);
    try std.testing.expectEqual(@as(usize, 1), request.live.count());
    try std.testing.expectEqual(@as(u8, 0x5a), bytes[127]);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), request.live.count());
}
