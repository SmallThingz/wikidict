const std = @import("std");
const zxml = @import("zxml");
const xml_decode = @import("xml_decode");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = false,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

const Capture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    page_id_raw: ?[]const u8 = null,
    revision_id_raw: ?[]const u8 = null,
    model_raw: ?[]const u8 = null,
    format_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();
        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) self.title_raw = node.leadingTextRaw() else if (node.depth == 1 and std.mem.eql(u8, name, "id")) self.page_id_raw = node.leadingTextRaw() else if (node.depth == 2 and std.mem.eql(u8, self.names_by_depth[1], "revision")) {
            if (std.mem.eql(u8, name, "id")) self.revision_id_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "model")) self.model_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "format")) self.format_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "text")) self.text_raw = node.leadingTextRaw();
        }
        return true;
    }
};

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};

fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

fn writeAllFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => {
            try w.writeAll("\\u00");
            try w.writeByte(hex[c >> 4]);
            try w.writeByte(hex[c & 0x0f]);
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeManifestRow(
    w: *std.Io.Writer,
    page_id: u64,
    revision_id: ?u64,
    title: []const u8,
    model: []const u8,
    format: ?[]const u8,
    source: []const u8,
) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    try w.print("{{\"page_id\":{d},\"revision_id\":", .{page_id});
    if (revision_id) |id| try w.print("{d}", .{id}) else try w.writeAll("null");
    try w.writeAll(",\"title\":");
    try writeJsonString(w, title);
    try w.writeAll(",\"model\":");
    try writeJsonString(w, model);
    try w.writeAll(",\"format\":");
    if (format) |value| try writeJsonString(w, value) else try w.writeAll("null");
    try w.print(",\"bytes\":{d},\"sha256\":\"{s}\",\"path\":\"modules/{d}.lua\"}}\n", .{
        source.len,
        &digest_hex,
        page_id,
    });
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const input_path = args[1];
    const output_root = args[2];
    const modules_dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/modules", .{output_root});
    const manifest_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/manifest.jsonl", .{output_root});
    try std.Io.Dir.cwd().createDirPath(init.io, modules_dir);

    var manifest_file = try std.Io.Dir.cwd().createFile(init.io, manifest_path, .{ .truncate = true });
    defer manifest_file.close(init.io);
    var manifest_buf: [256 * 1024]u8 = undefined;
    var manifest_writer = manifest_file.writer(init.io, &manifest_buf);
    const mw = &manifest_writer.interface;

    var mapped = try mmapPath(input_path);
    defer mapped.deinit();
    var parser = StreamParser.init(std.heap.smp_allocator);
    defer parser.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var pos: usize = 0;
    var pages: usize = 0;
    var modules: usize = 0;
    var source_bytes: u64 = 0;
    while (std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>")) |start| {
        const end_start = std.mem.indexOfPos(u8, mapped.bytes, start, "</page>") orelse return error.TruncatedXml;
        const page_end = end_start + "</page>".len;
        const page = mapped.bytes[start..page_end];
        pos = page_end;
        pages += 1;
        if (std.mem.indexOf(u8, page, "<ns>828</ns>") == null) continue;

        var capture: Capture = .{};
        try parser.parse(page, &capture, Capture.onNode);
        const page_id_raw = capture.page_id_raw orelse continue;
        const page_id = std.fmt.parseInt(u64, std.mem.trim(u8, page_id_raw, " \t\r\n"), 10) catch continue;
        const model_raw = capture.model_raw orelse continue;
        const model = try xml_decode.decodeSinglePassAlloc(arena.allocator(), model_raw);
        if (!std.mem.eql(u8, model, "Scribunto")) {
            _ = arena.reset(.retain_capacity);
            continue;
        }
        const title_raw = capture.title_raw orelse continue;
        const text_raw = capture.text_raw orelse continue;
        const title = try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
        const source = try xml_decode.decodeSinglePassAlloc(arena.allocator(), text_raw);
        const revision_id = if (capture.revision_id_raw) |raw|
            std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null
        else
            null;
        const format = if (capture.format_raw) |raw|
            try xml_decode.decodeSinglePassAlloc(arena.allocator(), raw)
        else
            null;
        const module_path = try std.fmt.allocPrint(arena.allocator(), "{s}/{d}.lua", .{ modules_dir, page_id });
        try writeAllFile(init.io, module_path, source);
        try writeManifestRow(mw, page_id, revision_id, title, model, format, source);

        modules += 1;
        source_bytes += source.len;
        if (modules % 1000 == 0) {
            try mw.flush();
            std.debug.print("modules={d} pages={d} source_bytes={d}\n", .{ modules, pages, source_bytes });
        }
        _ = arena.reset(.retain_capacity);
    }
    try mw.flush();
    std.debug.print("TOTAL pages={d} modules={d} source_bytes={d}\n", .{ pages, modules, source_bytes });
}
