//! Coordinated build-time Lua/template expansion and data-only blob bundling.
const std = @import("std");
const paths = @import("pipeline_paths");

const Options = struct {
    dump: []const u8,
    root: []const u8,
    commons_data_snapshot: ?[]const u8 = null,
    category_stats_snapshot: ?[]const u8 = null,
    interface_messages_snapshot: ?[]const u8 = null,
    llvm_workers: ?usize = null,
};

fn parseOptions(args: []const []const u8) !Options {
    if (args.len < 2) return error.Usage;
    var options: Options = .{ .dump = args[0], .root = args[1] };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--commons-data-snapshot")) {
            index += 1;
            if (index >= args.len or options.commons_data_snapshot != null) return error.Usage;
            options.commons_data_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--category-stats-snapshot")) {
            index += 1;
            if (index >= args.len or options.category_stats_snapshot != null) return error.Usage;
            options.category_stats_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--interface-messages-snapshot")) {
            index += 1;
            if (index >= args.len or options.interface_messages_snapshot != null) return error.Usage;
            options.interface_messages_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--llvm-workers")) {
            index += 1;
            if (index >= args.len or options.llvm_workers != null) return error.Usage;
            const workers = std.fmt.parseInt(usize, args[index], 10) catch return error.Usage;
            if (workers == 0) return error.Usage;
            options.llvm_workers = workers;
        } else return error.Usage;
    }
    return options;
}

fn defaultLlvmWorkersForCpuCount(logical_cpu_threads: usize) usize {
    const threads = @max(logical_cpu_threads, 1);
    return 1 + threads / 3;
}

fn defaultLlvmWorkers() usize {
    return defaultLlvmWorkersForCpuCount(std.Thread.getCpuCount() catch 1);
}

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

fn fileSize(io: std.Io, path: []const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return (try file.stat(io)).size;
}

fn installSnapshot(io: std.Io, a: std.mem.Allocator, source: []const u8, root: []const u8, name: []const u8) !void {
    const destination = try std.fs.path.join(a, &.{ root, name });
    const allocator = std.heap.smp_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = bytes });
}

const CompileMode = enum {
    o1,
    o2,

    fn parse(raw: []const u8) !CompileMode {
        if (std.mem.eql(u8, raw, "-O1")) return .o1;
        if (std.mem.eql(u8, raw, "-O2")) return .o2;
        return error.InvalidBatchPlan;
    }

    fn flag(self: CompileMode) []const u8 {
        return switch (self) {
            .o1 => "-O1",
            .o2 => "-O2",
        };
    }
};

const BatchPlan = struct {
    mode: CompileMode,
    file: []const u8,
    count: usize,
    first_index: usize,
    last_index: usize,
    source_bytes: u64,
};

