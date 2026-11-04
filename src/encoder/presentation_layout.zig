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
    // UG سۆز p4182/r21944 selects ئىسىملار p4204/r21121's default label.
    // ئىسىم (grammar noun): en.wiktionary.org/w/index.php?title=ئىسىم&oldid=86381152.
    // Section kind only; preserve the independently established record owner.
    if (std.mem.eql(u8, title, "ئومۇمىي ئىسىم")) return "Noun";
    // Exact ZGH heading-template p3117/r9844 labels (alias p3119/r9214).
    // IRCAM, Vocabulaire grammatical, English index pp103/119:
    // https://biblio.ircam.ma/pmb/uploads/publications/134.pdf
    // Section kind only: the caller retains its independently established owner.
    if (std.mem.eql(u8, title, "ⵉⵙⵎ")) return "Noun";
    if (std.mem.eql(u8, title, "ⴰⵎⵔⵏⵓ")) return "Adverb";
    // Retained MAD -subjudul- p9327/r34033 maps v/adj to these exact labels;
    // -v- p9330/r33638 and -adj- p9331/r33639 document verba/adjektiva.
    // Classify POS only; language ownership remains supplied by the caller.
    if (std.mem.eql(u8, title, "Oca' lako")) return "Verb";
    if (std.mem.eql(u8, title, "Oca' sèpat")) return "Adjective";
    // MY Module:headword/data p127525/r939704 explicitly labels this as noun;
    // all six retained MY noun sections use this exact spelling.
    if (std.mem.eql(u8, title, "နာမ်")) return "Noun";
    // Exact BR heading terms; Office public de la langue bretonne, Meurgorf:
    // https://niverel.brezhoneg.bzh/fr/meurgorf/1727 (substantif)
    // https://niverel.brezhoneg.bzh/fr/meurgorf/1722 (adjectif)
    // POS only: preserve the supplied owner, original title and sense relations.
    if (std.mem.eql(u8, title, "Anv-kadarn")) return "Noun";
    if (std.mem.eql(u8, title, "Anv-gwan")) return "Adjective";
    // Exact observed TL POS label; primary entry explicitly translates it as noun:
    // https://tl.wiktionary.org/w/index.php?title=pangngalan&oldid=150530
    // This classifies a section only; the caller still supplies any language owner.
    if (std.mem.eql(u8, title, "Pangngalan")) return "Noun";
    // Retained ocwiki Modèl:-vèrb- p1133/r309551 and -flex-verb- p2910/r50049.
    // A form heading is not evidence for a particular lemma or inflection relation.
    if (std.mem.eql(u8, title, "Vèrb")) return "Verb";
    if (std.mem.eql(u8, title, "Forma de vèrb")) return "Verb form";
    // Exact emitted KBD template p21/r212 label; its positional code is unused.
    // The named value is the uppercase noun term documented at this revision:
    // https://en.wiktionary.org/w/index.php?title=щыӏэцӏэ&oldid=89577699
    // Match this complete label only, without changing section titles or bodies.
    if (std.mem.eql(u8, title, "ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ")) return "Noun";
    // AST sustantivu p50071/r309486 emits this exact common-noun heading.
    // Its language argument supplies categories, not record ownership.
    // Preserve the owner established independently by the caller.
    if (std.mem.eql(u8, title, "Sustantivu")) return "Noun";
    // FO -navnorð- p1586/r24229 emits this label; -noun- p2673/r7800
    // redirects to that template. Classify POS without supplying an owner.
    if (std.mem.eql(u8, title, "Navnorð")) return "Noun";
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
        // Exact MY source heading for inherited/derived material in retained
        // p2617/r939601 and origin statements in p122417/r905431,p124492/r907881.
        // BR Patrom:-etim- p1929/r381015 emits Gerdarzh (Orin hag istor),
        // called by laezh-glas p46208/r382620 and reoliek p46674/r238569.
        const etymology = part.named(section.title, "Etymology") or std.mem.eql(u8, section.title, "Etimologia") or std.mem.eql(u8, section.title, "ရင်းမြစ်") or std.mem.eql(u8, section.title, "Gerdarzh");
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


test "Pangngalan layout retains an independently owned noun and exact source associations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "abaka", .language = "Declared owner" } };
    const blocks = try renderer.renderBody("'''abaka'''\n# A [[fiber|fiber]] meaning.\n#: An ''example''.\n# Another meaning.\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Declared owner", .level = 2 },
        .{ .title = "Pangngalan", .level = 3, .blocks = blocks },
        .{ .title = "Mga salin", .level = 4 },
        .{ .title = "Regional vocabulary", .level = 2 },
    };
    const layout = try buildOwned(a, &sections, "Declared owner");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Declared owner", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqualStrings("Pangngalan", sections[noun.section].title);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].examples.len);
    try std.testing.expectEqualSlices(usize, &.{2}, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    for (noun.definitions) |sense| {
        try std.testing.expect(sense.block < blocks.len);
        try std.testing.expect(blocks[sense.block].kind == .definition);
        try std.testing.expect(sense.form == null);
        for (sense.examples) |example| try std.testing.expect(blocks[example].kind == .example);
    }
    // The localized POS name cannot supply or override the entry language.
    const other_owner = try buildOwned(a, &sections, "A different independently declared owner");
    try std.testing.expectEqualStrings("A different independently declared owner", other_owner.lexemes[0].language);
    try std.testing.expectEqual(noun.section, other_owner.lexemes[0].section);
    try std.testing.expectEqualDeep(noun.definitions, other_owner.lexemes[0].definitions);
}

