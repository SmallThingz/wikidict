const std = @import("std");
const builtin = @import("builtin");
const zxml = @import("zxml");
const normalize = @import("normalize");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");
const wikitext = @import("wikitext.zig");
const xml_decode = @import("shared_xml_decode");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = true,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

pub const BuildOptions = struct {
    input_path: []const u8,
    output_path: []const u8,
    limit_entries: ?usize = null,
    worker_threads: ?usize = null,
};

pub const BuildStats = struct {
    pages_seen: usize = 0,
    namespace_zero_pages: usize = 0,
    english_entries: usize = 0,
    redirect_aliases: usize = 0,
};

const BuildProgress = struct {
    const refresh_interval_ns = std.time.ns_per_s / 20;

    const Phase = enum {
        scanning,
        writing,
        filtering,
        done,
    };

    total_input_bytes: usize,
    scanned_input_bytes: std.atomic.Value(usize) = .init(0),
    scanned_pages: std.atomic.Value(usize) = .init(0),
    scanned_entries: std.atomic.Value(usize) = .init(0),
    filtered_records: std.atomic.Value(usize) = .init(0),
    kept_filtered_records: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    phase: Phase = .scanning,
    scanning_parallel: bool = false,
    last_percent: u8 = 255,
    last_primary: usize = std.math.maxInt(usize),
    last_secondary: usize = std.math.maxInt(usize),
    last_render_ns: i96 = 0,

    fn init(total_input_bytes: usize) BuildProgress {
        return .{ .total_input_bytes = total_input_bytes };
    }

    fn setScanningParallel(self: *BuildProgress, scanning_parallel: bool) void {
        self.scanning_parallel = scanning_parallel;
    }

    fn scanAdvance(self: *BuildProgress, input_bytes_delta: usize, page_delta: usize, entry_delta: usize) void {
        const consumed_input_bytes = self.scanned_input_bytes.fetchAdd(input_bytes_delta, .monotonic) + input_bytes_delta;
        const pages = self.scanned_pages.fetchAdd(page_delta, .monotonic) + page_delta;
        const entries = self.scanned_entries.fetchAdd(entry_delta, .monotonic) + entry_delta;
        const percent = if (self.total_input_bytes == 0)
            97
        else
            @as(u8, @intCast(@min(97, (consumed_input_bytes * 97) / self.total_input_bytes)));
        self.render(.scanning, percent, pages, entries);
    }

    fn finishScanning(self: *BuildProgress) void {
        const pages = self.scanned_pages.load(.monotonic);
        const entries = self.scanned_entries.load(.monotonic);
        self.render(.scanning, 97, pages, entries);
    }

    fn setWriting(self: *BuildProgress, entries: usize, redirects: usize) void {
        self.render(.writing, 98, entries, redirects);
    }

    fn filter(self: *BuildProgress, processed_records: usize, total_records: usize, kept_records: usize) void {
        const percent_value: usize = if (total_records == 0)
            99
        else
            @as(usize, 98) + @min(@as(usize, 1), (processed_records * 2) / total_records);
        const percent: u8 = @intCast(percent_value);
        self.render(.filtering, percent, kept_records, processed_records);
    }

    fn filterAdvance(self: *BuildProgress, record_delta: usize, total_records: usize, kept_delta: usize) void {
        const processed_records = self.filtered_records.fetchAdd(record_delta, .monotonic) + record_delta;
        const kept_records = self.kept_filtered_records.fetchAdd(kept_delta, .monotonic) + kept_delta;
        self.filter(processed_records, total_records, kept_records);
    }

    fn finish(self: *BuildProgress, pages: usize, entries: usize) void {
        self.render(.done, 100, pages, entries);
        if (!builtin.is_test) std.debug.print("\n", .{});
    }

    fn render(self: *BuildProgress, phase: Phase, percent: u8, primary: usize, secondary: usize) void {
        if (builtin.is_test) return;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.phase == phase and self.last_percent == percent and self.last_primary == primary and self.last_secondary == secondary) return;
        const now_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
        if (!shouldRenderNow(self, phase, now_ns)) return;

        self.phase = phase;
        self.last_percent = percent;
        self.last_primary = primary;
        self.last_secondary = secondary;
        self.last_render_ns = now_ns;

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        switch (phase) {
            .scanning => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (pages={d} entries={d})",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            ),
            .writing => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (entries={d} redirects={d})",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            ),
            .filtering => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (kept={d} scanned={d})",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            ),
            .done => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (pages={d} entries={d})",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            ),
        }
    }

    fn phaseLabel(self: *const BuildProgress, phase: Phase) []const u8 {
        return switch (phase) {
            .scanning => if (self.scanning_parallel) "scan xml in parallel" else "scan xml",
            .writing => "write output",
            .filtering => "filter aliases",
            .done => "ready",
        };
    }

    fn shouldRenderNow(self: *const BuildProgress, phase: Phase, now_ns: i96) bool {
        if (phase == .done or phase != self.phase) return true;
        return now_ns - self.last_render_ns >= refresh_interval_ns;
    }
};

