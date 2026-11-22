const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const model = @import("model.zig");
const output = @import("output.zig");

fn payloadAlloc(a: std.mem.Allocator, kind: enc.blob_format.BlobKind, title: []const u8) ![]u8 {
    const spans = [_]enc.presentation_types.Span{.{ .text = "compiled presentation" }};
    const display_title = [_]enc.presentation_types.Span{.{ .text = title, .italic = true, .classes = "Latn", .role = .headword }};
    const blocks = [_]enc.presentation_types.Block{.{ .kind = .definition, .depth = 1, .spans = &spans, .list_path = "#" }};
    const sections = [_]enc.presentation_types.Section{.{ .level = 3, .title = "Entry", .blocks = &blocks }};
    return enc.presentation_codec.encodeAlloc(a, enc.presentation_types.Stored{ .entry = .{
        .title = title,
        .display_title = &display_title,
        .kind = kind,
        .language = if (kind == .language) "English" else null,
        .language_code = if (kind == .language) "en" else "",
        .sections = &sections,
    } });
}

test "all six shipped blob kinds deserialize compiled presentation only" {
    const a = std.testing.allocator;
    const kinds = [_]enc.blob_format.BlobKind{ .language, .thesaurus, .rhymes, .reconstruction, .citations, .sign_gloss, .supplemental };
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
        try std.testing.expectEqualStrings(title, doc.entry.title);
        try std.testing.expect(doc.entry.display_title.len == 1 and doc.entry.display_title[0].italic);
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        try output.entryText(&text.writer, doc.entry, false);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), title) != null);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "compiled presentation") != null);
        var json: std.Io.Writer.Allocating = .init(a);
        defer json.deinit();
        try output.json(&json.writer, .{ .operation = .lookup, .query = title, .kind = kind, .language = doc.entry.language, .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} });
        var parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
        defer parsed.deinit();
        const entry = parsed.value.object.get("entries").?.array.items[0].object;
        try std.testing.expectEqualStrings(title, entry.get("title").?.string);
        try std.testing.expectEqualStrings(title, entry.get("display_title").?.array.items[0].object.get("text").?.string);
    }
}

test "reader refuses old source-shaped record payloads" {
    const doc = model.fromRecord(std.testing.allocator, .{ .citations = .{ .title = "cat", .payload = "# [[cat]] {{template}}" } });
    try std.testing.expectError(error.InvalidPresentation, doc);
}

