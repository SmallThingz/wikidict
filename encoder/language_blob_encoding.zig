const std = @import("std");
const support = @import("blob_codec_support.zig");
const document_ir = @import("document_ir.zig");

const flag_custom_language_heading: u8 = 1 << 0;
const flag_preamble: u8 = 1 << 1;
const op_heading: u8 = 1;

pub const LanguageContext = struct {
    heading: []const u8,
    code: []const u8 = "",
};

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidEncoding,
    InvalidLanguageSection,
};

pub fn reconstructionHeadingFromTitle(title: []const u8) ?[]const u8 {
    const prefix = "Reconstruction:";
    const rest = if (std.mem.startsWith(u8, title, prefix)) title[prefix.len..] else title;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0) return null;
    return rest[0..slash];
}

const ParsedHeading = struct {
    level: u8,
    raw_title: []const u8,
    title: []const u8,
};

pub const SourceLanguageSection = struct {
    heading: []const u8,
    source: []const u8,
};

pub const SourceLanguageIterator = struct {
    source: []const u8,
    cursor: usize = 0,
    active_start: ?usize = null,
    active_heading: []const u8 = "",
    balance: Balance = .{},
    done: bool = false,

    pub fn init(source: []const u8) SourceLanguageIterator {
        return .{ .source = source };
    }

    pub fn next(self: *SourceLanguageIterator) ?SourceLanguageSection {
        if (self.done) return null;
        while (self.cursor < self.source.len) {
            const line_start = self.cursor;
            const newline = std.mem.indexOfScalarPos(u8, self.source, line_start, '\n') orelse self.source.len;
            var content_end = newline;
            if (content_end != line_start and self.source[content_end - 1] == '\r') content_end -= 1;
            const line = self.source[line_start..content_end];
            self.cursor = if (newline == self.source.len) self.source.len else newline + 1;

            if (!self.balance.isOpen()) {
                if (parseHeading(line)) |heading| {
                    if (heading.level == 2) {
                        if (self.active_start) |start| {
                            const result: SourceLanguageSection = .{
                                .heading = self.active_heading,
                                .source = self.source[start..line_start],
                            };
                            self.active_start = line_start;
                            self.active_heading = heading.title;
                            return result;
                        }
                        self.active_start = line_start;
                        self.active_heading = heading.title;
                        continue;
                    }
                }
            }
            self.balance.update(line);
        }

        self.done = true;
        if (self.active_start) |start| {
            self.active_start = null;
            return .{ .heading = self.active_heading, .source = self.source[start..] };
        }
        return null;
    }
};

const Balance = struct {
    templates: usize = 0,
    links: usize = 0,
    comments: usize = 0,

    fn update(self: *Balance, line: []const u8) void {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (i + 4 <= line.len and std.mem.eql(u8, line[i .. i + 4], "<!--")) {
                self.comments += 1;
                i += 3;
                continue;
            }
            if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "-->")) {
                if (self.comments != 0) self.comments -= 1;
                i += 2;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "{{")) {
                self.templates += 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "}}")) {
                if (self.templates != 0) self.templates -= 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "[[")) {
                self.links += 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "]]")) {
                if (self.links != 0) self.links -= 1;
                i += 1;
            }
        }
    }

    fn isOpen(self: Balance) bool {
        return self.templates != 0 or self.links != 0 or self.comments != 0;
    }
};

pub const SectionView = struct {
    level: u8,
    title: []const u8,
    raw_title: []const u8,
    raw_body: []const u8,
    language_code: []const u8,

    pub fn content(self: SectionView) []const u8 {
        if (std.mem.startsWith(u8, self.raw_body, "\r\n")) return self.raw_body[2..];
        if (std.mem.startsWith(u8, self.raw_body, "\n")) return self.raw_body[1..];
        return self.raw_body;
    }

    pub fn lineIterator(self: SectionView) LineIterator {
        return .{ .input = self.content() };
    }

    pub fn blockIterator(self: SectionView) BlockIterator {
        return .{ .lines = self.lineIterator() };
    }
};

pub const LineIterator = struct {
    input: []const u8,
    cursor: usize = 0,
    emitted_empty: bool = false,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.input.len == 0) {
            if (self.emitted_empty) return null;
            self.emitted_empty = true;
            return "";
        }
        if (self.cursor >= self.input.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.input, self.cursor, '\n') orelse self.input.len;
        const line = std.mem.trimEnd(u8, self.input[self.cursor..end], "\r");
        self.cursor = if (end == self.input.len) self.input.len else end + 1;
        return line;
    }
};

