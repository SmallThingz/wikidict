const std = @import("std");
const syntax = @import("encoder").wikitext_syntax;
const A = std.mem.Allocator;
const invalid = error.InvalidPageLanguagePrefix;
pub const Observation = struct { outer_languages: []const []const u8, body_skin_responsive: ?bool = null, root_language: []const u8 };
const Attributes = struct { lang: ?[]const u8 = null, xml_lang: ?[]const u8 = null, classes: []const u8 = "" };
fn space(c: u8) bool { return std.mem.indexOfScalar(u8, " \t\r\n\x0c", c) != null; }
fn same(a: []const u8, b: []const u8) bool { return std.ascii.eqlIgnoreCase(a, b); }
fn attributes(tag: syntax.Tag) !Attributes {
    var result: Attributes = .{};
    var seen_class = false;
    var at: usize = 0;
    while (at < tag.attrs.len) {
        while (at < tag.attrs.len and space(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len) break;
        const start = at;
        while (at < tag.attrs.len and (std.ascii.isAlphanumeric(tag.attrs[at]) or std.mem.indexOfScalar(u8, "-_:.", tag.attrs[at]) != null)) : (at += 1) {}
        if (at == start) return invalid;
        const name = tag.attrs[start..at];
        while (at < tag.attrs.len and space(tag.attrs[at])) : (at += 1) {}
        var value: []const u8 = "";
        if (at < tag.attrs.len and tag.attrs[at] == '=') {
            at += 1;
            while (at < tag.attrs.len and space(tag.attrs[at])) : (at += 1) {}
            if (at == tag.attrs.len) return invalid;
            const quote = tag.attrs[at];
            if (quote == '\'' or quote == '"') {
                at += 1; const begin = at;
                while (at < tag.attrs.len and tag.attrs[at] != quote) : (at += 1) {}
                if (at == tag.attrs.len) return invalid;
                value = tag.attrs[begin..at]; at += 1;
                if (at < tag.attrs.len and !space(tag.attrs[at])) return invalid;
            } else {
                const begin = at;
                while (at < tag.attrs.len and !space(tag.attrs[at])) : (at += 1) {}
                value = tag.attrs[begin..at];
                if (std.mem.indexOfAny(u8, value, "\"'`=<>") != null) return invalid;
            }
        }
        if (same(name, "lang")) { if (result.lang != null) return invalid; result.lang = value; }
        if (same(name, "xml:lang")) { if (result.xml_lang != null) return invalid; result.xml_lang = value; }
        if (same(name, "class")) { if (seen_class) return invalid; seen_class = true; result.classes = value; }
    }
    return result;
}
fn hasClass(raw: []const u8, wanted: []const u8) bool {
    var values = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c");
    while (values.next()) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}
fn language(raw: []const u8) bool {
    var segment = false;
    for (raw) |c| {
        if (c == '-') { if (!segment) return false; segment = false; }
        else if (std.ascii.isAlphabetic(c)) segment = true else return false;
    }
    return segment;
}
fn voidTag(tag: syntax.Tag) bool {
    for ([_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |name| if (tag.is(name)) return true;
    return false;
}
fn jsonEnd(text: []const u8, start: usize) !usize {
    if (start == text.len or text[start] != '{') return invalid;
    var depth: usize = 0; var quoted = false; var escape = false;
    for (text[start..], start..) |c, at| {
        if (quoted) {
            if (escape) { escape = false; continue; }
            if (c == '\\') escape = true else if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') quoted = true else if (c == '{' or c == '[') {
            depth += 1; if (depth > 32) return invalid;
        } else if (c == '}' or c == ']') {
            if (depth == 0) return invalid;
            depth -= 1; if (depth == 0) return at + 1;
        }
    }
    return invalid;
}
// Only a direct assignment or the exact retained generated head prelude is
// admitted. The prelude sets client classes and closes its IIFE before the
// assignment. No general JavaScript lexer or execution inference is used.
fn configuration(a: A, text: []const u8, page_id: u64, revision_id: u64) !bool {
    return configurationForPage(a, text, page_id, revision_id, null);
}
const SelectedPage = struct { namespace_id: i32, title: []const u8 };
fn configurationForPage(a: A, text: []const u8, page_id: u64, revision_id: u64, current_title: ?[]const u8) !bool {
    return configurationForSelectedPage(a, text, page_id, revision_id, current_title, null, "");
}
fn configurationForSelectedPage(a: A, text: []const u8, page_id: u64, revision_id: u64,
    current_title: ?[]const u8, selected: ?SelectedPage, html_classes: []const u8) !bool
{
    const at = std.mem.indexOf(u8, text, "RLCONF=") orelse return false;
    if (at != 0) {
        if (at != 952 and at != 956 and !(selected != null and at == 960)) return invalid;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text[0..at], &digest, .{});
        const hash = std.fmt.bytesToHex(digest, .lower);
        // Complete observed preludes differ only in the literal wiki cookie
        // name (ru/wo/el/sr) and TOC availability class. Each closes the IIFE
        // before RLCONF; unknown programs remain rejected.
        if (!std.mem.eql(u8, &hash, "4596a0a448783bdf5cd823d3b017520464502eba17da6e0277049df0c171bf39") and
            !std.mem.eql(u8, &hash, "296e5797ae51141a36d124508c23b7e0aeb2cb5be620e060fc6eb5aceb39cc89") and
            !std.mem.eql(u8, &hash, "ff0406678d57587b7409bfba7f818a44a9ec8dd418eb27da4b32823b3e19ed0d") and
            !std.mem.eql(u8, &hash, "50617cc2b928696b5f738520ed06f6814b186a4a6ddcadd9743d34abd74a8d5d") and
            !std.mem.eql(u8, &hash, "1e6d52df99a5b900fc18cec459f5e77aee670a50858da0923389f6c308ac7c49") and
            !std.mem.eql(u8, &hash, "1a3d0fcd4371047de9a485248822f83026e5d7361fb2e9ec9b547c0093bf1bb0") and
            !std.mem.eql(u8, &hash, "f8b4a82d07b0c2847a010739493119441c8ce97437e68ba0dac16f921ee322a8") and
            !std.mem.eql(u8, &hash, "932b9910c9e926e55516112a7ce9644909c06c20035d794b10947a5eec4e3f94") and
            !std.mem.eql(u8, &hash, "e925dc8ae7861a33fd0b23132dbc9eeae57bba470d42e81320a4b43ed0a6a5e1") and
            !(selected != null and std.mem.eql(u8, &hash, "65ec9c98e6764dbb12bc436514f1033a9cb2eb780783cd043398b237e6dc8d6b"))) return invalid;
        if (selected != null) {
            // Bind the observed static root to the complete retained prelude.
            // This does not evaluate cookies or issue a JavaScript outcome.
            const begin = "(function(){var className=\"";
            if (!std.mem.startsWith(u8, text, begin) or !std.mem.startsWith(u8, html_classes, "client-nojs ")) return invalid;
            const end_class = std.mem.indexOfPos(u8, text, begin.len, "\";var cookie=") orelse return invalid;
            const static_classes = try std.mem.concat(a, u8, &.{ "client-js ", html_classes["client-nojs ".len..] });
            defer a.free(static_classes);
            if (!std.mem.eql(u8, static_classes, text[begin.len..end_class])) return invalid;
        }
    }
    const start = at + "RLCONF=".len;
    const end = try jsonEnd(text, start);
    if (end == text.len or text[end] != ';' or std.mem.indexOfPos(u8, text, end + 1, "RLCONF") != null) return invalid;
    const parsed = std.json.parseFromSlice(std.json.Value, a, text[start..end], .{}) catch |err| switch (err) { error.OutOfMemory => return err, else => return invalid };
    defer parsed.deinit();
    if (parsed.value != .object) return invalid;
    const article = parsed.value.object.get("wgArticleId") orelse return invalid;
    const revision = parsed.value.object.get("wgRevisionId") orelse return invalid;
    const ns = parsed.value.object.get("wgNamespaceNumber") orelse return invalid;
    if (article != .integer or revision != .integer or ns != .integer or ns.integer != (if (selected) |value| value.namespace_id else @as(i32, 0)) or
        article.integer <= 0 or revision.integer <= 0 or @as(u64, @intCast(article.integer)) != page_id or @as(u64, @intCast(revision.integer)) != revision_id) return invalid;
    if (selected) |value| {
        const page_name = parsed.value.object.get("wgPageName") orelse return invalid;
        const action = parsed.value.object.get("wgAction") orelse return invalid;
        const article_view = parsed.value.object.get("wgIsArticle") orelse return invalid;
        const expected_name = try a.dupe(u8, value.title); defer a.free(expected_name);
        std.mem.replaceScalar(u8, expected_name, ' ', '_');
        if (page_name != .string or !std.mem.eql(u8, page_name.string, expected_name) or
            action != .string or !std.mem.eql(u8, action.string, "view") or article_view != .bool or !article_view.bool) return invalid;
    }
    if (current_title) |title| {
        const current = parsed.value.object.get("wgCurRevisionId") orelse return invalid;
        const observed_title = parsed.value.object.get("wgTitle") orelse return invalid;
        if (current != .integer or current.integer <= 0 or @as(u64, @intCast(current.integer)) != revision_id or
            observed_title != .string or !std.mem.eql(u8, observed_title.string, title)) return invalid;
    }
    return true;
}
pub fn parseAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64) !Observation {
    return parseForPage(a, bytes, page_id, revision_id, null);
}
// A current canonical observation must still name the exact selected revision.
pub fn parseCurrentAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64, title: []const u8) !Observation {
    return parseForPage(a, bytes, page_id, revision_id, title);
}
// Explicit full-GET selection binds the exact oldid and namespace; the older
// language APIs keep their main-namespace contract unchanged.
pub fn parseSelectedOldidAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, title: []const u8) !Observation
{
    return parseForSelectedPage(a, bytes, page_id, revision_id, null, .{ .namespace_id = namespace_id, .title = title });
}
fn parseForPage(a: A, bytes: []const u8, page_id: u64, revision_id: u64, current_title: ?[]const u8) !Observation {
    return parseForSelectedPage(a, bytes, page_id, revision_id, current_title, null);
}
fn parseForSelectedPage(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    current_title: ?[]const u8, selected: ?SelectedPage) !Observation
{
    if (bytes.len == 0 or bytes.len > 512 * 1024 or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return invalid;
    const Node = struct { tag: syntax.Tag, attrs: Attributes };
    var stack: [128]Node = undefined; var depth: usize = 0;
    var html_seen = false; var body_seen = false; var head_seen = false; var config_seen = false;
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes[at] != '<') { at += 1; continue; }
        if (std.mem.startsWith(u8, bytes[at..], "<!--")) { at = (std.mem.indexOfPos(u8, bytes, at + 4, "-->") orelse return invalid) + 3; continue; }
        if (at == 0 and bytes.len >= 15 and same(bytes[0..15], "<!DOCTYPE html>")) { at = 15; continue; }
        const tag = syntax.tagAt(bytes, at) orelse return invalid;
        const attrs = try attributes(tag);
        if (tag.closing) {
            if (tag.attrs.len != 0 or depth == 0 or !same(stack[depth - 1].tag.name, tag.name)) return invalid;
            depth -= 1; at = tag.end; continue;
        }
        if (tag.is("html")) { if (html_seen or depth != 0) return invalid; html_seen = true; }
        if (tag.is("head")) { if (head_seen or depth != 1 or !stack[0].tag.is("html")) return invalid; head_seen = true; }
        if (tag.is("body")) { if (body_seen or !head_seen or depth != 1 or !stack[0].tag.is("html")) return invalid; body_seen = true; }
        if (tag.is("noscript") or tag.is("template")) return invalid;
        if (tag.is("script") or tag.is("style") or tag.is("title")) {
            if (tag.self_closing) return invalid;
            var search = tag.end;
            while (true) {
                const begin = std.mem.indexOfScalarPos(u8, bytes, search, '<') orelse return invalid;
                if (syntax.tagAt(bytes, begin)) |close| {
                    if (close.closing and same(close.name, tag.name) and close.attrs.len == 0) {
                        if (tag.is("script") and depth == 2 and stack[1].tag.is("head")) {
                            if (try configurationForSelectedPage(a, bytes[tag.end..begin], page_id, revision_id, current_title, selected, stack[0].attrs.classes)) {
                                // Only the observed direct, attribute-free head
                                // script can supply the global configuration.
                                if (config_seen or tag.attrs.len != 0) return invalid;
                                config_seen = true;
                            }
                        }
                        at = close.end; break;
                    }
                }
                search = begin + 1;
            }
            continue;
        }
        if (voidTag(tag)) { at = tag.end; continue; }
        if (tag.self_closing or depth == stack.len) return invalid;
        stack[depth] = .{ .tag = tag, .attrs = attrs }; depth += 1;
        if (tag.is("div") and hasClass(attrs.classes, "mw-parser-output")) {
            if (tag.end != bytes.len or !config_seen or !html_seen or !body_seen or depth < 3 or !stack[0].tag.is("html") or !stack[1].tag.is("body")) return invalid;
            const langs = try a.alloc([]const u8, depth - 1);
            var owned: usize = 0;
            errdefer { for (langs[0..owned]) |value| a.free(value); a.free(langs); }
            var effective: ?[]const u8 = null;
            for (stack[0..depth], 0..) |node, index| {
                if (index > 1 and !node.tag.is("div") and !node.tag.is("main") and !node.tag.is("section") and !node.tag.is("article")) return invalid;
                if (node.attrs.xml_lang) |xml| {
                    const lang = node.attrs.lang orelse return invalid;
                    if (!same(lang, xml)) return invalid;
                }
                if (node.attrs.lang) |lang| effective = lang;
                const value = effective orelse return invalid;
                if (!language(value)) return invalid;
                if (index + 1 == depth) return .{ .outer_languages = langs, .root_language = try a.dupe(u8, value),
                    .body_skin_responsive = if (std.mem.indexOfScalar(u8, stack[1].attrs.classes, '&') != null) null
                        else hasClass(stack[1].attrs.classes, "skin--responsive") };
                langs[index] = try a.dupe(u8, value);
                owned += 1;
            }
            return invalid;
        }
        at = tag.end;
    }
    return invalid;
}

