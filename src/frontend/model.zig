//! Data-only runtime presentation model. Blob payloads are compiled at bundle time;
//! readers only deserialize the versioned presentation document.
const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const A = std.mem.Allocator;
const types = enc.presentation_types;
const codec = enc.presentation_codec;

pub const Feature = types.Feature;
pub const Span = types.Span;
pub const Block = types.Block;
pub const Table = types.Table;
pub const Section = types.Section;
pub const Reference = types.Reference;
pub const Media = types.Media;
pub const Entry = types.Entry;
pub const Layout = types.Layout;
pub const Lexeme = types.Lexeme;
pub const Sense = types.Sense;

/// Owns decoded structural arrays but borrows strings from the source record.
/// The source record backing must outlive this value.
pub const DecodedEntry = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *DecodedEntry) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn utf8Text(a: A, bytes: []const u8) ![]const u8 {
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

pub fn payload(record: dec.BlobRecordView) []const u8 {
    return record.payload();
}

pub fn fromRecord(allocator: A, record: dec.BlobRecordView) !DecodedEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const alias: ?enc.alias_codec.Record = if (record == .alias) enc.alias_codec.decode(payload(record)) catch return error.InvalidPresentation else null;
    if (alias) |value| enc.alias_codec.validateKey(record.title(), value) catch return error.InvalidPresentation;
    const stored = codec.decodeAlloc(
        a,
        if (alias) |value| value.presentation else payload(record),
        if (alias) |value| value.source_title else record.title(),
        record.kind(),
        if (record == .language) record.language.metadata else null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedPresentationVersion => return error.UnsupportedPresentationVersion,
        else => return error.InvalidPresentation,
    };
    var entry = stored.entry;
    entry.redirect = record.redirect();
    if (alias) |value| entry.alias = .{
        .xml_target = value.xml_target,
        .target_title = value.target_title,
        .fragment = value.fragment,
    };
    if (entry.redirect == null) if (alias) |value| {
        entry.redirect = .{
            .source_title = value.source_title,
            .target_title = value.target_title,
            .fragment = value.fragment,
            .followed = false,
        };
    };
    return .{ .arena = arena, .entry = entry };
}

test "reader deserializes compiled presentation without wikitext parsing" {
    const a = std.testing.allocator;
    const bytes = try codec.encodeAlloc(a, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    defer a.free(bytes);
    var doc = try fromRecord(a, .{ .language = .{ .title = "cat", .payload = bytes, .metadata = .{ .code = "en", .heading = "English" } } });
    defer doc.deinit();
    try std.testing.expectEqualStrings("cat", doc.entry.title);
    try std.testing.expectEqualStrings("English", doc.entry.language.?);
    try std.testing.expectEqualStrings("en", doc.entry.language_code);
}

test "reader rejects source-like payload instead of compiling it" {
    try std.testing.expectError(error.InvalidPresentation, fromRecord(std.testing.allocator, .{ .citations = .{ .title = "cat", .payload = "# [[cat]] {{template}}" } }));
}

test "alias model validates both envelope identity and nested compiled presentation" {
    const a = std.testing.allocator;
    const bytes = try codec.encodeAlloc(a, .{ .entry = .{ .title = "B", .kind = .alias } });
    defer a.free(bytes);
    var alias: enc.alias_codec.Record = .{
        .source_namespace = 0,
        .source_kind = .language,
        .source_title = "B",
        .source_key = "B",
        .xml_target = "C",
        .target_title = "C",
        .target_namespace = 0,
        .target_kind = .language,
        .target_key = "C",
        .fragment = "Next",
        .presentation = bytes,
    };
    const envelope = try enc.alias_codec.encodeAlloc(a, alias);
    defer a.free(envelope);
    var doc = try fromRecord(a, .{ .alias = .{
        .title = "1\tB",
        .payload = envelope,
        .redirect = .{ .source_title = "A", .target_title = "B", .fragment = "Incoming", .followed = true },
    } });
    defer doc.deinit();
    try std.testing.expectEqualStrings("A", doc.entry.redirect.?.source_title);
    try std.testing.expectEqualStrings("Incoming", doc.entry.redirect.?.fragment);
    try std.testing.expectEqualStrings("C", doc.entry.alias.?.target_title);
    try std.testing.expectEqualStrings("Next", doc.entry.alias.?.fragment);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tWrong", .payload = envelope } }));
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = bytes } }));
    alias.presentation = "#REDIRECT [[C]]";
    const source_like = try enc.alias_codec.encodeAlloc(a, alias);
    defer a.free(source_like);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = source_like } }));
}

