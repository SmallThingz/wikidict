const std = @import("std");

const encoder = @import("encoder");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        printUsage();
        return;
    }

    const offset: usize = if (args.len >= 2 and std.mem.eql(u8, args[1], "build")) 2 else 1;
    try cmdBuild(init.io, allocator, args[offset..]);
}

fn cmdBuild(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const input = flagValue(args, "--input") orelse "enwiktionary.xml";
    const output = flagValue(args, "--output") orelse "data/enwiktionary.bin";
    const limit = if (flagValue(args, "--limit")) |value| try std.fmt.parseInt(usize, value, 10) else null;

    const stats = try encoder.buildDictionary(io, allocator, .{
        .input_path = input,
        .output_path = output,
        .limit_entries = limit,
    });

    std.debug.print(
        "built {s}\npages={d}\nns0={d}\nentries={d}\nredirect_aliases={d}\n",
        .{ output, stats.pages_seen, stats.namespace_zero_pages, stats.english_entries, stats.redirect_aliases },
    );
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn printUsage() void {
    std.debug.print(
        \\dict-encoder [build] --input enwiktionary.xml --output data/enwiktionary.bin [--limit 10000]
        \\
    , .{});
}
