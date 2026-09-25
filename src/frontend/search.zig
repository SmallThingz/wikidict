//! Incremental search over indexed titles; entry payloads stay unopened.
const std = @import("std");
const store = @import("store.zig");
const unicode = @import("unicode_lower.zig");

pub const default_retained_matches: usize = 4096;
pub const max_retained_matches: usize = 128 * 1024;

pub const Task = struct {
    pub const Match = struct { index: usize, key: []u8 };
    query: []const u8 = &.{},
    matches: std.ArrayList(Match) = .empty,
    cursor: usize = 0,
    total_matches: usize = 0,
    max_matches: usize = default_retained_matches,
    complete: bool = true,

    fn clearMatches(self: *Task, a: std.mem.Allocator) void {
        for (self.matches.items) |match| a.free(match.key);
        self.matches.clearRetainingCapacity();
    }
    pub fn deinit(self: *Task, a: std.mem.Allocator) void {
        a.free(self.query);
        self.clearMatches(a);
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
    /// During scanning matches form a max-heap. The root is the worst retained
    /// result, so a new candidate can be admitted in O(log K) without retaining
    /// every match in a huge dictionary.
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
    pub fn step(self: *Task, a: std.mem.Allocator, db: *store.Store, budget: usize) !void {
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        const end = self.cursor + @min(budget, db.count() - self.cursor);
        while (self.cursor < end) : (self.cursor += 1) {
            text.clearRetainingCapacity();
            try unicode.writeLower(&text.writer, try db.titleAt(self.cursor));
            if (std.mem.startsWith(u8, text.written(), self.query)) try self.retain(a, text.written(), self.cursor);
        }
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
    const lowered = try unicode.lowerAlloc(a, std.mem.trim(u8, query, " \t\r\n"));
    defer a.free(lowered);
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (0..db.count()) |index| {
        text.clearRetainingCapacity();
        try unicode.writeLower(&text.writer, try db.titleAt(index));
        if (std.mem.eql(u8, text.written(), lowered)) return index;
    }
    return null;
}

test "case-insensitive search retains only the best bounded window" {
    const enc = @import("blob_encoder");
    const a = std.testing.allocator;
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &.{
        .{ .title = "Apple", .payload = "" },
        .{ .title = "Banana", .payload = "" },
        .{ .title = "aardvark", .payload = "" },
        .{ .title = "alpha", .payload = "" },
        .{ .title = "apricot", .payload = "" },
    });
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/search.wikblb", .{tmp.sub_path});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();

    var task: Task = .{};
    defer task.deinit(a);
    try task.beginLimited(a, "A", 2);
    while (!task.complete) try task.step(a, &db, 2);
    try std.testing.expectEqual(@as(usize, 4), task.total_matches);
    try std.testing.expectEqual(@as(usize, 2), task.matches.items.len);
    try std.testing.expectEqualStrings("aardvark", task.matches.items[0].key);
    try std.testing.expectEqualStrings("alpha", task.matches.items[1].key);
    try std.testing.expectEqual(@as(usize, 2), task.matches.items[0].index);
    try std.testing.expectEqual(@as(usize, 3), task.matches.items[1].index);
    try std.testing.expectError(error.SearchWindowTooLarge, task.beginLimited(a, "a", max_retained_matches + 1));
}
