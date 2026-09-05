const std = @import("std");
const generated = @import("generated_structure_tables");
const compact_pattern_seed = @import("compact_pattern_seed");
const structure_report = @import("shared_structure_report");
const wikitext = @import("wikitext_source");

pub const RuntimeLineTemplate = generated.LineTemplate;
pub const RuntimeTranslationTemplate = generated.TranslationTemplate;
pub const RuntimeHeadingLevelSpec = generated.HeadingLevelSpec;

pub const RuntimeMappings = struct {
    direct_patterns: []const []const u8,
    escaped_patterns: []const []const u8,
    extended_patterns: []const []const u8,
    line_templates: []const RuntimeLineTemplate,
    translation_templates: []const RuntimeTranslationTemplate,
    heading_levels: []const RuntimeHeadingLevelSpec,
};

pub const OwnedRuntimeMappings = struct {
    direct_patterns: [][]const u8 = &.{},
    escaped_patterns: [][]const u8 = &.{},
    extended_patterns: [][]const u8 = &.{},
    line_templates: []RuntimeLineTemplate = &.{},
    translation_templates: []RuntimeTranslationTemplate = &.{},
    heading_levels: []RuntimeHeadingLevelSpec = &.{},
    expected_line_template_count: u32 = 0,
    expected_translation_template_count: u32 = 0,
    template_table_fingerprint: u32 = 0,

    pub fn view(self: *const OwnedRuntimeMappings) RuntimeMappings {
        return .{
            .direct_patterns = self.direct_patterns,
            .escaped_patterns = self.escaped_patterns,
            .extended_patterns = self.extended_patterns,
            .line_templates = self.line_templates,
            .translation_templates = self.translation_templates,
            .heading_levels = self.heading_levels,
        };
    }

    pub fn deinit(self: *OwnedRuntimeMappings, allocator: std.mem.Allocator) void {
        allocator.free(self.direct_patterns);
        allocator.free(self.escaped_patterns);
        allocator.free(self.extended_patterns);
        allocator.free(self.line_templates);
        allocator.free(self.translation_templates);
        allocator.free(self.heading_levels);
        self.* = .{};
    }
};

pub const escape_byte: u8 = 0xFF;
pub const special_template_line_code: u8 = 0xFB;
pub const special_template_translation_code: u8 = 0xFC;
pub const special_heading_line_code: u8 = 0xFD;
pub const extended_pattern_code: u8 = 0xFE;
pub const raw_literal_code: u8 = 0xFF;

pub const SingleToken = struct {
    byte: u8,
    pattern: []const u8,
};

// Do not add 1-byte-to-1-byte mappings here. They do not reduce payload size and only
// waste opcode space. Keep this table for genuine contractions that replace longer text.
pub const static_direct_patterns = compact_pattern_seed.static_direct_patterns;
const generated_direct_patterns = if (@hasDecl(generated, "compact_direct_patterns"))
    generated.compact_direct_patterns
else
    [_][]const u8{};
pub const direct_patterns = static_direct_patterns ++ generated_direct_patterns;
pub const single_tokens = blk: {
    if (direct_patterns.len > compact_pattern_seed.max_direct_pattern_count) {
        @compileError("direct token table exceeds one-byte opcode space");
    }
    var tokens: [direct_patterns.len]SingleToken = undefined;
    for (direct_patterns, 0..) |pattern, idx| {
        tokens[idx] = .{
            .byte = @as(u8, @intCast(0xE0 + idx)),
            .pattern = pattern,
        };
    }
    break :blk tokens;
};

pub const static_escaped_patterns = compact_pattern_seed.static_escaped_patterns;

pub const escaped_patterns = static_escaped_patterns ++ generated.compact_patterns;
pub const static_extended_escaped_patterns = compact_pattern_seed.static_extended_escaped_patterns;
pub const extended_escaped_patterns = static_extended_escaped_patterns ++ generated.compact_patterns_ext;
const line_template_defs = generated.line_templates;
const translation_template_defs = generated.translation_templates;
const heading_level_defs = generated.heading_level_specs;

