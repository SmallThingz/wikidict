const std = @import("std");
const compiler = @import("presentation_compile.zig");
const semantic = @import("presentation_layout.zig");
const blobs = @import("blob_encoder");
const ir = blobs.document_ir;
const types = blobs.presentation_types;
const format = blobs.blob_format;
const codec = blobs.presentation_codec;
const A = std.mem.Allocator;
// Expanded heading templates can leave spacing around decorative media.
// Consume the whole NBSP sequence, never individual UTF-8 continuation bytes.
fn trimHeading(raw: []const u8) []const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    while (std.mem.startsWith(u8, text, "\u{a0}")) text = std.mem.trimStart(u8, text[2..], " \t\r\n");
    while (std.mem.endsWith(u8, text, "\u{a0}")) text = std.mem.trimEnd(u8, text[0 .. text.len - 2], " \t\r\n");
    return text;
}

const ImageRegistry = @import("namespace_registry").image_options.Registry;
const BehaviorRegistry = @import("namespace_registry").behavior_switches.Registry;
const NamespaceRegistry = @import("namespace_registry").Registry;
pub const Fallbacks = @import("presentation_fallback.zig").Report;
pub const ReferenceDefinitions = compiler.ReferenceDefinitions;
pub const referenceDefinitionsAlloc = compiler.referenceDefinitionsAlloc;

fn requireCompiledText(text: []const u8) !void {
    for ([_][]const u8{ "[[", "]]", "{{", "}}", "{|", "|}" }) |token| {
        if (std.mem.indexOf(u8, text, token) != null) {
            return error.UncompiledPresentation;
        }
    }
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '<')) |start| {
        var name = start + 1;
        if (name < text.len and text[name] == '/') name += 1;
        if (name < text.len and std.ascii.isAlphabetic(text[name]) and std.mem.indexOfScalarPos(u8, text, name, '>') != null) {
            return error.UncompiledPresentation;
        }
        at = start + 1;
    }
    at = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '[')) |start| {
        if (start + 1 < text.len and text[start + 1] != '[' and ir.hasExternalProtocol(text[start + 1 ..]))
            return error.UncompiledPresentation;
        at = start + 1;
    }
}

fn requireCompiledSpans(a: A, spans: []const compiler.Span) !void {
    try requireCompiledText(try compiler.plainText(a, spans));
}

fn validateText(text: []const u8, report: ?*Fallbacks) !void {
    requireCompiledText(text) catch |err| {
        if (report) |fallback| {
            fallback.literal_markup = true;
        } else return err;
    };
}

fn validateSpans(a: A, spans: []const compiler.Span, report: ?*Fallbacks) !void {
    if (report == null) for (spans) |span| {
        if (span.kind == .template) return error.UncompiledTemplate;
    };
    if (report) |fallback| {
        // A missing template is a normal red link in MediaWiki. Never serialize
        // its argument body as a custom template instruction.
        for (@constCast(spans)) |*span| if (span.kind == .template) {
            span.kind = .link;
            span.target = try std.fmt.allocPrint(a, "Template:{s}", .{span.target});
            span.text = span.target;
            fallback.missing_template = true;
        };
    }
    var parsed: std.ArrayList(u8) = .empty;
    defer parsed.deinit(a);
    for (spans) |span| {
        if (span.provenance != .parsed) {
            try validateText(parsed.items, report);
            parsed.clearRetainingCapacity();
        } else if (span.kind == .line_break) try parsed.append(a, '\n') else try parsed.appendSlice(a, span.text);
    }
    try validateText(parsed.items, report);
}

pub const DisplayTitle = struct {
    source: []const u8,
    page_title: []const u8,
};

