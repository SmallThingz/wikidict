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
            var trail_end = end + 2;
            while (trail_end < input.len and isWikiLinkTrailByte(input[trail_end])) : (trail_end += 1) {}
            try renderLink(out, allocator, input[i + 2 .. end], input[end + 2 .. trail_end]);
            i = trail_end;
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
            const tag_end = std.mem.indexOfScalarPos(u8, input, i, '>');
            if (tag_end) |end| {
                if (htmlTagName(input[i .. end + 1])) |tag_name| {
                    if (!isAllowedInlineHtmlTagName(tag_name) and !hasMatchingClosingTag(input[end + 1 ..], tag_name)) {
                        const placeholder = trimAnglePlaceholderText(input[i + 1 .. end]);
                        if (placeholder.len != 0) try renderInline(out, allocator, placeholder);
                        i = end + 1;
                        continue;
                    }
                }
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
            const run_start = i;
            while (i < input.len and input[i] == '\'') : (i += 1) {}
            if (shouldKeepLiteralApostrophe(input, run_start, i - run_start)) {
                try out.append(allocator, '\'');
            }
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
    trail: []const u8,
) std.mem.Allocator.Error!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const display = if (parts.items.len >= 2)
        trimWikiWhitespace(parts.items[parts.items.len - 1])
    else
        "";
    const base_selected = if (display.len != 0)
        display
    else
        normalizedLinkTarget(parts.items[0]);
    const selected = if (trail.len == 0)
        base_selected
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_selected, trail });
    defer if (trail.len != 0) allocator.free(selected);
    if (selected.len == 0) return;
    try renderInline(out, allocator, selected);
}

fn shouldKeepLiteralApostrophe(input: []const u8, run_start: usize, run_len: usize) bool {
    if ((run_len & 1) == 0) return false;
    if (run_start == 0 or run_start + run_len >= input.len) return false;
    return isLiteralApostropheNeighbor(input[run_start - 1]) and isLiteralApostropheNeighbor(input[run_start + run_len]);
}

fn isLiteralApostropheNeighbor(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte);
}

