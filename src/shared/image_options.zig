//! Capture-bound build-time image options, never a reader grammar.
const std = @import("std");
const casefold = @import("unicode_casefold.zig");
pub const header = "# wikidict-image-options-v1";
// Parser::getImageParams registration order: literal IDs precede parameter IDs.
pub const ids = [_][]const u8{
    "img_left",                   "img_right",       "img_center",       "img_none",    "img_baseline",         "img_sub",              "img_super",
    "img_top",                    "img_text_top",    "img_middle",       "img_bottom",  "img_text_bottom",      "img_thumbnail",        "img_framed",
    "img_frameless",              "img_border",      "img_manualthumb",  "img_upright", "img_link",             "img_alt",              "img_class",
    "img_width",                  "img_page",        "img_lang",         "img_lossy",   "timedmedia_thumbtime", "timedmedia_starttime", "timedmedia_endtime",
    "timedmedia_disablecontrols", "timedmedia_loop", "timedmedia_muted",
};
pub const Mode = enum { image, timed, gallery, timed_gallery, pdf, djvu, svg };
pub const Match = struct { id: []const u8, value: ?[]const u8 };
const Alias = struct { rank: usize, source_order: usize, id: []const u8, text: []const u8, sensitive: bool, placeholder: ?usize };
fn identity(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidImageOptionsSnapshot;
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.eql(u8, line[prefix.len..], expected)) return error.ImageIdentityMismatch;
}
fn rankOf(id: []const u8) usize {
    for (ids, 0..) |known, rank| if (std.mem.eql(u8, known, id)) return rank;
    return ids.len;
}
fn supported(rank: usize, mode: Mode) bool {
    if ((mode == .timed or mode == .timed_gallery) and rank >= 25 and rank < ids.len) return true;
    if (mode == .gallery or mode == .timed_gallery) return rank == 18 or rank == 19 or rank == 20;
    if (rank == 22) return mode == .pdf or mode == .djvu;
    if (rank == 23) return mode == .svg;
    return rank < 22; // No admitted PagedTiff handler fact for page/lossy.
}
fn aliasLessThan(_: void, lhs: Alias, rhs: Alias) bool {
    if (lhs.sensitive != rhs.sensitive) return !lhs.sensitive;
    if (lhs.rank != rhs.rank) return lhs.rank < rhs.rank;
    return lhs.source_order < rhs.source_order;
}
fn prefixEnd(input: []const u8, prefix: []const u8, sensitive: bool) ?usize {
    if (sensitive) return if (std.mem.startsWith(u8, input, prefix)) prefix.len else null;
    var input_iterator = (std.unicode.Utf8View.init(input) catch return null).iterator();
    var alias_iterator = (std.unicode.Utf8View.init(prefix) catch return null).iterator();
    while (alias_iterator.nextCodepoint()) |cp| {
        const input_cp = input_iterator.nextCodepoint() orelse return null;
        if (casefold.simpleFold(input_cp) != casefold.simpleFold(cp)) return null;
    }
    return input_iterator.i;
}
fn matchAlias(alias: Alias, input: []const u8) ?Match {
    const split = alias.placeholder orelse {
        const end = prefixEnd(input, alias.text, alias.sensitive) orelse return null;
        return if (end == input.len) .{ .id = alias.id, .value = null } else null;
    };
    const start = prefixEnd(input, alias.text[0..split], alias.sensitive) orelse return null;
    const suffix = alias.text[split + 2 ..];
    var end = input.len;
    if (alias.sensitive) {
        if (!std.mem.endsWith(u8, input[start..], suffix)) return null;
        end -= suffix.len;
    } else {
        // Count decoded alias suffix scalars; walk input scalars
        // backwards so Kelvin/long-s matches retain original capture bytes.
        var suffix_iterator = (std.unicode.Utf8View.init(suffix) catch return null).iterator();
        while (suffix_iterator.nextCodepoint() != null) {
            if (end <= start) return null;
            end -= 1;
            while (end > start and input[end] & 0xC0 == 0x80) end -= 1;
        }
        const suffix_end = prefixEnd(input[end..], suffix, false) orelse return null;
        if (suffix_end != input.len - end) return null;
    }
    if (end < start or std.mem.indexOfScalar(u8, input[start..end], '\n') != null) return null;
    return .{ .id = alias.id, .value = input[start..end] };
}
// Parser::parseWidthParam, followed by positive width OR height validation.
// The localized suffix is already captured. Legacy second "px" is accepted.
pub fn validWidth(raw: []const u8) bool {
    var cursor: usize = 0;
    var first_positive = false;
    while (cursor < raw.len and std.ascii.isDigit(raw[cursor])) : (cursor += 1) first_positive = first_positive or raw[cursor] != '0';
    var second_positive = false;
    if (cursor < raw.len and raw[cursor] == 'x') {
        cursor += 1;
        while (cursor < raw.len and std.ascii.isDigit(raw[cursor])) : (cursor += 1) second_positive = second_positive or raw[cursor] != '0';
    }
    while (cursor < raw.len and std.mem.indexOfScalar(u8, " \t\r\n\x0b\x0c", raw[cursor]) != null) cursor += 1;
    if (std.mem.startsWith(u8, raw[cursor..], "px")) cursor += 2;
    while (cursor < raw.len and std.mem.indexOfScalar(u8, " \t\r\n\x0b\x0c", raw[cursor]) != null) cursor += 1;
    return cursor == raw.len and (first_positive or second_positive);
}
fn select(aliases: []const Alias, input: []const u8, mode: Mode) ?Match {
    // Init resolves ID/bucket priority once. Matching scans the immutable
    // ordered aliases directly, without repeated per-option ID lookups.
    for (aliases) |alias| {
        if (!supported(alias.rank, mode)) continue;
        const found = matchAlias(alias, input) orelse continue;
        if (alias.rank == 21 and !validWidth(found.value orelse "")) return null;
        return found;
    }
    return null;
}
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    aliases: []const Alias,
    pub fn init(a: std.mem.Allocator, raw: []const u8, wiki: []const u8, date: []const u8, language: []const u8, namespace_sha256: [32]u8, behavior_sha256: [32]u8) !Registry {
        if (raw.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidImageOptionsSnapshot;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var lines = std.mem.splitScalar(u8, try alloc.dupe(u8, raw), '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidImageOptionsSnapshot, header)) return error.InvalidImageOptionsSnapshot;
        try identity(&lines, "# wiki\t", wiki);
        try identity(&lines, "# dump-date\t", date);
        try identity(&lines, "# content-language\t", language);
        const namespace_hex = std.fmt.bytesToHex(namespace_sha256, .lower);
        try identity(&lines, "# namespace-registry-sha256\t", &namespace_hex);
        const behavior_hex = std.fmt.bytesToHex(behavior_sha256, .lower);
        try identity(&lines, "# behavior-switches-sha256\t", &behavior_hex);
        var aliases: std.ArrayList(Alias) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = fields.next() orelse return error.InvalidImageOptionsSnapshot;
            var known = false;
            for (ids) |value| if (std.mem.eql(u8, value, id)) {
                known = true;
                break;
            };
            if (!known) return error.InvalidImageOptionsSnapshot;
            const flag = fields.next() orelse return error.InvalidImageOptionsSnapshot;
            const sensitive = if (std.mem.eql(u8, flag, "1")) true else if (std.mem.eql(u8, flag, "0")) false else return error.InvalidImageOptionsSnapshot;
            const encoded = fields.next() orelse return error.InvalidImageOptionsSnapshot;
            const text = std.json.parseFromSliceLeaky([]const u8, alloc, encoded, .{ .allocate = .alloc_always }) catch return error.InvalidImageOptionsSnapshot;
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidImageOptionsSnapshot;
            if (fields.next() != null or text.len == 0 or text.len > 1024 or aliases.items.len >= 10000) return error.InvalidImageOptionsSnapshot;
            var codepoints = (try std.unicode.Utf8View.init(text)).iterator();
            while (codepoints.nextCodepoint()) |cp| {
                if ((cp < 32 and cp != '\n' and cp != '\r' and cp != '\t') or (cp >= 127 and cp <= 159)) return error.InvalidImageOptionsSnapshot;
            }
            const placeholder = std.mem.indexOf(u8, text, "$1");
            var dollars: usize = 0;
            for (text, 0..) |byte, at| if (byte == '$') {
                dollars += 1;
                if (dollars > 1 or at + 1 >= text.len or text[at + 1] != '1') return error.InvalidImageOptionsSnapshot;
            };
            try aliases.append(alloc, .{ .rank = rankOf(id), .source_order = aliases.items.len, .id = id, .text = text, .sensitive = sensitive, .placeholder = placeholder });
        }
        std.mem.sort(Alias, aliases.items, {}, aliasLessThan);
        return .{ .arena = arena, .aliases = try aliases.toOwnedSlice(alloc) };
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn match(self: *const Registry, input: []const u8, mode: Mode) ?Match {
        return select(self.aliases, input, mode);
    }
};
const EnglishSpec = struct { id: []const u8, alias: []const u8, sensitive: bool = true };
// Exact enwiktionary captured aliases/order; TSV SHA256 329b2e49ad43a9af2a171f519e6086ed618f20e2188198dcbfbc61c7fd9fbfc8
const english = [_]EnglishSpec{
    .{ .id = "img_left", .alias = "left", .sensitive = true },
    .{ .id = "img_right", .alias = "right", .sensitive = true },
    .{ .id = "img_center", .alias = "center", .sensitive = true },
    .{ .id = "img_center", .alias = "centre", .sensitive = true },
    .{ .id = "img_none", .alias = "none", .sensitive = true },
    .{ .id = "img_baseline", .alias = "baseline", .sensitive = true },
    .{ .id = "img_sub", .alias = "sub", .sensitive = true },
    .{ .id = "img_super", .alias = "super", .sensitive = true },
    .{ .id = "img_super", .alias = "sup", .sensitive = true },
    .{ .id = "img_top", .alias = "top", .sensitive = true },
    .{ .id = "img_text_top", .alias = "text-top", .sensitive = true },
    .{ .id = "img_middle", .alias = "middle", .sensitive = true },
    .{ .id = "img_bottom", .alias = "bottom", .sensitive = true },
    .{ .id = "img_text_bottom", .alias = "text-bottom", .sensitive = true },
    .{ .id = "img_thumbnail", .alias = "thumb", .sensitive = true },
    .{ .id = "img_thumbnail", .alias = "thumbnail", .sensitive = true },
    .{ .id = "img_framed", .alias = "frame", .sensitive = true },
    .{ .id = "img_framed", .alias = "framed", .sensitive = true },
    .{ .id = "img_framed", .alias = "enframed", .sensitive = true },
    .{ .id = "img_frameless", .alias = "frameless", .sensitive = true },
    .{ .id = "img_border", .alias = "border", .sensitive = true },
    .{ .id = "img_manualthumb", .alias = "thumbnail=$1", .sensitive = true },
    .{ .id = "img_manualthumb", .alias = "thumb=$1", .sensitive = true },
    .{ .id = "img_upright", .alias = "upright", .sensitive = true },
    .{ .id = "img_upright", .alias = "upright=$1", .sensitive = true },
    .{ .id = "img_upright", .alias = "upright $1", .sensitive = true },
    .{ .id = "img_link", .alias = "link=$1", .sensitive = true },
    .{ .id = "img_alt", .alias = "alt=$1", .sensitive = true },
    .{ .id = "img_class", .alias = "class=$1", .sensitive = true },
    .{ .id = "img_width", .alias = "$1px", .sensitive = true },
    .{ .id = "img_page", .alias = "page=$1", .sensitive = true },
    .{ .id = "img_page", .alias = "page $1", .sensitive = true },
    .{ .id = "img_lang", .alias = "lang=$1", .sensitive = true },
    .{ .id = "img_lossy", .alias = "lossy=$1", .sensitive = true },
    .{ .id = "timedmedia_thumbtime", .alias = "thumbtime=$1", .sensitive = false },
    .{ .id = "timedmedia_starttime", .alias = "start=$1", .sensitive = false },
    .{ .id = "timedmedia_endtime", .alias = "end=$1", .sensitive = false },
    .{ .id = "timedmedia_disablecontrols", .alias = "disablecontrols=$1", .sensitive = false },
    .{ .id = "timedmedia_loop", .alias = "loop", .sensitive = false },
    .{ .id = "timedmedia_muted", .alias = "muted", .sensitive = false },
};

const english_aliases: [english.len]Alias = blk: {
    @setEvalBranchQuota(20000);
    var aliases: [english.len]Alias = undefined;
    for (english, 0..) |spec, index| aliases[index] = .{ .rank = rankOf(spec.id), .source_order = index, .id = spec.id, .text = spec.alias, .sensitive = spec.sensitive, .placeholder = std.mem.indexOf(u8, spec.alias, "$1") };
    std.mem.sort(Alias, &aliases, {}, aliasLessThan);
    break :blk aliases;
};
pub fn matchEnglish(input: []const u8, mode: Mode) ?Match {
    return select(&english_aliases, input, mode);
}
const test_identity = header ++ "\n# wiki\ttestwiktionary\n# dump-date\t20261001\n# content-language\ttest\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n# behavior-switches-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n";
test "image option aliases preserve case buckets registration precedence and exact captures" {
    const raw = test_identity ++ "img_width\t1\t\"$1px\"\nimg_thumbnail\t1\t\"thumb\"\nimg_manualthumb\t1\t\"thumb=$1\"\nimg_alt\t1\t\"alt=$1\"\ntimedmedia_starttime\t0\t\"ΟΣ=$1\"\nimg_left\t0\t\"thumb\"\nimg_link\t0\t\"link=$1\"\nimg_thumbnail\t1\t\"200px\"\nimg_manualthumb\t1\t\"अङ्गुष्ठचित्रम्=\\n$1\"\nimg_manualthumb\t1\t\"Tabs=\\t$1\\r\"\n";
    var registry = try Registry.init(std.testing.allocator, raw, "testwiktionary", "20261001", "test", @splat(0), @splat(0));
    defer registry.deinit();
    try std.testing.expectEqualStrings("img_left", registry.match("thumb", .image).?.id);
    try std.testing.expectEqualStrings("img_thumbnail", registry.match("200px", .image).?.id);
    try std.testing.expect(registry.match("THUMB=Manual.png", .image) == null);
    try std.testing.expectEqualStrings("Manual.png", registry.match("thumb=Manual.png", .image).?.value.?);
    try std.testing.expectEqualStrings("", registry.match("alt=", .image).?.value.?);
    try std.testing.expectEqualStrings("Case_Target", registry.match("linK=Case_Target", .image).?.value.?);
    try std.testing.expect(registry.match("alt=one\ntwo", .image) == null);
    try std.testing.expectEqualStrings("Manual.png", registry.match("अङ्गुष्ठचित्रम्=\nManual.png", .image).?.value.?);
    try std.testing.expect(registry.match("अङ्गुष्ठचित्रम्=\nOne\nTwo", .image) == null);
    try std.testing.expectEqualStrings("Original", registry.match("Tabs=\tOriginal\r", .image).?.value.?);
    try std.testing.expect(registry.match("200px", .gallery) == null);
    try std.testing.expectEqualStrings("OriginalValue", registry.match("ος=OriginalValue", .timed).?.value.?);
    try std.testing.expectEqualStrings("OriginalValue", registry.match("οσ=OriginalValue", .timed).?.value.?);
}
test "image option width validation rejects zero malformed and unsupported handler captions" {
    for ([_][]const u8{ "200", "200x100", "x100", "200x", "200x0", "0x100", "200 px", "200px", "200px " }) |input| try std.testing.expect(validWidth(input));
    for ([_][]const u8{ "", "x", "0", "0x0", "200xx100", "-200", "200.5", "200X100", "200 garbage", "200 px garbage" }) |input| try std.testing.expect(!validWidth(input));
    try std.testing.expect(matchEnglish("THUMB", .image) == null);
    try std.testing.expect(matchEnglish("0px", .image) == null);
    try std.testing.expect(matchEnglish("xpx", .image) == null);
    try std.testing.expect(matchEnglish("200pxpx", .image) != null);
    try std.testing.expect(matchEnglish("page=bad", .image) == null);
    try std.testing.expect(matchEnglish("frameless", .gallery) == null);
}
test "image option snapshot binds edition date language namespaces and selected behavior" {
    const raw = test_identity ++ "img_alt\t1\t\"alt=$1\"\n";
    try std.testing.expectError(error.ImageIdentityMismatch, Registry.init(std.testing.allocator, raw, "otherwiktionary", "20261001", "test", @splat(0), @splat(0)));
    try std.testing.expectError(error.ImageIdentityMismatch, Registry.init(std.testing.allocator, raw, "testwiktionary", "20260901", "test", @splat(0), @splat(0)));
    try std.testing.expectError(error.ImageIdentityMismatch, Registry.init(std.testing.allocator, raw, "testwiktionary", "20261001", "other", @splat(0), @splat(0)));
    try std.testing.expectError(error.ImageIdentityMismatch, Registry.init(std.testing.allocator, raw, "testwiktionary", "20261001", "test", @splat(1), @splat(0)));
    try std.testing.expectError(error.ImageIdentityMismatch, Registry.init(std.testing.allocator, raw, "testwiktionary", "20261001", "test", @splat(0), @splat(1)));
    for ([_][]const u8{ "img_alt\t1\t\"alt=$1$1\"\n", "img_alt\t1\t\"alt=$2\"\n", "img_alt\t1\t\"alt=$1$2\"\n", "img_alt\t1\t\"alt=$1\\u0085\"\n", "img_alt\t1\t\"alt=$1\\u0000\"\n", "unknown\t1\t\"alt=$1\"\n", "img_alt\t1\t\"alt=$1\"\tunexpected\n" }) |row| {
        const malformed = try std.mem.concat(std.testing.allocator, u8, &.{ test_identity, row });
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidImageOptionsSnapshot, Registry.init(std.testing.allocator, malformed, "testwiktionary", "20261001", "test", @splat(0), @splat(0)));
    }
}

