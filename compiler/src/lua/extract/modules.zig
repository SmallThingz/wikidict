const std = @import("std");
const namespace_registry = @import("namespace_registry");
const xml_decode = @import("xml_decode");
const usage_closure = @import("usage_closure.zig");
const lua_usage = @import("lua_usage").lua_usage;
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

// Physical bzip2 block boundaries are unrelated to XML page boundaries.
// Keep only the unfinished XML suffix; yielded PageView bytes remain borrowed
// through this iteration, exactly like the existing compressed-member path.
const OriginalXmlPages = struct {
    reader: wikimedia_dump.SourceReader,
    a: std.mem.Allocator,
    carry: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    base: u64 = 0,
    block: usize = 0,
    schema: @FieldType(wikimedia_dump.PageIterator, "size_schema") = .unknown,

    fn deinit(self: *OriginalXmlPages) void {
        self.carry.deinit(self.a);
        self.reader.deinit();
    }

    fn next(self: *OriginalXmlPages) !?PageItem {
        while (true) {
            var pages: wikimedia_dump.PageIterator = .{ .bytes = self.carry.items, .pos = self.cursor, .size_schema = self.schema };
            const capture = pages.next() catch |err| switch (err) {
                error.TruncatedXml => if (self.block == self.reader.original_bzip2.?.blocks.len) return err else null,
                else => return err,
            };
            if (capture) |page| {
                self.cursor = pages.pos;
                self.schema = pages.size_schema;
                const text = page.text_raw orelse "";
                return .{ .capture = page, .source = .{ .raw_xml = .{
                    .offset = if (text.len == 0) 0 else self.base + try sliceOffset(self.carry.items, text), .len = text.len,
                } } };
            }
            if (self.block == self.reader.original_bzip2.?.blocks.len) {
                try self.reader.original_bzip2.?.checkCurrent();
                return null;
            }
            const tail = self.carry.items.len - self.cursor;
            std.mem.copyForwards(u8, self.carry.items[0..tail], self.carry.items[self.cursor..]);
            self.carry.items.len = tail;
            self.base += self.cursor;
            self.cursor = 0;
            const block = self.reader.original_bzip2.?.blocks[self.block];
            self.block += 1;
            const len: usize = @intCast(block.row[2]);
            if (len > 128 * 1024 * 1024 - self.carry.items.len) return error.XmlPageTooLarge;
            const bytes = try self.reader.readAlloc(self.a, .{ .raw_xml = .{ .offset = block.raw_start, .len = len } });
            defer self.a.free(bytes);
            try self.carry.appendSlice(self.a, bytes);
        }
    }
};

