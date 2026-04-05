const std = @import("std");

const required_path = @import("required_path.zig");
const support = @import("structure_tables_support.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        std.debug.print(
            \\dict-structure-tables-codegen --input data/wiktionary-structure.json --output structure_tables.zig
            \\
        , .{});
        return;
    }

    const input_path = flagValue(args[1..], "--input") orelse return error.InvalidArgument;
    const output_path = flagValue(args[1..], "--output") orelse return error.InvalidArgument;
    required_path.ensureExistsOrExit(init.io, input_path, "structure report");

    const json_bytes = try readFileAlloc(allocator, init.io, input_path, 64 * 1024 * 1024);
    defer allocator.free(json_bytes);

    const source = try support.generateStructureTableSourceFromExactJsonAlloc(allocator, input_path, json_bytes);
    defer allocator.free(source);

    var file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{ .truncate = true });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, source, 0);
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > max_bytes) return error.FileTooBig;

    const out = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(out);

    const read_len = try file.readPositionalAll(io, out, 0);
    if (read_len == out.len) return out;

    const shrunk = try allocator.dupe(u8, out[0..read_len]);
    allocator.free(out);
    return shrunk;
}
