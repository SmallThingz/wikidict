//! Real installed CLI behavior against a freshly built split dictionary.
const std = @import("std");
const enc = @import("blob_encoder");
const encoder = @import("encoder");

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
    const swatch_fallback = [_]enc.presentation_types.Row{.{ .cells = &.{.{ .spans = &.{.{ .text = "Valid swatch fallback" }} }} }};
    const malformed_fallback = [_]enc.presentation_types.Row{.{ .cells = &.{.{ .spans = &.{.{ .text = "Malformed swatch fallback" }} }} }};
    const unknown_fallback = [_]enc.presentation_types.Row{.{ .cells = &.{.{ .spans = &.{.{ .text = "Unknown swatch fallback" }} }} }};
    const noun_blocks = [_]enc.presentation_types.Block{
        .{ .kind = .table, .feature = .{ .kind = "color_swatch", .data = "#ffff00" }, .table = .{ .rows = &swatch_fallback } },
        .{ .kind = .table, .feature = .{ .kind = "color_swatch", .data = "#FFFF00" }, .table = .{ .rows = &malformed_fallback } },
        .{ .kind = .table, .feature = .{ .kind = "unknown_swatch", .data = "#ffff00" }, .table = .{ .rows = &unknown_fallback } },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &definition_spans },
        .{ .kind = .example, .depth = 1, .list_path = "#:", .spans = &example_spans },
        .{ .kind = .paragraph, .spans = &styled },
        .{ .kind = .preformatted, .spans = &pre },
        .{ .kind = .table, .table = .{ .caption = &caption, .rows = &table_rows } },
    };
    const history_blocks = [_]enc.presentation_types.Block{
        .{ .kind = .paragraph, .spans = &history_spans },
    };
    // Empty authored parents reproduce Port:Bīnaman's compiled section shape.
    const personal_rows = [_]enc.presentation_types.Row{.{ .cells = &.{.{ .spans = &.{.{ .text = "Personal table token" }} }} }};
    const demonstrative_rows = [_]enc.presentation_types.Row{.{ .cells = &.{.{ .spans = &.{.{ .text = "Demonstrative table token" }} }} }};
    const sections = [_]enc.presentation_types.Section{
        .{ .level = 2, .title = "English" },
        .{ .level = 3, .title = "Etymology", .blocks = &history_blocks },
        .{ .level = 3, .title = "Noun", .blocks = &noun_blocks },
        .{ .level = 1, .title = "Personal", .anchor = "Personal" },
        .{ .level = 2, .title = "1st", .anchor = "1st", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &personal_rows } }} },
        .{ .level = 1, .title = "Demonstratives", .anchor = "Demonstratives" },
        .{ .level = 2, .title = "That, those, the", .anchor = "That,_those,_the", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &demonstrative_rows } }} },
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

fn writeStudyMeaningFixture(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
    // Controlled data-only contrast, not a new definition for the Greek bullet.
    const T = enc.presentation_types;
    const entries = [_]T.Entry{
        .{ .title = "bullet", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 3, .title = "Ουσιαστικό", .blocks = &.{.{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{.{ .text = "συνώνυμο του λέκος πιάτο, κατσαρόλα, δοχείο σαν κύπελλο" }} }} }} },
        .{ .title = "café", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 3, .title = "Noun", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &.{.{ .text = "A place to drink coffee." }} }} } }} }} },
    };
    var records: [entries.len]enc.blob_format.RecordInput = undefined;
    for (entries, 0..) |entry, i| records[i] = .{ .title = entry.title, .payload = try enc.presentation_codec.encodeAlloc(a, .{ .entry = entry }) };
    defer for (records) |record| a.free(record.payload);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const blob = try enc.blob_format.buildAlloc(a, .language, metadata, &records);
    defer a.free(blob);
    const languages = try std.fs.path.join(a, &.{ root, enc.blob_catalog.language_directory });
    try std.Io.Dir.cwd().createDirPath(io, languages);
    var filename: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ languages, enc.blob_catalog.languageBlobFilename("English", &filename) }), .data = blob });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, enc.blob_catalog.manifest_filename }), .data = enc.blob_catalog.manifest_header ++ "\nEnglish\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, ".reader-fixture" }), .data = "Synthetic no-structured-meaning reader control; Greek bullet remains a list item.\n" });
}