pub fn build(io: std.Io, allocator: std.mem.Allocator, options: BuildOptions) !BuildStats {
    var input = try mmapReadOnlyPath(io, options.input_path);
    defer input.deinit();

    const temp_output_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{options.output_path});
    defer allocator.free(temp_output_path);
    std.Io.Dir.cwd().deleteFile(io, temp_output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, temp_output_path) catch {};

    var stats: BuildStats = .{};

    const stat = input.stat;
    var progress = BuildProgress.init(@intCast(stat.size));
    {
        var output = try OutputWriter.init(io, allocator, temp_output_path);
        defer output.deinit(allocator);

        if (stat.size != 0) {
            const input_bytes = input.bytes();
            const worker_count = encodeThreadCount(input_bytes.len, options.limit_entries, options.worker_threads);
            progress.setScanningParallel(worker_count > 1);
            if (worker_count == 1) {
                var stream_parser = StreamParser.init(allocator);
                defer stream_parser.deinit();

                var page_arena = std.heap.ArenaAllocator.init(allocator);
                defer page_arena.deinit();

                try processMappedInputSequential(
                    input_bytes,
                    options.limit_entries,
                    &stream_parser,
                    &page_arena,
                    &output,
                    &stats,
                    &progress,
                );
            } else {
                try processMappedInputParallel(
                    io,
                    allocator,
                    input_bytes,
                    worker_count,
                    temp_output_path,
                    &output,
                    &stats,
                    &progress,
                );
            }
        }

        progress.finishScanning();
        progress.setWriting(output.entry_count, output.redirect_count);
        try output.finish();
        stats.english_entries = output.entry_count;
        stats.redirect_aliases = output.redirect_count;
    }

    if (options.limit_entries == null) {
        const filtered_output_path = try std.fmt.allocPrint(allocator, "{s}.filter.tmp", .{options.output_path});
        defer allocator.free(filtered_output_path);
        std.Io.Dir.cwd().deleteFile(io, filtered_output_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        defer std.Io.Dir.cwd().deleteFile(io, filtered_output_path) catch {};

        const filtered = try filterAliasRecordsFromBinary(io, allocator, temp_output_path, filtered_output_path, options.worker_threads, &progress);
        stats.english_entries = filtered.entry_count;
        stats.redirect_aliases = filtered.redirect_count;
        try std.Io.Dir.cwd().rename(filtered_output_path, std.Io.Dir.cwd(), options.output_path, io);
    } else {
        try std.Io.Dir.cwd().rename(temp_output_path, std.Io.Dir.cwd(), options.output_path, io);
    }
    progress.finish(stats.pages_seen, stats.english_entries);
    return stats;
}

fn processMappedInputSequential(
    mapped: []const u8,
    limit_entries: ?usize,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
    output: *OutputWriter,
    stats: *BuildStats,
    progress: *BuildProgress,
) !void {
    var consumed: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        const entry_count_before = output.entry_count;
        try processPageFragment(page_allocator, stream_parser, mapped[start..page_end], output, stats);
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);
        progress.scanAdvance(page_end - start, 1, output.entry_count - entry_count_before);

        if (limit_entries) |limit| {
            if (output.entry_count >= limit) return;
        }
    }
}

const EncodeChunk = struct {
    start: usize,
    end: usize,
};

const EncodeChunkResult = struct {
    stats: BuildStats = .{},
    temp_output_path: []const u8 = "",
    err: ?anyerror = null,
};

const EncodeChunkJob = struct {
    io: std.Io,
    mapped: []const u8,
    chunk: EncodeChunk,
    temp_output_path: []const u8,
    progress: *BuildProgress,
    result: *EncodeChunkResult,
};

fn encodeThreadCount(total_input_bytes: usize, limit_entries: ?usize, thread_override: ?usize) usize {
    if (builtin.single_threaded or limit_entries != null) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), requested);
    if (total_input_bytes < (32 << 20)) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), cpu_count);
}

fn filterThreadCount(record_count: usize, thread_override: ?usize) usize {
    if (builtin.single_threaded or record_count < 256) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), @min(record_count, requested));
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), @min(record_count, cpu_count));
}

fn partitionEnd(total: usize, part_count: usize, part_index: usize) usize {
    return @divTrunc(total * (part_index + 1), part_count);
}

fn collectEncodeChunksAlloc(allocator: std.mem.Allocator, mapped: []const u8, desired_chunks: usize) ![]EncodeChunk {
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

    const chunks = try allocator.alloc(EncodeChunk, starts.items.len - 1);
    for (chunks, 0..) |*chunk, idx| {
        chunk.* = .{
            .start = starts.items[idx],
            .end = starts.items[idx + 1],
        };
    }
    return chunks;
}

fn processMappedInputParallel(
    io: std.Io,
    allocator: std.mem.Allocator,
    mapped: []const u8,
    worker_count: usize,
    temp_output_path: []const u8,
    output: *OutputWriter,
    stats: *BuildStats,
    progress: *BuildProgress,
) !void {
    const chunks = try collectEncodeChunksAlloc(allocator, mapped, worker_count);
    defer allocator.free(chunks);

    const results = try allocator.alloc(EncodeChunkResult, chunks.len);
    defer {
        for (results) |result| if (result.temp_output_path.len != 0) allocator.free(result.temp_output_path);
        allocator.free(results);
    }
    for (results) |*result| result.* = .{};

    const threads = try allocator.alloc(std.Thread, chunks.len - 1);
    defer allocator.free(threads);

    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();

    const jobs = try allocator.alloc(EncodeChunkJob, chunks.len);
    defer allocator.free(jobs);

    for (chunks, results, jobs, 0..) |chunk, *result, *job, idx| {
        const chunk_path = try std.fmt.allocPrint(allocator, "{s}.part{d}", .{ temp_output_path, idx });
        result.temp_output_path = chunk_path;
        std.Io.Dir.cwd().deleteFile(io, chunk_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        job.* = .{
            .io = io,
            .mapped = mapped,
            .chunk = chunk,
            .temp_output_path = chunk_path,
            .progress = progress,
            .result = result,
        };
    }

    for (jobs[1..], threads) |*job, *thread| {
        thread.* = try std.Thread.spawn(.{}, processEncodeChunk, .{job});
        started_threads += 1;
    }
    processEncodeChunk(&jobs[0]);
    for (threads[0..started_threads]) |thread| thread.join();

    for (results) |result| {
        if (result.err) |err| return err;
    }

    for (results) |result| {
        defer std.Io.Dir.cwd().deleteFile(io, result.temp_output_path) catch {};
        stats.pages_seen += result.stats.pages_seen;
        stats.namespace_zero_pages += result.stats.namespace_zero_pages;
        stats.redirect_aliases += result.stats.redirect_aliases;
        try appendChunkFileToOutput(io, result.temp_output_path, output);
    }
}

fn processEncodeChunk(job: *EncodeChunkJob) void {
    processEncodeChunkFallible(job) catch |err| {
        job.result.err = err;
    };
}

fn processEncodeChunkFallible(job: *EncodeChunkJob) !void {
    var parser = StreamParser.init(std.heap.smp_allocator);
    defer parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer page_arena.deinit();

    var output = try OutputWriter.init(job.io, std.heap.smp_allocator, job.temp_output_path);
    defer output.deinit(std.heap.smp_allocator);

    var stats: BuildStats = .{};
    var consumed = job.chunk.start;
    while (true) {
        const start = std.mem.indexOfPos(u8, job.mapped, consumed, "<page>") orelse break;
        if (start >= job.chunk.end) break;
        const end_start = std.mem.indexOfPos(u8, job.mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;
        if (page_end > job.chunk.end) break;

        const page_allocator = page_arena.allocator();
        const entry_count_before = output.entry_count;
        try processPageFragment(page_allocator, &parser, job.mapped[start..page_end], &output, &stats);
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);
        job.progress.scanAdvance(page_end - start, 1, output.entry_count - entry_count_before);
    }

    try output.finish();
    job.result.stats = .{
        .pages_seen = stats.pages_seen,
        .namespace_zero_pages = stats.namespace_zero_pages,
        .english_entries = output.entry_count,
        .redirect_aliases = output.redirect_count,
    };
}

fn appendChunkFileToOutput(io: std.Io, chunk_path: []const u8, output: *OutputWriter) !void {
    var chunk = try mmapReadOnlyPath(io, chunk_path);
    defer chunk.deinit();

    const mapped = chunk.bytes();
    const inspected = try validateDictionaryHeader(mapped, chunk.stat.size);
    const lengths_start: usize = @intCast(inspected.layout.lengths_offset);
    const lengths_end: usize = @intCast(inspected.layout.lengths_offset + inspected.layout.lengths_len);
    const titles_start: usize = @intCast(inspected.layout.titles_offset);
    const titles_end: usize = @intCast(inspected.layout.titles_offset + inspected.layout.titles_len);
    const payloads_start: usize = @intCast(inspected.layout.records_offset);
    const payloads_end: usize = @intCast(inspected.layout.records_offset + inspected.layout.records_len);

    try output.writeLengthBytes(mapped[lengths_start..lengths_end]);
    try output.writeTitleBytes(mapped[titles_start..titles_end]);
    try output.writePayloadBytes(mapped[payloads_start..payloads_end]);
    output.entry_count += inspected.header.entry_count;
    output.raw_entry_count += inspected.header.raw_entry_count;
    output.redirect_count += inspected.header.redirect_count;
}

const PageCapture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,
    // Redirect pages encode the target as an attribute on the empty <redirect/> node.
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

const AliasCandidate = struct {
    normalized_title: []const u8,
    normalized_targets: []const []const u8,
    base_valid: bool,
    valid: bool = false,

    fn deinit(self: *AliasCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized_title);
        for (self.normalized_targets) |target| allocator.free(target);
        allocator.free(self.normalized_targets);
    }
};

