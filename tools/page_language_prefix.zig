const std = @import("std");
const syntax = @import("encoder").wikitext_syntax;
const A = std.mem.Allocator;
const invalid = error.InvalidPageLanguagePrefix;
pub const Observation = struct { outer_languages: []const []const u8, root_language: []const u8 };
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
    const at = std.mem.indexOf(u8, text, "RLCONF=") orelse return false;
    if (at != 0) {
        if (at != 952) return invalid;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text[0..at], &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), "296e5797ae51141a36d124508c23b7e0aeb2cb5be620e060fc6eb5aceb39cc89")) return invalid;
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
    if (article != .integer or revision != .integer or ns != .integer or ns.integer != 0 or
        article.integer <= 0 or revision.integer <= 0 or @as(u64, @intCast(article.integer)) != page_id or @as(u64, @intCast(revision.integer)) != revision_id) return invalid;
    return true;
}
pub fn parseAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64) !Observation {
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
                            if (try configuration(a, bytes[tag.end..begin], page_id, revision_id)) {
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
                if (index + 1 == depth) return .{ .outer_languages = langs, .root_language = try a.dupe(u8, value) };
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
