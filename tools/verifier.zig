const std = @import("std");
const builtin = @import("builtin");
const zxml = @import("zxml");

const encoder = @import("encoder");
const decoder = @import("decoder");
const tool_paths = @import("tool_paths");
const wikitext = encoder.wikitext;
const xml_decode = encoder.xml_decode;
const required_path = @import("required_path.zig");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = true,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

const VerifyProgress = struct {
    const refresh_interval_ns = std.time.ns_per_s / 20;

    total_input_bytes: usize,
    scanned_input_bytes: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    last_percent: u8 = 255,
    last_render_ns: i96 = 0,

    fn init(total_input_bytes: usize) VerifyProgress {
        return .{ .total_input_bytes = total_input_bytes };
    }

    fn scanAdvance(self: *VerifyProgress, input_bytes_delta: usize, pages: usize, compared: usize, failures: usize) void {
        const consumed_input_bytes = self.scanned_input_bytes.fetchAdd(input_bytes_delta, .monotonic) + input_bytes_delta;
        self.render(consumed_input_bytes, pages, compared, failures);
    }

    fn finish(self: *VerifyProgress, pages: usize, compared: usize, failures: usize) void {
        self.render(self.total_input_bytes, pages, compared, failures);
        if (!builtin.is_test) std.debug.print("\n", .{});
    }

    fn render(self: *VerifyProgress, consumed_input_bytes: usize, pages: usize, compared: usize, failures: usize) void {
        if (builtin.is_test) return;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        const percent = if (self.total_input_bytes == 0)
            100
        else
            @as(u8, @intCast(@min(100, (consumed_input_bytes * 100) / self.total_input_bytes)));
        if (percent == self.last_percent) return;
        const now_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
        if (now_ns - self.last_render_ns < refresh_interval_ns and percent != 100) return;
        self.last_percent = percent;
        self.last_render_ns = now_ns;

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        std.debug.print(
            "\rverify dict [{s}] {d:>3}% scan xml (pages={d} compared={d} failures={d})",
            .{ &bar, percent, pages, compared, failures },
        );
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        printUsage();
        return;
    }

    const options = try parseOptions(args[1..]);
    required_path.ensureExistsOrExit(init.io, options.input_path, "verifier input");
    ensureDictionaryIndexExists(init.io, allocator, options);
    const stats = verifyDictionary(init.io, init.gpa, options) catch |err| switch (err) {
        error.UnsupportedDictionaryVersion => {
            std.debug.print(
                "dictionary binary {s} is stale or incompatible with the current encoder tables; rebuild it with `zig build encode -Doptimize=ReleaseFast` and then re-run verify\n",
                .{options.db_path},
            );
            return err;
        },
        else => return err,
    };

    std.debug.print(
        "verified {s} against {s}\npages={d}\nns0={d}\nlanguage_entries={d}\ncompared={d}\nexact_matches={d}\nwhitespace_only_matches={d}\nmissing_raw_entries={d}\nduplicate_raw_titles={d}\ncontent_mismatches={d}\nunexpected_raw_entries={d}\nskipped_parse_errors={d}\nreport={s}\n",
        .{
            options.db_path,
            options.input_path,
            stats.pages_seen,
            stats.namespace_zero_pages,
            stats.language_entries,
            stats.compared_entries,
            stats.exact_matches,
            stats.whitespace_only_matches,
            stats.missing_raw_entries,
            stats.duplicate_raw_titles,
            stats.content_mismatches,
            stats.unexpected_raw_entries,
            stats.skipped_parse_errors,
            options.report_path,
        },
    );

    if (stats.failures() != 0) return error.VerificationFailed;
}

const Options = struct {
    input_path: []const u8 = "data/wiktionary.xml",
    db_path: []const u8 = "data/wiktionary.bin",
    structure_path: ?[]const u8 = null,
    report_path: []const u8 = "data/verification-report.txt",
    limit_entries: ?usize = null,
    thread_count: ?usize = null,
    exclusions: wikitext.ExclusionPolicy = wikitext.ExclusionPolicy.defaultCompact(),
};

pub const VerifyStats = struct {
    pages_seen: usize = 0,
    namespace_zero_pages: usize = 0,
    language_entries: usize = 0,
    compared_entries: usize = 0,
    exact_matches: usize = 0,
    whitespace_only_matches: usize = 0,
    missing_raw_entries: usize = 0,
    duplicate_raw_titles: usize = 0,
    content_mismatches: usize = 0,
    unexpected_raw_entries: usize = 0,
    skipped_parse_errors: usize = 0,

    fn failures(self: VerifyStats) usize {
        return self.missing_raw_entries +
            self.duplicate_raw_titles +
            self.content_mismatches +
            self.unexpected_raw_entries;
    }
};

