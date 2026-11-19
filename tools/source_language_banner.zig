//! Source-bound static language banners. This module creates no registry alias.
const std = @import("std");
const encoder = @import("encoder");
const namespaces = @import("namespace_registry");
const languages = @import("language_registry.zig");
const syntax = encoder.wikitext_syntax;
const Behavior = namespaces.behavior_switches.Registry;

fn controlAt(behavior: ?*const Behavior, source: []const u8, at: usize) std.mem.Allocator.Error!?usize {
    return if (behavior) |registry| registry.matchAt(std.heap.page_allocator, source, at) else syntax.behaviorSwitchEnd(source, at);
}
fn containsControl(behavior: ?*const Behavior, source: []const u8) bool {
    for (0..source.len) |at| if ((controlAt(behavior, source, at) catch return true) != null) return true;
    return false;
}
fn plain(source: []const u8) bool {
    if (source.len == 0 or std.mem.indexOfAny(u8, source, "[]{}<>&|=\"'") != null) return false;
    for (source) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn hiddenCategory(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior) bool {
    const input = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, input, "[[") or !std.mem.endsWith(u8, input, "]]")) return false;
    if (std.mem.indexOfAny(u8, input[2 .. input.len - 2], "[]{}<>&") != null or containsControl(behavior, input)) return false;
    for (input) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var iterator: encoder.document_ir.InlineIterator = .{ .input = input, .renderer_boundaries = true };
    const link = iterator.next() orelse return false;
    if (link.kind != .link or link.trail.len != 0 or iterator.cursor != input.len or iterator.next() != null) return false;
    const target = std.mem.trim(u8, link.target, " ");
    if (target.len == 0 or target[0] == ':') return false;
    const category = ns.ofTitle(target);
    return category.id == 14 and std.mem.trim(u8, category.text, " ").len != 0;
}

/// Conservative static source proofs. The known-name branch retains its
/// original grammar; the literal-code branch admits one finite neutral wrapper
/// shape only. Neither branch projects dynamic parameters or emitted prose.
pub fn parse(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    return parseKnownNames(source, ns, behavior, registry, code) orelse
        parseFlaggedName(source, ns, behavior, registry, code) orelse
        parseLiteralCode(source, ns, behavior, registry, code) orelse
        parseEmphasizedCode(source, ns, behavior, registry, code) orelse
        parseCategoryLinkedHeading(source, ns, behavior, registry, code);
}

fn bannerCategoryName(link: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior) ?[]const u8 {
    if (!std.mem.startsWith(u8, link, "[[") or !std.mem.endsWith(u8, link, "]]") or
        !hiddenCategory(link, ns, behavior) or std.mem.indexOfAny(u8, link, "|#") != null) return null;
    return ns.ofTitle(link[2 .. link.len - 2]).text;
}

// Some static banners declare an ordinary H2 label followed by an emphasized
// language code. Keep the complete authored heading, including its styling.
fn parseEmphasizedCode(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code) or
        std.mem.indexOf(u8, source, "<onlyinclude>") != null or std.mem.indexOf(u8, source, "</onlyinclude>") != null) return null;
    const open = "<includeonly>";
    const close = "</includeonly>";
    const begin = std.mem.indexOf(u8, source, open) orelse return null;
    const end = std.mem.indexOfPos(u8, source, begin + open.len, close) orelse return null;
    const category = source[begin + open.len .. end];
    const label = bannerCategoryName(category, ns, behavior) orelse return null;
    if (!plain(label) or std.mem.indexOfAny(u8, label, ":#") != null or
        !registry.sourceBannerLiteralCodeNameCompatible(code, label)) return null;
    if (begin != 0) {
        // The French provider repeats the identical category outside includeonly.
        if (source[begin - 1] != '\n') return null;
        const first = std.mem.trimEnd(u8, source[0..begin], "\r\n");
        const repeated = bannerCategoryName(first, ns, behavior) orelse return null;
        if (!std.mem.eql(u8, repeated, label)) return null;
    }
    const after = source[end + close.len ..];
    if (!std.mem.startsWith(u8, after, "\n") and !std.mem.startsWith(u8, after, "\r\n")) return null;
    const body = std.mem.trimStart(u8, after, "\r\n");
    const newline = std.mem.indexOfScalar(u8, body, '\n') orelse return null;
    const heading = syntax.controlHeading(std.mem.trimEnd(u8, body[0..newline], "\r"), null) orelse return null;
    if (heading.level != 2 or !std.mem.startsWith(u8, heading.title, label)) return null;
    const rest = heading.title[label.len..];
    if (rest.len == 0 or rest[0] != ' ') return null;
    var suffix = std.mem.trimStart(u8, rest, " ");
    for (0..3) |_| suffix = unwrapNeutral(suffix, "small") orelse return null;
    if (suffix.len != code.len + 8 or !std.mem.startsWith(u8, suffix, "'''(") or
        !std.mem.endsWith(u8, suffix, ")'''") or !std.mem.eql(u8, suffix[4 .. suffix.len - 4], code)) return null;
    const tail = std.mem.trim(u8, body[newline + 1 ..], "\r\n");
    if (!std.mem.startsWith(u8, tail, "<br><noinclude>")) return null;
    if ((excludedDocumentationEnd(tail, "<br>".len) orelse return null) != tail.len) return null;
    return .{ .heading = heading.title, .level = heading.level, .target = label, .label = label, .authority = .literal_code };
}

