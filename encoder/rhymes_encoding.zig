const std = @import("std");
const support = @import("blob_codec_support.zig");

const op_raw: u8 = 0;
const op_blank: u8 = 1;
const op_rhyme_top: u8 = 2;
const op_rhyme_bottom: u8 = 3;
const op_top3: u8 = 4;
const op_top4: u8 = 5;
const op_bottom: u8 = 6;
const op_partrhyme: u8 = 7;
const op_pronunciation: u8 = 8;
const op_rhymes: u8 = 9;
const op_partial_rhymes: u8 = 10;
const op_notes: u8 = 11;
const op_see_also: u8 = 12;
const op_syllable_base: u8 = 13; // one..ten = 13..22
const op_nav: u8 = 23;
const op_link_same: u8 = 24;
const op_link_new: u8 = 25;
const op_link_same_tail: u8 = 26;
const op_link_new_tail: u8 = 27;
const op_link_list_same: u8 = 28;
const op_link_list_new: u8 = 29;
const op_link_list_same_tail: u8 = 30;
const op_link_list_new_tail: u8 = 31;

const tail_raw: u8 = 0;
const tail_qualifier: u8 = 1;
const tail_q: u8 = 2;

const LangRest = struct { language: []const u8, rest: []const u8 };
const LinkLine = struct { language: []const u8, rest: []const u8, tail: []const u8 };
const LinkList = struct { language: []const u8, count: usize, tail: []const u8 };

pub const RecordKind = enum {
    raw_line,
    blank,
    list_boundary,
    heading,
    navigation,
    links,
};

pub const ListBoundary = enum {
    rhyme_top,
    rhyme_bottom,
    top3,
    top4,
    bottom,
    partial_rhyme,
};

pub const Heading = union(enum) {
    pronunciation,
    rhymes,
    partial_rhymes,
    notes,
    see_also,
    syllable: u8,
};

pub const TailKind = enum {
    none,
    raw,
    qualifier,
    q,
};

pub const LinkIterator = struct {
    encoded: []const u8,
    cursor: usize = 0,
    remaining: usize,

    pub fn next(self: *LinkIterator) error{InvalidEncoding}!?[]const u8 {
        if (self.remaining == 0) return null;
        const value = try support.readField(self.encoded, &self.cursor);
        self.remaining -= 1;
        return value;
    }
};

pub const Record = struct {
    kind: RecordKind,
    boundary: ?ListBoundary = null,
    heading: ?Heading = null,
    language: []const u8 = "",
    data: []const u8 = "",
    link_count: usize = 0,
    links_payload: []const u8 = "",
    tail_kind: TailKind = .none,
    tail: []const u8 = "",

    pub fn linkIterator(self: Record) ?LinkIterator {
        if (self.kind != .links) return null;
        return .{ .encoded = self.links_payload, .remaining = self.link_count };
    }
};

