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
    // TPI pes p2116/r13958 uses Naun beside Noun; bung p4923/r13780
    // and monin p5364/r13757 contrast nominal senses with Verb/Interjection.
    // This exact localized POS label supplies lexical kind, never an owner.
    if (std.mem.eql(u8, title, "Naun")) return "Noun";
    // JA verb p9193/r2251618 emits this exact label and declares POS categories.
    // Classify the section only; preserve independently resolved or unknown owners.
    if (std.mem.eql(u8, title, "動詞")) return "Verb";
    // BN longingly p223262/r575079 authors this H3 before {{en-adv}};
    // its captured expansion repeats the English adverb category and headword.
    // Exact lexical kind only; retain the independently supplied language owner.
    if (std.mem.eql(u8, title, "ক্রিয়া বিশেষণ")) return "Adverb";
    // Retained AZ pages69623/69626/69627/69628 author this H3 above
    // head|xag|letter. Kind only; the independent owner route stays separate.
    if (std.mem.eql(u8, title, "Hərf")) return "Letter";
    // Retained VI osada invokes -noun- and emits this exact H3 plus the
    // Russian noun category. This supplies lexical kind, never its owner.
    if (std.mem.eql(u8, title, "Danh từ")) return "Noun";
    // Retained MS kaeru p44101/r320137 authors this H3 above its verb
    // headword and definition. Kind only; the Japanese owner stays independent.
    if (std.mem.eql(u8, title, "Kata kerja")) return "Verb";
    // Modelo:-substf- p38548/r675585 emits this exact noun heading. Gender
    // stays authored text; language ownership is independently established.
    if (std.mem.eql(u8, title, "Substantivo feminino")) return "Noun";
    // Retained LT Ispanija authors this H3 above its noun inflection source.
    // Exact lexical kind only; the caller supplies independent language ownership.
    if (std.mem.eql(u8, title, "Daiktavardis")) return "Noun";
    // The retained LT adjective headwords independently name this exact POS.
    // Their entry-language ownership is a separate source declaration.
    if (std.mem.eql(u8, title, "Būdvardis")) return "Adjective";
    // Exact retained HY namespace10 -hy-գո-/ած-/մակ- p2733/2734/2736
    // emit these grammatical labels. Kind only: retain the independent owner.
    if (std.mem.eql(u8, title, "Գոյական")) return "Noun";
    if (std.mem.eql(u8, title, "Ածական")) return "Adjective";
    if (std.mem.eql(u8, title, "Մակբայ")) return "Adverb";
    // Retained FI isopihatatar p530637/r5266265 explicitly authors this H3;
    // fi-subs expansion repeats its noun category. Kind only, never an owner.
    if (std.mem.eql(u8, title, "Substantiivi")) return "Noun";
    // Exact FI kulta Reader H3, above its two retained pronoun-form senses.
    // This declares lexical kind only; language ownership stays independent.
    if (std.mem.eql(u8, title, "Pronomini")) return "Pronoun";
    // Retained ES ataujía explicitly authors this noun declaration. This
    // identifies lexical kind only; the caller supplies the language owner.
    if (std.mem.eql(u8, title, "Sustantivo femenino")) return "Noun";
    // Retained KO intercrural p495995/r4482683 authors this H3 immediately
    // before {{en-adj|-}}; expansion repeats the adjective category and headword.
    // Exact section classification only; the independently resolved owner stays.
    if (std.mem.eql(u8, title, "형용사")) return "Adjective";
    if (std.mem.eql(u8, title, "부사")) return "Adverb";
    // Retained KY modules p87905/r204198 and p88008/r204200 emit these
    // headings/categories; primary term definitions: enwiki oldid68920211,
    // oldid62332914 and kywiki Сан_атооч oldid445200. POS only, never owner.
    if (std.mem.eql(u8, title, "Зат атооч")) return "Noun";
    if (std.mem.eql(u8, title, "Сан атооч")) return "Numeral";
    if (std.mem.eql(u8, title, "Тактооч")) return "Adverb";
    // Retained NL curlingforælder p766852/r4525916 invokes -noun-|dan;
    // its captured expansion emits this exact linked H4 noun heading.
    // Classify the section only; preserve the independently resolved owner.
    if (std.mem.eql(u8, title, "Zelfstandig naamwoord")) return "Noun";
    // Retained it Template:-verb- p1951/r4007156 passes Sezione=verbo;
    // Sezione voce p172588/r1880894 emits its exact ucfirst heading.
    if (std.mem.eql(u8, title, "Verbo")) return "Verb";
    // Teamplaid:-ainm- p1960/r77514 emits this exact noun heading.
    // Scottish Gaelic noun term: en.wiktionary.org/wiki/noun#Translations.
    if (std.mem.eql(u8, title, "Ainmear")) return "Noun";
    // GA -noun- p2140/r8909 redirects to -ainm- p3085/r43776, which
    // emits this exact noun heading and language-qualified noun category.
    // The independently supplied owner is unchanged.
    if (std.mem.eql(u8, title, "Ainmfhocal")) return "Noun";
    // Exact EU Txantiloi:Izena p4768/r408565 and Adjektiboa p4771/r408576.
    // Grammar terms: en.wiktionary.org/wiki/izen (oldid92930614), /wiki/adjective.
    // These labels organize an existing record; they never supply its owner.
    if (std.mem.eql(u8, title, "Izena")) return "Noun";
    if (std.mem.eql(u8, title, "Adjektiboa")) return "Adjective";
    // Retained ca Mòdul:lema/plantilles p273800/r2695731 maps nom to
    // substantius and adj to adjectius; the captured catalán headings use
    // these exact labels. Classify POS only, retaining the supplied owner.
    if (std.mem.eql(u8, title, "Nom")) return "Noun";
    if (std.mem.eql(u8, title, "Adjectiu")) return "Adjective";
    // Exact LI medisch p1482/r843548 and ich p1545/r929752 POS labels.
    // Language/variety ownership remains independently supplied by the caller.
    if (std.mem.eql(u8, title, "Bieveugelik naamwaord")) return "Adjective";
    if (std.mem.eql(u8, title, "Biewaord")) return "Adverb";
    if (std.mem.eql(u8, title, "Persuunlik veurnaamwaord") or
        std.mem.eql(u8, title, "Persuuenlik veurnaamwaord")) return "Pronoun";
    // Retained თარგი:-noun- p3473/r7298 emits this exact noun heading.
    // Linked H5 category headings keep the same semantic label; no owner inference.
    if (std.mem.eql(u8, title, "არსებითი სახელი")) return "Noun";
    // Retained DA -noun- p6490/r294633, -verb- p6498/r76325,
    // -interj- p6493/r294632 and -car-num- p7090/r29046 emit these
    // exact H3 labels and POS categories. Their language argument changes only
    // the category suffix; the caller retains its independently supplied owner.
    if (std.mem.eql(u8, title, "Substantiv")) return "Noun";
    if (std.mem.eql(u8, title, "Verbum")) return "Verb";
    if (std.mem.eql(u8, title, "Interjektion")) return "Interjection";
    if (std.mem.eql(u8, title, "Mængdetal")) return "Numeral";
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
    // Retained MNW sv-adv p113204/r159011 explicitly declares this head POS.
    // Grammar term: en.wiktionary.org/wiki/ကြိယာဝိသေသန (adverb).
    // Classify the exact heading only; preserve the independently supplied owner.
    if (std.mem.eql(u8, title, "ကြိယာဝိသေသန")) return "Adverb";
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
    // Retained TL tl-adj/phi-headword select pang-uri/adjective; aba's
    // Pandamdam section invokes tl-head with the literal interjection argument.
    // This assigns POS only, never language ownership.
    if (std.mem.eql(u8, title, "Pang-uri")) return "Adjective";
    if (std.mem.eql(u8, title, "Pandamdam")) return "Interjection";
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
    // SI මලදනු p114237/r226015: authored noun heading, si-noun, and
    // expanded සිංහල නාම පද category. Classify POS only, never the owner.
    if (std.mem.eql(u8, title, "නාම පදය")) return "Noun";
    // Exact noun heading in retained SK biola and Czech houslista source.
    // Classify the section only; keep its independently established owner.
    if (std.mem.eql(u8, title, "Podstatné meno")) return "Noun";
    for (speech) |name| if (part.named(title, name)) return name;
    return null;
}
const PendingSense = struct {
    value: Sense,
    examples: std.ArrayList(usize) = .empty,
    quotations: std.ArrayList(usize) = .empty,
    notes: std.ArrayList(usize) = .empty,
};
// Colon-indented numbered meanings retain their original list_item block.
// Only an explicit POS (or its already-proved immediate lemma) lends sense
// structure; inferred paragraph/morphology POS does not broaden this rule.
fn lexicalDefinition(block: wiki.Block, colon_meanings: bool) bool {
    return block.kind == .definition or (colon_meanings and block.kind == .list_item and
        std.mem.eql(u8, block.list_path, ":#"));
}
// A plain positive numeric term followed immediately by its definition-list
// detail is an authored sense label under an explicit POS. Keep both original
// blocks: the detail is the sense body and the number remains other material.
fn numberedDefinitionDetail(blocks: []const wiki.Block, index: usize, declared_pos: bool) bool {
    if (!declared_pos or index == 0 or index >= blocks.len) return false;
    const detail = blocks[index];
    const marker = blocks[index - 1];
    if (detail.kind != .list_detail or detail.depth != 1 or !std.mem.eql(u8, detail.list_path, ":") or
        marker.kind != .term or marker.depth != 1 or !std.mem.eql(u8, marker.list_path, ";") or marker.spans.len != 1) return false;
    const span = marker.spans[0];
    if (span.kind != .text or span.provenance != .parsed or span.generated_diagnostic or span.self_link or span.flags.code or
        span.role != .normal or span.target.len != 0) return false;
    const number = std.mem.trim(u8, span.text, " \t\r\n");
    if (number.len == 0 or number[0] < '1' or number[0] > '9') return false;
    for (number[1..]) |digit| if (!std.ascii.isDigit(digit)) return false;
    return true;
}
fn analyze(a: A, kind: []const u8, index: usize, etymology: ?usize, blocks: []const wiki.Block, declared_pos: bool) !Lexeme {
    var pending: std.ArrayList(PendingSense) = .empty;
    var intro: std.ArrayList(usize) = .empty;
    var other: std.ArrayList(usize) = .empty;
    const no_sense = std.math.maxInt(usize);
    var stack: [256]usize = undefined;
    var stack_len: usize = 1;
    // The first lexical marker selects this section's numbering convention.
    // A later ordinary definition cannot erase leading colon-numbered senses;
    // SI's trailing :# gloss stays supplementary after its initial # definition.
    const colon_meanings = declared_pos and for (blocks) |block| {
        if (block.kind == .definition) break false;
        if (lexicalDefinition(block, true)) break true;
    } else false;
    for (blocks, 0..) |block, b| {
        if (numberedDefinitionDetail(blocks, b + 1, declared_pos)) {
            try other.append(a, b);
            continue;
        }
        var depth: usize = 0;
        for (block.list_path) |c| {
            if (c != '#') break;
            depth += 1;
        }
        depth = @min(depth, stack.len - 1);
        if (lexicalDefinition(block, colon_meanings) or numberedDefinitionDetail(blocks, b, declared_pos)) {
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
// The literal TE muttadi grammar section links క్రియ in its part-of-speech
// field. The selected linked page p4733/r970248 explicitly identifies verb
// grammar and links verb/Wikipedia:Verb; its own noun entry is not borrowed.
fn teluguGrammarPlainSpan(span: wiki.Span) bool {
    return span.provenance == .parsed and !span.generated_diagnostic and !span.self_link and
        span.image == null and span.role == .normal and @as(u8, @bitCast(span.flags)) == 0 and
        span.language.len == 0 and span.classes.len == 0 and span.direction.len == 0 and
        span.explanation.len == 0 and span.foreground == null and span.background == null and
        span.font_scale == null;
}
fn teluguGrammarTerm(block: wiki.Block, label: []const u8) bool {
    if (block.kind != .term or block.depth != 1 or !std.mem.eql(u8, block.list_path, ";") or
        block.number.len != 0 or block.level != 0 or block.table != null or block.feature != null or
        block.spans.len != 1) return false;
    const span = block.spans[0];
    return teluguGrammarPlainSpan(span) and span.kind == .text and span.target.len == 0 and
        std.mem.eql(u8, span.text, label);
}
fn teluguGrammarEmptyDetail(block: wiki.Block) bool {
    return block.kind == .list_detail and block.depth == 1 and std.mem.eql(u8, block.list_path, ":") and
        block.number.len == 0 and block.level == 0 and block.spans.len == 0 and
        block.table == null and block.feature == null;
}
fn teluguGrammarHeading(section: anytype) bool {
    return czechMeaningHeading(section) and section.title_spans.len == 1 and
        teluguGrammarPlainSpan(section.title_spans[0]) and
        std.mem.eql(u8, section.title_spans[0].text, section.title);
}
fn teluguGrammarMeaningPart(sections: anytype, index: usize, owner: ?[]const u8) ?[]const u8 {
    const Section = @TypeOf(sections[index]);
    if (!@hasField(Section, "is_heading") or !@hasField(Section, "title_depth") or
        !@hasField(Section, "title_list_path") or !@hasField(Section, "title_spans")) return null;
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or index == 0) return null;
    const grammar = sections[index - 1];
    const meaning = sections[index];
    if (grammar.level != 2 or meaning.level != 2 or
        !std.mem.eql(u8, grammar.title, "వ్యాకరణ విశేషాలు") or
        !std.mem.eql(u8, meaning.title, "అర్థ వివరణ") or
        !teluguGrammarHeading(grammar) or !teluguGrammarHeading(meaning) or grammar.blocks.len != 7) return null;
    const blocks = grammar.blocks;
    if (!teluguGrammarTerm(blocks[0], "భాషాభాగం") or !teluguGrammarEmptyDetail(blocks[1]) or
        !teluguGrammarTerm(blocks[3], "వ్యుత్పత్తి") or !teluguGrammarEmptyDetail(blocks[4]) or
        !teluguGrammarTerm(blocks[5], "బహువచనం లేక ఏక వచనం") or !teluguGrammarEmptyDetail(blocks[6])) return null;
    const marker = blocks[2];
    if (marker.kind != .list_item or marker.depth != 1 or !std.mem.eql(u8, marker.list_path, "*") or
        marker.number.len != 0 or marker.level != 0 or marker.feature != null or marker.table != null or
        marker.spans.len != 2) return null;
    const label = marker.spans[0];
    const stop = marker.spans[1];
    if (!teluguGrammarPlainSpan(label) or !teluguGrammarPlainSpan(stop) or
        label.kind != .link or !std.mem.eql(u8, label.text, "క్రియ") or !std.mem.eql(u8, label.target, "క్రియ") or
        stop.kind != .text or stop.target.len != 0 or !std.mem.eql(u8, stop.text, ".")) return null;
    if (meaning.blocks.len == 0) return null;
    for (meaning.blocks) |block| {
        if (block.kind != .definition or block.depth != 1 or !std.mem.eql(u8, block.list_path, "#") or
            !lexicalDefinition(block, false)) return null;
    }
    // The authored second # line begins ఉదా:, but remains a numbered sense.
    // Do not manufacture an example path or borrow a language from this role.
    return "Verb";
}

// This source convention supplies a POS, never a language. The ordinary
// classifier must have supplied an owner before sibling metadata is joined.
// Atlıq = noun: kaa.wikipedia.org/w/index.php?oldid=206763&title=Atlıq.
fn morphologySiblingPart(sections: anytype, index: usize, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or index == 0) return null;
    const meaning = sections[index];
    const morphology = sections[index - 1];
    if (meaning.level != 3 or morphology.level != 3 or
        !std.mem.eql(u8, meaning.title, "Leksikalıq mánileri") or
        !std.mem.eql(u8, morphology.title, "Morfologiyalıq hám sintaksislik qásiyetleri")) return null;
    if (morphology.blocks.len != 1 or morphology.blocks[0].kind != .paragraph) return null;
    const spans = morphology.blocks[0].spans;
    if (spans.len != 2) return null;
    const marker = spans[0];
    const syllables = spans[1];
    for (spans) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or
            span.kind != .text or span.target.len != 0 or span.role != .normal or span.flags.code) return null;
    }
    if (!marker.flags.italic or !std.mem.eql(u8, marker.text, "atlıq") or
        syllables.flags.italic or !std.mem.startsWith(u8, syllables.text, ", ")) return null;
    // Keep this exact observed marker-plus-syllabification convention separate
    // from arbitrary prose mentioning a POS or a second grammatical marker.
    const tail = syllables.text[2..];
    if (tail.len == 0 or tail[0] == '-' or tail[tail.len - 1] == '-') return null;
    var hyphens: usize = 0;
    var previous_hyphen = false;
    for (tail) |byte| {
        if (byte == '-') {
            if (previous_hyphen) return null;
            hyphens += 1;
        } else if (byte < 0x80 and !std.ascii.isAlphabetic(byte)) return null;
        previous_hyphen = byte == '-';
    }
    if (hyphens == 0) return null;
    return "Noun";
}

// Шаблон:імен en (p6092/r573065) and імен eo (p13380/r572861)
// emit this exact linked declaration in the morphology section. It supplies
// only a POS; the caller must already own the complete language record.
fn ukrainianNounMarker(block: wiki.Block) bool {
    if (block.kind != .paragraph or block.spans.len != 2) return false;
    for (block.spans) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or
            span.image != null or span.role != .normal or @as(u8, @bitCast(span.flags)) != 0 or
            span.language.len != 0 or span.classes.len != 0 or span.direction.len != 0 or
            span.explanation.len != 0 or span.foreground != null or span.background != null or
            span.font_scale != null) return false;
    }
    const label = block.spans[0];
    const stop = block.spans[1];
    return label.kind == .link and std.mem.eql(u8, label.text, "Іменник") and
        std.mem.eql(u8, label.target, "іменник") and stop.kind == .text and
        stop.target.len == 0 and std.mem.eql(u8, stop.text, ".");
}

fn ukrainianMarkerCandidate(block: wiki.Block) bool {
    if (block.kind != .paragraph) return false;
    for (block.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Іменник") != null or
            std.mem.eql(u8, span.target, "іменник")) return true;
    }
    // A second isolated grammatical link-plus-period is conflicting evidence,
    // even when its label is not one of the POS names known to this analyzer.
    return block.spans.len == 2 and block.spans[0].kind == .link and
        block.spans[1].kind == .text and std.mem.eql(u8, block.spans[1].text, ".");
}

// Styled section titles are emitted as an addressable heading companion before
// layout analysis. Only that exact root self-heading leaves this wrapper empty
// of substantive body; it supplies neither language nor grammatical evidence.
fn ukrainianSemanticsWrapperEmpty(section: anytype) bool {
    if (section.blocks.len == 0) return true;
    if (section.blocks.len != 1) return false;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans") or
        !@hasField(S, "anchor") or !@hasField(S, "anchor_fallback")) return false;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1 or section.anchor.len == 0) return false;
    const heading = section.blocks[0];
    if (heading.kind != .heading or heading.level != section.level or heading.depth != 0 or
        heading.list_path.len != 0 or heading.number.len != 0 or heading.feature != null or
        heading.table != null or heading.spans.len != 1 or
        !std.mem.eql(u8, heading.anchor, section.anchor) or
        !std.mem.eql(u8, heading.anchor_fallback, section.anchor_fallback)) return false;
    for ([_]wiki.Span{ section.title_spans[0], heading.spans[0] }) |span| {
        if (span.kind != .text or span.provenance != .parsed or span.generated_diagnostic or
            span.self_link or span.image != null or span.target.len != 0 or span.flags.code or
            span.role != .normal or span.language.len != 0 or span.explanation.len != 0 or
            !std.mem.eql(u8, span.text, section.title)) return false;
    }
    return true;
}

fn ukrainianMorphologyMeaningPart(sections: anytype, index: usize, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or index < 3) return null;
    const morphology = sections[index - 3];
    const pronunciation = sections[index - 2];
    const semantics = sections[index - 1];
    const meaning = sections[index];
    if (!std.mem.eql(u8, morphology.title, "Морфосинтаксичні ознаки") or morphology.level != 3 or
        !std.mem.eql(u8, pronunciation.title, "Вимова") or pronunciation.level != 3 or
        !std.mem.eql(u8, semantics.title, "Семантичні властивості") or
        (semantics.level != 3 and semantics.level != 4) or !ukrainianSemanticsWrapperEmpty(semantics) or
        !std.mem.eql(u8, meaning.title, "Значення") or meaning.level != semantics.level + 1) return null;
    var found = false;
    for (morphology.blocks) |block| {
        if (!ukrainianMarkerCandidate(block)) continue;
        if (found or !ukrainianNounMarker(block)) return null;
        found = true;
    }
    // Pronunciation cannot smuggle a second conflicting grammatical declaration
    // between the morphology marker and its meaning section.
    for (pronunciation.blocks) |block| if (ukrainianMarkerCandidate(block)) return null;
    if (!found) return null;
    for (meaning.blocks) |block| if (block.kind == .definition and
        std.mem.eql(u8, block.list_path, "#") and block.spans.len != 0) return "Noun";
    return null;
}

const MarkedParagraphPart = struct { kind: []const u8, first: usize, end: usize, croatian: bool = false, bracket_numbered: bool = false, id_term: bool = false };
fn slovenePosLink(span: wiki.Span) ?[]const u8 {
    if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or
        span.kind != .link or span.flags.code or span.role != .normal or
        !std.mem.eql(u8, span.text, span.target)) return null;
    if (span.flags.italic and std.mem.eql(u8, span.target, "glagol")) return "Verb";
    if (!span.flags.italic and std.mem.eql(u8, span.target, "samostalnik")) return "Noun";
    return null;
}
// Exact retained Predloga:glagol p20278/r170191 and Predloga:samostalnik
// p17834/r170902 headword/comma/POS-link convention. It classifies POS only.
fn sloveneHeadwordPart(block: wiki.Block) ?[]const u8 {
    if (block.kind != .paragraph or block.spans.len < 2) return null;
    var word = false;
    var comma = false;
    var result: ?[]const u8 = null;
    for (block.spans) |span| {
        if (span.generated_diagnostic or span.self_link or
            span.flags.code or span.role != .normal) return null;
        if (span.provenance != .parsed) {
            // SL emits &#32; after the POS, or outside italics after the
            // parsed noun headword/comma. Spacing supplies no marker authority.
            if ((result != null or (word and comma and !span.flags.italic and !span.flags.bold)) and
                span.provenance == .entity_literal and
                span.kind == .text and span.target.len == 0 and span.text.len != 0 and
                std.mem.trim(u8, span.text, " \t").len == 0) continue;
            return null;
        }
        if (result != null) {
            if (slovenePosLink(span) != null) return null;
            continue;
        }
        if (span.kind == .link) {
            if (!word or !comma) return null;
            result = slovenePosLink(span) orelse return null;
            continue;
        }
        if (span.kind != .text or span.target.len != 0) return null;
        for (span.text) |byte| {
            if (comma) {
                if (byte != ' ' and byte != '\t') return null;
            } else if (byte == ',') {
                if (!word) return null;
                comma = true;
            } else {
                if (!span.flags.italic or span.flags.bold or byte == '\r' or byte == '\n') return null;
                if (byte != ' ' and byte != '\t') word = true;
            }
        }
    }
    return result;
}
fn sloveneMeaningsLabel(block: wiki.Block) bool {
    if (block.kind != .paragraph or block.spans.len != 1) return false;
    const span = block.spans[0];
    return span.provenance == .parsed and !span.generated_diagnostic and !span.self_link and
        span.kind == .text and span.target.len == 0 and span.role == .normal and
        span.flags.bold and !span.flags.italic and !span.flags.code and
        std.mem.eql(u8, span.text, "Pomeni:");
}
fn sloveneParagraphPart(blocks: []const wiki.Block, owner: ?[]const u8, level: u8) ?MarkedParagraphPart {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or level != 2) return null;
    var marker: ?usize = null;
    var meaning: ?usize = null;
    var kind: ?[]const u8 = null;
    for (blocks, 0..) |block, index| {
        if (sloveneHeadwordPart(block)) |name| {
            if (marker != null) return null;
            marker = index;
            kind = name;
        }
        if (sloveneMeaningsLabel(block)) {
            if (meaning != null) return null;
            meaning = index;
        }
    }
    const marker_index = marker orelse return null;
    const meaning_index = meaning orelse return null;
    if (marker_index >= meaning_index) return null;
    var first = meaning_index + 1;
    while (first < blocks.len and blocks[first].kind == .blank) : (first += 1) {}
    if (first == blocks.len or blocks[first].kind != .definition or !std.mem.eql(u8, blocks[first].list_path, "#")) return null;
    var end = first + 1;
    while (end < blocks.len) : (end += 1) {
        if (blocks[end].kind == .blank) continue;
        if (!std.mem.startsWith(u8, blocks[end].list_path, "#")) break;
    }
    return .{ .kind = kind.?, .first = first, .end = end };
}
// Retained HR pages mark definitions with bold definicija:, then a line break
// and italic imenica/pridjev. This supplies POS only; the record owner remains
// independently classified. The first bold sinonimi: closes this sense region.
fn croatianMarkerSpan(span: wiki.Span) bool {
    return span.provenance == .parsed and !span.generated_diagnostic and !span.self_link and
        !span.flags.code and span.role == .normal;
}
fn croatianSpace(span: wiki.Span) bool {
    return croatianMarkerSpan(span) and span.kind == .text and span.target.len == 0 and
        !span.flags.bold and !span.flags.italic and std.mem.trim(u8, span.text, " \t\r\n").len == 0;
}
fn croatianParagraphMarkerSpans(block: wiki.Block) ?[]const wiki.Span {
    if (block.kind != .paragraph) return null;
    const parts = block.flow orelse return block.spans;
    // A leading figure and its following body remain one paragraph. Caption
    // text and nested bidi owners cannot supply this body POS marker.
    if (block.spans.len != 0 or block.figure != null or block.table != null or block.feature != null or
        parts.len != 2 or parts[0].kind != .figure or parts[0].figure == null or
        parts[0].spans.len != 0 or parts[0].scope != null or
        parts[1].kind != .@"inline" or parts[1].figure != null or parts[1].scope != null or
        parts[0].figure.?.map_fallback != null) return null;
    return parts[1].spans;
}
fn croatianParagraphKind(block: wiki.Block) ?[]const u8 {
    const spans = croatianParagraphMarkerSpans(block) orelse return null;
    var label: ?usize = null;
    for (spans, 0..) |span, index| {
        if (!croatianMarkerSpan(span)) return null;
        if (span.kind == .text and span.target.len == 0 and span.flags.bold and !span.flags.italic and
            std.mem.eql(u8, span.text, "definicija:"))
        {
            if (label != null) return null;
            label = index;
        }
    }
    var cursor = (label orelse return null) + 1;
    if (cursor == spans.len or spans[cursor].kind != .line_break) return null;
    cursor += 1;
    while (cursor < spans.len and croatianSpace(spans[cursor])) : (cursor += 1) {}
    if (cursor == spans.len) return null;
    const part_span = spans[cursor];
    if (part_span.kind != .text or part_span.target.len != 0 or !part_span.flags.italic or part_span.flags.bold) return null;
    const kind: []const u8 = if (std.mem.eql(u8, part_span.text, "imenica")) "Noun" else if
        (std.mem.eql(u8, part_span.text, "pridjev")) "Adjective" else return null;
    cursor += 1;
    // The captured noun includes this separate gender label; it is not a sense.
    if (cursor + 1 < spans.len and std.mem.eql(u8, kind, "Noun")) {
        const comma = spans[cursor];
        const gender = spans[cursor + 1];
        if (comma.kind == .text and comma.target.len == 0 and !comma.flags.bold and !comma.flags.italic and
            std.mem.eql(u8, comma.text, ", ") and gender.kind == .text and gender.target.len == 0 and
            gender.flags.italic and !gender.flags.bold and std.mem.eql(u8, gender.text, "ženski rod")) cursor += 2;
    }
    while (cursor < spans.len and croatianSpace(spans[cursor])) : (cursor += 1) {}
    return if (cursor == spans.len) kind else null;
}
fn croatianSynonymBoundary(block: wiki.Block) bool {
    if (block.kind != .paragraph) return false;
    for (block.spans) |span| {
        if (croatianSpace(span)) continue;
        return croatianMarkerSpan(span) and span.kind == .text and span.target.len == 0 and
            span.flags.bold and !span.flags.italic and std.mem.eql(u8, span.text, "sinonimi:");
    }
    return false;
}
// Return the end of an authored (major.minor) label. The label alone is an
// empty source placeholder, not a definition that the Reader should invent.
fn croatianSenseLabel(text: []const u8) ?usize {
    if (text.len < 5 or text[0] != '(') return null;
    var cursor: usize = 1;
    const major = cursor;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {}
    if (cursor == major or cursor == text.len or text[cursor] != '.') return null;
    cursor += 1;
    const minor = cursor;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {}
    if (cursor == minor or cursor == text.len or text[cursor] != ')') return null;
    return cursor + 1;
}
fn croatianSense(block: wiki.Block) ?bool {
    if (block.spans.len == 0) return null;
    const bullet = block.kind == .list_item and std.mem.eql(u8, block.list_path, "*");
    if (!bullet and (block.kind != .indent or !std.mem.eql(u8, block.list_path, ":"))) return null;
    const first = block.spans[0];
    const label = if (croatianMarkerSpan(first) and first.kind == .text and first.target.len == 0)
        croatianSenseLabel(first.text) else null;
    if (!bullet and label == null) return null;
    for (block.spans, 0..) |span, index| {
        // An empty label with only a generated diagnostic, image or citation
        // marker is not a lexical definition. Retain it among support blocks.
        if (span.generated_diagnostic or span.image != null or span.role == .reference or
            std.mem.startsWith(u8, span.target, "#reference-")) continue;
        const visible = if (index == 0 and label != null) span.text[label.?..] else span.text;
        if (std.mem.trim(u8, visible, " \t\r\n").len != 0) return true;
    }
    return false;
}
fn croatianParagraphPart(blocks: []const wiki.Block, owner: ?[]const u8, level: u8) ?MarkedParagraphPart {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or level != 2) return null;
    var marker: ?usize = null;
    var kind: ?[]const u8 = null;
    for (blocks, 0..) |block, index| if (croatianParagraphKind(block)) |name| {
        if (marker != null) return null;
        marker = index;
        kind = name;
    };
    var first = (marker orelse return null) + 1;
    while (first < blocks.len and blocks[first].kind == .blank) : (first += 1) {}
    if (first == blocks.len or !(croatianSense(blocks[first]) orelse false)) return null;
    var end = first;
    while (end < blocks.len) : (end += 1) {
        if (croatianSynonymBoundary(blocks[end])) return .{ .kind = kind.?, .first = first, .end = end, .croatian = true };
        if (blocks[end].kind == .blank) continue;
        _ = croatianSense(blocks[end]) orelse return null;
    }
    return null;
}
// The exact IS -is-nafnorð- template emits this plain marker, followed by
// the authored bold headword. A following contiguous :[n] region supplies
// senses; later tables/labels/sections cannot be borrowed into that region.
fn icelandicPlain(span: wiki.Span) bool {
    return span.provenance == .parsed and !span.generated_diagnostic and !span.self_link and
        span.kind == .text and span.target.len == 0 and span.role == .normal and
        !span.flags.code and !span.flags.italic;
}
fn icelandicNounHeadword(block: wiki.Block) bool {
    if (block.kind != .paragraph or block.spans.len < 2) return false;
    const marker = block.spans[0];
    if (!icelandicPlain(marker) or marker.flags.bold or !std.mem.startsWith(u8, marker.text, "Nafnorð") or
        std.mem.trim(u8, marker.text["Nafnorð".len..], " \t").len != 0) return false;
    var word = false;
    var space = marker.text.len > "Nafnorð".len;
    for (block.spans[1..]) |span| {
        if (!icelandicPlain(span)) return false;
        if (!word) {
            if (std.mem.trim(u8, span.text, " \t").len == 0 and !span.flags.bold) {
                space = true;
                continue;
            }
            if (!space or !span.flags.bold or std.mem.trim(u8, span.text, " \t").len == 0) return false;
            word = true;
        } else if (span.flags.bold) return false;
    }
    return word;
}
fn bracketNumberedMeaning(block: wiki.Block) bool {
    if (block.kind != .indent or !std.mem.eql(u8, block.list_path, ":") or block.spans.len == 0) return false;
    const marker = block.spans[0];
    if (!icelandicPlain(marker) or marker.flags.bold or marker.text.len < 4 or marker.text[0] != '[') return false;
    var cursor: usize = 1;
    while (cursor < marker.text.len and std.ascii.isDigit(marker.text[cursor])) : (cursor += 1) {}
    if (cursor == 1 or cursor + 1 >= marker.text.len or marker.text[cursor] != ']' or
        (marker.text[cursor + 1] != ' ' and marker.text[cursor + 1] != '\t')) return false;
    if (std.mem.trim(u8, marker.text[cursor + 2 ..], " \t\r\n").len != 0) return true;
    for (block.spans[1..]) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return false;
        if (std.mem.trim(u8, span.text, " \t\r\n").len != 0) return true;
    }
    return false;
}
fn icelandicParagraphPart(blocks: []const wiki.Block, owner: ?[]const u8, level: u8) ?MarkedParagraphPart {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or level != 2) return null;
    var marker: ?usize = null;
    for (blocks, 0..) |block, index| if (icelandicNounHeadword(block)) {
        if (marker != null) return null;
        marker = index;
    };
    var first = (marker orelse return null) + 1;
    while (first < blocks.len and blocks[first].kind == .blank) : (first += 1) {}
    if (first == blocks.len or !bracketNumberedMeaning(blocks[first])) return null;
    var end = first + 1;
    while (end < blocks.len) : (end += 1) {
        if (blocks[end].kind == .blank) continue;
        if (!bracketNumberedMeaning(blocks[end])) break;
    }
    return .{ .kind = "Noun", .first = first, .end = end, .bracket_numbered = true };
}
fn analyzeBracketNumberedParagraph(a: A, marker: MarkedParagraphPart, index: usize, etymology: ?usize, blocks: []const wiki.Block) !Lexeme {
    var senses: std.ArrayList(Sense) = .empty;
    var other: std.ArrayList(usize) = .empty;
    const intro = try a.alloc(usize, marker.first);
    for (intro, 0..) |*item, n| item.* = n;
    for (blocks[marker.first..marker.end], marker.first..) |block, b| {
        if (bracketNumberedMeaning(block)) try senses.append(a, .{ .block = b }) else try other.append(a, b);
    }
    for (marker.end..blocks.len) |b| try other.append(a, b);
    return .{ .kind = marker.kind, .section = index, .etymology = etymology, .definitions = try senses.toOwnedSlice(a), .introduction = intro, .other_blocks = try other.toOwnedSlice(a) };
}

// Retained бир authors immediate H4 Мааниси after each exact H3 POS.
// Only that immediate relationship lends POS; synonym/hypernym sections do not.
fn kyrgyzMeaningParent(sections: anytype, index: usize) ?usize {
    if (index == 0) return null;
    const section = sections[index];
    const parent = sections[index - 1];
    if (section.level != 4 or parent.level != 3 or !std.mem.eql(u8, section.title, "Мааниси")) return null;
    if (!std.mem.eql(u8, parent.title, "Сан атооч") and !std.mem.eql(u8, parent.title, "Зат атооч") and
        !std.mem.eql(u8, parent.title, "Тактооч")) return null;
    for (section.blocks) |block| if (block.kind == .definition and std.mem.eql(u8, block.list_path, "#")) return index - 1;
    return null;
}
fn hasKyrgyzMeaningChild(sections: anytype, index: usize) bool {
    if (index + 1 >= sections.len) return false;
    return if (kyrgyzMeaningParent(sections, index + 1)) |parent| parent == index else false;
}
// Калып:мисал p87927/r203647 emits a gray diamond then italic content.
// Preserve the original ## block and list numbering in the stored body; only
// the organization analysis views this proved example as a child of its # sense.
fn kyrgyzExample(block: wiki.Block) bool {
    if (block.kind != .definition or !std.mem.eql(u8, block.list_path, "##") or block.spans.len < 2) return false;
    var marker = false;
    var content = false;
    for (block.spans) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code or span.role != .normal) return false;
        const trimmed = std.mem.trim(u8, span.text, " \t\r\n");
        if (trimmed.len == 0 and span.kind == .text and span.target.len == 0) continue;
        const gray = if (span.foreground) |color| std.mem.eql(u8, color, "#555555") else false;
        if (span.kind == .text and span.target.len == 0 and !span.self_link and
            !span.flags.italic and !span.flags.bold and gray and std.mem.eql(u8, trimmed, "◆"))
        {
            if (marker and !content) return false;
            marker = true;
            content = false;
            continue;
        }
        if (!marker or !span.flags.italic or !gray or span.kind == .line_break) return false;
        content = true;
    }
    return marker and content;
}
fn analyzeKyrgyzMeanings(a: A, kind: []const u8, index: usize, etymology: ?usize, blocks: []const wiki.Block) !Lexeme {
    const projected = try a.dupe(wiki.Block, blocks);
    for (projected) |*block| if (kyrgyzExample(block.*)) {
        block.kind = .example;
        block.list_path = "#:";
    };
    return analyze(a, kind, index, etymology, projected, true);
}

fn idTermClass(classes: []const u8, name: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");
    while (tokens.next()) |token| if (std.mem.eql(u8, token, name)) return true;
    return false;
}
fn idTermSpace(span: wiki.Span) bool {
    return span.kind == .text and span.image == null and span.target.len == 0 and !span.self_link and
        !span.generated_diagnostic and std.mem.trim(u8, span.text, " \t\r\n").len == 0;
}
fn idTermKind(block: wiki.Block) ?[]const u8 {
    if (block.kind != .term or block.depth != 1 or !std.mem.eql(u8, block.list_path, ";") or block.table != null) return null;
    var icon = false;
    var kind: ?[]const u8 = null;
    for (block.spans) |span| {
        if (idTermSpace(span)) continue;
        if (span.provenance != .parsed or span.generated_diagnostic or span.kind != .text or
            span.target.len != 0 or span.self_link or span.role != .normal or @as(u8, @bitCast(span.flags)) != 0) return null;
        if (span.image) |image| {
            if (icon or kind != null or span.text.len != 0 or !idTermClass(span.classes, "section-header-img") or
                !std.mem.eql(u8, image.file, "Codex icon tag color-progressive.svg") or image.width_px != 12) return null;
            icon = true;
        } else {
            if (!icon or kind != null) return null;
            const label = std.mem.trim(u8, span.text, " \t\r\n");
            kind = if (std.mem.eql(u8, label, "Nomina")) "Noun" else if (std.mem.eql(u8, label, "Adjektiva")) "Adjective" else return null;
        }
    }
    return if (icon) kind else null;
}
fn idDefinitionRequest(block: wiki.Block) bool {
    if (block.kind != .definition or block.depth != 1 or !std.mem.eql(u8, block.list_path, "#") or block.spans.len != 9) return false;
    const texts = [_][]const u8{
        "Definisi dari istilah ini memerlukan penerangan lebih lanjut. Tolong bantu ",
        "tambahkan definisinya", ", kemudian hapus teks", " ", "{", "{", "rfdef", "}}", ".",
    };
    for (block.spans, texts, 0..) |span, text, index| {
        if (!std.mem.eql(u8, span.text, text) or span.generated_diagnostic or span.self_link or span.image != null or
            span.role != .normal) return false;
        const Flags = @TypeOf(span.flags);
        const flags: Flags = if (index < 3) .{ .italic = true, .bold = index == 1 } else if (index >= 4 and index <= 7) .{ .code = true } else .{};
        if (!std.meta.eql(flags, span.flags)) return false;
        if (index == 6) {
            if (span.kind != .link or !std.mem.eql(u8, span.target, "Templat:rfdef") or span.provenance != .parsed) return false;
        } else {
            if (span.kind != .text or span.target.len != 0) return false;
            if (index == 5) {
                if (span.provenance != .entity_literal) return false;
            } else if (index == 7) {
                if (span.provenance != .protected_literal) return false;
            } else if (span.provenance != .parsed) return false;
        }
    }
    return true;
}
// Retained ID rampai's -n-/-adj- -> -subjudul- role emits this root term
// beneath a typed headword H3. Its source switch names POS, never an owner.
fn idTermParagraphPart(blocks: []const wiki.Block, owner: ?[]const u8, level: u8) ?MarkedParagraphPart {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or level != 3 or blocks.len < 3 or
        blocks[0].kind != .heading or blocks[0].level != 3 or blocks[0].depth != 0 or blocks[0].list_path.len != 0) return null;
    var headword = false;
    for (blocks[0].spans) |span| {
        if (idTermSpace(span)) continue;
        const code_bracket = span.provenance == .entity_literal and span.kind == .text and span.flags.subscript and
            span.target.len == 0 and !span.self_link and (std.mem.eql(u8, span.text, "[") or std.mem.eql(u8, span.text, "]"));
        if ((span.provenance != .parsed and !code_bracket) or span.generated_diagnostic or span.image != null or span.flags.code or
            span.role != .normal or !idTermClass(span.classes, "headword-text")) return null;
        if (span.kind == .text and !span.flags.subscript and span.target.len == 0 and !span.self_link) headword = true;
    }
    if (!headword) return null;
    var marker: ?usize = null;
    var kind: ?[]const u8 = null;
    for (blocks, 0..) |block, index| if (idTermKind(block)) |value| {
        if (marker != null) return null;
        marker = index; kind = value;
    };
    const start = marker orelse return null;
    for (blocks[1..start]) |block| if (block.kind == .definition or block.kind == .term) return null;
    const first = start + 1;
    var end = first;
    while (end < blocks.len and blocks[end].kind != .term and blocks[end].kind != .heading) : (end += 1) {
        // A damaged or altered request is not evidence for a supplied meaning.
        if (blocks[end].kind == .definition and blocks[end].spans.len != 0 and
            std.mem.startsWith(u8, blocks[end].spans[0].text, "Definisi dari istilah ini memerlukan penerangan lebih lanjut.") and
            !idDefinitionRequest(blocks[end])) return null;
    }
    if (end == first) return null;
    return .{ .kind = kind.?, .first = first, .end = end, .id_term = true };
}

// Retained DE estroncio declares Wortart|Substantiv|Portugiesisch plus m.
// The linked H3 and the following Bedeutungen marker identify lexical kind
// and its numbered sense region; they never supply the record's language.
fn germanNounMeanings(section: anytype, owner: ?[]const u8) ?MarkedParagraphPart {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.level != 3 or section.title_depth != 0 or
        section.title_list_path.len != 0 or !std.mem.eql(u8, section.title, "Substantiv, m")) return null;
    var noun = false;
    for (section.title_spans) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or
            span.image != null or span.flags.code or span.role != .normal) return null;
        if (span.kind == .link) {
            if (noun or !std.mem.eql(u8, span.text, "Substantiv") or
                !std.mem.eql(u8, span.target, "Hilfe:Wortart#Substantiv")) return null;
            noun = true;
        } else if (span.kind != .text or span.target.len != 0) return null;
    }
    if (!noun) return null;
    var marker: ?usize = null;
    for (section.blocks, 0..) |block, index| {
        if (block.kind != .paragraph or block.depth != 0 or block.list_path.len != 0 or block.spans.len != 1) continue;
        const span = block.spans[0];
        if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or
            span.kind != .text or span.target.len != 0 or span.image != null or span.role != .normal or
            !span.flags.bold or span.flags.italic or span.flags.code or !std.mem.eql(u8, span.text, "Bedeutungen:")) continue;
        if (marker != null) return null;
        marker = index;
    }
    var first = (marker orelse return null) + 1;
    while (first < section.blocks.len and section.blocks[first].kind == .blank) : (first += 1) {}
    if (first == section.blocks.len or !bracketNumberedMeaning(section.blocks[first])) return null;
    var end = first + 1;
    while (end < section.blocks.len) : (end += 1) {
        if (section.blocks[end].kind == .blank) continue;
        if (!bracketNumberedMeaning(section.blocks[end])) break;
    }
    return .{ .kind = "Noun", .first = first, .end = end, .bracket_numbered = true };
}

// BEW -n-/-adj- call S|def with explicit POS; the retained S switch emits
// this icon and label below Modul:head's H3. None of these supplies an owner.
fn bewTermParagraphPart(blocks: []const wiki.Block, owner: ?[]const u8, level: u8) ?MarkedParagraphPart {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or level != 3 or blocks.len < 3) return null;
    const heading = blocks[0];
    if (heading.kind != .heading or heading.level != 3 or heading.depth != 0 or heading.list_path.len != 0 or heading.table != null or heading.flow != null) return null;
    var headword = false;
    var subscript = false;
    for (heading.spans) |span| {
        if (idTermSpace(span)) continue;
        const bracket = span.provenance == .entity_literal and span.flags.subscript and
            (std.mem.eql(u8, span.text, "[") or std.mem.eql(u8, span.text, "]"));
        if ((span.provenance != .parsed and !bracket) or span.generated_diagnostic or span.kind != .text or
            span.target.len != 0 or span.self_link or span.image != null or span.flags.code or span.role != .normal) return null;
        if (span.flags.subscript) subscript = true else headword = true;
    }
    if (!headword or !subscript) return null;
    const term = blocks[1];
    if (term.kind != .term or term.depth != 1 or !std.mem.eql(u8, term.list_path, ";") or term.table != null or term.flow != null) return null;
    var icon = false;
    var kind: ?[]const u8 = null;
    for (term.spans) |span| {
        if (idTermSpace(span)) continue;
        if (span.provenance != .parsed or span.generated_diagnostic or span.kind != .text or span.target.len != 0 or
            span.self_link or span.role != .normal or @as(u8, @bitCast(span.flags)) != 0) return null;
        if (span.image) |image| {
            if (icon or kind != null or span.text.len != 0 or !idTermClass(span.classes, "section-header-img") or
                !std.mem.eql(u8, image.file, "OOjs UI icon tag-ltr-progressive.svg") or image.width_px != 12 or
                image.height_px != null or image.border or image.map != null) return null;
            icon = true;
        } else {
            if (!icon or kind != null) return null;
            const label = std.mem.trim(u8, span.text, " \t\r\n");
            kind = if (std.mem.eql(u8, label, "Kata peada")) "Noun" else if (std.mem.eql(u8, label, "Kata penyipat")) "Adjective" else return null;
        }
    }
    if (!icon or kind == null) return null;
    const sense = blocks[2];
    if (sense.kind != .definition or sense.depth != 1 or !std.mem.eql(u8, sense.list_path, "#") or sense.table != null or sense.flow != null) return null;
    var visible = false;
    for (sense.spans) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code or span.image != null or span.role != .normal) return null;
        visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
    }
    if (!visible) return null;
    var end: usize = 3;
    while (end < blocks.len and blocks[end].kind != .term and blocks[end].kind != .heading) : (end += 1) {}
    return .{ .kind = kind.?, .first = 2, .end = end };
}

fn markedParagraphPart(blocks: []const wiki.Block, owner: ?[]const u8, level: u8) ?MarkedParagraphPart {
    return sloveneParagraphPart(blocks, owner, level) orelse croatianParagraphPart(blocks, owner, level) orelse icelandicParagraphPart(blocks, owner, level) orelse idTermParagraphPart(blocks, owner, level) orelse bewTermParagraphPart(blocks, owner, level);
}
fn analyzeCroatianParagraph(a: A, marker: MarkedParagraphPart, index: usize, etymology: ?usize, blocks: []const wiki.Block) !Lexeme {
    var senses: std.ArrayList(Sense) = .empty;
    var other: std.ArrayList(usize) = .empty;
    const intro = try a.alloc(usize, marker.first);
    for (intro, 0..) |*item, n| item.* = n;
    for (blocks[marker.first..marker.end], marker.first..) |block, b| {
        if (croatianSense(block) orelse false) try senses.append(a, .{ .block = b }) else try other.append(a, b);
    }
    for (marker.end..blocks.len) |b| try other.append(a, b);
    return .{ .kind = marker.kind, .section = index, .etymology = etymology, .definitions = try senses.toOwnedSlice(a), .introduction = intro, .other_blocks = try other.toOwnedSlice(a) };
}

fn offsetBlockIndices(a: A, indices: []const usize, offset: usize) ![]const usize {
    const result = try a.dupe(usize, indices);
    for (result) |*index| index.* += offset;
    return result;
}
fn analyzeMarkedParagraph(a: A, marker: MarkedParagraphPart, index: usize, etymology: ?usize, blocks: []const wiki.Block) !Lexeme {
    if (marker.croatian) return analyzeCroatianParagraph(a, marker, index, etymology, blocks);
    if (marker.bracket_numbered) return analyzeBracketNumberedParagraph(a, marker, index, etymology, blocks);
    const selected = if (marker.id_term) selected: {
        const projected = try a.dupe(wiki.Block, blocks[marker.first..marker.end]);
        for (projected) |*block| if (idDefinitionRequest(block.*)) {
            block.kind = .paragraph;
            block.list_path = "";
        };
        break :selected projected;
    } else blocks[marker.first..marker.end];
    var lexical = try analyze(a, marker.kind, index, etymology, selected, false);
    const senses = try a.dupe(Sense, lexical.definitions);
    for (senses) |*sense| {
        sense.block += marker.first;
        sense.examples = try offsetBlockIndices(a, sense.examples, marker.first);
        sense.quotations = try offsetBlockIndices(a, sense.quotations, marker.first);
        sense.notes = try offsetBlockIndices(a, sense.notes, marker.first);
        // parent is a sense index, not a block index, and must not be shifted.
    }
    lexical.definitions = senses;
    const intro = try a.alloc(usize, marker.first + lexical.introduction.len);
    for (intro[0..marker.first], 0..) |*item, n| item.* = n;
    for (lexical.introduction, intro[marker.first..]) |item, *out| out.* = item + marker.first;
    lexical.introduction = intro;
    const other = try a.alloc(usize, lexical.other_blocks.len + blocks.len - marker.end);
    for (lexical.other_blocks, other[0..lexical.other_blocks.len]) |item, *out| out.* = item + marker.first;
    for (other[lexical.other_blocks.len..], marker.end..) |*item, n| item.* = n;
    lexical.other_blocks = other;
    return lexical;
}

// Retained CS homosexuál p6652/r1354217 authors this H3 noun and H4
// meaning scope. Keep its Czech kind and the independently supplied owner;
// support headings and literal/list-nested heading text grant no sense scope.
fn czechMeaningHeading(section: anytype) bool {
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return false;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len == 0) return false;
    for (section.title_spans) |span| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.kind != .text or
            span.target.len != 0 or span.self_link or span.image != null or span.flags.code) return false;
    }
    return true;
}
fn czechMeaningParent(sections: anytype, index: usize, owner: ?[]const u8) ?usize {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified")) return null;
    const section = sections[index];
    if (section.level != 4 or !std.mem.eql(u8, section.title, "význam") or
        !czechMeaningHeading(section)) return null;
    const direct_sense = for (section.blocks) |block| {
        if (block.kind != .definition or !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) continue;
        var visible = false;
        for (block.spans) |span| {
            // Cite markers are the existing typed protected action, not lexical
            // text. They may accompany a sense but cannot establish one alone.
            if (span.provenance == .protected_literal and span.kind == .link and
                span.role == .reference and span.flags.superscript and !span.generated_diagnostic and
                std.mem.startsWith(u8, span.target, "#reference-") and span.target.len > "#reference-".len)
            {
                const numeric = for (span.target["#reference-".len..]) |digit| {
                    if (!std.ascii.isDigit(digit)) break false;
                } else true;
                if (numeric) continue;
            }
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) break;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        } else if (visible) break true;
    } else false;
    if (!direct_sense) return null;
    var previous = index;
    while (previous > 0) {
        previous -= 1;
        const parent = sections[previous];
        if (parent.level >= section.level) continue;
        return if (parent.level == 3 and std.mem.eql(u8, parent.title, "podstatné jméno") and
            czechMeaningHeading(parent)) previous else null;
    }
    return null;
}

// These retained SK pages put senses in an immediate Význam child of the
// Podstatné meno section. Keep that child's block addresses and the supplied
// owner; same-level support sections cannot become senses themselves.
fn slovakMeaningParent(sections: anytype, index: usize) ?usize {
    const section = sections[index];
    if (section.level != 4 or !std.mem.eql(u8, section.title, "Význam")) return null;
    const has_senses = for (section.blocks) |block| {
        if (block.kind == .definition) break true;
    } else false;
    if (!has_senses) return null;
    var previous = index;
    while (previous > 0) {
        previous -= 1;
        const parent = sections[previous];
        if (parent.level >= section.level) continue;
        return if (parent.level == 3 and std.mem.eql(u8, parent.title, "Podstatné meno")) previous else null;
    }
    return null;
}
fn hasSlovakMeaningChild(sections: anytype, index: usize) bool {
    if (sections[index].level != 3 or !std.mem.eql(u8, sections[index].title, "Podstatné meno")) return false;
    var child = index + 1;
    while (child < sections.len and sections[child].level > sections[index].level) : (child += 1) {
        if (slovakMeaningParent(sections, child)) |parent| if (parent == index) return true;
    }
    return false;
}

// Exact authored kinds, without guessing an English POS or language. The
// retained ET -'d p111377/r936737 uses four numbered form sections and Morfeem;
// Mall:-tegusõnavorm- p24234/r484850 independently declares the form heading.
// MG Endrika:-fomba fiteny- p1265960/r3477595 supplies the existing lexical kind.
fn authoredLexicalKind(title: []const u8) ?[]const u8 {
    for ([_][]const u8{ "Fomba fiteny", "Tegusõnavorm", "Morfeem" }) |name|
        if (std.mem.eql(u8, title, name)) return name;
    const prefix = "Tegusõnavorm (";
    if (!std.mem.startsWith(u8, title, prefix) or !std.mem.endsWith(u8, title, ")")) return null;
    const number = title[prefix.len .. title.len - 1];
    if (number.len == 0 or number[0] == '0') return null;
    for (number) |digit| if (!std.ascii.isDigit(digit)) return null;
    return "Tegusõnavorm";
}

// Only an independently owned, source-shaped entry with a parsed bold
// headword and immediate direct definition lends its authored lexical kind.
fn ownedAuthoredLexicalPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or section.level != 3) return null;
    const kind = authoredLexicalKind(section.title) orelse return null;
    var headword = false;
    for (section.blocks) |block| {
        if (block.kind == .heading) {
            if (headword) return null;
            continue;
        }
        if (block.kind == .blank) continue;
        if (!headword) {
            if (block.kind != .paragraph or block.spans.len == 0) return null;
            var visible = false;
            for (block.spans) |span| {
                if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or
                    span.kind != .text or span.target.len != 0 or span.role != .normal or span.flags.code) return null;
                if (std.mem.trim(u8, span.text, " \t\r\n").len != 0) {
                    if (!span.flags.bold) return null;
                    visible = true;
                }
            }
            if (!visible) return null;
            headword = true;
            continue;
        }
        if (block.kind != .definition or !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) kind else null;
    }
    return null;
}

// Шаблон:Глагол p1418/r1147143 declares this lexical heading and its
// grammar-type link before the ЗНАЧЕНИЕ slot. Retain the authored kind;
// neither the template name nor the unresolved aspect supplies an owner.
fn ownedBulgarianVerbPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "Unclassified") or section.level != 3) return null;
    const prefix = "Глагол, тип ";
    const suffix = ", {{{ВИД}}}";
    if (!std.mem.startsWith(u8, section.title, prefix) or !std.mem.endsWith(u8, section.title, suffix)) return null;
    const number = section.title[prefix.len .. section.title.len - suffix.len];
    if (number.len == 0 or number[0] == '0') return null;
    for (number) |digit| if (!std.ascii.isDigit(digit)) return null;
    if (section.blocks.len == 0) return null;
    const heading = section.blocks[0];
    if (heading.kind != .heading or heading.level != 3 or heading.depth != 0 or
        heading.list_path.len != 0 or heading.spans.len < 3) return null;
    const first = heading.spans[0];
    if (first.provenance != .parsed or first.generated_diagnostic or first.self_link or first.image != null or
        first.kind != .text or first.target.len != 0 or first.role != .normal or first.flags.code or
        !std.mem.eql(u8, first.text, "Глагол, ")) return null;
    const grammar = heading.spans[1];
    const target_prefix = "Уикиречник:Български/Типове думи/";
    if (grammar.provenance != .parsed or grammar.generated_diagnostic or grammar.self_link or grammar.image != null or
        grammar.kind != .link or grammar.role != .normal or grammar.flags.code or !grammar.flags.italic or
        !std.mem.startsWith(u8, grammar.target, target_prefix) or
        !std.mem.eql(u8, grammar.target[target_prefix.len..], number) or
        !std.mem.startsWith(u8, grammar.text, "тип ") or !std.mem.eql(u8, grammar.text["тип ".len..], number)) return null;
    // This unresolved suffix remains display data. Parsed and nowiki-preserved
    // literal versions are equivalent; it contributes no lexical authority.
    var used: usize = 0;
    for (heading.spans[2..]) |span| {
        if (span.generated_diagnostic or span.self_link or span.image != null or span.kind != .text or
            span.target.len != 0 or span.role != .normal or span.flags.code or !span.flags.italic or
            !std.mem.startsWith(u8, suffix[used..], span.text)) return null;
        used += span.text.len;
    }
    return if (used == suffix.len) "Глагол" else null;
}

// Retained mişk p878/r6642854 and Persian نصیب p27948/r6445461 both
// author H3 Navdêr, call navdêr with their respective language code and
// expand to a headword plus matching localized noun category. The noun
// role belongs to this parsed heading, independently of the supplied owner.
// Retain the direct-sense proof; this rule never creates a language owner.
fn ownedNavderNounPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (language.len == 0 or section.level != 3 or
        !std.mem.eql(u8, section.title, "Navdêr")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1) return null;
    const heading = section.title_spans[0];
    if (heading.provenance != .parsed or heading.generated_diagnostic or heading.self_link or
        heading.kind != .text or heading.target.len != 0 or heading.image != null or
        heading.flags.code or !std.mem.eql(u8, std.mem.trim(u8, heading.text, " \t"), "Navdêr")) return null;
    // Figures, sister-project prose and the headword precede the meanings in
    // this section. Only an ordinary direct definition supplies sense evidence.
    for (section.blocks) |block| {
        if (block.kind != .definition) continue;
        if (block.depth != 1 or !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) "Noun" else null;
    }
    return null;
}

// Retained FA hesabdari p44688/r777069 authors فارسی, this H3, three
// direct definitions and the اسم‌های فارسی category. Scope the noun kind
// to its existing Persian owner. The normal selected registry canonicalizes
// فارسی to Persian; neither spelling creates an owner. Urdu has separate proof.
fn ownedPersianNounPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if ((!std.mem.eql(u8, language, "فارسی") and !std.mem.eql(u8, language, "Persian")) or section.level != 3 or
        !std.mem.eql(u8, section.title, "اسم")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1) return null;
    const heading = section.title_spans[0];
    if (heading.provenance != .parsed or heading.generated_diagnostic or heading.self_link or
        heading.kind != .text or heading.target.len != 0 or heading.image != null or
        heading.flags.code or !std.mem.eql(u8, std.mem.trim(u8, heading.text, " \t"), "اسم")) return null;
    for (section.blocks) |block| {
        if (block.kind == .blank) continue;
        if (block.kind != .definition or block.depth != 1 or
            !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) "Noun" else null;
    }
    return null;
}

// Retained TR sadaka-i cariye authors Ad and invokes tr-ad p441277/r2933313,
// whose tr-başlıkbaşı p443668/r5827701 route declares adlar, nominal cases
// and plural forms. A short label cannot establish an owner: require the
// independently resolved Turkish record and its parsed Turkish headword.
fn ownedTurkishNounPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (!std.mem.eql(u8, language, "Türkçe") or section.level != 3 or
        !std.mem.eql(u8, section.title, "Ad")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1) return null;
    const heading = section.title_spans[0];
    if (heading.provenance != .parsed or heading.generated_diagnostic or heading.self_link or
        heading.kind != .text or heading.target.len != 0 or heading.image != null or
        heading.flags.code or !std.mem.eql(u8, heading.text, "Ad")) return null;
    var headword = false;
    for (section.blocks) |block| {
        if (block.kind == .blank) continue;
        if (!headword) {
            if (block.kind != .paragraph or block.depth != 0 or block.list_path.len != 0) return null;
            var visible = false;
            for (block.spans) |span| {
                if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code or span.image != null) return null;
                if (span.role == .headword) {
                    if (!span.flags.bold or !std.mem.eql(u8, span.language, "tr") or
                        (span.kind != .text and span.kind != .link)) return null;
                    visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
                }
            }
            if (!visible) return null;
            headword = true;
            continue;
        }
        if (block.kind != .definition or block.depth != 1 or
            !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) "Noun" else null;
    }
    return null;
}

// RW mudasobwa p1596/r13256 authors Izina above infl|rw|izina. The same
// input's -izina- p1943/r13277 emits this noun heading: nome p2274/r12882
// and nom p2281/r12883 pair it with explicit it/pt/fr noun inflections.
// Require the independent Ikinyarwanda owner and the retained ordinary bold
// headword/direct definition shape; the label never supplies a language.
fn ownedKinyarwandaNounPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (!std.mem.eql(u8, language, "Ikinyarwanda") or section.level != 3 or
        !std.mem.eql(u8, section.title, "Izina")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1) return null;
    const heading = section.title_spans[0];
    if (heading.provenance != .parsed or heading.generated_diagnostic or heading.self_link or
        heading.kind != .text or heading.target.len != 0 or heading.image != null or
        heading.flags.code or !std.mem.eql(u8, heading.text, "Izina")) return null;
    var headword = false;
    for (section.blocks) |block| {
        if (block.kind == .blank) continue;
        if (!headword) {
            if (block.kind != .paragraph or block.depth != 0 or block.list_path.len != 0) return null;
            if (block.spans.len != 1) return null;
            const word = block.spans[0];
            if (word.provenance != .parsed or word.generated_diagnostic or word.self_link or
                word.kind != .text or word.target.len != 0 or word.image != null or
                word.role != .normal or word.language.len != 0 or word.flags.code or !word.flags.bold or
                std.mem.trim(u8, word.text, " \t\r\n").len == 0) return null;
            headword = true;
            continue;
        }
        if (block.kind != .definition or block.depth != 1 or
            !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) "Noun" else null;
    }
    return null;
}

// SD اِندري p1644/r13692 authors this H3 and sd-اسم-قاعدو2
// p1679/r20815, with سنڌي اسم مونث -> سنڌي اسم noun categories.
// Require its independently resolved Sindhi owner, physical heading, ordinary
// bold lemma and direct definition. Other owners and compound labels stay separate.
fn ownedSindhiNounPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (!std.mem.eql(u8, language, "Sindhi") or section.level != 3 or
        !std.mem.eql(u8, section.title, "اسم")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1) return null;
    const heading = section.title_spans[0];
    if (heading.provenance != .parsed or heading.generated_diagnostic or heading.self_link or
        heading.kind != .text or heading.target.len != 0 or heading.image != null or
        heading.flags.code or !std.mem.eql(u8, heading.text, "اسم")) return null;
    var headword = false;
    for (section.blocks) |block| {
        if (block.kind == .blank) continue;
        if (!headword) {
            if (block.kind != .paragraph or block.depth != 0 or block.list_path.len != 0) return null;
            if (block.spans.len == 0) return null;
            const word = block.spans[0];
            if (word.provenance != .parsed or word.generated_diagnostic or word.self_link or
                word.kind != .text or word.target.len != 0 or word.image != null or
                word.role != .normal or word.language.len != 0 or word.flags.code or !word.flags.bold or
                std.mem.trim(u8, word.text, " \t\r\n").len == 0) return null;
            // The captured inflection follows the ordinary bold lemma with
            // a plural label and bold link. These remain body data, not owner proof.
            for (block.spans[1..]) |span| {
                if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code or span.image != null or
                    span.role != .normal or (span.kind != .text and span.kind != .link)) return null;
            }
            headword = true;
            continue;
        }
        if (block.kind != .definition or block.depth != 1 or
            !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) "Noun" else null;
    }
    return null;
}

// Retained UR p19170/r35943 authors this physical noun heading and invokes
// ur-noun p18859/r112640 (head|ur|اسما). The selected registry independently
// supplies اردو; neither the heading nor a language-bearing span creates it.
fn ownedUrduNounPart(section: anytype, owner: ?[]const u8) ?[]const u8 {
    const language = owner orelse return null;
    if (!std.mem.eql(u8, language, "اردو") or section.level != 3 or
        !std.mem.eql(u8, section.title, "اسم")) return null;
    const S = @TypeOf(section);
    if (!@hasField(S, "is_heading") or !@hasField(S, "title_depth") or
        !@hasField(S, "title_list_path") or !@hasField(S, "title_spans")) return null;
    if (!section.is_heading or section.title_depth != 0 or section.title_list_path.len != 0 or
        section.title_spans.len != 1) return null;
    const heading = section.title_spans[0];
    if (heading.provenance != .parsed or heading.generated_diagnostic or heading.self_link or
        heading.kind != .text or heading.target.len != 0 or heading.image != null or
        heading.flags.code or !std.mem.eql(u8, std.mem.trim(u8, heading.text, " \t"), "اسم")) return null;
    var headword = false;
    for (section.blocks) |block| {
        if (block.kind == .blank) continue;
        if (!headword) {
            if (block.kind != .paragraph or block.depth != 0 or block.list_path.len != 0) return null;
            var seen = false;
            for (block.spans) |span| {
                if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code or span.image != null) return null;
                if (span.role == .headword) {
                    if (!span.flags.bold or !std.mem.eql(u8, span.language, "ur") or
                        (span.kind != .text and span.kind != .link)) return null;
                    seen = seen or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
                } else {
                    // The template's optional gender is body data, not POS or
                    // owner authority. Only its plain annotation/spacing may
                    // accompany the independently marked headword paragraph.
                    if (span.kind != .text or span.target.len != 0 or span.role != .normal or
                        (std.mem.trim(u8, span.text, " \t\r\n\xc2\xa0").len != 0 and
                        !std.mem.eql(u8, span.classes, "gender"))) return null;
                }
            }
            if (!seen) return null;
            headword = true;
            continue;
        }
        if (block.kind != .definition or block.depth != 1 or
            !std.mem.eql(u8, block.list_path, "#") or block.spans.len == 0) return null;
        var visible = false;
        for (block.spans) |span| {
            if (span.provenance != .parsed or span.generated_diagnostic or span.flags.code) return null;
            visible = visible or std.mem.trim(u8, span.text, " \t\r\n").len != 0;
        }
        return if (visible) "Noun" else null;
    }
    return null;
}

// The retained page explicitly says its meaning has not been entered. Keep
// that exact italic instruction (including bold edit action text) as body,
// rather than manufacture a sense from its authored list marker.
fn bulgarianMissingMeaning(block: wiki.Block) bool {
    if (block.kind != .definition or !std.mem.eql(u8, block.list_path, "#") or block.spans.len != 3) return false;
    const parts = [_][]const u8{
        "Значението на думата все още не е въведено. Можете да го добавите, както и да попълните част от останалата липсваща информация, като щракнете на ",
        "редактиране", ".",
    };
    for (block.spans, parts, 0..) |span, text, index| {
        if (span.provenance != .parsed or span.generated_diagnostic or span.self_link or span.image != null or
            span.kind != .text or span.target.len != 0 or span.role != .normal or span.flags.code or
            !span.flags.italic or span.flags.bold != (index == 1) or !std.mem.eql(u8, span.text, text)) return false;
    }
    return true;
}
fn analyzeBulgarianVerb(a: A, kind: []const u8, index: usize, etymology: ?usize, blocks: []const wiki.Block) !Lexeme {
    const projected = try a.dupe(wiki.Block, blocks);
    for (projected) |*block| if (bulgarianMissingMeaning(block.*)) {
        block.kind = .paragraph;
        block.list_path = "";
        block.depth = 0;
    };
    return analyze(a, kind, index, etymology, projected, false);
}

// Exact localized semantic heading plus an optional canonical positive number.
// This is an organization label, never a language or part-of-speech declaration.
fn exactNumberedHeading(title: []const u8, label: []const u8) bool {
    if (std.mem.eql(u8, title, label)) return true;
    if (title.len <= label.len + 1 or !std.mem.startsWith(u8, title, label) or title[label.len] != ' ') return false;
    const number = title[label.len + 1 ..];
    if (number[0] < '1' or number[0] > '9') return false;
    for (number[1..]) |digit| if (!std.ascii.isDigit(digit)) return false;
    return true;
}

fn buildInContext(a: A, sections: anytype, unclassified: bool, owner: ?[]const u8) !Layout {
    var lexemes: std.ArrayList(Lexeme) = .empty;
    var other: std.ArrayList(usize) = .empty;
    var origin: ?usize = null;
    var current_language: []const u8 = owner orelse "";
    var active: ?usize = null;
    var active_level: u8 = 0;
    var related: std.ArrayList(usize) = .empty;
    var lemma_parent: ?struct { level: u8, kind: []const u8 } = null;
    for (sections, 0..) |section, i| {
        const declared_kind = if (unclassified and section.level == 2) null else partOfSpeech(section.title);
        const grammar_kind = if (unclassified) null else ownedBulgarianVerbPart(section, owner);
        const named_kind = declared_kind orelse grammar_kind orelse if (unclassified) null else
            ownedKinyarwandaNounPart(section, owner) orelse ownedTurkishNounPart(section, owner) orelse ownedUrduNounPart(section, owner) orelse ownedPersianNounPart(section, owner) orelse ownedSindhiNounPart(section, owner) orelse ownedNavderNounPart(section, owner) orelse ownedAuthoredLexicalPart(section, owner) orelse teluguGrammarMeaningPart(sections, i, owner) orelse morphologySiblingPart(sections, i, owner) orelse
            (if (active == null) ukrainianMorphologyMeaningPart(sections, i, owner) else null);
        const paragraph_part = if (named_kind == null and !unclassified) germanNounMeanings(section, owner) orelse markedParagraphPart(section.blocks, owner, section.level) else null;
        const own_kind: ?[]const u8 = named_kind orelse if (paragraph_part) |marker| marker.kind else null;
        const lemma = std.mem.eql(u8, section.title, "Lemma") or std.mem.eql(u8, section.title, "Neet-lemma");
        const czech_parent = if (own_kind == null) czechMeaningParent(sections, i, owner) else null;
        const meaning_parent = if (own_kind == null) slovakMeaningParent(sections, i) orelse kyrgyzMeaningParent(sections, i) else null;
        const nested_kind: ?[]const u8 = if (czech_parent) |parent| sections[parent].title else if (meaning_parent) |parent| partOfSpeech(sections[parent].title) else if (own_kind == null) nested: {
            const parent = lemma_parent orelse break :nested null;
            break :nested if (lemma and section.level > parent.level and section.level - parent.level == 1) parent.kind else null;
        } else null;
        const kind = own_kind orelse nested_kind;
        // Parsed morphology/paragraph evidence is scoped to its own section.
        // Only an authored POS heading can lend its kind to adjacent immediate
        // Lemma/Neet-lemma children; other/deeper/owner boundaries end that scope.
        if (declared_kind) |declared| {
            lemma_parent = .{ .level = section.level, .kind = declared };
        } else if (nested_kind == null) lemma_parent = null;
        // Modèl:-etim- p1091/r219080 emits this exact localized heading.
        // Exact MY source heading for inherited/derived material in retained
        // p2617/r939601 and origin statements in p122417/r905431,p124492/r907881.
        // BR Patrom:-etim- p1929/r381015 emits Gerdarzh (Orin hag istor),
        // called by laezh-glas p46208/r382620 and reoliek p46674/r238569.
        // TL abaka p1085/r164102 and aba p1084/r176826 author this heading;
        // aba's second region invokes inh+ (Module:etymology/templates).
        // RO Format:-etimologie- p4992/r324908 emits this exact H3; casă invokes it twice.
        const etymology = std.mem.eql(u8, section.title, "Etimologie") or exactNumberedHeading(section.title, "Etimolohiya") or part.named(section.title, "Etymology") or std.mem.eql(u8, section.title, "Etimologia") or std.mem.eql(u8, section.title, "Etimología") or std.mem.eql(u8, section.title, "ရင်းမြစ်") or std.mem.eql(u8, section.title, "Gerdarzh");
        // Owned records can contain several H1 source regions. A recognized H2
        // POS belongs to the preceding etymology, but a new region cannot inherit it.
        if (owner != null and section.level == 1) origin = null;
        if (section.level == 2) {
            if (owner == null or kind == null or paragraph_part != null) origin = null;
            if (owner == null and !unclassified and kind == null and !etymology) current_language = section.title;
        }
        if (active) |previous| {
            if (kind == null and !etymology and section.level > active_level) {
                try related.append(a, i);
                continue;
            }
            lexemes.items[previous].related_sections = try related.toOwnedSlice(a);
            active = null;
        }
        if (etymology) origin = i;
        if (kind) |name| {
            // Preserve parent body addresses without duplicating an empty POS
            // lexeme whose explicit child contains the actual senses.
            const next_is_lemma = if (i + 1 < sections.len) child: {
                const following = sections[i + 1];
                if (!(following.level > section.level and following.level - section.level == 1 and
                    (std.mem.eql(u8, following.title, "Lemma") or std.mem.eql(u8, following.title, "Neet-lemma")))) break :child false;
                // An independently classified child does not borrow this POS.
                const following_named: ?[]const u8 = if (unclassified and following.level == 2) null else
                    partOfSpeech(following.title) orelse if (unclassified) null else morphologySiblingPart(sections, i + 1, owner);
                const following_paragraph = if (following_named == null and !unclassified)
                    markedParagraphPart(following.blocks, owner, following.level) else null;
                break :child following_named == null and following_paragraph == null;
            } else false;
            const has_senses = for (section.blocks, 0..) |block, block_index| {
                if (lexicalDefinition(block, declared_kind != null) or numberedDefinitionDetail(section.blocks, block_index, declared_kind != null)) break true;
            } else false;
            const meaningful_child = hasSlovakMeaningChild(sections, i) or hasKyrgyzMeaningChild(sections, i);
            if (declared_kind != null and (next_is_lemma or meaningful_child) and !has_senses) {
                try other.append(a, i);
                continue;
            }
            active = lexemes.items.len;
            active_level = if (nested_kind != null) section.level - 1 else section.level;
            var lexical = if (paragraph_part) |marker|
                try analyzeMarkedParagraph(a, marker, i, origin, section.blocks)
            else if (grammar_kind != null)
                try analyzeBulgarianVerb(a, name, i, origin, section.blocks)
            else if (kyrgyzMeaningParent(sections, i) != null)
                try analyzeKyrgyzMeanings(a, name, i, origin, section.blocks)
            else
                try analyze(a, name, i, origin, section.blocks, declared_kind != null or (nested_kind != null and czech_parent == null));
            lexical.language = current_language;
            try lexemes.append(a, lexical);
        } else try other.append(a, i);
    }
    if (active) |previous| lexemes.items[previous].related_sections = try related.toOwnedSlice(a);
    return .{ .lexemes = try lexemes.toOwnedSlice(a), .other_sections = try other.toOwnedSlice(a) };
}
const ControlledFigureFixture = struct {
    const T = @import("blob_encoder").presentation_types;
    const Ns = @import("namespace_registry").Registry;
    file: []const u8,
    width: u32,
    fn resolve(raw: ?*const anyopaque, _: std.mem.Allocator, file: []const u8, format_value: T.FigureFormat, width: ?u32, height: ?u32) std.mem.Allocator.Error!?T.FigureSizingPolicy {
        const self: *const @This() = @ptrCast(@alignCast(raw orelse return null));
        if (!std.mem.eql(u8, file, self.file) or format_value != .thumbnail or width != self.width or height != null) return null;
        return .requested_fit;
    }
    fn source(self: *const @This(), ns: *const Ns) wiki.FigureSizingSource {
        return .{ .ctx = self, .resolve_fn = resolve, .source_context = .{
            .namespace_sha256 = ns.source_sha256,
            .defaults = .{ .rtl = false, .default_thumbnail_width = 275 },
        } };
    }
    const namespace_bytes = "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tFile\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    fn countBlocks(blocks: []const T.Block) usize {
        var total: usize = 0;
        for (blocks) |block| {
            if (block.flow) |parts| total += countFlow(parts);
            if (block.figure) |figure| { total += 1; if (figure.caption_blocks) |children| total += countBlocks(children); }
            if (block.table) |table| total += countTable(table);
        }
        return total;
    }
    fn countFlow(parts: []const T.FlowPart) usize {
        var total: usize = 0;
        for (parts) |flow_part| switch (flow_part.kind) {
            .@"inline" => {},
            .figure => if (flow_part.figure) |figure| { total += 1; if (figure.caption_blocks) |children| total += countBlocks(children); },
            .scope => if (flow_part.scope) |scope| { total += countFlow(scope.parts); },
        };
        return total;
    }
    fn countTable(table: T.Table) usize {
        var total: usize = 0;
        if (table.caption_blocks) |children| total += countBlocks(children);
        for (table.rows) |row| for (row.cells) |cell| {
            if (cell.blocks) |children| total += countBlocks(children);
            if (cell.nested_table) |nested| total += countTable(nested);
        };
        return total;
    }
    fn count(entry: T.Entry) usize {
        var total: usize = 0;
        for (entry.sections) |section| total += countBlocks(section.blocks);
        for (entry.references) |reference| if (reference.blocks) |blocks| { total += countBlocks(blocks); };
        return total;
    }
};

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

test "Danish template POS labels retain three independent fire owners and source sense associations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "fire" } };
    // Representative semantic controls use the exact retained Reader headings,
    // levels, definition text/targets and block schedule. They are not a replay
    // or a new full-page expansion of the malformed authored templates.
    const cardinal = try renderer.renderBody("'''fire'''\n#''(mængdetal)'': [[4]]\n#*ordenstal: [[fjerde]]\nEksempler: En [[hund]] har fire ben.\n{| class=wikitable\n! Halve !! Dobbelte\n|-\n| 2 || 8\n|}\n");
    const danish_verb = try renderer.renderBody("'''fire'''\n# At [[sænke]] noget eller nogen ned;\n");
    const english_noun = try renderer.renderBody("'''fire'''\n# <span lang=da>[[ild#Dansk|ild]], [[bål#Dansk|bål]]</span>\n# <span lang=da>[[brand#Dansk|brand]]</span>\n# <span lang=da>[[flamme#Dansk|flamme]]</span>\n# <span lang=da>[[ild#Dansk|ild]], [[beskydning#Dansk|beskydning]]</span>\n# <span lang=da>[[ovn#Dansk|ovn]], [[ildsted#Dansk|ildsted]]</span>\n");
    const english_verb = try renderer.renderBody("[malformed template]}\n# <span lang=da>[[skyde#Dansk|skyde]]</span>\n# <span lang=da>[[affyre#Dansk|affyre]]</span>\n# <span lang=da>[[fyre#Dansk|fyre]]</span>\n");
    const interjection = try renderer.renderBody("'''fire'''\n# Dette ord mangler en definition. Hjælp gerne med at tilføje en definition.\n");
    const norwegian_cardinal = try renderer.renderBody("'''fire'''\n#''(mængdetal)'': [[#Dansk|fire]]\n#*ordenstal: [[fjerde]]\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const da = [_]Section{
        .{ .title = "dansk", .level = 2 }, .{ .title = "Dansk", .level = 2 },
        .{ .title = "Mængdetal", .level = 3, .blocks = cardinal }, .{ .title = "Oversættelser", .level = 4 },
        .{ .title = "Verbum", .level = 3, .blocks = danish_verb }, .{ .title = "Oversættelser", .level = 4 },
        .{ .title = "Kilder", .level = 3 },
    };
    const en = [_]Section{
        .{ .title = "engelsk", .level = 2 }, .{ .title = "Engelsk", .level = 2 }, .{ .title = "Udtale", .level = 3 },
        .{ .title = "Substantiv", .level = 3, .blocks = english_noun }, .{ .title = "Synonymer", .level = 4 },
        .{ .title = "Verbum", .level = 3, .blocks = english_verb }, .{ .title = "Afledte termer", .level = 4 },
        .{ .title = "Interjektion", .level = 3, .blocks = interjection }, .{ .title = "Kilder", .level = 3 },
    };
    const no = [_]Section{
        .{ .title = "norsk", .level = 2 }, .{ .title = "Norsk", .level = 2 }, .{ .title = "Udtale", .level = 3 },
        .{ .title = "Mængdetal", .level = 3, .blocks = norwegian_cardinal }, .{ .title = "Kilder", .level = 3 },
    };
    const da_layout = try buildOwned(a, &da, "dansk");
    const en_layout = try buildOwned(a, &en, "engelsk");
    const no_layout = try buildOwned(a, &no, "norsk");
    try std.testing.expectEqual(@as(usize, 2), da_layout.lexemes.len);
    try std.testing.expectEqual(@as(usize, 3), en_layout.lexemes.len);
    try std.testing.expectEqual(@as(usize, 1), no_layout.lexemes.len);
    const number = da_layout.lexemes[0];
    try std.testing.expectEqualStrings("Numeral", number.kind);
    try std.testing.expectEqualStrings("dansk", number.language);
    try std.testing.expectEqual(@as(usize, 2), number.section);
    try std.testing.expectEqualSlices(usize, &.{0}, number.introduction);
    try std.testing.expectEqual(@as(usize, 1), number.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), number.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, number.definitions[0].quotations);
    // The source's free paragraph is supporting body, not an invented example.
    try std.testing.expectEqual(@as(usize, 0), number.definitions[0].examples.len);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, number.other_blocks);
    try std.testing.expectEqualSlices(usize, &.{3}, number.related_sections);
    try std.testing.expectEqualStrings("Verb", da_layout.lexemes[1].kind);
    try std.testing.expectEqual(@as(usize, 4), da_layout.lexemes[1].section);
    try std.testing.expectEqualSlices(usize, &.{5}, da_layout.lexemes[1].related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 6 }, da_layout.other_sections);
    for (en_layout.lexemes, [_][]const u8{ "Noun", "Verb", "Interjection" }, [_]usize{ 3, 5, 7 }, [_]usize{ 5, 3, 1 }) |lexeme, kind, section, senses| {
        try std.testing.expectEqualStrings(kind, lexeme.kind);
        try std.testing.expectEqualStrings("engelsk", lexeme.language);
        try std.testing.expectEqual(section, lexeme.section);
        try std.testing.expectEqual(senses, lexeme.definitions.len);
        try std.testing.expect(lexeme.etymology == null);
        for (lexeme.definitions, 1..) |sense, block| {
            try std.testing.expectEqual(block, sense.block);
            try std.testing.expect(sense.parent == null and sense.form == null);
        }
    }
    try std.testing.expectEqualSlices(usize, &.{4}, en_layout.lexemes[0].related_sections);
    try std.testing.expectEqualSlices(usize, &.{6}, en_layout.lexemes[1].related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 8 }, en_layout.other_sections);
    try std.testing.expectEqualStrings("Numeral", no_layout.lexemes[0].kind);
    try std.testing.expectEqualStrings("norsk", no_layout.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 3), no_layout.lexemes[0].section);
    try std.testing.expectEqualSlices(usize, &.{2}, no_layout.lexemes[0].definitions[0].quotations);
    try std.testing.expect(no_layout.lexemes[0].definitions[0].form == null);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4 }, no_layout.other_sections);
    // Definition targets keep their explicit Danish scope while the lexical
    // record owner remains English; number headings never supply an owner.
    var danish_target = false;
    for (english_noun[1].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "ild#Dansk")) {
        try std.testing.expectEqualStrings("da", span.language);
        danish_target = true;
    };
    try std.testing.expect(danish_target);
    var local_anchor = false;
    for (norwegian_cardinal[1].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "#Dansk")) {
        try std.testing.expectEqualStrings("", span.language);
        local_anchor = true;
    };
    try std.testing.expect(local_anchor);
    const table = cardinal[4].table.?;
    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].cells.len);
    try std.testing.expect(table.rows[0].cells[0].header and table.rows[0].cells[1].header);
    var diagnostic: std.ArrayList(u8) = .empty;
    for (english_verb[0].spans) |span| try diagnostic.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("[malformed template]}", diagnostic.items);
    const different = try buildOwned(a, &en, "A different independently declared owner");
    for (different.lexemes, en_layout.lexemes) |actual, expected| {
        try std.testing.expectEqualStrings("A different independently declared owner", actual.language);
        var copied = expected;
        copied.language = "A different independently declared owner";
        try std.testing.expectEqualDeep(copied, actual);
    }
}

test "Danish exact POS labels reject lookalikes and do not infer language or literal headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ .{ "Substantiv", "Noun" }, .{ "Verbum", "Verb" }, .{ "Interjektion", "Interjection" }, .{ "Mængdetal", "Numeral" } }) |row|
        try std.testing.expectEqualStrings(row[1], partOfSpeech(row[0]).?);
    for ([_][]const u8{ "substantiv", "SUBSTANTIV", "Substantiv 2", "Substantiver", "Verbum note", "Interjektioner", "Mængdetal 2", "Mængdetal note", "Mængde", "mængdetal", "Udtale", "Oversættelser", "Kilder", "dansk", "engelsk", "norsk" }) |title|
        try std.testing.expect(partOfSpeech(title) == null);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Unclassified", .level = 2 },
        .{ .title = "Mængdetal", .level = 2, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
        .{ .title = "Unknown boundary", .level = 2 },
        .{ .title = "Substantiv", .level = 3, .blocks = &.{.{ .kind = .definition, .list_path = "#" }} },
    };
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    try std.testing.expectEqualStrings("Noun", unresolved.lexemes[0].kind);
    try std.testing.expectEqual(@as(usize, 3), unresolved.lexemes[0].section);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const protected_body = try renderer.renderBody("<nowiki>===Substantiv===</nowiki>\n<pre>===Verbum===</pre>\nMængdetal and Interjektion in ordinary body text.\n");
    const protected = [_]Section{.{ .title = "Notes", .level = 3, .blocks = protected_body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &protected, "Declared owner")).lexemes.len);
}

test "explicit morphology noun marker joins only its adjacent meanings and preserves supplied owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "abaq" } };
    const morphology = try renderer.renderBody("''atlıq'', a-baq\n");
    const body = try renderer.renderBody("Jılımnıń etegi, sheti, jiyegi.\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Morfologiyalıq hám sintaksislik qásiyetleri", .level = 3, .blocks = morphology },
        .{ .title = "Leksikalıq mánileri", .level = 3, .blocks = body },
    };
    const result = try buildOwned(a, &sections, "Independently classified owner");
    try std.testing.expectEqual(@as(usize, 1), result.lexemes.len);
    const noun = result.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Independently classified owner", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{0}, result.other_sections);
    try std.testing.expectEqualDeep(morphology, sections[0].blocks);
    try std.testing.expectEqualDeep(body, sections[1].blocks);
    // Existing definition analysis remains authoritative when definitions really
    // are present; the production join does not manufacture paragraph senses.
    var numbered = sections;
    numbered[1].blocks = try renderer.renderBody("# first [[Target]]\n## second\n#: example\n");
    const with_senses = try buildOwned(a, &numbered, "Independently classified owner");
    var ordinary = numbered;
    ordinary[1].title = "Noun";
    try std.testing.expectEqualDeep(try buildOwned(a, &ordinary, "Independently classified owner"), with_senses);
}

test "morphology sibling join rejects unresolved owners protected markers prose and crossed domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const valid = [_]Section{
        .{ .title = "Morfologiyalıq hám sintaksislik qásiyetleri", .level = 3, .blocks = try renderer.renderBody("''atlıq'', o-ra-za\n") },
        .{ .title = "Leksikalıq mánileri", .level = 3, .blocks = try renderer.renderBody("1. first<br>2. second\n") },
    };
    for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
        try std.testing.expect(morphologySiblingPart(&valid, 1, owner) == null);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &valid)).lexemes.len);
    for ([_][]const u8{
        "atlıq, o-ra-za", "''atlıq'' prose", "''atlıq, verb'', o-ra-za",
        "''[[atlıq]]'', o-ra-za", "''<nowiki>atlıq</nowiki>'', o-ra-za",
        "<code>atlıq</code>, o-ra-za", " ''atlıq'', o-ra-za",
        "''Atlıq'', o-ra-za", "''atlıq'', o-ra-za, verb", "''atlıq'', o--ra-za",
    }) |source| {
        errdefer std.debug.print("morphology marker wrongly accepted: {s}\n", .{source});
        var changed = valid;
        changed[0].blocks = try renderer.renderBody(source);
        try std.testing.expect(morphologySiblingPart(&changed, 1, "Qaraqalpaqsha") == null);
    }
    var changed = valid;
    changed[0].level = 2;
    try std.testing.expect(morphologySiblingPart(&changed, 1, "Qaraqalpaqsha") == null);
    changed = valid;
    changed[1].level = 4;
    try std.testing.expect(morphologySiblingPart(&changed, 1, "Qaraqalpaqsha") == null);
    changed = valid;
    changed[1].title = "Leksikalıq mánileri extra";
    try std.testing.expect(morphologySiblingPart(&changed, 1, "Qaraqalpaqsha") == null);
    const separated = [_]Section{ valid[0], .{ .title = "Other language", .level = 2 }, valid[1] };
    try std.testing.expect(morphologySiblingPart(&separated, 2, "Qaraqalpaqsha") == null);
    const support = [_]Section{ valid[0], .{ .title = "Aytılıwı", .level = 3 }, valid[1] };
    try std.testing.expect(morphologySiblingPart(&support, 2, "Qaraqalpaqsha") == null);
}

// These are complete observed Reader entries, not reconstructed expanded pages.
// The test projection below supplies build-only structs solely to exercise layout;
// it makes no claim to recover erased source provenance or execute the Writer.
test "KAA observed abaq and oraza retain complete body actions paint media and codec with noun metadata only" {
    const types = @import("blob_encoder").presentation_types;
    const codec = @import("blob_encoder").presentation_codec;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const observed_json = [_][]const u8{
        \\{"organization":{"lexemes":[],"other_sections":[0,1,2,3,4,5]},"title":"abaq","display_title":[],"kind":"language","language":"Qaraqalpaqsha","language_code":"kaa","sections":[{"level":2,"title":"Qaraqalpaqsha","anchor":"","anchor_fallback":"","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"link","text":"Úlgi:Underlinked","target":"Úlgi:Underlinked","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"Úlgi:Orphan","target":"Úlgi:Orphan","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":2,"title":"Qaraqalpaqsha (kaa)","anchor":"Qaraqalpaqsha_(kaa)","anchor_fallback":"Qaraqalpaqsha_.28kaa.29","blocks":[{"kind":"heading","depth":0,"spans":[{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"toccolours","direction":"","explanation":"","foreground":null,"font_scale":1.2000000476837158,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Qaraqalpaqsha","target":"","trail":"","language":"","classes":"toccolours","direction":"","explanation":"","foreground":null,"font_scale":1.2000000476837158,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" (kaa)","target":"","trail":"","language":"","classes":"toccolours","direction":"","explanation":"","foreground":null,"font_scale":0.8333333134651184,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":2,"anchor":"Qaraqalpaqsha_(kaa)","anchor_fallback":"Qaraqalpaqsha_.28kaa.29","table":null}]},{"level":3,"title":"Morfologiyalıq hám sintaksislik qásiyetleri","anchor":"Morfologiyalıq_hám_sintaksislik_qásiyetleri","anchor_fallback":"Morfologiyal.C4.B1q_h.C3.A1m_sintaksislik_q.C3.A1siyetleri","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"atlıq","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", a-baq","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":3,"title":"Leksikalıq mánileri","anchor":"Leksikalıq_mánileri","anchor_fallback":"Leksikal.C4.B1q_m.C3.A1nileri","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Jılımnıń etegi, sheti, jiyegi. ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"•","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Ara-tura salǵan jılım, ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"abaǵım","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","background":"#edf0ff","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", Maylaǵanda úyip keler qabaǵın ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"(S. Nurımbetov)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":".","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":3,"title":"Aytılıwı","anchor":"Aytılıwı","anchor_fallback":"Ayt.C4.B1l.C4.B1w.C4.B1","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"link","text":"LL-Q33541 (kaa)-Inosham-Abaq.wav","target":"File:LL-Q33541 (kaa)-Inosham-Abaq.wav","trail":"","language":"","classes":"wikidict-media wikidict-media-file-4c4c2d51333335343120286b6161292d496e6f7368616d2d416261712e776176","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":3,"title":"Derekler","anchor":"Derekler","anchor_fallback":"","blocks":[{"kind":"definition","depth":1,"spans":[{"kind":"text","text":"QARAQALPAQ TILINIŃ TÚSINDIRME SÓZLIGI.","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Jeti tomlıq. I tom. Nókis, «Qaraqalpaqstan» baspası, 2023-jıl.","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"#","number":"1","level":0,"anchor":"","anchor_fallback":"","table":null}]}],"preamble_spans":[],"references":[],"media":[{"file":"LL-Q33541 (kaa)-Inosham-Abaq.wav","kind":"audio","caption":"LL-Q33541 (kaa)-Inosham-Abaq.wav"}],"redirect":null,"alias":null}
        ,
        \\{"organization":{"lexemes":[],"other_sections":[0,1,2,3]},"title":"oraza","display_title":[],"kind":"language","language":"Qaraqalpaqsha","language_code":"kaa","sections":[{"level":2,"title":"Qaraqalpaqsha (kaa)","anchor":"Qaraqalpaqsha_(kaa)","anchor_fallback":"Qaraqalpaqsha_.28kaa.29","blocks":[{"kind":"heading","depth":0,"spans":[{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"toccolours","direction":"","explanation":"","foreground":null,"font_scale":1.2000000476837158,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Qaraqalpaqsha","target":"","trail":"","language":"","classes":"toccolours","direction":"","explanation":"","foreground":null,"font_scale":1.2000000476837158,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" (kaa)","target":"","trail":"","language":"","classes":"toccolours","direction":"","explanation":"","foreground":null,"font_scale":0.8333333134651184,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":2,"anchor":"Qaraqalpaqsha_(kaa)","anchor_fallback":"Qaraqalpaqsha_.28kaa.29","table":null}]},{"level":3,"title":"Morfologiyalıq hám sintaksislik qásiyetleri","anchor":"Morfologiyalıq_hám_sintaksislik_qásiyetleri","anchor_fallback":"Morfologiyal.C4.B1q_h.C3.A1m_sintaksislik_q.C3.A1siyetleri","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"atlıq","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", o-ra-za","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":3,"title":"Leksikalıq mánileri","anchor":"Leksikalıq_mánileri","anchor_fallback":"Leksikal.C4.B1q_m.C3.A1nileri","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"<nowiki>","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"1. din. s. Jıl dawamında kúndiz awqat jemey júretuǵın arnawlı bir ay. ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"•","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Namaz ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"oraza","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","background":"#edf0ff","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" parızım bar, Bir alladan meniń, qızım, Atańnıń aytar arzı bar, qulaǵıń sal, janım qızım ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"(Berdaq)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":".","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":"#006400","bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"2. din. s. Ómirlik oraza, ómir boyı tutıq bolıw, oraza tutıw.","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":3,"title":"Derekler","anchor":"Derekler","anchor_fallback":"","blocks":[{"kind":"definition","depth":1,"spans":[{"kind":"text","text":"QARAQALPAQ TILINIŃ TÚSINDIRME SÓZLIGI.","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Jeti tomlıq, ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"Nókis","target":"Nókis","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", «Qaraqalpaqstan» baspası, 2023-jıl.","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"#","number":"1","level":0,"anchor":"","anchor_fallback":"","table":null}]}],"preamble_spans":[],"references":[],"media":[],"redirect":null,"alias":null}
        ,
    };
    for (observed_json, 0..) |json, fixture| {
        const parsed = try std.json.parseFromSlice(types.Entry, a, json, .{});
        const before = parsed.value;
        errdefer std.debug.print("complete observed KAA record: {s}\n", .{before.title});
        try std.testing.expectEqualStrings("kaa", before.language_code);
        try std.testing.expectEqualStrings("Qaraqalpaqsha", before.language.?);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = try a.alloc(Section, before.sections.len);
        for (before.sections, sections) |source_section, *section| {
            const blocks = try a.alloc(wiki.Block, source_section.blocks.len);
            for (source_section.blocks, blocks) |source_block, *block| {
                try std.testing.expect(source_block.table == null and source_block.feature == null);
                const spans = try a.alloc(wiki.Span, source_block.spans.len);
                for (source_block.spans, spans) |source_span, *span| {
                    try std.testing.expectEqualStrings("", source_span.trail);
                    span.* = .{
                        .kind = std.meta.stringToEnum(@TypeOf(span.kind), @tagName(source_span.kind)).?,
                        .text = source_span.text,
                        .target = source_span.target,
                        .language = source_span.language,
                        .classes = source_span.classes,
                        .direction = source_span.direction,
                        .explanation = source_span.explanation,
                        .foreground = source_span.foreground,
                        .background = source_span.background,
                        .font_scale = source_span.font_scale,
                        .font_scale_basis = source_span.font_scale_basis,
                        .role = std.meta.stringToEnum(@TypeOf(span.role), @tagName(source_span.role)).?,
                        .flags = .{
                            .bold = source_span.bold, .italic = source_span.italic,
                            .code = source_span.code, .small = source_span.small,
                            .superscript = source_span.superscript, .subscript = source_span.subscript,
                            .strike = source_span.strike, .underline = source_span.underline,
                        },
                    };
                }
                block.* = .{
                    .kind = std.meta.stringToEnum(wiki.Kind, @tagName(source_block.kind)).?,
                    .depth = source_block.depth, .spans = spans,
                    .list_path = source_block.list_path, .number = source_block.number,
                    .level = source_block.level, .anchor = source_block.anchor,
                    .anchor_fallback = source_block.anchor_fallback,
                };
            }
            section.* = .{ .title = source_section.title, .level = source_section.level, .blocks = blocks };
        }
        const organization = try buildOwned(a, sections, before.language.?);
        try std.testing.expectEqual(@as(usize, 1), organization.lexemes.len);
        const noun = organization.lexemes[0];
        const meaning_index: usize = if (fixture == 0) 3 else 2;
        try std.testing.expectEqual(meaning_index, noun.section);
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqualStrings(before.language.?, noun.language);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions.len);
        try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
        try std.testing.expectEqualStrings("Leksikalıq mánileri", before.sections[noun.section].title);
        // Source citations use definition blocks too. They stay independent;
        // none of these supporting rows becomes a lexical sense.
        try std.testing.expectEqual(@as(usize, 0), noun.related_sections.len);
        const bytes = try codec.encodeBuildAlloc(a, before.display_title, before.sections, organization, before.references, before.media);
        const stored = try codec.decodeAlloc(a, bytes, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
        try std.testing.expectEqualStrings(bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqualDeep(before.sections, stored.entry.sections);
        try std.testing.expectEqualDeep(before.display_title, stored.entry.display_title);
        try std.testing.expectEqualDeep(before.references, stored.entry.references);
        try std.testing.expectEqualDeep(before.media, stored.entry.media);
        var normalized = stored;
        normalized.entry.organization = before.organization;
        const baseline = try codec.encodeAlloc(a, .{ .entry = before });
        try std.testing.expectEqualStrings(baseline, try codec.encodeAlloc(a, normalized));
        // No owner was invented in the metadata projection either.
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
    }
}

test "SL headword and meanings profile reuses definition parents examples and block addresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "word" } };
    const source = "''word, [[glagol]]'', [[nedovršen]]\n\n'''Transkripcija:'''\n\n*word\n\n'''Pomeni:'''\n\n# first [[Target]]\n## second\n#: example\n##* quotation\n# third\n\n'''Sources:'''\n\n# bibliography\n";
    const blocks = try renderer.renderBody(source);
    const marker = markedParagraphPart(blocks, "Independent owner", 2).?;
    try std.testing.expectEqualStrings("Verb", marker.kind);
    const actual = try analyzeMarkedParagraph(a, marker, 0, null, blocks);
    try std.testing.expectEqual(@as(usize, 3), actual.definitions.len);
    try std.testing.expectEqual(@as(?usize, 0), actual.definitions[1].parent);
    try std.testing.expect(actual.definitions[0].parent == null and actual.definitions[2].parent == null);
    try std.testing.expectEqualStrings("first ", blocks[actual.definitions[0].block].spans[0].text);
    try std.testing.expectEqualStrings("second", blocks[actual.definitions[1].block].spans[0].text);
    try std.testing.expectEqualStrings("third", blocks[actual.definitions[2].block].spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), actual.definitions[0].examples.len);
    try std.testing.expectEqualStrings("example", blocks[actual.definitions[0].examples[0]].spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), actual.definitions[1].quotations.len);
    try std.testing.expectEqualStrings("quotation", blocks[actual.definitions[1].quotations[0]].spans[0].text);
    for (actual.introduction, 0..) |block_index, i| try std.testing.expectEqual(i, block_index);
    try std.testing.expectEqualStrings("bibliography", blocks[actual.other_blocks[actual.other_blocks.len - 1]].spans[0].text);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const sections = [_]Section{.{ .title = "Source language", .level = 2, .blocks = blocks }};
    const result = try buildOwned(a, &sections, "Independent owner");
    var expected = actual;
    expected.language = "Independent owner";
    try std.testing.expectEqual(@as(usize, 1), result.lexemes.len);
    try std.testing.expectEqualDeep(expected, result.lexemes[0]);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    const regions = [_]Section{
        .{ .title = "Etymology", .level = 2, .blocks = &.{} },
        sections[0],
    };
    const region_result = try buildOwned(a, &regions, "Independent owner");
    try std.testing.expectEqual(@as(usize, 1), region_result.lexemes.len);
    try std.testing.expect(region_result.lexemes[0].etymology == null);
    var direct_pos = regions;
    direct_pos[1].title = "Verb";
    const direct_result = try buildOwned(a, &direct_pos, "Independent owner");
    try std.testing.expectEqual(@as(?usize, 0), direct_result.lexemes[0].etymology);
    const noun = try renderer.renderBody("''oko'', [[samostalnik]] [[srednji|srednjega]] [[spol]]a, '''oko''' dv '''očesi'''\n\n'''Pomeni:'''\n\n# organ\n");
    try std.testing.expectEqualStrings("Noun", markedParagraphPart(noun, "slovenščina", 2).?.kind);
}

test "SL paragraph POS requires parsed headword local grammar link meanings and resolved owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "word" } };
    for ([_][]const u8{
        "word, [[glagol]]", "''word'' [[glagol]]", "''word'', glagol",
        "''word'', [[glagol]]", "''word, [[samostalnik]]''",
        "''word, [[Appendix:glagol|glagol]]''", "''word, [https://example.invalid/glagol glagol]''",
        "''word, [[glagol|verb]]''", "''word'', [[samostalnik]], ''[[glagol]]''",
        "''<nowiki>word</nowiki>, [[glagol]]''", "<code>word, [[glagol]]</code>",
        " ''word, [[glagol]]''", "''word, [[w:glagol|glagol]]''",
    }) |prefix| {
        errdefer std.debug.print("unexpected SL profile acceptance: {s}\n", .{prefix});
        const source = try std.fmt.allocPrint(a, "{s}\n\n'''Pomeni:'''\n\n# definition\n", .{prefix});
        try std.testing.expect(markedParagraphPart(try renderer.renderBody(source), "owner", 2) == null);
    }
    for ([_][]const u8{
        "Pomeni:\n\n# definition", "'''<nowiki>Pomeni:</nowiki>'''\n\n# definition",
        "'''Pomeni:'''\n\nplain meaning", "'''Pomeni:'''\n\n* meaning",
        "'''Pomeni:'''\n\n# first\n\n'''Pomeni:'''\n\n# second",
        "'''Pomeni:'''\n\n# first\n\n''other'', [[samostalnik]]",
    }) |tail| {
        errdefer std.debug.print("unexpected SL meaning profile acceptance: {s}\n", .{tail});
        const source = try std.fmt.allocPrint(a, "''word, [[glagol]]''\n\n{s}\n", .{tail});
        try std.testing.expect(markedParagraphPart(try renderer.renderBody(source), "owner", 2) == null);
    }
    const valid = try renderer.renderBody("''word, [[glagol]]''\n\n'''Pomeni:'''\n\n# definition\n");
    for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
        try std.testing.expect(markedParagraphPart(valid, owner, 2) == null);
    for ([_]u8{ 1, 3, 4, 5, 6 }) |level|
        try std.testing.expect(markedParagraphPart(valid, "owner", level) == null);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const separated = [_]Section{
        .{ .title = "First owner", .level = 2, .blocks = try renderer.renderBody("''word, [[glagol]]''") },
        .{ .title = "Second owner", .level = 2, .blocks = try renderer.renderBody("'''Pomeni:'''\n\n# definition") },
    };
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &separated, "owner")).lexemes.len);
}

// These are complete observed Reader entries, not reconstructed expanded pages.
// The test projection below supplies build-only structs solely to exercise layout;
// it makes no claim to recover erased source provenance or execute the Writer.
test "SL observed piacy and oko retain complete body tables actions and codec with actual sense addresses" {
    const types = @import("blob_encoder").presentation_types;
    const codec = @import("blob_encoder").presentation_codec;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const observed_json = [_][]const u8{
        \\{"organization":{"lexemes":[],"other_sections":[0]},"title":"пячы","display_title":[],"kind":"language","language":"beloruščina","language_code":"be","sections":[{"level":2,"title":"Beloruščina","anchor":"Beloruščina","anchor_fallback":"Beloru.C5.A1.C4.8Dina","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" Spregatev besede ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"пячы","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"table","depth":0,"spans":[],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":{"caption":[],"rows":[{"cells":[{"spans":[],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"sedanji čas","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#eff7ff"},{"spans":[{"kind":"text","text":"velelnik","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#eff7ff"},{"spans":[{"kind":"text","text":"pretekli čas","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#eff7ff"}]},{"cells":[{"spans":[{"kind":"text","text":"prva oseba (ednina)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пяку","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"druga oseba (ednina)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пячэш","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пячы","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"tretja oseba (ednina)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пячэ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"prva oseba (množina)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пячом","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"druga oseba (množina)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"печаце","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пячыце","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"tretja oseba (množina)","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пякуць","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"moški rod","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пёк","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"ženski rod","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пякла","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"srednji rod","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пякло","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]},{"cells":[{"spans":[{"kind":"text","text":"množina","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":true,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[{"kind":"text","text":"пяклі","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":"#f9f9f9"}]}]}},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"пячы, ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"glagol","target":"glagol","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":",","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"nedovršen","target":"nedovršen","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Transkripcija:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"list_item","depth":1,"spans":[{"kind":"text","text":"pjačy","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"*","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Pomeni:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"definition","depth":1,"spans":[{"kind":"link","text":"peči","target":"peči","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"#","number":"1","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Izgovarjava:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"list_item","depth":1,"spans":[{"kind":"external_link","text":"IPA","target":"https://en.wiktionary.org/wiki/Appendix:Slovene_pronunciation","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":": ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"[","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"[pʲaˈt͡ʂɨ","target":"","trail":"","language":"","classes":"IPA","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"pronunciation"},{"kind":"text","text":"]","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"*","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Protipomenke:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"indent","depth":1,"spans":[{"kind":"link","text":"сьпячы","target":"сьпячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":":","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Besedne zveze:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"indent","depth":1,"spans":[{"kind":"link","text":"пекар","target":"пекар","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"пячэнне","target":"пячэнне","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"адпячы","target":"адпячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"дапячы","target":"дапячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"напячы","target":"напячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"падпячы","target":"падпячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"папячы","target":"папячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"перапячы","target":"перапячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"прапячы","target":"прапячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"расьпячы","target":"расьпячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"упячы","target":"упячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":":","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Zunanje povezave:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"list_item","depth":1,"spans":[{"kind":"text","text":"Энцыкляпэдыя электронная „","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"пячы","target":"http://www.slounik.org/search?dict=&search=пячы","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"“","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"*","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]}],"preamble_spans":[],"references":[],"media":[],"redirect":null,"alias":null}
        ,
        \\{"organization":{"lexemes":[],"other_sections":[0,1]},"title":"oko","display_title":[],"kind":"language","language":"slovenščina","language_code":"sl","sections":[{"level":2,"title":"Slovenščina","anchor":"Slovenščina","anchor_fallback":"Sloven.C5.A1.C4.8Dina","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"oko","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":",","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"samostalnik","target":"samostalnik","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"srednjega","target":"srednji","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"spol","target":"spol","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"a","target":"spol","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"oko","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" dv ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"očesi","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" mn ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"očesa","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" posebna mn ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"oči","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Pomeni:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"definition","depth":1,"spans":[{"kind":"link","text":"človeški","target":"človek","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ali ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"žival","target":"žival","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ski","target":"žival","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"organ","target":"organ","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ki omogoča ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"vid","target":"vid","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":".","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"#","number":"1","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Besedne zveze:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"indent","depth":1,"spans":[{"kind":"link","text":"mačje oko","target":"mačje oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"tigrovo oko","target":"tigrovo oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"tretje oko","target":"tretje oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":":","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":4,"title":"Prevodi","anchor":"Prevodi","anchor_fallback":"","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"anatomija","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"table","depth":0,"spans":[],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":{"caption":[],"rows":[{"cells":[{"spans":[{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Angleško: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"eye","target":"eye","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(en)","target":"https://en.wiktionary.org/wiki/eye","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Baskovsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"begi","target":"begi","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(eu)","target":"https://eu.wiktionary.org/wiki/begi","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Francosko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"œil","target":"œil","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(fr)","target":"https://fr.wiktionary.org/wiki/%C5%93il","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Galicijsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ollo","target":"ollo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(gl)","target":"https://gl.wiktionary.org/wiki/ollo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Italijansko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"occhio","target":"occhio","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(it)","target":"https://it.wiktionary.org/wiki/occhio","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#ffffe0"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":null},{"spans":[{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Katalonsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ull","target":"ull","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(ca)","target":"https://ca.wiktionary.org/wiki/ull","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Latinsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"oculus","target":"oculus","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", i, ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(la)","target":"https://la.wiktionary.org/wiki/oculus","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Nemško: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"Auge","target":"Auge","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(de)","target":"https://de.wiktionary.org/wiki/Auge","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Portugalsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"olho","target":"olho","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(pt)","target":"https://pt.wiktionary.org/wiki/olho","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Špansko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ojo","target":"ojo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(es)","target":"https://es.wiktionary.org/wiki/ojo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"|}","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#ffffe0"}]}],"geometry":{"border":0,"cell_spacing":null,"cell_padding":null,"width":{"unit":"percent","value":100}}}},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"[malformed table]","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Rime:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"indent","depth":1,"spans":[{"kind":"link","text":"meso","target":"meso","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"pero","target":"pero","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":":","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Zunanje povezave:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"table","depth":0,"spans":[],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":{"caption":[],"rows":[{"cells":[{"spans":[{"kind":"link","text":"Commons","target":"File:Wikipedia-logo.png","trail":"","language":"","classes":"wikidict-media wikidict-media-file-57696b6970656469612d6c6f676f2e706e67","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":null},{"spans":[{"kind":"external_link","text":"oko","target":"https://sl.wikipedia.org/wiki/oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" – članek v Wikipediji","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":null}]}],"geometry":{"border":0,"cell_spacing":1,"cell_padding":null,"width":null}}}]}],"preamble_spans":[],"references":[],"media":[{"file":"Wikipedia-logo.png","kind":"image","caption":"Commons"}],"redirect":null,"alias":null}
        ,
    };
    for (observed_json, 0..) |json, fixture| {
        const parsed = try std.json.parseFromSlice(types.Entry, a, json, .{});
        const before = parsed.value;
        errdefer std.debug.print("complete observed SL record: {s}\n", .{before.title});
        try std.testing.expectEqualStrings(if (fixture == 0) "be" else "sl", before.language_code);
        try std.testing.expectEqualStrings(if (fixture == 0) "beloruščina" else "slovenščina", before.language.?);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = try a.alloc(Section, before.sections.len);
        for (before.sections, sections) |source_section, *section| {
            const blocks = try a.alloc(wiki.Block, source_section.blocks.len);
            for (source_section.blocks, blocks) |source_block, *block| {
                // Layout consumes block kind/path and inline markers only. Complete table
                // and feature graphs below are encoded directly from the original entry.
                const spans = try a.alloc(wiki.Span, source_block.spans.len);
                for (source_block.spans, spans) |source_span, *span| {
                    try std.testing.expectEqualStrings("", source_span.trail);
                    span.* = .{
                        .kind = std.meta.stringToEnum(@TypeOf(span.kind), @tagName(source_span.kind)).?,
                        .text = source_span.text,
                        .target = source_span.target,
                        .language = source_span.language,
                        .classes = source_span.classes,
                        .direction = source_span.direction,
                        .explanation = source_span.explanation,
                        .foreground = source_span.foreground,
                        .background = source_span.background,
                        .font_scale = source_span.font_scale,
                        .font_scale_basis = source_span.font_scale_basis,
                        .role = std.meta.stringToEnum(@TypeOf(span.role), @tagName(source_span.role)).?,
                        .flags = .{
                            .bold = source_span.bold, .italic = source_span.italic,
                            .code = source_span.code, .small = source_span.small,
                            .superscript = source_span.superscript, .subscript = source_span.subscript,
                            .strike = source_span.strike, .underline = source_span.underline,
                        },
                    };
                }
                block.* = .{
                    .kind = std.meta.stringToEnum(wiki.Kind, @tagName(source_block.kind)).?,
                    .depth = source_block.depth, .spans = spans,
                    .list_path = source_block.list_path, .number = source_block.number,
                    .level = source_block.level, .anchor = source_block.anchor,
                    .anchor_fallback = source_block.anchor_fallback,
                };
            }
            section.* = .{ .title = source_section.title, .level = source_section.level, .blocks = blocks };
        }
        const organization = try buildOwned(a, sections, before.language.?);
        try std.testing.expectEqual(@as(usize, 1), organization.lexemes.len);
        const lexeme = organization.lexemes[0];
        const definition_index: usize = if (fixture == 0) 6 else 2;
        try std.testing.expectEqual(@as(usize, 0), lexeme.section);
        try std.testing.expectEqualStrings(if (fixture == 0) "Verb" else "Noun", lexeme.kind);
        try std.testing.expectEqualStrings(before.language.?, lexeme.language);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        const sense = lexeme.definitions[0];
        try std.testing.expectEqual(definition_index, sense.block);
        try std.testing.expect(sense.parent == null and sense.form == null);
        try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
        try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
        try std.testing.expectEqual(@as(usize, 0), sense.notes.len);
        const definition = before.sections[0].blocks[sense.block];
        try std.testing.expectEqual(types.BlockKind.definition, definition.kind);
        try std.testing.expectEqualStrings("#", definition.list_path);
        try std.testing.expectEqualStrings("1", definition.number);
        var definition_text: std.ArrayList(u8) = .empty;
        for (definition.spans) |span| try definition_text.appendSlice(a, span.text);
        try std.testing.expectEqualStrings(if (fixture == 0) "peči" else "človeški ali živalski organ, ki omogoča vid.", definition_text.items);
        try std.testing.expectEqual(definition_index, lexeme.introduction.len);
        for (lexeme.introduction, 0..) |index, n| try std.testing.expectEqual(n, index);
        try std.testing.expectEqual(before.sections[0].blocks.len - definition_index - 1, lexeme.other_blocks.len);
        for (lexeme.other_blocks, definition_index + 1..) |index, n| try std.testing.expectEqual(n, index);
        if (fixture == 0) try std.testing.expectEqual(@as(usize, 0), lexeme.related_sections.len)
        else try std.testing.expectEqualSlices(usize, &.{1}, lexeme.related_sections);
        const bytes = try codec.encodeBuildAlloc(a, before.display_title, before.sections, organization, before.references, before.media);
        const stored = try codec.decodeAlloc(a, bytes, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
        try std.testing.expectEqualStrings(bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqualDeep(before.sections, stored.entry.sections);
        try std.testing.expectEqualDeep(before.display_title, stored.entry.display_title);
        try std.testing.expectEqualDeep(before.references, stored.entry.references);
        try std.testing.expectEqualDeep(before.media, stored.entry.media);
        var normalized = stored;
        normalized.entry.organization = before.organization;
        const baseline = try codec.encodeAlloc(a, .{ .entry = before });
        try std.testing.expectEqualStrings(baseline, try codec.encodeAlloc(a, normalized));
        // No owner was invented in the metadata projection either.
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
    }
}

test "KA exact noun heading preserves classified owner and original sense addresses" {
    try std.testing.expectEqualStrings("Noun", partOfSpeech("არსებითი სახელი").?);
    for ([_][]const u8{ "არსებითი", "არსებითი  სახელი", "არსებითი სახელი ", " არსებითი სახელი", "არსებითი სახელი 2", "არსებითი სახელები", "დახმარება:არსებითი სახელი" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "გლობუსი" } };
    const blocks = try renderer.renderBody("# [[დედამიწა|დედამიწის]] [[მოდელი]] [[მცირე]] [[მასშტაბი|მასშტაბისა]] (ჩვეულებისამებრ, [[ღერძი|ღერძზე]] [[მბრუნავი]]).\n#: ''source example''\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "ქართული", .level = 2 },
        .{ .title = "მნიშვნელობა", .level = 4 },
        .{ .title = "არსებითი სახელი", .level = 5, .blocks = blocks },
        .{ .title = "თარგმანები", .level = 4 },
    };
    const actual = try buildOwned(a, &sections, "Independent supplied owner");
    var ordinary = sections;
    ordinary[2].title = "Noun";
    try std.testing.expectEqualDeep(try buildOwned(a, &ordinary, "Independent supplied owner"), actual);
    try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
    const noun = actual.lexemes[0];
    try std.testing.expectEqualStrings("Independent supplied owner", noun.language);
    try std.testing.expectEqual(@as(usize, 2), noun.section);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    const sense = noun.definitions[0];
    try std.testing.expectEqual(@as(usize, 0), sense.block);
    try std.testing.expectEqualSlices(usize, &.{1}, sense.examples);
    try std.testing.expect(sense.parent == null and sense.form == null);
    try std.testing.expectEqualDeep(blocks, sections[2].blocks);
    const unresolved = [_]Section{
        .{ .title = "არსებითი სახელი", .level = 2, .blocks = blocks },
        .{ .title = "Unknown region", .level = 2 },
        .{ .title = "არსებითი სახელი", .level = 5, .blocks = blocks },
    };
    const unknown = try buildUnclassified(a, &unresolved);
    try std.testing.expectEqual(@as(usize, 1), unknown.lexemes.len);
    try std.testing.expectEqual(@as(usize, 2), unknown.lexemes[0].section);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
}

test "TL exact adjective and interjection labels preserve supplied owners and reject lookalikes" {
    try std.testing.expectEqualStrings("Adjective", partOfSpeech("Pang-uri").?);
    try std.testing.expectEqualStrings("Interjection", partOfSpeech("Pandamdam").?);
    for ([_][]const u8{ "pang-uri", "PANG-URI", "Pang-uri 2", "Pang-uri ", "Pandamdam 2", "pandamdam", "Pandamdam ", "Unknown Pandamdam" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "aba" } };
    const body = try renderer.renderBody("# [[Target|meaning]]\n#: ''example''\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Pang-uri", .level = 4, .blocks = body },
        .{ .title = "Pandamdam", .level = 4, .blocks = body },
    };
    const actual = try buildOwned(a, &sections, "Independent owner");
    var reference = sections;
    reference[1].title = "Adjective";
    reference[2].title = "Interjection";
    try std.testing.expectEqualDeep(try buildOwned(a, &reference, "Independent owner"), actual);
    try std.testing.expectEqual(@as(usize, 2), actual.lexemes.len);
    for (actual.lexemes, 1..) |lexeme, index| {
        try std.testing.expectEqualStrings("Independent owner", lexeme.language);
        try std.testing.expectEqual(index, lexeme.section);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{1}, lexeme.definitions[0].examples);
        try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
    }
    const unknown = [_]Section{
        .{ .title = "Pang-uri", .level = 2, .blocks = body },
        .{ .title = "Unknown region", .level = 2 },
        .{ .title = "Pandamdam", .level = 4, .blocks = body },
    };
    const unresolved = try buildUnclassified(a, &unknown);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqual(@as(usize, 2), unresolved.lexemes[0].section);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
}

test "SL parsed POS admits only trailing entity whitespace without lending literal authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "word" } };
    const tail = "\n\n'''Pomeni:'''\n\n# [[Meaning]]\n";
    const blocks = try renderer.renderBody("''word, [[glagol]]'',&#32;[[nedovršen]]" ++ tail);
    var entity_spaces: usize = 0;
    for (blocks[0].spans) |span| {
        if (span.provenance == .entity_literal) {
            try std.testing.expectEqualStrings(" ", span.text);
            try std.testing.expectEqual(@as(@TypeOf(span.kind), .text), span.kind);
            try std.testing.expectEqualStrings("", span.target);
            entity_spaces += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), entity_spaces);
    const marker = markedParagraphPart(blocks, "Independent owner", 2) orelse return error.MissingParsedSlovenePos;
    try std.testing.expectEqualStrings("Verb", marker.kind);
    const actual = try analyzeMarkedParagraph(a, marker, 0, null, blocks);
    try std.testing.expectEqual(@as(usize, 1), actual.definitions.len);
    const definition = blocks[actual.definitions[0].block];
    try std.testing.expectEqualStrings("#", definition.list_path);
    try std.testing.expectEqualStrings("Meaning", definition.spans[0].text);
    try std.testing.expectEqualStrings("Meaning", definition.spans[0].target);
    for ([_][]const u8{
        "''word,&#32;[[glagol]]''",
        "''word, [[glagol]]'',&#120;[[nedovršen]]",
        "''word, [[glagol]]'',<nowiki> </nowiki>[[nedovršen]]",
        "''word, [[glagol]]'',<code>&#32;</code>[[nedovršen]]",
        "''word, [[glagol|&#103;lagol]]''",
    }) |prefix| {
        errdefer std.debug.print("SL entity authority boundary: {s}\n", .{prefix});
        const source = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, tail });
        try std.testing.expect(markedParagraphPart(try renderer.renderBody(source), "Independent owner", 2) == null);
    }
    const spans = try a.dupe(wiki.Span, blocks[0].spans);
    const copied = try a.dupe(wiki.Block, blocks);
    copied[0].spans = spans;
    for (spans) |*span| {
        if (span.provenance == .entity_literal) {
            span.kind = .link;
            span.target = "glagol";
        }
    }
    try std.testing.expect(markedParagraphPart(copied, "Independent owner", 2) == null);
    for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
        try std.testing.expect(markedParagraphPart(blocks, owner, 2) == null);
    try std.testing.expect(markedParagraphPart(blocks, "Independent owner", 3) == null);
}


test "nested lemma senses keep local indices and stop inheritance at unrelated boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sense = [_]wiki.Block{ .{ .kind = .paragraph }, .{ .kind = .definition, .list_path = "#" }, .{ .kind = .example, .list_path = "#:" } };
    const sections = [_]Section{
        .{ .title = "Mofers", .level = 2 },
        .{ .title = "Persuuenlik veurnaamwaord", .level = 3 },
        .{ .title = "Lemma", .level = 4, .blocks = &sense },
        .{ .title = "Unrelated support", .level = 4, .blocks = &sense },
        .{ .title = "Neet-lemma", .level = 4, .blocks = &sense },
        .{ .title = "Other language", .level = 2 },
        .{ .title = "Lemma", .level = 4, .blocks = &sense },
        .{ .title = "Pronoun", .level = 3 },
        .{ .title = "Lemma", .level = 5, .blocks = &sense },
        .{ .title = "Lemma", .level = 4, .blocks = &sense },
        .{ .title = "Unknown POS", .level = 3 },
        .{ .title = "Lemma", .level = 4, .blocks = &sense },
    };
    const result = try buildOwned(a, &sections, "Independently supplied owner");
    try std.testing.expectEqual(@as(usize, 2), result.lexemes.len);
    const lexical = result.lexemes[0];
    try std.testing.expectEqualStrings("Pronoun", lexical.kind);
    try std.testing.expectEqualStrings("Independently supplied owner", lexical.language);
    try std.testing.expectEqual(@as(usize, 2), lexical.section);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{3, 4}, lexical.related_sections);
    try std.testing.expectEqual(@as(usize, 7), result.lexemes[1].section);
    try std.testing.expectEqual(@as(usize, 0), result.lexemes[1].definitions.len);
    try std.testing.expectEqualSlices(usize, &.{8, 9}, result.lexemes[1].related_sections);
    // An unresolved H2 POS is not a language or lemma-parent declaration.
    const unowned_sections = [_]Section{ .{ .title = "Noun", .level = 2 }, .{ .title = "Lemma", .level = 3, .blocks = &sense } };
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &unowned_sections)).lexemes.len);
    try std.testing.expect(partOfSpeech("Unknown POS") == null);
    try std.testing.expect(partOfSpeech("persuuenlik veurnaamwaord") == null);
    // A literal protected pseudo-heading remains paragraph content.
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const blocks = try renderer.renderBody("<nowiki>===Persuuenlik veurnaamwaord===\n====Lemma====\n# not a sense</nowiki>");
    const protected = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = blocks }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &protected)).lexemes.len);
}

test "retained LI Reader bodies reorganize lemma senses without changing sections or codec content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, anchor: []const u8 = "", anchor_fallback: []const u8 = "", blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    // Exact complete normal Reader JSON, not reconstructed expanded wikitext.
    const cases = .{
        .{ @embedFile("li-medisch-reader.json"), "medisch", "Mofers", "li", @as(usize, 1), @as(usize, 8), @as(usize, 2), @as(usize, 2), @as(usize, 0) },
        .{ @embedFile("li-ich-reader.json"), "ich", "Algemein Gesjreve Limburgs", "li", @as(usize, 1), @as(usize, 3), @as(usize, 1), @as(usize, 0), @as(usize, 0) },
        .{ @embedFile("li-ich-reader.json"), "ich", "Mofers", "li", @as(usize, 3), @as(usize, 9), @as(usize, 1), @as(usize, 1), @as(usize, 1) },
        .{ @embedFile("li-ik-reader.json"), "ik", "Nederlands", "nl", @as(usize, 0), @as(usize, 3), @as(usize, 1), @as(usize, 1), @as(usize, 0) },
    };
    inline for (cases) |case| {
        const parsed = try std.json.parseFromSlice(Page, a, case[0], .{ .ignore_unknown_fields = true });
        const typed = try std.json.parseFromSlice(TypedPage, a, case[0], .{ .ignore_unknown_fields = true });
        const before = typed.value.entries[0];
        const sections = parsed.value.entries[0].sections[case[4]..case[5]];
        const result = try buildOwned(a, sections, case[2]);
        try std.testing.expectEqual(case[6], result.lexemes.len);
        var senses: usize = 0; var examples: usize = 0;
        for (result.lexemes) |lexical| {
            try std.testing.expectEqualStrings(case[2], lexical.language);
            for (lexical.definitions) |sense| {
                senses += 1; examples += sense.examples.len;
                try std.testing.expect(sense.form == null);
                try std.testing.expectEqual(wiki.Kind.definition, sections[lexical.section].blocks[sense.block].kind);
            }
        }
        try std.testing.expectEqual(case[7], senses);
        try std.testing.expectEqual(case[8], examples);
        // Reader JSON is already the typed semantic body. The compiler-shaped
        // parse above supplies layout indices only: its Span.flags cannot read
        // the JSON's top-level style fields and must never serialize that body.
        var expected: types.Stored = .{ .entry = before };
        expected.entry.language = case[2];
        expected.entry.language_code = case[3];
        expected.entry.sections = before.sections[case[4]..case[5]];
        const organization_json = try std.json.Stringify.valueAlloc(a, result, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        expected.entry.organization = organization.value;
        const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
        const stored = try encoder.presentation_codec.decodeAlloc(a, bytes, case[1], .language, .{ .code = case[3], .heading = case[2] });
        try std.testing.expectEqualStrings(case[2], stored.entry.language.?);
        try std.testing.expectEqualStrings(case[3], stored.entry.language_code);
        try std.testing.expectEqualDeep(expected, stored);
        try std.testing.expectEqualDeep(before.sections[case[4]..case[5]], stored.entry.sections);
        try std.testing.expectEqualDeep(before.display_title, stored.entry.display_title);
        try std.testing.expectEqualDeep(before.references, stored.entry.references);
        try std.testing.expectEqualDeep(before.media, stored.entry.media);
        try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, stored));
        if (std.mem.eql(u8, case[1], "ich") and std.mem.eql(u8, case[2], "Mofers")) {
            try std.testing.expectEqual(@as(usize, 2), result.lexemes[0].section);
            try std.testing.expectEqualSlices(usize, &.{3, 4, 5}, result.lexemes[0].related_sections);
            try std.testing.expectEqual(@as(usize, 1), result.lexemes[0].definitions[0].block);
            try std.testing.expectEqualSlices(usize, &.{2}, result.lexemes[0].definitions[0].examples);
        }
    }
}



test "LI lemma inheritance composes with section-local KAA and SL POS evidence without scope leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "mixed-source-control" } };
    const morphology = try renderer.renderBody("''atlıq'', a-baq\n");
    const kaa = try renderer.renderBody("# KAA meaning [[Target]]\n");
    const sl = try renderer.renderBody("''word, [[glagol]]''\n\n'''Pomeni:'''\n\n# bounded SL meaning\n#: SL example\n\n'''Sources:'''\n\n# bibliography\n");
    const child = try renderer.renderBody("'''ich'''\n# LI child sense\n#: ''LI child example''\n");
    const unrelated = try renderer.renderBody("# must remain supporting body\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "First region", .level = 2 },
        .{ .title = "Morfologiyalıq hám sintaksislik qásiyetleri", .level = 3, .blocks = morphology },
        .{ .title = "Leksikalıq mánileri", .level = 3, .blocks = kaa },
        .{ .title = "Lemma", .level = 4, .blocks = unrelated },
        .{ .title = "SL region", .level = 2, .blocks = sl },
        .{ .title = "Lemma", .level = 3, .blocks = unrelated },
        .{ .title = "Mofers", .level = 2 },
        .{ .title = "Persuuenlik veurnaamwaord", .level = 3 },
        .{ .title = "Lemma", .level = 4, .blocks = child },
        .{ .title = "Unrelated", .level = 4, .blocks = unrelated },
        .{ .title = "Neet-lemma", .level = 4, .blocks = unrelated },
        .{ .title = "Later owner", .level = 2 },
        .{ .title = "Lemma", .level = 4, .blocks = unrelated },
    };
    const result = try buildOwned(a, &sections, "Independently supplied owner");
    try std.testing.expectEqual(@as(usize, 3), result.lexemes.len);
    for (result.lexemes, [_][]const u8{ "Noun", "Verb", "Pronoun" }, [_]usize{ 2, 4, 8 }) |lexical, kind, index| {
        try std.testing.expectEqualStrings(kind, lexical.kind);
        try std.testing.expectEqualStrings("Independently supplied owner", lexical.language);
        try std.testing.expectEqual(index, lexical.section);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expect(lexical.etymology == null and lexical.definitions[0].form == null);
    }
    try std.testing.expectEqualSlices(usize, &.{3}, result.lexemes[0].related_sections);
    try std.testing.expectEqualSlices(usize, &.{5}, result.lexemes[1].related_sections);
    try std.testing.expectEqualSlices(usize, &.{9, 10}, result.lexemes[2].related_sections);
    const sl_sense = result.lexemes[1].definitions[0];
    try std.testing.expectEqualStrings("bounded SL meaning", sl[sl_sense.block].spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), sl_sense.examples.len);
    try std.testing.expectEqualStrings("SL example", sl[sl_sense.examples[0]].spans[0].text);
    try std.testing.expectEqualStrings("bibliography", sl[result.lexemes[1].other_blocks[result.lexemes[1].other_blocks.len - 1]].spans[0].text);
    const li_sense = result.lexemes[2].definitions[0];
    try std.testing.expectEqual(@as(usize, 1), li_sense.block);
    try std.testing.expectEqualSlices(usize, &.{2}, li_sense.examples);
    try std.testing.expectEqualSlices(usize, &.{0, 1, 6, 7, 11, 12}, result.other_sections);
    // Neither a paragraph marker nor morphology evidence is an authored POS
    // heading for a later Lemma; only its own section obtains that kind.
    const codec = @import("blob_encoder").presentation_codec;
    const bytes = try codec.encodeBuildAlloc(a, &.{}, &sections, result, &.{}, &.{});
    const baseline = try codec.encodeBuildAlloc(a, &.{}, &sections, Layout{ .lexemes = &.{}, .other_sections = &.{} }, &.{}, &.{});
    var stored = try codec.decodeAlloc(a, bytes, "mixed-source-control", .language, .{ .heading = "Independently supplied owner", .code = "li" });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    const original = try codec.decodeAlloc(a, baseline, "mixed-source-control", .language, .{ .heading = "Independently supplied owner", .code = "li" });
    try std.testing.expectEqualDeep(original.entry.sections, stored.entry.sections);
    stored.entry.organization = original.entry.organization;
    try std.testing.expectEqualSlices(u8, baseline, try codec.encodeAlloc(a, stored));
}

test "declared POS and direct senses retain precedence when parsed profiles and lemma children coexist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "precedence-control" } };
    const marked = try renderer.renderBody("''word, [[glagol]]''\n\n'''Pomeni:'''\n\n# direct first\n\n'''Sources:'''\n\n# direct second\n");
    const sense = try renderer.renderBody("# child sense\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const declared = [_]Section{
        .{ .title = "Noun", .level = 2, .blocks = marked },
        .{ .title = "Lemma", .level = 3, .blocks = sense },
    };
    const explicit = try buildOwned(a, &declared, "Known owner");
    try std.testing.expectEqual(@as(usize, 2), explicit.lexemes.len);
    try std.testing.expectEqualStrings("Noun", explicit.lexemes[0].kind);
    try std.testing.expectEqualStrings("Noun", explicit.lexemes[1].kind);
    try std.testing.expectEqual(@as(usize, 2), explicit.lexemes[0].definitions.len);
    try std.testing.expectEqual(@as(usize, 1), explicit.lexemes[1].definitions.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &declared)).lexemes.len);
    // A child with its own SL proof does not inherit this empty parent. Keep
    // both the authored Noun and the independently bounded Verb analysis.
    const independent_child = [_]Section{
        .{ .title = "Noun", .level = 1 },
        .{ .title = "Lemma", .level = 2, .blocks = marked },
    };
    const independent = try buildOwned(a, &independent_child, "Known owner");
    try std.testing.expectEqual(@as(usize, 2), independent.lexemes.len);
    try std.testing.expectEqualStrings("Noun", independent.lexemes[0].kind);
    try std.testing.expectEqual(@as(usize, 0), independent.lexemes[0].section);
    try std.testing.expectEqual(@as(usize, 0), independent.lexemes[0].definitions.len);
    try std.testing.expectEqualStrings("Verb", independent.lexemes[1].kind);
    try std.testing.expectEqual(@as(usize, 1), independent.lexemes[1].section);
    try std.testing.expectEqual(@as(usize, 1), independent.lexemes[1].definitions.len);
    const children = [_]Section{
        .{ .title = "Mofers", .level = 2 },
        .{ .title = "Persuuenlik veurnaamwaord", .level = 3, .blocks = sense },
        .{ .title = "Lemma", .level = 4, .blocks = sense },
        .{ .title = "Neet-lemma", .level = 4, .blocks = sense },
        .{ .title = "Support", .level = 4, .blocks = sense },
        .{ .title = "Lemma", .level = 4, .blocks = sense },
        .{ .title = "Unknown POS", .level = 3 },
        .{ .title = "Lemma", .level = 4, .blocks = sense },
    };
    const result = try buildOwned(a, &children, "Mofers");
    try std.testing.expectEqual(@as(usize, 3), result.lexemes.len);
    for (result.lexemes, 1..) |lexical, section_index| {
        try std.testing.expectEqual(section_index, lexical.section);
        try std.testing.expectEqualStrings("Pronoun", lexical.kind);
        try std.testing.expectEqualStrings("Mofers", lexical.language);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].block);
        try std.testing.expect(lexical.definitions[0].form == null);
    }
    try std.testing.expectEqualSlices(usize, &.{4, 5}, result.lexemes[2].related_sections);
    try std.testing.expectEqualSlices(usize, &.{0, 6, 7}, result.other_sections);
}



test "SL noun template entity spacing follows a parsed headword and comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "oko" } };
    // Predloga:samostalnik p17834/r170902 emits this selected noun convention.
    // This is parsed source evidence, not a reconstruction of Reader provenance.
    const prefix = "''oko'',&#32;[[samostalnik]] [[srednji|srednjega]] [[spol]]a, '''oko''' dv '''očesi''' mn '''očesa''' posebna mn '''oči'''";
    const body = prefix ++ "\n\n'''Pomeni:'''\n\n# [[človek|človeški]] ali [[žival]]ski [[organ]], ki omogoča [[vid]].\n";
    const blocks = try renderer.renderBody(body);
    try std.testing.expectEqualStrings("oko", blocks[0].spans[0].text);
    try std.testing.expect(blocks[0].spans[0].provenance == .parsed and blocks[0].spans[0].flags.italic);
    try std.testing.expectEqualStrings(",", blocks[0].spans[1].text);
    try std.testing.expect(blocks[0].spans[1].provenance == .parsed);
    try std.testing.expectEqualStrings(" ", blocks[0].spans[2].text);
    try std.testing.expect(blocks[0].spans[2].provenance == .entity_literal);
    try std.testing.expectEqualStrings("Noun", sloveneHeadwordPart(blocks[0]).?);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const sections = [_]Section{.{ .title = "Independent supplied owner", .level = 2, .blocks = blocks }};
    const organization = try buildOwned(a, &sections, "Independent supplied owner");
    try std.testing.expectEqual(@as(usize, 1), organization.lexemes.len);
    const noun = organization.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Independent supplied owner", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    try std.testing.expect(markedParagraphPart(blocks, null, 2) == null);
    try std.testing.expect(markedParagraphPart(blocks, "", 2) == null);
    try std.testing.expect(markedParagraphPart(blocks, "Unclassified", 2) == null);
    try std.testing.expect(markedParagraphPart(blocks, "Independent supplied owner", 3) == null);
    const multiple = try renderer.renderBody("''oko'',&#32;&#32;[[samostalnik]]");
    try std.testing.expectEqualStrings("Noun", sloveneHeadwordPart(multiple[0]).?);
    // Numeric LF/HT references normalize to ordinary entity-literal space.
    for ([_][]const u8{ "''oko'',&#10;[[samostalnik]]", "''oko'',&#9;[[samostalnik]]" }) |source| {
        const normalized = try renderer.renderBody(source);
        try std.testing.expectEqualStrings(" ", normalized[0].spans[2].text);
        try std.testing.expect(normalized[0].spans[2].provenance == .entity_literal);
        try std.testing.expectEqualStrings("Noun", sloveneHeadwordPart(normalized[0]).?);
    }
    const post_pos = try renderer.renderBody("''word, [[glagol]]'',&#32;[[nedovršen]]");
    try std.testing.expectEqualStrings("Verb", sloveneHeadwordPart(post_pos[0]).?);
}

test "SL pre-POS entity whitespace never supplies headword comma POS or protected authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "oko" } };
    for ([_][]const u8{
        "&#32;''oko'', [[samostalnik]]",
        "''oko''&#32;[[samostalnik]]",
        "''oko''&#32;, [[samostalnik]]",
        "''&#111;ko'',&#32;[[samostalnik]]",
        "''oko''&#44;&#32;[[samostalnik]]",
        "''oko'',&#120;[[samostalnik]]",
        "''oko'',&nbsp;[[samostalnik]]",
        "''oko'',<nowiki> </nowiki>[[samostalnik]]",
        "''oko'',<code>&#32;</code>[[samostalnik]]",
        "''oko'',&#32;[[samostalnik|&#115;amostalnik]]",
        "''oko'',&#32;[[samostalnik|<nowiki>samostalnik</nowiki>]]",
        "''word,&#32;[[glagol]]''",
        "''oko'','''&#32;'''[[samostalnik]]",
    }) |source| {
        const blocks = try renderer.renderBody(source);
        try std.testing.expect(sloveneHeadwordPart(blocks[0]) == null);
    }
    const blocks = try renderer.renderBody("''oko'',&#32;[[samostalnik]]\n\n'''Pomeni:'''\n\n# organ");
    const mutated = try a.dupe(wiki.Span, blocks[0].spans);
    var headword = blocks[0];
    headword.spans = mutated;
    for ([_]usize{ 0, 1, 3 }) |index| {
        const original = mutated[index];
        mutated[index].provenance = .entity_literal;
        try std.testing.expect(sloveneHeadwordPart(headword) == null);
        mutated[index] = original;
    }
    const original_space = mutated[2];
    mutated[2].text = "\n";
    try std.testing.expect(sloveneHeadwordPart(headword) == null);
    mutated[2] = original_space;
    for ([_]wiki.Provenance{ .protected_literal, .entity_literal }) |provenance| {
        const original = mutated[2];
        mutated[2].provenance = provenance;
        mutated[2].generated_diagnostic = true;
        try std.testing.expect(sloveneHeadwordPart(headword) == null);
        mutated[2] = original;
    }
}



test "complete observed Native10 SL oko adds noun organization preserving all saved body fields and codec" {
    const types = @import("blob_encoder").presentation_types;
    const codec = @import("blob_encoder").presentation_codec;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Complete saved normal Reader entry f0a68262. Reader omits source provenance
    // and some Stored fields; this proves its complete observable graph, not a
    // full expanded capture or normal-loader rerun. Parse the exact headword
    // convention separately to avoid inventing parsed provenance for its entity.
    const observed_json =
        \\{"organization":{"lexemes":[],"other_sections":[0,1]},"title":"oko","display_title":[],"kind":"language","language":"slovenščina","language_code":"sl","sections":[{"level":2,"title":"Slovenščina","anchor":"Slovenščina","anchor_fallback":"Sloven.C5.A1.C4.8Dina","blocks":[{"kind":"heading","depth":0,"spans":[{"kind":"text","text":"","target":"","trail":"","language":"","classes":"wikidict-media wikidict-media-file-466c6167206f6620536c6f76656e69612e737667","direction":"","explanation":"","foreground":null,"image":{"file":"Flag of Slovenia.svg","width_px":50},"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" Slovenščina","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":2,"anchor":"Slovenščina","anchor_fallback":"Sloven.C5.A1.C4.8Dina","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"oko","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":",","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"samostalnik","target":"samostalnik","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"srednjega","target":"srednji","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"spol","target":"spol","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"a","target":"spol","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"oko","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" dv ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"očesi","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" mn ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"očesa","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" posebna mn ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"oči","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Pomeni:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"definition","depth":1,"spans":[{"kind":"link","text":"človeški","target":"človek","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ali ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"žival","target":"žival","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ski","target":"žival","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"organ","target":"organ","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ki omogoča ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"vid","target":"vid","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":".","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"#","number":"1","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Besedne zveze:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"indent","depth":1,"spans":[{"kind":"link","text":"mačje oko","target":"mačje oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"tigrovo oko","target":"tigrovo oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"tretje oko","target":"tretje oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":":","number":"","level":0,"anchor":"","anchor_fallback":"","table":null}]},{"level":4,"title":"Prevodi","anchor":"Prevodi","anchor_fallback":"","blocks":[{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"anatomija","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"table","depth":0,"spans":[],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":{"caption":[],"rows":[{"cells":[{"spans":[{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Angleško: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"eye","target":"eye","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(en)","target":"https://en.wiktionary.org/wiki/eye","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Baskovsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"begi","target":"begi","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(eu)","target":"https://eu.wiktionary.org/wiki/begi","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Francosko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"œil","target":"œil","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(fr)","target":"https://fr.wiktionary.org/wiki/%C5%93il","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Galicijsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ollo","target":"ollo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(gl)","target":"https://gl.wiktionary.org/wiki/ollo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Italijansko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"occhio","target":"occhio","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(it)","target":"https://it.wiktionary.org/wiki/occhio","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#ffffe0"},{"spans":[],"header":false,"colspan":1,"rowspan":1,"background":null},{"spans":[{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Katalonsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ull","target":"ull","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(ca)","target":"https://ca.wiktionary.org/wiki/ull","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Latinsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"oculus","target":"oculus","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", i, ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(la)","target":"https://la.wiktionary.org/wiki/oculus","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Nemško: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"Auge","target":"Auge","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(de)","target":"https://de.wiktionary.org/wiki/Auge","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Portugalsko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"olho","target":"olho","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(pt)","target":"https://pt.wiktionary.org/wiki/olho","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"line_break","text":"\n","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"• ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"Špansko: ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"ojo","target":"ojo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"m","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":true,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"external_link","text":"(es)","target":"https://es.wiktionary.org/wiki/ojo","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":"|}","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":"#ffffe0"}]}],"geometry":{"border":0,"cell_spacing":null,"cell_padding":null,"width":{"unit":"percent","value":100}}}},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"[malformed table]","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Rime:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"indent","depth":1,"spans":[{"kind":"link","text":"meso","target":"meso","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":", ","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"link","text":"pero","target":"pero","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":":","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"paragraph","depth":0,"spans":[{"kind":"text","text":"Zunanje povezave:","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":null},{"kind":"table","depth":0,"spans":[],"feature":null,"list_path":"","number":"","level":0,"anchor":"","anchor_fallback":"","table":{"caption":[],"rows":[{"cells":[{"spans":[{"kind":"link","text":"","target":"File:Wikipedia-logo.png","trail":"","language":"","classes":"wikidict-media wikidict-media-file-57696b6970656469612d6c6f676f2e706e67","direction":"","explanation":"","foreground":null,"image":{"file":"Wikipedia-logo.png","width_px":20,"alt":"Commons","tooltip":"Commons"},"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":null},{"spans":[{"kind":"external_link","text":"oko","target":"https://sl.wikipedia.org/wiki/oko","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":true,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"},{"kind":"text","text":" – članek v Wikipediji","target":"","trail":"","language":"","classes":"","direction":"","explanation":"","foreground":null,"bold":false,"italic":false,"code":false,"small":false,"superscript":false,"subscript":false,"strike":false,"underline":false,"role":"normal"}],"header":false,"colspan":1,"rowspan":1,"background":null}]}],"geometry":{"border":0,"cell_spacing":1,"cell_padding":null,"width":null}}}]}],"preamble_spans":[],"references":[],"media":[{"file":"Flag of Slovenia.svg","kind":"image","caption":"Flag of Slovenia.svg"},{"file":"Wikipedia-logo.png","kind":"image","caption":"Commons"}],"redirect":null,"alias":null}
    ;
    const before = (try std.json.parseFromSlice(types.Entry, a, observed_json, .{})).value;
    try std.testing.expectEqualStrings("oko", before.title);
    try std.testing.expectEqualStrings("sl", before.language_code);
    try std.testing.expectEqualStrings("slovenščina", before.language.?);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "oko" } };
    const headword = try renderer.renderBody("''oko'',&#32;[[samostalnik]] [[srednji|srednjega]] [[spol]]a, '''oko''' dv '''očesi''' mn '''očesa''' posebna mn '''oči'''");
    try std.testing.expect(headword[0].spans[2].provenance == .entity_literal);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const sections = try a.alloc(Section, before.sections.len);
    for (before.sections, sections, 0..) |source_section, *section, section_index| {
        const blocks = try a.alloc(wiki.Block, source_section.blocks.len);
        for (source_section.blocks, blocks, 0..) |source_block, *block, block_index| {
            const spans = try a.alloc(wiki.Span, source_block.spans.len);
            for (source_block.spans, spans) |source_span, *span| {
                try std.testing.expectEqualStrings("", source_span.trail);
                span.* = .{
                    .kind = std.meta.stringToEnum(@TypeOf(span.kind), @tagName(source_span.kind)).?,
                    .text = source_span.text, .target = source_span.target,
                    .language = source_span.language, .classes = source_span.classes,
                    .direction = source_span.direction, .explanation = source_span.explanation,
                    .foreground = source_span.foreground, .background = source_span.background,
                    .font_scale = source_span.font_scale, .font_scale_basis = source_span.font_scale_basis,
                    .role = std.meta.stringToEnum(@TypeOf(span.role), @tagName(source_span.role)).?,
                    .flags = .{
                        .bold = source_span.bold, .italic = source_span.italic,
                        .code = source_span.code, .small = source_span.small,
                        .superscript = source_span.superscript, .subscript = source_span.subscript,
                        .strike = source_span.strike, .underline = source_span.underline,
                    },
                };
            }
            block.* = .{
                .kind = std.meta.stringToEnum(wiki.Kind, @tagName(source_block.kind)).?,
                .depth = source_block.depth, .spans = spans,
                .list_path = source_block.list_path, .number = source_block.number,
                .level = source_block.level, .anchor = source_block.anchor,
                .anchor_fallback = source_block.anchor_fallback,
            };
            if (section_index == 0 and block_index == 1) {
                try std.testing.expectEqual(source_block.spans.len, headword[0].spans.len);
                for (source_block.spans, headword[0].spans) |saved, parsed| {
                    try std.testing.expectEqualStrings(saved.text, parsed.text);
                    try std.testing.expectEqualStrings(saved.target, parsed.target);
                    try std.testing.expectEqual(saved.bold, parsed.flags.bold);
                    try std.testing.expectEqual(saved.italic, parsed.flags.italic);
                }
                block.spans = headword[0].spans;
            }
        }
        section.* = .{ .title = source_section.title, .level = source_section.level, .blocks = blocks };
    }
    const organization = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), organization.lexemes.len);
    const noun = organization.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings(before.language.?, noun.language);
    try std.testing.expectEqual(@as(usize, 0), noun.section);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    const sense = noun.definitions[0];
    try std.testing.expectEqual(@as(usize, 3), sense.block);
    try std.testing.expect(sense.parent == null and sense.form == null);
    try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
    try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
    try std.testing.expectEqual(@as(usize, 0), sense.notes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{ 4, 5 }, noun.other_blocks);
    try std.testing.expectEqualSlices(usize, &.{1}, noun.related_sections);
    try std.testing.expectEqual(@as(usize, 0), organization.other_sections.len);
    var text: std.ArrayList(u8) = .empty;
    for (before.sections[0].blocks[sense.block].spans) |span| try text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("človeški ali živalski organ, ki omogoča vid.", text.items);
    const bytes = try codec.encodeBuildAlloc(a, before.display_title, before.sections, organization, before.references, before.media);
    const stored = try codec.decodeAlloc(a, bytes, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
    try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
    try std.testing.expectEqualDeep(before.sections, stored.entry.sections);
    try std.testing.expectEqualDeep(before.display_title, stored.entry.display_title);
    try std.testing.expectEqualDeep(before.references, stored.entry.references);
    try std.testing.expectEqualDeep(before.media, stored.entry.media);
    var normalized = stored;
    normalized.entry.organization = before.organization;
    try std.testing.expectEqualSlices(u8, try codec.encodeAlloc(a, .{ .entry = before }), try codec.encodeAlloc(a, normalized));
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
}


test "Catalan POS labels preserve supplied owners and do not classify unknown languages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const body = [_]wiki.Block{
        .{ .kind = .paragraph },
        .{ .kind = .definition, .list_path = "#" },
        .{ .kind = .example, .list_path = "#:" },
    };
    const sections = [_]Section{
        .{ .title = "Independently supplied language", .level = 2 },
        .{ .title = "Nom", .level = 3, .blocks = &body },
        .{ .title = "Related", .level = 4 },
        .{ .title = "Adjectiu", .level = 3, .blocks = &body },
        .{ .title = "Unknown POS", .level = 3, .blocks = &body },
    };
    const result = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 2), result.lexemes.len);
    try std.testing.expectEqualStrings("Noun", result.lexemes[0].kind);
    try std.testing.expectEqualStrings("Adjective", result.lexemes[1].kind);
    for (result.lexemes, [_]usize{ 1, 3 }) |lexical, section| {
        try std.testing.expectEqualStrings("French", lexical.language);
        try std.testing.expectEqual(section, lexical.section);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
        try std.testing.expect(lexical.definitions[0].form == null);
    }
    try std.testing.expectEqualSlices(usize, &.{2}, result.lexemes[0].related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, result.other_sections);
    for ([_][]const u8{ "nom", "NOM", "adjectiu", "Adjectiu desconegut", "Unknown POS" }) |unknown|
        try std.testing.expect(partOfSpeech(unknown) == null);
    // An unresolved L2 can be a language boundary, not a POS declaration.
    const unresolved = [_]Section{
        .{ .title = "Nom", .level = 2, .blocks = &body },
        .{ .title = "Adjectiu", .level = 2, .blocks = &body },
    };
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &unresolved)).lexemes.len);
    // Nested POS organization is allowed without inventing an owner.
    const unowned = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 2), unowned.lexemes.len);
    for (unowned.lexemes) |lexical| try std.testing.expectEqualStrings("", lexical.language);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const protected = try renderer.renderBody("<nowiki>===Nom===\n# not a structured definition\n===Adjectiu===</nowiki>");
    const literal = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = protected }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &literal)).lexemes.len);
}

test "retained catalan three owned bodies gain exact noun adjective senses without changing Stored content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    const cases = .{
        .{ @embedFile("ca-catalan-ast-reader.json"), "Asturian", "ast", @as(usize, 1) },
        .{ @embedFile("ca-catalan-gl-reader.json"), "Galician", "gl", @as(usize, 3) },
        .{ @embedFile("ca-catalan-es-reader.json"), "Spanish", "es", @as(usize, 3) },
    };
    inline for (cases) |case| {
        // The compiler view supplies layout indices only; it never serializes
        // the Reader body's top-level style flags. Retain the typed Entry.
        const projected = try std.json.parseFromSlice(Page, a, case[0], .{ .ignore_unknown_fields = true });
        const typed = try std.json.parseFromSlice(TypedPage, a, case[0], .{ .ignore_unknown_fields = true });
        const before = typed.value.entries[0];
        try std.testing.expectEqualStrings("catalán", before.title);
        try std.testing.expectEqualStrings(case[1], before.language.?);
        try std.testing.expectEqualStrings(case[2], before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = projected.value.entries[0].sections;
        const layout = try buildOwned(a, sections, before.language.?);
        try std.testing.expectEqual(case[3], layout.lexemes.len);
        for (layout.lexemes, 0..) |lexical, index| {
            try std.testing.expectEqualStrings(case[1], lexical.language);
            try std.testing.expectEqualStrings(if (case[3] == 3 and index == 0) "Adjective" else "Noun", lexical.kind);
            try std.testing.expectEqual(index + 1, lexical.section);
            try std.testing.expect(lexical.etymology == null);
            try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
            try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
            try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].examples.len);
            try std.testing.expect(lexical.definitions[0].form == null);
            try std.testing.expectEqual(wiki.Kind.definition, sections[lexical.section].blocks[lexical.definitions[0].block].kind);
            try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
            try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
        }
        if (std.mem.eql(u8, case[2], "es")) {
            try std.testing.expectEqualSlices(usize, &.{ 0, 4, 5 }, layout.other_sections);
        } else try std.testing.expectEqualSlices(usize, &.{0}, layout.other_sections);
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = organization.value;
        const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = case[2], .heading = case[1] });
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
        try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
        try std.testing.expectEqualDeep(before.references, decoded.entry.references);
        try std.testing.expectEqualDeep(before.media, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}


test "Basque POS labels retain independent owners and reject unknown boundary labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const body = [_]wiki.Block{ .{ .kind = .indent, .list_path = ":" }, .{ .kind = .list_item, .list_path = ":#" } };
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Izena", .level = 3, .blocks = &body },
        .{ .title = "Support", .level = 4, .blocks = &body },
        .{ .title = "Adjektiboa", .level = 3, .blocks = &body },
        .{ .title = "Unknown", .level = 3, .blocks = &body },
    };
    const result = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 2), result.lexemes.len);
    for (result.lexemes, [_]usize{ 1, 3 }, [_][]const u8{ "Noun", "Adjective" }) |lexeme, section, kind| {
        try std.testing.expectEqualStrings("French", lexeme.language);
        try std.testing.expectEqualStrings(kind, lexeme.kind);
        try std.testing.expectEqual(section, lexeme.section);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
        try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
    }
    try std.testing.expectEqualSlices(usize, &.{2}, result.lexemes[0].related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, result.other_sections);
    for ([_][]const u8{ "izena", "IZENA", "adjektiboa", "Adjektiboa unknown" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const ambiguous = [_]Section{.{ .title = "Izena", .level = 2, .blocks = &body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &ambiguous)).lexemes.len);
    const unowned = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 2), unowned.lexemes.len);
    for (unowned.lexemes) |lexeme| try std.testing.expectEqualStrings("", lexeme.language);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const literal = try renderer.renderBody("<nowiki>===Izena===\n:# literal, not a sense</nowiki>");
    const protected = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = literal }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &protected)).lexemes.len);
}

test "indented numbered meanings require declared POS and retain lemma scope barriers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = [_]wiki.Block{
        .{ .kind = .list_item, .list_path = ":*" },
        .{ .kind = .paragraph, .list_path = ":#" },
        .{ .kind = .list_item, .list_path = "*#" },
        .{ .kind = .list_item, .list_path = ":#" },
        .{ .kind = .list_item, .list_path = ":#" },
    };
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "Noun", 0, null, &blocks, false)).definitions.len);
    const explicit = try analyze(a, "Noun", 0, null, &blocks, true);
    try std.testing.expectEqual(@as(usize, 2), explicit.definitions.len);
    try std.testing.expectEqual(@as(usize, 3), explicit.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 4), explicit.definitions[1].block);
    for (explicit.definitions) |sense| try std.testing.expect(sense.parent == null);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const meaning = [_]wiki.Block{.{ .kind = .list_item, .list_path = ":#" }};
    const sections = [_]Section{
        .{ .title = "Owner", .level = 2 },
        .{ .title = "Noun", .level = 3, .blocks = &meaning },
        .{ .title = "Lemma", .level = 4, .blocks = &meaning },
        .{ .title = "Unrelated", .level = 3 },
        .{ .title = "Neet-lemma", .level = 4, .blocks = &meaning },
        .{ .title = "Later owner", .level = 2 },
        .{ .title = "Lemma", .level = 3, .blocks = &meaning },
    };
    const scoped = try buildOwned(a, &sections, "Supplied owner");
    try std.testing.expectEqual(@as(usize, 2), scoped.lexemes.len);
    for (scoped.lexemes, [_]usize{ 1, 2 }) |lexeme, section| {
        try std.testing.expectEqual(section, lexeme.section);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].block);
        try std.testing.expectEqualStrings("Supplied owner", lexeme.language);
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 4, 5, 6 }, scoped.other_sections);
}

test "retained Basque five owned records gain six senses with complete Stored codec parity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    const cases = .{
        .{ @embedFile("eu-dwa-ht-reader.json"), "dwa", "Haitiko kreolera", "ht", "Noun", @as(usize, 3) },
        .{ @embedFile("eu-dwa-csb-reader.json"), "dwa", "Kashubian", "csb", "Adjective", @as(usize, 2) },
        .{ @embedFile("eu-dwa-pl-reader.json"), "dwa", "poloniera", "pl", "Adjective", @as(usize, 2) },
        .{ @embedFile("eu-ama-eu-reader.json"), "ama", "euskara", "eu", "Noun", @as(usize, 4) },
        .{ @embedFile("eu-ama-gn-reader.json"), "ama", "guaraniera", "gn", "Noun", @as(usize, 3) },
    };
    inline for (cases) |case| {
        const projected = try std.json.parseFromSlice(Page, a, case[0], .{ .ignore_unknown_fields = true });
        const typed = try std.json.parseFromSlice(TypedPage, a, case[0], .{ .ignore_unknown_fields = true });
        const before = typed.value.entries[0];
        try std.testing.expectEqualStrings(case[1], before.title);
        try std.testing.expectEqualStrings(case[2], before.language.?);
        try std.testing.expectEqualStrings(case[3], before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = projected.value.entries[0].sections;
        const layout = try buildOwned(a, sections, before.language.?);
        const basque = std.mem.eql(u8, case[3], "eu");
        try std.testing.expectEqual(@as(usize, if (basque) 2 else 1), layout.lexemes.len);
        for (layout.lexemes, 0..) |lexeme, n| {
            try std.testing.expectEqualStrings(case[2], lexeme.language);
            try std.testing.expectEqualStrings(case[4], lexeme.kind);
            try std.testing.expectEqual(case[5] + n * 4, lexeme.section);
            try std.testing.expect(lexeme.etymology == null);
            try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
            const sense = lexeme.definitions[0];
            try std.testing.expectEqual(@as(usize, if (basque) 0 else 1), sense.block);
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
            try std.testing.expectEqual(@as(usize, 0), sense.notes.len);
            if (basque) {
                try std.testing.expectEqualSlices(usize, &.{1}, sense.quotations);
                try std.testing.expectEqual(wiki.Kind.definition, sections[lexeme.section].blocks[sense.block].kind);
            } else {
                try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
                try std.testing.expectEqual(wiki.Kind.list_item, sections[lexeme.section].blocks[sense.block].kind);
                try std.testing.expectEqualStrings(":#", sections[lexeme.section].blocks[sense.block].list_path);
            }
        }
        if (std.mem.eql(u8, case[3], "pl")) try std.testing.expectEqualSlices(usize, &.{3}, layout.lexemes[0].related_sections);
        if (basque) {
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 5, 6, 7, 9, 10, 11 }, layout.other_sections);
            for (layout.lexemes) |lexeme| try std.testing.expectEqual(@as(usize, 0), lexeme.related_sections.len);
        } else if (std.mem.eql(u8, case[3], "csb") or std.mem.eql(u8, case[3], "pl")) {
            try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, layout.other_sections);
        } else try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, layout.other_sections);
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = organization.value;
        const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = case[3], .heading = case[2] });
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
        try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
        try std.testing.expectEqualDeep(before.references, decoded.entry.references);
        try std.testing.expectEqualDeep(before.media, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}


test "Gaelic noun label preserves independent owner and unresolved boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const body = [_]wiki.Block{.{ .kind = .definition, .list_path = "#" }};
    const sections = [_]Section{
        .{ .title = "Independent", .level = 2 },
        .{ .title = "Ainmear", .level = 3, .blocks = &body },
        .{ .title = "Unknown", .level = 3, .blocks = &body },
    };
    const owned = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes.len);
    try std.testing.expectEqualStrings("Noun", owned.lexemes[0].kind);
    try std.testing.expectEqualStrings("French", owned.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes[0].section);
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes[0].definitions.len);
    for ([_][]const u8{ "ainmear", "AINMEAR", "Ainmear1", "Ainmear unknown" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const ambiguous = [_]Section{.{ .title = "Ainmear", .level = 2, .blocks = &body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &ambiguous)).lexemes.len);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const literal = try renderer.renderBody("<nowiki>===Ainmear===\n# literal</nowiki>");
    const protected = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = literal }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &protected)).lexemes.len);
}

test "retained Gaelic six records preserve nested senses support errors and full Stored codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    const cases = .{
        .{ @embedFile("gd-cat-en-reader.json"), "cat", "Beurla", "en", @as(usize, 2) },
        .{ @embedFile("gd-cat-gd-reader.json"), "cat", "Gàidhlig", "gd", @as(usize, 10) },
        .{ @embedFile("gd-cat-ga-reader.json"), "cat", "Gàidhlig na h-Èireann", "ga", @as(usize, 1) },
        .{ @embedFile("gd-cat-support-reader.json"), "cat", "Unclassified", "", @as(usize, 0) },
        .{ @embedFile("gd-cu-gd-reader.json"), "cù", "Gàidhlig", "gd", @as(usize, 3) },
        .{ @embedFile("gd-cu-support-reader.json"), "cù", "Unclassified", "", @as(usize, 0) },
    };
    inline for (cases) |case| {
        const projected = try std.json.parseFromSlice(Page, a, case[0], .{ .ignore_unknown_fields = true });
        const typed = try std.json.parseFromSlice(TypedPage, a, case[0], .{ .ignore_unknown_fields = true });
        const before = typed.value.entries[0];
        try std.testing.expectEqualStrings(case[1], before.title);
        try std.testing.expectEqualStrings(case[2], before.language.?);
        try std.testing.expectEqualStrings(case[3], before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = projected.value.entries[0].sections;
        const layout = if (case[3].len == 0) try buildUnclassified(a, sections) else try buildOwned(a, sections, case[2]);
        try std.testing.expectEqual(@as(usize, if (case[4] == 0) 0 else 1), layout.lexemes.len);
        if (case[4] != 0) {
            const lexical = layout.lexemes[0];
            try std.testing.expectEqualStrings("Noun", lexical.kind);
            try std.testing.expectEqualStrings(case[2], lexical.language);
            try std.testing.expectEqual(@as(usize, 3), lexical.section);
            try std.testing.expect(lexical.etymology == null);
            try std.testing.expectEqual(case[4], lexical.definitions.len);
            try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
            try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
            const block_indices: []const usize = if (case[4] == 10) &.{ 1, 3, 4, 5, 6, 7, 8, 9, 10, 11 } else if (case[4] == 3) &.{ 1, 2, 4 } else if (case[4] == 2) &.{ 1, 2 } else &.{1};
            for (lexical.definitions, block_indices, 0..) |sense, block, index| {
                try std.testing.expectEqual(block, sense.block);
                try std.testing.expectEqual(wiki.Kind.definition, sections[3].blocks[block].kind);
                const parent: ?usize = if (case[4] != 10 or index == 0) null else if (index == 3 or index == 4) 2 else 0;
                try std.testing.expectEqual(parent, sense.parent);
                if (case[4] == 10 and index == 0) try std.testing.expectEqualSlices(usize, &.{2}, sense.examples) else try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
                try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
                try std.testing.expectEqual(@as(usize, 0), sense.notes.len);
                try std.testing.expect(sense.form == null);
            }
            if (case[4] == 3) try std.testing.expectEqualSlices(usize, &.{3}, lexical.other_blocks) else try std.testing.expectEqual(@as(usize, 0), lexical.other_blocks.len);
        }
        if (case[4] == 0) {
            try std.testing.expectEqualSlices(usize, &.{0}, layout.other_sections);
        } else if (case[4] == 3) {
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4, 5, 6 }, layout.other_sections);
        } else if (case[4] == 1) {
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4, 5 }, layout.other_sections);
        } else try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, layout.other_sections);
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = organization.value;
        const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = case[3], .heading = case[2] });
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
        try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
        try std.testing.expectEqualDeep(before.references, decoded.entry.references);
        try std.testing.expectEqualDeep(before.media, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}


test "Slovak meaning children retain local senses independent owners and closed boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Podstatné meno").?);
    for ([_][]const u8{ "podstatné meno", "PODSTATNÉ MENO", "Podstatné mená", "Podstatné meno 2", "Podstatné meno extra", "Podstatné", "meno" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const gender = [_]wiki.Block{.{ .kind = .list_item, .list_path = "*" }};
    const senses = [_]wiki.Block{.{ .kind = .definition, .list_path = "#" }};
    const sections = [_]Section{
        .{ .title = "Existing owner", .level = 2 },
        .{ .title = "Podstatné meno", .level = 3, .blocks = &gender },
        .{ .title = "Význam", .level = 4, .blocks = &senses },
        .{ .title = "Unknown", .level = 3, .blocks = &senses },
    };
    for ([_][]const u8{ "slovenčina", "čeština", "Independent other owner" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const noun = layout.lexemes[0];
        try std.testing.expectEqualStrings(owner, noun.language);
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqual(@as(usize, 2), noun.section);
        try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].block);
        try std.testing.expectEqual(@as(usize, 0), noun.introduction.len);
        try std.testing.expectEqual(@as(usize, 0), noun.related_sections.len);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, layout.other_sections);
    }
    // Explicit nested POS structure is useful even when language ownership is
    // unknown. It must not acquire the surrounding unresolved label as owner.
    const unclassified = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unclassified.lexemes.len);
    try std.testing.expectEqualStrings("", unclassified.lexemes[0].language);
    try std.testing.expectEqualStrings("Noun", unclassified.lexemes[0].kind);
    try std.testing.expectEqual(@as(usize, 2), unclassified.lexemes[0].section);
    try std.testing.expectEqual(@as(usize, 1), unclassified.lexemes[0].definitions.len);
    try std.testing.expectEqual(@as(usize, 0), unclassified.lexemes[0].definitions[0].block);
    const ownerless = try build(a, sections[1..]);
    try std.testing.expectEqual(@as(usize, 1), ownerless.lexemes.len);
    try std.testing.expectEqualStrings("", ownerless.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 1), ownerless.lexemes[0].section);
    try std.testing.expectEqual(@as(usize, 1), ownerless.lexemes[0].definitions.len);
    try std.testing.expectEqual(@as(usize, 0), ownerless.lexemes[0].definitions[0].block);
    const separated = [_]Section{
        .{ .title = "Podstatné meno", .level = 3, .blocks = &gender },
        .{ .title = "Different boundary", .level = 3 },
        .{ .title = "Význam", .level = 4, .blocks = &senses },
    };
    try std.testing.expect(slovakMeaningParent(&separated, 2) == null);
    const deeper = [_]Section{
        .{ .title = "Podstatné meno", .level = 3 },
        .{ .title = "Význam", .level = 5, .blocks = &senses },
    };
    try std.testing.expect(slovakMeaningParent(&deeper, 1) == null);
    const no_definition = [_]Section{
        .{ .title = "Podstatné meno", .level = 3 },
        .{ .title = "Význam", .level = 4, .blocks = &gender },
    };
    try std.testing.expect(slovakMeaningParent(&no_definition, 1) == null);
    const foreign_parent = [_]Section{
        .{ .title = "Verb", .level = 3 },
        .{ .title = "Význam", .level = 4, .blocks = &senses },
    };
    try std.testing.expect(slovakMeaningParent(&foreign_parent, 1) == null);
    const ambiguous = [_]Section{.{ .title = "Podstatné meno", .level = 2, .blocks = &senses }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &ambiguous)).lexemes.len);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const literal = try renderer.renderBody("<nowiki>===Podstatné meno===\n# literal</nowiki>");
    const protected = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = literal }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &protected, "Independent owner")).lexemes.len);
}

test "retained Slovak biola and Czech houslista Reader bodies change only noun organization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    const cases = .{
        .{ @embedFile("sk-biola-reader.json"), "biola", "slovenčina", "sk", @as(usize, 2), @as(usize, 3) },
        .{ @embedFile("sk-houslista-reader.json"), "houslista", "čeština", "cs", @as(usize, 3), @as(usize, 5) },
    };
    inline for (cases) |case| {
        const projected = try std.json.parseFromSlice(Page, a, case[0], .{ .ignore_unknown_fields = true });
        const typed = try std.json.parseFromSlice(TypedPage, a, case[0], .{ .ignore_unknown_fields = true });
        const before = typed.value.entries[0];
        try std.testing.expectEqualStrings(case[1], before.title);
        try std.testing.expectEqualStrings(case[2], before.language.?);
        try std.testing.expectEqualStrings(case[3], before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = projected.value.entries[0].sections;
        const layout = try buildOwned(a, sections, before.language.?);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const noun = layout.lexemes[0];
        try std.testing.expectEqualStrings(case[2], noun.language);
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqual(case[5], noun.section);
        try std.testing.expectEqualStrings("Podstatné meno", sections[case[4]].title);
        try std.testing.expect(noun.etymology == null);
        // Meaning blocks remain local to the authored child section. The
        // default Reader can now render these actual senses without details.
        try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].block);
        try std.testing.expect(noun.definitions[0].parent == null and noun.definitions[0].form == null);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].examples.len);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].quotations.len);
        try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].notes.len);
        try std.testing.expectEqual(@as(usize, 0), noun.introduction.len);
        try std.testing.expectEqual(@as(usize, 0), noun.other_blocks.len);
        try std.testing.expectEqualStrings("Význam", sections[case[5]].title);
        try std.testing.expectEqual(@as(usize, 1), sections[case[5]].blocks.len);
        try std.testing.expectEqual(wiki.Kind.definition, sections[case[5]].blocks[0].kind);
        const slovak = std.mem.eql(u8, case[3], "sk");
        if (slovak) {
            try std.testing.expectEqual(@as(usize, 0), noun.related_sections.len);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, layout.other_sections);
            try std.testing.expectEqual(@as(usize, 0), before.references.len);
        } else {
            try std.testing.expectEqualSlices(usize, &.{6}, noun.related_sections);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 7, 8 }, layout.other_sections);
            try std.testing.expectEqual(@as(usize, 2), before.references.len);
            const table = before.sections[4].blocks[0].table.?;
            try std.testing.expectEqual(@as(usize, 8), table.rows.len);
            for (table.rows) |row| try std.testing.expectEqual(@as(usize, 3), row.cells.len);
        }
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = organization.value;
        const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = case[3], .heading = case[2] });
        try std.testing.expectEqualDeep(expected, decoded);
        var body_only = decoded;
        body_only.entry.organization = before.organization;
        try std.testing.expectEqualDeep(types.Stored{ .entry = before }, body_only);
        try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}

test "Croatian inline definition markers retain explicit senses and closed support boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const cases = .{
        .{ "'''izgovor:'''\n<br>'''definicija:'''<br>\n''imenica''<span>, ''ženski rod''</span>\n:(1.1) actual noun [[sense]]\n'''sinonimi:'''\n:(1.1) not a second sense", "Noun" },
        .{ "'''izgovor:'''\n<br>'''definicija:'''<br>\n''pridjev''\n* actual adjective ''sense''\n:(1.1)\n'''sinonimi:'''\n<br>'''srodne riječi:'''\n* related word\n:1. related meaning", "Adjective" },
    };
    inline for (cases) |case| {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
        const blocks = try renderer.renderBody(case[0]);
        const sections = [_]Section{.{ .level = 2, .title = "authored headword", .blocks = blocks }};
        for ([_][]const u8{ "hrvatski", "Independent owner" }) |owner| {
            const layout = try buildOwned(a, &sections, owner);
            try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
            const lexical = layout.lexemes[0];
            try std.testing.expectEqualStrings(owner, lexical.language);
            try std.testing.expectEqualStrings(case[1], lexical.kind);
            try std.testing.expectEqual(@as(usize, 0), lexical.section);
            try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
            try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
            try std.testing.expect(lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
            try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
            try std.testing.expectEqual(@as(usize, blocks.len - 2), lexical.other_blocks.len);
            for (lexical.other_blocks, 2..) |actual, expected| try std.testing.expectEqual(expected, actual);
        }
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
        try std.testing.expectEqual(@as(usize, 0), (try build(a, &sections)).lexemes.len);
        try std.testing.expect(croatianParagraphPart(blocks, "", 2) == null);
        try std.testing.expect(croatianParagraphPart(blocks, "Unclassified", 2) == null);
        try std.testing.expect(croatianParagraphPart(blocks, "hrvatski", 3) == null);
        // A second authored POS marker makes this one-section pattern ambiguous.
        const doubled = try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ case[0], case[0] });
        try std.testing.expect(croatianParagraphPart(try renderer.renderBody(doubled), "hrvatski", 2) == null);
    }
    const negatives = [_][]const u8{
        "definicija:\n''imenica''\n:(1.1) text\n'''sinonimi:'''",
        "'''definicija:''' ''imenica''\n:(1.1) text\n'''sinonimi:'''",
        "'''definicija:'''<br>imenica\n:(1.1) text\n'''sinonimi:'''",
        "'''definicija:'''<br>''[[imenica]]''\n:(1.1) text\n'''sinonimi:'''",
        "'''Definicija:'''<br>''imenica''\n:(1.1) text\n'''sinonimi:'''",
        "'''definicija:'''<br>''glagol''\n:(1.1) text\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica'' extra prose\n:(1.1) text\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica''\n:(1.1)\n'''sinonimi:'''",
        "'''definicija:'''<br>''pridjev''\n*(1.1)\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica''\n:(1.1)<ref>citation only</ref>\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica''\n: unnumbered prose\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica''\n:(1.1) text",
        "'''definicija:'''<br>''imenica''\n:(1.1) text\n\nunrelated paragraph\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica''\n:(1.1) text\n===Other===\n'''sinonimi:'''",
        "'''definicija:'''<br>''imenica''\n:(1.1) text\nsinonimi:",
        "<nowiki>'''definicija:'''<br>''imenica''\n:(1.1) text\n'''sinonimi:'''</nowiki>",
        "<pre>'''definicija:'''<br>''imenica''\n:(1.1) text\n'''sinonimi:'''</pre>",
        "<code>'''definicija:'''</code><br>''imenica''\n:(1.1) text\n'''sinonimi:'''",
    };
    for (negatives) |source| {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
        try std.testing.expect(croatianParagraphPart(try renderer.renderBody(source), "hrvatski", 2) == null);
    }
    const diagnostics = [_]wiki.Span{
        .{ .kind = .text, .text = "(1.1) " },
        .{ .kind = .text, .text = "generated error", .generated_diagnostic = true },
    };
    try std.testing.expectEqual(@as(?bool, false), croatianSense(.{ .kind = .indent, .list_path = ":", .spans = &diagnostics }));
}


test "Italian source verb label remains exact and supplies no unknown heading classification" {
    try std.testing.expectEqualStrings("Verb", partOfSpeech("Verbo").?);
    for ([_][]const u8{ "verbo", "VERBO", "Verbo sconosciuto", "polacco", "Italiano" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun").?);
}

test "Sinhala exact noun heading preserves independent owner and lexical section scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const numbered = [_]wiki.Block{.{ .kind = .definition, .list_path = "#" }};
    const noun = [_]wiki.Block{
        .{ .kind = .paragraph },
        .{ .kind = .definition, .list_path = "#" },
        .{ .kind = .list_item, .list_path = ":#" },
    };
    const sections = [_]Section{
        .{ .title = "සිංහල", .level = 2 },
        .{ .title = "නිරුක්තිය", .level = 3, .blocks = &numbered },
        .{ .title = "නාම පදය", .level = 3, .blocks = &noun },
        .{ .title = "අමතර අවධානයට", .level = 3, .blocks = &numbered },
    };
    const layout = try buildOwned(a, &sections, "Independent supplied owner");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("Independent supplied owner", lexeme.language);
    try std.testing.expectEqualStrings("Noun", lexeme.kind);
    try std.testing.expectEqual(@as(usize, 2), lexeme.section);
    try std.testing.expect(lexeme.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexeme.other_blocks);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
    try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].examples.len);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].quotations.len);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].notes.len);
    try std.testing.expectEqual(@as(usize, 0), lexeme.related_sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, layout.other_sections);
    for ([_][]const u8{ "නාමපදය", "නාම පදය extra", "නාම පද" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const ambiguous = [_]Section{.{ .title = "නාම පදය", .level = 2, .blocks = &numbered }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &ambiguous)).lexemes.len);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const literal = try renderer.renderBody("<nowiki>=== නාම පදය ===\n# literal</nowiki>");
    const protected = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = literal }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &protected)).lexemes.len);
}

test "first lexical marker preserves numbered convention and supplementary scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ordinary_first = [_]wiki.Block{
        .{ .kind = .paragraph },
        .{ .kind = .definition, .list_path = "#" },
        .{ .kind = .example, .list_path = "#:" },
        .{ .kind = .definition, .list_path = "##" },
        .{ .kind = .quotation, .list_path = "##*" },
        .{ .kind = .list_item, .list_path = ":#" },
    };
    const actual = try analyze(a, "Noun", 0, null, &ordinary_first, true);
    try std.testing.expectEqual(@as(usize, 2), actual.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), actual.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 3), actual.definitions[1].block);
    try std.testing.expect(actual.definitions[0].parent == null);
    try std.testing.expectEqual(@as(?usize, 0), actual.definitions[1].parent);
    try std.testing.expectEqualSlices(usize, &.{2}, actual.definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{4}, actual.definitions[1].quotations);
    try std.testing.expectEqualSlices(usize, &.{0}, actual.introduction);
    try std.testing.expectEqualSlices(usize, &.{5}, actual.other_blocks);
    var colon_first = ordinary_first;
    colon_first[0] = .{ .kind = .list_item, .list_path = ":#" };
    const leading = try analyze(a, "Noun", 0, null, &colon_first, true);
    try std.testing.expectEqual(@as(usize, 4), leading.definitions.len);
    for (leading.definitions, [_]usize{ 0, 1, 3, 5 }) |sense, block|
        try std.testing.expectEqual(block, sense.block);
    try std.testing.expect(leading.definitions[0].parent == null);
    try std.testing.expect(leading.definitions[1].parent == null);
    try std.testing.expectEqual(@as(?usize, 1), leading.definitions[2].parent);
    try std.testing.expect(leading.definitions[3].parent == null);
    try std.testing.expectEqualSlices(usize, &.{2}, leading.definitions[1].examples);
    try std.testing.expectEqualSlices(usize, &.{4}, leading.definitions[2].quotations);
    try std.testing.expectEqual(@as(usize, 0), leading.introduction.len);
    try std.testing.expectEqual(@as(usize, 0), leading.other_blocks.len);
    const inferred = try analyze(a, "Noun", 0, null, &colon_first, false);
    try std.testing.expectEqual(@as(usize, 2), inferred.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{0}, inferred.introduction);
    try std.testing.expectEqualSlices(usize, &.{5}, inferred.other_blocks);
    const indented_only = [_]wiki.Block{
        .{ .kind = .list_item, .list_path = ":#" },
        .{ .kind = .list_item, .list_path = ":#" },
    };
    const declared = try analyze(a, "Noun", 0, null, &indented_only, true);
    try std.testing.expectEqual(@as(usize, 2), declared.definitions.len);
    try std.testing.expectEqual(@as(usize, 0), declared.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 1), declared.definitions[1].block);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "Noun", 0, null, &indented_only, false)).definitions.len);
}

test "retained Sinhala maladanu gains one noun sense with complete body owner and Stored codec parity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    const source = @embedFile("si-maladanu-reader.json");
    const projected = try std.json.parseFromSlice(Page, a, source, .{ .ignore_unknown_fields = true });
    const typed = try std.json.parseFromSlice(TypedPage, a, source, .{ .ignore_unknown_fields = true });
    const before = typed.value.entries[0];
    try std.testing.expectEqualStrings("මලදනු", before.title);
    try std.testing.expectEqualStrings("සිංහල", before.language.?);
    try std.testing.expectEqualStrings("si", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    const sections = projected.value.entries[0].sections;
    try std.testing.expectEqual(@as(usize, 6), sections.len);
    try std.testing.expectEqualStrings("නාම පදය", sections[3].title);
    try std.testing.expectEqual(wiki.Kind.definition, sections[1].blocks[0].kind);
    try std.testing.expectEqual(wiki.Kind.definition, sections[1].blocks[1].kind);
    try std.testing.expectEqual(wiki.Kind.definition, sections[3].blocks[1].kind);
    try std.testing.expectEqual(wiki.Kind.list_item, sections[3].blocks[2].kind);
    try std.testing.expectEqualStrings(":#", sections[3].blocks[2].list_path);
    const layout = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("සිංහල", lexeme.language);
    try std.testing.expectEqualStrings("Noun", lexeme.kind);
    try std.testing.expectEqual(@as(usize, 3), lexeme.section);
    try std.testing.expect(lexeme.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexeme.other_blocks);
    try std.testing.expectEqual(@as(usize, 0), lexeme.related_sections.len);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
    const sense = lexeme.definitions[0];
    try std.testing.expectEqual(@as(usize, 1), sense.block);
    try std.testing.expect(sense.parent == null and sense.form == null);
    try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
    try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
    try std.testing.expectEqual(@as(usize, 0), sense.notes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4, 5 }, layout.other_sections);
    var block_count: usize = 0;
    var internal: usize = 0;
    var external: usize = 0;
    const targets = [_][]const u8{
        "Wiktionary:International Phonetic Alphabet",
        "https://en.wikipedia.org/wiki/%E0%B7%83%E0%B7%92%E0%B6%82%E0%B7%84%E0%B6%BD_phonology",
        "ඔක්සිජන්", "අම්ලකර", "Oxygen", "දලදනු#සිංහල", "ද₂ම#සිංහල",
        "https://www.ahubudu.lk/assets/pdf/EDIYA_Veluma5_Kalaba10.pdf",
    };
    var action: usize = 0;
    for (before.sections) |section| for (section.blocks) |block| {
        block_count += 1;
        for (block.spans) |span| {
            if (span.kind != .link and span.kind != .external_link) continue;
            try std.testing.expect(action < targets.len);
            try std.testing.expectEqualStrings(targets[action], span.target);
            action += 1;
            if (span.kind == .link) internal += 1 else external += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 9), block_count);
    try std.testing.expectEqual(@as(usize, 8), action);
    try std.testing.expectEqual(@as(usize, 6), internal);
    try std.testing.expectEqual(@as(usize, 2), external);
    const headword = before.sections[3].blocks[0].spans[0];
    try std.testing.expectEqualStrings("මලදනු", headword.text);
    try std.testing.expect(headword.bold);
    try std.testing.expectEqualStrings("si", headword.language);
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqual(@as(usize, 0), before.media.len);
    const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = "si", .heading = "සිංහල" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
    try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
    try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
    try std.testing.expectEqualDeep(before.references, decoded.entry.references);
    try std.testing.expectEqualDeep(before.media, decoded.entry.media);
    var restored = decoded.entry;
    restored.organization = before.organization;
    try std.testing.expectEqualDeep(before, restored);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "Dutch noun heading retains supplied owner and sense boundaries without broad label inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const body = try renderer.renderBody("'''headword'''\n# [[Meaning|meaning]]\n#: ''example''");
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Zelfstandig naamwoord", .level = 4, .blocks = body },
        .{ .title = "Related", .level = 5, .blocks = body },
        .{ .title = "Verwijzingen", .level = 4, .blocks = body },
        .{ .title = "Unknown", .level = 2 },
        .{ .title = "Lemma", .level = 3, .blocks = body },
    };
    const layout = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("French", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 1), lexical.section);
    try std.testing.expect(lexical.etymology == null);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    try std.testing.expect(lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 4, 5 }, layout.other_sections);
    for ([_][]const u8{ "zelfstandig naamwoord", "Zelfstandig naamwoord unknown", "Naamwoord", "Verwijzingen" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const unresolved_boundary = [_]Section{.{ .title = "Zelfstandig naamwoord", .level = 2, .blocks = body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &unresolved_boundary)).lexemes.len);
    const unresolved_nested = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved_nested.lexemes.len);
    try std.testing.expectEqualStrings("", unresolved_nested.lexemes[0].language);
    const literal = try renderer.renderBody("<nowiki>====Zelfstandig naamwoord====\n# literal, not a sense</nowiki>");
    const protected = [_]Section{.{ .title = "Unknown", .level = 2, .blocks = literal }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &protected, "French")).lexemes.len);
}

test "retained curlingforalder Danish body gains noun organization with complete typed codec parity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Page = struct { entries: []const struct { sections: []const Section } };
    const TypedPage = struct { entries: []const types.Entry };
    const source = @embedFile("nl-curlingforalder-reader.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualStrings("6b721dd4d93a02e49f8fcdf2ad8e70a4b83cf9d191e2161f9bfcaffeb2f29a41", &std.fmt.bytesToHex(digest, .lower));
    // The compiler-shaped projection supplies layout indices only. Keep all
    // Reader style flags and body fields in the separately parsed typed Entry.
    const projected = try std.json.parseFromSlice(Page, a, source, .{ .ignore_unknown_fields = true });
    const typed = try std.json.parseFromSlice(TypedPage, a, source, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), typed.value.entries.len);
    const before = typed.value.entries[0];
    try std.testing.expectEqualStrings("curlingforælder", before.title);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqualStrings("Deens", before.language.?);
    try std.testing.expectEqualStrings("da", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, before.organization.other_sections);
    const sections = projected.value.entries[0].sections;
    try std.testing.expectEqual(@as(usize, 5), sections.len);
    try std.testing.expectEqualStrings("Zelfstandig naamwoord", sections[3].title);
    try std.testing.expectEqual(@as(u8, 4), sections[3].level);
    const layout = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("Deens", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 3), lexical.section);
    try std.testing.expect(lexical.etymology == null);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), lexical.definitions[0].block);
    try std.testing.expectEqual(wiki.Kind.definition, sections[3].blocks[2].kind);
    try std.testing.expect(lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
    try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].examples.len);
    try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].quotations.len);
    try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].notes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, lexical.introduction);
    try std.testing.expectEqual(@as(usize, 0), lexical.other_blocks.len);
    try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4 }, layout.other_sections);
    const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = before.language_code, .heading = before.language.? });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
    try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
    try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
    try std.testing.expectEqualDeep(before.references, decoded.entry.references);
    try std.testing.expectEqualDeep(before.media, decoded.entry.media);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

const IsKyOrganizationTest = struct {
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    fn body(a: A, source: []const u8) ![]const wiki.Block {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
        return renderer.renderBody(source);
    }
    fn projected(a: A, source: []const u8, typed: @import("blob_encoder").presentation_types.Entry) ![]const Section {
        const Page = struct { entries: []const struct { sections: []const Section } };
        const parsed = try std.json.parseFromSlice(Page, a, source, .{ .ignore_unknown_fields = true });
        const sections = try a.dupe(Section, parsed.value.entries[0].sections);
        // Reader booleans live directly on stored spans; compiler flags are
        // nested. This test-only structural projection must not erase styles.
        for (sections, typed.sections) |*section, stored_section| {
            const copied = try a.dupe(wiki.Block, section.blocks);
            for (copied, stored_section.blocks) |*block, stored_block| {
                const spans = try a.dupe(wiki.Span, block.spans);
                for (spans, stored_block.spans) |*span, stored_span| span.flags = .{
                    .bold = stored_span.bold, .italic = stored_span.italic,
                    .code = stored_span.code, .small = stored_span.small,
                    .superscript = stored_span.superscript, .subscript = stored_span.subscript,
                    .strike = stored_span.strike, .underline = stored_span.underline,
                };
                block.spans = spans;
            }
            section.blocks = copied;
        }
        return sections;
    }
};

test "Icelandic noun paragraph keeps numbered meaning scope and requires independent owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "Nafnorð '''word''' (hvorugkyn); sterk beyging\n:[1] ''[[first]]''\n:[2] second\nSupport\n:[3] not a sense\n";
    const content = try IsKyOrganizationTest.body(a, source);
    const sections = [_]IsKyOrganizationTest.Section{.{ .title = "Independent", .level = 2, .blocks = content }};
    const layout = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("French", noun.language);
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions[1].block);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, noun.other_blocks);
    try std.testing.expectEqual(wiki.Kind.indent, content[1].kind);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    for ([_][]const u8{
        "<nowiki>Nafnorð</nowiki> '''word'''\n:[1] not proved\n",
        "[[control|Nafnorð]] '''word'''\n:[1] not proved\n",
        "Prose Nafnorð '''word'''\n:[1] not proved\n",
        "Nafnorð word\n:[1] not proved\n",
        // A blank line makes Support a separate paragraph, not headword tail.
        "Nafnorð '''word'''\n\nSupport\n:[1] not proved\n",
        "Nafnorð '''word'''\n:[[control|[1]]] not proved\n",
        "Nafnorð '''word'''\n:[abc] not proved\n",
        "Nafnorð '''word'''\n:[1] one\nNafnorð '''other'''\n:[1] two\n",
    }) |negative| {
        errdefer std.debug.print("IS noun negative source: {s}\n", .{negative});
        const negative_body = try IsKyOrganizationTest.body(a, negative);
        if (std.mem.indexOf(u8, negative, "\n\nSupport\n") != null) {
            try std.testing.expectEqual(@as(usize, 3), negative_body.len);
            try std.testing.expectEqual(wiki.Kind.paragraph, negative_body[0].kind);
            try std.testing.expectEqual(wiki.Kind.paragraph, negative_body[1].kind);
            try std.testing.expectEqualStrings("Support", negative_body[1].spans[0].text);
            try std.testing.expectEqual(wiki.Kind.indent, negative_body[2].kind);
        }
        const negative_sections = [_]IsKyOrganizationTest.Section{.{ .title = "Independent", .level = 2, .blocks = negative_body }};
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative_sections, "French")).lexemes.len);
    }
}

test "Kyrgyz immediate meaning children distinguish examples from nested senses and support" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const meanings = try IsKyOrganizationTest.body(a,
        "# first [[sense]]\n## <span style=\"color: #555;\"> ◆ ''actual '''example'''.''</span>\n" ++
        "## real nested sense\n# second\n");
    const support = try IsKyOrganizationTest.body(a, "# synonym [[word]]\n");
    const sections = [_]IsKyOrganizationTest.Section{
        .{ .title = "French", .level = 2 },
        .{ .title = "Зат атооч", .level = 3 },
        .{ .title = "Мааниси", .level = 4, .blocks = meanings },
        .{ .title = "Синонимдери", .level = 4, .blocks = support },
        .{ .title = "German", .level = 2 },
        .{ .title = "Мааниси", .level = 4, .blocks = support },
    };
    const layout = try buildOwned(a, &sections, "Independent");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Independent", noun.language);
    try std.testing.expectEqual(@as(usize, 2), noun.section);
    try std.testing.expectEqual(@as(usize, 3), noun.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{1}, noun.definitions[0].examples);
    try std.testing.expectEqual(@as(?usize, 0), noun.definitions[1].parent);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions[1].block);
    try std.testing.expectEqual(@as(usize, 3), noun.definitions[2].block);
    try std.testing.expectEqualSlices(usize, &.{3}, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 5 }, layout.other_sections);
    try std.testing.expectEqual(wiki.Kind.definition, meanings[1].kind);
    try std.testing.expectEqualStrings("##", meanings[1].list_path);
    for ([_][]const u8{
        "## <nowiki>◆</nowiki> ''not proved''\n",
        "## [[control|◆]] ''not proved''\n",
        "## ◆ ''not gray''\n",
        "## <span style=\"color: #555;\"> ◆ not italic</span>\n",
        "## <span style=\"color: #555;\"> ◆ ''one'' ◆ </span>\n",
    }) |negative| {
        const negative_body = try IsKyOrganizationTest.body(a, negative);
        try std.testing.expectEqual(@as(usize, 1), negative_body.len);
        try std.testing.expect(!kyrgyzExample(negative_body[0]));
    }
    var wrong = sections;
    wrong[1].title = "Unknown POS";
    try std.testing.expect(kyrgyzMeaningParent(&wrong, 2) == null);
    wrong = sections;
    wrong[2].level = 5;
    try std.testing.expect(kyrgyzMeaningParent(&wrong, 2) == null);
    wrong = sections;
    wrong[2].title = "Синонимдери";
    try std.testing.expect(kyrgyzMeaningParent(&wrong, 2) == null);
    const interrupted = [_]IsKyOrganizationTest.Section{
        sections[1], .{ .title = "Support", .level = 3 }, sections[2],
    };
    try std.testing.expect(kyrgyzMeaningParent(&interrupted, 2) == null);
}

test "retained Icelandic and Kyrgyz bodies preserve all fields through conditional organization codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Page = struct { entries: []const types.Entry };
    const cases = .{
        .{ @embedFile("is-aktin-reader78.json"), "aktín", "íslenska", "is" },
        .{ @embedFile("ky-bir-reader78.json"), "бир", "кыргызча", "ky" },
    };
    inline for (cases, 0..) |case, which| {
        const parsed = try std.json.parseFromSlice(Page, a, case[0], .{ .ignore_unknown_fields = true });
        const before = parsed.value.entries[0];
        try std.testing.expectEqualStrings(case[1], before.title);
        try std.testing.expectEqualStrings("Unclassified", before.language.?);
        try std.testing.expectEqualStrings("", before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        const sections = try IsKyOrganizationTest.projected(a, case[0], before);
        // This is conditional organization under independently supplied owners,
        // not proof that a new normal producer has resolved the historical blob.
        const layout = try buildOwned(a, sections, case[2]);
        if (which == 0) {
            try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
            const noun = layout.lexemes[0];
            try std.testing.expectEqualStrings("Noun", noun.kind);
            try std.testing.expectEqual(@as(usize, 0), noun.section);
            try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
            try std.testing.expectEqual(@as(usize, 3), noun.definitions[0].block);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, noun.introduction);
            try std.testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7, 8, 9, 10 }, noun.other_blocks);
            try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
        } else {
            try std.testing.expectEqual(@as(usize, 3), layout.lexemes.len);
            const kinds = [_][]const u8{ "Numeral", "Noun", "Adverb" };
            const addresses = [_]usize{ 3, 6, 9 };
            const sizes = [_]usize{ 1, 5, 5 };
            const expected_blocks = [_][]const usize{ &.{0}, &.{ 0, 2, 5, 8, 10 }, &.{ 0, 2, 4, 6, 9 } };
            const expected_examples = [_][]const usize{ &.{1}, &.{ 1, 2, 2, 1, 0 }, &.{ 1, 1, 1, 2, 1 } };
            for (layout.lexemes, 0..) |lexeme, n| {
                try std.testing.expectEqualStrings(kinds[n], lexeme.kind);
                try std.testing.expectEqual(addresses[n], lexeme.section);
                try std.testing.expectEqual(sizes[n], lexeme.definitions.len);
                for (lexeme.definitions, 0..) |sense, m| {
                    try std.testing.expectEqual(expected_blocks[n][m], sense.block);
                    try std.testing.expectEqual(expected_examples[n][m], sense.examples.len);
                    try std.testing.expect(sense.parent == null and sense.form == null);
                }
            }
            try std.testing.expectEqualSlices(usize, &.{4}, layout.lexemes[0].related_sections);
            try std.testing.expectEqualSlices(usize, &.{7}, layout.lexemes[1].related_sections);
            try std.testing.expectEqualSlices(usize, &.{ 10, 11 }, layout.lexemes[2].related_sections);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 5, 8 }, layout.other_sections);
            const unresolved = try buildUnclassified(a, sections);
            try std.testing.expectEqual(@as(usize, 3), unresolved.lexemes.len);
            for (unresolved.lexemes) |lexeme| try std.testing.expectEqualStrings("", lexeme.language);
        }
        for (layout.lexemes) |lexeme| {
            try std.testing.expectEqualStrings(case[2], lexeme.language);
            try std.testing.expect(lexeme.etymology == null);
        }
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.language = case[2];
        expected.entry.language_code = case[3];
        expected.entry.organization = organization.value;
        const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = case[3], .heading = case[2] });
        try std.testing.expectEqualDeep(expected, decoded);
        var original_body = decoded;
        original_body.entry.language = before.language;
        original_body.entry.language_code = before.language_code;
        original_body.entry.organization = before.organization;
        try std.testing.expectEqualDeep(types.Stored{ .entry = before }, original_body);
        try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}

test "normal document Icelandic organization preserves independent owner body actions media references and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const source = "== French ==\n{|\n| '''table''' || [[cell]]\n|}\nNafnorð '''word''' (hvorugkyn); sterk beyging\n" ++
        ":[1] ''[[meaning]]''<ref>'''note''' [[reference]]</ref>\nSupport [[support]]\n:[2] not a sense\n" ++
        "[[File:Example.jpg|thumb|caption]]\n<references/>\n";
    const document = @import("presentation_document.zig");
    var figure_namespaces = try @import("namespace_registry").Registry.init(a, ControlledFigureFixture.namespace_bytes); defer figure_namespaces.deinit();
    // Controlled source defaults and exact handler tuple; no actual-site or bitmap-original claim.
    const figure_input: ControlledFigureFixture = .{ .file = "Example.jpg", .width = 275 };
    var figure_styles = try @import("table_style_profile.zig").parseAlloc(a, ""); defer figure_styles.deinit();
    const figure_source = figure_input.source(&figure_namespaces);
    // Entry metadata is not classified-owner authority. Supply the independent
    // owner through the same explicit API used for resolved Writer groups.
    const payload = try document.compileClassifiedWithHeadingAnchorsAndSourceMediaRootAlloc(
        a, "control", .language, "French", "fr", document.MissingText.untracked(source),
        null, .{}, &figure_namespaces, null, null, .{}, null, null, &.{}, null, &.{},
        .{ .heading = "French", .code = "fr" }, &figure_styles, figure_source, .parser_output,
    );
    const decoded = try encoder.presentation_codec.decodeAlloc(a, payload, "control", .language, .{ .code = "fr", .heading = "French" });
    errdefer std.debug.print("IS document counts: lexemes={d} media={d} references={d}\n", .{ decoded.entry.organization.lexemes.len, decoded.entry.media.len, decoded.entry.references.len });
    try std.testing.expectEqualStrings("French", decoded.entry.language.?);
    try std.testing.expectEqualStrings("fr", decoded.entry.language_code);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.organization.lexemes[0].definitions.len);
    try std.testing.expectEqualStrings("French", decoded.entry.organization.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
    try std.testing.expectEqual(@as(usize, 1), ControlledFigureFixture.count(decoded.entry));
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    const unresolved_payload = try document.compileClassifiedWithHeadingAnchorsAndSourceMediaRootAlloc(a, "control", .language, "Unclassified", "", document.MissingText.untracked(source), null, .{}, &figure_namespaces, null, null, .{}, null, null, &.{}, null, &.{}, null, &figure_styles, figure_source, .parser_output);
    const unresolved = try encoder.presentation_codec.decodeAlloc(a, unresolved_payload, "control", .language, .{ .code = "", .heading = "Unclassified" });
    try std.testing.expectEqual(@as(usize, 0), unresolved.entry.organization.lexemes.len);
    var body = decoded;
    body.entry.language = unresolved.entry.language;
    body.entry.language_code = unresolved.entry.language_code;
    body.entry.organization = unresolved.entry.organization;
    try std.testing.expectEqualDeep(unresolved, body);
    try std.testing.expectEqualSlices(u8, payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "owned authored Malagasy lexical kind retains scope without guessing an English POS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const lexical = try renderer.renderBody("'''term'''\n# Definition [[target|label]].\n#: ''Example [[example]].''\n");
    const support = try renderer.renderBody("# Support [[support]].\n");
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Fomba fiteny", .level = 3, .blocks = lexical },
        .{ .title = "Fanononana", .level = 4, .blocks = support },
        .{ .title = "Generic support", .level = 3, .blocks = lexical },
    };
    const layout = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("Fomba fiteny", lexeme.kind);
    try std.testing.expectEqualStrings("French", lexeme.language);
    try std.testing.expectEqual(@as(usize, 1), lexeme.section);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, lexeme.definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexeme.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    try std.testing.expect(partOfSpeech("Fomba fiteny") == null);
    try std.testing.expectEqual(@as(usize, 0), (try build(a, &sections)).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    for ([_][]const u8{ "", "Unclassified" }) |owner| {
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, owner)).lexemes.len);
    }
    for ([_][]const u8{ "Generic support", "Fomba fiteny fanampiny", "fomba fiteny" }) |heading| {
        var negative = sections;
        negative[1].title = heading;
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "French")).lexemes.len);
    }
    for ([_]u8{ 2, 4 }) |level| {
        var negative = sections;
        negative[1].level = level;
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "French")).lexemes.len);
    }
    for ([_][]const u8{
        "# Definition without headword\n",
        "term\n# Definition\n",
        "'''term'''\n* Support\n",
        "'''term'''\n## Nested without direct sense\n",
        "'''term'''\n\nSupport\n# Definition\n",
        "'''term'''\n==== Intervening support ====\n# Definition\n",
        "<nowiki>'''term'''</nowiki>\n# Definition\n",
        "'''term'''\n# <nowiki>protected definition</nowiki>\n",
    }) |source| {
        errdefer std.debug.print("MG lexical negative: {s}\n", .{source});
        var negative = sections;
        negative[1].blocks = try renderer.renderBody(source);
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "French")).lexemes.len);
    }
}

test "retained MG liska normal Reader body gains only source declared organization through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const bytes = @embedFile("mg-liska-reader80.json");
    const page = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), page.value.entries.len);
    const before = page.value.entries[0];
    try std.testing.expectEqualStrings("liška podšitá", before.title);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqualStrings("Czech", before.language.?);
    try std.testing.expectEqualStrings("cs", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 4), before.sections.len);
    for (before.sections, [_][]const u8{ "Tseka", "Fomba fiteny", "Fanononana", "Tsiahy" }) |section, title| {
        try std.testing.expectEqualStrings(title, section.title);
    }
    try std.testing.expectEqual(@as(usize, 2), before.references.len);
    try std.testing.expectEqual(@as(usize, 3), before.media.len);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, bytes, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // This projection supplies compiler block addresses only. The independently
    // parsed Stored entry remains the complete body/style/action/codec oracle.
    for (sections, before.sections) |*section, original_section| {
        const blocks = try a.dupe(wiki.Block, section.blocks);
        for (blocks, original_section.blocks) |*block, original_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            for (spans, original_block.spans) |*span, original_span| span.flags = .{
                .bold = original_span.bold, .italic = original_span.italic,
                .code = original_span.code, .small = original_span.small,
                .superscript = original_span.superscript, .subscript = original_span.subscript,
                .strike = original_span.strike, .underline = original_span.underline,
            };
            block.spans = spans;
        }
        section.blocks = blocks;
    }
    const layout = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("Fomba fiteny", lexeme.kind);
    try std.testing.expectEqualStrings("Czech", lexeme.language);
    try std.testing.expectEqual(@as(usize, 1), lexeme.section);
    try std.testing.expect(lexeme.etymology == null);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), lexeme.definitions[0].block);
    try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].examples.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, lexeme.introduction);
    try std.testing.expectEqual(@as(usize, 0), lexeme.other_blocks.len);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, lexeme.related_sections);
    try std.testing.expectEqualSlices(usize, &.{0}, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
    const organization_bytes = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, organization_bytes, .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .heading = "Czech", .code = "cs" });
    try std.testing.expectEqualDeep(expected, decoded);
    var original = decoded;
    original.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, original);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "ET authored form and morpheme sections require owned parsed lexical bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const body = try renderer.renderBody("'''term'''\n# Definition [[target|label]].\n#:: ''Example [[example]].''\n");
    const support = try renderer.renderBody("* [[support]]\n");
    for ([_][]const u8{ "Tegusõnavorm", "Tegusõnavorm (1)", "Tegusõnavorm (24)", "Morfeem" }) |heading| {
        const sections = [_]Section{
            .{ .title = "French", .level = 2 },
            .{ .title = heading, .level = 3, .blocks = body },
            .{ .title = "Sõnad", .level = 4, .blocks = support },
            .{ .title = "Unrelated support", .level = 3, .blocks = body },
        };
        const layout = try buildOwned(a, &sections, "French");
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const lexeme = layout.lexemes[0];
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, heading, "Morfeem")) "Morfeem" else "Tegusõnavorm", lexeme.kind);
        try std.testing.expectEqualStrings("French", lexeme.language);
        try std.testing.expectEqual(@as(usize, 1), lexeme.section);
        try std.testing.expect(lexeme.etymology == null);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
        try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
        try std.testing.expectEqualSlices(usize, &.{2}, lexeme.definitions[0].examples);
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqualSlices(usize, &.{2}, lexeme.related_sections);
        try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
        try std.testing.expect(partOfSpeech(heading) == null);
        try std.testing.expectEqual(@as(usize, 0), (try build(a, &sections)).lexemes.len);
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
        for ([_][]const u8{ "", "Unclassified" }) |owner|
            try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, owner)).lexemes.len);
        for ([_]u8{ 2, 4 }) |level| {
            var negative = sections;
            negative[1].level = level;
            try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "French")).lexemes.len);
        }
        for ([_][]const u8{
            "# Definition without headword\n",
            "term\n# Definition\n",
            "'''term'''\n* Support\n",
            "'''term'''\n## Nested without direct sense\n",
            "'''term'''\nSupport\n# Definition\n",
            "'''term'''\n==== Intervening heading ====\n# Definition\n",
            "<nowiki>'''term'''</nowiki>\n# Definition\n",
            "'''term'''\n# <nowiki>protected definition</nowiki>\n",
            "'''term'''\n# <code>code definition</code>\n",
        }) |source| {
            var negative = sections;
            negative[1].blocks = try renderer.renderBody(source);
            errdefer std.debug.print("ET authored-kind negative heading={s} source={s}\n", .{ heading, source });
            try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "French")).lexemes.len);
        }
    }
    for ([_][]const u8{
        "tegusõnavorm", "Tegusõnavormid", "Tegusõnavorm ()", "Tegusõnavorm (0)",
        "Tegusõnavorm (01)", "Tegusõnavorm (1a)", "Tegusõnavorm (1) extra", "Tegusõnavorm 1",
        "Tegusõnavorm (١)", "morfeem", "Morfeemid", "Morfeem (1)", "Sõnad",
    }) |heading| {
        const sections = [_]Section{.{ .title = heading, .level = 3, .blocks = body }};
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, "French")).lexemes.len);
    }
}

test "ET retained contraction document gains five lexemes preserving complete Reader body and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const types = encoder.presentation_types;
    const raw = @embedFile("testdata/et-contraction/source.raw.wikitext");
    const source = @embedFile("testdata/et-contraction/source.static-template-derived.wikitext");
    const reader = @embedFile("testdata/et-contraction/reader83.json");
    const Verify = struct {
        fn hash(bytes: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    try Verify.hash(raw, "d2b8076f92369f678708d1687a899cb0fd7c99cc5b281e6c9b8f109b78685a73");
    try Verify.hash(source, "461148811ee181cb22fd82b9fbe64a06f076e7afc29657df856affc93090a838");
    try Verify.hash(reader, "2c2c607ee58d2c4e323cd31da3d2f1413c531b2978a3e591ea6b6e0912086f3e");
    const namespace_source = @embedFile("testdata/et-contraction/namespace-registry.tsv");
    try Verify.hash(namespace_source, "f1f1c1bf54d442da19ac9031eedd8f43d6b0225c85636cd793ea2e3a10cd9045");
    var namespaces = try @import("namespace_registry").Registry.init(a, namespace_source);
    defer namespaces.deinit();
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, reader, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("-'d", before.title);
    try std.testing.expectEqualStrings("inglise", before.language.?);
    try std.testing.expectEqualStrings("en", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    // The fixture substitutes only the authenticated constant Mall:-en- leaf,
    // applying its noinclude/includeonly and lowercase ASCII PAGENAME. It is a
    // static source-derived fixture, not a claimed captured expander output.
    // The JSON is only the complete Stored oracle: no compiler spans or parsed
    // provenance are projected from it. Normal document APIs parse every byte.
    const payload = try document.compileClassifiedWithHeadingAnchorsAlloc(
        a, before.title, .language, "inglise", "en", document.MissingText.untracked(source),
        null, .{}, &namespaces, null, null, .{}, null, null, &.{}, null, &.{},
        .{ .heading = "inglise", .code = "en" },
    );
    const decoded = try encoder.presentation_codec.decodeAlloc(a, payload, before.title, .language, .{ .heading = "inglise", .code = "en" });
    const layout = decoded.entry.organization;
    try std.testing.expectEqual(@as(usize, 5), layout.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, layout.other_sections);
    const sections = [_]usize{ 2, 4, 6, 8, 10 };
    const sense_counts = [_]usize{ 1, 1, 2, 1, 2 };
    for (layout.lexemes, sections, sense_counts, 0..) |lexeme, section, count, i| {
        try std.testing.expectEqualStrings(if (i == 4) "Morfeem" else "Tegusõnavorm", lexeme.kind);
        try std.testing.expectEqualStrings("inglise", lexeme.language);
        try std.testing.expectEqual(section, lexeme.section);
        try std.testing.expectEqual(count, lexeme.definitions.len);
        try std.testing.expect(lexeme.etymology == null);
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqual(@as(usize, 0), lexeme.other_blocks.len);
        if (i < 4) try std.testing.expectEqualSlices(usize, &.{section + 1}, lexeme.related_sections)
        else try std.testing.expectEqual(@as(usize, 0), lexeme.related_sections.len);
        for (lexeme.definitions) |sense| {
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expectEqual(@as(usize, 0), sense.notes.len);
        }
    }
    for (layout.lexemes) |lexeme| try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 4), layout.lexemes[2].definitions[1].block);
    try std.testing.expectEqual(@as(usize, 5), layout.lexemes[4].definitions[1].block);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, layout.lexemes[0].definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{2}, layout.lexemes[1].definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, layout.lexemes[2].definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{}, layout.lexemes[2].definitions[1].examples);
    try std.testing.expectEqualSlices(usize, &.{}, layout.lexemes[3].definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, layout.lexemes[4].definitions[0].examples);
    try std.testing.expectEqualSlices(usize, &.{6}, layout.lexemes[4].definitions[1].examples);
    try std.testing.expectEqualSlices(usize, &.{4}, layout.lexemes[4].definitions[0].quotations);
    for (layout.lexemes[0..4]) |lexeme| for (lexeme.definitions) |sense|
        try std.testing.expectEqual(@as(usize, 0), sense.quotations.len);
    try std.testing.expectEqual(@as(usize, 0), layout.lexemes[4].definitions[1].quotations.len);
    // Restore organization only; every original field must match the published
    // Reader entry, including source's unclosed italic and all 27 link actions.
    var restored = decoded;
    restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
    try std.testing.expectEqualSlices(u8, payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "Ukrainian morphology noun declaration binds only its authored meaning section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "tomato" } };
    const morphology = try renderer.renderBody("[[іменник|Іменник]].\n\nКорінь: '''--'''.");
    const pronunciation = try renderer.renderBody("* [[IPA]]");
    const meaning = try renderer.renderBody("# [[помідор]].\n; Синоніми");
    for ([_]u8{ 3, 4 }) |semantic_level| {
        const sections = [_]Section{
            .{ .title = "owner", .level = 1 },
            .{ .title = "Морфосинтаксичні ознаки", .level = 3, .blocks = morphology },
            .{ .title = "Вимова", .level = 3, .blocks = pronunciation },
            .{ .title = "Семантичні властивості", .level = semantic_level },
            .{ .title = "Значення", .level = semantic_level + 1, .blocks = meaning },
            .{ .title = "Джерела", .level = 3 },
        };
        const result = try buildOwned(a, &sections, "Independently resolved owner");
        try std.testing.expectEqual(@as(usize, 1), result.lexemes.len);
        const lexical = result.lexemes[0];
        try std.testing.expectEqualStrings("Noun", lexical.kind);
        try std.testing.expectEqualStrings("Independently resolved owner", lexical.language);
        try std.testing.expectEqual(@as(usize, 4), lexical.section);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{1}, lexical.other_blocks);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 5 }, result.other_sections);
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
        try std.testing.expectEqual(@as(usize, 0), (try build(a, &sections)).lexemes.len);
        // A prior declared POS continues to own its nested source sections.
        var inherited = sections;
        inherited[0] = .{ .title = "Verb", .level = 2 };
        const declared = try buildOwned(a, &inherited, "Independently resolved owner");
        try std.testing.expectEqual(@as(usize, 1), declared.lexemes.len);
        try std.testing.expectEqualStrings("Verb", declared.lexemes[0].kind);
        try std.testing.expectEqual(@as(usize, 0), declared.lexemes[0].section);
        try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4, 5 }, declared.lexemes[0].related_sections);
    }
}

test "Ukrainian morphology declaration refuses protected conflicting and detached markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const morphology = try renderer.renderBody("[[іменник|Іменник]].");
    const meaning = try renderer.renderBody("# [[помідор]].");
    const sections = [_]Section{
        .{ .title = "Морфосинтаксичні ознаки", .level = 3, .blocks = morphology },
        .{ .title = "Вимова", .level = 3 },
        .{ .title = "Семантичні властивості", .level = 3 },
        .{ .title = "Значення", .level = 4, .blocks = meaning },
    };
    for ([_][]const u8{
        "<nowiki>[[іменник|Іменник]].</nowiki>", "<code>[[іменник|Іменник]].</code>",
        "''[[іменник|Іменник]]''.", "[[wrong|Іменник]].", "[[іменник|Other]].",
        "[https://example.test/ Іменник].", "Іменник.", "[[іменник|Іменник]]. extra",
        "[[іменник|Іменник]].\n\n[[іменник|Іменник]].",
        "[[іменник|Іменник]].\n\n[[unknown|Unknown]].",
        "{|\n| [[іменник|Іменник]].\n|}",
        "* [[іменник|Іменник]].",
    }) |source| {
        var negative = sections;
        negative[0].blocks = try renderer.renderBody(source);
        errdefer std.debug.print("UK noun-marker refusal source={s}\n", .{source});
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "English")).lexemes.len);
    }
    for ([_]wiki.Provenance{ .protected_literal, .entity_literal }) |provenance| {
        const spans = try a.dupe(wiki.Span, morphology[0].spans);
        spans[0].provenance = provenance;
        const blocks = [_]wiki.Block{.{ .kind = .paragraph, .spans = spans }};
        var negative = sections;
        negative[0].blocks = &blocks;
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "English")).lexemes.len);
    }
    const diagnostic_spans = try a.dupe(wiki.Span, morphology[0].spans);
    diagnostic_spans[0].generated_diagnostic = true;
    const diagnostic_blocks = [_]wiki.Block{.{ .kind = .paragraph, .spans = diagnostic_spans }};
    var diagnostic = sections;
    diagnostic[0].blocks = &diagnostic_blocks;
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &diagnostic, "English")).lexemes.len);
    for (0..sections.len) |index| {
        var renamed = sections;
        renamed[index].title = "Unknown";
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &renamed, "English")).lexemes.len);
        var level = sections;
        level[index].level = 2;
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &level, "English")).lexemes.len);
    }
    var conflict = sections;
    conflict[1].blocks = try renderer.renderBody("[[unknown|Unknown]].");
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &conflict, "English")).lexemes.len);
    var mixed = sections;
    mixed[2].blocks = try renderer.renderBody("Other body");
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &mixed, "English")).lexemes.len);
    var empty = sections;
    empty[3].blocks = &.{};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &empty, "English")).lexemes.len);
    for ([_][]const u8{ "", "Unclassified" }) |owner|
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, owner)).lexemes.len);
}

test "retained UK tomato Reader graphs gain noun organization without changing body or codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Verify = struct {
        fn hash(bytes: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    try Verify.hash(@embedFile("testdata/uk-tomato/imen-en.xmlencoded.wikitext"), "afb87919c38f63b1b3579f5427aa8734cfc6893a7ec64310360197e48718c6c4");
    try Verify.hash(@embedFile("testdata/uk-tomato/imen-en-s.xmlencoded.wikitext"), "74bfaeb566087f6dbdc5f232fe3d4385349c378340d14ae8d12d434e3456a2ea");
    try Verify.hash(@embedFile("testdata/uk-tomato/imen-eo.xmlencoded.wikitext"), "7a21f8f7da976ce0ddc8ecb8f02b3888f09ece11cc764f11d41f57005088f99b");
    inline for (.{
        .{ @embedFile("testdata/uk-tomato/english-reader.json"), "a9bbb7c0422ddfbd4a271fad5cc6a86a16501605a160b6e20f92e6b4129deb52", "English", "en", @as(usize, 9) },
        .{ @embedFile("testdata/uk-tomato/esperanto-reader.json"), "3516af05e4adfa7a8fff7869961af624ab7aca8126fbf3c2f8ab14d2ce030d81", "Esperanto", "eo", @as(usize, 13) },
    }) |case| {
        try Verify.hash(case[0], case[1]);
        const typed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, case[0], .{ .ignore_unknown_fields = true });
        const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, case[0], .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), typed.value.entries.len);
        const before = typed.value.entries[0];
        try std.testing.expectEqualStrings("tomato", before.title);
        try std.testing.expectEqualStrings(case[2], before.language.?);
        try std.testing.expectEqualStrings(case[3], before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        try std.testing.expectEqual(case[4], before.sections.len);
        try std.testing.expectEqual(@as(usize, 4), before.references.len);
        const sections = try a.dupe(Section, projected.value.entries[0].sections);
        // Reader fields supply layout addresses only; never reserialize the
        // compiler projection as the source body. Live controls test provenance.
        for (sections, before.sections) |*section, original_section| {
            const blocks = try a.dupe(wiki.Block, section.blocks);
            for (blocks, original_section.blocks) |*block, original_block| {
                const spans = try a.dupe(wiki.Span, block.spans);
                for (spans, original_block.spans) |*span, original_span| span.flags = .{
                    .bold = original_span.bold, .italic = original_span.italic,
                    .code = original_span.code, .small = original_span.small,
                    .superscript = original_span.superscript, .subscript = original_span.subscript,
                    .strike = original_span.strike, .underline = original_span.underline,
                };
                block.spans = spans;
            }
            section.blocks = blocks;
        }
        const layout = try buildOwned(a, sections, case[2]);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const lexical = layout.lexemes[0];
        try std.testing.expectEqualStrings("Noun", lexical.kind);
        try std.testing.expectEqualStrings(case[2], lexical.language);
        try std.testing.expectEqual(@as(usize, 4), lexical.section);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].block);
        try std.testing.expect(lexical.etymology == null and lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
        try std.testing.expectEqual(@as(usize, 0), lexical.introduction.len);
        try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
        try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, lexical.other_blocks);
        try std.testing.expectEqual(case[4] - 1, layout.other_sections.len);
        for (layout.other_sections, 0..) |section, i| try std.testing.expectEqual(if (i < 4) i else i + 1, section);
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = organization.value;
        const payload = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, payload, before.title, before.kind, .{ .heading = case[2], .code = case[3] });
        try std.testing.expectEqualDeep(expected, decoded);
        var restored = decoded;
        restored.entry.organization = before.organization;
        // This includes every table cell and the unresolved Esperanto table
        // spill: an organization fix is not a table-fidelity waiver.
        try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
        try std.testing.expectEqualSlices(u8, payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}

test "BG authored grammar heading retains empty meaning as body and requires parsed type evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const heading = "=== Глагол, ''[[Уикиречник:Български/Типове думи/186|тип 186]], {{{ВИД}}}'' ===\n";
    const title = "Глагол, тип 186, {{{ВИД}}}";
    const placeholder = "# ''Значението на думата все още не е въведено. Можете да го добавите, както и да попълните част от останалата липсваща информация, като щракнете на '''редактиране'''.''\n";
    const body = try renderer.renderBody(heading ++ "(класификация — <i>?</i>)\n\n" ++ placeholder);
    const sections = [_]Section{
        .{ .title = "French", .level = 2 },
        .{ .title = title, .level = 3, .blocks = body },
        .{ .title = "Синоними", .level = 4, .blocks = try renderer.renderBody("# [[support]]\n") },
        .{ .title = "Other", .level = 3, .blocks = try renderer.renderBody("# [[unrelated]]\n") },
    };
    const layout = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("Глагол", lexical.kind);
    try std.testing.expectEqualStrings("French", lexical.language);
    try std.testing.expectEqual(@as(usize, 1), lexical.section);
    try std.testing.expect(lexical.etymology == null);
    try std.testing.expectEqual(@as(usize, 0), lexical.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    // Analysis never rewrites the authored numbered placeholder or its styling.
    try std.testing.expect(body[2].kind == .definition);
    try std.testing.expectEqualStrings("#", body[2].list_path);
    try std.testing.expect(body[2].spans[1].flags.italic and body[2].spans[1].flags.bold);
    try std.testing.expectEqualStrings("{{{ВИД}}}", body[0].spans[body[0].spans.len - 1].text);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try build(a, &sections)).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, "")).lexemes.len);
    const genuine = [_]Section{.{ .title = title, .level = 3, .blocks = try renderer.renderBody(heading ++ "(класификация — <i>?</i>)\n\n# A genuine [[sense]].\n") }};
    const genuine_layout = try buildOwned(a, &genuine, "French");
    try std.testing.expectEqual(@as(usize, 1), genuine_layout.lexemes.len);
    try std.testing.expectEqual(@as(usize, 1), genuine_layout.lexemes[0].definitions.len);
    try std.testing.expectEqual(@as(usize, 2), genuine_layout.lexemes[0].definitions[0].block);
    for ([_][]const u8{
        "=== <nowiki>Глагол, </nowiki>''[[Уикиречник:Български/Типове думи/186|тип 186]], {{{ВИД}}}'' ===\n",
        "=== Глагол, ''[[Unrelated/186|тип 186]], {{{ВИД}}}'' ===\n",
        "=== Глагол, ''[[Уикиречник:Български/Типове думи/185|тип 186]], {{{ВИД}}}'' ===\n",
        "=== Глагол, ''тип 186, {{{ВИД}}}'' ===\n",
    }) |negative| {
        const source = try std.mem.concat(a, u8, &.{ negative, placeholder });
        const one = [_]Section{.{ .title = title, .level = 3, .blocks = try renderer.renderBody(source) }};
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &one, "French")).lexemes.len);
    }
    // A same-line colon is literal heading text, not a physical list item.
    const literal_colon_body = try renderer.renderBody("<h3>:Глагол, ''[[Уикиречник:Български/Типове думи/186|тип 186]], {{{ВИД}}}''</h3>\n" ++ placeholder);
    try std.testing.expect(literal_colon_body[0].kind == .heading);
    try std.testing.expectEqualStrings("", literal_colon_body[0].list_path);
    try std.testing.expectEqual(@as(u8, 0), literal_colon_body[0].depth);
    const literal_colon = [_]Section{.{ .title = title, .level = 3, .blocks = literal_colon_body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &literal_colon, "French")).lexemes.len);
    const nested_body = try renderer.renderBody("<h3>\n:Глагол, ''[[Уикиречник:Български/Типове думи/186|тип 186]], {{{ВИД}}}''</h3>\n" ++ placeholder);
    try std.testing.expect(nested_body[0].kind == .heading);
    try std.testing.expectEqualStrings(":", nested_body[0].list_path);
    try std.testing.expect(nested_body[0].depth != 0);
    const nested = [_]Section{.{ .title = title, .level = 3, .blocks = nested_body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &nested, "French")).lexemes.len);
    var wrong_level = sections;
    wrong_level[1].level = 4;
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &wrong_level, "French")).lexemes.len);
    var wrong_title = sections;
    wrong_title[1].title = "Глагол, тип 185, {{{ВИД}}}";
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &wrong_title, "French")).lexemes.len);
}

test "Czech authored noun meanings require owned ordinary heading scope and direct parsed senses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const F = struct {
        fn compile(allocator: A, source: []const u8, owned: bool) !encoder.presentation_types.Stored {
            const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
                allocator, "term", .language, "French", "fr", document.MissingText.untracked(source),
                null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
                if (owned) .{ .heading = "French", .code = "fr" } else null,
            );
            const decoded = try encoder.presentation_codec.decodeAlloc(allocator, bytes, "term", .language, .{ .heading = "French", .code = "fr" });
            try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(allocator, decoded));
            return decoded;
        }
    };
    const source = "== French ==\n=== podstatné jméno ===\n* ''rod mužský životný''\n" ++
        "==== skloňování ====\n* [[form]]\n==== význam ====\n# Definition [[target|label]].<ref>Note [[note]].</ref>\n#: ''Example [[example]].''\n" ++
        "==== překlady ====\n# [[translation]]\n=== Support ===\n==== význam ====\n# Unrelated [[other]].\n";
    const actual = try F.compile(a, source, true);
    const layout = actual.entry.organization;
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("podstatné jméno", lexeme.kind);
    try std.testing.expectEqualStrings("French", lexeme.language);
    try std.testing.expectEqual(@as(usize, 3), lexeme.section);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].block);
    try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null and lexeme.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{1}, lexeme.definitions[0].examples);
    try std.testing.expectEqual(@as(usize, 1), actual.entry.references.len);
    try std.testing.expectEqualSlices(usize, &.{4}, lexeme.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 5, 6 }, layout.other_sections);
    try std.testing.expect(partOfSpeech("podstatné jméno") == null);
    const without_authority = try F.compile(a, source, false);
    try std.testing.expectEqual(@as(usize, 0), without_authority.entry.organization.lexemes.len);
    var restored = actual;
    restored.entry.organization = without_authority.entry.organization;
    try std.testing.expectEqualDeep(without_authority, restored);
    for ([_][]const u8{
        "== French ==\n=== Support ===\n==== význam ====\n# Definition\n",
        "== French ==\n=== podstatné jméno ===\n==== překlady ====\n# Definition\n",
        "== French ==\n=== podstatné jméno ===\n=== Support ===\n==== význam ====\n# Definition\n",
        "== French ==\n=== podstatné jméno ===\n== New region ==\n==== význam ====\n# Definition\n",
        "== French ==\n=== podstatné jméno ===\n==== Support ====\n===== význam =====\n# Definition\n",
        "== French ==\n== podstatné jméno ==\n==== význam ====\n# Definition\n",
        "== French ==\n==== podstatné jméno ====\n===== význam =====\n# Definition\n",
        "== French ==\n=== <nowiki>podstatné jméno</nowiki> ===\n==== význam ====\n# Definition\n",
        "== French ==\n=== podstatné jméno ===\n==== <nowiki>význam</nowiki> ====\n# Definition\n",
        "== French ==\n<nowiki>=== podstatné jméno ===\n==== význam ====\n# Definition</nowiki>\n",
        "== French ==\n=== podstatné jméno ===\n==== význam ====\n* Support\n",
        "== French ==\n=== podstatné jméno ===\n==== význam ====\n## Nested without direct sense\n",
        "== French ==\n=== podstatné jméno ===\n==== význam ====\n:# Supplement without direct sense\n",
        "== French ==\n=== podstatné jméno ===\n==== význam ====\n# <nowiki>Protected definition</nowiki>\n",
        "== French ==\n=== podstatné jméno ===\n==== význam ====\n# <code>Code definition</code>\n",
        "== French ==\n=== podstatné jméno ===\n==== význam ====\n# <ref>Only a note [[note]].</ref>\n",
    }) |negative| {
        errdefer std.debug.print("CS meaning scope negative: {s}\n", .{negative});
        const value = try F.compile(a, negative, true);
        try std.testing.expectEqual(@as(usize, 0), value.entry.organization.lexemes.len);
    }
    // Direct build-only heading metadata proves the list-depth/path and generated
    // diagnostic boundaries independently of the source renderer's routing.
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block = &.{},
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span,
    };
    const headings = [_]wiki.Span{ .{ .text = "podstatné jméno" }, .{ .text = "význam" } };
    const body = [_]wiki.Block{.{ .kind = .definition, .list_path = "#", .spans = &.{.{ .text = "Definition" }} }};
    const sections = [_]Section{
        .{ .title = "podstatné jméno", .level = 3, .title_spans = headings[0..1] },
        .{ .title = "význam", .level = 4, .title_spans = headings[1..2], .blocks = &body },
    };
    try std.testing.expectEqual(@as(?usize, 0), czechMeaningParent(&sections, 1, "Independent owner"));
    for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
        try std.testing.expect(czechMeaningParent(&sections, 1, owner) == null);
    for (0..2) |which| {
        var changed = sections;
        changed[which].title_depth = 1;
        try std.testing.expect(czechMeaningParent(&changed, 1, "Independent owner") == null);
        changed = sections;
        changed[which].title_list_path = "*";
        try std.testing.expect(czechMeaningParent(&changed, 1, "Independent owner") == null);
        changed = sections;
        changed[which].is_heading = false;
        try std.testing.expect(czechMeaningParent(&changed, 1, "Independent owner") == null);
        for ([_]wiki.Provenance{ .protected_literal, .entity_literal }) |provenance| {
            var title = headings[which];
            title.provenance = provenance;
            changed = sections;
            changed[which].title_spans = &.{title};
            try std.testing.expect(czechMeaningParent(&changed, 1, "Independent owner") == null);
        }
        var generated = headings[which];
        generated.generated_diagnostic = true;
        changed = sections;
        changed[which].title_spans = &.{generated};
        try std.testing.expect(czechMeaningParent(&changed, 1, "Independent owner") == null);
    }
}

test "CS normal homosexuál retains both complete Reader bodies and CSS while gaining one authored noun sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const types = encoder.presentation_types;
    const source = @embedFile("testdata/cs-organization/page.expanded.wikitext");
    const start = std.mem.indexOf(u8, source, "== čeština ==\n") orelse return error.TestUnexpectedResult;
    const raw = @embedFile("testdata/cs-organization/page.raw.wikitext");
    try std.testing.expect(std.mem.indexOf(u8, raw, "=== podstatné jméno ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "==== význam ====\n# ") != null);
    const namespace_registry = @import("namespace_registry");
    var namespaces = try namespace_registry.Registry.init(a, @embedFile("testdata/cs-organization/namespace-registry.tsv"));
    defer namespaces.deinit();
    try namespaces.attachInterwikiMap(@embedFile("testdata/cs-organization/interwiki-map.tsv"));
    const behavior_source = @embedFile("testdata/cs-organization/behavior-switches.tsv");
    var behavior = try namespace_registry.behavior_switches.Registry.init(a, behavior_source, namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256);
    defer behavior.deinit();
    var behavior_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(behavior_source, &behavior_sha, .{});
    var images = try namespace_registry.image_options.Registry.init(a, @embedFile("testdata/cs-organization/image-options.tsv"), namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256, behavior_sha);
    defer images.deinit();
    const css = @embedFile("testdata/cs-organization/cs-common.css");
    var css_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(css, &css_sha, .{});
    try std.testing.expectEqualStrings("11e038f6419e442a525fe46e2aff0815c72c0341a18510769b675dba16652d83", &std.fmt.bytesToHex(css_sha, .lower));
    var styles = try @import("table_style_profile.zig").parseAlloc(a, css);
    defer styles.deinit();
    // Transfer the exact source-matched font declarations to the same
    // elements, including the now-proved immediate-child translation label.
    // Inline dfn margins and other unmodeled layout remain separate limits.
    const genus_rule = "abbr.genus {\n    font-style: italic;\n}";
    const genus_open = "<abbr class=\"genus\" title=\"maskulinum (mužský rod)\">m</abbr>";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, css, genus_rule));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, source, genus_open));
    const label_rule = ".priznaky {\n    font-style: italic;\n}";
    const cite_rule = "cite.citace {\n    font-style: normal;\n}";
    const child_rule = "div.translations > dfn {\n    font-weight: bold;\n    font-style: normal;\n    margin-left: .6em;\n}";
    const child_reference_rule = "div.translations > dfn {\n    margin-left: .6em;\n}";
    const child_open = "<dfn>homosexuální člověk</dfn>";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, css, child_rule));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, child_open));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, css, label_rule));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, css, cite_rule));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, source, "<span class=\"priznaky\">"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, source, "<cite class=\"citace\""));
    var reference_css = try std.mem.replaceOwned(u8, a, css, genus_rule, "");
    reference_css = try std.mem.replaceOwned(u8, a, reference_css, label_rule, "");
    reference_css = try std.mem.replaceOwned(u8, a, reference_css, cite_rule, "");
    reference_css = try std.mem.replaceOwned(u8, a, reference_css, child_rule, child_reference_rule);
    var reference_source = try std.mem.replaceOwned(u8, a, source, genus_open,
        "<abbr class=\"genus\" title=\"maskulinum (mužský rod)\" style=\"font-style: italic\">m</abbr>");
    reference_source = try std.mem.replaceOwned(u8, a, reference_source, "<span class=\"priznaky\">", "<span class=\"priznaky\" style=\"font-style: italic\">");
    reference_source = try std.mem.replaceOwned(u8, a, reference_source, "<cite class=\"citace\"", "<cite style=\"font-style: normal\" class=\"citace\"");
    reference_source = try std.mem.replaceOwned(u8, a, reference_source, child_open, "<dfn style=\"font-weight: bold; font-style: normal\">homosexuální člověk</dfn>");
    var reference_styles = try @import("table_style_profile.zig").parseAlloc(a, reference_css);
    defer reference_styles.deinit();
    for ([_][]const u8{ @embedFile("testdata/cs-organization/unclassified-reader50.json"), @embedFile("testdata/cs-organization/owned-reader50.json") }, 0..) |bytes, record| {
        const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, bytes, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
        const before = parsed.value.entries[0];
        try std.testing.expectEqualStrings("homosexuál", before.title);
        try std.testing.expectEqualStrings(if (record == 0) "Unclassified" else "čeština", before.language.?);
        try std.testing.expectEqualStrings(if (record == 0) "" else "cs", before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        // Keep the historical Reader immutable. Change exact source-bound
        // font-style and generic title fields, retaining all remaining data.
        var expected = before;
        if (record == 1) {
            try std.testing.expectEqualStrings("překlady", before.sections[7].title);
            try std.testing.expectEqual(@as(usize, 1), before.sections[7].blocks.len);
            try std.testing.expectEqual(@as(usize, 55), before.sections[7].blocks[0].spans.len);
            const sections = try a.dupe(types.Section, before.sections);
            // The old Reader omitted authored generic titles. Add only the
            // independently located IPA and ten table-header tooltip fields.
            const ipa_title = "Toto je transkripce výslovnosti pomocí mezinárodní fonetické abecedy IPA.";
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source,
                "<span title=\"" ++ ipa_title ++ "\" class=\"IPA\" >[ɦɔmɔsɛksʊaːl]</span>"));
            try std.testing.expectEqualStrings("výslovnost", sections[1].title);
            const pronunciation = try a.dupe(types.Block, sections[1].blocks);
            try std.testing.expectEqual(@as(usize, 1), pronunciation.len);
            const ipa_spans = try a.dupe(types.Span, pronunciation[0].spans);
            try std.testing.expectEqual(@as(usize, 3), ipa_spans.len);
            try std.testing.expectEqualStrings("[ɦɔmɔsɛksʊaːl]", ipa_spans[2].text);
            try std.testing.expectEqualStrings("IPA", ipa_spans[2].classes);
            try std.testing.expect(ipa_spans[2].tooltip == null);
            ipa_spans[2].tooltip = ipa_title;
            pronunciation[0].spans = ipa_spans; sections[1].blocks = pronunciation;
            try std.testing.expectEqualStrings("skloňování", sections[5].title);
            const declension = try a.dupe(types.Block, sections[5].blocks);
            try std.testing.expectEqual(@as(usize, 1), declension.len);
            var grid = declension[0].table orelse return error.TestUnexpectedResult;
            const grid_rows = try a.dupe(types.Row, grid.rows);
            try std.testing.expectEqual(@as(usize, 8), grid_rows.len);
            for (grid_rows) |*row| row.cells = try a.dupe(types.Cell, row.cells);
            const tooltip_headers = [_]struct { row: usize, cell: usize, text: []const u8, title: []const u8 }{
                .{ .row = 0, .cell = 0, .text = "pád \\ číslo", .title = "substantivum (podstatné jméno)" },
                .{ .row = 0, .cell = 1, .text = "jednotné", .title = "singulár (jednotné číslo)" },
                .{ .row = 0, .cell = 2, .text = "množné", .title = "plurál (množné číslo)" },
                .{ .row = 1, .cell = 0, .text = "nominativ", .title = "nominativ (1. pád: kdo? co?)" },
                .{ .row = 2, .cell = 0, .text = "genitiv", .title = "genitiv (2. pád: bez koho? bez čeho?)" },
                .{ .row = 3, .cell = 0, .text = "dativ", .title = "dativ (3. pád: ke komu? k čemu?)" },
                .{ .row = 4, .cell = 0, .text = "akuzativ", .title = "akuzativ (4. pád: vidíme koho? vidíme co?)" },
                .{ .row = 5, .cell = 0, .text = "vokativ", .title = "vokativ (5. pád: oslovujeme, voláme)" },
                .{ .row = 6, .cell = 0, .text = "lokál", .title = "lokál (6. pád: o kom? o čem?)" },
                .{ .row = 7, .cell = 0, .text = "instrumentál", .title = "instrumentál (7. pád: s kým? s čím?)" },
            };
            for (tooltip_headers) |header| {
                const authored = try std.fmt.allocPrint(a, "<span title=\"{s}\">{s}</span>", .{header.title, header.text});
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, authored));
                try std.testing.expectEqual(@as(usize, 3), grid_rows[header.row].cells.len);
                const cell = &@constCast(grid_rows[header.row].cells)[header.cell];
                try std.testing.expect(cell.blocks == null);
                const header_spans = try a.dupe(types.Span, cell.spans);
                try std.testing.expectEqual(@as(usize, 1), header_spans.len);
                try std.testing.expectEqualStrings(header.text, header_spans[0].text);
                try std.testing.expect(header_spans[0].tooltip == null);
                header_spans[0].tooltip = header.title; cell.spans = header_spans;
            }
            grid.rows = grid_rows; declension[0].table = grid; sections[5].blocks = declension;
            const blocks = try a.dupe(types.Block, sections[7].blocks);
            const spans = try a.dupe(types.Span, blocks[0].spans);
            // Historical unsupported output is immutable, not the new oracle.
            // Exact expanded58 is a direct dfn child of div.translations;
            // CSS466 explicitly requests bold and normal, with no body edits.
            try std.testing.expectEqualStrings("homosexuální člověk", spans[0].text);
            try std.testing.expectEqualStrings("translations", spans[0].classes);
            try std.testing.expect(spans[0].kind == .text and spans[0].italic and !spans[0].bold);
            spans[0].bold = true;
            spans[0].italic = false;
            for ([_]usize{ 12, 18, 22, 28, 32, 38, 42, 46 }) |index| {
                try std.testing.expectEqualStrings("m", spans[index].text);
                try std.testing.expectEqualStrings("translations genus", spans[index].classes);
                try std.testing.expectEqualStrings("maskulinum (mužský rod)", spans[index].explanation);
                try std.testing.expect(!spans[index].italic);
                spans[index].italic = true;
            }
            blocks[0].spans = spans;
            sections[7].blocks = blocks;
            try std.testing.expectEqualStrings("synonyma", before.sections[8].title);
            try std.testing.expectEqual(@as(usize, 1), before.sections[8].blocks.len);
            try std.testing.expectEqual(@as(usize, 110), before.sections[8].blocks[0].spans.len);
            const label_blocks = try a.dupe(types.Block, sections[8].blocks);
            const label_spans = try a.dupe(types.Span, label_blocks[0].spans);
            const label_indices = [_]usize{ 2, 6, 91, 96, 103, 104, 105 };
            const label_texts = [_][]const u8{ "(expresivně)", "(vulgárně)", "(argot)", "(archaicky)", "(v", "\xc2\xa0", "obecném jazyce)" };
            for (label_indices, label_texts) |index, text| {
                try std.testing.expectEqualStrings(text, label_spans[index].text);
                try std.testing.expectEqualStrings("priznaky", label_spans[index].classes);
                try std.testing.expect(!label_spans[index].italic);
                label_spans[index].italic = true;
            }
            label_blocks[0].spans = label_spans;
            sections[8].blocks = label_blocks;
            expected.sections = sections;
            // Source quote pairs keep only the book/periodical titles italic.
            // These exact old runs cover three independently authored citations.
            const references = try a.dupe(types.Reference, before.references);
            for ([_]usize{ 0, 2, 3 }, [_]usize{ 11, 7, 17 }) |index, count| {
                try std.testing.expectEqual(count, before.references[index].spans.len);
                try std.testing.expect(before.references[index].blocks == null);
                const cite_spans = try a.dupe(types.Span, before.references[index].spans);
                for (cite_spans, 0..) |*span, span_index| {
                    try std.testing.expectEqualStrings("citace", span.classes);
                    try std.testing.expect(span.italic);
                    span.italic = if (index == 3) span_index >= 1 and span_index <= 5 else span_index == 1;
                }
                references[index].spans = cite_spans;
            }
            expected.references = references;
        }
        var report: document.Fallbacks = .{};
        const payload = try document.compileClassifiedWithHeadingAnchorsAndTableStylesAlloc(
            a, before.title, .language, before.language, before.language_code,
            document.MissingText.untracked(if (record == 0) source[0..start] else source[start..]),
            null, .{}, &namespaces, &behavior, &images, .{}, &report, null, &.{}, null, &.{},
            if (record == 0) null else .{ .heading = "čeština", .code = "cs" }, &styles,
        );
        const decoded = try encoder.presentation_codec.decodeAlloc(a, payload, before.title, .language, .{ .heading = before.language.?, .code = before.language_code });
        if (record == 0) {
            try std.testing.expectEqualDeep(types.Stored{ .entry = before }, decoded);
        } else {
            const layout = decoded.entry.organization;
            try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
            const lexeme = layout.lexemes[0];
            try std.testing.expectEqualStrings("podstatné jméno", lexeme.kind);
            try std.testing.expectEqualStrings("čeština", lexeme.language);
            try std.testing.expectEqual(@as(usize, 6), lexeme.section);
            try std.testing.expect(lexeme.etymology == null);
            try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
            try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].block);
            try std.testing.expect(lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
            try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].examples.len);
            try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].quotations.len);
            try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].notes.len);
            try std.testing.expectEqual(@as(usize, 0), lexeme.introduction.len);
            try std.testing.expectEqual(@as(usize, 0), lexeme.other_blocks.len);
            try std.testing.expectEqualSlices(usize, &.{ 7, 8, 9, 10 }, lexeme.related_sections);
            try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5, 11, 12 }, layout.other_sections);
            try std.testing.expect(report.rendered_lua_error);
            var restored = decoded;
            restored.entry.organization = before.organization;
            try std.testing.expectEqualDeep(types.Stored{ .entry = expected }, restored);
        }
        var reference_report: document.Fallbacks = .{};
        const reference_payload = try document.compileClassifiedWithHeadingAnchorsAndTableStylesAlloc(
            a, before.title, .language, before.language, before.language_code,
            document.MissingText.untracked(if (record == 0) reference_source[0..start] else reference_source[start..]),
            null, .{}, &namespaces, &behavior, &images, .{}, &reference_report, null, &.{}, null, &.{},
            if (record == 0) null else .{ .heading = "čeština", .code = "cs" }, &reference_styles,
        );
        const reference_decoded = try encoder.presentation_codec.decodeAlloc(a, reference_payload, before.title, .language, .{ .heading = before.language.?, .code = before.language_code });
        try std.testing.expectEqualDeep(decoded, reference_decoded);
        try std.testing.expectEqualSlices(u8, payload, reference_payload);
        try std.testing.expectEqualDeep(report, reference_report);
        // Complete Stored equality above retains every section, span, action,
        // 24-cell CSS table, numbered reference and both visible source errors.
        try std.testing.expectEqualSlices(u8, payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}


test "declared noun numbered term details retain owner markers and lexical scope barriers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const body = try renderer.renderBody("'''headword'''\n;1: [[Meaning|meaning]]<ref>note [[Book]]</ref>\n;2: ''second''\n: unrelated continuation\n");
    try std.testing.expectEqual(@as(usize, 6), body.len);
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Etimología", .level = 3 },
        .{ .title = "Sustantivo femenino", .level = 3, .blocks = body },
        .{ .title = "Support", .level = 4, .blocks = body },
        .{ .title = "Véase también", .level = 3, .blocks = body },
        .{ .title = "Later region", .level = 2 },
        .{ .title = "Noun", .level = 3, .blocks = body },
    };
    const layout = try buildOwned(a, &sections, "French");
    try std.testing.expectEqual(@as(usize, 2), layout.lexemes.len);
    const first = layout.lexemes[0];
    try std.testing.expectEqualStrings("French", first.language);
    try std.testing.expectEqualStrings("Noun", first.kind);
    try std.testing.expectEqual(@as(usize, 2), first.section);
    try std.testing.expectEqual(@as(?usize, 1), first.etymology);
    try std.testing.expectEqual(@as(usize, 2), first.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), first.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 4), first.definitions[1].block);
    for (first.definitions) |sense| {
        try std.testing.expect(sense.parent == null and sense.form == null);
        try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
    }
    try std.testing.expectEqualSlices(usize, &.{0}, first.introduction);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 5 }, first.other_blocks);
    try std.testing.expectEqualSlices(usize, &.{3}, first.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 5 }, layout.other_sections);
    try std.testing.expect(layout.lexemes[1].etymology == null);
    try std.testing.expectEqualStrings("French", layout.lexemes[1].language);
    // Paragraph-inferred POS cannot lend this explicit numbered convention.
    const inferred = try analyze(a, "Noun", 0, null, body, false);
    try std.testing.expectEqual(@as(usize, 0), inferred.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, inferred.introduction);
    for ([_][]const u8{ "sustantivo femenino", "Sustantivo femenino unknown", "Sustantivo", "Véase también" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const boundary = [_]Section{.{ .title = "Sustantivo femenino", .level = 2, .blocks = body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &boundary)).lexemes.len);
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    // Plain metadata terms, protected/code/link markers and noncanonical numbers
    // retain body blocks without becoming lexical definitions.
    for ([_][]const u8{ ";Label: detail", ";0: detail", ";01: detail", ";1a: detail", ";[[1]]: detail", ";[[control|1]]: detail", ";<code>1</code>: detail", ";<nowiki>1</nowiki>: detail" }) |source| {
        const negative_body = try renderer.renderBody(source);
        const negative = try analyze(a, "Noun", 0, null, negative_body, true);
        try std.testing.expectEqual(@as(usize, 0), negative.definitions.len);
        try std.testing.expectEqual(negative_body.len, negative.introduction.len);
    }
    const split = [_]wiki.Block{ body[1], body[0], body[2] };
    try std.testing.expectEqual(@as(usize, 0), (try analyze(a, "Noun", 0, null, &split, true)).definitions.len);
    const unknown = [_]Section{.{ .title = "Unknown", .level = 3, .blocks = body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &unknown, "French")).lexemes.len);
    const ordinary = try renderer.renderBody("# first\n#: example\n## child\n#* quotation");
    const unchanged = try analyze(a, "Noun", 0, null, ordinary, true);
    try std.testing.expectEqual(@as(usize, 2), unchanged.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{1}, unchanged.definitions[0].examples);
    try std.testing.expectEqual(@as(?usize, 0), unchanged.definitions[1].parent);
}

test "retained ataujia noun organization preserves complete typed body diagnostics and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Projection = struct { actual: struct { sections: []const Section } };
    const Typed = struct { actual: types.Entry, expected: types.Entry };
    const source = @embedFile("es-ataujia-entry-pair69.json");
    var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualStrings("38147044e0553d03b8182408045e55290c2a4cdf23d606b8ee4767df036a40d1", &std.fmt.bytesToHex(digest, .lower));
    const projected = try std.json.parseFromSlice(Projection, a, source, .{ .ignore_unknown_fields = true });
    const typed = try std.json.parseFromSlice(Typed, a, source, .{ .ignore_unknown_fields = true });
    const before = typed.value.actual;
    try std.testing.expectEqualDeep(typed.value.expected, before);
    try std.testing.expectEqualStrings("ataujía", before.title);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqualStrings("español", before.language.?);
    try std.testing.expectEqualStrings("es", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, before.organization.other_sections);
    const sections = projected.value.actual.sections;
    try std.testing.expectEqual(@as(usize, 6), sections.len);
    try std.testing.expectEqualStrings("Sustantivo femenino", sections[2].title);
    try std.testing.expectEqual(@as(u8, 3), sections[2].level);
    try std.testing.expectEqual(wiki.Kind.term, sections[2].blocks[1].kind);
    try std.testing.expectEqualStrings("1", sections[2].blocks[1].spans[0].text);
    try std.testing.expectEqual(wiki.Kind.list_detail, sections[2].blocks[2].kind);
    const layout = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("español", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 2), lexical.section);
    try std.testing.expectEqual(@as(?usize, 1), lexical.etymology);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), lexical.definitions[0].block);
    try std.testing.expect(lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
    try std.testing.expect(lexical.definitions[0].examples.len == 0 and lexical.definitions[0].quotations.len == 0 and lexical.definitions[0].notes.len == 0);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{1}, lexical.other_blocks);
    try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 5 }, layout.other_sections);
    const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = before.language_code, .heading = before.language.? });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
    try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
    try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
    try std.testing.expectEqualDeep(before.references, decoded.entry.references);
    try std.testing.expectEqualDeep(before.media, decoded.entry.media);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "current ES56 noun organization preserves complete normal Reader body paint actions and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Projection = struct { entries: []const struct { sections: []const Section } };
    const Typed = struct { entries: []const types.Entry };
    const source = @embedFile("es-ataujia-reader56.json");
    var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualStrings("6072f76e44e4d3c29326a4a837f868dd6161731dd5385159b4326728103355f4", &std.fmt.bytesToHex(digest, .lower));
    const projected = try std.json.parseFromSlice(Projection, a, source, .{ .ignore_unknown_fields = true });
    const typed = try std.json.parseFromSlice(Typed, a, source, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), typed.value.entries.len);
    const before = typed.value.entries[0];
    try std.testing.expectEqualStrings("ataujía", before.title);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqualStrings("español", before.language.?);
    try std.testing.expectEqualStrings("es", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, before.organization.other_sections);
    const sections = projected.value.entries[0].sections;
    try std.testing.expectEqual(@as(usize, 6), sections.len);
    try std.testing.expectEqualStrings("Sustantivo femenino", sections[2].title);
    try std.testing.expectEqual(@as(u8, 3), sections[2].level);
    try std.testing.expectEqual(wiki.Kind.term, sections[2].blocks[1].kind);
    try std.testing.expectEqualStrings("1", sections[2].blocks[1].spans[0].text);
    try std.testing.expectEqual(wiki.Kind.list_detail, sections[2].blocks[2].kind);
    const layout = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("español", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 2), lexical.section);
    try std.testing.expectEqual(@as(?usize, 1), lexical.etymology);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), lexical.definitions[0].block);
    try std.testing.expect(lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
    try std.testing.expect(lexical.definitions[0].examples.len == 0 and lexical.definitions[0].quotations.len == 0 and lexical.definitions[0].notes.len == 0);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{1}, lexical.other_blocks);
    try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 5 }, layout.other_sections);
    const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .code = before.language_code, .heading = before.language.? });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
    try std.testing.expectEqualDeep(before.display_title, decoded.entry.display_title);
    try std.testing.expectEqualDeep(before.preamble_spans, decoded.entry.preamble_spans);
    try std.testing.expectEqualDeep(before.references, decoded.entry.references);
    try std.testing.expectEqualDeep(before.media, decoded.entry.media);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
}


test "exact Korean adjective heading preserves supplied owner senses and unknown label boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Adjective", partOfSpeech("형용사").?);
    for ([_][]const u8{ "형용사형", "형용사 2", "형용사?", " 형용사", "형용사 ", "발음", "파생 어휘", "주석" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control", .language = "Declared owner" } };
    const blocks = try renderer.renderBody("'''headword'''\n# First [[target|sense]].\n#: ''First example.''\n#: ''Second example.''\n# Second sense.\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "발음", .level = 3 },
        .{ .title = "형용사", .level = 3, .blocks = blocks },
        .{ .title = "파생 어휘", .level = 4 },
        .{ .title = "형용사형", .level = 3, .blocks = blocks },
        .{ .title = "주석", .level = 3 },
    };
    const layout = try buildOwned(a, &sections, "Declared owner");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("Adjective", lexeme.kind);
    try std.testing.expectEqualStrings("Declared owner", lexeme.language);
    try std.testing.expectEqual(@as(usize, 1), lexeme.section);
    try std.testing.expectEqual(@as(usize, 2), lexeme.definitions.len);
    try std.testing.expectEqual(@as(usize, 2), lexeme.definitions[0].examples.len);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[1].examples.len);
    try std.testing.expectEqualSlices(usize, &.{2}, lexeme.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 4 }, layout.other_sections);
    const unclassified = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unclassified.lexemes.len);
    try std.testing.expectEqualStrings("", unclassified.lexemes[0].language);
    try std.testing.expectEqualDeep(lexeme.definitions, unclassified.lexemes[0].definitions);
    const protected_blocks = try renderer.renderBody("<nowiki>===형용사===</nowiki>\n<pre>===형용사===</pre>\n# body\n");
    const protected = [_]Section{.{ .title = "Unknown label", .level = 3, .blocks = protected_blocks }};
    const protected_layout = try buildOwned(a, &protected, "Declared owner");
    try std.testing.expectEqual(@as(usize, 0), protected_layout.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, protected_layout.other_sections);
}

test "exact TL numbered etymology headings link existing lexemes without assigning language or POS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "Etimolohiya", "Etimolohiya 1", "Etimolohiya 2", "Etimolohiya 12" }) |title|
        try std.testing.expect(exactNumberedHeading(title, "Etimolohiya"));
    for ([_][]const u8{ "etimolohiya", "ETIMOLOHIYA", "Etimolohiya ", "Etimolohiya 0", "Etimolohiya 01", "Etimolohiya -1", "Etimolohiya 1a", "Etimolohiya  1", "Etimolohiya note", "Unknown Etimolohiya", "<nowiki>Etimolohiya</nowiki>" }) |title|
        try std.testing.expect(!exactNumberedHeading(title, "Etimolohiya"));
    try std.testing.expect(partOfSpeech("Etimolohiya") == null);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("'''word'''\n# [[Meaning|meaning]]\n#: ''example''\n");
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Etimolohiya 1", .level = 3 },
        .{ .title = "Pang-uri", .level = 4, .blocks = body },
        .{ .title = "Etimolohiya 2", .level = 3 },
        .{ .title = "Pandamdam", .level = 4, .blocks = body },
        .{ .title = "Later owner region", .level = 2 },
        .{ .title = "Pangngalan", .level = 3, .blocks = body },
    };
    const layout = try buildOwned(a, &sections, "Independent French");
    try std.testing.expectEqual(@as(usize, 3), layout.lexemes.len);
    const origins = [_]?usize{ 1, 3, null };
    const kinds = [_][]const u8{ "Adjective", "Interjection", "Noun" };
    for (layout.lexemes, origins, kinds) |lexical, origin, kind| {
        try std.testing.expectEqualStrings("Independent French", lexical.language);
        try std.testing.expectEqualStrings(kind, lexical.kind);
        try std.testing.expectEqual(origin, lexical.etymology);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3, 5 }, layout.other_sections);
    const unknown = try buildUnclassified(a, &sections);
    for (unknown.lexemes) |lexical| try std.testing.expectEqualStrings("", lexical.language);
    const support = [_]Section{ .{ .title = "Etimolohiya", .level = 3 }, .{ .title = "Support", .level = 4, .blocks = body } };
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &support, "Independent French")).lexemes.len);
    for ([_][]const u8{ "Etimolohiya 0", "Etimolohiya note", "etimolohiya" }) |heading| {
        const unproved = [_]Section{ .{ .title = heading, .level = 3 }, .{ .title = "Pangngalan", .level = 4, .blocks = body } };
        const unproved_layout = try buildOwned(a, &unproved, "Independent French");
        try std.testing.expectEqual(@as(usize, 1), unproved_layout.lexemes.len);
        try std.testing.expect(unproved_layout.lexemes[0].etymology == null);
    }
}

test "actual TL60 all owned records preserve complete body errors actions media and codec except etymology pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const Projection = struct { entries: []const struct { sections: []const Section } };
    const Typed = struct { entries: []const types.Entry };
    const Case = struct { source: []const u8, sha256: []const u8, origins: []const ?usize };
    const cases = [_]Case{
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-et.json"), .sha256 = "934246416e726622fc4c9194604639bd6b210b77fa44277d28bfb779a5684fd9", .origins = &.{ null } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-pam.json"), .sha256 = "060e623cbc07d109aa153cd17654a8553d05200b2b50f6dc47af6d7a32a2d882", .origins = &.{ null } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-lv.json"), .sha256 = "c79886f08c98a360e236df99c69a54cd4f991714ff6033f89f97c3653a296cc3", .origins = &.{ null } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-lt.json"), .sha256 = "132c50de1d17591428d7f3469fb5fcea393c0e7120c99ce631d919229dd70f5d", .origins = &.{ null } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-pl.json"), .sha256 = "8ff31d04300444e1c5111e1984adf3a226d793b202cff5e96d2344d58aee26b4", .origins = &.{ null } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-tl.json"), .sha256 = "f0dcf809fdb361349c0ca45b04aa6aa5c6d365e7b666496c082ba6fc61a9c15b", .origins = &.{ 3 } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/abaka-cs.json"), .sha256 = "6ea63d3d9bedf4973b26f82d24c76193055c627cec81a4068db2e25af9353142", .origins = &.{ null } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/aab-unclassified.json"), .sha256 = "6345e7722c8d10def1918f27e1172faebc9202bb782f49951d59f53d90644581", .origins = &.{  } },
        .{ .source = @embedFile("testdata/tl-etymology-current60/aba-tl.json"), .sha256 = "adec3e5d7e7e1be7f1a34cae438b184ffd52b1995f17041d68871b772dfad9a2", .origins = &.{ 1, 5 } },
    };
    var changes: usize = 0;
    var preserved_unclassified: usize = 0;
    for (cases) |case| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(case.source, &digest, .{});
        try std.testing.expectEqualStrings(case.sha256, &std.fmt.bytesToHex(digest, .lower));
        const typed = try std.json.parseFromSlice(Typed, a, case.source, .{ .ignore_unknown_fields = true });
        const projection = try std.json.parseFromSlice(Projection, a, case.source, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), typed.value.entries.len);
        try std.testing.expectEqual(@as(usize, 1), projection.value.entries.len);
        const before = typed.value.entries[0];
        try std.testing.expect(before.kind == .language);
        const heading = before.language orelse return error.TestUnexpectedResult;
        const sections = projection.value.entries[0].sections;
        const computed = if (before.language_code.len == 0) try buildUnclassified(a, sections) else try buildOwned(a, sections, heading);
        const organization_json = try std.json.Stringify.valueAlloc(a, computed, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        var expected: types.Stored = .{ .entry = before };
        const expected_lexemes = try a.dupe(types.Lexeme, before.organization.lexemes);
        expected.entry.organization.lexemes = expected_lexemes;
        try std.testing.expectEqual(case.origins.len, expected_lexemes.len);
        for (expected_lexemes, case.origins) |*lexical, origin| {
            try std.testing.expect(lexical.etymology == null);
            lexical.etymology = origin;
            if (origin) |index| {
                try std.testing.expect(exactNumberedHeading(before.sections[index].title, "Etimolohiya"));
                changes += 1;
            }
        }
        try std.testing.expectEqualDeep(expected.entry.organization, organization.value);
        var actual: types.Stored = .{ .entry = before };
        actual.entry.organization = organization.value;
        try std.testing.expectEqualDeep(expected, actual);
        const encoded = try encoder.presentation_codec.encodeAlloc(a, actual);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .heading = heading, .code = before.language_code });
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(before.references, decoded.entry.references);
        try std.testing.expectEqualDeep(before.media, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
        if (before.language_code.len == 0) {
            try std.testing.expectEqualStrings("aab", before.title);
            try std.testing.expectEqualStrings("Unclassified", heading);
            try std.testing.expectEqualDeep(before, decoded.entry);
            preserved_unclassified += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), changes);
    try std.testing.expectEqual(@as(usize, 1), preserved_unclassified);
}

test "Urdu noun organization requires owned physical heading parsed headword and direct definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const F = struct {
        fn compile(allocator: A, source: []const u8, owner: ?[]const u8) !encoder.presentation_types.Stored {
            const label = owner orelse "Unclassified";
            const code: []const u8 = if (std.mem.eql(u8, label, "اردو")) "ur" else if (std.mem.eql(u8, label, "French")) "fr" else "";
            const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
                allocator, "control", .language, label, code, document.MissingText.untracked(source),
                null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
                if (code.len != 0) .{ .heading = label, .code = code } else null,
            );
            const decoded = try encoder.presentation_codec.decodeAlloc(allocator, bytes, "control", .language, .{ .heading = label, .code = code });
            try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(allocator, decoded));
            return decoded;
        }
    };
    const headword = "<strong class=\"ur-Arab headword\" lang=\"ur\">[[کتاب#اردو|کتاب]] [[ادعیہ#اردو|ادعیہ]]</strong> <span class=\"gender\" title=\"feminine gender\">مؤنث</span>\n";
    const sense = "# Meaning [[meaning|label]].\n";
    const tail = "=== تراجم ===\n==== انگریزی ====\n* Book of Common Prayer\n";
    const source = "== اردو ==\n=== اسم ===\n" ++ headword ++ sense ++ tail;
    const actual = try F.compile(a, source, "اردو");
    const layout = actual.entry.organization;
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("اردو", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, layout.other_sections);
    // An independent standard noun heading yields the same complete body and
    // organization. Restore only its intentionally different title/anchors.
    var reference = try F.compile(a, "== اردو ==\n=== Noun ===\n" ++ headword ++ sense ++ tail, "اردو");
    const sections = try a.dupe(encoder.presentation_types.Section, reference.entry.sections);
    reference.entry.sections = sections;
    sections[1].title = actual.entry.sections[1].title;
    sections[1].anchor = actual.entry.sections[1].anchor;
    sections[1].anchor_fallback = actual.entry.sections[1].anchor_fallback;
    try std.testing.expectEqualDeep(reference, actual);
    try std.testing.expectEqualSlices(u8, try encoder.presentation_codec.encodeAlloc(a, reference), try encoder.presentation_codec.encodeAlloc(a, actual));
    for ([_]?[]const u8{ null, "", "French", "Unclassified" }) |owner|
        try std.testing.expectEqual(@as(usize, 0), (try F.compile(a, source, owner)).entry.organization.lexemes.len);
    for ([_][]const u8{
        "=== <nowiki>اسم</nowiki> ===\n" ++ headword ++ sense,
        "=== <code>اسم</code> ===\n" ++ headword ++ sense,
        "=== اسم ===\n'''plain unmarked headword'''\n" ++ sense,
        "=== اسم ===\n<strong class=\"headword\" lang=\"en\">word</strong>\n" ++ sense,
        "=== اسم ===\n" ++ headword ++ "\nSupport paragraph.\n\n" ++ sense,
        "=== اسم ===\n" ++ headword ++ "==== Other ====\n" ++ sense,
        "=== اسم ===\n" ++ headword ++ "* Not a definition.\n",
        "=== اسم ===\n" ++ headword ++ "## Nested definition.\n",
        "=== اسم ===\n" ++ headword ++ "# <nowiki>protected meaning</nowiki>\n",
        "=== اسم ===\n" ++ headword ++ "# <code>code meaning</code>\n",
        "==== اسم ====\n" ++ headword ++ sense,
        "<h3>\n:اسم</h3>\n" ++ headword ++ sense,
        "=== تراجم ===\n" ++ headword ++ sense,
    }) |negative|
        try std.testing.expectEqual(@as(usize, 0), (try F.compile(a, try std.fmt.allocPrint(a, "== اردو ==\n{s}", .{negative}), "اردو")).entry.organization.lexemes.len);
}

test "Urdu actual lexical Reader retains complete definition gender actions and translations with noun organization codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/ur-lexical66/reader.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqualStrings("a99ee2d1c43f04f545fac689c32efc86b78e1dd1dddc783f152739c4def7cb85", &std.fmt.bytesToHex(digest, .lower));
    const raw = @embedFile("testdata/ur-lexical66/page.raw.wikitext");
    const noun_template = @embedFile("testdata/ur-lexical66/noun-template.raw.wikitext");
    try std.testing.expect(std.mem.startsWith(u8, raw, "== اردو ==\n\n=== اسم ===\n{{ur-noun|g=f}}"));
    try std.testing.expect(std.mem.startsWith(u8, noun_template, "{{head|ur|اسما|"));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("کتاب ادعیہ", before.title);
    try std.testing.expectEqualStrings("اردو", before.language.?);
    try std.testing.expectEqualStrings("ur", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 4), before.sections.len);
    // The full typed Entry remains the serialization authority. This compiler
    // view supplies analysis indices only. Its plain physical title is proved
    // by the exact raw page; restored internal flags come from typed spans.
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                try std.testing.expectEqualStrings("", typed_span.trail);
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language.?);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("اردو", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expect(noun.etymology == null);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expect(noun.definitions[0].parent == null and noun.definitions[0].form == null);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].examples.len);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].quotations.len);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].notes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqual(@as(usize, 0), noun.other_blocks.len);
    try std.testing.expectEqual(@as(usize, 0), noun.related_sections.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, layout.other_sections);
    const body = before.sections[1].blocks;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    try std.testing.expectEqualStrings("کتاب#اردو", body[0].spans[0].target);
    try std.testing.expectEqualStrings("ادعیہ#اردو", body[0].spans[2].target);
    try std.testing.expect(body[0].spans[0].bold and body[0].spans[2].bold);
    try std.testing.expectEqualStrings("مؤنث", body[0].spans[5].text);
    try std.testing.expectEqualStrings("feminine gender", body[0].spans[5].explanation);
    const definition = "انگلیکان گرجا گھروں میں پڑھی جانے والی دعاؤں کی کتاب";
    try std.testing.expectEqualStrings(definition, body[1].spans[0].text);
    try std.testing.expect(std.mem.indexOf(u8, raw, "# " ++ definition) != null);
    try std.testing.expectEqualStrings("Book of Common Prayer", before.sections[3].blocks[0].spans[0].text);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "اردو", .code = "ur" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}


test "exact Korean adverb heading organizes supplied owner definition without interpreting neighboring labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Adverb", partOfSpeech("부사") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "부사형", "부사 2", "부사?", " 부사", "부사 ", "발음", "Unknown 부사", "<nowiki>부사</nowiki>" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody("'''headword'''\n# [[target|meaning]]\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "발음", .level = 3 },
        .{ .title = "부사", .level = 3, .blocks = blocks },
        .{ .title = "부사형", .level = 3, .blocks = blocks },
    };
    const layout = try buildOwned(a, &sections, "Independently supplied owner");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexeme = layout.lexemes[0];
    try std.testing.expectEqualStrings("Adverb", lexeme.kind);
    try std.testing.expectEqualStrings("Independently supplied owner", lexeme.language);
    try std.testing.expectEqual(@as(usize, 1), lexeme.section);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 0), lexeme.definitions[0].examples.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, layout.other_sections);
    const unclassified = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unclassified.lexemes.len);
    try std.testing.expectEqualStrings("", unclassified.lexemes[0].language);
    try std.testing.expectEqualDeep(lexeme.definitions, unclassified.lexemes[0].definitions);
    const protected_blocks = try renderer.renderBody("<nowiki>===부사===</nowiki>\n<pre>===부사===</pre>\n# body\n");
    const protected = [_]Section{.{ .title = "Unknown label", .level = 3, .blocks = protected_blocks }};
    const protected_layout = try buildOwned(a, &protected, "Independently supplied owner");
    try std.testing.expectEqual(@as(usize, 0), protected_layout.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, protected_layout.other_sections);
}

test "exact MNW adverb heading preserves independent ownership and rejects neighboring raw labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    try std.testing.expectEqualStrings("Adverb", partOfSpeech("ကြိယာဝိသေသန") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("နာမ်") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "ကြိယာဝိသေသန 2", "ကြိယာဝိသေသန?", " ကြိယာဝိသေသန", "ကြိယာဝိသေသန ", "Unknown ကြိယာဝိသေသန", "ကြိယာဝိသေသန\xe2\x80\x8e", "sv-adv", "sv", "သွဳဒေန်", "<nowiki>ကြိယာဝိသေသန</nowiki>" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const F = struct {
        fn compile(allocator: A, body: []const u8, heading: []const u8, code: []const u8) !encoder.presentation_types.Stored {
            const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
                allocator, "ost", .language, heading, code, document.MissingText.untracked(body),
                null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
                .{ .heading = heading, .code = code },
            );
            const decoded = try encoder.presentation_codec.decodeAlloc(allocator, bytes, "ost", .language, .{ .heading = heading, .code = code });
            try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(allocator, decoded));
            return decoded;
        }
    };
    const source = "== Source language ==\n=== ကြိယာဝိသေသန ===\n'''ost'''\n# [[meaning|လ္ပာ်ဖာဗၟံက်။]]\n";
    for ([_]struct { heading: []const u8, code: []const u8 }{
        .{ .heading = "သွဳဒေန်", .code = "sv" },
        .{ .heading = "Independent foreign owner", .code = "fr" },
    }) |owner| {
        const stored = try F.compile(a, source, owner.heading, owner.code);
        try std.testing.expectEqualStrings(owner.heading, stored.entry.language orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualStrings(owner.code, stored.entry.language_code);
        try std.testing.expectEqual(@as(usize, 1), stored.entry.organization.lexemes.len);
        const lexeme = stored.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings("Adverb", lexeme.kind);
        try std.testing.expectEqualStrings(owner.heading, lexeme.language);
        try std.testing.expectEqual(@as(usize, 1), lexeme.section);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
        try std.testing.expect(lexeme.etymology == null and lexeme.definitions[0].parent == null and lexeme.definitions[0].form == null);
        try std.testing.expectEqualSlices(usize, &.{0}, lexeme.introduction);
        try std.testing.expectEqual(@as(usize, 0), lexeme.other_blocks.len);
        try std.testing.expectEqual(@as(usize, 0), lexeme.related_sections.len);
    }
    for ([_][]const u8{
        "== Source language ==\n=== ကြိယာဝိသေသန 2 ===\n'''ost'''\n# Meaning\n",
        "== Source language ==\n=== Unknown ကြိယာဝိသေသန ===\n'''ost'''\n# Meaning\n",
        "== Source language ==\n<nowiki>===ကြိယာဝိသေသန===</nowiki>\n'''ost'''\n# Meaning\n",
        "== Source language ==\n<pre>===ကြိယာဝိသေသန===\n'''ost'''\n# Meaning\n</pre>\n",
        "== Source language ==\n<!-- ===ကြိယာဝိသေသန=== -->\n'''ost'''\n# Meaning\n",
    }) |negative| {
        const denied = try F.compile(a, negative, "သွဳဒေန်", "sv");
        try std.testing.expectEqual(@as(usize, 0), denied.entry.organization.lexemes.len);
        try std.testing.expectEqualStrings("သွဳဒေန်", denied.entry.language.?);
        try std.testing.expectEqualStrings("sv", denied.entry.language_code);
    }
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody("'''ost'''\n# Meaning\n");
    const unowned_sections = [_]Section{.{ .title = "ကြိယာဝိသေသန", .level = 3, .blocks = blocks }};
    const unowned = try buildUnclassified(a, &unowned_sections);
    try std.testing.expectEqual(@as(usize, 1), unowned.lexemes.len);
    try std.testing.expectEqualStrings("Adverb", unowned.lexemes[0].kind);
    try std.testing.expectEqualStrings("", unowned.lexemes[0].language);
}

test "retained MNW ost complete Reader gains only authored adverb organization and preserves codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const reader_bytes = @embedFile("testdata/mnw-ost-pos/reader115.json");
    const raw = @embedFile("testdata/mnw-ost-pos/raw.wikitext");
    const expanded = @embedFile("testdata/mnw-ost-pos/expanded.wikitext");
    const Check = struct {
        fn hash(bytes: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    try Check.hash(reader_bytes, "dfb51645e2243adc2fd4171d0e8294403b935984d5767c3270460c029566dd5e");
    try Check.hash(raw, "83d32a32dbb6f38b6ee2ee0c4d0d3fe82645344ef2609a8d781faa8b2cb9c654");
    try Check.hash(expanded, "25253b16e9a1e9f38f410a43c74458a2863be381ef95bb63097887ae8b9043ac");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "===ကြိယာဝိသေသန===\n{{sv-adv|-}}"));
    try std.testing.expect(std.mem.indexOf(u8, expanded, "ကြိယာဝိသေသနသွဳဒေန်") != null);
    const page = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, reader_bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), page.value.entries.len);
    const before = page.value.entries[0];
    try std.testing.expectEqualStrings("ost", before.title);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqualStrings("သွဳဒေန်", before.language.?);
    try std.testing.expectEqualStrings("sv", before.language_code);
    try std.testing.expectEqual(@as(usize, 9), before.sections.len);
    try std.testing.expectEqual(@as(usize, 2), before.organization.lexemes.len);
    for (before.organization.lexemes, [_]usize{ 4, 7 }) |lexeme, section_index| {
        try std.testing.expectEqualStrings("Noun", lexeme.kind);
        try std.testing.expectEqualStrings("သွဳဒေန်", lexeme.language);
        try std.testing.expectEqual(section_index, lexeme.section);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions[0].block);
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 5, 6 }, before.organization.other_sections);
    try std.testing.expectEqualStrings("ကြိယာဝိသေသန", before.sections[6].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[6].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[6].blocks.len);
    try std.testing.expect(before.sections[6].blocks[0].kind == .paragraph and before.sections[6].blocks[1].kind == .definition);
    try std.testing.expectEqualStrings("#", before.sections[6].blocks[1].list_path);
    var definition: std.ArrayList(u8) = .empty;
    for (before.sections[6].blocks[1].spans) |span| try definition.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("လ္ပာ်ဖာဗၟံက်။", definition.items);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, reader_bytes, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // The build-only projection supplies block addresses and flags. The complete
    // independently parsed Reader Entry remains the body/error/style oracle.
    for (sections, before.sections) |*section, original_section| {
        const blocks = try a.dupe(wiki.Block, section.blocks);
        for (blocks, original_section.blocks) |*block, original_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            for (spans, original_block.spans) |*span, original_span| span.flags = .{
                .bold = original_span.bold, .italic = original_span.italic,
                .code = original_span.code, .small = original_span.small,
                .superscript = original_span.superscript, .subscript = original_span.subscript,
                .strike = original_span.strike, .underline = original_span.underline,
            };
            block.spans = spans;
        }
        section.blocks = blocks;
    }
    const layout = try buildOwned(a, sections, before.language.?);
    const layout_json = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, layout_json, .{});
    const wanted_lexemes = [_]types.Lexeme{
        before.organization.lexemes[0],
        .{ .language = "သွဳဒေန်", .kind = "Adverb", .section = 6, .definitions = &.{.{ .block = 1 }}, .introduction = &.{0} },
        before.organization.lexemes[1],
    };
    try std.testing.expectEqualDeep(types.Layout{ .lexemes = &wanted_lexemes, .other_sections = &.{ 0, 1, 2, 3, 5 } }, organization.value);
    var after: types.Stored = .{ .entry = before };
    after.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, after);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
    try std.testing.expectEqualDeep(after, decoded);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "FI exact noun heading preserves independently classified owner and all source addresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "isopihatatar" } };
    const body = try renderer.renderBody("'''isopihatatar'''\n# [[pihatatar|pihatattaren]] alalaji ''Polygonum aviculare'' subsp. ''aviculare''");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Suomi", .level = 2 },
        .{ .title = "Substantiivi", .level = 3, .blocks = body },
        .{ .title = "Käännökset", .level = 4 },
        .{ .title = "Aiheesta muualla", .level = 4 },
        .{ .title = "Viitteet", .level = 2 },
    };
    const layout = try buildOwned(a, &sections, "suomi");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("suomi", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expect(noun.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expect(noun.definitions[0].parent == null and noun.definitions[0].form == null);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].examples.len);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].quotations.len);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].notes.len);
    try std.testing.expectEqual(@as(usize, 0), noun.other_blocks.len);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, layout.other_sections);
    // A localized POS label never overrides the caller's classified language.
    const independent = try buildOwned(a, &sections, "Independent English");
    try std.testing.expectEqualStrings("Independent English", independent.lexemes[0].language);
    try std.testing.expectEqualStrings("Noun", independent.lexemes[0].kind);
    const unknown = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unknown.lexemes.len);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
    try std.testing.expectEqualStrings("Substantiivi", sections[1].title);
    try std.testing.expectEqualStrings("pihatatar", sections[1].blocks[1].spans[0].target);
}

test "FI noun label remains exact and cannot lexicalize protected text or unresolved language boundary" {
    for ([_][]const u8{ "substantiivi", "Substantiivit", "Substantiivi 2", " Substantiivi", "Substantiivi ", "Unknown Substantiivi" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const protected_body = try renderer.renderBody("<nowiki>===Substantiivi===</nowiki>\n# ordinary definition");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const protected_sections = [_]Section{.{ .title = "", .level = 0, .blocks = protected_body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &protected_sections, "suomi")).lexemes.len);
    const ambiguous_boundary = [_]Section{.{ .title = "Substantiivi", .level = 2, .blocks = &.{.{ .kind = .definition, .depth = 1, .list_path = "#" }} }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &ambiguous_boundary)).lexemes.len);
    const prose = [_]Section{.{ .title = "Aiheesta muualla", .level = 3, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "Substantiivi" }} }} }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &prose, "suomi")).lexemes.len);
}


test "direct-child font styles follow actual source parent and never a flattened class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = try @import("table_style_profile.zig").parseAlloc(a,
        "div.translations > dfn{font-weight:bold;font-style:normal}");
    defer profile.deinit();
    for ([_]struct { source: []const u8, bold: bool, italic: bool }{
        .{ .source = "<div class=translations><dfn>label</dfn></div>", .bold = true, .italic = false },
        .{ .source = "<div class=translations><span><dfn>label</dfn></span></div>", .bold = false, .italic = true },
        .{ .source = "<span class=translations><dfn>label</dfn></span>", .bold = false, .italic = true },
        .{ .source = "<div class=other><dfn>label</dfn></div>", .bold = false, .italic = true },
        .{ .source = "<div class=translations>before</div><dfn>label</dfn>", .bold = false, .italic = true },
        .{ .source = "<dfn class=translations>label</dfn>", .bold = false, .italic = true },
    }) |case| {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .table_styles = &profile } };
        const blocks = try renderer.renderBody(case.source);
        var found: usize = 0;
        for (blocks) |block| for (block.spans) |span| {
            if (!std.mem.eql(u8, span.text, "label")) continue;
            found += 1;
            try std.testing.expectEqual(case.bold, span.flags.bold);
            try std.testing.expectEqual(case.italic, span.flags.italic);
        };
        try std.testing.expectEqual(@as(usize, 1), found);
    }
}


test "FI exact pronoun heading preserves independent owner noun sibling and definition addresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Pronoun", partOfSpeech("Pronomini") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Substantiivi") orelse return error.TestUnexpectedResult);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const noun_blocks = try renderer.renderBody("noun headword\n# noun definition\n");
    const pronoun_blocks = try renderer.renderBody("<b>kulta</b>\n# [[kuka#Suomi|kuka]]\n# [[kuka#Suomi|kuka]]\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Suomi", .level = 2 },
        .{ .title = "Substantiivi", .level = 3, .blocks = noun_blocks },
        .{ .title = "Pronomini", .level = 3, .blocks = pronoun_blocks },
        .{ .title = "Inflection support", .level = 4 },
        .{ .title = "Unverified language boundary", .level = 2 },
        .{ .title = "Unrelated deep support", .level = 5 },
    };
    // These headings declare kinds only. A Finnish-edition heading may occur
    // in any independently classified record; neither heading replaces it.
    for ([_][]const u8{ "suomi", "kroatia", "English" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 2), layout.lexemes.len);
        const noun = layout.lexemes[0];
        const pronoun = layout.lexemes[1];
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqualStrings("Pronoun", pronoun.kind);
        for (layout.lexemes) |lexeme| try std.testing.expectEqualStrings(owner, lexeme.language);
        try std.testing.expectEqual(@as(usize, 1), noun.section);
        try std.testing.expectEqual(@as(usize, 2), pronoun.section);
        try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
        try std.testing.expectEqual(@as(usize, 2), pronoun.definitions.len);
        for (pronoun.definitions, 1..) |sense, block_index| {
            try std.testing.expectEqual(block_index, sense.block);
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
        }
        try std.testing.expectEqualSlices(usize, &.{0}, pronoun.introduction);
        try std.testing.expectEqualSlices(usize, &.{3}, pronoun.related_sections);
        try std.testing.expectEqualSlices(usize, &.{ 0, 4, 5 }, layout.other_sections);
    }
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 2), unresolved.lexemes.len);
    for (unresolved.lexemes) |lexeme| try std.testing.expectEqualStrings("", lexeme.language);
    try std.testing.expectEqualDeep(pronoun_blocks, sections[2].blocks);
}

test "FI pronoun label remains exact and cannot promote nonheading text or unresolved H2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "pronomini", "PRONOMINI", "Pronomini 2", "Pronomini?", " Pronomini", "Pronomini ", "Unknown Pronomini", "<nowiki>Pronomini</nowiki>" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const protected_blocks = try renderer.renderBody("Pronomini\n<nowiki>===Pronomini===</nowiki>\n<pre>===Pronomini===</pre>\n# retained body\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const nonheading = [_]Section{.{ .title = "Notes", .level = 3, .blocks = protected_blocks }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &nonheading, "independent-owner")).lexemes.len);
    const boundary = [_]Section{.{ .title = "Pronomini", .level = 2, .blocks = protected_blocks }};
    const unknown = try buildUnclassified(a, &boundary);
    try std.testing.expectEqual(@as(usize, 0), unknown.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, unknown.other_sections);
    try std.testing.expectEqualDeep(protected_blocks, boundary[0].blocks);
    try std.testing.expectEqualStrings("Pronoun", partOfSpeech("Pronoun") orelse return error.TestUnexpectedResult);
}

test "FI actual kulta Reader noun and pronoun organization preserves complete body styles actions media references and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    // Exact completed ordinary Reader output, not a new raw/expanded capture.
    // No source-parity or expansion/normal-loader acceptance is inferred here.
    const fixture = @embedFile("testdata/fi-kulta-reader/reader.suomi.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 624555), fixture.len);
    try std.testing.expectEqualStrings("b00be20b37cc55936e1738539fad8d5ad8108f6a5821fc8e8127385ae133cba2", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("kulta", before.title);
    try std.testing.expectEqualStrings("suomi", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("fi", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 12), before.sections.len);
    try std.testing.expectEqual(@as(usize, 1), before.references.len);
    try std.testing.expectEqual(@as(usize, 3), before.media.len);
    try std.testing.expectEqualStrings("Substantiivi", before.sections[1].title);
    try std.testing.expectEqualStrings("Pronomini", before.sections[11].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[11].level);
    try std.testing.expectEqual(@as(usize, 3), before.sections[11].blocks.len);
    // Project only the existing build-time analysis view. Every typed original
    // Entry field is retained below, including all nested tables and captions.
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 2), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("suomi", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 6), noun.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, noun.introduction);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 4, 5, 6, 7, 8, 9, 10 }, noun.related_sections);
    for (noun.definitions, 0..) |sense, index| {
        const block_index = 5 + 2 * index;
        try std.testing.expectEqual(block_index, sense.block);
        try std.testing.expect(sense.parent == null and sense.form == null);
        if (index < 5) try std.testing.expectEqualSlices(usize, &.{block_index + 1}, sense.examples) else
            try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
        try std.testing.expect(sense.quotations.len == 0 and sense.notes.len == 0);
    }
    const pronoun = layout.lexemes[1];
    try std.testing.expectEqualStrings("Pronoun", pronoun.kind);
    try std.testing.expectEqualStrings("suomi", pronoun.language);
    try std.testing.expectEqual(@as(usize, 11), pronoun.section);
    try std.testing.expect(pronoun.etymology == null);
    try std.testing.expectEqual(@as(usize, 2), pronoun.definitions.len);
    try std.testing.expectEqualSlices(usize, &.{0}, pronoun.introduction);
    try std.testing.expect(pronoun.other_blocks.len == 0 and pronoun.related_sections.len == 0);
    try std.testing.expectEqualSlices(usize, &.{0}, layout.other_sections);
    const body = before.sections[11].blocks;
    try std.testing.expectEqualStrings("kulta", body[0].spans[0].text);
    try std.testing.expect(body[0].spans[0].bold);
    const qualifiers = [_][]const u8{ "interrogatiivinen, taivutusmuoto, vanhahtava", "indefiniittinen, taivutusmuoto, vanhahtava" };
    for (pronoun.definitions, qualifiers, 1..) |sense, qualifier, block_index| {
        try std.testing.expectEqual(block_index, sense.block);
        try std.testing.expect(sense.parent == null and sense.form == null);
        try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
        const block = body[block_index];
        try std.testing.expect(block.kind == .definition);
        try std.testing.expectEqualStrings("#", block.list_path);
        try std.testing.expectEqual(@as(usize, 7), block.spans.len);
        try std.testing.expectEqualStrings(qualifier, block.spans[1].text);
        try std.testing.expect(block.spans[1].italic and !block.spans[1].bold);
        try std.testing.expectEqualStrings("yksikön ablatiivimuoto sanasta", block.spans[4].text);
        try std.testing.expect(block.spans[4].italic);
        const action = block.spans[6];
        try std.testing.expect(action.kind == .link and action.bold and !action.italic);
        try std.testing.expectEqualStrings("kuka", action.text);
        try std.testing.expectEqualStrings("kuka#Suomi", action.target);
        try std.testing.expectEqualStrings("fi", action.language);
    }
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "suomi", .code = "fi" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}


test "LT exact Daiktavardis heading supplies noun kind without language ownership" {
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Daiktavardis") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "daiktavardis", "DAIKTAVARDIS", "Daiktavardis 2", "Daiktavardžio", "<code>Daiktavardis</code>", "Daiktavardis ", " Daiktavardis" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const body = [_]wiki.Block{
        .{ .kind = .heading, .level = 3, .spans = &.{.{ .text = "Daiktavardis", .flags = .{ .italic = true } }} },
        .{ .kind = .paragraph, .spans = &.{.{ .text = "Ispanija", .flags = .{ .bold = true } }} },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &.{.{ .text = "valstybė" }} },
    };
    const sections = [_]Section{
        .{ .title = "independently observed language", .level = 2 },
        .{ .title = "Daiktavardis", .level = 3, .blocks = &body },
        .{ .title = "support", .level = 4 },
    };
    for ([_][]const u8{ "lietuvių", "another independently classified owner" }) |owner| {
        const result = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 1), result.lexemes.len);
        const noun = result.lexemes[0];
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqualStrings(owner, noun.language);
        try std.testing.expectEqual(@as(usize, 1), noun.section);
        try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
        try std.testing.expectEqual(@as(usize, 2), noun.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, noun.introduction);
        try std.testing.expectEqualSlices(usize, &.{2}, noun.related_sections);
        try std.testing.expectEqualSlices(usize, &.{0}, result.other_sections);
    }
    try std.testing.expect(body[0].spans[0].flags.italic and body[1].spans[0].flags.bold);
    try std.testing.expectEqualStrings("Daiktavardis", sections[1].title);
}

test "LT noun label in ordinary prose cannot classify or invent an unresolved H2 owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const prose = [_]Section{.{ .title = "Notes", .level = 3, .blocks = &.{
        .{ .kind = .paragraph, .spans = &.{.{ .text = "Daiktavardis", .flags = .{ .italic = true } }} },
        .{ .kind = .definition, .depth = 1, .list_path = "#", .spans = &.{.{ .text = "ordinary notes" }} },
    } }};
    const ordinary = try buildOwned(a, &prose, "record-owner");
    try std.testing.expectEqual(@as(usize, 0), ordinary.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, ordinary.other_sections);
    const unknown = [_]Section{.{ .title = "Daiktavardis", .level = 2, .blocks = prose[0].blocks }};
    const unclassified = try buildUnclassified(a, &unknown);
    try std.testing.expectEqual(@as(usize, 0), unclassified.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, unclassified.other_sections);
    const nested = [_]Section{.{ .title = "Daiktavardis", .level = 3, .blocks = prose[0].blocks }};
    const retained = try buildUnclassified(a, &nested);
    try std.testing.expectEqual(@as(usize, 1), retained.lexemes.len);
    try std.testing.expectEqualStrings("Noun", retained.lexemes[0].kind);
    try std.testing.expectEqualStrings("", retained.lexemes[0].language);
}

test "exact HY grammatical labels retain independent owner and related list domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const pairs = [_][2][]const u8{ .{ "Գոյական", "Noun" }, .{ "Ածական", "Adjective" }, .{ "Մակբայ", "Adverb" } };
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const lexical = try renderer.renderBody("'''head'''\n# [[sense]]\n#\n");
    const synonyms = try renderer.renderBody("# [[synonym]]\n");
    for (pairs) |pair| {
        try std.testing.expectEqualStrings(pair[1], partOfSpeech(pair[0]).?);
        const near = try std.fmt.allocPrint(a, "{s} 2", .{pair[0]});
        try std.testing.expect(partOfSpeech(near) == null);
        const sections = [_]Section{ .{ .title = "Authored language", .level = 1 }, .{ .title = pair[0], .level = 2, .blocks = lexical }, .{ .title = "Հոմանիշներ", .level = 4, .blocks = synonyms } };
        for ([_][]const u8{ "հայերեն", "Independent foreign owner" }) |owner| {
            const got = try buildOwned(a, &sections, owner);
            try std.testing.expectEqual(@as(usize, 1), got.lexemes.len);
            try std.testing.expectEqualStrings(owner, got.lexemes[0].language);
            try std.testing.expectEqualStrings(pair[1], got.lexemes[0].kind);
            try std.testing.expectEqual(@as(usize, 1), got.lexemes[0].section);
            try std.testing.expectEqualSlices(usize, &.{2}, got.lexemes[0].related_sections);
            // Existing empty-list policy is preserved; never reclassify related synonyms.
            try std.testing.expectEqual(@as(usize, 2), got.lexemes[0].definitions.len);
            try std.testing.expectEqual(@as(usize, 1), got.lexemes[0].definitions[0].block);
            try std.testing.expectEqual(@as(usize, 2), got.lexemes[0].definitions[1].block);
            try std.testing.expectEqualSlices(usize, &.{0}, got.lexemes[0].introduction);
            try std.testing.expectEqualSlices(usize, &.{0}, got.other_sections);
        }
        const unowned_sections = [_]Section{ .{ .title = pair[0], .level = 3, .blocks = lexical }, .{ .title = "Հոմանիշներ", .level = 4, .blocks = synonyms } };
        const unowned = try buildUnclassified(a, &unowned_sections);
        try std.testing.expectEqual(@as(usize, 1), unowned.lexemes.len);
        try std.testing.expectEqualStrings("", unowned.lexemes[0].language);
    }
    for ([_][]const u8{ "գոյական", "Ածական?", " Մակբայ", "Մակբայ ", "<nowiki>Գոյական</nowiki>", "հայերեն", "hy" }) |not_exact|
        try std.testing.expect(partOfSpeech(not_exact) == null);
}
test "retained HY homonyms gain only authored POS organization and preserve whole codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const reader_bytes = @embedFile("testdata/hy-pos/khghep-reader128.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(reader_bytes, &digest, .{});
    try std.testing.expectEqualStrings("dee53ccf315013efe8302254af64d10a2436da3d54490228531449352ec5d9d1", &std.fmt.bytesToHex(digest, .lower));
    const page = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, reader_bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), page.value.entries.len);
    const before = page.value.entries[0];
    try std.testing.expectEqualStrings("խեղեփ", before.title);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqualStrings("հայերեն", before.language.?);
    try std.testing.expectEqualStrings("hy", before.language_code);
    try std.testing.expectEqual(@as(usize, 14), before.sections.len);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualStrings("Գոյական", before.sections[3].title);
    try std.testing.expectEqualStrings("Ածական", before.sections[9].title);
    try std.testing.expectEqual(@as(usize, 3), before.sections[3].blocks.len);
    try std.testing.expectEqual(@as(usize, 2), before.sections[9].blocks.len);
    try std.testing.expect(before.sections[9].blocks[0].kind == .definition);
    try std.testing.expect(before.sections[9].blocks[1].kind == .paragraph);
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, reader_bytes, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // The build-only projection supplies block addresses and flags. The complete
    // independently parsed Reader Entry remains the body/error/style oracle.
    for (sections, before.sections) |*section, original_section| {
        const blocks = try a.dupe(wiki.Block, section.blocks);
        for (blocks, original_section.blocks) |*block, original_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            for (spans, original_block.spans) |*span, original_span| span.flags = .{
                .bold = original_span.bold, .italic = original_span.italic,
                .code = original_span.code, .small = original_span.small,
                .superscript = original_span.superscript, .subscript = original_span.subscript,
                .strike = original_span.strike, .underline = original_span.underline,
            };
            block.spans = spans;
        }
        section.blocks = blocks;
    }
    const layout = try buildOwned(a, sections, before.language.?);
    const layout_json = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, layout_json, .{});
    const wanted_lexemes = [_]types.Lexeme{
        .{ .language = "հայերեն", .kind = "Noun", .section = 3, .definitions = &.{ .{ .block = 0 }, .{ .block = 1 }, .{ .block = 2 } }, .related_sections = &.{ 4, 5, 6 } },
        .{ .language = "հայերեն", .kind = "Adjective", .section = 9, .definitions = &.{.{ .block = 0 }}, .other_blocks = &.{1}, .related_sections = &.{ 10, 11, 12 } },
    };
    try std.testing.expectEqualDeep(types.Layout{ .lexemes = &wanted_lexemes, .other_sections = &.{ 0, 1, 2, 7, 8, 13 } }, organization.value);
    var after: types.Stored = .{ .entry = before };
    after.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, after);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
    try std.testing.expectEqualDeep(after, decoded);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "exact Romanian etymology heading associates existing lexemes without assigning language or POS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = IsKyOrganizationTest.Section;
    const body = try IsKyOrganizationTest.body(a, "'''word'''\n# [[Meaning|meaning]]\n#: ''example''\n");
    const sections = [_]Section{
        .{ .title = "Independent owner", .level = 2 },
        .{ .title = "Etimologie", .level = 3 },
        .{ .title = "Pronunție", .level = 3 },
        .{ .title = "Substantiv", .level = 3, .blocks = body },
        .{ .title = "Etimologie", .level = 3 },
        .{ .title = "Substantiv", .level = 3, .blocks = body },
        .{ .title = "Later region", .level = 2 },
        .{ .title = "Substantiv", .level = 3, .blocks = body },
        .{ .title = "Etimologie", .level = 3 },
        .{ .title = "Root region", .level = 1 },
        .{ .title = "Substantiv", .level = 3, .blocks = body },
    };
    const owned = try buildOwned(a, &sections, "Independent French");
    const origins = [_]?usize{ 1, 4, null, null };
    try std.testing.expectEqual(origins.len, owned.lexemes.len);
    for (owned.lexemes, origins) |lexical, origin| {
        try std.testing.expectEqualStrings("Independent French", lexical.language);
        try std.testing.expectEqualStrings("Noun", lexical.kind);
        try std.testing.expectEqual(origin, lexical.etymology);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    }
    const unclassified = try buildUnclassified(a, &sections);
    for (unclassified.lexemes) |lexical| try std.testing.expectEqualStrings("", lexical.language);
    try std.testing.expect(partOfSpeech("Etimologie") == null);
    const support = [_]Section{ .{ .title = "Etimologie", .level = 3 }, .{ .title = "Unknown support", .level = 3, .blocks = body } };
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &support, "Independent French")).lexemes.len);
    for ([_][]const u8{ "etimologie", "ETIMOLOGIE", "Etimologie ", "Etimologie 1", "Etimologie note", "{{-etimologie-}}", "<nowiki>Etimologie</nowiki>" }) |heading| {
        const negative = [_]Section{ .{ .title = heading, .level = 3 }, .{ .title = "Substantiv", .level = 3, .blocks = body } };
        const layout = try buildOwned(a, &negative, "Independent French");
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        try std.testing.expect(layout.lexemes[0].etymology == null);
    }
    // Literal source in a body is never a section heading or an origin pointer.
    const protected_body = try IsKyOrganizationTest.body(a, "<nowiki>===Etimologie===</nowiki>\n<pre>===Etimologie===</pre>\nEtimologie\n");
    const literal = [_]Section{ .{ .title = "Unknown support", .level = 3, .blocks = protected_body }, .{ .title = "Substantiv", .level = 3, .blocks = body } };
    const literal_layout = try buildOwned(a, &literal, "Independent French");
    try std.testing.expectEqual(@as(usize, 1), literal_layout.lexemes.len);
    try std.testing.expect(literal_layout.lexemes[0].etymology == null);
}

test "actual RO83 casa complete Reader graph changes only two source authored etymology pointers through codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const source = @embedFile("testdata/ro-casa-etymology83/reader.json");
    var digest: [32]u8 = undefined;
    const raw = @embedFile("testdata/ro-casa-etymology83/page.raw.wikitext");
    const helper = @embedFile("testdata/ro-casa-etymology83/etymology-template.wikitext");
    std.crypto.hash.sha2.Sha256.hash(helper, &digest, .{});
    try std.testing.expectEqualStrings("522aa339d50626b96d4fa7ee8c959b78475bb9191df6d9e3920cdeb0505802e6", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqualStrings("<includeonly>__NOEDITSECTION__\n===Etimologie===</includeonly><noinclude>\n{{documentație}}\n</noinclude>", helper);
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    try std.testing.expectEqualStrings("38ea070097ee1026b33e25336d9611820d4c9a005cb61f13989f4065e9d2dc4d", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "{{-etimologie-}}"));
    try std.testing.expect(std.mem.indexOf(u8, raw, "{{-etimologie-}}\nDin latină ''[[casa]]''.") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "{{-etimologie-}}\nDin italiană ''[[cassa]]'', germană ''[[Kasse]]''.") != null);
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualStrings("d7086f12204989b8d122111342b81d86c398dfedc8cd9ba1ab101cab03ad8a0e", &std.fmt.bytesToHex(digest, .lower));
    const Typed = struct { entries: []const types.Entry };
    const typed = try std.json.parseFromSlice(Typed, a, source, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), typed.value.entries.len);
    const before = typed.value.entries[0];
    try std.testing.expectEqualStrings("casă", before.title);
    try std.testing.expectEqualStrings("română", before.language.?);
    try std.testing.expectEqualStrings("ro", before.language_code);
    try std.testing.expect(before.kind == .language);
    try std.testing.expectEqual(@as(usize, 20), before.sections.len);
    try std.testing.expectEqual(@as(usize, 2), before.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqual(@as(usize, 1), before.media.len);
    var table_count: usize = 0;
    for (before.sections) |section| for (section.blocks) |block| {
        if (block.table != null) table_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), table_count);
    const sections = try IsKyOrganizationTest.projected(a, source, before);
    const computed = try buildOwned(a, sections, before.language.?);
    const organization_json = try std.json.Stringify.valueAlloc(a, computed, .{});
    const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
    var expected: types.Stored = .{ .entry = before };
    const expected_lexemes = try a.dupe(types.Lexeme, before.organization.lexemes);
    expected.entry.organization.lexemes = expected_lexemes;
    const origins = [_]usize{ 2, 12 };
    const lexical_sections = [_]usize{ 4, 14 };
    const senses = [_]usize{ 10, 4 };
    var examples: usize = 0;
    for (expected_lexemes, origins, lexical_sections, senses) |*lexical, origin, lexical_section, sense_count| {
        try std.testing.expect(lexical.etymology == null);
        try std.testing.expectEqualStrings("română", lexical.language);
        try std.testing.expectEqualStrings("Noun", lexical.kind);
        try std.testing.expectEqual(lexical_section, lexical.section);
        try std.testing.expectEqual(sense_count, lexical.definitions.len);
        for (lexical.definitions) |definition| examples += definition.examples.len;
        try std.testing.expectEqualStrings("Etimologie", before.sections[origin].title);
        try std.testing.expectEqual(@as(u8, 3), before.sections[origin].level);
        lexical.etymology = origin;
    }
    try std.testing.expectEqual(@as(usize, 3), examples);
    try std.testing.expectEqualStrings("casa", before.sections[2].blocks[0].spans[1].target);
    try std.testing.expectEqualStrings("cassa", before.sections[12].blocks[0].spans[1].target);
    try std.testing.expectEqualStrings("Kasse", before.sections[12].blocks[0].spans[3].target);
    try std.testing.expect(before.sections[2].blocks[0].spans[1].italic);
    try std.testing.expect(before.sections[12].blocks[0].spans[1].italic);
    try std.testing.expect(before.sections[12].blocks[0].spans[3].italic);
    try std.testing.expectEqualDeep(expected.entry.organization, organization.value);
    var actual: types.Stored = .{ .entry = before };
    actual.entry.organization = organization.value;
    try std.testing.expectEqualDeep(expected, actual);
    const encoded = try encoder.presentation_codec.encodeAlloc(a, actual);
    try std.testing.expectEqualSlices(u8, try encoder.presentation_codec.encodeAlloc(a, expected), encoded);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualDeep(before.sections, decoded.entry.sections);
    try std.testing.expectEqualDeep(before.references, decoded.entry.references);
    try std.testing.expectEqualDeep(before.media, decoded.entry.media);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "current UK123 tomato typed self heading preserves complete entries and organization-only codec parity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block = &.{},
        anchor: []const u8 = "", anchor_fallback: []const u8 = "",
        is_heading: bool = false, title_depth: u8 = 0,
        title_list_path: []const u8 = "", title_spans: []const wiki.Span = &.{},
    };
    const Verify = struct {
        fn hash(bytes: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    try Verify.hash(@embedFile("testdata/uk-tomato/imen-en.xmlencoded.wikitext"), "afb87919c38f63b1b3579f5427aa8734cfc6893a7ec64310360197e48718c6c4");
    try Verify.hash(@embedFile("testdata/uk-tomato/imen-en-s.xmlencoded.wikitext"), "74bfaeb566087f6dbdc5f232fe3d4385349c378340d14ae8d12d434e3456a2ea");
    try Verify.hash(@embedFile("testdata/uk-tomato/imen-eo.xmlencoded.wikitext"), "7a21f8f7da976ce0ddc8ecb8f02b3888f09ece11cc764f11d41f57005088f99b");
    inline for (.{
        .{ @embedFile("testdata/uk-tomato/english-reader123.json"), "3a250492b52fba2156e80159ad98f016e189ce190027bac76ef73800e3f75065", "English", "en", @as(usize, 9), @as(usize, 1), @as(usize, 0) },
        .{ @embedFile("testdata/uk-tomato/esperanto-reader123.json"), "c42e29ba9bc919451b88e8161c6fe98fb48575866ff2666c17010043193b6419", "Esperanto", "eo", @as(usize, 13), @as(usize, 0), @as(usize, 1) },
    }) |case| {
        try Verify.hash(case[0], case[1]);
        const typed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, case[0], .{ .ignore_unknown_fields = true });
        const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, case[0], .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), typed.value.entries.len);
        const before = typed.value.entries[0];
        try std.testing.expectEqualStrings("tomato", before.title);
        try std.testing.expectEqualStrings(case[2], before.language.?);
        try std.testing.expectEqualStrings(case[3], before.language_code);
        try std.testing.expectEqual(case[6], before.organization.lexemes.len);
        try std.testing.expectEqual(case[4], before.sections.len);
        try std.testing.expectEqual(@as(usize, 4), before.references.len);
        const sections = try a.dupe(Section, projected.value.entries[0].sections);
        // Reader fields supply layout addresses only; never reserialize the
        // compiler projection as the source body. Live controls test provenance.
        for (sections, before.sections) |*section, original_section| {
            const blocks = try a.dupe(wiki.Block, section.blocks);
            for (blocks, original_section.blocks) |*block, original_block| {
                const spans = try a.dupe(wiki.Span, block.spans);
                for (spans, original_block.spans) |*span, original_span| span.flags = .{
                    .bold = original_span.bold, .italic = original_span.italic,
                    .code = original_span.code, .small = original_span.small,
                    .superscript = original_span.superscript, .subscript = original_span.subscript,
                    .strike = original_span.strike, .underline = original_span.underline,
                };
                block.spans = spans;
            }
            section.blocks = blocks;
            // Reader projections do not carry build-only provenance. This
            // reconstructs the observed self-heading identity only; separate
            // live source controls below establish its production origin.
            if (blocks.len != 0 and blocks[0].kind == .heading and blocks[0].level == section.level and
                std.mem.eql(u8, blocks[0].anchor, section.anchor)) {
                section.is_heading = true;
                section.title_depth = blocks[0].depth;
                section.title_list_path = blocks[0].list_path;
                section.title_spans = blocks[0].spans;
            }
        }
        const layout = try buildOwned(a, sections, case[2]);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        if (case[5] == 1) {
            const negative = try a.dupe(Section, sections);
            // Genuine current Meaning contains its own distinct heading and
            // definition. Neither is an empty Semantics companion.
            negative[3].blocks = sections[4].blocks;
            try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, negative, case[2])).lexemes.len);
            negative[3].blocks = sections[4].blocks[0..1];
            try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, negative, case[2])).lexemes.len);
            const substantive = try a.alloc(wiki.Block, 2);
            substantive[0] = sections[3].blocks[0];
            substantive[1] = sections[4].blocks[case[5]];
            negative[3].blocks = substantive;
            try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, negative, case[2])).lexemes.len);
        }
        const lexical = layout.lexemes[0];
        try std.testing.expectEqualStrings("Noun", lexical.kind);
        try std.testing.expectEqualStrings(case[2], lexical.language);
        try std.testing.expectEqual(@as(usize, 4), lexical.section);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(case[5], lexical.definitions[0].block);
        try std.testing.expect(lexical.etymology == null and lexical.definitions[0].parent == null and lexical.definitions[0].form == null);
        try std.testing.expectEqual(case[5], lexical.introduction.len);
        if (case[5] == 1) try std.testing.expectEqual(@as(usize, 0), lexical.introduction[0]);
        try std.testing.expectEqual(@as(usize, 0), lexical.related_sections.len);
        try std.testing.expectEqualSlices(usize, if (case[5] == 1) &.{ 2, 3, 4, 5 } else &.{ 1, 2, 3, 4 }, lexical.other_blocks);
        try std.testing.expectEqual(case[4] - 1, layout.other_sections.len);
        for (layout.other_sections, 0..) |section, i| try std.testing.expectEqual(if (i < 4) i else i + 1, section);
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
        const organization_json = try std.json.Stringify.valueAlloc(a, layout, .{});
        const organization = try std.json.parseFromSlice(types.Layout, a, organization_json, .{});
        if (case[6] == 1) try std.testing.expectEqualDeep(before.organization, organization.value);
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = organization.value;
        const payload = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, payload, before.title, before.kind, .{ .heading = case[2], .code = case[3] });
        try std.testing.expectEqualDeep(expected, decoded);
        var restored = decoded;
        restored.entry.organization = before.organization;
        // This includes every table cell and the unresolved Esperanto table
        // spill: an organization fix is not a table-fidelity waiver.
        try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
        try std.testing.expectEqualSlices(u8, payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}


test "UK semantics companion admits exact source identity and refuses body reference and foreign headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block = &.{},
        anchor: []const u8 = "", anchor_fallback: []const u8 = "",
        is_heading: bool = false, title_depth: u8 = 0,
        title_list_path: []const u8 = "", title_spans: []const wiki.Span = &.{},
    };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "control" } };
    const label = "Семантичні властивості";
    const title_spans = (try renderer.renderBody(label))[0].spans;
    const heading = wiki.Block{ .kind = .heading, .level = 4, .spans = title_spans,
        .anchor = "semantic", .anchor_fallback = "semantic" };
    const sections = [_]Section{
        .{ .title = "Морфосинтаксичні ознаки", .level = 3, .blocks = try renderer.renderBody("[[іменник|Іменник]].") },
        .{ .title = "Вимова", .level = 3 },
        .{ .title = label, .level = 4, .blocks = &.{heading}, .is_heading = true,
            .title_spans = title_spans, .anchor = "semantic", .anchor_fallback = "semantic" },
        .{ .title = "Значення", .level = 5, .blocks = try renderer.renderBody("# [[помідор]].") },
    };
    try std.testing.expectEqual(@as(usize, 1), (try buildOwned(a, &sections, "English")).lexemes.len);
    for (0..18) |case| {
        var negative = sections;
        var block = heading;
        const spans = try a.dupe(wiki.Span, title_spans);
        block.spans = spans;
        switch (case) {
            0 => block.kind = .paragraph,
            1 => block.depth = 1,
            2 => block.list_path = "*",
            3 => block.level = 3,
            4 => block.anchor = "other",
            5 => block.anchor_fallback = "other",
            6 => spans[0].text = "Other heading",
            7 => spans[0].kind = .link,
            8 => spans[0].target = "reference-1",
            9 => spans[0].role = .reference,
            10 => spans[0].flags.code = true,
            11 => spans[0].provenance = .protected_literal,
            12 => spans[0].generated_diagnostic = true,
            13 => negative[2].is_heading = false,
            14 => negative[2].title_depth = 1,
            15 => negative[2].title_list_path = "*",
            16 => negative[2].title_spans = (try renderer.renderBody("Other heading"))[0].spans,
            17 => spans[0].self_link = true,
            else => unreachable,
        }
        negative[2].blocks = &.{block};
        errdefer std.debug.print("UK typed companion negative={d}\n", .{case});
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "English")).lexemes.len);
    }
    for ([_][]const u8{ "Substantive body", "# [[definition]]", "[[reference|Семантичні властивості]]", "<nowiki>Семантичні властивості</nowiki>" }) |body| {
        var negative = sections;
        const body_blocks = try renderer.renderBody(body);
        const blocks = try a.alloc(wiki.Block, body_blocks.len + 1);
        blocks[0] = heading;
        @memcpy(blocks[1..], body_blocks);
        negative[2].blocks = blocks;
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &negative, "English")).lexemes.len);
    }
    var missing_wrapper = sections;
    missing_wrapper[2].title = "Other";
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &missing_wrapper, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try build(a, &sections)).lexemes.len);
}

test "UK source styled semantics companion reaches normal layout without changing stored body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const source = "= English =\n=== Морфосинтаксичні ознаки ===\n[[іменник|Іменник]].\n=== Вимова ===\n"
        ++ "<h4 style=\"font-size:100%\">Семантичні властивості</h4>\n"
        ++ "<h5 style=\"font-size:100%\">Значення</h5>\n# [[помідор]].\n";
    const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
        a, "control", .language, "English", "en", document.MissingText.untracked(source),
        null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
        .{ .heading = "English", .code = "en" },
    );
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, "control", .language, .{ .heading = "English", .code = "en" });
    const entry = decoded.entry;
    try std.testing.expectEqual(@as(usize, 5), entry.sections.len);
    try std.testing.expectEqual(@as(usize, 1), entry.sections[3].blocks.len);
    try std.testing.expect(entry.sections[3].blocks[0].kind == .heading);
    try std.testing.expectEqualStrings(entry.sections[3].anchor, entry.sections[3].blocks[0].anchor);
    try std.testing.expectEqualStrings(entry.sections[3].anchor_fallback, entry.sections[3].blocks[0].anchor_fallback);
    try std.testing.expectEqualStrings("Семантичні властивості", entry.sections[3].blocks[0].spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), entry.organization.lexemes.len);
    const lexical = entry.organization.lexemes[0];
    try std.testing.expectEqualStrings("English", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 4), lexical.section);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expect(entry.sections[4].blocks[0].kind == .heading);
    try std.testing.expect(entry.sections[4].blocks[1].kind == .definition);
    try std.testing.expectEqualStrings("помідор", entry.sections[4].blocks[1].spans[0].target);
    const encoded = try encoder.presentation_codec.encodeAlloc(a, decoded);
    try std.testing.expectEqualSlices(u8, bytes, encoded);
    try std.testing.expectEqualDeep(decoded, try encoder.presentation_codec.decodeAlloc(a, encoded, "control", .language, .{ .heading = "English", .code = "en" }));
}


test "exact Galician feminine noun heading keeps independent owner and support definitions" {
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const body = [_]wiki.Block{ .{ .kind = .paragraph }, .{ .kind = .definition, .list_path = "#" }, .{ .kind = .quotation, .list_path = "#*" } };
    const support = [_]wiki.Block{ .{ .kind = .definition, .list_path = "#" }, .{ .kind = .definition, .list_path = "#" } };
    const sections = [_]Section{ .{ .title = "English", .level = 1 }, .{ .title = "Substantivo feminino", .level = 3, .blocks = &body }, .{ .title = "Observacións", .level = 4, .blocks = &support }, .{ .title = "Termos relacionados", .level = 4 } };
    const layout = try buildOwned(a, &sections, "en");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, noun.definitions[0].quotations);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, noun.related_sections);
    for ([_][]const u8{ "substantivo feminino", "Substantivo feminino 2", "Substantivo feminino notes", "Substantivo", "Observacións" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    const unresolved = [_]Section{ .{ .title = "Substantivo feminino", .level = 2, .blocks = &body } };
    const unknown = try buildUnclassified(a, &unresolved);
    try std.testing.expectEqual(@as(usize, 0), unknown.lexemes.len);
}

test "Persian noun organization requires owned parsed H3 and direct definition while preserving complete body codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const F = struct {
        fn compile(allocator: A, source: []const u8, owner: ?[]const u8) !encoder.presentation_types.Stored {
            const label = owner orelse "Unclassified";
            const code: []const u8 = if (std.mem.eql(u8, label, "فارسی") or std.mem.eql(u8, label, "Persian")) "fa" else if (std.mem.eql(u8, label, "اردو")) "ur" else if (std.mem.eql(u8, label, "French")) "fr" else "";
            const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
                allocator, "control", .language, label, code, document.MissingText.untracked(source),
                null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
                if (code.len != 0) .{ .heading = label, .code = code } else null,
            );
            const decoded = try encoder.presentation_codec.decodeAlloc(allocator, bytes, "control", .language, .{ .heading = label, .code = code });
            try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(allocator, decoded));
            return decoded;
        }
    };
    const senses = "# First [[meaning|label]].\n# Second meaning.\n# Third meaning.\n";
    const tail = "==== برگردان‌ها ====\n* [[accounting]]\n";
    const source = "== فارسی ==\nحِسابداری\n=== اسم ===\n" ++ senses ++ tail;
    for ([_][]const u8{ "فارسی", "Persian" }) |owner| {
        const actual = try F.compile(a, source, owner);
        const layout = actual.entry.organization;
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const noun = layout.lexemes[0];
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqualStrings(owner, noun.language);
        try std.testing.expectEqual(@as(usize, 1), noun.section);
        try std.testing.expectEqual(@as(usize, 3), noun.definitions.len);
        for (noun.definitions, 0..) |definition, index| try std.testing.expectEqual(index, definition.block);
        try std.testing.expectEqual(@as(usize, 0), noun.introduction.len);
        // The independent standard noun heading changes only title and anchors.
        // Restore those explicit reference differences, then compare every field.
        var reference = try F.compile(a, "== فارسی ==\nحِسابداری\n=== Noun ===\n" ++ senses ++ tail, owner);
        const sections = try a.dupe(encoder.presentation_types.Section, reference.entry.sections);
        reference.entry.sections = sections;
        sections[1].title = actual.entry.sections[1].title;
        sections[1].anchor = actual.entry.sections[1].anchor;
        sections[1].anchor_fallback = actual.entry.sections[1].anchor_fallback;
        try std.testing.expectEqualDeep(reference, actual);
        try std.testing.expectEqualSlices(u8, try encoder.presentation_codec.encodeAlloc(a, reference), try encoder.presentation_codec.encodeAlloc(a, actual));
    }
    for ([_]?[]const u8{ null, "", "French", "اردو", "Unclassified", "persian", "Persian " }) |owner|
        try std.testing.expectEqual(@as(usize, 0), (try F.compile(a, source, owner)).entry.organization.lexemes.len);
    for ([_][]const u8{
        "=== <nowiki>اسم</nowiki> ===\n" ++ senses,
        "=== <code>اسم</code> ===\n" ++ senses,
        "=== [[اسم]] ===\n" ++ senses,
        "==== اسم ====\n" ++ senses,
        "=== اسم‌ها ===\n" ++ senses,
        "<h3>\n:اسم</h3>\n" ++ senses,
        "=== اسم ===\nSupport paragraph.\n" ++ senses,
        "=== اسم ===\n==== Other ====\n" ++ senses,
        "=== اسم ===\n* Not a definition.\n",
        "=== اسم ===\n## Nested definition.\n",
        "=== اسم ===\n# <nowiki>protected meaning</nowiki>\n",
        "=== اسم ===\n# <code>code meaning</code>\n",
    }) |negative| {
        for ([_][]const u8{ "فارسی", "Persian" }) |owner|
            try std.testing.expectEqual(@as(usize, 0), (try F.compile(a, try std.fmt.allocPrint(a, "== فارسی ==\n{s}", .{negative}), owner)).entry.organization.lexemes.len);
    }
    try std.testing.expect(partOfSpeech("اسم") == null);
}

test "retained ID headword terms preserve definition request and independent noun senses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try @import("namespace_registry").Registry.init(a, @embedFile("id-rampai129-namespace.tsv")); defer ns.deinit();
    try ns.attachInterwikiMap(@embedFile("id-rampai129-interwiki.tsv"));
    const source = @embedFile("id-rampai129-expanded.wikitext");
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "rampai", .namespace_catalog = &ns } };
    const blocks = try renderer.renderBody(source);
    var owners: usize = 0;
    for (blocks, 0..) |block, start| {
        if (block.kind != .heading or block.level != 3) continue;
        var end = start + 1;
        while (end < blocks.len and !(blocks[end].kind == .heading and blocks[end].level <= 3)) : (end += 1) {}
        const owned = blocks[start..end];
        const marker = idTermParagraphPart(owned, "Independent supplied owner", 3) orelse return error.MissingIdTermPos;
        const lexical = try analyzeMarkedParagraph(a, marker, 1, null, owned);
        try std.testing.expectEqualStrings(if (owners == 0) "Adjective" else "Noun", lexical.kind);
        try std.testing.expectEqual(@as(usize, if (owners == 0) 0 else 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), lexical.section);
        try std.testing.expect(lexical.etymology == null);
        if (owners == 0) {
            try std.testing.expect(idDefinitionRequest(owned[marker.first]));
            try std.testing.expectEqual(marker.first + 1, lexical.introduction.len);
            try std.testing.expectEqual(marker.end, lexical.other_blocks[0]);
            try std.testing.expect(owned[marker.end].kind == .term);
            try std.testing.expectEqualStrings("Terjemahan", owned[marker.end].spans[1].text);
            // The authored numbered instruction remains intact in the body.
            try std.testing.expect(owned[marker.first].kind == .definition);
            try std.testing.expectEqualStrings("#", owned[marker.first].list_path);
        } else {
            try std.testing.expectEqual(marker.first, lexical.definitions[0].block);
            try std.testing.expect(lexical.definitions[0].parent == null);
            try std.testing.expectEqual(@as(usize, 0), lexical.definitions[0].examples.len);
            if (owners == 1) try std.testing.expectEqualStrings("pakaian", owned[marker.first].spans[0].target);
        }
        for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
            try std.testing.expect(idTermParagraphPart(owned, owner, 3) == null);
        try std.testing.expect(idTermParagraphPart(owned, "Independent supplied owner", 2) == null);
        const changed = try a.dupe(wiki.Block, owned);
        changed[0].kind = .paragraph;
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        changed[0] = owned[0];
        changed[marker.first - 1].kind = .paragraph;
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        changed[marker.first - 1] = owned[marker.first - 1];
        const spans = try a.dupe(wiki.Span, changed[marker.first - 1].spans);
        changed[marker.first - 1].spans = spans;
        var label_index: ?usize = null;
        for (spans, 0..) |span, i| if (span.image == null and !idTermSpace(span)) { label_index = i; break; };
        const label = label_index orelse return error.MissingIdTermLabel;
        spans[label].provenance = .protected_literal;
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        spans[label] = owned[marker.first - 1].spans[label];
        spans[label].generated_diagnostic = true;
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        spans[label] = owned[marker.first - 1].spans[label];
        spans[label].text = "Unrelated";
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        spans[label] = owned[marker.first - 1].spans[label];
        changed[marker.first - 1].depth = 2;
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        changed[marker.first - 1] = owned[marker.first - 1];
        const icon_spans = try a.dupe(wiki.Span, owned[marker.first - 1].spans);
        var icon = icon_spans[0].image orelse return error.MissingIdTermIcon;
        icon.file = "unrelated.svg"; icon_spans[0].image = icon;
        changed[marker.first - 1].spans = icon_spans;
        try std.testing.expect(idTermParagraphPart(changed, "Independent supplied owner", 3) == null);
        if (owners == 0) {
            const noun_sense = for (blocks) |candidate| {
                if (candidate.kind == .definition and candidate.spans.len == 1 and
                    std.mem.eql(u8, candidate.spans[0].target, "pakaian")) break candidate;
            } else return error.MissingRetainedNounSense;
            const ordinary = try a.dupe(wiki.Block, owned);
            ordinary[marker.first] = noun_sense;
            const ordinary_marker = idTermParagraphPart(ordinary, "Independent supplied owner", 3).?;
            const ordinary_lexeme = try analyzeMarkedParagraph(a, ordinary_marker, 1, null, ordinary);
            try std.testing.expectEqualStrings("Adjective", ordinary_lexeme.kind);
            try std.testing.expectEqual(@as(usize, 1), ordinary_lexeme.definitions.len);
            try std.testing.expectEqual(marker.first, ordinary_lexeme.definitions[0].block);
            // A real # definition after the translation marker stays supporting
            // material; it cannot become the preceding adjective's meaning.
            const support = try a.alloc(wiki.Block, owned.len + 1);
            @memcpy(support[0..owned.len], owned); support[owned.len] = noun_sense;
            const support_marker = idTermParagraphPart(support, "Independent supplied owner", 3).?;
            const support_lexeme = try analyzeMarkedParagraph(a, support_marker, 1, null, support);
            try std.testing.expectEqual(@as(usize, 0), support_lexeme.definitions.len);
            try std.testing.expectEqual(owned.len, support_lexeme.other_blocks[support_lexeme.other_blocks.len - 1]);
            const damaged = try a.dupe(wiki.Block, owned);
            const instruction = try a.dupe(wiki.Span, damaged[marker.first].spans);
            instruction[7].text = "[malformed template]"; instruction[7].generated_diagnostic = true;
            damaged[marker.first].spans = instruction;
            try std.testing.expect(idTermParagraphPart(damaged, "Independent supplied owner", 3) == null);
        }
        owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), owners);
    try std.testing.expect(partOfSpeech("Nomina") == null);
    try std.testing.expect(partOfSpeech("Adjektiva") == null);
}

const TeGrammarScopeFixture = struct {
    const grammar = ";భాషాభాగం:\n*[[క్రియ]].\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n";
    const meaning = "#[[చుట్టుముట్టు]]\n# ఉదా:  ఆకోట ముట్టడికై సైన్యాలు ప్రయత్నించాయి.\n";
    const Section = struct {
        title: []const u8, level: u8 = 2, blocks: []const wiki.Block,
        is_heading: bool, title_depth: u8, title_list_path: []const u8, title_spans: []const wiki.Span,
    };
    fn section(a: A, title: []const u8, body: []const u8) !Section {
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "ముట్టడి" } };
        const headings = try renderer.renderBody(try std.mem.concat(a, u8, &.{ "==", title, "==\n" }));
        try std.testing.expectEqual(@as(usize, 1), headings.len);
        try std.testing.expect(headings[0].kind == .heading and headings[0].level == 2);
        return .{ .title = title, .blocks = try renderer.renderBody(body), .is_heading = true,
            .title_depth = headings[0].depth, .title_list_path = headings[0].list_path, .title_spans = headings[0].spans };
    }
    fn sections(a: A) ![5]Section {
        return .{
            try section(a, "వ్యాకరణ విశేషాలు", grammar),
            try section(a, "అర్థ వివరణ", meaning),
            try section(a, "పదాలు", ";నానార్థాలు:\n\n;సంబంధిత పదాలు:\n;వ్యతిరేక పదాలు:\n"),
            try section(a, "పద ప్రయోగాలు", ""),
            try section(a, "అనువాదాలు", "[[siege]]"),
        };
    }
};

test "TE parsed grammar role joins only its adjacent numbered meanings under an independent owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const sections = try TeGrammarScopeFixture.sections(a);
    try std.testing.expectEqualStrings("Verb", teluguGrammarMeaningPart(&sections, 1, "Independent owner").?);
    const actual = try buildOwned(a, &sections, "Independent owner");
    const senses = [_]Sense{ .{ .block = 0 }, .{ .block = 1 } };
    const lexemes = [_]Lexeme{.{ .kind = "Verb", .language = "Independent owner", .section = 1,
        .definitions = &senses, .introduction = &.{}, .other_blocks = &.{} }};
    try std.testing.expectEqualDeep(Layout{ .lexemes = &lexemes, .other_sections = &.{ 0, 2, 3, 4 } }, actual);
    try std.testing.expectEqualStrings("ఉదా:  ఆకోట ముట్టడికై సైన్యాలు ప్రయత్నించాయి.", sections[1].blocks[1].spans[0].text);
    try std.testing.expectEqualStrings("#", sections[1].blocks[1].list_path);
    try std.testing.expectEqualStrings("2", sections[1].blocks[1].number);
    try std.testing.expectEqual(@as(usize, 0), actual.lexemes[0].definitions[1].examples.len);
    try std.testing.expectEqual(@as(usize, 0), actual.lexemes[0].definitions[1].quotations.len);
    try std.testing.expect(partOfSpeech("క్రియ") == null);
}

test "TE grammar role refuses copied protected nested conflicting and unrelated heading evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const original = try TeGrammarScopeFixture.sections(a);
    for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
        try std.testing.expect(teluguGrammarMeaningPart(&original, 1, owner) == null);
    for ([_][]const u8{
        ";భాషాభాగం:\n*[[Other|క్రియ]].\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n",
        ";భాషాభాగం:\n*<nowiki>[[క్రియ]]</nowiki>.\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n",
        ";భాషాభాగం:\n**[[క్రియ]].\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n",
        ";భాషాభాగం:\n*[[క్రియ]].\n*[[నామవాచకం]].\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n",
        ";Other:\n*[[క్రియ]].\n\n;వ్యుత్పత్తి:\n\n;బహువచనం లేక ఏక వచనం:\n",
        ";భాషాభాగం:\n*[[క్రియ]].\n\n;వ్యుత్పత్తి: supplied\n\n;బహువచనం లేక ఏక వచనం:\n",
        "The word [[క్రియ]] appears in ordinary prose.",
    }) |body| {
        errdefer std.debug.print("TE grammar negative body={s}\n", .{body});
        var sections = original; sections[0] = try TeGrammarScopeFixture.section(a, "వ్యాకరణ విశేషాలు", body);
        try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
        try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, "Independent owner")).lexemes.len);
    }
    var sections = original; sections[0].title = "Other heading";
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    sections = original; sections[1].title = "Unrelated meanings";
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    sections = original; sections[0].level = 3;
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    sections = original; sections[0].title_depth = 1; sections[0].title_list_path = "*";
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    sections = original; sections[1].is_heading = false;
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    sections = original; sections[0].title_spans = original[1].title_spans;
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    const title_spans = try a.dupe(wiki.Span, original[0].title_spans);
    title_spans[0].provenance = .protected_literal;
    sections = original; sections[0].title_spans = title_spans;
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    const blocks = try a.dupe(wiki.Block, original[0].blocks);
    const marker = try a.dupe(wiki.Span, blocks[2].spans);
    marker[0].generated_diagnostic = true; blocks[2].spans = marker;
    sections = original; sections[0].blocks = blocks;
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    sections = original; sections[1] = try TeGrammarScopeFixture.section(a, "అర్థ వివరణ", "Ordinary prose, no authored sense.");
    try std.testing.expect(teluguGrammarMeaningPart(&sections, 1, "Independent owner") == null);
    const separated = [_]TeGrammarScopeFixture.Section{ original[0], original[2], original[1] };
    try std.testing.expect(teluguGrammarMeaningPart(&separated, 2, "Independent owner") == null);
}


test "MS exact Kata kerja heading supplies verb kind without changing independent language ownership" {
    try std.testing.expectEqualStrings("Verb", partOfSpeech("Kata kerja") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "kata kerja", "KATA KERJA", "Kata kerja 2", "Kata kerja?", " Kata kerja", "Kata kerja ", "<nowiki>Kata kerja</nowiki>", "Kata nama" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("<b>retained headword</b>\n# [[ganti]], [[tukar]]\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "Bahasa Jepun", .level = 2 },
        .{ .title = "Kata kerja", .level = 3, .blocks = body },
        .{ .title = "Nested support", .level = 4 },
        .{ .title = "Etimologi", .level = 3 },
    };
    // The edition's label declares a kind. It cannot replace the entry's owner.
    for ([_][]const u8{ "Jepun", "Bahasa Melayu", "independent-owner" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const verb = layout.lexemes[0];
        try std.testing.expectEqualStrings("Verb", verb.kind);
        try std.testing.expectEqualStrings(owner, verb.language);
        try std.testing.expectEqual(@as(usize, 1), verb.section);
        try std.testing.expect(verb.etymology == null);
        try std.testing.expectEqual(@as(usize, 1), verb.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), verb.definitions[0].block);
        try std.testing.expect(verb.definitions[0].parent == null and verb.definitions[0].form == null);
        try std.testing.expect(verb.definitions[0].examples.len == 0 and verb.definitions[0].quotations.len == 0 and verb.definitions[0].notes.len == 0);
        try std.testing.expectEqualSlices(usize, &.{0}, verb.introduction);
        try std.testing.expectEqual(@as(usize, 0), verb.other_blocks.len);
        try std.testing.expectEqualSlices(usize, &.{2}, verb.related_sections);
        try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    }
    try std.testing.expect(body[0].spans[0].flags.bold);
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    const boundary = [_]Section{.{ .title = "Kata kerja", .level = 2, .blocks = body }};
    const unknown = try buildUnclassified(a, &boundary);
    try std.testing.expectEqual(@as(usize, 0), unknown.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, unknown.other_sections);
    const prose = try renderer.renderBody("Kata kerja\n<nowiki>===Kata kerja===</nowiki>\n<pre>===Kata kerja===</pre>\n# ordinary notes\n");
    const ordinary = [_]Section{.{ .title = "Notes", .level = 3, .blocks = prose }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &ordinary, "Jepun")).lexemes.len);
    try std.testing.expectEqualStrings("Verb", partOfSpeech("Verb") orelse return error.TestUnexpectedResult);
}

test "MS actual kaeru Reader verb organization preserves complete Japanese body actions tables named references styles and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    // Exact completed MS146 Reader record. This changes organization only,
    // and does not imply a new expansion, producer run, or frontend acceptance.
    const fixture = @embedFile("testdata/ms-kaeru-reader146/reader.ja.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 299491), fixture.len);
    try std.testing.expectEqualStrings("ede3f721c256c40bf81af35815bf6658601b7403d2711fb028da190905932fdb", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, fixture, "\xef\xbf\xbd"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fixture, "替えん"));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("替える", before.title);
    try std.testing.expectEqualStrings("Jepun", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("ja", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5, 6 }, before.organization.other_sections);
    const headings = [_][]const u8{ "Bahasa Jepun", "Kata kerja", "Etimologi", "Sebutan", "Konjugasi", "Kata berkaitan", "Rujukan" };
    const block_counts = [_]usize{ 0, 3, 5, 2, 2, 1, 0 };
    try std.testing.expectEqual(headings.len, before.sections.len);
    for (before.sections, headings, block_counts, 0..) |section, heading, block_count, index| {
        try std.testing.expectEqualStrings(heading, section.title);
        try std.testing.expectEqual(@as(u8, if (index == 0) 2 else 3), section.level);
        try std.testing.expectEqual(block_count, section.blocks.len);
    }
    try std.testing.expectEqual(@as(usize, 0), before.media.len);
    try std.testing.expectEqual(@as(usize, 2), before.references.len);
    for (before.references, [_][]const u8{ "SMK2", "NHK" }, 1..) |reference, name, number| {
        try std.testing.expectEqualStrings(name, reference.name);
        try std.testing.expectEqual(number, reference.number);
    }
    // Project the same build-time analysis view as the existing complete FI
    // Reader regression. Preserve every original typed field for the codec.
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const verb = layout.lexemes[0];
    try std.testing.expectEqualStrings("Verb", verb.kind);
    try std.testing.expectEqualStrings("Jepun", verb.language);
    try std.testing.expectEqual(@as(usize, 1), verb.section);
    try std.testing.expect(verb.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, verb.introduction);
    try std.testing.expect(verb.other_blocks.len == 0 and verb.related_sections.len == 0);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3, 4, 5, 6 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), verb.definitions.len);
    const sense = verb.definitions[0];
    try std.testing.expectEqual(@as(usize, 2), sense.block);
    try std.testing.expect(sense.parent == null and sense.form == null);
    try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
    const definition = before.sections[verb.section].blocks[sense.block];
    try std.testing.expect(definition.kind == .definition and definition.depth == 1);
    try std.testing.expectEqualStrings("#", definition.list_path);
    try std.testing.expectEqualStrings("1", definition.number);
    try std.testing.expectEqual(@as(usize, 3), definition.spans.len);
    for ([_]usize{ 0, 2 }, [_][]const u8{ "ganti", "tukar" }) |index, term| {
        const span = definition.spans[index];
        try std.testing.expect(span.kind == .link and !span.bold and !span.italic);
        try std.testing.expectEqualStrings(term, span.text);
        try std.testing.expectEqualStrings(term, span.target);
    }
    try std.testing.expect(definition.spans[1].kind == .text and definition.spans[1].target.len == 0);
    try std.testing.expectEqualStrings(", ", definition.spans[1].text);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "Jepun", .code = "ja" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Includes every action/style in all three tables, both named references,
    // the repaired literal tail, and the separate source-present Wikibase error.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}


test "AZ exact Herf letter heading supplies existing kind without language ownership" {
    try std.testing.expectEqualStrings("Letter", partOfSpeech("Hərf") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "hərf", "HƏRF", "Hərflər", "Hərf 2", "Hərf?", " Hərf", "Hərf ", "<nowiki>Hərf</nowiki>" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("<b>retained letter</b>\n# alphabet use\n# numeric use\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]Section{
        .{ .title = "unverified language label", .level = 2 },
        .{ .title = "Hərf", .level = 3, .blocks = body },
        .{ .title = "Nested support", .level = 4 },
        .{ .title = "İstinad", .level = 3 },
    };
    for ([_][]const u8{ "independent-owner", "Aghwan" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const letter = layout.lexemes[0];
        try std.testing.expectEqualStrings("Letter", letter.kind);
        try std.testing.expectEqualStrings(owner, letter.language);
        try std.testing.expectEqual(@as(usize, 1), letter.section);
        try std.testing.expect(letter.etymology == null);
        try std.testing.expectEqualSlices(usize, &.{0}, letter.introduction);
        try std.testing.expectEqual(@as(usize, 2), letter.definitions.len);
        for (letter.definitions, 1..) |sense, block_index| {
            try std.testing.expectEqual(block_index, sense.block);
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
        }
        try std.testing.expectEqual(@as(usize, 0), letter.other_blocks.len);
        try std.testing.expectEqualSlices(usize, &.{2}, letter.related_sections);
        try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    }
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqualStrings("Letter", unresolved.lexemes[0].kind);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    const boundary = [_]Section{.{ .title = "Hərf", .level = 2, .blocks = body }};
    const unknown = try buildUnclassified(a, &boundary);
    try std.testing.expectEqual(@as(usize, 0), unknown.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, unknown.other_sections);
    const prose = try renderer.renderBody("Hərf\n<nowiki>===Hərf===</nowiki>\n<pre>===Hərf===</pre>\n# ordinary notes\n");
    const ordinary = [_]Section{.{ .title = "Notes", .level = 3, .blocks = prose }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &ordinary, "independent-owner")).lexemes.len);
    try std.testing.expectEqualStrings("Letter", partOfSpeech("Letter") orelse return error.TestUnexpectedResult);
}

test "AZ four actual Reader letter organizations preserve unresolved ownership complete bodies images actions styles and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const fixtures = .{
        .{ @embedFile("testdata/az-letter-reader145/reader-01.json"), "7bf209520c0d915f6c839fb0749a0c99320096252a0f08426338d3d72bc3bbec", "𐔰", "birinci", "ALT" },
        .{ @embedFile("testdata/az-letter-reader145/reader-02.json"), "9e94ae74c62cd9513181c18c98d7f76fa72c563e662ba816ee916536b3af3c2b", "𐔱", "ikinci", "BET" },
        .{ @embedFile("testdata/az-letter-reader145/reader-03.json"), "07fb0d3a87d1e41f479e1ae70ac6a883adf67b3c463edc2f172c4b0df51dc64b", "𐔲", "üçüncü", "GIM" },
        .{ @embedFile("testdata/az-letter-reader145/reader-04.json"), "21c57f72adca01ad655af1511d97d488331c342a1c486c14245a61b39c0b12cd", "𐔳", "dördüncü", "DAT" },
    };
    inline for (fixtures) |case| {
        const fixture = case[0];
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
        try std.testing.expectEqualStrings(case[1], &std.fmt.bytesToHex(digest, .lower));
        const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
        const before = parsed.value.entries[0];
        try std.testing.expectEqualStrings(case[2], before.title);
        try std.testing.expectEqualStrings("Unclassified", before.language orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualStrings("", before.language_code);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, before.organization.other_sections);
        const headings = [_][]const u8{ "Qafqaz albanlarının dili", "Tələffüz", "Hərf", "İstinad" };
        const block_counts = [_]usize{ 2, 1, 3, 1 };
        try std.testing.expectEqual(headings.len, before.sections.len);
        for (before.sections, headings, block_counts, 0..) |section, heading, block_count, index| {
            try std.testing.expectEqualStrings(heading, section.title);
            try std.testing.expectEqual(@as(u8, if (index == 0) 2 else 3), section.level);
            try std.testing.expectEqual(block_count, section.blocks.len);
        }
        try std.testing.expectEqual(@as(usize, 0), before.references.len);
        try std.testing.expectEqual(@as(usize, 1), before.media.len);
        try std.testing.expectEqualStrings("CAUCASIAN ALBANIAN LETTER " ++ case[4] ++ ".svg", before.media[0].file);
        try std.testing.expectEqualStrings("{{{uc}}}", before.media[0].caption);
        const Section = struct {
            title: []const u8, level: u8, blocks: []const wiki.Block,
            is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
            title_spans: []const wiki.Span = &.{},
        };
        const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
        const sections = try a.dupe(Section, projected.value.entries[0].sections);
        for (sections, before.sections) |*section, typed_section| {
            section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
            const blocks = try a.dupe(wiki.Block, section.blocks);
            section.blocks = blocks;
            for (blocks, typed_section.blocks) |*block, typed_block| {
                const spans = try a.dupe(wiki.Span, block.spans);
                block.spans = spans;
                for (spans, typed_block.spans) |*span, typed_span| {
                    span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                        .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                        .strike = typed_span.strike, .underline = typed_span.underline };
                }
            }
        }
        // Current actual ownership remains unresolved. Inline lang=xag and
        // this POS label cannot grant the separate template/provider authority.
        const layout = try buildUnclassified(a, sections);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const letter = layout.lexemes[0];
        try std.testing.expectEqualStrings("Letter", letter.kind);
        try std.testing.expectEqualStrings("", letter.language);
        try std.testing.expectEqual(@as(usize, 2), letter.section);
        try std.testing.expect(letter.etymology == null);
        try std.testing.expectEqualSlices(usize, &.{0}, letter.introduction);
        try std.testing.expect(letter.other_blocks.len == 0 and letter.related_sections.len == 0);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, layout.other_sections);
        try std.testing.expectEqual(@as(usize, 2), letter.definitions.len);
        const definitions = [_][]const u8{
            "Qafqaz albanlarının əlifbasının " ++ case[3] ++ " hərfi.",
            "Alban ədəd sisteminin " ++ case[3] ++ " ədədi.",
        };
        for (letter.definitions, definitions, 1..) |sense, text, block_index| {
            try std.testing.expectEqual(block_index, sense.block);
            try std.testing.expect(sense.parent == null and sense.form == null);
            try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
            const block = before.sections[letter.section].blocks[sense.block];
            try std.testing.expect(block.kind == .definition and block.depth == 1);
            try std.testing.expectEqualStrings("#", block.list_path);
            try std.testing.expectEqual(@as(usize, 1), block.spans.len);
            try std.testing.expectEqualStrings(text, block.spans[0].text);
            try std.testing.expect(block.spans[0].kind == .text and block.spans[0].target.len == 0);
        }
        try std.testing.expect(before.sections[2].blocks[0].spans[0].bold);
        try std.testing.expectEqualStrings("xag", before.sections[2].blocks[0].spans[0].language);
        const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
        var expected: types.Stored = .{ .entry = before };
        expected.entry.organization = typed_layout.value;
        const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "Unclassified", .code = "" });
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
        var restored = decoded;
        restored.entry.organization = before.organization;
        // Every image/caption, nested table, action, style, pronunciation and
        // source citation remains identical; only organization is replaced.
        try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
    }
}

test "German linked noun gender heading keeps only its marked meanings as senses" {
    const document = @import("presentation_document.zig");
    const blob = @import("blob_encoder");
    const codec = blob.presentation_codec;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "=== [[Hilfe:Wortart#Substantiv|Substantiv]], <em title='Genus: Maskulinum'>m</em> ===\n" ++
        "<p style='font-weight:bold'>Worttrennung:</p>\n:before\n" ++
        "<p style='font-weight:bold'>Bedeutungen:</p>\n:[1] <i>[[Chemie]]:</i> first meaning\n:[2] second [[Target|meaning]]\n" ++
        "<p style='font-weight:bold'>Abkürzungen:</p>\n:[1] [[Sr]]\n" ++
        "<p style='font-weight:bold'>Beispiele:</p>\n:[1] example\n";
    for ([_]struct { heading: []const u8, code: []const u8 }{
        .{ .heading = "Portugiesisch", .code = "pt" },
        .{ .heading = "English", .code = "en" },
    }) |owner| {
        // Labels passed to generic compilation do not grant single-owner authority.
        const unowned_bytes = try document.compileAlloc(a, "noun control", .language, owner.heading, owner.code, source, null);
        const unowned = try codec.decodeAlloc(a, unowned_bytes, "noun control", .language, .{ .heading = owner.heading, .code = owner.code });
        try std.testing.expectEqual(@as(usize, 0), unowned.entry.organization.lexemes.len);
        const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
            a, "noun control", .language, owner.heading, owner.code, document.MissingText.untracked(source),
            null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
            .{ .heading = owner.heading, .code = owner.code },
        );
        const stored = try codec.decodeAlloc(a, bytes, "noun control", .language, .{ .heading = owner.heading, .code = owner.code });
        try std.testing.expectEqualStrings(owner.heading, stored.entry.language orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualStrings(owner.code, stored.entry.language_code);
        try std.testing.expectEqualDeep(unowned.entry.sections, stored.entry.sections);
        try std.testing.expectEqual(@as(usize, 1), stored.entry.organization.lexemes.len);
        const lexeme = stored.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings("Noun", lexeme.kind);
        try std.testing.expectEqual(@as(usize, 2), lexeme.definitions.len);
        const section = stored.entry.sections[lexeme.section];
        try std.testing.expectEqualStrings("Substantiv, m", section.title);
        for (lexeme.definitions, 0..) |sense, ordinal| {
            const block = section.blocks[sense.block];
            try std.testing.expect(block.kind == .indent);
            try std.testing.expectEqualStrings(":", block.list_path);
            try std.testing.expect(std.mem.startsWith(u8, block.spans[0].text, if (ordinal == 0) "[1] " else "[2] "));
        }
        var related_action = false;
        for (lexeme.other_blocks) |index| for (section.blocks[index].spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "Sr")) related_action = true;
        };
        try std.testing.expect(related_action);
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqualDeep(stored, try codec.decodeAlloc(a, try codec.encodeAlloc(a, stored), "noun control", .language, .{ .heading = owner.heading, .code = owner.code }));
    }
}

test "German meanings organization refuses unowned protected and unrelated heading domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct {
        title: []const u8 = "Substantiv, m",
        level: u8 = 3,
        is_heading: bool = true,
        title_depth: u8 = 0,
        title_list_path: []const u8 = "",
        title_spans: []const wiki.Span,
        blocks: []const wiki.Block,
    };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const heading = try renderer.parseSpans("[[Hilfe:Wortart#Substantiv|Substantiv]], <em>m</em>", .{});
    const body = try renderer.renderBody("<p style='font-weight:bold'>Bedeutungen:</p>\n:[1] meaning\n<p style='font-weight:bold'>Abkürzungen:</p>\n:[1] support\n");
    const section: Section = .{ .title_spans = heading, .blocks = body };
    try std.testing.expect(germanNounMeanings(section, "Portugiesisch") != null);
    for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
        try std.testing.expect(germanNounMeanings(section, owner) == null);
    for ([_][]const u8{ "Substantiv", "Substantiv, m note", "Verb, m", "Bedeutungen" }) |title| {
        var altered = section; altered.title = title;
        try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    }
    var altered = section;
    altered.level = 2;
    try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    altered = section; altered.is_heading = false;
    try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    altered = section; altered.title_depth = 1; altered.title_list_path = ":";
    try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    const protected_heading = try a.dupe(wiki.Span, heading);
    for (protected_heading) |*span| span.provenance = .protected_literal;
    altered = section; altered.title_spans = protected_heading;
    try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    const wrong_target = try a.dupe(wiki.Span, heading);
    for (wrong_target) |*span| if (span.kind == .link) { span.target = "Unrelated"; };
    altered = section; altered.title_spans = wrong_target;
    try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    for ([_][]const u8{
        "Bedeutungen:\n:[1] meaning\n",
        "<p style='font-weight:bold'><nowiki>Bedeutungen:</nowiki></p>\n:[1] meaning\n",
        "<p style='font-weight:bold'>Bedeutungen:</p>\n:[[1]] meaning\n",
        "<p style='font-weight:bold'>Bedeutungen:</p>\n:[1] first\n<p style='font-weight:bold'>Bedeutungen:</p>\n:[2] second\n",
    }) |source| {
        altered = section; altered.blocks = try renderer.renderBody(source);
        try std.testing.expect(germanNounMeanings(altered, "Portugiesisch") == null);
    }
    const sections = [_]Section{section};
    const unowned = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 0), unowned.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{0}, unowned.other_sections);
}

test "Vietnamese noun label preserves independently classified owners and complete sense body codec" {
    const document = @import("presentation_document.zig");
    const blob = @import("blob_encoder");
    const codec = blob.presentation_codec;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Danh từ") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "danh từ", "Danh từ khác", "Tiếng Nga", "Tham khảo" }) |heading| try std.testing.expect(partOfSpeech(heading) == null);
    const source = "===Danh từ===\n'''head'''\n# [[Meaning|meaning]]\n#: example\n===Tham khảo===\n[[Other|other]]\n";
    for ([_]struct { heading: []const u8, code: []const u8 }{
        .{ .heading = "Tiếng Nga", .code = "ru" }, .{ .heading = "English", .code = "en" },
    }) |owner| {
        const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
            a, "noun control", .language, owner.heading, owner.code, document.MissingText.untracked(source),
            null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
            .{ .heading = owner.heading, .code = owner.code },
        );
        const stored = try codec.decodeAlloc(a, bytes, "noun control", .language, .{ .heading = owner.heading, .code = owner.code });
        try std.testing.expectEqualStrings(owner.heading, stored.entry.language orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualStrings(owner.code, stored.entry.language_code);
        try std.testing.expectEqual(@as(usize, 2), stored.entry.sections.len);
        try std.testing.expectEqual(@as(usize, 1), stored.entry.organization.lexemes.len);
        const lexeme = stored.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings(owner.heading, lexeme.language);
        try std.testing.expectEqualStrings("Noun", lexeme.kind);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        const sense = lexeme.definitions[0];
        try std.testing.expectEqual(@as(usize, 1), sense.examples.len);
        const section = stored.entry.sections[lexeme.section];
        try std.testing.expectEqualStrings("Danh từ", section.title);
        try std.testing.expect(section.blocks[sense.block].kind == .definition);
        try std.testing.expectEqualStrings("Meaning", section.blocks[sense.block].spans[0].target);
        try std.testing.expect(section.blocks[sense.examples[0]].kind == .example);
        try std.testing.expectEqualStrings("Tham khảo", stored.entry.sections[1].title);
        try std.testing.expectEqualStrings("Other", stored.entry.sections[1].blocks[0].spans[0].target);
        try std.testing.expectEqualSlices(u8, bytes, try codec.encodeAlloc(a, stored));
        try std.testing.expectEqualDeep(stored, try codec.decodeAlloc(a, try codec.encodeAlloc(a, stored), "noun control", .language, .{ .heading = owner.heading, .code = owner.code }));
    }
}

test "LT exact adjective heading adds lexical kind without supplying a language owner" {
    try std.testing.expectEqualStrings("Adjective", partOfSpeech("Būdvardis") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "būdvardis", "BŪDVARDIS", "Būdvardis 2", "Būdvardžio", "<code>Būdvardis</code>", " Būdvardis", "Būdvardis " }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("'''headword'''\n# ''first'' [[sense]]\n# second meaning\n");
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block };
    const sections = [_]Section{.{ .title = "Būdvardis", .level = 3, .blocks = body }};
    const unowned = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unowned.lexemes.len);
    try std.testing.expectEqualStrings("Adjective", unowned.lexemes[0].kind);
    try std.testing.expectEqualStrings("", unowned.lexemes[0].language);
    try std.testing.expectEqual(@as(usize, 2), unowned.lexemes[0].definitions.len);
    var standard = sections;
    standard[0].title = "Adjective";
    try std.testing.expectEqualDeep(try buildUnclassified(a, &standard), unowned);
    for ([_][]const u8{ "Japanese", "Mandarin Chinese", "independent-owner" }) |owner| {
        const owned = try buildOwned(a, &sections, owner);
        try std.testing.expectEqualDeep(try buildOwned(a, &standard, owner), owned);
        try std.testing.expectEqualStrings(owner, owned.lexemes[0].language);
    }
    const boundary = [_]Section{.{ .title = "Būdvardis", .level = 2, .blocks = body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &boundary)).lexemes.len);
    const prose = try renderer.renderBody("Būdvardis\n<nowiki>===Būdvardis===</nowiki>\n<pre>===Būdvardis===</pre>\n# notes\n");
    const ordinary = [_]Section{.{ .title = "Notes", .level = 3, .blocks = prose }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &ordinary, "independent-owner")).lexemes.len);
}

test "LT actual Reader adjective organization preserves all unresolved language bodies actions styles tables media diagnostics and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/lt-reader148/ziyou.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqualStrings("08e0fba80af4b281b9f97b3c65dd0b668cb5481823de2648c198028937588db7", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("自由", before.title);
    try std.testing.expectEqualStrings("Unclassified", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("", before.language_code);
    try std.testing.expectEqual(@as(usize, 21), before.sections.len);
    try std.testing.expectEqual(@as(usize, 5), before.media.len);
    try std.testing.expectEqual(@as(usize, 3), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 6, 7, 8, 9, 10, 11, 12, 15, 16, 19, 20 }, before.organization.other_sections);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    // The actual Reader remains unowned here. POS classification cannot replace
    // the independent indexed template/category ownership proof.
    const layout = try buildUnclassified(a, sections);
    try std.testing.expectEqual(@as(usize, 5), layout.lexemes.len);
    const positions = [_]usize{ 1, 6, 13, 17, 19 };
    const senses = [_]usize{ 3, 2, 2, 2, 2 };
    for (layout.lexemes, positions, senses, 0..) |lexeme, position, sense_block, index| {
        try std.testing.expectEqualStrings(if (index == 1 or index == 4) "Adjective" else "Noun", lexeme.kind);
        try std.testing.expectEqualStrings("", lexeme.language);
        try std.testing.expectEqual(position, lexeme.section);
        try std.testing.expect(lexeme.etymology == null and lexeme.other_blocks.len == 0);
        try std.testing.expectEqual(@as(usize, 1), lexeme.definitions.len);
        const sense = lexeme.definitions[0];
        try std.testing.expectEqual(sense_block, sense.block);
        try std.testing.expect(sense.parent == null and sense.form == null);
        try std.testing.expect(sense.examples.len == 0 and sense.quotations.len == 0 and sense.notes.len == 0);
        try std.testing.expectEqualSlices(usize, if (index == 0) &.{ 0, 1, 2 } else &.{ 0, 1 }, lexeme.introduction);
        const related: []const usize = switch (index) { 0 => &.{ 2, 3, 4, 5 }, 1 => &.{ 7, 8, 9, 10 }, 2 => &.{14}, 3 => &.{18}, 4 => &.{20}, else => unreachable };
        try std.testing.expectEqualSlices(usize, related, lexeme.related_sections);
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 11, 12, 15, 16 }, layout.other_sections);
    for ([_]usize{ 6, 19 }, [_][]const u8{ "laisvas\xc2\xa0(lt), laisva\xc2\xa0(lt)", "laisvas\xc2\xa0(lt)" }) |position, expected_text| {
        const section = before.sections[position];
        try std.testing.expectEqualStrings("Būdvardis", section.title);
        try std.testing.expectEqual(@as(u8, 3), section.level);
        const block = section.blocks[2];
        try std.testing.expect(block.kind == .definition and block.depth == 1);
        try std.testing.expectEqualStrings("#", block.list_path);
        var text: std.ArrayList(u8) = .empty;
        for (block.spans) |span| { try text.appendSlice(a, span.text); try text.appendSlice(a, span.trail); }
        try std.testing.expectEqualStrings(expected_text, text.items);
    }
    var diagnostic = false;
    for (before.sections[6].blocks[1].spans) |span| if (std.mem.indexOf(u8, span.text, "[malformed template]") != null) { diagnostic = true; };
    try std.testing.expect(diagnostic);
    const standard = try a.dupe(Section, sections);
    for ([_]usize{ 6, 19 }) |index| {
        standard[index].title = "Adjective";
        standard[index].title_spans = &.{.{ .text = "Adjective" }};
    }
    try std.testing.expectEqualDeep(try buildUnclassified(a, standard), layout);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "Unclassified", .code = "" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "retained BN longingly complete Reader gains authored adverb sense and quotation organization with codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const encoder = @import("blob_encoder"); const T = encoder.presentation_types;
    const bytes = @embedFile("testdata/bn-longingly/reader128.json");
    const raw = @embedFile("testdata/bn-longingly/source.raw.wikitext");
    const expanded = @embedFile("testdata/bn-longingly/source.expanded.wikitext");
    const F = struct {
        fn hash(source: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    try F.hash(bytes, "26393afa5504e792f5fbc3d7acdfd5af5c924918ec784f1358a218f2b48acdcd");
    try F.hash(raw, "f7399fb7a823b00157839da4ad94f8679e3e2e03995ea27227b0e1257eff64de");
    try F.hash(expanded, "1dc509344365639369d7f13ce436a17bcb98d18785135ea0afa8daf8f86404fe");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "===ক্রিয়া বিশেষণ===\n{{en-adv}}"));
    try std.testing.expect(std.mem.indexOf(u8, expanded, "[[Category:ইংরেজি ক্রিয়াবিশেষণ|LONGINGLY]]") != null);
    const page = try std.json.parseFromSlice(struct { entries: []const T.Entry }, a, bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), page.value.entries.len);
    const before = page.value.entries[0];
    try std.testing.expectEqualStrings("longingly", before.title);
    try std.testing.expectEqualStrings("ইংরেজি", before.language.?);
    try std.testing.expectEqualStrings("en", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, before.organization.other_sections);
    try std.testing.expectEqual(@as(usize, 4), before.sections.len);
    try std.testing.expectEqualStrings("ক্রিয়া বিশেষণ", before.sections[3].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[3].level);
    try std.testing.expectEqual(@as(usize, 4), before.sections[3].blocks.len);
    try std.testing.expect(before.sections[3].blocks[1].kind == .definition);
    for (before.sections[3].blocks[2..]) |block| {
        try std.testing.expect(block.kind == .quotation);
        try std.testing.expectEqualStrings("#*", block.list_path);
    }
    const S = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const S } }, a, bytes, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(S, projected.value.entries[0].sections);
    // This projection supplies build-only addresses and flags. It does not
    // invent missing Reader provenance; the full independent Entry is the oracle.
    for (sections, before.sections) |*section, original| {
        const blocks = try a.dupe(wiki.Block, section.blocks);
        for (blocks, original.blocks) |*block, original_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            for (spans, original_block.spans) |*span, original_span| span.flags = .{
                .bold = original_span.bold, .italic = original_span.italic, .code = original_span.code,
                .small = original_span.small, .superscript = original_span.superscript,
                .subscript = original_span.subscript, .strike = original_span.strike, .underline = original_span.underline,
            };
            block.spans = spans;
        }
        section.blocks = blocks;
    }
    const layout = try buildOwned(a, sections, before.language.?);
    const encoded_layout = try std.json.Stringify.valueAlloc(a, layout, .{});
    const organization = try std.json.parseFromSlice(T.Layout, a, encoded_layout, .{});
    const expected: T.Layout = .{ .lexemes = &.{.{
        .language = "ইংরেজি", .kind = "Adverb", .section = 3,
        .definitions = &.{.{ .block = 1, .quotations = &.{ 2, 3 } }}, .introduction = &.{0},
    }}, .other_sections = &.{ 0, 1, 2 } };
    try std.testing.expectEqualDeep(expected, organization.value);
    var after: T.Stored = .{ .entry = before }; after.entry.organization = organization.value;
    const encoded = try encoder.presentation_codec.encodeAlloc(a, after);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, encoded, before.title, before.kind, .{ .heading = before.language.?, .code = before.language_code });
    try std.testing.expectEqualDeep(after, decoded);
    try std.testing.expectEqualSlices(u8, encoded, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded; restored.entry.organization = before.organization;
    try std.testing.expectEqualDeep(T.Stored{ .entry = before }, restored);
}

test "exact Bengali adverb declaration retains supplied owner and refuses neighboring labels or body imitations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    try std.testing.expectEqualStrings("Adverb", partOfSpeech("ক্রিয়া বিশেষণ") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "ক্রিয়া বিশেষণ আলোচনা", "সম্পর্কিত ক্রিয়া বিশেষণ", "ক্রিয়া  বিশেষণ", "ক্রিয়াবিশেষণ", "<nowiki>ক্রিয়া বিশেষণ</nowiki>" }) |label| try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "longingly" } };
    const blocks = try renderer.renderBody("'''longingly'''\n# [[আকাঙ্ক্ষা]]র সাথে, [[কামনা]] সহকারে, [[ব্যগ্রভাবে]]।\n#* First quotation.\n#* Second quotation.");
    const S = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]S{ .{ .title = "ইংরেজি", .level = 2 }, .{ .title = "ক্রিয়া বিশেষণ", .level = 3, .blocks = blocks } };
    const owned = try buildOwned(a, &sections, "independently supplied owner");
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes.len);
    try std.testing.expectEqualStrings("independently supplied owner", owned.lexemes[0].language);
    try std.testing.expectEqualStrings("Adverb", owned.lexemes[0].kind);
    try std.testing.expectEqual(@as(usize, 1), owned.lexemes[0].definitions.len);
    const unclassified = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unclassified.lexemes.len);
    try std.testing.expectEqualStrings("", unclassified.lexemes[0].language);
    var altered = sections; altered[1].title = "ক্রিয়া বিশেষণ আলোচনা";
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &altered, "ইংরেজি")).lexemes.len);
    // A body label, protected literal and an ordinary reference do not declare POS.
    const prose = try renderer.renderBody("ক্রিয়া বিশেষণ\n<nowiki>ক্রিয়া বিশেষণ</nowiki>\n[[ক্রিয়া বিশেষণ]]");
    const body_only = [_]S{ .{ .title = "ইংরেজি", .level = 2 }, .{ .title = "উচ্চারণ", .level = 3, .blocks = prose } };
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &body_only, "ইংরেজি")).lexemes.len);
    const unknown_h2 = [_]S{.{ .title = "ক্রিয়া বিশেষণ", .level = 2, .blocks = blocks }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &unknown_h2)).lexemes.len);
}

test "TR authored Ad noun requires independent Turkish owner parsed heading headword and direct sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("<strong class=\"Latn headword\" lang=\"tr\">[[sadaka]]</strong>\n# [[sadaka]]\n#: ''authored example''\n");
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[0].spans[0].role == .headword);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block = &.{},
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const noun: Section = .{ .title = "Ad", .level = 3, .blocks = body, .title_spans = &.{.{ .text = "Ad" }} };
    const sections = [_]Section{
        .{ .title = "Türkçe", .level = 2 }, noun,
        .{ .title = "Çekimleme", .level = 4 }, .{ .title = "Kaynakça", .level = 3 },
    };
    try std.testing.expect(partOfSpeech("Ad") == null);
    try std.testing.expectEqualStrings("Noun", ownedTurkishNounPart(noun, "Türkçe") orelse return error.TestUnexpectedResult);
    const layout = try buildOwned(a, &sections, "Türkçe");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("Türkçe", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 1), lexical.section);
    try std.testing.expect(lexical.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    try std.testing.expect(lexical.definitions[0].quotations.len == 0 and lexical.definitions[0].notes.len == 0);
    for ([_]?[]const u8{ null, "", "Unclassified", "English", "Turkish", "Türkçe2" }) |owner|
        try std.testing.expect(ownedTurkishNounPart(noun, owner) == null);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    for ([_][]const u8{ "ad", "AD", "Ad2", "Ad?", " Ad", "Ad ", "<nowiki>Ad</nowiki>" }) |label| {
        var changed = noun;
        changed.title = label;
        try std.testing.expect(ownedTurkishNounPart(changed, "Türkçe") == null);
    }
    for ([_]u8{ 2, 4 }) |level| {
        var changed = noun;
        changed.level = level;
        try std.testing.expect(ownedTurkishNounPart(changed, "Türkçe") == null);
    }
    for (0..6) |case| {
        var changed = noun;
        var heading = [_]wiki.Span{.{ .text = "Ad" }};
        changed.title_spans = &heading;
        switch (case) {
            0 => changed.is_heading = false,
            1 => changed.title_depth = 1,
            2 => changed.title_list_path = "*",
            3 => heading[0].provenance = .protected_literal,
            4 => heading[0].generated_diagnostic = true,
            5 => heading[0].flags.code = true,
            else => unreachable,
        }
        try std.testing.expect(ownedTurkishNounPart(changed, "Türkçe") == null);
    }
    for (0..5) |case| {
        var changed = noun;
        const changed_blocks = try a.dupe(wiki.Block, body);
        changed.blocks = changed_blocks;
        const headword = try a.dupe(wiki.Span, body[0].spans);
        changed_blocks[0].spans = headword;
        switch (case) {
            0 => headword[0].language = "en",
            1 => headword[0].role = .normal,
            2 => headword[0].flags.bold = false,
            3 => headword[0].generated_diagnostic = true,
            4 => changed_blocks[1].kind = .paragraph,
            else => unreachable,
        }
        try std.testing.expect(ownedTurkishNounPart(changed, "Türkçe") == null);
    }
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun") orelse return error.TestUnexpectedResult);
}

test "TR actual sadaka Reader noun organization preserves all body examples inflections actions styles references and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/tr-sadaka-reader151/reader.tr.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 390476), fixture.len);
    try std.testing.expectEqualStrings("c8bacaa5971d7c01ddf3087e768cca25ca5e3fe9e9acf6ffc031294989c10c11", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("sadaka-i cariye", before.title);
    try std.testing.expectEqualStrings("Türkçe", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("tr", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, before.organization.other_sections);
    const headings = [_][]const u8{ "Türkçe", "Köken", "Söyleniş", "Ad", "Çekimleme", "Üst kavramlar", "Kelime birliktelikleri", "Çeviriler", "Kaynakça", "Ek okumalar" };
    const levels = [_]u8{ 2, 3, 3, 3, 4, 4, 4, 4, 3, 3 };
    const block_counts = [_]usize{ 0, 1, 2, 3, 4, 1, 1, 2, 0, 1 };
    try std.testing.expectEqual(headings.len, before.sections.len);
    for (before.sections, headings, levels, block_counts) |section, heading, level, count| {
        try std.testing.expectEqualStrings(heading, section.title);
        try std.testing.expectEqual(level, section.level);
        try std.testing.expectEqual(count, section.blocks.len);
    }
    try std.testing.expectEqual(@as(usize, 2), before.references.len);
    try std.testing.expectEqual(@as(usize, 1), before.media.len);
    try std.testing.expectEqualStrings("Bootstrap arrow-return-right.svg", before.media[0].file);
    for ([_]usize{ 1, 3 }, [_]usize{ 7, 43 }) |block_index, rows|
        try std.testing.expectEqual(rows, (before.sections[4].blocks[block_index].table orelse return error.TestUnexpectedResult).rows.len);
    try std.testing.expectEqual(@as(usize, 1), (before.sections[7].blocks[1].table orelse return error.TestUnexpectedResult).rows.len);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Türkçe", noun.language);
    try std.testing.expectEqual(@as(usize, 3), noun.section);
    // Köken remains authored supporting content; this patch does not invent
    // a new etymology mapping or alter any body field while repairing the noun.
    try std.testing.expect(noun.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqual(@as(usize, 0), noun.other_blocks.len);
    try std.testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7 }, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 8, 9 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    const sense = noun.definitions[0];
    try std.testing.expectEqual(@as(usize, 1), sense.block);
    try std.testing.expect(sense.parent == null and sense.form == null);
    try std.testing.expectEqualSlices(usize, &.{2}, sense.examples);
    try std.testing.expect(sense.quotations.len == 0 and sense.notes.len == 0);
    const definition = before.sections[noun.section].blocks[sense.block];
    try std.testing.expect(definition.kind == .definition and definition.depth == 1);
    try std.testing.expectEqualStrings("#", definition.list_path);
    try std.testing.expectEqualStrings("1", definition.number);
    try std.testing.expectEqualStrings("#:", before.sections[noun.section].blocks[2].list_path);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, sections, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "Türkçe", .code = "tr" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Every original body/style/action/media/reference and recovery literal is
    // retained, including the independent currentG visual limitations.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "GA actual achoimre organization preserves complete retained body actions styles media and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const encoder = @import("blob_encoder"); const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/ga-sd-organization/ga-00.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 27347), fixture.len);
    try std.testing.expectEqualStrings("eccd2fe0c217accdd28072c81f65e6d8c4c16cec34f0afb4bca1c0e07bb5298f", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("achoimre", before.title);
    try std.testing.expectEqualStrings("Gaeilge", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("ga", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    const raw = @embedFile("testdata/ga-sd-organization/ga-00.wikitext");
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    try std.testing.expectEqualStrings("0d0ef6b42894fbfa42858575f22c753d7fa90d56c669092289ad13c31088cadd", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 3), before.sections.len);
    try std.testing.expectEqual(@as(usize, 1), before.media.len);
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqualStrings("Gaeilge", before.sections[0].title);
    try std.testing.expectEqual(@as(u8, 2), before.sections[0].level);
    try std.testing.expectEqual(@as(usize, 0), before.sections[0].blocks.len);
    try std.testing.expectEqualStrings("Ainmfhocal", before.sections[1].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[1].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[1].blocks.len);
    try std.testing.expectEqualStrings("Aistriúcháin", before.sections[2].title);
    try std.testing.expectEqual(@as(u8, 4), before.sections[2].level);
    try std.testing.expectEqual(@as(usize, 3), before.sections[2].blocks.len);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // Value-based build-time projection; raw source establishes these headings.
    // This is not fresh expansion or independently earned Writer parity.
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Gaeilge", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].examples.len);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = before.language orelse return error.TestUnexpectedResult, .code = before.language_code });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Every original body/style/action/media/reference and recovery literal is
    // retained, including the independent currentG visual limitations.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "GA actual gainéad organization preserves complete retained body actions styles media and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const encoder = @import("blob_encoder"); const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/ga-sd-organization/ga-01.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 205085), fixture.len);
    try std.testing.expectEqualStrings("55bf03dc44709996a8a530b540b156e8a320aeba19b014f3c03984cb1b901fb6", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("gainéad", before.title);
    try std.testing.expectEqualStrings("Gaeilge", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("ga", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    const raw = @embedFile("testdata/ga-sd-organization/ga-01.wikitext");
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    try std.testing.expectEqualStrings("051b5a264ded5bc14c9ad80689716dcd9c6a142b7279911c92a165a28a0071a6", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 6), before.sections.len);
    try std.testing.expectEqual(@as(usize, 4), before.media.len);
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqualStrings("Gaeilge", before.sections[0].title);
    try std.testing.expectEqual(@as(u8, 2), before.sections[0].level);
    try std.testing.expectEqual(@as(usize, 1), before.sections[0].blocks.len);
    try std.testing.expectEqualStrings("Fuaimniú", before.sections[1].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[1].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[1].blocks.len);
    try std.testing.expectEqualStrings("Sanasaíocht", before.sections[2].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[2].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[2].blocks.len);
    try std.testing.expectEqualStrings("Ainmfhocal", before.sections[3].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[3].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[3].blocks.len);
    try std.testing.expectEqualStrings("Aistriúcháin", before.sections[4].title);
    try std.testing.expectEqual(@as(u8, 4), before.sections[4].level);
    try std.testing.expectEqual(@as(usize, 3), before.sections[4].blocks.len);
    try std.testing.expectEqualStrings("Tagairtí", before.sections[5].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[5].level);
    try std.testing.expectEqual(@as(usize, 8), before.sections[5].blocks.len);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // Value-based build-time projection; raw source establishes these headings.
    // This is not fresh expansion or independently earned Writer parity.
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Gaeilge", noun.language);
    try std.testing.expectEqual(@as(usize, 3), noun.section);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].examples.len);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = before.language orelse return error.TestUnexpectedResult, .code = before.language_code });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Every original body/style/action/media/reference and recovery literal is
    // retained, including the independent currentG visual limitations.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "SD actual سنڌي organization preserves complete retained body actions styles media and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const encoder = @import("blob_encoder"); const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/ga-sd-organization/sd-00.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 101944), fixture.len);
    try std.testing.expectEqualStrings("c30e3af78f65e21b1c4d5366db011b5882c47252e254a4180a5c388606d1a53b", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("سنڌي", before.title);
    try std.testing.expectEqualStrings("Sindhi", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("sd", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    const raw = @embedFile("testdata/ga-sd-organization/sd-00.wikitext");
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    try std.testing.expectEqualStrings("b094990064d1a7b593ca84a4748239623b137b51a5f620fbf171ec4a3b3eea08", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 8), before.sections.len);
    try std.testing.expectEqual(@as(usize, 3), before.media.len);
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqualStrings("سنڌي", before.sections[0].title);
    try std.testing.expectEqual(@as(u8, 2), before.sections[0].level);
    try std.testing.expectEqual(@as(usize, 0), before.sections[0].blocks.len);
    try std.testing.expectEqualStrings("بُڻڀياسُ", before.sections[1].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[1].level);
    try std.testing.expectEqual(@as(usize, 1), before.sections[1].blocks.len);
    try std.testing.expectEqualStrings("سرخي", before.sections[2].title);
    try std.testing.expectEqual(@as(u8, 2), before.sections[2].level);
    try std.testing.expectEqual(@as(usize, 0), before.sections[2].blocks.len);
    try std.testing.expectEqualStrings("اسم خاص (مونث)", before.sections[3].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[3].level);
    try std.testing.expectEqual(@as(usize, 1), before.sections[3].blocks.len);
    try std.testing.expectEqualStrings("ترجما", before.sections[4].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[4].level);
    try std.testing.expectEqual(@as(usize, 1), before.sections[4].blocks.len);
    try std.testing.expectEqualStrings("صفتَ", before.sections[5].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[5].level);
    try std.testing.expectEqual(@as(usize, 4), before.sections[5].blocks.len);
    try std.testing.expectEqualStrings("ترجما", before.sections[6].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[6].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[6].blocks.len);
    try std.testing.expectEqualStrings("پڻ ڏسندا", before.sections[7].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[7].level);
    try std.testing.expectEqual(@as(usize, 2), before.sections[7].blocks.len);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // Value-based build-time projection; raw source establishes these headings.
    // This is not fresh expansion or independently earned Writer parity.
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 0), layout.lexemes.len);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = before.language orelse return error.TestUnexpectedResult, .code = before.language_code });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Every original body/style/action/media/reference and recovery literal is
    // retained, including the independent currentG visual limitations.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "SD actual اِندري organization preserves complete retained body actions styles media and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const encoder = @import("blob_encoder"); const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/ga-sd-organization/sd-01.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 10363), fixture.len);
    try std.testing.expectEqualStrings("2a0511347f9587d8addc8bc28c532dedb02a038cc828f647455d833123365e7e", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("اِندري", before.title);
    try std.testing.expectEqualStrings("Sindhi", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("sd", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    const raw = @embedFile("testdata/ga-sd-organization/sd-01.wikitext");
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    try std.testing.expectEqualStrings("cd979056fafe1aa7db1163a34e70f5c20183cd838cd96b39bc7b25d871c27616", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectEqual(@as(usize, 4), before.sections.len);
    try std.testing.expectEqual(@as(usize, 2), before.media.len);
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqualStrings("سنڌي", before.sections[0].title);
    try std.testing.expectEqual(@as(u8, 2), before.sections[0].level);
    try std.testing.expectEqual(@as(usize, 0), before.sections[0].blocks.len);
    try std.testing.expectEqualStrings("بُڻڀياسُ", before.sections[1].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[1].level);
    try std.testing.expectEqual(@as(usize, 0), before.sections[1].blocks.len);
    try std.testing.expectEqualStrings("اسم", before.sections[2].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[2].level);
    try std.testing.expectEqual(@as(usize, 4), before.sections[2].blocks.len);
    try std.testing.expectEqualStrings("پڻ ڏسندا", before.sections[3].title);
    try std.testing.expectEqual(@as(u8, 3), before.sections[3].level);
    try std.testing.expectEqual(@as(usize, 1), before.sections[3].blocks.len);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // Value-based build-time projection; raw source establishes these headings.
    // This is not fresh expansion or independently earned Writer parity.
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Sindhi", noun.language);
    try std.testing.expectEqual(@as(usize, 2), noun.section);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[0].examples.len);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions[1].block);
    try std.testing.expectEqual(@as(usize, 0), noun.definitions[1].examples.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, sections, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = before.language orelse return error.TestUnexpectedResult, .code = before.language_code });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Every original body/style/action/media/reference and recovery literal is
    // retained, including the independent currentG visual limitations.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}

test "SD authored noun requires independent Sindhi owner parsed heading bold lemma and direct sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("'''اِندري''' (''جمع'' '''[[اِندريُون]]''')\n# حواس يا حسَ.\n#: ''authored example''\n");
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[0].spans[0].role == .normal and body[0].spans[0].flags.bold);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block = &.{},
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const noun: Section = .{ .title = "اسم", .level = 3, .blocks = body, .title_spans = &.{.{ .text = "اسم" }} };
    const sections = [_]Section{
        .{ .title = "Sindhi", .level = 2 }, noun,
        .{ .title = "Çekimleme", .level = 4 }, .{ .title = "Kaynakça", .level = 3 },
    };
    try std.testing.expect(partOfSpeech("اسم") == null);
    try std.testing.expectEqualStrings("Noun", ownedSindhiNounPart(noun, "Sindhi") orelse return error.TestUnexpectedResult);
    const layout = try buildOwned(a, &sections, "Sindhi");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("Sindhi", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 1), lexical.section);
    try std.testing.expect(lexical.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    try std.testing.expect(lexical.definitions[0].quotations.len == 0 and lexical.definitions[0].notes.len == 0);
    for ([_]?[]const u8{ null, "", "Unclassified", "English", "سنڌي", "Persian", "اردو", "Sindhi2" }) |owner|
        try std.testing.expect(ownedSindhiNounPart(noun, owner) == null);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    for ([_][]const u8{ "اسم خاص (مونث)", "اسم2", " اسم", "اسم ", "<nowiki>اسم</nowiki>" }) |label| {
        var changed = noun;
        changed.title = label;
        try std.testing.expect(ownedSindhiNounPart(changed, "Sindhi") == null);
    }
    for ([_]u8{ 2, 4 }) |level| {
        var changed = noun;
        changed.level = level;
        try std.testing.expect(ownedSindhiNounPart(changed, "Sindhi") == null);
    }
    for (0..6) |case| {
        var changed = noun;
        var heading = [_]wiki.Span{.{ .text = "اسم" }};
        changed.title_spans = &heading;
        switch (case) {
            0 => changed.is_heading = false,
            1 => changed.title_depth = 1,
            2 => changed.title_list_path = "*",
            3 => heading[0].provenance = .protected_literal,
            4 => heading[0].generated_diagnostic = true,
            5 => heading[0].flags.code = true,
            else => unreachable,
        }
        try std.testing.expect(ownedSindhiNounPart(changed, "Sindhi") == null);
    }
    for (0..10) |case| {
        var changed = noun;
        const changed_blocks = try a.dupe(wiki.Block, body);
        changed.blocks = changed_blocks;
        const headword = try a.dupe(wiki.Span, body[0].spans);
        changed_blocks[0].spans = headword;
        switch (case) {
            0 => headword[0].language = "en",
            1 => headword[0].role = .headword,
            2 => headword[0].flags.bold = false,
            3 => headword[0].generated_diagnostic = true,
            4 => changed_blocks[1].kind = .paragraph,
            5 => headword[0].provenance = .protected_literal,
            6 => headword[0].target = "invented",
            7 => changed_blocks[1].list_path = "*",
            8 => changed_blocks[1].depth = 2,
            9 => changed_blocks[1].spans = &.{.{ .text = "", .generated_diagnostic = true }},
            else => unreachable,
        }
        try std.testing.expect(ownedSindhiNounPart(changed, "Sindhi") == null);
    }
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun") orelse return error.TestUnexpectedResult);
}


test "Irish noun label preserves independent ownership and refuses neighboring labels and body imitations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Ainmfhocal") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "ainmfhocal", "Ainmfhocal 2", "Ainmfhocal?", " Ainmfhocal", "Ainmfhocal ", "<nowiki>Ainmfhocal</nowiki>" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody("'''achoimre'''\n# [[leagan|Leagan]] [[gearr]].\n#: ''example''\n");
    const S = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]S{ .{ .title = "Gaeilge", .level = 2 }, .{ .title = "Ainmfhocal", .level = 3, .blocks = blocks } };
    for ([_][]const u8{ "Gaeilge", "Independent foreign owner" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        try std.testing.expectEqualStrings(owner, layout.lexemes[0].language);
        try std.testing.expectEqualStrings("Noun", layout.lexemes[0].kind);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes[0].definitions.len);
        try std.testing.expectEqualSlices(usize, &.{2}, layout.lexemes[0].definitions[0].examples);
    }
    const unknown = try buildUnclassified(a, &sections);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
    const body = try renderer.renderBody("Ainmfhocal\n<nowiki>===Ainmfhocal===</nowiki>\n");
    const unsupported = [_]S{.{ .title = "Notes", .level = 3, .blocks = body }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &unsupported, "Gaeilge")).lexemes.len);
    const unknown_h2 = [_]S{.{ .title = "Ainmfhocal", .level = 2, .blocks = blocks }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &unknown_h2)).lexemes.len);
}

test "Irish and Sindhi lexical role source witnesses retain their exact authored dependency chain" {
    const noun = @embedFile("testdata/ga-sd-organization/ga-role-source-0.wikitext");
    try std.testing.expectEqualStrings("#REDIRECT [[Teimpléad:-ainm-]]", std.mem.trim(u8, noun, "\r\n"));
    const heading = @embedFile("testdata/ga-sd-organization/ga-role-source-followup-0.wikitext");
    try std.testing.expect(std.mem.indexOf(u8, heading, " Ainmfhocal ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, heading, ": ainmfhocail") != null);
    const sd = @embedFile("testdata/ga-sd-organization/sd-role-source-0.wikitext");
    try std.testing.expectEqualStrings("'''{{PAGENAME}}''' (''جمع'' '''[[{{PAGENAME}}ُون]]''')", sd);
    try std.testing.expectEqualStrings("[[category:سنڌي اسم]]", @embedFile("testdata/ga-sd-organization/sd-role-source-1.wikitext"));
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("testdata/ga-sd-organization/sd-role-source-followup-0.wikitext"), "سنڌي اسم لفظن جي فهرست:") != null);
    try std.testing.expect(partOfSpeech("اسم") == null);
}

test "JA exact verb heading preserves independent owners source blocks and unknown ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Section = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "partir", .language = "フランス語" } };
    const blocks = try renderer.renderBody("'''partir'''\n# [[出発]]する。\n#: 類義語: [[sortir]]\n# [[分割]]する。\n");
    const sections = [_]Section{
        .{ .title = "フランス語", .level = 2 },
        .{ .title = "動詞", .level = 3, .blocks = blocks },
        .{ .title = "関連語", .level = 4 },
    };
    var reference = sections;
    reference[1].title = "Verb";
    for ([_][]const u8{ "フランス語", "Independent owner" }) |owner| {
        const actual = try buildOwned(a, &sections, owner);
        try std.testing.expectEqualDeep(try buildOwned(a, &reference, owner), actual);
        try std.testing.expectEqual(@as(usize, 1), actual.lexemes.len);
        try std.testing.expectEqualStrings(owner, actual.lexemes[0].language);
        try std.testing.expectEqualStrings("Verb", actual.lexemes[0].kind);
        try std.testing.expectEqual(@as(usize, 2), actual.lexemes[0].definitions.len);
        try std.testing.expectEqualSlices(usize, &.{2}, actual.lexemes[0].definitions[0].examples);
    }
    const unknown = try buildUnclassified(a, &sections);
    try std.testing.expectEqualDeep(try buildUnclassified(a, &reference), unknown);
    try std.testing.expectEqualStrings("", unknown.lexemes[0].language);
    try std.testing.expectEqualDeep(blocks, sections[1].blocks);
    for ([_][]const u8{ "動詞形", "動詞 extra", "{{verb}}", "[[動詞]]", "語源", "発音" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
}

test "RW authored Izina noun requires independent Kinyarwanda owner parsed heading ordinary bold headword and direct sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const body = try renderer.renderBody("'''mudasobwa'''\n# A [[programmable]] [[device]].\n#: ''authored example''\n");
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[0].spans[0].role == .normal and body[0].spans[0].flags.bold);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block = &.{},
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const noun: Section = .{ .title = "Izina", .level = 3, .blocks = body, .title_spans = &.{.{ .text = "Izina" }} };
    const sections = [_]Section{
        .{ .title = "Ikinyarwanda", .level = 2 }, noun,
        .{ .title = "Related terms", .level = 4 }, .{ .title = "Supporting notes", .level = 3 },
    };
    try std.testing.expect(partOfSpeech("Izina") == null);
    try std.testing.expectEqualStrings("Noun", ownedKinyarwandaNounPart(noun, "Ikinyarwanda") orelse return error.TestUnexpectedResult);
    const layout = try buildOwned(a, &sections, "Ikinyarwanda");
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const lexical = layout.lexemes[0];
    try std.testing.expectEqualStrings("Ikinyarwanda", lexical.language);
    try std.testing.expectEqualStrings("Noun", lexical.kind);
    try std.testing.expectEqual(@as(usize, 1), lexical.section);
    try std.testing.expect(lexical.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
    try std.testing.expectEqualSlices(usize, &.{2}, lexical.definitions[0].examples);
    try std.testing.expect(lexical.definitions[0].quotations.len == 0 and lexical.definitions[0].notes.len == 0);
    for ([_]?[]const u8{ null, "", "Unclassified", "English", "Kinyarwanda", "Ikinyarwanda2" }) |owner|
        try std.testing.expect(ownedKinyarwandaNounPart(noun, owner) == null);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &sections, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
    for ([_][]const u8{ "izina", "IZINA", "Izina2", "Izina?", " Izina", "Izina ", "<nowiki>Izina</nowiki>" }) |label| {
        var changed = noun;
        changed.title = label;
        try std.testing.expect(ownedKinyarwandaNounPart(changed, "Ikinyarwanda") == null);
    }
    for ([_]u8{ 2, 4 }) |level| {
        var changed = noun;
        changed.level = level;
        try std.testing.expect(ownedKinyarwandaNounPart(changed, "Ikinyarwanda") == null);
    }
    for (0..6) |case| {
        var changed = noun;
        var heading = [_]wiki.Span{.{ .text = "Izina" }};
        changed.title_spans = &heading;
        switch (case) {
            0 => changed.is_heading = false,
            1 => changed.title_depth = 1,
            2 => changed.title_list_path = "*",
            3 => heading[0].provenance = .protected_literal,
            4 => heading[0].generated_diagnostic = true,
            5 => heading[0].flags.code = true,
            else => unreachable,
        }
        try std.testing.expect(ownedKinyarwandaNounPart(changed, "Ikinyarwanda") == null);
    }
    for (0..11) |case| {
        var changed = noun;
        const changed_blocks = try a.dupe(wiki.Block, body);
        changed.blocks = changed_blocks;
        const headword = try a.dupe(wiki.Span, body[0].spans);
        changed_blocks[0].spans = headword;
        switch (case) {
            0 => headword[0].language = "en",
            1 => headword[0].role = .headword,
            2 => headword[0].flags.bold = false,
            3 => headword[0].generated_diagnostic = true,
            4 => changed_blocks[1].kind = .paragraph,
            5 => changed_blocks[1].list_path = "*",
            6 => changed_blocks[1].depth = 2,
            7 => headword[0].provenance = .protected_literal,
            8 => headword[0].target = "invented",
            9 => headword[0].text = " ",
            10 => changed_blocks[1].spans = &.{.{ .text = "", .generated_diagnostic = true }},
            else => unreachable,
        }
        try std.testing.expect(ownedKinyarwandaNounPart(changed, "Ikinyarwanda") == null);
    }
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun") orelse return error.TestUnexpectedResult);
}

test "RW actual mudasobwa Reader noun organization preserves complete raw body actions styles translations media and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const types = encoder.presentation_types;
    const fixture = @embedFile("testdata/rw-mudasobwa-organization/reader.rw.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqual(@as(usize, 355230), fixture.len);
    try std.testing.expectEqualStrings("b34f143a0fd5e958cea44e6c068186e2c815e19a76b603cfb8c5d2b4218b11e1", &std.fmt.bytesToHex(digest, .lower));
    const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const before = parsed.value.entries[0];
    try std.testing.expectEqualStrings("mudasobwa", before.title);
    try std.testing.expectEqualStrings("Ikinyarwanda", before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("rw", before.language_code);
    try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, before.organization.other_sections);
    const headings = [_][]const u8{ "Ikinyarwanda", "Étymologie", "Izina", "Related terms", "Derived terms", "Gusemura mu ndimi" };
    const levels = [_]u8{ 2, 3, 3, 4, 4, 4 };
    const block_counts = [_]usize{ 4, 1, 2, 2, 5, 1 };
    try std.testing.expectEqual(headings.len, before.sections.len);
    for (before.sections, headings, levels, block_counts) |section, heading, level, count| {
        try std.testing.expectEqualStrings(heading, section.title);
        try std.testing.expectEqual(level, section.level);
        try std.testing.expectEqual(count, section.blocks.len);
    }
    try std.testing.expectEqual(@as(usize, 0), before.references.len);
    try std.testing.expectEqual(@as(usize, 1), before.media.len);
    try std.testing.expectEqualStrings("Wikipedia-logo-v2.svg", before.media[0].file);
    const table = before.sections[5].blocks[0].table orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(usize, 3), table.rows[0].cells.len);
    const raw = @embedFile("testdata/rw-mudasobwa-organization/raw.wikitext");
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    try std.testing.expectEqualStrings("ecfd170d463569feb88df84283972a64c487e7b5813e087bd0edd4d9b0d7ca67", &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expect(std.mem.indexOf(u8, raw, "=== Izina ===\n{{infl|rw|izina}}\n\n# A [[programmable]]") != null);
    try std.testing.expectEqualStrings("=== [[Dosiye:Open_book_01.svg|25px]] Izina ===", @embedFile("testdata/rw-mudasobwa-organization/heading-template.wikitext"));
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("testdata/rw-mudasobwa-organization/nome.wikitext"), "{{-izina-}}\n{{infl|it|noun|m|plural|nomi}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("testdata/rw-mudasobwa-organization/nome.wikitext"), "{{-izina-}}\n{{infl|pt|noun|m|plural|nomes}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("testdata/rw-mudasobwa-organization/nom.wikitext"), "{{-izina-}}\n{{infl|fr|noun||masculine||plural|noms}}") != null);
    const Section = struct {
        title: []const u8, level: u8, blocks: []const wiki.Block,
        is_heading: bool = true, title_depth: u8 = 0, title_list_path: []const u8 = "",
        title_spans: []const wiki.Span = &.{},
    };
    const projected = try std.json.parseFromSlice(struct { entries: []const struct { sections: []const Section } }, a, fixture, .{ .ignore_unknown_fields = true });
    const sections = try a.dupe(Section, projected.value.entries[0].sections);
    // Stored headings have no build-time Span provenance. This projection is
    // explicitly justified by the retained raw headings, not a new expansion.
    for (sections, before.sections) |*section, typed_section| {
        section.title_spans = try a.dupe(wiki.Span, &.{.{ .text = section.title }});
        const blocks = try a.dupe(wiki.Block, section.blocks);
        section.blocks = blocks;
        for (blocks, typed_section.blocks) |*block, typed_block| {
            const spans = try a.dupe(wiki.Span, block.spans);
            block.spans = spans;
            for (spans, typed_block.spans) |*span, typed_span| {
                span.flags = .{ .bold = typed_span.bold, .italic = typed_span.italic, .code = typed_span.code,
                    .small = typed_span.small, .superscript = typed_span.superscript, .subscript = typed_span.subscript,
                    .strike = typed_span.strike, .underline = typed_span.underline };
            }
        }
    }
    const layout = try buildOwned(a, sections, before.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
    const noun = layout.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("Ikinyarwanda", noun.language);
    try std.testing.expectEqual(@as(usize, 2), noun.section);
    // Étymologie remains authored supporting content; this patch does not invent
    // a new etymology mapping or alter any body field while repairing the noun.
    try std.testing.expect(noun.etymology == null);
    try std.testing.expectEqualSlices(usize, &.{0}, noun.introduction);
    try std.testing.expectEqual(@as(usize, 0), noun.other_blocks.len);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4, 5 }, noun.related_sections);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, layout.other_sections);
    try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
    const sense = noun.definitions[0];
    try std.testing.expectEqual(@as(usize, 1), sense.block);
    try std.testing.expect(sense.parent == null and sense.form == null);
    try std.testing.expectEqual(@as(usize, 0), sense.examples.len);
    try std.testing.expect(sense.quotations.len == 0 and sense.notes.len == 0);
    const definition = before.sections[noun.section].blocks[sense.block];
    try std.testing.expect(definition.kind == .definition and definition.depth == 1);
    try std.testing.expectEqualStrings("#", definition.list_path);
    try std.testing.expectEqualStrings("1", definition.number);
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, sections, "English")).lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
    const typed_layout = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
    var expected: types.Stored = .{ .entry = before };
    expected.entry.organization = typed_layout.value;
    const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
    const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "Ikinyarwanda", .code = "rw" });
    try std.testing.expectEqualDeep(expected, decoded);
    try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var restored = decoded;
    restored.entry.organization = before.organization;
    // Every original body/style/action/media/reference and recovery literal is
    // retained, including the independent currentG visual limitations.
    try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
}


test "owned Kurmanji Navder organizes direct noun senses without changing complete body actions styles or codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const F = struct {
        fn compile(allocator: A, source: []const u8, owner: ?[]const u8) !encoder.presentation_types.Stored {
            const label = owner orelse "Unclassified";
            const code: []const u8 = if (std.mem.eql(u8, label, "kurmancî")) "ku" else if (std.mem.eql(u8, label, "English")) "en" else if (std.mem.eql(u8, label, "farisî")) "fa" else "";
            const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
                allocator, "mişk", .language, label, code, document.MissingText.untracked(source),
                null, .{}, null, null, null, .{}, null, null, &.{}, null, &.{},
                if (code.len != 0) .{ .heading = label, .code = code } else null,
            );
            const decoded = try encoder.presentation_codec.decodeAlloc(allocator, bytes, "mişk", .language, .{ .heading = label, .code = code });
            try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(allocator, decoded));
            return decoded;
        }
    };
    const headword = "<div>Related [[Mişk|article]].</div>\n<strong class=\"Latn headword\" lang=ku>mişk</strong>\n";
    const senses = "# [[heywan|Heywanekî]] ''biçûk''.\n#: Kitik ne li mal e.\n# [[amûr|Amûrekî]] [[kompûter]]ê.\n";
    const tail = "==== Werger ====\n* [[mouse]]\n";
    const source = "== Kurmancî ==\n=== Navdêr ===\n" ++ headword ++ senses ++ tail;
    const actual = try F.compile(a, source, "kurmancî");
    try std.testing.expectEqualStrings("ku", actual.entry.language_code);
    try std.testing.expectEqualStrings("kurmancî", actual.entry.language orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), actual.entry.organization.lexemes.len);
    const noun = actual.entry.organization.lexemes[0];
    try std.testing.expectEqualStrings("Noun", noun.kind);
    try std.testing.expectEqualStrings("kurmancî", noun.language);
    try std.testing.expectEqual(@as(usize, 1), noun.section);
    try std.testing.expectEqual(@as(usize, 2), noun.definitions.len);
    var reference = try F.compile(a, "== Kurmancî ==\n=== Noun ===\n" ++ headword ++ senses ++ tail, "kurmancî");
    const sections = try a.dupe(encoder.presentation_types.Section, reference.entry.sections);
    reference.entry.sections = sections;
    sections[1].title = actual.entry.sections[1].title;
    sections[1].anchor = actual.entry.sections[1].anchor;
    sections[1].anchor_fallback = actual.entry.sections[1].anchor_fallback;
    try std.testing.expectEqualDeep(reference, actual);
    try std.testing.expectEqualSlices(u8, try encoder.presentation_codec.encodeAlloc(a, reference), try encoder.presentation_codec.encodeAlloc(a, actual));
    // A localized noun heading does not determine the lexical language.
    for ([_][]const u8{ "English", "farisî" }) |owner| {
        const foreign = try F.compile(a, source, owner);
        try std.testing.expectEqualStrings(owner, foreign.entry.language orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, owner, "English")) "en" else "fa", foreign.entry.language_code);
        try std.testing.expectEqual(@as(usize, 1), foreign.entry.organization.lexemes.len);
        const foreign_noun = foreign.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings("Noun", foreign_noun.kind);
        try std.testing.expectEqualStrings(owner, foreign_noun.language);
        var expected_noun = noun; expected_noun.language = owner;
        try std.testing.expectEqualDeep(expected_noun, foreign_noun);
        try std.testing.expectEqualDeep(actual.entry.sections, foreign.entry.sections);
        try std.testing.expectEqualDeep(actual.entry.media, foreign.entry.media);
        try std.testing.expectEqualDeep(actual.entry.references, foreign.entry.references);
    }
    for ([_]?[]const u8{ null, "", "Unclassified", "Kurmancî", "kurmancî " }) |owner| {
        const foreign = try F.compile(a, source, owner);
        try std.testing.expectEqual(@as(usize, 0), foreign.entry.organization.lexemes.len);
        try std.testing.expectEqualDeep(actual.entry.sections, foreign.entry.sections);
        try std.testing.expectEqualDeep(actual.entry.media, foreign.entry.media);
        try std.testing.expectEqualDeep(actual.entry.references, foreign.entry.references);
    }
    for ([_][]const u8{
        "=== <nowiki>Navdêr</nowiki> ===\n" ++ senses,
        "=== <code>Navdêr</code> ===\n" ++ senses,
        "=== [[Navdêr]] ===\n" ++ senses,
        "==== Navdêr ====\n" ++ senses,
        "=== Navdêrên ===\n" ++ senses,
        "=== navdêr ===\n" ++ senses,
        "=== Navdêr ===\n" ++ headword,
        "=== Navdêr ===\n* Not a definition.\n",
        "=== Navdêr ===\n## Nested definition.\n",
        "=== Navdêr ===\n# <nowiki>protected meaning</nowiki>\n",
        "=== Navdêr ===\n# <code>code meaning</code>\n",
    }) |negative| {
        const result = try F.compile(a, try std.mem.concat(a, u8, &.{ "== Kurmancî ==\n", negative }), "kurmancî");
        try std.testing.expectEqual(@as(usize, 0), result.entry.organization.lexemes.len);
    }
    try std.testing.expect(partOfSpeech("Navdêr") == null);
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Noun") orelse return error.TestUnexpectedResult);
}


test "Croatian body marker after a figure retains one paragraph and excludes captions and scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    var namespaces = try @import("namespace_registry").Registry.init(a, ControlledFigureFixture.namespace_bytes);
    defer namespaces.deinit();
    var styles = try @import("table_style_profile.zig").parseAlloc(a, "");
    defer styles.deinit();
    const input: ControlledFigureFixture = .{ .file = "Example.jpg", .width = 275 };
    const marker = "'''izgovor:'''\n<br>'''definicija:'''<br>\n''imenica''<span>, ''ženski rod''</span>";
    const ending = "\n:(1.1) actual [[sense]]\n'''sinonimi:'''\n:(1.1) support";
    const cases = .{
        .{ "== authored headword ==\n[[File:Example.jpg|thumb|275px|caption]]\n" ++ marker ++ ending, true },
        .{ "== authored headword ==\n[[File:Example.jpg|thumb|275px|'''definicija:'''<br>''imenica'']]\nordinary body" ++ ending, false },
        .{ "== authored headword ==\n[[File:Example.jpg|thumb|275px|caption]]\n<bdi dir=\"ltr\">" ++ marker ++ "</bdi>" ++ ending, false },
    };
    inline for (cases) |case| {
        const payload = try document.compileClassifiedWithHeadingAnchorsAndSourceMediaRootAlloc(
            a, "control", .language, "Independent owner", "en", document.MissingText.untracked(case[0]),
            null, .{}, &namespaces, null, null, .{}, null, null, &.{}, null, &.{},
            .{ .heading = "Independent owner", .code = "en" }, &styles, input.source(&namespaces), .parser_output,
        );
        const stored = try encoder.presentation_codec.decodeAlloc(a, payload, "control", .language, .{ .code = "en", .heading = "Independent owner" });
        try std.testing.expectEqualSlices(u8, payload, try encoder.presentation_codec.encodeAlloc(a, stored));
        try std.testing.expectEqual(@as(usize, 1), stored.entry.media.len);
        try std.testing.expectEqual(@as(usize, 1), ControlledFigureFixture.countBlocks(stored.entry.sections[0].blocks));
        try std.testing.expectEqual(@as(usize, if (case[1]) 1 else 0), stored.entry.organization.lexemes.len);
        if (case[1]) {
            const lexical = stored.entry.organization.lexemes[0];
            try std.testing.expectEqualStrings("Independent owner", lexical.language);
            try std.testing.expectEqualStrings("Noun", lexical.kind);
            try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
            try std.testing.expectEqual(@as(usize, 1), lexical.definitions[0].block);
            try std.testing.expectEqualSlices(usize, &.{0}, lexical.introduction);
            const flow = stored.entry.sections[0].blocks[0].flow.?;
            try std.testing.expectEqual(@as(usize, 2), flow.len);
            try std.testing.expect(flow[0].kind == .figure and flow[1].kind == .@"inline");
            try std.testing.expectEqualStrings("caption", flow[0].figure.?.caption[0].text);
        }
    }
    var renderer: wiki.Renderer = .{ .a = a, .content_root = .parser_output, .context = .{
        .namespace_catalog = &namespaces, .table_styles = &styles, .figure_sizing = input.source(&namespaces),
    } };
    const body = try std.mem.concat(a, u8, &.{ "[[File:Example.jpg|thumb|275px|caption]]\n", marker, ending });
    const blocks = try renderer.renderBody(body);
    try std.testing.expect(croatianParagraphKind(blocks[0]) != null);
    var malformed = blocks[0];
    const parts = try a.dupe(wiki.FlowPart, blocks[0].flow.?);
    malformed.flow = parts;
    parts[0].spans = parts[1].spans;
    try std.testing.expect(croatianParagraphKind(malformed) == null);
    parts[0].spans = &.{};
    parts[0].scope = .{ .mode = .isolate, .resolved_direction = .ltr, .parts = &.{} };
    try std.testing.expect(croatianParagraphKind(malformed) == null);
}

test "TPI Naun noun heading retains independent ownership and refuses imitations and unknown boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    try std.testing.expectEqualStrings("Noun", partOfSpeech("Naun") orelse return error.TestUnexpectedResult);
    for ([_][]const u8{ "naun", "NAUN", "Naun 2", "Naun?", " Naun", "Naun ", "<nowiki>Naun</nowiki>" }) |label|
        try std.testing.expect(partOfSpeech(label) == null);
    var renderer: wiki.Renderer = .{ .a = a, .context = .{} };
    const blocks = try renderer.renderBody("'''eye''' (planti: '''eyes''')\n# [[Ai]]\n#: ''example''\n");
    const S = struct { title: []const u8, level: u8, blocks: []const wiki.Block = &.{} };
    const sections = [_]S{ .{ .title = "Tok Inglis", .level = 2 }, .{ .title = "Naun", .level = 3, .blocks = blocks } };
    for ([_][]const u8{ "Inglis", "Tok Pisin", "Czech", "Independent foreign owner" }) |owner| {
        const layout = try buildOwned(a, &sections, owner);
        try std.testing.expectEqual(@as(usize, 1), layout.lexemes.len);
        const noun = layout.lexemes[0];
        try std.testing.expectEqualStrings(owner, noun.language);
        try std.testing.expectEqualStrings("Noun", noun.kind);
        try std.testing.expectEqual(@as(usize, 1), noun.section);
        try std.testing.expectEqual(@as(usize, 1), noun.definitions.len);
        try std.testing.expectEqual(@as(usize, 1), noun.definitions[0].block);
        try std.testing.expectEqualSlices(usize, &.{2}, noun.definitions[0].examples);
    }
    const unresolved = try buildUnclassified(a, &sections);
    try std.testing.expectEqual(@as(usize, 1), unresolved.lexemes.len);
    try std.testing.expectEqualStrings("", unresolved.lexemes[0].language);
    const ordinary = try renderer.renderBody("Naun\n<nowiki>===Naun===</nowiki>\n");
    const notes = [_]S{.{ .title = "Notes", .level = 3, .blocks = ordinary }};
    try std.testing.expectEqual(@as(usize, 0), (try buildOwned(a, &notes, "Inglis")).lexemes.len);
    const unknown_h2 = [_]S{.{ .title = "Naun", .level = 2, .blocks = blocks }};
    try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &unknown_h2)).lexemes.len);
}

test "TPI retained primary noun contrasts preserve exact source role evidence" {
    const F = struct {
        fn exact(bytes: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    const pes = @embedFile("testdata/tpi-naun/pes.wikitext");
    const bung = @embedFile("testdata/tpi-naun/bung.wikitext");
    const monin = @embedFile("testdata/tpi-naun/monin.wikitext");
    try F.exact(pes, "efa4efa3834b8a7a985b6850b0c245e0c2b7fa47ae78b592aaa08533b210c930");
    try F.exact(bung, "2fbb908a335d592a5f74551aab99fe79dd6e04b8cb6c122f9d23ce67a4dec114");
    try F.exact(monin, "97c261ea0cefbb0302de2cfbc70f7adce2e9c62229b10f752ce30cb0bfe88f7f");
    try std.testing.expect(std.mem.indexOf(u8, pes, "{{-cs-}}\n\n=== Naun ===\n\n'''pes''' ''m''\n\n# [[dok]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, pes, "{{-la-}}\n=== Noun ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, bung, "=== Naun ===\n{{tpi-naun}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, bung, "# '''meeting'''") != null);
    try std.testing.expect(std.mem.indexOf(u8, bung, "=== Verb ===\n{{tpi-verb|i|bungim}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, monin, "===Naun===\n{{tpi-naun}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, monin, "# '''morning'''") != null);
    try std.testing.expect(std.mem.indexOf(u8, monin, "===Interjection===\n{{tpi-greeting}}") != null);
}

const BewTermTest = struct {
    const icon = "OOjs UI icon tag-ltr-progressive.svg";
    fn source(a: A, label: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a,
            "<h3><span style=\"font-weight:normal;font-size:1.4em\">'acicim</span> <sub style=\"color:#888888\">&#91;ami&#93;</sub></h3>\n" ++
            "; <span class=\"section-header-img\">[[File:{s}|12px|link=]]</span>{s}\n# [[asem]]\n", .{ icon, label });
    }
    fn body(a: A, label: []const u8) ![]const wiki.Block {
        // Source-instantiated S/Modul:head structure, using the controlled
        // English File alias. This is not a retained expanded-page capture.
        var namespaces = try @import("namespace_registry").Registry.init(a, ControlledFigureFixture.namespace_bytes);
        defer namespaces.deinit();
        var renderer: wiki.Renderer = .{ .a = a, .context = .{ .title = "'acicim", .namespace_catalog = &namespaces } };
        return renderer.renderBody(try source(a, label));
    }
    fn exact(bytes: []const u8, hash: []const u8) !void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        try std.testing.expectEqualStrings(hash, &std.fmt.bytesToHex(digest, .lower));
    }
};

test "BEW source term roles require independent owner current icon headword and immediate sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ .{ "Kata penyipat", "Adjective" }, .{ "Kata peada", "Noun" } }) |case| {
        const body = try BewTermTest.body(a, case[0]);
        try std.testing.expectEqual(@as(usize, 3), body.len);
        const sections = [_]IsKyOrganizationTest.Section{.{ .title = "'acicim [ami]", .level = 3, .blocks = body }};
        const layout = try buildOwned(a, &sections, "Amis");
        const expected_senses = [_]Sense{.{ .block = 2 }};
        const expected_lexemes = [_]Lexeme{.{ .kind = case[1], .language = "Amis", .section = 0,
            .definitions = &expected_senses, .introduction = &.{ 0, 1 }, .other_blocks = &.{} }};
        try std.testing.expectEqualDeep(Layout{ .lexemes = &expected_lexemes, .other_sections = &.{} }, layout);
        try std.testing.expectEqualStrings("asem", body[2].spans[0].target);
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, &sections)).lexemes.len);
        for ([_]?[]const u8{ null, "", "Unclassified" }) |owner|
            try std.testing.expect(bewTermParagraphPart(body, owner, 3) == null);
        // POS evidence never overrides a separately supplied language.
        try std.testing.expectEqualStrings("Independent owner", (try buildOwned(a, &sections, "Independent owner")).lexemes[0].language);
        try std.testing.expect(bewTermParagraphPart(body, "Amis", 2) == null);
        for (0..18) |negative| {
            const changed = try a.dupe(wiki.Block, body);
            const head = try a.dupe(wiki.Span, body[0].spans); changed[0].spans = head;
            const term = try a.dupe(wiki.Span, body[1].spans); changed[1].spans = term;
            const sense = try a.dupe(wiki.Span, body[2].spans); changed[2].spans = sense;
            var image_index: ?usize = null; var label_index: ?usize = null;
            for (term, 0..) |span, i| {
                if (span.image != null) image_index = i else if (!idTermSpace(span)) label_index = i;
            }
            const ii = image_index orelse return error.TestUnexpectedResult;
            const li = label_index orelse return error.TestUnexpectedResult;
            switch (negative) {
                0 => changed[0].kind = .paragraph,
                1 => head[0].provenance = .protected_literal,
                2 => { for (head) |*span| span.flags.subscript = false; },
                3 => changed[1].kind = .paragraph,
                4 => changed[1].depth = 2,
                5 => term[li].text = "Kata peadaan",
                6 => term[li].provenance = .protected_literal,
                7 => term[li].generated_diagnostic = true,
                8 => term[li].target = "unrelated",
                9 => { var icon = term[ii].image.?; icon.file = "Other.svg"; term[ii].image = icon; },
                10 => { var icon = term[ii].image.?; icon.width_px = 13; term[ii].image = icon; },
                11 => { term[ii].image = null; term[ii].text = BewTermTest.icon; },
                12 => changed[2].kind = .paragraph,
                13 => { changed[2].depth = 2; changed[2].list_path = "##"; },
                14 => sense[0].provenance = .protected_literal,
                15 => { var icon = term[ii].image.?; icon.height_px = 12; term[ii].image = icon; },
                16 => { var icon = term[ii].image.?; icon.border = true; term[ii].image = icon; },
                17 => { var icon = term[ii].image.?; icon.map = .{}; term[ii].image = icon; },
                else => unreachable,
            }
            try std.testing.expect(bewTermParagraphPart(changed, "Amis", 3) == null);
        }
        const support = try a.alloc(wiki.Block, body.len + 2);
        @memcpy(support[0..body.len], body);
        support[3] = .{ .kind = .term, .depth = 1, .list_path = ";", .spans = &.{.{ .text = "Tarjiman" }} };
        support[4] = body[2];
        const marker = bewTermParagraphPart(support, "Amis", 3).?;
        const lexical = try analyzeMarkedParagraph(a, marker, 0, null, support);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, lexical.other_blocks);
    }
    try std.testing.expect(partOfSpeech("Kata peada") == null);
    try std.testing.expect(partOfSpeech("Kata penyipat") == null);
}

test "BEW retained Amis records preserve complete historical graph through scoped term organization and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder"); const types = encoder.presentation_types;
    inline for (.{
        .{ @embedFile("testdata/bew-term/acicim.reader.json"), @embedFile("testdata/bew-term/acicim.raw.wikitext"), "'acicim", "Adjective", "asem", "Kata penyipat" },
        .{ @embedFile("testdata/bew-term/acocol.reader.json"), @embedFile("testdata/bew-term/acocol.raw.wikitext"), "'acocol", "Noun", "gangsing", "Kata peada" },
    }) |case| {
        const parsed = try std.json.parseFromSlice(struct { entries: []const types.Entry }, a, case[0], .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
        const before = parsed.value.entries[0];
        try std.testing.expectEqualStrings(case[2], before.title);
        try std.testing.expectEqualStrings("Amis", before.language orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualStrings("ami", before.language_code);
        try std.testing.expect(std.mem.indexOf(u8, case[1], "=={{basa|ami}}==\n{{pala|ami}}") != null);
        try std.testing.expectEqual(@as(usize, 0), before.organization.lexemes.len);
        try std.testing.expectEqual(@as(usize, 2), before.sections.len);
        try std.testing.expectEqual(@as(usize, 3), before.sections[1].blocks.len);
        try std.testing.expectEqual(@as(usize, 1), before.media.len);
        try std.testing.expectEqualStrings(BewTermTest.icon, before.media[0].file);
        try std.testing.expectEqualStrings(case[4], before.sections[1].blocks[2].spans[0].target);
        const projected = try IsKyOrganizationTest.projected(a, case[0], before);
        const sections = try a.dupe(IsKyOrganizationTest.Section, projected);
        // The old Reader stores an icon as media-class text. Reconstruct ONLY
        // its source-proved modern inline-image view for classifier input;
        // the complete historical Entry below remains unchanged body evidence.
        const blocks = try a.dupe(wiki.Block, sections[1].blocks);
        sections[1].blocks = blocks;
        const spans = try a.dupe(wiki.Span, blocks[1].spans); blocks[1].spans = spans;
        try std.testing.expectEqualStrings(BewTermTest.icon, spans[0].text);
        try std.testing.expect(spans[0].image == null and idTermClass(spans[0].classes, "section-header-img"));
        spans[0].text = ""; spans[0].image = .{ .file = BewTermTest.icon, .width_px = 12 };
        const layout = try buildOwned(a, sections, "Amis");
        const senses = [_]Sense{.{ .block = 2 }};
        const lexemes = [_]Lexeme{.{ .kind = case[3], .language = "Amis", .section = 1,
            .definitions = &senses, .introduction = &.{ 0, 1 }, .other_blocks = &.{} }};
        try std.testing.expectEqualDeep(Layout{ .lexemes = &lexemes, .other_sections = &.{0} }, layout);
        try std.testing.expectEqual(@as(usize, 0), (try buildUnclassified(a, sections)).lexemes.len);
        const typed = try std.json.parseFromSlice(types.Layout, a, try std.json.Stringify.valueAlloc(a, layout, .{}), .{});
        var expected: types.Stored = .{ .entry = before }; expected.entry.organization = typed.value;
        const bytes = try encoder.presentation_codec.encodeAlloc(a, expected);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, before.title, .language, .{ .heading = "Amis", .code = "ami" });
        try std.testing.expectEqualDeep(expected, decoded);
        try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
        var restored = decoded; restored.entry.organization = before.organization;
        try std.testing.expectEqualDeep(types.Stored{ .entry = before }, restored);
    }
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("testdata/bew-term/adj.wikitext"), "Kata penyipat / adjektiva / ''adjective''") != null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("testdata/bew-term/noun.wikitext"), "Kata peada / nomina / ''noun''") != null);

    try BewTermTest.exact(@embedFile("testdata/bew-term/acicim.reader.json"), "148558a32204fd753dfda8fa544efda73a1fd0c1649f86765ef63ba2e3c44edb");
    try BewTermTest.exact(@embedFile("testdata/bew-term/acocol.reader.json"), "723c09d266d158b9cb1ca92fbb1f92d0ccd1c28ec407d006c68c9c452a0994e3");
    try BewTermTest.exact(@embedFile("testdata/bew-term/acicim.raw.wikitext"), "577c41498758a31cc3f3ddb16aa4df6f53c06a9716566b23669250b471352aec");
    try BewTermTest.exact(@embedFile("testdata/bew-term/acocol.raw.wikitext"), "856a79b671b84b25e131ccc67ca37bf2f8d26a8b352180fd3371abc94f6383a4");
    try BewTermTest.exact(@embedFile("testdata/bew-term/adj.wikitext"), "4fee20f7a805a0c5ee5df9ddc5b62d54c491049749d0f4f8024ed458e772247a");
    try BewTermTest.exact(@embedFile("testdata/bew-term/noun.wikitext"), "a8baff96d11c1e2926750a1279d60e3444320953625c5e9a4482a520386575fd");
    try BewTermTest.exact(@embedFile("testdata/bew-term/S.wikitext"), "cbc33b9b1a74a290cb6e56eea264c2e7992ea921fa9e19102f5d73c4294ad636");
    try BewTermTest.exact(@embedFile("testdata/bew-term/head.lua"), "0f97f20a3069ac1daced2ad1be706148b3c6027ab4b6cb5393fc4b7e650c44be");
    const term_source = @embedFile("testdata/bew-term/S.wikitext");
    try std.testing.expect(std.mem.indexOf(u8, term_source, "[[Gepokan:OOjs UI icon tag-ltr-progressive.svg|12px|link=]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, term_source, "|n=Kata peada") != null);
    try std.testing.expect(std.mem.indexOf(u8, term_source, "|adj=Kata penyipat") != null);
}

test "BEW source instantiated current icon body preserves complete compiled graph across independent ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const encoder = @import("blob_encoder");
    const document = @import("presentation_document.zig");
    const F = struct {
        fn compile(allocator: A, text: []const u8, classified: bool) !encoder.presentation_types.Stored {
            var namespaces = try @import("namespace_registry").Registry.init(allocator, ControlledFigureFixture.namespace_bytes);
            defer namespaces.deinit();
            const label: []const u8 = if (classified) "Amis" else "Unclassified";
            const code: []const u8 = if (classified) "ami" else "";
            const bytes = try document.compileClassifiedWithHeadingAnchorsAlloc(
                allocator, "'acicim", .language, label, code, document.MissingText.untracked(text),
                null, .{}, &namespaces, null, null, .{}, null, null, &.{}, null, &.{},
                if (classified) .{ .heading = label, .code = code } else null,
            );
            const decoded = try encoder.presentation_codec.decodeAlloc(allocator, bytes, "'acicim", .language, .{ .heading = label, .code = code });
            try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(allocator, decoded));
            return decoded;
        }
    };
    inline for (.{ .{ "Kata penyipat", "Adjective" }, .{ "Kata peada", "Noun" } }) |case| {
        const text = try BewTermTest.source(a, case[0]);
        const actual = try F.compile(a, text, true);
        const unknown = try F.compile(a, text, false);
        try std.testing.expectEqual(@as(usize, 1), actual.entry.organization.lexemes.len);
        const lexical = actual.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings(case[1], lexical.kind);
        try std.testing.expectEqualStrings("Amis", lexical.language);
        try std.testing.expectEqual(@as(usize, 1), lexical.definitions.len);
        try std.testing.expectEqual(@as(usize, 0), unknown.entry.organization.lexemes.len);
        try std.testing.expectEqual(@as(usize, 1), actual.entry.media.len);
        try std.testing.expectEqualStrings(BewTermTest.icon, actual.entry.media[0].file);
        const sense = actual.entry.sections[lexical.section].blocks[lexical.definitions[0].block];
        try std.testing.expectEqualStrings("asem", sense.spans[0].target);
        var restored = actual;
        restored.entry.language = unknown.entry.language;
        restored.entry.language_code = unknown.entry.language_code;
        restored.entry.organization = unknown.entry.organization;
        try std.testing.expectEqualDeep(unknown, restored);
    }
}