fn isWikiLinkTrailByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte);
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
        templateMatches(name, "rfv-pron") or
        templateMatches(name, "rfv-etym") or
        templateMatches(name, "rfv-sense") or
        templateMatches(name, "seemoreCites") or
        templateMatches(name, "seeCites") or
        templateMatches(name, "seeSynonyms") or
        templateMatches(name, "checksense") or
        templateMatches(name, "etystub") or
        templateMatches(name, "langlist") or
        templateMatches(name, "comcatlite") or
        templateMatches(name, "coefficient") or
        templateMatches(name, "commons cat") or
        templateMatches(name, "ethnologue") or
        templateMatches(name, "ISO 639") or
        templateMatches(name, "in appendix") or
        templateMatches(name, "langindex") or
        templateMatches(name, "no entry") or
        templateMatches(name, "phrasebook") or
        templateMatches(name, "rfdef") or
        templateMatches(name, "rfc-sense") or
        templateMatches(name, "rfclarify") or
        templateMatches(name, "rfd-sense") or
        templateMatches(name, "rfdate") or
        templateMatches(name, "rfref") or
        templateMatches(name, "season name spelling") or
        templateMatches(name, "see desc") or
        templateMatches(name, "specieslite") or
        templateMatches(name, "suffixsee") or
        templateMatches(name, "tea room") or
        templateMatches(name, "top2") or
        templateMatches(name, "top3") or
        templateMatches(name, "top4") or
        templateMatches(name, "bottom") or
        templateMatches(name, "rfc") or
        templateMatches(name, "attn") or
        templateMatches(name, "lookfrom") or
        templateMatches(name, "prefixsee") or
        templateMatches(name, "box-top") or
        templateMatches(name, "box-bottom") or
        templateMatches(name, "center top") or
        templateMatches(name, "center bottom") or
        templateMatches(name, "emojipic") or
        templateMatches(name, "img") or
        templateMatches(name, "letter_disp2") or
        templateMatches(name, "merge") or
        templateMatches(name, "multiple image") or
        templateMatches(name, "multiple images") or
        templateMatches(name, "arithmetic operations") or
        templateMatches(name, "gbooks") or
        templateMatches(name, "J2G") or
        templateMatches(name, "nyms") or
        templateMatches(name, "table:xiangqi pieces/en") or
        templateMatches(name, "wikinews") or
        templateMatches(name, "picdicimg") or
        templateMatches(name, "picdiclabel") or
        templateMatches(name, "elements") or
        templateMatches(name, "wikibooks") or
        templateMatches(name, "wikiversity") or
        templateMatches(name, "wikiversity lecture") or
        templateMatches(name, "Webster 1913") or
        templateMatches(name, "wikivoyage"))
    {
        return;
    }
    if (asciiStartsWithIgnoreCase(name, "list:")) {
        if (try renderKnownListTemplate(out, allocator, name)) return;
    }

    if (asciiStartsWithIgnoreCase(name, "R:") or
        asciiStartsWithIgnoreCase(name, "table:") or
        asciiStartsWithIgnoreCase(name, "U:") or
        asciiStartsWithIgnoreCase(name, "Wiktionary:"))
    {
        return;
    }

    if (templateMatches(name, "lb") or templateMatches(name, "lbl") or templateMatches(name, "label")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "qualifier") or templateMatches(name, "q") or templateMatches(name, "qual")) {
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
    if (templateMatches(name, "gl")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
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
    if (templateMatches(name, "...") or templateMatches(name, "nb...") or templateMatches(name, "…")) {
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
    if (templateMatches(name, "gl")) {
        if (templatePositional(&parts, 0)) |arg| {
            try appendWithSpace(out, allocator, "(");
            try renderInline(out, allocator, arg);
            try appendWithSpace(out, allocator, ")");
        }
        return;
    }
    if (templateMatches(name, "frac")) {
        try appendPositional(out, allocator, &parts, 0, "", "", "/");
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
        try renderHomophoneTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "antonyms")) {
        try appendWithSpace(out, allocator, "Antonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "troponyms")) {
        try appendWithSpace(out, allocator, "Troponyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "antonym")) {
        try appendWithSpace(out, allocator, "Antonyms: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "nearsyn")) {
        try appendWithSpace(out, allocator, "Near synonyms: ");
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
        var tail_segments: [8][]const u8 = undefined;
        var tail_len: usize = 0;
        var positional_index: usize = 0;
        for (parts.items[1..]) |segment| {
            if (templateArgHasName(segment)) continue;
            if (positional_index <= 1) {
                positional_index += 1;
                continue;
            }
            positional_index += 1;
            if (tail_len < tail_segments.len) {
                tail_segments[tail_len] = trimWikiWhitespace(segment);
                tail_len += 1;
            }
        }

        const split_index = alterQualifierSplitIndex(tail_segments[0..tail_len]);
        for (tail_segments[0..split_index]) |term| {
            if (term.len == 0) continue;
            try appendWithSpace(out, allocator, ", ");
            try renderInline(out, allocator, term);
        }

        var wrote_qualifier = false;
        for (tail_segments[split_index..tail_len]) |qualifier| {
            if (qualifier.len == 0) continue;
            const rendered = try renderWikitextToOwned(allocator, qualifier, 128);
            defer allocator.free(rendered);
            if (rendered.len == 0) continue;

            if (!wrote_qualifier) {
                try appendWithSpace(out, allocator, " (");
                wrote_qualifier = true;
            } else {
                try appendWithSpace(out, allocator, ", ");
            }
            try appendWithSpace(out, allocator, rendered);
        }
        if (wrote_qualifier) try appendWithSpace(out, allocator, ")");
        return;
    }
    if (templateMatches(name, "lang")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "alt case")) {
        try appendWithSpace(out, allocator, "alternative case form of ");
        if (templateAliasTarget(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "alt sp") or templateMatches(name, "altform")) {
        try appendWithSpace(out, allocator, "alternative form of ");
        if (templateAliasTarget(&parts)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "q-g")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "qf") or templateMatches(name, "as")) {
        try appendPositional(out, allocator, &parts, 0, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "1") or templateMatches(name, "bad")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "good")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
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
        if (templateNamed(&parts, "a")) |accent| {
            try appendWithSpace(out, allocator, "(");
            try renderInline(out, allocator, accent);
            try appendWithSpace(out, allocator, ") ");
        }
        try appendWithSpace(out, allocator, "enPR: ");
        try appendPositional(out, allocator, &parts, 0, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ipa")) {
        if (templateNamed(&parts, "a")) |accent| {
            try appendWithSpace(out, allocator, "(");
            try renderInline(out, allocator, accent);
            try appendWithSpace(out, allocator, ") ");
        }
        try appendWithSpace(out, allocator, "IPA: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "IPA letters")) {
        try appendPositional(out, allocator, &parts, 1, "", "", " ");
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
        try appendWithSpace(out, allocator, "Audio");
        if (templateNamed(&parts, "a")) |accent| {
            try appendWithSpace(out, allocator, " (");
            try renderInline(out, allocator, accent);
            try appendWithSpace(out, allocator, ")");
        }
        return;
    }
    if (templateMatches(name, "homophones")) {
        try renderHomophoneTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "hyphenation")) {
        try renderHyphenationTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "hyph")) {
        try renderHyphenationTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "compound+") or templateMatches(name, "compound")) {
        try renderCompoundTemplate(out, allocator, name, &parts);
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
        templateMatches(name, "af") or
        templateMatches(name, "compound") or
        templateMatches(name, "com") or
        templateMatches(name, "affix"))
    {
        try appendAffixTerms(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "root")) {
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
    if (templateMatches(name, "holo")) {
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
    if (templateMatches(name, "demonym-adj")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
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
    if (templateMatches(name, "small caps")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "given name")) {
        try appendNominalTemplate(out, allocator, &parts, "given name");
        return;
    }
    if (templateMatches(name, "surname")) {
        try appendNominalTemplate(out, allocator, &parts, "surname");
        return;
    }
    if (templateMatches(name, "short for")) {
        try renderUnaryTemplate(out, allocator, &parts, "short for");
        return;
    }
    if (templateMatches(name, "&lit")) {
        try appendWithSpace(out, allocator, "literally ");
        try appendPositional(out, allocator, &parts, 1, "", "", " + ");
        return;
    }
    if (templateMatches(name, "post")) {
        try appendPositional(out, allocator, &parts, 0, "(post-", ")", ", ");
        return;
    }
    if (templateMatches(name, "attention")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "color panel")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "colour panel")) {
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
    if (templateMatches(name, "anchor")) {
        return;
    }
    if (templateMatches(name, "senseno")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| {
            const trimmed = trimWikiWhitespace(value);
            if (!looksLikeOpaqueSenseId(trimmed)) try renderInline(out, allocator, trimmed);
        }
        return;
    }
    if (templateMatches(name, "section link")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "sic") or templateMatches(name, "SIC")) {
        try appendWithSpace(out, allocator, "[sic]");
        return;
    }
    if (templateMatches(name, "'")) {
        try appendWithSpace(out, allocator, "'");
        return;
    }
    if (templateMatches(name, "frac")) {
        try renderFractionTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "sub")) {
        try appendPositional(out, allocator, &parts, 0, "", "", "");
        return;
    }
    if (templateMatches(name, "unc")) {
        try appendWithSpace(out, allocator, "uncertain");
        return;
    }
    if (templateMatches(name, "uncertain")) {
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
    if (templateMatches(name, "circa") or templateMatches(name, "c.")) {
        if (templatePositional(&parts, 0)) |value| {
            try appendWithSpace(out, allocator, "c. ");
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "ante")) {
        if (templatePositional(&parts, 0)) |value| {
            try appendWithSpace(out, allocator, "before ");
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "century")) {
        try appendPositional(out, allocator, &parts, 0, "", " century", " to ");
        return;
    }
    if (templateMatches(name, "coin")) {
        if (templateNamed(&parts, "w") orelse templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| {
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "coinage")) {
        if (templateNamed(&parts, "w") orelse firstUsefulCoinageArg(&parts)) |value| {
            try appendWithSpace(out, allocator, "coined by ");
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "piecewise doublet")) {
        try appendWithSpace(out, allocator, "doublets: ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
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
    if (templateMatches(name, "nsyn")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "coord") or templateMatches(name, "coordinate terms")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "topics")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "tlb")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "collocation")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "mer") or
        templateMatches(name, "mero") or
        templateMatches(name, "meronyms") or
        templateMatches(name, "comeronyms") or
        templateMatches(name, "holonyms"))
    {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "alti")) {
        try renderAlternativeFormsTemplate(out, allocator, &parts);
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
        try renderCompoundTemplate(out, allocator, name, &parts);
        return;
    }
    if (templateMatches(name, "blend")) {
        try renderBlendTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "alt sp")) {
        try renderUnaryTemplate(out, allocator, &parts, "alternative spelling of");
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
    if (templateMatches(name, "cal") or templateMatches(name, "learned borrowing")) {
        if (templateEtymologyTerm(&parts)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "clq") or templateMatches(name, "pcal") or templateMatches(name, "semantic loan") or templateMatches(name, "sl")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "derived") or templateMatches(name, "borrowed") or templateMatches(name, "inherited")) {
        if (templateEtymologyTerm(&parts)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "word")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "m-g")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
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
    if (templateMatches(name, "obs form")) {
        try renderUnaryTemplate(out, allocator, &parts, "obsolete form of");
        return;
    }
    if (templateMatches(name, "acronym")) {
        try renderUnaryTemplate(out, allocator, &parts, "acronym of");
        return;
    }
    if (templateMatches(name, "abbrev")) {
        try renderUnaryTemplate(out, allocator, &parts, "abbreviation of");
        return;
    }
    if (templateMatches(name, "alt spell")) {
        try renderUnaryTemplate(out, allocator, &parts, "alternative spelling of");
        return;
    }
    if (templateMatches(name, "contraction")) {
        try renderUnaryTemplate(out, allocator, &parts, "contraction of");
        return;
    }
    if (templateMatches(name, "back-formation")) {
        try renderUnaryTemplate(out, allocator, &parts, "back-formation from");
        return;
    }
    if (templateMatches(name, "clip")) {
        try renderUnaryTemplate(out, allocator, &parts, "clipping of");
        return;
    }
    if (templateMatches(name, "term-label")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "zh-m")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "zh-l")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "sup")) {
        try appendPositional(out, allocator, &parts, 0, "", "", "");
        return;
    }
    if (templateMatches(name, "big")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "smc")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "long s")) {
        try appendWithSpace(out, allocator, "s");
        return;
    }
    if (templateMatches(name, "!")) {
        try appendWithSpace(out, allocator, "|");
        return;
    }
    if (templateMatches(name, "nowrap") or templateMatches(name, "monospace") or templateMatches(name, "angbr")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "upright")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "listen")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "inline alt forms")) {
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "ll")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "tcl")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "PAGENAME") or templateMatches(name, "nonlemma")) {
        return;
    }
    if (templateMatches(name, "mdash")) {
        try appendWithSpace(out, allocator, " - ");
        return;
    }
    if (templateMatches(name, "c.")) {
        if (templatePositional(&parts, 0)) |value| {
            try appendWithSpace(out, allocator, "c. ");
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "etymon")) {
        return;
    }
    if (isEtymologyLexemeTemplate(name)) {
        try renderEtymologyLexemeTemplate(out, allocator, name, &parts);
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
    if (templateMatches(name, "prefixusex")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "transterm")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (isLexicalTemplate(name)) {
        try appendLexemeTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "surf")) {
        try appendWithSpace(out, allocator, "By surface analysis, ");
        try appendPositional(out, allocator, &parts, 1, "", "", " + ");
        return;
    }
    if (templateMatches(name, "doublet")) {
        try appendWithSpace(out, allocator, "Doublet of ");
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
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

fn renderKnownListTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) std.mem.Allocator.Error!bool {
    const trimmed = trimWikiWhitespace(name);
    if (!asciiStartsWithIgnoreCase(trimmed, "list:")) return false;
    const list_name = trimWikiWhitespace(trimmed["list:".len..]);

    if (std.ascii.eqlIgnoreCase(list_name, "units of time/en")) {
        try appendKnownList(out, allocator, &.{
            "attosecond",
            "century",
            "day",
            "decade",
            "femtosecond",
            "hour",
            "instant",
            "microsecond",
            "millennium",
            "millisecond",
            "minute",
            "moment",
            "month",
            "nanosecond",
            "picosecond",
            "second",
            "week",
            "year",
            "yoctosecond",
            "zeptosecond",
        });
        return true;
    }

    return false;
}