const InputPages = union(enum) {
    original: OriginalXmlPages,
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

    fn openOriginal(io: std.Io, allocator: std.mem.Allocator, path: []const u8, directory: []const u8) !InputPages {
        return .{ .original = .{ .a = allocator, .reader = try wikimedia_dump.SourceReader.openOriginalBzip2(io, allocator, allocator, path, directory, .raw_xml, "", null) } };
    }

    fn deinit(self: *InputPages) void {
        switch (self.*) {
            .original => |*original| original.deinit(),
            .raw => |*raw| raw.mapped.deinit(),
            .compressed => |*compressed| compressed.walker.deinit(),
        }
        self.* = undefined;
    }

    fn next(self: *InputPages) !?PageItem {
        switch (self.*) {
            .original => |*original| return original.next(),
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
                    compressed.pages = .{ .bytes = member.bytes, .size_schema = compressed.pages.size_schema };
                }
            },
        }
    }

    fn consumedStreamCount(self: *const InputPages) ?usize {
        return switch (self.*) {
            .raw, .original => null,
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
    revision_size: ?u64,
) !void {
    switch (source) {
        .raw_xml => |loc| try w.print("{d}\t{d}\t", .{ loc.offset, loc.len }),
        .multistream_bz2, .multistream_zstd => |loc| try w.print("{d}\t{d}\t{d}\t", .{ loc.stream_id, loc.offset, loc.len }),
    }
    try w.print("{s}\t{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}", .{
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
    if (revision_size) |size| try w.print("\t{s}\t{d}", .{ wikimedia_dump.revision_size_proof, size });
    try w.writeByte('\n');
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
    return sourceReceiptForTransport(io, a, input, root, registry, expected_source, null);
}
fn sourceReceiptForTransport(io: std.Io, a: std.mem.Allocator, input: []const u8, root: []const u8, registry: *const namespace_registry.Registry, expected_source: ?FileIdentity, transport: ?wikimedia_dump.SourceTransport.Binding) ![]const u8 {
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
    if (transport) |binding| return std.json.Stringify.valueAlloc(a, .{ .version = 3, .source = source, .indexes = identities, .namespace_sha256 = namespace, .redirects_sha256 = try snapshotHash(io, a, root, "transclusion-redirects.tsv", true), .transport = binding }, .{});
    return std.json.Stringify.valueAlloc(a, .{ .version = 2, .source = source, .indexes = identities, .namespace_sha256 = namespace, .redirects_sha256 = try snapshotHash(io, a, root, "transclusion-redirects.tsv", true) }, .{});
}
fn rebuildUsage(io: std.Io, a: std.mem.Allocator, input: []const u8, root: []const u8, registry: *const namespace_registry.Registry) !void {
    const receipt_path = try std.fs.path.join(a, &.{ root, "extraction-source.json" });
    const recorded = try std.Io.Dir.cwd().readFileAlloc(io, receipt_path, a, .limited(16384));
    var transport = try wikimedia_dump.SourceTransport.load(io, a, root, input);
    defer if (transport) |*selected| selected.deinit();
    const binding: ?wikimedia_dump.SourceTransport.Binding = if (transport) |selected| selected.binding else null;
    const before = try sourceReceiptForTransport(io, a, input, root, registry, null, binding);
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
    var reader = try wikimedia_dump.SourceReader.openForRoot(io, std.heap.smp_allocator, std.heap.smp_allocator, root, input, kind, rows.bytes, if (kind == .raw_xml) null else streams_path, .root_receipt);
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
        const spec = try registry.storedPageSpec(page.title, std.math.cast(i32, page.ns) orelse return error.InvalidNamespace);
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
    const after = try sourceReceiptForTransport(io, a, input, root, registry, null, binding);
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
    return extract(.{ .io = init.io, .arena = init.arena }, args);
}

fn extract(init: struct { io: std.Io, arena: *std.heap.ArenaAllocator }, args: []const []const u8) !void {
    if (args.len < 3) return error.Usage;
    var mode: ?[]const u8 = null;
    var source_directory: ?[]const u8 = null;
    var arg: usize = 3;
    while (arg < args.len) : (arg += 1) {
        if (std.mem.eql(u8, args[arg], "--bzip2-source-directory")) {
            arg += 1;
            if (arg >= args.len or source_directory != null or !std.fs.path.isAbsolute(args[arg]) or !std.fs.path.isAbsolute(args[1])) return error.Usage;
            source_directory = args[arg];
        } else if (std.mem.eql(u8, args[arg], "--indexes-only") or std.mem.eql(u8, args[arg], "--page-index") or std.mem.eql(u8, args[arg], "--usage-only")) {
            if (mode != null) return error.Usage;
            mode = args[arg];
        } else return error.Usage;
    }
    const indexes_only = if (mode) |m| std.mem.eql(u8, m, "--indexes-only") else false;
    const emit_page_index = indexes_only or if (mode) |m| std.mem.eql(u8, m, "--page-index") else false;
    const usage_only = if (mode) |m| std.mem.eql(u8, m, "--usage-only") else false;
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
    var fresh_transport: ?wikimedia_dump.SourceTransport.Selected = null;
    defer if (fresh_transport) |*selected| selected.deinit();
    if (!usage_only) {
        if (source_directory) |directory| {
            fresh_transport = try wikimedia_dump.SourceTransport.forFreshExtraction(init.io, init.arena.allocator(), output_root, input_path, directory);
        } else {
            const descriptor = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "source-transport.json" });
            if (std.Io.Dir.cwd().access(init.io, descriptor, .{})) |_| return error.ExplicitSourceTransportRequired else |err| switch (err) { error.FileNotFound => {}, else => return err }
        }
    } else if (source_directory) |directory| {
        var selected = (try wikimedia_dump.SourceTransport.load(init.io, init.arena.allocator(), output_root, input_path)) orelse return error.MissingBzip2SourceTransport;
        defer selected.deinit();
        if (!std.mem.eql(u8, selected.descriptor.value.source_directory, directory)) return error.SourceTransportMismatch;
    }
    const transport_binding: ?wikimedia_dump.SourceTransport.Binding = if (fresh_transport) |selected| selected.binding else null;
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
    const old_completion = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "extraction-completion.json" });
    std.Io.Dir.cwd().deleteFile(init.io, old_completion) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const compressed = source_directory == null and (std.mem.endsWith(u8, input_path, ".bz2") or std.mem.endsWith(u8, input_path, ".xml.zst"));
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
    if (!indexes_only) try std.Io.Dir.cwd().createDirPath(init.io, modules_dir);
    const expected_stream_count: ?usize = if (emit_page_index and compressed)
        try writeStreamTable(init.io, init.arena.allocator(), input_path, multistream_index_path.?, stream_index_path)
    else
        null;

    var template_source_writer: ?wikimedia_dump.TemplateSourceWriter = if (emit_page_index and !indexes_only)
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

    var usage_file: ?std.Io.File = if (emit_page_index and !indexes_only)
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

    var redirects_file: ?std.Io.File = if (indexes_only) null else try std.Io.Dir.cwd().createFile(init.io, redirects_path, .{ .truncate = true });
    defer if (redirects_file) |*file| file.close(init.io);
    var redirects_buf: [64 * 1024]u8 = undefined;
    var redirects_writer = if (redirects_file) |*file| file.writer(init.io, &redirects_buf) else null;
    const rw: ?*std.Io.Writer = if (redirects_writer) |*writer| &writer.interface else null;

    var manifest_file: ?std.Io.File = if (indexes_only) null else try std.Io.Dir.cwd().createFile(init.io, manifest_path, .{ .truncate = true });
    defer if (manifest_file) |*file| file.close(init.io);
    var manifest_buf: [256 * 1024]u8 = undefined;
    var manifest_writer = if (manifest_file) |*file| file.writer(init.io, &manifest_buf) else null;
    const mw: ?*std.Io.Writer = if (manifest_writer) |*writer| &writer.interface else null;

    var input = if (source_directory) |directory| try InputPages.openOriginal(init.io, std.heap.smp_allocator, input_path, directory) else try InputPages.open(init.io, std.heap.smp_allocator, input_path, multistream_index_path);
    var input_open = true;
    defer if (input_open) input.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var pages: usize = 0;
    var modules: usize = 0;
    var redirects: usize = 0;
    var emitted_index_rows: usize = 0;
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
            try writePageIndexRow(
                pw.?,
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
                capture.revision_size,
            );
            emitted_index_rows = try std.math.add(usize, emitted_index_rows, 1);
            if (parsed_ns == 10 and capture.text_raw != null) {
                if (template_source_writer) |*template_writer|
                    try template_writer.append(@intCast(emitted_index_rows - 1), page_id, revision_id, text_raw);
            }
            decoded_title = title;
            decoded_redirect = redirect;
            indexed_page_id = page_id;
            indexed_revision_id = revision_id;

            const namespace_spec = try registry.storedPageSpec(title, std.math.cast(i32, parsed_ns) orelse return error.InvalidNamespace);
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

            if (indexes_only or parsed_ns != 828) {
                _ = arena.reset(.retain_capacity);
                continue;
            }
        }

        if (capture.redirect_raw) |target_raw| {
            if (capture.title_raw) |title_raw| {
                const title = decoded_title orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
                const target = decoded_redirect orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), target_raw);
                try rw.?.writeAll("M\t");
                try writeTsvField(rw.?, title);
                try rw.?.writeByte('\t');
                try writeTsvField(rw.?, target);
                try rw.?.writeByte('\n');
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
        try writeManifestRow(mw.?, page_id, revision_id, title, model, format, source);

        modules += 1;
        source_bytes += source.len;
        if (modules % 1000 == 0) {
            try mw.?.flush();
            try rw.?.flush();
            if (pw) |page_writer| try page_writer.flush();
            std.debug.print("modules={d} redirects={d} pages={d} source_bytes={d}\n", .{ modules, redirects, pages, source_bytes });
        }
        _ = arena.reset(.retain_capacity);
    }
    var completed_stream_count: ?usize = null;
    if (expected_stream_count) |expected| {
        const consumed = input.consumedStreamCount() orelse return error.IncompleteMultistreamScan;
        if (consumed != expected) {
            std.debug.print(
                "incomplete multistream scan: consumed={d} expected={d} pages={d} modules={d}\n",
                .{ consumed, expected, pages, modules },
            );
            return error.IncompleteMultistreamScan;
        }
        completed_stream_count = consumed;
    }
    input.deinit();
    input_open = false;
    if (mw) |writer| try writer.flush();
    if (rw) |writer| try writer.flush();
    if (pw) |page_writer| try page_writer.flush();
    if (template_source_writer) |*template_writer| try template_writer.finish(page_index_path);
    if (emit_page_index) {
        std.debug.print("PAGE_TITLE_INDEX start pages={d}\n", .{pages});
        const title_index_started_ns = std.Io.Clock.awake.now(init.io).toNanoseconds();
        try wikimedia_dump.buildPageTitleIndexCounted(init.io, std.heap.smp_allocator, page_index_path, title_index_path, emitted_index_rows);
        const title_index_elapsed_ms = @divTrunc(std.Io.Clock.awake.now(init.io).toNanoseconds() - title_index_started_ns, std.time.ns_per_ms);
        std.debug.print("PAGE_TITLE_INDEX complete pages={d} elapsed_ms={d}\n", .{ pages, title_index_elapsed_ms });
        if (transport_binding) |binding| {
            // Required by query-local usage reads, but not a completed cache or
            // ready generation; publication still follows the final checks.
            const provisional = try sourceReceiptForTransport(init.io, init.arena.allocator(), input_path, output_root, &registry, original_source, binding);
            const receipt_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "extraction-source.json" });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = receipt_path, .data = provisional });
        }
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
        const receipt = try sourceReceiptForTransport(init.io, init.arena.allocator(), input_path, output_root, &registry, original_source, transport_binding);
        const receipt_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "extraction-source.json" });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = receipt_path, .data = receipt });
        if (completed_stream_count) |consumed| {
            // The last member can contain only the XML footer, without a page.
            // Persist the already verified complete scan, rather than inferring
            // completion from the stream that happened to own the final page.
            const completion = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
                .schema = "wikidict.extraction-completion.v1",
                .version = 1,
                .expected_stream_count = expected_stream_count.?,
                .consumed_stream_count = consumed,
                .pages = pages,
            }, .{});
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = old_completion, .data = completion });
        }
        // Index completeness does not establish module/template usage closure.
        if (!indexes_only) {
            const ready_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "compiler-inputs.ready" });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready_path, .data = "complete\n" });
        }
    }
    std.debug.print(
        "TOTAL pages={d} modules={d} redirects={d} source_bytes={d} root_templates={d} root_modules={d}\n",
        .{ pages, modules, redirects, source_bytes, root_template_usage.count(), root_module_usage.count() },
    );
}

