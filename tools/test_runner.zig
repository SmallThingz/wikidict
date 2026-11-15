const std = @import("std");
const builtin = @import("builtin");

pub const panic = std.debug.FullPanic(panicHandler);

var is_child_mode: bool = false;
var dumping_panic_trace: bool = false;

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    if (comptime builtin.fuzz) {
        return fuzzBuiltin(context, testOne, fuzz_opts);
    }

    if (fuzz_opts.corpus.len == 0) {
        var smith: std.testing.Smith = .{ .in = "" };
        return testOne(context, &smith);
    }

    for (fuzz_opts.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
}

fn fuzzBuiltin(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    const fuzz_abi = std.Build.abi.fuzz;
    const Smith = std.testing.Smith;
    const Ctx = @TypeOf(context);

    const Wrapper = struct {
        var ctx: Ctx = undefined;

        pub fn testOneC() callconv(.c) void {
            var smith: Smith = .{ .in = null };
            testOne(ctx, &smith) catch {};
        }
    };

    Wrapper.ctx = context;

    var cache_dir: []const u8 = ".";
    var map_opt: ?std.process.Environ.Map = null;
    if (std.testing.environ.createMap(std.testing.allocator)) |map| {
        map_opt = map;
        if (map.get("ZIG_CACHE_DIR")) |v| {
            cache_dir = v;
        } else if (map.get("ZIG_GLOBAL_CACHE_DIR")) |v| {
            cache_dir = v;
        }
    } else |_| {}

    fuzz_abi.fuzzer_init(.fromSlice(cache_dir));

    const test_name = @typeName(@TypeOf(testOne));
    fuzz_abi.fuzzer_set_test(Wrapper.testOneC, .fromSlice(test_name));

    for (fuzz_opts.corpus) |input| {
        fuzz_abi.fuzzer_new_input(.fromSlice(input));
    }

    fuzz_abi.fuzzer_main(.forever, 0);

    if (map_opt) |*m| m.deinit();
}

pub fn main(init: std.process.Init) !void {
    const threaded = std.Io.Threaded.init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    std.testing.io_instance = threaded;
    defer std.testing.io_instance.deinit();
    std.testing.environ = init.minimal.environ;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();

    const argv0_z = arg_it.next() orelse "test-runner";
    const argv0 = try init.gpa.dupe(u8, argv0_z[0..argv0_z.len]);
    defer init.gpa.free(argv0);

    var child_test_name: ?[]const u8 = null;
    var list_tests = false;
    var filter: ?[]const u8 = null;
    var jobs: ?usize = null;
    var seed: ?u32 = null;

    while (arg_it.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--dict-run-test")) {
            const name_z = arg_it.next() orelse return error.MissingTestName;
            child_test_name = try init.gpa.dupe(u8, name_z[0..name_z.len]);
        } else if (std.mem.eql(u8, arg, "--dict-list-tests")) {
            list_tests = true;
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            const f_z = arg_it.next() orelse return error.MissingFilter;
            filter = try init.gpa.dupe(u8, f_z[0..f_z.len]);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            const j_z = arg_it.next() orelse return error.MissingJobs;
            jobs = try std.fmt.parseUnsigned(usize, j_z[0..j_z.len], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const s_z = arg_it.next() orelse return error.MissingSeed;
            seed = try std.fmt.parseUnsigned(u32, s_z[0..s_z.len], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            // Ignore unknown args to stay compatible with Zig's test flags.
        }
    }

    defer if (child_test_name) |name| init.gpa.free(name);
    defer if (filter) |f| init.gpa.free(f);
    if (list_tests) {
        if (child_test_name != null) return error.IncompatibleTestModes;
        var tests = try selectedTestNames(init.gpa, filter);
        defer tests.deinit(init.gpa);
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try std.json.Stringify.value(.{
            .schema = "dict.test-inventory.v1",
            .compiled_test_count = builtin.test_functions.len,
            .tests = tests.items,
        }, .{}, &stdout.interface);
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
        return;
    }

    if (child_test_name) |name| {
        is_child_mode = true;
        runSingleTest(name, seed);
        return;
    }

    try runAllTests(init.gpa, init.io, argv0, filter, jobs, seed);
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (is_child_mode) {
        std.debug.print("{s}\n", .{msg});
        // Keep the original panic site; a diagnostic panic must not recurse.
        if (!dumping_panic_trace) {
            dumping_panic_trace = true;
            std.debug.dumpCurrentStackTrace(.{ .first_address = first_trace_addr });
        }
        std.debug.print("{s}", .{ReturnedFailure.panic_trailer});
        std.process.exit(1);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn printHelp() void {
    std.debug.print(
        "Usage: test-runner [--dict-list-tests] [--test-filter <str>] [--jobs <n>] [--seed <n>]\n" ++
            "  --dict-list-tests  Write the compiled test inventory as JSON without running tests.\n",
        .{},
    );
}

const Status = enum {
    pass,
    fail,
    skip,
    leak,
    crash,
};

const Summary = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    leak: usize = 0,
    crash: usize = 0,
};

fn selectedTestNames(gpa: std.mem.Allocator, filter: ?[]const u8) !std.ArrayList([]const u8) {
    var tests: std.ArrayList([]const u8) = .empty;
    errdefer tests.deinit(gpa);
    for (builtin.test_functions) |t| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, t.name, f) == null) continue;
        }
        try tests.append(gpa, t.name);
    }
    return tests;
}

