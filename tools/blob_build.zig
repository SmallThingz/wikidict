const std = @import("std");
const encoder = @import("encoder");
const dump_source = @import("wiktionary_dump.zig");

pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) {
        std.debug.print("usage: dict-blob-build <wiktionary.xml> <output-root> [limit-pages]\n", .{});
        return error.Usage;
    }
    const limit_pages = if (args.len == 4) try std.fmt.parseInt(usize, args[3], 10) else null;

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

    var writer = try encoder.blob_builder.Writer.init(init.io, a, args[2]);
    defer writer.deinit();
    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    var it = dump.iterator();
    while (true) {
        if (limit_pages) |limit| if (it.pages_seen >= limit) break;
        const page_allocator = page_arena.allocator();
        const page = (try it.next(page_allocator)) orelse break;
        writer.stats.pages_seen = it.pages_seen;
        if (dump_source.relevantNamespace(page.ns))
            try writer.addPage(page_allocator, page.ns, page.title, page.source);
        _ = page_arena.reset(.retain_capacity);
    }
    const stats = try writer.finish(codes);
    _ = try encoder.name_linker.linkRoot(init.io, a, args[2], null);

    for (std.meta.tags(encoder.language_parts.Kind), 0..) |family, i| {
        std.debug.print("supplement={s} records={d} framed_body_bytes={d}\n", .{ @tagName(family), stats.supplement_records[i], stats.supplement_bytes[i] });
    }
    std.debug.print(
        "pages={d} main_pages={d} language_records={d} language_blobs={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d}\n",
        .{ stats.pages_seen, stats.main_pages, stats.language_records, stats.language_blobs, stats.thesaurus_records, stats.citations_records, stats.reconstruction_records, stats.rhymes_records, stats.sign_gloss_records },
    );
}
