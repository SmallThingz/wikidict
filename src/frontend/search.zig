//! Incremental case-insensitive search over indexed titles; payloads stay unopened.
const std = @import("std");
const store = @import("store.zig");
const unicode = @import("unicode_lower.zig");

pub const default_retained_matches: usize = 4096;
pub const max_retained_matches: usize = 128 * 1024;
const folded_cache_magic = "DFOLD201";
const folded_cache_header_len: usize = 56;
const folded_cache_min_records: usize = 100_000;
const folded_cache_max_bytes: usize = 64 * 1024 * 1024;

fn foldedKey(lower: []const u8) u16 {
    if (lower.len == 0) return 0;
    return (@as(u16, lower[0]) << 8) | @as(u16, if (lower.len > 1) lower[1] else 0);
}
fn prefixCanMatch(key: u16, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len == 1) return @as(u8, @truncate(key >> 8)) == query[0];
    return key == ((@as(u16, query[0]) << 8) | query[1]);
}
fn foldedCachePathAlloc(a: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(source_path) orelse ".";
    return std.fmt.allocPrint(a, "{s}/.dict-cache/{s}.fold2", .{ dir, std.fs.path.basename(source_path) });
}

const FoldedCache = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    count: usize,

    fn open(io: std.Io, path: []const u8, fingerprint: [32]u8, count: usize) !?FoldedCache {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        const expected = std.math.add(usize, folded_cache_header_len, std.math.mul(usize, count, 2) catch return null) catch return null;
        const len = std.math.cast(usize, (try file.stat(io)).size) orelse return null;
        if (len != expected or len > folded_cache_max_bytes) return null;
        const mapped = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(mapped);
        const keys = mapped[folded_cache_header_len..];
        if (!std.mem.eql(u8, mapped[0..8], folded_cache_magic) or
            !std.mem.eql(u8, mapped[8..40], &fingerprint) or
            std.mem.readInt(u64, mapped[40..48], .little) != count or
            std.mem.readInt(u64, mapped[48..56], .little) != std.hash.Wyhash.hash(0, keys))
        {
            std.posix.munmap(mapped);
            return null;
        }
        return .{ .bytes = mapped, .count = count };
    }
    fn deinit(self: *FoldedCache) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.* = undefined;
    }
    fn keyAt(self: FoldedCache, index: usize) u16 {
        std.debug.assert(index < self.count);
        const start = folded_cache_header_len + index * 2;
        return std.mem.readInt(u16, self.bytes[start..][0..2], .little);
    }
};