pub const BlockIterator = struct {
    lines: LineIterator,

    pub fn next(self: *BlockIterator) ?document_ir.DecodedBlock {
        const line = self.lines.next() orelse return null;
        return document_ir.classifyLine(line);
    }
};

pub const SectionIterator = struct {
    encoded: []const u8,
    language: LanguageContext,
    body_start: usize,
    preamble_bytes: []const u8 = "",
    current_level: u8 = 2,
    current_raw_title: []const u8 = "",
    current_title: []const u8 = "",
    done: bool = false,

    pub fn init(encoded: []const u8, language: LanguageContext) error{InvalidEncoding}!SectionIterator {
        if (encoded.len == 0) return error.InvalidEncoding;
        const flags = encoded[0];
        if (flags & ~(flag_custom_language_heading | flag_preamble) != 0) return error.InvalidEncoding;
        var cursor: usize = 1;
        const preamble_bytes = if (flags & flag_preamble != 0) try support.readField(encoded, &cursor) else "";
        if (flags & flag_custom_language_heading != 0) {
            _ = try support.readField(encoded, &cursor);
        }
        return .{
            .encoded = encoded,
            .language = language,
            .body_start = cursor,
            .preamble_bytes = preamble_bytes,
            .current_level = 2,
            .current_raw_title = language.heading,
            .current_title = language.heading,
        };
    }

    pub fn preamble(self: SectionIterator) []const u8 {
        return self.preamble_bytes;
    }

    pub fn next(self: *SectionIterator) error{InvalidEncoding}!?SectionView {
        if (self.done) return null;
        const marker = std.mem.indexOfScalarPos(u8, self.encoded, self.body_start, 0) orelse self.encoded.len;
        const result: SectionView = .{
            .level = self.current_level,
            .title = self.current_title,
            .raw_title = self.current_raw_title,
            .raw_body = self.encoded[self.body_start..marker],
            .language_code = self.language.code,
        };
        if (marker == self.encoded.len) {
            self.done = true;
            return result;
        }

        var cursor = marker + 1;
        if (cursor + 2 > self.encoded.len or self.encoded[cursor] != op_heading) return error.InvalidEncoding;
        cursor += 1;
        const level = self.encoded[cursor];
        cursor += 1;
        if (level < 3 or level > 6) return error.InvalidEncoding;
        const raw_title = try support.readField(self.encoded, &cursor);
        if (raw_title.len == 0) return error.InvalidEncoding;
        self.current_level = level;
        self.current_raw_title = raw_title;
        self.current_title = std.mem.trim(u8, raw_title, " \t");
        if (self.current_title.len == 0) return error.InvalidEncoding;
        self.body_start = cursor;
        return result;
    }
};

const SourceLayout = struct {
    preamble: []const u8,
    section_source: []const u8,
    first_newline: usize,
    first_content_end: usize,
    top: ParsedHeading,
};

fn sourceLayout(source: []const u8, language: LanguageContext) EncodeError!SourceLayout {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidEncoding;
    var source_sections = SourceLanguageIterator.init(source);
    const language_source = source_sections.next() orelse return error.InvalidLanguageSection;
    if (!std.mem.eql(u8, language_source.heading, language.heading) or source_sections.next() != null) return error.InvalidLanguageSection;
    const preamble_len = @intFromPtr(language_source.source.ptr) - @intFromPtr(source.ptr);
    const section_source = language_source.source;
    const first_newline = std.mem.indexOfScalar(u8, section_source, '\n') orelse section_source.len;
    var first_content_end = first_newline;
    if (first_content_end != 0 and section_source[first_content_end - 1] == '\r') first_content_end -= 1;
    const top = parseHeading(section_source[0..first_content_end]) orelse return error.InvalidLanguageSection;
    return .{
        .preamble = source[0..preamble_len],
        .section_source = section_source,
        .first_newline = first_newline,
        .first_content_end = first_content_end,
        .top = top,
    };
}

