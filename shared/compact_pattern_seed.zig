const std = @import("std");

pub const static_direct_patterns = [_][]const u8{
    "{{",
    "}}",
    "[[",
    "]]",
    "==",
    "===",
    "====",
    "\n# ",
    "\n## ",
    "\n#: ",
    "\n#* ",
    "|en|",
    "\n* ",
};

pub const static_escaped_patterns = [_][]const u8{
    "|head=",
    "|title=",
    "|author=",
    "|page=",
    "|passage=",
    "|year=",
    "|lang=",
    "|url=",
    "|publisher=",
    "|date=",
    "|text=",
    "|accessdate=",
    "|chapter=",
    "|journal=",
    "|volume=",
    "|isbn=",
    "|work=",
    "|sort=",
    "|type=",
    "|nocat=",
    "|gloss=",
    "|archiveurl=",
    "|entry=",
    "|pageurl=",
    "|location=",
    "|editor=",
    "|issue=",
    "|translation=",
    "|archivedate=",
    "|first=",
    "|last=",
    "|series=",
    "|month=",
    "|edition=",
    "|newsgroup=",
    "|magazine=",
    "|newspaper=",
    "|quote=",
    "|doi=",
    "|oclc=",
    "|issn=",
    "|authorlink=",
    "|section=",
    "{{multitrans|data=\n",
    "{{trans-bottom}}",
    "{{checktrans-top}}",
    "{{trans-top|",
    "{{trans-see|",
    "{{wikidata lexeme|",
    "{{wikipedia|",
    "{{quote-book|en|",
    "{{quote-text|en|",
    "{{quote-web|en|",
    "{{anagrams|en|",
    "{{senseid|en|",
    "{{homophones|en|",
    "{{hyph|en|",
    "{{rhymes|en|",
    "{{audio|en|",
    "{{IPA|en|",
    "{{alt|en|",
    "{{syn|en|",
    "{{ant|en|",
    "{{ux|en|",
    "{{uxi|en|",
    "{{lbl|en|",
    "{{lb|en|",
    "{{l|en|",
    "{{en-proper noun",
    "{{en-adj",
    "{{en-verb",
    "{{en-noun",
    "{{head|en|",
    "{{rfquote|en}}",
    "{{rfdef|en}}",
    "{{qualifier|",
    "{{anagrams|",
    "{{doublet|",
    "{{suffix|",
    "{{prefix|",
    "{{noncog|",
    "{{inh|",
    "{{der|",
    "{{bor|",
    "{{link|",
    "{{m+|",
    "{{m|",
    "{{tt+|",
    "{{tt|",
    "{{t+check|",
    "{{t-check|",
    "{{t+|",
    "{{t|",
    "{{cln|en|",
    "{{C|en|",
    "{{R:",
    "{{pedia|",
    "{{q|",
    "{{col5|en\n|",
    "{{col4|en\n|",
    "{{col3|en\n|",
    "{{col2|en\n|",
    "{{col|en\n|",
    "{{col|",
    "{{w|",
    "{{RQ:",
    "}}<!-- close {{multitrans}} -->\n{{trans-bottom}}",
    "|pos=",
    "|pages=",
    "|inline=",
    "|from=",
    "|yomi=",
    "|altform=",
    "|hanja=",
    "|hangeul=",
    "|stem=",
    "|grade=",
    "|trans-title=",
    "|column=",
    "|ref=",
    "|issue=",
    "|cat=",
    "|nocap=",
    "{{plural of|",
    "{{infl of|",
    "{{quote-journal|",
    "{{place|",
    "{{surname|",
    "{{wp|",
    "{{taxlink|",
    "{{alternative form of|",
    "{{taxfmt|",
    "{{alter|",
    "{{synonym of|",
    "{{alternative spelling of|",
    "{{initialism of|",
    "{{given name|",
    "{{hyphenation|",
    "{{enPR|",
    "{{quote-newsgroup|",
    "{{compound|",
    "{{en-adv",
    "{{af|",
    "{{vern|",
    "{{cog|",
    "{{uder|",
    "{{defdate|",
    "|tr=",
    "|alt=",
    "|g=",
    "|m}}",
    "|f}}",
    "|n}}",
    "|impf}}",
    "|pf}}",
    "|sc=Cyrl}}",
    "|sc=Hebr}}",
    "\n** ",
    "\n*: ",
    "\n'''",
    "'''",
};

pub const static_extended_escaped_patterns = [_][]const u8{
    "|nolinkhead=",
};

pub const max_direct_pattern_count: usize = 0xFD - 0xE0 + 1;

pub fn seedCoveredTemplateNames(
    allocator: std.mem.Allocator,
    covered: *std.StringHashMapUnmanaged(void),
) !void {
    for (static_escaped_patterns) |pattern| {
        const name = templateNameFromPattern(pattern) orelse continue;
        const gop = try covered.getOrPut(allocator, name);
        if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, name);
    }
}

pub fn seedCoveredPatterns(
    allocator: std.mem.Allocator,
    covered: *std.StringHashMapUnmanaged(void),
) !void {
    for (static_direct_patterns) |pattern| try seedCoveredPattern(allocator, covered, pattern);
    for (static_escaped_patterns) |pattern| try seedCoveredPattern(allocator, covered, pattern);
    for (static_extended_escaped_patterns) |pattern| try seedCoveredPattern(allocator, covered, pattern);
}

fn seedCoveredPattern(
    allocator: std.mem.Allocator,
    covered: *std.StringHashMapUnmanaged(void),
    pattern: []const u8,
) !void {
    const gop = try covered.getOrPut(allocator, pattern);
    if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, pattern);
}

fn templateNameFromPattern(pattern: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, pattern, "{{")) return null;
    const body = pattern[2..];
    var end: usize = 0;
    while (end < body.len and body[end] != '|' and body[end] != '}' and body[end] != '\n') : (end += 1) {}
    if (end == 0) return null;
    return body[0..end];
}

test "seedCoveredTemplateNames extracts template identifiers" {
    var covered: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = covered.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        covered.deinit(std.testing.allocator);
    }

    try seedCoveredTemplateNames(std.testing.allocator, &covered);

    try std.testing.expect(covered.contains("plural of"));
    try std.testing.expect(covered.contains("quote-book"));
    try std.testing.expect(!covered.contains("|head="));
}

test "seedCoveredPatterns includes static direct patterns" {
    var covered: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = covered.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        covered.deinit(std.testing.allocator);
    }

    try seedCoveredPatterns(std.testing.allocator, &covered);
    try std.testing.expect(covered.contains("{{"));
    try std.testing.expect(covered.contains("==="));
}
