const std = @import("std");
const support = @import("blob_codec_support.zig");

const op_raw: u8 = 0;
const op_blank: u8 = 1;
const op_ws_beginlist: u8 = 2;
const op_ws_endlist: u8 = 3;
const op_synonyms: u8 = 4;
const op_antonyms: u8 = 5;
const op_hypernyms: u8 = 6;
const op_hyponyms: u8 = 7;
const op_meronyms: u8 = 8;
const op_holonyms: u8 = 9;
const op_troponyms: u8 = 10;
const op_various: u8 = 11;
const op_ws_header: u8 = 12;
const op_ws_same_language: u8 = 13;
const op_ws_new_language: u8 = 14;
const op_ws_sense_same_language: u8 = 15;
const op_ws_sense_new_language: u8 = 16;
const op_ws_topic_same_language: u8 = 17;
const op_ws_topic_new_language: u8 = 18;
const op_ws_same_language_tail: u8 = 19;
const op_ws_new_language_tail: u8 = 20;
const op_ws_header_empty: u8 = 21;

const tail_raw: u8 = 0;
const tail_qualifier: u8 = 1;
const tail_q: u8 = 2;
const tail_plural_q: u8 = 3;
const tail_plural_qualifier: u8 = 4;
const tail_s: u8 = 5;

const LangRest = struct { language: []const u8, rest: []const u8 };
const WsLine = struct { language: []const u8, rest: []const u8, tail: []const u8 };

pub const RecordKind = enum {
    raw_line,
    blank,
    list_begin,
    list_end,
    relation,
    header,
    term,
    sense,
    topic,
};

pub const Relation = enum {
    synonyms,
    antonyms,
    hypernyms,
    hyponyms,
    meronyms,
    holonyms,
    troponyms,
    various,
};

pub const TailKind = enum {
    none,
    raw,
    qualifier,
    q,
    plural_q,
    plural_qualifier,
    plural_s,
};

pub const Record = struct {
    kind: RecordKind,
    relation: ?Relation = null,
    language: []const u8 = "",
    data: []const u8 = "",
    tail_kind: TailKind = .none,
    tail: []const u8 = "",
};