test "compressed extraction consumes footer-only member and rejects truncated footer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Codec = struct {
        extern fn ZSTD_compress(dst: [*]u8, capacity: usize, src: [*]const u8, len: usize, level: c_int) usize;
        extern fn ZSTD_isError(code: usize) c_uint;
        extern fn BZ2_bzBuffToBuffCompress(dst: [*]u8, len: *c_uint, src: [*]const u8, source_len: c_uint, block_size: c_int, verbosity: c_int, work_factor: c_int) c_int;
    };
    const page_xml = "<mediawiki><page><title>ET final</title><ns>0</ns><id>7</id><revision><id>70</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>wikitext</model><text>exact&amp;body</text></revision></page>";
    const footer = "\n</mediawiki>";
    var first_buffer: [1024]u8 = undefined;
    var footer_buffer: [128]u8 = undefined;
    const first_len = Codec.ZSTD_compress(&first_buffer, first_buffer.len, page_xml.ptr, page_xml.len, 1);
    const footer_len = Codec.ZSTD_compress(&footer_buffer, footer_buffer.len, footer.ptr, footer.len, 1);
    try std.testing.expectEqual(@as(c_uint, 0), Codec.ZSTD_isError(first_len));
    try std.testing.expectEqual(@as(c_uint, 0), Codec.ZSTD_isError(footer_len));
    const frames = try std.mem.concat(a, u8, &.{ first_buffer[0..first_len], footer_buffer[0..footer_len] });
    defer a.free(frames);
    const offsets = try std.fmt.allocPrint(a, "0:7:ET final\n{d}:0:footer\n", .{first_len});
    defer a.free(offsets);
    var index_buffer: [1024]u8 = undefined;
    var index_len: c_uint = index_buffer.len;
    try std.testing.expectEqual(@as(c_int, 0), Codec.BZ2_bzBuffToBuffCompress(&index_buffer, &index_len, offsets.ptr, @intCast(offsets.len), 1, 0, 30));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    defer a.free(root);
    const input_path = try std.fs.path.join(a, &.{ root, "tiny.xml.zst" });
    defer a.free(input_path);
    const index_path = try std.fs.path.join(a, &.{ root, "offsets.txt.bz2" });
    defer a.free(index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = frames });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_buffer[0..index_len] });
    {
        var input = try InputPages.open(io, a, input_path, index_path);
        defer input.deinit();
        const page = (try input.next()).?;
        try std.testing.expectEqualStrings("ET final", page.capture.title_raw.?);
        try std.testing.expectEqualStrings("0", page.capture.ns_raw.?);
        try std.testing.expectEqualStrings("7", page.capture.page_id_raw.?);
        try std.testing.expectEqualStrings("70", page.capture.revision_id_raw.?);
        try std.testing.expectEqualStrings("2026-10-01T00:00:00Z", page.capture.revision_timestamp_raw.?);
        try std.testing.expectEqualStrings("exact&amp;body", page.capture.text_raw.?);
        const decoded = try xml_decode.decodeSinglePassAlloc(a, page.capture.text_raw.?);
        defer a.free(decoded);
        try std.testing.expectEqualStrings("exact&body", decoded);
        const location = page.source.multistream_zstd;
        try std.testing.expectEqual(@as(u32, 0), location.stream_id);
        try std.testing.expectEqual(std.mem.indexOf(u8, page_xml, "exact&amp;body").?, location.offset);
        try std.testing.expectEqual("exact&amp;body".len, location.len);
        try std.testing.expectEqual(@as(?usize, 1), input.consumedStreamCount());
        try std.testing.expect((try input.next()) == null);
        try std.testing.expectEqual(@as(?usize, 2), input.consumedStreamCount());
    }
    // The final page is available even when the later footer frame is corrupt;
    // only scanning through EOF proves that extraction consumed the dump.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = frames[0 .. frames.len - 1] });
    var truncated = try InputPages.open(io, a, input_path, index_path);
    defer truncated.deinit();
    try std.testing.expect((try truncated.next()) != null);
    try std.testing.expectError(error.InvalidZstdMember, truncated.next());
}


