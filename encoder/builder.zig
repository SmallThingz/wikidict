const std = @import("std");
const builtin = @import("builtin");
const zxml = @import("zxml");
const normalize = @import("normalize");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");
const wikitext = @import("wikitext.zig");
const xml_decode = @import("xml_decode.zig");

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
};

pub const BuildStats = struct {
    pages_seen: usize = 0,
    namespace_zero_pages: usize = 0,
    english_entries: usize = 0,
    redirect_aliases: usize = 0,
};

const BuildProgress = struct {
    const Phase = enum {
        scanning,
        writing,
        done,
    };

    total_input_bytes: usize,
    phase: Phase = .scanning,
    last_percent: u8 = 255,

    fn init(total_input_bytes: usize) BuildProgress {
        return .{ .total_input_bytes = total_input_bytes };
    }

    fn scan(self: *BuildProgress, consumed_input_bytes: usize, pages: usize, entries: usize) void {
        const percent = if (self.total_input_bytes == 0)
            98
        else
            @as(u8, @intCast(@min(98, (consumed_input_bytes * 98) / self.total_input_bytes)));
        self.render(.scanning, percent, pages, entries);
    }

    fn setWriting(self: *BuildProgress, entries: usize, redirects: usize) void {
        self.render(.writing, 99, entries, redirects);
    }

    fn finish(self: *BuildProgress, pages: usize, entries: usize) void {
        self.render(.done, 100, pages, entries);
        if (!builtin.is_test) std.debug.print("\n", .{});
    }

    fn render(self: *BuildProgress, phase: Phase, percent: u8, primary: usize, secondary: usize) void {
        if (builtin.is_test) return;
        if (self.phase == phase and self.last_percent == percent) return;

        self.phase = phase;
        self.last_percent = percent;

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        switch (phase) {
            .scanning => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (pages={d} entries={d})",
                .{ &bar, percent, phaseLabel(phase), primary, secondary },
            ),
            .writing => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (entries={d} redirects={d})",
                .{ &bar, percent, phaseLabel(phase), primary, secondary },
            ),
            .done => std.debug.print(
                "\rbuild dict [{s}] {d:>3}% {s} (pages={d} entries={d})",
                .{ &bar, percent, phaseLabel(phase), primary, secondary },
            ),
        }
    }

    fn phaseLabel(phase: Phase) []const u8 {
        return switch (phase) {
            .scanning => "scan xml",
            .writing => "write output",
            .done => "ready",
        };
    }
};

pub fn build(io: std.Io, allocator: std.mem.Allocator, options: BuildOptions) !BuildStats {
    var input_file = try std.Io.Dir.cwd().openFile(io, options.input_path, .{});
    defer input_file.close(io);

    const temp_output_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{options.output_path});
    defer allocator.free(temp_output_path);
    std.Io.Dir.cwd().deleteFile(io, temp_output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, temp_output_path) catch {};

    var stats: BuildStats = .{};

    var stream_parser = StreamParser.init(allocator);
    defer stream_parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    var valid_titles: ?ValidTitleSet = null;
    defer if (valid_titles) |*set| deinitValidTitleSet(allocator, set);

    const stat = try input_file.stat(io);
    var progress = BuildProgress.init(@intCast(stat.size));
    {
        var output_file = try std.Io.Dir.cwd().createFile(io, temp_output_path, .{ .truncate = true });
        defer output_file.close(io);

        var output = try OutputWriter.init(io, allocator, output_file);
        defer output.deinit(allocator);

        if (stat.size != 0) {
            const map_len = std.mem.alignForward(usize, @as(usize, @intCast(stat.size)), std.heap.page_size_min);
            const mapped = try std.posix.mmap(
                null,
                map_len,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                input_file.handle,
                0,
            );
            defer std.posix.munmap(mapped);

            if (options.limit_entries == null) {
                valid_titles = try collectValidAliasTitleSet(
                    allocator,
                    mapped[0..@as(usize, @intCast(stat.size))],
                    &stream_parser,
                    &page_arena,
                );
            }

            try processMappedInput(
                mapped[0..@as(usize, @intCast(stat.size))],
                options.limit_entries,
                &stream_parser,
                &page_arena,
                &output,
                &stats,
                &progress,
                if (valid_titles) |*set| set else null,
            );
        }

        progress.setWriting(output.entry_count, output.redirect_count);
        try output.finish();
        stats.english_entries = output.entry_count;
    }

    try std.Io.Dir.cwd().rename(temp_output_path, std.Io.Dir.cwd(), options.output_path, io);
    progress.finish(stats.pages_seen, stats.english_entries);
    return stats;
}

