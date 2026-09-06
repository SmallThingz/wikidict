//! Runtime-only presentation model shared by terminal, HTML, and JSON consumers.
//! Text borrows the mapped blob where possible; OwnedEntry owns auxiliary arrays.
const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const ir = enc.document_ir;
const wiki = @import("wikitext.zig");
const Allocator = std.mem.Allocator;
pub const entry_layout = @import("entry_layout.zig");

pub const Feature = wiki.Feature;
pub const Block = wiki.Block;
pub const Section = struct { level: u8, title: []const u8, blocks: []const Block, deferred: ?enc.language_parts.Kind = null };
pub const Expansion = struct { backend: []const u8 = "lua-vm", status: enum { ok, failed }, diagnostic: ?[]const u8 = null };
pub const Entry = struct {
    content: enum { complete, core } = .complete,
    organization: entry_layout.Layout = .{},
    expansion: ?Expansion = null,
    title: []const u8,
    kind: enc.blob_format.BlobKind,
    language: ?[]const u8 = null,
    language_code: []const u8 = "",
    sections: []const Section = &.{},
    preamble: []const u8 = "",
    unexpanded_templates: usize = 0,
    rendered_templates: usize = 0,
    preamble_spans: []const wiki.Span = &.{},
    references: []const wiki.Reference = &.{},
    status: enum { structured, raw, invalid_payload } = .structured,
    source: ?[]const u8 = null,
    source_base64: ?[]const u8 = null,
    payload_base64: ?[]const u8 = null,
};
pub const OwnedEntry = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *OwnedEntry) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn sourceAlloc(a: Allocator, record: dec.BlobRecordView) ![]u8 {
    return switch (record) {
        .language => |r| enc.language_blob_encoding.decodeAlloc(a, r.payload, .{ .heading = r.metadata.heading, .code = r.metadata.code }),
        .thesaurus => |r| enc.thesaurus_encoding.decodeAlloc(a, r.payload),
        .rhymes => |r| enc.rhymes_encoding.decodeAlloc(a, r.payload),
        .reconstruction => |r| enc.reconstruction_encoding.decodeAlloc(a, r.payload, r.title),
        .citations, .sign_gloss => |r| a.dupe(u8, r.source),
        .supplement => return error.InvalidEncoding,
    };
}

pub fn payload(record: dec.BlobRecordView) []const u8 {
    return switch (record) {
        .language => |r| r.payload,
        .thesaurus => |r| r.payload,
        .rhymes => |r| r.payload,
        .reconstruction => |r| r.payload,
        .citations, .sign_gloss => |r| r.source,
        .supplement => |r| r.payload,
    };
}

pub fn utf8Text(a: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch 0;
        if (n != 0 and n <= bytes.len - pos and std.unicode.utf8ValidateSlice(bytes[pos..][0..n])) {
            try out.appendSlice(a, bytes[pos..][0..n]);
            pos += n;
        } else {
            try out.appendSlice(a, "\xef\xbf\xbd");
            pos += 1;
        }
    }
    return out.toOwnedSlice(a);
}
fn base64(a: Allocator, bytes: []const u8) ![]const u8 {
    const codec = std.base64.standard.Encoder;
    const result = try a.alloc(u8, codec.calcSize(bytes.len));
    return codec.encode(result, bytes);
}

