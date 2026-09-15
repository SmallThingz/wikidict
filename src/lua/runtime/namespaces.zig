const std = @import("std");
const rt = @import("zig_runtime");

pub const Spec = struct {
    id: i32,
    name: []const u8,
    canonical_name: []const u8,
    has_subpages: bool,
    aliases: []const []const u8 = &.{},
};
const entry_keys = [_]rt.Value{
    .{ .string = "id" },
    .{ .string = "name" },
    .{ .string = "canonicalName" },
    .{ .string = "hasSubpages" },
    .{ .string = "aliases" },
};
const entry_sorted_slots = [_]u32{ 4, 2, 3, 0, 1 };
const entry_shape = rt.Shape{
    .field_keys = &entry_keys,
    .sorted_string_slots = &entry_sorted_slots,
    .field_count = entry_keys.len,
    .open = true,
};

pub const all = [_]Spec{
    .{ .id = -2, .name = "Media", .canonical_name = "Media", .has_subpages = false },
    .{ .id = -1, .name = "Special", .canonical_name = "Special", .has_subpages = false },
    .{ .id = 0, .name = "", .canonical_name = "", .has_subpages = false },
    .{ .id = 1, .name = "Talk", .canonical_name = "Talk", .has_subpages = true },
    .{ .id = 2, .name = "User", .canonical_name = "User", .has_subpages = true },
    .{ .id = 3, .name = "User talk", .canonical_name = "User talk", .has_subpages = true },
    .{ .id = 4, .name = "Wiktionary", .canonical_name = "Project", .has_subpages = true, .aliases = &.{"WT"} },
    .{ .id = 5, .name = "Wiktionary talk", .canonical_name = "Project talk", .has_subpages = true },
    .{ .id = 6, .name = "File", .canonical_name = "File", .has_subpages = false, .aliases = &.{"Image"} },
    .{ .id = 7, .name = "File talk", .canonical_name = "File talk", .has_subpages = true, .aliases = &.{"Image talk"} },
    .{ .id = 8, .name = "MediaWiki", .canonical_name = "MediaWiki", .has_subpages = true },
    .{ .id = 9, .name = "MediaWiki talk", .canonical_name = "MediaWiki talk", .has_subpages = true },
    .{ .id = 10, .name = "Template", .canonical_name = "Template", .has_subpages = true, .aliases = &.{"T"} },
    .{ .id = 11, .name = "Template talk", .canonical_name = "Template talk", .has_subpages = true },
    .{ .id = 12, .name = "Help", .canonical_name = "Help", .has_subpages = true },
    .{ .id = 13, .name = "Help talk", .canonical_name = "Help talk", .has_subpages = true },
    .{ .id = 14, .name = "Category", .canonical_name = "Category", .has_subpages = false, .aliases = &.{"CAT"} },
    .{ .id = 15, .name = "Category talk", .canonical_name = "Category talk", .has_subpages = true },
    .{ .id = 90, .name = "Thread", .canonical_name = "Thread", .has_subpages = false },
    .{ .id = 91, .name = "Thread talk", .canonical_name = "Thread talk", .has_subpages = false },
    .{ .id = 92, .name = "Summary", .canonical_name = "Summary", .has_subpages = false },
    .{ .id = 93, .name = "Summary talk", .canonical_name = "Summary talk", .has_subpages = false },
    .{ .id = 100, .name = "Appendix", .canonical_name = "Appendix", .has_subpages = true, .aliases = &.{"AP"} },
    .{ .id = 101, .name = "Appendix talk", .canonical_name = "Appendix talk", .has_subpages = true },
    .{ .id = 106, .name = "Rhymes", .canonical_name = "Rhymes", .has_subpages = true },
    .{ .id = 107, .name = "Rhymes talk", .canonical_name = "Rhymes talk", .has_subpages = true },
    .{ .id = 108, .name = "Transwiki", .canonical_name = "Transwiki", .has_subpages = true },
    .{ .id = 109, .name = "Transwiki talk", .canonical_name = "Transwiki talk", .has_subpages = true },
    .{ .id = 110, .name = "Thesaurus", .canonical_name = "Thesaurus", .has_subpages = true, .aliases = &.{ "WS", "Wikisaurus" } },
    .{ .id = 111, .name = "Thesaurus talk", .canonical_name = "Thesaurus talk", .has_subpages = true, .aliases = &.{"Wikisaurus talk"} },
    .{ .id = 114, .name = "Citations", .canonical_name = "Citations", .has_subpages = true },
    .{ .id = 115, .name = "Citations talk", .canonical_name = "Citations talk", .has_subpages = true },
    .{ .id = 116, .name = "Sign gloss", .canonical_name = "Sign gloss", .has_subpages = true },
    .{ .id = 117, .name = "Sign gloss talk", .canonical_name = "Sign gloss talk", .has_subpages = true },
    .{ .id = 118, .name = "Reconstruction", .canonical_name = "Reconstruction", .has_subpages = true, .aliases = &.{"RC"} },
    .{ .id = 119, .name = "Reconstruction talk", .canonical_name = "Reconstruction talk", .has_subpages = true },
    .{ .id = 710, .name = "TimedText", .canonical_name = "TimedText", .has_subpages = false },
    .{ .id = 711, .name = "TimedText talk", .canonical_name = "TimedText talk", .has_subpages = false },
    .{ .id = 828, .name = "Module", .canonical_name = "Module", .has_subpages = true, .aliases = &.{"MOD"} },
    .{ .id = 829, .name = "Module talk", .canonical_name = "Module talk", .has_subpages = true },
    .{ .id = 1728, .name = "Event", .canonical_name = "Event", .has_subpages = true },
    .{ .id = 1729, .name = "Event talk", .canonical_name = "Event talk", .has_subpages = true },
    .{ .id = 2600, .name = "Topic", .canonical_name = "Topic", .has_subpages = false },
};

