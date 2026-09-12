//! Coordinated build. VM bytecode remains as an oracle while production gets a dump-specific native worker.
const std = @import("std");
const paths = @import("pipeline_paths");

fn stage(io: std.Io, marker: []const u8, name: []const u8, argv: []const []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = name });
    std.debug.print("dictionary build: {s}\n", .{name});
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("dictionary build failed at {s}; incomplete marker retained\n", .{name});
        return error.PipelineStageFailed;
    }
}

fn sourcePath(a: std.mem.Allocator, relative: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ paths.project_root, relative });
}

fn publishAotData(io: std.Io, a: std.mem.Allocator, aot_dir: []const u8, publish_root: []const u8) !void {
    const source = try std.fs.path.join(a, &.{ aot_dir, "aot-data.bin" });
    const destination = try std.fs.path.join(a, &.{ publish_root, "aot-data.bin" });
    try std.Io.Dir.cwd().rename(source, std.Io.Dir.cwd(), destination, io);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

const ObjectCompileJob = struct {
    child: std.process.Child,
    index: usize,
};

fn waitObjectCompile(io: std.Io, job: *?ObjectCompileJob) !void {
    if (job.*) |*active| {
        const term = try active.child.wait(io);
        const index = active.index;
        job.* = null;
        if (term != .exited or term.exited != 0) {
            std.debug.print("dictionary build failed compiling native AOT function shard {d}; incomplete marker retained\n", .{index});
            return error.PipelineStageFailed;
        }
    }
}

fn compileFunctionObjects(io: std.Io, a: std.mem.Allocator, marker: []const u8, aot_dir: []const u8) !std.ArrayList([]const u8) {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "compile native AOT function shards" });
    var objects: std.ArrayList([]const u8) = .empty;
    var jobs: [2]?ObjectCompileJob = .{ null, null };
    errdefer for (&jobs) |*job| if (job.*) |*active| active.child.kill(io);
    var index: usize = 0;
    while (true) : (index += 1) {
        const source = try std.fmt.allocPrint(a, "{s}/functions_{d:0>4}.zig", .{ aot_dir, index });
        if (!try fileExists(io, source)) break;
        const object = try std.fmt.allocPrint(a, "{s}/functions_{d:0>4}.o", .{ aot_dir, index });
        try objects.append(a, object);
        const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{object});
        const root_module = try std.fmt.allocPrint(a, "-Mroot={s}", .{source});
        const zig_runtime = try sourcePath(a, "lua2/zig_runtime.zig");
        const runtime_module = try std.fmt.allocPrint(a, "-Mzig_runtime={s}", .{zig_runtime});
        const slot = index % jobs.len;
        try waitObjectCompile(io, &jobs[slot]);
        std.debug.print("dictionary build: compile native AOT function shard {d}\n", .{index});
        const argv = &.{
            paths.zig,      "build-obj", "-OReleaseFast", "-fno-llvm",
            emit,           "--dep",     "zig_runtime",   root_module,
            runtime_module,
        };
        jobs[slot] = .{ .child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore }), .index = index };
    }
    if (objects.items.len == 0) return error.MissingAotFunctionShards;
    for (&jobs) |*job| try waitObjectCompile(io, job);
    return objects;
}