test "transient redirect metadata does not alter ordinary DPR2 bytes" {
    const a = std.testing.allocator;
    var entry: Entry = .{ .title = "cat", .kind = .citations };
    const ordinary = try codec.encodeAlloc(a, .{ .entry = entry });
    defer a.free(ordinary);
    entry.redirect = .{ .source_title = "Cat", .target_title = "cat", .fragment = "", .followed = true };
    entry.alias = .{ .xml_target = "next", .target_title = "next", .fragment = "" };
    const transient = try codec.encodeAlloc(a, .{ .entry = entry });
    defer a.free(transient);
    try std.testing.expectEqualSlices(u8, ordinary, transient);
    var doc = try fromRecord(a, .{ .citations = .{ .title = "cat", .payload = transient } });
    defer doc.deinit();
    try std.testing.expect(doc.entry.redirect == null);
    try std.testing.expect(doc.entry.alias == null);
}

test "reader preserves unsupported presentation capability without reclassifying malformed records" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "DPRW", "DPRX" }) |bytes|
        try std.testing.expectError(error.UnsupportedPresentationVersion, fromRecord(a, .{ .citations = .{ .title = "x", .payload = bytes } }));
    // DPRZ is a known capability: malformed flags and truncated known payloads
    // remain InvalidPresentation, while unknown complete DPR headers stay unsupported.
    for ([_][]const u8{ "", "DPR", "XPRN", "DPR2", "DPRM", "DPRN", "DPRO", "DPRP", "DPRQ", "DPRR", "DPRS", "DPRT", "DPRU", "DPRV", "DPRY",
        "DPRZ", "DPRZ\x00", "DPRZ\x00\x00", "DPRZ\x00\x80", "DPRZ\x00\x01", "DPRZpayload" }) |bytes|
        try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .citations = .{ .title = "x", .payload = bytes } }));
    const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
    const entry: Entry = .{ .title = "x", .kind = .citations, .sections = &.{.{ .level = 2, .title = "body", .blocks = &.{
        .{ .kind = .rule, .rule_style = .{ .height = .{ .unit = .px, .value = 1 }, .fill = .{ .rgb = "#a2a9b1" },
            .margins = .{ .top = zero, .right = zero, .bottom = zero, .left = zero } } },
    } }} };
    const bytes = try codec.encodeAlloc(a, types.Stored{ .entry = entry }); defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRN", bytes[0..4]);
    var doc = try fromRecord(a, .{ .citations = .{ .title = "x", .payload = bytes } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry, doc.entry);
}

test "reader unsupported inner capability does not bypass alias envelope validation" {
    const a = std.testing.allocator;
    var alias: enc.alias_codec.Record = .{
        .source_namespace = 0, .source_kind = .language, .source_title = "B", .source_key = "B",
        .xml_target = "C", .target_title = "C", .target_namespace = 0, .target_kind = .language, .target_key = "C",
        .fragment = "Next", .presentation = "DPRX",
    };
    const future = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(future);
    try std.testing.expectError(error.UnsupportedPresentationVersion, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = future } }));
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tWrong", .payload = future } }));
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = "DPRO" } }));
    alias.presentation = "DPRR";
    const malformed_r = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(malformed_r);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = malformed_r } }));
    alias.presentation = "DPRS";
    const malformed_s = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(malformed_s);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = malformed_s } }));
    alias.presentation = "DPRT";
    const malformed_t = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(malformed_t);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = malformed_t } }));
    alias.presentation = "DPRU";
    const malformed_u = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(malformed_u);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = malformed_u } }));
    alias.presentation = "DPRV";
    const malformed_v = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(malformed_v);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = malformed_v } }));
    alias.presentation = "DPRN";
    const malformed = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(malformed);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = malformed } }));
}

