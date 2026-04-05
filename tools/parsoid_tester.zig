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
    start_entry: usize = 0,
    thread_count: ?usize = null,
    word_filter: ?[]const u8 = null,
    prime_cache: bool = false,
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
    const refresh_interval_ns = std.time.ns_per_s / 5;

    total_entries: usize,
    mutex: std.Io.Mutex = .init,
    last_percent: u8 = 255,
    last_render_ns: i96 = 0,

    fn init(total_entries: usize) Progress {
        return .{ .total_entries = total_entries };
    }

    fn maybeRender(self: *Progress, auditor: *const Auditor, processed_entries: usize) void {
        if (builtin.is_test or self.total_entries == 0) return;
        const step = progressStep(self.total_entries);
        if ((processed_entries % step) != 0 and processed_entries != self.total_entries) return;

        self.mutex.lockUncancelable(auditor.io);
        defer self.mutex.unlock(auditor.io);

        const percent = @as(u8, @intCast(@min(100, (processed_entries * 100) / self.total_entries)));
        const now_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
        if (percent == self.last_percent and now_ns - self.last_render_ns < refresh_interval_ns and processed_entries != self.total_entries) return;
        self.last_percent = percent;
        self.last_render_ns = now_ns;

        const mismatches = auditor.mismatches.load(.monotonic);
        const worker_errors = auditor.worker_errors.load(.monotonic);

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        std.debug.print(
            "\rparsoid audit [{s}] {d:>3}% compare rendered sections ({d}/{d} entries, {d} mismatches, {d} worker errors)",
            .{
                &bar,
                percent,
                processed_entries,
                self.total_entries,
                mismatches,
                worker_errors,
            },
        );
    }

    fn progressStep(total_entries: usize) usize {
        if (total_entries <= 64) return 8;
        if (total_entries <= 256) return 16;
        if (total_entries <= 1024) return 32;
        if (total_entries <= 4096) return 64;
        return 1024;
    }

    fn finish(self: *Progress, auditor: *const Auditor) void {
        if (builtin.is_test) return;
        self.maybeRender(auditor, auditor.entries_scanned.load(.monotonic));
        std.debug.print("\n", .{});
    }
};

const RequestSection = struct {
    title: []const u8,
    level: u8,
    html: []const u8,
};

const WorkerRequest = struct {
    mode: []const u8 = "compare",
    title: []const u8,
    raw: []const u8,
    sections: []const RequestSection,
};

