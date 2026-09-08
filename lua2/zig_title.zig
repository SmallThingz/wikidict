const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("zig_host.zig");
const Value = rt.Value;

const State = struct {
    metatable: ?*rt.Table = null,
    equals: ?Value = null,
};

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

const NamespaceSpec = struct {
    id: i32,
    name: []const u8,
    canonical_name: []const u8,
    has_subpages: bool,
    aliases: []const []const u8 = &.{},
};
const wiktionary_namespaces = [_]NamespaceSpec{
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
fn namespaceSpecById(id: i32) ?NamespaceSpec {
    for (wiktionary_namespaces) |spec| if (spec.id == id) return spec;
    return null;
}

fn namespaceSpecByName(name: []const u8) ?NamespaceSpec {
    if (name.len == 0) return namespaceSpecById(0);
    for (wiktionary_namespaces) |spec| {
        if (std.ascii.eqlIgnoreCase(name, spec.name) or std.ascii.eqlIgnoreCase(name, spec.canonical_name)) return spec;
        for (spec.aliases) |alias| if (std.ascii.eqlIgnoreCase(name, alias)) return spec;
    }
    return null;
}

fn namespaceOf(title: []const u8) struct { id: i32, name: []const u8, text: []const u8 } {
    if (std.mem.indexOfScalar(u8, title, ':')) |colon| {
        if (namespaceSpecByName(title[0..colon])) |spec|
            return .{ .id = spec.id, .name = spec.name, .text = title[colon + 1 ..] };
    }
    return .{ .id = 0, .name = "", .text = title };
}
fn normalizeName(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '_') == null) return trimmed;
    const out = try a.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, out, '_', ' ');
    return out;
}

fn normalizeFragment(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (raw) |c| {
        const space = c == '_' or std.ascii.isWhitespace(c);
        if (space) {
            if (!in_space) try out.append(a, ' ');
            in_space = true;
        } else {
            try out.append(a, c);
            in_space = false;
        }
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.toOwnedSlice(a);
}
fn compareValues(lhs: Value, rhs: Value) !std.math.Order {
    if (lhs != .table or rhs != .table) return error.TableExpected;
    const li = lhs.table.rawGet(.{ .string = "interwiki" }) orelse return error.InvalidTitle;
    const ri = rhs.table.rawGet(.{ .string = "interwiki" }) orelse return error.InvalidTitle;
    if (li != .string or ri != .string) return error.InvalidTitle;
    const iw = std.mem.order(u8, li.string, ri.string);
    if (iw != .eq) return iw;
    const ln = lhs.table.rawGet(.{ .string = "namespace" }) orelse return error.InvalidTitle;
    const rn = rhs.table.rawGet(.{ .string = "namespace" }) orelse return error.InvalidTitle;
    if (ln != .number or rn != .number) return error.InvalidTitle;
    if (ln.number < rn.number) return .lt;
    if (ln.number > rn.number) return .gt;
    const lt = lhs.table.rawGet(.{ .string = "text" }) orelse return error.InvalidTitle;
    const rt_ = rhs.table.rawGet(.{ .string = "text" }) orelse return error.InvalidTitle;
    if (lt != .string or rt_ != .string) return error.InvalidTitle;
    return std.mem.order(u8, lt.string, rt_.string);
}

fn equalsCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    _ = runtime;
    if (args.len < 2 or args[0] != .table or args[1] != .table) return one(.{ .boolean = false });
    return one(.{ .boolean = (try compareValues(args[0], args[1])) == .eq });
}
fn lessCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    return one(.{ .boolean = (try compareValues(args[0], args[1])) == .lt });
}

fn compareCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2) return error.MissingArgument;
    const order = try compareValues(args[0], args[1]);
    const result: f64 = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return one(.{ .number = result });
}

fn metaIndexCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2 or args[0] != .table or args[1] != .string) return one(.nil);
    const table = args[0].table;
    const fragment = table.rawGet(.{ .string = "__fragment" }) orelse Value{ .string = "" };
    if (std.mem.eql(u8, args[1].string, "fragment")) return one(fragment);
    if (!std.mem.eql(u8, args[1].string, "fullText")) return one(.nil);
    const prefixed = table.rawGet(.{ .string = "prefixedText" }) orelse return one(.nil);
    if (prefixed != .string or fragment != .string) return one(.nil);
    if (fragment.string.len == 0) return one(prefixed);
    return one(.{ .string = try std.fmt.allocPrint(runtime.allocator, "{s}#{s}", .{ prefixed.string, fragment.string }) });
}
fn metaNewIndexCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 3 or args[0] != .table) return error.TableExpected;
    if (args[1] == .string and std.mem.eql(u8, args[1].string, "fragment")) {
        if (args[2] != .string) return error.StringExpected;
        const normalized = try normalizeFragment(runtime.allocator, args[2].string);
        try args[0].table.rawSet(runtime.allocator, .{ .string = "__fragment" }, .{ .string = normalized });
        return &.{};
    }
    try args[0].table.rawSet(runtime.allocator, args[1], args[2]);
    return &.{};
}

