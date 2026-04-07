const std = @import("std");
const builtin = @import("builtin");
const zxml = @import("zxml");
const normalize = @import("normalize");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");
const wikitext = @import("wikitext_source");
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
        stats.english_entries = output.raw_entry_count;
        stats.redirect_aliases = output.redirect_count;
    }

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
        .english_entries = output.raw_entry_count,
        .redirect_aliases = output.redirect_count,
    };
}

fn appendChunkFileToOutput(io: std.Io, chunk_path: []const u8, output: *OutputWriter) !void {
    var chunk = try mmapReadOnlyPath(io, chunk_path);
    defer chunk.deinit();

    const mapped = chunk.bytes();
    const inspected = try validateTempDictionaryHeader(mapped, chunk.stat.size);

    try output.writeRawTitleBytes(mapped[
        @as(usize, @intCast(inspected.layout.raw_titles_offset))..
            @as(usize, @intCast(inspected.layout.raw_titles_offset + inspected.layout.raw_titles_len))
    ]);
    try output.writeAliasTitleBytes(mapped[
        @as(usize, @intCast(inspected.layout.alias_titles_offset))..
            @as(usize, @intCast(inspected.layout.alias_titles_offset + inspected.layout.alias_titles_len))
    ]);
    try output.writeAliasTargetTitleBytes(mapped[
        @as(usize, @intCast(inspected.layout.alias_target_titles_offset))..
            @as(usize, @intCast(inspected.layout.alias_target_titles_offset + inspected.layout.alias_target_titles_len))
    ]);
    try output.writeRawPayloadBytes(mapped[
        @as(usize, @intCast(inspected.layout.raw_payloads_offset))..
            @as(usize, @intCast(inspected.layout.raw_payloads_offset + inspected.layout.raw_payloads_len))
    ]);
    output.raw_entry_count += inspected.header.raw_count;
    output.redirect_count += inspected.header.alias_count;
    output.entry_count += inspected.header.entryCount();
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
            try output.writeRawRecord(title.value, stored_sections);
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

const temp_magic = "WIKTMP01";

const TempHeader = extern struct {
    magic_bytes: [8]u8,
    raw_count: u32,
    alias_count: u32,
    raw_titles_len: u64,
    alias_titles_len: u64,
    alias_target_titles_len: u64,
    raw_payloads_len: u64,

    fn init(
        raw_count: u32,
        alias_count: u32,
        raw_titles_len: u64,
        alias_titles_len: u64,
        alias_target_titles_len: u64,
        raw_payloads_len: u64,
    ) TempHeader {
        return .{
            .magic_bytes = temp_magic.*,
            .raw_count = raw_count,
            .alias_count = alias_count,
            .raw_titles_len = raw_titles_len,
            .alias_titles_len = alias_titles_len,
            .alias_target_titles_len = alias_target_titles_len,
            .raw_payloads_len = raw_payloads_len,
        };
    }

    fn entryCount(self: TempHeader) u32 {
        return self.raw_count + self.alias_count;
    }
};

const temp_header_len = @sizeOf(TempHeader);

const TempLayout = struct {
    raw_titles_offset: u64,
    raw_titles_len: u64,
    alias_titles_offset: u64,
    alias_titles_len: u64,
    alias_target_titles_offset: u64,
    alias_target_titles_len: u64,
    raw_payloads_offset: u64,
    raw_payloads_len: u64,
};

const InspectedTempDictionary = struct {
    header: TempHeader,
    layout: TempLayout,
};

const FilterResult = struct {
    entry_count: usize,
    redirect_count: usize,
};

fn filterAliasRecordsFromBinary(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    thread_override: ?usize,
    progress: *BuildProgress,
) !FilterResult {
    _ = thread_override;
    var source = try mmapReadOnlyPath(io, source_path);
    defer source.deinit();

    const mapped = source.bytes();
    const inspected = try validateTempDictionaryHeader(mapped, source.stat.size);
    const raw_candidates = try collectTempRawCandidatesAlloc(allocator, mapped, inspected);
    defer {
        for (raw_candidates) |*candidate| candidate.deinit(allocator);
        allocator.free(raw_candidates);
    }
    const alias_candidates = try collectTempAliasCandidatesAlloc(allocator, mapped, inspected);
    defer {
        for (alias_candidates) |*candidate| candidate.deinit(allocator);
        allocator.free(alias_candidates);
    }
    try resolveReachableCandidatesAlloc(allocator, raw_candidates, alias_candidates);

    progress.filter(0, raw_candidates.len + alias_candidates.len, 0);
    return writeFinalDictionaryFromTempCandidates(
        io,
        allocator,
        dest_path,
        raw_candidates,
        alias_candidates,
        progress,
    );
}

const TempRawCandidate = struct {
    title_encoded: []const u8,
    payload_encoded: []const u8,
    normalized_title: []const u8,
    normalized_targets: []const []const u8,
    base_valid: bool,
    valid: bool = false,

    fn deinit(self: *TempRawCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized_title);
        freeOwnedStringSlice(allocator, self.normalized_targets);
    }
};