test "Pangngalan layout rejects lookalikes and does not promote an unknown language boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "pangngalan", "PANGNGALAN", "Pangngalan 2", "Pangngalang pantangi", "Unknown Pangngalan", "Regional vocabulary" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Unclassified", .level = 2 },
        .{ .title = "Pangngalan", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Regional vocabulary", .level = 2 },
        .{ .title = "Pangngalan", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const unresolved = try buildUnclassified(a, &sections);
    // Existing policy retains nested POS structure with an unknown owner; it
    // does not turn the unverified L2 label into a language or a second noun.
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqual(@as(usize, 3), unresolved.lexemes[0].section);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, unresolved.other_sections);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "test" } };
    const protected_blocks = try renderer.renderBody("<nowiki>===Pangngalan===</nowiki>\n<pre>===Pangngalan===</pre>\n");
    const protected = [_]Section{.{ .title = "Notes", .level = 3, .blocks = protected_blocks }};
    const literal = try buildOwned(a, &protected, "Declared owner");
    try std.testing.expectEqual(@as(usize, 0), literal.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, literal.other_sections);
}


test "Breton exact noun and adjective headings preserve independent owner and sense associations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control", .language = "Declared owner" } };
    const noun_blocks = try renderer.renderBody("'''laezh-glas'''\n# [[laezh-bihan|Laezh-bihan]]\n#* ''First quotation.''\n#* ''Second quotation.''\n");
    const adjective_blocks = try renderer.renderBody("'''reoliek'''\n# [[ordinal|Ordinal]].\n#* ''First quotation.''\n# A second [[rule|rule]].\n#* ''Second quotation.''\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Declared owner", .level = 2 },
        .{ .title = "Anv-kadarn", .level = 3, .blocks = noun_blocks },
        .{ .title = "Translations", .level = 4 },
        .{ .title = "Anv-gwan", .level = 3, .blocks = adjective_blocks },
        .{ .title = "Related terms", .level = 4 },
        .{ .title = "Unknown boundary", .level = 2 },
    };
    const layout = try buildOwned(a, &sections, "Declared owner");
    try std.testing.expectEqual(@as(usize, 2), layout.lexemes.len);
    const noun = layout.lexemes[0];
    const adjective = layout.lexemes[1];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Adjective", adjective.kind);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 3), adjective.section);
    try std.testing.expectEqualStrings("Anv-kadarn", sections[noun.section].title);
    try std.testing.expectEqualStrings("Anv-gwan", sections[adjective.section].title);
    try std.testing.expectEqualSlices(usize, &.{2}, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{4}, adjective.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 5 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions[0].quotations.len);
    try std.testing.expectEqual(@as(usize, 2), adjective.definitions.len);
    for (adjective.definitions) |sense| try std.testing.expectEqual(@as(usize, 1), sense.quotations.len);
    for (layout.lexemes) |lexeme| {
        try std.testing.expectEqualStrings("Declared owner", lexeme.language);
        const blocks = sections[lexeme.section].blocks;
        for (lexeme.definitions) |sense| {
            try std.testing.expect(sense.form == null);
            try std.testing.expect(blocks[sense.block].kind == .definition);
            for (sense.quotations) |quote| try std.testing.expect(blocks[quote].kind == .quotation);
        }
    }
    const different = try buildOwned(a, &sections, "Another declared owner");
    for (different.lexemes, layout.lexemes) |actual, expected| {
        try std.testing.expectEqualStrings("Another declared owner", actual.language);
        try std.testing.expectEqualDeep(expected.definitions, actual.definitions);
        try std.testing.expectEqual(expected.section, actual.section);
    }
}

test "Breton POS labels do not create language ownership or promote protected and unknown headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "anv-kadarn", "ANV-KADARN", "Anv-kadarn 2", "Anv-gwan 2", "Anv-gwan-verb", "Anv", "Regional vocabulary", "furm lies kuzh-heol." }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
    try std.testing.expectEqualStrings("Adjective", partOfSpeech("Adjective").?);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Unclassified", .level = 2 },
        .{ .title = "Anv-kadarn", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Regional vocabulary", .level = 2 },
        .{ .title = "Anv-gwan", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqual(@as(usize, 3), unresolved.lexemes[0].section);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    try std.testing.expectEqualStrings("Adjective", unresolved.lexemes[0].kind);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, unresolved.other_sections);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const blocks = try renderer.renderBody("<nowiki>===Anv-kadarn===</nowiki>\n<pre>===Anv-gwan===</pre>\n# furm lies kuzh-heol.\n");
    const protected = [_]Section{.{ .title = "Notes", .level = 3, .blocks = blocks }};
    const layout = try buildOwned(a, &protected, "Declared owner");
    try std.testing.expectEqual(@as(usize, 0), layout.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, layout.other_sections);
}

