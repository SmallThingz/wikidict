const std = @import("std");
const A = std.mem.Allocator;
pub const Data = struct {
    history: []const []const u8 = &.{},
    saved: []const []const u8 = &.{},
    history_limit: usize = 100,
    quiz_length: usize = 10,
    study_pool: enum { all, history, saved } = .all,
    last_title: []const u8 = "",
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
    baseline: Data = .{},
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
        var scratch_arena: std.heap.ArenaAllocator = .init(self.a);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        const path = try std.fmt.allocPrint(scratch, "{s}/.dict-state/{x}.json", .{ root, std.hash.Wyhash.hash(0, label) });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        var next = if (bytes) |text| try std.json.parseFromSliceLeaky(Data, scratch, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) else Data{};
        next.history_limit = @min(100_000, next.history_limit);
        next.quiz_length = std.math.clamp(next.quiz_length, 3, 50);
        next.media_cache_mb = @min(4096, next.media_cache_mb);
        next.history = next.history[0..@min(next.history.len, if (next.history_limit == 0) 100_000 else next.history_limit)];
        var committed: std.heap.ArenaAllocator = .init(self.a);
        errdefer committed.deinit();
        const strings = committed.allocator();
        const owned = try ownData(self.a, strings, next);
        errdefer self.a.free(owned.history);
        errdefer self.a.free(owned.saved);
        const baseline = try snapshot(strings, owned);
        const owned_path = try strings.dupe(u8, path);
        self.commit(committed, owned_path, owned, baseline);
    }
    pub fn save(self: *State, io: std.Io) !void {
        if (self.path.len == 0) return;
        var scratch_arena: std.heap.ArenaAllocator = .init(self.a);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(self.path).?);
        const lock_path = try std.fmt.allocPrint(scratch, "{s}.lock", .{self.path});
        const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
        defer lock.close(io);
        const existing = std.Io.Dir.cwd().readFileAlloc(io, self.path, scratch, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const latest = if (existing) |bytes| try std.json.parseFromSliceLeaky(Data, scratch, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) else Data{};
        var next = self.data;
        inline for (@typeInfo(Data).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "last_title")) {
                if (std.mem.eql(u8, next.last_title, self.baseline.last_title)) next.last_title = latest.last_title;
            } else if (comptime !std.mem.eql(u8, field.name, "saved") and !std.mem.eql(u8, field.name, "history") and !std.mem.eql(u8, field.name, "right") and !std.mem.eql(u8, field.name, "wrong")) {
                if (std.meta.eql(@field(next, field.name), @field(self.baseline, field.name))) @field(next, field.name) = @field(latest, field.name);
            }
        }
        next.history_limit = @min(100_000, next.history_limit);
        next.quiz_length = std.math.clamp(next.quiz_length, 3, 50);
        next.media_cache_mb = @min(4096, next.media_cache_mb);
        next.right = latest.right +| (self.data.right -| self.baseline.right);
        next.wrong = latest.wrong +| (self.data.wrong -| self.baseline.wrong);
        next.saved = try mergeWords(scratch, self.baseline.saved, self.data.saved, latest.saved, 100_000, false);
        next.history = try mergeWords(scratch, self.baseline.history, self.data.history, latest.history, if (next.history_limit == 0) 100_000 else next.history_limit, true);
        var committed: std.heap.ArenaAllocator = .init(self.a);
        errdefer committed.deinit();
        const strings = committed.allocator();
        const owned = try ownData(self.a, strings, next);
        errdefer self.a.free(owned.history);
        errdefer self.a.free(owned.saved);
        const baseline = try snapshot(strings, owned);
        const owned_path = try strings.dupe(u8, self.path);
        const bytes = try std.json.Stringify.valueAlloc(scratch, owned, .{});
        const temp = try std.fmt.allocPrint(scratch, "{s}.part", .{self.path});
        defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
        try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), self.path, io);
        self.commit(committed, owned_path, owned, baseline);
    }
    // Stage a complete owned generation before writing. A failed load/save
    // leaves data and baseline untouched; success invalidates their old slices.
    fn commit(self: *State, arena: std.heap.ArenaAllocator, path: []const u8, data: Data, baseline: Data) void {
        self.a.free(self.data.saved);
        self.a.free(self.data.history);
        self.arena.deinit();
        self.arena = arena;
        self.path = path;
        self.data = data;
        self.baseline = baseline;
    }
    fn ownData(a: A, strings: A, data: Data) !Data {
        var result = data;
        result.history = try ownWords(a, strings, data.history);
        errdefer a.free(result.history);
        result.saved = try ownWords(a, strings, data.saved);
        errdefer a.free(result.saved);
        result.last_title = try strings.dupe(u8, data.last_title);
        return result;
    }
    fn ownWords(a: A, strings: A, words: []const []const u8) ![]const []const u8 {
        const result = try a.alloc([]const u8, words.len);
        errdefer a.free(result);
        for (words, result) |word, *owned| owned.* = try strings.dupe(u8, word);
        return result;
    }
    fn snapshot(a: A, data: Data) !Data {
        var result = data;
        result.saved = try a.dupe([]const u8, data.saved);
        result.history = try a.dupe([]const u8, data.history);
        return result;
    }
    // Apply this reader's additions/removals to the latest file under the lock.
    // An idle TUI must not overwrite words saved by a concurrent CLI invocation.
    fn mergeWords(a: A, baseline: []const []const u8, local: []const []const u8, latest: []const []const u8, limit: usize, reorder: bool) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(a);
        var old: std.StringHashMapUnmanaged(usize) = .empty;
        defer old.deinit(a);
        var current: std.StringHashMapUnmanaged(void) = .empty;
        defer current.deinit(a);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        for (baseline, 0..) |word, i| try old.put(a, word, i);
        for (local) |word| try current.put(a, word, {});
        // MRU prepends leave an unchanged suffix in baseline order, even when
        // removals shorten it. A shifted row alone is not a new history visit.
        var unchanged_from = local.len;
        if (reorder) {
            var before = baseline.len;
            while (unchanged_from != 0) {
                const old_index = old.get(local[unchanged_from - 1]) orelse break;
                if (old_index >= before) break;
                before = old_index;
                unchanged_from -= 1;
            }
        }
        for (local, 0..) |word, i| {
            const changed = !old.contains(word) or (reorder and i < unchanged_from);
            if (changed and result.items.len < limit and !seen.contains(word)) {
                try result.append(a, word);
                try seen.put(a, word, {});
            }
        }
        for (latest) |word| {
            const removed = old.contains(word) and !current.contains(word);
            if (!removed and result.items.len < limit and !seen.contains(word)) {
                try result.append(a, word);
                try seen.put(a, word, {});
            }
        }
        return result.toOwnedSlice(a);
    }
    pub fn contains(words: []const []const u8, title: []const u8) bool {
        for (words) |word| if (std.mem.eql(u8, word, title)) return true;
        return false;
    }
    pub fn remember(self: *State, title: []const u8) !void {
        if (!std.mem.eql(u8, self.data.last_title, title)) self.data.last_title = try self.arena.allocator().dupe(u8, title);
        if (self.data.history_limit == 0) return;
        self.data.history = try self.prepend(self.data.history, title, self.data.history_limit, false);
    }
    pub fn bookmark(self: *State, title: []const u8) !void {
        self.data.saved = try self.prepend(self.data.saved, title, 100_000, contains(self.data.saved, title));
    }
    pub fn forget(self: *State, title: []const u8) !void {
        self.data.history = try self.prepend(self.data.history, title, if (self.data.history_limit == 0) 100_000 else self.data.history_limit, true);
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

test "concurrent readers preserve saved words settings and study increments" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var first = State.init(a);
    defer first.deinit();
    var second = State.init(a);
    defer second.deinit();
    try first.load(io, root, "English");
    try second.load(io, root, "English");
    try first.bookmark("cat");
    first.data.right = 1;
    first.data.theme = .light;
    try first.save(io);
    try second.bookmark("dog");
    second.data.right = 2;
    try second.save(io);
    try std.testing.expect(State.contains(second.data.saved, "cat"));
    try std.testing.expectEqual(@as(usize, 3), second.data.right);
    try std.testing.expectEqual(@TypeOf(second.data.theme).light, second.data.theme);
    try first.bookmark("cat");
    try first.remember("café");
    try first.save(io);
    try std.testing.expect(!State.contains(first.data.saved, "cat"));
    try std.testing.expect(State.contains(first.data.saved, "dog"));
    // An idle reader must not resurrect the removed word or double-count scores.
    try second.save(io);
    try std.testing.expect(!State.contains(second.data.saved, "cat"));
    try std.testing.expect(State.contains(second.data.saved, "dog"));
    try std.testing.expect(State.contains(second.data.history, "café"));
    try std.testing.expectEqual(@as(usize, 3), second.data.right);
}

