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
    return mergeOneMode(io, a, output_path, kind, input_paths, null);
}

const xz_argv = [_][]const u8{ "xz", "--compress", "--format=xz", "--check=crc64", "-0", "--threads=1", "--block-size=1MiB", "--stdout" };

fn syncParent(io: std.Io, path: []const u8) !void {
    // Default non-iterable directories use O_PATH on Linux, which cannot be fsynced.
    const dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{ .iterate = true });
    defer dir.close(io);
    const file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

fn mergeOneMode(
    io: std.Io,
    a: std.mem.Allocator,
    output_path: []const u8,
    kind: format.BlobKind,
    input_paths: []const []const u8,
    encoder_argv: ?[]const []const u8,
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

    const target = if (encoder_argv != null) try std.fmt.allocPrint(a, "{s}.xz", .{output_path}) else output_path;
    defer if (encoder_argv != null) a.free(target);
    const part = if (encoder_argv != null) try std.fmt.allocPrint(a, "{s}.part", .{target}) else target;
    defer if (encoder_argv != null) a.free(part);
    if (encoder_argv != null) {
        // Fresh output roots are required by main; never replace a committed blob.
        if (std.Io.Dir.cwd().access(io, target, .{})) |_| return error.OutputExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    var file = try std.Io.Dir.cwd().createFile(io, part, .{ .truncate = true, .exclusive = encoder_argv != null });
    defer file.close(io);
    var committed = false;
    defer if (encoder_argv != null and !committed) std.Io.Dir.cwd().deleteFile(io, part) catch {};
    var child: ?std.process.Child = null;
    defer if (child) |*process| process.kill(io);
    if (encoder_argv) |argv| child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .{ .file = file }, .stderr = .inherit });
    var buffer: [256 * 1024]u8 = undefined;
    var writer = (if (child) |process| process.stdin.? else file).writer(io, &buffer);
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
    if (child) |*process| {
        process.stdin.?.close(io);
        process.stdin = null;
        const term = try process.wait(io);
        child = null;
        if (!term.success()) return error.EncoderFailed;
        try file.sync(io);
        try std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), target, io);
        committed = true;
        try syncParent(io, target);
    }
    return count;
}

