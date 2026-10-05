const std = @import("std");
const namespace_registry = @import("namespace_registry");
const xml_decode = @import("xml_decode");
const usage_closure = @import("usage_closure.zig");
const lua_usage = @import("lua_usage");
const wikimedia_dump = @import("wikimedia_dump");

const Capture = wikimedia_dump.PageView;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
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

const PageItem = struct {
    capture: Capture,
    source: wikimedia_dump.PageSource,
};

fn sliceOffset(container: []const u8, slice: []const u8) !usize {
    if (slice.len == 0) return 0;
    const base = @intFromPtr(container.ptr);
    const ptr = @intFromPtr(slice.ptr);
    if (ptr < base) return error.InvalidXmlSlice;
    const offset = ptr - base;
    if (offset > container.len or slice.len > container.len - offset) return error.InvalidXmlSlice;
    return offset;
}

const InputPages = union(enum) {
    raw: struct {
        mapped: Mapped,
        pages: wikimedia_dump.PageIterator,
    },
    compressed: struct {
        kind: wikimedia_dump.PageIndexKind,
        walker: wikimedia_dump.MultistreamWalker,
        pages: wikimedia_dump.PageIterator = .{ .bytes = "" },
        stream_id: u32 = 0,
    },

    fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8, index_path: ?[]const u8) !InputPages {
        if (std.mem.endsWith(u8, path, ".bz2") or std.mem.endsWith(u8, path, ".xml.zst")) {
            const index = index_path orelse return error.MultistreamIndexPathRequired;
            const kind: wikimedia_dump.PageIndexKind = if (std.mem.endsWith(u8, path, ".xml.zst")) .multistream_zstd else .multistream_bz2;
            return .{ .compressed = .{ .kind = kind, .walker = try wikimedia_dump.MultistreamWalker.open(io, allocator, path, index, kind) } };
        }
        var mapped = try mmapPath(path);
        errdefer mapped.deinit();
        return .{ .raw = .{ .mapped = mapped, .pages = .{ .bytes = mapped.bytes } } };
    }

    fn deinit(self: *InputPages) void {
        switch (self.*) {
            .raw => |*raw| raw.mapped.deinit(),
            .compressed => |*compressed| compressed.walker.deinit(),
        }
        self.* = undefined;
    }

    fn next(self: *InputPages) !?PageItem {
        switch (self.*) {
            .raw => |*raw| {
                const capture = try raw.pages.next() orelse return null;
                const text = capture.text_raw orelse "";
                return .{
                    .capture = capture,
                    .source = .{ .raw_xml = .{
                        .offset = @intCast(try sliceOffset(raw.mapped.bytes, text)),
                        .len = text.len,
                    } },
                };
            },
            .compressed => |*compressed| {
                while (true) {
                    if (try compressed.pages.next()) |capture| {
                        const text = capture.text_raw orelse "";
                        return .{
                            .capture = capture,
                            .source = if (compressed.kind == .multistream_zstd) .{ .multistream_zstd = .{
                                .stream_id = compressed.stream_id,
                                .offset = try sliceOffset(compressed.pages.bytes, text),
                                .len = text.len,
                            } } else .{ .multistream_bz2 = .{
                                .stream_id = compressed.stream_id,
                                .offset = try sliceOffset(compressed.pages.bytes, text),
                                .len = text.len,
                            } },
                        };
                    }
                    const member = try compressed.walker.next() orelse return null;
                    compressed.stream_id = member.id;
                    compressed.pages = .{ .bytes = member.bytes };
                }
            },
        }
    }

    fn consumedStreamCount(self: *const InputPages) ?usize {
        return switch (self.*) {
            .raw => null,
            .compressed => |compressed| @intCast(compressed.walker.streams.stream_id),
        };
    }
};

