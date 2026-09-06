const std = @import("std");
const language = @import("language_blob_encoding.zig");

const kind_raw: u8 = 0;
const kind_language: u8 = 1;

pub const Kind = enum {
    raw,
    language,
};

pub const View = struct {
    kind: Kind,
    body: []const u8,
    heading: ?[]const u8,

    pub fn sectionIterator(self: View) error{InvalidEncoding}!?language.SectionIterator {
        if (self.kind != .language) return null;
        return try language.SectionIterator.init(self.body, .{ .heading = self.heading.? });
    }
};

pub fn inspect(encoded: []const u8, local_title: []const u8) error{InvalidEncoding}!View {
    if (encoded.len == 0) return error.InvalidEncoding;
    return switch (encoded[0]) {
        kind_raw => .{ .kind = .raw, .body = encoded[1..], .heading = null },
        kind_language => .{
            .kind = .language,
            .body = encoded[1..],
            .heading = language.reconstructionHeadingFromTitle(local_title) orelse return error.InvalidEncoding,
        },
        else => error.InvalidEncoding,
    };
}

pub fn encodeAlloc(allocator: std.mem.Allocator, source: []const u8, local_title: []const u8) ![]u8 {
    if (language.reconstructionHeadingFromTitle(local_title)) |heading| {
        if (language.encodeAlloc(allocator, source, .{ .heading = heading })) |structured| {
            defer allocator.free(structured);
            const out = try allocator.alloc(u8, structured.len + 1);
            out[0] = kind_language;
            @memcpy(out[1..], structured);
            return out;
        } else |_| {}
    }
    const out = try allocator.alloc(u8, source.len + 1);
    out[0] = kind_raw;
    @memcpy(out[1..], source);
    return out;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8, local_title: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const view = try inspect(encoded, local_title);
    return switch (view.kind) {
        .raw => allocator.dupe(u8, view.body),
        .language => language.decodeAlloc(allocator, view.body, .{ .heading = view.heading.? }),
    };
}

test "reconstruction codec uses structured language payload and preserves preamble" {
    const source = "{{reconstructed}}\n==Proto-Germanic==\n===Noun===\n# cat\n";
    const encoded = try encodeAlloc(std.testing.allocator, source, "Proto-Germanic/kattuz");
    defer std.testing.allocator.free(encoded);
    const view = try inspect(encoded, "Proto-Germanic/kattuz");
    try std.testing.expectEqual(Kind.language, view.kind);
    var sections = (try view.sectionIterator()).?;
    try std.testing.expectEqualStrings("{{reconstructed}}\n", sections.preamble());
    const decoded = try decodeAlloc(std.testing.allocator, encoded, "Proto-Germanic/kattuz");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "reconstruction codec falls back to raw source when title context is unsupported" {
    const source = "raw malformed reconstruction";
    const encoded = try encodeAlloc(std.testing.allocator, source, "no-slash");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(Kind.raw, (try inspect(encoded, "no-slash")).kind);
    const decoded = try decodeAlloc(std.testing.allocator, encoded, "no-slash");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}
