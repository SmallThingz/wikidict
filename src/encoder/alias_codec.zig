//! Typed build-time redirect data. The reader follows one direct edge only.
const std = @import("std");
const format = @import("blob_format.zig");
pub const magic = "DAL1";
// The directory key selects the ordinary compiled namespace without opening
// any payload. The suffix is exactly that kind's existing reader lookup key.
pub fn keyAlloc(a: std.mem.Allocator, kind: format.BlobKind, key: []const u8) ![]u8 {
    if (kind == .alias or key.len == 0 or std.mem.indexOfScalar(u8, key, 0) != null or !std.unicode.utf8ValidateSlice(key)) return error.InvalidAlias;
    const out = try a.alloc(u8, key.len + 2);
    out[0] = '0' + @backingInt(kind);
    out[1] = '\t';
    @memcpy(out[2..], key);
    return out;
}
pub fn validateKey(key: []const u8, record: Record) error{InvalidAlias}!void {
    if (key.len < 3 or key[0] != '0' + @backingInt(record.source_kind) or key[1] != '\t' or !std.mem.eql(u8, key[2..], record.source_key)) return error.InvalidAlias;
}
pub const Record = struct {
    source_namespace: u32,
    source_kind: format.BlobKind,
    source_title: []const u8,
    source_key: []const u8,
    xml_target: []const u8,
    target_title: []const u8,
    target_namespace: ?u32,
    target_kind: ?format.BlobKind,
    target_key: []const u8,
    fragment: []const u8,
    presentation: []const u8,
};
pub fn validate(r: Record) error{InvalidAlias}!void {
    if (r.source_kind == .alias or (r.source_kind == .language) != (r.source_namespace == 0)) return error.InvalidAlias;
    if (r.target_kind) |kind| {
        const ns = r.target_namespace orelse return error.InvalidAlias;
        if (kind == .alias or (kind == .language) != (ns == 0) or r.target_key.len == 0) return error.InvalidAlias;
    } else if (r.target_key.len != 0) return error.InvalidAlias;
    for ([_][]const u8{ r.source_title, r.source_key, r.xml_target, r.target_title }) |s| {
        if (s.len == 0 or std.mem.indexOfScalar(u8, s, 0) != null or !std.unicode.utf8ValidateSlice(s)) return error.InvalidAlias;
    }
    if (r.target_key.len != 0 and (!std.unicode.utf8ValidateSlice(r.target_key) or std.mem.indexOfScalar(u8, r.target_key, 0) != null)) return error.InvalidAlias;
    const expected_source_key = if (r.source_kind == .language or r.source_kind == .supplemental) r.source_title else blk: {
        const colon = std.mem.indexOfScalar(u8, r.source_title, ':') orelse return error.InvalidAlias;
        break :blk r.source_title[colon + 1 ..];
    };
    if (!std.mem.eql(u8, expected_source_key, r.source_key)) return error.InvalidAlias;
    if (r.target_kind) |kind| {
        const expected_key = if (kind == .language or kind == .supplemental) r.target_title else blk: {
            const colon = std.mem.indexOfScalar(u8, r.target_title, ':') orelse return error.InvalidAlias;
            break :blk r.target_title[colon + 1 ..];
        };
        if (!std.mem.eql(u8, r.target_key, expected_key)) return error.InvalidAlias;
    }
    if (r.fragment.len > 255 or !std.unicode.utf8ValidateSlice(r.fragment) or std.mem.indexOfScalar(u8, r.fragment, 0) != null) return error.InvalidAlias;
    if (r.presentation.len == 0) return error.InvalidAlias;
}
fn string(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var size: [format.max_varuint_len]u8 = undefined;
    try out.appendSlice(a, format.encodePayloadLength(s.len, &size));
    try out.appendSlice(a, s);
}
pub fn encodeAlloc(a: std.mem.Allocator, r: Record) ![]u8 {
    try validate(r);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, magic);
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, r.source_namespace, .little);
    try out.appendSlice(a, &word);
    try out.append(a, @backingInt(r.source_kind));
    try out.append(a, if (r.target_namespace != null) 1 else 0);
    std.mem.writeInt(u32, &word, r.target_namespace orelse 0, .little);
    try out.appendSlice(a, &word);
    try out.append(a, if (r.target_kind) |kind| @backingInt(kind) else 0);
    inline for (.{ "source_title", "source_key", "xml_target", "target_title", "target_key", "fragment", "presentation" }) |field|
        try string(&out, a, @field(r, field));
    return out.toOwnedSlice(a);
}
fn readString(bytes: []const u8, at: *usize) ![]const u8 {
    const len = format.readPayloadLength(bytes, at) catch return error.InvalidAlias;
    if (len > bytes.len - at.*) return error.InvalidAlias;
    const result = bytes[at.*..][0..len];
    at.* += len;
    return result;
}
pub fn decode(bytes: []const u8) error{InvalidAlias}!Record {
    if (bytes.len < 15 or !std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidAlias;
    const source_kind = std.enums.fromInt(format.BlobKind, bytes[8]) orelse return error.InvalidAlias;
    const has_namespace = bytes[9];
    if (has_namespace > 1) return error.InvalidAlias;
    const ns = std.mem.readInt(u32, bytes[10..14], .little);
    if (has_namespace == 0 and ns != 0) return error.InvalidAlias;
    const target_kind: ?format.BlobKind = if (bytes[14] == 0) null else std.enums.fromInt(format.BlobKind, bytes[14]) orelse return error.InvalidAlias;
    var at: usize = 15;
    const r: Record = .{
        .source_namespace = std.mem.readInt(u32, bytes[4..8], .little),
        .source_kind = source_kind,
        .target_namespace = if (has_namespace == 1) ns else null,
        .target_kind = target_kind,
        .source_title = try readString(bytes, &at),
        .source_key = try readString(bytes, &at),
        .xml_target = try readString(bytes, &at),
        .target_title = try readString(bytes, &at),
        .target_key = try readString(bytes, &at),
        .fragment = try readString(bytes, &at),
        .presentation = try readString(bytes, &at),
    };
    if (at != bytes.len) return error.InvalidAlias;
    try validate(r);
    return r;
}
test "alias codec preserves direct identity and fragment and rejects malformed framing" {
    const a = std.testing.allocator;
    const r: Record = .{ .source_namespace = 0, .source_kind = .language, .source_title = "Animus", .source_key = "Animus", .xml_target = "animus", .target_title = "animus", .target_namespace = 0, .target_kind = .language, .target_key = "animus", .fragment = "Latin noun", .presentation = "DPR2" };
    const bytes = try encodeAlloc(a, r);
    defer a.free(bytes);
    const decoded = try decode(bytes);
    const key = try keyAlloc(a, r.source_kind, r.source_key);
    defer a.free(key);
    try validateKey(key, decoded);
    try std.testing.expectError(error.InvalidAlias, validateKey("2\tAnimus", decoded));
    try std.testing.expectError(error.InvalidAlias, validateKey("1\tOther", decoded));
    const feature_key = try keyAlloc(a, .thesaurus, r.source_key);
    defer a.free(feature_key);
    try std.testing.expect(!std.mem.eql(u8, key, feature_key));
    inline for (.{ "source_title", "source_key", "xml_target", "target_title", "target_key", "fragment", "presentation" }) |field|
        try std.testing.expectEqualStrings(@field(r, field), @field(decoded, field));
    for (0..bytes.len) |end| try std.testing.expectError(error.InvalidAlias, decode(bytes[0..end]));
    const extra = try std.mem.concat(a, u8, &.{ bytes, "x" });
    defer a.free(extra);
    try std.testing.expectError(error.InvalidAlias, decode(extra));
    var invalid = r;
    invalid.target_key = "other";
    try std.testing.expectError(error.InvalidAlias, encodeAlloc(a, invalid));
    invalid = r;
    invalid.source_namespace = 10;
    try std.testing.expectError(error.InvalidAlias, encodeAlloc(a, invalid));
}