test "image option authenticated German English tables bind exact selected input bytes" {
    const tables = [_]struct { wiki: []const u8, language: []const u8, options: []const u8, namespaces: []const u8, behavior: []const u8 }{
        .{ .wiki = "dewiktionary", .language = "de", .options = @embedFile("fixtures/image-de-options.tsv"), .namespaces = @embedFile("fixtures/image-de-namespace.tsv"), .behavior = @embedFile("fixtures/image-de-behavior.tsv") },
        .{ .wiki = "enwiktionary", .language = "en", .options = @embedFile("fixtures/image-en-options.tsv"), .namespaces = @embedFile("fixtures/image-en-namespace.tsv"), .behavior = @embedFile("fixtures/image-en-behavior.tsv") },
    };
    for (tables) |table| {
        var namespace_sha: [32]u8 = undefined;
        var behavior_sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(table.namespaces, &namespace_sha, .{});
        std.crypto.hash.sha2.Sha256.hash(table.behavior, &behavior_sha, .{});
        var registry = try Registry.init(std.testing.allocator, table.options, table.wiki, "20261001", table.language, namespace_sha, behavior_sha);
        defer registry.deinit();
        if (std.mem.eql(u8, table.language, "de")) {
            try std.testing.expectEqualStrings("img_right", registry.match("rechts", .image).?.id);
            try std.testing.expectEqualStrings("KeepCase", registry.match("alternativtext=KeepCase", .image).?.value.?);
        } else {
            try std.testing.expect(registry.match("THUMB", .image) == null);
            try std.testing.expect(registry.match("thumb", .image) != null);
            try std.testing.expect(registry.match("MUTED", .timed) != null);
            try std.testing.expect(registry.match("MUTED", .image) == null);
        }
        try std.testing.expect(registry.match("0px", .image) == null);
        try std.testing.expect(registry.match("200xx100px", .image) == null);
    }
}

test {
    _ = casefold;
}
