const std = @import("std");
const rt = @import("zig_runtime");
const Value = rt.Value;
const Core = @import("format_core.zig").Formatter(rt);
pub const format = Core.format;

test "AOT Lua string.format core conversions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_]Value{
        .{ .string = "%s:%02d:%#.2x" },
        .{ .string = "n" },
        .{ .number = 7 },
        .{ .number = 31 },
    };
    try std.testing.expectEqualStrings("n:07:0x1f", try format(arena.allocator(), &args));
}