const Builder = struct {
    a: Allocator,
    sections: std.ArrayList(Section) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    title: []const u8 = "Entry",
    level: u8 = 2,
    renderer: *wiki.Renderer,
    pending_raw: std.ArrayList(u8) = .empty,
    started: bool = false,
    allow_deferred: bool = false,
    deferred: ?enc.language_parts.Kind = null,

    fn flush(self: *Builder) !void {
        try self.sections.append(self.a, .{ .level = self.level, .title = self.title, .blocks = try self.blocks.toOwnedSlice(self.a), .deferred = self.deferred });
        self.deferred = null;
    }
    fn heading(self: *Builder, level: u8, title: []const u8) !void {
        if (self.started) try self.flush();
        self.started = true;
        self.title = try utf8Text(self.a, title);
        self.level = level;
    }
    fn block(self: *Builder, input: ir.DecodedBlock, feature: ?Feature) !void {
        self.started = true;
        const text = try utf8Text(self.a, input.text);
        try self.blocks.append(self.a, .{ .kind = std.meta.stringToEnum(wiki.Kind, @tagName(input.kind)).?, .depth = input.depth, .text = text, .spans = try self.renderer.parseSpans(text, .{}), .feature = feature });
    }
    fn raw(self: *Builder, source: []const u8) !void {
        for (try self.renderer.renderBody(try utf8Text(self.a, source))) |item| {
            if (item.kind == .heading) {
                if (self.started) try self.flush();
                self.started = true;
                self.title = try wiki.plainText(self.a, item.spans);
                self.level = item.level;
            } else {
                self.started = true;
                try self.blocks.append(self.a, item);
            }
        }
    }
    fn rawLine(self: *Builder, line: []const u8) !void {
        try self.pending_raw.appendSlice(self.a, line);
        try self.pending_raw.append(self.a, '\n');
    }
    fn flushRaw(self: *Builder) !void {
        if (self.pending_raw.items.len == 0) return;
        try self.raw(self.pending_raw.items);
        self.pending_raw = .empty;
    }
    fn language(self: *Builder, it_ptr: *enc.language_blob_encoding.SectionIterator) !void {
        while (try it_ptr.next()) |s| {
            if (s.external != null and !self.allow_deferred) return error.InvalidEncoding;
            if (self.started) try self.flush();
            self.started = true;
            self.title = try utf8Text(self.a, s.title);
            self.level = s.level;
            self.deferred = s.external;
            if (s.external == null) try self.raw(s.content());
        }
    }
    fn term(self: *Builder, text: []const u8, language_code: []const u8, tail_kind: []const u8, tail: []const u8) !void {
        const data = try utf8Text(self.a, text);
        const suffix = try utf8Text(self.a, tail);
        const link = try std.fmt.allocPrint(self.a, "{{{{l|{s}|{s}}}}}", .{ language_code, data });
        const stem = if (std.mem.startsWith(u8, tail_kind, "plural_")) try std.fmt.allocPrint(self.a, "{s}s", .{link}) else link;
        const display = if (suffix.len == 0) stem else try std.fmt.allocPrint(self.a, "{s} ({s})", .{ stem, suffix });
        try self.block(.{ .kind = .list_item, .depth = 1, .text = display }, .{
            .kind = "term",
            .language = try utf8Text(self.a, language_code),
            .data = data,
            .tail_kind = tail_kind,
            .tail = suffix,
        });
    }
};

pub fn fromRecord(allocator: Allocator, record: dec.BlobRecordView, include_source: bool) !OwnedEntry {
    return recordDocument(allocator, record, include_source, false);
}

/// A deliberately partial presentation; unresolved section bodies are never empty source.
/// Exact source and VM expansion must use the resolved record path instead.
pub fn fromCoreRecord(allocator: Allocator, record: dec.BlobRecordView) !OwnedEntry {
    return recordDocument(allocator, record, false, true);
}

