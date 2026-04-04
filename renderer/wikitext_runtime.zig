const std = @import("std");
const xml_decode = @import("xml_decode.zig");

pub const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

pub fn parseHeadingLine(line: []const u8) ?ParsedHeading {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 4 or trimmed[0] != '=') return null;

    var left: usize = 0;
    while (left < trimmed.len and trimmed[left] == '=') : (left += 1) {}
    if (left < 2 or left > 6) return null;

    var right = trimmed.len;
    while (right > 0 and trimmed[right - 1] == '=') : (right -= 1) {}
    if (trimmed.len - right != left or right <= left) return null;

    const title = std.mem.trim(u8, trimmed[left..right], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(left), .title = title };
}

pub fn isRecognizedPartOfSpeech(title: []const u8) bool {
    return isPartOfSpeechHeading(title);
}

pub fn renderWikitextToOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_len: usize,
) std.mem.Allocator.Error![]const u8 {
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    try renderInline(&rendered, allocator, input);

    const decoded = try xml_decode.decodeAlloc(allocator, rendered.items);
    defer allocator.free(decoded);

    var collapsed: std.ArrayList(u8) = .empty;
    defer collapsed.deinit(allocator);
    try collapseWhitespace(&collapsed, allocator, decoded, max_len);
    return collapsed.toOwnedSlice(allocator);
}

fn renderInline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < input.len) {
        if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "<!--")) {
            const end = std.mem.indexOfPos(u8, input, i + 4, "-->") orelse input.len;
            i = @min(end + 3, input.len);
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<<")) {
            const end = std.mem.indexOfPos(u8, input, i + 2, ">>") orelse break;
            try renderAnglePlaceholder(out, allocator, input[i + 2 .. end]);
            i = end + 2;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            const end = findBalanced(input, i, "{{", "}}") orelse break;
            try renderTemplate(out, allocator, input[i + 2 .. end]);
            i = end + 2;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            const end = findBalanced(input, i, "[[", "]]") orelse break;
            try renderLink(out, allocator, input[i + 2 .. end]);
            i = end + 2;
            continue;
        }
        if (input[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, input, i + 1, ']')) |end| {
                if (std.mem.startsWith(u8, input[i + 1 ..], "http")) {
                    const body = input[i + 1 .. end];
                    if (std.mem.indexOfScalar(u8, body, ' ')) |space| {
                        try renderInline(out, allocator, body[space + 1 ..]);
                    }
                    i = end + 1;
                    continue;
                }
            }
        }
        if (input[i] == '<') {
            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<|")) {
                try appendWithSpace(out, allocator, " < ");
                i += 2;
                continue;
            }
            if (!looksLikeInlineTagStart(input[i..])) {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            }
            if (annotationTagLen(input[i..])) |tag_len| {
                i += tag_len;
                continue;
            }
            if (asciiStartsWithIgnoreCase(input[i..], "<br") or asciiStartsWithIgnoreCase(input[i..], "<hr")) {
                try appendWithSpace(out, allocator, " ");
                i = (std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len) + 1;
                continue;
            }
            if (asciiStartsWithIgnoreCase(input[i..], "<ref")) {
                if (std.mem.indexOfPos(u8, input, i, "</ref>")) |end| {
                    i = end + "</ref>".len;
                    continue;
                }
            }
            if (std.mem.indexOfScalarPos(u8, input, i, '>')) |end| {
                i = end + 1;
                continue;
            }
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }
        if (input[i] == '\'' and i + 1 < input.len and input[i + 1] == '\'') {
            while (i < input.len and input[i] == '\'') : (i += 1) {}
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
}

fn renderLink(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const display = if (parts.items.len >= 2)
        trimWikiWhitespace(parts.items[parts.items.len - 1])
    else
        "";
    const selected = if (display.len != 0)
        display
    else
        normalizedLinkTarget(parts.items[0]);
    if (selected.len == 0) return;
    try renderInline(out, allocator, selected);
}

