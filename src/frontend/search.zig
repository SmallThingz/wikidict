//! Incremental search over indexed titles; entry payloads stay unopened.
const std = @import("std");
const store = @import("store.zig");
const unicode = @import("unicode_lower.zig");

pub const Task = struct {
    pub const Match = struct { index: usize, offset: usize, len: usize };
    query: []const u8 = &.{},
    matches: std.ArrayList(Match) = .empty,
    keys: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    complete: bool = true,

    pub fn deinit(self: *Task, a: std.mem.Allocator) void {
        a.free(self.query);
        self.matches.deinit(a);
        self.keys.deinit(a);
    }
    pub fn begin(self: *Task, a: std.mem.Allocator, query: []const u8) !void {
        const next = try unicode.lowerAlloc(a, std.mem.trim(u8, query, " \t\r\n"));
        a.free(self.query);
        self.query = next;
        self.matches.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        self.cursor = 0;
        self.complete = false;
    }
    pub fn step(self: *Task, a: std.mem.Allocator, db: *store.Store, budget: usize) !void {
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        const end = self.cursor + @min(budget, db.count() - self.cursor);
        while (self.cursor < end) : (self.cursor += 1) {
            text.clearRetainingCapacity();
            try unicode.writeLower(&text.writer, try db.titleAt(self.cursor));
            if (std.mem.startsWith(u8, text.written(), self.query)) {
                try self.matches.ensureUnusedCapacity(a, 1);
                const offset = self.keys.items.len;
                try self.keys.appendSlice(a, text.written());
                self.matches.appendAssumeCapacity(.{ .index = self.cursor, .offset = offset, .len = text.written().len });
            }
        }
        self.complete = self.cursor == db.count();
        if (self.complete) std.mem.sort(Match, self.matches.items, self.keys.items, struct {
            fn less(keys: []const u8, x: Match, y: Match) bool {
                return switch (std.mem.order(u8, keys[x.offset..][0..x.len], keys[y.offset..][0..y.len])) {
                    .lt => true,
                    .gt => false,
                    .eq => x.index < y.index,
                };
            }
        }.less);
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