const TempAliasCandidate = struct {
    title_encoded: []const u8,
    normalized_title: []const u8,
    normalized_target: []const u8,
    keep: bool = false,

    fn deinit(self: *TempAliasCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized_title);
        allocator.free(self.normalized_target);
    }
};

fn inspectTempDictionary(bytes: []const u8) !InspectedTempDictionary {
    if (bytes.len < temp_header_len) return error.InvalidDictionaryFile;
    const header = std.mem.bytesToValue(TempHeader, bytes[0..temp_header_len]);
    if (!std.mem.eql(u8, &header.magic_bytes, temp_magic)) return error.InvalidDictionaryFile;

    var cursor: u64 = temp_header_len;
    const raw_titles_offset = cursor;
    cursor = std.math.add(u64, cursor, header.raw_titles_len) catch return error.FileTooBig;
    const alias_titles_offset = cursor;
    cursor = std.math.add(u64, cursor, header.alias_titles_len) catch return error.FileTooBig;
    const alias_target_titles_offset = cursor;
    cursor = std.math.add(u64, cursor, header.alias_target_titles_len) catch return error.FileTooBig;
    const raw_payloads_offset = cursor;
    cursor = std.math.add(u64, cursor, header.raw_payloads_len) catch return error.FileTooBig;
    if (cursor != bytes.len) return error.InvalidDictionaryFile;

    return .{
        .header = header,
        .layout = .{
            .raw_titles_offset = raw_titles_offset,
            .raw_titles_len = header.raw_titles_len,
            .alias_titles_offset = alias_titles_offset,
            .alias_titles_len = header.alias_titles_len,
            .alias_target_titles_offset = alias_target_titles_offset,
            .alias_target_titles_len = header.alias_target_titles_len,
            .raw_payloads_offset = raw_payloads_offset,
            .raw_payloads_len = header.raw_payloads_len,
        },
    };
}