pub fn encodeAlloc(allocator: std.mem.Allocator, source: []const u8, language: LanguageContext) EncodeError![]u8 {
    const layout = try sourceLayout(source, language);
    const section_source = layout.section_source;
    const first_newline = layout.first_newline;
    const first_content_end = layout.first_content_end;
    const top = layout.top;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const canonical = top.raw_title.len == language.heading.len and std.mem.eql(u8, top.raw_title, language.heading);
    var flags: u8 = if (canonical) 0 else flag_custom_language_heading;
    if (layout.preamble.len != 0) flags |= flag_preamble;
    try out.append(allocator, flags);
    if (layout.preamble.len != 0) try support.appendField(&out, allocator, layout.preamble);
    if (!canonical) try support.appendField(&out, allocator, section_source[0..first_content_end]);

    var segment_start = first_content_end;
    var line_start = if (first_newline == section_source.len) section_source.len else first_newline + 1;
    var balance: Balance = .{};
    while (line_start < section_source.len) {
        const newline = std.mem.indexOfScalarPos(u8, section_source, line_start, '\n') orelse section_source.len;
        var content_end = newline;
        if (content_end != line_start and section_source[content_end - 1] == '\r') content_end -= 1;
        const line = section_source[line_start..content_end];
        if (!balance.isOpen()) {
            if (parseHeading(line)) |heading| {
                if (heading.level >= 3) {
                    try out.appendSlice(allocator, section_source[segment_start..line_start]);
                    try out.append(allocator, 0);
                    try out.append(allocator, op_heading);
                    try out.append(allocator, heading.level);
                    try support.appendField(&out, allocator, heading.raw_title);
                    segment_start = content_end;
                    line_start = if (newline == section_source.len) section_source.len else newline + 1;
                    continue;
                }
            }
        }
        balance.update(line);
        line_start = if (newline == section_source.len) section_source.len else newline + 1;
    }
    try out.appendSlice(allocator, section_source[segment_start..]);
    return out.toOwnedSlice(allocator);
}

// A language payload may consist of one raw body segment, so fallback needs no new tag or format version.
pub fn encodeRawFallbackAlloc(allocator: std.mem.Allocator, source: []const u8, language: LanguageContext) EncodeError![]u8 {
    const layout = try sourceLayout(source, language);
    const canonical = layout.top.raw_title.len == language.heading.len and std.mem.eql(u8, layout.top.raw_title, language.heading);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var flags: u8 = if (canonical) 0 else flag_custom_language_heading;
    if (layout.preamble.len != 0) flags |= flag_preamble;
    try out.append(allocator, flags);
    if (layout.preamble.len != 0) try support.appendField(&out, allocator, layout.preamble);
    if (!canonical) try support.appendField(&out, allocator, layout.section_source[0..layout.first_content_end]);
    try out.appendSlice(allocator, layout.section_source[layout.first_content_end..]);
    return out.toOwnedSlice(allocator);
}

pub fn encodeRobustAlloc(allocator: std.mem.Allocator, source: []const u8, language: LanguageContext) EncodeError![]u8 {
    return encodeAlloc(allocator, source, language) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidEncoding, error.InvalidLanguageSection => encodeRawFallbackAlloc(allocator, source, language),
    };
}

