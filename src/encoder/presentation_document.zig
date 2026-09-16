const std = @import("std");
const compiler = @import("presentation_compile.zig");
const semantic = @import("presentation_layout.zig");
const blobs = @import("blob_encoder");
const types = blobs.presentation_types;
const format = blobs.blob_format;
const codec = blobs.presentation_codec;
const A = std.mem.Allocator;

pub const DisplayTitle = struct {
    source: []const u8,
    page_title: []const u8,
};

const WorkSection = struct {
    level: u8,
    title: []const u8,
    blocks: []const compiler.Block,
};
const Work = struct {
    sections: []const WorkSection,
    references: []const compiler.Reference,
    media: []const compiler.media_types.Media,
    rendered_templates: usize,
    unresolved_templates: usize,
};
const Builder = struct {
    a: A,
    renderer: *compiler.Renderer,
    sections: std.ArrayList(WorkSection) = .empty,
    blocks: std.ArrayList(compiler.Block) = .empty,
    title: []const u8,
    level: u8 = 2,
    started: bool = false,

    fn flush(self: *Builder) !void {
        if (!self.started) return;
        try self.sections.append(self.a, .{
            .level = self.level,
            .title = self.title,
            .blocks = try self.blocks.toOwnedSlice(self.a),
        });
        self.blocks = .empty;
    }

    fn render(self: *Builder, source: []const u8) !void {
        for (try self.renderer.renderBody(source)) |item| {
            if (item.kind == .heading) {
                try self.flush();
                self.started = true;
                self.title = try compiler.plainText(self.a, item.spans);
                self.level = item.level;
            } else {
                self.started = true;
                try self.blocks.append(self.a, item);
            }
        }
    }
};
fn workAlloc(a: A, title: []const u8, language: []const u8, source: []const u8) !Work {
    var renderer: compiler.Renderer = .{
        .a = a,
        .context = .{ .title = title, .language = if (language.len == 0) "English" else language },
    };
    var builder: Builder = .{
        .a = a,
        .renderer = &renderer,
        .title = if (language.len == 0) title else language,
    };
    try builder.render(source);
    try builder.flush();
    return .{
        .sections = try builder.sections.toOwnedSlice(a),
        .references = try renderer.finishReferences(),
        .media = try renderer.media.toOwnedSlice(a),
        .rendered_templates = renderer.rendered_templates,
        .unresolved_templates = renderer.unresolved_templates,
    };
}

fn inlineKind(kind: anytype) !types.InlineKind {
    return switch (kind) {
        .text => .text,
        .link => .link,
        .external_link => .external_link,
        .line_break => .line_break,
        .template => error.UncompiledTemplate,
    };
}
fn spansAlloc(a: A, source: []const compiler.Span) ![]types.Span {
    const out = try a.alloc(types.Span, source.len);
    for (source, out) |span, *dest| dest.* = .{
        .kind = try inlineKind(span.kind),
        .text = span.text,
        .target = span.target,
        .trail = span.trail,
        .language = span.language,
        .classes = span.classes,
        .direction = span.direction,
        .bold = span.bold,
        .italic = span.italic,
        .code = span.code,
        .small = span.small,
        .superscript = span.superscript,
        .subscript = span.subscript,
        .strike = span.strike,
        .underline = span.underline,
        .role = std.meta.stringToEnum(types.Role, @tagName(span.role)) orelse return error.InvalidPresentation,
    };
    return out;
}

fn displayTitleSpansAlloc(a: A, display: ?DisplayTitle, language: []const u8) ![]const types.Span {
    const value = display orelse return &.{};
    if (value.source.len == 0) return &.{};
    var renderer: compiler.Renderer = .{
        .a = a,
        .context = .{ .title = value.page_title, .language = if (language.len == 0) "English" else language },
    };
    const spans = try renderer.parseSpans(value.source, .{ .role = .headword });
    for (spans) |span| if (span.kind != .text) return &.{};
    const plain = try compiler.plainText(a, spans);
    if (!std.mem.eql(u8, plain, value.page_title)) return &.{};
    if (renderer.rendered_templates != 0 or renderer.unresolved_templates != 0) return error.UncompiledTemplate;
    return spansAlloc(a, spans);
}

