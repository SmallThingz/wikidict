const std = @import("std");
const rt = @import("zig_runtime");

pub const Spec = struct {
    id: i32,
    name: []const u8,
    canonical_name: []const u8,
    has_subpages: bool,
    is_capitalized: bool = false,
    aliases: []const []const u8 = &.{},
};
const entry_keys = [_]rt.Value{
    .{ .string = "id" },
    .{ .string = "name" },
    .{ .string = "canonicalName" },
    .{ .string = "hasSubpages" },
    .{ .string = "isCapitalized" },
    .{ .string = "aliases" },
    .{ .string = "displayName" },
    .{ .string = "hasGenderDistinction" },
    .{ .string = "isContent" },
    .{ .string = "isIncludable" },
    .{ .string = "isMovable" },
    .{ .string = "isSubject" },
    .{ .string = "isTalk" },
    .{ .string = "defaultContentModel" },
    .{ .string = "subject" },
    .{ .string = "talk" },
    .{ .string = "associated" },
};
const entry_sorted_slots = [_]u32{ 5, 16, 2, 13, 6, 7, 3, 0, 4, 8, 9, 10, 11, 12, 1, 14, 15 };
const entry_shape = rt.Shape{
    .field_keys = &entry_keys,
    .sorted_string_slots = &entry_sorted_slots,
    .field_count = entry_keys.len,
    .open = true,
};

pub const all = [_]Spec{
    .{ .id = -2, .name = "Media", .canonical_name = "Media", .has_subpages = false },
    .{ .id = -1, .name = "Special", .canonical_name = "Special", .has_subpages = false, .is_capitalized = true },
    .{ .id = 0, .name = "", .canonical_name = "", .has_subpages = false },
    .{ .id = 1, .name = "Talk", .canonical_name = "Talk", .has_subpages = true },
    .{ .id = 2, .name = "User", .canonical_name = "User", .has_subpages = true, .is_capitalized = true },
    .{ .id = 3, .name = "User talk", .canonical_name = "User talk", .has_subpages = true, .is_capitalized = true },
    .{ .id = 4, .name = "Wiktionary", .canonical_name = "Project", .has_subpages = true, .aliases = &.{"WT"} },
    .{ .id = 5, .name = "Wiktionary talk", .canonical_name = "Project talk", .has_subpages = true },
    .{ .id = 6, .name = "File", .canonical_name = "File", .has_subpages = false, .aliases = &.{"Image"} },
    .{ .id = 7, .name = "File talk", .canonical_name = "File talk", .has_subpages = true, .aliases = &.{"Image talk"} },
    .{ .id = 8, .name = "MediaWiki", .canonical_name = "MediaWiki", .has_subpages = true, .is_capitalized = true },
    .{ .id = 9, .name = "MediaWiki talk", .canonical_name = "MediaWiki talk", .has_subpages = true, .is_capitalized = true },
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
    .{ .id = 2600, .name = "Topic", .canonical_name = "Topic", .has_subpages = false, .is_capitalized = true },
};

const alias_slot_count: usize = blk: {
    var total: usize = 0;
    for (all) |spec| total += spec.aliases.len;
    break :blk total;
};

pub fn byId(id: i32) ?Spec {
    for (all) |spec| if (spec.id == id) return spec;
    return null;
}

fn nameEqual(raw: []const u8, expected: []const u8) bool {
    if (raw.len != expected.len) return false;
    for (raw, expected) |lhs_raw, rhs_raw| {
        const lhs = if (lhs_raw == '_') ' ' else lhs_raw;
        if (std.ascii.toLower(lhs) != std.ascii.toLower(rhs_raw)) return false;
    }
    return true;
}

pub fn byName(name: []const u8) ?Spec {
    if (name.len == 0) return byId(0);
    for (all) |spec| {
        if (nameEqual(name, spec.name) or nameEqual(name, spec.canonical_name)) return spec;
        for (spec.aliases) |alias| if (nameEqual(name, alias)) return spec;
    }
    return null;
}

pub fn subjectSpec(id: i32) ?Spec {
    const spec = byId(id) orelse return null;
    if (id > 0 and @mod(id, 2) == 1) return byId(id - 1) orelse spec;
    return spec;
}

pub fn talkSpec(id: i32) ?Spec {
    if (id < 0) return null;
    const spec = byId(id) orelse return null;
    if (id == 0) return byId(1);
    if (@mod(id, 2) == 1) return spec;
    return byId(id + 1);
}