test "compiler linked heading publication reaches reader and CLI without label or sense loss" {
    var diagnostic_phase: []const u8 = "Writer initialization";
    errdefer std.debug.print("pipeline failure phase: {s}\n", .{diagnostic_phase});
    const builder = @import("encoder").blob_builder;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Languages = struct {
        fn get(_: ?*const anyopaque, heading: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, heading, "English")) "en" else null;
        }
    };
    const codes: builder.LanguageCodes = .{ .get_fn = Languages.get };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const source = "==English==\n=== [[NounTargetA|Noun]] ===\n# first definition\n#: first example\n=== [[NounTargetB|Noun]] ===\n# second definition\n#: second example\n";
    diagnostic_phase = "Writer page publication";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "linked heading pipeline", source, source, null);
    diagnostic_phase = "Writer finish and publication counts";
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    diagnostic_phase = "published blob native Reader lookup";
    const path = try builder.languageBlobPathAlloc(a, root, "English");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4 * 1024 * 1024));
    const view = try dec.openTrustedBlob(bytes);
    var index = try view.buildIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("linked heading pipeline")).?;
    diagnostic_phase = "model DPR2 decode and metadata";
    var doc = try model.fromRecord(a, record);
    defer doc.deinit();
    try std.testing.expectEqualStrings("English", doc.entry.language.?);
    try std.testing.expectEqualStrings("en", doc.entry.language_code);
    try std.testing.expectEqual(@as(usize, 2), doc.entry.organization.lexemes.len);
    for (doc.entry.organization.lexemes, [_][]const u8{ "NounTargetA", "NounTargetB" }, 0..) |lexeme, target, i| {
        diagnostic_phase = if (i == 0) "first decoded heading and sense association" else "second decoded heading and sense association";
        const section = doc.entry.sections[lexeme.section];
        try std.testing.expectEqualStrings("Noun", section.title);
        try std.testing.expectEqual(@as(u8, 3), section.level);
        try std.testing.expectEqual(@as(usize, 3), section.blocks.len);
        const heading = section.blocks[0];
        try std.testing.expect(heading.kind == .heading);
        try std.testing.expectEqual(@as(u8, 0), heading.depth);
        try std.testing.expectEqual(section.level, heading.level);
        try std.testing.expectEqual(@as(usize, 1), heading.spans.len);
        try std.testing.expect(heading.spans[0].kind == .link);
        try std.testing.expectEqualStrings("Noun", heading.spans[0].text);
        try std.testing.expectEqualStrings(target, heading.spans[0].target);
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        const sense = lexeme.definitions[0];
        try std.testing.expectEqual(@as(usize, 1), sense.block);
        try std.testing.expectEqualSlices(usize, &.{2}, sense.examples);
        try std.testing.expect(section.blocks[sense.block].kind == .definition);
        try std.testing.expect(section.blocks[sense.examples[0]].kind == .example);
        try std.testing.expectEqual(@as(u8, 1), section.blocks[sense.block].depth);
        try std.testing.expectEqual(@as(u8, 2), section.blocks[sense.examples[0]].depth);
        try std.testing.expectEqualStrings(if (i == 0) "first definition" else "second definition", section.blocks[sense.block].spans[0].text);
        try std.testing.expectEqualStrings(if (i == 0) "first example" else "second example", section.blocks[sense.examples[0]].spans[0].text);
    }
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    diagnostic_phase = "colored detailed header and body counts";
    try output.entryText(&text.writer, doc.entry, true);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text.written(), "Noun"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text.written(), "\x1b[36mNoun"));
    for ([_][]const u8{ "first definition", "second definition", "first example", "second example" }) |visible|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.written(), visible));
    text.clearRetainingCapacity();
    diagnostic_phase = "plain grouped header and body order";
    try output.entryText(&text.writer, doc.entry, false);
    const grouped = "\nNoun\n  1. first definition\n    │ first example\n\nNoun\n  1. second definition\n    │ second example\n";
    if (std.mem.indexOf(u8, text.written(), grouped) == null)
        std.debug.print("pipeline grouped output mismatch\nEXPECTED:\n{s}ACTUAL:\n{s}\n", .{ grouped, text.written() });
    try std.testing.expect(std.mem.indexOf(u8, text.written(), grouped) != null);
    text.clearRetainingCapacity();
    diagnostic_phase = "compact output";
    try output.entryTextWithDetails(&text.writer, doc.entry, false, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.written(), "Noun"));
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "first example") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "second example") == null);
    text.clearRetainingCapacity();
    diagnostic_phase = "folded output";
    _ = try output.entryTextFolded(&text, doc.entry, false, .{ .details = true }, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text.written(), "Noun"));
    for ([_][]const u8{ "first definition", "second definition", "first example", "second example" }) |visible|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.written(), visible));
    text.clearRetainingCapacity();
    diagnostic_phase = "actual public JSON section and target associations";
    try output.json(&text.writer, .{ .operation = .lookup, .query = "linked heading pipeline", .kind = .language, .language = "English", .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} });
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text.written(), .{});
    defer parsed.deinit();
    const entry_json = parsed.value.object.get("entries").?.array.items[0].object;
    const sections_json = entry_json.get("sections").?.array.items;
    for (doc.entry.organization.lexemes, [_][]const u8{ "NounTargetA", "NounTargetB" }) |lexeme, target| {
        const section_json = sections_json[lexeme.section].object;
        try std.testing.expectEqualStrings("Noun", section_json.get("title").?.string);
        try std.testing.expectEqual(@as(i64, 3), section_json.get("level").?.integer);
        const heading_json = section_json.get("blocks").?.array.items[0].object;
        try std.testing.expectEqualStrings("heading", heading_json.get("kind").?.string);
        try std.testing.expectEqual(@as(i64, 0), heading_json.get("depth").?.integer);
        try std.testing.expectEqual(@as(i64, 3), heading_json.get("level").?.integer);
        const span_json = heading_json.get("spans").?.array.items[0].object;
        try std.testing.expectEqualStrings("link", span_json.get("kind").?.string);
        try std.testing.expectEqualStrings("Noun", span_json.get("text").?.string);
        try std.testing.expectEqualStrings(target, span_json.get("target").?.string);
    }
}

