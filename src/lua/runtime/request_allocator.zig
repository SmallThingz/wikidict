const std = @import("std");

/// Page/request allocator that honors ordinary frees while retaining arena-like
/// bulk cleanup for Lua objects whose ownership is intentionally page-scoped.
///
/// Tracking is intrusive: every backing allocation starts with a Header, and a
/// pointer to that header is stored immediately before the aligned user slice.
/// This keeps alloc/free/resize O(1) without a hash-table operation per Lua
/// allocation.
pub const RequestAllocator = struct {
    backing: std.mem.Allocator,
    head: ?*Header = null,
    live_count: usize = 0,

    const Header = struct {
        prev: ?*Header = null,
        next: ?*Header = null,
        raw_len: usize,
        user_len: usize,
        user_alignment: std.mem.Alignment,
    };

    const backref_len = @sizeOf(usize);

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
        var current = self.head;
        while (current) |header| {
            const next = header.next;
            const raw_ptr: [*]u8 = @ptrCast(header);
            self.backing.rawFree(
                raw_ptr[0..header.raw_len],
                rawAlignment(header.user_alignment),
                @returnAddress(),
            );
            current = next;
        }
        self.* = undefined;
    }

    fn selfFrom(raw: *anyopaque) *RequestAllocator {
        return @ptrCast(@alignCast(raw));
    }

    fn rawAlignment(user_alignment: std.mem.Alignment) std.mem.Alignment {
        return if (user_alignment.toByteUnits() > @alignOf(Header))
            user_alignment
        else
            .of(Header);
    }

    fn userOffset(user_alignment: std.mem.Alignment) ?usize {
        const prefix = std.math.add(usize, @sizeOf(Header), backref_len) catch return null;
        const alignment = user_alignment.toByteUnits();
        _ = std.math.add(usize, prefix, alignment - 1) catch return null;
        return std.mem.alignForward(usize, prefix, alignment);
    }

    fn writeHeaderBackref(user_ptr: [*]u8, header: *Header) void {
        const slot_addr = @intFromPtr(user_ptr) - backref_len;
        const slot: *align(1) [backref_len]u8 = @ptrFromInt(slot_addr);
        std.mem.writeInt(usize, slot, @intFromPtr(header), .native);
    }

    fn headerFor(memory: []u8) *Header {
        const user_addr = @intFromPtr(memory.ptr);
        if (user_addr < backref_len) @panic("request allocator invalid allocation pointer");
        const slot: *align(1) const [backref_len]u8 = @ptrFromInt(user_addr - backref_len);
        const header_addr = std.mem.readInt(usize, slot, .native);
        if (header_addr == 0) @panic("request allocator invalid allocation header");
        return @ptrFromInt(header_addr);
    }

    fn link(self: *RequestAllocator, header: *Header) void {
        header.prev = null;
        header.next = self.head;
        if (self.head) |old| old.prev = header;
        self.head = header;
        self.live_count += 1;
    }

    fn unlink(self: *RequestAllocator, header: *Header) void {
        if (header.prev) |prev| {
            prev.next = header.next;
        } else {
            std.debug.assert(self.head == header);
            self.head = header.next;
        }
        if (header.next) |next| next.prev = header.prev;
        std.debug.assert(self.live_count != 0);
        self.live_count -= 1;
    }

    fn validate(header: *const Header, memory: []u8, alignment: std.mem.Alignment) void {
        std.debug.assert(header.user_len == memory.len);
        std.debug.assert(header.user_alignment == alignment);
        const offset = @intFromPtr(memory.ptr) - @intFromPtr(header);
        std.debug.assert(offset >= @sizeOf(Header) + backref_len);
        std.debug.assert(header.raw_len == offset + memory.len);
        std.debug.assert(@intFromPtr(memory.ptr) % alignment.toByteUnits() == 0);
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = selfFrom(raw);
        const user_offset = userOffset(alignment) orelse return null;
        const raw_len = std.math.add(usize, user_offset, len) catch return null;
        const raw_alignment = rawAlignment(alignment);
        const raw_ptr = self.backing.rawAlloc(raw_len, raw_alignment, ret_addr) orelse return null;
        const header: *Header = @ptrCast(@alignCast(raw_ptr));
        header.* = .{
            .raw_len = raw_len,
            .user_len = len,
            .user_alignment = alignment,
        };
        const user_ptr = raw_ptr + user_offset;
        std.debug.assert(@intFromPtr(user_ptr) % alignment.toByteUnits() == 0);
        writeHeaderBackref(user_ptr, header);
        self.link(header);
        return user_ptr;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = selfFrom(raw);
        const header = headerFor(memory);
        validate(header, memory, alignment);
        const user_offset = @intFromPtr(memory.ptr) - @intFromPtr(header);
        const new_raw_len = std.math.add(usize, user_offset, new_len) catch return false;
        const raw_ptr: [*]u8 = @ptrCast(header);
        if (!self.backing.rawResize(
            raw_ptr[0..header.raw_len],
            rawAlignment(alignment),
            new_raw_len,
            ret_addr,
        )) return false;
        header.raw_len = new_raw_len;
        header.user_len = new_len;
        return true;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Returning null makes Allocator.realloc use alloc-copy-free. The
        // intrusive header therefore never has to survive a moving remap.
        return null;
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = selfFrom(raw);
        const header = headerFor(memory);
        validate(header, memory, alignment);
        self.unlink(header);
        const raw_ptr: [*]u8 = @ptrCast(header);
        self.backing.rawFree(
            raw_ptr[0..header.raw_len],
            rawAlignment(alignment),
            ret_addr,
        );
    }
};

test "request allocator honors frees and bulk-reclaims leftovers" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    const first = try a.alloc(u8, 4096);
    try std.testing.expectEqual(@as(usize, 1), request.live_count);
    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), request.live_count);

    _ = try a.alloc(u64, 128);
    _ = try a.alloc(u8, 8192);
    try std.testing.expectEqual(@as(usize, 2), request.live_count);
}

test "request allocator survives repeated allocation churn" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    for (0..4096) |_| {
        const bytes = try a.alloc(u8, 16 * 1024);
        a.free(bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), request.live_count);
}

test "request allocator keeps realloc tracking exact" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    var bytes = try a.realloc(try a.dupe(u8, &([_]u8{0x5a} ** 128)), 4096);
    try std.testing.expectEqual(@as(usize, 1), request.live_count);
    try std.testing.expectEqual(@as(u8, 0x5a), bytes[127]);
    bytes = try a.realloc(bytes, 64);
    try std.testing.expectEqual(@as(usize, 1), request.live_count);
    try std.testing.expectEqual(@as(u8, 0x5a), bytes[63]);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), request.live_count);
}

test "request allocator preserves over-aligned allocations" {
    var request = RequestAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();

    var bytes = try a.alignedAlloc(u8, .@"64", 37);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % 64);
    @memset(bytes, 0xa5);
    bytes = try a.realloc(bytes, 4096);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % 64);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes[36]);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), request.live_count);
}
