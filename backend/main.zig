const std = @import("std");

const backend = @import("backend");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const offset: usize = if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) 2 else 1;
    try backend.serveDictionary(init.io, init.gpa, args[offset..]);
}