fn appendKnownList(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    values: []const []const u8,
) std.mem.Allocator.Error!void {
    var first = true;
    for (values) |value| {
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        try out.appendSlice(allocator, value);
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

fn htmlTagName(input: []const u8) ?[]const u8 {
    if (input.len < 3 or input[0] != '<') return null;
    var i: usize = 1;
    if (i < input.len and input[i] == '/') i += 1;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    const start = i;
    while (i < input.len and std.ascii.isAlphanumeric(input[i])) : (i += 1) {}
    if (i == start) return null;
    return input[start..i];
}

fn isAllowedInlineHtmlTagName(tag_name: []const u8) bool {
    inline for ([_][]const u8{
        "b",
        "big",
        "blockquote",
        "br",
        "center",
        "cite",
        "code",
        "div",
        "em",
        "h1",
        "hiero",
        "hr",
        "i",
        "kbd",
        "math",
        "nowiki",
        "p",
        "ref",
        "s",
        "samp",
        "section",
        "small",
        "span",
        "strong",
        "sub",
        "sup",
        "table",
        "tbody",
        "td",
        "tfoot",
        "th",
        "thead",
        "tr",
        "u",
        "var",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(tag_name, candidate)) return true;
    }
    return false;
}

fn hasMatchingClosingTag(input: []const u8, tag_name: []const u8) bool {
    var pattern_buf: [64]u8 = undefined;
    if (tag_name.len + 3 > pattern_buf.len) return false;
    pattern_buf[0] = '<';
    pattern_buf[1] = '/';
    @memcpy(pattern_buf[2 .. 2 + tag_name.len], tag_name);
    pattern_buf[2 + tag_name.len] = '>';
    return std.mem.indexOf(u8, input, pattern_buf[0 .. tag_name.len + 3]) != null;
}

fn trimAnglePlaceholderText(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t/");
}

fn templateLexeme(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, if (positionalCount(parts) >= 2) 1 else 0);
}

fn appendLexemeTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const term = templateLexeme(parts) orelse return;
    if (isPlaceholderTemplateTerm(term)) {
        if (templatePositional(parts, 0)) |code| {
            if (languageDisplay(code)) |display| try appendWithSpace(out, allocator, display);
        }
        return;
    }
    try renderInline(out, allocator, term);

    const translit = templateNamed(parts, "tr");
    const gloss = templateNamed(parts, "t") orelse templateNamed(parts, "gloss") orelse templateLexemeGloss(parts);
    const literal = templateNamed(parts, "lit");
    if (translit == null and gloss == null and literal == null) return;

    try appendWithSpace(out, allocator, " (");
    if (translit) |value| {
        try renderInline(out, allocator, value);
        if (gloss != null or literal != null) try appendWithSpace(out, allocator, ", ");
    }
    if (gloss) |value| try renderInline(out, allocator, value);
    if (literal) |value| {
        if (gloss != null) try appendWithSpace(out, allocator, ", ");
        try appendWithSpace(out, allocator, "literally ");
        try appendWithSpace(out, allocator, "\"");
        try renderInline(out, allocator, value);
        try appendWithSpace(out, allocator, "\"");
    }
    try appendWithSpace(out, allocator, ")");
}

fn templateLexemeGloss(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const count = positionalCount(parts);
    if (count < 4) return null;
    const bridge = templatePositional(parts, 2) orelse "";
    if (trimWikiWhitespace(bridge).len != 0) return null;
    return templatePositional(parts, 3);
}

fn renderEtymologyLexemeTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const source_language = templatePositional(parts, 1);
    const term = templateEtymologyTerm(parts) orelse return;
    const has_term = !isPlaceholderTemplateTerm(term);

    if (templateMatches(name, "bor+") or templateMatches(name, "borrowed")) {
        try appendWithSpace(out, allocator, "borrowed from ");
    } else if (templateMatches(name, "inh+") or templateMatches(name, "inherited")) {
        try appendWithSpace(out, allocator, "inherited from ");
    } else if (templateMatches(name, "der+") or templateMatches(name, "derived") or templateMatches(name, "uder")) {
        try appendWithSpace(out, allocator, "derived from ");
    }

    if (source_language) |code| {
        if (languageDisplay(code)) |display| {
            try appendWithSpace(out, allocator, display);
            if (has_term) try appendWithSpace(out, allocator, " ");
        }
    }
    if (has_term) try renderInline(out, allocator, term);

    const translit = if (has_term) templateNamed(parts, "tr") else null;
    const gloss = templateNamed(parts, "t") orelse
        templateNamed(parts, "gloss") orelse
        templateEtymologyGloss(parts) orelse
        templateTrailingGloss(parts, term);
    const literal = if (has_term) templateNamed(parts, "lit") else null;
    if (translit != null or gloss != null or literal != null) {
        try appendWithSpace(out, allocator, " (");
        if (translit) |value| {
            try renderInline(out, allocator, value);
            if (gloss != null or literal != null) try appendWithSpace(out, allocator, ", ");
        }
        if (gloss) |value| try renderInline(out, allocator, value);
        if (literal) |value| {
            if (gloss != null) try appendWithSpace(out, allocator, ", ");
            try appendWithSpace(out, allocator, "literally ");
            try appendWithSpace(out, allocator, "\"");
            try renderInline(out, allocator, value);
            try appendWithSpace(out, allocator, "\"");
        }
        try appendWithSpace(out, allocator, ")");
    }
}

fn templateEtymologyGloss(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const count = positionalCount(parts);
    if (count < 5) return null;
    const bridge = templatePositional(parts, 3) orelse "";
    if (trimWikiWhitespace(bridge).len != 0) return null;
    return templatePositional(parts, 4);
}

