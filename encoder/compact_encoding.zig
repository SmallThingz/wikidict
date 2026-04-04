const std = @import("std");
const generated = @import("generated_structure_tables");

pub const escape_byte: u8 = 0x01;
pub const extended_pattern_code: u8 = 0xFE;
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
    .{ .byte = 0x12, .value = '*' },
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

pub const escaped_patterns = static_escaped_patterns ++ generated.compact_patterns;
pub const static_extended_escaped_patterns = [_][]const u8{
    "|nolinkhead=",
};
pub const extended_escaped_patterns = static_extended_escaped_patterns ++ generated.compact_patterns_ext;

comptime {
    if (escaped_patterns.len >= extended_pattern_code) @compileError("escaped token table exceeds one-byte escape space");
    if (extended_escaped_patterns.len >= 255) @compileError("extended escaped token table exceeds one-byte extension space");
}

const char_to_token_table = blk: {
    var table = [_]u8{0} ** 256;
    for (char_tokens) |token| table[token.value] = token.byte;
    break :blk table;
};

const token_to_char_table = blk: {
    var table = [_]u8{0} ** 256;
    for (char_tokens) |token| table[token.byte] = token.value;
    break :blk table;
};

const single_pattern_table = blk: {
    var table = [_]?[]const u8{null} ** 256;
    for (single_tokens) |token| table[token.byte] = token.pattern;
    break :blk table;
};

const pattern_start_table = blk: {
    var table = [_]bool{false} ** 256;
    for (single_tokens) |token| table[token.pattern[0]] = true;
    for (escaped_patterns) |pattern| table[pattern[0]] = true;
    for (extended_escaped_patterns) |pattern| table[pattern[0]] = true;
    break :blk table;
};

const pattern_start_bytes = blk: {
    var seen = [_]bool{false} ** 256;
    var count: usize = 0;

    for (single_tokens) |token| {
        if (!seen[token.pattern[0]]) {
            seen[token.pattern[0]] = true;
            count += 1;
        }
    }
    for (escaped_patterns) |pattern| {
        if (!seen[pattern[0]]) {
            seen[pattern[0]] = true;
            count += 1;
        }
    }
    for (extended_escaped_patterns) |pattern| {
        if (!seen[pattern[0]]) {
            seen[pattern[0]] = true;
            count += 1;
        }
    }

    var bytes: [count]u8 = undefined;
    var index: usize = 0;
    for (seen, 0..) |present, byte| {
        if (!present) continue;
        bytes[index] = @intCast(byte);
        index += 1;
    }
    break :blk bytes;
};

const Match = union(enum) {
    single: SingleToken,
    escaped: struct {
        code: u8,
        pattern: []const u8,
    },
    extended: struct {
        code: u8,
        pattern: []const u8,
    },
};

pub fn encodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    _ = try encodeToList(&out, allocator, input);
    return out.toOwnedSlice(allocator);
}

pub fn encodeToList(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const stable_input = blk: {
        if (list.capacity == 0 or input.len == 0) break :blk null;
        const allocated = list.allocatedSlice();
        if (allocated.len == 0) break :blk null;

        const input_start = @intFromPtr(input.ptr);
        const input_end = input_start + input.len;
        const allocated_start = @intFromPtr(allocated.ptr);
        const allocated_end = allocated_start + allocated.len;
        if (input_start >= allocated_end or allocated_start >= input_end) break :blk null;

        break :blk try allocator.dupe(u8, input);
    };
    defer if (stable_input) |owned| allocator.free(owned);

    const source = stable_input orelse input;
    list.items.len = 0;
    try list.ensureTotalCapacity(allocator, source.len);

    var i: usize = 0;
    while (i < source.len) {
        if (canCopyLiteralRun(source[i])) {
            const start = i;
            i += 1;
            while (i < source.len and canCopyLiteralRun(source[i])) : (i += 1) {}
            try list.appendSlice(allocator, source[start..i]);
            continue;
        }

        if (pattern_start_table[source[i]]) {
            if (matchLongest(source, i)) |match| {
                switch (match) {
                    .single => |token| try list.append(allocator, token.byte),
                    .escaped => |token| {
                        try list.append(allocator, escape_byte);
                        try list.append(allocator, token.code);
                    },
                    .extended => |token| {
                        try list.append(allocator, escape_byte);
                        try list.append(allocator, extended_pattern_code);
                        try list.append(allocator, token.code);
                    },
                }
                i += switch (match) {
                    .single => |token| token.pattern.len,
                    .escaped => |token| token.pattern.len,
                    .extended => |token| token.pattern.len,
                };
                continue;
            }
        }

        if (source[i] == escape_byte) {
            try list.append(allocator, escape_byte);
            try list.append(allocator, 0);
        } else if (tokenByteForChar(source[i])) |token_byte| {
            try list.append(allocator, token_byte);
        } else if (needsRawLiteralEscape(source[i])) {
            try list.append(allocator, escape_byte);
            try list.append(allocator, raw_literal_code);
            try list.append(allocator, source[i]);
        } else {
            try list.append(allocator, source[i]);
        }
        i += 1;
    }

    return list.items;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const out_len = try decodedLen(input);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    const written = try decodeInto(out, input);
    std.debug.assert(written == out.len);
    return out;
}