fn renderTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const name = trimWikiWhitespace(parts.items[0]);

    if (templateMatches(name, "also") or
        templateMatches(name, "commonscat") or
        templateMatches(name, "commons") or
        templateMatches(name, "langcat") or
        templateMatches(name, "interwiktionary") or
        templateMatches(name, "wikispecies") or
        templateMatches(name, "swp") or
        templateMatches(name, "wikiquote") or
        templateMatches(name, "pedia") or
        templateMatches(name, "wikipedia") or
        templateMatches(name, "slim-wikipedia") or
        templateMatches(name, "minitoc") or
        templateMatches(name, "wikidata lexeme") or
        templateMatches(name, "trans-see") or
        templateMatches(name, "senseid") or
        templateMatches(name, "sid") or
        templateMatches(name, "etymid") or
        templateMatches(name, "gbooks") or
        templateMatches(name, "picdic") or
        templateMatches(name, "dercat") or
        templateMatches(name, "cln") or
        templateMatches(name, "English personal pronouns") or
        templateMatches(name, "rfp") or
        templateMatches(name, "rfquote") or
        templateMatches(name, "rfquotek") or
        templateMatches(name, "rfquote-sense") or
        templateMatches(name, "rfex") or
        templateMatches(name, "rfap") or
        templateMatches(name, "rfv-etym") or
        templateMatches(name, "seemoreCites") or
        templateMatches(name, "seeCites") or
        templateMatches(name, "seeSynonyms") or
        templateMatches(name, "checksense") or
        templateMatches(name, "top2") or
        templateMatches(name, "top3") or
        templateMatches(name, "top4") or
        templateMatches(name, "rfc") or
        templateMatches(name, "attn") or
        templateMatches(name, "lookfrom") or
        templateMatches(name, "prefixsee") or
        templateMatches(name, "box-top") or
        templateMatches(name, "box-bottom") or
        templateMatches(name, "multiple images") or
        templateMatches(name, "picdicimg") or
        templateMatches(name, "picdiclabel") or
        templateMatches(name, "elements") or
        templateMatches(name, "wikivoyage"))
    {
        return;
    }
    if (asciiStartsWithIgnoreCase(name, "R:") or asciiStartsWithIgnoreCase(name, "list:")) {
        return;
    }

    if (templateMatches(name, "lb") or templateMatches(name, "lbl") or templateMatches(name, "label")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "qualifier") or templateMatches(name, "q")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "i")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "small")) {
        try appendPositional(out, allocator, &parts, 0, "", "", " ");
        return;
    }
    if (templateMatches(name, "nbsp")) {
        try appendWithSpace(out, allocator, " ");
        return;
    }
    if (templateMatches(name, ",")) {
        try appendWithSpace(out, allocator, ",");
        return;
    }
    if (templateMatches(name, "B.C.E.") or templateMatches(name, "C.E.")) {
        try appendWithSpace(out, allocator, name);
        return;
    }
    if (templateMatches(name, "a") or templateMatches(name, "C")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "U")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "glossary")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "sense")) {
        if (templatePositional(&parts, 0)) |arg| {
            try appendWithSpace(out, allocator, "(");
            try renderInline(out, allocator, arg);
            try appendWithSpace(out, allocator, ") ");
        }
        return;
    }
    if (templateMatches(name, "antsense")) {
        if (templatePositional(&parts, 0)) |arg| {
            try appendWithSpace(out, allocator, "(");
            try renderInline(out, allocator, arg);
            try appendWithSpace(out, allocator, ") ");
        }
        return;
    }
    if (templateMatches(name, "s")) {
        if (templatePositional(&parts, 0)) |arg| {
            try appendWithSpace(out, allocator, "(");
            try renderInline(out, allocator, arg);
            try appendWithSpace(out, allocator, ") ");
        }
        return;
    }
    if (templateMatches(name, "non-gloss") or templateMatches(name, "n-g")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "ng")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "...") or templateMatches(name, "nb...")) {
        try appendWithSpace(out, allocator, "...");
        return;
    }
    if (templateMatches(name, "defdate")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "gloss")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "ux") or templateMatches(name, "uxi") or templateMatches(name, "usex")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "quote")) {
        if (templateNamed(&parts, "passage") orelse templateNamed(&parts, "text") orelse templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| {
            try renderInline(out, allocator, arg);
        }
        return;
    }
    if (asciiStartsWithIgnoreCase(name, "quote-") or std.mem.startsWith(u8, name, "RQ:")) {
        if (templateNamed(&parts, "passage") orelse templateNamed(&parts, "text")) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "syn")) {
        try appendWithSpace(out, allocator, "Synonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "synonyms")) {
        try appendWithSpace(out, allocator, "Synonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ant")) {
        try appendWithSpace(out, allocator, "Antonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "homophone")) {
        try appendWithSpace(out, allocator, "Homophones: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "antonyms")) {
        try appendWithSpace(out, allocator, "Antonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "hyponyms")) {
        try appendWithSpace(out, allocator, "Hyponyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "hypernyms")) {
        try appendWithSpace(out, allocator, "Hypernyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "alt") or templateMatches(name, "alter")) {
        if (templatePositional(&parts, 1)) |arg| try renderInline(out, allocator, arg);
        if (templatePositional(&parts, 2)) |qualifier| {
            const rendered = try renderWikitextToOwned(allocator, qualifier, 128);
            defer allocator.free(rendered);
            if (rendered.len != 0) {
                try appendWithSpace(out, allocator, " (");
                try appendWithSpace(out, allocator, rendered);
                try appendWithSpace(out, allocator, ")");
            }
        }
        return;
    }
    if (templateMatches(name, "lang")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (isSemanticOfTemplate(name)) {
        try renderSemanticOfTemplate(out, allocator, name, &parts);
        return;
    }
    if (templateMatches(name, "head")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| {
            try renderInline(out, allocator, arg);
        }
        return;
    }
    if (templateMatches(name, "enpr")) {
        try appendPositional(out, allocator, &parts, 0, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ipa")) {
        try appendWithSpace(out, allocator, "IPA ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ja-r")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "IPAchar")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "audio")) {
        try appendWithSpace(out, allocator, "audio");
        if (templateNamed(&parts, "a")) |accent| {
            try appendWithSpace(out, allocator, " (");
            try renderInline(out, allocator, accent);
            try appendWithSpace(out, allocator, ")");
        }
        return;
    }
    if (templateMatches(name, "homophones")) {
        try appendWithSpace(out, allocator, "Homophones: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "hyphenation")) {
        try appendPositional(out, allocator, &parts, 1, "", "", "-");
        return;
    }
    if (templateMatches(name, "hyph")) {
        try appendWithSpace(out, allocator, "Hyphenation: ");
        try appendPositional(out, allocator, &parts, 1, "", "", "-");
        return;
    }
    if (templateMatches(name, "compound+") or templateMatches(name, "compound")) {
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "rhymes") or templateMatches(name, "rhyme")) {
        try appendWithSpace(out, allocator, "Rhymes: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "prefix") or
        templateMatches(name, "pre") or
        templateMatches(name, "suffix") or
        templateMatches(name, "suf") or
        templateMatches(name, "compound") or
        templateMatches(name, "com") or
        templateMatches(name, "affix"))
    {
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "root")) {
        if (templatePositional(&parts, 2) orelse templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| {
            try renderInline(out, allocator, arg);
        }
        return;
    }
    if (templateMatches(name, "PIE word")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "taxfmt")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "taxlink")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "number box")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "cot")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "desc") or
        templateMatches(name, "hyper") or
        templateMatches(name, "hypo"))
    {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "hmp")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "examples")) {
        if (templateNamed(&parts, "examples")) |value| {
            try renderInline(out, allocator, value);
            return;
        }
        try appendPositional(out, allocator, &parts, 0, "", "", "; ");
        return;
    }
    if (templateMatches(name, "co") or templateMatches(name, "coi")) {
        try appendPositional(out, allocator, &parts, 1, "", "", "; ");
        return;
    }
    if (templateMatches(name, "place")) {
        try appendPlaceTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "translit") or templateMatches(name, "transliteration")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "smallcaps")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "given name") or templateMatches(name, "surname")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "color panel")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "Latn-def")) {
        try appendPositional(out, allocator, &parts, 1, "", "", " ");
        return;
    }
    if (templateMatches(name, "dbt")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "senseno")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "sic")) {
        try appendWithSpace(out, allocator, "[sic]");
        return;
    }
    if (templateMatches(name, "unc")) {
        try appendWithSpace(out, allocator, "uncertain");
        return;
    }
    if (templateMatches(name, "unk")) {
        try appendWithSpace(out, allocator, "unknown origin");
        return;
    }
    if (templateMatches(name, "etydate")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "coin")) {
        if (templateNamed(&parts, "w") orelse templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| {
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "rootsee")) {
        if (templatePositional(&parts, 2) orelse templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "nearsyn")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "coord") or templateMatches(name, "coordinate terms")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "collocation")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "alti")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "+obj")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ISBN")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "com+")) {
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "blend")) {
        try renderBlendTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "clipping")) {
        try renderUnaryTemplate(out, allocator, &parts, "clipping of");
        return;
    }
    if (templateMatches(name, "back-form")) {
        try renderUnaryTemplate(out, allocator, &parts, "back-formation from");
        return;
    }
    if (templateMatches(name, "confix")) {
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "named-after")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "displaced")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "onomatopoeic")) {
        try appendWithSpace(out, allocator, "onomatopoeic");
        return;
    }
    if (templateMatches(name, "demonym-noun")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "sup")) {
        try appendPositional(out, allocator, &parts, 0, "", "", "");
        return;
    }
    if (templateMatches(name, "etymon")) {
        if (templateNamed(&parts, "text")) |text| {
            try renderInline(out, allocator, text);
            return;
        }
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |fallback| {
            try renderInline(out, allocator, stripTraversalSegments(fallback));
        }
        return;
    }
    if (isEtymologyLexemeTemplate(name)) {
        if (templateEtymologyTerm(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (isDescendantTemplate(name)) {
        if (templateEtymologyTerm(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "alt form")) {
        try appendWithSpace(out, allocator, "alternative form of ");
        if (templateAliasTarget(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "hol")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |arg| try renderInline(out, allocator, stripTraversalSegments(arg));
        return;
    }
    if (templateMatches(name, "ng")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "circa2")) {
        if (templatePositional(&parts, 0)) |year| {
            try appendWithSpace(out, allocator, "c. ");
            try renderInline(out, allocator, year);
        }
        return;
    }
    if (isLexicalTemplate(name)) {
        if (templateLexeme(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (isColumnTemplate(name)) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateNamed(&parts, "passage") orelse templateNamed(&parts, "text")) |arg| {
        try renderInline(out, allocator, arg);
        return;
    }
    if (templatePositional(&parts, positionalCount(&parts) -| 1)) |fallback| {
        try renderInline(out, allocator, fallback);
    }
}

fn renderAnglePlaceholder(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
) std.mem.Allocator.Error!void {
    const trimmed = trimWikiWhitespace(body);
    if (trimmed.len == 0) return;
    const text = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash|
        trimWikiWhitespace(trimmed[slash + 1 ..])
    else
        trimmed;
    try renderInline(out, allocator, text);
}

fn annotationTagLen(input: []const u8) ?usize {
    if (input.len < 4 or input[0] != '<') return null;
    var i: usize = 1;
    const name_start = i;
    while (i < input.len and std.ascii.isAlphanumeric(input[i])) : (i += 1) {}
    if (i == name_start or i >= input.len or input[i] != ':') return null;
    const end = std.mem.indexOfScalarPos(u8, input, i + 1, '>') orelse return null;
    return end + 1;
}

fn looksLikeInlineTagStart(input: []const u8) bool {
    if (input.len < 2 or input[0] != '<') return false;
    const next = input[1];
    return next == '!' or next == '/' or std.ascii.isAlphabetic(next);
}

fn templateLexeme(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, if (positionalCount(parts) >= 2) 1 else 0);
}

fn renderSemanticOfTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, trimWikiWhitespace(name));

    const target_index = semanticTemplateTargetIndex(parts);
    if (templatePositional(parts, target_index)) |arg| {
        try appendWithSpace(out, allocator, " ");
        try renderInline(out, allocator, arg);
    }

    const positional_total = positionalCount(parts);
    var extra_index = target_index + 1;
    var wrote_extra = false;
    while (extra_index < positional_total) : (extra_index += 1) {
        const extra = templatePositional(parts, extra_index) orelse continue;
        const trimmed = trimWikiWhitespace(extra);
        if (trimmed.len == 0 or looksLikeLanguageCode(trimmed)) continue;

        if (!wrote_extra) {
            try appendWithSpace(out, allocator, " (");
            wrote_extra = true;
        } else {
            try appendWithSpace(out, allocator, ", ");
        }
        try renderInline(out, allocator, trimmed);
    }
    if (wrote_extra) try appendWithSpace(out, allocator, ")");
}

fn renderUnaryTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    prefix: []const u8,
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, prefix);
    if (templateAliasTarget(parts)) |arg| {
        try appendWithSpace(out, allocator, " ");
        try renderInline(out, allocator, arg);
    }
}