fn templateTrailingGloss(parts: *const std.ArrayList([]const u8), term: []const u8) ?[]const u8 {
    if (isPlaceholderTemplateTerm(term)) return null;
    const count = positionalCount(parts);
    if (count <= 2) return null;
    const candidate = templatePositional(parts, count - 1) orelse return null;
    const trimmed = trimWikiWhitespace(candidate);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, trimWikiWhitespace(term)) or looksLikeLanguageCode(trimmed)) return null;
    return trimmed;
}

fn renderSemanticOfTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    if (templateMatches(name, "infl of") or templateMatches(name, "inflection of")) {
        if (try renderInflectionTemplate(out, allocator, parts)) return;
    }

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

fn renderInflectionTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!bool {
    const target_index = semanticTemplateTargetIndex(parts);
    const target = templatePositional(parts, target_index) orelse return false;

    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);

    var extra_index = target_index + 1;
    while (extra_index < positionalCount(parts)) : (extra_index += 1) {
        const extra = templatePositional(parts, extra_index) orelse continue;
        const trimmed = trimWikiWhitespace(extra);
        if (trimmed.len == 0 or (looksLikeLanguageCode(trimmed) and !isRecognizedInflectionTag(trimmed))) continue;
        try tags.append(allocator, trimmed);
    }

    const phrase = formatInflectionTags(tags.items) orelse return false;
    try appendWithSpace(out, allocator, phrase);
    try appendWithSpace(out, allocator, " of ");
    try renderInline(out, allocator, target);
    return true;
}

fn formatInflectionTags(tags: []const []const u8) ?[]const u8 {
    if (tags.len == 1) {
        if (std.ascii.eqlIgnoreCase(tags[0], "s-verb-form")) return "third-person singular simple present indicative";
        if (std.ascii.eqlIgnoreCase(tags[0], "spast")) return "simple past";
    }
    return null;
}

fn isRecognizedInflectionTag(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "s-verb-form") or std.ascii.eqlIgnoreCase(tag, "spast");
}

fn renderUnaryTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    prefix: []const u8,
) std.mem.Allocator.Error!void {
    const target = templateAliasTarget(parts);
    if (target == null or looksLikeLanguageCode(trimWikiWhitespace(target.?))) {
        try appendWithSpace(out, allocator, standaloneUnaryPrefix(prefix));
        return;
    }
    try appendWithSpace(out, allocator, prefix);
    if (target) |arg| {
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

const TrailingQualifier = struct {
    term: []const u8,
    qualifier: ?[]const u8 = null,
};

fn renderAlternativeFormsTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, "Alternative forms: ");
    var positional_index: usize = 0;
    var wrote_any = false;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const parsed = splitTrailingQualifier(segment);
        if (parsed.term.len == 0) continue;
        if (wrote_any) try appendWithSpace(out, allocator, ", ");
        wrote_any = true;
        if (parsed.qualifier) |qualifier| {
            try appendWithSpace(out, allocator, "(");
            try appendWithSpace(out, allocator, qualifier);
            try appendWithSpace(out, allocator, ") ");
        }
        try renderInline(out, allocator, parsed.term);
    }
}

fn alterQualifierSplitIndex(segments: []const []const u8) usize {
    for (segments, 0..) |segment, i| {
        if (segment.len == 0) return i + 1;
    }

    var nonempty: usize = 0;
    for (segments) |segment| {
        if (segment.len != 0) nonempty += 1;
    }
    if (nonempty <= 1) return segments.len;

    var trailing_qualifiers: usize = 0;
    var i = segments.len;
    while (i > 0) {
        i -= 1;
        const segment = segments[i];
        if (segment.len == 0) continue;
        if (!looksLikeAlterQualifier(segment)) break;
        trailing_qualifiers += 1;
    }
    if (trailing_qualifiers == 0 or trailing_qualifiers >= nonempty) return segments.len;
    return segments.len - trailing_qualifiers;
}

fn looksLikeAlterQualifier(value: []const u8) bool {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len == 0) return false;
    inline for ([_][]const u8{
        "obsolete",
        "archaic",
        "rare",
        "dated",
        "dialectal",
        "colloquial",
        "informal",
        "abbreviation",
        "abbreviations",
        "pronunciation spelling",
        "alternative spelling",
        "alternative form",
        "chiefly UK",
        "chiefly US",
        "UK",
        "US",
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry)) return true;
    }
    return false;
}

fn splitTrailingQualifier(raw: []const u8) TrailingQualifier {
    const trimmed = trimWikiWhitespace(raw);
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '>') return .{ .term = trimmed };
    const tag_start = std.mem.lastIndexOf(u8, trimmed, "<q:") orelse return .{ .term = trimmed };
    if (tag_start == 0 or tag_start >= trimmed.len - 1) return .{ .term = trimmed };
    const qualifier = trimWikiWhitespace(trimmed[tag_start + 3 .. trimmed.len - 1]);
    const term = trimWikiWhitespace(trimmed[0..tag_start]);
    if (qualifier.len == 0 or term.len == 0) return .{ .term = trimmed };
    return .{ .term = term, .qualifier = qualifier };
}

fn renderFractionTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const total = positionalCount(parts);
    if (total == 0) return;
    if (total >= 3) {
        if (templatePositional(parts, 0)) |whole| {
            try renderInline(out, allocator, whole);
            try appendWithSpace(out, allocator, " ");
        }
        if (templatePositional(parts, 1)) |numerator| try renderInline(out, allocator, numerator);
        try appendWithSpace(out, allocator, "/");
        if (templatePositional(parts, 2)) |denominator| try renderInline(out, allocator, denominator);
        return;
    }
    if (templatePositional(parts, 0)) |numerator| try renderInline(out, allocator, numerator);
    if (templatePositional(parts, 1)) |denominator| {
        try appendWithSpace(out, allocator, "/");
        try renderInline(out, allocator, denominator);
    }
}

fn firstUsefulCoinageArg(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        const value = trimWikiWhitespace(segment);
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        if (value.len == 0) {
            positional_index += 1;
            continue;
        }
        if (value[0] == 'Q' and value.len > 1) {
            var numeric = true;
            for (value[1..]) |char| {
                if (!std.ascii.isDigit(char)) {
                    numeric = false;
                    break;
                }
            }
            if (numeric) {
                positional_index += 1;
                continue;
            }
        }
        return value;
    }
    return null;
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

    var requires_extended_shape = trimmed.len > 5;
    var has_letter = false;
    for (trimmed) |char| {
        if (std.ascii.isAlphabetic(char)) {
            has_letter = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '-' or char == '_') {
            requires_extended_shape = false;
            continue;
        }
        return false;
    }
    return has_letter and !requires_extended_shape;
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
    if (isVisibleNamespaceTarget(target)) return target;
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

fn isVisibleNamespaceTarget(target: []const u8) bool {
    const colon_index = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    const namespace = trimWikiWhitespace(target[0..colon_index]);
    return std.ascii.eqlIgnoreCase(namespace, "Thesaurus") or
        std.ascii.eqlIgnoreCase(namespace, "Appendix") or
        std.ascii.eqlIgnoreCase(namespace, "Citations") or
        std.ascii.eqlIgnoreCase(namespace, "Reconstruction") or
        std.ascii.eqlIgnoreCase(namespace, "Wiktionary");
}

fn templateEtymologyTerm(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    return templatePositional(parts, 2) orelse
        templatePositional(parts, 1) orelse
        templatePositional(parts, 0);
}

