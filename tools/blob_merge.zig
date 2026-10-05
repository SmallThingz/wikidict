const std = @import("std");
const encoder = @import("encoder");
const format = encoder.blob_format;
const catalog = encoder.blob_catalog;
const file_reader = @import("blob_file_reader.zig");

const MergeSource = struct {
    reader: file_reader.Reader,
    current: ?file_reader.Record,
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

fn writeRecord(out: *std.Io.Writer, reader: *file_reader.Reader, record: file_reader.Record) !void {
    try format.validateRecordInput(.{ .title = record.title, .payload = &.{} });
    try out.writeAll(record.title);
    try out.writeByte(0);
    var encoded_len: [format.max_varuint_len]u8 = undefined;
    try out.writeAll(format.encodePayloadLength(record.payload_len, &encoded_len));
    try reader.copyPayload(record, out);
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
        for (sources.items) |*source| source.reader.deinit();
        sources.deinit(a);
    }
    var metadata: ?[]const u8 = null;
    for (input_paths) |path| {
        var reader = file_reader.Reader.init(io, a, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        errdefer reader.deinit();
        try reader.validate();
        if (reader.kind != kind) return error.KindMismatch;
        if (metadata) |expected| {
            if (!std.mem.eql(u8, expected, reader.metadata.items)) return error.MetadataMismatch;
        } else metadata = reader.metadata.items;
        const current = try reader.next();
        try sources.append(a, .{ .reader = reader, .current = current });
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

    var previous_title: std.ArrayList(u8) = .empty;
    defer previous_title.deinit(a);
    var count: usize = 0;
    while (heap.items.len != 0) {
        const index = heapPop(&heap, sources.items);
        const record = sources.items[index].current.?;
        if (count != 0 and std.mem.order(u8, previous_title.items, record.title) != .lt)
            return error.DuplicateRecord;
        try writeRecord(out, &sources.items[index].reader, record);
        // next() reuses this source's title buffers, so the global ordering key
        // must be owned separately before advancing that source.
        previous_title.clearRetainingCapacity();
        try previous_title.appendSlice(a, record.title);
        count += 1;
        sources.items[index].current = try sources.items[index].reader.next();
        if (sources.items[index].current != null) try heapPush(&heap, a, sources.items, index);
    }
    try out.flush();
    return count;
}

// Each heading maps to a distinct hashed output file. Keep one worker on the
// caller and allow at most one additional worker to bound simultaneous IO.
const LanguageMergePool = struct {
    io: std.Io,
    language_root: []const u8,
    roots: []const []const u8,
    headings: []const []const u8,
    counts: []usize,
    next: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    const Worker = struct {
        pool: *LanguageMergePool,
        failure: ?anyerror = null,

        fn run(self: *Worker) void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            while (!self.pool.stop.load(.acquire)) {
                const index = self.pool.next.fetchAdd(1, .monotonic);
                if (index >= self.pool.headings.len) break;
                self.pool.counts[index] = self.mergeHeading(a, self.pool.headings[index]) catch |err| {
                    self.failure = err;
                    self.pool.stop.store(true, .release);
                    break;
                };
                _ = arena.reset(.retain_capacity);
            }
        }

        fn mergeHeading(self: *Worker, a: std.mem.Allocator, heading: []const u8) !usize {
            var filename_buffer: [catalog.language_blob_filename_len]u8 = undefined;
            const filename = catalog.languageBlobFilename(heading, &filename_buffer);
            const paths = try a.alloc([]const u8, self.pool.roots.len);
            for (self.pool.roots, 0..) |root, i| {
                paths[i] = try std.fs.path.join(a, &.{ root, catalog.language_directory, filename });
            }
            const output_path = try std.fs.path.join(a, &.{ self.pool.language_root, filename });
            const partial_path = try std.fmt.allocPrint(a, "{s}.part", .{output_path});
            errdefer std.Io.Dir.cwd().deleteFile(self.pool.io, partial_path) catch {};
            const count = try mergeOne(self.pool.io, a, partial_path, .language, paths);
            // A manifest may list a heading absent from every shard blob. A
            // present zero-record blob still needs its header published.
            var partial_exists = true;
            std.Io.Dir.cwd().access(self.pool.io, partial_path, .{}) catch |err| switch (err) {
                error.FileNotFound => partial_exists = false,
                else => return err,
            };
            if (partial_exists) try std.Io.Dir.cwd().rename(partial_path, std.Io.Dir.cwd(), output_path, self.pool.io);
            return count;
        }
    };
};

fn mergeLanguagesParallel(
    io: std.Io,
    a: std.mem.Allocator,
    language_root: []const u8,
    roots: []const []const u8,
    headings: []const []const u8,
) !usize {
    if (headings.len == 0) return 0;
    const counts = try a.alloc(usize, headings.len);
    defer a.free(counts);
    var pool: LanguageMergePool = .{
        .io = io,
        .language_root = language_root,
        .roots = roots,
        .headings = headings,
        .counts = counts,
    };
    var workers: [2]LanguageMergePool.Worker = .{
        .{ .pool = &pool },
        .{ .pool = &pool },
    };
    if (@import("builtin").single_threaded or headings.len == 1) {
        workers[0].run();
    } else {
        const thread = try std.Thread.spawn(.{}, LanguageMergePool.Worker.run, .{&workers[1]});
        workers[0].run();
        thread.join();
    }
    if (workers[0].failure) |err| return err;
    if (workers[1].failure) |err| return err;
    var total: usize = 0;
    for (counts) |count| total = try std.math.add(usize, total, count);
    return total;
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
        var input = try file_reader.Window.init(io, path);
        defer input.deinit();
        try input.copyRange(0, input.size, &writer.interface);
        try input.checkIdentity();
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
    const language_records = try mergeLanguagesParallel(init.io, a, language_root, roots, headings);
    for (headings) |heading| try catalog.writeEntry(&manifest.interface, heading);
    try manifest.interface.flush();

    var fixed_records: usize = 0;
    inline for (.{ format.BlobKind.thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss, .supplemental }) |kind| {
        const filename = catalog.featureBlobFilename(kind).?;
        for (roots, 0..) |root, i| input_paths[i] = try std.fs.path.join(a, &.{ root, filename });
        defer for (input_paths) |path| a.free(path);
        const output_path = try std.fs.path.join(a, &.{ output_root, filename });
        defer a.free(output_path);
        fixed_records += try mergeOne(init.io, a, output_path, kind, input_paths);
    }
    try mergeFallbackReports(init.io, a, output_root, roots);
    var coverage: encoder.namespace_coverage.Table = .{};
    defer coverage.deinit(a);
    for (roots) |root| {
        var shard_coverage = try encoder.namespace_coverage.Table.read(init.io, a, root);
        defer shard_coverage.deinit(a);
        try coverage.merge(a, &shard_coverage);
    }
    try coverage.write(init.io, a, output_root);
    std.debug.print("merged shards={d} language_blobs={d} language_records={d} fixed_records={d}\n", .{ roots.len, headings.len, language_records, fixed_records });
}

test "streamed merge keeps cross-source payload association and global title lifetime" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const left = try std.fs.path.join(a, &.{ root, "left" });
    defer a.free(left);
    const right = try std.fs.path.join(a, &.{ root, "right" });
    defer a.free(right);
    const out = try std.fs.path.join(a, &.{ root, "out" });
    defer a.free(out);
    // Three consecutive records in one source plus interleaving source records
    // exercise source title-buffer reuse and the global previous-title copy.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = left, .data = "WIKBLB08\x07a\x00\x01Ab\x00\x01Bd\x00\x01Df\x00\x01F" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = right, .data = "WIKBLB08\x07c\x00\x01Ce\x00\x00g\x00\x01G" });
    try std.testing.expectEqual(@as(usize, 7), try mergeOne(io, a, out, .supplemental, &.{ left, right }));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, "WIKBLB08\x07a\x00\x01Ab\x00\x01Bc\x00\x01Cd\x00\x01De\x00\x00f\x00\x01Fg\x00\x01G", bytes);
    _ = try format.inspect(bytes);
}

