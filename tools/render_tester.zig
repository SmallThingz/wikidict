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

    const options = try parseOptions(args[1..]);
    const stats = try auditDictionary(init.io, init.gpa, options);

    std.debug.print(
        "strict render audit\n" ++
            "db={s}\n" ++
            "report={s}\n" ++
            "entries_scanned={d}\n" ++
            "raw_entries_scanned={d}\n" ++
            "rendered_entries={d}\n" ++
            "alias_entries_skipped={d}\n" ++
            "strict_failures={d}\n" ++
            "unexpected_errors={d}\n",
        .{
            options.db_path,
            options.report_path,
            stats.entries_scanned,
            stats.raw_entries_scanned,
            stats.rendered_entries,
            stats.alias_entries_skipped,
            stats.strict_failures,
            stats.unexpected_errors,
        },
    );

    if (stats.failures() != 0) return error.RenderAuditFailed;
}

const Options = struct {
    db_path: []const u8 = "data/enwiktionary.bin",
    report_path: []const u8 = "data/render-report.txt",
    start_entry: usize = 0,
    limit_entries: ?usize = null,
    thread_count: ?usize = null,
    sample_limit: usize = 4,
};

pub const AuditStats = struct {
    entries_scanned: usize = 0,
    raw_entries_scanned: usize = 0,
    rendered_entries: usize = 0,
    alias_entries_skipped: usize = 0,
    strict_failures: usize = 0,
    unexpected_errors: usize = 0,

    pub fn failures(self: AuditStats) usize {
        return self.strict_failures + self.unexpected_errors;
    }
};

const RenderProgress = struct {
    const refresh_interval_ns = std.time.ns_per_s / 10;

    total_entries: usize,
    mutex: std.Io.Mutex = .init,
    last_percent: u8 = 255,
    last_render_ns: i96 = 0,

    fn init(total_entries: usize) RenderProgress {
        return .{ .total_entries = total_entries };
    }

    fn maybeRender(self: *RenderProgress, auditor: *const Auditor, processed_entries: usize) void {
        if (builtin.is_test) return;
        if (self.total_entries == 0) return;
        if ((processed_entries & 1023) != 0 and processed_entries != self.total_entries) return;

        self.mutex.lockUncancelable(auditor.io);
        defer self.mutex.unlock(auditor.io);

        const percent = @as(u8, @intCast(@min(100, (processed_entries * 100) / self.total_entries)));
        const now_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
        if (percent == self.last_percent and now_ns - self.last_render_ns < refresh_interval_ns) return;

        self.last_percent = percent;
        self.last_render_ns = now_ns;

        const raw_entries = auditor.raw_entries_scanned.load(.monotonic);
        const failures = auditor.strict_failures.load(.monotonic) + auditor.unexpected_errors.load(.monotonic);

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        std.debug.print(
            "\rrender audit [{s}] {d:>3}% strict render ({d}/{d} entries, {d} raw, {d} failures)",
            .{ &bar, percent, processed_entries, self.total_entries, raw_entries, failures },
        );
    }

    fn finish(self: *RenderProgress, auditor: *const Auditor) void {
        if (builtin.is_test) return;
        self.maybeRender(auditor, auditor.entries_scanned.load(.monotonic));
        std.debug.print("\n", .{});
    }
};

const IssueSample = struct {
    word: []u8,
    line: []u8,
    line_number: usize,

    fn deinit(self: *IssueSample, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
        allocator.free(self.line);
    }
};

const IssueBucket = struct {
    kind: html_render.RenderIssueKind,
    section_title: []u8,
    detail: []u8,
    count: usize = 0,
    samples: std.ArrayListUnmanaged(IssueSample) = .empty,

    fn deinit(self: *IssueBucket, allocator: std.mem.Allocator) void {
        allocator.free(self.section_title);
        allocator.free(self.detail);
        for (self.samples.items) |*sample| sample.deinit(allocator);
        self.samples.deinit(allocator);
    }
};

const UnexpectedSample = struct {
    word: []u8,

    fn deinit(self: *UnexpectedSample, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
    }
};

const UnexpectedBucket = struct {
    count: usize = 0,
    samples: std.ArrayListUnmanaged(UnexpectedSample) = .empty,

    fn deinit(self: *UnexpectedBucket, allocator: std.mem.Allocator) void {
        for (self.samples.items) |*sample| sample.deinit(allocator);
        self.samples.deinit(allocator);
    }
};