// A source-authenticated literal banner may prefix its known language name
// with one neutral file icon. The icon itself contributes no language evidence.
fn parseFlaggedName(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code)) return null;
    // Blank lines may precede a banner, but indentation cannot create an H2.
    const input = std.mem.trimStart(u8, source, "\r\n");
    if (input.len == 0 or input[0] != '=') return null;
    const end = std.mem.indexOfScalar(u8, input, '\n') orelse return null;
    const heading = syntax.controlHeading(std.mem.trimEnd(u8, input[0..end], " \t\r"), null) orelse return null;
    if (heading.level != 2 or containsControl(behavior, heading.title) or
        !std.mem.startsWith(u8, heading.title, "[[")) return null;
    const close = std.mem.indexOf(u8, heading.title, "]]") orelse return null;
    const image = heading.title[2..close];
    const pipe = std.mem.indexOfScalar(u8, image, '|') orelse return null;
    const target = image[0..pipe];
    if (std.mem.indexOfAny(u8, target, "[]{}<>&#\r\n") != null) return null;
    const file = ns.ofTitle(target);
    if (file.id != 6 or std.mem.trim(u8, file.text, " \t").len == 0) return null;
    const option = image[pipe + 1 ..];
    if (!std.mem.endsWith(u8, option, "px") or option.len < 3) return null;
    const digits = option[0 .. option.len - 2];
    for (digits) |digit| if (digit < '0' or digit > '9') return null;
    const width = std.fmt.parseInt(u16, digits, 10) catch return null;
    if (width == 0 or width > 4096) return null;
    const suffix = heading.title[close + 2 ..];
    if (suffix.len == 0 or suffix[0] != ' ') return null;
    const label = std.mem.trim(u8, suffix, " ");
    if (!plain(label) or !registry.sourceBannerNameMatches(code, label)) return null;
    // This observed declaration emits only its heading and a hidden category;
    // parameters, projection tags, controls and extra prose cannot supply proof.
    const tail = std.mem.trim(u8, input[end + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, tail, "<includeonly>") or
        !std.mem.endsWith(u8, tail, "</includeonly>")) return null;
    const category = tail["<includeonly>".len .. tail.len - "</includeonly>".len];
    if (!hiddenCategory(category, ns, behavior)) return null;
    return .{ .heading = heading.title, .level = heading.level, .target = label, .label = label };
}

