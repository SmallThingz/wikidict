//! Demand-driven transclusion graph. Unreferenced pages require no second scan.
const std = @import("std");
const dump = @import("wikimedia_dump");
const usage = @import("lua_usage");
const xml = @import("xml_decode");
const Registry = @import("namespace_registry").Registry;
const A = std.mem.Allocator;
const max_visited_pages = 1_000_000;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn open(io: std.Io, path: []const u8) !Mapped {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(io);
        const size = std.math.cast(usize, (try file.stat(io)).size) orelse return error.FileTooBig;
        if (size == 0) return .{ .bytes = &.{} };
        return .{ .bytes = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
    }
    fn deinit(self: Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
    }
};

fn field(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
}
fn edge(w: *std.Io.Writer, kind: u8, source: []const u8, target: []const u8) !void {
    try w.writeByte(kind);
    try w.writeByte('\t');
    try field(w, source);
    try w.writeByte('\t');
    try field(w, target);
    try w.writeByte('\n');
}

pub const Result = struct { visited_pages: usize = 0, source_reads: usize = 0, retain_all_modules: bool = false };
const Closure = struct {
    a: A,
    registry: *const Registry,
    index: dump.PageTitleIndex,
    rows: []const u8,
    writer: *std.Io.Writer,
    overrides: std.StringHashMapUnmanaged([]const u8) = .empty,
    visited: std.DynamicBitSetUnmanaged,
    queue: std.ArrayList(u64) = .empty,
    result: Result = .{},

    fn enqueue(self: *Closure, scratch: A, requested: []const u8) !void {
        var title: []const u8 = try self.registry.normalizeTitle(scratch, requested, 0, .any);
        var redirects: usize = 0;
        while (self.overrides.get(title)) |target| {
            try edge(self.writer, 'T', title, target);
            title = target;
            redirects += 1;
            if (redirects > 32) return; // Runtime diagnoses the same redirect loop.
        }
        const ref = (try self.index.lookup(self.rows, title)) orelse return;
        const ordinal = dump.pageRowRefOrdinal(ref);
        if (ordinal >= self.index.row_count) return error.InvalidPageIndex;
        if (self.visited.isSet(ordinal)) return;
        if (self.queue.items.len >= max_visited_pages) {
            self.result.retain_all_modules = true;
            return;
        }
        self.visited.set(ordinal);
        try self.queue.append(self.a, ref);
    }
};

pub fn complete(io: std.Io, a: A, registry: *const Registry, dump_path: []const u8, root: []const u8, roots: *const std.StringHashMapUnmanaged(u64), writer: *std.Io.Writer) !Result {
    var lifetime = std.heap.ArenaAllocator.init(a);
    defer lifetime.deinit();
    const persistent = lifetime.allocator();
    const rows_path = try std.fs.path.join(persistent, &.{ root, "page-index.tsv" });
    const index_path = try std.fs.path.join(persistent, &.{ root, dump.page_title_index_filename });
    const rows = try Mapped.open(io, rows_path);
    defer rows.deinit();
    const mapped_index = try Mapped.open(io, index_path);
    defer mapped_index.deinit();
    const index = try dump.PageTitleIndex.init(mapped_index.bytes);
    if (index.page_index_size != rows.bytes.len or index.kind != dump.pageIndexKind(rows.bytes)) return error.InvalidPageTitleIndex;
    const streams_path = try std.fs.path.join(persistent, &.{ root, "dump-streams.tsv" });
    var reader = try dump.SourceReader.open(io, a, std.heap.smp_allocator, dump_path, index.kind, if (index.kind == .raw_xml) null else streams_path);
    defer reader.deinit();
    var closure: Closure = .{ .a = a, .registry = registry, .index = index, .rows = rows.bytes, .writer = writer, .visited = try .initEmpty(a, index.row_count) };
    defer closure.visited.deinit(a);
    defer closure.queue.deinit(a);
    defer closure.overrides.deinit(a);
    const overrides_path = try std.fs.path.join(persistent, &.{ root, "transclusion-redirects.tsv" });
    const overrides = std.Io.Dir.cwd().readFileAlloc(io, overrides_path, persistent, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, overrides, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidTransclusionRedirectSnapshot;
        if (tab == 0 or tab + 1 == line.len or std.mem.indexOfScalar(u8, line[tab + 1 ..], '\t') != null) return error.InvalidTransclusionRedirectSnapshot;
        const from = try registry.normalizeTitle(persistent, line[0..tab], 0, .any);
        const to = try registry.normalizeTitle(persistent, line[tab + 1 ..], 0, .any);
        const slot = try closure.overrides.getOrPut(a, from);
        if (slot.found_existing) return error.DuplicateTransclusionRedirect;
        slot.value_ptr.* = to;
    }
    const sorted = try a.alloc([]const u8, roots.count());
    defer a.free(sorted);
    var it = roots.keyIterator();
    var pos: usize = 0;
    while (it.next()) |key| : (pos += 1) sorted[pos] = key.*;
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.less);
    var scratch_arena = std.heap.ArenaAllocator.init(a);
    defer scratch_arena.deinit();
    for (sorted) |title| {
        try closure.enqueue(scratch_arena.allocator(), title);
        _ = scratch_arena.reset(.retain_capacity);
    }
    pos = 0;
    while (pos < closure.queue.items.len) : (pos += 1) {
        const scratch = scratch_arena.allocator();
        defer _ = scratch_arena.reset(.retain_capacity);
        const offset = dump.pageRowRefOffset(closure.queue.items[pos]);
        if (offset >= rows.bytes.len) return error.InvalidPageIndex;
        const end = std.mem.indexOfScalarPos(u8, rows.bytes, offset, '\n') orelse rows.bytes.len;
        const page = try dump.parsePageIndexLine(index.kind, rows.bytes[offset..end]);
        closure.result.visited_pages += 1;
        if (page.redirect) |raw| {
            const target = try registry.normalizeTitle(scratch, raw, 0, .any);
            try edge(writer, 'T', page.title, target);
            try closure.enqueue(scratch, target);
            continue;
        }
        if (!page.has_source) continue;
        const raw = try reader.readAlloc(scratch, page.source);
        closure.result.source_reads += 1;
        const source = if (page.source_needs_decode) try xml.decodeSinglePassAlloc(scratch, raw) else raw;
        var refs: std.ArrayList(usage.Ref) = .empty;
        const flags = try usage.scanTemplateWikitextFlags(scratch, registry, page.title, source, &refs);
        closure.result.retain_all_modules = closure.result.retain_all_modules or flags.dynamic_module_target or flags.dynamic_template_target;
        var seen_templates: std.StringHashMapUnmanaged(void) = .empty;
        var seen_modules: std.StringHashMapUnmanaged(void) = .empty;
        for (refs.items) |ref| switch (ref.kind) {
            .template => {
                if (seen_templates.contains(ref.target)) continue;
                try seen_templates.put(scratch, ref.target, {});
                try edge(writer, 'T', page.title, ref.target);
                try closure.enqueue(scratch, ref.target);
            },
            .module => {
                if (seen_modules.contains(ref.target)) continue;
                try seen_modules.put(scratch, ref.target, {});
                try edge(writer, 'I', page.title, ref.target);
            },
        };
    }
    return closure.result;
}

