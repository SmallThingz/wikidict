//! Edition-scoped title magic aliases captured from MediaWiki siteinfo.
const std = @import("std");
const lower = @import("unicode_lower");

pub const header = "# wikidict-magic-words-v1";
pub const max_bytes = 1024 * 1024;
pub const Form = enum { variable, parser_function };

// MediaWiki 1.47.0-wmf.22 registers bare variables and parser functions in
// different orders. Within each case map, later registrations replace earlier
// aliases (MagicWordArray::getHash and Parser::setFunctionHook). These orders
// are independent of siteinfo/TSV ordering and retain valid overlapping aliases.
// https://github.com/wikimedia/mediawiki/blob/wmf/1.47.0-wmf.22/includes/Parser/MagicWordFactory.php
// https://github.com/wikimedia/mediawiki/blob/wmf/1.47.0-wmf.22/includes/Parser/CoreParserFunctions.php
pub const title_ids = [_][]const u8{
    "basepagename",     "basepagenamee", "fullpagename",    "fullpagenamee",
    "namespace",        "namespacee",    "namespacenumber", "pagename",
    "pagenamee",        "rootpagename",  "rootpagenamee",   "subjectpagename",
    "subjectpagenamee", "subjectspace",  "subjectspacee",   "subpagename",
    "subpagenamee",     "talkspace",     "talkspacee",      "talkpagename",
    "talkpagenamee",
};
const function_ids = [_][]const u8{
    "pagename",        "pagenamee",        "fullpagename", "fullpagenamee",
    "subpagename",     "subpagenamee",     "rootpagename", "rootpagenamee",
    "basepagename",    "basepagenamee",    "talkpagename", "talkpagenamee",
    "subjectpagename", "subjectpagenamee", "namespace",    "namespacee",
    "namespacenumber", "talkspace",        "talkspacee",   "subjectspace",
    "subjectspacee",
};

fn priority(id: []const u8, form: Form) usize {
    const ids = if (form == .variable) &title_ids else &function_ids;
    for (ids, 0..) |candidate, rank| if (std.mem.eql(u8, id, candidate)) return rank;
    unreachable;
}

const Winners = struct {
    variable: []const u8,
    parser_function: []const u8,

    fn include(self: *Winners, id: []const u8) void {
        if (priority(id, .variable) > priority(self.variable, .variable)) self.variable = id;
        if (priority(id, .parser_function) > priority(self.parser_function, .parser_function)) self.parser_function = id;
    }

    fn select(self: Winners, form: Form) []const u8 {
        return if (form == .variable) self.variable else self.parser_function;
    }
};

fn canonicalId(raw: []const u8) ?[]const u8 {
    for (title_ids) |id| if (std.mem.eql(u8, raw, id)) return id;
    return null;
}

fn identityLine(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidMagicWordsSnapshot;
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.eql(u8, line[prefix.len..], expected))
        return error.MagicWordsIdentityMismatch;
}

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    sensitive: std.StringHashMapUnmanaged(Winners) = .empty,
    insensitive: std.StringHashMapUnmanaged(Winners) = .empty,

    pub fn init(a: std.mem.Allocator, raw: []const u8, wiki: []const u8, date: []const u8, language: []const u8) !Registry {
        if (raw.len > max_bytes or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidMagicWordsSnapshot;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = try arena.allocator().dupe(u8, raw);
        var lines = std.mem.splitScalar(u8, owned, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidMagicWordsSnapshot, header))
            return error.InvalidMagicWordsSnapshot;
        try identityLine(&lines, "# wiki\t", wiki);
        try identityLine(&lines, "# dump-date\t", date);
        try identityLine(&lines, "# content-language\t", language);
        var sensitive: std.StringHashMapUnmanaged(Winners) = .empty;
        var insensitive: std.StringHashMapUnmanaged(Winners) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = canonicalId(fields.next() orelse return error.InvalidMagicWordsSnapshot) orelse
                return error.InvalidMagicWordsSnapshot;
            const flag = fields.next() orelse return error.InvalidMagicWordsSnapshot;
            const case_sensitive = if (std.mem.eql(u8, flag, "1")) true else if (std.mem.eql(u8, flag, "0")) false else return error.InvalidMagicWordsSnapshot;
            const alias = fields.next() orelse return error.InvalidMagicWordsSnapshot;
            if (fields.next() != null or alias.len == 0 or alias.len > 1024) return error.InvalidMagicWordsSnapshot;
            for (alias) |byte| if (byte < 32 or byte == 127) return error.InvalidMagicWordsSnapshot;
            const map = if (case_sensitive) &sensitive else &insensitive;
            const key = if (case_sensitive) alias else try lower.lowerAlloc(arena.allocator(), alias);
            const entry = try map.getOrPut(arena.allocator(), key);
            if (entry.found_existing) {
                entry.value_ptr.include(id);
            } else {
                entry.value_ptr.* = .{ .variable = id, .parser_function = id };
            }
        }
        if (sensitive.count() + insensitive.count() == 0) return error.InvalidMagicWordsSnapshot;
        return .{ .arena = arena, .sensitive = sensitive, .insensitive = insensitive };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn resolve(self: *const Registry, raw: []const u8, form: Form) ?[]const u8 {
        if (raw.len > 1024) return null;
        if (self.sensitive.get(raw)) |winners| return winners.select(form);
        if (self.insensitive.count() == 0) return null;
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        lower.writeLower(&writer, raw) catch return null;
        return if (self.insensitive.get(writer.buffered())) |winners| winners.select(form) else null;
    }
};

