const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const model = @import("model.zig");
const output = @import("output.zig");
const html = @import("html.zig");

test "all six encoded blob kinds survive typed decoding and human and machine rendering" {
    const a = std.testing.allocator;
    const fixtures = .{
        .{ .kind = enc.blob_format.BlobKind.language, .title = "cat", .source = "==English==\n===Noun===\n# A [[cat|feline]].\n" },
        .{ .kind = enc.blob_format.BlobKind.thesaurus, .title = "cat", .source = "{{ws header|cat}}\n===={{ws sense|en|animal}}====\n=====Synonyms=====\n{{ws|en|kitty}}\n" },
        .{ .kind = enc.blob_format.BlobKind.rhymes, .title = "English/æt", .source = "==Rhymes==\n* {{l|en|cat}}, {{l|en|bat}} {{q|rare}}\n" },
        .{ .kind = enc.blob_format.BlobKind.reconstruction, .title = "Proto-Germanic/kattuz", .source = "{{reconstructed}}\n==Proto-Germanic==\n===Noun===\n# cat\n" },
        .{ .kind = enc.blob_format.BlobKind.citations, .title = "cat", .source = "A citation with \x00 and \x1b[2J.\n" },
        .{ .kind = enc.blob_format.BlobKind.sign_gloss, .title = "ASL:CAT", .source = "raw sign \xff\x00" },
    };
    inline for (fixtures) |fixture| {
        const payload = switch (fixture.kind) {
            .supplement, .symbols, .templates, .bytecode, .redirects, .pages => unreachable,
            .language => try enc.language_blob_encoding.encodeAlloc(a, fixture.source, .{ .heading = "English" }),
            .thesaurus => try enc.thesaurus_encoding.encodeAlloc(a, fixture.source),
            .rhymes => try enc.rhymes_encoding.encodeAlloc(a, fixture.source),
            .reconstruction => try enc.reconstruction_encoding.encodeAlloc(a, fixture.source, fixture.title),
            .citations, .sign_gloss => try a.dupe(u8, fixture.source),
        };
        defer a.free(payload);
        const bytes = try enc.blob_format.buildAlloc(a, fixture.kind, if (fixture.kind == .language) "\x00English\x00" else "", &.{.{ .title = fixture.title, .payload = payload }});
        defer a.free(bytes);
        const view = try dec.openTrustedBlob(bytes);
        var index = try view.buildIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(fixture.title)).?;
        const source = try model.sourceAlloc(a, record);
        defer a.free(source);
        try std.testing.expectEqualStrings(fixture.source, source);
        var doc = try model.fromRecord(a, record, true);
        defer doc.deinit();
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        try output.entryText(&text.writer, doc.entry, false);
        try std.testing.expect(std.mem.indexOfScalar(u8, text.written(), 0x1b) == null);
        var json: std.Io.Writer.Allocating = .init(a);
        defer json.deinit();
        try output.json(&json.writer, .{ .operation = .lookup, .query = fixture.title, .kind = fixture.kind, .language = doc.entry.language, .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} });
        var page: std.Io.Writer.Allocating = .init(a);
        defer page.deinit();
        try html.write(&page.writer, a, .{ .operation = .lookup, .query = fixture.title, .kind = fixture.kind, .language = doc.entry.language, .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} });
        try std.testing.expect(std.mem.indexOf(u8, page.written(), "<script id=\"dict-data\"") != null);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(fixture.title, parsed.value.object.get("entries").?.array.items[0].object.get("title").?.string);
    }
}