// Each heading maps to a distinct hashed output file. Keep one worker on the
// caller and allow at most one additional worker to bound simultaneous IO.
const LanguageMergePool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    language_root: []const u8,
    roots: []const []const u8,
    headings: []const []const u8,
    counts: []usize,
    compress_output: bool = false,
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
            // Reader caches replace allocations while a heading is live; their frees
            // require a reclaiming allocator rather than the path scratch arena.
            if (self.pool.compress_output) return mergeOneMode(self.pool.io, self.pool.allocator, output_path, .language, paths, &xz_argv);
            const partial_path = try std.fmt.allocPrint(a, "{s}.part", .{output_path});
            errdefer std.Io.Dir.cwd().deleteFile(self.pool.io, partial_path) catch {};
            const count = try mergeOne(self.pool.io, self.pool.allocator, partial_path, .language, paths);
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
    compress_output: bool,
) !usize {
    if (headings.len == 0) return 0;
    const counts = try a.alloc(usize, headings.len);
    defer a.free(counts);
    var pool: LanguageMergePool = .{
        .io = io,
        .allocator = a,
        .language_root = language_root,
        .roots = roots,
        .headings = headings,
        .counts = counts,
        .compress_output = compress_output,
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
    const compress_output = args.len > 1 and std.mem.eql(u8, args[1], "--compress-output");
    const first: usize = if (compress_output) 2 else 1;
    if (args.len < first + 2) {
        std.debug.print("usage: dict-blob-merge [--compress-output] OUTPUT_ROOT SHARD_ROOT SHARD_ROOT...\n", .{});
        return error.Usage;
    }
    const a = std.heap.smp_allocator;
    const output_root = args[first];
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

    const roots = args[first + 1 ..];
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
    const language_records = try mergeLanguagesParallel(init.io, a, language_root, roots, headings, compress_output);
    for (headings) |heading| try catalog.writeEntry(&manifest.interface, heading);
    try manifest.interface.flush();

    var fixed_records: usize = 0;
    var alias_records: usize = 0;
    inline for (.{ format.BlobKind.thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss, .supplemental, .alias }) |kind| {
        const filename = catalog.featureBlobFilename(kind).?;
        for (roots, 0..) |root, i| input_paths[i] = try std.fs.path.join(a, &.{ root, filename });
        defer for (input_paths) |path| a.free(path);
        const output_path = try std.fs.path.join(a, &.{ output_root, filename });
        defer a.free(output_path);
        const records = try mergeOneMode(init.io, a, output_path, kind, input_paths, if (compress_output) &xz_argv else null);
        if (kind == .alias) alias_records += records else fixed_records += records;
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
    std.debug.print("merged shards={d} language_blobs={d} language_records={d} fixed_records={d} alias_records={d}\n", .{ roots.len, headings.len, language_records, fixed_records, alias_records });
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
    const xz_out = try std.fs.path.join(a, &.{ root, "compressed-output" });
    defer a.free(xz_out);
    try std.testing.expectEqual(@as(usize, 7), try mergeOneMode(io, a, xz_out, .supplemental, &.{ left, right }, &xz_argv));
    const xz_path = try std.fmt.allocPrint(a, "{s}.xz", .{xz_out});
    defer a.free(xz_path);
    const decoded = try std.process.run(a, io, .{ .argv = &.{ "xz", "--decompress", "--stdout", "--", xz_path }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    defer a.free(decoded.stdout);
    defer a.free(decoded.stderr);
    try std.testing.expect(decoded.term.success());
    try std.testing.expectEqualSlices(u8, bytes, decoded.stdout);
    var compressed_reader = try file_reader.Reader.init(io, a, xz_out);
    defer compressed_reader.deinit();
    try compressed_reader.validate();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, xz_out, .{}));
    const failed_out = try std.fs.path.join(a, &.{ root, "failed-output" });
    defer a.free(failed_out);
    try std.testing.expectError(error.EncoderFailed, mergeOneMode(io, a, failed_out, .supplemental, &.{ left, right }, &.{ "sh", "-c", "cat; exit 7" }));
    for ([_][]const u8{ ".xz", ".xz.part" }) |suffix| {
        const failed_path = try std.fmt.allocPrint(a, "{s}{s}", .{ failed_out, suffix });
        defer a.free(failed_path);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, failed_path, .{}));
    }
    // The same merge contract applies to mixed and fully compressed shards.
    try file_reader.writeTestXz(io, a, left);
    try std.Io.Dir.cwd().deleteFile(io, left);
    for (0..2) |mode| {
        if (mode == 1) {
            try file_reader.writeTestXz(io, a, right);
            try std.Io.Dir.cwd().deleteFile(io, right);
        }
        try std.Io.Dir.cwd().deleteFile(io, out);
        try std.testing.expectEqual(@as(usize, 7), try mergeOne(io, a, out, .supplemental, &.{ left, right }));
        const compressed_result = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .limited(4096));
        defer a.free(compressed_result);
        try std.testing.expectEqualSlices(u8, bytes, compressed_result);
    }
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