test "ordinary compressed extraction carries size schema across members into the existing page index" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Codec = struct {
        extern fn ZSTD_compress(dst: [*]u8, capacity: usize, src: [*]const u8, len: usize, level: c_int) usize;
        extern fn ZSTD_isError(code: usize) c_uint;
        extern fn BZ2_bzBuffToBuffCompress(dst: [*]u8, len: *c_uint, src: [*]const u8, source_len: c_uint, block_size: c_int, verbosity: c_int, work_factor: c_int) c_int;
    };
    const header = "<mediawiki xmlns=\"http://www.mediawiki.org/xml/export-0.11/\" version=\"0.11\">";
    const page = "<page><title>Page</title><ns>0</ns><id>7</id><revision><id>70</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>wikitext</model><format>text/x-wiki</format><text bytes=\"3\" xml:space=\"preserve\">é&amp;</text></revision></page>";
    const third = "</mediawiki><mediawiki version=\"0.10\">" ++ page ++ "</mediawiki>";
    var frames: std.Io.Writer.Allocating = .init(a); defer frames.deinit();
    var offsets: std.Io.Writer.Allocating = .init(a); defer offsets.deinit();
    for ([_][]const u8{ header, page, third }, 0..) |raw, i| {
        var buffer: [2048]u8 = undefined;
        const len = Codec.ZSTD_compress(&buffer, buffer.len, raw.ptr, raw.len, 1);
        try std.testing.expectEqual(@as(c_uint, 0), Codec.ZSTD_isError(len));
        try offsets.writer.print("{d}:{d}:member\n", .{ frames.written().len, i + 1 });
        try frames.writer.writeAll(buffer[0..len]);
    }
    var index_buffer: [2048]u8 = undefined;
    var index_len: c_uint = index_buffer.len;
    const offset_bytes = offsets.written();
    try std.testing.expectEqual(@as(c_int, 0), Codec.BZ2_bzBuffToBuffCompress(&index_buffer, &index_len, offset_bytes.ptr, @intCast(offset_bytes.len), 1, 0, 30));
    var temp = std.testing.tmpDir(.{}); defer temp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path}); defer a.free(root);
    const input_path = try std.fs.path.join(a, &.{ root, "size.xml.zst" }); defer a.free(input_path);
    const index_path = try std.fs.path.join(a, &.{ root, "offsets.txt.bz2" }); defer a.free(index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = frames.written() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_buffer[0..index_len] });
    var input = try InputPages.open(io, a, input_path, index_path); defer input.deinit();
    const first = (try input.next()).?;
    try std.testing.expectEqual(@as(?u64, 3), first.capture.revision_size);
    try std.testing.expectEqualStrings("é&amp;", first.capture.text_raw.?);
    var row: std.Io.Writer.Allocating = .init(a); defer row.deinit();
    try writePageIndexRow(&row.writer, first.source, "Page", null, 7, 70, "2026-10-01T00:00:00Z", "", "wikitext", 0, true, true, first.capture.revision_size);
    var short_buffer: [8]u8 = undefined;
    var short = std.Io.Writer.fixed(&short_buffer);
    try std.testing.expectError(error.WriteFailed, writePageIndexRow(&short, first.source, "Page", null, 7, 70, "2026-10-01T00:00:00Z", "", "wikitext", 0, true, true, first.capture.revision_size));
    const written = row.written();
    const indexed = try wikimedia_dump.parsePageIndexLine(.multistream_zstd, written[0 .. written.len - 1]);
    try std.testing.expectEqual(@as(?u64, 3), indexed.revision_size);
    try std.testing.expectEqual(@as(u64, 7), indexed.page_id);
    try std.testing.expectEqual(@as(u64, 70), indexed.revision_id);
    try std.testing.expectEqualStrings("Page", indexed.title);
    const second = (try input.next()).?;
    try std.testing.expectEqual(@as(?u64, null), second.capture.revision_size);
    try std.testing.expect((try input.next()) == null);
}

