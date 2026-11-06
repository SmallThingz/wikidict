//! Edition-scoped magic aliases captured from MediaWiki siteinfo.
const std = @import("std");
const lower = @import("unicode_lower");

pub const header = "# wikidict-magic-words-v1";
pub const parser_header = "# wikidict-magic-words-v2";
pub const max_bytes = 1024 * 1024;
pub const Form = enum { variable, parser_function, category_option, raw_suffix };

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
pub const statistics_ids = [_][]const u8{
    "numberofpages", "numberofarticles",    "numberoffiles",  "numberofedits",
    "numberofusers", "numberofactiveusers", "numberofadmins",
};
pub const category_option_ids = [_][]const u8{ "pagesincategory_all", "pagesincategory_pages", "pagesincategory_subcats", "pagesincategory_files" };
pub const raw_suffix_ids = [_][]const u8{"rawsuffix"};
const variable_ids = statistics_ids ++ title_ids;
// Filtered supported hooks in CoreParserFunctions::registerFunctions order;
// option tokens have their own domains and never enter this callable order.
const function_ids = [_][]const u8{
    "ns",              "urlencode",        "lcfirst",             "ucfirst",       "lc",              "uc",            "localurl",     "fullurl",         "fullurle",      "canonicalurl",
    "formatnum",       "plural",           "language",            "padleft",       "padright",        "anchorencode",  "defaultsort",  "pagesincategory", "pagename",      "pagenamee",
    "fullpagename",    "fullpagenamee",    "subpagename",         "subpagenamee",  "rootpagename",    "rootpagenamee", "basepagename", "basepagenamee",   "talkpagename",  "talkpagenamee",
    "subjectpagename", "subjectpagenamee", "namespace",           "namespacee",    "namespacenumber", "talkspace",     "talkspacee",   "subjectspace",    "subjectspacee", "numberofarticles",
    "numberoffiles",   "numberofusers",    "numberofactiveusers", "numberofpages", "numberofadmins",  "numberofedits", "isbn", "int",          "special",         "tag",           "formatdate",
    "displaytitle",    "expr",             "if",                  "ifeq",          "ifexpr",          "iferror",       "switch",       "ifexist",         "time",          "titleparts",
    "len",             "sub",              "categorytree",        "invoke",        "lst",
};

pub const hash_function_ids = [_][]const u8{
    "special", "tag",     "formatdate", "expr",       "if",  "ifeq", "ifexpr",       "iferror",
    "switch",  "ifexist", "time",       "titleparts", "len", "sub",  "categorytree", "invoke",
    "lst",
};

fn hashFunction(id: []const u8) bool {
    for (hash_function_ids) |candidate| if (std.mem.eql(u8, id, candidate)) return true;
    return false;
}

pub fn knownHashFunctionHead(head: []const u8) bool {
    if (head.len == 0 or head[0] != '#') return false;
    for (hash_function_ids) |id| if (std.ascii.eqlIgnoreCase(head[1..], id)) return true;
    return std.ascii.eqlIgnoreCase(head, "#dateformat") or std.ascii.eqlIgnoreCase(head, "#language");
}

fn functionHead(id: []const u8) []const u8 {
    inline for (hash_function_ids) |candidate|
        if (std.mem.eql(u8, id, candidate)) return "#" ++ candidate;
    return id;
}

fn priority(id: []const u8, form: Form) usize {
    const ids: []const []const u8 = switch (form) {
        .variable => &variable_ids,
        .parser_function => &function_ids,
        .category_option => &category_option_ids,
        .raw_suffix => &raw_suffix_ids,
    };
    for (ids, 0..) |candidate, rank| if (std.mem.eql(u8, id, candidate)) return rank;
    unreachable;
}

const Winners = struct {
    variable: ?[]const u8 = null,
    parser_function: ?[]const u8 = null,
    category_option: ?[]const u8 = null,
    raw_suffix: ?[]const u8 = null,

    fn include(self: *Winners, id: []const u8, form: Form) void {
        const winner = switch (form) {
            .variable => &self.variable,
            .parser_function => &self.parser_function,
            .category_option => &self.category_option,
            .raw_suffix => &self.raw_suffix,
        };
        if (winner.* == null or priority(id, form) > priority(winner.*.?, form)) winner.* = id;
    }

    fn select(self: Winners, form: Form) ?[]const u8 {
        return switch (form) {
            .variable => self.variable,
            .parser_function => functionHead(self.parser_function orelse return null),
            .category_option => self.category_option,
            .raw_suffix => self.raw_suffix,
        };
    }
};