test "reader preserves ordinary body data while separating known P through V and Y from private W and X errors" {
    const a = std.testing.allocator;
    const entry: Entry = .{ .title = "body", .kind = .citations, .body_adjoining = .ordinary,
        .sections = &.{.{ .level = 2, .title = "", .blocks = &.{.{ .kind = .paragraph,
            .spans = &.{.{ .kind = .link, .text = "kept", .target = "Kept" }} }} }} };
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(bytes);
    var doc = try fromRecord(a, .{ .citations = .{ .title = "body", .payload = bytes } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry, doc.entry);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .citations = .{ .title = "body", .payload = "DPRP" } }));
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .citations = .{ .title = "body", .payload = "DPRQ" } }));
    for ([_][]const u8{ "DPRR", "DPRS", "DPRT", "DPRU", "DPRV", "DPRY" }) |header|
        try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .citations = .{ .title = "body", .payload = header } }));
    try std.testing.expectError(error.UnsupportedPresentationVersion, fromRecord(a, .{ .citations = .{ .title = "body", .payload = "DPRX" } }));
}

test "reader retains P inline family and declaring owner through the ordinary record model" {
    const a = std.testing.allocator;
    const entry: Entry = .{ .title = "family", .kind = .citations, .sections = &.{.{ .level = 0, .title = "", .blocks = &.{
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = " kept\xc2\xa0 ", .target = "Kept", .target_fragment = "part",
            .font_family = .{ .stack = .{ .names = &.{"Georgia"}, .fallback = .serif } },
            .inline_style = .{ .line_height = .{ .font_relative = .{ .factor = 1,
                .font = .{ .font_family = .sans_serif } } } } }} },
    } }} };
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRP", bytes[0..4]);
    var doc = try fromRecord(a, .{ .citations = .{ .title = "family", .payload = bytes } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry, doc.entry);
    try std.testing.expectEqualStrings(" kept\xc2\xa0 ", doc.entry.sections[0].blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("Kept", doc.entry.sections[0].blocks[0].spans[0].target);
}



test "ordinary record and alias model preserve explicit Q image baseline and middle with full envelope identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]types.InlineImageVerticalAlign{ .middle, .baseline }) |alignment| {
        const source: types.Stored = .{ .entry = .{ .title = "B", .kind = .alias,
            .sections = &.{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .paragraph,
                .spans = &.{.{ .kind = .link, .target = "File:Arrow.png", .image = .{
                    .file = "Arrow.png", .width_px = 30, .vertical_align = alignment } }} }} }},
            .media = &.{.{ .file = "Arrow.png", .kind = .image, .caption = "" }} } };
        const bytes = try codec.encodeAlloc(a, source);
        try std.testing.expectEqualStrings("DPRQ", bytes[0..4]);
        const alias: enc.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language,
            .source_title = "B", .source_key = "B", .xml_target = "C", .target_title = "C",
            .target_namespace = 0, .target_kind = .language, .target_key = "C", .fragment = "Next", .presentation = bytes };
        const envelope = try enc.alias_codec.encodeAlloc(a, alias);
        var doc = try fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = envelope } }); defer doc.deinit();
        try std.testing.expectEqualDeep(source.entry.sections, doc.entry.sections);
        try std.testing.expectEqualDeep(source.entry.media, doc.entry.media);
        try std.testing.expectEqualStrings("B", doc.entry.title);
        try std.testing.expectEqualStrings("C", doc.entry.alias.?.target_title);
        try std.testing.expectEqualStrings("Next", doc.entry.alias.?.fragment);
        try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tWrong", .payload = envelope } }));
    }
}

