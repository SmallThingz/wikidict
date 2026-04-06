const std = @import("std");

pub const SectionKind = enum(u8) {
    lines = 0,
    pos_lines = 1,
    term_list = 2,
    translations = 3,
};

pub const RuntimeLineTemplate = struct {
    code: u16,
    name: []const u8,
};

pub const RuntimeTranslationTemplate = struct {
    code: u16,
    name: []const u8,
};

pub const RuntimeHeadingLevelSpec = struct {
    code: u16,
    level: u8,
    title: []const u8,
    kind: SectionKind,
};

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
            const codepoint = try decodePacked2(byte, input[i + 1]);
            out_len += std.unicode.utf8CodepointSequenceLength(codepoint) catch return error.InvalidEncoding;
            i += 2;
            continue;
        }
        if (byte < 0xE0) {
            if (i + 2 >= input.len) return error.InvalidEncoding;
            const codepoint = try decodePacked3(byte, input[i + 1], input[i + 2]);
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
            }

            const pattern = patternForCodeIn(mappings, code) orelse return error.InvalidEncoding;
            out_len += pattern.len;
            i += 2;
            continue;
        }

        if (directPatternForByteIn(mappings, byte)) |pattern| {
            out_len += pattern.len;
            i += 1;
            continue;
        }
        return error.InvalidEncoding;
    }

    return out_len;
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
            const codepoint = try decodePacked2(byte, input[i + 1]);
            const written = std.unicode.utf8Encode(codepoint, out[out_index..]) catch return error.InvalidEncoding;
            out_index += written;
            i += 2;
            continue;
        }
        if (byte < 0xE0) {
            if (i + 2 >= input.len) return error.InvalidEncoding;
            const codepoint = try decodePacked3(byte, input[i + 1], input[i + 2]);
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

        if (directPatternForByteIn(mappings, byte)) |pattern| {
            @memcpy(out[out_index .. out_index + pattern.len], pattern);
            out_index += pattern.len;
            i += 1;
            continue;
        }
        return error.InvalidEncoding;
    }

    return out_index;
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

fn readCompactRef(input: []const u8, cursor: *usize) error{InvalidEncoding}!u16 {
    if (cursor.* >= input.len) return error.InvalidEncoding;
    const first = input[cursor.*];
    cursor.* += 1;
    if (first != 0xFF) return first;
    if (cursor.* + 1 >= input.len) return error.InvalidEncoding;
    const lo = input[cursor.*];
    const hi = input[cursor.* + 1];
    cursor.* += 2;
    return @as(u16, lo) | (@as(u16, hi) << 8);
}

fn lineTemplateNameIn(mappings: RuntimeMappings, code: u16) ?[]const u8 {
    for (mappings.line_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
}

fn translationTemplateNameIn(mappings: RuntimeMappings, code: u16) ?[]const u8 {
    for (mappings.translation_templates) |template| {
        if (template.code == code) return template.name;
    }
    return null;
}

fn headingLevelDefForCodeIn(mappings: RuntimeMappings, code: u16) ?RuntimeHeadingLevelSpec {
    for (mappings.heading_levels) |def| {
        if (def.code == code) return def;
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

fn directPatternForByteIn(mappings: RuntimeMappings, byte: u8) ?[]const u8 {
    if (byte < 0xE0) return null;
    const index: usize = byte - 0xE0;
    if (index >= mappings.direct_patterns.len) return null;
    return mappings.direct_patterns[index];
}

fn patternForCodeIn(mappings: RuntimeMappings, code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index: usize = code - 1;
    if (index >= mappings.escaped_patterns.len) return null;
    return mappings.escaped_patterns[index];
}

fn extendedPatternForCodeIn(mappings: RuntimeMappings, code: u8) ?[]const u8 {
    if (code == 0) return null;
    const index: usize = code - 1;
    if (index >= mappings.extended_patterns.len) return null;
    return mappings.extended_patterns[index];
}

fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, value.len, .little);
    hasher.update(&len_buf);
    hasher.update(value);
}