const FoldedBuilder = struct {
    io: std.Io,
    file: std.Io.File,
    mapped: []align(std.heap.page_size_min) u8,
    final_path: []u8,
    temp_path: []u8,
    count: usize,
    next: usize = 0,
    closed: bool = false,
    renamed: bool = false,

    fn init(io: std.Io, a: std.mem.Allocator, source_path: []const u8, fingerprint: [32]u8, count: usize) !FoldedBuilder {
        const payload_bytes = std.math.mul(usize, count, 2) catch return error.CacheTooLarge;
        const total = std.math.add(usize, folded_cache_header_len, payload_bytes) catch return error.CacheTooLarge;
        if (total > folded_cache_max_bytes) return error.CacheTooLarge;
        const final_path = try foldedCachePathAlloc(a, source_path);
        errdefer a.free(final_path);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(final_path).?);
        const temp_path = try std.fmt.allocPrint(a, "{s}.{d}.{d}.tmp", .{ final_path, std.os.linux.getpid(), std.Io.Clock.awake.now(io).toNanoseconds() });
        errdefer a.free(temp_path);
        var file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .read = true, .truncate = true, .exclusive = true });
        errdefer file.close(io);
        try file.setLength(io, total);
        const mapped = try std.posix.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, file.handle, 0);
        @memcpy(mapped[0..8], folded_cache_magic);
        @memcpy(mapped[8..40], &fingerprint);
        std.mem.writeInt(u64, mapped[40..48], @intCast(count), .little);
        @memset(mapped[48..56], 0);
        return .{ .io = io, .file = file, .mapped = mapped, .final_path = final_path, .temp_path = temp_path, .count = count };
    }
    fn deinit(self: *FoldedBuilder, a: std.mem.Allocator) void {
        if (self.mapped.len != 0) std.posix.munmap(self.mapped);
        if (!self.closed) self.file.close(self.io);
        if (!self.renamed) std.Io.Dir.cwd().deleteFile(self.io, self.temp_path) catch {};
        a.free(self.final_path);
        a.free(self.temp_path);
        self.* = undefined;
    }
    fn keyAt(self: FoldedBuilder, index: usize) u16 {
        std.debug.assert(index < self.next);
        const start = folded_cache_header_len + index * 2;
        return std.mem.readInt(u16, self.mapped[start..][0..2], .little);
    }
    fn append(self: *FoldedBuilder, index: usize, lower: []const u8) void {
        std.debug.assert(index == self.next and index < self.count);
        const start = folded_cache_header_len + index * 2;
        std.mem.writeInt(u16, self.mapped[start..][0..2], foldedKey(lower), .little);
        self.next += 1;
    }
    fn finish(self: *FoldedBuilder, fingerprint: [32]u8) !FoldedCache {
        if (self.next != self.count) return error.IncompleteFoldedCache;
        const keys = self.mapped[folded_cache_header_len..];
        std.mem.writeInt(u64, self.mapped[48..56], std.hash.Wyhash.hash(0, keys), .little);
        std.posix.munmap(self.mapped);
        self.mapped = &.{};
        try self.file.sync(self.io);
        self.file.close(self.io);
        self.closed = true;
        try std.Io.Dir.cwd().rename(self.temp_path, std.Io.Dir.cwd(), self.final_path, self.io);
        self.renamed = true;
        return (try FoldedCache.open(self.io, self.final_path, fingerprint, self.count)) orelse error.InvalidFoldedCache;
    }
};

