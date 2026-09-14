const std = @import("std");

const ManifestRow = struct { title: []const u8 };

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};

fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

fn stringLiteral(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try out.append(a, '"');
    for (value) |byte| switch (byte) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => if (byte >= 0x20 and byte <= 0x7e)
            try out.append(a, byte)
        else
            try out.print(a, "\\x{x:0>2}", .{byte}),
    };
    try out.append(a, '"');
}

const SortContext = struct {
    names: []const []const u8,
    fn less(self: SortContext, a: u32, b: u32) bool {
        const order = std.mem.order(u8, self.names[a], self.names[b]);
        return order == .lt or (order == .eq and a < b);
    }
};

pub fn generate(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    const sorted_ids = try a.alloc(u32, names.len);
    defer a.free(sorted_ids);
    for (sorted_ids, 0..) |*id, i| id.* = std.math.cast(u32, i) orelse return error.TooManyModules;
    std.sort.pdq(u32, sorted_ids, SortContext{ .names = names }, SortContext.less);
    var unique_count: usize = 0;
    var read: usize = 0;
    while (read < sorted_ids.len) {
        var end = read + 1;
        while (end < sorted_ids.len and std.mem.eql(u8, names[sorted_ids[read]], names[sorted_ids[end]])) : (end += 1) {}
        sorted_ids[unique_count] = sorted_ids[end - 1];
        unique_count += 1;
        read = end;
    }
    const unique_ids = sorted_ids[0..unique_count];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "const registry_mod = @import(\"zig_module_registry\");\n\nconst names = [_][]const u8{\n");
    for (names) |name| {
        try out.appendSlice(a, "    ");
        try stringLiteral(&out, a, name);
        try out.appendSlice(a, ",\n");
    }
    try out.appendSlice(a, "};\n\nconst sorted_ids = [_]u32{\n");
    for (unique_ids) |id| try out.print(a, "    {d},\n", .{id});
    try out.appendSlice(a, "};\n\npub const registry = registry_mod.Registry{ .names = &names, .sorted_ids = &sorted_ids };\n");
    return out.toOwnedSlice(a);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) return error.Usage;
    const limit = if (args.len == 4) try std.fmt.parseInt(usize, args[3], 10) else std.math.maxInt(usize);
    var manifest = try mmapPath(args[1]);
    defer manifest.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.heap.smp_allocator);
    var pos: usize = 0;
    while (pos < manifest.bytes.len and names.items.len < limit) {
        const nl = std.mem.indexOfScalarPos(u8, manifest.bytes, pos, '\n') orelse manifest.bytes.len;
        const line = manifest.bytes[pos..nl];
        pos = @min(nl + 1, manifest.bytes.len);
        if (line.len == 0) continue;
        const row = try std.json.parseFromSliceLeaky(ManifestRow, arena.allocator(), line, .{ .ignore_unknown_fields = true });
        try names.append(std.heap.smp_allocator, row.title);
    }
    const source = try generate(std.heap.smp_allocator, names.items);
    defer std.heap.smp_allocator.free(source);
    var output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .truncate = true });
    defer output.close(init.io);
    try output.writePositionalAll(init.io, source, 0);
    std.debug.print("AOT_MODULE_REGISTRY modules={d} bytes={d}\n", .{ names.items.len, source.len });
}

test "module registry generator stores each title once and sorts numeric IDs" {
    const names = [_][]const u8{ "Module:Zulu", "Module:Alpha", "Module:Beta" };
    const source = try generate(std.testing.allocator, &names);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "Module:Alpha"));
    try std.testing.expect(std.mem.indexOf(u8, source, "const sorted_ids = [_]u32{\n    1,\n    2,\n    0,") != null);
}

test "module registry generator resolves duplicate titles to the last module ID" {
    const names = [_][]const u8{ "Module:A", "Module:A", "Module:B" };
    const source = try generate(std.testing.allocator, &names);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "const sorted_ids = [_]u32{\n    1,\n    2,") != null);
}