pub fn encodeRepeatedSectionsFallbackAlloc(
    allocator: std.mem.Allocator,
    sections: []const SourceLanguageSection,
    language: LanguageContext,
) EncodeError![]u8 {
    var first: ?SourceLanguageSection = null;
    var extra_len: usize = 0;
    for (sections) |section| {
        if (!std.mem.eql(u8, section.heading, language.heading)) continue;
        if (std.mem.indexOfScalar(u8, section.source, 0) != null) return error.InvalidEncoding;
        if (first == null) {
            first = section;
        } else {
            extra_len = std.math.add(usize, extra_len, section.source.len) catch return error.InvalidEncoding;
        }
    }

    const first_section = first orelse return error.InvalidLanguageSection;
    const encoded = try encodeRobustAlloc(allocator, first_section.source, language);
    if (extra_len == 0) return encoded;
    defer allocator.free(encoded);

    const total_len = std.math.add(usize, encoded.len, extra_len) catch return error.InvalidEncoding;
    const out = try allocator.alloc(u8, total_len);
    @memcpy(out[0..encoded.len], encoded);
    var cursor = encoded.len;
    var skipped_first = false;
    for (sections) |section| {
        if (!std.mem.eql(u8, section.heading, language.heading)) continue;
        if (!skipped_first) {
            skipped_first = true;
            continue;
        }
        @memcpy(out[cursor .. cursor + section.source.len], section.source);
        cursor += section.source.len;
    }
    std.debug.assert(cursor == out.len);
    return out;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8, language: LanguageContext) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    if (encoded.len == 0) return error.InvalidEncoding;
    const flags = encoded[0];
    if (flags & ~(flag_custom_language_heading | flag_preamble) != 0) return error.InvalidEncoding;
    var cursor: usize = 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (flags & flag_preamble != 0) try out.appendSlice(allocator, try support.readField(encoded, &cursor));
    if (flags & flag_custom_language_heading != 0) {
        const heading = try support.readField(encoded, &cursor);
        try out.appendSlice(allocator, heading);
    } else {
        try out.appendSlice(allocator, "==");
        try out.appendSlice(allocator, language.heading);
        try out.appendSlice(allocator, "==");
    }

    while (cursor < encoded.len) {
        const marker = std.mem.indexOfScalarPos(u8, encoded, cursor, 0) orelse encoded.len;
        try out.appendSlice(allocator, encoded[cursor..marker]);
        if (marker == encoded.len) break;
        cursor = marker + 1;
        if (cursor + 2 > encoded.len or encoded[cursor] != op_heading) return error.InvalidEncoding;
        cursor += 1;
        const level = encoded[cursor];
        cursor += 1;
        if (level < 3 or level > 6) return error.InvalidEncoding;
        const raw_title = try support.readField(encoded, &cursor);
        if (raw_title.len == 0) return error.InvalidEncoding;
        try out.appendNTimes(allocator, '=', level);
        try out.appendSlice(allocator, raw_title);
        try out.appendNTimes(allocator, '=', level);
    }
    return out.toOwnedSlice(allocator);
}

fn parseHeading(line: []const u8) ?ParsedHeading {
    if (line.len < 5 or line[0] != '=') return null;
    var left: usize = 0;
    while (left < line.len and line[left] == '=') : (left += 1) {}
    if (left < 2 or left > 6) return null;
    var right = line.len;
    while (right != 0 and line[right - 1] == '=') : (right -= 1) {}
    if (line.len - right != left or right <= left) return null;
    const raw_title = line[left..right];
    const title = std.mem.trim(u8, raw_title, " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(left), .raw_title = raw_title, .title = title };
}

test "source language iterator ignores preamble and nested fake headings" {
    const source = "{{also|cat}}\n==English==\n{{foo|\n==not French==\n}}\n===Noun===\n# cat\n==French==\r\n===Nom===\n# chat\n";
    var it = SourceLanguageIterator.init(source);
    const english = it.next().?;
    try std.testing.expectEqualStrings("English", english.heading);
    try std.testing.expect(std.mem.startsWith(u8, english.source, "==English=="));
    try std.testing.expect(std.mem.indexOf(u8, english.source, "==not French==") != null);
    const french = it.next().?;
    try std.testing.expectEqualStrings("French", french.heading);
    try std.testing.expect(std.mem.startsWith(u8, french.source, "==French=="));
    try std.testing.expect(it.next() == null);
}

test "language blob repeated-section fallback preserves every matching source fragment" {
    const source =
        "==English==\n===Noun===\n# first\n" ++
        "==French==\n===Nom===\n# milieu\n" ++
        "==English==\n===Verb===\n# second\n";
    var it = SourceLanguageIterator.init(source);
    const sections = [_]SourceLanguageSection{ it.next().?, it.next().?, it.next().? };
    try std.testing.expect(it.next() == null);

    const encoded = try encodeRepeatedSectionsFallbackAlloc(std.testing.allocator, &sections, .{ .heading = "English" });
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded, .{ .heading = "English" });
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(
        "==English==\n===Noun===\n# first\n==English==\n===Verb===\n# second\n",
        decoded,
    );
}