pub const Task = struct {
    pub const Match = struct { index: usize, key: []u8 };
    query: []const u8 = &.{},
    matches: std.ArrayList(Match) = .empty,
    cursor: usize = 0,
    total_matches: usize = 0,
    max_matches: usize = default_retained_matches,
    complete: bool = true,
    folded_cache_min_records: usize = folded_cache_min_records,
    folded_source_set: bool = false,
    folded_source: [32]u8 = @splat(0),
    folded_count: usize = 0,
    folded_disabled: bool = false,
    folded_cache: ?FoldedCache = null,
    folded_builder: ?FoldedBuilder = null,

    fn clearMatches(self: *Task, a: std.mem.Allocator) void {
        for (self.matches.items) |match| a.free(match.key);
        self.matches.clearRetainingCapacity();
    }
    fn clearFolded(self: *Task, a: std.mem.Allocator) void {
        if (self.folded_cache) |*cache| cache.deinit();
        if (self.folded_builder) |*builder| builder.deinit(a);
        self.folded_cache = null;
        self.folded_builder = null;
        self.folded_disabled = false;
    }
    pub fn deinit(self: *Task, a: std.mem.Allocator) void {
        a.free(self.query);
        self.clearMatches(a);
        self.clearFolded(a);
        self.matches.deinit(a);
    }
    pub fn begin(self: *Task, a: std.mem.Allocator, query: []const u8) !void {
        return self.beginLimited(a, query, default_retained_matches);
    }
    pub fn beginLimited(self: *Task, a: std.mem.Allocator, query: []const u8, max_matches: usize) !void {
        if (max_matches == 0 or max_matches > max_retained_matches) return error.SearchWindowTooLarge;
        const next = try unicode.lowerAlloc(a, std.mem.trim(u8, query, " \t\r\n"));
        a.free(self.query);
        self.query = next;
        self.clearMatches(a);
        self.cursor = 0;
        self.total_matches = 0;
        self.max_matches = max_matches;
        self.complete = false;
    }
    fn ensureFolded(self: *Task, a: std.mem.Allocator, db: *store.Store) void {
        const fingerprint = db.file.fingerprint;
        const count = db.count();
        if (!self.folded_source_set or self.folded_count != count or !std.mem.eql(u8, &self.folded_source, &fingerprint)) {
            self.clearFolded(a);
            self.folded_source_set = true;
            self.folded_source = fingerprint;
            self.folded_count = count;
        }
        if (self.folded_cache != null or self.folded_builder != null or self.folded_disabled) return;
        if (count < self.folded_cache_min_records) {
            self.folded_disabled = true;
            return;
        }
        const payload_bytes = std.math.mul(usize, count, 2) catch {
            self.folded_disabled = true;
            return;
        };
        if (payload_bytes > folded_cache_max_bytes - folded_cache_header_len) {
            self.folded_disabled = true;
            return;
        }
        const path = foldedCachePathAlloc(a, db.file.path) catch {
            self.folded_disabled = true;
            return;
        };
        defer a.free(path);
        const existing = FoldedCache.open(db.file.io, path, fingerprint, count) catch null;
        if (existing) |cache| {
            self.folded_cache = cache;
            return;
        }
        self.folded_builder = FoldedBuilder.init(db.file.io, a, db.file.path, fingerprint, count) catch {
            self.folded_disabled = true;
            return;
        };
    }
    fn less(lhs: Match, rhs: Match) bool {
        return switch (std.mem.order(u8, lhs.key, rhs.key)) {
            .lt => true,
            .gt => false,
            .eq => lhs.index < rhs.index,
        };
    }
    fn keyLess(key: []const u8, index: usize, rhs: Match) bool {
        return switch (std.mem.order(u8, key, rhs.key)) {
            .lt => true,
            .gt => false,
            .eq => index < rhs.index,
        };
    }
    fn siftUp(self: *Task, child_start: usize) void {
        var child = child_start;
        while (child != 0) {
            const parent = (child - 1) / 2;
            if (!less(self.matches.items[parent], self.matches.items[child])) break;
            std.mem.swap(Match, &self.matches.items[parent], &self.matches.items[child]);
            child = parent;
        }
    }
    fn siftDown(self: *Task, parent_start: usize) void {
        var parent = parent_start;
        while (true) {
            const left = parent * 2 + 1;
            if (left >= self.matches.items.len) return;
            const right = left + 1;
            var child = left;
            if (right < self.matches.items.len and less(self.matches.items[left], self.matches.items[right])) child = right;
            if (!less(self.matches.items[parent], self.matches.items[child])) return;
            std.mem.swap(Match, &self.matches.items[parent], &self.matches.items[child]);
            parent = child;
        }
    }
    fn retain(self: *Task, a: std.mem.Allocator, key: []const u8, index: usize) !void {
        self.total_matches +|= 1;
        if (self.matches.items.len < self.max_matches) {
            const owned = try a.dupe(u8, key);
            errdefer a.free(owned);
            try self.matches.append(a, .{ .index = index, .key = owned });
            self.siftUp(self.matches.items.len - 1);
            return;
        }
        if (!keyLess(key, index, self.matches.items[0])) return;
        const owned = try a.dupe(u8, key);
        a.free(self.matches.items[0].key);
        self.matches.items[0] = .{ .index = index, .key = owned };
        self.siftDown(0);
    }
    fn knownFoldedKey(self: *Task, index: usize) ?u16 {
        if (self.folded_cache) |cache| return cache.keyAt(index);
        if (self.folded_builder) |builder| if (index < builder.next) return builder.keyAt(index);
        return null;
    }
    fn maybeFinishFolded(self: *Task, a: std.mem.Allocator) void {
        if (self.folded_builder) |*builder| {
            if (builder.next != builder.count) return;
            const cache = builder.finish(self.folded_source) catch {
                builder.deinit(a);
                self.folded_builder = null;
                self.folded_disabled = true;
                return;
            };
            builder.deinit(a);
            self.folded_builder = null;
            self.folded_cache = cache;
        }
    }
    pub fn step(self: *Task, a: std.mem.Allocator, db: *store.Store, budget: usize) !void {
        self.ensureFolded(a, db);
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        const end = self.cursor + @min(budget, db.count() - self.cursor);
        while (self.cursor < end) : (self.cursor += 1) {
            if (self.knownFoldedKey(self.cursor)) |key| if (!prefixCanMatch(key, self.query)) continue;
            text.clearRetainingCapacity();
            try unicode.writeLower(&text.writer, try db.titleAt(self.cursor));
            if (self.folded_builder) |*builder| if (self.cursor == builder.next) builder.append(self.cursor, text.written());
            if (std.mem.startsWith(u8, text.written(), self.query)) try self.retain(a, text.written(), self.cursor);
        }
        self.maybeFinishFolded(a);
        self.complete = self.cursor == db.count();
        if (self.complete) std.mem.sort(Match, self.matches.items, {}, struct {
            fn order(_: void, lhs: Match, rhs: Match) bool {
                return Task.less(lhs, rhs);
            }
        }.order);
    }
};