pub fn currentRuntimeMappings() RuntimeMappings {
    return .{
        .direct_patterns = &direct_patterns,
        .escaped_patterns = &escaped_patterns,
        .extended_patterns = &extended_escaped_patterns,
        .line_templates = &line_template_defs,
        .translation_templates = &translation_template_defs,
        .heading_levels = &heading_level_defs,
    };
}

pub fn mappingFingerprint(mappings: RuntimeMappings) u32 {
    var hasher = std.hash.Wyhash.init(0x4a92b39d6f1357c1);

    for (mappings.direct_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (mappings.escaped_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (mappings.extended_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (mappings.line_templates) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.name);
    }
    for (mappings.translation_templates) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.name);
    }
    for (mappings.heading_levels) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        hasher.update(&[_]u8{entry.level});
        fingerprintUpdateString(&hasher, entry.title);
        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
    }

    return @truncate(hasher.final());
}

pub fn binaryMappingFingerprint(mappings: RuntimeMappings) u32 {
    var hasher = std.hash.Wyhash.init(0x4a92b39d6f1357c1);

    for (mappings.direct_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (mappings.escaped_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (mappings.extended_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (mappings.heading_levels) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        hasher.update(&[_]u8{entry.level});
        fingerprintUpdateString(&hasher, entry.title);
        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
    }

    return @truncate(hasher.final());
}

pub fn templateTableFingerprint(mappings: RuntimeMappings) u32 {
    return structure_report.templateTableFingerprint(mappings.line_templates, mappings.translation_templates);
}

comptime {
    if (escaped_patterns.len >= special_template_line_code) @compileError("escaped token table exceeds reserved escape space");
    if (extended_escaped_patterns.len >= 255) @compileError("extended escaped token table exceeds one-byte extension space");
}

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
    line_template: struct {
        code: u16,
        pattern_len: usize,
    },
    translation_template: struct {
        code: u16,
        pattern_len: usize,
    },
    heading_line: struct {
        code: u16,
        pattern_len: usize,
    },
};

pub fn encodeAlloc(allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidUtf8})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    _ = try encodeToList(&out, allocator, input);
    return out.toOwnedSlice(allocator);
}

pub fn encodeToList(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidUtf8})![]const u8 {
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
                    .line_template => |token| {
                        try list.append(allocator, escape_byte);
                        try list.append(allocator, special_template_line_code);
                        try appendCompactRef(list, allocator, token.code);
                    },
                    .translation_template => |token| {
                        try list.append(allocator, escape_byte);
                        try list.append(allocator, special_template_translation_code);
                        try appendCompactRef(list, allocator, token.code);
                    },
                    .heading_line => |token| {
                        try list.append(allocator, escape_byte);
                        try list.append(allocator, special_heading_line_code);
                        try appendCompactRef(list, allocator, token.code);
                    },
                }
                i += switch (match) {
                    .single => |token| token.pattern.len,
                    .escaped => |token| token.pattern.len,
                    .extended => |token| token.pattern.len,
                    .line_template => |token| token.pattern_len,
                    .translation_template => |token| token.pattern_len,
                    .heading_line => |token| token.pattern_len,
                };
                continue;
            }
        }

        if (tokenByteForChar(source[i])) |token_byte| {
            try list.append(allocator, token_byte);
        } else {
            i += try appendLiteralCodepoint(list, allocator, source[i..]);
            continue;
        }
        i += 1;
    }

    return list.items;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    return decodeAllocWithMappings(allocator, input, currentRuntimeMappings());
}

pub fn decodeAllocWithMappings(
    allocator: std.mem.Allocator,
    input: []const u8,
    mappings: RuntimeMappings,
) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    const out_len = try decodedLenWithMappings(input, mappings);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    const written = try decodeIntoWithMappings(out, input, mappings);
    std.debug.assert(written == out.len);
    return out;
}

pub fn appendDecoded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})!void {
    return appendDecodedWithMappings(out, allocator, input, currentRuntimeMappings());
}