fn recordDocument(allocator: Allocator, record: dec.BlobRecordView, include_source: bool, core_only: bool) !OwnedEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var entry: Entry = .{ .title = try utf8Text(a, record.title()), .kind = record.kind() };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = entry.title } };
    var builder: Builder = .{ .a = a, .renderer = &renderer, .allow_deferred = core_only };
    populate(&builder, record, &entry) catch |err| switch (err) {
        error.InvalidEncoding => {
            entry.status = .invalid_payload;
            entry.payload_base64 = try base64(a, payload(record));
            return .{ .arena = arena, .entry = entry };
        },
        else => return err,
    };
    try builder.flush();
    entry.sections = try builder.sections.toOwnedSlice(a);
    entry.organization = try entry_layout.build(a, entry.sections);
    for (entry.sections) |section| if (section.deferred != null) {
        entry.content = .core;
        break;
    };
    entry.preamble_spans = try renderer.parseSpans(entry.preamble, .{});
    entry.references = try renderer.finishReferences();
    entry.unexpanded_templates = renderer.unresolved_templates;
    entry.rendered_templates = renderer.rendered_templates;
    if (include_source) {
        const source = try sourceAlloc(a, record);
        if (std.unicode.utf8ValidateSlice(source)) entry.source = source else entry.source_base64 = try base64(a, source);
    }
    return .{ .arena = arena, .entry = entry };
}

fn populate(b: *Builder, record: dec.BlobRecordView, entry: *Entry) !void {
    switch (record) {
        .supplement => return error.InvalidEncoding,
        .language => |r| {
            entry.language = try utf8Text(b.a, r.metadata.heading);
            entry.language_code = try utf8Text(b.a, r.metadata.code);
            b.renderer.context.language = entry.language.?;
            var it = try r.sectionIterator();
            entry.preamble = try utf8Text(b.a, it.preamble());
            try b.language(&it);
        },
        .reconstruction => |r| {
            if (try r.sectionIterator()) |sections| {
                var it = sections;
                entry.language = try utf8Text(b.a, it.language.heading);
                entry.preamble = try utf8Text(b.a, it.preamble());
                try b.language(&it);
            } else {
                entry.status = .raw;
                try b.raw((try r.inspect()).body);
            }
        },
        .citations, .sign_gloss => |r| {
            entry.status = .raw;
            try b.raw(r.source);
        },
        .thesaurus => |r| {
            var it = try r.recordIterator();
            while (try it.next()) |item| {
                if (item.kind == .raw_line) {
                    try b.rawLine(item.data);
                    continue;
                }
                if (item.kind == .blank) {
                    try b.rawLine("");
                    continue;
                }
                try b.flushRaw();
                switch (item.kind) {
                    .raw_line => unreachable,
                    .relation => try b.heading(3, @tagName(item.relation.?)),
                    .sense => try b.heading(3, item.data),
                    .header => if (item.data.len != 0) {
                        try b.heading(2, item.data);
                    },
                    .term => try b.term(item.data, item.language, @tagName(item.tail_kind), item.tail),
                    .topic => try b.block(.{ .kind = .paragraph, .depth = 0, .text = item.data }, .{ .kind = "topic", .language = try utf8Text(b.a, item.language), .data = try utf8Text(b.a, item.data) }),
                    .blank, .list_begin, .list_end => {},
                }
            }
            try b.flushRaw();
        },
        .rhymes => |r| {
            var it = try r.recordIterator();
            while (try it.next()) |item| {
                if (item.kind == .raw_line) {
                    try b.rawLine(item.data);
                    continue;
                }
                if (item.kind == .blank) {
                    try b.rawLine("");
                    continue;
                }
                try b.flushRaw();
                switch (item.kind) {
                    .raw_line => unreachable,
                    .heading => try b.heading(3, switch (item.heading.?) {
                        .pronunciation => "Pronunciation",
                        .rhymes => "Rhymes",
                        .partial_rhymes => "Partial rhymes",
                        .notes => "Notes",
                        .see_also => "See also",
                        .syllable => |n| try std.fmt.allocPrint(b.a, "{d} syllable(s)", .{n}),
                    }),
                    .links => {
                        var links = item.linkIterator().?;
                        while (try links.next()) |link| try b.term(link, item.language, @tagName(item.tail_kind), item.tail);
                    },
                    .navigation => try b.block(.{ .kind = .paragraph, .depth = 0, .text = item.data }, .{ .kind = "navigation", .language = try utf8Text(b.a, item.language), .data = try utf8Text(b.a, item.data) }),
                    .blank, .list_boundary => {},
                }
            }
            try b.flushRaw();
        },
    }
}