const ValidTitleSet = std.StringHashMap(void);

fn processPageFragment(
    allocator: std.mem.Allocator,
    parser: *StreamParser,
    page_fragment: []const u8,
    output: *OutputWriter,
    stats: *BuildStats,
) !void {
    var capture: PageCapture = .{};
    try parser.parse(page_fragment, &capture, PageCapture.onNode);
    stats.pages_seen += 1;

    const ns_raw = capture.ns_raw orelse return;
    const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch return;
    if (ns != 0) return;
    stats.namespace_zero_pages += 1;

    const title_raw = capture.title_raw orelse return;

    if (capture.text_raw) |text_raw| {
        var text = try decodeXmlViewAlloc(allocator, text_raw);
        defer text.deinit(allocator);
        if (try wikitext.extractConfiguredLanguageSectionsAlloc(allocator, text.value, .defaultCompact())) |stored_sections| {
            defer allocator.free(stored_sections);
            var title = try decodeXmlViewAlloc(allocator, title_raw);
            defer title.deinit(allocator);
            var metadata: wikitext.EntryMetadata = .{};
            defer metadata.deinit(allocator);
            if (wikitext.extractEnglishSection(stored_sections)) |english_section| {
                metadata = try wikitext.extractEntryMetadata(allocator, title.value, english_section);
            }
            try output.writeRawRecord(title.value, stored_sections, metadata);
            return;
        }
    }

    if (capture.redirect_title_raw) |raw| {
        var title = try decodeXmlViewAlloc(allocator, title_raw);
        defer title.deinit(allocator);
        var target = try decodeXmlViewAlloc(allocator, raw);
        defer target.deinit(allocator);
        try output.writeRedirectRecord(
            title.value,
            target.value,
        );
        stats.redirect_aliases += 1;
    }
}

const DecodedXmlView = struct {
    value: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *DecodedXmlView, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

fn decodeXmlViewAlloc(allocator: std.mem.Allocator, raw: []const u8) !DecodedXmlView {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) {
        return .{ .value = raw };
    }
    const owned = try xml_decode.decodeAlloc(allocator, raw);
    return .{
        .value = owned,
        .owned = owned,
    };
}

const BinaryRecord = struct {
    flags: u8,
    title: []const u8,
    payload: []const u8,
};

const FilterResult = struct {
    entry_count: usize,
    redirect_count: usize,
};

const CandidateChunkResult = struct {
    arena: std.heap.ArenaAllocator,
    candidates: []AliasCandidate = &.{},
    err: ?anyerror = null,

    fn init() CandidateChunkResult {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
        };
    }

    fn deinit(self: *CandidateChunkResult) void {
        self.arena.deinit();
    }
};

const CandidateChunkJob = struct {
    records: []const BinaryRecord,
    result: *CandidateChunkResult,
};

const FilterChunkResult = struct {
    temp_output_path: []const u8 = "",
    entry_count: usize = 0,
    redirect_count: usize = 0,
    err: ?anyerror = null,
};

const FilterChunkJob = struct {
    io: std.Io,
    records: []const BinaryRecord,
    valid_titles: *const ValidTitleSet,
    total_records: usize,
    temp_output_path: []const u8,
    result: *FilterChunkResult,
    progress: *BuildProgress,
};

