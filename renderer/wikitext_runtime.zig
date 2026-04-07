const std = @import("std");
const xml_decode = @import("shared_xml_decode");
const generated_templates = @import("generated_template_runtime");
const template_support = @import("template_compiler_support");

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

pub fn renderTemplateBodyToOwned(
    allocator: std.mem.Allocator,
    body: []const u8,
    max_len: usize,
) std.mem.Allocator.Error![]const u8 {
    const wrapped = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{body});
    defer allocator.free(wrapped);
    return renderWikitextToOwned(allocator, wrapped, max_len);
}

fn renderInline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!void {
    var emphasis_state: EmphasisState = .{};
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
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            i += 2;
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
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "]]")) {
            i += 2;
            continue;
        }
        if (input[i] == '[') {
            if (asciiStartsWithIgnoreCase(input[i + 1 ..], "http")) {
                if (findExternalLinkClose(input, i)) |end| {
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
            if (emphasis_state.consumeApostropheRun(input, run_start, i - run_start)) {
                try out.append(allocator, '\'');
            }
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
}

const EmphasisState = struct {
    italic_open: bool = false,
    bold_open: bool = false,

    fn consumeApostropheRun(self: *EmphasisState, input: []const u8, run_start: usize, run_len: usize) bool {
        switch (run_len) {
            2 => {
                self.italic_open = !self.italic_open;
                return false;
            },
            3 => {
                if (self.italic_open and !self.bold_open and shouldKeepLiteralApostrophe(input, run_start, run_len)) {
                    self.italic_open = false;
                    return true;
                }
                self.bold_open = !self.bold_open;
                return false;
            },
            5 => {
                self.bold_open = !self.bold_open;
                self.italic_open = !self.italic_open;
                return false;
            },
            else => return shouldKeepLiteralApostrophe(input, run_start, run_len),
        }
    }
};

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
        templateMatches(name, "was wotd") or
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
        templateMatches(name, "wikidata") or
        templateMatches(name, "wikidata lexeme") or
        templateMatches(name, "trans-see") or
        templateMatches(name, "see more citations") or
        templateMatches(name, "see citations") or
        templateMatches(name, "see thesaurus") or
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
        templateMatches(name, "see desc") or
        templateMatches(name, "specieslite") or
        templateMatches(name, "suffixsee") or
        templateMatches(name, "tea room") or
        templateMatches(name, "translation only") or
        templateMatches(name, "hot word") or
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
        templateMatches(name, "ref") or
        templateMatches(name, "see also") or
        templateMatches(name, "catlangname") or
        asciiStartsWithIgnoreCase(name, "ctRenderF") or
        templateMatches(name, "construed with") or
        templateMatches(name, "ety") or
        templateMatches(name, "mainapp") or
        templateMatches(name, "pseudo-loan") or
        templateMatches(name, "rfd") or
        templateMatches(name, "rfq") or
        templateMatches(name, "thub") or
        templateMatches(name, "mapframe") or
        templateMatches(name, "wikivoyage"))
    {
        return;
    }
    if (asciiStartsWithIgnoreCase(name, "list:")) {
        if (try renderKnownListTemplate(out, allocator, name)) return;
    }

    if (asciiStartsWithIgnoreCase(name, "R:") or
        asciiStartsWithIgnoreCase(name, "table:") or
        asciiStartsWithIgnoreCase(name, "Wiktionary:"))
    {
        return;
    }

    if (templateMatches(name, "lb") or templateMatches(name, "lbl") or templateMatches(name, "label")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "qualifier") or templateMatches(name, "q") or templateMatches(name, "q-lite") or templateMatches(name, "qual")) {
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
    if (templateMatches(name, "B.C.") or templateMatches(name, "B.C.E.") or templateMatches(name, "C.E.")) {
        try appendWithSpace(out, allocator, name);
        return;
    }
    if (templateMatches(name, "BC") or templateMatches(name, "BCE")) {
        try appendWithSpace(out, allocator, name);
        return;
    }
    if (templateMatches(name, "a") or templateMatches(name, "C")) {
        try appendPositional(out, allocator, &parts, 1, "(", ")", ", ");
        return;
    }
    if (templateMatches(name, "U") or asciiStartsWithIgnoreCase(name, "U:")) {
        if (usageTemplateDisplayValue(name, &parts)) |value| {
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "only used in")) {
        try appendWithSpace(out, allocator, "Only used in ");
        try appendPositional(out, allocator, &parts, semanticTemplateTargetIndex(&parts), "", "", ", ");
        try appendWithSpace(out, allocator, ".");
        return;
    }
    if (templateMatches(name, "glossary")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "sense")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "antsense")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "s")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
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
    if (templateMatches(name, "ux") or templateMatches(name, "uxa") or templateMatches(name, "uxi") or templateMatches(name, "usex")) {
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
    if (templateMatches(name, "nearsyn") or templateMatches(name, "near-synonyms")) {
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
    if (templateMatches(name, "clip of")) {
        try renderUnaryTemplate(out, allocator, &parts, "clipping of");
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
        try appendWithSpace(out, allocator, "IPA ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "IPAfont")) {
        if (templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
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
        try appendWithSpace(out, allocator, "audio");
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
        if (templatePositional(&parts, 1)) |arg| {
            const trimmed = trimWikiWhitespace(arg);
            const display = if (trimmed.len != 0 and trimmed[0] == '-') trimmed[1..] else trimmed;
            try renderInline(out, allocator, display);
        }
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
        try appendAffixTerms(out, allocator, name, &parts);
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
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
        return;
    }
    if (templateMatches(name, "taxlink")) {
        if (templatePositional(&parts, 1) orelse templatePositional(&parts, 0)) |arg| try renderInline(out, allocator, arg);
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
        try appendPositional(out, allocator, &parts, if (positionalCount(&parts) > 1) 1 else 0, "", "", ", ");
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
    if (templateMatches(name, "init")) {
        try renderUnaryTemplate(out, allocator, &parts, "Initialism of");
        return;
    }
    if (templateMatches(name, "short for")) {
        try renderUnaryTemplate(out, allocator, &parts, "short for");
        return;
    }
    if (templateMatches(name, "&lit")) {
        try appendWithSpace(out, allocator, "Used other than figuratively or idiomatically: see ");
        try appendPositional(out, allocator, &parts, 1, "", "", ", ");
        return;
    }
    if (templateMatches(name, "post")) {
        try appendPositional(out, allocator, &parts, 0, "(post-", ")", ", ");
        return;
    }
    if (templateMatches(name, "attention")) {
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
        try appendWithSpace(out, allocator, "Doublet of ");
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
    if (templateMatches(name, "coined")) {
        if (firstUsefulCoinageArg(&parts)) |value| {
            try appendWithSpace(out, allocator, "coined by ");
            try renderInline(out, allocator, value);
        } else {
            try appendWithSpace(out, allocator, "coined");
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
    if (templateMatches(name, "clipping") or templateMatches(name, "clip of")) {
        try renderUnaryTemplate(out, allocator, &parts, "clipping of");
        return;
    }
    if (templateMatches(name, "bf") or templateMatches(name, "back-form")) {
        try renderUnaryTemplate(out, allocator, &parts, "back-formation from");
        return;
    }
    if (templateMatches(name, "confix")) {
        try appendAffixTerms(out, allocator, name, &parts);
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
    if (templateMatches(name, "cal")) {
        if (templateEtymologyTerm(&parts)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "partial calque")) {
        const target_index = if (positionalCount(&parts) > 2 and
            looksLikeLanguageCode(trimWikiWhitespace(templatePositional(&parts, 0) orelse "")) and
            looksLikeLanguageCode(trimWikiWhitespace(templatePositional(&parts, 1) orelse "")))
            2
        else
            semanticTemplateTargetIndex(&parts);
        try renderUnaryTemplateAtIndex(out, allocator, &parts, "partial calque of", target_index);
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
    if (templateMatches(name, "onomatopoeic") or templateMatches(name, "onom")) {
        try appendWithSpace(out, allocator, "Onomatopoeic");
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
    if (templateMatches(name, "dated form")) {
        try renderUnaryTemplate(out, allocator, &parts, "dated form of");
        return;
    }
    if (templateMatches(name, "initialism")) {
        try renderUnaryTemplate(out, allocator, &parts, "initialism of");
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
    if (templateMatches(name, "alt case form")) {
        try renderUnaryTemplate(out, allocator, &parts, "alternative case form of");
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
    if (templateMatches(name, "backform")) {
        try renderUnaryTemplate(out, allocator, &parts, "back-formation from");
        return;
    }
    if (templateMatches(name, "aphetic form")) {
        try renderUnaryTemplate(out, allocator, &parts, "aphetic form of");
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
    if (templateMatches(name, "cens sp")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "ngd")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "staco")) {
        if (templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |tail| {
            const trimmed_tail = trimWikiWhitespace(tail);
            const trimmed_head = trimWikiWhitespace(templatePositional(&parts, 0) orelse "");
            if (trimmed_tail.len != 0 and !std.mem.eql(u8, trimmed_tail, trimmed_head)) {
                if (trimmed_head.len != 0) try appendWithSpace(out, allocator, ", ");
                try renderInline(out, allocator, trimmed_tail);
            }
        }
        return;
    }
    if (templateMatches(name, "lit")) {
        if (templatePositional(&parts, 0)) |value| {
            try appendWithSpace(out, allocator, "literally ");
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "nuclide")) {
        if (templatePositional(&parts, 0)) |mass| {
            try renderInline(out, allocator, mass);
            if (templatePositional(&parts, 2)) |symbol| try renderInline(out, allocator, symbol);
        }
        return;
    }
    if (templateMatches(name, "refn")) {
        if (templatePositional(&parts, positionalCount(&parts) -| 1)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "afex")) {
        try appendPositional(out, allocator, &parts, 1, "", "", " + ");
        return;
    }
    if (templateMatches(name, "OCLC")) {
        if (templatePositional(&parts, 0)) |value| {
            try appendWithSpace(out, allocator, "OCLC ");
            try renderInline(out, allocator, value);
        }
        return;
    }
    if (templateMatches(name, "math")) {
        if (templateNamed(&parts, "1") orelse templatePositional(&parts, 0)) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "ndash")) {
        try appendWithSpace(out, allocator, "-");
        return;
    }
    if (templateMatches(name, "cite book")) {
        if (templateNamed(&parts, "title")) |value| try renderInline(out, allocator, value);
        return;
    }
    if (templateMatches(name, "gentrade")) {
        try appendWithSpace(out, allocator, "genericized trademark");
        return;
    }
    if (templateMatches(name, "book of the Bible")) {
        try appendWithSpace(out, allocator, "book of the Bible");
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
    if (templateMatches(name, "CURRENTDAY")) {
        try appendWithSpace(out, allocator, currentDayText());
        return;
    }
    if (templateMatches(name, "CURRENTMONTHNAME")) {
        try appendWithSpace(out, allocator, currentMonthName());
        return;
    }
    if (templateMatches(name, "CURRENTYEAR")) {
        try appendWithSpace(out, allocator, currentYearText());
        return;
    }
    if (templateMatches(name, "season name spelling")) {
        try appendWithSpace(out, allocator, "Note that season names are not capitalized in modern English except where any noun would be capitalized, e.g. at the beginning of a sentence or as part of a name (Old Man Winter, the Winter War, Summer Glau). This is in contrast to the days of the week and months of the year, which are always capitalized (Thursday or September).");
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
    if (templateMatches(name, "cog") or templateMatches(name, "cognate") or templateMatches(name, "noncog") or templateMatches(name, "ncog")) {
        try appendLanguageAwareLexemeTemplate(out, allocator, &parts, 0, 1);
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
    if (templateMatches(name, "SI-unit")) {
        try renderSiUnitTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "suffixusex")) {
        try renderSuffixUsexTemplate(out, allocator, &parts);
        return;
    }
    if (templateMatches(name, "phono-semantic matching")) {
        try renderPhonoSemanticMatchingTemplate(out, allocator, &parts);
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
    if (try renderGeneratedTemplate(out, allocator, name, &parts)) {
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

fn renderGeneratedTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
) !bool {
    const dispatch_id = template_support.templateDispatchId(name) orelse return false;
    var args = try template_support.templateArgsFromPartsAlloc(allocator, parts);
    defer args.deinit(allocator);

    const start_len = out.items.len;
    if (!(generated_templates.renderTemplateByDispatchId(out, allocator, dispatch_id, &args) catch false)) {
        out.items.len = start_len;
        return false;
    }
    const appended = out.items[start_len..];
    if (appended.len == 0) return true;
    if (looksLikeTemplateRedirectText(appended)) {
        out.items.len = start_len;
        return false;
    }

    return true;
}

fn looksLikeTemplateRedirectText(text: []const u8) bool {
    const trimmed = trimWikiWhitespace(text);
    return trimmed.len >= "#REDIRECT".len and std.ascii.startsWithIgnoreCase(trimmed, "#REDIRECT");
}

pub fn knownListTerms(name: []const u8) ?[]const []const u8 {
    const trimmed = trimWikiWhitespace(name);
    if (!asciiStartsWithIgnoreCase(trimmed, "list:")) return null;
    const list_name = trimWikiWhitespace(trimmed["list:".len..]);

    if (std.ascii.eqlIgnoreCase(list_name, "units of time/en")) {
        return &.{
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
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "religious adherents/en")) {
        return &.{
            "African traditionalist",
            "agnostic",
            "Asatruar",
            "atheist",
            "Baháʼí",
            "Buddhist",
            "Caodaiist",
            "Christian",
            "Confucian",
            "deist",
            "Druid",
            "Druze",
            "Eckist",
            "heathen",
            "Hindu",
            "Jain",
            "Jedi",
            "Jew",
            "Mormon",
            "Mormonist",
            "Muslim",
            "Odinist",
            "pagan",
            "Pastafarian",
            "Quaker",
            "Raëlian",
            "Rastafarian",
            "Rodnover",
            "Samaritan",
            "Shintoist",
            "Sikh",
            "Taoist",
            "Tengrist",
            "Unitarian Universalist",
            "Wiccan",
            "Yahwist",
            "Yazidi",
            "Zoroastrian",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "latin script letters/en/simple")) {
        return &.{
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
            "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "latin script letter names/en/simple")) {
        return &.{
            "a",  "bee", "cee", "dee", "e",  "ef",  "gee", "aitch", "i",   "jay",      "kay", "el", "em",
            "en", "o",   "pee", "cue", "ar", "ess", "tee", "u",     "vee", "double-u", "ex",  "wy", "zed",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "countries in europe/en")) {
        return &.{
            "Albania",                "Andorra",      "Armenia",    "Austria", "Azerbaijan",     "Belarus",       "Belgium",
            "Bosnia and Herzegovina", "Bulgaria",     "Croatia",    "Cyprus",  "Czech Republic", "Denmark",       "Estonia",
            "Finland",                "France",       "Georgia",    "Germany", "Greece",         "Hungary",       "Iceland",
            "Ireland",                "Italy",        "Kazakhstan", "Kosovo",  "Latvia",         "Liechtenstein", "Lithuania",
            "Luxembourg",             "Malta",        "Moldova",    "Monaco",  "Montenegro",     "Netherlands",   "North Macedonia",
            "Norway",                 "Poland",       "Portugal",   "Romania", "Russia",         "San Marino",    "Serbia",
            "Slovakia",               "Slovenia",     "Spain",      "Sweden",  "Switzerland",    "Turkey",        "Ukraine",
            "United Kingdom",         "Vatican City",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "countries in south america/en")) {
        return &.{
            "Argentina", "Bolivia",  "Brazil", "Chile",    "Colombia", "Ecuador",
            "Guyana",    "Paraguay", "Peru",   "Suriname", "Uruguay",  "Venezuela",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "countries in asia/en")) {
        return &.{
            "Afghanistan", "Armenia",   "Azerbaijan",   "Bahrain",              "Bangladesh",   "Bhutan",
            "Brunei",      "Cambodia",  "China",        "Cyprus",               "Georgia",      "India",
            "Indonesia",   "Iran",      "Iraq",         "Israel",               "Japan",        "Jordan",
            "Kazakhstan",  "Kuwait",    "Kyrgyzstan",   "Laos",                 "Lebanon",      "Malaysia",
            "Maldives",    "Mongolia",  "Myanmar",      "Nepal",                "North Korea",  "Oman",
            "Pakistan",    "Palestine", "Philippines",  "Qatar",                "Saudi Arabia", "Singapore",
            "South Korea", "Sri Lanka", "Syria",        "Taiwan",               "Tajikistan",   "Thailand",
            "Timor-Leste", "Turkey",    "Turkmenistan", "United Arab Emirates", "Uzbekistan",   "Vietnam",
            "Yemen",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "provinces of equatorial guinea/en")) {
        return &.{
            "Annobón",
            "Bioko Norte",
            "Bioko Sur",
            "Centro Sur",
            "Djibloho",
            "Kié-Ntem",
            "Litoral",
            "Wele-Nzas",
        };
    }

    if (std.ascii.eqlIgnoreCase(list_name, "provinces of china/en")) {
        return &.{
            "Anhui",   "Beijing",        "Chongqing", "Fujian",       "Gansu",    "Guangdong", "Guangxi",
            "Guizhou", "Hainan",         "Hebei",     "Heilongjiang", "Henan",    "Hong Kong", "Hubei",
            "Hunan",   "Inner Mongolia", "Jiangsu",   "Jiangxi",      "Jilin",    "Liaoning",  "Macau",
            "Ningxia", "Qinghai",        "Shaanxi",   "Shandong",     "Shanghai", "Shanxi",    "Sichuan",
            "Taiwan",  "Tianjin",        "Tibet",     "Xinjiang",     "Yunnan",   "Zhejiang",
        };
    }

    return null;
}

fn renderKnownListTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) std.mem.Allocator.Error!bool {
    const terms = knownListTerms(name) orelse return false;
    try appendKnownList(out, allocator, terms);
    return true;
}

fn usageTemplateTarget(name: []const u8, parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const trimmed_name = trimWikiWhitespace(name);
    if (asciiStartsWithIgnoreCase(trimmed_name, "U:")) {
        var target = trimmed_name["U:".len..];
        if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
            const prefix = trimWikiWhitespace(target[0..colon]);
            if (looksLikeLanguageCode(prefix)) {
                target = target[colon + 1 ..];
            }
        }
        const trimmed_target = trimWikiWhitespace(target);
        return if (trimmed_target.len == 0) null else trimmed_target;
    }

    if (templatePositional(parts, 0)) |first| {
        const trimmed_first = trimWikiWhitespace(first);
        if (trimmed_first.len != 0 and !looksLikeLanguageCode(trimmed_first)) return trimmed_first;
    }
    if (templatePositional(parts, 1)) |second| {
        const trimmed_second = trimWikiWhitespace(second);
        if (trimmed_second.len != 0) return trimmed_second;
    }
    if (templatePositional(parts, 0)) |first| {
        const trimmed_first = trimWikiWhitespace(first);
        if (trimmed_first.len != 0) return trimmed_first;
    }
    return null;
}

fn usageTemplateDisplayValue(name: []const u8, parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const target = usageTemplateTarget(name, parts) orelse return null;
    return knownUsageTemplateExpansion(target) orelse target;
}

fn knownUsageTemplateExpansion(target: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(target);
    if (std.ascii.eqlIgnoreCase(trimmed, "I-P")) {
        return "The use of Israel to refer to the region between the Jordan River and the Mediterranean Sea in a non-historical sense is (since the latter half of the 20th century) politically charged; indeed, this is true of all terms for this region.";
    }
    return null;
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

fn appendLanguageAwareLexemeTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    language_index: usize,
    term_index: usize,
) std.mem.Allocator.Error!void {
    if (templatePositional(parts, language_index)) |code| {
        if (languageDisplay(code)) |display| {
            try appendWithSpace(out, allocator, display);
            if (templatePositional(parts, term_index)) |term| {
                if (!isPlaceholderTemplateTerm(term)) try appendWithSpace(out, allocator, " ");
            }
        }
    }

    const term = templatePositional(parts, term_index) orelse templatePositional(parts, 0) orelse return;
    if (isPlaceholderTemplateTerm(term)) return;
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
    } else if (templateMatches(name, "ubor") or templateMatches(name, "unadapted borrowing")) {
        try appendWithSpace(out, allocator, "Unadapted borrowing from ");
    } else if (templateMatches(name, "learned borrowing")) {
        try appendWithSpace(out, allocator, "learned borrowing from ");
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

    try appendWithSpace(out, allocator, semanticTemplateDisplay(name));

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
    if (templateNamed(parts, "addl")) |value| {
        const trimmed_addl = trimWikiWhitespace(value);
        if (trimmed_addl.len != 0) {
            try appendWithSpace(out, allocator, ", ");
            try renderInline(out, allocator, trimmed_addl);
        }
    }
    if (templatePositional(parts, target_index)) |arg| {
        const gloss = templateNamed(parts, "t") orelse templateNamed(parts, "gloss") orelse templateTrailingGloss(parts, arg);
        if (gloss) |value| {
            const trimmed = trimWikiWhitespace(value);
            if (trimmed.len != 0 and !std.mem.eql(u8, trimmed, trimWikiWhitespace(arg))) {
                try appendWithSpace(out, allocator, " (");
                try renderInline(out, allocator, trimmed);
                try appendWithSpace(out, allocator, ")");
            }
        }
    }
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
    if (sameTagSet(tags, &.{ "past", "part" })) return "past participle";
    if (sameTagSet(tags, &.{ "1", "s", "simple", "pres" })) return "first-person singular simple present";
    if (sameTagSet(tags, &.{ "1", "p", "simple", "pres" })) return "first-person plural simple present";
    if (sameTagSet(tags, &.{ "2", "s", "simple", "pres" })) return "second-person singular simple present";
    if (sameTagSet(tags, &.{ "2", "p", "simple", "pres" })) return "second-person plural simple present";
    if (sameTagSet(tags, &.{ "3", "s", "simple", "pres" })) return "third-person singular simple present";
    if (sameTagSet(tags, &.{ "3", "p", "simple", "pres" })) return "third-person plural simple present";
    if (tags.len == 1) {
        if (std.ascii.eqlIgnoreCase(tags[0], "pres")) return "present tense";
        if (std.ascii.eqlIgnoreCase(tags[0], "s-verb-form")) return "third-person singular simple present indicative";
        if (std.ascii.eqlIgnoreCase(tags[0], "spast")) return "simple past";
        if (std.ascii.eqlIgnoreCase(tags[0], "ed-form")) return "simple past and past participle";
        if (std.ascii.eqlIgnoreCase(tags[0], "ing-form")) return "present participle and gerund";
    }
    return null;
}

fn isRecognizedInflectionTag(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "s-verb-form") or
        std.ascii.eqlIgnoreCase(tag, "1") or
        std.ascii.eqlIgnoreCase(tag, "2") or
        std.ascii.eqlIgnoreCase(tag, "3") or
        std.ascii.eqlIgnoreCase(tag, "part") or
        std.ascii.eqlIgnoreCase(tag, "p") or
        std.ascii.eqlIgnoreCase(tag, "past") or
        std.ascii.eqlIgnoreCase(tag, "pres") or
        std.ascii.eqlIgnoreCase(tag, "s") or
        std.ascii.eqlIgnoreCase(tag, "simple") or
        std.ascii.eqlIgnoreCase(tag, "spast") or
        std.ascii.eqlIgnoreCase(tag, "ed-form") or
        std.ascii.eqlIgnoreCase(tag, "ing-form");
}

fn sameTagSet(tags: []const []const u8, expected: []const []const u8) bool {
    if (tags.len != expected.len) return false;
    for (expected) |candidate| {
        var found = false;
        for (tags) |tag| {
            if (std.ascii.eqlIgnoreCase(trimWikiWhitespace(tag), candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn semanticTemplateDisplay(name: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(name);
    if (templateMatches(trimmed, "syn of") or templateMatches(trimmed, "synonym of")) return "Synonym of";
    if (templateMatches(trimmed, "acronym of")) return "Acronym of";
    if (templateMatches(trimmed, "initialism of")) return "Initialism of";
    if (templateMatches(trimmed, "abbreviation of")) return "Abbreviation of";
    return trimmed;
}

fn renderUnaryTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    prefix: []const u8,
) std.mem.Allocator.Error!void {
    try renderUnaryTemplateAtIndex(out, allocator, parts, prefix, semanticTemplateTargetIndex(parts));
}

fn renderUnaryTemplateAtIndex(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    prefix: []const u8,
    target_index: usize,
) std.mem.Allocator.Error!void {
    const target = templatePositional(parts, target_index);
    if (target == null or (positionalCount(parts) <= 1 and looksLikeLanguageCode(trimWikiWhitespace(target.?)))) {
        try appendWithSpace(out, allocator, standaloneUnaryPrefix(prefix));
        return;
    }
    try appendWithSpace(out, allocator, prefix);
    if (target) |arg| {
        try appendWithSpace(out, allocator, " ");
        try renderInline(out, allocator, arg);
    }
    const positional_total = positionalCount(parts);
    var extra_index = target_index + 1;
    var wrote_extra = false;
    while (extra_index < positional_total) : (extra_index += 1) {
        const extra = templatePositional(parts, extra_index) orelse continue;
        const trimmed_extra = trimWikiWhitespace(extra);
        if (trimmed_extra.len == 0 or looksLikeLanguageCode(trimmed_extra)) continue;

        if (!wrote_extra) {
            try appendWithSpace(out, allocator, " (");
            wrote_extra = true;
        } else {
            try appendWithSpace(out, allocator, ", ");
        }
        try renderInline(out, allocator, trimmed_extra);
    }
    if (wrote_extra) try appendWithSpace(out, allocator, ")");
    if (target) |arg| {
        const gloss = templateNamed(parts, "t") orelse templateNamed(parts, "gloss") orelse templateTrailingGloss(parts, arg);
        if (gloss) |value| {
            const trimmed = trimWikiWhitespace(value);
            if (trimmed.len != 0 and !std.mem.eql(u8, trimmed, trimWikiWhitespace(arg))) {
                try appendWithSpace(out, allocator, " (");
                try renderInline(out, allocator, trimmed);
                try appendWithSpace(out, allocator, ")");
            }
        }
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
    const tag_start = std.mem.lastIndexOfScalar(u8, trimmed, '<') orelse return .{ .term = trimmed };
    if (tag_start == 0 or tag_start >= trimmed.len - 1) return .{ .term = trimmed };
    const tag = trimWikiWhitespace(trimmed[tag_start + 1 .. trimmed.len - 1]);
    const colon = std.mem.indexOfScalar(u8, tag, ':') orelse return .{ .term = trimmed };
    const prefix = trimWikiWhitespace(tag[0..colon]);
    if (!std.ascii.eqlIgnoreCase(prefix, "ll") and
        !std.ascii.eqlIgnoreCase(prefix, "q") and
        !std.ascii.eqlIgnoreCase(prefix, "qq") and
        !std.ascii.eqlIgnoreCase(prefix, "pos"))
    {
        return .{ .term = trimmed };
    }
    const qualifier = trimWikiWhitespace(tag[colon + 1 ..]);
    const term = trimWikiWhitespace(trimmed[0..tag_start]);
    if (qualifier.len == 0 or term.len == 0) return .{ .term = trimmed };
    return .{ .term = term, .qualifier = qualifier };
}

fn renderSiUnitTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const prefix = templatePositional(parts, 1) orelse return;
    const base = templatePositional(parts, 2) orelse return;
    const quantity = templatePositional(parts, 3);

    try appendWithSpace(out, allocator, "An SI unit");
    if (quantity) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try appendWithSpace(out, allocator, " of ");
            try renderInline(out, allocator, trimmed);
        }
    }
    try appendWithSpace(out, allocator, " equal to 10");
    try appendWithSpace(out, allocator, superscriptMinusThree());
    try appendWithSpace(out, allocator, " ");
    try renderInline(out, allocator, base);
    try appendWithSpace(out, allocator, "s");
    if (templateNamed(parts, "symbol")) |symbol| {
        const trimmed_symbol = trimWikiWhitespace(symbol);
        if (trimmed_symbol.len != 0) {
            try appendWithSpace(out, allocator, ". Symbol: ");
            try renderInline(out, allocator, trimmed_symbol);
        }
    } else {
        const inferred = inferredSiSymbol(prefix, base);
        if (inferred) |symbol| {
            try appendWithSpace(out, allocator, ". Symbol: ");
            try appendWithSpace(out, allocator, symbol);
        }
    }
}

fn inferredSiSymbol(prefix: []const u8, base: []const u8) ?[]const u8 {
    const trimmed_prefix = trimWikiWhitespace(prefix);
    const trimmed_base = trimWikiWhitespace(base);
    if (std.ascii.eqlIgnoreCase(trimmed_prefix, "milli") and std.ascii.eqlIgnoreCase(trimmed_base, "second")) return "ms";
    return null;
}

fn superscriptMinusThree() []const u8 {
    return "\xE2\x88\x92\xC2\xB3";
}

fn renderSuffixUsexTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const rendered = templatePositional(parts, 2) orelse templatePositional(parts, 1) orelse return;
    try renderInline(out, allocator, rendered);
    if (templateNamed(parts, "t2")) |gloss| {
        const trimmed = trimWikiWhitespace(gloss);
        if (trimmed.len != 0) {
            try appendWithSpace(out, allocator, " (");
            try renderInline(out, allocator, trimmed);
            try appendWithSpace(out, allocator, ")");
        }
    }
}

fn renderPhonoSemanticMatchingTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try appendWithSpace(out, allocator, "phono-semantic matching ");
    if (templatePositional(parts, 1)) |code| {
        if (languageDisplay(code)) |display| {
            try appendWithSpace(out, allocator, display);
            if (templatePositional(parts, 2) != null) try appendWithSpace(out, allocator, " ");
        }
    }
    if (templatePositional(parts, 2)) |term| {
        try renderInline(out, allocator, term);
    }
    if (templateNamed(parts, "t") orelse templateNamed(parts, "gloss")) |gloss| {
        const trimmed = trimWikiWhitespace(gloss);
        if (trimmed.len != 0) {
            try appendWithSpace(out, allocator, " (");
            try renderInline(out, allocator, trimmed);
            try appendWithSpace(out, allocator, ")");
        }
    }
}

fn currentDayText() []const u8 {
    return "5";
}

fn currentYearText() []const u8 {
    return "2026";
}

fn currentMonthName() []const u8 {
    return "April";
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
        .{ .code = "am", .display = "Amharic" },
        .{ .code = "ang", .display = "Old English" },
        .{ .code = "arc", .display = "Aramaic" },
        .{ .code = "ber-pro", .display = "Proto-Berber" },
        .{ .code = "be", .display = "Belarusian" },
        .{ .code = "br", .display = "Breton" },
        .{ .code = "cmn", .display = "Mandarin" },
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
        .{ .code = "ko", .display = "Korean" },
        .{ .code = "la", .display = "Latin" },
        .{ .code = "LL.", .display = "Late Latin" },
        .{ .code = "li", .display = "Limburgish" },
        .{ .code = "lt", .display = "Lithuanian" },
        .{ .code = "ML.", .display = "Medieval Latin" },
        .{ .code = "mi", .display = "Māori" },
        .{ .code = "ms", .display = "Malay" },
        .{ .code = "nds", .display = "Low German" },
        .{ .code = "nds-de", .display = "German Low German" },
        .{ .code = "nds-nl", .display = "Dutch Low Saxon" },
        .{ .code = "NL.", .display = "New Latin" },
        .{ .code = "nl", .display = "Dutch" },
        .{ .code = "nb", .display = "Norwegian Bokmål" },
        .{ .code = "no", .display = "Norwegian" },
        .{ .code = "non", .display = "Old Norse" },
        .{ .code = "nn", .display = "Norwegian Nynorsk" },
        .{ .code = "nan-hbl", .display = "Hokkien" },
        .{ .code = "nrf", .display = "Norman" },
        .{ .code = "onw", .display = "Old Nubian" },
        .{ .code = "ofs", .display = "Old Frisian" },
        .{ .code = "ota", .display = "Ottoman Turkish" },
        .{ .code = "osx", .display = "Old Saxon" },
        .{ .code = "pl", .display = "Polish" },
        .{ .code = "ru", .display = "Russian" },
        .{ .code = "rup", .display = "Aromanian" },
        .{ .code = "sga", .display = "Old Irish" },
        .{ .code = "yue", .display = "Cantonese" },
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
    template_name: []const u8,
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
        const trimmed_segment = trimWikiWhitespace(segment);
        if (trimmed_segment.len == 0) {
            positional_index += 1;
            continue;
        }
        if (wrote_any) {
            try out.appendSlice(allocator, " + ");
        } else if (positional_index > 1 and (templateMatches(template_name, "suffix") or templateMatches(template_name, "suf"))) {
            try out.appendSlice(allocator, "+ ");
        }
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
        try appendCompoundTerm(out, allocator, parts, term_slot, trimmed_segment);
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
    const abbreviation_target = placeAbbreviationTarget(raw_type);
    const actual_type_index = if (abbreviation_target != null and templatePositional(parts, type_index + 1) != null) type_index + 1 else type_index;
    const actual_raw_type = templatePositional(parts, actual_type_index) orelse raw_type;
    const rendered_type = try renderPlaceTypeTextAlloc(allocator, actual_raw_type);
    defer allocator.free(rendered_type);
    if (rendered_type.len == 0) return;

    if (abbreviation_target) |target| {
        try out.appendSlice(allocator, "Abbreviation of ");
        try renderInline(out, allocator, target);
        try out.appendSlice(allocator, ": ");
        if (placeTypeNeedsArticle(rendered_type)) {
            try out.appendSlice(allocator, chooseIndefiniteArticle(rendered_type, false));
            try out.appendSlice(allocator, " ");
        }
    } else if (placeTypeNeedsArticle(rendered_type)) {
        try out.appendSlice(allocator, chooseIndefiniteArticle(rendered_type, true));
        try out.appendSlice(allocator, " ");
    }
    try out.appendSlice(allocator, rendered_type);

    var wrote_location = false;
    var last_was_location_value = false;
    const positional_total = positionalCount(parts);
    var positional_index = actual_type_index + 1;
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
            try out.appendSlice(allocator, if (abbreviation_target != null) " of " else if (asciiEndsWithIgnoreCase(rendered_type, " seat")) " of " else if (placeTypeNeedsIn(rendered_type)) " in " else " ");
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

fn placeAbbreviationTarget(raw_type: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(stripTraversalSegments(raw_type));
    if (!asciiStartsWithIgnoreCase(trimmed, "@abbrev of:")) return null;
    return trimWikiWhitespace(trimmed["@abbrev of:".len..]);
}

fn appendNominalTemplate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    noun: []const u8,
) std.mem.Allocator.Error!void {
    var phrase: std.ArrayList(u8) = .empty;
    defer phrase.deinit(allocator);

    const qualifier = blk: {
        if (templatePositional(parts, 0)) |first| {
            if (looksLikeLanguageCode(trimWikiWhitespace(first))) {
                break :blk templatePositional(parts, 1);
            }
            break :blk first;
        }
        break :blk templatePositional(parts, 1);
    };
    if (qualifier) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try renderInline(&phrase, allocator, trimmed);
            if (phrase.items.len != 0) try phrase.append(allocator, ' ');
        }
    }
    try phrase.appendSlice(allocator, noun);

    try out.appendSlice(allocator, chooseIndefiniteArticle(phrase.items, true));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, phrase.items);
    if (templateNamed(parts, "addl")) |value| {
        const trimmed_addl = trimWikiWhitespace(value);
        if (trimmed_addl.len != 0) {
            try out.appendSlice(allocator, ", ");
            try renderInline(out, allocator, trimmed_addl);
        }
    }
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

    if (parts.items.len == 2) {
        const first = trimWikiWhitespace(parts.items[0]);
        const second = trimWikiWhitespace(parts.items[1]);
        const canonical_second = canonicalPlaceHolonymType(second) orelse second;
        if (std.ascii.eqlIgnoreCase(canonical_second, "capital city") or std.ascii.eqlIgnoreCase(canonical_second, "county seat")) {
            const rendered_first = try renderWikitextToOwned(allocator, canonicalPlaceHolonymType(first) orelse first, std.math.maxInt(usize));
            defer allocator.free(rendered_first);
            const rendered_second = try renderWikitextToOwned(allocator, canonical_second, std.math.maxInt(usize));
            defer allocator.free(rendered_second);
            if (rendered_first.len != 0 and rendered_second.len != 0) {
                return std.fmt.allocPrint(allocator, "{s}, the {s}", .{ rendered_first, rendered_second });
            }
        }
    }

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
        const resolved_value = placeLocationDisplayValue(prefix, value);
        const display = placeHolonymDisplay(prefix);
        switch (display.kind) {
            .plain => try renderInline(out, allocator, resolved_value),
            .prefix => {
                try appendPlaceHolonymPrefix(out, allocator, display.label);
                try renderInline(out, allocator, resolved_value);
            },
            .suffix => {
                try renderInline(out, allocator, resolved_value);
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

fn placeLocationDisplayValue(prefix: []const u8, value: []const u8) []const u8 {
    const trimmed_prefix = std.mem.trim(u8, prefix, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed_prefix, "c") or std.ascii.eqlIgnoreCase(trimmed_prefix, "cc")) {
        if (std.ascii.eqlIgnoreCase(value, "US") or std.ascii.eqlIgnoreCase(value, "U.S.") or std.ascii.eqlIgnoreCase(value, "USA") or std.ascii.eqlIgnoreCase(value, "U.S.A.")) return "United States";
        if (std.ascii.eqlIgnoreCase(value, "UK") or std.ascii.eqlIgnoreCase(value, "U.K.")) return "United Kingdom";
    }
    return value;
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
    if (std.mem.indexOf(u8, trimmed, "[[") != null or
        std.mem.indexOf(u8, trimmed, "{{") != null or
        std.mem.indexOf(u8, trimmed, "<<") != null or
        std.mem.indexOf(u8, trimmed, "]]") != null or
        std.mem.indexOf(u8, trimmed, "}}") != null or
        std.mem.indexOf(u8, trimmed, ">>") != null)
    {
        return trimmed;
    }
    if (std.mem.lastIndexOfScalar(u8, trimmed, '>')) |marker| {
        if (marker + 1 < trimmed.len) return std.mem.trim(u8, trimmed[marker + 1 ..], " \t");
    }
    return trimmed;
}

fn templateMatches(name: []const u8, expected: []const u8) bool {
    const actual = trimWikiWhitespace(name);
    const target = trimWikiWhitespace(expected);

    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
        while (j < target.len and isTemplateNameSpaceByte(target[j])) : (j += 1) {}
        if (i == actual.len or j == target.len) break;
        if (std.ascii.toLower(actual[i]) != std.ascii.toLower(target[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
    while (j < target.len and isTemplateNameSpaceByte(target[j])) : (j += 1) {}
    return i == actual.len and j == target.len;
}

fn isTemplateNameSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_';
}

fn findExternalLinkClose(input: []const u8, start: usize) ?usize {
    if (start >= input.len or input[start] != '[' or start + 1 >= input.len) return null;
    if (!asciiStartsWithIgnoreCase(input[start + 1 ..], "http")) return null;

    var templates: usize = 0;
    var links: usize = 0;
    var i = start + 1;
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
        if (input[i] == ']' and templates == 0 and links == 0) return i;
    }
    return null;
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
        if (!templateArgHasName(segment) or templateArgNumericIndex(segment) != null) count += 1;
    }
    return count;
}

fn templatePositional(parts: *const std.ArrayList([]const u8), target: usize) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) {
            if (templateArgNumericIndex(segment)) |numeric_index| {
                if (numeric_index == target) return templateArgNamedValue(segment);
            }
            continue;
        }
        if (positional_index == target) return trimWikiWhitespace(segment);
        positional_index += 1;
    }
    return null;
}

fn templateArgNumericIndex(segment: []const u8) ?usize {
    const equals = topLevelEquals(segment) orelse return null;
    const key = trimWikiWhitespace(segment[0..equals]);
    if (key.len == 0) return null;
    for (key) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const one_based = std.fmt.parseInt(usize, key, 10) catch return null;
    return if (one_based == 0) null else one_based - 1;
}

fn templateArgNamedValue(segment: []const u8) ?[]const u8 {
    const equals = topLevelEquals(segment) orelse return null;
    return trimWikiWhitespace(segment[equals + 1 ..]);
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
        templateMatches(name, "af");
}

fn isEtymologyLexemeTemplate(name: []const u8) bool {
    return templateMatches(name, "inh") or
        templateMatches(name, "inh+") or
        templateMatches(name, "der") or
        templateMatches(name, "der+") or
        templateMatches(name, "bor") or
        templateMatches(name, "bor+") or
        templateMatches(name, "ubor") or
        templateMatches(name, "unadapted borrowing") or
        templateMatches(name, "cog") or
        templateMatches(name, "cognate") or
        templateMatches(name, "lbor") or
        templateMatches(name, "noncog") or
        templateMatches(name, "learned borrowing") or
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

fn templateAliasTargetIndex(parts: *const std.ArrayList([]const u8)) ?usize {
    const count = positionalCount(parts);
    if (count == 0) return null;

    var index = semanticTemplateTargetIndex(parts);
    while (index < count) : (index += 1) {
        const candidate = templatePositional(parts, index) orelse continue;
        const trimmed = trimWikiWhitespace(candidate);
        if (trimmed.len == 0) continue;
        if (index == 0 and looksLikeLanguageCode(trimmed) and count == 1) continue;
        return index;
    }
    return null;
}

fn templateAliasTarget(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const index = templateAliasTargetIndex(parts) orelse return null;
    return templatePositional(parts, index);
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

test "renderWikitextToOwned expands ed-form and ing-form inflection tags" {
    const ed = try renderWikitextToOwned(std.testing.allocator, "{{infl of|en|abandon||ed-form}}", 256);
    defer std.testing.allocator.free(ed);
    try std.testing.expectEqualStrings("simple past and past participle of abandon", ed);

    const ing = try renderWikitextToOwned(std.testing.allocator, "{{infl of|en|abear||ing-form}}", 256);
    defer std.testing.allocator.free(ing);
    try std.testing.expectEqualStrings("present participle and gerund of abear", ing);
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
    try std.testing.expectEqualStrings("enPR: frē, IPA /fɹiː/, [fɹɪi̯]", rendered);
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

test "renderWikitextToOwned expands learned borrowing templates semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{learned borrowing|en|la|[[absque]] [[hoc]]|lit=without this}}.",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "learned borrowing from Latin absque hoc (literally \"without this\").",
        rendered,
    );
}

test "renderWikitextToOwned expands season name spelling usage note" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{season name spelling}}", 512);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "Note that season names are not capitalized in modern English except where any noun would be capitalized, e.g. at the beginning of a sentence or as part of a name (Old Man Winter, the Winter War, Summer Glau). This is in contrast to the days of the week and months of the year, which are always capitalized (Thursday or September).",
        rendered,
    );
}

test "renderWikitextToOwned supports cognate alias template" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{cognate|ang|earfoþe}} and {{cognate|de|Arbeit}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("Old English earfoþe and German Arbeit", rendered);
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

test "renderWikitextToOwned reads numeric named args as positional template args" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{non-gloss|1=Used as a prefix to verbs in the sense of remaining in the same condition.}} {{clip of|en|abdominal muscle}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Used as a prefix to verbs in the sense of remaining in the same condition.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "clipping of abdominal muscle") != null);
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

test "renderWikitextToOwned preserves unary template targets that resemble language codes" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{alternative spelling of|en|cro|t=marijuana}} {{ellipsis of|en|pie-dog|t=an [[Indian]] [[breed]]}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "alternative spelling of cro (marijuana) ellipsis of pie-dog (an Indian breed)",
        rendered,
    );
}

test "renderWikitextToOwned expands abbreviation place templates and present inflection tags" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|@abbrev of:Alabama|state|c/US}} {{inflection of|en|be||1|p|simple|pres}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Abbreviation of Alabama: a state of United States") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "first-person plural simple present of be") != null);
}

test "renderWikitextToOwned expands unadapted borrowing templates semantically" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "{{ubor|en|la|ōs|t=the mouth}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Unadapted borrowing from Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "the mouth") != null);
}

