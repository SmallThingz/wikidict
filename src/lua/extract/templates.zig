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
    ns_raw: ?[]const u8 = null,
    id_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,
    redirect_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();
        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) self.title_raw = node.leadingTextRaw() else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) self.ns_raw = node.leadingTextRaw() else if (node.depth == 1 and std.mem.eql(u8, name, "id")) self.id_raw = node.leadingTextRaw() else if (node.depth == 1 and std.mem.eql(u8, name, "redirect")) self.redirect_raw = node.getAttributeValueRaw("title") else if (node.depth == 2 and std.mem.eql(u8, name, "text") and std.mem.eql(u8, self.names_by_depth[1], "revision")) self.text_raw = node.leadingTextRaw();
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

fn writeField(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const input_path = args[1];
    const output_root = args[2];
    const templates_dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/templates", .{output_root});
    const manifest_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/template-manifest.tsv", .{output_root});
    try std.Io.Dir.cwd().createDirPath(init.io, templates_dir);

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
    var templates: usize = 0;
    while (std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>")) |start| {
        const end_start = std.mem.indexOfPos(u8, mapped.bytes, start, "</page>") orelse return error.TruncatedXml;
        const page_end = end_start + "</page>".len;
        const page = mapped.bytes[start..page_end];
        pos = page_end;
        pages += 1;
        if (std.mem.indexOf(u8, page, "<ns>10</ns>") == null) continue;

        var capture: Capture = .{};
        try parser.parse(page, &capture, Capture.onNode);
        const id_raw = capture.id_raw orelse continue;
        const id = std.fmt.parseInt(u64, std.mem.trim(u8, id_raw, " \t\r\n"), 10) catch continue;
        const title_raw = capture.title_raw orelse continue;
        const text_raw = capture.text_raw orelse "";
        const title = try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
        const text = try xml_decode.decodeSinglePassAlloc(arena.allocator(), text_raw);
        const path = try std.fmt.allocPrint(arena.allocator(), "{s}/{d}.wiki", .{ templates_dir, id });
        try writeAllFile(init.io, path, text);

        try mw.print("{d}\t", .{id});
        try writeField(mw, title);
        try mw.print("\t{d}\t", .{text.len});
        if (capture.redirect_raw) |raw| {
            const target = try xml_decode.decodeSinglePassAlloc(arena.allocator(), raw);
            try writeField(mw, target);
        }
        try mw.writeByte('\n');
        templates += 1;
        if (templates % 5000 == 0) std.debug.print("templates={d} pages={d}\n", .{ templates, pages });
        _ = arena.reset(.retain_capacity);
    }
    try mw.flush();
    std.debug.print("TOTAL pages={d} templates={d}\n", .{ pages, templates });
}
