//! Coordinated build-time Lua/template expansion and data-only blob bundling.
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

fn fileExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}
const CompileJob = struct {
    child: std.process.Child,
    index: usize,
};

fn waitCompile(io: std.Io, job: *?CompileJob) !void {
    if (job.*) |*active| {
        const term = try active.child.wait(io);
        const index = active.index;
        job.* = null;
        if (term != .exited or term.exited != 0) {
            std.debug.print("dictionary build failed compiling LLVM module {d}; incomplete marker retained\n", .{index});
            return error.PipelineStageFailed;
        }
    }
}

fn compileLlModules(io: std.Io, a: std.mem.Allocator, marker: []const u8, llvm_dir: []const u8) !std.ArrayList([]const u8) {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "compile Lua LLVM modules" });
    var objects: std.ArrayList([]const u8) = .empty;
    var jobs: [2]?CompileJob = .{ null, null };
    errdefer for (&jobs) |*job| if (job.*) |*active| active.child.kill(io);
    var index: usize = 0;
    while (true) : (index += 1) {
        const source = try std.fmt.allocPrint(a, "{s}/module_{d:0>6}.ll", .{ llvm_dir, index });
        if (!try fileExists(io, source)) break;
        const object = try std.fmt.allocPrint(a, "{s}/module_{d:0>6}.o", .{ llvm_dir, index });
        try objects.append(a, object);
        const slot = index % jobs.len;
        try waitCompile(io, &jobs[slot]);
        std.debug.print("dictionary build: compile LLVM module {d}\n", .{index});
        jobs[slot] = .{
            .child = try std.process.spawn(io, .{
                .argv = &.{ paths.zig, "cc", "-O3", "-c", source, "-o", object },
                .stdin = .ignore,
            }),
            .index = index,
        };
    }
    if (objects.items.len == 0) return error.MissingLlvmModules;
    for (&jobs) |*job| try waitCompile(io, job);

    const program_source = try std.fs.path.join(a, &.{ llvm_dir, "program.ll" });
    const program_object = try std.fs.path.join(a, &.{ llvm_dir, "program.o" });
    try stage(io, marker, "compile LLVM program metadata", &.{
        paths.zig, "cc", "-O3", "-c", program_source, "-o", program_object,
    });
    try objects.append(a, program_object);
    return objects;
}
fn compileWorkerObject(io: std.Io, a: std.mem.Allocator, marker: []const u8, llvm_dir: []const u8) ![]const u8 {
    const worker_core = try sourcePath(a, "src/lua/bundle_worker.zig");
    const zig_runtime = try sourcePath(a, "src/lua/runtime/core.zig");
    const lua_program = try sourcePath(a, "src/lua/runtime/llvm_program.zig");
    const lua_llvm_abi = try sourcePath(a, "src/lua/runtime/llvm_abi.zig");
    const zig_stdlib = try sourcePath(a, "src/lua/runtime/stdlib.zig");
    const zig_scribunto = try sourcePath(a, "src/lua/runtime/scribunto.zig");
    const lua_static_fields = try sourcePath(a, "src/lua/abi/static_fields.zig");
    const lua_globals = try sourcePath(a, "src/lua/abi/globals.zig");
    const preprocess = try sourcePath(a, "src/lua/wikitext/preprocess.zig");
    const expression = try sourcePath(a, "src/lua/wikitext/expression.zig");
    const shared_xml_decode = try sourcePath(a, "src/shared/xml_decode.zig");
    const output = try std.fs.path.join(a, &.{ llvm_dir, "worker.o" });
    const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{output});
    const root = try std.fmt.allocPrint(a, "-Mroot={s}", .{worker_core});
    const runtime_mod = try std.fmt.allocPrint(a, "-Mzig_runtime={s}", .{zig_runtime});
    const program_mod = try std.fmt.allocPrint(a, "-Mlua_program={s}", .{lua_program});
    const llvm_abi_mod = try std.fmt.allocPrint(a, "-Mlua_llvm_abi={s}", .{lua_llvm_abi});
    const stdlib_mod = try std.fmt.allocPrint(a, "-Mzig_stdlib={s}", .{zig_stdlib});
    const scribunto_mod = try std.fmt.allocPrint(a, "-Mzig_scribunto={s}", .{zig_scribunto});
    const static_fields_mod = try std.fmt.allocPrint(a, "-Mlua_static_fields={s}", .{lua_static_fields});
    const globals_mod = try std.fmt.allocPrint(a, "-Mlua_globals={s}", .{lua_globals});
    const preprocess_mod = try std.fmt.allocPrint(a, "-Mlua_wikitext_preprocess={s}", .{preprocess});
    const expression_mod = try std.fmt.allocPrint(a, "-Mlua_wikitext_expression={s}", .{expression});
    const xml_decode_mod = try std.fmt.allocPrint(a, "-Mshared_xml_decode={s}", .{shared_xml_decode});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ paths.zig, "build-obj", "-OReleaseFast", "-fllvm", "-lc", emit });
    try argv.appendSlice(a, &.{ "--dep", "lua_program", "--dep", "lua_llvm_abi", "--dep", "shared_xml_decode", "--dep", "lua_wikitext_preprocess", root });
    try argv.appendSlice(a, &.{
        "--dep",                   "lua_static_fields",       runtime_mod,
        "--dep",                   "zig_runtime",             "--dep",
        "zig_stdlib",              "--dep",                   "zig_scribunto",
        "--dep",                   "lua_globals",             program_mod,
        "--dep",                   "zig_runtime",             llvm_abi_mod,
        "--dep",                   "zig_runtime",             "--dep",
        "lua_globals",             stdlib_mod,                "--dep",
        "zig_runtime",             "--dep",                   "zig_stdlib",
        "--dep",                   "lua_wikitext_preprocess", "--dep",
        "lua_wikitext_expression", "--dep",                   "shared_xml_decode",
        scribunto_mod,             static_fields_mod,         globals_mod,
        preprocess_mod,            expression_mod,            xml_decode_mod,
    });
    try stage(io, marker, "compile optimized build-only Lua worker object", argv.items);
    return output;
}