const IssueBucketView = struct {
    bucket: *const IssueBucket,
};

const CountView = struct {
    key: []const u8,
    count: usize,
};

const UnexpectedBucketView = struct {
    name: []const u8,
    bucket: *const UnexpectedBucket,
};

const Auditor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dict: decoder.Dictionary,
    total_entries: usize,
    progress: RenderProgress,
    state_mutex: std.Io.Mutex = .init,
    report: std.Io.Writer.Allocating,
    issue_buckets: std.StringHashMapUnmanaged(IssueBucket) = .empty,
    section_failures: std.StringHashMapUnmanaged(usize) = .empty,
    unexpected_buckets: std.StringHashMapUnmanaged(UnexpectedBucket) = .empty,
    fatal_error: ?anyerror = null,
    entries_scanned: std.atomic.Value(usize) = .init(0),
    raw_entries_scanned: std.atomic.Value(usize) = .init(0),
    rendered_entries: std.atomic.Value(usize) = .init(0),
    strict_failures: std.atomic.Value(usize) = .init(0),
    unexpected_errors: std.atomic.Value(usize) = .init(0),

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Auditor {
        var dict = try decoder.openDictionary(allocator, io, options.db_path);
        errdefer dict.deinit();

        const start = @min(options.start_entry, dict.entries.len);
        const remaining = dict.entries.len - start;
        const total_entries = @min(options.limit_entries orelse remaining, remaining);
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dict = dict,
            .total_entries = total_entries,
            .progress = RenderProgress.init(total_entries),
            .report = .init(allocator),
        };
    }

    fn deinit(self: *Auditor) void {
        var issue_it = self.issue_buckets.iterator();
        while (issue_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.issue_buckets.deinit(self.allocator);

        var section_it = self.section_failures.iterator();
        while (section_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.section_failures.deinit(self.allocator);

        var unexpected_it = self.unexpected_buckets.iterator();
        while (unexpected_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.unexpected_buckets.deinit(self.allocator);

        self.report.deinit();
        self.dict.deinit();
    }

    fn recordAliasSkipped(self: *Auditor) void {
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        self.progress.maybeRender(self, processed);
    }

    fn recordRendered(self: *Auditor) void {
        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.rendered_entries.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        self.progress.maybeRender(self, processed);
    }

    fn recordStrictFailure(self: *Auditor, word: []const u8, issue: html_render.RenderIssue) !void {
        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.strict_failures.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        defer self.progress.maybeRender(self, processed);

        const section_title = displaySectionTitle(issue.section_title);
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f{s}", .{
            @tagName(issue.kind),
            section_title,
            issue.detail,
        });
        errdefer self.allocator.free(key);
        const word_copy = try self.allocator.dupe(u8, word);
        errdefer self.allocator.free(word_copy);
        const line_copy = try self.allocator.dupe(u8, excerptWindow(issue.line, 0, 240));
        errdefer self.allocator.free(line_copy);

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const section_key = try self.allocator.dupe(u8, section_title);
        errdefer self.allocator.free(section_key);
        const section_gop = try self.section_failures.getOrPut(self.allocator, section_key);
        if (section_gop.found_existing) {
            self.allocator.free(section_key);
        } else {
            section_gop.value_ptr.* = 0;
        }
        section_gop.value_ptr.* += 1;

        const gop = try self.issue_buckets.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .kind = issue.kind,
                .section_title = try self.allocator.dupe(u8, section_title),
                .detail = try self.allocator.dupe(u8, issue.detail),
            };
        } else {
            self.allocator.free(key);
        }

        gop.value_ptr.count += 1;
        if (gop.value_ptr.samples.items.len < self.options.sample_limit) {
            try gop.value_ptr.samples.append(self.allocator, .{
                .word = word_copy,
                .line = line_copy,
                .line_number = issue.line_number,
            });
        } else {
            self.allocator.free(word_copy);
            self.allocator.free(line_copy);
        }
    }

    fn recordUnexpectedError(self: *Auditor, word: []const u8, err: anyerror) !void {
        if (err == error.OutOfMemory) {
            self.noteFatal(err);
            return;
        }

        _ = self.raw_entries_scanned.fetchAdd(1, .monotonic);
        _ = self.unexpected_errors.fetchAdd(1, .monotonic);
        const processed = self.entries_scanned.fetchAdd(1, .monotonic) + 1;
        defer self.progress.maybeRender(self, processed);

        const error_name = @errorName(err);
        const key = try self.allocator.dupe(u8, error_name);
        errdefer self.allocator.free(key);
        const word_copy = try self.allocator.dupe(u8, word);
        errdefer self.allocator.free(word_copy);

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const gop = try self.unexpected_buckets.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        } else {
            self.allocator.free(key);
        }
        gop.value_ptr.count += 1;
        if (gop.value_ptr.samples.items.len < self.options.sample_limit) {
            try gop.value_ptr.samples.append(self.allocator, .{ .word = word_copy });
        } else {
            self.allocator.free(word_copy);
        }
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
        return stats;
    }

    fn snapshot(self: *const Auditor) AuditStats {
        const entries_scanned = self.entries_scanned.load(.monotonic);
        const raw_entries_scanned = self.raw_entries_scanned.load(.monotonic);
        const rendered_entries = self.rendered_entries.load(.monotonic);
        return .{
            .entries_scanned = entries_scanned,
            .raw_entries_scanned = raw_entries_scanned,
            .rendered_entries = rendered_entries,
            .alias_entries_skipped = entries_scanned - raw_entries_scanned,
            .strict_failures = self.strict_failures.load(.monotonic),
            .unexpected_errors = self.unexpected_errors.load(.monotonic),
        };
    }

    fn writeReport(self: *Auditor, stats: AuditStats) !void {
        try self.report.writer.print(
            "Strict render audit report\n" ++
                "db: {s}\n" ++
                "start: {d}\n" ++
                "limit: ",
            .{
                self.options.db_path,
                self.options.start_entry,
            },
        );
        if (self.options.limit_entries) |limit| {
            try self.report.writer.print("{d}\n", .{limit});
        } else {
            try self.report.writer.print("all\n", .{});
        }
        try self.report.writer.print(
            "threads: {d}\n" ++
                "sample_limit: {d}\n\n" ++
                "Summary\n" ++
                "-------\n" ++
                "entries_scanned: {d}\n" ++
                "raw_entries_scanned: {d}\n" ++
                "rendered_entries: {d}\n" ++
                "alias_entries_skipped: {d}\n" ++
                "strict_failures: {d}\n" ++
                "unexpected_errors: {d}\n\n",
            .{
                resolvedThreadCount(self.total_entries, self.options.thread_count),
                self.options.sample_limit,
                stats.entries_scanned,
                stats.raw_entries_scanned,
                stats.rendered_entries,
                stats.alias_entries_skipped,
                stats.strict_failures,
                stats.unexpected_errors,
            },
        );

        try self.writeKindSummary();
        try self.writeSectionSummary();
        try self.writeIssueBuckets();
        try self.writeUnexpectedBuckets();

        if (stats.failures() == 0) {
            try self.report.writer.print("No render failures found.\n", .{});
        }

        try writeReportFile(self.io, self.options.report_path, self.report.written());
    }

    fn writeKindSummary(self: *Auditor) !void {
        var counts = [_]usize{0} ** std.meta.fields(html_render.RenderIssueKind).len;
        var it = self.issue_buckets.iterator();
        while (it.next()) |entry| {
            counts[@intFromEnum(entry.value_ptr.kind)] += entry.value_ptr.count;
        }

        try self.report.writer.print("Strict Failures By Kind\n-----------------------\n", .{});
        inline for (std.meta.fields(html_render.RenderIssueKind), 0..) |field, idx| {
            try self.report.writer.print("{s}: {d}\n", .{ field.name, counts[idx] });
        }
        try self.report.writer.print("\n", .{});
    }

    fn writeSectionSummary(self: *Auditor) !void {
        var items: std.ArrayList(CountView) = .empty;
        defer items.deinit(self.allocator);

        var it = self.section_failures.iterator();
        while (it.next()) |entry| {
            try items.append(self.allocator, .{
                .key = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }

        std.mem.sort(CountView, items.items, {}, lessThanCountView);

        try self.report.writer.print("Top Failing Sections\n--------------------\n", .{});
        if (items.items.len == 0) {
            try self.report.writer.print("none\n\n", .{});
            return;
        }

        const limit = @min(@as(usize, 24), items.items.len);
        for (items.items[0..limit], 0..) |item, idx| {
            try self.report.writer.print("{d:>2}. {s} ({d})\n", .{ idx + 1, item.key, item.count });
        }
        try self.report.writer.print("\n", .{});
    }

    fn writeIssueBuckets(self: *Auditor) !void {
        var items: std.ArrayList(IssueBucketView) = .empty;
        defer items.deinit(self.allocator);

        var it = self.issue_buckets.iterator();
        while (it.next()) |entry| {
            try items.append(self.allocator, .{ .bucket = entry.value_ptr });
        }

        std.mem.sort(IssueBucketView, items.items, {}, lessThanIssueBucketView);

        try self.report.writer.print("Strict Failure Groups\n---------------------\n", .{});
        if (items.items.len == 0) {
            try self.report.writer.print("none\n\n", .{});
            return;
        }

        for (items.items, 0..) |view, idx| {
            const bucket = view.bucket;
            try self.report.writer.print(
                "{d:>3}. [{s}] section={s} detail={s}\ncount: {d}\n",
                .{
                    idx + 1,
                    @tagName(bucket.kind),
                    bucket.section_title,
                    bucket.detail,
                    bucket.count,
                },
            );
            for (bucket.samples.items) |sample| {
                try self.report.writer.print(
                    "  - word={s} line={d} text={s}\n",
                    .{
                        sample.word,
                        sample.line_number,
                        sample.line,
                    },
                );
            }
            try self.report.writer.print("\n", .{});
        }
    }

    fn writeUnexpectedBuckets(self: *Auditor) !void {
        var items: std.ArrayList(UnexpectedBucketView) = .empty;
        defer items.deinit(self.allocator);

        var it = self.unexpected_buckets.iterator();
        while (it.next()) |entry| {
            try items.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .bucket = entry.value_ptr,
            });
        }

        std.mem.sort(UnexpectedBucketView, items.items, {}, lessThanUnexpectedBucketView);

        try self.report.writer.print("Unexpected Renderer Errors\n--------------------------\n", .{});
        if (items.items.len == 0) {
            try self.report.writer.print("none\n\n", .{});
            return;
        }

        for (items.items, 0..) |view, idx| {
            try self.report.writer.print("{d:>2}. {s} ({d})\n", .{ idx + 1, view.name, view.bucket.count });
            for (view.bucket.samples.items) |sample| {
                try self.report.writer.print("  - word={s}\n", .{sample.word});
            }
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

    const thread_count = resolvedThreadCount(auditor.total_entries, options.thread_count);
    if (thread_count == 1) {
        renderWorkerMain(.{
            .auditor = &auditor,
            .start = options.start_entry,
            .end = options.start_entry + auditor.total_entries,
        });
    } else {
        const workers = try allocator.alloc(std.Thread, thread_count);
        defer allocator.free(workers);

        var start: usize = options.start_entry;
        for (workers, 0..) |*worker, idx| {
            const end = options.start_entry + partitionEnd(auditor.total_entries, thread_count, idx);
            worker.* = try std.Thread.spawn(.{}, renderWorkerMain, .{
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

    if (auditor.fatal()) |err| return err;
    return try auditor.finish();
}

fn renderWorkerMain(args: WorkerArgs) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    for (args.start..args.end) |idx| {
        if (args.auditor.fatal() != null) return;

        const entry = args.auditor.dict.entryAt(@intCast(idx));
        if (!entry.hasRaw()) {
            args.auditor.recordAliasSkipped();
            continue;
        }

        var issue: html_render.RenderIssue = .{};
        const raw = entry.rawEnglishAlloc(arena.allocator()) catch |err| {
            args.auditor.recordUnexpectedError(entry.word(), err) catch |fatal| args.auditor.noteFatal(fatal);
            _ = arena.reset(.retain_capacity);
            continue;
        } orelse {
            args.auditor.recordAliasSkipped();
            _ = arena.reset(.retain_capacity);
            continue;
        };

        _ = html_render.renderEnglishSectionWithOptionsAlloc(arena.allocator(), raw, .{
            .strict = true,
            .issue = &issue,
        }) catch |err| {
            if (err == error.StrictRenderFailure) {
                args.auditor.recordStrictFailure(entry.word(), issue) catch |fatal| args.auditor.noteFatal(fatal);
            } else {
                args.auditor.recordUnexpectedError(entry.word(), err) catch |fatal| args.auditor.noteFatal(fatal);
            }
            _ = arena.reset(.retain_capacity);
            continue;
        };

        args.auditor.recordRendered();
        _ = arena.reset(.retain_capacity);
    }
}

fn partitionEnd(total: usize, part_count: usize, part_index: usize) usize {
    return @divTrunc(total * (part_index + 1), part_count);
}

fn resolvedThreadCount(total_entries: usize, thread_override: ?usize) usize {
    if (builtin.single_threaded or total_entries < 64) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), @min(total_entries, requested));
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), @min(total_entries, cpu_count));
}