fn filterAliasRecordsFromBinary(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    thread_override: ?usize,
    progress: *BuildProgress,
) !FilterResult {
    var source = try mmapReadOnlyPath(io, source_path);
    defer source.deinit();

    const mapped = source.bytes();
    const inspected = try validateDictionaryHeader(mapped, source.stat.size);
    const records = try collectBinaryRecords(allocator, mapped, inspected);
    defer allocator.free(records);

    const worker_count = filterThreadCount(records.len, thread_override);
    var valid_titles = try collectValidTitlesFromBinary(allocator, records, worker_count);
    defer deinitValidTitleSet(std.heap.smp_allocator, &valid_titles);

    progress.filter(0, records.len, 0);
    if (worker_count == 1) {
        return filterAliasRecordsSequential(io, allocator, dest_path, records, &valid_titles, progress);
    }
    return filterAliasRecordsParallel(io, allocator, dest_path, records, &valid_titles, worker_count, progress);
}

fn collectValidTitlesFromBinary(
    allocator: std.mem.Allocator,
    records: []const BinaryRecord,
    worker_count: usize,
) !ValidTitleSet {
    if (worker_count == 1) return collectValidTitlesFromBinarySequential(records);

    const chunk_results = try allocator.alloc(CandidateChunkResult, worker_count);
    defer {
        for (chunk_results) |*result| result.deinit();
        allocator.free(chunk_results);
    }
    for (chunk_results) |*result| result.* = CandidateChunkResult.init();

    const jobs = try allocator.alloc(CandidateChunkJob, worker_count);
    defer allocator.free(jobs);

    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();

    var start: usize = 0;
    for (jobs, 0..) |*job, idx| {
        const end = partitionEnd(records.len, worker_count, idx);
        job.* = .{
            .records = records[start..end],
            .result = &chunk_results[idx],
        };
        start = end;
    }

    for (jobs[1..], threads) |*job, *thread| {
        thread.* = try std.Thread.spawn(.{}, collectCandidateChunk, .{job});
        started_threads += 1;
    }
    collectCandidateChunk(&jobs[0]);
    for (threads[0..started_threads]) |thread| thread.join();

    for (chunk_results) |result| {
        if (result.err) |err| return err;
    }

    return resolveValidTitlesFromCandidateChunks(chunk_results);
}

fn collectValidTitlesFromBinarySequential(records: []const BinaryRecord) !ValidTitleSet {
    var chunk = CandidateChunkResult.init();
    defer chunk.deinit();
    var job = CandidateChunkJob{
        .records = records,
        .result = &chunk,
    };
    collectCandidateChunk(&job);
    if (chunk.err) |err| return err;
    return resolveValidTitlesFromCandidateChunks(&.{chunk});
}

fn collectCandidateChunk(job: *CandidateChunkJob) void {
    collectCandidateChunkFallible(job) catch |err| {
        job.result.err = err;
    };
}

fn collectCandidateChunkFallible(job: *CandidateChunkJob) !void {
    const allocator = job.result.arena.allocator();
    const candidates = try allocator.alloc(AliasCandidate, job.records.len);
    for (job.records, 0..) |record, idx| {
        candidates[idx] = try buildAliasCandidateFromBinaryRecord(allocator, allocator, record);
    }
    job.result.candidates = candidates;
}

