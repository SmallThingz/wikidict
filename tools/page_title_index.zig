const std = @import("std");
const wikimedia_dump = @import("wikimedia_dump");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: dict-page-title-index <page-index.tsv> <page-title-index.bin>\n", .{});
        return error.Usage;
    }
    try wikimedia_dump.buildPageTitleIndex(init.io, std.heap.smp_allocator, args[1], args[2]);
}