pub fn byId(id: i32) ?Spec {
    for (all) |spec| if (spec.id == id) return spec;
    return null;
}

pub fn byName(name: []const u8) ?Spec {
    if (name.len == 0) return byId(0);
    for (all) |spec| {
        if (std.ascii.eqlIgnoreCase(name, spec.name) or std.ascii.eqlIgnoreCase(name, spec.canonical_name)) return spec;
        for (spec.aliases) |alias| if (std.ascii.eqlIgnoreCase(name, alias)) return spec;
    }
    return null;
}

pub fn ofTitle(title: []const u8) struct { id: i32, name: []const u8, text: []const u8 } {
    if (std.mem.indexOfScalar(u8, title, ':')) |colon| {
        if (byName(title[0..colon])) |spec| return .{ .id = spec.id, .name = spec.name, .text = title[colon + 1 ..] };
    }
    return .{ .id = 0, .name = "", .text = title };
}

pub fn makeTable(runtime: *rt.Context) !*rt.Table {
    // IDs 1..15 are the dense prefix produced by this namespace catalog.
    // Preallocating it and the fallback map removes all construction-time growth.
    const namespaces = try runtime.newArrayTable(16);
    try namespaces.map.ensureTotalCapacity(runtime.allocator, @intCast(all.len * 2));
    for (all) |spec| {
        const value = try runtime.newShapedTable(&entry_shape);
        const aliases = try runtime.newArrayTable(@intCast(spec.aliases.len));
        for (spec.aliases) |alias| try aliases.append(runtime.allocator, .{ .string = alias });
        try value.rawSetSlot(0, .{ .number = @floatFromInt(spec.id) });
        try value.rawSetSlot(1, .{ .string = spec.name });
        try value.rawSetSlot(2, .{ .string = spec.canonical_name });
        try value.rawSetSlot(3, .{ .boolean = spec.has_subpages });
        try value.rawSetSlot(4, .{ .table = aliases });
        try namespaces.rawSet(runtime.allocator, .{ .number = @floatFromInt(spec.id) }, .{ .table = value });
        if (spec.name.len != 0) try namespaces.rawSet(runtime.allocator, .{ .string = spec.name }, .{ .table = value });
    }
    return namespaces;
}

test "Wiktionary namespace lookup preserves canonical names and aliases" {
    try std.testing.expectEqual(@as(i32, 4), byName("WT").?.id);
    try std.testing.expectEqual(@as(i32, 4), byName("Project").?.id);
    try std.testing.expectEqual(@as(i32, 828), byName("MOD").?.id);
    const split = ofTitle("MOD:example/sub");
    try std.testing.expectEqual(@as(i32, 828), split.id);
    try std.testing.expectEqualStrings("Module", split.name);
    try std.testing.expectEqualStrings("example/sub", split.text);
}

test "namespace entry shapes remain open and mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const namespaces = try makeTable(&runtime);
    const template = namespaces.rawGet(.{ .number = 10 }).?.table;
    try template.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "Changed" });
    try std.testing.expectEqualStrings("Changed", template.rawGet(.{ .string = "name" }).?.string);
    try template.rawSet(runtime.allocator, .{ .string = "extra" }, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), template.rawGet(.{ .string = "extra" }).?.number);
    try std.testing.expectEqual(@as(usize, 1), template.map.count());
}
