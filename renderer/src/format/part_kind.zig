const std = @import("std");
/// Semantic optional sections. Never includes definitions, examples, or usage notes.
pub const Kind = enum(u8) { etymology = 1, translations = 2, relations = 3, references = 4, quotations = 5 };
pub const count = std.meta.tags(Kind).len;
/// Semantic external-body marker. Family is derived from its retained section heading.
pub const reference = [_]u8{ 0, 2 };
pub fn index(kind: Kind) usize {
    return @intFromEnum(kind) - 1;
}
pub fn fromByte(byte: u8) error{InvalidEncoding}!Kind {
    if (byte < 1 or byte > count) return error.InvalidEncoding;
    return @enumFromInt(byte);
}
pub fn classify(title: []const u8) ?Kind {
    const heading = std.mem.trim(u8, title, " \t");
    if (named(heading, "Etymology")) return .etymology;
    if (named(heading, "Translations")) return .translations;
    if (named(heading, "References") or named(heading, "Further reading")) return .references;
    if (named(heading, "Quotations")) return .quotations;
    for ([_][]const u8{ "Derived terms", "Related terms", "Descendants", "Synonyms", "Antonyms", "Hyponyms", "Hypernyms", "Holonyms", "Meronyms", "Coordinate terms", "Troponyms", "Anagrams", "See also" }) |name| if (named(heading, name)) return .relations;
    return null;
}
pub fn named(heading: []const u8, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(heading, name)) return true;
    if (heading.len <= name.len + 1 or !std.ascii.eqlIgnoreCase(heading[0..name.len], name) or heading[name.len] != ' ') return false;
    for (heading[name.len + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}
test "optional sections never swallow descendant definitions" {
    try std.testing.expectEqual(Kind.etymology, classify("Etymology 2").?);
    try std.testing.expect(classify("Noun") == null);
    try std.testing.expect(classify("Usage notes") == null);
    try std.testing.expect(classify("Etymology note") == null);
}