test "page prefix proves complete outer language chain and direct revision data without reading content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "<!DOCTYPE html><html lang=ru><head><script>RLCONF={\"wgArticleId\":3726,\"wgRevisionId\":14376095,\"wgNamespaceNumber\":0};</script></head><body><main><div class='mw-parser-output' lang=ru>";
    const result = try parseAlloc(a, prefix, 3726, 14376095);
    try std.testing.expectEqualStrings("ru", result.root_language);
    try std.testing.expectEqual(@as(usize, 3), result.outer_languages.len);
    for (result.outer_languages) |value| try std.testing.expectEqualStrings("ru", value);
    try std.testing.expectError(invalid, parseAlloc(a, prefix ++ "x", 3726, 14376095));
    try std.testing.expectError(invalid, parseAlloc(a, prefix, 3726, 14376094));
    for ([_][2][]const u8{
        .{ "<html lang=ru>", "<html>" }, .{ "<html lang=ru>", "<html lang=''>" },
        .{ "<main>", "<main lang=''>" }, .{ "<main>", "<main lang=ru xml:lang=cu>" },
        .{ "<main>", "<main lang=ru lang=cu>" }, .{ "<main>", "<table>" },
        .{ "RLCONF=", "IGNORED=" }, .{ "</head>", "</div>" },
        .{ "<script>", "<script src=x>" }, .{ "<script>", "<script type='text/plain'>" },
        .{ "<main>", "<main lang=ru--Latn>" },
    }) |pair| {
        const changed = try std.mem.replaceOwned(u8, a, prefix, pair[0], pair[1]);
        try std.testing.expectError(invalid, parseAlloc(a, changed, 3726, 14376095));
    }
    const overridden = try std.mem.replaceOwned(u8, a, prefix, "<main>", "<main lang=cu>");
    const other = try parseAlloc(a, overridden, 3726, 14376095);
    try std.testing.expectEqualStrings("cu", other.outer_languages[2]);
    try std.testing.expectEqualStrings("ru", other.root_language);
    try std.testing.expectError(invalid, configuration(a, "var x=';RLCONF={\"wgArticleId\":3726,\"wgRevisionId\":14376095,\"wgNamespaceNumber\":0};';", 3726, 14376095));
    try std.testing.expectError(invalid, configuration(a, "/*;RLCONF={\"wgArticleId\":3726,\"wgRevisionId\":14376095,\"wgNamespaceNumber\":0};*/", 3726, 14376095));
}