pub fn appendDecodedWithMappings(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    mappings: RuntimeMappings,
) (std.mem.Allocator.Error || error{InvalidEncoding})!void {
    const decoded_len = try decodedLenWithMappings(input, mappings);
    const old_len = out.items.len;
    const new_len = std.math.add(usize, old_len, decoded_len) catch return error.OutOfMemory;
    try out.resize(allocator, new_len);
    errdefer out.shrinkRetainingCapacity(old_len);
    const written = try decodeIntoWithMappings(out.items[old_len..], input, mappings);
    std.debug.assert(written == decoded_len);
}

pub fn decodedLen(input: []const u8) error{InvalidEncoding}!usize {
    return decodedLenWithMappings(input, currentRuntimeMappings());
}

fn decodedLenWithMappings(input: []const u8, mappings: RuntimeMappings) error{InvalidEncoding}!usize {
    var out_len: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte < 0x80) {
            out_len += 1;
            i += 1;
            continue;
        }
        if (byte < 0xC0) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const codepoint = decodePacked2(byte, input[i + 1]) catch return error.InvalidEncoding;
            out_len += std.unicode.utf8CodepointSequenceLength(codepoint) catch return error.InvalidEncoding;
            i += 2;
            continue;
        }
        if (byte < 0xE0) {
            if (i + 2 >= input.len) return error.InvalidEncoding;
            const codepoint = decodePacked3(byte, input[i + 1], input[i + 2]) catch return error.InvalidEncoding;
            out_len += std.unicode.utf8CodepointSequenceLength(codepoint) catch return error.InvalidEncoding;
            i += 3;
            continue;
        }
        if (byte == escape_byte) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const code = input[i + 1];
            if (code == 0) {
                out_len += 1;
                i += 2;
                continue;
            }
            if (code == special_template_line_code) {
                i += 2;
                const ref = try readCompactRef(input, &i);
                const name = lineTemplateNameIn(mappings, ref) orelse return error.InvalidEncoding;
                out_len += 2 + name.len;
                continue;
            }
            if (code == special_template_translation_code) {
                i += 2;
                const ref = try readCompactRef(input, &i);
                const name = translationTemplateNameIn(mappings, ref) orelse return error.InvalidEncoding;
                out_len += 2 + name.len;
                continue;
            }
            if (code == special_heading_line_code) {
                i += 2;
                const ref = try readCompactRef(input, &i);
                const def = headingLevelDefForCodeIn(mappings, ref) orelse return error.InvalidEncoding;
                out_len += headingLineLen(def);
                continue;
            }
            if (code == extended_pattern_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                const pattern = extendedPatternForCodeIn(mappings, input[i + 2]) orelse return error.InvalidEncoding;
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
                const pattern = patternForCodeIn(mappings, code) orelse return error.InvalidEncoding;
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

        if (charForTokenByte(byte) != null) {
            out_len += 1;
        } else if (directPatternForByteIn(mappings, byte)) |pattern| {
            out_len += pattern.len;
        } else {
            return error.InvalidEncoding;
        }
        i += 1;
    }

    return out_len;
}

fn decodeInto(out: []u8, input: []const u8) error{InvalidEncoding}!usize {
    return decodeIntoWithMappings(out, input, currentRuntimeMappings());
}

