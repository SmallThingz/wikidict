const std = @import("std");
const Registry = @import("namespace_registry").Registry;
const lua = @import("parser/root.zig");
const usage = @import("usage.zig");
const static_encode = @import("direct/static_literal_encode.zig");

// Only grammar/lexical errors from lua.parse may become load-time failures.
// Allocation, source reads, dependency analysis and compiler failures stay fatal.
pub fn isSyntaxFailure(err: anyerror) bool {
    return switch (err) {
        error.UnexpectedToken, error.UnexpectedEof, error.InvalidLongString,
        error.InvalidString, error.InvalidNumber, error.InvalidAssignment => true,
        else => false,
    };
}

pub const Row = struct {
    page_id: u64,
    title: []const u8,
    path: []const u8,
    bytes: u64,
};

// Each slot owns its AST and dependency facts until the ordered consumer releases
// it. Bounded lookahead avoids retaining a corpus worth of syntax trees. Shared
// global/shape IDs are assigned only by the consumer, never by parser threads.
pub const Slot = struct {
    io: std.Io,
    root: []const u8,
    registry: *const Registry,
    arena: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    wake: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    row: Row = undefined,
    chunk: ?lua.Chunk = null,
    syntax_error: ?[]const u8 = null,
    requires: std.ArrayList([]const u8) = .empty,
    load_data: std.ArrayList([]const u8) = .empty,
    dynamic: bool = false,
    failure: ?anyerror = null,

    fn parse(self: *Slot) !void {
        const a = self.arena.allocator();
        const path = try std.fs.path.join(a, &.{ self.root, self.row.path });
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const source = try a.alloc(u8, std.math.cast(usize, stat.size) orelse return error.FileTooBig);
        if (try file.readPositionalAll(self.io, source, 0) != source.len) return error.Truncated;
        self.chunk = lua.parse(a, source) catch |err| {
            if (!isSyntaxFailure(err)) return err;
            // The parser exposes an error kind, not a source position.
            self.syntax_error = try std.fmt.allocPrint(a, "error loading module '{s}': {s}", .{ self.row.title, @errorName(err) });
            return;
        };
        if (static_encode.rootLiteral(self.chunk.?.body) == null)
            self.dynamic = try usage.collectModuleLoadsDetailed(a, self.registry, self.chunk.?.body, &self.requires, &self.load_data);
    }

    fn run(self: *Slot) void {
        while (true) {
            self.wake.waitUncancelable(self.io);
            self.wake.reset();
            if (self.stop.load(.acquire)) return;
            self.parse() catch |err| {
                self.failure = err;
            };
            self.done.set(self.io);
        }
    }

    pub fn dispatch(self: *Slot, row: Row) void {
        self.row = row;
        self.done.reset();
        if (self.thread == null) {
            self.parse() catch |err| {
                self.failure = err;
            };
            self.done.set(self.io);
        } else self.wake.set(self.io);
    }

    pub fn wait(self: *Slot) !void {
        self.done.waitUncancelable(self.io);
        if (self.failure) |err| {
            std.debug.print("Lua parse failed: {s}: {s}\n", .{ self.row.title, @errorName(err) });
            return err;
        }
    }

    pub fn release(self: *Slot) void {
        if (self.chunk) |*chunk| chunk.deinit();
        self.chunk = null;
        self.syntax_error = null;
        _ = self.arena.reset(.retain_capacity);
        self.requires = .empty;
        self.load_data = .empty;
        self.dynamic = false;
        self.failure = null;
    }
};

