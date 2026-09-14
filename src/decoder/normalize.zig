const std = @import("std");

pub fn normalizeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    _ = try normalizeToList(&list, allocator, input);
    return list.toOwnedSlice(allocator);
}

pub fn isIdentity(input: []const u8) bool {
    var saw_any = false;
    var previous_space = false;

    for (input) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n', '_' => {
                if (c != ' ') return false;
                if (!saw_any or previous_space) return false;
                previous_space = true;
            },
            else => {
                if (c < 128 and std.ascii.isUpper(c)) return false;
                saw_any = true;
                previous_space = false;
            },
        }
    }

    return !previous_space;
}

pub fn normalizeToList(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    list.items.len = 0;
    try list.ensureTotalCapacity(allocator, input.len);
    var pending_space = false;

    for (input) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n', '_' => {
                pending_space = true;
            },
            else => {
                if (pending_space and list.items.len != 0) {
                    list.appendAssumeCapacity(' ');
                }
                pending_space = false;
                if (c < 128) {
                    list.appendAssumeCapacity(std.ascii.toLower(c));
                } else {
                    list.appendAssumeCapacity(c);
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

test "isIdentity recognizes already normalized keys" {
    try std.testing.expect(isIdentity(""));
    try std.testing.expect(isIdentity("color"));
    try std.testing.expect(isIdentity("co lor"));
    try std.testing.expect(!isIdentity(" Color"));
    try std.testing.expect(!isIdentity("co  lor"));
    try std.testing.expect(!isIdentity("CoLor"));
    try std.testing.expect(!isIdentity("co_lor"));
    try std.testing.expect(!isIdentity("co\tlor"));
}