fn parseKnownNames(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code)) return null;
    // Ordinary transclusion selects onlyinclude globally before control removal.
    // This proof admits no such projection, including inside captured aliases.
    if (std.mem.indexOf(u8, source, "<onlyinclude>") != null or
        std.mem.indexOf(u8, source, "</onlyinclude>") != null) return null;
    var cursor: usize = 0;
    var result: ?languages.SourceLanguageBanner = null;
    var emitted_category = false;
    while (cursor < source.len) {
        if (std.ascii.isWhitespace(source[cursor])) { cursor += 1; continue; }
        if (controlAt(behavior, source, cursor) catch return null) |end| {
            // A recognized control is empty only after earlier source parsing.
            // Do not swallow template, link or markup syntax as proof trivia.
            if (std.mem.indexOfAny(u8, source[cursor..end], "[]{}<>&|=\"'") != null) return null;
            const toc = if (behavior) |captured| captured.tocMatchAt(std.heap.page_allocator, source, cursor) catch return null else if (std.ascii.eqlIgnoreCase(source[cursor..end], "__TOC__")) end else null;
            if (toc != null) return null;
            cursor = end;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<noinclude>")) {
            const begin = cursor + "<noinclude>".len;
            const close = std.mem.indexOfPos(u8, source, begin, "</noinclude>") orelse return null;
            if (std.mem.indexOfScalar(u8, source[begin..close], '<') != null) return null;
            cursor = close + "</noinclude>".len;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<includeonly>")) {
            if (result != null or emitted_category) return null;
            const begin = cursor + "<includeonly>".len;
            const close = std.mem.indexOfPos(u8, source, begin, "</includeonly>") orelse return null;
            if (!hiddenCategory(source[begin..close], ns, behavior)) return null;
            emitted_category = true;
            cursor = close + "</includeonly>".len;
            continue;
        }
        // The heading must occupy a real source line. Removed documentation or
        // controls cannot turn an inline equals string into a new line boundary.
        if (result != null or source[cursor] != '=' or
            (cursor != 0 and source[cursor - 1] != '\n')) return null;
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        const line = std.mem.trimEnd(u8, source[cursor..end], " \t\r");
        const heading = syntax.controlHeading(line, null) orelse return null;
        if (heading.level < 1 or heading.level > 2 or containsControl(behavior, heading.title)) return null;
        const label = heading.title;
        if (!std.mem.startsWith(u8, label, "[[")) return null;
        const close = std.mem.indexOf(u8, label, "]]") orelse return null;
        const body = label[2..close];
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse return null;
        const target = std.mem.trim(u8, body[0..pipe], " ");
        const visible = std.mem.trim(u8, body[pipe + 1 ..], " ");
        if (!plain(target) or !plain(visible) or std.mem.indexOfAny(u8, target, ":#") != null or
            !registry.sourceBannerNameMatches(code, target) or !registry.sourceBannerNameMatches(code, visible)) return null;
        const tail = std.mem.trim(u8, label[close + 2 ..], " ");
        if (tail.len != 0) {
            if (tail.len < 3 or tail[0] != '(' or tail[tail.len - 1] != ')') return null;
            const explanation = tail[1 .. tail.len - 1];
            if (!plain(explanation) or std.mem.indexOfAny(u8, explanation, "()") != null) return null;
        }
        result = .{ .heading = label, .level = heading.level, .target = target, .label = visible };
        cursor = end;
    }
    return result;
}

// A separate finite proof for retained static banners containing an explicit
// registered literal code. Ordinary registry names and the known-name grammar
// above stay unchanged. No rendered-text stripping supplies this authority.
fn unwrapNeutral(input: []const u8, name: []const u8) ?[]const u8 {
    const tag = syntax.tagAt(input, 0) orelse return null;
    if (!tag.is(name) or tag.closing or tag.self_closing or
        std.mem.trim(u8, tag.attrs, " \t\r\n").len != 0) return null;
    const pair = syntax.matchingTag(input, tag) orelse return null;
    if (pair.end != input.len) return null;
    return std.mem.trim(u8, input[tag.end..pair.inner_end], " \t");
}

fn literalCodeHeading(heading: []const u8, level: u8, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (containsControl(behavior, heading)) return null;
    const div = syntax.tagAt(heading, 0) orelse return null;
    // The source-observed neutral presentation attributes are exact. In
    // particular no arbitrary class, hidden/style attribute or nested div.
    if (!div.is("div") or div.closing or div.self_closing or
        !std.mem.eql(u8, std.mem.trim(u8, div.attrs, " \t"), "id=\"toc\" class=\"toccolours\"")) return null;
    const pair = syntax.matchingTag(heading, div) orelse return null;
    if (pair.end != heading.len) return null;
    const inner = std.mem.trim(u8, heading[div.end..pair.inner_end], " \t");
    const body = unwrapNeutral(inner, "big") orelse return null;
    if (!std.mem.startsWith(u8, body, "[[")) return literalCodeBareHeading(heading, level, body, registry, code);
    const link = syntax.balanced(body, 0) orelse return null;
    const label_body = body[2..link.inner_end];
    const pipe = std.mem.indexOfScalar(u8, label_body, '|');
    const target = std.mem.trim(u8, label_body[0..pipe orelse label_body.len], " ");
    const visible = std.mem.trim(u8, if (pipe) |at| label_body[at + 1 ..] else label_body, " ");
    if (!plain(target) or !plain(visible) or std.mem.indexOfAny(u8, target, ":#") != null or
        !registry.sourceBannerLiteralCodeNameCompatible(code, target) or
        !registry.sourceBannerLiteralCodeNameCompatible(code, visible)) return null;
    var tail = std.mem.trim(u8, body[link.end..], " \t");
    // Only the source-observed one/two nested small presentation wrappers.
    tail = unwrapNeutral(tail, "small") orelse return null;
    if (std.mem.startsWith(u8, tail, "<")) tail = unwrapNeutral(tail, "small") orelse return null;
    if (tail.len != code.len + 2 or tail[0] != '(' or tail[tail.len - 1] != ')' or
        !std.mem.eql(u8, tail[1 .. tail.len - 1], code)) return null;
    return .{ .heading = heading, .level = level, .target = target, .label = visible, .authority = .literal_code };
}

