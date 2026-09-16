const std = @import("std");
const rt = @import("zig_runtime");
const namespace_lib = @import("namespaces.zig");
const host_api = @import("host.zig");
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
        .callable => "function",
    };
    return one(.{ .string = text });
}

const MessageCtx = struct {
    key: ?[]const u8 = null,
    raw_message: ?[]const u8 = null,
    params: std.ArrayList(Value) = .empty,
};

fn messageTitleAlloc(a: std.mem.Allocator, key_raw: []const u8) ![]const u8 {
    const key = std.mem.trim(u8, key_raw, " \t\r\n");
    const prefix = "MediaWiki:";
    const out = try a.alloc(u8, prefix.len + key.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], key);
    std.mem.replaceScalar(u8, out[prefix.len..], '_', ' ');
    if (key.len != 0 and std.ascii.isLower(out[prefix.len])) out[prefix.len] = std.ascii.toUpper(out[prefix.len]);
    return out;
}

fn messageSource(runtime: *rt.Context, ctx: *const MessageCtx) !?[]const u8 {
    if (ctx.raw_message) |source| return source;
    const key = ctx.key orelse return error.MissingMessageKey;
    const host = host_api.get(runtime) orelse return error.NotImplemented;
    const get = host.page_content orelse return error.NotImplemented;
    return get(host.ctx, runtime.allocator, try messageTitleAlloc(runtime.allocator, key));
}

fn messageParamString(runtime: *rt.Context, value: Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .number => |number| try rt.numberToString(runtime.allocator, number),
        .table => blk: {
            const method = runtime.metamethod(value, "__tostring") orelse return error.MessageParamExpected;
            const result = try runtime.callValue(method, &.{value});
            defer rt.freeResults(result);
            if (result.len == 0 or result[0] != .string) return error.StringExpected;
            break :blk result[0].string;
        },
        else => return error.MessageParamExpected,
    };
}

fn appendMessageParams(runtime: *rt.Context, ctx: *MessageCtx, values: []const Value) !void {
    for (values) |value| {
        const stored = if (value == .table)
            Value{ .string = try messageParamString(runtime, value) }
        else switch (value) {
            .string, .number => value,
            else => return error.MessageParamExpected,
        };
        try ctx.params.append(runtime.allocator, stored);
    }
}

fn substituteMessageParams(runtime: *rt.Context, source: []const u8, params: []const Value) ![]const u8 {
    if (params.len == 0 or std.mem.indexOfScalar(u8, source, '$') == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var remaining = source;
    var pos: usize = 0;
    while (pos < remaining.len) {
        if (remaining[pos] == '$' and pos + 1 < remaining.len and std.ascii.isDigit(remaining[pos + 1])) {
            var end = pos + 1;
            var index: usize = 0;
            while (end < remaining.len and std.ascii.isDigit(remaining[end])) : (end += 1) {
                index = std.math.add(usize, try std.math.mul(usize, index, 10), @as(usize, remaining[end] - '0')) catch return error.MessageParameterIndexOverflow;
            }
            if (index != 0 and index <= params.len) {
                try out.appendSlice(runtime.allocator, remaining[0..pos]);
                try out.appendSlice(runtime.allocator, try messageParamString(runtime, params[index - 1]));
                remaining = remaining[end..];
                pos = 0;
                continue;
            }
        }
        pos += 1;
    }
    if (out.items.len == 0) return source;
    try out.appendSlice(runtime.allocator, remaining);
    return out.toOwnedSlice(runtime.allocator);
}

fn messagePlainCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *MessageCtx = @ptrCast(@alignCast(raw orelse return error.MissingMessageContext));
    const source = (try messageSource(runtime, ctx)) orelse
        return one(.{ .string = try std.fmt.allocPrint(runtime.allocator, "⧼{s}⧽", .{ctx.key orelse ""}) });
    return one(.{ .string = try substituteMessageParams(runtime, source, ctx.params.items) });
}

fn messageExistsCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *MessageCtx = @ptrCast(@alignCast(raw orelse return error.MissingMessageContext));
    return one(.{ .boolean = (try messageSource(runtime, ctx)) != null });
}

fn messageIsBlankCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *MessageCtx = @ptrCast(@alignCast(raw orelse return error.MissingMessageContext));
    const source = try messageSource(runtime, ctx);
    return one(.{ .boolean = source == null or source.?.len == 0 });
}

fn messageIsDisabledCall(raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *MessageCtx = @ptrCast(@alignCast(raw orelse return error.MissingMessageContext));
    const source = try messageSource(runtime, ctx);
    return one(.{ .boolean = source == null or source.?.len == 0 or std.mem.eql(u8, source.?, "-") });
}

