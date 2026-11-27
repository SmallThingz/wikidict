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
// This binds a selected GET's observed generator only. It does not issue
// stylesheet, skin, ancestry, transport, or evaluated-program authority.
pub const SelectedGetGenerator = enum {
    wmf5,
    wmf6,

    fn text(self: SelectedGetGenerator) []const u8 {
        return switch (self) {
            .wmf5 => "MediaWiki 1.48.0-wmf.5",
            .wmf6 => "MediaWiki 1.48.0-wmf.6",
        };
    }
};
const SelectedPage = struct { namespace_id: i32, title: []const u8, sr_wmf5_prelude: bool = false,
    is_screen_prelude: bool = false,
    selected_get_wiki: ?[]const u8 = null,
    selected_get_generator: SelectedGetGenerator = .wmf5,
    // Only the separately typed normal-text identity path supplies this wiki.
    normal_text_wiki: ?[]const u8 = null,
    exterior: ?struct { wiki: []const u8, tags: *std.ArrayList([]const u8) } = null };
// Both retained EN Vector 2022 and HU legacy GETs have this complete static
// program. Only the literal class suffix and site cookie vary. Matching these
// bytes proves the program boundary, not an evaluated cookie/class outcome.
fn selectedGetPrelude(a: A, text: []const u8, html_classes: []const u8, wiki: []const u8) !void {
    if (text.len == 0 or text.len > 2048 or wiki.len == 0 or wiki.len > 128) return invalid;
    for (wiki) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return invalid;
    const nojs = "client-nojs ";
    if (!std.mem.startsWith(u8, html_classes, nojs) or html_classes.len <= nojs.len or html_classes.len > 1536) return invalid;
    const suffix = html_classes[nojs.len..];
    for (suffix) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != ' ') return invalid;
    const expected = try std.mem.concat(a, u8, &.{
        "(function(){var className=\"client-js ", suffix,
        "\";var cookie=document.cookie.match(/(?:^|; )", wiki,
        "mwclientpreferences=([^;]+)/);if(cookie){cookie[1].split('%2C').forEach(function(pref){className=className.replace(new RegExp('(^| )'+pref.replace(/-clientpref-\\w+$|[^\\w-]+/g,'')+'-clientpref-\\\\w+( |$)'),'$1'+pref+'$2');});}document.documentElement.className=className;}());",
    });
    defer a.free(expected);
    if (!std.mem.eql(u8, text, expected)) return invalid;
}
fn configurationForPage(a: A, text: []const u8, page_id: u64, revision_id: u64, current_title: ?[]const u8) !bool {
    return configurationForSelectedPage(a, text, page_id, revision_id, current_title, null, "");
}
fn configurationForSelectedPage(a: A, text: []const u8, page_id: u64, revision_id: u64,
    current_title: ?[]const u8, selected: ?SelectedPage, html_classes: []const u8) !bool
{
    const at = std.mem.indexOf(u8, text, "RLCONF=") orelse return false;
    const selected_get_wiki = if (selected) |value| value.selected_get_wiki else null;
    const selected_get_program = if (selected_get_wiki) |wiki| program: {
        try selectedGetPrelude(a, text[0..at], html_classes, wiki);
        break :program true;
    } else false;
    const sr_wmf5 = if (selected) |value| value.sr_wmf5_prelude else false;
    const exterior = if (selected) |record| record.exterior else null;
    // For exterior evidence, compare the whole reviewed static program after
    // binding its single site-cookie literal to the selected namespace registry.
    const program_wiki = if (exterior) |record| record.wiki else
        if (selected) |record| record.normal_text_wiki else null;
    const exterior_program = if (program_wiki != null and (exterior != null or at != 0)) program: {
        const wiki = program_wiki.?;
        if (wiki.len == 0 or wiki.len > 128) return invalid;
        for (wiki) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return invalid;
        const cookie = try std.mem.concat(a, u8, &.{ wiki, "mwclientpreferences" });
        defer a.free(cookie);
        if (at == 0 or at > 2048 or std.mem.count(u8, text[0..at], cookie) != 1) return invalid;
        const normalized = try std.mem.replaceOwned(u8, a, text[0..at], cookie, "srwiktionarymwclientpreferences");
        defer a.free(normalized);
        var canonical: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(normalized, &canonical, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(canonical, .lower), "ff0406678d57587b7409bfba7f818a44a9ec8dd418eb27da4b32823b3e19ed0d")) return invalid;
        break :program true;
    } else false;
    if (sr_wmf5 and at == 0) return invalid;
    if (selected != null and selected.?.is_screen_prelude and at != 956) return invalid;
    if (at != 0) {
        if (!selected_get_program and !exterior_program and at != 952 and at != 956 and !(selected != null and at == 960)) return invalid;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text[0..at], &digest, .{});
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (sr_wmf5) {
            // The captured programs differ only in the literal Vector TOC class.
            // Both still need to agree with the static HTML root below.
            const expected = switch (at) {
                952 => "ff0406678d57587b7409bfba7f818a44a9ec8dd418eb27da4b32823b3e19ed0d",
                956 => "1a3d0fcd4371047de9a485248822f83026e5d7361fb2e9ec9b547c0093bf1bb0",
                else => return invalid,
            };
            if (!std.mem.eql(u8, &hash, expected)) return invalid;
        }
        // Complete observed preludes differ only in the literal wiki cookie
        // name (ru/wo/el/sr) and TOC availability class. Each closes the IIFE
        // before RLCONF; unknown programs remain rejected.
        // This exact Icelandic program differs from the reviewed Serbian script
        // only in its site cookie. The ordinary article stylesheet join binds
        // the selected wiki, generator, class list and revision independently.
        const is_screen_program = selected != null and selected.?.is_screen_prelude and
            std.mem.eql(u8, &hash, "2b0ae9eb6125752f1f9cc44637490ceab85da7c39b5fb1d392e3fde2995856f0");
        if (selected != null and selected.?.is_screen_prelude and !is_screen_program) return invalid;
        if (!selected_get_program and !exterior_program and !is_screen_program and !std.mem.eql(u8, &hash, "4596a0a448783bdf5cd823d3b017520464502eba17da6e0277049df0c171bf39") and
            !std.mem.eql(u8, &hash, "296e5797ae51141a36d124508c23b7e0aeb2cb5be620e060fc6eb5aceb39cc89") and
            !std.mem.eql(u8, &hash, "4883bdb1c585b9440aa445aacdea8bdb5df146ca42bde57bd25862fffb71ed0f") and
            !std.mem.eql(u8, &hash, "ff0406678d57587b7409bfba7f818a44a9ec8dd418eb27da4b32823b3e19ed0d") and
            !std.mem.eql(u8, &hash, "50617cc2b928696b5f738520ed06f6814b186a4a6ddcadd9743d34abd74a8d5d") and
            !std.mem.eql(u8, &hash, "1e6d52df99a5b900fc18cec459f5e77aee670a50858da0923389f6c308ac7c49") and
            !std.mem.eql(u8, &hash, "1a3d0fcd4371047de9a485248822f83026e5d7361fb2e9ec9b547c0093bf1bb0") and
            !std.mem.eql(u8, &hash, "f8b4a82d07b0c2847a010739493119441c8ce97437e68ba0dac16f921ee322a8") and
            !std.mem.eql(u8, &hash, "932b9910c9e926e55516112a7ce9644909c06c20035d794b10947a5eec4e3f94") and
            !std.mem.eql(u8, &hash, "e925dc8ae7861a33fd0b23132dbc9eeae57bba470d42e81320a4b43ed0a6a5e1") and
            !(selected != null and std.mem.eql(u8, &hash, "6fd0a7ffa6553aafe70ba992a6f570ffa854338377eed5e58f2e635dfa099fa0")) and
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
    if (exterior != null or selected_get_program) {
        const groups = parsed.value.object.get("wgUserGroups") orelse return invalid;
        const user = parsed.value.object.get("wgUserName") orelse return invalid;
        if (user != .null or groups != .array or groups.array.items.len != 1 or groups.array.items[0] != .string or
            !std.mem.eql(u8, groups.array.items[0].string, "*")) return invalid;
    }
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
    if (selected_get_program) {
        const title = parsed.value.object.get("wgTitle") orelse return invalid;
        if (title != .string or !std.mem.eql(u8, title.string, selected.?.title)) return invalid;
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
// For a namespaced article, wgPageName contains the prefix and wgTitle does not.
pub fn parseNamespacedCurrentAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, full_title: []const u8, local_title: []const u8) !Observation
{
    return parseForSelectedPage(a, bytes, page_id, revision_id, local_title,
        .{ .namespace_id = namespace_id, .title = full_title });
}
// Explicit full-GET selection binds the exact oldid and namespace; the older
// language APIs keep their main-namespace contract unchanged.
pub fn parseSelectedOldidAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, title: []const u8) !Observation
{
    return parseForSelectedPage(a, bytes, page_id, revision_id, null, .{ .namespace_id = namespace_id, .title = title });
}
// Captured main-namespace GET identity: exact selected oldid, anonymous view,
// WMF5 generator, static class/cookie literals and the complete fixed program.
// No evaluated class, cookie, CSS, skin or Book ancestry authority is issued.
// Other entry points and current-versus-oldid contracts remain unchanged.
pub fn parseSelectedGetOldidAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, title: []const u8, wiki: []const u8) !Observation
{
    if (namespace_id != 0) return invalid;
    return parseForSelectedPage(a, bytes, page_id, revision_id, null,
        .{ .namespace_id = namespace_id, .title = title, .selected_get_wiki = wiki });
}