pub fn find(a: std.mem.Allocator, db: *store.Store, query: []const u8) !?usize {
    if (try db.find(query)) |index| return index;
    var task: Task = .{};
    defer task.deinit(a);
    try task.beginLimited(a, query, 1);
    while (!task.complete) try task.step(a, db, 4096);
    if (task.matches.items.len == 0) return null;
    const match = task.matches.items[0];
    return if (std.mem.eql(u8, match.key, task.query)) match.index else null;
}

fn testStore(a: std.mem.Allocator, titles: []const []const u8) !struct { path: []u8, db: store.Store } {
    const enc = @import("blob_encoder");
    var records = try a.alloc(enc.blob_format.RecordInput, titles.len);
    defer a.free(records);
    for (titles, 0..) |title, i| records[i] = .{ .title = title, .payload = "" };
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", records);
    defer a.free(bytes);
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/search-{d}.wikblb", .{std.Io.Clock.awake.now(std.testing.io).toNanoseconds()});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    return .{ .path = path, .db = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a } };
}

test "case-insensitive search retains only the best bounded window" {
    const a = std.testing.allocator;
    var fixture = try testStore(a, &.{ "Apple", "Banana", "aardvark", "alpha", "apricot" });
    defer {
        fixture.db.file.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, fixture.path) catch {};
        a.free(fixture.path);
    }
    var task: Task = .{};
    defer task.deinit(a);
    try task.beginLimited(a, "A", 2);
    while (!task.complete) try task.step(a, &fixture.db, 2);
    try std.testing.expectEqual(@as(usize, 4), task.total_matches);
    try std.testing.expectEqual(@as(usize, 2), task.matches.items.len);
    try std.testing.expectEqualStrings("aardvark", task.matches.items[0].key);
    try std.testing.expectEqualStrings("alpha", task.matches.items[1].key);
    try std.testing.expectEqual(@as(usize, 2), task.matches.items[0].index);
    try std.testing.expectEqual(@as(usize, 3), task.matches.items[1].index);
    try std.testing.expectError(error.SearchWindowTooLarge, task.beginLimited(a, "a", max_retained_matches + 1));
}

test "folded prefix cache persists two bytes per record and filters later queries" {
    const a = std.testing.allocator;
    var fixture = try testStore(a, &.{ "Apple", "Banana", "aardvark", "alpha", "apricot" });
    defer {
        fixture.db.file.deinit();
        const cache = foldedCachePathAlloc(a, fixture.path) catch null;
        if (cache) |path| {
            std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
            a.free(path);
        }
        std.Io.Dir.cwd().deleteFile(std.testing.io, fixture.path) catch {};
        a.free(fixture.path);
    }
    var first: Task = .{ .folded_cache_min_records = 0 };
    defer first.deinit(a);
    try first.beginLimited(a, "A", 2);
    while (!first.complete) try first.step(a, &fixture.db, 2);
    try std.testing.expect(first.folded_cache != null);
    const path = try foldedCachePathAlloc(a, fixture.path);
    defer a.free(path);
    var cache_file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer cache_file.close(std.testing.io);
    const stat = try cache_file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, folded_cache_header_len + 2 * 5), stat.size);

    var cache_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4096));
    defer a.free(cache_bytes);
    cache_bytes[folded_cache_header_len] ^= 0xff;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = cache_bytes });

    var second: Task = .{ .folded_cache_min_records = 0 };
    defer second.deinit(a);
    try second.beginLimited(a, "AP", 8);
    while (!second.complete) try second.step(a, &fixture.db, 2);
    try std.testing.expect(second.folded_cache != null);
    try std.testing.expectEqual(@as(usize, 2), second.total_matches);
    try std.testing.expectEqualStrings("apple", second.matches.items[0].key);
    try std.testing.expectEqualStrings("apricot", second.matches.items[1].key);
}