pub const Iterator = struct {
    encoded: []const u8,
    cursor: usize = 1,
    current_language: []const u8 = "",
    trailing_newline: bool,

    pub fn init(encoded: []const u8) error{InvalidEncoding}!Iterator {
        if (encoded.len == 0 or encoded[0] & ~support.trailing_newline_flag != 0) return error.InvalidEncoding;
        return .{ .encoded = encoded, .trailing_newline = encoded[0] & support.trailing_newline_flag != 0 };
    }

    pub fn next(self: *Iterator) error{InvalidEncoding}!?Record {
        if (self.cursor >= self.encoded.len) return null;
        const op = self.encoded[self.cursor];
        self.cursor += 1;

        if (boundaryForOpcode(op)) |boundary| return .{ .kind = .list_boundary, .boundary = boundary };
        if (headingForOpcode(op)) |heading| return .{ .kind = .heading, .heading = heading };
        if (op >= op_syllable_base and op < op_syllable_base + syllable_headings.len) {
            return .{ .kind = .heading, .heading = .{ .syllable = @intCast(op - op_syllable_base + 1) } };
        }

        switch (op) {
            op_raw => return .{ .kind = .raw_line, .data = try support.readField(self.encoded, &self.cursor) },
            op_blank => return .{ .kind = .blank },
            op_nav => {
                self.current_language = try support.readField(self.encoded, &self.cursor);
                if (self.current_language.len == 0) return error.InvalidEncoding;
                return .{
                    .kind = .navigation,
                    .language = self.current_language,
                    .data = try support.readField(self.encoded, &self.cursor),
                };
            },
            op_link_same,
            op_link_new,
            op_link_same_tail,
            op_link_new_tail,
            op_link_list_same,
            op_link_list_new,
            op_link_list_same_tail,
            op_link_list_new_tail,
            => {
                const is_list = op == op_link_list_same or op == op_link_list_new or op == op_link_list_same_tail or op == op_link_list_new_tail;
                const is_new = op == op_link_new or op == op_link_new_tail or op == op_link_list_new or op == op_link_list_new_tail;
                const has_tail = op == op_link_same_tail or op == op_link_new_tail or op == op_link_list_same_tail or op == op_link_list_new_tail;
                if (is_new) {
                    self.current_language = try support.readField(self.encoded, &self.cursor);
                    if (self.current_language.len == 0) return error.InvalidEncoding;
                } else if (self.current_language.len == 0) return error.InvalidEncoding;

                const count: usize = if (is_list) try support.readVarUInt(self.encoded, &self.cursor) else 1;
                if (count == 0 or (is_list and count < 2)) return error.InvalidEncoding;
                const items_start = self.cursor;
                var index: usize = 0;
                while (index < count) : (index += 1) _ = try support.readField(self.encoded, &self.cursor);
                const items_end = self.cursor;
                var record: Record = .{
                    .kind = .links,
                    .language = self.current_language,
                    .link_count = count,
                    .links_payload = self.encoded[items_start..items_end],
                };
                if (has_tail) try readTail(self, &record);
                return record;
            },
            else => return error.InvalidEncoding,
        }
    }

    fn readTail(self: *Iterator, record: *Record) error{InvalidEncoding}!void {
        if (self.cursor >= self.encoded.len) return error.InvalidEncoding;
        const kind = self.encoded[self.cursor];
        self.cursor += 1;
        record.tail_kind = switch (kind) {
            tail_raw => .raw,
            tail_qualifier => .qualifier,
            tail_q => .q,
            else => return error.InvalidEncoding,
        };
        record.tail = try support.readField(self.encoded, &self.cursor);
    }
};

pub fn iterator(encoded: []const u8) error{InvalidEncoding}!Iterator {
    return Iterator.init(encoded);
}

pub fn encodeAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const trailing_newline = source.len != 0 and source[source.len - 1] == '\n';
    try out.append(allocator, if (trailing_newline) support.trailing_newline_flag else 0);

    var current_language: []const u8 = "";
    var pos: usize = 0;
    while (pos < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
        try appendLine(&out, allocator, source[pos..end], &current_language);
        if (end == source.len) break;
        pos = end + 1;
        if (pos == source.len) break;
    }
    return out.toOwnedSlice(allocator);
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8, current_language: *[]const u8) !void {
    if (line.len == 0) return out.append(allocator, op_blank);
    if (fixedOpcode(line)) |op| return out.append(allocator, op);
    if (syllableHeadingIndex(line)) |index| return out.append(allocator, op_syllable_base + index);

    if (exactTemplateArgs(line, "rhymes nav")) |args| {
        if (splitLanguageRest(args)) |parsed| {
            try out.append(allocator, op_nav);
            try support.appendField(out, allocator, parsed.language);
            try support.appendField(out, allocator, parsed.rest);
            current_language.* = parsed.language;
            return;
        }
    }
    if (parseLinkList(line)) |list| {
        const same = current_language.*.len != 0 and std.mem.eql(u8, current_language.*, list.language);
        const has_tail = list.tail.len != 0;
        try out.append(allocator, if (same)
            (if (has_tail) op_link_list_same_tail else op_link_list_same)
        else
            (if (has_tail) op_link_list_new_tail else op_link_list_new));
        if (!same) {
            try support.appendField(out, allocator, list.language);
            current_language.* = list.language;
        }
        try support.appendVarUInt(out, allocator, list.count);
        var pos: usize = 2;
        var emitted: usize = 0;
        while (emitted < list.count) : (emitted += 1) {
            const close = support.findBalancedTemplateEnd(line, pos) orelse unreachable;
            const args = line[pos + 4 .. close];
            const parsed = splitLanguageRest(args) orelse unreachable;
            try support.appendField(out, allocator, parsed.rest);
            pos = close + 2;
            if (emitted + 1 < list.count) pos += 2;
        }
        if (has_tail) try appendLinkTail(out, allocator, list.tail);
        return;
    }
    if (parseLinkLine(line)) |parsed| {
        const same = current_language.*.len != 0 and std.mem.eql(u8, current_language.*, parsed.language);
        const has_tail = parsed.tail.len != 0;
        try out.append(allocator, if (same)
            (if (has_tail) op_link_same_tail else op_link_same)
        else
            (if (has_tail) op_link_new_tail else op_link_new));
        if (!same) {
            try support.appendField(out, allocator, parsed.language);
            current_language.* = parsed.language;
        }
        try support.appendField(out, allocator, parsed.rest);
        if (has_tail) try appendLinkTail(out, allocator, parsed.tail);
        return;
    }

    try out.append(allocator, op_raw);
    try support.appendField(out, allocator, line);
}

