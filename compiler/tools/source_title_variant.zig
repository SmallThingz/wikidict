//! Build-time title candidates from the exact matched MediaWiki converters.
//! This module supplies no page-existence, request, namespace or source authority.
const std = @import("std");
const A = std.mem.Allocator;
pub const converter_sha256 = "1f610f299bfc5b2976c440312a30958325006c36fb7b67e33810324f4c50e47e";
pub const base_sha256 = "36698382e4e527570f24ff0d838278298475359d7251ffa56910e65c8fe6f446";
pub fn matchedCore(core: []const u8) bool {
    return std.mem.eql(u8, core, "0470f6c99a6456a366635bf25a517a1f951de6f5") or
        std.mem.eql(u8, core, "79b81ba96674efc8a803fc956bc501d347d440d2");
}
// KuConverter::translate(ku-arab), in ordered getLanguageVariants position 1.
// The base variant must separately be proved empty before using this candidate.
// We return no later candidate: a missing Arabic title cannot prove ku-latn
// identity in the presence of an unexamined conversion-table override.
pub fn arabicAlloc(a: A, text: []const u8) A.Error!?[]const u8 {
    const view = std.unicode.Utf8View.init(text) catch return null;
    var iterator = view.iterator();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var in_word = false;
    var previous_vowel = false;
    while (iterator.nextCodepointSlice()) |character| {
        const cp = std.unicode.utf8Decode(character) catch unreachable;
        const vowel: ?[]const u8 = switch (cp) {
            'a', 'A' => "ا", 'e', 'E' => "ە", 'ê', 'Ê' => "ێ", 'i', 'I' => "",
            'î', 'Î' => "ی", 'o', 'O' => "ۆ", 'u', 'U' => "و", 'û', 'Û' => "وو",
            else => null,
        };
        const consonant: ?[]const u8 = switch (cp) {
            'b', 'B' => "ب", 'c', 'C' => "ج", 'ç', 'Ç' => "چ", 'd', 'D' => "د",
            'f', 'F' => "ف", 'g', 'G' => "گ", 'h' => "ه", 'H', 'ḧ', 'Ḧ' => "ح",
            'j', 'J' => "ژ", 'k', 'K' => "ک", 'l', 'L' => "ل", 'm', 'M' => "م",
            'n', 'N' => "ن", 'p', 'P' => "پ", 'q', 'Q' => "ق", 'r', 'R' => "ر",
            's', 'S' => "س", 'ş', 'Ş' => "ش", 't', 'T' => "ت", 'v', 'V' => "ڤ",
            'w', 'W' => "و", 'x', 'X' => "خ", 'y', 'Y' => "ی", 'z', 'Z' => "ز",
            'ẍ', 'Ẍ' => "غ", ',' => "،", '?' => "؟", else => null,
        };
        if (vowel) |value| {
            if (!in_word or previous_vowel) try out.appendSlice(a, "ئ");
            try out.appendSlice(a, value);
            previous_vowel = true;
        } else if (consonant) |value| {
            try out.appendSlice(a, value);
            previous_vowel = false;
        } else {
            try out.appendSlice(a, character);
            if (cp < '0' or cp > '9') {
                in_word = false;
                previous_vowel = false;
                continue;
            }
            previous_vowel = false;
        }
        in_word = true;
    }
    return try out.toOwnedSlice(a);
}

test "matched title converter preserves ordered Arabic candidate vowels digits case and boundaries" {
    const a = std.testing.allocator;
    const samples = [_][2][]const u8{
        .{ "gh", "گه" }, .{ "gw", "گو" }, .{ "kw", "کو" }, .{ "hr", "هر" },
        .{ "rz", "رز" }, .{ "sw", "سو" }, .{ "aai", "ئائائ" },
        .{ "2a-a", "2ا-ئا" }, .{ "hHḧẍ", "هححغ" }, .{ "گه", "گه" },
        .{ "گa", "گئا" }, .{ "*a,a?a", "*ئا،ا؟ا" },
    };
    for (samples) |sample| {
        const converted = (try arabicAlloc(a, sample[0])).?;
        defer a.free(converted);
        try std.testing.expectEqualStrings(sample[1], converted);
    }
    try std.testing.expect(try arabicAlloc(a, "\xff") == null);
    try std.testing.expect(matchedCore("0470f6c99a6456a366635bf25a517a1f951de6f5"));
    try std.testing.expect(matchedCore("79b81ba96674efc8a803fc956bc501d347d440d2"));
    try std.testing.expect(!matchedCore("unknown"));
}
