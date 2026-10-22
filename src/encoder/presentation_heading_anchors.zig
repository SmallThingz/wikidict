const std = @import("std");
const A = std.mem.Allocator;
pub const Ids = struct { anchor: []const u8, anchor_fallback: []const u8 = "" };

// Build-time MediaWiki HTML5 heading identity. Inputs are final semantic text,
// never wikitext. Keep collision keys ASCII-insensitive, as PHP strtolower is.
pub const Registry = struct {
    used: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Registry, a: A) void {
        var keys = self.used.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.used.deinit(a);
    }

    fn reserve(self: *Registry, a: A, base: []const u8) ![]const u8 {
        var suffix: usize = 1;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 1) try a.dupe(u8, base) else try std.fmt.allocPrint(a, "{s}_{d}", .{ base, suffix });
            const key = try a.dupe(u8, candidate);
            for (key) |*byte| byte.* = std.ascii.toLower(byte.*);
            const result = try self.used.getOrPut(a, key);
            if (!result.found_existing) return candidate;
            a.free(key);
            a.free(candidate);
        }
    }

    pub fn heading(self: *Registry, a: A, text: []const u8) ![]const u8 {
        return (try self.headingIds(a, text)).anchor;
    }

    pub fn headingIds(self: *Registry, a: A, text: []const u8) !Ids {
        const normalized = try normalizedAlloc(a, text);
        defer a.free(normalized);
        return self.reserveIds(a, normalized);
    }

    pub fn authored(self: *Registry, a: A, id: []const u8) ![]const u8 {
        return (try self.authoredIds(a, id)).anchor;
    }

    pub fn authoredIds(self: *Registry, a: A, id: []const u8) !Ids {
        var at: usize = 0;
        var points: usize = 0;
        while (at < id.len and points < 1024) : (points += 1) {
            const width = std.unicode.utf8ByteSequenceLength(id[at]) catch return error.InvalidPresentation;
            if (at + width > id.len) return error.InvalidPresentation;
            _ = std.unicode.utf8Decode(id[at..][0..width]) catch return error.InvalidPresentation;
            at += width;
        }
        return self.reserveIds(a, id[0..at]);
    }

    fn reserveIds(self: *Registry, a: A, normalized: []const u8) !Ids {
        const base = try a.dupe(u8, normalized);
        for (base) |*byte| if (byte.* == ' ' or byte.* == '\t' or byte.* == '\n' or byte.* == '\r' or byte.* == '\x0c') {
            byte.* = '_';
        };
        defer a.free(base);
        const primary = try self.reserve(a, base);
        // MediaWiki reserves legacy fallback IDs in the same namespace even
        // when a reader only needs the primary destination.
        const fallback = try legacyAlloc(a, normalized);
        defer a.free(fallback);
        if (!std.mem.eql(u8, fallback, base)) {
            const reserved = try self.reserve(a, fallback);
            return .{ .anchor = primary, .anchor_fallback = reserved };
        }
        return .{ .anchor = primary };
    }
};