const IndexesOnlyFixture = struct {
    const page = "<page><title>word</title><ns>0</ns><id>1</id><revision><id>11</id><timestamp>2026-10-01T00:00:00Z</timestamp><contributor><username>Editor</username></contributor><model>wikitext</model><text>body&amp;link</text></revision></page>";
    const template = "<page><title>Template:Probe</title><ns>10</ns><id>2</id><revision><id>22</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>wikitext</model><text>template body</text></revision></page>";
    const module = "<page><title>Module:Probe</title><ns>828</ns><id>3</id><revision><id>33</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>Scribunto</model><text>return {}</text></revision></page>";
    const redirect = "<page><title>Module:Alias</title><ns>828</ns><id>4</id><redirect title=\"Module:Probe\"/><revision><id>44</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>wikitext</model><text>#REDIRECT [[Module:Probe]]</text></revision></page>";
    const duplicate = "<page><title>word</title><ns>0</ns><id>5</id><revision><id>55</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>wikitext</model><text>last duplicate</text></revision></page>";
    // Extraction sees this page but emits no index row for its invalid namespace.
    const filtered = "<page><title>skip</title><ns>x</ns><id>6</id><revision><id>66</id><timestamp>2026-10-01T00:00:00Z</timestamp><model>wikitext</model><text>ignored</text></revision></page>";
    const first = "<mediawiki>" ++ page ++ filtered ++ template ++ module;
    const second = redirect ++ duplicate;
    const footer = "\n</mediawiki>";
    const xml = first ++ second ++ footer;
    const preserved = [_][]const u8{ "manifest.jsonl", "module-redirects.tsv", "modules/3.lua", "template-source.bin", "template-source.idx", "lua-usage.tsv" };

    fn root(a: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(a, &.{parent, name});
        try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
        try writeAllFile(std.testing.io, try std.fs.path.join(a, &.{path, "namespace-registry.tsv"}), namespace_registry.english_test_fixture);
        return path;
    }
    fn read(a: std.mem.Allocator, root_path: []const u8, name: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{root_path, name}), a, .limited(1024 * 1024));
    }
    fn absent(a: std.mem.Allocator, root_path: []const u8, name: []const u8) !void {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, try std.fs.path.join(a, &.{root_path, name}), .{}));
    }
    fn run(arena: *std.heap.ArenaAllocator, dump: []const u8, root_path: []const u8, option: []const u8) !void {
        try extract(.{ .io = std.testing.io, .arena = arena }, &.{"dict-module-extract", dump, root_path, option});
    }
    fn compressed(a: std.mem.Allocator, parent: []const u8, truncated: bool) ![]const u8 {
        const Codec = struct {
            extern fn ZSTD_compress(dst: [*]u8, capacity: usize, src: [*]const u8, len: usize, level: c_int) usize;
            extern fn ZSTD_isError(code: usize) c_uint;
            extern fn BZ2_bzBuffToBuffCompress(dst: [*]u8, len: *c_uint, src: [*]const u8, source_len: c_uint, block_size: c_int, verbosity: c_int, work_factor: c_int) c_int;
        };
        var frames: std.Io.Writer.Allocating = .init(a); defer frames.deinit();
        var offsets: std.Io.Writer.Allocating = .init(a); defer offsets.deinit();
        for ([_][]const u8{first, second, footer}, 0..) |part, i| {
            var buffer: [4096]u8 = undefined;
            const len = Codec.ZSTD_compress(&buffer, buffer.len, part.ptr, part.len, 1);
            try std.testing.expectEqual(@as(c_uint, 0), Codec.ZSTD_isError(len));
            try offsets.writer.print("{d}:{d}:member\n", .{frames.written().len, i + 1});
            try frames.writer.writeAll(buffer[0..len]);
        }
        var index_buffer: [4096]u8 = undefined; var index_len: c_uint = index_buffer.len;
        const raw_offsets = offsets.written();
        try std.testing.expectEqual(@as(c_int, 0), Codec.BZ2_bzBuffToBuffCompress(&index_buffer, &index_len, raw_offsets.ptr, @intCast(raw_offsets.len), 1, 0, 30));
        const dump = try std.fs.path.join(a, &.{parent, "indexes.xml.zst"});
        try writeAllFile(std.testing.io, dump, frames.written()[0 .. frames.written().len - @intFromBool(truncated)]);
        try writeAllFile(std.testing.io, try wikimedia_dump.deriveMultistreamIndexPath(a, dump), index_buffer[0..index_len]);
        return dump;
    }
    fn indexes(a: std.mem.Allocator, dump: []const u8, root_path: []const u8, kind: wikimedia_dump.PageIndexKind) !void {
        const bytes = try read(a, root_path, "page-index.tsv");
        const title_bytes = try read(a, root_path, "page-title-index.bin");
        const titles = try wikimedia_dump.PageTitleIndex.init(title_bytes);
        try std.testing.expectEqual(@as(usize, 5), titles.row_count);
        try std.testing.expectEqual(@as(usize, 4), titles.unique_count);
        const streams = if (wikimedia_dump.isMultistream(kind)) try std.fs.path.join(a, &.{root_path, "dump-streams.tsv"}) else null;
        var reader = try wikimedia_dump.SourceReader.open(std.testing.io, a, std.testing.allocator, dump, kind, streams); defer reader.deinit();
        const expected = [_][]const u8{ "body&amp;link", "template body", "return {}", "#REDIRECT [[Module:Probe]]", "last duplicate" };
        var lines = std.mem.splitScalar(u8, bytes, '\n'); var ordinal: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const row = try wikimedia_dump.parsePageIndexLine(kind, line);
            try std.testing.expectEqual(@as(u64, @intCast(ordinal + 1)), row.page_id);
            try std.testing.expectEqual(@as(u64, @intCast((ordinal + 1) * 11)), row.revision_id);
            try std.testing.expectEqualStrings(expected[ordinal], try reader.readAlloc(a, row.source));
            if (ordinal == 3) try std.testing.expectEqualStrings("Module:Probe", row.redirect.?);
            ordinal += 1;
        }
        try std.testing.expectEqual(expected.len, ordinal);
        const chosen = (try titles.lookup(bytes, "word")) orelse return error.TestUnexpectedResult;
        const offset = wikimedia_dump.pageRowRefOffset(chosen);
        const end = std.mem.indexOfScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
        const row = try wikimedia_dump.parsePageIndexLine(kind, bytes[offset..end]);
        try std.testing.expectEqual(@as(u64, 5), row.page_id);
        try std.testing.expectEqual(@as(usize, 4), wikimedia_dump.pageRowRefOrdinal(chosen));
    }
};