fn titleId(raw: []const u8) ?[]const u8 {
    for (title_ids) |id| if (std.mem.eql(u8, raw, id)) return id;
    return null;
}

pub fn statisticsId(raw: []const u8) ?usize {
    for (statistics_ids, 0..) |id, index| if (std.ascii.eqlIgnoreCase(raw, id)) return index;
    return null;
}

fn canonicalId(raw: []const u8, expanded: bool) ?[]const u8 {
    if (titleId(raw)) |id| return id;
    if (expanded) {
        for (function_ids) |id| if (std.mem.eql(u8, raw, id)) return id;
        for (category_option_ids) |id| if (std.mem.eql(u8, raw, id)) return id;
        for (raw_suffix_ids) |id| if (std.mem.eql(u8, raw, id)) return id;
    }
    return null;
}

fn addAlias(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Winners), key: []const u8, id: []const u8, form: Form) !void {
    const entry = try map.getOrPut(a, key);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    entry.value_ptr.include(id, form);
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
    expanded_functions: bool = false,
    raw_suffix_available: bool = false,

    pub fn init(a: std.mem.Allocator, raw: []const u8, wiki: []const u8, date: []const u8, language: []const u8) !Registry {
        if (raw.len > max_bytes or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidMagicWordsSnapshot;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = try arena.allocator().dupe(u8, raw);
        var lines = std.mem.splitScalar(u8, owned, '\n');
        const first = lines.next() orelse return error.InvalidMagicWordsSnapshot;
        const expanded = std.mem.eql(u8, first, parser_header);
        if (!expanded and !std.mem.eql(u8, first, header)) return error.InvalidMagicWordsSnapshot;
        try identityLine(&lines, "# wiki\t", wiki);
        try identityLine(&lines, "# dump-date\t", date);
        try identityLine(&lines, "# content-language\t", language);
        var sensitive: std.StringHashMapUnmanaged(Winners) = .empty;
        var insensitive: std.StringHashMapUnmanaged(Winners) = .empty;
        var raw_suffix_available = false;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const id = canonicalId(fields.next() orelse return error.InvalidMagicWordsSnapshot, expanded) orelse
                return error.InvalidMagicWordsSnapshot;
            const flag = fields.next() orelse return error.InvalidMagicWordsSnapshot;
            const case_sensitive = if (std.mem.eql(u8, flag, "1")) true else if (std.mem.eql(u8, flag, "0")) false else return error.InvalidMagicWordsSnapshot;
            const alias = fields.next() orelse return error.InvalidMagicWordsSnapshot;
            if (fields.next() != null or alias.len == 0 or alias.len > 1024) return error.InvalidMagicWordsSnapshot;
            for (alias) |byte| if (byte < 32 or byte == 127) return error.InvalidMagicWordsSnapshot;
            const map = if (case_sensitive) &sensitive else &insensitive;
            const a_owned = arena.allocator();
            const key = if (case_sensitive) alias else try lower.lowerAlloc(a_owned, alias);
            if (titleId(id) != null or statisticsId(id) != null) try addAlias(a_owned, map, key, id, .variable);
            var category_option = false;
            for (category_option_ids) |candidate| if (std.mem.eql(u8, id, candidate)) {
                category_option = true;
                break;
            };
            if (category_option) {
                try addAlias(a_owned, map, key, id, .category_option);
                continue;
            }
            if (std.mem.eql(u8, id, "rawsuffix")) {
                raw_suffix_available = true;
                try addAlias(a_owned, map, key, id, .raw_suffix);
                continue;
            }
            // Parser::setFunctionHook adds a hash before removing one trailing
            // colon. The source spelling is not title-normalized or deduplicated.
            var function_alias = key;
            if (expanded and std.mem.endsWith(u8, function_alias, ":"))
                function_alias = function_alias[0 .. function_alias.len - 1]
            else if (expanded and std.mem.endsWith(u8, function_alias, "："))
                function_alias = function_alias[0 .. function_alias.len - "：".len];
            if (hashFunction(id)) function_alias = try std.fmt.allocPrint(a_owned, "#{s}", .{function_alias});
            try addAlias(a_owned, map, function_alias, id, .parser_function);
        }
        if (sensitive.count() + insensitive.count() == 0) return error.InvalidMagicWordsSnapshot;
        return .{ .arena = arena, .sensitive = sensitive, .insensitive = insensitive, .expanded_functions = expanded, .raw_suffix_available = raw_suffix_available };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn resolve(self: *const Registry, raw: []const u8, form: Form) ?[]const u8 {
        if (raw.len > 1024) return null;
        if (self.sensitive.get(raw)) |winners| if (winners.select(form)) |id| return id;
        if (self.insensitive.count() == 0) return null;
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        lower.writeLower(&writer, raw) catch return null;
        return if (self.insensitive.get(writer.buffered())) |winners| winners.select(form) else null;
    }
};

const fixture = header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n";

test "expanded parser aliases retain hash colon case and invocation domains" {
    const raw = parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "pagename\t1\tPAGENAME\ninvoke\t0\tاستدعاء\ninvoke\t0\tinvoke\nif\t0\tلو\n" ++
        "ns\t0\tنط:\nns\t0\t空間：\nlen\t0\t#ziman\ndisplaytitle\t1\tDISPLAYTITLE\ndefaultsort\t1\tDEFAULTSORT:\n";
    var registry = try Registry.init(std.testing.allocator, raw, "arwiktionary", "20261001", "ar");
    defer registry.deinit();
    try std.testing.expect(registry.expanded_functions);
    try std.testing.expectEqualStrings("#invoke", registry.resolve("#استدعاء", .parser_function).?);
    try std.testing.expectEqualStrings("#invoke", registry.resolve("#INVOKE", .parser_function).?);
    try std.testing.expectEqualStrings("#if", registry.resolve("#لو", .parser_function).?);
    try std.testing.expectEqualStrings("ns", registry.resolve("نط", .parser_function).?);
    try std.testing.expectEqualStrings("ns", registry.resolve("空間", .parser_function).?);
    try std.testing.expectEqualStrings("#len", registry.resolve("##ziman", .parser_function).?);
    try std.testing.expectEqualStrings("defaultsort", registry.resolve("DEFAULTSORT", .parser_function).?);
    try std.testing.expect(registry.resolve("#ziman", .parser_function) == null);
    try std.testing.expect(registry.resolve("displaytitle", .parser_function) == null);
    try std.testing.expect(registry.resolve("استدعاء", .parser_function) == null);
    try std.testing.expect(registry.resolve("#استدعاء", .variable) == null);
    try std.testing.expect(registry.resolve("نط", .variable) == null);
    try std.testing.expectError(error.InvalidMagicWordsSnapshot, Registry.init(std.testing.allocator, fixture ++ "invoke\t0\tinvoke\n", "arwiktionary", "20261001", "ar"));
}

test "expanded functions share sensitive precedence with title functions" {
    inline for ([_][]const u8{
        "namespace\t1\t名前空間\nns\t0\t名前空間:\n",
        "ns\t0\t名前空間:\nnamespace\t1\t名前空間\n",
    }) |rows| {
        var registry = try Registry.init(std.testing.allocator, parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++ rows, "arwiktionary", "20261001", "ar");
        defer registry.deinit();
        try std.testing.expectEqualStrings("namespace", registry.resolve("名前空間", .parser_function).?);
        try std.testing.expectEqualStrings("namespace", registry.resolve("名前空間", .variable).?);
    }
}

test "title aliases preserve edition identity spelling case flags and Unicode" {
    var registry = try Registry.init(std.testing.allocator, fixture ++ "pagename\t1\tاسم_الصفحة\npagename\t1\tPAGENAME\nfullpagename\t0\tTÍTULO\nfullpagename\t0\ttítulo\n", "arwiktionary", "20261001", "ar");
    defer registry.deinit();
    try std.testing.expectEqualStrings("pagename", registry.resolve("اسم_الصفحة", .variable).?);
    try std.testing.expectEqualStrings("pagename", registry.resolve("PAGENAME", .variable).?);
    try std.testing.expectEqualStrings("fullpagename", registry.resolve("título", .parser_function).?);
    try std.testing.expect(registry.resolve("اسم الصفحة", .variable) == null);
    try std.testing.expect(!registry.raw_suffix_available);
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

// Core language is registered without SFH_HASH; the captured alias includes '#'.
test "language parser aliases retain their captured hash and registration order" {
    const raw = parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "language\t0\t#لغة\nlanguage\t0\t#LANGUAGE\nlanguage\t0\tCOLLISION\nplural\t0\tCOLLISION\n";
    var registry = try Registry.init(std.testing.allocator, raw, "arwiktionary", "20261001", "ar");
    defer registry.deinit();
    try std.testing.expectEqualStrings("language", registry.resolve("#language", .parser_function).?);
    try std.testing.expectEqualStrings("language", registry.resolve("#لغة", .parser_function).?);
    try std.testing.expectEqualStrings("language", registry.resolve("COLLISION", .parser_function).?);
    try std.testing.expect(registry.resolve("##language", .parser_function) == null);
    try std.testing.expect(registry.resolve("language", .parser_function) == null);
    try std.testing.expect(knownHashFunctionHead("#LANGUAGE"));
    try std.testing.expect(!knownHashFunctionHead("##language"));
}

test "captured statistics require expanded snapshot and preserve alias sensitivity" {
    const a = std.testing.allocator;
    const identity = "\n# wiki\tabwiktionary\n# dump-date\t20261001\n# content-language\tab\n";
    const row = "numberofarticles\t1\tКОЛИЧЕСТВО_СТАТЕЙ\n";
    var words = try Registry.init(a, parser_header ++ identity ++ row, "abwiktionary", "20261001", "ab");
    defer words.deinit();
    try std.testing.expectEqualStrings("numberofarticles", (words.resolve("КОЛИЧЕСТВО_СТАТЕЙ", .variable)).?);
    try std.testing.expectEqualStrings("numberofarticles", (words.resolve("КОЛИЧЕСТВО_СТАТЕЙ", .parser_function)).?);
    try std.testing.expect((words.resolve("количество_статей", .variable)) == null);
    try std.testing.expectError(error.InvalidMagicWordsSnapshot, Registry.init(a, header ++ identity ++ row, "abwiktionary", "20261001", "ab"));
}

test "category count options preserve captured case and stay outside callable domains" {
    const a = std.testing.allocator;
    var words = try Registry.init(a, parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "pagesincategory\t1\tPAGESINCATEGORY\npagesincategory\t1\tصفحات_في_التصنيف\n" ++
        "pagesincategory_all\t0\tكل\npagesincategory_all\t0\tall\npagesincategory_pages\t0\tصفحات\n" ++
        "pagesincategory_subcats\t0\tتصنيفات_فرعية\npagesincategory_files\t0\tfiles\nrawsuffix\t1\tآر\nrawsuffix\t1\tR\n", "arwiktionary", "20261001", "ar");
    defer words.deinit();
    try std.testing.expectEqualStrings("pagesincategory", words.resolve("PAGESINCATEGORY", .parser_function).?);
    try std.testing.expectEqualStrings("pagesincategory", words.resolve("صفحات_في_التصنيف", .parser_function).?);
    try std.testing.expect(words.resolve("pagesincategory", .parser_function) == null);
    try std.testing.expect(words.resolve("PAGESINCATEGORY", .variable) == null);
    try std.testing.expectEqualStrings("pagesincategory_all", words.resolve("ALL", .category_option).?);
    try std.testing.expectEqualStrings("pagesincategory_pages", words.resolve("صفحات", .category_option).?);
    try std.testing.expectEqualStrings("pagesincategory_subcats", words.resolve("تصنيفات_فرعية", .category_option).?);
    try std.testing.expectEqualStrings("rawsuffix", words.resolve("آر", .raw_suffix).?);
    try std.testing.expectEqualStrings("rawsuffix", words.resolve("R", .raw_suffix).?);
    try std.testing.expect(words.raw_suffix_available);
    try std.testing.expect(words.resolve("r", .raw_suffix) == null);
    try std.testing.expect(words.resolve("all", .parser_function) == null);
    try std.testing.expect(words.resolve("R", .variable) == null);
    inline for (.{
        "pagesincategory\t1\tX\npagename\t1\tX\nns\t1\tY\nnumberofpages\t1\tY\nnumberofarticles\t1\tZ\nnumberofedits\t1\tZ\n",
        "numberofedits\t1\tZ\nnumberofarticles\t1\tZ\nnumberofpages\t1\tY\nns\t1\tY\npagename\t1\tX\npagesincategory\t1\tX\n",
    }) |rows| {
        var overlap = try Registry.init(a, parser_header ++ "\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++ rows ++ "pagesincategory_pages\t1\tR\nrawsuffix\t1\tR\n", "arwiktionary", "20261001", "ar");
        defer overlap.deinit();
        try std.testing.expectEqualStrings("pagename", overlap.resolve("X", .parser_function).?);
        try std.testing.expectEqualStrings("numberofpages", overlap.resolve("Y", .parser_function).?);
        try std.testing.expectEqualStrings("numberofedits", overlap.resolve("Z", .parser_function).?);
        try std.testing.expectEqualStrings("pagesincategory_pages", overlap.resolve("R", .category_option).?);
        try std.testing.expectEqualStrings("rawsuffix", overlap.resolve("R", .raw_suffix).?);
    }
}
