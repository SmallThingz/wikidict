const std = @import("std");
const rt = @import("zig_runtime");

pub const Spec = rt.namespace_registry.Spec;
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
    .keys = .{ .boxed = &entry_keys },
    .sorted_string_slots = &entry_sorted_slots,
    .field_count = entry_keys.len,
    .open = true,
};

pub fn byId(runtime: *const rt.Context, id: i32) ?Spec {
    return (runtime.namespace_catalog orelse return null).byId(id);
}
pub fn byName(runtime: *const rt.Context, name: []const u8) ?Spec {
    return (runtime.namespace_catalog orelse return null).byName(name);
}
pub fn subjectSpec(runtime: *const rt.Context, id: i32) ?Spec {
    return (runtime.namespace_catalog orelse return null).subjectSpec(id);
}
pub fn talkSpec(runtime: *const rt.Context, id: i32) ?Spec {
    return (runtime.namespace_catalog orelse return null).talkSpec(id);
}
pub fn ofTitle(runtime: *const rt.Context, title: []const u8) struct { id: i32, name: []const u8, text: []const u8 } {
    const registry = runtime.namespace_catalog orelse @panic("missing edition namespace registry");
    const result = registry.ofTitle(title);
    return .{ .id = result.id, .name = result.name, .text = result.text };
}
pub fn canonicalizeTitle(a: std.mem.Allocator, runtime: *const rt.Context, raw: []const u8) ![]const u8 {
    const registry = runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
    return registry.normalizeTitle(a, raw, 0, .any);
}

fn one(value: rt.Value) ![]const rt.Value {
    const out = try std.heap.smp_allocator.alloc(rt.Value, 1);
    out[0] = value;
    return out;
}

fn namespaceIndexCall(_: ?*anyopaque, runtime: *rt.Context, args: []const rt.Value) ![]const rt.Value {
    if (args.len < 2 or args[0] != .table or args[1] != .string) return one(.nil);
    const spec = byName(runtime, args[1].string) orelse return one(.nil);
    return one(args[0].table.rawGet(.{ .number = @floatFromInt(spec.id) }) orelse .nil);
}

