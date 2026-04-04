const std = @import("std");

pub const escape_byte: u8 = 0x01;
pub const raw_literal_code: u8 = 0xFF;

pub const SingleToken = struct {
    byte: u8,
    pattern: []const u8,
};

pub const CharToken = struct {
    byte: u8,
    value: u8,
};

pub const char_tokens = [_]CharToken{
    .{ .byte = 0x02, .value = '\n' },
    .{ .byte = 0x03, .value = '{' },
    .{ .byte = 0x04, .value = '}' },
    .{ .byte = 0x05, .value = '[' },
    .{ .byte = 0x06, .value = ']' },
    .{ .byte = 0x07, .value = '|' },
    .{ .byte = 0x08, .value = '=' },
    .{ .byte = 0x09, .value = '#' },
    .{ .byte = 0x0A, .value = '*' },
    .{ .byte = 0x0B, .value = ':' },
    .{ .byte = 0x0C, .value = ';' },
    .{ .byte = 0x0D, .value = '<' },
    .{ .byte = 0x0E, .value = '>' },
    .{ .byte = 0x0F, .value = '\'' },
    .{ .byte = 0x10, .value = '/' },
    .{ .byte = 0x11, .value = '!' },
};

pub const single_tokens = [_]SingleToken{
    .{ .byte = 0xC0, .pattern = "{{" },
    .{ .byte = 0xC1, .pattern = "}}" },
    .{ .byte = 0xF5, .pattern = "[[" },
    .{ .byte = 0xF6, .pattern = "]]" },
    .{ .byte = 0xF7, .pattern = "==" },
    .{ .byte = 0xF8, .pattern = "===" },
    .{ .byte = 0xF9, .pattern = "====" },
    .{ .byte = 0xFA, .pattern = "\n# " },
    .{ .byte = 0xFB, .pattern = "\n## " },
    .{ .byte = 0xFC, .pattern = "\n#: " },
    .{ .byte = 0xFD, .pattern = "\n#* " },
    .{ .byte = 0xFE, .pattern = "|en|" },
    .{ .byte = 0xFF, .pattern = "\n* " },
};

