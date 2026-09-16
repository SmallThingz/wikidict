const std = @import("std");

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
const math_names = names[19..42];
const debug_names = names[42..45];
const mw_names = [_][]const u8{
    "loadData",   "clone",      "getCurrentFrame", "ustring", "dumpObject", "log",                "logObject",
    "addWarning", "isSubsting", "title",           "text",    "site",       "uri",                "wikibase",
    "message",    "hash",       "ext",             "html",    "language",   "getContentLanguage", "getLanguage",
};
const ustring_names = [_][]const u8{
    "len",    "sub",  "lower",  "upper",  "reverse",    "rep",       "char",       "byte",  "find",  "match",
    "gmatch", "gsub", "format", "isutf8", "byteoffset", "codepoint", "gcodepoint", "toNFC", "toNFD", "toNFKC",
    "toNFKD",
};
const title_names = names[71..77];
const text_names = [_][]const u8{ "trim", "split", "gsplit", "unstrip", "unstripNoWiki", "killMarkers", "listToText", "nowiki", "jsonEncode", "jsonDecode", "tag", "truncate", "encode", "decode" };
const uri_names = [_][]const u8{ "fullUrl", "localUrl", "canonicalUrl", "encode", "decode", "anchorEncode", "new", "validate" };
const html_names = names[94..95];
const language_names = [_][]const u8{ "new", "getContentLanguage", "getFallbacksFor", "isKnownLanguageTag", "fetchLanguageName" };
const frame_names = [_][]const u8{ "args", "getParent", "getTitle", "expandTemplate", "preprocess", "extensionTag", "callParserFunction" };
const title_value_names = [_][]const u8{
    "text",         "prefixedText", "__fragment", "namespace", "nsText", "subpageText", "baseText", "rootText",
    "isSubpage",    "interwiki",    "isExternal", "isLocal",   "exists", "getContent",  "fullUrl",  "localUrl",
    "canonicalUrl",
};
const language_value_names = [_][]const u8{
    "code",     "getCode", "formatDate", "uc",                   "lc", "ucfirst", "lcfirst", "getDir", "getFallbackLanguages",
    "getArrow", "gender",  "formatNum",  "parseFormattedNumber",
};
const html_node_names = [_][]const u8{ "tag", "done", "allDone", "wikitext", "node", "css", "cssText", "addClass", "attr", "getAttr", "newline" };
const hash_names = [_][]const u8{"hashValue"};

fn namespaceNames(namespace: Namespace) []const []const u8 {
    return switch (namespace) {
        .table => table_names,
        .string => string_names,
        .math => math_names,
        .debug => debug_names,
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
        .math => staticSlot(math_names, field_name),
        .debug => staticSlot(debug_names, field_name),
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
    };
}

pub fn nameAt(namespace: Namespace, slot: u32) ?[]const u8 {
    const namespace_names = namespaceNames(namespace);
    if (slot >= namespace_names.len) return null;
    return namespace_names[slot];
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
}
