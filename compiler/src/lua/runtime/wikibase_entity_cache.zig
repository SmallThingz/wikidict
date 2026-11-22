//! Optional Provider-owned JSON backing. Source buffers remain immutable and
//! outlive this cache; every Lua read still converts into its request allocator.
const std = @import("std");
const AllocationBudget = @import("allocation_budget.zig").AllocationBudget;

pub fn projectionNumber(value: std.json.Value) !f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |raw| std.fmt.parseFloat(f64, raw) catch return error.InvalidWikibaseEntitySnapshot,
        else => return error.InvalidWikibaseEntitySnapshot,
    };
    if (!std.math.isFinite(number)) return error.InvalidWikibaseEntitySnapshot;
    return number;
}

pub fn validateProjectionNumbers(value: std.json.Value) error{InvalidWikibaseEntitySnapshot}!void {
    // Full conversion used to reject invalid numbers even in fields that the
    // caller did not request. Preserve that boundary without allocating Lua.
    switch (value) {
        .integer, .float, .number_string => _ = try projectionNumber(value),
        .array => |array| for (array.items) |item| try validateProjectionNumbers(item),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try validateProjectionNumbers(entry.value_ptr.*);
        },
        else => {},
    }
}

pub const Cache = struct {
    pub const max_entries = 128;
    pub const max_bytes = 32 * 1024 * 1024;
    const bucket_count = 256;
    const Entry = struct {
        source: []const u8,
        parsed: std.json.Parsed(std.json.Value),
    };

    // The Cache itself is heap-stable: retained Parsed arenas point to budget.
    // Count its backing allocation explicitly, then all other allocations via
    // budget. This bounds allocator requests (including arena slack), not RSS.
    budget: AllocationBudget,
    buckets: [bucket_count]?*Entry = @splat(null),
    entry_limit: usize,
    entry_count: usize = 0,
    admission_stopped: bool = false,
    hits: u64 = 0,
    misses: u64 = 0,
    capacity_bypasses: u64 = 0,
    allocation_bypasses: u64 = 0,
    parse_bypasses: u64 = 0,
    validation_bypasses: u64 = 0,

    pub fn create(backing: std.mem.Allocator, byte_limit: usize, entry_limit: usize) !*Cache {
        const limit = @min(byte_limit, max_bytes);
        if (limit < @sizeOf(Cache)) return error.OutOfMemory;
        const self = try backing.create(Cache);
        self.* = .{
            .budget = .{ .backing = backing, .limit = limit, .used = @sizeOf(Cache), .peak = @sizeOf(Cache) },
            .entry_limit = @min(entry_limit, max_entries),
        };
        return self;
    }

    pub fn destroy(self: *Cache) void {
        const allocator = self.budget.allocator();
        for (self.buckets) |entry| if (entry) |owned| {
            owned.parsed.deinit();
            allocator.destroy(owned);
        };
        std.debug.assert(self.budget.used == @sizeOf(Cache));
        const backing = self.budget.backing;
        // AllocationBudget.free updates its state after backing.rawFree. Free
        // this object directly, never through its embedded budget allocator.
        backing.destroy(self);
    }

    fn slot(self: *const Cache, source: []const u8) usize {
        const address = @intFromPtr(source.ptr);
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&address));
        var index: usize = @intCast(hash & (bucket_count - 1));
        var probes: usize = 0;
        while (probes < bucket_count) : (probes += 1) {
            const entry = self.buckets[index] orelse return index;
            if (entry.source.ptr == source.ptr and entry.source.len == source.len) return index;
            index = (index + 1) & (bucket_count - 1);
        }
        unreachable; // Admission keeps the fixed index at most half full.
    }

    pub fn lookupOrAdmit(self: *Cache, source: []const u8) ?*const std.json.Value {
        const index = self.slot(source);
        if (self.buckets[index]) |entry| {
            self.hits += 1;
            return &entry.parsed.value;
        }
        self.misses += 1;
        if (self.admission_stopped or self.entry_count >= self.entry_limit) {
            self.admission_stopped = true;
            self.capacity_bypasses += 1;
            return null;
        }
        const allocator = self.budget.allocator();
        const before = self.budget.used;
        const entry = allocator.create(Entry) catch {
            self.allocation_bypasses += 1;
            self.admission_stopped = true;
            return null;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| {
            allocator.destroy(entry);
            std.debug.assert(self.budget.used == before);
            if (err == error.OutOfMemory) {
                self.allocation_bypasses += 1;
            } else {
                self.parse_bypasses += 1;
            }
            // Do not repeatedly attempt an impossible admission before doing
            // the authoritative request parse. Existing hits remain usable.
            self.admission_stopped = true;
            return null;
        };
        // Certify the entire immutable tree once, including unrequested fields.
        // A failed optional admission must leave the authoritative raw path.
        validateProjectionNumbers(parsed.value) catch {
            parsed.deinit();
            allocator.destroy(entry);
            std.debug.assert(self.budget.used == before);
            self.validation_bypasses += 1;
            self.admission_stopped = true;
            return null;
        };
        entry.* = .{ .source = source, .parsed = parsed };
        self.buckets[index] = entry;
        self.entry_count += 1;
        return &entry.parsed.value;
    }
};

