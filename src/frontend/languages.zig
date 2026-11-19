//! Explicit catalog-versus-entry accounting. Counts are derived from actual blob records.
const std = @import("std");
const files = @import("blob_storage");
const store = @import("store.zig");
const output = @import("output.zig");
const args = @import("args.zig");
const Item = struct { heading: []const u8, code: []const u8, classification: enum { language, translingual, unverified }, records: usize };

fn readItem(io: std.Io, a: std.mem.Allocator, scratch: std.mem.Allocator, opts: args.Options, heading: []const u8) !?Item {
    const file_path = try store.pathAlloc(scratch, opts.root, .language, heading);
    defer scratch.free(file_path);
    var file = try files.File.open(io, scratch, file_path);
    defer file.deinit();
    if (file.view.kind != .language) return error.UnexpectedBlobKind;
    const meta = try file.view.languageMetadata();
    if (!std.mem.eql(u8, meta.heading, heading)) return error.UnexpectedLanguageBlob;
    if (opts.query.len != 0 and file.find(opts.query) == null) return null;
    return .{ .heading = heading, .code = try a.dupe(u8, meta.code), .classification = if (std.mem.eql(u8, meta.code, "mul")) .translingual else if (meta.code.len == 0) .unverified else .language, .records = file.recordCount() };
}

fn catalogPage(a: std.mem.Allocator, bytes: []const u8, offset: usize, size: usize) !struct { all: [][]const u8, selected: [][]const u8 } {
    var it = try store.catalog.Iterator.init(bytes);
    var headings: std.ArrayList([]const u8) = .empty;
    errdefer headings.deinit(a);
    while (try it.next()) |entry| {
        if (!std.unicode.utf8ValidateSlice(entry.heading)) return error.InvalidManifest;
        try headings.append(a, entry.heading);
    }
    std.mem.sort([]const u8, headings.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    for (headings.items[@min(1, headings.items.len)..], 0..) |heading, i| {
        if (std.mem.eql(u8, heading, headings.items[i])) return error.InvalidManifest;
    }
    const all = try headings.toOwnedSlice(a);
    const start = @min(offset, all.len);
    return .{ .all = all, .selected = all[start..][0..@min(size, all.len - start)] };
}

pub fn write(io: std.Io, a: std.mem.Allocator, scratch: std.mem.Allocator, opts: args.Options, w: *std.Io.Writer) !void {
    try @import("blob_files").requireComplete(io, scratch, opts.root);
    const path = try std.fs.path.join(a, &.{ opts.root, store.catalog.manifest_filename });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
    if (opts.catalog_page_size) |size| {
        const page = try catalogPage(scratch, bytes, opts.offset, size);
        defer scratch.free(page.all);
        const accounting = try a.alloc(Item, page.selected.len);
        for (page.selected, accounting) |heading, *item| {
            item.* = (try readItem(io, a, scratch, opts, heading)).?;
        }
        try std.json.Stringify.value(.{ .schema = "dict.languages.page.v1", .offset = opts.offset, .total_headings = page.all.len, .accounting = accounting }, .{ .whitespace = .indent_2 }, w);
        try w.writeByte('\n');
        return;
    }
    var it = try store.catalog.Iterator.init(bytes);
    var seen: std.StringHashMap(void) = .init(a);
    var items: std.ArrayList(Item) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next()) |entry| {
        const slot = try seen.getOrPut(entry.heading);
        if (slot.found_existing) return error.InvalidManifest;
        if (try readItem(io, a, scratch, opts, entry.heading)) |item| try items.append(a, item);
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

test "catalog pages validate off-page headings and clamp empty or final slices" {
    const a = std.testing.allocator;
    const page = try catalogPage(a, "heading\nZulu\nEnglish\nArabic\n", 2, 2);
    defer a.free(page.all);
    try std.testing.expectEqual(@as(usize, 3), page.all.len);
    try std.testing.expectEqual(@as(usize, 1), page.selected.len);
    try std.testing.expectEqualStrings("Zulu", page.selected[0]);
    const empty = try catalogPage(a, "heading\nEnglish\n", std.math.maxInt(usize), 1);
    defer a.free(empty.all);
    try std.testing.expectEqual(@as(usize, 0), empty.selected.len);
    const neutral = try catalogPage(a, "heading\n", 0, 1);
    defer a.free(neutral.all);
    try std.testing.expectEqual(@as(usize, 0), neutral.all.len);
    try std.testing.expectError(error.InvalidManifest, catalogPage(a, "heading\nArabic\nZulu\nZulu\n", 0, 1));
    try std.testing.expectError(error.InvalidManifest, catalogPage(a, "heading\nArabic\n\xff\n", 0, 1));
}