fn renderBlendTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, "blend of ");
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, " and ");
        try renderInline(out, allocator, segment);
        wrote_any = true;
        positional_index += 1;
    }
}

fn semanticTemplateTargetIndex(parts: *const std.ArrayList([]const u8)) usize {
    const count = positionalCount(parts);
    if (count <= 1) return 0;
    const first = templatePositional(parts, 0) orelse return 0;
    return if (looksLikeLanguageCode(first)) 1 else 0;
}

fn isSemanticOfTemplate(name: []const u8) bool {
    const trimmed = trimWikiWhitespace(name);
    return trimmed.len != 0 and asciiEndsWithIgnoreCase(trimmed, " of");
}

fn looksLikeLanguageCode(value: []const u8) bool {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len < 2 or trimmed.len > 12) return false;

    var has_letter = false;
    for (trimmed) |char| {
        if (std.ascii.isAlphabetic(char)) {
            has_letter = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '-' or char == '_') continue;
        return false;
    }
    return has_letter;
}

fn normalizedLinkTarget(raw_target: []const u8) []const u8 {
    var target = trimWikiWhitespace(raw_target);
    if (target.len != 0 and target[0] == ':') target = trimWikiWhitespace(target[1..]);

    if (std.mem.indexOfScalar(u8, target, '#')) |hash_index| {
        target = if (hash_index == 0)
            target[1..]
        else
            target[0..hash_index];
    }

    if (isHiddenNamespaceTarget(target)) return "";
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon_index| {
        if (colon_index + 1 < target.len) target = target[colon_index + 1 ..];
    }
    return trimWikiWhitespace(target);
}

