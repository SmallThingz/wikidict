const std = @import("std");
const encoder = @import("encoder");
const dump_source = @import("wiktionary_dump.zig");
const bundle_expander = @import("bundle_expander.zig");

const Options = struct {
    limit_pages: ?usize = null,
    expander_root: []const u8 = "",
};

const IndexedPage = struct {
    source_offset: u64,
    source_len: usize,
    title: []const u8,
    ns: u32,
    has_source: bool,
    source_needs_decode: bool,
};

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = std.math.cast(usize, (try file.stat(io)).size) orelse return error.FileTooBig;
    const bytes = if (len == 0)
        @as([]align(std.heap.page_size_min) const u8, &.{})
    else
        try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    return .{ .bytes = bytes };
}

fn parseIndexedPage(line: []const u8) !IndexedPage {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const source_offset = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
    const source_len = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidPageIndex, 10);
    const title = fields.next() orelse return error.InvalidPageIndex;
    _ = fields.next() orelse return error.InvalidPageIndex; // redirect
    _ = fields.next() orelse return error.InvalidPageIndex; // page id
    _ = fields.next() orelse return error.InvalidPageIndex; // revision id
    _ = fields.next() orelse return error.InvalidPageIndex; // revision timestamp
    _ = fields.next() orelse return error.InvalidPageIndex; // revision user
    _ = fields.next() orelse return error.InvalidPageIndex; // content model
    const ns = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPageIndex, 10);
    const has_source_raw = fields.next() orelse return error.InvalidPageIndex;
    const needs_decode_raw = fields.next() orelse return error.InvalidPageIndex;
    if (title.len == 0 or fields.next() != null) return error.InvalidPageIndex;
    const has_source = if (std.mem.eql(u8, has_source_raw, "1"))
        true
    else if (std.mem.eql(u8, has_source_raw, "0"))
        false
    else
        return error.InvalidPageIndex;
    const source_needs_decode = if (std.mem.eql(u8, needs_decode_raw, "1"))
        true
    else if (std.mem.eql(u8, needs_decode_raw, "0"))
        false
    else
        return error.InvalidPageIndex;
    return .{ .source_offset = source_offset, .source_len = source_len, .title = title, .ns = ns, .has_source = has_source, .source_needs_decode = source_needs_decode };
}

fn parseOptions(args: []const []const u8) !Options {
    var out: Options = .{};
    var index: usize = 3;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--limit-pages")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            out.limit_pages = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--expander-root")) {
            index += 1;
            if (index >= args.len or out.expander_root.len != 0) return error.Usage;
            out.expander_root = args[index];
        } else if (out.limit_pages == null) {
            out.limit_pages = std.fmt.parseInt(usize, arg, 10) catch return error.Usage;
        } else return error.Usage;
        index += 1;
    }
    if (out.expander_root.len == 0) return error.Usage;
    return out;
}

pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: dict-blob-build <wiktionary.xml> <output-root> --expander-root ROOT [--limit-pages N]\n", .{});
        return error.Usage;
    }
    const options = parseOptions(args) catch {
        std.debug.print("usage: dict-blob-build <wiktionary.xml> <output-root> --expander-root ROOT [--limit-pages N]\n", .{});
        return error.Usage;
    };

    var dump = try dump_source.Dump.open(init.io, a, args[1]);
    defer dump.deinit();
    var registry = try dump.languageRegistry(a);
    defer registry.deinit();
    const codes: encoder.blob_builder.LanguageCodes = .{
        .ctx = &registry,
        .get_fn = struct {
            fn get(raw: ?*const anyopaque, heading: []const u8) ?[]const u8 {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return null));
                return value.code(heading);
            }
        }.get,
    };

    const worker_path = try std.fs.path.join(a, &.{ options.expander_root, "dict-bundle-expander" });
    defer a.free(worker_path);
    var worker = bundle_expander.Worker.init(init.io, options.expander_root, worker_path, args[1]);
    defer worker.deinit();

    var writer = try encoder.blob_builder.Writer.init(init.io, a, args[2]);
    defer writer.deinit();
    const page_index_path = try std.fs.path.join(a, &.{ options.expander_root, "page-index.tsv" });
    defer a.free(page_index_path);
    var page_index = try mmapPath(init.io, page_index_path);
    defer page_index.deinit();

    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    var lines = std.mem.splitScalar(u8, page_index.bytes, '\n');
    var pages_seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (options.limit_pages) |limit| if (pages_seen >= limit) break;
        pages_seen += 1;
        writer.stats.pages_seen = pages_seen;
        const page_allocator = page_arena.allocator();
        const page = try parseIndexedPage(line);
        if (page.has_source and dump_source.relevantNamespace(page.ns)) {
            const start = std.math.cast(usize, page.source_offset) orelse return error.InvalidPageIndex;
            const end = std.math.add(usize, start, page.source_len) catch return error.InvalidPageIndex;
            if (end > dump.bytes.len) return error.InvalidPageIndex;
            const raw_source = dump.bytes[start..end];
            const source = if (page.source_needs_decode)
                try dump_source.decodeSourceAlloc(page_allocator, raw_source)
            else
                raw_source;
            const expanded = try worker.expand(page_allocator, page.title, source);
            try writer.addPage(page_allocator, page.ns, page.title, expanded);
        }
        _ = page_arena.reset(.retain_capacity);
    }
    const stats = try writer.finish(codes);

    std.debug.print(
        "pages={d} main_pages={d} language_records={d} language_blobs={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d}\n",
        .{
            stats.pages_seen,
            stats.main_pages,
            stats.language_records,
            stats.language_blobs,
            stats.thesaurus_records,
            stats.citations_records,
            stats.reconstruction_records,
            stats.rhymes_records,
            stats.sign_gloss_records,
        },
    );
}
