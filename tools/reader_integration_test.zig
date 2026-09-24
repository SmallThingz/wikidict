//! Real installed CLI behavior against a freshly built split dictionary.
const std = @import("std");
const enc = @import("blob_encoder");

const source = "==English==\n===Etymology===\nHistorical source.\n===Noun===\n{{en-noun}}\n# A small animal.\n#: The cat sleeps.\n====Translations====\nFrench: chat\n====Synonyms====\nFeline\n===Quotations===\nA printed quotation\n===References===\nBook, 2020.\n";
const Harness = struct {
    a: std.mem.Allocator,
    io: std.Io,
    checks: usize = 0,
    fn run(self: *Harness, args: []const []const u8, expected: u8) ![]const u8 {
        const r = try std.process.run(self.a, self.io, .{ .argv = args, .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
        if (r.term != .exited or r.term.exited != expected) {
            std.debug.print("Reader command failed: {s} {s} => {any}, expected {d}\n{s}\n{s}\n", .{ args[0], args[1], r.term, expected, r.stdout, r.stderr });
            return error.ChildFailed;
        }
        self.checks += 1;
        return r.stdout;
    }
    fn require(_: *Harness, ok: bool, label: []const u8) !void {
        if (!ok) {
            std.debug.print("Reader assertion failed: {s}\n", .{label});
            return error.AssertionFailed;
        }
    }
    fn entry(self: *Harness, text: []const u8) !std.json.Value {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.a, text, .{});
        return parsed.value.object.get("entries").?.array.items[0];
    }
};
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
    var records: std.ArrayList(enc.blob_format.RecordInput) = .empty;
    defer records.deinit(a);
    try records.append(a, .{ .title = "cat", .payload = payload });
    for ([_][]const u8{ "catfish", "École", "ΣΊΣΥΦΟΣ", "МОСКВА" }) |title| {
        var variant = stored;
        variant.entry.title = title;
        const encoded = try enc.presentation_codec.encodeAlloc(a, variant);
        try records.append(a, .{ .title = title, .payload = encoded });
    }
    defer for (records.items[1..]) |record| a.free(record.payload);
    const blob = try enc.blob_format.buildAlloc(a, .language, metadata, records.items);
    defer a.free(blob);

    const languages_dir = try std.fs.path.join(a, &.{ root, enc.blob_catalog.language_directory });
    try std.Io.Dir.cwd().createDirPath(io, languages_dir);
    var filename: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ languages_dir, enc.blob_catalog.languageBlobFilename("English", &filename) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = blob });
    const manifest = try std.fs.path.join(a, &.{ root, enc.blob_catalog.manifest_filename });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = enc.blob_catalog.manifest_header ++ "\nEnglish\n" });
    const marker = try std.fs.path.join(a, &.{ root, ".reader-fixture" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "Synthetic reader integration fixture.\n" });
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 4) return error.Usage;
    const dir = try std.fmt.allocPrint(a, "{s}/reader-integration-{d}", .{ argv[3], std.Io.Clock.awake.now(init.io).toNanoseconds() });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    const root = try std.fs.path.join(a, &.{ dir, "blobs" });
    try writeCompiledFixture(init.io, a, root);

    var h: Harness = .{ .a = a, .io = init.io };
    const bin = argv[1];
    const ffi_test = argv[2];
    const ffi_output = try h.run(&.{ ffi_test, root, "cat" }, 0);
    try h.require(std.mem.indexOf(u8, ffi_output, "FFI_INTEGRATION_PASS") != null, "data-only C ABI");

    const exported = try h.run(&.{ bin, "export", "cat", "--root", root }, 0);
    const export_path = try std.fs.path.join(a, &.{ dir, "fixture.json" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = export_path, .data = exported });

    const complete = try h.entry(try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "json" }, 0));
    try h.require(complete.object.get("sections").?.array.items.len == 3, "complete compiled document");
    const text = try h.run(&.{ bin, "lookup", "cat", "--root", root }, 0);
    try h.require(std.mem.indexOf(u8, text, "small animal") != null, "compiled definition renders");
    const details_text = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, details_text, "Historical source") != null, "compiled supporting material renders");
    for ([_][]const u8{ "PREAMBLE", "After line break", "column A  column B", "Inflection table", "Reference content.", "Example image.svg", "Example pronunciation.ogg" }) |expected|
        try h.require(std.mem.indexOf(u8, details_text, expected) != null, expected);

    _ = try h.run(&.{ bin, "save", "cat", "--root", root }, 0);
    _ = try h.run(&.{ bin, "save", "cat", "--root", root }, 0);
    const saved = try h.run(&.{ bin, "saved", "--root", root }, 0);
    try h.require(std.mem.eql(u8, saved, "cat\n"), "saving is idempotent and plain lists stay pipe-friendly");
    _ = try h.run(&.{ bin, "save", "missing", "--root", root }, 1);
    _ = try h.run(&.{ bin, "unsave", "cat", "--root", root }, 0);
    _ = try h.run(&.{ bin, "unsave", "cat", "--root", root }, 0);
    const empty = try h.run(&.{ bin, "saved", "--root", root, "--format", "json" }, 1);
    const empty_json = try std.json.parseFromSlice(std.json.Value, a, empty, .{});
    try h.require(empty_json.value.object.get("matches").?.array.items.len == 0, "unsave survives another invocation");
    const empty_saved = try h.run(&.{ bin, "saved", "--root", root }, 1);
    try h.require(empty_saved.len == 0, "empty collection guidance stays out of stdout");
    const empty_search = try h.run(&.{ bin, "search", "missing", "--root", root }, 1);
    try h.require(empty_search.len == 0, "no-match guidance stays out of stdout");
    const beyond = try h.run(&.{ bin, "search", "cat", "--root", root, "--offset", "100" }, 0);
    try h.require(beyond.len == 0, "pagination hints do not contaminate stdout");
    _ = try h.run(&.{ bin, "tui", "--root", root }, 2);
    for ([_][]const u8{ "CAT", "école", "σίσυφος", "москва" }) |query| {
        _ = try h.run(&.{ bin, "lookup", query, "--root", root }, 0);
        _ = try h.run(&.{ bin, "search", query, "--root", root }, 0);
    }
    _ = try h.run(&.{ bin, "lookup", "CAT", "--root", root, "--case-sensitive" }, 1);
    _ = try h.run(&.{ bin, "search", "CAT", "--root", root, "--case-sensitive" }, 1);

    _ = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--core-only" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--format", "source" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--with-source" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--runtime", "not-present" }, 2);
    std.debug.print("READER_INTEGRATION_PASS checks={d}: precompiled fixture, data-only JSON/CLI/FFI, no source/runtime/core fallback. Artifacts: {s}\n", .{ h.checks, dir });
}
