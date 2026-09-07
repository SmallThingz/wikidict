const std = @import("std");
const rt = @import("vm_runtime.zig");
const Value = rt.Value;
const Core = @import("lua_format_core.zig").Formatter(rt);
pub const format = Core.format;

fn expectFormat(expected: []const u8, fmt: []const u8, args: []const Value) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all = try arena.allocator().alloc(Value, args.len + 1);
    all[0] = .{ .string = fmt };
    @memcpy(all[1..], args);
    try std.testing.expectEqualStrings(expected, try format(arena.allocator(), all));
}
test "Lua string.format core conversions" {
    try expectFormat("x 12 0x1f 00007 1.23 1.234e+03 1234 %", "%s %d %#x %05d %.2f %.3e %.4g %%", &.{
        .{ .string = "x" },   .{ .number = 12 },     .{ .number = 31 },     .{ .number = 7 },
        .{ .number = 1.234 }, .{ .number = 1234.5 }, .{ .number = 1234.5 },
    });
    try expectFormat("   +1.50", "%+8.2f", &.{.{ .number = 1.5 }});
    try expectFormat("x    !", "%-5s!", &.{.{ .string = "x" }});
}