test "reader preserves complete deep table bodies through T with legacy and reference controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 16, 17, 20, 32, 33 }) |depth| {
        for ([_]bool{ false, true }) |ordered| {
            var table: types.Table = .{ .rows = &.{.{ .cells = &.{.{ .spans = &.{
                .{ .kind = .link, .text = "DEEP", .target = "DeepTarget", .target_fragment = "leaf", .bold = true },
            } }} }} };
            for (1..depth) |_| {
                const cells = try a.alloc(types.Cell, 1);
                if (ordered) {
                    const blocks = try a.alloc(types.Block, 1);
                    blocks[0] = .{ .kind = .table, .table = table };
                    cells[0] = .{ .blocks = blocks };
                } else cells[0] = .{ .nested_table = table };
                const rows = try a.alloc(types.Row, 1);
                rows[0] = .{ .cells = cells };
                table = .{ .rows = rows };
            }
            const blocks = try a.alloc(types.Block, 1);
            blocks[0] = .{ .kind = .table, .table = table };
            for ([_]bool{ false, true }) |in_reference| {
                const entry: Entry = .{ .title = "deep", .kind = .citations,
                    .sections = if (in_reference) &.{} else &.{.{ .level = 2, .title = "body", .blocks = blocks }},
                    .references = if (in_reference) &.{.{ .number = 1, .group_number = 1, .blocks = blocks }} else &.{},
                };
                if (depth == 33) {
                    try std.testing.expectError(error.InvalidPresentation, codec.encodeAlloc(a, .{ .entry = entry }));
                    continue;
                }
                const bytes = try codec.encodeAlloc(a, .{ .entry = entry });
                if (depth > 16) try std.testing.expectEqualStrings("DPRT", bytes[0..4])
                else try std.testing.expect(!std.mem.eql(u8, "DPRT", bytes[0..4]));
                var doc = try fromRecord(a, .{ .citations = .{ .title = "deep", .payload = bytes } });
                defer doc.deinit();
                try std.testing.expectEqualDeep(entry, doc.entry);
            }
        }
    }
}


test "U reader preserves padding ownership edges children and ordinary alias identity" {
    const a = std.testing.allocator;
    // Synthetic declaring font: no claim about the computed SR reading font.
    const group: types.InlinePaddingGroup(Span) = .{
        .left = .{ .unit = .em, .value = 0.25 },
        .right = .{ .unit = .px, .value = 3 },
        .spans = &.{.{ .text = "read", .font_scale = 1.35 }, .{ .text = "ing", .font_scale = 1.35 }},
    };
    const entry: Entry = .{ .title = "B", .kind = .alias, .sections = &.{.{ .level = 0, .title = "", .blocks = &.{
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "", .target = "Reading", .target_fragment = "part",
            .font_scale = 1.35, .inline_padding_group = &group }} },
    } }} };
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRU", bytes[0..4]);
    const alias: enc.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language,
        .source_title = "B", .source_key = "B", .xml_target = "C", .target_title = "C",
        .target_namespace = 0, .target_kind = .language, .target_key = "C", .fragment = "Next", .presentation = bytes };
    const envelope = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(envelope);
    var doc = try fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = envelope } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry.sections, doc.entry.sections);
    try std.testing.expectEqualStrings("C", doc.entry.alias.?.target_title);
    try std.testing.expectEqualStrings("Next", doc.entry.alias.?.fragment);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tWrong", .payload = envelope } }));
}

