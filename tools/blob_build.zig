const std = @import("std");
const encoder = @import("encoder");
const dump_source = @import("wiktionary_dump.zig");
const bundle_expander = @import("bundle_expander.zig");

const Options = struct {
    limit_pages: ?usize = null,
    expander_root: []const u8 = "",
};

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
    var worker = bundle_expander.Worker.init(init.io, options.expander_root, worker_path);
    defer worker.deinit();

    var writer = try encoder.blob_builder.Writer.init(init.io, a, args[2]);
    defer writer.deinit();
    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    var it = dump.iterator();
    while (true) {
        if (options.limit_pages) |limit| if (it.pages_seen >= limit) break;
        const page_allocator = page_arena.allocator();
        const page = (try it.next(page_allocator)) orelse break;
        writer.stats.pages_seen = it.pages_seen;
        if (dump_source.relevantNamespace(page.ns)) {
            const source = try worker.expand(page_allocator, page.title, page.source);
            try writer.addPage(page_allocator, page.ns, page.title, source);
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