fn displaySectionTitle(title: []const u8) []const u8 {
    return if (title.len == 0) "<lead>" else title;
}

fn excerptWindow(text: []const u8, center: usize, width: usize) []const u8 {
    if (text.len <= width) return text;
    const half = width / 2;
    const start = center -| half;
    const end = @min(text.len, start + width);
    return text[start..end];
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

fn lessThanCountView(_: void, left: CountView, right: CountView) bool {
    if (left.count != right.count) return left.count > right.count;
    return std.mem.order(u8, left.key, right.key) == .lt;
}

fn lessThanIssueBucketView(_: void, left: IssueBucketView, right: IssueBucketView) bool {
    if (left.bucket.count != right.bucket.count) return left.bucket.count > right.bucket.count;
    const left_kind = @tagName(left.bucket.kind);
    const right_kind = @tagName(right.bucket.kind);
    if (!std.mem.eql(u8, left_kind, right_kind)) return std.mem.order(u8, left_kind, right_kind) == .lt;
    if (!std.mem.eql(u8, left.bucket.section_title, right.bucket.section_title)) {
        return std.mem.order(u8, left.bucket.section_title, right.bucket.section_title) == .lt;
    }
    return std.mem.order(u8, left.bucket.detail, right.bucket.detail) == .lt;
}

fn lessThanUnexpectedBucketView(_: void, left: UnexpectedBucketView, right: UnexpectedBucketView) bool {
    if (left.bucket.count != right.bucket.count) return left.bucket.count > right.bucket.count;
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
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
        } else if (std.mem.eql(u8, arg, "--samples") and i + 1 < args.len) {
            options.sample_limit = try std.fmt.parseInt(usize, args[i + 1], 10);
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
        \\dict-render-test [--db data/enwiktionary.bin]
        \\                 [--report data/render-report.txt]
        \\                 [--start 0]
        \\                 [--limit 10000]
        \\                 [--threads N]
        \\                 [--samples 4]
        \\
    , .{});
}