fn isHiddenNamespaceTarget(target: []const u8) bool {
    const colon_index = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    const namespace = trimWikiWhitespace(target[0..colon_index]);
    return std.ascii.eqlIgnoreCase(namespace, "File") or
        std.ascii.eqlIgnoreCase(namespace, "Image");
}

fn templateEtymologyTerm(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, 2) orelse
        templatePositional(parts, 1) orelse
        templatePositional(parts, 0);
}

fn collapseWhitespace(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    max_len: usize,
) std.mem.Allocator.Error!void {
    out.items.len = 0;
    var pending_space = false;

    for (input) |c| {
        if (out.items.len >= max_len) break;
        switch (c) {
            ' ', '\n', '\r', '\t' => pending_space = true,
            else => {
                if (pending_space and out.items.len != 0) {
                    try out.append(allocator, ' ');
                    if (out.items.len >= max_len) break;
                }
                pending_space = false;
                try out.append(allocator, c);
            },
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
    }
}

fn splitTopLevel(
    allocator: std.mem.Allocator,
    input: []const u8,
    sep: u8,
) std.mem.Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (input[i] == sep and templates == 0 and links == 0) {
            try out.append(allocator, trimWikiWhitespace(input[start..i]));
            start = i + 1;
        }
    }
    try out.append(allocator, trimWikiWhitespace(input[start..]));
    return out;
}