test "page prefix configuration requires direct global data outside unexecuted blocks" {
    const a = std.testing.allocator;
    const data = "RLCONF={\"wgArticleId\":3726,\"wgRevisionId\":14376095,\"wgNamespaceNumber\":0};";
    try std.testing.expect(try configuration(a, data, 3726, 14376095));
    for ([_][]const u8{
        "function unused(){;" ++ data ++ "}",
        "if(false){;" ++ data ++ "}",
        "(()=>{;" ++ data ++ "});",
        "{;" ++ data ++ "}",
        "var x=1/2;function f(){var y=1/2;" ++ data ++ "var z=1/2;}var w=1/2;",
    }) |source| try std.testing.expectError(invalid, configuration(a, source, 3726, 14376095));
}


test "page prefix actual WO prelude retains complete chain and rejects changed script authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const bytes = @embedFile("testdata/wo-page-language242/response.prefix.html");
    const observed = try parseAlloc(a, bytes, 3618, 26533);
    try std.testing.expectEqualStrings("wo", observed.root_language);
    try std.testing.expect(observed.outer_languages.len > 2);
    for (observed.outer_languages) |lang| try std.testing.expectEqualStrings("wo", lang);
    try std.testing.expectError(invalid, parseAlloc(a, bytes, 3618, 26532));
    const no_toc = @embedFile("testdata/wo-page-language242/response-no-toc.prefix.html");
    const no_toc_observed = try parseAlloc(a, no_toc, 6511, 26318);
    try std.testing.expectEqualStrings("wo", no_toc_observed.root_language);
    try std.testing.expect(no_toc_observed.outer_languages.len > 2);
    for (no_toc_observed.outer_languages) |lang| try std.testing.expectEqualStrings("wo", lang);
    try std.testing.expectError(invalid, parseAlloc(a, no_toc, 6511, 26317));
    const changed_toc = try std.mem.replaceOwned(u8, a, no_toc, "vector-toc-not-available", "vector-toc-xxx-available");
    try std.testing.expectError(invalid, parseAlloc(a, changed_toc, 6511, 26318));
    const changed = try std.mem.replaceOwned(u8, a, bytes, "wowiktionarymwclientpreferences", "xxwiktionarymwclientpreferences");
    try std.testing.expectError(invalid, parseAlloc(a, changed, 3618, 26533));
    const hidden = try std.mem.replaceOwned(u8, a, bytes, "RLCONF=", "if(false)RLCONF=");
    try std.testing.expectError(invalid, parseAlloc(a, hidden, 3618, 26533));
}


