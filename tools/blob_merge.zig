const std = @import("std");
const encoder = @import("encoder");
const format = encoder.blob_format;
const catalog = encoder.blob_catalog;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (len == 0) return .{ .bytes = &.{} };
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

const MergeSource = struct {
    mapped: Mapped,
    iterator: format.RecordIterator,
    current: ?format.RecordView,
};

fn sourceLess(sources: []const MergeSource, lhs: usize, rhs: usize) bool {
    const a = sources[lhs].current.?.title;
    const b = sources[rhs].current.?.title;
    return switch (std.mem.order(u8, a, b)) {
        .lt => true,
        .gt => false,
        .eq => lhs < rhs,
    };
}

fn heapPush(heap: *std.ArrayList(usize), a: std.mem.Allocator, sources: []const MergeSource, value: usize) !void {
    try heap.append(a, value);
    var child = heap.items.len - 1;
    while (child != 0) {
        const parent = (child - 1) / 2;
        if (!sourceLess(sources, heap.items[child], heap.items[parent])) break;
        std.mem.swap(usize, &heap.items[child], &heap.items[parent]);
        child = parent;
    }
}

fn heapPop(heap: *std.ArrayList(usize), sources: []const MergeSource) usize {
    const result = heap.items[0];
    const last = heap.pop().?;
    if (heap.items.len == 0) return result;
    heap.items[0] = last;
    var parent: usize = 0;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= heap.items.len) break;
        const right = left + 1;
        var child = left;
        if (right < heap.items.len and sourceLess(sources, heap.items[right], heap.items[left])) child = right;
        if (!sourceLess(sources, heap.items[child], heap.items[parent])) break;
        std.mem.swap(usize, &heap.items[child], &heap.items[parent]);
        parent = child;
    }
    return result;
}

fn writeRecord(out: *std.Io.Writer, record: format.RecordView) !void {
    try format.validateRecordInput(.{ .title = record.title, .payload = record.payload });
    try out.writeAll(record.title);
    try out.writeByte(0);
    var encoded_len: [format.max_varuint_len]u8 = undefined;
    try out.writeAll(format.encodePayloadLength(record.payload.len, &encoded_len));
    try out.writeAll(record.payload);
}