test "presentation uses semantic sections and preserves exact optional source" {
    const a = std.testing.allocator;
    const source = "==English==\n===Noun===\n# A '''small''' [[cat|animal]].\n#: An example.\n{{unknown|x}}\n";
    const encoded = try enc.language_blob_encoding.encodeAlloc(a, source, .{ .heading = "English" });
    defer a.free(encoded);
    var doc = try fromRecord(a, .{ .language = .{ .title = "cat", .payload = encoded, .metadata = .{ .code = "en", .heading = "English" } } }, true);
    defer doc.deinit();
    try std.testing.expectEqualStrings(source, doc.entry.source.?);
    try std.testing.expectEqualStrings("en", doc.entry.language_code);
    try std.testing.expectEqual(@as(usize, 2), doc.entry.sections.len);
    try std.testing.expectEqual(wiki.Kind.definition, doc.entry.sections[1].blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 1), doc.entry.unexpanded_templates);
}
test "presentation keeps arbitrary raw bytes lossless and invalid semantic payload explicit" {
    const a = std.testing.allocator;
    var raw = try fromRecord(a, .{ .citations = .{ .title = "a", .source = "\xff\x00\x1b" } }, true);
    defer raw.deinit();
    try std.testing.expectEqualStrings("/wAb", raw.entry.source_base64.?);
    try std.testing.expect(raw.entry.source == null);
    var invalid = try fromRecord(a, .{ .thesaurus = .{ .title = "a", .payload = "\xff" } }, true);
    defer invalid.deinit();
    try std.testing.expectEqual(.invalid_payload, invalid.entry.status);
    try std.testing.expectEqualStrings("/w==", invalid.entry.payload_base64.?);
}
fn allocationCase(a: Allocator) !void {
    var doc = try fromRecord(a, .{ .citations = .{ .title = "test", .source = "# [[cat]] {{x}}\n" } }, true);
    defer doc.deinit();
}
test "presentation frees every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

/// Render a standalone wikitext fragment without building/loading any dictionary blob.
pub fn fromWikitext(allocator: Allocator, title: []const u8, language: []const u8, source: []const u8, include_source: bool) !OwnedEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owned_source = try a.dupe(u8, source);
    var entry: Entry = .{ .title = try utf8Text(a, try a.dupe(u8, title)), .kind = .language, .language = try utf8Text(a, try a.dupe(u8, language)) };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = entry.title, .language = entry.language.? } };
    var builder: Builder = .{ .a = a, .renderer = &renderer, .title = entry.language.? };
    try builder.raw(owned_source);
    try builder.flush();
    entry.sections = try builder.sections.toOwnedSlice(a);
    entry.organization = try entry_layout.build(a, entry.sections);
    entry.references = try renderer.finishReferences();
    entry.rendered_templates = renderer.rendered_templates;
    entry.unexpanded_templates = renderer.unresolved_templates;
    if (include_source) {
        if (std.unicode.utf8ValidateSlice(owned_source)) entry.source = owned_source else entry.source_base64 = try base64(a, owned_source);
    }
    return .{ .arena = arena, .entry = entry };
}

test "standalone wikitext produces a rendered document while retaining byte-exact source" {
    const source = "==English==\n===Noun===\n#{{lb|en|rare}} A '''{{m|en|cat}}''' &amp; a dog.<ref>''Book'', 2020.</ref>\n";
    var doc = try fromWikitext(std.testing.allocator, "feline", "English", source, true);
    defer doc.deinit();
    try std.testing.expectEqualStrings(source, doc.entry.source.?);
    try std.testing.expectEqualStrings("Noun", doc.entry.sections[1].title);
    try std.testing.expectEqual(@as(usize, 2), doc.entry.rendered_templates);
    try std.testing.expectEqual(@as(usize, 0), doc.entry.unexpanded_templates);
    try std.testing.expectEqual(@as(usize, 1), doc.entry.references.len);
}

