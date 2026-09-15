const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const model = @import("model.zig");
const output = @import("output.zig");

fn payloadAlloc(a: std.mem.Allocator, kind: enc.blob_format.BlobKind, title: []const u8) ![]u8 {
    const spans = [_]enc.presentation_types.Span{.{ .text = "compiled presentation" }};
    const blocks = [_]enc.presentation_types.Block{.{ .kind = .definition, .depth = 1, .spans = &spans, .list_path = "#" }};
    const sections = [_]enc.presentation_types.Section{.{ .level = 3, .title = "Entry", .blocks = &blocks }};
    return std.json.Stringify.valueAlloc(a, enc.presentation_types.Stored{ .entry = .{
        .title = title,
        .kind = kind,
        .language = if (kind == .language) "English" else null,
        .language_code = if (kind == .language) "en" else "",
        .sections = &sections,
    } }, .{});
}

test "all six shipped blob kinds deserialize compiled presentation only" {
    const a = std.testing.allocator;
    const kinds = [_]enc.blob_format.BlobKind{ .language, .thesaurus, .rhymes, .reconstruction, .citations, .sign_gloss };
    inline for (kinds) |kind| {
        const title = if (kind == .language) "cat" else @tagName(kind);
        const payload = try payloadAlloc(a, kind, title);
        defer a.free(payload);
        const metadata = if (kind == .language)
            try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English")
        else
            try a.dupe(u8, "");
        defer a.free(metadata);
        const bytes = try enc.blob_format.buildAlloc(a, kind, metadata, &.{.{ .title = title, .payload = payload }});
        defer a.free(bytes);
        const view = try dec.openTrustedBlob(bytes);
        var index = try view.buildIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(title)).?;
        var doc = try model.fromRecord(a, record);
        defer doc.deinit();
        try std.testing.expectEqualStrings("compiled presentation", doc.entry.sections[0].blocks[0].spans[0].text);
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        try output.entryText(&text.writer, doc.entry, false);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "compiled presentation") != null);
        var json: std.Io.Writer.Allocating = .init(a);
        defer json.deinit();
        try output.json(&json.writer, .{ .operation = .lookup, .query = title, .kind = kind, .language = doc.entry.language, .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} });
        var parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(title, parsed.value.object.get("entries").?.array.items[0].object.get("title").?.string);
    }
}

test "reader refuses old source-shaped record payloads" {
    const doc = model.fromRecord(std.testing.allocator, .{ .citations = .{ .title = "cat", .source = "# [[cat]] {{template}}" } });
    try std.testing.expectError(error.InvalidPresentation, doc);
}