fn decodeIntoWithMappings(out: []u8, input: []const u8, mappings: RuntimeMappings) error{InvalidEncoding}!usize {
    var out_index: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte < 0x80) {
            out[out_index] = byte;
            out_index += 1;
            i += 1;
            continue;
        }
        if (byte < 0xC0) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const codepoint = decodePacked2(byte, input[i + 1]) catch return error.InvalidEncoding;
            const written = std.unicode.utf8Encode(codepoint, out[out_index..]) catch return error.InvalidEncoding;
            out_index += written;
            i += 2;
            continue;
        }
        if (byte < 0xE0) {
            if (i + 2 >= input.len) return error.InvalidEncoding;
            const codepoint = decodePacked3(byte, input[i + 1], input[i + 2]) catch return error.InvalidEncoding;
            const written = std.unicode.utf8Encode(codepoint, out[out_index..]) catch return error.InvalidEncoding;
            out_index += written;
            i += 3;
            continue;
        }
        if (byte == escape_byte) {
            if (i + 1 >= input.len) return error.InvalidEncoding;
            const code = input[i + 1];
            if (code == 0) {
                out[out_index] = 0;
                out_index += 1;
                i += 2;
                continue;
            }
            if (code == special_template_line_code) {
                i += 2;
                const ref = try readCompactRef(input, &i);
                const name = lineTemplateNameIn(mappings, ref) orelse return error.InvalidEncoding;
                out[out_index] = '{';
                out[out_index + 1] = '{';
                @memcpy(out[out_index + 2 .. out_index + 2 + name.len], name);
                out_index += 2 + name.len;
                continue;
            }
            if (code == special_template_translation_code) {
                i += 2;
                const ref = try readCompactRef(input, &i);
                const name = translationTemplateNameIn(mappings, ref) orelse return error.InvalidEncoding;
                out[out_index] = '{';
                out[out_index + 1] = '{';
                @memcpy(out[out_index + 2 .. out_index + 2 + name.len], name);
                out_index += 2 + name.len;
                continue;
            }
            if (code == special_heading_line_code) {
                i += 2;
                const ref = try readCompactRef(input, &i);
                const def = headingLevelDefForCodeIn(mappings, ref) orelse return error.InvalidEncoding;
                out_index += try writeHeadingLine(out[out_index..], def);
                continue;
            }
            if (code == extended_pattern_code) {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                const pattern = extendedPatternForCodeIn(mappings, input[i + 2]) orelse return error.InvalidEncoding;
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

            const pattern = patternForCodeIn(mappings, code) orelse return error.InvalidEncoding;
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

        if (directPatternForByteIn(mappings, byte)) |pattern| {
            @memcpy(out[out_index .. out_index + pattern.len], pattern);
            out_index += pattern.len;
        } else {
            return error.InvalidEncoding;
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

    if (first == '{') {
        if (matchGenericTemplate(input, index)) |match| {
            const match_len = switch (match) {
                .line_template => |token| token.pattern_len,
                .translation_template => |token| token.pattern_len,
                else => unreachable,
            };
            if (match_len > best_len) {
                best = match;
                best_len = match_len;
            }
        }
    }

    if (first == '=') {
        if (matchGenericHeading(input, index)) |match| {
            const match_len = switch (match) {
                .heading_line => |token| token.pattern_len,
                else => unreachable,
            };
            if (match_len > best_len) {
                best = match;
                best_len = match_len;
            }
        }
    }

    return best;
}

fn tokenByteForChar(value: u8) ?u8 {
    _ = value;
    return null;
}

fn charForTokenByte(byte: u8) ?u8 {
    _ = byte;
    return null;
}

fn needsRawLiteralEscape(byte: u8) bool {
    if (byte >= 0x80) return true;
    if (singlePatternForByte(byte) != null) return true;
    if (tokenByteForChar(byte) != null) return true;
    return false;
}

fn canCopyLiteralRun(byte: u8) bool {
    if (byte >= 0x80) return false;
    if (pattern_start_table[byte]) return false;
    return !needsRawLiteralEscape(byte);
}

fn appendLiteralCodepoint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidUtf8})!usize {
    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return error.InvalidUtf8;
    if (input.len < len) return error.InvalidUtf8;
    const codepoint = std.unicode.utf8Decode(input[0..len]) catch return error.InvalidUtf8;
    const used_bits = bitLen(codepoint);

    if (used_bits <= 7) {
        try list.append(allocator, @intCast(codepoint));
    } else if (used_bits <= 14) {
        try list.append(allocator, 0x80 | @as(u8, @intCast(codepoint >> 8)));
        try list.append(allocator, @as(u8, @intCast(codepoint & 0xFF)));
    } else {
        try list.append(allocator, 0xC0 | @as(u8, @intCast(codepoint >> 16)));
        try list.append(allocator, @as(u8, @intCast((codepoint >> 8) & 0xFF)));
        try list.append(allocator, @as(u8, @intCast(codepoint & 0xFF)));
    }
    return len;
}