fn collectTempRawCandidatesAlloc(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    inspected: InspectedTempDictionary,
) ![]TempRawCandidate {
    const raw_count: usize = inspected.header.raw_count;
    const out = try allocator.alloc(TempRawCandidate, raw_count);
    errdefer allocator.free(out);

    var title_cursor: usize = @intCast(inspected.layout.raw_titles_offset);
    const titles_end: usize = @intCast(inspected.layout.raw_titles_offset + inspected.layout.raw_titles_len);
    var payload_cursor: usize = @intCast(inspected.layout.raw_payloads_offset);
    const payloads_end: usize = @intCast(inspected.layout.raw_payloads_offset + inspected.layout.raw_payloads_len);

    var built: usize = 0;
    errdefer {
        while (built != 0) : (built -= 1) out[built - 1].deinit(allocator);
    }
    for (out) |*candidate| {
        const title_encoded = try readNullTerminatedSlice(mapped, &title_cursor, titles_end);
        const payload_encoded = try readNullTerminatedSlice(mapped, &payload_cursor, payloads_end);

        const decoded_title = try compact.decodeAlloc(allocator, title_encoded);
        defer allocator.free(decoded_title);
        const decoded_payload = try compact.decodeAlloc(allocator, payload_encoded);
        defer allocator.free(decoded_payload);

        const normalized_title = try normalizeOwnedAlloc(allocator, decoded_title);
        errdefer allocator.free(normalized_title);

        var metadata: wikitext.EntryMetadata = .{};
        defer metadata.deinit(allocator);
        if (wikitext.extractEnglishSection(decoded_payload)) |english_section| {
            metadata = try wikitext.extractEntryMetadata(allocator, decoded_title, english_section);
        }
        const normalized_targets = try normalizeTargetsAlloc(allocator, metadata.canonical_targets.items);
        errdefer freeOwnedStringSlice(allocator, normalized_targets);

        candidate.* = .{
            .title_encoded = title_encoded,
            .payload_encoded = payload_encoded,
            .normalized_title = normalized_title,
            .normalized_targets = normalized_targets,
            .base_valid = !metadata.alias_only,
        };
        built += 1;
    }
    if (title_cursor != titles_end or payload_cursor != payloads_end) return error.InvalidDictionaryFile;
    return out;
}

fn collectTempAliasCandidatesAlloc(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    inspected: InspectedTempDictionary,
) ![]TempAliasCandidate {
    const alias_count: usize = inspected.header.alias_count;
    const out = try allocator.alloc(TempAliasCandidate, alias_count);
    errdefer allocator.free(out);

    var title_cursor: usize = @intCast(inspected.layout.alias_titles_offset);
    const titles_end: usize = @intCast(inspected.layout.alias_titles_offset + inspected.layout.alias_titles_len);
    var target_cursor: usize = @intCast(inspected.layout.alias_target_titles_offset);
    const targets_end: usize = @intCast(inspected.layout.alias_target_titles_offset + inspected.layout.alias_target_titles_len);

    var built: usize = 0;
    errdefer {
        while (built != 0) : (built -= 1) out[built - 1].deinit(allocator);
    }
    for (out) |*candidate| {
        const title_encoded = try readNullTerminatedSlice(mapped, &title_cursor, titles_end);
        const target_encoded = try readNullTerminatedSlice(mapped, &target_cursor, targets_end);
        const decoded_title = try compact.decodeAlloc(allocator, title_encoded);
        defer allocator.free(decoded_title);
        const decoded_target = try compact.decodeAlloc(allocator, target_encoded);
        defer allocator.free(decoded_target);

        candidate.* = .{
            .title_encoded = title_encoded,
            .normalized_title = try normalizeOwnedAlloc(allocator, decoded_title),
            .normalized_target = try normalizeOwnedAlloc(allocator, decoded_target),
        };
        built += 1;
    }
    if (title_cursor != titles_end or target_cursor != targets_end) return error.InvalidDictionaryFile;
    return out;
}

