//! Coordinated Lua -> LLVM -> ThinLTO runtime build.
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
        const object = try std.fmt.allocPrint(a, "{s}/module_{d:0>6}.bc", .{ llvm_dir, index });
        try objects.append(a, object);
        const slot = index % jobs.len;
        try waitCompile(io, &jobs[slot]);
        std.debug.print("dictionary build: compile LLVM module {d}\n", .{index});
        jobs[slot] = .{
            .child = try std.process.spawn(io, .{
                .argv = &.{ paths.zig, "cc", "-O3", "-flto=thin", "-c", source, "-o", object },
                .stdin = .ignore,
            }),
            .index = index,
        };
    }
    if (objects.items.len == 0) return error.MissingLlvmModules;
    for (&jobs) |*job| try waitCompile(io, job);

    const program_source = try std.fs.path.join(a, &.{ llvm_dir, "program.ll" });
    const program_object = try std.fs.path.join(a, &.{ llvm_dir, "program.bc" });
    try stage(io, marker, "compile LLVM program metadata", &.{
        paths.zig, "cc", "-O3", "-flto=thin", "-c", program_source, "-o", program_object,
    });
    try objects.append(a, program_object);
    return objects;
}
fn compileWorkerBitcode(io: std.Io, a: std.mem.Allocator, marker: []const u8, llvm_dir: []const u8) ![]const u8 {
    const worker_core = try sourcePath(a, "src/frontend/native_expansion_worker_core.zig");
    const zig_runtime = try sourcePath(a, "src/lua/runtime/core.zig");
    const lua_program = try sourcePath(a, "src/lua/runtime/llvm_program.zig");
    const lua_llvm_abi = try sourcePath(a, "src/lua/runtime/llvm_abi.zig");
    const zig_stdlib = try sourcePath(a, "src/lua/runtime/stdlib.zig");
    const zig_scribunto = try sourcePath(a, "src/lua/runtime/scribunto.zig");
    const lua_static_fields = try sourcePath(a, "src/lua/abi/static_fields.zig");
    const lua_globals = try sourcePath(a, "src/lua/abi/globals.zig");
    const preprocess = try sourcePath(a, "src/lua/wikitext/preprocess.zig");
    const expression = try sourcePath(a, "src/lua/wikitext/expression.zig");
    const blob_encoder = try sourcePath(a, "src/encoder/blob_root.zig");
    const blob_decoder = try sourcePath(a, "src/decoder/blob_root.zig");
    const blob_files = try sourcePath(a, "src/encoder/blob_files.zig");
    const blob_storage = try sourcePath(a, "src/native/storage.zig");
    const output = try std.fs.path.join(a, &.{ llvm_dir, "worker.bc" });
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
    const encoder_mod = try std.fmt.allocPrint(a, "-Mblob_encoder={s}", .{blob_encoder});
    const decoder_mod = try std.fmt.allocPrint(a, "-Mblob_decoder={s}", .{blob_decoder});
    const files_mod = try std.fmt.allocPrint(a, "-Mblob_files={s}", .{blob_files});
    const storage_mod = try std.fmt.allocPrint(a, "-Mblob_storage={s}", .{blob_storage});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ paths.zig, "build-obj", "-OReleaseFast", "-fllvm", "-flto", "-lc", "-I/usr/include", emit });
    try argv.appendSlice(a, &.{ "--dep", "lua_program", "--dep", "lua_llvm_abi", "--dep", "zig_runtime", "--dep", "blob_encoder", "--dep", "blob_decoder", "--dep", "blob_files", "--dep", "blob_storage", root });
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
        "lua_wikitext_expression", scribunto_mod,             static_fields_mod,
        globals_mod,               preprocess_mod,            expression_mod,
        encoder_mod,               "--dep",                   "blob_encoder",
        "--dep",                   "blob_storage",            decoder_mod,
        "--dep",                   "blob_encoder",            "--dep",
        "blob_storage",            files_mod,                 "--dep",
        "blob_encoder",            storage_mod,
    });
    try stage(io, marker, "compile Zig worker runtime to LLVM bitcode", argv.items);
    return output;
}

