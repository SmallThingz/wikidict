const std = @import("std");

/// Build a name-sorted permutation without moving native global slots.
/// Duplicate names retain the original linear first-slot lookup behavior.
/// The caller owns the returned slice; duplicate input returns an empty slice.
pub fn build(allocator: std.mem.Allocator, keys: anytype) ![]u32 {
    if (keys.len > std.math.maxInt(u32)) return error.ProgramMetadataTooLarge;
    const slots = try allocator.alloc(u32, keys.len);
    errdefer allocator.free(slots);
    for (slots, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u32, slots, keys, struct {
        fn lessThan(names: @TypeOf(keys), lhs: u32, rhs: u32) bool {
            return std.mem.order(u8, names[lhs].string, names[rhs].string) == .lt;
        }
    }.lessThan);
    if (slots.len > 1) {
        for (slots[1..], slots[0 .. slots.len - 1]) |slot, previous| {
            if (std.mem.eql(u8, keys[slot].string, keys[previous].string)) {
                allocator.free(slots);
                return &.{};
            }
        }
    }
    return slots;
}

const TestKey = union(enum) { string: []const u8, nil };

test "global index sorts a permutation without changing slot order" {
    const keys = [_]TestKey{
        .{ .string = "_G" },     .{ .string = "zebra" }, .{ .string = "alpha" },
        .{ .string = "middle" }, .{ .string = "" },      .{ .string = "alpha2" },
    };
    const slots = try build(std.testing.allocator, keys[0..]);
    defer std.testing.allocator.free(slots);
    try std.testing.expectEqualSlices(u32, &.{ 4, 0, 2, 5, 3, 1 }, slots);
    try std.testing.expectEqualStrings("_G", keys[0].string);
    try std.testing.expectEqualStrings("zebra", keys[1].string);
}

test "global index keeps native ABI keys and high slots intact" {
    const abi = @import("lua_globals");
    var keys: [abi.names.len + 3]TestKey = undefined;
    for (abi.names, 0..) |name, slot| keys[slot] = .{ .string = name };
    keys[abi.names.len] = .{ .string = "z_global" };
    keys[abi.names.len + 1] = .{ .string = "a_global" };
    keys[abi.names.len + 2] = .{ .string = "A_global" };
    const slots = try build(std.testing.allocator, keys[0..]);
    defer std.testing.allocator.free(slots);
    var seen = [_]bool{false} ** keys.len;
    for (slots, 0..) |slot, index| {
        try std.testing.expect(slot < keys.len and !seen[slot]);
        seen[slot] = true;
        if (index != 0)
            try std.testing.expect(std.mem.order(u8, keys[slots[index - 1]].string, keys[slot].string) == .lt);
    }
    for (seen) |value| try std.testing.expect(value);
    for (abi.names, 0..) |name, slot| try std.testing.expectEqualStrings(name, keys[slot].string);
}

test "duplicate global names discard index and preserve linear fallback" {
    const keys = [_]TestKey{
        .{ .string = "z" }, .{ .string = "duplicate" },
        .{ .string = "a" }, .{ .string = "duplicate" },
    };
    const slots = try build(std.testing.allocator, keys[0..]);
    defer std.testing.allocator.free(slots);
    try std.testing.expectEqual(@as(usize, 0), slots.len);
    // Production Table.slotForKey uses the original field-key order when empty.
    const first = for (keys, 0..) |key, slot| {
        if (std.mem.eql(u8, key.string, "duplicate")) break slot;
    } else return error.MissingDuplicate;
    try std.testing.expectEqual(@as(usize, 1), first);
}

test "global index handles empty singleton and case-distinct keys" {
    const empty = try build(std.testing.allocator, @as([]const TestKey, &.{}));
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const one = [_]TestKey{.{ .string = "only" }};
    const single = try build(std.testing.allocator, one[0..]);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualSlices(u32, &.{0}, single);
    const keys = [_]TestKey{ .{ .string = "a" }, .{ .string = "A" } };
    const distinct = try build(std.testing.allocator, keys[0..]);
    defer std.testing.allocator.free(distinct);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, distinct);
}

fn allocationCase(allocator: std.mem.Allocator, duplicate: bool) !void {
    const keys = [_]TestKey{
        .{ .string = "z" }, .{ .string = if (duplicate) "z" else "a" },
    };
    const slots = try build(allocator, keys[0..]);
    defer allocator.free(slots);
    if (duplicate) {
        try std.testing.expectEqual(@as(usize, 0), slots.len);
    } else {
        try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, slots);
    }
}

test "global index cleans up allocations on unique and duplicate inputs" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{true});
}