test "indexes-only preserves complete ordinary indexes and retained module template usage assets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var temp = std.testing.tmpDir(.{}); defer temp.cleanup();
    const parent = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    const dump = try std.fs.path.join(a, &.{parent, "tiny.xml"}); try writeAllFile(std.testing.io, dump, IndexesOnlyFixture.xml);
    const full = try IndexesOnlyFixture.root(a, parent, "full");
    const only = try IndexesOnlyFixture.root(a, parent, "indexes");
    try IndexesOnlyFixture.run(&arena, dump, full, "--page-index");
    var prior: [IndexesOnlyFixture.preserved.len][]const u8 = undefined;
    for (IndexesOnlyFixture.preserved, 0..) |name, i| prior[i] = try IndexesOnlyFixture.read(a, full, name);
    const page_before = try IndexesOnlyFixture.read(a, full, "page-index.tsv");
    const title_before = try IndexesOnlyFixture.read(a, full, "page-title-index.bin");
    const title_index = try wikimedia_dump.PageTitleIndex.init(title_before);
    const template_ref = (try title_index.lookup(page_before, "Template:Probe")) orelse return error.TestUnexpectedResult;
    const ordinal = wikimedia_dump.pageRowRefOrdinal(template_ref);
    try std.testing.expectEqual(@as(usize, 1), ordinal);
    var templates = (try wikimedia_dump.TemplateSource.open(std.testing.io, a, full, page_before)) orelse return error.TestUnexpectedResult;
    defer templates.deinit();
    try std.testing.expectEqualStrings("template body", (try templates.lookup(@intCast(ordinal), 2, 22)) orelse return error.TestUnexpectedResult);
    try IndexesOnlyFixture.run(&arena, dump, only, "--indexes-only");
    try std.testing.expectEqualStrings(page_before, try IndexesOnlyFixture.read(a, only, "page-index.tsv"));
    try std.testing.expectEqualSlices(u8, title_before, try IndexesOnlyFixture.read(a, only, "page-title-index.bin"));
    try IndexesOnlyFixture.indexes(a, dump, only, .raw_xml);
    for (IndexesOnlyFixture.preserved) |name| try IndexesOnlyFixture.absent(a, only, name);
    try IndexesOnlyFixture.absent(a, only, "modules");
    try IndexesOnlyFixture.absent(a, only, "compiler-inputs.ready");
    try IndexesOnlyFixture.run(&arena, dump, full, "--indexes-only");
    for (IndexesOnlyFixture.preserved, 0..) |name, i| try std.testing.expectEqualSlices(u8, prior[i], try IndexesOnlyFixture.read(a, full, name));
    try std.testing.expectEqualStrings(page_before, try IndexesOnlyFixture.read(a, full, "page-index.tsv"));
    try std.testing.expectEqualSlices(u8, title_before, try IndexesOnlyFixture.read(a, full, "page-title-index.bin"));
    try IndexesOnlyFixture.absent(a, full, "compiler-inputs.ready");
    var ns = try namespace_registry.Registry.load(std.testing.io, a, only); defer ns.deinit();
    try std.testing.expectEqualStrings(try sourceReceipt(std.testing.io, a, dump, only, &ns, try pathIdentity(std.testing.io, dump)), try IndexesOnlyFixture.read(a, only, "extraction-source.json"));
}

