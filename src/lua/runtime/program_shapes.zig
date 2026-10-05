//! Immutable shapes keep string-only keys as slices and mixed keys boxed.
//! Pure 1..N layouts need no key storage; no hot-path metadata decoding is needed.
const std = @import("std");
const rt = @import("zig_runtime");
const metadata = @import("lua_program_metadata");

pub const Storage = struct {
    shapes: []rt.Shape,
    boxed: []rt.Value,
    strings: [][]const u8,
    sorted: []u32,

    pub fn deinit(self: Storage, a: std.mem.Allocator) void {
        a.free(self.sorted);
        a.free(self.strings);
        a.free(self.boxed);
        a.free(self.shapes);
    }
};

fn readKey(reader: *metadata.Reader) !rt.Value {
    const tag = std.enums.fromInt(metadata.ShapeKeyTag, try reader.readU32()) orelse return error.InvalidProgramMetadata;
    return switch (tag) {
        .string => .{ .string = try reader.readString() },
        .number => .{ .number = @bitCast(try reader.readU64()) },
        .false_ => .{ .boolean = false },
        .true_ => .{ .boolean = true },
    };
}

pub fn load(a: std.mem.Allocator, reader: *metadata.Reader, shape_count: u32, field_total: u32) !Storage {
    const first = reader.*;
    const shapes = try a.alloc(rt.Shape, shape_count);
    errdefer a.free(shapes);
    var fields: usize = 0;
    var boxed_count: usize = 0;
    var string_count: usize = 0;
    var sorted_count: usize = 0;
    // Validate framing and choose storage before allocating any key slabs.
    for (shapes) |*shape| {
        const count = try reader.readU32();
        if (count > field_total -| fields) return error.InvalidProgramMetadata;
        var dense = true;
        var all_strings = true;
        for (0..count) |slot| {
            const key = try readKey(reader);
            if (key != .string) all_strings = false;
            if (key != .number or key.number != @as(f64, @floatFromInt(slot + 1))) dense = false;
        }
        const keys: rt.Shape.Keys = if (dense) .dense_array else if (all_strings)
            .{ .strings = &.{} }
        else
            .{ .boxed = &.{} };
        switch (keys) {
            .boxed => boxed_count += count,
            .strings => string_count += count,
            .dense_array => {},
        }
        const sorted = try reader.readU32();
        if (sorted > count) return error.InvalidProgramMetadata;
        for (0..sorted) |_| if (try reader.readU32() >= count) return error.InvalidProgramMetadata;
        sorted_count += sorted;
        fields += count;
        shape.* = .{ .keys = keys, .field_count = count, .open = true, .all_string_keys = sorted == count };
    }
    if (fields != field_total) return error.InvalidProgramMetadata;
    try reader.finish();
    const boxed = try a.alloc(rt.Value, boxed_count);
    errdefer a.free(boxed);
    const strings = try a.alloc([]const u8, string_count);
    errdefer a.free(strings);
    const sorted = try a.alloc(u32, sorted_count);
    errdefer a.free(sorted);
    var replay = first;
    var boxed_at: usize = 0;
    var string_at: usize = 0;
    var sorted_at: usize = 0;
    for (shapes) |*shape| {
        const count = try replay.readU32();
        if (count != shape.field_count) return error.InvalidProgramMetadata;
        switch (shape.keys) {
            .boxed => shape.keys = .{ .boxed = boxed[boxed_at..][0..count] },
            .strings => shape.keys = .{ .strings = strings[string_at..][0..count] },
            .dense_array => {},
        }
        for (0..count) |slot| {
            const key = try readKey(&replay);
            switch (shape.keys) {
                .boxed => boxed[boxed_at + slot] = key,
                .strings => strings[string_at + slot] = if (key == .string) key.string else return error.InvalidProgramMetadata,
                .dense_array => {},
            }
        }
        switch (shape.keys) {
            .boxed => boxed_at += count,
            .strings => string_at += count,
            .dense_array => {},
        }
        const sorted_len = try replay.readU32();
        if (sorted_len > sorted.len -| sorted_at) return error.InvalidProgramMetadata;
        shape.sorted_string_slots = sorted[sorted_at..][0..sorted_len];
        var previous: ?[]const u8 = null;
        for (sorted[sorted_at..][0..sorted_len]) |*slot| {
            slot.* = try replay.readU32();
            const name = shape.stringKeyAt(slot.*) orelse return error.InvalidProgramMetadata;
            if (previous) |old| if (std.mem.order(u8, old, name) != .lt) return error.InvalidProgramMetadata;
            previous = name;
        }
        sorted_at += sorted_len;
    }
    if (boxed_at != boxed.len or string_at != strings.len or sorted_at != sorted.len) return error.InvalidProgramMetadata;
    try replay.finish();
    return .{ .shapes = shapes, .boxed = boxed, .strings = strings, .sorted = sorted };
}