fn tableAlloc(a: A, source: compiler.Table) !types.Table {
    const rows = try a.alloc(types.Row, source.rows.len);
    for (source.rows, rows) |row, *dest_row| {
        const cells = try a.alloc(types.Cell, row.cells.len);
        for (row.cells, cells) |cell, *dest_cell| dest_cell.* = .{
            .spans = try spansAlloc(a, cell.spans),
            .header = cell.header,
            .colspan = cell.colspan,
            .rowspan = cell.rowspan,
        };
        dest_row.* = .{ .cells = cells };
    }
    return .{ .caption = try spansAlloc(a, source.caption), .rows = rows };
}
fn blocksAlloc(a: A, source: []const compiler.Block) ![]types.Block {
    const out = try a.alloc(types.Block, source.len);
    for (source, out) |block, *dest| {
        dest.* = .{
            .kind = std.meta.stringToEnum(types.BlockKind, @tagName(block.kind)) orelse return error.InvalidPresentation,
            .depth = block.depth,
            .spans = try spansAlloc(a, block.spans),
            .list_path = block.list_path,
            .number = block.number,
            .level = block.level,
            .table = if (block.table) |table| try tableAlloc(a, table) else null,
        };
        if (block.feature) |feature| dest.feature = .{
            .kind = feature.kind,
            .language = feature.language,
            .data = feature.data,
            .tail_kind = feature.tail_kind,
            .tail = feature.tail,
        };
    }
    return out;
}

fn sectionsAlloc(a: A, source: []const WorkSection) ![]types.Section {
    const out = try a.alloc(types.Section, source.len);
    for (source, out) |section, *dest| dest.* = .{
        .level = section.level,
        .title = section.title,
        .blocks = try blocksAlloc(a, section.blocks),
    };
    return out;
}

fn layoutAlloc(a: A, source: semantic.Layout) !types.Layout {
    const lexemes = try a.alloc(types.Lexeme, source.lexemes.len);
    for (source.lexemes, lexemes) |lexeme, *dest| {
        const senses = try a.alloc(types.Sense, lexeme.definitions.len);
        for (lexeme.definitions, senses) |sense, *dest_sense| {
            dest_sense.* = .{
                .block = sense.block,
                .parent = sense.parent,
                .examples = sense.examples,
                .quotations = sense.quotations,
                .notes = sense.notes,
                .form = if (sense.form) |form| .{
                    .relation = form.relation,
                    .target = form.target,
                    .language = form.language,
                } else null,
            };
        }
        dest.* = .{
            .language = lexeme.language,
            .kind = lexeme.kind,
            .section = lexeme.section,
            .etymology = lexeme.etymology,
            .definitions = senses,
            .introduction = lexeme.introduction,
            .other_blocks = lexeme.other_blocks,
            .related_sections = lexeme.related_sections,
        };
    }
    return .{ .lexemes = lexemes, .other_sections = source.other_sections };
}

fn referencesAlloc(a: A, source: []const compiler.Reference) ![]types.Reference {
    const out = try a.alloc(types.Reference, source.len);
    for (source, out) |reference, *dest| dest.* = .{
        .number = reference.number,
        .group_number = reference.group_number,
        .name = reference.name,
        .group = reference.group,
        .spans = try spansAlloc(a, reference.spans),
    };
    return out;
}

fn mediaAlloc(a: A, source: []const compiler.media_types.Media) ![]types.Media {
    const out = try a.alloc(types.Media, source.len);
    for (source, out) |media, *dest| dest.* = .{
        .file = media.file,
        .kind = std.meta.stringToEnum(types.MediaKind, @tagName(media.kind)) orelse return error.InvalidPresentation,
        .caption = media.caption,
    };
    return out;
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
    const work = try workAlloc(a, title, language orelse "", source);
    if (work.rendered_templates != 0 or work.unresolved_templates != 0) return error.UncompiledTemplate;
    const sections = try sectionsAlloc(a, work.sections);
    const layout = try layoutAlloc(a, try semantic.build(a, work.sections));
    const stored: types.Stored = .{ .entry = .{
        .organization = layout,
        .title = title,
        .display_title = try displayTitleSpansAlloc(a, display_title, language orelse ""),
        .kind = kind,
        .language = language,
        .language_code = language_code,
        .sections = sections,
        .references = try referencesAlloc(a, work.references),
        .media = try mediaAlloc(a, work.media),
    } };
    return codec.encodeAlloc(a, stored);
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
