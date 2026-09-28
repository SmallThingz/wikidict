const std = @import("std");

// This is the runtime Value tag, checked against the actual union in core.zig.
// Literal field readers and ordinary map writes must use identical hashes so
// they address the same buckets without changing Lua table iteration order.
pub const string_value_tag: u8 = 3;

pub fn hashStringKey(text: []const u8) u64 {
    if (text.len <= 63) {
        var bytes: [64]u8 = undefined;
        bytes[0] = string_value_tag;
        @memcpy(bytes[1..][0..text.len], text);
        return std.hash.Wyhash.hash(0, bytes[0 .. text.len + 1]);
    }
    var h = std.hash.Wyhash.init(0);
    h.update(&.{string_value_tag});
    h.update(text);
    return h.final();
}

// Native global pointers must remain in this permanently dense slot prefix.
pub const global_dense_prefix_len: u32 = 64;

pub const Namespace = enum(u8) {
    table,
    string,
    math,
    debug,
    mw,
    ustring,
    title,
    text,
    uri,
    html,
    language,
    frame,
    title_value,
    language_value,
    html_node,
    hash,
    site,
    site_stats,
    ext,
    ext_data,
    wikibase,
    message,
    message_value,
    uri_value,
    title_batch,
    os,
    namespace_map,
    namespace_value,
    package,
    package_loaded,
    bit32,
    library_util,
};
const names = [_][]const u8{
    "insert",               "remove",             "concat",            "sort",            "maxn",                 "getn",
    "len",                  "sub",                "lower",             "upper",           "reverse",              "rep",
    "char",                 "byte",               "find",              "match",           "gmatch",               "gsub",
    "format",               "abs",                "ceil",              "floor",           "sqrt",                 "exp",
    "log",                  "log10",              "sin",               "cos",             "tan",                  "asin",
    "acos",                 "atan",               "deg",               "rad",             "min",                  "max",
    "pow",                  "fmod",               "mod",               "modf",            "pi",                   "huge",
    "getmetatable",         "traceback",          "getinfo",           "loadData",        "clone",                "getCurrentFrame",
    "ustring",              "dumpObject",         "logObject",         "addWarning",      "isSubsting",           "title",
    "text",                 "site",               "uri",               "wikibase",        "message",              "hash",
    "ext",                  "html",               "language",          "isutf8",          "byteoffset",           "codepoint",
    "gcodepoint",           "toNFC",              "toNFD",             "toNFKC",          "toNFKD",               "equals",
    "compare",              "new",                "makeTitle",         "getCurrentTitle", "newBatch",             "trim",
    "split",                "gsplit",             "unstrip",           "unstripNoWiki",   "listToText",           "nowiki",
    "jsonEncode",           "jsonDecode",         "tag",               "truncate",        "encode",               "decode",
    "fullUrl",              "localUrl",           "canonicalUrl",      "anchorEncode",    "create",               "getContentLanguage",
    "getFallbacksFor",      "isKnownLanguageTag", "fetchLanguageName", "getLanguage",     "args",                 "getParent",
    "getTitle",             "expandTemplate",     "preprocess",        "extensionTag",    "callParserFunction",   "prefixedText",
    "__fragment",           "namespace",          "nsText",            "subpageText",     "baseText",             "rootText",
    "isSubpage",            "interwiki",          "exists",            "getContent",      "code",                 "getCode",
    "formatDate",           "uc",                 "lc",                "ucfirst",         "lcfirst",              "getDir",
    "getFallbackLanguages", "getArrow",           "gender",            "formatNum",       "parseFormattedNumber", "done",
    "allDone",              "wikitext",           "node",              "css",             "cssText",              "addClass",
    "attr",                 "newline",
};