test "indexes-only verifies complete compressed stream and footer with ordinary row identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var temp = std.testing.tmpDir(.{}); defer temp.cleanup();
    const parent = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    const dump = try IndexesOnlyFixture.compressed(a, parent, false);
    const full = try IndexesOnlyFixture.root(a, parent, "full");
    const only = try IndexesOnlyFixture.root(a, parent, "indexes");
    try IndexesOnlyFixture.run(&arena, dump, full, "--page-index");
    try IndexesOnlyFixture.run(&arena, dump, only, "--indexes-only");
    for ([_][]const u8{ "page-index.tsv", "page-title-index.bin", "dump-streams.tsv", "extraction-completion.json" }) |name|
        try std.testing.expectEqualSlices(u8, try IndexesOnlyFixture.read(a, full, name), try IndexesOnlyFixture.read(a, only, name));
    try IndexesOnlyFixture.indexes(a, dump, only, .multistream_zstd);
    const completion = try std.json.parseFromSliceLeaky(struct { schema: []const u8, version: u32, expected_stream_count: usize, consumed_stream_count: usize, pages: usize }, a, try IndexesOnlyFixture.read(a, only, "extraction-completion.json"), .{});
    try std.testing.expectEqual(@as(usize, 3), completion.expected_stream_count);
    try std.testing.expectEqual(@as(usize, 3), completion.consumed_stream_count);
    try std.testing.expectEqual(@as(usize, 6), completion.pages);
    try IndexesOnlyFixture.absent(a, only, "compiler-inputs.ready");
}

