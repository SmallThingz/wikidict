const std = @import("std");

pub const Namespace = enum(u8) { table, string, math, debug, mw, ustring };
pub const marker: u32 = @as(u32, 1) << 31;
const index_mask = marker - 1;

pub const names = [_][]const u8{
    "insert",       "remove",     "concat",    "sort",       "maxn",       "getn",
    "len",          "sub",        "lower",     "upper",      "reverse",    "rep",
    "char",         "byte",       "find",      "match",      "gmatch",     "gsub",
    "format",       "abs",        "ceil",      "floor",      "sqrt",       "exp",
    "log",          "log10",      "sin",       "cos",        "tan",        "asin",
    "acos",         "atan",       "deg",       "rad",        "min",        "max",
    "pow",          "fmod",       "mod",       "modf",       "pi",         "huge",
    "getmetatable", "traceback",  "getinfo",   "loadData",   "clone",      "getCurrentFrame",
    "ustring",      "dumpObject", "logObject", "addWarning", "isSubsting", "title",
    "text",         "site",       "uri",       "wikibase",   "message",    "hash",
    "ext",          "html",       "language",  "isutf8",     "byteoffset", "codepoint",
    "gcodepoint",   "toNFC",      "toNFD",     "toNFKC",     "toNFKD",
};

const table_names = names[0..6];
const string_names = names[6..19];
const math_names = names[19..42];
const debug_names = names[42..45];
const mw_names = [_][]const u8{
    "loadData",   "clone",      "getCurrentFrame", "ustring", "dumpObject", "log", "logObject",
    "addWarning", "isSubsting", "title",           "text",    "site",       "uri", "wikibase",
    "message",    "hash",       "ext",             "html",    "language",
};
const ustring_names = [_][]const u8{
    "len",    "sub",  "lower",  "upper",  "reverse",    "rep",       "char",       "byte",  "find",  "match",
    "gmatch", "gsub", "format", "isutf8", "byteoffset", "codepoint", "gcodepoint", "toNFC", "toNFD", "toNFKC",
    "toNFKD",
};

fn namespaceNames(namespace: Namespace) []const []const u8 {
    return switch (namespace) {
        .table => table_names,
        .string => string_names,
        .math => math_names,
        .debug => debug_names,
        .mw => &mw_names,
        .ustring => &ustring_names,
    };
}
pub fn find(field_name: []const u8) ?u32 {
    for (names, 0..) |candidate, field_index| {
        if (std.mem.eql(u8, candidate, field_name)) return @intCast(field_index);
    }
    return null;
}

pub fn encode(field_index: u32) !u32 {
    if (field_index >= names.len) return error.BadStaticField;
    return marker | field_index;
}

pub fn refForName(field_name: []const u8) ?u32 {
    return marker | (find(field_name) orelse return null);
}

pub fn indexFromRef(value: u32) ?u32 {
    if (value & marker == 0) return null;
    const id = value & index_mask;
    return if (id < names.len) id else null;
}

pub fn nameForRef(value: u32) ?[]const u8 {
    return names[indexFromRef(value) orelse return null];
}
pub fn fieldCount(namespace: Namespace) u32 {
    return @intCast(namespaceNames(namespace).len);
}

pub fn slotForRef(namespace: Namespace, value: u32) ?u32 {
    const id = indexFromRef(value) orelse return null;
    return switch (namespace) {
        .table => if (id < 6) id else null,
        .string => if (id >= 6 and id < 19) id - 6 else null,
        .math => if (id >= 19 and id < 42) id - 19 else null,
        .debug => if (id >= 42 and id < 45) id - 42 else null,
        .mw => if (id >= 45 and id <= 49)
            id - 45
        else if (id == 24)
            5
        else if (id >= 50 and id <= 62)
            id - 44
        else
            null,
        .ustring => if (id >= 6 and id < 19)
            id - 6
        else if (id >= 63 and id <= 70)
            id - 50
        else
            null,
    };
}

pub fn slotForName(namespace: Namespace, field_name: []const u8) ?u32 {
    for (namespaceNames(namespace), 0..) |candidate, slot| {
        if (std.mem.eql(u8, candidate, field_name)) return @intCast(slot);
    }
    return null;
}

pub fn nameAt(namespace: Namespace, slot: u32) ?[]const u8 {
    const namespace_names = namespaceNames(namespace);
    if (slot >= namespace_names.len) return null;
    return namespace_names[slot];
}
test "static field refs encode names and namespace-local slots" {
    const insert = refForName("insert") orelse return error.MissingField;
    const find_ref = refForName("find") orelse return error.MissingField;
    try std.testing.expectEqualStrings("insert", nameForRef(insert).?);
    try std.testing.expectEqual(@as(u32, 0), slotForRef(.table, insert).?);
    try std.testing.expectEqual(@as(?u32, null), slotForRef(.string, insert));
    try std.testing.expectEqual(@as(u32, 8), slotForRef(.string, find_ref).?);
    try std.testing.expectEqualStrings("find", nameAt(.string, 8).?);
    try std.testing.expectEqual(@as(?u32, null), indexFromRef(7));
}

test "static field names are unique" {
    for (names, 0..) |lhs, i| {
        for (names[i + 1 ..]) |rhs| try std.testing.expect(!std.mem.eql(u8, lhs, rhs));
    }
}

test "shared field name has one ref across namespaces" {
    const log_ref = refForName("log") orelse return error.MissingField;
    try std.testing.expect(slotForRef(.math, log_ref) != null);
    try std.testing.expect(slotForRef(.mw, log_ref) != null);
    try std.testing.expectEqualStrings("log", nameAt(.math, slotForRef(.math, log_ref).?).?);
    try std.testing.expectEqualStrings("log", nameAt(.mw, slotForRef(.mw, log_ref).?).?);
}

test "numeric namespace mappings match their name layouts" {
    inline for (std.meta.fields(Namespace)) |field| {
        const namespace: Namespace = @enumFromInt(field.value);
        for (namespaceNames(namespace), 0..) |field_name, expected| {
            const ref = refForName(field_name) orelse return error.MissingField;
            try std.testing.expectEqual(@as(u32, @intCast(expected)), slotForRef(namespace, ref).?);
            try std.testing.expectEqualStrings(field_name, nameAt(namespace, @intCast(expected)).?);
        }
    }
}