fn ensureMetatable(runtime: *rt.Context, state: *State) !*rt.Table {
    if (state.metatable) |table| return table;
    const mt = try runtime.newTable();
    const eq = try runtime.newNative(null, equalsCall);
    const lt = try runtime.newNative(null, lessCall);
    try mt.rawSet(runtime.allocator, .{ .string = "__eq" }, eq);
    try mt.rawSet(runtime.allocator, .{ .string = "__lt" }, lt);
    try mt.rawSet(runtime.allocator, .{ .string = "__index" }, try runtime.newNative(null, metaIndexCall));
    try mt.rawSet(runtime.allocator, .{ .string = "__newindex" }, try runtime.newNative(null, metaNewIndexCall));
    state.metatable = mt;
    state.equals = eq;
    return mt;
}
fn pageExists(runtime: *rt.Context, title: []const u8) !bool {
    if (host_api.get(runtime)) |host| if (host.page_exists) |exists|
        return exists(host.ctx, title);
    if (namespaceOf(title).id == 828) {
        _ = runtime.resolveModule(title) catch return false;
        return true;
    }
    return false;
}

const TitleCtx = struct { title: []const u8 };

fn getContentCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *TitleCtx = @ptrCast(@alignCast(raw orelse return error.MissingTitleContext));
    const host = host_api.get(runtime) orelse return one(.nil);
    const provider = host.page_content orelse return one(.nil);
    if (try provider(host.ctx, runtime.allocator, ctx.title)) |source| return one(.{ .string = source });
    return one(.nil);
}

fn makeTitleValue(runtime: *rt.Context, state: *State, raw_title: []const u8) !Value {
    const title = try runtime.allocator.dupe(u8, raw_title);
    const table = try runtime.newNativeNamespace(.title_value);
    const hash = std.mem.indexOfScalar(u8, title, '#');
    const base_title = if (hash) |pos| title[0..pos] else title;
    const fragment_raw = if (hash) |pos| title[pos + 1 ..] else "";
    const fragment = try normalizeFragment(runtime.allocator, fragment_raw);
    const ns = namespaceOf(base_title);
    const slash = std.mem.lastIndexOfScalar(u8, ns.text, '/');
    const first_slash = std.mem.indexOfScalar(u8, ns.text, '/');
    try table.rawSet(runtime.allocator, .{ .string = "text" }, .{ .string = ns.text });
    try table.rawSet(runtime.allocator, .{ .string = "prefixedText" }, .{ .string = base_title });
    try table.rawSet(runtime.allocator, .{ .string = "__fragment" }, .{ .string = fragment });
    try table.rawSet(runtime.allocator, .{ .string = "namespace" }, .{ .number = @floatFromInt(ns.id) });
    try table.rawSet(runtime.allocator, .{ .string = "nsText" }, .{ .string = ns.name });
    try table.rawSet(runtime.allocator, .{ .string = "subpageText" }, .{ .string = if (slash) |pos| ns.text[pos + 1 ..] else ns.text });
    try table.rawSet(runtime.allocator, .{ .string = "baseText" }, .{ .string = if (slash) |pos| ns.text[0..pos] else ns.text });
    try table.rawSet(runtime.allocator, .{ .string = "rootText" }, .{ .string = if (first_slash) |pos| ns.text[0..pos] else ns.text });
    try table.rawSet(runtime.allocator, .{ .string = "isSubpage" }, .{ .boolean = slash != null });
    try table.rawSet(runtime.allocator, .{ .string = "interwiki" }, .{ .string = "" });
    try table.rawSet(runtime.allocator, .{ .string = "exists" }, .{ .boolean = try pageExists(runtime, base_title) });
    table.metatable = try ensureMetatable(runtime, state);
    const ctx = try runtime.allocator.create(TitleCtx);
    ctx.* = .{ .title = base_title };
    try table.rawSet(runtime.allocator, .{ .string = "getContent" }, try runtime.newNative(ctx, getContentCall));
    return .{ .table = table };
}
fn titleWithNamespace(a: std.mem.Allocator, text_raw: []const u8, namespace: ?Value) !?[]const u8 {
    const text = try normalizeName(a, text_raw);
    if (text.len == 0) return null;
    if (namespace == null or namespace.? == .nil) return text;
    const spec = switch (namespace.?) {
        .number => |number| namespaceSpecById(@intFromFloat(@trunc(number))),
        .string => |name| namespaceSpecByName(name),
        else => null,
    } orelse return null;
    if (spec.id == 0) return text;
    return @as(?[]const u8, try std.fmt.allocPrint(a, "{s}:{s}", .{ spec.name, text }));
}

fn newCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    if (args.len == 0 or args[0] != .string) return one(.nil);
    const title = try titleWithNamespace(runtime.allocator, args[0].string, if (args.len > 1) args[1] else null) orelse return one(.nil);
    return one(try makeTitleValue(runtime, state, title));
}