const RawEntryRef = struct {
    entry_index: u32,
    duplicate: bool = false,
};

const WorkItem = struct {
    title: []u8,
    expected_raw: []u8,
};

const WorkQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    items: std.ArrayList(WorkItem) = .empty,
    closed: bool = false,
    // Sticky terminal error propagated to all producers/consumers so worker failures stop
    // the verifier quickly instead of deadlocking on the bounded queue.
    failure: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) WorkQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .capacity = capacity,
        };
    }

    fn deinit(self: *WorkQueue) void {
        for (self.items.items) |item| {
            self.allocator.free(item.title);
            self.allocator.free(item.expected_raw);
        }
        self.items.deinit(self.allocator);
    }

    fn push(self: *WorkQueue, title: []const u8, expected_raw: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.failure == null and !self.closed and self.items.items.len >= self.capacity) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }

        if (self.failure) |err| return err;
        if (self.closed) return error.ClosedWorkQueue;

        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);
        const owned_expected_raw = try self.allocator.dupe(u8, expected_raw);
        errdefer self.allocator.free(owned_expected_raw);

        try self.items.append(self.allocator, .{
            .title = owned_title,
            .expected_raw = owned_expected_raw,
        });
        self.condition.signal(self.io);
    }

    fn pop(self: *WorkQueue) !?WorkItem {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.failure == null and self.items.items.len == 0 and !self.closed) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }

        if (self.failure) |err| return err;
        if (self.items.items.len == 0) return null;

        const item = self.items.swapRemove(self.items.items.len - 1);
        self.condition.signal(self.io);
        return item;
    }

    fn finish(self: *WorkQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.condition.broadcast(self.io);
    }

    fn fail(self: *WorkQueue, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure == null) self.failure = err;
        self.closed = true;
        self.condition.broadcast(self.io);
    }
};

const PageCapture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,
    redirect_title_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();

        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) {
            self.title_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) {
            self.ns_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "redirect")) {
            self.redirect_title_raw = node.getAttributeValueRaw("title");
        } else if (node.depth == 2 and std.mem.eql(u8, name, "text") and std.mem.eql(u8, self.names_by_depth[1], "revision")) {
            self.text_raw = node.leadingTextRaw();
        }
        return true;
    }
};

