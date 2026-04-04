const std = @import("std");
const zxml = @import("zxml");

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

const english_heading = "==English==\n";

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

pub fn build(io: std.Io, allocator: std.mem.Allocator, options: BuildOptions) !BuildStats {
    var input_file = try std.Io.Dir.cwd().openFile(io, options.input_path, .{});
    defer input_file.close(io);

    var output_file = try std.Io.Dir.cwd().createFile(io, options.output_path, .{ .truncate = true });
    defer output_file.close(io);

    var output = try OutputWriter.init(io, output_file);
    var stats: BuildStats = .{};

    var stream_parser = StreamParser.init(allocator);
    defer stream_parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    const stat = try input_file.stat(io);
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

        try processMappedInput(
            allocator,
            mapped[0..@as(usize, @intCast(stat.size))],
            options.limit_entries,
            &stream_parser,
            &page_arena,
            &output,
            &stats,
        );
    }

    try output.finish();
    stats.english_entries = output.entry_count;
    return stats;
}

fn processMappedInput(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    limit_entries: ?usize,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
    output: *OutputWriter,
    stats: *BuildStats,
) !void {
    var consumed: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        processPageFragment(page_allocator, stream_parser, mapped[start..page_end], output, stats) catch |err| {
            std.log.warn("skipping page after parse error: {}", .{err});
        };
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);

        if (limit_entries) |limit| {
            if (output.entry_count >= limit) return;
        }

        if (stats.pages_seen != 0 and stats.pages_seen % 10_000 == 0) {
            std.log.info(
                "pages={d} ns0={d} entries={d}",
                .{ stats.pages_seen, stats.namespace_zero_pages, output.entry_count },
            );
        }
    }

    _ = allocator;
}

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

    const title = try xml_decode.decodeAlloc(allocator, capture.title_raw orelse return);

    if (capture.text_raw) |text_raw| {
        if (std.mem.indexOf(u8, text_raw, "==English==") != null) {
            const text = try xml_decode.decodeAlloc(allocator, text_raw);
            if (wikitext.extractEnglishSection(text)) |english_section| {
                try output.writeRecord(
                    allocator,
                    title,
                    format.record_flag_has_raw,
                    english_section,
                );
                return;
            }
        }
    }

    if (capture.redirect_title_raw) |raw| {
        const target = try xml_decode.decodeAlloc(allocator, raw);
        try output.writeRecord(
            allocator,
            title,
            0,
            target,
        );
        stats.redirect_aliases += 1;
    }
}

const OutputWriter = struct {
    io: std.Io,
    file: std.Io.File,
    cursor: u64 = @sizeOf(format.Header),
    entry_count: usize = 0,
    raw_entry_count: usize = 0,
    redirect_count: usize = 0,

    fn init(io: std.Io, file: std.Io.File) !OutputWriter {
        const placeholder = format.Header.init(0, 0, 0, @sizeOf(format.Header), 0);
        try file.writePositionalAll(io, std.mem.asBytes(&placeholder), 0);
        return .{
            .io = io,
            .file = file,
        };
    }

    fn finish(self: *OutputWriter) !void {
        const header = format.Header.init(
            @intCast(self.entry_count),
            @intCast(self.raw_entry_count),
            @intCast(self.redirect_count),
            @sizeOf(format.Header),
            self.cursor - @sizeOf(format.Header),
        );
        try self.file.writePositionalAll(self.io, std.mem.asBytes(&header), 0);
    }

    fn writeRecord(
        self: *OutputWriter,
        allocator: std.mem.Allocator,
        title: []const u8,
        flags: u8,
        payload: []const u8,
    ) !void {
        try self.writeByte(flags);
        const encoded_title = try compact.encodeAlloc(allocator, title);
        defer allocator.free(encoded_title);
        try self.writeSlice(encoded_title);

        if ((flags & format.record_flag_has_raw) != 0) {
            const raw_payload = if (std.mem.startsWith(u8, payload, english_heading))
                payload[english_heading.len..]
            else
                payload;
            const encoded = try compact.encodeAlloc(allocator, raw_payload);
            defer allocator.free(encoded);
            try self.writeSlice(encoded);
            self.raw_entry_count += 1;
        } else {
            const encoded_target = try compact.encodeAlloc(allocator, payload);
            defer allocator.free(encoded_target);
            try self.writeSlice(encoded_target);
            self.redirect_count += 1;
        }

        self.entry_count += 1;
    }

    fn writeSlice(self: *OutputWriter, value: []const u8) !void {
        var len_buf: [10]u8 = undefined;
        try self.writeBytes(format.encodeVarUInt(&len_buf, value.len));
        try self.writeBytes(value);
    }

    fn writeByte(self: *OutputWriter, value: u8) !void {
        var byte = [_]u8{value};
        try self.writeBytes(&byte);
    }

    fn writeBytes(self: *OutputWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.file.writePositionalAll(self.io, bytes, self.cursor);
        self.cursor += bytes.len;
    }
};