fn processMappedInput(
    mapped: []const u8,
    limit_entries: ?usize,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
    output: *OutputWriter,
    stats: *BuildStats,
    progress: *BuildProgress,
    valid_titles: ?*const ValidTitleSet,
) !void {
    var consumed: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        try processPageFragment(page_allocator, stream_parser, mapped[start..page_end], output, stats, valid_titles);
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);
        progress.scan(consumed, stats.pages_seen, output.entry_count);

        if (limit_entries) |limit| {
            if (output.entry_count >= limit) return;
        }
    }

    progress.scan(mapped.len, stats.pages_seen, output.entry_count);
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
    valid_titles: ?*const ValidTitleSet,
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
        const text = try xml_decode.decodeAlloc(allocator, text_raw);
        if (try wikitext.extractConfiguredLanguageSectionsAlloc(allocator, text, .defaultCompact())) |stored_sections| {
            defer allocator.free(stored_sections);
            const title = try xml_decode.decodeAlloc(allocator, title_raw);
            var metadata: wikitext.EntryMetadata = .{};
            defer metadata.deinit(allocator);
            if (wikitext.extractEnglishSection(stored_sections)) |english_section| {
                metadata = try wikitext.extractEntryMetadata(allocator, title, english_section);
                if (valid_titles) |set| {
                    const was_alias_only = metadata.alias_only;
                    try filterMetadataCanonicalTargets(allocator, &metadata, set);
                    if (was_alias_only and metadata.canonical_targets.items.len == 0) return;
                }
            }
            const raw_payload = try buildRawRecordPayloadAlloc(allocator, stored_sections, metadata);
            defer allocator.free(raw_payload);
            try output.writeRawRecord(title, raw_payload);
            return;
        }
    }

    if (capture.redirect_title_raw) |raw| {
        const title = try xml_decode.decodeAlloc(allocator, title_raw);
        const target = try xml_decode.decodeAlloc(allocator, raw);
        if (valid_titles) |set| {
            const normalized_target = try normalize.normalizeAlloc(allocator, target);
            defer allocator.free(normalized_target);
            if (!set.contains(normalized_target)) return;
        }
        try output.writeRedirectRecord(
            title,
            target,
        );
        stats.redirect_aliases += 1;
    }
}

