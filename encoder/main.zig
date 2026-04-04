const std = @import("std");

const encoder = @import("encoder");
const cli_args = @import("cli_args");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        std.debug.print(
            \\dict-encoder [build] --input enwiktionary.xml --output data/enwiktionary.bin [--limit 10000]
            \\
        , .{});
        return;
    }

    const offset: usize = if (args.len >= 2 and std.mem.eql(u8, args[1], "build")) 2 else 1;
    const cmd_args = args[offset..];
    const input = cli_args.flagValue(cmd_args, "--input") orelse "enwiktionary.xml";
    const output = cli_args.flagValue(cmd_args, "--output") orelse "data/enwiktionary.bin";
    const limit = try cli_args.parseOptionalIntFlag(usize, cmd_args, "--limit");

    const stats = try encoder.buildDictionary(init.io, allocator, .{
        .input_path = input,
        .output_path = output,
        .limit_entries = limit,
    });

    std.debug.print(
        "built {s}\npages={d}\nns0={d}\nentries={d}\nredirect_aliases={d}\n",
        .{ output, stats.pages_seen, stats.namespace_zero_pages, stats.english_entries, stats.redirect_aliases },
    );
}
