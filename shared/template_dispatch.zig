const std = @import("std");

pub const marker_prefix: u8 = 0x1e;
pub const marker_suffix: u8 = 0x1f;
pub const marker_len: usize = 4;

pub fn appendDispatchMarker(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    dispatch_id: u16,
) !void {
    try out.append(allocator, marker_prefix);
    try out.append(allocator, @intCast(dispatch_id & 0xff));
    try out.append(allocator, @intCast(dispatch_id >> 8));
    try out.append(allocator, marker_suffix);
}

pub fn dispatchIdFromName(name: []const u8) ?u16 {
    if (name.len != marker_len) return null;
    if (name[0] != marker_prefix or name[3] != marker_suffix) return null;
    return std.mem.readInt(u16, name[1..3], .little);
}

test "dispatchIdFromName round trips marker bytes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendDispatchMarker(&out, std.testing.allocator, 0x3412);
    try std.testing.expectEqual(@as(?u16, 0x3412), dispatchIdFromName(out.items));
}