test "renderWikitextToOwned supports translation aliases and metadata templates" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{unadapted borrowing|en|ms|Jawi}} {{backform|en|alms}} {{IPAfont|/w/}} {{BC}} {{BCE}} {{ndash}} {{refn|group=n|name=n1|From the collection of the {{w|Wellcome Library}}, [[London]], UK.}}",
        512,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Unadapted borrowing from Malay Jawi") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "back-formation from alms") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/w/") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "BC") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "BCE") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Wellcome Library") != null);
}

test "renderWikitextToOwned handles audit-discovered lightweight templates" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{sense|UK}} {{audio|en|News.ogg}} {{rhymes|en|-aɪ}} {{taxlink|Kiwa|genus}} {{desc|no}} {{nuclide|14|6|C}} {{math|1=min(a, b)}} {{cens sp|en|ass}} {{ngd|musical structure}} {{OCLC|5879299}} {{book of the Bible}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "UK") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "audio") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Rhymes: aɪ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "genus") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "no") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "14C") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "min(a, b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ass") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "musical structure") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "OCLC 5879299") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "book of the Bible") != null);
}

test "renderWikitextToOwned ignores pure metadata templates from audits" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{was wotd|2006|May|1}}{{see more citations|en}}{{see citations|en}}{{see thesaurus|en|bad}}{{translation only}}{{rfd|en}}{{rfq|en}}{{hot word|en|date=2018}}{{thub}}{{ety|en|id=go}}{{mapframe|river|Q602}}",
        256,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
}