fn linkNativeWorker(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    main_c: []const u8,
    worker: []const u8,
    lua_objects: []const []const u8,
    output: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ paths.zig, "cc", "-O3", "-pthread", "-s", main_c, worker });
    try argv.appendSlice(a, lua_objects);
    try argv.appendSlice(a, &.{ "-lm", "-lc", "-o", output });
    try stage(io, marker, "link optimized native Lua worker", argv.items);
}

fn compileNativeWorker(io: std.Io, a: std.mem.Allocator, marker: []const u8, publish_root: []const u8, llvm_dir: []const u8) !void {
    const lua_objects = try compileLlModules(io, a, marker, llvm_dir);
    const worker = try compileWorkerObject(io, a, marker, llvm_dir);
    const main_c = try sourcePath(a, "src/lua/bundle_worker_main.c");
    const output = try std.fs.path.join(a, &.{ publish_root, "dict-bundle-expander" });
    try linkNativeWorker(io, a, marker, main_c, worker, lua_objects.items, output);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const args = argv[1..];
    if (args.len != 2) {
        std.debug.print("usage: dict-bundle-build DUMP NEW_OUTPUT_DIRECTORY\n", .{});
        return error.Usage;
    }
    const dump = args[0];
    const root = args[1];
    if (root.len == 0 or dump.len == 0) return error.Usage;
    if (std.fs.path.dirname(root)) |parent| if (parent.len != 0)
        try std.Io.Dir.cwd().createDirPath(init.io, parent);
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = marker, .data = "initializing" });
    const expander_root = try std.fs.path.join(a, &.{ root, ".bundle-expander" });
    try std.Io.Dir.cwd().createDir(init.io, expander_root, .default_dir);
    const expander_marker = try std.fs.path.join(a, &.{ expander_root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = expander_marker, .data = "building" });

    try stage(init.io, marker, "extract modules, redirects, and corpus index", &.{ paths.modules, dump, expander_root, "--page-index" });

    const manifest = try std.fs.path.join(a, &.{ expander_root, "manifest.jsonl" });
    const llvm_dir = try std.fs.path.join(a, &.{ expander_root, "llvm" });
    try std.Io.Dir.cwd().createDirPath(init.io, llvm_dir);
    try stage(init.io, marker, "compile Lua AST directly to LLVM IR", &.{ paths.llvm, manifest, expander_root, llvm_dir });

    // The native worker is a transient bundle compiler. It never belongs in the
    // shipped dictionary; full builds consume it immediately and delete .bundle-expander/.
    try compileNativeWorker(init.io, a, marker, expander_root, llvm_dir);
    try std.Io.Dir.cwd().deleteTree(init.io, llvm_dir);

    try std.Io.Dir.cwd().deleteFile(init.io, expander_marker);
    try stage(init.io, marker, "expand and encode dictionary blobs", &.{
        paths.blobs, dump, root, "--expander-root", expander_root,
    });
    try std.Io.Dir.cwd().deleteTree(init.io, expander_root);
    try std.Io.Dir.cwd().deleteFile(init.io, marker);
    std.debug.print("dictionary build complete: {s}\n", .{root});
}