test "MY exact noun and etymology labels preserve supplied owner senses examples and reference boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "အထမ်းသမား", .language = "မြန်မာ" } };
    const blocks = try renderer.renderBody("'''အထမ်းသမား'''\n# ဝန်ကိုပခုံးဖြင့်သယ်ဆောင်သူ။\n#: ကူလီအထမ်းသမား စာပို့သမား။\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "မြန်မာ", .level = 2 },
        .{ .title = "ရင်းမြစ်", .level = 3 },
        .{ .title = "အသံထွက်", .level = 3 },
        .{ .title = "နာမ်", .level = 3, .blocks = blocks },
        .{ .title = "အရေအတွက်", .level = 4 },
        .{ .title = "ဘာသာပြန်", .level = 3 },
        .{ .title = "ကိုးကား", .level = 2 },
        .{ .title = "နာမ်", .level = 3, .blocks = blocks },
    };
    const layout = try buildOwned(a, &sections, "ru"); // Label must not impose my ownership.
    try std.testing.expectEqual(@as(usize, 2), layout.lexemes.len);
    const first = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", first.kind);
    try std.testing.expectEqualStrings("ru", first.language);
    try std.testing.expectEqual(@as(usize, 3), first.section);
    try std.testing.expectEqual(@as(?usize, 1), first.etymology);
    try std.testing.expectEqual(@as(usize, 1), first.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{2}, first.definitions[0].examples);
    try std.testing.expect(first.definitions[0].form == null);
    try std.testing.expectEqualSlices(usize, &.{4}, first.related_sections);
    try std.testing.expectEqualSlices(usize, &.{0}, first.introduction);
    try std.testing.expectEqual(@as(?usize, null), layout.lexemes[1].etymology);
    try std.testing.expectEqualStrings("ru", layout.lexemes[1].language);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 5, 6 }, layout.other_sections);
    try std.testing.expectEqualStrings("နာမ်", sections[3].title);
    try std.testing.expectEqualStrings("ကိုးကား", sections[6].title);
}

test "MY layout labels stay exact and cannot create owner or lexicalize protected body text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "နာမ်များ", "နာမ် ", "Unknown နာမ်", "ရင်းမြစ်", "ကိုးကား" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const protected = try renderer.renderBody("<nowiki>===နာမ်===</nowiki>\n<nowiki>===ရင်းမြစ်===</nowiki>\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const no_headings = [_]Section{.{ .title = "", .level = 0, .blocks = protected }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &no_headings, "my")).lexemes.len);
    const unresolved = [_]Section{
        .{ .title = "နာမ်", .level = 2 },
        .{ .title = "ရင်းမြစ်", .level = 3 },
        .{ .title = "နာမ်", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const unknown = try buildUnclassified(a, &unresolved);
    try std.testing.expectEqual(@as(usize, 1), unknown.lexemes.len);
    try std.testing.expectEqual(@as(usize, 2), unknown.lexemes[0].section);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
    try std.testing.expectEqual(@as(?usize, 1), unknown.lexemes[0].etymology);
    const ordinary = [_]Section{ .{ .title = "Etymology", .level = 3 }, .{ .title = "Noun", .level = 3 } };
    const existing = try buildOwned(a, &ordinary, "en");
    try std.testing.expectEqualStrings("Noun", existing.lexemes[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), existing.lexemes[0].etymology);
}

test "MAD exact source POS labels preserve supplied owner and sibling body boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "lèjhâ'", .language = "mad" } };
    const body = try renderer.renderBody("#akalèjhâ'\n");
    const example = try renderer.renderBody("# Alhamdulilla, kocèngnga ghi' aka'''lèjhâ'''', Nom.\n");
    const reference = try renderer.renderBody("Pawitra, Adrian. Kamus Lengkap Bahasa Madura Indonesia. 2009. hal. 366.\n");
    const body_before = try a.dupe(wiki.Block, body);
    const example_before = try a.dupe(wiki.Block, example);
    const reference_before = try a.dupe(wiki.Block, reference);
    // The retained page puts the gloss and example in sibling sections.
    // A POS mapping must not invent a relation across those boundaries.
    const sections = [_]Section{
        .{ .title = "Bhâsa Madhurâ", .level = 2 },
        .{ .title = "Oca' sèpat", .level = 3 },
        .{ .title = "Lèjhâ'", .level = 3, .blocks = body },
        .{ .title = "Conto", .level = 3, .blocks = example },
        .{ .title = "Sombher", .level = 2, .blocks = reference },
        .{ .title = "Oca' lako", .level = 3 },
    };
    for ([_][]const u8{ "mad", "en" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 2), layout.lexemes.len);
        try std.testing.expectEqualStrings("Adjective", layout.lexemes[0].kind);
        try std.testing.expectEqualStrings("Verb", layout.lexemes[1].kind);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes[0].section);
        try std.testing.expectEqual(@as(usize, 5), layout.lexemes[1].section);
        for (layout.lexemes) |lexeme| {
            try std.testing.expectEqualStrings(owner, lexeme.language);
            try std.testing.expectEqual(@as(usize, 0), lexeme.definitions.len);
            try std.testing.expectEqual(@as(?usize, null), lexeme.etymology);
        }
        try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3, 4 }, layout.other_sections);
    }
    try std.testing.expectEqualStrings("Oca' sèpat", sections[1].title);
    try std.testing.expectEqualStrings("Oca' lako", sections[5].title);
    try std.testing.expectEqualDeep(body_before, sections[2].blocks);
    try std.testing.expectEqualDeep(example_before, sections[3].blocks);
    try std.testing.expectEqualDeep(reference_before, sections[4].blocks);
}