fn resolveValidTitlesFromCandidateChunks(chunks: []const CandidateChunkResult) !ValidTitleSet {
    var valid_titles = ValidTitleSet.init(std.heap.smp_allocator);
    errdefer deinitValidTitleSet(std.heap.smp_allocator, &valid_titles);

    for (chunks) |*chunk| {
        for (chunk.candidates) |*candidate| {
            if (!candidate.base_valid) continue;
            candidate.valid = true;
            if (!valid_titles.contains(candidate.normalized_title)) {
                try valid_titles.put(try std.heap.smp_allocator.dupe(u8, candidate.normalized_title), {});
            }
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (chunks) |*chunk| {
            for (chunk.candidates) |*candidate| {
                if (candidate.valid) continue;
                for (candidate.normalized_targets) |target| {
                    if (!valid_titles.contains(target)) continue;
                    candidate.valid = true;
                    if (!valid_titles.contains(candidate.normalized_title)) {
                        try valid_titles.put(try std.heap.smp_allocator.dupe(u8, candidate.normalized_title), {});
                    }
                    changed = true;
                    break;
                }
            }
        }
    }

    return valid_titles;
}

fn collectBinaryRecords(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    inspected: format.InspectedDictionary,
) ![]BinaryRecord {
    const records = try allocator.alloc(BinaryRecord, inspected.header.entry_count);
    errdefer allocator.free(records);

    const titles_end: usize = @intCast(inspected.layout.titles_offset + inspected.layout.titles_len);
    const payloads_start: usize = @intCast(inspected.layout.records_offset);
    const payloads_end: usize = @intCast(inspected.layout.records_offset + inspected.layout.records_len);
    const length_bytes = mapped[@as(usize, @intCast(inspected.layout.lengths_offset))..@as(usize, @intCast(inspected.layout.lengths_offset + inspected.layout.lengths_len))];

    var title_cursor: usize = @intCast(inspected.layout.titles_offset);
    var payload_cursor: usize = payloads_start;
    for (records, 0..) |*record, idx| {
        const title = try readNullTerminatedSlice(mapped, &title_cursor, titles_end);
        const payload_len = try format.payloadLengthAt(length_bytes, idx);
        if (payload_len == 0 or payload_len > payloads_end - payload_cursor) return error.InvalidDictionaryFile;

        const full_payload = mapped[payload_cursor .. payload_cursor + payload_len];
        payload_cursor += payload_len;
        record.* = .{
            .flags = full_payload[0],
            .title = title,
            .payload = full_payload[1..],
        };
    }
    if (title_cursor != titles_end or payload_cursor != payloads_end) return error.InvalidDictionaryFile;
    return records;
}

fn filterAliasRecordsSequential(
    io: std.Io,
    allocator: std.mem.Allocator,
    dest_path: []const u8,
    records: []const BinaryRecord,
    valid_titles: *const ValidTitleSet,
    progress: *BuildProgress,
) !FilterResult {
    var output = try OutputWriter.init(io, allocator, dest_path);
    defer output.deinit(allocator);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    for (records) |record| {
        const kept = try filterSingleBinaryRecord(io, allocator, valid_titles, &output, record, scratch.allocator());
        progress.filterAdvance(1, records.len, if (kept) 1 else 0);
        _ = scratch.reset(.retain_capacity);
    }

    try output.finish();
    return .{
        .entry_count = output.entry_count,
        .redirect_count = output.redirect_count,
    };
}

fn filterAliasRecordsParallel(
    io: std.Io,
    allocator: std.mem.Allocator,
    dest_path: []const u8,
    records: []const BinaryRecord,
    valid_titles: *const ValidTitleSet,
    worker_count: usize,
    progress: *BuildProgress,
) !FilterResult {
    const results = try allocator.alloc(FilterChunkResult, worker_count);
    defer {
        for (results) |result| if (result.temp_output_path.len != 0) allocator.free(result.temp_output_path);
        allocator.free(results);
    }
    for (results) |*result| result.* = .{};

    const jobs = try allocator.alloc(FilterChunkJob, worker_count);
    defer allocator.free(jobs);

    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();

    var start: usize = 0;
    for (jobs, results, 0..) |*job, *result, idx| {
        const end = partitionEnd(records.len, worker_count, idx);
        const temp_output_path = try std.fmt.allocPrint(allocator, "{s}.part{d}", .{ dest_path, idx });
        result.temp_output_path = temp_output_path;
        std.Io.Dir.cwd().deleteFile(io, temp_output_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        job.* = .{
            .io = io,
            .records = records[start..end],
            .valid_titles = valid_titles,
            .total_records = records.len,
            .temp_output_path = temp_output_path,
            .result = result,
            .progress = progress,
        };
        start = end;
    }

    for (jobs[1..], threads) |*job, *thread| {
        thread.* = try std.Thread.spawn(.{}, filterChunkWorker, .{job});
        started_threads += 1;
    }
    filterChunkWorker(&jobs[0]);
    for (threads[0..started_threads]) |thread| thread.join();

    for (results) |result| {
        if (result.err) |err| return err;
    }

    var output = try OutputWriter.init(io, allocator, dest_path);
    defer output.deinit(allocator);

    for (results) |result| {
        defer std.Io.Dir.cwd().deleteFile(io, result.temp_output_path) catch {};
        try appendChunkFileToOutput(io, result.temp_output_path, &output);
    }
    try output.finish();

    return .{
        .entry_count = output.entry_count,
        .redirect_count = output.redirect_count,
    };
}

fn filterChunkWorker(job: *FilterChunkJob) void {
    filterChunkWorkerFallible(job) catch |err| {
        job.result.err = err;
    };
}

fn filterChunkWorkerFallible(job: *FilterChunkJob) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();

    var output = try OutputWriter.init(job.io, std.heap.smp_allocator, job.temp_output_path);
    defer output.deinit(std.heap.smp_allocator);

    for (job.records) |record| {
        const kept = try filterSingleBinaryRecord(job.io, std.heap.smp_allocator, job.valid_titles, &output, record, scratch.allocator());
        job.progress.filterAdvance(1, job.total_records, if (kept) 1 else 0);
        _ = scratch.reset(.retain_capacity);
    }
    try output.finish();
    job.result.entry_count = output.entry_count;
    job.result.redirect_count = output.redirect_count;
}

fn filterSingleBinaryRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    valid_titles: *const ValidTitleSet,
    output: *OutputWriter,
    record: BinaryRecord,
    scratch_allocator: std.mem.Allocator,
) !bool {
    _ = io;
    _ = allocator;
    if ((record.flags & format.record_flag_has_raw) != 0) {
        const raw_metadata = try format.decodeRawRecordMetadataAlloc(scratch_allocator, record.payload);
        const filtered_targets = try filterCanonicalTargetsAlloc(scratch_allocator, raw_metadata.canonical_targets, valid_titles);
        if (raw_metadata.alias_only and raw_metadata.canonical_targets.len != 0 and filtered_targets.len == 0) return false;

        if (filtered_targets.len == raw_metadata.canonical_targets.len) {
            try output.writeExistingRecord(record.title, record.flags, record.payload);
        } else {
            const encoded_raw = try format.rawRecordContentPayload(record.payload);
            try output.writeRepackedRawRecord(
                record.title,
                raw_metadata.alt_forms,
                filtered_targets,
                raw_metadata.alias_only,
                encoded_raw,
            );
        }
        return true;
    }

    const target = try format.decodeAliasRecordTargetAlloc(scratch_allocator, record.payload);
    const normalized_target = try normalizeViewAlloc(scratch_allocator, target);
    if (!valid_titles.contains(normalized_target)) return false;
    try output.writeExistingRecord(record.title, record.flags, record.payload);
    return true;
}

fn buildAliasCandidateFromBinaryRecord(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    record: BinaryRecord,
) !AliasCandidate {
    const normalized_title = try normalizeOwnedAlloc(allocator, record.title);
    errdefer allocator.free(normalized_title);

    if ((record.flags & format.record_flag_has_raw) != 0) {
        const raw_metadata = try format.decodeRawRecordMetadataAlloc(scratch_allocator, record.payload);
        const normalized_targets = try normalizeTargetsAlloc(allocator, raw_metadata.canonical_targets);
        errdefer freeOwnedStringSlice(allocator, normalized_targets);
        return .{
            .normalized_title = normalized_title,
            .normalized_targets = normalized_targets,
            .base_valid = !raw_metadata.alias_only,
        };
    }

    const target = try format.decodeAliasRecordTargetAlloc(scratch_allocator, record.payload);
    const normalized_target = try normalizeOwnedAlloc(allocator, target);
    errdefer allocator.free(normalized_target);
    const targets = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(targets);
    targets[0] = normalized_target;
    return .{
        .normalized_title = normalized_title,
        .normalized_targets = targets,
        .base_valid = false,
    };
}

fn normalizeOwnedAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (normalize.isIdentity(value)) return allocator.dupe(u8, value);
    return normalize.normalizeAlloc(allocator, value);
}

fn normalizeViewAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (normalize.isIdentity(value)) return value;
    return normalize.normalizeAlloc(allocator, value);
}

fn mapWholeFile(file: std.Io.File, size_u64: u64) ![]align(std.heap.page_size_min) const u8 {
    const size = std.math.cast(usize, size_u64) orelse return error.FileTooBig;
    if (size < 4) return error.InvalidDictionaryFile;

    return try std.posix.mmap(
        null,
        std.mem.alignForward(usize, size, std.heap.page_size_min),
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

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

    return .{
        .stat = stat,
        .mapping = try mapWholeFile(file, stat.size),
    };
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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
            .PERM => return error.PermissionDenied,
            .TXTBSY => return error.FileBusy,
            else => |err| return std.posix.unexpectedErrno(err),
        },
        else => @compileError("truncateFd is only implemented for Linux"),
    }
}

