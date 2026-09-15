//! Runtime-only reading order. Every source section/block remains addressable; no
//! homonyms are merged and supporting material stays attached to its own sense.
const std = @import("std");
const ir = @import("blob_encoder").document_ir;
const syntax = @import("blob_encoder").wikitext_syntax;
const part = @import("blob_encoder").language_parts.kinds;
const wiki = @import("wikitext.zig");
const A = std.mem.Allocator;
pub const Form = struct { relation: []const u8, target: []const u8, language: []const u8 };
pub const Sense = struct {
    block: usize,
    parent: ?usize = null,
    examples: []const usize = &.{},
    quotations: []const usize = &.{},
    notes: []const usize = &.{},
    form: ?Form = null,
};
pub const Lexeme = struct {
    language: []const u8 = "",
    kind: []const u8,
    section: usize,
    etymology: ?usize = null,
    definitions: []const Sense,
    introduction: []const usize,
    other_blocks: []const usize,
    related_sections: []const usize = &.{},
};
pub const Layout = struct { lexemes: []const Lexeme = &.{}, other_sections: []const usize = &.{} };
const speech = [_][]const u8{
    "Adjective",    "Adverb",         "Ambiposition",  "Article",  "Circumposition", "Classifier", "Conjunction", "Contraction",      "Counter", "Determiner", "Ideophone", "Interjection",     "Noun",     "Numeral", "Participle", "Particle", "Postposition",         "Preposition",   "Pronoun", "Proper noun", "Verb",
    "Circumfix",    "Combining form", "Infix",         "Interfix", "Prefix",         "Root",       "Suffix",      "Diacritical mark", "Letter",  "Ligature",   "Number",    "Punctuation mark", "Syllable", "Symbol",  "Phrase",     "Proverb",  "Prepositional phrase", "Han character", "Hanzi",   "Kanji",       "Hanja",
    "Romanization", "Logogram",       "Determinative",
};
pub fn partOfSpeech(title: []const u8) ?[]const u8 {
    for (speech) |name| if (part.named(title, name)) return name;
    return null;
}
fn formOf(a: A, block: wiki.Block) !?Form {
    var it: ir.InlineIterator = .{ .input = block.text };
    while (it.next()) |span| if (span.kind == .template) {
        const t = syntax.Template.parse(a, span.text) catch |err| switch (err) {
            error.RenderLimit => continue,
            else => return err,
        };
        const relation: []const u8 = if (std.ascii.eqlIgnoreCase(t.name, "plural of")) "plural" else if (std.ascii.eqlIgnoreCase(t.name, "past participle of")) "past participle" else if (std.ascii.eqlIgnoreCase(t.name, "present participle of")) "present participle" else if (std.ascii.eqlIgnoreCase(t.name, "past of") or std.ascii.eqlIgnoreCase(t.name, "simple past of")) "past tense" else if ((std.ascii.eqlIgnoreCase(t.name, "infl of") or std.ascii.eqlIgnoreCase(t.name, "inflection of")) and std.mem.eql(u8, t.get(4), "s-verb-form") and t.last() == 4) "third-person singular present" else continue;
        if (t.get(2).len != 0) return .{ .relation = relation, .target = t.get(2), .language = t.get(1) };
    };
    return null;
}
fn isRelationNote(block: wiki.Block) bool {
    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, block.text, position, '<')) |start| {
        const tag = syntax.tagAt(block.text, start) orelse {
            position = start + 1;
            continue;
        };
        position = tag.end;
        if (tag.attr("class")) |classes| {
            var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");
            while (tokens.next()) |name| if (std.mem.eql(u8, name, "nyms")) return true;
        }
    }

    var it: ir.InlineIterator = .{ .input = block.text };
    while (it.next()) |span| if (span.kind == .template) {
        for ([_][]const u8{ "syn", "synonyms", "ant", "antonyms", "hyper", "hypernyms", "hypo", "hyponyms", "meronyms", "holonyms", "coordinate terms", "cot", "see", "senseid", "senseno" }) |name| if (std.ascii.eqlIgnoreCase(span.target, name)) return true;
    };
    return false;
}
const PendingSense = struct {
    value: Sense,
    examples: std.ArrayList(usize) = .empty,
    quotations: std.ArrayList(usize) = .empty,
    notes: std.ArrayList(usize) = .empty,
};
fn analyze(a: A, kind: []const u8, index: usize, etymology: ?usize, blocks: []const wiki.Block) !Lexeme {
    var pending: std.ArrayList(PendingSense) = .empty;
    var intro: std.ArrayList(usize) = .empty;
    var other: std.ArrayList(usize) = .empty;
    var stack: [256]?usize = @splat(null);
    for (blocks, 0..) |block, b| {
        var depth: usize = 0;
        for (block.list_path) |c| {
            if (c != '#') break;
            depth += 1;
        }
        depth = @min(depth, stack.len - 1);
        if (block.kind == .definition) {
            depth = @max(1, depth);
            var parent: ?usize = null;
            var d = depth;
            while (d > 1) {
                d -= 1;
                if (stack[d]) |s| {
                    parent = s;
                    break;
                }
            }
            stack[depth] = pending.items.len;
            @memset(stack[depth + 1 ..], null);
            try pending.append(a, .{ .value = .{ .block = b, .parent = parent, .form = try formOf(a, block) } });
        } else if (depth != 0 and stack[depth] != null and block.kind != .blank) {
            const owner = &pending.items[stack[depth].?];
            if (block.kind == .example and !isRelationNote(block)) try owner.examples.append(a, b) else if (block.kind == .quotation) try owner.quotations.append(a, b) else try owner.notes.append(a, b);
        } else if (pending.items.len == 0) try intro.append(a, b) else try other.append(a, b);
    }
    const senses = try a.alloc(Sense, pending.items.len);
    for (pending.items, senses) |*p, *s| {
        s.* = p.value;
        s.examples = try p.examples.toOwnedSlice(a);
        s.quotations = try p.quotations.toOwnedSlice(a);
        s.notes = try p.notes.toOwnedSlice(a);
    }
    return .{ .kind = kind, .section = index, .etymology = etymology, .definitions = senses, .introduction = try intro.toOwnedSlice(a), .other_blocks = try other.toOwnedSlice(a) };
}
/// Uses the entry arena. The result only refers to existing semantic source sections.
pub fn build(a: A, sections: anytype) !Layout {
    var lexemes: std.ArrayList(Lexeme) = .empty;
    var other: std.ArrayList(usize) = .empty;
    var origin: ?usize = null;
    var current_language: []const u8 = "";
    var active: ?usize = null;
    var related: std.ArrayList(usize) = .empty;
    for (sections, 0..) |section, i| {
        const kind = partOfSpeech(section.title);
        const etymology = part.named(section.title, "Etymology");
        if (section.level == 2) {
            origin = null;
            if (kind == null and !etymology) current_language = section.title;
        }
        if (active) |previous| {
            const parent = sections[lexemes.items[previous].section];
            if (kind == null and !etymology and section.level > parent.level) {
                try related.append(a, i);
                continue;
            }
            lexemes.items[previous].related_sections = try related.toOwnedSlice(a);
            active = null;
        }
        if (etymology) origin = i;
        if (kind) |name| {
            active = lexemes.items.len;
            var lexical = try analyze(a, name, i, origin, section.blocks);
            lexical.language = current_language;
            try lexemes.append(a, lexical);
        } else try other.append(a, i);
    }
    if (active) |previous| lexemes.items[previous].related_sections = try related.toOwnedSlice(a);
    return .{ .lexemes = try lexemes.toOwnedSlice(a), .other_sections = try other.toOwnedSlice(a) };
}
test "lexemes keep homonyms and nested sense evidence separate without losing blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "English", .level = 2 },      .{ .title = "Etymology 1", .level = 3 },
        .{ .title = "Noun", .level = 4, .blocks = &.{
            .{ .kind = .paragraph },                  .{ .kind = .definition, .list_path = "#" },  .{ .kind = .definition, .list_path = "##" },
            .{ .kind = .example, .list_path = "#:" }, .{ .kind = .quotation, .list_path = "##*" }, .{ .kind = .paragraph },
        } },
        .{ .title = "Translations", .level = 5 }, .{ .title = "Verb", .level = 4 },
        .{ .title = "Etymology 2", .level = 3 },  .{ .title = "Noun", .level = 4 },
        .{ .title = "Odd notes", .level = 3 },
    };
    const result = try build(a, &sections);
    try std.testing.expectEqual(@as(usize, 3), result.lexemes.len);
    const noun = result.lexemes[0];
    try std.testing.expectEqual(@as(?usize, 1), noun.etymology);
    try std.testing.expectEqual(@as(?usize, 0), noun.definitions[1].parent);
    try std.testing.expectEqualSlices(usize, &.{3}, noun.definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{4}, noun.definitions[1].quotations);
    try std.testing.expectEqualSlices(usize, &.{5}, noun.other_blocks);
    try std.testing.expectEqualSlices(usize, &.{3}, noun.related_sections);
    try std.testing.expectEqual(@as(?usize, 5), result.lexemes[2].etymology);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 5, 7 }, result.other_sections);
}

test "oversized definition template cannot fail lexeme analysis after renderer fallback" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "{{plural of|en|cat");
    for (0..16_385) |_| try source.appendSlice(a, "|x");
    try source.appendSlice(a, "}}");
    const block_value: wiki.Block = .{ .kind = .definition, .text = source.items, .spans = &.{}, .list_path = "#" };
    try std.testing.expect((try formOf(a, block_value)) == null);
}
