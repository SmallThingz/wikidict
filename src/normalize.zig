const std = @import("std");

pub fn normalizeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    _ = try normalizeToList(&list, allocator, input);
    return list.toOwnedSlice(allocator);
}

pub fn normalizeToList(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    list.items.len = 0;
    var pending_space = false;

    for (input) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n', '_' => {
                pending_space = true;
            },
            else => {
                if (pending_space and list.items.len != 0) {
                    try list.append(allocator, ' ');
                }
                pending_space = false;
                if (c < 128) {
                    try list.append(allocator, std.ascii.toLower(c));
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }

    while (list.items.len > 0 and list.items[list.items.len - 1] == ' ') {
        list.items.len -= 1;
    }
    return list.items;
}

test "normalize collapses whitespace and lowercases ascii" {
    const got = try normalizeAlloc(std.testing.allocator, "  CoL_or\tStorm  ");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("col or storm", got);
}