const WorkerResponse = struct {
    ok: bool,
    cached: ?bool = null,
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
    stdout_buffer: [512 * 1024]u8 = undefined,

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
    total_entries: usize,
    progress: Progress,
    state_mutex: std.Io.Mutex = .init,
    report: std.Io.Writer.Allocating,
    samples: std.ArrayList(FailureSample) = .empty,
    fatal_error: ?anyerror = null,
    entries_scanned: std.atomic.Value(usize) = .init(0),
    raw_entries_scanned: std.atomic.Value(usize) = .init(0),
    compared_entries: std.atomic.Value(usize) = .init(0),
    renderer_errors: std.atomic.Value(usize) = .init(0),
    mismatches: std.atomic.Value(usize) = .init(0),
    worker_errors: std.atomic.Value(usize) = .init(0),

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Auditor {
        var dict = try decoder.openDictionary(allocator, io, options.db_path);
        errdefer dict.deinit();

        const total_entries = countTargetEntries(&dict, options);
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dict = dict,
            .total_entries = total_entries,
            .report = .init(allocator),
            .progress = Progress.init(total_entries),
        };
    }

    fn deinit(self: *Auditor) void {
        for (self.samples.items) |*sample| sample.deinit(self.allocator);
        self.samples.deinit(self.allocator);
        self.report.deinit();
        self.dict.deinit();
    }

    fn recordAliasSkipped(self: *Auditor) void {
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        self.progress.maybeRender(self, processed);
    }

    fn recordCompared(self: *Auditor) void {
        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.compared_entries.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        self.progress.maybeRender(self, processed);
    }

    fn recordRendererError(self: *Auditor, word: []const u8, summary: []const u8) !void {
        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.renderer_errors.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        try self.addSample(word, "renderer_error", summary, "", "");
        self.progress.maybeRender(self, processed);
    }

    fn recordMismatch(self: *Auditor, word: []const u8, response: WorkerResponse) !void {
        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.compared_entries.fetchAdd(1, .monotonic);
        _ = self.mismatches.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        try self.addSample(
            word,
            response.kind orelse "mismatch",
            response.summary orelse "html mismatch",
            response.our orelse "",
            response.parsoid orelse "",
        );
        self.progress.maybeRender(self, processed);
    }

    fn recordWorkerError(self: *Auditor, word: []const u8, response: WorkerResponse) !void {
        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.compared_entries.fetchAdd(1, .monotonic);
        _ = self.worker_errors.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        try self.addSample(
            word,
            response.kind orelse "worker_error",
            response.summary orelse "worker failed",
            response.our orelse "",
            response.parsoid orelse "",
        );
        self.progress.maybeRender(self, processed);
    }

    fn addSample(self: *Auditor, word: []const u8, kind: []const u8, summary: []const u8, our: []const u8, parsoid: []const u8) !void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.samples.append(self.allocator, .{
            .word = try self.allocator.dupe(u8, word),
            .kind = try self.allocator.dupe(u8, kind),
            .summary = try self.allocator.dupe(u8, summary),
            .our = try self.allocator.dupe(u8, our),
            .parsoid = try self.allocator.dupe(u8, parsoid),
        });
    }

    fn noteFatal(self: *Auditor, err: anyerror) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.fatal_error == null) self.fatal_error = err;
    }

    fn fatal(self: *Auditor) ?anyerror {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.fatal_error;
    }

    fn finish(self: *Auditor) !AuditStats {
        self.progress.finish(self);
        const stats = self.snapshot();
        try self.writeReport(stats);
        try writeReportFile(self.io, self.options.report_path, self.report.written());
        return stats;
    }

    fn snapshot(self: *const Auditor) AuditStats {
        const entries_scanned = self.entries_scanned.load(.monotonic);
        const raw_entries_scanned = self.raw_entries_scanned.load(.monotonic);
        return .{
            .entries_scanned = entries_scanned,
            .raw_entries_scanned = raw_entries_scanned,
            .compared_entries = self.compared_entries.load(.monotonic),
            .alias_entries_skipped = entries_scanned - raw_entries_scanned,
            .renderer_errors = self.renderer_errors.load(.monotonic),
            .mismatches = self.mismatches.load(.monotonic),
            .worker_errors = self.worker_errors.load(.monotonic),
        };
    }

    fn writeReport(self: *Auditor, stats: AuditStats) !void {
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
                "threads: {d}\n\n" ++
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
                resolvedThreadCount(self.total_entries, self.options.thread_count, self.options.prime_cache),
                stats.entries_scanned,
                stats.raw_entries_scanned,
                stats.compared_entries,
                stats.alias_entries_skipped,
                stats.renderer_errors,
                stats.mismatches,
                stats.worker_errors,
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

const WorkerArgs = struct {
    auditor: *Auditor,
    start: usize,
    end: usize,
};

pub fn auditDictionary(io: std.Io, allocator: std.mem.Allocator, options: Options) !AuditStats {
    var auditor = try Auditor.init(allocator, io, options);
    defer auditor.deinit();

    if (auditor.total_entries == 0) return try auditor.finish();

    if (options.word_filter != null) {
        auditWorkerMain(.{ .auditor = &auditor, .start = options.start_entry, .end = scanEntryEnd(&auditor.dict, options) });
    } else {
        const thread_count = resolvedThreadCount(auditor.total_entries, options.thread_count, options.prime_cache);
        if (thread_count == 1) {
            auditWorkerMain(.{ .auditor = &auditor, .start = options.start_entry, .end = scanEntryEnd(&auditor.dict, options) });
        } else {
            const workers = try allocator.alloc(std.Thread, thread_count);
            defer allocator.free(workers);

            var start = options.start_entry;
            for (workers, 0..) |*worker, idx| {
                const end = options.start_entry + partitionEnd(auditor.total_entries, thread_count, idx);
                worker.* = try std.Thread.spawn(.{}, auditWorkerMain, .{
                    WorkerArgs{
                        .auditor = &auditor,
                        .start = start,
                        .end = end,
                    },
                });
                start = end;
            }

            for (workers) |worker| worker.join();
        }
    }

    if (auditor.fatal()) |err| return err;
    return auditor.finish();
}

fn auditWorkerMain(args: WorkerArgs) void {
    var arena = std.heap.ArenaAllocator.init(args.auditor.allocator);
    defer arena.deinit();

    var worker = WorkerClient.init(args.auditor.allocator, args.auditor.io, args.auditor.options) catch |err| {
        args.auditor.noteFatal(err);
        return;
    };
    defer worker.deinit();

    for (args.start..args.end) |idx| {
        if (args.auditor.fatal() != null) return;

        const entry = args.auditor.dict.entryAt(@intCast(idx));
        if (args.auditor.options.word_filter) |word_filter| {
            if (!std.mem.eql(u8, entry.word(), word_filter)) continue;
        }

        if (!entry.hasRaw()) {
            args.auditor.recordAliasSkipped();
            _ = arena.reset(.retain_capacity);
            continue;
        }

        const raw = entry.rawEnglishAlloc(arena.allocator()) catch |err| {
            args.auditor.recordRendererError(entry.word(), @errorName(err)) catch |fatal| args.auditor.noteFatal(fatal);
            _ = arena.reset(.retain_capacity);
            continue;
        } orelse {
            args.auditor.recordAliasSkipped();
            _ = arena.reset(.retain_capacity);
            continue;
        };

        const audit_raw = stripAuditExcludedWikitextAlloc(arena.allocator(), raw) catch |err| {
            args.auditor.recordRendererError(entry.word(), @errorName(err)) catch |fatal| args.auditor.noteFatal(fatal);
            _ = arena.reset(.retain_capacity);
            continue;
        };

        const request_sections = if (args.auditor.options.prime_cache) blk: {
            break :blk &.{};
        } else blk: {
            var render_issue: html_render.RenderIssue = .{};
            const rendered_sections = html_render.renderEnglishSectionWithOptionsAlloc(arena.allocator(), audit_raw, .{
                .strict = true,
                .issue = &render_issue,
                .link_resolver = .{
                    .context = @ptrCast(&args.auditor.dict),
                    .resolve = resolveRendererLink,
                },
            }) catch |err| {
                if (err == error.StrictRenderFailure) {
                    const summary = std.fmt.allocPrint(arena.allocator(), "{s} section={s} line={d} detail={s}", .{
                        @errorName(err),
                        render_issue.section_title,
                        render_issue.line_number,
                        render_issue.detail,
                    }) catch @errorName(err);
                    args.auditor.recordRendererError(entry.word(), summary) catch |fatal| args.auditor.noteFatal(fatal);
                } else {
                    args.auditor.recordRendererError(entry.word(), @errorName(err)) catch |fatal| args.auditor.noteFatal(fatal);
                }
                _ = arena.reset(.retain_capacity);
                continue;
            };

            const sections = arena.allocator().alloc(RequestSection, rendered_sections.len) catch |err| {
                args.auditor.noteFatal(err);
                return;
            };
            for (rendered_sections, 0..) |section, i| {
                sections[i] = .{
                    .title = section.title,
                    .level = section.level,
                    .html = section.html,
                };
            }
            break :blk sections;
        };

        const response = worker.compare(arena.allocator(), .{
            .mode = if (args.auditor.options.prime_cache) "prime" else "compare",
            .title = entry.word(),
            .raw = audit_raw,
            .sections = request_sections,
        }) catch |err| {
            args.auditor.recordWorkerError(entry.word(), .{
                .ok = false,
                .kind = "worker_error",
                .summary = @errorName(err),
            }) catch |fatal| args.auditor.noteFatal(fatal);
            _ = arena.reset(.retain_capacity);
            continue;
        };

        if (response.ok) {
            args.auditor.recordCompared();
        } else if (response.kind != null and std.mem.eql(u8, response.kind.?, "mismatch")) {
            args.auditor.recordMismatch(entry.word(), response) catch |fatal| args.auditor.noteFatal(fatal);
        } else {
            args.auditor.recordWorkerError(entry.word(), response) catch |fatal| args.auditor.noteFatal(fatal);
        }

        _ = arena.reset(.retain_capacity);
    }
}

fn partitionEnd(total: usize, part_count: usize, part_index: usize) usize {
    return @divTrunc(total * (part_index + 1), part_count);
}

fn resolvedThreadCount(total_entries: usize, thread_override: ?usize, prime_cache: bool) usize {
    if (builtin.single_threaded or total_entries < 128) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), @min(total_entries, requested));
    _ = prime_cache;
    return 1;
}

fn stripAuditExcludedWikitextAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var skip_level: ?u8 = null;
    var skip_inline_quote = false;
    var quote_balance: isize = 0;
    var current_title: []const u8 = "";
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
        const trimmed = std.mem.trim(u8, raw_line, " \t");

        if (skip_inline_quote) {
            quote_balance += templateBalanceDelta(trimmed);
            if (quote_balance <= 0) {
                skip_inline_quote = false;
                quote_balance = 0;
            }
            continue;
        }

        if (parseHeadingLine(trimmed)) |heading| {
            if (skip_level) |level| {
                if (heading.level <= level) skip_level = null;
            }
            if (skip_level == null and isExcludedAuditHeading(heading.title)) {
                skip_level = heading.level;
            }
            current_title = heading.title;
        }

        if (skip_level != null) continue;
        if (startsExcludedAuditTemplate(trimmed)) {
            quote_balance = templateBalanceDelta(trimmed);
            skip_inline_quote = quote_balance > 0;
            continue;
        }
        if (startsExcludedAuditInlineTemplate(trimmed)) {
            quote_balance = templateBalanceDelta(trimmed);
            skip_inline_quote = quote_balance > 0;
            continue;
        }
        if (isExcludedAuditInlineLine(trimmed)) continue;
        if (shouldSkipAuditLine(current_title, trimmed)) continue;

        if (out.items.len != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, raw_line);
    }

    const stripped = try out.toOwnedSlice(allocator);
    defer allocator.free(stripped);
    return pruneEmptyAuditHeadingsAlloc(allocator, stripped);
}

