//! Edition-scoped build-time behavior controls. Complete source aliases include delimiters.
const std = @import("std");
const casefold = @import("unicode_casefold.zig");
pub const header = "# wikidict-behavior-switches-v1";
pub const ids = [_][]const u8{ "notoc", "forcetoc", "toc", "noeditsection", "nogallery", "hiddencat", "index", "noindex", "newsectionlink", "nonewsectionlink", "nocontentconvert", "notitleconvert", "staticredirect", "expectunusedcategory", "expectunusedtemplate", "expectshortpage", "noglobal", "nomediaviewercarousel", "disambiguation", "expectedUnconnectedPage", "archivedtalk", "notalk", "keeptitle", "expectwithoutscans" };
const Alias = struct { text: []const u8, sensitive: bool, scalars: usize, toc: bool = false };
fn identity(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidBehaviorSnapshot;
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.eql(u8, line[prefix.len..], expected)) return error.BehaviorIdentityMismatch;
}
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    aliases: []const Alias,
    initial_bytes: [256]bool,
    pub fn init(a: std.mem.Allocator, raw: []const u8, wiki: []const u8, date: []const u8, language: []const u8, namespace_sha256: [32]u8) !Registry {
        if (raw.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidBehaviorSnapshot;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var lines = std.mem.splitScalar(u8, try alloc.dupe(u8, raw), '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidBehaviorSnapshot, header)) return error.InvalidBehaviorSnapshot;
        try identity(&lines, "# wiki\t", wiki);
        try identity(&lines, "# dump-date\t", date);
        try identity(&lines, "# content-language\t", language);
        const namespace_hex = std.fmt.bytesToHex(namespace_sha256, .lower);
        try identity(&lines, "# namespace-registry-sha256\t", &namespace_hex);
        var entries: std.ArrayList(Alias) = .empty;
        var initials: [256]bool = @splat(false);
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = fields.next() orelse return error.InvalidBehaviorSnapshot;
            var known = false;
            for (ids) |value| if (std.mem.eql(u8, value, id)) {
                known = true;
                break;
            };
            if (!known) return error.InvalidBehaviorSnapshot;
            const flag = fields.next() orelse return error.InvalidBehaviorSnapshot;
            const sensitive = if (std.mem.eql(u8, flag, "1")) true else if (std.mem.eql(u8, flag, "0")) false else return error.InvalidBehaviorSnapshot;
            const alias = fields.next() orelse return error.InvalidBehaviorSnapshot;
            if (fields.next() != null or alias.len == 0 or alias.len > 1024) return error.InvalidBehaviorSnapshot;
            for (alias) |byte| if (byte < 32 or byte == 127) return error.InvalidBehaviorSnapshot;
            var it = (try std.unicode.Utf8View.init(alias)).iterator();
            const first_cp = it.nextCodepoint().?;
            var count: usize = 1;
            while (it.nextCodepoint() != null) count += 1;
            initials[alias[0]] = true;
            if (!sensitive) {
                if (first_cp < 128) {
                    initials[std.ascii.toLower(alias[0])] = true;
                    initials[std.ascii.toUpper(alias[0])] = true;
                    // ASCII letters can also match long s or the Kelvin sign.
                    if (std.ascii.isAlphabetic(alias[0]))
                        for (128..256) |byte| {
                            initials[byte] = true;
                        };
                } else if (!std.mem.startsWith(u8, alias, "＿＿")) {
                    for (128..256) |byte| initials[byte] = true;
                    const folded_first = casefold.simpleFold(first_cp);
                    if (folded_first < 128) {
                        initials[folded_first] = true;
                        initials[std.ascii.toUpper(@intCast(folded_first))] = true;
                    }
                }
            }
            if (entries.items.len >= 10000) return error.InvalidBehaviorSnapshot;
            try entries.append(alloc, .{ .text = alias, .sensitive = sensitive, .scalars = count, .toc = std.mem.eql(u8, id, "toc") });
        }
        return .{ .arena = arena, .aliases = try entries.toOwnedSlice(alloc), .initial_bytes = initials };
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn matchAt(self: *const Registry, a: std.mem.Allocator, input: []const u8, at: usize) std.mem.Allocator.Error!?usize {
        return self.matchAtKind(a, input, at, false);
    }
    pub fn tocMatchAt(self: *const Registry, a: std.mem.Allocator, input: []const u8, at: usize) std.mem.Allocator.Error!?usize {
        return self.matchAtKind(a, input, at, true);
    }
    fn matchAtKind(self: *const Registry, a: std.mem.Allocator, input: []const u8, at: usize, toc_only: bool) std.mem.Allocator.Error!?usize {
        _ = a;
        if (at >= input.len or !self.initial_bytes[input[at]]) return null;
        var longest: usize = at;
        for (self.aliases) |alias| {
            if (toc_only and !alias.toc) continue;
            // Switch delimiters are punctuation and cannot case-fold into another byte.
            if (!std.ascii.isAlphabetic(alias.text[0]) and alias.text[0] < 128 and input[at] != alias.text[0]) continue;
            if (alias.sensitive) {
                if (std.mem.startsWith(u8, input[at..], alias.text)) longest = @max(longest, at + alias.text.len);
            } else {
                var pos = at;
                var count: usize = 0;
                while (pos < input.len and count < alias.scalars) : (count += 1) {
                    const n = std.unicode.utf8ByteSequenceLength(input[pos]) catch break;
                    if (pos + n > input.len) break;
                    pos += n;
                }
                if (count != alias.scalars) continue;
                if (casefold.eqlIgnoreCase(input[at..pos], alias.text)) longest = @max(longest, pos);
            }
        }
        return if (longest > at) longest else null;
    }
};
test "behavior registry respects fullwidth Arabic aliases case and identity" {
    const raw = header ++ "\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t＿＿目次非表示＿＿\nnoeditsection\t0\t__لاتحريرقسم__\nindex\t1\t__INDEX__\n";
    var r = try Registry.init(std.testing.allocator, raw, "jawiktionary", "20261001", "ja", @splat(0));
    defer r.deinit();
    try std.testing.expectEqual(@as(?usize, "＿＿目次非表示＿＿".len), try r.matchAt(std.testing.allocator, "＿＿目次非表示＿＿tail", 0));
    try std.testing.expectEqual(@as(?usize, "__لاتحريرقسم__".len), try r.matchAt(std.testing.allocator, "__لاتحريرقسم__", 0));
    try std.testing.expectEqual(@as(?usize, null), try r.matchAt(std.testing.allocator, "__index__", 0));
    try std.testing.expectError(error.BehaviorIdentityMismatch, Registry.init(std.testing.allocator, raw, "otherwiktionary", "20261001", "ja", @splat(0)));
    try std.testing.expectError(error.BehaviorIdentityMismatch, Registry.init(std.testing.allocator, raw, "jawiktionary", "20260901", "ja", @splat(0)));
    try std.testing.expectError(error.BehaviorIdentityMismatch, Registry.init(std.testing.allocator, raw, "jawiktionary", "20261001", "ar", @splat(0)));
    try std.testing.expectError(error.BehaviorIdentityMismatch, Registry.init(std.testing.allocator, raw, "jawiktionary", "20261001", "ja", @splat(1)));
}

test "TOC recognition retains canonical identity and existing alias case rules" {
    const raw = header ++ "\n# wiki\tfrwiktionary\n# dump-date\t20261001\n# content-language\tfr\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\ntoc\t0\t__SOMMAIRE__\nnoeditsection\t0\t__SANSSECTION__\n";
    var registry = try Registry.init(std.testing.allocator, raw, "frwiktionary", "20261001", "fr", @splat(0));
    defer registry.deinit();
    try std.testing.expectEqual(@as(?usize, "__sommaire__".len), try registry.tocMatchAt(std.testing.allocator, "__sommaire__tail", 0));
    try std.testing.expectEqual(@as(?usize, null), try registry.tocMatchAt(std.testing.allocator, "__SANSSECTION__", 0));
    try std.testing.expectEqual(@as(?usize, "__SANSSECTION__".len), try registry.matchAt(std.testing.allocator, "__SANSSECTION__", 0));
}

test "behavior aliases use Unicode simple folding and original byte endpoints" {
    const raw = header ++ "\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnoeditsection\t0\t__NOEDITSECTION__\nnotoc\t0\t__Σ__\nstaticredirect\t1\t__STATICREDIRECT__\ntoc\t0\tSoft\nnogallery\t0\tKeep\n";
    var registry = try Registry.init(std.testing.allocator, raw, "enwiktionary", "20261001", "en", @splat(0));
    defer registry.deinit();
    for ([_][]const u8{ "__NOEDITſECTION__", "__ς__", "__σ__", "ſoft", "KEEP", "Keep" }) |source| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ "x", source, "tail" });
        defer std.testing.allocator.free(input);
        try std.testing.expectEqual(@as(?usize, 1 + source.len), try registry.matchAt(std.testing.allocator, input, 1));
    }
    for ([_][]const u8{ "__ſTATICREDIRECT__", "__staticredirect__", "__NOEDİTSECTION__", "__UNKNOWN__", "__NOEDIT\xc0\xafECTION__" }) |source|
        try std.testing.expectEqual(@as(?usize, null), try registry.matchAt(std.testing.allocator, source, 0));
    try std.testing.expectEqual(@as(?usize, "ſoft".len), try registry.tocMatchAt(std.testing.allocator, "ſofttail", 0));
    try std.testing.expectEqual(@as(?usize, null), try registry.tocMatchAt(std.testing.allocator, "__NOEDITſECTION__", 0));
}