fn writeStreamTable(io: std.Io, allocator: std.mem.Allocator, dump_path: []const u8, index_path: []const u8, output_path: []const u8) !usize {
    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [128 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(wikimedia_dump.stream_index_header ++ "\n");
    var streams = try wikimedia_dump.StreamIterator.open(io, allocator, dump_path, index_path);
    defer streams.close();
    var count: usize = 0;
    while (try streams.next()) |stream| {
        try writer.interface.print("{d}\t{d}\t{d}\n", .{ stream.id, stream.span.offset, stream.span.len });
        count += 1;
    }
    try writer.interface.flush();
    return count;
}
fn writeAllFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeTsvField(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}

fn writePageIndexRow(
    w: *std.Io.Writer,
    source: wikimedia_dump.PageSource,
    title: []const u8,
    redirect: ?[]const u8,
    page_id: u64,
    revision_id: u64,
    revision_timestamp: []const u8,
    revision_user: []const u8,
    content_model: []const u8,
    ns: u32,
    has_source: bool,
    source_needs_decode: bool,
) !void {
    switch (source) {
        .raw_xml => |loc| try w.print("{d}\t{d}\t", .{ loc.offset, loc.len }),
        .multistream_bz2, .multistream_zstd => |loc| try w.print("{d}\t{d}\t{d}\t", .{ loc.stream_id, loc.offset, loc.len }),
    }
    try w.print("{s}\t{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n", .{
        title,
        redirect orelse "",
        page_id,
        revision_id,
        revision_timestamp,
        revision_user,
        content_model,
        ns,
        @intFromBool(has_source),
        @intFromBool(source_needs_decode),
    });
}

const UsageCountMap = std.StringHashMapUnmanaged(u64);

fn incrementUsageCount(a: std.mem.Allocator, counts: *UsageCountMap, key: []const u8) !void {
    if (counts.getPtr(key)) |value| {
        value.* = std.math.add(u64, value.*, 1) catch std.math.maxInt(u64);
        return;
    }
    const owned = try a.dupe(u8, key);
    errdefer a.free(owned);
    try counts.put(a, owned, 1);
}

fn writeUsageEdge(w: *std.Io.Writer, kind: u8, source: []const u8, target: []const u8) !void {
    try w.writeByte(kind);
    try w.writeByte('\t');
    try writeTsvField(w, source);
    try w.writeByte('\t');
    try writeTsvField(w, target);
    try w.writeByte('\n');
}

fn writeDynamicUsage(w: *std.Io.Writer, kind: []const u8, source: ?[]const u8) !void {
    try w.writeAll("D\t");
    try w.writeAll(kind);
    if (source) |name| {
        try w.writeByte('\t');
        try writeTsvField(w, name);
    }
    try w.writeByte('\n');
}

fn writeUsageCounts(
    a: std.mem.Allocator,
    w: *std.Io.Writer,
    kind: u8,
    counts: *const UsageCountMap,
) !void {
    const keys = try a.alloc([]const u8, counts.count());
    defer a.free(keys);
    var it = counts.keyIterator();
    var at: usize = 0;
    while (it.next()) |key| : (at += 1) keys[at] = key.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    for (keys) |key| {
        try w.writeByte(kind);
        try w.writeByte('\t');
        try writeTsvField(w, key);
        try w.print("\t{d}\n", .{counts.get(key).?});
    }
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

const FileIdentity = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,
};
fn pathIdentity(io: std.Io, path: []const u8) !FileIdentity {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const linux = std.os.linux;
    var stat: linux.Statx = undefined;
    if (linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat) != 0 or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME or !stat.mask.TYPE or (stat.mode & linux.S.IFMT) != linux.S.IFREG) return error.SourceStatFailed;
    return .{ .device_major = stat.dev_major, .device_minor = stat.dev_minor, .inode = stat.ino, .size = stat.size, .mtime_ns = @as(i128, stat.mtime.sec) * std.time.ns_per_s + stat.mtime.nsec, .ctime_ns = @as(i128, stat.ctime.sec) * std.time.ns_per_s + stat.ctime.nsec };
}
fn snapshotHash(io: std.Io, a: std.mem.Allocator, root: []const u8, name: []const u8, optional: bool) !?[32]u8 {
    const path = try std.fs.path.join(a, &.{ root, name });
    defer a.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => if (optional) return null else return err,
        else => return err,
    };
    defer a.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}
