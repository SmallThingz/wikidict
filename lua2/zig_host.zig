const std = @import("std");
const rt = @import("zig_runtime");

pub const PageExistsFn = *const fn (?*anyopaque, []const u8) anyerror!bool;
pub const PageContentFn = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8;

pub const Host = struct {
    ctx: ?*anyopaque = null,
    current_title: []const u8 = "",
    page_exists: ?PageExistsFn = null,
    page_content: ?PageContentFn = null,
};

pub fn set(runtime: *rt.Context, host: ?*Host) void {
    runtime.setHost(if (host) |value| value else null);
}

pub fn get(runtime: *const rt.Context) ?*Host {
    return @ptrCast(@alignCast(runtime.host orelse return null));
}