fn writeMappedFile(path: []const u8, bytes: []const u8) !void {
    var mapped_file = try MappedWritableFile.create(std.testing.io, path, @max(bytes.len, 1));
    defer mapped_file.deinit();

    @memcpy(mapped_file.bytes()[0..bytes.len], bytes);
    try mapped_file.finish(bytes.len);
}

fn validateDictionaryHeader(mapped: []const u8, size_u64: u64) !format.InspectedDictionary {
    const size = std.math.cast(usize, size_u64) orelse return error.FileTooBig;
    if (size != mapped.len) return error.InvalidDictionaryFile;
    return format.inspectDictionary(mapped) catch |err| switch (err) {
        error.InvalidDictionaryFile => error.InvalidDictionaryFile,
        error.FileTooBig => error.FileTooBig,
    };
}

fn normalizeTargetsAlloc(allocator: std.mem.Allocator, targets: []const []const u8) ![][]const u8 {
    const normalized_targets = try allocator.alloc([]const u8, targets.len);
    var count: usize = 0;
    errdefer {
        while (count > 0) : (count -= 1) allocator.free(normalized_targets[count - 1]);
        allocator.free(normalized_targets);
    }
    for (targets, 0..) |target, idx| {
        normalized_targets[idx] = try normalize.normalizeAlloc(allocator, target);
        count += 1;
    }
    return normalized_targets;
}

fn freeOwnedStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitValidTitleSet(allocator: std.mem.Allocator, valid_titles: *ValidTitleSet) void {
    var iter = valid_titles.keyIterator();
    while (iter.next()) |key_ptr| allocator.free(key_ptr.*);
    valid_titles.deinit();
}

fn filterCanonicalTargetsAlloc(
    allocator: std.mem.Allocator,
    canonical_targets: []const []const u8,
    valid_titles: *const ValidTitleSet,
) ![]const []const u8 {
    const filtered = try allocator.alloc([]const u8, canonical_targets.len);
    var kept: usize = 0;
    for (canonical_targets) |target| {
        const normalized = try normalizeViewAlloc(allocator, target);
        defer if (normalized.ptr != target.ptr) allocator.free(normalized);
        if (!valid_titles.contains(normalized)) continue;
        filtered[kept] = target;
        kept += 1;
    }
    return filtered[0..kept];
}

fn readNullTerminatedSlice(bytes: []const u8, cursor: *usize, limit: usize) ![]const u8 {
    if (cursor.* >= limit) return error.InvalidDictionaryFile;
    const terminator = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidDictionaryFile;
    if (terminator >= limit) return error.InvalidDictionaryFile;
    const out = bytes[cursor.*..terminator];
    cursor.* = terminator + 1;
    return out;
}