/// Keep raw source independent of the temporary expansion response.
pub fn setExactSource(doc: *OwnedEntry, source: []const u8) !void {
    const a = doc.arena.allocator();
    doc.entry.source = null;
    doc.entry.source_base64 = null;
    if (std.unicode.utf8ValidateSlice(source)) doc.entry.source = try a.dupe(u8, source) else doc.entry.source_base64 = try base64(a, source);
}

test "standalone and expanded presentation own temporary source bytes" {
    const expected = "==English==\n===Noun===\n# [[mouse]]\n";
    var buffer: [expected.len]u8 = undefined;
    @memcpy(&buffer, expected);
    var doc = try fromWikitext(std.testing.allocator, "mouse", "English", &buffer, true);
    defer doc.deinit();
    @memset(&buffer, 'x');
    try std.testing.expectEqualStrings(expected, doc.entry.source.?);
    try std.testing.expectEqualStrings("mouse", doc.entry.sections[1].blocks[0].spans[0].text);
    try setExactSource(&doc, "{{original}}\xff");
    try std.testing.expect(doc.entry.source == null and doc.entry.source_base64 != null);
}

test "form entries keep noun and verb meanings rather than becoming a bare redirect" {
    const source = "==English==\n===Noun===\n{{head|en|noun form}}\n# {{plural of|en|cat}}\n===Verb===\n{{head|en|verb form}}\n# {{infl of|en|cat||s-verb-form}}\n";
    var doc = try fromWikitext(std.testing.allocator, "cats", "English", source, true);
    defer doc.deinit();
    const lexical = doc.entry.organization.lexemes;
    try std.testing.expectEqual(@as(usize, 2), lexical.len);
    try std.testing.expectEqualStrings("Noun", lexical[0].kind);
    try std.testing.expectEqualStrings("Verb", lexical[1].kind);
    try std.testing.expectEqualStrings("plural", lexical[0].definitions[0].form.?.relation);
    try std.testing.expectEqualStrings("cat", lexical[1].definitions[0].form.?.target);
    try std.testing.expectEqualStrings("third-person singular present", lexical[1].definitions[0].form.?.relation);
    try std.testing.expectEqual(@as(usize, 0), doc.entry.unexpanded_templates);
    try std.testing.expectEqualStrings(source, doc.entry.source.?);
}

test "synonym lists are not mislabeled as usage examples" {
    const source = "==English==\n===Noun===\n# An animal.\n#: {{syn|en|feline|kitty}}\n#: The cat sat on the mat.\n#* {{quote-book|en|title=Book|passage=The cat slept.}}\n";
    var doc = try fromWikitext(std.testing.allocator, "cat", "English", source, false);
    defer doc.deinit();
    const sense = doc.entry.organization.lexemes[0].definitions[0];
    try std.testing.expectEqual(@as(usize, 1), sense.examples.len);
    try std.testing.expectEqual(@as(usize, 1), sense.notes.len);
    try std.testing.expectEqual(@as(usize, 1), sense.quotations.len);
    const blocks = doc.entry.sections[1].blocks;
    try std.testing.expect(std.mem.indexOf(u8, blocks[sense.examples[0]].text, "mat") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[sense.notes[0]].text, "syn") != null);
}

test "standalone multilingual source never merges equally named parts of speech" {
    var doc = try fromWikitext(std.testing.allocator, "chat", "English", "==English==\n===Noun===\n# A conversation.\n==French==\n===Etymology===\nLatin.\n===Noun===\n# A cat.\n", true);
    defer doc.deinit();
    const lexical = doc.entry.organization.lexemes;
    try std.testing.expectEqual(@as(usize, 2), lexical.len);
    try std.testing.expectEqualStrings("English", lexical[0].language);
    try std.testing.expectEqualStrings("French", lexical[1].language);
    try std.testing.expect(lexical[0].etymology == null);
    try std.testing.expectEqualStrings("Etymology", doc.entry.sections[lexical[1].etymology.?].title);
}