fn appendLinkTail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tail: []const u8) !void {
    if (exactTailTemplateArgs(tail, "qualifier")) |args| {
        try out.append(allocator, tail_qualifier);
        return support.appendField(out, allocator, args);
    }
    if (exactTailTemplateArgs(tail, "q")) |args| {
        try out.append(allocator, tail_q);
        return support.appendField(out, allocator, args);
    }
    try out.append(allocator, tail_raw);
    try support.appendField(out, allocator, tail);
}

fn exactTailTemplateArgs(tail: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, tail, " {{")) return null;
    const start: usize = 1;
    const close = support.findBalancedTemplateEnd(tail, start) orelse return null;
    if (close + 2 != tail.len) return null;
    const template = tail[start .. close + 2];
    return exactTemplateArgs(template, name);
}

fn fixedOpcode(line: []const u8) ?u8 {
    if (std.mem.eql(u8, line, "{{rhyme-top}}")) return op_rhyme_top;
    if (std.mem.eql(u8, line, "{{rhyme-bottom}}")) return op_rhyme_bottom;
    if (std.mem.eql(u8, line, "{{top3}}")) return op_top3;
    if (std.mem.eql(u8, line, "{{top4}}")) return op_top4;
    if (std.mem.eql(u8, line, "{{bottom}}")) return op_bottom;
    if (std.mem.eql(u8, line, "{{partrhyme}}")) return op_partrhyme;
    if (std.mem.eql(u8, line, "==Pronunciation==")) return op_pronunciation;
    if (std.mem.eql(u8, line, "==Rhymes==")) return op_rhymes;
    if (std.mem.eql(u8, line, "==Partial rhymes==")) return op_partial_rhymes;
    if (std.mem.eql(u8, line, "===Notes===")) return op_notes;
    if (std.mem.eql(u8, line, "====See also====")) return op_see_also;
    return null;
}

const syllable_headings = [_][]const u8{
    "===One syllable===",  "===Two syllables===",   "===Three syllables===", "===Four syllables===", "===Five syllables===",
    "===Six syllables===", "===Seven syllables===", "===Eight syllables===", "===Nine syllables===", "===Ten syllables===",
};

fn syllableHeadingIndex(line: []const u8) ?u8 {
    for (syllable_headings, 0..) |heading, index| if (std.mem.eql(u8, line, heading)) return @intCast(index);
    return null;
}

fn exactTemplateArgs(line: []const u8, name: []const u8) ?[]const u8 {
    if (line.len < name.len + 5 or !std.mem.startsWith(u8, line, "{{")) return null;
    const close = support.findBalancedTemplateEnd(line, 0) orelse return null;
    if (close + 2 != line.len) return null;
    if (!std.mem.eql(u8, line[2 .. 2 + name.len], name)) return null;
    const separator = 2 + name.len;
    if (separator >= close or line[separator] != '|') return null;
    return line[separator + 1 .. close];
}

fn splitLanguageRest(args: []const u8) ?LangRest {
    const separator = std.mem.indexOfScalar(u8, args, '|') orelse return null;
    if (separator == 0) return null;
    return .{ .language = args[0..separator], .rest = args[separator + 1 ..] };
}

fn parseLinkList(line: []const u8) ?LinkList {
    if (!std.mem.startsWith(u8, line, "* {{l|")) return null;
    var language: []const u8 = "";
    var count: usize = 0;
    var pos: usize = 2;
    while (pos < line.len and std.mem.startsWith(u8, line[pos..], "{{l|")) {
        const close = support.findBalancedTemplateEnd(line, pos) orelse return null;
        if (close < pos + 5) return null;
        const args = line[pos + 4 .. close];
        const parsed = splitLanguageRest(args) orelse return null;
        if (count == 0) language = parsed.language else if (!std.mem.eql(u8, language, parsed.language)) return null;
        count += 1;
        pos = close + 2;
        if (std.mem.startsWith(u8, line[pos..], ", {{l|")) {
            pos += 2;
            continue;
        }
        break;
    }
    if (count < 2) return null;
    return .{ .language = language, .count = count, .tail = line[pos..] };
}