test "language inventory rejects an incomplete build before output and preserves completed empty editions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
    const manifest = try std.fs.path.join(a, &.{ root, enc.blob_catalog.manifest_filename });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest, .data = enc.blob_catalog.manifest_header ++ "\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = marker, .data = "building" });
    var json: std.Io.Writer.Allocating = .init(a);
    defer json.deinit();
    // Both catalogue and exact-title inventory must obey the same boundary as
    // lookup. A valid partial/empty manifest is not a completed publication.
    for ([_][]const u8{ "", "cat" }) |query| {
        try std.testing.expectError(error.DictionaryBuildIncomplete, @import("languages.zig").write(std.testing.io, a, a, .{ .root = root, .query = query, .format = .json }, &json.writer));
        try std.testing.expectEqual(@as(usize, 0), json.written().len);
    }
    try std.Io.Dir.cwd().deleteFile(std.testing.io, marker);
    for ([_][]const u8{ "", "cat" }) |query| {
        json.clearRetainingCapacity();
        try @import("languages.zig").write(std.testing.io, a, a, .{ .root = root, .query = query, .format = .json }, &json.writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
        defer parsed.deinit();
        const value = parsed.value.object;
        try std.testing.expectEqualStrings("dict.languages.v1", value.get("schema").?.string);
        try std.testing.expectEqualStrings(if (query.len == 0) "catalog" else "entry", value.get("scope").?.string);
        try std.testing.expectEqualStrings(query, value.get("query").?.string);
        for ([_][]const u8{ "heading_count", "language_count", "translingual_count", "unverified_count" }) |name|
            try std.testing.expectEqual(@as(i64, 0), value.get(name).?.integer);
        try std.testing.expectEqual(@as(usize, 0), value.get("languages").?.array.items.len);
        try std.testing.expectEqual(@as(usize, 0), value.get("accounting").?.array.items.len);
    }
}



