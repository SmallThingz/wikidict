pub const ServeOptions = @import("server.zig").ServeOptions;

pub fn serveDictionary(io: @import("std").Io, allocator: @import("std").mem.Allocator, args: []const []const u8) !void {
    return @import("server.zig").serve(io, allocator, args);
}

test "backend module compiles" {
    _ = ServeOptions;
    _ = @import("renderer").html_render;
}