fn parseLinkLine(line: []const u8) ?LinkLine {
    if (!std.mem.startsWith(u8, line, "* {{l|")) return null;
    const start: usize = 2;
    const close = support.findBalancedTemplateEnd(line, start) orelse return null;
    if (close < start + 5) return null;
    const template = line[start .. close + 2];
    if (!std.mem.startsWith(u8, template, "{{l|")) return null;
    const args = template[4 .. template.len - 2];
    const parsed = splitLanguageRest(args) orelse return null;
    return .{ .language = parsed.language, .rest = parsed.rest, .tail = line[close + 2 ..] };
}

fn boundaryForOpcode(op: u8) ?ListBoundary {
    return switch (op) {
        op_rhyme_top => .rhyme_top,
        op_rhyme_bottom => .rhyme_bottom,
        op_top3 => .top3,
        op_top4 => .top4,
        op_bottom => .bottom,
        op_partrhyme => .partial_rhyme,
        else => null,
    };
}

fn headingForOpcode(op: u8) ?Heading {
    return switch (op) {
        op_pronunciation => .pronunciation,
        op_rhymes => .rhymes,
        op_partial_rhymes => .partial_rhymes,
        op_notes => .notes,
        op_see_also => .see_also,
        else => null,
    };
}

fn fixedLine(op: u8) ?[]const u8 {
    return switch (op) {
        op_rhyme_top => "{{rhyme-top}}",
        op_rhyme_bottom => "{{rhyme-bottom}}",
        op_top3 => "{{top3}}",
        op_top4 => "{{top4}}",
        op_bottom => "{{bottom}}",
        op_partrhyme => "{{partrhyme}}",
        op_pronunciation => "==Pronunciation==",
        op_rhymes => "==Rhymes==",
        op_partial_rhymes => "==Partial rhymes==",
        op_notes => "===Notes===",
        op_see_also => "====See also====",
        else => null,
    };
}

pub fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) (std.mem.Allocator.Error || error{InvalidEncoding})![]u8 {
    if (encoded.len == 0 or encoded[0] & ~support.trailing_newline_flag != 0) return error.InvalidEncoding;
    const trailing_newline = encoded[0] & support.trailing_newline_flag != 0;
    var cursor: usize = 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var current_language: ?[]const u8 = null;
    var first = true;

    while (cursor < encoded.len) {
        if (!first) try out.append(allocator, '\n');
        first = false;
        const op = encoded[cursor];
        cursor += 1;
        if (fixedLine(op)) |line| {
            try out.appendSlice(allocator, line);
            continue;
        }
        if (op >= op_syllable_base and op < op_syllable_base + syllable_headings.len) {
            try out.appendSlice(allocator, syllable_headings[op - op_syllable_base]);
            continue;
        }
        switch (op) {
            op_raw => try support.appendFieldTo(&out, allocator, encoded, &cursor),
            op_blank => {},
            op_nav => {
                const language = try support.readField(encoded, &cursor);
                current_language = language;
                try out.appendSlice(allocator, "{{rhymes nav|");
                try out.appendSlice(allocator, language);
                try out.append(allocator, '|');
                try support.appendFieldTo(&out, allocator, encoded, &cursor);
                try out.appendSlice(allocator, "}}");
            },
            op_link_list_same, op_link_list_new, op_link_list_same_tail, op_link_list_new_tail => {
                const is_new = op == op_link_list_new or op == op_link_list_new_tail;
                const has_tail = op == op_link_list_same_tail or op == op_link_list_new_tail;
                if (is_new) {
                    current_language = try support.readField(encoded, &cursor);
                } else if (current_language == null) return error.InvalidEncoding;
                const count = try support.readVarUInt(encoded, &cursor);
                if (count < 2) return error.InvalidEncoding;
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    if (index == 0) try out.appendSlice(allocator, "* ") else try out.appendSlice(allocator, ", ");
                    try out.appendSlice(allocator, "{{l|");
                    try out.appendSlice(allocator, current_language.?);
                    try out.append(allocator, '|');
                    try support.appendFieldTo(&out, allocator, encoded, &cursor);
                    try out.appendSlice(allocator, "}}");
                }
                if (has_tail) try appendDecodedLinkTail(&out, allocator, encoded, &cursor);
            },
            op_link_same, op_link_new, op_link_same_tail, op_link_new_tail => {
                const is_new = op == op_link_new or op == op_link_new_tail;
                const has_tail = op == op_link_same_tail or op == op_link_new_tail;
                if (is_new) {
                    current_language = try support.readField(encoded, &cursor);
                } else if (current_language == null) return error.InvalidEncoding;
                try out.appendSlice(allocator, "* {{l|");
                try out.appendSlice(allocator, current_language.?);
                try out.append(allocator, '|');
                try support.appendFieldTo(&out, allocator, encoded, &cursor);
                try out.appendSlice(allocator, "}}");
                if (has_tail) try appendDecodedLinkTail(&out, allocator, encoded, &cursor);
            },
            else => return error.InvalidEncoding,
        }
    }
    if (trailing_newline) try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn appendDecodedLinkTail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, encoded: []const u8, cursor: *usize) (std.mem.Allocator.Error || error{InvalidEncoding})!void {
    if (cursor.* >= encoded.len) return error.InvalidEncoding;
    const kind = encoded[cursor.*];
    cursor.* += 1;
    switch (kind) {
        tail_raw => try support.appendFieldTo(out, allocator, encoded, cursor),
        tail_qualifier, tail_q => {
            try out.appendSlice(allocator, " {{");
            try out.appendSlice(allocator, if (kind == tail_q) "q|" else "qualifier|");
            try support.appendFieldTo(out, allocator, encoded, cursor);
            try out.appendSlice(allocator, "}}");
        },
        else => return error.InvalidEncoding,
    }
}