const WorkSection = struct {
    title_spans: []const compiler.Span = &.{},
    level: u8,
    title: []const u8,
    blocks: []const compiler.Block,
};
const Work = struct {
    sections: []const WorkSection,
    references: []const compiler.Reference,
    media: []const compiler.media_types.Media,
    media_caption_spans: []const []const compiler.Span,
    rendered_templates: usize,
    unresolved_templates: usize,
    fallbacks: Fallbacks,
};
const Builder = struct {
    title_spans: []const compiler.Span = &.{},
    a: A,
    renderer: *compiler.Renderer,
    sections: std.ArrayList(WorkSection) = .empty,
    title: []const u8,
    level: u8 = 2,
    started: bool = false,

    fn flush(self: *Builder, blocks: []const compiler.Block) !void {
        if (!self.started) return;
        try self.sections.append(self.a, .{
            .level = self.level,
            .title = self.title,
            .title_spans = self.title_spans,
            .blocks = blocks,
        });
    }

    fn render(self: *Builder, source: []const u8) !void {
        const rendered = try self.renderer.renderBody(source);
        var section_start: usize = 0;
        for (rendered, 0..) |item, i| {
            if (item.kind == .heading) {
                try self.flush(rendered[section_start..i]);
                self.started = true;
                self.title_spans = item.spans;
                self.title = trimHeading(try compiler.plainText(self.a, item.spans));
                self.level = item.level;
                section_start = i + 1;
            } else {
                self.started = true;
            }
        }
        try self.flush(rendered[section_start..]);
    }
};
fn workAlloc(a: A, title: []const u8, language: []const u8, source: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, reference_context: compiler.ReferenceDefinitions) !Work {
    var renderer: compiler.Renderer = .{
        .a = a,
        .context = .{
            .title = title,
            .language = if (language.len == 0) "English" else language,
            .link_trail = link_trail,
            .namespace_catalog = namespace_catalog,
            .behavior_switches = behavior_switches,
            .image_options = image_options,
        },
    };
    renderer.page_reference_definitions = reference_context.items;
    renderer.fallbacks.merge(reference_context.fallbacks);
    var builder: Builder = .{
        .a = a,
        .renderer = &renderer,
        .title = if (language.len == 0) title else language,
    };
    try builder.render(source);
    return .{
        .sections = try builder.sections.toOwnedSlice(a),
        .references = try renderer.finishReferences(),
        .media = try renderer.media.toOwnedSlice(a),
        .media_caption_spans = try renderer.media_caption_spans.toOwnedSlice(a),
        .rendered_templates = renderer.rendered_templates,
        .unresolved_templates = renderer.unresolved_templates,
        .fallbacks = renderer.fallbacks,
    };
}

fn displayTitleSpansAlloc(a: A, display: ?DisplayTitle, language: []const u8, link_trail: ir.LinkTrail, namespace_catalog: ?*const NamespaceRegistry, behavior_switches: ?*const BehaviorRegistry, image_options: ?*const ImageRegistry, fallbacks: ?*Fallbacks) ![]const compiler.Span {
    const value = display orelse return &.{};
    if (value.source.len == 0) return &.{};
    var renderer: compiler.Renderer = .{
        .a = a,
        .context = .{
            .title = value.page_title,
            .language = if (language.len == 0) "English" else language,
            .link_trail = link_trail,
            .namespace_catalog = namespace_catalog,
            .behavior_switches = behavior_switches,
            .image_options = image_options,
        },
    };
    const spans = renderer.parseSpans(value.source, .{ .role = .headword }) catch |err| {
        if (fallbacks) |report| switch (err) {
            error.RenderLimit => {
                report.render_limit = true;
                report.display_title_rejected = true;
                return &.{};
            },
            else => return err,
        } else return err;
    };
    if (fallbacks) |report| report.merge(renderer.fallbacks);
    if (renderer.rendered_templates != 0 or renderer.unresolved_templates != 0) {
        if (fallbacks) |report| {
            report.template_presentation = report.template_presentation or renderer.rendered_templates != 0;
            report.missing_template = report.missing_template or renderer.unresolved_templates != 0;
            report.display_title_rejected = true;
            return &.{};
        }
        return error.UncompiledTemplate;
    }
    for (spans) |span| if (span.kind != .text) {
        if (fallbacks) |report| report.display_title_rejected = true;
        return &.{};
    };
    const plain = try compiler.plainText(a, spans);
    if (!std.mem.eql(u8, plain, value.page_title)) {
        if (fallbacks) |report| report.display_title_rejected = true;
        return &.{};
    }
    return spans;
}

pub fn compileAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
) ![]u8 {
    return compileReportedAlloc(a, title, kind, language, language_code, source, display_title, null);
}

// Explicit publication policy: MediaWiki renders malformed delimiters as
// literal text. This path records that decision; strict compiler callers keep
// rejecting it. Neither path places an executable template in the blob.
pub fn compileReportedAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithLinkTrailAlloc(
        a,
        title,
        kind,
        language,
        language_code,
        source,
        display_title,
        .{},
        null,
        fallbacks,
    );
}

pub fn compileReportedWithLinkTrailAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithBehaviorAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, null, fallbacks);
}

pub fn compileReportedWithBehaviorAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithOptionsAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, null, fallbacks);
}

pub fn compileReportedWithOptionsAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    return compileReportedWithReferencesAlloc(a, title, kind, language, language_code, source, display_title, link_trail, namespace_catalog, behavior_switches, image_options, .{}, fallbacks);
}

pub fn compileReportedWithReferencesAlloc(
    a: A,
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8,
    language_code: []const u8,
    source: []const u8,
    display_title: ?DisplayTitle,
    link_trail: ir.LinkTrail,
    namespace_catalog: ?*const NamespaceRegistry,
    behavior_switches: ?*const BehaviorRegistry,
    image_options: ?*const ImageRegistry,
    reference_context: compiler.ReferenceDefinitions,
    fallbacks: ?*Fallbacks,
) ![]u8 {
    _ = kind;
    _ = language_code;
    const work = try workAlloc(a, title, language orelse "", source, link_trail, namespace_catalog, behavior_switches, image_options, reference_context);
    if (fallbacks) |report| {
        report.merge(work.fallbacks);
        report.template_presentation = report.template_presentation or work.rendered_templates != 0;
        report.missing_template = report.missing_template or work.unresolved_templates != 0;
    } else if (work.rendered_templates != 0 or work.unresolved_templates != 0) return error.UncompiledTemplate;
    const display_spans = try displayTitleSpansAlloc(a, display_title, language orelse "", link_trail, namespace_catalog, behavior_switches, image_options, fallbacks);
    try validateSpans(a, display_spans, fallbacks);
    for (@constCast(work.sections)) |*section| {
        if (section.title_spans.len != 0) {
            try validateSpans(a, section.title_spans, fallbacks);
            section.title = trimHeading(try compiler.plainText(a, section.title_spans));
        } else try validateText(section.title, fallbacks);
        for (section.blocks) |block| {
            try validateSpans(a, block.spans, fallbacks);
            if (block.table) |table| {
                try validateSpans(a, table.caption, fallbacks);
                for (table.rows) |row| for (row.cells) |cell| try validateSpans(a, cell.spans, fallbacks);
            }
        }
    }
    for (work.references) |reference| try validateSpans(a, reference.spans, fallbacks);
    for (work.media_caption_spans, 0..) |caption_spans, index| {
        try validateSpans(a, caption_spans, fallbacks);
        @constCast(work.media)[index].caption = try compiler.plainText(a, caption_spans);
    }
    // Build semantic layout only after recovery has normalized all build-only
    // template spans to their final data-only representation.
    const layout = try semantic.build(a, work.sections);
    return codec.encodeBuildAlloc(a, display_spans, work.sections, layout, work.references, work.media);
}

test "shipped presentation accepts protected literal examples as compiled data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { source: []const u8, visible: []const u8 }{
        .{ .source = "<nowiki>{{w:Missing|label}}</nowiki>", .visible = "{{w:Missing|label}}" },
        .{ .source = "<pre>[[raw link]]</pre>", .visible = "[[raw link]]" },
        .{ .source = "<nowiki><span>raw</span></nowiki>", .visible = "<span>raw</span>" },
        .{ .source = "&#91;&#91;Episode 4&#93;&#93;", .visible = "[[Episode 4]]" },
    };
    for (cases) |case| {
        const encoded = try compileAlloc(a, "entry", .language, "English", "en", case.source, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        var text: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections[0].blocks[0].spans) |span| try text.appendSlice(a, span.text);
        try std.testing.expectEqualStrings(case.visible, text.items);
    }
}

test "reported publication audits malformed external link syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A [https://example.test broken link.\n";
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", source, null));

    var report: Fallbacks = .{};
    _ = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &report);
    try std.testing.expect(report.literal_markup);
}

test "builder sections borrow contiguous rendered block slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try workAlloc(a, "page", "English", "preamble\n===First===\n# one\n===Second===\n===Third===\n# three\n", .{}, null, null, null, .{});
    try std.testing.expectEqual(@as(usize, 4), work.sections.len);
    try std.testing.expectEqualStrings("English", work.sections[0].title);
    try std.testing.expectEqual(@as(usize, 1), work.sections[0].blocks.len);
    try std.testing.expectEqualStrings("First", work.sections[1].title);
    try std.testing.expectEqual(@as(usize, 1), work.sections[1].blocks.len);
    try std.testing.expectEqualStrings("Second", work.sections[2].title);
    try std.testing.expectEqual(@as(usize, 0), work.sections[2].blocks.len);
    try std.testing.expectEqualStrings("Third", work.sections[3].title);
    try std.testing.expectEqual(@as(usize, 1), work.sections[3].blocks.len);
}