fn writeTestFile(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var file = try dir.createFile(std.testing.io, name, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, contents, 0);
}

fn tempPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "auditDictionary succeeds on supported renderer input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>ring</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# {{lb|en|physical}} A [[round]] object.
        \\## {{ux|en|a gold ring}}
        \\====Derived terms====
        \\{{col4|en|wedding ring|ring finger}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    try writeTestFile(tmp.dir, "sample.xml", xml);

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "sample.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "render-report.txt");
    defer std.testing.allocator.free(report_rel);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
    });

    const stats = try auditDictionary(std.testing.io, std.testing.allocator, .{
        .db_path = db_rel,
        .report_path = report_rel,
        .thread_count = null,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.entries_scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.raw_entries_scanned);
    try std.testing.expectEqual(@as(usize, 1), stats.rendered_entries);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "auditDictionary reports strict renderer failures with detail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>broken</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# {{totally-unsupported-template|en|broken}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    try writeTestFile(tmp.dir, "sample.xml", xml);

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "sample.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "render-report.txt");
    defer std.testing.allocator.free(report_rel);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
    });

    const stats = try auditDictionary(std.testing.io, std.testing.allocator, .{
        .db_path = db_rel,
        .report_path = report_rel,
        .thread_count = 2,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.strict_failures);
    try std.testing.expectEqual(@as(usize, 0), stats.unexpected_errors);
}

test "parseOptions parses explicit thread and sample flags" {
    const args = [_][]const u8{ "--db", "dict.bin", "--threads", "3", "--samples", "7" };
    const options = try parseOptions(&args);
    try std.testing.expectEqualStrings("dict.bin", options.db_path);
    try std.testing.expectEqual(@as(?usize, 3), options.thread_count);
    try std.testing.expectEqual(@as(usize, 7), options.sample_limit);
}