fn makeMessageObject(runtime: *rt.Context, ctx: *MessageCtx) ![]const Value {
    const object = try runtime.newTable();
    const plain = try runtime.newNative(ctx, messagePlainCall);
    try object.rawSet(runtime.allocator, .{ .string = "plain" }, plain);
    try object.rawSet(runtime.allocator, .{ .string = "exists" }, try runtime.newNative(ctx, messageExistsCall));
    try object.rawSet(runtime.allocator, .{ .string = "isBlank" }, try runtime.newNative(ctx, messageIsBlankCall));
    try object.rawSet(runtime.allocator, .{ .string = "isDisabled" }, try runtime.newNative(ctx, messageIsDisabledCall));
    inline for (.{ "params", "rawParams", "numParams", "inLanguage", "useDatabase" }) |name|
        try setNative(runtime, object, name, notImplementedCall);
    const mt = try runtime.newTable();
    try mt.rawSet(runtime.allocator, .{ .string = "__tostring" }, plain);
    object.metatable = mt;
    return one(.{ .table = object });
}

fn messageNewCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const ctx = try runtime.allocator.create(MessageCtx);
    ctx.* = .{ .key = try runtime.allocator.dupe(u8, args[0].string) };
    try appendMessageParams(runtime, ctx, args[1..]);
    return makeMessageObject(runtime, ctx);
}

fn messageNewRawCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const ctx = try runtime.allocator.create(MessageCtx);
    ctx.* = .{ .raw_message = try runtime.allocator.dupe(u8, args[0].string) };
    try appendMessageParams(runtime, ctx, args[1..]);
    return makeMessageObject(runtime, ctx);
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

fn setMwNative(runtime: *rt.Context, mw: *rt.Table, comptime name: []const u8, comptime call: anytype) !void {
    try mw.rawSetNativeField(.mw, name, try runtime.newNative(null, call));
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try setMwNative(runtime, mw, "dumpObject", dumpObjectCall);
    try setMwNative(runtime, mw, "log", noOpCall);
    try setMwNative(runtime, mw, "logObject", noOpCall);
    try setMwNative(runtime, mw, "addWarning", noOpCall);
    try setMwNative(runtime, mw, "isSubsting", falseCall);

    const site = try runtime.newTable();
    const namespaces = try namespace_lib.makeTable(runtime);
    try site.rawSet(runtime.allocator, .{ .string = "namespaces" }, .{ .table = namespaces });
    const stats = try runtime.newTable();
    try setNative(runtime, stats, "pagesInCategory", notImplementedCall);
    try site.rawSet(runtime.allocator, .{ .string = "stats" }, .{ .table = stats });
    try setNative(runtime, site, "interwikiMap", interwikiMapCall);
    try mw.rawSetNativeField(.mw, "site", .{ .table = site });

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
    try mw.rawSetNativeField(.mw, "wikibase", .{ .table = wikibase });

    const message = try runtime.newTable();
    try setNative(runtime, message, "new", messageNewCall);
    try setNative(runtime, message, "newRawMessage", messageNewRawCall);
    inline for (.{
        "newFallbackSequence",
        "rawParam",
        "numParam",
        "getDefaultLanguage",
    }) |name| try setNative(runtime, message, name, notImplementedCall);
    try mw.rawSetNativeField(.mw, "message", .{ .table = message });
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
    try std.testing.expect(wikibase.rawGet(.{ .string = "getEntity" }).? == .callable);
    try std.testing.expect(wikibase.rawGet(.{ .string = "getEntityIdForTitle" }) == null);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = wikibase }, "getEntity", &.{.{ .string = "Q1" }}));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();

    const message = mw.rawGet(.{ .string = "message" }).?.table;
    inline for (.{ "new", "newFallbackSequence", "newRawMessage", "rawParam", "numParam", "getDefaultLanguage" }) |name| {
        try std.testing.expect(message.rawGet(.{ .string = name }).? == .callable);
    }
    const message_object = try callField(&runtime, .{ .table = message }, "new", &.{.{ .string = "mainpage" }});
    defer rt.freeResults(message_object);
    try std.testing.expect(message_object[0] == .table);
    inline for (.{ "plain", "exists", "isBlank", "isDisabled", "params", "rawParams", "numParams", "inLanguage", "useDatabase" }) |name|
        try std.testing.expect(message_object[0].table.rawGet(.{ .string = name }).? == .callable);

    const site = mw.rawGet(.{ .string = "site" }).?.table;
    const namespaces = site.rawGet(.{ .string = "namespaces" }).?.table;
    const template = namespaces.rawGet(.{ .number = 10 }).?.table;
    try std.testing.expectEqualStrings("Template", template.rawGet(.{ .string = "name" }).?.string);
    try std.testing.expect(namespaces.rawGet(.{ .string = "Template" }).?.table == template);
    const project = namespaces.rawGet(.{ .number = 4 }).?.table;
    try std.testing.expectEqualStrings("Project", project.rawGet(.{ .string = "canonicalName" }).?.string);
    const aliases = project.rawGet(.{ .string = "aliases" }).?.table;
    try std.testing.expectEqualStrings("WT", aliases.rawGet(.{ .number = 1 }).?.string);
    const stats = site.rawGet(.{ .string = "stats" }).?.table;
    try std.testing.expect(stats.rawGet(.{ .string = "pagesInCategory" }).? == .callable);
    try std.testing.expectError(error.AotCallFailed, callField(&runtime, .{ .table = stats }, "pagesInCategory", &.{ .{ .string = "English nouns" }, .{ .string = "pages" } }));
    try std.testing.expectEqualStrings("NotImplemented", runtime.aotErrorName().?);
    runtime.clearAotErrorName();
}