const Verifier = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dict: decoder.Dictionary,
    raw_by_word: std.StringHashMapUnmanaged(RawEntryRef) = .empty,
    seen_raw: []bool,
    state_mutex: std.Io.Mutex = .init,
    report: std.Io.Writer.Allocating,
    stats: VerifyStats = .{},

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Verifier {
        var dict = try openOrBuildDictionary(allocator, io, options);
        errdefer dict.deinit();

        var verifier = Verifier{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dict = dict,
            .seen_raw = try allocator.alloc(bool, dict.entries.len),
            .report = .init(allocator),
        };
        errdefer allocator.free(verifier.seen_raw);
        @memset(verifier.seen_raw, false);

        try verifier.raw_by_word.ensureTotalCapacity(allocator, dict.header.raw_entry_count);
        errdefer verifier.raw_by_word.deinit(allocator);

        try verifier.report.writer.print(
            "Dictionary verification report\ninput: {s}\ndb: {s}\nlimit: ",
            .{
                options.input_path,
                options.db_path,
            },
        );
        if (options.limit_entries) |limit| {
            try verifier.report.writer.print("{d}\n\n", .{limit});
        } else {
            try verifier.report.writer.print("all\n\n", .{});
        }
        try verifier.report.writer.print(
            "excluded_sections: anagrams={any} citations={any} meta={any} statistics={any} further_reading={any} translations={any}\n\n",
            .{
                options.exclusions.exclude_anagrams,
                options.exclusions.exclude_citations,
                options.exclusions.exclude_meta,
                options.exclusions.exclude_statistics,
                options.exclusions.exclude_further_reading,
                options.exclusions.exclude_translations,
            },
        );

        for (verifier.dict.entries, 0..) |_, idx| {
            const entry = verifier.dict.entryAt(@intCast(idx));
            if (!entry.hasRaw()) continue;

            const gop = try verifier.raw_by_word.getOrPut(allocator, entry.word());
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .entry_index = @intCast(idx) };
                continue;
            }
            gop.value_ptr.duplicate = true;
        }

        return verifier;
    }

    fn deinit(self: *Verifier) void {
        self.report.deinit();
        self.raw_by_word.deinit(self.allocator);
        self.allocator.free(self.seen_raw);
        self.dict.deinit();
    }

    fn finish(self: *Verifier) !VerifyStats {
        if (self.options.limit_entries == null) {
            for (self.dict.entries, 0..) |_, idx| {
                const entry = self.dict.entryAt(@intCast(idx));
                if (!entry.hasRaw() or self.seen_raw[idx]) continue;

                self.stats.unexpected_raw_entries += 1;
                const summary = try entry.summaryAlloc(self.allocator);
                defer self.allocator.free(summary);
                try self.reportUnexpectedEntry(entry.word(), summary);
            }
        }

        try self.report.writer.print(
            "Summary\n-------\npages: {d}\nnamespace_zero_pages: {d}\nlanguage_entries: {d}\ncompared_entries: {d}\nexact_matches: {d}\nwhitespace_only_matches: {d}\nmissing_raw_entries: {d}\nduplicate_raw_titles: {d}\ncontent_mismatches: {d}\nunexpected_raw_entries: {d}\nskipped_parse_errors: {d}\nfailures: {d}\n",
            .{
                self.stats.pages_seen,
                self.stats.namespace_zero_pages,
                self.stats.language_entries,
                self.stats.compared_entries,
                self.stats.exact_matches,
                self.stats.whitespace_only_matches,
                self.stats.missing_raw_entries,
                self.stats.duplicate_raw_titles,
                self.stats.content_mismatches,
                self.stats.unexpected_raw_entries,
                self.stats.skipped_parse_errors,
                self.stats.failures(),
            },
        );
        if (self.stats.failures() == 0) {
            try self.report.writer.print("\nNo mismatches found.\n", .{});
        }

        try writeReport(self.io, self.options.report_path, self.report.written());
        return self.stats;
    }

    fn snapshotProgress(self: *Verifier) struct {
        pages: usize,
        compared: usize,
        failures: usize,
    } {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return .{
            .pages = self.stats.pages_seen,
            .compared = self.stats.compared_entries,
            .failures = self.stats.failures(),
        };
    }

    fn notePageSeen(self: *Verifier, namespace_zero: bool) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.stats.pages_seen += 1;
        if (namespace_zero) self.stats.namespace_zero_pages += 1;
    }

    fn freeWorkItem(self: *Verifier, item: WorkItem) void {
        self.allocator.free(item.title);
        self.allocator.free(item.expected_raw);
    }

    fn noteLanguageEntry(self: *Verifier) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.stats.language_entries += 1;
    }

    fn noteParseSkip(self: *Verifier) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.stats.skipped_parse_errors += 1;
    }

    fn recordMissingEntry(self: *Verifier, title: []const u8, expected_raw: []const u8) !void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.stats.missing_raw_entries += 1;
        try self.reportMissingEntry(title, expected_raw);
    }

    fn recordDuplicateTitle(self: *Verifier, title: []const u8) !void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.stats.duplicate_raw_titles += 1;
        try self.reportDuplicateTitle(title);
    }

    fn recordExactMatch(self: *Verifier, entry_index: u32) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.seen_raw[entry_index] = true;
        self.stats.compared_entries += 1;
        self.stats.exact_matches += 1;
    }

    fn recordWhitespaceOnlyMatch(self: *Verifier, entry_index: u32) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.seen_raw[entry_index] = true;
        self.stats.compared_entries += 1;
        self.stats.whitespace_only_matches += 1;
    }

    fn recordContentMismatch(
        self: *Verifier,
        entry_index: u32,
        title: []const u8,
        expected_raw: []const u8,
        actual_raw: []const u8,
        expected_norm: []const u8,
        actual_norm: []const u8,
    ) !void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.seen_raw[entry_index] = true;
        self.stats.compared_entries += 1;
        self.stats.content_mismatches += 1;
        try self.reportContentMismatch(title, expected_raw, actual_raw, expected_norm, actual_norm);
    }

    fn compareEntry(self: *Verifier, temp_allocator: std.mem.Allocator, title: []const u8, expected_raw: []const u8) !void {
        self.noteLanguageEntry();

        const entry_ref = self.raw_by_word.get(title) orelse {
            if (try self.shouldSkipMissingEntry(temp_allocator, title, expected_raw)) return;
            try self.recordMissingEntry(title, expected_raw);
            return;
        };

        if (entry_ref.duplicate) {
            try self.recordDuplicateTitle(title);
        }

        const entry = self.dict.entryAt(entry_ref.entry_index);
        const actual_raw = (try entry.rawStoredAlloc(temp_allocator)) orelse {
            // Redirect-only entries intentionally do not store raw wikitext bodies.
            if (!entry.hasRaw()) return;
            try self.recordMissingEntry(title, expected_raw);
            return;
        };

        if (std.mem.eql(u8, expected_raw, actual_raw)) {
            self.recordExactMatch(entry_ref.entry_index);
            return;
        }

        const expected_norm = try normalizeForComparison(temp_allocator, expected_raw);
        const actual_norm = try normalizeForComparison(temp_allocator, actual_raw);
        if (std.mem.eql(u8, expected_norm, actual_norm)) {
            self.recordWhitespaceOnlyMatch(entry_ref.entry_index);
            return;
        }

        try self.recordContentMismatch(entry_ref.entry_index, title, expected_raw, actual_raw, expected_norm, actual_norm);
    }

    fn shouldSkipMissingEntry(_: *Verifier, allocator: std.mem.Allocator, title: []const u8, expected_raw: []const u8) !bool {
        if (std.mem.trim(u8, expected_raw, " \t\r\n").len == 0) return true;

        const english_section = wikitext.extractEnglishSection(expected_raw) orelse return false;
        var metadata = try wikitext.extractEntryMetadata(allocator, title, english_section);
        defer metadata.deinit(allocator);
        if (!metadata.alias_only) return false;
        return metadata.canonical_targets.items.len != 0;
    }

    fn reportMissingEntry(self: *Verifier, title: []const u8, expected_raw: []const u8) !void {
        try self.report.writer.print(
            "=== Missing Raw Entry ===\ntitle: {s}\nexpected_length: {d}\nexpected_excerpt:\n<<<\n{s}\n>>>\n\n",
            .{ title, expected_raw.len, excerptWindow(expected_raw, 0, 200) },
        );
    }

    fn reportDuplicateTitle(self: *Verifier, title: []const u8) !void {
        try self.report.writer.print(
            "=== Duplicate Raw Title ===\ntitle: {s}\ndetail: multiple raw dictionary entries share this exact title\n\n",
            .{title},
        );
    }

    fn reportUnexpectedEntry(self: *Verifier, title: []const u8, summary: []const u8) !void {
        try self.report.writer.print(
            "=== Unexpected Raw Entry ===\ntitle: {s}\nsummary: {s}\n\n",
            .{ title, summary },
        );
    }

    fn reportContentMismatch(
        self: *Verifier,
        title: []const u8,
        expected_raw: []const u8,
        actual_raw: []const u8,
        expected_norm: []const u8,
        actual_norm: []const u8,
    ) !void {
        const raw_diff_at = firstDiffIndex(expected_raw, actual_raw);
        const diff_at = firstDiffIndex(expected_norm, actual_norm);
        try self.report.writer.print(
            "=== Content Mismatch ===\ntitle: {s}\nexpected_length: {d}\nactual_length: {d}\nnormalized_expected_length: {d}\nnormalized_actual_length: {d}\nfirst_raw_diff: {d}\nfirst_normalized_diff: {d}\nexpected_raw_excerpt:\n<<<\n{s}\n>>>\nactual_raw_excerpt:\n<<<\n{s}\n>>>\nexpected_normalized_excerpt:\n<<<\n{s}\n>>>\nactual_normalized_excerpt:\n<<<\n{s}\n>>>\n\n",
            .{
                title,
                expected_raw.len,
                actual_raw.len,
                expected_norm.len,
                actual_norm.len,
                raw_diff_at,
                diff_at,
                excerptWindow(expected_raw, raw_diff_at, 240),
                excerptWindow(actual_raw, raw_diff_at, 240),
                excerptWindow(expected_norm, diff_at, 240),
                excerptWindow(actual_norm, diff_at, 240),
            },
        );
    }
};