test "parsed entity cache keeps stable source identities and pointers as it fills" {
    const cache = try Cache.create(std.testing.allocator, Cache.max_bytes, Cache.max_entries);
    defer cache.destroy();
    var sources: [Cache.max_entries][64]u8 = undefined;
    const first_source = try std.fmt.bufPrint(&sources[0], "{{\"id\":\"Q1\",\"value\":\"caf\\u00e9\"}}", .{});
    const first = cache.lookupOrAdmit(first_source).?;
    try std.testing.expect(cache.budget.used > @sizeOf(Cache) + first_source.len);
    for (1..Cache.max_entries) |i| {
        const source = try std.fmt.bufPrint(&sources[i], "{{\"id\":\"Q{d}\"}}", .{i + 1});
        try std.testing.expect(cache.lookupOrAdmit(source) != null);
    }
    try std.testing.expect(cache.lookupOrAdmit(first_source).? == first);
    try std.testing.expectEqualStrings("café", first.object.get("value").?.string);
    try std.testing.expectEqual(@as(usize, Cache.max_entries), cache.entry_count);
    try std.testing.expect(cache.budget.peak <= cache.budget.limit);
    try std.testing.expect(cache.lookupOrAdmit("{\"id\":\"Q999\"}") == null);
    try std.testing.expect(cache.lookupOrAdmit(first_source).? == first);
}

test "parsed entity cache keys captured rows instead of canonical entity ids" {
    const source_a = try std.testing.allocator.dupe(u8, "{\"id\":\"Q1\"}");
    defer std.testing.allocator.free(source_a);
    const source_b = try std.testing.allocator.dupe(u8, source_a);
    defer std.testing.allocator.free(source_b);
    const cache = try Cache.create(std.testing.allocator, Cache.max_bytes, Cache.max_entries);
    defer cache.destroy();
    const a = cache.lookupOrAdmit(source_a).?;
    const b = cache.lookupOrAdmit(source_b).?;
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 2), cache.entry_count);
    try std.testing.expect(cache.lookupOrAdmit(source_a).? == a);
}