const table_names = names[0..6];
const string_names = names[6..19];
const math_names = [_][]const u8{ "abs", "ceil", "floor", "sqrt", "exp", "log", "log10", "sin", "cos", "tan", "asin", "acos", "atan", "deg", "rad", "min", "max", "pow", "fmod", "mod", "modf", "pi", "huge", "random", "randomseed" };
const debug_names = [_][]const u8{ "traceback", "getmetatable", "getinfo" };
const mw_names = [_][]const u8{
    "loadData",   "loadJsonData", "clone", "getCurrentFrame", "ustring",            "dumpObject",  "log",                             "logObject",
    "addWarning", "isSubsting",   "title", "text",            "site",               "uri",         "wikibase",                        "message",
    "hash",       "ext",          "html",  "language",        "getContentLanguage", "getLanguage", "incrementExpensiveFunctionCount",
};
const ustring_names = [_][]const u8{
    "len",    "sub",  "lower",  "upper",  "reverse",    "rep",       "char",       "byte",  "find",  "match",
    "gmatch", "gsub", "format", "isutf8", "byteoffset", "codepoint", "gcodepoint", "toNFC", "toNFD", "toNFKC",
    "toNFKD",
};
const title_names = names[71..77];
const text_names = [_][]const u8{ "trim", "split", "gsplit", "unstrip", "unstripNoWiki", "killMarkers", "listToText", "nowiki", "jsonEncode", "jsonDecode", "tag", "truncate", "encode", "decode", "JSON_PRESERVE_KEYS", "JSON_TRY_FIXING", "JSON_PRETTY" };
const uri_names = [_][]const u8{ "fullUrl", "localUrl", "canonicalUrl", "encode", "decode", "anchorEncode", "new", "validate" };
const html_names = names[94..95];
const language_names = [_][]const u8{ "new", "getContentLanguage", "getFallbacksFor", "isKnownLanguageTag", "fetchLanguageName" };
const frame_names = [_][]const u8{ "args", "getParent", "getTitle", "expandTemplate", "preprocess", "extensionTag", "callParserFunction", "newChild" };
const title_value_names = [_][]const u8{
    "text",          "prefixedText",  "__fragment",   "namespace",      "nsText",     "subpageText",   "baseText",         "rootText",
    "isSubpage",     "interwiki",     "isExternal",   "isLocal",        "exists",     "getContent",    "fullUrl",          "localUrl",
    "canonicalUrl",  "inNamespace",   "isSubpageOf",  "subPageTitle",   "content",    "file",          "fileExists",       "fragment",
    "fullText",      "id",            "isRedirect",   "redirectTarget", "isTalkPage", "isContentPage", "subjectPageTitle", "talkPageTitle",
    "basePageTitle", "rootPageTitle", "contentModel", "subjectNsText",  "talkNsText", "canTalk",
};
const language_value_names = [_][]const u8{
    "code",  "getCode",              "formatDate", "uc",     "lc",        "ucfirst",              "lcfirst", "getDir",
    "isRTL", "getFallbackLanguages", "getArrow",   "gender", "formatNum", "parseFormattedNumber",
};
const html_node_names = [_][]const u8{ "tag", "done", "allDone", "wikitext", "node", "css", "cssText", "addClass", "attr", "getAttr", "newline" };
const hash_names = [_][]const u8{"hashValue"};
const site_names = [_][]const u8{ "namespaces", "stats", "interwikiMap" };
const site_stats_names = [_][]const u8{ "pagesInCategory", "pagesInNamespace", "usersInGroup" };
const ext_names = [_][]const u8{"data"};
const ext_data_names = [_][]const u8{"get"};
const wikibase_names = [_][]const u8{
    "getEntity",        "getEntityIdForTitle", "getEntityIdForCurrentPage", "getBestStatements",
    "getLabelWithLang", "getLabelByLang",      "getAllStatements",          "formatValue",
    "entityExists",     "getDescription",      "getLabel",                  "getSitelink",
    "sitelink",         "getEntityUrl",        "getGlobalSiteId",           "isValidEntityId",
};
const message_names = [_][]const u8{
    "new", "newRawMessage", "newFallbackSequence", "rawParam", "numParam", "getDefaultLanguage",
};
const message_value_names = [_][]const u8{
    "plain", "exists", "isBlank", "isDisabled", "inLanguage", "params", "rawParams", "numParams", "useDatabase",
};
const uri_value_names = [_][]const u8{
    "protocol", "user", "password", "host", "port", "path", "query", "fragment",
};
const title_batch_names = [_][]const u8{ "lookupExistence", "getTitles" };
const os_names = [_][]const u8{ "date", "time", "difftime", "clock" };
const namespace_map_names = [_][]const u8{};
const namespace_value_names = [_][]const u8{
    "id",                   "name",      "canonicalName", "hasSubpages", "isCapitalized", "aliases", "displayName",
    "hasGenderDistinction", "isContent", "isIncludable",  "isMovable",   "isSubject",     "isTalk",  "defaultContentModel",
    "subject",              "talk",      "associated",
};
const package_names = [_][]const u8{ "loaded", "loaders" };
const package_loaded_names = [_][]const u8{
    "_G", "table", "string", "math", "debug", "bit32", "libraryUtil", "package", "strict",
};
const bit32_names = [_][]const u8{ "band", "bor" };
const library_util_names = [_][]const u8{ "checkType", "checkTypeMulti" };