fn collectValidAliasTitleSet(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
) !ValidTitleSet {
    var candidates: std.ArrayList(AliasCandidate) = .empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var consumed: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        try collectPageAliasCandidate(page_allocator, allocator, stream_parser, mapped[start..page_end], &candidates);
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);
    }

    var valid_titles = ValidTitleSet.init(allocator);
    errdefer deinitValidTitleSet(allocator, &valid_titles);

    for (candidates.items) |*candidate| {
        if (!candidate.base_valid) continue;
        candidate.valid = true;
        if (!valid_titles.contains(candidate.normalized_title)) {
            try valid_titles.put(try allocator.dupe(u8, candidate.normalized_title), {});
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (candidates.items) |*candidate| {
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

    return valid_titles;
}

fn collectPageAliasCandidate(
    page_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    parser: *StreamParser,
    page_fragment: []const u8,
    candidates: *std.ArrayList(AliasCandidate),
) !void {
    var capture: PageCapture = .{};
    try parser.parse(page_fragment, &capture, PageCapture.onNode);

    const ns_raw = capture.ns_raw orelse return;
    const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch return;
    if (ns != 0) return;

    const title_raw = capture.title_raw orelse return;

    if (capture.text_raw) |text_raw| {
        const text = try xml_decode.decodeAlloc(page_allocator, text_raw);
        if (try wikitext.extractConfiguredLanguageSectionsAlloc(page_allocator, text, .defaultCompact())) |stored_sections| {
            const title = try xml_decode.decodeAlloc(page_allocator, title_raw);
            var normalized_targets: []const []const u8 = try allocator.alloc([]const u8, 0);
            errdefer allocator.free(normalized_targets);
            var base_valid = true;
            if (wikitext.extractEnglishSection(stored_sections)) |english_section| {
                var metadata = try wikitext.extractEntryMetadata(page_allocator, title, english_section);
                defer metadata.deinit(page_allocator);
                allocator.free(normalized_targets);
                normalized_targets = try normalizeTargetsAlloc(allocator, metadata.canonical_targets.items);
                errdefer freeOwnedStringSlice(allocator, normalized_targets);
                base_valid = !metadata.alias_only;
            }
            const normalized_title = try normalize.normalizeAlloc(allocator, title);
            errdefer allocator.free(normalized_title);
            try candidates.append(allocator, .{
                .normalized_title = normalized_title,
                .normalized_targets = normalized_targets,
                .base_valid = base_valid,
            });
            return;
        }
    }

    if (capture.redirect_title_raw) |raw| {
        const title = try xml_decode.decodeAlloc(page_allocator, title_raw);
        const target = try xml_decode.decodeAlloc(page_allocator, raw);
        const normalized_title = try normalize.normalizeAlloc(allocator, title);
        errdefer allocator.free(normalized_title);
        const normalized_target = try normalize.normalizeAlloc(allocator, target);
        errdefer allocator.free(normalized_target);
        const targets = try allocator.alloc([]const u8, 1);
        targets[0] = normalized_target;
        errdefer allocator.free(targets);
        try candidates.append(allocator, .{
            .normalized_title = normalized_title,
            .normalized_targets = targets,
            .base_valid = false,
        });
    }
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

fn filterMetadataCanonicalTargets(
    allocator: std.mem.Allocator,
    metadata: *wikitext.EntryMetadata,
    valid_titles: *const ValidTitleSet,
) !void {
    var kept: usize = 0;
    for (metadata.canonical_targets.items) |target| {
        const normalized = try normalize.normalizeAlloc(allocator, target);
        defer allocator.free(normalized);
        if (!valid_titles.contains(normalized)) {
            allocator.free(target);
            continue;
        }
        metadata.canonical_targets.items[kept] = target;
        kept += 1;
    }
    metadata.canonical_targets.items.len = kept;

    if (kept == 0) {
        metadata.alias_only = false;
        if (metadata.alias_hint_label.len != 0) {
            allocator.free(metadata.alias_hint_label);
            metadata.alias_hint_label = "";
        }
    }
}

fn buildRawRecordPayloadAlloc(
    allocator: std.mem.Allocator,
    stored_sections: []const u8,
    metadata: wikitext.EntryMetadata,
) ![]u8 {
    const encoded_raw = try compact.encodeAlloc(allocator, stored_sections);
    defer allocator.free(encoded_raw);

    return format.encodeRawRecordPayloadAlloc(
        allocator,
        metadata.alt_forms.items,
        metadata.canonical_targets.items,
        encoded_raw,
    );
}

const OutputWriter = struct {
    const flush_threshold = 1 << 20;

    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    // Bytes already persisted to disk, including the placeholder header.
    flushed_bytes: u64 = @sizeOf(format.Header),
    entry_count: usize = 0,
    raw_entry_count: usize = 0,
    redirect_count: usize = 0,
    buffer: std.ArrayList(u8) = .empty,
    // Scratch buffer reused for compact-encoding titles before length-prefixing them.
    title_buf: std.ArrayList(u8) = .empty,

    fn init(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !OutputWriter {
        const placeholder = format.Header.init(0, 0, 0, @sizeOf(format.Header), 0);
        try file.writePositionalAll(io, std.mem.asBytes(&placeholder), 0);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
        };
    }

    fn deinit(self: *OutputWriter, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.title_buf.deinit(allocator);
    }

    fn finish(self: *OutputWriter) !void {
        try self.flushBuffer();
        const header = format.Header.init(
            @intCast(self.entry_count),
            @intCast(self.raw_entry_count),
            @intCast(self.redirect_count),
            @sizeOf(format.Header),
            self.flushed_bytes - @sizeOf(format.Header),
        );
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&header), 0);
    }

    fn writeRawRecord(
        self: *OutputWriter,
        title: []const u8,
        payload: []const u8,
    ) !void {
        try self.writeBytes(&.{format.record_flag_has_raw});
        const encoded_title = try compact.encodeToList(&self.title_buf, self.allocator, title);
        try self.writeSlice(encoded_title);
        try self.writeSlice(payload);
        self.raw_entry_count += 1;
        self.entry_count += 1;
    }

    fn writeRedirectRecord(
        self: *OutputWriter,
        title: []const u8,
        target: []const u8,
    ) !void {
        try self.writeBytes(&.{0});
        const encoded_title = try compact.encodeToList(&self.title_buf, self.allocator, title);
        try self.writeSlice(encoded_title);
        const encoded_payload = try format.encodeAliasRecordPayloadAlloc(self.allocator, target);
        defer self.allocator.free(encoded_payload);
        try self.writeSlice(encoded_payload);
        self.redirect_count += 1;
        self.entry_count += 1;
    }

    fn writeSlice(self: *OutputWriter, value: []const u8) !void {
        var len_buf: [10]u8 = undefined;
        try self.writeBytes(format.encodeVarUInt(&len_buf, value.len));
        try self.writeBytes(value);
    }

    fn writeBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.buffer.appendSlice(self.allocator, bytes);
        if (self.buffer.items.len >= flush_threshold) try self.flushBuffer();
    }

    fn flushBuffer(self: *OutputWriter) !void {
        if (self.buffer.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buffer.items, self.flushed_bytes);
        self.flushed_bytes += self.buffer.items.len;
        self.buffer.items.len = 0;
    }
};