const fixture = header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n";

test "title aliases preserve edition identity spelling case flags and Unicode" {
    var registry = try Registry.init(std.testing.allocator, fixture ++ "pagename\t1\tاسم_الصفحة\npagename\t1\tPAGENAME\nfullpagename\t0\tTÍTULO\nfullpagename\t0\ttítulo\n", "arwiktionary", "20261001", "ar");
    defer registry.deinit();
    try std.testing.expectEqualStrings("pagename", registry.resolve("اسم_الصفحة", .variable).?);
    try std.testing.expectEqualStrings("pagename", registry.resolve("PAGENAME", .variable).?);
    try std.testing.expectEqualStrings("fullpagename", registry.resolve("título", .parser_function).?);
    try std.testing.expect(registry.resolve("اسم الصفحة", .variable) == null);
    try std.testing.expect(registry.resolve("pagename", .variable) == null);
    try std.testing.expectError(error.MagicWordsIdentityMismatch, Registry.init(std.testing.allocator, fixture ++ "pagename\t1\tPAGENAME\n", "enwiktionary", "20261001", "en"));
    try std.testing.expectError(error.MagicWordsIdentityMismatch, Registry.init(std.testing.allocator, fixture ++ "pagename\t1\tPAGENAME\n", "arwiktionary", "20260901", "ar"));
}

test "title alias snapshots reject malformed rows" {
    inline for ([_][]const u8{ "", "unknown\t1\tX\n", "pagename\t2\tX\n", "pagename\t1\t\n", "pagename\t1\tX\textra\n", "pagename\t1\tX\r\n" }) |rows|
        try std.testing.expectError(error.InvalidMagicWordsSnapshot, Registry.init(std.testing.allocator, fixture ++ rows, "arwiktionary", "20261001", "ar"));
}

test "Welsh and Armenian overlaps follow core precedence in either row order" {
    const Case = struct { wiki: []const u8, language: []const u8, first: []const u8, second: []const u8, alias: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .wiki = "cywiktionary", .language = "cy", .first = "namespace\t1\tPARTH\nnamespace\t1\tNAMESPACE\n", .second = "namespacee\t1\tNAMESPACE\nnamespacee\t1\tPARTHE\nnamespacee\t1\tNAMESPACEE\n", .alias = "NAMESPACE", .expected = "namespacee" },
        .{ .wiki = "hywiktionary", .language = "hy", .first = "fullpagename\t1\tARTICLESPACE\nfullpagename\t1\tԷՋԻ_ԼՐԻՎ_ԱՆՎԱՆՈՒՄԸ\nfullpagename\t1\tFULLPAGENAME\n", .second = "subjectspace\t1\tՀՈԴՎԱԾՆԵՐԻ_ՏԱՐԱԾՔԸ\nsubjectspace\t1\tSUBJECTSPACE\nsubjectspace\t1\tARTICLESPACE\n", .alias = "ARTICLESPACE", .expected = "subjectspace" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |reverse| {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "{s}\n# wiki\t{s}\n# dump-date\t20261001\n# content-language\t{s}\n{s}{s}", .{ header, case.wiki, case.language, if (reverse) case.second else case.first, if (reverse) case.first else case.second });
        defer std.testing.allocator.free(raw);
        var registry = try Registry.init(std.testing.allocator, raw, case.wiki, "20261001", case.language);
        defer registry.deinit();
        try std.testing.expectEqualStrings(case.expected, registry.resolve(case.alias, .variable).?);
        try std.testing.expectEqualStrings(case.expected, registry.resolve(case.alias, .parser_function).?);
    };
}

test "overlapping title aliases use distinct bare and function registration orders" {
    inline for ([_][]const u8{
        "pagename\t1\tCOLLISION\nbasepagename\t1\tCOLLISION\n",
        "basepagename\t1\tCOLLISION\npagename\t1\tCOLLISION\n",
    }) |rows| {
        var registry = try Registry.init(std.testing.allocator, fixture ++ rows, "arwiktionary", "20261001", "ar");
        defer registry.deinit();
        try std.testing.expectEqualStrings("pagename", registry.resolve("COLLISION", .variable).?);
        try std.testing.expectEqualStrings("basepagename", registry.resolve("COLLISION", .parser_function).?);
    }
}

test "exact case aliases precede folded collisions in both contexts" {
    inline for ([_][]const u8{
        "pagename\t0\tCOLLISION\nbasepagename\t0\tcollision\nnamespace\t1\tCoLlIsIoN\n",
        "namespace\t1\tCoLlIsIoN\nbasepagename\t0\tcollision\npagename\t0\tCOLLISION\n",
    }) |rows| {
        var registry = try Registry.init(std.testing.allocator, fixture ++ rows, "arwiktionary", "20261001", "ar");
        defer registry.deinit();
        try std.testing.expectEqualStrings("namespace", registry.resolve("CoLlIsIoN", .variable).?);
        try std.testing.expectEqualStrings("namespace", registry.resolve("CoLlIsIoN", .parser_function).?);
        try std.testing.expectEqualStrings("pagename", registry.resolve("COLLISION", .variable).?);
        try std.testing.expectEqualStrings("basepagename", registry.resolve("collision", .parser_function).?);
    }
}