fn excludedDocumentationEnd(source: []const u8, start: usize) ?usize {
    const begin = start + "<noinclude>".len;
    const close = std.mem.indexOfPos(u8, source, begin, "</noinclude>") orelse return null;
    // Normal transclusion ends at the first closing inclusion tag, without
    // nesting (wikitext/preprocess.zig). Admit plain excluded documentation
    // plus complete comments only; reject other tag/closing interpretations.
    var cursor = begin;
    while (std.mem.indexOfScalarPos(u8, source[0..close], cursor, '<')) |at| {
        if (!std.mem.startsWith(u8, source[at..], "<!--")) return null;
        const end = syntax.protectedEnd(source, at) orelse return null;
        if (end > close or end < at + 7 or !std.mem.endsWith(u8, source[at..end], "-->")) return null;
        if (std.mem.indexOfAny(u8, source[at + 4 .. end - 3], "<>") != null) return null;
        cursor = end;
    }
    return close + "</noinclude>".len;
}

fn parseLiteralCode(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code) or
        std.mem.indexOf(u8, source, "<onlyinclude>") != null or
        std.mem.indexOf(u8, source, "</onlyinclude>") != null) return null;
    var cursor: usize = 0;
    var result: ?languages.SourceLanguageBanner = null;
    var category = false;
    var leading_break = false;
    var trailing_break = false;
    var documentation = false;
    while (cursor < source.len) {
        if (std.ascii.isWhitespace(source[cursor])) { cursor += 1; continue; }
        if (documentation) return null;
        if (controlAt(behavior, source, cursor) catch return null) |end| {
            if (std.mem.indexOfAny(u8, source[cursor..end], "[]{}<>&|=\"'") != null) return null;
            const toc = if (behavior) |captured| captured.tocMatchAt(std.heap.page_allocator, source, cursor) catch return null else if (std.ascii.eqlIgnoreCase(source[cursor..end], "__TOC__")) end else null;
            if (toc != null) return null;
            cursor = end;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<includeonly>")) {
            if (result != null or category or leading_break) return null;
            const begin = cursor + "<includeonly>".len;
            const close = std.mem.indexOfPos(u8, source, begin, "</includeonly>") orelse return null;
            if (!hiddenCategory(source[begin..close], ns, behavior)) return null;
            category = true;
            cursor = close + "</includeonly>".len;
            continue;
        }
        if (std.mem.startsWith(u8, source[cursor..], "<noinclude>")) {
            if (result == null) return null;
            cursor = excludedDocumentationEnd(source, cursor) orelse return null;
            documentation = true;
            continue;
        }
        if (syntax.tagAt(source, cursor)) |tag| if (tag.is("br") and !tag.closing and
            std.mem.trim(u8, tag.attrs, " \t").len == 0) {
            if (result == null) {
                if (leading_break) return null;
                leading_break = true;
            } else {
                if (trailing_break) return null;
                trailing_break = true;
            }
            cursor = tag.end;
            continue;
        };
        if (result != null or source[cursor] != '=' or
            (cursor != 0 and source[cursor - 1] != '\n')) return null;
        const end = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
        const line = std.mem.trimEnd(u8, source[cursor..end], " \t\r");
        const parsed = syntax.controlHeading(line, null) orelse return null;
        if (parsed.level < 1 or parsed.level > 2) return null;
        result = literalCodeHeading(parsed.title, parsed.level, behavior, registry, code) orelse return null;
        // The parser above proves the complete static body. Retain only this
        // exact inclusion projection; neither arbitrary prefix text nor a later
        // matching heading can manufacture a template-to-prefix association.
        if (leading_break and std.mem.startsWith(u8, source, "<includeonly>")) {
            const begin = "<includeonly>".len;
            const close = std.mem.indexOf(u8, source, "</includeonly>") orelse return null;
            const after = close + "</includeonly>".len;
            if (after <= cursor and hiddenCategory(source[begin..close], ns, behavior))
                result.?.emitted_prefix = .{ .category = source[begin..close], .suffix = source[after..cursor] };
        }
        cursor = end;
    }
    return result;
}

