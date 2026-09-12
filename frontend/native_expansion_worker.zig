const std = @import("std");
const core = @import("native_expansion_worker_core.zig");

pub const Request = core.Request;
pub const Reply = core.Reply;

pub fn main(init: std.process.Init) !void {
    return core.run(init.io, init.arena.allocator());
}
