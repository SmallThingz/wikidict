//! Immutable, bounded digit transformations captured from MediaWiki formatDate.
const std = @import("std");
const Provider = @import("lua_program").WikitextProvider;
pub const DateNumbering = Provider.DateNumbering;
const A = std.mem.Allocator;
const Entry = struct { code: []const u8, digits: ?[10][]const u8 };
pub const max_snapshot_bytes = 128 * 1024;
pub const max_profiles = 64;

fn header(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8) ![]const u8 {
    const line = lines.next() orelse return error.InvalidDateNumberingSnapshot;
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidDateNumberingSnapshot;
    return line[prefix.len..];
}

fn identity(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, try header(lines, prefix), expected)) return error.InvalidDateNumberingSnapshot;
}

fn codeValid(code: []const u8) bool {
    if (code.len < 2 or code.len > 64) return false;
    for (code) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}

fn timezoneValid(zone: []const u8) bool {
    if (zone.len == 0 or zone.len > 128) return false;
    for (zone) |c| if (c <= 32 or c >= 127 or c == '\\') return false;
    return true;
}

// Unicode 16.0 White_Space and General_Category Cc/Cf, fixed to match
// prepare_date_numbering.py. Sources: Unicode 16.0 ucd/PropList.txt and
// ucd/extracted/DerivedGeneralCategory.txt; this is a wire-format constraint.
fn excludedScalar(cp: u21) bool {
    return switch (cp) {
        0x0...0x20,
        0x7f...0xa0,
        0xad,
        0x600...0x605,
        0x61c,
        0x6dd,
        0x70f,
        0x890...0x891,
        0x8e2,
        0x1680,
        0x180e,
        0x2000...0x200f,
        0x2028...0x202f,
        0x205f...0x2064,
        0x2066...0x206f,
        0x3000,
        0xfeff,
        0xfff9...0xfffb,
        0x110bd,
        0x110cd,
        0x13430...0x1343f,
        0x1bca0...0x1bca3,
        0x1d173...0x1d17a,
        0xe0001,
        0xe0020...0xe007f,
        => true,
        else => false,
    };
}

fn glyphValid(glyph: []const u8) bool {
    if (glyph.len == 0 or glyph.len > 32) return false;
    const view = std.unicode.Utf8View.init(glyph) catch return false;
    var scalars = view.iterator();
    while (scalars.nextCodepoint()) |cp| {
        if ((cp < 128 and (cp < '0' or cp > '9')) or excludedScalar(cp)) return false;
    }
    return true;
}

fn reasonValid(reason: []const u8) bool {
    inline for (.{ "invalid-glyphs", "composite-mismatch", "raw-control-mismatch", "negative-mismatch", "duplicate-mismatch" }) |valid| {
        if (std.mem.eql(u8, reason, valid)) return true;
    }
    return false;
}

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    timezone: []const u8,
    entries: []const Entry,

    pub fn init(allocator: A, bytes: []const u8, wiki: []const u8, date: []const u8, language: []const u8) !Registry {
        if (bytes.len == 0 or bytes.len > max_snapshot_bytes or bytes[bytes.len - 1] != '\n' or !std.unicode.utf8ValidateSlice(bytes))
            return error.InvalidDateNumberingSnapshot;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const source = try a.dupe(u8, bytes);
        var lines = std.mem.splitScalar(u8, source, '\n');
        try identity(&lines, "", "# wikidict-date-numbering-v1");
        try identity(&lines, "# wiki\t", wiki);
        try identity(&lines, "# dump-date\t", date);
        try identity(&lines, "# content-language\t", language);
        const timezone = try header(&lines, "# timezone\t");
        if (!timezoneValid(timezone)) return error.InvalidDateNumberingSnapshot;
        const raw_count = try header(&lines, "# profiles\t");
        if (raw_count.len == 0 or (raw_count.len > 1 and raw_count[0] == '0')) return error.InvalidDateNumberingSnapshot;
        for (raw_count) |c| if (!std.ascii.isDigit(c)) return error.InvalidDateNumberingSnapshot;
        const count = std.fmt.parseInt(usize, raw_count, 10) catch return error.InvalidDateNumberingSnapshot;
        if (count == 0 or count > max_profiles) return error.InvalidDateNumberingSnapshot;
        const entries = try a.alloc(Entry, count);
        for (entries, 0..) |*entry, index| {
            const line = lines.next() orelse return error.InvalidDateNumberingSnapshot;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const kind = fields.next() orelse return error.InvalidDateNumberingSnapshot;
            const code = fields.next() orelse return error.InvalidDateNumberingSnapshot;
            if (!codeValid(code)) return error.InvalidDateNumberingSnapshot;
            if (index > 0 and std.mem.order(u8, entries[index - 1].code, code) != .lt)
                return error.InvalidDateNumberingSnapshot;
            if (std.mem.eql(u8, kind, "D")) {
                var digits: [10][]const u8 = undefined;
                for (&digits, 0..) |*digit, position| {
                    const glyph = fields.next() orelse return error.InvalidDateNumberingSnapshot;
                    if (!glyphValid(glyph)) return error.InvalidDateNumberingSnapshot;
                    for (digits[0..position]) |previous| {
                        if (std.mem.eql(u8, previous, glyph)) return error.InvalidDateNumberingSnapshot;
                    }
                    digit.* = glyph;
                }
                entry.* = .{ .code = code, .digits = digits };
            } else if (std.mem.eql(u8, kind, "U")) {
                if (!reasonValid(fields.next() orelse return error.InvalidDateNumberingSnapshot))
                    return error.InvalidDateNumberingSnapshot;
                entry.* = .{ .code = code, .digits = null };
            } else return error.InvalidDateNumberingSnapshot;
            if (fields.next() != null) return error.InvalidDateNumberingSnapshot;
        }
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidDateNumberingSnapshot, "") or lines.next() != null)
            return error.InvalidDateNumberingSnapshot;
        return .{ .arena = arena, .timezone = timezone, .entries = entries };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    // All returned slices are immutable and remain owned by this registry.
    pub fn lookup(self: *const Registry, code: []const u8) !DateNumbering {
        var start: usize = 0;
        var end = self.entries.len;
        while (start < end) {
            const middle = start + (end - start) / 2;
            const entry = self.entries[middle];
            switch (std.mem.order(u8, code, entry.code)) {
                .lt => end = middle,
                .gt => start = middle + 1,
                .eq => return .{ .digits = entry.digits orelse return error.DateNumberingUnsupported, .timezone = self.timezone },
            }
        }
        return error.DateNumberingSnapshotMissing;
    }
};

