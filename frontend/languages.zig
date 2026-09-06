//! Explicit catalog-versus-entry accounting. Counts are derived from actual blob records.
const std = @import("std");
const files = @import("blob_storage");
const store = @import("store.zig");
const output = @import("output.zig");
const args = @import("args.zig");
const Item = struct { heading: []const u8, code: []const u8, classification: enum { language, translingual, unverified }, records: usize };
pub fn write(io: std.Io, a: std.mem.Allocator, scratch: std.mem.Allocator, opts: args.Options, w: *std.Io.Writer) !void {
    const path = try std.fs.path.join(a, &.{ opts.root, store.catalog.manifest_filename });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
    var it = try store.catalog.Iterator.init(bytes);
    var seen: std.StringHashMap(void) = .init(a);
    var items: std.ArrayList(Item) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next()) |entry| {
        const slot = try seen.getOrPut(entry.heading);
        if (slot.found_existing) return error.InvalidManifest;
        const file_path = try store.pathAlloc(scratch, opts.root, .language, entry.heading);
        defer scratch.free(file_path);
        var file = try files.File.open(io, scratch, file_path);
        defer file.deinit();
        if (file.view.kind != .language) return error.UnexpectedBlobKind;
        const meta = try file.view.languageMetadata();
        if (!std.mem.eql(u8, meta.heading, entry.heading)) return error.UnexpectedLanguageBlob;
        if (opts.query.len != 0 and file.find(opts.query) == null) continue;
        try items.append(a, .{ .heading = entry.heading, .code = try a.dupe(u8, meta.code), .classification = if (std.mem.eql(u8, meta.code, "mul")) .translingual else if (meta.code.len == 0) .unverified else .language, .records = file.recordCount() });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return std.mem.order(u8, x.heading, y.heading) == .lt;
        }
    }.less);
    var language_count: usize = 0;
    var translingual_count: usize = 0;
    var unverified_count: usize = 0;
    for (items.items) |item| {
        try names.append(a, item.heading);
        switch (item.classification) {
            .language => language_count += 1,
            .translingual => translingual_count += 1,
            .unverified => unverified_count += 1,
        }
    }
    const scope = if (opts.query.len == 0) "catalog" else "entry";
    if (opts.format == .json) {
        try std.json.Stringify.value(.{ .schema = "dict.languages.v1", .scope = scope, .query = opts.query, .heading_count = items.items.len, .language_count = language_count, .translingual_count = translingual_count, .unverified_count = unverified_count, .languages = names.items, .accounting = items.items }, .{ .whitespace = .indent_2 }, w);
        try w.writeByte('\n');
    } else {
        try w.print("{s}: {d} language headings; {d} Translingual; {d} unverified\n", .{ scope, language_count, translingual_count, unverified_count });
        if (opts.query.len != 0) {
            try w.writeAll("Exact title: ");
            try output.terminalText(w, opts.query);
            try w.writeByte('\n');
        }
        try w.writeAll("Heading\tCode\tRecords in language blob\n");
        for (items.items) |item| {
            try output.terminalText(w, item.heading);
            try w.writeByte('\t');
            try output.terminalText(w, item.code);
            try w.print("\t{d}\n", .{item.records});
        }
    }
}
