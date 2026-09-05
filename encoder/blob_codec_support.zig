const std = @import("std");
const format = @import("format.zig");

pub const trailing_newline_flag: u8 = 1 << 0;

pub fn appendField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEncoding;
    try out.appendSlice(allocator, value);
    try out.append(allocator, 0);
}

pub fn appendVarUInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var buf: [10]u8 = undefined;
    try out.appendSlice(allocator, format.encodeVarUInt(&buf, value));
}

pub fn readVarUInt(bytes: []const u8, cursor: *usize) error{InvalidEncoding}!usize {
    const value = format.readVarUInt(bytes, cursor, bytes.len) catch return error.InvalidEncoding;
    return std.math.cast(usize, value) orelse return error.InvalidEncoding;
}

pub fn readField(bytes: []const u8, cursor: *usize) error{InvalidEncoding}![]const u8 {
    if (cursor.* > bytes.len) return error.InvalidEncoding;
    const end = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidEncoding;
    const field = bytes[cursor.*..end];
    cursor.* = end + 1;
    return field;
}

pub fn appendFieldTo(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) (std.mem.Allocator.Error || error{InvalidEncoding})!void {
    try out.appendSlice(allocator, try readField(bytes, cursor));
}

pub fn findBalancedTemplateEnd(input: []const u8, start: usize) ?usize {
    if (start + 2 > input.len or !std.mem.eql(u8, input[start .. start + 2], "{{")) return null;
    var depth: usize = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            depth += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
            i += 1;
        }
    }
    return null;
}

test "blob fields are borrowed nul-terminated utf8" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const source = "{{l|en|light}} tail";
    try appendField(&out, std.testing.allocator, source);

    var cursor: usize = 0;
    const decoded = try readField(out.items, &cursor);
    try std.testing.expectEqualStrings(source, decoded);
    try std.testing.expectEqual(out.items.len, cursor);
}