// Explicit generator selection for a separately observed selected-GET
// profile. The existing API above remains WMF5-only; all program, wiki,
// anonymous-view, selected-identity and root checks remain shared.
pub fn parseSelectedGetOldidWithGeneratorAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, title: []const u8, wiki: []const u8, generator: SelectedGetGenerator) !Observation
{
    if (namespace_id != 0) return invalid;
    return parseForSelectedPage(a, bytes, page_id, revision_id, null,
        .{ .namespace_id = namespace_id, .title = title, .selected_get_wiki = wiki,
            .selected_get_generator = generator });
}

// The canonical-current Yiddish table role matches the full anonymous
// Vector program, including the page's own class inventory and Yiddish cookie.
// Its caller still owns URL, body, table occurrence, and CSS correspondence.
pub fn parseYiCurrentTableAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64, title: []const u8) !Observation {
    return parseForSelectedPage(a, bytes, page_id, revision_id, title,
        .{ .namespace_id = 0, .title = title, .selected_get_wiki = "yiwiktionary", .selected_get_generator = .wmf6 });
}

// A new normal-text identity role may bind the exact maintained static
// prelude after substituting only its selected wiki cookie literal. Existing
// selected-oldid/style/exterior entry points retain their earlier contracts.
// This supplies identity/root language only, never ancestor or CSS authority.
pub fn parseNormalTextOldidAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, title: []const u8, wiki: []const u8) !Observation
{
    if (namespace_id != 0) return invalid;
    return parseForSelectedPage(a, bytes, page_id, revision_id, null,
        .{ .namespace_id = namespace_id, .title = title, .normal_text_wiki = wiki });
}