test "current canonical prefix requires exact title page and both revision identities" {
    const a = std.testing.allocator;
    const bytes = "<!DOCTYPE html><html lang=ru><head><script>RLCONF={\"wgArticleId\":3726,\"wgRevisionId\":14376095,\"wgCurRevisionId\":14376095,\"wgTitle\":\"controlled title\",\"wgNamespaceNumber\":0};</script></head><body><main><div class='mw-parser-output' lang=ru>";
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
    const observed = try parseCurrentAlloc(t, bytes, 3726, 14376095, "controlled title");
    try std.testing.expectEqualStrings("ru", observed.root_language);
    try std.testing.expectEqual(@as(usize, 3), observed.outer_languages.len);
    try std.testing.expectError(invalid, parseCurrentAlloc(t, bytes, 3727, 14376095, "controlled title"));
    try std.testing.expectError(invalid, parseCurrentAlloc(t, bytes, 3726, 14376096, "controlled title"));
    try std.testing.expectError(invalid, parseCurrentAlloc(t, bytes, 3726, 14376095, "other title"));
    for ([_][2][]const u8{
        .{ "\"wgCurRevisionId\":14376095", "\"wgCurRevisionId\":14376096" },
        .{ "\"wgRevisionId\":14376095", "\"wgRevisionId\":14376094" },
        .{ "\"wgCurRevisionId\":14376095", "\"wgCurRevisionId\":\"14376095\"" },
        .{ "\"wgCurRevisionId\":14376095", "\"otherRevision\":14376095" },
        .{ "\"wgTitle\":\"controlled title\"", "\"otherTitle\":\"controlled title\"" },
        .{ "\"wgNamespaceNumber\":0", "\"wgNamespaceNumber\":1" },
        .{ "RLCONF=", "unreviewed();RLCONF=" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, t, bytes, change[0], change[1]);
        try std.testing.expectError(invalid, parseCurrentAlloc(t, altered, 3726, 14376095, "controlled title"));
    }
    // Oldid evidence never required equality with the current revision or title.
    const older = try std.mem.replaceOwned(u8, t, bytes, "\"wgCurRevisionId\":14376095", "\"wgCurRevisionId\":14376096");
    _ = try parseAlloc(t, older, 3726, 14376095);
}







test "page prefix exact observed EL program remains data-bound and rejects changed cookie or script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    // Actual current EL GET script; parser control does not grant whole-page adoption.
    const script = @embedFile("testdata/el-prefix-feminismos/feminismos-config.actual.js");
    try std.testing.expect(try configurationForPage(a, script, 47830, 7126690, "φεμινισμός"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 47831, 7126690, "φεμινισμός"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 47830, 7126691, "φεμινισμός"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 47830, 7126690, "Elsewhere"));
    for ([_][2][]const u8{
        .{ "elwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "vector-toc-available", "vector-toc-availablx" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgCurRevisionId\":7126690", "\"wgCurRevisionId\":7126691" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, script, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, script, altered));
        try std.testing.expectError(invalid, configurationForPage(a, altered, 47830, 7126690, "φεμινισμός"));
    }
}