fn resolveReachableCandidatesAlloc(
    allocator: std.mem.Allocator,
    raw_candidates: []TempRawCandidate,
    alias_candidates: []TempAliasCandidate,
) !void {
    var valid_titles = ValidTitleSet.init(allocator);
    defer deinitValidTitleSet(allocator, &valid_titles);

    for (raw_candidates) |*candidate| {
        if (!candidate.base_valid) continue;
        candidate.valid = true;
        if (!valid_titles.contains(candidate.normalized_title)) {
            try valid_titles.put(try allocator.dupe(u8, candidate.normalized_title), {});
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (alias_candidates) |*candidate| {
            if (candidate.keep or !valid_titles.contains(candidate.normalized_target)) continue;
            candidate.keep = true;
            if (!valid_titles.contains(candidate.normalized_title)) {
                try valid_titles.put(try allocator.dupe(u8, candidate.normalized_title), {});
            }
            changed = true;
        }
        for (raw_candidates) |*candidate| {
            if (candidate.valid) continue;
            for (candidate.normalized_targets) |target| {
                if (!valid_titles.contains(target)) continue;
                candidate.valid = true;
                if (!valid_titles.contains(candidate.normalized_title)) {
                    try valid_titles.put(try allocator.dupe(u8, candidate.normalized_title), {});
                }
                changed = true;
                break;
            }
        }
    }
}

fn writeFinalDictionaryFromTempCandidates(
    io: std.Io,
    allocator: std.mem.Allocator,
    dest_path: []const u8,
    raw_candidates: []TempRawCandidate,
    alias_candidates: []TempAliasCandidate,
    progress: *BuildProgress,
) !FilterResult {
    const raw_index_map = try allocator.alloc(u32, raw_candidates.len);
    defer allocator.free(raw_index_map);
    @memset(raw_index_map, std.math.maxInt(u32));

    var valid_title_map = std.StringHashMap(u32).init(allocator);
    defer valid_title_map.deinit();
    var alias_title_map = std.StringHashMap(usize).init(allocator);
    defer alias_title_map.deinit();

    var kept_raw_count: usize = 0;
    var raw_titles_len: usize = 0;
    var raw_payloads_len: usize = 0;
    for (raw_candidates, 0..) |candidate, idx| {
        progress.filterAdvance(1, raw_candidates.len + alias_candidates.len, if (candidate.valid) 1 else 0);
        if (!candidate.valid) continue;
        raw_index_map[idx] = @intCast(kept_raw_count);
        raw_titles_len += candidate.title_encoded.len + 1;
        raw_payloads_len += candidate.payload_encoded.len + 1;
        if (!valid_title_map.contains(candidate.normalized_title)) {
            try valid_title_map.put(candidate.normalized_title, @intCast(kept_raw_count));
        }
        kept_raw_count += 1;
    }

    var kept_alias_count: usize = 0;
    var alias_titles_len: usize = 0;
    for (alias_candidates, 0..) |candidate, idx| {
        progress.filterAdvance(1, raw_candidates.len + alias_candidates.len, if (candidate.keep) 1 else 0);
        if (!candidate.keep) continue;
        alias_titles_len += candidate.title_encoded.len + 1;
        try alias_title_map.put(candidate.normalized_title, idx);
        kept_alias_count += 1;
    }

    const alias_targets_len = try std.math.mul(usize, kept_alias_count, @sizeOf(u32));
    const total_len = try std.math.add(usize, format.header_len, raw_titles_len + alias_titles_len + alias_targets_len + raw_payloads_len);

    var out_file = try MappedWritableFile.create(io, dest_path, @max(total_len, 1));
    defer out_file.deinit();
    const out = out_file.bytes();

    const header = format.Header.init(
        std.math.cast(u32, kept_raw_count) orelse return error.FileTooBig,
        std.math.cast(u32, kept_alias_count) orelse return error.FileTooBig,
    );
    @memcpy(out[0..format.header_len], std.mem.asBytes(&header));

    var cursor: usize = format.header_len;
    for (raw_candidates) |candidate| {
        if (!candidate.valid) continue;
        @memcpy(out[cursor .. cursor + candidate.title_encoded.len], candidate.title_encoded);
        cursor += candidate.title_encoded.len;
        out[cursor] = 0;
        cursor += 1;
    }

    var kept_alias_targets: std.ArrayList(u32) = .empty;
    defer kept_alias_targets.deinit(allocator);
    try kept_alias_targets.ensureTotalCapacityPrecise(allocator, kept_alias_count);
    for (alias_candidates) |candidate| {
        if (!candidate.keep) continue;
        const target_index = try resolveAliasTargetIndexAlloc(
            allocator,
            candidate.normalized_target,
            &valid_title_map,
            &alias_title_map,
            alias_candidates,
        ) orelse continue;
        @memcpy(out[cursor .. cursor + candidate.title_encoded.len], candidate.title_encoded);
        cursor += candidate.title_encoded.len;
        out[cursor] = 0;
        cursor += 1;
        kept_alias_targets.appendAssumeCapacity(target_index);
    }

    for (kept_alias_targets.items) |target_index| {
        const ptr: *[4]u8 = @ptrCast(out[cursor .. cursor + 4].ptr);
        std.mem.writeInt(u32, ptr, target_index, .little);
        cursor += 4;
    }

    for (raw_candidates) |candidate| {
        if (!candidate.valid) continue;
        @memcpy(out[cursor .. cursor + candidate.payload_encoded.len], candidate.payload_encoded);
        cursor += candidate.payload_encoded.len;
        out[cursor] = 0;
        cursor += 1;
    }

    std.debug.assert(cursor == total_len);
    try out_file.finish(total_len);

    return .{
        .entry_count = kept_raw_count,
        .redirect_count = kept_alias_count,
    };
}

fn normalizeOwnedAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (normalize.isIdentity(value)) return allocator.dupe(u8, value);
    return normalize.normalizeAlloc(allocator, value);
}

