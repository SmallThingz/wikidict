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
    // Do not add template-specific opener patterns here. Template names must not be
    // serialized into the dictionary mapping blob; they are encoded generically by
    // template code and reconstructed from the structure report when needed.
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