fn compileShaBitcode(io: std.Io, a: std.mem.Allocator, marker: []const u8, llvm_dir: []const u8) ![]const u8 {
    const source = try sourcePath(a, "src/native/sha256_abi.zig");
    const output = try std.fs.path.join(a, &.{ llvm_dir, "sha256.bc" });
    const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{output});
    const root = try std.fmt.allocPrint(a, "-Mroot={s}", .{source});
    try stage(io, marker, "compile SHA-256 runtime to LLVM bitcode", &.{ paths.zig, "build-obj", "-OReleaseFast", "-fllvm", "-flto", emit, root });
    return output;
}
fn thinLtoLink(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    llvm_dir: []const u8,
    main_c: []const u8,
    worker: []const u8,
    sha: []const u8,
    lua_objects: []const []const u8,
    output: []const u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "discover ThinLTO linker recipe" });
    const probe = try std.fs.path.join(a, &.{ llvm_dir, "link-probe" });
    const result = try std.process.run(a, io, .{
        .argv = &.{ paths.zig, "cc", "-v", "-O3", "-flto=thin", "-pthread", "-s", main_c, "-lm", "-lc", "-o", probe },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
    });

    var recipe: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ld.lld ")) recipe = line["ld.lld ".len..];
    }
    const raw = recipe orelse {
        std.debug.print("unable to discover Zig LLD recipe:\n{s}\n", .{result.stderr});
        return error.MissingLldRecipe;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ paths.zig, "ld.lld", "--thinlto-jobs=2", "--threads=2" });
    var tokens = std.mem.splitScalar(u8, raw, ' ');
    var replace_output = false;
    var inserted = false;
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        if (replace_output) {
            try argv.append(a, output);
            replace_output = false;
            continue;
        }
        if (std.mem.eql(u8, token, "-o")) {
            try argv.append(a, token);
            replace_output = true;
            continue;
        }
        if (!inserted and std.mem.eql(u8, token, "--as-needed")) {
            try argv.append(a, worker);
            try argv.append(a, sha);
            try argv.appendSlice(a, lua_objects);
            inserted = true;
        }
        try argv.append(a, token);
    }
    if (replace_output or !inserted) return error.InvalidLldRecipe;
    try stage(io, marker, "ThinLTO link native Lua worker (2 jobs)", argv.items);
}

fn compileNativeWorker(io: std.Io, a: std.mem.Allocator, marker: []const u8, publish_root: []const u8, llvm_dir: []const u8) !void {
    const lua_objects = try compileLlModules(io, a, marker, llvm_dir);
    const worker = try compileWorkerBitcode(io, a, marker, llvm_dir);
    const sha = try compileShaBitcode(io, a, marker, llvm_dir);
    const main_c = try sourcePath(a, "src/frontend/native_expansion_worker_main.c");
    const output = try std.fs.path.join(a, &.{ publish_root, "dict-native-expansion-worker" });
    try thinLtoLink(io, a, marker, llvm_dir, main_c, worker, sha, lua_objects.items, output);
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
    if (std.fs.path.dirname(root)) |parent| if (parent.len != 0)
        try std.Io.Dir.cwd().createDirPath(init.io, parent);
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
    const llvm_dir = try std.fs.path.join(a, &.{ runtime, "llvm" });
    try std.Io.Dir.cwd().createDirPath(init.io, llvm_dir);
    try stage(init.io, marker, "compile Lua AST directly to LLVM IR", &.{ paths.llvm, manifest, runtime, llvm_dir });

    if (full)
        try stage(init.io, marker, "encode dictionary blobs", &.{ paths.blobs, dump, root })
    else
        try stage(init.io, marker, "link shared symbols and runtime sources", &.{ paths.linker, root, runtime });

    const publish_root = if (full) root else runtime;
    try compileNativeWorker(init.io, a, marker, publish_root, llvm_dir);
    try std.Io.Dir.cwd().deleteTree(init.io, llvm_dir);
    for ([_][]const u8{ "module-redirects.tsv", "usage.tsv" }) |name| {
        const transient = try std.fs.path.join(a, &.{ runtime, name });
        std.Io.Dir.cwd().deleteFile(init.io, transient) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    try std.Io.Dir.cwd().deleteFile(init.io, runtime_marker);
    if (full) try std.Io.Dir.cwd().deleteFile(init.io, marker);
    std.debug.print("dictionary build complete: {s}\n", .{root});
}