fn decodePacked2(first: u8, second: u8) error{InvalidEncoding}!u21 {
    const codepoint: u21 = (@as(u21, first & 0x3F) << 8) | second;
    if (codepoint < 0x80 or !std.unicode.utf8ValidCodepoint(codepoint)) return error.InvalidEncoding;
    return codepoint;
}

fn decodePacked3(first: u8, second: u8, third: u8) error{InvalidEncoding}!u21 {
    const codepoint: u21 = (@as(u21, first & 0x1F) << 16) | (@as(u21, second) << 8) | third;
    if (codepoint < 0x4000 or !std.unicode.utf8ValidCodepoint(codepoint)) return error.InvalidEncoding;
    return codepoint;
}

fn bitLen(value: u21) u6 {
    return if (value == 0) 0 else @as(u6, @intCast(@bitSizeOf(u21) - @clz(value)));
}

fn appendCompactRef(list: *std.ArrayList(u8), allocator: std.mem.Allocator, ref: u16) std.mem.Allocator.Error!void {
    if (ref <= 0xFE) {
        try list.append(allocator, @intCast(ref));
        return;
    }
    try list.append(allocator, 0xFF);
    try list.append(allocator, @intCast(ref & 0xFF));
    try list.append(allocator, @intCast(ref >> 8));
}

fn readCompactRef(input: []const u8, cursor: *usize) error{InvalidEncoding}!u16 {
    if (cursor.* >= input.len) return error.InvalidEncoding;
    const first = input[cursor.*];
    cursor.* += 1;
    if (first != 0xFF) return first;
    if (cursor.* + 1 >= input.len) return error.InvalidEncoding;
    const lo = input[cursor.*];
    const hi = input[cursor.* + 1];
    cursor.* += 2;
    return std.mem.readInt(u16, &[_]u8{ lo, hi }, .little);
}

fn matchGenericHeading(input: []const u8, index: usize) ?Match {
    if (index != 0 and input[index - 1] != '\n') return null;
    const line_end = std.mem.indexOfScalarPos(u8, input, index, '\n') orelse input.len;
    const line = input[index..line_end];
    const heading = wikitext.parseHeadingLine(line) orelse return null;
    const code = headingLevelCodeForTitle(heading.title, heading.level) orelse return null;
    return .{
        .heading_line = .{
            .code = code,
            .pattern_len = line.len,
        },
    };
}

fn matchGenericTemplate(input: []const u8, index: usize) ?Match {
    if (index + 3 > input.len) return null;
    if (!std.mem.startsWith(u8, input[index..], "{{")) return null;

    var name_end = index + 2;
    while (name_end < input.len) : (name_end += 1) {
        switch (input[name_end]) {
            '|', '}', '\n', '\r' => break,
            else => {},
        }
    }
    if (name_end <= index + 2) return null;

    const name = input[index + 2 .. name_end];
    if (lineTemplateCode(name)) |code| {
        return .{
            .line_template = .{
                .code = code,
                .pattern_len = 2 + name.len,
            },
        };
    }
    if (translationTemplateCode(name)) |code| {
        return .{
            .translation_template = .{
                .code = code,
                .pattern_len = 2 + name.len,
            },
        };
    }
    return null;
}

fn headingLevelCodeForTitle(title: []const u8, level: u8) ?u16 {
    for (heading_level_defs) |def| {
        if (def.level == level and std.mem.eql(u8, def.title, title)) return def.code;
    }
    return null;
}

fn headingLevelDefForCode(code: u16) ?generated.HeadingLevelSpec {
    return headingLevelDefForCodeIn(currentRuntimeMappings(), code);
}

fn headingLevelDefForCodeIn(mappings: RuntimeMappings, code: u16) ?RuntimeHeadingLevelSpec {
    for (mappings.heading_levels) |def| {
        if (def.code == code) return def;
    }
    return null;
}

fn lineTemplateCode(name: []const u8) ?u16 {
    for (line_template_defs) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.code;
    }
    return null;
}

fn translationTemplateCode(name: []const u8) ?u16 {
    for (translation_template_defs) |template| {
        if (std.mem.eql(u8, template.name, name)) return template.code;
    }
    return null;
}