pub fn parseStylesheetOldidAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    title: []const u8, wiki: []const u8, generator: []const u8) !Observation
{
    return parseForSelectedPage(a, bytes, page_id, revision_id, null, .{ .namespace_id = 0, .title = title,
        .is_screen_prelude = std.mem.eql(u8, wiki, "iswiktionary") and std.mem.eql(u8, generator, "MediaWiki 1.48.0-wmf.5") });
}

// The SR WMF5 Book path requires its exact observed static program. Older
// APIs retain their existing prelude choices and direct-assignment behavior.
pub fn parseSrWmf5SelectedOldidAlloc(a: A, bytes: []const u8, page_id: u64, revision_id: u64,
    namespace_id: i32, title: []const u8) !Observation
{
    if (namespace_id != 0) return invalid;
    return parseForSelectedPage(a, bytes, page_id, revision_id, null,
        .{ .namespace_id = namespace_id, .title = title, .sr_wmf5_prelude = true });
}
pub fn revisionExteriorTagsAlloc(a: A, bytes: []const u8, id: u64, revision: u64, title: []const u8, wiki: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer tags.deinit(a);
    const observation = try parseForSelectedPage(a, bytes, id, revision, title, .{ .namespace_id = 0, .title = title,
        .exterior = .{ .wiki = wiki, .tags = &tags } });
    defer {
        for (observation.outer_languages) |language_value| a.free(language_value);
        a.free(observation.outer_languages);
        a.free(observation.root_language);
    }
    return tags.toOwnedSlice(a);
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
    var exterior_generator = false;
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
        if (selected != null and (selected.?.exterior != null or selected.?.is_screen_prelude or selected.?.selected_get_wiki != null) and !tag.closing and tag.is("meta") and
            depth == 2 and stack[1].tag.is("head") and same(tag.attr("name") orelse "", "generator")) {
            const generator = tag.attr("content") orelse "";
            if (selected.?.selected_get_wiki != null) {
                if (exterior_generator or !std.mem.eql(u8, generator, selected.?.selected_get_generator.text())) return invalid;
            } else {
                if (exterior_generator or !same(generator, "MediaWiki 1.48.0-wmf.5")) return invalid;
                if (selected.?.is_screen_prelude and !std.mem.eql(u8, generator, "MediaWiki 1.48.0-wmf.5")) return invalid;
            }
            exterior_generator = true;
        }
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
            if (selected != null and (selected.?.is_screen_prelude or selected.?.selected_get_wiki != null) and !exterior_generator) return invalid;
            if (selected) |record| if (record.exterior) |exterior| {
                if (!exterior_generator) return invalid;
                for (stack[0..depth]) |node| try exterior.tags.append(a, node.tag.name);
            };
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


test "supplemental current prefix checks both titles namespace view and both revisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "<!DOCTYPE html><html lang=fr><head><script>RLCONF={\"wgArticleId\":1501871,\"wgRevisionId\":38791024,\"wgCurRevisionId\":38791024,\"wgNamespaceNumber\":118,\"wgPageName\":\"Racine:arabe/ل_ب_ن\",\"wgTitle\":\"arabe/ل ب ن\",\"wgAction\":\"view\",\"wgIsArticle\":true};</script></head><body><main><div class='mw-parser-output' lang=fr>";
    const title = "Racine:arabe/ل ب ن";
    const local = "arabe/ل ب ن";
    const accepted = try parseNamespacedCurrentAlloc(a, prefix, 1501871, 38791024, 118, title, local);
    try std.testing.expectEqualStrings("fr", accepted.root_language);
    for ([_][2][]const u8{
        .{ "\"wgArticleId\":1501871", "\"wgArticleId\":1501872" },
        .{ "\"wgRevisionId\":38791024", "\"wgRevisionId\":38791023" },
        .{ "\"wgCurRevisionId\":38791024", "\"wgCurRevisionId\":38791025" },
        .{ "\"wgNamespaceNumber\":118", "\"wgNamespaceNumber\":0" },
        .{ "Racine:arabe/ل_ب_ن", "Other:arabe/ل_ب_ن" },
        .{ "\"wgTitle\":\"arabe/ل ب ن\"", "\"wgTitle\":\"ل ب ن\"" },
        .{ "\"view\"", "\"edit\"" },
        .{ "true", "false" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, prefix, change[0], change[1]);
        try std.testing.expectError(invalid, parseNamespacedCurrentAlloc(a, altered, 1501871, 38791024, 118, title, local));
    }
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

test "Aragonese planetary table prelude retains its source classes and current identity" {
    const a = std.testing.allocator;
    const prelude = @embedFile("testdata/an-planet-table/vector-prelude.js");
    const script = prelude ++ "RLCONF={\"wgArticleId\":8372,\"wgRevisionId\":32427,\"wgCurRevisionId\":32427,\"wgNamespaceNumber\":0,\"wgTitle\":\"☉\",\"wgPageName\":\"☉\",\"wgAction\":\"view\",\"wgIsArticle\":true};";
    const page = SelectedPage{ .namespace_id = 0, .title = "☉" };
    const first = "(function(){var className=\"client-js ".len;
    const last = std.mem.indexOf(u8, prelude, "\";var cookie=") orelse return error.TestUnexpectedResult;
    const classes = try std.mem.concat(a, u8, &.{ "client-nojs ", prelude[first..last] });
    defer a.free(classes);
    try std.testing.expect(try configurationForSelectedPage(a, script, 8372, 32427, "☉", page, classes));
    try std.testing.expectError(invalid, configurationForSelectedPage(a, script, 8372, 32427, "☉", page, "client-nojs foreign"));
    try std.testing.expectError(invalid, configurationForSelectedPage(a, script, 8372, 32428, "☉", page, classes));
    const altered = try std.mem.replaceOwned(u8, a, script, "anwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences");
    defer a.free(altered);
    try std.testing.expectError(invalid, configurationForSelectedPage(a, altered, 8372, 32427, "☉", page, classes));
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

test "selected SR WMF5 oldid prefix retains actual program and refuses crossed operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const actual = @embedFile("testdata/sr-wmf5-america/get-prefix.html");
    const result = try parseSrWmf5SelectedOldidAlloc(a, actual, 11827, 711271, 0, "America");
    try std.testing.expectEqualStrings("sr", result.root_language);
    try std.testing.expectEqual(@as(usize, 8), result.outer_languages.len);
    try std.testing.expectError(invalid, parseSrWmf5SelectedOldidAlloc(a, actual, 11828, 711271, 0, "America"));
    try std.testing.expectError(invalid, parseSrWmf5SelectedOldidAlloc(a, actual, 11827, 711272, 0, "America"));
    try std.testing.expectError(invalid, parseSrWmf5SelectedOldidAlloc(a, actual, 11827, 711271, 1, "America"));
    try std.testing.expectError(invalid, parseSrWmf5SelectedOldidAlloc(a, actual, 11827, 711271, 0, "Elsewhere"));
    for ([_][2][]const u8{
        .{ "srwiktionarymwclientpreferences", "ruwiktionarymwclientpreferences" },
        .{ "srwiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "var cookie=", "var cookix=" },
        .{ "RLCONF=", "void 0;RLCONF=" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgRevisionId\":711271", "\"wgRevisionId\":0" },
        .{ "\"wgNamespaceNumber\":0", "\"wgNamespaceNumber\":1" },
        .{ "\"wgAction\":\"view\"", "\"wgAction\":\"edit\"" },
        .{ "<script>", "<script type=\"text/plain\">" },
        .{ "</head>", "</br></head>" },
    }) |pair| {
        const changed = try std.mem.replaceOwned(u8, a, actual, pair[0], pair[1]);
        try std.testing.expect(!std.mem.eql(u8, actual, changed));
        try std.testing.expectError(invalid, parseSrWmf5SelectedOldidAlloc(a, changed, 11827, 711271, 0, "America"));
    }
    // Direct RLCONF remains valid for old APIs but cannot substitute for this
    // explicitly observed program; the POST head's 931B program is also distinct.
    const script = @embedFile("testdata/sr-wmf5-america/get-config.js");
    const marker = std.mem.indexOf(u8, script, "RLCONF=") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 952), marker);
    const html_class = @embedFile("testdata/sr-wmf5-america/get-html-class.txt");
    const selected: SelectedPage = .{ .namespace_id = 0, .title = "America", .sr_wmf5_prelude = true };
    const unavailable = try std.mem.replaceOwned(u8, a, script, "vector-toc-available", "vector-toc-not-available");
    const unavailable_class = try std.mem.replaceOwned(u8, a, html_class, "vector-toc-available", "vector-toc-not-available");
    try std.testing.expect(try configurationForSelectedPage(a, unavailable, 11827, 711271, null, selected, unavailable_class));
    try std.testing.expectError(invalid, configurationForSelectedPage(a, unavailable, 11827, 711271, null, selected, html_class));
    try std.testing.expectError(invalid, configurationForSelectedPage(a, script, 11827, 711271, null, selected, unavailable_class));
    const changed_cookie = try std.mem.replaceOwned(u8, a, unavailable, "srwiktionarymwclientpreferences", "frwiktionarymwclientpreferences");
    try std.testing.expectError(invalid, configurationForSelectedPage(a, changed_cookie, 11827, 711271, null, selected, unavailable_class));
    try std.testing.expectError(invalid, configurationForSelectedPage(a, script[marker..], 11827, 711271, null, selected, html_class));
    const post = @embedFile("testdata/sr-wmf5-america/post-config.js");
    try std.testing.expectError(invalid, configurationForSelectedPage(a, post, 11827, 711271, null, selected, html_class));
}


test "observed Icelandic article stylesheet requires its exact selected revision generator and reviewed site prelude" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var input: std.Io.Reader = .fixed(@embedFile("testdata/is-authoritative-table/p888-prefix.html.gz"));
    var inflater: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
    const prefix = try inflater.reader.allocRemaining(alloc, .limited(64 * 1024));
    try std.testing.expect(inflater.err == null and inflater.state == .end);
    const name = "Autoversicherung";
    const generator = "MediaWiki 1.48.0-wmf.5";
    const accepted = try parseStylesheetOldidAlloc(alloc, prefix, 888, 309701, name, "iswiktionary", generator);
    try std.testing.expectEqualStrings("is", accepted.root_language);
    try std.testing.expectError(invalid, parseSelectedOldidAlloc(alloc, prefix, 888, 309701, 0, name));
    try std.testing.expectError(invalid, parseStylesheetOldidAlloc(alloc, prefix, 888, 309701, name, "elwiktionary", generator));
    try std.testing.expectError(invalid, parseStylesheetOldidAlloc(alloc, prefix, 888, 309701, name, "iswiktionary", "MediaWiki 1.48.0-wmf.4"));
    try std.testing.expectError(invalid, parseStylesheetOldidAlloc(alloc, prefix, 888, 309701, name, "ISwiktionary", generator));
    try std.testing.expectError(invalid, parseStylesheetOldidAlloc(alloc, prefix, 888, 309702, name, "iswiktionary", generator));
    for ([_][2][]const u8{ .{ "iswiktionarymwclientpreferences", "xxwiktionarymwclientpreferences" },
        .{ "iswiktionarymwclientpreferences", "srwiktionarymwclientpreferences" },
        .{ "client-nojs vector-feature", "client-nojs changed vector-feature" }, .{ generator, "MediaWiki 1.48.0-wmf.4" },
        .{ generator, "MediaWiki 1.48.0-WMF.5" } }) |change| {
        const altered = try std.mem.replaceOwned(u8, alloc, prefix, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, prefix, altered));
        try std.testing.expectError(invalid, parseStylesheetOldidAlloc(alloc, altered, 888, 309701, name, "iswiktionary", generator));
    }
}