fn languageDisplay(code: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(code);
    inline for ([_]struct { code: []const u8, display: []const u8 }{
        .{ .code = "af", .display = "Afrikaans" },
        .{ .code = "ang", .display = "Old English" },
        .{ .code = "arc", .display = "Aramaic" },
        .{ .code = "ber-pro", .display = "Proto-Berber" },
        .{ .code = "be", .display = "Belarusian" },
        .{ .code = "br", .display = "Breton" },
        .{ .code = "cs", .display = "Czech" },
        .{ .code = "csb", .display = "Kashubian" },
        .{ .code = "cy", .display = "Welsh" },
        .{ .code = "da", .display = "Danish" },
        .{ .code = "de", .display = "German" },
        .{ .code = "en", .display = "English" },
        .{ .code = "enm", .display = "Middle English" },
        .{ .code = "egy", .display = "Egyptian" },
        .{ .code = "es", .display = "Spanish" },
        .{ .code = "eu", .display = "Basque" },
        .{ .code = "fa-cls", .display = "Classical Persian" },
        .{ .code = "fi", .display = "Finnish" },
        .{ .code = "fia", .display = "Nobiin" },
        .{ .code = "fr", .display = "French" },
        .{ .code = "frm", .display = "Middle French" },
        .{ .code = "fro", .display = "Old French" },
        .{ .code = "fy", .display = "West Frisian" },
        .{ .code = "ga", .display = "Irish" },
        .{ .code = "gd", .display = "Scottish Gaelic" },
        .{ .code = "gem-pro", .display = "Proto-Germanic" },
        .{ .code = "gml", .display = "Middle Low German" },
        .{ .code = "gmq", .display = "North Germanic" },
        .{ .code = "gmw-pro", .display = "Proto-West Germanic" },
        .{ .code = "got", .display = "Gothic" },
        .{ .code = "grc", .display = "Ancient Greek" },
        .{ .code = "grc-koi", .display = "Koine Greek" },
        .{ .code = "gsw", .display = "Swiss German" },
        .{ .code = "hu", .display = "Hungarian" },
        .{ .code = "hy", .display = "Armenian" },
        .{ .code = "ine-pro", .display = "Proto-Indo-European" },
        .{ .code = "kw", .display = "Cornish" },
        .{ .code = "la", .display = "Latin" },
        .{ .code = "LL.", .display = "Late Latin" },
        .{ .code = "li", .display = "Limburgish" },
        .{ .code = "lt", .display = "Lithuanian" },
        .{ .code = "ML.", .display = "Medieval Latin" },
        .{ .code = "mi", .display = "Māori" },
        .{ .code = "nds", .display = "Low German" },
        .{ .code = "nds-de", .display = "German Low German" },
        .{ .code = "nds-nl", .display = "Dutch Low Saxon" },
        .{ .code = "NL.", .display = "New Latin" },
        .{ .code = "nl", .display = "Dutch" },
        .{ .code = "nb", .display = "Norwegian Bokmål" },
        .{ .code = "no", .display = "Norwegian" },
        .{ .code = "non", .display = "Old Norse" },
        .{ .code = "nn", .display = "Norwegian Nynorsk" },
        .{ .code = "nrf", .display = "Norman" },
        .{ .code = "onw", .display = "Old Nubian" },
        .{ .code = "ofs", .display = "Old Frisian" },
        .{ .code = "ota", .display = "Ottoman Turkish" },
        .{ .code = "osx", .display = "Old Saxon" },
        .{ .code = "pl", .display = "Polish" },
        .{ .code = "ru", .display = "Russian" },
        .{ .code = "rup", .display = "Aromanian" },
        .{ .code = "sa", .display = "Sanskrit" },
        .{ .code = "se", .display = "Northern Sami" },
        .{ .code = "sh", .display = "Serbo-Croatian" },
        .{ .code = "sv", .display = "Swedish" },
        .{ .code = "stq", .display = "Saterland Frisian" },
        .{ .code = "taq", .display = "Tamasheq" },
        .{ .code = "tmh", .display = "Tamahaq" },
        .{ .code = "tr", .display = "Turkish" },
        .{ .code = "tpi", .display = "Tok Pisin" },
        .{ .code = "uk", .display = "Ukrainian" },
        .{ .code = "urj-pro", .display = "Proto-Uralic" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.code)) return entry.display;
    }
    return null;
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
    var placeholders: usize = 0;
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
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<<")) {
            placeholders += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], ">>")) {
            if (placeholders != 0) placeholders -= 1;
            i += 1;
            continue;
        }
        if (input[i] == sep and templates == 0 and links == 0 and placeholders == 0) {
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
    var previous_lang: ?[]const u8 = null;
    var term_slot: usize = 1;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) try out.appendSlice(allocator, " + ");
        if (templateIndexedNamed(parts, "lang", term_slot)) |code| {
            const trimmed_code = trimWikiWhitespace(code);
            if (trimmed_code.len != 0 and (previous_lang == null or !std.mem.eql(u8, previous_lang.?, trimmed_code))) {
                if (languageDisplay(trimmed_code)) |display| {
                    try appendWithSpace(out, allocator, display);
                    try appendWithSpace(out, allocator, " ");
                }
                previous_lang = trimmed_code;
            }
        }
        try appendCompoundTerm(out, allocator, parts, term_slot, trimWikiWhitespace(segment));
        wrote_any = true;
        term_slot += 1;
        positional_index += 1;
    }
}

fn renderCompoundTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const total = positionalCount(parts);
    if (total == 0) return;
    if (templateMatches(name, "compound+") or templateMatches(name, "com+")) {
        try appendWithSpace(out, allocator, "Compound of ");
    }

    const first_term_index: usize = if (templatePositional(parts, 0)) |first|
        if (looksLikeLanguageCode(first)) 1 else 0
    else
        0;

    var term_slot: usize = 1;
    var positional_index = first_term_index;
    var wrote_any = false;
    while (positional_index < total) : (positional_index += 1) {
        const term = templatePositional(parts, positional_index) orelse continue;
        const trimmed = trimWikiWhitespace(term);
        if (trimmed.len == 0) continue;
        if (wrote_any) try out.appendSlice(allocator, " + ");
        try appendCompoundTerm(out, allocator, parts, term_slot, trimmed);
        wrote_any = true;
        term_slot += 1;
    }

    if (templateNamed(parts, "lit")) |literal| {
        const trimmed = trimWikiWhitespace(literal);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, ", literally ");
            try renderInline(out, allocator, trimmed);
        }
    }
}

fn standaloneUnaryPrefix(prefix: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(prefix, "clipping of")) return "clipping";
    return prefix;
}

fn templateIndexedNamed(parts: *const std.ArrayList([]const u8), prefix: []const u8, index: usize) ?[]const u8 {
    var key_buf: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ prefix, index }) catch return null;
    return templateNamed(parts, key);
}

fn appendCompoundTerm(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    term_slot: usize,
    fallback_term: []const u8,
) std.mem.Allocator.Error!void {
    const alt_name = try std.fmt.allocPrint(allocator, "alt{}", .{term_slot});
    defer allocator.free(alt_name);
    const gloss_name = try std.fmt.allocPrint(allocator, "t{}", .{term_slot});
    defer allocator.free(gloss_name);
    const pos_name = try std.fmt.allocPrint(allocator, "pos{}", .{term_slot});
    defer allocator.free(pos_name);

    const display = templateNamed(parts, alt_name) orelse fallback_term;
    try renderInline(out, allocator, display);

    const gloss = templateNamed(parts, gloss_name);
    const pos = templateNamed(parts, pos_name);
    if (gloss == null and pos == null) return;

    try out.appendSlice(allocator, " (");
    if (gloss) |value| {
        try renderInline(out, allocator, value);
        if (pos != null) try out.appendSlice(allocator, ", ");
    }
    if (pos) |value| try renderInline(out, allocator, value);
    try out.append(allocator, ')');
}

