//! Build-time message rows shared by the ordinary Provider and source proofs.
const std = @import("std");
const A = std.mem.Allocator;
pub const Entry = struct { source_raw: ?[]const u8 };
pub const Map = std.StringHashMapUnmanaged(Entry);
pub const Identity = struct { wiki: []const u8, dump_date: []const u8, content_language: []const u8 };
pub fn validLanguageCode(code: []const u8) bool {
    if (code.len == 0) return false;
    for (code) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}
pub fn normalizeKeyAlloc(a: A, raw: []const u8) ![]u8 {
    if (raw.len == 0 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidInterfaceMessageKey;
    if (raw[0] >= 128) return error.UnsupportedInterfaceMessageKey;
    const key = try a.dupe(u8, raw);
    errdefer a.free(key);
    std.mem.replaceScalar(u8, key, ' ', '_');
    key[0] = std.ascii.toLower(key[0]);
    for (key) |c| if (c == '\t' or c == '\r' or c == '\n') return error.InvalidInterfaceMessageKey;
    return key;
}
pub fn lookupKeyAlloc(a: A, language: []const u8, raw: []const u8) ![]u8 {
    if (!validLanguageCode(language)) return error.InvalidInterfaceMessageKey;
    const key = try normalizeKeyAlloc(a, raw);
    defer a.free(key);
    return std.fmt.allocPrint(a, "{s}\t{s}", .{ language, key });
}
pub fn expectHeader(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidSnapshotIdentity;
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.eql(u8, line[prefix.len..], expected)) return error.InvalidSnapshotIdentity;
}
pub fn identityHeaders(lines: *std.mem.SplitIterator(u8, .scalar), identity: Identity) !void {
    try expectHeader(lines, "# wiki\t", identity.wiki);
    try expectHeader(lines, "# dump-date\t", identity.dump_date);
    try expectHeader(lines, "# content-language\t", identity.content_language);
}
pub fn deinit(a: A, entries: *Map) void {
    var keys = entries.keyIterator();
    while (keys.next()) |key| a.free(key.*);
    entries.deinit(a);
}
pub fn parseAlloc(a: A, bytes: []const u8, identity: Identity, require_identity: bool) !Map {
    var entries: Map = .empty;
    errdefer deinit(a, &entries);
    const capacity = std.math.cast(u32, std.mem.count(u8, bytes, "\n") + 1) orelse return error.InterfaceMessageSnapshotTooLarge;
    try entries.ensureTotalCapacity(a, capacity);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (std.mem.eql(u8, lines.peek() orelse "", "# wikidict-interface-messages-v1")) {
        _ = lines.next();
        try identityHeaders(&lines, identity);
    } else if (require_identity) return error.InvalidSnapshotIdentity;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidInterfaceMessageSnapshot;
        const second_tab = std.mem.indexOfScalarPos(u8, line, first_tab + 1, '\t') orelse return error.InvalidInterfaceMessageSnapshot;
        if (first_tab == 0 or second_tab == first_tab + 1) return error.InvalidInterfaceMessageSnapshot;
        const lookup_key = try lookupKeyAlloc(a, line[0..first_tab], line[first_tab + 1 .. second_tab]);
        errdefer a.free(lookup_key);
        const encoded = line[second_tab + 1 ..];
        const entry: Entry = if (std.mem.eql(u8, encoded, "M")) .{ .source_raw = null }
            else if (std.mem.startsWith(u8, encoded, "V\t")) .{ .source_raw = encoded[2..] }
            else return error.InvalidInterfaceMessageSnapshot;
        const result = try entries.getOrPut(a, lookup_key);
        if (result.found_existing) return error.DuplicateInterfaceMessage;
        result.value_ptr.* = entry;
    }
    return entries;
}

pub fn deinitFallbacks(a: A, entries: *std.StringHashMapUnmanaged([]const []const u8)) void {
    var values = entries.valueIterator();
    while (values.next()) |list| a.free(list.*);
    entries.deinit(a);
}
pub fn parseFallbacksAlloc(a: A, bytes: []const u8, identity: Identity) !std.StringHashMapUnmanaged([]const []const u8) {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidLanguageFallbackSnapshot;
        var entries: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        errdefer {
            var values = entries.valueIterator();
            while (values.next()) |list| a.free(list.*);
            entries.deinit(a);
        }
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        try expectHeader(&lines, "", "# wikidict-language-fallbacks-v1");
        try expectHeader(&lines, "# wiki\t", identity.wiki);
        try expectHeader(&lines, "# dump-date\t", identity.dump_date);
        try expectHeader(&lines, "# content-language\t", identity.content_language);
        try expectHeader(&lines, "# mode\t", "strict");
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidLanguageFallbackSnapshot;
            const code = line[0..tab];
            if (!validLanguageCode(code)) return error.InvalidLanguageFallbackSnapshot;
            const raw = line[tab + 1 ..];
            const list = try a.alloc([]const u8, if (raw.len == 0) 0 else std.mem.count(u8, raw, "\t") + 1);
            errdefer a.free(list);
            var fields = std.mem.splitScalar(u8, raw, '\t');
            for (list, 0..) |*fallback, index| {
                fallback.* = fields.next().?;
                if (!validLanguageCode(fallback.*) or std.mem.eql(u8, code, fallback.*)) return error.InvalidLanguageFallbackSnapshot;
                for (list[0..index]) |previous| if (std.mem.eql(u8, previous, fallback.*)) return error.InvalidLanguageFallbackSnapshot;
            }
            const entry = try entries.getOrPut(a, code);
            if (entry.found_existing) return error.DuplicateLanguageFallback;
            entry.value_ptr.* = list;
        }
    return entries;
}