const NamespaceMapEntry = struct { name: []const u8, id: i32 };
const namespace_map_entries = [_]NamespaceMapEntry{
    .{ .name = "Media", .id = -2 },
    .{ .name = "Special", .id = -1 },
    .{ .name = "", .id = 0 },
    .{ .name = "Talk", .id = 1 },
    .{ .name = "User", .id = 2 },
    .{ .name = "User talk", .id = 3 },
    .{ .name = "Wiktionary", .id = 4 },
    .{ .name = "Project", .id = 4 },
    .{ .name = "WT", .id = 4 },
    .{ .name = "Wiktionary talk", .id = 5 },
    .{ .name = "Project talk", .id = 5 },
    .{ .name = "File", .id = 6 },
    .{ .name = "Image", .id = 6 },
    .{ .name = "File talk", .id = 7 },
    .{ .name = "Image talk", .id = 7 },
    .{ .name = "MediaWiki", .id = 8 },
    .{ .name = "MediaWiki talk", .id = 9 },
    .{ .name = "Template", .id = 10 },
    .{ .name = "T", .id = 10 },
    .{ .name = "Template talk", .id = 11 },
    .{ .name = "Help", .id = 12 },
    .{ .name = "Help talk", .id = 13 },
    .{ .name = "Category", .id = 14 },
    .{ .name = "CAT", .id = 14 },
    .{ .name = "Category talk", .id = 15 },
    .{ .name = "Thread", .id = 90 },
    .{ .name = "Thread talk", .id = 91 },
    .{ .name = "Summary", .id = 92 },
    .{ .name = "Summary talk", .id = 93 },
    .{ .name = "Appendix", .id = 100 },
    .{ .name = "AP", .id = 100 },
    .{ .name = "Appendix talk", .id = 101 },
    .{ .name = "Rhymes", .id = 106 },
    .{ .name = "Rhymes talk", .id = 107 },
    .{ .name = "Transwiki", .id = 108 },
    .{ .name = "Transwiki talk", .id = 109 },
    .{ .name = "Thesaurus", .id = 110 },
    .{ .name = "WS", .id = 110 },
    .{ .name = "Wikisaurus", .id = 110 },
    .{ .name = "Thesaurus talk", .id = 111 },
    .{ .name = "Wikisaurus talk", .id = 111 },
    .{ .name = "Citations", .id = 114 },
    .{ .name = "Citations talk", .id = 115 },
    .{ .name = "Sign gloss", .id = 116 },
    .{ .name = "Sign gloss talk", .id = 117 },
    .{ .name = "Reconstruction", .id = 118 },
    .{ .name = "RC", .id = 118 },
    .{ .name = "Reconstruction talk", .id = 119 },
    .{ .name = "TimedText", .id = 710 },
    .{ .name = "TimedText talk", .id = 711 },
    .{ .name = "Module", .id = 828 },
    .{ .name = "MOD", .id = 828 },
    .{ .name = "Module talk", .id = 829 },
    .{ .name = "Event", .id = 1728 },
    .{ .name = "Event talk", .id = 1729 },
    .{ .name = "Topic", .id = 2600 },
};

fn namespaceNameEqual(raw: []const u8, expected: []const u8) bool {
    if (raw.len != expected.len) return false;
    for (raw, expected) |lhs_raw, rhs_raw| {
        const lhs = if (lhs_raw == '_') ' ' else lhs_raw;
        if (std.ascii.toLower(lhs) != std.ascii.toLower(rhs_raw)) return false;
    }
    return true;
}

pub fn namespaceMapId(name: []const u8) ?i32 {
    for (namespace_map_entries) |entry|
        if (namespaceNameEqual(name, entry.name)) return entry.id;
    return null;
}

fn namespaceNames(namespace: Namespace) []const []const u8 {
    return switch (namespace) {
        .table => table_names,
        .string => string_names,
        .math => &math_names,
        .debug => &debug_names,
        .mw => &mw_names,
        .ustring => &ustring_names,
        .title => title_names,
        .text => &text_names,
        .uri => &uri_names,
        .html => html_names,
        .language => &language_names,
        .frame => &frame_names,
        .title_value => &title_value_names,
        .language_value => &language_value_names,
        .html_node => &html_node_names,
        .hash => &hash_names,
        .site => &site_names,
        .site_stats => &site_stats_names,
        .ext => &ext_names,
        .ext_data => &ext_data_names,
        .wikibase => &wikibase_names,
        .message => &message_names,
        .message_value => &message_value_names,
        .uri_value => &uri_value_names,
        .title_batch => &title_batch_names,
        .os => &os_names,
        .namespace_map => &namespace_map_names,
        .namespace_value => &namespace_value_names,
        .package => &package_names,
        .package_loaded => &package_loaded_names,
        .bit32 => &bit32_names,
        .library_util => &library_util_names,
    };
}
pub fn fieldCount(namespace: Namespace) u32 {
    return @intCast(namespaceNames(namespace).len);
}