fn mergeOne(
    io: std.Io,
    a: std.mem.Allocator,
    output_path: []const u8,
    kind: format.BlobKind,
    input_paths: []const []const u8,
) !usize {
    var sources: std.ArrayList(MergeSource) = .empty;
    defer {
        for (sources.items) |*source| source.mapped.deinit();
        sources.deinit(a);
    }
    var metadata: ?[]const u8 = null;
    for (input_paths) |path| {
        var mapped = mmapPath(io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        errdefer mapped.deinit();
        const blob = try format.inspect(mapped.bytes);
        if (blob.kind != kind) return error.KindMismatch;
        if (metadata) |expected| {
            if (!std.mem.eql(u8, expected, blob.metadata)) return error.MetadataMismatch;
        } else metadata = blob.metadata;
        var iterator = blob.iterator();
        const current = try iterator.next();
        try sources.append(a, .{ .mapped = mapped, .iterator = iterator, .current = current });
    }
    if (sources.items.len == 0) return 0;
    try format.validateMetadata(kind, metadata.?);

    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    const header = format.encodeHeader(kind);
    try out.writeAll(&header);
    try out.writeAll(metadata.?);

    var heap: std.ArrayList(usize) = .empty;
    defer heap.deinit(a);
    for (sources.items, 0..) |source, index| if (source.current != null)
        try heapPush(&heap, a, sources.items, index);

    var previous_title: ?[]const u8 = null;
    var count: usize = 0;
    while (heap.items.len != 0) {
        const index = heapPop(&heap, sources.items);
        const record = sources.items[index].current.?;
        if (previous_title) |previous| if (std.mem.order(u8, previous, record.title) != .lt)
            return error.DuplicateRecord;
        try writeRecord(out, record);
        previous_title = record.title;
        count += 1;
        sources.items[index].current = try sources.items[index].iterator.next();
        if (sources.items[index].current != null) try heapPush(&heap, a, sources.items, index);
    }
    try out.flush();
    return count;
}

fn loadHeadings(io: std.Io, a: std.mem.Allocator, roots: []const []const u8) ![][]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var headings: std.ArrayList([]const u8) = .empty;
    errdefer headings.deinit(a);
    for (roots) |root| {
        const path = try std.fs.path.join(a, &.{ root, catalog.manifest_filename });
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
        defer a.free(bytes);
        var it = try catalog.Iterator.init(bytes);
        while (try it.next()) |entry| {
            if (seen.contains(entry.heading)) continue;
            const heading = try a.dupe(u8, entry.heading);
            try seen.put(a, heading, {});
            try headings.append(a, heading);
        }
    }
    const less = struct {
        fn f(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.f;
    std.sort.pdq([]const u8, headings.items, {}, less);
    return headings.toOwnedSlice(a);
}

fn mergeFallbackReports(io: std.Io, a: std.mem.Allocator, output_root: []const u8, roots: []const []const u8) !void {
    const output_path = try std.fs.path.join(a, &.{ output_root, "fallback-pages.jsonl" });
    defer a.free(output_path);
    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    for (roots) |root| {
        const path = try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" });
        defer a.free(path);
        var mapped = try mmapPath(io, path);
        defer mapped.deinit();
        try writer.interface.writeAll(mapped.bytes);
    }
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: dict-blob-merge OUTPUT_ROOT SHARD_ROOT SHARD_ROOT...\n", .{});
        return error.Usage;
    }
    const a = std.heap.smp_allocator;
    const output_root = args[1];
    var output_exists = true;
    std.Io.Dir.cwd().access(init.io, output_root, .{}) catch |err| switch (err) {
        error.FileNotFound => output_exists = false,
        else => return err,
    };
    if (output_exists) return error.OutputExists;
    try std.Io.Dir.cwd().createDirPath(init.io, output_root);
    const language_root = try std.fs.path.join(a, &.{ output_root, catalog.language_directory });
    defer a.free(language_root);
    try std.Io.Dir.cwd().createDirPath(init.io, language_root);

    const roots = args[2..];
    const headings = try loadHeadings(init.io, a, roots);
    defer {
        for (headings) |heading| a.free(heading);
        a.free(headings);
    }
    const manifest_path = try std.fs.path.join(a, &.{ output_root, catalog.manifest_filename });
    defer a.free(manifest_path);
    var manifest_file = try std.Io.Dir.cwd().createFile(init.io, manifest_path, .{ .truncate = true });
    defer manifest_file.close(init.io);
    var manifest_buffer: [64 * 1024]u8 = undefined;
    var manifest = manifest_file.writer(init.io, &manifest_buffer);
    try manifest.interface.writeAll(catalog.manifest_header ++ "\n");

    var input_paths = try a.alloc([]const u8, roots.len);
    defer a.free(input_paths);
    var language_records: usize = 0;
    for (headings) |heading| {
        var filename_buffer: [catalog.language_blob_filename_len]u8 = undefined;
        const filename = catalog.languageBlobFilename(heading, &filename_buffer);
        for (roots, 0..) |root, i| input_paths[i] = try std.fs.path.join(a, &.{ root, catalog.language_directory, filename });
        defer for (input_paths) |path| a.free(path);
        const output_path = try std.fs.path.join(a, &.{ output_root, catalog.language_directory, filename });
        defer a.free(output_path);
        language_records += try mergeOne(init.io, a, output_path, .language, input_paths);
        try catalog.writeEntry(&manifest.interface, heading);
    }
    try manifest.interface.flush();

    var fixed_records: usize = 0;
    inline for (.{ format.BlobKind.thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss }) |kind| {
        const filename = catalog.featureBlobFilename(kind).?;
        for (roots, 0..) |root, i| input_paths[i] = try std.fs.path.join(a, &.{ root, filename });
        defer for (input_paths) |path| a.free(path);
        const output_path = try std.fs.path.join(a, &.{ output_root, filename });
        defer a.free(output_path);
        fixed_records += try mergeOne(init.io, a, output_path, kind, input_paths);
    }
    try mergeFallbackReports(init.io, a, output_root, roots);
    std.debug.print("merged shards={d} language_blobs={d} language_records={d} fixed_records={d}\n", .{ roots.len, headings.len, language_records, fixed_records });
}