const fixture_header = "# wikidict-date-numbering-v1\n# wiki\tbnwiktionary\n# dump-date\t20261001\n# content-language\tbn\n# timezone\tAsia/Dhaka\n";
const bn_row = "D\tbn\t০\t১\t২\t৩\t৪\t৫\t৬\t৭\t৮\t৯\n";
const fixture = fixture_header ++ "# profiles\t3\n" ++ bn_row ++
    "D\txx\t0\tā\tচ\t৩৩\t4\t5\t6\t7\t8\t9\n" ++
    "U\tzz\tcomposite-mismatch\n";

fn allocationProbe(a: A) !void {
    var registry = try Registry.init(a, fixture, "bnwiktionary", "20261001", "bn");
    defer registry.deinit();
    const profile = try registry.lookup("bn");
    try std.testing.expectEqualStrings("Asia/Dhaka", profile.timezone);
    try std.testing.expectEqualStrings("০", profile.digits[0]);
    try std.testing.expectEqualStrings("৯", profile.digits[9]);
    try std.testing.expectEqualStrings("৩৩", (try registry.lookup("xx")).digits[3]);
    try std.testing.expectError(error.DateNumberingUnsupported, registry.lookup("zz"));
    try std.testing.expectError(error.DateNumberingSnapshotMissing, registry.lookup("en"));
}

