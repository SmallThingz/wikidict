//! Coordinated build, not a second encoder/compiler. Every stage consumes existing APIs.
const std = @import("std");
const paths = @import("pipeline_paths");
fn stage(io: std.Io, a: std.mem.Allocator, marker: []const u8, name: []const u8, argv: []const []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = name });
    std.debug.print("dictionary build: {s}\n", .{name});
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        _ = a;
        std.debug.print("dictionary build failed at {s}; incomplete marker retained\n", .{name});
        return error.PipelineStageFailed;
    }
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const full = argv.len > 1 and std.mem.eql(u8, argv[1], "--with-blobs");
    const args = argv[if (full) @as(usize, 2) else 1..];
    if (args.len != 2) {
        std.debug.print("usage: build-runtime|build-dictionary -- DUMP NEW_OUTPUT_DIRECTORY\n", .{});
        return error.Usage;
    }
    const dump = args[0];
    const root = args[1];
    if (root.len == 0 or dump.len == 0) return error.Usage;
    if (std.fs.path.dirname(root)) |parent| if (parent.len != 0) try std.Io.Dir.cwd().createDirPath(init.io, parent);
    // Refuse existing outputs, including incomplete ones. Never overwrite shared corpus assets.
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
    const runtime = if (full) try std.fs.path.join(a, &.{ root, "runtime" }) else root;
    if (full) try std.Io.Dir.cwd().createDir(init.io, runtime, .default_dir);
    const runtime_marker = try std.fs.path.join(a, &.{ runtime, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = runtime_marker, .data = "building" });
    try stage(init.io, a, marker, "extract modules", &.{ paths.modules, dump, runtime });
    try stage(init.io, a, marker, "extract templates", &.{ paths.templates, dump, runtime });
    try stage(init.io, a, marker, "extract module redirects", &.{ paths.redirects, dump, runtime });
    try stage(init.io, a, marker, "extract auxiliary source pages", &.{ paths.pages, dump, runtime });
    const manifest = try std.fs.path.join(a, &.{ runtime, "manifest.jsonl" });
    const modules = try std.fs.path.join(a, &.{ runtime, "modules" });
    const bundle = try std.fs.path.join(a, &.{ runtime, "modules.bundle" });
    try stage(init.io, a, marker, "compile bytecode", &.{ paths.bytecode, manifest, modules, bundle });
    if (full) try stage(init.io, a, marker, "encode dictionary blobs", &.{ paths.blobs, dump, root }) else try stage(init.io, a, marker, "link shared symbols and bytecode", &.{ paths.linker, root, runtime });
    try std.Io.Dir.cwd().deleteFile(init.io, runtime_marker);
    if (full) try std.Io.Dir.cwd().deleteFile(init.io, marker);
    std.debug.print("dictionary build complete: {s}\n", .{root});
}