test "V reader preserves one rich action owner child metrics fragments and ordinary alias identity" {
    const a = std.testing.allocator;
    const group: types.InlineActionGroup(Span) = .{ .spans = &.{
        .{ .text = "d", .italic = true, .font_scale = 1.25 }, .{ .text = "a", .superscript = true, .font_scale = 0.8 },
    } };
    const entry: Entry = .{ .title = "B", .kind = .alias, .sections = &.{.{ .level = 0, .title = "", .blocks = &.{
        .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "", .target = "d", .target_fragment = "part",
            .tooltip = "owner advice", .inline_action_group = &group }} },
    } }} };
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRV", bytes[0..4]);
    const alias: enc.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language,
        .source_title = "B", .source_key = "B", .xml_target = "C", .target_title = "C",
        .target_namespace = 0, .target_kind = .language, .target_key = "C", .fragment = "Next", .presentation = bytes };
    const envelope = try enc.alias_codec.encodeAlloc(a, alias); defer a.free(envelope);
    var doc = try fromRecord(a, .{ .alias = .{ .title = "1\tB", .payload = envelope } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry.sections, doc.entry.sections);
    try std.testing.expectEqualStrings("C", doc.entry.alias.?.target_title);
    try std.testing.expectEqualStrings("Next", doc.entry.alias.?.fragment);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .alias = .{ .title = "1\tWrong", .payload = envelope } }));
    var machine: std.Io.Writer.Allocating = .init(a); defer machine.deinit();
    try std.json.Stringify.value(doc.entry, .{}, &machine.writer);
    try std.testing.expect(std.mem.indexOf(u8, machine.written(), "inline_action_group") != null);
}


test "reader preserves Y declaring paragraph font and signed margins without changing child actions" {
    const a = std.testing.allocator;
    const entry: Entry = .{ .title = "owner", .kind = .citations, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{
        .{ .kind = .container, .container = .{ .style = .{
            .owner_font = .{ .font_scale = 1, .font_scale_basis = .normal_body, .font_normalized = true,
                .bold = true, .language = "de", .font_family = .sans_serif },
            .margins = .{ .top = .{ .unit = .em, .value = 0.4 }, .bottom = .{ .unit = .em, .value = -0.5 },
                .left = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .px, .value = 0 } } },
            .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "normal", .target = "Target",
                .font_scale = 2, .font_scale_basis = .normal_body }} }} } },
    } }} };
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRY", bytes[0..4]);
    var doc = try fromRecord(a, .{ .citations = .{ .title = "owner", .payload = bytes } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry, doc.entry);
    const box = doc.entry.sections[0].blocks[0].container.?;
    try std.testing.expect(box.style.owner_font.?.bold and !box.blocks[0].spans[0].bold);
    try std.testing.expectEqualStrings("Target", box.blocks[0].spans[0].target);
    try std.testing.expectEqual(@as(f32, -0.5), box.style.margins.?.bottom.value);
    const roundtrip = try codec.encodeAlloc(a, .{ .entry = doc.entry }); defer a.free(roundtrip);
    try std.testing.expectEqualSlices(u8, bytes, roundtrip);
}


test "ordinary record model preserves final Y inline box and body owner while refusing private W and X" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const zero: types.StyleLength = .{ .unit = .px, .value = 0 };
    const group: types.InlineBoxGroup(Span) = .{ .padding = .{ .top = zero, .right = zero, .bottom = zero, .left = zero },
        .border = .all(.none), .spans = &.{.{ .kind = .link, .text = "kept", .target = "Kept" }} };
    const entry: Entry = .{ .title = "box", .kind = .citations,
        .body_typography = .{ .owner_font = .{ .font_scale = 1.25, .font_scale_basis = .normal_body, .font_normalized = true } },
        .sections = &.{.{ .level = 0, .title = "", .blocks = &.{.{ .kind = .paragraph,
            .spans = &.{.{ .text = "", .inline_box_group = &group }} }} }} };
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry });
    try std.testing.expectEqualStrings("DPRY", bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 6), bytes[4]);
    var doc = try fromRecord(a, .{ .citations = .{ .title = "box", .payload = bytes } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry, doc.entry);
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, .{ .entry = doc.entry }));
    for ([_][]const u8{ "DPRW", "DPRX" }) |private| {
        try std.testing.expectError(error.UnsupportedPresentationVersion, fromRecord(a,
            .{ .citations = .{ .title = "box", .payload = private } }));
        const alias: enc.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language,
            .source_title = "box", .source_key = "box", .xml_target = "next", .target_title = "next",
            .target_namespace = 0, .target_kind = .language, .target_key = "next", .fragment = "", .presentation = private };
        const envelope = try enc.alias_codec.encodeAlloc(a, alias);
        try std.testing.expectError(error.UnsupportedPresentationVersion, fromRecord(a,
            .{ .alias = .{ .title = "1\tbox", .payload = envelope } }));
        try std.testing.expectError(error.InvalidPresentation, fromRecord(a,
            .{ .alias = .{ .title = "1\twrong", .payload = envelope } }));
    }
}