// A headingless literal declaration needs its own proof. It must never be
// represented as a fabricated H1/H2 or promoted to an ordinary registry alias.
pub fn parseParagraph(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageParagraph {
    if (source.len > 4096 or containsControl(behavior, source)) return null;
    const split = std.mem.indexOf(u8, source, "<noinclude>") orelse return null;
    const label = source[0..split];
    if (!plain(label) or !std.mem.eql(u8, label, std.mem.trim(u8, label, " ")) or
        !registry.sourceParagraphNameMatches(code, label)) return null;
    const doc_start = split + "<noinclude>".len;
    const doc_end = std.mem.indexOfPos(u8, source, doc_start, "</noinclude>") orelse return null;
    const documentation = source[doc_start..doc_end];
    if (!hiddenCategory(documentation, ns, behavior) or
        std.mem.indexOfScalar(u8, documentation, '|') != null) return null;
    const tail = source[doc_end + "</noinclude>".len..];
    const open = "<includeonly>";
    const close = "</includeonly>";
    if (!std.mem.startsWith(u8, tail, open) or !std.mem.endsWith(u8, tail, close) or
        tail.len < open.len + close.len) return null;
    const category = tail[open.len .. tail.len - close.len];
    if (!hiddenCategory(category, ns, behavior) or std.mem.indexOfScalar(u8, category, '|') != null or
        !std.mem.eql(u8, category, std.mem.trim(u8, category, " \t\r\n"))) return null;
    const target = ns.ofTitle(category[2 .. category.len - 2]);
    if (!std.mem.eql(u8, target.text, label)) return null;
    return .{ .label = label, .category = category };
}

// Retained DV -dv- p2048/r3925 uses a bare name inside the same neutral
// explicit-code wrapper. The code supplies authority; the label is no alias.
fn literalCodeBareHeading(heading: []const u8, level: u8, body: []const u8, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    const small = std.mem.indexOf(u8, body, "<small>") orelse return null;
    const label = std.mem.trimEnd(u8, body[0..small], " \t");
    if (!plain(label) or std.mem.indexOfAny(u8, label, ":#") != null or
        !registry.sourceBannerLiteralCodeNameCompatible(code, label)) return null;
    var tail = unwrapNeutral(body[small..], "small") orelse return null;
    if (std.mem.startsWith(u8, tail, "<")) tail = unwrapNeutral(tail, "small") orelse return null;
    if (tail.len != code.len + 2 or tail[0] != '(' or tail[tail.len - 1] != ')' or
        !std.mem.eql(u8, tail[1 .. tail.len - 1], code)) return null;
    return .{ .heading = heading, .level = level, .target = label, .label = label, .authority = .literal_code };
}

// A code-named template may spell its language through an interface message
// while linking to one exact Help page. The message key repeats the registered
// code; neither the namespace nor the translated message supplies an alias.
pub fn messageLinkTarget(source: []const u8, ns: *const namespaces.Registry, code: []const u8) ?[]const u8 {
    if (source.len > 4096 or code.len == 0) return null;
    const input = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, input, "[[")) return null;
    const separator = std.mem.indexOf(u8, input, "|{{int:wikt-") orelse return null;
    const target = input[2..separator];
    if (!plain(target) or std.mem.indexOfScalar(u8, target, '#') != null or
        !std.mem.eql(u8, target, std.mem.trim(u8, target, " ")) or ns.ofTitle(target).id != 12) return null;
    var rest = input[separator + "|{{int:wikt-".len ..];
    if (!std.mem.startsWith(u8, rest, code)) return null;
    rest = rest[code.len..];
    if (!std.mem.startsWith(u8, rest, "}}]]<noinclude>")) return null;
    rest = rest["}}]]<noinclude>".len..];
    if (!std.mem.endsWith(u8, rest, "</noinclude>")) return null;
    if (!hiddenCategory(rest[0 .. rest.len - "</noinclude>".len], ns, null)) return null;
    return target;
}

/// This complete selected transclusion names its language in positional field 1.
/// Its dynamic name formatter changes display text, never the emitted code.
/// Documentation is wholly excluded; modified executable source grants no proof.
pub fn parseCodeDeclaration(source: []const u8, ns: *const namespaces.Registry) ?[]const u8 {
    const input = std.mem.trim(u8, source, " \t\r\n");
    const included = "<includeonly><span id=\"{{{{{1}}}}}\" class=\"lang\" data-code=\"{{{1}}}\" data-name=\"{{#invoke:bahasa|getLangName|{{{1}}}}}\">{{#if:{{{1|}}}|\n    {{#if:{{#invoke:bahasa|getLangName|{{{1}}}|nocap={{{nocap|}}}}}|\n      [[{{lcfirst:{{#invoke:bahasa|getLangName|{{{1}}}|nocap={{{nocap|}}}}}}}]]\n      |{{#invoke:utilitas|errorcat|bahasa}}\n    }}\n    |{{#invoke:utilitas|errorcat|templat}}\n  }}</span>\n[[Kategori:Tembung {{lcfirst:{{#invoke:bahasa|getLangName|{{{1}}}|nocap={{{nocap|}}}}}}}]]</includeonly>";
    if (!std.mem.startsWith(u8, input, included)) return null;
    const tail = input[included.len..];
    const opening = "<noinclude>";
    const closing = "</noinclude>";
    if (!std.mem.startsWith(u8, tail, opening) or !std.mem.endsWith(u8, tail, closing) or tail.len < opening.len + closing.len) return null;
    if (std.mem.indexOfAny(u8, tail[opening.len .. tail.len - closing.len], "<>") != null) return null;
    const category_prefix = "Kategori:Tembung ";
    if (ns.ofTitle(category_prefix).id != 14) return null;
    return category_prefix;
}


