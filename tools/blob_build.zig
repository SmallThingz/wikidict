const std = @import("std");
const encoder = @import("encoder");
const xml_decode = @import("xml_decode");
const dump_source = @import("wikimedia_dump");
const language_registry = @import("language_registry.zig");
const bundle_expander = @import("bundle_expander.zig");

const Options = struct {
    limit_pages: ?usize = null,
    expander_root: []const u8 = "",
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

fn loadLanguageRegistry(io: std.Io, a: std.mem.Allocator, expander_root: []const u8) !language_registry.Registry {
    const manifest_path = try std.fs.path.join(a, &.{ expander_root, "manifest.jsonl" });
    defer a.free(manifest_path);
    var manifest = try mmapPath(io, manifest_path);
    defer manifest.deinit();
    const title_marker = "\"title\":\"Module:languages/canonical names\"";
    const marker = std.mem.indexOf(u8, manifest.bytes, title_marker) orelse return language_registry.Registry.empty(a);
    const line_start = if (std.mem.lastIndexOfScalar(u8, manifest.bytes[0..marker], '\n')) |newline| newline + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, manifest.bytes, marker, '\n') orelse manifest.bytes.len;
    const line = manifest.bytes[line_start..line_end];
    const page_prefix = "{\"page_id\":";
    if (!std.mem.startsWith(u8, line, page_prefix)) return error.InvalidModuleManifest;
    const comma = std.mem.indexOfScalarPos(u8, line, page_prefix.len, ',') orelse return error.InvalidModuleManifest;
    const page_id = std.fmt.parseInt(u64, line[page_prefix.len..comma], 10) catch return error.InvalidModuleManifest;
    const module_path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ expander_root, page_id });
    defer a.free(module_path);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, module_path, a, .unlimited);
    defer a.free(source);
    return language_registry.Registry.fromLuaAlloc(a, source);
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
        std.debug.print("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2> <output-root> --expander-root ROOT [--limit-pages N]\n", .{});
        return error.Usage;
    }
    const options = parseOptions(args) catch {
        std.debug.print("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2> <output-root> --expander-root ROOT [--limit-pages N]\n", .{});
        return error.Usage;
    };

    var registry = try loadLanguageRegistry(init.io, a, options.expander_root);
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
    const page_index_kind = dump_source.pageIndexKind(page_index.bytes);
    const stream_index_path = try std.fs.path.join(a, &.{ options.expander_root, "dump-streams.tsv" });
    defer a.free(stream_index_path);
    var dump = try dump_source.SourceReader.open(
        init.io,
        a,
        a,
        args[1],
        page_index_kind,
        if (page_index_kind == .multistream_bz2) stream_index_path else null,
    );
    defer dump.deinit();

    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    var lines = std.mem.splitScalar(u8, page_index.bytes, '\n');
    var pages_seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (options.limit_pages) |limit| if (pages_seen >= limit) break;
        pages_seen += 1;
        writer.stats.pages_seen = pages_seen;
        const page_allocator = page_arena.allocator();
        const page = try dump_source.parsePageIndexLine(page_index_kind, line);
        if (page.has_source and dump_source.relevantNamespace(page.ns)) {
            const raw_source = try dump.readAlloc(page_allocator, page.source);
            const source = if (page.source_needs_decode)
                try xml_decode.decodeSinglePassAlloc(page_allocator, raw_source)
            else
                raw_source;
            if (try worker.expand(page_allocator, @intCast(pages_seen - 1), page.title, source)) |expanded| {
                writer.addPage(page_allocator, page.ns, page.title, expanded.source, expanded.display_title) catch |err| {
                    std.debug.print(
                        "blob add failed title={s} ordinal={d} ns={d} source_bytes={d} expanded_bytes={d} error={s}\n",
                        .{ page.title, pages_seen - 1, page.ns, source.len, expanded.source.len, @errorName(err) },
                    );
                    return err;
                };
            }
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