const OutputWriter = struct {
    const flush_threshold = 1 << 20;
    const initial_capacity = 8 << 20;

    io: std.Io,
    allocator: std.mem.Allocator,
    final_path: []const u8,
    titles_path: []const u8,
    payloads_path: []const u8,
    titles_file: MappedWritableFile,
    payloads_file: MappedWritableFile,
    flushed_title_bytes: u64 = 0,
    flushed_payload_bytes: u64 = 0,
    entry_count: usize = 0,
    raw_entry_count: usize = 0,
    redirect_count: usize = 0,
    length_bytes: std.ArrayList(u8) = .empty,
    title_buffer: std.ArrayList(u8) = .empty,
    payload_buffer: std.ArrayList(u8) = .empty,
    // Scratch buffer reused for compact-encoding titles, fields, and raw section payloads.
    encode_buf: std.ArrayList(u8) = .empty,
    // Scratch buffer reused for whole record payload bodies before the leading flag byte is added.
    record_buf: std.ArrayList(u8) = .empty,

    fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !OutputWriter {
        const titles_path = try std.fmt.allocPrint(allocator, "{s}.titles", .{path});
        errdefer allocator.free(titles_path);
        const payloads_path = try std.fmt.allocPrint(allocator, "{s}.payloads", .{path});
        errdefer allocator.free(payloads_path);

        deleteFileIfExists(io, titles_path) catch {};
        deleteFileIfExists(io, payloads_path) catch {};

        var titles_file = try MappedWritableFile.create(io, titles_path, initial_capacity);
        errdefer titles_file.deinit();
        var payloads_file = try MappedWritableFile.create(io, payloads_path, initial_capacity);
        errdefer payloads_file.deinit();
        return .{
            .io = io,
            .allocator = allocator,
            .final_path = path,
            .titles_path = titles_path,
            .payloads_path = payloads_path,
            .titles_file = titles_file,
            .payloads_file = payloads_file,
        };
    }

    fn deinit(self: *OutputWriter, allocator: std.mem.Allocator) void {
        self.length_bytes.deinit(allocator);
        self.title_buffer.deinit(allocator);
        self.payload_buffer.deinit(allocator);
        self.encode_buf.deinit(allocator);
        self.record_buf.deinit(allocator);
        self.titles_file.deinit();
        self.payloads_file.deinit();
        if (self.titles_path.len != 0) {
            deleteFileIfExists(self.io, self.titles_path) catch {};
            allocator.free(self.titles_path);
            self.titles_path = "";
        }
        if (self.payloads_path.len != 0) {
            deleteFileIfExists(self.io, self.payloads_path) catch {};
            allocator.free(self.payloads_path);
            self.payloads_path = "";
        }
    }

    fn finish(self: *OutputWriter) !void {
        try self.flushTitleBuffer();
        try self.flushPayloadBuffer();
        try self.titles_file.finish(@intCast(self.flushed_title_bytes));
        try self.payloads_file.finish(@intCast(self.flushed_payload_bytes));

        var titles = try mmapReadOnlyPath(self.io, self.titles_path);
        defer titles.deinit();
        var payloads = try mmapReadOnlyPath(self.io, self.payloads_path);
        defer payloads.deinit();

        const length_bytes_len = self.length_bytes.items.len;
        const total_len = try std.math.add(usize, 4, length_bytes_len);
        const total_with_titles = try std.math.add(usize, total_len, titles.bytes().len);
        const final_len = try std.math.add(usize, total_with_titles, payloads.bytes().len);

        var out_file = try MappedWritableFile.create(self.io, self.final_path, @max(final_len, 1));
        defer out_file.deinit();

        const out = out_file.bytes();
        std.mem.writeInt(u32, out[0..4], std.math.cast(u32, self.entry_count) orelse return error.FileTooBig, .little);

        var cursor: usize = 4;
        if (length_bytes_len != 0) {
            @memcpy(out[cursor .. cursor + length_bytes_len], self.length_bytes.items);
            cursor += length_bytes_len;
        }
        if (titles.bytes().len != 0) {
            @memcpy(out[cursor .. cursor + titles.bytes().len], titles.bytes());
            cursor += titles.bytes().len;
        }
        if (payloads.bytes().len != 0) {
            @memcpy(out[cursor .. cursor + payloads.bytes().len], payloads.bytes());
            cursor += payloads.bytes().len;
        }
        try out_file.finish(final_len);

        deleteFileIfExists(self.io, self.titles_path) catch {};
        self.allocator.free(self.titles_path);
        self.titles_path = "";
        deleteFileIfExists(self.io, self.payloads_path) catch {};
        self.allocator.free(self.payloads_path);
        self.payloads_path = "";
    }

    fn writeRawRecord(
        self: *OutputWriter,
        title: []const u8,
        stored_sections: []const u8,
        metadata: wikitext.EntryMetadata,
    ) !void {
        self.record_buf.items.len = 0;
        try self.record_buf.append(self.allocator, format.record_flag_has_raw);
        try self.appendRawPayload(
            metadata.alt_forms.items,
            metadata.canonical_targets.items,
            metadata.alias_only,
            stored_sections,
        );
        try self.writeRecord(title, self.record_buf.items);
    }

    fn writeRedirectRecord(
        self: *OutputWriter,
        title: []const u8,
        target: []const u8,
    ) !void {
        self.record_buf.items.len = 0;
        try self.record_buf.append(self.allocator, 0);
        try self.appendCompactSlice(&self.record_buf, target);
        try self.writeRecord(title, self.record_buf.items);
    }

    fn writeExistingRecord(self: *OutputWriter, title: []const u8, flags: u8, payload: []const u8) !void {
        self.record_buf.items.len = 0;
        try self.record_buf.append(self.allocator, flags);
        try self.record_buf.appendSlice(self.allocator, payload);
        try self.writeRecord(title, self.record_buf.items);
    }

    fn appendCompactSlice(self: *OutputWriter, out: *std.ArrayList(u8), value: []const u8) !void {
        const encoded = try compact.encodeToList(&self.encode_buf, self.allocator, value);
        var len_buf: [10]u8 = undefined;
        try out.appendSlice(self.allocator, format.encodeVarUInt(&len_buf, encoded.len));
        try out.appendSlice(self.allocator, encoded);
    }

    fn appendRawPayload(
        self: *OutputWriter,
        alt_forms: []const []const u8,
        canonical_targets: []const []const u8,
        alias_only: bool,
        stored_sections: []const u8,
    ) !void {
        var len_buf: [10]u8 = undefined;
        try self.record_buf.appendSlice(self.allocator, format.encodeVarUInt(&len_buf, alt_forms.len));
        for (alt_forms) |alt_form| try self.appendCompactSlice(&self.record_buf, alt_form);

        try self.record_buf.appendSlice(self.allocator, format.encodeVarUInt(&len_buf, canonical_targets.len));
        for (canonical_targets) |target| try self.appendCompactSlice(&self.record_buf, target);

        try self.record_buf.append(self.allocator, if (alias_only) 1 else 0);
        try self.appendCompactSlice(&self.record_buf, stored_sections);
    }

    fn writeRepackedRawRecord(
        self: *OutputWriter,
        title: []const u8,
        alt_forms: []const []const u8,
        canonical_targets: []const []const u8,
        alias_only: bool,
        encoded_raw: []const u8,
    ) !void {
        self.record_buf.items.len = 0;
        try self.record_buf.append(self.allocator, format.record_flag_has_raw);
        var len_buf: [10]u8 = undefined;
        try self.record_buf.appendSlice(self.allocator, format.encodeVarUInt(&len_buf, alt_forms.len));
        for (alt_forms) |alt_form| try self.appendCompactSlice(&self.record_buf, alt_form);

        try self.record_buf.appendSlice(self.allocator, format.encodeVarUInt(&len_buf, canonical_targets.len));
        for (canonical_targets) |target| try self.appendCompactSlice(&self.record_buf, target);

        try self.record_buf.append(self.allocator, if (alias_only) 1 else 0);
        try self.record_buf.appendSlice(self.allocator, format.encodeVarUInt(&len_buf, encoded_raw.len));
        try self.record_buf.appendSlice(self.allocator, encoded_raw);
        try self.writeRecord(title, self.record_buf.items);
    }

    fn writeRecord(self: *OutputWriter, title: []const u8, full_payload: []const u8) !void {
        if (std.mem.indexOfScalar(u8, title, 0) != null) return error.InvalidDictionaryFile;
        var len_buf: [3]u8 = undefined;
        try self.length_bytes.appendSlice(self.allocator, try format.writeU24(&len_buf, full_payload.len));
        try self.writeTitleBytes(title);
        try self.writeTitleBytes(&.{0});
        try self.writePayloadBytes(full_payload);

        self.entry_count += 1;
        if (full_payload[0] == format.record_flag_has_raw) {
            self.raw_entry_count += 1;
        } else {
            self.redirect_count += 1;
        }
    }

    fn writeLengthBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.length_bytes.appendSlice(self.allocator, bytes);
    }

    fn writeTitleBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.title_buffer.appendSlice(self.allocator, bytes);
        if (self.title_buffer.items.len >= flush_threshold) try self.flushTitleBuffer();
    }

    fn writePayloadBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.payload_buffer.appendSlice(self.allocator, bytes);
        if (self.payload_buffer.items.len >= flush_threshold) try self.flushPayloadBuffer();
    }

    fn flushTitleBuffer(self: *OutputWriter) !void {
        if (self.title_buffer.items.len == 0) return;
        const start: usize = @intCast(self.flushed_title_bytes);
        const end = start + self.title_buffer.items.len;
        try self.titles_file.ensureCapacity(end);
        @memcpy(self.titles_file.bytes()[start..end], self.title_buffer.items);
        self.flushed_title_bytes += self.title_buffer.items.len;
        self.title_buffer.items.len = 0;
    }

    fn flushPayloadBuffer(self: *OutputWriter) !void {
        if (self.payload_buffer.items.len == 0) return;
        const start: usize = @intCast(self.flushed_payload_bytes);
        const end = start + self.payload_buffer.items.len;
        try self.payloads_file.ensureCapacity(end);
        @memcpy(self.payloads_file.bytes()[start..end], self.payload_buffer.items);
        self.flushed_payload_bytes += self.payload_buffer.items.len;
        self.payload_buffer.items.len = 0;
    }
};

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

