const std = @import("std");

// Stable native environment layout. Names are compiler/reflection metadata,
// never keys for a statically bound load or store. Append, never reorder.
pub const names = [_][]const u8{
    "_G",           "type",         "assert",   "error",    "rawequal", "rawget", "rawset",
    "getmetatable", "setmetatable", "tostring", "tonumber", "select",   "unpack", "next",
    "pairs",        "ipairs",       "pcall",    "table",    "string",   "math",   "debug",
    "package",      "require",      "mw",
};
pub const count: u32 = names.len;
pub const native_shape: u32 = std.math.maxInt(u32) - 1;
pub fn find(name: []const u8) ?u32 {
    for (names, 0..) |text, index| if (std.mem.eql(u8, name, text)) return @intCast(index);
    return null;
}
pub fn id(comptime name: []const u8) u32 {
    return comptime find(name) orelse @compileError("Unknown native global: " ++ name);
}
test "native binding IDs have one stable spelling" {
    try std.testing.expectEqual(@as(u32, 0), id("_G"));
    for (names, 0..) |text, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), find(text).?);
    }
}