fn findBalanced(input: []const u8, start: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (i + open.len <= input.len and std.mem.eql(u8, input[i .. i + open.len], open)) {
            depth += 1;
            i += open.len - 1;
            continue;
        }
        if (i + close.len <= input.len and std.mem.eql(u8, input[i .. i + close.len], close)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
            i += close.len - 1;
        }
    }
    return null;
}

fn appendWithSpace(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, text);
}

fn appendPositional(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    first_positional: usize,
    prefix: []const u8,
    suffix: []const u8,
    separator: []const u8,
) std.mem.Allocator.Error!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    if (prefix.len != 0) try out.appendSlice(allocator, prefix);
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < first_positional) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, separator);
        try renderInline(out, allocator, segment);
        wrote_any = true;
        positional_index += 1;
    }
    if (suffix.len != 0 and wrote_any) try out.appendSlice(allocator, suffix);
}

fn appendAffixTerms(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, " + ");
        try renderInline(out, allocator, segment);
        wrote_any = true;
        positional_index += 1;
    }
}

fn appendPlaceTerms(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        const piece = normalizePlaceFragment(segment);
        if (piece.len == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, ", ");
        try renderInline(out, allocator, piece);
        wrote_any = true;
        positional_index += 1;
    }

    for ([_][]const u8{ "official", "capital", "located", "located in", "caplc" }) |key| {
        if (templateNamed(parts, key)) |value| {
            const piece = normalizePlaceFragment(value);
            if (piece.len == 0) continue;
            if (wrote_any) try out.appendSlice(allocator, "; ");
            try renderInline(out, allocator, piece);
            wrote_any = true;
        }
    }
}

