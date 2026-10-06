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