fn openOrBuildDictionary(allocator: std.mem.Allocator, io: std.Io, options: Options) !decoder.Dictionary {
    return decoder.openDictionaryWithOptions(allocator, io, options.db_path, .{
        .structure_path = options.structure_path,
    });
}

fn ensureDictionaryIndexExists(io: std.Io, allocator: std.mem.Allocator, options: Options) void {
    const idx_path = std.fmt.allocPrint(allocator, "{s}.idx", .{options.db_path}) catch unreachable;
    defer allocator.free(idx_path);

    const found = required_path.exists(io, idx_path) catch |err| {
        std.debug.print("failed to access dictionary index at {s}: {s}\n", .{ idx_path, @errorName(err) });
        std.process.exit(1);
    };
    if (found) return;

    std.debug.print("dictionary index not found: {s}; running {s} index\n", .{ idx_path, tool_paths.decoder_bin_path });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "index") catch unreachable;
    argv.append(allocator, "--input") catch unreachable;
    argv.append(allocator, options.input_path) catch unreachable;
    argv.append(allocator, "--db") catch unreachable;
    argv.append(allocator, options.db_path) catch unreachable;
    if (options.structure_path) |structure_path| {
        argv.append(allocator, "--structure") catch unreachable;
        argv.append(allocator, structure_path) catch unreachable;
    }
    if (options.limit_entries) |limit| {
        const limit_text = std.fmt.allocPrint(allocator, "{d}", .{limit}) catch unreachable;
        defer allocator.free(limit_text);
        argv.append(allocator, "--limit") catch unreachable;
        argv.append(allocator, limit_text) catch unreachable;
    }
    required_path.runToolOrExit(io, allocator, tool_paths.decoder_bin_path, "decoder binary", argv.items);
}

