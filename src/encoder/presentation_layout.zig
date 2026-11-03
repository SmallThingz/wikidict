//! Build-time reading-order analysis. Every source section/block remains addressable; no
//! homonyms are merged and supporting material stays attached to its own sense.
const std = @import("std");
const part = @import("blob_encoder").part_kind;
const wiki = @import("presentation_compile.zig");
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
    // Retained ocwiki Modèl:-vèrb- p1133/r309551 and -flex-verb- p2910/r50049.
    // A form heading is not evidence for a particular lemma or inflection relation.
    if (std.mem.eql(u8, title, "Vèrb")) return "Verb";
    if (std.mem.eql(u8, title, "Forma de vèrb")) return "Verb form";
    // Exact emitted KBD template p21/r212 label; its positional code is unused.
    // The named value is the uppercase noun term documented at this revision:
    // https://en.wiktionary.org/w/index.php?title=щыӏэцӏэ&oldid=89577699
    // Match this complete label only, without changing section titles or bodies.
    if (std.mem.eql(u8, title, "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ")) return "Noun";
    for (speech) |name| if (part.named(title, name)) return name;
    return null;
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
    const no_sense = std.math.maxInt(usize);
    var stack: [256]usize = undefined;
    var stack_len: usize = 1;
    for (blocks, 0..) |block, b| {
        var depth: usize = 0;
        for (block.list_path) |c| {
            if (c != '#') break;
            depth += 1;
        }
        depth = @min(depth, stack.len - 1);
        if (block.kind == .definition) {
            depth = @max(1, depth);
            if (depth >= stack_len) @memset(stack[stack_len..depth], no_sense);
            var parent: ?usize = null;
            var d = depth;
            while (d > 1) {
                d -= 1;
                if (stack[d] != no_sense) {
                    parent = stack[d];
                    break;
                }
            }
            stack[depth] = pending.items.len;
            stack_len = depth + 1;
            try pending.append(a, .{ .value = .{ .block = b, .parent = parent, .form = null } });
        } else if (depth != 0 and depth < stack_len and stack[depth] != no_sense and block.kind != .blank) {
            const owner = &pending.items[stack[depth]];
            if (block.kind == .example and !block.relation_note) try owner.examples.append(a, b) else if (block.kind == .quotation) try owner.quotations.append(a, b) else try owner.notes.append(a, b);
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
    return buildInContext(a, sections, false, null);
}
/// A synthetic unresolved owner supplies no evidence that an L2 term label is
/// a language boundary or a part of speech. Keep nested POS structure, but do
/// not turn those unverified boundary labels into language grouping metadata.
pub fn buildUnclassified(a: A, sections: anytype) !Layout {
    return buildInContext(a, sections, true, null);
}
/// The caller has already classified and split this single-owner record.
/// Section labels retain structure but cannot reclassify its lexeme language.
pub fn buildOwned(a: A, sections: anytype, owner: []const u8) !Layout {
    return buildInContext(a, sections, false, owner);
}
fn buildInContext(a: A, sections: anytype, unclassified: bool, owner: ?[]const u8) !Layout {
    var lexemes: std.ArrayList(Lexeme) = .empty;
    var other: std.ArrayList(usize) = .empty;
    var origin: ?usize = null;
    var current_language: []const u8 = owner orelse "";
    var active: ?usize = null;
    var related: std.ArrayList(usize) = .empty;
    for (sections, 0..) |section, i| {
        const kind = if (unclassified and section.level == 2) null else partOfSpeech(section.title);
        // Modèl:-etim- p1091/r219080 emits this exact localized heading.
        const etymology = part.named(section.title, "Etymology") or std.mem.eql(u8, section.title, "Etimologia");
        // Owned records can contain several H1 source regions. A recognized H2
        // POS belongs to the preceding etymology, but a new region cannot inherit it.
        if (owner != null and section.level == 1) origin = null;
        if (section.level == 2) {
            if (owner == null or kind == null) origin = null;
            if (owner == null and !unclassified and kind == null and !etymology) current_language = section.title;
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

test "sense ownership skips missing depths and invalidates stale deeper owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "English", .level = 2 },
        .{ .title = "Noun", .level = 3, .blocks = &.{
            .{ .kind = .definition, .list_path = "#" },
            .{ .kind = .definition, .list_path = "###" },
            .{ .kind = .example, .list_path = "###:" },
            .{ .kind = .definition, .list_path = "##" },
            .{ .kind = .example, .list_path = "###:" },
            .{ .kind = .definition, .list_path = "#" },
            .{ .kind = .example, .list_path = "##:" },
        } },
    };
    const layout = try build(a, &sections);
    const senses = layout.lexemes[0].definitions;
    try std.testing.expectEqual(@as(usize, 4), senses.len);
    try std.testing.expectEqual(@as(?usize, 0), senses[1].parent);
    try std.testing.expectEqualSlices(usize, &.{2}, senses[1].examples);
    try std.testing.expectEqual(@as(?usize, 0), senses[2].parent);
    try std.testing.expectEqual(@as(?usize, null), senses[3].parent);
    try std.testing.expectEqualSlices(usize, &.{ 4, 6 }, layout.lexemes[0].other_blocks);
}

test "renderer relation hints feed layout without reparsing source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "cat", .language = "English" } };
    const blocks = try renderer.renderBody("# A feline.\n#: <span class='nyms'>Synonyms: kitty</span>\n#: An ordinary example.\n");
    try std.testing.expect(blocks[1].relation_note);
    try std.testing.expect(!blocks[2].relation_note);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{ .{ .title = "English", .level = 2 }, .{ .title = "Noun", .level = 3, .blocks = blocks } };
    const layout = try build(a, &sections);
    try std.testing.expect(layout.lexemes[0].definitions[0].form == null);
    try std.testing.expectEqualSlices(usize, &.{2}, layout.lexemes[0].definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{1}, layout.lexemes[0].definitions[0].notes);
}

test "unclassified term boundaries do not invent language or POS but retain nested structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Unclassified", .level = 2 },
        .{ .title = "count", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "counter", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "country code", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Noun", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const layout = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    try std.testing.expectEqualStrings("Noun", layout.lexemes[0].kind);
    try std.testing.expectEqualStrings("", layout.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 4), layout.lexemes[0].section);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, layout.other_sections);
    // Existing callers keep their explicit-owner/monolingual L2 POS behavior.
    const existing = try build(a, &sections);
    try std.testing.expectEqual(@as(usize, 2), existing.lexemes.len);
    try std.testing.expectEqualStrings("Counter", existing.lexemes[0].kind);
}


