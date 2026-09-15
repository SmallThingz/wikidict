//! Build-only auxiliary wiki page extraction for template/Lua expansion.
//! These sources are transient and are never part of the shipped blob schema.
const std = @import("std");
const zxml = @import("zxml");
const xml_decode = @import("xml_decode");

const types = zxml.Types(.{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = false,
});

const Capture = struct {
    names: [8][]const u8 = @splat(""),
    title: ?[]const u8 = null,
    source: ?[]const u8 = null,

    fn onNode(self: *@This(), n: types.StreamNode) bool {
        if (n.kind != .element) return true;
        if (n.depth < self.names.len) self.names[n.depth] = n.nameSlice();
        if (n.depth == 1 and std.mem.eql(u8, n.nameSlice(), "title")) self.title = n.leadingTextRaw();
        if (n.depth == 2 and std.mem.eql(u8, self.names[1], "revision") and std.mem.eql(u8, n.nameSlice(), "text")) self.source = n.leadingTextRaw();
        return true;
    }
};

const ManifestRow = struct { page_id: u64, title: []const u8 };
const Map = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn open(io: std.Io, path: []const u8) !Map {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        const size = std.math.cast(usize, (try f.stat(io)).size) orelse return error.FileTooBig;
        if (size == 0) return .{ .bytes = &.{} };
        return .{ .bytes = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0) };
    }

    fn close(self: Map) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
    }
};

fn relevant(page: []const u8) bool {
    return std.mem.indexOf(u8, page, "<ns>4</ns>") != null or
        std.mem.indexOf(u8, page, "<ns>8</ns>") != null or
        std.mem.indexOf(u8, page, "<ns>100</ns>") != null;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    const pages_dir = try std.fs.path.join(a, &.{ args[2], "pages" });
    try std.Io.Dir.cwd().deleteTree(init.io, pages_dir);
    try std.Io.Dir.cwd().createDir(init.io, pages_dir, .default_dir);

    const manifest_path = try std.fs.path.join(a, &.{ args[2], "pages-manifest.jsonl" });
    var manifest_file = try std.Io.Dir.cwd().createFile(init.io, manifest_path, .{ .truncate = true });
    defer manifest_file.close(init.io);
    var manifest_buffer: [64 * 1024]u8 = undefined;
    var manifest_writer = manifest_file.writer(init.io, &manifest_buffer);

    const dump = try Map.open(init.io, args[1]);
    defer dump.close();
    var parser = types.StreamParser.init(init.gpa);
    defer parser.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var pos: usize = 0;
    var count: u64 = 0;
    while (std.mem.indexOfPos(u8, dump.bytes, pos, "<page>")) |start| {
        const end = std.mem.indexOfPos(u8, dump.bytes, start, "</page>") orelse return error.TruncatedXml;
        pos = end + "</page>".len;
        const page = dump.bytes[start..pos];
        if (!relevant(page)) continue;

        var captured: Capture = .{};
        try parser.parse(page, &captured, Capture.onNode);
        const pa = arena.allocator();
        const title = try xml_decode.decodeSinglePassAlloc(pa, captured.title orelse continue);
        const source = try xml_decode.decodeSinglePassAlloc(pa, captured.source orelse "");
        count += 1;

        const source_path = try std.fmt.allocPrint(pa, "{s}/{d}.wiki", .{ pages_dir, count });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = source_path, .data = source });
        const row = try std.json.Stringify.valueAlloc(pa, ManifestRow{ .page_id = count, .title = title }, .{});
        try manifest_writer.interface.writeAll(row);
        try manifest_writer.interface.writeByte('\n');
        _ = arena.reset(.retain_capacity);
    }
    try manifest_writer.interface.flush();
    std.debug.print("BUNDLE_PAGES={d}\n", .{count});
}