fn sourceReceipt(io: std.Io, a: std.mem.Allocator, input: []const u8, root: []const u8, registry: *const namespace_registry.Registry, expected_source: ?FileIdentity) ![]const u8 {
    var identities: [3]?FileIdentity = .{ null, null, null };
    const names = [_][]const u8{ "page-index.tsv", wikimedia_dump.page_title_index_filename, "dump-streams.tsv" };
    for (names, 0..) |name, i| {
        const path = try std.fs.path.join(a, &.{ root, name });
        defer a.free(path);
        identities[i] = pathIdentity(io, path) catch |err| switch (err) {
            error.FileNotFound => if (i == 2) null else return err,
            else => return err,
        };
        if (identities[i]) |*identity| identity.ctime_ns = 0;
    }
    const source = try pathIdentity(io, input);
    if (expected_source) |expected| if (!std.meta.eql(expected, source)) return error.ExtractionSourceChanged;
    const namespace = try snapshotHash(io, a, root, "namespace-registry.tsv", false);
    if (!std.mem.eql(u8, &namespace.?, &registry.source_sha256)) return error.ExtractionSourceChanged;
    return std.json.Stringify.valueAlloc(a, .{ .version = 2, .source = source, .indexes = identities, .namespace_sha256 = namespace, .redirects_sha256 = try snapshotHash(io, a, root, "transclusion-redirects.tsv", true) }, .{});
}
fn rebuildUsage(io: std.Io, a: std.mem.Allocator, input: []const u8, root: []const u8, registry: *const namespace_registry.Registry) !void {
    const receipt_path = try std.fs.path.join(a, &.{ root, "extraction-source.json" });
    const recorded = try std.Io.Dir.cwd().readFileAlloc(io, receipt_path, a, .limited(16384));
    const before = try sourceReceipt(io, a, input, root, registry, null);
    if (!std.mem.eql(u8, recorded, before)) return error.ExtractionSourceChanged;
    const rows_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    var rows = try mmapPath(rows_path);
    defer rows.deinit();
    const index_path = try std.fs.path.join(a, &.{ root, wikimedia_dump.page_title_index_filename });
    var index_bytes = try mmapPath(index_path);
    defer index_bytes.deinit();
    const index = try wikimedia_dump.PageTitleIndex.init(index_bytes.bytes);
    const kind = wikimedia_dump.pageIndexKind(rows.bytes);
    if (index.page_index_size != rows.bytes.len or index.kind != kind) return error.InvalidPageTitleIndex;
    const streams_path = try std.fs.path.join(a, &.{ root, "dump-streams.tsv" });
    var reader = try wikimedia_dump.SourceReader.open(io, std.heap.smp_allocator, std.heap.smp_allocator, input, kind, if (kind == .raw_xml) null else streams_path);
    var reader_open = true;
    defer if (reader_open) reader.deinit();
    const usage_path = try std.fs.path.join(a, &.{ root, "lua-usage.tsv" });
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, usage_path, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [256 * 1024]u8 = undefined;
    var output = atomic.file.writer(io, &buffer);
    var hashed = output.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &.{});
    const writer = &hashed.writer;
    try writer.writeAll("# dict-lua-usage-v1\n");
    var templates: UsageCountMap = .empty;
    defer templates.deinit(a);
    var modules: UsageCountMap = .empty;
    defer modules.deinit(a);
    var dynamic = false;
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, rows.bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        defer _ = scratch.reset(.retain_capacity);
        const page = try wikimedia_dump.parsePageIndexLine(kind, line);
        count += 1;
        const spec = registry.byId(std.math.cast(i32, page.ns) orelse return error.InvalidNamespace) orelse return error.InvalidNamespace;
        if (registry.ofTitle(page.title).id != spec.id) return error.NamespaceTitleMismatch;
        if (spec.role == .compile_only or page.redirect != null or !page.has_source or !std.mem.eql(u8, page.content_model, "wikitext")) continue;
        const raw = try reader.readAlloc(scratch.allocator(), page.source);
        const source = if (page.source_needs_decode) try xml_decode.decodeSinglePassAlloc(scratch.allocator(), raw) else raw;
        var refs: std.ArrayList(lua_usage.Ref) = .empty;
        const flags = try lua_usage.scanWikitextFlags(scratch.allocator(), registry, page.title, source, &refs);
        dynamic = dynamic or flags.dynamic_module_target or flags.dynamic_template_target;
        var seen_templates: std.StringHashMapUnmanaged(void) = .empty;
        var seen_modules: std.StringHashMapUnmanaged(void) = .empty;
        for (refs.items) |ref| {
            const seen = if (ref.kind == .template) &seen_templates else &seen_modules;
            if (seen.contains(ref.target)) continue;
            try seen.put(scratch.allocator(), ref.target, {});
            try incrementUsageCount(a, if (ref.kind == .template) &templates else &modules, ref.target);
        }
    }
    if (count != index.row_count) return error.InvalidPageTitleIndex;
    reader.deinit();
    reader_open = false;
    rows.deinit();
    index_bytes.deinit();
    _ = scratch.reset(.free_all);
    const closure = try usage_closure.complete(io, std.heap.smp_allocator, registry, input, root, &templates, writer);
    try writeUsageCounts(a, writer, 'R', &templates);
    try writeUsageCounts(a, writer, 'P', &modules);
    if (dynamic or closure.retain_all_modules) try writeDynamicUsage(writer, "module", null);
    try writer.flush();
    try output.interface.flush();
    try atomic.file.sync(io);
    const after = try sourceReceipt(io, a, input, root, registry, null);
    if (!std.mem.eql(u8, before, after)) return error.ExtractionSourceChanged;
    var previous = try std.Io.Dir.cwd().openFile(io, usage_path, .{});
    defer previous.close(io);
    var old_buffer: [64 * 1024]u8 = undefined;
    var old_reader = previous.reader(io, &old_buffer);
    var hash_buffer: [64 * 1024]u8 = undefined;
    var old_hash: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&hash_buffer);
    _ = try old_reader.interface.streamRemaining(&old_hash.writer);
    try old_hash.writer.flush();
    var old_digest: [32]u8 = undefined;
    var new_digest: [32]u8 = undefined;
    old_hash.hasher.final(&old_digest);
    hashed.hasher.final(&new_digest);
    if (std.mem.eql(u8, &old_digest, &new_digest)) return;
    const worker = try std.fs.path.join(a, &.{ root, "dict-bundle-expander" });
    if (std.Io.Dir.cwd().access(io, worker, .{})) |_| {
        const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "usage changed; native rebuild required\n" });
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try atomic.replace(io);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) return error.Usage;
    const option = if (args.len == 4) args[3] else "";
    const emit_page_index = std.mem.eql(u8, option, "--page-index");
    const usage_only = std.mem.eql(u8, option, "--usage-only");
    if (args.len == 4 and !emit_page_index and !usage_only) return error.Usage;
    const input_path = args[1];
    const output_root = args[2];
    const lock_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, ".compiler-inputs.lock" });
    // A cache generation is immutable; only a linked working root may be rebuilt.
    const cache_marker = try std.fs.path.join(init.arena.allocator(), &.{ output_root, ".complete.json" });
    if (std.Io.Dir.cwd().access(init.io, cache_marker, .{})) |_| return error.ImmutableExtractionCache else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (usage_only) {
        const receipt = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "extraction-source.json" });
        try std.Io.Dir.cwd().access(init.io, receipt, .{});
    }
    var inputs_lock = if (usage_only) try std.Io.Dir.cwd().openFile(init.io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true, .follow_symlinks = false }) else try std.Io.Dir.cwd().createFile(init.io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer inputs_lock.close(init.io);
    const original_source = try pathIdentity(init.io, input_path);
    const original_redirects = try snapshotHash(init.io, init.arena.allocator(), output_root, "transclusion-redirects.tsv", true);
    var registry = try namespace_registry.Registry.load(init.io, std.heap.smp_allocator, output_root);
    defer registry.deinit();
    if (usage_only) {
        const incomplete = try std.fs.path.join(init.arena.allocator(), &.{ output_root, ".incomplete" });
        if (std.Io.Dir.cwd().access(init.io, incomplete, .{})) |_| return error.IncompleteNativeBuild else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const ready = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "compiler-inputs.ready" });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, ready, init.arena.allocator(), .limited(32));
        if (!std.mem.eql(u8, bytes, "complete\n")) return error.IncompleteExtraction;
        return rebuildUsage(init.io, init.arena.allocator(), input_path, output_root, &registry);
    }
    const old_ready = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "compiler-inputs.ready" });
    std.Io.Dir.cwd().deleteFile(init.io, old_ready) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const compressed = std.mem.endsWith(u8, input_path, ".bz2") or std.mem.endsWith(u8, input_path, ".xml.zst");
    const zstd = std.mem.endsWith(u8, input_path, ".xml.zst");
    const multistream_index_path: ?[]const u8 = if (compressed)
        try wikimedia_dump.deriveMultistreamIndexPath(init.arena.allocator(), input_path)
    else
        null;
    const modules_dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/modules", .{output_root});
    const manifest_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/manifest.jsonl", .{output_root});
    const redirects_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/module-redirects.tsv", .{output_root});
    const page_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/page-index.tsv", .{output_root});
    const stream_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/dump-streams.tsv", .{output_root});
    const title_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ output_root, wikimedia_dump.page_title_index_filename });
    const usage_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/lua-usage.tsv", .{output_root});
    try std.Io.Dir.cwd().createDirPath(init.io, modules_dir);
    const expected_stream_count: ?usize = if (emit_page_index and compressed)
        try writeStreamTable(init.io, init.arena.allocator(), input_path, multistream_index_path.?, stream_index_path)
    else
        null;

    var template_source_writer: ?wikimedia_dump.TemplateSourceWriter = if (emit_page_index)
        try wikimedia_dump.TemplateSourceWriter.init(init.io, init.arena.allocator(), output_root)
    else
        null;
    defer if (template_source_writer) |*writer| writer.deinit();

    var page_index_file: ?std.Io.File = if (emit_page_index)
        try std.Io.Dir.cwd().createFile(init.io, page_index_path, .{ .truncate = true })
    else
        null;
    defer if (page_index_file) |*file| file.close(init.io);
    var page_index_buf: [256 * 1024]u8 = undefined;
    var page_index_writer = if (page_index_file) |*file| file.writer(init.io, &page_index_buf) else null;
    const pw: ?*std.Io.Writer = if (page_index_writer) |*writer| &writer.interface else null;
    if (compressed) if (pw) |writer| {
        if (zstd) try writer.writeAll(wikimedia_dump.page_index_v3_header ++ "\n") else try writer.writeAll(wikimedia_dump.page_index_v2_header ++ "\n");
    };

    var usage_file: ?std.Io.File = if (emit_page_index)
        try std.Io.Dir.cwd().createFile(init.io, usage_path, .{ .truncate = true })
    else
        null;
    defer if (usage_file) |*file| file.close(init.io);
    var usage_buf: [256 * 1024]u8 = undefined;
    var usage_writer = if (usage_file) |*file| file.writer(init.io, &usage_buf) else null;
    const uw: ?*std.Io.Writer = if (usage_writer) |*writer| &writer.interface else null;
    if (uw) |writer| try writer.writeAll("# dict-lua-usage-v1\n");

    var root_template_usage: UsageCountMap = .empty;
    defer root_template_usage.deinit(init.arena.allocator());
    var root_module_usage: UsageCountMap = .empty;
    defer root_module_usage.deinit(init.arena.allocator());
    var dynamic_root_module = false;
    var dynamic_root_template = false;

    var redirects_file = try std.Io.Dir.cwd().createFile(init.io, redirects_path, .{ .truncate = true });
    defer redirects_file.close(init.io);
    var redirects_buf: [64 * 1024]u8 = undefined;
    var redirects_writer = redirects_file.writer(init.io, &redirects_buf);
    const rw = &redirects_writer.interface;

    var manifest_file = try std.Io.Dir.cwd().createFile(init.io, manifest_path, .{ .truncate = true });
    defer manifest_file.close(init.io);
    var manifest_buf: [256 * 1024]u8 = undefined;
    var manifest_writer = manifest_file.writer(init.io, &manifest_buf);
    const mw = &manifest_writer.interface;

    var input = try InputPages.open(init.io, std.heap.smp_allocator, input_path, multistream_index_path);
    var input_open = true;
    defer if (input_open) input.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var pages: usize = 0;
    var modules: usize = 0;
    var redirects: usize = 0;
    var source_bytes: u64 = 0;
    while (try input.next()) |item| {
        const capture = item.capture;
        const page = capture.raw;
        pages += 1;
        const looks_like_module = std.mem.indexOf(u8, page, "<ns>828</ns>") != null;
        if (!emit_page_index and !looks_like_module) continue;

        var decoded_title: ?[]const u8 = null;
        var decoded_redirect: ?[]const u8 = null;
        var indexed_page_id: ?u64 = null;
        var indexed_revision_id: ?u64 = null;

        if (pw != null) {
            const ns_raw = capture.ns_raw orelse {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            const parsed_ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            const title_raw = capture.title_raw orelse {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            const page_id = std.fmt.parseInt(u64, std.mem.trim(u8, capture.page_id_raw orelse return error.InvalidPageMetadata, " \t\r\n"), 10) catch return error.InvalidPageMetadata;
            const revision_id = std.fmt.parseInt(u64, std.mem.trim(u8, capture.revision_id_raw orelse return error.InvalidPageMetadata, " \t\r\n"), 10) catch return error.InvalidPageMetadata;
            const revision_timestamp_raw = capture.revision_timestamp_raw orelse return error.InvalidPageMetadata;
            const model_raw = capture.model_raw orelse return error.InvalidPageMetadata;
            const text_raw = capture.text_raw orelse "";
            const title = try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
            const revision_timestamp = try xml_decode.decodeSinglePassAlloc(arena.allocator(), revision_timestamp_raw);
            const revision_user = try xml_decode.decodeSinglePassAlloc(arena.allocator(), capture.revision_user_raw orelse "");
            const content_model = try xml_decode.decodeSinglePassAlloc(arena.allocator(), model_raw);
            const redirect = if (capture.redirect_raw) |raw| try xml_decode.decodeSinglePassAlloc(arena.allocator(), raw) else null;
            if (std.mem.indexOfAny(u8, title, "\t\r\n") != null) return error.InvalidPageTitle;
            if (redirect) |target| if (std.mem.indexOfAny(u8, target, "\t\r\n") != null) return error.InvalidPageTitle;
            if (content_model.len == 0 or std.mem.indexOfAny(u8, revision_timestamp, "\t\r\n") != null or std.mem.indexOfAny(u8, revision_user, "\t\r\n") != null or std.mem.indexOfAny(u8, content_model, "\t\r\n") != null) return error.InvalidPageMetadata;
            if (pw) |page_writer| try writePageIndexRow(
                page_writer,
                item.source,
                title,
                redirect,
                page_id,
                revision_id,
                revision_timestamp,
                revision_user,
                content_model,
                parsed_ns,
                capture.text_raw != null,
                std.mem.indexOfScalar(u8, text_raw, '&') != null,
            );
            if (parsed_ns == 10 and capture.text_raw != null) {
                if (template_source_writer) |*template_writer|
                    try template_writer.append(@intCast(pages - 1), page_id, revision_id, text_raw);
            }
            decoded_title = title;
            decoded_redirect = redirect;
            indexed_page_id = page_id;
            indexed_revision_id = revision_id;

            const namespace_spec = registry.byId(std.math.cast(i32, parsed_ns) orelse return error.InvalidNamespace) orelse return error.InvalidNamespace;
            if (registry.ofTitle(title).id != namespace_spec.id) return error.NamespaceTitleMismatch;
            if (uw != null and namespace_spec.role != .compile_only and redirect == null and
                std.mem.eql(u8, content_model, "wikitext") and
                (std.mem.indexOfScalar(u8, text_raw, '{') != null or std.mem.indexOfScalar(u8, text_raw, '&') != null))
            {
                const usage_source = if (std.mem.indexOfScalar(u8, text_raw, '&') != null)
                    try xml_decode.decodeSinglePassAlloc(arena.allocator(), text_raw)
                else
                    text_raw;
                var refs: std.ArrayList(lua_usage.Ref) = .empty;
                const scan_flags = try lua_usage.scanWikitextFlags(arena.allocator(), &registry, title, usage_source, &refs);
                dynamic_root_module = dynamic_root_module or scan_flags.dynamic_module_target;
                dynamic_root_template = dynamic_root_template or scan_flags.dynamic_template_target;
                var seen_templates: std.StringHashMapUnmanaged(void) = .empty;
                var seen_modules: std.StringHashMapUnmanaged(void) = .empty;
                for (refs.items) |ref| switch (ref.kind) {
                    .template => {
                        if (seen_templates.contains(ref.target)) continue;
                        try seen_templates.put(arena.allocator(), ref.target, {});
                        try incrementUsageCount(init.arena.allocator(), &root_template_usage, ref.target);
                    },
                    .module => {
                        if (seen_modules.contains(ref.target)) continue;
                        try seen_modules.put(arena.allocator(), ref.target, {});
                        try incrementUsageCount(init.arena.allocator(), &root_module_usage, ref.target);
                    },
                };
            }

            if (parsed_ns != 828) {
                _ = arena.reset(.retain_capacity);
                continue;
            }
        }

        if (capture.redirect_raw) |target_raw| {
            if (capture.title_raw) |title_raw| {
                const title = decoded_title orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
                const target = decoded_redirect orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), target_raw);
                try rw.writeAll("M\t");
                try writeTsvField(rw, title);
                try rw.writeByte('\t');
                try writeTsvField(rw, target);
                try rw.writeByte('\n');
                redirects += 1;
                decoded_title = title;
            }
        }
        const page_id = indexed_page_id orelse blk: {
            const page_id_raw = capture.page_id_raw orelse {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            break :blk std.fmt.parseInt(u64, std.mem.trim(u8, page_id_raw, " \t\r\n"), 10) catch {
                _ = arena.reset(.retain_capacity);
                continue;
            };
        };
        const model_raw = capture.model_raw orelse {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        const model = try xml_decode.decodeSinglePassAlloc(arena.allocator(), model_raw);
        if (!std.mem.eql(u8, model, "Scribunto")) {
            _ = arena.reset(.retain_capacity);
            continue;
        }
        const title_raw = capture.title_raw orelse {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        const text_raw = capture.text_raw orelse {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        const title = decoded_title orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
        const source = try xml_decode.decodeSinglePassAlloc(arena.allocator(), text_raw);
        const revision_id = indexed_revision_id orelse if (capture.revision_id_raw) |raw|
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
            try rw.flush();
            if (pw) |page_writer| try page_writer.flush();
            std.debug.print("modules={d} redirects={d} pages={d} source_bytes={d}\n", .{ modules, redirects, pages, source_bytes });
        }
        _ = arena.reset(.retain_capacity);
    }
    if (expected_stream_count) |expected| {
        const consumed = input.consumedStreamCount() orelse return error.IncompleteMultistreamScan;
        if (consumed != expected) {
            std.debug.print(
                "incomplete multistream scan: consumed={d} expected={d} pages={d} modules={d}\n",
                .{ consumed, expected, pages, modules },
            );
            return error.IncompleteMultistreamScan;
        }
    }
    input.deinit();
    input_open = false;
    try mw.flush();
    try rw.flush();
    if (pw) |page_writer| try page_writer.flush();
    if (template_source_writer) |*template_writer| try template_writer.finish(page_index_path);
    if (emit_page_index) {
        try wikimedia_dump.buildPageTitleIndex(init.io, std.heap.smp_allocator, page_index_path, title_index_path);
        if (uw) |usage_out| {
            const closure = try usage_closure.complete(init.io, std.heap.smp_allocator, &registry, input_path, output_root, &root_template_usage, usage_out);
            dynamic_root_module = dynamic_root_module or closure.retain_all_modules;
            std.debug.print("USAGE_CLOSURE visited={d} source_reads={d} retain_all={}\n", .{ closure.visited_pages, closure.source_reads, closure.retain_all_modules });
        }
    }
    if (uw) |usage_out| {
        try writeUsageCounts(init.arena.allocator(), usage_out, 'R', &root_template_usage);
        try writeUsageCounts(init.arena.allocator(), usage_out, 'P', &root_module_usage);
        if (dynamic_root_module or dynamic_root_template) try writeDynamicUsage(usage_out, "module", null);
        try usage_out.flush();
    }
    // Reachability-sensitive compilation cannot start before closure completes.
    if (emit_page_index) {
        if (!std.meta.eql(original_source, try pathIdentity(init.io, input_path))) return error.ExtractionSourceChanged;
        if (!std.meta.eql(original_redirects, try snapshotHash(init.io, init.arena.allocator(), output_root, "transclusion-redirects.tsv", true))) return error.ExtractionSourceChanged;
        const receipt = try sourceReceipt(init.io, init.arena.allocator(), input_path, output_root, &registry, original_source);
        const receipt_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "extraction-source.json" });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = receipt_path, .data = receipt });
        const ready_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "compiler-inputs.ready" });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready_path, .data = "complete\n" });
    }
    std.debug.print(
        "TOTAL pages={d} modules={d} redirects={d} source_bytes={d} root_templates={d} root_modules={d}\n",
        .{ pages, modules, redirects, source_bytes, root_template_usage.count(), root_module_usage.count() },
    );
}