test "classified layout owner survives support labels without changing lexical structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Hausa", .level = 2 }, .{ .title = "Suna", .level = 2 },
        .{ .title = "Noun", .level = 3 }, .{ .title = "Unknown support", .level = 2 },
        .{ .title = "Verb", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const owned = try buildOwned(a, &sections, "Hausa");
    const legacy = try build(a, &sections);
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 2), owned.lexemes.len);
    for (owned.lexemes, legacy.lexemes, unresolved.lexemes) |actual, prior, unknown| {
        try std.testing.expectEqualStrings("Hausa", actual.language);
        try std.testing.expectEqualStrings("", unknown.language);
        var expected = prior; expected.language = "Hausa";
        try std.testing.expectEqualDeep(expected, actual);
    }
    try std.testing.expectEqualStrings("Suna", legacy.lexemes[0].language);
    try std.testing.expectEqualStrings("Unknown support", legacy.lexemes[1].language);
    try std.testing.expectEqualDeep(legacy.other_sections, owned.other_sections);
}
// Append to src/encoder/presentation_layout.zig in a private source only.
test "KBD exact localized noun heading preserves owner and descendant section evidence" {
    const title = "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ";
    try std.testing.expectEqualStrings("Noun", partOfSpeech(title).?);
    for ([_][]const u8{ "ЩЫӀЭЦӀЭ", "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: щыӏэцӏэ", "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ 2", "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: UNKNOWN", "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ:  ЩЫӀЭЦӀЭ" }) |other|
        try std.testing.expect(partOfSpeech(other) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)", .level = 2 },
        .{ .title = title, .level = 3 },
        .{ .title = "МЫХЬЭНЭ", .level = 4, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "ЩАПХЪЭХЭР", .level = 4, .blocks = &.{.{ .kind = .list_item, .list_path = "*" }} },
    };
    const owned = try buildOwned(a, &sections, "record-owner");
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes.len);
    try std.testing.expectEqualStrings("Noun", owned.lexemes[0].kind);
    try std.testing.expectEqualStrings("record-owner", owned.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes[0].section);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, owned.lexemes[0].related_sections);
    // Existing layout keeps descendant blocks addressable; it does not relocate
    // their definitions into the POS section's direct-block sense list.
    try std.testing.expectEqual(@as(usize, 0), owned.lexemes[0].definitions.len);
    try std.testing.expectEqualStrings(title, sections[1].title);
    try std.testing.expect(sections[2].blocks[0].kind == .definition);
    const unknown = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unknown.lexemes.len);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
}