fn renderHomophoneTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const count = positionalCount(parts);
    const first_term_index: usize = if (templatePositional(parts, 0)) |first|
        if (looksLikeLanguageCode(first)) 1 else 0
    else
        0;
    const term_count = count -| first_term_index;
    try appendWithSpace(out, allocator, if (term_count == 1) "Homophone: " else "Homophones: ");
    try appendPositional(out, allocator, parts, first_term_index, "", "", ", ");
    if (templateNamed(parts, "aa") orelse templateNamed(parts, "a")) |qualifier| {
        const trimmed = trimWikiWhitespace(qualifier);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, " (");
            try renderInline(out, allocator, trimmed);
            try out.append(allocator, ')');
        }
    }
}

fn renderHyphenationTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, "Hyphenation: ");
    const total = positionalCount(parts);
    var positional_index: usize = 1;
    var needs_form_separator = false;
    var needs_segment_separator = false;
    while (positional_index < total) : (positional_index += 1) {
        const segment = templatePositional(parts, positional_index) orelse continue;
        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0) {
            if (needs_segment_separator) {
                needs_form_separator = true;
                needs_segment_separator = false;
            }
            continue;
        }
        if (needs_form_separator) {
            try out.appendSlice(allocator, ", ");
            needs_form_separator = false;
        } else if (needs_segment_separator) {
            try out.appendSlice(allocator, "‧");
        }
        try renderInline(out, allocator, trimmed);
        needs_segment_separator = true;
    }
}

fn appendPlaceTerms(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const type_index = placeTypeIndex(parts);
    const raw_type = templatePositional(parts, type_index) orelse return;
    const rendered_type = try renderPlaceTypeTextAlloc(allocator, raw_type);
    defer allocator.free(rendered_type);
    if (rendered_type.len == 0) return;

    if (placeTypeNeedsArticle(rendered_type)) {
        try out.appendSlice(allocator, chooseIndefiniteArticle(rendered_type, true));
        try out.appendSlice(allocator, " ");
    }
    try out.appendSlice(allocator, rendered_type);

    var wrote_location = false;
    var last_was_location_value = false;
    const positional_total = positionalCount(parts);
    var positional_index = type_index + 1;
    while (positional_index < positional_total) {
        const piece_raw = templatePositional(parts, positional_index) orelse {
            positional_index += 1;
            continue;
        };
        const piece = std.mem.trim(u8, stripTraversalSegments(piece_raw), " \t");
        if (piece.len == 0) {
            positional_index += 1;
            continue;
        }

        if (templatePositional(parts, positional_index + 1)) |next_raw| {
            const next_piece = std.mem.trim(u8, stripTraversalSegments(next_raw), " \t");
            if (isPlaceConnectorPiece(piece, next_piece)) {
                if (wrote_location) {
                    try out.appendSlice(allocator, connectorSeparator(piece, last_was_location_value));
                } else {
                    try out.append(allocator, ' ');
                }
                try renderInline(out, allocator, piece);
                try out.append(allocator, ' ');
                try appendPlaceLocationFragment(out, allocator, next_piece);
                wrote_location = true;
                last_was_location_value = true;
                positional_index += 2;
                continue;
            }
        }

        if (!wrote_location) {
            try out.appendSlice(allocator, if (placeTypeNeedsIn(rendered_type)) " in " else " ");
            wrote_location = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try appendPlaceLocationFragment(out, allocator, piece);
        last_was_location_value = true;
        positional_index += 1;
    }

    for ([_][]const u8{ "official", "capital", "located", "located in", "caplc" }) |key| {
        if (templateNamed(parts, key)) |value| {
            const piece = normalizePlaceFragment(value);
            if (piece.len == 0) continue;
            if (wrote_location) {
                try out.appendSlice(allocator, "; ");
            } else {
                try out.appendSlice(allocator, " ");
            }
            try renderInline(out, allocator, piece);
            wrote_location = true;
        }
    }
}

fn appendNominalTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    noun: []const u8,
) std.mem.Allocator.Error!void {
    var phrase: std.ArrayList(u8) = .empty;
    defer phrase.deinit(allocator);

    if (templatePositional(parts, 1)) |qualifier| {
        const trimmed = trimWikiWhitespace(qualifier);
        if (trimmed.len != 0 and !looksLikeLanguageCode(trimmed)) {
            try renderInline(&phrase, allocator, trimmed);
            if (phrase.items.len != 0) try phrase.append(allocator, ' ');
        }
    }
    try phrase.appendSlice(allocator, noun);

    try out.appendSlice(allocator, chooseIndefiniteArticle(phrase.items, true));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, phrase.items);
    if (templateNamed(parts, "from")) |source| {
        try appendNominalOrigin(out, allocator, source);
    }
}

fn appendNominalOrigin(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_source: []const u8,
) std.mem.Allocator.Error!void {
    const trimmed = trimWikiWhitespace(raw_source);
    if (trimmed.len == 0) return;

    if (std.mem.indexOfScalar(u8, trimmed, '<')) |lt| {
        const source_phrase = trimWikiWhitespace(trimmed[0..lt]);
        const upstream = trimWikiWhitespace(trimmed[lt + 1 ..]);

        try out.appendSlice(allocator, " transferred from ");
        if (source_phrase.len != 0) {
            const normalized_source = try normalizeNominalOriginPhraseAlloc(allocator, source_phrase);
            defer allocator.free(normalized_source);
            try renderInline(out, allocator, normalized_source);
        }
        if (upstream.len != 0) {
            try out.appendSlice(allocator, " [in turn from ");
            try renderInline(out, allocator, upstream);
            try out.append(allocator, ']');
        }
        return;
    }

    try out.appendSlice(allocator, " from ");
    try renderInline(out, allocator, trimmed);
}

fn normalizeNominalOriginPhraseAlloc(
    allocator: std.mem.Allocator,
    phrase: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const trimmed = trimWikiWhitespace(phrase);
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    const singular = if (asciiEndsWithIgnoreCase(trimmed, " names"))
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed;

    inline for ([_][]const u8{
        "a ",
        "an ",
        "the ",
        "this ",
        "that ",
        "these ",
        "those ",
        "one ",
    }) |prefix| {
        if (asciiStartsWithIgnoreCase(trimmed, prefix)) return allocator.dupe(u8, singular);
    }

    return std.fmt.allocPrint(allocator, "the {s}", .{singular});
}

fn renderPlaceTypeTextAlloc(
    allocator: std.mem.Allocator,
    raw_type: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const trimmed = trimWikiWhitespace(stripTraversalSegments(raw_type));
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, trimmed, '/') == null) {
        return renderWikitextToOwned(allocator, trimmed, std.math.maxInt(usize));
    }

    var parts = try splitTopLevel(allocator, trimmed, '/');
    defer parts.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var prev_was_connector = false;
    var wrote_any = false;
    for (parts.items) |segment_raw| {
        const segment = trimWikiWhitespace(segment_raw);
        if (segment.len == 0) continue;

        const token = canonicalPlaceHolonymType(segment) orelse segment;
        const rendered = try renderWikitextToOwned(allocator, token, std.math.maxInt(usize));
        defer allocator.free(rendered);
        if (rendered.len == 0) continue;

        const is_connector = isPlaceTypeConnector(rendered);
        if (wrote_any) {
            try out.appendSlice(allocator, if (prev_was_connector or is_connector) " " else " and ");
        }
        try out.appendSlice(allocator, rendered);
        wrote_any = true;
        prev_was_connector = is_connector;
    }
    return out.toOwnedSlice(allocator);
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