test "date numbering preserves captured glyphs timezone and explicit unsupported profiles with allocation cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "date numbering rejects malformed duplicate incomplete unsorted and foreign captures" {
    const a = std.testing.allocator;
    const invalid = [_][]const u8{
        fixture_header ++ "# profiles\t1\n",
        fixture_header ++ "# profiles\t0\n" ++ bn_row,
        fixture_header ++ "# profiles\t01\n" ++ bn_row,
        fixture_header ++ "# profiles\t65\n",
        fixture_header ++ "# profiles\t+1\n" ++ bn_row,
        fixture_header ++ "# profiles\t2\n" ++ bn_row ++ bn_row,
        fixture_header ++ "# profiles\t2\nU\tzz\tinvalid-glyphs\n" ++ bn_row,
        fixture_header ++ "# profiles\t1\nU\tbn\tinvented-reason\n",
        fixture_header ++ "# profiles\t1\nU\tbn\tinvalid-glyphs\textra\n",
        fixture_header ++ "# profiles\t1\nU\tB N\tinvalid-glyphs\n",
        fixture_header ++ "# profiles\t1\nD\tbn\t0\t1\t2\n",
        fixture_header ++ "# profiles\t1\nD\tbn\t0\t0\t2\t3\t4\t5\t6\t7\t8\t9\n",
        fixture_header ++ "# profiles\t1\nD\tbn\t0\t \t2\t3\t4\t5\t6\t7\t8\t9\n",
        fixture_header ++ "# profiles\t1\nD\tbn\t0\t\\1\t2\t3\t4\t5\t6\t7\t8\t9\n",
        fixture_header ++ "# profiles\t1\nD\tbn\t0\t\x7f\t2\t3\t4\t5\t6\t7\t8\t9\n",
        fixture_header ++ "# profiles\t1\nD\tbn\t0\t\xff\t2\t3\t4\t5\t6\t7\t8\t9\n",
        fixture_header ++ "# profiles\t1\n" ++ bn_row ++ "\n",
    };
    for (invalid) |bytes| {
        try std.testing.expectError(error.InvalidDateNumberingSnapshot, Registry.init(a, bytes, "bnwiktionary", "20261001", "bn"));
    }
    inline for (.{
        .{ "enwiktionary", "20261001", "bn" },
        .{ "bnwiktionary", "20260901", "bn" },
        .{ "bnwiktionary", "20261001", "en" },
    }) |foreign| {
        try std.testing.expectError(error.InvalidDateNumberingSnapshot, Registry.init(a, fixture, foreign[0], foreign[1], foreign[2]));
    }
    try std.testing.expectError(error.InvalidDateNumberingSnapshot, Registry.init(a, fixture[0 .. fixture.len - 1], "bnwiktionary", "20261001", "bn"));
    const oversized = try a.alloc(u8, max_snapshot_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.InvalidDateNumberingSnapshot, Registry.init(a, oversized, "bnwiktionary", "20261001", "bn"));
}

test "date numbering accepts each explicit unsupported reason" {
    const a = std.testing.allocator;
    inline for (.{ "invalid-glyphs", "composite-mismatch", "raw-control-mismatch", "negative-mismatch", "duplicate-mismatch" }) |reason| {
        var registry = try Registry.init(a, fixture_header ++ "# profiles\t1\nU\tbn\t" ++ reason ++ "\n", "bnwiktionary", "20261001", "bn");
        defer registry.deinit();
        try std.testing.expectError(error.DateNumberingUnsupported, registry.lookup("bn"));
    }
}

test "date numbering glyph bounds preserve multiple scalars and reject controls and whitespace" {
    try std.testing.expect(glyphValid("২২"));
    try std.testing.expect(glyphValid("0"));
    try std.testing.expect(glyphValid("৩৩৩৩৩৩৩৩৩৩"));
    try std.testing.expect(!glyphValid("৩৩৩৩৩৩৩৩৩৩৩"));
    try std.testing.expect(glyphValid("00000000000000000000000000000000"));
    try std.testing.expect(!glyphValid("000000000000000000000000000000000"));
    for ([_][]const u8{ "", "two", "-", ".", " ", "\\", "\x00", "\x7f", "\xff", "\u{85}", "\u{a0}", "\u{ad}", "\u{600}", "\u{1680}", "\u{200d}", "\u{2029}", "\u{3000}", "\u{feff}", "\u{13430}", "\u{e007f}" }) |invalid| {
        try std.testing.expect(!glyphValid(invalid));
    }
    try std.testing.expect(codeValid("aa"));
    try std.testing.expect(codeValid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!codeValid("a"));
    try std.testing.expect(!codeValid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!codeValid("AA"));
    try std.testing.expect(timezoneValid("UTC"));
    try std.testing.expect(timezoneValid("Etc/GMT+5"));
    for ([_][]const u8{ "", "A B", "UTC\r", "\\", "বাংলা", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) |invalid| {
        try std.testing.expect(!timezoneValid(invalid));
    }
}

test "date numbering admits at most 64 sorted complete profiles" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDateNumberingSnapshot, Registry.init(a, fixture_header ++ "# profiles\t0\n", "bnwiktionary", "20261001", "bn"));
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, fixture_header ++ "# profiles\t64\n");
    for (0..64) |index| {
        var line: [64]u8 = undefined;
        const row = try std.fmt.bufPrint(&line, "U\tx{d:0>2}\tinvalid-glyphs\n", .{index});
        try source.appendSlice(a, row);
    }
    var registry = try Registry.init(a, source.items, "bnwiktionary", "20261001", "bn");
    defer registry.deinit();
    try std.testing.expectError(error.DateNumberingUnsupported, registry.lookup("x00"));
    try std.testing.expectError(error.DateNumberingUnsupported, registry.lookup("x63"));
    try std.testing.expectError(error.DateNumberingSnapshotMissing, registry.lookup("x64"));
}