test "parsed entity cache enforces real allocation budget and releases failed admission" {
    const source = "{\"id\":\"Q1\",\"labels\":{\"en\":{\"value\":\"example\"}},\"claims\":{\"P1\":[{\"rank\":\"normal\"}]}}";
    // Disable in-place growth so the same parse has deterministic allocation
    // points independent of the backing heap's current layout.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const required = blk: {
        const measured = try Cache.create(backing.allocator(), Cache.max_bytes, Cache.max_entries);
        defer measured.destroy();
        try std.testing.expect(measured.lookupOrAdmit(source) != null);
        try std.testing.expect(measured.budget.peak > @sizeOf(Cache) + source.len);
        break :blk measured.budget.peak;
    };
    const too_small = try Cache.create(backing.allocator(), required - 1, Cache.max_entries);
    defer too_small.destroy();
    try std.testing.expect(too_small.lookupOrAdmit(source) == null);
    try std.testing.expectEqual(@as(usize, @sizeOf(Cache)), too_small.budget.used);
    try std.testing.expectEqual(@as(usize, 0), too_small.entry_count);
    try std.testing.expect(too_small.admission_stopped);
    try std.testing.expect(too_small.lookupOrAdmit(source) == null);
    try std.testing.expectEqual(@as(u64, 1), too_small.allocation_bypasses);
    const exact = try Cache.create(backing.allocator(), required, Cache.max_entries);
    defer exact.destroy();
    try std.testing.expect(exact.lookupOrAdmit(source) != null);
    try std.testing.expectEqual(required, exact.budget.peak);
    try std.testing.expectError(error.OutOfMemory, Cache.create(std.testing.allocator, @sizeOf(Cache) - 1, Cache.max_entries));
}

test "parsed entity cache optional OOM and malformed parse preserve prior hits" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const first_source = "{\"id\":\"Q1\"}";
    {
        const cache = try Cache.create(backing.allocator(), Cache.max_bytes, Cache.max_entries);
        defer cache.destroy();
        const first = cache.lookupOrAdmit(first_source).?;
        const retained = cache.budget.used;
        // Permit Entry and Parsed arena header allocation; fail inside the parse.
        backing.fail_index = backing.alloc_index + 2;
        try std.testing.expect(cache.lookupOrAdmit("{\"id\":\"Q2\"}") == null);
        try std.testing.expect(backing.has_induced_failure);
        try std.testing.expectEqual(retained, cache.budget.used);
        try std.testing.expect(cache.lookupOrAdmit(first_source).? == first);
    }
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);

    const malformed = try Cache.create(std.testing.allocator, Cache.max_bytes, 1);
    defer malformed.destroy();
    try std.testing.expect(malformed.lookupOrAdmit("{") == null);
    try std.testing.expectEqual(@as(usize, @sizeOf(Cache)), malformed.budget.used);
    try std.testing.expectEqual(@as(u64, 1), malformed.parse_bypasses);
    const disabled = try Cache.create(std.testing.allocator, Cache.max_bytes, 0);
    defer disabled.destroy();
    try std.testing.expect(disabled.lookupOrAdmit(first_source) == null);
    try std.testing.expectEqual(@as(usize, @sizeOf(Cache)), disabled.budget.used);
}

test "parsed entity cache validates unrequested nested numbers before admission" {
    const cache = try Cache.create(std.testing.allocator, Cache.max_bytes, Cache.max_entries);
    defer cache.destroy();
    const good_source = "{\"id\":\"Q1\",\"schemaVersion\":2,\"unused\":[{\"n\":1.5}]}";
    const good = cache.lookupOrAdmit(good_source).?;
    const retained = cache.budget.used;
    const invalid_source = "{\"id\":\"Q2\",\"schemaVersion\":2,\"unused\":[{\"n\":1e9999}]}";
    try std.testing.expect(cache.lookupOrAdmit(invalid_source) == null);
    try std.testing.expectEqual(retained, cache.budget.used);
    try std.testing.expectEqual(@as(usize, 1), cache.entry_count);
    try std.testing.expectEqual(@as(u64, 1), cache.validation_bypasses);
    try std.testing.expect(cache.admission_stopped);
    try std.testing.expect(cache.lookupOrAdmit(good_source).? == good);
    try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, validateProjectionNumbers(.{ .number_string = "1e9999" }));
}