test "Writer catalog and normal Reader keep two headings with one parent code independently selectable" {
    const builder = @import("encoder").blob_builder;
    const store = @import("store.zig");
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    // The ordinary registry/marker proof is exercised by the tools controls.
    // This fixed callback isolates the public Writer/catalog/Reader contract.
    const Varieties = struct {
        fn resolve(_: ?*const anyopaque, label: []const u8) ?builder.ResolvedLanguage {
            if (std.mem.eql(u8, label, "Mofers")) return .{ .code = "li", .heading = "Mofers" };
            if (std.mem.eql(u8, label, "Algemein Gesjreve Limburgs")) return .{ .code = "li", .heading = "Algemein Gesjreve Limburgs" };
            return null;
        }
        fn get(ctx: ?*const anyopaque, label: []const u8) ?[]const u8 {
            return if (resolve(ctx, label)) |value| value.code else null;
        }
    };
    const codes: builder.LanguageCodes = .{ .get_fn = Varieties.get, .resolve_fn = Varieties.resolve, .trusted_fn = Varieties.resolve, .strong_fn = Varieties.resolve };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/li-reader", .{tmp.sub_path});
    var writer = try builder.Writer.init(io, a, root); defer writer.deinit();
    writer.language_codes = codes;
    const source = "==Algemein Gesjreve Limburgs==\n===Persuunlik veurnaamwaord===\n'''ich'''\n* Mofers: [[ich#Mofers|ich]]\n" ++
        "==Mofers==\n===Persuuenlik veurnaamwaord===\n====Lemma====\n'''ich'''\n# spraeker of sjriever\n#: ''Ich zing dit leed veur dich.''\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ich", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    const labels = [_][]const u8{ "Algemein Gesjreve Limburgs", "Mofers" };
    const first_path = try store.pathAlloc(a, root, .language, labels[0]);
    const second_path = try store.pathAlloc(a, root, .language, labels[1]);
    try std.testing.expect(!std.mem.eql(u8, first_path, second_path));
    for ([_][]const u8{ "", "ich" }) |query| {
        var json: std.Io.Writer.Allocating = .init(a); defer json.deinit();
        try @import("languages.zig").write(io, a, a, .{ .root = root, .query = query, .format = .json }, &json.writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{}); defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 2), obj.get("heading_count").?.integer);
        try std.testing.expectEqual(@as(i64, 2), obj.get("language_count").?.integer);
        try std.testing.expectEqual(@as(usize, 2), obj.get("accounting").?.array.items.len);
        for (obj.get("accounting").?.array.items, labels) |item, label| {
            try std.testing.expectEqualStrings(label, item.object.get("heading").?.string);
            try std.testing.expectEqualStrings("li", item.object.get("code").?.string);
            try std.testing.expectEqual(@as(i64, 1), item.object.get("records").?.integer);
        }
    }
    for (labels, 0..) |label, i| {
        var db = try store.Store.open(io, a, root, .language, label); defer db.deinit();
        try std.testing.expectEqualStrings(label, db.metadata().?.heading);
        try std.testing.expectEqualStrings("li", db.metadata().?.code);
        var raw = try db.recordAlloc(a, (try db.find("ich")).?); defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record); defer doc.deinit();
        try std.testing.expectEqualStrings(label, doc.entry.language.?);
        try std.testing.expectEqualStrings("li", doc.entry.language_code);
        try std.testing.expectEqualStrings(label, doc.entry.sections[0].title);
        for (doc.entry.sections) |section| try std.testing.expect(!std.mem.eql(u8, section.title, labels[1 - i]));
        try std.testing.expectEqual(@as(usize, 1), doc.entry.organization.lexemes.len);
        try std.testing.expectEqual(i, doc.entry.organization.lexemes[0].definitions.len);
        var text: std.Io.Writer.Allocating = .init(a); defer text.deinit();
        try output.entryText(&text.writer, doc.entry, false);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), if (i == 0) "Mofers: ich" else "Ich zing dit leed veur dich.") != null);
        text.clearRetainingCapacity();
        try output.entryTextWithDetails(&text.writer, doc.entry, false, false);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), if (i == 0) "Mofers: ich" else "spraeker of sjriever") != null);
        if (i == 1) try std.testing.expect(std.mem.indexOf(u8, text.written(), "Ich zing dit leed veur dich.") == null);
        var json: std.Io.Writer.Allocating = .init(a); defer json.deinit();
        try output.json(&json.writer, .{ .operation = .lookup, .query = "ich", .kind = .language, .language = label, .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} });
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{}); defer parsed.deinit();
        const entry = parsed.value.object.get("entries").?.array.items[0].object;
        try std.testing.expectEqualStrings(label, entry.get("language").?.string);
        try std.testing.expectEqualStrings("li", entry.get("language_code").?.string);
        const stored = try enc.presentation_codec.decodeAlloc(a, raw.record.payload(), "ich", .language, db.metadata());
        try std.testing.expectEqualSlices(u8, raw.record.payload(), try enc.presentation_codec.encodeAlloc(a, stored));
    }
}