const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

fn parseHeadingLine(line: []const u8) ?ParsedHeading {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 6 or trimmed[0] != '=') return null;

    var level: usize = 0;
    while (level < trimmed.len and trimmed[level] == '=') : (level += 1) {}
    if (level < 2 or level > 6) return null;

    var trailing: usize = 0;
    while (trailing < trimmed.len and trimmed[trimmed.len - 1 - trailing] == '=') : (trailing += 1) {}
    if (trailing != level) return null;
    if (trimmed.len <= level * 2) return null;

    const title = std.mem.trim(u8, trimmed[level .. trimmed.len - level], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(level), .title = title };
}

fn isExcludedAuditHeading(title: []const u8) bool {
    return headingMatches(title, "Pronunciation") or
        headingMatches(title, "Gallery") or
        headingMatches(title, "Quotations") or
        headingMatches(title, "References") or
        headingMatches(title, "Further reading") or
        headingMatches(title, "Conjugation") or
        headingMatches(title, "See also") or
        headingMatches(title, "Descendants");
}

fn headingMatches(title: []const u8, needle: []const u8) bool {
    var trimmed = std.mem.trim(u8, title, " \t");
    while (trimmed.len != 0 and std.ascii.isDigit(trimmed[trimmed.len - 1])) {
        trimmed = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
    }
    return std.ascii.eqlIgnoreCase(trimmed, needle);
}

fn isExcludedAuditInlineLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 5 or (trimmed[0] != '#' and trimmed[0] != '*')) return false;

    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] == '#' or trimmed[i] == '*' or trimmed[i] == ':' or trimmed[i] == ';')) : (i += 1) {}
    if (std.mem.indexOfScalar(u8, trimmed[0..i], '*') != null and trimmed[0] == '#') return true;
    const content = std.mem.trim(u8, trimmed[i..], " \t");
    return startsExcludedAuditTemplate(content);
}

fn startsExcludedAuditInlineTemplate(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 5 or (trimmed[0] != '#' and trimmed[0] != '*')) return false;

    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] == '#' or trimmed[i] == '*' or trimmed[i] == ':' or trimmed[i] == ';')) : (i += 1) {}
    const content = std.mem.trim(u8, trimmed[i..], " \t");
    return startsExcludedAuditTemplate(content);
}

fn shouldSkipAuditLine(section_title: []const u8, line: []const u8) bool {
    if (sectionTitleStartsWith(section_title, "Etymology")) {
        if (asciiStartsWithIgnoreCase(line, "Compare ")) return true;
        if (asciiStartsWithIgnoreCase(line, "More at ")) return true;
    }
    return false;
}

fn sectionTitleStartsWith(title: []const u8, prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, title, " \t");
    if (trimmed.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix);
}

fn isQuotationOnlyTemplate(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return false;
    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
    if (body.len == 0 or std.mem.indexOf(u8, body, "{{") != null or std.mem.indexOf(u8, body, "}}") != null) return false;
    return startsExcludedAuditTemplate(trimmed);
}