test "selected GET en authentic fixed prelude binds identity and rejects crossed program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const bytes = @embedFile("testdata/selected-get-static01/en.prefix.html");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings("0d9e9249963ce0184fc246e77fa038215c7fd13d9227272df34544c59489754d", &std.fmt.bytesToHex(digest, .lower));
    const observed = try parseSelectedGetOldidAlloc(a, bytes, 10500003, 87816728, 0, "แมวเสือ", "enwiktionary");
    try std.testing.expectEqualStrings("en", observed.root_language);
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 10500003 + 1, 87816728, 0, "แมวเสือ", "enwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 10500003, 87816728 + 1, 0, "แมวเสือ", "enwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 10500003, 87816728, 1, "แมวเสือ", "enwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 10500003, 87816728, 0, "crossed", "enwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 10500003, 87816728, 0, "แมวเสือ", "crossedwiktionary"));
    for ([_][2][]const u8{
        .{ "enwiktionarymwclientpreferences", "crossedwiktionarymwclientpreferences" },
        .{ "client-nojs ", "client-nojs crossed " },
        .{ "var cookie=", "var cookix=" },
        .{ "document.documentElement.className=className", "document.documentElement.className=other" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "RLCONF=", "void 0;RLCONF=" },
        .{ "MediaWiki 1.48.0-wmf.5", "MediaWiki 1.48.0-wmf.4" },
        .{ "MediaWiki 1.48.0-wmf.5", "MediaWiki 1.48.0-WMF.5" },
        .{ "\"wgRevisionId\":87816728", "\"wgRevisionId\":\"87816728\"" },
        .{ "\"wgNamespaceNumber\":0", "\"wgNamespaceNumber\":1" },
        .{ "\"wgAction\":\"view\"", "\"wgAction\":\"edit\"" },
        .{ "\"wgTitle\":\"แมวเสือ\"", "\"wgTitle\":\"crossed\"" },
        .{ "\"wgUserName\":null", "\"wgUserName\":\"crossed\"" },
        .{ "<script>", "<script type=\"text/plain\">" },
        .{ "</head>", "<script>RLCONF={};</script></head>" },
    }) |pair| {
        const altered = try std.mem.replaceOwned(u8, a, bytes, pair[0], pair[1]);
        try std.testing.expect(!std.mem.eql(u8, bytes, altered));
        try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, altered, 10500003, 87816728, 0, "แมวเสือ", "enwiktionary"));
    }
    // Even valid direct configuration cannot replace the captured full program.
    const cropped = try std.mem.concat(a, u8, &.{bytes[0..758], bytes[1710..]});
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, cropped, 10500003, 87816728, 0, "แมวเสือ", "enwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes[0..bytes.len - 1], 10500003, 87816728, 0, "แมวเสือ", "enwiktionary"));
    // Selected oldid does not require the wiki's latest revision to be identical.
    const newer = try std.mem.replaceOwned(u8, a, bytes, "\"wgCurRevisionId\":87816728", "\"wgCurRevisionId\":87816729");
    _ = try parseSelectedGetOldidAlloc(a, newer, 10500003, 87816728, 0, "แมวเสือ", "enwiktionary");
}

