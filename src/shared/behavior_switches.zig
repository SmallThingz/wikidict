//! Edition-scoped build-time behavior controls. Complete source aliases include delimiters.
const std = @import("std");
const lower = @import("unicode_lower");
pub const header = "# wikidict-behavior-switches-v1";
pub const ids = [_][]const u8{ "notoc", "forcetoc", "toc", "noeditsection", "nogallery", "hiddencat", "index", "noindex", "newsectionlink", "nonewsectionlink", "nocontentconvert", "notitleconvert", "staticredirect", "expectunusedcategory", "expectunusedtemplate", "expectshortpage", "noglobal", "nomediaviewercarousel", "disambiguation", "expectedUnconnectedPage", "archivedtalk", "notalk", "keeptitle", "expectwithoutscans" };
const Alias = struct { text: []const u8, folded: []const u8, sensitive: bool, scalars: usize };
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
            for (ids) |value| if (std.mem.eql(u8, value, id)) { known = true; break; };
            if (!known) return error.InvalidBehaviorSnapshot;
            const flag = fields.next() orelse return error.InvalidBehaviorSnapshot;
            const sensitive = if (std.mem.eql(u8, flag, "1")) true else if (std.mem.eql(u8, flag, "0")) false else return error.InvalidBehaviorSnapshot;
            const alias = fields.next() orelse return error.InvalidBehaviorSnapshot;
            if (fields.next() != null or alias.len == 0 or alias.len > 1024) return error.InvalidBehaviorSnapshot;
            for (alias) |byte| if (byte < 32 or byte == 127) return error.InvalidBehaviorSnapshot;
            initials[alias[0]] = true;
            if (!sensitive) {
                if (alias[0] < 128) {
                    initials[std.ascii.toLower(alias[0])] = true;
                    initials[std.ascii.toUpper(alias[0])] = true;
                } else if (!std.mem.startsWith(u8, alias, "＿＿")) {
                    // Generic Unicode aliases may change UTF-8 lead byte on lowercase.
                    for (128..256) |byte| initials[byte] = true;
                }
            }
            var it = (try std.unicode.Utf8View.init(alias)).iterator();
            var count: usize = 0;
            while (it.nextCodepoint() != null) count += 1;
            if (entries.items.len >= 10000) return error.InvalidBehaviorSnapshot;
            try entries.append(alloc, .{ .text = alias, .folded = try lower.lowerAlloc(alloc, alias), .sensitive = sensitive, .scalars = count });
        }
        return .{ .arena = arena, .aliases = try entries.toOwnedSlice(alloc), .initial_bytes = initials };
    }
    pub fn deinit(self: *Registry) void { self.arena.deinit(); self.* = undefined; }
    pub fn matchAt(self: *const Registry, a: std.mem.Allocator, input: []const u8, at: usize) std.mem.Allocator.Error!?usize {
        _ = a;
        if (at >= input.len or !self.initial_bytes[input[at]]) return null;
        var longest: usize = at;
        for (self.aliases) |alias| {
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
                var scratch: [4096]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&scratch);
                lower.writeLower(&writer, input[at..pos]) catch continue;
                if (std.mem.eql(u8, writer.buffered(), alias.folded)) longest = @max(longest, pos);
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
