const std = @import("std");
const xml_decode = @import("xml_decode");
const index_format = @import("page_store_index.zig");

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

fn titleRaw(page: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, page, "<title>") orelse return null;
    const start = open + 7;
    const close = std.mem.indexOfPos(u8, page, start, "</title>") orelse return null;
    return page[start..close];
}

fn putU64(w: *std.Io.Writer, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try w.writeAll(&buf);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    var mapped = try mmapPath(init.io, args[1]);
    defer mapped.deinit();

    var entries: std.ArrayList(index_format.Entry) = .empty;
    defer entries.deinit(std.heap.smp_allocator);
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();

    var pos: usize = 0;
    var pages: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>") orelse break;
        const close = std.mem.indexOfPos(u8, mapped.bytes, start + 6, "</page>") orelse return error.MalformedXml;
        const end = close + 7;
        const page = mapped.bytes[start..end];
        pos = end;
        const raw = titleRaw(page) orelse return error.MissingTitle;
        _ = scratch.reset(.retain_capacity);
        const title = if (std.mem.indexOfScalar(u8, raw, '&') == null)
            raw
        else
            try xml_decode.decodeSinglePassAlloc(scratch.allocator(), raw);
        try entries.append(std.heap.smp_allocator, .{
            .hash = index_format.titleHash(title),
            .page_offset = @intCast(start),
        });
        pages += 1;
        if (pages % 1_000_000 == 0) std.debug.print("indexed pages={d} offset={d}\n", .{ pages, pos });
    }

    std.mem.sort(index_format.Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: index_format.Entry, b: index_format.Entry) bool {
            return a.hash < b.hash or (a.hash == b.hash and a.page_offset < b.page_offset);
        }
    }.lessThan);

    var output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .truncate = true });
    defer output.close(init.io);
    var out_buf: [1024 * 1024]u8 = undefined;
    var writer = output.writer(init.io, &out_buf);
    const w = &writer.interface;
    try w.writeAll(index_format.magic);
    try putU64(w, @intCast(entries.items.len));
    for (entries.items) |entry| {
        try putU64(w, entry.hash);
        try putU64(w, entry.page_offset);
    }
    try w.flush();
    std.debug.print("TOTAL pages={d} bytes={d}\n", .{ pages, index_format.header_len + pages * index_format.entry_len });
}