fn slotMap(comptime field_names: []const []const u8) std.StaticStringMap(u32) {
    var pairs: [field_names.len]struct { []const u8, u32 } = undefined;
    for (field_names, 0..) |field_name, slot| pairs[slot] = .{ field_name, @intCast(slot) };
    return std.StaticStringMap(u32).initComptime(pairs);
}

fn staticSlot(comptime field_names: []const []const u8, field_name: []const u8) ?u32 {
    const map = comptime slotMap(field_names);
    return map.get(field_name);
}

pub fn slotForName(namespace: Namespace, field_name: []const u8) ?u32 {
    return switch (namespace) {
        .table => staticSlot(table_names, field_name),
        .string => staticSlot(string_names, field_name),
        .math => staticSlot(&math_names, field_name),
        .debug => staticSlot(&debug_names, field_name),
        .mw => staticSlot(&mw_names, field_name),
        .ustring => staticSlot(&ustring_names, field_name),
        .title => staticSlot(title_names, field_name),
        .text => staticSlot(&text_names, field_name),
        .uri => staticSlot(&uri_names, field_name),
        .html => staticSlot(html_names, field_name),
        .language => staticSlot(&language_names, field_name),
        .frame => staticSlot(&frame_names, field_name),
        .title_value => staticSlot(&title_value_names, field_name),
        .language_value => staticSlot(&language_value_names, field_name),
        .html_node => staticSlot(&html_node_names, field_name),
        .hash => staticSlot(&hash_names, field_name),
        .site => staticSlot(&site_names, field_name),
        .site_stats => staticSlot(&site_stats_names, field_name),
        .ext => staticSlot(&ext_names, field_name),
        .ext_data => staticSlot(&ext_data_names, field_name),
        .wikibase => staticSlot(&wikibase_names, field_name),
        .message => staticSlot(&message_names, field_name),
        .message_value => staticSlot(&message_value_names, field_name),
        .uri_value => staticSlot(&uri_value_names, field_name),
        .title_batch => staticSlot(&title_batch_names, field_name),
        .os => staticSlot(&os_names, field_name),
        .namespace_map => if (namespaceMapId(field_name) != null) 0 else null,
        .namespace_value => staticSlot(&namespace_value_names, field_name),
        .package => staticSlot(&package_names, field_name),
        .package_loaded => staticSlot(&package_loaded_names, field_name),
        .bit32 => staticSlot(&bit32_names, field_name),
        .library_util => staticSlot(&library_util_names, field_name),
    };
}

pub fn nameAt(namespace: Namespace, slot: u32) ?[]const u8 {
    const namespace_names = namespaceNames(namespace);
    if (slot >= namespace_names.len) return null;
    return namespace_names[slot];
}

/// Structural namespace of a table-valued field on a compiler-known native
/// namespace. These are immutable API layout facts, not assumptions about the
/// live field value: callers must still guard the runtime namespace.
pub fn fieldNamespace(namespace: Namespace, field_name: []const u8) ?Namespace {
    return switch (namespace) {
        .mw => if (std.mem.eql(u8, field_name, "ustring"))
            .ustring
        else if (std.mem.eql(u8, field_name, "title"))
            .title
        else if (std.mem.eql(u8, field_name, "text"))
            .text
        else if (std.mem.eql(u8, field_name, "uri"))
            .uri
        else if (std.mem.eql(u8, field_name, "hash"))
            .hash
        else if (std.mem.eql(u8, field_name, "html"))
            .html
        else if (std.mem.eql(u8, field_name, "language"))
            .language
        else if (std.mem.eql(u8, field_name, "site"))
            .site
        else if (std.mem.eql(u8, field_name, "ext"))
            .ext
        else if (std.mem.eql(u8, field_name, "wikibase"))
            .wikibase
        else if (std.mem.eql(u8, field_name, "message"))
            .message
        else
            null,
        .site => if (std.mem.eql(u8, field_name, "stats"))
            .site_stats
        else if (std.mem.eql(u8, field_name, "namespaces"))
            .namespace_map
        else
            null,
        .ext => if (std.mem.eql(u8, field_name, "data")) .ext_data else null,
        .title_value => if (std.mem.eql(u8, field_name, "redirectTarget") or
            std.mem.eql(u8, field_name, "subjectPageTitle") or
            std.mem.eql(u8, field_name, "talkPageTitle") or
            std.mem.eql(u8, field_name, "basePageTitle") or
            std.mem.eql(u8, field_name, "rootPageTitle"))
            .title_value
        else
            null,
        .namespace_map => if (namespaceMapId(field_name) != null) .namespace_value else null,
        .namespace_value => if (std.mem.eql(u8, field_name, "subject") or
            std.mem.eql(u8, field_name, "talk") or
            std.mem.eql(u8, field_name, "associated"))
            .namespace_value
        else
            null,
        .package => if (std.mem.eql(u8, field_name, "loaded")) .package_loaded else null,
        else => null,
    };
}