// A finite source contract for the selected wrapper, formatter and name table.
// Hashes identify actual decoded NS10 bodies, not an edition or language alias.
fn categoryRoleHash(source: []const u8, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected);
}
pub fn categoryH1ProofAlloc(a: std.mem.Allocator, wrapper: []const u8, formatter: []const u8, names: []const u8, ns: *const namespaces.Registry, registry: *const languages.Registry, code: []const u8) !?languages.SourceLanguageBanner {
    if (!categoryRoleHash(wrapper, "81378725d19d6ef9825d615c24cf3b9ede71f20be1de3ff45fd8765620c374a2") or
        !categoryRoleHash(formatter, "b3f929541a6e16f654ce30f05ce8edfd6caa72597b41d6bb4a57366b4c59748c") or
        !categoryRoleHash(names, "5580cf3a6bdef83cb2e3be22fb14e8fcb37e200f398b2e58c15cf8957a836757")) return null;
    const call = "{{-lingua-|";
    const end = std.mem.indexOf(u8, wrapper, "}}") orelse return null;
    if (!std.mem.startsWith(u8, wrapper, call) or end < call.len or !std.mem.eql(u8, wrapper[call.len..end], code) or
        !registry.codes.contains(code) or ns.ofTitle("Categoría:proof").id != 14) return null;
    var selected: ?[]const u8 = null;
    var rows = std.mem.splitScalar(u8, names, '\n');
    while (rows.next()) |row| {
        if (!std.mem.startsWith(u8, row, "|")) continue;
        const eq = std.mem.indexOfScalar(u8, row, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, row[1..eq], " \t"), code)) continue;
        if (selected != null) return null;
        selected = std.mem.trim(u8, row[eq + 1 ..], " \t\r");
    }
    const name = selected orelse return null;
    if (!plain(name) or name[0] < 'a' or name[0] > 'z' or !registry.sourceBannerNameMatches(code, name)) return null;
    const label = try a.dupe(u8, name);
    errdefer a.free(label);
    label[0] = std.ascii.toUpper(label[0]);
    if (!registry.sourceBannerNameMatches(code, label)) { a.free(label); return null; }
    const trusted = registry.resolveStrong(label) orelse registry.resolveSourceTrusted(label) orelse { a.free(label); return null; };
    if (!std.mem.eql(u8, trusted.code, code)) { a.free(label); return null; }
    const close = std.mem.indexOfScalar(u8, formatter, '>') orelse { a.free(label); return null; };
    const heading = try std.fmt.allocPrint(a, "{s}[[Categoría:{s}]]<span class=\"bluetogreen\">[[:Categoría:{s}|{s}]]</span></h1>", .{ formatter[0 .. close + 1], label, label, label });
    return .{ .heading = heading, .level = 1, .target = label, .label = label };
}


// Complete selected NS10 declaration, including inclusion boundaries and both
// uses of positional code 1. The emitted embedded name and ucfirst label still
// need independent registry agreement; this never registers an interwiki alias.
pub fn linkedCanonicalHeading(source: []const u8, ns: *const namespaces.Registry) ?languages.SourceLinkedHeading {
    if (!categoryRoleHash(source, "51c4a30bd4e74456182549ed438ccd93ecf558429005271700cf619d1c857423") or ns.byName("w") != null) return null;
    for (ns.interwiki_rows) |row| if (std.mem.eql(u8, row.prefix, "w") and !row.is_current_wiki and !row.is_interlanguage)
        return .{ .prefix = ":w:", .suffix = " nyelv" };
    return null;
}

// Complete retained Sablon:CMN p454544/r2966794 calls getCanonicalName
// with literal cmn for both target and ucfirst label, then appends this tail.
// The name itself must still come from the independent canonical-name source.
pub fn fixedCanonicalLinkedTail(source: []const u8, ns: *const namespaces.Registry) ?languages.SourceFixedLinkedTail {
    if (!categoryRoleHash(source, "6952bb910d6240ff45d5c37979cd2c1083ec2200252ea9fd53bded3b7733ecb3") or ns.byName("w") != null) return null;
    for (ns.interwiki_rows) |row| if (std.mem.eql(u8, row.prefix, "w") and !row.is_current_wiki and !row.is_interlanguage)
        return .{ .link = .{ .prefix = ":w:", .suffix = " nyelv" }, .code = "cmn", .tail = " kínai" };
    return null;
}