fn writeAliasFixture(io: std.Io, a: std.mem.Allocator, root: []const u8, neutral: bool) !void {
    // The four source/target spellings reproduce the pinned Bulgarian routing
    // defect; definition contents and the two-edge chain are synthetic.
    const target_titles = [_][]const u8{ "animus", "combustible", "county seat", "gainst" };
    var definitions: [target_titles.len]enc.blob_format.RecordInput = undefined;
    for (target_titles, 0..) |title, i| definitions[i] = .{
        .title = title,
        .payload = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{
            .title = title,
            .kind = .language,
            .language = "English",
            .language_code = "en",
            .sections = &.{.{ .level = 3, .title = "Noun", .blocks = &.{.{ .kind = .definition, .spans = &.{.{ .text = "Target definition." }} }} }},
        } }),
    };
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    const definition_blob = try enc.blob_format.buildAlloc(a, .language, metadata, &definitions);
    const languages_dir = try std.fs.path.join(a, &.{ root, enc.blob_catalog.language_directory });
    try std.Io.Dir.cwd().createDirPath(io, languages_dir);
    var filename: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
    const language_path = try std.fs.path.join(a, &.{ languages_dir, enc.blob_catalog.languageBlobFilename("English", &filename) });
    if (!neutral) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = language_path, .data = definition_blob });
    const source_titles = [_][]const u8{ "Animus", "ChainA", "ChainB", "Combustible", "County seat", "Gainst" };
    const destinations = [_][]const u8{ "animus", "ChainB", "gainst", "combustible", "county seat", "gainst" };
    var aliases: [source_titles.len]enc.blob_format.RecordInput = undefined;
    for (source_titles, destinations, 0..) |title, target, i| {
        const fragment: []const u8 = if (std.mem.eql(u8, title, "ChainA")) "Incoming" else if (std.mem.eql(u8, title, "ChainB")) "Noun" else "";
        const link = if (fragment.len == 0) target else try std.fmt.allocPrint(a, "{s}#{s}", .{ target, fragment });
        const presentation = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{
            .title = title,
            .kind = .alias,
            .preamble_spans = &.{.{ .kind = .link, .text = target, .target = link }},
        } });
        aliases[i] = .{ .title = try enc.alias_codec.keyAlloc(a, .language, title), .payload = try enc.alias_codec.encodeAlloc(a, .{
            .source_namespace = 0,
            .source_kind = .language,
            .source_title = title,
            .source_key = title,
            .xml_target = target,
            .target_title = target,
            .target_namespace = 0,
            .target_kind = .language,
            .target_key = target,
            .fragment = fragment,
            .presentation = presentation,
        }) };
    }
    const alias_blob = try enc.blob_format.buildAlloc(a, .alias, "", &aliases);
    const alias_path = try std.fs.path.join(a, &.{ root, enc.blob_catalog.featureBlobFilename(.alias).? });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = alias_path, .data = alias_blob });
    const manifest = try std.fs.path.join(a, &.{ root, enc.blob_catalog.manifest_filename });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = if (neutral) enc.blob_catalog.manifest_header ++ "\n" else enc.blob_catalog.manifest_header ++ "\nEnglish\n" });
    const marker = try std.fs.path.join(a, &.{ root, ".reader-fixture" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "Synthetic compiled alias reader integration fixture.\n" });
}