test "OC exact verb and verb-form layout retains owned etymology and region boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Occitan", .level = 1 },
        .{ .title = "Etimologia", .level = 3, .blocks = &.{.{ .kind = .paragraph }} },
        .{ .title = "Prononciacion", .level = 3 },
        .{ .title = "Vèrb", .level = 2, .blocks = &.{
            .{ .kind = .paragraph }, .{ .kind = .definition, .list_path = "#" },
            .{ .kind = .example, .list_path = "#:" },
        } },
        .{ .title = "Conjugason", .level = 3, .blocks = &.{.{ .kind = .paragraph }} },
        // A later same-owner source region without etymology must not inherit it.
        .{ .title = "Occitan", .level = 1 },
        .{ .title = "Forma de vèrb", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Etimologia", .level = 3 },
        .{ .title = "Vèrb", .level = 2 },
        // An unknown L2 remains a boundary; it cannot extend etymology scope.
        .{ .title = "Unknown", .level = 2 },
        .{ .title = "Vèrb", .level = 2 },
    };
    const layout = try buildOwned(a, &sections, "Declared owner");
    try std.testing.expectEqual(@as(usize, 4), layout.lexemes.len);
    const verb = layout.lexemes[0];
    try std.testing.expectEqualStrings("Verb", verb.kind);
    try std.testing.expectEqual(@as(usize, 3), verb.section);
    try std.testing.expectEqual(@as(?usize, 1), verb.etymology);
    try std.testing.expectEqualSlices(usize, &.{0}, verb.introduction);
    try std.testing.expectEqual(@as(usize, 1), verb.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), verb.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, verb.definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{4}, verb.related_sections);
    const form = layout.lexemes[1];
    try std.testing.expectEqualStrings("Verb form", form.kind);
    try std.testing.expectEqualStrings("Forma de vèrb", sections[form.section].title);
    try std.testing.expect(form.etymology == null);
    try std.testing.expectEqual(@as(usize, 1), form.definitions.len);
    try std.testing.expect(form.definitions[0].form == null);
    try std.testing.expectEqual(@as(?usize, 7), layout.lexemes[2].etymology);
    try std.testing.expect(layout.lexemes[3].etymology == null);
    for (layout.lexemes) |lexeme| try std.testing.expectEqualStrings("Declared owner", lexeme.language);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 5, 7, 9 }, layout.other_sections);
}

test "OC localized labels do not infer unresolved owner or broaden matching and legacy scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "vèrb", "Vèrb 2", "Forma de vèrb 2", "Forma de vèrb extra", "Prefix Vèrb" }) |title|
        try std.testing.expect(partOfSpeech(title) == null);
    try std.testing.expectEqualStrings("Verb", partOfSpeech("Verb").?);
    try std.testing.expectEqualStrings("Verb", partOfSpeech("VERB").?);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "English", .level = 1 },
        .{ .title = "Etymology", .level = 3 },
        .{ .title = "Verb", .level = 2 },
        .{ .title = "Etimologia", .level = 3 },
        .{ .title = "Forma de vèrb", .level = 2 },
    };
    const legacy = try build(a, &sections);
    try std.testing.expectEqual(@as(usize, 2), legacy.lexemes.len);
    for (legacy.lexemes) |lexeme| try std.testing.expect(lexeme.etymology == null);
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 0), unresolved.lexemes.len);
    const owned = try buildOwned(a, &sections, "English");
    try std.testing.expectEqual(@as(?usize, 1), owned.lexemes[0].etymology);
    try std.testing.expectEqual(@as(?usize, 3), owned.lexemes[1].etymology);
    // Protected text is blocks, not an admitted heading; layout cannot promote it.
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "test", .language = "English" } };
    const blocks = try renderer.renderBody("<nowiki>==Vèrb==</nowiki>\n<pre>==Forma de vèrb==</pre>\n");
    const protected = [_]Section{.{ .title = "Notes", .level = 3, .blocks = blocks }};
    const literal = try buildOwned(a, &protected, "English");
    try std.testing.expectEqual(@as(usize, 0), literal.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, literal.other_sections);
}