fn runAllTests(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    filter: ?[]const u8,
    jobs: ?usize,
    seed: ?u32,
) !void {
    var tests = try selectedTestNames(gpa, filter);
    defer tests.deinit(gpa);

    if (tests.items.len == 0) {
        std.debug.print("0 tests selected\n", .{});
        return;
    }

    var job_count = jobs orelse 1;
    if (job_count == 0) job_count = 1;
    if (job_count > tests.items.len) job_count = tests.items.len;

    var next_index: std.atomic.Value(usize) = .init(0);
    var summary: Summary = .{};
    var print_mutex: std.Io.Mutex = .init;
    var count_mutex: std.Io.Mutex = .init;

    // No environment-map allocation on the normal POSIX omitted-option path.
    var windows_failure_dir: ?[]u8 = null;
    defer if (windows_failure_dir) |directory| gpa.free(directory);
    if (builtin.os.tag == .windows) {
        windows_failure_dir = std.testing.environ.getAlloc(gpa, FailureOutput.environment_key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => return err,
        };
    }
    const failure_output_dir: ?[]const u8 = if (builtin.os.tag == .windows) windows_failure_dir else std.testing.environ.getPosix(FailureOutput.environment_key);
    if (failure_output_dir) |directory| try FailureOutput.validateDirectory(directory);

    var ctx = WorkerCtx{
        .gpa = gpa,
        .io = io,
        .argv0 = argv0,
        .tests = tests.items,
        .seed = seed,
        .failure_output_dir = failure_output_dir,
        .next_index = &next_index,
        .summary = &summary,
        .print_mutex = &print_mutex,
        .count_mutex = &count_mutex,
    };

    if (builtin.single_threaded or job_count == 1) {
        worker(&ctx);
    } else {
        const threads = try gpa.alloc(std.Thread, job_count);
        defer gpa.free(threads);
        for (threads, 0..) |*t, i| {
            _ = i;
            t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
        }
        for (threads) |t| t.join();
    }

    std.debug.print(
        "\npass: {d}  fail: {d}  skip: {d}  leak: {d}  crash: {d}\n",
        .{ summary.pass, summary.fail, summary.skip, summary.leak, summary.crash },
    );

    if (summary.fail != 0 or summary.crash != 0 or summary.leak != 0) {
        std.process.exit(1);
    }
}

const WorkerCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    tests: []const []const u8,
    seed: ?u32,
    failure_output_dir: ?[]const u8 = null,
    next_index: *std.atomic.Value(usize),
    summary: *Summary,
    print_mutex: *std.Io.Mutex,
    count_mutex: *std.Io.Mutex,
};