pub fn ofTitle(title: []const u8) struct { id: i32, name: []const u8, text: []const u8 } {
    if (std.mem.indexOfScalar(u8, title, ':')) |colon| {
        if (byName(title[0..colon])) |spec| return .{ .id = spec.id, .name = spec.name, .text = title[colon + 1 ..] };
    }
    return .{ .id = 0, .name = "", .text = title };
}

pub fn canonicalizeTitle(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':');
    const spec = if (colon) |at| byName(trimmed[0..at]) else null;
    const canonical_prefix = if (spec) |value| value.name else "";
    const prefix_changed = if (colon) |at| spec != null and !std.mem.eql(u8, trimmed[0..at], canonical_prefix) else false;
    const has_underscore = std.mem.indexOfScalar(u8, trimmed, '_') != null;
    if (!prefix_changed and !has_underscore) return trimmed;

    if (prefix_changed) {
        const at = colon.?;
        const suffix = trimmed[at + 1 ..];
        const out = try a.alloc(u8, canonical_prefix.len + 1 + suffix.len);
        @memcpy(out[0..canonical_prefix.len], canonical_prefix);
        out[canonical_prefix.len] = ':';
        @memcpy(out[canonical_prefix.len + 1 ..], suffix);
        std.mem.replaceScalar(u8, out, '_', ' ');
        return out;
    }

    const out = try a.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

fn one(value: rt.Value) ![]const rt.Value {
    const out = try std.heap.smp_allocator.alloc(rt.Value, 1);
    out[0] = value;
    return out;
}

fn namespaceIndexCall(_: ?*anyopaque, _: *rt.Context, args: []const rt.Value) ![]const rt.Value {
    if (args.len < 2 or args[0] != .table or args[1] != .string) return one(.nil);
    const spec = byName(args[1].string) orelse return one(.nil);
    return one(args[0].table.rawGet(.{ .number = @floatFromInt(spec.id) }) orelse .nil);
}

pub fn makeTable(runtime: *rt.Context) !*rt.Table {
    // IDs 1..15 are the dense prefix produced by this namespace catalog.
    // The namespace objects and their fixed slots have page lifetime, so allocate
    // them in contiguous arena-backed batches instead of ~2 allocations per object.
    const namespaces = try runtime.newArrayTable(16);
    try namespaces.map.ensureTotalCapacity(runtime.allocator, @intCast(all.len));
    const entries = try runtime.allocator.alloc(rt.Table, all.len);
    const entry_slots = try runtime.allocator.alloc(rt.Value, all.len * entry_keys.len);
    const alias_tables = try runtime.allocator.alloc(rt.Table, all.len);
    const alias_slots = try runtime.allocator.alloc(rt.Value, alias_slot_count);
    var alias_offset: usize = 0;
    for (all, 0..) |spec, index| {
        const value = &entries[index];
        const slots = entry_slots[index * entry_keys.len ..][0..entry_keys.len];
        value.* = .{ .shape = &entry_shape, .slots = slots, .owns_slots = false };

        const aliases = &alias_tables[index];
        const initial_aliases = alias_slots[alias_offset..][0..spec.aliases.len];
        alias_offset += spec.aliases.len;
        aliases.* = .{
            .slots = initial_aliases,
            .owns_slots = false,
            .append_index = @intCast(spec.aliases.len + 1),
        };
        for (spec.aliases, 0..) |alias, alias_index| initial_aliases[alias_index] = .{ .string = alias };

        slots[0] = .{ .number = @floatFromInt(spec.id) };
        slots[1] = .{ .string = spec.name };
        slots[2] = .{ .string = spec.canonical_name };
        slots[3] = .{ .boolean = spec.has_subpages };
        slots[4] = .{ .boolean = spec.is_capitalized };
        slots[5] = .{ .table = aliases };
        slots[6] = if (spec.id == 0) .{ .string = "(Main)" } else .nil;
        slots[7] = .{ .boolean = spec.id == 2 or spec.id == 3 };
        slots[8] = .{ .boolean = spec.id == 0 };
        slots[9] = .{ .boolean = true };
        slots[10] = .{ .boolean = spec.id >= 0 and spec.id != 2600 };
        const is_talk = spec.id > 0 and @mod(spec.id, 2) == 1;
        slots[11] = .{ .boolean = !is_talk };
        slots[12] = .{ .boolean = is_talk };
        slots[13] = if (spec.id == 2600) .{ .string = "flow-board" } else .nil;
        slots[14] = .nil;
        slots[15] = .nil;
        slots[16] = .nil;
        try namespaces.rawSet(runtime.allocator, .{ .number = @floatFromInt(spec.id) }, .{ .table = value });
    }

    // Scribunto exposes namespace relationships as object identities, not IDs.
    // Negative virtual namespaces have only a subject (themselves); missing talk
    // namespaces such as Topic's 2601 resolve to nil.
    for (all, 0..) |spec, index| {
        const value = &entries[index];
        if (subjectSpec(spec.id)) |subject|
            value.slots[14] = namespaces.rawGet(.{ .number = @floatFromInt(subject.id) }) orelse .nil;
        if (talkSpec(spec.id)) |talk|
            value.slots[15] = namespaces.rawGet(.{ .number = @floatFromInt(talk.id) }) orelse .nil;
        if (spec.id >= 0) {
            const associated = if (spec.id > 0 and @mod(spec.id, 2) == 1) subjectSpec(spec.id) else talkSpec(spec.id);
            if (associated) |other|
                value.slots[16] = namespaces.rawGet(.{ .number = @floatFromInt(other.id) }) orelse .nil;
        }
    }

    const metatable = try runtime.newTable();
    try metatable.rawSet(runtime.allocator, .{ .string = "__index" }, try runtime.newNative(null, namespaceIndexCall));
    namespaces.metatable = metatable;
    std.debug.assert(alias_offset == alias_slots.len);
    return namespaces;
}