fn lineTemplateName(code: u16) ?[]const u8 {
    return lineTemplateNameIn(currentRuntimeMappings(), code);
}

fn lineTemplateNameIn(mappings: RuntimeMappings, code: u16) ?[]const u8 {
    for (mappings.line_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
}

fn translationTemplateName(code: u16) ?[]const u8 {
    return translationTemplateNameIn(currentRuntimeMappings(), code);
}

fn translationTemplateNameIn(mappings: RuntimeMappings, code: u16) ?[]const u8 {
    for (mappings.translation_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
}

fn headingLineLen(def: RuntimeHeadingLevelSpec) usize {
    return def.level * 2 + def.title.len;
}

fn writeHeadingLine(out: []u8, def: RuntimeHeadingLevelSpec) error{InvalidEncoding}!usize {
    const needed = headingLineLen(def);
    if (out.len < needed) return error.InvalidEncoding;
    @memset(out[0..def.level], '=');
    @memcpy(out[def.level .. def.level + def.title.len], def.title);
    @memset(out[def.level + def.title.len .. needed], '=');
    return needed;
}

fn patternListContains(patterns: []const []const u8, needle: []const u8) bool {
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern, needle)) return true;
    }
    return false;
}

fn singlePatternForByte(byte: u8) ?[]const u8 {
    return single_pattern_table[byte];
}

fn directPatternForByteIn(mappings: RuntimeMappings, byte: u8) ?[]const u8 {
    if (byte < 0xE0) return null;
    const index: usize = byte - 0xE0;
    if (index >= mappings.direct_patterns.len) return null;
    return mappings.direct_patterns[index];
}

fn patternForCode(code: u8) ?[]const u8 {
    return patternForCodeIn(currentRuntimeMappings(), code);
}

fn patternForCodeIn(mappings: RuntimeMappings, code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index = code - 1;
    if (index >= mappings.escaped_patterns.len) return null;
    return mappings.escaped_patterns[index];
}

fn extendedPatternForCode(code: u8) ?[]const u8 {
    return extendedPatternForCodeIn(currentRuntimeMappings(), code);
}

fn extendedPatternForCodeIn(mappings: RuntimeMappings, code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index: usize = code - 1;
    if (index >= mappings.extended_patterns.len) return null;
    return mappings.extended_patterns[index];
}

fn appendUniqueTemplateName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, try allocator.dupe(u8, name));
}

fn combinedKnownTemplateNamesAlloc(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |entry| allocator.free(entry);
        names.deinit(allocator);
    }

    for (line_template_defs) |template| try appendUniqueTemplateName(allocator, &names, template.name);
    for (translation_template_defs) |template| try appendUniqueTemplateName(allocator, &names, template.name);
    return names;
}

fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, value.len, .little);
    hasher.update(&len_buf);
    hasher.update(value);
}

test "appendDecoded extends an existing output buffer" {
    const sample = "# [[light]] {{en-noun|s}}";
    const encoded = try encodeAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, "prefix:");
    try appendDecoded(&out, std.testing.allocator, encoded);
    try std.testing.expectEqualStrings("prefix:# [[light]] {{en-noun|s}}", out.items);

    const before_len = out.items.len;
    try std.testing.expectError(error.InvalidEncoding, appendDecoded(&out, std.testing.allocator, &.{escape_byte}));
    try std.testing.expectEqual(before_len, out.items.len);
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

test "compact encoding removes contracted wiki markers from encoded bytes" {
    const sample =
        \\==English==
        \\* {{alt|en|colour}}
        \\# [[light]]
        \\<!-- note -->
    ;

    const encoded = try encodeAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);

    for ([_][]const u8{ "{{", "}}", "[[", "]]", "==English==", "|en|" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, marker) == null);
    }
}

test "compact encoding re-encodes non-ascii utf literals into packed forms" {
    const sample = "caf\u{00E9} \u{1F642}";
    const encoded = try encodeAlloc(std.testing.allocator, sample);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(sample, decoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\xC3\xA9") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\xF0\x9F\x99\x82") == null);
}