test "selected GET hu authentic fixed prelude binds identity and rejects crossed program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const bytes = @embedFile("testdata/selected-get-static01/hu.prefix.html");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings("984e7ce3058d2897e96fc9441af6cb348973cfb5a00bf3c7505ba03d365b6633", &std.fmt.bytesToHex(digest, .lower));
    const observed = try parseSelectedGetOldidAlloc(a, bytes, 609, 3518053, 0, "víz", "huwiktionary");
    try std.testing.expectEqualStrings("hu", observed.root_language);
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 609 + 1, 3518053, 0, "víz", "huwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 609, 3518053 + 1, 0, "víz", "huwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 609, 3518053, 1, "víz", "huwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 609, 3518053, 0, "crossed", "huwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 609, 3518053, 0, "víz", "crossedwiktionary"));
    for ([_][2][]const u8{
        .{ "huwiktionarymwclientpreferences", "crossedwiktionarymwclientpreferences" },
        .{ "client-nojs ", "client-nojs crossed " },
        .{ "var cookie=", "var cookix=" },
        .{ "document.documentElement.className=className", "document.documentElement.className=other" },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "RLCONF=", "void 0;RLCONF=" },
        .{ "MediaWiki 1.48.0-wmf.5", "MediaWiki 1.48.0-wmf.4" },
        .{ "MediaWiki 1.48.0-wmf.5", "MediaWiki 1.48.0-WMF.5" },
        .{ "\"wgRevisionId\":3518053", "\"wgRevisionId\":\"3518053\"" },
        .{ "\"wgNamespaceNumber\":0", "\"wgNamespaceNumber\":1" },
        .{ "\"wgAction\":\"view\"", "\"wgAction\":\"edit\"" },
        .{ "\"wgTitle\":\"víz\"", "\"wgTitle\":\"crossed\"" },
        .{ "\"wgUserName\":null", "\"wgUserName\":\"crossed\"" },
        .{ "<script>", "<script type=\"text/plain\">" },
        .{ "</head>", "<script>RLCONF={};</script></head>" },
    }) |pair| {
        const altered = try std.mem.replaceOwned(u8, a, bytes, pair[0], pair[1]);
        try std.testing.expect(!std.mem.eql(u8, bytes, altered));
        try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, altered, 609, 3518053, 0, "víz", "huwiktionary"));
    }
    // Even valid direct configuration cannot replace the captured full program.
    const cropped = try std.mem.concat(a, u8, &.{bytes[0..207], bytes[642..]});
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, cropped, 609, 3518053, 0, "víz", "huwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes[0..bytes.len - 1], 609, 3518053, 0, "víz", "huwiktionary"));
    // Selected oldid does not require the wiki's latest revision to be identical.
    const newer = try std.mem.replaceOwned(u8, a, bytes, "\"wgCurRevisionId\":3518053", "\"wgCurRevisionId\":3518054");
    _ = try parseSelectedGetOldidAlloc(a, newer, 609, 3518053, 0, "víz", "huwiktionary");
}