const MessageProbe = struct {
    fn pageContent(_: ?*anyopaque, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const source = if (std.mem.eql(u8, title, "MediaWiki:Mainpage"))
            "{{ns:Project}}:Main Page"
        else if (std.mem.eql(u8, title, "MediaWiki:Disabled"))
            "-"
        else
            return null;
        return try a.dupe(u8, source);
    }
};

test "AOT mw message reads dump-backed interface messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .page_content = MessageProbe.pageContent };
    host_api.set(&runtime, &host);
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);
    const message = mw.rawGet(.{ .string = "message" }).?.table;

    const main = try callField(&runtime, .{ .table = message }, "new", &.{.{ .string = "mainpage" }});
    defer rt.freeResults(main);
    const plain = try callField(&runtime, main[0], "plain", &.{main[0]});
    defer rt.freeResults(plain);
    try std.testing.expectEqualStrings("{{ns:Project}}:Main Page", plain[0].string);
    const exists = try callField(&runtime, main[0], "exists", &.{main[0]});
    defer rt.freeResults(exists);
    try std.testing.expect(exists[0].boolean);
    const blank = try callField(&runtime, main[0], "isBlank", &.{main[0]});
    defer rt.freeResults(blank);
    try std.testing.expect(!blank[0].boolean);
    const disabled = try callField(&runtime, main[0], "isDisabled", &.{main[0]});
    defer rt.freeResults(disabled);
    try std.testing.expect(!disabled[0].boolean);

    const missing = try callField(&runtime, .{ .table = message }, "new", &.{.{ .string = "missing_key" }});
    defer rt.freeResults(missing);
    const missing_plain = try callField(&runtime, missing[0], "plain", &.{missing[0]});
    defer rt.freeResults(missing_plain);
    try std.testing.expectEqualStrings("⧼missing_key⧽", missing_plain[0].string);
    const missing_exists = try callField(&runtime, missing[0], "exists", &.{missing[0]});
    defer rt.freeResults(missing_exists);
    try std.testing.expect(!missing_exists[0].boolean);
    const missing_blank = try callField(&runtime, missing[0], "isBlank", &.{missing[0]});
    defer rt.freeResults(missing_blank);
    try std.testing.expect(missing_blank[0].boolean);
    const missing_disabled = try callField(&runtime, missing[0], "isDisabled", &.{missing[0]});
    defer rt.freeResults(missing_disabled);
    try std.testing.expect(missing_disabled[0].boolean);

    const disabled_message = try callField(&runtime, .{ .table = message }, "new", &.{.{ .string = "disabled" }});
    defer rt.freeResults(disabled_message);
    const is_disabled = try callField(&runtime, disabled_message[0], "isDisabled", &.{disabled_message[0]});
    defer rt.freeResults(is_disabled);
    try std.testing.expect(is_disabled[0].boolean);

    const raw_message = try callField(&runtime, .{ .table = message }, "newRawMessage", &.{ .{ .string = "($1 $2 $3)" }, .{ .string = "foo" }, .{ .number = 123456 }, main[0] });
    defer rt.freeResults(raw_message);
    const raw_plain = try callField(&runtime, raw_message[0], "plain", &.{raw_message[0]});
    defer rt.freeResults(raw_plain);
    try std.testing.expectEqualStrings("(foo 123456 {{ns:Project}}:Main Page)", raw_plain[0].string);

    const parameterized = try callField(&runtime, .{ .table = message }, "new", &.{ .{ .string = "mainpage" }, .{ .string = "unused" } });
    defer rt.freeResults(parameterized);
    const parameterized_plain = try callField(&runtime, parameterized[0], "plain", &.{parameterized[0]});
    defer rt.freeResults(parameterized_plain);
    try std.testing.expectEqualStrings("{{ns:Project}}:Main Page", parameterized_plain[0].string);
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