/// Structural namespace of a single-result native API call. The emitter carries
/// this only as a guarded hint so overwritten functions retain ordinary Lua
/// behavior.
pub fn callReturnNamespace(namespace: Namespace, field_name: []const u8) ?Namespace {
    return switch (namespace) {
        .mw => if (std.mem.eql(u8, field_name, "getCurrentFrame"))
            .frame
        else if (std.mem.eql(u8, field_name, "getContentLanguage") or
            std.mem.eql(u8, field_name, "getLanguage"))
            .language_value
        else
            null,
        .title => if (std.mem.eql(u8, field_name, "new") or
            std.mem.eql(u8, field_name, "makeTitle") or
            std.mem.eql(u8, field_name, "getCurrentTitle"))
            .title_value
        else if (std.mem.eql(u8, field_name, "newBatch"))
            .title_batch
        else
            null,
        .uri => if (std.mem.eql(u8, field_name, "new") or
            std.mem.eql(u8, field_name, "fullUrl") or
            std.mem.eql(u8, field_name, "localUrl") or
            std.mem.eql(u8, field_name, "canonicalUrl"))
            .uri_value
        else
            null,
        .language => if (std.mem.eql(u8, field_name, "new") or
            std.mem.eql(u8, field_name, "getContentLanguage"))
            .language_value
        else
            null,
        .html => if (std.mem.eql(u8, field_name, "create")) .html_node else null,
        .frame => if (std.mem.eql(u8, field_name, "getParent") or
            std.mem.eql(u8, field_name, "newChild"))
            .frame
        else
            null,
        .title_value => if (std.mem.eql(u8, field_name, "subPageTitle")) .title_value else null,
        .html_node => if (std.mem.eql(u8, field_name, "tag") or
            std.mem.eql(u8, field_name, "done") or
            std.mem.eql(u8, field_name, "allDone") or
            std.mem.eql(u8, field_name, "node"))
            .html_node
        else
            null,
        .message => if (std.mem.eql(u8, field_name, "new") or
            std.mem.eql(u8, field_name, "newRawMessage"))
            .message_value
        else
            null,
        .message_value => if (std.mem.eql(u8, field_name, "inLanguage")) .message_value else null,
        .title_batch => if (std.mem.eql(u8, field_name, "lookupExistence")) .title_batch else null,
        else => null,
    };
}
test "namespace slot layouts round trip" {
    inline for (std.meta.fields(Namespace)) |field| {
        const namespace: Namespace = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u32, @intCast(namespaceNames(namespace).len)), fieldCount(namespace));
        for (namespaceNames(namespace), 0..) |field_name, expected| {
            try std.testing.expectEqual(@as(u32, @intCast(expected)), slotForName(namespace, field_name).?);
            try std.testing.expectEqualStrings(field_name, nameAt(namespace, @intCast(expected)).?);
        }
    }
    try std.testing.expectEqual(@as(?u32, null), slotForName(.table, "definitely-not-a-field"));
    try std.testing.expectEqual(Namespace.title, fieldNamespace(.mw, "title").?);
    try std.testing.expectEqual(Namespace.title_value, callReturnNamespace(.title, "new").?);
    try std.testing.expectEqual(Namespace.frame, callReturnNamespace(.frame, "newChild").?);
    try std.testing.expectEqual(@as(?i32, 10), namespaceMapId("template"));
    try std.testing.expectEqual(@as(?i32, 3), namespaceMapId("user_talk"));
    try std.testing.expectEqual(Namespace.namespace_value, fieldNamespace(.namespace_map, "Template").?);
}