pub const Iterator = struct {
    encoded: []const u8,
    cursor: usize = 1,
    current_language: []const u8 = "",
    trailing_newline: bool,

    pub fn init(encoded: []const u8) error{InvalidEncoding}!Iterator {
        if (encoded.len == 0 or encoded[0] & ~support.trailing_newline_flag != 0) return error.InvalidEncoding;
        return .{
            .encoded = encoded,
            .trailing_newline = encoded[0] & support.trailing_newline_flag != 0,
        };
    }

    pub fn next(self: *Iterator) error{InvalidEncoding}!?Record {
        if (self.cursor >= self.encoded.len) return null;
        const op = self.encoded[self.cursor];
        self.cursor += 1;

        if (relationForOpcode(op)) |relation| return .{ .kind = .relation, .relation = relation };
        switch (op) {
            op_raw => return .{ .kind = .raw_line, .data = try support.readField(self.encoded, &self.cursor) },
            op_blank => return .{ .kind = .blank },
            op_ws_beginlist => return .{ .kind = .list_begin },
            op_ws_endlist => return .{ .kind = .list_end },
            op_ws_header_empty => return .{ .kind = .header },
            op_ws_header => return .{ .kind = .header, .data = try support.readField(self.encoded, &self.cursor) },
            op_ws_same_language,
            op_ws_new_language,
            op_ws_sense_same_language,
            op_ws_sense_new_language,
            op_ws_topic_same_language,
            op_ws_topic_new_language,
            op_ws_same_language_tail,
            op_ws_new_language_tail,
            => {
                const is_new = op == op_ws_new_language or op == op_ws_sense_new_language or op == op_ws_topic_new_language or op == op_ws_new_language_tail;
                if (is_new) {
                    self.current_language = try support.readField(self.encoded, &self.cursor);
                    if (self.current_language.len == 0) return error.InvalidEncoding;
                } else if (self.current_language.len == 0) {
                    return error.InvalidEncoding;
                }
                var record: Record = .{
                    .kind = if (op == op_ws_sense_same_language or op == op_ws_sense_new_language)
                        .sense
                    else if (op == op_ws_topic_same_language or op == op_ws_topic_new_language)
                        .topic
                    else
                        .term,
                    .language = self.current_language,
                    .data = try support.readField(self.encoded, &self.cursor),
                };
                if (op == op_ws_same_language_tail or op == op_ws_new_language_tail) try readTail(self, &record);
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
            tail_plural_q => .plural_q,
            tail_plural_qualifier => .plural_qualifier,
            tail_s => .plural_s,
            else => return error.InvalidEncoding,
        };
        if (record.tail_kind != .plural_s) record.tail = try support.readField(self.encoded, &self.cursor);
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
        const line = source[pos..end];
        try appendLine(&out, allocator, line, &current_language);
        if (end == source.len) break;
        pos = end + 1;
        if (pos == source.len) break;
    }
    return out.toOwnedSlice(allocator);
}

fn appendLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    current_language: *[]const u8,
) !void {
    if (line.len == 0) return out.append(allocator, op_blank);
    if (std.mem.eql(u8, line, "{{ws beginlist}}")) return out.append(allocator, op_ws_beginlist);
    if (std.mem.eql(u8, line, "{{ws endlist}}")) return out.append(allocator, op_ws_endlist);
    if (std.mem.eql(u8, line, "{{ws header}}")) return out.append(allocator, op_ws_header_empty);
    if (knownHeadingOpcode(line)) |op| return out.append(allocator, op);

    if (exactTemplateArgs(line, "ws header")) |args| {
        try out.append(allocator, op_ws_header);
        return support.appendField(out, allocator, args);
    }
    if (exactTemplateArgs(line, "ws topic")) |args| {
        if (splitLanguageRest(args)) |parsed| {
            return appendLanguageRecord(out, allocator, parsed, current_language, op_ws_topic_same_language, op_ws_topic_new_language);
        }
    }
    if (parseWsLine(line)) |parsed| {
        const same = current_language.*.len != 0 and std.mem.eql(u8, current_language.*, parsed.language);
        const has_tail = parsed.tail.len != 0;
        try out.append(allocator, if (same)
            (if (has_tail) op_ws_same_language_tail else op_ws_same_language)
        else
            (if (has_tail) op_ws_new_language_tail else op_ws_new_language));
        if (!same) {
            try support.appendField(out, allocator, parsed.language);
            current_language.* = parsed.language;
        }
        try support.appendField(out, allocator, parsed.rest);
        if (has_tail) try appendWsTail(out, allocator, parsed.tail);
        return;
    }
    if (line.len >= 12 and std.mem.startsWith(u8, line, "===={{ws sense|") and std.mem.endsWith(u8, line, "}}====")) {
        const inner = line[4 .. line.len - 4];
        if (exactTemplateArgs(inner, "ws sense")) |args| {
            if (splitLanguageRest(args)) |parsed| {
                return appendLanguageRecord(out, allocator, parsed, current_language, op_ws_sense_same_language, op_ws_sense_new_language);
            }
        }
    }

    try out.append(allocator, op_raw);
    try support.appendField(out, allocator, line);
}

fn appendLanguageRecord(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parsed: LangRest,
    current_language: *[]const u8,
    same_opcode: u8,
    new_opcode: u8,
) !void {
    if (current_language.*.len != 0 and std.mem.eql(u8, current_language.*, parsed.language)) {
        try out.append(allocator, same_opcode);
    } else {
        try out.append(allocator, new_opcode);
        try support.appendField(out, allocator, parsed.language);
        current_language.* = parsed.language;
    }
    try support.appendField(out, allocator, parsed.rest);
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

fn appendWsTail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tail: []const u8) !void {
    if (exactTailTemplateArgs(tail, " ", "qualifier")) |args| {
        try out.append(allocator, tail_qualifier);
        return support.appendField(out, allocator, args);
    }
    if (exactTailTemplateArgs(tail, " ", "q")) |args| {
        try out.append(allocator, tail_q);
        return support.appendField(out, allocator, args);
    }
    if (exactTailTemplateArgs(tail, "s ", "q")) |args| {
        try out.append(allocator, tail_plural_q);
        return support.appendField(out, allocator, args);
    }
    if (exactTailTemplateArgs(tail, "s ", "qualifier")) |args| {
        try out.append(allocator, tail_plural_qualifier);
        return support.appendField(out, allocator, args);
    }
    if (std.mem.eql(u8, tail, "s")) return out.append(allocator, tail_s);
    try out.append(allocator, tail_raw);
    try support.appendField(out, allocator, tail);
}