fn worker(ctx: *WorkerCtx) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .seq_cst);
        if (idx >= ctx.tests.len) break;

        const test_name = ctx.tests[idx];
        const result = runChildTest(ctx, test_name) catch |err| {
            ctx.print_mutex.lockUncancelable(ctx.io);
            defer ctx.print_mutex.unlock(ctx.io);
            if (err == error.StreamTooLong) std.debug.print("TEST_FAILURE_CAPTURE_ERROR capture_limit_per_stream={d} retained_streams_unavailable=true\n", .{FailureOutput.capture_limit});
            std.debug.print("\n== TEST {s} ==\nrunner error: {s}\n", .{ test_name, @errorName(err) });
            ctx.count_mutex.lockUncancelable(ctx.io);
            ctx.summary.fail += 1;
            ctx.count_mutex.unlock(ctx.io);
            continue;
        };
        defer ctx.gpa.free(result.stdout);
        defer ctx.gpa.free(result.stderr);

        ctx.print_mutex.lockUncancelable(ctx.io);
        defer ctx.print_mutex.unlock(ctx.io);
        retainFailureOutput(ctx, idx, result) catch |err| {
            std.debug.print("TEST_FAILURE_OUTPUT_ERROR index={d} error={s} capture_limit_per_stream={d} original_status={s}\n", .{ idx, @errorName(err), FailureOutput.capture_limit, @tagName(result.status) });
        };
        printTestOutput(test_name, result);

        ctx.count_mutex.lockUncancelable(ctx.io);
        switch (result.status) {
            .pass => ctx.summary.pass += 1,
            .fail => ctx.summary.fail += 1,
            .skip => ctx.summary.skip += 1,
            .leak => ctx.summary.leak += 1,
            .crash => ctx.summary.crash += 1,
        }
        ctx.count_mutex.unlock(ctx.io);
    }
}