fn makeCall(raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    if (args.len < 2 or args[1] != .string) return one(.nil);
    const title = try titleWithNamespace(runtime.allocator, args[1].string, args[0]) orelse return one(.nil);
    return one(try makeTitleValue(runtime, state, title));
}
fn currentCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const state: *State = @ptrCast(@alignCast(raw orelse return error.MissingTitleState));
    const host = host_api.get(runtime) orelse return error.MissingScribuntoHost;
    if (host.current_title.len == 0) return error.MissingCurrentTitle;
    return one(try makeTitleValue(runtime, state, host.current_title));
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    const state = try runtime.allocator.create(State);
    state.* = .{};
    _ = try ensureMetatable(runtime, state);
    const title = try runtime.newNativeNamespace(.title);
    try title.rawSet(runtime.allocator, .{ .string = "equals" }, state.equals.?);
    try title.rawSet(runtime.allocator, .{ .string = "compare" }, try runtime.newNative(null, compareCall));
    try title.rawSet(runtime.allocator, .{ .string = "new" }, try runtime.newNative(state, newCall));
    try title.rawSet(runtime.allocator, .{ .string = "makeTitle" }, try runtime.newNative(state, makeCall));
    try title.rawSet(runtime.allocator, .{ .string = "getCurrentTitle" }, try runtime.newNative(state, currentCall));
    try mw.rawSet(runtime.allocator, .{ .string = "title" }, .{ .table = title });
}

fn testPageExists(_: ?*anyopaque, title: []const u8) !bool {
    return std.mem.eql(u8, title, "Template:Foo/Sub");
}

fn testPageContent(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
    if (!std.mem.eql(u8, title, "Template:Foo/Sub")) return null;
    return try a.dupe(u8, "template body");
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT title exposes namespace fragment and subpage semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .current_title = "Template:Foo/Sub", .page_exists = testPageExists, .page_content = testPageContent };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    try install(&runtime, mw);
    const title_lib = mw.rawGet(.{ .string = "title" }).?.table;
    const made = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Template:Foo/Sub# frag_ment" }});
    defer rt.freeResults(made);
    const title = made[0];
    try std.testing.expectEqualStrings("Foo/Sub", (try runtime.getIndex(title, .{ .string = "text" })).string);
    try std.testing.expectEqualStrings("Template", (try runtime.getIndex(title, .{ .string = "nsText" })).string);
    try std.testing.expectEqual(@as(f64, 10), (try runtime.getIndex(title, .{ .string = "namespace" })).number);
    try std.testing.expectEqualStrings("Sub", (try runtime.getIndex(title, .{ .string = "subpageText" })).string);
    try std.testing.expectEqualStrings("Foo", (try runtime.getIndex(title, .{ .string = "baseText" })).string);
    try std.testing.expect((try runtime.getIndex(title, .{ .string = "isSubpage" })).boolean);
    try std.testing.expect((try runtime.getIndex(title, .{ .string = "exists" })).boolean);
    try std.testing.expectEqualStrings(" frag ment", (try runtime.getIndex(title, .{ .string = "fragment" })).string);
    try std.testing.expectEqualStrings("Template:Foo/Sub# frag ment", (try runtime.getIndex(title, .{ .string = "fullText" })).string);

    const content = try callField(&runtime, title, "getContent", &.{title});
    defer rt.freeResults(content);
    try std.testing.expectEqualStrings("template body", content[0].string);
    try runtime.setIndex(title, .{ .string = "fragment" }, .{ .string = " next_part " });
    try std.testing.expectEqualStrings(" next part", (try runtime.getIndex(title, .{ .string = "fragment" })).string);
}

test "AOT title constructors and current title use the live host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .current_title = "Module:Current/Sub" };
    host_api.set(&runtime, &host);
    const mw = try runtime.newTable();
    try install(&runtime, mw);
    const title_lib = mw.rawGet(.{ .string = "title" }).?.table;

    const current = try callField(&runtime, .{ .table = title_lib }, "getCurrentTitle", &.{});
    defer rt.freeResults(current);
    try std.testing.expectEqualStrings("Current/Sub", (try runtime.getIndex(current[0], .{ .string = "text" })).string);
    try std.testing.expectEqual(@as(f64, 828), (try runtime.getIndex(current[0], .{ .string = "namespace" })).number);

    const made = try callField(&runtime, .{ .table = title_lib }, "makeTitle", &.{ .{ .number = 10 }, .{ .string = "Thing" } });
    defer rt.freeResults(made);
    const made2 = try callField(&runtime, .{ .table = title_lib }, "new", &.{.{ .string = "Template:Thing" }});
    defer rt.freeResults(made2);
    try std.testing.expectEqualStrings("Template:Thing", (try runtime.getIndex(made[0], .{ .string = "prefixedText" })).string);
    const equals = title_lib.rawGet(.{ .string = "equals" }).?;
    const same = try runtime.callValue(equals, &.{ made[0], made2[0] });
    defer rt.freeResults(same);
    try std.testing.expect(same[0].boolean);

    host.current_title = "Appendix:Later";
    const later = try callField(&runtime, .{ .table = title_lib }, "getCurrentTitle", &.{});
    defer rt.freeResults(later);
    try std.testing.expectEqual(@as(f64, 100), (try runtime.getIndex(later[0], .{ .string = "namespace" })).number);
    try std.testing.expectEqualStrings("Later", (try runtime.getIndex(later[0], .{ .string = "text" })).string);
}