fn startsQuotationTemplate(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{")) return false;
    const body = std.mem.trim(u8, trimmed[2..], " \t");
    const end = std.mem.indexOfAny(u8, body, "|}") orelse body.len;
    const name = std.mem.trim(u8, body[0..end], " \t");
    return asciiStartsWithIgnoreCase(name, "quote-") or std.mem.startsWith(u8, name, "RQ:");
}

fn startsExcludedAuditTemplate(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{")) return false;
    const body = std.mem.trim(u8, trimmed[2..], " \t");
    const end = std.mem.indexOfAny(u8, body, "|}") orelse body.len;
    const name = std.mem.trim(u8, body[0..end], " \t");
    return startsQuotationTemplate(trimmed) or
        asciiStartsWithIgnoreCase(name, "U:") or
        asciiStartsWithIgnoreCase(name, "ref") or
        asciiStartsWithIgnoreCase(name, "see also") or
        asciiStartsWithIgnoreCase(name, "seeCites") or
        asciiStartsWithIgnoreCase(name, "seemoreCites") or
        asciiStartsWithIgnoreCase(name, "rfquote") or
        asciiStartsWithIgnoreCase(name, "rfquotek") or
        asciiStartsWithIgnoreCase(name, "rfquote-sense") or
        asciiStartsWithIgnoreCase(name, "examples") or
        asciiStartsWithIgnoreCase(name, "rootsee") or
        asciiStartsWithIgnoreCase(name, "catlangname") or
        asciiStartsWithIgnoreCase(name, "ctRenderF") or
        asciiStartsWithIgnoreCase(name, "construed with") or
        asciiStartsWithIgnoreCase(name, "in appendix") or
        asciiStartsWithIgnoreCase(name, "pseudo-loan") or
        asciiStartsWithIgnoreCase(name, "Webster 1913");
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn templateBalanceDelta(line: []const u8) isize {
    var delta: isize = 0;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == '{' and line[i + 1] == '{') {
            delta += 1;
            i += 1;
        } else if (line[i] == '}' and line[i + 1] == '}') {
            delta -= 1;
            i += 1;
        }
    }
    return delta;
}

fn pruneEmptyAuditHeadingsAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var split = std.mem.splitScalar(u8, raw, '\n');
    while (split.next()) |line| try lines.append(allocator, line);

    for (lines.items, 0..) |line, idx| {
        const raw_line = std.mem.trimEnd(u8, line, "\r");
        const heading = parseHeadingLine(raw_line) orelse {
            if (out.items.len != 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, raw_line);
            continue;
        };

        var keep = false;
        var lookahead = idx + 1;
        while (lookahead < lines.items.len) : (lookahead += 1) {
            const candidate_raw = std.mem.trimEnd(u8, lines.items[lookahead], "\r");
            const candidate_trimmed = std.mem.trim(u8, candidate_raw, " \t");
            if (parseHeadingLine(candidate_trimmed)) |candidate_heading| {
                if (candidate_heading.level <= heading.level) break;
                keep = true;
                break;
            }
            if (candidate_trimmed.len != 0) {
                keep = true;
                break;
            }
        }

        if (!keep) continue;
        if (out.items.len != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, raw_line);
    }

    return out.toOwnedSlice(allocator);
}

test "stripAuditExcludedWikitextAlloc removes excluded headings and inline quote lines" {
    const source =
        \\==English==
        \\===Pronunciation===
        \\* {{IPA|en|/x/}}
        \\===Gallery===
        \\<gallery>
        \\File:X.png|caption
        \\</gallery>
        \\===Noun===
        \\# kept
        \\#* {{U:en:be dead}}
        \\#* {{quote-book|en|text=drop}}
        \\====References====
        \\* ref
        \\====See also====
        \\* link
    ;

    const stripped = try stripAuditExcludedWikitextAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "Pronunciation") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "Gallery") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "quote-book") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "U:en:be dead") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "References") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "See also") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "# kept") != null);
}

test "stripAuditExcludedWikitextAlloc prunes headings emptied by stripping" {
    const source =
        \\==English==
        \\===Verb===
        \\# kept
        \\====Usage notes====
        \\* {{U:en:be dead}}
        \\====Synonyms====
        \\* kept too
    ;

    const stripped = try stripAuditExcludedWikitextAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "Usage notes") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "Synonyms") != null);
}

test "stripAuditExcludedWikitextAlloc removes conjugation, seeCites, quote bullets, and examples templates" {
    const source =
        \\==English==
        \\===Verb===
        \\# kept sense
        \\#* 1994, Citation head
        \\#*: Citation body
        \\#* {{seeCites|en}}
        \\{{examples|examples=
        \\* one
        \\}}
        \\{{rootsee|en|ine|deyḱ}}
        \\====Conjugation====
        \\{{en-conj|old=1}}
    ;

    const stripped = try stripAuditExcludedWikitextAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "Conjugation") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "seeCites") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "Citation head") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "{{examples|examples=") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "{{rootsee|") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "# kept sense") != null);
}