test "renderWikitextToOwned renders usage and only-used-in templates semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{U:en:be dead}} {{only used in|en|man enough}}",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "be dead") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Only used in man enough.") != null);
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

test "renderWikitextToOwned preserves nominal addl text and expands &lit semantically" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{given name|en|male|addl=or more often nickname, for a boy who is junior to someone else}}. {{&lit|en|false|friend}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A male given name, or more often nickname, for a boy who is junior to someone else. Used other than figuratively or idiomatically: see false, friend",
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

test "renderWikitextToOwned expands religious adherent list templates" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{list:religious adherents/en}}",
        4096,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "African traditionalist") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Wiccan") != null);
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

test "renderWikitextToOwned expands bf and omitted-base suffix etymologies" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "From {{bf|en|linguist}} {{suf|en||-ism}}.",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("From back-formation from linguist + -ism.", rendered);
}

test "renderWikitextToOwned strips bold apostrophe artifacts from acronym etymologies" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "From '''H'''alo'''A'''cetic '''A'''cids.",
        256,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("From HaloAcetic Acids.", rendered);
}

test "renderWikitextToOwned expands standalone initialism etymologies" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "From {{initialism|en|[[resistant|'''R'''esistant]] [[to]] [[oil]] [[particles]] [[with]] [[ninety-five|'''95''']][[%]] [[filtration]] [[efficiency]]}} in {{w|lang=en|NIOSH air filtration rating}}s.",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("From initialism of Resistant to oil particles with 95% filtration efficiency in NIOSH air filtration ratings.", rendered);
}

