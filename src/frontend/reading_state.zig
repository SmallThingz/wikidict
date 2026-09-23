const std = @import("std");
const A = std.mem.Allocator;
pub const Data = struct {
    history: []const []const u8 = &.{},
    saved: []const []const u8 = &.{},
    history_limit: usize = 100,
    quiz_length: usize = 10,
    right: usize = 0,
    wrong: usize = 0,
    details: bool = false,
    allow_images: bool = false,
    allow_audio: bool = false,
    media_cache_mb: usize = 100,
    collapse_pronunciation: bool = true,
    collapse_etymology: bool = true,
    collapse_other: bool = true,
    collapse_notes: bool = true,
    theme: enum { terminal, dark, light } = .dark,
};
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    a: A,
    data: Data = .{},
    path: []const u8 = "",
    pub fn init(a: A) State {
        return .{ .arena = .init(a), .a = a };
    }
    pub fn deinit(self: *State) void {
        self.a.free(self.data.history);
        self.a.free(self.data.saved);
        self.arena.deinit();
    }
    pub fn load(self: *State, io: std.Io, root: []const u8, label: []const u8) !void {
        const a = self.arena.allocator();
        self.path = try std.fmt.allocPrint(a, "{s}/.dict-state/{x}.json", .{ root, std.hash.Wyhash.hash(0, label) });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var next = try std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        next.history_limit = @min(100_000, next.history_limit);
        next.quiz_length = std.math.clamp(next.quiz_length, 3, 50);
        next.media_cache_mb = @min(4096, next.media_cache_mb);
        const history = try self.a.dupe([]const u8, next.history[0..@min(next.history.len, next.history_limit)]);
        errdefer self.a.free(history);
        const saved = try self.a.dupe([]const u8, next.saved);
        self.a.free(self.data.history);
        self.a.free(self.data.saved);
        next.history = history;
        next.saved = saved;
        self.data = next;
    }
    pub fn save(self: *State, io: std.Io) !void {
        if (self.path.len == 0) return;
        const a = self.arena.allocator();
        const bytes = try std.json.Stringify.valueAlloc(self.a, self.data, .{});
        defer self.a.free(bytes);
        const temp = try std.fmt.allocPrint(a, "{s}.part", .{self.path});
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(self.path).?);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
        try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), self.path, io);
    }
    pub fn contains(words: []const []const u8, title: []const u8) bool {
        for (words) |word| if (std.mem.eql(u8, word, title)) return true;
        return false;
    }
    pub fn remember(self: *State, title: []const u8) !void {
        if (self.data.history_limit == 0) return;
        self.data.history = try self.prepend(self.data.history, title, self.data.history_limit, false);
    }
    pub fn bookmark(self: *State, title: []const u8) !void {
        self.data.saved = try self.prepend(self.data.saved, title, 100_000, contains(self.data.saved, title));
    }
    fn prepend(self: *State, words: []const []const u8, title: []const u8, limit: usize, remove: bool) ![]const []const u8 {
        const a = self.a;
        var next: std.ArrayList([]const u8) = .empty;
        errdefer next.deinit(a);
        if (!remove) {
            var stable: ?[]const u8 = null;
            for (words) |word| if (std.mem.eql(u8, word, title)) {
                stable = word;
                break;
            };
            try next.append(a, stable orelse try self.arena.allocator().dupe(u8, title));
        }
        for (words) |word| if (!std.mem.eql(u8, word, title) and next.items.len < limit) {
            try next.append(a, word);
        };
        const result = try next.toOwnedSlice(a);
        self.a.free(words);
        return result;
    }
};
test "reading history is bounded, deduplicated and independent of saved words" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    state.data.history_limit = 2;
    try state.remember("a");
    try state.remember("b");
    try state.remember("a");
    try std.testing.expectEqualStrings("a", state.data.history[0]);
    try state.bookmark("a");
    try state.remember("c");
    try std.testing.expectEqual(@as(usize, 2), state.data.history.len);
    try std.testing.expect(State.contains(state.data.saved, "a"));
    try state.bookmark("a");
    try std.testing.expectEqual(@as(usize, 0), state.data.saved.len);
    state.data.history_limit = 0;
    try state.remember("disabled");
    try std.testing.expect(!State.contains(state.data.history, "disabled"));
}