const VerifyChunk = struct {
    start: usize,
    end: usize,
};

const VerifyChunkJob = struct {
    mapped: []const u8,
    chunk: VerifyChunk,
    verifier: *Verifier,
    queue: *WorkQueue,
    progress: *VerifyProgress,
    err: ?anyerror = null,
};

const PageOutcome = enum {
    none,
    raw,
    redirect,
};

pub fn verifyDictionary(io: std.Io, allocator: std.mem.Allocator, options: Options) !VerifyStats {
    var verifier = try Verifier.init(allocator, io, options);
    defer verifier.deinit();

    var input = try mmapReadOnlyPath(io, options.input_path);
    defer input.deinit();

    const stat = input.stat;
    var progress = VerifyProgress.init(@intCast(stat.size));
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const thread_count = @max(@as(usize, 1), options.thread_count orelse cpu_count);
    var queue = WorkQueue.init(allocator, io, @max(@as(usize, 32), thread_count * 8));
    defer queue.deinit();

    const workers = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(workers);
    var spawned_workers: usize = 0;
    for (workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, verifierWorkerMain, .{ &verifier, &queue });
        spawned_workers += 1;
    }
    var workers_joined = false;
    defer {
        queue.finish();
        if (!workers_joined) {
            for (workers[0..spawned_workers]) |worker| worker.join();
        }
    }

    if (stat.size != 0) {
        const input_bytes = input.bytes();
        const scan_thread_count = verifyScanThreadCount(input_bytes.len, options.limit_entries, options.thread_count);
        if (scan_thread_count == 1) {
            var stream_parser = StreamParser.init(allocator);
            defer stream_parser.deinit();

            var page_arena = std.heap.ArenaAllocator.init(allocator);
            defer page_arena.deinit();

            try processMappedInputSequential(
                &verifier,
                input_bytes,
                &stream_parser,
                &page_arena,
                &queue,
                &progress,
            );
        } else {
            try processMappedInputParallel(
                allocator,
                &verifier,
                input_bytes,
                scan_thread_count,
                &queue,
                &progress,
            );
        }
    }

    queue.finish();
    for (workers[0..spawned_workers]) |worker| worker.join();
    workers_joined = true;
    if (queue.failure) |err| return err;

    const final_counts = verifier.snapshotProgress();
    progress.finish(final_counts.pages, final_counts.compared, final_counts.failures);
    return verifier.finish();
}

const MappedReadOnlyFile = struct {
    stat: std.Io.File.Stat,
    mapping: ?[]align(std.heap.page_size_min) const u8,

    fn bytes(self: MappedReadOnlyFile) []const u8 {
        return if (self.mapping) |mapping|
            mapping[0..@as(usize, @intCast(self.stat.size))]
        else
            &.{};
    }

    fn deinit(self: *MappedReadOnlyFile) void {
        if (self.mapping) |mapping| std.posix.munmap(mapping);
        self.mapping = null;
    }
};

fn mmapReadOnlyPath(io: std.Io, path: []const u8) !MappedReadOnlyFile {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    var file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) {
        return .{
            .stat = stat,
            .mapping = null,
        };
    }

    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const mapping = try std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    return .{
        .stat = stat,
        .mapping = mapping,
    };
}

fn verifyScanThreadCount(total_input_bytes: usize, limit_entries: ?usize, thread_override: ?usize) usize {
    if (builtin.single_threaded or limit_entries != null) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), requested);
    if (total_input_bytes < (32 << 20)) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), cpu_count);
}

fn collectVerifyChunksAlloc(allocator: std.mem.Allocator, mapped: []const u8, desired_chunks: usize) ![]VerifyChunk {
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(allocator);
    try starts.append(allocator, 0);

    for (1..desired_chunks) |chunk_index| {
        const approx = @divTrunc(mapped.len * chunk_index, desired_chunks);
        const page_start = std.mem.indexOfPos(u8, mapped, approx, "<page>") orelse continue;
        if (page_start <= starts.items[starts.items.len - 1]) continue;
        try starts.append(allocator, page_start);
    }
    try starts.append(allocator, mapped.len);

    const chunks = try allocator.alloc(VerifyChunk, starts.items.len - 1);
    for (chunks, 0..) |*chunk, idx| {
        chunk.* = .{
            .start = starts.items[idx],
            .end = starts.items[idx + 1],
        };
    }
    return chunks;
}