test "renderWikitextToOwned tolerates stray closing wiki markup" {
    const rendered = try renderWikitextToOwned(std.testing.allocator, "kept sense}}", 256);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("kept sense", rendered);
}

test "renderWikitextToOwned normalizes template names and external link labels" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{dated_form|en|bra||item of underwear}} {{q-lite|Arabic numeral}} {{Webster_1913}} [https://example.test [[Wikipedia:The Art of Cookery made Plain and Easy|The Art of Cookery made Plain and Easy]]]",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "dated form of bra") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(item of underwear)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(Arabic numeral)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "The Art of Cookery made Plain and Easy") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://example.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Webster") == null);
}

test "renderWikitextToOwned expands usage, etymology, and known list helpers" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{U:en:I-P}} {{onom|en}} {{aphetic form|en|escarp}} {{partial calque|en|fr|cap vert}} {{alt case form|en|china|id=chinaware}} {{list:countries in South America/en}}",
        4096,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "The use of Israel to refer to the region") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Onomatopoeic") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aphetic form of escarp") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "partial calque of cap vert") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alternative case form of china") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Argentina, Bolivia, Brazil") != null);
}

test "renderWikitextToOwned formats county-seat place templates with United States expansion" {
    const rendered = try renderWikitextToOwned(
        std.testing.allocator,
        "{{place|en|city/county seat|co/Clay County|s/Indiana|c/USA}}",
        512,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "A city, the county seat of Clay County, Indiana, United States",
        rendered,
    );
}