const ChildResult = struct {
    status: Status,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runChildTest(ctx: *WorkerCtx, test_name: []const u8) !ChildResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);

    try argv.append(ctx.gpa, ctx.argv0);
    try argv.append(ctx.gpa, "--dict-run-test");
    try argv.append(ctx.gpa, test_name);

    var seed_buf: ?[]u8 = null;
    if (ctx.seed) |s| {
        const seed_str = try std.fmt.allocPrint(ctx.gpa, "{d}", .{s});
        seed_buf = seed_str;
        try argv.append(ctx.gpa, "--seed");
        try argv.append(ctx.gpa, seed_str);
    }
    defer if (seed_buf) |b| ctx.gpa.free(b);

    const result = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(FailureOutput.capture_limit),
        .stderr_limit = .limited(FailureOutput.capture_limit),
    });

    const status = classifyStatus(result.term);
    return .{
        .status = status,
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn classifyStatus(term: std.process.Child.Term) Status {
    switch (term) {
        .exited => |code| return switch (code) {
            0 => .pass,
            2 => .skip,
            3 => .leak,
            else => .fail,
        },
        .signal, .stopped, .unknown => return .crash,
    }
}

// A returned error is recorded after allocator cleanup, separately from the
// bounded human diagnostic prefix. Hex keeps arbitrary error names inert.
pub const ReturnedFailure = struct {
    pub const max_name_bytes = 128;
    pub const prefix = "\nDICT_TEST_RETURN_ERROR_HEX=";
    pub const panic_trailer = "\nDICT_TEST_CHILD_PANIC\n";
    pub const max_trailer_bytes = prefix.len + max_name_bytes * 2 + 1;

    pub fn trailer(buffer: []u8, result: anyerror!void, leak_status: usize) ?[]const u8 {
        if (leak_status != 0) return null;
        if (result) |_| {
            return null;
        } else |err| {
            if (err == error.SkipZigTest) return null;
            const name = @errorName(err);
            if (name.len == 0 or name.len > max_name_bytes) return null;
            const end = prefix.len + name.len * 2;
            if (buffer.len < end + 1) return null;
            @memcpy(buffer[0..prefix.len], prefix);
            const digits = "0123456789abcdef";
            for (name, 0..) |byte, index| {
                buffer[prefix.len + index * 2] = digits[byte >> 4];
                buffer[prefix.len + index * 2 + 1] = digits[byte & 15];
            }
            buffer[end] = '\n';
            return buffer[0 .. end + 1];
        }
    }

    pub fn fromChild(stderr: []const u8, term: std.process.Child.Term) ?[]const u8 {
        switch (term) {
            .exited => |code| if (code != 1) return null,
            else => return null,
        }
        if (stderr.len == 0 or stderr[stderr.len - 1] != '\n') return null;
        const start = std.mem.lastIndexOfScalar(u8, stderr[0 .. stderr.len - 1], '\n') orelse return null;
        const terminal = stderr[start..];
        if (!std.mem.startsWith(u8, terminal, prefix)) return null;
        const encoded = terminal[prefix.len .. terminal.len - 1];
        if (encoded.len == 0 or encoded.len > max_name_bytes * 2 or encoded.len % 2 != 0) return null;
        for (encoded) |byte| {
            if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return null;
        }
        return encoded;
    }
};

// Optional parent-owned diagnostics. Payload never enters the status/typed-error channel.
pub const FailureOutput = struct {
    pub const environment_key = "WIKIDICT_TEST_FAILURE_OUTPUT_DIR";
    pub const capture_limit = 4 * 1024 * 1024;

    pub fn validateDirectory(path: []const u8) !void {
        if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path)) return error.InvalidFailureOutputDirectory;
        for (path) |byte| if (std.ascii.isControl(byte)) return error.InvalidFailureOutputDirectory;
    }
    pub fn shouldRetain(status: Status) bool {
        return status == .fail or status == .leak or status == .crash;
    }
    pub fn write(dir: std.Io.Dir, io: std.Io, stem: []const u8, stdout: []const u8, stderr: []const u8) !void {
        if (stem.len == 0 or stem.len > 96) return error.InvalidFailureOutputStem;
        for (stem) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidFailureOutputStem;
        if (stdout.len > capture_limit or stderr.len > capture_limit) return error.StreamTooLong;
        var name_buffer: [112]u8 = undefined;
        const stdout_name = try std.fmt.bufPrint(&name_buffer, "{s}.stdout", .{stem});
        var stdout_file = try dir.createFile(io, stdout_name, .{ .exclusive = true });
        defer stdout_file.close(io);
        var stdout_buffer: [8192]u8 = undefined;
        var stdout_writer = stdout_file.writer(io, &stdout_buffer);
        try stdout_writer.interface.writeAll(stdout);
        try stdout_writer.interface.flush();
        const stderr_name = try std.fmt.bufPrint(&name_buffer, "{s}.stderr", .{stem});
        var stderr_file = try dir.createFile(io, stderr_name, .{ .exclusive = true });
        defer stderr_file.close(io);
        var stderr_buffer: [8192]u8 = undefined;
        var stderr_writer = stderr_file.writer(io, &stderr_buffer);
        try stderr_writer.interface.writeAll(stderr);
        try stderr_writer.interface.flush();
    }
    pub fn report(buffer: []u8, directory: []const u8, stem: []const u8, stdout_bytes: usize, stderr_bytes: usize) ![]const u8 {
        return std.fmt.bufPrint(buffer, "TEST_FAILURE_OUTPUT directory={s} stdout={s}.stdout stderr={s}.stderr stdout_bytes={d} stderr_bytes={d} capture_limit_per_stream={d} complete_captured_streams=true\n", .{ directory, stem, stem, stdout_bytes, stderr_bytes, capture_limit });
    }
};