test "retained current SR prefix keeps exact program and current revision identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const page = try std.json.parseFromSliceLeaky(std.json.Value, a,
        @embedFile("testdata/sr-current-missing-head/actual-year-page.json"), .{ .allocate = .alloc_always });
    const html = page.object.get("outer_context").?.object.get("response").?.string;
    const observed = try parseCurrentAlloc(a, html, 30732, 684280, "år");
    try std.testing.expectEqualStrings("sr", observed.root_language);
    try std.testing.expectError(invalid, parseCurrentAlloc(a, html, 30733, 684280, "år"));
    try std.testing.expectError(invalid, parseCurrentAlloc(a, html, 30732, 684281, "år"));
    try std.testing.expectError(invalid, parseCurrentAlloc(a, html, 30732, 684280, "other"));
    for ([_][2][]const u8{
        .{ "srwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "vector-toc-not-available", "vector-toc-not-availablx" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgCurRevisionId\":684280", "\"wgCurRevisionId\":684281" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, html, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, html, altered));
        try std.testing.expectError(invalid, parseCurrentAlloc(a, altered, 30732, 684280, "år"));
    }
}

test "page prefix exact retained MG available TOC program preserves revision and script boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const script = @embedFile("testdata/mg-prefix-ac/mg-config.actual.js");
    const prefix = @embedFile("testdata/mg-prefix-ac/mg-prefix.candidate.html");
    const observed = try parseCurrentAlloc(a, prefix, 3099, 37649537, "-ac");
    try std.testing.expectEqualStrings("mg", observed.root_language);
    try std.testing.expect(try configurationForPage(a, script, 3099, 37649537, "-ac"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 3100, 37649537, "-ac"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 3099, 37649538, "-ac"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 3099, 37649537, "Elsewhere"));
    for ([_][2][]const u8{
        .{ "mgwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "vector-toc-available", "vector-toc-availablx" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgCurRevisionId\":37649537", "\"wgCurRevisionId\":37649538" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, script, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, script, altered));
        try std.testing.expectError(invalid, configurationForPage(a, altered, 3099, 37649537, "-ac"));
    }
}