pub const escaped_patterns = [_][]const u8{
    "====Translations====\n{{multitrans|data=\n",
    "====Derived terms====\n{{col|en\n|",
    "====Derived terms====\n{{col4|en\n|",
    "====Related terms====\n{{col|en\n|",
    "====Related terms====\n{{col4|en\n|",
    "===Alternative forms===\n* {{alt|en|",
    "===Proper noun===\n{{en-proper noun",
    "===Adjective===\n{{en-adj",
    "===Noun===\n{{en-noun",
    "===Verb===\n{{en-verb",
    "==English==\n",
    "====Translations====\n",
    "====Derived terms====\n",
    "====Related terms====\n",
    "====Usage notes====\n",
    "====Coordinate terms====\n",
    "====Further reading====\n",
    "====Conjugation====\n",
    "====Declension====\n",
    "====Inflection====\n",
    "====Hypernyms====\n",
    "====Hyponyms====\n",
    "====Synonyms====\n",
    "====Antonyms====\n",
    "====Descendants====\n",
    "====Quotations====\n",
    "===Alternative forms===\n",
    "===Pronunciation===\n",
    "===Etymology===\n",
    "===Proper noun===\n",
    "===Adjective===\n",
    "===Adverb===\n",
    "===Anagrams===\n",
    "===See also===\n",
    "===Further reading===\n",
    "===Derived terms===\n",
    "===Interjection===\n",
    "===Conjunction===\n",
    "===Determiner===\n",
    "===Numeral===\n",
    "===Pronoun===\n",
    "===Preposition===\n",
    "===Participle===\n",
    "===Phrase===\n",
    "===Idiom===\n",
    "===Proverb===\n",
    "===Symbol===\n",
    "===Letter===\n",
    "===Noun===\n",
    "===Verb===\n",
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
    "French: ",
    "German: ",
    "Spanish: ",
    "Portuguese: ",
    "Russian: ",
    "Japanese: ",
    "Italian: ",
    "Dutch: ",
    "Swedish: ",
    "Danish: ",
    "Polish: ",
    "Finnish: ",
    "Hungarian: ",
    "Greek: ",
    "Hebrew: ",
    "Arabic: ",
    "Turkish: ",
    "Korean: ",
    "Czech: ",
    "Bulgarian: ",
    "Ukrainian: ",
    "Romanian: ",
    "Chinese:\n*: Mandarin: ",
    "Norwegian: \n*: Bokmål: ",
    "Norwegian: \n*: Nynorsk: ",
    "French: {{tt+|fr|",
    "French: {{tt|fr|",
    "German: {{tt+|de|",
    "German: {{tt|de|",
    "Spanish: {{tt+|es|",
    "Spanish: {{tt|es|",
    "Portuguese: {{tt+|pt|",
    "Portuguese: {{tt|pt|",
    "Russian: {{tt+|ru|",
    "Russian: {{tt|ru|",
    "Japanese: {{tt+|ja|",
    "Japanese: {{tt|ja|",
    "Italian: {{tt+|it|",
    "Italian: {{tt|it|",
    "Dutch: {{tt+|nl|",
    "Dutch: {{tt|nl|",
    "Swedish: {{tt+|sv|",
    "Swedish: {{tt|sv|",
    "Danish: {{tt+|da|",
    "Danish: {{tt|da|",
    "Polish: {{tt+|pl|",
    "Polish: {{tt|pl|",
    "Finnish: {{tt+|fi|",
    "Finnish: {{tt|fi|",
    "Hungarian: {{tt+|hu|",
    "Hungarian: {{tt|hu|",
    "Greek: {{tt+|el|",
    "Greek: {{tt|el|",
    "Hebrew: {{tt+|he|",
    "Hebrew: {{tt|he|",
    "Arabic: {{tt+|ar|",
    "Arabic: {{tt|ar|",
    "Turkish: {{tt+|tr|",
    "Turkish: {{tt|tr|",
    "Korean: {{tt+|ko|",
    "Korean: {{tt|ko|",
    "Czech: {{tt+|cs|",
    "Czech: {{tt|cs|",
    "Bulgarian: {{tt+|bg|",
    "Bulgarian: {{tt|bg|",
    "Ukrainian: {{tt+|uk|",
    "Ukrainian: {{tt|uk|",
    "Romanian: {{tt+|ro|",
    "Romanian: {{tt|ro|",
    "Chinese:\n*: Mandarin: {{tt+|cmn|",
    "Chinese:\n*: Mandarin: {{tt|cmn|",
    "Norwegian: \n*: Bokmål: {{tt+|nb|",
    "Norwegian: \n*: Bokmål: {{tt|nb|",
    "Norwegian: \n*: Nynorsk: {{tt+|nn|",
    "Norwegian: \n*: Nynorsk: {{tt|nn|",
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

comptime {
    if (escaped_patterns.len >= 255) @compileError("escaped token table exceeds one-byte escape space");
}

const Match = union(enum) {
    single: SingleToken,
    escaped: struct {
        code: u8,
        pattern: []const u8,
    },
};

pub fn encodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (matchLongest(input, i)) |match| {
            switch (match) {
                .single => |token| try out.append(allocator, token.byte),
                .escaped => |token| {
                    try out.append(allocator, escape_byte);
                    try out.append(allocator, token.code);
                },
            }
            i += switch (match) {
                .single => |token| token.pattern.len,
                .escaped => |token| token.pattern.len,
            };
            continue;
        }

        if (input[i] == escape_byte) {
            try out.append(allocator, escape_byte);
            try out.append(allocator, 0);
        } else if (tokenByteForChar(input[i])) |token_byte| {
            try out.append(allocator, token_byte);
        } else if (needsRawLiteralEscape(input[i])) {
            try out.append(allocator, escape_byte);
            try out.append(allocator, raw_literal_code);
            try out.append(allocator, input[i]);
        } else {
            try out.append(allocator, input[i]);
        }
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte == escape_byte) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const code = input[i + 1];
            if (code == 0) {
                try out.append(allocator, 0);
                i += 2;
                continue;
            }
            if (code == raw_literal_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                try out.append(allocator, input[i + 2]);
                i += 3;
                continue;
            } else {
                const pattern = patternForCode(code) orelse return error.InvalidEncoding;
                try out.appendSlice(allocator, pattern);
            }
            i += 2;
            continue;
        }

        if (charForTokenByte(byte)) |value| {
            try out.append(allocator, value);
            i += 1;
            continue;
        }

        if (singlePatternForByte(byte)) |pattern| {
            try out.appendSlice(allocator, pattern);
        } else {
            try out.append(allocator, byte);
        }
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn matchLongest(input: []const u8, index: usize) ?Match {
    var best: ?Match = null;
    var best_len: usize = 0;

    for (single_tokens) |token| {
        if (token.pattern.len > best_len and index + token.pattern.len <= input.len and std.mem.eql(u8, input[index .. index + token.pattern.len], token.pattern)) {
            best = .{ .single = token };
            best_len = token.pattern.len;
        }
    }

    for (escaped_patterns, 0..) |pattern, escaped_index| {
        if (pattern.len > best_len and index + pattern.len <= input.len and std.mem.eql(u8, input[index .. index + pattern.len], pattern)) {
            best = .{
                .escaped = .{
                    .code = @intCast(escaped_index + 1),
                    .pattern = pattern,
                },
            };
            best_len = pattern.len;
        }
    }

    return best;
}

fn tokenByteForChar(value: u8) ?u8 {
    for (char_tokens) |token| {
        if (token.value == value) return token.byte;
    }
    return null;
}

fn charForTokenByte(byte: u8) ?u8 {
    for (char_tokens) |token| {
        if (token.byte == byte) return token.value;
    }
    return null;
}

fn needsRawLiteralEscape(byte: u8) bool {
    if (byte == 0) return true;
    if (singlePatternForByte(byte) != null) return true;
    if (charForTokenByte(byte) != null) return true;
    return false;
}

fn singlePatternForByte(byte: u8) ?[]const u8 {
    for (single_tokens) |token| {
        if (token.byte == byte) return token.pattern;
    }
    return null;
}

fn patternForCode(code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index = code - 1;
    if (index >= escaped_patterns.len) return null;
    return escaped_patterns[index];
}

test "compact encoding round trips" {
    const sample =
        \\==English==
        \\===Alternative forms===
        \\* {{alt|en|colour}}
        \\
        \\===Noun===
        \\{{en-noun|s}}
        \\# [[light]]
        \\## {{lb|en|countable}} [[color]]
        \\#: Example.
        \\#* Another example.
        \\====Translations====
        \\{{multitrans|data=
        \\* French: {{tt+|fr|couleur}}
        \\}}
        \\{{trans-bottom}}
    ;

    const encoded = try encodeAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
}

test "compact encoding preserves nul bytes through escape" {
    const sample = [_]u8{ 'a', 0, 'b' };
    const encoded = try encodeAlloc(std.testing.allocator, &sample);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &sample, decoded);
}

test "compact encoding removes visible wiki punctuation from encoded bytes" {
    const sample =
        \\==English==
        \\* {{alt|en|colour}}
        \\# [[light]]
        \\<!-- note -->
    ;

    const encoded = try encodeAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    for ("{}\n[]|=#*:;<>/'!") |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, encoded, c) == null);
    }
}