fn processMappedInputParallel(
    allocator: std.mem.Allocator,
    verifier: *Verifier,
    mapped: []const u8,
    scan_thread_count: usize,
    queue: *WorkQueue,
    progress: *VerifyProgress,
) !void {
    const chunks = try collectVerifyChunksAlloc(allocator, mapped, scan_thread_count);
    defer allocator.free(chunks);

    const jobs = try allocator.alloc(VerifyChunkJob, chunks.len);
    defer allocator.free(jobs);
    for (chunks, jobs) |chunk, *job| {
        job.* = .{
            .mapped = mapped,
            .chunk = chunk,
            .verifier = verifier,
            .queue = queue,
            .progress = progress,
        };
    }

    const threads = try allocator.alloc(std.Thread, chunks.len - 1);
    defer allocator.free(threads);
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();

    for (jobs[1..], threads) |*job, *thread| {
        thread.* = try std.Thread.spawn(.{}, processVerifyChunkThread, .{job});
        started_threads += 1;
    }
    processVerifyChunkThread(&jobs[0]);
    for (threads[0..started_threads]) |thread| thread.join();

    for (jobs) |job| if (job.err) |err| return err;
}

fn processVerifyChunkThread(job: *VerifyChunkJob) void {
    processVerifyChunk(job) catch |err| {
        job.err = err;
        job.queue.fail(err);
    };
}

fn processVerifyChunk(job: *VerifyChunkJob) !void {
    var stream_parser = StreamParser.init(std.heap.smp_allocator);
    defer stream_parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer page_arena.deinit();

    var consumed: usize = job.chunk.start;
    while (true) {
        const start = std.mem.indexOfPos(u8, job.mapped, consumed, "<page>") orelse break;
        if (start >= job.chunk.end) break;
        const end_start = std.mem.indexOfPos(u8, job.mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;
        if (page_end > job.chunk.end) break;

        const page_allocator = page_arena.allocator();
        _ = processPageFragment(page_allocator, &stream_parser, job.mapped[start..page_end], job.verifier, job.queue) catch |err| switch (err) {
            error.OutOfMemory, error.ClosedWorkQueue => return err,
            else => blk: {
                job.verifier.noteParseSkip();
                break :blk PageOutcome.none;
            },
        };
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);

        const counts = job.verifier.snapshotProgress();
        job.progress.scanAdvance(page_end - start, counts.pages, counts.compared, counts.failures);
    }
}

fn processMappedInputSequential(
    verifier: *Verifier,
    mapped: []const u8,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
    queue: *WorkQueue,
    progress: *VerifyProgress,
) !void {
    var consumed: usize = 0;
    var selected_entries: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        const outcome = processPageFragment(page_allocator, stream_parser, mapped[start..page_end], verifier, queue) catch |err| switch (err) {
            error.OutOfMemory, error.ClosedWorkQueue => return err,
            else => blk: {
                verifier.noteParseSkip();
                break :blk PageOutcome.none;
            },
        };
        if (outcome != .none) {
            selected_entries += 1;
        }
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);
        const counts = verifier.snapshotProgress();
        progress.scanAdvance(page_end - start, counts.pages, counts.compared, counts.failures);

        if (verifier.options.limit_entries) |limit| {
            if (selected_entries >= limit) return;
        }
    }
}

fn processPageFragment(
    allocator: std.mem.Allocator,
    parser: *StreamParser,
    page_fragment: []const u8,
    verifier: *Verifier,
    queue: *WorkQueue,
) !PageOutcome {
    var capture: PageCapture = .{};
    try parser.parse(page_fragment, &capture, PageCapture.onNode);

    const ns_raw = capture.ns_raw orelse return .none;
    const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch return .none;
    verifier.notePageSeen(ns == 0);
    if (ns != 0) return .none;

    const title_raw = capture.title_raw orelse return .none;
    const text_raw = capture.text_raw orelse {
        if (capture.redirect_title_raw != null) return .redirect;
        return .none;
    };

    const title = try xml_decode.decodeAlloc(allocator, title_raw);
    const text = try xml_decode.decodeAlloc(allocator, text_raw);
    const stored_sections = (try wikitext.extractConfiguredLanguageSectionsAlloc(allocator, text, verifier.options.exclusions)) orelse {
        if (capture.redirect_title_raw != null) return .redirect;
        return .none;
    };

    try queue.push(title, stored_sections);
    return .raw;
}

fn verifierWorkerMain(verifier: *Verifier, queue: *WorkQueue) void {
    var arena = std.heap.ArenaAllocator.init(verifier.allocator);
    defer arena.deinit();

    while (true) {
        const maybe_item = queue.pop() catch |err| {
            queue.fail(err);
            return;
        };
        const item = maybe_item orelse return;
        defer verifier.freeWorkItem(item);

        verifier.compareEntry(arena.allocator(), item.title, item.expected_raw) catch |err| {
            queue.fail(err);
            return;
        };
        _ = arena.reset(.retain_capacity);
    }
}

