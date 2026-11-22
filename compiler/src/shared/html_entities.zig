const std = @import("std");
const comptime_hash_map = @import("comptime_hash_map.zig");
const entity_data = @import("html_entities_data.zig");

pub const Entry = comptime_hash_map.Entry;
pub const ComptimeHashMap = comptime_hash_map.ComptimeHashMap;
pub const AutoContext = comptime_hash_map.AutoContext;
pub const StringContext = comptime_hash_map.StringContext;

pub const NamedEntityEntry = Entry([]const u8, []const u8);

pub const named_entity_entries = entity_data.namedEntityEntries(NamedEntityEntry);
pub const malformed_entity_entries = &[_]NamedEntityEntry{
    .{ .key = "emdash", .value = "—" },
    .{ .key = "endash", .value = "–" },
    .{ .key = "mdsash", .value = "—" },
    .{ .key = "dmash", .value = "—" },
    .{ .key = "squo", .value = "’" },
    .{ .key = "bnsp", .value = "\u{a0}" },
    .{ .key = "nsbp", .value = "\u{a0}" },
    .{ .key = "egravre", .value = "è" },
};

pub const all_entity_entries = named_entity_entries ++ malformed_entity_entries;
pub const NamedEntityMap = ComptimeHashMap([]const u8, []const u8, StringContext, .{}, all_entity_entries);

pub const named_entities = NamedEntityMap.init();

pub fn lookupNamedEntity(entity: []const u8) ?[]const u8 {
    return named_entities.get(entity);
}

pub fn lookupHtmlNamedEntity(entity: []const u8) ?[]const u8 {
    for (malformed_entity_entries) |entry|
        if (std.mem.eql(u8, entity, entry.key)) return null;
    return named_entities.get(entity);
}

test "lookupNamedEntity covers html5 named references" {
    try std.testing.expectEqualStrings("\u{2267}\u{338}", lookupNamedEntity("NotGreaterFullEqual").?);
    try std.testing.expectEqualStrings("\u{2233}", lookupNamedEntity("CounterClockwiseContourIntegral").?);
    try std.testing.expectEqualStrings("\n", lookupNamedEntity("NewLine").?);
    try std.testing.expectEqualStrings("\t", lookupNamedEntity("Tab").?);
}

test "lookupNamedEntity preserves malformed dump aliases" {
    try std.testing.expectEqualStrings("—", lookupNamedEntity("emdash").?);
    try std.testing.expectEqualStrings("\u{a0}", lookupNamedEntity("nsbp").?);
}

test "canonical HTML entity lookup excludes dump typo aliases" {
    try std.testing.expectEqualStrings("©", lookupHtmlNamedEntity("copy").?);
    try std.testing.expectEqualStrings("\u{2267}\u{338}", lookupHtmlNamedEntity("NotGreaterFullEqual").?);
    try std.testing.expect(lookupHtmlNamedEntity("emdash") == null);
    try std.testing.expect(lookupHtmlNamedEntity("nsbp") == null);
}
