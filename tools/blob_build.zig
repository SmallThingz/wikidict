const std = @import("std");
const encoder = @import("encoder");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) {
        std.debug.print("usage: dict-blob-build <wiktionary.xml> <output-root> [limit-pages]\n", .{});
        return error.Usage;
    }
    const limit_pages = if (args.len == 4) try std.fmt.parseInt(usize, args[3], 10) else null;
    const stats = try encoder.blob_builder.build(init.io, std.heap.smp_allocator, .{
        .input_path = args[1],
        .output_root = args[2],
        .limit_pages = limit_pages,
    });
    for (std.meta.tags(encoder.language_parts.Kind), 0..) |family, i| {
        std.debug.print("supplement={s} records={d} framed_body_bytes={d}\n", .{ @tagName(family), stats.supplement_records[i], stats.supplement_bytes[i] });
    }
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