test "last title remains owned with history off and unchanged text adopts a newer reader" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var first = State.init(a);
    defer first.deinit();
    var second = State.init(a);
    defer second.deinit();
    try first.load(io, root, "English");
    first.data.history_limit = 0;
    first.data.study_pool = .saved;
    var title = "word".*;
    try first.remember(&title);
    @memset(&title, 'x');
    try first.save(io);
    try std.testing.expectEqualStrings("word", first.data.last_title);
    try std.testing.expectEqual(@as(usize, 0), first.data.history.len);
    try second.load(io, root, "English");
    try second.remember("other");
    try second.remember("word"); // Same baseline text at a different address.
    try first.remember("remote");
    try first.save(io);
    try second.save(io);
    try std.testing.expectEqualStrings("remote", second.data.last_title);
    try std.testing.expectEqualStrings("remote", second.baseline.last_title);
    var restored = State.init(a);
    defer restored.deinit();
    try restored.load(io, root, "English");
    try std.testing.expectEqualStrings("remote", restored.data.last_title);
    try std.testing.expectEqual(@TypeOf(restored.data.study_pool).saved, restored.data.study_pool);
}

test "concurrent history keeps fresh visits before untouched shifted rows" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var first = State.init(a);
    defer first.deinit();
    var second = State.init(a);
    defer second.deinit();
    try first.load(io, root, "English");
    try first.remember("b");
    try first.remember("a");
    try first.save(io);
    try second.load(io, root, "English");
    try first.remember("remote");
    try first.save(io);
    try second.remember("local");
    try second.save(io);
    const expected = [_][]const u8{ "local", "remote", "a", "b" };
    try std.testing.expectEqual(expected.len, second.data.history.len);
    for (expected, second.data.history) |word, actual| try std.testing.expectEqualStrings(word, actual);
}

