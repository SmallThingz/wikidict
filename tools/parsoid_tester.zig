const builtin = @import("builtin");
const std = @import("std");

const decoder = @import("decoder");
const renderer = @import("renderer");
const encoder = if (builtin.is_test) @import("encoder") else struct {};

const html_render = renderer.html_render;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        printUsage();
        return;
    }

    const options = try parseOptions(allocator, args[1..]);
    const stats = try auditDictionary(init.io, init.gpa, options);

    std.debug.print(
        "parsoid audit\n" ++
            "db={s}\n" ++
            "report={s}\n" ++
            "entries_scanned={d}\n" ++
            "raw_entries_scanned={d}\n" ++
            "compared_entries={d}\n" ++
            "alias_entries_skipped={d}\n" ++
            "renderer_errors={d}\n" ++
            "mismatches={d}\n" ++
            "worker_errors={d}\n",
        .{
            options.db_path,
            options.report_path,
            stats.entries_scanned,
            stats.raw_entries_scanned,
            stats.compared_entries,
            stats.alias_entries_skipped,
            stats.renderer_errors,
            stats.mismatches,
            stats.worker_errors,
        },
    );

    if (stats.failures() != 0) return error.ParsoidAuditFailed;
}

const Options = struct {
    db_path: []const u8 = "data/enwiktionary.bin",
    report_path: []const u8 = "data/parsoid-audit-report.txt",
    limit_entries: ?usize = null,
    word_filter: ?[]const u8 = null,
    node_cmd: []const u8 = "node",
    worker_path: []const u8,
};

pub const AuditStats = struct {
    entries_scanned: usize = 0,
    raw_entries_scanned: usize = 0,
    compared_entries: usize = 0,
    alias_entries_skipped: usize = 0,
    renderer_errors: usize = 0,
    mismatches: usize = 0,
    worker_errors: usize = 0,

    pub fn failures(self: AuditStats) usize {
        return self.renderer_errors + self.mismatches + self.worker_errors;
    }
};

const Progress = struct {
    total_entries: usize,
    last_percent: u8 = 255,

    fn init(total_entries: usize) Progress {
        return .{ .total_entries = total_entries };
    }

    fn update(self: *Progress, stats: AuditStats) void {
        if (builtin.is_test or self.total_entries == 0) return;

        const percent = @as(u8, @intCast(@min(100, (stats.entries_scanned * 100) / self.total_entries)));
        if (percent == self.last_percent and stats.entries_scanned != self.total_entries) return;
        self.last_percent = percent;

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        std.debug.print(
            "\rparsoid audit [{s}] {d:>3}% compare rendered sections ({d}/{d} entries, {d} mismatches, {d} worker errors)",
            .{
                &bar,
                percent,
                stats.entries_scanned,
                self.total_entries,
                stats.mismatches,
                stats.worker_errors,
            },
        );
    }

    fn finish(self: *Progress, stats: AuditStats) void {
        if (builtin.is_test) return;
        self.update(stats);
        std.debug.print("\n", .{});
    }
};

const RequestSection = struct {
    title: []const u8,
    level: u8,
    html: []const u8,
};

const WorkerRequest = struct {
    title: []const u8,
    raw: []const u8,
    sections: []const RequestSection,
};

const WorkerResponse = struct {
    ok: bool,
    kind: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    our: ?[]const u8 = null,
    parsoid: ?[]const u8 = null,
};

const FailureSample = struct {
    word: []u8,
    kind: []u8,
    summary: []u8,
    our: []u8,
    parsoid: []u8,

    fn deinit(self: *FailureSample, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
        allocator.free(self.kind);
        allocator.free(self.summary);
        allocator.free(self.our);
        allocator.free(self.parsoid);
    }
};

const WorkerClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_buffer: [4096]u8 = undefined,
    stdout_buffer: [64 * 1024]u8 = undefined,

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !WorkerClient {
        var child = try std.process.spawn(io, .{
            .argv = &.{ options.node_cmd, options.worker_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
        };
    }

    fn deinit(self: *WorkerClient) void {
        self.child.kill(self.io);
    }

    fn compare(self: *WorkerClient, allocator: std.mem.Allocator, request: WorkerRequest) !WorkerResponse {
        var writer = self.child.stdin.?.writerStreaming(self.io, &self.stdin_buffer);
        try writer.interface.print("{f}\n", .{std.json.fmt(request, .{})});
        try writer.flush();

        var reader = self.child.stdout.?.readerStreaming(self.io, &self.stdout_buffer);
        const line = (try reader.interface.takeDelimiter('\n')) orelse return error.UnexpectedEndOfStream;
        return try std.json.parseFromSliceLeaky(WorkerResponse, allocator, line, .{});
    }
};

const Auditor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dict: decoder.Dictionary,
    worker: WorkerClient,
    report: std.Io.Writer.Allocating,
    progress: Progress,
    samples: std.ArrayList(FailureSample) = .empty,
    stats: AuditStats = .{},

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Auditor {
        var dict = try decoder.openDictionary(allocator, io, options.db_path);
        errdefer dict.deinit();

        const total_entries = countTargetEntries(&dict, options);
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dict = dict,
            .worker = try WorkerClient.init(allocator, io, options),
            .report = .init(allocator),
            .progress = Progress.init(total_entries),
        };
    }

    fn deinit(self: *Auditor) void {
        for (self.samples.items) |*sample| sample.deinit(self.allocator);
        self.samples.deinit(self.allocator);
        self.report.deinit();
        self.worker.deinit();
        self.dict.deinit();
    }

    fn recordAliasSkipped(self: *Auditor) void {
        self.stats.entries_scanned += 1;
        self.stats.alias_entries_skipped += 1;
        self.progress.update(self.stats);
    }

    fn recordCompared(self: *Auditor) void {
        self.stats.entries_scanned += 1;
        self.stats.raw_entries_scanned += 1;
        self.stats.compared_entries += 1;
        self.progress.update(self.stats);
    }

    fn recordRendererError(self: *Auditor, word: []const u8, summary: []const u8) !void {
        self.stats.entries_scanned += 1;
        self.stats.raw_entries_scanned += 1;
        self.stats.renderer_errors += 1;
        try self.addSample(word, "renderer_error", summary, "", "");
        self.progress.update(self.stats);
    }

    fn recordMismatch(self: *Auditor, word: []const u8, response: WorkerResponse) !void {
        self.stats.entries_scanned += 1;
        self.stats.raw_entries_scanned += 1;
        self.stats.mismatches += 1;
        try self.addSample(
            word,
            response.kind orelse "mismatch",
            response.summary orelse "html mismatch",
            response.our orelse "",
            response.parsoid orelse "",
        );
        self.progress.update(self.stats);
    }

    fn recordWorkerError(self: *Auditor, word: []const u8, response: WorkerResponse) !void {
        self.stats.entries_scanned += 1;
        self.stats.raw_entries_scanned += 1;
        self.stats.worker_errors += 1;
        try self.addSample(
            word,
            response.kind orelse "worker_error",
            response.summary orelse "worker failed",
            response.our orelse "",
            response.parsoid orelse "",
        );
        self.progress.update(self.stats);
    }

    fn addSample(self: *Auditor, word: []const u8, kind: []const u8, summary: []const u8, our: []const u8, parsoid: []const u8) !void {
        try self.samples.append(self.allocator, .{
            .word = try self.allocator.dupe(u8, word),
            .kind = try self.allocator.dupe(u8, kind),
            .summary = try self.allocator.dupe(u8, summary),
            .our = try self.allocator.dupe(u8, our),
            .parsoid = try self.allocator.dupe(u8, parsoid),
        });
    }

    fn finish(self: *Auditor) !AuditStats {
        self.progress.finish(self.stats);
        try self.writeReport();
        try writeReportFile(self.io, self.options.report_path, self.report.written());
        return self.stats;
    }

    fn writeReport(self: *Auditor) !void {
        try self.report.writer.print(
            "Parsoid comparison audit report\n" ++
                "db: {s}\n" ++
                "limit: ",
            .{self.options.db_path},
        );
        if (self.options.limit_entries) |limit| {
            try self.report.writer.print("{d}\n", .{limit});
        } else {
            try self.report.writer.print("all\n", .{});
        }
        try self.report.writer.print(
            "word_filter: {s}\n" ++
                "worker: {s}\n\n" ++
                "Summary\n" ++
                "-------\n" ++
                "entries_scanned: {d}\n" ++
                "raw_entries_scanned: {d}\n" ++
                "compared_entries: {d}\n" ++
                "alias_entries_skipped: {d}\n" ++
                "renderer_errors: {d}\n" ++
                "mismatches: {d}\n" ++
                "worker_errors: {d}\n\n",
            .{
                self.options.word_filter orelse "<none>",
                self.options.worker_path,
                self.stats.entries_scanned,
                self.stats.raw_entries_scanned,
                self.stats.compared_entries,
                self.stats.alias_entries_skipped,
                self.stats.renderer_errors,
                self.stats.mismatches,
                self.stats.worker_errors,
            },
        );

        if (self.samples.items.len == 0) {
            try self.report.writer.print("No failures recorded.\n", .{});
            return;
        }

        try self.report.writer.print("Failures\n--------\n", .{});
        for (self.samples.items, 0..) |sample, idx| {
            try self.report.writer.print(
                "{d}. [{s}] word={s}\nsummary: {s}\n",
                .{ idx + 1, sample.kind, sample.word, sample.summary },
            );
            if (sample.our.len != 0) try self.report.writer.print("ours: {s}\n", .{sample.our});
            if (sample.parsoid.len != 0) try self.report.writer.print("parsoid: {s}\n", .{sample.parsoid});
            try self.report.writer.print("\n", .{});
        }
    }
};