test "compiled presentation contains no executable template syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A [[cat|feline]].\n";
    const bytes = try compileAlloc(a, "cat", .language, "English", "en", source, null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{{") == null);
    const parsed = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings(types.schema, parsed.schema);
    try std.testing.expectEqualStrings("cat", parsed.entry.title);
    try std.testing.expectEqual(types.BlockKind.definition, parsed.entry.sections[1].blocks[0].kind);

    var registry = try NamespaceRegistry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n" ++
        "6\tLêer\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n" ++
        "10\tSjabloon\tTemplate\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n");
    defer registry.deinit();
    // Expanded forms of the actual AF pronunciation, noun and definition templates.
    const heading_source = "==Engels==\n" ++
        "===[[Lêer:Nuvola apps edu languages.svg|30px]] [[uitspraak|Uitspraak]]===\n" ++
        "=== [[Lêer:Open book 01.svg|35px]] [[selfstandige naamwoord|Selfstandige naamwoord]] ===\n" ++
        "====&nbsp;&nbsp;&nbsp;[[Lêer:Crystal Clear app kedit.svg|25px]] [[betekenis|Betekenisse]]====\n" ++
        "# (anatomie) [[rugmurg|Rugmurg]]\n" ++
        "===[[Lêer:Icon.svg|alt=Speech]]&nbsp;===\n" ++
        "===[[Lêer:Icon.svg|alt=Speech|Caption]]===\n" ++
        "===[[:Lêer:Icon.svg]]===\n" ++
        "[[Lêer:Body.jpg|20px]]\n" ++
        "===\u{4e20}===\n" ++
        "===\u{feff}Literal\u{feff}===\n";
    var report: Fallbacks = .{};
    const heading_bytes = try compileReportedWithLinkTrailAlloc(a, "spinal cord", .language, "Engels", "en", heading_source, null, .{}, &registry, &report);
    const heading_page = try codec.decodeAlloc(a, heading_bytes, "spinal cord", .language, .{ .code = "en", .heading = "Engels" });
    const expected_titles = [_][]const u8{ "Engels", "Uitspraak", "Selfstandige naamwoord", "Betekenisse", "Speech", "Caption", "Lêer:Icon.svg", "\u{4e20}", "\u{feff}Literal\u{feff}" };
    try std.testing.expectEqual(expected_titles.len, heading_page.entry.sections.len);
    for (expected_titles, heading_page.entry.sections) |expected, section| try std.testing.expectEqualStrings(expected, section.title);
    try std.testing.expectEqual(types.BlockKind.definition, heading_page.entry.sections[3].blocks[0].kind);
    try std.testing.expectEqualStrings("(anatomie) ", heading_page.entry.sections[3].blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("Rugmurg", heading_page.entry.sections[3].blocks[0].spans[1].text);
    try std.testing.expectEqualStrings("Body.jpg", heading_page.entry.sections[6].blocks[0].spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), heading_page.entry.media.len);
    try std.testing.expectEqualStrings("Body.jpg", heading_page.entry.media[0].file);
    try std.testing.expectEqualStrings("Body.jpg", heading_page.entry.media[0].caption);
    try std.testing.expect(!report.any());
}

test "edition link trail survives compiled presentation encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const trail: ir.LinkTrail = .{
        .contains_fn = struct {
            fn contains(_: ?*const anyopaque, cp: u21) bool {
                return cp == 'ы';
            }
        }.contains,
    };
    const source = "==English==\n===Noun===\n# [[кот]]ыZ\n";
    const bytes = try compileReportedWithLinkTrailAlloc(
        a,
        "entry",
        .language,
        "English",
        "en",
        source,
        null,
        trail,
        null,
        null,
    );
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    const spans = parsed.entry.sections[1].blocks[0].spans;
    var linked_trail = false;
    for (spans) |span| {
        if (std.mem.eql(u8, span.text, "ы")) {
            linked_trail = span.kind == .link and std.mem.eql(u8, span.target, "кот");
        }
    }
    try std.testing.expect(linked_trail);
}

