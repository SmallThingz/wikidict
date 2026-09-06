//! Runtime-only presentation model shared by terminal, HTML, and JSON consumers.
//! Text borrows the mapped blob where possible; OwnedEntry owns auxiliary arrays.
const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const ir = enc.document_ir;
const Allocator = std.mem.Allocator;

pub const Feature = struct {
    kind: []const u8,
    language: []const u8 = "",
    data: []const u8 = "",
    tail_kind: []const u8 = "none",
    tail: []const u8 = "",
};
pub const Block = struct {
    kind: ir.BlockKind,
    depth: u8,
    text: []const u8,
    spans: []const ir.InlineSpan,
    feature: ?Feature = null,
};
pub const Section = struct { level: u8, title: []const u8, blocks: []const Block };
pub const Entry = struct {
    title: []const u8,
    kind: enc.blob_format.BlobKind,
    language: ?[]const u8 = null,
    sections: []const Section = &.{},
    preamble: []const u8 = "",
    unexpanded_templates: usize = 0,
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
    };
}

pub fn payload(record: dec.BlobRecordView) []const u8 {
    return switch (record) {
        .language => |r| r.payload,
        .thesaurus => |r| r.payload,
        .rhymes => |r| r.payload,
        .reconstruction => |r| r.payload,
        .citations, .sign_gloss => |r| r.source,
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
    templates: usize = 0,
    started: bool = false,

    fn flush(self: *Builder) !void {
        try self.sections.append(self.a, .{ .level = self.level, .title = self.title, .blocks = try self.blocks.toOwnedSlice(self.a) });
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
        var spans: std.ArrayList(ir.InlineSpan) = .empty;
        var it: ir.InlineIterator = .{ .input = text };
        while (it.next()) |span| {
            try spans.append(self.a, span);
            if (span.kind == .template) self.templates += 1;
        }
        try self.blocks.append(self.a, .{ .kind = input.kind, .depth = input.depth, .text = text, .spans = try spans.toOwnedSlice(self.a), .feature = feature });
    }
    fn raw(self: *Builder, text: []const u8) !void {
        var lines: enc.language_blob_encoding.LineIterator = .{ .input = text };
        while (lines.next()) |line| try self.block(ir.classifyLine(line), null);
    }
    fn language(self: *Builder, it_ptr: *enc.language_blob_encoding.SectionIterator) !void {
        while (try it_ptr.next()) |s| {
            // Preserve even empty semantic sections and their original levels.
            if (self.started) try self.flush();
            self.started = true;
            self.title = try utf8Text(self.a, s.title);
            self.level = s.level;
            var blocks = s.blockIterator();
            while (blocks.next()) |b| try self.block(b, null);
        }
    }
    fn term(self: *Builder, text: []const u8, language_code: []const u8, tail_kind: []const u8, tail: []const u8) !void {
        const data = try utf8Text(self.a, text);
        const suffix = try utf8Text(self.a, tail);
        const stem = if (std.mem.startsWith(u8, tail_kind, "plural_")) try std.fmt.allocPrint(self.a, "{s}s", .{data}) else data;
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var entry: Entry = .{ .title = try utf8Text(a, record.title()), .kind = record.kind() };
    var builder: Builder = .{ .a = a };
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
    entry.unexpanded_templates = builder.templates;
    if (include_source) {
        const source = try sourceAlloc(a, record);
        if (std.unicode.utf8ValidateSlice(source)) entry.source = source else entry.source_base64 = try base64(a, source);
    }
    return .{ .arena = arena, .entry = entry };
}

fn populate(b: *Builder, record: dec.BlobRecordView, entry: *Entry) !void {
    switch (record) {
        .language => |r| {
            entry.language = try utf8Text(b.a, r.metadata.heading);
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
            while (try it.next()) |item| switch (item.kind) {
                .raw_line => try b.raw(item.data),
                .relation => try b.heading(3, @tagName(item.relation.?)),
                .sense => try b.heading(3, item.data),
                .header => if (item.data.len != 0) {
                    try b.heading(2, item.data);
                },
                .term => try b.term(item.data, item.language, @tagName(item.tail_kind), item.tail),
                .topic => try b.block(.{ .kind = .paragraph, .depth = 0, .text = item.data }, .{ .kind = "topic", .language = try utf8Text(b.a, item.language), .data = try utf8Text(b.a, item.data) }),
                .blank, .list_begin, .list_end => {},
            };
        },
        .rhymes => |r| {
            var it = try r.recordIterator();
            while (try it.next()) |item| switch (item.kind) {
                .raw_line => try b.raw(item.data),
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
            };
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
    try std.testing.expectEqual(@as(usize, 2), doc.entry.sections.len);
    try std.testing.expectEqual(ir.BlockKind.definition, doc.entry.sections[1].blocks[0].kind);
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
