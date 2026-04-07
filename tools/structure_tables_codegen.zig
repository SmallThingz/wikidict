const std = @import("std");

const required_path = @import("required_path.zig");
const structure_report = @import("shared_structure_report");
const support = @import("structure_tables_support.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        std.debug.print(
            \\dict-structure-tables-codegen --input data/wiktionary-structure.bin --output structure_tables.zig
            \\
        , .{});
        return;
    }

    const input_path = flagValue(args[1..], "--input") orelse return error.InvalidArgument;
    const output_path = flagValue(args[1..], "--output") orelse return error.InvalidArgument;
    required_path.ensureExistsOrExit(init.io, input_path, "structure report");

    var build_data = try structure_report.loadBuildDataAlloc(init.io, allocator, input_path);
    defer build_data.deinit(allocator);

    const source = try support.generateStructureTableSourceAlloc(allocator, input_path, adaptBuildData(build_data));
    defer allocator.free(source);

    var file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{ .truncate = true });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, source, 0);
}

fn adaptBuildData(build_data: structure_report.BuildData) support.BuildData {
    return .{
        .compact_direct_patterns = build_data.compact_direct_patterns,
        .heading_specs = @ptrCast(build_data.heading_specs),
        .heading_level_specs = @ptrCast(build_data.heading_level_specs),
        .line_templates = @ptrCast(build_data.line_templates),
        .compact_patterns = build_data.compact_patterns,
        .compact_patterns_ext = build_data.compact_patterns_ext,
        .translation_templates = @ptrCast(build_data.translation_templates),
        .target_languages = @ptrCast(build_data.target_languages),
        .language_labels = @ptrCast(build_data.language_labels),
        .structure_fingerprint = build_data.structure_fingerprint,
    };
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}