test "MAD POS labels stay exact and cannot create owner or lexicalize protected body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "oca' lako", "Oca' lako ", "Oca' lako 2", "Oca' sèpat 2", "Oca' s'''è'''pat", "Oca' lako; Oca' sèpat", "Unknown Oca' lako", "Conto", "Sombher" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    try std.testing.expectEqualStrings("Verb", partOfSpeech("Verb").?);
    try std.testing.expectEqualStrings("Adjective", partOfSpeech("Adjective").?);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Oca' lako", .level = 2 },
        .{ .title = "Oca' sèpat", .level = 3 },
    };
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    try std.testing.expectEqualStrings("Adjective", unresolved.lexemes[0].kind);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes[0].section);
    try std.testing.expectEqualSlices(usize, &.{0}, unresolved.other_sections);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const protected = try renderer.renderBody("<nowiki>===Oca' lako===</nowiki>\n<pre>===Oca' sèpat===</pre>\n");
    const body_only = [_]Section{.{ .title = "Notes", .level = 3, .blocks = protected }};
    const layout = try buildOwned(a, &body_only, "mad");
    try std.testing.expectEqual(@as(usize, 0), layout.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, layout.other_sections);
}


// Append to src/encoder/presentation_layout.zig with layout.patch in the selected
// private qualification candidate. These are layout controls, not a saved-page
// or production/GUI replay. Exact heading authority: Patrom:-etim- p1929/r381015.
test "BR Gerdarzh associates etymology without changing retained lexical structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { title: []const u8, pos: []const u8, etymology: []const u8, body: []const u8, senses: usize };
    const cases = [_]Case{
        .{ .title = "laezh-glas", .pos = "Anv-kadarn", .etymology = ":[[ger|Ger]] [[kevrennek]] [[savet]] [[diwar]] an [[anv-kadarn]] ''[[laezh]]'' [[hag]] an [[anv-gwan]] ''[[glas]]''\n", .body = "'''laezh-glas'''\n#[[laezh-bihan|Laezh-bihan]]\n", .senses = 1 },
        .{ .title = "reoliek", .pos = "Anv-gwan", .etymology = ":[[savet|Savet]] [[diwar]] an [[anv-kadarn]] ''[[reol]]'' [[hag]] al [[lostger]] ''[[-iek]]''\n", .body = "'''reoliek'''\n# [[ordinal|Ordinal]]. a c'hoarvez en un doare [[boutin]], ha n'eo ket [[digustum]].\n# A c'hoarvez en un [[heuliañ]] [[reolennoù]], naturel pe gevredadel.\n", .senses = 2 },
    };
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    for (cases) |case| {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = case.title, .language = "Brezhoneg" } };
        const origin_blocks = try renderer.renderBody(case.etymology);
        const lexical_blocks = try renderer.renderBody(case.body);
        const sections = [_]Section{
            .{ .title = "Brezhoneg", .level = 2 },
            .{ .title = "Gerdarzh", .level = 3, .blocks = origin_blocks },
            .{ .title = case.pos, .level = 3, .blocks = lexical_blocks },
            .{ .title = "Troidigezhioù", .level = 4 },
        };
        var prior_sections = sections;
        prior_sections[1].title = "Unrecognized origin heading";
        const prior = try buildOwned(a, &prior_sections, "Brezhoneg");
        const actual = try buildOwned(a, &sections, "Brezhoneg");
        try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
        try std.testing.expectEqual(@as(?usize, 1), actual.lexemes[0].etymology);
        try std.testing.expectEqual(case.senses, actual.lexemes[0].definitions.len);
        try std.testing.expectEqualStrings("Brezhoneg", actual.lexemes[0].language);
        // Only the compiled origin reference changes: sense/block indices,
        // introduction, related sections and lexical kind retain their values.
        var without_origin = actual.lexemes[0];
        without_origin.etymology = null;
        try std.testing.expectEqualDeep(prior.lexemes[0], without_origin);
        try std.testing.expectEqualDeep(prior.other_sections, actual.other_sections);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, actual.other_sections);
        try std.testing.expectEqualDeep(origin_blocks, sections[1].blocks);
        try std.testing.expectEqualDeep(lexical_blocks, sections[2].blocks);
        const other_owner = try buildOwned(a, &sections, "Independent owner");
        try std.testing.expectEqualStrings("Independent owner", other_owner.lexemes[0].language);
        try std.testing.expectEqual(@as(?usize, 1), other_owner.lexemes[0].etymology);
        const unknown = try buildUnclassified(a, &sections);
        try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
        try std.testing.expectEqual(@as(?usize, 1), unknown.lexemes[0].etymology);
    }
}

test "BR Gerdarzh preserves source region boundaries and does not invent a language" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Brezhoneg", .level = 2 },
        .{ .title = "Gerdarzh", .level = 3 },
        .{ .title = "Anv-kadarn", .level = 3 },
        .{ .title = "Unknown region", .level = 2 },
        .{ .title = "Anv-gwan", .level = 3 },
        .{ .title = "Gerdarzh", .level = 3 },
        .{ .title = "Anv-kadarn", .level = 3 },
        .{ .title = "Brezhoneg", .level = 1 },
        .{ .title = "Anv-gwan", .level = 3 },
    };
    const owned = try buildOwned(a, &sections, "Independent owner");
    try std.testing.expectEqual(@as(usize, 4), owned.lexemes.len);
    const expected = [_]?usize{ 1, null, 5, null };
    for (owned.lexemes, expected) |lexeme, origin| {
        try std.testing.expectEqual(origin, lexeme.etymology);
        try std.testing.expectEqualStrings("Independent owner", lexeme.language);
    }
    // In the legacy non-owned path a localized etymology H2 cannot replace the
    // preceding language with its own label. Unclassified ownership stays empty.
    const l2 = [_]Section{
        .{ .title = "Brezhoneg", .level = 2 },
        .{ .title = "Gerdarzh", .level = 2 },
        .{ .title = "Anv-kadarn", .level = 3 },
    };
    const legacy = try build(a, &l2);
    try std.testing.expectEqualStrings("Brezhoneg", legacy.lexemes[0].language);
    try std.testing.expectEqual(@as(?usize, 1), legacy.lexemes[0].etymology);
    const unknown = try buildUnclassified(a, &l2);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
    try std.testing.expect(partOfSpeech("Gerdarzh") == null);
}

test "BR etymology matching stays exact and protected body text is not a heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    for ([_][]const u8{ "gerdarzh", "GERDARZH", "Gerdarzh 2", "Gerdarzh ", "Unknown Gerdarzh" }) |title| {
        const sections = [_]Section{ .{ .title = title, .level = 3 }, .{ .title = "Anv-kadarn", .level = 3 } };
        const layout = try buildOwned(a, &sections, "Independent owner");
        try std.testing.expect(layout.lexemes[0].etymology == null);
        try std.testing.expectEqualStrings("Independent owner", layout.lexemes[0].language);
    }
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const blocks = try renderer.renderBody("<nowiki>===Gerdarzh===</nowiki>\n<pre>===Gerdarzh===</pre>\n");
    const protected = [_]Section{ .{ .title = "Notes", .level = 3, .blocks = blocks }, .{ .title = "Anv-kadarn", .level = 3 } };
    const layout = try buildOwned(a, &protected, "Independent owner");
    try std.testing.expect(layout.lexemes[0].etymology == null);
    try std.testing.expectEqualDeep(blocks, protected[0].blocks);
    for ([_][]const u8{ "Etymology", "Etimologia", "ရင်းမြစ်" }) |title| {
        const sections = [_]Section{ .{ .title = title, .level = 3 }, .{ .title = "Noun", .level = 3 } };
        const legacy = try buildOwned(a, &sections, "Independent owner");
        try std.testing.expectEqual(@as(?usize, 0), legacy.lexemes[0].etymology);
    }
}


// Append to the existing presentation_layout.zig module in private qualification.
// Scoped raw-source controls: actual full Reader trees remain separate evidence.
test "ZGH exact POS headings retain independently declared owners and source sense associations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { title: []const u8, owner: []const u8, label: []const u8, kind: []const u8, body: []const u8, definitions: usize };
    const cases = [_]Case{
        .{ .title = "Land", .owner = "ⵜⴰⵏⴳⵍⵉⵣⵜ", .label = "ⵉⵙⵎ", .kind = "Noun", .body = "* '''Land'''\n# [[ⵜⴰⵎⴰⵣⵉⵔⵜ#zgh|ⵜⴰⵎⴰⵣⵉⵔⵜ]]\n", .definitions = 1 },
        .{ .title = "hola", .owner = "ⵜⴰⵙⴱⵏⵢⵓⵍⵉⵜ", .label = "ⵉⵙⵎ", .kind = "Noun", .body = "'''hola'''\n# [[ⴰⵣⵓⵍ#zgh|ⴰⵣⵓⵍ]]\n", .definitions = 1 },
        .{ .title = "hola", .owner = "Catalan", .label = "ⵉⵙⵎ", .kind = "Noun", .body = "'''hola'''\n# [[ⴰⵣⵓⵍ#zgh|ⴰⵣⵓⵍ]]\n", .definitions = 1 },
        .{ .title = "hola", .owner = "Basque", .label = "ⴰⵎⵔⵏⵓ", .kind = "Adverb", .body = "'''hola'''\n# [[ⴰⵎ ⵉⵎⴽⵉ#zgh|ⴰⵎ ⵉⵎⴽⵉ]]\n# [[ⵙ ⵜⵖⴰⵔⴰⵙⵜ ⴰ#zgh|ⵙ ⵜⵖⴰⵔⴰⵙⵜ ⴰ]]\n", .definitions = 2 },
    };
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    for (cases) |case| {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = case.title, .language = case.owner } };
        const blocks = try renderer.renderBody(case.body);
        const sections = [_]Section{
            .{ .title = case.owner, .level = 2 },
            .{ .title = case.label, .level = 3, .blocks = blocks },
            .{ .title = "ⵜⵉⵙⵓⵖⴰⵍ", .level = 4 },
        };
        // English canonical kind is the existing layout behavior oracle. Only
        // recognition of the localized heading is new; source data is not moved.
        var canonical = sections;
        canonical[1].title = case.kind;
        const expected = try buildOwned(a, &canonical, case.owner);
        const actual = try buildOwned(a, &sections, case.owner);
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
        const lexeme = actual.lexemes[0];
        try std.testing.expectEqualStrings(case.owner, lexeme.language);
        try std.testing.expectEqualStrings(case.kind, lexeme.kind);
        try std.testing.expectEqual(@as(usize, 1), lexeme.section);
        try std.testing.expectEqual(case.definitions, lexeme.definitions.len);
        try std.testing.expect(lexeme.etymology == null);
        try std.testing.expectEqualSlices(usize, &.{2}, lexeme.related_sections);
        try std.testing.expectEqualStrings(case.label, sections[1].title);
        try std.testing.expectEqualDeep(blocks, sections[1].blocks);
        for (lexeme.definitions) |sense| {
            try std.testing.expect(blocks[sense.block].kind == .definition);
            try std.testing.expect(sense.form == null);
        }
        const different = try buildOwned(a, &sections, "Independent other owner");
        try std.testing.expectEqualStrings("Independent other owner", different.lexemes[0].language);
        try std.testing.expectEqualDeep(lexeme.definitions, different.lexemes[0].definitions);
    }
}

test "ZGH layout preserves unclassified preamble and does not promote a POS label into ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "ⴰⵏⴰⵎⴽ" } };
    // Actual authored Markdown-like preamble. Its two definition blocks must
    // remain unclassified content; an edition or later POS is not their owner.
    const preamble = try renderer.renderBody("# Tamazight Dictionary Entries\n\n## Entry 1: ⴰⵏⴰⵎⴽ (anamk) - المعنى\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const unknown_sections = [_]Section{.{ .title = "Unclassified", .level = 2, .blocks = preamble }};
    const unknown = try buildUnclassified(a, &unknown_sections);
    try std.testing.expectEqual(@as(usize, 0), unknown.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, unknown.other_sections);
    try std.testing.expectEqualDeep(preamble, unknown_sections[0].blocks);
    const unknown_pos = [_]Section{
        .{ .title = "ⵉⵙⵎ", .level = 2, .blocks = preamble },
        .{ .title = "ⴰⵎⵔⵏⵓ", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const unresolved = try buildUnclassified(a, &unknown_pos);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes[0].section);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    // Separate actual zgh-owned region: table stays other material and only
    // the three definition blocks become senses. No table-to-sense conversion.
    const body = [_]wiki.Block{
        .{ .kind = .table }, .{ .kind = .paragraph },
        .{ .kind = .definition, .list_path = "#" },
        .{ .kind = .definition, .list_path = "#" },
        .{ .kind = .definition, .list_path = "#" },
    };
    const owned_sections = [_]Section{
        .{ .title = "ⵜⴰⵎⴰⵣⵉⵖⵜ ⵜⴰⵏⴰⵡⴰⵢⵜ", .level = 2 },
        .{ .title = "ⵉⵙⵎ", .level = 3, .blocks = &body },
        .{ .title = "ⵉⴽⵏⵉⵡⵏ", .level = 2 },
    };
    const owned = try buildOwned(a, &owned_sections, "ⵜⴰⵎⴰⵣⵉⵖⵜ ⵜⴰⵏⴰⵡⴰⵢⵜ");
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes.len);
    try std.testing.expectEqual(@as(usize, 3), owned.lexemes[0].definitions.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, owned.lexemes[0].introduction);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, owned.other_sections);
    try std.testing.expectEqualDeep(@as([]const wiki.Block, &body), owned_sections[1].blocks);
}

test "ZGH POS labels reject lookalikes support labels and protected literal text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "ⵉⵙⵎ ", "ⵉⵙⵎ 2", "ⵉⵙⵎ ⵉⵥⵍⵉⵏ", "ⵉⵙⵎⴰⵡⵏ", "ⴰⵎⵔⵏⵓ 2", "Unknown ⴰⵎⵔⵏⵓ", "ⵉⵎⵔⵏⵓⵜⵏ", "ⵉⴽⵏⵉⵡⵏ", "ⴰⵙⵓⵙⵔⵓ", "ⵜⵉⵙⵓⵖⴰⵍ" }) |title|
        try std.testing.expect(partOfSpeech(title) == null);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("ⵉⵙⵎ").?);
    try std.testing.expectEqualStrings("Adverb", partOfSpeech("ⴰⵎⵔⵏⵓ").?);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
    try std.testing.expectEqualStrings("Adverb", partOfSpeech("Adverb").?);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const blocks = try renderer.renderBody("<nowiki>===ⵉⵙⵎ===</nowiki>\n<pre>===ⴰⵎⵔⵏⵓ===</pre>\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{.{ .title = "Notes", .level = 3, .blocks = blocks }};
    const literal = try buildOwned(a, &sections, "Independent owner");
    try std.testing.expectEqual(@as(usize, 0), literal.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, literal.other_sections);
}

// Append only to presentation_layout.zig in the selected private candidate.
// Scoped controls from retained raw p5779/r29021 and observed UG02 Reader fields.
// This authored fixture is not the complete page or a recovered expanded body.
test "UG exact noun title preserves supplied owner and actual sense quotation relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const label = "ئومۇمىي ئىسىم";
    const owner = "ئۇيغۇرچە / Uyghurche";
    const first = "بىرەر كىشى ياكى نەرسىگە يېتىدىغان مەنپەئەت، نەپ";
    const quote = "قىلىدىغان ئىش بولمىسا، ئۆيگە بېرىپ ئۆز ئىشىمىزنى قىلساق شۇ پايدا ئەمەسمۇ؟";
    const second = "‹س ئىقتىساد› ئىشلەپچىقرىش، سودا-سېتىق ۋە تۈرلۈك تىجارەت يوللىرى ئارقىلىق كىرگۈزگەن كىرىمىدىن، تەننەرخى ياكى دەسمايىنى ۋە باجنى چىقىرىۋەتكەندىن كېيىنكى ئاشقان سومما، نەپ.";
    // The angle spelling is an explicit scoped literal control; it is not an
    // assertion that this was the retained template's full expanded output.
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "پايدا", .language = owner } };
    const blocks = try renderer.renderBody("'''پايدا''' / &lt;pɑyɗɑ&gt; /\n# " ++ first ++ "\n#* " ++ quote ++ "\n# " ++ second ++ "\n");
    const synonyms = try renderer.renderBody("* [[نەپ]]، [[مەنپەئەت]]\n");
    const antonyms = try renderer.renderBody("* [[زىيان]]، [[زەرەر]]\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = label, .level = 3, .blocks = blocks },
        .{ .title = "مەنىداش سۆزلەر", .level = 4, .blocks = synonyms },
        .{ .title = "قارشى مەنىلىك سۆزلەر", .level = 4, .blocks = antonyms },
        .{ .title = "", .level = 2 },
        .{ .title = "پايدىلانمىلار", .level = 3 },
    };
    var canonical = sections;
    canonical[0].title = "Noun";
    const expected = try buildOwned(a, &canonical, owner);
    const actual = try buildOwned(a, &sections, owner);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
    const noun = actual.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings(owner, noun.language);
    try std.testing.expectEqual(@as(usize, 0), noun.section);
    try std.testing.expect(noun.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, actual.other_sections);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 3), noun.definitions[1].block);
    try std.testing.expectEqualSlices(usize, &.{2}, noun.definitions[0].quotations);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[1].quotations.len);
    for (noun.definitions) |sense| {
        try std.testing.expect(sense.parent == null and sense.form == null);
        try std.testing.expectEqualStrings("#", blocks[sense.block].list_path);
    }
    try std.testing.expectEqualStrings(first, blocks[1].spans[0].text);
    try std.testing.expectEqualStrings(quote, blocks[2].spans[0].text);
    try std.testing.expectEqualStrings(second, blocks[3].spans[0].text);
    try std.testing.expect(blocks[2].kind == .quotation and blocks[2].depth == 2);
    try std.testing.expectEqualStrings("#*", blocks[2].list_path);
    var headword = false;
    var intro_text: std.ArrayList(u8) = .empty;
    for (blocks[0].spans) |span| {
        try intro_text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.text, "پايدا")) headword = span.flags.bold;
    }
    try std.testing.expect(headword);
    try std.testing.expectEqualStrings("پايدا / <pɑyɗɑ> /", intro_text.items);
    const targets = [_][]const u8{ "نەپ", "مەنپەئەت", "زىيان", "زەرەر" };
    var links: usize = 0;
    for ([_][]const wiki.Block{ synonyms, antonyms }) |relation| for (relation) |block| for (block.spans) |span| {
        if (span.kind == .link) {
            try std.testing.expect(links < targets.len);
            const target = targets[links];
            try std.testing.expectEqualStrings(target, span.text);
            try std.testing.expectEqualStrings(target, span.target);
            links += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 4), links);
    try std.testing.expectEqualStrings(label, sections[0].title);
    try std.testing.expectEqualDeep(blocks, sections[0].blocks);
    const other = try buildOwned(a, &sections, "Independent supplied owner");
    var expected_other = noun;
    expected_other.language = "Independent supplied owner";
    try std.testing.expectEqualDeep(expected_other, other.lexemes[0]);
}

test "UG noun matching is exact and unknown L2 supplies no language or POS owner" {
    try std.testing.expectEqualStrings("Noun", partOfSpeech("ئومۇمىي ئىسىم").?);
    for ([_][]const u8{ "ئىسىم", "ئومۇمىي", "ئومۇمىي  ئىسىم", "ئومۇمىي ئىسىم ", " ئومۇمىي ئىسىم", "ئومۇمىي ئىسىم 2", "ئومۇمىي ئىسىملىق", "Unknown ئومۇمىي ئىسىم" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "ئومۇمىي ئىسىم", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Unknown region", .level = 2 },
        .{ .title = "ئومۇمىي ئىسىم", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const unknown = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unknown.lexemes.len);
    try std.testing.expectEqualStrings("Noun", unknown.lexemes[0].kind);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 2), unknown.lexemes[0].section);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, unknown.other_sections);
    try std.testing.expectEqual(@as(usize, 1), unknown.lexemes[0].definitions.len);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
}

// Append only to presentation_layout.zig in the selected private candidate.
// Authored scoped fixture from llingua p22/r356746 and actual AST04 Reader.
// This is not a reconstruction of the full expanded page or its template labels.
test "AST exact noun label preserves owner three senses and independent source actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = "asturianu";
    const first_source = "Órganu muscular carnosu y móvil, asitiáu nel interior de la [[boca]], que pertime percibir el [[sentíu]] del [[gustu]] y d'articular dellos [[soníu|soníos]].";
    const second = "Sistema de comunicación que consiste en facer usu de soníos y/o xestos pa espresar pensamientos y sentimientos.";
    const third = "Sistema de comunicación oral y natural propiu a una determinada comunidá o grupu humanos.";
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "llingua", .language = owner } };
    const blocks = try renderer.renderBody("''femenín singular'' '''llingua'''; ''plural'' '''[[llingües]]'''\n# " ++ first_source ++ "\n# " ++ second ++ "\n# " ++ third ++ "\n");
    const origin = try renderer.renderBody("* Del ''[[lingua]]'', de mesmu significáu.\n");
    const synonyms = try renderer.renderBody("* [[parpayuela]]\n* [[llinguaxe]] ~ [[llinguax]]\n* [[idioma]]\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Etimoloxía", .level = 3, .blocks = origin },
        .{ .title = "Sustantivu", .level = 2, .blocks = blocks },
        .{ .title = "Sinónimos", .level = 3, .blocks = synonyms },
        .{ .title = "Referencies", .level = 2 },
    };
    var canonical = sections;
    canonical[1].title = "Noun";
    const expected = try buildOwned(a, &canonical, owner);
    const actual = try buildOwned(a, &sections, owner);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
    const noun = actual.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings(owner, noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, actual.other_sections);
    try std.testing.expectEqual(@as(usize, 3), noun.definitions.len);
    for (noun.definitions, 0..) |sense, i| {
        try std.testing.expectEqual(i + 1, sense.block);
        try std.testing.expect(sense.parent == null and sense.form == null);
        try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
        try std.testing.expectEqualStrings("#", blocks[sense.block].list_path);
    }
    try std.testing.expectEqualStrings(second, blocks[2].spans[0].text);
    try std.testing.expectEqualStrings(third, blocks[3].spans[0].text);
    const targets = [_][]const u8{ "boca", "sentíu", "gustu", "soníu" };
    const labels = [_][]const u8{ "boca", "sentíu", "gustu", "soníos" };
    var links: usize = 0;
    for (blocks[1].spans) |span| if (span.kind == .link) {
        try std.testing.expect(links < targets.len);
        try std.testing.expectEqualStrings(targets[links], span.target);
        try std.testing.expectEqualStrings(labels[links], span.text);
        links += 1;
    };
    try std.testing.expectEqual(targets.len, links);
    var headword = false;
    var plural = false;
    for (blocks[0].spans) |span| {
        if (std.mem.eql(u8, span.text, "llingua")) headword = span.flags.bold;
        if (span.kind == .link and std.mem.eql(u8, span.target, "llingües")) {
            try std.testing.expectEqualStrings("llingües", span.text);
            plural = span.flags.bold;
        }
    }
    try std.testing.expect(headword and plural);
    var etymology_link = false;
    for (origin[0].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "lingua")) {
        try std.testing.expectEqualStrings("lingua", span.text);
        etymology_link = span.flags.italic;
    };
    try std.testing.expect(etymology_link);
    try std.testing.expectEqualStrings("Sustantivu", sections[1].title);
    try std.testing.expectEqualDeep(blocks, sections[1].blocks);
    var alternate = noun;
    alternate.language = "Independent supplied owner";
    const other = try buildOwned(a, &sections, alternate.language);
    try std.testing.expectEqualDeep(alternate, other.lexemes[0]);
}

test "AST noun label is exact and unknown L2 supplies neither owner nor POS" {
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Sustantivu").?);
    for ([_][]const u8{ "sustantivu", "SUSTANTIVU", "Sustantivos", "Sustantivu ", " Sustantivu", "Sustantivu 2", "Sustantivu propiu", "Unknown Sustantivu" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Sustantivu", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Unknown region", .level = 2 },
        .{ .title = "Sustantivu", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const actual = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
    try std.testing.expectEqualStrings("Noun", actual.lexemes[0].kind);
    try std.testing.expectEqualStrings("", actual.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 2), actual.lexemes[0].section);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, actual.other_sections);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes[0].definitions.len);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
}

// Exact noun-body slice of retained leinki p857/r8162, from after
// {{-navnorð-|fo}} to before {{-samheiti-}}. No template execution or invented
// hash-list definition: the authored :[1] line remains an indent, as in FO02.
test "FO leinki exact noun label keeps numbered indent and supplied owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = "Føroyskt";
    const body =
        \\'''leinki''', hvørkikyn
        \\:[1] Ístaðin fyri tenglar ella links eigur orðið ''leinki'' at verða nýtt.
        \\
        \\'''Bending: '''Eitt ''leinki'', fleiri ''leinki'' ella ''leinkir'', bundið: ''leinkið''
        \\:
        \\
    ;
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "leinki", .language = owner } };
    const blocks = try renderer.renderBody(body);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Føroyskt", .level = 2 },
        .{ .title = "Navnorð", .level = 3, .blocks = blocks },
        .{ .title = "Týðing", .level = 3 },
    };
    var canonical = sections;
    canonical[1].title = "Noun";
    const expected = try buildOwned(a, &canonical, owner);
    const actual = try buildOwned(a, &sections, owner);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
    const noun = actual.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings(owner, noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expect(noun.etymology == null);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 0), noun.related_sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, actual.other_sections);
    try std.testing.expectEqual(blocks.len, noun.introduction.len);
    for (noun.introduction, 0..) |block, i| try std.testing.expectEqual(i, block);

    var numbered_indent = false;
    var bold_headword = false;
    var declension_forms: usize = 0;
    const forms = [_][]const u8{ "leinki", "leinki", "leinkir", "leinkið" };
    for (blocks) |block| {
        try std.testing.expect(block.kind != .definition);
        var visible: std.ArrayList(u8) = .empty;
        for (block.spans) |span| try visible.appendSlice(a, span.text);
        if (std.mem.eql(u8, visible.items, "[1] Ístaðin fyri tenglar ella links eigur orðið leinki at verða nýtt.")) {
            try std.testing.expect(block.kind == .indent);
            try std.testing.expectEqualStrings(":", block.list_path);
            numbered_indent = true;
        }
        if (std.mem.eql(u8, visible.items, "leinki, hvørkikyn")) {
            for (block.spans) |span| {
                if (std.mem.eql(u8, span.text, "leinki")) bold_headword = span.flags.bold;
            }
        }
        if (std.mem.startsWith(u8, visible.items, "Bending: Eitt ")) {
            try std.testing.expectEqualStrings("Bending: Eitt leinki, fleiri leinki ella leinkir, bundið: leinkið", visible.items);
            for (block.spans) |span| {
                if (span.flags.italic) {
                    try std.testing.expect(declension_forms < forms.len);
                    try std.testing.expectEqualStrings(forms[declension_forms], span.text);
                    declension_forms += 1;
                }
            }
        }
    }
    try std.testing.expect(numbered_indent and bold_headword);
    try std.testing.expectEqual(forms.len, declension_forms);
    try std.testing.expectEqualStrings("Navnorð", sections[1].title);
    try std.testing.expectEqualDeep(blocks, sections[1].blocks);
    const other = try buildOwned(a, &sections, "Independent supplied owner");
    var expected_other = noun;
    expected_other.language = "Independent supplied owner";
    try std.testing.expectEqualDeep(expected_other, other.lexemes[0]);
}

test "FO noun label exactness never establishes language ownership" {
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Navnorð").?);
    for ([_][]const u8{ "navnorð", "NAVNORÐ", "Navnorð ", " Navnorð", "Navnorð 2", "Navnorð bøying", "Unknown Navnorð", "Samheiti", "Týðing" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Navnorð", .level = 2 },
        .{ .title = "Unknown region", .level = 2 },
        .{ .title = "Navnorð", .level = 3 },
    };
    const actual = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
    try std.testing.expectEqualStrings("Noun", actual.lexemes[0].kind);
    try std.testing.expectEqualStrings("", actual.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 2), actual.lexemes[0].section);
    try std.testing.expectEqual(@as(usize, 0), actual.lexemes[0].definitions.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, actual.other_sections);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
}