fn normalizePlaceFragment(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, stripTraversalSegments(input), " \t");
    if (trimmed.len == 0) return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        const prefix = std.mem.trim(u8, trimmed[0..slash], " \t");
        if (prefix.len <= 8 and std.mem.indexOfScalar(u8, prefix, ' ') == null) {
            return std.mem.trim(u8, trimmed[slash + 1 ..], " \t");
        }
    }
    return trimmed;
}

fn stripTraversalSegments(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '>')) |marker| {
        if (marker + 1 < trimmed.len) return std.mem.trim(u8, trimmed[marker + 1 ..], " \t");
    }
    return trimmed;
}

fn templateMatches(name: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(trimWikiWhitespace(name), expected);
}

fn templateArgHasName(segment: []const u8) bool {
    return topLevelEquals(segment) != null;
}

fn topLevelEquals(segment: []const u8) ?usize {
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (segment[i] == '=' and templates == 0 and links == 0) return i;
    }
    return null;
}

fn templateNamed(parts: *const std.ArrayList([]const u8), name: []const u8) ?[]const u8 {
    for (parts.items[1..]) |segment| {
        const equals = topLevelEquals(segment) orelse continue;
        const key = trimWikiWhitespace(segment[0..equals]);
        if (std.ascii.eqlIgnoreCase(key, name)) return trimWikiWhitespace(segment[equals + 1 ..]);
    }
    return null;
}

fn positionalCount(parts: *const std.ArrayList([]const u8)) usize {
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        if (!templateArgHasName(segment)) count += 1;
    }
    return count;
}

fn templatePositional(parts: *const std.ArrayList([]const u8), target: usize) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == target) return trimWikiWhitespace(segment);
        positional_index += 1;
    }
    return null;
}

fn trimWikiWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn isLexicalTemplate(name: []const u8) bool {
    return templateMatches(name, "l") or
        templateMatches(name, "m") or
        templateMatches(name, "m+") or
        templateMatches(name, "link") or
        templateMatches(name, "cog") or
        templateMatches(name, "noncog") or
        templateMatches(name, "af") or
        templateMatches(name, "doublet");
}

fn isEtymologyLexemeTemplate(name: []const u8) bool {
    return templateMatches(name, "inh") or
        templateMatches(name, "inh+") or
        templateMatches(name, "der") or
        templateMatches(name, "der+") or
        templateMatches(name, "bor") or
        templateMatches(name, "bor+") or
        templateMatches(name, "lbor") or
        templateMatches(name, "uder") or
        templateMatches(name, "ncog");
}

fn isDescendantTemplate(name: []const u8) bool {
    return templateMatches(name, "desc") or
        templateMatches(name, "desctree") or
        templateMatches(name, "ubor") or
        templateMatches(name, "calque");
}

fn isColumnTemplate(name: []const u8) bool {
    return templateMatches(name, "col") or
        templateMatches(name, "col2") or
        templateMatches(name, "col3") or
        templateMatches(name, "col4") or
        templateMatches(name, "col5");
}