fn checkWriterCellRules(h: *Harness, bin: []const u8, dir: []const u8) !void {
    const a = h.a;
    const root = try std.fs.path.join(a, &.{ dir, "writer-cell-rules" });
    const authored = "==01==\n{|\n| '''A'''\n----\n*[[alal]]\n'''B'''\n----\n*''[[baat]]''\n|}\n";
    // Build the fixture through the ordinary Writer; do not seed typed rule blocks.
    var writer = try encoder.blob_builder.Writer.init(h.io, a, root);
    defer writer.deinit();
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "cell-rules", authored, null);
    const stats = try writer.finish(.{});
    try h.require(stats.language_records == 1 and stats.language_blobs == 1, "Writer preserves unclassified word-index owner");
    var filename: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ root, "languages", enc.blob_catalog.languageBlobFilename("Unclassified", &filename) });
    const blob_bytes = try std.Io.Dir.cwd().readFileAlloc(h.io, path, a, .limited(1024 * 1024));
    const blob = try enc.blob_format.inspect(blob_bytes);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("cell-rules")) orelse return error.AssertionFailed;
    const stored = try enc.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
    try h.require(std.mem.eql(u8, record.payload, try enc.presentation_codec.encodeAlloc(a, stored)), "Writer rule blocks round trip exact codec bytes");
    try h.require(stored.entry.sections.len == 1 and std.mem.eql(u8, stored.entry.sections[0].title, "01"), "Writer retains numeric source section without language inference");
    const cell = stored.entry.sections[0].blocks[0].table.?.rows[0].cells[0];
    const ordered = cell.blocks orelse return error.AssertionFailed;
    const kinds = [_]enc.presentation_types.BlockKind{ .paragraph, .rule, .list_item, .paragraph, .rule, .list_item };
    try h.require(ordered.len == kinds.len and cell.spans.len == 0, "Writer stores ordered cell blocks rather than flattened rules");
    for (ordered, kinds) |block, kind| try h.require(block.kind == kind, "Writer rule source position");
    const entry = try h.entry(try h.run(&.{ bin, "lookup", "cell-rules", "--root", root, "--language", "Unclassified", "--format", "json" }, 0));
    const sections = entry.object.get("sections").?.array.items;
    try h.require(sections.len == 1, "Reader keeps cell blocks within original section");
    const cells = sections[0].object.get("blocks").?.array.items[0].object.get("table").?.object.get("rows").?.array.items[0].object.get("cells").?.array.items;
    const blocks = cells[0].object.get("blocks").?.array.items;
    try h.require(blocks.len == 6, "Reader emits all six ordered cell blocks");
    for (blocks, [_][]const u8{ "paragraph", "rule", "list_item", "paragraph", "rule", "list_item" }) |block, kind|
        try h.require(std.mem.eql(u8, block.object.get("kind").?.string, kind), "Reader rule placement matches Writer codec");
    for ([_]usize{ 2, 5 }, [_][]const u8{ "alal", "baat" }) |position, target| {
        const spans = blocks[position].object.get("spans").?.array.items;
        try h.require(spans.len == 1 and std.mem.eql(u8, spans[0].object.get("target").?.string, target), "Reader retains links beside cell rules");
    }
    const text = try h.run(&.{ bin, "lookup", "cell-rules", "--root", root, "--language", "Unclassified", "--details" }, 0);
    const rule = "────────────────────────";
    try h.require(std.mem.count(u8, text, rule) == 2, "Reader visibly renders both cell rules");
    const first_rule = std.mem.indexOf(u8, text, rule) orelse return error.AssertionFailed;
    const alal = std.mem.indexOf(u8, text, "alal") orelse return error.AssertionFailed;
    const second_rule = std.mem.indexOfPos(u8, text, first_rule + rule.len, rule) orelse return error.AssertionFailed;
    const baat = std.mem.indexOf(u8, text, "baat") orelse return error.AssertionFailed;
    try h.require(first_rule < alal and alal < second_rule and second_rule < baat, "Reader plain rule and link order matches authored cells");
}