test "sparse closure crosses namespaces and scans only reached transclusion views" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    defer a.free(root);
    const source_path = try std.fs.path.join(a, &.{ root, "source.xml" });
    defer a.free(source_path);
    const rows_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(rows_path);
    const index_path = try std.fs.path.join(a, &.{ root, dump.page_title_index_filename });
    defer a.free(index_path);
    var sources: std.Io.Writer.Allocating = .init(a);
    defer sources.deinit();
    var rows: std.Io.Writer.Allocating = .init(a);
    defer rows.deinit();
    const Page = struct { title: []const u8, body: []const u8, redirect: []const u8 = "", ns: u32 };
    const pages = [_]Page{
        .{ .title = "User:Helper", .body = "{{:Shared}}", .ns = 2 },
        .{ .title = "Shared", .body = "<noinclude>{{#invoke:Excluded|run}}</noinclude>{{/Child}}{{:Template:Parent}}", .ns = 0 },
        .{ .title = "Template:/Child", .body = "{{#invoke:LiteralChild|run}}", .ns = 10 },
        .{ .title = "Template:Parent", .body = "{{/Child}}", .ns = 10 },
        .{ .title = "Template:Parent/Child", .body = "{{#invoke:Needed|run}}{{User:Helper}}", .ns = 10 },
        .{ .title = "Unreferenced", .body = "{{#invoke:MustNotRead|run}}", .ns = 0 },
        .{ .title = "Template:Alias", .body = "", .redirect = "User:Helper", .ns = 10 },
    };
    for (pages, 0..) |page, i| {
        const offset = sources.written().len;
        try sources.writer.writeAll(page.body);
        try rows.writer.print("{d}\t{d}\t{s}\t{s}\t{d}\t1\t2026-10-01T00:00:00Z\tTest\twikitext\t{d}\t1\t0\n", .{ offset, page.body.len, page.title, page.redirect, i + 1, page.ns });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = sources.written() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rows_path, .data = rows.written() });
    try dump.buildPageTitleIndex(io, a, rows_path, index_path);
    var registry = try Registry.init(a, @import("namespace_registry").english_test_fixture);
    defer registry.deinit();
    var roots: std.StringHashMapUnmanaged(u64) = .empty;
    defer roots.deinit(a);
    try roots.put(a, "Template:Alias", 1);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const result = try complete(io, a, &registry, source_path, root, &roots, &output.writer);
    try std.testing.expectEqual(@as(usize, 6), result.visited_pages);
    try std.testing.expectEqual(@as(usize, 5), result.source_reads);
    try std.testing.expect(!result.retain_all_modules);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "I\tTemplate:Parent/Child\tModule:Needed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "I\tTemplate:/Child\tModule:LiteralChild\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Excluded") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "MustNotRead") == null);
}