test "compact encoding generically encodes non-hot heading lines" {
    var rendered_heading: ?[]u8 = null;
    defer if (rendered_heading) |value| std.testing.allocator.free(value);

    for (heading_level_defs) |def| {
        const buf = try std.testing.allocator.alloc(u8, headingLineLen(def));
        const written = try writeHeadingLine(buf, def);
        std.debug.assert(written == buf.len);
        if (patternListContains(direct_patterns[0..], buf)) {
            std.testing.allocator.free(buf);
            continue;
        }
        if (patternListContains(escaped_patterns[0..], buf)) {
            std.testing.allocator.free(buf);
            continue;
        }
        if (patternListContains(extended_escaped_patterns[0..], buf)) {
            std.testing.allocator.free(buf);
            continue;
        }
        rendered_heading = buf;
        break;
    }

    if (rendered_heading) |heading| {
        const sample = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{heading});
        defer std.testing.allocator.free(sample);
        const encoded = try encodeAlloc(std.testing.allocator, sample);
        defer std.testing.allocator.free(encoded);
        const decoded = try decodeAlloc(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(sample, decoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, heading) == null);
    }
}

test "compact encoding generically encodes non-hot template names" {
    var chosen_name: ?[]const u8 = null;
    blk: {
        for (line_template_defs) |template| {
            const opener = try std.fmt.allocPrint(std.testing.allocator, "{{{{{s}", .{template.name});
            defer std.testing.allocator.free(opener);
            if (patternListContains(direct_patterns[0..], opener)) continue;
            if (patternListContains(escaped_patterns[0..], opener)) continue;
            if (patternListContains(extended_escaped_patterns[0..], opener)) continue;
            chosen_name = template.name;
            break :blk;
        }
        for (translation_template_defs) |template| {
            const opener = try std.fmt.allocPrint(std.testing.allocator, "{{{{{s}", .{template.name});
            defer std.testing.allocator.free(opener);
            if (patternListContains(direct_patterns[0..], opener)) continue;
            if (patternListContains(escaped_patterns[0..], opener)) continue;
            if (patternListContains(extended_escaped_patterns[0..], opener)) continue;
            chosen_name = template.name;
            break :blk;
        }
    }

    if (chosen_name) |name| {
        const sample = try std.fmt.allocPrint(std.testing.allocator, "{{{{{s}|x}}}}", .{name});
        defer std.testing.allocator.free(sample);
        const raw_prefix = try std.fmt.allocPrint(std.testing.allocator, "{{{{{s}", .{name});
        defer std.testing.allocator.free(raw_prefix);
        const encoded = try encodeAlloc(std.testing.allocator, sample);
        defer std.testing.allocator.free(encoded);
        const decoded = try decodeAlloc(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(sample, decoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, raw_prefix) == null);
    }
}

test "compact pattern tables do not embed template-specific opener strings" {
    inline for (.{
        direct_patterns[0..],
        escaped_patterns[0..],
        extended_escaped_patterns[0..],
    }) |patterns| {
        for (patterns) |pattern| {
            const template_start = std.mem.indexOf(u8, pattern, "{{") orelse continue;
            try std.testing.expectEqualStrings("{{", pattern[template_start .. template_start + 2]);
            try std.testing.expect(template_start + 2 == pattern.len);
        }
    }
}

test "compact encoding round trips every known template name from the bottom of the combined table" {
    var names = try combinedKnownTemplateNamesAlloc(std.testing.allocator);
    defer {
        for (names.items) |entry| std.testing.allocator.free(entry);
        names.deinit(std.testing.allocator);
    }

    var idx = names.items.len;
    while (idx > 0) {
        idx -= 1;
        const name = names.items[idx];
        const sample = try std.fmt.allocPrint(std.testing.allocator, "{{{{{s}|x|y}}}}", .{name});
        defer std.testing.allocator.free(sample);

        const encoded = try encodeAlloc(std.testing.allocator, sample);
        defer std.testing.allocator.free(encoded);
        const decoded = try decodeAlloc(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqualStrings(sample, decoded);
    }
}
