const std = @import("std");
const lua = @import("parser/root.zig");
const usage = @import("usage.zig");
const static_encode = @import("direct/static_literal_encode.zig");

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
    arena: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    wake: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    row: Row = undefined,
    chunk: ?lua.Chunk = null,
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
        self.chunk = try lua.parse(a, source);
        if (static_encode.rootLiteral(self.chunk.?.body) == null)
            self.dynamic = try usage.collectModuleLoadsDetailed(a, self.chunk.?.body, &self.requires, &self.load_data);
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
        _ = self.arena.reset(.retain_capacity);
        self.requires = .empty;
        self.load_data = .empty;
        self.dynamic = false;
        self.failure = null;
    }
};

pub const Pool = struct {
    slots: []Slot,
    pub fn init(io: std.Io, root: []const u8, count: usize) !Pool {
        const a = std.heap.smp_allocator;
        const slots = try a.alloc(Slot, count);
        errdefer a.free(slots);
        for (slots) |*slot| slot.* = .{ .io = io, .root = root, .arena = .init(a) };
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