fn retainFailureOutput(ctx: *WorkerCtx, index: usize, result: ChildResult) !void {
    const directory = ctx.failure_output_dir orelse return;
    if (!FailureOutput.shouldRetain(result.status)) return;
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, directory, .{ .follow_symlinks = false });
    defer dir.close(ctx.io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ctx.argv0, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var stem_buffer: [96]u8 = undefined;
    const stem = try std.fmt.bufPrint(&stem_buffer, "{s}-{d}", .{ hex, index });
    try FailureOutput.write(dir, ctx.io, stem, result.stdout, result.stderr);
    var report_buffer: [4608]u8 = undefined;
    const report = try FailureOutput.report(&report_buffer, directory, stem, result.stdout.len, result.stderr.len);
    std.debug.print("{s}", .{report});
}

fn printTestOutput(name: []const u8, res: ChildResult) void {
    const color = switch (res.status) {
        .pass => "\x1b[32m",
        .skip => "\x1b[94m",
        else => "\x1b[31m",
    };
    const label = switch (res.status) {
        .pass => "ok",
        .skip => "skip",
        .leak => "leak",
        .crash => "crash",
        .fail => "error",
    };

    std.debug.print("{s}{s}\x1b[0m {s}", .{ color, label, name });

    if (res.stdout.len > 0) {
        std.debug.print(" | out: ", .{});
        printSingleLine(res.stdout, if (res.status == .fail or res.status == .crash) 2000 else 200);
    }
    if (res.stderr.len > 0) {
        std.debug.print(" | err: ", .{});
        printSingleLine(res.stderr, if (res.status == .fail or res.status == .crash) 2000 else 200);
    }

    switch (res.term) {
        .exited => |code| if (code != 0) std.debug.print(" | exit {d}", .{code}),
        .signal => |sig| std.debug.print(" | signal {d}", .{@backingInt(sig)}),
        .stopped => |code| std.debug.print(" | stopped {d}", .{code}),
        .unknown => |code| std.debug.print(" | unknown {d}", .{code}),
    }

    if (res.status == .fail) {
        if (ReturnedFailure.fromChild(res.stderr, res.term)) |encoded| {
            std.debug.print(" | returned-error-hex={s}", .{encoded});
        }
    }
    std.debug.print("\n", .{});
}

fn printSingleLine(bytes: []const u8, max_len: usize) void {
    var written: usize = 0;
    for (bytes) |c| {
        if (written >= max_len) break;
        switch (c) {
            '\n', '\r', '\t' => {
                std.debug.print(" ", .{});
                written += 1;
            },
            else => {
                std.debug.print("{c}", .{c});
                written += 1;
            },
        }
    }
    if (bytes.len > max_len) std.debug.print("...", .{});
}

fn runSingleTest(name: []const u8, seed: ?u32) void {
    if (seed) |s| std.testing.random_seed = s;

    const test_fn = findTest(name) orelse {
        std.debug.print("unknown test: {s}\n", .{name});
        std.process.exit(1);
    };

    std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
    const result = test_fn.func();
    // Report while the callee's return trace is live, before allocator cleanup
    // can issue fallible diagnostics. Cleanup still decides leak exit priority.
    if (result) |_| {} else |err| {
        if (err != error.SkipZigTest) {
            std.debug.print("{s}\n", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            } else {
                std.debug.print("error return trace unavailable (enable error tracing for this test build)\n", .{});
            }
        }
    }
    const leak_status = std.testing.allocator_instance.deinit();

    if (leak_status != 0) {
        std.debug.print("memory leak\n", .{});
        std.process.exit(3);
    }

    var returned_error_buffer: [ReturnedFailure.max_trailer_bytes]u8 = undefined;
    if (ReturnedFailure.trailer(&returned_error_buffer, result, leak_status)) |terminal| {
        std.debug.print("{s}", .{terminal});
    }

    if (result) |_| {
        std.process.exit(0);
    } else |err| switch (err) {
        error.SkipZigTest => std.process.exit(2),
        else => std.process.exit(1),
    }
}

const TestFn = std.meta.Elem(@TypeOf(builtin.test_functions));

fn findTest(name: []const u8) ?TestFn {
    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}