fn writeShape(w: *std.Io.Writer, keys: []const rt.Value, sorted: []const u32) !void {
    try metadata.writeU32(w, @intCast(keys.len));
    for (keys) |key| switch (key) {
        .string => |s| {
            try metadata.writeU32(w, @intFromEnum(metadata.ShapeKeyTag.string));
            try metadata.writeString(w, s);
        },
        .number => |n| {
            try metadata.writeU32(w, @intFromEnum(metadata.ShapeKeyTag.number));
            try metadata.writeU64(w, @bitCast(n));
        },
        .boolean => |b| try metadata.writeU32(w, @intFromEnum(if (b) metadata.ShapeKeyTag.true_ else metadata.ShapeKeyTag.false_)),
        else => unreachable,
    };
    try metadata.writeU32(w, @intCast(sorted.len));
    for (sorted) |slot| try metadata.writeU32(w, slot);
}

test "typed shape storage boxes only mixed keys and elides exact dense keys" {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer w.deinit();
    try writeShape(&w.writer, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } }, &.{});
    try writeShape(&w.writer, &.{ .{ .string = "a\x00\xff" }, .{ .boolean = true }, .{ .number = -0.0 }, .{ .string = "z" } }, &.{ 0, 3 });
    try writeShape(&w.writer, &.{ .{ .number = 2 }, .{ .number = 1 } }, &.{});
    var reader = metadata.Reader{ .bytes = w.written() };
    const storage = try load(std.testing.allocator, &reader, 3, 9);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expect(storage.shapes[0].keys == .dense_array);
    try std.testing.expect(storage.shapes[1].keys == .boxed);
    try std.testing.expect(storage.shapes[2].keys == .boxed);
    try std.testing.expectEqual(@as(usize, 6), storage.boxed.len);
    try std.testing.expectEqual(@as(usize, 0), storage.strings.len);
    try std.testing.expectEqual(@as(usize, 2), storage.sorted.len);
    try std.testing.expectEqualStrings("a\x00\xff", storage.shapes[1].stringKeyAt(0).?);
    try std.testing.expect(storage.shapes[1].keyAt(1).?.boolean);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(storage.shapes[1].keyAt(2).?.number)));
    try std.testing.expectEqual(@as(f64, 3), storage.shapes[0].keyAt(2).?.number);
    try std.testing.expect(storage.shapes[0].keyAt(3) == null);
}

test "pure strings use slices independently of partial sorted index" {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer w.deinit();
    try writeShape(&w.writer, &.{ .{ .string = "same" }, .{ .string = "same" }, .{ .string = "z" } }, &.{0});
    var reader = metadata.Reader{ .bytes = w.written() };
    const storage = try load(std.testing.allocator, &reader, 1, 3);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expect(storage.shapes[0].keys == .strings);
    try std.testing.expect(!storage.shapes[0].all_string_keys);
    try std.testing.expectEqual(@as(usize, 0), storage.boxed.len);
    try std.testing.expectEqual(@as(usize, 3), storage.strings.len);
    try std.testing.expectEqual(@as(usize, 1), storage.sorted.len);
    try std.testing.expectEqualStrings("same", storage.shapes[0].stringKeyAt(1).?);
}

test "shape loader rejects corrupt and truncated framing without leaking" {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer w.deinit();
    try writeShape(&w.writer, &.{ .{ .string = "x" }, .{ .number = 2 } }, &.{0});
    for (0..w.written().len) |len| {
        var reader = metadata.Reader{ .bytes = w.written()[0..len] };
        try std.testing.expectError(error.InvalidProgramMetadata, load(std.testing.allocator, &reader, 1, 2));
    }
    var reader = metadata.Reader{ .bytes = w.written() };
    try std.testing.expectError(error.InvalidProgramMetadata, load(std.testing.allocator, &reader, 1, 3));
    w.clearRetainingCapacity();
    try writeShape(&w.writer, &.{ .{ .string = "z" }, .{ .string = "a" } }, &.{ 0, 1 });
    reader = .{ .bytes = w.written() };
    try std.testing.expectError(error.InvalidProgramMetadata, load(std.testing.allocator, &reader, 1, 2));
}

