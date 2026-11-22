const std = @import("std");
const implementation = @import("extract/modules.zig");

pub fn main(init: std.process.Init) !void {
    return implementation.main(init);
}