pub const Pool = struct {
    slots: []Slot,
    pub fn init(io: std.Io, root: []const u8, registry: *const Registry, count: usize) !Pool {
        const a = std.heap.smp_allocator;
        const slots = try a.alloc(Slot, count);
        errdefer a.free(slots);
        for (slots) |*slot| slot.* = .{ .io = io, .root = root, .registry = registry, .arena = .init(a) };
        var spawned: usize = 0;
        errdefer {
            for (slots[0..spawned]) |*slot| {
                slot.stop.store(true, .release);
                slot.wake.set(io);
            }
            for (slots[0..spawned]) |*slot| slot.thread.?.join();
            for (slots) |*slot| slot.arena.deinit();
        }
        if (count > 1) for (slots) |*slot| {
            slot.thread = try std.Thread.spawn(.{}, Slot.run, .{slot});
            spawned += 1;
        };
        return .{ .slots = slots };
    }

    pub fn deinit(self: *Pool) void {
        for (self.slots) |*slot| {
            slot.stop.store(true, .release);
            slot.wake.set(slot.io);
        }
        for (self.slots) |*slot| if (slot.thread) |thread| thread.join();
        for (self.slots) |*slot| {
            slot.release();
            slot.arena.deinit();
        }
        std.heap.smp_allocator.free(self.slots);
    }
};

test "syntax failure classification excludes infrastructure and analysis errors" {
    for ([_]anyerror{ error.UnexpectedToken, error.UnexpectedEof, error.InvalidLongString, error.InvalidString, error.InvalidNumber, error.InvalidAssignment }) |err|
        try std.testing.expect(isSyntaxFailure(err));
    for ([_]anyerror{ error.OutOfMemory, error.FileNotFound, error.Truncated, error.InvalidModuleLookupId }) |err|
        try std.testing.expect(!isSyntaxFailure(err));
    try std.testing.expectError(error.UnexpectedToken, lua.parse(std.testing.allocator, "function f() while true do ...... end end"));
}

test "parse slot preserves syntax load failures and can be reused after release" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "fixture.lua" });
    defer a.free(path);
    var registry = try Registry.init(a, @import("namespace_registry").english_test_fixture);
    defer registry.deinit();
    var pool = try Pool.init(std.testing.io, root, &registry, 1);
    defer pool.deinit();
    const slot = &pool.slots[0];
    for ([_][]const u8{ "return {}", "function f() while true do ...... end end", "return {}" }, 0..) |source, index| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = source });
        slot.dispatch(.{ .page_id = 1, .title = "Module:Fixture", .path = "fixture.lua", .bytes = source.len });
        try slot.wait();
        if (index == 1) {
            try std.testing.expect(slot.chunk == null);
            try std.testing.expectEqualStrings("error loading module 'Module:Fixture': UnexpectedToken", slot.syntax_error.?);
        } else {
            try std.testing.expect(slot.chunk != null);
            try std.testing.expect(slot.syntax_error == null);
        }
        slot.release();
        try std.testing.expect(slot.syntax_error == null);
        try std.testing.expect(slot.chunk == null);
    }
    slot.dispatch(.{ .page_id = 2, .title = "Module:Missing", .path = "missing.lua", .bytes = 0 });
    try std.testing.expectError(error.FileNotFound, slot.wait());
    try std.testing.expect(slot.syntax_error == null);
    slot.release();
}

test "parse slot allocation failures remain fatal through syntax diagnostic creation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "broken.lua" });
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "function f() while true do ...... end end" });
    var registry = try Registry.init(a, @import("namespace_registry").english_test_fixture);
    defer registry.deinit();
    const Probe = struct {
        fn run(backing: std.mem.Allocator, source_root: []const u8, namespaces: *const Registry) !void {
            var slot: Slot = .{ .io = std.testing.io, .root = source_root, .registry = namespaces, .arena = .init(backing) };
            defer slot.arena.deinit();
            // Only parse/diagnostic allocations are under test. release() also
            // performs optional retained-capacity preheating that may fail safely.
            defer if (slot.chunk) |*chunk| chunk.deinit();
            slot.dispatch(.{ .page_id = 1, .title = "Module:Broken", .path = "broken.lua", .bytes = "function f() while true do ...... end end".len });
            try slot.wait();
            try std.testing.expect(slot.syntax_error != null and slot.chunk == null);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Probe.run, .{ root, &registry });
}
