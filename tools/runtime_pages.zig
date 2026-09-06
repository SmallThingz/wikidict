//! Auxiliary wiki pages are real runtime dependencies (e.g. Appendix:Glossary).
//! Bounded spool: no duplicate main-language dictionary and no persisted index.
const std = @import("std");
const zxml = @import("zxml");
const enc = @import("encoder");
const format = enc.blob_format;
const types = zxml.Types(.{ .mode = .strict, .validate_closing_tags = true, .drop_whitespace_text_nodes = false });
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
const Map = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn open(io: std.Io, path: []const u8) !Map {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        const size = std.math.cast(usize, (try f.stat(io)).size) orelse return error.FileTooBig;
        return .{ .bytes = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0) };
    }
    fn close(self: Map) void {
        std.posix.munmap(self.bytes);
    }
};
fn record(w: *std.Io.Writer, title: []const u8, body: []const u8) !void {
    try w.writeAll(title);
    try w.writeByte(0);
    var length: [format.max_varuint_len]u8 = undefined;
    try w.writeAll(format.encodePayloadLength(body.len, &length));
    try w.writeAll(body);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    const spool = try std.fmt.allocPrint(a, "{s}/.pages-{d}.spool", .{ args[2], std.os.linux.getpid() });
    var file = try std.Io.Dir.cwd().createFile(init.io, spool, .{ .exclusive = true });
    defer file.close(init.io);
    defer std.Io.Dir.cwd().deleteFile(init.io, spool) catch {};
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&format.encodeUnlinkedHeader(.pages));
    const dump = try Map.open(init.io, args[1]);
    defer dump.close();
    var parser = types.StreamParser.init(init.gpa);
    defer parser.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var pos: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, dump.bytes, pos, "<page>")) |start| {
        const end = std.mem.indexOfPos(u8, dump.bytes, start, "</page>") orelse return error.TruncatedXml;
        pos = end + 7;
        const page = dump.bytes[start..pos];
        if (std.mem.indexOf(u8, page, "<ns>4</ns>") == null and std.mem.indexOf(u8, page, "<ns>8</ns>") == null and std.mem.indexOf(u8, page, "<ns>100</ns>") == null) continue;
        var captured: Capture = .{};
        try parser.parse(page, &captured, Capture.onNode);
        const pa = arena.allocator();
        const title = try enc.xml_decode.decodeSinglePassAlloc(pa, captured.title orelse continue);
        const source = try enc.xml_decode.decodeSinglePassAlloc(pa, captured.source orelse "");
        try record(w, title, source);
        count += 1;
        _ = arena.reset(.retain_capacity);
    }
    try w.flush();
    const mapped = try Map.open(init.io, spool);
    defer mapped.close();
    const view = try format.openTrusted(mapped.bytes);
    var refs: std.ArrayList(format.RecordInput) = .empty;
    defer refs.deinit(init.gpa);
    var it = view.iterator();
    while (try it.next()) |r| try refs.append(init.gpa, .{ .title = r.title, .payload = r.payload });
    std.mem.sort(format.RecordInput, refs.items, {}, struct {
        fn less(_: void, l: format.RecordInput, r: format.RecordInput) bool {
            return std.mem.order(u8, l.title, r.title) == .lt;
        }
    }.less);
    const output = try std.fs.path.join(a, &.{ args[2], "pages.source.wikblb" });
    var out = try std.Io.Dir.cwd().createFile(init.io, output, .{ .exclusive = true });
    defer out.close(init.io);
    var out_buffer: [65536]u8 = undefined;
    var ow = out.writer(init.io, &out_buffer);
    try ow.interface.writeAll(&format.encodeUnlinkedHeader(.pages));
    for (refs.items, 0..) |r, i| {
        if (i != 0 and std.mem.eql(u8, r.title, refs.items[i - 1].title)) return error.DuplicatePage;
        try record(&ow.interface, r.title, r.payload);
    }
    try ow.interface.flush();
    std.debug.print("RUNTIME_PAGES={d}\n", .{count});
}