pub fn makeTable(runtime: *rt.Context) !*rt.Table {
    const registry = runtime.namespace_catalog orelse return error.NamespaceRegistryRequired;
    const all = registry.entries;
    var alias_slot_count: usize = 0;
    for (all) |spec| alias_slot_count += spec.aliases.len;
    // IDs 1..15 are the dense prefix produced by this namespace catalog.
    // The namespace objects and their fixed slots have page lifetime, so allocate
    // them in contiguous arena-backed batches instead of ~2 allocations per object.
    const namespaces = try runtime.newNativeNamespace(.namespace_map);
    try namespaces.map.ensureTotalCapacity(runtime.allocator, @intCast(all.len));
    const entries = try runtime.allocator.alloc(rt.Table, all.len);
    const entry_slots = try runtime.allocator.alloc(rt.Value, all.len * entry_keys.len);
    const alias_tables = try runtime.allocator.alloc(rt.Table, all.len);
    const alias_slots = try runtime.allocator.alloc(rt.Value, alias_slot_count);
    var alias_offset: usize = 0;
    for (all, 0..) |spec, index| {
        const value = &entries[index];
        const slots = entry_slots[index * entry_keys.len ..][0..entry_keys.len];
        value.* = .{ .native_namespace = .namespace_value, .slots = slots, .owns_slots = false };

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
        slots[8] = .{ .boolean = spec.is_content };
        slots[9] = .{ .boolean = spec.is_includable };
        slots[10] = .{ .boolean = spec.id >= 0 and spec.id != 2600 };
        const is_talk = spec.id > 0 and @mod(spec.id, 2) == 1;
        slots[11] = .{ .boolean = !is_talk };
        slots[12] = .{ .boolean = is_talk };
        slots[13] = if (spec.default_content_model.len != 0) .{ .string = spec.default_content_model } else .nil;
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
        if (subjectSpec(runtime, spec.id)) |subject|
            value.slots[14] = namespaces.rawGet(.{ .number = @floatFromInt(subject.id) }) orelse .nil;
        if (talkSpec(runtime, spec.id)) |talk|
            value.slots[15] = namespaces.rawGet(.{ .number = @floatFromInt(talk.id) }) orelse .nil;
        if (spec.id >= 0) {
            const associated = if (spec.id > 0 and @mod(spec.id, 2) == 1) subjectSpec(runtime, spec.id) else talkSpec(runtime, spec.id);
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
    var runtime = try rt.Context.init(std.testing.allocator, 0);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(i32, 4), byName(&runtime, "WT").?.id);
    try std.testing.expectEqual(@as(i32, 4), byName(&runtime, "Project").?.id);
    try std.testing.expectEqual(@as(i32, 3), byName(&runtime, "user_talk").?.id);
    try std.testing.expectEqual(@as(i32, 828), byName(&runtime, "MOD").?.id);
    try std.testing.expect(byId(&runtime, 2).?.is_capitalized);
    try std.testing.expect(!byId(&runtime, 10).?.is_capitalized);
    try std.testing.expectEqual(@as(i32, 4), subjectSpec(&runtime, 5).?.id);
    try std.testing.expectEqual(@as(i32, 5), talkSpec(&runtime, 4).?.id);
    try std.testing.expectEqual(@as(i32, 1), talkSpec(&runtime, 0).?.id);
    try std.testing.expect(talkSpec(&runtime, -1) == null);
    try std.testing.expect(talkSpec(&runtime, 2600) == null);
    const split = ofTitle(&runtime, "MOD:example/sub");
    try std.testing.expectEqual(@as(i32, 828), split.id);
    try std.testing.expectEqualStrings("Module", split.name);
    try std.testing.expectEqualStrings("example/sub", split.text);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Wiktionary:foo bar", try canonicalizeTitle(arena.allocator(), &runtime, "WT:foo_bar"));
    try std.testing.expectEqualStrings("Wiktionary:Foo", try canonicalizeTitle(arena.allocator(), &runtime, "Project:Foo"));
    try std.testing.expectEqualStrings("NotNs:foo bar", try canonicalizeTitle(arena.allocator(), &runtime, "NotNs:foo_bar"));
    try std.testing.expectEqualStrings("Template:RQ:William Burroughs Soft Machine", try canonicalizeTitle(arena.allocator(), &runtime, "  Template:RQ:William  Burroughs___Soft Machine  "));
    try std.testing.expectEqualStrings("Template:Foo bar", try canonicalizeTitle(arena.allocator(), &runtime, "Template :  Foo__bar"));
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
    try std.testing.expectEqual(runtime.namespace_catalog.?.entries.len, namespace_count);
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

test "compiled namespace fields stay edition local across simultaneous contexts" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var french = try rt.namespace_registry.Registry.init(a, rt.namespace_registry.french_test_fixture);
    defer french.deinit();
    var en = try rt.Context.init(arena.allocator(), 0);
    defer en.deinit();
    var fr = try rt.Context.init(arena.allocator(), 0);
    defer fr.deinit();
    fr.namespace_catalog = &french;
    const en_table = try makeTable(&en);
    const fr_table = try makeTable(&fr);
    const en_rhymes = try en.getKnownNativeField(.{ .table = en_table }, .namespace_map, 0, "Rhymes");
    const fr_rhymes = try fr.getKnownNativeField(.{ .table = fr_table }, .namespace_map, 0, "Rhymes");
    try std.testing.expect(en_rhymes == .table);
    try std.testing.expect(fr_rhymes == .nil);
    const thesaurus = try fr.getIndex(.{ .table = fr_table }, .{ .string = "THÉSAURUS" });
    try std.testing.expectEqual(@as(f64, 106), thesaurus.table.rawGet(.{ .string = "id" }).?.number);
    try std.testing.expectEqualStrings("Thésaurus", thesaurus.table.rawGet(.{ .string = "name" }).?.string);
    const module = fr_table.rawGet(.{ .number = 828 }).?.table;
    try std.testing.expect(module.rawGet(.{ .string = "defaultContentModel" }) == null or module.rawGet(.{ .string = "defaultContentModel" }).? == .nil);
}