fn appendPlaceLocationFragment(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!void {
    if (std.mem.indexOfScalar(u8, input, '/')) |slash| {
        const prefix = std.mem.trim(u8, input[0..slash], " \t");
        const value = std.mem.trim(u8, input[slash + 1 ..], " \t");
        if (value.len == 0) return;
        const display = placeHolonymDisplay(prefix);
        switch (display.kind) {
            .plain => try renderInline(out, allocator, value),
            .prefix => {
                try appendPlaceHolonymPrefix(out, allocator, display.label);
                try renderInline(out, allocator, value);
            },
            .suffix => {
                try renderInline(out, allocator, value);
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, display.label);
            },
        }
        return;
    }
    try renderInline(out, allocator, input);
}

const PlaceHolonymDisplayKind = enum {
    plain,
    prefix,
    suffix,
};

const PlaceHolonymDisplay = struct {
    kind: PlaceHolonymDisplayKind = .plain,
    label: []const u8 = "",
};

fn placeHolonymDisplay(prefix: []const u8) PlaceHolonymDisplay {
    const canonical = canonicalPlaceHolonymType(prefix) orelse return .{};

    if (std.ascii.eqlIgnoreCase(canonical, "metropolitan borough") or
        std.ascii.eqlIgnoreCase(canonical, "London borough") or
        std.ascii.eqlIgnoreCase(canonical, "royal borough") or
        std.ascii.eqlIgnoreCase(canonical, "metropolitan city"))
    {
        return .{ .kind = .prefix, .label = canonical };
    }

    if (std.ascii.eqlIgnoreCase(canonical, "borough") or
        std.ascii.eqlIgnoreCase(canonical, "county borough") or
        std.ascii.eqlIgnoreCase(canonical, "parish") or
        std.ascii.eqlIgnoreCase(canonical, "civil parish") or
        std.mem.endsWith(u8, canonical, " district") or
        std.ascii.eqlIgnoreCase(canonical, "district"))
    {
        return .{ .kind = .suffix, .label = canonical };
    }

    return .{};
}

fn canonicalPlaceHolonymType(prefix: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, prefix, " \t");
    inline for ([_]struct { alias: []const u8, canonical: []const u8 }{
        .{ .alias = "bor", .canonical = "borough" },
        .{ .alias = "borough", .canonical = "borough" },
        .{ .alias = "cobor", .canonical = "county borough" },
        .{ .alias = "county borough", .canonical = "county borough" },
        .{ .alias = "cpar", .canonical = "civil parish" },
        .{ .alias = "civil parish", .canonical = "civil parish" },
        .{ .alias = "dist", .canonical = "district" },
        .{ .alias = "district", .canonical = "district" },
        .{ .alias = "lgd", .canonical = "local government district" },
        .{ .alias = "lgdist", .canonical = "local government district" },
        .{ .alias = "local government district", .canonical = "local government district" },
        .{ .alias = "lbor", .canonical = "London borough" },
        .{ .alias = "London borough", .canonical = "London borough" },
        .{ .alias = "metbor", .canonical = "metropolitan borough" },
        .{ .alias = "metropolitan borough", .canonical = "metropolitan borough" },
        .{ .alias = "metcity", .canonical = "metropolitan city" },
        .{ .alias = "metropolitan city", .canonical = "metropolitan city" },
        .{ .alias = "par", .canonical = "parish" },
        .{ .alias = "parish", .canonical = "parish" },
        .{ .alias = "rdist", .canonical = "regional district" },
        .{ .alias = "regional district", .canonical = "regional district" },
        .{ .alias = "robor", .canonical = "royal borough" },
        .{ .alias = "royal borough", .canonical = "royal borough" },
        .{ .alias = "subdistrict", .canonical = "subdistrict" },
        .{ .alias = "udist", .canonical = "unitary district" },
        .{ .alias = "unitary district", .canonical = "unitary district" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.alias)) return entry.canonical;
    }
    return null;
}

fn isPlaceTypeConnector(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    inline for ([_][]const u8{
        "and",
        "or",
        "of",
        "for",
        "in",
        "on",
        "near",
        "with",
        "without",
        "from",
        "to",
        "the",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

fn isPlaceConnectorPiece(piece: []const u8, next_piece: []const u8) bool {
    if (piece.len == 0 or next_piece.len == 0) return false;
    if (std.mem.indexOfScalar(u8, piece, '/')) |_| return false;
    return std.mem.indexOfScalar(u8, next_piece, '/') != null or
        std.mem.indexOf(u8, next_piece, "[[") != null or
        std.mem.indexOf(u8, next_piece, "{{") != null or
        std.mem.indexOf(u8, next_piece, "<<") != null;
}

fn connectorSeparator(piece: []const u8, last_was_location_value: bool) []const u8 {
    if (!last_was_location_value) return " ";
    const trimmed = std.mem.trim(u8, piece, " \t");
    if (asciiStartsWithIgnoreCase(trimmed, "previously") or
        asciiStartsWithIgnoreCase(trimmed, "historically") or
        asciiStartsWithIgnoreCase(trimmed, "formerly"))
    {
        return ", ";
    }
    return " ";
}

fn appendPlaceHolonymPrefix(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
) std.mem.Allocator.Error!void {
    const titled = try titleCaseAsciiAlloc(allocator, label);
    defer allocator.free(titled);
    try out.appendSlice(allocator, "the ");
    try out.appendSlice(allocator, titled);
    try out.appendSlice(allocator, " of ");
}

fn placeTypeIndex(parts: *const std.ArrayList([]const u8)) usize {
    if (positionalCount(parts) <= 1) return 0;
    const first = templatePositional(parts, 0) orelse return 0;
    return if (looksLikeLanguageCode(first)) 1 else 0;
}

fn placeTypeNeedsIn(rendered_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, rendered_type, " \t");
    return !asciiEndsWithIgnoreCase(trimmed, " in") and
        !asciiEndsWithIgnoreCase(trimmed, " of") and
        !asciiEndsWithIgnoreCase(trimmed, " on") and
        !asciiEndsWithIgnoreCase(trimmed, " at");
}

fn placeTypeNeedsArticle(rendered_type: []const u8) bool {
    const trimmed = std.mem.trim(u8, rendered_type, " \t");
    if (trimmed.len == 0) return false;
    inline for ([_][]const u8{
        "a ",
        "an ",
        "the ",
        "this ",
        "that ",
        "these ",
        "those ",
        "one ",
    }) |prefix| {
        if (asciiStartsWithIgnoreCase(trimmed, prefix)) return false;
    }
    return true;
}

fn chooseIndefiniteArticle(text: []const u8, capitalize: bool) []const u8 {
    const article = if (startsWithVowelSound(text)) "an" else "a";
    if (!capitalize) return article;
    return if (article[0] == 'a' and article.len == 2) "An" else "A";
}

fn startsWithVowelSound(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return false;

    var i: usize = 0;
    while (i < trimmed.len and !std.ascii.isAlphabetic(trimmed[i])) : (i += 1) {}
    if (i >= trimmed.len) return false;

    const lower = std.ascii.toLower(trimmed[i]);
    if (lower == 'u') {
        if (trimmed.len >= i + 3) {
            const next = std.ascii.toLower(trimmed[i + 1]);
            const third = std.ascii.toLower(trimmed[i + 2]);
            if ((next == 'n' and third == 'i') or (next == 's' and third == 'e')) return false;
        }
    }
    if (lower == 'e' and trimmed.len >= i + 2 and std.ascii.toLower(trimmed[i + 1]) == 'u') return false;
    if (lower == 'o' and trimmed.len >= i + 3 and std.ascii.toLower(trimmed[i + 1]) == 'n' and std.ascii.toLower(trimmed[i + 2]) == 'e') return false;
    return lower == 'a' or lower == 'e' or lower == 'i' or lower == 'o' or lower == 'u';
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

fn looksLikeOpaqueSenseId(value: []const u8) bool {
    if (value.len < 2 or value[0] != 'Q') return false;
    for (value[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn isPlaceholderTemplateTerm(term: []const u8) bool {
    const trimmed = trimWikiWhitespace(term);
    return std.mem.eql(u8, trimmed, "-") or std.mem.eql(u8, trimmed, "—");
}

fn isLexicalTemplate(name: []const u8) bool {
    return templateMatches(name, "l") or
        templateMatches(name, "m") or
        templateMatches(name, "m+") or
        templateMatches(name, "link") or
        templateMatches(name, "cog") or
        templateMatches(name, "noncog") or
        templateMatches(name, "af");
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
        templateMatches(name, "col1") or
        templateMatches(name, "col2") or
        templateMatches(name, "col3") or
        templateMatches(name, "col4") or
        templateMatches(name, "col5") or
        templateMatches(name, "col6");
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

fn titleCaseAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    var upper_next = true;
    for (out) |*char| {
        if (std.ascii.isAlphabetic(char.*)) {
            char.* = if (upper_next) std.ascii.toUpper(char.*) else std.ascii.toLower(char.*);
            upper_next = false;
            continue;
        }
        upper_next = char.* == ' ' or char.* == '-' or char.* == '/' or char.* == '(';
    }
    return out;
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

test "renderWikitextToOwned expands common inflection tags" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{infl of|en|pie||s-verb-form}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("third-person singular simple present indicative of pie", rendered);
}

test "renderWikitextToOwned keeps alter qualifiers beyond the third slot" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{alter|en|encyclopaedia||UK}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("encyclopaedia (UK)", rendered);
}

test "renderWikitextToOwned keeps extra alter terms before qualifiers" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{alter|en|heed|hed|obsolete}} {{alter|en|trade-wind|tradewind}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("heed, hed (obsolete) trade-wind, tradewind", rendered);
}

test "renderWikitextToOwned labels pronunciation templates" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{enPR|frē}}, {{IPA|en|/fɹiː/|[fɹɪi̯]}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("enPR: frē, IPA: /fɹiː/, [fɹɪi̯]", rendered);
}

test "renderWikitextToOwned formats hyphenation with wiktionary separators" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{hyphenation|en|dic|tion|a|ry||dic|tion|ary}}", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Hyphenation: dic‧tion‧a‧ry, dic‧tion‧ary", rendered);
}