fn checkWriterImageBorder(h: *Harness, bin: []const u8, ffi_test: []const u8, dir: []const u8) !void {
    const a = h.a;
    const root = try std.fs.path.join(a, &.{ dir, "writer-image-border" });
    const title = "image-border-contract";
    // Marked synthetic source; the actual alarmowac full-page oracle is in blob_builder.
    const authored = "== Image border contract ==\n[[File:Flag of Poland.svg|border|40px]] [[File:Open book 01.svg|30px]]\n[[File:Flag of Poland.svg|border|20px|alt=|link=]] [[File:Flag of Poland.svg|border|x25px|alt=Poland|link=https://example.test/]]";
    var writer = try encoder.blob_builder.Writer.init(h.io, a, root);
    defer writer.deinit();
    try writer.addPage(a, .{ .id = 100, .kind = .supplemental }, title, authored, null);
    const stats = try writer.finish(.{});
    try h.require(stats.supplemental_records == 1 and stats.language_records == 0, "border fixture is supplemental without invented owner");
    const blob_path = try std.fs.path.join(a, &.{ root, enc.blob_catalog.featureBlobFilename(.supplemental).? });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(h.io, blob_path, a, .limited(1024 * 1024));
    const blob = try enc.blob_format.inspect(bytes);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find(title)) orelse return error.AssertionFailed;
    try h.require(std.mem.eql(u8, record.payload[0..4], "DPRD"), "ordinary Writer generated conditional DPRD");
    const stored = try enc.presentation_codec.decodeAlloc(a, record.payload, title, .supplemental, null);
    try h.require(std.mem.eql(u8, record.payload, try enc.presentation_codec.encodeAlloc(a, stored)), "border fixture full codec equality");
    // Retained outputs are normal native-produced cross-client conformance inputs.
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, ".reader-fixture" }), .data = "Synthetic ordinary Writer image border conformance fixture.\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "image-border-contract.dprd" }), .data = record.payload });
    const json = try h.run(&.{ bin, "lookup", title, "--root", root, "--kind", "supplemental", "--format", "json" }, 0);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "image-border-contract.json" }), .data = json });
    const entry = try h.entry(json);
    var occurrences: usize = 0;
    var bordered: usize = 0;
    for (entry.object.get("sections").?.array.items) |section| for (section.object.get("blocks").?.array.items) |block| for (block.object.get("spans").?.array.items) |span| {
        if (span.object.get("image")) |image| {
            occurrences += 1;
            if (image.object.get("border")) |border| {
                try h.require(border == .bool and border.bool, "border JSON is true-only boolean");
                bordered += 1;
            }
            if (occurrences == 1) {
                try h.require(std.mem.eql(u8, image.object.get("file").?.string, "Flag of Poland.svg") and image.object.get("width_px").?.integer == 40, "flag content size remains40");
                try h.require(std.mem.eql(u8, span.object.get("target").?.string, "File:Flag of Poland.svg"), "border preserves source action");
            }
            if (occurrences == 2) try h.require(image.object.get("border") == null and image.object.get("width_px").?.integer == 30, "book remains borderless30");
        }
    };
    try h.require(occurrences == 4 and bordered == 3, "all image occurrences preserve individual border state");
    const text = try h.run(&.{ bin, "lookup", title, "--root", root, "--kind", "supplemental", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, text, "[image]") != null and std.mem.indexOf(u8, text, "[[File:") == null, "terminal keeps honest image placeholder without source");
    const ffi = try h.run(&.{ ffi_test, root, title, "--image-border" }, 0);
    try h.require(std.mem.indexOf(u8, ffi, "FFI_IMAGE_BORDER_PASS") != null, "ABI8 reads genuine DPRD through supplemental lookup");
}