test "page prefix exact retained FR available TOC program preserves revision and script boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const script = @embedFile("testdata/fr-prefix-symbol/fr-config.actual.js");
    const prefix = @embedFile("testdata/fr-prefix-symbol/fr-prefix.candidate.html");
    const observed = try parseCurrentAlloc(a, prefix, 1517441, 34477915, "♃");
    try std.testing.expectEqualStrings("fr", observed.root_language);
    try std.testing.expect(try configurationForPage(a, script, 1517441, 34477915, "♃"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 1517442, 34477915, "♃"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 1517441, 34477916, "♃"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 1517441, 34477915, "Elsewhere"));
    for ([_][2][]const u8{
        .{ "frwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "vector-toc-available", "vector-toc-availablx" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgCurRevisionId\":34477915", "\"wgCurRevisionId\":34477916" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, script, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, script, altered));
        try std.testing.expectError(invalid, configurationForPage(a, altered, 1517441, 34477915, "♃"));
    }
}

test "page prefix body responsive fact is exact scoped and never guessed from language or lookalike classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const head = "<!DOCTYPE html><html lang=hu><head><script>RLCONF={\"wgArticleId\":1153,\"wgRevisionId\":3369675,\"wgNamespaceNumber\":0};</script></head><body class='";
    const tail = "'><main><div class='mw-parser-output' lang=hu>";
    const cases = [_]struct { classes: []const u8, expected: ?bool }{
        .{ .classes = "skin-vector-2022 skin--responsive", .expected = true },
        .{ .classes = "skin-vector-2022", .expected = false },
        .{ .classes = "skin--responsive-extra", .expected = false },
        .{ .classes = "skin&#45;&#45;responsive", .expected = null },
    };
    for (cases) |case| {
        const parsed = try parseAlloc(a, try std.mem.concat(a, u8, &.{head, case.classes, tail}), 1153, 3369675);
        try std.testing.expectEqual(case.expected, parsed.body_skin_responsive);
        try std.testing.expectEqualStrings("hu", parsed.root_language);
    }
}

test "page prefix exact retained SR available TOC program preserves revision and script boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const script = @embedFile("testdata/sr-prefix-alexander/alexander-config.actual.js");
    try std.testing.expect(try configurationForPage(a, script, 12600, 676512, "Alexander"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 12601, 676512, "Alexander"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 12600, 676513, "Alexander"));
    try std.testing.expectError(invalid, configurationForPage(a, script, 12600, 676512, "Elsewhere"));
    for ([_][2][]const u8{
        .{ "srwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "vector-toc-available", "vector-toc-availablx" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgCurRevisionId\":676512", "\"wgCurRevisionId\":676513" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, script, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, script, altered));
        try std.testing.expectError(invalid, configurationForPage(a, altered, 12600, 676512, "Alexander"));
    }
}
