const std = @import("std");
const classes = @import("unicode_classes.zig");

// Program-owned immutable metadata. Entries never move or evict; all searches
// and page arenas must be gone before their owning Program destroys the cache.
pub const PatternCache = struct {
    pub const max_entries = 128;
    pub const max_bytes = 8 * 1024 * 1024;
    pub const min_pattern_bytes = 128;
    pub const max_pattern_bytes = 16 * 1024;
    const bucket_count = 256;

    pub const Entry = struct {
        hash: u64,
        bytes: []const u8,
        codepoints: []const u21,
        prepared: classes.Prepared,
        requested_bytes: usize,

        fn deinit(self: *Entry, a: std.mem.Allocator) void {
            self.prepared.deinit(a);
            a.free(self.codepoints);
            a.free(self.bytes);
            a.destroy(self);
        }
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    buckets: [bucket_count]?*Entry = @splat(null),
    entry_count: usize = 0,
    requested_bytes: usize,
    byte_limit: usize = max_bytes,
    entry_limit: usize = max_entries,
    hits: u64 = 0,
    misses: u64 = 0,
    capacity_bypasses: u64 = 0,
    allocation_bypasses: u64 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) PatternCache {
        return .{ .io = io, .allocator = allocator, .requested_bytes = @sizeOf(PatternCache) };
    }

    pub fn create(io: std.Io, allocator: std.mem.Allocator) !*PatternCache {
        const cache = try allocator.create(PatternCache);
        cache.* = init(io, allocator);
        return cache;
    }

    pub fn destroy(self: *PatternCache) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *PatternCache) void {
        // Owner teardown cannot race its descendants or borrowed searches.
        for (self.buckets) |entry| if (entry) |e| e.deinit(self.allocator);
        self.* = undefined;
    }

    fn eligible(len: usize) bool {
        return len >= min_pattern_bytes and len <= max_pattern_bytes;
    }

    fn slot(self: *const PatternCache, bytes: []const u8, hash: u64) usize {
        var index: usize = @intCast(hash & (bucket_count - 1));
        var probes: usize = 0;
        while (probes < bucket_count) : (probes += 1) {
            const entry = self.buckets[index] orelse return index;
            if (entry.hash == hash and std.mem.eql(u8, entry.bytes, bytes)) return index;
            index = (index + 1) & (bucket_count - 1);
        }
        unreachable; // Admission stays at or below half-full.
    }

    pub fn lookup(self: *PatternCache, bytes: []const u8) ?*const Entry {
        if (!eligible(bytes.len)) return null;
        const hash = std.hash.Wyhash.hash(0, bytes);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.buckets[self.slot(bytes, hash)]) |entry| {
            self.hits += 1;
            return entry;
        }
        self.misses += 1;
        return null;
    }

    fn makeEntry(self: *PatternCache, bytes: []const u8, cps: []const u21, hash: u64, size: usize) !*Entry {
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        const owned_cps = try self.allocator.dupe(u21, cps);
        errdefer self.allocator.free(owned_cps);
        const prepared = try classes.Prepared.init(self.allocator, owned_cps);
        errdefer prepared.deinit(self.allocator);
        const entry = try self.allocator.create(Entry);
        entry.* = .{ .hash = hash, .bytes = owned_bytes, .codepoints = owned_cps, .prepared = prepared, .requested_bytes = size };
        return entry;
    }

    pub fn admit(self: *PatternCache, cps: []const u21) ?*const Entry {
        if (cps.len > max_pattern_bytes) return null;
        // Search snapshots decoded codepoints, but need not retain the caller's
        // original UTF-8 buffer. Re-encode only on first admission so a mutated
        // or freed original pattern can never poison another search's key.
        var scratch: [max_pattern_bytes]u8 = undefined;
        var len: usize = 0;
        for (cps) |cp| {
            const count = std.unicode.utf8CodepointSequenceLength(cp) catch return null;
            if (count > scratch.len - len) return null;
            len += std.unicode.utf8Encode(cp, scratch[len..]) catch return null;
        }
        const bytes = scratch[0..len];
        if (!eligible(bytes.len)) return null;
        const hash = std.hash.Wyhash.hash(0, bytes);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.slot(bytes, hash);
        if (self.buckets[index]) |entry| return entry;
        const size = @sizeOf(Entry) + bytes.len + cps.len * @sizeOf(u21) + classes.Prepared.allocationBytes(cps);
        if (self.entry_count >= @min(self.entry_limit, max_entries) or
            size > self.byte_limit -| self.requested_bytes)
        {
            self.capacity_bypasses += 1;
            return null;
        }
        const entry = self.makeEntry(bytes, cps, hash, size) catch {
            self.allocation_bypasses += 1;
            return null;
        };
        self.buckets[index] = entry;
        self.entry_count += 1;
        self.requested_bytes += size;
        return entry;
    }

    pub fn logDiagnostics(self: *PatternCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.print("unicode pattern cache: entries={d} requested_bytes={d} hits={d} misses={d} capacity_bypasses={d} allocation_bypasses={d}\n", .{ self.entry_count, self.requested_bytes, self.hits, self.misses, self.capacity_bypasses, self.allocation_bypasses });
    }
};