test "Wiktionary namespace lookup preserves canonical names and aliases" {
    try std.testing.expectEqual(@as(i32, 4), byName("WT").?.id);
    try std.testing.expectEqual(@as(i32, 4), byName("Project").?.id);
    try std.testing.expectEqual(@as(i32, 3), byName("user_talk").?.id);
    try std.testing.expectEqual(@as(i32, 828), byName("MOD").?.id);
    try std.testing.expect(byId(2).?.is_capitalized);
    try std.testing.expect(!byId(10).?.is_capitalized);
    try std.testing.expectEqual(@as(i32, 4), subjectSpec(5).?.id);
    try std.testing.expectEqual(@as(i32, 5), talkSpec(4).?.id);
    try std.testing.expectEqual(@as(i32, 1), talkSpec(0).?.id);
    try std.testing.expect(talkSpec(-1) == null);
    try std.testing.expect(talkSpec(2600) == null);
    const split = ofTitle("MOD:example/sub");
    try std.testing.expectEqual(@as(i32, 828), split.id);
    try std.testing.expectEqualStrings("Module", split.name);
    try std.testing.expectEqualStrings("example/sub", split.text);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Wiktionary:foo bar", try canonicalizeTitle(arena.allocator(), "WT:foo_bar"));
    try std.testing.expectEqualStrings("Wiktionary:Foo", try canonicalizeTitle(arena.allocator(), "Project:Foo"));
    try std.testing.expectEqualStrings("NotNs:foo bar", try canonicalizeTitle(arena.allocator(), "NotNs:foo_bar"));
}

