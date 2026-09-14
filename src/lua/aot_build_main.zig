const std = @import("std");
const implementation = @import("aot/build.zig");

pub fn main(init: std.process.Init) !void {
    return implementation.main(init);
}