fn resolveAliasTargetIndexAlloc(
    allocator: std.mem.Allocator,
    normalized_target: []const u8,
    raw_title_map: *const std.StringHashMap(u32),
    alias_title_map: *const std.StringHashMap(usize),
    alias_candidates: []const TempAliasCandidate,
) !?u32 {
    var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer visited.deinit(allocator);
    return resolveAliasTargetIndex(
        allocator,
        normalized_target,
        raw_title_map,
        alias_title_map,
        alias_candidates,
        &visited,
    );
}

fn resolveAliasTargetIndex(
    allocator: std.mem.Allocator,
    normalized_target: []const u8,
    raw_title_map: *const std.StringHashMap(u32),
    alias_title_map: *const std.StringHashMap(usize),
    alias_candidates: []const TempAliasCandidate,
    visited: *std.AutoHashMapUnmanaged(usize, void),
) !?u32 {
    if (raw_title_map.get(normalized_target)) |raw_index| return raw_index;
    const alias_index = alias_title_map.get(normalized_target) orelse return null;
    if (visited.contains(alias_index)) return null;
    try visited.put(allocator, alias_index, {});
    defer _ = visited.remove(alias_index);
    return resolveAliasTargetIndex(
        allocator,
        alias_candidates[alias_index].normalized_target,
        raw_title_map,
        alias_title_map,
        alias_candidates,
        visited,
    );
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

fn validateTempDictionaryHeader(mapped: []const u8, size_u64: u64) !InspectedTempDictionary {
    const size = std.math.cast(usize, size_u64) orelse return error.FileTooBig;
    if (size != mapped.len) return error.InvalidDictionaryFile;
    return inspectTempDictionary(mapped) catch |err| switch (err) {
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
    raw_titles_path: []const u8,
    alias_titles_path: []const u8,
    alias_target_titles_path: []const u8,
    raw_payloads_path: []const u8,
    raw_titles_file: MappedWritableFile,
    alias_titles_file: MappedWritableFile,
    alias_target_titles_file: MappedWritableFile,
    raw_payloads_file: MappedWritableFile,
    flushed_raw_title_bytes: u64 = 0,
    flushed_alias_title_bytes: u64 = 0,
    flushed_alias_target_title_bytes: u64 = 0,
    flushed_raw_payload_bytes: u64 = 0,
    entry_count: usize = 0,
    raw_entry_count: usize = 0,
    redirect_count: usize = 0,
    raw_title_buffer: std.ArrayList(u8) = .empty,
    alias_title_buffer: std.ArrayList(u8) = .empty,
    alias_target_title_buffer: std.ArrayList(u8) = .empty,
    raw_payload_buffer: std.ArrayList(u8) = .empty,
    // Scratch buffer reused for compact-encoding titles and raw payload strings.
    encode_buf: std.ArrayList(u8) = .empty,

    fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !OutputWriter {
        const raw_titles_path = try std.fmt.allocPrint(allocator, "{s}.raw-titles", .{path});
        errdefer allocator.free(raw_titles_path);
        const alias_titles_path = try std.fmt.allocPrint(allocator, "{s}.alias-titles", .{path});
        errdefer allocator.free(alias_titles_path);
        const alias_target_titles_path = try std.fmt.allocPrint(allocator, "{s}.alias-targets", .{path});
        errdefer allocator.free(alias_target_titles_path);
        const raw_payloads_path = try std.fmt.allocPrint(allocator, "{s}.raw-payloads", .{path});
        errdefer allocator.free(raw_payloads_path);

        deleteFileIfExists(io, raw_titles_path) catch {};
        deleteFileIfExists(io, alias_titles_path) catch {};
        deleteFileIfExists(io, alias_target_titles_path) catch {};
        deleteFileIfExists(io, raw_payloads_path) catch {};

        var raw_titles_file = try MappedWritableFile.create(io, raw_titles_path, initial_capacity);
        errdefer raw_titles_file.deinit();
        var alias_titles_file = try MappedWritableFile.create(io, alias_titles_path, initial_capacity);
        errdefer alias_titles_file.deinit();
        var alias_target_titles_file = try MappedWritableFile.create(io, alias_target_titles_path, initial_capacity);
        errdefer alias_target_titles_file.deinit();
        var raw_payloads_file = try MappedWritableFile.create(io, raw_payloads_path, initial_capacity);
        errdefer raw_payloads_file.deinit();
        return .{
            .io = io,
            .allocator = allocator,
            .final_path = path,
            .raw_titles_path = raw_titles_path,
            .alias_titles_path = alias_titles_path,
            .alias_target_titles_path = alias_target_titles_path,
            .raw_payloads_path = raw_payloads_path,
            .raw_titles_file = raw_titles_file,
            .alias_titles_file = alias_titles_file,
            .alias_target_titles_file = alias_target_titles_file,
            .raw_payloads_file = raw_payloads_file,
        };
    }

    fn deinit(self: *OutputWriter, allocator: std.mem.Allocator) void {
        self.raw_title_buffer.deinit(allocator);
        self.alias_title_buffer.deinit(allocator);
        self.alias_target_title_buffer.deinit(allocator);
        self.raw_payload_buffer.deinit(allocator);
        self.encode_buf.deinit(allocator);
        self.raw_titles_file.deinit();
        self.alias_titles_file.deinit();
        self.alias_target_titles_file.deinit();
        self.raw_payloads_file.deinit();
        self.cleanupTempPath(allocator, &self.raw_titles_path);
        self.cleanupTempPath(allocator, &self.alias_titles_path);
        self.cleanupTempPath(allocator, &self.alias_target_titles_path);
        self.cleanupTempPath(allocator, &self.raw_payloads_path);
    }

    fn finish(self: *OutputWriter) !void {
        try self.flushRawTitleBuffer();
        try self.flushAliasTitleBuffer();
        try self.flushAliasTargetTitleBuffer();
        try self.flushRawPayloadBuffer();
        try self.raw_titles_file.finish(@intCast(self.flushed_raw_title_bytes));
        try self.alias_titles_file.finish(@intCast(self.flushed_alias_title_bytes));
        try self.alias_target_titles_file.finish(@intCast(self.flushed_alias_target_title_bytes));
        try self.raw_payloads_file.finish(@intCast(self.flushed_raw_payload_bytes));

        var raw_titles = try mmapReadOnlyPath(self.io, self.raw_titles_path);
        defer raw_titles.deinit();
        var alias_titles = try mmapReadOnlyPath(self.io, self.alias_titles_path);
        defer alias_titles.deinit();
        var alias_target_titles = try mmapReadOnlyPath(self.io, self.alias_target_titles_path);
        defer alias_target_titles.deinit();
        var raw_payloads = try mmapReadOnlyPath(self.io, self.raw_payloads_path);
        defer raw_payloads.deinit();

        const header = TempHeader.init(
            std.math.cast(u32, self.raw_entry_count) orelse return error.FileTooBig,
            std.math.cast(u32, self.redirect_count) orelse return error.FileTooBig,
            raw_titles.bytes().len,
            alias_titles.bytes().len,
            alias_target_titles.bytes().len,
            raw_payloads.bytes().len,
        );
        const final_len = try std.math.add(
            usize,
            temp_header_len,
            raw_titles.bytes().len + alias_titles.bytes().len + alias_target_titles.bytes().len + raw_payloads.bytes().len,
        );

        var out_file = try MappedWritableFile.create(self.io, self.final_path, @max(final_len, 1));
        defer out_file.deinit();

        const out = out_file.bytes();
        @memcpy(out[0..temp_header_len], std.mem.asBytes(&header));

        var cursor: usize = temp_header_len;
        if (raw_titles.bytes().len != 0) {
            @memcpy(out[cursor .. cursor + raw_titles.bytes().len], raw_titles.bytes());
            cursor += raw_titles.bytes().len;
        }
        if (alias_titles.bytes().len != 0) {
            @memcpy(out[cursor .. cursor + alias_titles.bytes().len], alias_titles.bytes());
            cursor += alias_titles.bytes().len;
        }
        if (alias_target_titles.bytes().len != 0) {
            @memcpy(out[cursor .. cursor + alias_target_titles.bytes().len], alias_target_titles.bytes());
            cursor += alias_target_titles.bytes().len;
        }
        if (raw_payloads.bytes().len != 0) {
            @memcpy(out[cursor .. cursor + raw_payloads.bytes().len], raw_payloads.bytes());
            cursor += raw_payloads.bytes().len;
        }
        try out_file.finish(final_len);
    }

    fn writeRawRecord(
        self: *OutputWriter,
        title: []const u8,
        stored_sections: []const u8,
    ) !void {
        try self.writeEncodedString(&self.raw_title_buffer, title, flushRawTitleBuffer);
        try self.writeEncodedString(&self.raw_payload_buffer, stored_sections, flushRawPayloadBuffer);
        self.raw_entry_count += 1;
        self.entry_count += 1;
    }

    fn writeRedirectRecord(
        self: *OutputWriter,
        title: []const u8,
        target: []const u8,
    ) !void {
        try self.writeEncodedString(&self.alias_title_buffer, title, flushAliasTitleBuffer);
        try self.writeEncodedString(&self.alias_target_title_buffer, target, flushAliasTargetTitleBuffer);
        self.redirect_count += 1;
        self.entry_count += 1;
    }

    fn writeEncodedString(
        self: *OutputWriter,
        buffer: *std.ArrayList(u8),
        value: []const u8,
        comptime flushFn: fn (*OutputWriter) anyerror!void,
    ) !void {
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidDictionaryFile;
        const encoded = try compact.encodeToList(&self.encode_buf, self.allocator, value);
        try buffer.appendSlice(self.allocator, encoded);
        try buffer.append(self.allocator, 0);
        if (buffer.items.len >= flush_threshold) {
            try flushFn(self);
        }
    }

    fn writeRawTitleBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.raw_title_buffer.appendSlice(self.allocator, bytes);
        if (self.raw_title_buffer.items.len >= flush_threshold) try self.flushRawTitleBuffer();
    }

    fn writeAliasTitleBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.alias_title_buffer.appendSlice(self.allocator, bytes);
        if (self.alias_title_buffer.items.len >= flush_threshold) try self.flushAliasTitleBuffer();
    }

    fn writeAliasTargetTitleBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.alias_target_title_buffer.appendSlice(self.allocator, bytes);
        if (self.alias_target_title_buffer.items.len >= flush_threshold) try self.flushAliasTargetTitleBuffer();
    }

    fn writeRawPayloadBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.raw_payload_buffer.appendSlice(self.allocator, bytes);
        if (self.raw_payload_buffer.items.len >= flush_threshold) try self.flushRawPayloadBuffer();
    }

    fn flushRawTitleBuffer(self: *OutputWriter) !void {
        try flushBufferIntoFile(
            self,
            &self.raw_title_buffer,
            &self.raw_titles_file,
            &self.flushed_raw_title_bytes,
        );
    }

    fn flushAliasTitleBuffer(self: *OutputWriter) !void {
        try flushBufferIntoFile(
            self,
            &self.alias_title_buffer,
            &self.alias_titles_file,
            &self.flushed_alias_title_bytes,
        );
    }

    fn flushAliasTargetTitleBuffer(self: *OutputWriter) !void {
        try flushBufferIntoFile(
            self,
            &self.alias_target_title_buffer,
            &self.alias_target_titles_file,
            &self.flushed_alias_target_title_bytes,
        );
    }

    fn flushRawPayloadBuffer(self: *OutputWriter) !void {
        try flushBufferIntoFile(
            self,
            &self.raw_payload_buffer,
            &self.raw_payloads_file,
            &self.flushed_raw_payload_bytes,
        );
    }

    fn flushBufferIntoFile(
        self: *OutputWriter,
        buffer: *std.ArrayList(u8),
        file: *MappedWritableFile,
        flushed_bytes: *u64,
    ) !void {
        _ = self;
        if (buffer.items.len == 0) return;
        const start: usize = @intCast(flushed_bytes.*);
        const end = start + buffer.items.len;
        try file.ensureCapacity(end);
        @memcpy(file.bytes()[start..end], buffer.items);
        flushed_bytes.* += buffer.items.len;
        buffer.items.len = 0;
    }

    fn cleanupTempPath(self: *OutputWriter, allocator: std.mem.Allocator, path: *[]const u8) void {
        if (path.*.len == 0) return;
        deleteFileIfExists(self.io, path.*) catch {};
        allocator.free(path.*);
        path.* = "";
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
    try writer.writeRawRecord(first_title, first_payload);

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

    try writer.writeRawRecord("color", "==English==");
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
    try std.testing.expectEqual(@as(usize, 2), stats.english_entries);
    try std.testing.expectEqual(@as(usize, 1), stats.redirect_aliases);

    var mapped_db = try mmapReadOnlyPath(std.testing.io, db_path);
    defer mapped_db.deinit();
    const mapped = mapped_db.bytes();
    const inspected = try format.inspectDictionary(mapped);
    try std.testing.expectEqual(@as(u32, 2), inspected.header.raw_count);
    try std.testing.expectEqual(@as(u32, 1), inspected.header.alias_count);

    var raw_cursor: usize = @intCast(inspected.layout.raw_titles_offset);
    const raw_titles_end: usize = @intCast(inspected.layout.raw_titles_offset + inspected.layout.raw_titles_len);
    const raw0 = try format.readNullTerminatedSlice(mapped, &raw_cursor, raw_titles_end);
    const raw1 = try format.readNullTerminatedSlice(mapped, &raw_cursor, raw_titles_end);
    const raw0_decoded = try compact.decodeAlloc(std.testing.allocator, raw0);
    defer std.testing.allocator.free(raw0_decoded);
    const raw1_decoded = try compact.decodeAlloc(std.testing.allocator, raw1);
    defer std.testing.allocator.free(raw1_decoded);
    try std.testing.expectEqualStrings("color", raw0_decoded);
    try std.testing.expectEqualStrings("colour", raw1_decoded);

    var alias_cursor: usize = @intCast(inspected.layout.alias_titles_offset);
    const alias_titles_end: usize = @intCast(inspected.layout.alias_titles_offset + inspected.layout.alias_titles_len);
    const alias0 = try format.readNullTerminatedSlice(mapped, &alias_cursor, alias_titles_end);
    const alias_title = try compact.decodeAlloc(std.testing.allocator, alias0);
    defer std.testing.allocator.free(alias_title);
    try std.testing.expectEqualStrings("colours", alias_title);
    try std.testing.expectEqual(@as(u32, 1), try format.readAliasTargetAt(mapped, inspected.layout, 0));
}