fn normalizeForComparison(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(text) catch return normalizeBytesForComparison(allocator, text);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pending_space = false;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        if (isComparisonWhitespace(codepoint)) {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &buf);
        try out.appendSlice(allocator, buf[0..len]);
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeBytesForComparison(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pending_space = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, byte);
    }

    return out.toOwnedSlice(allocator);
}

fn isComparisonWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009,
        0x000A,
        0x000B,
        0x000C,
        0x000D,
        0x0020,
        0x0085,
        0x00A0,
        0x1680,
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2007,
        0x2008,
        0x2009,
        0x200A,
        0x200B,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x2060,
        0x3000,
        0xFEFF,
        => true,
        else => false,
    };
}

fn firstDiffIndex(left: []const u8, right: []const u8) usize {
    const common = @min(left.len, right.len);
    var i: usize = 0;
    while (i < common) : (i += 1) {
        if (left[i] != right[i]) return i;
    }
    return common;
}

fn excerptWindow(text: []const u8, center: usize, width: usize) []const u8 {
    if (text.len <= width) return text;
    const half = width / 2;
    const start = center -| half;
    const end = @min(text.len, start + width);
    return text[start..end];
}

fn writeReport(io: std.Io, report_path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, report_path, "-")) {
        std.debug.print("{s}", .{bytes});
        return;
    }

    var file = try std.Io.Dir.cwd().createFile(io, report_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn truncateFd(fd: std.posix.fd_t, length: usize) !void {
    const signed_length = std.math.cast(i64, length) orelse return error.FileTooBig;
    switch (builtin.os.tag) {
        .linux => switch (std.posix.errno(std.os.linux.ftruncate(fd, signed_length))) {
            .SUCCESS => {},
            .INTR => return truncateFd(fd, length),
            .ACCES => return error.AccessDenied,
            .BADF => return error.FileNotFound,
            .FBIG => return error.FileTooBig,
            .INVAL => return error.InvalidArgument,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.AccessDenied,
            .TXTBSY => return error.FileBusy,
            else => |err| return std.posix.unexpectedErrno(err),
        },
        else => @compileError("truncateFd is only implemented for Linux"),
    }
}

fn writeMappedFile(path: []const u8, contents: []const u8) !void {
    const map_len = @max(contents.len, 1);
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o666);
    errdefer _ = std.os.linux.close(fd);
    try truncateFd(fd, map_len);

    const mapping = try std.posix.mmap(
        null,
        map_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(mapping);

    @memcpy(mapping[0..contents.len], contents);
    try truncateFd(fd, contents.len);
    _ = std.os.linux.close(fd);
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") and i + 1 < args.len) {
            options.input_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            options.db_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--structure") and i + 1 < args.len) {
            options.structure_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--report") and i + 1 < args.len) {
            options.report_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            options.limit_entries = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--threads") and i + 1 < args.len) {
            options.thread_count = try std.fmt.parseInt(usize, args[i + 1], 10);
            if (options.thread_count.? == 0) return error.InvalidArgument;
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
        \\dict-verify [--input data/wiktionary.xml] [--db data/wiktionary.bin]
        \\            [--structure data/wiktionary-structure.json]
        \\            [--report data/verification-report.txt] [--limit 10000]
        \\            [--threads N]
        \\build-time exclusions come from -Dskip-headings=...
        \\
    , .{});
}