test "renderWikitextToOwned expands etymology helpers with language names and glosses" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "From {{inh|en|enm|dixionare}}, from {{der|en|la|dictiō||a speaking}}. {{surf|en|diction|-ary}}. {{doublet|en|treasure}}.",
        512,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "From Middle English dixionare, from Latin dictiō (a speaking). By surface analysis, diction + -ary. Doublet of treasure.",
        rendered,
    );
}

test "renderWikitextToOwned keeps placeholder etymology language labels" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{der|en|fr|-}} ''{{w|Encyclopédie}}''", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("French Encyclopédie", rendered);
}

test "renderWikitextToOwned expands compound metadata and literal glosses" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{compound|frm|porter|alt1=porte|t1=carries|pos1=third-person singular present indicative of {{m|frm|porter|t=to carry}}|manteau|t2=coat|lit=[that which] carries coat}}",
        512,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "porte (carries, third-person singular present indicative of porter (to carry)) + manteau (coat), literally [that which] carries coat",
        rendered,
    );
}

test "renderWikitextToOwned expands Ottoman Turkish and Classical Persian etymology languages" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "Borrowed from {{bor|en|ota|آبدست}} (modern {{cog|tr|abdest}}), from {{der|en|fa-cls|آبْدَسْت|tr=ābdast}}.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Ottoman Turkish") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Turkish") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Classical Persian") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ābdast") != null);
}

test "renderWikitextToOwned prefixes compound-plus etymologies" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{compound+|en|trade|t1=course, path (of running)|pos1=from 14th c.|wind}}",
        512,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Compound of trade") != null);
}

test "renderWikitextToOwned keeps standalone clipping templates targetless" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "Bookmaker sense by {{clipping|en|nocap=1}}.", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "clipping.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "clipping of") == null);
}

test "renderWikitextToOwned prefixes affix components with explicit languages" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "From {{af|en|lang1=la|alphabēticus|-al}}.", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Latin alphabēticus + -al") != null);
}

test "renderWikitextToOwned falls back from empty pipe-trick displays" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "[[Fresnel reflection|]]", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Fresnel reflection", rendered);
}

test "renderWikitextToOwned preserves visible wiktionary namespaces in pipe-trick links" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "[[Thesaurus:verb|]]", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Thesaurus:verb", rendered);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "A country in Brazil") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Micronesia") != null);
}

test "renderWikitextToOwned formats place and surname templates as sentence fragments" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|hamlet|par/Ipplepen|dist/Teignbridge|co/Devon|cc/England}} {{q|[[OS]] grid ref SX8566}}. {{surname|en}}.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A hamlet in Ipplepen parish, Teignbridge district, Devon, England (OS grid ref SX8566). A surname.",
        rendered,
    );
}

test "renderWikitextToOwned preserves nominal template origins" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{surname|en|habitational|from=Old Norse}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("A habitational surname from Old Norse", rendered);
}

test "renderWikitextToOwned expands metropolitan borough place fragments" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|town|metbor/Knowsley|co/Merseyside|cc/England}} {{q|[[OS]] grid ref SJ4491}}.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A town in the Metropolitan Borough of Knowsley, Merseyside, England (OS grid ref SJ4491).",
        rendered,
    );
}

test "renderWikitextToOwned expands combined place type shorthands" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|village/and/cpar|in|co/North Yorkshire|cc/England|previously in|dist/Hambleton}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A village and civil parish in North Yorkshire, England, previously in Hambleton district",
        rendered,
    );
}

test "renderWikitextToOwned handles wiki link trails and alternative-form qualifiers" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "[[travel]]ling [[case]]. {{alti|en|portemanteau|portmantua<q:obsolete>}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "travelling case. Alternative forms: portemanteau, (obsolete) portmantua",
        rendered,
    );
}

test "renderWikitextToOwned does not prepend indefinite articles to determiner-led place text" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|The largest and most populous <<constituent country>> of the <<c/United Kingdom>>}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "The largest and most populous constituent country of the United Kingdom",
        rendered,
    );
}

test "renderWikitextToOwned expands nominal month-name origins semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{given name|en|female|from=month names < English}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A female given name transferred from the month name [in turn from English]",
        rendered,
    );
}

test "renderWikitextToOwned expands known units-of-time list templates" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{list:units of time/en}}",
        4096,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "attosecond") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "year") != null);
}

test "renderWikitextToOwned treats lone angle placeholders as inline text" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "Press <Ctrl>+<Alt>+<Del>.", 256);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Press Ctrl+Alt+Del.", rendered);
}

test "renderWikitextToOwned preserves possessive apostrophes around italic markup" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "''Britannica'''s ''[[w:Macropædia|Macropædia]]''",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Britannica's Macropædia", rendered);
}