fn exactTailTemplateArgs(tail: []const u8, prefix: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, tail, prefix)) return null;
    const start = prefix.len;
    if (start >= tail.len or !std.mem.startsWith(u8, tail[start..], "{{")) return null;
    const close = support.findBalancedTemplateEnd(tail, start) orelse return null;
    if (close + 2 != tail.len) return null;
    const template = tail[start .. close + 2];
    return exactTemplateArgs(template, name);
}

fn parseWsLine(line: []const u8) ?WsLine {
    if (!std.mem.startsWith(u8, line, "{{ws|")) return null;
    const close = support.findBalancedTemplateEnd(line, 0) orelse return null;
    if (close < 5) return null;
    const args = line[5..close];
    const parsed = splitLanguageRest(args) orelse return null;
    return .{ .language = parsed.language, .rest = parsed.rest, .tail = line[close + 2 ..] };
}

fn splitLanguageRest(args: []const u8) ?LangRest {
    const separator = std.mem.indexOfScalar(u8, args, '|') orelse return null;
    if (separator == 0) return null;
    return .{ .language = args[0..separator], .rest = args[separator + 1 ..] };
}

fn knownHeadingOpcode(line: []const u8) ?u8 {
    if (std.mem.eql(u8, line, "=====Synonyms=====")) return op_synonyms;
    if (std.mem.eql(u8, line, "=====Antonyms=====")) return op_antonyms;
    if (std.mem.eql(u8, line, "=====Hypernyms=====")) return op_hypernyms;
    if (std.mem.eql(u8, line, "=====Hyponyms=====")) return op_hyponyms;
    if (std.mem.eql(u8, line, "=====Meronyms=====")) return op_meronyms;
    if (std.mem.eql(u8, line, "=====Holonyms=====")) return op_holonyms;
    if (std.mem.eql(u8, line, "=====Troponyms=====")) return op_troponyms;
    if (std.mem.eql(u8, line, "=====Various=====")) return op_various;
    return null;
}

fn relationForOpcode(op: u8) ?Relation {
    return switch (op) {
        op_synonyms => .synonyms,
        op_antonyms => .antonyms,
        op_hypernyms => .hypernyms,
        op_hyponyms => .hyponyms,
        op_meronyms => .meronyms,
        op_holonyms => .holonyms,
        op_troponyms => .troponyms,
        op_various => .various,
        else => null,
    };
}

fn knownHeadingForOpcode(op: u8) ?[]const u8 {
    return switch (op) {
        op_synonyms => "=====Synonyms=====",
        op_antonyms => "=====Antonyms=====",
        op_hypernyms => "=====Hypernyms=====",
        op_hyponyms => "=====Hyponyms=====",
        op_meronyms => "=====Meronyms=====",
        op_holonyms => "=====Holonyms=====",
        op_troponyms => "=====Troponyms=====",
        op_various => "=====Various=====",
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
        if (knownHeadingForOpcode(op)) |heading| {
            try out.appendSlice(allocator, heading);
            continue;
        }
        switch (op) {
            op_raw => try support.appendFieldTo(&out, allocator, encoded, &cursor),
            op_blank => {},
            op_ws_beginlist => try out.appendSlice(allocator, "{{ws beginlist}}"),
            op_ws_endlist => try out.appendSlice(allocator, "{{ws endlist}}"),
            op_ws_header_empty => try out.appendSlice(allocator, "{{ws header}}"),
            op_ws_header => {
                try out.appendSlice(allocator, "{{ws header|");
                try support.appendFieldTo(&out, allocator, encoded, &cursor);
                try out.appendSlice(allocator, "}}");
            },
            op_ws_same_language,
            op_ws_new_language,
            op_ws_sense_same_language,
            op_ws_sense_new_language,
            op_ws_topic_same_language,
            op_ws_topic_new_language,
            op_ws_same_language_tail,
            op_ws_new_language_tail,
            => {
                const is_new = op == op_ws_new_language or op == op_ws_sense_new_language or op == op_ws_topic_new_language or op == op_ws_new_language_tail;
                const has_tail = op == op_ws_same_language_tail or op == op_ws_new_language_tail;
                if (is_new) {
                    current_language = try support.readField(encoded, &cursor);
                } else if (current_language == null) {
                    return error.InvalidEncoding;
                }
                const language = current_language.?;
                if (op == op_ws_sense_same_language or op == op_ws_sense_new_language) {
                    try out.appendSlice(allocator, "===={{ws sense|");
                } else if (op == op_ws_topic_same_language or op == op_ws_topic_new_language) {
                    try out.appendSlice(allocator, "{{ws topic|");
                } else {
                    try out.appendSlice(allocator, "{{ws|");
                }
                try out.appendSlice(allocator, language);
                try out.append(allocator, '|');
                try support.appendFieldTo(&out, allocator, encoded, &cursor);
                try out.appendSlice(allocator, if (op == op_ws_sense_same_language or op == op_ws_sense_new_language) "}}====" else "}}");
                if (has_tail) try appendDecodedWsTail(&out, allocator, encoded, &cursor);
            },
            else => return error.InvalidEncoding,
        }
    }
    if (trailing_newline) try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn appendDecodedWsTail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, encoded: []const u8, cursor: *usize) (std.mem.Allocator.Error || error{InvalidEncoding})!void {
    if (cursor.* >= encoded.len) return error.InvalidEncoding;
    const kind = encoded[cursor.*];
    cursor.* += 1;
    switch (kind) {
        tail_raw => try support.appendFieldTo(out, allocator, encoded, cursor),
        tail_qualifier, tail_q, tail_plural_q, tail_plural_qualifier => {
            if (kind == tail_plural_q or kind == tail_plural_qualifier) try out.append(allocator, 's');
            try out.appendSlice(allocator, " {{");
            try out.appendSlice(allocator, if (kind == tail_q or kind == tail_plural_q) "q|" else "qualifier|");
            try support.appendFieldTo(out, allocator, encoded, cursor);
            try out.appendSlice(allocator, "}}");
        },
        tail_s => try out.append(allocator, 's'),
        else => return error.InvalidEncoding,
    }
}