fn isAliasTemplate(name: []const u8) bool {
    return templateMatches(name, "standard spelling of") or
        templateMatches(name, "standard form of") or
        templateMatches(name, "alternative spelling of") or
        templateMatches(name, "alternative form of") or
        templateMatches(name, "alt form") or
        templateMatches(name, "alt spelling of") or
        templateMatches(name, "dated spelling of") or
        templateMatches(name, "obsolete spelling of") or
        templateMatches(name, "nonstandard spelling of") or
        templateMatches(name, "misspelling of") or
        templateMatches(name, "pronunciation spelling of") or
        templateMatches(name, "pronunciation variant of");
}

fn templateAliasTarget(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const count = positionalCount(parts);
    if (count == 0) return null;
    if (count >= 2) return templatePositional(parts, count - 1);
    return templatePositional(parts, 0);
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
}

fn asciiEndsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return asciiStartsWithIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

fn headingMatches(title: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, title, " \t"), expected);
}

fn headingStartsWith(title: []const u8, prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, title, " \t");
    return asciiStartsWithIgnoreCase(trimmed, prefix);
}

fn isPartOfSpeechHeading(title: []const u8) bool {
    return isCorePartOfSpeechHeading(title) or
        headingMatches(title, "Prepositional phrase") or
        headingMatches(title, "Verb phrase") or
        headingMatches(title, "Proper adjective") or
        headingMatches(title, "Proper nouns") or
        headingStartsWith(title, "Proper noun ") or
        headingMatches(title, "Multiple parts of speech") or
        headingMatches(title, "Abbreviations") or
        headingMatches(title, "Number") or
        headingMatches(title, "Punctuation mark") or
        headingMatches(title, "Diacritical mark") or
        headingMatches(title, "Symbols") or
        headingMatches(title, "Combining form") or
        headingMatches(title, "Verb form") or
        headingMatches(title, "Adverbial phrase") or
        headingMatches(title, "Common nouns") or
        headingMatches(title, "Initialisms") or
        headingMatches(title, "Adjectives") or
        headingMatches(title, "Proper");
}

fn isCorePartOfSpeechHeading(title: []const u8) bool {
    inline for ([_][]const u8{
        "Noun",
        "Proper noun",
        "Verb",
        "Adjective",
        "Adverb",
        "Pronoun",
        "Preposition",
        "Conjunction",
        "Interjection",
        "Determiner",
        "Numeral",
        "Phrase",
        "Article",
        "Abbreviation",
        "Initialism",
        "Symbol",
        "Letter",
        "Contraction",
        "Participle",
        "Particle",
        "Affix",
        "Prefix",
        "Suffix",
        "Infix",
        "Circumfix",
        "Proverb",
        "Idiom",
        "Proper Noun",
    }) |candidate| {
        if (headingMatches(title, candidate)) return true;
    }
    return false;
}

test "parseHeadingLine parses standard headings" {
    const heading = parseHeadingLine("===Noun===") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 3), heading.level);
    try std.testing.expectEqualStrings("Noun", heading.title);
}

test "renderWikitextToOwned strips common wiki markup" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{lb|en|countable}} [[light]]", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("(countable) light", rendered);
}

test "renderWikitextToOwned preserves semantic form-of templates" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{plural of|en|Fresnel reflection}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("plural of Fresnel reflection", rendered);
}

test "renderWikitextToOwned falls back from empty pipe-trick displays" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "[[Fresnel reflection|]]", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Fresnel reflection", rendered);
}

test "renderWikitextToOwned suppresses bare file links" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "[[File:Example.png]]", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
}

test "renderWikitextToOwned preserves literal less-than text" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "month names < English", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("month names < English", rendered);
}

test "renderWikitextToOwned expands alias-style helper templates" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{alt form|en|abb-wool}} and {{back-form|en|abduction}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("alternative form of abb-wool and back-formation from abduction", rendered);
}

test "renderWikitextToOwned supports etymology and place helpers" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "From {{der|en|fro|encloyer}} in {{place|en|country|c/Brazil}} and <<r/Micronesia>>.",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "encloyer") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "country, Brazil") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Micronesia") != null);
}