const MappedWritableFile = struct {
    fd: std.posix.fd_t,
    mapping: []align(std.heap.page_size_min) u8,
    capacity: usize,
    finished: bool = false,

    fn create(io: std.Io, path: []const u8, initial_capacity: usize) !MappedWritableFile {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o666);
        errdefer _ = std.os.linux.close(fd);

        const capacity = std.mem.alignForward(usize, @max(initial_capacity, 1), std.heap.page_size_min);
        try truncateFd(fd, capacity);
        const mapping = try std.posix.mmap(
            null,
            capacity,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        _ = io;
        return .{
            .fd = fd,
            .mapping = mapping,
            .capacity = capacity,
        };
    }

    fn bytes(self: *MappedWritableFile) []u8 {
        return self.mapping[0..self.capacity];
    }

    fn ensureCapacity(self: *MappedWritableFile, needed: usize) !void {
        if (needed <= self.capacity) return;

        var new_capacity = self.capacity;
        while (new_capacity < needed) new_capacity *= 2;
        new_capacity = std.mem.alignForward(usize, new_capacity, std.heap.page_size_min);

        std.posix.munmap(self.mapping);
        try truncateFd(self.fd, new_capacity);
        self.mapping = try std.posix.mmap(
            null,
            new_capacity,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            self.fd,
            0,
        );
        self.capacity = new_capacity;
    }

    fn finish(self: *MappedWritableFile, final_len: usize) !void {
        if (self.finished) return;
        std.posix.munmap(self.mapping);
        self.mapping = undefined;
        try truncateFd(self.fd, final_len);
        _ = std.os.linux.close(self.fd);
        self.finished = true;
    }

    fn deinit(self: *MappedWritableFile) void {
        if (self.finished) return;
        std.posix.munmap(self.mapping);
        _ = std.os.linux.close(self.fd);
        self.finished = true;
    }
};

test "output writer buffers survive page arena resets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin.tmp", .{tmp.sub_path});
    defer std.testing.allocator.free(output_path);

    var writer = try OutputWriter.init(std.testing.io, std.testing.allocator, output_path);
    defer writer.deinit(std.testing.allocator);

    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page_arena.deinit();

    const first_alloc = page_arena.allocator();
    const first_title = try first_alloc.dupe(u8, "color");
    const first_payload = try first_alloc.dupe(u8, "==English==\n===Noun===\n# [[light]]\n");
    var metadata = try wikitext.extractEntryMetadata(std.testing.allocator, first_title, first_payload);
    defer metadata.deinit(std.testing.allocator);
    try writer.writeRawRecord(first_title, first_payload, metadata);

    _ = page_arena.reset(.retain_capacity);

    const second_alloc = page_arena.allocator();
    const second_title = try second_alloc.dupe(u8, "colour");
    const second_payload = try second_alloc.dupe(u8, "color");
    try writer.writeRedirectRecord(second_title, second_payload);
    try writer.finish();

    try std.testing.expectEqual(@as(usize, 2), writer.entry_count);
}

test "output writer accepts english section without trailing heading newline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin.tmp", .{tmp.sub_path});
    defer std.testing.allocator.free(output_path);

    var writer = try OutputWriter.init(std.testing.io, std.testing.allocator, output_path);
    defer writer.deinit(std.testing.allocator);

    var metadata = try wikitext.extractEntryMetadata(std.testing.allocator, "color", "==English==");
    defer metadata.deinit(std.testing.allocator);
    try writer.writeRawRecord("color", "==English==", metadata);
    try writer.finish();

    try std.testing.expectEqual(@as(usize, 1), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 1), writer.raw_entry_count);
}

test "full build filters unresolved alias records in binary second pass" {
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
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colour</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{alternative form of|en|color}}
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colours</title>
        \\<ns>0</ns>
        \\<redirect title="colour"/>
        \\</page>
        \\<page>
        \\<title>broken</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{alternative form of|en|missing}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    const stats = try build(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.english_entries);
    try std.testing.expectEqual(@as(usize, 1), stats.redirect_aliases);

    var mapped_db = try mmapReadOnlyPath(std.testing.io, db_path);
    defer mapped_db.deinit();
    const mapped = mapped_db.bytes();
    const inspected = try validateDictionaryHeader(mapped, mapped.len);
    try std.testing.expectEqual(@as(u32, 3), inspected.header.entry_count);
    try std.testing.expectEqual(@as(u32, 2), inspected.header.raw_entry_count);
    try std.testing.expectEqual(@as(u32, 1), inspected.header.redirect_count);

    const records = try collectBinaryRecords(std.testing.allocator, mapped, inspected);
    defer std.testing.allocator.free(records);

    var saw_color = false;
    var saw_colour = false;
    var saw_colours = false;
    var saw_broken = false;
    for (records) |record| {
        if (std.mem.eql(u8, record.title, "color")) saw_color = true;
        if (std.mem.eql(u8, record.title, "colour")) saw_colour = true;
        if (std.mem.eql(u8, record.title, "colours")) saw_colours = true;
        if (std.mem.eql(u8, record.title, "broken")) saw_broken = true;
    }

    try std.testing.expect(saw_color);
    try std.testing.expect(saw_colour);
    try std.testing.expect(saw_colours);
    try std.testing.expect(!saw_broken);
}