test "display titles compile to semantic spans after page-title validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A word.\n";
    const bytes = try compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "<span class=\"Latn headword\" lang=\"en\" dir=\"ltr\"><i>cat</i></span>",
        .page_title = "cat",
    });
    const parsed = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 1), parsed.entry.display_title.len);
    try std.testing.expectEqualStrings("cat", parsed.entry.display_title[0].text);
    try std.testing.expect(parsed.entry.display_title[0].italic);
    try std.testing.expectEqualStrings("Latn headword", parsed.entry.display_title[0].classes);
    try std.testing.expectEqualStrings("en", parsed.entry.display_title[0].language);
    try std.testing.expectEqualStrings("ltr", parsed.entry.display_title[0].direction);
    try std.testing.expectEqual(types.Role.headword, parsed.entry.display_title[0].role);

    const ignored = try compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "<b>dog</b>",
        .page_title = "cat",
    });
    const ignored_parsed = try codec.decodeAlloc(a, ignored, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), ignored_parsed.entry.display_title.len);

    const linked = try compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "[[cat]]",
        .page_title = "cat",
    });
    const linked_parsed = try codec.decodeAlloc(a, linked, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), linked_parsed.entry.display_title.len);
}

test "reported display title rejection falls back to canonical title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# A word.\n";

    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "{{MissingDisplayTitle}}",
        .page_title = "cat",
    }));

    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "{{MissingDisplayTitle}}",
        .page_title = "cat",
    }, &report);
    try std.testing.expect(report.display_title_rejected);
    try std.testing.expect(report.missing_template);
    const parsed = try codec.decodeAlloc(a, bytes, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), parsed.entry.display_title.len);

    var linked_report: Fallbacks = .{};
    const linked = try compileReportedAlloc(a, "cat", .language, "English", "en", source, .{
        .source = "[[cat]]",
        .page_title = "cat",
    }, &linked_report);
    try std.testing.expect(linked_report.display_title_rejected);
    const linked_parsed = try codec.decodeAlloc(a, linked, "cat", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqual(@as(usize, 0), linked_parsed.entry.display_title.len);
}

test "unknown templates are rejected at bundle time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# {{definitely-unknown-template|x}}\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, null));
}

test "known presentation templates cannot bypass bundle expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# {{lb|en|rare}} A [[cat]].\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, null));
}

test "partially renderable unsupported citation templates still fail publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==English==\n===Noun===\n# {{RQ:Unknown Work|page=17|passage=The '''[[cat]]''' sleeps.}}\n";
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source, null));
}

test "template parse limits fail publication instead of preserving executable syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "==English==\n===Noun===\n# {{oversized");
    for (0..16_385) |_| try source.appendSlice(a, "|x");
    try source.appendSlice(a, "}} tail\n");
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "cat", .language, "English", "en", source.items, null));
}