test "thesaurus payload round trips structured ws lists with raw fallback" {
    const source =
        \\{{ws header|worship}}
        \\==English==
        \\===Noun===
        \\===={{ws sense|en|devotion accorded to a deity}}====
        \\=====Synonyms=====
        \\{{ws beginlist}}
        \\{{ws|en|praise}}
        \\{{ws|en|worship|q=rare}}
        \\{{ws endlist}}
        \\{{ws topic|en|Religion}}
        \\* {{R:Roget 1911|worship|990}}
        \\
    ;
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "thesaurus iterator exposes frontend-neutral borrowed records" {
    const source = "{{ws header|worship}}\n=====Synonyms=====\n{{ws beginlist}}\n{{ws|en|praise}}\n{{ws|en|honour}} {{q|formal}}\n{{ws endlist}}\n";
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    var it = try iterator(encoded);
    try std.testing.expect(it.trailing_newline);
    try std.testing.expectEqual(RecordKind.header, (try it.next()).?.kind);
    const relation = (try it.next()).?;
    try std.testing.expectEqual(RecordKind.relation, relation.kind);
    try std.testing.expectEqual(Relation.synonyms, relation.relation.?);
    try std.testing.expectEqual(RecordKind.list_begin, (try it.next()).?.kind);
    const first = (try it.next()).?;
    try std.testing.expectEqual(RecordKind.term, first.kind);
    try std.testing.expectEqualStrings("en", first.language);
    try std.testing.expectEqualStrings("praise", first.data);
    const second = (try it.next()).?;
    try std.testing.expectEqual(TailKind.q, second.tail_kind);
    try std.testing.expectEqualStrings("formal", second.tail);
    try std.testing.expectEqual(RecordKind.list_end, (try it.next()).?.kind);
    try std.testing.expect((try it.next()) == null);
}

test "thesaurus payload preserves redirect pages through raw records" {
    const source = "#REDIRECT [[Wikisaurus:copulation]]\n";
    const encoded = try encodeAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "thesaurus unsupported syntax always round trips through raw records" {
    const alphabet = "{}[]=|*#\n\r<>/ abcXYZ0123456789_:-'\"";
    var storage: [320]u8 = undefined;
    var state: u64 = 0x52ab_7041_ee39_c618;
    var case_index: usize = 0;
    while (case_index < 2048) : (case_index += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const len: usize = @intCast(state % storage.len);
        for (storage[0..len]) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = alphabet[@intCast(state % alphabet.len)];
        }
        const source = storage[0..len];
        const encoded = try encodeAlloc(std.testing.allocator, source);
        const decoded = try decodeAlloc(std.testing.allocator, encoded);
        try std.testing.expectEqualStrings(source, decoded);
        std.testing.allocator.free(decoded);
        std.testing.allocator.free(encoded);
    }
}