test "stripAuditExcludedWikitextAlloc removes etymology compare notes from audit input" {
    const source =
        \\==English==
        \\===Etymology===
        \\From {{m|en|test}}.
        \\
        \\Compare {{m|en|other}}.
        \\More at {{l|en|elsewhere}}.
        \\===Noun===
        \\# kept
    ;

    const stripped = try stripAuditExcludedWikitextAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "Compare ") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "More at ") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "From {{m|en|test}}.") != null);
}

test "stripAuditExcludedWikitextAlloc removes multiline inline quotation templates" {
    const source =
        \\==English==
        \\===Noun===
        \\# kept
        \\#* {{RQ:Orwell Animal Farm|6
        \\|passage=Example}}
        \\# still kept
    ;

    const stripped = try stripAuditExcludedWikitextAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "RQ:Orwell Animal Farm") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "# kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "# still kept") != null);
}

test "stripAuditExcludedWikitextAlloc removes audit-only inline maintenance templates" {
    const source =
        \\==English==
        \\===Noun===
        \\# kept
        \\# {{ref|en|test}}
        \\# {{see also|en|other}}
        \\# {{Webster 1913}}
        \\# {{pseudo-loan|en|fr|mot}}
        \\# still kept
    ;

    const stripped = try stripAuditExcludedWikitextAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "{{ref|") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "{{see also|") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "{{Webster 1913") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "{{pseudo-loan|") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "# kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "# still kept") != null);
}

fn resolveRendererLink(context: *const anyopaque, allocator: std.mem.Allocator, term: []const u8) anyerror!?[]const u8 {
    const dict: *const decoder.Dictionary = @ptrCast(@alignCast(context));
    return dict.resolveLinkTargetAlloc(allocator, term);
}

fn countTargetEntries(dict: *const decoder.Dictionary, options: Options) usize {
    if (options.word_filter) |word_filter| {
        var count: usize = 0;
        const scan_end = scanEntryEnd(dict, options);
        for (options.start_entry..scan_end) |idx| {
            const entry = dict.entryAt(@intCast(idx));
            if (std.mem.eql(u8, entry.word(), word_filter)) count += 1;
        }
        return count;
    }
    return scanEntryEnd(dict, options) -| options.start_entry;
}

fn scanEntryEnd(dict: *const decoder.Dictionary, options: Options) usize {
    const start = @min(options.start_entry, dict.entries.len);
    const remaining = dict.entries.len - start;
    return start + @min(options.limit_entries orelse remaining, remaining);
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
        } else if (std.mem.eql(u8, arg, "--start") and i + 1 < args.len) {
            options.start_entry = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            options.limit_entries = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--threads") and i + 1 < args.len) {
            options.thread_count = try std.fmt.parseInt(usize, args[i + 1], 10);
            if (options.thread_count.? == 0) return error.InvalidArgument;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--word") and i + 1 < args.len) {
            options.word_filter = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--prime-cache")) {
            options.prime_cache = true;
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
        \\                  [--start 0]
        \\                  [--limit 100]
        \\                  [--threads N]
        \\                  [--word entry]
        \\                  [--prime-cache]
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
    const args = [_][]const u8{ "--db", "dict.bin", "--word", "ring", "--worker", "worker.mjs", "--start", "12", "--threads", "3" };
    const options = try parseOptions(std.testing.allocator, &args);
    try std.testing.expectEqualStrings("dict.bin", options.db_path);
    try std.testing.expectEqualStrings("ring", options.word_filter.?);
    try std.testing.expectEqualStrings("worker.mjs", options.worker_path);
    try std.testing.expectEqual(@as(usize, 12), options.start_entry);
    try std.testing.expectEqual(@as(usize, 3), options.thread_count.?);
}

test "parseOptions parses prime-cache flag" {
    const args = [_][]const u8{ "--prime-cache" };
    const options = try parseOptions(std.testing.allocator, &args);
    try std.testing.expect(options.prime_cache);
}

test "resolvedThreadCount defaults to one worker for remote parsoid audits" {
    try std.testing.expectEqual(@as(usize, 1), resolvedThreadCount(1000, null, false));
    try std.testing.expectEqual(@as(usize, 1), resolvedThreadCount(1000, null, true));
    try std.testing.expectEqual(@as(usize, 4), resolvedThreadCount(1000, 4, false));
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
        \\# [[loop]]
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