test "selected GET observed HU WMF6 binds explicit generator without widening WMF5 identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const bytes = @embedFile("testdata/selected-get-wmf6-01/hu.prefix.html");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings("9cc7a399e80647ce0be5641ee645935cabef00ec5646065cb70b9e78f0e7f371", &std.fmt.bytesToHex(digest, .lower));
    const observed = try parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 609, 3518053, 0, "víz", "huwiktionary", .wmf6);
    try std.testing.expectEqualStrings("hu", observed.root_language);
    try std.testing.expectError(invalid, parseSelectedGetOldidAlloc(a, bytes, 609, 3518053, 0, "víz", "huwiktionary"));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 609, 3518053, 0, "víz", "huwiktionary", .wmf5));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 610, 3518053, 0, "víz", "huwiktionary", .wmf6));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 609, 3518054, 0, "víz", "huwiktionary", .wmf6));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 609, 3518053, 1, "víz", "huwiktionary", .wmf6));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 609, 3518053, 0, "crossed", "huwiktionary", .wmf6));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes, 609, 3518053, 0, "víz", "crossedwiktionary", .wmf6));
    for ([_][2][]const u8{
        .{ "MediaWiki 1.48.0-wmf.6", "MediaWiki 1.48.0-wmf.5" },
        .{ "MediaWiki 1.48.0-wmf.6", "MediaWiki 1.48.0-wmf.7" },
        .{ "MediaWiki 1.48.0-wmf.6", "MediaWiki 1.48.0-WMF.6" },
        .{ "huwiktionarymwclientpreferences", "crossedwiktionarymwclientpreferences" },
        .{ "client-nojs ", "client-nojs crossed " },
        .{ "var cookie=", "var cookix=" },
        .{ "document.documentElement.className=className", "document.documentElement.className=other" },
        .{ "RLCONF=", "void 0;RLCONF=" },
        .{ "\"wgRevisionId\":3518053", "\"wgRevisionId\":\"3518053\"" },
        .{ "\"wgNamespaceNumber\":0", "\"wgNamespaceNumber\":1" },
        .{ "\"wgAction\":\"view\"", "\"wgAction\":\"edit\"" },
        .{ "\"wgTitle\":\"víz\"", "\"wgTitle\":\"crossed\"" },
        .{ "\"wgUserName\":null", "\"wgUserName\":\"crossed\"" },
        .{ "<script>", "<script type=\"text/plain\">" },
        .{ "</head>", "<script>RLCONF={};</script></head>" },
        .{ "</head>", "<meta name=\"generator\" content=\"MediaWiki 1.48.0-wmf.6\"></head>" },
    }) |pair| {
        const altered = try std.mem.replaceOwned(u8, a, bytes, pair[0], pair[1]);
        try std.testing.expect(!std.mem.eql(u8, bytes, altered));
        try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, altered, 609, 3518053, 0, "víz", "huwiktionary", .wmf6));
    }
    const cropped = try std.mem.concat(a, u8, &.{bytes[0..207], bytes[642..]});
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, cropped, 609, 3518053, 0, "víz", "huwiktionary", .wmf6));
    try std.testing.expectError(invalid, parseSelectedGetOldidWithGeneratorAlloc(a, bytes[0..bytes.len - 1], 609, 3518053, 0, "víz", "huwiktionary", .wmf6));
}