// Complete indexed přeserbšćenje p3728/r11475: the rěč parameter is used
// unchanged in the sole parenthesized language link and language category.
// This proves the formatter role, not an owner for any particular argument.
pub fn parentheticalLinkedHeading(source: []const u8) bool {
    return categoryRoleHash(source, "ac7a09bf14b0b39ba21b374a730767f710092a6d0ad6acdd772e019a74c1d041");
}

// These complete sources prove a declaration role, not a language-name alias.
// head_t reads parent argument 1 through the scalar parameter contract, resolves
// that exact code through languages.getByCode, and passes the object unchanged
// to full_headword. The independent Dil source only delimits a named container.
pub const headword_role_modules = [_][]const u8{ "headword/templates", "parameters", "languages", "headword" };
pub const headword_role_hashes = [_][]const u8{
    "97be6e6d09ad383f691b894820b09c287a57c89503d69f2263d5525124fb8756",
    "7c9d66994a4164e9acedcae87bbb4e26fe3a5a3ef843a07afddf704dea3243fb",
    "2e71773c298ad3063d01132adca7a06f9604e0fd917d729493412b0ecc896666",
    "b582b68050e4bc752af3d82e0e5343c37c4fed35798c45d8e56b370c46f24907",
};

pub fn provesHeadwordLanguageRole(head: []const u8, container: []const u8, modules: [headword_role_modules.len][]const u8) bool {
    if (!categoryRoleHash(head, "ad25437854da57afc0508b995567b3bd907e9b6ecbb5427a3f12ca082c65decc") or
        !categoryRoleHash(container, "c429e566da8ff0682f35f11d9b900613e474863d777190d256fa73ce9c0473fd")) return false;
    for (modules, headword_role_hashes) |source, digest| if (!categoryRoleHash(source, digest)) return false;
    return true;
}

// The complete pinned decoration has no lexical declaration. Only c occurs in
// its image filename; omitted uc remains a literal parameter in the qualified
// source. Project these exact inclusion boundaries once for later byte pairing.
pub fn headwordStaticPrefixAlloc(a: std.mem.Allocator, source: []const u8) !?[]u8 {
    if (!categoryRoleHash(source, "6ed00656a2ef4792f1b7fa078717ab49980cd6ae9653b1cc36b947694ae93c58")) return null;
    const included = try std.mem.replaceOwned(u8, a, source, "<includeonly>", ""); defer a.free(included);
    const closed = try std.mem.replaceOwned(u8, a, included, "</includeonly>", ""); defer a.free(closed);
    const documented = try std.mem.replaceOwned(u8, a, closed, "<noinclude>''Alban əlifbası''</noinclude>", ""); defer a.free(documented);
    const end = std.mem.indexOf(u8, documented, "<noinclude>") orelse return null;
    return try a.dupe(u8, documented[0..end]);
}