test "rhymes payload round trips canonical lists with qualifiers" {
    const source =
        \\{{rhymes nav|en|æ|t}}
        \\
        \\==Pronunciation==
        \\{{enPR|-ăt}}, {{IPA|en|/-æt/}}
        \\
        \\==Rhymes==
        \\===One syllable===
        \\{{rhyme-top}}
        \\* {{l|en|at}} {{qualifier|when stressed}}
        \\* {{l|en|bat}}
        \\{{rhyme-bottom}}
        \\
    ;
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "rhymes payload compacts repeated same-language link lists" {
    const source = "* {{l|en|gram}}, {{l|en|gramme}} {{q|one pronunciation}}\n";
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "rhymes iterator exposes headings and borrowed link groups" {
    const source = "{{rhymes nav|en|æ|m}}\n==Rhymes==\n===One syllable===\n{{rhyme-top}}\n* {{l|en|gram}}, {{l|en|gramme}} {{q|one pronunciation}}\n{{rhyme-bottom}}\n";
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    var it = try iterator(encoded);
    try std.testing.expect(it.trailing_newline);
    const nav = (try it.next()).?;
    try std.testing.expectEqual(RecordKind.navigation, nav.kind);
    try std.testing.expectEqualStrings("en", nav.language);
    try std.testing.expectEqualStrings("æ|m", nav.data);
    try std.testing.expectEqual(Heading.rhymes, (try it.next()).?.heading.?);
    const syllable = (try it.next()).?.heading.?;
    try std.testing.expectEqual(@as(u8, 1), syllable.syllable);
    try std.testing.expectEqual(ListBoundary.rhyme_top, (try it.next()).?.boundary.?);
    const links = (try it.next()).?;
    try std.testing.expectEqual(@as(usize, 2), links.link_count);
    try std.testing.expectEqual(TailKind.q, links.tail_kind);
    try std.testing.expectEqualStrings("one pronunciation", links.tail);
    var link_it = links.linkIterator().?;
    try std.testing.expectEqualStrings("gram", (try link_it.next()).?);
    try std.testing.expectEqualStrings("gramme", (try link_it.next()).?);
    try std.testing.expect((try link_it.next()) == null);
    try std.testing.expectEqual(ListBoundary.rhyme_bottom, (try it.next()).?.boundary.?);
    try std.testing.expect((try it.next()) == null);
}

test "rhymes payload changes language only on explicit link language" {
    const source = "* {{l|en|cat}}\n* {{l|fr|chat|g=m}}\n* {{l|fr|rat}}\n";
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}
