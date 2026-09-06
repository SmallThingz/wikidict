//! Native presentation of common Wiktionary templates. This does not invent Lua results.
//! Unknown templates remain explicit; exact source stays in the source view.
const std = @import("std");
const syntax = @import("wiki_syntax.zig");
const Template = syntax.Template;
const Error = std.mem.Allocator.Error || error{RenderLimit};
fn is(name: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(name, choice)) return true;
    return false;
}
fn first(a: []const u8, b: []const u8) []const u8 {
    return if (a.len != 0) a else b;
}
pub fn language(code: []const u8) []const u8 {
    const pairs = .{ .{ "en", "English" }, .{ "fr", "French" }, .{ "de", "German" }, .{ "es", "Spanish" }, .{ "it", "Italian" }, .{ "pt", "Portuguese" }, .{ "la", "Latin" }, .{ "grc", "Ancient Greek" }, .{ "el", "Greek" }, .{ "enm", "Middle English" }, .{ "ang", "Old English" }, .{ "gem-pro", "Proto-Germanic" }, .{ "gmw-pro", "Proto-West Germanic" }, .{ "ine-pro", "Proto-Indo-European" }, .{ "la-lat", "Late Latin" }, .{ "afa", "Afroasiatic" }, .{ "ja", "Japanese" }, .{ "zh", "Chinese" }, .{ "ru", "Russian" }, .{ "ar", "Arabic" }, .{ "nl", "Dutch" }, .{ "non", "Old Norse" } };
    inline for (pairs) |pair| if (std.mem.eql(u8, code, pair[0])) return pair[1];
    return code;
}
fn termLink(p: anytype, label_value: []const u8, target_value: []const u8, style: anytype, depth: usize) Error!void {
    const at = std.mem.indexOfScalar(u8, target_value, '<') orelse {
        try p.link(label_value, target_value, style, depth + 1, false);
        return;
    };
    const modifier = target_value[at..];
    if (!(syntax.starts(modifier, "<q:") or syntax.starts(modifier, "<qq:") or syntax.starts(modifier, "<t:") or syntax.starts(modifier, "<g:") or syntax.starts(modifier, "<tr:") or syntax.starts(modifier, "<alt:"))) {
        try p.link(label_value, target_value, style, depth + 1, false);
        return;
    }
    const base = target_value[0..at];
    var label_text = if (std.mem.eql(u8, label_value, target_value)) base else label_value;
    var pos = at;
    // Alternative display text changes only the visible word, never its target.
    while (pos < target_value.len and target_value[pos] == '<') {
        const end = std.mem.indexOfScalarPos(u8, target_value, pos, '>') orelse break;
        if (syntax.starts(target_value[pos..], "<alt:")) label_text = target_value[pos + 5 .. end];
        pos = end + 1;
    }
    try p.link(label_text, base, style, depth + 1, false);
    pos = at;
    while (pos < target_value.len and target_value[pos] == '<') {
        const end = std.mem.indexOfScalarPos(u8, target_value, pos, '>') orelse break;
        const field = target_value[pos + 1 .. end];
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse break;
        const key = field[0..colon];
        const value = field[colon + 1 ..];
        if (!std.mem.eql(u8, key, "alt")) try label(p, value, style, depth + 1);
        pos = end + 1;
    }
    if (pos < target_value.len) try p.inlineText(target_value[pos..], style, depth + 1);
}
fn join(p: anytype, t: Template, start: usize, sep: []const u8, style: anytype, depth: usize, links: bool) Error!void {
    var written = false;
    if (t.last() < start) return;
    for (start..t.last() + 1) |i| {
        const value = t.get(i);
        if (value.len == 0) continue;
        if (written) try p.text(sep, style);
        if (links) try termLink(p, value, value, style, depth + 1) else try p.inlineText(value, style, depth + 1);
        written = true;
    }
}
fn label(p: anytype, value: []const u8, style: anytype, depth: usize) Error!void {
    if (value.len == 0) return;
    var s = style;
    s.role = .label;
    try p.text(" (", s);
    try p.inlineText(value, s, depth + 1);
    try p.text(")", s);
}
fn word(p: anytype, t: Template, term_index: usize, alt_index: usize, style: anytype, depth: usize) Error!void {
    const target = t.get(term_index);
    const alt = first(t.named("alt"), if (alt_index != 0) t.get(alt_index) else "");
    try termLink(p, first(alt, target), target, style, depth + 1);
    try label(p, t.named("q"), style, depth);
    const gloss = first(t.named("t"), first(t.named("gloss"), if (alt_index != 0) t.get(alt_index + 1) else ""));
    if (gloss.len != 0) {
        try p.text(" (“", style);
        try p.inlineText(gloss, style, depth + 1);
        try p.text("”)", style);
    }
    try label(p, t.named("tr"), style, depth);
}
pub fn render(p: anytype, t: Template, style: anytype, depth: usize) Error!bool {
    const name = t.name;
    if (is(name, &.{ "non-gloss", "non-gloss definition", "ngd" }) and t.get(1).len != 0) {
        var s = style;
        s.italic = true;
        try p.inlineText(t.get(1), s, depth + 1);
        return true;
    }
    if (is(name, &.{ "defdate", "quote-gloss" }) and t.get(1).len != 0) {
        try label(p, t.get(1), style, depth + 1);
        return true;
    }
    if (is(name, &.{ "l", "m", "link", "mention", "ll", "m+" })) {
        if (t.get(2).len == 0 and t.named("alt").len == 0) return false;
        var s = style;
        s.language = t.get(1);
        if (is(name, &.{ "m", "mention", "m+" })) s.italic = true;
        try word(p, t, 2, 3, s, depth);
        return true;
    }
    if (is(name, &.{ "lb", "label", "lbl", "tlb", "term-label", "q", "qualifier", "qual", "i", "a", "accent" })) {
        const start: usize = if (is(name, &.{ "lb", "label", "lbl", "tlb", "term-label" })) 2 else 1;
        var s = style;
        s.role = .label;
        try p.text("(", s);
        try join(p, t, start, ", ", s, depth, false);
        try p.text(")", s);
        return true;
    }
    if (is(name, &.{ "gloss", "sense", "non-gloss definition", "non-gloss", "n-g", "ngd" })) {
        if (t.get(1).len == 0) return false;
        const parens = is(name, &.{ "gloss", "sense" });
        if (parens) try p.text("(", style);
        try p.inlineText(t.get(1), style, depth + 1);
        if (parens) try p.text(")", style);
        return true;
    }
    if (is(name, &.{ "ux", "uxi", "uxa", "usex", "co", "coi", "coa" })) {
        if (t.get(2).len == 0) return false;
        var s = style;
        s.italic = true;
        s.role = .example;
        s.language = t.get(1);
        try p.inlineText(t.get(2), s, depth + 1);
        const translation = first(t.named("translation"), first(t.named("t"), t.get(3)));
        if (translation.len != 0) {
            try p.lineBreak(style);
            try p.inlineText(translation, style, depth + 1);
        }
        try label(p, t.named("tr"), style, depth);
        return true;
    }
    if (is(name, &.{ "quote-text", "quote-book", "quote-web", "quote-journal", "quote-song", "quote-video", "quote-av", "quote-newsgroup", "quote" })) {
        const passage = first(t.named("passage"), first(t.named("text"), t.named("quote")));
        if (passage.len == 0) return false;
        var s = style;
        s.role = .quotation;
        try p.inlineText(passage, s, depth + 1);
        const translation = first(t.named("translation"), t.named("t"));
        if (translation.len != 0) {
            try p.lineBreak(style);
            try p.inlineText(translation, style, depth + 1);
        }
        s = style;
        s.role = .citation;
        s.small = true;
        var any = false;
        inline for (.{ "author", "author2", "title", "work", "year", "date", "page", "pages" }) |field| {
            const value = t.named(field);
            if (value.len != 0) {
                if (!any) try p.lineBreak(s) else try p.text(", ", s);
                if (comptime std.mem.eql(u8, field, "page") or std.mem.eql(u8, field, "pages")) try p.text("p. ", s);
                if (comptime std.mem.eql(u8, field, "title")) {
                    var titled = s;
                    titled.italic = true;
                    if (t.named("url").len != 0) try p.link(value, t.named("url"), titled, depth + 1, true) else try p.inlineText(value, titled, depth + 1);
                } else try p.inlineText(value, s, depth + 1);
                any = true;
            }
        }
        if (any) try p.lineBreak(style);
        return true;
    }
    if (is(name, &.{ "IPA", "IPAchar", "enPR" })) {
        var s = style;
        s.role = .pronunciation;
        const ipa = is(name, &.{"IPA"});
        if (!is(name, &.{"IPAchar"})) try p.text(if (ipa) "IPA: " else "enPR: ", s);
        try join(p, t, if (ipa) 2 else 1, ", ", s, depth, false);
        try label(p, first(t.named("a"), t.named("qual")), style, depth);
        return true;
    }
    if (is(name, &.{"audio"})) {
        if (t.get(2).len == 0) return false;
        const encoded = try p.urlEncode(t.get(2));
        const url = try std.fmt.allocPrint(p.a, "https://commons.wikimedia.org/wiki/Special:FilePath/{s}", .{encoded});
        try p.link(first(t.get(3), first(t.named("text"), "Audio pronunciation")), url, style, depth + 1, true);
        try label(p, t.named("a"), style, depth);
        return true;
    }
    if (is(name, &.{ "hyph", "hyphenation", "rhymes", "hmp", "homophones" })) {
        const hyph = is(name, &.{ "hyph", "hyphenation" });
        try p.text(if (hyph) "Hyphenation: " else if (is(name, &.{"rhymes"})) "Rhymes: " else "Homophones: ", style);
        try join(p, t, 2, if (hyph) "·" else ", ", style, depth, !hyph);
        return true;
    }
    if (is(name, &.{ "alt", "alter", "alternative forms", "syn", "synonyms", "ant", "antonyms", "hyper", "hypo", "hypernyms", "hyponyms" })) {
        if (!is(name, &.{ "alt", "alter", "alternative forms" })) {
            try p.text(if (is(name, &.{ "syn", "synonyms" })) "Synonyms: " else if (is(name, &.{ "ant", "antonyms" })) "Antonyms: " else if (is(name, &.{ "hyper", "hypernyms" })) "Hypernyms: " else "Hyponyms: ", style);
        }
        try join(p, t, 2, ", ", style, depth, true);
        return true;
    }
    if (is(name, &.{ "en-noun", "en-proper noun", "en-verb", "en-adj", "en-adv", "head" })) {
        var s = style;
        s.bold = true;
        s.role = .headword;
        try p.inlineText(first(t.named("head"), p.context.title), s, depth + 1);
        const pos = if (is(name, &.{"head"})) t.get(2) else if (is(name, &.{"en-noun"})) "noun" else if (is(name, &.{"en-proper noun"})) "proper noun" else if (is(name, &.{"en-verb"})) "verb" else if (is(name, &.{"en-adj"})) "adjective" else "adverb";
        try p.text(" · ", style);
        try p.text(pos, style);
        if (is(name, &.{"en-noun"})) {
            const plural = t.get(1);
            if (std.mem.eql(u8, plural, "-")) try label(p, "uncountable", style, depth) else if (std.mem.eql(u8, plural, "~")) try label(p, "countable and uncountable", style, depth) else if (plural.len > 1 and std.mem.indexOfAny(u8, plural, "<>+?~!") == null and !is(plural, &.{"es"})) {
                try p.text(" (plural ", style);
                try p.inlineText(plural, s, depth + 1);
                try p.text(")", style);
            }
        }
        try label(p, t.named("g"), style, depth);
        return true;
    }
    if (is(name, &.{ "infl of", "inflection of" }) and t.get(2).len != 0 and std.mem.eql(u8, t.get(4), "s-verb-form") and t.last() == 4) {
        try p.text("third-person singular simple present indicative of ", style);
        // Parameter 4 is a grammatical tag, not the gloss used by link templates.
        try termLink(p, first(t.named("alt"), first(t.get(3), t.get(2))), t.get(2), style, depth + 1);
        return true;
    }
    const forms = .{ .{ "plural of", "plural of " }, .{ "past of", "past tense of " }, .{ "simple past of", "simple past of " }, .{ "past participle of", "past participle of " }, .{ "present participle of", "present participle of " }, .{ "alternative form of", "alternative form of " }, .{ "alternative spelling of", "alternative spelling of " }, .{ "alt form", "alternative form of " }, .{ "alt sp", "alternative spelling of " }, .{ "synonym of", "synonym of " }, .{ "diminutive of", "diminutive of " }, .{ "abbreviation of", "abbreviation of " }, .{ "initialism of", "initialism of " }, .{ "acronym of", "acronym of " } };
    inline for (forms) |form| if (std.ascii.eqlIgnoreCase(name, form[0])) {
        if (t.get(2).len == 0) return false;
        try p.text(form[1], style);
        try word(p, t, 2, 3, style, depth);
        return true;
    };
    if (is(name, &.{ "inh", "inherited", "bor", "borrowed", "der", "derived", "cog", "cognate", "noncog" })) {
        const cognate = is(name, &.{ "cog", "cognate", "noncog" });
        const lang_index: usize = if (cognate) 1 else 2;
        if (t.get(lang_index).len == 0) return false;
        try p.text(language(t.get(lang_index)), style);
        if (t.get(lang_index + 1).len != 0 and !std.mem.eql(u8, t.get(lang_index + 1), "-")) {
            try p.text(" ", style);
            var s = style;
            s.italic = true;
            s.language = t.get(lang_index);
            try word(p, t, lang_index + 1, lang_index + 2, s, depth);
        }
        return true;
    }
    if (is(name, &.{ "prefix", "suffix", "affix", "compound", "blend", "confix", "doublet" })) {
        try join(p, t, 2, if (is(name, &.{"doublet"})) ", " else " + ", style, depth, true);
        return true;
    }
    if (is(name, &.{ "t", "t+", "t-check", "t+check", "tt", "tt+" })) {
        if (t.get(2).len == 0) return false;
        var s = style;
        s.language = t.get(1);
        try p.link(first(t.named("alt"), t.get(2)), t.get(2), s, depth + 1, false);
        if (t.get(3).len != 0) {
            try p.text(" ", style);
            var g = style;
            g.small = true;
            try join(p, t, 3, ", ", g, depth, false);
        }
        try label(p, t.named("tr"), style, depth);
        return true;
    }
    if (is(name, &.{ "col", "col1", "col2", "col3", "col4", "col5", "col-u", "col1-u", "col2-u", "col3-u", "col4-u", "col5-u", "der2", "der3", "der4", "rel2", "rel3", "rel4" })) {
        try join(p, t, 2, ", ", style, depth, true);
        return true;
    }
    if (is(name, &.{ "trans-top", "checktrans-top" })) {
        var s = style;
        s.bold = true;
        try p.inlineText(t.get(1), s, depth + 1);
        return true;
    }
    if (is(name, &.{ "trans-mid", "trans-bottom", "checktrans-mid", "checktrans-bottom", "top2", "top3", "top4", "bottom", "rhyme-top", "rhyme-bottom", "ws beginlist", "ws endlist", "col-top", "col-bottom", "senseid", "sid", "anchor", "attention" })) return true;
    if (is(name, &.{ "ws", "ws sense", "ws topic" })) {
        try word(p, t, 2, 3, style, depth);
        return true;
    }
    if (is(name, &.{ "w", "wikipedia", "wp", "pedia", "pedialite" })) {
        const title = first(t.get(1), p.context.title);
        const url = try std.fmt.allocPrint(p.a, "https://en.wikipedia.org/wiki/{s}", .{try p.urlEncode(title)});
        try p.link(first(t.get(2), title), url, style, depth + 1, true);
        return true;
    }
    if (is(name, &.{ "taxlink", "taxfmt" })) {
        var s = style;
        s.italic = true;
        try p.inlineText(t.get(1), s, depth + 1);
        return true;
    }
    if (is(name, &.{ "small", "smallcaps", "sc", "sup", "sub", "monospace", "nowrap" })) {
        var s = style;
        if (is(name, &.{"small"})) s.small = true;
        if (is(name, &.{"sup"})) s.superscript = true;
        if (is(name, &.{"sub"})) s.subscript = true;
        if (is(name, &.{"monospace"})) s.code = true;
        try p.inlineText(t.get(1), s, depth + 1);
        return true;
    }
    if (is(name, &.{"defdate"})) {
        try p.text("[since ", style);
        try join(p, t, 1, ", ", style, depth, false);
        try p.text("]", style);
        return true;
    }
    if (is(name, &.{"quote-gloss"})) {
        try p.text("[", style);
        try p.inlineText(t.get(1), style, depth + 1);
        try p.text("]", style);
        return true;
    }
    if (is(name, &.{"nb..."})) {
        try p.text("…", style);
        return true;
    }
    if (is(name, &.{"reconstructed"})) {
        var s = style;
        s.role = .label;
        try p.text("Reconstructed form", s);
        return true;
    }
    if (is(name, &.{ "was wotd", "was fwotd" })) return true;
    if (is(name, &.{"!"})) {
        try p.text("|", style);
        return true;
    }
    if (is(name, &.{"="})) {
        try p.text("=", style);
        return true;
    }
    if (is(name, &.{ "PAGENAME", "FULLPAGENAME" })) {
        try p.text(p.context.title, style);
        return true;
    }
    return false;
}