fn readBatchPlan(
    io: std.Io,
    a: std.mem.Allocator,
    llvm_dir: []const u8,
) ![]BatchPlan {
    const path = try std.fs.path.join(a, &.{ llvm_dir, "batch-plan.tsv" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);

    var plans: std.ArrayList(BatchPlan) = .empty;
    errdefer plans.deinit(a);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const mode = try CompileMode.parse(
            fields.next() orelse return error.InvalidBatchPlan,
        );
        const file = fields.next() orelse return error.InvalidBatchPlan;
        if (file.len == 0 or
            std.fs.path.isAbsolute(file) or
            std.mem.indexOfScalar(u8, file, '/') != null or
            !std.mem.endsWith(u8, file, ".bc"))
            return error.InvalidBatchPlan;
        const count = try std.fmt.parseInt(
            usize,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        const first_index = try std.fmt.parseInt(
            usize,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        const last_index = try std.fmt.parseInt(
            usize,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        const source_bytes = try std.fmt.parseInt(
            u64,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        if (fields.next() != null or count == 0 or last_index < first_index)
            return error.InvalidBatchPlan;
        try plans.append(a, .{
            .mode = mode,
            .file = file,
            .count = count,
            .first_index = first_index,
            .last_index = last_index,
            .source_bytes = source_bytes,
        });
    }
    if (plans.items.len == 0) return error.MissingLlvmModules;
    return plans.toOwnedSlice(a);
}

const CompileJob = struct {
    child: std.process.Child,
    mode: CompileMode,
    first_index: usize,
    last_index: usize,
    count: usize,
};

fn waitCompile(io: std.Io, job: *?CompileJob) !void {
    if (job.*) |*active| {
        const term = try active.child.wait(io);
        const mode = active.mode;
        const first_index = active.first_index;
        const last_index = active.last_index;
        const count = active.count;
        job.* = null;
        if (term != .exited or term.exited != 0) {
            std.debug.print(
                "dictionary build failed compiling {s} LLVM batch count={d} first={d} last={d}; incomplete marker retained\n",
                .{ mode.flag(), count, first_index, last_index },
            );
            return error.PipelineStageFailed;
        }
    }
}

fn compileBitcodeModules(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    llvm_dir: []const u8,
    llvm_workers: usize,
) !std.ArrayList([]const u8) {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = marker,
        .data = "compile Lua LLVM bitcode batches",
    });

    if (llvm_workers == 0) return error.InvalidWorkerCount;
    const plans = try readBatchPlan(io, a, llvm_dir);
    defer a.free(plans);
    const worker_count = @min(llvm_workers, plans.len);
    std.debug.print("dictionary build: LLVM compile workers={d}\n", .{worker_count});

    var objects: std.ArrayList([]const u8) = .empty;
    const jobs = try a.alloc(?CompileJob, worker_count);
    defer a.free(jobs);
    @memset(jobs, null);
    errdefer for (jobs) |*job| if (job.*) |*active| active.child.kill(io);

    for (plans, 0..) |plan, batch_index| {
        const source = try std.fs.path.join(a, &.{ llvm_dir, plan.file });
        const object = try std.fmt.allocPrint(
            a,
            "{s}/module_batch_{d:0>6}.o",
            .{ llvm_dir, batch_index },
        );
        try objects.append(a, object);

        const slot = batch_index % jobs.len;
        try waitCompile(io, &jobs[slot]);
        std.debug.print(
            "dictionary build: compile {s} LLVM batch count={d} first={d} last={d} source_bytes={d}\n",
            .{
                plan.mode.flag(),
                plan.count,
                plan.first_index,
                plan.last_index,
                plan.source_bytes,
            },
        );
        const child = try std.process.spawn(io, .{
            .argv = &.{
                paths.clang,
                plan.mode.flag(),
                "-fno-lto",
                "-Wno-override-module",
                "-c",
                source,
                "-o",
                object,
            },
            .stdin = .ignore,
        });
        jobs[slot] = .{
            .child = child,
            .mode = plan.mode,
            .first_index = plan.first_index,
            .last_index = plan.last_index,
            .count = plan.count,
        };
    }
    for (jobs) |*job| try waitCompile(io, job);

    const program_source = try std.fs.path.join(a, &.{ llvm_dir, "program.bc" });
    const program_object = try std.fs.path.join(a, &.{ llvm_dir, "program.o" });
    try stage(io, marker, "compile LLVM program metadata (-O1)", &.{
        paths.clang,
        "-O1",
        "-fno-lto",
        "-Wno-override-module",
        "-c",
        program_source,
        "-o",
        program_object,
    });
    try objects.append(a, program_object);
    return objects;
}

fn compileWorkerObject(io: std.Io, a: std.mem.Allocator, marker: []const u8, llvm_dir: []const u8) ![]const u8 {
    const worker_core = try sourcePath(a, "src/lua/bundle_worker.zig");
    const zig_runtime = try sourcePath(a, "src/lua/runtime/core.zig");
    const lua_program = try sourcePath(a, "src/lua/runtime/llvm_program.zig");
    const lua_program_metadata = try sourcePath(a, "src/lua/program_metadata.zig");
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
    const program_metadata_mod = try std.fmt.allocPrint(a, "-Mlua_program_metadata={s}", .{lua_program_metadata});
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
        "--dep",                   "lua_static_fields", runtime_mod,
        "--dep",                   "zig_runtime",       "--dep",
        "zig_stdlib",              "--dep",             "zig_scribunto",
        "--dep",                   "lua_globals",       "--dep",
        "lua_program_metadata",    program_mod,         "--dep",
        "zig_runtime",             llvm_abi_mod,        "--dep",
        "zig_runtime",             "--dep",             "lua_globals",
        stdlib_mod,                "--dep",             "zig_runtime",
        "--dep",                   "zig_stdlib",        "--dep",
        "lua_wikitext_preprocess", "--dep",             "lua_wikitext_expression",
        "--dep",                   "shared_xml_decode", scribunto_mod,
        static_fields_mod,         globals_mod,         program_metadata_mod,
        preprocess_mod,            expression_mod,      xml_decode_mod,
    });
    try stage(io, marker, "compile optimized build-only Lua worker object", argv.items);
    return output;
}

fn appendResponseArg(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) !void {
    try out.append(a, '"');
    for (arg) |byte| {
        if (byte == '\\' or byte == '"') try out.append(a, '\\');
        try out.append(a, byte);
    }
    try out.appendSlice(a, "\"\n");
}

fn writeResponseFile(io: std.Io, a: std.mem.Allocator, path: []const u8, args: []const []const u8) !void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    for (args) |arg| try appendResponseArg(&data, a, arg);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data.items });
}