fn tempPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "verifyDictionary accepts whitespace-only differences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const build_xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;
    const verify_xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\
        \\===Noun===
        \\#   [[light]]
        \\
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const build_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "build.xml");
    defer std.testing.allocator.free(build_rel);
    const verify_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "verify.xml");
    defer std.testing.allocator.free(verify_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(build_rel, build_xml);
    try writeMappedFile(verify_rel, verify_xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = verify_rel,
        .db_path = db_rel,
        .report_path = report_rel,
        .thread_count = 2,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.whitespace_only_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary reports content mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const build_xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;
    const verify_xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[pigment]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const build_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "build.xml");
    defer std.testing.allocator.free(build_rel);
    const verify_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "verify.xml");
    defer std.testing.allocator.free(verify_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(build_rel, build_xml);
    try writeMappedFile(verify_rel, verify_xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = verify_rel,
        .db_path = db_rel,
        .report_path = report_rel,
        .thread_count = 2,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.content_mismatches);
    try std.testing.expect(stats.failures() != 0);

    var report_file = try tmp.dir.openFile(std.testing.io, "report.txt", .{});
    defer report_file.close(std.testing.io);
    const stat = try report_file.stat(std.testing.io);
    const report = try std.testing.allocator.alloc(u8, @intCast(stat.size));
    defer std.testing.allocator.free(report);
    var read_buf: [256]u8 = undefined;
    var file_reader = report_file.reader(std.testing.io, &read_buf);
    try file_reader.interface.readSliceAll(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "Content Mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "color") != null);
}

test "verifyDictionary decodes double-escaped symbols and builder stores decoded raw text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const build_xml =
        \\<mediawiki>
        \\<page>
        \\<title>copycat</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[symbol]] &amp;copy; &amp;emdash; &amp;amp;#91;
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const build_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "build.xml");
    defer std.testing.allocator.free(build_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(build_rel, build_xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .output_path = db_rel,
    });

    var dict = try decoder.Dictionary.open(std.testing.allocator, std.testing.io, db_rel, .{});
    defer dict.deinit();

    const hits = try dict.lookupExact(std.testing.allocator, "copycat");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);

    const raw = (try dict.entryAt(hits[0].entry_index).rawEnglishAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "©") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "—") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "&copy;") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "&emdash;") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "&amp#91;") == null);

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .db_path = db_rel,
        .report_path = report_rel,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.exact_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary treats decoded unicode spacing entities as whitespace-only differences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const build_xml =
        \\<mediawiki>
        \\<page>
        \\<title>spacing</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# alpha beta
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;
    const verify_xml =
        \\<mediawiki>
        \\<page>
        \\<title>spacing</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# alpha&amp;nbsp;beta
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const build_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "build.xml");
    defer std.testing.allocator.free(build_rel);
    const verify_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "verify.xml");
    defer std.testing.allocator.free(verify_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(build_rel, build_xml);
    try writeMappedFile(verify_rel, verify_xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = verify_rel,
        .db_path = db_rel,
        .report_path = report_rel,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.whitespace_only_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary skips redirect-only entries without raw payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>headspace</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[space]] in the [[head]]
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>head space</title>
        \\<ns>0</ns>
        \\<redirect title="headspace" />
        \\<revision><text xml:space="preserve">#REDIRECT [[headspace]]</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "redirect.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(xml_rel, xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .db_path = db_rel,
        .report_path = report_rel,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.exact_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.missing_raw_entries);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary limit matches encoder entry limit when redirects are included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>alpha</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# first
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>alpha redirect</title>
        \\<ns>0</ns>
        \\<redirect title="alpha" />
        \\<revision><text xml:space="preserve">#REDIRECT [[alpha]]</text></revision>
        \\</page>
        \\<page>
        \\<title>beta</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# second
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "limit.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(xml_rel, xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
        .limit_entries = 2,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .db_path = db_rel,
        .report_path = report_rel,
        .limit_entries = 2,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.exact_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.missing_raw_entries);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary ignores excluded headings with matching blacklist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\===References===
        \\* {{R:OneLook}}
        \\===Further reading===
        \\* {{R:OneLook}}
        \\===Translations===
        \\* Finnish: testi
        \\===Anagrams===
        \\* crolo
        \\===Statistics===
        \\* stub
        \\===Dialects===
        \\* rare
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const build_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "build.xml");
    defer std.testing.allocator.free(build_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(build_rel, xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = build_rel,
        .db_path = db_rel,
        .report_path = report_rel,
        .exclusions = .defaultCompact(),
    });

    try std.testing.expectEqual(@as(usize, 1), stats.exact_matches + stats.whitespace_only_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary ignores dropped alias-only entries with invalid destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[color]]
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colour</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Adjective===
        \\# {{alternative spelling of|en|Missing target}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "sample.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "verify-report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(xml_rel, xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .db_path = db_rel,
        .report_path = report_rel,
        .thread_count = 1,
    });

    try std.testing.expectEqual(@as(usize, 2), stats.language_entries);
    try std.testing.expectEqual(@as(usize, 1), stats.compared_entries);
    try std.testing.expectEqual(@as(usize, 1), stats.exact_matches + stats.whitespace_only_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "verifyDictionary skips non-English entries by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>चूत</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==Hindi==
        \\===Noun===
        \\# [[cunt]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const xml_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "sample.xml");
    defer std.testing.allocator.free(xml_rel);
    const db_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "dict.bin");
    defer std.testing.allocator.free(db_rel);
    const report_rel = try tempPath(std.testing.allocator, &tmp.sub_path, "verify-report.txt");
    defer std.testing.allocator.free(report_rel);
    try writeMappedFile(xml_rel, xml);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .output_path = db_rel,
    });

    const stats = try verifyDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_rel,
        .db_path = db_rel,
        .report_path = report_rel,
        .thread_count = 2,
    });

    try std.testing.expectEqual(@as(usize, 0), stats.language_entries);
    try std.testing.expectEqual(@as(usize, 0), stats.compared_entries);
    try std.testing.expectEqual(@as(usize, 0), stats.exact_matches);
    try std.testing.expectEqual(@as(usize, 0), stats.failures());
}

test "wikitext.parseExclusionPolicy accepts translations" {
    const exclusions = try wikitext.parseExclusionPolicy("translations");
    try std.testing.expect(exclusions.exclude_translations);
}