pub fn auditDictionary(io: std.Io, allocator: std.mem.Allocator, options: Options) !AuditStats {
    var auditor = try Auditor.init(allocator, io, options);
    defer auditor.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for (auditor.dict.entries, 0..) |_, idx| {
        if (options.limit_entries) |limit| {
            if (auditor.stats.entries_scanned >= limit) break;
        }

        const entry = auditor.dict.entryAt(@intCast(idx));
        if (options.word_filter) |word_filter| {
            if (!std.mem.eql(u8, entry.word(), word_filter)) continue;
        }

        if (!entry.hasRaw()) {
            auditor.recordAliasSkipped();
            continue;
        }

        const raw = entry.rawEnglishAlloc(arena.allocator()) catch |err| {
            try auditor.recordRendererError(entry.word(), @errorName(err));
            _ = arena.reset(.retain_capacity);
            continue;
        } orelse {
            auditor.recordAliasSkipped();
            _ = arena.reset(.retain_capacity);
            continue;
        };

        const rendered_sections = html_render.renderEnglishSectionWithOptionsAlloc(arena.allocator(), raw, .{
            .strict = true,
            .link_resolver = .{
                .context = @ptrCast(&auditor.dict),
                .resolve = resolveRendererLink,
            },
        }) catch |err| {
            try auditor.recordRendererError(entry.word(), @errorName(err));
            _ = arena.reset(.retain_capacity);
            continue;
        };

        const request_sections = try arena.allocator().alloc(RequestSection, rendered_sections.len);
        for (rendered_sections, 0..) |section, i| {
            request_sections[i] = .{
                .title = section.title,
                .level = section.level,
                .html = section.html,
            };
        }

        const response = auditor.worker.compare(arena.allocator(), .{
            .title = entry.word(),
            .raw = raw,
            .sections = request_sections,
        }) catch |err| {
            try auditor.recordWorkerError(entry.word(), .{
                .ok = false,
                .kind = "worker_error",
                .summary = @errorName(err),
            });
            _ = arena.reset(.retain_capacity);
            continue;
        };

        if (response.ok) {
            auditor.recordCompared();
        } else if (response.kind != null and std.mem.eql(u8, response.kind.?, "mismatch")) {
            try auditor.recordMismatch(entry.word(), response);
        } else {
            try auditor.recordWorkerError(entry.word(), response);
        }

        _ = arena.reset(.retain_capacity);
    }

    return auditor.finish();
}