fn compileNativeWorker(io: std.Io, a: std.mem.Allocator, marker: []const u8, publish_root: []const u8, aot_dir: []const u8) !void {
    const objects = try compileFunctionObjects(io, a, marker, aot_dir);
    const worker_core = try sourcePath(a, "frontend/native_expansion_worker_core.zig");
    const worker_link = try sourcePath(a, "frontend/native_expansion_worker_link.zig");
    const generated = try std.fs.path.join(a, &.{ aot_dir, "root.zig" });
    const zig_runtime = try sourcePath(a, "lua2/zig_runtime.zig");
    const zig_stdlib = try sourcePath(a, "lua2/zig_stdlib.zig");
    const zig_scribunto = try sourcePath(a, "lua2/zig_scribunto.zig");
    const zig_module_registry = try sourcePath(a, "lua2/zig_module_registry.zig");
    const blob_encoder = try sourcePath(a, "encoder/blob_root.zig");
    const blob_decoder = try sourcePath(a, "decoder/blob_root.zig");
    const blob_files = try sourcePath(a, "encoder/blob_files.zig");
    const blob_storage = try sourcePath(a, "native/storage.zig");

    const core_object = try std.fs.path.join(a, &.{ aot_dir, "native-expansion-worker-core.o" });
    const core_emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{core_object});
    const core_root_module = try std.fmt.allocPrint(a, "-Mroot={s}", .{worker_core});
    const generated_module = try std.fmt.allocPrint(a, "-Mgenerated={s}", .{generated});
    const runtime_module = try std.fmt.allocPrint(a, "-Mzig_runtime={s}", .{zig_runtime});
    const stdlib_module = try std.fmt.allocPrint(a, "-Mzig_stdlib={s}", .{zig_stdlib});
    const scribunto_module = try std.fmt.allocPrint(a, "-Mzig_scribunto={s}", .{zig_scribunto});
    const registry_module = try std.fmt.allocPrint(a, "-Mzig_module_registry={s}", .{zig_module_registry});
    const encoder_module = try std.fmt.allocPrint(a, "-Mblob_encoder={s}", .{blob_encoder});
    const decoder_module = try std.fmt.allocPrint(a, "-Mblob_decoder={s}", .{blob_decoder});
    const files_module = try std.fmt.allocPrint(a, "-Mblob_files={s}", .{blob_files});
    const storage_module = try std.fmt.allocPrint(a, "-Mblob_storage={s}", .{blob_storage});

    var core_argv: std.ArrayList([]const u8) = .empty;
    try core_argv.appendSlice(a, &.{ paths.zig, "build-obj", "-OReleaseFast", "-fno-llvm", "-lc", "-I/usr/include", core_emit });
    try core_argv.appendSlice(a, objects.items);
    try core_argv.appendSlice(a, &.{
        "--dep",          "generated",    "--dep",       "blob_encoder", "--dep",      "blob_decoder", "--dep",          "blob_files", "--dep",               "blob_storage",   "--dep",        "zig_runtime",
        core_root_module, "--dep",        "zig_runtime", "--dep",        "zig_stdlib", "--dep",        "zig_scribunto",  "--dep",      "zig_module_registry", generated_module, runtime_module, "--dep",
        "zig_runtime",    stdlib_module,  "--dep",       "zig_runtime",  "--dep",      "zig_stdlib",   scribunto_module, "--dep",      "zig_runtime",         registry_module,  encoder_module, "--dep",
        "blob_encoder",   decoder_module, "--dep",       "blob_encoder", "--dep",      "blob_storage", files_module,     "--dep",      "blob_encoder",        storage_module,
    });
    try stage(io, marker, "compile native AOT worker core", core_argv.items);

    const output = try std.fs.path.join(a, &.{ publish_root, "dict-native-expansion-worker" });
    const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{output});
    const link_root_module = try std.fmt.allocPrint(a, "-Mroot={s}", .{worker_link});
    try stage(io, marker, "link native AOT worker", &.{
        paths.zig, "build-exe",                    "-OReleaseFast", "-fllvm",    "-flld",          "-fstrip", "-lc", "-I/usr/include",
        "--name",  "dict-native-expansion-worker", emit,            core_object, link_root_module,
    });
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
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
    const runtime = if (full) try std.fs.path.join(a, &.{ root, "runtime" }) else root;
    if (full) try std.Io.Dir.cwd().createDir(init.io, runtime, .default_dir);
    const runtime_marker = try std.fs.path.join(a, &.{ runtime, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = runtime_marker, .data = "building" });

    try stage(init.io, marker, "extract modules", &.{ paths.modules, dump, runtime });
    try stage(init.io, marker, "extract templates", &.{ paths.templates, dump, runtime });
    try stage(init.io, marker, "extract module redirects", &.{ paths.redirects, dump, runtime });
    try stage(init.io, marker, "extract auxiliary source pages", &.{ paths.pages, dump, runtime });
    const manifest = try std.fs.path.join(a, &.{ runtime, "manifest.jsonl" });
    const modules = try std.fs.path.join(a, &.{ runtime, "modules" });
    const bundle = try std.fs.path.join(a, &.{ runtime, "modules.bundle" });
    try stage(init.io, marker, "compile bytecode oracle", &.{ paths.bytecode, manifest, modules, bundle });

    const aot_dir = try std.fs.path.join(a, &.{ runtime, "aot" });
    try std.Io.Dir.cwd().createDirPath(init.io, aot_dir);
    try stage(init.io, marker, "generate native AOT", &.{ paths.aot, manifest, runtime, aot_dir, "--sharded", "--external-data", "--external-functions" });

    if (full)
        try stage(init.io, marker, "encode dictionary blobs", &.{ paths.blobs, dump, root })
    else
        try stage(init.io, marker, "link shared symbols and bytecode", &.{ paths.linker, root, runtime });

    const publish_root = if (full) root else runtime;
    try publishAotData(init.io, a, aot_dir, publish_root);
    try compileNativeWorker(init.io, a, marker, publish_root, aot_dir);
    // Generated Zig and native shard objects are build-only. Keep them on failure for diagnosis,
    // but never retain them in a completed runtime.
    try std.Io.Dir.cwd().deleteTree(init.io, aot_dir);
    try std.Io.Dir.cwd().deleteFile(init.io, runtime_marker);
    if (full) try std.Io.Dir.cwd().deleteFile(init.io, marker);
    std.debug.print("dictionary build complete: {s}\n", .{root});
}