/// A static hyphen-code template can declare its exact local language label.
/// The caller supplies an authenticated NS10 -code- wikitext row. The hidden
/// category and sole decorated H2 must agree; the icon supplies no owner proof.
/// This finite grammar does not certify dynamic or general HTML templates.
pub fn decoratedCategoryLabel(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?[]const u8 {
    if (source.len > 4096 or !registry.codes.contains(code)) return null;
    const input = std.mem.trim(u8, source, "\r\n");
    const prefix = "<includeonly>";
    if (!std.mem.startsWith(u8, input, prefix)) return null;
    const end_category = std.mem.indexOf(u8, input, "</includeonly>") orelse return null;
    const category = input[prefix.len..end_category];
    if (!hiddenCategory(category, ns, behavior)) return null;
    const target = std.mem.trim(u8, category[2 .. category.len - 2], " ");
    if (std.mem.indexOfScalar(u8, target, '|') != null) return null;
    const category_label = ns.ofTitle(target).text;
    if (!plain(category_label)) return null;
    const control_start = end_category + "</includeonly>".len;
    const control = "__NOEDITSECTION__";
    if (!std.mem.startsWith(u8, input[control_start..], control)) return null;
    const control_end = (controlAt(behavior, input, control_start) catch return null) orelse return null;
    if (control_end != control_start + control.len or control_end >= input.len or input[control_end] != '\n') return null;
    const heading_start = control_end + 1;
    const heading_end = std.mem.indexOfScalarPos(u8, input, heading_start, '\n') orelse return null;
    const heading = syntax.controlHeading(input[heading_start..heading_end], null) orelse return null;
    if (heading.level != 2 or containsControl(behavior, heading.title)) return null;
    const div = syntax.tagAt(heading.title, 0) orelse return null;
    if (!div.is("div") or div.closing or div.self_closing or
        !std.mem.eql(u8, std.mem.trim(u8, div.attrs, " \t"), "id=\"toc\" class=\"toccolours\"")) return null;
    const pair = syntax.matchingTag(heading.title, div) orelse return null;
    if (pair.end != heading.title.len) return null;
    const outer = unwrapNeutral(heading.title[div.end..pair.inner_end], "big") orelse return null;
    const inner = unwrapNeutral(outer, "big") orelse return null;
    if (!std.mem.startsWith(u8, inner, "[[")) return null;
    const icon_end = std.mem.indexOf(u8, inner, "]]") orelse return null;
    const icon = inner[2..icon_end];
    var options = std.mem.splitScalar(u8, icon, '|');
    const file = options.next() orelse return null;
    if (std.mem.indexOfAny(u8, file, "[]{}<>&#\r\n") != null) return null;
    const file_title = ns.ofTitle(file);
    if (file_title.id != 6 or std.mem.trim(u8, file_title.text, " \t").len == 0) return null;
    if (!std.mem.eql(u8, options.next() orelse return null, "border")) return null;
    const size = options.next() orelse return null;
    if (options.next() != null or size.len < 3 or !std.mem.endsWith(u8, size, "px")) return null;
    const digits = size[0 .. size.len - 2];
    for (digits) |digit| if (digit < '0' or digit > '9') return null;
    const width = std.fmt.parseInt(u16, digits, 10) catch return null;
    if (width == 0 or width > 4096) return null;
    const rest = inner[icon_end + 2..];
    if (rest.len == 0 or rest[0] != ' ') return null;
    const label = std.mem.trim(u8, rest, " ");
    if (!plain(label) or !std.mem.eql(u8, label, category_label)) return null;
    const tail = std.mem.trim(u8, input[heading_end + 1..], " \t\r\n");
    if (!std.mem.startsWith(u8, tail, "<noinclude>") or !std.mem.endsWith(u8, tail, "</noinclude>")) return null;
    // Even excluded documentation is finite: one actual hidden category, no
    // onlyinclude, parameters, nested tags, or additional emitted content.
    if (!hiddenCategory(tail["<noinclude>".len .. tail.len - "</noinclude>".len], ns, behavior)) return null;
    return label;
}


fn parseCategoryLinkedHeading(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    return categoryLinkedDeclaration(source, ns, behavior, registry, code, false);
}


pub fn categoryLinkedBoundary(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8) ?languages.SourceLanguageBanner {
    return categoryLinkedDeclaration(source, ns, behavior, registry, code, true);
}


fn categoryLinkedDeclaration(source: []const u8, ns: *const namespaces.Registry, behavior: ?*const Behavior, registry: *const languages.Registry, code: []const u8, boundary_only: bool) ?languages.SourceLanguageBanner {
    if (source.len > 4096 or !registry.codes.contains(code)) return null;
    const control = "__NOEDITSECTION__";
    if (!std.mem.startsWith(u8, source, control ++ "\n")) return null;
    const control_end = (controlAt(behavior, source, 0) catch return null) orelse return null;
    if (control_end != control.len) return null;
    const input = source[control.len + 1 ..];
    const suffix = "<includeonly>\n{{#ifeq:{{NAMESPACE}}||";
    const cut = std.mem.indexOf(u8, input, suffix) orelse return null;
    const line = input[0..cut];
    if (!std.mem.startsWith(u8, line, "== ''[[") or !std.mem.endsWith(u8, line, "]]'' ==")) return null;
    const label = line[7 .. line.len - 7];
    if (!plain(label) or label.len > 256 or !std.unicode.utf8ValidateSlice(label) or
        !std.mem.eql(u8, label, std.mem.trim(u8, label, " ")) or std.mem.indexOfAny(u8, label, ":#") != null or
        std.mem.indexOf(u8, label, "__") != null or containsControl(behavior, label) or
        (!boundary_only and !registry.sourceBannerCategoryNameCompatible(code, label))) return null;
    const tail = input[cut + suffix.len ..];
    const close = "|}}</includeonly>";
    if (!std.mem.endsWith(u8, tail, close)) return null;
    const category = tail[0 .. tail.len - close.len];
    if (!hiddenCategory(category, ns, behavior) or std.mem.indexOfScalar(u8, category, '|') != null or
        !std.mem.eql(u8, category, std.mem.trim(u8, category, " \t\r\n"))) return null;
    if (!std.mem.eql(u8, ns.ofTitle(category[2 .. category.len - 2]).text, label)) return null;
    const heading = syntax.controlHeading(line, null) orelse return null;
    if (heading.level != 2) return null;
    return .{ .heading = heading.title, .level = 2, .target = label, .label = label, .authority = .category_declaration };
}