test "language blob round trips sections and exposes borrowed blocks" {
    const source = "==English==\n{{wp}}\n\n===Noun===\n{{en-noun}}\n# [[cat]]\n#: A small animal.\n\n====Synonyms====\n* {{l|en|kitty}}\n";
    const language: LanguageContext = .{ .heading = "English", .code = "en" };
    const encoded = try encodeAlloc(std.testing.allocator, source, language);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded, language);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);

    var sections = try SectionIterator.init(encoded, language);
    const root = (try sections.next()).?;
    try std.testing.expectEqual(@as(u8, 2), root.level);
    try std.testing.expectEqualStrings("English", root.title);
    const noun = (try sections.next()).?;
    try std.testing.expectEqualStrings("Noun", noun.title);
    var blocks = noun.blockIterator();
    try std.testing.expectEqual(document_ir.BlockKind.paragraph, blocks.next().?.kind);
    try std.testing.expectEqual(document_ir.BlockKind.definition, blocks.next().?.kind);
    try std.testing.expectEqual(document_ir.BlockKind.example, blocks.next().?.kind);
    const synonyms = (try sections.next()).?;
    try std.testing.expectEqualStrings("Synonyms", synonyms.title);
    try std.testing.expect((try sections.next()) == null);
}

test "language blob preserves reconstruction preamble" {
    const source = "{{reconstructed}}\n{{also|foo}}\n==Proto-Germanic==\n===Etymology===\nFrom foo.\n===Noun===\n# test\n====Descendants====\n* bar\n";
    const language: LanguageContext = .{ .heading = "Proto-Germanic" };
    const encoded = try encodeAlloc(std.testing.allocator, source, language);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded, language);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
    const sections = try SectionIterator.init(encoded, language);
    try std.testing.expectEqualStrings("{{reconstructed}}\n{{also|foo}}\n", sections.preamble());
}

test "language blob derives reconstruction heading from title" {
    try std.testing.expectEqualStrings("Proto-Indo-European", reconstructionHeadingFromTitle("Reconstruction:Proto-Indo-European/h₂ep-").?);
    try std.testing.expectEqualStrings("Old English", reconstructionHeadingFromTitle("Reconstruction:Old English/feortan").?);
    try std.testing.expectEqualStrings("Proto-Germanic", reconstructionHeadingFromTitle("Proto-Germanic/kattuz").?);
    try std.testing.expect(reconstructionHeadingFromTitle("cat") == null);
}

test "language blob preserves custom top heading bytes and multiline template headings" {
    const source = "== English ==\r\n{{foo|\n===not a section===\nbar}}\n===Noun===\n# test\n";
    const language: LanguageContext = .{ .heading = "English", .code = "en" };
    const encoded = try encodeAlloc(std.testing.allocator, source, language);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded, language);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);

    var sections = try SectionIterator.init(encoded, language);
    _ = (try sections.next()).?;
    const noun = (try sections.next()).?;
    try std.testing.expectEqualStrings("Noun", noun.title);
    try std.testing.expect((try sections.next()) == null);
}

test "language raw fallback stays inside existing payload grammar" {
    const source = "{{also|foo}}\n== English ==\r\n===Noun===\n{{broken|\n# still raw\n";
    const language: LanguageContext = .{ .heading = "English" };
    const encoded = try encodeRawFallbackAlloc(std.testing.allocator, source, language);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded, language);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);

    var sections = try SectionIterator.init(encoded, language);
    try std.testing.expectEqualStrings("{{also|foo}}\n", sections.preamble());
    try std.testing.expectEqualStrings("English", (try sections.next()).?.title);
    try std.testing.expect((try sections.next()) == null);
}

test "language splitter emits sections accepted by robust encoder" {
    const alphabet = "{}[]=|*#\n\r<>/ abcXYZ0123456789_:-'\"";
    const prefix = "==English==\n";
    var storage: [384]u8 = undefined;
    var state: u64 = 0x91c4_d38a_2b75_6e10;
    var case_index: usize = 0;
    while (case_index < 1024) : (case_index += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const body_len: usize = @intCast(state % (storage.len - prefix.len));
        @memcpy(storage[0..prefix.len], prefix);
        for (storage[prefix.len .. prefix.len + body_len]) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = alphabet[@intCast(state % alphabet.len)];
        }
        const source = storage[0 .. prefix.len + body_len];
        var it = SourceLanguageIterator.init(source);
        var seen: usize = 0;
        while (it.next()) |section| {
            const language: LanguageContext = .{ .heading = section.heading };
            const encoded = try encodeRobustAlloc(std.testing.allocator, section.source, language);
            const decoded = try decodeAlloc(std.testing.allocator, encoded, language);
            try std.testing.expectEqualStrings(section.source, decoded);
            std.testing.allocator.free(decoded);
            std.testing.allocator.free(encoded);
            seen += 1;
        }
        try std.testing.expect(seen != 0);
    }
}