test "reported recovery matches MediaWiki literal and formatting fixtures" {
    // Live oracle: tools/check_mediawiki_recovery.py and its fixture file.
    const cases = [_][2][]const u8{
        .{ "A [[-", "A [[-" },
        .{ "B ]]word]]", "B ]]word]]" },
        .{ "C <small>x<small> y", "C x y" },
        .{ "D [[]] E", "D [[]] E" },
        .{ "|}\nAfter", "|} After" },
        .{ "{|\n* [[one]]\n|}", "one" },
        .{ "X <script>y</script> Z", "X <script>y</script> Z" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report: Fallbacks = .{};
        const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", case[0], null, &report);
        const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
        var text: std.ArrayList(u8) = .empty;
        for (parsed.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
        };
        try std.testing.expectEqualStrings(case[1], text.items);
        try std.testing.expect(report.any());
    }
}

test "missing template recovery emits a data-only red link without argument source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report: Fallbacks = .{};
    const bytes = try compileReportedAlloc(a, "entry", .language, "English", "en", "{{MissingFixture|secret_argument_body}}", null, &report);
    try std.testing.expect(report.missing_template);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret_argument_body") == null);
    const parsed = try codec.decodeAlloc(a, bytes, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("Template:MissingFixture", parsed.entry.sections[0].blocks[0].spans[0].text);
}

test "localized behavior registry reaches compiled presentation roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const behavior = @import("namespace_registry").behavior_switches;
    const raw = behavior.header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\n";
    var registry = try behavior.Registry.init(a, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer registry.deinit();
    const encoded = try compileReportedWithBehaviorAlloc(a, "entry", .language, "English", "en", "# a＿＿目次非表示＿＿b", null, .{}, null, &registry, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    var text: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections[0].blocks[0].spans) |span| try text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("ab", text.items);
}

test "literal provenance never authorizes malformed parsed suffixes or split delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UncompiledPresentation, compileAlloc(a, "entry", .language, "English", "en", "<nowiki>{{example}}</nowiki> [[broken", null));
    const spans = [_]compiler.Span{ .{ .text = "{" }, .{ .text = "{uncompiled}}", .flags = .{ .bold = true } } };
    try std.testing.expectError(error.UncompiledPresentation, validateSpans(a, &spans, null));
    var report: Fallbacks = .{};
    _ = try compileReportedAlloc(a, "entry", .language, "English", "en", "<nowiki>{{example}}</nowiki> [[broken", null, &report);
    try std.testing.expect(report.literal_markup);
    try std.testing.expectError(error.UncompiledTemplate, compileAlloc(a, "entry", .language, "English", "en", "<code>{{missing}}</code>", null));
}

test "literal provenance survives headings references table cells and media captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==<nowiki>{{heading}}</nowiki>==\n# definition<ref><nowiki>{{reference}}</nowiki></ref>\n<table><tr><td><nowiki>{{cell}}</nowiki></td></tr></table>\n[[File:test.png|<nowiki>{{caption}}</nowiki>]]";
    const encoded = try compileAlloc(a, "entry", .language, "English", "en", source, null);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("{{heading}}", decoded.entry.sections[0].title);
    try std.testing.expectEqualStrings("{{reference}}", decoded.entry.references[0].spans[0].text);
    try std.testing.expectEqualStrings("{{caption}}", decoded.entry.media[0].caption);
}

test "literal provenance preserves structural templates line breaks and normalized captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const template_spans = try a.dupe(compiler.Span, &.{.{ .kind = .template, .target = "Missing", .text = "stale argument", .provenance = .protected_literal }});
    try std.testing.expectError(error.UncompiledTemplate, validateSpans(a, template_spans, null));
    var report: Fallbacks = .{};
    try validateSpans(a, template_spans, &report);
    try std.testing.expectEqual(ir.InlineKind.link, template_spans[0].kind);
    try std.testing.expectEqualStrings("Template:Missing", template_spans[0].text);
    try std.testing.expect(report.missing_template);
    const breaks = [_]compiler.Span{ .{ .text = "{" }, .{ .kind = .line_break, .text = "" }, .{ .text = "{example}" } };
    try validateSpans(a, &breaks, null);
    var renderer: compiler.Renderer = .{ .a = a, .context = .{} };
    const source = "[[File:test.png|a<br>b {{Missing}}]]";
    const label_spans = try renderer.parseSpans(source, .{});
    try std.testing.expectEqualStrings("a\nb [unavailable template: Missing]", try compiler.plainText(a, label_spans));
    var caption_report: Fallbacks = .{};
    const encoded = try compileReportedAlloc(a, "entry", .language, "English", "en", source, null, &caption_report);
    const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
    try std.testing.expectEqualStrings("a\nb Template:Missing", decoded.entry.media[0].caption);
    try std.testing.expect(caption_report.missing_template);
}

test "localized image options reach serialized media captions without swallowing case-sensitive text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const images = @import("namespace_registry").image_options;
    const raw = images.header ++ "\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n# behavior-switches-sha256\t1111111111111111111111111111111111111111111111111111111111111111\nimg_right\t1\t\"rechts\"\nimg_thumbnail\t1\t\"miniatur\"\nimg_thumbnail\t1\t\"thumb\"\nimg_alt\t1\t\"alternativtext=$1\"\nimg_width\t1\t\"$1px\"\n";
    var registry = try images.Registry.init(a, raw, "dewiktionary", "20261001", "de", @splat(0), @splat(0x11));
    defer registry.deinit();
    const cases = [_]struct { source: []const u8, caption: []const u8 }{
        .{ .source = "[[File:Example.jpg|miniatur|CaptionProbeAlpha|rechts]]", .caption = "CaptionProbeAlpha" },
        .{ .source = "[[File:Example.jpg|miniatur|CaptionProbeBeta|alternativtext=OnlyAltProbe]]", .caption = "CaptionProbeBeta" },
        .{ .source = "[[File:Example.jpg|thumb|THUMB]]", .caption = "THUMB" },
        .{ .source = "[[File:Example.jpg|caption|0px]]", .caption = "0px" },
    };
    for (cases) |case| {
        const encoded = try compileReportedWithOptionsAlloc(a, "entry", .language, "English", "en", case.source, null, .{}, null, null, &registry, null);
        const decoded = try codec.decodeAlloc(a, encoded, "entry", .language, .{ .code = "en", .heading = "English" });
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
        try std.testing.expectEqualStrings(case.caption, decoded.entry.media[0].caption);
    }
}