test "quotation continuation lines stay with quotations rather than becoming usage examples" {
    var doc = try fromWikitext(std.testing.allocator, "cat", "English", "==English==\n===Noun===\n# An animal.\n#* 1973, A Book.\n#*: A continuation of the quoted passage.\n#: My cat sleeps.\n", false);
    defer doc.deinit();
    const sense = doc.entry.organization.lexemes[0].definitions[0];
    try std.testing.expectEqual(@as(usize, 2), sense.quotations.len);
    try std.testing.expectEqual(@as(usize, 1), sense.examples.len);
}

test "core reading retains definitions and origin identity without pretending deferred bodies are empty" {
    const a = std.testing.allocator;
    const source = "==English==\n===Etymology 1===\nHistory one.\n====Noun====\n# First meaning.\n#: An example.\n=====Translations=====\nFrench: chat\n===Etymology 2===\nHistory two.\n====Verb====\n# Second meaning.\n";
    const context: enc.language_blob_encoding.LanguageContext = .{ .heading = "English" };
    const payload_bytes = try enc.language_blob_encoding.encodeAlloc(a, source, context);
    defer a.free(payload_bytes);
    var split = try enc.language_parts.splitAlloc(a, payload_bytes, context);
    defer split.deinit(a);
    const record: dec.BlobRecordView = .{ .language = .{ .title = "cat", .payload = split.core, .metadata = .{ .code = "en", .heading = "English" } } };
    var doc = try fromCoreRecord(a, record);
    defer doc.deinit();
    try std.testing.expectEqual(.structured, doc.entry.status);
    try std.testing.expectEqual(.core, doc.entry.content);
    try std.testing.expect(doc.entry.source == null and doc.entry.source_base64 == null);
    try std.testing.expectEqual(@as(usize, 6), doc.entry.sections.len);
    try std.testing.expectEqual(enc.language_parts.Kind.etymology, doc.entry.sections[1].deferred.?);
    try std.testing.expectEqual(enc.language_parts.Kind.translations, doc.entry.sections[3].deferred.?);
    try std.testing.expectEqual(enc.language_parts.Kind.etymology, doc.entry.sections[4].deferred.?);
    try std.testing.expectEqual(@as(usize, 0), doc.entry.sections[1].blocks.len);
    try std.testing.expectEqual(@as(usize, 2), doc.entry.organization.lexemes.len);
    try std.testing.expectEqual(@as(?usize, 1), doc.entry.organization.lexemes[0].etymology);
    try std.testing.expectEqual(@as(?usize, 4), doc.entry.organization.lexemes[1].etymology);
    try std.testing.expectEqual(@as(usize, 1), doc.entry.organization.lexemes[0].definitions[0].examples.len);
    try std.testing.expectError(error.InvalidEncoding, sourceAlloc(a, record));
    var strict = try fromRecord(a, record, false);
    defer strict.deinit();
    try std.testing.expectEqual(.invalid_payload, strict.entry.status);
    var full = try fromCoreRecord(a, .{ .language = .{ .title = "cat", .payload = payload_bytes, .metadata = record.language.metadata } });
    defer full.deinit();
    try std.testing.expectEqual(.complete, full.entry.content);
}
fn coreAllocationCase(a: Allocator) !void {
    const bytes = try enc.language_blob_encoding.encodeAlloc(a, "==English==\n===Etymology===\nOrigin\n===Noun===\n# An animal.\n", .{ .heading = "English" });
    defer a.free(bytes);
    var split = try enc.language_parts.splitAlloc(a, bytes, .{ .heading = "English" });
    defer split.deinit(a);
    var doc = try fromCoreRecord(a, .{ .language = .{ .title = "cat", .payload = split.core, .metadata = .{ .code = "en", .heading = "English" } } });
    defer doc.deinit();
}
test "core rendering frees every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, coreAllocationCase, .{});
}