test "reader preserves positioned Container Z fields and complete body through the ordinary record decoder" {
    const a = std.testing.allocator;
    const entry: Entry = .{ .title = "positioned", .kind = .citations,
        .media = &.{.{ .file = "hand.jpeg", .kind = .image, .caption = "" }}, .sections = &.{.{ .level = 2, .title = "Body", .blocks = &.{
        .{ .kind = .container, .container = .{ .style = .{ .positioning = .relative_auto, .text_wrap = .nowrap }, .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .image = .{ .file = "hand.jpeg", .width_px = 240, .alt = "hand image" } }} },
            .{ .kind = .container, .container = .{ .style = .{
                .absolute_position = .{ .left = .{ .unit = .px, .value = -20 }, .top = .{ .unit = .px, .value = 30 } },
                .width = .{ .length = .{ .unit = .px, .value = 120 } }, .height = .{ .unit = .px, .value = 20 },
                .line_height = .{ .length = .{ .unit = .px, .value = 20 } }, .text_align = .center,
                .owner_font = .{ .font_scale = 18, .font_scale_basis = .css_px, .font_normalized = true, .language = "ja" } },
                .blocks = &.{.{ .kind = .paragraph, .spans = &.{
                    .{ .kind = .link, .text = "linked label", .target = "Label", .target_fragment = "ja" },
                    .{ .text = " self label", .bold = true },
                } }} } },
        } } },
    } }} };
    var missing_media = entry;
    missing_media.media = &.{};
    try std.testing.expectError(error.InvalidPresentation, codec.encodeAlloc(a, .{ .entry = missing_media }));
    const bytes = try codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(bytes);
    try std.testing.expectEqualStrings("DPRZ", bytes[0..4]);
    var doc = try fromRecord(a, .{ .citations = .{ .title = entry.title, .payload = bytes } }); defer doc.deinit();
    try std.testing.expectEqualDeep(entry, doc.entry);
    const outer = doc.entry.sections[0].blocks[0].container.?;
    try std.testing.expect(outer.style.height == null and outer.style.text_wrap == .nowrap);
    try std.testing.expect(outer.blocks[0].spans[0].target.len == 0);
    try std.testing.expectEqual(@as(u32, 240), outer.blocks[0].spans[0].image.?.width_px.?);
    const label = outer.blocks[1].container.?;
    try std.testing.expectEqual(@as(f32, -20), label.style.absolute_position.?.left.value);
    try std.testing.expectEqualStrings("ja", label.blocks[0].spans[0].target_fragment.?);
    try std.testing.expect(label.blocks[0].spans[1].bold);
    const roundtrip = try codec.encodeAlloc(a, .{ .entry = doc.entry }); defer a.free(roundtrip);
    try std.testing.expectEqualSlices(u8, bytes, roundtrip);
    var machine: std.Io.Writer.Allocating = .init(a); defer machine.deinit();
    try std.json.Stringify.value(doc.entry, .{}, &machine.writer);
    for ([_][]const u8{ "absolute_position", "text_wrap", "nowrap", "css_px", "linked label", "self label", "hand.jpeg" }) |field|
        try std.testing.expect(std.mem.indexOf(u8, machine.written(), field) != null);
    try std.testing.expectError(error.InvalidPresentation, fromRecord(a, .{ .citations = .{ .title = entry.title, .payload = "DPRZ" } }));
}
