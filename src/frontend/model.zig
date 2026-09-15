//! Data-only runtime presentation model. Blob payloads are compiled at bundle time;
//! readers only deserialize the versioned presentation document.
const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
const A = std.mem.Allocator;
const types = enc.presentation_types;

pub const Feature = types.Feature;
pub const Span = types.Span;
pub const Block = types.Block;
pub const Section = types.Section;
pub const Reference = types.Reference;
pub const Media = types.Media;
pub const Entry = types.Entry;
pub const Layout = types.Layout;
pub const Lexeme = types.Lexeme;
pub const Sense = types.Sense;

pub const OwnedEntry = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *OwnedEntry) void {
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

fn validate(record: dec.BlobRecordView, stored: types.Stored) !void {
    try types.validateStored(
        stored,
        record.title(),
        record.kind(),
        if (record == .language) record.language.metadata else null,
    );
}

pub fn fromRecord(allocator: A, record: dec.BlobRecordView) !OwnedEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var stored = std.json.parseFromSliceLeaky(types.Stored, a, payload(record), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidPresentation;
    try validate(record, stored);
    if (record == .language) {
        stored.entry.language = try a.dupe(u8, record.language.metadata.heading);
        stored.entry.language_code = try a.dupe(u8, record.language.metadata.code);
    }
    return .{ .arena = arena, .entry = stored.entry };
}

test "reader deserializes compiled presentation without wikitext parsing" {
    const a = std.testing.allocator;
    const bytes = "{\"schema\":\"dict.presentation.v1\",\"entry\":{\"organization\":{},\"title\":\"cat\",\"kind\":\"language\",\"language\":\"English\",\"language_code\":\"en\",\"sections\":[],\"preamble_spans\":[],\"references\":[],\"media\":[]}}";
    var doc = try fromRecord(a, .{ .language = .{ .title = "cat", .payload = bytes, .metadata = .{ .code = "en", .heading = "English" } } });
    defer doc.deinit();
    try std.testing.expectEqualStrings("cat", doc.entry.title);
    try std.testing.expectEqualStrings("English", doc.entry.language.?);
    try std.testing.expectEqualStrings("en", doc.entry.language_code);
}

test "reader rejects source-like payload instead of compiling it" {
    try std.testing.expectError(error.InvalidPresentation, fromRecord(std.testing.allocator, .{ .citations = .{ .title = "cat", .payload = "# [[cat]] {{template}}" } }));
}
