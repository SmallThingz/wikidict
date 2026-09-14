const std = @import("std");
const implementation = @import("extract/templates.zig");

pub fn main(init: std.process.Init) !void {
    return implementation.main(init);
}
