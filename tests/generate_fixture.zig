//! Compiled semantic fixture for native UX regression tests.
const std = @import("std");
const enc = @import("blob_encoder");

fn writeCompiledFixture(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
    const definition_spans = [_]enc.presentation_types.Span{.{ .text = "A small animal." }};
    const example_spans = [_]enc.presentation_types.Span{.{ .text = "The cat sleeps." }};
    const history_spans = [_]enc.presentation_types.Span{.{ .text = "Historical source." }};
    const styled = [_]enc.presentation_types.Span{
        .{ .text = "Bold", .bold = true, .trail = " " },
        .{ .text = "Italic", .italic = true, .trail = " " },
        .{ .text = "code sample", .code = true, .trail = " " },
        .{ .text = "small", .small = true, .trail = " " },
        .{ .text = "2", .superscript = true, .trail = " " },
        .{ .text = "2", .subscript = true, .trail = " " },
        .{ .text = "marked", .strike = true, .underline = true, .trail = " " },
        .{ .kind = .link, .text = "école", .target = "école", .trail = "s " },
        .{ .kind = .external_link, .text = "Wiktionary", .target = "https://en.wiktionary.org/wiki/cat" },
        .{ .kind = .line_break },
        .{ .text = "After line break: 猫 👩🏽‍💻 é " },
        .{ .text = "كتاب", .language = "ar", .direction = "rtl" },
    };
    const pre = [_]enc.presentation_types.Span{.{ .text = "column A  column B\n  indented\tvalue", .code = true }};
    const caption = [_]enc.presentation_types.Span{.{ .text = "Inflection table" }};
    const table_rows = [_]enc.presentation_types.Row{
        .{ .cells = &.{ .{ .spans = &.{.{ .text = "Case" }}, .header = true, .rowspan = 2 }, .{ .spans = &.{.{ .text = "Number" }}, .header = true, .colspan = 2 } } },
        .{ .cells = &.{ .{ .spans = &.{.{ .text = "Singular" }}, .header = true }, .{ .spans = &.{.{ .text = "Plural" }}, .header = true } } },
        .{ .cells = &.{ .{ .spans = &.{.{ .text = "Nominative" }} }, .{ .spans = &.{.{ .text = "cat" }} }, .{ .spans = &.{.{ .text = "cats" }} } } },
    };
    const noun_blocks = [_]enc.presentation_types.Block{
        .{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &definition_spans },
        .{ .kind = .example, .depth = 1, .list_path = "#:", .spans = &example_spans },
        .{ .kind = .paragraph, .spans = &styled },
        .{ .kind = .preformatted, .spans = &pre },
        .{ .kind = .table, .table = .{ .caption = &caption, .rows = &table_rows } },
    };
    const history_blocks = [_]enc.presentation_types.Block{
        .{ .kind = .paragraph, .spans = &history_spans },
    };
    const sections = [_]enc.presentation_types.Section{
        .{ .level = 2, .title = "English" },
        .{ .level = 3, .title = "Etymology", .blocks = &history_blocks },
        .{ .level = 3, .title = "Noun", .blocks = &noun_blocks },
    };
    const stored: enc.presentation_types.Stored = .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
        .sections = &sections,
        .preamble_spans = &.{.{ .text = "PREAMBLE: compiled presentation." }},
        .references = &.{.{ .number = 1, .group_number = 1, .group = "note", .spans = &.{.{ .text = "Reference content." }} }},
        .media = &.{ .{ .file = "Example image.svg", .kind = .image, .caption = "Image caption" }, .{ .file = "Example pronunciation.ogg", .kind = .audio, .caption = "Pronunciation audio" } },
    } };
    const payload = try enc.presentation_codec.encodeAlloc(a, stored);
    defer a.free(payload);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    var entries: std.ArrayList(enc.blob_format.RecordInput) = .empty;
    try entries.append(a, .{ .title = "cat", .payload = payload });
    var i: usize = 0;
    while (i < 181) : (i += 1) {
        const title = if (i == 0) "dog" else try std.fmt.allocPrint(a, "page{d:0>3}", .{i});
        var word = stored;
        word.entry.title = title;
        try entries.append(a, .{ .title = title, .payload = try enc.presentation_codec.encodeAlloc(a, word) });
    }
    const blob = try enc.blob_format.buildAlloc(a, .language, metadata, entries.items);
    defer a.free(blob);

    const languages_dir = try std.fs.path.join(a, &.{ root, enc.blob_catalog.language_directory });
    try std.Io.Dir.cwd().createDirPath(io, languages_dir);
    var filename: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ languages_dir, enc.blob_catalog.languageBlobFilename("English", &filename) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blob });
    const manifest = try std.fs.path.join(a, &.{ root, enc.blob_catalog.manifest_filename });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = enc.blob_catalog.manifest_header ++ "\nEnglish\n" });

    var thesaurus = stored;
    thesaurus.entry.kind = .thesaurus;
    thesaurus.entry.language = null;
    thesaurus.entry.language_code = "";
    const thesaurus_payload = try enc.presentation_codec.encodeAlloc(a, thesaurus);
    defer a.free(thesaurus_payload);
    const thesaurus_blob = try enc.blob_format.buildAlloc(a, .thesaurus, "", &.{.{ .title = "cat", .payload = thesaurus_payload }});
    defer a.free(thesaurus_blob);
    const thesaurus_path = try std.fs.path.join(a, &.{ root, "thesaurus.wikblb" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = thesaurus_path, .data = thesaurus_blob });
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 2) return error.ExpectedOutputFolder;
    try writeCompiledFixture(init.io, init.arena.allocator(), argv[1]);
}
