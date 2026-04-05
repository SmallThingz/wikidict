const std = @import("std");

const encoder = @import("encoder");
const cli_args = @import("cli_args");
const required_path = @import("required_path");
const tool_paths = @import("tool_paths");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        try printStdOut(init.io, allocator,
            \\dict-encoder [build] --input data/wiktionary.xml --output data/wiktionary.bin [--limit 10000] [--threads 4]
            \\
        , .{});
        return;
    }

    const offset: usize = if (args.len >= 2 and std.mem.eql(u8, args[1], "build")) 2 else 1;
    const cmd_args = args[offset..];
    const input = cli_args.flagValue(cmd_args, "--input") orelse "data/wiktionary.xml";
    const output = cli_args.flagValue(cmd_args, "--output") orelse "data/wiktionary.bin";
    const limit = try cli_args.parseOptionalIntFlag(usize, cmd_args, "--limit");
    const worker_threads = try cli_args.parseOptionalIntFlag(usize, cmd_args, "--threads");
    ensureFileExistsOrExit(init.io, input, "encoder input");
    ensureStructureReportExists(init.io, allocator, input);

    const stats = try encoder.buildDictionary(init.io, allocator, .{
        .input_path = input,
        .output_path = output,
        .limit_entries = limit,
        .worker_threads = worker_threads,
    });

    try printStdOut(
        init.io,
        allocator,
        "built {s}\npages={d}\nns0={d}\nentries={d}\nredirect_aliases={d}\n",
        .{ output, stats.pages_seen, stats.namespace_zero_pages, stats.english_entries, stats.redirect_aliases },
    );
}

fn printStdOut(io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn ensureStructureReportExists(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8) void {
    const structure_path = "data/wiktionary-structure.json";
    const found = required_path.exists(io, structure_path) catch |err| {
        std.debug.print("failed to access structure report at {s}: {s}\n", .{ structure_path, @errorName(err) });
        std.process.exit(1);
    };
    if (found) return;

    std.debug.print("structure report not found: {s}; running {s}\n", .{ structure_path, tool_paths.structure_bin_path });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "--input") catch unreachable;
    argv.append(allocator, input_path) catch unreachable;
    argv.append(allocator, "--output") catch unreachable;
    argv.append(allocator, structure_path) catch unreachable;
    required_path.runToolOrExit(io, allocator, tool_paths.structure_bin_path, "structure binary", argv.items);
}

fn ensureFileExistsOrExit(io: std.Io, path: []const u8, label: []const u8) void {
    required_path.ensureExistsOrExit(io, path, label);
}