test "malformed redundant attribute quote preserves semantic heading and protected literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exact Plantía:-de- revision 309509 markup; source-instantiated, not
    // captured whole-page expansion. Live action=parse normalizes this tag.
    const markup = "<span style=\"color:#6b5a40;\"\">'''Alemán'''</span>";
    const work = try workAlloc(a, "asturisch", "alemán", "=" ++ markup ++ "=\n# [[asturianu|Asturianu]], d'[[Asturies]].\n", .{}, null, null, null, .{});
    try std.testing.expectEqual(@as(usize, 1), work.sections.len);
    try std.testing.expectEqualStrings("Alemán", work.sections[0].title);
    try std.testing.expectEqual(@as(u8, 1), work.sections[0].level);
    try std.testing.expect(work.sections[0].title_spans[0].flags.bold);
    try std.testing.expectEqualStrings("Asturianu, d'Asturies.", try compiler.plainText(a, work.sections[0].blocks[0].spans));
    var asturianu_links: usize = 0;
    var asturies_links: usize = 0;
    for (work.sections[0].blocks[0].spans) |span| {
        if (std.mem.eql(u8, span.target, "asturianu")) asturianu_links += 1;
        if (std.mem.eql(u8, span.target, "Asturies")) asturies_links += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), asturianu_links);
    try std.testing.expectEqual(@as(usize, 1), asturies_links);
    const protected = try workAlloc(a, "page", "alemán", "=<nowiki>" ++ markup ++ "</nowiki>=\n# retained\n", .{}, null, null, null, .{});
    try std.testing.expectEqualStrings(markup, protected.sections[0].title);
    const unclosed = try workAlloc(a, "page", "alemán", "=<span title=\"unterminated>Alemán=\n# retained\n", .{}, null, null, null, .{});
    try std.testing.expectEqualStrings("<span title=\"unterminated>Alemán", unclosed.sections[0].title);
}

test "ruby strict compiled record preserves readable annotation and existing typed spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "==Japanese==\n===Usage===\n" ++
        "日とは<ruby>実<rt>じつ</rt></ruby>である\n\n" ++
        "七月に<ruby>心宿<rt>なかごぼし</rt></ruby>が天頂を過ぎ\n\n" ++
        "月光を<ruby lang='ja'>[[看]]<rt>''[[み]]''</rt></ruby>る\n\n" ++
        "<ruby>字<rp>[</rp><rt>じ</rt><rp>]</rp></ruby>\n\n" ++
        "<nowiki><ruby>保護<rt>ほご</rt></ruby></nowiki>\n";
    const bytes = try compileAlloc(a, "Ruby source excerpts", .language, "Japanese", "ja", source, null);
    const parsed = try codec.decodeAlloc(a, bytes, "Ruby source excerpts", .language, .{ .code = "ja", .heading = "Japanese" });
    try std.testing.expectEqualStrings(types.schema, parsed.schema);
    var text: std.ArrayList(u8) = .empty;
    var reading_link = false;
    for (parsed.entry.sections) |section| for (section.blocks) |block| {
        for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.text, "み")) reading_link = span.kind == .link and std.mem.eql(u8, span.target, "み") and span.italic and std.mem.eql(u8, span.language, "ja");
        }
        try text.append(a, '\n');
    };
    for ([_][]const u8{ "日とは実（じつ）である", "七月に心宿（なかごぼし）が天頂を過ぎ", "月光を看（み）る", "字[じ]", "<ruby>保護<rt>ほご</rt></ruby>" }) |expected|
        try std.testing.expect(std.mem.indexOf(u8, text.items, expected) != null);
    try std.testing.expect(reading_link);
}