test "namespace entry shapes remain open and mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const namespaces = try makeTable(&runtime);
    var namespace_count: usize = 0;
    var namespace_it = namespaces.iterator();
    while (namespace_it.next()) |entry| {
        try std.testing.expect(entry.key_ptr.* == .number);
        namespace_count += 1;
    }
    try std.testing.expectEqual(all.len, namespace_count);
    try std.testing.expect(namespaces.rawGet(.{ .string = "Template" }) == null);
    const template_by_name = try runtime.getIndex(.{ .table = namespaces }, .{ .string = "template" });
    try std.testing.expect(template_by_name == .table);
    try std.testing.expect(template_by_name.table == namespaces.rawGet(.{ .number = 10 }).?.table);
    const user_talk = try runtime.getIndex(.{ .table = namespaces }, .{ .string = "User_talk" });
    try std.testing.expect(user_talk == .table);
    try std.testing.expectEqual(@as(f64, 3), user_talk.table.rawGet(.{ .string = "id" }).?.number);
    try std.testing.expect(user_talk.table.rawGet(.{ .string = "isCapitalized" }).?.boolean);
    const main = namespaces.rawGet(.{ .number = 0 }).?.table;
    const talk = namespaces.rawGet(.{ .number = 1 }).?.table;
    try std.testing.expectEqualStrings("(Main)", main.rawGet(.{ .string = "displayName" }).?.string);
    try std.testing.expect(main.rawGet(.{ .string = "isContent" }).?.boolean);
    try std.testing.expect(main.rawGet(.{ .string = "isSubject" }).?.boolean);
    try std.testing.expect(!main.rawGet(.{ .string = "isTalk" }).?.boolean);
    try std.testing.expect(main.rawGet(.{ .string = "talk" }).?.table == talk);
    try std.testing.expect(main.rawGet(.{ .string = "associated" }).?.table == talk);

    const project = namespaces.rawGet(.{ .number = 4 }).?.table;
    const project_talk = namespaces.rawGet(.{ .number = 5 }).?.table;
    try std.testing.expect(project.rawGet(.{ .string = "subject" }).?.table == project);
    try std.testing.expect(project.rawGet(.{ .string = "talk" }).?.table == project_talk);
    try std.testing.expect(project.rawGet(.{ .string = "associated" }).?.table == project_talk);
    try std.testing.expect(project_talk.rawGet(.{ .string = "subject" }).?.table == project);
    try std.testing.expect(project_talk.rawGet(.{ .string = "talk" }).?.table == project_talk);
    try std.testing.expect(project_talk.rawGet(.{ .string = "associated" }).?.table == project);
    try std.testing.expect(project.rawGet(.{ .string = "isMovable" }).?.boolean);
    try std.testing.expect(project.rawGet(.{ .string = "isIncludable" }).?.boolean);
    try std.testing.expect((project.rawGet(.{ .string = "defaultContentModel" }) orelse .nil) == .nil);

    const user = namespaces.rawGet(.{ .number = 2 }).?.table;
    try std.testing.expect(user.rawGet(.{ .string = "hasGenderDistinction" }).?.boolean);
    try std.testing.expect(user_talk.table.rawGet(.{ .string = "hasGenderDistinction" }).?.boolean);

    const media = namespaces.rawGet(.{ .number = -2 }).?.table;
    try std.testing.expect(media.rawGet(.{ .string = "subject" }).?.table == media);
    try std.testing.expect((media.rawGet(.{ .string = "talk" }) orelse .nil) == .nil);
    try std.testing.expect((media.rawGet(.{ .string = "associated" }) orelse .nil) == .nil);
    try std.testing.expect(!media.rawGet(.{ .string = "isMovable" }).?.boolean);
    try std.testing.expect(media.rawGet(.{ .string = "isSubject" }).?.boolean);

    const topic = namespaces.rawGet(.{ .number = 2600 }).?.table;
    try std.testing.expectEqualStrings("flow-board", topic.rawGet(.{ .string = "defaultContentModel" }).?.string);
    try std.testing.expect(topic.rawGet(.{ .string = "subject" }).?.table == topic);
    try std.testing.expect((topic.rawGet(.{ .string = "talk" }) orelse .nil) == .nil);
    try std.testing.expect((topic.rawGet(.{ .string = "associated" }) orelse .nil) == .nil);
    try std.testing.expect(!topic.rawGet(.{ .string = "isMovable" }).?.boolean);

    const template = namespaces.rawGet(.{ .number = 10 }).?.table;
    try std.testing.expect(!template.rawGet(.{ .string = "hasGenderDistinction" }).?.boolean);
    try std.testing.expect(template.map.count() == 0);
    try template.rawSet(runtime.allocator, .{ .string = "name" }, .{ .string = "Changed" });
    try std.testing.expectEqualStrings("Changed", template.rawGet(.{ .string = "name" }).?.string);
    try template.rawSet(runtime.allocator, .{ .string = "extra" }, .{ .number = 7 });
    try std.testing.expectEqual(@as(f64, 7), template.rawGet(.{ .string = "extra" }).?.number);
    try std.testing.expectEqual(@as(usize, 1), template.map.count());
    const aliases = template.rawGet(.{ .string = "aliases" }).?.table;
    try std.testing.expectEqual(@as(usize, 1), aliases.rawLen());
    try aliases.append(runtime.allocator, .{ .string = "Extra" });
    try std.testing.expectEqual(@as(usize, 2), aliases.rawLen());
    try std.testing.expectEqualStrings("Extra", aliases.rawGet(.{ .number = 2 }).?.string);
}