test "repeated saves reclaim JSON snapshots and superseded title strings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var counted: std.testing.FailingAllocator = .init(a, .{});
    {
        var state = State.init(counted.allocator());
        defer state.deinit();
        try state.load(io, root, "English");
        state.data.history_limit = 4;
        try state.bookmark("saved");
        var bound: usize = 0;
        for (0..128) |i| {
            var buffer: [32]u8 = undefined;
            const title = try std.fmt.bufPrint(&buffer, "title-{d:0>4}", .{i});
            try state.remember(title);
            try state.save(io);
            const live = counted.allocated_bytes - counted.freed_bytes;
            if (i == 8) bound = live + 1024;
            if (i > 8) try std.testing.expect(live <= bound);
            try std.testing.expectEqualStrings(title, state.data.last_title);
        }
    }
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "failed saves preserve both generations and reclaim staged allocations" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var counted: std.testing.FailingAllocator = .init(a, .{});
    var state = State.init(counted.allocator());
    defer state.deinit();
    try state.load(io, root, "English");
    try state.remember("before");
    try state.save(io);
    try state.remember("after");
    try state.bookmark("pending");
    state.data.right = 3;
    const data_before = state.data;
    const baseline_before = state.baseline;
    const path_before = state.path;
    const live_before = counted.allocated_bytes - counted.freed_bytes;
    const part = try std.fmt.allocPrint(a, "{s}.part", .{state.path});
    defer a.free(part);
    try std.Io.Dir.cwd().createDirPath(io, part);
    for (0..16) |_| {
        try std.testing.expectError(error.IsDir, state.save(io));
        try std.testing.expect(std.meta.eql(data_before, state.data));
        try std.testing.expect(std.meta.eql(baseline_before, state.baseline));
        try std.testing.expect(std.meta.eql(path_before, state.path));
        try std.testing.expectEqual(live_before, counted.allocated_bytes - counted.freed_bytes);
        try std.testing.expectEqualStrings("after", state.data.last_title);
        try std.testing.expectEqualStrings("before", state.baseline.last_title);
    }
    try std.Io.Dir.cwd().deleteDir(io, part);
    try state.save(io);
    try std.testing.expectEqualStrings("after", state.baseline.last_title);
    try std.testing.expectEqual(@as(usize, 3), state.data.right);
}