test "pattern cache owns keys and codepoints and reuses equal content" {
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    var pattern: [130]u21 = @splat('q');
    pattern[0] = '[';
    pattern[129] = ']';
    const first = cache.admit(&pattern).?;
    @memset(&pattern, 'x');
    const key = "[" ++ @as([128]u8, @splat('q')) ++ "]";
    var copied: [key.len]u8 = undefined;
    @memcpy(&copied, key);
    try std.testing.expect(cache.lookup(&copied).? == first);
    try std.testing.expectEqual(@as(u21, '['), first.codepoints[0]);
    try std.testing.expect(first.prepared.classes[0].matches('q'));
    try std.testing.expect(!first.prepared.classes[0].matches('x'));
    try std.testing.expectEqual(@as(usize, 1), cache.entry_count);
}

test "pattern cache accounts unmerged storage and respects exact byte budget" {
    var pattern: [130]u21 = @splat('q');
    pattern[0] = '[';
    pattern[129] = ']';
    const expected = @sizeOf(PatternCache.Entry) + 130 + 130 * @sizeOf(u21) + classes.Prepared.allocationBytes(&pattern);
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    cache.byte_limit = @sizeOf(PatternCache) + expected - 1;
    try std.testing.expect(cache.admit(&pattern) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.entry_count);
    cache.byte_limit += 1;
    const entry = cache.admit(&pattern).?;
    try std.testing.expectEqual(expected, entry.requested_bytes);
    try std.testing.expectEqual(cache.byte_limit, cache.requested_bytes);
    try std.testing.expect(entry.prepared.storage.len > entry.prepared.classes[0].ranges.len);
    try std.testing.expect(cache.lookup("[" ++ @as([128]u8, @splat('q')) ++ "]").? == entry);
    pattern[1] = 'a';
    try std.testing.expect(cache.admit(&pattern) == null);
}

test "full pattern cache still serves old entries" {
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    var pattern: [130]u21 = @splat('q');
    pattern[0] = '[';
    pattern[129] = ']';
    var first: ?*const PatternCache.Entry = null;
    for (0..PatternCache.max_entries) |i| {
        pattern[1] = @intCast(0x100 + i);
        const entry = cache.admit(&pattern).?;
        if (i == 0) first = entry;
    }
    try std.testing.expectEqual(@as(usize, PatternCache.max_entries), cache.entry_count);
    pattern[1] = 0x100 + PatternCache.max_entries;
    try std.testing.expect(cache.admit(&pattern) == null);
    try std.testing.expect(cache.lookup(first.?.bytes).? == first.?);
    pattern[1] = 0x100;
    try std.testing.expect(cache.admit(&pattern).? == first.?);
}

test "failed cache admission releases every allocation and publishes nothing" {
    var pattern: [130]u21 = @splat('q');
    pattern[0] = '[';
    pattern[129] = ']';
    for (0..5) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var cache = PatternCache.init(std.testing.io, failing.allocator());
        try std.testing.expect(cache.admit(&pattern) == null);
        try std.testing.expectEqual(@as(usize, 0), cache.entry_count);
        try std.testing.expect(cache.lookup("[" ++ @as([128]u8, @splat('q')) ++ "]") == null);
        cache.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "concurrent pattern admission publishes one stable entry" {
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    const Worker = struct {
        fn run(c: *PatternCache) void {
            var pattern: [130]u21 = @splat('q');
            pattern[0] = '[';
            pattern[129] = ']';
            for (0..40) |_| _ = c.admit(&pattern);
        }
    };
    const a = try std.Thread.spawn(.{}, Worker.run, .{&cache});
    const b = try std.Thread.spawn(.{}, Worker.run, .{&cache});
    a.join();
    b.join();
    try std.testing.expectEqual(@as(usize, 1), cache.entry_count);
}