fn decodedLen(input: []const u8) error{InvalidEncoding}!usize {
    var out_len: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte == escape_byte) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const code = input[i + 1];
            if (code == 0) {
                out_len += 1;
                i += 2;
                continue;
            }
            if (code == extended_pattern_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                const pattern = extendedPatternForCode(input[i + 2]) orelse return error.InvalidEncoding;
                out_len += pattern.len;
                i += 3;
                continue;
            }
            if (code == raw_literal_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                out_len += 1;
                i += 3;
                continue;
            } else {
                const pattern = patternForCode(code) orelse return error.InvalidEncoding;
                out_len += pattern.len;
            }
            i += 2;
            continue;
        }

        if (charForTokenByte(byte)) |value| {
            _ = value;
            out_len += 1;
            i += 1;
            continue;
        }

        if (singlePatternForByte(byte)) |pattern| {
            out_len += pattern.len;
        } else {
            out_len += 1;
        }
        i += 1;
    }

    return out_len;
}

fn decodeInto(out: []u8, input: []const u8) error{InvalidEncoding}!usize {
    var out_index: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte == escape_byte) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const code = input[i + 1];
            if (code == 0) {
                out[out_index] = 0;
                out_index += 1;
                i += 2;
                continue;
            }
            if (code == extended_pattern_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                const pattern = extendedPatternForCode(input[i + 2]) orelse return error.InvalidEncoding;
                @memcpy(out[out_index .. out_index + pattern.len], pattern);
                out_index += pattern.len;
                i += 3;
                continue;
            }
            if (code == raw_literal_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                out[out_index] = input[i + 2];
                out_index += 1;
                i += 3;
                continue;
            }

            const pattern = patternForCode(code) orelse return error.InvalidEncoding;
            @memcpy(out[out_index .. out_index + pattern.len], pattern);
            out_index += pattern.len;
            i += 2;
            continue;
        }

        if (charForTokenByte(byte)) |value| {
            out[out_index] = value;
            out_index += 1;
            i += 1;
            continue;
        }

        if (singlePatternForByte(byte)) |pattern| {
            @memcpy(out[out_index .. out_index + pattern.len], pattern);
            out_index += pattern.len;
        } else {
            out[out_index] = byte;
            out_index += 1;
        }
        i += 1;
    }

    return out_index;
}

fn matchLongest(input: []const u8, index: usize) ?Match {
    const first = input[index];
    inline for (pattern_start_bytes) |candidate| {
        if (first == candidate) return matchLongestForFirst(candidate, input, index);
    }
    return null;
}

fn matchLongestForFirst(comptime first: u8, input: []const u8, index: usize) ?Match {
    var best: ?Match = null;
    var best_len: usize = 0;

    inline for (single_tokens) |token| {
        if (token.pattern[0] != first) continue;
        if (token.pattern.len > best_len and index + token.pattern.len <= input.len and std.mem.eql(u8, input[index .. index + token.pattern.len], token.pattern)) {
            best = .{ .single = token };
            best_len = token.pattern.len;
        }
    }

    inline for (escaped_patterns, 0..) |pattern, escaped_index| {
        if (pattern[0] != first) continue;
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

    inline for (extended_escaped_patterns, 0..) |pattern, escaped_index| {
        if (pattern[0] != first) continue;
        if (pattern.len > best_len and index + pattern.len <= input.len and std.mem.eql(u8, input[index .. index + pattern.len], pattern)) {
            best = .{
                .extended = .{
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
    const token_byte = char_to_token_table[value];
    return if (token_byte == 0) null else token_byte;
}

fn charForTokenByte(byte: u8) ?u8 {
    const value = token_to_char_table[byte];
    return if (value == 0) null else value;
}

fn needsRawLiteralEscape(byte: u8) bool {
    if (byte == 0) return true;
    if (charForTokenByte(byte) != null) return true;
    if (singlePatternForByte(byte) != null) return true;
    if (tokenByteForChar(byte) != null) return true;
    return false;
}

fn canCopyLiteralRun(byte: u8) bool {
    if (pattern_start_table[byte]) return false;
    return !needsRawLiteralEscape(byte);
}

fn singlePatternForByte(byte: u8) ?[]const u8 {
    return single_pattern_table[byte];
}

fn patternForCode(code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index = code - 1;
    if (index >= escaped_patterns.len) return null;
    return escaped_patterns[index];
}

fn extendedPatternForCode(code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index: usize = code - 1;
    if (index >= extended_escaped_patterns.len) return null;
    return extended_escaped_patterns[index];
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

test "compact encoding preserves raw control bytes that collide with token bytes" {
    const sample = [_]u8{ 'a', '\t', 0x02, 0x09, 'b' };
    const encoded = try encodeAlloc(std.testing.allocator, &sample);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &sample, decoded);
}

test "encodeToList handles aliased input buffer" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try buf.appendSlice(std.testing.allocator,
        \\plain text with no tokens at all
    );

    const aliased_input = buf.items;
    const encoded = try encodeToList(&buf, std.testing.allocator, aliased_input);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(aliased_input, decoded);
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

    for ([_][]const u8{ "{{", "}}", "[[", "]]", "==English==", "|en|", "<!--", "-->" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, marker) == null);
    }
}