// Controlled wikitext compiled by the ordinary Writer. Keep the actual Reader
// response and DPRJ payload together for the desktop and Android conformance tests.
fn checkWriterStyledEmptyTable(h: *Harness, bin: []const u8, dir: []const u8) !void {
    const a = h.a;
    const T = enc.presentation_types;
    const root = try std.fs.path.join(a, &.{ dir, "writer-empty-table" });
    const title = "styled-empty-table-contract";
    const authored = "== Empty table contract ==\n" ++
        "{| style='background:#f9f9f9;border:1px solid #aabbcc;border-collapse:collapse;width:120px;padding:3px 4px 5px 6px;margin:7px 8px 9px 10px;float:right;clear:both'\n" ++
        "|+ [[CaptionTarget|Caption link]]\n" ++
        "|- style='display:none'\n| hidden only\n|}\nafter [[Visible|visible action]]";
    // This controlled source has no external stylesheet; retain its inline paint.
    var styles = try encoder.table_style_profile.parseAlloc(a, "");
    defer styles.deinit();
    var writer = try encoder.blob_builder.Writer.init(h.io, a, root);
    defer writer.deinit();
    writer.language_codes.table_styles = &styles;
    // Source-page accounting belongs to the caller, as in the normal build loop.
    writer.stats.pages_seen += 1;
    try writer.addPage(a, .{ .id = 100, .kind = .supplemental }, title, authored, null);
    const stats = try writer.finish(.{});
    try h.require(stats.pages_seen == 1 and stats.supplemental_records == 1 and stats.language_records == 0 and stats.fallback_pages == 0,
        "styled empty table is one ordinary supplemental record with no invented language or fallback");
    const report = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    try h.require(report.len == 0, "styled hidden-row source has no malformed-table or unresolved-style report");
    const blob_path = try std.fs.path.join(a, &.{ root, enc.blob_catalog.featureBlobFilename(.supplemental).? });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(h.io, blob_path, a, .limited(1024 * 1024));
    const blob = try enc.blob_format.inspect(bytes);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find(title)) orelse return error.AssertionFailed;
    try h.require(record.payload.len >= 4 and std.mem.eql(u8, record.payload[0..4], enc.presentation_codec.image_maps_magic),
        "ordinary Writer selects DPRJ for the authored table box fields");
    const stored = try enc.presentation_codec.decodeAlloc(a, record.payload, title, .supplemental, null);
    try T.validateStored(a, stored, title, .supplemental, null);
    try h.require(std.mem.eql(u8, record.payload, try enc.presentation_codec.encodeAlloc(a, stored)),
        "styled empty table preserves complete Writer codec bytes");
    try h.require(stored.entry.language == null and stored.entry.language_code.len == 0 and
        stored.entry.sections.len == 1 and stored.entry.references.len == 0 and stored.entry.media.len == 0,
        "controlled table retains one section without language references or media");
    const section = stored.entry.sections[0];
    try h.require(std.mem.eql(u8, section.title, "Empty table contract") and section.blocks.len == 2,
        "empty table and visible suffix remain separate ordered blocks");
    const table_block = section.blocks[0];
    const table = table_block.table orelse return error.AssertionFailed;
    try h.require(table_block.kind == .table and table_block.spans.len == 0 and table.rows.len == 0 and table.geometry == null,
        "all hidden rows leave a real zero-row table without synthetic cells or legacy geometry");
    const expected_style: T.TableStyle = .{
        .background = "#f9f9f9",
        .border = .{ .solid = .{ .width = .{ .unit = .px, .value = 1 }, .color = "#aabbcc" } },
        .collapse = .collapse,
        .width = .{ .unit = .px, .value = 120 },
        .padding = .{ .top = .{ .unit = .px, .value = 3 }, .right = .{ .unit = .px, .value = 4 }, .bottom = .{ .unit = .px, .value = 5 }, .left = .{ .unit = .px, .value = 6 } },
        .margins = .{ .top = .{ .unit = .px, .value = 7 }, .right = .{ .unit = .px, .value = 8 }, .bottom = .{ .unit = .px, .value = 9 }, .left = .{ .unit = .px, .value = 10 } },
        .float_side = .right,
        .clear = .both,
    };
    const actual_style = table.style orelse return error.AssertionFailed;
    try h.require(std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, expected_style, .{}), try std.json.Stringify.valueAlloc(a, actual_style, .{})),
        "zero rows preserve exact width padding TRBL margins collapse float clear border and background");
    try h.require(table.caption_blocks == null and table.caption.len == 1,
        "single inline caption remains independent of the empty cell grid");
    const caption = table.caption[0];
    try h.require(caption.kind == .link and std.mem.eql(u8, caption.text, "Caption link") and
        std.mem.eql(u8, caption.target, "CaptionTarget") and caption.trail.len == 0,
        "caption label and navigation survive hidden-row filtering");
    const suffix = section.blocks[1];
    try h.require(suffix.kind == .paragraph and suffix.table == null and suffix.flow == null and suffix.figure == null,
        "visible suffix remains an ordinary paragraph after the table");
    var visible: std.ArrayList(u8) = .empty;
    var actions: usize = 0;
    for (suffix.spans) |span| {
        try visible.appendSlice(a, span.text);
        try visible.appendSlice(a, span.trail);
        if (span.target.len != 0) {
            try h.require(span.kind == .link and std.mem.eql(u8, span.target, "Visible"), "suffix retains only its authored local action");
            actions += 1;
        }
    }
    try h.require(actions == 1 and std.mem.eql(u8, visible.items, "after visible action"),
        "visible suffix text and one action are retained in source order");
    const stored_json = try std.json.Stringify.valueAlloc(a, stored.entry, .{});
    try h.require(std.mem.indexOf(u8, stored_json, "hidden only") == null,
        "hidden cell text is absent from every compiled Entry field");
    const json = try h.run(&.{ bin, "lookup", title, "--root", root, "--kind", "supplemental", "--format", "json" }, 0);
    const response = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer response.deinit();
    const entries = response.value.object.get("entries").?.array.items;
    try h.require(response.value.object.get("record_count").?.integer == 1 and
        response.value.object.get("total_matches").?.integer == 1 and entries.len == 1,
        "ordinary Reader returns exactly the generated table record");
    const entry_json = try std.json.Stringify.valueAlloc(a, entries[0], .{});
    const read_entry = try std.json.parseFromSlice(T.Entry, a, entry_json, .{});
    defer read_entry.deinit();
    try T.validateStored(a, .{ .entry = read_entry.value }, title, .supplemental, null);
    try h.require(std.mem.eql(u8, record.payload, try enc.presentation_codec.encodeAlloc(a, T.Stored{ .entry = read_entry.value })),
        "complete normal Reader JSON preserves every Writer body style caption action and codec field");
    // Keep the complete observed response; never replace it with constructed JSON.
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, ".reader-fixture" }), .data = "Controlled styled zero-row table from ordinary Writer and Reader.\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "styled-empty-table-contract.dprj" }), .data = record.payload });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "styled-empty-table-contract.json" }), .data = json });
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
    try checkWriterCellRules(&h, bin, dir);
    const ux_python = init.environ_map.get("WIKIDICT_READER_UX_PYTHON") orelse "python3";
    const ffi_test = argv[2];
    try checkWriterImageBorder(&h, bin, ffi_test, dir);
    try checkWriterStyledEmptyTable(&h, bin, dir);
    const ffi_output = try h.run(&.{ ffi_test, root, "cat" }, 0);
    try h.require(std.mem.indexOf(u8, ffi_output, "FFI_INTEGRATION_PASS") != null, "data-only C ABI");

    const exported = try h.run(&.{ bin, "export", "cat", "--root", root }, 0);
    const export_path = try std.fs.path.join(a, &.{ dir, "fixture.json" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = export_path, .data = exported });

    const complete = try h.entry(try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "json" }, 0));
    const complete_sections = complete.object.get("sections").?.array.items;
    try h.require(complete_sections.len == 7, "complete compiled document");
    for ([_]usize{ 3, 5 }, [_][]const u8{ "Personal", "Demonstratives" }) |index, title| {
        const section = complete_sections[index].object;
        try h.require(std.mem.eql(u8, section.get("title").?.string, title) and
            std.mem.eql(u8, section.get("anchor").?.string, title) and
            section.get("blocks").?.array.items.len == 0, "actual CLI retains anchored empty parent at original compiled index");
    }
    const text = try h.run(&.{ bin, "lookup", "cat", "--root", root }, 0);
    try h.require(std.mem.indexOf(u8, text, "small animal") != null, "compiled definition renders");
    const details_text = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, details_text, "Historical source") != null, "compiled supporting material renders");
    for ([_][]const u8{ "\nPersonal\n", "\nDemonstratives\n", "Personal table token", "Demonstrative table token" }) |expected|
        try h.require(std.mem.count(u8, details_text, expected) == 1, "actual CLI details preserve parent and child table labels exactly once");
    for ([_][]const u8{ "PREAMBLE", "After line break", "column A  column B", "Inflection table", "Reference content.", "Example image.svg", "Example pronunciation.ogg" }) |expected|
        try h.require(std.mem.indexOf(u8, details_text, expected) != null, expected);

    try h.require(std.mem.count(u8, details_text, "Color sample #ffff00") == 1, "plain actual CLI swatch has one readable label");
    try h.require(std.mem.indexOfScalar(u8, details_text, 0x1b) == null, "plain actual CLI emits no color escape");
    try h.require(std.mem.indexOf(u8, details_text, "Valid swatch fallback") == null, "valid typed swatch replaces generic table");
    for ([_][]const u8{ "Malformed swatch fallback", "Unknown swatch fallback" }) |fallback|
        try h.require(std.mem.indexOf(u8, details_text, fallback) != null, "malformed and unknown swatches preserve actual table fallback");
    const swatch_pty = try h.run(&.{ ux_python, "compiler/tools/verify_reader_ux.py", "--binary", bin, "--root", root, "--report", dir, "--swatch-only" }, 0);
    try h.require(std.mem.indexOf(u8, swatch_pty, "CLI_SWATCH_PTY_PASS") != null, "actual pyte swatch sample/reset/narrow/resize/terminal-restoration route");
    try h.require(std.mem.indexOf(u8, swatch_pty, "CLI_ANCHORED_PARENT_PTY_PASS") != null, "actual anchored parent section navigation/folding/narrow terminal route");
    std.debug.print("CLI_SWATCH_PTY_PASS child summary/report: {s}\n", .{swatch_pty});
    const study_root = try std.fs.path.join(a, &.{ dir, "study-blobs" });
    try writeStudyMeaningFixture(init.io, a, study_root);
    const study_pty = try h.run(&.{ ux_python, "compiler/tools/verify_reader_ux.py", "--binary", bin, "--root", study_root, "--report", dir, "--study-only" }, 0);
    try h.require(std.mem.indexOf(u8, study_pty, "CLI_UNSCORED_STUDY_PTY_PASS") != null, "actual missing-meaning state, no grading, Greek body, normal grading and terminal restoration");
    std.debug.print("CLI_UNSCORED_STUDY_PTY_PASS child summary/report: {s}\n", .{study_pty});
    try std.Io.Dir.cwd().deleteTree(init.io, study_root);

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
    const alias_root = try std.fs.path.join(a, &.{ dir, "alias-blobs" });
    try writeAliasFixture(init.io, a, alias_root, false);
    for ([_][]const u8{ "Animus", "Combustible", "County seat", "Gainst" }, [_][]const u8{ "animus", "combustible", "county seat", "gainst" }) |alias, target| {
        const entry = try h.entry(try h.run(&.{ bin, "lookup", alias, "--root", alias_root, "--language", "English", "--case-sensitive", "--format", "json" }, 0));
        try h.require(std.mem.eql(u8, entry.object.get("title").?.string, target), "exact alias selects direct target");
        try h.require(std.mem.eql(u8, entry.object.get("language").?.string, "English"), "alias keeps selected target language");
        const redirect = entry.object.get("redirect").?.object;
        try h.require(std.mem.eql(u8, redirect.get("source_title").?.string, alias) and redirect.get("followed").?.bool, "JSON preserves incoming alias");
    }
    const chain = try h.entry(try h.run(&.{ bin, "lookup", "ChainA", "--root", alias_root, "--format", "json" }, 0));
    try h.require(std.mem.eql(u8, chain.object.get("title").?.string, "ChainB"), "double redirect stops after one hop");
    const incoming = chain.object.get("redirect").?.object;
    const current_alias = chain.object.get("alias").?.object;
    try h.require(std.mem.eql(u8, incoming.get("target_title").?.string, "ChainB") and std.mem.eql(u8, incoming.get("fragment").?.string, "Incoming"), "chain incoming destination retained");
    try h.require(std.mem.eql(u8, current_alias.get("target_title").?.string, "gainst") and std.mem.eql(u8, current_alias.get("fragment").?.string, "Noun"), "displayed alias destination retained");
    const chain_text = try h.run(&.{ bin, "lookup", "ChainA", "--root", alias_root }, 0);
    try h.require(std.mem.indexOf(u8, chain_text, "gainst") != null and std.mem.indexOf(u8, chain_text, "Target definition.") == null, "compact text shows redirect link without following twice");
    _ = try h.run(&.{ bin, "lookup", "ChainA", "--root", alias_root, "--kind", "alias" }, 2);
    _ = try h.run(&.{ bin, "lookup", "ChainA", "--root", alias_root, "--language", "Missing" }, 2);
    const neutral_root = try std.fs.path.join(a, &.{ dir, "neutral-redirects" });
    try writeAliasFixture(init.io, a, neutral_root, true);
    const neutral_json = try h.run(&.{ bin, "lookup", "ChainA", "--root", neutral_root, "--format", "json" }, 0);
    const neutral_response = try std.json.parseFromSlice(std.json.Value, a, neutral_json, .{});
    try h.require(neutral_response.value.object.get("language").? == .null, "neutral response has no fabricated language");
    try h.require(std.mem.eql(u8, neutral_response.value.object.get("kind").?.string, "language"), "internal alias mode is not a public kind");
    const neutral_entry = try h.entry(neutral_json);
    try h.require(std.mem.eql(u8, neutral_entry.object.get("title").?.string, "ChainB") and neutral_entry.object.get("language").? == .null, "neutral chain displays exactly one hop");
    try h.require(std.mem.eql(u8, neutral_entry.object.get("alias").?.object.get("target_title").?.string, "gainst"), "neutral displayed redirect retains next target");
    const neutral_missing = try h.entry(try h.run(&.{ bin, "lookup", "Animus", "--root", neutral_root, "--format", "json" }, 0));
    try h.require(std.mem.eql(u8, neutral_missing.object.get("title").?.string, "Animus") and !neutral_missing.object.get("redirect").?.object.get("followed").?.bool, "neutral missing definition remains its compiled redirect page");
    const neutral_stats = try h.run(&.{ bin, "stats", "--root", neutral_root }, 0);
    try h.require(std.mem.indexOf(u8, neutral_stats, "Redirects") != null and std.mem.indexOf(u8, neutral_stats, "English") == null, "neutral human label is Redirects");
    const neutral_languages = try std.json.parseFromSlice(std.json.Value, a, try h.run(&.{ bin, "languages", "--root", neutral_root, "--format", "json" }, 0), .{});
    try h.require(neutral_languages.value.object.get("languages").?.array.items.len == 0, "neutral mode adds no language menu item");
    _ = try h.run(&.{ bin, "lookup", "ChainA", "--root", neutral_root, "--kind", "alias" }, 2);
    const neutral_ffi = try h.run(&.{ ffi_test, neutral_root, "ChainA", "--neutral" }, 0);
    try h.require(std.mem.indexOf(u8, neutral_ffi, "FFI_NEUTRAL_PASS") != null, "C ABI neutral selection and one-hop routing");
    // Keep observed Writer/Reader contracts and PTY reports for the outer assessor.
    // These three generated data roots have no consumer after the checks above.
    for ([_][]const u8{ root, alias_root, neutral_root }) |generated_root|
        try std.Io.Dir.cwd().deleteTree(init.io, generated_root);
    std.debug.print("READER_INTEGRATION_PASS checks={d}: precompiled fixture, data-only JSON/CLI/FFI, no source/runtime/core fallback. Artifacts: {s}\n", .{ h.checks, dir });
}