test "streamed merge keeps source-order and cross-source-duplicate errors distinct" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const left = try std.fs.path.join(a, &.{ root, "left" });
    defer a.free(left);
    const right = try std.fs.path.join(a, &.{ root, "right" });
    defer a.free(right);
    const out = try std.fs.path.join(a, &.{ root, "out" });
    defer a.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = right, .data = "WIKBLB08\x07a\x00\x01R" });
    for ([_][]const u8{
        "WIKBLB08\x07a\x00\x01Aa\x00\x01B",
        "WIKBLB08\x07b\x00\x01Ba\x00\x01A",
    }) |invalid| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = left, .data = invalid });
        try std.testing.expectError(error.InvalidBlob, mergeOne(io, a, out, .supplemental, &.{ left, right }));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, out, .{}));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = left, .data = "WIKBLB08\x07a\x00\x01L" });
    // Both shards individually valid; no silent first/last-wins deduplication.
    try std.testing.expectError(error.DuplicateRecord, mergeOne(io, a, out, .supplemental, &.{ left, right }));
}

test "streamed merge preserves per-input validation and mismatch precedence" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const left = try std.fs.path.join(a, &.{ root, "left" });
    defer a.free(left);
    const right = try std.fs.path.join(a, &.{ root, "right" });
    defer a.free(right);
    const out = try std.fs.path.join(a, &.{ root, "out" });
    defer a.free(out);
    // The same input must be framing/order-validated before kind is checked.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = left, .data = "WIKBLB08\x02a\x00\x80" });
    try std.testing.expectError(error.InvalidBlob, mergeOne(io, a, out, .supplemental, &.{left}));
    // But an earlier valid wrong-kind source wins over a later corrupt source.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = left, .data = "WIKBLB08\x02a\x00\x00" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = right, .data = "WIKBLB08\x07a\x00\x80" });
    try std.testing.expectError(error.KindMismatch, mergeOne(io, a, out, .supplemental, &.{ left, right }));
    // Empty codes are legal, but byte-different language metadata cannot merge.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = left, .data = "WIKBLB08\x01en\x00English\x00" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = right, .data = "WIKBLB08\x01fr\x00English\x00" });
    try std.testing.expectError(error.MetadataMismatch, mergeOne(io, a, out, .language, &.{ left, right }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, out, .{}));
}
