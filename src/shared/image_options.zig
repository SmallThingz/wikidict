//! Capture-bound build-time image options, never a reader grammar.
const std = @import("std");
pub const header = "# wikidict-image-options-v1";
// Parser::getImageParams registration order: literal IDs precede parameter IDs.
pub const ids = [_][]const u8{
    "img_left", "img_right", "img_center", "img_none", "img_baseline", "img_sub", "img_super",
    "img_top", "img_text_top", "img_middle", "img_bottom", "img_text_bottom", "img_thumbnail", "img_framed",
    "img_frameless", "img_border", "img_manualthumb", "img_upright", "img_link", "img_alt", "img_class",
    "img_width", "img_page", "img_lang", "img_lossy", "timedmedia_thumbtime", "timedmedia_starttime",
    "timedmedia_endtime", "timedmedia_disablecontrols", "timedmedia_loop", "timedmedia_muted",
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
        if (simpleFold(input_cp) != simpleFold(cp)) return null;
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
            for (ids) |value| if (std.mem.eql(u8, value, id)) { known = true; break; };
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
    pub fn deinit(self: *Registry) void { self.arena.deinit(); self.* = undefined; }
    pub fn match(self: *const Registry, input: []const u8, mode: Mode) ?Match { return select(self.aliases, input, mode); }
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
pub fn matchEnglish(input: []const u8, mode: Mode) ?Match { return select(&english_aliases, input, mode); }
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

// Unicode16.0 simple C/S folds (PCRE /iu single-scalar equivalence).
// https://www.unicode.org/Public/16.0.0/ucd/CaseFolding.txt SHA256 6f1f9c588eb4a5c718d9e8f93b782685e5c7fec872cf05e8e6878053599e09bb
// Generated into contiguous equal-delta ranges. Data copyright (c)2024 Unicode, Inc.
// Distributed under Unicode-3.0; see src/frontend/UNICODE-LICENSE.txt.
const FoldRange = struct { first: u21, last: u21, delta: i32 };
const fold_ranges = [_]FoldRange{
    .{ .first = 0x41, .last = 0x5A, .delta = 32 },
    .{ .first = 0xB5, .last = 0xB5, .delta = 775 },
    .{ .first = 0xC0, .last = 0xD6, .delta = 32 },
    .{ .first = 0xD8, .last = 0xDE, .delta = 32 },
    .{ .first = 0x100, .last = 0x100, .delta = 1 },
    .{ .first = 0x102, .last = 0x102, .delta = 1 },
    .{ .first = 0x104, .last = 0x104, .delta = 1 },
    .{ .first = 0x106, .last = 0x106, .delta = 1 },
    .{ .first = 0x108, .last = 0x108, .delta = 1 },
    .{ .first = 0x10A, .last = 0x10A, .delta = 1 },
    .{ .first = 0x10C, .last = 0x10C, .delta = 1 },
    .{ .first = 0x10E, .last = 0x10E, .delta = 1 },
    .{ .first = 0x110, .last = 0x110, .delta = 1 },
    .{ .first = 0x112, .last = 0x112, .delta = 1 },
    .{ .first = 0x114, .last = 0x114, .delta = 1 },
    .{ .first = 0x116, .last = 0x116, .delta = 1 },
    .{ .first = 0x118, .last = 0x118, .delta = 1 },
    .{ .first = 0x11A, .last = 0x11A, .delta = 1 },
    .{ .first = 0x11C, .last = 0x11C, .delta = 1 },
    .{ .first = 0x11E, .last = 0x11E, .delta = 1 },
    .{ .first = 0x120, .last = 0x120, .delta = 1 },
    .{ .first = 0x122, .last = 0x122, .delta = 1 },
    .{ .first = 0x124, .last = 0x124, .delta = 1 },
    .{ .first = 0x126, .last = 0x126, .delta = 1 },
    .{ .first = 0x128, .last = 0x128, .delta = 1 },
    .{ .first = 0x12A, .last = 0x12A, .delta = 1 },
    .{ .first = 0x12C, .last = 0x12C, .delta = 1 },
    .{ .first = 0x12E, .last = 0x12E, .delta = 1 },
    .{ .first = 0x132, .last = 0x132, .delta = 1 },
    .{ .first = 0x134, .last = 0x134, .delta = 1 },
    .{ .first = 0x136, .last = 0x136, .delta = 1 },
    .{ .first = 0x139, .last = 0x139, .delta = 1 },
    .{ .first = 0x13B, .last = 0x13B, .delta = 1 },
    .{ .first = 0x13D, .last = 0x13D, .delta = 1 },
    .{ .first = 0x13F, .last = 0x13F, .delta = 1 },
    .{ .first = 0x141, .last = 0x141, .delta = 1 },
    .{ .first = 0x143, .last = 0x143, .delta = 1 },
    .{ .first = 0x145, .last = 0x145, .delta = 1 },
    .{ .first = 0x147, .last = 0x147, .delta = 1 },
    .{ .first = 0x14A, .last = 0x14A, .delta = 1 },
    .{ .first = 0x14C, .last = 0x14C, .delta = 1 },
    .{ .first = 0x14E, .last = 0x14E, .delta = 1 },
    .{ .first = 0x150, .last = 0x150, .delta = 1 },
    .{ .first = 0x152, .last = 0x152, .delta = 1 },
    .{ .first = 0x154, .last = 0x154, .delta = 1 },
    .{ .first = 0x156, .last = 0x156, .delta = 1 },
    .{ .first = 0x158, .last = 0x158, .delta = 1 },
    .{ .first = 0x15A, .last = 0x15A, .delta = 1 },
    .{ .first = 0x15C, .last = 0x15C, .delta = 1 },
    .{ .first = 0x15E, .last = 0x15E, .delta = 1 },
    .{ .first = 0x160, .last = 0x160, .delta = 1 },
    .{ .first = 0x162, .last = 0x162, .delta = 1 },
    .{ .first = 0x164, .last = 0x164, .delta = 1 },
    .{ .first = 0x166, .last = 0x166, .delta = 1 },
    .{ .first = 0x168, .last = 0x168, .delta = 1 },
    .{ .first = 0x16A, .last = 0x16A, .delta = 1 },
    .{ .first = 0x16C, .last = 0x16C, .delta = 1 },
    .{ .first = 0x16E, .last = 0x16E, .delta = 1 },
    .{ .first = 0x170, .last = 0x170, .delta = 1 },
    .{ .first = 0x172, .last = 0x172, .delta = 1 },
    .{ .first = 0x174, .last = 0x174, .delta = 1 },
    .{ .first = 0x176, .last = 0x176, .delta = 1 },
    .{ .first = 0x178, .last = 0x178, .delta = -121 },
    .{ .first = 0x179, .last = 0x179, .delta = 1 },
    .{ .first = 0x17B, .last = 0x17B, .delta = 1 },
    .{ .first = 0x17D, .last = 0x17D, .delta = 1 },
    .{ .first = 0x17F, .last = 0x17F, .delta = -268 },
    .{ .first = 0x181, .last = 0x181, .delta = 210 },
    .{ .first = 0x182, .last = 0x182, .delta = 1 },
    .{ .first = 0x184, .last = 0x184, .delta = 1 },
    .{ .first = 0x186, .last = 0x186, .delta = 206 },
    .{ .first = 0x187, .last = 0x187, .delta = 1 },
    .{ .first = 0x189, .last = 0x18A, .delta = 205 },
    .{ .first = 0x18B, .last = 0x18B, .delta = 1 },
    .{ .first = 0x18E, .last = 0x18E, .delta = 79 },
    .{ .first = 0x18F, .last = 0x18F, .delta = 202 },
    .{ .first = 0x190, .last = 0x190, .delta = 203 },
    .{ .first = 0x191, .last = 0x191, .delta = 1 },
    .{ .first = 0x193, .last = 0x193, .delta = 205 },
    .{ .first = 0x194, .last = 0x194, .delta = 207 },
    .{ .first = 0x196, .last = 0x196, .delta = 211 },
    .{ .first = 0x197, .last = 0x197, .delta = 209 },
    .{ .first = 0x198, .last = 0x198, .delta = 1 },
    .{ .first = 0x19C, .last = 0x19C, .delta = 211 },
    .{ .first = 0x19D, .last = 0x19D, .delta = 213 },
    .{ .first = 0x19F, .last = 0x19F, .delta = 214 },
    .{ .first = 0x1A0, .last = 0x1A0, .delta = 1 },
    .{ .first = 0x1A2, .last = 0x1A2, .delta = 1 },
    .{ .first = 0x1A4, .last = 0x1A4, .delta = 1 },
    .{ .first = 0x1A6, .last = 0x1A6, .delta = 218 },
    .{ .first = 0x1A7, .last = 0x1A7, .delta = 1 },
    .{ .first = 0x1A9, .last = 0x1A9, .delta = 218 },
    .{ .first = 0x1AC, .last = 0x1AC, .delta = 1 },
    .{ .first = 0x1AE, .last = 0x1AE, .delta = 218 },
    .{ .first = 0x1AF, .last = 0x1AF, .delta = 1 },
    .{ .first = 0x1B1, .last = 0x1B2, .delta = 217 },
    .{ .first = 0x1B3, .last = 0x1B3, .delta = 1 },
    .{ .first = 0x1B5, .last = 0x1B5, .delta = 1 },
    .{ .first = 0x1B7, .last = 0x1B7, .delta = 219 },
    .{ .first = 0x1B8, .last = 0x1B8, .delta = 1 },
    .{ .first = 0x1BC, .last = 0x1BC, .delta = 1 },
    .{ .first = 0x1C4, .last = 0x1C4, .delta = 2 },
    .{ .first = 0x1C5, .last = 0x1C5, .delta = 1 },
    .{ .first = 0x1C7, .last = 0x1C7, .delta = 2 },
    .{ .first = 0x1C8, .last = 0x1C8, .delta = 1 },
    .{ .first = 0x1CA, .last = 0x1CA, .delta = 2 },
    .{ .first = 0x1CB, .last = 0x1CB, .delta = 1 },
    .{ .first = 0x1CD, .last = 0x1CD, .delta = 1 },
    .{ .first = 0x1CF, .last = 0x1CF, .delta = 1 },
    .{ .first = 0x1D1, .last = 0x1D1, .delta = 1 },
    .{ .first = 0x1D3, .last = 0x1D3, .delta = 1 },
    .{ .first = 0x1D5, .last = 0x1D5, .delta = 1 },
    .{ .first = 0x1D7, .last = 0x1D7, .delta = 1 },
    .{ .first = 0x1D9, .last = 0x1D9, .delta = 1 },
    .{ .first = 0x1DB, .last = 0x1DB, .delta = 1 },
    .{ .first = 0x1DE, .last = 0x1DE, .delta = 1 },
    .{ .first = 0x1E0, .last = 0x1E0, .delta = 1 },
    .{ .first = 0x1E2, .last = 0x1E2, .delta = 1 },
    .{ .first = 0x1E4, .last = 0x1E4, .delta = 1 },
    .{ .first = 0x1E6, .last = 0x1E6, .delta = 1 },
    .{ .first = 0x1E8, .last = 0x1E8, .delta = 1 },
    .{ .first = 0x1EA, .last = 0x1EA, .delta = 1 },
    .{ .first = 0x1EC, .last = 0x1EC, .delta = 1 },
    .{ .first = 0x1EE, .last = 0x1EE, .delta = 1 },
    .{ .first = 0x1F1, .last = 0x1F1, .delta = 2 },
    .{ .first = 0x1F2, .last = 0x1F2, .delta = 1 },
    .{ .first = 0x1F4, .last = 0x1F4, .delta = 1 },
    .{ .first = 0x1F6, .last = 0x1F6, .delta = -97 },
    .{ .first = 0x1F7, .last = 0x1F7, .delta = -56 },
    .{ .first = 0x1F8, .last = 0x1F8, .delta = 1 },
    .{ .first = 0x1FA, .last = 0x1FA, .delta = 1 },
    .{ .first = 0x1FC, .last = 0x1FC, .delta = 1 },
    .{ .first = 0x1FE, .last = 0x1FE, .delta = 1 },
    .{ .first = 0x200, .last = 0x200, .delta = 1 },
    .{ .first = 0x202, .last = 0x202, .delta = 1 },
    .{ .first = 0x204, .last = 0x204, .delta = 1 },
    .{ .first = 0x206, .last = 0x206, .delta = 1 },
    .{ .first = 0x208, .last = 0x208, .delta = 1 },
    .{ .first = 0x20A, .last = 0x20A, .delta = 1 },
    .{ .first = 0x20C, .last = 0x20C, .delta = 1 },
    .{ .first = 0x20E, .last = 0x20E, .delta = 1 },
    .{ .first = 0x210, .last = 0x210, .delta = 1 },
    .{ .first = 0x212, .last = 0x212, .delta = 1 },
    .{ .first = 0x214, .last = 0x214, .delta = 1 },
    .{ .first = 0x216, .last = 0x216, .delta = 1 },
    .{ .first = 0x218, .last = 0x218, .delta = 1 },
    .{ .first = 0x21A, .last = 0x21A, .delta = 1 },
    .{ .first = 0x21C, .last = 0x21C, .delta = 1 },
    .{ .first = 0x21E, .last = 0x21E, .delta = 1 },
    .{ .first = 0x220, .last = 0x220, .delta = -130 },
    .{ .first = 0x222, .last = 0x222, .delta = 1 },
    .{ .first = 0x224, .last = 0x224, .delta = 1 },
    .{ .first = 0x226, .last = 0x226, .delta = 1 },
    .{ .first = 0x228, .last = 0x228, .delta = 1 },
    .{ .first = 0x22A, .last = 0x22A, .delta = 1 },
    .{ .first = 0x22C, .last = 0x22C, .delta = 1 },
    .{ .first = 0x22E, .last = 0x22E, .delta = 1 },
    .{ .first = 0x230, .last = 0x230, .delta = 1 },
    .{ .first = 0x232, .last = 0x232, .delta = 1 },
    .{ .first = 0x23A, .last = 0x23A, .delta = 10795 },
    .{ .first = 0x23B, .last = 0x23B, .delta = 1 },
    .{ .first = 0x23D, .last = 0x23D, .delta = -163 },
    .{ .first = 0x23E, .last = 0x23E, .delta = 10792 },
    .{ .first = 0x241, .last = 0x241, .delta = 1 },
    .{ .first = 0x243, .last = 0x243, .delta = -195 },
    .{ .first = 0x244, .last = 0x244, .delta = 69 },
    .{ .first = 0x245, .last = 0x245, .delta = 71 },
    .{ .first = 0x246, .last = 0x246, .delta = 1 },
    .{ .first = 0x248, .last = 0x248, .delta = 1 },
    .{ .first = 0x24A, .last = 0x24A, .delta = 1 },
    .{ .first = 0x24C, .last = 0x24C, .delta = 1 },
    .{ .first = 0x24E, .last = 0x24E, .delta = 1 },
    .{ .first = 0x345, .last = 0x345, .delta = 116 },
    .{ .first = 0x370, .last = 0x370, .delta = 1 },
    .{ .first = 0x372, .last = 0x372, .delta = 1 },
    .{ .first = 0x376, .last = 0x376, .delta = 1 },
    .{ .first = 0x37F, .last = 0x37F, .delta = 116 },
    .{ .first = 0x386, .last = 0x386, .delta = 38 },
    .{ .first = 0x388, .last = 0x38A, .delta = 37 },
    .{ .first = 0x38C, .last = 0x38C, .delta = 64 },
    .{ .first = 0x38E, .last = 0x38F, .delta = 63 },
    .{ .first = 0x391, .last = 0x3A1, .delta = 32 },
    .{ .first = 0x3A3, .last = 0x3AB, .delta = 32 },
    .{ .first = 0x3C2, .last = 0x3C2, .delta = 1 },
    .{ .first = 0x3CF, .last = 0x3CF, .delta = 8 },
    .{ .first = 0x3D0, .last = 0x3D0, .delta = -30 },
    .{ .first = 0x3D1, .last = 0x3D1, .delta = -25 },
    .{ .first = 0x3D5, .last = 0x3D5, .delta = -15 },
    .{ .first = 0x3D6, .last = 0x3D6, .delta = -22 },
    .{ .first = 0x3D8, .last = 0x3D8, .delta = 1 },
    .{ .first = 0x3DA, .last = 0x3DA, .delta = 1 },
    .{ .first = 0x3DC, .last = 0x3DC, .delta = 1 },
    .{ .first = 0x3DE, .last = 0x3DE, .delta = 1 },
    .{ .first = 0x3E0, .last = 0x3E0, .delta = 1 },
    .{ .first = 0x3E2, .last = 0x3E2, .delta = 1 },
    .{ .first = 0x3E4, .last = 0x3E4, .delta = 1 },
    .{ .first = 0x3E6, .last = 0x3E6, .delta = 1 },
    .{ .first = 0x3E8, .last = 0x3E8, .delta = 1 },
    .{ .first = 0x3EA, .last = 0x3EA, .delta = 1 },
    .{ .first = 0x3EC, .last = 0x3EC, .delta = 1 },
    .{ .first = 0x3EE, .last = 0x3EE, .delta = 1 },
    .{ .first = 0x3F0, .last = 0x3F0, .delta = -54 },
    .{ .first = 0x3F1, .last = 0x3F1, .delta = -48 },
    .{ .first = 0x3F4, .last = 0x3F4, .delta = -60 },
    .{ .first = 0x3F5, .last = 0x3F5, .delta = -64 },
    .{ .first = 0x3F7, .last = 0x3F7, .delta = 1 },
    .{ .first = 0x3F9, .last = 0x3F9, .delta = -7 },
    .{ .first = 0x3FA, .last = 0x3FA, .delta = 1 },
    .{ .first = 0x3FD, .last = 0x3FF, .delta = -130 },
    .{ .first = 0x400, .last = 0x40F, .delta = 80 },
    .{ .first = 0x410, .last = 0x42F, .delta = 32 },
    .{ .first = 0x460, .last = 0x460, .delta = 1 },
    .{ .first = 0x462, .last = 0x462, .delta = 1 },
    .{ .first = 0x464, .last = 0x464, .delta = 1 },
    .{ .first = 0x466, .last = 0x466, .delta = 1 },
    .{ .first = 0x468, .last = 0x468, .delta = 1 },
    .{ .first = 0x46A, .last = 0x46A, .delta = 1 },
    .{ .first = 0x46C, .last = 0x46C, .delta = 1 },
    .{ .first = 0x46E, .last = 0x46E, .delta = 1 },
    .{ .first = 0x470, .last = 0x470, .delta = 1 },
    .{ .first = 0x472, .last = 0x472, .delta = 1 },
    .{ .first = 0x474, .last = 0x474, .delta = 1 },
    .{ .first = 0x476, .last = 0x476, .delta = 1 },
    .{ .first = 0x478, .last = 0x478, .delta = 1 },
    .{ .first = 0x47A, .last = 0x47A, .delta = 1 },
    .{ .first = 0x47C, .last = 0x47C, .delta = 1 },
    .{ .first = 0x47E, .last = 0x47E, .delta = 1 },
    .{ .first = 0x480, .last = 0x480, .delta = 1 },
    .{ .first = 0x48A, .last = 0x48A, .delta = 1 },
    .{ .first = 0x48C, .last = 0x48C, .delta = 1 },
    .{ .first = 0x48E, .last = 0x48E, .delta = 1 },
    .{ .first = 0x490, .last = 0x490, .delta = 1 },
    .{ .first = 0x492, .last = 0x492, .delta = 1 },
    .{ .first = 0x494, .last = 0x494, .delta = 1 },
    .{ .first = 0x496, .last = 0x496, .delta = 1 },
    .{ .first = 0x498, .last = 0x498, .delta = 1 },
    .{ .first = 0x49A, .last = 0x49A, .delta = 1 },
    .{ .first = 0x49C, .last = 0x49C, .delta = 1 },
    .{ .first = 0x49E, .last = 0x49E, .delta = 1 },
    .{ .first = 0x4A0, .last = 0x4A0, .delta = 1 },
    .{ .first = 0x4A2, .last = 0x4A2, .delta = 1 },
    .{ .first = 0x4A4, .last = 0x4A4, .delta = 1 },
    .{ .first = 0x4A6, .last = 0x4A6, .delta = 1 },
    .{ .first = 0x4A8, .last = 0x4A8, .delta = 1 },
    .{ .first = 0x4AA, .last = 0x4AA, .delta = 1 },
    .{ .first = 0x4AC, .last = 0x4AC, .delta = 1 },
    .{ .first = 0x4AE, .last = 0x4AE, .delta = 1 },
    .{ .first = 0x4B0, .last = 0x4B0, .delta = 1 },
    .{ .first = 0x4B2, .last = 0x4B2, .delta = 1 },
    .{ .first = 0x4B4, .last = 0x4B4, .delta = 1 },
    .{ .first = 0x4B6, .last = 0x4B6, .delta = 1 },
    .{ .first = 0x4B8, .last = 0x4B8, .delta = 1 },
    .{ .first = 0x4BA, .last = 0x4BA, .delta = 1 },
    .{ .first = 0x4BC, .last = 0x4BC, .delta = 1 },
    .{ .first = 0x4BE, .last = 0x4BE, .delta = 1 },
    .{ .first = 0x4C0, .last = 0x4C0, .delta = 15 },
    .{ .first = 0x4C1, .last = 0x4C1, .delta = 1 },
    .{ .first = 0x4C3, .last = 0x4C3, .delta = 1 },
    .{ .first = 0x4C5, .last = 0x4C5, .delta = 1 },
    .{ .first = 0x4C7, .last = 0x4C7, .delta = 1 },
    .{ .first = 0x4C9, .last = 0x4C9, .delta = 1 },
    .{ .first = 0x4CB, .last = 0x4CB, .delta = 1 },
    .{ .first = 0x4CD, .last = 0x4CD, .delta = 1 },
    .{ .first = 0x4D0, .last = 0x4D0, .delta = 1 },
    .{ .first = 0x4D2, .last = 0x4D2, .delta = 1 },
    .{ .first = 0x4D4, .last = 0x4D4, .delta = 1 },
    .{ .first = 0x4D6, .last = 0x4D6, .delta = 1 },
    .{ .first = 0x4D8, .last = 0x4D8, .delta = 1 },
    .{ .first = 0x4DA, .last = 0x4DA, .delta = 1 },
    .{ .first = 0x4DC, .last = 0x4DC, .delta = 1 },
    .{ .first = 0x4DE, .last = 0x4DE, .delta = 1 },
    .{ .first = 0x4E0, .last = 0x4E0, .delta = 1 },
    .{ .first = 0x4E2, .last = 0x4E2, .delta = 1 },
    .{ .first = 0x4E4, .last = 0x4E4, .delta = 1 },
    .{ .first = 0x4E6, .last = 0x4E6, .delta = 1 },
    .{ .first = 0x4E8, .last = 0x4E8, .delta = 1 },
    .{ .first = 0x4EA, .last = 0x4EA, .delta = 1 },
    .{ .first = 0x4EC, .last = 0x4EC, .delta = 1 },
    .{ .first = 0x4EE, .last = 0x4EE, .delta = 1 },
    .{ .first = 0x4F0, .last = 0x4F0, .delta = 1 },
    .{ .first = 0x4F2, .last = 0x4F2, .delta = 1 },
    .{ .first = 0x4F4, .last = 0x4F4, .delta = 1 },
    .{ .first = 0x4F6, .last = 0x4F6, .delta = 1 },
    .{ .first = 0x4F8, .last = 0x4F8, .delta = 1 },
    .{ .first = 0x4FA, .last = 0x4FA, .delta = 1 },
    .{ .first = 0x4FC, .last = 0x4FC, .delta = 1 },
    .{ .first = 0x4FE, .last = 0x4FE, .delta = 1 },
    .{ .first = 0x500, .last = 0x500, .delta = 1 },
    .{ .first = 0x502, .last = 0x502, .delta = 1 },
    .{ .first = 0x504, .last = 0x504, .delta = 1 },
    .{ .first = 0x506, .last = 0x506, .delta = 1 },
    .{ .first = 0x508, .last = 0x508, .delta = 1 },
    .{ .first = 0x50A, .last = 0x50A, .delta = 1 },
    .{ .first = 0x50C, .last = 0x50C, .delta = 1 },
    .{ .first = 0x50E, .last = 0x50E, .delta = 1 },
    .{ .first = 0x510, .last = 0x510, .delta = 1 },
    .{ .first = 0x512, .last = 0x512, .delta = 1 },
    .{ .first = 0x514, .last = 0x514, .delta = 1 },
    .{ .first = 0x516, .last = 0x516, .delta = 1 },
    .{ .first = 0x518, .last = 0x518, .delta = 1 },
    .{ .first = 0x51A, .last = 0x51A, .delta = 1 },
    .{ .first = 0x51C, .last = 0x51C, .delta = 1 },
    .{ .first = 0x51E, .last = 0x51E, .delta = 1 },
    .{ .first = 0x520, .last = 0x520, .delta = 1 },
    .{ .first = 0x522, .last = 0x522, .delta = 1 },
    .{ .first = 0x524, .last = 0x524, .delta = 1 },
    .{ .first = 0x526, .last = 0x526, .delta = 1 },
    .{ .first = 0x528, .last = 0x528, .delta = 1 },
    .{ .first = 0x52A, .last = 0x52A, .delta = 1 },
    .{ .first = 0x52C, .last = 0x52C, .delta = 1 },
    .{ .first = 0x52E, .last = 0x52E, .delta = 1 },
    .{ .first = 0x531, .last = 0x556, .delta = 48 },
    .{ .first = 0x10A0, .last = 0x10C5, .delta = 7264 },
    .{ .first = 0x10C7, .last = 0x10C7, .delta = 7264 },
    .{ .first = 0x10CD, .last = 0x10CD, .delta = 7264 },
    .{ .first = 0x13F8, .last = 0x13FD, .delta = -8 },
    .{ .first = 0x1C80, .last = 0x1C80, .delta = -6222 },
    .{ .first = 0x1C81, .last = 0x1C81, .delta = -6221 },
    .{ .first = 0x1C82, .last = 0x1C82, .delta = -6212 },
    .{ .first = 0x1C83, .last = 0x1C84, .delta = -6210 },
    .{ .first = 0x1C85, .last = 0x1C85, .delta = -6211 },
    .{ .first = 0x1C86, .last = 0x1C86, .delta = -6204 },
    .{ .first = 0x1C87, .last = 0x1C87, .delta = -6180 },
    .{ .first = 0x1C88, .last = 0x1C88, .delta = 35267 },
    .{ .first = 0x1C89, .last = 0x1C89, .delta = 1 },
    .{ .first = 0x1C90, .last = 0x1CBA, .delta = -3008 },
    .{ .first = 0x1CBD, .last = 0x1CBF, .delta = -3008 },
    .{ .first = 0x1E00, .last = 0x1E00, .delta = 1 },
    .{ .first = 0x1E02, .last = 0x1E02, .delta = 1 },
    .{ .first = 0x1E04, .last = 0x1E04, .delta = 1 },
    .{ .first = 0x1E06, .last = 0x1E06, .delta = 1 },
    .{ .first = 0x1E08, .last = 0x1E08, .delta = 1 },
    .{ .first = 0x1E0A, .last = 0x1E0A, .delta = 1 },
    .{ .first = 0x1E0C, .last = 0x1E0C, .delta = 1 },
    .{ .first = 0x1E0E, .last = 0x1E0E, .delta = 1 },
    .{ .first = 0x1E10, .last = 0x1E10, .delta = 1 },
    .{ .first = 0x1E12, .last = 0x1E12, .delta = 1 },
    .{ .first = 0x1E14, .last = 0x1E14, .delta = 1 },
    .{ .first = 0x1E16, .last = 0x1E16, .delta = 1 },
    .{ .first = 0x1E18, .last = 0x1E18, .delta = 1 },
    .{ .first = 0x1E1A, .last = 0x1E1A, .delta = 1 },
    .{ .first = 0x1E1C, .last = 0x1E1C, .delta = 1 },
    .{ .first = 0x1E1E, .last = 0x1E1E, .delta = 1 },
    .{ .first = 0x1E20, .last = 0x1E20, .delta = 1 },
    .{ .first = 0x1E22, .last = 0x1E22, .delta = 1 },
    .{ .first = 0x1E24, .last = 0x1E24, .delta = 1 },
    .{ .first = 0x1E26, .last = 0x1E26, .delta = 1 },
    .{ .first = 0x1E28, .last = 0x1E28, .delta = 1 },
    .{ .first = 0x1E2A, .last = 0x1E2A, .delta = 1 },
    .{ .first = 0x1E2C, .last = 0x1E2C, .delta = 1 },
    .{ .first = 0x1E2E, .last = 0x1E2E, .delta = 1 },
    .{ .first = 0x1E30, .last = 0x1E30, .delta = 1 },
    .{ .first = 0x1E32, .last = 0x1E32, .delta = 1 },
    .{ .first = 0x1E34, .last = 0x1E34, .delta = 1 },
    .{ .first = 0x1E36, .last = 0x1E36, .delta = 1 },
    .{ .first = 0x1E38, .last = 0x1E38, .delta = 1 },
    .{ .first = 0x1E3A, .last = 0x1E3A, .delta = 1 },
    .{ .first = 0x1E3C, .last = 0x1E3C, .delta = 1 },
    .{ .first = 0x1E3E, .last = 0x1E3E, .delta = 1 },
    .{ .first = 0x1E40, .last = 0x1E40, .delta = 1 },
    .{ .first = 0x1E42, .last = 0x1E42, .delta = 1 },
    .{ .first = 0x1E44, .last = 0x1E44, .delta = 1 },
    .{ .first = 0x1E46, .last = 0x1E46, .delta = 1 },
    .{ .first = 0x1E48, .last = 0x1E48, .delta = 1 },
    .{ .first = 0x1E4A, .last = 0x1E4A, .delta = 1 },
    .{ .first = 0x1E4C, .last = 0x1E4C, .delta = 1 },
    .{ .first = 0x1E4E, .last = 0x1E4E, .delta = 1 },
    .{ .first = 0x1E50, .last = 0x1E50, .delta = 1 },
    .{ .first = 0x1E52, .last = 0x1E52, .delta = 1 },
    .{ .first = 0x1E54, .last = 0x1E54, .delta = 1 },
    .{ .first = 0x1E56, .last = 0x1E56, .delta = 1 },
    .{ .first = 0x1E58, .last = 0x1E58, .delta = 1 },
    .{ .first = 0x1E5A, .last = 0x1E5A, .delta = 1 },
    .{ .first = 0x1E5C, .last = 0x1E5C, .delta = 1 },
    .{ .first = 0x1E5E, .last = 0x1E5E, .delta = 1 },
    .{ .first = 0x1E60, .last = 0x1E60, .delta = 1 },
    .{ .first = 0x1E62, .last = 0x1E62, .delta = 1 },
    .{ .first = 0x1E64, .last = 0x1E64, .delta = 1 },
    .{ .first = 0x1E66, .last = 0x1E66, .delta = 1 },
    .{ .first = 0x1E68, .last = 0x1E68, .delta = 1 },
    .{ .first = 0x1E6A, .last = 0x1E6A, .delta = 1 },
    .{ .first = 0x1E6C, .last = 0x1E6C, .delta = 1 },
    .{ .first = 0x1E6E, .last = 0x1E6E, .delta = 1 },
    .{ .first = 0x1E70, .last = 0x1E70, .delta = 1 },
    .{ .first = 0x1E72, .last = 0x1E72, .delta = 1 },
    .{ .first = 0x1E74, .last = 0x1E74, .delta = 1 },
    .{ .first = 0x1E76, .last = 0x1E76, .delta = 1 },
    .{ .first = 0x1E78, .last = 0x1E78, .delta = 1 },
    .{ .first = 0x1E7A, .last = 0x1E7A, .delta = 1 },
    .{ .first = 0x1E7C, .last = 0x1E7C, .delta = 1 },
    .{ .first = 0x1E7E, .last = 0x1E7E, .delta = 1 },
    .{ .first = 0x1E80, .last = 0x1E80, .delta = 1 },
    .{ .first = 0x1E82, .last = 0x1E82, .delta = 1 },
    .{ .first = 0x1E84, .last = 0x1E84, .delta = 1 },
    .{ .first = 0x1E86, .last = 0x1E86, .delta = 1 },
    .{ .first = 0x1E88, .last = 0x1E88, .delta = 1 },
    .{ .first = 0x1E8A, .last = 0x1E8A, .delta = 1 },
    .{ .first = 0x1E8C, .last = 0x1E8C, .delta = 1 },
    .{ .first = 0x1E8E, .last = 0x1E8E, .delta = 1 },
    .{ .first = 0x1E90, .last = 0x1E90, .delta = 1 },
    .{ .first = 0x1E92, .last = 0x1E92, .delta = 1 },
    .{ .first = 0x1E94, .last = 0x1E94, .delta = 1 },
    .{ .first = 0x1E9B, .last = 0x1E9B, .delta = -58 },
    .{ .first = 0x1E9E, .last = 0x1E9E, .delta = -7615 },
    .{ .first = 0x1EA0, .last = 0x1EA0, .delta = 1 },
    .{ .first = 0x1EA2, .last = 0x1EA2, .delta = 1 },
    .{ .first = 0x1EA4, .last = 0x1EA4, .delta = 1 },
    .{ .first = 0x1EA6, .last = 0x1EA6, .delta = 1 },
    .{ .first = 0x1EA8, .last = 0x1EA8, .delta = 1 },
    .{ .first = 0x1EAA, .last = 0x1EAA, .delta = 1 },
    .{ .first = 0x1EAC, .last = 0x1EAC, .delta = 1 },
    .{ .first = 0x1EAE, .last = 0x1EAE, .delta = 1 },
    .{ .first = 0x1EB0, .last = 0x1EB0, .delta = 1 },
    .{ .first = 0x1EB2, .last = 0x1EB2, .delta = 1 },
    .{ .first = 0x1EB4, .last = 0x1EB4, .delta = 1 },
    .{ .first = 0x1EB6, .last = 0x1EB6, .delta = 1 },
    .{ .first = 0x1EB8, .last = 0x1EB8, .delta = 1 },
    .{ .first = 0x1EBA, .last = 0x1EBA, .delta = 1 },
    .{ .first = 0x1EBC, .last = 0x1EBC, .delta = 1 },
    .{ .first = 0x1EBE, .last = 0x1EBE, .delta = 1 },
    .{ .first = 0x1EC0, .last = 0x1EC0, .delta = 1 },
    .{ .first = 0x1EC2, .last = 0x1EC2, .delta = 1 },
    .{ .first = 0x1EC4, .last = 0x1EC4, .delta = 1 },
    .{ .first = 0x1EC6, .last = 0x1EC6, .delta = 1 },
    .{ .first = 0x1EC8, .last = 0x1EC8, .delta = 1 },
    .{ .first = 0x1ECA, .last = 0x1ECA, .delta = 1 },
    .{ .first = 0x1ECC, .last = 0x1ECC, .delta = 1 },
    .{ .first = 0x1ECE, .last = 0x1ECE, .delta = 1 },
    .{ .first = 0x1ED0, .last = 0x1ED0, .delta = 1 },
    .{ .first = 0x1ED2, .last = 0x1ED2, .delta = 1 },
    .{ .first = 0x1ED4, .last = 0x1ED4, .delta = 1 },
    .{ .first = 0x1ED6, .last = 0x1ED6, .delta = 1 },
    .{ .first = 0x1ED8, .last = 0x1ED8, .delta = 1 },
    .{ .first = 0x1EDA, .last = 0x1EDA, .delta = 1 },
    .{ .first = 0x1EDC, .last = 0x1EDC, .delta = 1 },
    .{ .first = 0x1EDE, .last = 0x1EDE, .delta = 1 },
    .{ .first = 0x1EE0, .last = 0x1EE0, .delta = 1 },
    .{ .first = 0x1EE2, .last = 0x1EE2, .delta = 1 },
    .{ .first = 0x1EE4, .last = 0x1EE4, .delta = 1 },
    .{ .first = 0x1EE6, .last = 0x1EE6, .delta = 1 },
    .{ .first = 0x1EE8, .last = 0x1EE8, .delta = 1 },
    .{ .first = 0x1EEA, .last = 0x1EEA, .delta = 1 },
    .{ .first = 0x1EEC, .last = 0x1EEC, .delta = 1 },
    .{ .first = 0x1EEE, .last = 0x1EEE, .delta = 1 },
    .{ .first = 0x1EF0, .last = 0x1EF0, .delta = 1 },
    .{ .first = 0x1EF2, .last = 0x1EF2, .delta = 1 },
    .{ .first = 0x1EF4, .last = 0x1EF4, .delta = 1 },
    .{ .first = 0x1EF6, .last = 0x1EF6, .delta = 1 },
    .{ .first = 0x1EF8, .last = 0x1EF8, .delta = 1 },
    .{ .first = 0x1EFA, .last = 0x1EFA, .delta = 1 },
    .{ .first = 0x1EFC, .last = 0x1EFC, .delta = 1 },
    .{ .first = 0x1EFE, .last = 0x1EFE, .delta = 1 },
    .{ .first = 0x1F08, .last = 0x1F0F, .delta = -8 },
    .{ .first = 0x1F18, .last = 0x1F1D, .delta = -8 },
    .{ .first = 0x1F28, .last = 0x1F2F, .delta = -8 },
    .{ .first = 0x1F38, .last = 0x1F3F, .delta = -8 },
    .{ .first = 0x1F48, .last = 0x1F4D, .delta = -8 },
    .{ .first = 0x1F59, .last = 0x1F59, .delta = -8 },
    .{ .first = 0x1F5B, .last = 0x1F5B, .delta = -8 },
    .{ .first = 0x1F5D, .last = 0x1F5D, .delta = -8 },
    .{ .first = 0x1F5F, .last = 0x1F5F, .delta = -8 },
    .{ .first = 0x1F68, .last = 0x1F6F, .delta = -8 },
    .{ .first = 0x1F88, .last = 0x1F8F, .delta = -8 },
    .{ .first = 0x1F98, .last = 0x1F9F, .delta = -8 },
    .{ .first = 0x1FA8, .last = 0x1FAF, .delta = -8 },
    .{ .first = 0x1FB8, .last = 0x1FB9, .delta = -8 },
    .{ .first = 0x1FBA, .last = 0x1FBB, .delta = -74 },
    .{ .first = 0x1FBC, .last = 0x1FBC, .delta = -9 },
    .{ .first = 0x1FBE, .last = 0x1FBE, .delta = -7173 },
    .{ .first = 0x1FC8, .last = 0x1FCB, .delta = -86 },
    .{ .first = 0x1FCC, .last = 0x1FCC, .delta = -9 },
    .{ .first = 0x1FD3, .last = 0x1FD3, .delta = -7235 },
    .{ .first = 0x1FD8, .last = 0x1FD9, .delta = -8 },
    .{ .first = 0x1FDA, .last = 0x1FDB, .delta = -100 },
    .{ .first = 0x1FE3, .last = 0x1FE3, .delta = -7219 },
    .{ .first = 0x1FE8, .last = 0x1FE9, .delta = -8 },
    .{ .first = 0x1FEA, .last = 0x1FEB, .delta = -112 },
    .{ .first = 0x1FEC, .last = 0x1FEC, .delta = -7 },
    .{ .first = 0x1FF8, .last = 0x1FF9, .delta = -128 },
    .{ .first = 0x1FFA, .last = 0x1FFB, .delta = -126 },
    .{ .first = 0x1FFC, .last = 0x1FFC, .delta = -9 },
    .{ .first = 0x2126, .last = 0x2126, .delta = -7517 },
    .{ .first = 0x212A, .last = 0x212A, .delta = -8383 },
    .{ .first = 0x212B, .last = 0x212B, .delta = -8262 },
    .{ .first = 0x2132, .last = 0x2132, .delta = 28 },
    .{ .first = 0x2160, .last = 0x216F, .delta = 16 },
    .{ .first = 0x2183, .last = 0x2183, .delta = 1 },
    .{ .first = 0x24B6, .last = 0x24CF, .delta = 26 },
    .{ .first = 0x2C00, .last = 0x2C2F, .delta = 48 },
    .{ .first = 0x2C60, .last = 0x2C60, .delta = 1 },
    .{ .first = 0x2C62, .last = 0x2C62, .delta = -10743 },
    .{ .first = 0x2C63, .last = 0x2C63, .delta = -3814 },
    .{ .first = 0x2C64, .last = 0x2C64, .delta = -10727 },
    .{ .first = 0x2C67, .last = 0x2C67, .delta = 1 },
    .{ .first = 0x2C69, .last = 0x2C69, .delta = 1 },
    .{ .first = 0x2C6B, .last = 0x2C6B, .delta = 1 },
    .{ .first = 0x2C6D, .last = 0x2C6D, .delta = -10780 },
    .{ .first = 0x2C6E, .last = 0x2C6E, .delta = -10749 },
    .{ .first = 0x2C6F, .last = 0x2C6F, .delta = -10783 },
    .{ .first = 0x2C70, .last = 0x2C70, .delta = -10782 },
    .{ .first = 0x2C72, .last = 0x2C72, .delta = 1 },
    .{ .first = 0x2C75, .last = 0x2C75, .delta = 1 },
    .{ .first = 0x2C7E, .last = 0x2C7F, .delta = -10815 },
    .{ .first = 0x2C80, .last = 0x2C80, .delta = 1 },
    .{ .first = 0x2C82, .last = 0x2C82, .delta = 1 },
    .{ .first = 0x2C84, .last = 0x2C84, .delta = 1 },
    .{ .first = 0x2C86, .last = 0x2C86, .delta = 1 },
    .{ .first = 0x2C88, .last = 0x2C88, .delta = 1 },
    .{ .first = 0x2C8A, .last = 0x2C8A, .delta = 1 },
    .{ .first = 0x2C8C, .last = 0x2C8C, .delta = 1 },
    .{ .first = 0x2C8E, .last = 0x2C8E, .delta = 1 },
    .{ .first = 0x2C90, .last = 0x2C90, .delta = 1 },
    .{ .first = 0x2C92, .last = 0x2C92, .delta = 1 },
    .{ .first = 0x2C94, .last = 0x2C94, .delta = 1 },
    .{ .first = 0x2C96, .last = 0x2C96, .delta = 1 },
    .{ .first = 0x2C98, .last = 0x2C98, .delta = 1 },
    .{ .first = 0x2C9A, .last = 0x2C9A, .delta = 1 },
    .{ .first = 0x2C9C, .last = 0x2C9C, .delta = 1 },
    .{ .first = 0x2C9E, .last = 0x2C9E, .delta = 1 },
    .{ .first = 0x2CA0, .last = 0x2CA0, .delta = 1 },
    .{ .first = 0x2CA2, .last = 0x2CA2, .delta = 1 },
    .{ .first = 0x2CA4, .last = 0x2CA4, .delta = 1 },
    .{ .first = 0x2CA6, .last = 0x2CA6, .delta = 1 },
    .{ .first = 0x2CA8, .last = 0x2CA8, .delta = 1 },
    .{ .first = 0x2CAA, .last = 0x2CAA, .delta = 1 },
    .{ .first = 0x2CAC, .last = 0x2CAC, .delta = 1 },
    .{ .first = 0x2CAE, .last = 0x2CAE, .delta = 1 },
    .{ .first = 0x2CB0, .last = 0x2CB0, .delta = 1 },
    .{ .first = 0x2CB2, .last = 0x2CB2, .delta = 1 },
    .{ .first = 0x2CB4, .last = 0x2CB4, .delta = 1 },
    .{ .first = 0x2CB6, .last = 0x2CB6, .delta = 1 },
    .{ .first = 0x2CB8, .last = 0x2CB8, .delta = 1 },
    .{ .first = 0x2CBA, .last = 0x2CBA, .delta = 1 },
    .{ .first = 0x2CBC, .last = 0x2CBC, .delta = 1 },
    .{ .first = 0x2CBE, .last = 0x2CBE, .delta = 1 },
    .{ .first = 0x2CC0, .last = 0x2CC0, .delta = 1 },
    .{ .first = 0x2CC2, .last = 0x2CC2, .delta = 1 },
    .{ .first = 0x2CC4, .last = 0x2CC4, .delta = 1 },
    .{ .first = 0x2CC6, .last = 0x2CC6, .delta = 1 },
    .{ .first = 0x2CC8, .last = 0x2CC8, .delta = 1 },
    .{ .first = 0x2CCA, .last = 0x2CCA, .delta = 1 },
    .{ .first = 0x2CCC, .last = 0x2CCC, .delta = 1 },
    .{ .first = 0x2CCE, .last = 0x2CCE, .delta = 1 },
    .{ .first = 0x2CD0, .last = 0x2CD0, .delta = 1 },
    .{ .first = 0x2CD2, .last = 0x2CD2, .delta = 1 },
    .{ .first = 0x2CD4, .last = 0x2CD4, .delta = 1 },
    .{ .first = 0x2CD6, .last = 0x2CD6, .delta = 1 },
    .{ .first = 0x2CD8, .last = 0x2CD8, .delta = 1 },
    .{ .first = 0x2CDA, .last = 0x2CDA, .delta = 1 },
    .{ .first = 0x2CDC, .last = 0x2CDC, .delta = 1 },
    .{ .first = 0x2CDE, .last = 0x2CDE, .delta = 1 },
    .{ .first = 0x2CE0, .last = 0x2CE0, .delta = 1 },
    .{ .first = 0x2CE2, .last = 0x2CE2, .delta = 1 },
    .{ .first = 0x2CEB, .last = 0x2CEB, .delta = 1 },
    .{ .first = 0x2CED, .last = 0x2CED, .delta = 1 },
    .{ .first = 0x2CF2, .last = 0x2CF2, .delta = 1 },
    .{ .first = 0xA640, .last = 0xA640, .delta = 1 },
    .{ .first = 0xA642, .last = 0xA642, .delta = 1 },
    .{ .first = 0xA644, .last = 0xA644, .delta = 1 },
    .{ .first = 0xA646, .last = 0xA646, .delta = 1 },
    .{ .first = 0xA648, .last = 0xA648, .delta = 1 },
    .{ .first = 0xA64A, .last = 0xA64A, .delta = 1 },
    .{ .first = 0xA64C, .last = 0xA64C, .delta = 1 },
    .{ .first = 0xA64E, .last = 0xA64E, .delta = 1 },
    .{ .first = 0xA650, .last = 0xA650, .delta = 1 },
    .{ .first = 0xA652, .last = 0xA652, .delta = 1 },
    .{ .first = 0xA654, .last = 0xA654, .delta = 1 },
    .{ .first = 0xA656, .last = 0xA656, .delta = 1 },
    .{ .first = 0xA658, .last = 0xA658, .delta = 1 },
    .{ .first = 0xA65A, .last = 0xA65A, .delta = 1 },
    .{ .first = 0xA65C, .last = 0xA65C, .delta = 1 },
    .{ .first = 0xA65E, .last = 0xA65E, .delta = 1 },
    .{ .first = 0xA660, .last = 0xA660, .delta = 1 },
    .{ .first = 0xA662, .last = 0xA662, .delta = 1 },
    .{ .first = 0xA664, .last = 0xA664, .delta = 1 },
    .{ .first = 0xA666, .last = 0xA666, .delta = 1 },
    .{ .first = 0xA668, .last = 0xA668, .delta = 1 },
    .{ .first = 0xA66A, .last = 0xA66A, .delta = 1 },
    .{ .first = 0xA66C, .last = 0xA66C, .delta = 1 },
    .{ .first = 0xA680, .last = 0xA680, .delta = 1 },
    .{ .first = 0xA682, .last = 0xA682, .delta = 1 },
    .{ .first = 0xA684, .last = 0xA684, .delta = 1 },
    .{ .first = 0xA686, .last = 0xA686, .delta = 1 },
    .{ .first = 0xA688, .last = 0xA688, .delta = 1 },
    .{ .first = 0xA68A, .last = 0xA68A, .delta = 1 },
    .{ .first = 0xA68C, .last = 0xA68C, .delta = 1 },
    .{ .first = 0xA68E, .last = 0xA68E, .delta = 1 },
    .{ .first = 0xA690, .last = 0xA690, .delta = 1 },
    .{ .first = 0xA692, .last = 0xA692, .delta = 1 },
    .{ .first = 0xA694, .last = 0xA694, .delta = 1 },
    .{ .first = 0xA696, .last = 0xA696, .delta = 1 },
    .{ .first = 0xA698, .last = 0xA698, .delta = 1 },
    .{ .first = 0xA69A, .last = 0xA69A, .delta = 1 },
    .{ .first = 0xA722, .last = 0xA722, .delta = 1 },
    .{ .first = 0xA724, .last = 0xA724, .delta = 1 },
    .{ .first = 0xA726, .last = 0xA726, .delta = 1 },
    .{ .first = 0xA728, .last = 0xA728, .delta = 1 },
    .{ .first = 0xA72A, .last = 0xA72A, .delta = 1 },
    .{ .first = 0xA72C, .last = 0xA72C, .delta = 1 },
    .{ .first = 0xA72E, .last = 0xA72E, .delta = 1 },
    .{ .first = 0xA732, .last = 0xA732, .delta = 1 },
    .{ .first = 0xA734, .last = 0xA734, .delta = 1 },
    .{ .first = 0xA736, .last = 0xA736, .delta = 1 },
    .{ .first = 0xA738, .last = 0xA738, .delta = 1 },
    .{ .first = 0xA73A, .last = 0xA73A, .delta = 1 },
    .{ .first = 0xA73C, .last = 0xA73C, .delta = 1 },
    .{ .first = 0xA73E, .last = 0xA73E, .delta = 1 },
    .{ .first = 0xA740, .last = 0xA740, .delta = 1 },
    .{ .first = 0xA742, .last = 0xA742, .delta = 1 },
    .{ .first = 0xA744, .last = 0xA744, .delta = 1 },
    .{ .first = 0xA746, .last = 0xA746, .delta = 1 },
    .{ .first = 0xA748, .last = 0xA748, .delta = 1 },
    .{ .first = 0xA74A, .last = 0xA74A, .delta = 1 },
    .{ .first = 0xA74C, .last = 0xA74C, .delta = 1 },
    .{ .first = 0xA74E, .last = 0xA74E, .delta = 1 },
    .{ .first = 0xA750, .last = 0xA750, .delta = 1 },
    .{ .first = 0xA752, .last = 0xA752, .delta = 1 },
    .{ .first = 0xA754, .last = 0xA754, .delta = 1 },
    .{ .first = 0xA756, .last = 0xA756, .delta = 1 },
    .{ .first = 0xA758, .last = 0xA758, .delta = 1 },
    .{ .first = 0xA75A, .last = 0xA75A, .delta = 1 },
    .{ .first = 0xA75C, .last = 0xA75C, .delta = 1 },
    .{ .first = 0xA75E, .last = 0xA75E, .delta = 1 },
    .{ .first = 0xA760, .last = 0xA760, .delta = 1 },
    .{ .first = 0xA762, .last = 0xA762, .delta = 1 },
    .{ .first = 0xA764, .last = 0xA764, .delta = 1 },
    .{ .first = 0xA766, .last = 0xA766, .delta = 1 },
    .{ .first = 0xA768, .last = 0xA768, .delta = 1 },
    .{ .first = 0xA76A, .last = 0xA76A, .delta = 1 },
    .{ .first = 0xA76C, .last = 0xA76C, .delta = 1 },
    .{ .first = 0xA76E, .last = 0xA76E, .delta = 1 },
    .{ .first = 0xA779, .last = 0xA779, .delta = 1 },
    .{ .first = 0xA77B, .last = 0xA77B, .delta = 1 },
    .{ .first = 0xA77D, .last = 0xA77D, .delta = -35332 },
    .{ .first = 0xA77E, .last = 0xA77E, .delta = 1 },
    .{ .first = 0xA780, .last = 0xA780, .delta = 1 },
    .{ .first = 0xA782, .last = 0xA782, .delta = 1 },
    .{ .first = 0xA784, .last = 0xA784, .delta = 1 },
    .{ .first = 0xA786, .last = 0xA786, .delta = 1 },
    .{ .first = 0xA78B, .last = 0xA78B, .delta = 1 },
    .{ .first = 0xA78D, .last = 0xA78D, .delta = -42280 },
    .{ .first = 0xA790, .last = 0xA790, .delta = 1 },
    .{ .first = 0xA792, .last = 0xA792, .delta = 1 },
    .{ .first = 0xA796, .last = 0xA796, .delta = 1 },
    .{ .first = 0xA798, .last = 0xA798, .delta = 1 },
    .{ .first = 0xA79A, .last = 0xA79A, .delta = 1 },
    .{ .first = 0xA79C, .last = 0xA79C, .delta = 1 },
    .{ .first = 0xA79E, .last = 0xA79E, .delta = 1 },
    .{ .first = 0xA7A0, .last = 0xA7A0, .delta = 1 },
    .{ .first = 0xA7A2, .last = 0xA7A2, .delta = 1 },
    .{ .first = 0xA7A4, .last = 0xA7A4, .delta = 1 },
    .{ .first = 0xA7A6, .last = 0xA7A6, .delta = 1 },
    .{ .first = 0xA7A8, .last = 0xA7A8, .delta = 1 },
    .{ .first = 0xA7AA, .last = 0xA7AA, .delta = -42308 },
    .{ .first = 0xA7AB, .last = 0xA7AB, .delta = -42319 },
    .{ .first = 0xA7AC, .last = 0xA7AC, .delta = -42315 },
    .{ .first = 0xA7AD, .last = 0xA7AD, .delta = -42305 },
    .{ .first = 0xA7AE, .last = 0xA7AE, .delta = -42308 },
    .{ .first = 0xA7B0, .last = 0xA7B0, .delta = -42258 },
    .{ .first = 0xA7B1, .last = 0xA7B1, .delta = -42282 },
    .{ .first = 0xA7B2, .last = 0xA7B2, .delta = -42261 },
    .{ .first = 0xA7B3, .last = 0xA7B3, .delta = 928 },
    .{ .first = 0xA7B4, .last = 0xA7B4, .delta = 1 },
    .{ .first = 0xA7B6, .last = 0xA7B6, .delta = 1 },
    .{ .first = 0xA7B8, .last = 0xA7B8, .delta = 1 },
    .{ .first = 0xA7BA, .last = 0xA7BA, .delta = 1 },
    .{ .first = 0xA7BC, .last = 0xA7BC, .delta = 1 },
    .{ .first = 0xA7BE, .last = 0xA7BE, .delta = 1 },
    .{ .first = 0xA7C0, .last = 0xA7C0, .delta = 1 },
    .{ .first = 0xA7C2, .last = 0xA7C2, .delta = 1 },
    .{ .first = 0xA7C4, .last = 0xA7C4, .delta = -48 },
    .{ .first = 0xA7C5, .last = 0xA7C5, .delta = -42307 },
    .{ .first = 0xA7C6, .last = 0xA7C6, .delta = -35384 },
    .{ .first = 0xA7C7, .last = 0xA7C7, .delta = 1 },
    .{ .first = 0xA7C9, .last = 0xA7C9, .delta = 1 },
    .{ .first = 0xA7CB, .last = 0xA7CB, .delta = -42343 },
    .{ .first = 0xA7CC, .last = 0xA7CC, .delta = 1 },
    .{ .first = 0xA7D0, .last = 0xA7D0, .delta = 1 },
    .{ .first = 0xA7D6, .last = 0xA7D6, .delta = 1 },
    .{ .first = 0xA7D8, .last = 0xA7D8, .delta = 1 },
    .{ .first = 0xA7DA, .last = 0xA7DA, .delta = 1 },
    .{ .first = 0xA7DC, .last = 0xA7DC, .delta = -42561 },
    .{ .first = 0xA7F5, .last = 0xA7F5, .delta = 1 },
    .{ .first = 0xAB70, .last = 0xABBF, .delta = -38864 },
    .{ .first = 0xFB05, .last = 0xFB05, .delta = 1 },
    .{ .first = 0xFF21, .last = 0xFF3A, .delta = 32 },
    .{ .first = 0x10400, .last = 0x10427, .delta = 40 },
    .{ .first = 0x104B0, .last = 0x104D3, .delta = 40 },
    .{ .first = 0x10570, .last = 0x1057A, .delta = 39 },
    .{ .first = 0x1057C, .last = 0x1058A, .delta = 39 },
    .{ .first = 0x1058C, .last = 0x10592, .delta = 39 },
    .{ .first = 0x10594, .last = 0x10595, .delta = 39 },
    .{ .first = 0x10C80, .last = 0x10CB2, .delta = 64 },
    .{ .first = 0x10D50, .last = 0x10D65, .delta = 32 },
    .{ .first = 0x118A0, .last = 0x118BF, .delta = 32 },
    .{ .first = 0x16E40, .last = 0x16E5F, .delta = 32 },
    .{ .first = 0x1E900, .last = 0x1E921, .delta = 34 },
};
fn simpleFold(cp: u21) u21 {
    var lo: usize = 0;
    var hi = fold_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = fold_ranges[mid];
        if (cp < range.first) hi = mid else if (cp > range.last) lo = mid + 1 else return @intCast(@as(i32, cp) + range.delta);
    }
    return cp;
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