test "output writer buffers survive page arena resets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "dict.bin.tmp", .{ .truncate = true });
    defer file.close(std.testing.io);

    var writer = try OutputWriter.init(std.testing.io, std.testing.allocator, file);
    defer writer.deinit(std.testing.allocator);

    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page_arena.deinit();

    const first_alloc = page_arena.allocator();
    const first_title = try first_alloc.dupe(u8, "color");
    const first_payload = try first_alloc.dupe(u8, "==English==\n===Noun===\n# [[light]]\n");
    var metadata = try wikitext.extractEntryMetadata(std.testing.allocator, first_title, first_payload);
    defer metadata.deinit(std.testing.allocator);
    const first_record_payload = try buildRawRecordPayloadAlloc(std.testing.allocator, first_payload, metadata);
    defer std.testing.allocator.free(first_record_payload);
    try writer.writeRawRecord(first_title, first_record_payload);

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

    var file = try tmp.dir.createFile(std.testing.io, "dict.bin.tmp", .{ .truncate = true });
    defer file.close(std.testing.io);

    var writer = try OutputWriter.init(std.testing.io, std.testing.allocator, file);
    defer writer.deinit(std.testing.allocator);

    var metadata = try wikitext.extractEntryMetadata(std.testing.allocator, "color", "==English==");
    defer metadata.deinit(std.testing.allocator);
    const payload = try buildRawRecordPayloadAlloc(std.testing.allocator, "==English==", metadata);
    defer std.testing.allocator.free(payload);
    try writer.writeRawRecord("color", payload);
    try writer.finish();

    try std.testing.expectEqual(@as(usize, 1), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 1), writer.raw_entry_count);
}