test "normal text actual selected oldid prelude binds wiki and preserves prior refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const bytes = @embedFile("testdata/normal-text-polvoroso01/response.prefix.html");
    var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings("a82d4134c3f47d42afe41fb65f2ad9757d5e150cfa05b248df71ffc3e6df2436", &std.fmt.bytesToHex(digest, .lower));
    const observed = try parseNormalTextOldidAlloc(a, bytes, 1513544, 6045117, 0, "polvoroso", "zhwiktionary");
    try std.testing.expectEqualStrings("zh", observed.root_language);
    try std.testing.expectEqual(@as(usize, 8), observed.outer_languages.len);
    for (observed.outer_languages) |lang| try std.testing.expectEqualStrings("zh", lang);
    try std.testing.expectError(invalid, parseSelectedOldidAlloc(a, bytes, 1513544, 6045117, 0, "polvoroso"));
    try std.testing.expectError(invalid, parseNormalTextOldidAlloc(a, bytes, 1513544, 6045117, 0, "polvoroso", "srwiktionary"));
    try std.testing.expectError(invalid, parseNormalTextOldidAlloc(a, bytes, 1513544, 6045116, 0, "polvoroso", "zhwiktionary"));
    try std.testing.expectError(invalid, parseNormalTextOldidAlloc(a, bytes, 1513545, 6045117, 0, "polvoroso", "zhwiktionary"));
    try std.testing.expectError(invalid, parseNormalTextOldidAlloc(a, bytes, 1513544, 6045117, 1, "polvoroso", "zhwiktionary"));
    try std.testing.expectError(invalid, parseNormalTextOldidAlloc(a, bytes, 1513544, 6045117, 0, "other", "zhwiktionary"));
    // Selected-oldid is intentionally not a current-revision equality claim.
    const newer = try std.mem.replaceOwned(u8, a, bytes, "\"wgCurRevisionId\":6045117", "\"wgCurRevisionId\":6045118");
    _ = try parseNormalTextOldidAlloc(a, newer, 1513544, 6045117, 0, "polvoroso", "zhwiktionary");
    for ([_][2][]const u8{
        .{ "zhwiktionarymwclientpreferences", "zzwiktionarymwclientpreferences" },
        .{ "document.documentElement.className=className", "document.documentElement.className=otherName" },
        .{ "class=\"client-nojs ", "class=\"invented-nojs " },
        .{ "RLCONF=", "if(false)RLCONF=" },
        .{ "\"wgRevisionId\":6045117", "\"wgRevisionId\":\"6045117\"" },
        .{ "\"wgAction\":\"view\"", "\"wgAction\":\"edit\"" },
    }) |change| {
        const altered = try std.mem.replaceOwned(u8, a, bytes, change[0], change[1]);
        try std.testing.expect(!std.mem.eql(u8, bytes, altered));
        try std.testing.expectError(invalid, parseNormalTextOldidAlloc(a, altered, 1513544, 6045117, 0, "polvoroso", "zhwiktionary"));
    }
}