test "indexes-only keeps truncation refusal and immutable option boundaries without full readiness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var temp = std.testing.tmpDir(.{}); defer temp.cleanup();
    const parent = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    const dump = try IndexesOnlyFixture.compressed(a, parent, true);
    const root = try IndexesOnlyFixture.root(a, parent, "indexes");
    try writeAllFile(std.testing.io, try std.fs.path.join(a, &.{root, "compiler-inputs.ready"}), "complete\n");
    try writeAllFile(std.testing.io, try std.fs.path.join(a, &.{root, "extraction-completion.json"}), "old receipt");
    try std.testing.expectError(error.InvalidZstdMember, IndexesOnlyFixture.run(&arena, dump, root, "--indexes-only"));
    for ([_][]const u8{ "compiler-inputs.ready", "extraction-completion.json", "extraction-source.json", "page-title-index.bin", "manifest.jsonl", "modules" }) |name| try IndexesOnlyFixture.absent(a, root, name);
    try std.testing.expectError(error.Usage, extract(.{ .io = std.testing.io, .arena = &arena }, &.{"extract", dump, root, "--indexes-only", "--page-index"}));
    try std.testing.expectError(error.Usage, IndexesOnlyFixture.run(&arena, dump, root, "--unknown"));
    try writeAllFile(std.testing.io, try std.fs.path.join(a, &.{root, ".complete.json"}), "immutable witness");
    try std.testing.expectError(error.ImmutableExtractionCache, IndexesOnlyFixture.run(&arena, dump, root, "--indexes-only"));
    try std.testing.expectEqualStrings("immutable witness", try IndexesOnlyFixture.read(a, root, ".complete.json"));
}


test "fresh original bzip2 extraction carries complete XML into new raw indexes and v3 receipt" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "part-a.bz2", .data = wikimedia_dump.OriginalBzipTestData.part_a });
    try tmp.dir.writeFile(io, .{ .sub_path = "part-b.bz2", .data = wikimedia_dump.OriginalBzipTestData.part_b });
    try tmp.dir.writeFile(io, .{ .sub_path = "blocks.json", .data = wikimedia_dump.OriginalBzipTestData.directory });
    var root_buffer: [4096]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const directory = try std.fs.path.join(a, &.{ root, "blocks.json" });
    {
        var input = try InputPages.openOriginal(io, std.testing.allocator, directory, root);
        defer input.deinit();
        const first_part_bytes = input.original.reader.original_bzip2.?.parsed.value.parts[0].xml_bytes;
        const first = (try input.next()).?;
        try std.testing.expectEqualStrings("first", first.capture.title_raw.?);
        try std.testing.expectEqual(@as(usize, 216000), first.capture.text_raw.?.len);
        try std.testing.expectEqual(@as(?u64, 216000), first.capture.revision_size);
        const second = (try input.next()).?;
        try std.testing.expectEqualStrings("second", second.capture.title_raw.?);
        try std.testing.expectEqualStrings("tail", second.capture.text_raw.?);
        try std.testing.expectEqual(@as(?u64, 4), second.capture.revision_size);
        try std.testing.expect(second.source.raw_xml.offset > first_part_bytes);
        try std.testing.expect((try input.next()) == null);
    }
    const output = try IndexesOnlyFixture.root(a, root, "output");
    const descriptor = try std.json.Stringify.valueAlloc(a, .{
        .format = "wikidict-source-transport-v1", .transport = "bzip2-blocks",
        .block_directory = directory, .source_directory = root,
    }, .{});
    try writeAllFile(io, try std.fs.path.join(a, &.{ output, "source-transport.json" }), descriptor);
    try extract(.{ .io = io, .arena = &arena }, &.{ "dict-module-extract", directory, output, "--page-index", "--bzip2-source-directory", root });
    const rows = try IndexesOnlyFixture.read(a, output, "page-index.tsv");
    try std.testing.expectEqual(wikimedia_dump.PageIndexKind.raw_xml, wikimedia_dump.pageIndexKind(rows));
    var lines = std.mem.splitScalar(u8, rows, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const page = try wikimedia_dump.parsePageIndexLine(.raw_xml, line);
        if (count == 0) try std.testing.expectEqualStrings("first", page.title) else try std.testing.expectEqualStrings("second", page.title);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    const receipt_bytes = try IndexesOnlyFixture.read(a, output, "extraction-source.json");
    const receipt = try std.json.parseFromSlice(struct { version: u32, transport: wikimedia_dump.SourceTransport.Binding }, a, receipt_bytes, .{ .ignore_unknown_fields = true });
    defer receipt.deinit();
    try std.testing.expectEqual(@as(u32, 3), receipt.value.version);
    try std.testing.expectEqualStrings("bzip2-blocks", receipt.value.transport.kind);
    var selected = (try wikimedia_dump.SourceTransport.load(io, a, output, directory)) orelse return error.TestUnexpectedResult;
    defer selected.deinit();
    try std.testing.expectEqualSlices(u8, &selected.binding.descriptor_sha256, &receipt.value.transport.descriptor_sha256);
    try std.testing.expectEqualSlices(u8, &selected.binding.block_directory_sha256, &receipt.value.transport.block_directory_sha256);
    try std.testing.expectEqualStrings("complete\n", try IndexesOnlyFixture.read(a, output, "compiler-inputs.ready"));
    // The ordinary usage-only path selects the same authenticated transport.
    try extract(.{ .io = io, .arena = &arena }, &.{ "dict-module-extract", directory, output, "--usage-only" });
    try std.testing.expectEqualStrings(receipt_bytes, try IndexesOnlyFixture.read(a, output, "extraction-source.json"));
}