fn differential(keys: []const rt.Value, sorted: []const u32) !void {
    const a = std.testing.allocator;
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    try writeShape(&w.writer, keys, sorted);
    var reader = metadata.Reader{ .bytes = w.written() };
    const storage = try load(a, &reader, 1, @intCast(keys.len));
    defer storage.deinit(a);
    const lookup = try rt.buildShapeStringIndices(a, storage.shapes);
    defer a.free(lookup);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ctx = try rt.Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const boxed = rt.Shape{ .keys = .{ .boxed = keys }, .field_count = @intCast(keys.len), .sorted_string_slots = sorted, .open = true, .all_string_keys = sorted.len == keys.len };
    const left = try ctx.newShapedTable(&boxed);
    const right = try ctx.newShapedTable(&storage.shapes[0]);
    for (keys, 0..) |key, i| {
        const value = rt.Value{ .number = @floatFromInt(i + 11) };
        try left.rawSet(ctx.allocator, key, value);
        try right.rawSet(ctx.allocator, key, value);
    }
    const extra = [_]rt.Value{ .{ .number = 99 }, .{ .number = 1.5 }, .{ .number = -1 }, .{ .string = "overflow" }, .{ .boolean = false } };
    for (extra) |key| {
        try left.rawSet(ctx.allocator, key, .{ .number = 88 });
        try right.rawSet(ctx.allocator, key, .{ .number = 88 });
    }
    for (keys) |key| try std.testing.expect(rt.rawEqual(left.rawGet(key).?, right.rawGet(key).?));
    for (extra) |key| try std.testing.expect(rt.rawEqual(left.rawGet(key).?, right.rawGet(key).?));
    try std.testing.expectEqual(left.rawLen(), right.rawLen());
    const deleted = keys[0];
    try left.rawSet(ctx.allocator, deleted, .nil);
    try right.rawSet(ctx.allocator, deleted, .nil);
    try std.testing.expect(left.rawGet(deleted) == null and right.rawGet(deleted) == null);
    try std.testing.expectEqual(left.rawLen(), right.rawLen());
    var li = left.iterator();
    var ri = right.iterator();
    while (li.next()) |l| {
        const r = ri.next() orelse return error.MissingIterationEntry;
        try std.testing.expect(rt.rawEqual(l.key_ptr.*, r.key_ptr.*));
        try std.testing.expect(rt.rawEqual(l.value_ptr.*, r.value_ptr.*));
    }
    try std.testing.expect(ri.next() == null);
    const inherited = try ctx.newTable();
    try inherited.rawSet(ctx.allocator, deleted, .{ .number = 77 });
    const meta = try ctx.newTable();
    try meta.rawSet(ctx.allocator, .{ .string = "__index" }, .{ .table = inherited });
    left.metatable = meta;
    right.metatable = meta;
    try std.testing.expect(rt.rawEqual(try ctx.getIndex(.{ .table = left }, deleted), try ctx.getIndex(.{ .table = right }, deleted)));
    try std.testing.expectEqual(@as(f64, 77), (try ctx.getIndex(.{ .table = right }, deleted)).number);
    try left.rawSet(ctx.allocator, deleted, .{ .number = 42 });
    try right.rawSet(ctx.allocator, deleted, .{ .number = 42 });
    try std.testing.expectEqual(left.rawLen(), right.rawLen());
    left.read_only = true;
    right.read_only = true;
    try std.testing.expectError(error.ReadOnlyTable, left.rawSet(ctx.allocator, deleted, .nil));
    try std.testing.expectError(error.ReadOnlyTable, right.rawSet(ctx.allocator, deleted, .nil));
}

test "boxed string-slice and dense shapes preserve mutation iteration holes and metatables" {
    try differential(&.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } }, &.{});
    try differential(&.{ .{ .string = "a" }, .{ .string = "a" }, .{ .string = "z" }, .{ .boolean = true }, .{ .number = -0.0 } }, &.{ 0, 2 });
    try differential(&.{ .{ .string = "a" }, .{ .string = "a" }, .{ .string = "z" } }, &.{0});
    try differential(&.{ .{ .number = 2 }, .{ .number = 1 }, .{ .number = std.math.inf(f64) } }, &.{});
}

fn allocationCase(a: std.mem.Allocator, fallback: bool) !void {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer w.deinit();
    if (fallback) {
        try writeShape(&w.writer, &.{ .{ .string = "one" }, .{ .number = 3 }, .{ .boolean = true } }, &.{0});
    } else try writeShape(&w.writer, &.{ .{ .string = "one" }, .{ .string = "one" }, .{ .string = "z" } }, &.{0});
    var reader = metadata.Reader{ .bytes = w.written() };
    const storage = try load(a, &reader, 1, 3);
    defer storage.deinit(a);
    const indices = try rt.buildShapeStringIndices(a, storage.shapes);
    defer a.free(indices);
    try std.testing.expectEqual(@as(u32, 0), rt.shapeStringSlot(&storage.shapes[0], "one").?);
}

test "shape slab and lookup allocation failures release all unpublished storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{true});
}

test "manual string shapes reject inconsistent key counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const names = [_][]const u8{"x"};
    var shape = rt.Shape{ .keys = .{ .strings = &names }, .field_count = 1 };
    _ = try ctx.newShapedTable(&shape);
    shape.field_count = 2;
    try std.testing.expectError(error.BadShape, ctx.newShapedTable(&shape));
}

test "non-dense numeric shapes keep constant-time indexed string misses" {
    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer w.deinit();
    try writeShape(&w.writer, &.{ .{ .number = 2 }, .{ .number = 1 } }, &.{});
    var reader = metadata.Reader{ .bytes = w.written() };
    const storage = try load(std.testing.allocator, &reader, 1, 2);
    defer storage.deinit(std.testing.allocator);
    const slots = try rt.buildShapeStringIndices(std.testing.allocator, storage.shapes);
    defer std.testing.allocator.free(slots);
    try std.testing.expectEqual(@as(usize, 1), storage.shapes[0].string_lookup_slots.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.initProgram(arena.allocator(), 0, 0);
    defer ctx.deinit();
    const table = try ctx.newShapedTable(&storage.shapes[0]);
    try std.testing.expect(table.rawGet(.{ .string = "absent" }) == null);
}