fn titleSpace(cp: u21) bool {
    return cp == ' ' or cp == '_' or cp == 0xa0 or cp == 0x1680 or cp == 0x180e or
        (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or
        cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn normalizedAlloc(a: A, text: []const u8) ![]u8 {
    const clean = std.mem.trim(u8, text, " \t\n\r\x00\x0b_");
    // TitleParser rejects the replacement character; Parser then keeps the
    // first whitespace-normalized section name instead of its title result.
    const fallback = std.mem.indexOf(u8, clean, "\xef\xbf\xbd") != null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var at: usize = 0;
    var points: usize = 0;
    var space = false;
    while (at < clean.len and points < 1024) {
        const width = std.unicode.utf8ByteSequenceLength(clean[at]) catch return error.InvalidPresentation;
        if (at + width > clean.len) return error.InvalidPresentation;
        const cp = std.unicode.utf8Decode(clean[at..][0..width]) catch return error.InvalidPresentation;
        defer at += width;
        if (!fallback and (cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e))) continue;
        if (if (fallback) cp == ' ' or cp == '_' else titleSpace(cp)) {
            space = true;
            continue;
        }
        if (space) {
            try out.append(a, ' ');
            points += 1;
            if (points == 1024) break;
            space = false;
        }
        try out.appendSlice(a, clean[at..][0..width]);
        points += 1;
    }
    return out.toOwnedSlice(a);
}

fn legacyAlloc(a: A, primary: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (primary) |source_byte| {
        const byte: u8 = if (source_byte == ' ') '_' else source_byte;
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == ':') {
            try out.append(a, byte);
        } else {
            try out.appendSlice(a, &.{ '.', hex[byte >> 4], hex[byte & 15] });
        }
    }
    return out.toOwnedSlice(a);
}

test "heading IDs share the page namespace across case and explicit suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: Registry = .{};
    defer ids.deinit(a);
    const headings = [_][]const u8{ "Noun", "noun", "Noun_2", "Noun", "Usage  notes", "Usage_notes" };
    const expected = [_][]const u8{ "Noun", "noun_2", "Noun_2_2", "Noun_3", "Usage_notes", "Usage_notes_2" };
    for (headings, expected) |heading, id| try std.testing.expectEqualStrings(id, try ids.heading(a, heading));
}

test "semantic literal text is not parsed while legacy IDs reserve collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: Registry = .{};
    defer ids.deinit(a);
    try std.testing.expectEqualStrings("<literal>", try ids.heading(a, "<literal>"));
    try std.testing.expectEqualStrings(".3Cliteral.3E_2", try ids.heading(a, ".3Cliteral.3E"));
    try std.testing.expectEqualStrings("A_&_B", try ids.heading(a, "A & B"));
}

test "authored heading IDs bypass title normalization and reserve the same namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: Registry = .{};
    defer ids.deinit(a);
    try std.testing.expectEqualStrings("Custom__ID", try ids.authored(a, "Custom  ID"));
    try std.testing.expectEqualStrings("Custom_ID", try ids.heading(a, "Custom  ID"));
    try std.testing.expectEqualStrings("custom__id_2", try ids.authored(a, "custom  id"));
}

test "heading normalization follows title whitespace bidi and Unicode truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: Registry = .{};
    defer ids.deinit(a);
    try std.testing.expectEqualStrings("_Noun", try ids.heading(a, "\xc2\xa0Noun\xc2\xa0"));
    try std.testing.expectEqualStrings("Noun", try ids.heading(a, "N\xe2\x80\x8eoun"));
    const long = try a.alloc(u8, 1025);
    @memset(long, 'a');
    try std.testing.expectEqual(@as(usize, 1024), (try ids.heading(a, long)).len);
    long[1024] = 'b';
    const next = try ids.heading(a, long);
    try std.testing.expectEqual(@as(usize, 1026), next.len);
    try std.testing.expect(std.mem.endsWith(u8, next, "_2"));
}

test "legacy fallback IDs retain independent suffixes in the shared namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: Registry = .{};
    defer ids.deinit(a);
    const first = try ids.headingIds(a, "\xc3\xa4");
    try std.testing.expectEqualStrings("\xc3\xa4", first.anchor);
    try std.testing.expectEqualStrings(".C3.A4", first.anchor_fallback);
    const literal = try ids.headingIds(a, ".C3.A4");
    try std.testing.expectEqualStrings(".C3.A4_2", literal.anchor);
    try std.testing.expectEqualStrings("", literal.anchor_fallback);
    const later = try ids.headingIds(a, "\xc3\xa4");
    try std.testing.expectEqualStrings("\xc3\xa4_2", later.anchor);
    try std.testing.expectEqualStrings(".C3.A4_3", later.anchor_fallback);
}
