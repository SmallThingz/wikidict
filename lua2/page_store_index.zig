const std = @import("std");

pub const magic = "DWPI0001";
pub const header_len: usize = 16;
pub const entry_len: usize = 16;

pub const Entry = struct {
    hash: u64,
    page_offset: u64,
};

pub fn titleHash(title: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (title) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}

pub fn count(bytes: []const u8) !usize {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..8], magic)) return error.BadPageIndex;
    const n = std.mem.readInt(u64, bytes[8..16], .little);
    if (n > std.math.maxInt(usize)) return error.BadPageIndex;
    const needed = std.math.add(usize, header_len, std.math.mul(usize, @intCast(n), entry_len) catch return error.BadPageIndex) catch return error.BadPageIndex;
    if (needed != bytes.len) return error.BadPageIndex;
    return @intCast(n);
}

pub fn entryAt(bytes: []const u8, index: usize) Entry {
    const off = header_len + index * entry_len;
    return .{
        .hash = std.mem.readInt(u64, bytes[off..][0..8], .little),
        .page_offset = std.mem.readInt(u64, bytes[off + 8 ..][0..8], .little),
    };
}

test "page index format hash and entry" {
    try std.testing.expectEqual(@as(u64, 0xa430d84680aabd0b), titleHash("hello"));
}
