const std = @import("std");
const rt = @import("zig_runtime");
const namespace_lib = @import("zig_namespaces.zig");
const host_api = @import("zig_host.zig");
const Value = rt.Value;

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn noOpCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return &.{};
}

fn falseCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return one(.{ .boolean = false });
}

fn notImplementedCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return error.NotImplemented;
}

fn dumpObjectCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const text: []const u8 = if (args.len == 0) "nil" else switch (args[0]) {
        .nil => "nil",
        .boolean => |value| if (value) "true" else "false",
        .number => |value| try rt.numberToString(runtime.allocator, value),
        .string => |value| value,
        .table => "table",
        .function, .native => "function",
    };
    return one(.{ .string = text });
}

fn interwikiMapCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const filter: enum { all, local, nonlocal } = if (args.len == 0 or args[0] == .nil)
        .all
    else if (args[0] != .string)
        return error.StringExpected
    else if (std.mem.eql(u8, args[0].string, "local"))
        .local
    else if (std.mem.eql(u8, args[0].string, "!local"))
        .nonlocal
    else
        return error.InvalidInterwikiFilter;
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    const rows = try (host.site_interwiki_map orelse return error.NotImplemented)(host.ctx);
    const map = try runtime.newTable();
    for (rows) |row| {
        if (filter == .local and !row.is_local) continue;
        if (filter == .nonlocal and row.is_local) continue;
        const entry = try runtime.newTable();
        try entry.rawSet(runtime.allocator, .{ .string = "prefix" }, .{ .string = row.prefix });
        try entry.rawSet(runtime.allocator, .{ .string = "url" }, .{ .string = row.url });
        try entry.rawSet(runtime.allocator, .{ .string = "isProtocolRelative" }, .{ .boolean = row.is_protocol_relative });
        try entry.rawSet(runtime.allocator, .{ .string = "isLocal" }, .{ .boolean = row.is_local });
        try entry.rawSet(runtime.allocator, .{ .string = "isTranscludable" }, .{ .boolean = false });
        try entry.rawSet(runtime.allocator, .{ .string = "isCurrentWiki" }, .{ .boolean = row.is_current_wiki });
        try entry.rawSet(runtime.allocator, .{ .string = "isExtraLanguageLink" }, .{ .boolean = false });
        try map.rawSet(runtime.allocator, .{ .string = row.prefix }, .{ .table = entry });
    }
    return one(.{ .table = map });
}

fn setNative(runtime: *rt.Context, table: *rt.Table, name: []const u8, comptime call: anytype) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(null, call));
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try setNative(runtime, mw, "dumpObject", dumpObjectCall);
    try setNative(runtime, mw, "log", noOpCall);
    try setNative(runtime, mw, "logObject", noOpCall);
    try setNative(runtime, mw, "addWarning", noOpCall);
    try setNative(runtime, mw, "isSubsting", falseCall);

    const site = try runtime.newTable();
    const namespaces = try namespace_lib.makeTable(runtime);
    try site.rawSet(runtime.allocator, .{ .string = "namespaces" }, .{ .table = namespaces });
    try setNative(runtime, site, "interwikiMap", interwikiMapCall);
    try mw.rawSet(runtime.allocator, .{ .string = "site" }, .{ .table = site });

    const wikibase = try runtime.newTable();
    inline for (.{
        "getEntity",
        "getDescription",
        "getLabel",
        "getEntityIdForCurrentPage",
        "getSitelink",
        "getEntityUrl",
        "getBestStatements",
        "getLabelWithLang",
        "getLabelByLang",
        "isValidEntityId",
        "entityExists",
        "sitelink",
    }) |name| try setNative(runtime, wikibase, name, notImplementedCall);
    try mw.rawSet(runtime.allocator, .{ .string = "wikibase" }, .{ .table = wikibase });
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT mw basics expose logging, dumpObject and site namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);

    const dumped = try callField(&runtime, .{ .table = mw }, "dumpObject", &.{.{ .number = 7 }});
    defer rt.freeResults(dumped);
    try std.testing.expectEqualStrings("7", dumped[0].string);
    const logged = try callField(&runtime, .{ .table = mw }, "log", &.{.{ .string = "ignored" }});
    defer rt.freeResults(logged);
    try std.testing.expectEqual(@as(usize, 0), logged.len);
    const substing = try callField(&runtime, .{ .table = mw }, "isSubsting", &.{});
    defer rt.freeResults(substing);
    try std.testing.expect(!substing[0].boolean);

    const wikibase = mw.rawGet(.{ .string = "wikibase" }).?.table;
    try std.testing.expect(wikibase.rawGet(.{ .string = "getEntity" }).? == .native);
    try std.testing.expect(wikibase.rawGet(.{ .string = "getEntityIdForTitle" }) == null);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = wikibase }, "getEntity", &.{.{ .string = "Q1" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();

    const site = mw.rawGet(.{ .string = "site" }).?.table;
    const namespaces = site.rawGet(.{ .string = "namespaces" }).?.table;
    const template = namespaces.rawGet(.{ .number = 10 }).?.table;
    try std.testing.expectEqualStrings("Template", template.rawGet(.{ .string = "name" }).?.string);
    try std.testing.expect(namespaces.rawGet(.{ .string = "Template" }).?.table == template);
    const project = namespaces.rawGet(.{ .number = 4 }).?.table;
    try std.testing.expectEqualStrings("Project", project.rawGet(.{ .string = "canonicalName" }).?.string);
    const aliases = project.rawGet(.{ .string = "aliases" }).?.table;
    try std.testing.expectEqualStrings("WT", aliases.rawGet(.{ .number = 1 }).?.string);
}

const InterwikiProbe = struct {
    const rows = [_]host_api.InterwikiRow{
        .{ .prefix = "local", .url = "//local.example/$1", .is_local = true, .is_current_wiki = true, .is_protocol_relative = true },
        .{ .prefix = "ext", .url = "https://ext.example/$1", .is_local = false, .is_current_wiki = false, .is_protocol_relative = false },
    };
    fn get(_: ?*anyopaque) ![]const host_api.InterwikiRow {
        return &rows;
    }
};

test "AOT mw site interwikiMap uses typed host rows and filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    var host = host_api.Host{ .site_interwiki_map = InterwikiProbe.get };
    host_api.set(&runtime, &host);
    const site = mw.rawGet(.{ .string = "site" }).?.table;

    const all = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{});
    defer rt.freeResults(all);
    const local = all[0].table.rawGet(.{ .string = "local" }).?.table;
    try std.testing.expect(local.rawGet(.{ .string = "isLocal" }).?.boolean);
    try std.testing.expect(local.rawGet(.{ .string = "isCurrentWiki" }).?.boolean);
    try std.testing.expectEqualStrings("//local.example/$1", local.rawGet(.{ .string = "url" }).?.string);

    const local_only = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{.{ .string = "local" }});
    defer rt.freeResults(local_only);
    try std.testing.expect(local_only[0].table.rawGet(.{ .string = "local" }) != null);
    try std.testing.expect(local_only[0].table.rawGet(.{ .string = "ext" }) == null);
    const external_only = try callField(&runtime, .{ .table = site }, "interwikiMap", &.{.{ .string = "!local" }});
    defer rt.freeResults(external_only);
    try std.testing.expect(external_only[0].table.rawGet(.{ .string = "local" }) == null);
    try std.testing.expect(external_only[0].table.rawGet(.{ .string = "ext" }) != null);
}