test "shared interface message rows preserve explicit missing empty values normalization and duplicate errors" {
    const a = std.testing.allocator;
    const identity: Identity = .{ .wiki = "kuwiktionary", .dump_date = "20261001", .content_language = "ku" };
    const header = "# wikidict-interface-messages-v1\n# wiki\tkuwiktionary\n# dump-date\t20261001\n# content-language\tku\n";
    var map = try parseAlloc(a, header ++ "ku\tConversiontable/ku\tM\nku\tempty\tV\t\n", identity, true); defer deinit(a, &map);
    try std.testing.expect((map.get("ku\tconversiontable/ku") orelse return error.TestUnexpectedResult).source_raw == null);
    try std.testing.expectEqualStrings("", (map.get("ku\tempty") orelse return error.TestUnexpectedResult).source_raw orelse return error.TestUnexpectedResult);
    try std.testing.expect(map.get("ku\tomitted") == null);
    try std.testing.expectError(error.DuplicateInterfaceMessage, parseAlloc(a, header ++ "ku\tConversiontable/ku\tM\nku\tconversiontable/ku\tV\t\n", identity, true));
    try std.testing.expectError(error.InvalidInterfaceMessageSnapshot, parseAlloc(a, header ++ "ku\tconversiontable/ku\tM\textra\n", identity, true));
    try std.testing.expectError(error.InvalidSnapshotIdentity, parseAlloc(a, "ku\tx\tM\n", identity, true));
    var legacy = try parseAlloc(a, "ku\tx\tM\n", identity, false); defer deinit(a, &legacy);
    try std.testing.expect((legacy.get("ku\tx") orelse return error.TestUnexpectedResult).source_raw == null);
    try std.testing.expectError(error.InvalidInterfaceMessageKey, lookupKeyAlloc(a, "ku!", "x"));
    try std.testing.expectError(error.UnsupportedInterfaceMessageKey, normalizeKeyAlloc(a, "\xc3\xaa"));
    const key = try lookupKeyAlloc(a, "ku", "A mixedCase"); defer a.free(key);
    try std.testing.expectEqualStrings("ku\ta_mixedCase", key);
    const Probe = struct {
        fn run(allocator: A) !void {
            const selected: Identity = .{ .wiki = "kuwiktionary", .dump_date = "20261001", .content_language = "ku" };
            var messages = try parseAlloc(allocator, "# wikidict-interface-messages-v1\n# wiki\tkuwiktionary\n# dump-date\t20261001\n# content-language\tku\nku\tConversiontable/ku\tM\nku\tvalue\tV\ttext\n", selected, true);
            defer deinit(allocator, &messages);
            var fallbacks = try parseFallbacksAlloc(allocator, "# wikidict-language-fallbacks-v1\n# wiki\tkuwiktionary\n# dump-date\t20261001\n# content-language\tku\n# mode\tstrict\nku\tku-latn\ten\nen\t\n", selected);
            defer deinitFallbacks(allocator, &fallbacks);
            try std.testing.expectEqual(@as(usize, 2), messages.count());
            try std.testing.expectEqual(@as(usize, 2), (fallbacks.get("ku") orelse return error.TestUnexpectedResult).len);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Probe.run, .{});
}

// Nonrecursive $N substitution shared with ordinary mw.message plain().
// A provider is called only for a referenced parameter, in original order.
pub fn substituteParams(a: A, source: []const u8, count: usize, provider: anytype) ![]const u8 {
    if (count == 0 or std.mem.indexOfScalar(u8, source, '$') == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var remaining = source;
    var pos: usize = 0;
    while (pos < remaining.len) {
        if (remaining[pos] == '$' and pos + 1 < remaining.len and std.ascii.isDigit(remaining[pos + 1])) {
            var end = pos + 1;
            var index: usize = 0;
            while (end < remaining.len and std.ascii.isDigit(remaining[end])) : (end += 1) {
                index = std.math.add(usize, try std.math.mul(usize, index, 10), @as(usize, remaining[end] - '0')) catch return error.MessageParameterIndexOverflow;
            }
            if (index != 0 and index <= count) {
                try out.appendSlice(a, remaining[0..pos]);
                try out.appendSlice(a, try provider.get(index - 1));
                remaining = remaining[end..];
                pos = 0;
                continue;
            }
        }
        pos += 1;
    }
    if (out.items.len == 0) return source;
    try out.appendSlice(a, remaining);
    return out.toOwnedSlice(a);
}
