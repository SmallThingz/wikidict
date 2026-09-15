//! Module redirects are semantic bundle-time dependencies, not compilable Lua source.
const std = @import("std");
const zxml = @import("zxml");
const xml_decode = @import("xml_decode");
const types = zxml.Types(.{ .mode = .strict, .validate_closing_tags = true, .drop_whitespace_text_nodes = false });
const Capture = struct {
    title: ?[]const u8 = null,
    target: ?[]const u8 = null,
    fn node(self: *Capture, n: types.StreamNode) bool {
        if (n.kind != .element or n.depth != 1) return true;
        if (std.mem.eql(u8, n.nameSlice(), "title")) self.title = n.leadingTextRaw();
        if (std.mem.eql(u8, n.nameSlice(), "redirect")) self.target = n.getAttributeValueRaw("title");
        return true;
    }
};
fn field(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    var f = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer f.close(init.io);
    const len = std.math.cast(usize, (try f.stat(init.io)).size) orelse return error.FileTooBig;
    if (len == 0) return error.EmptyDump;
    const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0);
    defer std.posix.munmap(bytes);
    const path = try std.fs.path.join(a, &.{ args[2], "module-redirects.tsv" });
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .exclusive = true });
    defer file.close(init.io);
    var buf: [65536]u8 = undefined;
    var writer = file.writer(init.io, &buf);
    var parser = types.StreamParser.init(init.gpa);
    defer parser.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var pos: usize = 0;
    var released: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "<page>")) |start| {
        const end = (std.mem.indexOfPos(u8, bytes, start, "</page>") orelse return error.TruncatedXml) + 7;
        const page = bytes[start..end];
        pos = end;
        if (std.mem.indexOf(u8, page, "<ns>828</ns>") != null and std.mem.indexOf(u8, page, "<redirect ") != null) {
            var capture: Capture = .{};
            try parser.parse(page, &capture, Capture.node);
            if (capture.title != null and capture.target != null) {
                const title = try xml_decode.decodeSinglePassAlloc(arena.allocator(), capture.title.?);
                const target = try xml_decode.decodeSinglePassAlloc(arena.allocator(), capture.target.?);
                try writer.interface.writeAll("M\t");
                try field(&writer.interface, title);
                try writer.interface.writeByte('\t');
                try field(&writer.interface, target);
                try writer.interface.writeByte('\n');
                count += 1;
            }
            _ = arena.reset(.retain_capacity);
        }
        if (pos - released > 16 * 1024 * 1024) {
            const boundary = pos - pos % std.heap.page_size_min;
            _ = std.os.linux.madvise(@ptrCast(@constCast(bytes.ptr + released)), boundary - released, std.os.linux.MADV.DONTNEED);
            released = boundary;
        }
    }
    try writer.interface.flush();
    std.debug.print("module_redirects={d}\n", .{count});
}