fn linkNativeWorker(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    llvm_dir: []const u8,
    main_c: []const u8,
    worker: []const u8,
    lua_objects: []const []const u8,
    output: []const u8,
) !void {
    const response_path = try std.fs.path.join(a, &.{ llvm_dir, "module-objects.rsp" });
    try writeResponseFile(io, a, response_path, lua_objects);
    const response_arg = try std.fmt.allocPrint(a, "@{s}", .{response_path});
    try stage(io, marker, "link optimized native Lua worker", &.{
        paths.zig, "cc", "-O2", "-pthread", "-s", main_c, worker, response_arg, "-lm", "-lc", "-o", output,
    });
}

fn compileNativeWorker(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    publish_root: []const u8,
    llvm_dir: []const u8,
    llvm_workers: usize,
) !void {
    const lua_objects = try compileBitcodeModules(io, a, marker, llvm_dir, llvm_workers);
    const worker = try compileWorkerObject(io, a, marker, llvm_dir);
    const main_c = try sourcePath(a, "src/lua/bundle_worker_main.c");
    const output = try std.fs.path.join(a, &.{ publish_root, "dict-bundle-expander" });
    try linkNativeWorker(io, a, marker, llvm_dir, main_c, worker, lua_objects.items, output);

    const metadata_source = try std.fs.path.join(a, &.{ llvm_dir, "program.meta" });
    const metadata_destination = try std.fs.path.join(a, &.{ publish_root, "lua-program.meta" });
    try std.Io.Dir.cwd().rename(metadata_source, std.Io.Dir.cwd(), metadata_destination, io);
}

test "default LLVM worker count is one plus one third logical CPUs" {
    try std.testing.expectEqual(@as(usize, 1), defaultLlvmWorkersForCpuCount(1));
    try std.testing.expectEqual(@as(usize, 1), defaultLlvmWorkersForCpuCount(2));
    try std.testing.expectEqual(@as(usize, 2), defaultLlvmWorkersForCpuCount(3));
    try std.testing.expectEqual(@as(usize, 5), defaultLlvmWorkersForCpuCount(12));
}

test "LLVM worker override accepts positive integers only" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "7" });
    try std.testing.expectEqual(@as(?usize, 7), options.llvm_workers);
    try std.testing.expectError(
        error.Usage,
        parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "0" }),
    );
    try std.testing.expectError(
        error.Usage,
        parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "nope" }),
    );
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const options = parseOptions(argv[1..]) catch {
        std.debug.print("usage: dict-bundle-build DUMP NEW_OUTPUT_DIRECTORY [--commons-data-snapshot FILE] [--category-stats-snapshot FILE] [--interface-messages-snapshot FILE]\n", .{});
        return error.Usage;
    };
    const dump = options.dump;
    const root = options.root;
    if (root.len == 0 or dump.len == 0) return error.Usage;
    const llvm_workers = options.llvm_workers orelse defaultLlvmWorkers();
    if (std.fs.path.dirname(root)) |parent| if (parent.len != 0)
        try std.Io.Dir.cwd().createDirPath(init.io, parent);
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = marker, .data = "initializing" });
    const expander_root = try std.fs.path.join(a, &.{ root, ".bundle-expander" });
    try std.Io.Dir.cwd().createDir(init.io, expander_root, .default_dir);
    const expander_marker = try std.fs.path.join(a, &.{ expander_root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = expander_marker, .data = "building" });
    if (options.commons_data_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "commons-data.tsv");
    if (options.category_stats_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "category-stats.tsv");
    if (options.interface_messages_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "interface-messages.tsv");

    try stage(init.io, marker, "extract modules, redirects, and corpus index", &.{ paths.modules, dump, expander_root, "--page-index" });

    const manifest = try std.fs.path.join(a, &.{ expander_root, "manifest.jsonl" });
    const llvm_dir = try std.fs.path.join(a, &.{ expander_root, "llvm" });
    try std.Io.Dir.cwd().createDirPath(init.io, llvm_dir);
    try stage(init.io, marker, "emit Lua AST directly to LLVM bitcode", &.{ paths.llvm, manifest, expander_root, llvm_dir });

    // The native worker is a transient bundle compiler. It never belongs in the
    // shipped dictionary; full builds consume it immediately and delete .bundle-expander/.
    try compileNativeWorker(init.io, a, marker, expander_root, llvm_dir, llvm_workers);
    try std.Io.Dir.cwd().deleteTree(init.io, llvm_dir);

    try std.Io.Dir.cwd().deleteFile(init.io, expander_marker);
    try stage(init.io, marker, "expand and encode dictionary blobs", &.{
        paths.blobs, dump, root, "--expander-root", expander_root,
    });
    try std.Io.Dir.cwd().deleteTree(init.io, expander_root);
    try std.Io.Dir.cwd().deleteFile(init.io, marker);
    std.debug.print("dictionary build complete: {s}\n", .{root});
}