test "language merge reclaims decoded blocks outside heading scratch arena" {
    const Tracking = struct {
        backing: std.mem.Allocator,
        live: usize = 0,
        peak: usize = 0,
        block_allocations: usize = 0,
        block_frees: usize = 0,
        limit: usize = 1024 * 1024,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (len > self.limit - self.live) return null;
            const bytes = self.backing.rawAlloc(len, alignment, ra) orelse return null;
            self.live += len;
            if (len == 64 * 1024) self.block_allocations += 1;
            self.peak = @max(self.peak, self.live);
            return bytes;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(bytes, alignment, ra);
            self.live -= bytes.len;
            if (bytes.len == 64 * 1024) self.block_frees += 1;
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const left_root = try std.fs.path.join(a, &.{ root, "left" });
    defer a.free(left_root);
    const right_root = try std.fs.path.join(a, &.{ root, "right" });
    defer a.free(right_root);
    const output_root = try std.fs.path.join(a, &.{ root, "output" });
    defer a.free(output_root);
    const roots = [_][]const u8{ left_root, right_root };
    for (roots) |source_root| {
        const languages = try std.fs.path.join(a, &.{ source_root, catalog.language_directory });
        defer a.free(languages);
        try std.Io.Dir.cwd().createDirPath(io, languages);
    }
    try std.Io.Dir.cwd().createDirPath(io, output_root);
    // Small blocks force many payload cache replacements after preflight.
    const payload = try a.alloc(u8, 512 * 1024 + 17);
    defer a.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i *% 17);
    var tracked: Tracking = .{ .backing = a };
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    for ([_][]const u8{ "English", "Other" }, [_]bool{ false, true }) |heading, compress_output| {
        const metadata = try format.buildLanguageMetadataAlloc(a, "", heading);
        defer a.free(metadata);
        const left_records = [_]format.RecordInput{
            .{ .title = "a", .payload = payload }, .{ .title = "c", .payload = "LEFT_TAIL" },
        };
        const right_records = [_]format.RecordInput{
            .{ .title = "b", .payload = payload }, .{ .title = "d", .payload = "RIGHT_TAIL" },
        };
        var filename_buffer: [catalog.language_blob_filename_len]u8 = undefined;
        const filename = catalog.languageBlobFilename(heading, &filename_buffer);
        for (roots, 0..) |source_root, index| {
            const path = try std.fs.path.join(a, &.{ source_root, catalog.language_directory, filename });
            defer a.free(path);
            const bytes = try format.buildAlloc(a, .language, metadata, if (index == 0) &left_records else &right_records);
            defer a.free(bytes);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            const compressed = try std.process.run(a, io, .{
                .argv = &.{ "xz", "-0", "-c", "--threads=1", "--check=crc64", "--block-size=64KiB", path },
                .stdout_limit = .limited(2 * 1024 * 1024),
                .stderr_limit = .limited(4096),
            });
            defer a.free(compressed.stdout);
            defer a.free(compressed.stderr);
            try std.testing.expect(compressed.term.success());
            const alternate = try std.fmt.allocPrint(a, "{s}.xz", .{path});
            defer a.free(alternate);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = alternate, .data = compressed.stdout });
            try std.Io.Dir.cwd().deleteFile(io, path);
        }
        var pool: LanguageMergePool = .{
            .io = io,
            .allocator = tracked.allocator(),
            .language_root = output_root,
            .roots = &roots,
            .headings = &.{},
            .counts = &.{},
            .compress_output = compress_output,
        };
        var worker: LanguageMergePool.Worker = .{ .pool = &pool };
        try std.testing.expectEqual(@as(usize, 4), try worker.mergeHeading(scratch.allocator(), heading));
        // Previously the Reader allocated blocks from scratch: old non-tail
        // cache frees did nothing and decoded input accumulated for the heading.
        try std.testing.expect(scratch.queryCapacity() < 256 * 1024);
        try std.testing.expect(tracked.peak > 256 * 1024);
        try std.testing.expect(tracked.peak <= tracked.limit);
        try std.testing.expectEqual(@as(usize, 0), tracked.live);
        try std.testing.expect(tracked.block_allocations >= 16);
        try std.testing.expectEqual(tracked.block_allocations, tracked.block_frees);
        const expected = try format.buildAlloc(a, .language, metadata, &.{ left_records[0], right_records[0], left_records[1], right_records[1] });
        defer a.free(expected);
        const output = try std.fs.path.join(a, &.{ output_root, filename });
        defer a.free(output);
        if (compress_output) {
            const compressed_output = try std.fmt.allocPrint(a, "{s}.xz", .{output});
            defer a.free(compressed_output);
            const decoded = try std.process.run(a, io, .{
                .argv = &.{ "xz", "--decompress", "--stdout", "--", compressed_output },
                .stdout_limit = .limited(2 * 1024 * 1024),
                .stderr_limit = .limited(4096),
            });
            defer a.free(decoded.stdout);
            defer a.free(decoded.stderr);
            try std.testing.expect(decoded.term.success());
            try std.testing.expectEqualSlices(u8, expected, decoded.stdout);
        } else {
            const actual = try std.Io.Dir.cwd().readFileAlloc(io, output, a, .limited(2 * 1024 * 1024));
            defer a.free(actual);
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
        _ = scratch.reset(.free_all);
        tracked.peak = 0;
        tracked.block_allocations = 0;
        tracked.block_frees = 0;
    }
    // A small allocator refusal during Reader initialization must release the
    // compressed map, owned alternate path and all prior Reader allocations.
    var filename_buffer: [catalog.language_blob_filename_len]u8 = undefined;
    const filename = catalog.languageBlobFilename("English", &filename_buffer);
    const kept_path = try std.fs.path.join(a, &.{ output_root, filename });
    defer a.free(kept_path);
    const before = try std.Io.Dir.cwd().readFileAlloc(io, kept_path, a, .limited(2 * 1024 * 1024));
    defer a.free(before);
    var refused: Tracking = .{ .backing = a, .limit = 64 * 1024 };
    var refused_pool: LanguageMergePool = .{
        .io = io,
        .allocator = refused.allocator(),
        .language_root = output_root,
        .roots = &roots,
        .headings = &.{},
        .counts = &.{},
    };
    var refused_worker: LanguageMergePool.Worker = .{ .pool = &refused_pool };
    try std.testing.expectError(error.OutOfMemory, refused_worker.mergeHeading(scratch.allocator(), "English"));
    try std.testing.expectEqual(@as(usize, 0), refused.live);
    try std.testing.expect(scratch.queryCapacity() < 256 * 1024);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, kept_path, a, .limited(2 * 1024 * 1024));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    const partial = try std.fmt.allocPrint(a, "{s}.part", .{kept_path});
    defer a.free(partial);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, partial, .{}));
}