fn resolveRendererLink(context: *const anyopaque, allocator: std.mem.Allocator, term: []const u8) anyerror!?[]const u8 {
    const dict: *const decoder.Dictionary = @ptrCast(@alignCast(context));
    return dict.resolveLinkTargetAlloc(allocator, term);
}

fn countTargetEntries(dict: *const decoder.Dictionary, options: Options) usize {
    if (options.word_filter != null) return 1;
    return @min(options.limit_entries orelse dict.entries.len, dict.entries.len);
}

fn parseOptions(_: std.mem.Allocator, args: []const []const u8) !Options {
    var options = Options{
        .worker_path = "tools/parsoid-worker/worker.mjs",
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            options.db_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--report") and i + 1 < args.len) {
            options.report_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            options.limit_entries = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--word") and i + 1 < args.len) {
            options.word_filter = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--node") and i + 1 < args.len) {
            options.node_cmd = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--worker") and i + 1 < args.len) {
            options.worker_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else {
            return error.InvalidArgument;
        }
    }

    return options;
}

fn printUsage() void {
    std.debug.print(
        \\dict-parsoid-test [--db data/enwiktionary.bin]
        \\                  [--report data/parsoid-audit-report.txt]
        \\                  [--limit 100]
        \\                  [--word entry]
        \\                  [--node node]
        \\                  [--worker tools/parsoid-worker/worker.mjs]
        \\
    , .{});
}

fn writeReportFile(io: std.Io, report_path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, report_path, "-")) {
        std.debug.print("{s}", .{bytes});
        return;
    }

    var file = try std.Io.Dir.cwd().createFile(io, report_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn writeTestFile(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var file = try dir.createFile(std.testing.io, name, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, contents, 0);
}

fn tempPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "parseOptions parses worker and word flags" {
    const args = [_][]const u8{ "--db", "dict.bin", "--word", "ring", "--worker", "worker.mjs" };
    const options = try parseOptions(std.testing.allocator, &args);
    try std.testing.expectEqualStrings("dict.bin", options.db_path);
    try std.testing.expectEqualStrings("ring", options.word_filter.?);
    try std.testing.expectEqualStrings("worker.mjs", options.worker_path);
}

test "auditDictionary records mismatches from fake worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>ring</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# {{plural of|en|ring}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;
    const worker_script =
        \\import readline from "node:readline";
        \\const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        \\for await (const line of rl) {
        \\  const req = JSON.parse(line);
        \\  if (req.title === "ring") {
        \\    process.stdout.write(JSON.stringify({ ok: false, kind: "mismatch", summary: "forced mismatch", our: "ours", parsoid: "theirs" }) + "\n");
        \\  } else {
        \\    process.stdout.write(JSON.stringify({ ok: true }) + "\n");
        \\  }
        \\}
    ;

    try writeTestFile(tmp.dir, "sample.xml", xml);
    try writeTestFile(tmp.dir, "fake-worker.mjs", worker_script);

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "sample.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "parsoid-report.txt");
    defer std.testing.allocator.free(report_rel);
    const worker_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "fake-worker.mjs");
    defer std.testing.allocator.free(worker_rel);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
    });

    const stats = try auditDictionary(std.testing.io, std.testing.allocator, .{
        .db_path = db_rel,
        .report_path = report_rel,
        .limit_entries = 1,
        .node_cmd = "node",
        .worker_path = worker_rel,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.entries_scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.mismatches);
    try std.testing.expectEqual(@as(usize, 0), stats.worker_errors);
}
